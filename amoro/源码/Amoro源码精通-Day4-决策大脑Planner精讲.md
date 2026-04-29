# Amoro 源码精通 · Day4 · 《"要不要优化"是怎么算出来的？—— Planner + Evaluator 决策大脑精讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 04 讲  
> 本讲时长：60 分钟阅读 + 90 分钟动手  
> 承接：Day3《自优化调度核心精讲》

---

## 🎯 本讲学完你能干什么

读完这一讲，你将能够：

- ✅ **30 秒讲清楚** Full / Major / Minor 三种优化的本质区别（不再背官方文档）
- ✅ **看懂一段表的"体检报告"**：fragmentFile / segmentFile / equalityDelete / positionDelete 是什么
- ✅ **回答生产问题**："为什么我的表小文件已经一堆了，AMS 还不优化？"
- ✅ **看透一行神级代码**：用一个 19KB 文件的 4 行布尔判断，决定整个 Amoro 的"忙不忙"
- ✅ **理解"权重排序 + 容量上限"**这个调度算法对 OOM 防护的意义
- ✅ **掌握"健康分"（HealthScore）的算法**，能给 Dashboard 上的红绿灯做出解释

---

## 🪜 预备知识

| 点 | 要会什么 |
|---|---|
| Day1-Day3 | 默画 AMS 启动 + 表生命周期 + 自优化 pull 模型 |
| Iceberg 文件类型 | 知道 DataFile / DeleteFile，知道 equality delete vs position delete |
| 文件大小术语 | 知道 fragment（碎片）/ segment（段）的概念区分 |
| 数学基础 | 会读 `cost / weight` 这种"代价函数 + 优先级"算法 |

> **强烈建议**：开讲前去翻一遍 `bigdata-study/iceberg/Iceberg功能地图.md` 看一眼 Iceberg 的文件层次。

---

## 🧠 一句话心智模型

> **Day3 讲的是"派工系统"——AMS 怎么把活儿派给 Optimizer。Day4 讲的是"医院体检中心"——AMS 怎么决定一张表"病不病"、"病到什么程度"、"开什么药方"。**

如果说 Day3 是滴滴打车，那 Day4 就是**医生坐诊**：先看体检报告（Evaluator），再开处方（Planner），处方写明手术内容（RewriteStageTask）。

---

## 🏛️ 从生活类比入手：体检 → 开方 → 手术

```
┌─────────────────────────────────────────────────────────┐
│           Amoro 的"医院"系统                             │
│                                                         │
│   📊 体检中心（Evaluator）                                │
│      ├─ 全身扫描：scan 所有文件 → 计入 partitionPlanMap   │
│      ├─ 分项判断：每个分区是否 isNecessary               │
│      └─ 综合健康分：avgHealthScore                       │
│              │                                          │
│              ▼  isNecessary = true                      │
│   👨‍⚕️ 主治医生（Planner extends Evaluator）              │
│      ├─ 排队优先：weight 高的先治                         │
│      ├─ 一次手术容量：actualInputSize ≤ maxInputSize     │
│      └─ 切分手术单：splitTasks                           │
│              │                                          │
│              ▼                                          │
│   📋 手术处方（RewriteStageTask）                         │
│      ├─ 输入：RewriteFilesInput                          │
│      │       ├─ 要重写的 DataFile                        │
│      │       ├─ 要重写的 DeleteFile                      │
│      │       └─ 只读的 DeleteFile                        │
│      └─ 类型：FULL / MAJOR / MINOR                       │
│              │                                          │
│              ▼                                          │
│   🔪 外科医生（Optimizer）执行手术（Day5+ 深挖）           │
└─────────────────────────────────────────────────────────┘
```

**Full / Major / Minor 的医学比喻**：

| 类型 | 医学比喻 | 触发条件 | 干什么 |
|---|---|---|---|
| **MINOR** | 日常换药 | 小文件多 / 小 delete 多 | 把碎片合成段，但不重写大文件 |
| **MAJOR** | 局部手术 | 段文件够多 / 段文件偏小 | 重写多个 segment 文件 |
| **FULL** | 全身大手术 | 到达全量优化间隔时间 | 重写整个分区，包括所有 delete |

