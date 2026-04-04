# Spark 内存管理 —— 逐行深度分析

> 本文不是源码摘要，是豹纹逐行啃 `UnifiedMemoryManager` + `ExecutionMemoryPool` 后的深度思考。
> 每一段都回答三个问题：**为什么这么写？不这么写会怎样？线上什么场景会命中？**

---

## 一、300MB 硬编码预留 —— 为什么是 300？

```scala
// UnifiedMemoryManager.scala 行198
private val RESERVED_SYSTEM_MEMORY_BYTES = 300 * 1024 * 1024
```

### 为什么这么写？
JVM 内部元数据（class metadata、线程栈、JIT 编译缓存、GC 元数据）+ Spark 内部数据结构（RPC、序列化缓冲、Listener 等）需要一个"不可动"的安全区域。这 300MB 是经验值，不是计算得出的。

### 不这么写会怎样？
如果不预留，Executor 堆内存全给了 Execution+Storage，JVM 自身运行就会 OOM。尤其是小堆（比如 512MB）场景下，不预留 300MB 就剩 212MB，再乘 0.6 只有 127MB 给计算+缓存，根本跑不了。

### 线上场景
**SPARK-12759**: 早期版本如果用户设 `--executor-memory 300m`，算出来 `maxHeapMemory = 0`，Executor 启动后直接 OOM 但没有任何有用的错误信息。修复后加了 fail-fast 检查：

```scala
// 行217-225: 启动时直接拒绝太小的内存
val minSystemMemory = (reservedMemory * 1.5).ceil.toLong  // 450MB
if (systemMemory < minSystemMemory) {
  throw new SparkIllegalArgumentException("INVALID_DRIVER_MEMORY", ...)
}
```

**为什么是 1.5 倍（450MB）而不是刚好 300MB？** 因为 300MB 只是"预留给系统"的，如果堆总共才 300MB，那 Execution+Storage 分到 0 字节，完全没法用。1.5 倍保证至少有 `300 × 0.6 = 90MB` 给计算。

---

## 二、软边界设计 —— 为什么 Execution 能驱逐 Storage，反过来不行？

```scala
// 行25-48 类注释精髓
// Storage can borrow as much execution memory as is free until execution reclaims its space.
// execution memory is *never* evicted by storage due to the complexities involved
```

### 为什么不对称？

这不是偷懒，是**经过深思熟虑的设计妥协**：

1. **Storage 的数据可重建**：缓存的 RDD Block 可以落盘（如果 StorageLevel 允许）或从源头重算。驱逐的成本是"重算时间"，不会导致正确性问题。

2. **Execution 的数据不可安全驱逐**：Shuffle 排序中的中间数据、Hash Join 的 hash table、聚合的 partial result —— 这些是"正在计算中"的活数据。要驱逐它就要 spill 到磁盘，但 spill 本身也需要内存来序列化。如果 Storage 要驱逐 Execution 来腾空间，可能陷入"没内存做 spill → 没法释放内存"的死循环。

3. **Execution 是"刚性需求"**：一个 Task 如果分不到足够内存就跑不了（或者极慢地反复 spill），而 Storage 是"锦上添花"（有缓存快一些，没缓存慢一些但能跑）。

### 线上推论

**当 Execution 任务（大 Shuffle/Join/Agg）占满内存后，你会看到：**
```
INFO: Will not store rdd_X_Y as the required space (N bytes) exceeds our memory limit (M bytes)
```
这不是 bug，这是**设计如此**。解决方案不是调大 `spark.memory.storageFraction`（这只改初始软边界，Execution 照样可以吃掉），而是：
- 增加 `--executor-memory`
- 减少并发 Task 数（`spark.executor.cores`）
- 优化 Shuffle 数据量

---

## 三、`maybeGrowExecutionPool` —— 每一行都有故事

```scala
// 行111-128
def maybeGrowExecutionPool(extraMemoryNeeded: Long): Unit = {
  if (extraMemoryNeeded > 0) {
    val memoryReclaimableFromStorage = math.max(
      storagePool.memoryFree,                    // (A) Storage 空闲部分
      storagePool.poolSize - storageRegionSize)  // (B) Storage 超出初始区域的部分
```

