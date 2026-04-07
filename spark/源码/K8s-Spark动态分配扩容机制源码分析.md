# K8s Spark 动态分配扩容机制源码分析

> 来源案例：K8s vs YARN 性能对比，2026-04-07
> 任务编号: KY-01 补充

---

## K8s 扩容时间线还原（从日志）

```
T+0s   13:28:21  initialExecutors=1, 请求第 1 个 Pod
T+5s   13:28:26  Exec-1 注册（SchedulerBackend ready, minRatio=0.8）
T+65s  13:29:26  Stage 1 触发 backlog → 请求扩到 2
T+90s  13:29:51  指数扩容开始: 3→4→6→10→18→34→66→100
T+97s  13:29:58  请求达到 100 个
T+117s 13:30:23  第 100 个 Exec 注册完成
```

### 指数扩容序列

```
13:29:26  target: 2   (+1)    1 个 Pod 在跑
13:29:51  target: 3   (+2)    
13:29:52  target: 4   (+1)    
13:29:53  target: 6   (+2)    
13:29:54  target: 10  (+4)    
13:29:55  target: 18  (+8)    
13:29:56  target: 34  (+16)   
13:29:57  target: 66  (+32)   
13:29:58  target: 100 (+34)   
```

Spark 的指数退避策略：每秒翻倍（1→2→4→8→16→32→...），8 秒内从 2 扩到 100。

## 关键源码

### ExecutorAllocationManager — 指数扩容

```scala
// ExecutorAllocationManager.scala
// 每个 schedulerBacklogTimeout (默认 1s) 检查一次
// 如果有 backlog，按指数增长请求
private var numExecutorsToAdd = 1
if (addTime > 0 && now >= addTime) {
  val delta = addExecutors(maxNumExecutorsNeeded)
  if (delta > 0) numExecutorsToAdd = math.min(numExecutorsToAdd * 2, ...)
}
```

### ExecutorPodsAllocator — K8s Pod 创建

```scala
// ExecutorPodsAllocator.scala 第 382-428 行
private def requestNewExecutors(numExecutorsToAllocate: Int, ...): Unit = {
  for (_ <- 0 until numExecutorsToAllocate) {
    val executorConf = KubernetesConf.createExecutorConf(...)
    val resolvedExecutorSpec = executorBuilder.buildFromFeatures(executorConf, ...)
    val podWithAttachedContainer = new PodBuilder(executorPod.pod)
      .editOrNewSpec()
      .addToContainers(executorPod.container)
      .endSpec()
      .build()
    val createdExecutorPod = kubernetesClient.pods().create(podWithAttachedContainer)
    // ← 每个 Pod 逐个创建，串行 API 调用
  }
}
```

**注意**: Pod 创建是**串行**的（for 循环逐个调 K8s API），这是扩容慢的原因之一。

### 受 podAllocationSize 限制

```scala
// Config.scala 第 405-411 行
val KUBERNETES_ALLOCATION_BATCH_SIZE =
  ConfigBuilder("spark.kubernetes.allocation.batch.size")
    .doc("Number of pods to launch at once in each round of executor allocation.")
    .intConf.createWithDefault(5)  // ← 默认每轮只创建 5 个！
```

每个 `podAllocationDelay` (默认 1s) 周期，最多创建 `batch.size` (默认 5) 个 Pod。
所以 100 个 Pod 理论最快需要 100/5 = 20 轮 × 1s = 20s。

## 优化建议

```properties
# 1. 直接设初始值（最简单有效）
spark.dynamicAllocation.initialExecutors = 100

# 2. 或增大 batch size（减少扩容轮次）
spark.kubernetes.allocation.batch.size = 20  # 默认 5

# 3. 或减少 batch delay
spark.kubernetes.allocation.batch.delay = 500ms  # 默认 1s

# 4. 用 Volcano gang scheduling（所有 Pod 一次性调度）
spark.kubernetes.scheduler.volcano.podGroupTemplateJson = {
  "spec": {"minMember": 101}  # driver + 100 executors
}
```
