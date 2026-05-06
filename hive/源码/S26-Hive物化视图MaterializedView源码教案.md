# [教案] Hive物化视图(MaterializedView)注册与重写源码深度剖析

> 🎯 教学目标：掌握HiveMaterializedViewsRegistry的注册管理机制、自动重写匹配流程、增量维护(REBUILD)的源码实现  
> ⏰ 预计学时：3学时  
> 📊 难度：⭐⭐⭐⭐（中高级）

---

## 一、课前导入（生活类比引入）

### 1.1 生活类比：预制菜中央厨房

想象一家连锁餐厅：
- **没有预制菜**：每道菜从洗菜→切菜→炒菜→装盘，耗时30分钟
- **有预制菜**：中央厨房提前做好半成品，门店加热5分钟出餐

物化视图就是SQL世界的"预制菜"：
- **建立MV** = 中央厨房提前烹制半成品
- **自动重写** = 点单时识别"这道菜可以用预制菜"
- **增量维护** = 原料更新时只补充新增部分，不全部重做

### 1.2 生产故障场景

```sql
-- 已创建物化视图
CREATE MATERIALIZED VIEW mv_daily_sales 
STORED AS ORC TBLPROPERTIES ('transactional'='true')
AS SELECT region, product_category, sale_date, SUM(amount) as total
   FROM sales GROUP BY region, product_category, sale_date;

-- 用户查询（预期使用MV）
SELECT region, SUM(amount) FROM sales 
WHERE sale_date >= '2024-01-01' GROUP BY region;
-- 实际未使用MV，全表扫描 → 执行45分钟
```

**问题根因**：MV Registry未正确初始化 / MV被标记为过期 / 重写规则未匹配

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 含义 | 类比 |
|------|------|------|
| MaterializedView | 预计算并持久化的视图结果 | 预制菜 |
| Registry | MV注册表（HS2内存缓存） | 菜品目录册 |
| RelOptMaterialization | Calcite物化对象（viewScan + queryRel） | 菜品+配方 |
| REBUILD | 增量/全量刷新MV数据 | 补货/换货 |
| Rewrite Enabled | MV允许被查询优化器自动使用 | 上架状态 |
| Staleness | MV过期状态（源表数据已变化） | 保质期 |

### 2.2 物化视图生命周期架构

```
┌────────────────────────────────────────────────────────────────┐
│                   Materialized View Lifecycle                    │
├─────────┬─────────────┬──────────────┬─────────────────────────┤
│ CREATE  │  REGISTER   │   REWRITE    │      REBUILD            │
├─────────┼─────────────┼──────────────┼─────────────────────────┤
│         │             │              │                         │
│ DDL →   │ Registry →  │ Query来了 →  │ 数据过期 →              │
│ HMS存储 │ 缓存解析后   │ 匹配MV →    │ 增量MERGE /             │
│ + ORC   │ 的RelNode   │ 替换查询计划 │ 全量INSERT OVERWRITE    │
│         │             │              │                         │
│ Hive.   │ HiveMaterial│ HiveMaterial │ HiveAggregateIncremental│
│ create  │ izedViews   │ izedViewRule │ RewritingRule           │
│ Table() │ Registry    │              │                         │
│         │ .addMV()    │              │                         │
└─────────┴─────────────┴──────────────┴─────────────────────────┘
```

### 2.3 核心类关系

```
HiveMaterializedViewsRegistry (单例)
    ├── materializedViews: ConcurrentMap<dbName, Map<viewName, RelOptMaterialization>>
    ├── init() → Loader线程异步加载所有MV
    ├── createMaterializedView() → 新建MV时注册
    ├── dropMaterializedView() → 删除MV时反注册
    └── getRewritingMaterializedView() → 查询时获取候选MV

RelOptMaterialization
    ├── tableRel: RelNode (viewScan - MV的TableScan)
    ├── queryRel: RelNode (原始查询的逻辑计划)
    └── qualifiedTableName: List<String>
```

---

## 三、源码深度剖析

### 3.1 Registry单例与初始化

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/metadata/HiveMaterializedViewsRegistry.java`

#### 3.1.1 单例模式（第88-116行）

```java
public final class HiveMaterializedViewsRegistry {
    private static final Logger LOG = LoggerFactory.getLogger(HiveMaterializedViewsRegistry.class);
    
