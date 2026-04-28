# [教案] DataNode 退役与磁盘管理源码分析

> 🎯 教学目标：掌握 DataNode 退役（Decommission）完整流程、磁盘故障检测与热插拔机制、退役期间的 Block 迁移调度 | ⏰ 预计学时: 80分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：快递仓库关闭搬迁

想象一家快递公司有 100 个仓库（DataNode），其中一个仓库因为租约到期要关闭（退役/Decommission）。你不能直接关门了事——仓库里还有几万件包裹（Block）！

正确的做法是：
1. **通知总部**（NameNode）：这个仓库要关了
2. **盘点货物**：清点仓库里所有包裹
3. **逐批搬运**：把包裹搬到其他仓库，确保每种包裹至少还有 3 份副本
4. **检查确认**：所有包裹搬完了吗？有没有遗漏？
5. **正式关闭**：确认无误后才能关门

这就是 HDFS DataNode 退役的核心流程。而磁盘管理则是另一个场景——仓库里的某个货架（磁盘）坏了，需要在**不停止仓库运营**的前提下更换货架。

### 生产故障场景

> "运维小哥把 datanode-03 加入了 dfs.hosts.exclude 开始退役，结果 3 天了退役状态一直是 'Decommission In Progress'，怎么都完不成。去看日志发现有 200 个 block 只剩 1 个副本，且那个唯一副本就在正在退役的节点上……"

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| **Decommission** | 退役，将 DataNode 优雅下线 | 仓库有序关闭搬迁 |
| **Decommission In Progress** | 退役进行中，Block 还在搬运 | 搬家进行中 |
| **Decommissioned** | 退役完成，所有 Block 已迁移 | 搬家完毕，可以关门 |
| **DecommissionManager** | NameNode 中管理退役流程的组件 | 搬家公司的调度中心 |
| **FsVolumeList** | DataNode 中管理所有磁盘卷的组件 | 仓库的货架清单 |
| **FsDatasetImpl** | DataNode 的数据集实现，管理所有 Block 存储 | 仓库的库存管理系统 |
| **VolumeFailureInfo** | 磁盘故障信息 | 货架损坏报告 |
| **Hot Swap** | 热插拔，运行时添加/移除磁盘 | 不停业换货架 |
| **dfs.hosts.exclude** | 配置退役节点列表的文件 | 要关闭的仓库清单 |

### 2.2 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                  DataNode 退役全景图                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  管理员操作                                                  │
│  ┌─────────────────────────────────────┐                    │
│  │ 1. 编辑 dfs.hosts.exclude            │                    │
│  │ 2. hdfs dfsadmin -refreshNodes       │                    │
│  └─────────────┬───────────────────────┘                    │
│                │                                             │
│                ▼                                             │
│  NameNode                                                    │
│  ┌─────────────────────────────────────┐                    │
│  │  DatanodeManager                    │                    │
│  │    ├─ refreshNodes() ─────┐         │                    │
│  │    │                      ▼         │                    │
│  │    │  DecommissionManager           │                    │
│  │    │    ├─ startDecommission(dn)    │                    │
│  │    │    ├─ Monitor (定时线程)        │                    │
│  │    │    │   ├─ processPendingNodes() │                    │
│  │    │    │   ├─ check()              │                    │
│  │    │    │   │   ├─ handleInsufficiently│                  │
│  │    │    │   │   │   Replicated()     │                    │
│  │    │    │   │   ├─ pruneSufficiently │                    │
│  │    │    │   │   │   Replicated()     │                    │
│  │    │    │   │   └─ setDecommissioned()│                   │
│  │    │    │   └─────────────────────── │                    │
│  │    │    └─────────────────────────── │                    │
│  │    └─────────────────────────────── │                    │
│  └─────────────────────────────────────┘                    │
│                │                                             │
│                │ 心跳下发复制命令                             │
│                ▼                                             │
│  DataNode (退役中)                DataNode (目标)            │
│  ┌──────────────────┐            ┌──────────────────┐       │
│  │ Block A, B, C... │──复制──>   │ Block A', B'...  │       │
│  │ (源数据)          │            │ (新副本)          │       │
│  └──────────────────┘            └──────────────────┘       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 核心类 | 文件路径 | 职责 |
|--------|----------|------|
| `DecommissionManager` | `server/blockmanagement/DecommissionManager.java` | 管理退役流程，后台线程定期检查 |
| `DatanodeDescriptor` | `server/blockmanagement/DatanodeDescriptor.java` | DataNode 在 NameNode 中的描述对象 |
| `DatanodeManager` | `server/blockmanagement/DatanodeManager.java` | DataNode 管理入口 |
| `HeartbeatManager` | `server/blockmanagement/HeartbeatManager.java` | 心跳管理，更新 DN 状态 |
| `FsVolumeList` | `server/datanode/fsdataset/impl/FsVolumeList.java` | DataNode 端磁盘卷管理 |
| `FsDatasetImpl` | `server/datanode/fsdataset/impl/FsDatasetImpl.java` | DataNode 数据集实现 |
| `VolumeFailureInfo` | `server/datanode/fsdataset/impl/VolumeFailureInfo.java` | 磁盘故障信息 |