### 为什么取 `max(A, B)` 而不是 `A + B`？

这两个值有**重叠区域**，不能简单相加：

- `storagePool.memoryFree`：Storage 池中**空闲**的内存（poolSize - memoryUsed）
- `storagePool.poolSize - storageRegionSize`：Storage 池**超出初始配额**的部分（即从 Execution 借来的）

**场景分析**：
- 如果 Storage 从 Execution 借了 100MB 且全部用掉了：`memoryFree=0, poolSize-regionSize=100MB` → 取 100MB（可以通过驱逐 Block 回收这 100MB）
- 如果 Storage 没借但有 50MB 空闲：`memoryFree=50MB, poolSize-regionSize=0` → 取 50MB（直接拿走空闲的）
- 如果 Storage 借了 100MB 但只用了 60MB：`memoryFree=40MB, poolSize-regionSize=100MB` → 取 100MB

**取 max 的原因**：B 已经包含了"可以通过驱逐回收"的量，而 A 是"不用驱逐就能拿"的量。当 B > A 时说明 Storage 借了 Execution 的地盘且还在用，需要驱逐；当 A > B 时说明 Storage 没借但有闲置。两者取大值就是"最大可回收量"。

```scala
    val spaceToReclaim = storagePool.freeSpaceToShrinkPool(
      math.min(extraMemoryNeeded, memoryReclaimableFromStorage))
```

### 为什么用 `freeSpaceToShrinkPool` 而不是直接 `decrementPoolSize`？

因为 `decrementPoolSize` 有个 `require(_poolSize - delta >= memoryUsed)` 的断言。如果 Storage 池的 `memoryUsed > poolSize - delta`，直接 decrement 会崩。

`freeSpaceToShrinkPool` 的逻辑是：
1. 先释放空闲内存（不用驱逐）
2. 空闲不够就驱逐 Block（通过 `MemoryStore.evictBlocksToFreeSpace`）
3. 返回**实际释放的量**（可能小于请求量，因为有些 Block 正在被读不能驱逐）

---

## 四、`computeMaxExecutionPoolSize` —— SPARK-12155 的血泪教训

```scala
// 行143-145
def computeMaxExecutionPoolSize(): Long = {
  maxMemory - math.min(storagePool.memoryUsed, storageRegionSize)
}
```

### 这行看着简单，为什么不直接用 `executionPool.poolSize`？

**这是 SPARK-12155 的修复核心**。

#### SPARK-12155 的故事

线上场景：集群缓存了 43GB 数据，然后跑一个 Tungsten 聚合查询。

**Bug 复现路径**：
1. Storage 借走了 Execution 大量内存来缓存数据
2. 一个 Task 请求 256KB Execution 内存
3. 系统发现 Execution 池不够，调 `maybeGrowExecutionPool` 从 Storage 回收了一些
4. 但在计算 `maxMemoryPerTask = poolSize / numActiveTasks` 时，`poolSize` 只反映了**已经回收过来的**内存，不包含"可以但还没回收"的 Storage 内存
5. 结果 `maxMemoryPerTask` 算出来很小（比如 80KB），`maxToGrant = min(256KB, max(0, 80KB - curMem))` 也很小
6. Task 分不到足够内存 → OOM

**修复思路**：`computeMaxExecutionPoolSize()` 返回的不是 Execution 池的实际大小，而是"理论上 Execution 池能有多大"——即总内存减去 Storage 的**合理占用量**。

```
maxMemory - min(storagePool.memoryUsed, storageRegionSize)
```

翻译：总内存 - Storage 至少应该保留的部分。如果 Storage 实际用量 < 初始配额，就按实际用量算（给 Execution 留更多空间）；如果 Storage 用量超出配额（借了 Execution 的地盘），那只保留配额大小。

**这样 Task 在计算自己的份额上限时，就能"看见"那些还没真正回收但可以回收的内存，不会因为 poolSize 太小而 OOM。**

