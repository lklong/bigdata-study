# Iceberg 源码深度解析：RewriteDataFiles / ExpireSnapshots / DeleteOrphanFiles 维护操作

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-25

---

## 一、Iceberg 表维护三板斧

```
┌──────────────────────────────────────────────────────────────┐
│                    Iceberg 表生命周期维护                      │
│                                                              │
│  ┌───────────────────┐  ┌──────────────────┐  ┌───────────┐ │
│  │ RewriteDataFiles  │  │ ExpireSnapshots  │  │ DeleteOrph│ │
│  │ (小文件合并)       │  │ (快照过期清理)    │  │ anFiles   │ │
│  │                   │  │                  │  │ (孤立文件) │ │
│  │ 问题: 小文件堆积  │  │ 问题: 元数据膨胀  │  │ 问题: 脏  │ │
│  │ 频率: 每天/每周    │  │ 频率: 每小时/天   │  │ 数据残留  │ │
│  │ 影响: 查询变慢     │  │ 影响: Planning慢  │  │ 影响: 磁  │ │
│  │ 原理: 读取+重写    │  │ 原理: 删除旧版本  │  │ 盘浪费    │ │
│  └───────────────────┘  └──────────────────┘  └───────────┘ │
└──────────────────────────────────────────────────────────────┘
```

---

## 二、SparkActions — 统一入口

**源码位置**: `spark/v3.5/spark/src/main/java/org/apache/iceberg/spark/actions/SparkActions.java`

```java
public class SparkActions implements ActionsProvider {
    private final SparkSession spark;

    public static SparkActions get(SparkSession spark) {
        return new SparkActions(spark);
    }

    // 小文件合并
    public RewriteDataFilesSparkAction rewriteDataFiles(Table table) {
        return new RewriteDataFilesSparkAction(spark, table);
    }

    // 快照过期
    public ExpireSnapshotsSparkAction expireSnapshots(Table table) {
        return new ExpireSnapshotsSparkAction(spark, table);
    }

    // 孤立文件清理
    public DeleteOrphanFilesSparkAction deleteOrphanFiles(Table table) {
        return new DeleteOrphanFilesSparkAction(spark, table);
    }

    // 其他 Actions
    public RewriteManifestsSparkAction rewriteManifests(Table table) { ... }
    public RewritePositionDeleteFilesSparkAction rewritePositionDeletes(Table table) { ... }
    public RemoveDanglingDeletesSparkAction removeDanglingDeleteFiles(Table table) { ... }
}
```

**使用示例**:

```java
SparkActions.get(spark)
    .rewriteDataFiles(table)
    .filter(Expressions.equal("dt", "2026-04-25"))
    .option("target-file-size-bytes", "134217728")  // 128MB
    .execute();
```

---

## 三、RewriteDataFiles — 小文件合并核心

### 3.1 API 接口定义

**源码位置**: `api/src/main/java/org/apache/iceberg/actions/RewriteDataFiles.java`

```java
public interface RewriteDataFiles
    extends SnapshotUpdate<RewriteDataFiles, RewriteDataFiles.Result> {

    // ========== 关键配置常量 ==========
    String TARGET_FILE_SIZE_BYTES = "target-file-size-bytes";
    // 目标文件大小（默认取表属性 write.target-file-size-bytes）

    String MAX_FILE_GROUP_SIZE_BYTES = "max-file-group-size-bytes";
    long MAX_FILE_GROUP_SIZE_BYTES_DEFAULT = 100L * 1024 * 1024 * 1024; // 100GB
    // 单个重写组的最大数据量

    String MAX_CONCURRENT_FILE_GROUP_REWRITES = "max-concurrent-file-group-rewrites";
    int MAX_CONCURRENT_FILE_GROUP_REWRITES_DEFAULT = 5;
    // 最大并发重写组数

    String PARTIAL_PROGRESS_ENABLED = "partial-progress.enabled";
    boolean PARTIAL_PROGRESS_ENABLED_DEFAULT = false;
    // 是否允许增量提交（部分组失败不影响已提交的组）

    String PARTIAL_PROGRESS_MAX_COMMITS = "partial-progress.max-commits";
    int PARTIAL_PROGRESS_MAX_COMMITS_DEFAULT = 10;
    // 增量模式下最大提交次数

    String REMOVE_DANGLING_DELETES = "remove-dangling-deletes";
    // 重写后自动清理悬挂的 delete 文件

    // ========== 合并策略 ==========
    RewriteDataFiles binPack();                    // BinPack（默认）— 仅合并，不改变排序
    RewriteDataFiles sort(SortOrder sortOrder);    // Sort — 按指定排序重写
    RewriteDataFiles zOrder(String... columns);    // Z-Order — 空间曲线排序

    // ========== 过滤器 ==========
    RewriteDataFiles filter(Expression expr);      // 限定重写范围（如指定分区）
}
```

