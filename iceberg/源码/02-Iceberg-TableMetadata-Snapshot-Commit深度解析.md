# Iceberg 源码深度解析：TableMetadata / Snapshot / Commit 机制

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-25

---

## 一、TableMetadata — Iceberg 的"DNA"

**源码位置**: `core/src/main/java/org/apache/iceberg/TableMetadata.java`（64KB，Iceberg 最大的单文件）

### 1.1 核心字段

```java
// TableMetadata.java Line 236-264
private final String metadataFileLocation;    // 当前 metadata.json 路径
private final int formatVersion;              // 表格式版本（1/2/3）
private final String uuid;                    // 表唯一标识（v2 必须）
private final String location;                // 表数据根路径
private final long lastSequenceNumber;        // 最后序列号（v2+ 用于排序）
private final long lastUpdatedMillis;         // 最后更新时间
private final int lastColumnId;               // 最后分配的列 ID（递增）
private final int currentSchemaId;            // 当前 Schema ID
private final List<Schema> schemas;           // 所有历史 Schema（不删除）
private final int defaultSpecId;              // 当前默认分区规格 ID
private final List<PartitionSpec> specs;      // 所有历史分区规格
private final int defaultSortOrderId;         // 默认排序 ID
private final List<SortOrder> sortOrders;     // 所有排序规则
private final Map<String, String> properties; // 表属性
private final long currentSnapshotId;         // 当前快照 ID
private volatile List<Snapshot> snapshots;    // 所有快照列表
private volatile Map<String, SnapshotRef> refs; // 分支/标签引用
private final List<HistoryEntry> snapshotLog; // 快照历史日志
private final List<MetadataLogEntry> previousFiles; // 历史 metadata 文件
```

**关键设计**:
- **所有历史 Schema/PartitionSpec 都保留**，通过 ID 引用，支持 Schema Evolution 和 Partition Evolution
- `lastColumnId` 只增不减，保证 field_id 全局唯一
- `snapshots` 使用 `volatile` + `SerializableSupplier` 实现**延迟加载**（metadata.json 可能引用外部 snapshot 文件）

### 1.2 新建表的初始化流程

```java
// TableMetadata.java Line 101-147
static TableMetadata newTableMetadata(...) {
    // 1. 重新分配所有列 ID（保证从 0 开始递增）
    AtomicInteger lastColumnId = new AtomicInteger(0);
    Schema freshSchema = TypeUtil.assignFreshIds(
        INITIAL_SCHEMA_ID, schema, lastColumnId::incrementAndGet);

    // 2. 用新列 ID 重建分区规格
    PartitionSpec freshSpec = specBuilder.build();

    // 3. 用新列 ID 重建排序规则
    SortOrder freshSortOrder = freshSortOrder(...);

    // 4. 用 Builder 构建最终 TableMetadata
    return new Builder()
        .setInitialFormatVersion(formatVersion)
        .setCurrentSchema(freshSchema, lastColumnId.get())
        .setDefaultPartitionSpec(freshSpec)
        .setDefaultSortOrder(freshSortOrder)
        .setLocation(location)
        .setProperties(properties)
        .build();
}
```

**关键点**: 创建表时会**重新分配所有 field_id**，确保内部一致性。这意味着同一张表的 field_id 永远从 1 开始递增。

### 1.3 版本支持

```java
static final int DEFAULT_TABLE_FORMAT_VERSION = 2;  // 默认 v2
static final int SUPPORTED_TABLE_FORMAT_VERSION = 3; // 最高支持 v3
```

| 版本 | 特性 |
|------|------|
| v1 | 基础功能，无序列号，无 row-level delete |
| v2 | 序列号、row-level delete（Position/Equality）、UUID 必须 |
| v3 | 新增类型支持 |

---

## 二、Snapshot — 数据的"时间胶囊"

### 2.1 接口定义

