# Kafka 第二课：分区副本机制与 ISR 同步 — 数据不丢的秘密

> **教学目标**：学完本课后，你能解释 Kafka 的副本同步机制（ISR），理解 acks=0/1/all 的区别，并能计算不同配置下的数据丢失风险。

---

## 一、先讲个故事（白话层）

想象你写了一份**超级重要的合同**，需要确保不丢失：

- **acks=0**（不等确认）：你把合同扔进邮箱就走了——最快，但合同可能掉在路上
- **acks=1**（Leader 确认）：邮局收到后给你回执——比较安全，但邮局着火了合同就没了
- **acks=all**（所有副本确认）：邮局收到后，复印给 2 个分局都存好了才给你回执——最安全，但最慢

**ISR（In-Sync Replicas）= 跟得上进度的分局列表**。只有在 ISR 里的分局才算"可靠的备份"。

---

## 二、副本架构

```
Topic-A, Partition-0 (3 副本):

┌────────────────────────────────────────────────────┐
│  Broker-0                                          │
│  ┌──────────────────────────────────────────────┐  │
│  │ Partition-0 (Leader)                          │  │
│  │ [msg0][msg1][msg2][msg3][msg4][msg5]         │  │
│  │                              ↑ LEO=6          │  │
│  │                         ↑ HW=5                │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
         │ 同步
         ▼
┌────────────────────────────────────────────────────┐
│  Broker-1                                          │
│  ┌──────────────────────────────────────────────┐  │
│  │ Partition-0 (Follower, ISR)                   │  │
│  │ [msg0][msg1][msg2][msg3][msg4]               │  │
│  │                         ↑ LEO=5               │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
         │ 同步
         ▼
┌────────────────────────────────────────────────────┐
│  Broker-2                                          │
│  ┌──────────────────────────────────────────────┐  │
│  │ Partition-0 (Follower, ISR)                   │  │
│  │ [msg0][msg1][msg2][msg3][msg4]               │  │
│  │                         ↑ LEO=5               │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘

LEO = Log End Offset（日志末端偏移 = 最新消息的下一个位置）
HW  = High Watermark（高水位 = 所有 ISR 副本都同步到的位置）
Consumer 只能读到 HW 以下的消息（保证数据一致性）
```

---

## 三、ISR 机制详解

### 3.1 ISR 是什么？

```
ISR = In-Sync Replicas = "能跟上 Leader 进度的副本集合"

判断标准：
  Follower 的 LEO 落后 Leader 的 LEO 不超过 replica.lag.time.max.ms (默认30s)

ISR 动态变化：
  Follower 追上了 → 加入 ISR
  Follower 落后了 → 踢出 ISR（变成 OSR = Out-of-Sync Replicas）
  Follower 又追上了 → 重新加入 ISR
```

### 3.2 ISR 与 acks 的关系

| acks | 含义 | 数据安全 | 延迟 | 吞吐 |
|------|------|---------|------|------|
| `0` | 不等任何确认 | 可能丢消息 | **最低** | **最高** |
| `1` | Leader 写入即确认 | Leader 挂了可能丢 | 中等 | 高 |
| `all`（-1） | **ISR 中所有副本**都写入才确认 | **不丢消息** | **最高** | 中等 |

### 3.3 min.insync.replicas — 防止"假安全"

```
问题：如果 ISR 只剩 Leader 自己（其他都被踢出），acks=all 还安全吗？
答：不安全！此时 acks=all 等同于 acks=1

解决：设置 min.insync.replicas = 2
含义：ISR 中至少要有 2 个副本，否则 Producer 会收到 NotEnoughReplicasException
效果：宁可写入失败，也不在不安全的状态下假装成功
```

**生产黄金组合**：
```properties
# Producer 端
acks = all

# Broker 端（Topic 级别）
replication.factor = 3
min.insync.replicas = 2
```

含义：3 副本中至少 2 个确认才算成功。容忍 1 个 Broker 宕机仍不丢数据。

---

## 四、Leader 选举