### 3.2 关键方法逐行解读

#### 3.2.1 退役启动 — startDecommission()

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DecommissionManager.java
// 行号: 199-217

@VisibleForTesting
public void startDecommission(DatanodeDescriptor node) {
    // 只有当节点既不是"退役中"也不是"已退役"时，才开始退役
    if (!node.isDecommissionInProgress() && !node.isDecommissioned()) {
        // 1. 通知 HeartbeatManager 更新 DN 的管理状态
        //    这会将节点标记为 DECOMMISSION_INPROGRESS
        //    注意：如果节点已死亡，hbManager 会直接标记为 DECOMMISSIONED
        hbManager.startDecommission(node);
        
        // 2. 只有活着的节点才需要走"退役进行中"流程
        if (node.isDecommissionInProgress()) {
            for (DatanodeStorageInfo storage : node.getStorageInfos()) {
                LOG.info("Starting decommission of {} {} with {} blocks",
                    node, storage, storage.numBlocks());
            }
            // 3. 记录退役开始时间
            node.decommissioningStatus.setStartTime(monotonicNow());
            // 4. 加入待处理队列，等待 Monitor 线程处理
            pendingNodes.add(node);
        }
    } else {
        LOG.trace("startDecommission: Node {} in {}, nothing to do." +
            node, node.getAdminState());
    }
}
```

**关键设计点：**
- **死节点直接退役**：如果 DN 已经死了，不需要等 Block 迁移，直接标记为 Decommissioned
- **活节点进入等待队列**：先加入 `pendingNodes`，由 Monitor 线程异步处理

#### 3.2.2 Monitor 线程 — 退役检查的核心

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DecommissionManager.java
// 行号: 339-498（Monitor 内部类）

private class Monitor implements Runnable {
    private final int numBlocksPerCheck;      // 每轮最多检查多少个 Block
    private final int numNodesPerCheck;       // 每轮最多检查多少个节点
    private final int maxConcurrentTrackedNodes; // 最大并发跟踪节点数

    @Override
    public void run() {
        if (!namesystem.isRunning()) {
            return;  // NameNode 没运行就跳过
        }
        // 重置计数器
        numBlocksChecked = 0;
        numNodesChecked = 0;
        
        // 关键：持有 namesystem 写锁！
        namesystem.writeLock();
        try {
            // 1. 把 pendingNodes 中的节点转移到 decomNodeBlocks
            processPendingNodes();
            // 2. 检查每个退役中节点的 Block 复制状态
            check();
        } finally {
            namesystem.writeUnlock();
        }
    }

    /**
     * 核心检查逻辑：遍历退役节点，检查其 Block 是否已充分复制
     */
    private void check() {
        // CyclicIteration：从上次停止的位置继续遍历
        // 这是为了避免总是检查同一批节点
        final Iterator<Map.Entry<DatanodeDescriptor, AbstractList<BlockInfo>>>
            it = new CyclicIteration<>(decomNodeBlocks, iterkey).iterator();
        final LinkedList<DatanodeDescriptor> toRemove = new LinkedList<>();

        while (it.hasNext()
            && !exceededNumBlocksPerCheck()     // 没超过 Block 检查上限
            && !exceededNumNodesPerCheck()       // 没超过节点检查上限
            && namesystem.isRunning()) {
            
            numNodesChecked++;
            final Map.Entry<DatanodeDescriptor, AbstractList<BlockInfo>> entry = it.next();
            final DatanodeDescriptor dn = entry.getKey();
            AbstractList<BlockInfo> blocks = entry.getValue();
            
            if (blocks == null) {
                // 新加入的节点，做全量扫描
                LOG.debug("Newly-added node {}, doing full scan", dn);
                blocks = handleInsufficientlyReplicated(dn);
                decomNodeBlocks.put(dn, blocks);
            } else {
                // 已知节点，裁剪已充分复制的 Block
                pruneSufficientlyReplicated(dn, blocks);
            }
            
            if (blocks.size() == 0) {
                // 所有 Block 都充分复制了！
                // 再做一次全量扫描确认
                blocks = handleInsufficientlyReplicated(dn);
                decomNodeBlocks.put(dn, blocks);
                
                if (blocks.size() == 0 && 
                    blockManager.isNodeHealthyForDecommission(dn)) {
                    // ✅ 退役完成！
                    setDecommissioned(dn);
                    toRemove.add(dn);
                }
            }
            iterkey = dn;
        }
        // 移除已完成退役的节点
        for (DatanodeDescriptor dn : toRemove) {
            decomNodeBlocks.remove(dn);
        }
    }
}
```