---

## 🔍 源码逐层剥离

### L1 · 接口层：Day4 的 6 个核心抽象

```
┌─────────────────────────────────────────────────────────┐
│ 1. PartitionEvaluator (interface)                        │
│    "单个分区的体检员"— 决定一个分区要不要优化              │
│    - addFile(dataFile, deletes)                         │
│    - isNecessary()                                      │
│    - getCost() / getWeight()                            │
│    - getOptimizingType() → MINOR/MAJOR/FULL             │
│    - getHealthScore()                                   │
├─────────────────────────────────────────────────────────┤
│ 2. CommonPartitionEvaluator (class, ~600 行)             │
│    "通用的体检员"— 实际的判断逻辑全在这里                  │
│    - isFullNecessary / isMajorNecessary / isMinorNecessary
│    - 文件分类：fragment / segment / equalityDelete / posDelete│
│    - reachFullInterval / reachMinorInterval             │
├─────────────────────────────────────────────────────────┤
│ 3. AbstractOptimizingEvaluator (class)                   │
│    "全表体检员"— 把多个分区的 PartitionEvaluator 汇总     │
│    - initEvaluator()        全表扫描入口                  │
│    - needOptimizingPlanMap  需要优化的分区列表             │
│    - PendingInput           表级体检报告                  │
├─────────────────────────────────────────────────────────┤
│ 4. AbstractOptimizingPlanner (class extends Evaluator)   │
│    "主治医生" — 体检后的"开方"逻辑                         │
│    - planTasks()            ★ 决策核心                   │
│    - 限流：maxInputSize 控制 OOM                         │
│    - 排序：weight 高优先（防饿死）                          │
├─────────────────────────────────────────────────────────┤
│ 5. RewriteFilesInput / RewriteFilesOutput                │
│    "手术处方/手术报告"                                     │
│    - rewrittenDataFiles      要重写的数据文件              │
│    - rePosDeletedDataFiles   只重新生成 posDelete 的文件   │
│    - readOnlyDeleteFiles     只读的 delete 文件            │
│    - rewrittenDeleteFiles    要重写的 delete 文件          │
├─────────────────────────────────────────────────────────┤
│ 6. RewriteStageTask                                      │
│    "完整的手术单"— 串联 Input + 执行 + Output              │
│    - calculateSummary()  汇总指标                        │
└─────────────────────────────────────────────────────────┘
```

---

### L2 · 主链路一：Evaluator 的全表扫描（体检流程）

**入口**：`AbstractOptimizingEvaluator.initEvaluator()` (L86-111)

```java
protected void initEvaluator() {
  long startTime = System.currentTimeMillis();
  TableFileScanHelper tableFileScanHelper;
  
  // ★ 三种文件扫描器，按表类型选
  if (TableFormat.ICEBERG.equals(mixedTable.format())) {
    tableFileScanHelper = new IcebergTableFileScanHelper(...);
  } else {
    if (mixedTable.isUnkeyedTable()) {
      tableFileScanHelper = new UnkeyedTableFileScanHelper(...);
    } else {
      tableFileScanHelper = new KeyedTableFileScanHelper(...);   // ★ Mixed 专用
    }
  }
  
  tableFileScanHelper.withPartitionFilter(getPartitionFilter()); // 分区过滤
  initPartitionPlans(tableFileScanHelper);                       // 真正扫描
  isInitialized = true;
}
```

**核心方法 `initPartitionPlans()`** (L118-147)：

```java
private void initPartitionPlans(TableFileScanHelper tableFileScanHelper) {
  long count = 0;
  try (CloseableIterable<FileScanResult> results = tableFileScanHelper.scan()) {
    for (FileScanResult fileScanResult : results) {
      // ★ 每个文件：找/建对应分区的 Evaluator，把文件喂进去
      String partitionPath = ...;
      PartitionEvaluator evaluator =
          partitionPlanMap.computeIfAbsent(
              partitionPath,
              ignore -> buildEvaluator(...));
      evaluator.addFile(fileScanResult.file(), fileScanResult.deleteFiles());
      count++;
    }
  }
  
  // ★ 过滤出真正"需要优化"的分区（带上限保护）
  needOptimizingPlanMap.putAll(
      partitionPlanMap.entrySet().stream()
          .filter(entry -> entry.getValue().isNecessary())
          .limit(maxPendingPartitions)                            // ★ 防爆
          .collect(Collectors.toMap(Map.Entry::getKey, Map.Entry::getValue)));
}
```

