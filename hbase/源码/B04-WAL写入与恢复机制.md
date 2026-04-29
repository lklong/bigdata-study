# B04 — WAL 写入与恢复机制

> **段位**: L2→L3 | **方法**: 分形剥离 L2 + 考古学方法  
> **核心类**: `FSHLog`, `AsyncFSWAL`, `WALEdit`, `WALSplitter`, `WALKey`  
> **同构**: WAL ≈ MySQL Redo Log ≈ HDFS EditLog ≈ Kafka Partition Log

---

## 一、WAL 的作用

```
问题: 如果数据写入 MemStore 后、Flush 到 HFile 前 RS 崩溃？
  → MemStore 中的数据全部丢失！

解决: Write-Ahead Log（预写日志）
  → 写 MemStore 之前，先写 WAL（持久化到 HDFS）
  → RS 崩溃后，通过重放 WAL 恢复 MemStore 数据

保证: 只要 WAL 写入成功（HDFS sync），数据就不会丢
```

---

## 二、WAL 写入链路

### 2.1 整体流程

```
Client.put(Put)
  │
  ▼
HRegion.put()
  │
  ├─ 1. 获取行锁 (RowLock)
  │
  ├─ 2. 构造 WALEdit
  │     └─ WALEdit = {WALKey, [Cell1, Cell2, ...]}
  │     └─ WALKey = {regionName, tableName, sequenceId, timestamp}
  │
  ├─ 3. WAL.append(WALKey, WALEdit)     ← 写入 WAL 缓冲区
  │     └─ 追加到 RingBuffer (Disruptor)
  │
  ├─ 4. WAL.sync()                       ← 持久化到 HDFS
  │     └─ 等待 HDFS Pipeline ack
  │     └─ sync 成功 = 数据持久化保证
  │
  ├─ 5. 写入 MemStore
  │
  └─ 6. 释放行锁
```

### 2.2 AsyncFSWAL 实现（2.x 推荐）

```java
// AsyncFSWAL.java — 基于 Disruptor RingBuffer 的异步 WAL

public class AsyncFSWAL extends AbstractFSWAL<AsyncWriter> {
    
    // Disruptor RingBuffer — 环形缓冲区
    private final RingBuffer<RingBufferTruck> waitingConsumePayloads;
    
    // 消费者线程: append-pool-N
    private final EventHandler<RingBufferTruck> eventHandler;
    
    @Override
    public long append(RegionInfo hri, WALKeyImpl key, WALEdit edits, boolean inMemstore) {
        // 1. 序列化 WALEdit → byte[]
        // 2. 发布到 RingBuffer（非阻塞）
        long sequence = waitingConsumePayloads.next();
        RingBufferTruck truck = waitingConsumePayloads.get(sequence);
        truck.load(key, edits);
        waitingConsumePayloads.publish(sequence);
        
        return txid;  // 返回事务 ID，sync 时用
    }
    
    @Override
    public void sync(long txid) throws IOException {
        // 等待该 txid 对应的数据被 flush 到 HDFS
        // append-pool 线程负责批量 flush
        SyncFuture future = getSyncFuture(txid);
        future.get(timeout);  // 阻塞等待
    }
}
```

### 2.3 append-pool 消费者线程

```java
// AsyncFSWAL 内部的 EventHandler
// 对应 Thread Dump 中的 "append-pool-0"

public void onEvent(RingBufferTruck truck, long sequence, boolean endOfBatch) {
    // 1. 将 WALEdit 写入 AsyncWriter（HDFS 异步写）
    writer.append(entry);
    
    // 2. 如果是 batch 结尾 → 触发 sync
    if (endOfBatch || shouldSync()) {
        writer.sync();  // → HDFS Pipeline sync
        // sync 完成后通知所有等待的 SyncFuture
        completeSyncFutures(txid);
    }
}
```

**你的 Thread Dump 中**:
- `append-pool-0` 状态 `WAITING (parking)` on `BlockingWaitStrategy`
- 说明当前没有 WAL 写入需求（因为 flush 卡死，写入可能被阻塞或流量降低）

---

## 三、WAL 文件管理

### 3.1 文件结构

```
HDFS 上的 WAL 目录:
/hbase/WALs/
  └─ regionserver,16020,timestamp/
       ├─ regionserver%2C16020%2Ctimestamp.1650000000000   ← 当前活跃 WAL
       ├─ regionserver%2C16020%2Ctimestamp.1650000001000   ← 已关闭（可归档）
       └─ regionserver%2C16020%2Ctimestamp.1650000002000

归档后:
/hbase/oldWALs/
  └─ regionserver%2C16020%2Ctimestamp.1650000001000
```

