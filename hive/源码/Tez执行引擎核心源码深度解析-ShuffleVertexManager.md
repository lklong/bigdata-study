# Hive Tez 执行引擎核心源码深度解析（ShuffleVertexManager + DAG 调度）

> 版本: Tez 0.10.x
> 源码路径: `/Users/kailongliu/bigdata/gitproject/tez`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

Hive on Tez 是国内绝大部分大数据平台的核心执行引擎。理解 Tez 必须搞清楚：
- 为什么 Tez 比 MR 快？关键设计是什么？
- ShuffleVertexManager 的 "auto-parallelism" 是怎么动态决定 reduce task 数量的？
- min-src-fraction / max-src-fraction "slow start" 调度是什么？
- Tez DAG 状态机怎么运转？Vertex 之间的 Edge 怎么定义？

## 二、Tez 核心抽象（与 MR 对比）

| 抽象 | MapReduce | Tez |
|------|-----------|-----|
| 计算单元 | Job (Map + Reduce 固定) | DAG (任意有向无环图) |
| 节点 | MapTask / ReduceTask | Vertex（一组并行 Task）|
| 数据传输 | HDFS 中间文件 | Edge（数据移动协议）|
| 拓扑控制 | 无 | VertexManagerPlugin（动态控制并行度/调度时机）|
| 容器复用 | 无 | Container Reuse |

**Tez 三大杀手锏**：
1. **DAG 而非两阶段** —— Hive 一条 SQL 编译成一个 DAG，一次提交，不用走多个 MR Job 的 HDFS 中间结果落地
2. **VertexManager 动态调度** —— 上游 task 完成后实时决定下游 task 数量和启动时机
3. **Container Reuse** —— 一个 YARN Container 跑多个 Tez Task，免去 fork JVM 的开销

## 三、调用链总图

```
Hive SQL → Tez Compiler → DAG (Vertices + Edges)
                               │
                               ▼
                  TezClient.submitDAG → AppMaster (DAGAppMaster)
                               │
                               ▼
                  DAGImpl 状态机 (NEW → INITED → RUNNING → SUCCEEDED)
                               │
                               ▼
                  for each Vertex:
                      VertexImpl 状态机 (NEW → INITED → RUNNING → SUCCEEDED)
                               │
                               ▼
                  VertexManagerPlugin（用户/Tez 内置）：
                    onVertexStarted        ← Vertex 启动通知
                    onSourceTaskCompleted  ← 上游 task 完成通知
                    onVertexStateUpdated   ← 上游 vertex 状态变化
                               │
                               ▼
                  调用 VertexManagerPluginContext API：
                    scheduleTasks         ← 启动一组 task
                    reconfigureVertex     ← 改变 vertex 并行度（auto parallelism!）
                    setVertexParallelism  ← 设置初始并行度
                               │
                               ▼
                  TaskScheduler 申请 Container → 启动 TezTaskRunner
                               │
                               ▼
                  Task 执行：LogicalIO/LogicalOutput/Processor 三件套
                  （读输入 → 处理 → 写输出，写到 ShuffleHandler/disk）
```

## 四、关键源码逐段精读

### 4.1 ShuffleVertexManager —— Tez 最常用的 VertexManager

`ShuffleVertexManager.java:63-160`：

