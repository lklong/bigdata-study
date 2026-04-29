# Amoro 源码精通 · Day2 · 《表是怎么"活"的？—— TableRuntime 生命周期与责任链精讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 02 讲  
> 本讲时长：50 分钟阅读 + 90 分钟动手  
> 承接：Day1《AMS 控制面从零开讲》

---

## 🎯 本讲学完你能干什么

读完这一讲，你将能够：

- ✅ **默画 AMS 的"表发现→注册→监听→清理"完整生命周期**（6 大阶段）。
- ✅ **30 秒讲清楚** `TableService / TableRuntime / RuntimeHandlerChain / InlineTableExecutors` 四者的**协作关系**。
- ✅ **回答生产问题**："为什么我新建的外部 Iceberg 表 AMS 看不到？"
- ✅ **回答生产问题**："为什么我把 Catalog 删了，AMS 里表还在？"
- ✅ **看懂 Amoro 对"责任链"的一个"反直觉"设计**——它既不是经典责任链，也不是事件总线，而是**"广播型递归链"**。
- ✅ **给同事解释** `Action` / `Process` / `TableProcessContainer` 这组抽象，为 Day3 讲自优化打下地基。

---

## 🪜 预备知识

| 点 | 要会什么 |
|---|---|
| Day1 内容 | 能默画 AMS 启动 12 步 + 3 个 Table 抽象 |
| Java 并发基础 | `ConcurrentHashMap` / `CompletableFuture` / `ScheduledExecutorService` |
| 设计模式直觉 | 知道"责任链""观察者""策略"三种模式的差别 |
| Iceberg 基础 | 知道 Iceberg 表有 snapshot 概念 |

---

## 🧠 一句话心智模型

> **Day1 讲的是 AMS 怎么"开机"。Day2 讲的是 AMS 开机之后，每一张表在 AMS 脑袋里"活着"的样子——怎么进来、怎么被盯着、怎么被派活、怎么出去。**

Day1 = 物业大楼怎么开业；Day2 = 每一个业主怎么被物业管起来。

---

## 🏛️ 从生活类比入手：表的"一生"

接着 Day1 的物业类比，继续讲：

> 🏘️ **一张 Amoro 表从进入 AMS 到离开，就像一位业主的完整生命周期**
>
> ```
> 👤 业主出现在楼盘             (ExternalCatalog 里新增了一张 Iceberg 表)
>    │
>    ▼
> 📋 物业去各楼盘巡查             (tableExplorerScheduler 每 N 秒跑一遍)
>    │
>    ▼  发现新业主
> 📝 登记入住                    (syncTable + triggerTableAdded)
>    │ - 办物业 ID 卡（主键 id）
>    │ - 建业主档案（DefaultTableRuntime）
>    │ - 通知所有部门欢迎（fireTableAdded 广播）
>    ▼
> 👁️ 定期盯梢                    (TableRuntimeRefreshExecutor 每 N 秒刷一次)
>    │ - 看他家 snapshot 变没变
>    │ - 变了 → fireStatusChanged 广播到各部门
>    │   ├─ 优化组：要不要合并小文件？
>    │   ├─ 清洁组：要不要清孤儿文件？
>    │   ├─ 快照组：要不要过期老快照？
>    │   └─ ...（共 10 个部门）
>    ▼
> 🎬 派活干活                    (trigger(Action) → TableProcessContainer)
>    │ - 给外包公司（Optimizer）下派优化任务
>    │ - 任务一个个 Process 执行完成
>    ▼
> 👋 业主搬走                    (Catalog drop 或表被删)
>    │ - 巡查发现业主不在了
>    │ - fireTableRemoved 广播通知所有部门
>    │ - 销毁档案、注销 ID、移除监控
> ```

**本讲要讲清楚的，就是上面这段伪代码在源码里是如何精确实现的**。

---

## 🔍 源码逐层剥离

### L1 · 接口层：Day2 要掌握的 5 个核心类

