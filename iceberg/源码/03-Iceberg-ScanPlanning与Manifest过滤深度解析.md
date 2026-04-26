# Iceberg 源码深度解析：Scan Planning 与 Manifest 过滤

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码分析
> Eric | 2026-04-25

---

## 一、查询入口链路

```
Table.newScan()                          # api/Table.java
  → DataTableScan                        # core/DataTableScan.java
    → SnapshotScan.planFiles()           # core/SnapshotScan.java
      → ManifestGroup.planFiles()        # core/ManifestGroup.java  ← 核心
        → ManifestReader.read() × N     # core/ManifestReader.java
```

---

## 二、ManifestGroup — Scan Planning 核心

**源码位置**: `core/src/main/java/org/apache/iceberg/ManifestGroup.java`

### 2.1 核心字段

```java
// ManifestGroup.java Line 48-67
class ManifestGroup {
    private final FileIO io;
    private final Set<ManifestFile> dataManifests;     // 数据 Manifest 集合
    private final DeleteFileIndex.Builder deleteIndexBuilder; // 删除文件索引构建器
    private Expression dataFilter;         // 数据过滤表达式
    private Expression fileFilter;         // 文件级过滤
    private Expression partitionFilter;    // 分区过滤表达式
    private boolean ignoreDeleted;         // 是否忽略已删除条目
    private boolean ignoreExisting;        // 是否忽略已存在条目（增量扫描用）
    private boolean ignoreResiduals;       // 是否忽略残差表达式
    private List<String> columns;          // 需要读取的列
    private boolean caseSensitive;         // 大小写敏感
    private ExecutorService executorService; // 并行扫描线程池
    private ScanMetrics scanMetrics;       // 扫描指标
}
```

### 2.2 三层过滤机制

```
Layer 1: ManifestFile 级别过滤
  ├── ManifestEvaluator 用 Manifest 的分区统计信息
  │   （每个 Manifest 记录了包含的 partition 范围）
  │   → 不匹配的 Manifest 整个跳过（不读取内容）
  │
Layer 2: ManifestEntry 级别过滤
  ├── 读取 Manifest 内容
  ├── PartitionFilter 用每个 DataFile 的 partition 值
  │   → 不匹配分区的 DataFile 跳过
  ├── MetricsEvaluator 用每个 DataFile 的列级统计
  │   （min/max/null_count/nan_count）
  │   → 不可能包含匹配数据的 DataFile 跳过
  │
Layer 3: RowGroup/Page 级别过滤（引擎层，不在 ManifestGroup 里）
  └── Parquet/ORC 的 RowGroup 级统计
      → 引擎读取数据时的细粒度过滤
```

### 2.3 Manifest 过滤链路

```java
// ManifestGroup 构造时初始化
ManifestGroup(FileIO io, Iterable<ManifestFile> manifests) {
    // 分离数据 Manifest 和删除 Manifest
    this.dataManifests = filter(manifests, content == DATA);
    this.deleteIndexBuilder = DeleteFileIndex.builderFor(io, deleteManifests);
}

// 链式配置过滤条件
group.filterData(expression)          // 设置数据过滤
     .filterPartitions(expression)    // 设置分区过滤
     .specsById(specsById)           // 分区规格映射
     .caseSensitive(true)            // 大小写敏感
```

### 2.4 ManifestEvaluator — Manifest 级别快速剪枝

```java
// expressions/ManifestEvaluator.java
// 利用 ManifestFile 中的 partitions 字段做快速过滤
// ManifestFile.partitions() 包含每个分区字段的 lower_bound/upper_bound
//
// 示例: WHERE dt = '2026-04-25'
//   Manifest-A.partitions = {dt: [2026-04-01, 2026-04-20]}  → SKIP（不包含 04-25）
//   Manifest-B.partitions = {dt: [2026-04-20, 2026-04-30]}  → READ（可能包含）
```

### 2.5 并行扫描

```java
// ManifestGroup.planFiles() 内部
// 多个 Manifest 文件并行读取
new ParallelIterable<>(readers, executorService)
// executorService 默认使用 ThreadPools.getWorkerPool()
// 可通过 scan.option("scan-plan-workers", "8") 控制
```

---

## 三、FileScanTask — 扫描结果

每个 FileScanTask 包含：

```java
// BaseFileScanTask.java
public class BaseFileScanTask implements FileScanTask {
    private DataFile file;              // 要读取的数据文件
    private DeleteFile[] deletes;       // 关联的删除文件
    private String schemaString;        // Schema
    private String specString;          // 分区规格
    private ResidualEvaluator residuals; // 残差表达式（文件级过滤后剩余的条件）
}
```

**残差表达式**的作用：Manifest 过滤只能做分区和文件级统计的粗过滤，过滤后剩余的条件变成 `residual`，由引擎在读数据时精确过滤。

---

## 四、DeleteFileIndex — 删除文件关联

```
DataFile-A ← [PosDelete-1, EqDelete-3]
DataFile-B ← [PosDelete-2]
DataFile-C ← []  （无关联删除文件）

DeleteFileIndex 负责：
1. 扫描所有 delete manifest
2. 按分区建立 DataFile → DeleteFile 的映射
3. Position Delete: 按文件路径精确匹配
4. Equality Delete: 按序列号 + 分区匹配
```

---

## 五、性能关键指标

| 指标 | 含义 | 优化方向 |
|------|------|---------|
| `scanned-data-manifests` | 扫描的数据 Manifest 数 | Manifest 太多 → rewrite_manifests |
| `skipped-data-manifests` | 跳过的数据 Manifest 数 | 越高越好 |
| `scanned-data-files` | 扫描到的数据文件数 | 小文件多 → rewrite_data_files |
| `skipped-data-files` | 跳过的数据文件数 | min/max 统计有效 |
| `total-data-manifests` | 总 Manifest 数 | 建议控制在千级以内 |

---

*Iceberg Scan Planning 深度解析 v1.0 | Eric | 2026-04-25*
