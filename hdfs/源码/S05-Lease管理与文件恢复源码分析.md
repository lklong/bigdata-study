# S05-Lease 管理与文件恢复源码分析

> **组件版本**: Apache Hadoop 3.x (基于 txProjects/hadoop 源码)
> **源码路径**: `hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/`
> **核心类**: `LeaseManager`、`FSNamesystem.internalReleaseLease()`、`LeaseManager.Monitor`
> **分析日期**: 2026-04-27

---

## 一、问题/场景

### 1.1 核心问题
- HDFS Lease 机制是什么？为什么需要 Lease？
- Soft Lease 和 Hard Lease 的区别是什么？
- Client 崩溃后文件如何恢复（Lease Recovery vs Block Recovery）？
- Lease Recovery 和 NameNode HA 切换如何协同？

### 1.2 典型生产场景
- Spark 作业崩溃后，输出文件处于 "正在写入" 状态无法读取
- `RecoverLease: File is already being created by another client` 错误
- Lease 过期后文件自动关闭，但数据可能不完整
- HA 切换后正在写入的文件需要 Lease Recovery

---

## 二、Lease 机制概述

### 2.1 为什么需要 Lease

HDFS 采用 **单写者模型**（Write-Once-Read-Many），同一时刻只允许一个 Client 写入某个文件。Lease 是 NameNode 授予 Client 的 **写入许可证**：

```
Lease 的核心作用:
  1. 互斥写入: 防止多个 Client 同时写同一个文件
  2. 故障检测: Client 崩溃后通过 Lease 超时检测
  3. 文件恢复: Lease 过期后自动触发文件关闭/恢复
```

### 2.2 Lease 生命周期

```
  Client 创建文件 (create)
    │
    │  NameNode 创建 Lease: holder="DFSClient_xxx", file=INodeID
    ▼
  Client 周期性续约 (renewLease)
    │  每 softLimit/2 续约一次 (默认 30 秒)
    │
    ├── 正常流程: Client 调用 close()
    │   └── NameNode 移除 Lease, 文件标记为 COMPLETE
    │
    ├── Soft Limit 过期 (默认 60 秒):
    │   └── 其他 Client 可以抢占 Lease (recoverLease)
    │
    └── Hard Limit 过期 (默认 60 分钟):
        └── LeaseManager.Monitor 自动触发 Lease Recovery
```

---

## 三、核心数据结构

### 3.1 LeaseManager 类结构

```java
// 文件: LeaseManager.java, 行 72-103
public class LeaseManager {
    private final FSNamesystem fsnamesystem;

    // ★ Soft Limit: 默认 60 秒 (Client 可以抢占)
    private long softLimit = HdfsConstants.LEASE_SOFTLIMIT_PERIOD;
    // ★ Hard Limit: 默认 60 分钟 (自动触发 Recovery)
    private long hardLimit = HdfsConstants.LEASE_HARDLIMIT_PERIOD;

    // 三重索引结构:
    // leaseHolder → Lease (按 holder 名称查找)
    private final SortedMap<String, Lease> leases = new TreeMap<>();

    // 按 lastUpdate 时间排序的 Lease 集合 (用于 Monitor 按过期顺序检查)
    private final NavigableSet<Lease> sortedLeases = new TreeSet<>(...);

    // INodeID → Lease (按文件 ID 查找)
    private final TreeMap<Long, Lease> leasesById = new TreeMap<>();

    // Lease 监控线程
    private Daemon lmthread;
    private volatile boolean shouldRunMonitor;
}
```

### 3.2 Lease 内部类

```java
// 文件: LeaseManager.java, 行 326-381
class Lease {
    private final String holder;          // Lease 持有者 (DFSClient 名称)
    private long lastUpdate;              // 最后更新时间
    private final HashSet<Long> files = new HashSet<>();  // 持有的文件 INode ID 集合

    private void renew() {
      this.lastUpdate = monotonicNow();   // 续约 = 更新时间戳
    }

    /** Hard Limit 是否过期 (默认 60 分钟) */
    public boolean expiredHardLimit() {
      return monotonicNow() - lastUpdate > hardLimit;
    }

    /** Soft Limit 是否过期 (默认 60 秒) */
    public boolean expiredSoftLimit() {
      return monotonicNow() - lastUpdate > softLimit;
    }
}
```

