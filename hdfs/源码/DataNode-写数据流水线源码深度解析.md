# HDFS DataNode 写数据流水线源码深度解析

> 版本: Hadoop 3.x
> 源码路径: `/Users/kailongliu/bigdata/txProjects/hadoop`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

HDFS 三副本写入是怎么做到"一次客户端写、三个 DN 落盘、且任一 DN 故障可恢复"的？
为什么 DN 有时候日志里出现 `Slow BlockReceiver write packet to mirror took XXXms`？
DataXceiver / BlockReceiver / PacketResponder 三剑客分别干啥？

理解 DN 写流水线，是排查"HDFS 写慢/写失败/数据校验错误/磁盘 IO 异常"等所有写入侧故障的前置条件。

## 二、调用链总图（一图全览）

```
HDFS Client (DFSOutputStream)
   │ TCP 连接（dataTransfer 协议）
   ▼
DN1: DataXceiver.run()                  ← per-connection 线程
   │ readOp() = WRITE_BLOCK
   ▼
DataXceiver.writeBlock(...)
   │ new BlockReceiver(...)             ← 创建接收器
   ├──→ 与 DN2 建 TCP（mirror downstream）
   │    DN2: DataXceiver.writeBlock → BlockReceiver
   │    DN2 ──→ DN3: DataXceiver.writeBlock → BlockReceiver
   ▼
BlockReceiver.receiveBlock()
   │ while (receivePacket() >= 0) { ... }
   │
   │ 启动 PacketResponder Daemon ───────────┐
   ▼                                         │
[Packet 接收循环]                            │
  receiveNextPacket(in)                     │
  └─ 写本地磁盘 (out.write)                │
  └─ 转发 mirrorOut.flush ──→ DN2          │
  └─ enqueue(seqno) ──────────────────────►│
                                            ▼
                              PacketResponder.run()
                              [ACK 返回循环]
                              ack.readFields(downstreamIn) ← 读 DN2 的 ACK
                              waitForAckHead(seqno)        ← 取出本地待确认 packet
                              sendAckUpstream(...)         ← 给上游/客户端 ACK
                              if (lastPacketInBlock) finalizeBlock()
```

**核心三组件分工**：

| 组件 | 角色 | 线程模型 |
|------|------|---------|
| **DataXceiver** | TCP 连接接入，决定 op (WRITE/READ/COPY) | per-connection 线程，由 `DataXceiverServer` 的线程池管理 |
| **BlockReceiver** | 数据 packet 接收 + 写磁盘 + 转发 mirror | 复用 DataXceiver 线程（同步） |
| **PacketResponder** | ACK 链反向回传，处理"sealed by downstream" | 独立 Daemon 线程，BlockReceiver 创建并启动 |

## 三、关键源码逐段精读

### 3.1 receivePacket() —— 单个 packet 的全生命周期

`BlockReceiver.java:519-923`，核心代码（删减版）：

