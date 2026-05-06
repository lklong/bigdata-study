# Amoro + Iceberg 联合案例：Amoro 管理 Iceberg 表的完整生命周期

> Eric | 2026-04-25

---

## 一、背景

Iceberg 表本身不具备自动维护能力，需要外部系统定期执行小文件合并、快照过期、孤立文件清理。Amoro（原 Arctic）作为湖仓管理系统，核心价值就是**自动化治理 Iceberg 表**。

本案例完整覆盖：**建表 → 写入 → 自动优化 → 元数据维护 → 监控告警 → 故障处理**。

---

## 二、架构全景

```
                          ┌───────────────────────────────┐
                          │        Amoro AMS Server        │
                          │  ┌──────────────────────────┐  │
                          │  │  CatalogManager          │  │
                          │  │  InternalCatalogImpl     │  │
                          │  │  (REST Catalog Protocol)  │  │
                          │  └──────────┬───────────────┘  │
                          │             │                   │
                          │  ┌──────────▼───────────────┐  │
                          │  │  TableService            │  │
                          │  │  - TableRuntime per table│  │
                          │  │  - RuntimeHandlerChain   │  │
                          │  └──────────┬───────────────┘  │
                          │             │                   │
                          │  ┌──────────▼───────────────┐  │
                          │  │  AsyncTableExecutors     │  │
                          │  │  ├─ SnapshotExpiring     │  │
                          │  │  ├─ OrphanFileCleaning   │  │
                          │  │  ├─ DataExpiring         │  │
                          │  │  └─ TagAutoCreating      │  │
                          │  └──────────────────────────┘  │
                          │                                 │
                          │  ┌──────────────────────────┐  │
                          │  │  OptimizingQueue         │  │
                          │  │  (Self-Optimizing调度)    │  │
                          │  └──────────┬───────────────┘  │
                          └─────────────┼───────────────────┘
                                        │
                          ┌─────────────▼───────────────────┐
                          │     Optimizer 进程 (N个)         │
                          │  ├─ OptimizerToucher (心跳)     │
                          │  └─ OptimizerExecutor × M       │
                          │      - pollTask() → execute()   │
                          │      - rewrite Iceberg files    │
                          └─────────────────────────────────┘
                                        │
                          ┌─────────────▼───────────────────┐
                          │        HDFS / S3 / OSS          │
                          │  ├─ /warehouse/db/table/data/   │
                          │  └─ /warehouse/db/table/metadata│
                          └─────────────────────────────────┘
```

---

## 三、Step 1：注册 Catalog 到 Amoro

### 3.1 AMS 内置 Catalog（推荐）

```
AMS Dashboard → Catalogs → Create Catalog
  - Catalog Name: iceberg_catalog
  - Catalog Type: Internal (AMS)
  - Table Format: Iceberg
  - Storage: HDFS
  - Warehouse: hdfs:///warehouse/iceberg
```

**原理（源码层面）**：

```
CatalogController.createCatalog()
  → DefaultCatalogManager.createCatalog(CatalogMeta)
    → CatalogBuilder.buildServerCatalog(meta)
      → new InternalCatalogImpl(meta, config)
         → 自动注入 REST Catalog 属性：
            uri = http://{ams-host}:1630/api/iceberg/rest
            catalog-impl = org.apache.iceberg.rest.RESTCatalog
    → 写入数据库: CatalogMetaMapper.insertCatalog()
```

### 3.2 外部 Catalog（HMS 类型）

```
AMS Dashboard → Catalogs → Create Catalog
  - Catalog Name: hive_iceberg
  - Catalog Type: Hive
  - Table Format: Iceberg
  - Hive Metastore URI: thrift://hive-metastore:9083
```

**原理**：

```
CatalogBuilder.buildServerCatalog(meta)
  → new ExternalCatalog(meta)
    → new CommonUnifiedCatalog(meta)  // 委托 HMS 客户端
  → DefaultTableService.exploreTableRuntimes()
    → exploreExternalCatalog()
      → unifiedCatalog.listDatabases() + listTables()
      → 对比已同步表 → syncTable() 同步新表
```

---

## 四、Step 2：创建 Iceberg 表

