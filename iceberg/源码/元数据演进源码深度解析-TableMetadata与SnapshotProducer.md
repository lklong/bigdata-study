# Iceberg 元数据演进源码深度解析（TableMetadata + SnapshotProducer 提交链路）

> 版本: Iceberg 1.x
> 源码路径: `/Users/kailongliu/bigdata/txProjects/iceberg/core`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

Iceberg 是新一代数据湖表格式，号称"ACID + 时间旅行 + Schema Evolution"。但要真正用好它，必须搞清楚：
- 一次 INSERT/MERGE/DELETE 到底怎么改变 Iceberg 表的元数据？
- `TableMetadata` / `Snapshot` / `ManifestList` / `ManifestFile` / `DataFile` 五层结构怎么协同？
- 多写入并发时怎么解决冲突（OCC，乐观并发控制）？为什么 commit 会重试？
- "时间旅行" / "回滚" 的物理实现是什么？

理解这条链是排查 "Iceberg 元数据膨胀 / commit 失败重试 / 表损坏 / 小文件爆炸" 的前置。

## 二、Iceberg 元数据五层结构

```
                ┌──────────────────────────┐
   Catalog ───► │  metadata.json           │  (TableMetadata)
                │  ─ 当前 snapshot id        │
                │  ─ schema 历史              │
                │  ─ partition spec 历史     │
                │  ─ branches/tags (refs)    │
                │  ─ snapshot log            │
                └──────────┬───────────────┘
                           │ 引用 currentSnapshotId
                           ▼
                ┌──────────────────────────┐
                │  Snapshot                 │  (Snapshot 对象)
                │  ─ snapshot-id             │
                │  ─ parent-id               │
                │  ─ sequence-number         │
                │  ─ summary (op + counters) │
                │  ─ manifest-list 路径      │
                └──────────┬───────────────┘
                           │
                           ▼
                ┌──────────────────────────┐
                │  manifest list (.avro)    │  (ManifestList writer)
                │  ─ N 个 ManifestFile 条目 │
                │  ─ 每条含 stats           │
                └──────┬─────────────┬─────┘
                       │             │
                       ▼             ▼
            ┌──────────────┐  ┌──────────────┐
            │ manifest 1   │  │ manifest 2   │   (ManifestFile)
            │  (.avro)     │  │  (.avro)     │
            │  M 个 entry  │  │  M 个 entry  │
            └──────┬───────┘  └──────┬───────┘
                   │                 │
                   ▼                 ▼
              DataFile          DataFile
              (.parquet/.orc)   (.parquet/.orc)
              + DeleteFile (V2 row-level delete)
```

## 三、关键源码逐段精读

### 3.1 TableMetadata —— 整张表的"大脑"

`TableMetadata.java:48-310`（删减版）：

```java
public class TableMetadata implements Serializable {
    public static final long INITIAL_SEQUENCE_NUMBER = 0;
    public static final int DEFAULT_FORMAT_VERSION = 2;
    static final int MIN_FORMAT_VERSION = 1;
    static final int SUPPORTED_TABLE_FORMAT_VERSION = 2;

    // 不可变字段（每次更新都生成新 TableMetadata 对象）
    private final int formatVersion;
    private final String uuid;
    private final String location;
    private final long lastSequenceNumber;       // 全局递增 seq
    private final long lastUpdatedMillis;
    private final int lastColumnId;
    private final int currentSchemaId;
    private final List<Schema> schemas;
    private final int defaultSpecId;
    private final List<PartitionSpec> specs;
    private final int defaultSortOrderId;
    private final List<SortOrder> sortOrders;
    private final Map<String, String> properties;
    private final long currentSnapshotId;        // 当前活跃 snapshot
    private final List<Snapshot> snapshots;      // 所有历史 snapshot
    private final List<HistoryEntry> snapshotLog;
    private final List<MetadataLogEntry> previousFiles;
    private final List<StatisticsFile> statisticsFiles;
    private final Map<Long, Snapshot> snapshotsById;
    private final Map<Integer, Schema> schemasById;
    private final Map<Integer, PartitionSpec> specsById;
    private final Map<Integer, SortOrder> sortOrdersById;
    private final List<MetadataUpdate> changes;
    private final Map<String, SnapshotRef> refs;  // branches & tags
    ...
}
```

