# Spark 06 — Shuffle 写入全链路与三种 ShuffleWriter 源码深度分析

> 源码版本：Apache Spark 4.0.0-SNAPSHOT（本地路径 `/Users/kailongliu/bigdata/txProjects/spark/`）
> 分析日期：2026-04-27
> 作者：Eric（豹纹） | 大哥的 SRE AI 专家团队

---

## 一、概述

Spark 的 Shuffle 是分布式计算的核心机制，也是性能瓶颈和故障高发区。本篇从源码层面深度剖析 **Shuffle Write 侧**的完整链路：

1. **ShuffleManager** — 可插拔的 Shuffle 管理接口
2. **SortShuffleManager** — 默认实现，根据条件选择 Writer
3. **三种 ShuffleWriter** — SortShuffleWriter / BypassMergeSortShuffleWriter / UnsafeShuffleWriter
4. **TaskSetManager** — Task 调度与本地性管理
5. **写入路径选择决策树** — 什么条件下选哪个 Writer

---

## 二、ShuffleManager — 可插拔接口

### 2.1 源码定位

**文件**：`core/.../shuffle/ShuffleManager.scala`

```scala
private[spark] trait ShuffleManager {
  def registerShuffle[K, V, C](shuffleId: Int, dependency: ShuffleDependency[K, V, C]): ShuffleHandle
  def getWriter[K, V](handle: ShuffleHandle, mapId: Long, context: TaskContext, metrics): ShuffleWriter[K, V]
  def getReader[K, C](handle, startMapIndex, endMapIndex, startPartition, endPartition, context, metrics): ShuffleReader[K, C]
  def unregisterShuffle(shuffleId: Int): Boolean
  def shuffleBlockResolver: ShuffleBlockResolver
  def stop(): Unit
}
```

**设计要点**：
- 通过 `spark.shuffle.manager` 配置，默认为 `sort`（即 `SortShuffleManager`）
- `registerShuffle` 返回 `ShuffleHandle`，不同 Handle 类型决定后续使用哪个 Writer
- Celeborn / Uniffle 等外部 Shuffle Service 就是通过实现 `ShuffleManager` 接口接入的

---

## 三、SortShuffleManager — Writer 选择决策

### 3.1 三种 ShuffleHandle

| Handle 类型 | 对应 Writer | 选择条件 |
|------------|------------|---------|
| `BypassMergeSortShuffleHandle` | `BypassMergeSortShuffleWriter` | 无 map 端聚合 **且** 分区数 ≤ `spark.shuffle.sort.bypassMergeThreshold`（默认 200） |
| `SerializedShuffleHandle` | `UnsafeShuffleWriter` | 序列化器支持 relocate **且** 无 map 端聚合 **且** 分区数 ≤ 16M |
| `BaseShuffleHandle` | `SortShuffleWriter` | 其他所有情况（兜底） |

### 3.2 决策流程图

```
ShuffleDependency 注册
    │
    ├─ mapSideCombine = true? ────YES──→ BaseShuffleHandle (SortShuffleWriter)
    │                                     ↑ 需要 map 端 aggregation
    │
    ├─ numPartitions ≤ 200? ─────YES──→ BypassMergeSortShuffleHandle
    │   (bypassMergeThreshold)           ↑ 小分区数，直接写多文件
    │
    ├─ serializer.supportsRelocationOf   
    │   SerializedObjects?       YES──→ SerializedShuffleHandle (UnsafeShuffleWriter)
    │   && numPartitions ≤ 16M          ↑ 序列化数据直接排序，高效
    │
    └─ 其他 ─────────────────────────→ BaseShuffleHandle (SortShuffleWriter)
                                        ↑ 通用兜底方案
```

---

## 四、SortShuffleWriter — 通用排序写入

### 4.1 源码定位

**文件**：`core/.../shuffle/sort/SortShuffleWriter.scala`

### 4.2 write() 核心流程