```java
private int receivePacket() throws IOException {
    // ① 收下一个 packet（PacketReceiver 内部用 NIO Channel 读）
    packetReceiver.receiveNextPacket(in);
    PacketHeader header = packetReceiver.getHeader();

    // ② Sanity check：偏移量是否连续
    if (header.getOffsetInBlock() > replicaInfo.getNumBytes()) {
      throw new IOException("Received an out-of-sequence packet for " + block + ...);
    }
    if (header.getDataLen() < 0) { throw new IOException("Got wrong length..."); }

    long offsetInBlock = header.getOffsetInBlock();
    long seqno = header.getSeqno();
    boolean lastPacketInBlock = header.isLastPacketInBlock();
    final int len = header.getDataLen();
    boolean syncBlock = header.getSyncBlock();

    // ③ 异步路径：把 packet 加入 PacketResponder 的等待队列（lock-free）
    //    注意：只有非 syncBlock 且不需校验时才走异步路径
    if (responder != null && !syncBlock && !shouldVerifyChecksum()) {
      ((PacketResponder) responder.getRunnable()).enqueue(seqno,
          lastPacketInBlock, offsetInBlock, Status.SUCCESS);
    }

    // ④ 转发到 mirror（下游 DN）—— pipeline 写的关键
    if (mirrorOut != null && !mirrorError) {
      try {
        long begin = Time.monotonicNow();
        packetReceiver.mirrorPacketTo(mirrorOut);
        mirrorOut.flush();
        long duration = Time.monotonicNow() - begin;
        if (duration > datanodeSlowLogThresholdMs) {
          LOG.warn("Slow BlockReceiver write packet to mirror took " + duration
              + "ms (threshold=" + datanodeSlowLogThresholdMs + "ms)");
        }
      } catch (IOException e) {
        handleMirrorOutError(e);  // 下游断了 → 通知客户端切流水线
      }
    }

    ByteBuffer dataBuf = packetReceiver.getDataSlice();
    ByteBuffer checksumBuf = packetReceiver.getChecksumSlice();

    // ⑤ 校验和验证（仅在需要时，例如客户端是 client 模式且非 transient 存储）
    if (shouldVerifyChecksum()) {
      try {
        verifyChunks(dataBuf, checksumBuf);
      } catch (IOException ioe) {
        // 本地校验失败 → 直接给上游报 ERROR_CHECKSUM
        ((PacketResponder) responder.getRunnable()).enqueue(seqno,
            lastPacketInBlock, offsetInBlock, Status.ERROR_CHECKSUM);
        Thread.sleep(3000);  // 等 ACK 上去再退出
        throw new IOException("Terminating due to a checksum error." + ioe);
      }
    }

    // ⑥ 写本地磁盘（关键 IO 路径）
    long begin = Time.monotonicNow();
    out.write(dataBuf.array(), startByteToDisk, numBytesToDisk);
    long duration = Time.monotonicNow() - begin;
    if (duration > datanodeSlowLogThresholdMs) {
      LOG.warn("Slow BlockReceiver write data to disk cost:" + duration + "ms ...");
    }

    // ⑦ 同步路径：写盘后才入队（确保数据已落盘后才允许 ACK）
    if (responder != null && (syncBlock || shouldVerifyChecksum())) {
      ((PacketResponder) responder.getRunnable()).enqueue(seqno,
          lastPacketInBlock, offsetInBlock, Status.SUCCESS);
    }

    if (lastPacketInBlock) return -1;  // 触发 receiveBlock() 主循环退出
    return len;
}
```

**关键点**：
- **③ 与 ⑦ 是两条入队路径**：
  - 异步路径（③）：早早入队，让 PacketResponder 与磁盘 IO 并行处理 ACK，**最大化吞吐**
  - 同步路径（⑦）：写盘+校验后才入队，**确保 ACK 真实代表数据已落盘**，用于 hsync/hflush
- **mirror flush 与 disk write 串行**：先转发再写盘（异步路径）。这种"先发后存"看似反直觉，但保证了下游能尽早开始它的写盘，**总流水线深度 = 单 DN 的 max(网络 + 磁盘)** 而非 sum。

### 3.2 receiveBlock 主循环（外层）

`BlockReceiver.java:923` 附近：

```java
while (receivePacket() >= 0) { /* Receive until the last packet */ }
```

简简单单一行，但**所有 IO、所有同步、所有错误处理都在 receivePacket() 里**。

### 3.3 PacketResponder —— ACK 反向回传的精髓

`BlockReceiver.java:1132-1500`：

