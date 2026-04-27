# S12 - Hive ACID Compaction 源码深度分析

> **知识晶体化模板** | 基于 Hive 3.x 源码 | 作者: Eric (豹纹) for 大哥

---

## 一、问题/场景

Hive ACID 表使用 delta 文件存储增量数据，随着 INSERT/UPDATE/DELETE 操作的积累，delta 文件数量不断增长，导致：

1. **读性能下降**：查询需要合并大量 delta 文件，ORC Reader 开销大增
2. **小文件泛滥**：HDFS NameNode 压力增大
3. **Aborted 事务残留**：UPDATE/DELETE 产生的废弃 delta 占用空间
4. **Compaction 卡死**：Worker 线程挂起，队列堆积

**核心源码目录**: `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/`

---

## 二、ACID 文件布局基础

### 2.1 文件目录命名规则

```java
// AcidUtils.java:97-105
public static final String BASE_PREFIX = "base_";    // base_0000001
public static final String DELTA_PREFIX = "delta_";   // delta_0000001_0000005
public static final String DELETE_DELTA_PREFIX = "delete_delta_";  // delete_delta_0000003_0000003
```

文件目录布局示例：
```
/warehouse/db/acid_table/
├── base_0000005/           ← Major Compaction 产出 (包含 writeId ≤ 5 的全量数据)
│   ├── bucket_00000
│   └── bucket_00001
├── delta_0000006_0000006/  ← INSERT (writeId=6)
│   └── bucket_00000
├── delta_0000007_0000007/  ← INSERT (writeId=7)
│   └── bucket_00000
├── delta_0000008_0000010/  ← Minor Compaction 产出 (合并 writeId 6-10)
│   └── bucket_00000
└── delete_delta_0000009_0000009/  ← DELETE (writeId=9)
    └── bucket_00000
```

### 2.2 核心文件命名方法

```java
// AcidUtils.java:220-253
public static String deltaSubdir(long min, long max) {
    return DELTA_PREFIX + String.format(DELTA_DIGITS, min) + "_" + String.format(DELTA_DIGITS, max);
}
// 带 statementId (同一事务内多条语句)
public static String deltaSubdir(long min, long max, int statementId) {
    return deltaSubdir(min, max) + "_" + String.format(STATEMENT_DIGITS, statementId);
}
public static String baseDir(long writeId) {
    return BASE_PREFIX + String.format(DELTA_DIGITS, writeId);
}
```

---

## 三、Compaction 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                  Hive Metastore Server                       │
│                                                             │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐         │
│  │  Initiator  │   │  Worker(s)  │   │  Cleaner   │         │
│  │ (检查是否需 │   │ (执行合并)  │   │ (清理旧文件)│         │
│  │  要Compact)  │   │             │   │             │         │
│  └──────┬─────┘   └──────┬─────┘   └──────┬─────┘         │
│         │                │                │                 │
│         ▼                ▼                ▼                 │
│  ┌─────────────────────────────────────────────────┐       │
│  │           COMPACTION_QUEUE (RDBMS 表)            │       │
│  │                                                   │       │
│  │  状态流转:                                       │       │
│  │  initiated → working → ready_for_cleaning         │       │
│  │      ↓           ↓            ↓                   │       │
│  │   [Initiator]  [Worker]    [Cleaner]             │       │
│  │      写入        取出        清理                 │       │
│  │                  执行MR      旧delta/base         │       │
│  └─────────────────────────────────────────────────┘       │
│                                                             │
│  CompactorThread (基类): 提供 resolveTable/Partition/SD    │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 Compaction 三阶段状态流转

```
┌──────────┐   Initiator    ┌──────────┐   Worker     ┌────────────────┐
│          │  requestCompact │          │  markCompacted│                │
│ (无记录) │ ──────────────▶│ initiated│ ────────────▶│ready_for_cleaning│
│          │                 │          │               │                │
└──────────┘                 └──────────┘               └───────┬────────┘
                                  │                             │
                                  │  Worker.findNextToCompact   │ Cleaner.clean()
                                  │  ──────────▶ working        │ markCleaned()
                                  │                             ▼
                                  │                     ┌───────────────┐
                                  │                     │   succeeded   │
                                  │                     │ (历史记录)     │
                                  │                     └───────────────┘
                                  │ 失败时:
                                  ▼
                            ┌──────────┐
                            │  failed  │
                            └──────────┘
```

