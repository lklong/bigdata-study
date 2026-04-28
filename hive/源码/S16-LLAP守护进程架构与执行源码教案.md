# [教案] LLAP 守护进程架构与执行源码深度剖析

> 🎯 教学目标：掌握 LLAP Daemon 的启动流程、核心组件架构、任务调度机制和缓存管理 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：外卖 vs 食堂

传统的 Hive 查询就像**叫外卖**——每次下单（提交查询），都要现做（启动 Container），做完送到（返回结果），厨房就关了（Container 释放）。下次再点同样的菜，又要重新开火、备料、做菜。

LLAP（Live Long and Process）就像把外卖厨房升级成了**常驻食堂**：
- **常驻厨师**（Executor 线程池）一直在岗，不用每次开火
- **食材缓存**（IO Cache）热门食材提前备好，不用每次从仓库搬
- **点餐台**（RPC Server）随时接收订单，即时出餐
- **多条生产线**（多 Executor 并发）同时做多道菜

### 生产故障场景

```
现象：启用 LLAP 后，前几次查询很慢，之后同样的查询快了 10 倍
原因：第一次查询需要从 HDFS 读数据并填充 IO Cache，后续命中缓存
排查：通过 LLAP Web UI 查看缓存命中率从 0% 上升到 95%
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| LlapDaemon | LLAP 守护进程主类，管理所有子服务 | 食堂的总经理，管理厨房、仓库、前台 |
| ContainerRunnerImpl | 接收并管理 Fragment 执行请求 | 前台接待员，负责接收订单分配给厨师 |
| TaskExecutorService | 任务执行器+等待队列+优先级调度 | 厨师长，决定哪道菜先做、谁来做 |
| TaskRunnerCallable | 单个 Fragment 的执行封装 | 一道菜的制作流程卡 |
| AMReporter | 向 Tez AM 汇报心跳和 Fragment 状态 | 送餐员，负责告诉客户菜做好了 |
| LlapProtocolServerImpl | RPC 服务端，接收来自 AM 的请求 | 电话接线员，接听订单电话 |
| BuddyAllocator | 伙伴分配器，管理 IO 缓存内存 | 仓库管理员，用固定格子分配存储空间 |
| LowLevelCacheImpl | 底层数据缓存，以列块为单位缓存 | 食材冷藏柜，按种类分格存放 |
| LowLevelLrfuCachePolicy | LRFU 缓存淘汰策略（LRU + LFU 混合） | 冷藏柜淘汰规则：很久没用且使用频率低的先扔 |
| QueryTracker | 追踪查询生命周期和本地资源 | 订单跟踪系统 |

### 2.2 架构图/流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                       LlapDaemon (CompositeService)              │
│                                                                  │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────┐ │
│  │ LlapProtocol     │  │ ContainerRunner   │  │ AMReporter   │ │
│  │ ServerImpl       │→│ Impl              │→│              │ │
│  │ (RPC Server)     │  │ (请求分发)        │  │ (心跳上报)    │ │
│  └──────────────────┘  └────────┬──────────┘  └──────────────┘ │
│                                 │                                │
│                                 ▼                                │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │           TaskExecutorService (Scheduler)                 │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │   │
│  │  │ WaitQueue   │→│ Scheduler    │→│ ExecutorPool   │  │   │
│  │  │ (优先级队列) │  │ Thread       │  │ (线程池)       │  │   │
│  │  └─────────────┘  └──────────────┘  └────────────────┘  │   │
│  │                    ┌──────────────┐                       │   │
│  │                    │ Preemption   │                       │   │
│  │                    │ Queue        │                       │   │
│  │                    └──────────────┘                       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              IO Cache Layer                                │   │
│  │  ┌──────────────┐  ┌─────────────┐  ┌────────────────┐  │   │
│  │  │ LowLevel     │  │ BuddyAlloc  │  │ LRFU Cache     │  │   │
│  │  │ CacheImpl    │  │ ator        │  │ Policy         │  │   │
│  │  │ (数据缓存)    │  │ (内存分配)   │  │ (淘汰策略)     │  │   │
│  │  └──────────────┘  └─────────────┘  └────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────┐  ┌──────────────┐  ┌────────────┐                │
│  │ Registry │  │ WebServices  │  │ Shuffle    │                │
│  │ Service  │  │ (Web UI)     │  │ Handler    │                │
│  └──────────┘  └──────────────┘  └────────────┘                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|----------|------|
| `LlapDaemon` | `llap-server/.../daemon/impl/LlapDaemon.java` | 守护进程主类，组装所有子服务 |
| `ContainerRunner` | `llap-server/.../daemon/ContainerRunner.java` | 任务运行器接口（submitWork/queryComplete） |
| `ContainerRunnerImpl` | `llap-server/.../daemon/impl/ContainerRunnerImpl.java` | 接收请求、创建 TaskRunnerCallable、提交调度 |
| `TaskExecutorService` | `llap-server/.../daemon/impl/TaskExecutorService.java` | 等待队列 + 线程池 + 抢占式调度 |
| `TaskRunnerCallable` | `llap-server/.../daemon/impl/TaskRunnerCallable.java` | 单个 Tez Fragment 的执行封装 |
| `AMReporter` | `llap-server/.../daemon/impl/AMReporter.java` | 与 Tez AM 保持心跳并上报状态 |
| `QueryTracker` | `llap-server/.../daemon/impl/QueryTracker.java` | 追踪查询生命周期，管理本地资源 |
| `BuddyAllocator` | `llap-server/.../cache/BuddyAllocator.java` | 伙伴系统内存分配器 |
| `LowLevelCacheImpl` | `llap-server/.../cache/LowLevelCacheImpl.java` | 底层列块数据缓存 |
| `LowLevelLrfuCachePolicy` | `llap-server/.../cache/LowLevelLrfuCachePolicy.java` | LRFU 缓存淘汰策略 |

### 3.2 关键方法逐行解读

#### 3.2.1 LlapDaemon —— 守护进程的"总指挥部"

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/LlapDaemon.java
// 行号: 92-116

public class LlapDaemon extends CompositeService
    implements ContainerRunner, LlapDaemonMXBean {

  // 核心组件
  private final SecretManager secretManager;         // 安全认证
  private final LlapProtocolServerImpl server;       // RPC 服务端
  private final ContainerRunnerImpl containerRunner; // 任务运行管理
  private final AMReporter amReporter;               // AM 心跳上报
  private final LlapRegistryService registry;        // 服务注册（ZK）
  private final LlapWebServices webServices;         // Web UI
  private final JvmPauseMonitor pauseMonitor;        // GC 暂停监控
  private final LlapDaemonExecutorMetrics metrics;   // 执行指标
  private final FunctionLocalizer fnLocalizer;       // UDF 本地化

  // 关键参数
  private final boolean llapIoEnabled;               // IO缓存是否启用
  private final long executorMemoryPerInstance;      // 执行器内存
  private final long ioMemoryPerInstance;            // IO缓存内存
  private final int numExecutors;                    // 执行器数量
  private final long maxJvmMemory;                   // JVM 最大堆
  private final String[] localDirs;                  // 本地工作目录
}
```