**🔑 教学关键点**：

1. **流式扫描**：`CloseableIterable` + try-with-resources。**几百万文件也不会 OOM**——边扫边塞进 evaluator，不一次性加载到内存。
2. **per-partition 累积**：每个文件根据 `partitionPath` 路由到对应分区的 Evaluator，**O(1) 路由 + O(N) 文件**。
3. **`maxPendingPartitions` 是性命攸关的限流**：哪怕表有 1 万个分区都需要优化，也只取前若干个，**避免一次 plan 出爆炸性的任务量**。

**生活类比**：体检中心来 1 万个病人，先看每个人的报告，能治的排到候诊队列，**但候诊室只有 100 个座位，多了不收**。这就是 `maxPendingPartitions`。

---

### L2 · 主链路二：CommonPartitionEvaluator 的"五大判定函数"（最重要的一节）

**这是 Amoro 整个自优化决策的"大脑神经中枢"**——四五行代码决定整个系统的繁忙程度。

#### 函数 1：`isMinorNecessary()` —— 日常换药要不要做

```java
public boolean isMinorNecessary() {
  int smallFileCount = fragmentFileCount + equalityDeleteFileCount;
  return smallFileCount >= config.getMinorLeastFileCount()      // ★条件 A
      || (smallFileCount > 1 && reachMinorInterval())            // ★条件 B
      || combinePosSegmentFileCount > 0;                          // ★条件 C
}
```

**翻译成大白话**：
- **条件 A**：碎片小文件数 + 等值 delete 文件数 ≥ 配置的"最少触发数"（默认 12）→ 文件太多了必须合
- **条件 B**：有超过 1 个小文件，且距上次 minor 优化已超过间隔时间 → 时间到了顺手合一下
- **条件 C**：有 segment 文件需要合并 posDelete → 主键去重需要

#### 函数 2：`isMajorNecessary()` —— 局部手术要不要做

```java
public boolean isMajorNecessary() {
  return enoughContent()                                          // ★段文件够多
      || rewriteSegmentFileCount > 0;                             // ★或有需要重写的段
}
```

`enoughContent()` 判定（按注释）：
1. 所有 undersized 段文件加起来 > target file size
2. 或有两个 undersized segment 可以合一

#### 函数 3：`isFullNecessary()` —— 全身大手术要不要做

```java
public boolean isFullNecessary() {
  if (!reachFullInterval()) {                                     // ★前置条件
    return false;
  }
  return anyDeleteExist()                                         // 有任何 delete 文件
      || fragmentFileCount >= 2                                   // 碎片文件 ≥ 2
      || undersizedSegmentFileCount >= 2                          // 偏小段文件 ≥ 2
      || rewriteSegmentFileCount > 0
      || rewritePosSegmentFileCount > 0;
}
```

**精妙之处**：FULL 必须满足"**到了 fullTriggerInterval 时间**"。这不是按文件量判断，是**按时间触发**。即便表很干净，到了一定时间也会"全身体检+清理"。

#### 函数 4：`isNecessary()` —— 总开关

```java
public boolean isNecessary() {
  if (necessary == null) {
    if (isFullOptimizing()) {                                     // 时间到 FULL 周期
      necessary = isFullNecessary();
    } else {
      necessary = isMajorNecessary() || isMinorNecessary();       // 否则看 Major/Minor
    }
  }
  return necessary;
}
```

**关键决策逻辑**：

```
                ┌─ isFullOptimizing()? ─┐
                │                       │
            是  │                       │  否
                ▼                       ▼
        isFullNecessary()    isMajorNecessary() || isMinorNecessary()
                │                       │
                ▼                       ▼
      （FULL OR not necessary）    （MAJOR / MINOR / not necessary）
```