**核心设计原则（TableMetadata.java:48）**：
> **TableMetadata 是不可变（immutable）的**

每次表变更（INSERT/UPDATE/SCHEMA EVOLUTION）都通过 `Builder` 构造一个**全新的** TableMetadata 对象，再把它写到一个新的 `vN.metadata.json` 文件。
旧的 `vN-1.metadata.json` 通过 `previousFiles` 引用保留（用于元数据日志清理）。

**为什么不可变？**
- 多个 reader 并发读老 snapshot，不会被写入操作影响 → 实现 **MVCC**（多版本并发控制）
- 时间旅行：拿到任意 metadata 版本就能还原任意时刻的表状态
- 简化故障恢复：commit 失败不污染当前状态

### 3.2 SnapshotRef —— Branch / Tag 的统一抽象

`TableMetadata.java:781-790`：

```java
SnapshotRef main = inputRefs.get(SnapshotRef.MAIN_BRANCH);
if (currentSnapshotId != -1) {
    Preconditions.checkArgument(
        main == null || currentSnapshotId == main.snapshotId(),
        "Current snapshot ID does not match main branch (%s != %s)",
        currentSnapshotId, main == null ? null : main.snapshotId());
}
```

Iceberg 1.0+ 引入 `SnapshotRef`（参考 git 设计）：
- **Branch**：可移动指针，写操作默认更新 `main` branch
- **Tag**：不可移动指针，常用于"快照"语义（如 `release-2025-01`）

**`SnapshotRef.MAIN_BRANCH = "main"`** 是默认 branch，对应 `currentSnapshotId`。

### 3.3 SnapshotProducer.apply() —— 一次写操作的核心逻辑

`SnapshotProducer.java:207-261`：

```java
@Override
public Snapshot apply() {
    refresh();                                   // ① 刷新 base 元数据（拿最新 metadata）
    Snapshot parentSnapshot = base.currentSnapshot();
    if (targetBranch != null) {
        SnapshotRef branch = base.ref(targetBranch);
        if (branch != null) {
            parentSnapshot = base.snapshot(branch.snapshotId());
        } else if (base.currentSnapshot() != null) {
            parentSnapshot = base.currentSnapshot();
        }
    }

    long sequenceNumber = base.nextSequenceNumber();    // ② 全局递增 seq
    Long parentSnapshotId = parentSnapshot == null ? null : parentSnapshot.snapshotId();

    validate(base, parentSnapshot);              // ③ 子类校验（OCC 关键，见下）
    List<ManifestFile> manifests = apply(base, parentSnapshot);  // ④ 产生 manifest 列表

    OutputFile manifestList = manifestListPath();

    try (ManifestListWriter writer =
            ManifestLists.write(
                ops.current().formatVersion(),
                manifestList,
                snapshotId(),
                parentSnapshotId,
                sequenceNumber)) {

        // ⑤ 把所有 manifest 写入 manifest list 文件（avro 格式）
        manifestLists.add(manifestList.location());
        ManifestFile[] manifestFiles = new ManifestFile[manifests.size()];
        Tasks.range(manifestFiles.length)
            .stopOnFailure()
            .throwFailureWhenFinished()
            .executeWith(workerPool)
            .run(index -> manifestFiles[index] = manifestsWithMetadata.get(manifests.get(index)));

        writer.addAll(Arrays.asList(manifestFiles));
    } catch (IOException e) {
        throw new RuntimeIOException(e, "Failed to write manifest list file");
    }

    // ⑥ 构造新 Snapshot 对象（注意：还没 commit！）
    return new BaseSnapshot(
        sequenceNumber,
        snapshotId(),
        parentSnapshotId,
        System.currentTimeMillis(),
        operation(),                       // append/overwrite/replace/delete
        summary(base),                     // counters: added-records, deleted-records, ...
        base.currentSchemaId(),
        manifestList.location());
}
```

