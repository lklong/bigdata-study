# Kafka 第三课：Consumer Group 与 Rebalance 协议

> **教学目标**：学完本课后，你能解释 Consumer Group 的协调机制、Rebalance 触发条件、三种分配策略的区别，以及如何避免"消费风暴"。

---

## 一、先讲个故事（白话层）

想象一个**外卖配送团队**：

- **Consumer Group** = 配送团队（比如"美团骑手A组"）
- **Consumer** = 骑手
- **Partition** = 配送区域
- **Rebalance** = **重新分配配送区域**

正常情况：3 个骑手负责 6 个区域（每人 2 个区域）。
有骑手请假了（Consumer 下线）→ 团长重新分配区域给剩下的人 = **Rebalance**。
新骑手入职（Consumer 上线）→ 也要重新分配 = **Rebalance**。

**Rebalance 的痛点**：重新分配期间，**所有骑手暂停配送**（Stop The World）！所以要尽量避免频繁 Rebalance。

---

## 二、Consumer Group 协调机制

```
┌─────────────────────────────────────────────┐
│            Kafka Broker Cluster              │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │ Group Coordinator (某个Broker担任)     │  │
│  │                                       │  │
│  │ 职责：                                 │  │
│  │  ① 管理 Group 成员（心跳检测）          │  │
│  │  ② 触发 Rebalance                     │  │
│  │  ③ 选举 Group Leader（Consumer 之一）  │  │
│  │  ④ 存储 offset（__consumer_offsets）   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
         ▲           ▲           ▲
         │ 心跳       │ 心跳       │ 心跳
         │           │           │
┌────────┴──┐ ┌──────┴────┐ ┌───┴─────────┐
│ Consumer-1│ │ Consumer-2│ │ Consumer-3  │
│ (Leader)  │ │ (Follower)│ │ (Follower)  │
│           │ │           │ │             │
│ 负责分配  │ │           │ │             │
│ 策略执行  │ │           │ │             │
└───────────┘ └───────────┘ └─────────────┘
```

### 关键角色

| 角色 | 谁担任 | 职责 |
|------|--------|------|
| **Group Coordinator** | 某个 Broker | 管理 Group 成员、触发 Rebalance |
| **Group Leader** | Group 中的某个 Consumer | 执行分区分配算法 |
| **Group Member** | 其他 Consumer | 接收分配结果 |

---

## 三、Rebalance 触发条件

| 触发事件 | 说明 | 频率 |
|---------|------|------|
| Consumer **加入** Group | 新 Consumer 启动、调用 `subscribe()` | 低 |
| Consumer **离开** Group | 主动 `close()` 或心跳超时 | 中 |
| Consumer **心跳超时** | 超过 `session.timeout.ms` 未发心跳 | **常见！** |
| Consumer **Poll 超时** | 超过 `max.poll.interval.ms` 未调用 poll() | **常见！** |
| Topic **分区数变化** | 管理员新增分区 | 低 |
| **订阅 Topic 变化** | 使用正则订阅时匹配到新 Topic | 低 |

### 最常见的意外 Rebalance 原因

```
"Consumer 处理消息太慢，超过 max.poll.interval.ms → 被踢出 → Rebalance"

解决方案：
  ① 增大 max.poll.interval.ms（默认 300s，可以调到 600s）
  ② 减小 max.poll.records（每次拉取少一点，处理快一点）
  ③ 将消息处理逻辑异步化（拉取和处理分离）
```

---

## 四、三种分区分配策略

### 4.1 RangeAssignor（范围分配，默认）

```
6 个分区，3 个 Consumer：
  Partitions: [P0, P1, P2, P3, P4, P5]
  
  分配：6 / 3 = 2，每人 2 个
  Consumer-1: [P0, P1]
  Consumer-2: [P2, P3]
  Consumer-3: [P4, P5]

问题：当 Topic 数量多时，可能不均匀
  例如 Topic-A(3分区) + Topic-B(3分区)：
  Consumer-1: [A-P0, A-P1, B-P0, B-P1]  ← 4个
  Consumer-2: [A-P2, B-P2]              ← 2个
  不均匀！
```

### 4.2 RoundRobinAssignor（轮询分配）

```
6 个分区，3 个 Consumer：
  按轮询分配：
  Consumer-1: [P0, P3]
  Consumer-2: [P1, P4]
  Consumer-3: [P2, P5]

最均匀的分配方式，但要求 Group 内所有 Consumer 订阅相同的 Topic。
```

### 4.3 StickyAssignor（粘性分配，推荐！）