```
┌────────────────────────────────────────────────────────┐
│  1. DefaultTableService                                │
│     "物业总部调度室" — 管所有表的生命周期大循环           │
│     - tableRuntimeMap: Map<Long, DefaultTableRuntime> │
│     - exploreTableRuntimes()  定时巡查大循环           │
│     - syncTable()             把新表登记入库           │
│     - disposeTable()          把走的表销户             │
│     - triggerTableAdded()     广播"有新业主了"         │
├────────────────────────────────────────────────────────┤
│  2. DefaultTableRuntime                                │
│     "单个业主档案"— 每张表在 AMS 内存里的投影             │
│     - tableIdentifier: ServerTableIdentifier           │
│     - optimizingState: DefaultOptimizingState         │
│     - processContainerMap: Map<Action, Container>     │
│     - trigger(Action)         按动作派活               │
│     - dispose()               销户                    │
├────────────────────────────────────────────────────────┤
│  3. RuntimeHandlerChain (抽象)                         │
│     "部门流水线" — 表事件广播到各部门                    │
│     - fireTableAdded()        新业主入住              │
│     - fireStatusChanged()     业主状态变化             │
│     - fireConfigChanged()     业主配置变更             │
│     - fireTableRemoved()      业主退租                │
│     - 子类 handleXxx() 各部门自己的处理逻辑            │
├────────────────────────────────────────────────────────┤
│  4. InlineTableExecutors                               │
│     "10 个部门的注册器"— 单例工厂管理 10 种定时 Executor │
│     - setup()                按开关注册                │
│     - getXxxExecutor()       返回各个 handler 给主干   │
├────────────────────────────────────────────────────────┤
│  5. TableProcessContainer (内部类)                     │
│     "单表的任务容器" — 单个 Action 下的进程池            │
│     - processFactory: 创建 Process 的工厂              │
│     - processMap: 正在跑的 Process 列表                │
│     - trigger()              启一个 Process           │
└────────────────────────────────────────────────────────┘
```

---

### L2 · 主链路一：定时巡查大循环（核心心跳）

**这是 AMS 的"心跳"——每 N 秒跑一次，发现新表 / 发现表消失 / 全量同步**。

**入口**：`DefaultTableService.initialize()` L182-183

```java
tableExplorerScheduler.scheduleAtFixedRate(
    this::exploreTableRuntimes, 0, externalCatalogRefreshingInterval, TimeUnit.MILLISECONDS);
```

**调用链逐帧展开**（L231-272）：

```
exploreTableRuntimes()              // 每 N 秒执行一次
  │
  ├─ 1. long start = System.currentTimeMillis();            ← 记录开始时间
  │
  ├─ 2. List<ServerCatalog> externalCatalogs = 
  │         catalogManager.getServerCatalogs();             ← 取当前所有 Catalog
  │
  ├─ 3. LOG.info("Syncing server catalogs: {}", ...);
  │
  ├─ 4. for each serverCatalog in externalCatalogs:         ← 遍历每个 Catalog
  │       │
  │       ├─ if (serverCatalog.isInternal())
  │       │     exploreInternalCatalog(...)                 ← AMS 自管 Catalog
  │       │
  │       └─ else 
  │             exploreExternalCatalog(...)                 ← Hive/外部 Iceberg
  │
  ├─ 5. 清理僵尸 TableRuntime：                            ← ★★ 容错兜底
  │      for each tableRuntime in tableRuntimeMap:
  │         if tableRuntime 所在的 catalog 已经不在 catalogNames:
  │              disposeTable(...)
  │      
  │      注释原话：
  │      "It is permissible to have some erroneous states
  │       in the middle, as long as the final data is consistent."
  │
  └─ 6. LOG.info("Syncing external catalogs took {} ms.", end - start);
```

**🔑 教学关键点**：

- **第 5 步是真正的"大师级"设计** —— Amoro 承认"中间状态可以错，但最终一致"。这是**最终一致性**思想的典型应用。为什么？因为 drop catalog 和 drop tableRuntime 是两个事务，并发时可能不同步，**靠这个定时兜底补救**。
- 这一句代码注释（第 256-259 行）值得写进教科书：*"It is permissible to have some erroneous states in the middle, as long as the final data is consistent."*

---

### L2 · 主链路二：ExternalCatalog 的三路操作（差集思维）

`exploreExternalCatalog()` (L275-368) 是 Day2 最**烧脑也最精妙**的一段代码。它要同时处理三件事：