**七步精髓**：
1. **refresh** —— 拉最新 metadata，避免基于过期版本提交（OCC 关键）
2. **拿 parent snapshot** —— 决定 branch 父节点
3. **分配 sequence number** —— 全局递增，用于 OCC 顺序判定
4. **validate** —— 子类实现，比如 `RowDelta.validate` 检查写入冲突（防止 RR 隔离破坏）
5. **生成 manifests** —— 子类实现 `apply(base, parent)` 决定哪些 manifest 进入新 snapshot
6. **写 manifest list 文件** —— 真实物理文件写到 HDFS/S3
7. **构造 Snapshot 对象** —— 内存对象，仍未 commit

### 3.4 SnapshotProducer.commit() —— OCC 提交 + 重试

`SnapshotProducer.java:354-399`：

```java
@Override
public void commit() {
    AtomicLong newSnapshotId = new AtomicLong(-1L);
    try {
        Tasks.foreach(ops)
            .retry(base.propertyAsInt(COMMIT_NUM_RETRIES, COMMIT_NUM_RETRIES_DEFAULT))  // 默认 4
            .exponentialBackoff(
                base.propertyAsInt(COMMIT_MIN_RETRY_WAIT_MS, ...),    // 默认 100ms
                base.propertyAsInt(COMMIT_MAX_RETRY_WAIT_MS, ...),    // 默认 60s
                base.propertyAsInt(COMMIT_TOTAL_RETRY_TIME_MS, ...),  // 默认 30min
                2.0 /* exponential */)
            .onlyRetryOn(CommitFailedException.class)              // ★ 只对冲突重试
            .run(taskOps -> {
                Snapshot newSnapshot = apply();                    // ① 重新 apply（拉最新 base）
                newSnapshotId.set(newSnapshot.snapshotId());
                TableMetadata.Builder update = TableMetadata.buildFrom(base);

                if (base.snapshot(newSnapshot.snapshotId()) != null) {
                    // ② 回滚操作（snapshot 已存在）
                    update.setBranchSnapshot(newSnapshot.snapshotId(), targetBranch);
                } else if (stageOnly) {
                    update.addSnapshot(newSnapshot);              // ③ 只暂存，不更新 branch
                } else {
                    update.setBranchSnapshot(newSnapshot, targetBranch);  // ④ 真正提交
                }

                TableMetadata updated = update.build();
                if (updated.changes().isEmpty()) {
                    return;                                      // ⑤ 无变更跳过
                }

                taskOps.commit(base, updated.withUUID());         // ★ 真正写元数据 JSON
            });
    } catch (CommitStateUnknownException commitStateUnknownException) {
        throw commitStateUnknownException;
    } catch (RuntimeException e) {
        Exceptions.suppressAndThrow(e, this::cleanAll);          // 清理失败遗留文件
    }
}
```

**OCC（乐观并发控制）的核心**：
- `taskOps.commit(base, updated)` 内部会做 **CAS（Compare-And-Swap）**：
  - HadoopFileIO：用 rename 原子操作（HDFS rename 是原子的）
  - HiveCatalog：在 Hive Metastore 内做行锁 + 版本比较
  - JDBC Catalog：用数据库的事务/版本号
  - Nessie/REST：服务端做 if-match/etag 比较
- **CAS 失败 → 抛 CommitFailedException → `onlyRetryOn(CommitFailedException.class)` 触发重试**
- 重试时**重新 apply()**（重新 refresh + validate），避免基于过期 base

**默认重试策略**：4 次重试 + 指数退避 + 最长 30 分钟。**多写并发严重时建议调大 retry 次数**。

### 3.5 BaseTransaction —— 多操作原子合并