#### 函数 5：`getOptimizingType()` —— 究竟开什么手术

```java
return optimizingType =
    isFullNecessary()
        ? OptimizingType.FULL
        : isMajorNecessary() ? OptimizingType.MAJOR : OptimizingType.MINOR;
```

**优先级链**：FULL > MAJOR > MINOR。FULL 满足时直接 FULL，不管 Major/Minor 什么情况。

**🔑 教学关键点（生产问题速查神表）**：

| 现象 | 检查项 |
|---|---|
| 小文件堆积但不优化 | `minor.least.file.count` 是不是设太大？ |
| 一直不做 FULL 优化 | `full.trigger.interval` 是不是 -1？ |
| 一直只做 MINOR 不做 MAJOR | segment 文件还没堆够数量 |
| 文件分类不对 | `fragment-size` 配置是不是设错了？ |

---

### L2 · 主链路三：Planner 的"开方"算法（防饿死 + 防 OOM）

**`AbstractOptimizingPlanner.planTasks()`** (L141-202) 是 Day4 最经典的代码。

```java
public List<RewriteStageTask> planTasks() {
  if (this.tasks != null) return this.tasks;                  // 缓存
  
  if (!isInitialized) initEvaluator();                        // 体检
  
  if (!super.isNecessary()) {                                 // 不需优化早退
    return cacheAndReturnTasks(Collections.emptyList());
  }

  // ★ 步骤 1：把所有需要优化的分区按 weight 倒序排
  LinkedList<PartitionEvaluator> evaluators = new LinkedList<>(needOptimizingPlanMap.values());
  evaluators.sort(Comparator.comparing(PartitionEvaluator::getWeight, Comparator.reverseOrder()));

  // ★ 步骤 2：算容量上限
  double maxInputSize = maxInputSizePerThread * availableCore;
  
  // ★ 步骤 3：从权重高的开始累加，直到容量用满
  actualPartitionPlans = Lists.newArrayList();
  long actualInputSize = 0;
  List<RewriteStageTask> plannedTasks = Lists.newArrayList();

  while (plannedTasks.isEmpty() && !evaluators.isEmpty()) {
    for (PartitionEvaluator evaluator = evaluators.poll();
         evaluator != null;
         evaluator = evaluators.poll()) {
      actualPartitionPlans.add((AbstractPartitionPlan) evaluator);
      actualInputSize += evaluator.getCost();
      if (actualInputSize > maxInputSize) {
        break;                                                // ★ 容量超限就停
      }
    }

    // ★ 步骤 4：按 thread 数切分 task
    double avgThreadCost = actualInputSize / availableCore;
    for (AbstractPartitionPlan partitionPlan : actualPartitionPlans) {
      plannedTasks.addAll(partitionPlan.splitTasks((int) (actualInputSize / avgThreadCost)));
    }
  }

  // ★ 步骤 5：取最严重的 OptimizingType（FULL > MAJOR > MINOR）
  if (!plannedTasks.isEmpty()) {
    if (有任何分区 type=FULL)  optimizingType = FULL;
    else if (有任何 MAJOR)     optimizingType = MAJOR;
    else                       optimizingType = MINOR;
  }
  
  return cacheAndReturnTasks(plannedTasks);
}
```

**🔑 教学关键点（这段代码是 Phase 4 提 PR 的金矿）**：

#### 设计精妙 #1：weight 倒序排序防止"分区饿死"

```java
evaluators.sort(Comparator.comparing(PartitionEvaluator::getWeight, Comparator.reverseOrder()));
```

> "**prioritize partitions with high cost to avoid starvation**" — L155 注释

**为什么 cost 高反而要先做**？因为 cost 高意味着**积累的脏数据多**，再不处理会越积越多——典型的"**用优先级解决饿死问题**"。

**反直觉点**：直觉上你会觉得"先挑简单的做掉"。但调度器告诉你：**先挑最严重的，否则严重的永远轮不到**。

