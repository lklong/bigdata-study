# Apache Kyuubi — 源码级深度知识手册（L4 创造者/科学家级）

> **最后更新**：2026-04-05 | **作者**：Eric（BigData Ops Orchestrator）
> **源码版本**：master 分支 (ba854d3c, 2026-04)
> **段位目标**：L4 创造者/科学家 — 能写 SPIP、能提 PR、能做架构级 Review
> **方法论**：源码精通九大法则 × 费曼三层输出

---

## L4 文档体系索引

> 所有文档均按"费曼三层（白话→架构→论文）+ 对抗性分析 + 考古追溯 + 知识晶体化"标准编写。

### 源码深度分析系列

| 序号 | 文档 | 核心模块 | L4 特色 |
|------|------|---------|---------|
| 01 | [Service 抽象层与 KyuubiServer 启动链路](01-Service抽象层与KyuubiServer启动链路.md) | Service 状态机、CompositeService、Serverable、启动/停机链路 | 状态机形式化证明、启动回滚正确性、与 Spring/OSGi 对比 |
| 02 | [Session 管理与 EngineRef 引擎管理](02-Session管理与EngineRef引擎管理源码深度分析.md) | SessionManager、限流、EngineRef.getOrCreate、分布式锁、引擎池 | 调度模型形式化、引擎启动延迟模型、POLLING 溢出 Bug 考古 |
| 02 | [SparkSQLEngine 与 Operation 管理](02-SparkSQLEngine与Operation管理源码深度分析.md) | SparkSQLEngine、ExecuteStatement、结果集三种模式、WatchDog | Session 隔离内存模型、SQL 延迟分析、OOM 对抗性分析 |
| 05 | [HA / Events / Metrics](05-HA-Events-Metrics源码深度分析.md) | ZK 服务发现、EventBus、Prometheus 指标 | CAP 分析、ZK 脑裂对抗、EventBus 阻塞风险 |
| — | **本文（总纲）** | 全模块端到端串联 | 21 章完整请求生命周期 |

### 运维与实战系列

| 文档 | 内容 | L4 特色 |
|------|------|---------|
| [异常场景 + 配置参数 + Bug 考古](../异常场景-配置参数-Bug考古.md) | 10+ 异常场景的源码级根因分析 | Top 5 危险配置 + Top 5 隐蔽 Bug + JIRA 考古 |

### 待补写（P1-P4）

| 文档 | 状态 | 说明 |
|------|------|------|
| 03-REST-API 与 JDBC 协议层 | 计划中 | REST Frontend / Thrift HTTP / MySQL Protocol |
| 04-认证鉴权体系 | 计划中 | SASL/GSSAPI/Kerberos/LDAP + Ranger 授权 |
| 06-性能建模与容量规划 | 计划中 | Amdahl 建模 + 引擎启动延迟公式 + 容量计算 |
| 07-跨项目同构对比 | 计划中 | Kyuubi vs HS2 vs Flink SQL Gateway vs Trino Gateway |
| 案例/Bug 复现 | 计划中 | 3 个高价值 JIRA 的源码级复现 |
| 案例/PR Review | 计划中 | 3 个社区 PR 的深度 Review |
| 案例/SPIP 设计方案 | 计划中 | 引擎池动态扩缩容设计方案 |

---

## 第一章 总览：Kyuubi 是什么

Apache Kyuubi 是一个**分布式多租户 SQL 网关**，在 Spark/Flink/Trino/Hive 之上提供 Serverless SQL 能力。核心价值：**让不懂 Spark 的人也能用 SQL 操作大数据，且资源自动隔离、自动管理**。

**一句话架构**：`Client ──Thrift/REST──→ Kyuubi Server (无状态网关) ──Thrift RPC──→ 独立 Engine 进程 (Spark/Flink) ──→ 数据层`

---

## 第二章 源码模块全景

```
apache/kyuubi/                          # 根项目
├── kyuubi-common/                      # ★ 公共基础层
│   ├── config/KyuubiConf.scala         #   配置定义中心（所有配置项在此注册）
│   ├── server/Serverable.scala         #   Server/Engine 公共抽象（定义 Frontend+Backend 组合模式）
│   ├── service/CompositeService.scala  #   组合服务模式（管理子服务生命周期）
│   ├── session/SessionManager.scala    #   会话管理器抽象
│   ├── operation/OperationManager.scala#   操作管理器抽象
│   ├── engine/ShareLevel.scala         #   引擎共享级别枚举（CONNECTION/USER/GROUP/SERVER）
│   └── ha/client/DiscoveryClient.scala #   服务发现客户端抽象（ZK/Etcd 接口）
│
├── kyuubi-server/                      # ★ Kyuubi Server 核心
│   ├── server/KyuubiServer.scala       #   Server 主入口（main 方法）
│   ├── server/KyuubiBackendService.scala#  后端服务（持有 SessionManager）
│   ├── session/
│   │   ├── KyuubiSessionManager.scala  #   ★ 会话管理器（引擎分配调度中心）
│   │   └── KyuubiSessionImpl.scala     #   ★ 交互式会话实现（引擎连接+SQL路由）
│   ├── engine/
│   │   ├── EngineRef.scala             #   ★★★ 引擎引用（getOrCreate 核心算法）
│   │   └── spark/SparkProcessBuilder.scala # spark-submit 命令构建器
│   └── api/v1/SessionsResource.scala   #   REST API 端点
│
├── kyuubi-ha/                          # ★ 高可用模块
│   └── ha/client/
│       ├── DiscoveryClient.scala       #   发现客户端接口
│       └── zookeeper/ZookeeperDiscoveryClient.scala # ZK 实现
│
├── externals/
│   └── kyuubi-spark-sql-engine/        # ★ Spark SQL 引擎
│       ├── engine/spark/SparkSQLEngine.scala      # 引擎主入口
│       ├── engine/spark/session/
│       │   ├── SparkSQLSessionManager.scala       # 引擎端会话管理
│       │   └── SparkSessionImpl.scala             # 引擎端会话实现
│       └── engine/spark/operation/
│           ├── ExecuteStatement.scala             # ★ SQL 执行核心
│           └── SparkOperation.scala               # 操作基类
│
├── extensions/spark/                   # Spark SQL 扩展
│   └── KyuubiSparkSQLExtension.scala   # AQE增强/Z-Ordering/小文件合并/SQL血缘
│
└── kyuubi-metrics/                     # 指标模块
```

---

## 第三章 Service 抽象层设计（源码级）

### 3.1 核心继承体系

Kyuubi 的所有服务（Server 和 Engine）共享同一套抽象体系，这是理解整个系统的基础：

```scala
// 最底层：Service 接口
trait Service {
  def getName: String
  def getServiceState: ServiceState
  def init(conf: KyuubiConf): Unit
  def start(): Unit
  def stop(): Unit
}

// 组合服务：管理多个子服务的生命周期
abstract class CompositeService(name: String) extends Service {
  private val serviceList = new java.util.ArrayList[Service]()
  
  def addService(service: Service): Unit = serviceList.add(service)
  
  // init/start/stop 时依次遍历所有子服务
  override def init(conf: KyuubiConf): Unit = {
    serviceList.forEach(_.init(conf))
    super.init(conf)
  }
  override def start(): Unit = {
    serviceList.forEach(_.start())
    super.start()
  }
  override def stop(): Unit = {
    // 注意：stop 是逆序的，后添加的先停
    serviceList.asScala.reverse.foreach(_.stop())
    super.stop()
  }
}

// 可服务的抽象：定义了 Frontend + Backend 的组合模式
// ★ 这是 KyuubiServer 和 SparkSQLEngine 共享的父类
trait Serverable extends CompositeService {
  // 后端服务（持有 SessionManager）
  def backendService: AbstractBackendService
  
  // 前端服务列表（支持多协议）
  private val frontendServices = new java.util.ArrayList[FrontendService]()
  
  override def initialize(conf: KyuubiConf): Unit = {
    // 1. 初始化后端服务
    addService(backendService)
    // 2. 根据配置初始化前端服务
    conf.get(FRONTEND_PROTOCOLS).foreach { protocol =>
      val frontend = protocol match {
        case THRIFT_BINARY => new KyuubiTBinaryFrontendService(this)
        case THRIFT_HTTP   => new KyuubiTHttpFrontendService(this)
        case REST          => new KyuubiRestFrontendService(this)
        case MYSQL         => new KyuubiMySQLFrontendService(this)
        case TRINO         => new KyuubiTrinoFrontendService(this)
      }
      addService(frontend)
      frontendServices.add(frontend)
    }
    super.initialize(conf)
  }
}
```

**设计精髓**：Server 和 Engine 共用同一个 `Serverable` 抽象，区别仅在于：
- **KyuubiServer**：Backend = `KyuubiBackendService(KyuubiSessionManager)`
- **SparkSQLEngine**：Backend = `SparkSQLBackendService(SparkSQLSessionManager)`

这使得 Server 和 Engine 在协议处理、服务生命周期管理上完全一致。

---

## 第四章 KyuubiServer 启动链路（源码级）

### 4.1 main 方法启动流程

```scala
// KyuubiServer.scala - 伴生对象
object KyuubiServer {
  def main(args: Array[String]): Unit = {
    // Step 1: 打印版本信息
    info(s"Starting Kyuubi $KYUUBI_VERSION")
    // 输出：Java/Scala/Spark/Hadoop/Hive/Flink/Trino 编译版本
    
    // Step 2: 注册 JDBC 元数据存储配置
    JDBCMetadataStoreConf.registerCustomConfigs()
    
    // Step 3: 创建 KyuubiConf，加载配置
    val conf = new KyuubiConf().loadFileDefaults()
    // 加载顺序：$KYUUBI_HOME/conf/kyuubi-defaults.conf → 系统属性 → 命令行参数
    
    // Step 4: 设置 Hadoop 安全认证
    UserGroupInformation.setConfiguration(conf.getHadoopConf)
    
    // Step 5: 启动服务器
    startServer(conf)
  }
  
  private def startServer(conf: KyuubiConf): KyuubiServer = {
    val server = new KyuubiServer()
    server.initialize(conf)  // ← 初始化所有服务
    server.start()           // ← 启动所有服务
    server
  }
}
```

### 4.2 initialize 方法详解

```scala
// KyuubiServer.scala - 类方法
class KyuubiServer extends Serverable("KyuubiServer") {
  
  // 后端服务：持有 KyuubiSessionManager
  override val backendService = new KyuubiBackendService()
  
  override def initialize(conf: KyuubiConf): Unit = {
    // 1. 添加 Kerberos Kinit 辅助服务
    //    如果配置了 Kerberos，会定期执行 kinit 刷新票据
    addService(new KinitAuxiliaryService())
    
    // 2. 添加周期性 GC 服务
    //    定期执行 System.gc() 回收内存
    addService(new PeriodicGCService())
    
    // 3. 添加指标系统（Prometheus/JSON/JMX）
    if (conf.get(MetricsConf.METRICS_ENABLED)) {
      addService(MetricsSystem.createMetricsSystem())
    }
    
    // 4. 调用父类 Serverable.initialize
    //    → 初始化 BackendService(KyuubiSessionManager)
    //    → 根据 FRONTEND_PROTOCOLS 配置初始化前端服务
    super.initialize(conf)
    
    // 5. 初始化事件日志处理器
    initLoggerEventHandler(conf)
  }
}
```