### 3.3 数据关系图

```
  LeaseManager 三重索引:

  leases (SortedMap<String, Lease>):
    "DFSClient_xxx_001" → Lease {holder, lastUpdate, files=[101, 205]}
    "DFSClient_xxx_002" → Lease {holder, lastUpdate, files=[307]}

  sortedLeases (NavigableSet<Lease>):
    [Lease(oldest), Lease(second), ..., Lease(newest)]
    (按 lastUpdate 排序，Monitor 从最老的开始检查)

  leasesById (TreeMap<Long, Lease>):
    101 → Lease("DFSClient_xxx_001")
    205 → Lease("DFSClient_xxx_001")
    307 → Lease("DFSClient_xxx_002")
```

---

## 四、调用链总览

### 4.1 Lease 创建流程

```
DFSClient.create("/path/to/file")
  └── NameNodeRpcServer.create()
        └── FSNamesystem.startFile()
              └── FSDirWriteFileOp.startFile()
                    └── leaseManager.addLease(holder, inodeId)
                          ├── 创建或获取 Lease 对象
                          ├── leases.put(holder, lease)
                          ├── sortedLeases.add(lease)
                          └── leasesById.put(inodeId, lease)
```

### 4.2 Lease 续约流程

```
DFSClient 后台线程 (LeaseRenewer):
  └── 每 softLimit/2 = 30 秒发送一次 renewLease RPC
        └── NameNodeRpcServer.renewLease()
              └── FSNamesystem.renewLease()
                    └── leaseManager.renewLease(holder)
                          └── lease.renew()  // lastUpdate = monotonicNow()
```

### 4.3 Lease Recovery 流程 (Hard Limit 触发)

```
LeaseManager.Monitor (后台线程，每 2 秒检查一次):
  └── checkLeases()
        └── 遍历 sortedLeases (从最老的开始)
        └── lease.expiredHardLimit() == true?
              └── 对 lease 中每个文件调用:
                    fsnamesystem.internalReleaseLease(lease, src, iip, newHolder)
                      │
                      ├── Case 1: 所有 Block 都是 COMPLETE
                      │   └── finalizeINodeFileUnderConstruction()
                      │   └── return true (文件直接关闭)
                      │
                      ├── Case 2: 最后 Block 是 COMMITTED 且最小副本满足
                      │   └── finalizeINodeFileUnderConstruction()
                      │   └── return true (文件直接关闭)
                      │
                      ├── Case 3: 最后 Block 是 UNDER_CONSTRUCTION/UNDER_RECOVERY
                      │   └── 无 DataNode 且 Block 大小为 0:
                      │   │     └── 删除空 Block, 关闭文件
                      │   └── 有 DataNode:
                      │         └── nextGenerationStamp() (分配新 GS)
                      │         └── reassignLease() (转移 Lease 给 NameNode 自身)
                      │         └── uc.initializeBlockRecovery() (★ 启动 Block Recovery)
                      │         └── return false (Recovery 进行中，稍后再检查)
                      │
                      └── Case 4: COMMITTED 但最小副本不满足
                          └── 抛出 AlreadyBeingCreatedException (稍后重试)
```

---

## 五、核心源码分析

### 5.1 addLease — 创建 Lease

```java
// 文件: LeaseManager.java, 行 224-236
synchronized Lease addLease(String holder, long inodeId) {
    Lease lease = getLease(holder);
    if (lease == null) {
      lease = new Lease(holder);
      leases.put(holder, lease);
      sortedLeases.add(lease);
    } else {
      renewLease(lease);           // 已有 Lease 则续约
    }
    leasesById.put(inodeId, lease);
    lease.files.add(inodeId);
    return lease;
}
```

**设计意图**: 一个 Client（holder）可以同时写入多个文件，它们共享同一个 Lease。续约时只需续一个 Lease 即可更新所有文件的时间戳。

### 5.2 Monitor — Lease 监控线程

