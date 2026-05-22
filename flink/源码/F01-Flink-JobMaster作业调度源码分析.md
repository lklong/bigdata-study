# Flink JobMaster 作业调度源码分析

> **源码路径**：`txProjects/flink/flink-runtime/src/main/java/org/apache/flink/runtime/jobmaster/JobMaster.java`（72.28 KB）
> **铁律遵守**：所有方法名、行号引用均来自上述真实源码

---

## 一、JobMaster 定位

**官方注释（JobMaster.java:143-153）**：
```java
143: /**
144:  * JobMaster implementation. The job master is responsible for the execution of a single {@link
145:  * JobGraph}.
146:  *
147:  * <p>It offers the following methods as part of its rpc interface to interact with the JobMaster
148:  * remotely:
149:  *
150:  * <ul>
151:  *   <li>{@link #updateTaskExecutionState} updates the task execution state for given task
152:  * </ul>
153:  */
```

**核心职责**：
- 管理**单个 Flink Job** 的全生命周期
- 注册 TaskManager，分配 Slot
- 调度 ExecutionGraph 中的所有 Task
- 协调 Checkpoint
- 处理 Task 状态汇报

**与 YARN/K8s 的区别**：
- YARN ApplicationMaster = Flink JobMaster + ResourceManagerConnection
- 一个 Flink 集群可能有多个 JobMaster（per-job 模式）

---

## 二、类继承关系（JobMaster.java:154-158）

```java
154: public class JobMaster extends FencedRpcEndpoint<JobMasterId>
155:         implements JobMasterGateway, JobMasterService {
156:
157:     /** Default names for Flink's distributed components. */
158:     public static final String JOB_MANAGER_NAME = "jobmanager";
```

**继承链**：
- `FencedRpcEndpoint<JobMasterId>` — 带 fencing token 的 RPC 端点（防止脑裂）
- `JobMasterGateway` — RPC 客户端代理接口
- `JobMasterService` — 内部服务接口

**Fencing Token 机制**：
- HA 切主时，新 JobMaster 持有新 token
- 旧 JobMaster 的请求会被识别并拒绝（避免脑裂）

---

## 三、核心字段（JobMaster.java:162-178）

```java
162:     private final JobMasterConfiguration jobMasterConfiguration;
163:
164:     private final ResourceID resourceId;
165:
166:     private final JobGraph jobGraph;                         // ⭐ 用户提交的 JobGraph
167:
168:     private final Time rpcTimeout;
169:
170:     private final HighAvailabilityServices highAvailabilityServices;
171:
172:     private final BlobWriter blobWriter;
173:
174:     private final HeartbeatServices heartbeatServices;
175:
176:     private final ScheduledExecutorService futureExecutor;
177:
178:     private final Executor ioExecutor;
```

**关键依赖**：
- **JobGraph**：用户 program 经过 StreamGraph → JobGraph 转换后的逻辑图
- **HighAvailabilityServices**：JobManager 选主、ResourceManager 发现
- **BlobWriter**：分发用户 jar、UDF 字节码
- **HeartbeatServices**：心跳框架（监控 TM、RM 死活）

---

## 四、startJobExecution 核心调度入口（JobMaster.java:1126-1141）

```java
1126: private void startJobExecution() throws Exception {
1127:     validateRunsInMainThread();                         // ⭐ 必须在 main thread
1128:
1129:     JobShuffleContext context = new JobShuffleContextImpl(jobGraph.getJobID(), this);
1130:     shuffleMaster.registerJob(context);                 // ⭐ 注册 Shuffle Master
1131:
1132:     startJobMasterServices();                            // ⭐ 启动核心服务
1133:
1134:     log.info(
1135:             "Starting execution of job '{}' ({}) under job master id {}.",
1136:             jobGraph.getName(),
1137:             jobGraph.getJobID(),
1138:             getFencingToken());
1139:
1140:     startScheduling();                                   // ⭐ 启动 SchedulerNG
1141: }
```

**4 步启动**：
1. `validateRunsInMainThread()` — 单线程模型校验（JobMaster 主流程必须在 main thread）
2. `shuffleMaster.registerJob()` — 注册到 ShuffleMaster（管理 result partition）
3. `startJobMasterServices()` — 启动 SlotPool、连接 ResourceManager
4. `startScheduling()` — 委托给 SchedulerNG（DefaultScheduler / AdaptiveScheduler）

---

## 五、startJobMasterServices 服务装配（JobMaster.java:1143-1160）

