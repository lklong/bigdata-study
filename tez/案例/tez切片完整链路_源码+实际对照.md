# Tez 切片计算完整链路：源码时序 + 实际日志对照

> 对比 application_682541（Map=246）和 application_683560（Map=487）

---

## 一、源码时序 + 两个 App 的实际时间对照

```
源码链路                          682541 实际时间         683560 实际时间
──────────────────────           ──────────────         ──────────────

【阶段1: HS2 端 — 提交 App 到 YARN】

TezClient.submitApplication()
 → YarnClientImpl.submitApplication()
                                  00:20:04               03:51:36
 日志: "Submitted application"
 
 此时 App 进入 RM 队列排队
 等待 RM 分配 AM Container...
                                  等了 ~7 分钟            等了 ~20 分钟
                                  (队列较忙)             (队列更忙)

【阶段2: AM 端 — AM 启动 + 注册】

DAGAppMaster.main()
 → serviceInit() → serviceStart()
 → YarnTaskSchedulerService.start()
   → amRmClient.registerApplicationMaster()
   → RM 返回 RegisterResponse
     (含 maxResourceCapability, queue)
     (不含 headroom)
                                  ~00:26:xx              ~04:11:xx

【阶段3: AM 端 — 第一次心跳 ★★★ totalResources 在此确定 ★★★】

AMRMClientAsync 心跳线程启动(间隔 1s)
 → allocate RPC #1 发给 RM
 → RM 计算 headroom:
     headroom = min(
       userLimit - userUsed,   ← dmp 用户的其他 app 占了多少
       queueCap - queueUsed    ← dw 队列的其他 app 占了多少
     )
 → AllocateResponse 返回:
     availableResources = headroom
     allocatedContainers = []  (还没请求任何 container)

 回调 → getProgress()
   if (totalResources.getMemory() == 0):  ← 第一次，true
     totalResources = getAvailableResources()
     ★ 赋值一次，之后不再更新 ★
```

**源码（YarnTaskSchedulerService.java 第 895-918 行）**：
```java
@Override
public float getProgress() {
    if (totalResources.getMemory() == 0) {
        // assume this is the first allocate callback. nothing is allocated.
        // available resource = totalResource
        // TODO this will not handle dynamic changes in resources
        totalResources = Resources.clone(getAvailableResources());
        LOG.info("App total resource memory: " + totalResources.getMemory()
            + " cpu: " + totalResources.getVirtualCores()
            + " taskAllocations: " + taskAllocations.size());
    }
    // ...
}

// 第 256 行
public Resource getAvailableResources() {
    return amRmClient.getAvailableResources();
    // ← AMRMClient 内部缓存的 RM 最近一次 allocate 响应中的 headroom
}
```

**调用链**：
```
getTotalAvailableResource()                          (InputInitializerContext 接口)
 → TezRootInputInitializerContextImpl.java 第107行
   appContext.getTaskScheduler().getTotalResources()
     → TaskSchedulerManager.java 第247行
       taskSchedulers[schedulerId].getTotalResources()
         → YarnTaskSchedulerService.java 第934行
           return totalResources;               ← 就是上面第一次心跳固定的值
```

