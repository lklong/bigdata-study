# [教案] DataNode磁盘均衡DiskBalancer源码深度剖析

> 🎯 教学目标：掌握DiskBalancer的设计动机、与HDFS Balancer的区别、节点内磁盘间数据均衡的Plan生成与执行机制、源码实现原理  
> ⏰ 预计学时：2.5学时  
> 📊 难度：★★★☆☆

---

## 一、课前导入（生活类比/故障场景引入）

### 1.1 生活类比：仓库库位均衡

想象一个大型仓库（DataNode）有6个货架（磁盘）：
- **HDFS Balancer** = 仓库间调度（把货从仓库A搬到仓库B，即节点间均衡）
- **DiskBalancer** = 仓库内库位调度（在同一仓库内，把过满货架的货搬到空货架）

当新增一块磁盘或某块磁盘更换后，该节点内磁盘使用率差异巨大，需要节点内均衡。

### 1.2 生产故障场景引入

**场景**：某DataNode有12块8TB磁盘，扩容新加2块8TB空盘：
- 原12块磁盘使用率：85%
- 新2块磁盘使用率：0%
- HDFS Balancer只做节点间均衡，不解决节点内磁盘倾斜
- 新写入的block被HDFS轮询到新盘，但旧盘数据不会自动迁移
- 结果：旧盘IO负载重，新盘空闲

**解决方案**：使用DiskBalancer在节点内做磁盘间数据迁移。

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| DiskBalancer | 磁盘均衡器 | 节点内磁盘间的数据均衡工具 |
| DiskBalancerPlan | 均衡计划 | JSON格式的迁移方案，描述源磁盘/目标磁盘/迁移量 |
| DiskBalancerStep | 均衡步骤 | Plan中的一个迁移动作（从Volume A移到Volume B） |
| Volume | 存储卷 | DataNode上的一个磁盘/分区对应的存储目录 |
| HDFS Balancer | 集群均衡器 | 节点间的数据均衡工具（对比） |
| DiskBalancerCluster | 磁盘集群 | DiskBalancer的节点模型，包含所有卷的使用情况 |
| MoveStep | 移动步骤 | 具体的block搬运指令 |
| Bandwidth | 带宽限制 | 搬运速度限制，避免影响正常IO |

### 2.2 DiskBalancer vs HDFS Balancer 对比

| 维度 | HDFS Balancer | DiskBalancer |
|------|--------------|-------------|
| 均衡粒度 | 节点间（Inter-node） | 节点内磁盘间（Intra-node） |
| 触发方式 | 手动/定时运行 | 手动提交Plan |
| 决策者 | Balancer进程（独立JVM） | DiskBalancer命令 + DataNode执行 |
| 数据移动 | 通过网络（DataTransferProtocol） | 本地磁盘间复制（同节点） |
| 使用场景 | 集群扩容/缩容/节点上下线 | 磁盘扩容/更换/磁盘倾斜 |
| 引入版本 | Hadoop 1.x | Hadoop 3.0 (HDFS-1312) |
| 对网络影响 | 消耗带宽 | 无网络开销 |

### 2.3 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                    管理员 / 运维                                      │
│  $ hdfs diskbalancer -plan dn01.example.com                         │
│  $ hdfs diskbalancer -execute /path/to/plan.json                    │
│  $ hdfs diskbalancer -query dn01.example.com                        │
│  $ hdfs diskbalancer -cancel dn01.example.com                       │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ RPC (submitDiskBalancerPlan)
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    DataNode (dn01.example.com)                        │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │              DiskBalancer (DataNode内组件)                      │  │
│  │  ┌─────────┐   ┌──────────────┐   ┌──────────────────────┐   │  │
│  │  │Plan解析 │   │WorkerThread  │   │进度/状态跟踪         │   │  │
│  │  │(JSON)   │→  │(执行block   │→  │(queryStatus/cancel)  │   │  │
│  │  │         │   │ 搬运)        │   │                      │   │  │
│  │  └─────────┘   └──────────────┘   └──────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Storage Volumes (磁盘)                                         │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐            │ │
│  │  │ /data1  │ │ /data2  │ │ /data3  │ │ /data4  │            │ │
│  │  │ 使用85% │ │ 使用82% │ │ 使用88% │ │ 使用10% │←新盘       │ │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘            │ │
│  │       │           │           │                ▲              │ │
│  │       └───────────┴───────────┴── block搬运 ───┘              │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

> **注意**：DiskBalancer于HDFS-1312（Hadoop 3.0+）引入。源码路径：
> `hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/diskbalancer/`

### 3.1 DiskBalancerPlan——均衡计划模型