1. **哪些表是新增的**（外部有、AMS 没有）→ `syncTable` 登记
2. **哪些表是被删的**（AMS 有、外部没有）→ `disposeTable` 销户
3. **两边都有的**（交集）→ 不动

**核心代码片段**（简化版）：

```java
// A = 外部 Catalog 里当前的所有表 ID
Set<TableIdentity> tableIdentifiers = ...;

// B = AMS DB 里登记的所有表 ID
Map<TableIdentity, ServerTableIdentifier> serverTableIdentifiers = ...;

// 外部有 - AMS 没有 = 要新登记的
Sets.difference(tableIdentifiers, serverTableIdentifiers.keySet())
    .forEach(tableIdentity -> {
        CompletableFuture.runAsync(() -> syncTable(...), tableExplorerExecutors);
    });

// AMS 有 - 外部没有 = 要销户的
Sets.difference(serverTableIdentifiers.keySet(), tableIdentifiers)
    .forEach(tableIdentity -> {
        CompletableFuture.runAsync(() -> disposeTable(...), tableExplorerExecutors);
    });

// 全部提交到线程池跑，最后 join 等完成
taskFutures.forEach(CompletableFuture::join);
```

**🔑 教学关键点**：

1. **集合差集是 SRE 的基本功**。你在任何"两边同步"场景（文件同步、HBase region 同步、ZK 节点同步）都会见到这个模式。
2. **不是一张一张同步**，而是先算差集，再**用 `CompletableFuture` 丢线程池并发跑**。这就是为什么 `setup` 里要配 `REFRESH_EXTERNAL_CATALOGS_THREAD_COUNT` 这个参数。
3. **`RejectedExecutionException` 出现在日志里**就说明你表太多了，线程池队列满了——这是生产最常见的告警之一。

**举一反三**：

| 场景 | 差集用法 |
|---|---|
| HDFS trash 清理 | 磁盘现有 - 保留策略 = 要删除 |
| HBase region 同步 | Master 的 meta - RegionServer 的实际 = 异常的 |
| MSCK REPAIR TABLE | 目录真实分区 - metastore 分区 = 要补加的 |
| Amoro tableRuntime 同步 | 外部表 ∆ AMS DB = 要建/要销 |

---

### L2 · 主链路三：责任链的"广播型递归"设计（重头戏）

这是 Day1 我讲的时候**留了一个小坑**——说它是"责任链"。今天 Day2 深读后必须**纠正**：

**Amoro 的 `RuntimeHandlerChain` 不是经典责任链，而是"广播型递归链"。**

#### 经典责任链 vs Amoro 的设计

**经典责任链**（例如 Tomcat Filter）：
```java
public void doFilter(Request req) {
    // 前置处理
    if (canHandle(req)) {
        handle(req);        // 自己处理
    } else {
        next.doFilter(req); // 交给下一个
    }
    // 后置处理
}
```
**特点**：一个请求**只由最匹配的那个**处理，后面的不执行。

**Amoro 的"广播型递归链"**（`RuntimeHandlerChain.fireStatusChanged`）：
```java
public final void fireStatusChanged(
    DefaultTableRuntime tableRuntime, OptimizingStatus originalStatus) {
  if (!initialized) return;
  if (formatSupported(tableRuntime.getFormat())) {
    doSilently(() -> handleStatusChanged(tableRuntime, originalStatus));  // 自己处理
  }
  if (next != null) {
    next.fireStatusChanged(tableRuntime, originalStatus);                  // 然后下一个也处理
  }
}
```
**特点**：一个事件**所有 Handler 都要处理**，不是二选一。

#### 它为什么不叫"事件总线"

广播型递归链 vs 事件总线的区别：

| 维度 | 事件总线（EventBus） | Amoro 广播型递归链 |
|---|---|---|
| 数据结构 | 订阅者列表（subscribers[]） | 单向链表（next 指针） |
| 调用方式 | 遍历 listeners 通常异步 | 递归同步调用（调用栈深度 = Handler 数） |
| 顺序保证 | 可能无序或按 priority | **严格按 append 顺序** |
| 失败处理 | 通常捕获不 throw | `doSilently` 吞异常继续 |
| 启动期 vs 运行期 | 动态订阅 | **`checkNotStarted()` 启动期固化** |
| 过滤机制 | 按 Event 类型 | `formatSupported(format)` 按表格式过滤 |

