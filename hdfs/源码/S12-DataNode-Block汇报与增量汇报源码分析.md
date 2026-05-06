# [教案] DataNode Block 汇报与增量汇报源码分析

> 🎯 教学目标：掌握全量 Block Report 与增量 Block Report (IBR) 机制、BlockReportLeaseManager 租约管理、NameNode 处理 Block Report 流程 | ⏰ 预计学时: 75分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：仓库库存盘点

想象你是一家快递公司的总部（NameNode），下面有 1000 个仓库（DataNode）。你需要知道每个仓库里有哪些包裹（Block）。

有两种盘点方式：
1. **全量盘点（Full Block Report）**：每隔 6 小时，每个仓库把完整的库存清单发给总部。清单可能有几百万条记录，非常大！
2. **增量盘点（Incremental Block Report / IBR）**：每次有包裹入库或出库，仓库立即把变更通知总部——"Block-123 刚入库了"、"Block-456 被删除了"。

问题来了：如果 1000 个仓库同时发全量清单，总部会被"淹没"。所以需要一个**排队机制（Block Report Lease）**——总部一次只让 6 个仓库发全量清单，其他的排队等。

### 生产故障场景

> "NameNode 每隔 6 小时就会出现一次 CPU 飙升到 100%、RPC 队列堆积的情况，持续 10-20 分钟。经排查发现是所有 DataNode 的 Block Report 集中到达，NameNode 串行处理导致。调整了 Block Report 的 Lease 并发数和初始延迟后问题解决。"

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| **Full Block Report (FBR)** | 全量块汇报，DataNode 汇报所有持有的 Block | 仓库完整库存清单 |
| **Incremental Block Report (IBR)** | 增量块汇报，只汇报变更的 Block | 实时出入库通知 |
| **BlockReportLease** | 块汇报租约，控制并发全量汇报数 | 盘点排队号 |
| **BlockReportLeaseManager** | 租约管理器，分配和管理租约 | 排队叫号系统 |
| **BPServiceActor** | DataNode 的服务线程，负责与一个 NN 通信 | 仓库的通讯员 |
| **IncrementalBlockReportManager** | 增量汇报管理器 | 实时变更记录员 |
| **ReceivedDeletedBlockInfo** | IBR 中一条记录（收到/删除/正在接收） | 出入库单据 |
| **StorageBlockReport** | 按存储分组的块汇报 | 按货架分类的库存清单 |
| **BlockReportContext** | 汇报上下文（报告 ID、总份数、当前序号） | 清单封面（第几页/共几页） |

### 2.2 汇报机制全景图

