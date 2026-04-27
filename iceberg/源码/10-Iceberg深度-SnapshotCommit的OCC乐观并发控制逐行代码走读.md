# Iceberg 深度源码：Snapshot Commit 的 OCC 乐观并发控制 — 从 retry 到 conflict 的每一行代码

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/core/src/main/java/org/apache/iceberg/SnapshotProducer.java` 真实源码逐行分析
> Eric | 2026-04-27

---

## 写在前面

这是一篇不一样的源码分析。

不罗列 API，不画漂亮的架构图。我带你**逐行走一遍 Iceberg 最核心的 100 行代码** — `SnapshotProducer.commit()` 方法。理解了这 100 行，你就理解了 Iceberg 的灵魂：**如何在没有分布式锁的前提下，保证多个 Spark/Flink Job 并发写入同一张表不丢数据、不出脏读。**

---

## 一、问题：没有锁，怎么保证并发安全？

想象这个场景：

```
时刻 T=0: Spark Job A 开始写入 orders 表
时刻 T=1: Flink Job B 也开始写入 orders 表
时刻 T=2: Job A 写完数据文件，准备 commit
时刻 T=3: Job B 也写完数据文件，准备 commit

问题：
  - 如果 A 和 B 都读到了 v5.metadata.json
  - A commit 成功，表变成 v6
  - B 还拿着 v5 来 commit → 怎么办？
```

传统数据库用锁（Pessimistic Locking）。Iceberg 用 **OCC（Optimistic Concurrency Control，乐观并发控制）**：

```
OCC 三步走：
  1. READ    — 读取当前 metadata（base）
  2. COMPUTE — 计算变更（生成新 snapshot + manifest）
  3. CAS     — Compare-And-Swap：如果 base 没变，则提交；否则重试
