# Amoro 源码精通 · Day3 · 《自优化是怎么被触发的？—— OptimizingService 调度核心精讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 03 讲  
> 本讲时长：60 分钟阅读 + 120 分钟动手  
> 承接：Day2《表的一生与责任链精讲》

---

## 🎯 本讲学完你能干什么

读完这一讲，你将能够：

- ✅ **10 秒答出** "为什么我的表 Optimizing 一直是 PENDING？" 的 5 种可能原因
- ✅ **默画 Amoro 的"双状态机"**（表级 7 态 + 任务级 6 态）
- ✅ **讲清楚** "push 模型（AMS 推任务）" vs "pull 模型（Optimizer 拉任务）"——Amoro 选了后者，为什么？
- ✅ **理解 Optimizer 心跳 + 过期 + 任务追回** 的完整机制，这是**生产最常出问题的地方**
- ✅ **看透一个精妙设计**：AMS 为什么用 `ReentrantLock + Condition` 而不是 `BlockingQueue`？
- ✅ **Optimizer Group 是什么**，为什么它是 Amoro 做多租户资源隔离的核心抽象
- ✅ **诊断 Day2 留下的自优化疑问**：哪张 Handler 调用链最终触发了自优化？

---

## 🪜 预备知识

| 点 | 要会什么 |
|---|---|
| Day1 + Day2 | 能默画 AMS 启动 + 表生命周期 6 阶段 |
| Thrift | 知道 Thrift 是双向 RPC，服务端也能定义 client 方法 |
| Java `ReentrantLock + Condition` | 知道它是 wait/notify 的升级版 |
| 生产者-消费者模型 | 经典 BlockingQueue 套路 |
| Iceberg 小文件合并概念 | 知道 rewrite_data_files 的作用 |

---

## 🧠 一句话心智模型

> **OptimizingService 就是 Amoro 的"滴滴打车"：把**"要优化的表"**当乘客，把**"Optimizer"**当司机。AMS 不主动派车，是司机主动在 App 上"接单"。AMS 的全部工作是：管乘客排队、管司机心跳、管订单状态、超时任务重派。**

记住"滴滴"这个类比，后面所有细节都能对号入座。

---

## 🏛️ 从生活类比入手：Amoro 的"滴滴系统"

```
┌─────────────────────────────────────────────────────────┐
│                  滴滴平台（AMS）                          │
│                                                         │
│   👥 乘客排队（表等优化）      🚗 司机池（Optimizer 池）    │
│   SchedulingPolicy            authOptimizers            │
│       ↓                         ↑                       │
│   planningTables  ──────→   OptimizingQueue             │
│   （正在规划行程）              （按 Group 分区的队列）     │
│       ↓                         ↑                       │
│   TableOptimizingProcess   ←──  pollTask                │
│   （一张表的一次完整优化）       （司机主动来接单）          │
│       ↓                         ↑                       │
│   TaskRuntime（单个任务单）←──  ackTask + completeTask   │
│                                （司机确认+完工）          │
│                                                         │
│   👁️ OptimizerKeeper（心跳监控）                         │
│      每隔 HB_TIMEOUT 检查司机在不在线                      │
│      掉线 → 单号退回，派给别的司机                         │
└─────────────────────────────────────────────────────────┘
```

**每一张表在 AMS 里的身份转换**：

```
  表建好 ──→ 加入 SchedulingPolicy  (IDLE 状态)
                   │
                   ▼   定时器触发 scheduleTable
              PLANNING  (规划期：判断要不要优化)
                   │
              ┌────┴────┐
              ▼         ▼
           无需优化   需要优化
              │         │
              └──→ IDLE └──→ PENDING (入 OptimizingQueue)
                               │
                          司机来接单 → Task 被 Pop
                               │
                               ▼
                   FULL_OPTIMIZING / MAJOR / MINOR (干活中)
                               │
                               ▼
                         COMMITTING  (提交结果)
                               │
                               ▼
                              IDLE
```

**这就是 `OptimizingStatus` 的 7 个状态**。

---

## 🔍 源码逐层剥离

### L1 · 接口层：Day3 要掌握的 6 个核心类

