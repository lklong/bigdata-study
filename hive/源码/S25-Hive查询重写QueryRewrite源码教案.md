# [教案] Hive查询重写(Query Rewrite)源码深度剖析

> 🎯 教学目标：掌握Hive基于Calcite的查询重写框架，理解物化视图重写、子查询消除、谓词推导三大核心重写机制的源码实现  
> ⏰ 预计学时：3学时  
> 📊 难度：⭐⭐⭐⭐⭐（高级）

---

## 一、课前导入（生活类比引入）

### 1.1 生活类比：快递分拣中心的"路径优化"

想象你是快递分拣中心的调度员：
- **原始路线**：北京→上海→杭州→上海→广州（有冗余绕路）
- **优化后**：北京→上海→杭州→广州（消除冗余，合并路径）

SQL查询重写就像这个过程：
- **原始SQL**：用户写的SQL可能包含冗余子查询、低效谓词位置
- **重写后SQL**：语义等价但执行效率更高的SQL

### 1.2 真实故障场景

```sql
-- 某电商平台慢查询，执行时间 45 分钟
SELECT dept_name, SUM(sales)
FROM orders o
WHERE o.region IN (SELECT region FROM hot_regions WHERE year = 2024)
  AND EXISTS (SELECT 1 FROM products p WHERE p.id = o.product_id AND p.category = 'electronics')
GROUP BY dept_name;
```

问题分析：
1. IN子查询未被消除为Semi Join → 产生笛卡尔积
2. 谓词`year=2024`未能推导到orders表的分区
3. 存在已建立的物化视图`mv_dept_sales`但未被自动匹配

**Query Rewrite就是解决这类问题的核心引擎。**

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 含义 | 类比 |
|------|------|------|
| Calcite | Apache关系代数优化框架 | SQL的"LLVM" |
| RelNode | 关系代数节点（逻辑算子树） | 语法树中的节点 |
| RexNode | 行表达式节点（标量表达式） | 条件/投影中的表达式 |
| RelOptRule | 优化规则（模式匹配+转换） | 分拣规则 |
| HepProgram | 启发式优化程序（规则序列） | 分拣流水线 |
| Materialization | 物化视图对象（预计算结果） | 预制件仓库 |

### 2.2 查询重写总体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Hive Query Rewrite Framework              │
├──────────────┬──────────────────┬───────────────────────────┤
│  子查询消除   │   谓词推导/下推    │    物化视图重写            │
│ SubQueryRemove│ TransitivePredicate│ MaterializedViewRewrite  │
├──────────────┼──────────────────┼───────────────────────────┤
│              │                  │                           │
│ HiveSubQuery │ HiveJoinPush     │ HiveMaterializedViewRule  │
│ RemoveRule   │ TransitivePreds  │ + RewritingRelVisitor     │
│              │ Rule             │ + IncrementalRewriting    │
├──────────────┴──────────────────┴───────────────────────────┤
│                Apache Calcite RelOptRule Framework           │
├─────────────────────────────────────────────────────────────┤
│         HiveRulesRegistry（规则注册表/去重追踪器）             │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 三大重写类别

| 类别 | 规则类 | 作用 |
|------|--------|------|
| 子查询消除 | `HiveSubQueryRemoveRule` | IN/EXISTS/SCALAR → JOIN |
| 谓词推导 | `HiveJoinPushTransitivePredicatesRule` | 等值传递推导新谓词 |
| 物化视图重写 | `HiveMaterializedViewRule` | 用MV替代原始查询 |

---

## 三、源码深度剖析

### 3.1 规则注册中心：HiveRulesRegistry

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/HiveRulesRegistry.java`

```java
// 第31-65行
public class HiveRulesRegistry {
    // 跟踪每个规则已访问过的算子节点（防止重复应用）
    private SetMultimap<RelOptRule, RelNode> registryVisited;
    // 跟踪每个算子已推送的谓词（防止重复推送）
    private ListMultimap<RelNode, Set<String>> registryPushedPredicates;

