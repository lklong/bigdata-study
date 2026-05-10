# Tez DAGAppMaster DAG 执行引擎源码分析

> **源码路径**：`gitproject/tez/tez-dag/src/main/java/org/apache/tez/dag/app/DAGAppMaster.java`（101.49 KB）
> **铁律遵守**：所有方法名、行号引用均来自上述真实源码

---

## 一、定位

Tez DAGAppMaster 是 **Hadoop MR 后继者** 的核心组件。每个 Tez Application（如 Hive on Tez 的一次查询）对应一个 DAGAppMaster 进程，跑在 YARN Container 里。

**官方注释（DAGAppMaster.java:200-216）**：
```java
200: /**
201:  * The Tez DAG Application Master.
202:  * The state machine is encapsulated in the implementation of Job interface.
203:  * All state changes happens via Job interface. Each event
204:  * results in a Finite State Transition in Job.
205:  *
206:  * Tez DAG AppMaster is the composition of loosely coupled services. The services
207:  * interact with each other via events. The components resembles the
208:  * Actors model. The component acts on received event and send out the
209:  * events to other components.
210:  * This keeps it highly concurrent with no or minimal synchronization needs.
211:  *
212:  * The events are dispatched by a central Dispatch mechanism. All components
213:  * register to the Dispatcher.
214:  *
215:  * The information is shared across different components using AppContext.
216:  */
```

**设计哲学**：
- **Actor 模型** — 组件通过事件异步通信，高并发零/少同步
- **AsyncDispatcher 中心化事件总线**
- **有限状态机（FSM）** 驱动 Job/Vertex/Task 状态转换
- **AppContext 共享上下文**（避免全局变量）

---

## 二、类继承关系（DAGAppMaster.java:218-219）

```java
218: @SuppressWarnings("rawtypes")
219: public class DAGAppMaster extends AbstractService {
```

**继承 `AbstractService`** — Hadoop 通用服务框架，提供 `serviceInit/serviceStart/serviceStop` 三段式生命周期。

---

## 三、核心字段（DAGAppMaster.java:232-249）

```java
232: private Clock clock;
233: private final boolean isSession;                      // Session 模式 vs Per-DAG 模式
234: private long appsStartTime;
235: private final long startTime;
236: private final long appSubmitTime;
237: private String appName;
238: private final ApplicationAttemptId appAttemptID;      // YARN AM 尝试 ID
239: private final ContainerId containerID;
240: private final String nmHost;
   ...
245: private final String[] logDirs;
246: private final AMPluginDescriptorProto amPluginDescriptorProto;
247: private HadoopShim hadoopShim;
248: private ContainerSignatureMatcher containerSignatureMatcher;
249: private AMContainerMap containers;                    // ⭐ Container 索引
```

**关键字段**：
- **`isSession`** — 决定是单 DAG 结束就退出，还是作为 Session（如 HiveServer2）复用
- **`containers`** — 所有分配到的 Container 索引，支持 cross-DAG 复用

---

## 四、serviceInit 核心初始化（DAGAppMaster.java:420-622）⭐

```java
420: protected void serviceInit(final Configuration conf) throws Exception {
421:
422:     this.amConf = conf;
423:     initResourceCalculatorPlugins();
424:     this.hadoopShim = new HadoopShimsLoader(this.amConf).getHadoopShim();
   ...
436:     UserPayload defaultPayload = TezUtils.createUserPayloadFromConf(amConf);
437:
438:     List<NamedEntityDescriptor> taskSchedulerDescriptors = Lists.newLinkedList();
439:     List<NamedEntityDescriptor> containerLauncherDescriptors = Lists.newLinkedList();
440:     List<NamedEntityDescriptor> taskCommunicatorDescriptors = Lists.newLinkedList();
441:
442:     parseAllPlugins(taskSchedulerDescriptors, taskSchedulers, containerLauncherDescriptors,
443:         containerLaunchers, taskCommunicatorDescriptors, taskCommunicators, amPluginDescriptorProto,
444:         isLocal, defaultPayload);
```

### 4.1 三大插件分离加载（438-449）

Tez 把 AM 职责抽象成三个可插拔插件：
- **TaskScheduler** — 向 YARN/LocalScheduler 申请资源
- **ContainerLauncher** — 在 Container 上启动 task 进程
- **TaskCommunicator** — Task 与 AM 的 RPC 通信