#### 3.2.3 充分复制判断 — isSufficientlyReplicated()

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DecommissionManager.java
// 行号: 252-287

private boolean isSufficientlyReplicated(BlockInfo block,
    BlockCollection bc, NumberReplicas numberReplicas) {
    final int numExpected = block.getReplication();  // 期望副本数（通常3）
    final int numLive = numberReplicas.liveReplicas(); // 当前存活副本数
    
    // 情况1：副本够了，且放置策略满足（跨机架）
    if (numLive >= numExpected
        && blockManager.isPlacementPolicySatisfied(block)) {
        return true;
    }

    // 情况2：副本不够，但是...
    if (numExpected > numLive) {
        if (bc.isUnderConstruction() && block.equals(bc.getLastBlock())) {
            // 2a. 正在写入的文件的最后一个块
            // 只要活副本 >= minReplication（默认1），就可以退役
            if (numLive >= blockManager.minReplication) {
                return true;
            }
        } else {
            // 2b. 普通块：只要活副本 >= defaultReplication（默认3），就OK
            if (numLive >= blockManager.defaultReplication) {
                return true;
            }
        }
    }
    return false;
}
```

**这就是退役卡住的常见原因**：如果某些 Block 的副本数始终达不到要求（比如源节点是唯一副本），退役就永远完不成。

#### 3.2.4 磁盘管理 — FsVolumeList 故障检测

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/FsVolumeList.java
// 行号: 50-75

class FsVolumeList {
    // 使用 CopyOnWriteArrayList 保证并发安全
    // 读多写少的场景非常适合
    private final CopyOnWriteArrayList<FsVolumeImpl> volumes =
        new CopyOnWriteArrayList<>();
    
    // 跟踪磁盘故障信息，按卷路径排序
    private final Map<String, VolumeFailureInfo> volumeFailureInfos =
        Collections.synchronizedMap(new TreeMap<String, VolumeFailureInfo>());
    
    // 正在被移除的卷（热移除）
    private final ConcurrentLinkedQueue<FsVolumeImpl> volumesBeingRemoved =
        new ConcurrentLinkedQueue<>();

    /**
     * 选择卷存储新 Block
     * 支持按 StorageType（DISK/SSD/ARCHIVE/RAM_DISK）筛选
     */
    FsVolumeReference getNextVolume(StorageType storageType, long blockSize)
        throws IOException {
        final List<FsVolumeImpl> list = new ArrayList<>(volumes.size());
        for (FsVolumeImpl v : volumes) {
            if (v.getStorageType() == storageType) {
                list.add(v);
            }
        }
        return chooseVolume(list, blockSize);
    }
}
```

#### 3.2.5 磁盘故障检测流程

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/FsVolumeList.java
// (checkDirs 方法概要)

