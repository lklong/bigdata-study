# S02-BlockManager 块管理源码分析

> **组件版本**: Apache Hadoop 3.x (基于 txProjects/hadoop 源码)
> **源码路径**: `hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/`
> **核心类**: `BlockManager`、`BlockPlacementPolicyDefault`、`BlocksMap`、`UnderReplicatedBlocks`
> **分析日期**: 2026-04-27

---

## 一、问题/场景

### 1.1 核心问题
- BlockManager 在 NameNode 中扮演什么角色？
- 块和 DataNode 之间的映射关系如何维护？
- 副本放置策略的三副本规则是怎么实现的？
- Under-Replicated Block 是如何被发现和修复的？

### 1.2 典型生产场景
- DataNode 宕机后副本数不足，BlockManager 如何调度复制
- 新写入文件时副本如何放置到不同机架
- 集群扩容后副本再平衡的底层机制

---

## 二、BlockManager 核心数据结构

### 2.1 类层级关系

```
BlockManager (主入口)
 ├── BlocksMap                       // Block → {BlockCollection, DatanodeStorageInfo[]} 映射
 ├── DatanodeManager                 // DataNode 管理（心跳、注册、退役）
 │    └── HeartbeatManager           // 心跳管理
 ├── BlockPlacementPolicy            // 副本放置策略接口
 │    └── BlockPlacementPolicyDefault // 默认实现（机架感知）
 ├── UnderReplicatedBlocks           // 副本不足的 Block 优先级队列
 ├── PendingReplicationBlocks        // 正在复制中的 Block
 ├── InvalidateBlocks                // 待删除的 Block
 ├── CorruptReplicasMap              // 损坏副本映射
 ├── ExcessReplicateMap              // 多余副本映射
 └── ReplicationMonitor              // 副本复制监控线程
```

### 2.2 核心字段 (来自源码)

```java
// 文件: BlockManager.java, 行 196-255
// Block → { BlockCollection, datanodes, self ref } 映射
final BlocksMap blocksMap;

// 副本复制线程
final Daemon replicationThread = new Daemon(new ReplicationMonitor());

// 损坏副本映射
final CorruptReplicasMap corruptReplicas = new CorruptReplicasMap();

// 待删除的 Block
private final InvalidateBlocks invalidateBlocks;

// 推迟处理的错误副本
private final LinkedHashSet<Block> postponedMisreplicatedBlocks = new LinkedHashSet<>();

// 多余副本映射: StorageID → Set<Block>
public final Map<String, LightWeightHashSet<Block>> excessReplicateMap = new HashMap<>();

// 副本不足的 Block 队列（优先级队列）
public final UnderReplicatedBlocks neededReplications = new UnderReplicatedBlocks();

// 正在复制中的 Block
final PendingReplicationBlocks pendingReplications;

// 最大副本数 / 最大复制流数 / 最小副本数
public final short maxReplication;
int maxReplicationStreams;
int replicationStreamsHardLimit;
public final short minReplication;
```

---

## 三、调用链总览

### 3.1 BlockManager 激活流程

```
FSNamesystem.startCommonServices()
  └── blockManager.activate(conf)
        ├── pendingReplications.start()        // 启动 pending 超时检测
        ├── datanodeManager.activate(conf)     // 启动 DataNode 管理
        ├── replicationThread.start()          // ★ 启动 ReplicationMonitor
        └── blockReportThread.start()          // 启动块报告处理线程
```

```java
// 文件: BlockManager.java, 行 504-511
public void activate(Configuration conf) {
    pendingReplications.start();
    datanodeManager.activate(conf);
    this.replicationThread.setName("ReplicationMonitor");
    this.replicationThread.start();
    this.blockReportThread.start();
    mxBeanName = MBeans.register("NameNode", "BlockStats", this);
}
```

### 3.2 addStoredBlock 调用链

```
DataNode 心跳/块报告
  → NameNodeRpcServer.blockReport() / sendHeartbeat()
    → BlockManager.processReport()
      → reportDiff()
        → addStoredBlock(block, storageInfo, delHintNode, logEveryBlock)
          ├── storageInfo.addBlock(storedBlock)        // 更新 DatanodeStorageInfo
          ├── namesystem.incrementSafeBlockCount()     // 安全模式计数
          ├── completeBlock()                          // Block 完成检查
          ├── updateNeededReplications()               // 更新副本需求
          └── processOverReplicatedBlock()             // 处理多余副本
```

