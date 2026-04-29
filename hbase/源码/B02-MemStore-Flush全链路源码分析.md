# B02 — MemStore Flush 全链路源码分析

> **段位**: L2→L3 | **方法**: 逆向工程 + 对抗性阅读 + 实战案例关联  
> **核心类**: `MemStoreFlusher`, `DefaultStoreFlusher`, `HStore.flushCache`, `HFileWriterImpl`, `CompressorStream`  
> **实战关联**: ITEM 表 Flush 卡死 25 小时案例（2026-04-25 Thread Dump）

---

## 一、Flush 触发链路

### 1.1 三种触发方式

```
触发 Flush 的三条路径：

1. Region 级别触发（最常见）
   HRegion.checkResources()
     → MemStore size > hbase.hregion.memstore.flush.size (128MB)
       → MemStoreFlusher.requestFlush(region, reason)

2. 全局 MemStore 水位触发（紧急）
   MemStoreFlusher 后台线程定期检查：
     → 全局 MemStore > globalMemStoreLimit (堆×0.4)
       → reclaimMemStoreMemory()
         → 选最大 MemStore 的 Region → requestFlush
         → 如果还不够 → 阻塞所有写入（写反压！）

3. WAL 文件数触发
   WAL 文件数 > hbase.regionserver.maxlogs (32)
     → 找最老 WAL 关联的 Region → requestFlush
     → Flush 完成后可以归档旧 WAL
```

### 1.2 requestFlush 到 FlushHandler

```java
// MemStoreFlusher.java
public boolean requestFlush(HRegion region, FlushLifeCycleTracker tracker) {
    // 构造 FlushRegionEntry（带延迟时间）
    FlushRegionEntry entry = new FlushRegionEntry(region, tracker);
    
    // 放入 DelayQueue
    this.flushQueue.add(entry);
    
    return true;
}

// FlushHandler 线程消费（每个线程独立从队列 poll）
private class FlushHandler extends HasThread {
    @Override
    public void run() {
        while (!server.isStopped()) {
            FlushQueueEntry fqe = flushQueue.poll(threadWakeFrequency, MILLISECONDS);
            if (fqe != null && fqe instanceof FlushRegionEntry) {
                FlushRegionEntry fre = (FlushRegionEntry) fqe;
                if (!flushRegion(fre)) {
                    // flush 失败，重新入队
                    flushQueue.add(fre);
                }
            }
        }
    }
}
```

---

## 二、Flush 执行核心链路

```
MemStoreFlusher.flushRegion(FlushRegionEntry)
│
├─ 1. 检查 Region 是否可 flush
│     └─ region.shouldFlush() — 非 closing/closed/splitting 状态
│
├─ 2. HRegion.flushcache(families, reason, tracker)
│     │
│     ├─ 2a. 获取 updatesLock.writeLock()（暂停写入）
│     │       └─ 此时新的 put 操作会阻塞！
│     │
│     ├─ 2b. MemStore Snapshot
│     │       └─ 对每个 Store 的 MemStore 做 snapshot()
│     │       └─ 新建空 MemStore 接收后续写入
│     │       └─ 原 MemStore 数据变为不可变的 snapshot
│     │
│     ├─ 2c. 释放 updatesLock.writeLock()（恢复写入）
│     │       └─ 写入中断时间通常 < 10ms
│     │
│     └─ 2d. internalFlushCacheAndCommit()
│             │
│             ├─ 2d-1. 逐 Store flush
│             │         └─ HStore.flushCache(snapshot)
│             │               └─ StoreFlusher.flushSnapshot(snapshot)
│             │                     └─ 详见下方 Section 三
│             │
│             ├─ 2d-2. 完成后：
│             │         ├─ 更新 Region 的 sequenceId
│             │         ├─ 更新 WAL 的 oldest-unflushed-seqId
│             │         └─ 释放 snapshot 内存
│             │
│             └─ 2d-3. 通知 CompactSplitThread
│                       └─ 如果 StoreFile 数量过多 → 触发 compaction
```

