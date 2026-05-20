# Spark Shuffle 引擎源码深度解析（SortShuffleManager + Reader/Writer 全链路）

> 版本: Spark 3.4 系
> 源码路径: `/Users/kailongliu/bigdata/txProjects/spark`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

Spark Shuffle 是所有 Spark 性能调优的核心战场：
- 为什么 SortShuffle 取代了 HashShuffle？
- `BypassMergeSortShuffleWriter` / `UnsafeShuffleWriter` / `SortShuffleWriter` 三种 writer 各自适用什么场景？是怎么自动选的？
- ShuffleReader 怎么从远端 fetch 数据？怎么实现 spill / aggregator / sorter？
- Shuffle Push 模式（SPIP-30602）的入口在哪？

理解 Shuffle 是排查"Spark Stage 慢/Shuffle Fetch Failed/磁盘 IO 飙高/Executor OOM"等所有 shuffle 侧问题的前置。

## 二、调用链总图

```
[Driver 端]
DAGScheduler.submitMissingTasks(stage)
   │
   ▼
ShuffleMapStage 创建 ShuffleMapTask × N (N = mapper 数)
   │
   ▼  TaskScheduler 调度到 Executor
[Executor 端]
ShuffleMapTask.runTask
   │
   ▼
反序列化 (RDD, ShuffleDependency)
   │
   ▼
dep.shuffleWriterProcessor.write(rdd, dep, mapId, context, partition)
   │
   ▼
SparkEnv.shuffleManager.getWriter(handle, mapId, context, metrics)
   │ ← 三种 ShuffleHandle → 三种 ShuffleWriter
   ▼
   ┌──────────────────────────┬────────────────────────────┬─────────────────────┐
   ▼                          ▼                            ▼                     │
SerializedShuffleHandle  BypassMergeSortShuffleHandle   BaseShuffleHandle        │
   │                          │                            │                     │
   ▼                          ▼                            ▼                     │
UnsafeShuffleWriter     BypassMergeSortShuffleWriter   SortShuffleWriter         │
   │                          │                            │                     │
   ▼                          ▼                            ▼                     │
ShuffleExternalSorter   per-partition writer × N       ExternalSorter            │
(off-heap, page-based)  (无 sort, 直接写)              (in-memory + spill)       │
   │                          │                            │                     │
   └──────────────────────────┴─────────────┬──────────────┘                     │
                                            │                                    │
                                            ▼                                    │
                          IndexShuffleBlockResolver                              │
                          写 shuffle_<sId>_<mId>_0.data + .index                 │
                          通过 fadvise 提示内核                                   │
                                            │                                    │
                                            ▼                                    │
                          MapStatus 上报给 Driver MapOutputTracker               │
                                                                                 │
                                                                                 │
[下游 Stage Task]                                                                │
ResultTask / ShuffleMapTask 启动 Reader                                          │
   │                                                                             │
   ▼                                                                             │
SortShuffleManager.getReader → BlockStoreShuffleReader                           │
   │                                                                             │
   ▼                                                                             │
ShuffleBlockFetcherIterator (Netty fetch)                                        │
   │   └─ 远端 BlockManagerNettyServer 走 Netty + ZeroCopy 读 .data 文件         │
   ▼                                                                             │
[Reader 端处理链]                                                                │
deserializerStream → Aggregator (combineByKey) → ExternalSorter (sort)           │
   │                                                                             │
   ▼                                                                             │
最终 Iterator[Product2[K, C]] 给上层 RDD 算子                                    │
```

## 三、关键源码逐段精读

### 3.1 入口：ShuffleMapTask.runTask

`ShuffleMapTask.scala:77-100`：

```scala
override def runTask(context: TaskContext): MapStatus = {
    // ① 反序列化 RDD + ShuffleDependency
    val deserializeStartTimeNs = System.nanoTime()
    val ser = SparkEnv.get.closureSerializer.newInstance()
    val rddAndDep = ser.deserialize[(RDD[_], ShuffleDependency[_, _, _])](
      ByteBuffer.wrap(taskBinary.value), Thread.currentThread.getContextClassLoader)
    _executorDeserializeTimeNs = System.nanoTime() - deserializeStartTimeNs

    val rdd = rddAndDep._1
    val dep = rddAndDep._2

    // ② mapId 计算（兼容老协议）
    val mapId = if (SparkEnv.get.conf.get(config.SHUFFLE_USE_OLD_FETCH_PROTOCOL)) {
      partitionId
    } else context.taskAttemptId()

    // ③ 委托给 ShuffleWriterProcessor 实际写
    dep.shuffleWriterProcessor.write(rdd, dep, mapId, context, partition)
}
```