**好处**：Tez 可以运行在 YARN、本地模式、甚至其他调度平台上（未来 K8s）。

### 4.2 客户端版本检查（456-472）

```java
456:     LOG.info("Comparing client version with AM version"
457:         + ", clientVersion=" + clientVersion
458:         + ", AMVersion=" + dagVersionInfo.getVersion());
459:     Simple2LevelVersionComparator versionComparator = new Simple2LevelVersionComparator();
460:     if (versionComparator.compare(clientVersion, dagVersionInfo.getVersion()) != 0) {
461:         versionMismatchDiagnostics = "Incompatible versions found"
   ...
465:         if (disableVersionCheck) {
466:             LOG.warn("Ignoring client-AM version mismatch as check disabled. "
   ...
469:         } else {
470:             LOG.error(versionMismatchDiagnostics);
471:             versionMismatch = true;
   ...
```

**Client-AM 版本必须兼容**，否则 RPC 协议错乱。可通过 `TEZ_AM_DISABLE_CLIENT_VERSION_CHECK` 跳过。

### 4.3 Dispatcher 创建（474-491）

```java
474:     dispatcher = createDispatcher();
   ...
480:     } else {
481:         dispatcher.enableExitOnDispatchException();
482:     }
   ...
486:     context = new RunningAppContext(conf);
487:     this.aclManager = new ACLManager(appMasterUgi.getShortUserName(), this.amConf);
488:
489:     clientHandler = new DAGClientHandler(this);
490:
491:     addIfService(dispatcher, false);
```

**关键点**：
- **非 Local 模式开启 `enableExitOnDispatchException`** — 任何事件处理异常直接退出 JVM，防止腐化状态传播
- `AppContext` 是所有组件共享的上下文（类似 Spring Context）
- `DAGClientHandler` 处理客户端 RPC（提交 DAG、查状态）

### 4.4 Recovery + RPC（493-505）

```java
493:     recoveryDataDir = TezCommonUtils.getRecoveryPath(tezSystemStagingDir, conf);
494:     recoveryFS = recoveryDataDir.getFileSystem(conf);
495:     currentRecoveryDataDir = TezCommonUtils.getAttemptRecoveryPath(recoveryDataDir,
496:         appAttemptID.getAttemptId());
   ...
502:     recoveryEnabled = conf.getBoolean(TezConfiguration.DAG_RECOVERY_ENABLED,
503:         TezConfiguration.DAG_RECOVERY_ENABLED_DEFAULT);
504:
505:     initClientRpcServer();
```

**AM Recovery 机制**：
- AM 失败重试时，从 HDFS 上的 recovery log 恢复 DAG 状态
- 避免重跑整个 DAG（已完成的 vertex 直接跳过）

---

## 五、Event Handler 注册（DAGAppMaster.java:545）

```java
545:     dispatcher.register(DAGAppMasterEventType.class, new DAGAppMasterEventHandler());
```

所有组件通过 `register(EventType.class, handler)` 注册到 Dispatcher：
- `DAGEventType` → DAGImpl
- `VertexEventType` → VertexImpl
- `TaskEventType` → TaskImpl
- `TaskAttemptEventType` → TaskAttemptImpl
- `ContainerEventType` → AMContainerImpl

---

## 六、DAGAppMasterEventHandler（DAGAppMaster.java:899-912）

```java
899: private class DAGAppMasterEventHandler implements
900:     EventHandler<DAGAppMasterEvent> {
901:   @Override
902:   public void handle(DAGAppMasterEvent event) {
903:     // don't handle events if DAGAppMaster is in the state of STOPPED,
904:     // otherwise there may be dead-lock happen.  TEZ-2204
905:     if (DAGAppMaster.this.getServiceState() == STATE.STOPPED) {
906:       LOG.info("ignore event when DAGAppMaster is in the state of STOPPED, eventType="
907:         + event.getType());
908:       return;
909:     }
910:     DAGAppMaster.this.handle(event);
911:   }
912: }
```

**TEZ-2204 Bug 修复注释**：STOPPED 状态下直接忽略事件，避免与关闭流程竞争造成死锁。

---

## 七、startDAG 启动 DAG（DAGAppMaster.java:2463-2524）⭐