```
┌─────────────────────────────────────────────────────────┐
│  1. DefaultOptimizingService (extends OptimizingService.Iface)  │
│     "滴滴总调度室" — Thrift server 对外 + 责任链对内        │
│     - optimizingQueueByGroup  各 Group 的队列             │
│     - authOptimizers          登记在册的司机               │
│     - optimizerKeeper         心跳检测线程                 │
│     - optimizingConfigWatcher Group 配置刷新线程           │
│     对外 Thrift API:                                     │
│       authenticate / touch / pollTask / ackTask / completeTask│
├─────────────────────────────────────────────────────────┤
│  2. OptimizingQueue                                      │
│     "按司机组分区的订单池"— 每个 OptimizerGroup 一个队列    │
│     - tableQueue           排队中的优化进程                │
│     - retryTaskQueue       失败重试队列                   │
│     - planningTables       正在规划的表（并行上限）         │
│     - scheduler            SchedulingPolicy              │
│     - scheduleLock + Condition  ★核心同步机制             │
├─────────────────────────────────────────────────────────┤
│  3. SchedulingPolicy                                     │
│     "排队顺序策略"— 从一堆 IDLE 表里选一张规划              │
│     - tableRuntimeMap   所有 IDLE 表                    │
│     - policyName        QuotaOccupy / BalancedBy...      │
│     - scheduleTable()   排序 → 选第一个                   │
├─────────────────────────────────────────────────────────┤
│  4. OptimizingStatus (enum, 7 态)                        │
│     FULL / MAJOR / MINOR / COMMITTING / PLANNING / PENDING / IDLE│
│     - isProcessing: 是否占着资源                          │
├─────────────────────────────────────────────────────────┤
│  5. TaskRuntime.Status (enum, 6 态) + 显式转换表          │
│     PLANNED → SCHEDULED → ACKED → SUCCESS / FAILED       │
│                                                / CANCELED│
│     每对合法转换都预先写死在 ImmutableMap                  │
├─────────────────────────────────────────────────────────┤
│  6. OptimizerKeeper (内部类, Runnable)                   │
│     "司机心跳监控"— 独立线程 + DelayQueue                 │
│     - DelayQueue<OptimizerKeepingTask>                   │
│     - tryKeeping()：比较 lastTouchTime 是否变了            │
│     - 超时 → unregister + 未完任务 retryQueue              │
└─────────────────────────────────────────────────────────┘
```

---

### L2 · 主链路一：Day2 留给 Day3 的"悬念"被接上

Day2 我们讲到 `fireStatusChanged → OptimizingService.TableRuntimeHandler`，然后就停在"接到事件"这一步。**今天我们把这条链路的下半段补全**：

```
Day2 接力棒 ▼

DefaultTableService.handleTableChanged()
   └─ headHandler.fireStatusChanged(tableRuntime, originalStatus)
       │
       ▼ 递归链传到 ↓
DefaultOptimizingService$TableRuntimeHandlerImpl
   .handleStatusChanged(tableRuntime, originalStatus)          (L377-383)
   │
   ├─ if (!tableRuntime.optimizingState.isProcessing()) {       ← 在跑就不抢
   │
   │    getOptionalQueueByGroup(group)
   │        .ifPresent(q -> q.refreshTable(tableRuntime));      ★ 进入 Queue
   │  }
   │
   ▼
OptimizingQueue.refreshTable(tableRuntime)                     (L159-171)
   ├─ if (optimizingEnabled && !isProcessing):
   │    optimizingState.resetTaskQuotas(lookbackTime);          ← 重置配额窗口
   │    scheduler.addTable(tableRuntime);                       ★ 进 SchedulingPolicy
```

**关键断点 #1**：进 `SchedulingPolicy` 之后**什么都不会立刻发生**，只是加入了"候选表池"。真正的触发要等到**Optimizer 来 pollTask**。

这就是为什么 Amoro 叫 **"pull 模型"**——AMS 不推任务，等 Optimizer 来拉。

---

### L2 · 主链路二：Optimizer 拉任务的完整链路（生产核心）

**场景**：一个 Flink Optimizer 启动了，向 AMS 打 Thrift 拉活。