```java
1143: private void startJobMasterServices() throws Exception {
1144:     try {
1145:         this.taskManagerHeartbeatManager = createTaskManagerHeartbeatManager(heartbeatServices);
1146:         this.resourceManagerHeartbeatManager =
1147:                 createResourceManagerHeartbeatManager(heartbeatServices);
1148:
1149:         // start the slot pool make sure the slot pool now accepts messages for this leader
1150:         slotPoolService.start(getFencingToken(), getAddress());
1151:
1152:         // job is ready to go, try to establish connection with resource manager
1153:         //   - activate leader retrieval for the resource manager
1154:         //   - on notification of the leader, the connection will be established and
1155:         //     the slot pool will start requesting slots
1156:         resourceManagerLeaderRetriever.start(new ResourceManagerLeaderListener());
1157:     } catch (Exception e) {
1158:         handleStartJobMasterServicesError(e);
1159:     }
1160: }
```

**关键设计**：
- **两个 HeartbeatManager**：分别监控 TaskManager 和 ResourceManager 死活
- **SlotPool 先 start**：保证有 leader 接收 slot offer
- **RM Leader Retriever**：通过 ZooKeeper/K8s 异步发现 RM leader

---

## 六、TaskManager 注册（JobMaster.java:773-849）

### 6.1 注册入口

```java
773: public CompletableFuture<RegistrationResponse> registerTaskManager(
774:         final JobID jobId,
775:         final TaskManagerRegistrationInformation taskManagerRegistrationInformation,
776:         final Time timeout) {
777:
778:     if (!jobGraph.getJobID().equals(jobId)) {
779:         log.debug(
780:                 "Rejecting TaskManager registration attempt because of wrong job id {}.",
781:                 jobId);
782:         return CompletableFuture.completedFuture(
783:                 new JMTMRegistrationRejection(...));
787:     }
```

**JobID 检查**：JobMaster 只接受属于自己 Job 的 TaskExecutor，避免 per-job 模式串扰。

### 6.2 重复注册处理（JobMaster.java:799-820）

```java
799:     final ResourceID taskManagerId = taskManagerLocation.getResourceID();
800:     final UUID sessionId = taskManagerRegistrationInformation.getTaskManagerSession();
801:     final TaskManagerRegistration taskManagerRegistration =
802:             registeredTaskManagers.get(taskManagerId);
803:
804:     if (taskManagerRegistration != null) {
805:         if (taskManagerRegistration.getSessionId().equals(sessionId)) {
806:             log.debug(
807:                     "Ignoring registration attempt of TaskManager {} with the same session id {}.",
808:                     taskManagerId,
809:                     sessionId);
810:             final RegistrationResponse response = new JMTMRegistrationSuccess(resourceId);
811:             return CompletableFuture.completedFuture(response);
812:         } else {
813:             disconnectTaskManager(
814:                     taskManagerId,
815:                     new FlinkException(
816:                             String.format(
817:                                     "A registered TaskManager %s re-registered with a new session id. This indicates a restart of the TaskManager. Closing the old connection.",
818:                                     taskManagerId)));
819:         }
820:     }
```

**Session ID 机制**：
- 同 SessionID → 幂等返回成功
- 不同 SessionID → TM 已重启，断开旧连接

### 6.3 异步建立连接（JobMaster.java:822-848）

```java
822:     CompletableFuture<RegistrationResponse> registrationResponseFuture =
823:             getRpcService()
824:                     .connect(
825:                             taskManagerRegistrationInformation.getTaskManagerRpcAddress(),
826:                             TaskExecutorGateway.class)
827:                     .handleAsync(
828:                             (TaskExecutorGateway taskExecutorGateway, Throwable throwable) -> {
   ...
833:                                 slotPoolService.registerTaskManager(taskManagerId);
834:                                 registeredTaskManagers.put(
835:                                         taskManagerId,
836:                                         TaskManagerRegistration.create(
837:                                                 taskManagerLocation,
838:                                                 taskExecutorGateway,
839:                                                 sessionId));
840:
841:                                 // monitor the task manager as heartbeat target
842:                                 taskManagerHeartbeatManager.monitorTarget(
843:                                         taskManagerId,
844:                                         new TaskExecutorHeartbeatSender(taskExecutorGateway));
845:
846:                                 return new JMTMRegistrationSuccess(resourceId);
847:                             },
848:                             getMainThreadExecutor());
```

**注册成功 3 件事**：
1. SlotPool 注册（接受后续 slot offer）
2. registeredTaskManagers 缓存连接
3. HeartbeatManager 开始监控

---

## 七、停止与清理（JobMaster.java:1190-1215）

```java
1190: private CompletableFuture<Void> stopJobExecution(final Exception cause) {
1191:     validateRunsInMainThread();
1192:
1193:     final CompletableFuture<Void> terminationFuture = stopScheduling();   // ⭐ 先停调度
1194:
1195:     return FutureUtils.runAfterwards(
1196:             terminationFuture,
1197:             () -> {
1198:                 shuffleMaster.unregisterJob(jobGraph.getJobID());          // 注销 shuffle
1199:                 disconnectTaskManagerResourceManagerConnections(cause);   // 断开 TM/RM
1200:                 stopJobMasterServices();                                   // 关闭服务
1201:             });
1202: }
```

