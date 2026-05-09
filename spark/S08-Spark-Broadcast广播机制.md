# Spark Broadcast 广播机制源码分析

> **模块**: Spark Core — 广播变量  
> **源码路径**: `core/src/main/scala/org/apache/spark/broadcast/TorrentBroadcast.scala`  
> **相关模块**: `BroadcastManager.scala`, `BlockManager.scala`  
> **分析日期**: 2026-05-10  
> **Spark 版本**: 4.x (master)

---

## 1. 定位与背景

Broadcast 机制用于将**只读大对象**（配置、查找表、小表等）高效地分发到集群所有 Executor：

```
Driver 广播一个 lookup 表（100MB）给 100 个 Executor：
  无 Broadcast：Driver → 每个 Executor = 100 × 100MB = 10GB 网络带宽
  有 Broadcast：Driver → 每个 Executor(1份) → 其他 Executor(从邻居拉取) ≈ O(Executor数) 带宽
```

Spark 4.x 默认使用 **TorrentBroadcast**（BitTorrent 风格），另有 `HttpBroadcast`（已废弃）和 ` TorrentBroadcast` 两种实现。

---

## 2. BroadcastManager — 工厂与生命周期

```scala
class BroadcastManager(val isDriver: Boolean, conf: SparkConf) extends Logging {
  private var broadcastFactory: BroadcastFactory = null

  private def initialize(): Unit = synchronized {
    if (!initialized) {
      broadcastFactory = new TorrentBroadcastFactory  // 默认工厂
      broadcastFactory.initialize(isDriver, conf)
      initialized = true
    }
  }

  def newBroadcast[T: ClassTag](value_: T, isLocal: Boolean): Broadcast[T] = {
    val bid = nextBroadcastId.getAndIncrement()  // 全局递增广播 ID
    broadcastFactory.newBroadcast[T](value_, isLocal, bid)
  }

  def unbroadcast(id: Long, removeFromDriver: Boolean, blocking: Boolean): Unit = {
    broadcastFactory.unbroadcast(id, removeFromDriver, blocking)
  }

  // 软引用缓存：Driver 端持有广播对象引用，可被 GC 回收后重建
  private[broadcast] val cachedValues =
    Collections.synchronizedMap(new ReferenceMap(HARD, WEAK).asInstanceOf[...])
}
```

---

## 3. TorrentBroadcast — BitTorrent 分发机制

### 3.1 写入阶段（Driver 端）

```scala
private[spark] class TorrentBroadcast[T: ClassTag](obj: T, id: Long)
  extends Broadcast[T](id) with Logging with Serializable {

  private val broadcastId = BroadcastBlockId(id)  // blockId = "broadcast_X"
  private val numBlocks: Int = writeBlocks(obj)   // ⬅ 构造时即写入

  private def writeBlocks(value: T): Int = {
    val blockManager = SparkEnv.get.blockManager

    // Step 1: 在 Driver 端本地存一份完整对象（MEMORY_AND_DISK）
    // 作用：让 Driver 上运行的任务直接读本地，不重复拉取
    blockManager.putSingle(broadcastId, value, MEMORY_AND_DISK, tellMaster = false)

    // Step 2: 将对象序列化为 Chunk，写入多个 piece blocks（MEMORY_AND_DISK_SER）
    val blocks = TorrentBroadcast.blockifyObject(
      value, blockSize, SparkEnv.get.serializer, compressionCodec)

    blocks.zipWithIndex.foreach { case (block, i) =>
      val pieceId = BroadcastBlockId(id, "piece" + i)  // piece0, piece1, ...
      if (checksumEnabled) checksums(i) = calcChecksum(block)
      // tellMaster=true → 向 Driver 的 BlockManagerMaster 注册，供其他 Executor 发现
      blockManager.putBytes(pieceId, bytes, MEMORY_AND_DISK_SER, tellMaster = true)
    }
    blocks.length  // 返回 block 数量
  }
}
```

**`blockifyObject` 核心**：

```scala
def blockifyObject[T](obj: T, blockSize: Int, serializer: Serializer,
    compressionCodec: Option[CompressionCodec]): Array[ByteBuffer] = {
  val cbbos = new ChunkedByteBufferOutputStream(blockSize, ByteBuffer.allocate)
  val ser = serializer.newInstance()
  ser.serializeStream(cbbos).writeObject(obj)
  cbbos.toChunkedByteBuffer.toArray  // 按 blockSize 分片
}
```

### 3.2 读取阶段（Executor 端）