```java
// 文件: LeaseManager.java, 行 392-424
class Monitor implements Runnable {
    @Override
    public void run() {
      for (; shouldRunMonitor && fsnamesystem.isRunning(); ) {
        boolean needSync = false;
        try {
          fsnamesystem.writeLockInterruptibly();
          try {
            // ★ 安全模式中不做 Lease Recovery
            if (!fsnamesystem.isInSafeMode()) {
              needSync = checkLeases();
            }
          } finally {
            fsnamesystem.writeUnlock("leaseManager");
            if (needSync) {
              fsnamesystem.getEditLog().logSync();  // 同步 EditLog
            }
          }
          // ★ 每 2 秒检查一次 (可配置)
          Thread.sleep(fsnamesystem.getLeaseRecheckIntervalMs());
        } catch (InterruptedException ie) {
          // ...
        }
      }
    }
}
```

### 5.3 checkLeases — 核心检查逻辑

```java
// 文件: LeaseManager.java, 行 430-505
synchronized boolean checkLeases() {
    boolean needSync = false;
    assert fsnamesystem.hasWriteLock();

    long start = monotonicNow();

    // ★ 从最老的 Lease 开始检查
    while (!sortedLeases.isEmpty() &&
        sortedLeases.first().expiredHardLimit()
        && !isMaxLockHoldToReleaseLease(start)) {
      
      Lease leaseToCheck = sortedLeases.first();
      LOG.info(leaseToCheck + " has expired hard limit");

      Collection<Long> files = leaseToCheck.getFiles();
      Long[] leaseINodeIds = files.toArray(new Long[files.size()]);
      FSDirectory fsd = fsnamesystem.getFSDirectory();
      String newHolder = getInternalLeaseHolder();  // NameNode 自身作为新 holder
      
      for (Long id : leaseINodeIds) {
        try {
          INodesInPath iip = INodesInPath.fromINode(fsd.getInode(id));
          String p = iip.getPath();
          
          final INodeFile lastINode = iip.getLastINode().asFile();
          if (fsnamesystem.isFileDeleted(lastINode)) {
            removeLease(lastINode.getId());
            continue;
          }
          
          // ★ 核心: 尝试释放 Lease (触发 Recovery)
          boolean completed = fsnamesystem.internalReleaseLease(
              leaseToCheck, p, iip, newHolder);
              
          if (!needSync && !completed) {
            needSync = true;  // Recovery 进行中，需要 sync EditLog
          }
        } catch (IOException e) {
          LOG.warn("Cannot release the path " + p + ". It will be retried.", e);
          continue;
        }
        
        // ★ 防止长时间持有写锁
        if (isMaxLockHoldToReleaseLease(start)) {
          LOG.debug("Breaking out of checkLeases after max lock hold time.");
          break;
        }
      }
    }
    return needSync;
}
```

**关键设计**:
1. **按过期顺序处理**: `sortedLeases` 按 `lastUpdate` 排序，最老的 Lease 最先被检查
2. **防止锁饥饿**: `isMaxLockHoldToReleaseLease()` 限制单次持有写锁的最大时间
3. **容错重试**: 如果 `internalReleaseLease()` 失败，不移除 Lease，下次继续尝试

### 5.4 internalReleaseLease — Lease 释放与 Block Recovery

