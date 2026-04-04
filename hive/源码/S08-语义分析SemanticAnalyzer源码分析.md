# S08: SemanticAnalyzer 语义分析 — AST → QB → Operator Tree 源码深度分析

> **创建时间**: 2026-04-04
> **分析版本**: Apache Hive 3.x / 4.x
> **标签**: #Hive #SemanticAnalyzer #QueryBlock #OperatorTree #编译原理 #源码分析

---

## 一、语义分析在编译链路中的位置

```
Phase 1: Parser → AST (ASTNode)
  ↓
┌──────────────────────────────────────────────────────┐
│ Phase 2: SemanticAnalyzer（语义分析）← 本文聚焦       │
│   AST → QB (QueryBlock) → Operator Tree              │
│   代码量 10000+ 行，Hive 编译器最复杂的单个类          │
└──────────────────────────────────────────────────────┘
  ↓
Phase 3: Optimizer → 优化后的 Operator Tree
```

---

## 二、核心调用链

```java
Driver.compile()
  → SemanticAnalyzerFactory.get(queryState, tree)  // 工厂选择 Analyzer
  → sem.analyze(tree, ctx)
    → sem.analyzeInternal(tree)                    // 核心入口
      → Phase A: genResolvedParseTree(ast, plannerCtx)
      │   ├── doPhase1(child, qb, ctx_1, plannerCtx)  // AST → QB
      │   └── getMetaData(qb)                          // 填充元数据
      → Phase B: genOPTree(ast, plannerCtx)
      │   └── genPlan(qb)                              // QB → Operator Tree
      → Phase C: Optimizer.optimize()                   // 逻辑优化
      → Phase D: TaskCompiler.compile()                 // 物理计划生成
```

---

## 三、SemanticAnalyzer 工厂选择

### 3.1 SemanticAnalyzerFactory

```java
public final class SemanticAnalyzerFactory {
    
    public static BaseSemanticAnalyzer get(QueryState queryState, ASTNode tree) {
        
        switch (tree.getType()) {
            case HiveParser.TOK_EXPLAIN:
                return new ExplainSemanticAnalyzer(queryState);
                
            case HiveParser.TOK_LOAD:
                return new LoadSemanticAnalyzer(queryState);
                
            case HiveParser.TOK_CREATEDATABASE:
            case HiveParser.TOK_DROPDATABASE:
            case HiveParser.TOK_CREATETABLE:
            case HiveParser.TOK_DROPTABLE:
            case HiveParser.TOK_ALTERTABLE:
            // ... 更多 DDL
                return new DDLSemanticAnalyzer(queryState);
                
            case HiveParser.TOK_QUERY:
                // ★ 关键分支：普通查询
                if (queryState.getConf().getBoolVar(
                    HiveConf.ConfVars.HIVE_CBO_ENABLED)) {
                    // CBO 开启 → CalcitePlanner（继承自 SemanticAnalyzer）
                    return new CalcitePlanner(queryState);
                } else {
                    // CBO 关闭 → 原生 SemanticAnalyzer
                    return new SemanticAnalyzer(queryState);
                }
                
            default:
                return new SemanticAnalyzer(queryState);
        }
    }
}
```

**关键**: `CalcitePlanner extends SemanticAnalyzer`，在 CBO 开启时，重写了 `genOPTree()` 方法引入 Calcite 优化。

---

## 四、Phase A: AST → QueryBlock（genResolvedParseTree）

### 4.1 QueryBlock（QB）数据结构

QB 是 Hive 语义分析的核心数据结构，将非结构化的 AST 转为结构化的查询块：

```java
public class QB implements Serializable {
    
    // ★ 核心组件
    private QBParseInfo qbp;           // 解析信息（存储各子句）
    private QBMetaData qbm;            // 元数据（表、列的元信息）
    
    // 别名管理
    private Map<String, String> aliasToTabs;      // 别名 → 实际表名
    private Map<String, QB> aliasToSubq;           // 别名 → 子查询 QB
    private Map<String, ASTNode> aliasToViews;     // 别名 → 视图
    
    // 输入输出
    private Set<String> tabAliases;                // 所有表别名
    private List<String> subqAliases;              // 子查询别名
    
    // 标记
    private boolean isSubQ;                        // 是否子查询
    private int numJoins;                          // Join 数量
    private int numGbys;                           // Group By 数量
}
```