```
┌─────────────────────────────────────────────────────────────────┐
│                    Block Report 全景图                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  DataNode                                                        │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  BPServiceActor (每个 NN 一个)                        │       │
│  │                                                      │       │
│  │  ┌─────────────────┐    ┌──────────────────────┐    │       │
│  │  │ 心跳循环 (3s)     │    │ IncrementalBlock      │    │       │
│  │  │                   │    │ ReportManager         │    │       │
│  │  │ 1. sendHeartbeat  │    │                       │    │       │
│  │  │    (请求BR Lease) │    │ pendingIBRs:           │    │       │
│  │  │                   │    │  storage1→[blk1,blk2] │    │       │
│  │  │ 2. 收到Lease后    │    │  storage2→[blk3]      │    │       │
│  │  │    blockReport()  │    │                       │    │       │
│  │  │                   │    │ sendIBRs():            │    │       │
│  │  │ 3. 定期发送 IBR   │    │  blockReceivedAnd     │    │       │
│  │  │                   │    │  Deleted()            │    │       │
│  │  └─────────────────┘    └──────────────────────┘    │       │
│  └──────────────────────────────────────────────────────┘       │
│                          │                                       │
│                          │ RPC                                    │
│                          ▼                                       │
│  NameNode                                                        │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  ┌────────────────────┐                              │       │
│  │  │BlockReportLease    │                              │       │
│  │  │Manager             │                              │       │
│  │  │                    │                              │       │
│  │  │ maxPending=6       │  ┌─────────────────────┐    │       │
│  │  │ deferredList:      │  │ BlockManager         │    │       │
│  │  │  [DN4,DN5,DN6...] │  │  .processReport()    │    │       │
│  │  │ pendingList:       │  │  - 遍历每个Block     │    │       │
│  │  │  [DN1,DN2,DN3]    │  │  - 对比现有状态       │    │       │
│  │  └────────────────────┘  │  - 触发复制/删除     │    │       │
│  │                          └─────────────────────┘    │       │
│  └──────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 核心类 | 文件路径 | 职责 |
|--------|----------|------|
| `BPServiceActor` | `server/datanode/BPServiceActor.java` | DataNode→NN 的通信线程 |
| `IncrementalBlockReportManager` | `server/datanode/IncrementalBlockReportManager.java` | 管理 IBR 待发送队列 |
| `BlockReportLeaseManager` | `server/blockmanagement/BlockReportLeaseManager.java` | NN 端管理 BR 租约 |
| `BlockManager` | `server/blockmanagement/BlockManager.java` | 处理 Block Report |

### 3.2 关键方法逐行解读

#### 3.2.1 BPServiceActor — 心跳与汇报主循环

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/BPServiceActor.java
// 行号: 548-668 (offerService方法)

private void offerService() throws Exception {
    LOG.info("For namenode " + nnAddr + " using"
        + " BLOCKREPORT_INTERVAL of " + dnConf.blockReportInterval + "msec"
        + " CACHEREPORT_INTERVAL of " + dnConf.cacheReportInterval + "msec"
        + " Initial delay: " + dnConf.initialBlockReportDelayMs + "msec"
        + "; heartBeatInterval=" + dnConf.heartBeatInterval);
    
    long fullBlockReportLeaseId = 0;

    while (shouldRun()) {
        try {
            final long startTime = scheduler.monotonicNow();
            final boolean sendHeartbeat = scheduler.isHeartbeatDue(startTime);
            HeartbeatResponse resp = null;
            
            if (sendHeartbeat) {
                // ★ 关键1：请求 Block Report 租约
                // 只有满足两个条件才请求：1) 还没有租约 2) BR时间到了
                boolean requestBlockReportLease = 
                    (fullBlockReportLeaseId == 0) &&
                    scheduler.isBlockReportDue(startTime);
                
                if (!dn.areHeartbeatsDisabledForTests()) {
                    // ★ 发送心跳，同时请求BR租约
                    resp = sendHeartBeat(requestBlockReportLease);
                    
                    // ★ 如果NN返回了租约ID，保存下来
                    if (resp.getFullBlockReportLeaseId() != 0) {
                        fullBlockReportLeaseId = 
                            resp.getFullBlockReportLeaseId();
                    }
                    
                    // 处理NN下发的命令
                    if (!processCommand(resp.getCommands()))
                        continue;
                }
            }
            
            // ★ 关键2：发送增量汇报 (IBR)
            // 两种触发条件：有紧急变更 或 刚发过心跳
            if (ibrManager.sendImmediately() || sendHeartbeat) {
                ibrManager.sendIBRs(bpNamenode, bpRegistration,
                    bpos.getBlockPoolId(), dn.getMetrics());
            }

            // ★ 关键3：发送全量汇报 (FBR)
            // 拿到租约 或 被强制触发时才发送
            List<DatanodeCommand> cmds = null;
            boolean forceFullBr =
                scheduler.forceFullBlockReport.getAndSet(false);
            if ((fullBlockReportLeaseId != 0) || forceFullBr) {
                cmds = blockReport(fullBlockReportLeaseId);
                fullBlockReportLeaseId = 0;  // 用完租约清零
            }
            
            // 等待下一次心跳
            ibrManager.waitTillNextIBR(scheduler.getHeartbeatWaitTime());
            
        } catch (RemoteException re) {
            // 处理异常...
        }
    }
}
```

#### 3.2.2 全量 Block Report 发送流程

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/BPServiceActor.java
// 行号: 327-410 (blockReport方法)