**举一反三**：这就是 OS 的多级反馈队列、K8s 的 PriorityClass、Linux 的 CFS 调度器的同款思想。

#### 设计精妙 #2：`maxInputSize = maxInputSizePerThread × availableCore` 容量公式

```
maxInputSize = (单线程最大输入字节数) × (可用 CPU 核数)
```

这是一个非常工程化的容量评估公式：
- 假设单线程能处理 X 字节
- 有 N 个核可并行
- 则一次优化能 cover X×N 字节

**生产意义**：**这个值就是单次 plan 的"上限"**，超过了就拆下次。这是防止单次 plan 出几百个 task 一次性把 Optimizer JVM 吃爆的关键。

#### 设计精妙 #3：`while (plannedTasks.isEmpty()` 重试循环

```java
while (plannedTasks.isEmpty() && !evaluators.isEmpty()) { ... }
```

**为什么要 while 而不是 if？** 因为可能：
1. 第一轮收集了几个分区，但 `splitTasks` 后是空（没真正可拆出的 task）
2. 此时还有别的 evaluator 没考察过
3. 需要再来一轮

**这是非常隐蔽的兜底设计**——防止"看起来需要优化但实际拆不出活"的尴尬情况。

---

### L2 · 主链路四：RewriteFilesInput 的"四桶模型"（精妙的去重设计）

`RewriteFilesInput` 把要操作的文件分成 4 类：

```
┌─────────────────────────────────────────────────────────────┐
│  rewrittenDataFiles      要被重写（合并）的数据文件             │
│   ┌────────┬────────┬─────┐                                 │
│   │ small  │ small  │ ... │  → 合并成大文件 → 删原文件         │
│   └────────┴────────┴─────┘                                 │
├─────────────────────────────────────────────────────────────┤
│  rePosDeletedDataFiles   只需要重新生成 position delete 的文件 │
│   ┌────────────────────┐                                    │
│   │  big segment file  │  → 不重写本身，只更新它的 posDelete  │
│   └────────────────────┘                                    │
├─────────────────────────────────────────────────────────────┤
│  rewrittenDeleteFiles    要被重写（消化掉）的 delete 文件      │
│   ┌────────┬────────┐                                       │
│   │equality│position│  → 合并到数据里之后，本身被删除          │
│   └────────┴────────┘                                       │
├─────────────────────────────────────────────────────────────┤
│  readOnlyDeleteFiles     只读 delete 文件（不动）              │
│   ┌────────────────────┐                                    │
│   │  big posDelete     │  → 应用到读取时即可，不重写             │
│   └────────────────────┘                                    │
└─────────────────────────────────────────────────────────────┘
```

**🔑 教学关键点**：

- **`rewrittenDataFiles`**（被重写）：完全消失，被合并后的新文件取代
- **`rePosDeletedDataFiles`**（只重新生成 posDelete）：保留文件本身，只更新关联的 posDelete
- **`rewrittenDeleteFiles`**（被消化）：合并完成后被删
- **`readOnlyDeleteFiles`**（只读）：作为"上下文"参与读，自身不变

**为什么要这么细分？** 因为 Iceberg 的 delete 文件有两种语义：
- **equality delete**：按列值删（`WHERE id = 5`），适合频繁删除场景
- **position delete**：按行号删（`row 12345 in file X`），适合精准删除

**Major 优化要做的核心工作就是**：把 small data files 合并的同时，**把 equalityDelete 应用到数据里**，只留 posDelete 给后续读使用。

---

### L3 · 异常/边界预警（Day4 新增 W19-W22，累计 22 条）

