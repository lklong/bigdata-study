# [教案] TezSession 管理与 AM 生命周期源码深度剖析

> 🎯 教学目标：掌握 Hive Tez Session 的池化管理、会话生命周期、DAG 提交流程和 WorkloadManager 资源隔离 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：出租车 vs 专车队

传统的 Hive on MR 就像**叫出租车**——每次出门（提交查询）都要在路边招手等车（申请 YARN Container），到了目的地车就走了。下次出门又得重新等车。

Hive on Tez 的 Session 管理就像**公司有一支专车队**：
- **TezSessionPoolManager**（车队经理）：管理一组预热好的车（Session）
- **TezSessionState**（一辆专车）：引擎预热、GPS就绪，随叫随走
- **WorkloadManager**（调度中心）：根据部门（资源池）分配车辆，VIP 优先

### 生产故障场景

```
现象：HiveServer2 启动后前几个查询特别慢（30-60秒），后续查询秒级返回
原因：首批查询触发了 Tez AM 的启动（需要 YARN 分配 Container、初始化 JVM）
     后续查询复用已有的 Tez Session，无需重新启动 AM
排查：查看 YARN UI 发现 Application 被复用
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| TezSessionState | 一个 Tez 会话的状态封装（含 TezClient） | 一辆专车（引擎热着，随时出发） |
| TezSessionPoolManager | Session 池管理器（单例） | 车队经理（管理所有专车的调度） |
| TezSessionPool | 会话对象池（先进先出队列） | 停车场（空闲车辆排队等待派出） |
| SessionExpirationTracker | 会话超时追踪器 | 计时器（车辆空闲太久就熄火回库） |
| TezClient | Apache Tez 客户端（与 AM 通信） | 车的发动机（真正干活的核心） |
| TezTask | Hive 的 Tez 任务封装 | 一次出行任务（从 A 到 B） |
| DAG | 有向无环图（查询执行计划） | 导航路线（从起点到终点的完整路径） |
| WorkloadManager | 工作负载管理器（资源隔离） | 调度中心（按部门分配车辆配额） |
| WmTezSession | 受 WM 管理的 Tez Session | 调度中心管控下的专车 |

### 2.2 架构图/流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                    HiveServer2                                   │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐           │
│  │          TezSessionPoolManager (单例)             │           │
│  │                                                   │           │
│  │  ┌────────────────┐  ┌────────────────────────┐  │           │
│  │  │ defaultSession │  │ SessionExpiration      │  │           │
│  │  │ Pool (队列)    │  │ Tracker (超时回收)      │  │           │
│  │  │ ┌────────────┐ │  └────────────────────────┘  │           │
│  │  │ │ Session #1 │ │                               │           │
│  │  │ │ Session #2 │ │  ┌────────────────────────┐  │           │
│  │  │ │ Session #3 │ │  │ WorkloadManager        │  │           │
│  │  │ │   ...      │ │  │ (可选，资源隔离)        │  │           │
│  │  │ └────────────┘ │  │ ┌─────┐ ┌─────┐       │  │           │
│  │  └────────────────┘  │ │Pool1│ │Pool2│ ...   │  │           │
│  │                       │ └─────┘ └─────┘       │  │           │
│  │                       └────────────────────────┘  │           │
│  └──────────────────────────────────────────────────┘           │
│                                                                  │
│  用户查询 ──→ getSession() ──→ TezSessionState                  │
│                                     │                            │
│                                     ▼                            │
│                               TezClient (AM)                    │
│                                     │                            │
│                                     ▼                            │
│                              submitDAG(dag)                      │
│                                     │                            │
│                                     ▼                            │
│                               YARN Cluster                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|----------|------|
| `TezSessionPoolManager` | `ql/.../exec/tez/TezSessionPoolManager.java` | Session 池管理器，获取/归还/超时管理 |
| `TezSessionState` | `ql/.../exec/tez/TezSessionState.java` | 单个 Tez Session 的状态和操作 |
| `TezSessionPool` | `ql/.../exec/tez/TezSessionPool.java` | Session 对象池实现 |
| `TezSessionPoolSession` | `ql/.../exec/tez/TezSessionPoolSession.java` | 池化 Session 的包装 |
| `SessionExpirationTracker` | `ql/.../exec/tez/SessionExpirationTracker.java` | 会话过期追踪和回收 |
| `TezTask` | `ql/.../exec/tez/TezTask.java` | Hive Tez 任务，负责构建 DAG 并提交 |
| `WorkloadManager` | `ql/.../exec/tez/WorkloadManager.java` | 工作负载管理器 |
| `WmTezSession` | `ql/.../exec/tez/WmTezSession.java` | 受 WM 管理的 Session |

### 3.2 关键方法逐行解读

#### 3.2.1 TezSessionPoolManager —— 池管理器

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionPoolManager.java
// 行号: 55-99

public class TezSessionPoolManager extends TezSessionPoolSession.AbstractTriggerValidator
    implements Manager, SessionExpirationTracker.RestartImpl {

  // LLAP 并发查询信号量
  private Semaphore llapQueue;
  private HiveConf initConf = null;
  private int numConcurrentLlapQueries = -1;

  // 默认 Session 池（预热的 Session 队列）
  private TezSessionPool<TezSessionPoolSession> defaultSessionPool;
  // 会话过期追踪器
  private SessionExpirationTracker expirationTracker;
  // 配置限制检查器
  private RestrictedConfigChecker restrictedConfig;

  // 是否有初始 Session（池化模式）
  private volatile boolean hasInitialSessions = false;

  // 单例模式
  private static TezSessionPoolManager instance = null;

  // 所有打开的 Session 列表（用于关闭时清理）
  private final List<TezSessionState> openSessions = new LinkedList<>();

  public static TezSessionPoolManager getInstance() {
    TezSessionPoolManager local = instance;
    if (local == null) {
      instance = local = new TezSessionPoolManager();
    }
    return local;
  }
}
```

