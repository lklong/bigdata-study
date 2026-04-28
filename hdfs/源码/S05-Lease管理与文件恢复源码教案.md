# [教案] S05-Lease管理与文件恢复源码深度剖析

> 🎯 教学目标：掌握HDFS Lease机制的设计思想、Soft/Hard Limit的工作原理、Lease Recovery与Block Recovery的完整流程 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：图书馆自习室的座位管理

想象你在大学图书馆，自习室的座位是有限的。图书馆有一个规定：
- 你可以在前台**登记**占用一个座位（获取 Lease）
- 每隔一段时间你需要回前台**刷卡续期**，证明你还在用（Lease Renew）
- 如果你离开**超过1小时没刷卡**（Soft Limit 过期），其他同学可以来占你的位（其他 Client 可以抢占写权限）
- 如果你离开**超过60小时还没刷卡**（Hard Limit 过期），管理员会强制清理你的物品，把座位释放出来（NameNode 强制回收 Lease）
- 如果你突然生病（Client 崩溃），管理员会按流程处理你的桌上物品（Lease Recovery）

在 HDFS 中，**Lease 就是文件的写锁**。任何时刻，一个文件只能被一个 Client 写入。Lease 机制保证了**写操作的互斥性**，同时通过超时回收避免了**死锁**（Client 崩溃后文件永远不能关闭）。

### 生产故障场景

```
场景：HBase RegionServer 突然审机，大量 WAL 文件残留在 HDFS 上
现象：新的 RegionServer 试图恢复这些 WAL 文件时报错
      "org.apache.hadoop.hdfs.protocol.AlreadyBeingCreatedException: 
       Failed to create file /hbase/WALs/xxx for DFSClient_xxx 
       on client xxx because this file lease is currently owned by 
       DFSClient_yyy on host_yyy"
根因：旧的 RegionServer 崩溃后，其持有的 Lease 尚未过期或回收
解法：理解 Lease Recovery 机制才能正确排障
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| Lease | HDFS文件的写锁，绑定到一个Client | 自习室座位登记卡 |
| Lease Holder | 持有Lease的客户端标识 | 登记卡上的姓名 |
| Soft Limit | 60秒，过期后其他Client可抢占 | 1小时不刷卡，座位可被他人申请 |
| Hard Limit | 60分钟，过期后NameNode强制回收 | 60小时不刷卡，管理员强制清场 |
| Lease Renew | Client定期续约（默认30秒一次） | 回前台刷卡 |
| Lease Recovery | 发现过期Lease后的恢复流程 | 管理员按流程处理遗留物品 |
| Block Recovery | Lease Recovery中对最后一个Block的同步修复 | 管理员检查桌上半完成的作业，确定保留多少 |
| LeaseManager | NameNode中管理所有Lease的组件 | 前台管理员 |
| LeaseRenewer | Client端的续约守护线程 | 定时提醒你去刷卡的闹钟 |
| Monitor | LeaseManager内部的检查线程 | 管理员的巡检计划 |

### 2.2 架构图

```
┌──────────────────────────────────────────────────────────┐
│                      NameNode                             │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                  LeaseManager                        │ │
│  │                                                      │ │
│  │  ┌───────────────┐  ┌──────────────────────────────┐│ │
│  │  │  leases        │  │  sortedLeases (按时间排序)   ││ │
│  │  │ (holder→Lease) │  │  最老的Lease在最前面          ││ │
│  │  └───────────────┘  └──────────────────────────────┘│ │
│  │  ┌───────────────────────────────────────┐          │ │
│  │  │  leasesById (INodeID → Lease)          │          │ │
│  │  └───────────────────────────────────────┘          │ │
│  │                                                      │ │
│  │  ┌────────────────────┐                              │ │
│  │  │  Monitor Thread     │ ← 定期检查过期Lease         │ │
│  │  │  (Daemon线程)       │                              │ │
│  │  └────────────────────┘                              │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              FSNamesystem                             │ │
│  │  recoverLease() ──→ internalReleaseLease()           │ │
│  │                          │                            │ │
│  │                          ├─ 所有Block COMPLETE → 关闭 │ │
│  │                          ├─ 最后Block COMMITTED → 关闭│ │
│  │                          └─ UNDER_CONSTRUCTION →      │ │
│  │                             initializeBlockRecovery() │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
        ▲                                    │
        │ renewLease (每30秒)                │ Block Recovery Command
        │                                    ▼
