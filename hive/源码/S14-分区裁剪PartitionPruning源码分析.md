# S14 - Hive 分区裁剪 PartitionPruning 源码深度分析

> **知识晶体化模板** | 基于 Hive 3.x 源码 | 作者: Eric (豹纹) for 大哥

---

## 一、问题/场景

分区裁剪是 Hive 查询优化中最重要的优化之一，直接决定了需要扫描的数据量：

1. **全表扫描**: WHERE 条件中没有分区列，导致扫描所有分区
2. **裁剪失败**: 使用了 UDF 或类型转换，Metastore 无法下推过滤
3. **动态分区裁剪 (DPP) 不生效**: JOIN 条件中的分区列未被识别为 DPP 候选
4. **严格模式报错**: `hive.strict.checks.no.partition.filter=true` 但查询缺少分区过滤

**核心源码**:
- 静态裁剪: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/ppr/PartitionPruner.java`
- 动态裁剪: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/DynamicPartitionPruningOptimization.java`
- 表达式求值: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/ppr/PartExprEvalUtils.java`

---

## 二、架构概览 — 两种裁剪机制

```
┌──────────────────────────────────────────────────────────────┐
│              Hive 分区裁剪两阶段                              │
│                                                              │
│  阶段1: 静态分区裁剪 (编译期)                                 │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━                                │
│  WHERE dt = '2024-01-01' AND country = 'US'                  │
│       ↓                                                      │
│  PartitionPruner.prune()                                     │
│       ├─ 提取分区列表达式                                     │
│       ├─ 移除非分区列 (替换为null/true)                       │
│       ├─ 压缩表达式 (compactExpr)                             │
│       └─ 发送给 Metastore 过滤 → 返回匹配分区列表             │
│                                                              │
│  阶段2: 动态分区裁剪 (运行期, Tez/Spark)                      │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                       │
│  SELECT * FROM fact_table f JOIN dim_table d                  │
│  ON f.dt = d.dt WHERE d.status = 'active'                    │
│       ↓                                                      │
│  DynamicPartitionPruningOptimization                         │
│       ├─ 识别 JOIN 条件中的分区列                              │
│       ├─ 在 dim_table 侧插入聚合算子 (收集分区值)             │
│       ├─ 运行时将分区值集合传递给 fact_table 的 TableScan      │
│       └─ 使用 BloomFilter 或 IN list 裁剪分区                 │
└──────────────────────────────────────────────────────────────┘
```

---

## 三、核心源码分析

### 3.1 PartitionPruner — 静态分区裁剪

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/ppr/PartitionPruner.java`

#### 3.1.1 transform() — 优化器入口

```java
// PartitionPruner.java:76-99
public class PartitionPruner extends Transform {
    @Override
    public ParseContext transform(ParseContext pctx) throws SemanticException {
        // 1. 创建上下文 (包含每个 TableScan 的分区裁剪表达式)
        OpWalkerCtx opWalkerCtx = new OpWalkerCtx(pctx.getOpToPartPruner());
        
        // 2. 遍历算子树，提取分区裁剪表达式
        PrunerUtils.walkOperatorTree(pctx, opWalkerCtx, 
            OpProcFactory.getFilterProc(),    // Filter 算子处理器
            OpProcFactory.getDefaultProc());  // 默认处理器
        return pctx;
    }
}
```

#### 3.1.2 prune() — 核心裁剪方法

```java
// PartitionPruner.java:169-231
public static PrunedPartitionList prune(Table tab, ExprNodeDesc prunerExpr,
    HiveConf conf, String alias, Map<String, PrunedPartitionList> prunedPartitionsMap) {
    
    // 1. 非分区表：直接返回
    if (!tab.isPartitioned()) {
        return getAllPartsFromCacheOrServer(tab, key, false, prunedPartitionsMap);
    }
    
    // 2. 严格模式检查
    if (!hasColumnExpr(prunerExpr)) {
        String error = StrictChecks.checkNoPartitionFilter(conf);
        if (error != null) {
            throw new SemanticException(error + " No partition predicate for Alias \""
                + alias + "\" Table \"" + tab.getTableName() + "\"");
        }
    }
    
    // 3. 无谓词 → 返回所有分区
    if (prunerExpr == null) {
        return getAllPartsFromCacheOrServer(tab, key, false, prunedPartitionsMap);
    }
    
    // 4. 核心步骤: 提取分区列表达式
    Set<String> partColsUsedInFilter = new LinkedHashSet<>();
    
    // 4a. 移除非分区列 (替换为 null)
    prunerExpr = removeNonPartCols(prunerExpr, extractPartColNames(tab), partColsUsedInFilter);
    
    // 4b. 压缩表达式 (消除 null 和冗余)
    ExprNodeDesc compactExpr = compactExpr(prunerExpr.clone());
    
    // 5. 压缩结果判断
    if (compactExpr == null || isBooleanExpr(compactExpr)) {
        if (isFalseExpr(compactExpr)) {
            return new PrunedPartitionList(tab, key, emptySet, emptyList, false);  // 不可能满足
        }
        return getAllPartsFromCacheOrServer(tab, key, true, prunedPartitionsMap);  // 无法裁剪
    }
    
    // 6. 缓存检查
    PrunedPartitionList ppList = prunedPartitionsMap.get(key);
    if (ppList != null) return ppList;
    
    // 7. 发送给 Metastore 获取匹配的分区
    ppList = getPartitionsFromServer(tab, key, compactExpr, conf, alias, 
        partColsUsedInFilter, isExactFilter);
    prunedPartitionsMap.put(key, ppList);
    return ppList;
}
```