#### 3.2.2 setupPool —— 初始化 Session 池

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionPoolManager.java
// 行号: 122-176

public void setupPool(HiveConf conf) throws Exception {
  // 读取默认队列列表（可配多个）
  final String[] defaultQueueList = HiveConf.getTrimmedStringsVar(
      conf, HiveConf.ConfVars.HIVE_SERVER2_TEZ_DEFAULT_QUEUES);

  // 每个队列的 Session 数量
  int numSessions = conf.getIntVar(
      ConfVars.HIVE_SERVER2_TEZ_SESSIONS_PER_DEFAULT_QUEUE);
  int numSessionsTotal = numSessions * defaultQueueList.length;

  if (numSessionsTotal > 0) {
    // 创建 Session 池，使用工厂模式创建 Session
    defaultSessionPool = new TezSessionPool<>(initConf, numSessionsTotal,
        enableAmRegistry, new TezSessionPool.SessionObjectFactory<>() {
          int queueIx = 0;

          @Override
          public TezSessionPoolSession create(TezSessionPoolSession oldSession) {
            // 轮询分配到不同队列
            // 保证 Session 在队列间均匀分布：s1q1, s1q2, s1q3, s2q1, ...
            int localQueueIx;
            synchronized (defaultQueueList) {
              localQueueIx = queueIx;
              ++queueIx;
              if (queueIx == defaultQueueList.length) queueIx = 0;
            }
            return createAndInitSession(
                defaultQueueList[localQueueIx], true, sessionConf);
          }
    });
  }

  // 创建过期追踪器
  expirationTracker = SessionExpirationTracker.create(conf, this);
  this.hasInitialSessions = numSessionsTotal > 0;
}
```

#### 3.2.3 TezSessionState —— 会话的核心状态

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionState.java
// 行号: 100-220（关键节选）

public class TezSessionState {
  public static final String LLAP_SERVICE = "LLAP";

  private final HiveConf conf;
  private Path tezScratchDir;          // HDFS 临时目录
  private LocalResource appJarLr;      // 应用 JAR 本地资源
  private TezClient session;           // Tez 客户端（与 AM 通信）
  private Future<TezClient> sessionFuture;  // 异步打开
  private String sessionId;            // 会话ID
  private String queueName;            // YARN 队列名
  private String user;                 // 用户名

  // 会话所有者线程（防止并发冲突）
  private AtomicReference<String> ownerThread = new AtomicReference<>(null);

  // 判断会话是否正在打开中（异步）
  public boolean isOpening() {
    if (session != null || sessionFuture == null) return false;
    try {
      TezClient session = sessionFuture.get(0, TimeUnit.NANOSECONDS);
      if (session == null) return false;
      this.session = session;
    } catch (TimeoutException e) {
      return true;  // 还没打开完成
    }
    return false;
  }

  // 判断会话是否已打开
  public boolean isOpen() {
    if (session != null) return true;
    if (sessionFuture == null) return false;
    // 尝试获取异步结果
    try {
      TezClient session = sessionFuture.get(0, TimeUnit.NANOSECONDS);
      if (session == null) return false;
      this.session = session;
    } catch (TimeoutException | CancellationException e) {
      return false;
    }
    return true;
  }
}
```

