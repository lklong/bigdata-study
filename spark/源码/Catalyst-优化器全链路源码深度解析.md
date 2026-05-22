# Spark Catalyst 优化器全链路源码深度解析

> 版本: Spark 3.4 系
> 源码路径: `/Users/kailongliu/bigdata/txProjects/spark`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

一条 Spark SQL 从 `spark.sql("select ...")` 提交，到最终生成 RDD 执行，**中间发生了什么？**
SparkSQL 之所以能高性能，核心是 Catalyst —— 一个基于规则的优化器（RBO）+ 基于代价的优化器（CBO）框架。
理解 Catalyst 是理解 Spark SQL 调优、AQE、Iceberg/Hudi 自定义规则的前置条件。

## 二、五阶段调用链（一图全览）

```
spark.sql("...")
   │
   ▼
[1] Parser           SparkSqlParser.parsePlan         → Unresolved LogicalPlan
   │                 (ANTLR4 grammar)
   ▼
[2] Analyzer         Analyzer.executeAndCheck         → Resolved LogicalPlan
   │                 (绑定 Catalog、Schema、UDF)
   ▼
[3] Optimizer        SparkOptimizer.executeAndTrack   → Optimized LogicalPlan
   │                 (RBO 100+ 规则 + CBO Join Reorder)
   ▼
[4] SparkPlanner     planner.plan(ReturnAnswer(plan)) → SparkPlan (Physical)
   │                 (Strategy 模式选物理算子)
   ▼
[5] prepareForExecution                              → Executable SparkPlan
   │                 (插入 Exchange、Codegen、AQE)
   ▼
   executedPlan.execute()                            → RDD[InternalRow]
```

**总入口源码**: `QueryExecution.scala` (sql/core/src/main/scala/org/apache/spark/sql/execution/QueryExecution.scala)

## 三、关键源码逐段精读

### 3.1 五个 lazy val —— 链式触发的精髓

`QueryExecution.scala:74-160`：

```scala
lazy val analyzed: LogicalPlan = executePhase(QueryPlanningTracker.ANALYSIS) {
  sparkSession.sessionState.analyzer.executeAndCheck(logical, tracker)
}

lazy val optimizedPlan: LogicalPlan = {
  assertCommandExecuted()
  executePhase(QueryPlanningTracker.OPTIMIZATION) {
    val plan = sparkSession.sessionState.optimizer.executeAndTrack(
                 withCachedData.clone(), tracker)
    plan.setAnalyzed()
    plan
  }
}

lazy val sparkPlan: SparkPlan = {
  assertOptimized()
  executePhase(QueryPlanningTracker.PLANNING) {
    QueryExecution.createSparkPlan(sparkSession, planner, optimizedPlan.clone())
  }
}

lazy val executedPlan: SparkPlan = {
  assertOptimized()
  executePhase(QueryPlanningTracker.PLANNING) {
    QueryExecution.prepareForExecution(preparations, sparkPlan.clone())
  }
}
```

**设计意图**：用 Scala `lazy val` 实现"按需触发，结果缓存"。`Dataset.collect()` 才会真正触发 `toRdd`，五阶段才会全部跑完，否则只是构建了一个"懒计算 DAG"。

**踩坑点**：每个阶段都对 plan 做了 `clone()`，这是**必须的** —— 因为 LogicalPlan/SparkPlan 内部携带 expressionId、stats 等可变状态，不 clone 会导致下一阶段污染上一阶段的内存表示，调试 explain 时出现"幽灵字段"。

### 3.2 RuleExecutor —— Catalyst 引擎的心脏

`RuleExecutor.scala:114-272` 抽象类，Analyzer/Optimizer 都继承它：

```scala
abstract class RuleExecutor[TreeType <: TreeNode[_]] extends Logging {

  abstract class Strategy { def maxIterations: Int }
  case object Once extends Strategy { val maxIterations = 1 }   // 只跑一次
  case class FixedPoint(maxIterations: Int) extends Strategy    // 跑到不动点

  protected case class Batch(name: String, strategy: Strategy, rules: Rule[TreeType]*)
  protected def batches: Seq[Batch]   // 子类必须实现

  def execute(plan: TreeType): TreeType = {
    var curPlan = plan
    batches.foreach { batch =>                          // 外层：按 Batch 顺序
      var iteration = 1
      var lastPlan = curPlan
      var continue = true
      while (continue) {                                // 中层：FixedPoint 迭代
        curPlan = batch.rules.foldLeft(curPlan) {       // 内层：Batch 内规则按顺序
          case (plan, rule) =>
            val startTime = System.nanoTime()
            val result = rule(plan)                     // ← 真正的规则应用
            val effective = !result.fastEquals(plan)
            if (effective) planChangeLogger.logRule(rule.ruleName, plan, result)
            queryExecutionMetrics.incExecutionTimeBy(rule.ruleName, runTime)
            result
        }
        iteration += 1
        if (iteration > batch.strategy.maxIterations) continue = false
        if (curPlan.fastEquals(lastPlan)) {             // 不动点判定
          logTrace(s"Fixed point reached for batch ${batch.name} after ${iteration - 1} iterations.")
          continue = false
        }
        lastPlan = curPlan
      }
    }
    curPlan
  }
}
```