```java
// DiskBalancerPlan.java - Plan的数据模型
public class DiskBalancerPlan {
  private String planID;              // 计划唯一ID
  private String nodeName;            // 目标DataNode
  private int port;                   // DataNode端口
  private long planVersion;           // 版本号
  private long timeStamp;             // 创建时间
  private List<Step> volumeSetPlans;  // 均衡步骤列表
  
  // 每个Step描述一次磁盘间迁移
  public static class Step {
    private String sourcePath;       // 源磁盘路径（如 /data1）
    private String destPath;         // 目标磁盘路径（如 /data4）
    private long bytesToMove;        // 要移动的字节数
    private long maxDiskErrors;      // 最大允许错误数
    private long tolerancePercent;   // 容忍偏差百分比
    private long bandwidth;          // 限速（MB/s）
  }
}
```

### 3.2 Plan生成算法

```java
// DiskBalancerPlanGenerator (逻辑)
public DiskBalancerPlan generatePlan(DatanodeInfo node) {
  // 1. 获取节点所有Volume的使用情况
  List<VolumeInfo> volumes = getVolumeInfo(node);
  
  // 2. 计算平均使用率
  double totalCapacity = volumes.stream().mapToLong(v -> v.capacity).sum();
  double totalUsed = volumes.stream().mapToLong(v -> v.used).sum();
  double avgUsagePercent = totalUsed / totalCapacity * 100;
  
  // 3. 分类：过满盘 vs 空闲盘
  List<VolumeInfo> overUsed = volumes.stream()
      .filter(v -> v.usagePercent > avgUsagePercent + threshold)
      .sorted(byUsageDesc)
      .collect(toList());
  List<VolumeInfo> underUsed = volumes.stream()
      .filter(v -> v.usagePercent < avgUsagePercent - threshold)
      .sorted(byUsageAsc)
      .collect(toList());
  
  // 4. 贪心匹配：从最满的盘移到最空的盘
  List<Step> steps = new ArrayList<>();
  int i = 0, j = 0;
  while (i < overUsed.size() && j < underUsed.size()) {
    VolumeInfo src = overUsed.get(i);
    VolumeInfo dst = underUsed.get(j);
    
    long srcExcess = src.used - (long)(avgUsagePercent * src.capacity / 100);
    long dstDeficit = (long)(avgUsagePercent * dst.capacity / 100) - dst.used;
    long toMove = Math.min(srcExcess, dstDeficit);
    
    steps.add(new Step(src.path, dst.path, toMove));
    
    if (srcExcess <= toMove) i++;
    if (dstDeficit <= toMove) j++;
  }
  
  return new DiskBalancerPlan(node, steps);
}
```

### 3.3 DataNode侧执行——DiskBalancer组件

```java
// DiskBalancer.java (DataNode内部组件)
public class DiskBalancer {
  private final DataNode dataNode;
  private DiskBalancerPlan currentPlan;
  private ExecutorService executor;
  private volatile boolean shouldRun;
  
  // 提交Plan并开始执行
  public void submitPlan(String planJson) throws IOException {
    DiskBalancerPlan plan = parseAndValidate(planJson);
    this.currentPlan = plan;
    
    // 为每个Step启动一个Worker线程
    for (Step step : plan.getSteps()) {
      executor.submit(new DiskBalancerMover(step));
    }
  }
  
  // 实际搬运block的Worker
  private class DiskBalancerMover implements Runnable {
    private final Step step;
    private long bytesMoved = 0;
    
    @Override
    public void run() {
      FsVolumeSpi srcVolume = findVolume(step.getSourcePath());
      FsVolumeSpi dstVolume = findVolume(step.getDestPath());
      
      while (bytesMoved < step.getBytesToMove() && shouldRun) {
        // 1. 从源Volume选择一个block
        ExtendedBlock block = selectBlockToMove(srcVolume);
        if (block == null) break;  // 没有更多block可移
        
        // 2. 复制block文件到目标Volume
        //    这是本地文件复制，不走网络！
        File srcFile = srcVolume.getBlockFile(block);
        File dstFile = dstVolume.createBlockFile(block);
        copyFileWithThrottle(srcFile, dstFile, step.getBandwidth());
        
        // 3. 复制meta文件
        File srcMeta = srcVolume.getMetaFile(block);
        File dstMeta = dstVolume.createMetaFile(block);
        copyFileWithThrottle(srcMeta, dstMeta, step.getBandwidth());
        
        // 4. 更新Volume映射（通知DataNode此block已移动）
        dataNode.moveBlock(block, srcVolume, dstVolume);
        
        // 5. 删除源文件
        srcFile.delete();
        srcMeta.delete();
        
        bytesMoved += block.getNumBytes();
        
        // 6. 限速
        throttle(step.getBandwidth());
      }
    }
  }
  
  // 查询执行状态
  public DiskBalancerWorkStatus queryStatus() {
    return new DiskBalancerWorkStatus(
        currentPlan, bytesMoved, totalToMove, 
        isRunning() ? Status.RUNNING : Status.DONE);
  }
  
  // 取消执行
  public void cancelPlan() {
    shouldRun = false;
    executor.shutdownNow();
  }
}
```