**🔑 教学关键点**：

- **这是"有序广播"的最简实现**。当你有 10 个 Handler 必须按顺序都跑一遍，用"next 指针"而非 for 循环的好处是：**每个 Handler 可以决定是否调用 `next.xxx()`**——虽然 Amoro 没用这个能力，但保留了未来"中断广播"的可能。
- **`doSilently` 是生产级设计**（L127-133）：一个 Handler 抛异常不能影响后面 9 个 Handler 的执行，这叫 **failure isolation（故障隔离）**。

#### 一个精妙的"反向遍历"细节

读到这里眼睛放尖一点，`fireTableRemoved` (L106-118) **和其他 `fireXxx` 的顺序不一样**：

```java
public final void fireTableRemoved(DefaultTableRuntime tableRuntime) {
  if (!initialized) return;

  // ★ 注意：先调 next，再调自己！
  if (next != null) {
    next.fireTableRemoved(tableRuntime);
  }

  if (formatSupported(tableRuntime.getFormat())) {
    doSilently(() -> handleTableRemoved(tableRuntime));
  }
}
```

**对比** `fireTableAdded` (L93-104) 的顺序：
```java
public final void fireTableAdded(AmoroTable<?> table, DefaultTableRuntime tableRuntime) {
  if (!initialized) return;

  if (formatSupported(tableRuntime.getFormat())) {
    doSilently(() -> handleTableAdded(table, tableRuntime));   // 先自己
  }
  if (next != null) {
    next.fireTableAdded(table, tableRuntime);                  // 后 next
  }
}
```

**🔑 为什么？—— 这是"依赖倒序"的经典玩法**：

- **Added 时**：顺序是 `A → B → C`（先 A 先建，后面依赖 A 的 B/C 再建）
- **Removed 时**：顺序是 `C → B → A`（先拆掉 C/B，最后才能拆 A）
- 就像**穿袜子再穿鞋，脱鞋再脱袜子**。

**这才是真正的生产级代码**。新手会把四个 fire 都写成一样，老工匠会区分。

---

### L2 · 主链路四：表注册的事务性

**看 `DefaultTableService.syncTable()` (L424-445)**：

```java
private void syncTable(ExternalCatalog externalCatalog, TableIdentity tableIdentity) {
  AtomicBoolean tableRuntimeAdded = new AtomicBoolean(false);
  try {
    doAsTransaction(
        () -> externalCatalog.syncTable(...),                      // step 1: 写 DB
        () -> {
          ServerTableIdentifier tableIdentifier = 
              externalCatalog.getServerTableIdentifier(...);       // step 2: 查回 id
          tableRuntimeAdded.set(triggerTableAdded(...));           // step 3: 建内存 runtime
        });
  } catch (Throwable t) {
    if (tableRuntimeAdded.get()) {                                  // step 3 成功但整体失败
      revertTableRuntimeAdded(externalCatalog, tableIdentity);      // 手动回滚内存
    }
    throw t;
  }
}
```

**🔑 教学关键点** —— 这是典型的 **"DB 事务 + 非事务内存操作"混合场景** 的正确写法：

1. `doAsTransaction(...)` 保证 DB 层的事务一致性。
2. 但 `tableRuntimeMap.put` 是**内存操作**，DB 事务管不到它。
3. 所以用 `AtomicBoolean tableRuntimeAdded` 记录"内存是否已改"，**catch 里手动回滚**。

**这个模式很重要**：只要你有"DB + 内存双写"场景（任何注册中心、任何缓存系统都有），都要考虑这个**"混合事务的手动补偿"**。

---

### L2 · 主链路五：`DefaultTableRuntime` 的 Action/Process 模型（Day3 的地基）

Day1 我们看到 `tableRuntime` 是个"档案"，Day2 深读后发现它其实更像**一个"任务调度小中心"**：