```java
class PacketResponder implements Runnable, Closeable {
    private final Deque<Packet> ackQueue = new ArrayDeque<>();  // 待 ACK 队列
    private final PacketResponderType type;  // LAST_IN_PIPELINE / HAS_DOWNSTREAM_IN_PIPELINE

    @Override
    public void run() {
      boolean lastPacketInBlock = false;
      while (isRunning() && !lastPacketInBlock) {
        Packet pkt = null;
        long expected = -2;
        PipelineAck ack = new PipelineAck();
        long seqno = PipelineAck.UNKOWN_SEQNO;

        try {
          // ① 如果有下游，先读下游的 ACK
          if (type != PacketResponderType.LAST_IN_PIPELINE && !mirrorError) {
            ack.readFields(downstreamIn);              // ← 阻塞读
            ackRecvNanoTime = System.nanoTime();

            // ② OOB（Out-Of-Band）ACK 处理 —— 用于 DN 重启等场景
            Status oobStatus = ack.getOOBStatus();
            if (oobStatus != null) {
              LOG.info("Relaying an out of band ack of type " + oobStatus);
              sendAckUpstream(ack, PipelineAck.UNKOWN_SEQNO, 0L, 0L,
                PipelineAck.combineHeader(datanode.getECN(), Status.SUCCESS));
              continue;
            }
            seqno = ack.getSeqno();
          }

          // ③ 取出本地等待 ACK 的 packet 头
          if (seqno != PipelineAck.UNKOWN_SEQNO ||
              type == PacketResponderType.LAST_IN_PIPELINE) {
            pkt = waitForAckHead(seqno);
            expected = pkt.seqno;

            // ④ 校验 seqno 一致性
            if (type == PacketResponderType.HAS_DOWNSTREAM_IN_PIPELINE
                && seqno != expected) {
              throw new IOException("seqno: expected=" + expected + ", received=" + seqno);
            }

            // ⑤ 计算并上报本节点 ACK 耗时（用于 metrics）
            if (type == PacketResponderType.HAS_DOWNSTREAM_IN_PIPELINE) {
              totalAckTimeNanos = ackRecvNanoTime - pkt.ackEnqueueNanoTime;
              long ackTimeNanos = totalAckTimeNanos - ack.getDownstreamAckTimeNanos();
              datanode.metrics.addPacketAckRoundTripTimeNanos(ackTimeNanos);
            }
            lastPacketInBlock = pkt.lastPacketInBlock;
          }
        } catch (IOException ioe) {
          if (ioe instanceof EOFException && !packetSentInTime()) {
            // 下游报错可能是因为本节点拥塞导致没及时发包，让上游判定到底谁的锅
            LOG.warn("The downstream error might be due to congestion in upstream...");
            throw ioe;
          } else {
            mirrorError = true;  // 标记下游故障，后续走单边模式
          }
        }

        // ⑥ 如果是 lastPacket，先 finalize block
        if (lastPacketInBlock) {
          finalizeBlock(startTime);   // ← 关键：closes file, calls FsDatasetImpl.finalizeBlock
        }

        // ⑦ 给上游发 ACK
        Status myStatus = pkt != null ? pkt.ackStatus : Status.SUCCESS;
        sendAckUpstream(ack, expected, totalAckTimeNanos,
          (pkt != null ? pkt.offsetInBlock : 0),
          PipelineAck.combineHeader(datanode.getECN(), myStatus));

        if (pkt != null) removeAckHead();
      }
    }
}
```

**ACK 链路的精髓 —— 三个角色**：

| 节点 | type | 行为 |
|------|------|------|
| **流水线最后一个 DN** | `LAST_IN_PIPELINE` | 不读下游 ACK（无下游），只看本地 ackQueue，写盘成功就发 ACK 给上游 |
| **流水线中间 DN** | `HAS_DOWNSTREAM_IN_PIPELINE` | 阻塞读下游 ACK → 校验 seqno → 给上游 ACK |
| **流水线第一个 DN** | 同中间 | ACK 最终走给客户端 |

**ECN（Explicit Congestion Notification）**：`PipelineAck.combineHeader(datanode.getECN(), myStatus)` —— DN 通过 ACK 头部夹带本节点拥塞信号，HDFS-9079 引入，让上游知道下游压力，可主动 backoff。

### 3.4 finalizeBlock —— 块写完最后一公里

`BlockReceiver.java:1434`：

