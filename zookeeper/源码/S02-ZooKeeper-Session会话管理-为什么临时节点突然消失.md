# 教案 S02：ZooKeeper Session 会话管理 — 为什么你的临时节点突然消失了？

> **课时**：40分钟 | **难度**：⭐⭐⭐

---

## 一、课前导入 — HBase RegionServer 被误判死亡

> HBase RS 正常运行，但突然被 ZK 判定为"死亡"，临时节点被删除，触发 Region 迁移。事后发现 RS 只是发生了一次 30 秒的 Full GC。ZK 的 Session 超时判定机制没给它"申诉"的机会。

## 二、Session 生命周期

```
客户端连接 → 创建 Session → 定时发送心跳（ping）→ 服务端续期
                                    │
                          心跳超时？─┤
                          ├── NO → 继续保持
                          └── YES → Session 过期！
                                    │
                                    ▼
                          删除该 Session 的所有临时节点
                          触发所有 Watcher
```

### SessionTrackerImpl 核心设计（源码）

```java
// 批量过期设计 — 不是每个 Session 单独设 Timer！
// 而是将 Session 按"下次过期时间"分桶，每个 tick 统一检查

class SessionTrackerImpl extends ZooKeeperCriticalThread {
    // sessionId → SessionImpl
    HashMap<Long, SessionImpl> sessionsById;
    
    // 过期时间（向上取整到 tickTime）→ 该时间点过期的 Session 集合
    HashMap<Long, SessionSet> sessionSets;
    
    // 核心循环：每个 tickTime 检查一次
    public void run() {
        while (running) {
            long waitTime = tickTime - (System.currentTimeMillis() % tickTime);
            Thread.sleep(waitTime);  // 等到下一个 tick 边界
            
            SessionSet expiredSessions = sessionSets.remove(nextExpirationTime);
            if (expiredSessions != null) {
                for (SessionImpl s : expiredSessions) {
                    setSessionClosing(s.sessionId);  // 标记关闭
                    expirer.expire(s);                // 过期处理（删除临时节点）
                }
            }
            nextExpirationTime += tickTime;
        }
    }
}
```

**设计精髓**：
- 不是每个 Session 一个 Timer（那样百万连接就百万个 Timer）
- 而是**时间轮**思想：按 tickTime（默认 2000ms）分桶，批量过期
- `roundToInterval()` 将精确时间**向上取整**到 tick 边界 → 同一 tick 内的 Session 一起检查

### Session 续期（touchSession）

```java
// 每次收到客户端请求（包括心跳 ping）时调用
void touchSession(long sessionId, int timeout) {
    SessionImpl s = sessionsById.get(sessionId);
    long expireTime = roundToInterval(System.currentTimeMillis() + timeout);
    // 从旧的过期桶移到新的过期桶
    sessionSets.get(s.tickTime).remove(s);
    s.tickTime = expireTime;
    sessionSets.get(expireTime).add(s);
}
```

## 三、超时计算 — 一个精确的公式

```
实际 Session 超时 ∈ [2/3 × sessionTimeout, 2 × sessionTimeout]

例如 sessionTimeout = 30s：
- 客户端每 30s × 2/3 = 20s 发一次 ping（客户端 SDK 自动）
- 服务端如果 30s 内没收到任何请求 → Session 过期
- 但由于 tickTime 向上取整：实际过期可能延迟到 30s + tickTime(2s) = 32s
```

## 四、课堂练习

### 思考题 1：sessionTimeout 设多少合适？

<details>
<summary>参考答案</summary>

| 场景 | 推荐值 | 理由 |
|------|--------|------|
| HBase RS | 60-90s | RS GC 可能 30-60s，要给足余量 |
| Kafka Broker | 18s（默认6s太小） | 短暂网络抖动不要误判 |
| HDFS NameNode | 30s | NN Failover 需要时间 |
| 普通客户端 | 10-30s | 快速检测死亡 |

原则：`sessionTimeout > 最大可能的 GC 暂停 + 网络抖动`
</details>

### 思考题 2：为什么用时间轮而不是每个 Session 一个 Timer？

<details>
<summary>参考答案</summary>

百万级连接时：
- 每个 Session 一个 Timer → 百万个 Timer 对象 + 百万次调度 → GC 和 CPU 压力巨大
- 时间轮方案 → 只有 `totalTime/tickTime` 个桶（如 30s/2s = 15 个桶）→ O(1) 插入/删除

同构类比：Kafka 的 `TimingWheel`、Netty 的 `HashedWheelTimer`、Linux 内核的 Timer Wheel
</details>

## 五、知识晶体

```
┌──────────────────────────────────────────────────┐
│  ZooKeeper Session 管理                            │
├──────────────────────────────────────────────────┤
│  核心: SessionTrackerImpl (时间轮批量过期)          │
│  分桶: roundToInterval(now + timeout) → 同tick一起检查 │
│  续期: touchSession() → 从旧桶移到新桶             │
├──────────────────────────────────────────────────┤
│  过期后果: 删除所有临时节点 + 触发 Watcher          │
│  超时范围: [2/3 × timeout, 2 × timeout + tickTime] │
├──────────────────────────────────────────────────┤
│  生产经验:                                         │
│  - sessionTimeout > GC暂停 + 网络抖动              │
│  - HBase: 60-90s, Kafka: 18s                      │
│  同构: Kafka TimingWheel / Netty HashedWheelTimer  │
└──────────────────────────────────────────────────┘
```

*教案作者：Eric | 数据来源：ZooKeeper SessionTrackerImpl.java | 最后更新：2026-04-30*