### 3.3 removeStoredBlock 调用链

```
DataNode 故障/退役
  → BlockManager.removeStoredBlock(block, node)
      ├── blocksMap.removeNode(storedBlock, node)    // 从映射中移除
      ├── 清理缓存相关列表
      ├── namesystem.decrementSafeBlockCount()       // 安全模式计数
      └── updateNeededReplications(storedBlock, -1, 0)  // ★ 加入 neededReplications 队列
```

---

## 四、核心源码分析

### 4.1 addStoredBlock — 块存储注册

```java
// 文件: BlockManager.java, 行 2654-2753
private Block addStoredBlock(final BlockInfo block,
                             DatanodeStorageInfo storageInfo,
                             DatanodeDescriptor delNodeHint,
                             boolean logEveryBlock)
throws IOException {
    assert block != null && namesystem.hasWriteLock();
    BlockInfo storedBlock;
    DatanodeDescriptor node = storageInfo.getDatanodeDescriptor();
    if (!block.isComplete()) {
      storedBlock = blocksMap.getStoredBlock(block);
    } else {
      storedBlock = block;
    }
    if (storedBlock == null || storedBlock.isDeleted()) {
      // Block 不属于任何文件，跳过
      blockLog.debug("BLOCK* addStoredBlock: {} on {} size {} but it does not"
          + " belong to any file", block, node, block.getNumBytes());
      return block;
    }

    // ★ 核心：将 Block 添加到 DatanodeStorageInfo
    AddBlockResult result = storageInfo.addBlock(storedBlock);

    int curReplicaDelta;
    if (result == AddBlockResult.ADDED) {
      curReplicaDelta = (node.isDecommissioned()) ? 0 : 1;
    } else if (result == AddBlockResult.REPLACED) {
      curReplicaDelta = 0;
    } else {
      // 冗余请求，清理可能的错误标记
      corruptReplicas.removeFromCorruptReplicasMap(block, node,
          Reason.GENSTAMP_MISMATCH);
      curReplicaDelta = 0;
    }

    // ★ 检查 Block 是否可以从 COMMITTED 变为 COMPLETE
    NumberReplicas num = countNodes(storedBlock);
    int numLiveReplicas = num.liveReplicas();
    int numCurrentReplica = numLiveReplicas
        + pendingReplications.getNumReplicas(storedBlock);

    if (storedBlock.getBlockUCState() == BlockUCState.COMMITTED
        && numLiveReplicas >= minReplication) {
      addExpectedReplicasToPending(storedBlock);
      completeBlock(storedBlock, null, false);    // Block 完成！
    } else if (storedBlock.isComplete() && result == AddBlockResult.ADDED) {
      // ★ 安全模式：增加安全块计数
      namesystem.incrementSafeBlockCount(numCurrentReplica);
    }

    if (!storedBlock.isCompleteOrCommitted()) {
      return storedBlock;  // 正在构建中，暂不处理
    }

    // 安全模式中不处理副本问题
    if (!isPopulatingReplQueues()) {
      return storedBlock;
    }

    // ★ 副本不足处理
    short fileReplication = getExpectedReplicaNum(storedBlock);
    if (!isNeededReplication(storedBlock, numCurrentReplica)) {
      neededReplications.remove(storedBlock, numCurrentReplica,
          num.readOnlyReplicas(),
          num.decommissionedAndDecommissioning(), fileReplication);
    } else {
      updateNeededReplications(storedBlock, curReplicaDelta, 0);
    }
    // ★ 副本过多处理
    if (numCurrentReplica > fileReplication) {
      processOverReplicatedBlock(storedBlock, fileReplication, node, delNodeHint);
    }
}
```

**设计意图**:
- `addStoredBlock` 是一个**中心枢纽方法**，每当有新的块-DataNode 映射关系时都会调用
- 它同时处理：块完成状态转换、安全模式计数、副本不足/过多检测
- 通过 `curReplicaDelta` 追踪增量变化，避免全量重算

### 4.2 removeStoredBlock — 块存储移除