```java
private void finalizeBlock(long startTime) throws IOException {
  try (ReplicaHandler handler = BlockReceiver.this.claimReplicaHandler()) {
    BlockReceiver.this.close();             // ① 关闭 block 文件 + meta 文件
    block.setNumBytes(replicaInfo.getNumBytes());
    datanode.data.finalizeBlock(block, dirSyncOnFinalize);  // ② 把 RBW → FINALIZED
    //                                                          会做 rename(rbw/x → finalized/subdir/x)
  }
  if (pinning) datanode.data.setPinning(block);
  datanode.closeBlock(block, null, replicaInfo.getStorageUuid(), ...);  // ③ 给 NN 报 BlockReceived
  ClientTraceLog.info(String.format(DN_CLIENTTRACE_FORMAT, ...));
}
```

**三步走**：①关闭文件流 → ②把 `current/rbw/blk_xxx` 移动到 `current/finalized/subdirN/blk_xxx`（HDFS 块的物理目录布局，大哥都熟）→ ③`closeBlock()` 通过 BPOfferService 给 NN 发 `BlockReceivedAndDeleted` RPC，NN 才会把这个副本计入 `blocksMap`。

**生产意义**：DN 上 `current/rbw/` 看到的是"正在写但还没 finalize 的块"，DN 重启后会从 rbw 目录恢复并重新 finalize（参考 `BPOfferService.processFirstBlockReport`）。

## 四、Pipeline 故障恢复流程

`receivePacket()` 第 ④ 步发现 `mirrorOut` 写失败时调用 `handleMirrorOutError(e)`：

```
DN1 写 mirror 失败
  │
  ▼
mirrorError = true
  │
  ▼
后续 packet 不再写 mirror，DN1 给客户端发 SUCCESS（仅自己落盘）
  │
  ▼
客户端 DataStreamer 收到只有 DN1 的 ACK（少一个） → 进入 pipeline recovery
  │
  ▼
客户端调用 NN.updateBlockForPipeline → 拿到新的 GenStamp
  │
  ▼
客户端重建 pipeline（可能换 DN，或 [DN1, DN3] 两副本继续写）
  │
  ▼
原 DN2 上的不完整副本由 NN 后续标记为 corrupt
```

## 五、实战 LOG 对齐验证

DN 日志中可见的关键日志（行号对应源码）：

| 日志关键词 | 对应源码行 | 含义 |
|----------|----------|------|
| `Slow BlockReceiver write packet to mirror took XXXms` | `BlockReceiver.java:587` | mirror 转发慢，下游网络/DN 处理慢 |
| `Slow BlockReceiver write data to disk cost:XXXms` | `BlockReceiver.java:719` | 本地磁盘 IO 慢 |
| `Received an out-of-sequence packet for ...` | `BlockReceiver.java:531` | seqno 错乱，可能 client bug 或网络乱序 |
| `Got wrong length during writeBlock` | `BlockReceiver.java:536` | header 校验失败 |
| `Terminating due to a checksum error` | `BlockReceiver.java:630` | 客户端发来的数据校验失败 |
| `IOException in BlockReceiver.run()` | `BlockReceiver.java:1410` | PacketResponder 异常退出，会触发 disk error 检查 |
| `Relaying an out of band ack of type` | `BlockReceiver.java:1313` | OOB ACK，下游 DN 在重启 |
| `seqno: expected=X, received=Y` | `BlockReceiver.java:1330` | ACK 顺序错乱（严重，pipeline 一致性破坏）|
| `terminating` | `BlockReceiver.java:1427` | PacketResponder 正常退出 |

