# Kyuubi SparkSQLEngine 与 Operation 管理 — L4 源码深度分析

> **源码版本**：Apache Kyuubi master 分支（2026-04, commit ba854d3c）
> **段位目标**：L4 创造者/科学家
> **方法论**：源码精通九大法则 × 费曼三层输出
> **本文重点**：Spark SQL Engine 启动全链路、SQL 执行核心、Operation 状态机、WatchDog 熔断

---

## 阅读导航

| 模块 | 白话版 | 架构版 | 论文版 | 对抗性分析 | 考古追溯 |
|------|--------|--------|--------|-----------|---------|
| SparkSQLEngine 启动 | [§1.1](#11-白话版费曼-l1) | [§1.2](#12-架构版费曼-l2) | [§1.3](#13-论文版费曼-l3) | [§1.4](#14-对抗性分析) | [§1.5](#15-考古追溯) |
| SQL 执行 & Operation | [§2.1](#21-白话版费曼-l1) | [§2.2](#22-架构版费曼-l2) | [§2.3](#23-论文版费曼-l3) | [§2.4](#24-对抗性分析) | [§2.5](#25-考古追溯) |
| WatchDog & 扩展 | — | [§3.1](#31-架构版) | — | [§3.2](#32-对抗性分析) | — |

---

# 模块一：SparkSQLEngine 启动与会话管理

## 1.1 白话版（费曼 L1）

> **给完全不懂的人讲**

SparkSQLEngine 就像一个**远程厨房**：

1. **开火**（main 方法）：先检查煤气表有没有超时（ENGINE_INIT_TIMEOUT），然后点火烧水（创建 SparkSession），准备好锅碗瓢盆（初始化 Backend + Frontend 服务）
2. **挂牌营业**（ZK 注册）：在美团上挂上地址，让 Kyuubi Server（调度中心）知道"我准备好了"
3. **接单做菜**（处理 SQL）：调度中心转发客户的菜单（SQL），厨房解析后做菜（Spark 执行），做好后通过传菜口送出去（返回结果）
4. **下班关门**（引擎终止）：
   - 没客人了等一会儿就关（IdleTimeout）
   - 干了太久必须关（MaxLifetime）
   - 客人都走了且是独享厨房就关（CONNECTION 级别）

**SparkSession 隔离**就像厨房里的灶台：
- CONNECTION 级别：整个厨房只有一个灶台（独占）
- USER 级别：每个客人分一个灶台，共用厨房（`spark.newSession()`）
- SERVER 级别：老客户复用之前的灶台（用户隔离缓存）

---

## 1.2 架构版（费曼 L2）

### 1.2.1 SparkSQLEngine 启动全流程

```
SparkSQLEngine.main()
  │
  ├── ① 超时检查
  │     submitTime = spark.kyuubi.engine.submit.time
  │     if (now - submitTime > ENGINE_INIT_TIMEOUT) throw timeout
  │     启动 CreateSparkTimeoutChecker 守护线程
  │
  ├── ② createSpark()
  │     setupConf()  // spark.kyuubi.xxx → kyuubi.xxx 配置映射
  │     SparkSession.builder.config(_sparkConf).getOrCreate()
  │     处理 Delegation Token 安全凭证
  │     执行 ENGINE_SPARK_INITIALIZE_SQL (默认 "SHOW DATABASES")
  │
  ├── ③ startEngine(spark)
  │     engine = new SparkSQLEngine(spark)
  │     engine.initialize()
  │       ├── 注册 SparkSQLEngineListener (Job 状态追踪)
  │       ├── 注册 SparkSQLEngineEventListener (事件追踪)
  │       └── super.initialize() // Serverable 级联初始化
  │             ├── SparkSQLBackendService.init()
  │             │     └── SparkSQLSessionManager.init()
  │             └── SparkTBinaryFrontendService.init()
  │                   └── EngineServiceDiscovery.init()
  │
  │     engine.start()
  │       ├── super.start() // 级联启动
  │       │     ├── SparkSQLBackendService.start()
  │       │     │     └── SparkSQLSessionManager.start()
  │       │     └── SparkTBinaryFrontendService.start()
  │       │           ├── 绑定 Thrift 端口
  │       │           └── EngineServiceDiscovery.start()
  │       │                 └── ZK 创建临时节点（引擎注册）
  │       │
  │       ├── 启动 IdleTerminatingChecker (空闲超时)
  │       ├── 启动 MaxLifetimeChecker (最大生命周期)
  │       ├── 启动 FastFailChecker (CONNECTION 级别)
  │       └── 注册 Spark UI KyuubiEngineTab
  │
  └── ④ countDownLatch.await()  // 阻塞主线程，引擎持续运行
```

### 1.2.2 超时保护双重机制

```scala
// 机制一：总初始化超时
val totalInitTimeout = kyuubiConf.get(ENGINE_INIT_TIMEOUT)
if (System.currentTimeMillis() - submitTime > totalInitTimeout)
  throw new KyuubiException("Engine init timeout")

// 机制二：CreateSpark 超时守护线程
// 防止 SparkSession.getOrCreate() 因 YARN 资源不足无限阻塞
// 守护线程在超时后中断主线程 → main 方法抛 InterruptedException → 进程退出
```

**设计意图**：双重超时防止"僵尸引擎"。机制一检查总耗时，机制二针对 SparkSession 创建这个最容易卡住的阶段。

### 1.2.3 SparkSQLSessionManager — 会话隔离策略

```
singleSparkSession = true?
  ├── YES → 所有连接共享根 SparkSession
  └── NO  → 按 ENGINE_SHARE_LEVEL 决策：
      ├── CONNECTION → 共享根 Session，关闭时 stopEngine()
      ├── USER → 每次 spark.newSession() (独立临时视图/UDF/配置)
      └── GROUP/SERVER → userIsolatedSparkSession?
            ├── YES → 同 USER，每次新建
            └── NO  → 用户隔离缓存
                      ConcurrentHashMap<user, SparkSession>
                      引用计数 + 空闲超时回收
```

**用户隔离缓存机制**：
```scala
private val userIsolatedCache = new ConcurrentHashMap[String, SparkSession]
private val userIsolatedCacheCount = new ConcurrentHashMap[String, (AtomicInteger, AtomicLong)]
//                                              用户名        (引用计数, 最后访问时间)

// 获取/创建 SparkSession
def getOrNewSparkSession(user: String): SparkSession = {
  userIsolatedCache.computeIfAbsent(user, _ => spark.newSession())
  cacheCount.get(user).refCount.incrementAndGet()
  return userIsolatedCache.get(user)
}

// 关闭时减少引用计数
def closeSession(): Unit = {
  cacheCount.get(user).refCount.decrementAndGet()
  cacheCount.get(user).lastAccessTime.set(now())
}

// 后台清理线程：引用计数 = 0 且空闲超时 → 回收 SparkSession
```

### 1.2.4 生命周期检查器

```
引擎运行中的三个守护线程：

1. IdleTerminatingChecker:
   if (activeSessionCount == 0 && idleTime > ENGINE_IDLE_TIMEOUT)
     → gracefulStop()

2. MaxLifetimeChecker:
   if (uptime > ENGINE_SPARK_MAX_LIFETIME)
     → deregisterFromZK() → 等待 gracefulPeriod → forceStop()

3. FastFailChecker (仅 CONNECTION 级别):
   if (noConnectionAfterInit && timeout > MAX_INIT_TIMEOUT)
     → stop()  // 引擎启动后无人连接，快速释放资源
```

### 1.2.5 优雅停机流程

```
gracefulStop():
  1. frontendServices.discoveryService.stop()  // ZK 注销，不再接受新连接
  2. while (activeSessionCount > 0 && elapsed < gracefulPeriod):
       Thread.sleep(1000)                       // 等待现有会话完成
  3. engine.stop()
       → SparkSQLSessionManager.stop()
       → SparkTBinaryFrontendService.stop()
       → SparkContext.stop()                    // 停止 Spark
  4. countDownLatch.countDown()                  // 唤醒主线程退出
```

---

## 1.3 论文版（费曼 L3）

### 1.3.1 SparkSession 隔离级别的内存模型

`spark.newSession()` 创建的 Session 与根 Session 的关系：

| 组件 | 是否共享 | 说明 |
|------|---------|------|
| SparkContext | **共享** | 唯一，管理 Executor 资源 |
| Catalog | **共享** | 同一 Hive Metastore |
| SessionState | **独立** | SQL 解析器/优化器实例 |
| 临时视图 | **独立** | 每个 Session 有自己的临时视图 |
| UDF | **独立** | 每个 Session 可注册不同 UDF |
| SQL 配置 | **独立** | SET 命令只影响当前 Session |
| SparkConf | **共享** | Spark 运行时配置（不可变） |

**内存开销**：`newSession()` ≈ 10-50MB（SessionState + 临时视图缓存），远小于 SparkContext（500MB-2GB）。这是 USER 级别共享引擎的基础 — 多个 Session 共享一个 SparkContext 的资源。

### 1.3.2 引擎终止条件的形式化

令：
- \( A(t) \) = 时刻 t 的活跃会话数
- \( T_{idle} \) = 空闲超时配置
- \( T_{max} \) = 最大生命周期配置
- \( t_0 \) = 引擎启动时间
- \( t_l \) = 最后一个会话关闭时间

引擎终止条件：

\[
terminate(t) = (A(t) = 0 \wedge t - t_l > T_{idle}) \vee (t - t_0 > T_{max})
\]

**优先级**：MaxLifetime 触发 > IdleTimeout 触发 > CONNECTION 关闭触发

### 1.3.3 与 Spark Thrift Server (STS) 的对比

| 维度 | Kyuubi SparkSQLEngine | Spark Thrift Server |
|------|----------------------|---------------------|
| 部署模型 | 按需创建，多实例 | 长期运行，单实例 |
| 资源隔离 | 多级 ShareLevel | 无隔离 |
| SparkSession | newSession() 独立 | 单一 Session |
| 生命周期 | 自动终止（idle/max） | 手动管理 |
| 结果集 | 三种模式（内存/增量/落盘） | 仅内存 |
| 版本管理 | 多引擎版本并存 | 固定版本 |

---

## 1.4 对抗性分析

### 1.4.1 并发竞态：用户隔离缓存的线程安全

**场景**：两个 Session 同时为同一用户创建 SparkSession。

```java
// ConcurrentHashMap.computeIfAbsent 保证原子性
userIsolatedCache.computeIfAbsent(user, _ => spark.newSession())
```

**分析**：`computeIfAbsent` 对同一 key 是线程安全的（内部 synchronized 该 key 的 hash bucket）。不会创建两个 SparkSession。

### 1.4.2 异常路径：SparkSession 创建失败

**场景**：`spark.newSession()` 在 GROUP/SERVER 级别下失败（如 Metastore 不可达）。

```
后果：
  ├── computeIfAbsent 中的 lambda 抛异常 → 不会存入缓存
  ├── Session 创建失败 → 客户端收到错误
  ├── 后续相同用户的请求会重试 newSession()
  └── 如果 Metastore 恢复 → 正常创建
```

**风险**：无泄漏。异常 Session 不会被缓存。

### 1.4.3 资源泄漏：引用计数不正确

**场景**：Session 在 `getOrNewSparkSession` 中成功但在后续处理中异常，`closeSession` 未被调用。

```
refCount.incrementAndGet() → 成功
... 后续异常 ...
refCount.decrementAndGet() → 未执行
```

**结果**：引用计数永远大于 0，该用户的 SparkSession 永远不会被回收。

> **缓解**：Kyuubi 的 Session 超时清理器会最终关闭过期 Session，触发 `closeSession` → `decrementAndGet`。但如果 Session 刚创建就异常（未注册到 handleToSession），则真的泄漏。

### 1.4.4 OOM 风险：结果集内存收集

```scala
// 默认模式：df.collect() 全量加载到 Driver
new ArrayFetchIterator(result.collect())
// 如果结果集有 1 亿行 → Driver OOM
```

**三种模式的 OOM 风险**：

| 模式 | 触发条件 | OOM 风险 |
|------|---------|---------|
| 内存模式 | 默认 | **高**（全量 collect） |
| 增量模式 | `incrementalCollect=true` | 低（逐批拉取） |
| 落盘模式 | `saveToFile=true` | 极低（写 ORC 文件） |

> **生产建议**：必须设置 `OPERATION_RESULT_MAX_ROWS` 限制返回行数，或启用增量/落盘模式。

---

## 1.5 考古追溯

### 1.5.1 双重超时机制的由来

**背景**：早期只有 `ENGINE_INIT_TIMEOUT` 一个超时。但在 YARN 资源紧张时，`SparkSession.getOrCreate()` 内部会阻塞在 `YarnClientApplication.createApplication()`，此时引擎进程已存在但无法被 Kyuubi Server 超时检测到（因为进程是 alive 的）。

**解决方案**：引入 `CreateSparkTimeoutChecker` 守护线程，在 SparkSession 创建阶段独立计时，超时后中断主线程。

### 1.5.2 结果集三种模式的演化

| 版本 | 支持的模式 |
|------|-----------|
| 1.0 | 仅内存模式（df.collect()） |
| 1.4 | + 增量模式（toLocalIterator） |
| 1.6 | + 落盘模式（写 ORC/Parquet） |

**驱动力**：大量生产事故报告 Driver OOM，社区逐步引入低内存消耗的结果收集方式。

### 1.5.3 用户隔离缓存的引入

**背景**：SERVER 级别下，所有用户共享一个引擎。早期每个 Session 都 `newSession()`，但 SparkSession 数量过多导致 Metastore 连接池耗尽。

**解决方案**：引入 `userIsolatedCache`，同用户复用 SparkSession + 引用计数 + LRU 超时回收。

---

## 1.6 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 如何让一个 Spark 进程安全服务多用户 SQL，同时控制资源消耗和结果集大小？ |
| **核心源码** | `SparkSQLEngine.main()` → `SparkSQLSessionManager` → `ExecuteStatement` |
| **调用链** | `main → createSpark → startEngine → ZK注册 → 等待SQL → spark.sql() → collect/stream/file` |
| **设计意图** | 双重超时防僵尸 + 多级 Session 隔离 + 三种结果集模式防 OOM |
| **关键参数** | `ENGINE_IDLE_TIMEOUT=30min`, `ENGINE_SPARK_MAX_LIFETIME`, `OPERATION_RESULT_MAX_ROWS` |
| **踩坑记录** | ① collect() 大结果集 OOM ② 用户隔离缓存引用计数泄漏 ③ YARN 资源不足导致 SparkSession 创建阻塞 |
| **认知更新** | 从"Engine 就是个 Spark 应用"→ "双重超时 + 多级隔离 + 三种收集策略 + 优雅停机的完整引擎生命周期" |

---

# 模块二：SQL 执行与 Operation 管理

## 2.1 白话版（费曼 L1）

> **给完全不懂的人讲**

Operation 就像**餐厅厨房里的一张菜单**：

1. 客人点菜（executeStatement）→ 厨师拿到菜单（创建 Operation）
2. 菜单上写着：做什么菜（SQL 语句）、要不要催（同步/异步）、最多等多久（queryTimeout）
3. 厨师开始做菜（执行 SQL）→ 经历几个阶段：
   - INITIALIZED（接单）→ PENDING（排队等灶台）→ RUNNING（炒菜中）→ FINISHED（出锅）
   - 如果出了问题 → ERROR（糊了）
   - 如果客人不要了 → CANCELLED（退单）
4. 做完后结果放在传菜口（结果缓存）→ 客人分批取走（fetchResults）

**WatchDog**（SQL 熔断器）就像**厨房安全监控**：
- 一道菜做太久？超时自动取消（查询超时）
- 菜单太复杂？拒绝（行数限制、文件扫描限制）
- 灶台全满了？拒绝新菜单（线程池满）

---

## 2.2 架构版（费曼 L2）

### 2.2.1 ExecuteStatement — SQL 执行核心

**源码位置**：`externals/kyuubi-spark-sql-engine/.../operation/ExecuteStatement.scala`

```scala
class ExecuteStatement(spark: SparkSession, session: Session,
    statement: String, shouldRunAsync: Boolean, queryTimeout: Long,
    incrementalCollect: Boolean) extends SparkOperation {

  override def runInternal(): Unit = {
    addTimeoutMonitor(queryTimeout)  // 超时监控

    if (shouldRunAsync) {
      // 异步：提交到后台线程池
      val task = new Runnable { def run() = executeStatement() }
      try { sessionManager.submitBackgroundOperation(task) }
      catch {
        case _: RejectedExecutionException =>
          setState(ERROR)
          throw KyuubiSQLException("Background pool full")
      }
    } else {
      executeStatement()  // 同步执行
    }
  }

  private def executeStatement(): Unit = {
    setState(RUNNING)
    spark.sparkContext.setLocalProperty("spark.jobGroup.id", statementId)

    val result: DataFrame = spark.sql(statement)
    // 内部: parse → analyze → optimize (AQE) → physical plan → execute

    iter = collectResult(result)
    setState(FINISHED)
  }

  // ★ 结果集三种收集策略
  private def collectResult(df: DataFrame): FetchIterator[Row] = {
    if (incrementalCollect) {
      new IterableFetchIterator(df.toLocalIterator().asScala)  // 增量
    } else if (saveToFile) {
      df.write.option("compression","zstd").format("orc").save(path)
      new FetchOrcStatement(path)                               // 落盘
    } else {
      val maxRows = conf.get(OPERATION_RESULT_MAX_ROWS)
      if (maxRows > 0) new ArrayFetchIterator(df.take(maxRows)) // 限行
      else new ArrayFetchIterator(df.collect())                  // 全量
    }
  }
}
```

### 2.2.2 Operation 状态机

```
INITIALIZED → PENDING → RUNNING → COMPILED → FINISHED
                                            ↘ ERROR
                                   ↗ CANCELLED (任何阶段可取消)
                          CLOSEDOP (关闭态)
                          TIMEDOUT (超时态)
```

**状态转换规则**：
- INITIALIZED → PENDING：操作入队等待
- PENDING → RUNNING：获得线程开始执行
- RUNNING → FINISHED/ERROR：执行完成/异常
- 任何状态 → CANCELLED：客户端主动取消
- RUNNING → TIMEDOUT：`queryTimeout` 到期

### 2.2.3 Server→Engine SQL 转发（KyuubiOperation）

```
Server 端:
  KyuubiSessionImpl.executeStatement(sql)
    → KyuubiParser.parse(sql)
       ├── RunnableCommand (SET/USE) → ExecuteOnServerOperation (本地执行)
       └── 普通 SQL → KyuubiOperation → client.executeStatement(sql)
                                          │
                                          │ Thrift RPC
                                          ▼
Engine 端:
  SparkTBinaryFrontendService.ExecuteStatement()
    → SparkSQLBackendService.executeStatement()
      → SparkSessionImpl.executeStatement()
        → new ExecuteStatement(spark, sql)
          → spark.sql(sql)
```

### 2.2.4 WatchDog SQL 熔断机制

**源码位置**：`extensions/spark/.../KyuubiWatchDogRules.scala`

```scala
// Spark SQL Extension 注入规则
class KyuubiWatchDogRules extends SparkSessionExtensions {
  // 规则1：ForcedMaxOutputRows
  // 如果 SQL 返回行数超过限制，自动注入 LIMIT
  // 配置: spark.kyuubi.watchdog.forced.maxOutputRows

  // 规则2：MaxPartitions
  // 如果扫描分区数超过限制，拒绝执行
  // 配置: spark.kyuubi.watchdog.maxPartitions

  // 规则3：MaxFileSize
  // 如果扫描文件总大小超过限制，拒绝执行
  // 配置: spark.kyuubi.watchdog.maxFileSize
}
```

### 2.2.5 KyuubiSparkSQLExtension

```
spark.sql.extensions = org.apache.kyuubi.sql.KyuubiSparkSQLExtension

包含的优化规则：
├── RepartitionBeforeWriteHive   — 写 Hive 前自动 repartition（防小文件）
├── InsertRepartitionBeforeWrite — 通用写前重分区
├── RebalanceBeforeWriting       — AQE 感知的写前重平衡
├── FinalStageConfigIsolation    — 最终 Stage 独立配置
├── DropIgnoreNonexistent        — DROP IF EXISTS 不报错
└── Z-Ordering                   — 数据布局优化 (OPTIMIZE table ZORDER BY)
```

---

## 2.3 论文版（费曼 L3）

### 2.3.1 SQL 执行延迟模型

一条 SQL 的端到端延迟：

\[
T_{sql} = T_{server\_parse} + T_{thrift\_rpc} + T_{engine\_parse} + T_{catalyst} + T_{spark\_exec} + T_{collect} + T_{thrift\_result}
\]

其中：
- \( T_{server\_parse} \)：Server 端 SQL 解析（判断是否本地执行），< 1ms
- \( T_{thrift\_rpc} \)：Server → Engine 的 Thrift RPC 往返，1-10ms
- \( T_{engine\_parse} \)：Engine 端 SQL 解析，< 1ms
- \( T_{catalyst} \)：Catalyst 优化器（parse → analyze → optimize → physical），10-100ms
- \( T_{spark\_exec} \)：Spark Job 执行，**主要瓶颈**，秒 ~ 小时级
- \( T_{collect} \)：结果收集（取决于模式），ms ~ 分钟级
- \( T_{thrift\_result} \)：结果序列化传输，取决于数据量

### 2.3.2 线程池满的排队论分析

后台线程池大小 \( K \)（默认 100），到达率 \( \lambda \)，平均服务时间 \( \mu^{-1} \)。

当 \( \lambda > K \mu \) 时，线程池满。新请求被 `RejectedExecutionException` 拒绝。

**预防条件**：\( K > \lambda / \mu \)

假设平均查询时间 30s，峰值并发 200 QPS：
\[
K > 200 \times 30 = 6000
\]

默认 100 远远不够！但实际场景下，一个引擎通常不会面对 200 QPS（有 Session 级别的限制）。

---

## 2.4 对抗性分析

### 2.4.1 线程池满：RejectedExecutionException

**场景**：100 个并发 SQL 同时提交到一个 ENGINE，线程池满。

**后果**：第 101 个请求收到 `Background operation pool full`。

**缓解**：
1. 调大 `BACKEND_SERVER_EXEC_POOL_SIZE`
2. 使用引擎池（pool.size=3）分散负载
3. WatchDog 规则限制长查询数量

### 2.4.2 结果集 OOM：collect() 炸 Driver

**场景**：`SELECT * FROM huge_table`（10 亿行）

**防护链**：
1. WatchDog `ForcedMaxOutputRows` 自动注入 LIMIT
2. `OPERATION_RESULT_MAX_ROWS` 限制 take(n)
3. 增量模式 / 落盘模式避免全量内存加载

### 2.4.3 SQL 注入 → Spark 任意代码执行

**场景**：用户通过 SQL 调用 `reflect` 函数执行 Java 代码。

```sql
SELECT reflect('java.lang.Runtime', 'exec', 'rm -rf /')
```

**防护**：Ranger 授权可以限制函数调用。但如果未启用 Ranger，引擎以 `--proxy-user` 运行，权限受 OS 用户限制。

---

## 2.5 考古追溯

### 2.5.1 Operation 状态机从 Hive 继承

Kyuubi 的 Operation 状态机（INITIALIZED→PENDING→RUNNING→FINISHED）完整继承自 HiveServer2 的 `OperationState`。

**区别**：Kyuubi 增加了 `COMPILED` 状态（Catalyst 编译完成但未开始执行），便于监控 SQL 的编译耗时。

### 2.5.2 WatchDog 的由来

**背景**：生产环境中，用户经常写出 `SELECT * FROM large_table`（无 WHERE、无 LIMIT），导致 Driver OOM 或集群资源耗尽。

**解决方案**：WatchDog 作为 Spark SQL Extension 注入，在 Catalyst 优化阶段拦截危险 SQL。

---

## 2.6 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 如何安全高效地执行用户 SQL，防止 OOM/超时/资源滥用？ |
| **核心源码** | `ExecuteStatement` → `spark.sql()` → `collectResult()` |
| **调用链** | `Server parse → Thrift RPC → Engine parse → Catalyst → SparkJob → collect → return` |
| **设计意图** | 三种结果集模式防 OOM + WatchDog 熔断 + 超时监控 + 状态机追踪 |
| **关键参数** | `EXEC_POOL_SIZE=100`, `RESULT_MAX_ROWS`, `WATCHDOG_MAX_PARTITIONS` |
| **踩坑记录** | ① 线程池满导致所有查询被拒 ② collect() OOM ③ reflect() 函数导致任意代码执行 |
| **认知更新** | 从"spark.sql 一行代码"→ "线程池管理+三种收集策略+WatchDog熔断+多级超时的完整SQL执行引擎" |

---

## 源码文件索引

| 文件 | 核心职责 |
|------|----------|
| `SparkSQLEngine.scala` | 引擎主入口 |
| `SparkSQLSessionManager.scala` | 会话管理 + 用户隔离缓存 |
| `SparkSessionImpl.scala` | 会话实现 + UDF 注册 |
| `ExecuteStatement.scala` | SQL 执行核心 |
| `SparkOperation.scala` | 操作基类 + 结果集转换 |
| `KyuubiOperation.scala` | Server→Engine 转发 |
| `KyuubiWatchDogRules.scala` | SQL 熔断规则 |
| `KyuubiSparkSQLExtension.scala` | 写前优化 + Z-Ordering |

---

> 本文档遵循"源码精通方法论"L4 标准。
> 源码版本：Apache Kyuubi master 分支 (2026-04, commit ba854d3c)
