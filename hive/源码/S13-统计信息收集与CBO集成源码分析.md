# S13 - Hive 统计信息收集与 CBO 集成源码深度分析

> **知识晶体化模板** | 基于 Hive 3.x 源码 | 作者: Eric (豹纹) for 大哥

---

## 一、问题/场景

统计信息是 CBO（Cost-Based Optimizer）做出正确决策的基础。常见问题：

1. **JOIN 顺序不优化**：缺少统计信息导致 CBO 无法判断哪张表更大，回退到 RBO
2. **MapJoin 未触发**：统计信息不准确，小表大小被高估或低估
3. **ANALYZE TABLE 执行缓慢**：大表收集列级统计耗时长
4. **统计信息过期**：数据更新后统计信息未同步，CBO 决策偏差

**核心源码目录**:
- 统计收集: `ql/src/java/org/apache/hadoop/hive/ql/stats/`
- 统计任务: `ql/src/java/org/apache/hadoop/hive/ql/exec/StatsTask.java`
- CBO集成: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/`

---

## 二、架构概览

```
┌────────────────────────────────────────────────────────────────┐
│                    ANALYZE TABLE t COMPUTE STATISTICS          │
│                                                                │
│  ┌──────────────┐    ┌─────────────────┐    ┌──────────────┐ │
│  │ SemanticAnalyzer│──▶│ DDLSemanticAnalyzer│──▶│ StatsTask    │ │
│  │ (解析SQL)       │    │ (生成StatsWork)    │    │ (执行收集)  │ │
│  └──────────────┘    └─────────────────┘    └──────┬───────┘ │
│                                                      │         │
│                               ┌──────────────────────┼──────┐ │
│                               │                      │      │ │
│                      ┌────────▼─────┐    ┌──────────▼────┐ │ │
│                      │BasicStatsTask │    │ColStatsProcessor│ │ │
│                      │(行数/文件大小) │    │(列级NDV/min/max)│ │ │
│                      └────────┬─────┘    └──────────┬────┘ │ │
│                               │                      │      │ │
│                               ▼                      ▼      │ │
│                      ┌─────────────────────────────────────┐│ │
│                      │        Hive Metastore               ││ │
│                      │  TABLE_PARAMS / PARTITION_PARAMS     ││ │
│                      │  TAB_COL_STATS / PART_COL_STATS     ││ │
│                      └──────────────┬──────────────────────┘│ │
│                                     │                        │ │
└─────────────────────────────────────┼────────────────────────┘ │
                                      │                          │
                                      ▼                          │
┌─────────────────────────────────────────────────────────────┐ │
│                 CBO (Calcite) 优化器                         │ │
│                                                             │ │
│  ┌──────────────────┐    ┌──────────────────────┐          │ │
│  │ RelOptHiveTable   │──▶│ HiveRelMdRowCount     │          │ │
│  │ (Hive表→Calcite)  │    │ (行数估算)            │          │ │
│  │ getColStat()      │    │                      │          │ │
│  │ hiveColStatsMap   │    │ HiveRelMdSelectivity  │          │ │
│  └──────────────────┘    │ HiveRelMdDistinctRowCount│       │ │
│                           │ HiveRelMdCost          │        │ │
│                           └──────────────────────┘         │ │
└─────────────────────────────────────────────────────────────┘ │
```

---

## 三、统计信息的两个层次

### 3.1 表/分区基础统计 (Basic Stats)

存储在 `TABLE_PARAMS` / `PARTITION_PARAMS` 中的键值对：

| 统计项 | KEY | 说明 |
|--------|-----|------|
| 行数 | `numRows` | 表/分区总行数 |
| 原始数据大小 | `rawDataSize` | 未压缩数据大小 |
| 文件总大小 | `totalSize` | HDFS 上文件总大小 |
| 文件数量 | `numFiles` | HDFS 文件数量 |

### 3.2 列级统计 (Column Stats)

存储在 `TAB_COL_STATS` / `PART_COL_STATS` 表中：

| 统计项 | 说明 | 数据类型 |
|--------|------|---------|
| `ndv` (Number of Distinct Values) | 不同值个数 | 所有类型 |
| `numNulls` | NULL 值个数 | 所有类型 |
| `avgColLen` | 平均列长度 | String 类型 |
| `maxColLen` | 最大列长度 | String 类型 |
| `lowValue` / `highValue` | 最小/最大值 | 数值/日期 |
| `numTrues` / `numFalses` | true/false 个数 | Boolean 类型 |

---

## 四、核心源码分析

### 4.1 StatsTask — 统计收集任务入口

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/StatsTask.java`