    /* 单例实例 */
    private static final HiveMaterializedViewsRegistry SINGLETON = new HiveMaterializedViewsRegistry();
    
    /* 核心数据结构：DB名 → (视图名 → 物化对象) */
    private final ConcurrentMap<String, ConcurrentMap<String, RelOptMaterialization>> materializedViews =
        new ConcurrentHashMap<>();
    
    /* 是否为Dummy模式（不缓存，每次都查Metastore） */
    private boolean dummy;
    
    /* 初始化状态 */
    private AtomicBoolean initialized = new AtomicBoolean(false);
    
    private HiveMaterializedViewsRegistry() { }
    
    public static HiveMaterializedViewsRegistry get() {
        return SINGLETON;
    }
}
```

**设计考量**：
- ConcurrentHashMap保证线程安全（HS2多Session并发访问）
- AtomicBoolean保证初始化状态的可见性
- 两级Map结构：先按DB分组，再按视图名索引

#### 3.1.2 初始化流程（第126-176行）

```java
public void init() {
    try {
        // 创建绕过授权的HiveConf（需要读取所有DB的MV）
        HiveConf conf = new HiveConf();
        conf.set(MetastoreConf.ConfVars.FILTER_HOOK.getVarname(),
            DefaultMetaStoreFilterHookImpl.class.getName());
        init(Hive.get(conf));
    } catch (HiveException e) {
        LOG.error("Problem connecting to the metastore when initializing the view registry", e);
    }
}

public void init(Hive db) {
    dummy = db.getConf().get(
        HiveConf.ConfVars.HIVE_SERVER2_MATERIALIZED_VIEWS_REGISTRY_IMPL.varname)
        .equals("DUMMY");
    
    if (dummy) {
        // Dummy模式：不缓存，直接标记已初始化
        initialized.set(true);
        LOG.info("Using dummy materialized views registry");
    } else {
        // 正常模式：异步加载
        ExecutorService pool = Executors.newCachedThreadPool();
        pool.submit(new Loader(db));
        pool.shutdown();
    }
}
```

#### 3.1.3 Loader异步加载器（第154-176行）

```java
private class Loader implements Runnable {
    private final Hive db;
    