虽然 SnapshotProducer 不在本文重点，但补一句：Iceberg 支持把多个操作合并成一个 commit（`Transaction` API）：
- `transaction.newAppend().commit()`
- `transaction.newDelete().commit()`
- ...
- `transaction.commitTransaction()`  ← 真正生成一个 snapshot 写入

中间步骤都只是在内存中累积 manifest，避免每个操作各自一个 snapshot 导致 history 爆炸。

## 四、Iceberg 元数据物理布局

```
warehouse/db/table/
├── metadata/
│   ├── v1.metadata.json                  ← TableMetadata 序列化
│   ├── v2.metadata.json
│   ├── v3.metadata.json                  ← 当前活跃版本（catalog 指向）
│   ├── snap-{snapshot-id}-1-{uuid}.avro  ← Manifest List
│   ├── snap-{snapshot-id}-2-{uuid}.avro
│   ├── {uuid}-m0.avro                    ← Manifest File
│   ├── {uuid}-m1.avro
│   └── ...
└── data/
    ├── part_a=2025/
    │   ├── 00000-0-{uuid}.parquet         ← DataFile
    │   └── 00001-0-{uuid}.parquet
    └── part_a=2026/
        ├── 00002-0-{uuid}.parquet
        └── 00003-1-{uuid}-deletes.parquet ← DeleteFile (V2)
```

**Catalog 的核心职责**：把 `db.table` → `metadata.json` 的路径"指针" **原子地** 切到新版本。
- HadoopCatalog：用 `version-hint.text` + rename
- HiveCatalog：用 HMS 的 `metadata_location` 表属性
- JDBC：用数据库行
- REST：HTTP if-match

## 五、实战 LOG 对齐

| 日志关键词 | 出处 | 含义 |
|----------|------|------|
| `Failed to write manifest list file` | `SnapshotProducer.java:249` | manifest list 写 HDFS 失败 |
| `Committed snapshot N (operation)` | TableOperations 实现类 | 提交成功 |
| `CommitFailedException: Cannot commit ...` | TableOperations | OCC 冲突，会触发重试 |
| `Retrying commit attempt N` | `Tasks.run` 内部 | 第 N 次重试 |
| `CommitStateUnknownException: ...` | 各 catalog 实现 | commit 状态未知（网络超时），**不能盲目重试** |

**故障排查公式**：
- "Cannot commit" 频繁 → 多写并发，调大 `commit.retry.num-retries`
- "CommitStateUnknownException" → catalog 网络问题，需要人工介入确认是否真的 commit 了
- 元数据文件膨胀 → 定期跑 `expireSnapshots` + `removeOrphanFiles`

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| TableMetadata 不可变 | MVCC 基础：reader/writer 不冲突 |
| 五层结构（metadata→snapshot→list→manifest→datafile）| **元数据分层** —— 每次写操作只生成新 snapshot/manifest，不动旧文件 |
| Snapshot 包含 sequence number | OCC 排序基础 + delete file 可见性判定（V2）|
| Manifest 用 Avro 不用 Parquet | 顺序读为主，Avro 行存更高效 |
| `apply()` + `commit()` 分离 | apply 在客户端做（生成 manifest），commit 是 catalog 原子切换 |
| OCC + 退避重试 | 高并发友好，无须分布式锁 |
| SnapshotRef (branches/tags) | 像 git 一样支持多版本独立维护，CDC/dev-prod 隔离 |
| Tasks 框架 (parallel manifest write) | 大量小 manifest 并行写，加速 commit |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `commit.retry.num-retries` | 4 | OCC 失败最大重试 |
| `commit.retry.min-wait-ms` | 100 | 重试初始等待 |
| `commit.retry.max-wait-ms` | 60000 | 重试最长等待 |
| `commit.retry.total-timeout-ms` | 1800000 (30min) | 重试总超时 |
| `commit.status-check.num-retries` | 3 | commit 状态未知时检查次数 |
| `format-version` | 2 | 表格式版本（V2 支持 row-level delete）|
| `write.metadata.previous-versions-max` | 100 | 保留多少个旧 metadata.json |
| `write.metadata.delete-after-commit.enabled` | false | commit 后自动清理过期 metadata |
| `history.expire.max-snapshot-age-ms` | 5 days | snapshot 默认过期时间 |
| `history.expire.min-snapshots-to-keep` | 1 | 至少保留多少个 snapshot |
| `write.target-file-size-bytes` | 512MB | 数据文件目标大小 |
| `write.distribution-mode` | none | 写入数据分布模式（none/hash/range）|

