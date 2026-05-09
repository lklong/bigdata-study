# Spark Task 执行引擎

## 1. 核心定位

Spark Task 执行引擎是 Driver-Executor 架构的关键环节：从 DAGScheduler 提交 TaskSet → TaskScheduler 调度 → Executor 反序列化 → 线程池执行 → 结果回传。

**核心类**：
- `Task.scala` — Task 抽象基类
- `Executor.scala` — Executor 进程管理
- `CoarseGrainedExecutorBackend.scala` — 与 Driver 通信的 RPC 端点
- `TaskRunner.scala` — Executor 内部的任务执行包装器

---

## 2. Task 抽象体系

### 2.1 Task 类定义

```scala
58: private[spark] abstract class Task[T](
    val stageId: Int,              // 所属 Stage ID
    val stageAttemptId: Int,       // Stage 尝试次数
    val partitionId: Int,          // 分区索引
    @transient var localProperties: Properties,  // 用户设置的线程本地属性
    serializedTaskMetrics: Array[Byte],          // 序列化的 TaskMetrics
    val jobId: Option[Int],         // 所属 Job ID
    val appId: Option[String],      // Application ID
    val appAttemptId: Option[String], // App 尝试 ID
    val isBarrier: Boolean)        // 是否为 Barrier Stage
  extends Serializable
```

**两个实现子类**：
- `ShuffleMapTask` — 对中间输出做 shuffle map 端计算
- `ResultTask` — 执行最终结果计算

### 2.2 Task.run() 执行入口

```scala
82: final def run(
      taskAttemptId: Long,
      attemptNumber: Int,
      metricsSystem: MetricsSystem,
      cpus: Int,
      resources: Map[String, ResourceInformation],
      plugins: Option[PluginContainer]): T = {

95:   val taskContext = new TaskContextImpl(...)
108:   context = if (isBarrier) new BarrierTaskContext(taskContext) else taskContext

136:   try {
      runTask(context)  // ⭐ 子类实现
    } catch { ... }
```

**关键设计**：
- `run()` 是 final 方法，内部处理所有通用逻辑（上下文初始化、Metrics 采集、异常处理、资源清理）
- `runTask(context)` 是抽象方法，由子类实现具体计算逻辑

---

## 3. Executor 核心逻辑

### 3.1 Executor 初始化

```scala
62: private[spark] class Executor(
    executorId: String,
    executorHostname: String,
    env: SparkEnv,       // 由 Driver 传入
    userClassPath: Seq[URL],
    isLocal: Boolean,
    uncaughtExceptionHandler: UncaughtExceptionHandler,
    resources: immutable.Map[String, ResourceInformation])
  extends Logging
```

**线程池**：
```scala
107: private[executor] val threadPool = {
      val threadFactory = new ThreadFactoryBuilder()
        .setDaemon(true)
        .setNameFormat("Executor task launch worker-%d")
        .build()
      Executors.newCachedThreadPool(threadFactory).asInstanceOf[ThreadPoolExecutor]
113: }
```

- `newCachedThreadPool`：按需创建线程，空闲 60 秒回收
- 线程名格式：`Executor task launch worker-%d`

**资源注册**（非 Local 模式）：
```scala
137: env.blockManager.initialize(conf.getAppId)
138: env.metricsSystem.registerSource(executorSource)
140: executorMetricsSource.foreach(_.register(env.metricsSystem))
141: env.metricsSystem.registerSource(env.blockManager.shuffleMetricsSource)
```

### 3.2 launchTask — 任务分发

```scala
296: def launchTask(context: ExecutorBackend, taskDescription: TaskDescription): Unit = {
297:   val taskId = taskDescription.taskId
298:   val tr = createTaskRunner(context, taskDescription)  // 创建 TaskRunner
299:   runningTasks.put(taskId, tr)                         // 注册到运行表
300:   val killMark = killMarks.get(taskId)                // 检查预杀标记
301:   if (killMark != null) { tr.kill(killMark._1, killMark._2); killMarks.remove(taskId) }
305:   threadPool.execute(tr)                               // 提交到线程池
306:   if (decommissioned) { log.error("Launching a task while in decommissioned state.") }
307: }
```

**核心流程**：
1. 用 `TaskDescription` 创建 `TaskRunner`
2. 加入 `runningTasks` Map（用于 kill tracking）
3. 检查预杀标记（处理 killTask 先于 launchTask 的竞态）
4. 提交到线程池