```java
// 文件: BlockManager.java, 行 3108-3153
public void removeStoredBlock(Block block, DatanodeDescriptor node) {
    blockLog.debug("BLOCK* removeStoredBlock: {} from {}", block, node);
    assert (namesystem.hasWriteLock());
    {
      BlockInfo storedBlock = getStoredBlock(block);
      if (storedBlock == null || !blocksMap.removeNode(storedBlock, node)) {
        blockLog.debug("BLOCK* removeStoredBlock: {} has already been"
            + " removed from node {}", block, node);
        return;
      }

      // 清理缓存相关信息
      CachedBlock cblock = namesystem.getCacheManager().getCachedBlocks()
          .get(new CachedBlock(block.getBlockId(), (short) 0, false));
      if (cblock != null) {
        boolean removed = false;
        removed |= node.getPendingCached().remove(cblock);
        removed |= node.getCached().remove(cblock);
        removed |= node.getPendingUncached().remove(cblock);
      }

      // ★ Block 仍然有效时，更新安全模式计数和副本需求
      if (!storedBlock.isDeleted()) {
        namesystem.decrementSafeBlockCount(storedBlock);
        updateNeededReplications(storedBlock, -1, 0);  // 副本减少 1，可能需要补副本
      }

      // 从多余副本映射中移除
      LightWeightHashSet<Block> excessBlocks = excessReplicateMap.get(
          node.getDatanodeUuid());
      if (excessBlocks != null) {
        if (excessBlocks.remove(block)) {
          excessBlocksCount.decrementAndGet();
        }
      }
    }
}
```

**关键点**: `updateNeededReplications(storedBlock, -1, 0)` — 当一个副本被移除后，可能导致副本数低于期望值，此方法会检查并加入 `neededReplications` 队列。

---

## 五、副本放置策略 — BlockPlacementPolicyDefault

### 5.1 三副本放置规则

默认的三副本放置策略 `chooseTargetInOrder` 实现了经典的机架感知策略：

```java
// 文件: BlockPlacementPolicyDefault.java, 行 447-493
protected Node chooseTargetInOrder(int numOfReplicas,
                               Node writer,
                               final Set<Node> excludedNodes,
                               final long blocksize,
                               final int maxNodesPerRack,
                               final List<DatanodeStorageInfo> results,
                               final boolean avoidStaleNodes,
                               final boolean newBlock,
                               EnumMap<StorageType, Integer> storageTypes)
                               throws NotEnoughReplicasException {
    final int numOfResults = results.size();
    
    // ★ 第1个副本: 本地节点（Writer 所在节点）
    if (numOfResults == 0) {
      writer = chooseLocalStorage(writer, excludedNodes, blocksize,
          maxNodesPerRack, results, avoidStaleNodes, storageTypes, true)
          .getDatanodeDescriptor();
      if (--numOfReplicas == 0) {
        return writer;
      }
    }
    
    final DatanodeDescriptor dn0 = results.get(0).getDatanodeDescriptor();
    
    // ★ 第2个副本: 远程机架上的节点
    if (numOfResults <= 1) {
      chooseRemoteRack(1, dn0, excludedNodes, blocksize, maxNodesPerRack,
          results, avoidStaleNodes, storageTypes);
      if (--numOfReplicas == 0) {
        return writer;
      }
    }
    
    // ★ 第3个副本: 取决于前两个副本的位置
    if (numOfResults <= 2) {
      final DatanodeDescriptor dn1 = results.get(1).getDatanodeDescriptor();
      if (clusterMap.isOnSameRack(dn0, dn1)) {
        // 如果前两个在同机架，第3个选远程机架
        chooseRemoteRack(1, dn0, excludedNodes, blocksize, maxNodesPerRack,
            results, avoidStaleNodes, storageTypes);
      } else if (newBlock) {
        // 新块：第3个选与第2个副本同机架
        chooseLocalRack(dn1, excludedNodes, blocksize, maxNodesPerRack,
            results, avoidStaleNodes, storageTypes);
      } else {
        // 追加：第3个选与 Writer 同机架
        chooseLocalRack(writer, excludedNodes, blocksize, maxNodesPerRack,
            results, avoidStaleNodes, storageTypes);
      }
      if (--numOfReplicas == 0) {
        return writer;
      }
    }
    
    // ★ 第4个及以上副本: 随机选择
    chooseRandom(numOfReplicas, NodeBase.ROOT, excludedNodes, blocksize,
        maxNodesPerRack, results, avoidStaleNodes, storageTypes);
    return writer;
}
```

