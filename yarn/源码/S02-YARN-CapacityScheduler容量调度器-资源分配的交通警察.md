# 教案 S02：YARN CapacityScheduler 容量调度器 — 资源分配的交通警察

> **适用对象**：大数据运维/平台工程师 | **前置知识**：了解 YARN 基础架构  
> **课时**：50 分钟 | **难度**：⭐⭐⭐⭐

---

## 一、课前导入 — 两个团队抢资源的故事

> 你管理着一个 200 节点的 YARN 集群。数据团队和算法团队共用这个集群。某天算法团队提交了一个超大的训练任务，瞬间把集群资源吃光了。数据团队的所有 ETL 作业排队等待，老板的报表出不来。
>
> 你需要一个"交通警察"来管理集群的交通——这就是**调度器**的角色。而 CapacityScheduler 是生产环境用得最多的调度器。

---

## 二、本课目标

1. **CapacityScheduler 的队列模型是什么？** 容量、最大容量、弹性如何配置？
2. **一个 Container 请求从提交到分配，经历了哪些步骤？**
3. **什么是 Preemption（抢占）？** 什么条件下触发？代价是什么？

---

## 三、核心概念 — 高速公路收费站的比喻

把 YARN 集群想象成一条多车道高速公路：

```
集群总资源 = 高速公路总车道数（200 车道）
                ┌──────────────────────────┐
                │        root              │  (100% 容量)
                ├──────────┬───────────────┤
                │  data    │   algo        │
                │  (60%)   │   (40%)       │  ← 保证容量
                │  [80%]   │   [70%]       │  ← 最大弹性容量
                ├────┬─────┤               │
                │etl │ adhoc│               │
                │40% │ 20%  │               │
                └────┴─────┴───────────────┘
```

- **capacity = 60%** → 数据团队**保证**能用 60% 的车道
- **maximum-capacity = 80%** → 如果算法团队没用完，数据团队**最多**能弹性扩展到 80%
- **Preemption** → 如果数据团队占了 80% 但算法团队来了任务，系统会**强制回收**多出的 20%

---

## 四、源码精讲

### 4.1 CapacityScheduler 核心类

> 源码：`hadoop-yarn-server-resourcemanager/.../scheduler/capacity/CapacityScheduler.java` (82KB)

```java
// CapacityScheduler 继承了 AbstractYarnScheduler
// 它是 RM 中最核心的资源分配决策者

public class CapacityScheduler extends AbstractYarnScheduler<...> {
    // 核心字段
    private CSQueue root;                    // 队列树的根节点
    private int numNodeManagers;             // 集群中 NM 数量
    private ResourceCalculator calculator;   // 资源计算器（Default vs Dominant）

    // 核心方法：NM 心跳时触发资源分配
    private CSAssignment allocateContainersToNode(SchedulerNode node) {
        // 从 root 队列开始，递归地找到最应该被分配资源的子队列
        // 然后在该队列中找到最应该得到资源的应用
        // 最后为该应用分配一个 Container
    }
}
```

### 4.2 LeafQueue — 叶子队列（实际干活的地方）

> 源码：`...scheduler/capacity/LeafQueue.java` (85KB)

```java
// LeafQueue 是用户实际提交任务的队列
// 所有资源分配的真正决策在这里发生

public class LeafQueue extends AbstractCSQueue {
    // 队列中的应用列表（按优先级+提交时间排序）
    private OrderingPolicy<FiCaSchedulerApp> orderingPolicy;
    // 活跃用户管理器
    private ActiveUsersManager activeUsersManager;
    // 资源使用统计
    private ResourceUsage queueUsage;

    // 核心方法：为一个 NM 节点分配 Container
    public CSAssignment assignContainers(Resource clusterResource,
                                          SchedulerNode node) {
        // Step 1: 检查队列是否超过最大容量
        if (queueUsage.getUsed() >= maxCapacity) return SKIP;

        // Step 2: 选择最应该得到资源的应用（按 FIFO/Fair/DRF 策略）
        FiCaSchedulerApp app = orderingPolicy.getAssignmentIterator().next();

        // Step 3: 为该应用分配一个 Container
        return app.assignContainer(node, request);
    }
}
```

### 4.3 ResourceCalculator — 资源怎么比大小？

> 源码：`hadoop-yarn-common/.../resource/ResourceCalculator.java`

```java
// 这是一个看似简单却影响深远的抽象类
// 它决定了"谁更需要资源"这个核心问题的答案

public abstract class ResourceCalculator {
    // 核心方法：比较两个资源请求的大小
    public abstract int compare(Resource clusterResource,
                                 Resource lhs, Resource rhs);
}
```

**两种实现的差异**：

| | DefaultResourceCalculator | DominantResourceCalculator |
|--|--|--|
| **比较维度** | 只看内存 | 看所有维度（CPU + 内存）的最大份额 |
| **公平性** | CPU 密集型任务吃亏 | 更公平（DRF 算法） |
| **配置** | `DefaultResourceCalculator` | `DominantResourceCalculator` |
| **生产建议** | **不推荐** | **强烈推荐** |

