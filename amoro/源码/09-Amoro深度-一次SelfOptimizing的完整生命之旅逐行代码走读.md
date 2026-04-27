# Amoro 深度源码：一次 Self-Optimizing 的完整生命之旅 — 从检测到提交的 2000 行代码走读

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-27

---

## 写在前面

之前的文档把 Amoro 的各个模块拆开讲了，这次不同。

我要**追踪一个真实的 Self-Optimizing 任务**，从它被检测到、到被调度、到被 Optimizer 执行、到最后提交到 Iceberg — **走完整条链路上的每一个关键方法**。就像给一个快递贴上 GPS，看它从仓库到你手里的每一步。

---

## 零、故事背景

```
你有一张 Iceberg 表 db.orders，通过 Spark Streaming 每分钟写入一次。
已经运行了 3 天，某个分区 dt=2026-04-27 下堆积了 200+ 个小文件。
现在 Amoro 要自动合并这些小文件。

让我们从 AMS Server 的视角，一行一行走完这个过程。
```

---

## 第一站：检测 — "哥们，这表有问题了"

故事从 `TableRuntimeRefreshExecutor` 开始。这是一个定时器，每隔一段时间对每张表执行 `refresh()`。

```java
// TableRuntimeRefreshExecutor.java（继承 BaseTableExecutor）
@Override
public void execute(TableRuntime tableRuntime) {
    AmoroTable<?> amoroTable = loadTable(tableRuntime);
    tableRuntime.refresh(amoroTable);  // ← 故事从这里开始
}
```

进入 `TableRuntime.refresh()`：

```java
// TableRuntime.java Line 261-273
public TableRuntime refresh(AmoroTable<?> table) {
    return invokeConsistency(() -> {
        // invokeConsistency 的作用：获取 tableLock，保证以下操作原子执行

        TableConfiguration configuration = tableConfiguration;
        boolean configChanged = updateConfigInternal(table.properties());

        // ★ 核心：刷新快照信息
        if (refreshSnapshots(table) || configChanged) {
            persistUpdatingRuntime();  // 持久化到数据库
        }
        if (configChanged) {
            tableHandler.handleTableChanged(this, configuration);
        }
        return this;
    });
}
```

`refreshSnapshots()` 做了什么？它读取了 Iceberg 表的最新 snapshot，对比了上次优化时的 snapshot。如果发现有新写入（snapshot ID 变了），就要评估是否需要优化。

接着进入 `setPendingInput()` — **这里是状态从 IDLE 变成 PENDING 的关键一跳**：

```java
// TableRuntime.java Line 245-258
public void setPendingInput(AbstractOptimizingEvaluator.PendingInput pendingInput) {
    invokeConsistency(() -> {
        this.pendingInput = pendingInput;  // 记录"待优化"的统计信息

        // ★★★ 关键状态转换 ★★★
        if (optimizingStatus == OptimizingStatus.IDLE) {
            updateOptimizingStatus(OptimizingStatus.PENDING);
            persistUpdatingRuntime();  // 写数据库
            LOG.info("{} status changed from idle to pending with pendingInput {}",
                tableIdentifier, pendingInput);

            // 通知事件链 — 告诉 OptimizingQueue "有活干了"
            tableHandler.handleTableChanged(this, OptimizingStatus.IDLE);
        }
    });
}
```

**到这一步的状态**：`orders` 表的 `optimizingStatus` 从 `IDLE(700)` 变成了 `PENDING(600)`。数据库已更新，OptimizingQueue 已收到通知。

---

## 第二站：调度 — "排队等号，叫到你了"

Optimizer 进程通过 Thrift RPC 调用 `pollTask()` 来领取任务。这个调用最终到达 `OptimizingQueue.pollTask()`：

```java
// OptimizingQueue.java Line 190-197
public TaskRuntime<?> pollTask(long maxWaitTime) {
    long deadline = calculateDeadline(maxWaitTime);
    TaskRuntime<?> task = fetchTask();  // ← 尝试获取一个任务
    while (task == null && waitTask(deadline)) {
        task = fetchTask();  // 没有任务就等，直到超时或有新任务
    }
    return task;
}
```

`fetchTask()` 内部先看有没有已经 plan 好的任务。如果没有，就要**选一张表来 plan**：

SchedulingPolicy 在这里登场了：