```
Optimizer (Flink Job)
   │
   ▼ Thrift RPC (OptimizingService.Client)
authenticate(registerInfo)                                     ┐
   │                                                           │
   ▼                                                           │
DefaultOptimizingService.authenticate()             (L257-278) │
   ├─ 校验心跳参数 < AMS 的 HB 超时                             │ 这一步只做一次
   ├─ new OptimizerInstance(registerInfo)                      │ 
   ├─ registerOptimizer(optimizer, true) {        (L168-178)   │
   │     ├─ doAs → insertOptimizer(DB)             持久化       │
   │     ├─ queue.addOptimizer(optimizer)                       │
   │     ├─ authOptimizers.put(token, optimizer)  在册          │
   │     ├─ optimizingQueueByToken.put(token, queue)            │
   │     └─ optimizerKeeper.keepInTouch(optimizer) 心跳监控入队   │
   │   }                                                         │
   └─ return token                                               ┘
                                                               
Optimizer 拿到 token 后，进入主循环（每个线程独立循环）：
                                                               
   while (true) {
     OptimizingTask task = client.pollTask(token, threadId);    ↓
                                                                ↓
DefaultOptimizingService.pollTask()                (L210-216)   ↓
   ├─ queue = getQueueByToken(token)                            ↓
   ├─ task = queue.pollTask(pollingTimeout)                     ↓
   │                                                            ↓
   │  ▼ 进入 Queue 内部（L199-206）                              ↓
   │  TaskRuntime<?> pollTask(long maxWaitTime) {              ↓
   │      TaskRuntime<?> task = fetchTask();      ★ 优先从重试队列│
   │      while (task == null && waitTask(deadline)) {          ↓
   │          task = fetchTask();                               ↓
   │      }                                                     ↓
   │      return task;                                          ↓
   │  }                                                         ↓
   │                                                            ↓
   │  fetchTask() 二级策略（L228-239）:                          ↓
   │    1) 先从 retryTaskQueue.poll() ← 失败重试优先             ↓
   │    2) 再从 tableQueue 找有 Task 可 poll 的 Process          ↓
   │                                                            ↓
   │  waitTask() 同步机制（L213-226）:                           ↓
   │    scheduleLock.lock();                                    ↓
   │    scheduleTableIfNecessary(currentTime); ★ 触发规划        ↓
   │    planningCompleted.await(timeout, MS);  ★ 等规划完成通知   ↓
   │    scheduleLock.unlock();                                  ↓
   │                                                            ↓
   ├─ if (task == null) return null;                            ↓
   ├─ else: extractOptimizingTask(task, token, threadId, queue)↓
   │    ├─ task.schedule(optimizerThread);  PLANNED→SCHEDULED   ↓
   │    └─ task.extractProtocolTask();      返回 Thrift DTO      ↓
                                                               │
     if (task != null) {                                        │
       client.ackTask(token, threadId, task.getTaskId());      ↓
       → TaskRuntime.ack() : SCHEDULED → ACKED                  │
                                                                │
       TaskResult result = doWork(task);  ← 真正干活              │
                                                                │
       client.completeTask(token, result);                      │
       → TaskRuntime.complete() : ACKED → SUCCESS / FAILED     │
     }                                                          │
     
     每隔几秒：
     client.touch(token);   ← 心跳（不然 OptimizerKeeper 会 unregister）
   }
```

**🔑 教学关键点（必记）**：

1. **AMS 不发起请求**。所有交互都是 Optimizer 打 Thrift 过来，AMS 只是 Iface 实现。
2. **pollTask 是会阻塞的**（`planningCompleted.await`），上限 `pollingTimeout`（默认若干秒）——**这是 long polling，不是 busy polling**。
3. **retryTaskQueue 优先** —— 失败的任务先重派，比新任务优先级高。
4. **task.schedule(thread)**这一步才把 `PLANNED → SCHEDULED`，**拿到任务但还没"签收"**。
5. **ack 才算签收**：签收后如果 Optimizer 挂了，AMS 知道这任务没完成，会通过 OptimizerKeeper 捞回来重派。

---

### L2 · 主链路三：`ReentrantLock + Condition` vs `BlockingQueue` 的选择（精妙之处）

**新手问题**：为什么不用 `LinkedBlockingQueue` 直接实现生产者-消费者？

**答**：因为 Amoro 要同时满足**三个不能用 BlockingQueue 解决的需求**：