```scala
override def write(records: Iterator[Product2[K, V]]): Unit = {
  // 1. 创建 ExternalSorter
  sorter = if (dep.mapSideCombine) {
    new ExternalSorter[K, V, C](context, dep.aggregator, Some(dep.partitioner), dep.keyOrdering, dep.serializer)
  } else {
    new ExternalSorter[K, V, V](context, aggregator = None, Some(dep.partitioner), ordering = None, dep.serializer)
  }

  // 2. 将所有记录插入 Sorter（可能触发 spill）
  sorter.insertAll(records)

  // 3. 创建 MapOutputWriter
  val mapOutputWriter = shuffleExecutorComponents.createMapOutputWriter(dep.shuffleId, mapId, numPartitions)

  // 4. 按分区写出排序后的数据
  sorter.writePartitionedMapOutput(dep.shuffleId, mapId, mapOutputWriter)

  // 5. 提交所有分区，获取各分区长度
  partitionLengths = mapOutputWriter.commitAllPartitions(sorter.getChecksums).getPartitionLengths

  // 6. 构造 MapStatus（包含 shuffle 块的位置和大小信息）
  mapStatus = MapStatus(blockManager.shuffleServerId, partitionLengths, mapId)
}
```

### 4.3 ExternalSorter 内部机制

```
records → PartitionedAppendOnlyMap/PartitionedPairBuffer
              │
              ├─ 内存不足? → spill 到磁盘（临时文件）
              │               排序：先按 partitionId，再按 key（如果有 keyOrdering）
              │
              └─ 最终 → merge 所有 spill 文件 + 内存数据 → 单个输出文件
```

**关键参数**：
- `spark.shuffle.spill.initialMemoryThreshold`（默认 5MB）：初始内存阈值
- `spark.shuffle.sort.bypassMergeThreshold`（默认 200）：bypass 阈值
- `spark.shuffle.spill.compress`（默认 true）：spill 文件是否压缩

### 4.4 适用场景

- 有 `mapSideCombine`（如 `reduceByKey`）
- 分区数较多（> 200）且序列化器不支持 relocation
- **最通用但性能中等**

---

## 五、BypassMergeSortShuffleWriter — 小分区快速写入

### 5.1 源码定位

**文件**：`core/src/main/java/.../shuffle/sort/BypassMergeSortShuffleWriter.java`

### 5.2 核心设计

```
records → 按 partitionId 直接写入对应分区文件
              │
              partitionWriters[0] → tmp-file-0
              partitionWriters[1] → tmp-file-1
              ...
              partitionWriters[N] → tmp-file-N
              │
              └─ 最终 → concatenate 所有分区文件 → 单个输出文件 + 索引文件
```

**关键源码注释**：
```java
/**
 * This write path writes incoming records to separate files, one file per reduce partition,
 * then concatenates these per-partition files to form a single output file.
 * Records are not buffered in memory.
 */
```

### 5.3 选择条件

```java
// SortShuffleWriter.shouldBypassMergeSort()
def shouldBypassMergeSort(conf: SparkConf, dep: ShuffleDependency[_, _, _]): Boolean = {
  if (dep.mapSideCombine) false                              // 有 map 端聚合则不能 bypass
  else dep.partitioner.numPartitions <= bypassMergeThreshold // 分区数不超过阈值
}
```

### 5.4 优缺点

| 优点 | 缺点 |
|------|------|
| **不需要排序**，直接按分区写入 | 同时打开 N 个文件描述符（N = 分区数） |
| **不需要反序列化**，数据直写 | 分区数大时文件描述符耗尽 |
| 实现简单，无内存压力 | 分区数大时 concatenate 耗时 |
| 适合小分区数场景 | 不支持 map 端聚合 |

### 5.5 适用场景

- `repartition(10)` / `coalesce(5)`
- 小分区数的 `groupBy` / `join`（无 map 端聚合）

---

## 六、UnsafeShuffleWriter — Tungsten 高性能写入

### 6.1 源码定位

**文件**：`core/src/main/java/.../shuffle/sort/UnsafeShuffleWriter.java`

### 6.2 核心设计

```
records → serialize → ShuffleExternalSorter (unsafe memory)
              │
              ├─ 利用 Tungsten 内存管理，直接操作二进制数据
              ├─ 排序时只移动指针（8 bytes），不移动数据本身
              ├─ 内存不足 → spill 到磁盘
              │
              └─ merge spills → 单个输出文件 + 索引文件
```

### 6.3 关键优化