### 3.2 RewriteDataFilesSparkAction — Spark 实现

**源码位置**: `spark/v3.5/spark/src/main/java/org/apache/iceberg/spark/actions/RewriteDataFilesSparkAction.java`

```java
public class RewriteDataFilesSparkAction
    extends BaseSnapshotUpdateSparkAction<RewriteDataFilesSparkAction>
    implements RewriteDataFiles {

    private final Table table;
    private Expression filter = Expressions.alwaysTrue();
    private int maxConcurrentFileGroupRewrites;
    private boolean partialProgressEnabled;
    private SizeBasedFileRewriter<FileScanTask, DataFile> rewriter;
```

#### 核心执行流程 `execute()`

```
execute()
  │
  ├── 1. 检查当前快照
  │      if (table.currentSnapshot() == null) return EMPTY_RESULT
  │
  ├── 2. 确定快照 ID
  │      startingSnapshotId = table.currentSnapshot().snapshotId()
  │
  ├── 3. 选择合并策略（默认 BinPack）
  │      rewriter = 未设置 ? new SparkBinPackDataRewriter(spark, table) : rewriter
  │      rewriter.init(options)  // 初始化策略参数
  │
  ├── 4. 规划文件组
  │      List<List<FileScanTask>> fileGroups = planFileGroups(startingSnapshotId)
  │      // 扫描表 → 按分区分组 → 由 rewriter 拆分为多个 rewrite 组
  │      // 每组不超过 MAX_FILE_GROUP_SIZE_BYTES
  │
  ├── 5. 构建执行上下文
  │      RewriteExecutionContext ctx = new RewriteExecutionContext(fileGroups)
  │      // 跟踪全局/分区维度的组索引
  │
  ├── 6A. 非增量提交模式（默认）
  │      doExecute(ctx, fileGroups)
  │      │
  │      ├── 线程池并发重写所有组
  │      │    ExecutorService executor = Executors.newFixedThreadPool(maxConcurrent)
  │      │    for each group:
  │      │      executor.submit(() -> rewriteFiles(ctx, group))
  │      │
  │      ├── 等待所有组完成
  │      │    Tasks.foreach(rewriteGroups)
  │      │       .executeWith(executor)
  │      │       .noRetry()
  │      │       .onFailure((group, ex) -> commitManager.abortFileGroup(group))
  │      │       .run(group -> rewriteFiles(ctx, group))
  │      │
  │      └── 一次性提交所有结果
  │           commitManager.commitFileGroups(completedGroups)
  │
  └── 6B. 增量提交模式（partial-progress.enabled=true）
         doExecuteWithPartialProgress(ctx, fileGroups)
         │
         ├── 创建 CommitService（异步提交线程）
         │    CommitService commitService = commitManager.service(rewritesPerCommit)
         │    commitService.start()
         │
         ├── 线程池并发重写
         │    for each group:
         │      rewriteFiles(ctx, group)
         │      commitService.offer(group)  // 完成后提交到 CommitService 队列
         │
         └── CommitService 异步批量提交
              // 积累到 rewritesPerCommit 个组后批量 commit
```

#### `rewriteFiles()` — 单组重写

```java
private void rewriteFiles(RewriteExecutionContext ctx, RewriteFileGroup group) {
    String desc = jobDesc(group, ctx);
    Set<DataFile> addedFiles = withJobGroupInfo(
        newJobGroupInfo("REWRITE-DATA-FILES", desc),
        () -> rewriter.rewrite(group.fileScans())  // 调用策略执行重写
    );
    group.setOutputFiles(addedFiles);
    LOG.info("Rewrite Files for {} in {}: {} → {} files",
        group.info().partition(), table.name(),
        group.rewrittenFiles().size(), addedFiles.size());
}
```