### 5.2 副本放置策略示意图

```
三副本放置规则 (默认 replication=3):

  Rack-1                    Rack-2                    Rack-3
  ┌──────────┐              ┌──────────┐              ┌──────────┐
  │ DN-1     │              │ DN-3     │              │ DN-5     │
  │ [副本1]  │◄─── Writer  │ [副本2]  │              │          │
  │          │              │          │              │          │
  │ DN-2     │              │ DN-4     │              │ DN-6     │
  │          │              │ [副本3]  │              │          │
  └──────────┘              └──────────┘              └──────────┘

规则:
  副本1 → Writer 本地节点 (DN-1)
  副本2 → 远程机架的某个节点 (DN-3, Rack-2)
  副本3 → 与副本2同机架的另一个节点 (DN-4, Rack-2)

好处:
  - 跨机架分布，防止整个机架故障
  - 第3个副本与第2个同机架，减少跨机架写入
  - 读取时本地有一个副本，延迟低
```

### 5.3 chooseLocalStorage — 本地节点选择

```java
// 文件: BlockPlacementPolicyDefault.java, 行 495-532
protected DatanodeStorageInfo chooseLocalStorage(Node localMachine,
    Set<Node> excludedNodes, long blocksize, int maxNodesPerRack,
    List<DatanodeStorageInfo> results, boolean avoidStaleNodes,
    EnumMap<StorageType, Integer> storageTypes)
    throws NotEnoughReplicasException {
    // 没有本地节点则随机选
    if (localMachine == null) {
      return chooseRandom(NodeBase.ROOT, excludedNodes, blocksize,
          maxNodesPerRack, results, avoidStaleNodes, storageTypes);
    }
    if (preferLocalNode && localMachine instanceof DatanodeDescriptor
        && clusterMap.contains(localMachine)) {
      DatanodeDescriptor localDatanode = (DatanodeDescriptor) localMachine;
      // 检查本地节点是否合适
      if (excludedNodes.add(localMachine)
          && isGoodDatanode(localDatanode, maxNodesPerRack, false,
              results, avoidStaleNodes)) {
        for (Iterator<Map.Entry<StorageType, Integer>> iter = storageTypes
            .entrySet().iterator(); iter.hasNext(); ) {
          Map.Entry<StorageType, Integer> entry = iter.next();
          DatanodeStorageInfo localStorage = chooseStorage4Block(
              localDatanode, blocksize, results, entry.getKey());
          if (localStorage != null) {
            addToExcludedNodes(localDatanode, excludedNodes);
            return localStorage;
          }
        }
      }
    }
    return null;
}
```

---

## 六、ReplicationMonitor — 副本修复核心

### 6.1 ReplicationMonitor 运行循环

```java
// 文件: BlockManager.java, 行 3738-3769
private class ReplicationMonitor implements Runnable {
    @Override
    public void run() {
      while (namesystem.isRunning()) {
        try {
          // 只在 Active NN 退出安全模式后才执行
          if (isPopulatingReplQueues()) {
            computeDatanodeWork();             // ★ 计算复制/删除任务
            processPendingReplications();       // ★ 检查超时的复制任务
            rescanPostponedMisreplicatedBlocks(); // ★ 重扫推迟的错误副本
          }
          Thread.sleep(replicationRecheckInterval);  // 默认 3 秒
        } catch (Throwable t) {
          if (!namesystem.isRunning()) {
            LOG.info("Stopping ReplicationMonitor.");
            break;
          }
          LOG.error("ReplicationMonitor thread received Runtime exception. ", t);
          terminate(1, t);
        }
      }
    }
}
```

### 6.2 computeDatanodeWork — 计算副本复制和删除任务

```java
// 文件: BlockManager.java, 行 3779-3806
int computeDatanodeWork() {
    // 安全模式中不执行
    if (namesystem.isInSafeMode()) {
      return 0;
    }

    final int numlive = heartbeatManager.getLiveDatanodeCount();
    // ★ 每轮处理的块数 = 存活DN数 × 乘数（默认2）
    final int blocksToProcess = numlive * this.blocksReplWorkMultiplier;
    // ★ 每轮处理的节点数 = 存活DN数 × 比例（默认32%）
    final int nodesToProcess = (int) Math.ceil(numlive * this.blocksInvalidateWorkPct);

    int workFound = this.computeReplicationWork(blocksToProcess);

    namesystem.writeLock();
    try {
      this.updateState();
      this.scheduledReplicationBlocksCount = workFound;
    } finally {
      namesystem.writeUnlock();
    }
    workFound += this.computeInvalidateWork(nodesToProcess);
    return workFound;
}
```

