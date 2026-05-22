# Spark BlockManager 存储管理机制源码分析

> **模块**: Spark Core — 块存储层  
> **源码路径**: `core/src/main/scala/org/apache/spark/storage/BlockManager.scala`  
> **相关模块**: `MemoryStore.scala`, `DiskStore.scala`, `BlockManagerMaster.scala`  
> **分析日期**: 2026-05-10  
> **Spark 版本**: 4.x (master)

---

## 1. 定位与上下文

BlockManager 是 Spark 存储体系的核心，负责：
- **Block 元数据管理**（在哪存、存多大、存哪台机器）
- **读写请求路由**（本地优先，远程兜底）
- **Shuffle 数据持久化**（ShuffleBlockResolver）
- **与 Driver 端 BlockManagerMaster 心跳上报**

```
SparkEnv
  └─ BlockManager (per Executor / Driver)
       ├─ MemoryStore     — 堆内/堆外内存块管理
       ├─ DiskStore        — 磁盘文件块管理
       ├─ BlockInfoManager — 块读写锁与元数据
       ├─ BlockTransferService — 网络传输（Fetch / Push）
       ├─ ShuffleManager   — Shuffle 数据读写
       └─ BlockManagerMaster — 与 Driver 心跳 & 元数据同步
```

---

## 2. Block 生命周期

### 2.1 BlockId 命名体系

```scala
sealed abstract class BlockId {
  def name: String  // 全局唯一名称
}

case class RDDBlockId(rddId: Int, partitionIndex: Int)  // RDD Cache
case class ShuffleBlockId(shuffleId: Int, mapId: Int, reduceId: Int)  // Shuffle 数据
case class BroadcastBlockId(broadcastId: Long, field = "")  // 广播变量 pieces
case class TaskResultBlockId(taskId: Long)  // Task 结果
case class StreamBlockId(streamId: Long, uniqueId: Long)  // 流数据
case class TempBlockId(uid: Long)  // 临时块（写入中）
case class TempLocalBlockId(uid: BlockId)  // 本地临时块
```

### 2.2 BlockInfo — 元数据与读写锁

```scala
class BlockInfo(
    val classTag: ClassTag[_],
    val writer: DataWriteLock,
    val tellMaster: Boolean) {

  @volatile var size: Long = -1
  @volatile var checksum: Option[Long] = None
  @volatile var cohort: Option[MemoryStoreCohort] = None  // LRFU 淘汰组
}
```

**读写锁模型**：
- **写锁**：`putBytes`/`putIterator` 时获取 `writer`（排他锁），写完后释放
- **读锁**：`getValues`/`getBytes` 时通过 `BlockInfoManager.lockForReading(blockId)` 获取读锁
- **读-写互斥**：读锁和写锁互斥（同一个 Block 不可同时读写）

---

## 3. getRemoteBytes — 远程 Block 拉取

当 Executor 本地没有目标 Block 时，通过网络拉取：

```scala
def getRemoteBytes(blockId: BlockId): Option[ChunkedByteBuffer] = {
  val locations = getLocations(blockId)  // ⬅ 询问 BlockManagerMaster
  if (locations.isEmpty) return None

  // 按距离排序（本地 > 同节点 > 同机架 > 跨机架）
  val sortedLocations = sortLocations(locations)

  for (loc <- sortedLocations) {
    val blockManagerId = BlockManagerId(loc.executorId, loc.host, loc.port, None)
    try {
      // 通过 BlockTransferService 拉取
      val result = blockTransferService.fetchBlockSync(
        loc.host, loc.port, loc.executorId, blockId.toString)
      return Some(result)
    } catch {
      case e: Exception =>
        logWarning(s"Failed to fetch block $blockId from $loc", e)
        // 尝试下一个位置
    }
  }
  None
}
```

**关键设计**：
- **按拓扑排序拉取**：优先从本地（同 JVM）拉取 → 同节点 → 同机架 → 远程
- **Failover**：第一个位置失败自动尝试下一个位置
- **串行拉取**：每个 Block 一次只从一个位置拉取（避免重复网络开销）

---

## 4. getLocalBytes — 本地 Block 读取

```scala
def getLocalBytes(blockId: BlockId): Option[BlockData] = {
  val info = blockInfoManager.assertInfoForReading(blockId)

  // 按存储层级依次查找：Memory → Disk
  memoryStore.getBytes(blockId).map { chunkedByteBuffer =>
    new ByteBufferBlockData(chunkedByteBuffer, false)
  }.orElse {
    diskStore.getBytes(blockId).map { fileSegment =>
      new ByteBufferBlockData(ByteBuffer.wrap(bytes), true)  // mapped ByteBuffer
    }
  }.map { blockData =>
    // 释放读锁
    releaseLock(blockId)
    blockData
  }.getOrElse {
    releaseLock(blockId)
    throw new SparkException(s"Block $blockId not found on local")
  }
}
```

---

## 5. putBytes / putSingle — 写入路径