```java
public class DefaultTableRuntime {
  private final Map<Action, TableProcessContainer> processContainerMap;

  @Override
  public AmoroProcess<?> trigger(Action action) {           // 按 Action 派活
    return processContainerMap.get(action).trigger(action);
  }

  @Override
  public void install(Action action, ProcessFactory<?> f) { // 注册一种 Action 能跑的工厂
    processContainerMap.putIfAbsent(action, new TableProcessContainer(f));
  }
}
```

配合 `TableProcessContainer` (L137-163)：

```java
private class TableProcessContainer {
  private final Lock processLock = new ReentrantLock();
  private final ProcessFactory<?> processFactory;
  private final Map<Long, AmoroProcess<?>> processMap;
  
  public AmoroProcess<?> trigger(Action action) {
    processLock.lock();
    try {
      AmoroProcess<?> process = processFactory.create(DefaultTableRuntime.this, action);
      process.getCompleteFuture().whenCompleted(() -> processMap.remove(process.getId()));  // 自清理
      processMap.put(process.getId(), process);
      return process;
    } finally {
      processLock.unlock();
    }
  }
}
```

**🔑 教学关键点**：

- **`Action`（优化/清理/过期/...）← → `ProcessFactory`（怎么创建任务）← → `AmoroProcess`（运行中的任务实例）** 这套三元组是 Amoro 调度核心的通用抽象。
- **自清理设计**：`process.getCompleteFuture().whenCompleted(() -> processMap.remove(...))` —— 任务完成**自动从 map 移除**，不依赖外部定时清理。
- **`ReentrantLock` 而非 `synchronized`**：因为 `trigger` 可能耗时长（要 `processFactory.create`），用显式锁能**精确控制加锁范围 + 支持 tryLock**。

**这就是 Day3 要深挖的"自优化"的地基**——自优化无非是 `Action = OPTIMIZING` 的一个 Process。

---

### L3 · 异常边界预警（新增登记，接 Day1 的 W1-W6）

| 编号 | 文件 | 行号 | 嫌疑 | 类比 |
|---|---|---|---|---|
| **W7** | `DefaultTableService` | L264-268 清理僵尸 | 单线程清理，表多了会拖慢整个 exploreTableRuntimes；且 `disposeTable` 拿不到锁也会阻塞后续 | 巡查员一个人干两件事 |
| **W8** | `DefaultTableService` | L329-344 线程池 rejectedExecution | 线程池队列满了只打 `LOG.error`，**不抛异常**——结果是部分表静默丢失同步 | 前台接待太多，排队的业主被轰走没记录 |
| **W9** | `DefaultTableService` | L367 `taskFutures.forEach(join)` | `.join()` 会阻塞，**一个表卡住，整轮 explore 就卡住**；而 explore 是 ScheduledAtFixedRate，会导致**下一轮延迟累积** | 巡查员等一户等到天亮，其他户全漏了 |
| **W10** | `RuntimeHandlerChain` | L127-133 `doSilently` | 虽是故障隔离，但**只打 ERROR 日志不上报 metrics**，handler 静默失败很难发现 | 部门出错不告诉总经理 |
| **W11** | `DefaultTableRuntime` | L138 `ReentrantLock` | 如果 `processFactory.create()` 本身阻塞，锁会被长时间占用，其他并发 trigger 同 Action 都排队 | 外包公司打一个电话半小时，后面的业主全排队 |
| **W12** | `DefaultTableService` | L81 `CompletableFuture<Boolean> initialized` 配合 `initialized.get()` | 若 `initialize()` 抛异常**从未调 `complete(true)`**，后续所有 `checkStarted()` 会**永远阻塞** | 开业庆典出事，前台永远打不开 |

这 12 个坑会在 Phase 3（Day 46-70）逐一复现。

---

## 💡 精妙设计拆解（记住就能举一反三）

### 精妙一：`initialized = CompletableFuture<Boolean>` 作为启动屏障

**对比两种写法**：

❌ **新手写法**：
```java
private volatile boolean started = false;

public void initialize() { ... ; started = true; }

public Xxx get() {
    if (!started) throw new IllegalStateException("Not started");
    ...
}
```

✅ **Amoro 写法**：
```java
private final CompletableFuture<Boolean> initialized = new CompletableFuture<>();

public void initialize() { ... ; initialized.complete(true); }

private void checkStarted() {
    try { initialized.get(); } catch (Exception e) { throw new RuntimeException(e); }
}
```