| 编号 | 文件 | 行号 | 嫌疑 | 类比 |
|---|---|---|---|---|
| **W19** | `AbstractOptimizingEvaluator.initPartitionPlans` | L121 try-with-resources | scan 流式跑大表，**单个文件 IO 异常会中断整个 plan**——一颗坏苹果毁一筐 | 体检某项设备故障，整个体检中止 |
| **W20** | `AbstractOptimizingEvaluator` | L145 `.limit(maxPendingPartitions)` | 用 stream 的 `.limit` 截断会**随机丢分区**（因 partitionPlanMap 是 HashMap）；高优分区可能被截掉 | 排在后面的 VIP 病人没排上 |
| **W21** | `AbstractOptimizingPlanner.planTasks` | L163 while 循环 + L170 break | 容量超限 break 后剩下的 evaluator 永远没人理，下轮 explore 才会再做；**长 backlog 表会持续被晚做** | 等待长队的病人持续被新急诊病人插队 |
| **W22** | `CommonPartitionEvaluator.isFullNecessary` | L373 `if (!reachFullInterval()) return false;` | full.trigger.interval 设为 -1 (禁用) 时，**永远不做全量优化**；老 delete 文件永久存在；表会越来越慢 | 一辈子不做大体检的人 |

累计 L3 坑：**22 条**（W1-W22）。

---

## 💡 精妙设计拆解

### 精妙一：`AbstractOptimizingPlanner extends AbstractOptimizingEvaluator`

**Planner is-a Evaluator**——这是非常优雅的继承关系。

**含义**：Planner **本质上就是 Evaluator + 切 task 的能力**。
- Evaluator：能判断"要不要优化"
- Planner：在能判断的基础上，**还能算出"具体怎么优化"**

```
Evaluator  →  isNecessary() / getCost() / getWeight()
   ↓ extends
Planner    →  + planTasks() / getOptimizingType()  /  getProcessId()
```

**对照**：`Evaluator` 是诊断医生，`Planner` 是诊断 + 手术医生。手术医生当然能诊断，但诊断医生不一定能手术。

### 精妙二：`isNecessary` 在 Planner 里被 override 增强

```java
// Evaluator 父类
public boolean isNecessary() {
  return !needOptimizingPlanMap.isEmpty();
}

// Planner 子类
@Override
public boolean isNecessary() {
  if (!super.isNecessary()) return false;        // ① 父类先判断
  return !planTasks().isEmpty();                  // ② 真正生成 task 看有没有
}
```

**为什么要双重判定**？因为：
1. 父类只看"分区维度"——有需要优化的分区
2. 子类还要看"任务维度"——能不能真切出可执行的 task

**最常见的反例**：分区有 1 个超大文件需要 FULL，但 `splitTasks` 切不出（因为 maxInputSize 不够）——分区维度 isNecessary=true，任务维度却生不出 task。

### 精妙三：`HealthScore` 的设计意图

```java
private int avgHealthScore(double totalHealthScore, int partitionCount) {
  if (partitionCount == 0) return 100;                      // 没分区就是满分
  return (int) Math.ceil(totalHealthScore / partitionCount); // 各分区平均
}
```

**0-100 分制 + 向上取整**：这是**为 Dashboard UI 设计的指标**，不是为内部决策。

**举一反三**：所有"对外展示的健康度"都该是 0-100 分制（人类直觉好理解），而**内部判定**用 boolean / cost / weight（程序友好）。**两种维度分离**是 Amoro 的小聪明。

---

## 🎓 举一反三：同构系统清单

| Amoro 机制 | 同构系统 | 关键词 |
|---|---|---|
| weight 高的先做防饿死 | OS Multi-Level Feedback Queue / K8s PriorityClass | **优先级倒序调度** |
| `maxInputSizePerThread × availableCore` 容量公式 | Spark `spark.sql.adaptive.advisoryPartitionSizeInBytes` | **资源 × 并发 = 容量** |
| `Evaluator → Planner` 继承关系 | TensorFlow `Estimator → Trainer`、Calcite `Validator → Planner` | **诊断医生 → 手术医生** |
| Full/Major/Minor 三级优化 | HBase Compaction Minor/Major、RocksDB L0~Ln Compaction | **不同强度的合并** |
| `fragment / segment / delete` 文件分类 | LSM-Tree memtable / SSTable / tombstone | **分层存储分类管理** |
| `readOnly / rewritten / rePosDeleted` 四桶模型 | Iceberg row-level delete 处理本身 | **delete 处理三态** |
| `partitionPlanMap` ConcurrentHashMap 累积 | MapReduce Combiner 的"局部聚合" | **per-key 累积器** |
| `maxPendingPartitions` 截断保护 | YARN 的 `maxApplicationsPerUser` | **业务层限流** |
| `HealthScore` 0-100 对外 / boolean 对内 | DBA Health Check（如 SQL Server health score） | **对外得分 vs 对内决策** |