```java
// SchedulingPolicy.java Line 88-98
public TableRuntime scheduleTable(Set<ServerTableIdentifier> skipSet) {
    tableLock.lock();
    try {
        fillSkipSet(skipSet);  // 排除不该被调度的表

        // ★ 从所有候选表中选"分数最低"的那个
        return tableRuntimeMap.values().stream()
            .filter(t -> !skipSet.contains(t.getTableIdentifier()))
            .min(createSorterByPolicy())  // ← QuotaOccupySorter
            .orElse(null);
    } finally {
        tableLock.unlock();
    }
}
```

`fillSkipSet()` 的过滤逻辑值得仔细看，因为它决定了**哪些表不会被选中**：

```java
// SchedulingPolicy.java Line 123-133
private void fillSkipSet(Set<ServerTableIdentifier> originalSet) {
    long currentTime = System.currentTimeMillis();
    tableRuntimeMap.values().stream()
        .filter(runtime ->
            // 条件1: 不是 PENDING → 没资格
            !isTablePending(runtime)
            // 条件2: 被 Blocker 阻塞（比如有人在手动操作这张表）
            || runtime.isBlocked(BlockableOperation.OPTIMIZE)
            // 条件3: 距上次 plan 时间太短（防止频繁 plan 浪费资源）
            || currentTime - runtime.getLastPlanTime()
                < runtime.getOptimizingConfig().getMinPlanInterval()
        )
        .forEach(runtime -> originalSet.add(runtime.getTableIdentifier()));
}
```

而 `isTablePending()` 更精细 — 不是所有 PENDING 都真的需要优化：

```java
// SchedulingPolicy.java Line 135-140
private boolean isTablePending(TableRuntime tableRuntime) {
    return tableRuntime.getOptimizingStatus() == OptimizingStatus.PENDING
        // ★ 还要检查 snapshot 是否真的变了
        && (tableRuntime.getLastOptimizedSnapshotId() != tableRuntime.getCurrentSnapshotId()
            || tableRuntime.getLastOptimizedChangeSnapshotId()
                != tableRuntime.getCurrentChangeSnapshotId());
}
```

**设计洞察**：双重检查 — 状态是 PENDING **且** snapshot 确实有变化。防止 "状态标了 PENDING 但实际没有新数据需要优化" 的情况。

假设我们的 `orders` 表被选中了。接下来进入 plan 阶段。

---

## 第三站：Planning — "给你设计一个优化方案"

`TableRuntime.beginPlanning()` 被调用：

```java
// TableRuntime.java Line 193-201
public void beginPlanning() {
    invokeConsistency(() -> {
        OptimizingStatus originalStatus = optimizingStatus;  // PENDING
        updateOptimizingStatus(OptimizingStatus.PLANNING);   // → PLANNING
        persistUpdatingRuntime();
        tableHandler.handleTableChanged(this, originalStatus);
    });
}
```

接着 OptimizingQueue 创建 `TableOptimizingProcess`，内部调用 Planner：

Planner 的核心工作：**扫描每个分区的文件，决定哪些文件需要合并，生成任务列表**。

如果 planner 生成了任务（比如 dt=2026-04-27 分区的 200 个小文件需要合并）：

```java
// TableRuntime.java Line 221-232
public void beginProcess(OptimizingProcess optimizingProcess) {
    invokeConsistency(() -> {
        OptimizingStatus originalStatus = optimizingStatus;  // PLANNING
        this.optimizingProcess = optimizingProcess;
        this.processId = optimizingProcess.getProcessId();

        // ★ 根据优化类型设置状态
        updateOptimizingStatus(
            OptimizingStatus.ofOptimizingType(optimizingProcess.getOptimizingType()));
        // MINOR → MINOR_OPTIMIZING(300)
        // MAJOR → MAJOR_OPTIMIZING(200)
        // FULL  → FULL_OPTIMIZING(100)

        this.pendingInput = null;  // 清空待优化输入（已经在 plan 中了）
        persistUpdatingRuntime();
        tableHandler.handleTableChanged(this, originalStatus);
    });
}
```

如果 planner 发现不需要优化（文件都挺大的），走另一条路：

```java
// TableRuntime.java Line 289-300
public void completeEmptyProcess() {
    invokeConsistency(() -> {
        pendingInput = null;
        if (optimizingStatus == OptimizingStatus.PLANNING
            || optimizingStatus == OptimizingStatus.PENDING) {
            updateOptimizingStatus(OptimizingStatus.IDLE);  // → 直接回 IDLE
            lastOptimizedSnapshotId = currentSnapshotId;     // 标记"已优化到这个版本"
            lastOptimizedChangeSnapshotId = currentChangeSnapshotId;
            persistUpdatingRuntime();
        }
    });
}
```

