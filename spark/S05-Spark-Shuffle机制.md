# Spark Shuffle 机制源码分析

> Eric 源码分析 | 基于 Spark txProjects (2026-05-09)
> 法则：逆向工程 + 分形剥离（L1 接口层 → L2 主链路层 → L3 异常边界层）

---

## 一、Shuffle 的定位：跨 Stage 数据交换

Shuffle 是 Spark 中最昂贵的操作——它跨越 DAG Stage 边界，将上游 ShuffleMapTask 的输出重新分区后供下游 Stage 使用。理解 Shuffle 就是理解 Spark 为什么需要"分 stage"的核心原因。

```
Stage 0 (ShuffleMapStage)           Stage 1 (ShuffleMapStage)           Stage 2 (ResultStage)
┌─────────────────┐                ┌─────────────────┐                ┌─────────────────┐
│ Task 0 → Part0  │───┐           │ Task 0 → Part0  │───┐           │ Task 0 → Part0  │
│ Task 1 → Part1  │   │           │ Task 1 → Part1  │   │           │ Task 1 → Part1  │
│ Task 2 → Part2  │   └──── Shuffle ──→ Fetch ─┘   └──── Shuffle ──→ Fetch ─┘   └──── Action
└─────────────────┘                └─────────────────┘                └─────────────────┘
     Map Phase                         Map Phase                        Reduce Phase
```

**关键度量**（类比迁移，参考 OS 调度器）：
- Shuffle ≈ 网络 I/O + 磁盘 I/O + 序列化三重开销
- ShuffleMapStage 的 `isAvailable` 标志 = "Map 输出就绪" = 下游可以开始 Fetch
- Push-based Shuffle = "Map 数据主动推送" vs Pull-based = "Reducer 主动拉取"

---

## 二、SortShuffleManager：Shuffle 的总调度

### 2.1 入口：registerShuffle + getWriter

```scala
// SortShuffleManager.scala:95
override def registerShuffle[K, V, C](shuffleId: Int, dependency: ShuffleDependency[K, V, C]): ShuffleHandle = {
  if (SortShuffleWriter.shouldBypassMergeSort(conf, dependency)) {
    // 分区数 < spark.shuffle.sort.bypassMergeThreshold(200) 且无 map-side 聚合
    new BypassMergeSortShuffleHandle(...)
  } else if (SortShuffleWriter.shouldUseSortShuffleWriter(conf, dependency)) {
    // 普通 SortShuffle（超过阈值或有聚合）
    new BaseShuffleHandle(...)
  } else {
    // Serializer 支持序列化排序 → SerializedSortedShuffleWriter
    new SerializedShuffleHandle(...)
  }
}
```

**三条写入路径**：

| 路径 | 触发条件 | 特点 |
|------|---------|------|
| BypassMergeSort | 分区数 < 200 && 无聚合 | 每个分区写一个文件，最后 concat，性能最优 |
| SortShuffleWriter | 普通情况 | 全局排序，按 partitionId 写溢出文件 |
| SerializedSortedShuffleWriter | Serializer 支持 relocation && 分区数 < 16M | 序列化排序，内存效率最高，GC 最友好 |

### 2.2 三种 ShuffleHandle 的关系

```scala
// ShuffleHandle 继承链
sealed trait ShuffleHandle
  ├→ BaseShuffleHandle      // 普通 ShuffleHandle
  ├→ BypassMergeSortShuffleHandle  // bypass 优化
  └→ SerializedShuffleHandle      // 序列化排序
```

**核心判断逻辑**（`shouldBypassMergeSort`）：

```scala
// SortShuffleWriter.shouldBypassMergeSort()
conf.get(config.SHUFFLE_SORT_BYPASS_MERGE_THRESHOLD).foreach { threshold =>
  dependency.partitioner.numPartitions <= threshold
} && 
dependency.mapSideCombine == false   // 无 map-side 聚合
&& !dependency.aggregator.isDefined // 无聚合器
```

---

## 三、SortShuffleWriter：排序写入核心

### 3.1 写入流程

```
write() 
  → insertAll(records) 
    → [每条记录] → partitioner.getPartition(record) 
                    → Serializer（如需要 spill）→ ShuffleExternalSorter.insertRecord()
    → [内存阈值触发] → spill() → PartitionedAppendOnlyMap / PartitionedPairs
  → writePartitionedFile() → 合并溢出文件 + 写索引
  → getMetadataWriter().commit(success)
```

### 3.2 ShuffleExternalSorter：内存溢出控制器

**核心职责**：在内存中排序记录，超出阈值时溢出到磁盘。