**三层循环（三层嵌套）—— 这是 Catalyst 的灵魂**：
1. **Batches**（顺序）：阶段化，比如先跑"Operator Optimization"再跑"Join Reorder"
2. **Iteration**（FixedPoint 不动点）：同一个 Batch 反复跑直到 plan 不再变（`fastEquals`）
3. **Rules**（顺序应用）：Batch 内规则一个个 fold

**设计意图**：FixedPoint 是因为规则之间会**互相触发**。比如 `PushDownPredicate` 把谓词下推后，可能让 `ConstantFolding` 又有新机会触发；或者 `CombineFilters` 合并后，`PruneFilters` 又能消除。所以必须迭代到收敛。

**配置点**：`spark.sql.optimizer.maxIterations`（默认 100），到达上限会 WARN 但不报错（除非 testing 模式）。**生产中如果看到 "Max iterations (100) reached for batch Operator Optimization" 警告，说明规则陷入震荡或 plan 过于复杂，可考虑调大或排查规则冲突。**

### 3.3 Optimizer 默认 Batch 列表（RBO 全貌）

`Optimizer.scala:78-246`，关键 Batch 顺序：

```
1.  Eliminate Distinct                Once    EliminateDistinct
2.  Finish Analysis                   Once    EliminateResolvedHint, ComputeCurrentTime, ...
3.  Inline CTE                        Once    InlineCTE
4.  Union                             Once    RemoveNoopOperators, CombineUnions
5.  OptimizeLimitZero                 Once
6.  LocalRelation early               FixedPt ConvertToLocalRelation, PropagateEmptyRelation
7.  Pullup Correlated Expressions     Once    PullupCorrelatedPredicates
8.  Subquery                          FixedPt(1) OptimizeSubqueries
9.  Replace Operators                 FixedPt RewriteExceptAll, ReplaceIntersectWithSemiJoin, ...
10. Aggregate                         FixedPt RemoveLiteralFromGroupExpressions
11. ★ Operator Optimization (核心)    FixedPt 60+ 规则（见下）
12. Infer Filters                     Once    InferFiltersFromConstraints  ← 谓词推断
13. Operator Optimization (二轮)       FixedPt
14. Push extra predicate through join FixedPt
15. Pre CBO Rules                     Once
16. Early Filter and Projection Push-Down  Once  V2ScanRelationPushDown, SchemaPruning, ...
17. ★ Join Reorder (CBO)              FixedPt(1) CostBasedJoinReorder
18. Eliminate Sorts                   Once
19. Decimal Optimizations             FixedPt
20. Distinct Aggregate Rewrite        Once
21. RewriteSubquery                   Once    RewritePredicateSubquery
```

**11 号 Operator Optimization 内的 60+ 规则**（最高频应用）：

| 类别 | 关键规则 | 作用 |
|------|---------|------|
| **谓词下推** | PushDownPredicates, PushDownLeftSemiAntiJoin | 把 Filter 推到 Scan 附近 |
| **列裁剪** | ColumnPruning | 砍掉用不到的列 |
| **算子下推** | PushProjectionThroughUnion, LimitPushDown | Project/Limit 下推 |
| **算子合并** | CollapseProject, CombineFilters, CombineUnions | 相邻同类算子合并 |
| **常量折叠** | ConstantFolding, NullPropagation, ConstantPropagation | 1+1 → 2，null 传播 |
| **布尔简化** | BooleanSimplification, SimplifyConditionals | a AND TRUE → a |
| **消除冗余** | RemoveNoopOperators, EliminateLimits, RemoveRedundantAliases | 删掉 no-op |
| **Join 优化** | ReorderJoin, EliminateOuterJoin | Inner Join 重排，Outer→Inner |
| **强度削减** | UnwrapCastInBinaryComparison, OptimizeIn | cast 消除、IN→equal |

