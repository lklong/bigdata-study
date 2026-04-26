# Amoro 源码深度解析：OptimizingQueue 调度策略与配额管理

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-26

---

## 一、OptimizingQueue 在架构中的位置

```
DefaultTableService
  └── headHandler (RuntimeHandlerChain)
         │
         ├── OptimizingQueue  ← 本篇核心
         │    ├── SchedulingPolicy（表调度策略）
         │    ├── OptimizingProcess（优化进程管理）
         │    ├── TaskRuntime 队列（任务分发）
         │    └── 配额管理（Quota）
         │
         └── AsyncTableExecutors
              ├── SnapshotsExpiringExecutor
              ├── OrphanFilesCleaningExecutor
              └── ...
```

---

## 二、OptimizingQueue 核心职责

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/OptimizingQueue.java` (26.9KB)

```
OptimizingQueue 的四大职责:
  1. 接收表状态事件 → 维护待优化表列表
  2. 调度选表 → SchedulingPolicy 选择下一个优化的表
  3. 规划任务 → Planner 生成优化任务列表
  4. 分发任务 → Optimizer 通过 pollTask() 领取任务
```

### 2.1 作为 RuntimeHandlerChain 的事件处理

```java
// OptimizingQueue 继承 RuntimeHandlerChain
public class OptimizingQueue extends RuntimeHandlerChain {

    // 表被添加到 AMS
    @Override
    protected void handleTableAdded(TableRuntime tableRuntime) {
        String groupName = tableRuntime.getOptimizerGroup();
        if (groupName.equals(this.optimizerGroup.getName())) {
            schedulingPolicy.addTable(tableRuntime);
        }
    }

    // 表被移除
    @Override
    protected void handleTableRemoved(TableRuntime tableRuntime) {
        schedulingPolicy.removeTable(tableRuntime);
        // 如果正在优化中 → 取消任务
    }

    // 表状态变更（如从 IDLE → PENDING）
    @Override
    protected void handleStatusChanged(TableRuntime runtime, OptimizingStatus oldStatus) {
        // PENDING 状态的表会被 SchedulingPolicy 选中
    }
}
```

---

## 三、SchedulingPolicy — 表调度策略

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/SchedulingPolicy.java`

### 3.1 核心数据结构

```java
public class SchedulingPolicy {
    private final Map<ServerTableIdentifier, TableRuntime> tableRuntimeMap; // 所有待调度的表
    private volatile String policyName;  // 当前策略名（默认 "quota"）
    private final Lock tableLock;        // 并发保护锁
}
```

### 3.2 scheduleTable — 选表核心逻辑

```java
public TableRuntime scheduleTable(Set<ServerTableIdentifier> skipSet) {
    tableLock.lock();
    try {
        // 1. 构建跳过集合
        fillSkipSet(skipSet);

        // 2. 从剩余表中选择优先级最高的
        return tableRuntimeMap.values().stream()
            .filter(t -> !skipSet.contains(t.getTableIdentifier()))
            .min(createSorterByPolicy())  // ← 比较器
            .orElse(null);
    } finally {
        tableLock.unlock();
    }
}
```

### 3.3 fillSkipSet — 跳过条件

```java
private void fillSkipSet(Set<ServerTableIdentifier> originalSet) {
    long currentTime = System.currentTimeMillis();
    tableRuntimeMap.values().stream()
        .filter(runtime ->
            // 条件1: 不是 PENDING 状态 → 跳过
            !isTablePending(runtime)
            // 条件2: 被 Blocker 阻塞 → 跳过
            || runtime.isBlocked(BlockableOperation.OPTIMIZE)
            // 条件3: 距上次 plan 时间太短 → 跳过
            || currentTime - runtime.getLastPlanTime()
                < runtime.getOptimizingConfig().getMinPlanInterval()
        )
        .forEach(runtime -> originalSet.add(runtime.getTableIdentifier()));
}

// PENDING 判断
private boolean isTablePending(TableRuntime runtime) {
    return runtime.getOptimizingStatus() == OptimizingStatus.PENDING
        && (runtime.getLastOptimizedSnapshotId() != runtime.getCurrentSnapshotId()
            || runtime.getLastOptimizedChangeSnapshotId()
                != runtime.getCurrentChangeSnapshotId());
    // 状态是 PENDING 且 snapshot 有变化 → 真正需要优化
}
```

