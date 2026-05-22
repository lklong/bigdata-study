# Spark MemoryManager 内存管理机制源码分析

> **模块**: Spark Core — 内存管理  
> **源码路径**: `core/src/main/scala/org/apache/spark/memory/MemoryManager.scala`  
> **相关模块**: `ExecutionMemoryPool.scala`, `StorageMemoryPool.scala`, `MemoryStore.scala`  
> **分析日期**: 2026-05-10  
> **Spark 版本**: 4.x (master)

---

## 1. 定位与上下文

Spark 内存管理采用**统一内存管理**（Unified Memory Management）模型，在 Spark 1.6+ 引入，取代了之前的静态划分模型。MemoryManager 是 JVM 级别的单例，负责：

- **Execution 内存**：Shuffle / Sort / Join / Aggregation 等计算操作
- **Storage 内存**：RDD Cache / Broadcast / 用户数据结构
- **两者可相互借用**：计算内存不足时可 evict Storage 块；Storage 不足时可 spill Execution 内存

---

## 2. 内存池架构

```scala
abstract class MemoryManager(
    conf: SparkConf,
    numCores: Int,
    onHeapStorageMemory: Long,    // 堆内 Storage 初始大小
    onHeapExecutionMemory: Long)  // 堆内 Execution 初始大小
```

MemoryManager 在构造时初始化**四个内存池**（全部带 `synchronized` 保护）：

```scala
@GuardedBy("this")
protected val onHeapStorageMemoryPool   = new StorageMemoryPool(this, ON_HEAP)
@GuardedBy("this")
protected val offHeapStorageMemoryPool  = new StorageMemoryPool(this, OFF_HEAP)
@GuardedBy("this")
protected val onHeapExecutionMemoryPool = new ExecutionMemoryPool(this, ON_HEAP)
@GuardedBy("this")
protected val offHeapExecutionMemoryPool= new ExecutionMemoryPool(this, OFF_HEAP)

// 初始化各池大小
onHeapStorageMemoryPool.incrementPoolSize(onHeapStorageMemory)
onHeapExecutionMemoryPool.incrementPoolSize(onHeapExecutionMemory)
// OffHeap: 总大小 - Storage 占比 = Execution
offHeapExecutionMemoryPool.incrementPoolSize(maxOffHeapMemory - offHeapStorageMemory)
offHeapStorageMemoryPool.incrementPoolSize(offHeapStorageMemory)
```

### 2.1 Unified Memory 划分公式

```
堆内总内存 = spark.memory.fraction × (JVM Heap - 300MB 保留)
堆内 Storage = spark.memory.storageFraction × 堆内总内存   (默认 50%)
堆内 Execution = 堆内总内存 - 堆内 Storage

OffHeap 总大小 = spark.memory.offHeap.size（默认 0，即不开启）
```

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `spark.memory.fraction` | 0.6 | JVM Heap 中用于 Spark 内存的比例 |
| `spark.memory.storageFraction` | 0.5 | Storage 占 Spark 内存的比例 |
| `spark.memory.offHeap.enabled` | false | 是否开启 OffHeap |
| `spark.memory.offHeap.size` | 0 | OffHeap 内存大小 |

---

## 3. Execution 内存分配

### 3.1 acquireExecutionMemory — 核心方法

```scala
private[memory]
def acquireExecutionMemory(
    numBytes: Long,
    taskAttemptId: Long,
    memoryMode: MemoryMode): Long
```

**调用方**：
- `ShuffleExternalSorter.acquireMemory()` — Shuffle 排序溢出控制
- `AppendOnlyMap.acquireMemory()` — HashMap 聚合溢出控制
- `BytesToBytesMap.acquireMemory()` — Unsafe 模式 KV Map

**关键设计 — 公平保证**：每个活跃 Task 至少获得 `1 / 2N` 的 Execution 内存（N = 活跃 Task 数），防止旧任务饿死新任务：

