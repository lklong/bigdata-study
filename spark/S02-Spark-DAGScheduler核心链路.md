# Spark DAGScheduler 核心链路源码分析

> Eric 源码分析 | 基于 Spark txProjects (2026-05-09)
> 法则：逆向工程 + 对抗性阅读 + 分形剥离（L1/L2/L3）

---

## 一、整体定位：调度层的"大脑"

DAGScheduler 是 Spark 调度层的顶层组件，运行在 Driver 进程中。它的核心职责是：

```
用户 Action (e.g. count()) 
  → SparkContext.runJob() 
  → DAGScheduler.runJob() 
  → 创建 Stage DAG 
  → 切割 Stage 
  → 提交 TaskSet 
  → TaskSchedulerImpl → Executor 执行
```

**关键设计原则**（源码注释原文）：
- DAGScheduler 是**单线程执行**的，所有事件通过 `DAGSchedulerEventProcessLoop` 事件循环串行处理，避免并发问题
- Stage 是按照 **Shuffle 边界**切割的，NarrowDependency（map/filter）可以流水线合并成一个 Stage
- TaskSet 内的 Task 完全独立，可以基于已有数据并行调度

---

## 二、数据结构：调度器的"内存"

### 2.1 核心状态映射

| 数据结构 | 类型 | 作用 |
|---------|------|------|
| `jobIdToStageIds: HashMap[Int, HashSet[Int]]` | Job → Stage 集合 | 记录每个 Job 依赖哪些 Stage |
| `stageIdToStage: HashMap[Int, Stage]` | Stage ID → Stage 对象 | 全局 Stage 注册表 |
| `shuffleIdToMapStage: HashMap[Int, ShuffleMapStage]` | Shuffle ID → Stage | ShuffleMapStage 缓存，避免重复创建 |
| `jobIdToActiveJob: HashMap[Int, ActiveJob]` | Job ID → ActiveJob | 活跃 Job 追踪 |
| `waitingStages: HashSet[Stage]` | Stage 集合 | 等待父 Stage 完成的 Stage |
| `runningStages: HashSet[Stage]` | Stage 集合 | 正在运行的 Stage |
| `failedStages: HashSet[Stage]` | Stage 集合 | 因 FetchFailure 需要重试的 Stage |
| `cacheLocs: HashMap[Int, IndexedSeq[Seq[TaskLocation]]]` | RDD ID → 缓存位置 | RDD 分区缓存位置追踪 |

### 2.2 事件驱动架构

```scala
// 第 254 行：单线程事件循环
private[spark] val eventProcessLoop = new DAGSchedulerEventProcessLoop(this)

// 所有事件通过 eventProcessLoop.post() 异步投递：
// - JobSubmitted        → handleJobSubmitted()
// - TaskSetFailed      → handleTaskSetFailed()
// - ExecutorLost      → handleExecutorLost()
// - CompletionEvent    → handleTaskCompletion()
// - FetchFailure       → handleFetchFailure()
```

**关键设计**：所有事件通过单线程事件循环处理，保证 DAGScheduler 内部无需加锁（除了 `cacheLocs` 需要 `synchronized` 访问）。

---

## 三、主链路：submitJob → handleJobSubmitted → submitStage

### 3.1 入口：SparkContext.runJob

```scala
// SparkContext.scala:2224
def runJob[T, U](rdd, func, partitions, resultHandler): Unit = {
  val callSite = getCallSite
  val cleanedFunc = clean(func)        // 闭包清理，防止引用外部变量
  dagScheduler.runJob(rdd, cleanedFunc, partitions, callSite, resultHandler, ...)
}
```

### 3.2 DAGScheduler.runJob → submitJob（同步阻塞）

```scala
// DAGScheduler.scala:934
def runJob(rdd, func, partitions, ..., resultHandler, properties): Unit = {
  val start = System.nanoTime
  val waiter = submitJob(...)          // 异步提交，返回 JobWaiter
  ThreadUtils.awaitReady(waiter.completionFuture, Duration.Inf)  // 阻塞等待
  // 成功/失败处理
}
```

### 3.3 submitJob（异步投递事件）

```scala
// DAGScheduler.scala:876
def submitJob[T, U](...): JobWaiter[U] = {
  // 1. partition 合法性检查
  partitions.find(p => p >= maxPartitions || p < 0).foreach(...)
  
  // 2. 预先计算所有 RDD 的分区（SPARK-23626，避免在事件循环中阻塞）
  eagerlyComputePartitionsForRddAndAncestors(rdd)
  
  // 3. 分配 jobId，投递 JobSubmitted 事件
  val jobId = nextJobId.getAndIncrement()
  eventProcessLoop.post(JobSubmitted(jobId, rdd, func, partitions, ...))
  return new JobWaiter(this, jobId, partitions.size, resultHandler)
}
```

