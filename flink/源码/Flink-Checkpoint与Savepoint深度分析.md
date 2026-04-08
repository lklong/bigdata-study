# Flink Checkpoint 与 Savepoint 深度分析

> Flink Expert 补课学习 — 流计算核心容错机制

## 一、Checkpoint 核心原理

### 1.1 Chandy-Lamport 分布式快照算法

```
Flink 的 Checkpoint 基于 Chandy-Lamport 算法的变体:

1. JobManager (CheckpointCoordinator) 触发 Checkpoint
2. 向所有 Source 算子注入 Checkpoint Barrier
3. Barrier 随数据流向下游传播
4. 每个算子收到所有输入的 Barrier 后:
   a. 暂停处理新数据（对齐模式）
   b. 将当前状态快照到 State Backend
   c. 向 CheckpointCoordinator 汇报完成
   d. 继续处理
5. 所有算子汇报完成 → Checkpoint 成功

时间线:
  Source ──[data]──[barrier]──[data]──→ Map ──→ Sink
                     ↓
              State Backend (HDFS/RocksDB)
```

### 1.2 对齐 vs 非对齐 Checkpoint

```
对齐 Checkpoint (Aligned, 默认):
  ┌─ Input 1 ──[data][barrier]──────────────────────────→
  │                          ↓ 等待 Input 2 的 barrier
  │                          ↓ (Input 1 的数据被缓存)
  └─ Input 2 ──[data]──[data]──[barrier]────────────────→
                                    ↓
                              两个 barrier 对齐
                              → 做快照 → 继续

  问题: Input 1 的数据在等待期间被缓存 → 背压传导 → 延迟增加
  适用: 精确一次语义 (Exactly-Once)

非对齐 Checkpoint (Unaligned, Flink 1.11+):
  ┌─ Input 1 ──[data][barrier]──→ 立即做快照！
  │                    ↓
  │              不等 Input 2
  │              把 in-flight 数据也存入快照
  └─ Input 2 ──[data]──[data]──[barrier]──→

  优点: 不阻塞数据流，背压场景下 Checkpoint 更快完成
  代价: 快照更大（包含 in-flight 数据）、恢复更慢
  适用: 高背压场景 + 对 Checkpoint 时间敏感
```

### 1.3 Checkpoint Barrier 传播源码

```java
// StreamTask.java — 处理 Checkpoint Barrier
public void processInput(MailboxDefaultAction.Controller controller) {
    // 从 InputGate 读取数据或 Barrier
    InputStatus status = inputProcessor.processInput();
    // 如果是 Barrier → 触发 CheckpointBarrierHandler
}

// SingleCheckpointBarrierHandler.java
// 对齐模式: 收到第一个 Barrier → 开始缓存该 channel 的数据
// 收到所有 channel 的 Barrier → 触发 triggerCheckpoint()

// CheckpointBarrierUnaligner.java
// 非对齐模式: 收到第一个 Barrier → 立即触发快照
// 将其他 channel 的 in-flight 数据一起保存
```

## 二、State Backend 深度对比

### 2.1 三种 State Backend

| 维度 | MemoryStateBackend | FsStateBackend | RocksDBStateBackend |
|------|-------------------|----------------|---------------------|
| 状态存储 | JVM 堆内存 | JVM 堆内存 | RocksDB (磁盘) |
| Checkpoint 存储 | JobManager 内存 | 文件系统 (HDFS) | 文件系统 (HDFS) |
| 状态大小限制 | ~5MB/状态 | ~JVM 堆大小 | **无限制** (磁盘) |
| 读写性能 | 最快 (内存) | 快 (内存) | 慢 (磁盘序列化) |
| 增量 Checkpoint | ❌ | ❌ | **✅** |
| 适用场景 | 测试/小状态 | 中等状态 | **大状态 (TB级)** |

### 2.2 RocksDB 增量 Checkpoint（关键特性）

```
全量 Checkpoint:
  每次快照整个 RocksDB → 状态 100GB → 每次传 100GB → 慢！

增量 Checkpoint:
  第一次: 全量快照 → base SST files
  第二次: 只传新增/修改的 SST files → 可能只有 1GB
  第三次: 继续增量 → 只传 delta

  优势: 100GB 状态，增量只传 1-5GB → Checkpoint 时间从分钟级降到秒级

配置:
  state.backend: rocksdb
  state.backend.incremental: true
  state.backend.rocksdb.checkpoint.transfer.thread.num: 4
```

### 2.3 RocksDB 调优