### 关键点：写入中断时间

```
   ← 写入正常 →  ← 暂停(snapshot) →  ← 写入恢复 →
                  │                  │
                  │  获取 writeLock   │  释放 writeLock
                  │  做 snapshot     │
                  │  通常 < 10ms     │
```

**如果 snapshot 很大（例如 MemStore 积压了 GB 级数据），snapshot 操作本身可能耗时较长！**

---

## 三、StoreFlusher.performFlush — 写 HFile 核心

```java
// StoreFlusher.java（关键方法）
protected void performFlush(InternalScanner scanner, 
                            CellSink sink,     // → StoreFileWriter
                            long smallestReadPoint) throws IOException {
    
    Cell cell = null;
    List<Cell> kvs = new ArrayList<>();
    boolean hasMore;
    
    do {
        // 从 MemStore snapshot 中逐行读取
        hasMore = scanner.next(kvs);
        
        if (!kvs.isEmpty()) {
            for (Cell kv : kvs) {
                // 逐个 Cell 写入 HFile
                sink.append(kv);  // → StoreFileWriter.append()
                //                       → HFileWriterImpl.append()
                //                          → checkBlockBoundary()
                //                             → finishBlock() → compress!
            }
            kvs.clear();
        }
    } while (hasMore);
}
```

### 3.1 HFileWriterImpl.append — Block 边界检查

```java
// HFileWriterImpl.java
public void append(Cell cell) {
    // ...编码 cell 到当前 block...
    
    // 检查当前 block 是否超过 blockSize (默认 64KB)
    if (checkBlockBoundary()) {
        // block 满了，先完成当前 block
        finishBlock();  // ← 这里触发压缩！
    }
    
    // 将 cell 写入新/当前 block
    blockWriter.write(cell);
}

private void finishBlock() {
    // 1. 结束当前 block 的编码
    blockWriter.ensureBlockReady();
    
    // 2. 内部调用: compressAndEncrypt
    //    → HFileBlockDefaultEncodingContext.compressAfterEncoding()
    //      → CompressorStream.write(uncompressedData)
    //        → ZStandardCompressor.compress()
    //          → deflateBytesDirect(Native Method)  ← 你的卡死点！
    
    // 3. 将压缩后的 block 写入 HDFS
    blockWriter.writeHeaderAndData(outputStream);
}
```

### 3.2 压缩调用链

```
finishBlock()
  → HFileBlock$Writer.ensureBlockReady()
    → HFileBlock$Writer.finishBlockAndWriteHeaderAndData()
      → HFileBlockDefaultEncodingContext.compressAndEncrypt()
        → compressAfterEncoding(uncompressedBytes, compressedStream)
          → CompressorStream.write(uncompressedBytes)
            → CompressorStream.compress()
              → compressor.compress(buffer, off, len)  // Compressor 接口
                → ZStandardCompressor.compress()       // ZStd 实现
                  → deflateBytesDirect(Native Method)  // JNI → libzstd.so
```

**这就是你线上案例的完整调用链**。问题出在最底层的 `deflateBytesDirect` JNI 调用。

---

## 四、DefaultStoreFlusher.flushSnapshot — 完整源码

```java
// DefaultStoreFlusher.java
public class DefaultStoreFlusher extends StoreFlusher {
    
    @Override
    public List<Path> flushSnapshot(MemStoreSnapshot snapshot,
                                     long cacheFlushSeqNum,
                                     MonitoredTask status,
                                     ThroughputController ctrl) throws IOException {
        
        List<Path> result = new ArrayList<>();
        int cellsCount = snapshot.getCellsCount();
        
        if (cellsCount == 0) return result;  // 空 snapshot 直接返回
        
        // 创建 StoreFileWriter
        synchronized (flushLock) {  // ← 你 Thread Dump 中看到的锁 <0x00007f4e57bed1e0>
            
            InternalScanner scanner = createScanner(snapshot, smallestReadPoint);
            StoreFileWriter writer = null;
            
            try {
                // 创建 writer（包含压缩配置）
                writer = store.createWriterInTmp(cellsCount, 
                    store.getColumnFamilyDescriptor().getCompressionType(),  // ← ZSTD!
                    false, true, false, false, ctrl);
                
                // 执行 flush — 逐 cell 写入
                performFlush(scanner, writer, smallestReadPoint);
                
                // 完成写入
                result.add(writer.getPath());
                
            } finally {
                if (scanner != null) scanner.close();
                if (writer != null) writer.close();
            }
        }
        
        return result;
    }
}
```