```java
// 文件: FSNamesystem.java, 行 3193-3327
boolean internalReleaseLease(Lease lease, String src, INodesInPath iip,
    String recoveryLeaseHolder) throws IOException {
    LOG.info("Recovering " + lease + ", src=" + src);
    assert !isInSafeMode();
    assert hasWriteLock();

    final INodeFile pendingFile = iip.getLastINode().asFile();
    int nrBlocks = pendingFile.numBlocks();
    BlockInfo[] blocks = pendingFile.getBlocks();

    // 统计 COMPLETE 块数
    int nrCompleteBlocks;
    BlockInfo curBlock = null;
    for (nrCompleteBlocks = 0; nrCompleteBlocks < nrBlocks; nrCompleteBlocks++) {
      curBlock = blocks[nrCompleteBlocks];
      if (!curBlock.isComplete())
        break;
    }

    // ★ Case 1: 所有块都是 COMPLETE → 直接关闭文件
    if (nrCompleteBlocks == nrBlocks) {
      finalizeINodeFileUnderConstruction(src, pendingFile,
          iip.getLatestSnapshotId(), false);
      NameNode.stateChangeLog.warn("BLOCK* internalReleaseLease: " +
          "All existing blocks are COMPLETE, lease removed, file " + src + " closed.");
      return true;  // ★ 文件已关闭
    }

    // 获取最后一个 Block 的状态
    final BlockInfo lastBlock = pendingFile.getLastBlock();
    BlockUCState lastBlockState = lastBlock.getBlockUCState();

    switch (lastBlockState) {
    case COMMITTED:
      // ★ Case 2: 最后块是 COMMITTED 且满足最小副本 → 关闭文件
      if (penultimateBlockMinReplication &&
          blockManager.checkMinReplication(lastBlock)) {
        finalizeINodeFileUnderConstruction(src, pendingFile,
            iip.getLatestSnapshotId(), false);
        return true;  // ★ 文件已关闭
      }
      // 最小副本不满足，稍后重试
      throw new AlreadyBeingCreatedException("Committed blocks waiting...");

    case UNDER_CONSTRUCTION:
    case UNDER_RECOVERY:
      BlockUnderConstructionFeature uc = lastBlock.getUnderConstructionFeature();

      // ★ Case 3: 空 Block (无数据) → 删除空 Block 关闭文件
      if (uc.getNumExpectedLocations() == 0 && lastBlock.getNumBytes() == 0) {
        pendingFile.removeLastBlock(lastBlock);
        finalizeINodeFileUnderConstruction(src, pendingFile,
            iip.getLatestSnapshotId(), false);
        return true;  // ★ 文件已关闭
      }

      // ★ Case 4: 有数据 → 启动 Block Recovery
      long blockRecoveryId = nextGenerationStamp(
          blockIdManager.isLegacyBlock(lastBlock));
      
      // 将 Lease 转移给 NameNode 内部持有者
      lease = reassignLease(lease, src, recoveryLeaseHolder, pendingFile);
      
      // ★ 初始化 Block Recovery
      uc.initializeBlockRecovery(lastBlock, blockRecoveryId, true);
      leaseManager.renewLease(lease);
      
      NameNode.stateChangeLog.warn("DIR* NameSystem.internalReleaseLease: " +
          "File " + src + " has not been closed. " +
          "Lease recovery is in progress. RecoveryId = " + blockRecoveryId);
      return false;  // ★ Recovery 进行中，文件尚未关闭
    }
    return false;
}
```

---

## 六、Block Recovery 详解

### 6.1 Lease Recovery vs Block Recovery

| 维度 | Lease Recovery | Block Recovery |
|------|---------------|----------------|
| 触发者 | LeaseManager.Monitor | internalReleaseLease() |
| 目的 | 回收过期 Lease | 恢复未完成的 Block |
| 范围 | 文件级别 | Block 级别 |
| 执行者 | NameNode | Primary DataNode |
| 结果 | 文件关闭或触发 Block Recovery | Block 变为 COMPLETE |

### 6.2 Block Recovery 算法 (来自源码注释)

```java
// 文件: LeaseManager.java, 行 53-69
/**
 * Lease Recovery Algorithm:
 * 1) NameNode retrieves lease information
 * 2) For each file f in the lease, consider the last block b of f
 *    2.1) Get the datanodes which contains b
 *    2.2) Assign one of the datanodes as the primary datanode p
 *    2.3) p obtains a new generation stamp from the namenode
 *    2.4) p gets the block info from each datanode
 *    2.5) p computes the minimum block length
 *    2.6) p updates the datanodes, which have a valid generation stamp,
 *         with the new generation stamp and the minimum block length
 *    2.7) p acknowledges the namenode the update results
 *    2.8) Namenode updates the BlockInfo
 *    2.9) Namenode removes f from the lease
 *         and removes the lease once all files have been removed
 *    2.10) Namenode commit changes to edit log
 */
```

### 6.3 Block Recovery 时序图

