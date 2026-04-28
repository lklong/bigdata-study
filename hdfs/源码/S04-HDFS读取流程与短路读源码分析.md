# S04-HDFS 读取流程与短路读源码分析

> **组件版本**: Apache Hadoop 3.x (基于 txProjects/hadoop 源码)
> **源码路径**: `hadoop-hdfs-project/hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/`
> **核心类**: `DFSInputStream`、`BlockReaderLocal`、`BlockReaderFactory`、`DFSClient`
> **分析日期**: 2026-04-27

---

## 一、问题/场景

### 1.1 核心问题
- HDFS 读取流程从 `open()` 到 `read()` 经历了哪些步骤？
- 客户端如何选择读取数据的 DataNode？
- 短路读 (Short-Circuit Read) 是什么？如何通过 DomainSocket 实现？
- 集中式缓存管理 (Centralized Cache Management) 如何加速读取？

### 1.2 典型生产场景
- Spark/MapReduce 数据本地性 (Data Locality) 优化
- 热点数据频繁读取导致 DataNode 网络瓶颈
- 短路读配置不当导致本地数据仍走网络读取

---

## 二、读取架构总览

### 2.1 三种读取模式对比

```
模式 1: 远程读取 (Remote Read) — 最常见
  Client ──── TCP Socket ────► DataNode ──── Disk I/O ────► 数据文件
  (完整 TCP 通信链路，适用于跨节点读取)

模式 2: 短路读 (Short-Circuit Read) — 本地优化
  Client ──── DomainSocket ────► DataNode: "给我文件描述符"
  Client ──── 直接读 FD ────► 数据文件 (绕过 DataNode 进程)
  (Client 和 DataNode 同机时，避免数据拷贝)

模式 3: 零拷贝读 (Zero-Copy Read) — 最快
  Client ──── mmap ────► 内核缓存/集中式缓存 ────► 数据文件
  (利用 HDFS Centralized Cache，数据已在内存中)
```

### 2.2 读取选择决策树

```
Client.read()
  │
  ├── Block 位置在本地？
  │     ├── Yes: 短路读启用？
  │     │     ├── Yes: DomainSocket 可用？
  │     │     │     ├── Yes → Short-Circuit Read (BlockReaderLocal)
  │     │     │     └── No  → Remote Read (BlockReaderRemote)
  │     │     └── No  → Remote Read
  │     └── No → Remote Read
  │
  └── Block 在集中式缓存中？
        ├── Yes → Zero-Copy Read (通过 mmap)
        └── No  → 普通读取路径
```

---

## 三、调用链总览

### 3.1 文件打开流程

```
FileSystem.open(path)
  └── DistributedFileSystem.open()
        └── DFSClient.open(src)
              └── new DFSInputStream(dfsClient, src, verifyChecksum, null)
                    └── openInfo(false)
                          └── fetchLocatedBlocksAndGetLastBlockLength()
                                └── dfsClient.namenode.getBlockLocations()  // RPC
                                      // 返回 LocatedBlocks: 文件的所有 Block 位置信息
```

### 3.2 数据读取流程

```
DFSInputStream.read(buf, off, len)
  └── readWithStrategy(strategy)
        └── 如果 blockReader == null 或偏移不匹配:
        │     └── blockSeekTo(target)
        │           ├── getBlockAt(target)             // 找到目标 Block
        │           ├── chooseDataNode(targetBlock)     // 选择最佳 DataNode
        │           └── getBlockReader(targetBlock, ...) // 创建 BlockReader
        │                 └── BlockReaderFactory.build()
        │                       ├── 尝试 Short-Circuit Read
        │                       │     └── new BlockReaderLocal(shortCircuitReplica)
        │                       ├── 尝试 Remote Read
        │                       │     └── new BlockReaderRemote(peer)
        │                       └── 尝试 Cache Read
        │                             └── getRemoteBlockReaderFromCache()
        └── blockReader.read(buf, off, len)            // 实际读取
```