```yaml
# RocksDB 核心参数
state.backend.rocksdb.memory.managed: true          # 使用 Flink 管理的内存
state.backend.rocksdb.memory.write-buffer-ratio: 0.5 # 写缓冲比例
state.backend.rocksdb.memory.high-prio-pool-ratio: 0.1
state.backend.rocksdb.writebuffer.size: 64MB         # 单个 memtable 大小
state.backend.rocksdb.writebuffer.count: 3           # memtable 数量
state.backend.rocksdb.compaction.level.max-size-level-base: 256MB
state.backend.rocksdb.thread.num: 4                  # 后台 compaction 线程数
```

## 三、Savepoint vs Checkpoint

| 维度 | Checkpoint | Savepoint |
|------|-----------|-----------|
| 触发方式 | 自动（定时） | 手动（`flink savepoint <jobId>`） |
| 用途 | 故障恢复 | 版本升级/迁移/停机维护 |
| 生命周期 | 被新 CP 覆盖 | 永久保留 |
| 格式 | 可能是增量的 | 始终是全量的 |
| 兼容性 | 仅同 Job | 跨 Job（需 UID 匹配） |
| 性能影响 | 低（增量） | 高（全量） |

### 3.1 Savepoint 最佳实践

```bash
# 1. 停止 Job 并创建 Savepoint（优雅停机）
flink stop --savepointPath hdfs:///savepoints <jobId>

# 2. 从 Savepoint 恢复
flink run -s hdfs:///savepoints/savepoint-xxx -c com.example.MyJob my-job.jar

# 3. 关键: 算子必须设置 UID！否则无法从 Savepoint 恢复
env.addSource(source).uid("source-uid")
   .map(mapper).uid("map-uid")
   .addSink(sink).uid("sink-uid")
```

## 四、Checkpoint 故障排查

### 4.1 Checkpoint 超时

```
现象: Checkpoint expired before completing
原因排查:
  1. 背压导致 Barrier 传播慢 → 检查 backPressuredTimeMsPerSecond
  2. 状态太大，快照时间超过 timeout → 增大 timeout 或开启增量 CP
  3. State Backend 写入慢 → HDFS 带宽瓶颈 / RocksDB compaction 导致 stall
  4. GC 暂停导致 TaskManager 无响应

解决:
  execution.checkpointing.timeout: 600000    # 10 分钟
  execution.checkpointing.unaligned: true    # 开启非对齐
  state.backend.incremental: true            # 增量 CP
```

### 4.2 Checkpoint 文件膨胀

```
现象: HDFS 上 Checkpoint 目录越来越大
原因: retained checkpoint 数量过多 / 增量 CP 的 SST 文件累积

解决:
  state.checkpoints.num-retained: 3         # 只保留最近 3 个
  # 定期触发 Savepoint → 清理旧的增量 CP 链
```

### 4.3 从 Checkpoint 恢复后数据不一致

```
原因:
  1. Source 不支持 replay (如 socket) → 至少一次语义
  2. Sink 不支持幂等/事务 → 可能重复写入
  3. 外部系统状态未回滚

确保精确一次:
  Source: 支持 offset 回放 (Kafka/Kinesis)
  Sink:   支持事务提交 (Kafka TwoPhaseCommitSink / JDBC 事务)
  处理:   开启对齐 Checkpoint
```

## 五、生产配置模板

```yaml
# Checkpoint 配置
execution.checkpointing.interval: 60000           # 1 分钟
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 600000            # 10 分钟超时
execution.checkpointing.min-pause: 30000           # 两次 CP 最小间隔
execution.checkpointing.max-concurrent-checkpoints: 1
execution.checkpointing.unaligned: false           # 默认对齐
execution.checkpointing.tolerable-failed-checkpoints: 3

# State Backend
state.backend: rocksdb
state.backend.incremental: true
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints
state.checkpoints.num-retained: 3

# RocksDB
state.backend.rocksdb.memory.managed: true
state.backend.rocksdb.checkpoint.transfer.thread.num: 4
```

## 六、关键源码索引

| 文件 | 内容 |
|------|------|
| `CheckpointCoordinator.java` | CP 触发和协调 |
| `SingleCheckpointBarrierHandler.java` | 对齐模式 Barrier 处理 |
| `CheckpointBarrierUnaligner.java` | 非对齐模式 |
| `RocksDBStateBackend.java` | RocksDB 后端实现 |
| `RocksDBIncrementalSnapshotStrategy.java` | 增量快照策略 |
| `SavepointV2Serializer.java` | Savepoint 格式 |

---

*Flink Expert 学习产出 | 2026-04-08 | 补课：核心容错机制*