```scala
class ShuffleExternalSorter {
  // 内存分配
  private val numBytesForPartitioning = PartitionedPairBuffer.estimateSize(P)
  
  // 核心数据结构（两种模式）
  private var sorter: PartitionedPairs = _
  // 1. 序列化模式：PartitionedPairBuffer[Long, Long]（8 bytes/record，cache 友好）
  // 2. 普通模式：PartitionedAppendOnlyMap[K, V]（对象模式）
  
  def insertRecord(record: AnyRef, partitionId: Int): Unit = {
    // 序列化后写入 buffer
    if (sorter.numRecords >= ShuffleExternalSorter.RECORDS_PER_LOAD) {
      sorter.spill()    // 溢出到磁盘
      sorter = newPartitionedPairs()
    }
    sorter.insert(key, partitionId, value)
  }
}
```

**关键参数**（由 `spark.shuffle.memoryFraction` 控制）：
- `SHUFFLE_SORT_BYPASS_MERGE_THRESHOLD = 200`：BypassMergeSort 分区数阈值
- `SHUFFLE_MEMORYFraction`：Shuffle 使用占总堆内存比例

### 3.3 writePartitionedFile：文件合并

```scala
// SortShuffleWriter.scala
private def writePartitionedFile(...): (Array[File], Array[Long]) = {
  val outputFile = blockManager.diskBlockManager.getFile(...)
  val writer = new ShuffleIndexOutputWriter(...)
  
  // 1. 如有溢出文件：依次 mergeSpillFiles()
  //    - 归并排序：多路归并溢出文件，按 partitionId 分区聚合
  //    - 支持 NIO transferTo 零拷贝合并
  // 2. 如无溢出：直接 writeSortedFile()
  // 3. 生成 .index 文件（partition 起始偏移量）
  
  (outputBlocks, partitionLengths)
}
```

---

## 四、ShuffleMapTask：Map 端执行体

### 4.1 run() 方法：Task 层执行

```scala
// ShuffleMapTask.scala
override def runTask(context: TaskContext): Unit = {
  val (rdd, shuffleDep) = deserializeBroadcast(taskBinary.value, ...)
  val shuffleManager = SparkEnv.get.shuffleManager
  val shuffleHandle = shuffleManager.registerShuffle(shuffleId, shuffleDep)
  val writer = shuffleManager.getWriter(shuffleHandle, partitionId, ...)
  
  // 触发 RDD.compute()，在 compute() 中调用 writer.write()
  writer.write(rdd.iterator(partition, context).toSeq)
  writer.stop(success = true)
}
```

**核心流程**：

```
ShuffleMapTask.runTask()
  1. 反序列化 (rdd, shuffleDep)
  2. 注册 ShuffleHandle（获取 ShuffleWriter）
  3. 调用 rdd.iterator(partition, context) → 执行用户代码 + 写入 Shuffle
     └→ rdd.compute() → 遍历父 RDD partition → map/filter/... → writer.write(record)
  4. stop(success = true) → 提交 meta 到 MapOutputTracker
```

### 4.2 MapOutputTracker：元数据注册

Task 完成后，`MapOutputTrackerMaster` 记录每个 map 输出块的位置：

```scala
// MapOutputTracker.scala
def registerMapOutput(shuffleId: Int, mapId: Int, status: MapStatus): Unit = {
  mapStatuses.put(shuffleId, mapStatuses.getOrElse(shuffleId, ArrayBuffer()) += status)
}
```

**Reducer 通过 MapOutputTracker 获知从哪些 Executor fetch 数据**。

---

## 五、ShuffleBlockResolver：读取与索引

### 5.1 IndexShuffleBlockResolver

```scala
// IndexShuffleBlockResolver.scala
// Shuffle 数据布局：
// /tmp/
//   shuffle_${shuffleId}/
//     block_${mapId}_${reduceId}_${data}.data   ← 数据文件（连续分区）
//     block_${mapId}_${reduceId}_${index}.data  ← 索引文件（分区偏移量）
```

**索引文件格式**：

```
[index file, 每 8 bytes 一个分区]
Offset[0] = 数据文件起始位置
Offset[1] = Partition 0 结束位置 / Partition 1 起始位置
Offset[2] = Partition 1 结束位置 / Partition 2 起始位置
...
```

Reducer fetch 时，直接通过 Offset[i] 和 Offset[i+1] 计算读取范围，O(1) 定位，避免全表扫描。

---

## 六、Push-Based Shuffle（DAGScheduler 中的关键逻辑）

### 6.1 核心区别

