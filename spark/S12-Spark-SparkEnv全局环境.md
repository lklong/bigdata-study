# SparkEnv 全局环境初始化

## 1. 核心定位

`SparkEnv` 是 Spark 运行时所有核心对象的容器，通过全局单例模式供所有线程访问。它在 Driver 和 Executor 两侧都会创建，但职责不同。

**源码路径**：`core/src/main/scala/org/apache/spark/SparkEnv.scala`

---

## 2. 全局单例模式

```scala
147: object SparkEnv extends Logging {
148:   @volatile private var env: SparkEnv = _

149:   private[spark] val driverSystemName = "sparkDriver"
150:   private[spark] val executorSystemName = "sparkExecutor"

153:   def set(e: SparkEnv): Unit = { env = e }
156:   def get: SparkEnv = {
157:     if (env == null) throw new SparkException(...)
158:     env
159:   }
```

> **设计**：使用 `@volatile var` 实现线程安全的延迟初始化单例，所有组件通过 `SparkEnv.get` 访问。

---

## 3. SparkEnv 核心成员

```scala
59: class SparkEnv(
    val executorId: String,                          // 唯一标识（Driver = "driver"）
    private[spark] val rpcEnv: RpcEnv,                // RPC 通信环境
    val serializer: Serializer,                        // 数据序列化器
    val closureSerializer: Serializer,                // 闭包序列化器
    val serializerManager: SerializerManager,         // 序列化管理器
    val mapOutputTracker: MapOutputTracker,           // Map 输出追踪器
    val shuffleManager: ShuffleManager,                // Shuffle 管理器
    val broadcastManager: BroadcastManager,           // 广播管理器
    val blockManager: BlockManager,                   // 存储块管理器
    val securityManager: SecurityManager,             // 安全认证
    val metricsSystem: MetricsSystem,                 // 指标系统
    val memoryManager: MemoryManager,                 // 内存管理器
    val outputCommitCoordinator: OutputCommitCoordinator, // 输出提交协调器
    val conf: SparkConf) extends Logging
```

**12 大核心组件**，几乎涵盖 Spark 所有子系统。

---

## 4. create 方法核心逻辑（L1）

`SparkEnv.create()` 是核心工厂方法（约 100+ 行），分阶段构建所有组件：

### 4.1 身份判断

```scala
250: val isDriver = executorId == SparkContext.DRIVER_IDENTIFIER
```

区分 Driver 和 Executor 环境，决定组件创建策略。

### 4.2 SecurityManager

```scala
257: val securityManager = new SecurityManager(conf, ioEncryptionKey, authSecretFileConf)
258: if (isDriver) securityManager.initializeAuth()
```

### 4.3 RpcEnv 创建 ⭐

```scala
270: val systemName = if (isDriver) driverSystemName else executorSystemName
271: val rpcEnv = RpcEnv.create(systemName, bindAddress, advertiseAddress, 
                               port.getOrElse(-1), conf, securityManager, 
                               numUsableCores, !isDriver)
```

- **Driver**：创建 `NettyRpcEnv`，监听端口等待 Executor 连接
- **Executor**：使用 Driver 传过来的 RpcEnv（CoarseGrained 模式）

### 4.4 Serializer

```scala
279: val serializer = Utils.instantiateSerializerFromConf[Serializer](SERIALIZER, conf, isDriver)
281: val serializerManager = new SerializerManager(serializer, conf, ioEncryptionKey)
283: val closureSerializer = new JavaSerializer(conf)
```

- **Serializer**：用户数据序列化（Kryo / Java Serializer）
- **closureSerializer**：闭包序列化（固定用 JavaSerializer，因为 Kryo 无法序列化 Scala 闭包）

### 4.5 BroadcastManager

```scala
296: val broadcastManager = new BroadcastManager(isDriver, conf)
```

### 4.6 MapOutputTracker ⭐

```scala
298: val mapOutputTracker = if (isDriver) {
299:   new MapOutputTrackerMaster(conf, broadcastManager, isLocal)
300: } else {
301:   new MapOutputTrackerWorker(conf)
302: }
```

- **Driver**：创建 Master，持有所有 shuffle map output 的元信息
- **Executor**：创建 Worker，通过 RPC 向 Master 查询

```scala
306: mapOutputTracker.trackerEndpoint = registerOrLookupEndpoint(
307:   MapOutputTracker.ENDPOINT_NAME,
308:   new MapOutputTrackerMasterEndpoint(rpcEnv, mapOutputTracker.asInstanceOf[MapOutputTrackerMaster], conf))
```

### 4.7 ShuffleManager

```scala
311: val shortShuffleMgrNames = Map(
      "sort" -> "org.apache.spark.shuffle.sort.SortShuffleManager",
      "tungsten-sort" -> "org.apache.spark.shuffle.sort.SortShuffleManager")
315: val shuffleMgrName = conf.get(config.SHUFFLE_MANAGER)
317: val shuffleManager = Utils.instantiateSerializerOrShuffleManager[ShuffleManager](...)
```

可插拔设计，通过 SPI 机制支持自定义 ShuffleManager。

### 4.8 MemoryManager ⭐