```

现在打开源码看它怎么做的。

---

## 二、入口：`SnapshotProducer.commit()` — 第 387-471 行

这是 **Iceberg 所有写操作（append/overwrite/rowDelta/rewrite）的统一 commit 入口**。无论你调 `table.newAppend().commit()` 还是 `table.newRowDelta().commit()`，最终都走到这里。

```java
// SnapshotProducer.java Line 387-430（核心 commit 逻辑，我逐行翻译）
@Override
public void commit() {
    // stagedSnapshot 用于追踪最后一次 attempt 生成的 snapshot
    // 如果 commit 成功，这就是被提交的 snapshot
    // 如果 commit 失败需要清理，也从这里拿到要清理的 manifest
    AtomicReference<Snapshot> stagedSnapshot = new AtomicReference<>();

    try (Timed ignore = commitMetrics().totalDuration().start()) {
      try {
        Tasks.foreach(ops)    // ops = TableOperations，封装了底层 Catalog 的 commit
            // ─── 重试配置 ───
            .retry(base.propertyAsInt(COMMIT_NUM_RETRIES, COMMIT_NUM_RETRIES_DEFAULT))
            // 默认重试 4 次（COMMIT_NUM_RETRIES_DEFAULT = 4）

            .exponentialBackoff(
                base.propertyAsInt(COMMIT_MIN_RETRY_WAIT_MS, COMMIT_MIN_RETRY_WAIT_MS_DEFAULT),
                // 最小等待 100ms
                base.propertyAsInt(COMMIT_MAX_RETRY_WAIT_MS, COMMIT_MAX_RETRY_WAIT_MS_DEFAULT),
                // 最大等待 60000ms (1分钟)
                base.propertyAsInt(COMMIT_TOTAL_RETRY_TIME_MS, COMMIT_TOTAL_RETRY_TIME_MS_DEFAULT),
                // 总重试时间 1800000ms (30分钟)
                2.0 /* 指数退避因子 */)

            .onlyRetryOn(CommitFailedException.class)
            // ★ 只有 CommitFailedException 才重试！
            // CommitStateUnknownException 不重试（无法确定是否已提交）
            // 其他异常不重试

            .run(taskOps -> {
                // ════════════════════════════════════════════
                // ★★★ 这个 lambda 是每次重试都会执行的核心逻辑 ★★★
                // ════════════════════════════════════════════

                // Step 1: apply() — 刷新元数据 + 生成新 Snapshot
                Snapshot newSnapshot = apply();
                stagedSnapshot.set(newSnapshot);

                // Step 2: 构建新的 TableMetadata
                TableMetadata.Builder update = TableMetadata.buildFrom(base);
                if (base.snapshot(newSnapshot.snapshotId()) != null) {
                    // 这是回滚操作（snapshot ID 已存在）
                    update.setBranchSnapshot(newSnapshot.snapshotId(), targetBranch);
                } else if (stageOnly) {
                    // 仅暂存（用于事务），不设为当前 snapshot
                    update.addSnapshot(newSnapshot);
                } else {
                    // ★ 正常 commit：添加 snapshot 并设为 branch 的 HEAD
                    update.setBranchSnapshot(newSnapshot, targetBranch);
                }

                TableMetadata updated = update.build();
                if (updated.changes().isEmpty()) {
                    return; // 无变化，跳过 commit
                }

                // Step 3: CAS 提交！
                // ★★★ 这一行是 OCC 的核心 ★★★
                taskOps.commit(base, updated.withUUID());
                // base = 我读到的旧元数据
                // updated = 我计算出的新元数据
                // 如果底层 Catalog 发现 base 已经过时 → 抛 CommitFailedException → 重试
            });
      } catch (CommitStateUnknownException e) {
          throw e;  // 状态未知，不能清理也不能重试，直接上抛
      } catch (RuntimeException e) {
          // commit 失败 → 清理已写入但未提交的 manifest 文件
          if (!strictCleanup || e instanceof CleanableFailure) {
              Exceptions.suppressAndThrow(e, this::cleanAll);
          }
          throw e;
      }
    }
}
```

**关键洞察**：整个 commit 方法的灵魂就一句话：

```java
taskOps.commit(base, updated.withUUID());
```

这是一个 **CAS（Compare-And-Swap）操作**。不同的 Catalog 实现用不同的方式保证原子性：

| Catalog | CAS 实现方式 | 具体代码位置 |
|---------|-------------|-------------|
| **HadoopCatalog** | 文件系统 atomic rename | `HadoopTableOperations.java:160-161` |
| **HiveCatalog** | HMS `alter_table` + 锁 | `HiveTableOperations.java` |
| **RESTCatalog** | HTTP POST + 服务端版本检查 | `RESTTableOperations.java` |

---

## 三、apply() — 每次重试都会重新执行

```java
// SnapshotProducer.java Line 245-290
@Override
public Snapshot apply() {
    // ★ 第一件事：刷新元数据！
    // 这就是为什么重试时能拿到最新的 base
    refresh();  // → this.base = ops.refresh();

    // 拿到当前 branch 的最新 snapshot 作为 parent
    Snapshot parentSnapshot = SnapshotUtil.latestSnapshot(base, targetBranch);

    // ★ sequence number 递增（v2 格式核心）
    long sequenceNumber = base.nextSequenceNumber();
    Long parentSnapshotId = parentSnapshot == null ? null : parentSnapshot.snapshotId();

    // ★ 子类在这里做冲突验证！
    // MergeAppend 验证无冲突数据文件
    // BaseRowDelta 验证无冲突删除文件
    validate(base, parentSnapshot);

    // ★ 子类在这里计算新的 manifest 列表
    // 可能复用旧 manifest，也可能合并/重写
    List<ManifestFile> manifests = apply(base, parentSnapshot);

    // 写 manifest-list 文件
    // 文件名格式：snap-{snapshotId}-{attempt}-{uuid}.avro
    OutputFile manifestList = manifestListPath();
    try (ManifestListWriter writer = ManifestLists.write(...)) {
        manifestLists.add(manifestList.location());
        // 并行填充 manifest 元数据
        ManifestFile[] manifestFiles = new ManifestFile[manifests.size()];
        Tasks.range(manifestFiles.length)
            .executeWith(workerPool)
            .run(index -> manifestFiles[index] =
                manifestsWithMetadata.get(manifests.get(index)));
        writer.addAll(Arrays.asList(manifestFiles));
    }

    // 构建 BaseSnapshot 对象
    return new BaseSnapshot(
        sequenceNumber,
        snapshotId(),
        parentSnapshotId,
        System.currentTimeMillis(),
        operation(),           // "append" / "overwrite" / "delete" / "replace"
        summary(base),         // 统计信息
        base.currentSchemaId(),
        manifestList.location());
}
```

**关键洞察**：`apply()` 的第一行是 `refresh()`。这意味着**每次重试都会重新读取最新的元数据**。上一次 attempt 生成的 manifest 文件不会白费（因为数据没变，文件还在磁盘上），但会基于最新的 base 重新计算需要包含哪些 manifest。

---

## 四、HadoopCatalog 的 CAS：atomic rename

```java
// HadoopTableOperations.java Line 130-171
@Override
public void commit(TableMetadata base, TableMetadata metadata) {
    Pair<Integer, TableMetadata> current = versionAndMetadata();

    // ★★★ CAS 检查第一步：版本比对 ★★★
    if (base != current.second()) {
        // base（我开始计算时读到的元数据）≠ current（现在磁盘上的元数据）
        // 说明有人在我计算期间提交了新版本
        throw new CommitFailedException(
            "Cannot commit changes based on stale table metadata");
        // → 这个异常会被 SnapshotProducer.commit() 的 retry 机制捕获
        // → 触发重试：refresh() → 重新 apply() → 重新 commit()
    }

    // 没有变化就不提交
    if (base == metadata) {
        LOG.info("Nothing to commit.");
        return;
    }

    // 写临时元数据文件（随机 UUID 名字）
    Path tempMetadataFile = metadataPath(UUID.randomUUID() + fileExtension);
    TableMetadataParser.write(metadata, io().newOutputFile(tempMetadataFile.toString()));

    // 计算下一个版本号
    int nextVersion = (current.first() != null ? current.first() : 0) + 1;
    Path finalMetadataFile = metadataFilePath(nextVersion, codec);
    // 最终文件名：v{version}.metadata.json
    // 例如：v6.metadata.json

    // ★★★ CAS 检查第二步：atomic rename ★★★
    // 如果 v6.metadata.json 已经存在（被别人抢先创建了）→ rename 失败
    // HDFS 的 rename 是原子的：要么成功，要么失败
    renameToFinal(fs, tempMetadataFile, finalMetadataFile, nextVersion);
    // 内部：fs.rename(temp, final)
    // 如果 final 已存在 → rename 返回 false → 抛 CommitFailedException

    // 更新 version hint 文件（最佳努力，不保证原子）
    writeVersionHint(nextVersion);
}
```

**关键洞察**：HadoopCatalog 的 CAS 分两层：
1. **内存级 CAS**：`base != current.second()` — 快速检查
2. **文件系统级 CAS**：`rename(temp, v6.metadata.json)` — 如果已有 v6 就失败

这就是为什么 HadoopCatalog 要求底层文件系统支持 **atomic rename**。HDFS 天然支持，但 S3 不支持（S3 的 rename 不是原子的），所以 S3 场景不能用 HadoopCatalog。

---

## 五、重试时发生了什么？

让我们走一遍完整的并发场景：

```
时刻  Job A                         Job B
─────────────────────────────────────────────────────────
T=0   读 v5.metadata.json           读 v5.metadata.json
      base_A = v5                   base_B = v5

