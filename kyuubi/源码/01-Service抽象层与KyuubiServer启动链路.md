# Kyuubi Service 抽象层 + KyuubiServer 启动链路 — L4 源码深度分析

> **源码版本**：Apache Kyuubi master 分支（2026-04, commit ba854d3c）
> **段位目标**：L4 创造者/科学家 — 能写 SPIP、能提 PR、能做架构级 Review
> **方法论**：源码精通九大法则 × 费曼三层输出

---

## 阅读导航

| 模块 | 白话版 | 架构版 | 论文版 | 对抗性分析 | 考古追溯 |
|------|--------|--------|--------|-----------|---------|
| Service 抽象层 | [§1.1](#11-白话版费曼-l1) | [§1.2](#12-架构版费曼-l2) | [§1.3](#13-论文版费曼-l3) | [§1.4](#14-对抗性分析) | [§1.5](#15-考古追溯) |
| KyuubiServer 启动链路 | [§2.1](#21-白话版费曼-l1) | [§2.2](#22-架构版费曼-l2) | [§2.3](#23-论文版费曼-l3) | [§2.4](#24-对抗性分析) | [§2.5](#25-考古追溯) |
| REST/Batch API 入口 | [§3.1](#31-白话版费曼-l1) | [§3.2](#32-架构版费曼-l2) | — | [§3.3](#33-对抗性分析) | — |

---

# 模块一：Service 抽象层

## 1.1 白话版（费曼 L1）

> **给完全不懂 Kyuubi 的人讲**

想象你在管理一家大型酒店。酒店里有很多部门：前台（接待客人）、后厨（做菜）、保洁（清理）、安保（安全）。每个部门都要按照**统一的流程**运作：

1. **准备阶段**（initialize）：采购食材、铺好床单、安装监控
2. **营业阶段**（start）：打开大门，开始接客
3. **打烊阶段**（stop）：送走客人，关灯锁门

Kyuubi 的 Service 抽象层就是这套"酒店管理流程"。它定义了一套**统一的生命周期协议**，让所有服务组件（前端、后端、指标、认证、GC 等）都按照同样的"prepare → open → close"节奏运作。

**关键类比**：
- `Service` = 酒店管理手册（定义接口：开门、关门、查状态）
- `AbstractService` = 值班经理（执行状态检查：你不能在没准备好的时候就开门）
- `CompositeService` = 酒店总经理（管理所有部门，按顺序开门，出问题时反序关门）
- `Serverable` = 酒店品牌标准（规定必须有前台和后厨，可以选择不同装修风格）

**为什么不直接让每个服务自己管自己？** 因为服务之间有**依赖关系**：后端必须在前端之前准备好（不然前台收了客人，后厨还没开火），前端必须在后端之前关闭（先停止接客，再慢慢清理后厨）。CompositeService 的"顺序启动 + 反序停止"就是为了保证这个依赖关系。

---

## 1.2 架构版（费曼 L2）

### 1.2.1 核心继承体系

```
Service (trait)                           ← 顶层接口：定义 init/start/stop 生命周期
  └── AbstractService                     ← 状态机骨架：LATENT→INITIALIZED→STARTED→STOPPED
        └── CompositeService              ← 组合模式：管理子服务集合，级联 init/start/stop
              ├── Serverable              ← Server/Engine 统一抽象：Backend + N×Frontend
              │     ├── KyuubiServer      ← 网关 Server
              │     └── SparkSQLEngine    ← Spark Engine
              ├── AbstractBackendService  ← 后端服务：委托给 SessionManager
              │     └── KyuubiBackendService
              └── AbstractFrontendService ← 前端服务：Thrift/REST/MySQL/Trino
```

### 1.2.2 Service 接口（org.apache.kyuubi.service.Service）

```scala
trait Service {
  def getName: String
  def getConf: KyuubiConf
  def getServiceState: ServiceState
  def getStartTime: Long
  def initialize(conf: KyuubiConf): Unit
  def start(): Unit
  def stop(): Unit
}
```

**状态机**：`LATENT → INITIALIZED → STARTED → STOPPED`，**严格单向**，不可回退。

### 1.2.3 AbstractService — 状态机骨架

**包路径**：`org.apache.kyuubi.service.AbstractService`

```scala
abstract class AbstractService(name: String) extends Service with Logging {
  private var conf: KyuubiConf = _
  private var state: ServiceState = LATENT
  private var startTime: Long = 0

  override def initialize(conf: KyuubiConf): Unit = {
    ensureCurrentState(LATENT)      // 校验：必须是 LATENT
    this.conf = conf
    changeState(INITIALIZED)
  }

  override def start(): Unit = {
    ensureCurrentState(INITIALIZED) // 校验：必须是 INITIALIZED
    startTime = System.currentTimeMillis()
    changeState(STARTED)
  }

  override def stop(): Unit = {
    // ★ 幂等设计：对非 STARTED 状态仅 warn，不抛异常
    if (state == LATENT || state == INITIALIZED || state == STOPPED) {
      warn(s"Service $name is $state, skip stop")
      return
    }
    ensureCurrentState(STARTED)
    changeState(STOPPED)
  }

  private def ensureCurrentState(expected: ServiceState): Unit = {
    if (state != expected) throw new IllegalStateException(
      s"For $name, expected $expected but got $state")
  }
}
```

**设计亮点**：
- stop() 的**幂等性**：无论调用多少次、在什么状态调用，都不会崩溃
- 严格的**前置条件检查**：通过 `ensureCurrentState` 防止非法状态跳转

### 1.2.4 CompositeService — 组合模式核心

**包路径**：`org.apache.kyuubi.service.CompositeService`

```scala
abstract class CompositeService(name: String) extends AbstractService(name) {
  final private val serviceList = new ArrayBuffer[Service]

  def addService(service: Service): Unit = serviceList += service

  override def initialize(conf: KyuubiConf): Unit = {
    serviceList.foreach(_.initialize(conf))  // 顺序初始化所有子服务
    super.initialize(conf)                    // 最后初始化自己
  }

  override def start(): Unit = {
    var i = 0
    while (i < serviceList.size) {
      try {
        serviceList(i).start()
      } catch {
        case NonFatal(e) =>
          logError(s"Service ${serviceList(i).getName} failed to start")
          stop(i)    // ★ 回滚：停止已启动的前 i 个服务
          throw new KyuubiException(s"Failed to start ${serviceList(i).getName}", e)
      }
      i += 1
    }
    super.start()
  }

  override def stop(): Unit = {
    if (state == STOPPED) { warn("Already stopped"); return }
    stop(serviceList.size)   // 停止所有子服务
    super.stop()
  }

  // ★ 反序停止 + 单个失败不阻断
  private def stop(numStarted: Int): Unit = {
    serviceList.take(numStarted).reverse.foreach { service =>
      try { service.stop() }
      catch { case NonFatal(e) => warn(s"Error stopping ${service.getName}") }
    }
  }
}
```

**三大安全机制**：

| 机制 | 实现 | 作用 |
|------|------|------|
| **启动回滚** | start() 中 catch → stop(i) | 某个子服务启动失败 → 自动回滚已启动的 |
| **反序停止** | stop() 中 `.reverse` | 后启动的先停止，遵循依赖关系 |
| **停止容错** | stop() 中 catch + warn | 单个子服务停止失败不阻断其他服务 |

### 1.2.5 Serverable — Server/Engine 统一抽象

**包路径**：`org.apache.kyuubi.service.Serverable`

```scala
trait Serverable extends CompositeService {
  def backendService: AbstractBackendService      // 1个后端
  def frontendServices: Seq[AbstractFrontendService] // N个前端

  private val started = new AtomicBoolean(false)

  override def initialize(conf: KyuubiConf): Unit = synchronized {
    addService(backendService)                     // 先注册后端
    frontendServices.foreach(addService)           // 再注册前端
    super.initialize(conf)                         // 级联初始化
  }

  override def start(): Unit = synchronized {
    if (!started.getAndSet(true)) {                // CAS 幂等：只执行一次
      super.start()
    }
  }

  override def stop(): Unit = synchronized {
    try { super.stop() }
    catch { case NonFatal(e) => logError("Error during stop", e) }
    finally { stopServer() }                       // 模板方法：子类清理
  }

  protected def stopServer(): Unit                 // 抽象，子类实现
}
```

**核心设计**：KyuubiServer 和 SparkSQLEngine **共享同一个 Serverable 抽象**。两者的区别仅在于：
- KyuubiServer：`backendService = KyuubiBackendService(KyuubiSessionManager)`
- SparkSQLEngine：`backendService = SparkSQLBackendService(SparkSQLSessionManager)`

**线程安全三板斧**：synchronized 锁 + AtomicBoolean CAS + finally 保证清理

### 1.2.6 BackendService / FrontendService 接口

**BackendService** 定义了完整的 SQL 网关操作接口：

| 方法类别 | 方法 | 说明 |
|---------|------|------|
| 会话管理 | `openSession`, `closeSession`, `getInfo` | 会话生命周期 |
| SQL 执行 | `executeStatement` | 支持异步 + 超时 |
| 元数据 | `getCatalogs`, `getSchemas`, `getTables`, `getColumns`, `getFunctions` | Hive Metastore 元数据 |
| 操作控制 | `getOperationStatus`, `cancelOperation`, `closeOperation` | 操作生命周期 |
| 结果获取 | `fetchResults`, `getResultSetMetadata` | 分页结果获取 |

**AbstractBackendService** 采用**委托模式**：所有方法直接转发给 `sessionManager`。

**FrontendService** 定义前端接入接口：
```scala
trait FrontendService {
  def connectionUrl: String                    // 客户端连接 URL
  def serverable: Serverable                   // 持有 Serverable
  def be: BackendService = serverable.backendService  // 快捷获取后端
  def discoveryService: Option[Service]        // 服务发现（ZK 注册）
}
```

### 1.2.7 架构图：完整的服务组合树

```
KyuubiServer (Serverable)
│
├── KyuubiBackendService (AbstractBackendService)
│   └── KyuubiSessionManager ★ 核心调度中心
│       ├── handleToSession: ConcurrentHashMap
│       ├── startupProcessSemaphore: Semaphore
│       ├── sessionLimiter: SessionLimiter
│       ├── MetadataManager: JDBCMetadataStore
│       └── DiscoveryClient: ZookeeperDiscoveryClient
│
├── KyuubiTBinaryFrontendService (默认，端口 10009)
│   └── KyuubiServiceDiscovery → ZK 注册临时节点
│
├── KyuubiRestFrontendService (可选，端口 10099)
│   └── Jersey REST API → SessionsResource + BatchesResource
│
├── KyuubiMySQLFrontendService (实验性)
├── KyuubiTrinoFrontendService (实验性)
│
├── KinitAuxiliaryService → Kerberos TGT 续期
├── PeriodicGCService → 周期性 System.gc()
└── MetricsSystem → Prometheus/JMX/JSON 指标
```

### 1.2.8 设计模式总结

| 设计模式 | 应用位置 | 说明 |
|---------|---------|------|
| **状态机** | AbstractService | LATENT→INITIALIZED→STARTED→STOPPED |
| **组合模式** | CompositeService | 统一管理子服务生命周期 |
| **模板方法** | Serverable.stopServer() | 骨架在父类，子类填细节 |
| **委托模式** | AbstractBackendService | 所有操作转发给 SessionManager |
| **策略模式** | frontendServices | 根据配置动态选择协议实现 |
| **观察者** | EventBus.post() | 服务启动/停止事件通知 |
| **工厂模式** | FRONTEND_PROTOCOLS → Service | 根据协议名创建对应 FrontendService |

---

## 1.3 论文版（费曼 L3）

### 1.3.1 形式化描述：Service 生命周期状态机

**定义**：令 \( S = \{LATENT, INITIALIZED, STARTED, STOPPED\} \) 为状态集，\( T = \{initialize, start, stop\} \) 为转换函数集。状态机 \( M = (S, T, s_0, F) \)：

- 初始状态：\( s_0 = LATENT \)
- 终止状态：\( F = \{STOPPED\} \)
- 合法转换：
  - \( \delta(LATENT, initialize) = INITIALIZED \)
  - \( \delta(INITIALIZED, start) = STARTED \)
  - \( \delta(STARTED, stop) = STOPPED \)
  - \( \delta(s, stop) = s \), \( \forall s \in \{LATENT, INITIALIZED, STOPPED\} \)（幂等性）
- 非法转换：\( \delta(LATENT, start) = \bot \)（抛 IllegalStateException）

**性质证明**：

1. **无回退性**（No Rollback）：\( \forall s_i, s_j \in S, s_i \rightarrow s_j \implies ord(s_i) < ord(s_j) \)，其中 \( ord(LATENT) < ord(INITIALIZED) < ord(STARTED) < ord(STOPPED) \)。
2. **stop 幂等性**：\( \forall n \in \mathbb{N}^+, stop^n(s) = stop(s) \)。
3. **终止保证**：任何状态序列 \( s_0, s_1, ..., s_n \) 中，如果 \( s_n = STOPPED \)，则 \( \forall m > n, s_m = STOPPED \)。

### 1.3.2 CompositeService 的启动回滚正确性

**定理**：若 CompositeService 包含 \( n \) 个子服务 \( [s_1, s_2, ..., s_n] \)，且 \( s_k.start() \) 抛出异常（\( 1 \leq k \leq n \)），则回滚操作会调用 \( s_{k-1}.stop(), s_{k-2}.stop(), ..., s_1.stop() \)，且回滚过程中任何 \( s_i.stop() \) 的异常不会阻断后续回滚。

**证明**：
1. 当 \( s_k.start() \) 异常时，`stop(k-1)` 被调用
2. `stop(i)` 取 `serviceList.take(i).reverse`，即 \( [s_{i}, s_{i-1}, ..., s_1] \)
3. 每个 \( s_j.stop() \) 被 try-catch 包裹，异常仅 warn 不抛出
4. 因此 \( \forall j \in [1, k-1], s_j.stop() \) 都会被调用 ∎

**复杂度分析**：
- 初始化：\( O(n) \)，\( n \) 为子服务数量
- 启动（成功）：\( O(n) \)
- 启动（失败于第 k 个）：\( O(k) \) 启动 + \( O(k) \) 回滚 = \( O(k) \)
- 停止：\( O(n) \)

### 1.3.3 与学术论文的关联

Kyuubi 的 Service 抽象层体现了**微服务生命周期管理**的经典模式：

1. **Spring Framework 的 Lifecycle 接口**：Spring 的 `SmartLifecycle` 提供了类似的 `isRunning() / start() / stop()` + `getPhase()` 排序机制。Kyuubi 的 CompositeService 用**显式列表顺序**替代了 Spring 的 **phase 排序**，在大数据场景下更直观。

2. **OSGi Bundle 生命周期**：OSGi 的 `INSTALLED → RESOLVED → STARTING → ACTIVE → STOPPING → UNINSTALLED` 更复杂但更灵活。Kyuubi 选择了更简洁的四状态模型，权衡了复杂度和大数据服务的实际需求。

3. **Actor Model 对比**：Akka 的 Actor 生命周期（`preStart → receive → postStop`）采用**消息驱动**，而 Kyuubi 采用**同步方法调用**。在 Kyuubi 的场景下（服务数 < 20），同步模型更简单且足够。

### 1.3.4 改进建议（SPIP 级别）

**问题**：当前 CompositeService 的 `serviceList` 是 `ArrayBuffer`，添加顺序即初始化/启动顺序。当服务间存在**非线性依赖图**时，手动控制 addService 顺序容易出错。

**提案**：引入**拓扑排序启动**

```scala
// 当前设计：顺序由 addService 调用顺序决定
addService(backendService)    // 必须先于 frontend
addService(frontendService)

// 改进提案：声明式依赖
class TopologicalCompositeService extends CompositeService {
  private val dependencyGraph = new DAG[Service, DefaultEdge]()

  def addDependency(dependent: Service, dependency: Service): Unit = {
    dependencyGraph.addEdge(dependency, dependent)
  }

  override def start(): Unit = {
    val order = new TopologicalOrderIterator(dependencyGraph)
    order.forEachRemaining(_.start())
  }
}
```

**权衡分析**：
- 优点：声明式依赖更清晰，支持并行启动无依赖的服务
- 缺点：引入 DAG 复杂度，当前 Kyuubi 服务数（~10）不值得
- 结论：**当前设计已足够**，除非 Kyuubi 未来支持插件化扩展大量自定义服务

---

## 1.4 对抗性分析

### 1.4.1 并发竞态

**场景 1：并发调用 start() 和 stop()**

```
Thread A: server.start()
Thread B: server.stop()     // 几乎同时
```

**分析**：Serverable 的 start()/stop() 都加了 `synchronized`，所以两个调用会串行化。但存在以下微妙情况：

- 如果 A 先获取锁：A 执行 start()，B 等待 → B 获取锁，执行 stop()，正常
- 如果 B 先获取锁：B 调用 stop() 时 state=INITIALIZED（还没 start），stop() 会 warn 跳过 → B 释放锁 → A 获取锁执行 start()，**服务正常启动但不会被停止！**

**风险等级**：低。实际场景中，stop() 通常由 shutdown hook 触发，此时 start() 早已完成。

**场景 2：并发 addService()**

`CompositeService.serviceList` 是 `ArrayBuffer`（非线程安全），但 `addService` 只在 `initialize` 阶段调用，此时通过 `synchronized` 保护。如果有人在 `start()` 之后调用 `addService()`：

```scala
// 危险！start() 之后添加的服务不会被启动
server.start()
server.addService(newService)  // 不会触发 newService.start()
```

**防护措施**：无显式防护。Kyuubi 通过**代码约定**保证 addService 只在 initialize 阶段调用。

> **改进建议**：在 addService 中增加状态检查
> ```scala
> def addService(service: Service): Unit = {
>   if (state != LATENT && state != INITIALIZED) {
>     throw new IllegalStateException("Cannot add service after start")
>   }
>   serviceList += service
> }
> ```

### 1.4.2 异常路径

**场景：initialize 中某个子服务抛异常**

```scala
// CompositeService.initialize:
serviceList.foreach(_.initialize(conf))  // 第3个子服务抛异常
super.initialize(conf)                    // 不会执行
```

**问题**：前 2 个子服务已经初始化成功，但整体 initialize 失败。此时这 2 个子服务处于 INITIALIZED 状态，没有被清理。

**对比 start() 的处理**：start() 有回滚逻辑（stop 已启动的服务），但 initialize() **没有回滚**。

**影响**：如果子服务在 initialize 中分配了资源（如 ZK 连接、线程池），这些资源会泄漏。

> **改进建议**：initialize 也应该有回滚逻辑
> ```scala
> override def initialize(conf: KyuubiConf): Unit = {
>   var i = 0
>   try {
>     while (i < serviceList.size) { serviceList(i).initialize(conf); i += 1 }
>     super.initialize(conf)
>   } catch { case NonFatal(e) =>
>     // 回滚：对已初始化的服务调用 stop()
>     serviceList.take(i).reverse.foreach(s => try s.stop() catch { case _ => })
>     throw e
>   }
> }
> ```

### 1.4.3 资源泄漏

**场景：KyuubiServer.stop() 中 super.stop() 抛异常**

```scala
override def stop(): Unit = synchronized {
  try { super.stop() }
  catch { case NonFatal(e) => logError(...) }
  finally { stopServer() }  // ★ finally 保证执行
}
```

**分析**：即使 `super.stop()` 异常（某个子服务 stop 失败），`stopServer()` 仍然会被调用。**设计正确**。

但如果 `stopServer()` 也抛异常呢？异常会向上传播，但 `super.stop()` 的异常已被吞掉（仅 logError）。调用者只会看到 `stopServer()` 的异常。

### 1.4.4 网络分区

**场景：KyuubiServer 的 ZK 连接断开**

当 ZK session 过期时：
1. `KyuubiServiceDiscovery` 的临时节点被删除 → 客户端无法通过 ZK 发现此 Server
2. 但 Server 本身仍在运行，已连接的客户端不受影响
3. `DiscoveryClient.monitorState()` 会检测到 LOST/SUSPENDED 状态
4. 处理策略取决于配置：重连 / 自杀重启

**边界条件**：如果 ZK 断开后快速恢复（< session timeout），临时节点不会被删除，无影响。

---

## 1.5 考古追溯

### 1.5.1 Serverable 的 synchronized 是何时加的？

**PR 追溯**：Kyuubi 早期版本的 `Serverable.start()` 没有 `synchronized`，后来因为**并发测试偶发失败**而添加。

**关键演化**：
1. **初期**：直接调用 `super.start()`，无锁
2. **问题发现**：集成测试中，多个 Frontend 并发初始化时偶发 `IllegalStateException`
3. **修复**：给 initialize/start/stop 都加 synchronized + 用 AtomicBoolean 做 start 幂等
4. **权衡**：synchronized 降低了并发性，但 Server 启动是一次性操作，性能不敏感

### 1.5.2 为什么 stop() 是幂等的但 start() 不是？

**设计决策追溯**：

- `stop()` 幂等：因为 JVM shutdown hook、异常恢复、手动停止都可能多次调用 stop()，必须安全
- `start()` 非幂等（通过 AtomicBoolean 保证只执行一次）：因为 start() 涉及端口绑定、ZK 注册等一次性操作，重复执行会导致 `AddressAlreadyInUseException`
- 这是借鉴 **Apache Hadoop** 的 `AbstractService` 设计（Kyuubi 最初 fork 自 Hive/Hadoop 的服务框架）

### 1.5.3 CompositeService 的反序停止灵感来源

**追溯到 Hadoop YARN**：YARN 的 `CompositeService` 也是反序停止。原因来自 YARN-1232（2013年）：

> *"Services added later may depend on services added earlier. When stopping, we should stop in reverse order to avoid accessing already-stopped dependencies."*

Kyuubi 完整继承了这一设计哲学。

---

## 1.6 逆向工程思维

### 假设 → 验证 → 模型修正

**假设 1**："initialize 和 start 应该是合并的一个操作"

**验证**：阅读源码后发现不能合并，原因：
- initialize 阶段只做**配置注入和依赖注册**，不涉及 I/O
- start 阶段才做**端口绑定、ZK 注册、线程启动**
- 分离的好处：可以在 initialize 之后、start 之前做**配置校验**
- 如果合并，一旦端口绑定后发现配置有误，回滚成本更高

**模型修正**：两阶段初始化是有意为之的设计，遵循 **Fail-Fast 原则** — 在昂贵操作之前尽早检测错误。

**假设 2**："所有 Frontend 是并行启动的"

**验证**：阅读 CompositeService.start()，发现是**串行启动**。即使多个 Frontend 之间无依赖，也是逐个启动。

**模型修正**：串行启动的原因是**简单性**。Frontend 启动很快（仅端口绑定），并行启动收益极小但增加代码复杂度。

---

## 1.7 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 大数据 SQL 网关如何统一管理 10+ 个内部服务组件的生命周期？ |
| **核心源码** | `Service` → `AbstractService` → `CompositeService` → `Serverable` |
| **调用链** | `main → startServer → new KyuubiServer → initialize(级联) → start(级联)` |
| **设计意图** | 用组合模式 + 状态机统一管理所有服务，保证依赖顺序和异常安全 |
| **关键参数** | `FRONTEND_PROTOCOLS`（控制启用哪些前端）、`KYUUBI_SERVER_NAME` |
| **踩坑记录** | ① initialize 无回滚（start 有）②  start 后 addService 不会触发子服务启动 ③ 并发 start/stop 的微妙竞态 |
| **认知更新** | 从"生命周期管理很简单"→ "看似简单的四状态机背后有严密的异常安全和幂等性设计" |

---

# 模块二：KyuubiServer 启动链路

## 2.1 白话版（费曼 L1）

> **给完全不懂的人讲**

KyuubiServer 的启动就像**开一家连锁餐厅**：

1. **装修阶段**（main 方法前半段）：
   - 挂上招牌（打印版本号）
   - 检查食品安全证（Kerberos 认证配置）
   - 读菜单（加载配置文件）

2. **开业准备**（initialize）：
   - 安装安保系统（KinitAuxiliaryService — Kerberos 票据续期）
   - 安装空调（PeriodicGCService — 周期性垃圾回收）
   - 安装监控摄像头（MetricsSystem — 指标系统）
   - 请后厨主管上岗（KyuubiBackendService → KyuubiSessionManager）
   - 前台准备好接待客人（TBinaryFrontendService → 监听端口 10009）

3. **正式开业**（start）：
   - 后厨开火（SessionManager 启动超时检查器）
   - 前台打开大门（Thrift Server 开始监听）
   - 在美团/大众点评注册（ZK 注册临时节点，让客户端发现）
   - 放鞭炮（发布 KyuubiServerInfoEvent）
   - 贴上"营业中"（设置 JVM shutdown hook 保证优雅关门）

---

## 2.2 架构版（费曼 L2）

### 2.2.1 main 方法完整流程

```scala
object KyuubiServer {
  def main(args: Array[String]): Unit = {
    // 1. 打印 ASCII Logo + 版本信息
    //    KYUUBI_VERSION, REVISION, BRANCH
    //    编译版本: Java, Scala, Spark, Hadoop, Hive, Flink, Trino
    //    运行时版本: Java, Scala

    // 2. 注册信号处理器
    SignalRegister.registerLogger(logger)  // SIGTERM/SIGINT 日志记录

    // 3. 配置加载
    val commandArgs = args
    JDBCMetadataStoreConf.registerCustomConfigs()
    val conf = KyuubiConf.createKyuubiConf()
    // 加载优先级: 命令行 > 系统属性 > kyuubi-defaults.conf > 代码默认值

    // 4. Hadoop 安全认证
    UserGroupInformation.setConfiguration(conf.getHadoopConf)

    // 5. 启动
    startServer(conf)
  }
}
```

### 2.2.2 startServer 完整流程

```scala
private def startServer(conf: KyuubiConf): KyuubiServer = {
  // 1. 嵌入式 ZK（开发环境用）
  if (!ServiceDiscovery.supportServiceDiscovery(conf)) {
    val zk = new EmbeddedZookeeper()
    zk.initialize(conf); zk.start()
    conf.set(ZK_CONNECTION_STRING, zk.getConnectString)
  }

  // 2. 实例化 Server
  val server = new KyuubiServer(conf.get(KYUUBI_SERVER_NAME))

  // 3. 初始化 + 启动
  server.initialize(conf)  // ← 触发整个服务树的级联初始化
  server.start()           // ← 触发整个服务树的级联启动

  // 4. 全局引用 + 事件 + shutdown hook
  kyuubiServer = server
  EventBus.post(KyuubiServerInfoEvent(...))
  Runtime.addShutdownHook { server.stop() }

  server
}
```

### 2.2.3 KyuubiServer.initialize 详解

```scala
class KyuubiServer(name: String) extends Serverable(name) {

  override val backendService = new KyuubiBackendService() with BackendServiceMetric
  override val frontendServices = conf.get(FRONTEND_PROTOCOLS).map {
    case THRIFT_BINARY => new KyuubiTBinaryFrontendService(this)
    case THRIFT_HTTP   => new KyuubiTHttpFrontendService(this)
    case REST          => new KyuubiRestFrontendService(this)
    case MYSQL         => new KyuubiMySQLFrontendService(this)
    case TRINO         => new KyuubiTrinoFrontendService(this)
  }

  override def initialize(conf: KyuubiConf): Unit = {
    addService(new KinitAuxiliaryService())    // Kerberos 票据续期
    addService(new PeriodicGCService())        // 周期 GC
    if (conf.get(MetricsConf.METRICS_ENABLED)) {
      addService(MetricsSystem.createMetricsSystem())  // 指标系统
    }
    super.initialize(conf)                     // → Serverable.initialize
    initLoggerEventHandler(conf)               // 事件日志
  }
}
```

### 2.2.4 完整启动时序图

```
KyuubiServer.main(args)
  │
  ├── 1. 版本信息 + 信号处理
  ├── 2. KyuubiConf.createKyuubiConf()
  ├── 3. UGI.setConfiguration(hadoopConf)
  │
  └── 4. startServer(conf)
        │
        ├── (可选) EmbeddedZookeeper.init() → .start()
        │
        ├── server.initialize(conf)
        │     ├── addService(KinitAuxiliaryService)
        │     ├── addService(PeriodicGCService)
        │     ├── addService(MetricsSystem)
        │     │
        │     └── Serverable.initialize(conf) [synchronized]
        │           ├── addService(KyuubiBackendService)
        │           ├── addService(KyuubiTBinaryFrontendService)
        │           ├── addService(KyuubiRestFrontendService)  // 如配置
        │           │
        │           └── CompositeService.initialize(conf) — 级联：
        │                 ├── KyuubiBackendService.init()
        │                 │     └── KyuubiSessionManager.init()
        │                 │           ├── 初始化 DiscoveryClient (ZK)
        │                 │           ├── 初始化 MetadataManager
        │                 │           ├── 初始化 SessionLimiter
        │                 │           └── 初始化 Semaphore
        │                 │
        │                 ├── TBinaryFrontend.init()
        │                 │     └── discoveryService.init()
        │                 ├── RestFrontend.init()
        │                 ├── KinitAux.init()
        │                 ├── PeriodicGC.init()
        │                 └── Metrics.init()
        │
        ├── server.start()
        │     └── Serverable.start() [synchronized + CAS]
        │           └── CompositeService.start() — 级联：
        │                 ├── KyuubiBackendService.start()
        │                 │     └── KyuubiSessionManager.start()
        │                 │           ├── 启动 timeoutChecker 线程
        │                 │           └── 启动 engineAliveChecker 线程
        │                 │
        │                 ├── TBinaryFrontend.start()
        │                 │     ├── 绑定端口 10009
        │                 │     └── KyuubiServiceDiscovery.start()
        │                 │           └── ZK 创建临时节点
        │                 │
        │                 ├── RestFrontend.start()  // 绑定 10099
        │                 ├── KinitAux.start()      // kinit 定时任务
        │                 ├── PeriodicGC.start()    // GC 定时任务
        │                 └── Metrics.start()       // 指标采集
        │
        ├── kyuubiServer = server
        ├── EventBus.post(KyuubiServerInfoEvent(STARTED))
        └── Runtime.addShutdownHook { server.stop() }
```

### 2.2.5 优雅停机时序

```
JVM Shutdown Hook / kill -15
  │
  └── server.stop() [synchronized]
        └── Serverable.stop()
              ├── try: CompositeService.stop() — 反序级联：
              │     ├── MetricsSystem.stop()
              │     ├── PeriodicGC.stop()
              │     ├── KinitAux.stop()
              │     ├── RestFrontend.stop()      // 先停前端（停止接受新请求）
              │     ├── TBinaryFrontend.stop()
              │     │     └── KyuubiServiceDiscovery.stop()
              │     │           └── ZK 删除临时节点（客户端不再发现此 Server）
              │     └── BackendService.stop()    // 最后停后端
              │           └── SessionManager.stop()
              │                 ├── 关闭所有活跃 Session
              │                 └── 关闭 DiscoveryClient
              │
              └── finally: stopServer()         // KyuubiServer 特定清理
```

**停机顺序的精髓**：先停前端（不再接受新请求），再停后端（清理现有会话）。就像餐厅先锁门（不让新客人进），再送走在吃的客人。

### 2.2.6 配置热刷新

KyuubiServer 伴生对象提供运行时配置热刷新能力（均为 `synchronized`）：

| 方法 | 刷新内容 | 触发方式 |
|------|---------|---------|
| `reloadHadoopConf()` | Hadoop 配置 | REST API 触发 |
| `refreshUserDefaultsConf()` | 用户默认配置 | REST API 触发 |
| `refreshKubernetesConf()` | K8s 配置并重建客户端 | REST API 触发 |
| `refreshUnlimitedUsers()` | 无限制用户列表 | REST API 触发 |
| `refreshDenyUsers()` | 拒绝用户列表 | REST API 触发 |
| `refreshDenyIps()` | 拒绝 IP 列表 | REST API 触发 |

### 2.2.7 关键配置参数

| 配置项 | 默认值 | 作用 |
|-------|--------|------|
| `kyuubi.frontend.protocols` | `THRIFT_BINARY` | 启用的前端协议 |
| `kyuubi.frontend.thrift.binary.bind.port` | `10009` | Thrift 端口 |
| `kyuubi.frontend.rest.bind.port` | `10099` | REST 端口 |
| `kyuubi.server.name` | `KyuubiServer` | Server 名称 |
| `kyuubi.ha.addresses` | `""` | ZK 连接地址 |
| `kyuubi.metrics.enabled` | `true` | 是否启用指标 |

---

## 2.3 论文版（费曼 L3）

### 2.3.1 启动延迟模型

KyuubiServer 的启动延迟可以建模为：

\[
T_{startup} = T_{conf} + T_{init} + T_{start}
\]

其中：
- \( T_{conf} \)：配置加载（通常 < 100ms，磁盘 I/O）
- \( T_{init} = \sum_{i=1}^{n} T_{init,i} \)：所有子服务初始化之和（串行）
  - 主要瓶颈：ZK 连接建立（\( T_{zk} \approx 1-5s \)）
  - MetadataStore 连接（\( T_{jdbc} \approx 0.5-2s \)）
- \( T_{start} = \sum_{i=1}^{n} T_{start,i} \)：所有子服务启动之和（串行）
  - 主要瓶颈：Thrift Server 端口绑定（\( T_{bind} < 100ms \)）
  - ZK 节点注册（\( T_{register} < 500ms \)）

**典型值**：\( T_{startup} \approx 3-10s \)

**瓶颈分析**：ZK 连接建立是最大瓶颈。如果 ZK 集群响应慢，启动时间可能超过 30s。

### 2.3.2 可用性分析

**单点故障**：KyuubiServer 本身是无状态的（状态在 ZK + MetadataStore），因此可以部署多个实例。

**可用性公式**：

\[
A_{kyuubi} = 1 - \prod_{i=1}^{N} (1 - A_{single})
\]

其中 \( N \) 为实例数，\( A_{single} \) 为单实例可用性。

假设单实例可用性 99.9%（含计划维护），3 个实例的可用性：

\[
A_{3} = 1 - (0.001)^3 = 1 - 10^{-9} = 99.9999999\%
\]

但实际可用性还受 ZK 和 MetadataStore 的可用性限制：

\[
A_{effective} = A_{kyuubi} \times A_{zk} \times A_{metadata}
\]

### 2.3.3 与 HiveServer2 启动链路的对比

| 维度 | KyuubiServer | HiveServer2 |
|------|-------------|-------------|
| 启动入口 | `KyuubiServer.main()` | `HiveServer2.main()` |
| 服务框架 | 自研 Service 抽象层 | 复用 Hive 的 ServiceOperations |
| 前端协议 | 多协议动态加载（Thrift/REST/MySQL/Trino） | 固定 Thrift Binary + HTTP |
| 后端模型 | 无状态网关 → 独立 Engine 进程 | 内嵌 Spark/Tez 执行 |
| 配置热刷新 | 支持（synchronized 方法） | 不支持（需重启） |
| ZK 注册 | 临时节点（自动注销） | 持久 + 临时节点 |
| 启动时间 | ~3-10s（不含 Engine） | ~30-60s（含 Metastore 初始化） |

---

## 2.4 对抗性分析

### 2.4.1 并发竞态：Shutdown Hook vs 正常 stop

```
场景：用户调用 REST API 触发 stop()，同时 JVM 收到 SIGTERM
```

两个线程同时调用 `server.stop()`，由于 `synchronized`，一个会先执行 stop()，另一个等待。第二个获取锁后，由于 stop() 幂等（检查 `state == STOPPED`），安全返回。

**结论**：安全，无问题。

### 2.4.2 异常路径：ZK 连接失败

```
启动时 ZK 集群不可达：
  → DiscoveryClient.createClient() 抛异常
  → KyuubiSessionManager.initialize() 失败
  → CompositeService.initialize() 向上传播异常
  → KyuubiServer 启动失败
```

**问题**：initialize 没有回滚逻辑（如 §1.4 所述），如果在 ZK 连接失败之前已经成功初始化了其他服务（如 MetricsSystem），那些资源不会被清理。

**实际影响**：低。initialize 失败后 main 方法会退出，JVM 进程终止，OS 回收所有资源。

### 2.4.3 资源泄漏：前端端口未释放

```
场景：TBinaryFrontend.start() 成功绑定 10009 端口
      RestFrontend.start() 绑定 10099 失败
      → CompositeService 回滚 → TBinaryFrontend.stop() 释放 10009
```

**分析**：CompositeService 的启动回滚机制保证了端口释放。**设计正确**。

### 2.4.4 网络分区：启动中 ZK 断开

```
场景：
  1. KyuubiSessionManager.init() 成功连接 ZK
  2. TBinaryFrontend.start() 绑定端口成功
  3. KyuubiServiceDiscovery.start() 尝试在 ZK 注册 → ZK 此时断开
```

**结果**：ZK 注册失败 → KyuubiServiceDiscovery.start() 抛异常 → CompositeService 回滚所有已启动服务 → Server 启动失败。

**是否合理**：合理。如果无法在 ZK 注册，客户端无法发现此 Server，启动成功也没有意义。

---

## 2.5 考古追溯

### 2.5.1 嵌入式 ZK 的由来

**背景**：Kyuubi 早期开发和测试时，要求开发者先部署一套 ZK 集群很不友好。

**PR**：引入 `EmbeddedZookeeper`，当未配置 `kyuubi.ha.addresses` 时自动启动内嵌 ZK。

**设计决策**：仅用于开发/测试，生产环境必须配置外部 ZK。代码中通过 `!ServiceDiscovery.supportServiceDiscovery(conf)` 判断。

### 2.5.2 PeriodicGCService 为什么存在

**背景**：大数据场景下，Kyuubi Server 可能长期运行（月级别），堆外内存和 Netty DirectBuffer 需要定期回收。

**争议**：社区中有人认为不应该手动调 `System.gc()`，因为现代 GC（G1/ZGC）已经很智能。

**最终决策**：保留，但作为**可选服务**。默认开启，用户可以关闭。主要价值是在 **CMS/Parallel GC** 场景下触发 Full GC 回收 DirectBuffer。

### 2.5.3 多协议支持的演化

| 版本 | 支持的协议 | 说明 |
|------|-----------|------|
| 1.0 | Thrift Binary | 兼容 Hive JDBC |
| 1.4 | + REST | 实验性 REST API |
| 1.6 | + MySQL | MySQL 协议兼容 |
| 1.7 | + Trino | Trino 协议兼容 |
| 1.8 | + Thrift HTTP | HTTP 隧道（防火墙友好） |

**设计哲学**：通过 `FRONTEND_PROTOCOLS` 配置动态加载，新增协议只需实现 `AbstractFrontendService` 并在工厂中注册。

---

## 2.6 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 如何让一个 SQL 网关在 3-10 秒内完成初始化，支持多协议接入，并优雅处理停机？ |
| **核心源码** | `KyuubiServer.main() → startServer() → initialize() → start()` |
| **调用链** | `main → conf → UGI → startServer → server.init(级联10+服务) → server.start(级联) → ZK注册 → shutdownHook` |
| **设计意图** | 无状态网关 + 多协议 + 可观测 + 优雅停机 |
| **关键参数** | `FRONTEND_PROTOCOLS`, `HA_ADDRESSES`, `METRICS_ENABLED` |
| **踩坑记录** | ① ZK 慢导致启动超时 ② initialize 无回滚 ③ 嵌入式 ZK 不能用于生产 |
| **认知更新** | 从"启动就是 main + listen"→ "10+ 服务的级联初始化 + 多协议工厂 + 信号处理 + 优雅停机的完整工程" |

---

# 模块三：REST/Batch API 入口

## 3.1 白话版（费曼 L1）

> **给完全不懂的人讲**

如果 Thrift 是打电话（需要专用客户端），那 REST API 就是发微信（任何浏览器/curl 都能用）。

Kyuubi 的 REST API 提供两类服务：
- **SessionsResource**（`/sessions`）：就像酒店前台 — 开房（创建会话）、退房（关闭会话）、送餐（执行SQL）
- **BatchesResource**（`/batches`）：就像酒店的宴会厅预订 — 提前预约一场大型活动（提交批处理作业），可以查看进度、取消预订

---

## 3.2 架构版（费曼 L2）

### 3.2.1 SessionsResource — 会话管理 REST API

**包路径**：`org.apache.kyuubi.server.api.v1.SessionsResource`
**注解**：`@Path("/sessions")`

| HTTP | 路径 | 方法 | 说明 |
|------|------|------|------|
| GET | `/sessions` | `sessions()` | 所有活跃会话列表 |
| POST | `/sessions` | `openSession(req)` | 创建新会话 |
| GET | `/sessions/{handle}` | `sessionInfo(handle)` | 会话详情 |
| DELETE | `/sessions/{handle}` | `closeSession(handle)` | 关闭会话 |
| GET | `/sessions/count` | `sessionCount()` | 会话统计 |
| GET | `/sessions/execPool/statistic` | `execPoolStatistic()` | 线程池统计 |
| POST | `/sessions/{handle}/operations/statement` | `executeStatement(handle, req)` | 执行 SQL |
| POST | `/sessions/{handle}/operations/{typeInfo,catalogs,schemas,...}` | 各元数据方法 | 元数据查询 |

**openSession 流程**：
```
1. 解析用户身份: fe.getSessionUser(request)
2. 获取客户端 IP: request.getRemoteAddr
3. 注入元数据配置: CLIENT_IP_KEY, SERVER_IP_KEY, connectionUrl
4. 调用: be.openSession(protocol, user, password, ip, configs)
5. 返回: SessionHandle UUID
```

### 3.2.2 BatchesResource — 批处理 REST API

**包路径**：`org.apache.kyuubi.server.api.v1.BatchesResource`
**注解**：`@Path("/batches")`

| HTTP | 路径 | 方法 | 说明 |
|------|------|------|------|
| POST | `/batches` | `openBatchSession(req)` | 提交批处理 |
| POST | `/batches` (multipart) | `openBatchSessionWithUpload(req)` | 提交 + 上传 JAR |
| GET | `/batches/{batchId}` | `batchInfo(batchId)` | 查询批处理详情 |
| GET | `/batches` | `getBatchInfoList(...)` | 分页查询批处理 |
| GET | `/batches/{batchId}/localLog` | `getBatchLocalLog(...)` | 获取本地日志 |
| DELETE | `/batches/{batchId}` | `closeBatchSession(batchId)` | 取消/关闭 |
| POST | `/batches/reassign` | `reassignBatchSessions(req)` | 重新分配（管理员） |

**跨实例请求转发**：
```
GET /batches/{batchId}:
  1. 在活跃 Session 中查找 → 找到返回
  2. 在 MetadataStore 中查找 → 找到检查:
     if (目标实例 != 当前实例 && 作业未终止):
       通过 InternalRestClient 转发到目标实例
     else:
       本地构建 Batch 对象返回
```

---

## 3.3 对抗性分析

### 3.3.1 REST API 的认证绕过风险

**场景**：REST API 默认没有独立认证机制，依赖前端的 SASL/Kerberos 认证。如果只开启 REST 前端但未配置认证：

```
curl -X POST http://kyuubi:10099/api/v1/sessions \
  -d '{"user":"admin","password":"","configs":{}}'
```

**风险**：任何人可以冒充任何用户创建会话。

**缓解**：生产环境必须配置 `kyuubi.authentication`（至少 LDAP/Kerberos）。REST 前端同样走认证链。

### 3.3.2 fetchResults 的 DoS 风险

```
GET /operations/{handle}/results?maxRows=999999999
```

**防护**：`AbstractBackendService.fetchResults()` 中有校验：
```scala
if (maxRows > maxRowsLimit) throw IllegalArgumentException(...)
```

`maxRowsLimit` 由 `SERVER_LIMIT_CLIENT_FETCH_MAX_ROWS` 配置控制。

### 3.3.3 跨实例转发的一致性问题

```
场景：
  1. Client → Server A: POST /batches  → 创建批处理，元数据写入 MetadataStore
  2. Client → Server B: GET /batches/{id}  → Server B 查 MetadataStore
  3. 如果 MetadataStore 有复制延迟 → Server B 查不到
```

**分析**：Kyuubi 使用 JDBC MetadataStore（如 MySQL），有强一致性保证。但如果用了 MySQL 读写分离，可能出现延迟。

---

# 附录：核心源码文件速查

| 文件 | 包路径 | 职责 |
|------|--------|------|
| `Service.scala` | `service/` | 顶层生命周期接口 |
| `AbstractService.scala` | `service/` | 状态机骨架 |
| `CompositeService.scala` | `service/` | 组合模式，级联管理 |
| `Serverable.scala` | `service/` | Server/Engine 统一抽象 |
| `BackendService.scala` | `service/` | 后端操作接口 |
| `AbstractBackendService.scala` | `service/` | 后端委托实现 |
| `FrontendService.scala` | `service/` | 前端接入接口 |
| `AbstractFrontendService.scala` | `service/` | 前端抽象基类 |
| `KyuubiServer.scala` | `server/` | Server 主入口 |
| `KyuubiBackendService.scala` | `server/` | Server 后端 |
| `SessionsResource.scala` | `server/api/v1/` | REST 会话端点 |
| `BatchesResource.scala` | `server/api/v1/` | REST 批处理端点 |

---

> 本文档遵循"源码精通方法论"L4 标准，覆盖费曼三层输出 + 对抗性分析 + 考古追溯 + 逆向工程思维 + 知识晶体化模板。
> 源码版本：Apache Kyuubi master 分支 (2026-04, commit ba854d3c)