1. **序列化数据直接排序**：不需要反序列化，排序的是 (partitionId, 数据指针) 的 8 字节记录
2. **基数排序**：`ShuffleExternalSorter` 使用 `RadixSort` 对 partition ID 排序，O(n) 时间复杂度
3. **Page-based 内存管理**：通过 `TaskMemoryManager` 的 Page 机制管理 off-heap 内存
4. **单次 spill 合并**：如果只有一次 spill，使用 `SingleSpillShuffleMapOutputWriter` 直接传输，避免额外拷贝

### 6.4 选择条件

```
serializer.supportsRelocationOfSerializedObjects = true  // KryoSerializer ✅, JavaSerializer ❌
&& !dep.mapSideCombine                                   // 无 map 端聚合
&& numPartitions <= 16,777,216 (2^24)                    // 分区数限制（指针编码限制）
```

### 6.5 性能对比

| 维度 | SortShuffleWriter | BypassMerge | UnsafeShuffleWriter |
|------|-------------------|-------------|---------------------|
| 排序方式 | 反序列化对象排序 | 不排序 | 序列化数据指针排序 |
| 内存效率 | 中（Java 对象） | 低（多文件 IO） | 高（Tungsten 二进制） |
| GC 压力 | 高（大量对象） | 低 | **极低**（off-heap） |
| 适用分区数 | 无限制 | ≤ 200 | ≤ 16M |
| map 端聚合 | ✅ | ❌ | ❌ |
| 排序复杂度 | O(n log n) | O(1) | **O(n)**（基数排序） |

---

## 七、TaskSetManager — Task 调度与本地性

### 7.1 源码定位

**文件**：`core/.../scheduler/TaskSetManager.scala`

### 7.2 核心职责

```
TaskSetManager:
├─ 管理一个 TaskSet 中所有 Task 的调度
├─ 维护每个 Task 的状态（pending/running/successful/failed）
├─ 实现本地性感知调度（Locality-Aware Scheduling）
├─ 处理 Task 失败重试（最多 maxTaskFailures 次）
└─ 推测执行（Speculation）管理
```

### 7.3 本地性级别

```scala
// 优先级从高到低
PROCESS_LOCAL  → 数据在同一 Executor 的 BlockManager 中
NODE_LOCAL     → 数据在同一节点的其他 Executor 或 HDFS DataNode
RACK_LOCAL     → 数据在同一机架
ANY            → 数据在任意位置
```

### 7.4 延迟调度（Delay Scheduling）

```
当前本地性级别 = PROCESS_LOCAL
    │
    ├─ 有 PROCESS_LOCAL 的 pending task? → 调度
    │
    └─ 没有，等待 localityWait 时间
         │
         └─ 超时 → 降级到 NODE_LOCAL → 继续...
```

**关键参数**：
- `spark.locality.wait`（默认 3s）：每级本地性的等待时间
- `spark.locality.wait.process`：PROCESS_LOCAL 等待时间
- `spark.locality.wait.node`：NODE_LOCAL 等待时间
- `spark.locality.wait.rack`：RACK_LOCAL 等待时间

### 7.5 推测执行

```scala
val speculationEnabled = conf.get(SPECULATION_ENABLED)          // 默认 false
val speculationQuantile = conf.get(SPECULATION_QUANTILE)        // 默认 0.75
val speculationMultiplier = conf.get(SPECULATION_MULTIPLIER)    // 默认 1.5
```

当 75% 的 Task 完成后，如果某个 Task 的运行时间超过已完成 Task 中位时间的 1.5 倍，则启动推测执行副本。

---

## 八、Shuffle Write 全链路串联

```
DAGScheduler.submitMissingTasks()
    │
    ▼
TaskSchedulerImpl.submitTasks()
    │
    ▼
TaskSetManager.addPendingTasks()  ← 按本地性分组
    │
    ▼
CoarseGrainedSchedulerBackend.makeOffers()
    │
    ▼
TaskSetManager.resourceOffer()  ← 延迟调度
    │
    ▼
TaskRunner.run() [Executor 端]
    │
    ▼
ShuffleMapTask.runTask()
    │
    ├─ writer = shuffleManager.getWriter(handle, mapId, context, metrics)
    │      │
    │      ├─ BypassMergeSortShuffleHandle  → BypassMergeSortShuffleWriter
    │      ├─ SerializedShuffleHandle       → UnsafeShuffleWriter
    │      └─ BaseShuffleHandle             → SortShuffleWriter
    │
    ├─ writer.write(rdd.iterator(partition, context))
    │      │
    │      ├─ 数据从 RDD partition 流入
    │      ├─ 按分区排序/分组
    │      ├─ 可能 spill 到磁盘
    │      └─ 写出单个 shuffle 文件 + 索引文件
    │
    └─ writer.stop(success=true) → 返回 MapStatus
           │
           └─ MapStatus 包含: (BlockManagerId, partitionLengths[])
                  │
                  └─ 回传给 Driver 的 MapOutputTracker
```