### 3.3 RewriteDataFilesCommitManager — 提交管理

**源码位置**: `core/src/main/java/org/apache/iceberg/actions/RewriteDataFilesCommitManager.java`

```java
public class RewriteDataFilesCommitManager {
    private final Table table;
    private final long startingSnapshotId;
    private final boolean useStartingSequenceNumber;

    // 核心提交方法
    public void commitFileGroups(Set<RewriteFileGroup> fileGroups) {
        RewriteFiles rewrite = table.newRewrite()
            .validateFromSnapshot(startingSnapshotId)
            .scanManifestsWith(workerPool);

        for (RewriteFileGroup group : fileGroups) {
            for (FileScanTask task : group.fileScans()) {
                rewrite.deleteFile(task.file());           // 标记删除旧文件
            }
            for (DataFile file : group.addedFiles()) {
                rewrite.addFile(file);                     // 标记新增文件
            }
        }

        rewrite.commit();  // 原子提交！
    }

    // 失败回滚 — 清理已写入的文件
    public void abortFileGroup(RewriteFileGroup group) {
        Tasks.foreach(group.addedFiles())
            .noRetry()
            .run(file -> table.io().deleteFile(file.path().toString()));
    }
}
```

### 3.4 三种合并策略

| 策略 | 类 | 适用场景 | 原理 |
|------|-----|---------|------|
| **BinPack** | `SparkBinPackDataRewriter` | 通用场景（默认） | 仅合并小文件，不改变排序 |
| **Sort** | `SparkSortDataRewriter` | 范围查询优化 | 按指定列排序后重写 |
| **Z-Order** | `SparkZOrderDataRewriter` | 多维查询优化 | 按 Z-Order 曲线排序 |

---

## 四、ExpireSnapshots — 快照过期清理

### 4.1 底层接口（表操作层）

**源码位置**: `api/src/main/java/org/apache/iceberg/ExpireSnapshots.java`

```java
public interface ExpireSnapshots extends PendingUpdate<List<Snapshot>> {
    ExpireSnapshots expireSnapshotId(long snapshotId);  // 按 ID 过期
    ExpireSnapshots expireOlderThan(long timestampMs);  // 按时间过期
    ExpireSnapshots retainLast(int numSnapshots);       // 保留最近 N 个
    ExpireSnapshots deleteWith(Consumer<String> fn);    // 自定义删除函数
    ExpireSnapshots executeDeleteWith(ExecutorService); // 自定义删除线程池
    ExpireSnapshots cleanExpiredFiles(boolean clean);   // 是否同时清理底层文件
}
```

### 4.2 Actions 层接口

**源码位置**: `api/src/main/java/org/apache/iceberg/actions/ExpireSnapshots.java`

```java
public interface ExpireSnapshots extends Action<ExpireSnapshots, ExpireSnapshots.Result> {
    ExpireSnapshots expireSnapshotId(long snapshotId);
    ExpireSnapshots expireOlderThan(long timestampMs);
    ExpireSnapshots retainLast(int numSnapshots);
    ExpireSnapshots deleteWith(Consumer<String> fn);

    interface Result {
        long deletedDataFilesCount();
        long deletedEqualityDeleteFilesCount();
        long deletedPositionDeleteFilesCount();
        long deletedManifestsCount();
        long deletedManifestListsCount();
        long deletedStatisticsFilesCount();
    }
}
```

### 4.3 ExpireSnapshotsSparkAction — Spark 实现

**源码位置**: `spark/v3.5/spark/src/main/java/org/apache/iceberg/spark/actions/ExpireSnapshotsSparkAction.java`

```java
public class ExpireSnapshotsSparkAction extends BaseSparkAction<ExpireSnapshotsSparkAction>
    implements ExpireSnapshots {

    // 构造时 GC 安全检查
    ExpireSnapshotsSparkAction(SparkSession spark, Table table) {
        boolean gcEnabled = PropertyUtil.propertyAsBoolean(
            table.properties(), "gc.enabled", true);
        ValidationException.check(gcEnabled,
            "Cannot expire snapshots: gc.enabled is false");
    }
```

#### 核心执行流程

