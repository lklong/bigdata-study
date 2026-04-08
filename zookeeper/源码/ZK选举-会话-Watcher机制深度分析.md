# ZooKeeper 选举、会话、Watcher 机制深度分析

> ZooKeeper Expert 补课学习 — 分布式协调核心机制

## 一、Leader 选举机制

### 1.1 FastLeaderElection 算法

```
ZK 集群启动时的选举过程:

1. 每个 Server 初始投票给自己: (myid, zxid)
2. 广播投票给所有其他 Server
3. 收到其他 Server 的投票后比较:
   a. 先比 zxid（事务 ID）— 越大越新，优先当 Leader
   b. zxid 相同则比 myid — 越大优先
4. 如果收到比自己更优的投票 → 更新自己的投票为更优的，重新广播
5. 当某个 Server 获得超过半数投票 → 成为 Leader

时间线:
  Server-1 (myid=1, zxid=100): 投自己 → 收到 Server-3 的 (3, 100) → 更优 → 改投 3
  Server-2 (myid=2, zxid=100): 投自己 → 收到 Server-3 的 (3, 100) → 更优 → 改投 3
  Server-3 (myid=3, zxid=100): 投自己 → 收到 2 票 → 获得 3/3 多数 → 当选 Leader！

关键: zxid 最大的优先 → 保证数据最新的节点当 Leader → 不丢数据
```

### 1.2 选举源码关键路径

```java
// FastLeaderElection.java
public Vote lookForLeader() {
    // 1. 创建初始投票 (自己)
    Vote proposal = new Vote(self.myid, self.getLastLoggedZxid(), self.getElectionEpoch());
    
    // 2. 广播投票
    sendNotifications();
    
    while (true) {
        // 3. 接收其他 Server 的投票
        Notification n = recvqueue.poll(timeout);
        
        // 4. 比较投票
        if (totalOrderPredicate(n.leader, n.zxid, n.epoch, 
                                proposal.leader, proposal.zxid, proposal.epoch)) {
            // 对方更优 → 更新自己的投票
            proposal = new Vote(n.leader, n.zxid, n.epoch);
            sendNotifications();  // 重新广播
        }
        
        // 5. 检查是否有 Server 获得多数票
        if (termPredicate(recvset, proposal)) {
            // 等待一小段时间看有没有更优的投票进来
            while ((n = recvqueue.poll(finalizeWait)) != null) {
                if (totalOrderPredicate(...)) {
                    // 有更优的 → 继续循环
                    break;
                }
            }
            // 确认当选
            return proposal;
        }
    }
}

// 投票比较: zxid 优先，相同则 myid 大的优先
boolean totalOrderPredicate(long newId, long newZxid, long newEpoch,
                            long curId, long curZxid, long curEpoch) {
    return (newEpoch > curEpoch) ||
           (newEpoch == curEpoch && newZxid > curZxid) ||
           (newEpoch == curEpoch && newZxid == curZxid && newId > curId);
}
```

### 1.3 脑裂防护

```
防止脑裂的关键: Quorum 机制

3 节点集群: 需要 2 票 → 最多容忍 1 个节点故障
5 节点集群: 需要 3 票 → 最多容忍 2 个节点故障

网络分区:
  分区 A: [Server-1, Server-2]  → 只有 2 票，< 3 → 无法选出 Leader
  分区 B: [Server-3, Server-4, Server-5] → 3 票 ≥ 3 → 选出 Leader
  
  结果: 只有分区 B 能提供服务，不会脑裂
```

## 二、会话管理机制

### 2.1 Session 生命周期

```
Client 连接 ZK:
  1. Client 发送 ConnectRequest (sessionTimeout)
  2. Server 创建 Session → 生成 sessionId (全局唯一)
  3. Server 返回 ConnectResponse (sessionId, negotiatedTimeout)
  4. Client 定期发送 Ping（心跳）保活
  5. Server 在 sessionTimeout 内没收到心跳 → Session 过期 → 删除临时节点

Session 状态机:
  CONNECTING → CONNECTED → CLOSED
                  ↕
              RECONNECTING (网络抖动)
```

### 2.2 Session 过期处理

```
Session 过期影响:
  1. 该 Session 创建的所有 EPHEMERAL 节点被删除
  2. 该 Session 注册的所有 Watcher 被移除
  3. 如果该 Session 持有分布式锁 → 锁释放 → 其他等待者获取锁

对大数据组件的影响:
  - HBase RegionServer 的 Session 过期 → Master 认为 RS 挂了 → 触发 Region 迁移
  - Kafka Broker 的 Session 过期 → Controller 认为 Broker 挂了 → Partition 重分配
  - Spark Driver 注册在 ZK 的 Session 过期 → HA 故障转移触发

关键参数:
  tickTime = 2000ms          # ZK 内部时钟单位
  minSessionTimeout = 2 * tickTime = 4s
  maxSessionTimeout = 20 * tickTime = 40s
  客户端建议 sessionTimeout = 30s (大数据场景)
```

### 2.3 Session 源码