```java
// Snapshot.java (api) — 完整接口
public interface Snapshot extends Serializable {
    long sequenceNumber();         // 序列号（v2+，提交时分配）
    long snapshotId();             // 全局唯一 ID
    Long parentId();               // 父快照 ID（形成链表）
    long timestampMillis();        // 创建时间戳
    List<ManifestFile> allManifests(FileIO io);    // 所有 Manifest
    List<ManifestFile> dataManifests(FileIO io);   // 数据 Manifest
    List<ManifestFile> deleteManifests(FileIO io); // 删除 Manifest
    String operation();            // 操作类型（append/overwrite/replace/delete）
    Map<String, String> summary(); // 摘要统计
    Iterable<DataFile> addedDataFiles(FileIO io);  // 新增数据文件
    Iterable<DataFile> removedDataFiles(FileIO io); // 删除的数据文件
    String manifestListLocation(); // ManifestList 文件位置
    Integer schemaId();            // Schema 版本
}
```

### 2.2 快照链与分支

```
Snapshot 形成单链表：
  snap-1 ← snap-2 ← snap-3 (main branch)
                  ↖ snap-4 (audit branch)

refs 管理分支和标签：
  "main"  → SnapshotRef(snap-3, BRANCH)
  "audit" → SnapshotRef(snap-4, BRANCH)
  "v1.0"  → SnapshotRef(snap-2, TAG)
```

---

## 三、Commit 机制 — 乐观并发的精髓

### 3.1 SnapshotProducer.commit() — 重试循环

**源码位置**: `core/src/main/java/org/apache/iceberg/SnapshotProducer.java` Line 387-471

```java
// SnapshotProducer.commit() 核心逻辑
public void commit() {
    AtomicReference<Snapshot> stagedSnapshot = new AtomicReference<>();

    Tasks.foreach(ops)
        // 1. 重试策略：指数退避
        .retry(COMMIT_NUM_RETRIES)         // 默认 4 次
        .exponentialBackoff(
            COMMIT_MIN_RETRY_WAIT_MS,      // 默认 100ms
            COMMIT_MAX_RETRY_WAIT_MS,      // 默认 60000ms
            COMMIT_TOTAL_RETRY_TIME_MS,    // 默认 1800000ms (30min)
            2.0)                           // 指数因子
        .onlyRetryOn(CommitFailedException.class)  // 只重试冲突异常
        .run(taskOps -> {
            // 2. 生成新快照（每次重试都重新生成）
            Snapshot newSnapshot = apply();
            stagedSnapshot.set(newSnapshot);

            // 3. 构建新 TableMetadata
            TableMetadata.Builder update = TableMetadata.buildFrom(base);
            update.setBranchSnapshot(newSnapshot, targetBranch);
            TableMetadata updated = update.build();

            // 4. 原子提交（由具体 TableOperations 实现）
            taskOps.commit(base, updated.withUUID());
            // 如果 base 已经过期 → 抛 CommitFailedException → 重试
        });

    // 5. 提交成功后清理
    cleanUncommitted(committedManifests);
    // 清理多次重试产生的未使用 manifest-list
    for (String manifestList : manifestLists) {
        if (!committedSnapshot.manifestListLocation().equals(manifestList)) {
            deleteFile(manifestList);
        }
    }
}
```

### 3.2 SnapshotProducer.apply() — 生成快照

```java
// Line 244-290
public Snapshot apply() {
    refresh();  // 刷新 base metadata
    Snapshot parentSnapshot = SnapshotUtil.latestSnapshot(base, targetBranch);
    long sequenceNumber = base.nextSequenceNumber();

    // 1. 验证（子类实现，如冲突检测）
    validate(base, parentSnapshot);

    // 2. 生成新的 Manifest 列表（子类实现）
    List<ManifestFile> manifests = apply(base, parentSnapshot);

    // 3. 写 ManifestList 文件
    OutputFile manifestList = manifestListPath();
    try (ManifestListWriter writer = ManifestLists.write(...)) {
        // 并行enrichment（填充 manifest metadata）
        Tasks.range(manifestFiles.length)
            .executeWith(workerPool)
            .run(index -> manifestFiles[index] = manifestsWithMetadata.get(...));
        writer.addAll(Arrays.asList(manifestFiles));
    }

    // 4. 创建 BaseSnapshot 对象
    return new BaseSnapshot(
        sequenceNumber, snapshotId(), parentSnapshotId,
        System.currentTimeMillis(), operation(), summary(base),
        base.currentSchemaId(), manifestList.location());
}
```