**调用链 — 静态分区裁剪完整流程**:
```
SQL: SELECT * FROM orders WHERE dt = '2024-01-01' AND amount > 100;

1. SemanticAnalyzer 生成 Filter 算子
   FilterOperator(predicate: dt='2024-01-01' AND amount>100)
       ↓
2. PartitionPruner.transform()
   → PrunerUtils.walkOperatorTree()
   → OpProcFactory.getFilterProc() 提取分区相关表达式
       ↓
3. PartitionPruner.prune()
   ├─ removeNonPartCols(): 
   │   dt='2024-01-01' AND amount>100 
   │   → dt='2024-01-01' AND TRUE (amount 非分区列，替换为 TRUE)
   │
   ├─ compactExpr():
   │   dt='2024-01-01' AND TRUE 
   │   → dt='2024-01-01' (压缩掉 TRUE)
   │
   └─ getPartitionsFromServer():
       ├─ 优先: Metastore 端过滤
       │   Hive.getPartitionsByExpr(tab, "dt='2024-01-01'")
       │   → SELECT * FROM PARTITIONS WHERE PART_KEY_VAL1='2024-01-01'
       │
       └─ 回退: 客户端过滤 (UDF 等不可下推)
           Hive.getAllPartitionsOf(tab) 
           → PartExprEvalUtils.evalExprWithPart() 逐个求值
```

#### 3.1.3 removeNonPartCols() — 提取分区列表达式

```java
// PartitionPruner.java:376-414
static private ExprNodeDesc removeNonPartCols(ExprNodeDesc expr, List<String> partCols, Set<String> referred) {
    if (expr instanceof ExprNodeColumnDesc) {
        String column = ((ExprNodeColumnDesc) expr).getColumn();
        if (!partCols.contains(column)) {
            // 非分区列 → 替换为类型匹配的 null 常量
            return new ExprNodeConstantDesc(expr.getTypeInfo(), null);
        }
        referred.add(column);
    }
    else if (expr instanceof ExprNodeGenericFuncDesc) {
        List<ExprNodeDesc> children = expr.getChildren();
        for (int i = 0; i < children.size(); ++i) {
            ExprNodeDesc other = removeNonPartCols(children.get(i), partCols, referred);
            if (ExprNodeDescUtils.isNullConstant(other)) {
                if (FunctionRegistry.isOpAnd(expr)) {
                    // AND 中的非分区条件替换为 TRUE
                    // WHERE dt='20240101' AND col1>5  →  dt='20240101' AND TRUE
                    other = new ExprNodeConstantDesc(expr.getTypeInfo(), true);
                } else {
                    // OR/其他函数中的非分区条件 → 传播 null (表示无法裁剪)
                    // WHERE dt='20240101' OR col1>5  →  无法裁剪 (null传播)
                    return new ExprNodeConstantDesc(expr.getTypeInfo(), null);
                }
            }
            children.set(i, other);
        }
    }
    return expr;
}
```

**关键逻辑**: AND 和 OR 的处理不同：
- `A AND B`: 非分区条件替换为 TRUE → 只保留分区条件（安全，不会过度裁剪）
- `A OR B`: 非分区条件传播 null → 整个 OR 被判定为无法裁剪（保守，避免遗漏数据）

#### 3.1.4 compactExpr() — 表达式压缩