### 为什么注释还提到不能超过 `maxMemory`？

```
// this quantity should be kept below `maxMemory` to arbitrate fairness
```

如果 `computeMaxExecutionPoolSize` 返回值 > `maxMemory`，那 `maxMemoryPerTask = huge / N`，单个 Task 会认为自己可以用很多，实际拿不到就会一直 wait。

---

## 五、`ExecutionMemoryPool.acquireMemory` —— 1/2N 公平性算法的精妙与陷阱

```scala
// ExecutionMemoryPool.scala 行102-106
if (!memoryForTask.contains(taskAttemptId)) {
  memoryForTask(taskAttemptId) = 0L
  lock.notifyAll()  // ← 为什么新 Task 注册要 notifyAll？
}
```

### 为什么新 Task 注册要唤醒所有等待的 Task？

因为 `numActiveTasks` 变了！所有 Task 的份额 `1/2N` 和 `1/N` 都变了（N 增大了，每人份额缩小了）。

场景：Task A 已经占了 60% 的内存，Task B 在等（因为 B 的 `curMem + toGrant < minMemoryPerTask`）。这时 Task C 来了，N 从 2 变成 3，`minMemoryPerTask` 从 `poolSize/4` 变成 `poolSize/6`，B 可能现在就能满足最低要求了。

```scala
// 行112-144 核心循环
while (true) {
  val numActiveTasks = memoryForTask.keys.size
  val curMem = memoryForTask(taskAttemptId)

  maybeGrowPool(numBytes - memoryFree)  // ← 每次循环都尝试从 Storage 回收！

  val maxPoolSize = computeMaxPoolSize()
  val maxMemoryPerTask = maxPoolSize / numActiveTasks   // 上限 1/N
  val minMemoryPerTask = poolSize / (2 * numActiveTasks) // 下限 1/2N

  val maxToGrant = math.min(numBytes, math.max(0, maxMemoryPerTask - curMem))
  val toGrant = math.min(maxToGrant, memoryFree)

  if (toGrant < numBytes && curMem + toGrant < minMemoryPerTask) {
    lock.wait()  // ← 阻塞！直到其他 Task 释放内存
  } else {
    memoryForTask(taskAttemptId) += toGrant
    return toGrant  // ← 可能返回 < numBytes（部分分配）
  }
}
```

### 逐行解读

**`maybeGrowPool(numBytes - memoryFree)`**: 每次循环都尝试从 Storage 回收。为什么每次都要？注释说了——"potential race condition where new storage blocks may steal the free execution memory that this task was waiting for"。你在 wait 的时候，可能有其他线程缓存了一个大 Block，把你等到的空闲内存又抢走了。

**`maxMemoryPerTask = maxPoolSize / numActiveTasks`**: 注意是 `maxPoolSize`（包含潜在可回收的）而不是 `poolSize`（实际大小）。这就是 SPARK-12155 的修复。

**`minMemoryPerTask = poolSize / (2 * numActiveTasks)`**: 注意这里用的是 `poolSize`（实际大小）而不是 `maxPoolSize`。为什么？因为最低保障必须基于**实际已有的内存**，不能基于"理论上可以回收"的。

**`maxToGrant = min(numBytes, max(0, maxMemoryPerTask - curMem))`**: 
- `maxMemoryPerTask - curMem`：这个 Task 还能再拿多少（公平上限）
- 如果已经超标（`curMem > maxMemoryPerTask`），`maxToGrant = 0`，这轮不分配
- 但不会回收已持有的内存！只是不再给了

**`toGrant = min(maxToGrant, memoryFree)`**: 实际只能给空闲的，不能给别人正在用的

**`if (toGrant < numBytes && curMem + toGrant < minMemoryPerTask)`**: 
- 条件1: 分的不够（`toGrant < numBytes`）
- 条件2: 加上现有的也不到最低保障（`curMem + toGrant < 1/2N`）
- 两个条件**同时满足**才 wait。如果只满足条件1（分的不够但已经有了 1/2N），直接返回部分分配，让调用方决定是 spill 还是继续请求。