```java
// StatsTask.java:55-158
public class StatsTask extends Task<StatsWork> implements Serializable {

    List<IStatsProcessor> processors = new ArrayList<>();
    
    @Override
    public void initialize(QueryState queryState, QueryPlan queryPlan, DriverContext ctx, CompilationOpContext opContext) {
        super.initialize(queryState, queryPlan, ctx, opContext);
        
        // 1. 基础统计处理器 (行数、文件大小)
        if (work.getBasicStatsWork() != null) {
            BasicStatsTask task = new BasicStatsTask(conf, work.getBasicStatsWork());
            task.followedColStats = work.hasColStats();
            processors.add(0, task);
        } else if (work.isFooterScan()) {
            // ORC/Parquet 可从文件 footer 直接读取统计信息
            BasicStatsNoJobTask t = new BasicStatsNoJobTask(conf, work.getBasicStatsNoJobWork());
            processors.add(0, t);
        }
        
        // 2. 列级统计处理器 (NDV、min/max 等)
        if (work.hasColStats()) {
            processors.add(new ColStatsProcessor(work.getColStats(), conf));
        }
    }
    
    @Override
    public int execute(DriverContext driverContext) {
        Hive db = getHive();
        Table tbl = getTable(db);
        
        // 依次执行所有处理器
        for (IStatsProcessor task : processors) {
            task.setDpPartSpecs(dpPartSpecs);  // 动态分区信息
            ret = task.process(db, tbl);
            if (ret != 0) return ret;
        }
        return 0;
    }
}
```

**调用链 — ANALYZE TABLE 执行流程**:
```
用户: ANALYZE TABLE t COMPUTE STATISTICS FOR COLUMNS;

1. Driver.compile()
   └─▶ DDLSemanticAnalyzer.analyzeAnalyze()
        ├─▶ 构建 BasicStatsWork (基础统计配置)
        ├─▶ 构建 ColumnStatsDesc (列统计配置, 包含 FetchWork)
        └─▶ 生成 StatsTask

2. Driver.execute()
   └─▶ StatsTask.execute()
        ├─▶ BasicStatsTask.process(db, tbl)   [第一步: 基础统计]
        │     ├─▶ aggregateStats()
        │     │     ├─▶ 遍历所有分区/文件
        │     │     ├─▶ 统计 numRows, rawDataSize, totalSize, numFiles
        │     │     └─▶ db.alterTable/alterPartition → 更新 TABLE_PARAMS
        │     └─▶ 完成
        │
        └─▶ ColStatsProcessor.process(db, tbl) [第二步: 列统计]
              ├─▶ constructColumnStatsFromPackedRows()
              │     ├─▶ FetchOperator 读取之前 MR/Tez 计算的统计结果
              │     ├─▶ ColumnStatisticsObjTranslator.readHiveStruct()
              │     └─▶ 构建 ColumnStatisticsObj 列表
              └─▶ persistColumnStats()
                    └─▶ db.setPartitionColumnStatistics() / updateTableColumnStatistics()
                         → 写入 TAB_COL_STATS / PART_COL_STATS
```

### 4.2 BasicStatsTask — 基础统计收集

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/stats/BasicStatsTask.java`

```java
// BasicStatsTask.java:72-99
public class BasicStatsTask implements Serializable, IStatsProcessor {
    
