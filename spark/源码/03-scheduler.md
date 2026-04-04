# Spark 调度系统源码分析

## 一、两层架构

```
DAGScheduler (Stage级别)     ← 负责 Stage 划分、拓扑调度、FetchFailed 重试
     ↓ submitTasks(TaskSet)
TaskSchedulerImpl (Task级别) ← 负责资源分配、本地性优化、失败重试
     ↓ reviveOffers()
SchedulerBackend             ← 与 Executor 通信 (YARN/K8s/Standalone)
```

## 二、Job → Task 完整链路

```
rdd.action() → SparkContext.runJob → DAGScheduler.runJob
  → submitJob → eventProcessLoop.post(JobSubmitted)
  → handleJobSubmitted → createResultStage (递归创建所有 Stage)
  → submitStage (递归提交父Stage)
  → submitMissingTasks → 创建 Task[] → taskScheduler.submitTasks(TaskSet)
  → TaskSchedulerImpl.submitTasks → 创建 TaskSetManager → backend.reviveOffers()
  → resourceOffers → TaskSetManager.resourceOffer (按本地性匹配)
  → Executor.launchTask → Task.run → runTask
```

## 三、Stage 划分规则

`getShuffleDependenciesAndResourceProfiles`: BFS 遍历 RDD 依赖
- 遇到 `ShuffleDependency` → Stage 边界 (停止遍历)
- 遇到 `NarrowDependency` → 同一 Stage (继续向上)

## 四、失败重试机制

### Task 级别 (TaskSetManager)
- 单 Task 最多重试 `spark.task.maxFailures` (默认4) 次
- FetchFailed → 标记 Task 完成，整个 TaskSet 标记为 zombie
- NotSerializableException / TaskOutputFileAlreadyExistException → abort，不重试
- ExecutorLostFailure (非 App 原因) → 不计入失败次数

### Stage 级别 (DAGScheduler)
- FetchFailed → unregisterMapOutput → failedStages → 200ms 后重提交
- 连续失败 ≥ `spark.stage.maxConsecutiveAttempts` (默认4) → abort

## 五、HealthTracker (黑名单) 三级排除

| 级别 | 作用域 | 关键参数 |
|------|--------|---------|
| **TaskSetExcludelist** | 单 TaskSet | MAX_TASK_ATTEMPTS_PER_EXECUTOR/NODE |
| **HealthTracker (Executor)** | 整个应用 | MAX_FAILURES_PER_EXEC (默认2) |
| **HealthTracker (Node)** | 整个应用 | MAX_FAILED_EXEC_PER_NODE (默认2) |

过期恢复: `EXCLUDE_ON_FAILURE_TIMEOUT` (默认1小时)

## 六、关键配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.task.maxFailures` | 4 | 单 Task 最大失败次数 |
| `spark.stage.maxConsecutiveAttempts` | 4 | Stage 连续失败最大重试 |
| `spark.scheduler.mode` | FIFO | 调度模式 (FIFO/FAIR) |
| `spark.speculation` | false | 推测执行开关 |
| `spark.speculation.quantile` | 0.75 | 推测执行任务完成比例阈值 |
| `spark.locality.wait` | 3s | 数据本地性等待时间 |
| `spark.excludeOnFailure.enabled` | 关闭 | 黑名单机制开关 |
| `spark.excludeOnFailure.timeout` | 1h | 黑名单超时恢复时间 |

## 七、可能导致任务卡死的路径

1. **DAGScheduler.runJob 无限阻塞**: `Duration.Inf` 等待，无 Executor 可用时永久阻塞
2. **waitingStages 无法触发**: 父 Stage shuffle output 丢失但 FetchFailed 未正确传播
3. **Barrier Stage 资源死锁**: 需要所有 Task 同时启动，但 slot 不够时无超时机制
4. **黑名单 abort 定时器竞态**: 其他 TaskSet 成功调度会清除所有不可调度的定时器

## 八、核心源码文件索引

| 文件 | 行数 | 关键内容 |
|------|------|---------|
| `scheduler/DAGScheduler.scala` | 3100 | Stage 划分/提交/完成/FetchFailed |
| `scheduler/TaskSchedulerImpl.scala` | 1365 | resourceOffers/黑名单/推测执行 |
| `scheduler/TaskSetManager.scala` | 1391 | Task 调度/成功/失败/本地性 |
| `scheduler/HealthTracker.scala` | 513 | 三级排除/超时恢复 |
| `scheduler/Stage.scala` | 135 | Stage 基类 |
| `scheduler/Task.scala` | 236 | Task 基类/内存释放 |