---

## 📝 课后习题

### ⭐ 题目 1：30 秒答出三种类型差异

**用一句话** 说出 MINOR / MAJOR / FULL 的本质区别。讲不清回到 §"五大判定函数"重看。

<details>
<summary>参考答案</summary>

- **MINOR**：合碎片小文件 + 合 equalityDelete，**不动 segment 大文件**
- **MAJOR**：在 MINOR 基础上 **重写 segment 大文件**（合并/重排）
- **FULL**：按时间触发的全分区重写，**消化所有 delete**，回到最干净的状态
</details>

### ⭐⭐ 题目 2：生产问题排查（推荐做）

运维小李反馈："我新建了一张 Iceberg 表写了 1 万个小文件，等了 1 小时 AMS 完全没动。"

**结合 Day4 源码列出 5 个排查项**：

<details>
<summary>参考答案</summary>

1. 表是不是 Mixed 子表？`triggerTableAdded`（Day2 W）会跳过它
2. 表的 `optimizing.enabled` 是不是 false？
3. `minor.least.file.count` 是不是设得过高（默认 12）？
4. 表所属 OptimizerGroup 有 Optimizer 吗？没司机派单也没用（Day3）
5. 表的 OptimizingStatus 是不是卡在 PENDING 但 planningTables 满了？（Day3）
</details>

### ⭐⭐⭐ 题目 3：调优计算题

某 OptimizerGroup 配置：
- 4 个 Optimizer，每个 4 GB 内存 / 2 核
- `maxInputSizePerThread` = 1 GB

请计算：
1. 一次 plan 的容量上限是多少？
2. 如果一张表有 50 GB 数据要优化，要分几轮 plan？
3. 如果把 thread 加到 4，容量变多少？risks 是什么？

### ⭐⭐⭐⭐ 题目 4：写一段代码模拟

请写一个 Python 小脚本（或 Java），输入：

```yaml
fragmentSize: 16MB
segmentSize: 128MB  
files:
  - {size: 5MB,  type: data}
  - {size: 200MB, type: data}
  - {size: 50MB,  type: data}
  - {size: 1MB,  type: equalityDelete}
  ...
```

输出该分区的 `isMinorNecessary / isMajorNecessary / isFullNecessary` 判定结果。

**这是 Phase 2 复盘"决策函数"必做的题**。

### ⭐⭐⭐⭐⭐ 题目 5：设计 PR（挑战）

观察 W20——`stream.limit(maxPendingPartitions)` 是个隐患（HashMap 顺序不稳定）。

请：
1. 写一个 demo 复现"高优分区被截掉"的场景
2. 给出 fix（提示：先 sort 再 limit）
3. 写 PR description 草稿

**这是个真正的 GoodFirstIssue 候选**。

---

## 🧪 本讲知识晶体

### 问题/场景
理解 Amoro 决定"优化什么、怎么优化、用多少资源"的全部逻辑。掌握 5 个判定函数 = 掌握 Amoro 自优化的"灵魂"。

### 核心源码锚点
- `AbstractOptimizingEvaluator.initEvaluator` (L86-111) — 全表扫描入口
- `AbstractOptimizingEvaluator.initPartitionPlans` (L118-147) — 分区累积
- `CommonPartitionEvaluator.isMinorNecessary` (L356-361) — 日常换药
- `CommonPartitionEvaluator.isMajorNecessary` (L352-354) — 局部手术
- `CommonPartitionEvaluator.isFullNecessary` (L372-381) — 全身大手术
- `CommonPartitionEvaluator.getOptimizingType` (L320+) — 最终选型
- `AbstractOptimizingPlanner.planTasks` (L141-202) — 开方核心
- `RewriteFilesInput`（L35-166） — 四桶模型
- `RewriteStageTask`（L32-106） — 手术单

### 五大判定函数速查

