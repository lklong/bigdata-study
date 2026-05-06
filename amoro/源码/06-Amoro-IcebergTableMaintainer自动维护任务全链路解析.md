# Amoro 源码深度解析：IcebergTableMaintainer 自动维护任务全链路

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-26

---

## 一、自动维护架构总览

```
DefaultTableService.initialize()
  │
  ├── 注册 RuntimeHandlerChain
  │    headHandler → [OptimizingQueue] → [AsyncTableExecutors]
  │
  └── AsyncTableExecutors 包含 6 个定时执行器:
       │
       ├── SnapshotsExpiringExecutor    (1小时周期)
       │    → TableMaintainer.expireSnapshots()
       │
       ├── OrphanFilesCleaningExecutor  (可配周期)
       │    → TableMaintainer.cleanOrphanFiles()
       │
       ├── DanglingDeleteFilesCleaningExecutor
       │    → TableMaintainer.cleanDanglingDeleteFiles()
       │
       ├── DataExpiringExecutor         (1小时周期)
       │    → TableMaintainer.expireData()
       │
       ├── TagsAutoCreatingExecutor     (1小时周期)
       │    → TableMaintainer.autoCreateTags()
       │
       └── BlockerExpiringExecutor      (过期 blocker 清理)
```

---

## 二、TableMaintainer 接口

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/maintainer/TableMaintainer.java`

```java
public interface TableMaintainer {
    void cleanOrphanFiles(TableRuntime tableRuntime);    // 清理孤立文件
    void cleanDanglingDeleteFiles(TableRuntime runtime); // 清理悬挂删除文件
    void expireSnapshots(TableRuntime tableRuntime);     // 过期快照
    void expireData(TableRuntime tableRuntime);          // 过期数据
    void autoCreateTags(TableRuntime tableRuntime);      // 自动创建 Tag

    // 工厂方法 — 根据表格式选择实现
    static TableMaintainer ofTable(AmoroTable<?> amoroTable) {
        TableFormat format = amoroTable.format();
        if (format.in(MIXED_HIVE, MIXED_ICEBERG)) {
            return new MixedTableMaintainer((MixedTable) amoroTable.originalTable());
        } else if (ICEBERG.equals(format)) {
            return new IcebergTableMaintainer((Table) amoroTable.originalTable());
        }
    }
}
```

---

## 三、Executor 执行器详解

### 3.1 BaseTableExecutor — 执行器基类

```java
// 所有执行器继承此基类
public abstract class BaseTableExecutor extends RuntimeHandlerChain {
    protected abstract long getNextExecutingTime(TableRuntime runtime); // 下次执行间隔
    protected abstract boolean enabled(TableRuntime runtime);          // 是否启用
    public abstract void execute(TableRuntime runtime);                // 执行逻辑

    // 调度机制:
    // 每个 TableRuntime 对应一个 ScheduledFuture
    // 根据 getNextExecutingTime() 决定下次执行时间
    // enabled() 为 false 时跳过
}
```

### 3.2 SnapshotsExpiringExecutor — 快照过期

```java
public class SnapshotsExpiringExecutor extends BaseTableExecutor {
    private static final long INTERVAL = 60 * 60 * 1000L; // 1 小时

    @Override
    protected long getNextExecutingTime(TableRuntime runtime) {
        return INTERVAL;
    }

    @Override
    protected boolean enabled(TableRuntime runtime) {
        return runtime.getTableConfiguration().isExpireSnapshotEnabled();
    }

    @Override
    public void execute(TableRuntime tableRuntime) {
        AmoroTable<?> amoroTable = loadTable(tableRuntime);
        TableMaintainer maintainer = TableMaintainer.ofTable(amoroTable);
        maintainer.expireSnapshots(tableRuntime);
        // → IcebergTableMaintainer.expireSnapshots()
    }
}
```

### 3.3 OrphanFilesCleaningExecutor — 孤立文件清理

```java
public class OrphanFilesCleaningExecutor extends BaseTableExecutor {
    private final Duration interval;  // 可配置间隔

    @Override
    protected boolean enabled(TableRuntime runtime) {
        return runtime.getTableConfiguration().isCleanOrphanEnabled();
    }

    @Override
    public void execute(TableRuntime tableRuntime) {
        AmoroTable<?> amoroTable = loadTable(tableRuntime);
        TableMaintainer maintainer = TableMaintainer.ofTable(amoroTable);
        maintainer.cleanOrphanFiles(tableRuntime);
        // → IcebergTableMaintainer.cleanOrphanFiles()
    }
}
```

---

## 四、IcebergTableMaintainer — 核心实现（39KB 大文件）

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/maintainer/IcebergTableMaintainer.java`

### 4.1 expireSnapshots — 快照过期