List<DatanodeCommand> blockReport(long fullBrLeaseId) throws IOException {
    final ArrayList<DatanodeCommand> cmds = new ArrayList<>();

    // ★ 关键：在发送FBR之前，先把IBR flush掉！
    // 否则可能出现：IBR 报告删除了 Block A，但 FBR 还报告持有 Block A
    ibrManager.sendIBRs(bpNamenode, bpRegistration,
        bpos.getBlockPoolId(), dn.getMetrics());

    // 1. 构建每个存储卷的 Block 列表
    long brCreateStartTime = monotonicNow();
    Map<DatanodeStorage, BlockListAsLongs> perVolumeBlockLists =
        dn.getFSDataset().getBlockReports(bpos.getBlockPoolId());

    // 2. 转换为 StorageBlockReport 数组
    int totalBlockCount = 0;
    StorageBlockReport reports[] =
        new StorageBlockReport[perVolumeBlockLists.size()];
    int i = 0;
    for (Map.Entry<DatanodeStorage, BlockListAsLongs> kvPair 
            : perVolumeBlockLists.entrySet()) {
        BlockListAsLongs blockList = kvPair.getValue();
        reports[i++] = new StorageBlockReport(kvPair.getKey(), blockList);
        totalBlockCount += blockList.getNumberOfBlocks();
    }

    // 3. 发送报告（可能拆分为多个RPC）
    long reportId = generateUniqueBlockReportId();
    
    if (totalBlockCount < dnConf.blockReportSplitThreshold) {
        // ★ 小报告：一次RPC发送全部
        DatanodeCommand cmd = bpNamenode.blockReport(
            bpRegistration, bpos.getBlockPoolId(), reports,
            new BlockReportContext(1, 0, reportId, fullBrLeaseId));
        if (cmd != null) cmds.add(cmd);
    } else {
        // ★ 大报告：每个存储卷一个RPC
        // 这样即使一个卷的报告失败了，其他卷的不受影响
        for (int r = 0; r < reports.length; r++) {
            StorageBlockReport singleReport[] = { reports[r] };
            DatanodeCommand cmd = bpNamenode.blockReport(
                bpRegistration, bpos.getBlockPoolId(), singleReport,
                new BlockReportContext(reports.length, r, reportId,
                    fullBrLeaseId));
            if (cmd != null) cmds.add(cmd);
        }
    }

    // 4. 更新调度器，安排下一次BR
    scheduler.updateLastBlockReportTime(monotonicNow());
    scheduler.scheduleNextBlockReport();
    return cmds.size() == 0 ? null : cmds;
}
```

#### 3.2.3 BlockReportLeaseManager — 租约管理

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/BlockReportLeaseManager.java
// 行号: 54-354

class BlockReportLeaseManager {

    // ★ 双向链表结构
    // deferredHead: 等待获取租约的 DN（排队中）
    private final NodeData deferredHead = NodeData.ListHead("deferredHead");
    // pendingHead: 已持有租约的 DN（正在发送BR）
    private final NodeData pendingHead = NodeData.ListHead("pendingHead");
    
    // ★ 核心限制参数
    private final int maxPending;      // 最大并发租约数（默认6）
    private final long leaseExpiryMs;  // 租约过期时间（默认5分钟）
    
    /**
     * DN 请求租约
     * 返回非0表示获得租约，返回0表示需要等待
     */
    public synchronized long requestLease(DatanodeDescriptor dn) {
        NodeData node = nodes.get(dn.getDatanodeUuid());
        
        // 先清理过期的租约
        pruneExpiredPending(monotonicNowMs);
        
        // ★ 关键：如果当前持有租约的DN数 >= 最大并发数，拒绝
        if (numPending >= maxPending) {
            LOG.debug("Can't create BR lease for DN {}, " +
                "numPending equals maxPending at {}",
                dn.getDatanodeUuid(), numPending);
            return 0;  // 返回0，DN需要下次心跳再请求
        }
        
        // 分配租约
        numPending++;
        node.leaseId = getNextId();
        node.leaseTimeMs = monotonicNowMs;
        pendingHead.addToEnd(node);  // 加入持有租约的链表
        
        return node.leaseId;
    }

    /**
     * 验证租约是否有效
     * NN 收到 Block Report 时调用
     */
    public synchronized boolean checkLease(DatanodeDescriptor dn,
            long monotonicNowMs, long id) {
        if (id == 0) {
            // ★ 租约ID=0：绕过限流（手动触发的BR、旧版DN）
            return true;
        }
        
        NodeData node = nodes.get(dn.getDatanodeUuid());
        if (node == null || node.leaseId == 0) {
            return false;
        }
        
        // 检查是否过期
        if (pruneIfExpired(monotonicNowMs, node)) {
            LOG.warn("BR lease 0x{} expired for DN {}",
                Long.toHexString(id), dn.getDatanodeUuid());
            return false;
        }
        
        // 验证租约ID匹配
        return id == node.leaseId;
    }
}
```

#### 3.2.4 IncrementalBlockReportManager — 增量汇报

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/IncrementalBlockReportManager.java
// 行号: 47-270

class IncrementalBlockReportManager {
    
    // ★ 按 Storage 分组的 IBR 队列
    // 每个磁盘卷有独立的待发送 Block 变更列表
    private final Map<DatanodeStorage, PerStorageIBR> pendingIBRs
        = Maps.newHashMap();
    
    // 是否有紧急变更需要立即发送
    private volatile boolean readyToSend = false;
    
    // IBR 发送间隔（默认跟心跳间隔一致，约3s）
    private final long ibrInterval;