```
时间线

├── Client 崩溃 (不再续约 Lease)
│
├── 60 分钟后: LeaseManager.Monitor 检测到 Hard Limit 过期
│   └── checkLeases() → internalReleaseLease()
│
├── NameNode 启动 Block Recovery:
│   ├── 分配新的 Generation Stamp (blockRecoveryId)
│   ├── reassignLease() → NameNode 自身持有 Lease
│   └── initializeBlockRecovery(lastBlock, blockRecoveryId)
│       └── 选择 Primary DataNode (p)
│       └── 在 p 的下次心跳中下发 Recovery 命令
│
├── Primary DataNode (p) 执行 Block Recovery:
│   ├── 2.3: 获取 blockRecoveryId (新 GS) ← NameNode 已分配
│   ├── 2.4: 向所有持有该 Block 的 DN 查询 Block 信息
│   │         DN-1: block_len=1024, gs=1001
│   │         DN-2: block_len=2048, gs=1001  
│   │         DN-3: block_len=1024, gs=1001
│   ├── 2.5: 计算最小 Block 长度 = min(1024, 2048, 1024) = 1024
│   ├── 2.6: 通知所有 DN 更新:
│   │         - 截断 Block 到 1024 字节
│   │         - 更新 Generation Stamp 为 blockRecoveryId
│   └── 2.7: 向 NameNode 报告 Recovery 结果
│             commitBlockSynchronization(block, newGS, newLength, ...)
│
├── NameNode 处理 Recovery 结果:
│   ├── 2.8: 更新 BlockInfo (新长度、新 GS)
│   ├── Block 状态: UNDER_RECOVERY → COMPLETE
│   ├── 2.9: 关闭文件, 移除 Lease
│   └── 2.10: 记录 EditLog
│
└── 文件现在可以被其他 Client 正常读取
```

---

## 七、Soft Limit 与 Lease 抢占

### 7.1 recoverLease — 其他 Client 抢占

当 Soft Limit 过期后（60 秒），其他 Client 可以通过 `recoverLease` 抢占写入权：

```
场景: Client-A 崩溃，Client-B 想追加写入同一个文件

Client-B.append("/path/to/file")
  └── NameNode: 检测到文件有 Lease (holder=Client-A)
        └── Client-A 的 Lease softLimit 已过期?
              ├── Yes → 可以抢占
              │   └── recoverLeaseInternal()
              │         └── internalReleaseLease(lease, src, iip, Client-B)
              │               └── 触发 Block Recovery (如需要)
              │               └── 完成后 Client-B 获得 Lease
              └── No → 抛出 AlreadyBeingCreatedException
                        "Client-A 正在写入此文件"
```

```java
// 文件: FSNamesystem.java, 行 2390-2441 (简化)
boolean recoverLeaseInternal(RecoverLeaseOp op, INodesInPath iip,
    String src, String holder, Configuration conf, boolean force)
    throws IOException {
    
    final INodeFile file = iip.getLastINode().asFile();
    if (!file.isUnderConstruction()) {
      return true;  // 文件不在写入状态，无需 Recovery
    }
    
    String clientName = file.getFileUnderConstructionFeature().getClientName();
    
    if (holder.equals(clientName)) {
      // 同一个 Client 重新打开文件
      return true;
    }
    
    Lease lease = leaseManager.getLease(clientName);
    if (force) {
      // 强制模式
    } else if (lease != null) {
      if (!lease.expiredSoftLimit()) {
        // ★ Soft Limit 未过期，拒绝抢占
        throw new AlreadyBeingCreatedException(
            "File is already being created by " + clientName);
      }
    }
    
    // ★ Soft Limit 已过期，可以抢占
    LOG.info("recoverLease: " + lease + ", src=" + src + " from client " + clientName);
    return internalReleaseLease(lease, src, iip, holder);
}
```

### 7.2 Soft Limit vs Hard Limit 对比

```
时间轴:
  0s                60s                              3600s
  │─── 正常写入 ────│──── Soft Limit ────────────────│── Hard Limit ──
  │                 │                                │
  │  Client 活跃    │  Client 可能崩溃               │  确认 Client 已死
  │  定期续约       │  其他 Client 可抢占            │  自动 Recovery
  │                 │  (需要显式请求)                │  (Monitor 自动)
```