```
 日志: "App total resource memory: X cpu: Y taskAllocations: 0"
 日志: "Allocated: <0,0> Free: <X,Y> heartbeats: 1"

                                  totalResources = A     totalResources = B
                                  (A < B)                (B ≈ 2A)
                                  
 ┌─────────────────────────────────────────────────────────────┐
 │ 为什么 B ≈ 2A？                                             │
 │                                                             │
 │ headroom = min(userLimit - userUsed, queueCap - queueUsed) │
 │                                                             │
 │ 00:26 (682541): 凌晨高峰，dmp 用户的其他 app 占用多          │
 │   → userUsed 大 → headroom 小 → totalResources = A         │
 │                                                             │
 │ 04:11 (683560): 凌晨低谷，部分 app 已完成释放资源            │
 │   → userUsed 小 → headroom 大 → totalResources = B ≈ 2A    │
 │                                                             │
 │ 注意：这是 AM 还没请求任何 task container 时的值             │
 │ 所以 headroom = 队列给该用户的"当前剩余可用资源"             │
 └─────────────────────────────────────────────────────────────┘

【阶段4: HS2 端 — 提交 PreWarm DAG】

TezClient.submitDAG(PreWarmDAG)
                                  00:26:54               04:11:46
 日志: "Submitting dag...dagName=TezPreWarmDAG_0"
 
 PreWarm 完成后提交实际查询 DAG...

【阶段5: HS2 端 — 提交实际查询 DAG】

TezClient.submitDAG(实际查询)
                                  00:27:22               04:12:05
 日志: "Submitting dag...dagName=dwd.dwd_nf_iot_report_..."

【阶段6: AM 端 — ★★★ 切片计算（核心）★★★】

DAGImpl.handle(DAG_INIT)
 → VertexImpl.handle(V_INIT)
 → RootInputInitializerManager.runInputInitializers()
 → HiveSplitGenerator.initialize()
```

**源码（HiveSplitGenerator.java 第 186-248 行）**：
```java
// ── 第一层：计算 availableSlots ──
if (getContext() != null) {
    totalResource = getContext().getTotalAvailableResource().getMemory();
    //              ↑ 返回阶段3固定的 totalResources
    taskResource = getContext().getVertexTaskResource().getMemory();
    availableSlots = totalResource / taskResource;
}

// ── preferredSplitSize 计算 ──
if (HiveConf.getLongVar(conf, HiveConf.ConfVars.MAPREDMINSPLITSIZE, 1) <= 1) {
    final long blockSize = conf.getLong(DFSConfigKeys.DFS_BLOCK_SIZE_KEY,
        DFSConfigKeys.DFS_BLOCK_SIZE_DEFAULT);
    final long minGrouping = conf.getLong(
        TezMapReduceSplitsGrouper.TEZ_GROUPING_SPLIT_MIN_SIZE,
        TezMapReduceSplitsGrouper.TEZ_GROUPING_SPLIT_MIN_SIZE_DEFAULT);
    final long preferredSplitSize = Math.min(blockSize / 2, minGrouping);
    HiveConf.setLongVar(jobConf, HiveConf.ConfVars.MAPREDMINSPLITSIZE, preferredSplitSize);
}

// ── 第二层：生成原始 splits ──
float waves = conf.getFloat(TEZ_GROUPING_SPLIT_WAVES, 1.7f);
splits = inputFormat.getSplits(jobConf, (int)(availableSlots * waves));
//                                       ↑ numSplits hint 传给 HiveInputFormat
Arrays.sort(splits, new InputSplitComparator());

// ── 第三层：SplitGrouper 分组 ──
Multimap<Integer, InputSplit> groupedSplits =
    splitGrouper.generateGroupedSplits(jobConf, conf, splits,
        waves, availableSlots, splitLocationProvider);
InputSplit[] flatSplits = groupedSplits.values().toArray(new InputSplit[0]);
```

**SplitGrouper 内部（SplitGrouper.java 第 72-103 行 + 第 203-256 行）**：
```java
// group() 方法
Map<Integer, Integer> bucketTaskMap =
    estimateBucketSizes(availableSlots, waves, bucketSplitMultimap.asMap());

for (int bucketId : bucketSplitMultimap.keySet()) {
    InputSplit[] groupedSplits = tezGrouper.getGroupedSplits(
        conf, rawSplits, bucketTaskMap.get(bucketId),
        HiveInputFormat.class.getName(),
        new ColumnarSplitSizeEstimator(), splitLocationProvider);
}

// estimateBucketSizes() 方法
numEstimatedTasks = (int)(availableSlots * waves * bucketSizeMap.get(bucketId) / totalSize);
// 如果只有1个bucket → desiredNumSplits ≈ (int)(availableSlots * waves)
```