#### 3.2.4 TezSessionState.open —— 打开会话（启动 AM）

```java
// 核心流程（从源码中提取的逻辑）:

public void open(HiveConf conf) throws Exception {
  // 1. 创建 HDFS 临时目录
  tezScratchDir = createTezDir(sessionId);

  // 2. 构建 Tez 配置
  TezConfiguration tezConf = new TezConfiguration(true);

  // 3. 配置 LLAP 服务插件（如果启用）
  if (llapMode) {
    // 设置 LLAP 特有的 Task Scheduler、Container Launcher、Task Communicator
    ServicePluginsDescriptor pluginDesc = ServicePluginsDescriptor.create(
        true, // 启用 LLAP
        new TaskSchedulerDescriptor[] { ... },     // LlapTaskSchedulerService
        new ContainerLauncherDescriptor[] { ... },  // LlapContainerLauncher
        new TaskCommunicatorDescriptor[] { ... }    // LlapTaskCommunicator
    );
  }

  // 4. 创建 TezClient
  TezClient tezClient = TezClient.newBuilder("HIVE-" + sessionId, tezConf)
      .setIsSession(true)        // Session 模式
      .setLocalResources(...)     // 添加 JAR、配置等资源
      .setCredentials(...)        // 安全凭证
      .setServicePluginDescriptor(pluginDesc)  // 服务插件
      .build();

  // 5. 异步启动（不阻塞当前线程）
  tezClient.start();    // 向 YARN 提交 AM
  session = tezClient;

  // 6. 可选：预热（提前启动 Container）
  if (preWarmEnabled) {
    tezClient.preWarm(PreWarmVertex.create(...));
  }
}
```

#### 3.2.5 TezTask.execute —— DAG 构建与提交

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezTask.java
// 行号: 80+（核心逻辑提取）

public class TezTask extends Task<TezWork> {

  @Override
  public int execute(DriverContext driverContext) {
    // 1. 获取或创建 TezSession
    TezSessionState session = sessionState.getTezSession();

    // 2. 构建 Tez DAG
    DAG dag = build(conf, work, tezScratchDir, ...);

    // 3. 设置 DAG 访问控制
    dag.setAccessControls(new DAGAccessControls(...));

    // 4. 设置调用者上下文（用于 YARN UI 展示）
    dag.setCallerContext(CallerContext.create("HIVE",
        queryPlan.getQueryId(), "HIVE_QUERY_ID", queryId));

    // 5. 提交 DAG 到 Tez AM
    DAGClient dagClient = session.getSession().submitDAG(dag);

    // 6. 监控执行进度
    TezJobMonitor monitor = new TezJobMonitor(...);
    int rc = monitor.monitorExecution();

    // 7. 归还 Session 到池
    // (由 Driver 在查询结束后处理)

    return rc;
  }

