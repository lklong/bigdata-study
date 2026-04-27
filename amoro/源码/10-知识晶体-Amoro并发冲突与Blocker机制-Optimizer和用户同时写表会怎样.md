# [知识晶体] Amoro 并发冲突与 Blocker 机制 — Optimizer 和用户同时写表会怎样？

> 法则4（对抗性阅读）+ 法则1（逆向工程思维）
> 基于 `OptimizingQueue.java` / `TableRuntime.java` / `DefaultTableManager.java` / `SnapshotProducer.java` 真实源码
> Eric | 2026-04-27

---

## 问题/场景

```
生产环境真实故障：
  1. Amoro Optimizer 正在对 orders 表执行 Major Optimize（合并 200 个小文件）
  2. 与此同时，用户执行了 ALTER TABLE orders DROP PARTITION dt='2026-04-20'
  3. 结果：
     - Optimizer 的 commit 失败了（CommitFailedException）
     - 但 Optimizer 已经写了 5 个 128MB 的新文件到 HDFS
     - 这些文件变成了孤立文件（orphan files）
     - 更糟糕的是，Optimizer 又重试了，又生成了 5 个新文件...

问题：
  1. Amoro 的 Blocker 机制为什么没有阻止这个冲突？
  2. Iceberg 的 OCC 重试在这种场景下是否有效？
  3. 孤立文件怎么产生的？怎么清理？
```

---

## 核心源码

### 第一层：Amoro 的 Blocker 防线

Amoro 设计了 `TableBlocker` 机制来防止并发操作冲突。看它怎么工作的：

```java
// DefaultTableManager.java Line 132-178（blocker 创建逻辑）
public Blocker block(
    TableIdentifier tableIdentifier,
    List<BlockableOperation> operations,
    Map<String, String> properties) {

    int tryCount = 0;
    while (tryCount++ < TABLE_BLOCKER_RETRY) {
        long now = System.currentTimeMillis();

        // 1. 清理过期的 blocker
        doAs(TableBlockerMapper.class,
            mapper -> mapper.deleteExpiredBlockers(catalog, database, table, now));

        // 2. 查询当前活跃的 blocker
        List<TableBlocker> tableBlockers = getAs(TableBlockerMapper.class,
            mapper -> mapper.selectBlockers(catalog, database, table, now));

        // ★ 3. 冲突检测
        if (TableBlocker.conflict(operations, tableBlockers)) {
            throw new BlockerConflictException(
                operations + " is conflict with " + tableBlockers);
        }

        // 4. 尝试创建新 blocker（CAS 插入）
        TableBlocker tableBlocker = TableBlocker.buildTableBlocker(
            tableIdentifier, operations, properties, now, blockerTimeout, prevBlockerId);
        doAs(TableBlockerMapper.class, mapper -> mapper.insert(tableBlocker));
        if (tableBlocker.getBlockerId() > 0) {
            return tableBlocker.buildBlocker();  // 成功！
        }
    }

    throw new BlockerConflictException("Failed to create a blocker: conflict meet max retry");
}
```

### 对抗性问题 1："Blocker 保护的范围是什么？"

```java
// BlockableOperation 枚举
public enum BlockableOperation {
    OPTIMIZE,           // Amoro 优化
    BATCH_WRITE,        // 批量写入
    // ... 其他操作
}
```

**关键发现**：Blocker 只保护 **Amoro 内部的操作**。用户通过 Spark SQL 直接对表执行 DDL/DML 时，**完全不经过 Amoro 的 Blocker 机制**！

```
Amoro Optimizer 执行优化 → 会先获取 OPTIMIZE blocker → OK
用户 Spark SQL DROP PARTITION → 直接调 Iceberg API → 不经过 Amoro → 没有 blocker 检查！

★ 这就是故障的根因：Blocker 是 Amoro 的应用层保护，不是 Iceberg 层的保护。
★ 外部写入者（Spark/Flink 直接操作 Iceberg 表）完全绕过了这层防线。
```

### 第二层：Iceberg OCC 是最后的防线

当 Optimizer 写完新文件要提交时，走的是 Iceberg 的 `table.newRewrite().commit()`，最终到 `SnapshotProducer.commit()`：

```java
// SnapshotProducer.java Line 392-430（回顾 OCC commit）
Tasks.foreach(ops)
    .retry(4)
    .exponentialBackoff(100, 60000, 1800000, 2.0)
    .onlyRetryOn(CommitFailedException.class)
    .run(taskOps -> {
        Snapshot newSnapshot = apply();  // ← 每次重试都 refresh + 重新计算

        // ...构建新 metadata...

        taskOps.commit(base, updated.withUUID());
        // ★ 如果 base 过时（被 DROP PARTITION 改了）→ CommitFailedException
        // ★ 然后重试：refresh() → 基于新 base 重新 apply()
    });
```