#### 3.2.2 LlapDaemon 构造 —— 组件初始化

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/LlapDaemon.java
// 行号: 123-296（关键节选）

public LlapDaemon(Configuration daemonConf, int numExecutors,
    long executorMemoryBytes, boolean ioEnabled, boolean isDirectCache,
    long ioMemoryBytes, String[] localDirs, int srvPort,
    int mngPort, int shufflePort, int webPort, String appName) {
  super("LlapDaemon");

  // 参数校验
  Preconditions.checkArgument(numExecutors > 0);
  Preconditions.checkArgument(localDirs != null && localDirs.length > 0);

  // 内存分配：executor内存 + IO缓存内存 不能超过 JVM 堆
  long xmxHeadRoomBytes = determineXmxHeadroom(daemonConf, executorMemoryBytes, maxJvmMemory);
  this.executorMemoryPerInstance = executorMemoryBytes - xmxHeadRoomBytes;
  this.ioMemoryPerInstance = ioMemoryBytes;

  // 从配置读取等待队列大小和抢占开关
  int waitQueueSize = HiveConf.getIntVar(daemonConf,
      ConfVars.LLAP_DAEMON_TASK_SCHEDULER_WAIT_QUEUE_SIZE);
  boolean enablePreemption = HiveConf.getBoolVar(daemonConf,
      ConfVars.LLAP_DAEMON_TASK_SCHEDULER_ENABLE_PREEMPTION);

  // 初始化 Shuffle Handler
  this.shuffleHandlerConf = new Configuration(daemonConf);
  this.shuffleHandlerConf.setInt(ShuffleHandler.SHUFFLE_PORT_CONFIG_KEY, shufflePort);

  // 初始化 UDF 本地化（下载永久函数到本地）
  if (HiveConf.getBoolVar(daemonConf, ConfVars.LLAP_DAEMON_DOWNLOAD_PERMANENT_FNS)) {
    this.fnLocalizer = new FunctionLocalizer(daemonConf, localDirs[0]);
  }

  // 初始化指标系统
  LlapMetricsSystem.initialize("LlapDaemon");
  this.pauseMonitor = new JvmPauseMonitor(daemonConf);
  this.metrics = LlapDaemonExecutorMetrics.create(...);

  // 初始化 AM 上报器
  this.amReporter = new AMReporter(numExecutors, maxAmReporterThreads,
      srvAddress, new QueryFailedHandlerProxy(), daemonConf, daemonId, socketFactory);

  // 初始化 RPC 服务端
  this.server = new LlapProtocolServerImpl(secretManager,
      numHandlers, this, srvAddress, mngAddress, srvPort, mngPort, daemonId);

  // 核心！初始化 ContainerRunner（包含 TaskExecutorService）
  this.containerRunner = new ContainerRunnerImpl(daemonConf, numExecutors,
      waitQueueSize, enablePreemption, localDirs, this.shufflePort,
      srvAddress, executorMemoryPerInstance, metrics,
      amReporter, executorClassLoader, daemonId, fsUgiFactory, socketFactory);
  addIfService(containerRunner);
}
```

**关键设计**：LlapDaemon 使用 Hadoop 的 `CompositeService` 模式，所有组件通过 `addIfService()` 注册，启动/停止时会自动级联管理。

#### 3.2.3 ContainerRunner 接口 —— 与 Tez AM 交互的协议

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/ContainerRunner.java
// 行号: 30-45

public interface ContainerRunner {

  // 提交一个 Fragment 执行请求
  SubmitWorkResponseProto submitWork(SubmitWorkRequestProto request)
      throws IOException;

  // 数据源状态变更（如上游 Vertex 完成）
  SourceStateUpdatedResponseProto sourceStateUpdated(
      SourceStateUpdatedRequestProto request) throws IOException;

  // 查询完成通知（清理资源）
  QueryCompleteResponseProto queryComplete(
      QueryCompleteRequestProto request) throws IOException;

  // 终止一个正在执行的 Fragment
  TerminateFragmentResponseProto terminateFragment(
      TerminateFragmentRequestProto request) throws IOException;

  // 更新 Fragment 运行信息
  UpdateFragmentResponseProto updateFragment(
      UpdateFragmentRequestProto request) throws IOException;
}
```