### 3.3 BaseMetastoreTableOperations.commit() — 原子指针切换

```java
// BaseMetastoreTableOperations.java Line 107-133
public void commit(TableMetadata base, TableMetadata metadata) {
    // 1. Stale check（乐观锁第一道防线）
    if (base != current()) {
        throw new CommitFailedException("Cannot commit: stale table metadata");
    }

    // 2. No-op check
    if (base == metadata) {
        LOG.info("Nothing to commit.");
        return;
    }

    // 3. 子类执行实际提交（更新 HMS/JDBC/S3 指针）
    doCommit(base, metadata);

    // 4. 清理被替换的旧 metadata 文件
    CatalogUtil.deleteRemovedMetadataFiles(io(), base, metadata);

    // 5. 标记需要刷新
    requestRefresh();
}
```

### 3.4 HiveTableOperations.doCommit() — HMS 实现

HMS 使用 Hive 表属性 `metadata_location` 作为指针：

```
1. 写新 metadata.json 到存储
2. 调用 HMS API: alterTable(table, newMetadataLocation)
   → HMS 内部用行锁保证原子性
3. 如果 HMS 中的 metadata_location 已变 → CommitFailedException
```

### 3.5 完整 Commit 流程图

```
用户操作（INSERT/UPDATE/DELETE）
  │
  ▼
SnapshotProducer.commit()
  │
  ├─── retry loop (最多 4 次，指数退避) ─────────┐
  │                                                │
  │  ┌─ apply() ──────────────────────────────┐   │
  │  │ 1. refresh() → 获取最新 base metadata  │   │
  │  │ 2. validate() → 冲突检测               │   │
  │  │ 3. apply() → 生成新 Manifest 列表       │   │
  │  │    ├── 写新 Manifest 文件               │   │
  │  │    ├── 写 ManifestList 文件             │   │
  │  │    └── 返回 BaseSnapshot               │   │
  │  └────────────────────────────────────────┘   │
  │                                                │
  │  ┌─ commit to catalog ────────────────────┐   │
  │  │ 4. TableMetadata.buildFrom(base)       │   │
  │  │    .setBranchSnapshot(newSnapshot)      │   │
  │  │    .build()                             │   │
  │  │ 5. writeNewMetadata(updated)            │   │
  │  │    → 写新 v{N+1}.metadata.json         │   │
  │  │ 6. doCommit(base, updated)              │   │
  │  │    → HMS/JDBC/S3 原子更新指针           │   │
  │  │    → 失败? → CommitFailedException      │───┘
  │  └────────────────────────────────────────┘
  │
  ▼
成功 → cleanUncommitted() → 清理未提交的 Manifest
```

---

## 四、重试参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `commit.retry.num-retries` | 4 | 最大重试次数 |
| `commit.retry.min-wait-ms` | 100 | 最小等待时间 |
| `commit.retry.max-wait-ms` | 60000 | 最大等待时间 |
| `commit.retry.total-timeout-ms` | 1800000 (30min) | 总超时时间 |

**高并发场景调优建议**：
```sql
ALTER TABLE t SET TBLPROPERTIES (
  'commit.retry.num-retries' = '10',
  'commit.retry.min-wait-ms' = '200',
  'commit.retry.max-wait-ms' = '120000'
);
```

---

*Iceberg Commit 深度解析 v1.0 | Eric | 2026-04-25*
