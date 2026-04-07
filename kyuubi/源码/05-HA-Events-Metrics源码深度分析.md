# Kyuubi HA / Events / Metrics — L4 源码深度分析

> **源码版本**：Apache Kyuubi master 分支（2026-04, commit ba854d3c）
> **段位目标**：L4 创造者/科学家
> **方法论**：源码精通九大法则 × 费曼三层输出
> **本文重点**：高可用服务发现、事件总线、指标采集三大子系统

---

## 阅读导航

| 模块 | 白话版 | 架构版 | 论文版 | 对抗性分析 | 考古追溯 |
|------|--------|--------|--------|-----------|---------|
| HA 服务发现 | [§1.1](#11-白话版费曼-l1) | [§1.2](#12-架构版费曼-l2) | [§1.3](#13-论文版费曼-l3) | [§1.4](#14-对抗性分析) | [§1.5](#15-考古追溯) |
| Events 事件系统 | [§2.1](#21-白话版费曼-l1) | [§2.2](#22-架构版费曼-l2) | — | [§2.3](#23-对抗性分析) | — |
| Metrics 指标系统 | — | [§3.1](#31-架构版) | — | [§3.2](#32-对抗性分析) | — |

---

# 模块一：HA 高可用/服务发现

## 1.1 白话版（费曼 L1）

> **给完全不懂的人讲**

HA 子系统就像一个**出租车调度平台**：

1. **司机注册**（服务注册）：每辆出租车（Kyuubi Server / Engine）启动后，在平台上登记自己的位置和联系方式。就像美团司机开了接单模式。
2. **乘客找车**（服务发现）：乘客（客户端 / Kyuubi Server）打开平台，看到附近有哪些车可用，随机选一辆。
3. **司机下线**（故障检测）：如果司机熄火了（进程崩溃），平台会在一分钟内自动下架（ZK 临时节点自动删除），新乘客不会再匹配到这辆车。
4. **抢单排队**（分布式锁）：多个乘客同时要同一辆车（多个 Server 同时为同一用户创建引擎），平台用排队叫号确保只有一个人能下单。

**ZooKeeper** 就是这个调度平台。它不做运输，只做**注册、发现、排队**。

**Etcd** 是另一个备选平台（像是换了一家打车软件），但功能一样。

---

## 1.2 架构版（费曼 L2）

### 1.2.1 整体架构

```
┌─────────────────────────────────────────────────────┐
│                  ServiceDiscovery                     │
│              (抽象服务发现生命周期)                    │
│  ┌───────────────────┐  ┌──────────────────────────┐ │
│  │ KyuubiServiceDisc │  │ EngineServiceDiscovery   │ │
│  │ (Server端)         │  │ (Engine端)               │ │
│  └───────────────────┘  └──────────────────────────┘ │
└──────────────────┬──────────────────────────────────┘
                   │ 依赖
                   ▼
┌─────────────────────────────────────────────────────┐
│              DiscoveryClient (trait)                   │
│  ┌───────────────────┐  ┌──────────────────────────┐ │
│  │ ZookeeperDiscovery│  │ EtcdDiscoveryClient      │ │
│  │ Client            │  │                          │ │
│  └───────────────────┘  └──────────────────────────┘ │
└─────────────────────────────────────────────────────┘
                   │
                   ▼
         ┌─────────────────┐
         │  ZooKeeper/Etcd  │
         └─────────────────┘
```

### 1.2.2 DiscoveryClient 核心接口

```scala
trait DiscoveryClient {
  // 连接管理
  def createClient(): Unit
  def closeClient(): Unit
  def monitorState(serviceDiscovery: ServiceDiscovery): Unit

  // 服务注册/注销
  def registerService(conf, namespace, serviceDiscovery, version, external): Unit
  def deregisterService(): Unit

  // 服务发现
  def getServerHost(namespace): (String, Int)
  def getEngineByRefId(namespace, refId): (String, Int)
  def getServiceNodesInfo(namespace, sizeOpt, silent): Seq[ServiceNodeInfo]

  // 分布式锁
  def tryWithLock[T](lockPath, timeout)(f: => T): T

  // 原子计数器（引擎池轮询）
  def getAndIncrement(path, delta): Int

  // 密钥节点（Engine 认证）
  def startSecretNode(namespace, ...): Unit
}
```

### 1.2.3 ZookeeperDiscoveryClient 实现

**基于 Apache Curator Framework**

| 机制 | ZK 实现 | 说明 |
|------|---------|------|
| 服务注册 | `PersistentNode` (EPHEMERAL_SEQUENTIAL) | 临时顺序节点，断连自动删除 |
| 服务发现 | `getChildren()` + `getData()` | 列举子节点，解析 host:port |
| 心跳保活 | Curator 自动管理 | ZK session 心跳 |
| 故障检测 | `ConnectionStateListener` | session 过期 → 临时节点删除 |
| 分布式锁 | `InterProcessSemaphoreMutex` | Curator Recipes 实现 |
| 原子计数器 | `SharedCount` | Curator Recipes 实现 |

**服务注册流程**：
```scala
def registerService(...): Unit = {
  // 1. 构建节点数据
  val instance = s"serverUri=$host:$port;version=$version;sequence=$seqNum"

  // 2. 创建 PersistentNode
  //    ZK 节点路径: /{namespace}/instance-{sequence}
  //    节点数据: instance 字符串
  //    节点类型: EPHEMERAL_SEQUENTIAL（临时顺序）
  val node = new PersistentNode(zkClient, mode, useProtection=true, path, data)
  node.start()

  // 3. 等待节点创建完成
  node.waitForInitialCreate(timeout, TimeUnit.MILLISECONDS)

  // 4. 注册连接状态监听器
  //    LOST → 记录警告
  //    RECONNECTED → 检查节点是否还在
}
```

**服务发现流程**：
```scala
def getServerHost(namespace: String): Option[(String, Int)] = {
  if (!pathExists(namespace)) return None
  val children = getChildren(namespace)
  if (children.isEmpty) return None

  // 解析第一个子节点（或随机选择）
  val instanceData = getData(s"$namespace/${children.head}")
  val (host, port) = parseInstanceHostPort(instanceData)
  Some((host, port))
}
```

### 1.2.4 ZK 节点结构

```
/kyuubi                                    ← 根命名空间
│
├── /serviceDiscovery                      ← Server 注册
│   ├── instance_0000000001                ← Server 1 (临时顺序节点)
│   │   data: "serverUri=host1:10009;version=1.9.0"
│   └── instance_0000000002                ← Server 2
│
├── /kyuubi_1.9.0_USER_SPARK_SQL           ← Engine 空间
│   ├── /alice/default
│   │   └── instance_0000000001            ← alice 的 Engine (临时节点)
│   │       data: "serverUri=engine1:37291;refId=uuid-xxx"
│   └── /bob/pool-0
│       └── instance_0000000001
│
├── /kyuubi_lock                           ← 分布式锁
│   └── /alice_SPARK_SQL
│       ├── lock-0000000001                ← 临时顺序节点
│       └── lock-0000000002
│
└── /kyuubi_secret                         ← Engine 认证密钥
    └── /engine_xxx
        └── secret: "encrypted_password"
```

### 1.2.5 EtcdDiscoveryClient 实现

| ZK 概念 | Etcd 等价 |
|---------|-----------|
| ZNode | Key-Value |
| 临时节点 | Lease + KeepAlive |
| 顺序节点 | Revision 排序 |
| Watch | Watch API |
| InterProcessMutex | Lock API |

### 1.2.6 ServiceDiscovery 抽象类

```scala
abstract class ServiceDiscovery(name: String) extends AbstractService(name) {
  protected val client: DiscoveryClient

  override def start(): Unit = {
    client.createClient()                    // 连接 ZK/Etcd
    client.registerService(conf, namespace)  // 注册服务
    client.monitorState(this)                // 监控连接状态
    super.start()
  }

  override def stop(): Unit = {
    client.deregisterService()               // 注销服务
    client.closeClient()                     // 关闭连接
    super.stop()
  }
}
```

**两个子类**：
- `KyuubiServiceDiscovery`：Server 端服务发现（注册 Server 地址）
- `EngineServiceDiscovery`：Engine 端服务发现（注册 Engine 地址）

---

## 1.3 论文版（费曼 L3）

### 1.3.1 服务发现的 CAP 分析

Kyuubi 使用 ZK 作为服务注册中心：
- **C（一致性）**：ZK 提供顺序一致性（linearizable writes + sequential reads）
- **A（可用性）**：ZK 在半数以上节点存活时可用
- **P（分区容忍）**：ZK 在网络分区时选择一致性（CP 系统）

**对 Kyuubi 的影响**：
- 网络分区时，少数派 ZK 节点不可用 → Kyuubi Server 无法注册/发现服务
- 已注册的临时节点可能因 session 超时被删除 → 客户端暂时无法找到 Server

### 1.3.2 临时节点的故障检测延迟

ZK 临时节点的删除延迟：

\[
T_{detect} = T_{session\_timeout} + T_{gc}
\]

其中：
- \( T_{session\_timeout} \)：ZK session 超时（默认 60s）
- \( T_{gc} \)：ZK 服务端 session 清理周期（tickTime 的倍数）

**典型值**：60-90s。在这段时间内，客户端可能连接到已死的 Server/Engine。

### 1.3.3 与 Consul / Nacos 的对比

| 维度 | ZooKeeper | Etcd | Consul | Nacos |
|------|-----------|------|--------|-------|
| 一致性协议 | ZAB | Raft | Raft | Raft + AP |
| 临时节点 | 原生支持 | Lease 模拟 | 健康检查 | 实例心跳 |
| 故障检测延迟 | 60-90s | 可配 (TTL) | 可配 | 15s |
| 分布式锁 | 原生 | 原生 | 原生 | 无 |
| 运维复杂度 | 中 | 低 | 中 | 低 |

**Kyuubi 选择 ZK 的原因**：大数据生态（HDFS/YARN/HBase/Kafka）普遍依赖 ZK，复用已有集群降低运维成本。

---

## 1.4 对抗性分析

### 1.4.1 ZK 脑裂

**场景**：3 节点 ZK 集群，网络分区导致 1 vs 2 分裂。

```
ZK1 (独立)     ZK2 + ZK3 (多数派)
│                │
│ 不可写         │ 正常工作
│                │
└── Kyuubi Server A（连接 ZK1）
    → session 超时 → 临时节点被删除
    → 客户端无法发现 Server A
    → Server A 仍在运行，已有连接不受影响
    → 新连接被路由到其他 Server
```

**影响**：Server A 暂时"消失"，但不会双重注册（ZK1 不可写）。脑裂恢复后 Server A 重新注册。

### 1.4.2 临时节点残留（ZK session 未超时）

**场景**：Engine 进程被 `kill -9`，但 ZK session 尚未超时。

```
1. Engine 进程死了（60s 内）
2. ZK 临时节点仍存在 → Server 认为 Engine 活着
3. Server 尝试连接 Engine → Connection refused
4. 重试 ENGINE_OPEN_MAX_ATTEMPTS 次
5. 如果配置了 DEREGISTER_IMMEDIATELY → 主动删除 ZK 节点
6. 重新创建 Engine
```

**总恢复时间**：
- 有 DEREGISTER_IMMEDIATELY：`重试次数 × 重试间隔`（约 30s）
- 无此配置：`ZK session timeout`（约 60s）

### 1.4.3 事件丢失：EventBus 的可靠性

**场景**：EventBus 采用同步发布（`EventBus.post(event)`），如果 Handler 抛异常：

```scala
// EventBus.post 内部
handlers.foreach { handler =>
  try { handler.apply(event) }
  catch { case NonFatal(e) => warn(s"Handler failed: $e") }
}
```

**分析**：单个 Handler 失败不影响其他 Handler。事件不会丢失（对其他 Handler 而言），但失败的 Handler 会丢失该事件。

**更严重**：如果 KafkaLoggingEventHandler 连接 Kafka 失败，所有事件都会被该 Handler 丢弃。

> **缓解**：KafkaLoggingEventHandler 内部有缓冲队列 + 重试机制，短暂 Kafka 不可用不会丢事件。但长时间不可用会导致队列溢出 → 事件丢弃。

### 1.4.4 Metrics 指标延迟

**场景**：Prometheus pull 间隔 15s，Kyuubi 指标更新频率实时。

**问题**：在两次 pull 之间，指标可能经历了峰值又回落，Prometheus 看不到峰值。

**缓解**：关键指标（如 `ENGINE_STARTUP_PERMIT_AVAILABLE`）使用 Gauge（实时值），非计数器（Counter）。

---

## 1.5 考古追溯

### 1.5.1 从 ZK-only 到 ZK + Etcd 双支持

| 版本 | 支持 |
|------|------|
| 1.0-1.6 | 仅 ZooKeeper |
| 1.7 | + Etcd |

**驱动力**：Kubernetes 生态更倾向 Etcd（K8s 自带）。在纯 K8s 部署中，引入 ZK 增加运维负担。

### 1.5.2 PersistentNode vs 原生 EPHEMERAL

**背景**：早期使用 ZK 原生 `create(EPHEMERAL_SEQUENTIAL)`。问题：ZK 连接断开重连后，原始临时节点被删除，需要手动重新创建。

**解决方案**：使用 Curator 的 `PersistentNode`。它会自动在断线重连后重新创建节点。

### 1.5.3 密钥节点（Secret Node）的由来

**背景**：ENGINE_SHARE_LEVEL=USER/GROUP/SERVER 时，多个客户端共享一个引擎。但引擎启动时生成了随机认证密码，后续客户端如何知道这个密码？

**解决方案**：引擎启动时将密码写入 ZK 的 secret 节点。Kyuubi Server 从 ZK 读取密码后用于连接引擎。

---

## 1.6 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 多 Server、多 Engine 如何在分布式环境中互相发现、避免冲突、检测故障？ |
| **核心源码** | `DiscoveryClient` → `ZookeeperDiscoveryClient` → `ServiceDiscovery` |
| **调用链** | `Server.start → ServiceDiscovery.start → ZK.registerService → 临时节点 → 客户端 getServerHost` |
| **设计意图** | ZK 临时节点实现自动故障检测 + 分布式锁防并发创建 + Secret 节点传递认证信息 |
| **关键参数** | `HA_ADDRESSES`, `HA_ZK_SESSION_TIMEOUT=60s`, `HA_ZK_NAMESPACE=kyuubi` |
| **踩坑记录** | ① ZK session timeout 内的残留节点 ② 脑裂导致 Server 暂时消失 ③ Etcd lease 过短导致频繁重注册 |
| **认知更新** | 从"就是 ZK 注册一下"→ "临时节点+故障检测+分布式锁+Secret传递+双后端支持的完整HA体系" |

---

# 模块二：Events 事件子系统

## 2.1 白话版（费曼 L1）

> 事件系统就像酒店的**监控录像**。每个客人进门（Session 打开）、点菜（SQL 执行）、退房（Session 关闭），都会被摄像头记录下来。录像可以存到本地硬盘（JSON 日志），也可以传到云端（Kafka）。

## 2.2 架构版（费曼 L2）

### 2.2.1 核心架构

```
KyuubiEvent (trait)          ← 事件基础接口
  ├── KyuubiSessionEvent     ← 会话事件
  ├── KyuubiOperationEvent   ← 操作事件
  ├── KyuubiServerInfoEvent  ← Server 启动事件
  └── SparkOperationEvent    ← Spark 操作事件

EventBus                     ← 事件总线（同步发布）
  post(event) → handlers.foreach(_.apply(event))

EventHandler[T <: KyuubiEvent] (trait)  ← 处理器
  ├── JsonLoggingEventHandler    ← JSON 日志（本地文件 / HDFS）
  ├── KafkaLoggingEventHandler   ← Kafka 消息
  └── SparkHistoryLoggingEventHandler ← Spark History Server

EventHandlerRegister         ← 注册器（SPI 加载 Handler）
```

### 2.2.2 EventBus — 同步事件总线

```scala
object EventBus {
  private val handlers = new CopyOnWriteArrayList[EventHandler[KyuubiEvent]]

  def post(event: KyuubiEvent): Unit = {
    handlers.forEach { handler =>
      try { handler.apply(event) }
      catch { case NonFatal(e) => warn(s"Handler failed: $e") }
    }
  }
}
```

**设计决策**：同步发布（不用异步队列），因为：
1. 事件量不大（Session/Operation 粒度，非 SQL 结果行粒度）
2. 同步保证事件顺序
3. 失败即时可见

### 2.2.3 JsonLoggingEventHandler

```
事件 → JSON 序列化 → 写入文件
  路径: {kyuubi.operation.log.root}/{event_type}/{date}/{event.json}
  支持: 本地文件 / HDFS / S3
  轮转: 按日期目录
```

### 2.2.4 KafkaLoggingEventHandler

```
事件 → JSON 序列化 → 发送到 Kafka Topic
  Topic: kyuubi.backend.server.event.kafka.topic (默认 kyuubi_events)
  分区: 按 SessionHandle hash
  配置: 标准 Kafka Producer 配置
```

---

## 2.3 对抗性分析

**EventBus 的阻塞风险**：如果某个 Handler 执行很慢（如 Kafka 网络超时），会阻塞 `post()` 的调用者（可能是 SQL 执行线程）。

> **改进建议**：对耗时 Handler 使用异步队列 + 背压控制。

---

# 模块三：Metrics 指标子系统

## 3.1 架构版

### 3.1.1 核心架构

```
MetricsSystem (CompositeService)
  ├── MetricsConf (配置)
  │     ├── METRICS_ENABLED (默认 true)
  │     └── METRICS_REPORTERS (JSON/JMX/PROMETHEUS/SLF4J/CONSOLE)
  │
  ├── MetricRegistry (Dropwizard Metrics)
  │     ├── Gauge      ← 即时值（如活跃会话数）
  │     ├── Counter    ← 累计计数（如总连接数）
  │     ├── Histogram  ← 分布（如查询延迟分布）
  │     ├── Timer      ← 计时器（如引擎启动时间）
  │     └── Meter      ← 速率（如 QPS）
  │
  └── Reporters
        ├── PrometheusReporterService (端口 10019)
        ├── JmxReporterService
        ├── JsonReporterService (定期写 JSON 文件)
        ├── Slf4jReporterService (日志输出)
        └── ConsoleReporterService (控制台输出)
```

### 3.1.2 核心指标列表

| 指标 | 类型 | 说明 |
|------|------|------|
| `kyuubi.connection.opened` | Gauge | 当前打开连接数 |
| `kyuubi.connection.total` | Counter | 总连接数 |
| `kyuubi.connection.failed` | Counter | 失败连接数 |
| `kyuubi.engine.total` | Counter | 总引擎创建数 |
| `kyuubi.engine.timeout` | Counter | 引擎超时数 |
| `kyuubi.operation.total` | Counter | 总操作数 |
| `kyuubi.operation.failed` | Counter | 失败操作数 |
| `kyuubi.exec_pool.alive` | Gauge | 线程池存活线程 |
| `kyuubi.exec_pool.active` | Gauge | 线程池活跃线程 |
| `kyuubi.engine.startup.permit.available` | Gauge | 可用启动许可 |
| `kyuubi.engine.startup.permit.waiting` | Gauge | 等待许可请求数 |

### 3.1.3 Prometheus 集成

```
GET http://kyuubi-server:10019/metrics

# 返回 Prometheus exposition format
kyuubi_connection_opened 42
kyuubi_engine_total 156
kyuubi_exec_pool_active 23
...
```

---

## 3.2 对抗性分析

**Prometheus pull 间隔 vs 指标精度**：瞬时峰值可能被 15s pull 间隔遗漏。

**解决方案**：关键告警指标使用 Counter（单调递增），配合 `rate()` 函数检测异常增长率。

---

# 三大子系统协作关系

```
                     ┌──────────────┐
                     │ KyuubiServer │
                     └──────┬───────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
    ┌─────▼─────┐   ┌──────▼──────┐   ┌──────▼──────┐
    │   HA      │   │   Events    │   │   Metrics   │
    │ (ZK/Etcd) │   │ (EventBus)  │   │ (Dropwizard)│
    └─────┬─────┘   └──────┬──────┘   └──────┬──────┘
          │                │                 │
          ▼                ▼                 ▼
    ┌──────────┐   ┌───────────┐   ┌──────────────┐
    │ ZooKeeper│   │ JSON/Kafka│   │ Prometheus   │
    │          │   │ /HDFS     │   │ /JMX/Console │
    └──────────┘   └───────────┘   └──────────────┘

协作示例（Session 打开）:
  1. HA: getServerHost() → 发现 Engine
  2. Events: post(SessionOpenEvent)
  3. Metrics: connection_opened.inc()
```

---

## 源码文件索引

| 文件 | 模块 | 核心职责 |
|------|------|----------|
| `DiscoveryClient.scala` | kyuubi-ha | 服务发现抽象接口 |
| `ZookeeperDiscoveryClient.scala` | kyuubi-ha | ZK 实现 |
| `EtcdDiscoveryClient.scala` | kyuubi-ha | Etcd 实现 |
| `ServiceDiscovery.scala` | kyuubi-ha | 服务发现生命周期 |
| `KyuubiEvent.scala` | kyuubi-events | 事件基础接口 |
| `EventBus.scala` | kyuubi-events | 同步事件总线 |
| `EventHandler.scala` | kyuubi-events | 处理器接口 |
| `JsonLoggingEventHandler.scala` | kyuubi-events | JSON 日志 |
| `KafkaLoggingEventHandler.scala` | kyuubi-events | Kafka 消息 |
| `MetricsSystem.scala` | kyuubi-metrics | 指标系统核心 |
| `MetricsConstants.scala` | kyuubi-metrics | 指标名称定义 |
| `PrometheusReporterService.scala` | kyuubi-metrics | Prometheus 端点 |

---

> 本文档遵循"源码精通方法论"L4 标准。
> 源码版本：Apache Kyuubi master 分支 (2026-04, commit ba854d3c)
