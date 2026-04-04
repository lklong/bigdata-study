# Spark 3.5.1 源码深度学习笔记

> 学习方法论：Eric 源码精通方法论 v2.0 — 科学家级别（九大法则 + 四段位 + 90天路线图）
> 
> 目标：从"能用"到"精通"到"创造"，成为源码级科学家

## 目录

| 模块 | 优先级 | 文档 | 核心能力 |
|------|--------|------|---------|
| [学习方法论 v2.0](./00-学习方法论-v2.md) | — | 完成 | 九大法则+四段位+90天路线图 |
| [全局架构地图](./05-全局架构地图.md) | P0 | 完成 | 核心类速查+SQL流水线+Shuffle架构+调度三层+场景清单 |
| [内存管理](./01-memory-management.md) | P0 | 完成 | 解决 OOM、内存泄漏、堆外溢出 |
| [Shuffle](./02-shuffle.md) | P0 | 完成 | 解决 FetchFailed、Shuffle 倾斜、磁盘打满 |
| [调度系统](./03-scheduler.md) | P1 | 完成 | 解决 Task 卡死、Stage 重试、黑名单 |
| [SQL/Catalyst/AQE](./04-sql-catalyst-aqe.md) | P1 | 完成 | 解决执行计划不优、数据倾斜、AQE 异常 |

## 快速排障索引

### 按报错信息定位

| 报错关键词 | 对应模块 | 快速定位 |
|-----------|---------|---------|
| `OutOfMemoryError` | 内存管理 | `UnifiedMemoryManager` / `MemoryStore` |
| `FetchFailedException` | Shuffle | `ShuffleBlockFetcherIterator.throwFetchFailedException` |
| `OutOfDirectMemoryError` | Shuffle/内存 | Netty 堆外内存 / `ShuffleBlockFetcherIterator.onBlockFetchFailure` |
| `Stage cancelled` / `Task failed N times` | 调度 | `TaskSetManager.handleFailedTask` |
| `Will not store X as the required space exceeds` | 内存管理 | `UnifiedMemoryManager.acquireStorageMemory` |
| `TID X waiting for at least 1/2N` | 内存管理 | `ExecutionMemoryPool.acquireMemory` |
| `Skewed partition detected` | AQE | `OptimizeSkewedJoin` |

### 按线上场景定位

| 场景 | 推荐阅读顺序 |
|------|-------------|
| Executor OOM | 内存管理 → Shuffle(spill机制) |
| Driver OOM | 内存管理(广播变量/collect) |
| 任务执行慢 | AQE(数据倾斜) → Shuffle(流控) → 调度(推测执行) |
| 任务卡死不动 | 调度(HealthTracker/Barrier) → 内存管理(ExecutionPool wait) |
| Stage 反复失败 | 调度(FetchFailed重试) → Shuffle(数据损坏) |
| Shuffle 文件丢失 | Shuffle(IndexShuffleBlockResolver) → 调度(executorLost) |

## 源码版本

- **Spark**: 3.5.1 (tag: v3.5.1)
- **源码路径**: `/Users/kailongliu/CodeBuddy/20260401235241/spark-source/`