### 3.4 SorterFactory — SPI 可插拔排序策略

```java
// ServiceLoader 机制加载所有 SorterFactory
static {
    ServiceLoader<SorterFactory> factories = ServiceLoader.load(SorterFactory.class);
    for (SorterFactory f : factories) {
        sorterFactoryCache.put(f.getIdentifier(), f);
    }
}

// 创建比较器
private Comparator<TableRuntime> createSorterByPolicy() {
    SorterFactory factory = sorterFactoryCache.get(policyName);
    return factory.createComparator();
}
```

---

## 四、内置调度策略详解

### 4.1 QuotaOccupySorter — 配额优先（默认）

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/sorter/QuotaOccupySorter.java`

```java
public class QuotaOccupySorter implements SorterFactory {
    public static final String IDENTIFIER = "quota";

    @Override
    public Comparator<TableRuntime> createComparator() {
        return Comparator.comparingDouble(TableRuntime::calculateQuotaOccupy);
    }
}
```

**配额计算逻辑**:

```
quotaOccupy = 实际使用的优化时间 / 分配的配额时间

例如:
  表 A: self-optimizing.quota = 0.1（占 Optimizer 组 10% 的算力）
  Optimizer 组共 100 线程 × 3600 秒 = 360000 线程秒/小时
  表 A 分配配额 = 360000 × 0.1 = 36000 线程秒/小时
  表 A 过去 1 小时实际使用 = 18000 线程秒
  quotaOccupy = 18000 / 36000 = 0.5

quotaOccupy 越小 → 配额空间越大 → 优先调度
quotaOccupy > 1.0 → 超配额 → 降低优先级
```

### 4.2 BalancedSorter — 均衡优先

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/optimizing/sorter/BalancedSorter.java`

```java
public class BalancedSorter implements SorterFactory {
    public static final String IDENTIFIER = "balanced";

    @Override
    public Comparator<TableRuntime> createComparator() {
        // 按上次优化时间排序
        // 最久未优化的表优先
        return Comparator.comparingLong(TableRuntime::getLastPlanTime);
    }
}
```

### 4.3 策略对比

| 策略 | 标识符 | 排序维度 | 适用场景 |
|------|--------|---------|---------|
| **QuotaOccupy** | `quota` | 配额使用率 | 多表共享 Optimizer 组，需要公平调度 |
| **Balanced** | `balanced` | 上次优化时间 | 所有表同等重要，轮流优化 |

### 4.4 配置方式

```
AMS Dashboard → Optimizer Groups → default → Properties
  scheduling-policy = quota  (或 balanced)
```

---

## 五、配额管理机制

### 5.1 Quota 概念

```
Optimizer Group（优化组）:
  ├── 资源: N 个 Optimizer 实例 × M 个线程 = 总算力
  ├── 表 A: quota = 0.1 → 占总算力 10%
  ├── 表 B: quota = 0.3 → 占总算力 30%
  └── 表 C: quota = 0.05 → 占总算力 5%

quota 不是硬限制，而是调度优先级的权重:
  - 用完配额的表优先级降低（但不会停止）
  - 没有其他表需要优化时，超配额的表仍然会被调度
```

### 5.2 配额相关配置

```sql
ALTER TABLE catalog.db.orders SET TBLPROPERTIES (
    'self-optimizing.group' = 'default',   -- Optimizer 组
    'self-optimizing.quota' = '0.1',       -- 配额（0-1）
    'self-optimizing.min-plan-interval' = '60000'  -- 最小计划间隔（ms）
);
```

---

## 六、任务分发流程

### 6.1 pollTask — Optimizer 领取任务