### 6.3 副本修复完整流程

```
DataNode-X 故障
  │
  ├── HeartbeatManager 检测到心跳超时
  │   └── DatanodeManager.removeDatanode(dn)
  │       └── BlockManager.removeBlocksAssociatedTo(dn)
  │           └── 对 dn 上的每个 block 调用 removeStoredBlock()
  │               └── updateNeededReplications(block, -1, 0)
  │                   └── 将 block 加入 neededReplications 队列
  │
  ├── ReplicationMonitor 周期性执行 (每 3 秒)
  │   └── computeDatanodeWork()
  │       └── computeReplicationWork(blocksToProcess)
  │           ├── 从 neededReplications 队列取出优先级最高的 block
  │           ├── 选择 source DataNode (已有副本的存活节点)
  │           ├── 调用 BlockPlacementPolicy.chooseTarget() 选择 target
  │           └── 创建复制任务，通知 target DataNode
  │
  └── Target DataNode 心跳时获取复制命令
      └── DataNode 从 Source 拉取 Block 数据
      └── 复制完成后报告给 NameNode
          └── addStoredBlock() → 更新映射 → 从 neededReplications 移除
```

---

## 七、UnderReplicatedBlocks — 优先级队列

`neededReplications` 是一个按优先级排序的队列，共 5 个优先级：

| 优先级 | 含义 | 说明 |
|--------|------|------|
| 0 (QUEUE_HIGHEST_PRIORITY) | 只有 1 个副本的 Block | 最紧急，随时可能丢失 |
| 1 (QUEUE_VERY_UNDER_REPLICATED) | 副本数严重不足 | 存活副本 < 预期的 1/3 |
| 2 (QUEUE_UNDER_REPLICATED) | 副本数不足 | 存活副本 < 预期值 |
| 3 (QUEUE_REPLICAS_BADLY_DISTRIBUTED) | 副本分布不合理 | 副本数够但机架分布不好 |
| 4 (QUEUE_WITH_CORRUPT_BLOCKS) | 有损坏副本的 Block | 需要修复 |

`ReplicationMonitor` 按优先级从高到低处理，确保最关键的 Block 最先被修复。

---

## 八、BlocksMap — 核心映射数据结构

### 8.1 设计概述

```
BlocksMap 内部使用 LightWeightGSet (类 HashMap 结构):

  Key: Block (blockId + generationStamp)
  Value: BlockInfo
          ├── BlockCollection (所属文件 INode)
          └── DatanodeStorageInfo[] (存储该 Block 的 DataNode 列表)
              ├── DatanodeStorageInfo-1 (DN-1, StorageType=DISK)
              ├── DatanodeStorageInfo-2 (DN-3, StorageType=SSD)
              └── DatanodeStorageInfo-3 (DN-4, StorageType=DISK)
```

```java
// 文件: BlockManager.java, 行 332-333
blocksMap = new BlocksMap(
    LightWeightGSet.computeCapacity(2.0, "BlocksMap"));
```

**内存优化**: `LightWeightGSet` 是 Hadoop 自研的轻量级哈希集合，相比 `HashMap`：
- 不需要 Entry 对象包装，直接使用数组
- 内存开销减少 ~40%
- 容量默认为 JVM 堆内存的 2%

### 8.2 BlockInfo 的三元组链表

`BlockInfo` 继承自 `Block`，额外维护了一个三元组链表（triplet array）：

```
BlockInfo.triplets[]:
  [DatanodeStorageInfo-0, prev-BlockInfo-0, next-BlockInfo-0,
   DatanodeStorageInfo-1, prev-BlockInfo-1, next-BlockInfo-1,
   DatanodeStorageInfo-2, prev-BlockInfo-2, next-BlockInfo-2]

  其中每3个元素为一组:
    triplets[3*i]   = 第 i 个副本的 DatanodeStorageInfo
    triplets[3*i+1] = 该 DataNode 上的上一个 BlockInfo (链表前驱)
    triplets[3*i+2] = 该 DataNode 上的下一个 BlockInfo (链表后继)
```

