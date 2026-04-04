# S09: CBO/RBO 优化器 — Calcite + Hive 规则优化源码深度分析

> **创建时间**: 2026-04-04
> **分析版本**: Apache Hive 3.x / 4.x
> **标签**: #Hive #CBO #RBO #Calcite #Optimizer #谓词下推 #列裁剪 #源码分析

---

## 一、优化器全景

```
Operator Tree (来自 SemanticAnalyzer)
  ↓
┌──────────────────────────────────────────────────────────────┐
│ 优化器管道 ← 本文聚焦                                         │
│                                                              │
│ ┌─ CBO 路径（hive.cbo.enable = true，默认）─────────────┐    │
│ │  CalcitePlanner.genOPTree()                            │    │
│ │    QB → RelNode (Calcite 关系代数)                     │    │
│ │    → HiveVolcanoPlanner 火山模型优化                    │    │
│ │    → 优化后 RelNode → ASTNode → Operator Tree          │    │
│ └────────────────────────────────────────────────────────┘    │
│                          ↓                                    │
│ ┌─ RBO 路径（Hive 原生规则优化器）──────────────────────┐    │
│ │  Optimizer.optimize()                                  │    │
│ │    逐个应用 Transform 规则                              │    │
│ │    谓词下推 / 列裁剪 / 分区裁剪 / MapJoin 转换等        │    │
│ └────────────────────────────────────────────────────────┘    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
  ↓
优化后的 Operator Tree → TaskCompiler
```

**关键认知**: CBO 和 RBO **不是互斥的**。当 CBO 开启时，先由 Calcite 做全局代价优化，然后 RBO 再做 Hive 特有的规则优化。

---

## 二、CBO — Calcite 基于代价优化

### 2.1 CalcitePlanner 类结构

```java
public class CalcitePlanner extends SemanticAnalyzer {
    
    // ★ 重写 genOPTree，在生成 Operator Tree 之前插入 Calcite 优化
    @Override
    Operator genOPTree(ASTNode ast, PlannerContext plannerCtx) 
        throws SemanticException {
        
        // Step 1: 尝试 CBO 优化
        if (canUseCBO()) {
            try {
                Operator result = processWithCBO(ast, plannerCtx);
                if (result != null) return result;
            } catch (Exception e) {
                LOG.warn("CBO failed, falling back to non-CBO path", e);
                // CBO 失败 → 降级到原生路径
            }
        }
        
        // Step 2: CBO 失败或关闭 → 走原生 SemanticAnalyzer 路径
        return super.genOPTree(ast, plannerCtx);
    }
}
```

### 2.2 CBO 核心流程

```java
private Operator processWithCBO(ASTNode ast, PlannerContext plannerCtx) {
    
    // ★ Phase 1: QB → Calcite RelNode
    // 将 Hive 的 QueryBlock 转换为 Calcite 的关系代数表达式
    RelNode calciteGenPlan = genLogicalPlan(qb);
    // 生成的 RelNode 树类似：
    //   HiveProject (投影)
    //     HiveFilter (过滤)
    //       HiveJoin (连接)
    //         HiveTableScan (表扫描)
    //         HiveTableScan (表扫描)
    
    // ★ Phase 2: Calcite 优化
    // 使用 HiveVolcanoPlanner（火山模型优化器）
    RelNode optimizedPlan = applyCalciteOptimizations(calciteGenPlan);
    
    // ★ Phase 3: RelNode → ASTNode
    // 将优化后的 Calcite 计划转回 Hive AST
    ASTNode optimizedAST = ASTConverter.convert(optimizedPlan);
    
    // ★ Phase 4: ASTNode → Operator Tree
    // 使用父类（SemanticAnalyzer）的标准路径生成 Operator
    return super.genOPTree(optimizedAST, plannerCtx);
}
```

**数据流转**:
```
QB (QueryBlock)
  ↓ genLogicalPlan()
RelNode (Calcite 关系代数)
  ↓ HiveVolcanoPlanner.findBestExp()
优化后的 RelNode
  ↓ ASTConverter.convert()
优化后的 ASTNode
  ↓ SemanticAnalyzer.genOPTree()
Operator Tree
```

### 2.3 HiveVolcanoPlanner — 火山模型优化器