    @Override
    public void run() {
        try {
            SessionState.start(db.getConf());
            // 遍历所有数据库
            for (String dbName : db.getAllDatabases()) {
                // 获取每个DB下所有物化视图
                for (Table mv : db.getAllMaterializedViewObjects(dbName)) {
                    addMaterializedView(db.getConf(), mv, OpType.LOAD);
                }
            }
            initialized.set(true);
            LOG.info("Materialized views registry has been initialized");
        } catch (HiveException e) {
            LOG.error("Problem connecting to the metastore", e);
        }
    }
}
```

**关键时序**：
1. HS2启动 → 调用`init()`
2. 创建异步线程池 → 提交Loader任务
3. Loader遍历所有DB → 逐个加载MV
4. 设置`initialized=true` → Registry可用

**风险点**：HS2启动后、Loader完成前的查询窗口期内，MV重写不可用！

---

### 3.2 MV注册核心方法：addMaterializedView

> 📁 第196-246行

```java
private RelOptMaterialization addMaterializedView(HiveConf conf, Table materializedViewTable, OpType opType) {
    // 检查1：是否启用重写
    if (!materializedViewTable.isRewriteEnabled()) {
        LOG.debug("Materialized view " + materializedViewTable.getCompleteName() +
            " ignored; it is not rewrite enabled");
        return null;
    }
    
    // 检查2：获取或创建DB级别的Map
    ConcurrentMap<String, RelOptMaterialization> cq = new ConcurrentHashMap<>();
    if (!dummy) {
        final ConcurrentMap<String, RelOptMaterialization> prevCq = 
            materializedViews.putIfAbsent(materializedViewTable.getDbName(), cq);
        if (prevCq != null) {
            cq = prevCq;  // 已存在则复用
        }
    }
    
    // 步骤1：创建MV的TableScan节点（替代计划）
    final RelNode viewScan = createMaterializedViewScan(conf, materializedViewTable);
    if (viewScan == null) {
        LOG.warn("error creating view replacement");
        return null;
    }
    
    // 步骤2：解析MV的原始定义SQL → 逻辑计划
    final String viewQuery = materializedViewTable.getViewExpandedText();
    final RelNode queryRel = parseQuery(conf, viewQuery);
    if (queryRel == null) {
        LOG.warn("error parsing original query");
        return null;
    }
    
    // 步骤3：构建RelOptMaterialization对象
    RelOptMaterialization materialization = new RelOptMaterialization(
        viewScan, queryRel, null, viewScan.getTable().getQualifiedName());
    
    // 步骤4：根据操作类型存储
    if (opType == OpType.CREATE) {
        cq.put(materializedViewTable.getTableName(), materialization);
    } else {
        // LOAD模式：仅在不存在时添加（避免覆盖更新的版本）
        cq.putIfAbsent(materializedViewTable.getTableName(), materialization);
    }
    
    return materialization;
}
```

**设计精妙之处**：
- `putIfAbsent`保证并发安全：多线程同时加载同一MV时不会相互覆盖
- CREATE vs LOAD语义区分：新创建的MV直接覆盖；加载时不覆盖已有的（可能更新）

---

### 3.3 创建MV的TableScan节点

> 📁 第287-404行

```java
private static RelNode createMaterializedViewScan(HiveConf conf, Table viewTable) {
    // 0. 创建Calcite集群环境
    final RelOptPlanner planner = CalcitePlanner.createPlanner(conf);
    final RexBuilder rexBuilder = new RexBuilder(
        new JavaTypeFactoryImpl(new HiveTypeSystemImpl()));
    final RelOptCluster cluster = RelOptCluster.create(planner, rexBuilder);
    
    // 1. 构建列Schema
    final RowResolver rr = new RowResolver();
    StructObjectInspector rowObjectInspector = 
        (StructObjectInspector) viewTable.getDeserializer().getObjectInspector();
    
    // 1.1 非分区列
    ArrayList<ColumnInfo> nonPartitionColumns = new ArrayList<>();
    for (StructField field : rowObjectInspector.getAllStructFieldRefs()) {
        ColumnInfo colInfo = new ColumnInfo(field.getFieldName(), 
            TypeInfoUtils.getTypeInfoFromObjectInspector(field.getFieldObjectInspector()),
            null, false);
        rr.put(null, field.getFieldName(), colInfo);
        nonPartitionColumns.add(colInfo);
    }
    
    // 1.2 分区列
    ArrayList<ColumnInfo> partitionColumns = new ArrayList<>();
    for (FieldSchema part_col : viewTable.getPartCols()) {
        ColumnInfo colInfo = new ColumnInfo(part_col.getName(),
            TypeInfoFactory.getPrimitiveTypeInfo(part_col.getType()), null, true);
        rr.put(null, part_col.getName(), colInfo);
        partitionColumns.add(colInfo);
    }
    
    // 1.3 类型转换
    RelDataType rowType = TypeConverter.getType(cluster, rr, null);
    
    // 2. 构建RelOptHiveTable
    RelOptHiveTable optTable = new RelOptHiveTable(null, fullyQualifiedTabName,
        rowType, viewTable, nonPartitionColumns, partitionColumns, ...);
    
    // 3. 根据存储类型创建不同的TableScan
    if (obtainTableType(viewTable) == TableType.DRUID) {
        // Druid存储：创建DruidQuery
        return DruidQuery.create(cluster, ...);
    } else {
        // Hive原生存储：创建HiveTableScan
        return new HiveTableScan(cluster, 
            cluster.traitSetOf(HiveRelNode.CONVENTION), optTable, ...);
    }
}
```

### 3.4 解析MV定义SQL

> 📁 第406-422行

```java
private static RelNode parseQuery(HiveConf conf, String viewQuery) {
    try {
        // 1. 语法解析
        final ASTNode node = ParseUtils.parse(viewQuery);
        
        // 2. 创建语义分析器
        final QueryState qs = new QueryState.Builder().withHiveConf(conf).build();
        CalcitePlanner analyzer = new CalcitePlanner(qs);
        
        // 3. 设置加载MV标志（避免递归）
        Context ctx = new Context(conf);
        ctx.setIsLoadingMaterializedView(true);  // 关键！
        analyzer.initCtx(ctx);
        analyzer.init(false);
        
        // 4. 生成逻辑计划
        return analyzer.genLogicalPlan(node);
    } catch (Exception e) {
        LOG.error("Error parsing original query for materialized view", e);
        return null;
    }
}
```

**关键设计**：`setIsLoadingMaterializedView(true)` 防止在解析MV定义时再次尝试用其他MV重写（避免递归死循环）。

---

### 3.5 MV删除与过期处理

```java
// 第253-272行：删除MV
public void dropMaterializedView(String dbName, String tableName) {
    if (dummy) return;  // Dummy模式无需操作
    
    ConcurrentMap<String, RelOptMaterialization> dbMap = materializedViews.get(dbName);
    if (dbMap != null) {
        dbMap.remove(tableName);
    }
}
```

### 3.6 MV获取（查询时调用）

```java
// 第280-285行
RelOptMaterialization getRewritingMaterializedView(String dbName, String viewName) {
    if (materializedViews.get(dbName) != null) {
        return materializedViews.get(dbName).get(viewName);
    }
    return null;
}
```

---

### 3.7 物化视图增量维护(REBUILD)

#### 3.7.1 HiveAggregateIncrementalRewritingRule

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/views/HiveAggregateIncrementalRewritingRule.java`