**短短一个方法，三件事：反序列化 → 算 mapId → 调 writer**。
真正的 shuffle 写逻辑在 `ShuffleWriterProcessor.write` → `manager.getWriter().write(...)`。

### 3.2 SortShuffleManager.registerShuffle —— 三种路径的自动选择

`SortShuffleManager.scala:95-114`：

```scala
override def registerShuffle[K, V, C](
    shuffleId: Int,
    dependency: ShuffleDependency[K, V, C]): ShuffleHandle = {
  if (SortShuffleWriter.shouldBypassMergeSort(conf, dependency)) {
    // ① BypassMergeSort：分区数 < 阈值 + 不需要 map-side combine
    new BypassMergeSortShuffleHandle[K, V](shuffleId, ...)
  } else if (SortShuffleManager.canUseSerializedShuffle(dependency)) {
    // ② Serialized (Tungsten)：不需要 combine + serializer 支持 relocation + 分区 ≤ 16M
    new SerializedShuffleHandle[K, V](shuffleId, ...)
  } else {
    // ③ Base (deserialized)：兜底
    new BaseShuffleHandle(shuffleId, dependency)
  }
}
```

**三个分支条件**（`SortShuffleManager.scala:230-248`）：

```scala
def canUseSerializedShuffle(dependency: ShuffleDependency[_, _, _]): Boolean = {
    val numPartitions = dependency.partitioner.numPartitions
    if (!dependency.serializer.supportsRelocationOfSerializedObjects) {
      false  // KryoSerializer 支持，JavaSerializer 不支持
    } else if (dependency.mapSideCombine) {
      false  // 需要 combine 必须走 deserialized 路径
    } else if (numPartitions > MAX_SHUFFLE_OUTPUT_PARTITIONS_FOR_SERIALIZED_MODE) {
      false  // > 16,777,216 个 partition（PackedRecordPointer 8 字节中 24 位给 partition id）
    } else {
      true
    }
}
```

| 路径 | 触发条件 | Writer | 数据形式 | 排序数据结构 |
|------|---------|--------|---------|------------|
| **Bypass** | < `spark.shuffle.sort.bypassMergeThreshold`（默认 200）+ 无 combine | `BypassMergeSortShuffleWriter` | 反序列化 | 不排序，每分区一个文件后 concat |
| **Serialized (Tungsten)** | 无 combine + serializer relocation + partition≤16M | `UnsafeShuffleWriter` | 序列化字节 | `ShuffleExternalSorter`（off-heap + 8 字节 PackedRecordPointer 数组）|
| **Base (deserialized)** | 兜底 | `SortShuffleWriter` | 反序列化对象 | `ExternalSorter`（in-memory `PartitionedAppendOnlyMap`/`PartitionedPairBuffer` + spill）|

### 3.3 SortShuffleManager.getWriter —— 工厂模式分发

`SortShuffleManager.scala:150-181`：

```scala
override def getWriter[K, V](
    handle: ShuffleHandle, mapId: Long, context: TaskContext,
    metrics: ShuffleWriteMetricsReporter): ShuffleWriter[K, V] = {
  val mapTaskIds = taskIdMapsForShuffle.computeIfAbsent(
    handle.shuffleId, _ => new OpenHashSet[Long](16))
  mapTaskIds.synchronized { mapTaskIds.add(mapId) }
  val env = SparkEnv.get
  handle match {
    case unsafeShuffleHandle: SerializedShuffleHandle[K, V] =>
      new UnsafeShuffleWriter(
        env.blockManager,
        context.taskMemoryManager(),     // ← 关键：Tungsten 内存管理
        unsafeShuffleHandle, mapId, context, env.conf, metrics, shuffleExecutorComponents)
    case bypassMergeSortHandle: BypassMergeSortShuffleHandle[K, V] =>
      new BypassMergeSortShuffleWriter(
        env.blockManager, bypassMergeSortHandle, mapId, env.conf, metrics, shuffleExecutorComponents)
    case other: BaseShuffleHandle[K, V, _] =>
      new SortShuffleWriter(other, mapId, context, shuffleExecutorComponents)
  }
}
```

