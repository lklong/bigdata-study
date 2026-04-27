# S03-HDFS 写入流水线 Pipeline 源码分析

> **组件版本**: Apache Hadoop 3.x (基于 txProjects/hadoop 源码)
> **源码路径**: `hadoop-hdfs-project/hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/`
> **核心类**: `DFSOutputStream`、`DataStreamer`、`ResponseProcessor`、`DFSPacket`
> **分析日期**: 2026-04-27

---

## 一、问题/场景

### 1.1 核心问题
- HDFS 写入流水线 (Pipeline) 是如何建立的？
- Packet 是怎么发送和 ACK 的？数据流如何在 Pipeline 中流动？
- 当 Pipeline 中某个 DataNode 故障时，如何恢复？
- `hflush()` 和 `hsync()` 的语义差异是什么？

### 1.2 典型生产场景
- Spark/Hive 作业写数据时偶发超时，排查 Pipeline 建立和故障恢复机制
- 日志采集 (Flume) 需要数据可见性保证，选择 `hflush` 还是 `hsync`
- Pipeline Recovery 导致写入抖动

---

## 二、写入架构总览

### 2.1 Pipeline 写入模型

```
  Client                  DN-1                  DN-2                  DN-3
    │                      │                      │                      │
    │  ┌─ Packet 1 ──────►│  ┌─ Packet 1 ──────►│  ┌─ Packet 1 ──────►│
    │  │                   │  │                   │  │                   │
    │  │   (Data Flow)     │  │   (Data Flow)     │  │   (Data Flow)     │
    │  │                   │  │                   │  │                   │
    │  │◄── ACK 1 ─────── │  │◄── ACK 1 ─────── │  │◄── ACK 1 ─────── │
    │  │                   │  │                   │  │                   │
    │  │   (ACK Flow)      │  │   (ACK Flow)      │  │   (ACK Flow)     │
    │  └───────────────────┘  └───────────────────┘  └──────────────────┘
    │
    │  数据从 Client → DN-1 → DN-2 → DN-3 (正向流水线)
    │  ACK 从 DN-3 → DN-2 → DN-1 → Client (反向确认)
```

### 2.2 数据分层

```
  文件 (File)
   └── Block (默认 128MB)
        └── Packet (默认 64KB)
             └── Chunk (默认 512B + 4B checksum)
```

---

## 三、调用链总览

### 3.1 文件创建与 Pipeline 建立

```
DFSClient.create()
  └── DFSOutputStream.newStreamForCreate()
        ├── dfsClient.namenode.create()              // RPC: NameNode 创建文件
        ├── new DFSOutputStream(dfsClient, src, stat, ...)
        │     └── new DataStreamer(stat, null, dfsClient, ...)
        └── out.start()                              // 启动 DataStreamer 线程

DataStreamer.run() 主循环:
  └── stage == PIPELINE_SETUP_CREATE
        └── nextBlockOutputStream()                  // 向 NameNode 申请新 Block
        │     ├── dfsClient.namenode.addBlock()      // RPC: 获取 Block 位置
        │     └── createBlockOutputStream()          // 建立到 DN-1 的 Socket 连接
        │           └── DN-1 内部建立到 DN-2 的连接
        │                 └── DN-2 内部建立到 DN-3 的连接
        └── setPipeline(lb)                          // 设置 Pipeline 节点列表
        └── initDataStreaming()                      // 切换到 DATA_STREAMING 阶段
              └── new ResponseProcessor(nodes)       // 启动 ACK 接收线程
```

### 3.2 Packet 发送流程

```
应用层 write():
  └── DFSOutputStream.write(buf)
        └── FSOutputSummer.write1() → writeChecksumChunks()
              └── writeChunk() → 填充 currentPacket
              └── currentPacket 满 → enqueueCurrentPacketFull()
                    └── dataQueue.addLast(currentPacket)  // 放入发送队列
                    └── dataQueue.notifyAll()              // 唤醒 DataStreamer

DataStreamer.run() 主循环:
  └── one = dataQueue.getFirst()                       // 取出 Packet
  └── 发送 Packet 到 DN-1
        └── one.writeTo(blockStream)                   // 写入 Socket
  └── dataQueue → ackQueue                             // 移到 ACK 等待队列

ResponseProcessor.run():
  └── ack.readFields(blockReplyStream)                 // 从 DN-1 读取 ACK
  └── 检查每个 DN 的 reply 状态
  └── ackQueue.removeFirst()                           // ACK 成功，移出队列
```