### 线上排障

**看到日志 `TID X waiting for at least 1/2N of on-heap execution pool to be free` 意味着什么？**

这个 Task 当前持有的内存 + 能分到的 < 总内存的 `1/(2×活跃Task数)`。可能原因：
1. 太多并发 Task，每人份额太小 → 减少 `spark.executor.cores`
2. 某些 Task 占了大量内存不释放（在做大聚合/排序）→ 正常，等它 spill 后就会 notifyAll
3. Storage 占太多，Execution 回收不回来 → 减少缓存数据或增加总内存

**极端情况：所有 Task 都在 wait 会死锁吗？**

不会。Task 完成时 `releaseAllMemoryForTask` 会 `notifyAll()`。但如果**所有** Task 都分不到最低保障且没有 Task 能完成... 理论上会卡住。实际中 spill 机制会在 Task 返回部分分配后触发磁盘写入，释放内存后 notify 其他 Task。

---

## 六、`acquireStorageMemory` —— Storage 借用的单向性

```scala
// 行173-179
if (numBytes > storagePool.memoryFree) {
  val memoryBorrowedFromExecution = Math.min(
    executionPool.memoryFree,              // 只借 Execution 的空闲！
    numBytes - storagePool.memoryFree)     // 只借需要的量
  executionPool.decrementPoolSize(memoryBorrowedFromExecution)
  storagePool.incrementPoolSize(memoryBorrowedFromExecution)
}
```

### 关键约束：只借空闲的

Storage 不能驱逐 Execution 的内存，只能拿 Execution **空闲**的。如果 Execution 全占满了，Storage 分不到任何额外内存，只能在自己的 pool 内驱逐旧 Block 来腾空间。

### 线上场景

大 Shuffle 跑完后紧接着 `rdd.cache()`：
- Shuffle 占了大量 Execution 内存（但已释放回 pool）
- `executionPool.memoryFree` 很大
- Storage 可以借到大量内存来缓存
- **但如果紧接着又来一个 Shuffle**，Execution 会通过 `maybeGrowExecutionPool` 把这些借出去的内存**连带 Storage 的 Block 一起驱逐回来**

这就是为什么你看到 "缓存了之后又被驱逐了" 的现象——不是 bug，是设计如此。

---

## 七、源码中提到的关键 JIRA 索引

| JIRA | 问题 | 修复 | 影响的代码位置 |
|------|------|------|---------------|
| **SPARK-12155** | 缓存大数据后 Execution OOM | `computeMaxExecutionPoolSize` 考虑潜在可回收内存 | `UnifiedMemoryManager:143` |
| **SPARK-12759** | Executor 内存太小时无有用错误 | 启动时 fail-fast 检查 | `UnifiedMemoryManager:218-236` |
| **SPARK-19276** | FetchFailed 被用户代码吞掉 | 构造函数中 `setFetchFailed` | `FetchFailedException:59` |
| **SPARK-37593** | G1GC 下 page size 对齐问题 | `chosenPageSize - Platform.LONG_ARRAY_OFFSET` | `MemoryManager:263` |

---

## 八、实战排障 Checklist

遇到内存相关问题时，按这个顺序排查：

1. **看 Spark UI → Executors Tab → Storage Memory / Execution Memory**
   - Storage 占比很高 + Execution 经常 spill → cache 太多了
   - Execution 占比很高 + Storage 全被驱逐 → 并发 Task 太多或 Shuffle 数据量太大

2. **看日志关键词**
   - `Will not store` → Storage 被 Execution 挤占，参考上文第二节
   - `waiting for at least 1/2N` → Execution 池内 Task 间竞争，参考上文第五节
   - `Unable to acquire N bytes of memory` → 可能命中 SPARK-12155 的变种

3. **关键参数调优**
   - 加内存永远是第一选择
   - `spark.memory.fraction=0.6` 一般不用改
   - `spark.memory.storageFraction=0.5` 只影响初始边界，不影响上限
   - 减少 `spark.executor.cores` 可以降低每个 Executor 的并发 Task 数