```
execute() → doExecute()
  │
  ├── 1. 获取原始元数据
  │      TableMetadata originalMetadata = ops.current()
  │
  ├── 2. 执行快照过期（元数据层面）
  │      table.expireSnapshots()
  │        .expireOlderThan(expireOlderThanTimestamp)
  │        .retainLast(retainLastNum)
  │        .expireSnapshotId(...)
  │        .cleanExpiredFiles(false)  // ← 关键：不在这一步删文件！
  │        .commit()
  │
  ├── 3. 获取最新元数据
  │      TableMetadata updatedMetadata = ops.refresh()
  │
  ├── 4. 计算可删除的文件（Spark 分布式计算）
  │      │
  │      ├── deleteCandidateFileDS = 被删除快照引用的所有文件
  │      │    (原始 manifests/data files - 最新 manifests/data files)
  │      │
  │      ├── validFileDS = 当前仍然有效的文件
  │      │    (最新元数据引用的所有 manifests + data files)
  │      │
  │      └── expiredFileDS = deleteCandidateFileDS.except(validFileDS)
  │           // anti-join：候选文件中排除仍有效的 → 得到可安全删除的文件
  │
  └── 5. 删除文件
         if (table.io() instanceof SupportsBulkOperations) {
             io.deleteFiles(filePaths);  // 批量删除（S3/HDFS）
         } else {
             Tasks.foreach(filePaths)
                 .executeWith(deleteExecutor)
                 .run(path -> deleteFunc.accept(path));
         }
```

**关键设计**:

```
为什么不直接在 table.expireSnapshots() 时删除文件？
  → 因为 table.expireSnapshots() 运行在 Driver 端，大量文件删除会很慢
  → Spark 实现先 commit 元数据变更（快），再用 Spark 分布式删除文件（并行）
  → cleanExpiredFiles(false) 就是为了把"删文件"这步推迟到 Spark 并行处理
```

---

## 五、DeleteOrphanFiles — 孤立文件清理

### 5.1 API 接口

**源码位置**: `api/src/main/java/org/apache/iceberg/actions/DeleteOrphanFiles.java`

```java
public interface DeleteOrphanFiles extends Action<DeleteOrphanFiles, DeleteOrphanFiles.Result> {
    DeleteOrphanFiles location(String loc);                 // 扫描位置
    DeleteOrphanFiles olderThan(long timestampMs);          // 仅删除早于此时间的文件
    DeleteOrphanFiles deleteWith(Consumer<String> fn);      // 自定义删除函数
    DeleteOrphanFiles prefixMismatchMode(PrefixMismatchMode); // scheme/authority 不匹配处理

    // 默认安全阈值
    // olderThan 默认 = 当前时间 - 3天（防止误删正在写入的文件！）

    enum PrefixMismatchMode {
        ERROR,   // 默认：发现不匹配就报错
        IGNORE,  // 忽略不匹配的文件
        DELETE   // 直接删除
    }
}
```

### 5.2 DeleteOrphanFilesSparkAction — Spark 实现

**源码位置**: `spark/v3.5/spark/src/main/java/org/apache/iceberg/spark/actions/DeleteOrphanFilesSparkAction.java`

#### 核心执行流程

```
execute() → doExecute()
  │
  ├── 1. 构建实际文件列表（文件系统扫描）
  │      actualFileIdentDS = 递归列表扫描
  │      │
  │      ├── Driver 端列出前 3 层目录
  │      │    (data/ metadata/ 等)
  │      │
  │      └── 子目录 > 10 个时交给 Executor 并行扫描
  │           sparkContext.parallelize(subDirs)
  │             .flatMap(dir -> fileSystem.listFiles(dir))
  │
  ├── 2. 构建有效文件列表（元数据扫描）
  │      validFileIdentDS = 合并以下 4 类：
  │      ├── contentFileDS:  所有 manifest 中记录的 data/delete files
  │      ├── manifestDS:     所有 manifest-list 中记录的 manifest files
  │      ├── manifestListDS: 所有 snapshot 的 manifest-list 路径
  │      └── otherMetadataDS: metadata.json + version-hint.text + statistics 等
  │
  ├── 3. 找出孤立文件
  │      orphanFileDS = findOrphanFiles(actualFileIdentDS, validFileIdentDS)
  │      │
  │      ├── 将路径标准化为 FileURI (scheme + authority + path)
  │      │    等价 scheme 映射: s3n, s3a → s3
  │      │
  │      ├── LEFT OUTER JOIN
  │      │    actual LEFT JOIN valid ON (path, authority, scheme)
  │      │    WHERE valid.path IS NULL → 孤立文件！
  │      │
  │      └── 过滤 olderThan 时间阈值
  │           WHERE modificationTime < olderThanTimestamp
  │
  └── 4. 删除孤立文件
         if (SupportsBulkOperations) → 批量删除
         else → Tasks.foreach().executeWith(deleteExecutor).run(deleteFunc)
```