┌───────────────┐                  ┌───────────────────┐
│  DFS Client    │                  │   DataNode (Primary)│
│ ┌────────────┐│                  │  - 获取新GS          │
│ │LeaseRenewer ││                  │  - 收集Block信息     │
│ │(守护线程)   ││                  │  - 计算最小长度      │
│ └────────────┘│                  │  - 同步更新各DN      │
└───────────────┘                  └───────────────────┘
```

### 2.3 Lease 生命周期

```
Client创建/打开文件 → addLease(holder, inodeId)
         │
         ▼
   LeaseRenewer 每30秒续约 → renewLease(holder)
         │
         ├─ 正常关闭文件 → removeLease(holder, src)
         │
         ├─ Soft Limit过期(60s) → 其他Client可抢占
         │     └─ 新Client调用recoverLease()
         │
         └─ Hard Limit过期(60min) → Monitor强制回收
               └─ checkLeases() → internalReleaseLease()
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|---------|------|
| `LeaseManager` | `hdfs/server/namenode/LeaseManager.java` | Lease的增删改查、过期检查、Monitor线程 |
| `LeaseManager.Lease` | 同上（内部类） | 单个Lease实体，包含holder、lastUpdate、files |
| `LeaseManager.Monitor` | 同上（内部类） | 后台守护线程，定期检查过期Lease |
| `FSNamesystem` | `hdfs/server/namenode/FSNamesystem.java` | Lease Recovery的实际执行者 |
| `LeaseRenewer` | `hdfs-client/client/impl/LeaseRenewer.java` | Client端的Lease续约守护线程 |
| `HdfsConstants` | `hdfs-client/protocol/HdfsConstants.java` | 定义Soft/Hard Limit常量 |

### 3.2 关键方法逐行解读

#### 3.2.1 Soft/Hard Limit 常量定义

```java
// 文件: hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/protocol/HdfsConstants.java
// 行号: 96-117

/**
 * For a HDFS client to write to a file, a lease is granted; During the lease
 * period, no other client can write to the file. The writing client can
 * periodically renew the lease. When the file is closed, the lease is
 * revoked. The lease duration is bound by this soft limit and a hard limit.
 * Until the soft limit expires, the writer has sole write access to the file.
 * If the soft limit expires and the client fails to close the file or renew
 * the lease, another client can preempt the lease.
 */
public static final long LEASE_SOFTLIMIT_PERIOD = 60 * 1000;  // 60秒

/**
 * If after the hard limit expires and the client has failed to renew
 * the lease, HDFS assumes that the client has quit and will automatically
 * close the file on behalf of the writer, and recover the lease.
 */
public static final long LEASE_HARDLIMIT_PERIOD = 60 * LEASE_SOFTLIMIT_PERIOD;  // 60分钟
```

**教学要点**：
- Soft Limit = 60秒：过期后，**其他 Client** 可以通过 `recoverLease()` 抢占
- Hard Limit = 60分钟：过期后，**NameNode 自己** 通过 Monitor 线程强制回收
- 两层设计思想：先给 Client 机会自己恢复，超时后系统兜底

#### 3.2.2 LeaseManager 核心数据结构

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/LeaseManager.java
// 行号: 72-100

public class LeaseManager {
  private final FSNamesystem fsnamesystem;

  private long softLimit = HdfsConstants.LEASE_SOFTLIMIT_PERIOD;   // 60s
  private long hardLimit = HdfsConstants.LEASE_HARDLIMIT_PERIOD;   // 60min

  // 三个关键数据结构，构成了 Lease 的多维索引
  // 1. holder名称 → Lease对象（按holder快速查找）
  private final SortedMap<String, Lease> leases = new TreeMap<>();
  