### 4.2 QBParseInfo — 各子句存储

```java
public class QBParseInfo {
    
    // ★ 各子句按 dest（目标/子句 ID）存储
    private final Map<String, ASTNode> destToSelExpr;      // SELECT 表达式
    private final Map<String, ASTNode> destToWhereExpr;    // WHERE 条件
    private final Map<String, ASTNode> destToGroupby;      // GROUP BY
    private final Map<String, ASTNode> destToHaving;       // HAVING
    private final Map<String, ASTNode> destToOrderby;      // ORDER BY
    private final Map<String, ASTNode> destToSortby;       // SORT BY
    private final Map<String, ASTNode> destToLimit;        // LIMIT
    private final Map<String, ASTNode> destToClusterby;    // CLUSTER BY
    private final Map<String, ASTNode> destToDistributeby; // DISTRIBUTE BY
    
    // JOIN 信息
    private QBJoinTree joinExpr;                            // JOIN 树
    
    // 聚合函数
    private final Map<String, LinkedHashMap<String, ASTNode>> 
        destToAggregationExprs;                             // 聚合表达式
    
    // 窗口函数
    private final Map<String, LinkedHashMap<String, ASTNode>> 
        destToWindowingExprs;                               // 窗口表达式
    
    // INSERT 目标
    private final Map<String, ASTNode> nameToDestTable;     // INSERT INTO 目标表
    private final Map<String, ASTNode> nameToDestDir;       // INSERT OVERWRITE DIRECTORY
}
```

### 4.3 doPhase1 — AST 分块存入 QB

```java
public class SemanticAnalyzer extends BaseSemanticAnalyzer {
    
    /**
     * Phase 1: 递归遍历 AST，将各子句分块存入 QB
     * 
     * 核心思想: "大卸八块"
     * - 遍历 AST 的每个节点
     * - 根据节点类型，将信息存入 QB / QBParseInfo 的对应 Map
     */
    public boolean doPhase1(ASTNode ast, QB qb, Phase1Ctx ctx_1,
                            PlannerContext plannerCtx) throws SemanticException {
        
        boolean phase1Result = true;
        QBParseInfo qbp = qb.getParseInfo();
        
        switch (ast.getToken().getType()) {
            
            // ★ FROM 子句 — 表引用
            case HiveParser.TOK_TABREF:
                // 解析表名和别名
                String tableIdent = getUnescapedName((ASTNode) ast.getChild(0));
                String alias = getAlias(ast);
                qb.setTabAlias(alias, tableIdent);
                qbp.setTabAlias(alias, tableIdent);
                break;
                
            // ★ 子查询
            case HiveParser.TOK_SUBQUERY:
                // 创建子 QB，递归调用 doPhase1
                QB subQB = new QB(qb.getId() + ":" + alias, alias, true);
                qb.setSubqAlias(alias, subQB);
                doPhase1((ASTNode) ast.getChild(0), subQB, ctx_1, plannerCtx);
                break;
                
            // ★ SELECT 子句
            case HiveParser.TOK_SELECT:
            case HiveParser.TOK_SELECTDI:
                qbp.setSelExprForClause(ctx_1.dest, ast);
                // 遍历 SELECT 中的聚合函数
                LinkedHashMap<String, ASTNode> aggExprs = 
                    doPhase1GetAggregationsFromSelect(ast, qb, ctx_1.dest);
                qbp.setAggregationExprsForClause(ctx_1.dest, aggExprs);
                break;
                
            // ★ WHERE 子句
            case HiveParser.TOK_WHERE:
                qbp.setWhrExprForClause(ctx_1.dest, ast);
                break;
                
            // ★ GROUP BY 子句
            case HiveParser.TOK_GROUPBY:
                qbp.setGroupByExprForClause(ctx_1.dest, ast);
                break;
                
            // ★ ORDER BY / SORT BY / DISTRIBUTE BY / CLUSTER BY
            case HiveParser.TOK_ORDERBY:
                qbp.setOrderByExprForClause(ctx_1.dest, ast);
                break;
                
            // ★ LIMIT 子句
            case HiveParser.TOK_LIMIT:
                qbp.setDestLimit(ctx_1.dest, 
                    new Integer(ast.getChild(0).getText()));
                break;
                
            // ★ JOIN
            case HiveParser.TOK_JOIN:
            case HiveParser.TOK_LEFTOUTERJOIN:
            case HiveParser.TOK_RIGHTOUTERJOIN:
            case HiveParser.TOK_FULLOUTERJOIN:
            case HiveParser.TOK_CROSSJOIN:
            case HiveParser.TOK_LEFTSEMIJOIN:
                // 构建 QBJoinTree
                processJoin(ast, qb, ctx_1, plannerCtx);
                break;
                
            // ★ UNION
            case HiveParser.TOK_UNION:
                // 创建多个子 QB
                processUnion(ast, qb, ctx_1, plannerCtx);
                break;
                
            // ★ LATERAL VIEW
            case HiveParser.TOK_LATERAL_VIEW:
            case HiveParser.TOK_LATERAL_VIEW_OUTER:
                qbp.addLateralViewForAlias(alias, ast);
                break;
        }
        
        // 递归处理子节点
        for (int i = 0; i < ast.getChildCount(); i++) {
            phase1Result &= doPhase1((ASTNode) ast.getChild(i), qb, ctx_1, plannerCtx);
        }
        
        return phase1Result;
    }
}
```