### 对抗性问题 2："OCC 重试时，RewriteFiles.apply() 会怎样？"

重点看 `MergingSnapshotProducer`（RewriteFiles 的父类）在 apply 时的 validate 逻辑：

```
Optimizer 的 RewriteFiles 操作：
  deleteFile(old_file_1)  // 标记删除旧文件
  deleteFile(old_file_2)
  ...
  addFile(new_file_1)     // 添加新文件
  addFile(new_file_2)

如果在 Optimizer 执行期间，用户 DROP PARTITION 已经删除了 old_file_1：

  重试时 refresh() → 发现 old_file_1 已经不存在了
  → validate() 检查：要删除的文件必须存在
  → 抛出 ValidationException("Cannot delete file that does not exist")
  → 这个异常 NOT 是 CommitFailedException
  → 不会重试！直接失败！
```

**关键发现**：**OCC 重试只对 CAS 冲突（CommitFailedException）有效。如果是数据文件已被删除（ValidationException），重试无意义，直接失败。**

### 第三层：孤立文件产生的时刻

```
时间线：
  T=0  Optimizer 开始执行 RewriteFiles
       读取 200 个旧文件 → 合并 → 写出 5 个新文件到 HDFS
       (new_file_1.parquet ~ new_file_5.parquet 已经在磁盘上了)

  T=1  用户执行 DROP PARTITION，删除了一些旧文件的引用
       Iceberg commit 成功，表 metadata 更新

  T=2  Optimizer 尝试 commit
       refresh() → 发现 base 变了
       validate() → old_file_1 不存在了 → ValidationException → 失败

  T=3  SnapshotProducer 异常处理：
       cleanAll() → 清理 manifest-list 和 manifest
       但 ★不会清理数据文件★！
       因为 new_file_1~5.parquet 是 Optimizer 自己写的，
       Iceberg 的 cleanUncommitted 只清理 manifest，不清理 data files

  结果：5 个 128MB 的新数据文件变成孤立文件，占 640MB 磁盘空间
```

### 对抗性问题 3："谁负责清理这些孤立数据文件？"

答案在 Amoro 的 `IcebergTableMaintainer.cleanOrphanFiles()` 和 Iceberg 的 `DeleteOrphanFilesSparkAction`：

```
1. Amoro 自动清理（OrphanFilesCleaningExecutor）：
   默认每天执行一次，清理 3 天前的孤立文件
   → 这 5 个文件要等 3 天后才会被清理

2. 手动清理：
   CALL catalog.system.remove_orphan_files(
       table => 'db.orders',
       older_than => TIMESTAMP '...'
   );
```

---

## 调用链

```
并发冲突的完整调用链：

Optimizer 线程:                        用户 Spark SQL:
─────────────                          ─────────────
OptimizingQueue.pollTask()
  → plan: 选中 orders 表               
  → tableRuntime.beginPlanning()
  → PENDING → PLANNING

OptimizingPlanner.plan()
  → 生成 RewriteFiles 任务
  → beginProcess()
  → PLANNING → MINOR_OPTIMIZING

OptimizerExecutor.execute()
  → IcebergRewriteExecutor
    → 读取 200 个旧文件
    → 合并写出 5 个新文件              用户: ALTER TABLE DROP PARTITION
                                        → Iceberg commit → 表 metadata 更新
                                        → 旧文件引用被移除

OptimizerExecutor → 上报结果 SUCCESS
  → 所有任务完成
  → beginCommitting()
  → MINOR_OPTIMIZING → COMMITTING

OptimizingProcess.commit()
  → table.newRewrite()
    .deleteFile(旧文件)                 ← 旧文件已不存在！
    .addFile(新文件)
    .commit()
      → SnapshotProducer.commit()
        → apply() → validate()
          → ValidationException!
        → cleanAll() → 清理 manifest（但不清理 data files）
        → 异常上抛

  → commit 失败
  → COMMITTING → PENDING（回到等待队列）
  → 5 个新数据文件成为孤立文件
  → 等待 OrphanFilesCleaningExecutor 3 天后清理
```

---

## 设计意图

Amoro 的 Blocker 是**应用层的"协商锁"**，不是强制锁。设计理念：

| 层级 | 机制 | 强度 | 覆盖范围 |
|------|------|------|---------|
| **Amoro Blocker** | 协商锁 | 弱 | 仅限 Amoro 管理的操作 |
| **Iceberg OCC** | CAS | 中 | 所有通过 Iceberg API 的操作 |
| **文件系统** | atomic rename | 强 | metadata.json 原子更新 |