```java
// Hive 继承 Calcite 的 VolcanoPlanner
public class HiveVolcanoPlanner extends VolcanoPlanner {
    
    // 注册 Hive 特有的优化规则
    public void registerHiveRules() {
        // ★ Join 重排序
        addRule(HiveJoinReorderRule.INSTANCE);
        
        // ★ 谓词下推
        addRule(HiveFilterProjectTransposeRule.INSTANCE);
        addRule(HiveFilterJoinRule.INSTANCE);
        
        // ★ 投影裁剪
        addRule(HiveProjectMergeRule.INSTANCE);
        
        // ★ 聚合优化
        addRule(HiveAggregateProjectMergeRule.INSTANCE);
        
        // ★ Join 算法选择
        addRule(HiveJoinToMapJoinRule.INSTANCE);
        addRule(HiveJoinToBucketMapJoinRule.INSTANCE);
        addRule(HiveJoinToSortMergeBucketMapJoinRule.INSTANCE);
        
        // ★ 子查询去相关
        addRule(HiveSubQueryRemoveRule.INSTANCE);
    }
}
```

**火山模型工作原理**:
```
1. 将原始 RelNode 注册到搜索空间 (Memo)
2. 对每个等价类 (Equivalence Class)，尝试所有可用的转换规则
3. 生成多个等价的执行计划变体
4. 用代价模型 (Cost Model) 评估每个变体
5. 选择总代价最小的计划

代价模型考量因素:
  - 行数 (rowCount)
  - CPU 成本 (cpu)
  - IO 成本 (io)
  - 网络传输 (network)
```

### 2.4 统计信息 — CBO 的基石

```java
// RelOptHiveTable: Hive 对 Calcite RelOptTable 的扩展
public class RelOptHiveTable extends RelOptAbstractTable {
    
    private Table hiveTable;          // Hive Table 对象
    private ColStatistics[] colStats; // 列级统计
    
    // ★ 行数获取
    @Override
    public double getRowCount() {
        // 从 Metastore 获取 numRows 统计
        // → 通过 StatsUtils.getFileSizeForTable() 
        //   或 table.getParameters().get("numRows")
    }
    
    // ★ 列统计获取
    public ColStatistics getColStat(int index) {
        // 从 Metastore 获取列统计信息
        // 包括: NDV, numNulls, avgColLen, range(min/max)
    }
}

// ColStatistics: 列级统计
public class ColStatistics {
    private long countDistinct;  // 不同值个数 (NDV)
    private long numNulls;       // NULL 值个数
    private double avgColLen;    // 平均列长度
    private Range range;         // 最大/最小值范围
}
```

**统计信息收集**:
```sql
-- 表级统计
ANALYZE TABLE employees COMPUTE STATISTICS;
-- → 收集 numRows, rawDataSize, numFiles, totalSize

-- 列级统计
ANALYZE TABLE employees COMPUTE STATISTICS FOR COLUMNS id, name, age, dept;
-- → 收集 NDV, numNulls, avgColLen, maxColLen, min/max
```

---

## 三、RBO — Hive 原生规则优化器

### 3.1 Optimizer 规则管道