**举一反三**：如果你发现某个应用只申请了 1 核 + 100GB 内存，而另一个申请了 100 核 + 1GB 内存，`DefaultResourceCalculator` 会认为后者"用了更少资源"，这显然不合理。

---

## 五、Preemption（抢占）机制

### 什么时候触发抢占？

```
队列 A: capacity=60%, 当前使用 80%（弹性占了 20%）
队列 B: capacity=40%, 当前使用 20%（有 20% 被队列 A 抢走了）

当队列 B 有新任务排队时 → RM 发现队列 B 低于保证容量 → 触发抢占
→ 向队列 A 中"多占"的 Container 发送 Preempt 信号
→ 给队列 A 一个宽限期（默认 15 秒）自己释放
→ 超时未释放 → RM 强制 Kill 那些 Container
```

**抢占的代价**：被 Kill 的 Container 上的任务需要重算，可能导致：
- Spark Stage 重算
- Flink Checkpoint 失败
- Hive 查询超时

---

## 六、课堂练习

### 思考题 1：队列设计

> 你的集群有 3 个团队：数据 ETL（优先级最高，不能延迟）、算法训练（资源消耗大但可以等）、临时查询（小任务但要快速响应）。请设计队列层次结构和容量分配。

<details>
<summary>参考答案</summary>

```xml
root (100%)
├── production (70%, max=100%)   ← 生产环境最高优先级
│   ├── etl (50%, max=80%)       ← ETL 保证充足资源
│   └── adhoc (20%, max=40%)     ← 临时查询快速响应
└── training (30%, max=60%)      ← 算法训练弹性伸缩
```

关键配置：
- `production` 队列开启抢占保护：`disable_preemption=true`
- `training` 队列允许被抢占
- `adhoc` 队列设置较小的 `max-am-resource-percent` 防止一个大 AM 占满

</details>

### 思考题 2：为什么用 Dominant 而不是 Default？

> 用一个具体例子说明 `DefaultResourceCalculator` 在什么场景下会导致不公平。

<details>
<summary>参考答案</summary>

场景：集群有 1000 核 CPU + 4000GB 内存
- App A：每个 Container 要 1 核 + 8GB（内存密集型，如 Spark 内存计算）
- App B：每个 Container 要 4 核 + 1GB（CPU 密集型，如数据压缩）

用 `DefaultResourceCalculator`（只看内存）：
- App A 的 500 个 Container 用了 4000GB 内存 → 内存满了
- App B 只用了 500 核 / 500GB → 看起来"资源用得少"
- 但实际上 CPU 已经被 App B 的 500 个 Container 占了 2000 核

结果：App A 觉得自己用了"更多资源"被限制，但 App B 占着大量 CPU 却不受限 → **不公平**

</details>

### 思考题 3：抢占风暴

> 什么情况下会出现"抢占风暴"——队列之间不断互相抢占导致集群实际利用率反而下降？如何避免？

<details>
<summary>参考答案</summary>

场景：两个队列 capacity 各 50%，max-capacity 各 100%。两个队列都有大量任务排队。
- 队列 A 先把集群占满 → 队列 B 触发抢占 → 杀掉 A 的 Container
- 队列 B 占满 → 队列 A 又触发抢占 → 杀掉 B 的 Container
- 无限循环，大量任务被 Kill 重算

避免方案：
1. **设置合理的 max-capacity**：不要都设 100%，设为 70-80%
2. **开启 `yarn.scheduler.capacity.preemption.natural_termination_factor`**：控制每次最多抢占多少比例
3. **设置抢占冷却时间**：`preemption.monitoring_interval` 和 `preemption.max_ignored_over_capacity`

</details>

---

## 七、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  YARN CapacityScheduler                            │
├──────────────────────────────────────────────────┤
│  核心类: CapacityScheduler (82KB, RM 内)           │
│  队列: CSQueue → ParentQueue / LeafQueue           │
│  分配: NM 心跳触发 → 队列树递归 → 选应用 → 分配    │
├──────────────────────────────────────────────────┤
│  资源模型:                                         │
│  capacity — 保证容量                               │
│  maximum-capacity — 弹性上限                       │
│  user-limit-factor — 单用户最大占比                 │
├──────────────────────────────────────────────────┤
│  ResourceCalculator:                               │
│  Default → 只看内存（不推荐）                       │
│  Dominant → DRF 看所有维度（生产必选）              │
├──────────────────────────────────────────────────┤
│  Preemption: 低于保证容量 → 标记 → 宽限 → 强制Kill │
│  代价: 任务重算 + 可能的级联故障                    │
├──────────────────────────────────────────────────┤
│  同构类比:                                         │
│  队列 ≈ 高速公路车道分配                           │
│  Preemption ≈ 应急车道征用                         │
│  DRF ≈ 多维度资源公平调度（Max-Min Fairness 扩展）  │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Hadoop YARN 源码 txProjects/hadoop/ | 最后更新：2026-04-29*