#### 3.2.4 ContainerRunnerImpl.submitWork —— 任务提交的核心入口

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/ContainerRunnerImpl.java
// 行号: 96-199（关键节选）

public class ContainerRunnerImpl extends CompositeService
    implements ContainerRunner, FragmentCompletionHandler, QueryFailedHandler {

  private final AMReporter amReporter;
  private final QueryTracker queryTracker;
  private final Scheduler<TaskRunnerCallable> executorService;  // TaskExecutorService
  private final long memoryPerExecutor;

  public ContainerRunnerImpl(Configuration conf, int numExecutors, int waitQueueSize,
      boolean enablePreemption, ...) {
    super("ContainerRunnerImpl");

    // 初始化查询追踪器
    this.queryTracker = new QueryTracker(conf, localDirsBase, clusterId);

    // 核心！创建 TaskExecutorService（含等待队列和线程池）
    this.executorService = new TaskExecutorService(numExecutors, waitQueueSize,
        waitQueueSchedulerClassName, enablePreemption, classLoader, metrics, null);

    // 计算每个 Executor 分配的内存
    this.memoryPerExecutor = (long)(totalMemoryAvailableBytes / (float) numExecutors);
  }

  @Override
  public SubmitWorkResponseProto submitWork(SubmitWorkRequestProto request)
      throws IOException {
    // 1. 安全检查（Token 验证）
    LlapTokenInfo tokenInfo = LlapTokenChecker.getTokenInfo(clusterId);

    // 2. 解析 Vertex 规格（包含 DAG 信息、输入输出规格等）
    SignableVertexSpec vertex = extractVertexSpec(request, tokenInfo);

    // 3. 注册到 QueryTracker（追踪查询生命周期）
    QueryIdentifier queryIdentifier = ...;
    queryTracker.registerFragment(queryIdentifier, ...);

    // 4. 创建 TaskRunnerCallable（封装执行逻辑）
    TaskRunnerCallable callable = new TaskRunnerCallable(request, conf, ...);

    // 5. 提交到 TaskExecutorService 调度执行
    SubmissionState submissionState = executorService.schedule(callable);

    // 6. 注册 AM 心跳（让 AM 知道这个 Daemon 还活着）
    amReporter.registerTask(amNodeInfo, queryIdentifier);

    return response;
  }
}
```

#### 3.2.5 TaskExecutorService —— 调度核心：等待队列 + 抢占

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/TaskExecutorService.java
// 行号: 91-117

public class TaskExecutorService extends AbstractService
    implements Scheduler<TaskRunnerCallable>, SchedulerFragmentCompletingListener {

  // 实际执行工作的线程池
  private final ListeningExecutorService executorService;

  // 等待队列（优先级排序）—— 任务先入队等待
  final EvictingPriorityBlockingQueue<TaskWrapper> waitQueue;

  // 从等待队列取任务的调度线程
  private final ListeningExecutorService waitQueueExecutorService;

  // 任务完成回调线程池
  private final ListeningExecutorService executionCompletionExecutorService;

  // 抢占队列 —— 可被抢占的正在运行的任务
  final BlockingQueue<TaskWrapper> preemptionQueue;

  // 是否启用抢占
  private final boolean enablePreemption;

  // 可用执行槽位数
  private final AtomicInteger numSlotsAvailable;

  // 最大并行执行器数量
  private final int maxParallelExecutors;
}
```

