# [教案] S08-HDFS Balancer数据均衡源码深度剖析

> 🎯 教学目标：掌握Balancer的启动策略、源/目标选择算法、带宽限制与迁移调度机制 | ⏰ 预计学时: 80分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：仓库货物均衡调度

想象一家连锁超市有10个仓库（DataNode），每个仓库存储不同数量的货物（Block）：
- 仓库A已经堆满了（使用率95%），仓库B几乎空着（使用率10%）
- 平均使用率是50%，你设定的容忍差异是10%（threshold）
- **Balancer就是调度员**：他的任务是把货物从"过满"的仓库搬到"过空"的仓库
- 搬运有**速度限制**（带宽限制），不能影响正常配送（不能影响正常读写）
- 搬运按**就近原则**：优先同机架搬运（网络开销小），再跨机架

### 生产故障场景

```
场景：新扩容了50个DataNode，但所有新节点都是空的
现象：- 新数据只写入新节点（因为空间多），老节点继续被读取
      - 集群存储不均衡，读取热点集中在老节点
      - 部分老节点磁盘使用率>90%，触发告警
解法：运行 hdfs balancer -threshold 5
      理解 Balancer 如何将数据从过载节点迁移到空闲节点
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| Threshold | 均衡阈值，默认10% | 容忍的仓库差异 |
| Average Utilization | 集群平均利用率 | 所有仓库的平均装载率 |
| Over-utilized | 利用率 > 平均+threshold | 严重过满的仓库 |
| Above-average | 平均 < 利用率 < 平均+threshold | 偏满但可接受的仓库 |
| Below-average | 平均-threshold < 利用率 < 平均 | 偏空但可接受的仓库 |
| Under-utilized | 利用率 < 平均-threshold | 严重过空的仓库 |
| Source | 数据迁出节点 | 需要搬出货物的仓库 |
| Target | 数据迁入节点 | 需要接收货物的仓库 |
| Dispatcher | 迁移任务调度器 | 调度搬运车队的调度中心 |
| Matcher | 源/目标匹配策略 | 优先同机架→同机房→跨机房 |
| MAX_SIZE_TO_MOVE | 每个节点每轮最大迁移量(默认10GB) | 每辆车一次最多搬多少 |

### 2.2 架构图

```
┌───────────────────────────────────────────────────────────────┐
│                        Balancer 进程                           │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                   Balancer.run()                          │  │
│  │  for (iteration=0; !done; iteration++) {                  │  │
│  │    1. init()           → 分类节点为4组                    │  │
│  │    2. chooseStorageGroups() → 匹配源/目标对               │  │
│  │    3. dispatcher.dispatchAndCheckContinue() → 执行迁移    │  │
│  │  }                                                        │  │
│  └─────────────────────────────────────────────────────────┘  │
│                          │                                     │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │                   Dispatcher                              │  │
│  │  - Source[] / Target[]                                    │  │
│  │  - 选择要移动的Block                                      │  │
│  │  - 通过DataTransfer协议在DataNode之间移动Block            │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
         │ getDatanodeStorageReports         │ Block迁移
         ▼                                   ▼
┌──────────────┐                  ┌───────────────────┐
│  NameNode     │                  │ DataNode A → DN B  │
│ 提供集群信息  │                  │ (DataTransfer协议)  │
└──────────────┘                  └───────────────────┘
```

### 2.3 节点分类示例

```
集群平均利用率: 60%    Threshold: 10%

Over-utilized  (>70%):   DN1(85%), DN2(78%)     ← 必须迁出数据
Above-average  (60-70%): DN3(65%), DN4(62%)     ← 可以迁出数据
Below-average  (50-60%): DN5(55%), DN6(52%)     ← 可以接收数据  
Under-utilized (<50%):   DN7(30%), DN8(15%)     ← 优先接收数据

匹配优先级:
  1. Over-utilized → Under-utilized  (最高优先)
  2. Over-utilized → Below-average
  3. Above-average → Under-utilized
  4. Above-average → Below-average   (最低优先)
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|---------|------|
| `Balancer` | `server/balancer/Balancer.java` | 均衡策略：节点分类、源/目标匹配 |
| `Dispatcher` | `server/balancer/Dispatcher.java` | 实际迁移调度：选Block、发起DataTransfer |
| `BalancerParameters` | 同包 | 命令行参数封装(threshold/include/exclude) |
| `BalancingPolicy` | 同包 | 均衡策略(DataNode级/BlockPool级) |
| `NameNodeConnector` | 同包 | 与NameNode通信 |