  // 2. 按lastUpdate排序的Lease集合（用于快速找到最老的过期Lease）
  private final NavigableSet<Lease> sortedLeases = new TreeSet<>(
      new Comparator<Lease>() {
        @Override
        public int compare(Lease o1, Lease o2) {
          if (o1.getLastUpdate() != o2.getLastUpdate()) {
            return Long.signum(o1.getLastUpdate() - o2.getLastUpdate());
          } else {
            return o1.holder.compareTo(o2.holder);  // 时间相同时按holder排序
          }
        }
  });
  
  // 3. INodeID → Lease（按文件快速查找其所属Lease）
  private final TreeMap<Long, Lease> leasesById = new TreeMap<>();
}
```

**教学要点**：
- 三个数据结构 = 三个索引维度：按 holder 查、按时间排序、按文件ID查
- `sortedLeases` 是 `TreeSet`，最老的 Lease 在最前面，`checkLeases()` 只需检查头部
- 这是典型的"**空间换时间**"设计模式

#### 3.2.3 Lease 内部类

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/LeaseManager.java
// 行号: 326-381

class Lease {
  private final String holder;          // 持有者标识（DFSClient_xxx）
  private long lastUpdate;              // 上次续约时间（单调时钟）
  private final HashSet<Long> files = new HashSet<>();  // 该holder打开的所有文件INodeID
  
  private Lease(String holder) {
    this.holder = holder;
    renew();  // 创建时自动续约
  }
  
  private void renew() {
    this.lastUpdate = monotonicNow();  // 使用单调时钟，不受系统时间修改影响
  }

  /** Hard Limit 是否过期 */
  public boolean expiredHardLimit() {
    return monotonicNow() - lastUpdate > hardLimit;  // 超过60分钟
  }

  /** Soft Limit 是否过期 */
  public boolean expiredSoftLimit() {
    return monotonicNow() - lastUpdate > softLimit;  // 超过60秒
  }
}
```

**教学要点**：
- 一个 Lease 可以关联多个文件（`HashSet<Long> files`），因为同一个 Client 可以同时写多个文件
- 使用 `monotonicNow()` 而非 `System.currentTimeMillis()`，避免系统时钟回拨导致误判
- Lease 对象只能由 LeaseManager 创建（构造函数 `private`），这是**封装性**的体现

#### 3.2.4 Lease 的增删续约

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/LeaseManager.java
// 行号: 224-308

/** 添加Lease */
synchronized Lease addLease(String holder, long inodeId) {
  Lease lease = getLease(holder);
  if (lease == null) {
    lease = new Lease(holder);         // 新建Lease
    leases.put(holder, lease);          // 加入holder索引
    sortedLeases.add(lease);            // 加入时间排序集合
  } else {
    renewLease(lease);                  // holder已存在，仅续约
  }
  leasesById.put(inodeId, lease);       // 加入文件索引
  lease.files.add(inodeId);             // 关联文件
  return lease;
}

/** 删除Lease中的某个文件 */
private synchronized void removeLease(Lease lease, long inodeId) {
  leasesById.remove(inodeId);           // 移除文件索引
  lease.removeFile(inodeId);            // 从Lease中移除文件
  
  if (!lease.hasFiles()) {              // 如果Lease下没有文件了
    leases.remove(lease.holder);        // 移除holder索引
    sortedLeases.remove(lease);         // 移除排序集合
  }
}

/** 续约 */
synchronized void renewLease(Lease lease) {
  if (lease != null) {
    sortedLeases.remove(lease);  // 先移除（因为排序键要变）
    lease.renew();                // 更新lastUpdate
    sortedLeases.add(lease);     // 重新插入（新的排序位置）
  }
}
```

**教学要点**：
- `renewLease` 的 remove-then-add 模式：因为 TreeSet 的排序基于 `lastUpdate`，更新值后必须重新排序
- 所有操作都是 `synchronized`，保证线程安全
- `removeLease` 的级联删除：文件移除后，如果 Lease 下没有文件了，则整个 Lease 也被清理

#### 3.2.5 Monitor 线程：过期 Lease 的自动回收

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/LeaseManager.java
// 行号: 392-424

class Monitor implements Runnable {
  @Override
  public void run() {
    for(; shouldRunMonitor && fsnamesystem.isRunning(); ) {
      boolean needSync = false;
      try {
        fsnamesystem.writeLockInterruptibly();  // 获取FSN写锁
        try {
          if (!fsnamesystem.isInSafeMode()) {
            needSync = checkLeases();  // 核心：检查并回收过期Lease
          }
        } finally {
          fsnamesystem.writeUnlock("leaseManager");
          if (needSync) {
            fsnamesystem.getEditLog().logSync();  // 同步EditLog
          }
        }
        Thread.sleep(fsnamesystem.getLeaseRecheckIntervalMs());  // 默认2秒
      } catch(InterruptedException ie) {
        // 被中断，继续循环
      }
    }
  }
}
```