**完整启动时序图**：

```
main()
  │
  ├── KyuubiConf.loadFileDefaults()          ← 加载 kyuubi-defaults.conf
  │
  ├── server.initialize(conf)
  │   ├── addService(KinitAuxiliaryService)   ← Kerberos 票据刷新
  │   ├── addService(PeriodicGCService)       ← 定期 GC
  │   ├── addService(MetricsSystem)           ← 指标采集
  │   ├── super.initialize(conf)
  │   │   ├── addService(KyuubiBackendService)
  │   │   │   └── KyuubiSessionManager.init()
  │   │   │       ├── 初始化 DiscoveryClient (ZK 连接)
  │   │   │       ├── 初始化 MetadataManager (元数据持久化)
  │   │   │       ├── 初始化 SessionLimiter (并发会话限制)
  │   │   │       └── 初始化 EngineStartupProcessSemaphore (引擎启动并发控制)
  │   │   │
  │   │   ├── addService(KyuubiTBinaryFrontendService)  ← 默认 Thrift 端口 10009
  │   │   ├── addService(KyuubiRestFrontendService)     ← REST 端口 10099（如配置）
  │   │   └── ... 其他前端服务
  │   │
  │   └── initLoggerEventHandler()            ← 事件总线
  │
  └── server.start()
      ├── KinitAuxiliaryService.start()
      ├── PeriodicGCService.start()
      ├── MetricsSystem.start()
      ├── KyuubiBackendService.start()
      │   └── KyuubiSessionManager.start()
      │       ├── 启动超时检查器线程 (timeoutChecker)
      │       └── 启动引擎连接活性检查器 (engineConnectionAliveChecker)
      ├── KyuubiTBinaryFrontendService.start()
      │   └── 启动 Thrift Server，开始监听 10009 端口
      ├── KyuubiServiceDiscovery.start()
      │   └── 在 ZK 创建临时节点注册自己
      └── 发布 KyuubiServerInfoEvent(STARTED)
```

---

## 第五章 会话管理内核（源码级）

### 5.1 KyuubiSessionManager — 调度指挥中心

```scala
class KyuubiSessionManager extends SessionManager("KyuubiSessionManager") {
  
  // ★ 核心数据结构：活跃会话存储
  // 继承自父类：ConcurrentHashMap<SessionHandle, Session>
  private val handleToSession = new ConcurrentHashMap[SessionHandle, Session]()
  
  // ★ 并发控制：限制引擎同时启动数量
  private var startupProcessSemaphore: Option[Semaphore] = None
  // 配置: kyuubi.engine.startup.maxConcurrent (默认无限制)
  // 作用: 防止瞬间大量引擎启动把 YARN/K8s 打爆
  
  // ★ 会话限制器：防止用户资源滥用
  private var sessionLimiter: Option[SessionLimiter] = None
  // 配置: kyuubi.server.limit.connections.per.user (默认无限制)
  //       kyuubi.server.limit.connections.per.ipaddress
  //       kyuubi.server.limit.connections.per.user.ipaddress
  
  // ★ 超时检查器：定期扫描清理过期会话
  // 运行在独立线程中，按 kyuubi.session.check.interval 间隔执行
  // 对比每个 session 的 lastAccessTime 与 idle.timeout
  
  // 打开会话的核心方法
  def openSession(
      protocol: TProtocolVersion,
      user: String,
      password: String,
      ipAddress: String,
      conf: Map[String, String]): SessionHandle = {
    
    // 1. 会话数量限制检查
    sessionLimiter.foreach(_.increment(UserIpAddress(user, ipAddress)))
    
    // 2. 配置校验：白名单/黑名单过滤
    val normalizedConf = validateAndNormalizeConf(conf)
    
    // 3. 创建 KyuubiSessionImpl
    val session = new KyuubiSessionImpl(
      protocol, user, password, ipAddress, normalizedConf, this)
    
    // 4. 将会话注册到 handleToSession
    setSession(session.handle, session)
    
    // 5. 打开会话（触发引擎创建/连接）
    session.open()  // ← 这里是重头戏，见下文
    
    session.handle
  }
}
```

### 5.2 KyuubiSessionImpl — 交互式会话实现

```scala
class KyuubiSessionImpl(
    protocol: TProtocolVersion,
    user: String,
    password: String,
    ipAddress: String,
    conf: Map[String, String],
    sessionManager: KyuubiSessionManager
) extends KyuubiSession(...) {

  // ★ 引擎引用对象
  private val engine: EngineRef = new EngineRef(conf, user, ...)
  
  // ★ 引擎启动操作（异步执行）
  private val launchEngineOp = new LaunchEngine(this)
  
  // ★ 引擎 Thrift 客户端（连接到引擎端）
  @volatile private var _client: KyuubiSyncThriftClient = _

  /**
   * 打开会话的完整流程
   */
  override def open(): Unit = {
    // Step 1: 指标记录 + 权限检查
    traceMetricsOnOpen()
    checkSessionAccessPathURIs()
    
    // Step 2: 父类基础设置
    super.open()
    
    // Step 3: ★★★ 启动引擎（核心步骤）
    // 根据 SESSION_ENGINE_LAUNCH_ASYNC 决定同步/异步
    runOperation(launchEngineOp)
    // launchEngineOp 内部调用:
    //   engine.getOrCreate(discoveryClient)
    //   → 返回 (engineHost, enginePort)
    
    // Step 4: ★★★ 连接到引擎
    openEngineSession(engineHost, enginePort)
  }

  /**
   * 连接到引擎的详细逻辑
   */
  private def openEngineSession(host: String, port: Int): Unit = {
    var attempts = 0
    val maxAttempts = conf.get(ENGINE_OPEN_MAX_ATTEMPTS)  // 默认 9
    
    while (attempts < maxAttempts) {
      try {
        // 1. 创建 Thrift 客户端
        _client = KyuubiSyncThriftClient.createClient(host, port, ...)
        
        // 2. 在引擎端打开 Session
        //    → 引擎端会创建独立的 SparkSession
        _client.openSession(protocol, user, password, openConf)
        
        return  // 成功
      } catch {
        case e: TTransportException =>
          attempts += 1
          // 重试逻辑：等待后重试，或者注销有问题的引擎节点
          if (conf.get(ENGINE_OPEN_ON_FAILURE) == DEREGISTER_IMMEDIATELY) {
            deregisterEngineNode()
          }
          Thread.sleep(retryInterval)
      }
    }
    throw new KyuubiException("Failed to open engine session after retries")
  }

  /**
   * SQL 执行路由：Server 端 vs Engine 端
   */
  override def executeStatement(
      statement: String,
      confOverlay: Map[String, String],
      runAsync: Boolean,
      queryTimeout: Long): OperationHandle = {
    
    // ★ SQL 解析判断执行位置
    val parsedPlan = parser.parsePlan(statement)
    parsedPlan match {
      case _: RunnableCommand =>
        // SET / USE / ADD JAR 等轻量命令 → Server 端直接执行
        // 不需要转发给引擎，减少网络开销
        new ExecuteOnServerOperation(session, statement).run()
        
      case _ =>
        // 正常 SQL → 转发给引擎执行
        // 通过 _client.executeStatement() Thrift RPC 调用
        super.executeStatement(statement, confOverlay, runAsync, queryTimeout)
    }
  }

  /**
   * 关闭会话
   */
  override def close(): Unit = {
    super.close()
    // 1. 清除凭证缓存
    credentialManager.removeSessionCredentials(handle)
    // 2. 关闭到引擎的连接
    Option(_client).foreach(_.closeSession())
    // 3. 如果有异常，尝试关闭引擎引用
    if (openSessionError.isDefined) engine.close()
    // 4. 发布会话结束事件
    EventBus.post(sessionEvent.copy(state = "CLOSED"))
  }
}
```

---

## 第六章 EngineRef — 引擎分配核心算法（源码级）

这是 Kyuubi 最精华的部分：如何决定引擎的创建与复用。

### 6.1 getOrCreate — 先查找后创建

```scala
class EngineRef(conf: KyuubiConf, user: String, ...) {
  
  // ★ 引擎命名空间：决定了引擎在 ZK 中的路径
  // 这是引擎复用的核心机制
  val engineSpace: String = buildEngineSpace()
  
  /**
   * 获取或创建引擎
   * 
   * @return (host, port) 引擎的 Thrift 服务地址
   */
  def getOrCreate(
      discoveryClient: DiscoveryClient,
      extraEngineLog: Option[OperationLog] = None): (String, Int) = {
    
    // Step 1: 在 ZK 的 engineSpace 路径下查找已注册的引擎
    discoveryClient.getServerHost(engineSpace)
      .getOrElse {
        // Step 2: 未找到 → 创建新引擎
        create(discoveryClient, extraEngineLog)
      }
  }
```

### 6.2 engineSpace 路径构建 — Share Level 的灵魂

```scala
  /**
   * 构建引擎命名空间路径
   * 
   * 不同 Share Level 生成不同路径，路径不同 = 引擎不共享
   * 路径相同 = 引擎可以共享
   */
  private def buildEngineSpace(): String = {
    val shareLevel = conf.get(ENGINE_SHARE_LEVEL)
    val engineType = conf.get(ENGINE_TYPE)
    val version = KYUUBI_VERSION
    
    // 基础前缀：{serverSpace}_{version}_{shareLevel}_{engineType}
    val prefix = s"${serverSpace}_${version}_${shareLevel}_${engineType}"
    
    shareLevel match {
      case CONNECTION =>
        // ★ 每个连接独占：路径包含 engineRefId（全局唯一 UUID）
        // 所以永远不会命中已有引擎
        s"$prefix/$user/$engineRefId"
        
      case USER =>
        // ★ 同用户共享：路径只包含 user
        // 同一用户的所有连接都会命中同一路径
        val subdomain = getSubdomain()  // 引擎池子域（如果有）
        s"$prefix/$user" + subdomain.map(s => s"/$s").getOrElse("")
        
      case GROUP =>
        // ★ 同组共享：路径包含 primaryGroup（而非 user）
        val primaryGroup = groupProvider.primaryGroup(user)
        val subdomain = getSubdomain()
        s"$prefix/$primaryGroup" + subdomain.map(s => s"/$s").getOrElse("")
        
      case SERVER =>
        // ★ 全局共享：路径只包含 serverUser（固定值）
        val serverUser = Utils.currentUser  // Kyuubi 服务账号
        val subdomain = getSubdomain()
        s"$prefix/$serverUser" + subdomain.map(s => s"/$s").getOrElse("")
        
      case SERVER_LOCAL =>
        // ★ Server 本地共享：路径包含 hostAddress
        val serverUser = Utils.currentUser
        s"$prefix/$serverUser/${hostAddress}_${subdomain}"
    }
  }

  /**
   * 引擎池子域计算
   * 
   * 当配置 kyuubi.engine.pool.size > 0 时生效
   * 用于在同一个 Share Level 下运行多个引擎实例
   */
  private def getSubdomain(): Option[String] = {
    val poolSize = conf.get(ENGINE_POOL_SIZE)
    if (poolSize <= 0) return None
    
    val poolName = conf.get(ENGINE_POOL_NAME)
    conf.get(ENGINE_POOL_SELECT_POLICY) match {
      case POLLING =>
        // 轮询策略：通过 ZK 原子计数器分配
        val index = discoveryClient.getAndIncrement(counterPath, 1) % poolSize
        Some(s"$poolName-$index")
      case RANDOM =>
        // 随机策略
        val index = Random.nextInt(poolSize)
        Some(s"$poolName-$index")
    }
  }
```

