# Flink Checkpoint 协议源码深度解析（CheckpointCoordinator + Barrier 对齐）

> 版本: Flink 1.17 系
> 源码路径: `/Users/kailongliu/bigdata/txProjects/flink`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

Flink "exactly-once" 的核心是 Chandy-Lamport 算法的工程化实现 —— 异步 barrier snapshotting。理解 Checkpoint 协议必须搞清楚：
- Checkpoint 是怎么由 JobManager 触发的？怎么保证全局一致性？
- Barrier 在 task 间怎么传播？aligned vs unaligned 的区别？
- 一个 checkpoint 失败/超时时怎么处理？为什么有"checkpoint expired"日志？
- exactly-once / at-least-once 的语义边界在哪？

理解 Checkpoint 是排查"Flink 反压/checkpoint 失败/状态恢复异常/savepoint 卡死"的前置。

## 二、Chandy-Lamport 算法在 Flink 的工程化

### 算法原理（极简版）
1. Coordinator 注入 marker 到所有 source channel
2. 节点收到第一个 marker 后：
   - 立即 snapshot 自身状态
   - 把 marker 转发到所有出 channel
   - 开始记录所有 in-channel 的消息（直到收到对应 in-channel 的 marker）
3. 所有节点 snapshot 完成 + 所有 in-channel 消息记录完毕 → 全局一致快照

### Flink 工程化对应

| 算法概念 | Flink 实现 |
|---------|-----------|
| Coordinator | **CheckpointCoordinator** (JobManager 端) |
| Marker | **CheckpointBarrier** (StreamElement 子类) |
| Source 注入 | `Execution.triggerCheckpoint` RPC → SourceTask 直接生成 barrier |
| 节点 snapshot | `SubtaskCheckpointCoordinator.checkpointState` → `StateBackend.snapshot` |
| In-channel 消息记录 | **Aligned**: barrier 阻塞先到的 channel；**Unaligned**: 不阻塞，把 in-flight 数据当 state 一并 snapshot |
| 全局一致确认 | 所有 task ACK 到 Coordinator → `completePendingCheckpoint` |

## 三、调用链总图

```
[JobManager / CheckpointCoordinator]
   ScheduledTrigger 周期触发 (默认无周期，需显式 enableCheckpointing)
   │
   ▼
CheckpointCoordinator.triggerCheckpoint(boolean isPeriodic)
   │
   ▼
startTriggeringCheckpoint(request)                    ← CheckpointCoordinator.java:630
   │ ① 计算 CheckpointPlan（哪些 task 触发 / 哪些 ACK / 哪些不参与）
   │ ② 异步从 CheckpointIDCounter 拿全局递增的 checkpointID（HA 模式从 ZK）
   │ ③ 创建 PendingCheckpoint
   │ ④ 初始化 CheckpointStorageLocation（HDFS/RocksDB metadata 路径）
   │ ⑤ trigger OperatorCoordinators 的 snapshot
   │ ⑥ snapshot master state（hooks）
   ▼
triggerCheckpointRequest → triggerTasks
   │ 给所有 source task 发 RPC: Execution.triggerCheckpoint
   ▼
[Source TaskExecutor]
StreamTask.triggerCheckpointAsync
   │
   ▼
SubtaskCheckpointCoordinator.checkpointState
   │ ① 调用 source operator 的 snapshotState
   │ ② 把 CheckpointBarrier 注入 output channel（往下游所有 task 发）
   │
   ▼ (网络传输)
[Downstream TaskExecutor]
SingleCheckpointBarrierHandler.processBarrier        ← SingleCheckpointBarrierHandler.java:214
   │ ① 检查是否过期（barrierId < currentCheckpointId）
   │ ② markCheckpointAlignedAndTransformState
   │     - 收第一个 barrier：标记 alignment 开始
   │     - 收齐所有 channel barrier：标记 alignment 结束 → 触发 checkpoint
   │
   ▼
SubtaskCheckpointCoordinator.checkpointState (snapshot 本节点)
   │
   ▼
RPC 反馈：JobMaster.acknowledgeCheckpoint
   │
   ▼
[JobManager / CheckpointCoordinator]
receiveAcknowledgeMessage                             ← CheckpointCoordinator.java:1210
   │ checkpoint.acknowledgeTask(...)
   │ if (checkpoint.isFullyAcknowledged()) → completePendingCheckpoint
   │
   ▼
completePendingCheckpoint                             ← CheckpointCoordinator.java:1365
   │ ① finalizeCheckpoint：写 _metadata 文件
   │ ② addCompletedCheckpointToStoreAndSubsumeOldest（保留 N 个）
   │ ③ pendingCheckpoint.getCompletionFuture().complete(...)
   │ ④ sendAcknowledgeMessages：通知所有 task 持久化已就位（exactly-once sink commit 时机）
```