```
isFullOptimizing? ─┬─ true  → isFullNecessary()
                   │           ├ reachFullInterval && (anyDelete||frag≥2||undersizedSeg≥2||rewriteSeg>0)
                   │           
                   └─ false → isMajorNecessary || isMinorNecessary
                              ├ Major: enoughContent || rewriteSegmentFileCount>0
                              └ Minor: smallFileCount≥leastFileCount
                                       || (smallFile>1 && reachInterval)
                                       || combinePosSeg>0
```

### 关键参数速查（生产调参必备）

| 参数 key | 作用 | 错配后果 |
|---|---|---|
| `optimizing.minor.least.file.count` | Minor 触发的最少文件数 | 太大 → 小文件堆积；太小 → 频繁优化耗资源 |
| `optimizing.minor.least.interval` | Minor 时间触发间隔 | -1 = 禁用 |
| `optimizing.full.trigger.interval` | Full 触发周期 | -1 = 禁用 FULL，老 delete 永久存在（W22）|
| `optimizing.fragment-size` | fragment 切分阈值 | 太大→小文件不被识别；太小→无意义合并 |
| `optimizing.target-size` | 优化后目标文件大小 | 太大→单文件慢；太小→carbon footprint |
| `optimizing.max.pending.partitions` | 单次 plan 最多分区数 | 太大→OOM；太小→大表收敛慢（W20）|
| `self-optimizing.execute.max-input-size-per-thread` | 单线程最大输入 | OOM 防护核心 |

### 设计意图速记
- **Evaluator → Planner 是 is-a 关系**：诊断医生 + 手术医生
- **weight 倒序**：cost 大的优先（防饿死）
- **maxInputSize 容量公式**：(单线程上限 × 核数) = 单次 plan 上限
- **Full > Major > Minor 优先级**：最严重的优先选型
- **四桶文件模型**：rewritten/rePosDel/readOnly/rewrittenDelete 精准对应 Iceberg 语义
- **HealthScore 0-100 对外**：UI 友好；boolean/cost 对内
- **流式扫描**：CloseableIterable 防 OOM
- **maxPendingPartitions 截断**：业务层限流第一道

### 踩坑登记（Day4 新增 W19-W22，累计 22 条）

---

## 🔚 本讲收尾

### 今天我学会了

- [x] Full / Major / Minor 三级优化的本质区别
- [x] `CommonPartitionEvaluator` 的五大判定函数（核心）
- [x] `Planner.planTasks` 的容量限流 + 优先级排序算法
- [x] `RewriteFilesInput` 的四桶模型与 Iceberg delete 语义
- [x] `Evaluator → Planner` 继承关系的设计意图
- [x] `HealthScore` 对外 vs `cost/weight` 对内的双层指标设计

### 段位变化

| 维度 | Day3 末 | **Day4 末** |
|---|---|---|
| Amoro 源码段位 | L2 中阶 | **L2 顶阶**（决策大脑全打通）|
| 能画的图 | + 双状态机 + pull 模型 | + **决策树 + 四桶文件模型** |
| 能答的问题 | + 自优化任务流 + 心跳 | + **任意分区"要不要优化、为什么"** |
| L3 坑登记 | 18 条 | **22 条** |

### 下次开工（Day5 任务清单）

**Day5 主题**：《优化任务怎么真正干起来？—— TaskRuntime 状态机 + Optimizer Executor 精讲》

1. 🔍 读 `TaskRuntime` 完整文件（含 statusMachine 实现）
2. 🔍 读 `OptimizingProcess` 单表的一次完整优化生命周期
3. 🔍 读 `amoro-optimizer-common` 的 `OptimizerExecutor`
4. 🔍 读 `IcebergRewriteExecutor` 真正干活的实现
5. 🔍 读 `KeyedTableCommit` / `UnKeyedTableCommit` 提交逻辑
6. ✍️ 按八段式写 Day5 笔记

---

> **信条**：好的代码是"设计意图清晰可读"，最好的代码是"读完能让你做更好的设计"。Day4 的 5 个判定函数就是这种好代码。

— eric · Amoro 源码精通 · 第 04 讲