    @Override
    public int process(Hive db, Table tbl) throws Exception {
        table = tbl;
        return aggregateStats(db);
    }
}
```

`BasicStatsProcessor` 内部类的关键处理逻辑：

```java
// BasicStatsTask.java:113-150 (简化)
public Object process(StatsAggregator statsAggregator) throws HiveException, MetaException {
    Map<String, String> parameters = partish.getPartParameters();
    
    if (partish.isTransactionalTable()) {
        // ACID表: 标记基础统计为非准确状态
        StatsSetupConst.setBasicStatsState(parameters, StatsSetupConst.FALSE);
    } else if (work.isTargetRewritten()) {
        // 目标完全重写(如 INSERT OVERWRITE): 统计准确
        StatsSetupConst.setBasicStatsState(parameters, StatsSetupConst.TRUE);
    }
    
    // 非ANALYZE命令且后续无列统计 → 清除列统计
    if (!work.isExplicitAnalyze() && !followedColStats) {
        StatsSetupConst.clearColumnStatsState(parameters);
    }
    
    // 从文件系统收集: numFiles, totalSize, numRows, rawDataSize
    // ...
}
```

### 4.3 ColStatsProcessor — 列级统计收集

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/stats/ColStatsProcessor.java`

列统计的收集方式与基础统计不同——它需要通过实际的数据扫描来计算 NDV、min、max 等：

```java
// ColStatsProcessor.java:53-149
public class ColStatsProcessor implements IStatsProcessor {
    private FetchOperator ftOp;       // 用于读取 MR/Tez 统计结果
    private FetchWork fWork;           // 描述如何获取统计结果
    private ColumnStatsDesc colStatDesc;
    
    @Override
    public int process(Hive db, Table tbl) throws Exception {
        return persistColumnStats(db, tbl);
    }
    
    // 从 MR/Tez 输出中解析列统计
    private List<ColumnStatistics> constructColumnStatsFromPackedRows(Table tbl) {
        List<ColumnStatistics> stats = new ArrayList<>();
        InspectableObject packedRow;
        
        while ((packedRow = ftOp.getNextRow()) != null) {
            List<ColumnStatisticsObj> statsObjs = new ArrayList<>();
            StructObjectInspector soi = (StructObjectInspector) packedRow.oi;
            List<Object> list = soi.getStructFieldsDataAsList(packedRow.o);
            
            for (int i = 0; i < numOfStatCols; i++) {
                String columnName = colName.get(i);
                String columnType = colType.get(i);
                Object values = list.get(i);
                
                // 将原始结果转换为 ColumnStatisticsObj
                ColumnStatisticsObj statObj = ColumnStatisticsObjTranslator
                    .readHiveStruct(columnName, columnType, structField, values);
                statsObjs.add(statObj);
            }
            
            // 对于分区表，还需要解析分区列值
            if (!isTblLevel) {
                partName = Warehouse.makePartName(partColSchema, partVals);
            }
            
            ColumnStatisticsDesc statsDesc = buildColumnStatsDesc(tbl, partName, isTblLevel);
            ColumnStatistics colStats = new ColumnStatistics();
            colStats.setStatsDesc(statsDesc);
            colStats.setStatsObj(statsObjs);
            stats.add(colStats);
        }
        return stats;
    }
}
```

**ANALYZE TABLE 底层执行的查询** (对于列统计):
```sql
-- Hive 内部生成的统计查询 (示意)
SELECT 
    count(DISTINCT col1),      -- NDV
    count(col1),               -- numNotNulls
    min(col1), max(col1),      -- range
    avg(length(col1)),         -- avgColLen (for string)
    max(length(col1)),         -- maxColLen (for string)
    count(CASE WHEN col1 IS NULL THEN 1 END)  -- numNulls
FROM table_name;
```

---

