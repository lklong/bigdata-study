# SparkContext 入口初始化链路

## 1. 核心定位

`SparkContext` 是 Spark 应用程序的主入口，用户通过它创建 RDD、accumulator 和 broadcast variables。它建立了与集群的连接，是 Driver 进程的核心组件。

**关键约束**：同一 JVM 只能有一个活跃的 `SparkContext`，必须先 `stop()` 再创建新的。

---

## 2. 构造函数链路

SparkContext 有多个重载构造函数，最终都汇聚到主构造函数：

```scala
84: class SparkContext(config: SparkConf) extends Logging {
```

**构造函数入口链**：
```
new SparkContext(conf)
  → this(SparkContext.updatedConf(conf, master, appName))
    → this(updatedConf, master, appName, sparkHome, jars, environment)
      → 最终走到主构造函数
```

**双重检查机制**（防止多实例）：
```scala
97: SparkContext.markPartiallyConstructed(this)  // 构造函数第一行放置
105: val activeContext = SparkContext.activeContext.get()
```

---

## 3. 初始化核心流程（L1）

按执行顺序分解：

### 3.1 前置配置解析（第 430~527 行）

```scala
_conf.set(EXECUTOR_ID, SparkContext.DRIVER_IDENTIFIER)  // Driver 标识
_jars = Utils.getUserJars(_conf)
_files = _conf.getOption(FILES.key).toSeq.flatten
_archives = _conf.getOption(ARCHIVES.key).toSeq.flatten
```

### 3.2 事件日志配置（第 437~452 行）

```scala
_eventLogDir = if (isEventLogEnabled) Some(Utils.resolveURI(...)) else None
_eventLogCodec = if (compress && isEventLogEnabled) Some(...) else None
```

### 3.3 ListenerBus & AppStatusStore（第 454~461 行）

```scala
_listenerBus = new LiveListenerBus(_conf)
_resourceProfileManager = new ResourceProfileManager(_conf, _listenerBus)
_statusStore = AppStatusStore.createLiveStore(conf, appStatusSource)
listenerBus.addToStatusQueue(_statusStore.listener.get)
```

> **设计意图**：ListenerBus 在 SparkEnv 创建之前就初始化，确保所有组件生命周期事件都能被捕获。

### 3.4 SparkEnv.createDriverEnv（第 463~465 行）⭐ 核心

```scala
_env = createSparkEnv(_conf, isLocal, listenerBus)  // 第 275 行
SparkEnv.set(_env)  // 设置全局单例
```

```scala
// createSparkEnv 内部（第 275~280 行）
private[spark] def createSparkEnv(...) = {
  SparkEnv.createDriverEnv(conf, isLocal, listenerBus, 
                           SparkContext.numDriverCores(master, conf))
}
```

### 3.5 Hadoop Configuration（第 494~503 行）

```scala
_hadoopConfiguration = SparkHadoopUtil.get.newConfiguration(_conf)
_hadoopConfiguration.size()  // 性能优化：触发 eager evaluation
```

### 3.6 HeartbeatReceiver（第 564~567 行）

```scala
_heartbeatReceiver = env.rpcEnv.setupEndpoint(
  HeartbeatReceiver.ENDPOINT_NAME, new HeartbeatReceiver(this))
```

> **SPARK-6640 修复**：必须在 `createTaskScheduler` 之前注册，因为 Executor 构造函数会获取 HeartbeatReceiver。

### 3.7 PluginContainer（第 569~570 行）

```scala
_plugins = PluginContainer(this, _resources.asJava)
```

### 3.8 TaskScheduler 创建（第 572~576 行）⭐ 核心

```scala
val (sched, ts) = SparkContext.createTaskScheduler(this, master)
_schedulerBackend = sched
_taskScheduler = ts
_dagScheduler = new DAGScheduler(this)
```

关键等待：
```scala
_heartbeatReceiver.ask[Boolean](TaskSchedulerIsSet)
```

### 3.9 Heartbeater 启动（第 586~591 行）

```scala
_heartbeater = new Heartbeater(
  () => SparkContext.this.reportHeartBeat(_executorMetricsSource),
  "driver-heartbeater",
  conf.get(EXECUTOR_HEARTBEAT_INTERVAL))
_heartbeater.start()
```

### 3.10 TaskScheduler.start()（第 595 行）

```scala
_taskScheduler.start()
```

### 3.11 获取 applicationId（第 597~603 行）

```scala
_applicationId = _taskScheduler.applicationId()
_applicationAttemptId = _taskScheduler.applicationAttemptId()
_conf.set("spark.app.id", _applicationId)
```

### 3.12 BlockManager 初始化（第 610 行）