**关键顺序**：先 stopScheduling（让所有 task 收到 cancel），再清理资源连接。

---

## 八、JobMaster 完整生命周期

```
JobMaster 创建 (DispatcherJobManagerRunnerFactory)
    ↓
fencingToken 分配 (确保单 active)
    ↓
onStart() [JobMaster.java:459]
    ↓
startJobExecution() [JobMaster.java:1126]
    ├─ shuffleMaster.registerJob()
    ├─ startJobMasterServices() [1143]
    │   ├─ TaskManagerHeartbeatManager 启动
    │   ├─ ResourceManagerHeartbeatManager 启动
    │   ├─ slotPoolService.start()
    │   └─ resourceManagerLeaderRetriever.start()
    │
    └─ startScheduling()  → schedulerNG.startScheduling()
        ├─ ExecutionGraph 构建
        ├─ Slot 申请（向 SlotPool）
        │   └─ SlotPool 不够 → 向 RM 申请新 TM
        └─ Task 分发到 TaskExecutor

[运行期]
    ├─ registerTaskManager() [773]    ← TM 注册
    ├─ updateTaskExecutionState()     ← Task 状态更新
    ├─ acknowledgeCheckpoint()        ← Checkpoint 协调
    └─ heartbeat 监控

stopJobExecution() [1190]
    ├─ stopScheduling() → 取消所有 task
    ├─ shuffleMaster.unregisterJob()
    ├─ disconnectTaskManagerResourceManagerConnections()
    └─ stopJobMasterServices()
```

---

## 九、SchedulerNG 调度抽象

`startScheduling()` 委托给 `schedulerNG`：
- **DefaultScheduler**（默认）：Eager / Lazy 调度策略
- **AdaptiveScheduler**：动态调整并行度（Reactive Mode）
- **AdaptiveBatchScheduler**：批模式动态分区

调度核心环节：
1. **ExecutionGraph 构建**：JobGraph → ExecutionGraph（带 ExecutionVertex）
2. **Slot 分配**：通过 SlotPool 申请 / 向 RM 申请新 TM
3. **DEPLOY**：将 task 字节码 + state 推送到 TaskExecutor
4. **状态机推进**：CREATED → SCHEDULED → DEPLOYING → RUNNING → FINISHED

---

## 十、生产关注点

### 10.1 单线程模型

```java
1127:     validateRunsInMainThread();
```

JobMaster 所有状态变更必须在 main thread，避免锁竞争。
- **优势**：无锁、易调试
- **限制**：长操作必须 async（如 RPC connect）

### 10.2 HA 切主延迟

- ZK leader retriever 默认超时 60s
- 切主期间 in-flight checkpoint 会失败
- 建议：增大 `high-availability.jobmanager.port` 范围避开冲突

### 10.3 SlotPool 申请节奏

- `slot.request.timeout` 默认 5min
- 大作业（千 slot）申请慢 → 调大或开启 `slotmanager.slot.request.timeout`

### 10.4 Checkpoint 协调

JobMaster 是 CheckpointCoordinator 的宿主：
- 触发 → 等所有 TM ack → 写元数据
- 任一 TM 超时（默认 10min）整个 cp 失败

---

## 十一、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `jobmanager.memory.process.size` | - | JobManager 总内存 |
| `jobmanager.execution.failover-strategy` | region | 失败转移策略 |
| `slot.request.timeout` | 5min | Slot 申请超时 |
| `heartbeat.timeout` | 50s | 心跳超时（TM/RM） |
| `high-availability` | NONE | HA 模式（zookeeper / kubernetes） |

---

## 十二、Eric 点评

JobMaster 是 Flink **最值得学习的组件**之一，原因：

1. **单线程异步模型** — 所有状态在 main thread 单线程修改，所有 IO 走 CompletableFuture，理论上零锁竞争
2. **Fencing Token** — 用最朴素的方式解决脑裂（每次切主递增 token）
3. **职责单一** — 只管一个 Job，per-job 模式天然隔离
4. **Pluggable Scheduler** — DefaultScheduler / AdaptiveScheduler 可换，支撑 Reactive Mode 革命

对比 Spark Driver：
- Spark Driver = SparkContext + DAGScheduler + TaskScheduler + BlockManagerMaster（一个进程多职责）
- Flink JobMaster = 只管单 Job 调度（更轻量）
- Flink ResourceManager 单独存在（管理整集群 slot）

理解 JobMaster 的"单线程 + 异步 + fencing"模型，是理解现代分布式系统设计的钥匙。Kafka KRaft、Pulsar Broker 都用了类似的模式。
