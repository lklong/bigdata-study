# Apache Iceberg 表格式与元数据管理深度分析

> Iceberg Expert 补课学习 — 新一代数据湖表格式核心

## 一、Iceberg 架构总览

### 1.1 三层元数据架构

```
┌────────────────────────────────────────────┐
│              Catalog (HMS / REST)           │
│  table → current metadata file location    │
└────────────┬───────────────────────────────┘
             ↓
┌────────────────────────────────────────────┐
│           Metadata File (JSON)             │
│  ┌──────────────────────────────────┐      │
│  │ Snapshot List:                   │      │
│  │   snap-1 → manifest-list-1      │      │
│  │   snap-2 → manifest-list-2 (cur)│      │
│  │ Schema Evolution History         │      │
│  │ Partition Spec History           │      │
│  │ Sort Order                       │      │
│  │ Properties                       │      │
│  └──────────────────────────────────┘      │
└────────────┬───────────────────────────────┘
             ↓
┌────────────────────────────────────────────┐
│         Manifest List (Avro)               │
│  ┌──────────────────────────────────┐      │
│  │ manifest-1.avro: /data/part=A/*  │      │
│  │ manifest-2.avro: /data/part=B/*  │      │
│  │ 每个 manifest 的分区范围/文件数  │      │
│  └──────────────────────────────────┘      │
└────────────┬───────────────────────────────┘
             ↓
┌────────────────────────────────────────────┐
│          Manifest File (Avro)              │
│  ┌──────────────────────────────────┐      │
│  │ data-file-1.parquet:            │      │
│  │   path, partition, record_count, │      │
│  │   file_size, column_sizes,      │      │
│  │   value_counts, null_counts,    │      │
│  │   lower_bounds, upper_bounds    │      │
│  └──────────────────────────────────┘      │
└────────────┬───────────────────────────────┘
             ↓
┌────────────────────────────────────────────┐
│         Data Files (Parquet/ORC/Avro)      │
└────────────────────────────────────────────┘

关键设计:
  - 每一层都是不可变的（immutable）
  - 写操作 = 创建新的 metadata file → 原子更新 catalog 指针
  - 读操作 = 从 catalog 获取当前 metadata → 遍历 snapshot → manifest → data files
```

### 1.2 快照隔离 (Snapshot Isolation)

```
时间线:
  T1: Writer-A 开始写入（基于 snap-1）
  T2: Writer-B 完成写入 → 创建 snap-2（current）
  T3: Reader-C 开始读取 → 看到 snap-2
  T4: Writer-A 完成写入 → 尝试创建 snap-3
      → 乐观并发控制: 检查 snap-1 → snap-2 的变更是否冲突
      → 无冲突 → 成功创建 snap-3
      → 有冲突 → 重试

对比 Hive:
  Hive: 写入时锁表/分区 → 并发差
  Iceberg: 乐观并发 + 快照隔离 → 读写不阻塞
```

## 二、核心特性

### 2.1 Schema Evolution（模式演进）

```sql
-- Iceberg 支持原地 Schema 变更（不重写数据）
ALTER TABLE db.events ADD COLUMN user_agent STRING;
ALTER TABLE db.events RENAME COLUMN user_agent TO ua;
ALTER TABLE db.events ALTER COLUMN price TYPE double;  -- 类型提升
ALTER TABLE db.events DROP COLUMN deprecated_col;

-- 原理:
-- 每个列有全局唯一 field_id（不依赖列名/位置）
-- Schema 变更只修改 metadata file 中的 schema 定义
-- 旧数据文件继续有效（新列读出 null）
```

### 2.2 Hidden Partitioning（隐式分区）

```sql
-- Hive 方式: 用户必须知道分区列，查询时也要指定
CREATE TABLE events (ts TIMESTAMP, data STRING) PARTITIONED BY (dt STRING);
-- 用户负担: INSERT 时要手动计算 dt = date_format(ts, 'yyyy-MM-dd')

-- Iceberg 方式: 分区转换对用户透明
CREATE TABLE events (
  ts TIMESTAMP,
  data STRING
) USING iceberg
PARTITIONED BY (days(ts));   -- 自动从 ts 提取日期分区

-- 用户查询时不需要知道分区:
SELECT * FROM events WHERE ts > '2026-04-01';
-- Iceberg 自动做 partition pruning → 只扫描 4月的分区

-- 支持的分区转换:
-- years(ts), months(ts), days(ts), hours(ts)
-- bucket(N, col)  — 哈希分桶
-- truncate(L, col) — 截断
```

### 2.3 Time Travel（时间旅行）