---

## 四、核心源码分析

### 4.1 CompactorThread — 公共基类

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/CompactorThread.java`

```java
// CompactorThread.java:54-97
abstract class CompactorThread extends Thread implements MetaStoreThread {
    protected HiveConf conf;
    protected TxnStore txnHandler;     // 访问 COMPACTION_QUEUE 等表
    protected RawStore rs;             // 访问 Metastore 元数据
    protected AtomicBoolean stop;      // 优雅停止标志
    
    @Override
    public void init(AtomicBoolean stop, AtomicBoolean looped) throws MetaException {
        this.stop = stop;
        setPriority(MIN_PRIORITY);     // 最低线程优先级
        setDaemon(true);               // 守护线程，进程退出时不等待
        txnHandler = TxnUtils.getTxnStore(conf);
        rs = RawStoreProxy.getProxy(conf, ...);
    }
}
```

**设计意图**: 所有 Compactor 线程共享：表/分区解析、用户权限确定（`findUserToRunAs`，基于 HDFS 目录 owner）。

---

### 4.2 Initiator — 判断是否需要 Compaction

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Initiator.java`

> **关键约束**: 整个仓库只能有 1 个 Initiator 实例运行（通过 `MUTEX_KEY.Initiator` 保证）

#### 4.2.1 主循环逻辑

```java
// Initiator.java:70-198 (核心流程)
public void run() {
    recoverFailedCompactions(false);  // 恢复之前失败的 compaction
    int abortedThreshold = HiveConf.getIntVar(conf, HIVE_COMPACTOR_ABORTEDTXN_THRESHOLD);
    
    do {
        handle = txnHandler.getMutexAPI().acquireLock(MUTEX_KEY.Initiator.name());
        
        // 1. 获取当前正在进行的 compaction
        ShowCompactResponse currentCompactions = txnHandler.showCompact(new ShowCompactRequest());
        
        // 2. 查找潜在的 compaction 候选者 (基于 abortedTxn 阈值和 TXN_COMPONENTS)
        Set<CompactionInfo> potentials = txnHandler.findPotentialCompactions(abortedThreshold);
        
        for (CompactionInfo ci : potentials) {
            // 3. 跳过条件检查:
            //    - 表不存在 (可能是临时表或已删除)
            //    - 表设置了 NO_AUTO_COMPACT=true
            //    - 分区表的表级请求 (动态分区场景)
            //    - 已有 initiated/working 状态的同资源 compaction
            //    - 连续失败次数超过阈值
            
            if (noAutoCompactSet(t)) continue;
            if (lookForCurrentCompactions(currentCompactions, ci)) continue;
            if (txnHandler.checkFailedCompactions(ci)) continue;
            
            // 4. 核心判断: 是否需要 compaction，以及 Minor 还是 Major
            CompactionType compactionNeeded = checkForCompaction(ci, tblValidWriteIds, sd, tblProperties, runAs);
            
            if (compactionNeeded != null) {
                requestCompaction(ci, runAs, compactionNeeded);
            }
        }
        
        // 5. 恢复超时的远程 Worker
        recoverFailedCompactions(true);
        
        // 6. 清理空的 aborted 事务
        txnHandler.cleanEmptyAbortedTxns();
        txnHandler.cleanTxnToWriteIdTable();
        
    } while (!stop.get());
}
```

#### 4.2.2 determineCompactionType() — 核心决策逻辑