T=1   计算 apply()                  计算 apply()
      生成 manifest + data files    生成 manifest + data files
      生成 snap-xxx-1-uuid.avro     生成 snap-yyy-1-uuid.avro

T=2   commit(v5, v6_A)             
      CAS 检查: v5 == current ✓
      rename(temp → v6.metadata.json) ✓
      commit 成功！表变成 v6

T=3                                 commit(v5, v6_B)
                                    CAS 检查: v5 ≠ current (已是v6) ✗
                                    → CommitFailedException!

T=4                                 ── 第 1 次重试 ──
                                    refresh() → 读到 v6
                                    base_B = v6
                                    apply(): 基于 v6 重新计算
                                    生成新的 snap-yyy-2-uuid.avro
                                    commit(v6, v7_B)
                                    CAS 检查: v6 == current ✓
                                    rename(temp → v7.metadata.json) ✓
                                    commit 成功！表变成 v7

最终结果：
  v5 → v6 (Job A 的数据) → v7 (Job B 的数据)
  两份数据都不丢！
```

---

## 六、重试参数详解

```java
// TableProperties.java 中的默认值
COMMIT_NUM_RETRIES_DEFAULT = 4;           // 最多重试 4 次
COMMIT_MIN_RETRY_WAIT_MS_DEFAULT = 100;   // 首次重试等 100ms
COMMIT_MAX_RETRY_WAIT_MS_DEFAULT = 60000; // 最大等 60 秒
COMMIT_TOTAL_RETRY_TIME_MS_DEFAULT = 1800000; // 总计最多等 30 分钟
```

退避策略是**指数退避 (exponential backoff)**，因子 2.0：

```
第 1 次重试: 等 100ms
第 2 次重试: 等 200ms
第 3 次重试: 等 400ms
第 4 次重试: 等 800ms (上限 60s)
```

**生产调优建议**：

```sql
-- 高并发场景（数百个 Spark Job 写同一张表）
ALTER TABLE t SET TBLPROPERTIES (
    'commit.retry.num-retries' = '10',         -- 增加重试次数
    'commit.retry.min-wait-ms' = '50',         -- 缩短首次等待
    'commit.retry.max-wait-ms' = '30000',      -- 缩短最大等待
    'commit.retry.total-timeout-ms' = '3600000' -- 延长总超时
);
```

---

## 七、三种不可重试的异常

```java
// SnapshotProducer.java Line 399
.onlyRetryOn(CommitFailedException.class)
```

只有 `CommitFailedException` 会重试。其他异常行为：

| 异常 | 含义 | 行为 |
|------|------|------|
| `CommitFailedException` | CAS 失败（并发冲突） | **重试**，刷新 base 后重新 apply |
| `CommitStateUnknownException` | 提交结果未知（网络超时等） | **不重试不清理**，因为不知道是否已提交 |
| `CleanableFailure` | 可安全清理的失败 | **清理** manifest，然后上抛 |
| 其他 `RuntimeException` | 非预期错误 | strictCleanup 模式决定是否清理 |

`CommitStateUnknownException` 是最危险的。如果贸然清理 → 可能删掉已提交的 manifest → 数据丢失。如果不清理 → 可能留下垃圾文件。Iceberg 选择**安全第一：不清理，让上层处理**。

---

## 八、清理机制 — commit 成功后

```java
// SnapshotProducer.java Line 443-458（commit 成功后的清理）
Snapshot committedSnapshot = stagedSnapshot.get();