**好在哪**：

1. `CompletableFuture.get()` 是**阻塞等待**——在 `initialize` 还没跑完时调用 `getRuntime()` 会**自动等**而不是报错。
2. `complete(true)` 是**幂等且一次性**——多次调用只第一次生效。
3. 未来若想加"启动超时" `initialized.get(5, TimeUnit.SECONDS)` 一行就能加。

**举一反三**：任何"启动慢 + 外部会提前调用"的组件都适合这个模式（Spring bean lazy init、Kafka consumer group 加入等）。

### 精妙二：`this::exploreTableRuntimes` 与 `ScheduledExecutorService`

```java
tableExplorerScheduler.scheduleAtFixedRate(
    this::exploreTableRuntimes, 0, externalCatalogRefreshingInterval, TimeUnit.MILLISECONDS);
```

**三个细节值得品**：

1. **`this::method` 方法引用**比 `() -> exploreTableRuntimes()` 更简洁、性能更好（JVM 有特化）。
2. **初始延迟 `0`** + 固定频率 —— 启动后立即跑第一轮，不等。
3. 调度器是**单线程** `newSingleThreadScheduledExecutor`，避免两轮 explore 并发干扰；但**真正的表同步**丢给另一个线程池 `tableExplorerExecutors`，职责分离。

### 精妙三：Executor 按开关装配（插件化的前身）

看 `InlineTableExecutors.setup()`：

```java
if (conf.getBoolean(AmoroManagementConf.EXPIRE_SNAPSHOTS_ENABLED)) {
    this.snapshotsExpiringExecutor = new SnapshotsExpiringExecutor(...);
}
if (conf.getBoolean(AmoroManagementConf.CLEAN_ORPHAN_FILES_ENABLED)) {
    this.orphanFilesCleaningExecutor = new OrphanFilesCleaningExecutor(...);
}
// ...
```

**教学点**：

- **Executor 全部按开关 `xxx.enabled` 决定是否初始化**——这是"**Feature Flag**"思想在运维场景的落地。
- 生产上可以灵活**关掉某个清理器**（比如磁盘空间够用时关掉 `orphan-files-cleaning` 省资源）。
- 代码架构为"未来变插件化"留了口子——只要把 `if` 改成 SPI 加载就能变成完全插件化。

**你自己写代码时要抄这个套路**：任何"可选能力"都用 `enabled` 开关裹起来，别硬编码。

---

## 🎓 举一反三：同构系统清单

| Amoro 机制 | 同构系统 | 关键词 |
|---|---|---|
| `exploreTableRuntimes` 定时差集同步 | HBase Master 的 `RegionStateManager`、Kubernetes controller 的 `reconcile` 循环 | **Reconciler 模式** |
| `tableRuntimeMap` 作为 DB 的内存镜像 | ZK 的 `DataTree`、HDFS NameNode 的 `BlockMap`、Kafka Controller 的 `MetadataCache` | **冷热分层** |
| `RuntimeHandlerChain` 广播型递归链 | Netty 的 `ChannelPipeline`（双向）、Servlet Filter 链 | **Pipeline 模式** |
| `fireTableRemoved` 反向遍历 | LIFO 资源释放、析构函数倒序调用 | **依赖倒序** |
| `Action/Process/ProcessFactory` 三元组 | HBase `Procedure` 框架、Flink `Checkpoint` 机制、Raft `Entry/StateMachine` | **命令模式 + 工厂** |
| `InlineTableExecutors.enabled` 开关装配 | Spring Boot `@ConditionalOnProperty`、Kubernetes feature gates | **Feature Flag** |
| `CompletableFuture<Boolean> initialized` 启动屏障 | Kafka 的 `CountDownLatch` 初始化、Java 9 的 `Phaser` | **启动同步器** |
| 线程池 reject 静默丢弃 | HDFS 的 `CallQueue` 降级、RPC 的 `RejectedHandler` | **降级策略**（⚠️ Amoro 这里有隐患，见 W8） |

---

## 📝 课后习题

### ⭐ 题目 1：默讲一分钟

闭上眼睛，**用 60 秒**把 `exploreTableRuntimes` 的 6 个步骤讲出来。讲不全回去重看 L231-272。