/**
 * 磁盘健康检查
 * 由 DataNode 定期调用（默认 dfs.datanode.disk.check.interval = 5min）
 */
void checkDirs() throws DiskErrorException {
    // 遍历所有卷，检查是否可访问
    for (FsVolumeImpl volume : volumes) {
        try {
            volume.checkDirs();  // 实际检查磁盘 I/O
        } catch (DiskErrorException e) {
            // 磁盘故障！
            // 1. 记录故障信息
            volumeFailureInfos.put(volume.getBasePath(),
                new VolumeFailureInfo(volume.getBasePath(), Time.now()));
            // 2. 从活跃卷列表中移除
            removeVolume(volume);
            // 3. 触发 Block 汇报更新
            // 4. 通过心跳告知 NameNode
        }
    }
}
```

### 3.3 调用链时序图

```
管理员                 NameNode                    DataNode(退役中)      DataNode(目标)
  |                       |                            |                    |
  |--refreshNodes()------>|                            |                    |
  |                       |                            |                    |
  |                       |--startDecommission(dn)     |                    |
  |                       |  pendingNodes.add(dn)      |                    |
  |                       |                            |                    |
  |                 [Monitor线程每30s运行一次]           |                    |
  |                       |                            |                    |
  |                       |--processPendingNodes()     |                    |
  |                       |  pendingNodes→decomNodeBlocks                   |
  |                       |                            |                    |
  |                       |--handleInsufficiently      |                    |
  |                       |  Replicated(dn)            |                    |
  |                       |  遍历dn上所有Block         |                    |
  |                       |  发现under-replicated      |                    |
  |                       |  加入neededReplications    |                    |
  |                       |                            |                    |
  |              [ReplicationMonitor执行复制]           |                    |
  |                       |                            |                    |
  |                       |---心跳应答:复制Block A---->|                    |
  |                       |                            |---复制Block A----->|
  |                       |                            |                    |
  |                       |<--心跳:Block A复制完成------|                    |
  |                       |                            |                    |
  |                 [下一轮Monitor检查]                  |                    |
  |                       |                            |                    |
  |                       |--pruneSufficiently         |                    |
  |                       |  Replicated(dn, blocks)    |                    |
  |                       |  Block A已充分复制→移除     |                    |
  |                       |                            |                    |
  |              [所有Block都充分复制后]                 |                    |
  |                       |                            |                    |
  |                       |--setDecommissioned(dn) ✅   |                    |
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：退役卡在 "Decommission In Progress"

```bash
# 症状：退役 3 天都没完成
$ hdfs dfsadmin -report | grep "Decommission"
Decommission Status : Decommission in progress

# 排障步骤：
# 1. 查看还有多少 Block 未复制
$ hdfs dfsadmin -report | grep -A5 "datanode-03"
# Under replicated blocks: 200
# Blocks with no live replicas: 5   ← 这就是卡住的原因！

# 2. 查看具体哪些 Block 有问题
$ hdfs fsck / -blocks -locations | grep "MISSING"
/data/important.txt: MISSING 1 blocks of total size 128MB

# 3. 解决方案：
# a) 如果文件不重要，删除文件
$ hdfs dfs -rm /data/important.txt

# b) 如果文件重要但副本确实只有1个，设置较低的复制因子
$ hdfs dfs -setrep -w 1 /data/important.txt

# c) 强制退役（丢数据风险！慎用）
# 修改 dfs.namenode.replication.min=0
```

#### 场景2：磁盘故障导致 DataNode 退出

```bash
# 症状：DataNode 日志中出现
ERROR fsdataset.impl.FsDatasetImpl: Removing failed volume /data/dn/disk3

# 排障步骤：
# 1. 检查磁盘状态
$ df -h /data/dn/disk3
$ smartctl -a /dev/sdc

# 2. 检查容忍的故障磁盘数
# dfs.datanode.failed.volumes.tolerated 默认=0（一个磁盘坏就退出DN）
# 建议设置为总磁盘数的 1/3

# 3. 热插拔新磁盘
$ hdfs dfsadmin -reconfig datanode host:port start
```