---

## 四、核心源码分析

### 4.1 DFSInputStream 构造 — openInfo

```java
// 文件: DFSInputStream.java, 行 261-310
DFSInputStream(DFSClient dfsClient, String src, boolean verifyChecksum,
    LocatedBlocks locatedBlocks) throws IOException {
    this.dfsClient = dfsClient;
    this.verifyChecksum = verifyChecksum;
    this.src = src;
    synchronized (infoLock) {
      this.cachingStrategy = dfsClient.getDefaultReadCachingStrategy();
    }
    this.locatedBlocks = locatedBlocks;
    openInfo(false);
}

void openInfo(boolean refreshLocatedBlocks) throws IOException {
    final DfsClientConf conf = dfsClient.getConf();
    synchronized(infoLock) {
      lastBlockBeingWrittenLength =
          fetchLocatedBlocksAndGetLastBlockLength(refreshLocatedBlocks);
      int retriesForLastBlockLength = conf.getRetryTimesForGetLastBlockLength();
      while (retriesForLastBlockLength > 0) {
        // ★ 集群重启时 DN 可能尚未汇报 Block，需要重试
        if (lastBlockBeingWrittenLength == -1) {
          DFSClient.LOG.warn("Last block locations not available. "
              + "Datanodes might not have reported blocks completely."
              + " Will retry for " + retriesForLastBlockLength + " times");
          waitFor(conf.getRetryIntervalForGetLastBlockLength());
          lastBlockBeingWrittenLength =
              fetchLocatedBlocksAndGetLastBlockLength(true);
        } else {
          break;
        }
        retriesForLastBlockLength--;
      }
      if (lastBlockBeingWrittenLength == -1 && retriesForLastBlockLength == 0) {
        throw new IOException("Could not obtain the last block locations.");
      }
    }
}
```

**关键点**:
- `openInfo()` 通过 RPC 获取文件所有 Block 的位置信息（`LocatedBlocks`）
- 每个 `LocatedBlock` 包含: Block ID、大小、DataNode 列表（按网络距离排序）
- 对于正在写入的文件（最后一个 Block 未完成），需要重试获取实际长度

### 4.2 blockSeekTo — 定位并连接目标 DataNode

```java
// 文件: DFSInputStream.java, 行 616-683
private synchronized DatanodeInfo blockSeekTo(long target) throws IOException {
    if (target >= getFileLength()) {
      throw new IOException("Attempted to read past end of file");
    }
    closeCurrentBlockReaders();   // 关闭旧的 BlockReader

    DatanodeInfo chosenNode;
    int refetchToken = 1;
    int refetchEncryptionKey = 1;
    boolean connectFailedOnce = false;

    while (true) {
      // ★ 1. 根据偏移找到对应的 LocatedBlock
      LocatedBlock targetBlock = getBlockAt(target);

      this.pos = target;
      this.blockEnd = targetBlock.getStartOffset() +
          targetBlock.getBlockSize() - 1;
      this.currentLocatedBlock = targetBlock;

      long offsetIntoBlock = target - targetBlock.getStartOffset();

      // ★ 2. 选择最佳 DataNode
      DNAddrPair retval = chooseDataNode(targetBlock, null);
      chosenNode = retval.info;
      InetSocketAddress targetAddr = retval.addr;
      StorageType storageType = retval.storageType;
      targetBlock = retval.block;

      try {
        // ★ 3. 创建 BlockReader
        blockReader = getBlockReader(targetBlock, offsetIntoBlock,
            targetBlock.getBlockSize() - offsetIntoBlock, targetAddr,
            storageType, chosenNode);
        return chosenNode;
      } catch (IOException ex) {
        if (ex instanceof InvalidEncryptionKeyException && refetchEncryptionKey > 0) {
          refetchEncryptionKey--;
          dfsClient.clearDataEncryptionKey();
        } else if (refetchToken > 0 && tokenRefetchNeeded(ex, targetAddr)) {
          refetchToken--;
          fetchBlockAt(target);
        } else {
          connectFailedOnce = true;
          DFSClient.LOG.warn("Failed to connect to " + targetAddr
              + " for block, add to deadNodes and continue.");
          // ★ 连接失败，加入黑名单，重试其他 DN
          addToDeadNodes(chosenNode);
        }
      }
    }
}
```