**调度流程**：
```
submitWork() → TaskRunnerCallable 入 WaitQueue
                    │
                    ▼
         WaitQueue Scheduler Thread（循环）
                    │
           ┌────────┴─────────┐
           │有空闲 Executor?   │
           ├─ Yes ────────────┼──→ 直接提交到 ExecutorPool 执行
           │                  │
           └─ No ─────────────┼──→ 启用抢占?
                              │     │
                              │  ┌──┴──┐
                              │  │ Yes │──→ 新任务优先级 > 运行中最低优先级?
                              │  │     │     ├─ Yes → 抢占（kill低优先级）→ 执行新任务
                              │  │     │     └─ No  → 留在 WaitQueue 等待
                              │  └─────┘
                              │  ┌──┐
                              │  │No│──→ 留在 WaitQueue 等待
                              │  └──┘
                              │
                              └──→ WaitQueue 满? → 返回 REJECTED
```

#### 3.2.6 TaskRunnerCallable —— Fragment 的实际执行

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/TaskRunnerCallable.java
// 行号: 93-100

public class TaskRunnerCallable extends CallableWithNdc<TaskRunner2Result> {
  private final SubmitWorkRequestProto request;  // 原始请求
  private final Configuration conf;
  private final ObjectRegistryImpl objectRegistry;  // 跨 Fragment 对象共享
  private final ExecutionContext executionContext;   // 执行上下文

