# Spark 07 — Catalyst 优化器 Rule 体系与 Batch 执行框架源码深度分析

> 源码版本：Apache Spark 4.0.0-SNAPSHOT（本地路径 `/Users/kailongliu/bigdata/txProjects/spark/`）
> 分析日期：2026-04-27
> 作者：Eric（豹纹） | 大哥的 SRE AI 专家团队

---

## 一、概述

Spark SQL 的 Catalyst 优化器是整个 SQL 引擎的核心，包含 **50+ 条优化规则**，通过 **Batch 执行框架** 按顺序和策略应用这些规则。本篇从源码层面深度剖析：

1. **Rule 与 RuleExecutor** — 规则基础框架
2. **Optimizer** — 优化器的 Batch 组织与执行顺序
3. **核心优化规则分类** — 算子下推、常量折叠、连接重排、子查询优化
4. **执行策略** — Once vs FixedPoint
5. **扩展机制** — 如何添加自定义优化规则

---

## 二、Rule 基础框架

### 2.1 Rule 抽象类

**文件**：`catalyst/.../rules/Rule.scala`

```scala
abstract class Rule[TreeType <: TreeNode[_]] extends Logging {
  val ruleName: String = this.getClass.getSimpleName  // 规则名称
  def apply(plan: TreeType): TreeType                   // 核心方法：树变换
}
```

**设计要点**：
- 每条 Rule 是一个**树变换函数**：接收 LogicalPlan，返回优化后的 LogicalPlan
- 规则是**无状态的**，相同输入永远产生相同输出
- 规则可以通过 `TreeNode.transform` / `TreeNode.transformDown` 递归遍历和修改计划树

### 2.2 RuleExecutor — 规则执行器

**文件**：`catalyst/.../rules/RuleExecutor.scala`

```scala
abstract class RuleExecutor[TreeType <: TreeNode[_]] {
  // Batch = 一组规则 + 执行策略
  case class Batch(name: String, strategy: Strategy, rules: Rule[TreeType]*)
  
  // 执行策略
  abstract class Strategy { def maxIterations: Int }
  case object Once extends Strategy { val maxIterations = 1 }
  case class FixedPoint(override val maxIterations: Int) extends Strategy
  
  // 核心执行方法
  def execute(plan: TreeType): TreeType = {
    batches.foreach { batch =>
      var iteration = 1
      var curPlan = plan
      var lastPlan = curPlan
      while (iteration <= batch.strategy.maxIterations) {
        batch.rules.foreach { rule =>
          curPlan = rule.apply(curPlan)
        }
        if (curPlan.fastEquals(lastPlan)) {
          // 达到不动点，提前退出
          return curPlan
        }
        lastPlan = curPlan
        iteration += 1
      }
    }
  }
}
```

### 2.3 执行策略

| 策略 | 说明 | 适用场景 |
|------|------|---------|
| `Once` | 只执行一次 | 确定性变换、不需要迭代 |
| `FixedPoint(N)` | 重复执行直到计划不再变化或达到 N 次 | 规则之间有依赖，需要多轮收敛 |

**FixedPoint 的不动点语义**：当一轮执行后计划没有变化（`fastEquals`），认为已收敛，提前退出。这是 Catalyst 的核心优化——避免无用的重复变换。

---

## 三、Optimizer — 优化器 Batch 组织

### 3.1 源码定位

**文件**：`catalyst/.../optimizer/Optimizer.scala`（100.83 KB，Spark 最大的单文件之一）

```scala
abstract class Optimizer(catalogManager: CatalogManager)
  extends RuleExecutor[LogicalPlan] {
  
  def defaultBatches: Seq[Batch] = { ... }  // 定义所有默认优化 Batch
}
```

### 3.2 完整 Batch 执行顺序

