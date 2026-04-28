# [教案] S06-DataNode心跳与指令下发源码深度剖析

> 🎯 教学目标：掌握DataNode心跳机制的完整流程、NameNode如何通过心跳响应下发指令、HeartbeatManager如何检测死亡节点 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：快递站与快递员的日常汇报

想象一个大型快递分拣中心（NameNode），管理着上百个快递员（DataNode）：

- 每个快递员每隔**3秒**要回站点打卡（心跳），汇报自己的状态："我还活着，我的车上还有多少空位，我已经送了多少件"
- 站长（NameNode）在快递员打卡时，顺便给他派发新任务："去5号库房拿3个包裹送到东区"、"把你车上编号888的包裹复制一份送到西区"
- 如果某个快递员**超过10分钟没回来打卡**，站长就认为他出事了（宕机），开始将他负责的包裹调度给其他快递员
- 快递员不仅打卡，还会定期交一份**完整的包裹清单**（Block Report），站长对账确保没有丢件

在 HDFS 中，**心跳是 DataNode 和 NameNode 之间最基础的通信机制**。它不仅是存活检测，更是 NameNode **控制整个集群的指令通道**。

### 生产故障场景

```
场景1：大量 DataNode 同时被标记为 Dead
现象：NameNode 日志突然出现大量 "Dead datanode" 告警，集群可用存储骤降
      触发大量 Block 副本补充，网络带宽打满，集群雪崩
根因：NameNode GC 停顿 > 10分钟，导致所有心跳被判定为超时
解法：理解心跳超时判定机制 + heartbeatRecheckInterval + GC暂停保护

场景2：DataNode 心跳正常但不接收新Block
现象：某些 DataNode 虽然心跳正常，但始终不被分配新的写入请求
根因：心跳汇报的 xceiver 数过高或磁盘利用率过高，被标记为 Stale
解法：理解心跳携带的存储信息如何影响 Block 调度
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| Heartbeat | DataNode定期发送的存活信号+状态汇报 | 快递员的定时打卡 |
| BPServiceActor | DataNode端的心跳发送线程，每个NameNode一个 | 专门负责跑腿打卡的小弟 |
| HeartbeatManager | NameNode端管理所有DataNode心跳的组件 | 站长的考勤系统 |
| HeartbeatResponse | NameNode对心跳的响应，携带指令 | 站长给的任务清单 |
| DatanodeCommand | NameNode下发给DataNode的指令 | 具体的任务条目 |
| Block Report | DataNode定期发送的完整Block清单 | 快递员的完整包裹清单 |
| IBR (Incremental Block Report) | 增量Block汇报 | 每次送完一件就汇报一件 |
| Stale Node | 超过30秒没心跳的节点，优先级降低 | 迟到的快递员，暂不派新活 |
| Dead Node | 超过阈值未心跳的节点，判定为死亡 | 失联的快递员，启动替补 |
| DNA_TRANSFER | 指令：复制Block到其他DataNode | 任务：把包裹送到指定地点 |
| DNA_INVALIDATE | 指令：删除本地Block | 任务：销毁指定包裹 |
| DNA_RECOVERBLOCK | 指令：执行Block Recovery | 任务：处理损坏的包裹 |

### 2.2 架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                           DataNode                                   │
│  ┌───────────────────────┐  ┌───────────────────────┐               │
│  │  BPServiceActor #1     │  │  BPServiceActor #2     │  (HA模式)    │
│  │  (Active NameNode)     │  │  (Standby NameNode)    │              │
│  │  offerService() 主循环 │  │  offerService() 主循环 │              │
│  │  1.发心跳 2.处理指令   │  │  1.发心跳 2.处理指令   │              │
│  │  3.发IBR 4.发BR        │  │  3.发IBR 4.发BR        │              │
│  └───────────────────────┘  └───────────────────────┘              │
│            │ sendHeartBeat() RPC                                     │
└────────────┼─────────────────────────────────────────────────────────┘
             ▼                              
┌─────────────────────────────────────────────────────────────────────┐
│                          NameNode                                    │
│  FSNamesystem.handleHeartbeat()                                      │
│       → DatanodeManager.handleHeartbeat()                            │
│            ├─ HeartbeatManager.updateHeartbeat() (更新状态)           │
│            ├─ getLeaseRecoveryCommand() (Recovery指令)                │
│            ├─ getReplicationCommand() (复制指令)                      │
│            └─ getInvalidateBlocks() (删除指令)                       │
│                                                                      │
│  HeartbeatManager.Monitor: 每5秒检查死亡节点                         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|---------|------|
| `BPServiceActor` | `server/datanode/BPServiceActor.java` | DataNode端心跳发送线程 |
| `HeartbeatManager` | `server/blockmanagement/HeartbeatManager.java` | NameNode端心跳管理 |
| `HeartbeatManager.Monitor` | 同上（内部类） | 后台线程，检测死亡节点 |
| `DatanodeManager` | `server/blockmanagement/DatanodeManager.java` | 处理心跳，生成指令 |
| `FSNamesystem` | `server/namenode/FSNamesystem.java` | 心跳入口 |

### 3.2 关键方法逐行解读

#### 3.2.1 offerService()：DataNode 心跳主循环

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/BPServiceActor.java
// 行号: 548-668

private void offerService() throws Exception {
  while (shouldRun()) {
    final long startTime = scheduler.monotonicNow();
    final boolean sendHeartbeat = scheduler.isHeartbeatDue(startTime);
    HeartbeatResponse resp = null;
    
    if (sendHeartbeat) {
      resp = sendHeartBeat(requestBlockReportLease);  // 发送心跳
      bpos.updateActorStatesFromHeartbeat(this, resp.getNameNodeHaState());
      if (!processCommand(resp.getCommands())) continue;  // 处理指令
    }
    
    if (ibrManager.sendImmediately() || sendHeartbeat) {
      ibrManager.sendIBRs(...);  // 发送增量Block汇报
    }
    
    if ((fullBlockReportLeaseId != 0) || forceFullBr) {
      cmds = blockReport(fullBlockReportLeaseId);  // 发送完整Block Report
      processCommand(cmds...);
    }
    
    ibrManager.waitTillNextIBR(scheduler.getHeartbeatWaitTime());  // 等待
  }
}
```