---

## 四、核心源码分析

### 4.1 DFSOutputStream.newStreamForCreate — 创建输出流

```java
// 文件: DFSOutputStream.java, 行 250-302
static DFSOutputStream newStreamForCreate(DFSClient dfsClient, String src,
    FsPermission masked, EnumSet<CreateFlag> flag, boolean createParent,
    short replication, long blockSize, Progressable progress,
    DataChecksum checksum, String[] favoredNodes) throws IOException {
    try (TraceScope ignored =
             dfsClient.newPathTraceScope("newStreamForCreate", src)) {
      HdfsFileStatus stat = null;
      boolean shouldRetry = true;
      int retryCount = CREATE_RETRY_COUNT;   // 最多重试 10 次
      while (shouldRetry) {
        shouldRetry = false;
        try {
          // ★ RPC 调用 NameNode 创建文件
          stat = dfsClient.namenode.create(src, masked, dfsClient.clientName,
              new EnumSetWritable<>(flag), createParent, replication,
              blockSize, SUPPORTED_CRYPTO_VERSIONS);
          break;
        } catch (RemoteException re) {
          IOException e = re.unwrapRemoteException(
              AccessControlException.class,
              SafeModeException.class,           // 安全模式拒绝
              // ... 其他异常
              RetryStartFileException.class);    // 加密区操作需重试
          if (e instanceof RetryStartFileException) {
            if (retryCount > 0) {
              shouldRetry = true;
              retryCount--;
            }
          } else {
            throw e;
          }
        }
      }
      // ★ 创建 DFSOutputStream，内部创建 DataStreamer
      final DFSOutputStream out = new DFSOutputStream(dfsClient, src, stat,
          flag, progress, checksum, favoredNodes);
      out.start();  // 启动 DataStreamer 线程
      return out;
    }
}
```

**关键设计**:
- `create()` RPC 只在 NameNode 上创建文件元数据，此时还没有分配 Block
- DataStreamer 线程以 Daemon 方式启动，负责后续所有与 DataNode 的数据通信

### 4.2 DataStreamer.run() — 核心事件循环

```java
// 文件: DataStreamer.java, 行 639-738 (简化)
public void run() {
    long lastPacket = Time.monotonicNow();
    while (!streamerClosed && dfsClient.clientRunning) {
      // ★ 1. 检查是否有 DataNode 错误需要处理
      if (errorState.hasError() && response != null) {
        response.close();
        response.join();
        response = null;
      }

      DFSPacket one;
      try {
        boolean doSleep = processDatanodeError();  // Pipeline 恢复

        synchronized (dataQueue) {
          // ★ 2. 等待 Packet 或心跳超时
          while ((!shouldStop() && dataQueue.size() == 0 &&
              (stage != BlockConstructionStage.DATA_STREAMING ||
                  now - lastPacket < halfSocketTimeout)) || doSleep) {
            dataQueue.wait(timeout);
          }

          // ★ 3. 获取 Packet（空队列时发心跳包）
          if (dataQueue.isEmpty()) {
            one = createHeartbeatPacket();
          } else {
            one = dataQueue.getFirst();
          }
        }

        // ★ 4. Pipeline 建立阶段
        if (stage == BlockConstructionStage.PIPELINE_SETUP_CREATE) {
          LOG.debug("Allocating new block");
          setPipeline(nextBlockOutputStream());   // 申请 Block + 建立连接
          initDataStreaming();                     // 启动 ResponseProcessor
        } else if (stage == BlockConstructionStage.PIPELINE_SETUP_APPEND) {
          setupPipelineForAppendOrRecovery();
          initDataStreaming();
        }

        // ★ 5. 最后一个 Packet 时等待所有 ACK
        if (one.isLastPacketInBlock()) {
          synchronized (dataQueue) {
            while (!shouldStop() && ackQueue.size() != 0) {
              dataQueue.wait(1000);
            }
          }
        }

        // ★ 6. 发送 Packet
        // ... 发送逻辑 ...
      }
    }
}
```

