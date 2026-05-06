# Amoro 源码深度解析：TableRuntime 状态机与优化进程生命周期管理

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-27

---

## 一、TableRuntime — 表运行时管理核心

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/table/TableRuntime.java` (661行)

### 1.1 核心字段

```java
public class TableRuntime extends StatedPersistentBase {
    private final ServerTableIdentifier tableIdentifier;  // 表标识
    private final TableRuntimeHandler tableHandler;       // 事件处理器
    private final Lock tableLock = new ReentrantLock();   // 并发锁
    private final List<TaskRuntime.TaskQuota> taskQuotas; // 配额记录

    // ========== @StateField — 持久化到数据库 ==========
    @StateField volatile long currentSnapshotId;            // 当前 base snapshot
    @StateField volatile long currentChangeSnapshotId;      // 当前 change snapshot
    @StateField volatile long lastOptimizedSnapshotId;      // 上次优化的 base snapshot
    @StateField volatile long lastOptimizedChangeSnapshotId;// 上次优化的 change snapshot
    @StateField volatile OptimizingStatus optimizingStatus; // 优化状态（核心！）
    @StateField volatile long currentStatusStartTime;       // 当前状态开始时间
    @StateField volatile long lastMajorOptimizingTime;      // 上次 Major 完成时间
    @StateField volatile long lastFullOptimizingTime;       // 上次 Full 完成时间
    @StateField volatile long lastMinorOptimizingTime;      // 上次 Minor 完成时间
    @StateField volatile String optimizerGroup;             // 所属优化组
    @StateField volatile OptimizingProcess optimizingProcess; // 当前优化进程
    @StateField volatile TableConfiguration tableConfiguration; // 表配置
    @StateField volatile PendingInput pendingInput;         // 待优化输入统计
    @StateField volatile PendingInput tableSummary;         // 表概况统计

    // ========== 非持久化 ==========
    volatile long lastPlanTime;              // 上次计划时间
    long targetSnapshotId;                   // 目标快照 ID
    OptimizingType optimizingType;           // 优化类型
    TableOptimizingMetrics optimizingMetrics; // Prometheus 指标
}
```

---

## 二、OptimizingStatus 状态机

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/OptimizingStatus.java`

```
状态定义（code 越小优先级越高）:

  FULL_OPTIMIZING (100)  — 全量优化中
  MAJOR_OPTIMIZING (200) — Major 优化中
  MINOR_OPTIMIZING (300) — Minor 优化中
  COMMITTING (400)       — 提交中
  PLANNING (500)         — 计划中
  PENDING (600)          — 等待调度
  IDLE (700)             — 空闲
```

### 2.1 状态流转图

```
                    ┌──────────────────────────────────────────────┐
                    │                                              │
                    ▼                                              │
  ┌──────┐    ┌─────────┐    ┌──────────┐    ┌──────────────────┐ │
  │ IDLE │───→│ PENDING │───→│ PLANNING │───→│ MINOR/MAJOR/FULL │ │
  │ (700)│    │  (600)  │    │  (500)   │    │ OPTIMIZING       │ │
  └──┬───┘    └────┬────┘    └────┬─────┘    │ (100/200/300)    │ │
     │             │              │           └───────┬──────────┘ │
     │             │              │                   │            │
     │        plan 失败           │                   ▼            │
     │        或无任务            │           ┌──────────────┐     │
     │             │              │           │  COMMITTING  │     │
     │             ▼              │           │    (400)     │     │
     │         ┌──────┐          │           └───────┬──────┘     │
     │         │ IDLE │◄─────────┘                   │            │
     │         └──────┘                              │ 成功       │
     │                                               ▼            │
     │                                          ┌──────┐          │
     └──────────────────────────────────────────│ IDLE │──────────┘
                                                └──────┘
                                                  │ 检测到变更
                                                  ▼
                                             ┌─────────┐
                                             │ PENDING │
                                             └─────────┘
```

### 2.2 状态转换触发条件