```java
// Initiator.java:265-345
private CompactionType determineCompactionType(CompactionInfo ci, ValidWriteIdList writeIds,
                                                StorageDescriptor sd, Map<String, String> tblproperties) {
    
    // 1. 获取 ACID 目录状态
    AcidUtils.Directory dir = AcidUtils.getAcidState(location, conf, writeIds, false, false);
    Path base = dir.getBaseDirectory();
    
    // 2. 计算 base 大小 (包括 original 文件)
    long baseSize = 0;
    if (base != null) {
        baseSize = sumDirSize(fs, base);
    }
    for (HdfsFileStatusWithId origStat : dir.getOriginalFiles()) {
        baseSize += origStat.getFileStatus().getLen();
    }
    
    // 3. 计算所有 delta 的总大小
    long deltaSize = 0;
    List<AcidUtils.ParsedDelta> deltas = dir.getCurrentDirectories();
    for (AcidUtils.ParsedDelta delta : deltas) {
        deltaSize += sumDirSize(fs, delta.getPath());
    }
    
    // 4. 判断逻辑:
    
    // 4a. 没有 base 但有 delta → 必须 MAJOR
    if (baseSize == 0 && deltaSize > 0) {
        noBase = true;
    }
    
    // 4b. delta 与 base 的比例超过阈值 → MAJOR
    //     默认阈值: hive.compactor.delta.pct.threshold = 0.1 (10%)
    float deltaPctThreshold = ...; // 默认 0.1
    if ((float)deltaSize / (float)baseSize > deltaPctThreshold) {
        return CompactionType.MAJOR;
    }
    
    // 4c. delta 文件数量超过阈值 → MINOR (有base时) 或 MAJOR (无base时)
    //     默认阈值: hive.compactor.delta.num.threshold = 10
    int deltaNumThreshold = ...; // 默认 10
    if (deltas.size() > deltaNumThreshold) {
        // MM (Micro Managed) 表只做 MAJOR
        if (AcidUtils.isInsertOnlyTable(tblproperties)) return CompactionType.MAJOR;
        return noBase ? CompactionType.MAJOR : CompactionType.MINOR;
    }
    
    return null;  // 不需要 compaction
}
```

**Compaction 类型决策树**:
```
                    tooManyAborts?
                   /            \
                 YES             NO
                  |               |
               MAJOR        有base文件?
                            /        \
                          NO          YES
                          |            |
                     有delta?    deltaSize/baseSize > 10%?
                     /    \         /        \
                   NO     YES     YES         NO
                   |       |       |           |
                 null    MAJOR   MAJOR    delta数量 > 10?
                                          /        \
                                        YES         NO
                                         |           |
                                    无base→MAJOR     null
                                    有base→MINOR
```

#### 4.2.3 特殊触发: tooManyAborts

```java
// Initiator.java:237-241
if (ci.tooManyAborts) {
    LOG.debug("Found too many aborted transactions for " + ci.getFullPartitionName() + 
              ", initiating major compaction");
    return CompactionType.MAJOR;
}
```

当 aborted 事务数超过 `hive.compactor.abortedtxn.threshold`（默认 1000）时，强制触发 MAJOR Compaction，清理废弃的 delta 文件。

---

### 4.3 Worker — 执行 Compaction

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Worker.java`

#### 4.3.1 主循环

```java
// Worker.java:80-200 (核心流程)
public void run() {
    do {
        // 1. 从队列中获取下一个 compaction 任务 (状态从 initiated → working)
        final CompactionInfo ci = txnHandler.findNextToCompact(name);
        
        if (ci == null) {
            Thread.sleep(5000);  // 无任务则休眠 5秒
            continue;
        }
        
        // 2. 解析表/分区信息
        Table t = resolveTable(ci);
        Partition p = resolvePartition(ci);
        StorageDescriptor sd = resolveStorageDescriptor(t, p);
        
        // 3. 检查不支持的场景: 排序表
        if (sd.getSortCols() != null && !sd.getSortCols().isEmpty()) {
            LOG.error("Attempt to compact sorted table, which is not yet supported!");
            txnHandler.markCleaned(ci);
            continue;
        }
        
        // 4. 获取有效 writeId 列表 (决定读取哪些 delta)
        final boolean isMajor = ci.isMajorCompaction();
        ValidWriteIdList tblValidWriteIds = TxnUtils.createValidCompactWriteIdList(...);
        txnHandler.setCompactionHighestWriteId(ci, tblValidWriteIds.getHighWatermark());
        
        // 5. 确定执行用户 (基于 HDFS 目录 owner)
        String runAs = findUserToRunAs(sd.getLocation(), t);
        
        // 6. 执行 MR/Tez 作业进行实际的文件合并
        CompactorMR mr = new CompactorMR();
        mr.run(conf, jobName, t, p, sd, tblValidWriteIds, ci, su, txnHandler);
        
        // 7. 标记完成 (状态: working → ready_for_cleaning)
        txnHandler.markCompacted(ci);
        
    } while (!stop.get());
}
```

#### 4.3.2 Minor vs Major Compaction 的区别

| 特性 | Minor Compaction | Major Compaction |
|------|-----------------|-----------------|
| 输入 | 多个 delta → 1个合并delta | base + 所有 delta → 新 base |
| 输出 | `delta_<min>_<max>` | `base_<writeId>` |
| DELETE 处理 | 保留 delete_delta | 合并应用删除 |
| 空间回收 | 不回收（delete 仍保留） | 完全回收 |
| 性能影响 | 较轻 | 较重（需读写全部数据） |
| 触发条件 | delta 数量超阈值 | delta/base 比率超阈值 或 无 base |

**CompactorMR 核心逻辑** (简化):

```
Minor Compaction:
  输入: delta_0000001_0000001, delta_0000002_0000002, delta_0000003_0000003
  操作: 将多个 delta 合并为一个
  输出: delta_0000001_0000003