| 特性 | Soft Limit (60s) | Hard Limit (60min) |
|------|------------------|---------------------|
| 默认值 | 60 秒 | 3600 秒 (60 分钟) |
| 触发条件 | 距最后续约 > 60s | 距最后续约 > 3600s |
| 效果 | 允许其他 Client 抢占 | 自动触发 Recovery |
| 谁触发 | 另一个 Client 的 append/create | LeaseManager.Monitor |
| 场景 | Client 可能只是暂时断开 | Client 确认已死 |

---

## 八、与 NameNode HA 的交互

### 8.1 HA 切换时的 Lease 处理

```
Active NameNode 故障 → Standby 切换为 Active:

1. 新 Active NameNode 从 EditLog 恢复所有 Lease 状态
2. LeaseManager.Monitor 重新启动
3. 正在进行中的 Block Recovery:
   - 如果 Primary DN 已经完成 Recovery:
     → 心跳时报告 commitBlockSynchronization → 正常完成
   - 如果 Primary DN 还未完成:
     → Lease 会再次过期 → 重新触发 Recovery
     → 新 Active 分配新的 blockRecoveryId (更高的 GS)
     → 旧的 Recovery 自动失效 (GS 不匹配)
```

### 8.2 Generation Stamp 的仲裁作用

```
GS (Generation Stamp) 在 Recovery 中的作用:

  Block 初始状态: GS=1001
    │
    ├── 第一次 Recovery: NameNode 分配 GS=1002
    │   └── Primary DN 执行 Recovery, 更新 Block GS=1002
    │
    ├── HA 切换! 新 Active 不知道 Recovery 结果
    │
    └── 第二次 Recovery: 新 Active 分配 GS=1003
        └── DN 比较: 自己的 GS(1002) < Recovery GS(1003)
        └── DN 接受新的 Recovery (GS=1003)
        └── 旧 Recovery (GS=1002) 的结果被覆盖

结论: GS 单调递增，确保只有最新的 Recovery 有效
```

---

## 九、关键参数与调优建议

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `dfs.namenode.lease-recheck-interval-ms` | 2000ms | Monitor 检查间隔 | 通常不改 |
| `dfs.namenode.max-lock-hold-to-release-lease-ms` | 25000ms | 单次检查最大持锁时间 | |
| Soft Limit | 60s | Client 断开后允许抢占时间 | 代码硬编码，不可配 |
| Hard Limit | 3600s (60min) | 自动 Recovery 触发时间 | 代码硬编码，不可配 |
| `dfs.client.retry.period` | 60000ms | Client 续约失败重试间隔 | |
| `dfs.ha.tail-edits.period` | 60s | Standby 拉取 EditLog 间隔 | 影响 HA 切换后 Lease 恢复速度 |

### 调优场景

**场景 1: 加速文件恢复（不等 Hard Limit）**
```java
// 通过其他 Client 主动触发 Soft Limit Recovery
FileSystem fs = FileSystem.get(conf);
((DistributedFileSystem) fs).recoverLease(new Path("/stuck/file"));
```

```bash
# 或使用命令行工具
hdfs debug recoverLease -path /stuck/file
```

**场景 2: 大量 Lease 导致 NameNode 压力**
```xml
<!-- 增加检查间隔，减少锁竞争 -->
<property>
  <name>dfs.namenode.lease-recheck-interval-ms</name>
  <value>5000</value>
</property>
```

**场景 3: 检查当前 Lease 状态**
```bash
# 查看所有打开的文件 (持有 Lease 的文件)
hdfs dfsadmin -listOpenFiles

# 通过 JMX 监控
curl http://<namenode>:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem | \
  jq '.beans[0].FilesUnderConstruction'
```

---

## 十、踩坑记录

### 坑 1: AlreadyBeingCreatedException 的多种含义
这个异常不一定表示"有人在写"，可能是：
1. 上一个 Client 崩溃但 Soft Limit 未过期（需等待 60s）
2. Block Recovery 正在进行中（COMMITTED 但副本不足）
3. 文件确实被另一个活跃 Client 写入