```scala
// 序列化块写入（适合 Shuffle 结果 / Broadcast pieces）
def putBytes[T: ClassTag](
    blockId: BlockId,
    _bytes: ChunkedByteBuffer,
    level: StorageLevel,
    tellMaster: Boolean): Boolean = {
  require(!containsBlock(blockId))

  // 尝试写入 Memory
  if (level.useMemory) {
    if (memoryStore.putBytes(blockId, _bytes.size, memoryMode, () => _bytes)) {
      reportWrite(blockId, _bytes.size, level, tellMaster)
      return true
    }
    // 空间不足，尝试写入 Disk
    if (level.useDisk) {
      diskStore.write(blockId, _bytes.toInputStream(), true)
      reportWrite(blockId, _bytes.size, level, tellMaster)
      return true
    }
  }
  false
}

// 反序列化块写入（适合用户数据结构 / RDD Cache）
def putSingle[T: ClassTag](
    blockId: BlockId,
    values: Iterator[_],
    level: StorageLevel,
    tellMaster: Boolean): Boolean = {
  // 走 putIterator 路径（MemoryStore 内部展开）
  val size = memoryStore.putIteratorAsValues(...)
  reportWrite(blockId, size, level, tellMaster)
  true
}
```

**存储层级优先级**：
```
写入: Memory → Disk (Memory 满则溢写到 Disk)
读取: Memory → Disk
```

---

## 6. 心跳上报与元数据同步

```scala
private val heartBeat: ScheduledFuture[_] = {
  scheduleAtFixedRate(
    () => { if (registered) { sendHeartBeat() } },
    0L, // 初始延迟
    blockManagerId.periodicHeartBeatInterval,  // 默认 10s
    TimeUnit.MILLISECONDS)
}

private def sendHeartBeat(): Unit = {
  val updatedBlocks = blockInfoManager.synchronized {
    val updatedBlocks = new ArrayBuffer[(BlockId, BlockStatus)]
    for ((blockId, info) <- blockInfoManager.entries) {
      if (info.writer.isHeldByCurrentThread) {
        // 正在写入的块：上报 PENDING
        updatedBlocks += (blockId -> BlockStatus(StorageLevel.NONE, 0, 0))
      } else {
        updatedBlocks += (blockId -> getStatus(blockId))
      }
    }
    updatedBlocks
  }
  // 发送到 Driver 的 BlockManagerMasterActor
  masterActor.askWithReply[HeartbeatAck](Heartbeat(blockManagerId, updatedBlocks))
}
```

**Driver 端 BlockManagerMaster** 维护全集群 Block 位置映射，供 `getLocations(blockId)` 查询。

---

## 7. Shuffle 数据与 BlockManager 的交互

```scala
// ShuffleBlockResolver 负责 Shuffle 数据的读写路径
// ShuffleWriter.write() → ShuffleExternalSorter.write() → 本地磁盘
// ShuffleReader.fetch() → BlockTransferService.fetchBlocks() → 远程拉取

// IndexShuffleBlockResolver 维护 shuffle data 文件的索引
// .data 文件 → Shuffle 数据（按 reduceId 排序）
// .index 文件 → 每个 mapId 的 offset 索引
```

---

## 8. 安全 decommission

Executor 下线时，安全迁移或删除其上的 Block：

```scala
case DecommissionBlockManager =>
  logInfo("Decommissioning block manager")
  // 1. 将本地 RDD Cache 复制到其他 Executor
  // 2. Shuffle 数据标记为 stale（后续由其他节点重新计算）
  // 3. 注销与 Driver 的注册关系
  context.reply(true)
```

---

## 9. 完整数据流总图

```
写路径（Shuffle / Cache / Broadcast）:
  Task.run()
    └─ ShuffleWriter.write() / RDD.iterator()
         └─ ShuffleExternalSorter / MemoryStore.putIterator()
              └─ BlockManager.putBytes() / putSingle()
                   ├─ MemoryStore.putBytes()
                   │    └─ MemoryManager.acquireStorageMemory()
                   │         └─ evictBlocksToFreeSpace() (LRU)
                   └─ DiskStore.write() (溢出时)

读路径:
  Task.fetchRemoteBlocks() / RDD.compute()
    └─ BlockManager.getLocalBytes()
         ├─ MemoryStore.getBytes() → 命中 ✅
         └─ DiskStore.getBytes() → 命中 ✅
    或
    └─ BlockManager.getRemoteBytes()
         └─ BlockTransferService.fetchBlockSync()
              └─ 写入本地 MemoryStore → 其他 Executor 可复用

Driver 元数据同步:
  BlockManager.sendHeartBeat()
    └─ BlockManagerMasterActor.Heartbeat()
         └─ 更新 Driver 端 BlockLocations 映射
```

---

## 10. 踩坑 & 运维要点

| 场景 | 现象 | 根因 | 解决 |
|------|------|------|------|
| `Block not found locally` | Shuffle fetch 失败 | Map 端数据已被清理 | 检查 `spark.shuffle.service.enabled` 或 `spark.cleaner.referenceTracking.blockStatus` |
| BlockManagerMaster 内存泄漏 | Driver OOM（大量 block） | Shuffle 数据过多未清理 | 升级到 External Shuffle Service |
| DiskStore 写入失败 | `IOException: No space left on device` | 磁盘满 | 配置多目录 `spark.local.dirs`；清理旧数据 |
| Fetch 失败重试风暴 | Stage 重试导致集群抖动 | 热点 Block 所在节点过载 | 增加 replication；开启 `spark.shuffle.reduceLocality.enabled` |
| Block 读锁持有不释放 | 其他 Task 卡住读同一 Block | 代码 bug 异常未释放锁 | Spark 内部有超时检测；升级版本 |
| broadcast 数据本地读失败 | 走网络读取，延迟高 | Driver 未注册 piece → Executor 找不到本地块 | 确保 `tellMaster = true` |