**注意 `synchronized (flushLock)`**：
- 你的 Thread Dump 中 `locked <0x00007f4e57bed1e0> (a java.lang.Object)` 就是这把锁
- 同一个 Store（同一个 CF）的 flush 是串行的
- 但不同 Store/不同 Region 的 flush 可以并行

---

## 五、全局 MemStore 内存管理（写反压机制）

```java
// MemStoreFlusher.java — reclaimMemStoreMemory()

private void reclaimMemStoreMemory() {
    // 获取当前全局 MemStore 大小
    long curSize = server.getRegionServerAccounting().getGlobalMemStoreDataSize();
    
    if (curSize > globalMemStoreLimit) {
        // 紧急！超过上限
        // 1. 选 MemStore 最大的 Region
        HRegion bestRegion = getBiggestMemStoreRegion();
        
        // 2. 请求 flush
        requestFlush(bestRegion, FlushLifeCycleTracker.DUMMY);
        
        // 3. 如果依然超标 → 阻塞所有写入！
        if (isAboveHighWaterMark()) {
            // 所有 RPC Handler 线程的 put 操作在这里等待
            synchronized (blockSignal) {
                blockSignal.wait(timeout);
            }
        }
    }
}
```

**这就是为什么 flush 卡死会导致写入阻塞的原因**：
1. MemStoreFlusher.10 卡在 ZStd 压缩 → 该 Region flush 不完成
2. 该 Region 的 MemStore 持续增长（因为 snapshot 后新 MemStore 继续接收写入）
3. 全局 MemStore 接近上限 → 开始强制选最大 Region flush
4. 如果全局超标 → **所有写入操作被 block**
5. 集群表现：写入延迟暴涨 / Put 超时

---

## 六、Flush 过程中的异常处理

```java
// HRegion.internalFlushCacheAndCommit()

try {
    // 执行 flush
    storeFlushCtxs.get(store).flushCache(status);
} catch (IOException ioe) {
    // Flush 失败！
    if (ioe instanceof DroppedSnapshotException) {
        // 严重！snapshot 数据丢失 → abort RS
        server.abort("Replay of WAL required. Forcing server shutdown", ioe);
        return;
    }
    
    // 其他 IO 异常（如 HDFS 写入失败）
    // 重试 or 标记 Region 为 closing
}
```

**关键**: 如果 flush 因为压缩卡死而 **永远不返回**（你的情况），那么：
- 不会触发异常处理
- 线程永远 RUNNABLE，吃 CPU
- 只能外部干预（kill RS 或 unassign Region）

---

## 七、Flush 性能模型

```
Flush 耗时 = Snapshot 时间 + Write 时间

Snapshot 时间 ≈ O(1)（只是指针切换，通常 < 10ms）

Write 时间 = Σ(每个 Block 的处理时间)
           = (MemStore 数据量 / BlockSize) × (编码时间 + 压缩时间 + HDFS 写入时间)

正常情况（128MB MemStore, 64KB block, LZ4 压缩）：
  Block 数 = 128MB / 64KB = 2048 个
  每个 Block 压缩: ~0.1ms (LZ4) 或 ~0.5ms (ZSTD 正常)
  每个 Block 写 HDFS: ~1ms
  总计: 2048 × 1.5ms ≈ 3 秒

你的异常情况：
  一个 Block 的 ZStd 压缩: > 24.8 小时 ← 明显是 Bug
  正常应该: 0.5ms
  异常放大倍数: 24.8h / 0.5ms = 178,560,000 倍
```