| 转换 | 触发条件 | 方法 |
|------|---------|------|
| IDLE → PENDING | 检测到 snapshot 变化 + needOptimizing | `refresh()` |
| PENDING → PLANNING | SchedulingPolicy 选中该表 | `beginPlanning()` |
| PLANNING → *_OPTIMIZING | Planner 生成任务 | `beginProcess()` |
| PLANNING → IDLE | 无需优化（plan 为空） | `planFailed()` |
| *_OPTIMIZING → COMMITTING | 所有任务完成 | `beginCommitting()` |
| COMMITTING → IDLE | 提交成功 | `commitDone()` |
| *_OPTIMIZING → PENDING | 优化失败/超时 | `resetProcess()` |

---

## 三、关键方法详解

### 3.1 beginPlanning — 开始计划

```java
public void beginPlanning() {
    invokeConsistency(() -> {
        OptimizingStatus originalStatus = optimizingStatus;
        updateOptimizingStatus(OptimizingStatus.PLANNING);
        persistUpdatingRuntime();
        tableHandler.handleTableChanged(this, originalStatus);
    });
}
```

### 3.2 refresh — 检测表变更

```java
public void refresh(AmoroTable<?> amoroTable) {
    tableLock.lock();
    try {
        // 1. 获取最新 snapshot
        Table icebergTable = (Table) amoroTable.originalTable();
        Snapshot currentSnapshot = icebergTable.currentSnapshot();
        long newSnapshotId = currentSnapshot != null ? currentSnapshot.snapshotId() : -1;

        // 2. 更新 snapshot ID
        this.currentSnapshotId = newSnapshotId;

        // 3. 评估是否需要优化
        PendingInput newPendingInput = evaluatePendingInput(amoroTable);
        this.pendingInput = newPendingInput;

        // 4. 状态转换
        if (optimizingStatus == OptimizingStatus.IDLE && needOptimizing()) {
            updateOptimizingStatus(OptimizingStatus.PENDING);
        }

        persistUpdatingRuntime();
    } finally {
        tableLock.unlock();
    }
}
```

### 3.3 calculateQuotaOccupy — 配额计算

```java
public double calculateQuotaOccupy() {
    long quotaTime = calculateQuotaTime();    // 分配的配额时间
    long actualUsed = calculateActualUsed();  // 实际使用时间
    if (quotaTime == 0) return 0;
    return BigDecimal.valueOf(actualUsed)
        .divide(BigDecimal.valueOf(quotaTime), 4, RoundingMode.HALF_UP)
        .doubleValue();
}
```

---

## 四、OptimizingProcess — 优化进程

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/OptimizingProcess.java`

```java
public interface OptimizingProcess {
    long getProcessId();
    OptimizingType getOptimizingType();  // MINOR / MAJOR / FULL
    ProcessStatus getStatus();
    long getTargetSnapshotId();
    long getTargetChangeSnapshotId();
    long getPlanTime();
    long getDuration();
    long getRunningQuotaTime(long calculatingStartTime, long calculatingEndTime);
    void close();
    boolean isClosed();
    void commit();                       // 提交优化结果
    Map<String, String> getSummary();    // 指标摘要
}
```

### 进程生命周期

```
创建 → PLANNED → 分发任务 → EXECUTING → 所有任务完成 → COMMITTING → 提交 → CLOSED
                                 │
                           任务失败 → 重试（max 3次）→ FAILED → CLOSED
```

---

## 五、TaskRuntime — 任务运行时

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/TaskRuntime.java`

### 5.1 Task 状态机

```java
public enum Status {
    PLANNED,    // 已计划，等待领取
    SCHEDULED,  // 已分配给 Optimizer
    ACKED,      // Optimizer 已确认
    FAILED,     // 执行失败
    SUCCESS,    // 执行成功
    CANCELED    // 已取消
}

// 合法状态转换:
// PLANNED → SCHEDULED → ACKED → SUCCESS
// PLANNED → SCHEDULED → ACKED → FAILED
// PLANNED → CANCELED
// SCHEDULED → CANCELED
```

### 5.2 核心字段

