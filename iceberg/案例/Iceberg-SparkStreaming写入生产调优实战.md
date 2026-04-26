# Iceberg + Spark Streaming 写入生产调优实战

> Eric | 2026-04-26

---

## 一、场景描述

```
业务场景:
  - Kafka 实时订单流 → Spark Structured Streaming → Iceberg 表
  - 日增数据量: ~50GB / 天
  - 分区策略: days(created_at)
  - 触发间隔: 1 分钟

问题:
  运行 3 个月后，查询从 10s 退化到 120s+
  根因: 每分钟一个 micro-batch → 1440 次/天 → 数十万小文件
```

---

## 二、问题诊断

### 2.1 文件状态检查

```sql
-- 检查文件数量和平均大小
SELECT
    count(*) as file_count,
    avg(file_size_in_bytes) / 1024 / 1024 as avg_size_mb,
    min(file_size_in_bytes) / 1024 / 1024 as min_size_mb,
    max(file_size_in_bytes) / 1024 / 1024 as max_size_mb,
    sum(file_size_in_bytes) / 1024 / 1024 / 1024 as total_gb
FROM catalog.db.orders.files
WHERE content = 0;  -- 只看 data files

-- 典型输出:
-- file_count: 432000
-- avg_size_mb: 3.2
-- min_size_mb: 0.01
-- max_size_mb: 128
-- total_gb: 1350
```

### 2.2 快照膨胀检查

```sql
SELECT count(*) as snapshot_count
FROM catalog.db.orders.snapshots;
-- 可能: 130000+ (1440/天 × 90天)

SELECT count(*) as manifest_count
FROM catalog.db.orders.manifests;
-- Manifest 数量也会膨胀
```

### 2.3 Delete File 检查

```sql
SELECT
    content,
    count(*) as cnt,
    sum(file_size_in_bytes) / 1024 / 1024 as total_mb
FROM catalog.db.orders.files
GROUP BY content;
-- content=0: data files
-- content=1: position deletes
-- content=2: equality deletes
```

---

## 三、写入侧优化

### 3.1 增大 Batch 间隔

```python
# 之前: 1 分钟
orders_df.writeStream.trigger(processingTime="1 minute")

# 优化后: 5-10 分钟（根据延迟容忍度）
orders_df.writeStream.trigger(processingTime="5 minutes")
# 文件数量直接减少 5 倍！
```

### 3.2 目标文件大小

```sql
ALTER TABLE catalog.db.orders SET TBLPROPERTIES (
    'write.target-file-size-bytes' = '134217728'  -- 128MB
);
```

```python
# Spark 配置
spark.conf.set("spark.sql.iceberg.write-target-file-size-bytes", "134217728")
```

### 3.3 Fanout Writer（分区打散写入）

```sql
-- 避免排序导致的性能问题
ALTER TABLE catalog.db.orders SET TBLPROPERTIES (
    'write.distribution-mode' = 'none'  -- 不做全局排序
    -- 或 'hash' 按分区哈希分配
);
```

### 3.4 Spark Streaming 特有配置

```python
spark.conf.set("spark.sql.shuffle.partitions", "200")  # 并行度

# 控制每次 commit 的文件数
spark.conf.set("spark.sql.iceberg.fanout.enabled", "true")  # fanout writer
```

---

## 四、维护侧优化

### 4.1 方案 A：手动定时维护（Airflow/DolphinScheduler）

```python
# daily_maintenance.py — 每天凌晨执行
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .config("spark.sql.catalog.catalog", "org.apache.iceberg.spark.SparkCatalog") \
    .getOrCreate()

# Step 1: 小文件合并（按分区）
yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
spark.sql(f"""
    CALL catalog.system.rewrite_data_files(
        table => 'db.orders',
        where => 'created_at_day = "{yesterday}"',
        options => map(
            'target-file-size-bytes', '134217728',
            'max-concurrent-file-group-rewrites', '5',
            'partial-progress.enabled', 'true'
        )
    )
""")

# Step 2: 快照过期（保留 10 个）
spark.sql("""
    CALL catalog.system.expire_snapshots(
        table => 'db.orders',
        retain_last => 10
    )
""")

# Step 3: 孤立文件清理（每周日执行）
if datetime.now().weekday() == 6:
    spark.sql(f"""
        CALL catalog.system.remove_orphan_files(
            table => 'db.orders',
            older_than => TIMESTAMP '{(datetime.now() - timedelta(days=3)).strftime("%Y-%m-%d %H:%M:%S")}'
        )
    """)
```