**为什么 Blocker 不做成强制锁？**

```
1. 外部引擎（Spark/Flink）直接通过 Iceberg API 操作表，不经过 Amoro
   → Amoro 无法拦截
2. 即使能拦截，强制锁会严重影响写入吞吐
   → Iceberg 的 OCC 设计就是为了避免锁
3. Amoro 的定位是"管理系统"而非"存储引擎"
   → 只管自己的操作，不干预用户操作
```

---

## 关键参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `blocker.timeout` | `60000`（1分钟） | Blocker 自动过期时间 |
| `TABLE_BLOCKER_RETRY` | `3` | 创建 Blocker 的最大重试次数 |
| `clean-orphan-files.delay` | `259200000`（3天） | 孤立文件安全清理延迟 |
| `commit.retry.num-retries` | `4` | Iceberg OCC 重试次数 |

---

## 关联知识

- **上游**：用户 DDL/DML 通过 Spark/Flink 直接操作 Iceberg 表，不经过 Amoro
- **下游**：孤立文件由 `OrphanFilesCleaningExecutor` → `IcebergTableMaintainer.cleanOrphanFiles()` 清理
- **同构**：数据库的 MVCC vs 悲观锁。Iceberg 选择了类似 MVCC 的 OCC 路线，Amoro 的 Blocker 类似 Advisory Lock（建议锁）

---

## 踩坑记录

### 踩坑 1：Optimizer commit 失败后孤立文件堆积

```
现象：HDFS 使用量缓慢增长，但表数据量没变
原因：每次 Optimizer commit 冲突 → 产生孤立数据文件 → 等待 3 天才清理
诊断：
  hdfs dfs -ls /warehouse/db/orders/data/ | wc -l  # 实际文件数
  SELECT count(*) FROM orders.files WHERE content=0   # 元数据引用的文件数
  如果实际文件数 >> 元数据文件数 → 孤立文件堆积
解决：
  1. 手动执行 remove_orphan_files
  2. 缩短 clean-orphan-files.delay（风险：可能误删正在写入的文件）
  3. 避免在 Optimizer 运行时做 DDL
```

### 踩坑 2：Blocker 过期导致并发冲突

```
现象：Optimizer 执行了很久（> 60 秒），其他操作已经获取了新 Blocker
原因：Blocker 默认 60 秒过期，但大表优化可能需要 5-10 分钟
      Blocker 过期后，其他 Amoro 操作认为表"没人用"，也开始操作
诊断：AMS 日志中出现 "BlockerConflictException"
解决：
  增大 blocker.timeout（如 300000 = 5分钟）
  或拆分大任务为小任务（减小 max-file-count）
```

### 踩坑 3：AMS 重启时 COMMITTING 状态的表

```
现象：AMS 重启后，某些表一直卡在 COMMITTING 状态
原因：重启时不知道 commit 是否已经成功执行了
      如果贸然重新 commit → 可能双重提交
      如果直接取消 → 可能丢弃已成功的提交
解决（Amoro 的做法）：
  OptimizingQueue.initTableRuntime() Line 125-133：
    if (status == COMMITTING) {
        process.close();  // ★ 安全选择：关闭进程，不重试
    }
  这和 Iceberg 的 CommitStateUnknownException 处理思路一致：
  不确定就不动，让外部（OrphanFileCleaning）来兜底清理
```

---

## 认知更新记录

```
更新前的认知：
  "Amoro 有 Blocker 机制保护并发安全，Optimizer 不会和用户操作冲突"

更新后的认知：
  1. Blocker 只是"协商锁"，不是强制锁 — 外部 Spark/Flink 完全绕过
  2. 真正的并发安全由 Iceberg OCC（CAS commit）保证
  3. OCC 重试只对 CommitFailedException 有效 — ValidationException 直接失败
  4. 冲突失败后的孤立数据文件是存储泄漏的根因 — 需要 3 天才清理
  5. AMS 重启时 COMMITTING 状态的处理策略：安全放弃，而非冒险重试
  6. Blocker 过期时间需要根据实际优化耗时调整，默认 60s 对大表不够

三层防线模型（从强到弱）：
  L1 文件系统 atomic rename → 保证 metadata.json 原子更新
  L2 Iceberg OCC CAS → 保证 snapshot 级别的并发安全
  L3 Amoro Blocker → 仅保证 Amoro 管理的操作间不冲突
  
  生产事故大多发生在 L3 被绕过的场景。
```