**教学要点**：
- Monitor 是一个 Daemon 线程，NameNode 退出时自动停止
- 在 SafeMode 下不检查 Lease（SafeMode下不允许修改操作）
- 检查频率：默认每2秒一次（`dfs.namenode.lease-recheck-interval-ms`）
- 注意锁的顺序：先获取 FSNamesystem 写锁，再操作 Lease

#### 3.2.6 checkLeases()：过期检查的核心逻辑

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/LeaseManager.java
// 行号: 430-505

synchronized boolean checkLeases() {
  boolean needSync = false;
  long start = monotonicNow();

  // 从最老的Lease开始检查
  while(!sortedLeases.isEmpty() &&
      sortedLeases.first().expiredHardLimit()   // 只有Hard Limit过期才强制回收
      && !isMaxLockHoldToReleaseLease(start)) { // 不能持锁太久
    
    Lease leaseToCheck = sortedLeases.first();
    LOG.info(leaseToCheck + " has expired hard limit");

    Collection<Long> files = leaseToCheck.getFiles();
    Long[] leaseINodeIds = files.toArray(new Long[files.size()]);
    String newHolder = getInternalLeaseHolder();  // 内部holder，接管Lease
    
    for(Long id : leaseINodeIds) {
      INodesInPath iip = INodesInPath.fromINode(fsd.getInode(id));
      String p = iip.getPath();
      
      if (fsnamesystem.isFileDeleted(lastINode)) {
        removeLease(lastINode.getId());  // 文件已删除，直接清理Lease
        continue;
      }
      
      boolean completed = fsnamesystem.internalReleaseLease(
          leaseToCheck, p, iip, newHolder);  // 核心：执行Lease Recovery
      
      if (!needSync && !completed) {
        needSync = true;  // Block Recovery启动了，需要同步EditLog
      }
    }
  }
  return needSync;
}
```

**教学要点**：
- `sortedLeases.first()` 总是最老的 Lease，O(1) 获取
- `isMaxLockHoldToReleaseLease` 防止持锁时间过长（默认25秒），保护 NameNode 响应性
- `getInternalLeaseHolder()` 返回形如 `HDFS_NameNode-2026-04-28 23:06:00` 的内部标识
- 设计亮点：即使要处理很多过期 Lease，也不会一直持锁，到时间就释放

#### 3.2.7 internalReleaseLease()：Lease Recovery 的核心逻辑

这是整个 Lease Recovery 中最关键的方法，根据最后一个 Block 的状态做不同处理：

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java
// 行号: 3193-3327

boolean internalReleaseLease(Lease lease, String src, INodesInPath iip,
    String recoveryLeaseHolder) throws IOException {
  LOG.info("Recovering " + lease + ", src=" + src);
  
  final INodeFile pendingFile = iip.getLastINode().asFile();
  int nrBlocks = pendingFile.numBlocks();
  BlockInfo[] blocks = pendingFile.getBlocks();

  // 第一步：计算有多少个Block已经COMPLETE
  int nrCompleteBlocks;
  BlockInfo curBlock = null;
  for(nrCompleteBlocks = 0; nrCompleteBlocks < nrBlocks; nrCompleteBlocks++) {
    curBlock = blocks[nrCompleteBlocks];
    if(!curBlock.isComplete()) break;
  }

  // 情况1：所有Block都COMPLETE → 直接关闭文件，回收Lease
  if(nrCompleteBlocks == nrBlocks) {
    finalizeINodeFileUnderConstruction(src, pendingFile, ...);
    return true;  // closed!
  }

  // 分析最后一个Block的状态
  final BlockInfo lastBlock = pendingFile.getLastBlock();
  BlockUCState lastBlockState = lastBlock.getBlockUCState();

  switch(lastBlockState) {
  case COMMITTED:
    // 情况2：最后Block已COMMITTED且满足最小副本数 → 直接关闭
    if(penultimateBlockMinReplication &&
        blockManager.checkMinReplication(lastBlock)) {
      finalizeINodeFileUnderConstruction(src, pendingFile, ...);
      return true;  // closed!
    }
    // 不满足最小副本数 → 抛异常，等待下次重试
    throw new AlreadyBeingCreatedException("Committed blocks are waiting " +
        "to be minimally replicated. Try again later.");

  case UNDER_CONSTRUCTION:
  case UNDER_RECOVERY:
    // 情况3：需要Block Recovery
    
    // 3a: 如果最后Block没有任何DataNode且大小为0 → 删除空Block，关闭文件
    if (uc.getNumExpectedLocations() == 0 && lastBlock.getNumBytes() == 0) {
      pendingFile.removeLastBlock(lastBlock);
      finalizeINodeFileUnderConstruction(src, pendingFile, ...);
      return true;  // closed!
    }
    
    // 3b: 启动Block Recovery
    long blockRecoveryId = nextGenerationStamp(...);  // 分配新的GS
    lease = reassignLease(lease, src, recoveryLeaseHolder, pendingFile);
    uc.initializeBlockRecovery(lastBlock, blockRecoveryId, true);
    leaseManager.renewLease(lease);  // 续约，避免反复触发
    return false;  // 未关闭，Block Recovery进行中
  }
  return false;
}
```