    public HiveRulesRegistry() {
        this.registryVisited = HashMultimap.create();
        this.registryPushedPredicates = ArrayListMultimap.create();
    }

    // 注册已访问的节点
    public void registerVisited(RelOptRule rule, RelNode operator) {
        this.registryVisited.put(rule, operator);
    }

    // 获取已推送的谓词集合
    public Set<String> getPushedPredicates(RelNode operator, int pos) {
        if (!this.registryPushedPredicates.containsKey(operator)) {
            for (int i = 0; i < operator.getInputs().size(); i++) {
                this.registryPushedPredicates.get(operator).add(Sets.newHashSet());
            }
        }
        return this.registryPushedPredicates.get(operator).get(pos);
    }
}
```

**设计思想**：
- `registryVisited`：防止同一规则对同一节点重复应用（幂等性保证）
- `registryPushedPredicates`：记录已推送谓词的字符串表示，避免重复推送导致死循环

---

### 3.2 子查询消除：HiveSubQueryRemoveRule

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/HiveSubQueryRemoveRule.java`

#### 3.2.1 核心转换逻辑

```java
// 第76-85行：规则定义
public class HiveSubQueryRemoveRule extends RelOptRule {
    private HiveConf conf;

    public HiveSubQueryRemoveRule(HiveConf conf) {
        // 匹配包含RexSubQuery的RelNode
        super(operand(RelNode.class, null, HiveSubQueryFinder.RELNODE_PREDICATE, any()),
            HiveRelFactories.HIVE_BUILDER, "SubQueryRemoveRule:Filter");
        this.conf = conf;
    }
}
```

#### 3.2.2 onMatch核心方法（第86-143行）

```java
public void onMatch(RelOptRuleCall call) {
    final RelNode relNode = call.rel(0);
    final HiveSubQRemoveRelBuilder builder = new HiveSubQRemoveRelBuilder(...);

    // 场景1：子查询在FILTER中
    if (relNode instanceof Filter) {
        final Filter filter = call.rel(0);
        final RexSubQuery e = RexUtil.SubQueryFinder.find(filter.getCondition());
        
        // 确定逻辑语义（TRUE / TRUE_FALSE_UNKNOWN）
        final RelOptUtil.Logic logic = LogicVisitor.find(
            RelOptUtil.Logic.TRUE, ImmutableList.of(filter.getCondition()), e);
        
        builder.push(filter.getInput());
        final int fieldCount = builder.peek().getRowType().getFieldCount();
        
        // 核心转换：将子查询转为JOIN
        final RexNode target = apply(e, HiveFilter.getVariablesSet(e), logic,
            builder, 1, fieldCount, isCorrScalarQuery, hasNoWindowingAndNoGby);
        
        // 用转换后的表达式替换原子查询
        final RexShuttle shuttle = new ReplaceSubQueryShuttle(e, target);
        builder.filter(shuttle.apply(filter.getCondition()));
        builder.project(fields(builder, filter.getRowType().getFieldCount()));
        call.transformTo(builder.build());
    }
    // 场景2：子查询在PROJECT中（第117-142行）
    else if (relNode instanceof Project) { ... }
}
```

#### 3.2.3 apply方法：三种子查询类型的转换（第167-456行）

**SCALAR_QUERY处理**（标量子查询→LEFT JOIN）：