## 四、关键源码逐段精读

### 4.1 触发 Checkpoint —— triggerCheckpoint 异步链

`CheckpointCoordinator.java:619-786`，删减版核心：

```java
CompletableFuture<CompletedCheckpoint> triggerCheckpoint(
        CheckpointProperties props,
        @Nullable String externalSavepointLocation,
        boolean isPeriodic) {
    CheckpointTriggerRequest request =
            new CheckpointTriggerRequest(props, externalSavepointLocation, isPeriodic);
    chooseRequestToExecute(request).ifPresent(this::startTriggeringCheckpoint);
    return request.onCompletionPromise;
}

private void startTriggeringCheckpoint(CheckpointTriggerRequest request) {
    try {
        synchronized (lock) {
            preCheckGlobalState(request.isPeriodic);   // ① 检查 job 状态
        }
        Preconditions.checkState(!isTriggering);
        isTriggering = true;
        final long timestamp = System.currentTimeMillis();

        // ② 异步链 - Step 1: 计算 CheckpointPlan
        CompletableFuture<CheckpointPlan> checkpointPlanFuture =
                checkpointPlanCalculator.calculateCheckpointPlan();

        CompletableFuture<Void> masterTriggerCompletionPromise = new CompletableFuture<>();

        // ③ 异步链 - Step 2: 拿 checkpointID（HA 模式可能阻塞）
        final CompletableFuture<PendingCheckpoint> pendingCheckpointCompletableFuture =
                checkpointPlanFuture
                    .thenApplyAsync(
                        plan -> {
                            long checkpointID = checkpointIdCounter.getAndIncrement();
                            return new Tuple2<>(plan, checkpointID);
                        },
                        executor)                            // 注意：用 executor 而非 timer
                    .thenApplyAsync(
                        (checkpointInfo) ->
                            createPendingCheckpoint(
                                timestamp, request.props, checkpointInfo.f0,
                                request.isPeriodic, checkpointInfo.f1,
                                request.getOnCompletionFuture(),
                                masterTriggerCompletionPromise),
                        timer);                              // 这里用 timer（单线程）

        // ④ 异步链 - Step 3: 初始化存储位置 + trigger OperatorCoordinator snapshot
        final CompletableFuture<?> coordinatorCheckpointsComplete =
                pendingCheckpointCompletableFuture
                    .thenApplyAsync(
                        pendingCheckpoint -> {
                            CheckpointStorageLocation checkpointStorageLocation =
                                initializeCheckpointLocation(
                                    pendingCheckpoint.getCheckpointID(),
                                    request.props,
                                    request.externalSavepointLocation,
                                    initializeBaseLocations);
                            return Tuple2.of(pendingCheckpoint, checkpointStorageLocation);
                        },
                        executor)
                    .thenComposeAsync(
                        (checkpointInfo) -> {
                            PendingCheckpoint pendingCheckpoint = checkpointInfo.f0;
                            synchronized (lock) {
                                pendingCheckpoint.setCheckpointTargetLocation(checkpointInfo.f1);
                            }
                            return OperatorCoordinatorCheckpoints
                                .triggerAndAcknowledgeAllCoordinatorCheckpointsWithCompletion(
                                    coordinatorsToCheckpoint, pendingCheckpoint, timer);
                        },
                        timer);

        // ⑤ 异步链 - Step 4: snapshot master state (hooks)
        final CompletableFuture<?> masterStatesComplete =
                coordinatorCheckpointsComplete.thenComposeAsync(
                    ignored -> snapshotMasterState(checkpoint), timer);

        // ⑥ 等所有 master 端 snapshot 完成
        FutureUtils.forward(
            CompletableFuture.allOf(masterStatesComplete, coordinatorCheckpointsComplete),
            masterTriggerCompletionPromise);

        // ⑦ 最终 trigger 各 source task 的 RPC（真正发 RPC 在这里）
        FutureUtils.assertNoException(
            masterTriggerCompletionPromise.handleAsync(
                (ignored, throwable) -> {
                    if (throwable != null) {
                        onTriggerFailure(checkpoint, throwable);
                    } else {
                        triggerCheckpointRequest(request, timestamp, checkpoint);  // ← Trigger tasks
                    }
                    return null;
                }, timer));
    } catch (Throwable throwable) {
        onTriggerFailure(request, throwable);
    }
}
```

