# Spark RPC 通信层源码分析

> **模块**: Spark Core — 网络通信层  
> **源码路径**: `core/src/main/scala/org/apache/spark/rpc/netty/NettyRpcEnv.scala`  
> **相关模块**: `Dispatcher.scala`, `Outbox.scala`, `Inbox.scala`, `NettyRpcHandler.scala`  
> **分析日期**: 2026-05-10  
> **Spark 版本**: 4.x (master)

---

## 1. 定位与上下文

Spark RPC 层是整个分布式通信的底层基础设施：

```
上层: DAGScheduler / TaskScheduler / BlockManagerMaster / ...
      ↓ 调用
RPC 层: RpcEnv.ask() / RpcEnv.send()   ← Fire-and-forget / Request-Response
      ↓
NettyRpcEnv
      ├─ Dispatcher     — 消息分发到本地 RpcEndpoint
      ├─ Outbox         — 远程消息发送队列
      ├─ Inbox          — 本地 RpcEndpoint 消息处理
      └─ TransportContext — Netty 底层网络
           └─ TransportServer / TransportClientFactory
                └─ Netty NIO / Epoll
```

**两条通信路径**：
- **本地同 JVM**：消息直接路由到 Inbox（无网络开销）
- **跨节点**：消息经 Outbox → TCP 连接 → 对方 Inbox

---

## 2. 核心组件架构

### 2.1 NettyRpcEnv 初始化

```scala
class NettyRpcEnv(conf: SparkConf, host: String, ...) extends RpcEnv {

  // 每个 JVM 一个 Dispatcher（消息分发中枢）
  private[netty] val dispatcher: Dispatcher = new Dispatcher(this, numUsableCores)

  // Netty Transport 层
  private val transportContext = new TransportContext(
    transportConf,
    new NettyRpcHandler(dispatcher, this, streamManager)  // 底层消息处理器
  )

  // 客户端工厂（复用连接池）
  private val clientFactory = transportContext.createClientFactory(createClientBootstraps())

  // RPC Server（监听 RPC 请求）
  private val server: TransportServer = transportContext.createServer(host, port, bootstraps)

  // 文件下载专用客户端（隔离 RPC 流量）
  @volatile private var fileDownloadFactory: TransportClientFactory = _

  // 连接建立线程池（createClient 是阻塞的）
  private[netty] val clientConnectionExecutor = ThreadUtils.newDaemonCachedThreadPool(
    "netty-rpc-connection", conf.get(RPC_CONNECT_THREADS))
}
```

### 2.2 Dispatcher — 消息分发

```scala
class Dispatcher(nettyEnv: NettyRpcEnv, numUsableCores: Int) extends Logging {

  // name → MessageLoop（独立线程或线程池中执行）
  private val endpoints: ConcurrentMap[String, MessageLoop] = new ConcurrentHashMap()
  private val endpointRefs: ConcurrentMap[RpcEndpoint, RpcEndpointRef] = new ConcurrentHashMap()

  // 两种消息循环模式：
  // 1. IsolatedRpcEndpoint → DedicatedMessageLoop（独占线程）
  // 2. 普通 RpcEndpoint → sharedLoop（共享线程池）
  def registerRpcEndpoint(name: String, endpoint: RpcEndpoint): NettyRpcEndpointRef = {
    endpointRefs.put(endpoint, endpointRef)  // 先注册 ref

    val messageLoop = endpoint match {
      case e: IsolatedRpcEndpoint =>
        new DedicatedMessageLoop(name, e, this)  // 独占线程
      case _ =>
        sharedLoop.register(name, endpoint)      // 共享线程池
        sharedLoop
    }
    endpoints.put(name, messageLoop)
    endpointRef
  }
}
```

**关键设计 — 两种消息循环**：
| 模式 | 适用场景 | 线程 |
|------|---------|------|
| DedicatedMessageLoop | 高并发/高优先级 Endpoint（如 CoarseGrainedSchedulerBackend） | 独占线程 |
| SharedMessageLoop | 普通 Endpoint（如 BlockManagerMasterActor） | 共享线程池 |

---

## 3. 三种通信模式

### 3.1 send — Fire-and-Forget（单向）