```java
// 第173-242行
case SCALAR_QUERY:
    // 步骤1：添加sq_count_check确保至多返回一行
    if (!hasNoWindowingAndNoGby) {
        builder.push(e.rel);
        builder.aggregate(builder.groupKey(), builder.count(false, "cnt"));
        
        // 创建 sq_count_check UDF
        SqlFunction countCheck = new SqlFunction("sq_count_check", ...);
        builder.filter(builder.call(SqlStdOperatorTable.LESS_THAN_OR_EQUAL,
            builder.call(countCheck, builder.field("cnt")), builder.literal(1)));
        
        // 相关子查询用LEFT JOIN，非相关用INNER JOIN
        if (!variablesSet.isEmpty()) {
            builder.join(JoinRelType.LEFT, builder.literal(true), variablesSet);
        } else {
            builder.join(JoinRelType.INNER, builder.literal(true), variablesSet);
        }
    }
    
    // 步骤2：相关标量聚合特殊处理
    if (isCorrScalarAgg) {
        builder.push(e.rel);
        // 添加alwaysTrue指示器列
        String indicator = "alwaysTrue" + e.rel.getId();
        parentQueryFields.add(builder.alias(builder.literal(true), indicator));
        builder.project(parentQueryFields);
        builder.join(JoinRelType.LEFT, builder.literal(true), variablesSet);
        
        // CASE WHEN indicator IS NULL THEN default ELSE agg_result END
        return builder.call(SqlStdOperatorTable.CASE, operands.build());
    }
```

**IN/EXISTS处理**（第244-451行）：

```
转换前：SELECT * FROM e WHERE e.deptno IN (SELECT deptno FROM emp)

转换后（TRUE逻辑）：
SELECT * FROM e 
INNER JOIN (SELECT DISTINCT deptno FROM emp) AS dt
ON e.deptno = dt.deptno

转换后（TRUE_FALSE_UNKNOWN逻辑）：
SELECT e.*, CASE
  WHEN ct.c = 0 THEN false
  WHEN dt.i IS NOT NULL THEN true
  WHEN e.deptno IS NULL THEN null
  WHEN ct.ck < ct.c THEN null
  ELSE false END
FROM e
LEFT JOIN (
  (SELECT count(*) as c, count(deptno) as ck FROM emp) as ct
  CROSS JOIN (SELECT DISTINCT deptno, true as i FROM emp)) as dt
ON e.deptno = dt.deptno
```

#### 3.2.4 子查询发现器：HiveSubQueryFinder（第504-560行）

```java
public static final class HiveSubQueryFinder extends RexVisitorImpl<Void> {
    // 谓词：判断RelNode是否包含子查询
    public static final Predicate<RelNode> RELNODE_PREDICATE = new Predicate<RelNode>() {
        public boolean apply(RelNode relNode) {
            if (relNode instanceof Project) {
                for (RexNode node : ((Project)relNode).getProjects()) {
                    try {
                        node.accept(INSTANCE);
                    } catch (Util.FoundOne e) {
                        return true;  // 发现子查询！
                    }
                }
            } else if (relNode instanceof Filter) {
                try {
                    ((Filter)relNode).getCondition().accept(INSTANCE);
                } catch (Util.FoundOne e) {
                    return true;  // 发现子查询！
                }
            }
            return false;
        }
    };

    @Override
    public Void visitSubQuery(RexSubQuery subQuery) {
        throw new Util.FoundOne(subQuery);  // 异常控制流
    }
}
```

**设计模式**：利用异常作为控制流（`Util.FoundOne`），在深层遍历时快速返回发现结果。

---

### 3.3 谓词传递推导：HiveJoinPushTransitivePredicatesRule

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/HiveJoinPushTransitivePredicatesRule.java`

#### 3.3.1 核心原理

```
给定 JOIN 条件: A.id = B.id
已知谓词: A.id > 100