### 4.4 RelOptHiveTable — CBO 统计信息入口

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/RelOptHiveTable.java`

这是 Hive 表在 Calcite 框架中的表示，**CBO 获取统计信息的唯一入口**。

```java
// RelOptHiveTable.java:79-96
public class RelOptHiveTable extends RelOptAbstractTable {
    private final Table hiveTblMetadata;                    // Hive 原始表元数据
    private double rowCount = -1;                           // 行数缓存
    Map<Integer, ColStatistics> hiveColStatsMap = new HashMap<>();  // 列统计缓存
    PrunedPartitionList partitionList;                      // 分区裁剪后的分区列表
    AtomicInteger noColsMissingStats;                       // 缺失统计的列数
}
```

#### 4.4.1 getColStat() — 获取列级统计

```java
// RelOptHiveTable.java:591-629
public List<ColStatistics> getColStat(List<Integer> projIndxLst) {
    return getColStat(projIndxLst, HiveConf.getBoolVar(hiveConf, HIVE_STATS_ESTIMATE_STATS));
}

public List<ColStatistics> getColStat(List<Integer> projIndxLst, boolean allowMissingStats) {
    List<ColStatistics> colStatsBldr = Lists.newArrayList();
    Set<Integer> projIndxSet = new HashSet<>(projIndxLst);
    
    // 1. 先从缓存中取
    for (Integer i : projIndxLst) {
        if (hiveColStatsMap.get(i) != null) {
            colStatsBldr.add(hiveColStatsMap.get(i));
            projIndxSet.remove(i);
        }
    }
    
    // 2. 缓存未命中的，从 Metastore 获取
    if (!projIndxSet.isEmpty()) {
        updateColStats(projIndxSet, allowMissingStats);
        for (Integer i : projIndxSet) {
            colStatsBldr.add(hiveColStatsMap.get(i));
        }
    }
    
    return colStatsBldr;
}
```

`updateColStats()` 内部流程:
```
updateColStats(neededCols)
  ├─▶ 区分非分区列 vs 分区列
  │
  ├─▶ 非分区列:
  │     ├─▶ 非分区表: StatsUtils.getTableColumnStats(tbl, colNames)
  │     │     └─▶ Metastore.getTableColumnStatistics() → TAB_COL_STATS
  │     └─▶ 分区表: StatsUtils.getTableColumnStats(tbl, schema, colNames, partList)
  │           └─▶ Metastore.getPartitionColumnStatistics() → PART_COL_STATS
  │           └─▶ 跨分区聚合 (min/max/sum NDV 等)
  │
  └─▶ 分区列:
        └─▶ StatsUtils.getColStatsForPartCol(colInfo, partitions)
              └─▶ 从分区元数据直接推算 NDV 等
```

#### 4.4.2 统计信息缺失时的处理

```java
// RelOptHiveTable.java:573-588
if (!colNamesFailedStats.isEmpty()) {
    String logMsg = "No Stats for " + hiveTblMetadata.getCompleteName() + ", Columns: " + colNamesFailedStats;
    noColsMissingStats.getAndAdd(colNamesFailedStats.size());
    
    if (allowMissingStats) {
        LOG.warn(logMsg);  // 仅警告，允许 CBO 估算
        if (HiveConf.getBoolVar(conf, HIVE_CBO_SHOW_WARNINGS)) {
            console.printInfo(logMsg);  // 显示给用户
        }
    } else {
        LOG.error(logMsg);
        throw new RuntimeException(logMsg);  // 严格模式：抛异常，CBO 回退到 RBO
    }
}
```

**关键参数**: `hive.stats.estimate.stats=true` 时，缺失统计不会导致 CBO 失败，而是使用估算值。

---

### 4.5 HiveRelMdRowCount — 行数估算传递给 Calcite

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/calcite/stats/HiveRelMdRowCount.java`