增量维护的核心思想：

```
旧数据（MV已有）：mv = {(A,B,SUM_A_B,COUNT_A_B)}
新数据（增量查询）：source = SELECT a, b, SUM(x), COUNT(*) FROM new_data GROUP BY a, b

增量MERGE：
- MATCHED行：SUM = mv.SUM + source.SUM, COUNT = mv.COUNT + source.COUNT
- NOT MATCHED行：直接INSERT
```

```java
// 第95-173行：核心onMatch
@Override
public void onMatch(RelOptRuleCall call) {
    final Aggregate agg = call.rel(0);
    final Union union = call.rel(1);
    
    // 左输入=MV旧数据，右输入=增量数据
    final RelNode joinLeftInput = union.getInput(1);  // MV
    final RelNode joinRightInput = union.getInput(0); // New Data
    
    // 构建GROUP BY列的JOIN条件
    for (int leftPos = 0; leftPos < groupCount; leftPos++) {
        joinConjs.add(EQUALS(leftRef, rightRef));      // mv.a = source.a
        filterConjs.add(IS_NULL(leftRef));             // mv.a IS NULL (新行标识)
    }
    
    // 构建聚合列的MERGE表达式
    for (AggregateCall aggCall : agg.getAggCallList()) {
        switch (aggCall.getKind()) {
            case SUM:
                // mv.sum + source.sum
                elseReturn = PLUS(rightRef, leftRef);
                break;
            case MIN:
                // CASE WHEN source.min < mv.min THEN source.min ELSE mv.min
                elseReturn = CASE(LESS_THAN(rightRef, leftRef), rightRef, leftRef);
                break;
            case MAX:
                // CASE WHEN source.max > mv.max THEN source.max ELSE mv.max
                elseReturn = CASE(GREATER_THAN(rightRef, leftRef), rightRef, leftRef);
                break;
        }
        // 完整CASE：新行直接用source值，已有行做合并计算
        projExprs.add(CASE(isNewRow, rightRef, elseReturn));
    }
    
    // 最终计划：RIGHT JOIN → FILTER → PROJECT
    RelNode newNode = builder
        .push(mvInput).push(sourceInput)
        .join(JoinRelType.RIGHT, joinCond)
        .filter(OR(joinCond, filterCond))
        .project(projExprs)
        .build();
    
    call.transformTo(newNode);
}
```