// 1. 清理未提交的 manifest
if (cleanupAfterCommit()) {
    cleanUncommitted(Sets.newHashSet(committedSnapshot.allManifests(ops.io())));
    // 把"已提交的 manifest"传进去，让子类删除"未提交的 manifest"
    // 比如重试 3 次才成功，前 2 次 apply() 生成的 manifest 就是垃圾
}

// 2. 清理多余的 manifest-list
// 每次 apply() 都会生成一个 manifest-list（snap-xxx-{attempt}-uuid.avro）
// 但只有最后一个被提交了，其他的都是垃圾
for (String manifestList : manifestLists) {
    if (!committedSnapshot.manifestListLocation().equals(manifestList)) {
        deleteFile(manifestList);  // 删除未提交的 manifest-list
    }
}
```

**manifest-list 文件名的秘密**：

```java
// Line 511-522
protected OutputFile manifestListPath() {
    return ops.io().newOutputFile(
        ops.metadataFileLocation(
            FileFormat.AVRO.addExtension(
                String.format("snap-%d-%d-%s",
                    snapshotId(),
                    attempt.incrementAndGet(), // ← attempt 递增！
                    commitUUID))));
}
// 生成文件名: snap-12345-1-uuid.avro (第 1 次)
//            snap-12345-2-uuid.avro (第 2 次重试)
//            snap-12345-3-uuid.avro (第 3 次重试)
// 只有最后成功的那个被写入 metadata.json
```

---

## 九、设计洞察总结

读完这 100 行代码，我总结出 Iceberg OCC 的 **五个设计精髓**：

| # | 设计 | 为什么 |
|---|------|--------|
| 1 | **CAS 在 Catalog 层**，不在 Iceberg 层 | 不同 Catalog 有不同的原子性保证机制，Iceberg 只定义接口 |
| 2 | **每次重试都 refresh()** | 保证拿到最新 base，避免无意义的重复冲突 |
| 3 | **CommitStateUnknown 不清理** | 安全第一：宁可留垃圾文件，不可删除已提交的数据 |
| 4 | **指数退避** | 避免重试风暴，在高并发下优雅退让 |
| 5 | **数据文件先写、元数据后提交** | 数据文件是幂等的（重复写无害），元数据才需要原子性 |

最后一点最深刻：Iceberg 的数据文件写入**不需要任何并发控制**。因为文件名是 UUID，不可能冲突。并发控制只发生在**提交元数据的那一瞬间** — 就是 `taskOps.commit(base, updated)` 这一行。

这就是 Iceberg 能在没有分布式锁的情况下支撑数百个并发 writer 的根本原因。