**安全机制**:

```
1. gc.enabled 检查 — 表属性 gc.enabled=false 时拒绝执行
2. olderThan 默认 3 天 — 防止删除正在写入的临时文件
3. PrefixMismatchMode — scheme/authority 不同时的处理策略
4. 等价映射 — s3n/s3a 等自动映射为 s3，避免误判
```

---

## 六、Stored Procedure 调用（SQL 方式）

### 6.1 小文件合并

```sql
-- BinPack 合并
CALL catalog.system.rewrite_data_files(
    table => 'db.t',
    options => map('target-file-size-bytes', '134217728')
);

-- 指定分区合并
CALL catalog.system.rewrite_data_files(
    table => 'db.t',
    where => 'dt = "2026-04-25"'
);

-- Sort 合并
CALL catalog.system.rewrite_data_files(
    table => 'db.t',
    strategy => 'sort',
    sort_order => 'dt ASC NULLS LAST, id ASC NULLS LAST'
);

-- Z-Order 合并
CALL catalog.system.rewrite_data_files(
    table => 'db.t',
    strategy => 'sort',
    sort_order => 'zorder(dt, city)'
);
```

### 6.2 快照过期

```sql
-- 保留最近 5 个快照
CALL catalog.system.expire_snapshots(
    table => 'db.t',
    retain_last => 5
);

-- 删除 7 天前的快照
CALL catalog.system.expire_snapshots(
    table => 'db.t',
    older_than => TIMESTAMP '2026-04-18 00:00:00'
);
```

### 6.3 孤立文件清理

```sql
CALL catalog.system.remove_orphan_files(
    table => 'db.t',
    older_than => TIMESTAMP '2026-04-22 00:00:00'
);
```

---

## 七、运维最佳实践

### 7.1 推荐维护策略

| 操作 | 频率 | 关键参数 |
|------|------|---------|
| `rewrite_data_files` | 每天/每周 | `target-file-size-bytes=128MB`，指定分区 |
| `expire_snapshots` | 每小时/每天 | `retain_last=5-10`，`older_than=7d` |
| `remove_orphan_files` | 每周/每月 | `older_than=3d`（默认），低峰期执行 |
| `rewrite_manifests` | 每周 | Manifest 数量 > 1000 时 |
| `rewrite_position_deletes` | 每天 | Delete File 堆积时 |

### 7.2 危险操作警告

```
⚠️ expire_snapshots 后无法 Time Travel 到已删除的快照！
⚠️ remove_orphan_files 的 olderThan 不要设太小，至少 3 天！
⚠️ gc.enabled=false 的表需要手动维护，Amoro 也不会自动优化！
⚠️ rewrite_data_files 会产生新文件，需要后续 expire_snapshots 清理旧文件！
```

### 7.3 执行顺序

```
推荐顺序（每日维护）：
  1. rewrite_data_files   → 合并小文件
  2. expire_snapshots     → 清理旧快照（释放对旧文件的引用）
  3. remove_orphan_files  → 清理孤立文件（确保旧快照已过期后再清理）
```

---

## 八、Amoro 如何自动化这些操作

```
Amoro AMS 内置了这些维护操作的自动化执行器：

AsyncTableExecutors (DefaultTableService 初始化时注册)
  ├── SnapshotsExpiringExecutor    → 自动 expire_snapshots
  ├── OrphanFilesCleaningExecutor  → 自动 remove_orphan_files
  ├── DataExpiringExecutor         → 自动按 TTL 删除过期数据
  ├── TagsAutoCreatingExecutor     → 自动创建 Tag（Time Travel 锚点）
  └── Self-Optimizing (OptimizingQueue) → 自动 rewrite_data_files

所以使用 Amoro 管理 Iceberg 表时，这三板斧会被自动执行！
```
