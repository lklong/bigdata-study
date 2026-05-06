# [教案] S07-NameNode元数据持久化EditLog与FsImage源码深度剖析

> 🎯 教学目标：掌握FSImage与EditLog的关系、EditLog双缓冲写入+同步机制、Checkpoint流程 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：会计的账本管理

想象一家大公司的财务部门：
- **总账本**（FsImage）：记录了公司截止到某个时间点的所有资产负债详情，厚厚的一本，每年底盘点一次
- **流水日志**（EditLog）：每天的每一笔收入支出都实时记录在流水日志中
- 年底**盘点**（Checkpoint）：会计把流水日志中所有变动合并到总账本中，生成新的总账本
- 如果公司遭遇灾难（NameNode重启），恢复方法是：**打开最近的总账本 + 从流水日志中回放未合并的变动**

在 HDFS 中：
- **FsImage** = 某一时间点完整的文件系统元数据快照（目录树、权限、Block映射等）
- **EditLog** = 自上次FsImage以来的所有修改操作日志
- **Checkpoint** = 将EditLog合并到FsImage的过程（由StandbyNN或SecondaryNN完成）

**为什么这个机制如此重要？**
> NameNode 的所有元数据都在内存中，一旦重启就全部丢失。FsImage+EditLog 是元数据持久化的唯一保障。EditLog 写入性能直接决定了整个 HDFS 的吞吐量上限。

### 生产故障场景

```
场景：NameNode 启动耗时超过30分钟
现象：NameNode 日志显示 "Loading edits: xxx"，回放了几百万条EditLog
根因：长时间未做Checkpoint，EditLog积累过多
      NN启动时需要加载FsImage + 回放所有EditLog
解法：确保Checkpoint定期执行，理解 dfs.namenode.checkpoint.period 等参数
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| FsImage | 文件系统元数据的完整快照 | 年度总账本 |
| EditLog | 操作日志，记录每一次修改 | 日常流水账 |
| Checkpoint | 将EditLog合并到FsImage | 年底盘点 |
| Transaction ID (txid) | 每条EditLog的唯一递增序号 | 流水号 |
| Double Buffer | 双缓冲机制，写入与刷盘并行 | 两个记事本轮换使用 |
| logSync() | 将缓冲区数据刷写到磁盘 | 将记事本内容誊抄到正式账本 |
| JournalNode | HA模式下存储EditLog的服务 | 远程备份账本的保险柜 |
| StandbyNN | 负责定期执行Checkpoint的备用NameNode | 负责盘点的副会计 |
| SecondaryNN | 非HA模式下执行Checkpoint的节点 | 临时帮忙盘点的实习生 |
| EditLogOp | 一条操作日志（如创建文件、删除文件） | 一笔流水记录 |

### 2.2 架构图

```
┌──────────────────────────────────────────────────────────────────────┐
│                     Active NameNode                                   │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐   │
│  │                     FSNamesystem (内存)                        │   │
│  │  INodeDirectory (根目录)                                       │   │
│  │   ├── /user                                                    │   │
│  │   ├── /data                                                    │   │
│  │   └── ...                                                      │   │
│  └───────────────────────────────────────────────────────────────┘   │
│            │ 每次修改操作                                              │
│            ▼                                                          │
│  ┌───────────────────────────────────────────────────────────────┐   │
│  │                     FSEditLog                                   │   │
│  │                                                                 │   │
│  │  logEdit(op) → beginTransaction() → write(op) → endTransaction │   │
│  │       │                                                         │   │
│  │       ▼ (needsSync?)                                            │   │
│  │  logSync() ─→ 双缓冲交换 ─→ flush到磁盘                        │   │
│  │                                                                 │   │
│  │  ┌──────────────────────────────────────────────────────┐      │   │
│  │  │  EditLogOutputStream (双缓冲)                         │      │   │
│  │  │  ┌──────────┐  ┌──────────┐                          │      │   │
│  │  │  │ Buffer A  │  │ Buffer B  │  ← 一个写入，一个刷盘   │      │   │
│  │  │  │ (writing) │  │ (flushing)│                          │      │   │
│  │  │  └──────────┘  └──────────┘                          │      │   │
│  │  └──────────────────────────────────────────────────────┘      │   │
│  └───────────────────────────────────────────────────────────────┘   │
│            │ 写入                        │ 写入                       │
│            ▼                             ▼                            │
│  ┌──────────────┐              ┌──────────────────┐                  │
│  │ 本地EditLog   │              │ JournalNode集群   │ (HA模式)        │
│  │ edits_xxx-yyy │              │ (QJM)             │                  │
│  └──────────────┘              └──────────────────┘                  │
│                                         │                             │
└─────────────────────────────────────────┼─────────────────────────────┘
                                          │ 读取EditLog
                                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│                   Standby NameNode                                     │