**解决**: 重试或调用 `recoverLease()` 强制恢复。

### 坑 2: Hard Limit 60 分钟导致文件长时间不可用
Client 崩溃后，如果没有其他 Client 主动 `recoverLease()`，文件需要等 60 分钟才能自动恢复。在此期间：
- 文件可读（已写入的 COMPLETE Block 可以读取）
- 最后一个 UNDER_CONSTRUCTION Block 不可读
- 文件不可追加写入

**建议**: 重要文件在检测到 Client 崩溃后，立即调用 `recoverLease()`。

### 坑 3: Block Recovery 可能丢失数据
Block Recovery 使用**最小长度**策略（取所有 DN 上该 Block 长度的最小值）。这意味着：
- 如果某个 DN 收到了更多数据但还未确认给其他 DN，那些数据会被截断
- Pipeline Recovery 和 Block Recovery 的语义不同：Pipeline Recovery 保证已 ACK 的数据不丢，Block Recovery 可能丢失未同步的数据

### 坑 4: 安全模式中 Lease 不检查
`Monitor.run()` 中有 `if (!fsnamesystem.isInSafeMode())` 判断。NameNode 在安全模式期间不执行 Lease 检查，也不触发 Recovery。大量 Lease 可能在安全模式退出后瞬间触发大量 Recovery。

### 坑 5: NameNode 内部 Lease Holder 的时间戳
```java
// 文件: LeaseManager.java, 行 111-124
private void updateInternalLeaseHolder() {
    this.lastHolderUpdateTime = Time.monotonicNow();
    this.internalLeaseHolder = HdfsServerConstants.NAMENODE_LEASE_HOLDER +
        "-" + Time.formatTime(Time.now());
}
```
NameNode 自身作为 Recovery 的 Lease Holder 时，使用带时间戳的名称。这确保 HA 切换后新 Active 的内部 Holder 名称不同，避免与旧 Active 的 Recovery 冲突。

---

## 十一、Lease 管理完整状态图

```
                    create()
  [No Lease] ─────────────────────► [Active Lease]
                                         │
                          ┌──────────────┼──────────────┐
                          │              │              │
                     renewLease()    close()      Soft Limit
                     (每30s)          │           过期(60s)
                          │           │              │
                          └───────┐   │   ┌──────────┘
                                  │   │   │
                                  ▼   ▼   ▼
                             [Active] [Closed] [Soft Expired]
                                              │
                                              │ 其他 Client
                                              │ recoverLease()
                                              ▼
                                         [Recovery]
                                              │
                                              │ internalReleaseLease()
                             ┌────────────────┼────────────────┐
                             │                │                │
                        All COMPLETE    COMMITTED OK    UNDER_CONSTRUCTION
                             │                │                │
                             ▼                ▼                ▼
                          [Closed]         [Closed]     [Block Recovery]
                                                              │
                                                    Primary DN 执行
                                                    commitBlockSync
                                                              │
                                                              ▼
                                                          [Closed]

  Hard Limit 过期 (60min):
    [Active Lease] ──Monitor──► [Recovery] ──(同上)──► [Closed]
```

---

## 十二、认知更新

1. **Lease 是 HDFS 写入互斥的基石**: 没有 Lease 机制，多个 Client 可能同时写同一个文件导致数据损坏
2. **Soft/Hard Limit 是两级保护**: Soft Limit 允许快速恢复（另一个 Client 主动触发），Hard Limit 是兜底保障
3. **Block Recovery 选择最小长度是安全策略**: 宁可丢数据也不保留可能不一致的部分
4. **Generation Stamp 是版本仲裁器**: 解决 HA 切换和并发 Recovery 的一致性问题
5. **LeaseManager 的三重索引设计**: 按 holder/按时间/按文件 ID 三种访问模式优化
6. **Monitor 防锁饥饿设计**: `isMaxLockHoldToReleaseLease()` 防止大量 Lease 过期时长时间持有写锁
7. **安全模式是 Lease Recovery 的暂停键**: 类似 BlockManager，安全模式期间不执行 Recovery