```
Phase 1: 预处理
├── Batch "Eliminate Distinct"          (Once)
├── Batch "Finish Analysis"             (Once)
│
Phase 2: CTE 与 Union 优化
├── Batch "Inline CTE"                  (Once)
├── Batch "Union"                       (Once)
├── Batch "OptimizeLimitZero"           (Once)
│
Phase 3: 早期简化
├── Batch "LocalRelation early"         (FixedPoint)
├── Batch "Pullup Correlated Expressions" (Once)
├── Batch "Subquery"                    (FixedPoint(1))
│
Phase 4: 算子替换
├── Batch "Replace Operators"           (FixedPoint)
├── Batch "Aggregate"                   (FixedPoint)
│
Phase 5: 算子优化（核心，执行两轮）
├── Batch "Operator Optimization before Inferring Filters"  (FixedPoint)
│   ├── PushProjectionThroughUnion      ← 投影下推
│   ├── ReorderJoin                     ← 连接重排序
│   ├── EliminateOuterJoin              ← 消除外连接
│   ├── PushDownPredicates              ← 谓词下推
│   ├── ColumnPruning                   ← 列裁剪
│   ├── CollapseProject                 ← 合并投影
│   ├── CombineFilters                  ← 合并过滤
│   ├── ConstantFolding                 ← 常量折叠
│   ├── BooleanSimplification           ← 布尔简化
│   ├── SimplifyCasts                   ← 简化类型转换
│   ├── UnwrapCastInBinaryComparison    ← 解包比较中的 Cast
│   └── ... (共 30+ 条规则)
│
├── Batch "Infer Filters"              (Once)
│   ├── InferFiltersFromGenerate
│   └── InferFiltersFromConstraints
│
├── Batch "Operator Optimization after Inferring Filters"  (FixedPoint)
│   └── (同上 30+ 条规则，第二轮)
│
├── Batch "Push extra predicate through join"  (FixedPoint)
│
Phase 6: 后期优化
├── Batch "Clean Up Temporary CTE Info" (Once)
├── Batch "Pre CBO Rules"              (Once)
├── Batch "Early Filter and Projection Push-Down" (Once)
├── Batch "Update CTE Relation Stats"  (Once)
├── Batch "Join Reorder"               (FixedPoint(1))    ← CBO 连接重排序
├── Batch "Eliminate Sorts"             (Once)
├── Batch "Decimal Optimizations"       (FixedPoint)
├── Batch "Distinct Aggregate Rewrite"  (Once)
├── Batch "Object Expressions Optimization" (FixedPoint)
├── Batch "LocalRelation"              (FixedPoint)
├── Batch "Optimize One Row Plan"       (FixedPoint)
├── Batch "Check Cartesian Products"    (Once)
│
Phase 7: 子查询重写
├── Batch "RewriteSubquery"            (Once)
├── Batch "NormalizeFloatingNumbers"    (Once)
└── Batch "ReplaceUpdateFieldsExpression" (Once)
```

---

## 四、核心优化规则分类

### 4.1 算子下推类（Operator Push Down）

| 规则 | 功能 | 性能影响 |
|------|------|---------|
| `PushDownPredicates` | 将 Filter 下推到离数据源最近的位置 | ⭐⭐⭐⭐⭐ 减少扫描数据量 |
| `PushProjectionThroughUnion` | 将 Project 下推到 Union 子节点 | ⭐⭐⭐ 减少中间数据量 |
| `PushDownLeftSemiAntiJoin` | 将 LeftSemi/LeftAnti Join 下推 | ⭐⭐⭐ 减少 Join 输入 |
| `ColumnPruning` | 裁剪不需要的列 | ⭐⭐⭐⭐ 减少 IO 和内存 |
| `LimitPushDown` | 将 Limit 下推到子节点 | ⭐⭐⭐ 减少计算量 |

**谓词下推示例**：
```
优化前:                         优化后:
Filter(age > 18)               Scan(table, pushdown: age > 18)
  └── Scan(table)              
```

### 4.2 常量折叠类（Constant Folding）