### 3.4 SparkOptimizer —— Catalyst 之上的 Spark 增强

`SparkOptimizer.scala:32-93`：

```scala
class SparkOptimizer(catalogManager, catalog, experimentalMethods)
    extends Optimizer(catalogManager) {

  override def earlyScanPushDownRules: Seq[Rule[LogicalPlan]] =
    Seq(SchemaPruning) :+
      GroupBasedRowLevelOperationScanPlanning :+
      V2ScanRelationPushDown :+              // ← DataSource V2 谓词/列下推
      V2ScanPartitioning :+
      V2Writes :+
      PruneFileSourcePartitions              // ← Hive 分区裁剪入口

  override def defaultBatches: Seq[Batch] = (preOptimizationBatches ++
    super.defaultBatches :+
    Batch("PartitionPruning", Once, PartitionPruning) :+        // ← 动态分区裁剪 DPP
    Batch("InjectRuntimeFilter", FixedPoint(1),
      InjectRuntimeFilter,                                       // ← 运行时过滤（Bloom Filter）
      RewritePredicateSubquery) :+
    Batch("MergeScalarSubqueries", Once, MergeScalarSubqueries) :+
    ...
}
```

**重要的两个增强**：
1. **PartitionPruning（DPP - Dynamic Partition Pruning）**：Spark 3.0+ 引入，针对星型 schema 大表 join 小表场景，把小表过滤后的 join key 当作大表的分区过滤条件运行时下推。**关键参数**：`spark.sql.optimizer.dynamicPartitionPruning.enabled=true`（默认开）。
2. **InjectRuntimeFilter**：Spark 3.3+，类似 Bloom Filter 提前过滤大表。**关键参数**：`spark.sql.optimizer.runtime.bloomFilter.enabled=false`（默认关，需要业务方主动开）。

### 3.5 PlanChangeLogger —— 每条规则的可观测性

`RuleExecutor.scala:47-112`：

```scala
class PlanChangeLogger[TreeType] extends Logging {
  private val logLevel = SQLConf.get.planChangeLogLevel

  def logRule(ruleName: String, oldPlan, newPlan): Unit = {
    if (!newPlan.fastEquals(oldPlan)) {
      def message(): String = s"""
         |=== Applying Rule $ruleName ===
         |${sideBySide(oldPlan.treeString, newPlan.treeString).mkString("\n")}
       """
      logBasedOnLevel(message)
    }
  }
}
```

**实战调优技巧**：把 `spark.sql.planChangeLog.level=INFO`，可以在日志里看到**每条规则前后的 plan 对比**，定位"我的查询为啥不下推/不裁剪"立刻能找到罪魁祸首规则。生产慎开（日志爆炸）。

## 四、CBO 部分 —— Join Reorder 的代价模型

`CostBasedJoinReorder` 位于 `Batch("Join Reorder", FixedPoint(1), CostBasedJoinReorder)`，**但只有满足以下条件才生效**：

1. `spark.sql.cbo.enabled = true`（默认 false，需要 ANALYZE TABLE 后开启）
2. `spark.sql.cbo.joinReorder.enabled = true`
3. 参与 join 的表必须有 `ANALYZE TABLE ... COMPUTE STATISTICS FOR COLUMNS` 收集的列统计

**核心思想**（动态规划，DPsize 算法）：
- 枚举 N 张表的所有 join 顺序（N≤12 默认上限），用代价函数 `cost = weight * card + (1-weight) * size` 评估
- `card`（cardinality）= 估算行数，`size` = 估算字节数
- 选总代价最小的 plan

**踩坑警告**：CBO 在生产中默认关闭不是没原因 —— **统计信息更新成本 + 估算偏差**导致很多场景反而退化。建议生产先评估再开。

## 五、实战 LOG 对齐验证

提交一个 SQL 后，开启 `spark.sql.planChangeLog.level=INFO`，会看到形如：

```
=== Applying Rule org.apache.spark.sql.catalyst.optimizer.PushDownPredicates ===
 Filter (a > 10)                              Project [a, b]
 +- Project [a, b]              becomes      +- Filter (a > 10)
    +- Relation[a, b, c]                        +- Relation[a, b, c]

=== Applying Rule org.apache.spark.sql.catalyst.optimizer.ColumnPruning ===
 Project [a, b]                               Project [a, b]
 +- Filter (a > 10)             becomes      +- Filter (a > 10)
    +- Relation[a, b, c]                        +- Relation[a, b]   ← c 列被裁掉
```