│                                                                       │
│  1. 定期从JournalNode拉取EditLog并回放                                │
│  2. 定期执行Checkpoint:                                               │
│     FsImage(old) + EditLogs → FsImage(new)                           │
│  3. 将新的FsImage传回Active NN                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.3 NameNode 启动恢复流程

```
NameNode 启动
    │
    ▼
加载最新的 FsImage (fsimage_000000000000xxxxx)
    │  ← FSImage.loadFSImage()
    ▼
回放之后的 EditLog (edits_xxxxx-yyyyy, edits_yyyyy-zzzzz...)
    │  ← FSEditLogLoader.loadEditRecords()
    ▼
内存中的文件系统命名空间恢复完成
    │
    ▼
打开新的 EditLog Segment 开始记录
    │  ← FSEditLog.startLogSegment()
    ▼
退出 SafeMode，开始服务
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|---------|------|
| `FSEditLog` | `server/namenode/FSEditLog.java` | EditLog的写入、同步、管理 |
| `FSEditLogOp` | `server/namenode/FSEditLogOp.java` | 各种操作日志的定义 |
| `FSImage` | `server/namenode/FSImage.java` | FsImage的加载、保存、Checkpoint |
| `EditLogOutputStream` | `server/namenode/EditLogOutputStream.java` | 双缓冲输出流基类 |
| `JournalSet` | `server/namenode/JournalSet.java` | 管理多个Journal（本地+远程） |
| `FSImageFormat` | `server/namenode/FSImageFormat.java` | FsImage的序列化/反序列化 |

### 3.2 关键方法逐行解读

#### 3.2.1 logEdit()：写入一条EditLog

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSEditLog.java
// 行号: 450-470

void logEdit(final FSEditLogOp op) {
  boolean needsSync = false;
  synchronized (this) {
    assert isOpenForWrite() : "bad state: " + state;
    
    // 如果有自动同步正在进行，等待完成
    waitIfAutoSyncScheduled();

    // 执行事务：分配txid + 写入缓冲区
    needsSync = doEditTransaction(op);
    if (needsSync) {
      isAutoSyncScheduled = true;  // 标记需要自动同步
    }
  }

  // 同步到磁盘（在 synchronized 块外执行！关键设计！）
  if (needsSync) {
    logSync();
  }
}
```

**教学要点**：
- `logEdit` 分两步：① synchronized 块内写缓冲区 ② synchronized 块外刷盘
- 这样设计使得**写缓冲区和刷盘可以并行**，大幅提升吞吐量
- `isAutoSyncScheduled` 标志防止多个线程同时触发 sync

#### 3.2.2 doEditTransaction()：分配事务ID并写入

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSEditLog.java
// 行号: 472-485

synchronized boolean doEditTransaction(final FSEditLogOp op) {
  long start = beginTransaction();   // 分配 txid
  op.setTransactionId(txid);         // 设置到操作对象

  try {
    editLogStream.write(op);         // 写入双缓冲区
  } catch (IOException ex) {
    // All journals failed, handled in logSync
  } finally {
    op.reset();
  }
  endTransaction(start);             // 记录统计信息
  return shouldForceSync();          // 是否需要强制刷盘
}
```

#### 3.2.3 beginTransaction()：事务ID分配

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSEditLog.java
// 行号: 519-530

private long beginTransaction() {
  assert Thread.holdsLock(this);
  txid++;                    // 全局递增的事务ID

  // 记录当前线程的事务ID（ThreadLocal）
  TransactionId id = myTransactionId.get();
  id.txid = txid;
  return monotonicNow();
}
```