```java
// PartitionPruner.java:277-364 (核心逻辑)
static ExprNodeDesc compactExpr(ExprNodeDesc expr) {
    if (expr instanceof ExprNodeGenericFuncDesc) {
        GenericUDF udf = ((ExprNodeGenericFuncDesc)expr).getGenericUDF();
        boolean isAnd = udf instanceof GenericUDFOPAnd;
        boolean isOr = udf instanceof GenericUDFOPOr;
        
        if (isAnd) {
            // AND: null子节点移除, TRUE子节点移除, FALSE→整体FALSE
            // dt='20240101' AND TRUE → dt='20240101'
            // dt='20240101' AND FALSE → FALSE (没有匹配分区)
        }
        
        if (isOr) {
            // OR: null子节点 → 整体null (无法裁剪)
            // TRUE子节点 → 整体TRUE (所有分区)
            // FALSE子节点移除
        }
    }
    return expr;
}
```

#### 3.1.5 getPartitionsFromServer() — 服务端/客户端过滤

```java
// PartitionPruner.java:435-530 (简化)
private static PrunedPartitionList getPartitionsFromServer(Table tab, String key, 
    ExprNodeGenericFuncDesc compactExpr, HiveConf conf, ...) {
    
    // 检查是否包含自定义 UDF (不可下推)
    boolean doEvalClientSide = hasUserFunctions(compactExpr);
    
    if (!doEvalClientSide) {
        // 路径1: Metastore 端过滤 (高效)
        // 将表达式序列化后发送给 Metastore
        hasUnknownPartitions = tab.getPartitionsByExpr(compactExpr, partitions);
    }
    
    if (hasUnknownPartitions || doEvalClientSide) {
        // 路径2: 客户端过滤 (慢，需要获取所有分区)
        // 获取所有分区，然后逐个用 ExprNodeEvaluator 求值
        Set<Partition> allParts = getAllPartitions(tab);
        for (Partition part : allParts) {
            if (evalExprWithPart(compactExpr, part)) {
                partitions.add(part);
            }
        }
    }
}
```

---

### 3.2 PartExprEvalUtils — 表达式对分区求值

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/ppr/PartExprEvalUtils.java`

```java
// PartExprEvalUtils.java:55-100
static synchronized public Object evalExprWithPart(ExprNodeDesc expr,
    Partition p, List<VirtualColumn> vcs, StructObjectInspector rowObjectInspector) {
    
    LinkedHashMap<String, String> partSpec = p.getSpec();
    
    // 1. 构建分区列的值和 ObjectInspector
    ArrayList<Object> partValues = new ArrayList<>();
    ArrayList<ObjectInspector> partObjectInspectors = new ArrayList<>();
    for (Map.Entry<String, String> entry : partSpec.entrySet()) {
        ObjectInspector oi = PrimitiveObjectInspectorFactory
            .getPrimitiveWritableObjectInspector(TypeInfoFactory.getPrimitiveTypeInfo(partKeyTypes[i++]));
        partValues.add(ObjectInspectorConverters.getConverter(
            PrimitiveObjectInspectorFactory.javaStringObjectInspector, oi)
            .convert(entry.getValue()));
        partObjectInspectors.add(oi);
    }
    
    // 2. 构建行对象 [null, partValues, vcValues]
    Object[] rowWithPart = new Object[hasVC ? 3 : 2];
    rowWithPart[1] = partValues;
    
    // 3. 使用 ExprNodeEvaluator 求值
    ExprNodeEvaluator evaluator = ExprNodeEvaluatorFactory.get(expr);
    ObjectInspector evaluateResultOI = evaluator.initialize(rowWithPartObjectInspector);
    Object evaluateResultO = evaluator.evaluate(rowWithPart);
    
    return evaluateResultO;  // Boolean: true=分区匹配, false=不匹配
}
```

---

### 3.3 DynamicPartitionPruningOptimization — 动态分区裁剪

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/DynamicPartitionPruningOptimization.java`

动态分区裁剪 (DPP) 是 Tez/Spark 引擎特有的运行时优化。

```java
// DynamicPartitionPruningOptimization.java:91-99
/**
 * This optimization looks for expressions of the kind "x IN (RS[n])". If such
 * an expression made it to a table scan operator and x is a partition column we
 * can use an existing join to dynamically prune partitions.
 */
public class DynamicPartitionPruningOptimization implements NodeProcessor {
    // ...
}
```

**DPP 工作原理**:

```
原始计划:
  TableScan(fact, part_col=dt) → Filter → Join → ...
  TableScan(dim) → Filter(status='active') → Join

DPP 优化后:
  TableScan(fact, part_col=dt) → Filter(dt IN [动态值]) → Join → ...
                                          ↑
  TableScan(dim) → Filter(status='active') → Aggregate(DISTINCT dt) → 传递值
                                              └─ BloomFilter 或 值列表
```

