# Amoro 源码精通 · Day5 · 《优化任务怎么真正干起来？—— TaskRuntime + Optimizer Executor + Commit 全链路精讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 05 讲  
> 承接：Day4《决策大脑 Planner 精讲》

---

## 🎯 本讲学完你能干什么

- ✅ **默画出一个优化任务从 PLANNED 到 SUCCESS 的 6 步状态转换**（带"谁触发"）
- ✅ **讲清楚 Optimizer 进程的 `while(true)` 主循环在干什么**——poll → ack → execute → complete
- ✅ **理解 Iceberg `Transaction + RewriteFiles` 的 commit 机制**——为什么 commit 要分两步
- ✅ **回答生产问题**："优化任务一直处于 ACKED 不结束怎么办？"
- ✅ **看透 `TaskStatusMachine` 的两个方法差异**：`accept()` 抛异常 vs `tryAccepting()` 返回 false

---

## 🧠 一句话心智模型

> **Day3 讲了"滴滴怎么派单"，Day4 讲了"乘客怎么做体检排队"。Day5 讲的是"司机到了以后怎么干活、干完怎么交差"——从 Optimizer 线程的 `while(true)` 开始，到 Iceberg 的 `transaction.commitTransaction()` 结束，一张表的一次优化就此闭环。**

---

## 🏛️ 生活类比：从接单到结款

```
  🚗 司机（Optimizer 线程）的一天
  
  while (没下班) {
    ① 打开 App 接单     →  pollTask()    ← 阻塞 long-polling
    ② 告诉平台"我接了"   →  ackTask()     ← PLANNED → SCHEDULED → ACKED
    ③ 开车送客             →  executeTask() ← 真正干活（RewriteFiles）
    ④ 告诉平台"我送到了" →  completeTask()← ACKED → SUCCESS / FAILED
  }
  
  🏢 平台（AMS）在另一边：
  ⑤ 收到完工 → 更新状态 → 当所有 task 都完工 → 触发 COMMIT
  ⑥ commit() → Iceberg Transaction → 写新 snapshot → 闭环
```

---

## 🔍 源码逐层剥离

### L2 · Optimizer 侧的 `while(true)` 主循环

**文件**：`amoro-optimizer-common/OptimizerExecutor.java` (L48-60)

```java
public void start() {
  while (isStarted()) {
    try {
      OptimizingTask task = pollTask();             // ① 拉活（阻塞）
      if (task != null && ackTask(task)) {          // ② 签收
        OptimizingTaskResult result = executeTask(task); // ③ 干活
        completeTask(result);                       // ④ 交差
      }
    } catch (Throwable t) {
      LOG.error("unexpected error", t);             // 任何异常吞掉继续
    }
  }
}
```

**这 12 行代码，就是 Optimizer 进程的全部人生**。每个线程独立跑这个循环。

#### 关键方法一：pollTask（拉活）

```java
private OptimizingTask pollTask() {
  while (isStarted()) {
    task = callAuthenticatedAms((client, token) -> client.pollTask(token, threadId));
    if (task != null) break;
    else waitAShortTime();   // 没活就短睡再试（避免空转）
  }
  return task;
}
```

**callAuthenticatedAms** = 自动管 token 的 Thrift RPC 调用。如果 token 过期会自动 re-authenticate。

#### 关键方法二：executeTask（真正干活）

```java
public static OptimizingTaskResult executeTask(OptimizerConfig config, int threadId, 
                                                OptimizingTask task, Logger logger) {
  // 1) 反序列化输入
  OptimizingInput input = SerializationUtil.simpleDeserialize(task.getTaskInput());
  
  // 2) 动态加载执行工厂（SPI 模式）
  String executorFactoryImpl = properties.getExecutorFactoryImpl();
  OptimizingExecutorFactory factory = DynConstructors.builder(...)
      .impl(executorFactoryImpl).buildChecked().newInstance();
  factory.initialize(properties);
  
  // 3) 创建 Executor 并执行
  OptimizingExecutor executor = factory.createExecutor(input);
  OptimizingOutput output = executor.execute();         // ★ 真正的 Iceberg RewriteFiles
  
  // 4) 序列化输出
  ByteBuffer outputByteBuffer = SerializationUtil.simpleSerialize(output);
  result.setTaskOutput(outputByteBuffer);
  return result;
}
```

**🔑 教学关键点**：

