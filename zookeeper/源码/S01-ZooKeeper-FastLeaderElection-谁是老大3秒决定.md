# 教案 S01：ZooKeeper FastLeaderElection — 谁是老大？3 秒决定

> **适用对象**：大数据运维/开发工程师 | **前置知识**：了解 ZK 集群基础  
> **课时**：45 分钟 | **难度**：⭐⭐⭐⭐

---

## 一、课前导入 — 你的 HBase 集群突然脑裂了

> 凌晨 2 点，ZK 集群 3 个节点中有 1 个网络闪断 5 秒。恢复后，你发现 HBase 的两个 RegionServer 同时认为自己是某个 Region 的 Master。原因：ZK Leader 变更时，临时节点被删除，触发了 HBase 的 failover 逻辑。
>
> 理解 ZK 的 Leader 选举机制，你才能回答：**选举要多久？期间集群不可用吗？什么条件下会脑裂？**

---

## 二、本课目标

1. **FastLeaderElection 算法的核心逻辑是什么？** 用 3 句话说清楚
2. **选举过程中 ZK 集群是什么状态？** 客户端能读能写吗？
3. **什么条件下选举会卡住或失败？** 生产中如何避免？

---

## 三、核心概念 — 投票选班长

### 选举规则（和小学选班长一模一样）

```
规则 1：每人先投自己
规则 2：收到别人的票时，比较"谁更优秀"：
         - 先比 epoch（任期号）→ 大的赢
         - epoch 相同比 zxid（事务ID）→ 大的赢（数据更新）
         - zxid 相同比 myid → 大的赢（配置文件里的 ID）
规则 3：如果别人比自己优秀，改投他
规则 4：当某个候选人获得**过半数**票时，选举结束
```

### 源码核心（FastLeaderElection.java）

```java
// 选举的核心投票循环
while (self.getPeerState() == ServerState.LOOKING) {
    // Step 1: 从接收队列取出一个通知（其他节点的投票）
    Notification n = recvqueue.poll(notTimeout, TimeUnit.MILLISECONDS);
    
    // Step 2: 比较对方的提议和我当前的提议
    if (totalOrderPredicate(n.leader, n.zxid, n.epoch,
                             proposedLeader, proposedZxid, proposedEpoch)) {
        // 对方更优秀 → 改投对方
        proposedLeader = n.leader;
        proposedZxid = n.zxid;
        proposedEpoch = n.epoch;
        // 广播我的新投票给所有人
        sendNotifications();
    }
    
    // Step 3: 检查是否有候选人获得过半数票
    if (hasAllQuorums(voteSet)) {
        // 等待 finalizeWait=200ms，看有没有更优的迟到票
        // 没有 → 选举结束！
        break;
    }
}
```

### totalOrderPredicate — "谁更优秀"的判定

```java
// 全序比较：先比 epoch，再比 zxid，最后比 myid
static boolean totalOrderPredicate(long newId, long newZxid, long newEpoch,
                                    long curId, long curZxid, long curEpoch) {
    return (newEpoch > curEpoch) ||
           (newEpoch == curEpoch && newZxid > curZxid) ||
           (newEpoch == curEpoch && newZxid == curZxid && newId > curId);
}
```

---

## 四、选举时序图

```
Node1(myid=1) | Node2(myid=2) | Node3(myid=3)   时间线
     │              │              │              ↓
  投自己(1)      投自己(2)      投自己(3)         T=0ms
     │──广播──→    │──广播──→    │──广播──→
     │              │              │
  收到(2,3)     收到(1,3)      收到(1,2)         T=10ms
  2>1? YES!    3>2? YES!      已经最大
  改投3        改投3           保持投3
     │──广播──→    │──广播──→    │
     │              │              │
  统计: 3获得     3获得3票       3获得3票          T=20ms
  3票(过半!)    (过半!)        (过半!)
     │              │              │
  等200ms...    等200ms...     等200ms...         T=220ms
     │              │              │
  确认: Node3    确认: Node3   确认: 我是Leader!  T=220ms
  是Leader      是Leader       切换为LEADING状态
  切换FOLLOWING 切换FOLLOWING
```

**总耗时：约 200-500ms**（正常情况下）

---

## 五、选举期间的集群状态

| 阶段 | 读 | 写 | 说明 |
|------|----|----|------|
| LOOKING（选举中） | ❌ 拒绝 | ❌ 拒绝 | 集群**完全不可用** |
| 选举完成，Leader 同步中 | ❌ 等待 | ❌ 等待 | Leader 在与 Follower 同步数据 |
| Leader 就绪 | ✅ | ✅ | 恢复正常服务 |

**关键洞察**：ZK 选举期间**集群完全不可用**！这就是为什么 ZK 集群要求**奇数节点**且**过半存活**——减少选举概率。

---

## 六、课堂练习

### 思考题 1：5 节点集群挂了 2 个，能选出 Leader 吗？

<details>
<summary>参考答案</summary>

能！5 节点的过半数 = 3。剩余 3 个节点可以选出 Leader。
但如果挂了 3 个 → 只剩 2 个 < 过半数 3 → **无法选举**，集群不可用。
</details>

### 思考题 2：为什么比较时 zxid 比 myid 优先级高？

<details>
<summary>参考答案</summary>

zxid 代表"数据新鲜度"。选 zxid 最大的节点当 Leader，确保新 Leader 拥有最新的数据，不会丢失已提交的事务。如果选了 zxid 小的节点当 Leader，它可能缺少一些已提交的事务 → **数据丢失**！
</details>

### 思考题 3：生产中什么会导致选举卡住？

<details>
<summary>参考答案</summary>

1. **网络分区**：节点间不通，投票发不出去/收不到 → 永远凑不够过半数
2. **GC 暂停**：某节点 GC 导致心跳超时被认为挂了，触发选举，但 GC 恢复后又加入 → 反复选举
3. **磁盘 IO 慢**：事务日志写入太慢，zxid 落后 → 选举时数据同步阶段耗时过长
4. **时钟偏差**：影响超时判断

解决：GC 调优（CMS/G1）、SSD 磁盘、专用网络、NTP 同步
</details>

---

## 七、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  ZooKeeper FastLeaderElection                      │
├──────────────────────────────────────────────────┤
│  核心: 每人投自己 → 比较改票 → 过半数当选          │
│  比较优先级: epoch > zxid > myid                   │
│  耗时: 正常 200-500ms                              │
├──────────────────────────────────────────────────┤
│  选举期间: 集群完全不可用（读写都拒绝）             │
│  过半数: 2N+1 节点集群需要 N+1 存活               │
├──────────────────────────────────────────────────┤
│  生产风险: GC暂停 / 网络分区 / 磁盘慢             │
│  同构类比: Raft Leader Election（但 ZK 用 Zab）    │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：ZooKeeper 源码 gitproject/zookeeper/ | 最后更新：2026-04-30*