#### 3.2.2 sendHeartBeat()：心跳携带的7类信息

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/BPServiceActor.java
// 行号: 444-468

HeartbeatResponse sendHeartBeat(boolean requestBlockReportLease)
    throws IOException {
  StorageReport[] reports =
      dn.getFSDataset().getStorageReports(bpos.getBlockPoolId());
  VolumeFailureSummary volumeFailureSummary = dn.getFSDataset()
      .getVolumeFailureSummary();
  
  return bpNamenode.sendHeartbeat(
      bpRegistration,          // ① DataNode注册信息
      reports,                  // ② 存储目录容量报告
      dn.getFSDataset().getCacheCapacity(),  // ③ 缓存总容量
      dn.getFSDataset().getCacheUsed(),      // ④ 缓存已使用
      dn.getXmitsInProgress(), // ⑤ 进行中的数据传输数
      dn.getXceiverCount(),    // ⑥ 活跃连接数
      numFailedVolumes,        // ⑦ 故障磁盘数
      volumeFailureSummary,
      requestBlockReportLease);
}
```

#### 3.2.3 DatanodeManager.handleHeartbeat()：指令生成

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeManager.java
// 行号: 1357-1454

public DatanodeCommand[] handleHeartbeat(...) throws IOException {
  synchronized (heartbeatManager) {
    synchronized (datanodeMap) {
      // 步骤1：更新心跳状态
      heartbeatManager.updateHeartbeat(nodeinfo, reports, ...);

      // SafeMode下不返回指令
      if(namesystem.isInSafeMode()) return new DatanodeCommand[0];

      // 步骤2：Lease Recovery指令（最高优先级）
      BlockInfo[] blocks = nodeinfo.getLeaseRecoveryCommand(Integer.MAX_VALUE);
      if (blocks != null) {
        BlockRecoveryCommand brCommand = new BlockRecoveryCommand(blocks.length);
        // 构造RecoveringBlock，跳过Stale节点
        return new DatanodeCommand[] { brCommand };
      }

      // 步骤3：Block复制指令
      List<BlockTargetPair> pendingList = nodeinfo.getReplicationCommand(maxTransfers);
      if (pendingList != null) {
        cmds.add(new BlockCommand(DatanodeProtocol.DNA_TRANSFER, ...));
      }
      
      // 步骤4：Block删除指令、缓存指令等
      return cmds.toArray(new DatanodeCommand[cmds.size()]);
    }
  }
}
```

#### 3.2.4 heartbeatCheck()：死亡节点检测

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java
// 行号: 316-390