**教学要点**：
- 这是一个**状态机**：根据最后 Block 的 4 种状态（COMPLETE/COMMITTED/UNDER_CONSTRUCTION/UNDER_RECOVERY），执行不同的恢复策略
- 空 Block 优化：如果 Client 崩溃在写入数据之前（Block 大小为0），直接删除，不需要 Recovery
- `nextGenerationStamp()` 分配新的 Generation Stamp，这是 Block Recovery 的"协议版本号"
- `reassignLease` 将 Lease 从崩溃的 Client 转移到 NameNode 内部 holder

#### 3.2.8 Client 端的 LeaseRenewer

```java
// 文件: hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/client/impl/LeaseRenewer.java
// 行号: 166-167

/** A fixed lease renewal time period in milliseconds */
private long renewal = HdfsConstants.LEASE_SOFTLIMIT_PERIOD / 2;  // 30秒
```

**教学要点**：
- Client 每 30 秒续约一次（Soft Limit 的一半），留出充足的安全裕量
- 如果网络抖动导致一次续约失败，还有 30 秒的缓冲时间

### 3.3 调用链时序图

#### 3.3.1 正常写入场景

```
Client                      NameNode (FSNamesystem)           LeaseManager
  │                              │                               │
  │──create(/data/file.txt)────→ │                               │
  │                              │──addLease("DFSClient_1",id)──→│
  │                              │                               │─ leases.put()
  │                              │                               │─ sortedLeases.add()
  │                              │                               │─ leasesById.put()
  │←─────返回OutputStream────────│                               │
  │                              │                               │
  │  [每30秒]                     │                               │
  │──renewLease("DFSClient_1")──→│                               │
  │                              │──renewLease("DFSClient_1")───→│
  │                              │                               │─ sortedLeases.remove()
  │                              │                               │─ lease.renew()
  │                              │                               │─ sortedLeases.add()
  │                              │                               │
  │──close()────────────────────→│                               │
  │                              │──removeLease("DFSClient_1")──→│
  │                              │                               │─ leasesById.remove()
  │                              │                               │─ lease.removeFile()
  │                              │                               │─ leases.remove() [if empty]
```

#### 3.3.2 Client 崩溃后的 Lease Recovery