```scala
// 每个 Task 最低保底：总 Execution 内存 / (2 × 活跃 Task 数)
val maxMemoryPerTask = poolSize / numActiveTasks
val minMemoryPerTask = poolSize / (2 * numActiveTasks)
```

**三者分配策略**：
1. **请求 ≤ minMemoryPerTask**：直接批准
2. **请求在 min~max 之间**：等待其他 Task 释放（spill）
3. **请求 > maxMemoryPerTask**：只批准 maxMemoryPerTask（防止单 Task 独占）

### 3.2 ExecutionMemoryPool 内部机制

```scala
class ExecutionMemoryPool[M](memoryManager: MemoryManager, memoryMode: MemoryMode)
    extends MemoryPool with Logging {

  // perTaskMemory: Long → 当前 Task 占用内存
  private val perTaskMemory = new HashMap[Long, Long]()

  // 活跃 Task 集合（通过 tryAcquire/release 动态增删）
  private def activeTasks(): Int = perTaskMemory.size
}
```

Task 结束时调用 `releaseAllExecutionMemoryForTask(taskAttemptId)`，Pool 感知活跃 Task 数变化后重新分配。

---

## 4. Storage 内存分配

### 4.1 acquireStorageMemory — RDD Cache / Broadcast

```scala
def acquireStorageMemory(blockId: BlockId, numBytes: Long, memoryMode: MemoryMode): Boolean
```

**调用链**：
```
MemoryStore.putBytes() / putIterator() 
  → MemoryManager.acquireStorageMemory()
    → StorageMemoryPool.acquireMemory()
      → evictBlocksToFreeSpace()  // 空间不足时触发 LRU 淘汰
```

### 4.2 StorageMemoryPool — LRU Eviction

```scala
// entries: LinkedHashMap[BlockId, MemoryEntry]（LRU 顺序）
private val entries = new util.LinkedHashMap[BlockId, MemoryEntry](32, 0.75f, true)

// 淘汰逻辑：遍历 LRU 队列，优先驱逐非 RDD block 和非正在使用的 block
while (freedMemory < space && iterator.hasNext) {
  val (blockId, entry) = iterator.next()
  if (blockId.isBroadcast || !isBlockServingAsInput(blockId)) {
    remove(blockId)
    freedMemory += entry.size
  }
}
```

**淘汰优先级**：
1. Broadcast 变量（最早被淘汰）
2. 非当前计算使用的 RDD Block
3. 其他非活跃 Block

---

## 5. MemoryStore — 数据块存储

```scala
private[spark] class MemoryStore(
    conf: SparkConf,
    blockInfoManager: BlockInfoManager,
    memoryManager: MemoryManager,
    maxMemory: Long) extends BlockStore
```

### 5.1 putBytes — 序列化存储（用于 Broadcast / Shuffle 结果）

```scala
def putBytes[T: ClassTag](blockId, size, memoryMode, _bytes: () => ChunkedByteBuffer): Boolean = {
  require(!contains(blockId), s"Block $blockId already exists")
  if (memoryManager.acquireStorageMemory(blockId, size, memoryMode)) {
    val bytes = _bytes()
    val entry = new SerializedMemoryEntry[T](bytes, memoryMode, classTag)
    entries.synchronized { entries.put(blockId, entry) }
    true
  } else { false }
}
```

### 5.2 putIterator — 迭代器渐进展开（用于 RDD 计算结果缓存）

**核心挑战**：迭代器可能非常大，无法一次性全部加载到内存。