### 4.4 getMetaData — 填充元数据

```java
/**
 * 从 Metastore 获取表、列、分区的元数据
 * 填充到 QB 中，使 QB 具有完整的语义信息
 */
private void getMetaData(QB qb) throws SemanticException {
    
    // ★ Step 1: 处理所有表引用
    for (String alias : qb.getTabAliases()) {
        String tableName = qb.getTabNameForAlias(alias);
        
        // 从 Metastore 获取 Table 对象
        Table tab = db.getTable(tableName);
        if (tab == null) {
            throw new SemanticException(ErrorMsg.INVALID_TABLE.getMsg(tableName));
        }
        
        // 存储元数据
        qb.getMetaData().setSrcForAlias(alias, tab);
        
        // 获取分区信息（如果有 WHERE 条件涉及分区列）
        List<Partition> parts = getPartitions(tab, qb, alias);
        qb.getMetaData().setPartForAlias(alias, parts);
    }
    
    // ★ Step 2: 处理子查询（递归）
    for (String alias : qb.getSubqAliases()) {
        QB subQB = qb.getSubqForAlias(alias);
        getMetaData(subQB);
    }
    
    // ★ Step 3: 处理 INSERT 目标表
    for (String dest : qb.getParseInfo().getClauseNames()) {
        ASTNode destTab = qb.getParseInfo().getDestForClause(dest);
        if (destTab != null) {
            Table destTable = db.getTable(getUnescapedName(destTab));
            qb.getMetaData().setDestForAlias(dest, destTable);
        }
    }
    
    // ★ Step 4: 处理视图（展开视图定义）
    for (String alias : qb.getAliasToViews().keySet()) {
        // 获取视图的 SQL 定义 → 递归解析
        String viewSql = view.getViewOriginalText();
        ASTNode viewTree = ParseUtils.parse(viewSql);
        // 创建新的 QB 处理视图内部逻辑
    }
}
```

---

## 五、Phase B: QB → Operator Tree（genOPTree）

### 5.1 Operator 体系

```
Operator<T extends OperatorDesc> (抽象基类)
  ├── TableScanOperator         ← 表扫描
  ├── FilterOperator            ← WHERE/HAVING 过滤
  ├── SelectOperator            ← SELECT 投影
  ├── JoinOperator              ← Common Join
  ├── MapJoinOperator           ← Map Join
  ├── ReduceSinkOperator        ← Shuffle 前的数据分发
  ├── GroupByOperator           ← GROUP BY 聚合
  ├── UnionOperator             ← UNION ALL
  ├── LimitOperator             ← LIMIT
  ├── FileSinkOperator          ← 写入 HDFS
  ├── LateralViewJoinOperator   ← LATERAL VIEW
  ├── LateralViewForwardOperator
  ├── ExtractOperator           ← 提取（ORDER BY 后）
  ├── ScriptOperator            ← TRANSFORM 脚本
  ├── UDTFOperator              ← 表生成函数
  └── CollectOperator           ← FETCH 模式
```