```java
// HiveRelMdRowCount.java:53-77
public class HiveRelMdRowCount extends RelMdRowCount {
    
    // JOIN 行数估算: 利用 PK-FK 关系优化
    public Double getRowCount(Join join, RelMetadataQuery mq) {
        PKFKRelationInfo pkfk = analyzeJoinForPKFK(join, mq);
        if (pkfk != null) {
            double selectivity = pkfk.pkInfo.selectivity * pkfk.ndvScalingFactor;
            selectivity = Math.min(1.0, selectivity);
            return pkfk.fkInfo.rowCount * selectivity;
        }
        return join.estimateRowCount(mq);
    }
    
    // SORT/LIMIT 行数估算
    @Override
    public Double getRowCount(Sort rel, RelMetadataQuery mq) {
        final Double rowCount = mq.getRowCount(rel.getInput());
        if (rowCount != null && rel.fetch != null) {
            final int offset = rel.offset == null ? 0 : RexLiteral.intValue(rel.offset);
            final int limit = RexLiteral.intValue(rel.fetch);
            return Math.min(rowCount, offset + limit);
        }
        return rowCount;
    }
}
```

---

### 4.6 统计信息如何影响 CBO 决策

**完整传递链**:
```
Metastore (TAB_COL_STATS/PART_COL_STATS)
    │
    ▼
RelOptHiveTable.getColStat() / getRowCount()
    │
    ▼
HiveRelMdRowCount / HiveRelMdSelectivity / HiveRelMdDistinctRowCount
    │ (Calcite MetadataQuery 接口)
    ▼
Calcite CBO 优化规则:
    ├─▶ JoinReorderRule: 利用行数和 NDV 决定 JOIN 顺序
    │     rowCount(A) < rowCount(B) → A 作为 build side
    │
    ├─▶ MapJoin 判断: 利用 totalSize 决定是否转 MapJoin
    │     totalSize(smallTable) < hive.auto.convert.join.noconditionaltask.size
    │
    ├─▶ Filter 选择率: 利用 NDV 和 min/max 估算 WHERE 过滤效果
    │     selectivity = 1.0 / NDV (等值条件)
    │     selectivity = (value - min) / (max - min) (范围条件)
    │
    └─▶ Aggregate 基数估算: 利用 NDV 估算 GROUP BY 输出行数
          outputRows = min(inputRows, product(NDV(groupby_cols)))
```

---

## 五、调用链总结 — ANALYZE TABLE 完整流程

```
用户: ANALYZE TABLE orders COMPUTE STATISTICS FOR COLUMNS order_id, user_id;

1. 解析阶段
   DDLSemanticAnalyzer.analyzeAnalyze()
     ├─▶ 生成内部查询: 
     │     SELECT compute_stats(order_id, 'long'), compute_stats(user_id, 'long') FROM orders;
     ├─▶ 构建 BasicStatsWork (配置基础统计收集)
     ├─▶ 构建 ColumnStatsDesc (包含 FetchWork，用于读取统计结果)
     └─▶ 构建执行计划: MapRedTask → StatsTask

2. 执行阶段
   ├─▶ MapRedTask/TezTask 执行数据扫描，计算列级统计
   │     └─▶ GenericUDAF: compute_stats() → 输出 NDV, min, max, numNulls 等
   │
   └─▶ StatsTask.execute()
         ├─▶ BasicStatsTask.process()
         │     ├─▶ 遍历 HDFS 文件统计 numFiles, totalSize
         │     ├─▶ 从 ORC footer 读取 numRows, rawDataSize
         │     └─▶ db.alterTable() → UPDATE TABLE_PARAMS
         │
         └─▶ ColStatsProcessor.process()
               ├─▶ FetchOperator 读取 MapRedTask 输出
               ├─▶ ColumnStatisticsObjTranslator 解析为 ColumnStatisticsObj
               └─▶ db.setPartitionColumnStatistics()
                     └─▶ Metastore → INSERT/UPDATE TAB_COL_STATS

3. 查询使用阶段
   SELECT * FROM orders JOIN users ON orders.user_id = users.id;
   
   Calcite 优化器:
     ├─▶ RelOptHiveTable("orders").getColStat([1])  // user_id
     │     └─▶ Metastore.getTableColumnStatistics("orders", ["user_id"])
     │         → ColStatistics{ndv=100000, numNulls=0, min=1, max=100000}
     │
     ├─▶ RelOptHiveTable("users").getRowCount()
     │     └─▶ TABLE_PARAMS.numRows = 100000
     │
     └─▶ JoinReorderRule: users(100K rows) < orders(10M rows) → users 作为 build side
```