void heartbeatCheck() {
  if (namesystem.isInStartupSafeMode()) return;
  
  boolean allAlive = false;
  while (!allAlive) {
    DatanodeID dead = null;
    synchronized(this) {
      for (DatanodeDescriptor d : datanodes) {
        if (shouldAbortHeartbeatCheck(0)) return;  // GC保护
        if (dead == null && dm.isDatanodeDead(d)) {
          dead = d;  // 每次只标记一个Dead节点！
        }
      }
    }
    allAlive = dead == null;
    if (dead != null) {
      namesystem.writeLock();
      try { dm.removeDeadDatanode(dead); }
      finally { namesystem.writeUnlock(); }
    }
  }
}
```

#### 3.2.5 Monitor线程

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java
// 行号: 393-430

private class Monitor implements Runnable {
  public void run() {
    while(namesystem.isRunning()) {
      restartHeartbeatStopWatch();
      final long now = Time.monotonicNow();
      if (lastHeartbeatCheck + heartbeatRecheckInterval < now) {
        heartbeatCheck();
        lastHeartbeatCheck = now;
      }
      Thread.sleep(5000);  // 每5秒检查一次
      
      // GC暂停保护
      if (shouldAbortHeartbeatCheck(-5000)) {
        LOG.warn("Skipping next heartbeat scan due to excessive pause");
        lastHeartbeatCheck = Time.monotonicNow();
      }
    }
  }
}
```

### 3.3 调用链时序图

```
DataNode (BPServiceActor)          NameNode
     │                                │
     │──sendHeartBeat()──────────────→│
     │  (StorageReport[]+状态信息)      │  FSNamesystem.handleHeartbeat()
     │                                │   → DatanodeManager.handleHeartbeat()
     │                                │      ├─ updateHeartbeat()
     │                                │      ├─ getLeaseRecoveryCommand()
     │                                │      ├─ getReplicationCommand()
     │                                │      └─ 返回 DatanodeCommand[]
     │←─HeartbeatResponse─────────────│
     │  (DatanodeCommand[]+HA状态)     │
     │                                │
     │  processCommand()              │
     │  执行: 复制/删除/Recovery       │

HeartbeatManager.Monitor (每5秒)
     │──heartbeatCheck()
     │  遍历datanodes → isDatanodeDead?
     │  → removeDeadDatanode (每次只一个)
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：NameNode GC 导致 DataNode 被误判 Dead
```
原因: NN Full GC > heartbeatExpireInterval → 所有DN超时
解法: 调优NN JVM参数，开启GC暂停保护
```

#### 场景2：心跳风暴
```
原因: 5000+ DN × 每3秒 = 大量心跳RPC积压
解法: 增大heartbeat.interval/handler.count
```

### 4.2 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.heartbeat.interval` | 3s | 心跳间隔 |
| `dfs.namenode.heartbeat.recheck-interval` | 5min | 检查间隔 |
| `dfs.namenode.stale.datanode.interval` | 30s | Stale阈值 |
| Dead阈值(计算) | ~10min30s | 2×recheck+10×heartbeat |

---

## 五、举一反三

### 5.1 类比迁移

| 概念 | HDFS | Kafka | ZooKeeper | K8s |
|------|------|-------|-----------|-----|
| 心跳间隔 | 3s | 3s | tickTime | 10s |
| 指令下发 | 心跳响应 | LeaderAndIsr | Watcher | Watch |
| 死亡处理 | removeDeadDN | ISR shrink | 删临时节点 | Not Ready |

### 5.2 面试高频题

**Q1: 心跳包含哪些信息？** → 7类：注册信息、StorageReport、缓存、xmits、xceiver、故障盘、BR租约请求

**Q2: 如何判定Dead？** → 2×recheckInterval + 10×heartbeatInterval ≈ 10min30s

**Q3: 为什么每次只处理一个Dead？** → 防GC误判导致级联Block副本风暴

**Q4: 指令如何下发？** → Piggyback模式，搭心跳响应的便车

### 5.3 思考题

1. 将heartbeat.interval从3s改为30s，死亡判定变为多少？对集群有何影响？
2. 为什么handleHeartbeat用readLock而非writeLock？
3. DataNode为何要向Standby NN也发心跳？

---

## 六、知识晶体

```
┌──────────────────────────────────────────────────────────────────┐
│ 核心源码: BPServiceActor.offerService() → sendHeartBeat()        │
│          DatanodeManager.handleHeartbeat() → 生成指令             │
│          HeartbeatManager.heartbeatCheck() → 检测Dead             │
│ 设计意图: Piggyback下发指令 | 防级联每次一个 | GC暂停保护        │
│ 关键参数: 心跳3s | Stale 30s | Dead 10min30s | Monitor 5s       │
│ 踩坑: NN GC→误判Dead→副本风暴 | Stale→写入倾斜 | Handler不足   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/BPServiceActor.java`
2. `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/HeartbeatManager.java`
3. `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/DatanodeManager.java` (L1357-1454)
4. `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java` (L3748-3775)