```java
// IcebergTableMaintainer.java (简化)
@Override
public void expireSnapshots(TableRuntime tableRuntime) {
    TableConfiguration config = tableRuntime.getTableConfiguration();
    // 1. 获取保留配置
    int retainLast = config.getSnapshotRetainNum();         // 默认 10
    long olderThanMs = config.getSnapshotRetainTime();      // 默认 7 天

    // 2. 保护正在优化的快照
    long optimizingSnapshotId = tableRuntime.getOptimizingSnapshotId();
    // 不能过期正在被 Self-Optimizing 引用的快照！

    // 3. 执行过期
    table.expireSnapshots()
        .expireOlderThan(System.currentTimeMillis() - olderThanMs)
        .retainLast(retainLast)
        .cleanExpiredFiles(true)  // 直接清理文件（AMS 端执行，非 Spark）
        .commit();
}
```

### 4.2 cleanOrphanFiles — 孤立文件清理

```java
@Override
public void cleanOrphanFiles(TableRuntime tableRuntime) {
    // 1. 计算安全时间
    long olderThan = System.currentTimeMillis() -
        tableRuntime.getTableConfiguration().getOrphanCleanDelay(); // 默认 3 天

    // 2. 扫描表目录
    Set<String> validFiles = collectValidFiles();  // 元数据引用的所有文件
    Set<String> actualFiles = listFilesByLocation();  // 文件系统实际存在的文件

    // 3. 计算差集
    Set<String> orphanFiles = actualFiles - validFiles;

    // 4. 按时间过滤 + 删除
    orphanFiles.stream()
        .filter(f -> getFileModTime(f) < olderThan)
        .forEach(f -> table.io().deleteFile(f));
}
```

### 4.3 cleanDanglingDeleteFiles — 悬挂删除文件清理

```java
@Override
public void cleanDanglingDeleteFiles(TableRuntime tableRuntime) {
    // 悬挂删除文件: delete file 引用的 data file 已经不存在了
    // 这些 delete file 永远不会被应用，白白占用空间

    // 1. 扫描所有 delete files
    // 2. 检查每个 delete file 引用的 data files 是否还存在
    // 3. 删除不再有效的 delete files
}
```

### 4.4 expireData — 数据过期（TTL）

```java
@Override
public void expireData(TableRuntime tableRuntime) {
    DataExpirationConfig config = tableRuntime.getDataExpirationConfig();
    if (!config.isEnabled()) return;

    // 1. 确定过期字段和保留时长
    String expirationField = config.getExpirationField();  // 如 "dt"
    Duration retention = config.getRetentionTime();         // 如 90 天

    // 2. 计算过期边界
    long expireBoundary = System.currentTimeMillis() - retention.toMillis();

    // 3. 扫描分区，删除过期分区的数据
    // 如 dt < '2026-01-25' 的所有分区数据
}
```

### 4.5 autoCreateTags — 自动创建 Tag

```java
@Override
public void autoCreateTags(TableRuntime tableRuntime) {
    TagConfiguration config = tableRuntime.getTagConfiguration();
    if (!config.isAutoCreateEnabled()) return;

    // 1. 获取触发条件
    Duration period = config.getAutoCreatePeriod();  // 如 1 天
    String format = config.getAutoCreateFormat();     // 如 "yyyyMMdd"

    // 2. 检查是否需要创建新 Tag
    // 3. 创建 Tag（Iceberg 的 Ref → Tag）
    //    等效于: table.manageSnapshots().createTag(tagName, snapshotId).commit();
}
```

---

## 五、OptimizingQueue — 调度策略

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/OptimizingQueue.java`

### 5.1 核心职责

```
OptimizingQueue 作为 RuntimeHandlerChain 的一环:
  1. 接收表状态变更事件 (fireTableAdded/fireStatusChanged)
  2. 维护 SchedulingPolicy（调度策略）
  3. 为 Optimizer 提供 pollTask() 接口
  4. 管理优化进程的生命周期
```

### 5.2 SchedulingPolicy — 表调度排序

```java
// SchedulingPolicy.java
public class SchedulingPolicy {
    private final Map<ServerTableIdentifier, TableRuntime> tableRuntimeMap;
    private volatile String policyName;  // 默认 "quota"

    // 选择下一个需要优化的表
    public TableRuntime scheduleTable(Set<ServerTableIdentifier> skipSet) {
        // 1. 填充跳过集合
        fillSkipSet(skipSet);
        // 跳过条件:
        //   - 不是 PENDING 状态
        //   - 被 Blocker 阻塞
        //   - 距上次 plan 时间 < minPlanInterval

        // 2. 按策略排序，选择优先级最高的表
        return tableRuntimeMap.values().stream()
            .filter(t -> !skipSet.contains(t.getTableIdentifier()))
            .min(createSorterByPolicy())  // ← 排序比较器
            .orElse(null);
    }