**七步异步链精髓**：
1. ① **状态检查** —— 同步 lock，确保 job 处于可触发状态
2. ② **计算 CheckpointPlan** —— 哪些 task 是 trigger task（source）/ 哪些是 ACK task / 哪些 finished 不参与（FLINK-21515）
3. ③ **分配 checkpointID + 创建 PendingCheckpoint** —— ID 来自 ZK（HA）或本地计数器
4. ④ **初始化 storage + trigger OperatorCoordinator** —— Source coordinator 等
5. ⑤ **Master state snapshot** —— `MasterTriggerRestoreHook` 用户钩子
6. ⑥ **等 master 端就绪**
7. ⑦ **Trigger Tasks** —— 给所有 source task 发 RPC

**为什么这么复杂**？—— 因为：
- 不能在 task 还没准备好之前发 RPC（race）
- HA 模式下 checkpointID 必须先持久化到 ZK，否则 JM 重启会冲突
- OperatorCoordinator（如 Source enumerator）的 state 必须先 snapshot 完，task 端才能 snapshot 一致状态
- 整个流程异步避免阻塞 timer 线程（Coordinator 单线程模型）

### 4.2 Barrier 对齐 —— processBarrier

`SingleCheckpointBarrierHandler.java:214-279`：

```java
public void processBarrier(
        CheckpointBarrier barrier, InputChannelInfo channelInfo, boolean isRpcTriggered)
        throws IOException {
    long barrierId = barrier.getId();

    // ① 过期 barrier 检测：当前 checkpoint 已超过这个 barrierId
    if (currentCheckpointId > barrierId
            || (currentCheckpointId == barrierId && !isCheckpointPending())) {
        if (!barrier.getCheckpointOptions().isUnalignedCheckpoint()) {
            inputs[channelInfo.getGateIdx()].resumeConsumption(channelInfo);
        }
        return;
    }

    // ② 检查是否新 checkpoint，如果是则初始化 state
    checkNewCheckpoint(barrier);
    checkState(currentCheckpointId == barrierId);

    // ③ 标记本 channel 已对齐 + 状态机转移
    markCheckpointAlignedAndTransformState(
        channelInfo,
        barrier,
        state -> state.barrierReceived(context, channelInfo, barrier, !isRpcTriggered));
}

protected void markCheckpointAlignedAndTransformState(
        InputChannelInfo alignedChannel,
        CheckpointBarrier barrier,
        FunctionWithException<BarrierHandlerState, BarrierHandlerState, Exception>
                stateTransformer) throws IOException {
    alignedChannels.add(alignedChannel);

    // ④ 第一个 channel 对齐 → 标记 alignment 开始
    if (alignedChannels.size() == 1) {
        if (targetChannelCount == 1) {
            markAlignmentStartAndEnd(barrier.getId(), barrier.getTimestamp());
        } else {
            markAlignmentStart(barrier.getId(), barrier.getTimestamp());
        }
    }

    // ⑤ 所有 channel 对齐 → 标记 alignment 结束（在调用 barrierReceived 之前）
    if (alignedChannels.size() == targetChannelCount) {
        if (targetChannelCount > 1) {
            markAlignmentEnd();
        }
    }

    try {
        currentState = stateTransformer.apply(currentState);   // ⑥ 状态机转移
    } catch (CheckpointException e) {
        abortInternal(currentCheckpointId, e);
    }

    // ⑦ 全部对齐 → 触发 task 端 snapshot
    if (alignedChannels.size() == targetChannelCount) {
        alignedChannels.clear();
        lastCancelledOrCompletedCheckpointId = currentCheckpointId;
        resetAlignmentTimer();
        allBarriersReceivedFuture.complete(null);   // ← 通知 StreamTask 开始 snapshot
    }
}
```

**对齐过程的精髓**（aligned checkpoint）：