  // call() 方法是实际执行入口
  // 内部创建 TezTaskRunner2 来执行 Tez Fragment
  // TezTaskRunner2 会：
  //   1. 初始化 Input/Output
  //   2. 调用 Processor.run()（实际处理逻辑）
  //   3. 返回执行结果
}
```

#### 3.2.7 AMReporter —— 与 Tez AM 的心跳机制

```java
// 文件: llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/AMReporter.java
// 行号: 15-70（接口说明）

// AMReporter 负责：
// 1. 维护与每个 AM 的 RPC 连接
// 2. 定期发送心跳（告诉 AM "我还活着"）
// 3. 上报 Fragment 完成状态
// 4. 处理 AM 失联（如果 AM 挂了，清理相关任务）

// 使用 DelayQueue 管理心跳间隔
// 当 LLAP Daemon 长时间无法联系 AM 时，
// 会将该 AM 关联的所有 Fragment 标记为失败
```

### 3.3 调用链时序图

```
Tez AM                 LlapDaemon                     内部组件
  │                        │                              │
  │  SubmitWork(RPC)       │                              │
  │──────────────────────→ │                              │
  │                        │  LlapProtocolServerImpl      │
  │                        │  接收请求                     │
  │                        │──→ LlapDaemon.submitWork()   │
  │                        │       │                      │
  │                        │       ▼                      │
  │                        │  ContainerRunnerImpl         │
  │                        │  .submitWork()               │
  │                        │       │                      │
  │                        │       ├─ 安全检查 (Token)     │
  │                        │       ├─ 解析 VertexSpec      │
  │                        │       ├─ queryTracker.register│
  │                        │       │                      │
  │                        │       ▼                      │
  │                        │  创建 TaskRunnerCallable     │
  │                        │       │                      │
  │                        │       ▼                      │
  │                        │  TaskExecutorService         │
  │                        │  .schedule()                 │
  │                        │       │                      │
  │                        │       ├─ 入 WaitQueue        │
  │                        │       │                      │
  │                        │       ▼ WaitQueue Scheduler  │
  │                        │       ├─ 有空闲Executor?     │
  │                        │       │  └─ Yes → submit     │
  │                        │       │     到 ExecutorPool  │
  │                        │       │                      │
  │                        │       ▼                      │
  │                        │  TaskRunnerCallable.call()   │
  │                        │       │                      │
  │                        │       ├─ 创建 TezTaskRunner2 │
  │                        │       ├─ 初始化 Input/Output │
  │                        │       ├─ Processor.run()     │
  │                        │       │  (向量化读取+处理)    │
  │                        │       │  ↓ IO Cache 命中?    │
  │                        │       │  ├─ Yes → 直接读缓存 │
  │                        │       │  └─ No → 读HDFS→缓存 │
  │                        │       │                      │
  │                        │       ▼                      │
  │                        │  Fragment 完成               │
  │                        │       │                      │
  │  ←─────────────────────│  AMReporter 上报结果         │
  │  Fragment完成通知       │                              │
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：LLAP 内存 OOM

```
现象：LLAP Daemon 频繁被 YARN kill，日志报 "Container killed by YARN for exceeding memory limits"
原因：executor 内存 + IO 缓存 + JVM 开销 超过了 YARN Container 内存
排查：
  检查配置：
  hive.llap.daemon.yarn.container.mb = 容器总内存
  hive.llap.daemon.memory.per.instance.mb = executor 内存
  hive.llap.io.memory.size = IO 缓存内存
  确保：executor + io_cache + JVM_overhead < container_mb
```

#### 场景2：任务长时间在 WaitQueue 排队

```
现象：Dashboard 显示大量任务在等待，查询延迟很高
原因：numExecutors 配置过少，或者某些慢查询占满了所有 Executor
排查：
  查看 LLAP Web UI → Executor 使用率
  查看 WaitQueue 深度
  检查是否有长时间运行的 Fragment
解决：
  增加 numExecutors 或启用抢占
  SET hive.llap.daemon.task.scheduler.enable.preemption=true;
```

#### 场景3：缓存命中率低

