# Spark SQL / Catalyst / AQE 源码分析

## 一、SQL 执行链路 (QueryExecution 的 lazy val 链)

```
SQL String → Parser → Unresolved LogicalPlan
  → Analyzer → Resolved LogicalPlan        [lazy val analyzed]
  → Command Execution                       [lazy val commandExecuted]
  → Cache Manager                           [lazy val withCachedData]
  → Optimizer (60+ 规则)                    [lazy val optimizedPlan]
  → Planner (逻辑→物理)                     [lazy val sparkPlan]
  → Preparations (12 条规则)                 [lazy val executedPlan]
  → RDD Execution                           [lazy val toRdd]
```

## 二、Preparations 规则链 (执行前最后准备)

```
InsertAdaptiveSparkPlan  → AQE 入口 (如果开启，后续规则不生效)
CoalesceBucketsInJoin    → 合并 bucket join
PlanDynamicPruningFilters → 动态分区裁剪
PlanSubqueries           → 子查询规划
RemoveRedundantProjects  → 移除冗余 Project
EnsureRequirements       → 插入 Shuffle/Sort 确保数据分布
ReplaceHashWithSortAgg   → Hash聚合 → Sort聚合
RemoveRedundantSorts     → 移除冗余排序
CollapseCodegenStages    → Whole-Stage CodeGen
ReuseExchangeAndSubquery → Exchange/子查询复用
```

## 三、AQE 核心执行流程

```
while (!allChildStagesMaterialized):
  1. createQueryStages: 自底向上遇 Exchange 创建 QueryStageExec
  2. Broadcast 优先提交，异步物化
  3. 等待 Stage 完成，收集运行时统计
  4. reOptimize: 逻辑重优化(AQEOptimizer) + 物理重规划
  5. costEvaluator: 新计划更优则采用

最终: optimizeQueryStage(isFinalStage=true) + CodeGen
```

### AQE 三层规则
- **queryStagePreparationRules**: 创建 Stage 前 (含 OptimizeSkewedJoin)
- **queryStageOptimizerRules**: 新 Stage 后 (CoalesceShufflePartitions, OptimizeSkewInRebalance)
- **postStageCreationRules**: 最终 (Columnar + CodeGen)

## 四、OptimizeSkewedJoin 倾斜处理

### 倾斜判断
```
isSkewed = partitionSize > max(medianSize × 5.0, 256MB)
```

### 处理方式
- 按 mapper 输出大小拆分倾斜分区为多个子分区
- 对侧数据复制到每个子分区
- 双侧倾斜时做笛卡尔积组合

### 支持的 Join 类型
- 可拆左侧: Inner, Cross, LeftSemi, LeftAnti, LeftOuter
- 可拆右侧: Inner, Cross, RightOuter

## 五、CoalesceShufflePartitions 合并小分区

```
targetSize = min(totalSize/minNumPartitions, advisorySize).max(minPartitionSize)

贪心算法: 累加连续分区到当前合并分区
  - 超过 targetSize → 开始新分区
  - 小于 minPartitionSize → 与相邻更小的分区合并
```

## 六、关键配置参数

### AQE 总开关
| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.sql.adaptive.enabled` | true | AQE 总开关 |
| `spark.sql.adaptive.forceApply` | false | 强制应用 AQE |

### 分区合并
| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.sql.adaptive.advisoryPartitionSizeInBytes` | 64MB | 建议分区大小 |
| `spark.sql.adaptive.coalescePartitions.enabled` | true | 合并小分区 |
| `spark.sql.adaptive.coalescePartitions.parallelismFirst` | true | 优先保障并行度 |
| `spark.sql.adaptive.coalescePartitions.minPartitionSize` | 1MB | 最小分区大小 |

### 数据倾斜
| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.sql.adaptive.skewJoin.enabled` | true | 倾斜优化开关 |
| `spark.sql.adaptive.skewJoin.skewedPartitionFactor` | 5.0 | 倾斜因子 |
| `spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes` | 256MB | 倾斜绝对阈值 |
| `spark.sql.adaptive.forceOptimizeSkewedJoin` | false | 即使引入额外 Shuffle 也强制优化 |

## 七、核心源码文件索引

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `execution/QueryExecution.scala` | 552 | SQL 执行链路全景，preparations 规则链 |
| `adaptive/AdaptiveSparkPlanExec.scala` | 887 | AQE 核心循环，createQueryStages，reOptimize |
| `adaptive/OptimizeSkewedJoin.scala` | 268 | 倾斜检测+拆分+笛卡尔组合 |
| `adaptive/CoalesceShufflePartitions.scala` | 205 | 小分区合并，分组逻辑 |
| `adaptive/ShufflePartitionsUtil.scala` | 412 | coalescePartitions 贪心算法，createSkewPartitionSpecs |
| `adaptive/QueryStageExec.scala` | 299 | Shuffle/Broadcast/TableCache Stage |
| `adaptive/AQEOptimizer.scala` | 77 | AQE 重优化规则批次 |
| `catalyst/optimizer/Optimizer.scala` | 2475 | Catalyst 60+ 优化规则 |