```
Channel 1: ──record──record──[Barrier-5]──record──record──   ← 收到 Barrier 后阻塞
                                ↑ 阻塞在这里等 Channel 2

Channel 2: ──record──record──record──record──[Barrier-5]──   ← 还没到 Barrier
                                                ↑ 收到这个才能开始 snapshot

→ Channel 1 阻塞期间数据堆积在 buffer，造成反压
→ 全部 channel 收齐 Barrier → snapshot 本节点 → 转发 Barrier 到下游
```

**关键点**：在 `barrierReceived` 状态转移过程中决定**是否做 snapshot**：
- `AlignedBarrierHandlerState`：阻塞 channel，等齐了 snapshot
- `AlternatingCollectingBarriersUnaligned`：不阻塞，把 in-flight buffer 一并 snapshot

### 4.3 完成 Checkpoint —— receiveAcknowledgeMessage + completePendingCheckpoint

`CheckpointCoordinator.java:1210-1402`，删减版：

```java
public boolean receiveAcknowledgeMessage(
        AcknowledgeCheckpoint message, String taskManagerLocationInfo)
        throws CheckpointException {
    if (shutdown || message == null) return false;
    if (!job.equals(message.getJob())) return false;

    final long checkpointId = message.getCheckpointId();
    synchronized (lock) {
        if (shutdown) return false;

        final PendingCheckpoint checkpoint = pendingCheckpoints.get(checkpointId);

        // ① 注册 shared state（增量 checkpoint 关键 —— 多个 ckpt 共享同一个 sst 文件）
        if (message.getSubtaskState() != null) {
            if (checkpoint == null || !checkpoint.getProps().isSavepoint()) {
                message.getSubtaskState()
                    .registerSharedStates(
                        completedCheckpointStore.getSharedStateRegistry(), checkpointId);
            }
        }

        if (checkpoint != null && !checkpoint.isDisposed()) {
            // ② 给 PendingCheckpoint 喂 ACK
            switch (checkpoint.acknowledgeTask(
                    message.getTaskExecutionId(),
                    message.getSubtaskState(),
                    message.getCheckpointMetrics())) {
                case SUCCESS:
                    // ③ 全部 ACK 到位 → 完成 checkpoint
                    if (checkpoint.isFullyAcknowledged()) {
                        completePendingCheckpoint(checkpoint);
                    }
                    break;
                case DUPLICATE:
                    // 重复 ACK，正常忽略
                    break;
                case UNKNOWN:
                    // task execution attempt id 未知，是过期 ACK
                    discardSubtaskState(...);
                    break;
            }
        }
    }
    return true;
}

private void completePendingCheckpoint(PendingCheckpoint pendingCheckpoint)
        throws CheckpointException {
    final long checkpointId = pendingCheckpoint.getCheckpointID();
    final CompletedCheckpoint completedCheckpoint;
    final CompletedCheckpoint lastSubsumed;
    final CheckpointProperties props = pendingCheckpoint.getProps();

    // ① shared state registry 标记本 checkpoint 完成
    completedCheckpointStore.getSharedStateRegistry().checkpointCompleted(checkpointId);

    try {
        // ② finalizeCheckpoint：把 metadata 写入 storage（HDFS/file:// 等）
        completedCheckpoint = finalizeCheckpoint(pendingCheckpoint);

        // ③ 加入 completedCheckpointStore，超出 maxRetainedCheckpoints 的旧 ckpt 被 subsumed
        if (!props.isSavepoint()) {
            lastSubsumed = addCompletedCheckpointToStoreAndSubsumeOldest(
                checkpointId, completedCheckpoint, pendingCheckpoint);
        } else {
            lastSubsumed = null;
        }

        // ④ 完成 future（用户拿到 CompletedCheckpoint 引用）
        pendingCheckpoint.getCompletionFuture().complete(completedCheckpoint);
        reportCompletedCheckpoint(completedCheckpoint);
    } finally {
        pendingCheckpoints.remove(checkpointId);
        scheduleTriggerRequest();   // 触发下一个排队的 checkpoint
    }

    // ⑤ 清理：drop subsumed checkpoint + 给所有 task 发 notifyCheckpointComplete
    cleanupAfterCompletedCheckpoint(
        pendingCheckpoint, checkpointId, completedCheckpoint, lastSubsumed, props);
}
```