```java
public class Optimizer {
    
    private List<Transform> transformations;  // 规则列表（顺序执行）
    
    public void initialize(HiveConf hiveConf) {
        transformations = new ArrayList<>();
        
        // ★ 按顺序添加优化规则
        
        // 1. 谓词下推 (Predicate Pushdown)
        transformations.add(new PredicatePushDown());
        
        // 2. 常量传播 (Constant Propagation)
        transformations.add(new ConstantPropagate());
        
        // 3. 列裁剪 (Column Pruner)
        transformations.add(new ColumnPruner());
        
        // 4. 分区裁剪 (Partition Pruner)
        transformations.add(new PartitionPruner());
        
        // 5. Map Join 自动转换
        if (hiveConf.getBoolVar(HiveConf.ConfVars.HIVECONVERTJOIN)) {
            transformations.add(new MapJoinProcessor());
        }
        
        // 6. Bucket Map Join 优化
        if (hiveConf.getBoolVar(HiveConf.ConfVars.HIVEOPTBUCKETMAPJOIN)) {
            transformations.add(new BucketMapJoinOptimizer());
        }
        
        // 7. Sort Merge Bucket Map Join
        if (hiveConf.getBoolVar(HiveConf.ConfVars.HIVEOPTSORTMERGEBUCKETMAPJOIN)) {
            transformations.add(new SortMergeBucketMapJoinOptimizer());
        }
        
        // 8. Group By 优化
        transformations.add(new GroupByOptimizer());
        
        // 9. 相关子查询优化
        transformations.add(new CorrelationOptimizer());
        
        // 10. ReduceSink 去重
        transformations.add(new ReduceSinkDeDuplication());
        
        // 11. Skew Join 优化
        if (hiveConf.getBoolVar(HiveConf.ConfVars.HIVE_OPTIMIZE_SKEWJOIN_COMPILETIME)) {
            transformations.add(new SkewJoinOptimizer());
        }
        
        // 12. Union 优化
        transformations.add(new UnionProcessor());
        
        // 13. 谓词传递关闭
        transformations.add(new PredicateTransitivePropagate());
        
        // 14. 限制下推 (Limit Pushdown)
        transformations.add(new LimitPushdownOptimizer());
        
        // ... 更多规则
    }
    
    public ParseContext optimize() throws SemanticException {
        // ★ 顺序执行每个规则
        for (Transform t : transformations) {
            pctx = t.transform(pctx);
        }
        return pctx;
    }
}
```

### 3.2 谓词下推（Predicate Pushdown）

**目标**: 将 WHERE 条件尽量下推到靠近数据源（TableScan）的位置，减少后续处理的数据量。

```java
public class PredicatePushDown extends Transform {
    
    @Override
    public ParseContext transform(ParseContext pctx) {
        // 使用 DefaultGraphWalker 遍历 Operator Tree
        // 规则: OpProcFactory.FilterPPD
        
        // 示例优化:
        // 优化前:
        //   TableScan(A) → Join → Filter(A.age > 25)
        // 优化后:
        //   TableScan(A) → Filter(A.age > 25) → Join
        //   ↑ 过滤在 Join 之前，减少 Join 数据量
    }
}
```

**下推规则**:
```
1. Join + Filter → Filter 下推到 Join 的对应输入端
   - Inner Join: 两边都可以下推
   - Left Outer Join: 只能下推到右表（保留表不能下推）
   - Full Outer Join: 不能下推

2. Aggregate + Filter → Filter 下推到 Aggregate 之前
   - 条件: Filter 中只包含 GROUP BY 列

3. Union + Filter → Filter 复制到 Union 的每个输入
```

### 3.3 列裁剪（Column Pruner）

**目标**: 移除 Operator Tree 中不需要的列，减少数据传输和处理量。

```java
public class ColumnPruner extends Transform {
    
    @Override
    public ParseContext transform(ParseContext pctx) {
        // 自顶向下遍历，收集每个 Operator 实际需要的列
        // 然后自底向上裁剪不需要的列
        
        // 示例:
        // SQL: SELECT id FROM employees WHERE age > 25
        // 表 employees 有 (id, name, age, dept, salary) 5 列
        //
        // 优化前: TableScan 读取所有 5 列
        // 优化后: TableScan 只读取 (id, age) 2 列
        //         name, dept, salary 被裁剪
    }
}
```

### 3.4 分区裁剪（Partition Pruner）

```java
public class PartitionPruner extends Transform {
    
    // 示例:
    // SQL: SELECT * FROM logs WHERE dt = '2026-04-04'
    // 表 logs 按 dt 分区，有 365 个分区
    //
    // 优化: 只扫描 dt='2026-04-04' 这一个分区
    // 减少 IO: 1/365 的数据量
}
```

### 3.5 完整规则清单