```sql
-- 查看历史版本
SELECT * FROM events TIMESTAMP AS OF '2026-04-07 12:00:00';

-- 回滚到指定快照
CALL system.rollback_to_snapshot('db.events', 12345678);

-- 增量查询（两个快照之间的变更）
SELECT * FROM events 
  WHERE _commit_timestamp > '2026-04-07' 
  AND _commit_timestamp <= '2026-04-08';

-- 快照列表
SELECT * FROM db.events.snapshots;
```

### 2.4 文件级统计信息

```
每个数据文件在 Manifest 中记录:
  - record_count: 记录数
  - file_size_in_bytes: 文件大小
  - column_sizes: 每列占用字节数
  - value_counts: 每列非null值数
  - null_value_counts: 每列null值数
  - nan_value_counts: 每列NaN值数
  - lower_bounds: 每列最小值
  - upper_bounds: 每列最大值

查询优化:
  SELECT * FROM events WHERE user_id = 12345
  → Iceberg 检查每个文件的 lower_bounds/upper_bounds
  → user_id=12345 不在 [1000, 5000] 范围内 → 跳过该文件
  → 大幅减少扫描量（类似 Parquet RowGroup 级过滤，但粒度更粗更快）
```

## 三、Compaction 与维护

### 3.1 小文件合并

```sql
-- 触发 compaction（合并小文件）
CALL system.rewrite_data_files(
  table => 'db.events',
  strategy => 'binpack',         -- 按大小合并
  options => map('target-file-size-bytes', '536870912')  -- 512MB
);

-- 排序合并（按特定列排序，优化后续查询）
CALL system.rewrite_data_files(
  table => 'db.events',
  strategy => 'sort',
  sort_order => 'user_id ASC NULLS LAST, ts DESC'
);
```

### 3.2 快照过期清理

```sql
-- 过期旧快照（释放存储空间）
CALL system.expire_snapshots(
  table => 'db.events',
  older_than => TIMESTAMP '2026-04-01 00:00:00',
  retain_last => 5
);

-- 清理孤立文件（metadata 不引用的数据文件）
CALL system.remove_orphan_files(
  table => 'db.events',
  older_than => TIMESTAMP '2026-04-01 00:00:00'
);
```

## 四、Iceberg 与 Spark 集成

```properties
# Spark 配置
spark.sql.catalog.spark_catalog = org.apache.iceberg.spark.SparkSessionCatalog
spark.sql.catalog.spark_catalog.type = hive
spark.sql.extensions = org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
```

```sql
-- 创建 Iceberg 表
CREATE TABLE db.events (
  id BIGINT,
  ts TIMESTAMP,
  data STRING
) USING iceberg
PARTITIONED BY (days(ts))
TBLPROPERTIES (
  'write.format.default' = 'parquet',
  'write.parquet.compression-codec' = 'zstd',
  'write.target-file-size-bytes' = '536870912'  -- 512MB
);

-- MERGE INTO (Upsert)
MERGE INTO db.events t
USING updates s
ON t.id = s.id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;
```

## 五、Iceberg vs Hudi vs Delta Lake

| 维度 | Iceberg | Hudi | Delta Lake |
|------|---------|------|------------|
| 发起方 | Netflix/Apple | Uber | Databricks |
| 元数据 | 三层 (metadata→manifest→data) | Timeline + FileGroup | DeltaLog (JSON/Parquet) |
| Schema Evolution | ✅ 完整 | ✅ | ✅ |
| Hidden Partition | ✅ | ❌ | ❌ |
| Time Travel | ✅ | ✅ | ✅ |
| MERGE INTO | ✅ (Spark 3+) | ✅ (原生) | ✅ (原生) |
| 增量查询 | ✅ (快照间) | ✅ (原生优势) | ✅ |
| 社区活跃度 | 高 (ASF顶级) | 高 (ASF顶级) | 中 (Databricks主导) |
| 引擎兼容性 | Spark/Flink/Trino/Presto | Spark/Flink | Spark (最优) |

## 六、运维实战

### 6.1 监控指标

```bash
# 表元数据概览
SELECT * FROM db.events.metadata_log_entries;

# 快照历史
SELECT committed_at, snapshot_id, operation, summary 
FROM db.events.snapshots;

# 文件分布
SELECT partition, file_count, total_size_in_bytes 
FROM db.events.partitions;

# Manifest 数量（过多会影响查询计划时间）
SELECT * FROM db.events.manifests;
```

### 6.2 性能优化

```
1. 控制文件大小: target-file-size = 256MB-1GB
2. 定期 compaction: 小文件合并到目标大小
3. 排序: 按高频查询列排序（利用 min/max 过滤）
4. 分区策略: 不要过度分区（每分区 > 100MB）
5. Manifest 清理: expire_snapshots 定期执行
```

---

*Iceberg Expert 学习产出 | 2026-04-08 | 补课：表格式与元数据管理*