```scala
// 调用方不等待响应，异步发送
def send(message: Any): Unit = {
  postToOutbox(receiver, OneWayOutboxMessage(message))
}

private def send(message: RequestMessage): Unit = {
  val remoteAddr = message.receiver.address
  if (remoteAddr == address) {
    // 同 JVM：直接本地分发
    dispatcher.postOneWayMessage(message)
  } else {
    // 跨节点：放入 Outbox 发送
    postToOutbox(message.receiver, OneWayOutboxMessage(message.serialize(this)))
  }
}
```

**用途**：`TaskSchedulerImpl.statusUpdate()` → 发到 DAGScheduler（本地）

### 3.2 ask — Request-Response（双向等待）

```scala
def ask[T](message: RequestMessage, timeout: RpcTimeout): Future[T] = {
  val promise = Promise[Any]()

  if (remoteAddr == address) {
    // 同 JVM：走本地消息循环
    val p = Promise[Any]()
    dispatcher.postLocalMessage(message, p)  // p 接收结果
    p.future.onComplete {
      case Success(response) => promise.trySuccess(response)
      case Failure(e) => promise.tryFailure(e)
    }(ThreadUtils.sameThread)
  } else {
    // 跨节点：RpcOutboxMessage 带回调
    val rpcMessage = RpcOutboxMessage(
      message.serialize(this),
      onFailure = onFailure,
      onSuccess = (client, response) => onSuccess(deserialize(response))
    )
    postToOutbox(receiver, rpcMessage)  // 异步等待
  }

  // 超时控制
  val timeoutCancelable = timeoutScheduler.schedule(..., timeout.duration.toNanos, NANOSECONDS)
  promise.future.onComplete { timeoutCancelable.cancel(true) }(sameThread)

  promise.future.mapTo[T]
}
```

**用途**：
- `CoarseGrainedSchedulerBackend.ask()` → Executor 端注册/响应
- `BlockManagerMaster.ask()` → Driver 端查询 Block 位置

### 3.3 askAbortable — 可中止的双向请求

```scala
// 支持在 RPC 进行中主动中止（用于 Task 取消等场景）
def askAbortable[T](message, timeout): AbortableRpcFuture[T] = {
  val rpcMessage = RpcOutboxMessage(...)
  rpcMsg = Option(rpcMessage)
  postToOutbox(receiver, rpcMessage)

  // onAbort 回调可在 RPC 进行中触发 TCP 连接关闭
  new AbortableRpcFuture(promise.future.mapTo[T], onAbort = rpcMessage.onAbort())
}
```

---

## 4. Outbox — 远程消息发送队列

每个远程目标地址维护一个 Outbox（防止连接风暴）：

```scala
private val outboxes: ConcurrentMap[RpcAddress, Outbox] = new ConcurrentHashMap()

private def postToOutbox(receiver: NettyRpcEndpointRef, message: OutboxMessage): Unit = {
  if (receiver.client != null) {
    // 已有连接 → 直接发送
    message.sendWith(receiver.client)
  } else {
    // 无连接 → 创建 Outbox（每个地址一个）
    val targetOutbox = outboxes.getOrPut(receiver.address) {
      val newOutbox = new Outbox(this, receiver.address)
      // Outbox 内部创建线程异步建立连接并发送
      newOutbox
    }
    if (stopped.get) {
      targetOutbox.stop()
    } else {
      targetOutbox.send(message)  // 消息入队
    }
  }
}
```

**Outbox 设计优势**：
- **连接复用**：同一个地址的所有消息复用同一个 TCP 连接
- **流量控制**：Outbox 内部有队列，超长队列时拒绝新消息
- **Failover**：连接断开时自动重连，Outbox 中消息不丢失

---

## 5. Inbox — 本地消息处理

每个 RpcEndpoint 有一个 Inbox，消息循环从 Inbox 中取出并分发到 Endpoint 的 `receive/receiveAndReply` 方法：

```scala
// 伪代码
class Inbox {
  val messages = java.util.Queue[InboxMessage]()

  def process(dispatcher: Dispatcher): Unit = synchronized {
    while (!messages.isEmpty) {
      val msg = messages.poll()
      msg match {
        case OneWayMessage(content, senderAddress, context) =>
          endpoint.receive(context, content)  // fire-and-forget
        case RpcMessage(content, senderAddress, p) =>
          endpoint.receiveAndReply(context, content)  // 带 promise
        case OnStartMessage =>
          endpoint.onStart()
        case OnStopMessage =>
          endpoint.onStop()
      }
    }
  }
}
```