### 3.2 关键方法逐行解读

#### 3.2.1 Balancer.run()：主循环

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Balancer.java
// 行号: 667-710

static int run(Collection<URI> namenodes, final BalancerParameters p,
    Configuration conf) throws IOException, InterruptedException {
  // 迭代间休眠时间 = 2×heartbeat + replicationInterval
  final long sleeptime = conf.getLong(DFS_HEARTBEAT_INTERVAL_KEY, 3) * 2000 +
      conf.getLong(DFS_NAMENODE_REPLICATION_INTERVAL_KEY, 3) * 1000;

  boolean done = false;
  for(int iteration = 0; !done; iteration++) {
    done = true;
    for(NameNodeConnector nnc : connectors) {
      final Balancer b = new Balancer(nnc, p, conf);
      final Result r = b.runOneIteration();  // 执行一轮均衡
      r.print(iteration, System.out);
      
      // 判断是否继续
      if (r.exitStatus == ExitStatus.IN_PROGRESS) {
        done = false;  // 还有数据需要移动
      }
    }
    if (!done) {
      Thread.sleep(sleeptime);  // 休眠后继续下一轮
    }
  }
}
```

**教学要点**：
- 外层是无限循环，每轮执行 `runOneIteration()`
- 每轮之间休眠 `2×heartbeat + replicationInterval`，等待NameNode更新统计
- 支持多NameNode（Federation模式），逐个均衡

#### 3.2.2 runOneIteration()：单轮均衡

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Balancer.java
// 行号: 600-659

Result runOneIteration() {
  // 步骤1：获取集群信息并初始化
  final List<DatanodeStorageReport> reports = dispatcher.init();
  final long bytesLeftToMove = init(reports);
  
  if (bytesLeftToMove == 0) {
    System.out.println("The cluster is balanced. Exiting...");
    return newResult(ExitStatus.SUCCESS, bytesLeftToMove, 0);
  }
  
  // 步骤2：匹配源/目标对
  final long bytesBeingMoved = chooseStorageGroups();
  if (bytesBeingMoved == 0) {
    return newResult(ExitStatus.NO_MOVE_BLOCK, ...);
  }
  
  // 步骤3：执行数据迁移
  if (!dispatcher.dispatchAndCheckContinue()) {
    return newResult(ExitStatus.NO_MOVE_PROGRESS, ...);
  }
  
  return newResult(ExitStatus.IN_PROGRESS, bytesLeftToMove, bytesBeingMoved);
}
```

#### 3.2.3 init()：节点分类算法（核心！）

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Balancer.java
// 行号: 340-405