**`taskIdMapsForShuffle`** 是 Driver-Executor 之间一致性的关键 —— `unregisterShuffle` 时要按这个集合删掉所有 mapId 的本地数据文件（避免泄漏）。

### 3.4 BlockStoreShuffleReader.read —— 读取链全貌

`BlockStoreShuffleReader.scala:70-146`：

```scala
override def read(): Iterator[Product2[K, C]] = {
    // ① 创建 fetch 迭代器：内部启动 Netty client 异步拉远端 block
    val wrappedStreams = new ShuffleBlockFetcherIterator(
      context,
      blockManager.blockStoreClient,
      blockManager,
      mapOutputTracker,                          // ← 拿 map output 位置
      blocksByAddress,                            // ← (BlockManagerId, [BlockId, size, mapIndex])
      serializerManager.wrapStream,
      conf.get(config.REDUCER_MAX_SIZE_IN_FLIGHT) * 1024 * 1024,    // 默认 48MB
      conf.get(config.REDUCER_MAX_REQS_IN_FLIGHT),                   // 默认 Int.MAX
      conf.get(config.REDUCER_MAX_BLOCKS_IN_FLIGHT_PER_ADDRESS),     // 默认 Int.MAX
      conf.get(config.MAX_REMOTE_BLOCK_SIZE_FETCH_TO_MEM),           // 默认 200MB
      conf.get(config.SHUFFLE_MAX_ATTEMPTS_ON_NETTY_OOM),
      conf.get(config.SHUFFLE_DETECT_CORRUPT),
      conf.get(config.SHUFFLE_DETECT_CORRUPT_MEMORY),
      conf.get(config.SHUFFLE_CHECKSUM_ENABLED),
      conf.get(config.SHUFFLE_CHECKSUM_ALGORITHM),
      readMetrics,
      fetchContinuousBlocksInBatch).toCompletionIterator

    val serializerInstance = dep.serializer.newInstance()

    // ② 反序列化为 (K, V) 迭代器
    val recordIter = wrappedStreams.flatMap { case (blockId, wrappedStream) =>
      serializerInstance.deserializeStream(wrappedStream).asKeyValueIterator
    }

    // ③ Metrics 包装
    val metricIter = CompletionIterator[(Any, Any), Iterator[(Any, Any)]](
      recordIter.map { record =>
        readMetrics.incRecordsRead(1)
        record
      }, context.taskMetrics().mergeShuffleReadMetrics())

    // ④ 可中断（task cancel 时用）
    val interruptibleIter = new InterruptibleIterator[(Any, Any)](context, metricIter)

    // ⑤ 聚合（reduceByKey/aggregateByKey）—— 走 ExternalAppendOnlyMap，自动 spill
    val aggregatedIter: Iterator[Product2[K, C]] = if (dep.aggregator.isDefined) {
      if (dep.mapSideCombine) {
        dep.aggregator.get.combineCombinersByKey(combinedKeyValuesIterator, context)
      } else {
        dep.aggregator.get.combineValuesByKey(keyValuesIterator, context)
      }
    } else interruptibleIter.asInstanceOf[Iterator[Product2[K, C]]]

    // ⑥ 排序（sortByKey）—— 走 ExternalSorter，自动 spill
    val resultIter: Iterator[Product2[K, C]] = dep.keyOrdering match {
      case Some(keyOrd: Ordering[K]) =>
        val sorter = new ExternalSorter[K, C, C](
          context, ordering = Some(keyOrd), serializer = dep.serializer)
        sorter.insertAllAndUpdateMetrics(aggregatedIter)
      case None => aggregatedIter
    }
    ...
}
```

**关键点 ① 的 batch fetch**（SPARK-9853 + 后续优化）：
当下游一个 reducer 要读 N 个连续 partition 时（AQE coalesce 场景），可以把多个 block 合并成一个 fetch 请求。`fetchContinuousBlocksInBatch` 的判定条件（`BlockStoreShuffleReader.scala:44-67`）：
- serializer 支持 relocation
- 压缩编解码器支持 concatenation（lz4/zstd 支持，snappy 不支持）
- 不开 IO encryption（SPARK-34790）
- 不用 old fetch protocol

**关键点 ⑤ 的 mapSideCombine 区分**：
- `mapSideCombine=true`：reader 收到的就是已经 combine 过的 (K, C)，再走 `combineCombinersByKey`
- `mapSideCombine=false`：reader 收到的是原始 (K, V)，走 `combineValuesByKey`