**重试策略**:
1. 首先尝试 Token/Key 刷新（可能是凭证过期）
2. 如果连接本身失败，将 DN 加入 `deadNodes` 黑名单
3. 下次循环会选择另一个 DN（黑名单中的 DN 被排除）

### 4.3 chooseDataNode — DataNode 选择策略

```java
// 文件: DFSInputStream.java, 行 1028-1041
private DNAddrPair chooseDataNode(LocatedBlock block,
    Collection<DatanodeInfo> ignoredNodes, boolean refetchIfRequired)
    throws IOException {
    while (true) {
      // ★ 获取最佳节点（按网络距离排序后的第一个可用节点）
      DNAddrPair result = getBestNodeDNAddrPair(block, ignoredNodes);
      if (result != null) {
        return result;
      } else if (refetchIfRequired) {
        // ★ 所有节点都不可用，重新从 NameNode 获取位置
        block = refetchLocations(block, ignoredNodes);
      } else {
        return null;
      }
    }
}
```

**DataNode 选择优先级** (由 NameNode 排序):
1. **本地节点** (Same Node) — 距离 0
2. **同机架节点** (Same Rack) — 距离 2
3. **不同机架节点** (Off Rack) — 距离 4
4. **不同数据中心** (Off Data Center) — 距离 6

### 4.4 getBlockReader — BlockReader 工厂

```java
// 文件: DFSInputStream.java, 行 685-714
protected BlockReader getBlockReader(LocatedBlock targetBlock,
    long offsetInBlock, long length, InetSocketAddress targetAddr,
    StorageType storageType, DatanodeInfo datanode) throws IOException {
    ExtendedBlock blk = targetBlock.getBlock();
    Token<BlockTokenIdentifier> accessToken = targetBlock.getBlockToken();
    CachingStrategy curCachingStrategy;
    boolean shortCircuitForbidden;
    synchronized (infoLock) {
      curCachingStrategy = cachingStrategy;
      shortCircuitForbidden = shortCircuitForbidden();
    }
    // ★ 使用 Builder 模式构建 BlockReader
    return new BlockReaderFactory(dfsClient.getConf()).
        setInetSocketAddress(targetAddr).
        setRemotePeerFactory(dfsClient).
        setDatanodeInfo(datanode).
        setStorageType(storageType).
        setFileName(src).
        setBlock(blk).
        setBlockToken(accessToken).
        setStartOffset(offsetInBlock).
        setVerifyChecksum(verifyChecksum).
        setClientName(dfsClient.clientName).
        setLength(length).
        setCachingStrategy(curCachingStrategy).
        setAllowShortCircuitLocalReads(!shortCircuitForbidden).  // ★ 短路读控制
        setClientCacheContext(dfsClient.getClientContext()).
        setUserGroupInformation(dfsClient.ugi).
        setConfiguration(dfsClient.getConfiguration()).
        build();
}
```

`BlockReaderFactory.build()` 内部按优先级尝试:
1. **Short-Circuit Read**: 如果允许且是本地节点
2. **Domain Socket Remote Read**: 通过 Unix Domain Socket 读取
3. **TCP Remote Read**: 标准 TCP 网络读取

---

## 五、短路读 (Short-Circuit Read) 深度分析

### 5.1 短路读原理