    /**
     * Block 变更通知入口
     * 当 DataNode 收到/删除一个 Block 时调用
     */
    synchronized void notifyNamenodeBlock(ReceivedDeletedBlockInfo rdbi,
            DatanodeStorage storage, boolean isOnTransientStorage) {
        addRDBI(rdbi, storage);

        final BlockStatus status = rdbi.getStatus();
        if (status == BlockStatus.RECEIVING_BLOCK) {
            // 正在接收中 → 下次心跳时发送
            readyToSend = true;
        } else if (status == BlockStatus.RECEIVED_BLOCK) {
            // 接收完成 → 立即触发发送！
            triggerIBR(isOnTransientStorage);
        }
    }

    /**
     * 生成IBR报告（加锁）
     * 从 pendingIBRs 中取出所有待发送的变更
     */
    private synchronized StorageReceivedDeletedBlocks[] generateIBRs() {
        final List<StorageReceivedDeletedBlocks> reports
            = new ArrayList<>(pendingIBRs.size());
        for (Map.Entry<DatanodeStorage, PerStorageIBR> entry
                : pendingIBRs.entrySet()) {
            // ★ removeAll(): 原子地取出所有待发送记录
            final ReceivedDeletedBlockInfo[] rdbi = 
                entry.getValue().removeAll();
            if (rdbi != null) {
                reports.add(new StorageReceivedDeletedBlocks(
                    entry.getKey(), rdbi));
            }
        }
        readyToSend = false;
        return reports.toArray(
            new StorageReceivedDeletedBlocks[reports.size()]);
    }

    /**
     * 发送IBR到NameNode
     * 如果发送失败，会把记录放回队列
     */
    void sendIBRs(DatanodeProtocol namenode, 
            DatanodeRegistration registration,
            String bpid, DataNodeMetrics metrics) throws IOException {
        // 1. 在锁内生成报告
        final StorageReceivedDeletedBlocks[] reports = generateIBRs();
        if (reports.length == 0) return;

        // 2. 在锁外发送（避免持锁时间过长）
        boolean success = false;
        try {
            namenode.blockReceivedAndDeleted(registration, bpid, reports);
            success = true;
        } finally {
            if (!success) {
                // ★ 发送失败，把记录放回队列重试
                putMissing(reports);
            }
        }
    }
}
```

### 3.3 调用链时序图

```
DataNode                        NameNode
BPServiceActor                  BlockReportLeaseManager    BlockManager
    |                                    |                      |
    |=== 心跳 (每3s) ===================>|                      |
    | requestBlockReportLease=true       |                      |
    |                                    |                      |
    |                                    |--requestLease()      |
    |                                    |  numPending<6 ?      |
    |                                    |  YES → 返回leaseId   |
    |<== HeartbeatResponse ==============|                      |
    |    fullBlockReportLeaseId=0x1234   |                      |
    |                                    |                      |
    |                                    |                      |
    |=== IBR flush =====================>|                      |
    | blockReceivedAndDeleted()          |                      |
    |                                    |                      |
    |=== Block Report ==================>|                      |
    | blockReport(leaseId=0x1234)        |                      |
    |                                    |--checkLease(0x1234)  |
    |                                    |  有效!                |
    |                                    |                      |
    |                                    |         processReport()
    |                                    |                      |
    |                                    |    遍历每个Block:     |
    |                                    |    - 已知Block? 更新  |
    |                                    |    - 新Block? 添加    |
    |                                    |    - 缺失Block? 标记  |
    |                                    |                      |
    |                                    |--removeLease(dn)     |
    |                                    |  numPending--        |
    |<== DatanodeCommand ===============|                      |
    |    (可能要求删除/复制某些Block)     |                      |
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：Block Report 风暴导致 NameNode 卡顿

```
# 症状：所有 DN 同时发 BR，NN RPC 队列爆满
WARN ipc.Server: IPC Server handler is taking long: 
  blockReport from DN xxx took 45000ms

# 原因：DN 重启后 initialBlockReportDelayMs 为0，集群重启时所有DN同时发BR

# 解决：
# 1. 增大初始BR延迟，让DN随机错开
dfs.blockreport.initialDelay = 120  # 秒，DN随机在0~120s内发第一次BR

# 2. 减少BR租约并发数（默认6）
dfs.namenode.max.full.block.report.leases = 4

# 3. 开启BR拆分（按存储卷拆分）
dfs.blockreport.split.threshold = 1000000  # Block数超过100万才拆分
```

#### 场景2：IBR 丢失导致 Block 状态不一致

```
# 症状：NN 认为某个 Block 已删除，但 DN 上还有
# fsck 显示 over-replicated blocks

# 原因：IBR 发送失败，但 DN 没有重试（极端情况）

# 解决：
# 1. 等待下一次全量 BR 自动修正（6小时）
# 2. 手动触发 BR
hdfs dfsadmin -triggerBlockReport <DN host:port>
```

