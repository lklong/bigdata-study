# 教案 S01：Flink Checkpoint 机制 — 分布式快照的魔法

> **适用对象**：大数据开发/运维工程师 | **前置知识**：了解 Flink 基础概念  
> **课时**：50 分钟 | **难度**：⭐⭐⭐⭐

---

## 一、课前导入 — 你的流处理作业凌晨挂了

> 凌晨 3 点，你收到告警：一个 Flink 实时 ETL 作业挂了。你从 Savepoint 恢复后，发现**数据要么丢了，要么重复了**。老板问你：Flink 不是号称 Exactly-Once 吗？为什么还会这样？
>
> 答案就藏在 Checkpoint 机制里。理解了它，你才知道什么条件下 Exactly-Once 才成立，什么时候它会退化成 At-Least-Once。

---

## 二、本课目标

学完本课，你能回答：
1. **Checkpoint 到底做了什么？** Barrier 是怎么在算子之间传递的？
2. **CheckpointCoordinator 的核心循环是什么？** 从触发到确认的全链路
3. **什么场景下 Exactly-Once 会失效？** 以及如何避免

---

## 三、核心概念 — 拍全家福的比喻

想象你在给一个正在踢球的足球队拍全家福：

### 问题：球员们在动，你怎么拍到"一致"的照片？

**Flink 的方案**：不让所有人同时停下来，而是让一个"拍照信号"（**Barrier**）像波浪一样从守门员（Source）传到前锋（Sink）。每个球员收到信号后，定格自己的姿势（保存状态），然后把信号传给下一个人。

```
Source → [Barrier] → Map → [Barrier] → KeyBy → [Barrier] → Sink
         ↓               ↓                ↓
    保存 offset        保存计数器        保存窗口状态
```

**关键洞察**：
- Barrier **不需要暂停整个系统**（与 stop-the-world GC 不同）
- 但多输入算子需要 **Barrier 对齐**（Alignment）—— 这是 Exactly-Once 和 At-Least-Once 的分水岭

### Barrier 对齐 vs 不对齐

| | Barrier 对齐（默认） | 不对齐（Unaligned） |
|--|--|--|
| **语义** | Exactly-Once | Exactly-Once（但方式不同） |
| **原理** | 先到的 Barrier 那侧暂停处理，等另一侧 | 不暂停，把未处理的数据也存入 Checkpoint |
| **优势** | Checkpoint 数据量小 | 不会因为对齐导致反压加剧 |
| **代价** | 可能加剧反压 | Checkpoint 数据量大 |
| **适用** | 正常场景 | 已有严重反压时 |

---

## 四、源码精讲

### 4.1 CheckpointCoordinator — 总指挥

> 源码：`flink-runtime/.../checkpoint/CheckpointCoordinator.java` (106KB 巨型类)

```java
// CheckpointCoordinator 是 JM（JobManager）上的核心组件
// 它负责 Checkpoint 的整个生命周期

// 核心方法1：定时触发 Checkpoint
private void startTriggeringCheckpoint(CheckpointTriggerRequest request) {
    // Step 1: 验证——所有 Task 是否都在运行？
    // Step 2: 创建 PendingCheckpoint（占位符）
    // Step 3: 向所有 Source Task 发送 triggerCheckpoint RPC
    // Step 4: 等待所有 Task 汇报完成
}

// 核心方法2：收到 Task 的完成确认
public void receiveAcknowledgeMessage(AcknowledgeCheckpoint message) {
    // 从 PendingCheckpoint 中标记这个 Task 已完成
    // 如果所有 Task 都确认了 → 转为 CompletedCheckpoint
    // 通知所有 Task：这个 Checkpoint 已完成，可以清理旧状态
}
```

**老师画重点**：
- `CheckpointCoordinator` 只运行在 **JobManager** 上
- 它不直接操作状态，只负责"发号施令"和"收集确认"
- 关键超时：`checkpointTimeout` — 超时后这个 Checkpoint 被放弃

### 4.2 StreamTask — 执行者

> 源码：`flink-streaming-java/.../tasks/StreamTask.java` (80KB)

```java
// StreamTask 是每个并行子任务的执行容器
// 收到 CheckpointBarrier 后的处理：

// Step 1: performCheckpoint() — 快照核心方法
void performCheckpoint(CheckpointMetaData metadata, CheckpointOptions options) {
    // 1.1 通知所有算子准备做快照
    operatorChain.prepareSnapshotPreBarrier(checkpointId);

    // 1.2 向下游广播 Barrier
    operatorChain.broadcastEvent(new CheckpointBarrier(checkpointId, timestamp, options));

    // 1.3 异步执行状态快照（不阻塞数据处理）
    for (StreamOperator<?> op : allOperators) {
        op.snapshotState(checkpointId);  // 每个算子保存自己的状态
    }

    // 1.4 汇报给 CheckpointCoordinator
    reportCompletedSnapshotStates(metadata);
}
```