  // 构建 DAG：遍历 TezWork 中的所有 BaseWork，创建 Vertex 和 Edge
  private DAG build(JobConf conf, TezWork work, ...) {
    DAG dag = DAG.create(work.getName());

    // 遍历所有 Work 节点
    for (BaseWork w : work.getAllWorkUnsorted()) {
      // 创建 Vertex（对应 Map 或 Reduce 阶段）
      Vertex vertex = utils.createVertex(conf, w, ...);
      dag.addVertex(vertex);
    }

    // 添加边（数据流关系）
    for (TezEdgeProperty edgeProp : work.getEdgeProperties()) {
      Edge edge = utils.createEdge(edgeProp, ...);
      dag.addEdge(edge);
    }

    return dag;
  }
}
```

### 3.3 调用链时序图

```
用户提交查询
    │
    ▼
Driver.execute()
    │
    ▼
TezTask.execute()
    │
    ├─ 1. SessionState.getTezSession()
    │       │
    │       ▼
    │   TezSessionPoolManager.getSession()
    │       │
    │       ├─ hasInitialSessions?
    │       │   ├─ Yes → defaultSessionPool.take()
    │       │   │        (从池中取一个预热的Session)
    │       │   │
    │       │   └─ No → createSession() + open()
    │       │            (新建Session，启动AM)
    │       │
    │       └─ 返回 TezSessionState
    │
    ├─ 2. build(conf, work) → 构建 DAG
    │       │
    │       ├─ 遍历 TezWork 中的 BaseWork
    │       ├─ 创建 Vertex (Map/Reduce)
    │       └─ 创建 Edge (数据流)
    │
    ├─ 3. session.getSession().submitDAG(dag)
    │       │
    │       ▼
    │   TezClient → Tez AM (YARN)
    │       │
    │       ▼
    │   AM 分配 Container → 执行 Task
    │
    ├─ 4. TezJobMonitor.monitorExecution()
    │       │
    │       ├─ 轮询 DAGClient.getDAGStatus()
    │       ├─ 打印进度 (Map 50%, Reduce 0%)
    │       └─ 等待完成
    │
    └─ 5. 查询结束
            │
            ├─ Session 归还到池（复用）
            │   TezSessionPoolManager.returnSession()
            │
            └─ 或 Session 关闭（超时/异常）
                session.close()
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：首次查询延迟高

```
现象：HS2 重启后第一批查询延迟 30-60 秒
原因：Session 池尚未预热，需要启动 Tez AM
解决：
  -- 增加预热 Session 数量
  SET hive.server2.tez.sessions.per.default.queue=3;
  SET hive.server2.tez.default.queues=default;
  -- 启用 Session 预热
  SET hive.prewarm.enabled=true;
```

#### 场景2：Session 泄露导致 YARN 资源耗尽

```
现象：YARN 上大量 Tez AM 处于 RUNNING 状态，但没有活跃查询
原因：Session 未正确归还到池中（代码异常路径泄露）
排查：
  查看 openSessions 列表大小
  检查 SessionExpirationTracker 是否工作正常
解决：
  SET hive.server2.tez.session.lifetime=36000s;  -- Session 最大生存时间
```

### 4.2 排障步骤

**Step 1：检查 Session 池状态**
```sql
-- 查看当前 Session 配置
SET hive.server2.tez.default.queues;
SET hive.server2.tez.sessions.per.default.queue;
SET hive.execution.engine;
```

**Step 2：监控 YARN Application**
```bash
# 查看所有 Tez Session Application
yarn application -list | grep -i tez
```