### 3.2 WAL 滚动 (Roll)

```java
// LogRoller.java（对应 Thread Dump 中的 "logRoller" 线程）

public class LogRoller extends HasThread {
    
    // 滚动周期: hbase.regionserver.logroll.period = 3600000 (1小时)
    // 滚动大小: hbase.regionserver.logroll.multiplier × HDFS block size
    
    @Override
    public void run() {
        while (!server.isStopped()) {
            Thread.sleep(rollPeriod);
            
            // 检查是否需要滚动
            if (shouldRoll()) {
                // 关闭当前 WAL 文件，创建新文件
                wal.rollWriter();
            }
        }
    }
}

// rollWriter():
// 1. 关闭当前 writer（flush + close）
// 2. 创建新的 HDFS 文件
// 3. 检查旧 WAL 是否可以归档
//    → 如果旧 WAL 中所有 Region 的数据都已 flush → 可归档
```

### 3.3 WAL 归档条件

```
WAL 文件可归档的条件：
  该 WAL 文件中记录的每个 Region 的最新 sequenceId
  都 <= 该 Region 已 flush 的 sequenceId

举例:
  WAL-001 包含: RegionA(seq 1-100), RegionB(seq 1-50)
  
  RegionA 已 flush 到 seq=120 → ✓
  RegionB 已 flush 到 seq=30  → ✗（seq 31-50 还在 MemStore）
  
  → WAL-001 不能归档！必须等 RegionB flush 到 ≥ 50

这就是为什么 flush 卡死会导致 WAL 堆积的原因！
```

---

## 四、崩溃恢复 — WAL Splitting

### 4.1 触发时机

```
RS 崩溃 → ZK session 超时 → Master 检测到
  → Master 触发 ServerCrashProcedure
    → 第一步: WAL Splitting（拆分死亡 RS 的 WAL）
      → 第二步: Region Reassign（将 Region 分配给其他 RS）
        → 其他 RS open Region 时 replay WAL
```

### 4.2 WALSplitter 过程

```java
// WALSplitter.java

public static List<Path> split(Path walDir, List<Path> walFiles, 
                                FileSystem fs, Configuration conf) {
    
    // 1. 读取每个 WAL 文件
    for (Path walFile : walFiles) {
        WAL.Reader reader = WALFactory.createReader(fs, walFile, conf);
        
        // 2. 逐条读取 WALEdit
        WAL.Entry entry;
        while ((entry = reader.next()) != null) {
            WALKey key = entry.getKey();
            byte[] regionName = key.getEncodedRegionName();
            
            // 3. 按 Region 分组写入
            //    /hbase/WALs/regionserver/recovered.edits/regionName/seqid
            getWriterForRegion(regionName).append(entry);
        }
    }
    
    // 4. 关闭所有 writer
    closeAllWriters();
    
    return outputPaths;
}
```

### 4.3 Region Open 时的 WAL Replay

```java
// HRegion.initialize() 中

private long replayRecoveredEditsIfAny(Path regionDir) {
    // 1. 查找 recovered.edits 目录
    Path editsDir = new Path(regionDir, "recovered.edits");
    
    // 2. 按 sequenceId 排序读取
    for (Path editFile : getRecoveredEditsFiles(editsDir)) {
        // 3. 逐条重放到 MemStore
        WAL.Reader reader = WALFactory.createReader(fs, editFile, conf);
        WAL.Entry entry;
        while ((entry = reader.next()) != null) {
            long seqId = entry.getKey().getSequenceId();
            
            // 跳过已经 flush 过的数据
            if (seqId <= lastFlushedSequenceId) continue;
            
            // 重放到 MemStore
            for (Cell cell : entry.getEdit().getCells()) {
                store.add(cell, memstoreSizing);
            }
        }
    }
    
    // 4. 重放完成后 flush MemStore
    if (memstoreSizing.getDataSize() > 0) {
        internalFlushcache(null, seqId, ...);
    }
    
    return lastSeqId;
}
```

---

## 五、WAL 持久性保证

### 5.1 HDFS Pipeline Sync

```
WAL sync = HDFS hflush/hsync

hflush(): 数据到达所有 DN 的 OS 缓冲区 → 宕机可能丢（OS crash）
hsync(): 数据落盘到所有 DN 磁盘 → 真正持久化

HBase 默认用 hflush (性能好)
配置: hbase.regionserver.hlog.syncer.count = 5 (sync 线程数)

Pipeline 副本数 = dfs.replication (默认 3)
  → WAL 写到 3 个 DN → 3 副本全部 hflush 成功才 ack
  → 单个 DN 故障不影响 WAL 持久性
```