```
现象：即使反复查询相同的数据，IO 缓存命中率仍然很低
原因：
  1. IO 缓存内存太小，数据被频繁淘汰
  2. 查询访问的数据分布太散（大量不同的文件/列）
  3. 数据被更新（缓存失效）
排查：
  查看 LLAP Web UI → Cache Hit Ratio
  查看 LRFU policy 的淘汰频率
```

### 4.2 排障步骤

**Step 1：检查 LLAP 运行状态**
```bash
# 检查 LLAP 是否在运行
hive --service llapstatus -n <cluster_name>

# 查看 LLAP 实例信息
hive --service llapstatus --findlive
```

**Step 2：检查内存配置**
```sql
-- 关键内存参数
SET hive.llap.daemon.yarn.container.mb;        -- YARN 容器总内存
SET hive.llap.daemon.memory.per.instance.mb;   -- Executor 内存
SET hive.llap.io.memory.size;                  -- IO 缓存大小
SET hive.llap.daemon.num.executors;            -- Executor 数量
```

**Step 3：监控关键指标**
- LLAP Web UI: `http://<llap-host>:15002`
- 缓存命中率、Executor 使用率、WaitQueue 深度、抢占次数

### 4.3 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.llap.daemon.num.executors` | CPU核数 | Executor 线程数 |
| `hive.llap.daemon.memory.per.instance.mb` | 取决于集群 | Executor 堆内存 |
| `hive.llap.io.memory.size` | 取决于集群 | IO 缓存大小（堆外） |
| `hive.llap.io.enabled` | true | IO 缓存总开关 |
| `hive.llap.daemon.task.scheduler.wait.queue.size` | 10 | 等待队列大小 |
| `hive.llap.daemon.task.scheduler.enable.preemption` | true | 是否启用抢占 |
| `hive.llap.daemon.rpc.num.handlers` | 5 | RPC 处理线程数 |
| `hive.llap.daemon.am.reporter.max.threads` | 4 | AM 心跳线程数 |
| `hive.llap.io.cache.direct` | true | IO 缓存使用堆外内存 |
| `hive.llap.daemon.service.hosts` | @llap0 | LLAP 服务注册地址（@开头为 ZK 模式） |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 概念 | Hive LLAP | Spark (Thrift Server) | Impala | Presto/Trino |
|------|-----------|----------------------|--------|-------------|
| 常驻进程 | LlapDaemon | SparkContext | Impalad | Worker |
| 内存缓存 | IO Cache (列块) | RDD Cache (行/列) | Buffer Pool (页) | 无持久缓存 |
| 任务调度 | WaitQueue + 抢占 | Fair/FIFO Scheduler | Admission Control | Resource Groups |
| 与 AM 交互 | AMReporter (心跳) | Driver 直连 | Catalog 通信 | Coordinator 通信 |
| 缓存粒度 | ORC 列块 | Partition/Table | HDFS Block | 无 |
| 执行模型 | Tez Fragment | Spark Task | Fragment | Split |

### 5.2 面试高频题

**Q1：LLAP 相比传统 Hive on Tez/MR 的核心优势是什么？**

> A: 三大核心优势：
> 1. **常驻进程**：省去了 Container 申请/启动时间（通常 10-30 秒），查询可以亚秒级启动
> 2. **IO 缓存**：热数据缓存在内存中，重复查询不需要访问 HDFS，性能提升 10x+
> 3. **执行优化**：与向量化执行引擎深度集成，数据直接以列式格式从缓存流入向量化处理

**Q2：LLAP 的 IO Cache 是如何工作的？**

> A: IO Cache 以 ORC 列块为粒度缓存数据：
> 1. 使用 BuddyAllocator 管理堆外内存（Direct ByteBuffer）
> 2. 以 (文件路径, 列ID, 偏移量) 为 key 索引缓存块
> 3. 使用 LRFU 策略（LRU 和 LFU 的混合）淘汰冷数据
> 4. 支持谓词下推：缓存的数据可以直接应用 Filter，跳过不需要的行

**Q3：TaskExecutorService 的抢占机制是如何工作的？**