---

## 4. TaskRunner 执行流程

`TaskRunner` 是 `Runnable`，在 Executor 线程池中执行。

### 4.1 线程初始化

```scala
481: override def run(): Unit = {
482:   setMDCForTask(taskName, mdcProperties)  // MDC 日志上下文
483:   threadId = Thread.currentThread.getId
484:   Thread.currentThread.setName(threadName)
485:   val threadMXBean = ManagementFactory.getThreadMXBean()
486:   val taskMemoryManager = new TaskMemoryManager(env.memoryManager, taskId)
```

**每个 Task 分配独立的 `TaskMemoryManager`**，实现内存隔离。

### 4.2 Task 反序列化

```scala
505: updateDependencies(...)    // 更新依赖（JAR/文件）
507: task = ser.deserialize[Task[Any]](
      taskDescription.serializedTask, 
      Thread.currentThread.getContextClassLoader)  // 用 REPL 类加载器
510: task.setTaskMemoryManager(taskMemoryManager)
514: val killReason = reasonIfKilled  // 检查反序列化前是否被 kill
```

**关键点**：使用 `replClassLoader`（优先用户类），而非 Spark 系统类加载器。

### 4.3 Task 运行

```scala
494: execBackend.statusUpdate(taskId, TaskState.RUNNING, EMPTY_BYTE_BUFFER)  // 上报 RUNNING 状态

... 中间是各种状态统计 ...

515: // 执行！⭐
516: val value = task.run(taskContext)
```

### 4.4 结果处理

```scala
// 结果序列化
val serializedResult = Serializer.getKryo.newInstance().serialize(value)

// 大结果走 BlockManager（超过 maxDirectResultSize）
val directResult = if (serializedResult.size > maxDirectResultSize) {
  val blockId = TaskResultBlockId(taskId)
  env.blockManager.cacheBytes(blockId, serializedResult, StorageLevel.MEMORY_AND_DISK_SER)
  IndirectTaskResult(blockId)
} else {
  DirectTaskResult(serializedResult)
}

// 上报 SUCCESS
execBackend.statusUpdate(taskId, TaskState.FINISHED, serializedResult)
```

### 4.5 异常处理

```scala
catch {
  case e: FetchFailedException =>  // Shuffle fetch 失败
    setTaskFinishedAndClearInterruptStatus()
    execBackend.statusUpdate(taskId, TaskState.FAILED, serializedTaskFailure)
  case _: CommitDeniedException => ...
  case ce: ControlAwareThrowable => ...
  case t: Throwable => ... // 记录 GC/JVM 信息后上报 FAILED
}
```

### 4.6 资源清理（finally）

```scala
finally {
  // 释放 unroll 内存
  SparkEnv.get.blockManager.memoryStore.releaseUnrollMemoryForThisTask(MemoryMode.ON_HEAP)
  SparkEnv.get.blockManager.memoryStore.releaseUnrollMemoryForThisTask(MemoryMode.OFF_HEAP)
  // 通知等待内存的任务
  val memoryManager = SparkEnv.get.memoryManager
  memoryManager.synchronized { memoryManager.notifyAll() }
  // 清除 ThreadLocal
  TaskContext.unset()
  InputFileBlockHolder.unset()
}
```

---

## 5. CoarseGrainedExecutorBackend

### 5.1 核心角色

`CoarseGrainedExecutorBackend` 是 Executor 进程的 RPC 端点，负责：
- 与 Driver 通信（注册、心跳、接收任务）
- 管理 Executor 生命周期

### 5.2 onStart → 注册 Driver

```scala
80: override def onStart(): Unit = {
81:   if (isLocal) { ... }
82:   driverRef.foreach(_.send(RegisterExecutor(executorId, self, hostname, cores,
83:       resources, resourceProfile)))  // 向 Driver 发送注册消息
84: }
```

### 5.3 receive 处理消息

```scala
169: override def receive: PartialFunction[Any, Unit] = {
170:   case RegisteredExecutor =>
171:     // Driver 接受注册，创建 Executor 实例 ⭐
172:     executor = new Executor(executorId, executorHostname, env, ...)
176:     logInfo("Successfully registered with driver")
178:   case LaunchTask(data) =>
181:     // Driver 发送任务，开始执行 ⭐
182:     if (executor == null) exitExecutor(1, ...)
183:     executor.launchTask(this, deserializeTaskDescription(data))
184:   case KillTask(taskId, interruptThread, reason) =>
185:     executor.killTask(taskId, interruptThread, reason)
186: }
```