```
Optimizer 通过 Thrift RPC 调用 pollTask():

OptimizingQueue.pollTask()
  │
  ├── 1. 检查是否有已规划的任务（PLANNED 状态）
  │      如果有 → 直接分发最早的任务
  │
  ├── 2. 如果没有待分发任务 → 尝试规划新任务
  │      SchedulingPolicy.scheduleTable(skipSet)
  │      → 选择优先级最高的表
  │
  ├── 3. 为选中的表创建 OptimizingProcess
  │      OptimizingPlanner.plan()
  │      → 评估分区 → 决定 Minor/Major → 生成任务列表
  │
  ├── 4. 持久化任务到数据库
  │      OptimizingMapper.insertProcess()
  │      OptimizingMapper.insertTaskRuntime()
  │
  └── 5. 返回第一个任务给 Optimizer
```

### 6.2 OptimizingStatus 状态机

```
表的优化状态流转:

  IDLE ──(有变更)──→ PENDING ──(被选中)──→ PLANNING
    ↑                                         │
    │                                         ▼
    │                                    COMMITTING
    │                                         │
    └──────────(完成/失败)────────────────────┘

  PLANNING → 正在生成优化计划
  PENDING  → 等待被调度
  IDLE     → 无需优化
  COMMITTING → 正在提交优化结果
```

---

## 七、OptimizerGroup 资源管理

```
┌───────────────────────────────────┐
│       Optimizer Group: default     │
│  ┌─────────────────────────────┐  │
│  │ Properties:                 │  │
│  │   scheduling-policy: quota  │  │
│  │   container: local          │  │
│  │   parallelism: 4            │  │
│  └─────────────────────────────┘  │
│                                   │
│  ┌─────────────────────────────┐  │
│  │ Optimizer 实例:             │  │
│  │   optimizer-1 (4 threads)   │  │
│  │   optimizer-2 (4 threads)   │  │
│  │   optimizer-3 (4 threads)   │  │
│  └─────────────────────────────┘  │
│                                   │
│  ┌─────────────────────────────┐  │
│  │ 注册的表:                   │  │
│  │   orders (quota=0.1)        │  │
│  │   users  (quota=0.3)        │  │
│  │   events (quota=0.05)       │  │
│  └─────────────────────────────┘  │
└───────────────────────────────────┘
```

**Optimizer 容器类型**:

| 类型 | 类 | 说明 |
|------|-----|------|
| Local | `LocalOptimizerContainer` | 本地进程 |
| Flink | `FlinkOptimizerContainer` | Flink Session 集群 |
| Spark | `SparkOptimizerContainer` | Spark Application |
| Kubernetes | `KubernetesOptimizerContainer` | K8s Pod |

---

## 八、运维最佳实践

### 8.1 Optimizer Group 规划

```
小集群（< 50 张表）:
  1 个 default 组，3-5 个 Optimizer 实例

中型集群（50-200 张表）:
  按业务分 2-3 个组：
  - realtime 组（高频写入表，quota 较高）
  - batch 组（离线表，quota 较低）
  - critical 组（核心表，独享资源）

大集群（> 200 张表）:
  按团队/业务线分组
  使用 Flink/K8s 容器动态伸缩
```

### 8.2 配额调优

```
经验值:
  高频写入表（Streaming）: quota = 0.2 ~ 0.5
  中频写入表（每小时 batch）: quota = 0.05 ~ 0.1
  低频写入表（每天 batch）: quota = 0.01 ~ 0.05

监控:
  AMS Dashboard → Optimizer Groups → 查看各表的配额使用率
  quotaOccupy 持续 > 1.0 → 需要增加 Optimizer 或提高 quota
```

### 8.3 故障诊断

```
问题: 表长时间处于 PENDING 状态
  排查:
  1. Optimizer 存活? → Dashboard → Optimizers
  2. Group 匹配? → 表的 self-optimizing.group vs Optimizer 注册的 group
  3. 配额耗尽? → 其他高配额表占用了所有资源
  4. Blocker 阻塞? → 其他操作持有表的 Blocker
  5. 最小间隔? → self-optimizing.min-plan-interval 过大

问题: 优化任务频繁失败
  排查:
  1. Optimizer 日志 → OOM / 网络超时
  2. 数据文件权限 → Hadoop/S3 权限问题
  3. 表元数据损坏 → metadata.json 不可读
```