#### 3.7.2 HiveNoAggregateIncrementalRewritingRule

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/views/HiveNoAggregateIncrementalRewritingRule.java`

无聚合场景更简单：直接将INSERT OVERWRITE改为INSERT INTO（追加新数据）。

#### 3.7.3 可行性检查器：MaterializedViewRewritingRelVisitor

```java
// 检查规则：
// 1. 计划树必须包含Union（MV旧数据 UNION ALL 新数据）
// 2. Union必须恰好2个分支
// 3. 第一分支（新数据）只允许：TableScan/Filter/Project/Join/Aggregate
// 4. 第二分支（MV引用）必须指向物化视图表
// 5. 含聚合时，MV表必须是Full ACID表（支持MERGE操作）
```

---

### 3.8 调用链时序图

```
┌──────┐     ┌─────────┐    ┌──────────┐    ┌──────────────────┐
│ HS2  │     │ Registry│    │ Metastore│    │ CalcitePlanner   │
│Start │     │         │    │          │    │                  │
└──┬───┘     └────┬────┘    └────┬─────┘    └────────┬─────────┘
   │              │              │                    │
   │─init()──────▶│              │                    │
   │              │─getAllDBs()──▶│                    │
   │              │◀─[db1,db2]───│                    │
   │              │              │                    │
   │              │─getMVs(db1)─▶│                    │
   │              │◀─[mv1,mv2]──│                    │
   │              │              │                    │
   │              │──parseQuery(mv1.sql)─────────────▶│
   │              │◀─────────────queryRel─────────────│
   │              │              │                    │
   │              │──createMVScan(mv1)               │
   │              │──store(db1, mv1, materialization) │
   │              │              │                    │
   │              │─initialized=true                  │
   │              │              │                    │
   │              │              │                    │
   │  === 查询阶段 ===           │                    │
   │              │              │                    │
   │─query───────▶│              │                    │
   │              │              │    ┌───────────────────────┐
   │              │              │    │HiveMaterializedViewRule│
   │              │              │    └───────────┬───────────┘
   │              │              │                │
   │              │◀─getMVs(dbName)───────────────│
   │              │─return List<Materialization>──▶│
   │              │              │                │─match(queryRel,mvQueryRel)
   │              │              │                │─success → transformTo(viewScan)
```

---

## 四、生产实战案例

### 4.1 案例一：MV创建后未被使用

**排障流程**：

```sql
-- 1. 确认MV状态
SHOW MATERIALIZED VIEWS IN default;
DESCRIBE FORMATTED mv_daily_sales;

-- 2. 检查REWRITE是否启用
-- 查看 Table Parameters 中的 rewrite.enabled
-- 如果为 false：
ALTER MATERIALIZED VIEW mv_daily_sales ENABLE REWRITE;

-- 3. 检查Registry实现
SET hive.server2.materialized.views.registry.impl;
-- 值不能是 DUMMY

-- 4. 检查MV是否过期（源表有新数据）
SHOW TBLPROPERTIES mv_daily_sales ('rewrite.fromOpenTxnSCN');
-- 如果源表有新事务，需要REBUILD
ALTER MATERIALIZED VIEW mv_daily_sales REBUILD;

-- 5. 确认CBO和MV重写开关
SET hive.cbo.enable;              -- 必须 true
SET hive.materializedview.rewriting; -- 必须 true
```

### 4.2 案例二：REBUILD失败

**故障现象**：`ALTER MATERIALIZED VIEW mv REBUILD` 报OOM

**分析**：
- MV含聚合，源表为Full ACID表
- 增量重写被触发，但新增数据量极大
- RIGHT JOIN时笛卡尔积爆内存

**解决方案**：
```sql
-- 方案1：降级为全量重写
SET hive.materializedview.rebuild.incremental=false;
ALTER MATERIALIZED VIEW mv REBUILD;

-- 方案2：增加容器内存
SET tez.am.resource.memory.mb=8192;
SET hive.tez.container.size=8192;