## 四、Push-based Shuffle（SPARK-30602）入口

`SortShuffleManager.scala:124-147` 的 `getReader`：

```scala
override def getReader[K, C](handle, startMapIndex, endMapIndex,
                              startPartition, endPartition, context, metrics): ShuffleReader[K, C] = {
  val baseShuffleHandle = handle.asInstanceOf[BaseShuffleHandle[K, _, C]]
  val (blocksByAddress, canEnableBatchFetch) =
    if (baseShuffleHandle.dependency.isShuffleMergeFinalizedMarked) {
      // ★ Push-based shuffle 路径
      val res = SparkEnv.get.mapOutputTracker.getPushBasedShuffleMapSizesByExecutorId(
        handle.shuffleId, startMapIndex, endMapIndex, startPartition, endPartition)
      (res.iter, res.enableBatchFetch)
    } else {
      // 经典路径
      val address = SparkEnv.get.mapOutputTracker.getMapSizesByExecutorId(
        handle.shuffleId, startMapIndex, endMapIndex, startPartition, endPartition)
      (address, true)
    }
  new BlockStoreShuffleReader(...)
}
```

**Push-based shuffle 概念**（也叫 Magnet Shuffle，LinkedIn 主导）：
- mapper 写完本地 shuffle 文件后，**主动把 block 推送到 reducer 端的 ESS**（External Shuffle Service）
- ESS 收到后做合并，等所有 push 完成后调用 `dependency.markShuffleMergeFinalized()` 设置 `isShuffleMergeFinalizedMarked=true`
- reducer 直接从 ESS 读合并好的 block，**避免 small file 问题**（核心痛点：reducer 拉 N×M 个小文件 → 拉 M 个合并文件）

**关键参数**：
- `spark.shuffle.push.enabled=false`（默认关，需要 ESS 配套支持）
- `spark.shuffle.push.server.mergedShuffleFileManagerImpl=org.apache.spark.network.shuffle.RemoteBlockPushResolver`

## 五、实战 LOG 对齐

| 日志关键词 | 出处 | 含义 |
|----------|------|------|
| `Can't use serialized shuffle for shuffle X because the serializer ...` | `SortShuffleManager.scala:234` | 走不了 Tungsten，原因：序列化器不支持 relocation |
| `Can't use serialized shuffle for shuffle X because we need to do map-side aggregation` | `SortShuffleManager.scala:238` | 用了 reduceByKey 等 |
| `Can't use serialized shuffle for shuffle X because it has more than 16777216 partitions` | `SortShuffleManager.scala:242` | 分区数超限（极少见）|
| `spark.shuffle.spill was set to false ... ignored` | `SortShuffleManager.scala:78` | 老配置警告，spill 强制开 |
| `The feature tag of continuous shuffle block fetching is set to true, but ...` | `BlockStoreShuffleReader.scala:60` | batch fetch 失败原因 |

**经典故障日志**（不在以上文件，但要联动）：
- `FetchFailedException: Failed to connect to ...` → reducer 拉 mapper 的 ESS 失败 → mapper 节点宕机或网络问题
- `Total size of serialized results of N tasks (XXX MB) is bigger than spark.driver.maxResultSize` → 不属于 shuffle，但是 collect 时常见

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| 三种 ShuffleHandle 自动选 | 性能优先：Tungsten > Bypass > Base，但 Tungsten 有约束（无 combine/relocation/分区数）|
| Bypass 不排序、每分区一文件后 concat | 分区数少时，排序成本 > IO 成本，反而退化 |
| Tungsten 用 8 字节指针数组排序 | cache-friendly：一个 cacheline（64B）能装 8 个指针，sort 的数据局部性极好 |
| `IndexShuffleBlockResolver` 两文件设计 (.data + .index) | reducer 一次读：先读 index 偏移，再 seek + read 对应区段，避免 seek 灾难 |
| ShuffleBlockFetcherIterator 用 Netty 异步 + 反压 | `MAX_SIZE_IN_FLIGHT=48MB` 控制内存峰值，避免 OOM |
| `MAX_REMOTE_BLOCK_SIZE_FETCH_TO_MEM=200MB` | 大 block 直接落盘 fetch，避免 reducer 端单条记录撑爆堆 |
| Reader 端用 ExternalSorter/ExternalAppendOnlyMap | 自动 spill 到磁盘，反压而非 OOM |
| Push-based shuffle | 解决 reducer 拉 N×M 小文件的物理瓶颈，磁盘 random read 改顺序 read |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `spark.shuffle.sort.bypassMergeThreshold` | 200 | < 这个分区数走 Bypass |
| `spark.shuffle.spill.numElementsForceSpillThreshold` | Long.MaxValue | 强制 spill 阈值 |
| `spark.shuffle.compress` | true | 压缩 |
| `spark.io.compression.codec` | lz4 | shuffle 压缩编解码 |
| `spark.shuffle.file.buffer` | 32KB | shuffle 写 buffer |
| `spark.shuffle.spill.batchSize` | 10000 | spill 时序列化 batch |
| `spark.reducer.maxSizeInFlight` | 48MB | reducer 单 host 最大 in-flight 数据量 |
| `spark.reducer.maxReqsInFlight` | Int.MaxValue | 单 reducer 最大 in-flight 请求数 |
| `spark.reducer.maxBlocksInFlightPerAddress` | Int.MaxValue | 单 host 最大 in-flight block 数 |
| `spark.shuffle.detectCorrupt` | true | 检测 shuffle 数据损坏 |
| `spark.shuffle.checksum.enabled` | true | shuffle 写时计算 checksum |
| `spark.shuffle.push.enabled` | false | Push-based shuffle |
| `spark.shuffle.useOldFetchProtocol` | false | 旧协议（mapId=partitionId）|
| `spark.maxRemoteBlockSizeFetchToMem` | 200MB | 单 block 超过此值直接落盘 |