传递推导 → B.id > 100（新增谓词下推到B表）
```

#### 3.3.2 onMatch实现（第81-128行）

```java
@Override
public void onMatch(RelOptRuleCall call) {
    Join join = call.rel(0);
    
    // 1. 获取JOIN节点的推导谓词
    RelOptPredicateList preds = call.getMetadataQuery().getPulledUpPredicates(join);
    
    // 2. 获取规则注册表（防止重复推送）
    HiveRulesRegistry registry = call.getPlanner().getContext().unwrap(HiveRulesRegistry.class);
    
    RelNode lChild = join.getLeft();
    RelNode rChild = join.getRight();
    
    // 3. 过滤已推送的谓词，获取有效的新谓词
    Set<String> leftPushedPredicates = Sets.newHashSet(registry.getPushedPredicates(join, 0));
    List<RexNode> leftPreds = getValidPreds(join.getCluster(), lChild,
        leftPushedPredicates, preds.leftInferredPredicates, lChild.getRowType());
    
    Set<String> rightPushedPredicates = Sets.newHashSet(registry.getPushedPredicates(join, 1));
    List<RexNode> rightPreds = getValidPreds(join.getCluster(), rChild,
        rightPushedPredicates, preds.rightInferredPredicates, rChild.getRowType());
    
    // 4. 合成新的Filter节点并下推
    RexNode newLeftPredicate = RexUtil.composeConjunction(rB, leftPreds, false);
    RexNode newRightPredicate = RexUtil.composeConjunction(rB, rightPreds, false);
    
    if (!newLeftPredicate.isAlwaysTrue()) {
        lChild = filterFactory.createFilter(lChild, newLeftPredicate.accept(new RexReplacer(lChild)));
    }
    if (!newRightPredicate.isAlwaysTrue()) {
        rChild = filterFactory.createFilter(rChild, newRightPredicate.accept(new RexReplacer(rChild)));
    }
    
    // 5. 重建JOIN节点
    RelNode newRel = join.copy(join.getTraitSet(), join.getCondition(),
        lChild, rChild, join.getJoinType(), join.isSemiJoinDone());
    
    // 6. 记录已推送谓词
    registry.getPushedPredicates(newRel, 0).addAll(leftPushedPredicates);
    registry.getPushedPredicates(newRel, 1).addAll(rightPushedPredicates);
    
    call.transformTo(newRel);
}
```

#### 3.3.3 InputRefValidator类型安全校验（第167-206行）

```java
private static class InputRefValidator extends RexVisitorImpl<Void> {
    @Override
    public Void visitCall(RexCall call) {
        // 对NOT NULL谓词特殊处理：非nullable列不需要推送NOT NULL
        if (isNotNullOp(call) && !types.get(index).getType().isNullable()) {
            throw new Util.FoundOne(call);  // 跳过无意义的推送
        }
        return super.visitCall(call);
    }
    
    @Override
    public Void visitInputRef(RexInputRef inputRef) {
        // 类型兼容性检查：推导出的谓词类型必须与目标列兼容
        if (!areTypesCompatible(inputRef.getType(), types.get(inputRef.getIndex()).getType())) {
            throw new Util.FoundOne(inputRef);
        }
        return super.visitInputRef(inputRef);
    }
}
```

---

### 3.4 物化视图重写：HiveMaterializedViewRule

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/views/HiveMaterializedViewRule.java`

#### 3.4.1 六大重写规则实例

```java
// 第81-103行：六种MV重写规则实例
public class HiveMaterializedViewRule {

    // 1. Project + Filter场景
    public static final MaterializedViewProjectFilterRule INSTANCE_PROJECT_FILTER = ...;
    // 2. 仅Filter场景
    public static final MaterializedViewOnlyFilterRule INSTANCE_FILTER = ...;
    // 3. Project + Join场景
    public static final MaterializedViewProjectJoinRule INSTANCE_PROJECT_JOIN = ...;
    // 4. 仅Join场景
    public static final MaterializedViewOnlyJoinRule INSTANCE_JOIN = ...;
    // 5. Project + Aggregate场景
    public static final HiveMaterializedViewProjectAggregateRule INSTANCE_PROJECT_AGGREGATE = ...;
    // 6. 仅Aggregate场景
    public static final HiveMaterializedViewOnlyAggregateRule INSTANCE_AGGREGATE = ...;
}
```

