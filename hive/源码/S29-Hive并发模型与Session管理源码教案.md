# [教案] Hive并发模型与Session管理源码深度剖析

> 🎯 教学目标：掌握HiveServer2线程模型、SessionManager/OperationManager生命周期、异步执行与并发控制机制  
> ⏰ 预计学时：3学时  
> 📊 难度：⭐⭐⭐⭐（中高级）

---

## 一、课前导入（生活类比引入）

### 1.1 生活类比：酒店前台管理系统

- **前台接待（Thrift Server）**：接收客人的入住请求
- **房间管理（SessionManager）**：分配房间，跟踪入住状态
- **客房服务（OperationManager）**：每个需求(operation)异步执行
- **服务员线程池（BackgroundOperationPool）**：有限的服务员并行服务
- **退房检查（TimeoutChecker）**：超时自动退房

### 1.2 生产故障场景

```
故障现象：HiveServer2响应变慢，新连接被拒绝
ERROR: HiveServer2: AsyncExecPool size reached maximum. Rejected.

根因分析：
1. 并发查询过多，异步线程池被打满
2. 慢查询占用线程不释放
3. Session泄漏（客户端断开但Session未清理）
4. queryTimeout未设置，僵尸操作占用资源
```

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 含义 | 类比 |
|------|------|------|
| SessionManager | 会话管理器（HS2核心组件） | 酒店前台系统 |
| HiveSession | 单个用户会话 | 一个房间 |
| OperationManager | 操作管理器 | 客房服务中心 |
| SQLOperation | SQL操作（编译+执行+获取） | 具体服务请求 |
| BackgroundOperationPool | 异步执行线程池 | 服务员团队 |
| SessionHandle | 会话唯一标识 | 房卡 |
| OperationHandle | 操作唯一标识 | 服务工单号 |

### 2.2 HS2并发架构

```
┌────────────────────────────────────────────────────────────────────┐
│                      HiveServer2 Architecture                       │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌──────────────┐                                                  │
│  │Thrift Server │◀── JDBC/ODBC/Beeline 连接                       │
│  │(Binary/HTTP) │                                                  │
│  └──────┬───────┘                                                  │
│         │ openSession()                                            │
│  ┌──────▼────────────────────────────────────────────────────┐    │
│  │                  SessionManager                            │    │
│  │  ├─ handleToSession: Map<SessionHandle, HiveSession>      │    │
│  │  ├─ connectionsCount: Map<user/ip, count> (限流)           │    │
│  │  ├─ backgroundOperationPool: ThreadPoolExecutor            │    │
│  │  └─ timeoutChecker: 定期清理过期Session                    │    │
│  └──────┬────────────────────────────────────────────────────┘    │
│         │                                                          │
│  ┌──────▼────────────────────────────────────────────────────┐    │
│  │              HiveSessionImpl                               │    │
│  │  ├─ sessionHandle: 唯一标识                                │    │
│  │  ├─ username / ipAddress                                   │    │
│  │  ├─ sessionConf: 会话级配置覆盖                            │    │
│  │  ├─ operationManager: 操作管理                             │    │
│  │  └─ lastAccessTime / creationTime                          │    │
│  └──────┬────────────────────────────────────────────────────┘    │
│         │ executeStatement()                                       │
│  ┌──────▼────────────────────────────────────────────────────┐    │
│  │              OperationManager                              │    │
│  │  ├─ handleToOperation: Map<OperationHandle, Operation>    │    │
│  │  ├─ queryIdOperation: Map<queryId, Operation>             │    │
│  │  ├─ liveQueryInfos / historicalQueryInfos (WebUI)         │    │
│  │  └─ newExecuteStatementOperation() → SQLOperation         │    │
│  └──────┬────────────────────────────────────────────────────┘    │
│         │                                                          │
│  ┌──────▼────────────────────────────────────────────────────┐    │
│  │                  SQLOperation                              │    │
│  │  ├─ driver: IDriver (查询编译+执行)                        │    │
│  │  ├─ runAsync / queryTimeout                                │    │
│  │  ├─ operationState: INITIALIZED→RUNNING→FINISHED/ERROR    │    │
│  │  └─ backgroundHandle: Future (异步执行句柄)                │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 SessionManager核心结构

> 📁 源码位置：`service/src/java/org/apache/hive/service/cli/session/SessionManager.java`

#### 3.1.1 核心字段（第64-93行）

```java
public class SessionManager extends CompositeService {
    
    // 会话存储：SessionHandle → HiveSession
    private final Map<SessionHandle, HiveSession> handleToSession =
        new ConcurrentHashMap<>();
    