**TezSplitGrouper 边界检查（TezSplitGrouper.java 第 224-274 行）**：
```java
long lengthPerGroup = totalLength / splitCount;

if (lengthPerGroup > maxLengthPerGroup) {
    // 路径A: 被 max-size 兜底
    desiredNumSplits = (int)(totalLength / maxLengthPerGroup) + 1;
} else if (lengthPerGroup < minLengthPerGroup) {
    // 路径B: 被 min-size 兜底
    desiredNumSplits = (int)(totalLength / minLengthPerGroup) + 1;
}

if (desiredNumSplits >= originalSplits.size()) {
    // 路径C: 不分组，直接返回原始 splits
    return wrapSplits(originalSplits);
}
// 路径D: 正常按 location 多轮迭代分组
```

**三层影响对比**：
```
   │                                                        │
   │ totalResource = getContext()                            │
   │   .getTotalAvailableResource().getMemory()              │
   │   → 返回阶段3固定的 totalResources                      │
   │                                                        │
   │ taskResource = getContext()                             │
   │   .getVertexTaskResource().getMemory()                  │
   │   → 返回 Vertex 配置的 task 内存（两次相同）              │
   │                                                        │
   │ availableSlots = totalResource / taskResource           │
   │                                                        │
   │                  682541          683560                 │
   │ totalResource:   A MB            B MB (≈2A)            │
   │ taskResource:    相同             相同                   │
   │ availableSlots:  a               b (≈2a)               │
   └────────────────────────────────────────────────────────┘
   
   ┌─ 第二层：生成原始 splits ──────────────────────────────┐
   │                                                        │
   │ numSplits = (int)(availableSlots * waves)              │
   │           = (int)(a * 1.7)    vs (int)(b * 1.7)        │
   │                                                        │
   │ inputFormat.getSplits(jobConf, numSplits)              │
   │  → HiveInputFormat.getSplits()                         │
   │    → addSplitsForGroup(..., numSplitsForGroup, ...)    │
   │      → 实际InputFormat.getSplits(conf, numSplits)      │
   │        → FileInputFormat:                              │
   │            goalSize = totalSize / numSplits             │
   │            splitSize = max(minSize, min(goalSize, blk)) │
   │                                                        │
   │ numSplits 越大 → goalSize 越小 → splitSize 越小         │
   │ → 原始 splits 越多                                      │
   │                                                        │
   │                  682541          683560                 │
   │ numSplits:       小               大 (≈2倍)             │
   │ goalSize:        大               小                    │
   │ 原始splits:      N 个             M 个 (M > N)          │
   └────────────────────────────────────────────────────────┘
   
   ┌─ 第三层：SplitGrouper 分组 ───────────────────────────┐
   │                                                        │
   │ SplitGrouper.generateGroupedSplits()                   │
   │  → schemaEvolved() 按 schema 边界分桶                   │
   │  → group()                                             │
   │    → estimateBucketSizes(availableSlots, waves, ...)   │
   │      desiredNumSplits = (int)(availableSlots * waves)  │
   │                                                        │
   │    → tezGrouper.getGroupedSplits(desiredNumSplits)     │
   │                                                        │
   │      lengthPerGroup = totalLength / desiredNumSplits   │
   │                                                        │
   │      三种路径:                                          │
   │      A. lengthPerGroup > maxSize → 被max兜底重算        │
   │      B. lengthPerGroup < minSize → 被min兜底重算        │
   │      C. desiredNumSplits >= 原始splits数 → 不分组      │
   │      D. 正常分组                                        │
   │                                                        │
   │                  682541          683560                 │
   │ desiredNumSplits: 小              大                    │
   │ 原始splits数:     N               M                    │
   │ 走哪条路径:       可能A或D         可能C或D              │
   │ 最终Map数:        246             487                   │
   └────────────────────────────────────────────────────────┘

 日志: "Number of input splits: X. N available slots, 1.7 waves"
 日志: "Estimated number of tasks: Y for bucket Z"
 日志: "Original split count is P grouped split count is Q"
 日志: "Number of split groups: K"
 → K 就是最终 Map 数

                                  Map = 246              Map = 487

【阶段7: AM 端 — 开始调度 Container】

VertexImpl.setParallelism(Map数)
 → TaskSchedulerManager 开始请求 Container
 → AMRMClientAsync 心跳中携带 Container 请求
 → RM CapacityScheduler 按调度策略分配

 ┌─────────────────────────────────────────────────────────────┐
 │ 此时 headroom 已经跟阶段3不同了！                             │
 │                                                             │
 │ 因为:                                                       │
 │ 1. PreWarm DAG 已经分配了一些 container → userUsed 增加      │
 │ 2. 其他 app 也在同时请求 → queueUsed 变化                    │
 │ 3. 但 totalResources 不再更新（只在阶段3赋值一次）            │
 │                                                             │
 │ 所以切片算出 487 个 Map，但实际调度时资源已经不是那个值了      │
 └─────────────────────────────────────────────────────────────┘

                                  682541               683560
 日志: "Map 1: 0(+?)/246"         初始并发 ?            初始并发 3
                                  00:27:22             04:12:07

【阶段8: 实际执行】

                                  682541               683560
                                  00:27 ~ 00:28        04:12 ~ 05:23
                                  Map=246, ~1min完成    Map=487, 并发3
                                  task_245 EOFException 71分钟跑完486个
                                  → DAG FAILED          task_485 EOFException
                                                       → DAG2 FAILED

                                  00:28:29             05:23:25
                                  DAG3 重试              DAG3 重试
                                  Map=246               Map=487
                                  task_245 再次 EOF     487并发全拉满
                                  → 再次 FAILED         0个完成(1h42min)
                                  00:28:49             → 被用户kill
                                                       07:06:36
                                  
                                  00:28:51             07:06:59
                                  Session 关闭          App FINISHED
```