**设计精要**:
- DataStreamer 是一个**单线程事件循环**，处理 Pipeline 建立、数据发送、错误恢复等所有状态
- 使用 `BlockConstructionStage` 枚举管理状态机
- 空闲时发送心跳包防止 Socket 超时

### 4.3 Pipeline 状态机

```
  PIPELINE_SETUP_CREATE
    │ (首次写入，需要向 NameNode 申请新 Block)
    │ nextBlockOutputStream() → addBlock() RPC
    │ createBlockOutputStream() → 建立 Pipeline
    ▼
  DATA_STREAMING
    │ (正常发送 Packet 的阶段)
    │ 如果 Block 写满 → 回到 PIPELINE_SETUP_CREATE
    │ 如果出错 → 进入 PIPELINE_SETUP_STREAMING_RECOVERY
    ▼
  PIPELINE_SETUP_STREAMING_RECOVERY
    │ (Pipeline 故障恢复)
    │ setupPipelineForAppendOrRecovery()
    │ 移除故障 DN，用剩余 DN 重建 Pipeline
    ▼
  DATA_STREAMING (恢复后继续)

  PIPELINE_SETUP_APPEND
    │ (追加写入场景)
    │ setupPipelineForAppendOrRecovery()
    ▼
  DATA_STREAMING
```

### 4.4 ResponseProcessor — ACK 接收

```java
// 文件: DataStreamer.java, 行 1052-1155 (简化)
private class ResponseProcessor extends Daemon {
    private volatile boolean responderClosed = false;
    private DatanodeInfo[] targets = null;
    private boolean isLastPacketInBlock = false;

    @Override
    public void run() {
      setName("ResponseProcessor for block " + block);
      PipelineAck ack = new PipelineAck();

      while (!responderClosed && dfsClient.clientRunning && !isLastPacketInBlock) {
        try {
          // ★ 从第一个 DataNode 读取 Pipeline ACK
          ack.readFields(blockReplyStream);
          long seqno = ack.getSeqno();

          // ★ 检查每个 DataNode 的回复状态
          for (int i = ack.getNumOfReplies()-1; i >= 0 && dfsClient.clientRunning; i--) {
            final Status reply = PipelineAck.getStatusFromHeader(ack.getHeaderFlag(i));

            // 检查 DataNode 拥塞信号
            if (PipelineAck.getECNFromHeader(ack.getHeaderFlag(i)) ==
                PipelineAck.ECN.CONGESTED) {
              congestedNodesFromAck.add(targets[i]);
            }

            // DataNode 重启检测
            if (PipelineAck.isRestartOOBStatus(reply)) {
              errorState.initRestartingNode(i, message, shouldWaitForRestart(i));
              throw new IOException(message);
            }

            // ★ 非成功状态 → 标记故障节点
            if (reply != SUCCESS) {
              errorState.setBadNodeIndex(i);
              throw new IOException("Bad response " + reply +
                  " for " + block + " from datanode " + targets[i]);
            }
          }

          // ★ ACK 成功，从 ackQueue 移除
          if (seqno == DFSPacket.HEART_BEAT_SEQNO) {
            continue;  // 心跳 ACK 跳过
          }
          DFSPacket one;
          synchronized (dataQueue) {
            one = ackQueue.getFirst();
          }
          if (one.getSeqno() != seqno) {
            throw new IOException("Expecting seqno " + one.getSeqno()
                + " but received " + seqno);
          }
          isLastPacketInBlock = one.isLastPacketInBlock();

          // ★ 确认成功，从 ackQueue 移除
          synchronized (dataQueue) {
            ackQueue.removeFirst();
            packetSendTime.remove(seqno);
            dataQueue.notifyAll();
          }
        } catch (Exception e) {
          if (!responderClosed) {
            hasError = true;
            errorState.setInternalError();
            // ... 错误处理
          }
        }
      }
    }
}
```

