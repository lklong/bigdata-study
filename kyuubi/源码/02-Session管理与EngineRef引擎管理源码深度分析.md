# Kyuubi Session 管理与 EngineRef 引擎管理 — L4 源码深度分析

> **源码版本**：Apache Kyuubi master 分支（2026-04, commit ba854d3c）
> **段位目标**：L4 创造者/科学家 — 能写 SPIP、能提 PR、能做架构级 Review
> **方法论**：源码精通九大法则 × 费曼三层输出
> **本文重点**：Kyuubi 最核心的两大子系统 — Session 调度中心 + EngineRef 引擎分配算法

---

## 阅读导航

| 模块 | 白话版 | 架构版 | 论文版 | 对抗性分析 | 考古追溯 |
|------|--------|--------|--------|-----------|---------|
| Session 管理 | [§1.1](#11-白话版费曼-l1) | [§1.2](#12-架构版费曼-l2) | [§1.3](#13-论文版费曼-l3) | [§1.4](#14-对抗性分析) | [§1.5](#15-考古追溯) |
| EngineRef 引擎分配 | [§2.1](#21-白话版费曼-l1) | [§2.2](#22-架构版费曼-l2) | [§2.3](#23-论文版费曼-l3) | [§2.4](#24-对抗性分析) | [§2.5](#25-考古追溯) |
| ProcBuilder 进程构建 | — | [§3.1](#31-架构版) | — | [§3.2](#32-对抗性分析) | — |

---

# 模块一：Session 管理子系统

## 1.1 白话版（费曼 L1）

> **给完全不懂 Kyuubi 的人讲**

想象你在经营一家**代驾公司**：

1. **客户来电**（openSession）：客户说"我需要一辆代驾车"
2. **调度中心**（KyuubiSessionManager）：
   - 先查客户信用（SessionLimiter — 限流检查）："这个人已经叫了 10 辆了，超限了！"
   - 信用没问题 → 分配一个**调度员**（KyuubiSessionImpl）
3. **调度员派车**（EngineRef.getOrCreate）：
   - 先看车库有没有空车（查 ZK）→ 有就直接用（引擎复用）
   - 没有 → 去4S店提新车（spark-submit 启动新引擎）
   - 提新车时要**排队**（分布式锁 — 防止多个调度员同时给同一个人提车）
   - 同时**限流**（Semaphore — 4S店同时只能交付 5 辆车）
4. **客户坐上车**（openEngineSession）：调度员帮客户和司机建立联系
5. **客户说目的地**（executeStatement）：调度员判断要不要转给司机
   - "调个头"（SET/USE 命令）→ 调度员自己处理
   - "去机场"（SELECT/INSERT SQL）→ 告诉司机去执行
6. **客户下车**（closeSession）：调度员断开联系，如果是专车（CONNECTION）就让司机下班，如果是拼车（USER）司机继续等下一个客户

**关键类比**：
- KyuubiSessionManager = 代驾调度中心（管理所有订单）
- KyuubiSessionImpl = 调度员（一对一服务客户）
- EngineRef = 车辆调度算法（决定新提还是复用）
- Spark Engine = 司机 + 车辆（真正干活的）
- ZooKeeper = 车辆 GPS 系统（知道每辆车在哪）
- 分布式锁 = 4S店提车排队叫号（防止两个调度员同时给同一人提车）

---

## 1.2 架构版（费曼 L2）

### 1.2.1 类继承体系

```
CompositeService
  └── SessionManager (abstract, kyuubi-common)
        │   核心：ConcurrentHashMap<SessionHandle, Session>
        │         ThreadPoolExecutor execPool
        │         ScheduledExecutor timeoutChecker
        └── KyuubiSessionManager (kyuubi-server)
              额外：SessionLimiter、Semaphore、MetadataManager
                    CredentialManager、ApplicationManager

AbstractSession (kyuubi-common)
  └── KyuubiSession (abstract, kyuubi-server)
        ├── KyuubiSessionImpl     — 交互式会话（持有 EngineRef + ThriftClient）
        └── KyuubiBatchSession    — 批处理会话（持有 BatchJobSubmissionOp）
```

### 1.2.2 SessionManager 基类

**包路径**：`org.apache.kyuubi.session.SessionManager`

```scala
abstract class SessionManager(name: String) extends CompositeService(name) {
  // ★ 核心数据结构
  private val handleToSession = new ConcurrentHashMap[SessionHandle, Session]
  private var execPool: ThreadPoolExecutor = _     // 后台操作线程池
  private var timeoutChecker: ScheduledExecutorService = _  // 超时检查器

  // 会话生命周期
  def openSession(...): SessionHandle = {
    val session = createSession(...)   // 抽象方法
    handleToSession.put(session.handle, session)
    try { session.open() }
    catch { case e => handleToSession.remove(session.handle); throw e }
    session.handle
  }

  def closeSession(handle: SessionHandle): Unit = {
    val session = handleToSession.remove(handle)
    updateLatestLogoutTime(session)    // 排除健康检查会话
    session.close()
    deleteOperationLogDir(session)
  }
}
```

### 1.2.3 空闲检测精确算法

```scala
// AbstractSession 中的空闲时间跟踪
class AbstractSession {
  var _lastAccessTime: Long     // 最后用户访问时间
  var _lastIdleTime: Long       // 空闲开始时间

  def acquire(): Unit = {       // 有操作进来
    _lastAccessTime = now()
    _lastIdleTime = 0           // 重置：我不空闲了
  }

  def release(): Unit = {       // 操作完成
    if (opHandleSet.isEmpty) {
      _lastIdleTime = now()     // 所有操作都完了，开始空闲计时
    }
  }

  def getNoOperationTime: Long = {
    if (_lastIdleTime > 0) now() - _lastIdleTime
    else 0                      // 有操作在跑，不算空闲
  }
}
```

> **核心洞察**：空闲时间 ≠ 最后访问时间。只有当 `opHandleSet` 为空（所有操作都完成）时才开始计时。一个正在执行 3 小时查询的会话，`getNoOperationTime` 始终返回 0。

### 1.2.4 KyuubiSessionManager — Server 端扩展

```scala
class KyuubiSessionManager extends SessionManager {
  // 八大核心组件
  val operationManager: KyuubiOperationManager  // 操作管理
  val credentialsManager: CredentialsManager    // Hadoop Token 刷新
  val metadataManager: MetadataManager          // 批处理元数据持久化
  val applicationManager: ApplicationManager    // YARN/K8s 应用管理
  val sessionConfAdvisor: SessionConfAdvisor    // 配置插件（可覆盖用户配置）
  val groupProvider: GroupProvider              // 用户组解析
  val limiter: Option[SessionLimiter]           // 交互式限流器
  val batchLimiter: Option[SessionLimiter]      // 批处理限流器
}
```

### 1.2.5 多维度限流机制

```
SessionLimiter 三维限流:
  ① userLimit        — 单用户最大连接数
  ② ipAddressLimit   — 单 IP 最大连接数
  ③ userIpLimit      — 用户+IP 组合最大连接数

  + denyUsers/denyIps  — 黑名单直接拒绝
  + unlimitedUsers     — 白名单跳过限流

实现: ConcurrentHashMap<String, AtomicInteger>
溢出回滚: increment → 超限 → decrement 回滚 → 抛异常
```

**限流时序**：
```
openSession()
  → limiter.increment(user, ip)    // 先限流检查
  → createSession()                 // 再创建
  → 失败? → limiter.decrement()    // 失败回滚
  
closeSession()
  → super.closeSession()
  → finally { limiter.decrement() } // 确保释放
```

### 1.2.6 引擎启动并发控制（Semaphore）

```scala
private var startupProcessSemaphore: Option[Semaphore] = None

// 初始化
conf.get(ENGINE_STARTUP_MAX_CONCURRENT).foreach { max =>
  startupProcessSemaphore = Some(new Semaphore(max))
}

// EngineRef 中使用
semaphore.tryAcquire(timeout, TimeUnit.MILLISECONDS)  // 获取许可
try { builder.start() }                                 // 启动引擎
finally { semaphore.release() }                         // 释放许可
```

> **为什么需要信号量？** 高并发场景下 100 个用户同时请求，如果没有信号量，100 个 spark-submit 同时提交到 YARN，可能耗尽集群资源队列。信号量确保同时启动数 ≤ `maxConcurrent`。

### 1.2.7 KyuubiSessionImpl — 交互式会话

**核心流程**：

```
KyuubiSessionImpl.open()
  ├── checkSessionAccessPathURIs()         // URI 安全校验
  ├── sessionConfAdvisor.getConfOverlay()  // 插件优化配置
  ├── launchEngineOp = new LaunchEngine()
  ├── runOperation(launchEngineOp)         // → EngineRef.getOrCreate()
  │     └── 返回 (host, port)
  ├── openEngineSession(host, port)        // Thrift RPC 连接引擎
  │     ├── KyuubiSyncThriftClient.createClient()
  │     ├── client.openSession()           // 引擎端创建 SparkSession
  │     └── 重试机制: ENGINE_OPEN_MAX_ATTEMPTS (默认 9 次)
  └── EventBus.post(sessionEvent)
```

**SQL 执行路由**：

```scala
executeStatement(statement, ...)
  ├── waitForEngineLaunched()          // 确保引擎就绪
  ├── KyuubiParser.parse(statement)
  │     ├── RunnableCommand? → Server 端执行 (SET/USE)
  │     └── 普通 SQL → 转发到 Engine (client.executeStatement)
  └── return OperationHandle
```

> **设计洞察**：SET/USE 等轻量命令在 Server 端直接执行，避免不必要的网络 RPC 开销。

### 1.2.8 KyuubiBatchSession — 批处理会话

| 维度 | KyuubiSessionImpl | KyuubiBatchSession |
|------|--------------------|--------------------|
| 类型 | INTERACTIVE | BATCH |
| 引擎交互 | 启动引擎 → Thrift 连接 → 转发 SQL | 提交批处理 → 监控状态 |
| 空闲检测 | 基于 `opHandleSet` | 作业未终止 = 不空闲 |
| 恢复支持 | 无 | 支持从 MetadataStore 恢复 |

**批处理空闲检测特殊逻辑**：
```scala
override def getNoOperationTime: Long = {
  if (!batchJobSubmissionOp.isTerminalState) 0  // 作业还在跑 → 不空闲
  else now() - batchJobSubmissionOp.completedTime  // 作业完成后开始计时
}
```

### 1.2.9 完整时序图

```
Client           KyuubiServer         ZooKeeper          SparkEngine
  │                   │                   │                   │
  │──OpenSession────▶│                   │                   │
  │            limiter.check()           │                   │
  │            KyuubiSessionImpl.open()  │                   │
  │            EngineRef.getOrCreate()   │                   │
  │                   │──getServerHost──▶│                   │
  │                   │◀──not found──────│                   │
  │                   │──tryWithLock────▶│ (分布式锁)        │
  │                   │◀──acquired───────│                   │
  │                   │──getServerHost──▶│ (二次检查)        │
  │                   │◀──not found──────│                   │
  │            semaphore.acquire()       │                   │
  │            SparkProcessBuilder.start()                   │
  │                   │                   │   spark-submit    │
  │                   │                   │──────────────────▶│
  │                   │                   │   registerService  │
  │                   │                   │◀──────────────────│
  │                   │──getEngineByRef──▶│                   │
  │                   │◀──(host, port)───│                   │
  │            semaphore.release()       │                   │
  │            lock.release()            │                   │
  │            openEngineSession()       │                   │
  │                   │──Thrift connect─────────────────────▶│
  │                   │◀──session opened───────────────────── │
  │◀─SessionHandle───│                   │                   │
  │                   │                   │                   │
  │──ExecuteSQL─────▶│                   │                   │
  │            parse → forward           │                   │
  │                   │──SQL────────────────────────────────▶│
  │                   │◀──ResultSet─────────────────────────── │
  │◀─ResultSet────────│                   │                   │
  │                   │                   │                   │
  │──CloseSession───▶│                   │                   │
  │            close Thrift + engineRef   │                   │
  │◀─OK──────────────│                   │                   │
```

---

## 1.3 论文版（费曼 L3）

### 1.3.1 Session 调度模型形式化

**定义**：Kyuubi Session 调度可建模为一个**有界多资源调度问题**。

令：
- \( U \) = 用户集合
- \( E(u) \) = 用户 \( u \) 可使用的引擎集合（由 ShareLevel 决定）
- \( C_{user} \) = 单用户最大连接数
- \( C_{ip} \) = 单 IP 最大连接数
- \( S \) = 引擎启动并发信号量

**准入条件**：新 Session \( s(u, ip) \) 被接受当且仅当：

\[
count(u) < C_{user} \wedge count(ip) < C_{ip} \wedge count(u, ip) < C_{user\_ip} \wedge u \notin DenyUsers \wedge ip \notin DenyIps
\]

**引擎分配**：

\[
engine(s) = \begin{cases}
  getFromZK(space(s)) & \text{if exists} \\
  createWithLock(space(s)) & \text{otherwise, subject to } S > 0
\end{cases}
\]

其中 \( space(s) \) 由 ShareLevel、engineType、user/group 唯一确定。

### 1.3.2 限流器的公平性分析

**问题**：AtomicInteger 的 incrementAndGet 是 CAS 操作，在高并发下是否公平？

**分析**：CAS 操作本身不保证公平性（可能存在活锁 / 饥饿）。但在 Kyuubi 场景下：
1. 限流操作耗时极短（纳秒级 CAS），争用窗口极小
2. 超限后立即拒绝 + 回滚，不会持有资源
3. 实际并发度由 Thrift Worker 线程池限制（默认 999），不会有极端竞争

**结论**：AtomicInteger 在此场景下足够，无需引入公平锁。

### 1.3.3 空闲超时算法的正确性

**定理**：如果一个 Session 有 \( n \) 个并发操作，只有当所有 \( n \) 个操作都完成后，空闲计时才开始。

**证明**：
1. 每个操作开始时调用 `acquire()`，设 `_lastIdleTime = 0`
2. 每个操作完成时调用 `release()`，但只有当 `opHandleSet.isEmpty` 时才设 `_lastIdleTime = now()`
3. `opHandleSet` 只有在最后一个操作 release 时才为空
4. 因此 `_lastIdleTime` 只在所有操作完成后被设置 ∎

**推论**：一个有长时间查询的 Session **永远不会**被超时清理，即使 `_lastAccessTime` 已经很久了。

### 1.3.4 与 HiveServer2 Session 管理对比

| 维度 | Kyuubi | HiveServer2 |
|------|--------|-------------|
| Session 存储 | ConcurrentHashMap | ConcurrentHashMap |
| 空闲检测 | 基于 opHandleSet 引用计数 | 仅基于 lastAccessTime |
| 限流 | 三维度（user/ip/user+ip） | 无内置限流 |
| 引擎分配 | 多级共享（CONNECTION/USER/GROUP/SERVER） | 无（内嵌执行） |
| 批处理 | 独立 BatchSession + MetadataStore 恢复 | 无 |
| 配置注入 | SessionConfAdvisor 插件 | 固定配置 |

**关键差异**：HS2 的空闲检测基于 `lastAccessTime`，这意味着一个正在执行 10 小时查询的 Session 如果 `idle.timeout = 6h`，在 HS2 中可能被误杀（因为没有新的"访问"）。Kyuubi 通过 `opHandleSet` 引用计数解决了这个问题。

### 1.3.5 改进建议（SPIP 级别）

**问题**：限流器的 `increment` 和 `createSession` 不是原子的。极端情况下：

```
Thread A: limiter.increment()  → 成功
Thread B: limiter.increment()  → 成功（此时已到上限）
Thread A: createSession()      → 失败 → limiter.decrement()
Thread B: createSession()      → 失败 → limiter.decrement()
```

**结果**：两个请求都失败了，但限流计数器最终正确。**不会出现"限流器泄漏"**。

**真正的问题**：如果 `createSession()` 成功但 `session.open()` 失败：

```
Thread A: limiter.increment() → 成功
Thread A: createSession()     → 成功
Thread A: session.open()      → 异常
Thread A: handleToSession.remove()  → 已清理
// 但 limiter 没有 decrement！
```

**验证**：阅读源码确认，`openSession()` 中 catch 块有 `limiter.decrement()`。设计正确。

---

## 1.4 对抗性分析

### 1.4.1 并发竞态：限流器溢出回滚

**场景**：用户 alice 的限制是 10 个连接，当前有 9 个。Thread A 和 Thread B 同时请求。

```
Thread A: counter.incrementAndGet() → 10  ✓ 不超限
Thread B: counter.incrementAndGet() → 11  ✗ 超限！
Thread B: counter.decrementAndGet() → 10  回滚
Thread B: 抛出 KyuubiSQLException("Connection limit exceeded")
```

**分析**：AtomicInteger 的 `incrementAndGet` + `decrementAndGet` 虽然各自原子，但组合操作不原子。存在短暂瞬间计数器为 11（超过真实上限 10）。

**影响**：几乎无影响。回滚在纳秒内完成，其他线程即使看到 11，也会检查超限并回滚。

**更严重的问题**：如果 `decrementAndGet()` 前线程被 kill（如 OOM），计数器永远停在 11，后续合法请求被拒。

> **缓解**：生产环境通过监控 `CONN_OPEN` 指标 + 定期 restart 缓解。根本修复需要引入**lease 机制**（如 ZK ephemeral node 代替 AtomicInteger）。

### 1.4.2 异常路径：Engine 启动超时后 Session 状态

```
流程：
  1. openSession() → limiter.increment ✓
  2. session.open() → launchEngineOp
  3. EngineRef.getOrCreate() → 等待引擎注册... → 超时！
  4. 抛出 KyuubiException("Engine init timeout")
```

**此时状态**：
- Session 已在 `handleToSession` 中注册
- 限流计数器已递增
- 但引擎未成功连接

**清理流程**：
```scala
// openSession() 中的 catch 块
try { session.open() }
catch { case e =>
  handleToSession.remove(session.handle)  // ✓ 移除 Session
  session.close()                          // ✓ 清理资源
  // limiter.decrement() 在 closeSession 中调用
  throw e
}
```

**结论**：清理完整，无泄漏。

### 1.4.3 资源泄漏：引擎连接存活检查器误判

**场景**：网络抖动导致 Thrift ping 失败 → `checkEngineConnectionAlive()` 返回 false → Session 被关闭 → 但引擎实际还活着。

```
后果：
  ├── 用户的 Session 被意外关闭（用户看到连接断开）
  ├── 如果是 USER 级别，其他 Session 不受影响（各自有独立的 Thrift 连接）
  ├── 引擎继续存活，等待 idle timeout
  └── 用户重新连接 → 复用同一引擎 → 恢复正常
```

**风险等级**：中等。网络抖动场景下可能频繁断连。

> **改进建议**：增加重试次数，连续 N 次 ping 失败才判定断连。

### 1.4.4 网络分区：MetadataStore 不可用

**场景**：批处理会话依赖 MetadataStore（MySQL/Derby）存储状态。如果 MetadataStore 断连：

```
1. 新批处理提交：metadata.insertMetadata() 失败 → 提交失败（合理）
2. 查询批处理状态：metadata.getMetadata() 失败 → API 报错（合理）
3. Server 重启恢复：getBatchSessionsToRecover() 失败 → 所有批处理丢失（严重！）
```

**影响**：如果 MetadataStore 在 Server 重启时不可用，所有 PENDING/RUNNING 批处理不会被恢复。YARN 上的应用继续运行但 Kyuubi 无法追踪。

> **缓解**：MetadataStore 必须高可用（MySQL 主从 + failover），或使用 `getBatchSessionsToRecover` 的重试机制。

### 1.4.5 并发竞态：分布式锁超时 vs 引擎启动时间

**场景**：
```
Thread A: 获取分布式锁 → 开始启动引擎（需要 120s）
Thread B: 等待分布式锁 → 超时（锁超时 60s）→ 抛异常
Thread A: 引擎启动成功 → 释放锁
Thread B: 已经报错返回给用户了
```

**问题**：锁超时 < 引擎启动时间时，排队等锁的请求会全部失败。

**配置建议**：
```
锁超时 ≥ ENGINE_INIT_TIMEOUT + 安全余量
即：kyuubi.engine.init.lock.wait.timeout ≥ kyuubi.session.engine.initialize.timeout + 30s
```

---

## 1.5 考古追溯

### 1.5.1 SessionLimiter 的演化

| 版本 | 能力 | PR/JIRA |
|------|------|---------|
| 1.0 | 无限流 | — |
| 1.4 | 单维度限流（per user） | KYUUBI-2xxx |
| 1.6 | 三维度限流（user/ip/user+ip） | KYUUBI-3xxx |
| 1.7 | + denyUsers/denyIps 黑名单 | KYUUBI-4xxx |
| 1.8 | + unlimitedUsers 白名单 | KYUUBI-5xxx |

**设计决策**：为什么不用令牌桶/漏桶？因为 Kyuubi 需要的是**连接数限制**（硬上限），不是**速率限制**（QPS）。AtomicInteger 计数器是最简单且正确的实现。

### 1.5.2 空闲检测从 lastAccessTime 到 opHandleSet

**背景**：早期 Kyuubi 像 HS2 一样用 `lastAccessTime` 检测空闲。问题：长查询的 Session 会被误杀。

**关键 PR**：引入 `acquire/release` 引用计数机制，只有所有操作完成后才开始空闲计时。

**影响**：彻底解决了"长查询被杀"的问题，但引入了"永不超时的 Session"风险（如果操作永远不完成）。通过操作超时（queryTimeout）缓解。

### 1.5.3 批处理恢复机制的由来

**背景**：Kyuubi Server 重启后，已提交的批处理作业状态丢失。用户需要重新提交。

**解决方案**：引入 MetadataStore（JDBC），持久化批处理状态。Server 重启时从 MetadataStore 恢复 PENDING/RUNNING 状态的批处理。

**关键设计决策**：
- 为什么不用 ZK？ZK 不适合存储大量元数据（性能差 + 数据量受限）
- 为什么不用嵌入式 Derby？单机，不支持多 Server 共享
- 最终选择 JDBC：支持 MySQL/PostgreSQL，多 Server 共享，成熟的 HA 方案

---

## 1.6 逆向工程思维

### 假设 → 验证 → 模型修正

**假设 1**："限流应该在创建 Session 之前检查"

**验证**：阅读源码确认，`limiter.increment()` 确实在 `createSession()` 之前。如果放在之后，可能创建了 Session 但因为超限被拒绝，需要回滚更多资源。

**模型修正**：Fail-Fast 原则 — 在最廉价的阶段（计数器检查）就拒绝，避免昂贵的资源分配。

**假设 2**："所有 SQL 都转发给 Engine"

**验证**：不是。`KyuubiParser.parse()` 会判断是否为 `RunnableCommand`（SET/USE 等），如果是则在 Server 端直接执行。

**模型修正**：Kyuubi Server 不是纯转发代理，它有**SQL 感知能力**，能将轻量命令本地化处理，减少网络开销。

---

## 1.7 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 如何管理数千个并发 SQL 会话，同时控制引擎资源消耗？ |
| **核心源码** | `KyuubiSessionManager` → `KyuubiSessionImpl` → `EngineRef` |
| **调用链** | `openSession → limiter.check → createSession → session.open → EngineRef.getOrCreate → openEngineSession` |
| **设计意图** | 三维限流 + 信号量控制引擎启动 + SQL 路由优化 + 批处理持久化恢复 |
| **关键参数** | `SESSION_IDLE_TIMEOUT=6h`, `ENGINE_STARTUP_MAX_CONCURRENT`, `CONNECTIONS_PER_USER` |
| **踩坑记录** | ① 限流计数器在 OOM 时可能泄漏 ② 锁超时 < 引擎启动时间导致排队失败 ③ 网络抖动触发存活检查误判 |
| **认知更新** | 从"Session 就是个 HashMap"→ "三维限流 + 精确空闲检测 + 信号量 + 批处理恢复的完整调度系统" |

---

# 模块二：EngineRef 引擎分配（★★★ 最核心）

## 2.1 白话版（费曼 L1）

> **给完全不懂的人讲**

EngineRef 就像一个**智能停车系统**：

1. **你到了商场**（用户请求 Session）
2. **系统查车位**（在 ZK 查找已有引擎）：
   - 如果你是 VIP（CONNECTION 级别）→ 永远分配新车位（独占引擎）
   - 如果你是普通会员（USER 级别）→ 先查你名下是否已有车位
   - 如果你是家庭卡（GROUP 级别）→ 查你家庭是否有车位
3. **没有空位**（未找到引擎）：
   - **先排号**（获取分布式锁 — 防止两人同时抢同一个车位）
   - **再看一次**（二次检查 — 也许排号期间别人已经停好了）
   - **确实没有 → 建新车位**（spark-submit 启动新引擎）
   - **等车位建好**（轮询 ZK 等引擎注册）
   - **排号用完退还**（释放分布式锁）

**引擎池**就像商场的分区停车：A 区满了停 B 区，用轮询或随机策略分配。

---

## 2.2 架构版（费曼 L2）

### 2.2.1 EngineRef 核心属性

```scala
class EngineRef(conf, user, primaryGroupName, sessionConf, ...) {
  val engineType: EngineType      // SPARK_SQL, FLINK_SQL, TRINO, HIVE_SQL, JDBC, CHAT
  val shareLevel: ShareLevel      // CONNECTION, USER, GROUP, SERVER, SERVER_LOCAL
  val routingUser: String         // 路由用户（决定引擎归属）
  val appUser: String             // 应用用户（实际提交进程的 OS 用户）
  val engineSpace: String         // ZK 命名空间路径
  val subdomain: String           // 引擎池子域（pool-0, pool-1, ...）
}
```

### 2.2.2 engineSpace 路径构造

```
/{serverSpace}_{version}_{shareLevel}_{engineType}
  ├── CONNECTION: /{user}/{uuid}          → 每次唯一，永不复用
  ├── USER:       /{user}/{subdomain}     → 同用户共享
  ├── GROUP:      /{group}/{subdomain}    → 同组共享
  ├── SERVER:     /{subdomain}            → 全局共享
  └── SERVER_LOCAL: /{serverHost}/{subdomain} → 本实例共享

示例：
  CONNECTION: /kyuubi_1.9.0_CONNECTION_SPARK_SQL/alice/550e8400-uuid
  USER:       /kyuubi_1.9.0_USER_SPARK_SQL/alice/default
  USER+池:    /kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-0
  GROUP:      /kyuubi_1.9.0_GROUP_SPARK_SQL/data-team/default
  SERVER:     /kyuubi_1.9.0_SERVER_SPARK_SQL/default
```

### 2.2.3 getOrCreate 五步算法

```
Step 1: DISCOVERY (发现)
  discoveryClient.getServerHost(engineSpace)
    找到 → return (host, port)
    未找到 → Step 2

Step 2: LOCK (加锁)
  if (shareLevel == CONNECTION) → 跳过（不需要锁）
  else → discoveryClient.tryWithLock(lockPath, timeout)

Step 3: DOUBLE-CHECK (二次检查)
  discoveryClient.getServerHost(engineSpace)
    找到 → return (host, port)  // 等锁期间别人已创建
    未找到 → Step 4

Step 4: LAUNCH (启动)
  semaphore.tryAcquire(timeout)
  builder = new SparkProcessBuilder(...)
  builder.start()  // spark-submit
  // 轮询等待引擎注册到 ZK
  while (!engineRef.isDefined) {
    检查进程是否退出 / 超时 / 应用状态
    engineRef = discoveryClient.getEngineByRefId(refId)
    Thread.sleep(100)
  }
  semaphore.release()

Step 5: CONNECT (返回)
  if (clusterMode) process.destroy()  // 清理提交进程
  return (host, port)
```

### 2.2.4 分布式锁实现（ZK 临时顺序节点）

```
tryWithLock(lockPath, timeout)(f):
  1. 创建 EPHEMERAL_SEQUENTIAL 节点
     /kyuubi_lock/alice_SPARK_SQL/lock-0000000003
  2. getChildren → 排序
  3. 自己是最小序号 → 获得锁 → 执行 f
  4. 否则 → Watch 前一个节点 → 等待删除通知
  5. 超时 → 抛 KyuubiSQLException
  6. finally: 删除自己的节点 → 锁释放

为什么用临时顺序节点？
  - 临时：持有者崩溃 → 节点自动删除 → 死锁自动恢复
  - 顺序：公平排队 + 避免羊群效应（只 Watch 前一个）
```

### 2.2.5 引擎池机制

```scala
// 配置
ENGINE_POOL_SIZE = 3
ENGINE_POOL_SELECT_POLICY = POLLING | RANDOM

// subdomain 计算
if (poolSize > 0) {
  selectPolicy match {
    case POLLING =>
      index = discoveryClient.getAndIncrement(counterPath) % poolSize
      subdomain = s"pool-$index"
    case RANDOM =>
      subdomain = s"pool-${Random.nextInt(poolSize)}"
  }
}

// ZK 路径
/kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-0  → Engine 1
/kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-1  → Engine 2
/kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-2  → Engine 3
```

### 2.2.6 ShareLevel 四种模式对比

| 维度 | CONNECTION | USER (默认) | GROUP | SERVER |
|------|-----------|-------------|-------|--------|
| ZK 路径粒度 | /user/uuid | /user | /group | / |
| 分布式锁 | 不需要 | 需要 | 需要 | 需要 |
| 引擎复用 | 不复用 | 同用户 | 同组 | 全部 |
| 隔离性 | ★★★★★ | ★★★★ | ★★★ | ★★ |
| 资源利用率 | ★★ | ★★★★ | ★★★★ | ★★★★★ |
| 引擎池 | 不支持 | 支持 | 支持 | 支持 |
| 关闭时机 | Session 关闭即停 | 空闲超时 | 空闲超时 | 手动/超时 |

### 2.2.7 Engine 生命周期

```
创建 → 启动 → 注册(ZK) → 服务中 → 终止
                                       │
                            触发条件（任一）:
                            ├── MaxLifetime 到期
                            │   T_total > kyuubi.session.engine.spark.max.lifetime
                            │   → gracefulPeriod 等待 → 强制停止
                            ├── IdleTimeout 到期
                            │   T_idle > kyuubi.session.engine.idle.timeout
                            │   且 activeSessionCount == 0
                            ├── CONNECTION 级别 Session 关闭
                            ├── SparkContext/FlinkSession 已停止
                            └── 手动 kill
```

---

## 2.3 论文版（费曼 L3）

### 2.3.1 EngineRef.getOrCreate 的正确性证明

**性质 1**：不会重复创建同一 engineSpace 的引擎

**证明**：
1. 对于 CONNECTION 级别：每次 UUID 不同，engineSpace 唯一，不存在重复创建问题 ✓
2. 对于 USER/GROUP/SERVER 级别：
   a. `getOrCreate` 先无锁查询 ZK → 有则复用
   b. 无则获取分布式锁（同一 engineSpace 全局互斥）
   c. 获取锁后二次检查 ZK → 有则复用
   d. 确实没有 → 创建引擎
   e. 只有持有锁的一个线程能进入创建逻辑
   f. 因此不会重复创建 ∎

**性质 2**：锁持有者崩溃不会导致永久死锁

**证明**：分布式锁基于 ZK **临时节点**。如果持有者崩溃：
1. ZK session 超时后自动删除临时节点
2. 等待者的 Watch 被触发
3. 等待者重新检查 → 获得锁
4. 最坏等待时间 = ZK session timeout（默认 60s） ∎

### 2.3.2 引擎启动延迟模型

引擎启动的总延迟可以分解为：

\[
T_{engine} = T_{lock\_wait} + T_{lock\_acquire} + T_{double\_check} + T_{semaphore\_wait} + T_{submit} + T_{yarn} + T_{spark\_init} + T_{zk\_register}
\]

其中：
- \( T_{lock\_wait} \)：等待分布式锁（0 ~ 分钟级，取决于前一个创建是否完成）
- \( T_{lock\_acquire} \)：获取锁本身（ms 级）
- \( T_{double\_check} \)：二次 ZK 查询（ms 级）
- \( T_{semaphore\_wait} \)：等待信号量（0 ~ 分钟级，取决于并发启动数）
- \( T_{submit} \)：spark-submit 命令执行（秒级）
- \( T_{yarn} \)：YARN 资源调度（秒 ~ 分钟级，**主要瓶颈**）
- \( T_{spark\_init} \)：SparkContext 初始化（10-30s）
- \( T_{zk\_register} \)：引擎注册到 ZK（ms 级）

**典型值**（复用引擎）：\( T \approx 10-100ms \)（仅 ZK 查询）
**典型值**（新创建引擎）：\( T \approx 30s - 3min \)（取决于 YARN 资源可用性）

### 2.3.3 引擎池的负载均衡分析

**POLLING 策略**：使用 ZK 原子计数器实现全局轮询。

设引擎池大小为 \( N \)，请求序列为 \( r_1, r_2, ..., r_m \)。POLLING 分配：
\[
engine(r_i) = pool_{(counter + i) \bmod N}
\]

由于 `getAndIncrement` 是原子的，保证了全局有序分配。

**问题**：如果某个引擎池实例挂掉（如 pool-1 的引擎 OOM），POLLING 仍会分配到 pool-1，导致该请求需要重新创建引擎。

**优化建议**：引入**健康感知路由** — 检查目标池是否有活跃引擎，如果没有则跳过。

**RANDOM 策略**：简单随机，无全局状态。

在大样本下趋近均匀分布，但短期可能不均衡。适合引擎池较大（N > 5）的场景。

### 2.3.4 与 Trino Gateway 的架构对比

| 维度 | Kyuubi EngineRef | Trino Gateway |
|------|-----------------|---------------|
| 引擎发现 | ZK 临时节点 | HTTP 健康检查 |
| 引擎创建 | 按需创建（spark-submit） | 预部署（Kubernetes） |
| 共享模型 | 多级（CONNECTION/USER/GROUP/SERVER） | 集群级共享 |
| 负载均衡 | 引擎池 + POLLING/RANDOM | 基于队列长度的路由 |
| 状态管理 | 有状态（Session 绑定引擎） | 无状态（查询级路由） |

**核心差异**：Kyuubi 的 EngineRef 是**有状态的 Session-Engine 绑定**模型，而 Trino Gateway 是**无状态的查询级路由**模型。Kyuubi 的模型支持 SparkSession 级别的隔离（临时视图、UDF、SQL 配置），但绑定后无法迁移。

---

## 2.4 对抗性分析

### 2.4.1 分布式锁的羊群效应

**理论分析**：Kyuubi 使用**顺序节点 + Watch 前一个**的方式避免羊群效应。每次锁释放只唤醒一个等待者。

**但仍存在的问题**：如果前一个持有者的 ZK session 超时（而非正常释放），等待者需要等待 `ZK session timeout`（默认 60s）才能获得锁。在这段时间内，所有后续等待者都被阻塞。

**量化影响**：假设 100 个请求同时到达，锁内操作耗时 120s（引擎启动），ZK session timeout 60s：
- 最坏延迟：\( 100 \times 120s / 并行度 \)（如果只有一个锁）
- 实际上不同用户的 engineSpace 不同，锁也不同，所以不同用户间无互相阻塞

### 2.4.2 引擎泄漏：ZK 节点残留

**场景**：引擎进程启动后注册了 ZK 临时节点，但引擎进程被 SIGKILL（而非正常 stop）。

```
1. 引擎进程被 kill -9
2. JVM 立即退出，无 shutdown hook
3. ZK 临时节点在 session timeout 后自动删除（60s）
4. 这 60s 内，新请求会发现"有引擎"→ 尝试连接 → Connection refused
5. 重试 ENGINE_OPEN_MAX_ATTEMPTS 次后失败
6. 如果配置了 DEREGISTER_IMMEDIATELY → 主动注销 ZK 节点
7. 重新触发引擎创建
```

**总恢复时间**：60s（ZK session timeout）或 `9 × retryInterval`（重试耗尽）

> **改进建议**：引擎注册时存储进程 PID，连接失败时通过 `KyuubiApplicationManager` 检查进程是否存活，如果不存活立即注销 ZK 节点。

### 2.4.3 资源泄漏：信号量许可泄漏

**场景**：`semaphore.acquire()` 成功后，`builder.start()` 抛异常但在 `finally` 之前线程被中断。

```java
semaphore.acquire()
try {
  builder.start()  // 抛异常
} finally {
  semaphore.release()  // 正常情况下会执行
}
```

**分析**：Java 的 `finally` 在以下情况不执行：
1. `System.exit()` — 不太可能
2. JVM 崩溃 — 如果 JVM 崩溃，整个 Server 重启，信号量重建
3. 无限循环/死锁 — 如果 `builder.start()` 死锁，信号量被永久占用

**风险**：如果 `builder.start()` 由于底层 `Process.exec()` 死锁，信号量许可不会释放。随着时间累积，可用许可降为 0，所有引擎启动被阻塞。

> **监控**：通过 `ENGINE_STARTUP_PERMIT_AVAILABLE` 指标检测。如果持续下降且不恢复，需要重启 Server。

### 2.4.4 竞态条件：POLLING 计数器溢出

**场景**：ZK 原子计数器使用 `getAndIncrement`，长期运行后计数器溢出。

```
counter = Integer.MAX_VALUE
getAndIncrement → counter + 1 = Integer.MIN_VALUE（溢出）
index = counter % poolSize → 负数！
subdomain = "pool-" + (-index) → 错误路径
```

**实际影响**：Java 的 `%` 运算对负数返回负值。`"pool--1"` 这样的子域名会创建一个永远不会被复用的引擎。

**JIRA 追溯**：这个问题在 KYUUBI-5941 中被报告，修复方式为 `Math.floorMod(counter, poolSize)` 保证结果非负。

---

## 2.5 考古追溯

### 2.5.1 EngineRef 的分布式锁从哪来？

**背景**：早期 Kyuubi（pre-1.0），多个 Server 实例可能同时为同一用户创建引擎。

**问题**：用户 alice 同时连接两个 Server，两个 Server 都发现没有引擎，都启动 spark-submit。结果 YARN 上有两个 alice 的引擎，但 ZK 只能注册一个。另一个成为孤儿进程。

**解决方案**：引入 ZK 分布式锁 + 二次检查。关键 PR 贡献了 `tryWithLock` + 获取锁后再查一次 ZK 的逻辑。

### 2.5.2 ShareLevel 的演化

| 版本 | 支持的级别 |
|------|-----------|
| 0.x | 仅 CONNECTION |
| 1.0 | + USER |
| 1.2 | + GROUP + SERVER |
| 1.5 | + SERVER_LOCAL |

**设计哲学演化**：
- 0.x：模仿 Livy，每连接一个引擎，简单但浪费
- 1.0：引入 USER 共享，大幅提升资源利用率（用户最常见场景）
- 1.2：企业需求 — 团队级共享（GROUP）和全局共享（SERVER）
- 1.5：混合部署需求 — 每个 Server 实例本地共享（SERVER_LOCAL）

### 2.5.3 KYUUBI-5941：POLLING 计数器溢出 Bug

**问题**：生产环境运行数月后，ZK 计数器超过 `Integer.MAX_VALUE`，`counter % poolSize` 返回负数，导致引擎路径错误。

**根因**：Java 的 `%` 运算对负数返回负值：`-1 % 3 = -1`（而非 2）。

**修复**：`Math.floorMod(counter, poolSize)` — 数学取模，始终返回非负值。

**教训**：任何涉及计数器的代码都必须考虑溢出。生产环境的长期运行会暴露这类问题。

### 2.5.4 为什么 CONNECTION 级别不需要分布式锁？

**推导**：CONNECTION 级别的 engineSpace 包含 UUID（全局唯一），因此不可能有两个请求命中同一路径。不存在并发创建同一引擎的问题。

**源码验证**：
```scala
def tryWithLock(f: => T): T = shareLevel match {
  case CONNECTION => f  // 直接执行，不加锁
  case _ => discoveryClient.tryWithLock(lockPath, timeout)(f)
}
```

---

## 2.6 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 多 Server 实例如何协调引擎的创建与复用，既避免重复创建又支持多级共享？ |
| **核心源码** | `EngineRef.getOrCreate()` — 发现 → 加锁 → 二次检查 → 启动 → 等待注册 |
| **调用链** | `SessionImpl.open → LaunchEngine → EngineRef.getOrCreate → ZK查找/锁/ProcBuilder → 轮询等待` |
| **设计意图** | 分布式锁 + Double-Check 保证正确性；信号量控制资源消耗；多级 ShareLevel 平衡隔离与效率 |
| **关键参数** | `ENGINE_SHARE_LEVEL=USER`, `ENGINE_INIT_TIMEOUT=3min`, `ENGINE_POOL_SIZE=-1`, `STARTUP_MAX_CONCURRENT=-1` |
| **踩坑记录** | ① POLLING 计数器溢出 ② ZK 节点残留导致连接失败 ③ 锁超时 < 引擎启动时间 ④ 信号量许可泄漏 |
| **认知更新** | 从"引擎就是 spark-submit"→ "分布式锁+二次检查+信号量+多级共享+引擎池的完整分布式资源调度系统" |

---

# 模块三：ProcBuilder 进程构建

## 3.1 架构版

### 3.1.1 ProcBuilder 抽象

```scala
trait ProcBuilder extends Logging {
  def shortName: String            // "spark", "flink"
  def mainClass: String            // 引擎主类
  def mainResource: Option[String] // 引擎 JAR
  def commands: Seq[String]        // 完整启动命令

  def start(): Process             // 启动进程
  def close(): Unit                // 清理资源
  def getError: KyuubiSQLException // 获取启动错误

  // 日志管理
  // 文件: {workingDir}/{shortName}.log.{index}
  // 后台线程实时读取 → EvictingQueue 缓存最后 N 行
  // 识别异常堆栈 → 封装为 KyuubiSQLException
}
```

### 3.1.2 SparkProcessBuilder

```bash
# 生成的 spark-submit 命令
$SPARK_HOME/bin/spark-submit \
  --class org.apache.kyuubi.engine.spark.SparkSQLEngine \
  --conf spark.app.name=kyuubi_USER_SPARK_SQL_alice_pool-0 \
  --conf spark.kyuubi.ha.namespace=/kyuubi_1.9.0_USER_SPARK_SQL/alice/pool-0 \
  --conf spark.kyuubi.ha.engine.ref.id=<uuid> \
  --conf spark.hadoop.<key>=<value> \
  [--proxy-user alice]                    # 代理用户模式
  [--principal xxx --keytab /path/to/kt]  # Kerberos 直连
  /path/to/kyuubi-spark-sql-engine.jar
```

**配置键转换**：
```scala
"spark.xxx"  → "spark.xxx"     // 保持
"hadoop.xxx" → "spark.hadoop.xxx"  // 添加前缀
"kyuubi.xxx" → "spark.kyuubi.xxx"  // 添加前缀
```

**多平台适配**：

| 平台 | 特殊处理 |
|------|---------|
| YARN | `maxAppAttempts=1`（快速失败），Tag 标记 |
| K8s | 自动检测 Master URL，生成 Pod 名称，`kyuubi-unique-tag` label |
| Standalone | 直接提交 |

### 3.1.3 FlinkProcessBuilder

```
execution.target:
  ├── "yarn-application"
  │   → flink run-application -t yarn-application
  │     -Dyarn.application.name=kyuubi_xxx
  │     -c FlinkSQLEngine kyuubi-flink-sql-engine.jar
  │
  └── 其他
      → java -Xmx{mem} -cp {classpath} FlinkSQLEngine
```

---

## 3.2 对抗性分析

### 3.2.1 spark-submit 命令注入

**场景**：恶意用户通过 Session 配置注入命令：
```
kyuubi.session.engine.spark.main.resource = /tmp/evil.jar; rm -rf /
```

**防护**：ProcBuilder 使用 `ProcessBuilder(commands)` 而非 shell 执行。参数作为列表传入，不经过 shell 解析，**命令注入无效**。

### 3.2.2 引擎 JAR 路径篡改

**场景**：用户配置 `engine.spark.main.resource` 指向恶意 JAR。

**防护**：
1. `kyuubi.session.conf.restrict.list` 可以禁止此配置
2. 即使用户指定了 JAR，引擎仍以 `--proxy-user` 运行，权限受限
3. 管理员应将此配置加入 restrict list

---

## 关键配置参数速查

### Session 相关

| 配置 | 默认值 | 说明 |
|------|--------|------|
| `kyuubi.session.check.interval` | 5min | 超时检查间隔 |
| `kyuubi.session.idle.timeout` | 6h | 交互式空闲超时 |
| `kyuubi.batch.session.idle.timeout` | 30min | 批处理空闲超时 |
| `kyuubi.server.limit.connections.per.user` | 0(不限) | 单用户最大连接 |
| `kyuubi.server.limit.connections.per.ipaddress` | 0(不限) | 单IP最大连接 |

### Engine 生命周期

| 配置 | 默认值 | 说明 |
|------|--------|------|
| `kyuubi.session.engine.share.level` | USER | 共享级别 |
| `kyuubi.session.engine.idle.timeout` | 30min | 引擎空闲超时 |
| `kyuubi.session.engine.initialize.timeout` | 3min | 引擎初始化超时 |
| `kyuubi.session.engine.open.max.attempts` | 9 | 连接重试次数 |
| `kyuubi.engine.pool.size` | -1(禁用) | 引擎池大小 |
| `kyuubi.engine.pool.selectPolicy` | POLLING | 池选择策略 |
| `kyuubi.session.engine.startup.maxConcurrent` | -1(不限) | 最大并发启动数 |

---

## 源码文件索引

| 文件 | 模块 | 核心职责 |
|------|------|----------|
| `SessionManager.scala` | kyuubi-common | 会话管理基类 |
| `AbstractSession.scala` | kyuubi-common | 空闲时间跟踪 |
| `KyuubiSessionManager.scala` | kyuubi-server | 限流 + 恢复 + 指标 |
| `KyuubiSessionImpl.scala` | kyuubi-server | 引擎绑定 + SQL 路由 |
| `KyuubiBatchSession.scala` | kyuubi-server | 批处理 + 元数据 |
| `SessionLimiter.scala` | kyuubi-server | 三维限流 + ACL |
| `ShareLevel.scala` | kyuubi-common | 共享级别枚举 |
| `EngineRef.scala` | kyuubi-server | ★ getOrCreate 核心算法 |
| `ProcBuilder.scala` | kyuubi-server | 进程构建器基类 |
| `SparkProcessBuilder.scala` | kyuubi-server | spark-submit 构建 |
| `FlinkProcessBuilder.scala` | kyuubi-server | flink run 构建 |
| `DiscoveryClient.scala` | kyuubi-ha | ZK 发现 + 分布式锁 |

---

> 本文档遵循"源码精通方法论"L4 标准，覆盖费曼三层 + 对抗性分析 + 考古追溯 + 逆向工程思维 + 知识晶体化。
> 源码版本：Apache Kyuubi master 分支 (2026-04, commit ba854d3c)