### 4.2 方案 B：Amoro 全自动维护（推荐）

```sql
-- 注册表到 Amoro 后配置以下参数
ALTER TABLE catalog.db.orders SET TBLPROPERTIES (
    -- Self-Optimizing 核心参数
    'self-optimizing.enabled' = 'true',
    'self-optimizing.group' = 'default',
    'self-optimizing.quota' = '0.1',
    'self-optimizing.minor.trigger.file-count' = '12',
    'self-optimizing.major.trigger.file-count' = '100',

    -- 目标文件大小
    'write.target-file-size-bytes' = '134217728',

    -- 快照过期
    'snapshot.retain-num' = '10',

    -- 孤立文件清理
    'clean-orphan-files.enabled' = 'true',
    'clean-orphan-files.delay' = '259200000'  -- 3天 (ms)
);
```

**Amoro 全自动效果**:
- Minor Optimize: 分区内小文件 > 12 时自动合并
- Major Optimize: 分区总文件 > 100 或 delete file 堆积时全量合并
- 快照过期: 每小时自动执行
- 孤立文件清理: 定时自动执行

---

## 五、读取侧优化

### 5.1 Manifest 缓存

```sql
ALTER TABLE catalog.db.orders SET TBLPROPERTIES (
    'read.metadata.table-cache.expiration-interval-ms' = '300000'  -- 5分钟
);
```

### 5.2 Vectorized Read

```python
spark.conf.set("spark.sql.iceberg.vectorization.enabled", "true")
spark.conf.set("spark.sql.iceberg.vectorization.batch-size", "4096")
```

### 5.3 Manifest 重写

```sql
-- Manifest 数量过多时（> 1000）
CALL catalog.system.rewrite_manifests(table => 'db.orders');
```

---

## 六、监控告警配置

### 6.1 关键指标

| 指标 | SQL | 告警阈值 |
|------|-----|---------|
| 文件数 | `SELECT count(*) FROM t.files WHERE content=0` | > 10000 |
| 平均文件大小 | `SELECT avg(file_size_in_bytes) FROM t.files` | < 32MB |
| 快照数 | `SELECT count(*) FROM t.snapshots` | > 1000 |
| Delete 文件数 | `SELECT count(*) FROM t.files WHERE content>0` | > 100 |
| Manifest 数 | `SELECT count(*) FROM t.manifests` | > 1000 |

### 6.2 Grafana Dashboard（如使用 Amoro）

```
Amoro AMS 暴露 Prometheus 指标:
  amoro_table_data_files_count
  amoro_table_data_files_size_bytes
  amoro_table_optimizing_status
  amoro_table_pending_input_data_files
  amoro_optimizer_threads_active
```

---

## 七、优化前后对比

| 维度 | 优化前 | 优化后 |
|------|--------|--------|
| 文件数 | 432,000 | 12,000 |
| 平均文件大小 | 3.2MB | 115MB |
| 快照数 | 130,000 | 10 |
| 查询耗时 | 120s+ | 8s |
| Planning 耗时 | 30s | 0.5s |
| 维护方式 | 无 | Amoro 全自动 |

---

## 八、最佳实践总结

```
写入侧:
  1. Batch 间隔 ≥ 5 分钟（平衡延迟与文件数）
  2. target-file-size = 128MB
  3. distribution-mode = hash（按分区均匀分配）

维护侧:
  4. 首选 Amoro 全自动维护
  5. 无 Amoro 时用 Airflow 定时: rewrite → expire → orphan clean
  6. 顺序很重要: 先合并 → 再过期 → 最后清孤立

读取侧:
  7. 开启 vectorized read
  8. Manifest 数量 > 1000 时 rewrite_manifests
  9. 添加 Grafana 监控告警
```