```scala
_env.blockManager.initialize(_applicationId)
```

### 3.13 MetricsSystem 启动（第 615 行）

```scala
_env.metricsSystem.start(_conf.get(METRICS_STATIC_SOURCES_ENABLED))
```

---

## 4. createTaskScheduler 方法

```scala
val (sched, ts) = SparkContext.createTaskScheduler(this, master)
```

根据 master URL 的不同，创建不同的 SchedulerBackend + TaskScheduler 组合：

| Master | SchedulerBackend | TaskScheduler |
|--------|----------------|---------------|
| local[N] | LocalSchedulerBackend | TaskSchedulerImpl |
| spark:// | StandaloneSchedulerBackend | TaskSchedulerImpl |
| yarn (cluster/client) | YarnClientSchedulerBackend / YarnClusterSchedulerBackend | TaskSchedulerImpl |
| k8s | KubernetesSchedulerBackend | TaskSchedulerImpl |
| mesos | MesosSchedulerBackend | TaskSchedulerImpl |

---

## 5. 全局单例管理

```scala
84: class SparkContext(config: SparkConf) extends Logging {
86:   // 记录调用点
91:   SparkContext.assertOnDriver()  // 必须在 Driver 端创建
96:   SparkContext.markPartiallyConstructed(this)  // 标记为"部分构造"
```

单例检查机制：
```scala
val activeContext = SparkContext.activeContext.get()
if (activeContext != null && !activeContext.isStopped.get()) {
  throw new SparkException(...)  // 防止多实例
}
```

---

## 6. 核心成员变量一览

| 变量 | 类型 | 初始化时机 |
|------|------|-----------|
| `_conf` | SparkConf | 构造函数参数 |
| `_env` | SparkEnv | 第 464 行 |
| `_listenerBus` | LiveListenerBus | 第 454 行 |
| `_statusStore` | AppStatusStore | 第 460 行 |
| `_heartbeatReceiver` | RpcEndpointRef | 第 566 行 |
| `_schedulerBackend` | SchedulerBackend | 第 574 行 |
| `_taskScheduler` | TaskScheduler | 第 575 行 |
| `_dagScheduler` | DAGScheduler | 第 576 行 |
| `_applicationId` | String | 第 597 行 |
| `_ui` | SparkUI | 第 482 行 |

---

## 7. 调用关系图

```
用户代码 new SparkContext(conf)
         ↓
    markPartiallyConstructed()
         ↓
    createSparkEnv()
         ↓
    SparkEnv.createDriverEnv()
         ├─ RpcEnv.create()           → NettyRpcEnv
         ├─ SerializerManager
         ├─ MapOutputTracker
         ├─ ShuffleManager
         ├─ MemoryManager (UnifiedMemoryManager)
         ├─ BlockManager
         ├─ BroadcastManager
         └─ MetricsSystem
         ↓
    setupEndpoint(HeartbeatReceiver)
         ↓
    createTaskScheduler() → (SchedulerBackend, TaskScheduler)
         ↓
    new DAGScheduler()
         ↓
    TaskScheduler.start()
         ↓
    BlockManager.initialize()
         ↓
    MetricsSystem.start()
         ↓
    SparkContext 就绪 ✓
```

---

## 8. 设计意图分析

### 为什么 SparkEnv 在其他组件之前创建？

SparkEnv 包含所有核心运行时对象（RpcEnv、BlockManager、MemoryManager 等），其他组件（HeartbeatReceiver、DAGScheduler 等）都依赖它。

### 为什么用"部分构造"机制？

Scala 构造函数体可能抛出异常，如果不标记为"部分构造"，activeContext 会残留一个半成品引用，导致后续检查失效。

### 为什么先注册 HeartbeatReceiver 再创建 TaskScheduler？

SPARK-6640：Executor 端代码可能在 TaskScheduler 创建前就需要向 HeartbeatReceiver 发送心跳。

---

## 9. 关键参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `spark.app.id` | 运行时分配 | Application 唯一标识 |
| `spark.executor.memory` | 1024m | Executor 堆内存 |
| `spark.driver.cores` | 1 | Driver CPU 核数 |
| `spark.task.cpus` | 1 | 每个 Task 分配的 CPU |
| `EXECUTOR_HEARTBEAT_INTERVAL` | 30s | 心跳间隔 |

---

> **Eric 点评**：SparkContext 初始化链路是理解整个 Spark 架构的最佳起点。它清晰地展示了"先环境、后调度"的启动顺序，所有组件都围绕 `SparkEnv` 这个全局环境单例展开。理解了这个链路，就掌握了 Spark Driver 启动的全局视图。