**需求 1**：Pop 之前**可能没有任务**，但**应该触发规划**，等到规划好了再 pop。

```java
// BlockingQueue 的做法：只能死等，不能"触发生产者"
queue.poll(timeout, TimeUnit.MILLISECONDS);  // ❌ 没东西只能等

// Amoro 的做法
scheduleLock.lock();
try {
    scheduleTableIfNecessary(currentTime);   // ★ 主动触发规划
    planningCompleted.await(timeout, MS);    // 等规划完成
} finally {
    scheduleLock.unlock();
}
```

**需求 2**：并发消费的同时还需要**全局状态判断**（planningTables size < max）。BlockingQueue 不支持。

**需求 3**：retryQueue 必须优先 —— 同一个锁下实现"先查重试再查正常"的原子优先级，BlockingQueue 做不到。

**精妙总结**：**当同步逻辑超越了"排队 + 取数"的简单模型，ReentrantLock + Condition 就比 BlockingQueue 灵活 10 倍**。记住这个判据。

---

### L2 · 主链路四：双状态机的精妙配合

Amoro 在优化场景下用了**两套状态机**，要分清：

#### 表级状态机：`OptimizingStatus` (7 态)

```
        ┌───────── IDLE (初始/完成态) ─────────┐
        │                                      │
   refreshTable                              COMMIT 成功
        │                                      │
        ▼                                      │
    PENDING (排队等规划)                         │
        │                                      │
    scheduleTable                              │
        │                                      │
        ▼                                      │
    PLANNING (正在规划)                          │
        │                                      │
    ┌───┴───────────────────────────┐         │
    │ 无需优化                         需要优化                 
    ▼                                 │                        
   IDLE                               ▼                        
                            FULL / MAJOR / MINOR ──────────────┘
                                (执行中，isProcessing=true)    
                                       │                        
                                   所有 Task 成功
                                       │                        
                                       ▼                        
                                 COMMITTING                     
                                       │                        
                                       ▼                        
                                     IDLE
```

#### 任务级状态机：`TaskRuntime.Status` (6 态) + 显式转换表

**核心源码**（`TaskRuntime.java` L274-283）：

```java
ImmutableMap.<Status, Set<Status>>builder()
    .put(Status.PLANNED,  ImmutableSet.of(Status.SCHEDULED, Status.CANCELED))
    .put(Status.SCHEDULED, ImmutableSet.of(Status.PLANNED, Status.ACKED, Status.CANCELED))
    .put(Status.ACKED,    ImmutableSet.of(Status.PLANNED, Status.SUCCESS, Status.FAILED, Status.CANCELED))
    .put(Status.FAILED,   ImmutableSet.of(Status.PLANNED))  // ★ 失败可回 PLANNED 重试
    .put(Status.CANCELED, ImmutableSet.of())                 // 终态
    .put(Status.SUCCESS,  ImmutableSet.of())                 // 终态
    .build();
```

**🔑 教学关键点**：

- **状态转换表显式写死**——任何非法转换都会被 `statusMachine.accept()` 拒绝，抛异常。
- **FAILED → PLANNED 的反向回退** 是 Amoro 重试机制的核心：失败不是终点，是"排队重来"。
- **CANCELED 和 SUCCESS 都是终态**（空 Set）。
- 这叫 **"显式状态机"**（Explicit FSM），比 `if/else + 枚举` 安全 100 倍。

**对比**：Kafka 的 `ReplicaState`、Raft 的 `RaftState`、Flink 的 `ExecutionState`——所有严肃的分布式系统都用显式状态机。

---

### L2 · 主链路五：OptimizerKeeper 心跳机制（生产必懂）

这段代码（L463-538）直接**决定了生产上 Optimizer 挂掉后任务能不能被正确救回来**。

```java
private class OptimizerKeeper implements Runnable {
  private final DelayQueue<OptimizerKeepingTask> suspendingQueue = new DelayQueue<>();
  
  public void keepInTouch(OptimizerInstance optimizer) {
    suspendingQueue.add(new OptimizerKeepingTask(optimizer));  // ★ DelayQueue
  }
  
  public void run() {
    while (!stopped) {
      OptimizerKeepingTask task = suspendingQueue.take();       // 阻塞到超时
      
      boolean isExpired = !task.tryKeeping();                   // 有没有 touch 过
      
      // 无论过期与否，都先扫"挂起任务"进重试队列
      task.getQueue().collectTasks(buildSuspendingPredication(authOptimizers.keySet()))
          .forEach(t -> retryTask(t, queue));
      
      if (isExpired) {
        unregisterOptimizer(token);                             // 过期 → 踢出
      } else {
        keepInTouch(task.getOptimizer());                       // ★ 续一轮
      }
    }
  }
}
```

