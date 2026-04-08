# Spark 性能调优 Checklist

> 上线前必查 | 按优先级排序

---

## P0 — 必须检查（不做会出事）

- [ ] `spark.serializer` = KryoSerializer（默认 JavaSerializer 慢 10 倍）
- [ ] `spark.sql.adaptive.enabled` = true（AQE 自适应）
- [ ] `spark.sql.shuffle.partitions` 根据数据量调整（默认 200 太小/太大？）
- [ ] `spark.executor.memory` + `memoryOverhead` 不超过 Container/Pod 限制
- [ ] 没有 `SELECT *`（列裁剪）
- [ ] WHERE 条件用到了分区列（分区裁剪）
- [ ] 没有笛卡尔积 Join（`BroadcastNestedLoopJoin`）
- [ ] GC 日志已开启（`-verbose:gc -Xloggc:...`）
- [ ] `spark.task.maxFailures` ≥ 4（容错）

## P1 — 强烈建议

- [ ] 开启动态分配 + 设合理的 min/max Executor
- [ ] 大表 Join 小表用 BroadcastJoin（调大 `autoBroadcastJoinThreshold`）
- [ ] 数据倾斜场景开启 `spark.sql.adaptive.skewJoin.enabled=true`
- [ ] Shuffle 压缩用 zstd（比 lz4 压缩率高 30%）
- [ ] K8s 场景显式设 `-XX:ParallelGCThreads=8`
- [ ] `spark.speculation=true`（推测执行，杀掉慢 Task 重跑）
- [ ] 数据源用列存格式（Parquet/ORC），不用 TextFile/JSON

## P2 — 进阶优化

- [ ] CBO 统计信息已收集（`ANALYZE TABLE ... COMPUTE STATISTICS`）
- [ ] UDF 用内置函数替代（避免黑盒）
- [ ] 合理设置 `spark.sql.files.maxPartitionBytes`（默认 128MB）
- [ ] `spark.locality.wait` 根据集群网络调整（默认 3s）
- [ ] K8s: `spark.dynamicAllocation.initialExecutors` = 目标值（避免慢启动）

---

*Spark Expert | 2026-04-08*