### 5.2 Group Commit（批量 sync 优化）

```
问题: 每个 Put 都 sync 一次 → HDFS 延迟高（每次 sync ~5ms）
优化: 多个 Put 的 WAL 聚合为一次 sync

原理（Disruptor + batching）:
  Put1 → WALEdit1 ──┐
  Put2 → WALEdit2 ──┼─→ batch write → 1次 sync → 通知 Put1,Put2,Put3
  Put3 → WALEdit3 ──┘

效果: 
  单次 sync 延迟 5ms
  100 个 Put 共享 1 次 sync
  → 平均每个 Put 的 sync 延迟 = 5ms / 100 = 0.05ms
```

---

## 六、WAL 异常场景分析

| 场景 | 现象 | 根因 | 处理 |
|------|------|------|------|
| WAL sync 慢 | 写入延迟高 | HDFS DN 磁盘慢/网络抖动 | 检查 DN 状态，排除慢盘 |
| WAL 堆积 | `/hbase/WALs` 下文件越来越多 | Region flush 卡死/慢 | 找出卡死的 flush，修复后 WAL 自动归档 |
| WAL split 慢 | RS 故障后 Region 长时间不可用 | WAL 文件大/多 | 调小 maxlogs，加速 split |
| WAL 损坏 | RS 启动时 replay 失败 | HDFS 数据块损坏 | `hbase hbck` 修复，或跳过损坏 entry |
| WAL 写满磁盘 | RS 不可用 | WAL 归档失败 + flush 卡死 | 手动归档/删除旧 WAL |

### 与你线上案例的关联

```
因果链:
  MemStoreFlusher.10 卡死 (ZStd bug)
    → ITEM Region 的 flush 不完成
      → 包含 ITEM Region 数据的 WAL 文件不能归档
        → WAL 文件数持续增长
          → 如果超过 maxlogs → 触发更多 flush 请求
            → 但 flush 已卡死 → 恶性循环
              → 最终: WAL 堆积 + MemStore 满 + 写入阻塞
```

---

## 七、FSHLog vs AsyncFSWAL 对比

| 维度 | FSHLog (1.x 默认) | AsyncFSWAL (2.x 默认) |
|------|-------------------|----------------------|
| 架构 | 同步 write + sync | Disruptor + 异步 flush |
| 线程模型 | 多个 handler 竞争一把 WAL 锁 | handler 发布到 RingBuffer，单线程消费 |
| 吞吐 | 受限于 sync 延迟 | Group Commit 批量 sync |
| 延迟 | 高（每次 Put 等 sync） | 低（批量 amortize） |
| CPU | 低 | 略高（Disruptor 开销） |
| 稳定性 | 成熟 | 2.x 后稳定 |

**你的集群用的是 AsyncFSWAL**（Thread Dump 证据：`append-pool-0` + `BlockingWaitStrategy`）。

---

## 八、关键配置

| 配置项 | 默认值 | 建议值 | 说明 |
|--------|--------|--------|------|
| `hbase.wal.provider` | asyncfs | asyncfs | WAL 实现 |
| `hbase.regionserver.maxlogs` | 32 | 64~128 | WAL 文件上限（超过触发 flush） |
| `hbase.regionserver.logroll.period` | 3600000 | 3600000 | WAL 滚动周期(1h) |
| `hbase.regionserver.hlog.syncer.count` | 5 | 5 | sync 线程数 |
| `hbase.wal.hsync` | false | false | true=fsync 落盘，false=hflush |
| `hbase.regionserver.wal.codec` | WALCellCodec | — | WAL 编码器 |
| `hbase.regionserver.hlog.blocksize` | HDFS block | — | WAL 文件大小上限 |

---

## 九、WAL 监控指标

```
关键 JMX 指标:
  - WAL.SyncTime_mean        → sync 平均延迟（正常 < 10ms）
  - WAL.SyncTime_99th        → P99 延迟（正常 < 50ms）
  - WAL.AppendCount          → 追加次数/秒
  - WAL.AppendSize_mean      → 平均追加大小
  - WAL.SlowSyncCount        → 慢 sync 次数（> 阈值）
  - WAL.RollRequest          → 滚动请求次数
  
告警阈值:
  - SyncTime_99th > 100ms → 预警（HDFS 可能有问题）
  - SyncTime_99th > 500ms → 报警（影响写入延迟）
  - WAL 文件数 > maxlogs × 0.8 → 预警（flush 可能跟不上）
```

---

*— Eric HBase 源码精通 B04 | 2026-04-30 —*