**路径示例对比**：

```
假设: serverSpace="kyuubi", version="1.9.0", engineType="SPARK_SQL", user="alice"

CONNECTION 级别:
  /kyuubi_1.9.0_CONNECTION_SPARK_SQL/alice/550e8400-e29b-41d4-a716-446655440000
  → UUID 每次不同，永远不共享

USER 级别:
  /kyuubi_1.9.0_USER_SPARK_SQL/alice
  → alice 的所有连接命中同一路径

GROUP 级别（alice 属于 data-team 组）:
  /kyuubi_1.9.0_GROUP_SPARK_SQL/data-team
  → data-team 组所有成员共享

SERVER 级别:
  /kyuubi_1.9.0_SERVER_SPARK_SQL/kyuubi_service_account
  → 全局唯一路径

USER 级别 + 引擎池(size=3):
  /kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-0
  /kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-1
  /kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-2
  → alice 有 3 个引擎实例，请求轮询分配
```

### 6.3 create — 引擎创建流程（分布式锁 + Double-Check）

```scala
  /**
   * 创建新引擎的核心逻辑
   */
  private def create(
      discoveryClient: DiscoveryClient,
      extraEngineLog: Option[OperationLog]): (String, Int) = {
    
    // ★ 关键设计：分布式锁 + Double-Check Locking
    tryWithLock(discoveryClient) {
      
      // Double-Check：获取锁后再查一次
      // 因为可能在等锁期间，另一个 Server 已经创建了引擎
      discoveryClient.getServerHost(engineSpace) match {
        case Some((host, port)) =>
          return (host, port)  // 有了，直接用
        case None =>
          // 确实没有，开始创建
      }
      
      // Step 1: 获取启动信号量（限制并发启动数）
      startupProcessSemaphore.foreach(_.acquire())
      
      try {
        // Step 2: 构建引擎进程
        val builder = engineType match {
          case SPARK_SQL => new SparkProcessBuilder(conf, user, ...)
          case FLINK_SQL => new FlinkProcessBuilder(conf, user, ...)
          case TRINO     => new TrinoProcessBuilder(conf, user, ...)
          case HIVE_SQL  => new HiveProcessBuilder(conf, user, ...)
          case JDBC      => new JDBCProcessBuilder(conf, user, ...)
        }
        
        // Step 3: 启动子进程
        val process = builder.start()
        // 对于 Spark: 实际执行的是 spark-submit 命令
        
        // Step 4: 等待引擎在 ZK 注册
        val timeout = conf.get(ENGINE_INIT_TIMEOUT).toMillis
        val startTime = System.currentTimeMillis()
        
        while (true) {
          // 检查引擎是否注册到了 ZK
          val engineRef = discoveryClient.getServerHost(engineSpace)
          if (engineRef.isDefined) {
            return engineRef.get  // 引擎就绪！
          }
          
          // 超时检查
          if (System.currentTimeMillis() - startTime > timeout) {
            process.destroyForcibly()
            throw new KyuubiException(
              s"Engine init timeout after ${timeout}ms")
          }
          
          // 应用状态检查（快速失败）
          val appInfo = builder.getApplicationInfo()
          if (appInfo.state == FAILED || appInfo.state == KILLED) {
            throw new KyuubiException(
              s"Engine failed: ${appInfo.error}")
          }
          
          Thread.sleep(100)  // 100ms 轮询间隔
        }
      } finally {
        // Step 5: 释放信号量
        startupProcessSemaphore.foreach(_.release())
      }
    }
  }

  /**
   * 分布式锁的获取策略
   */
  private def tryWithLock(discoveryClient: DiscoveryClient)(f: => T): T = {
    shareLevel match {
      case CONNECTION =>
        // CONNECTION 级别不需要锁（每连接独占，不存在竞争）
        f
      case USER | GROUP | SERVER | SERVER_LOCAL =>
        // 其他级别需要分布式锁（防止重复创建）
        // 底层实现：ZK InterProcessSemaphoreMutex
        discoveryClient.tryWithLock(lockPath, lockTimeout)(f)
    }
  }
}
```

---

## 第七章 SparkProcessBuilder — spark-submit 命令构建（源码级）

### 7.1 命令组装过程

```scala
class SparkProcessBuilder(conf: KyuubiConf, user: String, ...) 
  extends ProcBuilder {

  // 可执行文件：$SPARK_HOME/bin/spark-submit
  override def executable: String = {
    val sparkHome = getEngineHome("spark")
    Paths.get(sparkHome, "bin", "spark-submit").toString
  }

  // 主类：固定为 SparkSQLEngine
  override def mainClass: String = 
    "org.apache.kyuubi.engine.spark.SparkSQLEngine"

  // ★ 完整命令构建
  override def commands: Iterable[String] = {
    val buffer = new ListBuffer[String]()
    
    buffer += executable
    buffer += "--class" += mainClass
    
    // 1. 配置转换：kyuubi 配置 → spark 配置
    val sparkConf = new mutable.HashMap[String, String]()
    conf.getAll.foreach { case (key, value) =>
      val sparkKey = convertConfigKey(key)
      sparkConf(sparkKey) = value
    }
    
    // 2. 自动补全 master URL
    if (!sparkConf.contains("spark.master")) {
      completeMasterUrl(sparkConf)  // 检测 K8s 环境自动设置
    }
    
    // 3. YARN 特殊处理
    sparkConf.getOrElseUpdate(
      "spark.yarn.maxAppAttempts", "1")  // 快速失败
    
    // 4. Kubernetes 处理
    if (isKubernetesMode) {
      sparkConf("spark.kubernetes.driver.pod.name") = 
        generatePodName()  // 自动生成 Pod 名称
    }
    
    // 5. Kerberos 设置
    setupKerberos(buffer, sparkConf)
    
    // 6. 写入所有 --conf 参数
    sparkConf.foreach { case (k, v) =>
      buffer += "--conf" += s"$k=$v"
    }
    
    // 7. 主资源（Kyuubi Engine JAR）
    buffer += mainResource
    
    buffer
  }

  /**
   * 配置 Key 转换规则
   */
  private def convertConfigKey(key: String): String = key match {
    case k if k.startsWith("spark.")  => k           // 已是 Spark 配置
    case k if k.startsWith("hadoop.") => s"spark.hadoop.$k"  // Hadoop 配置
    case k => s"spark.$k"                             // 其他加 spark. 前缀
  }

  /**
   * Kerberos 认证设置
   */
  private def setupKerberos(
      buffer: ListBuffer[String], 
      sparkConf: mutable.Map[String, String]): Unit = {
    
    if (hasKeytab && isProxyUser) {
      // 代理用户模式
      buffer += "--proxy-user" += proxyUser
      sparkConf("spark.kubernetes.driverEnv.SPARK_USER_NAME") = proxyUser
    } else if (hasKeytab) {
      // Keytab 直连模式
      sparkConf("spark.files") = keytabPath  // 上传 keytab 到 YARN
    } else {
      // 无认证模式
      sparkConf("spark.executorEnv.SPARK_USER_NAME") = user
    }
  }
}
```

**最终生成的 spark-submit 命令示例**：

```bash
/opt/spark/bin/spark-submit \
  --class org.apache.kyuubi.engine.spark.SparkSQLEngine \
  --conf spark.master=yarn \
  --conf spark.submit.deployMode=cluster \
  --conf spark.driver.memory=2g \
  --conf spark.executor.memory=4g \
  --conf spark.executor.cores=2 \
  --conf spark.dynamicAllocation.enabled=true \
  --conf spark.dynamicAllocation.minExecutors=1 \
  --conf spark.dynamicAllocation.maxExecutors=20 \
  --conf spark.yarn.maxAppAttempts=1 \
  --conf spark.kyuubi.ha.addresses=zk1:2181,zk2:2181 \
  --conf spark.kyuubi.ha.namespace=kyuubi \
  --conf spark.kyuubi.engine.share.level=USER \
  --conf spark.kyuubi.session.user=alice \
  --proxy-user alice \
  /opt/kyuubi/externals/engines/spark/kyuubi-spark-sql-engine.jar
```

---

## 第八章 Spark SQL Engine 内部实现（源码级）

### 8.1 SparkSQLEngine 主入口

```scala
object SparkSQLEngine {
  def main(args: Array[String]): Unit = {
    // Step 1: 版本检查（Spark 3.3/3.4 弃用警告）
    checkSparkVersion()
    
    // Step 2: 超时监控线程
    //   独立守护线程监控 SparkSession 创建
    //   如果超时（ENGINE_INIT_TIMEOUT），中断主线程防死锁
    startInitTimeoutChecker()
    
    // Step 3: 创建 SparkSession
    val spark = createSpark()
    // 内部做的事：
    //   - kyuubi.* 配置从 spark.kyuubi.* 前缀解析
    //   - K8s 环境适配（Pod 名称/端口/地址）
    //   - 本地模式默认 master=local
    //   - 根据 classpath 是否有 Hive 类选择 catalog
    //   - SparkSession.builder().config(sparkConf).getOrCreate()
    //   - 执行 ENGINE_SPARK_INITIALIZE_SQL（默认 "SHOW DATABASES"）
    
    // Step 4: 启动引擎服务
    startEngine(spark)
    //   → new SparkSQLEngine().initialize(conf)
    //      → 添加 SparkSQLEngineListener
    //      → 添加 SparkSQLEngineEventListener
    //      → super.initialize(): 初始化 Backend + Frontend
    //   → engine.start()
    //      → super.start(): 启动所有服务
    //      → 启动空闲终止检查器
    //      → 启动最大生命周期检查器
    //      → 在 ZK 注册自己（引擎服务发现）
    
    // Step 5: 阻塞等待
    countDownLatch.await()
    //   → 主线程阻塞，直到收到停止信号
    //   → 停止信号来源：空闲超时 / 最大生命周期 / 主动 kill
  }
}
```