---

## 六、关键参数与调优建议

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.stats.autogather` | true | INSERT/CTAS 后自动收集基础统计 |
| `hive.stats.column.autogather` | true | INSERT/CTAS 后自动收集列统计 |
| `hive.stats.fetch.column.stats` | true | CBO 是否从 Metastore 获取列统计 |
| `hive.stats.estimate.stats` | true | 缺失统计时是否允许估算 |
| `hive.stats.reliable` | false | 统计收集失败是否导致查询失败 |
| `hive.stats.gather.num.threads` | 10 | 并行收集统计的线程数 |
| `hive.cbo.enable` | true | 是否启用 CBO |
| `hive.cbo.show.warnings` | false | 是否显示 CBO 警告（如统计缺失） |
| `hive.compute.query.using.stats` | true | 简单聚合是否直接使用统计(无需扫描) |

### 调优建议

1. **确保列统计及时**: 大表变更后及时执行 `ANALYZE TABLE ... FOR COLUMNS`
2. **启用自动收集**: `hive.stats.autogather=true` + `hive.stats.column.autogather=true`
3. **监控统计缺失**: 开启 `hive.cbo.show.warnings=true`，在查询日志中观察 `No Stats for` 警告
4. **分区表按需收集**: 对新增分区单独收集：`ANALYZE TABLE t PARTITION (dt='2024-01-01') COMPUTE STATISTICS FOR COLUMNS`
5. **ORC 表利用 footer**: ORC 表的基础统计可从文件 footer 免费获取，列统计仍需 ANALYZE

---

## 七、踩坑记录

### 7.1 CBO 回退到 RBO

**现象**: 执行计划显示 `Warning: CBO disabled due to missing stats`

**根因**: `hive.stats.estimate.stats=false` 且关键列缺少统计信息，导致 `RelOptHiveTable.updateColStats()` 抛异常。

**源码证据** (RelOptHiveTable.java:584-587):
```java
if (!allowMissingStats) {
    LOG.error(logMsg);
    throw new RuntimeException(logMsg);  // CBO 失败，回退 RBO
}
```

**解决**: 保持 `hive.stats.estimate.stats=true`（默认），或补充统计信息。

### 7.2 分区表统计聚合不准确

**现象**: 分区表的 NDV 被高估（各分区 NDV 简单相加）。

**根因**: 跨分区的 NDV 聚合只能取各分区 NDV 的最大值或相加，无法精确计算全局 NDV。

**解决**: 对频繁用于 JOIN 的列，在整表级别收集统计（非分区级别）。

### 7.3 ACID 表统计不准确

**现象**: ACID 表执行 UPDATE/DELETE 后统计信息过期。

**源码证据** (BasicStatsTask.java:130-133):
```java
if (p.isTransactionalTable()) {
    StatsSetupConst.setBasicStatsState(parameters, StatsSetupConst.FALSE);
}
```

**根因**: ACID 表的写操作不会直接更新统计（因为 delta 文件需要合并后才能确定最终状态），统计被标记为不准确。

**解决**: ACID 表需要在 Compaction 后重新 ANALYZE。

---

## 八、总结

Hive 统计信息系统是 CBO 的数据基础，包含两个层次：

1. **基础统计**: 行数、文件大小，存储在 `TABLE_PARAMS`，写操作后自动更新
2. **列级统计**: NDV、min/max、numNulls，存储在 `TAB_COL_STATS`，需要 ANALYZE TABLE 或自动收集

统计信息通过 `RelOptHiveTable` 桥接到 Calcite CBO 框架：
- `getRowCount()` 提供行数
- `getColStat()` 提供列级统计
- `HiveRelMdRowCount` / `HiveRelMdSelectivity` 将统计信息转化为成本估算

**关键设计**: 统计缺失时的降级策略——通过 `hive.stats.estimate.stats` 控制是估算还是回退 RBO。