### 3.4 命令行工具使用

```bash
# 1. 生成计划（不执行，只是生成JSON）
hdfs diskbalancer -plan dn01.example.com
# 输出: /tmp/diskbalancer/plan-dn01.json

# 2. 查看计划
cat /tmp/diskbalancer/plan-dn01.json
# {
#   "planID": "abc123",
#   "nodeName": "dn01.example.com",
#   "steps": [
#     {"sourcePath":"/data1","destPath":"/data4","bytesToMove":1099511627776}
#   ]
# }

# 3. 执行计划
hdfs diskbalancer -execute /tmp/diskbalancer/plan-dn01.json

# 4. 查询进度
hdfs diskbalancer -query dn01.example.com
# Status: RUNNING, Progress: 45%, BytesMoved: 500GB / 1TB

# 5. 取消执行
hdfs diskbalancer -cancel dn01.example.com
```

---

## 四、生产实战案例

### 4.1 案例：新增磁盘后节点内均衡

```bash
# 1. 启用DiskBalancer（hdfs-site.xml）
<property>
  <name>dfs.disk.balancer.enabled</name>
  <value>true</value>
</property>
<property>
  <name>dfs.disk.balancer.max.disk.throughputInMBperSec</name>
  <value>100</value>  <!-- 限速100MB/s避免影响业务 -->
</property>

# 2. 查看节点磁盘使用情况
hdfs diskbalancer -report -node dn01.example.com
# Volume: /data1, Capacity: 8TB, Used: 6.8TB (85%)
# Volume: /data2, Capacity: 8TB, Used: 6.5TB (81%)  
# Volume: /data3, Capacity: 8TB, Used: 7.0TB (88%)
# Volume: /data4, Capacity: 8TB, Used: 0.8TB (10%)  ← 新盘

# 3. 生成并执行计划
hdfs diskbalancer -plan dn01.example.com -thresholdPercentage 10
hdfs diskbalancer -execute /tmp/diskbalancer/plan-dn01.json

# 4. 监控进度
watch -n 30 'hdfs diskbalancer -query dn01.example.com'
```

### 4.2 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.disk.balancer.enabled` | true | 是否启用DiskBalancer |
| `dfs.disk.balancer.max.disk.throughputInMBperSec` | 10 | 磁盘搬运限速 |
| `dfs.disk.balancer.max.disk.errors` | 5 | 单Step最大错误容忍数 |
| `dfs.disk.balancer.plan.threshold.percent` | 10 | 触发均衡的偏差阈值 |
| `dfs.disk.balancer.block.tolerance.percent` | 10 | block级别容忍偏差 |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：DiskBalancer和HDFS Balancer的区别？各自适用什么场景？**

A：HDFS Balancer做节点间均衡（通过网络），适用于集群扩缩容；DiskBalancer做节点内磁盘间均衡（本地文件复制），适用于磁盘扩容、更换磁盘后的节点内数据倾斜。

**Q2：DiskBalancer搬运block时，对正在读取该block的客户端有影响吗？**

A：搬运是复制+删除的两阶段。复制完成后更新DataNode的blockMap，最后删除源文件。在复制期间，源block仍可正常读取。切换映射是瞬时的，且有retry机制。

**Q3：如何避免DiskBalancer影响正常IO？**

A：通过bandwidth参数限速（默认10MB/s，可调整到100MB/s），搬运线程在每次复制后会sleep以满足限速要求。建议在业务低峰期执行。

### 5.2 思考题

1. 如果DiskBalancer执行到一半DataNode重启了，会怎样？（已复制但未删除源的block会变成什么状态？）
2. DiskBalancer是否需要通知NameNode？block位置信息如何更新？
3. 在异构磁盘（SSD + HDD混合）场景下，DiskBalancer是否适用？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────────┐
│         DataNode DiskBalancer · 知识晶体                             │
├─────────────────────────────────────────────────────────────────────┤
│  【定位】节点内磁盘间数据均衡（vs HDFS Balancer = 节点间）           │
│  【流程】-plan生成JSON → -execute提交到DN → Worker线程执行搬运      │
│  【搬运】本地文件复制(src→dst) → 更新blockMap → 删除源文件          │
│  【限速】bandwidth参数控制IO速率，避免影响在线服务                   │
│  【适用】磁盘扩容/更换/节点内磁盘使用率不均                          │
│  【关键命令】hdfs diskbalancer -plan/-execute/-query/-cancel        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码目录**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/diskbalancer/`
2. **设计文档**: HDFS-1312: HDFS Disk Balancer
3. **官方文档**: Apache Hadoop: HDFS Disk Balancer