> A: 抢占基于优先级：
> 1. 所有 `canFinish=false` 的运行中任务被放入 preemptionQueue
> 2. 当高优先级任务到来且无空闲 Executor 时，检查 preemptionQueue
> 3. 如果新任务优先级 > 队列中最低优先级任务，则 kill 低优先级任务
> 4. 被抢占的任务会通知 AM 重新调度到其他节点
> 5. 抢占有 grace period（500ms），给被抢占任务一个清理机会

**Q4：LLAP 适合什么样的工作负载？**

> A: LLAP 最适合：
> - **交互式查询**：短查询、亚秒级响应（BI 仪表盘）
> - **重复性查询**：同样的数据被反复查询（缓存命中率高）
> - **低延迟要求**：不能等 Container 启动
> 不太适合：
> - **大规模 ETL**：数据量大、一次性处理（缓存利用率低）
> - **写密集型**：频繁更新导致缓存失效

### 5.3 思考题

1. **如果 LLAP Daemon 挂了，正在运行的查询会怎样？AM 如何感知并恢复？**
   提示：AM 通过心跳超时检测，将 Fragment 重新调度到其他 LLAP 实例

2. **为什么 LLAP 使用堆外内存（Direct ByteBuffer）做 IO 缓存而不是堆内存？**
   提示：避免 GC 压力，大内存堆的 Full GC 可能导致秒级暂停

3. **BuddyAllocator（伙伴分配器）相比简单的 malloc/free 有什么优势？**
   提示：减少内存碎片化，分配/释放 O(log n) 时间复杂度

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────┐
│            LLAP 守护进程架构 · 知识晶体                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  核心思想：常驻进程 + IO缓存 + 抢占式调度                         │
│                                                                  │
│  组件层次：                                                       │
│    LlapDaemon (CompositeService)                                 │
│      ├─ LlapProtocolServerImpl (RPC服务)                         │
│      ├─ ContainerRunnerImpl (请求分发)                           │
│      │    └─ TaskExecutorService (调度核心)                      │
│      │         ├─ WaitQueue (优先级等待队列)                     │
│      │         ├─ ExecutorPool (线程池执行)                      │
│      │         └─ PreemptionQueue (抢占队列)                     │
│      ├─ AMReporter (AM心跳上报)                                  │
│      ├─ IO Cache Layer                                           │
│      │    ├─ LowLevelCacheImpl (列块缓存)                       │
│      │    ├─ BuddyAllocator (内存分配)                          │
│      │    └─ LrfuCachePolicy (淘汰策略)                         │
│      └─ Registry / WebServices / ShuffleHandler                  │
│                                                                  │
│  请求流：AM →RPC→ ContainerRunner → TaskExecutor → Fragment执行  │
│  缓存流：HDFS → IO Cache(列块) → VectorizedRowBatch → 算子处理  │
│                                                                  │
│  关键调优三角：numExecutors × memoryPerExecutor × ioCacheSize    │
│  三者之和不能超过 YARN Container 总内存                           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/LlapDaemon.java` — 守护进程主类
   - `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/ContainerRunner.java` — 任务接口
   - `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/ContainerRunnerImpl.java` — 请求分发
   - `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/TaskExecutorService.java` — 调度核心
   - `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/TaskRunnerCallable.java` — Fragment 执行
   - `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/AMReporter.java` — AM 心跳
   - `llap-server/src/java/org/apache/hadoop/hive/llap/cache/BuddyAllocator.java` — 伙伴分配器
   - `llap-server/src/java/org/apache/hadoop/hive/llap/cache/LowLevelCacheImpl.java` — 底层缓存
   - `llap-server/src/java/org/apache/hadoop/hive/llap/cache/LowLevelLrfuCachePolicy.java` — LRFU 策略

2. **官方文档**
   - [Hive LLAP](https://cwiki.apache.org/confluence/display/Hive/LLAP)
   - [HIVE-7926: LLAP Proposal](https://issues.apache.org/jira/browse/HIVE-7926)

3. **设计理念**
   - LLAP = Live Long And Process，灵感来自 Star Trek 的 "Live Long and Prosper"
   - 核心目标：将 Hive 从批处理系统推向交互式分析