---

## 6. Spark 核心 RpcEndpoint 注册

```scala
// 在 SparkEnv 创建时注册
SparkEnv.create()
  └─ val rpcEnv = NettyRpcEnv.create(...)
       ├─ rpcEnv.setupEndpoint("BlockManagerMaster", blockManagerMasterEndpoint)
       ├─ rpcEnv.setupEndpoint("MapOutputTracker", mapOutputTracker)
       ├─ rpcEnv.setupEndpoint("SparkUI", sparkUiEndpoint)
       ├─ rpcEnv.setupEndpoint("ExecutorRuntime", executorRuntime)  // IsolatedRpcEndpoint
       └─ rpcEnv.setupEndpoint("CoarseGrainedScheduler", schedulerBackend)
```

**IsolatedRpcEndpoint（独享线程）**：
- `ExecutorRuntime` — 每个 Executor 一个独占线程，避免线程竞争
- `CoarseGrainedExecutorBackend` — Executor 端主 Endpoint

---

## 7. 序列化与压缩

```scala
// NettyRpcEnv 使用 JavaSerializer 实例
val javaSerializerInstance: JavaSerializerInstance = {
  val ser = new JavaSerializer(conf)
  ser.newInstance()
}

// 消息序列化时压缩（可配置）
private def serialize(e: RpcEndpointRef, message: Any): ByteBuffer = {
  val bos = new ByteBufferOutputStream()
  val ser = e.serializer.newInstance()
  ser.serializeStream(bos).writeObject(message)
  compressIfNeeded(bos.toByteBuffer)
}
```

---

## 8. 完整调用链：Executor → Driver 注册

```
Executor.main()
  └─ CoarseGrainedExecutorBackend.run()
       └─ rpcEnv.asyncSetupEndpointRefByURI(driverUrl)
            ├─ ask(RpcEndpointVerifier.CheckExistence)  ← 验证 Driver 存在
            └─ onSuccess: executorRef = NettyRpcEndpointRef(drvierAddress)
       
  ExecutorBackend.registeredExecutor()
    └─ executorRef.send(RegisterExecutor(executorId, ...))  ← Fire-and-forget
         └─ NettyRpcEnv.send() → postToOutbox() → TCP → Driver

Driver 端：
  CoarseGrainedScheduler.receive()
    └─ case RegisterExecutor(executorId, ...) =>
         executorIdToHost(executorId) = host
         executorIdToRunningTaskIds(executorId) = HashSet()
         executorRef = context.senderAddress  ← 拿到 Executor 的 Ref
         backend.reviveOffers()  ← 触发资源调度
```

---

## 9. 关键配置参数

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `spark.rpc.io.threads` | CPU 核数 | Netty boss/worker 线程数 |
| `spark.rpc.connect.retry.enabled` | true | 连接重试 |
| `spark.rpc.connect.threads` | 8 | 建立连接的线程池大小 |
| `spark.rpc.io.numConnectionsPerPeer` | 1 | 与每个节点的连接数（默认复用） |
| `spark.rpc.message.maxSize` | 128MB | 单条 RPC 消息最大大小 |
| `spark.network.timeout` | 120s | 默认网络超时 |

---

## 10. 踩坑 & 运维要点

| 场景 | 现象 | 根因 | 解决 |
|------|------|------|------|
| `RpcEnv has been stopped` | Task 重试 | RPC Server 已关闭但有消息还在路上 | 升级 Spark，检查 executor 优雅退出流程 |
| RPC 超时 | Stage 挂死 | 网络抖动或 GC 阻塞 | 增大 `spark.network.timeout`；开启 `spark.executor.heartbeat.interval` |
| `OneWayOutboxMessage` 丢失 | 消息没到 | Outbox 队列满丢弃 | 监控 `netty-rpc-*` 线程；检查网络 |
| `ask` 超时但 send 正常 | 特定 RPC 失败 | 对方 endpoint 未正确响应 | 抓包分析 RPC 序列；检查 endpoint receiveAndReply |
| 连接数过多 | File descriptor 耗尽 | 大量小文件/频繁创建连接 | 启用连接复用；检查 `spark.rpc.io.numConnectionsPerPeer` |
| Executor 无法注册 | `Cannot receive any reply from driver` | Driver 地址不可达（NAT/防火墙） | 检查 `spark.driver.host` / `--host` 配置 |