### 8.2 SparkSQLSessionManager — 引擎端会话管理

```scala
class SparkSQLSessionManager(spark: SparkSession) 
  extends SessionManager("SparkSQLSessionManager") {

  // ★ 用户隔离的 SparkSession 缓存
  // 用于 GROUP/SERVER 级别下不同用户拥有独立的 SQL 环境
  private val userIsolatedCache = new HashMap[String, SparkSession]()
  private val userIsolatedCacheCount = new HashMap[String, (Int, Long)]()
  // key = userName, value = (活跃会话数, 最后访问时间戳)
  private val userIsolatedCacheLock = new ReentrantLock()

  /**
   * 获取或创建 SparkSession
   * 
   * ★ 这里决定了不同 Share Level 下 SparkSession 的隔离方式
   */
  private def getOrNewSparkSession(user: String): SparkSession = {
    val shareLevel = conf.get(ENGINE_SHARE_LEVEL)
    val singleSession = conf.get(ENGINE_SINGLE_SPARK_SESSION)
    
    if (singleSession) {
      // 单会话模式：所有人共享根 SparkSession
      return spark
    }
    
    shareLevel match {
      case CONNECTION =>
        // 连接级：共享根 SparkSession（因为引擎本身就是独占的）
        spark
        
      case USER =>
        // 用户级：★ 总是创建新的 SparkSession
        // 因为 USER 级别引擎被同一用户共享
        // 但每个 Session 需要独立的 SQL 环境
        spark.newSession()
        // newSession() 创建的会话：
        //   - 共享同一个 SparkContext
        //   - 独立的 SessionState（临时视图/UDF/SQL配置）
        
      case GROUP | SERVER =>
        if (userIsolatedSparkSession) {
          spark.newSession()
        } else {
          // ★ 用户隔离缓存：引用计数 + LRU
          userIsolatedCacheLock.lock()
          try {
            userIsolatedCache.getOrElseUpdate(user, {
              spark.newSession()
            })
            // 增加引用计数
            val (count, _) = userIsolatedCacheCount
              .getOrElse(user, (0, System.currentTimeMillis()))
            userIsolatedCacheCount(user) = 
              (count + 1, System.currentTimeMillis())
          } finally {
            userIsolatedCacheLock.unlock()
          }
          userIsolatedCache(user)
        }
    }
  }

  /**
   * 关闭会话时的清理逻辑
   */
  override def closeSession(handle: SessionHandle): Unit = {
    val session = getSession(handle)
    super.closeSession(handle)
    
    // GROUP/SERVER 级别：减少引用计数
    if (shareLevel == GROUP || shareLevel == SERVER) {
      userIsolatedCacheLock.lock()
      try {
        val user = session.user
        userIsolatedCacheCount.get(user).foreach { case (count, _) =>
          if (count <= 1) {
            userIsolatedCacheCount(user) = (0, System.currentTimeMillis())
          } else {
            userIsolatedCacheCount(user) = (count - 1, System.currentTimeMillis())
          }
        }
      } finally {
        userIsolatedCacheLock.unlock()
      }
    }
    
    // ★ CONNECTION 级别：直接停止整个引擎
    if (shareLevel == CONNECTION) {
      stopEngine()
    }
  }

  /**
   * 用户隔离缓存清理器
   * 
   * 后台线程定期扫描，回收空闲用户的 SparkSession
   */
  private def startUserIsolatedCacheChecker(): Unit = {
    val checker = new Runnable {
      override def run(): Unit = {
        userIsolatedCacheLock.lock()
        try {
          val now = System.currentTimeMillis()
          userIsolatedCacheCount.foreach { case (user, (count, lastAccess)) =>
            if (count == 0 && (now - lastAccess) > idleTimeout) {
              // 活跃会话数为 0 且超时 → 回收
              userIsolatedCache.remove(user)
              userIsolatedCacheCount.remove(user)
            }
          }
        } finally {
          userIsolatedCacheLock.unlock()
        }
      }
    }
    scheduler.scheduleAtFixedRate(checker, interval, interval, TimeUnit.MILLISECONDS)
  }
}
```

### 8.3 ExecuteStatement — SQL 执行核心

```scala
class ExecuteStatement(
    spark: SparkSession,
    session: Session,
    statement: String,
    override val shouldRunAsync: Boolean,
    queryTimeout: Long,
    incrementalCollect: Boolean
) extends SparkOperation {

  /**
   * 操作状态机:
   * INITIALIZED → PENDING → RUNNING → (COMPILED) → FINISHED
   *                                              ↘ ERROR
   */

  override def runInternal(): Unit = {
    // Step 1: 添加超时监控
    addTimeoutMonitor(queryTimeout)  // 超时后取消 Spark Job
    
    if (shouldRunAsync) {
      // 异步执行：提交到后台线程池
      val task = new Runnable {
        override def run(): Unit = executeStatement()
      }
      try {
        sessionManager.submitBackgroundOperation(task)
      } catch {
        case _: RejectedExecutionException =>
          // ★ 线程池满！类似 HS2 的 backgroundOperationPool 问题
          setState(OperationState.ERROR)
          throw KyuubiSQLException("Background operation pool full")
      }
    } else {
      // 同步执行
      executeStatement()
    }
  }

  /**
   * ★ SQL 执行核心逻辑
   */
  private def executeStatement(): Unit = {
    setState(OperationState.RUNNING)
    
    try {
      // Step 1: 设置 Spark Job 元数据
      spark.sparkContext.setLocalProperty("spark.jobGroup.id", statementId)
      spark.sparkContext.setLocalProperty("kyuubi.statement", statement)
      
      // Step 2: ★ 执行 SQL
      val result: DataFrame = spark.sql(statement)
      // 内部调用链：
      //   spark.sql(statement)
      //   → SessionState.sqlParser.parsePlan(statement)    // 解析
      //   → Analyzer.execute(logicalPlan)                  // 分析
      //   → Optimizer.execute(analyzedPlan)                // 优化(含 AQE)
      //   → SparkPlanner.plan(optimizedPlan)               // 物理计划
      //   → QueryExecution                                 // 执行框架
      
      // Step 3: 收集结果
      iter = collectAsIterator(result)
      
      // Step 4: 完成
      setState(OperationState.FINISHED)
      
    } catch {
      case e: Exception =>
        setState(OperationState.ERROR)
        throw e
    }
  }

  /**
   * ★ 结果收集策略（三种模式）
   */
  private def collectAsIterator(result: DataFrame): FetchIterator[Row] = {
    
    if (incrementalCollect) {
      // 模式 1：增量收集 — 逐批拉取，不全量加载到 Driver
      // 适合大数据量场景，防止 Driver OOM
      // 但性能较低（多次 RPC）
      new IterableFetchIterator(result.toLocalIterator().asScala)
      
    } else if (saveToFile) {
      // 模式 2：落盘收集 — 结果写到 ORC 文件
      // 超大结果集场景，通过文件流式返回
      val path = getResultSavePath()
      result.write
        .option("compression", "zstd")
        .format("orc")
        .save(path)
      new FetchOrcStatement(path)
      
    } else {
      // 模式 3：内存收集（默认）
      val maxRows = conf.get(OPERATION_RESULT_MAX_ROWS)
      if (maxRows > 0) {
        // 限制行数：df.take(maxRows)
        new ArrayFetchIterator(result.take(maxRows.toInt))
      } else {
        // 全量收集：df.collect()
        // ⚠️ 大数据量可能导致 Driver OOM
        new ArrayFetchIterator(result.collect())
      }
    }
  }

  /**
   * 关闭操作：取消 Spark Job + 清理文件
   */
  override def close(): Unit = {
    super.close()
    // 取消关联的 Spark Job Group
    spark.sparkContext.cancelJobGroup(statementId)
    // 清理临时结果文件
    saveFilePath.foreach(FileSystem.get(conf).delete(_, true))
  }
}
```

---

## 第九章 HA 服务发现机制（源码级）

### 9.1 DiscoveryClient 接口设计

```scala
trait DiscoveryClient extends Closeable {
  
  // ===== 连接管理 =====
  def createClient(): Unit
  def closeClient(): Unit
  def monitorState(serviceDiscovery: ServiceDiscovery): Unit
  
  // ===== 节点操作（底层 ZK ZNode 操作） =====
  def create(path: String, mode: CreateMode, createParent: Boolean): String
  def delete(path: String, deleteChildren: Boolean): Unit
  def setData(path: String, data: Array[Byte]): Unit
  def getData(path: String): Array[Byte]
  def pathExists(path: String): Boolean
  
  // ===== 服务注册/注销 =====
  def registerService(
      conf: KyuubiConf, 
      namespace: String,
      serviceDiscovery: ServiceDiscovery,
      version: String,
      external: Boolean): Unit
  // external=true: 客户端断开时不自动删除节点
  // external=false: 客户端断开时自动删除（临时节点）
  
  def deregisterService(): Unit
  
  // ===== 引擎发现 =====
  def getServerHost(namespace: String): Option[(String, Int)]
  def getEngineByRefId(
      namespace: String, 
      engineRefId: String): Option[(String, Int)]
  def getServiceNodesInfo(
      namespace: String, 
      sizeOpt: Option[Int] = None): Seq[ServiceNodeInfo]
  
  // ===== 分布式锁 =====
  def tryWithLock[T](lockPath: String, timeout: Long)(f: => T): T
  // 底层实现：ZK InterProcessSemaphoreMutex
  // 用途：防止多个 Server 同时创建同一个共享引擎
  
  // ===== 原子计数器 =====
  def getAndIncrement(path: String, delta: Int): Int
  // 用途：引擎池的轮询策略（POLLING）序号分配
}
```

### 9.2 ZooKeeper 实现细节