**重要设计**：RDD 分区在事件循环外预先计算，防止 `getPartitions()` 的潜在慢操作阻塞调度器（SPARK-23626）。

---

## 四、Stage 构建核心链路

### 4.1 handleJobSubmitted：创建 ResultStage + 递归构建父 Stage

```scala
// DAGScheduler.scala:1207
private[scheduler] def handleJobSubmitted(jobId, finalRDD, func, partitions, callSite, listener, properties): Unit = {
  // 1. 创建最终 Stage（ResultStage）
  //    在创建过程中会递归调用 getOrCreateParentStages() → 构建完整 Stage DAG
  finalStage = createResultStage(finalRDD, func, partitions, jobId, callSite)
  
  // 2. 创建 ActiveJob，注册到全局状态
  val job = new ActiveJob(jobId, finalStage, callSite, listener, properties)
  clearCacheLocs()                          // 清空缓存位置
  jobIdToActiveJob(jobId) = job
  finalStage.setActiveJob(job)
  
  // 3. 发布 SparkListenerJobStart 事件
  listenerBus.post(SparkListenerJobStart(...))
  
  // 4. 提交 Stage（递归拓扑排序）
  submitStage(finalStage)
}
```

### 4.2 createResultStage：按 Shuffle 边界切割 Stage

```scala
// DAGScheduler.scala:594
private def createResultStage(rdd, func, partitions, jobId, callSite): ResultStage = {
  val (shuffleDeps, resourceProfiles) = getShuffleDependenciesAndResourceProfiles(rdd)
  val resourceProfile = mergeResourceProfilesForStage(resourceProfiles)
  checkBarrierStageWithDynamicAllocation(rdd)     // Barrier Stage 不能动态分配资源
  checkBarrierStageWithNumSlots(rdd, resourceProfile)
  checkBarrierStageWithRDDChainPattern(rdd, partitions.toSet.size)
  val parents = getOrCreateParentStages(shuffleDeps, jobId)  // 递归创建父 Stage
  val id = nextStageId.getAndIncrement()
  new ResultStage(id, rdd, func, partitions, parents, jobId, callSite, ...)
}
```

### 4.3 getShuffleDependenciesAndResourceProfiles：遍历 RDD 依赖链

```scala
// DAGScheduler.scala:663（用于构建完整依赖链）
private[scheduler] def getShuffleDependenciesAndResourceProfiles(rdd): 
    (HashSet[ShuffleDependency], HashSet[ResourceProfile]) = {
  val parents = new HashSet[ShuffleDependency]()
  val visited = new HashSet[RDD]()
  val waitingForVisit = ListBuffer(rdd)
  while (waitingForVisit.nonEmpty) {
    val toVisit = waitingForVisit.remove(0)
    if (!visited(toVisit)) {
      visited += toVisit
      toVisit.dependencies.foreach {
        case shuffleDep: ShuffleDependency => parents += shuffleDep
        case dependency => waitingForVisit.prepend(dependency.rdd)  // 继续向上遍历
      }
    }
  }
  (parents, resourceProfiles)
}
```

**关键**：遍历 RDD 依赖链时，NarrowDependency 继续向上遍历，ShuffleDependency 则作为 Stage 切割点停下。

### 4.4 getOrCreateParentStages：递归创建父 ShuffleMapStage

```scala
// DAGScheduler.scala:618
private def getOrCreateParentStages(shuffleDeps, firstJobId): List[Stage] = {
  shuffleDeps.map { shuffleDep =>
    getOrCreateShuffleMapStage(shuffleDep, firstJobId)  // 缓存复用
  }.toList
}
```

### 4.5 getOrCreateShuffleMapStage：ShuffleMapStage 缓存复用

```scala
// DAGScheduler.scala:424
private def getOrCreateShuffleMapStage(shuffleDep, firstJobId): ShuffleMapStage = {
  shuffleIdToMapStage.get(shuffleDep.shuffleId) match {
    case Some(stage) => stage                          // 命中缓存，直接复用
    case None =>
      // 1. 先创建所有缺失的祖先 ShuffleMapStage
      getMissingAncestorShuffleDependencies(shuffleDep.rdd).foreach { dep =>
        if (!shuffleIdToMapStage.contains(dep.shuffleId))
          createShuffleMapStage(dep, firstJobId)
      }
      // 2. 创建当前 ShuffleMapStage
      createShuffleMapStage(shuffleDep, firstJobId)
  }
}
```

**设计亮点**：ShuffleMapStage 缓存复用机制——同一个 Shuffle 操作被多个 Job 复用时，只创建一次，避免重复计算。`shuffleIdToMapStage` 是缓存 key。