1. **SPI 动态加载**：`executorFactoryImpl` 是类名字符串，用 `DynConstructors` 反射构造——这让 Optimizer 支持不同引擎的执行器，**无需改代码换实现**。
2. **输入输出都是序列化后的 `ByteBuffer`**——跨 Thrift 传输只传 byte[]，两端各自序列化/反序列化。
3. **异常不传播**：catch 所有 `Throwable`，错误信息截断到 4000 字符放进 `errorMessage`，保证 Optimizer 不会因为单 task 异常而退出进程。

---

### L2 · AMS 侧的 TaskRuntime 状态机（Day3 铺好的地基）

**完整状态转换图**（带触发者 + 代码行号）：

```
                   pollTask              ackTask           completeTask(success)
                   (AMS侧)              (Optimizer)       (Optimizer)
  ┌──────────┐   schedule()    ┌───────────┐   ack()    ┌──────────┐   complete()  ┌──────────┐
  │ PLANNED  │ ──────────────→ │ SCHEDULED │ ─────────→ │  ACKED   │ ───────────→ │ SUCCESS  │
  └────┬─────┘   (L127)       └─────┬─────┘   (L139)   └────┬─────┘   (L92)      └──────────┘
       │                             │                        │                         
       │                             │ reset()(L111)          │ complete(fail)(L89)     
       │                             ▼                        ▼                         
       │                        ┌──────────┐           ┌──────────┐                    
       │ ←─────── reset() ─── │ PLANNED  │ ←──────── │  FAILED  │  ← FAILED→PLANNED 可重试
       │                        └──────────┘           └──────────┘                    
       │                                                                               
       │ tryCanceling()(L147)                                                          
       ▼                                                                               
  ┌──────────┐                                                                         
  │ CANCELED │  ← 任何非终态都可以尝试 cancel                                              
  └──────────┘                                                                         
```

**`accept()` vs `tryAccepting()` 的精妙区别**：

```java
// accept: 非法转换直接抛异常（硬校验）
public void accept(Status target) {
  if (!getNext().contains(target)) {
    throw new IllegalTaskStateException(taskId, status.name(), target.name());
  }
  status = target;
}

// tryAccepting: 非法转换返回 false（软尝试）
public synchronized boolean tryAccepting(Status target) {
  if (!getNext().contains(target)) {
    return false;
  }
  status = target;
  return true;
}
```

**为什么需要两种？** —— `tryCanceling` 用的是 `tryAccepting`，因为 cancel 可能在**任何时刻**被调用（比如用户手动取消整个 Process），此时 task 可能已经 SUCCESS 了——不应该抛异常，静默跳过即可。而 `schedule/ack/complete` 走 `accept`，因为它们有严格的前置条件——如果状态不对就是 bug。

---

### L2 · Commit 阶段：Iceberg Transaction 的两步提交

**文件**：`UnKeyedTableCommit.commit()` (L188-241)

```java
public void commit() throws OptimizingCommitException {
  // 1) 如果是 Hive 表，先把文件搬到 Hive 位置
  List<DataFile> hiveNewDataFiles = moveFile2HiveIfNeed();
  
  // 2) 收集所有 task 的输入输出 → 4 个 Set
  Set<DataFile> addedDataFiles = ...;        // 新写的数据文件
  Set<DataFile> removedDataFiles = ...;      // 要删的旧数据文件
  Set<DeleteFile> addedDeleteFiles = ...;    // 新写的 delete 文件
  Set<DeleteFile> removedDeleteFiles = ...;  // 要删的旧 delete 文件
  
  // 3) ★ 开 Iceberg Transaction
  Transaction transaction = table.asUnkeyedTable().newTransaction();
  
  if (removedDeleteFiles.isEmpty() && !addedDeleteFiles.isEmpty()) {
    // ★ 特殊情况：没有旧 delete 要删，只有新 delete 要加
    // Iceberg 的 RewriteFiles 校验会抛 "Delete files to add must be empty"
    // 所以拆成两步：先 rewrite data，再 addDelete
    rewriteDataFiles(transaction, removedDataFiles, addedDataFiles);
    addDeleteFiles(transaction, addedDeleteFiles);
  } else {
    // 正常情况：一把 rewrite
    rewriteFiles(transaction, removedDataFiles, addedDataFiles, 
                              removedDeleteFiles, addedDeleteFiles);
  }
  
  transaction.commitTransaction();   // ★ 原子提交
}
```

**🔑 教学关键点（3 个必记）**：

#### 必记 1：为什么要用 Transaction？

Iceberg 的 `newTransaction()` 可以**在一个原子操作内做多件事**。如果不用 Transaction，rewrite + addDelete 会产生**两个 snapshot**，而 Transaction 只产生一个——**保证一次优化对读者来说是原子可见的**。

#### 必记 2：为什么分两步？