### 4.2 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.namenode.decommission.interval` | 30s | Monitor 检查间隔 |
| `dfs.namenode.decommission.blocks.per.interval` | 500000 | 每轮检查的最大 Block 数 |
| `dfs.namenode.decommission.max.concurrent.tracked.nodes` | 100 | 最大并发跟踪退役节点数 |
| `dfs.datanode.failed.volumes.tolerated` | 0 | 容忍的磁盘故障数（建议改为磁盘数/3） |
| `dfs.datanode.disk.check.interval` | 300000ms | 磁盘健康检查间隔 |
| `dfs.hosts.exclude` | (空) | 退役节点列表文件路径 |
| `dfs.namenode.replication.min` | 1 | 最小复制因子（影响退役完成条件） |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 系统 | HDFS Decommission | Kafka Broker 下线 | Ceph OSD 下线 |
|------|-------------------|-------------------|---------------|
| 触发方式 | exclude 文件 + refreshNodes | kafka-reassign-partitions | ceph osd out |
| 数据迁移 | NameNode 调度复制 | 分区重分配 | CRUSH 自动 rebalance |
| 完成条件 | 所有 Block 充分复制 | 所有分区迁移完成 | PG 全部 active+clean |
| 监控方式 | dfsadmin -report | reassignment status | ceph -w |

### 5.2 面试高频题

**Q1: DataNode 退役流程是什么？**

A: 1) 管理员将节点加入 exclude 文件并刷新；2) NameNode 标记节点为 Decommission In Progress；3) Monitor 线程定期检查节点上的 Block，将副本不足的加入复制队列；4) ReplicationMonitor 调度实际复制；5) 所有 Block 充分复制后标记为 Decommissioned。

**Q2: 退役卡住的常见原因和解决方法？**

A: 原因：某些 Block 的唯一存活副本就在退役节点上（under-replicated with 0 live replicas on other nodes）。解决：检查 fsck 找出问题 Block，删除无用文件或降低复制因子。

**Q3: dfs.datanode.failed.volumes.tolerated 为什么默认是 0？生产中应该怎么设？**

A: 默认0是最保守的安全策略，一个磁盘坏就停掉整个DN，防止数据不一致。生产中如果DN有12块盘，建议设为3-4，容忍部分磁盘故障而不中断服务。

### 5.3 思考题

1. **如果在退役过程中 NameNode 重启了，退役状态会丢失吗？怎么恢复？**
2. **DecommissionManager.Monitor 为什么要使用 CyclicIteration 而不是普通遍历？**
3. **FsVolumeList 为什么用 CopyOnWriteArrayList 而不是 synchronized List？**

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────┐
│           DataNode 退役与磁盘管理知识晶体                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  退役流程:                                                   │
│  exclude文件 → refreshNodes → startDecommission             │
│    → Monitor定期检查 → 调度Block复制 → 全部充分复制           │
│    → setDecommissioned ✅                                    │
│                                                             │
│  核心类: DecommissionManager.Monitor (30s一轮)               │
│    - processPendingNodes(): 待处理→跟踪中                    │
│    - check(): 遍历退役节点，检查Block复制状态                │
│    - isSufficientlyReplicated(): 判断Block是否可以退役      │
│                                                             │
│  退役卡住原因: Block仅有副本在退役节点上                     │
│  解决: fsck → 删文件/降replication/手动处理                  │
│                                                             │
│  磁盘管理:                                                   │
│  FsVolumeList: CopyOnWriteArrayList管理磁盘卷               │
│  故障检测: 定期checkDirs → DiskErrorException → 移除卷      │
│  容忍参数: dfs.datanode.failed.volumes.tolerated            │
│  热插拔: hdfs dfsadmin -reconfig datanode                    │
│                                                             │
│  生产关键参数:                                               │
│    decommission.interval=30s                                │
│    decommission.blocks.per.interval=500000                  │
│    failed.volumes.tolerated=磁盘数/3                        │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DecommissionManager.java` (Hadoop 2.8.5)
2. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/FsVolumeList.java`
3. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeDescriptor.java`
4. [HDFS Decommission 官方文档](https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsDataNodeAdminGuide.html)
5. [HDFS-6791: 退役中死节点处理](https://issues.apache.org/jira/browse/HDFS-6791)