### 4.6 getMissingAncestorShuffleDependencies：祖先 Stage 发现

```scala
// DAGScheduler.scala:626
private def getMissingAncestorShuffleDependencies(rdd): ListBuffer[ShuffleDependency] = {
  val ancestors = new ListBuffer[ShuffleDependency]()
  val visited = new HashSet[RDD]()
  val waitingForVisit = ListBuffer(rdd)
  while (waitingForVisit.nonEmpty) {
    val toVisit = waitingForVisit.remove(0)
    if (!visited(toVisit)) {
      visited += toVisit
      val (shuffleDeps, _) = getShuffleDependenciesAndResourceProfiles(toVisit)
      shuffleDeps.foreach { shuffleDep =>
        if (!shuffleIdToMapStage.contains(shuffleDep.shuffleId)) {
          ancestors.prepend(shuffleDep)           // 前置插入，保持拓扑顺序
          waitingForVisit.prepend(shuffleDep.rdd) // 继续向上找
        }
      }
    }
  }
  ancestors
}
```

**关键**：使用手动栈（while 循环）而非递归，防止 StackOverflowError（注释明确提到）。

---

## 五、Stage 拓扑排序提交

### 5.1 submitStage：递归拓扑排序

```scala
// DAGScheduler.scala:1319
private def submitStage(stage: Stage): Unit = {
  val jobId = activeJobForStage(stage)
  if (jobId.isDefined) {
    if (!waitingStages(stage) && !runningStages(stage) && !failedStages(stage)) {
      val missing = getMissingParentStages(stage).sortBy(_.id)
      if (missing.isEmpty) {
        // 所有父 Stage 完成，提交当前 Stage 的 Tasks
        submitMissingTasks(stage, jobId.get)
      } else {
        // 父 Stage 未完成，递归提交父 Stage
        for (parent <- missing) {
          submitStage(parent)
        }
        waitingStages += stage  // 父 Stage 完成后会从 waitingStages 取出继续
      }
    }
  }
}
```

**核心算法**：拓扑排序（Kahn算法变体）。`getMissingParentStages` 返回未完成的父 Stage，`sortBy(_.id)` 保证 Stage ID 小的先提交（近似的拓扑顺序）。

### 5.2 getMissingParentStages：检查父 Stage 是否完成

```scala
// DAGScheduler.scala:712
private def getMissingParentStages(stage: Stage): List[Stage] = {
  val missing = new HashSet[Stage]
  val visited = new HashSet[RDD]()
  val waitingForVisit = ListBuffer(stage.rdd)
  while (waitingForVisit.nonEmpty) {
    val toVisit = waitingForVisit.remove(0)
    if (!visited(toVisit)) {
      visited += toVisit
      val rddHasUncachedPartitions = getCacheLocs(rdd).contains(Nil)
      if (rddHasUncachedPartitions) {  // 有分区未缓存
        for (dep <- rdd.dependencies) {
          dep match {
            case shufDep: ShuffleDependency =>
              val mapStage = getOrCreateShuffleMapStage(shufDep, stage.firstJobId)
              if (!mapStage.isAvailable || !mapStage.shuffleDep.shuffleMergeFinalized) {
                missing += mapStage           // 父 Stage 未完成
              } else {
                mapStage.increaseAttemptIdOnFirstSkip()  // 跳过时推进 attemptId
              }
            case narrowDep: NarrowDependency =>
              waitingForVisit.prepend(narrowDep.rdd)  // NarrowDependency 继续向下找
          }
        }
      }
    }
  }
  missing.toList
}
```

**对抗性思考**：Push-based Shuffle 场景下，即使 `mapStage.isAvailable`，如果 `shuffleMergeFinalized` 为 false（merge 未最终化），仍然标记为 missing，强制等待合并完成。

---

## 六、Task 提交：submitMissingTasks

### 6.1 构建 Task 二进制（序列化广播）

```scala
// DAGScheduler.scala:1488
taskBinaryBytes = stage match {
  case stage: ShuffleMapStage =>
    closureSerializer.serialize((stage.rdd, stage.shuffleDep): AnyRef)
  case stage: ResultStage =>
    closureSerializer.serialize((stage.rdd, stage.func): AnyRef)
}
taskBinary = sc.broadcast(taskBinaryBytes)  // 广播到所有 Executor
```

**关键**：RDD + ShuffleDep / RDD + Func 序列化后广播，每个 Executor 反序列化后独立持有副本，实现 Task 间隔离（Hadoop JobConf 不支持线程安全，注释原文）。

### 6.2 Task 构建

