# Kyuubi Server 多租户引擎源码分析

> **源码路径**：`txProjects/incubator-kyuubi/kyuubi-server/src/main/scala/org/apache/kyuubi/server/KyuubiServer.scala`（9.29 KB）
> **铁律遵守**：所有方法名、行号引用均来自上述真实源码

---

## 一、Kyuubi 定位

Apache Kyuubi 是**多租户企业级 Spark/Flink/Trino SQL 网关**：
- 兼容 HiveServer2 Thrift 协议（用户无感切换）
- 支持 USER / GROUP / SERVER 三级 Engine 复用策略
- 提供 REST、MySQL、Trino 多协议入口
- 内置 ZK 服务发现，支持负载均衡

---

## 二、KyuubiServer 双层结构

源文件分两层：
1. **`object KyuubiServer`** — 单例伴生对象（main 入口、全局配置管理）
2. **`class KyuubiServer`** — 服务实例（继承 Serverable 服务框架）

---

## 三、main 启动入口（KyuubiServer.scala:73-101）

```scala
73: def main(args: Array[String]): Unit = {
74:   info(
75:     """
76:       |                  Welcome to
77:       |  __  __                           __
   ...
86:      """.stripMargin)
87:   info(s"Version: $KYUUBI_VERSION, Revision: $REVISION ($REVISION_TIME), Branch: $BRANCH," +
88:     s" Java: $JAVA_COMPILE_VERSION, Scala: $SCALA_COMPILE_VERSION," +
89:     s" Spark: $SPARK_COMPILE_VERSION, Hadoop: $HADOOP_COMPILE_VERSION," +
90:     s" Hive: $HIVE_COMPILE_VERSION, Flink: $FLINK_COMPILE_VERSION," +
91:     s" Trino: $TRINO_COMPILE_VERSION")
   ...
94:   SignalRegister.registerLogger(logger)
95:
96:   // register conf entries
97:   JDBCMetadataStoreConf
98:   val conf = new KyuubiConf().loadFileDefaults()
99:   UserGroupInformation.setConfiguration(KyuubiHadoopUtils.newHadoopConf(conf))
100:   startServer(conf)
101: }
```

**4 步启动**：
1. **打 Banner + 版本信息**（启动日志快速定位编译版本依赖）
2. **SignalRegister.registerLogger()** — 注册 SIGTERM/SIGINT 优雅关闭
3. **`JDBCMetadataStoreConf`** — 触发 conf entries 注册（隐式静态初始化）
4. **`UserGroupInformation.setConfiguration()`** — 初始化 Hadoop UGI（Kerberos 准备）

---

## 四、startServer 核心方法（KyuubiServer.scala:44-71）

```scala
44: def startServer(conf: KyuubiConf): KyuubiServer = {
45:   hadoopConf = KyuubiHadoopUtils.newHadoopConf(conf)
46:   var embeddedZkServer: Option[EmbeddedZookeeper] = None
47:   if (!ServiceDiscovery.supportServiceDiscovery(conf)) {
48:     embeddedZkServer = Some(new EmbeddedZookeeper())
49:     embeddedZkServer.foreach(zkServer => {
50:       zkServer.initialize(conf)
51:       zkServer.start()
52:       conf.set(HA_ADDRESSES, zkServer.getConnectString)
53:       conf.set(HA_ZK_AUTH_TYPE, AuthTypes.NONE.toString)
54:     })
55:   }
56:
57:   val server = conf.get(KyuubiConf.SERVER_NAME) match {
58:     case Some(s) => new KyuubiServer(s)
59:     case _ => new KyuubiServer()
60:   }
61:   try {
62:     server.initialize(conf)
63:   } catch {
64:     case e: Exception =>
65:       embeddedZkServer.filter(_.getServiceState == ServiceState.STARTED).foreach(_.stop())
66:       throw e
67:   }
68:   server.start()
69:   Utils.addShutdownHook(() => server.stop(), Utils.SERVER_SHUTDOWN_PRIORITY)
70:   server
71: }
```