### 4.1 Spark 方式

```sql
-- 通过 AMS REST Catalog 创建
spark.sql("""
    CREATE TABLE iceberg_catalog.db.orders (
        order_id    BIGINT,
        customer_id BIGINT,
        amount      DECIMAL(10,2),
        status      STRING,
        created_at  TIMESTAMP,
        dt          STRING
    )
    USING iceberg
    PARTITIONED BY (dt)
    TBLPROPERTIES (
        'write.target-file-size-bytes' = '134217728',
        'self-optimizing.enabled' = 'true',
        'self-optimizing.group' = 'default',
        'self-optimizing.quota' = '0.1'
    )
""")
```

### 4.2 Amoro Dashboard 方式

```
AMS Dashboard → Tables → Create Table
  - Catalog: iceberg_catalog
  - Database: db
  - Table: orders
  - Format: Iceberg
  - Partition: dt (Identity)
```

**调用链**：

```
RestCatalogService.createTable()
  → InternalCatalogImpl.newTableCreator()
    → new InternalIcebergCreator(meta, db, tbl, request)
  → InternalCatalog.createTable()
    → doAsTransaction(insertTable, insertTableMeta, incTableCount, incDbTableCount)
  → DefaultTableService.onTableCreated()
    → new TableRuntime(meta, this)
    → tableRuntimeMap.put(id, runtime)
    → headHandler.fireTableAdded(runtime)
      → OptimizingQueue: 注册到调度队列
      → AsyncTableExecutors: 注册维护任务
```

---

## 五、Step 3：写入数据

```python
# Spark Streaming 写入
df = spark.readStream.format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:9092") \
    .option("subscribe", "orders") \
    .load()

orders_df = df.selectExpr(
    "CAST(value AS STRING) as json"
).select(
    from_json("json", schema).alias("data")
).select("data.*")

orders_df.writeStream \
    .format("iceberg") \
    .outputMode("append") \
    .option("checkpointLocation", "/checkpoint/orders") \
    .trigger(processingTime="1 minute") \
    .toTable("iceberg_catalog.db.orders")
```

**写入后的问题**：

```
每分钟一个 micro-batch → 每分钟产生 1-N 个小文件
1天 = 1440 个 batch → 可能数千个小文件/分区
3个月 = 数十万小文件 → 查询严重退化
```

---

## 六、Step 4：Amoro Self-Optimizing 自动治理

### 6.1 触发检测

```
TableRuntimeRefreshExecutor（定时刷新）
  → TableRuntime.refresh()
    → 读取 Iceberg 表最新 Snapshot
    → 计算 PendingInput：
       - dataFileCount:    当前数据文件数
       - dataFileSize:     当前数据总大小
       - equalityDeleteFileCount: 等式删除文件数
       - positionalDeleteFileCount: 位置删除文件数
    → 判断是否需要优化：
       if (pendingInput.needOptimizing(config)) {
           tableRuntime.setOptimizingStatus(PENDING);
       }
```

### 6.2 Minor Optimize（快速合并）

```
触发条件：分区内小文件数 > self-optimizing.minor.trigger.file-count (默认 12)

执行：
  OptimizingQueue.pollTask()
    → CommonPartitionEvaluator.evaluate()
      → planMinorOptimizing()
        → 选择小于 target-file-size 的文件
        → 打包为 RewriteFilesInput
    → OptimizerExecutor.execute(task)
      → IcebergRewriteExecutor.execute()
        → 读取选中的小文件
        → 合并写出为更大的文件
        → 返回 RewriteFilesOutput
    → UnKeyedTableCommit.commit()
      → table.newRewrite()
        .deleteFile(oldFiles)
        .addFile(newFiles)
        .commit()
```

### 6.3 Major Optimize（完整合并）

```
触发条件：
  - 分区总数据文件数 > self-optimizing.major.trigger.file-count (默认 100)
  - 或分区内 delete file 数 > self-optimizing.major.trigger.delete-file-count

执行：
  类似 Minor，但范围更大，可能合并整个分区的所有文件
  等效于 Iceberg 的 rewrite_data_files + rewrite_position_deletes
```

### 6.4 全自动维护循环