```java
public class ShuffleVertexManager extends ShuffleVertexManagerBase {

  // ---- 核心配置（Hive 调优最常碰的几个）----

  /** 期望每个 task 的输入数据量，自动并行度的目标 */
  public static final String TEZ_SHUFFLE_VERTEX_MANAGER_DESIRED_TASK_INPUT_SIZE
      = "tez.shuffle-vertex-manager.desired-task-input-size";
  public static final long ..._DEFAULT = 100 * MB;   // 默认 100MB/task

  /** 是否开启自动并行度 */
  public static final String TEZ_SHUFFLE_VERTEX_MANAGER_ENABLE_AUTO_PARALLEL
      = "tez.shuffle-vertex-manager.enable.auto-parallel";
  public static final boolean ..._DEFAULT = false;   // 默认关，Hive 通常会开

  /** 自动并行度最低值 */
  public static final String TEZ_SHUFFLE_VERTEX_MANAGER_MIN_TASK_PARALLELISM
      = "tez.shuffle-vertex-manager.min-task-parallelism";
  public static final int ..._DEFAULT = 1;

  /** Slow Start —— 上游完成多少比例才开始调度下游第一个 task */
  public static final String TEZ_SHUFFLE_VERTEX_MANAGER_MIN_SRC_FRACTION
      = "tez.shuffle-vertex-manager.min-src-fraction";
  public static final float ..._DEFAULT = 0.25f;     // 25%

  /** Slow Start —— 上游完成多少比例可以调度全部下游 task */
  public static final String TEZ_SHUFFLE_VERTEX_MANAGER_MAX_SRC_FRACTION
      = "tez.shuffle-vertex-manager.max-src-fraction";
  public static final float ..._DEFAULT = 0.75f;     // 75%

  // 在 min-fraction 与 max-fraction 之间，下游 task 数量线性增长
}
```

**核心思想（Slow Start）**：

```
上游完成度  →   0%   25%   50%   75%   100%
下游可启动 task →  0   ▏0%   50%   100%  100%
                   ↑     ↑                ↑
                  暂不启动  按比例线性启动   全部就位
```

**为什么这么设计**？
- 上游刚开始时，map output 还少，启动 reducer 没数据可拉，浪费 container slot
- 25% (`min-src-fraction`) 是经验值：足够让 reducer 一启动就有持续数据流入
- 75% (`max-src-fraction`) 之后全部启动：剩余 25% 的 map output 量可承受 reducer 全速拉取

**对应 Hive 调优**：
- 集群繁忙、慢节点多 → 调高 `min-src-fraction`（如 0.5），避免 reducer 早启动等数据
- 数据量小、希望快 → 调低 `min-src-fraction`（如 0.1），让 reducer 早就位

### 4.2 自动并行度（Auto-Parallelism）—— Tez 杀手特性

`ShuffleVertexManager.java:138-160`：

```java
@Override
ShuffleVertexManagerBaseConfig initConfiguration() {
    float slowStartMinFraction = conf.getFloat(
        TEZ_SHUFFLE_VERTEX_MANAGER_MIN_SRC_FRACTION,
        TEZ_SHUFFLE_VERTEX_MANAGER_MIN_SRC_FRACTION_DEFAULT);

    mgrConfig = new ShuffleVertexManagerConfig(
        conf.getBoolean(TEZ_SHUFFLE_VERTEX_MANAGER_ENABLE_AUTO_PARALLEL, false),
        conf.getLong(TEZ_SHUFFLE_VERTEX_MANAGER_DESIRED_TASK_INPUT_SIZE, 100 * MB),
        slowStartMinFraction,
        conf.getFloat(TEZ_SHUFFLE_VERTEX_MANAGER_MAX_SRC_FRACTION,
            Math.max(slowStartMinFraction, 0.75f)),
        Math.max(1, conf.getInt(TEZ_SHUFFLE_VERTEX_MANAGER_MIN_TASK_PARALLELISM, 1)));
    return mgrConfig;
}
```

**Auto-Parallelism 算法**（来自 ShuffleVertexManagerBase 父类逻辑）：
1. 上游每个 task 完成时，通过 `VertexManagerEventPayload` 上报本 task 输出的总字节数
2. VertexManager 累计已知的所有上游 task 输出字节
3. 当上游完成比例达到一定阈值（默认 25%），用累计数据估算总输出：
   ```
   estimatedTotalOutput = currentCumulativeOutput / fractionCompleted
   ```
4. 计算理想 reducer 数：
   ```
   idealReducers = max(minTaskParallelism,
                        ceil(estimatedTotalOutput / desiredTaskInputSize))
   ```