#### 3.4.2 部分重写辅助程序PROGRAM（第67-79行）

```java
// 当发生部分重写（UNION操作）时执行的HEP优化程序
private static final HepProgram PROGRAM = new HepProgramBuilder()
    .addRuleInstance(HiveExtractRelNodeRule.INSTANCE)     // 从RelSubset提取真实节点
    .addRuleInstance(HiveTableScanProjectInsert.INSTANCE) // TableScan上插入投影
    .addRuleCollection(ImmutableList.of(
        HiveFilterProjectTransposeRule.INSTANCE,          // Filter/Project互换
        HiveJoinProjectTransposeRule.BOTH_PROJECT,        // Join上提投影
        HiveJoinProjectTransposeRule.LEFT_PROJECT,
        HiveJoinProjectTransposeRule.RIGHT_PROJECT,
        HiveProjectMergeRule.INSTANCE))                   // Project合并
    .addRuleInstance(ProjectRemoveRule.INSTANCE)           // 移除多余Project
    .addRuleInstance(HiveRootJoinProjectInsert.INSTANCE)   // 根JOIN上插入Project
    .build();
```

#### 3.4.3 Aggregate聚合函数的Rollup支持

```java
// 第106-121行：支持聚合函数的上卷(rollup)
protected static class HiveMaterializedViewProjectAggregateRule 
    extends MaterializedViewProjectAggregateRule {
    
    @Override
    protected SqlFunction getFloorSqlFunction(TimeUnitRange flag) {
        return HiveRelBuilder.getFloorSqlFunction(flag);
    }
    
    @Override
    public SqlAggFunction getRollup(SqlAggFunction aggregation) {
        // COUNT → SUM（上卷时COUNT变为SUM）
        // SUM → SUM（保持不变）
        // MIN → MIN / MAX → MAX
        return HiveRelBuilder.getRollup(aggregation);
    }
}
```

---

### 3.5 增量重写规则：HiveAggregateIncrementalRewritingRule

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/views/HiveAggregateIncrementalRewritingRule.java`

#### 3.5.1 设计目标

将物化视图的`INSERT OVERWRITE`全量刷新改为`MERGE`增量更新：

```sql
-- 全量刷新（昂贵）
INSERT OVERWRITE mv SELECT a, b, SUM(s), SUM(c) FROM (
  SELECT * FROM mv UNION ALL SELECT ... FROM source
) GROUP BY a, b;

-- 增量更新（高效，由本规则生成）
MERGE INTO mv USING source
ON (mv.a = source.a AND mv.b = source.b)
WHEN MATCHED THEN UPDATE SET mv.s = mv.s + source.s, mv.c = mv.c + source.c
WHEN NOT MATCHED THEN INSERT VALUES (source.a, source.b, s, c);
```

#### 3.5.2 onMatch核心逻辑（第95-173行）

```java
@Override
public void onMatch(RelOptRuleCall call) {
    final Aggregate agg = call.rel(0);
    final Union union = call.rel(1);
    
    // 1. 确定输入：左分支=MV旧数据，右分支=新增数据
    final RelNode joinLeftInput = union.getInput(1);  // MV
    final RelNode joinRightInput = union.getInput(0); // 新数据
    
    // 2. 构建JOIN条件和投影表达式
    for (int leftPos = 0; leftPos < groupCount; leftPos++) {
        // GROUP BY列：等值JOIN条件
        joinConjs.add(rexBuilder.makeCall(SqlStdOperatorTable.EQUALS, leftRef, rightRef));
        // NULL检测：判断是否为新插入行
        filterConjs.add(rexBuilder.makeCall(SqlStdOperatorTable.IS_NULL, leftRef));
    }
    
    // 3. 聚合列的MERGE逻辑
    for (AggregateCall aggCall : agg.getAggCallList()) {
        switch (aggCall.getKind()) {
            case SUM:   elseReturn = PLUS(rightRef, leftRef);      break;  // 累加
            case MIN:   elseReturn = CASE(right<left, right, left); break;  // 取最小
            case MAX:   elseReturn = CASE(right>left, right, left); break;  // 取最大
        }
        // CASE WHEN 旧数据IS NULL THEN 新数据 ELSE merge结果
        projExprs.add(CASE(caseFilterCond, rightRef, elseReturn));
    }
    
    // 4. 构建最终计划：RIGHT JOIN + FILTER + PROJECT
    RelNode newNode = call.builder()
        .push(union.getInput(1))
        .push(union.getInput(0))
        .join(JoinRelType.RIGHT, joinCond)
        .filter(OR(joinCond, filterCond))
        .project(projExprs)
        .build();
    call.transformTo(newNode);
}
```

---

### 3.6 增量重写可行性检查：MaterializedViewRewritingRelVisitor

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/views/MaterializedViewRewritingRelVisitor.java`