**设计洞察**：`completeEmptyProcess()` 把 `lastOptimizedSnapshotId` 更新了。这样下次 `isTablePending()` 检查时，如果没有新写入，就不会再白白 plan 一次。

---

## 第四站：执行 — "Optimizer 干活了"

回到 `pollTask()`，Optimizer 拿到了一个 `TaskRuntime`。任务描述里包含了要读取哪些文件、写到哪里。

Optimizer 进程的核心循环：

```
OptimizerExecutor.run():
  while (!stopped):
    1. task = pollTask()                // Thrift RPC 领取任务
    2. acknowledgeTask(task)            // 确认接收
    3. result = execute(task)           // ★ 执行重写
    4. completeTask(task, result)       // 上报结果
```

`execute()` 内部会创建 `IcebergRewriteExecutor`（纯 Iceberg）或 `MixedIcebergRewriteExecutor`（Mixed-Iceberg），执行逻辑：

```
读取旧的小文件（200 个 × 平均 3MB）
  → 合并为新的大文件（约 5 个 × 128MB）
  → 返回 RewriteFilesOutput {
       dataFiles: [新文件列表],
       deleteFiles: [如有 delete 需要重写]
     }
```

任务完成后，`TaskRuntime.complete()` 被调用：

```java
// TaskRuntime.java Line 84-100
public void complete(OptimizerThread thread, OptimizingTaskResult result) {
    invokeConsistency(() -> {
        validThread(thread);  // 验证是正确的线程在上报

        if (result.getErrorMessage() != null) {
            statusMachine.accept(Status.FAILED);   // 失败
            failReason = result.getErrorMessage();
        } else {
            statusMachine.accept(Status.SUCCESS);   // 成功
            taskDescriptor.setOutputBytes(result.getTaskOutput());  // 保存输出
        }

        endTime = System.currentTimeMillis();
        costTime += endTime - startTime;  // 累计耗时
        runTimes += 1;                    // 运行次数 +1
        persistTaskRuntime();             // 写数据库
        future.complete();                // 通知等待者"我完成了"
    });
}
```

---

## 第五站：提交 — "所有工人都干完了，提交成果"

当一个 `OptimizingProcess` 的所有 `TaskRuntime` 都变成 SUCCESS 后，进入 COMMITTING 阶段：

```java
// TableRuntime.java Line 235-242
public void beginCommitting() {
    invokeConsistency(() -> {
        OptimizingStatus originalStatus = optimizingStatus; // *_OPTIMIZING
        updateOptimizingStatus(OptimizingStatus.COMMITTING); // → COMMITTING
        persistUpdatingRuntime();
        tableHandler.handleTableChanged(this, originalStatus);
    });
}
```

然后 `OptimizingProcess.commit()` 被调用。内部使用 **Iceberg 的 RewriteFiles API**：

```java
// 简化后的提交逻辑
RewriteFiles rewrite = table.newRewrite()
    .validateFromSnapshot(targetSnapshotId);

// 告诉 Iceberg：删除这些旧文件
for (DataFile oldFile : taskOutput.getOldDataFiles()) {
    rewrite.deleteFile(oldFile);
}

// 告诉 Iceberg：添加这些新文件
for (DataFile newFile : taskOutput.getNewDataFiles()) {
    rewrite.addFile(newFile);
}

// ★ 最终调用 Iceberg 的 SnapshotProducer.commit()
// 就是我们上一篇分析的 OCC commit！
rewrite.commit();
```

**关键点**：Amoro 的优化提交，最终用的就是 Iceberg 标准的 `RewriteFiles` API + OCC commit。如果有并发冲突（比如用户在优化期间也在写数据），Iceberg 的重试机制会处理。

提交成功后，回到 `TableRuntime` 更新最终状态：

```
COMMITTING → IDLE
lastOptimizedSnapshotId = targetSnapshotId
lastMinorOptimizingTime = now()  // 或 lastMajorOptimizingTime
→ 持久化到数据库
→ tableHandler.handleTableChanged() → 将表重新加入 SchedulingPolicy
```

---

## 第六站：回到起点 — "继续巡逻"

表回到 IDLE 状态，被重新加入 `SchedulingPolicy` 的候选池。等到 `TableRuntimeRefreshExecutor` 下一次 `refresh()` 检测到新的写入数据，整个循环又开始了。

