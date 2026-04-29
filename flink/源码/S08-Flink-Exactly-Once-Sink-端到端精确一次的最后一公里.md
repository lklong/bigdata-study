# 教案 S08：Flink Exactly-Once Sink — 端到端精确一次的最后一公里

> **课时**：40分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入

> Flink 内部通过 Checkpoint 保证了 Exactly-Once。但数据最终要写到外部系统（Kafka/MySQL/HDFS）。如果 Checkpoint 成功了但 Sink 写入后系统崩了，重启后 Sink 会**重复写入**。端到端 Exactly-Once 的最后一公里，靠的是 **Two-Phase Commit（2PC）协议**。

## 二、Two-Phase Commit — 两阶段提交

### 和银行转账的类比

```
第一阶段（Pre-commit / 投票阶段）:
  - 银行先冻结转出账户的钱（但不实际扣）
  - 冻结转入账户的位置（但不实际加）
  → 对应 Flink: Checkpoint 时把数据写入 Kafka 的事务（未提交）

第二阶段（Commit / 提交阶段）:
  - Checkpoint 成功通知到来 → 真正提交 Kafka 事务
  - 如果 Checkpoint 失败 → 回滚 Kafka 事务（数据丢弃）
```

### Kafka Sink 的 Exactly-Once 实现

```java
// TwoPhaseCommitSinkFunction 核心流程

// Phase 1: 每条数据写入当前 Kafka 事务（未提交）
void invoke(value) {
    kafkaProducer.send(record);  // 写入事务缓冲区
}

// Checkpoint 触发时: 刷新 + 预提交
void snapshotState(checkpointId) {
    kafkaProducer.flush();             // 确保数据发到 Kafka Broker
    currentTransaction.preCommit();     // 记录事务 ID 到 Checkpoint 状态
    beginNewTransaction();              // 开始新事务
}

// Checkpoint 完成通知: 真正提交
void notifyCheckpointComplete(checkpointId) {
    kafkaProducer.commitTransaction();  // 正式提交！消费者现在能看到数据了
}

// Checkpoint 失败/超时: 回滚
void notifyCheckpointAborted(checkpointId) {
    kafkaProducer.abortTransaction();   // 回滚！数据丢弃
}
```

## 三、Exactly-Once 对 Kafka 消费者的影响

| 消费者 isolation.level | 能看到什么 | 适用场景 |
|---|---|---|
| `read_uncommitted`（默认） | 事务提交前就能看到数据 | 不关心重复 |
| `read_committed` | 只能看到已提交的事务数据 | **必须配合 Exactly-Once** |

```properties
# 消费端必须设置
consumer.isolation.level = read_committed
```

## 四、哪些 Sink 支持 Exactly-Once？

| Sink | 机制 | 配置 |
|------|------|------|
| **Kafka** | Kafka 事务 | `semantic = EXACTLY_ONCE` |
| **JDBC/MySQL** | XA 事务 | JdbcExactlyOnceSinkFunction |
| **Iceberg** | IcebergFilesCommitter | Checkpoint 时原子提交 |
| **HDFS/S3** | 文件 rename 原子性 | StreamingFileSink |
| **Elasticsearch** | 幂等写入（upsert） | 不是真 E-O，是 At-Least-Once + 幂等 |
| **Redis** | 幂等 SET | 同上 |

## 五、课堂练习

### 思考题：Kafka Exactly-Once Sink 的事务超时怎么配？

<details>
<summary>参考答案</summary>

Kafka 事务默认超时 = 15 分钟（`transaction.timeout.ms`）。
Flink Checkpoint 间隔如果 > 15 分钟，事务会在 Checkpoint 完成前超时被 Kafka 自动 abort！

配置原则：`transaction.timeout.ms > checkpoint.interval + checkpoint.timeout`

```properties
# Flink Kafka Sink
properties.transaction.timeout.ms = 900000  # 15min（需 < Kafka Broker 的 max）

# Kafka Broker 端
transaction.max.timeout.ms = 3600000  # 允许最长 1 小时事务
```
</details>

## 六、知识晶体

```
端到端 Exactly-Once = Flink Checkpoint + 2PC Sink
2PC: 数据写入(Phase1) → Checkpoint成功则commit(Phase2) / 失败则abort
Kafka: semantic=EXACTLY_ONCE + 消费端read_committed
HDFS/Iceberg: 利用文件系统rename/Iceberg OCC的原子性
关键: transaction.timeout > checkpoint.interval + timeout
```

*教案作者：Eric | 最后更新：2026-04-30*
