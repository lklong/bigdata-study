# AQE (Adaptive Query Execution) 在 K8s 环境的深度分析

> Spark Expert 延伸学习 — 从 K8s vs YARN 案例中的 AQE 配置差异出发

## 一、背景

在 K8s vs YARN 性能分析案例中，两端的 AQE 配置完全一致：
```properties
spark.sql.adaptive.enabled = true
spark.sql.adaptive.coalescePartitions.enabled = true
spark.sql.adaptive.skewJoin.enabled = true
```

但 AQE 在 K8s 环境有一些特殊行为需要注意。

## 二、AQE 核心机制源码解析

### 2.1 AQE 触发时机

源码路径：`sql/core/src/main/scala/org/apache/spark/sql/execution/adaptive/AdaptiveSparkPlanExec.scala`

```scala
// AdaptiveSparkPlanExec.scala
// AQE 在每个 Stage 完成后重新优化剩余 Stage
override def doExecute(): RDD[InternalRow] = {
  // 1. 提交初始 Stage
  // 2. 等待 Stage 完成
  // 3. 收集运行时统计（shuffle 分区大小、数据量）
  // 4. 重新优化逻辑计划
  // 5. 生成新的物理计划
  // 6. 提交下一组 Stage
}
```

### 2.2 三大自适应策略

#### 策略1: CoalesceShufflePartitions（合并小分区）

```scala
// CoalesceShufflePartitions.scala
// 目标：将 200 个默认 shuffle 分区根据实际数据量合并
// 关键参数：
//   spark.sql.adaptive.coalescePartitions.minPartitionSize = 1MB (默认)
//   spark.sql.adaptive.advisoryPartitionSizeInBytes = 64MB (默认)
```

**K8s 影响**：
- K8s executor 内存固定（Pod limit），合并后的大分区可能导致 OOM
- YARN 可以通过 `spark.executor.memoryOverhead` 灵活调整，K8s 受 cgroup 硬限制

#### 策略2: OptimizeSkewedJoin（倾斜处理）

```scala
// OptimizeSkewedJoin.scala
// 检测 shuffle 分区倾斜，自动拆分大分区
// 关键参数：
//   spark.sql.adaptive.skewJoin.skewedPartitionFactor = 5 (默认)
//   spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes = 256MB (默认)
```

**K8s 影响**：
- 倾斜处理会动态增加 task 数量
- K8s 如果 `dynamicAllocation.maxExecutors` 设得低，新 task 要排队
- YARN 的 ESS 本地读取倾斜分区更快，K8s + Celeborn 是远程读取

#### 策略3: DemoteBroadcastHashJoin（降级广播 Join）

```scala
// DemoteBroadcastHashJoin.scala
// 运行时发现实际数据量大于阈值，降级为 SortMergeJoin
// 关键参数：
//   spark.sql.adaptive.autoBroadcastJoinThreshold = 与 spark.sql.autoBroadcastJoinThreshold 一致
```

### 2.3 K8s 特有的 AQE 影响

#### 问题1: Stage 间的 Shuffle 数据传输

```
YARN + ESS:
  Stage 1 → Shuffle Write → 本地磁盘 → ESS 管理
  Stage 2 → Shuffle Read → ESS 本地/远程读取

K8s + Celeborn:
  Stage 1 → Shuffle Write → Celeborn Worker (网络传输)
  Stage 2 → Shuffle Read → Celeborn Worker (网络传输)
  
K8s + 本地 Shuffle:
  Stage 1 → Shuffle Write → Pod emptyDir/hostPath
  Stage 2 → Shuffle Read → 本地磁盘（但 Pod 可能被调度到不同 Node！）
```

**AQE 重新优化后如果增加了 Shuffle Stage**，K8s 的额外网络开销会被放大。

#### 问题2: Executor 弹性伸缩与 AQE 配合

```
AQE 合并分区 → task 数减少 → executor 空闲
→ dynamicAllocation 回收 executor
→ 下一个 Stage 需要更多 executor → 重新扩容

K8s 扩容（Pod 创建）: ~30-60s
YARN 扩容（Container 分配）: ~5-15s
```

**AQE 频繁调整并行度时，K8s 的 Pod 创建延迟会成为瓶颈。**

## 三、K8s 环境 AQE 调优建议

### 3.1 必调参数

```properties
# 1. 合并分区的最小大小 — K8s 适当调大，避免小 task 太多导致 Pod 启停频繁
spark.sql.adaptive.coalescePartitions.minPartitionSize=4MB

# 2. 建议分区大小 — 和 executor 内存匹配
spark.sql.adaptive.advisoryPartitionSizeInBytes=128MB

# 3. 初始 shuffle 分区数 — K8s 设大一些让 AQE 有合并空间
spark.sql.shuffle.partitions=500

# 4. 禁止 AQE 频繁收缩并行度（避免触发 Pod 回收→重建循环）
spark.dynamicAllocation.executorIdleTimeout=120
```

### 3.2 K8s + Celeborn 场景的特殊调优

```properties
# Celeborn Shuffle 下，AQE 的 coalesce 不走本地磁盘
# 合并后的大分区通过 Celeborn 远程读取，适当控制大小
spark.sql.adaptive.advisoryPartitionSizeInBytes=64MB

# Celeborn 支持的最大分区数
spark.celeborn.client.spark.shuffle.partition.max=5000
```

### 3.3 防止 AQE + 动态分配的"震荡"

```properties
# 问题: AQE 减少并行度 → idle executor → 被回收 → 下轮又要扩
# 解决: 增大 idle timeout + 设置最小 executor 数
spark.dynamicAllocation.minExecutors=20
spark.dynamicAllocation.executorIdleTimeout=180
spark.dynamicAllocation.cachedExecutorIdleTimeout=600
```

## 四、实战验证方法

### 4.1 确认 AQE 是否生效

```sql
-- Spark SQL 执行后查看
EXPLAIN ADAPTIVE SELECT ...;
-- 或在 Spark UI > SQL Tab > 查看是否有 "Adaptive Query Execution" 标记
```

### 4.2 对比 AQE 开/关的性能

```bash
# 关闭 AQE
spark.sql.adaptive.enabled=false
# 对比同一条 SQL 的 Stage 数、Task 数、总耗时

# 关键观察点:
# 1. Stage 数是否因为 AQE 增加了?（意味着多了 Shuffle）
# 2. 合并后的分区是否导致了 OOM?
# 3. 动态分配的 executor 数曲线是否有"锯齿"形震荡?
```

## 五、源码关键文件索引

| 文件 | 内容 |
|------|------|
| `AdaptiveSparkPlanExec.scala` | AQE 核心执行引擎 |
| `CoalesceShufflePartitions.scala` | 分区合并策略 |
| `OptimizeSkewedJoin.scala` | 倾斜处理策略 |
| `DemoteBroadcastHashJoin.scala` | 广播降级策略 |
| `ShufflePartitionsUtil.scala` | 分区大小计算工具 |
| `CelebornShuffleReader.scala` | Celeborn 读取路径 |
| `ExecutorAllocationManager.scala` | 动态分配管理 |

---

*Spark Expert 学习产出 | 2026-04-08 | 来源：K8s vs YARN 案例延伸*