```scala
class ZookeeperDiscoveryClient(conf: KyuubiConf) extends DiscoveryClient {
  
  private var zkClient: CuratorFramework = _
  
  override def createClient(): Unit = {
    zkClient = CuratorFrameworkFactory.builder()
      .connectString(conf.get(HA_ADDRESSES))
      .sessionTimeoutMs(conf.get(HA_ZK_SESSION_TIMEOUT))
      .retryPolicy(new ExponentialBackoffRetry(1000, 3))
      .build()
    zkClient.start()
  }
  
  /**
   * 服务注册：在 ZK 创建临时顺序节点
   */
  override def registerService(...): Unit = {
    // 节点数据格式：
    // "serverUri=host:port;version=1.9.0;sequence=0000000001"
    val nodeData = s"serverUri=$host:$port;version=$version"
    
    val mode = if (external) {
      CreateMode.PERSISTENT_SEQUENTIAL  // 持久化节点
    } else {
      CreateMode.EPHEMERAL_SEQUENTIAL   // 临时节点（断连自动删除）
    }
    
    zkClient.create()
      .creatingParentsIfNeeded()
      .withMode(mode)
      .forPath(s"$namespace/$nodeData")
  }
  
  /**
   * 获取引擎地址
   */
  override def getServerHost(namespace: String): Option[(String, Int)] = {
    if (!pathExists(namespace)) return None
    
    val children = zkClient.getChildren.forPath(namespace)
    if (children.isEmpty) return None
    
    // 解析子节点数据获取 host:port
    val nodeData = children.asScala.head
    val (host, port) = parseInstanceHostPort(nodeData)
    Some((host, port))
  }
  
  /**
   * 分布式锁实现
   */
  override def tryWithLock[T](lockPath: String, timeout: Long)(f: => T): T = {
    val lock = new InterProcessSemaphoreMutex(zkClient, lockPath)
    if (!lock.acquire(timeout, TimeUnit.MILLISECONDS)) {
      throw new KyuubiException(
        s"Timeout waiting for lock at $lockPath after ${timeout}ms")
    }
    try {
      f  // 执行临界区代码
    } finally {
      lock.release()
    }
  }
}
```

### 9.3 ZK 节点结构完整图

```
/kyuubi                                    ← 根命名空间
│
├── /serviceDiscovery                      ← Kyuubi Server 注册
│   ├── serverUri=host1:10009;version=1.9.0;sequence=0000000001
│   └── serverUri=host2:10009;version=1.9.0;sequence=0000000002
│
├── /kyuubi_1.9.0_USER_SPARK_SQL           ← USER 级别引擎
│   ├── /alice
│   │   └── serviceUri=engine1:37291;instance=app-001
│   ├── /bob
│   │   └── serviceUri=engine2:37292;instance=app-002
│   └── /alice                             ← alice 的引擎池（如果有）
│       ├── /pool-0
│       │   └── serviceUri=engine3:37293;instance=app-003
│       └── /pool-1
│           └── serviceUri=engine4:37294;instance=app-004
│
├── /kyuubi_1.9.0_CONNECTION_SPARK_SQL     ← CONNECTION 级别
│   └── /alice
│       └── /550e8400-e29b-...             ← UUID（每连接唯一）
│           └── serviceUri=engine5:37295
│
├── /kyuubi_1.9.0_GROUP_SPARK_SQL          ← GROUP 级别
│   └── /data-team
│       └── serviceUri=engine6:37296
│
└── /locks                                 ← 分布式锁节点
    └── /kyuubi_1.9.0_USER_SPARK_SQL_alice
```

---

## 第十章 配置系统 KyuubiConf（源码级）

### 10.1 ConfigEntry 定义模式

```scala
// KyuubiConf.scala — 所有配置项的注册中心
object KyuubiConf {
  
  // ★ 构建器模式：类型安全 + 文档化 + 校验
  private def buildConf(key: String): ConfigBuilder = new ConfigBuilder(key)

  // ===== 引擎管理配置 =====
  
  val ENGINE_SHARE_LEVEL: ConfigEntry[String] = 
    buildConf("kyuubi.engine.share.level")
      .doc("Engines shared level: CONNECTION, USER, GROUP, SERVER")
      .version("1.2.0")
      .serverOnly                              // 仅 Server 端生效
      .stringConf
      .transformToUpperCase                    // 自动转大写
      .checkValue(
        s => ShareLevel.values.map(_.toString).contains(s),
        "Invalid share level")
      .createWithDefault("USER")
  
  val ENGINE_TYPE: ConfigEntry[String] = 
    buildConf("kyuubi.engine.type")
      .doc("Specify the engine type: SPARK_SQL, FLINK_SQL, TRINO, HIVE_SQL, JDBC, CHAT")
      .version("1.4.0")
      .serverOnly
      .stringConf
      .transformToUpperCase
      .createWithDefault("SPARK_SQL")
  
  val ENGINE_IDLE_TIMEOUT: ConfigEntry[Long] = 
    buildConf("kyuubi.session.engine.idle.timeout")
      .doc("Engine idle timeout. PT0s means no timeout.")
      .version("1.0.0")
      .timeConf                                // Duration 类型
      .createWithDefault(Duration.ofMinutes(30).toMillis)
  
  val ENGINE_INIT_TIMEOUT: ConfigEntry[Long] = 
    buildConf("kyuubi.session.engine.initialize.timeout")
      .doc("Timeout for starting a new engine")
      .version("1.0.0")
      .timeConf
      .createWithDefault(Duration.ofMinutes(3).toMillis)
  
  val ENGINE_POOL_SIZE: ConfigEntry[Int] = 
    buildConf("kyuubi.engine.pool.size")
      .doc("Engine pool size. -1 means disabled.")
      .version("1.4.0")
      .serverOnly
      .intConf
      .checkValue(_ >= -1, "Must be >= -1")
      .createWithDefault(-1)
  
  val ENGINE_STARTUP_MAX_CONCURRENT: OptionalConfigEntry[Int] = 
    buildConf("kyuubi.engine.startup.maxConcurrent")
      .doc("Max concurrent engine startup processes, 0 means unlimited")
      .version("1.8.0")
      .serverOnly
      .intConf
      .createOptional                          // 可选配置
  
  // ===== 会话管理配置 =====
  
  val SESSION_IDLE_TIMEOUT: ConfigEntry[Long] = 
    buildConf("kyuubi.session.idle.timeout")
      .doc("Session idle timeout")
      .version("1.0.0")
      .timeConf
      .createWithDefault(Duration.ofHours(6).toMillis)
      // ★ 注意默认 6 小时，生产必须缩短！
  
  val SESSION_CHECK_INTERVAL: ConfigEntry[Long] = 
    buildConf("kyuubi.session.check.interval")
      .doc("Interval for session timeout check")
      .version("1.0.0")
      .timeConf
      .createWithDefault(Duration.ofMinutes(5).toMillis)
  
  // ===== 前端服务配置 =====
  
  val FRONTEND_PROTOCOLS: ConfigEntry[Seq[String]] = 
    buildConf("kyuubi.frontend.protocols")
      .doc("Frontend protocols: THRIFT_BINARY, THRIFT_HTTP, REST, MYSQL, TRINO")
      .version("1.4.0")
      .serverOnly
      .stringConf
      .toSequence()                            // 逗号分隔的列表
      .createWithDefault(Seq("THRIFT_BINARY"))
  
  val FRONTEND_THRIFT_BINARY_BIND_PORT: ConfigEntry[Int] = 
    buildConf("kyuubi.frontend.thrift.binary.bind.port")
      .doc("Port for Thrift binary frontend service")
      .version("1.4.0")
      .serverOnly
      .intConf
      .checkValue(p => p == 0 || (p > 1024 && p < 65535), 
        "Invalid port number")
      .createWithDefault(10009)
  
  // ===== HA 配置 =====
  
  val HA_ADDRESSES: ConfigEntry[String] = 
    buildConf("kyuubi.ha.addresses")
      .doc("ZooKeeper/Etcd addresses for HA")
      .version("1.0.0")
      .stringConf
      .createWithDefault("")
  
  // ===== 认证配置 =====
  
  val AUTHENTICATION_METHOD: ConfigEntry[Seq[String]] = 
    buildConf("kyuubi.authentication")
      .doc("Authentication method: NOSASL, NONE, KERBEROS, LDAP, JDBC, CUSTOM")
      .version("1.0.0")
      .serverOnly
      .stringConf
      .toSequence()                            // ★ 支持多种认证同时启用
      .createWithDefault(Seq("NONE"))
  
  // ===== 操作配置 =====
  
  val OPERATION_RESULT_MAX_ROWS: ConfigEntry[Int] = 
    buildConf("kyuubi.operation.result.max.rows")
      .doc("Max rows returned per fetch")
      .version("1.6.0")
      .intConf
      .createWithDefault(0)                    // 0 = 无限制
  
  val BACKEND_SERVER_EXEC_POOL_SIZE: ConfigEntry[Int] = 
    buildConf("kyuubi.backend.server.exec.pool.size")
      .doc("Background operation thread pool size")
      .version("1.0.0")
      .intConf
      .createWithDefault(100)
      // ★ 类似 HS2 的 backgroundOperationPool
      // 满了就会 RejectedExecution
  
  // ===== 批处理配置 =====
  
  val METADATA_STORE_CLASS: ConfigEntry[String] = 
    buildConf("kyuubi.metadata.store.class")
      .doc("Metadata store for batch jobs")
      .version("1.6.0")
      .stringConf
      .createWithDefault("JDBC")
  
  val METADATA_MAX_AGE: ConfigEntry[Long] = 
    buildConf("kyuubi.metadata.max.age")
      .doc("Max age of metadata entries")
      .version("1.6.0")
      .timeConf
      .createWithDefault(Duration.ofDays(3).toMillis)
}
```

### 10.2 配置加载优先级链

```
命令行参数 --conf kyuubi.xxx=yyy
     ↓ (最高优先级)
系统属性 -Dkyuubi.xxx=yyy
     ↓
$KYUUBI_HOME/conf/kyuubi-defaults.conf  (主配置文件)
     ↓
$KYUUBI_HOME/conf/kyuubi-env.sh  (环境变量)
     ↓
ConfigEntry.createWithDefault()  (代码默认值，最低优先级)

特殊机制：
  用户特定默认值：通过 ___username___key=value 语法
  引擎端环境变量透传：kyuubi.engineEnv.VAR_NAME=value
```

---

## 第十一章 引擎生命周期状态机

### 11.1 完整生命周期

```
                       ┌─────────────────────────────────┐
                       │         引擎生命周期              │
┌──────┐    ┌─────────┐│  ┌─────────┐    ┌──────────────┐│  ┌──────┐
│CREATE├───→│STARTING ││─→│REGISTERED├───→│  SERVING     ││─→│STOP  │
│      │    │         ││  │(ZK注册) │    │  (处理SQL)   ││  │      │
└──────┘    └─────────┘│  └─────────┘    └──────────────┘│  └──────┘
                       └─────────────────────────────────┘
     │                                        │                  │
     │ spark-submit                          │ idle timeout     │
     │ 提交到YARN/K8s                        │ max lifetime     │
     │                                        │ CONNECTION close │
     │                                        │                  │
     │    ┌──────────────────────────┐       │                  │
     └───→│ENGINE_INIT_TIMEOUT       │       │                  │
          │超时 → 杀进程 → 报错返回   │       │                  │
          └──────────────────────────┘       │                  │
                                             ▼                  ▼
                                    从ZK注销 → 优雅关闭 → SparkContext.stop()
```

### 11.2 SparkSQLEngine 内的生命周期检查器