**核心机制**（OptimizerKeepingTask 是 `Delayed`）：

```java
public long getDelay(TimeUnit unit) {
  return unit.convert(
      lastTouchTime + optimizerTouchTimeout - System.currentTimeMillis(),
      TimeUnit.MILLISECONDS);
}
```

**🔑 教学关键点（必须默会）**：

1. **DelayQueue 按"超时点"排序**——队头永远是最快要超时的 Optimizer。
2. **超时判断 = tryKeeping 的返回**：比较 `lastTouchTime` 是否**变过**（变过 = 收到过 touch）。
3. **一次性 Delayed 对象**：每次 take 后要么 unregister，要么 `keepInTouch(...)` **重新入队一个新的 DelayedTask**（不是复用原来的）。
4. **挂起任务检测**：`buildSuspendingPredication` 判断 task 是否"孤儿"（持有过期 token 或 SCHEDULED 但超过 ackTimeout 没 ack）。

**这就是 Amoro 的"任务永不丢失"保证**——任何 Optimizer 挂掉后，它手上在跑的 task 会被这个循环发现并 `retryTask` 重派。

---

### L3 · 异常/边界预警（Day3 新增，接 W1-W12）

| 编号 | 文件 | 行号 | 嫌疑 | 类比 |
|---|---|---|---|---|
| **W13** | `DefaultOptimizingService` | L277 `registerOptimizer(optimizer, true)` 不是事务内的 | `doAs(insertOptimizer)` 和 内存 `authOptimizers.put` 可能部分成功 | 登记上了、内存没入账 |
| **W14** | `OptimizingQueue` | L93 `planningTables` 是普通 `HashSet`（非 ConcurrentHashSet） | 只靠 `scheduleLock` 保护，**漏加锁访问会很危险** | 规划中名单没上锁 |
| **W15** | `OptimizingQueue` | L277 `CompletableFuture.supplyAsync(planInternal, planExecutor)` | `planExecutor` 是 cachedThreadPool，**无上限**，大规模集群会创建太多线程 | 司机招太多挤爆 |
| **W16** | `OptimizerKeeper` | L489 while(!stopped) + take()  | 一次 `Throwable` catch 后直接进入下一轮；如果 **DB 短暂不可用**导致每次 `retryTask` 都抛异常，会出现**心跳失效窗口** | 门卫晕倒，门没人管 |
| **W17** | `DefaultOptimizingService` | L257 authenticate 校验 HB 参数 **≥ 超时才抛异常**，实际生产的默认值如果设反会导致 Optimizer **循环 register-expire-register** | Optimizer 不知死活反复登记 | 司机不断掉线重来 |
| **W18** | `TaskRuntime` | FAILED → PLANNED 允许 | 失败重试未限最大次数（需看 DefaultOptimizingState 才能验证） | 无限重试风险 |

累计 L3 坑：**18 条**（W1-W18）。

---

## 💡 精妙设计拆解

### 精妙一：Thrift Iface 实现 = 事实上的"无状态服务器"

```java
public class DefaultOptimizingService extends StatedPersistentBase
    implements OptimizingService.Iface, QuotaProvider {
```

**一行代码** `implements OptimizingService.Iface` 让这个类成了**完整的 Thrift server 业务层**。对比：

| 设计 | 优点 |
|---|---|
| Thrift Iface 直接实现 | 业务代码就是接口实现，**没有中间层** |
| Servlet/Controller 模式 | 需要 routing、参数解码、error handling 等胶水代码 |

**再配合** Day1 讲的 `ThriftServiceProxy.createProxy(...)`（`AmoroServiceContainer` L354-359）——这个 proxy 做了**异常归一化**（把业务异常转成 Thrift 异常），让 Iface 实现可以**直接抛业务异常**不用手动转。