## 八、踩坑记录

1. **元数据膨胀（最常见）** —— 频繁小 commit + 没有定期清理。`metadata/` 目录数十万小文件。**应对**：
   ```sql
   CALL spark_catalog.system.expire_snapshots('db.tbl', TIMESTAMP '...', 5);
   CALL spark_catalog.system.rewrite_manifests('db.tbl');
   CALL spark_catalog.system.remove_orphan_files('db.tbl');
   ```
2. **CommitFailedException 频繁** —— 多个写入流并发同表。**应对**：调大 `commit.retry.num-retries=10` 或者上层串行化。
3. **CommitStateUnknownException** —— catalog 网络超时，commit 可能成功也可能失败。**应对**：先查 `catalog.tableExists()` + `currentSnapshot().summary()`，确认状态，再决定重试还是直接接受。**不要无脑 retry**，可能造成同 snapshot 多次写入。
4. **Manifest 倾斜** —— 一个 manifest 引用 1 万个 datafile，另一个只 100 个，扫描时慢的拖快的。**应对**：`rewrite_manifests` 重平衡。
5. **DeleteFile 累积** —— V2 表频繁 UPDATE/DELETE，DeleteFile 越来越多，读取时 anti-join 成本飙升。**应对**：`rewrite_data_files` + `compact_position_deletes`。
6. **Branch/Tag 不清理** —— 创建后忘了删，对应 snapshot 永不过期。**应对**：定期检查 `SHOW REFS`。
7. **HiveCatalog 锁等待** —— HMS 内 `IcebergTablePropertiesLockHelper` 默认锁等待 3min，并发高时全部排队。**应对**：升级 Iceberg 1.4+ 的 `iceberg.hive.lock-creation-timeout-ms`。
8. **Format Version 不匹配** —— 升级 Iceberg 后某些查询引擎仍走 V1 协议。**应对**：检查所有引擎都支持当前 format-version。

## 九、认知更新

- 之前以为"Snapshot 提交是事务"，**实际上是 OCC + retry**，没有传统数据库的 X 锁。多写场景下重试是常态，**不是异常**。
- `apply()` 和 `commit()` 是分开的两个阶段，**apply() 已经写了 manifest list 到 HDFS**，commit() 只是切 metadata 指针。失败时如果不调用 `cleanAll()`，会留下"孤儿 manifest list 文件"。
- `SnapshotRef` 是 1.0 之后的核心抽象 —— 之前只有 `currentSnapshotId`，现在 `main` branch + 多 branch + tags 都统一在 SnapshotRef 下。**v2 之前的代码看 currentSnapshotId，v2 之后看 refs.MAIN_BRANCH**。
- `CommitStateUnknownException` 才是最危险的异常 —— `CommitFailedException` 重试就行，但 unknown 状态必须人工介入。生产中要专门捕获这个异常。
- Iceberg 的 sequence number 不是 snapshot id —— **snapshot id 是随机长 long**（防猜测），sequence number 才是全局递增的逻辑时钟。

## 十、下一步深挖方向

- [ ] DeleteFile 的两种模式：position delete vs equality delete
- [ ] BaseTransaction 多操作合并的内部状态机
- [ ] HiveCatalog 的元数据锁机制（hive lock 4-step 协议）
- [ ] Manifest pruning 算法（min/max stats 过滤）
- [ ] Sort Order / Z-Order 与 Manifest stats 的关系

---

**沉淀完成。Iceberg 五层元数据结构 + apply/commit 分离 + OCC retry 机制源码精确对齐。**