**核心逻辑**：
1. **EmbeddedZookeeper 兜底**：如果用户没配 ZK，启动一个内嵌 ZK（开发场景）
2. **服务实例创建**：根据 `kyuubi.server.name` 决定服务名
3. **三段式生命周期**：`initialize → start → stop`（继承 Hadoop Service 模式）
4. **Shutdown Hook**：JVM 退出时优雅关闭

> **生产坑点**：EmbeddedZookeeper 默认监听 `2181`，多实例部署会冲突。生产必须显式配置外部 ZK 集群。

---

## 五、class KyuubiServer 定义（KyuubiServer.scala:174-196）

```scala
174: class KyuubiServer(name: String) extends Serverable(name) {
175:
176:   def this() = this(classOf[KyuubiServer].getSimpleName)
177:
178:   override val backendService: AbstractBackendService =
179:     new KyuubiBackendService() with BackendServiceMetric
180:
181:   override lazy val frontendServices: Seq[AbstractFrontendService] =
182:     conf.get(FRONTEND_PROTOCOLS).map(FrontendProtocols.withName).map {
183:       case THRIFT_BINARY => new KyuubiTBinaryFrontendService(this)
184:       case THRIFT_HTTP => new KyuubiTHttpFrontendService(this)
185:       case REST =>
186:         warn("REST frontend protocol is experimental, API may change in the future.")
187:         new KyuubiRestFrontendService(this)
188:       case MYSQL =>
189:         warn("MYSQL frontend protocol is experimental.")
190:         new KyuubiMySQLFrontendService(this)
191:       case TRINO =>
192:         warn("Trino frontend protocol is experimental.")
193:         new KyuubiTrinoFrontendService(this)
194:       case other =>
195:         throw new UnsupportedOperationException(s"Frontend protocol $other is not supported yet.")
196:     }
```

### 5.1 BackendService — 真正的业务实现

```scala
178:   override val backendService: AbstractBackendService =
179:     new KyuubiBackendService() with BackendServiceMetric
```

`KyuubiBackendService` 内部委托给 `KyuubiSessionManager` + `KyuubiOperationManager`，实现 SQL 执行的真正逻辑。

### 5.2 FrontendService — 多协议入口

| 协议 | 实现类 | 状态 |
|------|--------|------|
| THRIFT_BINARY | KyuubiTBinaryFrontendService | ✅ Stable（HiveServer2 兼容） |
| THRIFT_HTTP | KyuubiTHttpFrontendService | ✅ Stable |
| REST | KyuubiRestFrontendService | 🟡 Experimental |
| MYSQL | KyuubiMySQLFrontendService | 🟡 Experimental |
| TRINO | KyuubiTrinoFrontendService | 🟡 Experimental |

**多协议同时启用**：用户可以同时开 Thrift（BI 工具）+ REST（程序化）+ MySQL（DBA 工具）。

---

## 六、initialize 服务装配（KyuubiServer.scala:198-217）

```scala
198: override def initialize(conf: KyuubiConf): Unit = synchronized {
199:   val kinit = new KinitAuxiliaryService()
200:   addService(kinit)                                      // ⭐ 自动 kinit
201:
202:   val periodicGCService = new PeriodicGCService
203:   addService(periodicGCService)                           // ⭐ 周期 GC
204:
205:   if (conf.get(MetricsConf.METRICS_ENABLED)) {
206:     addService(new MetricsSystem)
207:   }
208:
209:   if (conf.isRESTEnabled && conf.get(BATCH_SUBMITTER_ENABLED)) {
210:     addService(new KyuubiBatchService(
211:       this,
212:       backendService.sessionManager.asInstanceOf[KyuubiSessionManager]))
213:   }
214:   super.initialize(conf)                                  // ⭐ 调父类初始化（含 backend + frontend）
215:
216:   initLoggerEventHandler(conf)
217: }
```

**4 个增值服务**：
1. **KinitAuxiliaryService** — 后台周期 kinit 续期（Kerberos 长期有效）
2. **PeriodicGCService** — 周期触发 `System.gc()`（用于 long-running 服务避免内存碎片）
3. **MetricsSystem** — Prometheus / JMX / SLF4J 多种 Reporter
4. **KyuubiBatchService** — REST 批模式提交（spark-submit 替代）