代码注释写得很清楚（L221-226）：Iceberg 内部 `BaseRewriteFiles.validateReplacedAndAddedFiles` 有个校验——"如果没有旧 delete 要删，就不允许加新 delete"。这是 Iceberg 的设计约束。Amoro 通过**拆分为 rewriteData + rowDelta 两步**来绕过。

**这是典型的"上游 API 限制导致下游绕路"的工程实践**。

#### 必记 3：commit 失败怎么办？

```java
catch (Exception e) {
  if (needMoveFile2Hive()) {
    correctHiveData(addedDataFiles, addedDeleteFiles);  // ★ 清理已搬移的 Hive 文件
  }
  throw new OptimizingCommitException("unexpected commit error", e);
}
```

**失败补偿**：如果是 Hive 表，commit 失败时已经把文件搬到 Hive 目录了，必须**手动删掉这些"孤儿文件"**。否则下次 Hive 查会查到脏数据。

---

### L2 · 完整闭环：从 Day1 到 Day5 的一条线串起来

```
Day1: AMS 启动
   └─ CatalogManager + TableService + OptimizingService

Day2: 表进入 AMS
   └─ exploreTableRuntimes → syncTable → triggerTableAdded
       └─ headHandler.fireTableAdded → SchedulingPolicy.addTable

Day3: Optimizer 来拉活
   └─ pollTask → waitTask → scheduleTableIfNecessary → triggerAsyncPlanning

Day4: Planner 决策
   └─ initEvaluator → scan files → isNecessary? → planTasks → splitTasks
       └─ List<RewriteStageTask> → 推入 tableQueue

Day5: Task 执行 + 提交  ← 今天
   └─ Optimizer.pollTask → ackTask → executeTask（Iceberg RewriteFiles）→ completeTask
       └─ AMS 收到所有 task 成功 → UnKeyedTableCommit.commit
           └─ Transaction → RewriteFiles → commitTransaction
               └─ 新 snapshot 生成 → 表回到 IDLE → 闭环完成 ✅
```

**Day1 → Day5 总计追了 15+ 个源码文件、~5000 行代码**，形成了一条"从 AMS 启动到一次自优化完成"的**完整链路**。

---

## 💡 精妙设计拆解

### 精妙一：`@StateField` 注解标记可持久化字段

`TaskRuntime` 里有 `@StateField` 注解（L46-53）：

```java
@StateField private Status status = Status.PLANNED;
@StateField private int runTimes = 0;
@StateField private long startTime = ...;
@StateField private String token;
```

**这是 Amoro 自定义的"标记哪些字段需要持久化到 DB"的注解**。配合 `StatedPersistentBase`（父类）的 `invokeConsistency`，实现了**"内存改 → 自动写 DB"的一致性语义**。

**类比**：JPA 的 `@Column`、Hibernate 的 `@Transient`。但 Amoro 更轻量——只是一个标记，具体持久化在 `persistTaskRuntime()` 里手动调 MyBatis。

### 精妙二：`costTime` 跨重试累计

```java
// reset() 里的注释：
// The cost time should not be reset since it is the total cost time of all runs.
```

`costTime` 不在 reset 里归零——它记录的是**这个 task 历史上所有执行的累计耗时**。这在 Dashboard 上非常有用：如果一个 task 重试了 3 次 × 每次 5 分钟 = 总 costTime 15 分钟，但 `runTimes = 3`，管理员一看就知道是"反复失败 + 浪费资源"。

### 精妙三：`DynConstructors` SPI 动态加载 ExecutorFactory

```java
DynConstructors.Ctor<OptimizingExecutorFactory> ctor =
    DynConstructors.builder(OptimizingExecutorFactory.class)
        .impl(executorFactoryImpl).buildChecked();
```

**这让 Optimizer 可以在不改代码的情况下切换不同的执行器**——只需在 task 属性里指定不同的工厂类名。典型的**策略模式 + 反射加载**。

---

## 🎓 举一反三

| Amoro 机制 | 同构系统 | 关键词 |
|---|---|---|
| `while(true) { poll→ack→exec→complete }` | Kafka Consumer 主循环 / YARN Container 主循环 | **Worker 主循环** |
| `TaskStatusMachine` 显式 FSM | Kafka `ReplicaState`、Flink `ExecutionState` | **显式状态机** |
| `accept` 硬校验 vs `tryAccepting` 软尝试 | Java `Lock.lock()` vs `tryLock()` | **强弱两套 API** |
| `Transaction.commitTransaction()` 原子批次 | DB 的 BEGIN/COMMIT、Kafka 事务 | **原子批量提交** |
| 拆两步绕 Iceberg 限制 | 任何 API 版本兼容的绕路设计 | **上游限制 → 下游适配** |
| `@StateField` + `invokeConsistency` | JPA `@Column` + `EntityManager.flush()` | **标记式持久化** |
| `DynConstructors` 反射加载工厂 | Hadoop `ReflectionUtils.newInstance` | **SPI + 反射** |
| commit 失败清理 Hive 孤儿文件 | Spark `HadoopFsRelation.deleteStagingDir` | **补偿式回滚** |