```java
2463: private void startDAG(DAGPlan dagPlan, Map<String, LocalResource> additionalAMResources)
2464:     throws TezException {
2465:   long submitTime = this.clock.getTime();
2466:   this.appName = dagPlan.getName();
2467:
2468:   // /////////////////// Create the job itself.
2469:   final DAG newDAG = createDAG(dagPlan);                              // ⭐ DAGImpl 实例化
   ...
2478:   Map<String, LocalResource> lrDiff = getAdditionalLocalResourceDiff(
2479:       newDAG, additionalAMResources);
2480:   if (lrDiff != null) {
2481:     amResources.putAll(lrDiff);
2482:     cumulativeAdditionalResources.putAll(lrDiff);
2483:   }
   ...
2499:   final DAGSubmittedEvent submittedEvent = new DAGSubmittedEvent(newDAG.getID(),
2500:       submitTime, dagPlan, this.appAttemptID, cumulativeAdditionalResources,
2501:       newDAG.getUserName(), newDAG.getConf(), containerLogs, getContext().getQueueName());
   ...
2506:   try {
2507:      appMasterUgi.doAs(new PrivilegedExceptionAction<Void>() {
2508:        @Override
2509:        public Void run() throws Exception {
2510:          historyEventHandler.handleCriticalEvent(                    // ⭐ 写 history log
2511:              new DAGHistoryEvent(newDAG.getID(), submittedEvent));
2512:          return null;
2513:        }
2514:      });
   ...
2521:   startDAGExecution(newDAG, lrDiff);                                  // ⭐ 真正执行
2522:   // set state after curDag is set
2523:   this.state = DAGAppMasterState.RUNNING;
2524: }
```

**关键步骤**：
1. `createDAG(dagPlan)` — 从 protobuf plan 构建 DAGImpl（含 Vertex、Edge）
2. 本地资源差异计算 — 支持 session 模式下多 DAG 共享资源
3. 写 history log（Tez UI 数据源）
4. `startDAGExecution` — 初始化 vertex services，开始调度
5. 最后设置 `state = RUNNING`

---

## 八、Shutdown 流程（DAGAppMaster.java:914-968）

```java
914: protected class DAGAppMasterShutdownHandler {
915:   private AtomicBoolean shutdownHandled = new AtomicBoolean(false);
   ...
926:   public void shutdown(boolean now) {
927:     LOG.info("DAGAppMasterShutdownHandler invoked");
928:     if(!shutdownHandled.compareAndSet(false, true)) {
929:       LOG.info("Ignoring multiple shutdown events");
930:       return;
931:     }
   ...
938:     AMShutdownRunnable r = new AMShutdownRunnable(now, sleepTimeBeforeExit);
939:     Thread t = new Thread(r, "AMShutdownThread");
940:     t.start();
941:   }
```

**CAS 保护**：`shutdownHandled.compareAndSet(false, true)` 保证 shutdown 只执行一次（多个 TERM 信号或事件都只触发一次）。

**异步关闭**：单独起 `AMShutdownThread`，避免阻塞事件 dispatcher。

---

## 九、核心方法位置速查

| 方法 | 行号 | 作用 |
|------|------|------|
| `serviceInit()` | 420 | 核心初始化 |
| `serviceStart()` | 1927 | 启动所有子服务 |
| `createDAG()` | 987, 992 | 从 DAGPlan 构建 DAGImpl |
| `startDAG()` | 2463 | 启动一个 DAG 执行 |
| `startDAGExecution()` | 2538 | Localize 资源后真正调度 |
| `main()` | 2298 | JVM 入口 |
| `DAGAppMasterEventHandler` | 899 | 主事件处理器 |
| `DAGAppMasterShutdownHandler` | 914 | 关闭处理器 |

---

## 十、架构全景