```
传统读取 (需要经过 DataNode 进程):
  Client ───TCP──→ DataNode ───read()──→ 磁盘文件
  Client ◄──TCP──── DataNode ◄──data──── 磁盘文件
  (数据经过 DataNode 进程空间，涉及多次拷贝)

短路读 (绕过 DataNode 进程):
  1. Client ──DomainSocket──→ DataNode: "请给我 Block 的文件描述符 (FD)"
  2. DataNode ──DomainSocket──→ Client: 传递 data FD + meta FD
  3. Client ──直接 read(FD)──→ 磁盘文件
  (数据不经过 DataNode 进程空间，减少一次内存拷贝)
```

### 5.2 BlockReaderLocal — 短路读实现

```java
// 文件: BlockReaderLocal.java, 行 49-65
/**
 * BlockReaderLocal enables clients on the same machine as the datanode
 * to read files directly from the local file system rather than going
 * through the datanode for better performance.
 *
 * BlockReaderLocal works as follows:
 * 1. The client performing short circuit reads must be configured at the datanode.
 * 2. The client gets the file descriptors for the metadata file and the data
 *    file for the block using DataXceiver.requestShortCircuitFds.
 * 3. The client reads the file descriptors.
 */
class BlockReaderLocal implements BlockReader {
    static final Logger LOG = LoggerFactory.getLogger(BlockReaderLocal.class);
    private static final DirectBufferPool bufferPool = new DirectBufferPool();
    
    // ★ ShortCircuitReplica 封装了数据文件和元数据文件的 FileChannel
    private final ShortCircuitReplica replica;
    
    // 读取位置
    private long dataPos;
}
```

### 5.3 ShortCircuitReplica — 文件描述符封装

```
ShortCircuitReplica 结构:
  ├── dataStream (FileInputStream → FileChannel)  // Block 数据文件 FD
  ├── metaStream (FileInputStream → FileChannel)   // Block 元数据文件 FD (checksum)
  ├── mmapData (MappedByteBuffer)                  // 可选：mmap 映射
  └── slot (ShortCircuitShm.Slot)                  // 共享内存槽位
```

### 5.4 DomainSocket 传递文件描述符

```
短路读建立流程:

  Client                              DataNode
    │                                    │
    │  1. 通过 DomainSocket 连接         │
    │  ──────────────────────────────►   │
    │                                    │
    │  2. 发送 requestShortCircuitFds    │
    │  ──────────────────────────────►   │
    │     (Block ID, Token)              │
    │                                    │
    │  3. DataNode 打开 Block 文件       │
    │                                    │  fd_data = open(block_file)
    │                                    │  fd_meta = open(meta_file)
    │                                    │
    │  4. 通过 DomainSocket 传递 FD      │
    │  ◄──────────────────────────────   │
    │     (fd_data, fd_meta)             │
    │                                    │
    │  5. Client 直接通过 FD 读取数据    │
    │  ──── FileChannel.read() ────►  磁盘
    │
```

**关键技术**: Unix Domain Socket 支持通过 `sendmsg/recvmsg` 传递文件描述符（SCM_RIGHTS），使得 Client 进程可以获得 DataNode 打开的文件句柄，直接读取磁盘文件。

### 5.5 BlockReaderLocal.read() — 直接读取

```java
// 文件: BlockReaderLocal.java, 行 405-440 (简化)
public synchronized int read(ByteBuffer buf) throws IOException {
    // ★ 直接通过 FileChannel 读取 Block 数据
    int nRead = dataIn.read(buf, dataPos);
    if (nRead < 0) {
      return nRead;
    }
    
    if (verifyChecksum) {
      // ★ 可选：校验 checksum
      // 从 metaIn (元数据 FileChannel) 读取对应的 checksum
      // 与数据的实际 checksum 对比
    }
    
    dataPos += nRead;
    return nRead;
}
```

---

## 六、读取失败与重试机制

### 6.1 DeadNodes 黑名单机制

```
读取失败处理:

  read() 失败
    │
    ├── ChecksumException (校验失败)
    │   └── 报告 NameNode: reportBadBlocks()
    │   └── 加入 deadNodes
    │   └── 选择其他 DN 重试
    │
    ├── IOException (连接失败/超时)
    │   └── 加入 deadNodes
    │   └── 重试其他 DN
    │   └── 超过最大重试次数 → 从 NameNode 重新获取 Block 位置
    │
    └── BlockMissingException
        └── 所有 DN 都不可用
        └── 抛出异常给上层
```