### 4.3 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.server2.tez.default.queues` | "" | 预热 Session 的 YARN 队列（逗号分隔） |
| `hive.server2.tez.sessions.per.default.queue` | 1 | 每个队列预热的 Session 数量 |
| `hive.server2.tez.session.lifetime` | 162h | Session 最大生存时间 |
| `hive.server2.tez.session.lifetime.jitter` | 162h | 生存时间随机抖动（避免同时过期） |
| `hive.server2.tez.sessions.custom.queue.allowed` | true | 是否允许用户指定自定义队列 |
| `hive.prewarm.enabled` | false | 是否预热 Container |
| `hive.prewarm.numcontainers` | 10 | 预热的 Container 数量 |
| `hive.server2.llap.concurrent.queries` | -1 | LLAP 并发查询限制 |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 概念 | Hive Tez Session | Spark Session | Impala | Presto |
|------|-----------------|---------------|--------|--------|
| 会话管理 | TezSessionPoolManager | SparkSession (共享) | 无独立 Session | 无 Session |
| AM 生命周期 | 长期运行（Session 模式） | Driver 长期运行 | Impalad 常驻 | Coordinator 常驻 |
| 资源隔离 | WorkloadManager | Dynamic Allocation | Admission Control | Resource Groups |
| DAG 提交 | submitDAG(DAG) | submitJob(Stage) | exec_request | 分发 Split |

### 5.2 面试高频题

**Q1：Tez Session 模式 vs 非 Session 模式的区别？**

> A: Session 模式下 TezClient 使用 `setIsSession(true)` 创建，AM 会持续运行，多个 DAG 可以复用同一个 AM。非 Session 模式每次提交 DAG 都会启动新的 AM。Session 模式省去了 AM 启动开销（通常 10-30 秒），适合交互式查询。

**Q2：TezSessionPoolManager 如何保证 Session 在多队列间均匀分布？**

> A: 使用轮询（Round-Robin）策略：维护一个 queueIx 计数器，每创建一个 Session 就递增，到达队列列表末尾后归零。初始化时 Session 分布为 s1q1, s1q2, s1q3, s2q1, s2q2, s2q3 ...

**Q3：WorkloadManager 的资源隔离原理？**

> A: WM 维护资源计划（Resource Plan），将集群资源按池（Pool）划分。每个查询根据用户/组映射到池。WM 通过 Tez AM 的 API 动态调整每个查询的 guaranteed task 数量，实现资源隔离。如果某个池的查询超出配额，可以触发 Kill/Move 操作。

### 5.3 思考题

1. **如果 Tez AM 崩溃了，TezSessionState 如何检测并恢复？**
2. **为什么需要 SessionExpirationTracker？不回收 Session 会有什么问题？**
3. **WorkloadManager 的 Kill Trigger 和 Move Trigger 分别适用于什么场景？**

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────┐
│          TezSession 管理与 AM 生命周期 · 知识晶体                 │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  核心思想：Session 池化复用 + 长期运行的 AM                       │
│                                                                  │
│  三层管理：                                                       │
│    TezSessionPoolManager (池管理器·单例)                         │
│      ├─ TezSessionPool (对象池·FIFO队列)                        │
│      │    └─ TezSessionPoolSession[] (预热的Session)             │
│      ├─ SessionExpirationTracker (超时回收)                      │
│      └─ WorkloadManager (资源隔离·可选)                         │
│                                                                  │
│  Session 生命周期：                                               │
│    create → open(启动AM) → submitDAG → returnToPool → expire    │
│                                                                  │
│  获取策略：                                                       │
│    有池 → pool.take() (取预热Session)                            │
│    无池 → new + open() (新建Session)                             │
│    指定队列 → new + open(queue) (自定义队列)                     │
│                                                                  │
│  关键配置：                                                       │
│    sessions.per.default.queue × default.queues = 池大小          │
│    session.lifetime = 自动回收周期                                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionPoolManager.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionState.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezTask.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/WorkloadManager.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionPool.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/SessionExpirationTracker.java`

2. **官方文档**
   - [Hive on Tez](https://cwiki.apache.org/confluence/display/Hive/Hive+on+Tez)
   - [Workload Management](https://cwiki.apache.org/confluence/display/Hive/Workload+Management)