| 规则 | 功能 | 示例 |
|------|------|------|
| `ConstantFolding` | 编译期计算常量表达式 | `1 + 2` → `3` |
| `ConstantPropagation` | 传播已知常量值 | `a = 1 AND b = a` → `a = 1 AND b = 1` |
| `NullPropagation` | 传播 NULL 值 | `NULL + 1` → `NULL` |
| `FoldablePropagation` | 传播可折叠表达式 | 别名引用的常量 |
| `BooleanSimplification` | 简化布尔表达式 | `true AND x` → `x` |

### 4.3 算子合并类（Operator Combine）

| 规则 | 功能 |
|------|------|
| `CombineFilters` | 合并相邻 Filter：`Filter(a) → Filter(b)` → `Filter(a AND b)` |
| `CollapseProject` | 合并相邻 Project |
| `CollapseRepartition` | 合并相邻 Repartition |
| `CollapseWindow` | 合并窗口函数 |
| `CombineUnions` | 合并嵌套 Union |
| `CombineConcats` | 合并字符串 Concat |

### 4.4 连接优化类（Join Optimization）

| 规则 | 功能 | 说明 |
|------|------|------|
| `ReorderJoin` | 基于启发式的连接重排序 | 将有条件的 Join 排在前面 |
| `EliminateOuterJoin` | 消除不必要的外连接 | 外连接 + 非空条件 → 内连接 |
| `CostBasedJoinReorder` | 基于统计信息的 CBO 连接重排序 | 需要表统计信息 |
| `PushExtraPredicateThroughJoin` | 推导额外的 Join 谓词 | 利用等值条件传递 |

### 4.5 子查询优化类

| 规则 | 功能 |
|------|------|
| `RewriteCorrelatedScalarSubquery` | 将关联标量子查询重写为 Join |
| `RewritePredicateSubquery` | 将 EXISTS/IN 子查询重写为 Semi/Anti Join |
| `RewriteLateralSubquery` | 重写 Lateral 子查询 |
| `PullupCorrelatedPredicates` | 上拉关联谓词 |
| `MergeScalarSubqueries` | 合并相同的标量子查询 |
| `OptimizeSubqueries` | 递归优化子查询计划 |

---

## 五、不可排除规则（Non-Excludable Rules）

某些规则对正确性至关重要，即使用户通过 `spark.sql.optimizer.excludedRules` 配置排除规则也不会被跳过：

```scala
def nonExcludableRules: Seq[String] =
  FinishAnalysis.ruleName ::
  RewriteDistinctAggregates.ruleName ::
  ReplaceDeduplicateWithAggregate.ruleName ::
  ReplaceIntersectWithSemiJoin.ruleName ::
  ReplaceExceptWithFilter.ruleName ::
  NormalizeFloatingNumbers.ruleName ::
  PullupCorrelatedPredicates.ruleName ::
  RewriteCorrelatedScalarSubquery.ruleName ::
  RewritePredicateSubquery.ruleName :: ...
```

**设计意图**：这些规则要么是语义必需的（如 `ReplaceDeduplicateWithAggregate`），要么是安全相关的（如 `NormalizeFloatingNumbers`），不允许用户误关闭。

---

## 六、扩展机制

### 6.1 SparkSessionExtensions

```scala
// 用户自定义优化规则
spark.experimental.extraOptimizations ++= Seq(MyCustomRule)

// 或通过 Extensions API
class MyExtensions extends (SparkSessionExtensions => Unit) {
  override def apply(extensions: SparkSessionExtensions): Unit = {
    extensions.injectOptimizerRule { session =>
      MyCustomRule(session)
    }
  }
}
```

### 6.2 Kyuubi 的 Spark Extension

Kyuubi 通过 `KyuubiSparkSQLExtension` 注入了自己的优化规则：