```scala
// DAGScheduler.scala:1530
val tasks: Seq[Task[_]] = stage match {
  case stage: ShuffleMapStage =>
    partitionsToCompute.map { id =>
      new ShuffleMapTask(stage.id, stage.latestInfo.attemptNumber,
        taskBinary, partitions(id), taskIdToLocations(id), ...)
    }
  case stage: ResultStage =>
    partitionsToCompute.map { id =>
      new ResultTask(stage.id, stage.latestInfo.attemptNumber,
        taskBinary, partitions(stage.partitions(id)), taskIdToLocations(id), ...)
    }
}
```

### 6.3 投递 TaskSet 到 TaskScheduler

```scala
// DAGScheduler.scala:1565
taskScheduler.submitTasks(new TaskSet(
  tasks.toArray, stage.id, stage.latestInfo.attemptNumber, jobId, properties, stage.resourceProfileId))
```

**TaskScheduler.submitTasks** 是调度层的边界——DAGScheduler 负责"切 Stage + 找位置 + 建 Task"，TaskSchedulerImpl 负责"调度策略（FIFO/FAIR）+ Task 重试 + 慢任务推测"。

---

## 七、容错机制：FetchFailure 处理

### 7.1 handleTaskCompletion → FetchFailure 检测

```scala
// 当 Task 完成事件是 FetchFailed 时：
// 1. 在 shuffleFileLostEpoch 中记录该 Executor/epoch
// 2. 标记 failedStages += 对应 Stage
// 3. 触发 resubmitLostStages() 重新执行失败的 Stage
```

### 7.2 事件循环中的 stage 重试逻辑

- `failedStages` 中的 Stage 被重新提交
- 同一 Stage 最多重试 `maxConsecutiveStageAttempts` 次（默认 4，可配置）
- 超过限制后 abortStage，整个 Job 失败

---

## 八、关键参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `spark.stage.maxConsecutiveAttempts` | 4 | Stage 最大重试次数 |
| `spark.barrier.maxConcurrentTasksCheck.maxFailures` | 2 | Barrier Stage 资源检查最大失败次数 |
| `spark.barrier.maxConcurrentTasksCheck.interval` | 30s | Barrier Stage 资源检查重试间隔 |
| `spark.stage.maxConsecutiveAttempts` | 4 | Stage 最大重试次数 |

---

## 九、核心调用链总结

```
SparkContext.runJob()
  └→ DAGScheduler.runJob()                      [同步阻塞，等待完成]
       └→ DAGScheduler.submitJob()              [投递 JobSubmitted 事件]
            └→ DAGSchedulerEventProcessLoop.JobSubmitted
                 └→ handleJobSubmitted()        [L2 核心：Stage 构建]
                      ├→ createResultStage()    [创建最终 Stage]
                      │    └→ getOrCreateParentStages()
                      │         └→ getOrCreateShuffleMapStage()
                      │              ├→ getMissingAncestorShuffleDependencies()
                      │              └→ createShuffleMapStage()  [递归]
                      └→ submitStage()          [拓扑排序提交]
                           └→ getMissingParentStages()  [检查父 Stage 是否完成]
                                ├→ [父 Stage 未完成] → submitStage(父)  [递归]
                                └→ [父 Stage 完成]   → submitMissingTasks()
                                     ├→ findMissingPartitions()
                                     ├→ getPreferredLocs()          [Task 最优位置]
                                     ├→ broadcast(taskBinary)        [序列化广播]
                                     ├→ 构建 ShuffleMapTask / ResultTask
                                     └→ taskScheduler.submitTasks()  [→ TaskSchedulerImpl]
```

---

## 十、源码阅读发现（L3 边界层）

### 10.1 Barrier Stage 限制（分形 L3）

源码中 `checkBarrierStageWithDynamicAllocation` 明确禁止 Barrier Stage + 动态资源分配同时使用，否则抛异常。Barrier Stage 要求同时调度所有分区（all-or-nothing），而动态分配可能只拿到部分 Executor。

### 10.2 StageAttemptId 的推进机制

`mapStage.increaseAttemptIdOnFirstSkip()` 是一个隐藏关键点：当父 Stage 跳过重试时，必须推进 `attemptId`，否则新 attempt 的 task 可能与旧 attempt 的 task 在 MapOutputTracker 中混淆。

### 10.3 SparkEnv.closureSerializer 单例使用

第 211 行注释说明：
> "This is only safe because DAGScheduler runs in a single thread."

DAGScheduler 单线程特性是其所有无锁设计的根基。closureSerializer 每次 `newInstance()` 复用，JVM 层面共享状态但无并发风险。

---

## 十一、TODO：TaskSetManager 链路

（待续：TaskSetManager 如何管理 Task 重试、推测执行、动态分配撤销）

---

*文档路径：Spark/S02-Spark-DAGScheduler核心链路.md*
*来源：txProjects/spark/core/src/main/scala/org/apache/spark/scheduler/DAGScheduler.scala*