## 八、踩坑记录

1. **大量 Shuffle Spill** —— Reader 端 `ExternalSorter.spill` 频繁触发，磁盘 IO 飙高。**根因**：reducer 内存不足容纳一个 partition 的所有数据。**应对**：增加 `spark.executor.memory` / `spark.shuffle.spill.numElementsForceSpillThreshold`，或减少分区粒度。
2. **FetchFailedException 雪崩** —— 一个 mapper 节点失联，导致下游所有 reducer 重新调度上游 stage。**应对**：开启 `spark.shuffle.io.maxRetries=10`、`spark.shuffle.io.retryWait=10s`，避免短暂网络抖动重启 stage。
3. **Bypass 分区文件数爆炸** —— `bypassMergeThreshold=200` 时每个 mapper 写 200 个文件，1000 mapper × 200 = 20 万文件，inode 紧张。**应对**：降低分区数或关闭 bypass（`spark.shuffle.sort.bypassMergeThreshold=0`）。
4. **小文件读 random IO** —— 经典痛点。**应对**：开 push-based shuffle 或上 ESS。
5. **Tungsten 但 numPartitions > 16M** —— 极特殊场景（动辄上千万分区）。**应对**：合并 partition，根本不应该用这么多。
6. **`mapSideCombine=true` 退化** —— reduceByKey 的 combine 在 mapper 端用 hash map，如果 key 倾斜严重，单个 mapper 的 combine map 撑爆 → spill 频繁。**应对**：换 aggregateByKey 手动控制 combine 时机。

## 九、认知更新

- 之前以为 Spark 只有一种 SortShuffleWriter，**实际上有三种**，根据 dependency 自动选，UnsafeShuffleWriter（Tungsten）才是 Spark 性能秘诀。
- 之前以为 reader 端会把所有数据加载到内存，**实际上 ExternalSorter 自动 spill**，reader 端理论上只用一个 record 大小的内存。
- Push-based shuffle 在 SortShuffleManager 中是通过 `isShuffleMergeFinalizedMarked` 标记走分支的，**不是替代而是叠加**：mapper 仍然写本地，只是额外推一份给 ESS 合并。
- ShuffleMapTask 本身极薄（103 行），**所有 shuffle 逻辑都在 ShuffleManager 里**。Spark 的设计是"task = 工作线程，ShuffleManager = 真正的 shuffle 引擎"。

## 十、下一步深挖方向

- [ ] UnsafeShuffleWriter 的 `ShuffleExternalSorter` + `PackedRecordPointer` 内存布局
- [ ] ShuffleBlockFetcherIterator 的 Netty 流控 + 反压实现
- [ ] AQE `OptimizeSkewedJoin` 如何利用 MapOutputTracker 的 stats 切分倾斜分区
- [ ] Push-based Shuffle 的 ESS 端合并算法（RemoteBlockPushResolver）

---

**沉淀完成。三种 Writer 自动选路径源码精确对齐，Reader 链路 Iterator 链清晰。**