**教学要点**：
- `txid` 是一个全局递增的 long，每次写入操作+1
- 使用 `ThreadLocal<TransactionId>` 记录每个线程的最新 txid
- 后续 `logSync()` 时，线程通过 ThreadLocal 知道自己需要同步到哪个 txid

#### 3.2.4 logSync()：双缓冲同步的核心（最重要的方法！）

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSEditLog.java
// 行号: 611-730

/**
 * The data is double-buffered within each edit log implementation so that
 * in-memory writing can occur in parallel with the on-disk writing.
 *
 * Each sync occurs in three steps:
 *   1. synchronized, it swaps the double buffer and sets isSyncRunning flag
 *   2. unsynchronized, it flushes the data to storage
 *   3. synchronized, it resets the flag and notifies anyone waiting
 */
protected void logSync(long mytxid) {
  long syncStart = 0;
  boolean sync = false;

  EditLogOutputStream logStream = null;
  synchronized (this) {
    // ======== 步骤1: synchronized 区域 ========
    
    // 如果有人正在sync，等待
    while (mytxid > synctxid && isSyncRunning) {
      wait(1000);
    }

    // 如果我的事务已经被别人sync了，直接返回（搭便车！）
    if (mytxid <= synctxid) {
      return;
    }

    // 现在轮到我来sync了
    editsBatchedInSync = txid - synctxid - 1;  // 本次sync打包的额外事务数
    syncStart = txid;
    isSyncRunning = true;
    sync = true;

    // 交换双缓冲区！
    editLogStream.setReadyToFlush();
    
    logStream = editLogStream;
  }
  
  // ======== 步骤2: unsynchronized 区域（关键！不持锁！）========
  long start = monotonicNow();
  logStream.flush();  // 实际的磁盘写入
  long elapsed = monotonicNow() - start;

  // ======== 步骤3: synchronized 区域 ========
  synchronized (this) {
    if (sync) {
      synctxid = syncStart;  // 更新已sync的最大txid
      isSyncRunning = false;
      notifyAll();           // 唤醒等待的线程
    }
  }
}
```

**教学要点**（这是全篇最关键的知识点！）：

1. **双缓冲设计**：Buffer A 接收新写入，Buffer B 正在刷盘。`setReadyToFlush()` 交换两个缓冲区
2. **步骤2不持锁**：刷盘是耗时的 I/O 操作，如果持锁，其他线程无法写入 EditLog，吞吐量会严重下降
3. **搭便车机制**：如果线程 A 正在 sync，线程 B 的写入会被打包在同一批。B 的 `logSync` 发现 `mytxid <= synctxid` 直接返回，无需再次 sync
4. **三步走**：synchronized(交换) → unsynchronized(刷盘) → synchronized(通知)

#### 3.2.5 FSImage.loadFSImage()：NameNode启动时加载

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSImage.java
// 行号: 648-710

private boolean loadFSImage(FSNamesystem target, StartupOption startOpt,
    MetaRecoveryContext recovery) throws IOException {
  
  // 找到最新的FsImage文件
  final FSImageStorageInspector inspector = storage
      .readAndInspectDirs(nnfs, startOpt);
  List<FSImageFile> imageFiles = inspector.getLatestImages();
  
  boolean needToSave = inspector.needToSave();
  
  // 初始化EditLog
  initEditLog(startOpt);
  
  // 选择需要回放的EditLog范围
  long toAtLeastTxId = editLog.isOpenForWrite() ? 
      inspector.getMaxSeenTxId() : 0;
  editStreams = editLog.selectInputStreams(
      imageFiles.get(0).getCheckpointTxId() + 1,  // 从FsImage之后的txid开始
      toAtLeastTxId, recovery, false);
  
  // 加载FsImage
  loadFSImageFile(target, recovery, imageFile, startOpt);
  
  // 回放EditLog
  long loaded = loadEdits(editStreams, target, ...);
  
  needToSave |= needsResaveBasedOnStaleCheckpoint(...);
  return needToSave;
}
```