**完成阶段最关键的事 —— `notifyCheckpointComplete`**：
- 这是 **exactly-once sink 提交事务的时机**
- 比如 `TwoPhaseCommitSinkFunction`：在 `snapshotState` 时 prepare 事务，在 `notifyCheckpointComplete` 时 commit
- 如果 notify 失败（task 已挂），事务保持 prepare 状态，**等 job restart 后从 ckpt 恢复时再 commit**（这就是 exactly-once 的兜底机制）

## 五、Aligned vs Unaligned Checkpoint 对比

| 维度 | Aligned | Unaligned |
|------|---------|----------|
| **反压时表现** | barrier 卡在快通道，慢通道堆积 → 长尾 | barrier 直接超车，把 in-flight 数据一并 snapshot |
| **snapshot 大小** | 仅 operator state | operator state + in-flight buffer state |
| **恢复速度** | 快（只恢复 operator state） | 慢（需要 replay in-flight buffer） |
| **适用场景** | 无反压稳定流 | 高反压、checkpoint 频繁超时 |
| **配置** | 默认 | `execution.checkpointing.unaligned=true` |
| **超时降级** | N/A | `execution.checkpointing.aligned-checkpoint-timeout=30s`：超时自动转 unaligned |

**经验法则**：
- 稳定流 → aligned（默认）
- 反压频繁、ckpt timeout 多 → 配 aligned-checkpoint-timeout 让自动降级
- 极端反压 → 直接 unaligned

## 六、实战 LOG 对齐

| 日志关键词 | 出处 | 含义 |
|----------|------|------|
| `Triggering Checkpoint X for job Y failed due to ...` | `CheckpointCoordinator.java:802` | 触发失败 |
| `Received acknowledge message for checkpoint X from task Y` | `CheckpointCoordinator.java:1259` (DEBUG) | 单 task ACK |
| `Received a duplicate acknowledge message` | `CheckpointCoordinator.java:1271` (DEBUG) | 重复 ACK，无害 |
| `Could not acknowledge the checkpoint X for task Y ... unknown` | `CheckpointCoordinator.java:1279` | task 已 cancelled，过期 ACK |
| `Checkpoint X size: NKb, duration: Mms` | `CheckpointCoordinator.java:1408` (TRACE) | 完成统计 |
| `Received barrier from channel ... @ ...` | `SingleCheckpointBarrierHandler.java:218` (DEBUG) | barrier 到达 |
| `All the channels are aligned for checkpoint X` | `SingleCheckpointBarrierHandler.java:272` (DEBUG) | 对齐完成，开始 snapshot |
| `Triggering checkpoint X on the barrier announcement` | `SingleCheckpointBarrierHandler.java:282` (DEBUG) | RPC 触发的 ckpt |
| `Obsolete announcement of checkpoint X for channel Y` | `SingleCheckpointBarrierHandler.java:299` (DEBUG) | 过期 announcement |

**故障排查路径**：
- "Checkpoint expired" → ckpt 总耗时超过 `checkpoint.timeout`，检查反压（aligned 时）或 state 大小（unaligned）
- "Decline checkpoint" → 某 task 主动拒绝，看 task log 找原因
- "Async checkpoint" 卡 → state backend 上传 HDFS/S3 慢

## 七、设计意图总结

| 设计 | 为什么 |
|------|-------|
| Coordinator 单线程 timer + worker executor 双线程模型 | timer 不能阻塞，所有 IO 操作在 executor 中跑 |
| PendingCheckpoint 收 ACK 计数 | 异步收集分布式快照确认，松散一致性 |
| CompletableFuture 异步链 | 多步操作不阻塞 timer，错误处理统一 |
| Aligned 默认 + Unaligned 可配 | aligned 简单可靠，unaligned 解决反压场景 |
| Shared state registry | 增量 checkpoint：多个 ckpt 共享 sst 文件，引用计数 |
| `notifyCheckpointComplete` 在持久化后 | exactly-once 关键：先存盘再让 sink commit，崩溃也能恢复 |
| 异步 + 增量 snapshot | 不阻塞业务流，state 大也能保持低 ckpt 耗时 |