**教学启示**：用 Thrift / gRPC 做内部 RPC 时，**让服务类直接实现 Iface**，用 Proxy 包装异常处理，代码会干净 10 倍。

### 精妙二：按 Group 分队列 = 天然多租户

`optimizingQueueByGroup: Map<String, OptimizingQueue>` —— **一个 OptimizerGroup 一个队列**。

好处：
1. **资源隔离**：Group A 的任务绝对不会被 Group B 的 Optimizer 抢
2. **弹性扩缩容**：某个 Group 的 Optimizer 不够 → 单独加
3. **故障隔离**：Group A 挂了不影响 Group B
4. **配额管理**：`QuotaProvider.getTotalQuota(group)` 天然按 Group 算

**举一反三**：这就是 YARN 的 Queue、K8s 的 Namespace、Kafka 的 Topic Partition ——**所有多租户系统的第一刀都是"按某个维度分队列"**。

### 精妙三：DelayQueue 做心跳检测 = 性能最优解

对比几种"检测 N 个资源超时"的方案：

| 方案 | 复杂度 | 问题 |
|---|---|---|
| 定时扫全表 | O(N × 扫频率) | 频率高费 CPU，低了不准 |
| 每个资源一个 Timer | O(N) 定时器 | Timer 多到 JVM 受不了 |
| **DelayQueue take()** | O(1) 阻塞到最近到期 | ✅ 优雅、精准、低消耗 |

**DelayQueue 的内部是优先队列 + `Condition.await(delay)`**——队头还没到期就精准 sleep，有新任务加入会自动 wake up。

**生产上所有"N 个资源各有独立超时"的场景都该抄这个**：
- Kafka consumer group session timeout
- Redis key expiration
- HBase RegionServer 心跳
- 任何重连/重试的退避（exponential backoff）

### 精妙四：planningTables 并行上限

```java
if (planningTables.size() < maxPlanningParallelism) {
    Optional.ofNullable(scheduler.scheduleTable(skipTables))
        .ifPresent(tableRuntime -> triggerAsyncPlanning(...));
}
```

**关键参数**：`OPTIMIZER_MAX_PLANNING_PARALLELISM`（默认值建议 2-4）。

**为什么需要这个限流？** 因为 planning 是**重操作**——要读表的所有 manifest、评估小文件率、算 partition 切分，**极端情况下一个大表 planning 可能要几分钟**。如果不限并发，十个大表同时 planning 会**OOM AMS 或打爆 HMS**。

**教学启示**：**任何"异步扔线程池"的场景都要想清楚上限**。线程池的 maxPoolSize 只是 JVM 层面的限制，业务语义的限流要自己做（本例用 `planningTables.size() <` 判断）。

---

## 🎓 举一反三：同构系统清单

| Amoro 机制 | 同构系统 | 关键词 |
|---|---|---|
| pull 模型（Optimizer 拉任务） | Kafka Consumer Group / YARN NodeManager / K8s kubelet | **反转控制权** |
| Thrift Iface 直接实现业务 | gRPC + Protobuf 服务直写 | **零胶水代码** |
| `OptimizingStatus` 7 态表级状态机 | Flink Job 状态（CREATED/RUNNING/FAILED/...）| **显式 FSM** |
| `TaskRuntime.Status` 6 态 + 转换表 | Kafka 副本状态、Raft 状态、K8s Pod Phase | **Explicit FSM** |
| DelayQueue 心跳检测 | Redis key expiration、Kafka session timeout | **最省 CPU 的超时检测** |
| 按 Group 分队列 | YARN Queue、K8s Namespace、HBase Region Group | **第一刀分租户** |
| retryTask 优先级 > 新 task | TCP 重传优先于新包、Kafka retry topic | **重试优先** |
| ReentrantLock + Condition 自定义生产消费 | JDK ThreadPoolExecutor 的 workQueue / Take | **比 BlockingQueue 灵活** |
| `Thrift Proxy` 异常归一化 | Spring `@ControllerAdvice`、gRPC interceptor | **横切关注点** |
| `OptimizerKeeper.tryKeeping` 比较 lastTouchTime | OS 的 "softirq watchdog" 检测、GC `SafepointTimeout` | **比时间戳，不比次数** |

---

## 📝 课后习题