#### 3.2.6 FSImage.saveFSImage()：保存FsImage快照

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSImage.java
// 行号: 952-964

void saveFSImage(SaveNamespaceContext context, StorageDirectory sd,
    NameNodeFile dstType) throws IOException {
  long txid = context.getTxId();
  File newFile = NNStorage.getStorageFile(sd, NameNodeFile.IMAGE_NEW, txid);
  File dstFile = NNStorage.getStorageFile(sd, dstType, txid);
  
  // 使用Protobuf格式序列化
  FSImageFormatProtobuf.Saver saver = new FSImageFormatProtobuf.Saver(context);
  FSImageCompression compression = FSImageCompression.createCompression(conf);
  saver.save(newFile, compression);  // 保存为 fsimage_txid.tmp
  
  MD5FileUtils.saveMD5File(dstFile, saver.getSavedDigest());  // 保存MD5校验
  storage.setMostRecentCheckpointInfo(txid, Time.now());
}
```

**教学要点**：
- FsImage 使用 Protobuf 格式序列化（早期版本用自定义二进制格式）
- 先写临时文件 `fsimage_xxx.tmp`，完成后重命名为 `fsimage_xxx`（原子性）
- MD5 校验确保文件完整性

### 3.3 调用链时序图

#### 3.3.1 EditLog 写入流程（双缓冲）

```
Thread-1 (create /a)     Thread-2 (mkdir /b)      FSEditLog
     │                        │                       │
     │──logEdit(CreateOp)────→│                       │
     │                        │                       │
     │  synchronized {        │                       │
     │   txid=101             │                       │
     │   write→BufferA        │                       │
     │   needsSync=false      │                       │
     │  }                     │                       │
     │                        │──logEdit(MkdirOp)────→│
     │                        │  synchronized {        │
     │                        │   txid=102             │
     │                        │   write→BufferA        │
     │                        │   needsSync=true(满了) │
     │                        │   isAutoSyncScheduled  │
     │                        │  }                     │
     │                        │                       │
     │                        │──logSync(102)         │
     │                        │  synchronized {        │
     │                        │   swap BufferA↔BufferB │
     │                        │   isSyncRunning=true  │
     │                        │  }                     │
     │                        │  ── flush BufferB ──→  disk  (不持锁！)
     │                        │                       │
     │  (此时Thread-1可以继续写入BufferA!)              │
     │──logEdit(DeleteOp)────→│                       │
     │  synchronized {        │                       │
     │   txid=103             │                       │
     │   write→BufferA(新的)   │                       │
     │  }                     │                       │
     │                        │                       │
     │                        │  synchronized {        │
     │                        │   synctxid=102        │
     │                        │   isSyncRunning=false │
     │                        │   notifyAll()         │
     │                        │  }                     │
```

#### 3.3.2 Checkpoint 流程（StandbyNN）

```
Active NN                  JournalNode              Standby NN
    │                          │                        │
    │──写EditLog──────────────→│                        │
    │                          │                        │
    │                          │←──拉取EditLog──────────│ (EditLogTailer)
    │                          │──返回EditLog──────────→│
    │                          │                        │
    │                          │                        │──回放EditLog到内存
    │                          │                        │
    │                          │            [到达checkpoint周期]
    │                          │                        │
    │                          │                        │──saveNamespace()
    │                          │                        │  FsImage(old)+EditLogs
    │                          │                        │  → FsImage(new)
    │                          │                        │
    │←──────上传新FsImage───────┼────────────────────────│
    │  (HTTP传输)               │                        │
    │                          │                        │
    │──使用新FsImage           │                        │
    │  清理旧EditLog           │                        │
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：NameNode启动缓慢（EditLog回放过多）