    // 连接数限流计数器
    private final Map<String, LongAdder> connectionsCount = new ConcurrentHashMap<>();
    private int userLimit;           // 每用户连接上限
    private int ipAddressLimit;      // 每IP连接上限
    private int userIpAddressLimit;  // 每用户+IP组合上限
    
    // 异步操作线程池
    private ThreadPoolExecutor backgroundOperationPool;
    
    // Session超时管理
    private long checkInterval;      // 检查间隔
    private long sessionTimeout;     // 空闲超时
    private boolean checkOperation;  // 是否检查操作状态
    
    private volatile boolean shutdown;
    private final HiveServer2 hiveServer2;
}
```

#### 3.1.2 初始化（第96-117行）

```java
@Override
public synchronized void init(HiveConf hiveConf) {
    this.hiveConf = hiveConf;
    
    // 1. 初始化操作日志
    if (hiveConf.getBoolVar(ConfVars.HIVE_SERVER2_LOGGING_OPERATION_ENABLED)) {
        initOperationLogRootDir();
    }
    
    // 2. 创建异步线程池
    createBackgroundOperationPool();
    
    // 3. 添加OperationManager子服务
    addService(operationManager);
    
    // 4. 注册Metrics
    Metrics metrics = MetricsFactory.getInstance();
    if (metrics != null) {
        registerOpenSesssionMetrics(metrics);
        registerActiveSesssionMetrics(metrics);
    }
    
    // 5. 设置连接限制
    userLimit = hiveConf.getIntVar(ConfVars.HIVE_SERVER2_LIMIT_CONNECTIONS_PER_USER);
    ipAddressLimit = hiveConf.getIntVar(ConfVars.HIVE_SERVER2_LIMIT_CONNECTIONS_PER_IPADDRESS);
    userIpAddressLimit = hiveConf.getIntVar(ConfVars.HIVE_SERVER2_LIMIT_CONNECTIONS_PER_USER_IPADDRESS);
}
```

#### 3.1.3 创建异步线程池（第178-220行）

```java
private void createBackgroundOperationPool() {
    int poolSize = hiveConf.getIntVar(ConfVars.HIVE_SERVER2_ASYNC_EXEC_THREADS);       // 默认100
    int poolQueueSize = hiveConf.getIntVar(ConfVars.HIVE_SERVER2_ASYNC_EXEC_WAIT_QUEUE_SIZE); // 默认100
    long keepAliveTime = HiveConf.getTimeVar(hiveConf, 
        ConfVars.HIVE_SERVER2_ASYNC_EXEC_KEEPALIVE_TIME, TimeUnit.SECONDS);            // 默认10s

    // 有界队列 + 固定大小线程池
    final BlockingQueue queue = new LinkedBlockingQueue<Runnable>(poolQueueSize);
    backgroundOperationPool = new ThreadPoolExecutor(
        poolSize,           // 核心线程数
        poolSize,           // 最大线程数（= 核心，不扩展）
        keepAliveTime,      // 空闲线程存活时间
        TimeUnit.SECONDS, 
        queue,              // 有界任务队列
        new ThreadFactoryWithGarbageCleanup(threadPoolName));
    backgroundOperationPool.allowCoreThreadTimeOut(true);  // 允许核心线程超时退出
}
```

**关键设计**：
- 线程数 = poolSize（固定），不会动态扩展
- 队列满时直接拒绝（RejectedExecutionException）
- `allowCoreThreadTimeOut(true)` → 空闲时线程可退出

#### 3.1.4 Session超时检查器（第262-308行）

```java
private void startTimeoutChecker() {
    final long interval = Math.max(checkInterval, 3000L);  // 最小3秒
    
    final Runnable timeoutChecker = new Runnable() {
        @Override
        public void run() {
            sleepFor(interval);
            while (!shutdown) {
                long current = System.currentTimeMillis();
                for (HiveSession session : new ArrayList<>(handleToSession.values())) {
                    if (shutdown) break;
                    
                    // 判断Session是否超时
                    if (sessionTimeout > 0 
                        && session.getLastAccessTime() + sessionTimeout <= current
                        && (!checkOperation || session.getNoOperationTime() > sessionTimeout)) {
                        
                        LOG.warn("Session " + handle + " is Timed-out");
                        try {
                            closeSession(handle);  // 强制关闭
                        } catch (HiveSQLException e) {
                            LOG.warn("Exception closing session", e);
                        }
                        // 记录Metric
                        metrics.incrementCounter(MetricsConstant.HS2_ABANDONED_SESSIONS);
                    } else {
                        session.closeExpiredOperations();  // 关闭过期的操作
                    }
                }
                sleepFor(interval);
            }
        }
    };
    backgroundOperationPool.execute(timeoutChecker);  // 复用线程池
}
```

---

### 3.2 OperationManager：操作管理

> 📁 源码位置：`service/src/java/org/apache/hive/service/cli/operation/OperationManager.java`

```java
public class OperationManager extends AbstractService {
    