### ⭐ 题目 2：生产问题推理（最推荐做）

场景：运维小张反馈："新建了一个 Iceberg 表，等了 10 分钟，AMS Dashboard 上还看不到。"

请根据今天的源码，列出 **≥4 种可能原因**，并给出每种原因对应的**查证方法**。

<details>
<summary>展开参考答案（自己写完再看）</summary>

1. **外部 Catalog 没刷新** → 查 `ams.server.refresh.external.catalogs.interval`，默认可能就是 10 分钟
2. **线程池满** → 搜日志 `The queue of table explorer is full`（W8）
3. **Mixed 表被忽略** → 看 `triggerTableAdded` L452-455 逻辑，Mixed 的 Iceberg 子表会被跳过
4. **表格式不支持** → `formatSupported` L136-138 只接 ICEBERG/MIXED_ICEBERG/MIXED_HIVE，Paimon 是直到更新才被纳管
5. **explore 自己卡住了** → 某一轮卡了，下一轮永远等不到（W9）

</details>

### ⭐⭐⭐ 题目 3：对比阅读

打开 Kubernetes `kube-controller-manager` 源码（GitHub 找 `controller/endpoint/endpoints_controller.go`），观察它的 `syncService` 函数。对比 Amoro 的 `exploreExternalCatalog`：

- 两者都是 Reconciler 模式，**差异在哪**？
- K8s 的 informer 机制是不是更先进？为什么 Amoro 没抄？
- 把结论写成 200 字总结。

### ⭐⭐⭐⭐ 题目 4：找 Bug 嫌疑（高阶）

针对 W9（`taskFutures.forEach(join)` 阻塞风险），设计一个**复现 demo**：

- 在一个 Catalog 下建 100 张表
- 人为让其中 1 张表 sync 卡住 60 秒
- 观察 AMS 的 explore 周期会不会"累积延迟"
- 记录你的观察结论

这题做出来就是一个能提 PR 的素材。

### ⭐⭐⭐⭐⭐ 题目 5：源码贡献（挑战）

Amoro 的 `W10` 问题（`doSilently` 不上报 metrics）如果你是 committer 会怎么修？请写一段伪代码改造 `RuntimeHandlerChain.doSilently`：

要求：
1. 保留故障隔离（不打断链）
2. 增加 metrics 计数（按 Handler class name 分组）
3. 增加 TRACE 级日志栈追踪
4. 兼容现有调用方

**这就是你未来提 PR 的练手题**。

---

## 🧪 本讲知识晶体

### 问题/场景
理解 AMS 运行期"表的一生"——从发现到消亡的完整链路，是一切后续生产排障的基础。

### 核心源码锚点
- `DefaultTableService.initialize` (L147-185) — 启动初始化 + 定时器注册
- `DefaultTableService.exploreTableRuntimes` (L231-272) — 定时巡查大循环
- `DefaultTableService.exploreExternalCatalog` (L275-368) — 差集同步
- `DefaultTableService.syncTable` (L424-445) — 事务性注册
- `DefaultTableService.triggerTableAdded` (L447-465) — 内存登记 + 广播
- `DefaultTableRuntime` (L45-164) — 表运行时容器
- `RuntimeHandlerChain` (L33-153) — 广播型递归链
- `InlineTableExecutors.setup` (L43-96) — 10 Executor 按开关装配

### 调用链速查

```
ScheduledExecutor 定时触发
    │
exploreTableRuntimes()          [DefaultTableService]
    ├─ catalogManager.getServerCatalogs()
    ├─ for each catalog:
    │   ├─ isInternal → exploreInternalCatalog
    │   └─ external   → exploreExternalCatalog
    │                   ├─ listDatabases → listTables（并发）
    │                   ├─ Sets.difference(A, B) → syncTable（并发）
    │                   ├─ Sets.difference(B, A) → disposeTable（并发）
    │                   └─ taskFutures.forEach(join)
    └─ 僵尸清理：遍历 tableRuntimeMap
        └─ catalog 已删 → disposeTable

syncTable
    ├─ doAsTransaction(
    │    externalCatalog.syncTable(),                    ← DB 操作
    │    triggerTableAdded() = {
    │       new DefaultTableRuntime(...)
    │       tableRuntimeMap.put(...)
    │       headHandler.fireTableAdded(...) ────── RuntimeHandlerChain ──┐
    │    })                                                              │
    └─ catch: revertTableRuntimeAdded（手动补偿）                        │
                                                                         ▼
                                    各 Handler.handleTableAdded() 顺序执行
                                    （OptimizingService / DataExpiring / OrphanFilesCleaning / ...）
```