### 5.2 genPlan — 核心生成逻辑

```java
/**
 * 将 QB 转为 Operator Tree
 * 这是编译器最核心的方法之一
 */
public Operator genPlan(QB qb) throws SemanticException {
    
    // ★ Step 1: 处理子查询（自底向上，先处理最内层）
    for (String subqAlias : qb.getSubqAliases()) {
        QB subQB = qb.getSubqForAlias(subqAlias);
        Operator subqOp = genPlan(subQB);  // 递归！
        aliasToOpInfo.put(subqAlias, subqOp);
    }
    
    // ★ Step 2: 为每个输入表生成 TableScanOperator
    for (String alias : qb.getTabAliases()) {
        Operator top = genTablePlan(alias, qb);
        // top = TableScanOperator
        aliasToOpInfo.put(alias, top);
    }
    
    // ★ Step 3: 处理 LATERAL VIEW
    for (String alias : qb.getLateralViewAliases()) {
        Operator lateralViewOp = genLateralViewPlan(qb, alias);
        aliasToOpInfo.put(alias, lateralViewOp);
    }
    
    // ★ Step 4: 处理 JOIN
    Operator joinOp = null;
    if (qb.getParseInfo().getJoinExpr() != null) {
        // 生成 Join 的 Operator 子树
        // 包含: ReduceSinkOperator (多个输入) → JoinOperator
        joinOp = genJoinPlan(qb, aliasToOpInfo);
    }
    
    // ★ Step 5: 处理各 dest（每个 INSERT INTO / SELECT）
    Operator curr = (joinOp != null) ? joinOp : aliasToOpInfo.values().iterator().next();
    
    for (String dest : qb.getParseInfo().getClauseNames()) {
        
        // 5a: WHERE → FilterOperator
        ASTNode whereExpr = qb.getParseInfo().getWhrForClause(dest);
        if (whereExpr != null) {
            curr = genFilterPlan(qb, whereExpr, curr);
        }
        
        // 5b: GROUP BY → ReduceSinkOperator + GroupByOperator
        if (qb.getParseInfo().getGroupByForClause(dest) != null) {
            curr = genGroupByPlanMapReduce(dest, qb, curr);
        }
        
        // 5c: SELECT → SelectOperator
        curr = genSelectPlan(dest, qb, curr);
        
        // 5d: HAVING → FilterOperator
        ASTNode havingExpr = qb.getParseInfo().getHavingForClause(dest);
        if (havingExpr != null) {
            curr = genFilterPlan(qb, havingExpr, curr);
        }
        
        // 5e: ORDER BY / SORT BY → ReduceSinkOperator + ExtractOperator
        if (qb.getParseInfo().getOrderByForClause(dest) != null) {
            curr = genOrderByPlan(dest, qb, curr);
        }
        
        // 5f: LIMIT → LimitOperator
        Integer limit = qb.getParseInfo().getDestLimit(dest);
        if (limit != null) {
            curr = genLimitPlan(dest, qb, curr, limit);
        }
        
        // 5g: 输出 → FileSinkOperator
        curr = genFileSinkPlan(dest, qb, curr);
    }
    
    return curr;  // 返回 Operator Tree 的根节点
}
```

### 5.3 Operator Tree 示例

```sql
SELECT dept, COUNT(*) as cnt
FROM employees
WHERE age > 25
GROUP BY dept
HAVING COUNT(*) > 10
ORDER BY cnt DESC
LIMIT 100
```

生成的 Operator Tree:
```
TableScanOperator (employees)
  ↓
FilterOperator (age > 25)              ← WHERE
  ↓
ReduceSinkOperator (key=dept)          ← GROUP BY 的 Shuffle
  ↓
GroupByOperator (dept, count(*))       ← 聚合
  ↓
FilterOperator (count(*) > 10)         ← HAVING
  ↓
SelectOperator (dept, cnt)             ← SELECT 投影
  ↓
ReduceSinkOperator (key=cnt, order=DESC) ← ORDER BY 的 Shuffle
  ↓
LimitOperator (100)                    ← LIMIT
  ↓
FileSinkOperator                       ← 输出
```