### 5.4 statusUpdate 上报状态

```scala
263: override def statusUpdate(taskId: Long, state: TaskState, data: ByteBuffer): Unit = {
265:   driver match {
266:     case Some(driverRef) => driverRef.send(TaskStatusUpdate(taskAttemptId, taskId, state, data, summary))
267:     case None => logWarning(s"Dropping TaskStatusUpdate because no active driver")
268:   }
269: }
```

---

## 6. Task 状态机

```
TaskState 枚举：
  LAUNCHING  → 已发送到 Executor
  RUNNING   → Executor 开始执行
  FINISHED  → 成功完成
  FAILED    → 执行失败
  KILLED    → 被 kill
  LOST      → Executor 丢失（Task 被标记为 lost）
```

**状态转换图**：

```
LAUNCHING ──→ RUNNING ──→ FINISHED
    │            │
    │            ├─→ FAILED
    │            ├─→ KILLED
    │            └─→ LOST (executor lost)
    │
    └─────────────→ KILLED (launch 前就被 kill)
```

---

## 7. Task Kill 机制

### 7.1 三层保护

```
Driver killTask()
    ↓
CoarseGrainedSchedulerBackend.killTask()
    ↓
ExecutorBackend.killTask()
    ↓
TaskRunner.kill(interruptThread, reason)  /  killMarks.put()（预杀标记）
    ↓
task.kill(interruptThread, reason)
    ↓
Thread.interrupt() + CancellationException
```

### 7.2 TaskReaper

```scala
// 如果启用了 taskReaper（spark.taskReaper.enabled = true）
// killTask 不直接 interrupt，而是启动一个 TaskReaper 线程
val taskReaper = new TaskReaper(taskRunner, interruptThread, reason)
taskReaperPool.execute(taskReaper)
```

TaskReaper 等待 TaskRunner 完成或超时，超时后强制 kill 进程。

---

## 8. Executor 心跳机制

```scala
// Executor.HeartbeatSender (内部线程)
class HeartbeatSender(...) extends Runnable {
  def run() {
    val executorMetrics = executorSource.getMetrics()
    val blockManagerMetrics = env.blockManager.metrics
    driverEndpointRef.send(Heartbeat(executorId, executorMetrics, blockManagerMetrics, 
                                      executorResources, clock.getTimeMillis()))
  }
}
```

**心跳间隔**：`spark.executor.heartbeat.interval`（默认 30s）

**Driver 收到心跳后**：
1. 更新 Executor 存活状态
2. 触发 BlockManager GC 检查
3. 更新 Executor Resource Profile

---

## 9. 结果回传链路

```
Task.runTask(context)
    ↓ (返回结果)
TaskRunner.run()
    ↓ (序列化)
结果 > maxDirectResultSize?
    ├─ 是 → 写入 BlockManager → 返回 IndirectTaskResult(BlockId)
    └─ 否 → 直接序列化 → DirectTaskResult(bytes)
    ↓
execBackend.statusUpdate(taskId, FINISHED, serializedResult)
    ↓
CoarseGrainedExecutorBackend.statusUpdate()
    ↓
driverEndpointRef.send(TaskStatusUpdate(...))
    ↓
TaskSetManager.statusUpdate()
    ↓
TaskResultGetter 反序列化结果
    ↓
handleSuccessfulTask()
    ↓
DAGScheduler.eventProcessActor ! CompletionEvent
```

---

## 10. 关键配置参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `spark.task.cpus` | 1 | 每个 Task 分配的 CPU |
| `spark.executor.cores` | 1 | Executor 总核数 |
| `spark.task.maxResultSize` | 1GB | Task 结果最大 size |
| `spark.task.reaper.enabled` | false | 是否启用 TaskReaper |
| `spark.executor.heartbeat.interval` | 30s | 心跳间隔 |

---

> **Eric 点评**：Task 执行引擎的核心设计亮点在于"反序列化时机"——Task 在线程池中才反序列化，保证每个 Task 有独立的类加载器上下文；以及"结果分段回传"——大结果走 BlockManager 而非直接 RPC，避免 Driver OOM。这两个细节体现了 Spark 对生产环境的深度考量。