### 关键参数速查（生产调参必读）

| 参数 key | 作用 | 调优建议 |
|---|---|---|
| `ams.server.refresh.external.catalogs.interval` | 巡查周期 | 外部表少可调大（省 HMS 负担）；多可调小（发现更快）|
| `ams.server.refresh.external.catalogs.thread.count` | 并发同步线程池大小 | 外部表多 → 调大 |
| `ams.server.refresh.external.catalogs.queue.size` | 同步线程池队列 | 看到 "queue of table explorer is full" → 调大 |
| `ams.server.expire.snapshots.enabled` | 是否开快照过期 | 默认开，空间紧才关 |
| `ams.server.clean.orphan.files.enabled` | 是否清孤儿文件 | 默认开 |
| `ams.server.clean.dangling.delete.files.enabled` | 清悬空 delete 文件 | 默认开 |
| `ams.server.refresh.tables.interval` | 单表 refresh 频率 | 大表集群调长 |
| `ams.server.sync.hive.tables.enabled` | Hive 提交同步 | 使用 Mixed-Hive 才开 |

### 设计意图速记
- **Reconciler 模式**：差集同步 + 定时兜底 = 最终一致性
- **广播型递归链 ≠ 责任链**：所有 Handler 都要跑，按 append 顺序
- **Added 正序 / Removed 倒序**：依赖关系决定的经典玩法
- **DB 事务 + 内存手动补偿**：混合事务的正确姿势
- **CompletableFuture 作启动屏障**：比 volatile boolean 优雅得多

### 踩坑登记（Day2 新增 W7-W12，Day1 已登 W1-W6）
12 处 L3 嫌疑，Phase 3 验证。

---

## 🔚 本讲收尾

### 今天我学会了

- [x] AMS 表运行时的 6 阶段生命周期（默画）
- [x] `exploreTableRuntimes` 定时巡查 + 差集同步 + 僵尸清理
- [x] `RuntimeHandlerChain` 是广播型递归链不是经典责任链
- [x] `fireTableAdded` 正序 / `fireTableRemoved` 倒序的精妙
- [x] `DefaultTableRuntime` 的 `Action/ProcessFactory/Process` 三元组
- [x] `CompletableFuture<Boolean>` 作启动屏障的正确姿势
- [x] `InlineTableExecutors` 按开关装配 10 个 Executor

### 段位变化

| 维度 | Day1 末 | Day2 末 |
|---|---|---|
| Amoro 使用 | L2 | L2（不变） |
| Amoro 源码 | L1.5 | **L2 初阶**（脑中有了运行期主骨架）|
| 能画架构图 | AMS 启动 12 步 | + 表生命周期 6 阶段 + 责任链/事件对照 |
| L3 坑登记 | 6 条（W1-W6） | **12 条**（W1-W12） |

### 下次开工（Day3 任务清单）

Day3 主题：**《自优化是怎么被触发的？—— OptimizingService 调度核心精讲》**

1. 🔍 读 `DefaultOptimizingService` 的 init + core loop
2. 🔍 读 `TableRuntimeHandler` —— OptimizingService 对外的 Handler 实现
3. 🔍 读 `OptimizingQueue` —— 任务队列结构
4. 🔍 读 `OptimizingPlanner` + `OptimizingEvaluator` —— "要不要优化"的决策大脑
5. 🔍 理清 `DefaultOptimizingState` —— 单表优化状态机
6. ✍️ 按八段式写 Day3 笔记

---

> **信条**：读源码不只是读"做了什么"，更要读"为什么这么做"。能把"为什么"讲给同事听，你就到了 L2 顶峰；能把"为什么"改得更好，你就到了 L3。

— eric · Amoro 源码精通 · 第 02 讲