    // 操作存储
    private final ConcurrentHashMap<OperationHandle, Operation> handleToOperation = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Operation> queryIdOperation = new ConcurrentHashMap<>();
    
    // WebUI支持
    private QueryInfoCache historicalQueryInfos;  // LRU缓存
    private Map<String, QueryInfo> liveQueryInfos = new LinkedHashMap<>();
    
    // 创建SQL执行操作
    public ExecuteStatementOperation newExecuteStatementOperation(
        HiveSession parentSession, String statement, 
        Map<String, String> confOverlay, boolean runAsync, long queryTimeout) {
        
        ExecuteStatementOperation op = ExecuteStatementOperation
            .newExecuteStatementOperation(parentSession, statement, confOverlay, runAsync, queryTimeout);
        addOperation(op);
        return op;
    }
}
```

---

### 3.3 SQLOperation：异步执行核心

> 📁 源码位置：`service/src/java/org/apache/hive/service/cli/operation/SQLOperation.java`

```java
public class SQLOperation extends ExecuteStatementOperation {
    private IDriver driver = null;           // 查询驱动器
    private TableSchema resultSchema;        // 结果Schema
    private volatile MetricsScope currentSQLStateScope;
    private long queryTimeout;               // 查询超时
    private final boolean runAsync;          // 是否异步执行
    
    // 全局查询计数（按用户）
    private static Map<String, AtomicInteger> userQueries = new HashMap<>();

    public SQLOperation(HiveSession parentSession, String statement, 
        Map<String, String> confOverlay, boolean runInBackground, long queryTimeout) {
        super(parentSession, statement, confOverlay, runInBackground);
        this.runAsync = runInBackground;
        this.queryTimeout = queryTimeout;
        
        // 配置级超时覆盖
        long timeout = HiveConf.getTimeVar(queryState.getConf(),
            HiveConf.ConfVars.HIVE_QUERY_TIMEOUT_SECONDS, TimeUnit.SECONDS);
        if (timeout > 0 && (queryTimeout <= 0 || timeout < queryTimeout)) {
            this.queryTimeout = timeout;
        }
    }
}
```

#### 异步执行流程

```java
// SQLOperation.runInternal()
private void runInternal(boolean asyncMode) {
    setState(OperationState.PENDING);
    
    if (asyncMode) {
        // 异步模式：提交到线程池
        Runnable work = new BackgroundWork(getCurrentUGI(), parentSession);
        try {
            backgroundHandle = getParentSession().getSessionManager()
                .submitBackgroundOperation(work);
        } catch (RejectedExecutionException e) {
            // 线程池满！
            setState(OperationState.ERROR);
            throw new HiveSQLException("The background threadpool cannot accept new task");
        }
    } else {
        // 同步模式：当前线程直接执行
        execute();
    }
}

private void execute() {
    // 1. 编译SQL
    response = driver.compileAndRespond(statement);
    
    // 2. 执行
    response = driver.run();
    
    // 3. 获取结果Schema
    if (driver.getResults(results)) {
        resultSchema = new TableSchema(driver.getSchema());
    }
    
    setState(OperationState.FINISHED);
}
```

---

### 3.4 调用链时序图

```
┌───────┐  ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌──────────┐
│Beeline│  │ThriftSrv │  │SessionMgr  │  │OpManager │  │SQLOp     │
└──┬────┘  └────┬─────┘  └─────┬──────┘  └────┬─────┘  └────┬─────┘
   │            │               │              │              │
   │─OpenSession▶               │              │              │
   │            │─openSession──▶│              │              │
   │            │               │─new Session  │              │
   │            │               │─checkLimit() │              │
   │            │◀──handle──────│              │              │
   │◀─handle────│               │              │              │
   │            │               │              │              │
   │─ExecuteStmt▶               │              │              │
   │            │─executeStmt──▶│              │              │
   │            │               │─newExecOp───▶│              │
   │            │               │              │─new SQLOp───▶│
   │            │               │              │              │─runAsync
   │            │               │─submitBgOp──▶│              │ (ThreadPool)
   │            │◀──opHandle────│              │              │
   │◀─opHandle──│               │              │              │
   │            │               │              │              │──compile
   │            │               │              │              │──execute
   │            │               │              │              │──FINISHED
   │─GetStatus─▶│               │              │              │
   │◀─FINISHED──│               │              │              │
   │            │               │              │              │
   │─FetchResult▶               │              │              │
   │◀─rows──────│               │              │              │
   │            │               │              │              │
   │─CloseOp───▶│               │              │              │
   │─CloseSession▶              │─closeSession │              │
   │            │               │─decrementCnt │              │