### 6.2 refetchLocations — 重新获取位置

```java
// 文件: DFSInputStream.java, 行 1043-1072 (简化)
private LocatedBlock refetchLocations(LocatedBlock block,
    Collection<DatanodeInfo> ignoredNodes) throws IOException {
    if (failures >= dfsClient.getConf().getMaxBlockAcquireFailures()) {
      throw new BlockMissingException(src, description,
          block.getStartOffset());
    }
    // ★ 指数退避等待
    // 第 1 次: 随机 0~3000ms
    // 第 2 次: 3000ms + 随机 0~6000ms
    // 第 3 次: 6000ms + 随机 0~9000ms
    Thread.sleep(waitTime);

    // ★ 重新从 NameNode 获取最新的 Block 位置
    openInfo(true);
    block = refreshLocatedBlock(block);
    failures++;
    return block;
}
```

---

## 七、集中式缓存管理 (Centralized Cache Management)

### 7.1 概述

HDFS Centralized Cache 允许管理员将特定路径的 Block 缓存到 DataNode 的堆外内存中：

```
管理员命令:
  hdfs cacheadmin -addDirective -path /hot/data -pool my_pool

流程:
  1. NameNode 记录缓存指令
  2. NameNode 选择 DataNode 缓存 Block
  3. DataNode 通过 mmap 将 Block 加载到内存
  4. Client 读取时可以零拷贝访问缓存数据
```

### 7.2 缓存读取路径

```
Client.read()
  └── BlockReaderFactory.build()
        └── tryToCreateBlockReaderLocal()
              └── 检查 ShortCircuitCache 是否有缓存的 Replica
              └── 如果有 mmap 映射 → 直接从内存读取（零拷贝）
              └── 如果没有 → 创建 BlockReaderLocal 从磁盘读取
```

---

## 八、读取流程完整时序图

```
时间线

├── DFSClient.open("/path/to/file")
│   └── new DFSInputStream()
│       └── openInfo(false)
│           └── namenode.getBlockLocations("/path/to/file", 0, Long.MAX_VALUE)
│               └── 返回 LocatedBlocks:
│                   Block-0: [DN-1(本地), DN-3(同机架), DN-5(远程机架)]
│                   Block-1: [DN-2(远程), DN-4(同机架), DN-6(远程机架)]
│
├── DFSInputStream.read(buf, 0, 4096)
│   └── blockSeekTo(0)
│       ├── getBlockAt(0) → Block-0
│       ├── chooseDataNode(Block-0) → DN-1 (本地，距离最近)
│       └── getBlockReader(Block-0, DN-1)
│           └── BlockReaderFactory.build()
│               ├── 检测 DN-1 在本地
│               ├── 短路读启用 → 尝试 Short-Circuit Read
│               │   └── 通过 DomainSocket 获取 FD
│               │   └── new BlockReaderLocal(replica)
│               └── 成功！
│   └── blockReader.read(buf, 0, 4096)
│       └── dataIn.read(buf, dataPos)  // 直接从 FD 读取
│
├── 继续读取到 Block-0 结束
│   └── blockSeekTo(Block-1 的起始偏移)
│       ├── getBlockAt(offset) → Block-1
│       ├── chooseDataNode(Block-1) → DN-2 (远程)
│       └── getBlockReader(Block-1, DN-2)
│           └── BlockReaderFactory.build()
│               └── 非本地 → Remote Read
│               └── new BlockReaderRemote(peer)
│   └── blockReader.read(buf, ...)
│       └── 通过 TCP Socket 从 DN-2 读取
│
└── close()
    └── closeCurrentBlockReaders()
```

---