```java
public class TaskRuntime<T> extends StatedPersistentBase {
    @StateField Status status = Status.PLANNED;
    @StateField int runTimes = 0;        // 已运行次数
    @StateField long startTime;          // 开始时间
    @StateField long endTime;            // 结束时间
    @StateField long costTime;           // 累计耗时
    @StateField String token;            // Optimizer 令牌
    @StateField int threadId;            // 执行线程 ID
    @StateField String failReason;       // 失败原因
}
```

### 5.3 任务完成处理

```java
public void complete(OptimizerThread thread, OptimizingTaskResult result) {
    invokeConsistency(() -> {
        validThread(thread);
        if (result.getErrorMessage() != null) {
            statusMachine.accept(Status.FAILED);
            failReason = result.getErrorMessage();
        } else {
            statusMachine.accept(Status.SUCCESS);
            taskDescriptor.setOutputBytes(result.getTaskOutput());
        }
        endTime = System.currentTimeMillis();
        costTime += endTime - startTime;
        runTimes += 1;
        persistTaskRuntime();
        future.complete();
    });
}
```

---

## 六、完整生命周期流程

```
1. TableRuntimeRefreshExecutor 定时刷新
   TableRuntime.refresh(amoroTable)
     → currentSnapshotId 更新
     → evaluatePendingInput()
     → IDLE → PENDING（如果有变更需要优化）

2. OptimizingQueue.pollTask()
   → SchedulingPolicy.scheduleTable()
     → 选择 PENDING 且配额最低的表
   → TableRuntime.beginPlanning()
     → PENDING → PLANNING

3. OptimizingPlanner.plan()
   → 评估分区（Minor/Major/Full）
   → 生成 OptimizingProcess + TaskRuntime 列表
   → PLANNING → *_OPTIMIZING
   → 持久化到数据库

4. Optimizer.pollTask()（Thrift RPC）
   → 返回 PLANNED 状态的 TaskRuntime
   → PLANNED → SCHEDULED → ACKED

5. Optimizer 执行任务
   → IcebergRewriteExecutor / MixedIcebergRewriteExecutor
   → 读取 → 合并 → 写出新文件
   → TaskRuntime.complete(SUCCESS/FAILED)

6. 所有任务完成
   → *_OPTIMIZING → COMMITTING
   → OptimizingProcess.commit()
     → table.newRewrite().deleteFile(old).addFile(new).commit()
   → COMMITTING → IDLE

7. 更新 TableRuntime
   → lastOptimizedSnapshotId = targetSnapshotId
   → lastMajorOptimizingTime / lastMinorOptimizingTime 更新
   → 回到步骤 1 继续检测
```

---

## 七、并发安全设计

```
TableRuntime 的并发控制:
  1. ReentrantLock tableLock — 保护所有状态字段的读写
  2. invokeConsistency() — 确保状态+持久化的原子性
  3. StatedPersistentBase — 状态变更自动持久化到数据库
  4. volatile 字段 — 保证可见性

TaskRuntime 的并发控制:
  1. TaskStatusMachine — 严格验证状态转换合法性
  2. validThread(thread) — 验证操作者是否是被分配的线程
  3. invokeConsistency() — 状态+持久化原子性
```

---

## 八、Prometheus 指标

```
每个 TableRuntime 注册以下指标:

TableOptimizingMetrics:
  amoro_table_optimizing_status{table=...}           — 当前状态
  amoro_table_optimizing_status_duration_ms{table=..} — 状态持续时间
  amoro_table_last_minor_optimizing_time{table=...}   — 上次 Minor 时间
  amoro_table_last_major_optimizing_time{table=...}   — 上次 Major 时间
  amoro_table_last_full_optimizing_time{table=...}    — 上次 Full 时间

TableSummaryMetrics:
  amoro_table_data_files_count{table=...}    — 数据文件数
  amoro_table_data_files_size{table=...}     — 数据总大小
  amoro_table_eq_delete_files_count{table=..} — Equality Delete 文件数
  amoro_table_pos_delete_files_count{table=..}— Position Delete 文件数
```