Major Compaction:
  输入: base_0000000 + delta_0000001_0000001 + delete_delta_0000002_0000002
  操作: 读取 base，应用所有 delta 和 delete，生成新 base
  输出: base_0000003
```

---

### 4.4 Cleaner — 清理过期文件

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Cleaner.java`

#### 4.4.1 清理前的安全检查

Cleaner 最重要的职责是**确保不会删除正在被读取的文件**。它通过跟踪锁来实现：

```java
// Cleaner.java:81-212 (核心流程)
public void run() {
    do {
        handle = txnHandler.getMutexAPI().acquireLock(MUTEX_KEY.Cleaner.name());
        
        // 1. 获取所有 "ready for cleaning" 状态的 compaction
        List<CompactionInfo> toClean = txnHandler.findReadyToClean();
        
        // 2. 获取当前所有活跃锁
        ShowLocksResponse locksResponse = txnHandler.showLocks(new ShowLocksRequest());
        
        // 3. 对每个待清理的 compaction，记录相关锁
        for (CompactionInfo ci : toClean) {
            if (!compactId2LockMap.containsKey(ci.id)) {
                // 找到所有锁住同一 db/table/partition 的锁
                compactId2LockMap.put(ci.id, findRelatedLocks(ci, locksResponse));
                compactId2CompactInfoMap.put(ci.id, ci);
            }
        }
        
        // 4. 检查每个待清理项的锁是否已全部释放
        Set<Long> currentLocks = buildCurrentLockSet(locksResponse);
        for (Map.Entry<Long, Set<Long>> queueEntry : compactId2LockMap.entrySet()) {
            boolean sawLock = false;
            for (Long lockId : queueEntry.getValue()) {
                if (currentLocks.contains(lockId)) {
                    sawLock = true;  // 仍有锁持有
                    break;
                }
            }
            
            if (!sawLock) {
                // 所有锁已释放，安全删除
                clean(compactId2CompactInfoMap.get(queueEntry.getKey()));
            } else {
                LOG.info("Skipping cleaning due to reader present: " + queueEntry.getValue());
            }
        }
    } while (!stop.get());
}
```

**设计思想**: Cleaner 在第一次看到一个待清理项时，记录当时所有相关的锁 ID。之后每次检查这些锁是否都已经消失。这样做的好处是：**后来的新读者不会阻塞清理**（因为新读者一定读取的是 compaction 后的新文件）。

#### 4.4.2 clean() 与 removeFiles()