```scala
320: val memoryManager: MemoryManager = UnifiedMemoryManager(conf, numUsableCores)
```

统一内存管理器，涵盖执行内存和存储内存的动态分配。

### 4.9 BlockManagerMaster & BlockManager ⭐

```scala
337: val blockManagerInfo = new concurrent.TrieMap[BlockManagerId, BlockManagerInfo]()
338: val blockManagerMaster = new BlockManagerMaster(
      registerOrLookupEndpoint(BlockManagerMaster.DRIVER_ENDPOINT_NAME, 
        new BlockManagerMasterEndpoint(...)),
      registerOrLookupEndpoint(BlockManagerMaster.DRIVER_HEARTBEAT_ENDPOINT_NAME,
        new BlockManagerMasterHeartbeatEndpoint(...)),
      conf, isDriver)

360: val blockTransferService = new NettyBlockTransferService(...)
365: val blockManager = new BlockManager(...)
```

- **BlockManagerMaster**：仅在 Driver 创建，维护全局 Block 元信息
- **NettyBlockTransferService**：基于 Netty 的块传输服务

### 4.10 MetricsSystem

```scala
val metricsSystem = MetricsSystem.registerSources(...)
```

### 4.11 OutputCommitCoordinator

```scala
val outputCommitCoordinator = new OutputCommitCoordinator(...)
```

---

## 5. Driver vs Executor 创建差异

| 组件 | Driver | Executor |
|------|--------|---------|
| RpcEnv | `RpcEnv.create()` 新建 | 使用 Driver 传过来的 |
| MapOutputTracker | `MapOutputTrackerMaster` | `MapOutputTrackerWorker` |
| BlockManagerMaster | 新建 Master | 不创建，只连接 Driver |
| BlockManager | 新建 | 新建（每个 Executor 独立） |
| BroadcastManager | 新建 | 新建（每个 Executor 独立） |
| Serializer | Kryo/Java | 同 Driver |
| MetricsSystem | 启动（start()） | 注册 source |

---

## 6. 组件关系图

```
SparkEnv
  ├─ RpcEnv ───────────────────┐
  │   └─ NettyRpcEnv ─────────┼─ Dispatcher / Outbox / Inbox
  │       └─ NettyStreamManager
  ├─ BlockManager ─────────────┤
  │   ├─ BlockManagerMaster ──┤
  │   ├─ BlockTransferService ─┤
  │   └─ MemoryStore ──────────┤
  ├─ MemoryManager ────────────┤
  │   ├─ ExecutionMemoryPool ──┤
  │   └─ StorageMemoryPool ────┤
  ├─ MapOutputTracker ─────────┤
  ├─ ShuffleManager ───────────┤
  ├─ BroadcastManager ──────────┤
  ├─ SerializerManager ────────┤
  └─ MetricsSystem ─────────────┘
```

---

## 7. stop() 方法

```scala
87: private[spark] def stop(): Unit = {
89:   if (!isStopped) {
90:     isStopped = true
91:     pythonWorkers.values.foreach(_.stop())
92:     mapOutputTracker.stop()
93:     shuffleManager.stop()
94:     broadcastManager.stop()
95:     blockManager.stop()
96:     blockManager.master.stop()
97:     metricsSystem.stop()
98:     outputCommitCoordinator.stop()
99:     rpcEnv.shutdown()
100:   rpcEnv.awaitTermination()
```

**优雅关闭顺序**：先子组件后 RpcEnv，符合依赖顺序。

---

## 8. Executor 端 SparkEnv 创建

在 `CoarseGrainedExecutorBackend` 收到 `RegisteredExecutor` 后：

```scala
// CoarseGrainedExecutorBackend 第 112 行
executor = new Executor(executorId, executorHostname, env, ...)
```

```scala
// Executor 构造函数中
SparkEnv.createExecutorEnv(conf, executorId, bindAddress, hostname, 
                           numCores, ioEncryptionKey, isLocal)
```

Executor 的 SparkEnv 由 Driver 通过 `CoarseGrainedExecutorBackend` 传递过来，而非自己创建。

---

## 9. 关键设计模式

### 9.1 单例模式
`SparkEnv.get` 静态访问点，所有代码无需传递 SparkEnv 实例。

### 9.2 可插拔架构
ShuffleManager、Serializer 都支持通过配置自定义实现。

### 9.3 依赖注入
各组件通过构造函数注入依赖，而非全局 static 访问。

### 9.4 线程安全
`@volatile private var env` 保证多线程可见性。

---

## 10. 关键配置参数

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `spark.serializer` | `org.apache.spark.serializer.KryoSerializer` | 数据序列化器 |
| `spark.shuffle.manager` | `sort` | Shuffle 策略 |
| `spark.memory.fraction` | 0.6 | 堆内存用于执行+存储的比例 |
| `spark.memory.storageFraction` | 0.5 | 存储内存初始占比 |

---

> **Eric 点评**：SparkEnv 是 Spark 的"主板"，将所有核心子系统通过单一入口组织起来。它的设计体现了"关注点分离"——每个组件职责单一，通过统一的单例访问点整合。这种设计让 Spark 可以灵活地替换组件实现（如换 ShuffleManager），同时保持代码整洁。