```

---

## 四、生产实战案例

### 4.1 案例一：线程池打满导致新查询被拒绝

**排障**：
```sql
-- 1. 检查当前活跃查询数
-- WebUI: http://hs2:10002 查看Active Sessions和Operations

-- 2. 检查线程池配置
SET hive.server2.async.exec.threads;           -- 默认100
SET hive.server2.async.exec.wait.queue.size;   -- 默认100

-- 3. 增大线程池
SET hive.server2.async.exec.threads=200;
-- 需要重启HS2生效（静态配置）

-- 4. 设置查询超时防止僵尸查询
SET hive.query.timeout.seconds=3600;  -- 1小时超时
```

### 4.2 参数调优

| 参数 | 默认值 | 建议 | 说明 |
|------|--------|------|------|
| `hive.server2.async.exec.threads` | 100 | 200 | 异步线程池大小 |
| `hive.server2.async.exec.wait.queue.size` | 100 | 200 | 等待队列大小 |
| `hive.server2.idle.session.timeout` | 7200s | 3600s | 空闲Session超时 |
| `hive.server2.session.check.interval` | 6000ms | 60000ms | 检查间隔 |
| `hive.query.timeout.seconds` | 0 | 3600 | 查询超时(0=无限) |
| `hive.server2.limit.connections.per.user` | 0 | 50 | 每用户连接上限 |
| `hive.server2.limit.connections.per.ipaddress` | 0 | 100 | 每IP连接上限 |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：HiveServer2的异步执行模型是如何实现的？**

A：客户端调用executeStatement(runAsync=true)后：
1. SessionManager将SQLOperation包装为Runnable提交到ThreadPoolExecutor
2. 立即返回OperationHandle给客户端
3. 客户端通过GetOperationStatus轮询状态
4. FINISHED后通过FetchResults获取结果
5. 线程池满时抛RejectedExecutionException

**Q2：Session超时清理机制是怎样的？**

A：TimeoutChecker线程定期扫描所有Session：
- `lastAccessTime + sessionTimeout <= current` → Session空闲超时
- `checkOperation=true`时还要检查是否有正在执行的操作
- 超时Session强制close（释放资源、关闭Operation、递减连接计数）

**Q3：如何防止单用户占满所有连接？**

A：三级限流：
- `LIMIT_CONNECTIONS_PER_USER`：每用户上限
- `LIMIT_CONNECTIONS_PER_IPADDRESS`：每IP上限
- `LIMIT_CONNECTIONS_PER_USER_IPADDRESS`：每用户+IP组合上限

### 5.2 思考题

1. 为什么HS2使用固定大小线程池而非CachedThreadPool？
2. 如果一个查询在编译阶段(compile)就hang住了，queryTimeout能否生效？
3. 如何设计一个查询优先级队列，让VIP用户的查询优先执行？

---

## 六、知识晶体（一页纸总结）

```
┌────────────────────────────────────────────────────────────────┐
│       Hive 并发模型与Session管理核心知识晶体                    │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  层次：ThriftServer → SessionManager → OperationManager → Op  │
│                                                                │
│  SessionManager：                                              │
│  ├── ConcurrentHashMap<Handle, Session> (线程安全)              │
│  ├── ThreadPoolExecutor(fixed, bounded queue) (异步执行)        │
│  ├── TimeoutChecker (定期扫描, 超时关闭)                        │
│  └── 三级限流(user/ip/user+ip)                                 │
│                                                                │
│  SQLOperation 状态机：                                          │
│  INITIALIZED → PENDING → RUNNING → FINISHED / ERROR / CANCELED │
│                                                                │
│  异步执行流程：                                                  │
│  submitBgOp → ThreadPool → compile → execute → FINISHED        │
│  客户端：executeStmt → getStatus轮询 → fetchResults            │
│                                                                │
│  关键参数：                                                     │
│  • async.exec.threads=100 (线程池大小)                          │
│  • async.exec.wait.queue.size=100 (队列大小)                    │
│  • idle.session.timeout=7200s (Session超时)                     │
│  • query.timeout.seconds=0 (查询超时)                           │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. Hive源码：`service/src/java/org/apache/hive/service/cli/session/SessionManager.java`
2. Hive源码：`service/src/java/org/apache/hive/service/cli/operation/SQLOperation.java`
3. Hive源码：`service/src/java/org/apache/hive/service/cli/operation/OperationManager.java`
4. HIVE-4239: HiveServer2 concurrent model
5. Hive Wiki: HiveServer2 Architecture