```
┌────────────────────────────────────────────────────────┐
│ DAGAppMaster extends AbstractService                   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ AsyncDispatcher (事件总线)                       │   │
│  │  ├─ DAGEventType → DAGImpl (FSM)                │   │
│  │  ├─ VertexEventType → VertexImpl (FSM)          │   │
│  │  ├─ TaskEventType → TaskImpl (FSM)              │   │
│  │  ├─ TaskAttemptEventType → TaskAttemptImpl      │   │
│  │  └─ ContainerEventType → AMContainerImpl        │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  可插拔三件套：                                         │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐   │
│  │TaskScheduler │ │ContainerLaunc│ │TaskCommunic  │   │
│  │ (YARN)       │ │ her          │ │ ator         │   │
│  └──────────────┘ └──────────────┘ └──────────────┘   │
│                                                         │
│  基础服务：                                             │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐   │
│  │ClientRpcServ │ │HistoryHandler│ │AMContainerMap│   │
│  │ er (DAG 提交)│ │ (Recovery)   │ │              │   │
│  └──────────────┘ └──────────────┘ └──────────────┘   │
│                                                         │
│  AppContext（共享上下文，所有组件都能访问）              │
└────────────────────────────────────────────────────────┘
```

---

## 十一、Tez vs MR vs Spark 对比

| 特性 | Tez | MR | Spark |
|------|-----|-----|-------|
| DAG 结构 | ✅ 原生 | ❌ 必须 map-reduce | ✅ 原生（RDD） |
| Container 复用 | ✅ 默认 | ❌ 每个 task 新进程 | ✅ Executor 复用 |
| Session 模式 | ✅ 支持 | ❌ | ✅（Spark Thrift Server） |
| AM/Driver 职责 | 纯调度 | 纯调度 | 调度 + 部分执行 |
| 主要用户 | Hive on Tez | 历史遗产 | 主流 SQL/ML/Streaming |

---

## 十二、生产关注点

### 12.1 Container Reuse

- `tez.am.container.reuse.enabled=true`（默认 true）
- 同一 Container 跑多个 task，省去启动开销
- **但同一 Container 内 task 串行** — 不要混用 CPU/内存差异大的 task

### 12.2 AM 内存
- `tez.am.resource.memory.mb` 默认 1024MB
- 大 DAG（1000+ vertex）需要 4-8GB
- OOM 表现：AM 被 YARN kill，DAG 整体失败

### 12.3 Recovery 是否启用
- `tez.dag.recovery.enabled=true`（默认）
- 写 HDFS 有开销，但失败重试省时间
- 短查询可考虑关闭

### 12.4 关键日志

```
Running DAG: dag_xxx     ← 从 startDAG 日志 (line 2491)
Comparing client version with AM version  ← 版本检查 (line 456)
DAGAppMasterShutdownHandler invoked       ← 关闭触发
```

---

## 十三、Eric 点评

Tez 是**被低估的中间代**。在 Hive on MR 被淘汰、Hive on Spark 尚未成熟时，Tez 承载了 Hortonworks 的赌注。

### 13.1 Actor 模型的教科书实现

DAGAppMaster 是 Hadoop 生态里**最纯粹的 Actor 模型实现**：
- 每个组件是一个 Actor
- 组件间只通过事件通信（Dispatcher）
- 零/少 synchronized 锁
- 状态机 FSM 驱动状态转换

对比 MR 的 JobTracker（巨型 synchronized 类）和 Spark 的 DAGScheduler（带锁的事件循环），Tez 架构**最干净**。

### 13.2 可插拔三件套的远见

2013 年就把 TaskScheduler/ContainerLauncher/TaskCommunicator 抽象成插件，这个设计让 Tez 理论上可以无缝迁移到 K8s（虽然实际社区没做这件事）。

### 13.3 Recovery 机制的精巧

Tez 的 AM Recovery 比 Spark 的重跑更高效：
- 已完成 vertex 的 output 保留在 HDFS
- AM 重启后从 recovery log 重建状态
- 只重跑失败的 task

Spark 的 AM（Driver）挂了整个 job 就要重跑。

### 13.4 为什么 Tez 没火

- **时机不对**：2013-2016 正是 Spark 崛起期
- **社区弱**：基本只有 Hortonworks 维护
- **生态窄**：只服务 Hive，没有 ML/Streaming
- **复杂度高**：对比 Spark 易用性差

但 Tez 的**架构思想深远影响**了：
- Flink 的 TaskExecutor/SlotPool 设计
- K8s Native Spark/Flink 的资源抽象
- Dagster/Airflow 的 DAG engine

> Tez 是好学生，但没赶上好老师。

理解 DAGAppMaster 的 Actor + Dispatcher 模型，你就掌握了现代**事件驱动分布式系统**的脊梁。