```
现象: NN启动耗时30分钟+
日志: "Loading edits: xxxxxxx ops"
原因: Checkpoint长期未执行，EditLog积累了上千万条记录
解法: 
  1. 手动触发 hdfs dfsadmin -saveNamespace
  2. 检查 StandbyNN/SecondaryNN 是否正常
  3. 调小 checkpoint.period
```

#### 场景2：EditLog写入延迟导致客户端超时

```
现象: HDFS客户端操作（create/mkdir）频繁超时
日志: "FSEditLog: logSync took xxx ms"
原因: EditLog刷盘延迟（磁盘I/O瓶颈或JournalNode网络延迟）
解法:
  1. 检查NN磁盘I/O（iostat）
  2. 检查JournalNode延迟
  3. EditLog目录使用SSD
```

#### 场景3：EditLog磁盘空间不足

```
现象: NameNode报错 "No space left on device"
原因: 旧的EditLog文件未被清理（Checkpoint不执行导致）
解法:
  1. 确保Checkpoint正常运行
  2. 检查 dfs.namenode.num.checkpoints.retained
  3. 手动清理过期EditLog
```

### 4.2 排障步骤

```bash
# 查看FsImage和EditLog文件
ls -la $HADOOP_HOME/data/namenode/current/
# 输出示例:
# fsimage_0000000000000123456
# fsimage_0000000000000123456.md5
# edits_0000000000000123457-0000000000000123500
# edits_inprogress_0000000000000123501

# 查看EditLog内容（调试用）
hdfs oev -i edits_xxx-yyy -o edits.xml
cat edits.xml | head -50

# 查看FsImage内容
hdfs oiv -i fsimage_xxx -o fsimage.txt -p Delimited
head -20 fsimage.txt

# 手动触发Checkpoint
hdfs dfsadmin -saveNamespace

# 查看最新事务ID
hdfs dfsadmin -getServiceState nn1
```

### 4.3 关键参数调优

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `dfs.namenode.checkpoint.period` | 3600s (1h) | Checkpoint周期 | 生产建议1小时 |
| `dfs.namenode.checkpoint.txns` | 1000000 | 触发Checkpoint的事务数阈值 | 高负载可增大 |
| `dfs.namenode.num.checkpoints.retained` | 2 | 保留的FsImage数量 | 保持默认 |
| `dfs.namenode.num.extra.edits.retained` | 1000000 | 额外保留的EditLog事务数 | 根据恢复需求调整 |
| `dfs.namenode.edits.dir` | 与image同目录 | EditLog存储目录 | **必须**用独立SSD |
| `dfs.namenode.edit.log.autoroll.multiplier.threshold` | 2.0 | EditLog自动滚动阈值 | 保持默认 |

---

## 五、举一反三

### 5.1 与其他系统的类比（类比迁移法）

| 概念 | HDFS EditLog+FsImage | MySQL | Redis | Kafka |
|------|---------------------|-------|-------|-------|
| 快照 | FsImage | ibdata (表空间) | RDB | N/A |
| 操作日志 | EditLog | binlog/redo log | AOF | Log Segment |
| 刷盘策略 | 双缓冲+批量 | innodb_flush_log_at_trx_commit | appendfsync | flush.messages |
| 合并(Checkpoint) | StandbyNN | N/A (自动) | bgrewriteaof | Log Compaction |
| 恢复 | FsImage+EditLog | ibdata+redo log | RDB+AOF | Log Replay |

### 5.2 面试高频题

**Q1: FsImage 和 EditLog 的关系？**

> FsImage 是某一时间点的完整元数据快照，EditLog 记录了自该时间点以来的所有修改操作。NameNode 启动时，加载最新 FsImage 并回放后续 EditLog，恢复完整的内存状态。Checkpoint 将两者合并生成新的 FsImage。

**Q2: EditLog 的双缓冲机制是如何工作的？**

> EditLog 维护两个内存缓冲区（Buffer A 和 Buffer B）。正常写入时，操作日志写入 Buffer A；当需要刷盘时，两个缓冲区交换——原来的 A 变成刷盘缓冲区，原来的 B 变成写入缓冲区。**关键在于刷盘操作不持锁**，所以其他线程可以继续写入新的缓冲区，实现了写入与刷盘的并行。