**ACK 处理流程**:
1. ACK 从最后一个 DN → 第一个 DN → Client 逐级返回
2. 每个 ACK 包含所有 DN 的回复状态
3. 任何一个 DN 返回非 SUCCESS，都标记为故障节点
4. 心跳 ACK（seqno == HEART_BEAT_SEQNO）不需要从 ackQueue 移除

### 4.5 Pipeline 故障恢复 — setupPipelineForAppendOrRecovery

```java
// 文件: DataStreamer.java, 行 1446-1488
private boolean setupPipelineForAppendOrRecovery() throws IOException {
    if (nodes == null || nodes.length == 0) {
      lastException.set(new IOException("Could not get block locations."));
      streamerClosed = true;
      return false;
    }

    boolean success = false;
    long newGS = 0L;
    while (!success && !streamerClosed && dfsClient.clientRunning) {
      // ★ 1. 处理正在重启的 DataNode
      if (!handleRestartingDatanode()) {
        return false;
      }

      final boolean isRecovery = errorState.hasError();

      // ★ 2. 移除故障 DataNode
      if (!handleBadDatanode()) {
        return false;
      }

      // ★ 3. 尝试替换故障 DataNode（可选）
      handleDatanodeReplacement();

      // ★ 4. 从 NameNode 获取新的 Generation Stamp
      final LocatedBlock lb = updateBlockForPipeline();
      newGS = lb.getBlock().getGenerationStamp();
      accessToken = lb.getBlockToken();

      // ★ 5. 用剩余节点重建 Pipeline
      success = createBlockOutputStream(nodes, storageTypes, newGS, isRecovery);

      errorState.checkRestartingNodeDeadline(nodes);
    }

    if (success) {
      // ★ 6. 通知 NameNode Pipeline 已更新
      updatePipeline(newGS);
    }
    return false; // do not sleep, continue processing
}
```

### 4.6 Pipeline Recovery 时序图

```
时间线

│  正常写入中: Client → DN-1 → DN-2 → DN-3
│
├── DN-2 故障！ResponseProcessor 检测到 ACK 异常
│   └── errorState.setBadNodeIndex(1)  // 标记 DN-2 为故障
│   └── ResponseProcessor 退出
│
├── DataStreamer.processDatanodeError()
│   └── stage = PIPELINE_SETUP_STREAMING_RECOVERY
│
├── setupPipelineForAppendOrRecovery()
│   ├── handleBadDatanode()
│   │   └── 从 nodes[] 移除 DN-2，nodes = [DN-1, DN-3]
│   │
│   ├── updateBlockForPipeline()        // RPC to NameNode
│   │   └── 获取新的 GenerationStamp (newGS)
│   │   └── NameNode 将 Block 状态更新为 UNDER_RECOVERY
│   │
│   ├── createBlockOutputStream(nodes=[DN-1, DN-3], newGS, isRecovery=true)
│   │   └── 建立新的 Pipeline: Client → DN-1 → DN-3
│   │   └── DN-1 和 DN-3 更新 Block 的 GenerationStamp
│   │
│   └── updatePipeline(newGS)           // RPC to NameNode
│       └── 通知 NameNode Pipeline 新节点列表和 newGS
│
├── initDataStreaming()                 // 启动新的 ResponseProcessor
│   └── stage = DATA_STREAMING
│
├── 重发 ackQueue 中未确认的 Packet
│
└── 继续正常写入: Client → DN-1 → DN-3
```

---

## 五、hflush vs hsync 语义分析

### 5.1 hflush — 数据可见性保证

```java
// 文件: DFSOutputStream.java, 行 524-529
@Override
public void hflush() throws IOException {
    try (TraceScope ignored = dfsClient.newPathTraceScope("hflush", src)) {
      flushOrSync(false, EnumSet.noneOf(SyncFlag.class));
    }
}
```

**语义**: 
- 数据已到达所有 DataNode 的**内存缓冲区**
- 新的 Reader 可以看到数据
- **不保证**数据已写入磁盘（DN 宕机可能丢失）