private long init(List<DatanodeStorageReport> reports) {
  // 第一步：计算集群平均利用率
  for (DatanodeStorageReport r : reports) {
    policy.accumulateSpaces(r);  // 累计总容量和已使用量
  }
  policy.initAvgUtilization();   // avgUtilization = totalUsed / totalCapacity

  // 第二步：将每个DataNode的每个StorageType分入4组
  long overLoadedBytes = 0L, underLoadedBytes = 0L;
  for(DatanodeStorageReport r : reports) {
    final DDatanode dn = dispatcher.newDatanode(r.getDatanodeInfo());
    
    for(StorageType t : StorageType.getMovableTypes()) {
      final Double utilization = policy.getUtilization(r, t);
      final double average = policy.getAvgUtilization(t);
      
      final double utilizationDiff = utilization - average;
      final double thresholdDiff = Math.abs(utilizationDiff) - threshold;
      final long maxSize2Move = computeMaxSize2Move(capacity, remaining,
          utilizationDiff, maxSizeToMove);

      if (utilizationDiff > 0) {
        // 利用率高于平均 → Source（数据迁出方）
        final Source s = dn.addSource(t, maxSize2Move, dispatcher);
        if (thresholdDiff <= 0) {
          aboveAvgUtilized.add(s);    // 平均~平均+threshold
        } else {
          overUtilized.add(s);         // > 平均+threshold
          overLoadedBytes += percentage2bytes(thresholdDiff, capacity);
        }
      } else {
        // 利用率低于平均 → Target（数据迁入方）
        final StorageGroup g = dn.addTarget(t, maxSize2Move);
        if (thresholdDiff <= 0) {
          belowAvgUtilized.add(g);    // 平均-threshold~平均
        } else {
          underUtilized.add(g);        // < 平均-threshold
          underLoadedBytes += percentage2bytes(thresholdDiff, capacity);
        }
      }
    }
  }
  
  return Math.max(overLoadedBytes, underLoadedBytes);
}
```

**教学要点**：
- 分类基于 `utilizationDiff = nodeUtilization - avgUtilization` 和 `threshold`
- 每个 StorageType 独立分类（DISK 和 SSD 分开均衡）
- `maxSize2Move` 限制了每个节点每轮的最大迁移量，防止过度迁移
- 返回值 `overLoadedBytes` 表示需要迁移的总字节数

#### 3.2.4 chooseCandidate()：源/目标匹配

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Balancer.java
// 行号: 536-548

C chooseCandidate(G g, Iterator<C> candidates, Matcher matcher) {
  if (g.hasSpaceForScheduling()) {
    for(; candidates.hasNext(); ) {
      final C c = candidates.next();
      if (!c.hasSpaceForScheduling()) {
        candidates.remove();     // 候选者已满/空，移除
      } else if (matchStorageGroups(c, g, matcher)) {
        return c;                 // 找到匹配的候选者
      }
    }
  }
  return null;
}

private boolean matchStorageGroups(StorageGroup left, StorageGroup right,
    Matcher matcher) {
  return left.getStorageType() == right.getStorageType()  // StorageType匹配
      && matcher.match(dispatcher.getCluster(),           // 拓扑匹配
          left.getDatanodeInfo(), right.getDatanodeInfo());
}
```

**教学要点**：
- Matcher 有三级匹配策略：SAME_RACK（同机架）→ ANY_OTHER（跨机架）
- 优先同机架迁移，减少跨机架网络流量
- StorageType 必须匹配（DISK→DISK, SSD→SSD）

#### 3.2.5 matchSourceWithTargetToMove()：创建迁移任务

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Balancer.java
// 行号: 524-532

private void matchSourceWithTargetToMove(Source source, StorageGroup target) {
  // 迁移量 = min(source可迁出量, target可接收量)
  long size = Math.min(source.availableSizeToMove(), target.availableSizeToMove());
  final Task task = new Task(target, size);
  source.addTask(task);
  target.incScheduledSize(task.getSize());
  dispatcher.add(source, target);
  LOG.info("Decided to move " + StringUtils.byteDesc(size) + " bytes from "
      + source.getDisplayName() + " to " + target.getDisplayName());
}
```

### 3.3 调用链时序图

```
Balancer                    NameNode                 DataNode A    DataNode B
   │                           │                        │             │
   │──getStorageReports()────→ │                        │             │
   │←─DatanodeStorageReport[]──│                        │             │
   │                           │                        │             │
   │  init():                  │                        │             │
   │  计算平均利用率            │                        │             │
   │  分类4组:                  │                        │             │
   │  overUtilized=[A(85%)]    │                        │             │
   │  underUtilized=[B(15%)]   │                        │             │
   │                           │                        │             │
   │  chooseStorageGroups():   │                        │             │
   │  A→B, 迁移5GB             │                        │             │
   │                           │                        │             │
   │  dispatcher.dispatch():   │                        │             │
   │──getBlocks(A, 5GB)──────→ │                        │             │
   │←─Block列表─────────────── │                        │             │
   │                           │                        │             │
   │  对每个Block:              │                        │             │
   │─────────────────────────────DataTransfer──────────→│             │
   │                           │                        │──copy────→│
   │                           │                        │             │
   │                           │←─blockReceived─────────┼─────────────│
   │                           │                        │             │
   │  本轮完成                  │                        │             │
   │  sleep(sleeptime)         │                        │             │
   │  继续下一轮...             │                        │             │
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：Balancer运行极慢
```
原因: 默认带宽限制仅 1MB/s (dfs.datanode.balance.bandwidthPerSec)
解法: hdfs dfsadmin -setBalancerBandwidth 104857600  # 设为100MB/s
```