**Q3: logSync() 的"搭便车"机制是什么？**

> 当多个线程同时需要 sync 时，只有一个线程实际执行刷盘操作。其他线程发现 `mytxid <= synctxid`（自己的事务已经被别人的 sync 包含了），就直接返回。这样一次 I/O 操作就能同步多个线程的写入，大幅减少磁盘 I/O 次数。

**Q4: 为什么 Checkpoint 由 StandbyNN 执行而不是 Active NN？**

> 生成 FsImage 需要遍历整个内存命名空间并序列化，这是一个**耗时且需要读锁**的操作。如果由 Active NN 执行，会阻塞所有修改操作，严重影响服务可用性。由 StandbyNN 执行则对 Active NN 没有任何影响。

**Q5: EditLog 目录为什么建议独立磁盘？**

> EditLog 的写入在 HDFS 操作的关键路径上（每次 create/delete/rename 都要写 EditLog）。如果与其他 I/O 共享磁盘，会导致写入延迟增大，直接影响客户端操作的响应时间。使用独立 SSD 可以将 EditLog 写入延迟降低到亚毫秒级。

### 5.3 思考题（留给学生）

1. **思考题1**：如果 `logSync()` 的步骤2（flush）也在 synchronized 块内执行，会对性能产生什么影响？尝试量化分析。

2. **思考题2**：如果 Active NN 和所有 JournalNode 同时宕机（极端情况），EditLog 会丢失吗？如何防范？

3. **思考题3**：EditLog 中记录的是"操作"（如 CREATE /a）还是"状态"（如 /a 的完整属性）？这两种方式各有什么优缺点？

4. **思考题4**：Redis 的 AOF 和 HDFS 的 EditLog 在设计上有什么相似之处和不同之处？

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│           NameNode 元数据持久化 EditLog 与 FsImage — 知识晶体                     │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 问题/场景                                                                        │
│   NameNode 内存中的元数据如何持久化？重启后如何恢复？如何保证写入性能？            │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 核心源码                                                                         │
│   FSEditLog.logEdit()    → 写入缓冲区 (synchronized)                             │
│   FSEditLog.logSync()    → 双缓冲交换 + 不持锁刷盘 + 搭便车机制                  │
│   FSImage.loadFSImage()  → 加载FsImage + 回放EditLog                             │
│   FSImage.saveFSImage()  → Protobuf序列化 + MD5校验                              │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 调用链                                                                           │
│   写入: logEdit → beginTransaction(txid++) → write(buffer) → logSync             │
│   logSync 三步: ①sync(swap buffer) → ②unsync(flush disk) → ③sync(notify)        │
│   启动: loadFSImage → loadEdits(replay) → startLogSegment                        │
│   Checkpoint: StandbyNN 拉取EditLog → 回放 → saveNamespace → 上传FsImage         │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 设计意图                                                                         │
│   1. 双缓冲: 写入与刷盘并行，不互相阻塞                                          │
│   2. 搭便车: 一次I/O批量同步多线程的写入                                          │
│   3. Checkpoint外置: Active NN不做Checkpoint，避免影响服务                         │
│   4. txid全局有序: 保证EditLog的回放顺序一致性                                    │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 关键参数                                                                         │
│   Checkpoint周期=1h | Checkpoint事务数=100万 | 保留FsImage=2个                    │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 踩坑记录                                                                         │
│   1. EditLog过多→NN启动慢: 确保Checkpoint定期执行                                │
│   2. EditLog写入慢→客户端超时: EditLog目录用独立SSD                               │
│   3. EditLog磁盘满: 检查Checkpoint是否正常 + 清理旧文件                           │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSEditLog.java` (L450-730)
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSImage.java` (L648-964)
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSEditLogOp.java`

2. **官方文档**
   - [HDFS High Availability Using the Quorum Journal Manager](https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-hdfs/HDFSHighAvailabilityWithQJM.html)
   - [HDFS Architecture Guide](https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-hdfs/HdfsDesign.html)

3. **前置知识**
   - S01-NameNode启动流程与安全模式源码分析