### ⭐ 题目 1：生产问题速答（必做）

运维小王反馈："我启动了 Flink Optimizer，AMS 日志看到 'Register optimizer'，但 10 分钟后 Optimizer 自己报 `Optimizer has not been authenticated`。"

**请你 30 秒内说出 3 种可能原因**。

<details>
<summary>参考答案</summary>

1. **Optimizer 心跳间隔 ≥ AMS HB_TIMEOUT**（W17）——`authenticate` 直接拒绝
2. **Optimizer 被 OptimizerKeeper 踢了**——发现 lastTouchTime 没变，过期 unregister
3. **AMS 重启或切主**——`authOptimizers` 内存 map 清空，token 对不上（HA 场景）
</details>

### ⭐⭐ 题目 2：pull vs push 对比分析

Amoro 选了 **pull 模型**（Optimizer 主动拉），而 YARN 用的是 **push 模型**（ResourceManager 主动推）。请写 200 字对比：

- 两者的优劣？
- 为什么 Amoro 选 pull？
- 如果要改成 push 难在哪？

### ⭐⭐⭐ 题目 3：双状态机找 Bug（推荐做）

假设一张表当前 `OptimizingStatus = MAJOR_OPTIMIZING`，它的所有 TaskRuntime 都处于 `ACKED`。此时**一个 Optimizer 心跳超时**：

- 根据源码，AMS 会做什么？
- 表的 `OptimizingStatus` 会变吗？
- `ACKED` 的 TaskRuntime 会走哪条分支（查 FSM 表）？

**带出你 Phase 3 真正复现这个场景的脚本思路**。

### ⭐⭐⭐⭐ 题目 4：参数风暴（高阶）

列出 Day3 出现的 **所有与 Optimizer/Optimizing 相关的参数**（`AmoroManagementConf.*`），画一张表：
- 参数名
- 默认值
- 作用
- **错配会出什么问题**（比如 HB_TIMEOUT 太小会怎样）

作为 Phase 2 的《调优手册》素材。

### ⭐⭐⭐⭐⭐ 题目 5：设计题（挑战）

假设你是 committer，要给 Amoro 加一个**"优先级"**特性：某些表（例如关键业务表）希望**优先得到 Optimizer 资源**。

请设计：
1. 你要改 `SchedulingPolicy` 还是 `OptimizingQueue` 还是新增一层？
2. 如何保证不破坏现有 Group 隔离？
3. 低优表会不会饿死？怎么避免？
4. 写一份 SPIP 草稿的大纲。

**这是 Phase 4 真正可以去社区提的 proposal 素材**。

---

## 🧪 本讲知识晶体

### 问题/场景
生产上 80% 的 Amoro 问题都出在 OptimizingService 这一层（任务不触发 / Optimizer 掉线 / 任务卡住）。读懂这一讲就有了排障的源码锚点。

### 核心源码锚点
- `DefaultOptimizingService.authenticate` (L257-278) — Optimizer 注册入口
- `DefaultOptimizingService.pollTask` (L210-216) — 核心拉任务入口
- `DefaultOptimizingService.TableRuntimeHandlerImpl` (L374-420) — 接 Day2 责任链
- `DefaultOptimizingService.OptimizerKeeper.run` (L487-512) — 心跳主循环
- `OptimizingQueue.pollTask + waitTask + fetchTask` (L199-239) — 三层队列逻辑
- `OptimizingQueue.scheduleTableIfNecessary` (L241-247) — 并行规划控制
- `OptimizingStatus` 7 态枚举 (整个文件)
- `TaskRuntime.Status` 6 态 + 显式转换表 (L274-314)

### 调用链速查