---

## 六、类型检查（TypeCheckProcFactory）

在 Operator Tree 生成过程中，每个表达式都会经过类型检查：

```java
public class TypeCheckProcFactory {
    
    // 处理列引用
    static class ColumnExprProcessor implements SemanticNodeProcessor {
        public Object process(Node nd, ...) {
            // 验证列是否存在于表中
            // 解析列类型（INT, STRING, DOUBLE, ...）
            // 返回 ExprNodeColumnDesc
        }
    }
    
    // 处理函数调用
    static class FuncExprProcessor implements SemanticNodeProcessor {
        public Object process(Node nd, ...) {
            // 验证 UDF 是否注册
            // 检查参数类型是否匹配
            // 如果需要，插入隐式类型转换
            // 返回 ExprNodeGenericFuncDesc
        }
    }
    
    // 处理常量
    static class DefaultExprProcessor implements SemanticNodeProcessor {
        public Object process(Node nd, ...) {
            // 解析数值、字符串、布尔值等常量
            // 返回 ExprNodeConstantDesc
        }
    }
}
```

---

## 七、Hook 机制

```java
// Driver.compile() 中的 Hook 调用
List<HiveSemanticAnalyzerHook> saHooks = getHooks(
    HiveConf.ConfVars.SEMANTIC_ANALYZER_HOOK);

// 编译前 Hook
for (HiveSemanticAnalyzerHook hook : saHooks) {
    tree = hook.preAnalyze(hookCtx, tree);
    // 可以修改 AST！
}

// 执行语义分析
sem.analyze(tree, ctx);

// 编译后 Hook
for (HiveSemanticAnalyzerHook hook : saHooks) {
    hook.postAnalyze(hookCtx, sem.getAllRootTasks());
    // 可以修改执行计划！
}
```

---

## 八、关键数据流总结

```
SQL String
  ↓ ParseDriver.parse()
ASTNode (抽象语法树)
  ↓ SemanticAnalyzerFactory.get() 选择 Analyzer
  ↓ doPhase1() — AST 分块
QB (QueryBlock) + QBParseInfo (各子句的 AST 引用)
  ↓ getMetaData() — Metastore RPC
QB + QBMetaData (表名→Table对象、列名→ColumnInfo)
  ↓ genOPTree() / genPlan() — 生成 Operator
Operator Tree (TableScan→Filter→Select→Join→GroupBy→...)
  ↓ Optimizer.optimize() — 逻辑优化 (→ S09)
优化后的 Operator Tree
  ↓ TaskCompiler.compile() — 物理计划 (→ S10)
Task Tree (TezTask / MapRedTask)
```

---

## 九、源码文件索引

| 文件 | 路径 | 行数 | 职责 |
|------|------|------|------|
| **SemanticAnalyzer** | `ql/.../parse/SemanticAnalyzer.java` | 14000+ | 语义分析主类（最大的单个类） |
| **CalcitePlanner** | `ql/.../parse/CalcitePlanner.java` | 4000+ | CBO 版语义分析（继承 SemanticAnalyzer） |
| **SemanticAnalyzerFactory** | `ql/.../parse/SemanticAnalyzerFactory.java` | ~200 | 工厂：根据 SQL 类型选择 Analyzer |
| **QB** | `ql/.../parse/QB.java` | ~500 | QueryBlock 数据结构 |
| **QBParseInfo** | `ql/.../parse/QBParseInfo.java` | ~800 | 各子句信息存储 |
| **QBMetaData** | `ql/.../parse/QBMetaData.java` | ~200 | 元数据存储 |
| **QBJoinTree** | `ql/.../parse/QBJoinTree.java` | ~300 | Join 树结构 |
| **TypeCheckProcFactory** | `ql/.../parse/TypeCheckProcFactory.java` | ~2000 | 类型检查 |
| **Operator** | `ql/.../exec/Operator.java` | ~1500 | Operator 基类 |