```
Client (崩溃)       NameNode                    DataNode(Primary)    DataNode(Replica)
  ╳                   │                              │                    │
  │                   │                              │                    │
  │            [2秒一次]│                              │                    │
  │            Monitor │                              │                    │
  │                   │──checkLeases()                │                    │
  │                   │  sortedLeases.first()         │                    │
  │                   │  expiredHardLimit()?           │                    │
  │                   │  YES (超过60分钟没续约)         │                    │
  │                   │                              │                    │
  │                   │──internalReleaseLease()       │                    │
  │                   │  lastBlock状态=UNDER_CONSTRUCTION                   │
  │                   │  分配新GenerationStamp         │                    │
  │                   │  reassignLease()              │                    │
  │                   │  initializeBlockRecovery()    │                    │
  │                   │                              │                    │
  │                   │──[心跳响应中下发]──────────────→│                    │
  │                   │  BlockRecoveryCommand          │                    │
  │                   │                              │                    │
  │                   │                              │──getBlockInfo()───→│
  │                   │                              │←─返回Block信息──────│
  │                   │                              │                    │
  │                   │                              │  计算最小Block长度   │
  │                   │                              │  更新GS              │
  │                   │                              │──updateBlock()────→│
  │                   │                              │                    │
  │                   │←─commitBlockSynchronization──│                    │
  │                   │  汇报Recovery结果             │                    │
  │                   │                              │                    │
  │                   │──finalizeFile()              │                    │
  │                   │  关闭文件，释放Lease           │                    │
```

#### 3.3.3 Soft Limit 抢占场景

```
Client_A (停止续约)    Client_B (新Client)      NameNode
    ╳                       │                     │
    │                       │                     │
    │            [60秒后]    │                     │
    │                       │──create(same_file)──→│
    │                       │                     │──getLease(Client_A)
    │                       │                     │  lease.expiredSoftLimit()? YES
    │                       │                     │──internalReleaseLease()
    │                       │                     │  (recovery or close)
    │                       │                     │──addLease("Client_B", id)
    │                       │←─────OK─────────────│
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：HBase WAL 文件 Lease 冲突

```
现象: HBase RegionServer RS1 宕机，RS2 尝试恢复 WAL 文件时报错
错误: AlreadyBeingCreatedException: Failed to create file 
      /hbase/WALs/rs1/rs1.xxx for DFSClient_RS2 because this file 
      lease is currently owned by DFSClient_RS1

原因: RS1 崩溃后，其 Lease 尚未过期（Hard Limit 60分钟）
```

#### 场景2：Lease Recovery 陷入死循环

```
现象: NameNode 日志中持续出现
      "DIR* NameSystem.internalReleaseLease: File xxx has not been closed. 
       Lease recovery is in progress."
      且 Block Recovery 一直不成功

原因: 最后一个 Block 的所有副本所在 DataNode 都宕机了
      Block Recovery 无法完成（没有可用的 DataNode 参与同步）
```

#### 场景3：文件无法关闭（COMMITTED 状态卡住）

```
现象: internalReleaseLease 抛出 
      "Committed blocks are waiting to be minimally replicated. Try again later."

原因: 最后一个 Block 状态为 COMMITTED，但副本数未达到最小副本数要求
      可能是多个 DataNode 同时故障
```

### 4.2 排障步骤

#### Step 1: 查看当前 Lease 状态

```bash
# 通过 NameNode Web UI 查看（默认 50070 端口）
# 或使用 hdfs debug recoverLease 命令
hdfs debug recoverLease -path /path/to/file -retries 3

# 查看 NameNode 日志中的 Lease 相关信息
grep -E "LeaseManager|internalReleaseLease|recoverLease|Block Recovery" \
  $HADOOP_LOG_DIR/hadoop-hdfs-namenode-*.log | tail -50
```

#### Step 2: 检查文件 Block 状态

```bash
# 查看文件的 Block 详情
hdfs fsck /path/to/file -files -blocks -locations

# 查看 Under Construction 文件列表
hdfs dfsadmin -listOpenFiles
```

#### Step 3: 强制恢复

```bash
# 如果 Lease Recovery 卡住，可以强制回收
# 方法1：使用 hdfs debug
hdfs debug recoverLease -path /path/to/file -retries 10