---

## 八、压缩算法对比（Flush 场景）

| 算法 | 压缩速度 | 解压速度 | 压缩比 | CPU 占用 | 稳定性 | HBase 推荐 |
|------|----------|----------|--------|----------|--------|-----------|
| **NONE** | ∞ | ∞ | 1:1 | 0 | ★★★★★ | 测试环境 |
| **SNAPPY** | ~500MB/s | ~1.5GB/s | 2:1 | 低 | ★★★★★ | 读密集 |
| **LZ4** | ~700MB/s | ~2.5GB/s | 2:1 | 最低 | ★★★★★ | **首选推荐** |
| **ZSTD** | ~300MB/s | ~1GB/s | 3:1 | 中 | ★★★☆ | 冷数据/空间敏感 |
| **GZ** | ~30MB/s | ~300MB/s | 5:1 | 高 | ★★★★ | 归档数据 |

**结论**: HBase Flush/Compaction 是 CPU 密集操作，**LZ4 是最佳选择**（速度快、CPU 低、稳定性好）。ZSTD 虽然压缩比好 50%，但有 Native Library 稳定性风险（如你遇到的 bug）。

---

## 九、排障决策树（Flush 相关问题）

```
Flush 慢/卡死？
│
├─ 检查 RS 日志: "Flushing" 关键字
│   └─ 持续时间 > 5分钟 → 异常
│
├─ 查 Thread Dump: grep "StoreFlusher\|MemStoreFlusher"
│   │
│   ├─ 状态 RUNNABLE + cpu 很高？
│   │   └─ 看栈顶：
│   │       ├─ compress/deflate → 压缩卡死（本案例）
│   │       │   └─ 方案: unassign Region + 换压缩算法
│   │       ├─ HDFS write/sync → HDFS 写入慢
│   │       │   └─ 方案: 检查 DN 状态/网络/磁盘
│   │       └─ 其他 → 按具体位置分析
│   │
│   ├─ 状态 BLOCKED？
│   │   └─ 查等谁的锁 → 可能是 compaction 和 flush 竞争 Store 锁
│   │
│   └─ 状态 WAITING？
│       └─ 全部在 DelayQueue.poll → 正常（空闲等任务）
│
├─ 全局 MemStore 水位:
│   └─ RS Web UI → Memory 标签
│   └─ 超过 95% → 写入被阻塞！
│
└─ Flush 完成但频繁:
    └─ 检查是否有热点 Region（写入集中）
    └─ 方案: pre-split / 调大 flush.size
```

---

## 十、与线上案例完整对应

| 源码位置 | Thread Dump 证据 | 含义 |
|----------|-----------------|------|
| `MemStoreFlusher$FlushHandler.run()` line 360 | MemStoreFlusher.10 RUNNABLE | FlushHandler 正在执行 flush |
| `DefaultStoreFlusher.flushSnapshot()` line 68 | `locked <0x00007f4e57bed1e0>` | 持有 Store 级 flush 锁 |
| `StoreFlusher.performFlush()` line 132 | 调用链中间 | 正在逐 cell 写入 |
| `HFileWriterImpl.checkBlockBoundary()` line 326 | → finishBlock | 检测到 block 满了，触发压缩 |
| `HFileBlockDefaultEncodingContext.compressAfterEncoding()` line 204 | → compress | 压缩操作 |
| `ZStandardCompressor.deflateBytesDirect()` | **栈顶 Native Method** | **卡死在 JNI 层** |
| `DataStreamer for .../ITEM/.tmp/CF1/...` | elapsed=90694s | HDFS 写入线程等待压缩完成后的数据 |

---

*— Eric HBase 源码精通 B02 | 2026-04-30 —*