**对齐源码**：上面 `Applying Rule` 字符串就是 `RuleExecutor.scala:60` `s"=== Applying Rule $ruleName ==="` 输出的。

## 六、设计意图总结

| 设计 | 为什么这样 |
|------|-----------|
| 五阶段 lazy val | 按需触发 + 中间结果缓存，便于 explain 调试，符合"懒计算 DAG"理念 |
| RuleExecutor 三层循环 | Batch 阶段化 / FixedPoint 不动点 / Rule 顺序应用 —— 解决规则间互相触发问题 |
| 每阶段 clone() plan | 避免可变状态污染，让阶段间隔离（典型纯函数编程范式） |
| Rule 模式（Tree Transform） | 让优化规则是**纯函数 + 无副作用**，可任意组合、可单测 |
| Strategy 模式选物理算子 | 同一逻辑算子（Join）有多种物理实现（BHJ/SHJ/SMJ），由 Strategy 决策 |
| AQE 插桩点 | `prepareForExecution` 中的 `InsertAdaptiveSparkPlan` 把整个 plan 包成 `AdaptiveSparkPlanExec`，运行时根据 stats 动态调整 |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `spark.sql.optimizer.maxIterations` | 100 | RuleExecutor FixedPoint 上限 |
| `spark.sql.optimizer.excludedRules` | 空 | 黑名单规则（除 nonExcludable 外） |
| `spark.sql.cbo.enabled` | false | CBO 总开关 |
| `spark.sql.cbo.joinReorder.enabled` | false | CBO Join 重排 |
| `spark.sql.cbo.joinReorder.dp.threshold` | 12 | DP 算法处理表数上限 |
| `spark.sql.optimizer.dynamicPartitionPruning.enabled` | true | DPP |
| `spark.sql.optimizer.runtime.bloomFilter.enabled` | false | 运行时 Bloom Filter |
| `spark.sql.adaptive.enabled` | true (3.2+) | AQE 总开关 |
| `spark.sql.planChangeLog.level` | trace | 规则变更日志级别 |
| `spark.sql.planChangeLog.rules` | 空 | 只看哪些规则的变更（白名单） |

## 八、踩坑记录

1. **`spark.sql.optimizer.excludedRules` 不能排除 nonExcludable 规则** —— 比如 `RewriteDistinctAggregates`。`Optimizer.scala:387-419` 强制保留这些规则，即使你列在排除名单里也无效，会有 WARN。
2. **CTE 重复计算** —— 默认 `Inline CTE` Batch 会内联所有 CTE，可能导致同一子查询多次扫描。Spark 3.4 引入了 `WithCTE` 节点和 `ReplaceCTERefWithRepartition` 规则缓解，但**只对最末尾的 SparkOptimizer 那条 batch 生效**。要让 CTE 真正物化，得用 `cache()` 或 `repartition`。
3. **`fastEquals` vs `equals`** —— 不动点判定用的是 `fastEquals`（基于 reference 比较 + tree id），不会做深度结构比较。某些规则返回的虽然结构相同但 expressionId 不同的 plan，仍会被判定为"变化"，导致死循环。**写自定义规则时务必保持幂等且 ID 稳定。**

## 九、认知更新（这次精读的新收获）

- 之前以为 Optimizer 是"一遍就过"的，**实际上 Operator Optimization Batch 跑两遍**（Infer Filters 前后各一次），且每遍都跑到不动点（最多 100 轮）。
- 之前以为 RBO 和 CBO 是平行的，实际上**CBO（Join Reorder）是作为一个 Batch 嵌在 RBO 流水线中间**的，且只跑一次（FixedPoint(1)）。
- `PartitionPruning` 在 `Batch("PartitionPruning", Once, ...)`，只跑一次 —— 但它内部会**插入 DynamicPruningSubquery 节点**，等到运行时才能执行，所以"分区裁剪"在编译期决定 + 运行期生效。

## 十、下一步深挖方向

- [ ] AQE 的 `AdaptiveSparkPlanExec.replan()` 重规划机制
- [ ] WholeStageCodegen 字节码生成（CollapseCodegenStages）
- [ ] V2ScanRelationPushDown 的 SupportsPushDownFilters/Aggregates 协议

---

**沉淀完成。源码证据完整，可作为团队 Catalyst 培训和故障排查参考资料。**