-- 方案3：分批REBUILD（业务层控制）
```

### 4.3 参数调优

| 参数 | 默认值 | 建议 | 说明 |
|------|--------|------|------|
| `hive.server2.materialized.views.registry.impl` | DEFAULT | DEFAULT | DEFAULT缓存/DUMMY不缓存 |
| `hive.materializedview.rewriting` | true | true | 查询时MV重写总开关 |
| `hive.materializedview.rewriting.sql` | true | true | 基于SQL的补偿重写 |
| `hive.materializedview.rebuild.incremental` | true | true | 增量REBUILD开关 |
| `hive.txn.manager` | - | DbTxnManager | 增量REBUILD需要ACID支持 |

---

## 五、举一反三

### 5.1 系统对比

| 特性 | Hive MV | Oracle MV | Spark (无MV) | Presto MV |
|------|---------|-----------|-------------|-----------|
| 自动重写 | ✅ Calcite规则 | ✅ CBO内置 | ❌ | ✅ 部分 |
| 增量维护 | ✅ MERGE | ✅ ON COMMIT/DEMAND | - | ❌ |
| 注册缓存 | HS2内存 | SGA | - | Coordinator |
| 过期检测 | SCN/WriteId | SCN | - | 时间戳 |

### 5.2 面试高频题

**Q1：HiveMaterializedViewsRegistry为什么是单例？如果HS2多实例部署会怎样？**

A：单例保证单个HS2进程内所有Session共享MV缓存。多HS2实例时，每个实例独立维护自己的Registry，通过Metastore保持一致性。如果某实例创建了MV但其他实例未感知，需等待Loader定期同步或重启。

**Q2：物化视图自动重写的匹配条件是什么？**

A：Calcite AbstractMaterializedViewRule执行以下匹配：
1. 查询的表集合是MV引用表集合的子集
2. 查询的WHERE条件可以从MV的WHERE推导出
3. 查询的GROUP BY列是MV的GROUP BY列的子集（可做Rollup）
4. 查询的SELECT列可以从MV列计算得到

**Q3：为什么增量REBUILD需要Full ACID表？**

A：增量REBUILD生成MERGE语句（UPDATE + INSERT），MERGE需要：
1. 按主键定位行（ROW_ID）
2. 原子更新行内容
3. 这些能力只有Full ACID表（ORC + transactional=true）提供

**Q4：parseQuery中为什么要设置`isLoadingMaterializedView=true`？**

A：防止无限递归。在解析MV定义SQL时，CalcitePlanner会尝试用其他MV重写该SQL，如果该MV又依赖其他MV...就会死循环。这个标志告诉优化器："我正在加载MV定义，请跳过重写逻辑"。

### 5.3 思考题

1. 如果物化视图的源表被DROP再CREATE（同名），Registry会如何处理？
2. Dummy模式下MV重写如何工作？性能影响是什么？
3. 如何设计一个"MV推荐系统"——根据查询负载自动建议创建哪些MV？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────┐
│         Hive MaterializedView 核心知识晶体                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  架构：HiveMaterializedViewsRegistry（HS2单例 + ConcurrentMap）  │
│                                                                 │
│  生命周期：CREATE → REGISTER → REWRITE → REBUILD → DROP         │
│                                                                 │
│  核心数据结构：                                                   │
│  materializedViews: Map<DB, Map<ViewName, RelOptMaterialization>>│
│  RelOptMaterialization = {viewScan(替代计划), queryRel(原始定义)} │
│                                                                 │
│  初始化流程：                                                    │
│  HS2启动 → init() → Loader异步 → 遍历所有DB →                   │
│  getAllMVs → parseQuery + createMVScan → store → initialized=T  │
│                                                                 │
│  重写匹配（Calcite引擎）：                                       │
│  6种规则: Filter/Join/Aggregate × (Project+Only)                 │
│  条件: 表子集 + 谓词蕴含 + 列可推导 + 聚合可Rollup               │
│                                                                 │
│  增量维护：                                                      │
│  HiveAggregateIncrementalRewritingRule                           │
│  INSERT OVERWRITE → MERGE (RIGHT JOIN + CASE + PROJECT)          │
│  前提：Full ACID表 + 含聚合                                      │
│                                                                 │
│  关键参数：                                                      │
│  • registry.impl=DEFAULT（缓存） / DUMMY（不缓存）               │
│  • materializedview.rewriting=true                              │
│  • materializedview.rebuild.incremental=true                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/metadata/HiveMaterializedViewsRegistry.java`
2. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/rules/views/`
3. HIVE-14249: Cost-based materialized view rewriting
4. HIVE-18680: Incremental rebuild for MV with aggregations
5. Apache Calcite Materialized View文档
6. Hive Wiki: Materialized Views
