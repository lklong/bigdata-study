# 教案 14：Iceberg 与 Spark 集成全解 — 从建表到流批一体

> **适用对象**：大数据开发工程师 | **前置知识**：了解 Spark SQL 基础  
> **课时**：50 分钟 | **难度**：⭐⭐⭐

---

## 一、课前导入 — 为什么不能直接用 Hive 表？

> 你的 Spark 作业写 Hive 表，每次写入都要刷新分区元数据，大表有 10 万个分区，`MSCK REPAIR TABLE` 一跑就是 30 分钟。更别提并发写入冲突、Schema 变更要删表重建...
>
> Iceberg 通过 Spark DSv2 API 完美解决了这些问题：**无缝集成、零元数据延迟、ACID 事务、Schema Evolution 在线变更**。

---

## 二、本课目标

1. **SparkCatalog 如何桥接 Spark 和 Iceberg？** 一条 SQL 从哪进来、怎么走到 Iceberg？
2. **流批一体怎么做？** 同一张表如何同时支持 Streaming 写入和批量查询？
3. **生产环境最佳配置清单** — 20 个关键配置项

---

## 三、架构图 — Spark + Iceberg 的桥梁

```
┌──────────────────────────────────┐
│         Spark SQL / DataFrame     │
├──────────────────────────────────┤
│     Spark DSv2 Catalog API        │  ← 标准接口
│  (TableCatalog / Table / Scan)    │
├──────────────────────────────────┤
│       SparkCatalog (Iceberg)      │  ← 桥梁类
│  ┌─────────────────────────────┐ │
│  │  icebergCatalog (底层实现)    │ │
│  │  HiveCatalog / RESTCatalog   │ │
│  └─────────────────────────────┘ │
├──────────────────────────────────┤
│         Iceberg Core API          │  ← 表操作
│  (Table / Scan / Append / etc.)   │
├──────────────────────────────────┤
│     FileIO (HDFS / S3 / COS)      │  ← 存储层
└──────────────────────────────────┘
```

### SparkCatalog（源码核心）

```java
// spark/v3.5/.../iceberg/spark/SparkCatalog.java
// 实现了 Spark 的 TableCatalog 接口，让 Spark SQL 能直接操作 Iceberg 表

public class SparkCatalog implements TableCatalog, SupportsNamespaces {
    private Catalog icebergCatalog;  // 底层的 Iceberg Catalog 实现
    
    @Override
    public Table loadTable(Identifier ident) {
        // 加载 Iceberg 表并包装成 SparkTable
        org.apache.iceberg.Table table = icebergCatalog.loadTable(tableIdent);
        return new SparkTable(table, ...);
    }
}
```

---

## 四、实战操作

### 4.1 配置 Spark 使用 Iceberg

```python
# spark-defaults.conf 或 SparkSession 配置
spark.sql.catalog.iceberg = org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.iceberg.type = hive  # 或 rest / hadoop
spark.sql.catalog.iceberg.uri = thrift://hms:9083
spark.sql.extensions = org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
```

### 4.2 建表 + 写入 + 查询

```sql
-- 建表
CREATE TABLE iceberg.db.orders (
    order_id BIGINT,
    user_id BIGINT,
    amount DECIMAL(10,2),
    order_time TIMESTAMP,
    status STRING
) USING iceberg
PARTITIONED BY (days(order_time))  -- Hidden Partitioning！
TBLPROPERTIES (
    'write.format.default' = 'parquet',
    'write.target-file-size-bytes' = '134217728'  -- 128MB
);

-- 批量写入
INSERT INTO iceberg.db.orders SELECT * FROM staging_orders;

-- 流式写入（Structured Streaming）
df.writeStream
  .format("iceberg")
  .outputMode("append")
  .option("checkpointLocation", "/checkpoints/orders")
  .toTable("iceberg.db.orders")

-- 时间旅行查询
SELECT * FROM iceberg.db.orders VERSION AS OF 12345;
SELECT * FROM iceberg.db.orders TIMESTAMP AS OF '2024-01-15 15:00:00';
```

### 4.3 流批一体的关键

同一张表可以：
- **Streaming 写入**：Spark Structured Streaming 每个 micro-batch 生成一个新 Snapshot
- **批量查询**：普通 Spark SQL 直接查最新 Snapshot
- **增量读取**：`SELECT * FROM iceberg.db.orders VERSION BETWEEN 100 AND 200`

---

## 五、生产配置清单 TOP 10

| 配置 | 推荐值 | 作用 |
|------|--------|------|
| `write.target-file-size-bytes` | 128MB-512MB | 控制单个数据文件大小 |
| `write.distribution-mode` | hash | 写入时按分区 key 分桶，减少小文件 |
| `write.metadata.delete-after-commit.enabled` | true | 自动清理旧元数据文件 |
| `read.split.target-size` | 128MB | 控制读取时的 split 大小 |
| `write.spark.fanout.enabled` | true | Streaming 场景避免 sort（减少内存） |
| `history.expire.max-snapshot-age-ms` | 604800000 (7天) | 快照保留时间 |
| `history.expire.min-snapshots-to-keep` | 10 | 最少保留快照数 |
| `write.parquet.compression-codec` | zstd | 压缩率和速度的最佳平衡 |
| `write.delete.mode` | merge-on-read | UPDATE/DELETE 使用 MoR |
| `commit.retry.num-retries` | 4 | OCC 冲突重试次数 |

---

## 六、课堂练习

### 思考题 1：为什么 Iceberg 的 Hidden Partitioning 比 Hive 分区好？

<details>
<summary>参考答案</summary>

Hive 分区问题：
- 用户必须知道分区列和值：`WHERE dt='2024-01-15'`
- 换分区策略要重建表
- 分区列是"虚拟列"，不在数据文件中

Iceberg Hidden Partitioning：
- 用户只写业务条件：`WHERE order_time > '2024-01-15'`，引擎自动裁剪
- 分区策略可在线变更（Partition Evolution）
- 支持 Transform：`days()`, `hours()`, `months()`, `bucket()`, `truncate()`
</details>

### 思考题 2：Streaming + 批量并发读写安全吗？

<details>
<summary>参考答案</summary>

安全！Iceberg 的 MVCC 保证：
- Streaming 写入创建新 Snapshot → 不影响正在读旧 Snapshot 的查询
- 批量查询读的是某个 Snapshot 的"快照视图" → 不受并发写入影响
- 唯一冲突点：两个 Writer 同时写同一个分区 → OCC 重试解决
</details>

---

## 七、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Iceberg + Spark 集成                              │
├──────────────────────────────────────────────────┤
│  桥梁: SparkCatalog → icebergCatalog → Table      │
│  接口: Spark DSv2 (TableCatalog/Table/Scan)       │
├──────────────────────────────────────────────────┤
│  流批一体:                                         │
│  写: writeStream.format("iceberg") → 每batch一个Snapshot │
│  读: 普通SQL读最新 / VERSION AS OF 读历史          │
│  增量: VERSION BETWEEN x AND y                     │
├──────────────────────────────────────────────────┤
│  必配项: target-file-size=128MB + distribution=hash │
│  + expire.max-age=7d + compression=zstd           │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Iceberg Spark 源码 v3.5 | 最后更新：2026-04-30*
