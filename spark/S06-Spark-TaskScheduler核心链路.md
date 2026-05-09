# Spark TaskScheduler 核心链路源码分析

> **模块**: Spark Core — 任务调度层  
> **源码路径**: `core/src/main/scala/org/apache/spark/scheduler/TaskSchedulerImpl.scala`  
> **分析日期**: 2026-05-10  
> **Spark 版本**: 4.x (master)

---

## 1. 定位与上下文

TaskSchedulerImpl 是 Spark 任务调度体系的**第二层**（第一层是 DAGScheduler，第三层是 SchedulerBackend）：

```
SparkContext
  └─ DAGScheduler        (Stage 切分 + 拓扑排序)
       └─ TaskSchedulerImpl  (TaskSet 管理 + 本地性调度)    ← 本文
            └─ SchedulerBackend  (YARN/Kubernetes/Standalone 等)
                 └─ Executor
```

DAGScheduler 将 Job 划分为多个 Stage 后，调用 `submitTasks(TaskSet)` 将每个 Stage 的 TaskSet 交给 TaskSchedulerImpl。TaskSchedulerImpl 负责：
1. **TaskSet 生命周期管理**（Zombie 机制）
2. **多级本地性调度**（PROCESS_LOCAL → NODE_LOCAL → RACK_LOCAL → ANY）
3. **资源分配**（WorkerOffer → TaskDescription）
4. **Task 状态追踪**与结果回传
5. **推测执行**与**延迟调度**

---

## 2. 核心数据结构

```scala
// 按 stageId → stageAttemptId 管理 TaskSetManager（非线程安全，需外部同步）
private val taskSetsByStageIdAndAttempt = new HashMap[Int, HashMap[Int, TaskSetManager]]

// taskId → TaskSetManager 快速查找
private[scheduler] val taskIdToTaskSetManager = new ConcurrentHashMap[Long, TaskSetManager]

// executorId → running taskIds
private val executorIdToRunningTaskIds = new HashMap[String, HashSet[Long]]

// host → executorIds
private val hostToExecutors = new HashMap[String, HashSet[String]]

// 调度池（FIFO 或 FAIR）
val rootPool: Pool = new Pool("", schedulingMode, 0, 0)

// 不可调度的 TaskSet → 超时时间（用于延迟调度）
private val unschedulableTaskSetToExpiryTime = new HashMap[TaskSetManager, Long]
```

**关键设计**：TaskSetManager 非线程安全，所有访问必须在 `this.synchronized` 块内进行（由 DAGScheduler 事件循环保证串行）。

---

## 3. submitTasks — TaskSet 接入

```scala
override def submitTasks(taskSet: TaskSet): Unit = {
  val tasks = taskSet.tasks
  this.synchronized {
    val manager = createTaskSetManager(taskSet, maxTaskFailures)
    val stageTaskSets =
      taskSetsByStageIdAndAttempt.getOrElseUpdate(stage, new HashMap[Int, TaskSetManager])

    // 🔑 Zombie 机制：同一 stage 的旧 TaskSetManager 全部标记为僵尸
    // 防止 corner case：旧 TSM 还在跑某 partition，新 TSM 认为 stage 未完成，
    // DAGScheduler 重复提交创建 TSM3，此时同一 stage 不能有两个 active TSM
    stageTaskSets.foreach { case (_, ts) => ts.isZombie = true }
    stageTaskSets(taskSet.stageAttemptId) = manager

    // 加入调度池（FIFO/FAIR）
    schedulableBuilder.addTaskSetManager(manager, manager.taskSet.properties)

    // 启动饥饿检测定时器（Job 等待超过 STARVATION_TIMEOUT_MS = 60s 时告警）
    if (!isLocal && !hasReceivedTask) {
      starvationTimer.scheduleAtFixedRate(...)
      hasReceivedTask = true
    }
  }
  // 通知 Backend 重新分发资源
  backend.reviveOffers()
}
```

**关键设计**：
- **Zombie 机制**：防止 DAGScheduler 重复提交同一个 Stage 时产生多个 active TaskSetManager
- **Starvation Timer**：60s 无资源则告警（用户可以感知集群资源紧张）
- **`backend.reviveOffers()`**：触发 SchedulerBackend 重新向 Driver 的 Executor 发送资源邀请

---

## 4. resourceOffers — 资源分发核心

### 4.1 入口：`resourceOffers(offers: IndexedSeq[WorkerOffer])`