**故障排查公式**：
- DN 写慢 → 先 `grep "Slow BlockReceiver"` 区分是 mirror 慢还是 disk 慢
- 数据损坏 → `grep "checksum error"` + 查 client 端
- pipeline 异常切换 → `grep "Relaying an out of band\|mirrorError\|terminating"`

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| 三组件分工（DataXceiver/BlockReceiver/PacketResponder） | 单一职责：连接接入 / 数据接收 / ACK 处理，互不阻塞 |
| PacketResponder 独立 Daemon | 数据接收与 ACK 处理解耦，**充分利用网络与磁盘并行** |
| 异步入队（早入队）+ 同步入队（晚入队）双路径 | 兼顾吞吐（异步）与持久化语义（hsync 同步）|
| ECN 在 ACK 头夹带拥塞信号 | 反向反馈，避免上游持续打满下游 |
| RBW → Finalize 两阶段 | 写过程可恢复，DN 重启后能识别"半截块"并尝试 lease recovery |
| seqno + offsetInBlock 双重校验 | 检测乱序、丢包、错位 |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `dfs.datanode.socket.write.timeout` | 8 * 60 * 1000 ms | 写 socket 超时 |
| `dfs.datanode.slow.io.warning.threshold.ms` | 300 | Slow disk/mirror 告警阈值 |
| `dfs.datanode.handler.count` | 10 | DataXceiver 服务端 IPC handler 数 |
| `dfs.datanode.max.transfer.threads` | 4096 | 最大并发 DataXceiver 数（这个被打满就是经典的 "xceiver count exceeds the limit"）|
| `dfs.datanode.sync.behind.writes` | false | 是否在写 packet 后做 fadvise/fsync 释放 page cache |
| `dfs.datanode.drop.cache.behind.writes` | false | 写完后丢弃 page cache（防止污染热数据 cache）|
| `dfs.client.socket-timeout` | 60s | 客户端 socket 读超时（影响 ACK 等待时长）|
| `dfs.bytes-per-checksum` | 512 | CRC chunk 大小 |

## 八、踩坑记录

1. **`xceiver count exceeds the limit`**：DN 收到的并发连接数 > `dfs.datanode.max.transfer.threads`。常见于 HBase Region 多、Spark Streaming 频繁 list/getBlock。**根因**：DataXceiver 是 per-connection 线程，连接堆积。**应对**：调大该参数（4096→8192/16384）+ 排查上层是否泄漏连接。
2. **`Slow BlockReceiver write packet to mirror`** 仅 DN1 出现：说明 DN2 慢（磁盘满/网络/GC）。**应对**：登录 DN2 看 `iostat -x 1 5` + `jstat -gc`。
3. **`mirrorOut` 关闭但客户端没切 pipeline**：DN1 持续给客户端报 SUCCESS（即使副本数实际只剩 1）。客户端依赖 ACK 中的 `numTargets` 字段判断，**不要依赖 ACK count 数**。
4. **`finalizeBlock` 慢**：通常是磁盘 fsync 慢。`dirSyncOnFinalize=true` 时会 fsync 父目录，对小文件场景有冲击。
5. **OOB ACK 误用**：DN 优雅重启会发 OOB，**但** OOB 协议在客户端 < 2.6.0 不支持，会被当作错误 packet 处理 → 触发 pipeline 重建。

## 九、认知更新

- 之前以为 packet 是"接收→写盘→ACK"严格串行的，**实际上是"接收→入队（异步）→并行写盘+下游转发→ACK"**，关键在 PacketResponder 与 BlockReceiver 主线程解耦。
- 之前以为 mirror 转发用的独立线程，**实际上是 BlockReceiver 主线程同步写 mirrorOut**，DN1 转发慢会直接把 receivePacket() 阻塞，进而把客户端写阻塞 —— 这是 DN1→DN2 慢全链路放大效应的根源。
- finalize 阶段会在 PacketResponder 线程内做（`lastPacketInBlock` 触发），不是单独线程。**这意味着 finalize 慢会延迟 ACK 回传**，影响客户端关闭文件耗时。

## 十、下一步深挖方向

- [ ] DataXceiverServer 的 `peersXceiver` 限流机制
- [ ] FsDatasetImpl.finalizeBlock 的卷选择 + rename 原子性
- [ ] DataNode 心跳 + IBR (Incremental Block Report) 与 finalize 的时序关系
- [ ] EC（Erasure Coding）写流水线的差异（StripedBlockReceiver）

---

**沉淀完成。源码定位精确到行号，与生产日志关键词逐一对齐。**