| 特性 | Pull-Based（传统） | Push-Based |
|------|------------------|-----------|
| 数据流向 | Reducer 主动拉取 | Mapper 主动推送 |
| Map 输出 | 写入本地磁盘 | 先推送到 Merger（Reducer 侧） |
| Merge 节点 | 无 | ExternalShuffleService 充当 Merger |
| 优点 | 实现简单 | 减少 Reducer 侧网络连接数，减少 shuffle 文件数 |
| 关键判断 | `spark.shuffle.push.enabled = true` | `spark.shuffle.manager = sort` |

### 6.2 DAGScheduler 中的 Push-Shuffle 逻辑

```scala
// DAGScheduler.scala:1371
prepareShuffleServicesForShuffleMapStage(stage: ShuffleMapStage): Unit = {
  // 为 push-based shuffle 设置 merger 位置
  val mergerLocs = sc.schedulerBackend.getShufflePushMergerLocations(
    stage.shuffleDep.partitioner.numPartitions, stage.resourceProfileId)
  stage.shuffleDep.setMergerLocs(mergerLocs)
}
```

在 `getMissingParentStages` 中，即使 `mapStage.isAvailable`，如果 `shuffleMergeFinalized` 为 false（merge 结果未最终化），Stage 仍标记为 missing，强制等待 merge 完成。

---

## 七、关键参数表

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `spark.shuffle.sort.bypassMergeThreshold` | 200 | BypassMergeSort 触发阈值 |
| `spark.shuffle.spill` | true | 允许溢出（不可关闭） |
| `spark.shuffle.compress` | true | 压缩 shuffle 输出 |
| `spark.shuffle.push.enabled` | false | 启用 Push-Based Shuffle |
| `spark.shuffle.push.merge.enabled` | true | Push 完成后自动 merge |
| `spark.shuffle.manager` | sort | Shuffle Manager 类型 |

---

## 八、异常边界层（L3 对抗性思考）

### 8.1 Serializer 不支持 relocation 的陷阱

源码注释中明确提到 Serialized Sorting 需要 Serializer 支持 relocation：
> "the shuffle serializer supports relocation of serialized values (this is currently supported by KryoSerializer and Spark SQL's custom serializers)"

如果使用默认的 Java Serializer，序列化的对象无法原地重排序，SortShuffleWriter 会回退到 Deserialized Sorting，内存和 GC 压力会显著增加。

### 8.2 Shuffle 溢出文件过多时的性能劣化

当 shuffle 数据量极大时，`writePartitionedFile()` 归并排序会打开大量文件描述符。如果 `ulimit -n` 不足，会导致 `Too many open files` 错误。

### 8.3 MapOutputTracker 内存膨胀

`mapStatuses` 是一个全 ActorSystem 共享的 HashMap，存储所有 Mapper 的 BlockLocation。每个 Shuffle Map Task 完成后注册一次，大规模 Shuffle（如 10000 个 Mapper）时元数据内存占用显著。

### 8.4 ShuffleMapTask 失败的 Stage 重试场景

当 ShuffleMapTask 因 ExecutorLost 而失败时：
1. DAGScheduler 检测到 FetchFailure 或 Task 失败
2. 标记 `failedStages += stage`
3. `submitStage` 被重新触发，但 `mapStage.isAvailable = false`（因为 map 输出可能不完整）
4. **关键**：`increaseAttemptIdOnFirstSkip()` 确保 StageAttemptId 推进，防止旧 attempt 的 output 被下游错误消费

---

## 九、类比迁移：Spark Shuffle vs OS 调度器

| Spark Shuffle | OS Process Scheduler |
|--------------|---------------------|
| ShuffleMapTask | Producer Process |
| ResultTask | Consumer Process |
| MapOutputTracker | 进程状态表 |
| ShuffleBlockResolver | 文件系统 inode |
| Spill Files | Swap Files |
| ShuffleWriter | write() syscall |
| ShuffleReader | read() syscall |
| SortShuffle | O(n log n) 排序 → 减少 merge 次数 |
| Push-based Shuffle | 消息队列的主动推送模式 |

---

## 十、源码关键路径

```
ShuffleMapTask.runTask()
  → ShuffleManager.getWriter()
       → SortShuffleWriter.write()
            → ShuffleExternalSorter.insertRecord()
                 ├→ [不溢出] → PartitionedPairBuffer
                 └→ [溢出]   → spill() → write partition to disk
            → writePartitionedFile()
                 → mergeSpillFiles() / writeSortedFile()
                 → IndexShuffleBlockResolver 写 .data + .index
  → writer.stop(success=true)
       → MapOutputTrackerMaster.registerMapOutput()
```

---

*文档路径：Spark/S05-Spark-Shuffle机制.md*
*来源：txProjects/spark/core/src/main/scala/org/apache/spark/shuffle/sort/SortShuffleManager.scala + ShuffleMapTask.scala*