---

## 九、运维关键参数速查

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.shuffle.manager` | `sort` | Shuffle 管理器实现 |
| `spark.shuffle.sort.bypassMergeThreshold` | `200` | Bypass 模式分区数阈值 |
| `spark.shuffle.compress` | `true` | Shuffle 输出是否压缩 |
| `spark.shuffle.spill.compress` | `true` | Spill 文件是否压缩 |
| `spark.io.compression.codec` | `lz4` | 压缩编码器 |
| `spark.shuffle.file.buffer` | `32k` | 文件写入缓冲区 |
| `spark.reducer.maxSizeInFlight` | `48m` | Reduce 端每次拉取的最大数据量 |
| `spark.shuffle.io.maxRetries` | `3` | Shuffle 数据拉取失败重试次数 |
| `spark.shuffle.io.retryWait` | `5s` | 重试间隔 |
| `spark.shuffle.maxChunksBeingTransferred` | `Long.MAX` | 同时传输的最大 chunk 数 |
| `spark.locality.wait` | `3s` | 本地性等待时间 |
| `spark.speculation` | `false` | 是否启用推测执行 |

---

## 十、踩坑记录与调优建议

### 10.1 常见问题

1. **Shuffle Write OOM**：`SortShuffleWriter` 的 `ExternalSorter` 在 `insertAll()` 阶段可能因为数据倾斜导致某个 partition 数据过大。解决：增大 `spark.shuffle.spill.initialMemoryThreshold` 或使用 `repartition` 打散数据。

2. **Too Many Open Files**：`BypassMergeSortShuffleWriter` 同时打开 N 个文件。如果分区数 > 200（或 ulimit 设置较低），可能触发文件描述符耗尽。解决：调低 `bypassMergeThreshold` 或增大 ulimit。

3. **Shuffle Fetch Failed**：Shuffle 文件损坏或 Executor 被 kill。解决：增大 `spark.shuffle.io.maxRetries`，启用 External Shuffle Service。

### 10.2 选择策略建议

| 场景 | 推荐 Writer | 调优方向 |
|------|------------|---------|
| 小分区数、无聚合 | Bypass | 保持 `bypassMergeThreshold ≥ 分区数` |
| 大数据量、有聚合 | Sort | 增大 Executor 内存 |
| 大数据量、无聚合 | Unsafe | 使用 KryoSerializer（支持 relocate） |
| 数据倾斜严重 | Sort + AQE | 启用 `spark.sql.adaptive.enabled` |

---

## 十一、跨项目同构对比

| 特性 | Spark Shuffle | Flink Network Shuffle | MapReduce Shuffle |
|------|--------------|----------------------|-------------------|
| 写入排序 | ✅ Sort-based | ❌ Pipeline | ✅ Sort-based |
| 内存管理 | Tungsten off-heap | Network Buffer Pool | JVM heap |
| Spill 策略 | 按阈值 spill | 反压（Backpressure） | 按百分比 spill |
| 可插拔 | ✅ ShuffleManager | ✅ ShuffleMaster | ❌ 固定 |
| 外部 Shuffle | ESS / Celeborn | Celeborn / Flink RSS | 无 |
| 压缩 | 可配置 | 可配置 | 可配置 |

---

> **认知更新**：Spark Shuffle Write 的三条路径本质上是**空间-时间-GC** 三维的不同权衡：Bypass 用空间（多文件）换时间（无排序）；Sort 用时间（O(n log n)）保通用性；Unsafe 用 Tungsten 内存管理避开 GC，实现最优性能。理解这个权衡框架后，调优策略就很清晰了。