## 九、关键参数与调优建议

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `dfs.client.read.shortcircuit` | false | 启用短路读 | 生产环境建议开启 |
| `dfs.domain.socket.path` | - | DomainSocket 路径 | 必须配置才能使用短路读 |
| `dfs.client.read.shortcircuit.skip.checksum` | false | 跳过短路读 checksum | 性能敏感可开启 |
| `dfs.client.read.shortcircuit.buffer.size` | 1MB | 短路读缓冲区大小 | |
| `dfs.datanode.max.locked.memory` | 0 | DN 最大缓存内存 | 集中式缓存需配置 |
| `dfs.client.cache.readahead` | - | 预读大小 | |
| `dfs.client.failover.max.attempts` | 15 | 最大失败重试次数 | |
| `dfs.client.max.block.acquire.failures` | 3 | Block 获取最大失败次数 | |

### 调优场景

**场景 1: 启用短路读**
```xml
<!-- Client 和 DataNode 都需要配置 -->
<property>
  <name>dfs.client.read.shortcircuit</name>
  <value>true</value>
</property>
<property>
  <name>dfs.domain.socket.path</name>
  <value>/var/lib/hadoop-hdfs/dn_socket</value>
</property>
```

**场景 2: 热点数据缓存**
```bash
# 创建缓存池
hdfs cacheadmin -addPool hot_pool -owner hdfs -limit 10737418240  # 10GB

# 缓存热点数据
hdfs cacheadmin -addDirective -path /warehouse/hot_table -pool hot_pool -replication 1
```

**场景 3: DataNode 缓存配置**
```xml
<property>
  <name>dfs.datanode.max.locked.memory</name>
  <value>8589934592</value> <!-- 8GB -->
</property>
```

---

## 十、踩坑记录

### 坑 1: 短路读的 DomainSocket 权限问题
`dfs.domain.socket.path` 指定的路径必须是 DataNode 进程可写、Client 进程可读写的。通常设置在 `/var/lib/hadoop-hdfs/` 下。权限问题是短路读无法生效的最常见原因。

### 坑 2: deadNodes 导致的性能下降
`deadNodes` 是每个 `DFSInputStream` 实例的黑名单。如果某个 DN 暂时网络抖动被加入黑名单，后续所有读取都会跳过它，可能导致数据本地性降低。黑名单在 `DFSInputStream` 关闭前不会清除。

### 坑 3: LocatedBlocks 缓存过时
`openInfo()` 获取的 Block 位置信息在整个读取过程中可能过时（Block 被移动或 DN 下线）。虽然有 `refetchLocations()` 机制，但频繁 refetch 会增加 NameNode RPC 压力。

### 坑 4: 短路读和 checksum
即使使用短路读，默认仍然会验证 checksum。对于性能要求极高的场景，可以设置 `dfs.client.read.shortcircuit.skip.checksum=true`，但这会牺牲数据完整性保证。

### 坑 5: 集中式缓存的 locked memory 限制
DataNode 的缓存使用 `mlock` 系统调用锁定内存。需要确保：
1. `dfs.datanode.max.locked.memory` 不超过 OS 的 `ulimit -l` 限制
2. 不与 DataNode 的 JVM 堆争抢内存

---

## 十一、认知更新

1. **HDFS 读取是 "惰性" 的**: `open()` 只获取 Block 位置，`read()` 时才建立连接
2. **DataNode 选择是距离优先的**: NameNode 返回的 Block 位置已按网络距离排序
3. **短路读的本质是传递文件描述符**: 通过 Unix DomainSocket 的 SCM_RIGHTS 机制
4. **BlockReader 是可插拔的**: 通过 `BlockReaderFactory` 统一创建，支持 Local/Remote/Cache 三种实现
5. **读取失败重试有指数退避**: 不是简单重试，每次等待时间递增
6. **集中式缓存是管理员主动行为**: 不是 LRU 自动缓存，需要明确指定路径
7. **短路读对写入场景无效**: 短路读仅用于 Complete 状态的 Block，正在写入的 Block 不支持