```java
// Cleaner.java:249-361 (关键逻辑)
private void clean(CompactionInfo ci) throws MetaException {
    // 1. highestWriteId 保护: 防止删除活跃读者正在读取的文件
    final ValidWriteIdList validWriteIdList = (ci.highestWriteId > 0)
        ? new ValidReaderWriteIdList(ci.getFullTableName(), new long[0], new BitSet(), ci.highestWriteId)
        : new ValidReaderWriteIdList();
    
    // 2. 删除过期文件
    removeFiles(location, validWriteIdList, ci);
    
    // 3. 标记清理完成
    txnHandler.markCleaned(ci);
}

private void removeFiles(String location, ValidWriteIdList writeIdList, CompactionInfo ci) {
    // 使用 AcidUtils.getAcidState() 确定哪些目录是过期的
    AcidUtils.Directory dir = AcidUtils.getAcidState(locPath, conf, writeIdList);
    List<FileStatus> obsoleteDirs = dir.getObsolete();
    
    // 删除所有过期目录
    for (Path dead : filesToDelete) {
        LOG.debug("Going to delete path " + dead.toString());
        if (ReplChangeManager.isSourceOfReplication(db)) {
            replChangeManager.recycle(dead, ReplChangeManager.RecycleType.MOVE, true);
        }
        fs.delete(dead, true);
    }
}
```

**highestWriteId 保护机制**:
- Worker 在开始 compaction 前记录当前最高的已提交 writeId
- Cleaner 在清理时使用这个 writeId 作为上限，防止误删后续写入的 delta

---

## 五、调用链总结 — 一次完整的 Compaction 生命周期

```
                                  时间线
    ─────────────────────────────────────────────────────▶
    
    Phase 1: Initiator 检测
    ┌──────────────────────────────────────────────┐
    │ Initiator.run()                               │
    │  ├─ txnHandler.findPotentialCompactions()     │
    │  │   └─ 扫描 TXN_COMPONENTS 找到有数据变更的表 │
    │  ├─ lookForCurrentCompactions()               │
    │  │   └─ 排除已有 initiated/working 的资源     │
    │  ├─ determineCompactionType()                 │
    │  │   ├─ AcidUtils.getAcidState() 获取文件状态 │
    │  │   ├─ 计算 base/delta 大小和数量            │
    │  │   └─ 返回 MAJOR / MINOR / null             │
    │  └─ requestCompaction()                       │
    │      └─ txnHandler.compact() → 写入队列       │
    │         INSERT INTO COMPACTION_QUEUE           │
    │         (cq_state = 'i' initiated)            │
    └──────────────────────────────────────────────┘
                         │
                         ▼
    Phase 2: Worker 执行
    ┌──────────────────────────────────────────────┐
    │ Worker.run()                                  │
    │  ├─ txnHandler.findNextToCompact(name)        │
    │  │   └─ UPDATE COMPACTION_QUEUE               │
    │  │      SET cq_state='w', cq_worker_id=name  │
    │  ├─ resolveTable/Partition/SD()               │
    │  ├─ getValidWriteIds()                        │
    │  │   └─ 确定读取范围 (highestWriteId)         │
    │  ├─ CompactorMR.run()                         │
    │  │   ├─ Minor: 合并 deltas → new delta        │
    │  │   └─ Major: base + deltas → new base       │
    │  └─ txnHandler.markCompacted(ci)              │
    │      └─ UPDATE cq_state = 'r'                 │
    │         (ready_for_cleaning)                   │
    └──────────────────────────────────────────────┘
                         │
                         ▼
    Phase 3: Cleaner 清理
    ┌──────────────────────────────────────────────┐
    │ Cleaner.run()                                 │
    │  ├─ txnHandler.findReadyToClean()             │
    │  ├─ findRelatedLocks() 记录当前活跃锁        │
    │  ├─ 等待所有相关锁释放...                     │
    │  ├─ clean()                                   │
    │  │   ├─ AcidUtils.getAcidState() 找 obsolete  │
    │  │   ├─ fs.delete(obsolete_dirs)              │
    │  │   └─ txnHandler.markCleaned(ci)            │
    │  │      └─ UPDATE → 移入 COMPLETED_COMPACTIONS│
    │  └─ 完成                                      │
    └──────────────────────────────────────────────┘
```

---

## 六、关键参数与调优建议

### 6.1 Initiator 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.compactor.check.interval` | 300s | Initiator 检查间隔 |
| `hive.compactor.delta.pct.threshold` | 0.1 | delta/base 比例触发 MAJOR 的阈值 |
| `hive.compactor.delta.num.threshold` | 10 | delta 数量触发 MINOR 的阈值 |
| `hive.compactor.abortedtxn.threshold` | 1000 | aborted 事务数触发 MAJOR 的阈值 |
| `hive.compactor.initiator.failed.compactions.threshold` | 2 | 连续失败次数阈值，超过则跳过 |