```scala
// SparkSQLEngine.start() 中启动的检查器

// 1. 空闲终止检查器
//    当没有活跃 Session 时，等待 engine.idle.timeout 后停止
private def startIdleTerminatingChecker(): Unit = {
  val idleTimeout = conf.get(ENGINE_IDLE_TIMEOUT)
  scheduler.scheduleAtFixedRate(
    () => {
      if (sessionManager.getActiveSessionCount == 0) {
        val idleSince = sessionManager.getLastNoSessionTime()
        if (System.currentTimeMillis() - idleSince > idleTimeout) {
          info("Engine idle timeout, stopping...")
          deregisterFromDiscovery()  // 先从 ZK 注销
          stop()                      // 再停止服务
          countDownLatch.countDown()   // 唤醒主线程退出
        }
      }
    },
    checkInterval, checkInterval, TimeUnit.MILLISECONDS
  )
}

// 2. 最大生命周期检查器
//    引擎运行超过 max.lifetime 后，优雅关闭
private def startLifetimeTerminatingChecker(): Unit = {
  val maxLifetime = conf.get(ENGINE_MAX_LIFETIME)
  val gracefulPeriod = conf.get(ENGINE_MAX_LIFETIME_GRACEFUL_PERIOD)
  
  scheduler.schedule(
    () => {
      info(s"Engine max lifetime ${maxLifetime}ms reached")
      
      // Step 1: 从 ZK 注销（不再接受新连接）
      deregisterFromDiscovery()
      
      // Step 2: 等待现有 Session 完成
      val deadline = System.currentTimeMillis() + gracefulPeriod
      while (sessionManager.getActiveSessionCount > 0 
             && System.currentTimeMillis() < deadline) {
        Thread.sleep(1000)
      }
      
      // Step 3: 停止引擎
      stop()
      countDownLatch.countDown()
    },
    maxLifetime, TimeUnit.MILLISECONDS
  )
}

// 3. CONNECTION 级别快速失败检查器
//    如果引擎启动后一直没有连接，超时后自动销毁
private def startFastFailChecker(): Unit = {
  if (shareLevel == CONNECTION) {
    scheduler.schedule(
      () => {
        if (sessionManager.getOpenSessionCount == 0) {
          warn("No connection after init timeout, stopping engine")
          stop()
          countDownLatch.countDown()
        }
      },
      maxInitTimeout, TimeUnit.MILLISECONDS
    )
  }
}
```

---

## 第十二章 Frontend Thrift 服务实现

### 12.1 请求处理链路

```scala
// KyuubiTBinaryFrontendService 继承自 TBinaryFrontendService
// TBinaryFrontendService 实现了 TCLIService.Iface（Hive Thrift 协议接口）

class KyuubiTBinaryFrontendService(serverable: Serverable) 
  extends TBinaryFrontendService("KyuubiTBinaryFrontend") {

  /**
   * 处理 OpenSession 请求
   */
  override def OpenSession(req: TOpenSessionReq): TOpenSessionResp = {
    val resp = new TOpenSessionResp()
    try {
      // 1. 提取认证信息
      val (user, password) = getAuthInfo(req)
      val ipAddress = getIpAddress()
      
      // 2. 提取配置（客户端传递的 SET 参数）
      val conf = req.getConfiguration.asScala.toMap
      
      // 3. ★ 调用后端服务打开会话
      val sessionHandle = backendService.openSession(
        protocol, user, password, ipAddress, conf)
      
      // 4. 返回 SessionHandle
      resp.setSessionHandle(sessionHandle.toTSessionHandle)
      resp.setStatus(OK_STATUS)
    } catch {
      case e: Exception =>
        resp.setStatus(ERROR_STATUS(e))
    }
    resp
  }

  /**
   * 处理 ExecuteStatement 请求
   */
  override def ExecuteStatement(req: TExecuteStatementReq): TExecuteStatementResp = {
    val resp = new TExecuteStatementResp()
    try {
      val sessionHandle = SessionHandle(req.getSessionHandle)
      val statement = req.getStatement
      val confOverlay = req.getConfOverlay.asScala.toMap
      val runAsync = req.isRunAsync
      val queryTimeout = req.getQueryTimeout
      
      // ★ 调用后端服务执行 SQL
      val operationHandle = backendService.executeStatement(
        sessionHandle, statement, confOverlay, runAsync, queryTimeout)
      
      resp.setOperationHandle(operationHandle.toTOperationHandle)
      resp.setStatus(OK_STATUS)
    } catch {
      case e: Exception =>
        resp.setStatus(ERROR_STATUS(e))
    }
    resp
  }

  /**
   * 处理 FetchResults 请求
   */
  override def FetchResults(req: TFetchResultsReq): TFetchResultsResp = {
    // 从操作中获取结果集，返回 TRowSet
    val operationHandle = OperationHandle(req.getOperationHandle)
    val orientation = req.getOrientation
    val maxRows = req.getMaxRows
    
    val rowSet = backendService.fetchResults(
      operationHandle, orientation, maxRows)
    
    val resp = new TFetchResultsResp(OK_STATUS)
    resp.setResults(rowSet)
    resp
  }
}
```

---

## 第十三章 认证安全链路

### 13.1 认证方式枚举

```scala
// 支持的认证方式（可多选组合）
// 配置: kyuubi.authentication=KERBEROS,LDAP
enum AuthTypes {
  NOSASL,     // 不走 SASL（不安全）
  NONE,       // 无认证（接受任何用户名）
  KERBEROS,   // Kerberos 强认证
  LDAP,       // LDAP 目录服务认证
  JDBC,       // SQL 查库认证
  CUSTOM      // 自定义认证提供者
}
```

### 13.2 认证链工作流

```
客户端连接
  │
  ├── KERBEROS 认证
  │   1. 客户端发送 Kerberos ticket (SASL/GSSAPI)
  │   2. KyuubiServer 用 keytab 验证 ticket
  │   3. 获取认证后的 principal 作为 user
  │   4. 使用 proxy user 机制以该用户身份启动引擎
  │
  ├── LDAP 认证
  │   1. 客户端发送 user/password
  │   2. KyuubiServer 连接 LDAP 服务器验证
  │   3. 验证通过后使用该用户启动引擎
  │
  ├── JDBC 认证
  │   1. 客户端发送 user/password
  │   2. KyuubiServer 执行 SQL 查询数据库验证
  │   3. 比对密码 hash
  │
  └── CUSTOM 认证
      1. 加载自定义 AuthenticationProviderImpl
      2. 调用 authenticate(user, password) 方法
```

---

## 第十四章 关键数据结构与设计模式总结

### 14.1 核心设计模式

| 模式 | 应用场景 | 实现 |
|------|----------|------|
| **Builder 模式** | 配置定义 | `KyuubiConf.buildConf().doc().version().intConf.createWithDefault()` |
| **CompositeService 模式** | 服务生命周期 | `KyuubiServer → [Kinit, GC, Metrics, Backend, Frontend]` |
| **Double-Check Locking** | 引擎创建 | `EngineRef.create()`: 获取锁后再查一次 ZK |
| **Semaphore** | 并发控制 | `startupProcessSemaphore`: 限制引擎启动并发数 |
| **引用计数** | Session 管理 | `SparkSQLSessionManager.userIsolatedCacheCount` |
| **观察者模式** | 事件系统 | `EventBus.post(event)` |
| **策略模式** | 引擎池分配 | `POLLING` vs `RANDOM` 选择策略 |
| **模板方法** | 服务框架 | `Serverable.initialize()` 定义骨架，子类实现细节 |

### 14.2 线程模型

```
KyuubiServer 进程中的主要线程：
│
├── main 线程：启动完成后阻塞
├── Thrift Worker 线程池（处理客户端请求）
│   └── 大小: kyuubi.frontend.thrift.max.worker.threads (默认 999)
├── Backend Operation 线程池（处理后台操作）
│   └── 大小: kyuubi.backend.server.exec.pool.size (默认 100)
│   └── ★ 满了会 RejectedExecutionException（类似 HS2 问题）
├── Session 超时检查线程
│   └── 间隔: kyuubi.session.check.interval (默认 5 分钟)
├── Engine 连接活性检查线程
│   └── 定期 ping 引擎检测连通性
├── Kinit 刷新线程（Kerberos 环境）
├── PeriodicGC 线程
├── Metrics 采集线程
└── ZK 事件监听线程（服务发现状态变化）

SparkSQLEngine 进程中的主要线程：
│
├── main 线程：countDownLatch.await() 阻塞
├── Spark Driver 线程（执行 SQL）
├── Thrift Worker 线程池（接收 Server 的 RPC 请求）
├── 空闲终止检查器线程
├── 最大生命周期检查器线程
├── SparkContext 事件总线线程
├── GC 监控线程
└── ZK 事件监听线程
```

---

## 附录：与 HS2 知识库的源码级交叉关联

| Kyuubi 源码位置 | 对应 HS2 问题 | 关联说明 |
|----------------|-------------|---------|
| `KyuubiSessionManager.execPool` | HS2 `backgroundOperationPool` RejectedExecution | 同样存在线程池满风险，默认 100 |
| `KyuubiSessionImpl.close()` | HS2 `CLOSE_SESSION_ON_DISCONNECT` | Kyuubi 断连后 Session 是否清理取决于 Share Level |
| `SparkSQLSessionManager.userIsolatedCache` | HS2 `HiveSessionImpl` MetaStoreClient 泄漏 | 引用计数机制防止 SparkSession 泄漏 |
| `EngineRef.create()` 分布式锁 | HS2 单点启动 | Kyuubi 用 ZK 锁解决并发创建问题，HS2 无此机制 |
| `ExecuteStatement.collectAsIterator()` | HS2 大结果集 OOM | Kyuubi 提供增量收集/落盘收集三种策略 |
| `SparkSQLEngine.startIdleTerminatingChecker()` | HS2 连接池不回收 | Kyuubi 主动检测并销毁空闲引擎 |

---

---

## 第十五章 KyuubiApplicationManager — 引擎应用管理（源码级）

### 15.1 架构定位

`KyuubiApplicationManager` 是**引擎进程在资源管理器层面的生命周期管理器**。它不关心引擎内部逻辑，只关心进程级别的启动、监控、销毁。

```
EngineRef（负责引擎的 ZK 级别管理）
    ↓ 启动引擎时调用
ProcBuilder（构建 spark-submit 命令）
    ↓ 启动后需要监控和管理
KyuubiApplicationManager（负责资源管理器级别的管理）
    ├── YarnApplicationOperation    ← YARN 环境
    ├── KubernetesApplicationOperation  ← K8s 环境
    └── JpsApplicationOperation     ← 本地进程环境
```

### 15.2 ApplicationOperation 接口

