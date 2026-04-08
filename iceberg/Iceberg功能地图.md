# Apache Iceberg 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 核心能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **ACID 事务** | 快照隔离的读写事务 | 自动（乐观并发控制） | 写冲突需要重试 | 并发写同分区可能冲突 |
| **Schema Evolution** | 添加/删除/重命名/类型提升 | `ALTER TABLE ADD/DROP/RENAME COLUMN` | 不支持缩窄类型（如 long→int） | 用 field_id 不依赖列名 |
| **Hidden Partitioning** | 用户无需感知分区 | `PARTITIONED BY (days(ts))` | 分区转换不可变（需 partition evolution） | 查询自动做 partition pruning |
| **Partition Evolution** | 运行时修改分区策略 | `ALTER TABLE ... SET PARTITION SPEC (...)` | 旧数据保持原分区；新数据用新分区 | 不需要重写历史数据 |
| **Time Travel** | 查询历史快照 | `SELECT * FROM t TIMESTAMP AS OF '...'` / `VERSION AS OF snapshotId` | 快照过期后不可查 | 控制 `expire_snapshots` 策略 |
| **增量查询** | 两快照间变更数据 | Spark: `option("start-snapshot-id", ...)` | 需要知道快照 ID | CDC 场景使用 |
| **行级更新** | UPDATE / DELETE / MERGE INTO | `MERGE INTO t USING src ON ... WHEN MATCHED THEN UPDATE ...` | Copy-on-Write 模式写放大；Merge-on-Read 读放大 | 大量更新用 MOR |
| **文件级统计** | 列级 min/max/null_count | 自动写入 Manifest | 统计只在文件级，不如 Parquet RowGroup 级精细 | 大幅减少数据扫描 |
| **多引擎** | Spark/Flink/Trino/Presto/Hive | 各引擎的 Iceberg Connector | 各引擎支持程度不同（Spark 最完整） | 统一用 HiveCatalog |
| **Compaction** | 合并小文件 | `CALL system.rewrite_data_files(...)` | 需要额外计算资源 | 定期执行 |
| **排序** | 按指定列排序文件内数据 | `CALL ... strategy => 'sort', sort_order => 'col ASC'` | 排序后写入是全量重写 | 按查询热点列排序 |

---

## 功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 实时点查 (< 10ms) | HBase |
| 流式写入（毫秒级） | Hudi / Paimon |
| 独立查询引擎 | 需要 Spark/Flink/Trino |
| 自动 Compaction | Amoro / 手动调度 |

---

*Iceberg Expert | 功能地图 v1.0 | 2026-04-08*
