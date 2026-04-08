# Iceberg 小文件治理实战

> Iceberg Expert 案例学习 — 流式写入场景的小文件问题

## 案例背景

```
环境: Spark Structured Streaming → Iceberg 表, 每分钟写入一次
表: events (分区: days(ts)), 每天 100GB 新数据
问题:
  - 3 个月后表有 200 万个小文件（平均 5MB/文件）
  - 查询性能严重退化: 1 小时的数据扫描从 10s → 120s
  - Manifest 文件膨胀: 5000 个 manifest → 查询计划时间 30s
  - 存储浪费: 小文件的 Parquet footer 开销占比高
```

## 排查过程

### Step 1: 文件分布分析

```sql
-- 查看各分区的文件数和平均大小
SELECT 
  partition,
  count(*) as file_count,
  sum(file_size_in_bytes) / count(*) / 1024 / 1024 as avg_file_mb,
  sum(file_size_in_bytes) / 1024 / 1024 / 1024 as total_gb
FROM db.events.files
GROUP BY partition
ORDER BY file_count DESC
LIMIT 20;

-- 结果:
-- ts_day=2026-04-07: 2200 files, avg 4.5MB, 9.9GB
-- ts_day=2026-04-06: 2200 files, avg 4.5MB, 9.9GB
-- ...

-- 根因: 每分钟一次微批写入 × 100 个 executor × 1 file/executor = 每天 144,000 个小文件
-- 实际因为 AQE 合并: ~2200 个/天，但仍然太小
```

### Step 2: 修复方案

```python
# 方案1: 定时 Compaction（推荐）
# 每天执行一次小文件合并

from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .config("spark.sql.catalog.spark_catalog", "org.apache.iceberg.spark.SparkCatalog") \
    .getOrCreate()

# binpack 策略: 将小文件合并到 512MB
spark.sql("""
CALL spark_catalog.system.rewrite_data_files(
  table => 'db.events',
  strategy => 'binpack',
  options => map(
    'target-file-size-bytes', '536870912',
    'min-file-size-bytes', '104857600',
    'max-file-size-bytes', '1073741824',
    'partial-progress.enabled', 'true',
    'partial-progress.max-commits', '10'
  ),
  where => 'ts >= current_date() - INTERVAL 3 DAYS'
)
""")

# 合并 manifest 文件
spark.sql("""
CALL spark_catalog.system.rewrite_manifests(
  table => 'db.events',
  use_caching => true
)
""")

# 过期旧快照
spark.sql("""
CALL spark_catalog.system.expire_snapshots(
  table => 'db.events',
  older_than => TIMESTAMP '2026-04-01 00:00:00',
  retain_last => 10
)
""")

# 清理孤立文件
spark.sql("""
CALL spark_catalog.system.remove_orphan_files(
  table => 'db.events',
  older_than => TIMESTAMP '2026-04-01 00:00:00'
)
""")
```

```properties
# 方案2: 写入端优化 — 减少小文件产生
# Spark Structured Streaming 配置
spark.sql.shuffle.partitions=20           # 减少输出分区数
write.target-file-size-bytes=536870912    # 目标文件大小 512MB
write.distribution-mode=hash              # 按分区 hash 分布写入
```

### Step 3: 自动化 Compaction（Amoro/Arctic 方案）

```
如果使用 Amoro (原 Arctic) 管理 Iceberg 表:
  - Amoro 自动检测小文件 → 触发 Self-Optimizing
  - 无需手动调度 Compaction 任务
  - 支持 Minor (合并小文件) + Major (全量优化) 两级

配置:
  self-optimizing.enabled=true
  self-optimizing.minor.trigger.file-count=20     # 分区内 > 20 个文件触发
  self-optimizing.minor.trigger.interval=3600000  # 最少间隔 1 小时
  self-optimizing.target-size=536870912            # 目标 512MB
```

### Step 4: 效果

```
修复前: 200 万文件, 5000 manifests, 查询计划 30s, 扫描 120s
修复后: 3 万文件, 200 manifests, 查询计划 2s, 扫描 12s

提升: 查询性能 10x, 存储空间节省 15%(footer 开销减少)
```

## 经验规则

```
R-ICE-001: 流式写入的 Iceberg 表必须配合定时 Compaction
R-ICE-002: 目标文件大小 256MB-1GB, 不要太小也不要太大
R-ICE-003: 每天至少执行一次 rewrite_manifests 清理 manifest 膨胀
R-ICE-004: expire_snapshots + remove_orphan_files 每周至少一次
R-ICE-005: 有条件用 Amoro 做自动化小文件治理
```

---

*Iceberg Expert 案例产出 | 2026-04-08*