```scala
// 统一的应用操作接口 — 屏蔽 YARN/K8s/本地 差异
trait ApplicationOperation {
  // 查询应用状态
  def getApplicationInfoByTag(
      clusterManager: Option[String],
      tag: String): Option[ApplicationInfo]
  
  // 终止应用
  def killApplicationByTag(
      clusterManager: Option[String],
      tag: String): KillResponse
  
  // 判断是否支持当前环境
  def isSupported(clusterManager: Option[String]): Boolean
}

// ApplicationInfo — 引擎应用状态
case class ApplicationInfo(
  id: String,           // 应用 ID（如 application_xxx）
  name: String,         // 应用名称
  state: ApplicationState,  // RUNNING/FINISHED/FAILED/KILLED/NOT_FOUND
  url: Option[String],  // Tracking URL
  error: Option[String] // 错误信息
)
```

### 15.3 三种资源管理器实现

| 实现类 | 环境 | 监控方式 | 终止方式 |
|--------|------|----------|----------|
| **YarnApplicationOperation** | YARN | `YarnClient.getApplicationReport()` | `YarnClient.killApplication()` |
| **KubernetesApplicationOperation** | K8s | K8s Informer 监听 Pod 状态 | `kubernetesClient.pods().delete()` |
| **JpsApplicationOperation** | 本地 | `jps` 命令扫描 JVM 进程 | `kill -15 <pid>` |

### 15.4 引擎应用标记机制

Kyuubi 通过**标记（Tag）** 在资源管理器中追踪引擎：

```scala
// SparkProcessBuilder 中设置标记
sparkConf("spark.yarn.tags") = s"KYUUBI,$engineRefId"
// K8s 模式
sparkConf("spark.kubernetes.driver.label.kyuubi-unique-tag") = engineRefId
// Flink
flinkConf("flink.yarn.tags") = s"KYUUBI,$engineRefId"
```

**作用**：当引擎在 ZK 中注册失败（比如网络问题），Kyuubi 仍然可以通过 Tag 在 YARN/K8s 中找到并清理它，防止孤儿进程。

---

## 第十六章 凭证管理系统（源码级）

### 16.1 为什么需要凭证管理

Spark 引擎可能是**长期运行**的（USER/GROUP/SERVER 级别下可以存活数小时甚至数天）。Kerberos 票据和 Hadoop Delegation Token 有**有效期**，过期后引擎无法访问 HDFS/Hive。

### 16.2 CredentialManager 工作机制

```scala
class CredentialManager {
  // 后台线程定期获取新的 Token
  private val renewalExecutor = Executors.newScheduledThreadPool(1)
  
  // 支持的凭证提供者
  // kyuubi.credentials.hadoopfs.enabled=true → HDFS DelegationToken
  // kyuubi.credentials.hive.enabled=true → Hive Metastore DelegationToken
  
  def start(): Unit = {
    renewalExecutor.scheduleAtFixedRate(
      () => {
        // 1. 使用 Kyuubi Server 的 Kerberos 凭证获取新 Token
        val tokens = obtainDelegationTokens()
        
        // 2. 将新 Token 写入 ZK（引擎从 ZK 拉取）
        //    或通过 Thrift RPC 直接推送给引擎
        distributeTokensToEngines(tokens)
      },
      initialDelay,
      renewalInterval,  // kyuubi.credentials.renewal.interval
      TimeUnit.MILLISECONDS
    )
  }
}
```

**Token 分发链路**：
```
Kyuubi Server (有 Kerberos keytab)
  → CredentialManager 定期获取新 DelegationToken
  → 写入 ZK 的 secret node
  → Engine 端 CredentialManager 监听 ZK 变化
  → 获取新 Token 并更新到 SparkContext.hadoopConfiguration
  → Engine 后续 HDFS/HMS 请求使用新 Token
```

---

## 第十七章 Ranger 授权集成（源码级）

### 17.1 授权链路

```
用户提交 SQL
  ↓
Spark Catalyst 解析生成 LogicalPlan
  ↓
RangerSparkExtension 拦截
  ↓
PrivilegesBuilder 分析 LogicalPlan
  → 提取：访问了哪些表、哪些列、什么操作（SELECT/INSERT/DROP...）
  → 构造 PrivilegeObject 列表
  ↓
RangerSparkPlugin 检查 Ranger 策略
  → 调用 Ranger Admin REST API 或本地缓存策略
  ↓
├── 授权通过 → 继续执行
└── 授权拒绝 → 抛出 AccessControlException
```

### 17.2 配置方式

```properties
# 在 kyuubi-defaults.conf 或 spark-defaults.conf 中
spark.sql.extensions=org.apache.kyuubi.plugin.spark.authz.ranger.RangerSparkExtension

# Ranger 服务端地址（在 ranger-spark-security.xml 中配置）
ranger.plugin.spark.service.name=kyuubi_spark
ranger.plugin.spark.policy.rest.url=http://ranger-admin:6080
```

### 17.3 支持的权限控制粒度

| 操作类型 | 示例 | 控制粒度 |
|----------|------|----------|
| 数据读取 | SELECT | 表级/列级 |
| 数据写入 | INSERT / OVERWRITE | 表级 |
| DDL | CREATE / DROP / ALTER | 库级/表级 |
| 元数据 | SHOW / DESCRIBE | 库级/表级 |
| 函数 | UDF 调用 | 函数级 |
| 管理 | GRANT / REVOKE | 策略级 |

---

## 第十八章 批处理会话（源码级）

### 18.1 批处理 vs 交互式

| 维度 | 交互式会话 (KyuubiSessionImpl) | 批处理会话 (KyuubiBatchSession) |
|------|------|------|
| 触发方式 | JDBC/Thrift 连接 | REST API 提交 |
| 引擎生命周期 | 会话期间保活 | 作业完成后自动销毁 |
| 交互模式 | 多轮 SQL 执行 | 一次性提交 |
| 状态跟踪 | SessionHandle | BatchId + MetadataStore |
| 适用场景 | Ad-hoc 查询 | ETL 批处理作业 |

### 18.2 批处理提交流程

```
POST /api/v1/batches
  Body: {
    "batchType": "spark",
    "resource": "hdfs:///jars/my-etl.jar",
    "className": "com.example.ETLJob",
    "name": "daily-etl",
    "conf": { "spark.executor.memory": "4g" },
    "args": ["--date", "2026-04-04"]
  }
  
  ↓ REST Frontend 接收
  
KyuubiSessionManager.openBatchSession()
  → new KyuubiBatchSession(resource, className, batchArgs)
  
  ↓ 创建批处理操作
  
BatchJobSubmission.runInternal()
  → SparkBatchProcessBuilder.start()
  → 提交 spark-submit --class com.example.ETLJob ...
  → 元数据写入 MetadataStore（JDBC/内存）
  
  ↓ 状态跟踪
  
GET /api/v1/batches/{batchId}
  → 查询 MetadataStore 获取状态
  → 同时查询 ApplicationManager 获取实时状态
```

### 18.3 MetadataManager — 批处理状态持久化

```scala
// 配置
// kyuubi.metadata.store.class=JDBC（默认）
// kyuubi.metadata.store.jdbc.url=jdbc:mysql://...
// kyuubi.metadata.max.age=PT72H（3天后清理）

class JDBCMetadataStore extends MetadataStore {
  // 存储批处理作业的元数据
  // 包括：batchId, state, createTime, endTime, error, engineId 等
  
  // 支持 Kyuubi Server 重启后恢复
  def getBatchSessionsToRecover(): Seq[Metadata] = {
    // 查询状态为 PENDING 或 RUNNING 的批处理
    // Server 重启后重新接管这些作业的状态监控
  }
}
```

---

## 第十九章 Kyuubi Spark SQL 扩展（源码级）

### 19.1 KyuubiSparkSQLExtension

```scala
// 配置方式
spark.sql.extensions=org.apache.kyuubi.sql.KyuubiSparkSQLExtension

// 包含的优化规则：
class KyuubiSparkSQLExtension extends SparkSessionExtensions {
  // 1. RepartitionBeforeWriteHive
  //    解决 Hive 动态分区写入产生大量小文件的问题
  //    在写入前自动 repartition
  
  // 2. InsertRepartitionBeforeWrite
  //    通用的写前重分区
  
  // 3. DropIgnoreNonexistent
  //    DROP TABLE IF EXISTS 不报错
  
  // 4. FinalStageConfigIsolation
  //    最终 Stage 独立配置
  
  // 5. RebalanceBeforeWriting (Spark 3.2+)
  //    AQE 感知的写前重平衡
  
  // 6. Z-Ordering (Spark 3.1+)
  //    数据布局优化，加速点查和范围查询
  //    语法: OPTIMIZE table ZORDER BY (col1, col2)
}
```

### 19.2 SQL 血缘解析

```scala
// 配置
spark.sql.queryExecutionListeners=org.apache.kyuubi.sql.SparkSQLLineageListener

// 工作方式：
// 1. 监听每个 SQL 的 QueryExecution
// 2. 分析 LogicalPlan 提取输入表和输出表
// 3. 以 JSON 格式写入日志
// 格式：
// {
//   "inputTables": ["db1.table1", "db2.table2"],
//   "outputTables": ["db3.result_table"],
//   "columnLineage": [
//     {"output": "result_table.col_a", "inputs": ["table1.col_x"]}
//   ]
// }
```

---

## 第二十章 多语言支持（源码级）

Spark Engine 不仅支持 SQL，还支持 Scala 和 Python 代码执行：

### 20.1 操作类型枚举

```scala
enum OperationLanguages {
  SQL,     // spark.sql(statement) — 标准 SQL
  SCALA,   // ExecuteScala — Scala REPL
  PYTHON   // ExecutePython — PySpark
}
```

### 20.2 ExecutePython 实现

```scala
class ExecutePython extends SparkOperation {
  // 通过 Py4J Gateway 与 Python 进程通信
  // 1. 启动 Python Worker 进程
  // 2. 通过 Py4J 传递 SparkSession 引用
  // 3. 执行 Python 代码
  // 4. 返回结果
  
  // 关键依赖：KyuubiPythonGatewayServer
  // 引擎停止时调用 KyuubiPythonGatewayServer.shutdown()
}
```

### 20.3 PlanOnlyMode — 仅解析/优化不执行

```scala
// 配置: kyuubi.operation.plan.only.mode=optimize
// 可选值: none(默认)/parse/analyze/optimize/physical
//
// 用途：调试 SQL 执行计划，不实际执行查询
// 示例输出（optimize 模式）：
// == Optimized Logical Plan ==
// Filter (id > 100)
// +- Relation[id, name] parquet
```

---

## 第二十一章 完整请求生命周期（源码级端到端）