### 5.2 hsync — 持久化保证

```java
// 文件: DFSOutputStream.java, 行 531-536
@Override
public void hsync() throws IOException {
    try (TraceScope ignored = dfsClient.newPathTraceScope("hsync", src)) {
      flushOrSync(true, EnumSet.noneOf(SyncFlag.class));
    }
}
```

**语义**:
- 数据已写入所有 DataNode 的**操作系统缓冲区**（posix fsync）
- 即使 DN 进程崩溃，只要 OS 不崩溃，数据就不会丢失
- **注意**: 只保证当前 Block 内的数据，不跨 Block

### 5.3 flushOrSync 核心逻辑

```java
// 文件: DFSOutputStream.java, 行 569-600 (简化)
private void flushOrSync(boolean isSync, EnumSet<SyncFlag> syncFlags)
    throws IOException {
    dfsClient.checkOpen();
    checkClosed();
    try {
      long toWaitFor;
      synchronized (this) {
        int numKept = flushBuffer(!endBlock, true);

        if (lastFlushOffset != getStreamer().getBytesCurBlock()) {
          lastFlushOffset = getStreamer().getBytesCurBlock();
          if (isSync && currentPacket == null && !endBlock) {
            // ★ hsync 时如果没有数据，发送一个空 Packet（携带 syncBlock 标记）
            currentPacket = createPacket(packetSize, chunksPerPacket,
                getStreamer().getBytesCurBlock(),
                getStreamer().getAndIncCurrentSeqno(), false);
          }
        } else {
          if (isSync && getStreamer().getBytesCurBlock() > 0
              && !endBlock) {
            // ★ hsync 且有数据但偏移没变，也发空 Packet
            currentPacket = createPacket(packetSize, chunksPerPacket,
                getStreamer().getBytesCurBlock(),
                getStreamer().getAndIncCurrentSeqno(), false);
          }
        }
      }
      // ★ 等待所有 Packet 被 ACK
      getStreamer().waitForAckedSeqno(toWaitFor);
    }
}
```

### 5.4 语义对比表

| 特性 | hflush | hsync |
|------|--------|-------|
| 数据到达 DN 内存 | Yes | Yes |
| 数据写入 DN 磁盘 | No | Yes (posix fsync) |
| 新 Reader 可见 | Yes | Yes |
| DN 进程崩溃后安全 | No | Yes |
| DN OS 崩溃后安全 | No | No (需硬件级保证) |
| 性能影响 | 较小 | 较大 (触发磁盘 I/O) |
| 适用场景 | 日志采集、流计算 | 关键交易数据 |

---

## 六、Packet 数据结构

### 6.1 DFSPacket 结构

```
Packet 结构 (默认 64KB):
┌──────────────────────────────────────────────────────┐
│ PacketHeader (最大 33 bytes)                          │
│  ├── pktLen (4 bytes)       // Packet 数据长度        │
│  ├── offsetInBlock (8 bytes) // Block 内偏移          │
│  ├── seqno (8 bytes)        // 序列号                 │
│  ├── lastPacketInBlock (1 bit) // 是否最后一个包      │
│  └── dataLen (4 bytes)      // 数据长度               │
├──────────────────────────────────────────────────────┤
│ Checksums (每 512B 数据对应 4B CRC32C)               │
│  └── [checksum-1][checksum-2]...[checksum-N]         │
├──────────────────────────────────────────────────────┤
│ Data Chunks                                          │
│  └── [chunk-1 (512B)][chunk-2 (512B)]...[chunk-N]   │
└──────────────────────────────────────────────────────┘

默认 64KB Packet = 128 个 Chunk × (512B data + 4B checksum)
```

### 6.2 数据队列双缓冲

```
应用线程                    DataStreamer 线程               ResponseProcessor 线程
    │                            │                              │
    │  write() → currentPacket   │                              │
    │  ─────►  dataQueue  ──────►│  send() → Socket             │
    │         (待发送)           │  ──────► ackQueue  ──────────►│  readAck()
    │                            │         (待确认)              │
    │                            │                              │  ACK OK
    │                            │         ackQueue.remove() ◄──│
    │                            │                              │
```

