# Amoro 源码深度解析：Self-Optimizing 调度核心

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-25

---

## 一、调度全景

```
TableRuntimeRefreshExecutor（定期刷新表状态）
  → TableRuntime 检测 snapshot 变更
  → OptimizingQueue.refreshTable()
     → 触发 planInternal()
        → AbstractOptimizingEvaluator.initEvaluator()
           → CommonPartitionEvaluator.addFile()  ← 逐文件评估
           → CommonPartitionEvaluator.isNecessary() ← 判定是否需要优化
        → AbstractOptimizingPlanner.planTasks()   ← 生成任务列表
  → Optimizer.pollTask() → 执行 → completeTask()
  → OptimizingCommitExecutor 提交结果
```

---

## 二、CommonPartitionEvaluator — 优化决策大脑

**源码位置**: `amoro-format-iceberg/.../optimizing/plan/CommonPartitionEvaluator.java`（500+ 行）

### 2.1 文件分类体系

```java
// 文件三档分类
// Line 117-123
protected boolean isFragmentFile(DataFile dataFile) {
    return dataFile.fileSizeInBytes() <= fragmentSize;
    // fragmentSize = targetSize / fragmentRatio
    // 默认: 128MB / 8 = 16MB
    // 小于 16MB → fragment file（碎片文件）
}

protected boolean isUndersizedSegmentFile(DataFile dataFile) {
    return dataFile.fileSizeInBytes() > fragmentSize
        && dataFile.fileSizeInBytes() <= minTargetSize;
    // 16MB < size <= minTargetSize
    // 偏小的 segment 文件
}

// 其他: size > minTargetSize → 正常大小的 segment 文件
```

**文件分类图**:

```
0          16MB (fragment)     minTargetSize        128MB (target)
|──fragment──|────undersized────|──────normal──────────|
             ↑                  ↑
         fragmentSize      minTargetSize
      (target/ratio)    (target*minRatio)
```

### 2.2 addFile() — 逐文件评估

```java
// Line 126-137
public boolean addFile(DataFile dataFile, List<ContentFile<?>> deletes) {
    if (!config.isEnabled()) return false;

    if (isFragmentFile(dataFile)) {
        return addFragmentFile(dataFile, deletes);
        // 直接标记为需要重写，累加统计
    } else if (isUndersizedSegmentFile(dataFile)) {
        return addUndersizedSegmentFile(dataFile, deletes);
        // 根据 delete 比例决定是否需要重写
        // 同时缓存最小两个文件大小（用于 enoughContent 判断）
    } else {
        return addTargetSizeReachedFile(dataFile, deletes);
        // 大文件：只有 delete 比例超阈值才重写
    }
}
```

### 2.3 fileShouldRewrite() — 重写决策

```java
// Line 218-234
public boolean fileShouldRewrite(DataFile dataFile, List<ContentFile<?>> deletes) {
    // Full 优化模式：几乎所有文件都重写
    if (isFullOptimizing()) {
        return fileShouldFullOptimizing(dataFile, deletes);
    }

    // Fragment 文件：无条件重写
    if (isFragmentFile(dataFile)) {
        return true;
    }

    // Segment 文件：pos_delete 占比超过 majorDuplicateRatio 才重写
    return getPosDeletesRecordCount(deletes)
        > dataFile.recordCount() * config.getMajorDuplicateRatio();
    // 默认 majorDuplicateRatio = 0.1（10%）
    // 即: 如果一个文件有 10% 以上的行被删除，才值得重写
}
```

### 2.4 三种优化类型判定

```java
// Line 288-298 — 优先级: Full > Major > Minor
public boolean isNecessary() {
    if (isFullOptimizing()) {
        necessary = isFullNecessary();       // Full 优化
    } else {
        necessary = isMajorNecessary()       // Major 优先
            || isMinorNecessary();           // 再看 Minor
    }
}

// Line 372-381 — Full 优化触发条件
public boolean isFullNecessary() {
    if (!reachFullInterval()) return false;  // 必须达到 Full 间隔
    return anyDeleteExist()                  // 有任何删除文件
        || fragmentFileCount >= 2            // 有 2+ 碎片文件
        || undersizedSegmentFileCount >= 2   // 有 2+ 偏小文件
        || rewriteSegmentFileCount > 0       // 有需要重写的 segment
        || rewritePosSegmentFileCount > 0;   // 有需要重写 pos-delete 的 segment
}

// Line 352-354 — Major 优化触发条件
public boolean isMajorNecessary() {
    return enoughContent()                   // 偏小文件总大小 >= targetSize
        || rewriteSegmentFileCount > 0;      // 有需要重写的 segment
}

// Line 356-361 — Minor 优化触发条件
public boolean isMinorNecessary() {
    int smallFileCount = fragmentFileCount + equalityDeleteFileCount;
    return smallFileCount >= config.getMinorLeastFileCount()  // 默认 12
        || (smallFileCount > 1 && reachMinorInterval())       // 超过 minor 间隔
        || combinePosSegmentFileCount > 0;                    // 有需要合并 pos-delete 的
}
```

**决策流程图**:

```
                   ┌── reachFullInterval? ──YES──→ isFullNecessary?
                   │                                ├── YES → FULL 优化
                   │                                └── NO  → 跳过
分区评估 ─────────┤
                   │
                   └── NO ──→ isMajorNecessary?
                               ├── YES → MAJOR 优化
                               └── NO  → isMinorNecessary?
                                          ├── YES → MINOR 优化
                                          └── NO  → 不需要优化
```

### 2.5 Cost 计算与优先级排序

```java
// Line 301-321
public long getCost() {
    // 读写成本（假设读写代价相同）
    cost = (fragmentFileSize + rewriteSegmentFileSize + undersizedSegmentFileSize) * 2
        + rewritePosSegmentFileSize / 10  // Pos-delete 重写只读主键，1/10
        + posDeleteFileSize
        + equalityDeleteFileSize;

    // 文件打开成本
    int fileCnt = fragmentFileCount + rewriteSegmentFileCount + ...;
    cost += fileCnt * config.getOpenFileCost();
}
```

`AbstractOptimizingPlanner.planTasks()` 按 cost 降序排列分区，优先优化代价最大的分区，避免小分区饿死大分区。

### 2.6 健康评分

```java
// Line 395-412
public int getHealthScore() {
    // 0-100 分，越高越健康
    // 三个惩罚因子：
    // 40% — 小文件惩罚（平均文件大小 / minTargetSize）
    // 40% — EqDelete 惩罚（eq_delete_records / data_records）
    // 20% — PosDelete 惩罚（pos_delete_records / data_records）
    //
    // 加上表级惩罚因子（小表不惩罚）
    return 100 - tablePenaltyFactor * (
        40 * smallFilePenalty + 40 * eqDeletePenalty + 20 * posDeletePenalty);
}
```

---

## 三、OptimizingQueue — 任务队列管理

**源码位置**: `amoro-ams/.../server/optimizing/OptimizingQueue.java`（761 行）

### 3.1 核心职责

```
OptimizingQueue（每个 Optimizer Group 一个）
  ├── 维护表的 TableRuntime 集合
  ├── 周期性 plan：选择需要优化的表 → 生成任务
  ├── 任务分发：Optimizer 来 poll → 分配任务
  ├── 任务跟踪：ack/complete/timeout
  └── 资源配额管理
```

### 3.2 planInternal() 流程

```java
// OptimizingQueue 内部
void planInternal(TableRuntime tableRuntime) {
    // 1. 加载表
    AmoroTable<?> table = catalogManager.loadTable(identifier);
    MixedTable mixedTable = (MixedTable) table.originalTable();

    // 2. 创建 Planner（根据表类型选择）
    AbstractOptimizingPlanner planner = new IcebergOptimizingPlanner(
        identifier, config, mixedTable, snapshot, ...);

    // 3. 规划任务
    List<RewriteStageTask> tasks = planner.planTasks();

    // 4. 如果有任务，创建 OptimizingProcess
    if (!tasks.isEmpty()) {
        OptimizingProcess process = new OptimizingProcess(...);
        // 序列化 TaskInput，存储到 DB
        // 创建 TaskRuntime 对象
        // 加入任务队列等待分发
    }
}
```

### 3.3 TaskRuntime 状态机

```java
// TaskRuntime.java Line 273-283
private static final Map<Status, Set<Status>> nextStatusMap =
    ImmutableMap.<Status, Set<Status>>builder()
        .put(PLANNED,   ImmutableSet.of(SCHEDULED, CANCELED))
        .put(SCHEDULED, ImmutableSet.of(PLANNED, ACKED, CANCELED))
        .put(ACKED,     ImmutableSet.of(PLANNED, SUCCESS, FAILED, CANCELED))
        .put(FAILED,    ImmutableSet.of(PLANNED))      // 失败可重试
        .put(CANCELED,  ImmutableSet.of())              // 取消是终态
        .put(SUCCESS,   ImmutableSet.of())              // 成功是终态
        .build();
```

**状态流转**:

```
PLANNED ──→ SCHEDULED ──→ ACKED ──→ SUCCESS ✓
   ↑            │            │
   │            │            ├──→ FAILED → PLANNED（重试）
   │            │            │
   └────────────┴────────────┴──→ CANCELED ✗
```

---

## 四、关键配置与调优

| 配置 | 默认 | 对应源码字段 | 调优建议 |
|------|------|-------------|---------|
| `self-optimizing.target-size` | 128MB | `config.getTargetSize()` | 根据查询模式调整，OLAP 可调大到 256MB |
| `self-optimizing.fragment-ratio` | 8 | `config.getFragmentRatio()` | fragment = target/ratio = 16MB |
| `self-optimizing.min-target-size-ratio` | 0.75 | `config.getMinTargetSizeRatio()` | minTarget = 128*0.75 = 96MB |
| `self-optimizing.minor.trigger.file-count` | 12 | `config.getMinorLeastFileCount()` | 流式写入降低到 6 |
| `self-optimizing.major.trigger.duplicate-ratio` | 0.1 | `config.getMajorDuplicateRatio()` | 10% 删除触发 Major |
| `self-optimizing.full.trigger.interval` | -1 | `config.getFullTriggerInterval()` | -1 禁用，按需开启 |

---

*Amoro Self-Optimizing 调度深度解析 v1.0 | Eric | 2026-04-25*