```java
// 第45-164行：检查MV是否可以从INSERT OVERWRITE转为INSERT INTO
public class MaterializedViewRewritingRelVisitor extends RelVisitor {
    private boolean containsAggregate;
    private boolean rewritingAllowed;

    @Override
    public void visit(RelNode node, int ordinal, RelNode parent) {
        if (node instanceof Aggregate) {
            this.containsAggregate = true;
            RelNode input = node.getInput(0);
            if (input instanceof Union) {
                check((Union) input);  // 聚合模式下检查Union
            }
        } else if (node instanceof Union) {
            check((Union) node);  // 非聚合模式
        } else if (node instanceof Project) {
            super.visit(node, ordinal, parent);  // Project可透传
        }
        throw new ReturnedValue(false);
    }

    private void check(Union union) {
        // 条件1：Union必须恰好有2个输入
        if (union.getInputs().size() != 2) throw new ReturnedValue(false);
        
        // 条件2：第一个分支（新数据查询）只能包含合法算子
        // 允许：TableScan, Filter, Project, Join, Aggregate(仅聚合模式)
        
        // 条件3：第二个分支（MV引用）必须是物化视图
        // 且聚合模式下必须是Full ACID表（支持MERGE）
        new RelVisitor() {
            public void visit(RelNode node, ...) {
                if (node instanceof TableScan) {
                    RelOptHiveTable hiveTable = (RelOptHiveTable) node.getTable();
                    if (!hiveTable.getHiveTableMD().isMaterializedView()) {
                        throw new ReturnedValue(false);
                    }
                    if (containsAggregate && !AcidUtils.isFullAcidTable(hiveTable.getHiveTableMD())) {
                        throw new ReturnedValue(false);  // 需要MERGE支持
                    }
                }
            }
        }.go(union.getInput(1));
        
        throw new ReturnedValue(true);  // 通过所有检查
    }
}
```

---

### 3.7 调用链时序图

```
用户提交SQL
    │
    ▼
CalcitePlanner.genLogicalPlan()
    │
    ├─── Phase 1: CBO优化入口
    │         │
    │         ▼
    │    HepPlanner (启发式优化器)
    │         │
    │         ├── 规则1: HiveSubQueryRemoveRule.onMatch()
    │         │         ├── HiveSubQueryFinder.find() → 定位子查询
    │         │         ├── apply(SCALAR_QUERY) → LEFT JOIN + sq_count_check
    │         │         ├── apply(IN) → SEMI JOIN / LEFT JOIN
    │         │         └── apply(EXISTS) → SEMI JOIN
    │         │
    │         ├── 规则2: HiveJoinPushTransitivePredicatesRule.onMatch()
    │         │         ├── getMetadataQuery().getPulledUpPredicates() → 推导谓词
    │         │         ├── getValidPreds() → 过滤无效/已推送谓词
    │         │         └── createFilter() → 下推新谓词
    │         │
    │         └── 规则3: HiveMaterializedViewRule（多实例）
    │                   ├── MaterializedViewsRegistry.get() → 获取可用MV
    │                   ├── Calcite AbstractMaterializedViewRule → 匹配MV
    │                   └── PROGRAM → 部分重写时的投影上提
    │
    ├─── Phase 2: 物化视图增量维护（REBUILD场景）
    │         │
    │         ▼
    │    HiveAggregateIncrementalRewritingRule.onMatch()
    │         ├── MaterializedViewRewritingRelVisitor.go() → 可行性检查
    │         └── 生成 RIGHT JOIN + FILTER + PROJECT → MERGE计划
    │
    └─── 输出优化后的RelNode树
```