**设计洞察**：
- Barrier 广播在**状态快照之前** — 这保证了下游不会在你还没快照完就开始处理新数据
- 状态快照是**异步的** — 不会阻塞正常的数据处理流水线
- 这就是 Flink 能在高吞吐下做 Checkpoint 而不显著影响延迟的秘密

### 4.3 StateBackend — 状态存储在哪

> 源码：`flink-runtime/.../state/StateBackend.java`

```java
// StateBackend 是一个工厂接口
// 它不存储状态本身，而是创建状态存储的实例

public interface StateBackend extends Serializable {
    // 创建 Keyed State 后端（如 HashMap / RocksDB）
    <K> CheckpointableKeyedStateBackend<K> createKeyedStateBackend(...);

    // 创建 Operator State 后端
    OperatorStateBackend createOperatorStateBackend(...);
}
```

**两大实现对比**：

| | HashMapStateBackend | EmbeddedRocksDBStateBackend |
|--|--|--|
| **存储位置** | JVM 堆内存 | RocksDB（堆外 + 磁盘） |
| **状态大小** | 受堆内存限制（通常 < 10GB） | 仅受磁盘限制（可达 TB 级） |
| **速度** | 极快（内存读写） | 较慢（序列化 + RocksDB IO） |
| **Checkpoint** | 全量快照（大状态时慢） | 增量快照（只传输变化部分） |
| **适用场景** | 小状态、低延迟要求 | 大状态、生产环境首选 |

---

## 五、课堂练习

### 思考题 1：Checkpoint 超时

> 你的 Flink 作业 Checkpoint 总是超时（默认 10 分钟）。可能的原因有哪些？如何逐一排查？

<details>
<summary>参考答案</summary>

1. **反压导致 Barrier 传不过去** — 查看 Web UI 的 BackPressure 面板
2. **状态太大，快照时间超过超时** — 启用增量 Checkpoint（RocksDB 后端）
3. **Checkpoint 存储（HDFS/S3）IO 太慢** — 检查文件系统延迟
4. **GC 暂停** — 检查 TaskManager 的 GC 日志
5. **解决方案**：启用 Unaligned Checkpoint、增大超时、优化状态大小

</details>

### 思考题 2：Exactly-Once 的边界

> Flink 的 Exactly-Once 保证在什么条件下会失效？举 3 个真实场景。

<details>
<summary>参考答案</summary>

1. **Sink 不支持事务** — 如果 Sink 是普通的 Kafka Producer（不用 TwoPhaseCommitSinkFunction），数据可能重复
2. **Source 不支持 Replay** — 如果 Source 是 Socket 或不支持 offset 重置的消息源，恢复时数据会丢失
3. **手动从 Savepoint 恢复但改了算子图** — 状态无法映射回去时，Flink 会丢弃无法恢复的状态

</details>

### 思考题 3：同构类比

> Flink 的 Checkpoint 机制与数据库的哪种技术最相似？为什么？

<details>
<summary>参考答案</summary>

最相似的是 **数据库的 WAL（Write-Ahead Log）+ ARIES 恢复协议**：
- Checkpoint = 数据库的 Checkpoint（刷脏页）
- Barrier = 数据库事务的 Commit Record
- 恢复时从最近的 Checkpoint 重放 = 数据库的 Redo/Undo

但 Flink 的创新在于：**Barrier 随数据流传播，不需要全局暂停**。这比数据库的 stop-and-snapshot 高效得多，是 Chandy-Lamport 分布式快照算法的工程化实现。

</details>

---

## 六、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Flink Checkpoint 机制                             │
├──────────────────────────────────────────────────┤
│  协调器: CheckpointCoordinator (JM 上)             │
│  执行者: StreamTask.performCheckpoint (TM 上)      │
│  传播器: CheckpointBarrier (随数据流传播)           │
│  存储: StateBackend (HashMap / RocksDB)            │
├──────────────────────────────────────────────────┤
│  关键流程:                                         │
│  JM触发 → Source注入Barrier → 算子对齐+快照         │
│  → 汇报确认 → CompletedCheckpoint                  │
├──────────────────────────────────────────────────┤
│  Exactly-Once 条件:                                │
│  1. Source 可重放（如 Kafka offset）                │
│  2. Barrier 对齐（或 Unaligned）                    │
│  3. Sink 支持事务（如 TwoPhaseCommit）              │
├──────────────────────────────────────────────────┤
│  同构类比:                                         │
│  Checkpoint ≈ DB WAL + ARIES                       │
│  Barrier ≈ Chandy-Lamport 分布式快照标记            │
│  StateBackend ≈ DB Buffer Pool                     │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Flink 源码 txProjects/flink/ | 最后更新：2026-04-29*