```scala
override protected def getValue(): T = synchronized {
  // Step 1: 软引用缓存命中检查
  val memoized: T = if (_value == null) null else _value.get
  if (memoized != null) return memoized

  // Step 2: 从 BlockManager 读取重建
  val newlyRead = readBroadcastBlock()
  _value = new SoftReference[T](newlyRead)  // 软引用缓存
  newlyRead
}

private def readBlocks(): Array[BlockData] = {
  val blocks = new Array[BlockData](numBlocks)
  val bm = SparkEnv.get.blockManager

  // ⬇ 随机打散顺序，从多个来源并行/交叉拉取
  for (pid <- Random.shuffle(Seq.range(0, numBlocks))) {
    val pieceId = BroadcastBlockId(id, "piece" + pid)

    // 优先本地
    bm.getLocalBytes(pieceId) match {
      case Some(block) =>
        blocks(pid) = block
        releaseBlockManagerLock(pieceId)
      case None =>
        // 远程拉取（Driver 或其他 Executor）
        bm.getRemoteBytes(pieceId) match {
          case Some(b) =>
            // 校验 checksum
            if (checksumEnabled) {
              val sum = calcChecksum(b.chunks(0))
              if (sum != checksums(pid))
                throw new SparkException(s"corrupt block $pieceId: $sum != ${checksums(pid)}")
            }
            // 拉到本地后存入本机 BlockManager（向 Driver 注册）
            bm.putBytes(pieceId, b, StorageLevel.MEMORY_AND_DISK_SER, tellMaster = true)
            blocks(pid) = new ByteBufferBlockData(b, true)
          case None =>
            throw new SparkException(s"Failed to get $pieceId of $broadcastId")
        }
    }
  }
  blocks
}
```

---

## 4. BitTorrent 分发拓扑

```
Driver
  ├─ broadcast_0 (完整对象，MEMORY_AND_DISK)
  ├─ broadcast_0_piece0 (4MB chunks, 分布存储)
  ├─ broadcast_0_piece1
  └─ ...
      ↓ 拉取
  Executor-1 ────────────────────────────────┐
  ├─ broadcast_0_piece0 [本地]               │ 
  ├─ broadcast_0_piece1 [本地]               │ 
  └─ broadcast_0_piece2 [从 Driver/Executor-3 拉取]  ← 减少 Driver 带宽压力
                                               │
  Executor-2 ────────────────────────────────┘
  ├─ broadcast_0_piece2 [本地] (可被其他 Executor 拉取)
  └─ ...
```

**关键设计**：
1. 每个 Executor 拉取 chunk 后立即向 Driver 注册 → 变成可被其他 Executor 拉取的节点
2. **随机打散拉取顺序** → 避免同时向 Driver 请求同一个 piece（热点分散）
3. **Driver 本地有完整对象副本** → Driver 上运行的 task 直接读本地，无网络开销
4. **Checksum 校验**（默认开启）→ 防止网络传输损坏
5. **软引用缓存**（Driver 端）→ 内存紧张时可被 GC 回收，Task 再次访问时触发 `readBroadcastBlock` 重建

---

## 5. Block 大小与性能调优

```scala
// 读取配置：spark.broadcast.blockSize（默认 4MB）
blockSize = conf.get(config.BROADCAST_BLOCKSIZE).toInt * 1024  // 4MB
```

| blockSize | 块数量 | 元数据开销 | 适用场景 |
|-----------|--------|-----------|---------|
| 2MB | 多 | 高 | 大广播对象（>100MB） |
| **4MB** | 适中 | 适中 | **默认，推荐** |
| 8MB+ | 少 | 低 | 小集群、低并发 |

**块太小**：元数据过多，BlockManager 压力增大
**块太大**：热门块成为单点瓶颈，灵活性降低

---

## 6. 其他关键配置

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `spark.broadcast.compress` | true | 广播块是否压缩（snappy） |
| `spark.broadcast.checksum` | true | 是否开启块校验（Adler32） |
| `spark.broadcast.blockSize` | 4MB | 每个 piece 的块大小 |

---

## 7. Unpersist — 释放广播内存

```scala
override protected def doUnpersist(blocking: Boolean): Unit = {
  broadcastFactory.unbroadcast(id, removeFromDriver = false, blocking)
}
```

**关键点**：
- Executor 端 `unpersist()`：只删除本地 pieces，不通知 Driver
- Driver 端 `unpersist()`：调用 `blockManager.removeBroadcast(id, tellMaster = true)`，通知所有 Executor 删除
- **显式调用 `unpersist()`**：在 Batch 作业或流式作业中，及时释放不再需要的广播对象

---

## 8. 踩坑 & 运维要点

| 场景 | 现象 | 根因 | 解决 |
|------|------|------|------|
| Driver OOM | 广播变量导致 OOM | Driver 内存 = `numBlocks × blockSize`，且 BlockManager 缓存全部 piece | 增大 `spark.driver.memory` 或开启 `spark.broadcast.compress` |
| Executor 广播读取慢 | broadcast join 慢 | 本地 piece 不全，需跨网络拉取 | 增大 `spark.sql.shuffle.partitions` 减少单 Executor 并发；调整 blockSize |
| 广播对象 > 2GB | 序列化失败 | Spark 广播使用 Java serialize，有 2GB 限制 | 使用 Kryo；或手动分片广播 |
| Checksum 校验失败 | `corrupt block` 异常 | 网络传输损坏（内存错误/NIC） | 开启 ECC 内存；检查网络硬件 |
| 未及时 unpersist | 内存持续增长 | 批处理每批广播同一对象，旧对象未释放 | 每批次后显式调用 `broadcast.unpersist()` |