```scala
private def putIterator[T](blockId, values: Iterator[T], ..., valuesHolder: ValuesHolder[T])
  : Either[Long, Long] = {

  // 初始内存预留
  var memoryThreshold = initialMemoryThreshold  // 默认 4KB × numCores
  var unrollMemoryUsedByThisBlock = 0L

  // 逐步展开迭代器
  while (values.hasNext && keepUnrolling) {
    valuesHolder.storeValue(values.next())  // 反序列化到 valuesHolder

    if (elementsUnrolled % memoryCheckPeriod == 0) {  // 每 N 个元素检查一次
      val currentSize = valuesHolder.estimatedSize()
      if (currentSize >= memoryThreshold) {
        // 按指数增长申请内存：newThreshold = currentSize × 1.1
        val amountToRequest = (currentSize * memoryGrowthFactor - memoryThreshold).toLong
        keepUnrolling = reserveUnrollMemoryForThisTask(blockId, amountToRequest, memoryMode)
        unrollMemoryUsedByThisBlock += amountToRequest
        memoryThreshold += amountToRequest
      }
    }
    elementsUnrolled += 1
  }

  // 展开完成后，将 unroll 内存转为 storage 内存（原子操作）
  memoryManager.synchronized {
    releaseUnrollMemoryForThisTask(memoryMode, unrollMemoryUsedByThisBlock)
    memoryManager.acquireStorageMemory(blockId, entry.size, memoryMode)  // 保底申请
    entries.synchronized { entries.put(blockId, entry) }
  }
}
```

**参数**：
| 参数 | 默认值 | 含义 |
|------|--------|------|
| `spark.memory.unroll.initial` | 4KB × cores | 初始展开内存 |
| `spark.memory.unrollGrowthFactor` | 1.1 | 内存增长倍数 |
| `spark.memory.storage fraction` | 0.5 | Storage 占 Unified Memory 的比例 |

---

## 6. Tungsten / Page 内存管理

```scala
// Page 大小计算（核心）
private lazy val defaultPageSizeBytes = {
  val maxTungstenMemory = (poolSize / numCores / 16).nextPowerOf2
  math.min(64MB, math.max(1MB, maxTungstenMemory))
}
```

**Tungsten 使用 `sun.misc.Unsafe` 直接操作二进制内存**：
- **堆内模式**（`ON_HEAP`）：使用 `byte[]` + Unsafe 读写（JVM Heap 内）
- **堆外模式**（`OFF_HEAP`）：直接通过 Unsafe 分配 OS 内存（绕过 GC）

```scala
final val tungstenMemoryAllocator: MemoryAllocator = {
  tungstenMemoryMode match {
    case OFF_HEAP => new UnsafeMemoryAllocator()
    case ON_HEAP  => new HeapMemoryAllocator()
  }
}
```

---

## 7. 完整调用链：RDD Cache 执行路径

```
rdd.persist(StorageLevel.MEMORY_AND_DISK)
  └─ RDD.persist()
       └─ storage.BlockManager.put()
            └─ MemoryStore.putIterator() / putBytes()
                 ├─ acquireStorageMemory()  ← MemoryManager 审批
                 │    └─ StorageMemoryPool.acquireMemory()
                 │         └─ evictBlocksToFreeSpace()  ← LRU 淘汰
                 └─ entries.put(blockId, entry)  ← LinkedHashMap 存储
```

---

## 8. 踩坑 & 运维要点

| 场景 | 现象 | 根因 | 解决 |
|------|------|------|------|
| OOM: GC overhead | `OutOfMemoryError: GC overhead` | Execution 内存被 Storage 大量借用 | `spark.memory.storageFraction` 降低，或开启 OffHeap |
| Cache 数据被意外驱逐 | RDD 反复重算 | Storage 内存不足被 LRU 淘汰 | 增加 `spark.memory.fraction` 或改用 DISK 层级 |
| Shuffle Spill 频繁 | 磁盘 I/O 高 | Execution 内存不足 | 增加 `spark.executor.memory` 或 `spark.shuffle.memoryFraction` |
| OffHeap 分配失败 | `Native memory allocation error` | OS 内存或虚拟内存不足 | 检查 ulimit -v，或关闭 OffHeap |
| Page 大小不当 | 内存碎片化 | PageSize 计算不合理 | 手动设置 `spark.buffer.pageSize` |