---

## 七、关键参数与调优建议

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `dfs.client-write-packet-size` | 65536 (64KB) | Packet 大小 | 大文件可增至 128KB 减少 Packet 数 |
| `dfs.bytes-per-checksum` | 512 | Chunk 大小 | 通常不改 |
| `dfs.client.socket-timeout` | 60000ms | Socket 超时 | 网络不稳定可增大 |
| `dfs.datanode.socket.write.timeout` | 480000ms (8min) | DN 写超时 | |
| `dfs.client.block.write.retries` | 3 | 写重试次数 | |
| `dfs.client.block.write.replace-datanode-on-failure.enable` | true | 故障时替换 DN | |
| `dfs.client.block.write.replace-datanode-on-failure.policy` | DEFAULT | 替换策略 | ALWAYS/NEVER/DEFAULT |
| `dfs.client.block.write.replace-datanode-on-failure.best-effort` | false | 最佳努力替换 | 小集群建议 true |

### 调优场景

**场景 1: 小集群 Pipeline Recovery 失败**
```xml
<!-- 小集群（<3个节点）允许 Pipeline 降级 -->
<property>
  <name>dfs.client.block.write.replace-datanode-on-failure.policy</name>
  <value>NEVER</value>
</property>
<property>
  <name>dfs.client.block.write.replace-datanode-on-failure.best-effort</name>
  <value>true</value>
</property>
```

**场景 2: 高吞吐写入优化**
```xml
<property>
  <name>dfs.client-write-packet-size</name>
  <value>131072</value> <!-- 128KB -->
</property>
```

---

## 八、踩坑记录

### 坑 1: Pipeline 中 DataNode 顺序的重要性
Client 只与 Pipeline 中的第一个 DataNode 通信。如果第一个 DN 故障，整个 Pipeline 需要重建，包括重新向 NameNode 申请 Block。但如果中间或末尾的 DN 故障，只需剔除故障节点并用剩余节点重建 Pipeline。

### 坑 2: Generation Stamp 的作用
每次 Pipeline Recovery 都会递增 Generation Stamp。这用于**检测过时的块报告** — 如果 DataNode 报告的 Block GenerationStamp 低于 NameNode 记录的，说明该副本是旧的（Recovery 之前的），应该被丢弃。

### 坑 3: ackQueue 重发的幂等性
Pipeline Recovery 后，ackQueue 中未确认的 Packet 会被重发。DataNode 需要通过 offset 判断是否已经收到过，实现**幂等接收**。

### 坑 4: hflush 不等于 close
`hflush()` 只保证当前已写入的数据对 Reader 可见，但不意味着文件完成。只有 `close()` 才会发送 `lastPacketInBlock`，触发 Block 从 UNDER_CONSTRUCTION 变为 COMPLETE。如果 Client 在 `hflush()` 后崩溃，文件需要通过 Lease Recovery 才能被关闭。

### 坑 5: 心跳 Packet 的必要性
当 `dataQueue` 为空且距上次发送超过 `socketTimeout/2` 时，DataStreamer 会发送心跳 Packet（seqno = HEART_BEAT_SEQNO）。这防止 Pipeline 因为应用层长时间不写入而超时断开。

---

## 九、认知更新

1. **Pipeline 是单向的**: 数据正向流动，ACK 反向流动，Client 只需一个 Socket 连接
2. **DataStreamer 是一个精巧的状态机**: 用 `BlockConstructionStage` 管理 Pipeline 生命周期
3. **双队列设计 (dataQueue + ackQueue)** 实现了发送和确认的解耦，允许"发了就走"提升吞吐
4. **Pipeline Recovery 的核心是 Generation Stamp**: 通过递增 GS 来区分新旧副本
5. **hflush/hsync 的语义差异在 DataNode 端**: Client 端的差异只是 `isSync` 标志位
6. **ResponseProcessor 是错误发现的入口**: 所有 Pipeline 错误最终都通过 ACK 状态被 ResponseProcessor 发现并传递给 DataStreamer