---

## 完整时间线

```
T+0s    TableRuntimeRefreshExecutor.execute()
          → TableRuntime.refresh()
          → refreshSnapshots() 发现新 snapshot
          → setPendingInput()
          → IDLE ──→ PENDING
          → 持久化 + 通知 OptimizingQueue

T+30s   Optimizer.pollTask()
          → OptimizingQueue.fetchTask()
          → SchedulingPolicy.scheduleTable()
            → fillSkipSet(): 过滤非 PENDING、被阻塞、间隔太短的表
            → QuotaOccupySorter: 按 quotaOccupy 排序
            → 选中 orders 表
          → TableRuntime.beginPlanning()
          → PENDING ──→ PLANNING

T+32s   OptimizingPlanner.plan()
          → 扫描 dt=2026-04-27 分区
          → 200 个小文件 > minor.trigger.file-count (12)
          → 生成 Minor Optimize 任务列表（5 个 TaskRuntime）
          → TableRuntime.beginProcess()
          → PLANNING ──→ MINOR_OPTIMIZING
          → 持久化 Process + Tasks 到数据库

T+33s   Optimizer 领取 Task 1/5 → 执行 → SUCCESS
T+35s   Optimizer 领取 Task 2/5 → 执行 → SUCCESS
T+37s   Optimizer 领取 Task 3/5 → 执行 → SUCCESS
T+39s   Optimizer 领取 Task 4/5 → 执行 → SUCCESS
T+41s   Optimizer 领取 Task 5/5 → 执行 → SUCCESS

T+42s   所有任务完成
          → TableRuntime.beginCommitting()
          → MINOR_OPTIMIZING ──→ COMMITTING

T+43s   OptimizingProcess.commit()
          → Iceberg table.newRewrite()
            .deleteFile(200 个旧文件)
            .addFile(5 个新文件)
            .commit()  ← OCC commit!
          → 成功

T+44s   COMMITTING ──→ IDLE
          → lastOptimizedSnapshotId = 新 snapshot
          → lastMinorOptimizingTime = now
          → 持久化
          → 重新加入 SchedulingPolicy

         ✅ 完成！200 个小文件 → 5 个 128MB 文件
         dt=2026-04-27 分区查询速度恢复正常
```

---

## 设计洞察

读完这条完整链路，我总结出 Amoro Self-Optimizing 的 **五个关键设计决策**：

| # | 决策 | 为什么这么做 |
|---|------|-------------|
| 1 | **双重 PENDING 检查**（状态 + snapshot 变化） | 避免"状态是 PENDING 但没有新数据"的空转。`completeEmptyProcess()` 更新 `lastOptimizedSnapshotId` 是防空转的关键 |
| 2 | **QuotaOccupy 调度而非 FIFO** | 多表共享有限 Optimizer 资源时，用过少配额的表优先。公平性 > 先来先服务 |
| 3 | **plan 和 execute 分离** | AMS 做 plan（轻量级，读元数据），Optimizer 做 execute（重量级，读写数据）。AMS 不需要大内存 |
| 4 | **最终提交用标准 Iceberg API** | 不自己造 commit 逻辑，直接用 `table.newRewrite().commit()`。并发安全由 Iceberg OCC 保证 |
| 5 | **所有状态转换都通过 `invokeConsistency`** | tableLock + 持久化的原子性。AMS 重启后可以从数据库恢复到任意中间状态继续执行 |

其中第 5 点最容易被忽略，但它是 Amoro **可靠性**的基石。看 `initTableRuntime()` 的恢复逻辑：

```java
// OptimizingQueue.java Line 116-146
private void initTableRuntime(TableRuntime tableRuntime) {
    if (tableRuntime.getOptimizingStatus().isProcessing()
        && tableRuntime.getProcessId() != 0) {
        // ★ AMS 重启 → 从数据库恢复正在执行的 Process
        tableRuntime.recover(new TableOptimizingProcess(tableRuntime));
    }

    if (tableRuntime.getOptimizingStatus() == OptimizingStatus.COMMITTING) {
        // ★ 重启时处于 COMMITTING → 不知道有没有提交成功
        // 安全选择：关闭这个 Process，让它重新来
        OptimizingProcess process = tableRuntime.getOptimizingProcess();
        if (process != null) {
            process.close();
        }
    }
}
```

这就是**系统可靠性的真正来源**：不是"永远不挂"，而是"挂了之后能正确恢复"。