---

## 四、生产实战案例

### 4.1 案例一：子查询消除失败导致性能问题

**故障现象**：
```sql
SELECT * FROM orders WHERE order_id IN (SELECT order_id FROM returns);
-- 预期：SemiJoin  实际：CartesianProduct + Filter
```

**排障步骤**：
```bash
# 1. 开启CBO调试日志
SET hive.log.explain.output=true;
SET hive.cbo.show.warnings=true;

# 2. 查看执行计划
EXPLAIN EXTENDED SELECT ...;

# 3. 检查子查询消除是否启用
SET hive.optimize.remove.sq_count_check;   -- 默认true
SET hive.cbo.enable;                        -- 必须true
```

**根因**：`hive.cbo.enable=false`导致Calcite优化器未启用，SubQueryRemoveRule未执行。

### 4.2 案例二：物化视图未被匹配

**故障现象**：已创建MV但查询未使用

**排障步骤**：
```sql
-- 1. 检查MV是否启用重写
ALTER MATERIALIZED VIEW mv_sales ENABLE REWRITE;

-- 2. 检查MV注册状态
SET hive.server2.materialized.views.registry.impl;  -- 不能是DUMMY

-- 3. 检查MV是否过期
DESCRIBE FORMATTED mv_sales;
-- 查看 rewrite.fromOpenTxnSCN 和 rewrite.toSCN

-- 4. 确认优化器配置
SET hive.materializedview.rewriting=true;
SET hive.materializedview.rewriting.sql=true;
```

### 4.3 参数调优清单

| 参数 | 默认值 | 建议 | 说明 |
|------|--------|------|------|
| `hive.cbo.enable` | true | true | CBO总开关 |
| `hive.optimize.remove.sq_count_check` | false | true | 移除sq_count_check(提升性能) |
| `hive.materializedview.rewriting` | true | true | MV重写开关 |
| `hive.materializedview.rewriting.sql` | true | true | 基于SQL文本匹配 |
| `hive.server2.materialized.views.registry.impl` | DEFAULT | DEFAULT | 缓存实现(非DUMMY) |
| `hive.optimize.point.lookup.min` | 2 | 2 | IN列表转PointLookup阈值 |
| `hive.cbo.fallback.strategy` | CONSERVATIVE | CONSERVATIVE | CBO失败降级策略 |

---

## 五、举一反三

### 5.1 与其他系统的类比

| Hive Query Rewrite | Spark Catalyst | Presto/Trino | 数据库(Oracle) |
|-------------------|----------------|--------------|---------------|
| HiveSubQueryRemoveRule | RewriteCorrelatedScalarSubquery | DecorrelateUnnest | 子查询展开(Unnesting) |
| HiveJoinPushTransitivePreds | InferFiltersFromConstraints | PredicatePushDown | 传递闭包 |
| HiveMaterializedViewRule | - (不支持) | MaterializedViewOptimizer | MV Query Rewrite |
| HiveRulesRegistry | - | - | Cost-Based Transform |

### 5.2 面试高频题

**Q1：Hive中IN子查询是如何被消除的？转换为什么类型的JOIN？**