```scala
def resourceOffers(
    offers: IndexedSeq[WorkerOffer],
    isAllFreeResources: Boolean = true): Seq[Seq[TaskDescription]] = synchronized {
  // 1. 注册/更新 WorkerOffer：host → executorId 映射
  for (o <- offers) {
    if (!hostToExecutors.contains(o.host)) hostToExecutors(o.host) = new HashSet[String]()
    if (!executorIdToRunningTaskIds.contains(o.executorId)) {
      executorIdToRunningTaskIds(o.executorId) = HashSet[Long]()
      executorAdded(o.executorId, o.host)  // 通知 DAGScheduler
      executorIdToHost(o.executorId) = o.host
    }
  }

  // 2. 按 Rack 聚合 hosts
  for ((host, Some(rack)) <- hosts.zip(getRacksForHosts(hosts))) {
    hostsByRack.getOrElseUpdate(rack, new HashSet[String]()) += host
  }

  // 3. 健康检查过滤：排除节点/Executor 级别故障节点
  val filteredOffers = healthTrackerOpt.map { healthTracker =>
    offers.filter { offer =>
      !healthTracker.isNodeExcluded(offer.host) &&
        !healthTracker.isExecutorExcluded(offer.executorId)
    }
  }.getOrElse(offers)

  // 4. 打散 offer 顺序，避免每次都从同一 Executor 开始调度
  val shuffledOffers = shuffleOffers(filteredOffers)  // Random.shuffle

  // 5. 按调度池顺序获取 TaskSet 队列
  val sortedTaskSets = rootPool.getSortedTaskSetQueue
}
```

### 4.2 TaskSet × Locality Level 双重循环

```scala
for (taskSet <- sortedTaskSets) {
  val numBarrierSlotsAvailable = if (taskSet.isBarrier) {
    calculateAvailableSlots(...)  //  barrier 模式需要全部 slot 同时可用
  } else { -1 }

  // 跳过资源不足的 barrier TaskSet
  if (taskSet.isBarrier && numBarrierSlotsAvailable < taskSet.numTasks) { ... }
  else {
    for (currentMaxLocality <- taskSet.myLocalityLevels) {   // ⬅ 本地性级别循环
      var launchedTaskAtCurrentMaxLocality = false
      do {
        val (noDelayScheduleReject, minLocality) = resourceOfferSingleTaskSet(
          taskSet, currentMaxLocality, shuffledOffers, availableCpus,
          availableResources, tasks)
        launchedTaskAtCurrentMaxLocality = minLocality.isDefined
      } while (launchedTaskAtCurrentMaxLocality)   // ⬅ 同一 locality 级别尽力塞满
    }
  }
}
```

**双重循环设计**：
- 外层：`TaskSet` 按调度顺序（FIFO/FAIR 权重）遍历
- 内层：`Locality Level` 从最严格（PROCESS_LOCAL）到最宽松（ANY）逐级退让

**`myLocalityLevels` 顺序**：
```
PROCESS_LOCAL → NODE_LOCAL → NO_PREF → RACK_LOCAL → ANY
  (同一 JVM)    (同节点)      (无偏好)   (同机架)     (任意)
```

### 4.3 resourceOfferSingleTaskSet — 单次 TaskSet 调度

```scala
private def resourceOfferSingleTaskSet(
    taskSet: TaskSetManager,
    maxLocality: TaskLocality,
    shuffledOffers: Seq[WorkerOffer],
    availableCpus: Array[Int],
    availableResources: Array[Map[String, Buffer[String]]],
    tasks: IndexedSeq[ArrayBuffer[TaskDescription]])
  : (Boolean, Option[TaskLocality]) = {

  for (i <- 0 until shuffledOffers.size) {
    val execId = shuffledOffers(i).executorId
    val host = shuffledOffers(i).host

    // 硬性要求：ResourceProfile 必须匹配
    if (taskSetRpID == shuffledOffers(i).resourceProfileId) {
      taskResAssignmentsOpt.foreach { taskResAssignments =>
        val (taskDescOption, didReject, index) =
          taskSet.resourceOffer(execId, host, maxLocality, taskCpus, taskResAssignments)

        for (task <- taskDescOption) {
          tasks(i) += task              // ⬅ 分配 TaskDescription
          addRunningTask(task.taskId, execId, taskSet)  // 注册 running task
          availableCpus(i) -= taskCpus // ⬅ 扣减 CPU
        }
      }
    }
  }
  (noDelayScheduleRejects, minLaunchedLocality)
}
```

**TaskSetManager.resourceOffer() 内部逻辑**：
- 检查是否有 pending task（未分配的 partition）
- 检查该 executor 是否满足任务的 preferredLocations
- 如果满足 locality 要求：返回 TaskDescription
- 如果不满足：`didReject = true`，延迟调度计数器 +1，等待下一次 offer

---

## 5. statusUpdate — Task 状态回传