**设计精妙之处**: 通过三元组链表，一个 BlockInfo 对象同时维护了：
1. Block → DataNode 的正向映射（第 i 个副本在哪个 DN）
2. DataNode → Block 的反向链表（方便遍历某个 DN 上的所有 Block）

**内存效率**: 不需要额外的 `Map<DataNode, List<Block>>` 结构。

---

## 九、关键参数与调优建议

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `dfs.namenode.replication.max-streams` | 2 | 每个 DN 最大同时复制流数 | 大集群可调到 6-10 |
| `dfs.namenode.replication.max-streams-hard-limit` | 4 | 含最高优先级的最大复制流数 | 大集群可调到 12 |
| `dfs.namenode.replication.work.multiplier.per.iteration` | 2 | 每轮复制块数乘数 | 大集群可调到 4-10 |
| `dfs.namenode.invalidate.work.pct.per.iteration` | 0.32 | 每轮删除节点比例 | 通常不改 |
| `dfs.namenode.replication.interval` | 3s | ReplicationMonitor 检查间隔 | 通常不改 |
| `dfs.block.placement.ec.classname` | - | EC 放置策略类 | EC 场景需配置 |
| `dfs.replication` | 3 | 默认副本数 | 根据需求调整 |
| `dfs.namenode.replication.min` | 1 | 最小写入副本数 | 通常不改 |

### 调优场景

**场景 1: DataNode 批量退役时复制速度慢**
```xml
<property>
  <name>dfs.namenode.replication.max-streams</name>
  <value>8</value>
</property>
<property>
  <name>dfs.namenode.replication.max-streams-hard-limit</name>
  <value>16</value>
</property>
<property>
  <name>dfs.namenode.replication.work.multiplier.per.iteration</name>
  <value>10</value>
</property>
```

**场景 2: 监控关键指标**
```bash
# 查看 Under-Replicated Blocks 数量
hdfs dfsadmin -report | grep "Under replicated"

# 查看 Missing Blocks
hdfs fsck / -blocks | grep "Missing"

# 查看 BlockManager 指标
curl http://<namenode>:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem | jq '.beans[0].UnderReplicatedBlocks'
```

---

## 十、踩坑记录

### 坑 1: isPopulatingReplQueues 的双重含义
`isPopulatingReplQueues()` 在安全模式中返回 `false`，导致 `addStoredBlock` 中不会处理副本不足/过多的逻辑。只有退出安全模式后，ReplicationMonitor 才真正工作。这是**设计意图**而非 Bug — 安全模式期间块报告尚未完成，此时判断副本数不准确。

### 坑 2: 副本放置策略的 Stale Node 回退
当 `chooseTarget` 由于避开 Stale Node 导致找不到足够副本时，会**自动回退**为不避开 Stale Node 重试一次。这意味着在大量 DataNode 心跳延迟的场景下，可能往心跳不稳定的节点写入数据。

### 坑 3: postponedMisreplicatedBlocks 积压
HA 切换后，新 Active NameNode 会将所有错误副本放入 `postponedMisreplicatedBlocks`，等所有 DataNode 都发送了块报告后才处理。如果某个 DataNode 长时间不发送块报告，这个列表会一直积压，影响副本修复进度。

### 坑 4: BlocksMap 内存开销
`BlocksMap` 是 NameNode 最大的内存消耗者之一。每个 Block 的 `BlockInfo` 对象加三元组链表约占 ~150 字节。1 亿个 Block 就需要 ~15GB 内存。这是大集群 NameNode 需要大堆内存的核心原因之一。

---

## 十一、认知更新

1. **BlockManager 是 NameNode 的"心脏"**: 几乎所有与 Block 相关的操作都要经过它
2. **addStoredBlock 是一个多功能枢纽方法**: 不只是添加映射，还处理块完成、安全模式、副本均衡
3. **三元组链表是一个精妙的内存优化设计**: 用一个数组同时维护正向和反向映射
4. **ReplicationMonitor 是被动触发的**: 它不主动扫描所有块，而是处理 `neededReplications` 队列中被标记的块
5. **副本放置策略是可插拔的**: 通过 `dfs.block.replicator.classname` 配置，可以替换为自定义实现
6. **安全模式是 BlockManager 的"暂停键"**: 安全模式期间副本管理逻辑暂停，退出后才全面启动