---

## 二、总结：为什么 Map 数差一倍

```
根因链路:

  00:26 队列繁忙，dmp 用户资源占用高
  → 682541 AM 第一次心跳 headroom 小 → totalResources = A → availableSlots = a
  
  04:11 队列相对空闲，dmp 用户资源占用低（682541 已结束释放资源）
  → 683560 AM 第一次心跳 headroom 大 → totalResources = B ≈ 2A → availableSlots = b ≈ 2a

同一份数据:
  availableSlots 差 2 倍
  → 三层同时放大（原始splits数 + desiredNumSplits + 分组路径）
  → 最终 Map 数差 2 倍: 246 vs 487

但实际调度时:
  683560 虽然算出 487 个 Map
  totalResources 是阶段3的一次性快照，不再更新
  实际 Container 分配取决于调度时的真实竞争
  → DAG2 只拿到 3 个并发（队列 82 个 active apps）
  → DAG3 拿到 487 个并发（DAG2 结束释放了大量 container + 其他 app 也结束了）
```

---

## 三、关键源码位置索引

| 阶段 | 源码位置 | 行号 | 关键逻辑 |
|------|---------|------|---------|
| totalResources 赋值 | `YarnTaskSchedulerService.java` | 901-908 | `totalResources = getAvailableResources()`，**只赋值一次** |
| getAvailableResources | `YarnTaskSchedulerService.java` | 256-257 | `amRmClient.getAvailableResources()` = RM 心跳返回的 headroom |
| getTotalAvailableResource | `TezRootInputInitializerContextImpl.java` | 106-107 | `appContext.getTaskScheduler().getTotalResources()` → 返回上面固定的值 |
| availableSlots 计算 | `HiveSplitGenerator.java` | 186-189 | `totalResource / taskResource` |
| 原始 splits 切分 | `HiveSplitGenerator.java` | 243 | `getSplits(jobConf, (int)(availableSlots * waves))` |
| desiredNumSplits | `SplitGrouper.java` | 247-248 | `(int)(availableSlots * waves * bucketSize / totalSize)` |
| 边界检查 | `TezSplitGrouper.java` | 239-269 | max-size / min-size / 不分组 三条路径 |