```
核心思想：在保证均匀的基础上，尽量保持上次的分配结果不变。

初始分配：
  Consumer-1: [P0, P1]
  Consumer-2: [P2, P3]
  Consumer-3: [P4, P5]

Consumer-3 下线，Rebalance 后：
  Consumer-1: [P0, P1, P4]  ← 只新增了 P4
  Consumer-2: [P2, P3, P5]  ← 只新增了 P5
  
  而不是：
  Consumer-1: [P0, P1, P2]  ← Range 会全部重新分配
  Consumer-2: [P3, P4, P5]
  
优势：减少分区迁移 → 减少 Rebalance 对消费的影响
```

### 4.4 CooperativeStickyAssignor（协作式粘性，Kafka 2.4+，**最推荐！**）

```
传统 Rebalance（Eager 模式）：
  ① 所有 Consumer 停止消费
  ② 所有 Consumer 放弃所有分区
  ③ 重新分配
  ④ 重新开始消费
  → Stop The World！

协作式 Rebalance（Cooperative 模式）：
  ① 只有需要迁移的分区才暂停
  ② 不需要迁移的分区继续消费
  ③ 两阶段完成分配
  → 最小化影响！
```

---

## 五、Offset 管理

```
Offset 提交方式：

① 自动提交（enable.auto.commit=true）：
   每隔 auto.commit.interval.ms（默认5s）自动提交
   风险：消息处理失败但 offset 已提交 → 消息丢失

② 手动同步提交（commitSync）：
   consumer.commitSync();
   安全但阻塞，失败会重试

③ 手动异步提交（commitAsync）：
   consumer.commitAsync(callback);
   非阻塞但失败不重试

④ 最佳实践：异步+同步组合
   正常处理时 commitAsync（高吞吐）
   关闭 Consumer 前 commitSync（确保最后一次提交成功）
```

---

## 六、课堂练习

### 练习 1：计算消费能力

> Topic 有 12 个分区，Consumer Group 有 4 个 Consumer。每个 Consumer 每秒处理 1000 条消息。
> 问：Group 的最大消费吞吐？如果增加到 15 个 Consumer 呢？

答：
- 4 Consumer：每人 3 个分区，总吞吐 = 4 × 1000 = 4000 条/s
- 15 Consumer：只有 12 个能分到分区，3 个空闲，总吞吐 = 12 × 1000 = 12000 条/s
- **Consumer 数不应超过分区数**

### 练习 2：举一反三

> "Kafka 的 Consumer Group Rebalance 与 YARN 的容器重分配有什么同构？"

答：
- Kafka Rebalance ≈ YARN 容器重调度（都是资源重分配）
- Kafka Sticky ≈ YARN 的容器本地性保持（尽量不移动）
- Kafka Cooperative ≈ YARN 的增量式调度（只调整变化的部分）

---

## 七、生产配置推荐

```properties
# 避免意外 Rebalance
session.timeout.ms = 45000          # 心跳超时（默认10s太短）
heartbeat.interval.ms = 15000       # 心跳频率（session.timeout的1/3）
max.poll.interval.ms = 600000       # Poll 超时（默认300s，处理慢时调大）
max.poll.records = 200              # 每次拉取条数（别太多，处理不过来）

# 分配策略（推荐协作式粘性）
partition.assignment.strategy = org.apache.kafka.clients.consumer.CooperativeStickyAssignor

# Offset 管理
enable.auto.commit = false          # 手动提交，防丢消息
auto.offset.reset = earliest        # 找不到offset时从头读
```

---

## 八、知识晶体

```
问题/场景: Consumer 频繁 Rebalance 导致消费延迟飙升
核心机制: Group Coordinator + Rebalance Protocol + Partition Assignment Strategy
设计意图: 动态分配分区实现弹性扩缩容，但需要最小化 Rebalance 影响
关键参数:
  session.timeout.ms            → 心跳超时（建议 45s）
  max.poll.interval.ms          → Poll 超时（建议 600s）
  partition.assignment.strategy  → 分配策略（推荐 CooperativeSticky）
踩坑记录:
  - GC 停顿 > session.timeout → 被踢出 → Rebalance
  - 消息处理耗时 > max.poll.interval → 被踢出 → Rebalance
  - Consumer 数 > Partition 数 → 多余 Consumer 空闲
认知更新: Rebalance 是 Kafka 的"双刃剑"——提供了弹性，但频繁触发是性能杀手。用 CooperativeSticky + 合理超时来驯服它
```