---

## 📝 课后习题

### ⭐ 题目 1：默画状态转换图

不看任何资料，画出 TaskRuntime 的 6 态状态转换图（带触发方法名）。

### ⭐⭐ 题目 2：生产排障

现象："某张表的 Optimizing 一直在 COMMITTING 不结束。"

根据 Day5 源码，列出 3 种可能原因 + 查证方法。

<details>
<summary>参考答案</summary>

1. **Iceberg commit 卡住**（对象存储 rename 超时 / 元数据锁竞争）→ 查 AMS 线程栈
2. **Hive `moveFile2HiveIfNeed` 卡住**（HMS 连接超时 / HDFS rename 卡）→ 查 AMS 日志 `moveFile`
3. **AMS commit executor 线程满**（`OptimizingCommitExecutor` 线程数太小）→ 调大 `optimizing.commit.thread.count`
</details>

### ⭐⭐⭐ 题目 3：两步 commit 的精确条件

请翻源码回答：什么条件下 Amoro 会走"两步 commit"？写出完整的布尔表达式。

### ⭐⭐⭐⭐ 题目 4：设计一个重试上限机制

观察 W18（无限重试嫌疑）：请设计一个 `maxRetries` 配置项，当 task 重试超过 N 次自动标记 CANCELED 并告警。

给出：参数名、默认值、改哪些类、改哪些方法、告警方式。

### ⭐⭐⭐⭐⭐ 题目 5：Day1-Day5 全景复盘

写一篇 500 字的**费曼检验文章**：用类比给你妈/非技术朋友讲清楚"Amoro 怎么自动管表"。不能用任何技术术语。

这是 Phase 1 的里程碑交付物。

---

## 🧪 本讲知识晶体

### 核心源码锚点
- `OptimizerExecutor.start` (L48-60) — Optimizer while(true)
- `OptimizerExecutor.executeTask` (L128-173) — SPI 动态加载 + 执行
- `TaskRuntime` 完整 (L40-374) — 6 态状态机 + 持久化 + 配额计算
- `UnKeyedTableCommit.commit` (L188-241) — Iceberg Transaction 两步提交

### 设计意图速记
- **Optimizer = 无脑循环 + AMS = 全部调度** → 关注点分离
- **FSM accept/tryAccepting** → 强弱两套防护
- **Transaction 原子批次** → 对读者不可见中间态
- **失败补偿 correctHiveData** → Hive 特有的脏数据防护

### 段位变化

| 维度 | Day4 末 | **Day5 末** |
|---|---|---|
| Amoro 源码段位 | L2 顶阶 | **L2 毕业**（完整闭环打通） |
| 能画的图 | 决策树 | + **Task 全状态转换 + 完整端到端闭环** |
| L3 坑 | 22 条 | **24 条**（+W23 commit 无超时 / +W24 executeTask 异常截断丢信息）|
| Phase 1 完成度 | 4/15 | **5/15**（到达里程碑"半程"） |

---

## 🔚 Phase 1 半程总结（Day1-Day5）

| Day | 核心主题 | 一句话成果 |
|---|---|---|
| 1 | AMS 启动 12 步 | 脑中有 AMS 的"开机画面" |
| 2 | 表生命周期 + 责任链 | 知道表怎么"进来、被盯、出去" |
| 3 | 自优化 pull 模型 | 理解"滴滴打车"调度全景 |
| 4 | Planner/Evaluator 决策大脑 | 看透"要不要优化"的 5 行代码 |
| 5 | Task 执行 + Iceberg Commit | **完整闭环：从表进来到优化完成** |

**Day5 后你的段位是 L2 毕业**——能画完整架构图、能追完整链路、能定位代码行号。

**Day6-Day15 的重点**：Mixed 格式深挖、Engine 多态、性能建模、费曼检验。

> **信条**：一个完整的闭环，胜过十个半截的理解。Day1-Day5 画出了"AMS 自优化"这一条完整的闭环，这比泛泛看十个模块都有价值。

— eric · Amoro 源码精通 · 第 05 讲