5. 调用 `pluginContext.reconfigureVertex(idealReducers, ...)` 更新 vertex 并行度
6. 同时调用 `setEdgeManager` 重新调整 partition → reducer 映射（`CustomShuffleEdgeManager`，见 4.3）

**实战示例**：
- 上游 100 个 mapper，初始下游 reducer 设置为 200
- 25% mapper 完成时，已生成 5GB shuffle 数据
- 估算总数据：5GB / 0.25 = 20GB
- 期望 task 输入 100MB → 理想 reducer = 20GB / 100MB = 200
- 与初始一致，不调整。如果实际只产生 2GB，则 ideal = 20，并行度被砍到 20。

**对应 Hive 配置**：
```sql
SET tez.shuffle-vertex-manager.enable.auto-parallel=true;
SET tez.shuffle-vertex-manager.desired-task-input-size=134217728;  -- 128MB
SET tez.shuffle-vertex-manager.min-task-parallelism=4;
```

### 4.3 CustomShuffleEdgeManager —— Auto-Parallelism 的连带方案

`ShuffleVertexManager.java:172-192`：

```java
public static class CustomShuffleEdgeManager extends EdgeManagerPluginOnDemand {
    int numSourceTaskOutputs;
    int numDestinationTasks;
    int basePartitionRange;
    int remainderRangeForLastShuffler;
    int numSourceTasks;

    int[][] sourceIndices;
    int[][] targetIndices;

    public CustomShuffleEdgeManager(EdgeManagerPluginContext context) {
        super(context);
    }

    @Override
    public void initialize() {
      UserPayload userPayload = getContext().getUserPayload();
      ...
    }
}
```

**为什么需要重写 EdgeManager**？
- 默认 `ScatterGatherEdgeManager` 是 1:N 映射：mapper task 0 的 partition i 给 reducer i
- Auto-parallelism 把 reducer 从 200 砍到 20 后，原来 reducer 0、10、20 ... 190 的数据都要进入新 reducer 0
- `CustomShuffleEdgeManager` 重写 `getSourceOutputIndices()`，把多个原 partition 路由到一个新 reducer

```java
// 简化逻辑
basePartitionRange = origNumReducers / newNumReducers;  // 200/20 = 10
remainderRangeForLastShuffler = origNumReducers % newNumReducers;  // 0

// reducer i 拉取 mapper 输出的 [i*10, (i+1)*10) 范围 partition
```

### 4.4 VertexManagerPlugin 接口 —— 用户扩展点

`VertexManagerPlugin.java`（API 接口）：

```java
public abstract class VertexManagerPlugin {
    public abstract void initialize();

    /** Vertex 启动时调用 */
    public abstract void onVertexStarted(Map<String, List<Integer>> completions);

    /** 上游某个 source task 完成时调用 */
    public abstract void onSourceTaskCompleted(TaskAttemptIdentifier attempt);

    /** 收到 VertexManagerEvent（用户事件，如 ShuffleVertexManager 用它接收输出大小）*/
    public abstract void onVertexManagerEventReceived(VertexManagerEvent vmEvent);

    /** 上游 vertex 状态变化（如 SUCCEEDED）*/
    public abstract void onVertexStateUpdated(VertexStateUpdate stateUpdate);

    /** Root vertex 接到 RootInput 初始化通知 */
    public abstract void onRootVertexInitialized(String inputName,
                                                  InputDescriptor inputDescriptor,
                                                  List<Event> events);
}
```

**Plugin 通过 `VertexManagerPluginContext` 操作 vertex**：
- `scheduleTasks(List<TaskWithLocationHint>)` —— 启动一组指定的 task（带 locality 提示）
- `reconfigureVertex(int newParallelism, ...)` —— 改变并行度（必须在 vertex 初始化阶段做）
- `getVertexNumTasks(vertexName)` —— 查询 vertex 当前并行度
- `addRootInputEvents(...)` —— 给 input 添加事件（DataSourceVertexManager 用）