### 6.2 Worker 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.compactor.worker.threads` | 0 | Worker 线程数（0=不启动） |
| `hive.compactor.worker.timeout` | 86400s | Worker 超时时间 |
| `hive.compactor.job.queue` | (空) | Compaction MR 作业队列名 |

### 6.3 Cleaner 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.compactor.cleaner.run.interval` | 5000ms | Cleaner 检查间隔 |

### 6.4 调优建议

1. **Worker 线程数**: 建议设为 CPU 核数的 1/4 到 1/2，如 `hive.compactor.worker.threads=4`
2. **降低 delta 阈值**: 写入频繁的表可设 `delta.num.threshold=5`，更早触发 MINOR
3. **专用作业队列**: 设置 `hive.compactor.job.queue=compaction`，避免与业务查询争抢资源
4. **NO_AUTO_COMPACT 白名单**: 对不频繁更新的大表设置 `'NO_AUTO_COMPACT'='true'`，手动控制 compaction 时间
5. **监控 COMPACTION_QUEUE**: 定期检查 `SHOW COMPACTIONS`，关注 `initiated` 状态堆积

---

## 七、踩坑记录

### 7.1 Compaction 队列堆积

**现象**: `SHOW COMPACTIONS` 显示大量 `initiated` 状态的任务。

**根因**: Worker 线程数为 0 或过少，无法消费 Initiator 产生的 compaction 请求。

**源码证据** (Worker.java:86-97):
```java
final CompactionInfo ci = txnHandler.findNextToCompact(name);
if (ci == null && !stop.get()) {
    Thread.sleep(SLEEP_TIME);  // 5秒轮询一次
    continue;
}
```

**解决**: 增加 `hive.compactor.worker.threads`。

### 7.2 Cleaner 等待锁释放导致清理延迟

**现象**: `ready_for_cleaning` 状态的任务长时间未被清理。

**根因**: Cleaner 发现有活跃锁在读取相关表/分区，等待这些锁释放后才清理。如果有长时间运行的查询持有读锁，清理会无限期延迟。

**源码证据** (Cleaner.java:154-177):
```java
for (Long lockId : queueEntry.getValue()) {
    if (currentLocks.contains(lockId)) {
        sawLock = true;  // 仍有锁持有，跳过清理
        break;
    }
}
```

**解决**: 优化长查询性能或设置查询超时。Cleaner 的设计保证不会被后来的新读者阻塞。

### 7.3 Minor Compaction 后 delete_delta 未清理

**现象**: 执行了 Minor Compaction 后，`delete_delta_*` 目录仍然存在。

**根因**: Minor Compaction **只合并 delta，不处理 delete_delta**。只有 Major Compaction 才会将 delete 应用到 base 中。

**解决**: 对有大量 DELETE 操作的表，手动触发 `ALTER TABLE t COMPACT 'major'`。

### 7.4 排序表不支持 Compaction

**源码证据** (Worker.java:136-140):
```java
if (sd.getSortCols() != null && !sd.getSortCols().isEmpty()) {
    LOG.error("Attempt to compact sorted table, which is not yet supported!");
    txnHandler.markCleaned(ci);
    continue;
}
```

排序表的 Compaction 需要维持全局排序，当前版本不支持。

---

## 八、总结

Hive ACID Compaction 采用了经典的 **三阶段异步处理** 架构：

1. **Initiator（决策者）**: 基于文件大小比例和数量阈值判断是否需要 Compaction，将请求写入队列
2. **Worker（执行者）**: 从队列取任务，通过 MR/Tez 作业执行实际的文件合并
3. **Cleaner（清洁工）**: 等待所有活跃读者释放锁后，删除过期的 delta/base 文件

**核心设计亮点**:
- 所有三个组件通过 `MUTEX_KEY` 互斥，保证同一时间同一资源只有一个 compaction 在运行
- Cleaner 通过**锁快照**机制，既保证了读取安全，又避免了被新读者无限期阻塞
- `highestWriteId` 作为时间水位线，确保清理不会影响到 compaction 之后的新数据
- `tooManyAborts` 作为安全阀，防止大量 aborted 事务的 delta 文件堆积