**核心逻辑**:
1. 识别 JOIN 条件中的分区列（`f.dt = d.dt`）
2. 在维度表侧插入聚合算子，收集分区列的值集合
3. 运行时将值集合传递给事实表的 TableScan
4. TableScan 根据值集合动态裁剪分区

---

## 四、调用链总结

```
SQL: SELECT * FROM orders o JOIN dates d ON o.dt = d.dt WHERE d.holiday = true;

═══ 编译期: 静态分区裁剪 ═══

1. SemanticAnalyzer 解析 → 生成算子树
2. PartitionPruner.transform()
   └─ 遍历 FilterOperator，提取分区相关谓词
      └─ o.dt 出现在 JOIN 条件中，不在 WHERE 中 → 静态裁剪无法生效
      └─ 返回所有分区（静态裁剪失败）

═══ Tez 物理优化: 动态分区裁剪 ═══

3. OptimizeTezProcContext 
   └─ DynamicPartitionPruningOptimization.process()
      ├─ 发现 o.dt = d.dt 且 dt 是分区列
      ├─ 在 d 的 ReduceSink 后插入聚合: GROUP BY d.dt
      ├─ 生成 BloomFilter (如果分区数太多)
      └─ 在 o 的 TableScan 前插入 DynamicPruningEvent

═══ 运行时 ═══

4. Tez DAG 执行:
   ├─ Vertex-1: 扫描 dates 表 → Filter(holiday=true) → 聚合 dt 值
   │            → 产生值集合: {2024-01-01, 2024-12-25, ...}
   │
   ├─ 值集合通过 Tez Event 传递给 Vertex-2
   │
   └─ Vertex-2: 收到 DPP Event → TableScan(orders) 只扫描匹配的分区
               → dt IN ('2024-01-01', '2024-12-25', ...)
```

---

## 五、关键参数与调优建议

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.strict.checks.no.partition.filter` | false | 严格模式：无分区过滤则报错 |
| `hive.optimize.pruner` | true | 是否启用静态分区裁剪 |
| `hive.tez.dynamic.partition.pruning` | true | 是否启用 Tez DPP |
| `hive.tez.dynamic.partition.pruning.max.event` | 100 | DPP 最大事件数 |
| `hive.tez.dynamic.partition.pruning.max.data.size` | 100MB | DPP 值集合最大数据量 |
| `hive.spark.dynamic.partition.pruning` | false | 是否启用 Spark DPP |
| `hive.optimize.metadataonly` | false | 只用元数据回答查询 |

### 调优建议

1. **生产环境开启严格模式**: `hive.strict.checks.no.partition.filter=true`
2. **确保 DPP 开启**: `hive.tez.dynamic.partition.pruning=true`
3. **避免分区列类型转换**: `WHERE dt = 20240101` (dt 是 string 类型) → 类型不匹配，裁剪可能失败
4. **避免分区列上使用函数**: `WHERE year(dt) = 2024` → 无法裁剪，改为 `WHERE dt >= '2024-01-01' AND dt < '2025-01-01'`

---

## 六、踩坑记录

### 6.1 OR 条件导致裁剪失效

**现象**: `WHERE dt = '2024-01-01' OR amount > 100` 扫描了所有分区

**根因**: `removeNonPartCols()` 中 OR 逻辑：非分区条件产生 null → 整个 OR 无法裁剪。这是正确行为，因为 `amount > 100` 可能在任何分区中为 true。

**解决**: 改写为子查询或 UNION ALL。

### 6.2 UDF 阻止 Metastore 下推

**现象**: 自定义 UDF 处理分区列时，性能严重下降。

**源码证据** (PartitionPruner.java:441):
```java
boolean doEvalClientSide = hasUserFunctions(compactExpr);
```

**根因**: 含 UDF 的表达式无法序列化到 Metastore 执行，退化为客户端逐分区求值。

### 6.3 DPP 传递数据量过大

**现象**: DPP Event 过大导致 AM 内存溢出。

**解决**: 调小 `hive.tez.dynamic.partition.pruning.max.data.size`，超过阈值时 DPP 自动降级使用 BloomFilter。

---

## 七、总结

Hive 分区裁剪是两阶段优化：

1. **静态裁剪（编译期）**: `PartitionPruner` 从 WHERE 条件中提取分区列表达式，发送给 Metastore 过滤
   - AND 中的非分区条件安全移除
   - OR 中的非分区条件导致整体无法裁剪
   - 含 UDF 时退化为客户端求值

2. **动态裁剪（运行期）**: `DynamicPartitionPruningOptimization` 利用 JOIN 条件在运行时传递分区值
   - 需要 Tez/Spark 引擎支持
   - 通过 BloomFilter 或值列表实现
   - 对 star schema 的查询效果显著