```scala
// kyuubi-extension-spark-3-5/.../KyuubiSparkSQLExtension.scala
class KyuubiSparkSQLExtension extends (SparkSessionExtensions => Unit) {
  override def apply(extensions: SparkSessionExtensions): Unit = {
    extensions.injectOptimizerRule(KyuubiEnsureRequirements)
    extensions.injectOptimizerRule(KyuubiQueryStagePreparation)
    // ... Shuffle 重排、动态分区等
  }
}
```

---

## 七、运维关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.sql.optimizer.maxIterations` | `100` | FixedPoint 最大迭代次数 |
| `spark.sql.optimizer.excludedRules` | `(空)` | 需要排除的优化规则（逗号分隔） |
| `spark.sql.cbo.enabled` | `false` | 是否启用 CBO 优化 |
| `spark.sql.cbo.joinReorder.enabled` | `false` | 是否启用 CBO 连接重排序 |
| `spark.sql.planChangeLog.level` | `(不记录)` | 记录计划变更的日志级别 |
| `spark.sql.planChangeLog.rules` | `(全部)` | 记录哪些规则的计划变更 |
| `spark.sql.planChangeLog.batches` | `(全部)` | 记录哪些 Batch 的计划变更 |

### 7.1 调试技巧

```scala
// 查看优化前后的计划对比
spark.conf.set("spark.sql.planChangeLog.level", "WARN")
spark.sql("SELECT * FROM t WHERE 1=1").explain(true)
```

---

## 八、性能影响排行

基于生产环境经验，对查询性能影响最大的优化规则 Top 10：

| 排名 | 规则 | 影响 | 说明 |
|------|------|------|------|
| 1 | `PushDownPredicates` | ⭐⭐⭐⭐⭐ | 减少数据扫描量 |
| 2 | `ColumnPruning` | ⭐⭐⭐⭐⭐ | 减少列读取 |
| 3 | `ConstantFolding` | ⭐⭐⭐⭐ | 消除运行时计算 |
| 4 | `CostBasedJoinReorder` | ⭐⭐⭐⭐ | 优化多表连接顺序 |
| 5 | `EliminateOuterJoin` | ⭐⭐⭐ | 减少不必要的外连接 |
| 6 | `RewriteCorrelatedScalarSubquery` | ⭐⭐⭐ | 消除关联子查询 |
| 7 | `PropagateEmptyRelation` | ⭐⭐⭐ | 短路空结果计划 |
| 8 | `CombineFilters` | ⭐⭐ | 减少算子数量 |
| 9 | `CollapseProject` | ⭐⭐ | 减少投影层级 |
| 10 | `SimplifyCasts` | ⭐⭐ | 消除冗余类型转换 |

---

## 九、跨项目同构对比

| 特性 | Spark Catalyst | Calcite (Hive/Flink) | Trino (Cost-based) |
|------|---------------|---------------------|-------------------|
| 规则框架 | Rule + RuleExecutor | RelOptRule + HepPlanner/VolcanoPlanner | PlanOptimizer + Rule |
| 执行策略 | Batch (Once/FixedPoint) | HepProgram / VolcanoPlanner | 多阶段优化 |
| 规则数量 | 50+ | 200+ | 80+ |
| CBO | 可选（spark.sql.cbo.enabled） | 内置 VolcanoPlanner | **默认启用** |
| 可扩展 | ✅ Extensions API | ✅ 注册自定义 Rule | ✅ Plugin API |
| 子查询 | 重写为 Join | 重写为 Join | 内建支持 |

---

> **认知更新**：Catalyst 的 Batch 执行框架本质上是一个**迭代不动点求解器** — 将优化问题建模为"反复应用变换规则直到计划不再变化"。FixedPoint 策略保证了收敛性（最多 100 次迭代），而 `fastEquals` 检测保证了效率（提前退出）。理解这个框架后，所有优化规则都可以用统一的视角来看待：它们都是"LogicalPlan → LogicalPlan"的纯函数变换。