```
Amoro AMS 自动执行循环：

  ┌─── TableRuntimeRefreshExecutor（1分钟周期）
  │     检测表变更 → 更新 PendingInput
  │
  ├─── OptimizingQueue（持续调度）
  │     PENDING 表 → 生成优化任务 → 分配给 Optimizer
  │
  ├─── SnapshotsExpiringExecutor（定时）
  │     自动 expire 旧快照
  │     参数: self-optimizing.expire-snapshots.retain-last = 10
  │
  ├─── OrphanFilesCleaningExecutor（定时）
  │     自动清理孤立文件
  │     参数: self-optimizing.orphan-files-clean.delay-ms = 259200000 (3天)
  │
  ├─── DataExpiringExecutor（定时）
  │     按 TTL 删除过期分区数据
  │     参数: data-expire.enabled, data-expire.field, data-expire.retention
  │
  └─── TagsAutoCreatingExecutor（定时）
       自动创建 Iceberg Tag（Time Travel 锚点）
       参数: tag.auto-create.enabled, tag.auto-create.trigger.period
```

---

## 七、Step 5：监控与诊断

### 7.1 AMS Dashboard 关键指标

| 指标 | 含义 | 告警阈值 |
|------|------|---------|
| Optimizing Status | 表优化状态 | PENDING 超过 1 小时 |
| Pending Input | 待优化的输入量 | data files > 1000 |
| Optimizer Threads | 活跃线程数 | = 0 表示无 Optimizer |
| Optimizing Duration | 最近优化耗时 | > 30 分钟 |
| File Count | 数据文件总数 | > 10000 |
| Avg File Size | 平均文件大小 | < 32MB |

### 7.2 诊断 SQL

```sql
-- 检查文件状态
SELECT count(*), avg(file_size_in_bytes), min(file_size_in_bytes)
FROM iceberg_catalog.db.orders.files;

-- 检查快照数量
SELECT count(*) FROM iceberg_catalog.db.orders.snapshots;

-- 检查 Delete 文件
SELECT content, count(*)
FROM iceberg_catalog.db.orders.files
GROUP BY content;
-- content=0: data files, content=1: position deletes, content=2: equality deletes
```

---

## 八、Step 6：故障处理

### 8.1 Self-Optimizing 不工作

```
排查决策树：
  ├── 检查 self-optimizing.enabled = true ?
  ├── 检查 Optimizer 进程是否存活（AMS Dashboard → Optimizers）
  ├── 检查 Optimizer Group 是否匹配表的 self-optimizing.group
  ├── 检查 OptimizingQueue 中的任务状态
  │    ├── PLANNING → 正在规划，等待
  │    ├── PENDING → 等待 Optimizer 领取
  │    ├── EXECUTING → 正在执行
  │    └── COMMITTING → 正在提交
  └── 检查 Optimizer 日志是否有 OOM/异常
```

### 8.2 手动触发优化

```sql
-- 如果 Amoro 自动优化不及时，可手动执行
CALL iceberg_catalog.system.rewrite_data_files(
    table => 'db.orders',
    where => 'dt = "2026-04-25"',
    options => map('target-file-size-bytes', '134217728')
);

CALL iceberg_catalog.system.expire_snapshots(
    table => 'db.orders',
    retain_last => 5
);
```

---

## 九、关键配置参数总览

| 参数 | 含义 | 推荐值 |
|------|------|--------|
| `self-optimizing.enabled` | 启用自动优化 | `true` |
| `self-optimizing.group` | Optimizer 组 | `default` |
| `self-optimizing.quota` | CPU 配额（0-1） | `0.1` |
| `self-optimizing.minor.trigger.file-count` | Minor 触发阈值 | `12` |
| `self-optimizing.major.trigger.file-count` | Major 触发阈值 | `100` |
| `write.target-file-size-bytes` | 目标文件大小 | `134217728`（128MB） |
| `gc.enabled` | 允许 GC | `true` |
| `snapshot.retain-last` | 保留快照数 | `10` |
| `data-expire.enabled` | 启用数据过期 | 按需 |
| `data-expire.field` | 过期字段 | `dt` |
| `data-expire.retention` | 保留时长 | `90d` |