## 八、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `execution.checkpointing.interval` | 0 (disabled) | ckpt 周期，必须显式开启 |
| `execution.checkpointing.timeout` | 10min | 单次 ckpt 超时 |
| `execution.checkpointing.min-pause` | 0 | 两次 ckpt 之间的最小间隔（防止背靠背）|
| `execution.checkpointing.max-concurrent-checkpoints` | 1 | 最大并发 ckpt 数 |
| `execution.checkpointing.tolerable-failed-checkpoints` | 0 | 容忍连续失败次数（超过 fail job）|
| `execution.checkpointing.unaligned` | false | 启用 unaligned ckpt |
| `execution.checkpointing.aligned-checkpoint-timeout` | 0 | aligned 超时降级到 unaligned |
| `execution.checkpointing.externalized-checkpoint-retention` | NO_EXTERNALIZED_CHECKPOINTS | RETAIN/DELETE on cancel |
| `state.checkpoints.num-retained` | 1 | 保留 N 个 completed ckpt |
| `state.checkpoints.dir` | (无) | ckpt 元数据存储位置 |
| `state.savepoints.dir` | (无) | savepoint 存储位置 |
| `state.backend.incremental` | false (rocksdb 默认 true) | 是否增量 |

## 九、踩坑记录

1. **Checkpoint 超时（最高频）** —— "Checkpoint xxx expired before completing"。**根因**：① 反压（aligned 阻塞）② state 太大上传慢 ③ DataStream 算子有重操作。**应对**：开 unaligned-checkpoint，调大 timeout，分析 backpressure 来源。
2. **Checkpoint 大小爆炸** —— state.size MB 级别正常，GB 级别就要警惕。**根因**：① 用了 ListState/MapState 但没及时清理 ② TTL 没设。**应对**：检查 state 使用模式，加 TTL（`StateTtlConfig`）。
3. **Tolerable failed checkpoints** —— 默认为 0，一次失败就 fail job。**生产建议**：调到 3-5，避免临时网络抖动炸 job。
4. **Externalized checkpoint 没保留** —— job cancel 后 ckpt 被删，再启动只能从头跑。**应对**：`externalized-checkpoint-retention=RETAIN_ON_CANCELLATION`。
5. **HA 模式 ckptId 冲突** —— ZK 没清干净，新 job 用了老 job 的 ckptId 路径。**应对**：HA 模式用唯一 cluster-id（`high-availability.cluster-id`）。
6. **Unaligned + Source 端开** —— Source operator 的 input gate 不是真实 input，无法用 unaligned。**应对**：unaligned 仅对中间算子有效。
7. **Coordinator 单线程瓶颈** —— 大型 job（10000+ task）触发 ckpt 时，coordinator 的 timer 线程积压。**应对**：调大 `min-pause` 减少 ckpt 频率，或考虑分层 region failover。

## 十、认知更新

- 之前以为 trigger 是同步发 RPC，**实际上是七步 CompletableFuture 异步链**，目的是不阻塞 timer 单线程。
- 之前以为 barrier 对齐就是"等齐"，**实际上是状态机驱动的状态转移**：每收到一个 barrier 都触发 `BarrierHandlerState` 状态机，状态决定是否阻塞、何时 snapshot、何时 abort。
- `notifyCheckpointComplete` 是 exactly-once 的关键 —— 不只是个通知，而是 sink 提交事务的同步点。**KafkaSink/JdbcSink 的事务 commit 都在这里**。
- Unaligned ckpt 的 in-flight buffer 是被**当作 state 一部分** snapshot 的，恢复时要 replay 这些 buffer，**所以恢复比 aligned 慢**。
- Shared state registry（增量 ckpt 的核心）：每个 ckpt 持有 RocksDB sst 文件的"引用"，旧 ckpt 删除时检查引用计数 → 共享文件不会被误删。**机制类似 Java 引用计数 GC**。

## 十一、下一步深挖方向

- [ ] StateBackend 的 RocksDB 增量 snapshot 实现（IncrementalRemoteKeyedStateHandle）
- [ ] CheckpointPlan 的计算逻辑（FLINK-21515 finished task 处理）
- [ ] BarrierHandlerState 的几种实现：AlignedBarrierHandlerState / AlternatingCollectingBarriers / etc.
- [ ] 2PC Sink 的精确语义（TwoPhaseCommitSinkFunction → SinkV2）
- [ ] Region failover vs full restart 的边界

---

**沉淀完成。Chandy-Lamport 算法到 Flink 工程化的映射 + 触发/对齐/完成三阶段源码精确对齐 + aligned/unaligned 对比清晰。**