### 4.5 DAGImpl —— DAG 状态机（94KB 大文件）

`DAGImpl.java` 是 Tez DAG 调度的核心，也是 Tez AM 中最复杂的状态机。状态转移：

```
NEW
 │ DAG_INIT
 ▼
INITED
 │ DAG_START
 ▼
RUNNING ───────────────► COMMITTING ──────────► SUCCEEDED
 │  │                       │                       
 │  │                       ▼                       
 │  │                    FAILED                     
 │  │                                               
 │  └──────────► TERMINATING ────► KILLED          
 │                                                  
 └──────────────► FAILED                            
```

**关键内部组件**（DAGImpl.java 顶部 import 推断 + 通用 Tez 知识）：
- `Vertex[]` —— DAG 内所有 vertex 的引用
- `EventHandler<DAGEvent>` —— 异步事件分发
- `StateMachine<DAGState, DAGEventType, DAGEvent>` —— Hadoop 风格状态机
- `dagEventDispatcher` —— 给子状态机（VertexImpl）转发事件

**事件流**：
```
某 task 失败 →  TaskAttemptEvent(FAILED)
            ↓
TaskImpl 状态机变更 →  TaskEvent(SUCCEEDED/FAILED)
            ↓
VertexImpl 状态机变更 →  VertexEvent(VERTEX_COMPLETED)
            ↓
DAGImpl 状态机变更 →  DAGEvent(DAG_VERTEX_COMPLETED)
            ↓
DAGImpl 检查所有 vertex 是否完成 → DAG_FINISHED
```

## 五、Edge —— 数据移动协议

Tez 支持三种 Edge：

| Edge 类型 | 数据传递 | 典型场景 |
|---------|---------|---------|
| **One-to-One** | task i → task i | 流水线优化（保留分区性） |
| **Broadcast** | task i → 所有下游 task | Map Join 小表广播 |
| **Scatter-Gather** | 按 partitioner 分散 → reducer 聚合 | 经典 Reduce-side Join、GroupBy |

每个 Edge 包含：
- `EdgeManagerPlugin` —— 决定 partition → task 的映射
- `EdgeProperty` —— 数据移动类型 + 调度依赖（CONCURRENT/SEQUENTIAL）+ DataSource/SinkType

**对应 Hive 操作**：
- `ScatterGather` + `ShuffleVertexManager`：GROUP BY、ORDER BY、Reduce-side Join
- `Broadcast`：Map Join (`hive.auto.convert.join=true`)
- `One-to-One`：连续两个 vertex 不需要 reshuffle 时（Sort Merge Join 优化路径）

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| DAG 而非 Job 链 | 中间结果不落 HDFS，CPU 直传，10x 性能 |
| VertexManagerPlugin 可插拔 | 调度策略由用户决定，框架只提供 hook |
| Slow Start (min/max-src-fraction) | 平衡"reducer 早启动空等"和"reducer 晚启动长尾"两个极端 |
| Auto-Parallelism (动态调整 reducer 数) | 解决数据量预估困难的问题，运行时根据真实 stats 调整 |
| CustomShuffleEdgeManager 配套 | Auto-parallelism 改了 reducer 数后，必须重映射 partition→reducer |
| 三种 Edge 抽象 | 不同物理传输模式（one-to-one/broadcast/scatter-gather）统一在 Edge 抽象下 |
| Container Reuse | JVM 复用，省 fork 开销，特别是大量小 task 时 |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `tez.shuffle-vertex-manager.enable.auto-parallel` | false | 自动并行度总开关（**Hive 一定要开**）|
| `tez.shuffle-vertex-manager.desired-task-input-size` | 100MB | 每 reducer 期望输入量 |
| `tez.shuffle-vertex-manager.min-task-parallelism` | 1 | 最小并行度（防过度收缩）|
| `tez.shuffle-vertex-manager.min-src-fraction` | 0.25 | Slow start 起始 |
| `tez.shuffle-vertex-manager.max-src-fraction` | 0.75 | Slow start 终点 |
| `tez.am.container.reuse.enabled` | true | Container 复用 |
| `tez.am.container.reuse.locality.delay-allocation-millis` | 250 | 等本地化的最长时间 |
| `tez.am.container.idle.release-timeout-min.millis` | 5000 | 空闲容器最短保留时间 |
| `tez.am.container.idle.release-timeout-max.millis` | 10000 | 空闲容器最长保留时间 |
| `tez.runtime.shuffle.fetch.buffer.percent` | 0.9 | reducer 端 shuffle buffer 占内存比例 |
| `tez.runtime.shuffle.parallel.copies` | 20 | reducer 拉取并发度 |
| `tez.runtime.io.sort.mb` | 100 | mapper sort buffer |