```scala
def statusUpdate(tid: Long, state: TaskState, serializedData: ByteBuffer): Unit = {
  synchronized {
    try {
      Option(taskIdToTaskSetManager.get(tid)) match {
        case Some(taskSet) =>
          if (TaskState.isFinished(state)) {
            cleanupTaskState(tid)
            taskSet.removeRunningTask(tid)
            if (state == TaskState.FINISHED)
              taskResultGetter.enqueueSuccessfulTask(taskSet, tid, serializedData)
            else
              taskResultGetter.enqueueFailedTask(taskSet, tid, state, serializedData)
          }
        case None =>
          // 幂等：重复的 statusUpdate（网络重传）直接忽略
          logError("Ignoring update with state ...")
      }
    } catch { case e: Exception => logError("Exception in statusUpdate", e) }
  }
  // 通知 DAGScheduler（无锁，避免死锁）
  dagScheduler.taskEnded(...)
}
```

**关键点**：
- **`taskIdToTaskSetManager`** 支持 O(1) 查找当前 Task 属于哪个 TaskSet
- 重复的 statusUpdate（网络重传）会被忽略（TaskSet 已变为 zombie）
- **`taskResultGetter`** 是一个专门的线程池（`spark.resultGetter.threads`）异步拉取和反序列化结果，避免阻塞事件循环

---

## 6. 延迟调度（Delay Scheduling）机制

```scala
// 每次 TaskSet 获得新资源时重置延迟计时器
taskSet.resetDelayScheduleTimer(globalMinLocality)

// 每次因 locality 退让拒绝资源时记录
noDelaySchedulingRejects &= !didReject
```

**原理**：作业公平性（Fair）与数据本地性（Locality）之间的权衡：

```
假设 TaskSet 需要 PROCESS_LOCAL，但当前只有 NODE_LOCAL 可用：
  → 接受 NODE_LOCAL（wait）
  → 延迟计时器开始计时
  → 超过配置的等待时间后 → 退让到 RACK_LOCAL
  → 再超过等待时间 → 最终接受 ANY（任意节点）
```

**配置参数**：
| 参数 | 默认值 | 含义 |
|------|--------|------|
| `spark.locality.wait` | 3s | 默认等待时间 |
| `spark.locality.wait.process` | 3s | PROCESS_LOCAL 等待 |
| `spark.locality.wait.node` | 3s | NODE_LOCAL 等待 |
| `spark.locality.wait.rack` | 3s | RACK_LOCAL 等待 |

---

## 7. 调度模式：FIFO vs FAIR

```scala
// 初始化时根据 spark.taskScheduler.pool 选择
schedulingMode match {
  case SPARK_SCHEDULER_MODE_FAIR =>
    new FairSchedulableBuilder(rootPool, sc)
  case _ =>
    new FIFOSchedulableBuilder(rootPool)
}
```

- **FIFO**：`rootPool.getSortedTaskSetQueue` 按 stage 优先级顺序
- **FAIR**：按权重轮询，保证多 Job 并发时的公平性

---

## 8. 完整调用链

```
SparkContext.runJob()
  └─ DAGScheduler.runJob()
       └─ DAGScheduler.submitJob()
            └─ DAGScheduler.handleJobSubmitted()
                 └─ DAGScheduler.submitStage(finalStage)
                      └─ DAGScheduler.submitMissingTasks(stage)
                           └─ TaskSchedulerImpl.submitTasks(taskSet)
                                └─ SchedulerBackend.reviveOffers()
                                     └─ [Executor 注册后] CoarseGrainedSchedulerBackend.resourceOffers()
                                          └─ TaskSchedulerImpl.resourceOffers(offers)
                                               └─ for (taskSet <- sortedTaskSets)
                                                    └─ for (maxLocality <- myLocalityLevels)
                                                         └─ resourceOfferSingleTaskSet()
                                                              └─ TaskSetManager.resourceOffer()
                                                                   └─ TaskDescription (序列化 → Executor)
                                                
Executor 端 Task 执行完成后：
  └─ ExecutorBackend.statusUpdate()
       └─ TaskSchedulerImpl.statusUpdate()
            └─ taskResultGetter.enqueueSuccessfulTask()
                 └─ DAGScheduler.taskEnded()
                      └─ handleTaskCompletion() → submitNextStage 或 Job 完成
```

---

## 9. 踩坑 & 运维要点

| 场景 | 现象 | 根因 | 解决 |
|------|------|------|------|
| Task 一直处于 PENDING | `spark.locality.wait` 过长 | 本地性不满足但一直等待 | 降低 locality wait 参数 |
| 大量 RACK_LOCAL / ANY | 数据倾斜或 rack 感知配置缺失 | 网络跨机架带宽瓶颈 | 检查 `spark.speculation` + 网络拓扑 |
| Barrier Stage 永不启动 | 资源不足 | `numSlots < numTasks` | 减少并发 Barrier Stage，或扩容 |
| `isZombie = true` | Task 重试但 Stage 已完成 | DAGScheduler 误判 Stage 完成 | 检查 `spark.stage.maxConsecutiveAttempts` |
| Task 饥饿 | `Initial job has not accepted any resources` | 集群资源不足 | 增加 Executor 数量/核数 |