    // SPI 加载排序策略
    private Comparator<TableRuntime> createSorterByPolicy() {
        SorterFactory factory = sorterFactoryCache.get(policyName);
        return factory.createComparator();
    }
}
```

### 5.3 内置调度策略

| 策略 | 类 | 排序逻辑 |
|------|-----|---------|
| **QuotaOccupy**（默认） | `QuotaOccupySorter` | 按配额占用率排序，配额用得少的优先 |
| **Balanced** | `BalancedSorter` | 按上次优化时间排序，最久未优化的优先 |

```java
// QuotaOccupySorter.java
public class QuotaOccupySorter implements SorterFactory {
    public static final String IDENTIFIER = "quota";

    @Override
    public Comparator<TableRuntime> createComparator() {
        return Comparator.comparingDouble(
            runtime -> runtime.calculateQuotaOccupy()
            // quotaOccupy = 实际使用时间 / 分配配额时间
            // 值越小 → 配额空间越大 → 优先调度
        );
    }
}
```

---

## 六、完整调度链路

```
OptimizingQueue 内部流程:

Optimizer.pollTask()
  │
  ├── 1. SchedulingPolicy.scheduleTable()
  │      选择 PENDING 状态、未被阻塞、满足最小间隔的表
  │      按 QuotaOccupy 排序选择优先级最高的
  │
  ├── 2. planOptimizing(selectedTable)
  │      │
  │      ├── 加载表元数据
  │      ├── 创建 OptimizingPlanner
  │      │    ├── IcebergOptimizingPlanner (纯 Iceberg)
  │      │    └── MixedIcebergOptimizingPlanner (Mixed-Iceberg)
  │      │
  │      ├── OptimizingPlanner.plan()
  │      │    ├── 评估每个分区: PartitionEvaluator.evaluate()
  │      │    ├── 决定 Minor / Major / Full optimize
  │      │    └── 生成 OptimizingProcess + TaskRuntime 列表
  │      │
  │      └── 入库: 持久化 OptimizingProcessMeta + OptimizingTaskMeta
  │
  ├── 3. 返回 TaskRuntime 给 Optimizer
  │      Optimizer 通过 Thrift RPC 领取任务
  │
  ├── 4. Optimizer 执行任务
  │      IcebergRewriteExecutor / MixedIcebergRewriteExecutor
  │      读取数据 → 合并 → 写出新文件
  │
  ├── 5. Optimizer 提交结果
  │      pollTask() → acknowledgeTask() → commitTask()
  │
  └── 6. AMS 提交到 Iceberg
         UnKeyedTableCommit / KeyedTableCommit
         table.newRewrite().deleteFile(old).addFile(new).commit()
```

---

## 七、AsyncTableExecutors 初始化

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/table/executor/AsyncTableExecutors.java`

```java
public class AsyncTableExecutors {
    private SnapshotsExpiringExecutor snapshotsExpiringExecutor;
    private OrphanFilesCleaningExecutor orphanFilesCleaningExecutor;
    private DanglingDeleteFilesCleaningExecutor danglingDeleteFilesCleaningExecutor;
    private DataExpiringExecutor dataExpiringExecutor;
    private TagsAutoCreatingExecutor tagsAutoCreatingExecutor;
    private BlockerExpiringExecutor blockerExpiringExecutor;

    // 在 DefaultTableService.addHandlerChain() 时注册
    // 每个 executor 独立的线程池 + 定时调度
    // 对每个 TableRuntime 独立维护调度状态
}
```

---

## 八、运维关键配置

| 配置项 | 对应执行器 | 默认值 | 说明 |
|--------|-----------|--------|------|
| `expire-snapshots.enabled` | SnapshotsExpiring | `true` | 是否自动过期快照 |
| `snapshot.retain-num` | SnapshotsExpiring | `10` | 保留快照数 |
| `snapshot.retain-time` | SnapshotsExpiring | `7d` | 保留时间 |
| `clean-orphan-files.enabled` | OrphanFilesCleaning | `true` | 是否清理孤立文件 |
| `clean-orphan-files.delay` | OrphanFilesCleaning | `3d` | 安全延迟 |
| `data-expire.enabled` | DataExpiring | `false` | 是否按 TTL 过期数据 |
| `data-expire.field` | DataExpiring | — | 过期字段 |
| `data-expire.retention-time` | DataExpiring | — | 保留时长 |
| `tag.auto-create.enabled` | TagsAutoCreating | `false` | 是否自动创建 Tag |
| `tag.auto-create.trigger.period` | TagsAutoCreating | `1d` | Tag 创建周期 |
| `self-optimizing.group` | OptimizingQueue | `default` | 优化组 |
| `self-optimizing.quota` | OptimizingQueue | `0.1` | CPU 配额 |

---

## 九、设计亮点

| 设计 | 说明 |
|------|------|
| **保护性过期** | expireSnapshots 时跳过正在被 Self-Optimizing 引用的快照 |
| **SPI 可扩展** | SchedulingPolicy 通过 ServiceLoader 加载自定义排序策略 |
| **独立线程池** | 每个执行器独立线程池，维护任务互不干扰 |
| **配置热更新** | 表配置变更通过 handleConfigChanged 事件实时生效 |
| **Blocker 保护** | 优化时对表加 Blocker，防止并发操作冲突 |