将所有章节串联，展示一个 SQL 从客户端到结果返回的完整链路：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        完整请求生命周期                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. 客户端连接                                                          │
│  beeline -u "jdbc:hive2://zk1:2181/;serviceDiscoveryMode=zooKeeper"    │
│     │                                                                   │
│     │ JDBC Driver 从 ZK 获取可用 Server 地址（RandomSelect/Polling）    │
│     │ 建立 TCP 连接到 Kyuubi Server                                     │
│     ▼                                                                   │
│  2. 认证                                                                │
│  KyuubiTBinaryFrontendService                                          │
│     │ 根据 kyuubi.authentication 配置：                                 │
│     │ KERBEROS → SASL/GSSAPI 握手验证 Kerberos ticket                  │
│     │ LDAP → 连接 LDAP 服务器验证 user/password                        │
│     │ NONE → 直接通过                                                   │
│     ▼                                                                   │
│  3. 打开会话                                                            │
│  KyuubiSessionManager.openSession()                                    │
│     ├── SessionLimiter 检查并发限制                                     │
│     ├── validateAndNormalizeConf() 配置白名单/黑名单校验                │
│     ├── new KyuubiSessionImpl(user, conf)                              │
│     │                                                                   │
│     ▼                                                                   │
│  4. 启动引擎                                                            │
│  KyuubiSessionImpl.open()                                              │
│     ├── launchEngineOp（可异步）                                        │
│     │   └── EngineRef.getOrCreate(discoveryClient)                     │
│     │       ├── 构建 engineSpace 路径                                   │
│     │       │   USER 级别: /kyuubi_1.9.0_USER_SPARK_SQL/alice          │
│     │       ├── discoveryClient.getServerHost(engineSpace)             │
│     │       │   ├── 找到 → 直接复用 (热启动 < 1s)                      │
│     │       │   └── 未找到 → create()                                   │
│     │       │       ├── tryWithLock() 获取 ZK 分布式锁                  │
│     │       │       ├── Double-Check: 再查一次                          │
│     │       │       ├── semaphore.acquire() 限制并发启动数              │
│     │       │       ├── SparkProcessBuilder.start()                    │
│     │       │       │   → spark-submit --class SparkSQLEngine ...      │
│     │       │       │   → YARN/K8s 分配资源                             │
│     │       │       │   → Driver 启动 SparkSQLEngine.main()            │
│     │       │       │   → 创建 SparkSession                            │
│     │       │       │   → 初始化 Backend + Frontend 服务                │
│     │       │       │   → 在 ZK 注册引擎地址                           │
│     │       │       ├── 轮询 ZK 等待引擎注册                           │
│     │       │       │   超时: engine.initialize.timeout (默认 3min)     │
│     │       │       │   快速失败: 检测 YARN app 状态                    │
│     │       │       └── semaphore.release()                            │
│     │       └── 返回 (host, port)                                      │
│     │                                                                   │
│     └── openEngineSession()                                            │
│         ├── KyuubiSyncThriftClient.createClient(host, port)            │
│         ├── client.openSession() → 引擎端创建 SparkSession             │
│         │   USER 级别: spark.newSession() (独立临时视图/UDF/配置)       │
│         │   CONNECTION: 直接用根 SparkSession                          │
│         └── 重试机制: 最多 9 次, 间隔递增                              │
│                                                                         │
│  5. 执行 SQL                                                            │
│  beeline> SELECT * FROM db.table WHERE id > 100;                       │
│     │                                                                   │
│     │ Thrift RPC: ExecuteStatement                                      │
│     ▼                                                                   │
│  KyuubiSessionImpl.executeStatement()                                  │
│     ├── parser.parsePlan(sql)                                          │
│     │   ├── RunnableCommand (SET/USE) → ExecuteOnServerOperation       │
│     │   │   → Server 端直接执行，不走引擎                               │
│     │   └── 普通 SQL → 转发给引擎                                       │
│     │                                                                   │
│     └── client.executeStatement(sql) [Thrift RPC 到引擎]               │
│         ↓                                                               │
│  ┌──── Engine 端 ────────────────────────────────────────────┐         │
│  │  ExecuteStatement.executeStatement()                       │         │
│  │     │                                                      │         │
│  │     ├── Ranger 授权检查（如果启用）                         │         │
│  │     │   RangerSparkExtension → PrivilegesBuilder           │         │
│  │     │   → 检查用户是否有权访问 db.table                    │         │
│  │     │                                                      │         │
│  │     ├── spark.sql("SELECT * FROM db.table WHERE id > 100") │         │
│  │     │   → Catalyst Parser: 解析 SQL 为 LogicalPlan        │         │
│  │     │   → Analyzer: 绑定表元数据 (查询 Hive Metastore)    │         │
│  │     │   → Optimizer: 谓词下推/列裁剪/AQE 自适应优化       │         │
│  │     │   → SparkPlanner: 生成物理计划                       │         │
│  │     │   → 提交 Spark Job 到 Executor 集群执行             │         │
│  │     │                                                      │         │
│  │     └── collectAsIterator(result)                          │         │
│  │         ├── 增量模式 → toLocalIterator() (大数据量)        │         │
│  │         ├── 落盘模式 → 写 ORC 文件 (超大结果集)           │         │
│  │         └── 内存模式 → collect() 或 take(n) (小数据量)    │         │
│  └────────────────────────────────────────────────────────────┘         │
│     │                                                                   │
│  6. 返回结果                                                            │
│     │ Thrift RPC: FetchResults                                          │
│     │ → 分批返回 TRowSet (每批 maxFetchSize 行)                        │
│     ▼                                                                   │
│  beeline 显示查询结果                                                   │
│                                                                         │
│  7. 关闭会话                                                            │
│  beeline> !quit                                                         │
│     │                                                                   │
│     ├── KyuubiSessionImpl.close()                                      │
│     │   ├── client.closeSession() → 引擎端关闭 SparkSession            │
│     │   ├── credentialManager.removeSessionCredentials()                │
│     │   └── sessionLimiter.decrement()                                  │
│     │                                                                   │
│     └── 引擎后续行为（取决于 Share Level）                              │
│         ├── CONNECTION → 引擎立即停止                                   │
│         ├── USER → 引擎继续存活 idle.timeout 时间                      │
│         │          期间新连接可以直接复用                                │
│         │          超时后：从 ZK 注销 → 优雅关闭 → SparkContext.stop()  │
│         └── SERVER → 引擎持续运行，除非手动停止                        │
│                                                                         │
│  8. 引擎监控（贯穿全程）                                               │
│     ├── engineConnectionAliveChecker: 定期 ping 引擎                   │
│     ├── KyuubiApplicationManager: 通过 YARN/K8s API 监控进程状态       │
│     ├── CredentialManager: 定期刷新 Hadoop/Hive Token                  │
│     └── MetricsSystem: 上报指标到 Prometheus/JMX                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 附录 A：核心源码文件速查表

| 源码文件 | 包路径 | 核心职责 |
|----------|--------|----------|
| **KyuubiServer.scala** | server/ | Server 主入口，组装所有子服务 |
| **KyuubiBackendService.scala** | server/ | 后端服务，持有 SessionManager |
| **KyuubiSessionManager.scala** | session/ | 会话管理中心，引擎分配调度 |
| **KyuubiSessionImpl.scala** | session/ | 交互式会话，SQL 路由（Server/Engine） |
| **KyuubiBatchSession.scala** | session/ | 批处理会话，REST API 提交 |
| **EngineRef.scala** | engine/ | ★★★ 引擎分配核心算法 |
| **ProcBuilder.scala** | engine/ | 进程构建器抽象基类 |
| **SparkProcessBuilder.scala** | engine/spark/ | spark-submit 命令构建 |
| **KyuubiApplicationManager.scala** | engine/ | 引擎应用生命周期管理 |
| **ApplicationOperation.scala** | engine/ | 资源管理器操作接口 |
| **YarnApplicationOperation.scala** | engine/ | YARN 应用操作实现 |
| **KubernetesApplicationOperation.scala** | engine/ | K8s Pod 操作实现 |
| **SparkSQLEngine.scala** | engine/spark/ | 引擎端主入口 |
| **SparkSQLSessionManager.scala** | engine/spark/session/ | 引擎端会话管理 |
| **ExecuteStatement.scala** | engine/spark/operation/ | SQL 执行核心 |
| **ArrowBasedExecuteStatement.scala** | engine/spark/operation/ | Arrow 格式结果优化 |
| **DiscoveryClient.scala** | ha/client/ | 服务发现接口（ZK/Etcd） |
| **ZookeeperDiscoveryClient.scala** | ha/client/zookeeper/ | ZK 实现 |
| **KyuubiConf.scala** | config/ | 所有配置项定义中心 |
| **Serverable.scala** | server/ | Server/Engine 公共抽象层 |
| **TFrontendService.scala** | service/ | Thrift 前端服务基类 |
| **SessionsResource.scala** | server/api/v1/ | REST API 会话端点 |
| **KyuubiSparkSQLExtension.scala** | extensions/spark/ | Spark SQL 扩展规则 |
| **RangerSparkExtension.scala** | plugin/spark/authz/ | Ranger 授权拦截 |

## 附录 B：与 HS2 知识库的源码级交叉关联

| Kyuubi 源码 | 对应 HS2 问题 | 深层关联 |
|-------------|-------------|---------|
| `KyuubiSessionManager.execPool (默认100)` | HS2 `backgroundOperationPool` RejectedExecution | 相同设计模式，相同风险点。Kyuubi 通过 `BACKEND_SERVER_EXEC_POOL_SIZE` 控制 |
| `KyuubiSessionImpl.close()` | HS2 `CLOSE_SESSION_ON_DISCONNECT=false` 导致 Session 积累 | Kyuubi 的 CONNECTION 级别会立即销毁引擎，USER 级别依赖 `session.idle.timeout` |
| `SparkSQLSessionManager.userIsolatedCache` | HS2 `HiveSessionImpl` MetaStoreClient 泄漏 | Kyuubi 使用引用计数+LRU 管理 SparkSession，比 HS2 更精细 |
| `EngineRef.create()` 分布式锁 | HS2 无此机制，多 HS2 实例会重复创建 Spark Thrift Server | Kyuubi 用 ZK `InterProcessSemaphoreMutex` 解决并发创建 |
| `ExecuteStatement.collectAsIterator()` | HS2 大结果集 OOM | Kyuubi 提供增量/落盘/内存三种策略，HS2 只有内存模式 |
| `SparkSQLEngine.startIdleTerminatingChecker()` | HS2 连接池不回收 | Kyuubi 主动监测空闲引擎并销毁，HS2 依赖外部运维 |
| `CredentialManager` Token 自动刷新 | HS2 Kerberos ticket 过期导致 HMS 连接失败 | Kyuubi 内置了完整的凭证生命周期管理 |
| `KyuubiApplicationManager` | HS2 无引擎进程管理 | Kyuubi 通过 YARN/K8s API 主动监控和清理引擎进程 |

---

> 本手册基于 Kyuubi master 分支源码 (commit ba854d3c) 深度阅读整理。
> 六层学习法应用：L1定位 → L2主链路 → L3核心算法逐行 → L4对称阅读 → L5交叉关联 → L6输出倒逼。
> 持续更新中：Flink Engine 实现、JDBC Engine、Chat Engine(LLM) 等模块待后续深入。