```java
// SessionTrackerImpl.java
public synchronized boolean touchSession(long sessionId, int timeout) {
    SessionImpl s = sessionsById.get(sessionId);
    if (s == null) return false;
    
    // 更新过期时间
    long expireTime = roundToNextInterval(Time.currentElapsedTime() + timeout);
    // 从旧的过期桶移到新的过期桶
    sessionExpiryQueue.update(s, expireTime);
    return true;
}

// 过期检查 (每 tickTime 执行一次)
public void run() {
    while (running) {
        long waitTime = sessionExpiryQueue.getWaitTime();
        Thread.sleep(waitTime);
        
        // 获取已过期的 Session
        Set<SessionImpl> expiredSessions = sessionExpiryQueue.poll();
        for (SessionImpl s : expiredSessions) {
            setSessionClosing(s.sessionId);
            expirer.expire(s);  // 触发过期处理
        }
    }
}
```

## 三、Watcher 机制

### 3.1 Watcher 核心设计

```
Watcher 是 ZK 的事件通知机制:

Client 注册:
  getData("/path", watcher=true)  → Server 记录 watcher
  
Server 端触发:
  setData("/path", newData) → 找到所有注册的 watcher → 触发通知
  
Client 端回调:
  收到 WatcherEvent → 调用 Watcher.process(event) → 用户逻辑

关键特性:
  1. 一次性 (One-time): 触发后自动移除，需要重新注册
  2. 有序性: 事件按 zxid 顺序通知
  3. 轻量级: Server 只存 watcher 映射，不存回调逻辑
```

### 3.2 Watcher 事件类型

```java
enum EventType {
    None,                  // 连接状态变化
    NodeCreated,           // 节点创建
    NodeDeleted,           // 节点删除
    NodeDataChanged,       // 节点数据变更
    NodeChildrenChanged,   // 子节点列表变更
    DataWatchRemoved,      // Watcher 被移除 (3.5+)
    ChildWatchRemoved      // 子节点 Watcher 被移除
}

// 哪些操作触发哪些事件:
create("/a")      → 触发 "/a" 的 NodeCreated + "/" 的 NodeChildrenChanged
delete("/a")      → 触发 "/a" 的 NodeDeleted + "/" 的 NodeChildrenChanged  
setData("/a")     → 触发 "/a" 的 NodeDataChanged
create("/a/b")    → 触发 "/a/b" 的 NodeCreated + "/a" 的 NodeChildrenChanged
```

### 3.3 持久化 Watcher（ZK 3.6+）

```java
// 解决一次性 Watcher 的痛点: 不用反复注册
// 持久化 Watcher 触发后不会移除，持续监听

// 注册持久化 Watcher
zk.addWatch("/path", watcher, AddWatchMode.PERSISTENT);

// 递归持久化 Watcher（监听整个子树）
zk.addWatch("/path", watcher, AddWatchMode.PERSISTENT_RECURSIVE);

// 适用场景:
//   - 配置中心: 监听配置变更
//   - 服务发现: 监听服务注册/注销
//   - 分布式锁: 监听锁节点变化
```

## 四、ZK 在大数据生态中的角色

```
┌─────────────────────────────────────────────────────┐
│                   ZooKeeper Ensemble                 │
├─────────────────────────────────────────────────────┤
│                                                     │
│  HBase:     Master 选举 + RegionServer 注册         │
│  Kafka:     Controller 选举 + Broker 注册 (旧版)     │
│  HDFS HA:   NameNode Active/Standby 选举            │
│  YARN HA:   ResourceManager Active/Standby 选举     │
│  Spark HA:  Driver 注册 (Standalone 模式)           │
│  Kyuubi:    Server 服务发现 + Engine 注册           │
│  Hive:      HiveServer2 服务发现                    │
│  Flink:     HA Checkpoint 元数据存储                │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## 五、运维故障排查

### 5.1 常见问题

```
问题1: Session 频繁过期
  原因: GC 暂停 / 网络抖动 / ZK 服务端负载高
  排查: 检查 Client 端 GC 日志 + ZK 的 maxSessionTimeout 配置
  解决: 增大 sessionTimeout / 优化 Client GC / ZK 扩容

问题2: Watcher 通知延迟
  原因: ZK 事件队列堆积 / 大量 Watcher 同时触发（羊群效应）
  排查: 检查 ZK 的 outstanding_requests 监控
  解决: 减少不必要的 Watcher / 使用持久化 Watcher (3.6+)

问题3: Leader 频繁切换
  原因: 网络分区 / Leader 节点 GC / 磁盘 I/O 慢
  排查: 检查 ZK 日志中的 LOOKING 状态 + 选举耗时
  解决: 将 ZK 数据目录放 SSD / 独立部署 ZK（不和计算混部）

问题4: ZK 写入慢
  原因: 事务日志 (txnlog) 刷盘慢 / Follower 同步慢
  排查: 检查 fsync 延迟 + Follower ACK 延迟
  解决: txnlog 放 SSD / autopurge 清理快照
```

### 5.2 关键监控指标

```bash
# 四字命令 (4-letter words)
echo mntr | nc localhost 2181   # 核心指标
echo stat | nc localhost 2181   # 状态
echo cons | nc localhost 2181   # 连接列表
echo wchs | nc localhost 2181   # Watcher 数量

# 关键指标:
#   zk_avg_latency        — 平均延迟 (应 < 10ms)
#   zk_outstanding_requests — 待处理请求 (应 < 10)
#   zk_znode_count        — 节点总数
#   zk_watch_count        — Watcher 总数 (过多会影响性能)
#   zk_approximate_data_size — 数据大小
#   zk_open_file_descriptor_count — FD 使用量
```

---

*ZooKeeper Expert 学习产出 | 2026-04-08 | 补课：核心协调机制*