## 八、踩坑记录

1. **auto-parallel 开了反而变慢** —— 上游 task 数量过少（<10），slow-start fraction 估算样本不足，估错总量。**应对**：调高 `min-src-fraction` 让更多上游完成才估算，或设 `min-task-parallelism` 防过度收缩。
2. **小数据量下 reducer 数=1** —— `desired-task-input-size=100MB` 太大。**应对**：Hive 单查询 SET `desired-task-input-size=33554432`（32MB）。
3. **倾斜场景 reducer 长尾** —— Tez auto-parallel 只能整体调，不能为倾斜 key 单独切分。**应对**：上层 Hive 用 skew-aware optimization（`hive.optimize.skewjoin=true`）。
4. **Container Reuse 内存泄漏** —— 复用 container 跑了不同的 vertex，前一个 vertex 的 ThreadLocal/Cache 没清。**应对**：明确 `tez.am.container.reuse.enabled=false`（小集群可以关），或定位泄漏对象。
5. **DAG 提交后状态卡 INITED** —— 通常是 RM 没分配 AM container（资源队列饱和）。看 RM web UI 的 ACCEPTED 应用数。
6. **`onSourceTaskCompleted` 事件丢失** —— 上游 vertex 配置了 `tez.task.generate.counters.per.io=false`，VertexManagerEventPayload 里没数据，auto-parallel 估不出。**应对**：始终开 `generate.counters.per.io=true`。

## 九、认知更新

- 之前以为 Tez auto-parallelism 是"启动后再改"，**实际上必须在 INITED 阶段调用 reconfigureVertex**。一旦 vertex 进入 RUNNING 就不能改并行度。
- 之前以为 Slow Start 是"等到 75% 才启动 reducer"，**实际上是 25%~75% 线性增长**：25% 启动 0 个，50% 启动一半，75% 全部启动。
- ShuffleVertexManager 与 CustomShuffleEdgeManager 是绑定的 —— **改 vertex 并行度必须同时改 edge mapping**，否则 reducer 拉错 partition。
- VertexManagerPlugin 的 `onSourceTaskCompleted` 不是同步调用，而是 AM dispatcher 异步分发的事件 —— 写自定义 plugin 时**不能阻塞这个回调**，否则会阻塞整个 AM 事件循环。
- 默认 `enable.auto-parallel=false`，**Hive 团队会在 hive-site.xml 默认开启**，所以用户感觉 Tez 自动并行度是默认的，其实是 Hive 帮开的。

## 十、下一步深挖方向

- [ ] DAGImpl 完整状态机的详细转移（KILLING/RECOVERING 路径）
- [ ] TezTaskRunner 的 LogicalIO/LogicalOutput/Processor 三件套调用约定
- [ ] OrderedPartitionedKVOutput 的 sort + spill + merge 流程（对标 MR 的 MapOutputBuffer）
- [ ] Tez Recovery 机制（AM 重启后从 dag_recovery_data_X.bin 恢复）

---

**沉淀完成。Tez 自动并行度核心算法、Slow Start 调度时机、Edge 重映射机制源码精确对齐。**