```
表状态变化（Day2）
    │
    ▼ fireStatusChanged
TableRuntimeHandlerImpl.handleStatusChanged
    │
    ▼
OptimizingQueue.refreshTable
    │
    └─ scheduler.addTable（IDLE 表池）
    
═══════ 等待 Optimizer 来 poll ═══════

Optimizer → authenticate → token
Optimizer → touch（周期性）
Optimizer → pollTask（阻塞 long-polling）
    │
    ▼
OptimizingQueue.pollTask
    ├─ fetchTask  ← retryTaskQueue 优先
    └─ waitTask   ← scheduleTableIfNecessary + await
                  
         scheduleTableIfNecessary
            │
            └─ triggerAsyncPlanning（submit to planExecutor）
                │
                └─ planInternal（Day4 深挖）
                     │
                     └─ planningCompleted.signalAll()  ← 唤醒 waitTask

Optimizer → ackTask     → PLANNED→SCHEDULED→ACKED
Optimizer → completeTask → ACKED→SUCCESS / FAILED

═══════ 心跳监控独立线程 ═══════

OptimizerKeeper.take
    ├─ tryKeeping  ← 比较 lastTouchTime
    ├─ collectTasks + retryTask  ← 先救任务
    └─ 过期 → unregisterOptimizer
       未过期 → keepInTouch（再入队）
```

### 关键参数速查（生产必备）

| 参数 key | 作用 | 错配后果 |
|---|---|---|
| `ams.server.optimizer.heart-beat-timeout` | Optimizer 心跳超时 | 太小 → Optimizer 频繁 unregister；太大 → 故障检测延迟 |
| `ams.server.optimizer.task.ack.timeout` | Task ack 超时 | 同上 |
| `ams.server.optimizing.refresh.group.interval` | Group 配置刷新间隔 | 太小 → 频繁扫 DB；太大 → 配置改动生效慢 |
| `ams.server.optimizer.max.planning.parallelism` | 同时规划的表数上限 | 太大 → 大表一起 plan OOM；太小 → 规划吞吐受限 |
| `ams.server.optimizer.polling.timeout` | Optimizer long-polling 超时 | 太小 → Optimizer 空转；太大 → 响应 Queue 变化慢 |

### 设计意图速记
- **pull 模型**：AMS 无状态转发 + Optimizer 主动接单 = 水平扩容容易
- **ReentrantLock + Condition**：当同步逻辑 > BlockingQueue 能力时的正确选择
- **双状态机**：表级（业务粒度）+ 任务级（执行粒度）= 精确控制
- **显式 FSM 转换表**：比 if/else 安全 100 倍
- **DelayQueue 心跳**：最省 CPU 的精确超时检测
- **按 Group 分队列**：多租户的第一刀
- **retryTask 优先**：保证任务最终完成

### 踩坑登记（Day3 新增 W13-W18，累计 18 条）

---

## 🔚 本讲收尾

### 今天我学会了

- [x] OptimizingService 的 pull 模型全链路（authenticate/touch/poll/ack/complete）
- [x] `OptimizingQueue` 的三层队列结构（retry/table/planning）
- [x] `ReentrantLock + Condition` vs `BlockingQueue` 的选择判据
- [x] 双状态机（7 态 + 6 态）+ 显式 FSM 转换表
- [x] `OptimizerKeeper` 的 DelayQueue 心跳机制
- [x] `planningTables` 并行上限的限流设计
- [x] 按 Group 分队列的多租户隔离

### 段位变化

| 维度 | Day2 末 | **Day3 末** |
|---|---|---|
| Amoro 源码段位 | L2 初阶 | **L2 中阶**（核心调度链路打通）|
| 能画的图 | 启动 + 运行期 | + **双状态机 + pull 模型全景** |
| 能答的问题 | 运行期行为 | + **自优化任务流 / Optimizer 心跳 / 超时机制** |
| L3 坑登记 | 12 条 | **18 条** |

### 下次开工（Day4 任务清单）

**Day4 主题**：《"要不要优化"是怎么算出来的？—— Planner + Evaluator 决策大脑精讲》

1. 🔍 读 `AbstractOptimizingPlanner`（在 `amoro-format-mixed` 或 `amoro-common`）
2. 🔍 读 `OptimizingEvaluator` —— 判断是否需要优化
3. 🔍 读 `Mixed-Iceberg` 的具体 Planner 实现（`MixedIcebergPartitionPlan` 之类）
4. 🔍 读 `RewriteFilesInput` + `RewriteStageTask`
5. 🔍 理解 Full / Major / Minor 三种优化的差别
6. ✍️ 按八段式写 Day4 笔记

---

> **信条**：代码里每一个"看起来多余的同步原语"背后都有一个新手看不见的坑。能看见这些坑，你就到了 L3。

— eric · Amoro 源码精通 · 第 03 讲