A：HiveSubQueryRemoveRule通过Calcite框架实现。根据逻辑语义：
- `TRUE`逻辑 → INNER JOIN + DISTINCT（Semi Join语义）
- `TRUE_FALSE_UNKNOWN`逻辑 → LEFT JOIN + COUNT检查 + CASE表达式
核心在于`apply()`方法中根据`RelOptUtil.Logic`枚举选择不同的转换策略。

**Q2：谓词传递推导为什么需要HiveRulesRegistry？如果不用会怎样？**

A：HiveRulesRegistry记录已推送的谓词。没有它会导致：
1. 同一谓词被反复推送形成死循环
2. 优化器无法收敛（CBO超时）
3. 推导出冗余Filter节点增加计划复杂度

**Q3：物化视图重写的前置条件有哪些？**

A：
1. MV必须ENABLE REWRITE
2. MV对应表数据不能过期（通过SCN/WriteId检测）
3. 含聚合的增量重写要求底表是Full ACID表
4. HiveMaterializedViewsRegistry已初始化完成
5. 查询的RelNode结构需匹配六种规则之一

**Q4：SCALAR_QUERY中的sq_count_check函数的作用是什么？**

A：保证标量子查询最多返回一行。如果返回多行，运行时会抛出异常。它通过在子查询上添加`COUNT(*)`并验证`sq_count_check(cnt) <= 1`的Filter实现。设置`hive.optimize.remove.sq_count_check=true`可跳过此检查以提升性能（需确认业务逻辑保证单行）。

### 5.3 思考题

1. 为什么Hive选择基于Calcite框架而非自研优化器？相比Spark Catalyst有何优劣？
2. `MaterializedViewRewritingRelVisitor`中为什么聚合场景下要求Full ACID表？如果不是会有什么问题？
3. 如果一个IN子查询的子表返回NULL值，THREE_VALUED_LOGIC的CASE表达式如何处理？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────┐
│           Hive Query Rewrite 核心知识晶体                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  框架层：Apache Calcite RelOptRule + HepProgram                  │
│  注册表：HiveRulesRegistry（防重复推送/访问追踪）                  │
│                                                                 │
│  三大重写：                                                      │
│  ┌─────────────────┐ ┌────────────────┐ ┌──────────────────┐   │
│  │ 子查询消除       │ │ 谓词传递推导    │ │ 物化视图重写      │   │
│  │ IN→SemiJoin     │ │ A.id=B.id      │ │ 6种匹配模式      │   │
│  │ EXISTS→SemiJoin │ │ A.id>100       │ │ Filter/Join/Agg │   │
│  │ SCALAR→LeftJoin │ │ → B.id>100     │ │ 增量MERGE重写    │   │
│  └─────────────────┘ └────────────────┘ └──────────────────┘   │
│                                                                 │
│  关键类：                                                        │
│  • HiveSubQueryRemoveRule → apply() 三种SqlKind处理             │
│  • HiveJoinPushTransitivePredicatesRule → getValidPreds()       │
│  • HiveMaterializedViewRule → 6个INSTANCE + PROGRAM             │
│  • HiveAggregateIncrementalRewritingRule → MERGE重写            │
│  • MaterializedViewRewritingRelVisitor → 可行性检查             │
│                                                                 │
│  调优要点：                                                      │
│  • hive.cbo.enable=true（总开关）                               │
│  • hive.materializedview.rewriting=true                         │
│  • hive.optimize.remove.sq_count_check=true（生产酌情）          │
│  • registry.impl ≠ DUMMY                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. Apache Calcite官方文档：https://calcite.apache.org/docs/materialized_views.html
2. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/`
3. HIVE-14249: Materialized View Rewriting (JIRA)
4. HIVE-18680: Incremental rebuild for MV with aggregations
5. Julian Hyde, "Cost-based query optimization via Calcite" (Calcite设计论文)
6. Hive Wiki: CBO (Cost Based Optimizer)