---

## 七、start / stop（KyuubiServer.scala:219-228）

```scala
219: override def start(): Unit = {
220:   super.start()
221:   KyuubiServer.kyuubiServer = this                          // ⭐ 设置全局单例
222:   KyuubiServerInfoEvent(this, ServiceState.STARTED).foreach(EventBus.post)
223: }
224:
225: override def stop(): Unit = {
226:   KyuubiServerInfoEvent(this, ServiceState.STOPPED).foreach(EventBus.post)
227:   super.stop()
228: }
```

**EventBus 推送**：每次状态变更触发 ServerInfoEvent，可被外部监听器（审计、监控）订阅。

---

## 八、配置热更新机制

KyuubiServer.scala:107-171 实现了多种配置热更新接口：

### 8.1 Hadoop Conf 热更新（KyuubiServer.scala:107-110）

```scala
107: private[kyuubi] def reloadHadoopConf(): Unit = synchronized {
108:   val _hadoopConf = KyuubiHadoopUtils.newHadoopConf(new KyuubiConf().loadFileDefaults())
109:   hadoopConf = _hadoopConf
110: }
```

### 8.2 用户默认配置热更新（KyuubiServer.scala:112-116）

```scala
112: private[kyuubi] def refreshUserDefaultsConf(): Unit = kyuubiServer.conf.synchronized {
113:   val existedUserDefaults = kyuubiServer.conf.getAllUserDefaults
114:   val refreshedUserDefaults = KyuubiConf().loadFileDefaults().getAllUserDefaults
115:   refreshConfig("user defaults", existedUserDefaults, refreshedUserDefaults)
116: }
```

### 8.3 K8s 配置热更新（KyuubiServer.scala:118-124）

```scala
118: private[kyuubi] def refreshKubernetesConf(): Unit = kyuubiServer.conf.synchronized {
119:   val existedKubernetesConf =
120:     kyuubiServer.conf.getAll.filter(_._1.startsWith(KYUUBI_KUBERNETES_CONF_PREFIX))
121:   val refreshedKubernetesConf =
122:     KyuubiConf().loadFileDefaults().getAll.filter(_._1.startsWith(KYUUBI_KUBERNETES_CONF_PREFIX))
123:   refreshConfig("kubernetes", existedKubernetesConf, refreshedKubernetesConf)
124: }
```

### 8.4 黑白名单热更新（KyuubiServer.scala:149-171）

```scala
149: private[kyuubi] def refreshUnlimitedUsers(): Unit = synchronized {
150:   val sessionMgr = kyuubiServer.backendService.sessionManager.asInstanceOf[KyuubiSessionManager]
151:   val existingUnlimitedUsers = sessionMgr.getUnlimitedUsers
152:   sessionMgr.refreshUnlimitedUsers(KyuubiConf().loadFileDefaults())
   ...
157: private[kyuubi] def refreshDenyUsers(): Unit = synchronized {
   ...
165: private[kyuubi] def refreshDenyIps(): Unit = synchronized {
```

**生产价值**：无需重启即可：
- 加白用户（避开并发限制）
- 拉黑用户/IP（紧急熔断）
- 切换 Hadoop 配置（如更新 keytab）

通过 REST API `/api/v1/admin/refresh/...` 触发。

---

## 九、KyuubiServer 服务全景