| 规则 | 类 | 作用 |
|------|-----|------|
| 谓词下推 | `PredicatePushDown` | WHERE 条件下推到数据源 |
| 常量传播 | `ConstantPropagate` | 常量表达式替换和折叠 |
| 列裁剪 | `ColumnPruner` | 移除不需要的列 |
| 分区裁剪 | `PartitionPruner` | 只扫描相关分区 |
| MapJoin 转换 | `MapJoinProcessor` | Common Join → Map Join |
| Bucket Map Join | `BucketMapJoinOptimizer` | 桶表 Map Join |
| SMB Join | `SortMergeBucketMapJoinOptimizer` | 排序桶表合并 Join |
| GroupBy 优化 | `GroupByOptimizer` | Map 端预聚合 |
| ReduceSink 去重 | `ReduceSinkDeDuplication` | 合并冗余 Shuffle |
| Skew Join | `SkewJoinOptimizer` | 数据倾斜 Join 优化 |
| Union 优化 | `UnionProcessor` | Union 合并优化 |
| 限制下推 | `LimitPushdownOptimizer` | LIMIT 下推到源 |
| 谓词传递 | `PredicateTransitivePropagate` | 谓词等式传递 |
| 相关子查询 | `CorrelationOptimizer` | 子查询去相关 |
| 动态分区裁剪 | `DynamicPartitionPruningOptimization` | 运行时分区裁剪 (Tez) |
| 向量化 | `Vectorizer` | 启用向量化执行 |

---

## 四、CBO vs RBO 对比

| 维度 | CBO (Calcite) | RBO (Hive 原生) |
|------|---------------|-----------------|
| 决策依据 | 统计信息 + 代价模型 | 固定规则顺序 |
| Join 排序 | 基于代价自动选择最优 Join 顺序 | 按 SQL 书写顺序 |
| Join 算法 | 基于表大小选择 Map/Bucket/SMB Join | 基于阈值参数 |
| 子查询 | 自动去相关 + 展开 | 有限支持 |
| 搜索空间 | 火山模型搜索所有等价计划 | 单通道顺序应用规则 |
| 降级机制 | CBO 失败 → 自动降级到 RBO | 无降级 |
| 依赖 | 需要准确的统计信息 | 不依赖统计信息 |
| 开启方式 | `hive.cbo.enable = true` (默认) | 始终启用 |

---

## 五、排障指南

### 5.1 CBO 相关参数

```sql
-- CBO 总开关
SET hive.cbo.enable = true;                    -- 默认 true

-- 统计信息自动收集
SET hive.stats.autogather = true;              -- 默认 true
SET hive.stats.column.autogather = true;       -- 默认 true

-- CBO 返回路径（CBO 异常时的降级策略）
SET hive.cbo.fallbackonfailure = true;         -- 默认 true

-- Join 重排序
SET hive.cbo.enable.jmr = true;               -- Join 重排序
```

### 5.2 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| CBO 选了很差的计划 | 统计信息不准/过期 | `ANALYZE TABLE ... COMPUTE STATISTICS FOR COLUMNS` |
| CBO 降级到 RBO | CBO 处理异常 | 查看 HiveServer2 日志中的 CBO 异常 |
| Join 顺序不佳 | 缺少列统计信息 | 收集列级统计（特别是 NDV） |
| 谓词没有下推 | Outer Join 限制/UDF 不可下推 | 改写 SQL 或调整 Join 类型 |

---

## 六、源码文件索引

| 文件 | 路径 | 职责 |
|------|------|------|
| **CalcitePlanner** | `ql/.../parse/CalcitePlanner.java` | CBO 入口，重写 genOPTree |
| **HiveVolcanoPlanner** | `ql/.../optimizer/calcite/HiveVolcanoPlanner.java` | Calcite 火山模型优化器 |
| **RelOptHiveTable** | `ql/.../optimizer/calcite/RelOptHiveTable.java` | Hive 表统计信息桥接 |
| **ASTConverter** | `ql/.../optimizer/calcite/translator/ASTConverter.java` | RelNode → ASTNode 转换 |
| **Optimizer** | `ql/.../optimizer/Optimizer.java` | RBO 规则管道入口 |
| **PredicatePushDown** | `ql/.../optimizer/ppd/PredicatePushDown.java` | 谓词下推 |
| **ColumnPruner** | `ql/.../optimizer/ColumnPruner.java` | 列裁剪 |
| **PartitionPruner** | `ql/.../optimizer/ppr/PartitionPruner.java` | 分区裁剪 |
| **MapJoinProcessor** | `ql/.../optimizer/MapJoinProcessor.java` | MapJoin 转换 |
| **GroupByOptimizer** | `ql/.../optimizer/GroupByOptimizer.java` | GroupBy 优化 |
| **StatsUtils** | `ql/.../stats/StatsUtils.java` | 统计信息工具 |