### 4.2 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.blockreport.intervalMsec` | 21600000 (6h) | 全量 BR 间隔 |
| `dfs.blockreport.initialDelay` | 0 | 初始 BR 延迟（建议120s） |
| `dfs.blockreport.split.threshold` | 1000000 | BR 拆分阈值 |
| `dfs.namenode.max.full.block.report.leases` | 6 | 最大 BR 并发租约数 |
| `dfs.namenode.full.block.report.lease.length.ms` | 300000 (5min) | BR 租约过期时间 |
| `dfs.heartbeat.interval` | 3s | 心跳间隔（IBR跟随心跳） |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 机制 | HDFS Block Report | Kafka ISR | ZooKeeper Session |
|------|-------------------|-----------|-------------------|
| 全量同步 | Full BR (6h) | Full ISR sync (重启) | Snapshot |
| 增量同步 | IBR (实时) | ISR 变更通知 | Transaction Log |
| 并发控制 | Lease (限6个) | Controller Epoch | Session ID |
| 故障检测 | 心跳超时 | Heartbeat | Session Timeout |

### 5.2 面试高频题

**Q1: Full Block Report 和 Incremental Block Report 有什么区别？为什么需要两种？**

A: FBR 是全量快照（DN 上所有 Block 清单），IBR 是增量变更（收到/删除 Block 的实时通知）。需要两种是因为：IBR 可能丢失或遗漏，FBR 定期修正；但 FBR 数据量大不能太频繁，IBR 保证实时性。

**Q2: BlockReportLeaseManager 的作用是什么？为什么需要它？**

A: 限制同时发送 Full Block Report 的 DataNode 数量（默认6个）。因为处理 FBR 需要持有 NameNode 写锁，如果所有 DN 同时发 FBR，NameNode 会长时间持锁导致 RPC 超时。Lease 机制让 DN 排队有序发送。

**Q3: 为什么发送 FBR 之前要先 flush IBR？**

A: 避免状态不一致。例如：IBR 待发送 "Block-A 已删除"，FBR 中还包含 Block-A。如果先发 FBR 后发 IBR，NN 先添加再删除没问题；但如果 IBR 丢了，Block-A 就永远残留在 NN 中。先 flush IBR 确保 FBR 反映最新状态。

### 5.3 思考题

1. **如果一个 DataNode 有 500 万个 Block，Full Block Report 的 RPC 消息有多大？如何优化？**
2. **BlockReportLease 过期了会怎样？DN 需要重新请求吗？**
3. **如果 NameNode 在处理 Block Report 时重启了，会发生什么？**

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────┐
│         Block Report 与增量汇报知识晶体                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  两种汇报机制:                                               │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │ Full BR (全量)     │  │ IBR (增量)         │                │
│  │ 每6小时一次        │  │ 实时(Block变更时)   │                │
│  │ 数据量大           │  │ 数据量小            │                │
│  │ 需要Lease排队      │  │ 不需要Lease        │                │
│  │ 修正IBR遗漏        │  │ 保证实时性          │                │
│  └──────────────────┘  └──────────────────┘                │
│                                                             │
│  发送顺序: flush IBR → 发送 FBR (避免状态不一致)            │
│                                                             │
│  Lease机制 (BlockReportLeaseManager):                       │
│    DN心跳请求 → NN检查numPending<maxPending                  │
│    → 分配leaseId → DN发BR → NN验证lease → 处理 → 释放      │
│    默认: maxPending=6, 过期=5min                            │
│                                                             │
│  IBR管理 (IncrementalBlockReportManager):                   │
│    pendingIBRs: 按Storage分组的变更队列                     │
│    RECEIVING_BLOCK → 下次心跳发送                            │
│    RECEIVED_BLOCK → 立即触发发送                             │
│    发送失败 → putMissing() 放回队列重试                     │
│                                                             │
│  关键参数:                                                   │
│    blockreport.intervalMsec=6h (FBR间隔)                    │
│    blockreport.initialDelay=120s (初始延迟,防风暴)          │
│    max.full.block.report.leases=6 (并发限制)                │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/BPServiceActor.java` (行 327-668)
2. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/BlockReportLeaseManager.java` (全文 354 行)
3. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/IncrementalBlockReportManager.java` (全文 270 行)
4. [HDFS-9710: Block Report Lease 设计文档](https://issues.apache.org/jira/browse/HDFS-9710)
5. [HDFS-9917: Standby NN IBR 问题](https://issues.apache.org/jira/browse/HDFS-9917)