#### 场景2：Balancer报 "No block can be moved"
```
原因: 所有可移动Block都在同一机架，Matcher无法找到跨机架目标
解法: 检查机架感知配置，确保include/exclude配置正确
```

#### 场景3：Balancer影响生产读写
```
原因: 带宽设置过高，DataNode数据传输线程被Balancer占满
解法: 控制 dfs.datanode.balance.max.concurrent.moves (默认50)
```

### 4.2 常用命令

```bash
# 启动Balancer
hdfs balancer -threshold 5

# 指定只均衡某些节点
hdfs balancer -threshold 5 -source dn1,dn2

# 排除某些节点
hdfs balancer -threshold 5 -exclude dn3,dn4

# 动态调整带宽（不需要重启）
hdfs dfsadmin -setBalancerBandwidth 52428800  # 50MB/s

# 查看均衡进度
tail -f /var/log/hadoop/balancer.log
```

### 4.3 关键参数调优

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `-threshold` | 10% | 均衡阈值 | 生产建议5-10% |
| `dfs.datanode.balance.bandwidthPerSec` | 1MB/s | 每DN带宽限制 | 根据网络提升到50-100MB/s |
| `dfs.balancer.max-size-to-move` | 10GB | 每DN每轮最大迁移量 | 大集群可增大 |
| `dfs.datanode.balance.max.concurrent.moves` | 50 | 每DN最大并发迁移数 | 根据磁盘IO调整 |
| `dfs.balancer.moverThreads` | 1000 | Balancer总线程数 | 大集群可增大 |
| `dfs.balancer.getBlocks.min-block-size` | 10MB | 忽略的小Block阈值 | 保持默认 |

---

## 五、举一反三

### 5.1 类比迁移

| 概念 | HDFS Balancer | Kafka | Elasticsearch | Ceph |
|------|--------------|-------|--------------|------|
| 均衡对象 | Block | Partition | Shard | PG |
| 触发方式 | 手动命令 | kafka-reassign | cluster.routing | 自动 |
| 均衡粒度 | DataNode级 | Broker级 | Node级 | OSD级 |
| 带宽限制 | bandwidthPerSec | throttle | indices.recovery.max_bytes_per_sec | osd_recovery_max_bandwidth |

### 5.2 面试高频题

**Q1: Balancer 的均衡策略是什么？**
> 计算集群平均利用率，将节点分为4组（over/above/below/under），按优先级匹配源→目标对，迁移数据直到所有节点利用率与平均值的差异 < threshold。

**Q2: 为什么 Balancer 默认带宽只有1MB/s？**
> 保守策略：避免影响生产读写。Balancer是后台任务，数据一致性和服务可用性优先。实际使用时通常会调高到50-100MB/s。

**Q3: Balancer 如何保证不破坏副本放置策略？**
> 迁移Block时会检查BlockPlacementPolicy，确保迁移后仍满足机架感知等副本放置要求。匹配时优先SAME_RACK再ANY_OTHER。

**Q4: 每轮迭代做了什么？**
> ①从NameNode获取存储报告 → ②计算平均利用率并分类 → ③匹配源/目标对 → ④通过Dispatcher选Block并迁移 → ⑤休眠后继续下一轮。

### 5.3 思考题

1. 如果将threshold设为0%，会发生什么？集群能达到完全均衡吗？
2. Balancer在Federation模式下是如何工作的？
3. 为什么迁移间隔是 `2×heartbeat + replicationInterval`？

---

## 六、知识晶体

```
┌──────────────────────────────────────────────────────────────────┐
│ 核心源码: Balancer.init() → 4组分类 | chooseStorageGroups() → 匹配│
│          Dispatcher.dispatchAndCheckContinue() → 实际迁移         │
│ 设计意图: 迭代式均衡 | 带宽限制保护生产 | 机架感知优先同机架       │
│ 关键参数: threshold=10% | bandwidth=1MB/s | maxMove=10GB/DN/轮    │
│ 踩坑: 默认带宽太小→慢 | 带宽太大→影响生产 | 机架配置错→无法迁移  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Balancer.java`
2. `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/balancer/Dispatcher.java`
3. [HDFS Balancer Guide](https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-hdfs/HDFSCommands.html#balancer)