# 方法2：调用 DFSClient.recoverLease (编程方式)
# FileSystem fs = FileSystem.get(conf);
# ((DistributedFileSystem)fs).recoverLease(new Path("/path/to/file"));

# 方法3：极端情况下，可临时缩短 Hard Limit
# 在 hdfs-site.xml 中设置（不建议在生产环境永久修改）
# dfs.namenode.lease-hard-limit-sec = 60
```

### 4.3 关键参数调优

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `LEASE_SOFTLIMIT_PERIOD` | 60s (硬编码) | Soft Limit，其他Client可抢占 | 不可配置，需改源码 |
| `LEASE_HARDLIMIT_PERIOD` | 60min (硬编码) | Hard Limit，NameNode强制回收 | 不可配置，需改源码 |
| `dfs.namenode.lease-recheck-interval-ms` | 2000 | Monitor检查频率 | 生产环境保持默认 |
| `dfs.namenode.max-lock-hold-to-release-lease-ms` | 25000 | 单次检查最大持锁时间 | 大集群可适当增大 |
| LeaseRenewer renewal | 30s (SoftLimit/2) | Client续约频率 | 不建议修改 |

---

## 五、举一反三

### 5.1 与其他系统的类比（类比迁移法）

| 概念 | HDFS Lease | Kafka | ZooKeeper | OS文件系统 |
|------|-----------|-------|-----------|-----------|
| 写锁 | Lease | Partition Leader | 临时节点 | flock / fcntl |
| 超时机制 | Soft/Hard Limit | session.timeout.ms | Session Timeout | 文件锁超时 |
| 续约 | LeaseRenewer (30s) | Heartbeat (3s) | Session Ping | N/A |
| 故障检测 | Monitor线程 | Controller | Session Tracker | 无（进程退出自动释放） |
| 恢复机制 | Lease/Block Recovery | Leader Election | 临时节点删除+Watcher | 无 |

### 5.2 面试高频题

**Q1: HDFS 的 Soft Lease 和 Hard Lease 有什么区别？**

> Soft Limit（60秒）过期后，**其他 Client** 可以通过调用 `recoverLease()` 来抢占该文件的写权限。在此之前，只有 Lease 持有者可以写入。
> Hard Limit（60分钟）过期后，**NameNode 的 Monitor 线程** 会自动强制回收 Lease，触发 Lease Recovery 流程。
> 设计思想：两层超时 = 给 Client 留出恢复时间 + 系统兜底保证不死锁。

**Q2: Client 崩溃后，HDFS 如何保证数据一致性？**

> 1. NameNode 发现 Hard Limit 过期，触发 `internalReleaseLease()`
> 2. 对最后一个 Block（状态为 UNDER_CONSTRUCTION），启动 Block Recovery
> 3. NameNode 分配新的 Generation Stamp，选一个 DataNode 为 Primary
> 4. Primary 收集所有副本的 Block 信息，计算最小 Block 长度
> 5. Primary 将所有副本截断到最小长度，更新 GS
> 6. Primary 向 NameNode 汇报，NameNode 关闭文件
> 7. 结果：所有副本长度一致，丢失的是最后一个 Block 中未同步完成的部分

**Q3: 为什么 LeaseRenewer 的续约间隔是 30 秒而不是 59 秒？**

> 续约间隔 = Soft Limit / 2 = 30秒。这样设计留出了**一倍的安全裕量**：
> 即使一次续约因网络原因失败，Client 还有 30 秒时间重试，不会导致 Soft Limit 过期。
> 这是分布式系统中常见的"**半周期续约**"策略。

**Q4: LeaseManager 为什么要维护三个数据结构？**

> - `leases` (holder → Lease)：Client 续约时按 holder 查找，O(log n)
> - `sortedLeases` (按时间排序)：Monitor 检查过期时从最老的开始，O(1) 取最老
> - `leasesById` (INodeID → Lease)：按文件查 Lease，O(log n)
> 三个索引覆盖了三种查询场景，空间换时间。

**Q5: Block Recovery 的 Generation Stamp 有什么作用？**

> Generation Stamp (GS) 是 Block 的"版本号"。Block Recovery 时分配新 GS 的作用：
> 1. **过滤过期数据**：持有旧 GS 的 DataNode 如果后来上线，其 Block 不会被接受
> 2. **标记 Recovery 操作**：所有参与 Recovery 的 DataNode 都更新为新 GS
> 3. **防止脑裂**：如果崩溃的 Client 重新上线尝试写入（持有旧 GS），写入会被拒绝

### 5.3 思考题（留给学生）

1. **思考题1**：如果 NameNode 在 Lease Recovery 过程中也崩溃了（HA 切换到 Standby），Recovery 流程会怎样？Standby 接管后如何恢复到正确状态？

2. **思考题2**：如果一个 Client 同时打开了 100 个文件进行写入，它持有几个 Lease？续约时需要发送几次 RPC？

3. **思考题3**：在源码中，`checkLeases()` 有一个 `isMaxLockHoldToReleaseLease` 的检查。为什么要限制持锁时间？如果不限制会有什么后果？

4. **思考题4**：Lease 的 Soft/Hard Limit 是硬编码的常量，无法通过配置修改。你认为这是好的设计还是不好的设计？如果让你改进，你会怎么做？

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                    HDFS Lease 管理与文件恢复 — 知识晶体                           │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 问题/场景                                                                        │
│   HDFS 如何保证同一时刻只有一个 Client 写入文件？Client 崩溃后如何恢复？          │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 核心源码                                                                         │
│   LeaseManager.java     → Lease 增删改查 + Monitor 线程                          │
│   FSNamesystem.java     → internalReleaseLease() 状态机                          │
│   LeaseRenewer.java     → Client 端 30 秒续约                                    │
│   HdfsConstants.java    → SOFT_LIMIT=60s, HARD_LIMIT=60min                      │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 调用链                                                                           │
│   写入: create() → addLease() → [LeaseRenewer 30s续约] → close() → removeLease() │
│   回收: Monitor(2s) → checkLeases() → internalReleaseLease()                     │
│         → [COMPLETE: 关闭] / [COMMITTED: 检查副本数] / [UC: Block Recovery]       │
│   Block Recovery: 分配新GS → 选Primary DN → 收集信息 → 截断同步 → 关闭           │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 设计意图                                                                         │
│   1. 写互斥: 同一文件同一时刻只有一个 writer                                      │
│   2. 防死锁: Soft+Hard 两层超时保证 Lease 最终被回收                              │
│   3. 数据一致: Block Recovery 通过 GS + 截断到最小长度 保证副本一致                │
│   4. 性能: 三索引数据结构，空间换时间                                              │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 关键参数                                                                         │
│   Soft Limit=60s | Hard Limit=60min | Renew=30s | Monitor=2s | MaxLockHold=25s  │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 踩坑记录                                                                         │
│   1. HBase WAL Lease 冲突：等 Hard Limit 过期或手动 recoverLease                  │
│   2. Block Recovery 死循环：所有副本 DN 宕机，无法完成 Recovery                     │
│   3. COMMITTED 卡住：副本数不足，需先恢复 DataNode                                 │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 认知更新                                                                         │
│   Lease != 分布式锁，它是有超时的"写权限租约"                                     │
│   Block Recovery 的核心是"截断到最小公共长度"，而非"选最长副本"                    │
│   monotonicNow() 防时钟回拨，是分布式系统的标准实践                                │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/LeaseManager.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java` (L3193-3327)
   - `hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/protocol/HdfsConstants.java` (L96-117)
   - `hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/client/impl/LeaseRenewer.java`

2. **官方文档**
   - [HDFS Architecture Guide](https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-hdfs/HdfsDesign.html)
   - [HDFS Lease Recovery Design](https://issues.apache.org/jira/browse/HDFS-2083)

3. **相关 JIRA**
   - HDFS-4882: Lease Recovery 改进
   - HDFS-7215: Block Recovery 优化
   - HDFS-9801: Lease Recheck Interval 可配置化

4. **前置知识**
   - S02-BlockManager块管理源码分析（Block 状态机）
   - S03-HDFS写入流水线Pipeline源码分析（写入流程）