```
┌──────────────────────────────────────────────────────────┐
│ KyuubiServer extends Serverable                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ FrontendServices (多协议入口)                       │  │
│  │  ┌──────────┐ ┌──────────┐ ┌────┐ ┌────┐ ┌─────┐  │  │
│  │  │ Thrift   │ │ Thrift   │ │REST│ │MYSQL│ │TRINO│  │  │
│  │  │ Binary   │ │ HTTP     │ │    │ │     │ │     │  │  │
│  │  │ (10009)  │ │ (10010)  │ │10099│ │3306 │ │8090 │  │  │
│  │  └──────────┘ └──────────┘ └────┘ └────┘ └─────┘  │  │
│  └────────────────────────────────────────────────────┘  │
│                          │                                │
│                          ▼                                │
│  ┌────────────────────────────────────────────────────┐  │
│  │ BackendService (KyuubiBackendService)              │  │
│  │  ┌──────────────────┐  ┌─────────────────────┐    │  │
│  │  │ KyuubiSessionMgr │  │ KyuubiOperationMgr  │    │  │
│  │  │ - User Sessions  │  │ - SQL/SCALA/Python  │    │  │
│  │  │ - Engine Mapping │  │   Operations        │    │  │
│  │  └──────────────────┘  └─────────────────────┘    │  │
│  └────────────────────────────────────────────────────┘  │
│                          │                                │
│                          ▼                                │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Engine 池 (Spark/Flink/Trino)                      │  │
│  │  USER 共享 / GROUP 共享 / SERVER 共享 / CONNECTION  │  │
│  │  通过 ZooKeeper 服务发现复用                        │  │
│  └────────────────────────────────────────────────────┘  │
│                                                           │
│  辅助服务：                                                │
│  - KinitAuxiliaryService（Kerberos 续期）                 │
│  - PeriodicGCService（周期 GC）                           │
│  - MetricsSystem（监控）                                  │
│  - KyuubiBatchService（REST 批提交）                      │
│  - EmbeddedZookeeper（开发兜底）                          │
└──────────────────────────────────────────────────────────┘
```

---

## 十、Engine 共享级别

Kyuubi 的核心创新是 **Engine 复用**：

| 级别 | 配置 | 复用粒度 | 适用场景 |
|------|------|---------|---------|
| `CONNECTION` | 默认 | 单 SQL Session | 一次性查询 |
| `USER` | 推荐 | 同用户共享 | 多 BI 查询 |
| `GROUP` | 高级 | 同组共享 | 团队协作 |
| `SERVER` | 慎用 | 全局共享 | 资源极度紧张 |

**配置项**：`kyuubi.engine.share.level=USER`

**底层实现**：通过 ZooKeeper 路径 `/kyuubi/{level}/{user}/spark` 实现服务发现。

---

## 十一、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `kyuubi.frontend.protocols` | THRIFT_BINARY | 前端协议（多个用逗号） |
| `kyuubi.engine.share.level` | USER | Engine 共享级别 |
| `kyuubi.engine.type` | SPARK_SQL | 引擎类型 |
| `kyuubi.session.engine.idle.timeout` | PT30M | Engine 空闲超时 |
| `kyuubi.ha.addresses` | - | ZK 地址（多实例 HA） |
| `kyuubi.kinit.interval` | PT1H | Kerberos 续期间隔 |

---

## 十二、Eric 点评

Kyuubi 是**国内开源大数据界的明星项目**，原网易有道孵化，2021 进入 Apache 孵化，2022 毕业。它的核心价值：

1. **填补 HiveServer2 → 现代引擎的鸿沟** — 用户用 Beeline / DBeaver 无感切换到 Spark / Flink / Trino
2. **多租户隔离 + Engine 复用** — USER 级共享既隔离又节省资源
3. **零侵入** — 不修改 Spark/Flink 源码，纯外挂网关
4. **多协议支持** — REST / MySQL / Trino 协议拓宽接入面

源码层面观察：
- **Scala 服务框架优雅**：Serverable 三段式生命周期，addService 装配
- **配置热更新完整**：黑名单、用户默认、Hadoop conf、K8s conf 全可热更
- **EventBus 解耦**：事件驱动便于审计扩展
- **依赖隔离**：通过编译期版本注入，避免与用户 Spark/Flink 版本冲突

对比 Apache Livy（HDP 时代的 REST gateway）：
- Livy：单 Session = 单 SparkContext（资源浪费）
- Kyuubi：多 Session 复用 Engine（资源节省 5-10x）

理解 Kyuubi 的"网关 + 复用 + 多租户"模式，是理解现代数据中台架构的钥匙。它的设计哲学也被腾讯 SuperSQL、阿里 DLA 等商业产品借鉴。