```
正常情况：
  ISR = [Broker-0(Leader), Broker-1, Broker-2]

Broker-0 宕机：
  Controller 从 ISR 中选择新 Leader → Broker-1 成为新 Leader
  ISR = [Broker-1(Leader), Broker-2]

关键配置：
  unclean.leader.election.enable = false（默认）
    → 只从 ISR 中选 Leader，保证不丢数据
    → 如果 ISR 为空，分区不可用（宁可不可用，不可丢数据）

  unclean.leader.election.enable = true（危险！）
    → 允许从 OSR 中选 Leader
    → 可能丢失数据！（OSR 的副本数据不完整）
```

---

## 五、数据丢失场景分析

| 场景 | acks=0 | acks=1 | acks=all + min.insync=2 |
|------|--------|--------|------------------------|
| Producer 发送后网络断开 | 丢 | 丢 | 丢（重试可恢复） |
| Leader 写入后立即宕机 | 丢 | **丢** | **不丢**（ISR 已同步） |
| 所有 Broker 同时宕机 | 丢 | 丢 | 磁盘数据存在，恢复后不丢 |
| ISR 只剩 Leader 时 Leader 宕机 | 丢 | 丢 | 不发生（min.insync=2 拒绝写入） |

---

## 六、课堂练习

### 练习 1：故障分析

> 场景：Topic-A 有 3 个分区，每个分区 3 副本。Broker-2 因磁盘故障下线。
> 问：哪些分区受影响？影响程度如何？

答：
- Broker-2 上的 Leader 分区：触发选举，短暂不可用后恢复（秒级）
- Broker-2 上的 Follower 分区：被踢出 ISR，不影响读写，但冗余度降低
- 如果 min.insync.replicas=2，剩余 2 个副本仍满足，写入正常

### 练习 2：举一反三

> "Kafka 的 ISR 同步机制与 MySQL 的半同步复制（semi-sync）有什么同构关系？"

答：
- Kafka ISR + acks=all ≈ MySQL semi-sync（至少一个 Slave 确认）
- Kafka min.insync.replicas ≈ MySQL rpl_semi_sync_master_wait_for_slave_count
- 区别：Kafka ISR 是动态的，MySQL Slave 集合是静态的

### 练习 3：配置选择

> 三种业务场景，分别选什么 acks？
> A. 用户行为日志采集（允许少量丢失）
> B. 支付订单消息（绝对不能丢）
> C. 实时监控 metrics（延迟敏感）

答：A → acks=1，B → acks=all + min.insync=2，C → acks=0

---

## 七、生产配置模板

```properties
# ===== Producer 端 =====
acks = all
retries = 10
retry.backoff.ms = 100
max.in.flight.requests.per.connection = 5  # Kafka 2.0+ 支持幂等，可 >1
enable.idempotence = true                   # 开启幂等（防重复）
compression.type = lz4                      # 压缩

# ===== Broker 端 (server.properties) =====
default.replication.factor = 3
min.insync.replicas = 2
unclean.leader.election.enable = false      # 绝不允许脏选举
log.retention.hours = 168                   # 7天
log.segment.bytes = 1073741824              # 1GB
replica.lag.time.max.ms = 30000             # 30s ISR 判定阈值

# ===== Consumer 端 =====
enable.auto.commit = false                  # 关闭自动提交，手动控制
auto.offset.reset = earliest                # 找不到 offset 时从头读
max.poll.records = 500                      # 每次拉取最大条数
```

---

## 八、知识晶体

```
问题/场景: 如何保证 Kafka 消息不丢失？
核心机制: ISR + acks=all + min.insync.replicas
设计意图: 通过"多数确认"保证即使 Leader 宕机，数据也存在于其他副本
关键参数:
  acks                       → all（最安全）
  min.insync.replicas        → 2（黄金值）
  replication.factor         → 3（标准值）
  unclean.leader.election    → false（绝不脏选举）
  enable.idempotence         → true（防重复）
踩坑记录:
  - acks=all 但 min.insync.replicas=1 等于白设
  - ISR 持续缩小说明有 Follower 跟不上，查网络/磁盘/GC
  - unclean.leader.election=true 会导致消息丢失，生产环境禁用
认知更新: Kafka 的"不丢消息"不是单一配置，而是 Producer+Broker+Consumer 三端协同的结果
```
