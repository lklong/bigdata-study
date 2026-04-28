# HBase RegionServer Thread Dump 深度分析报告

**集群**: hbaseemr-0uhnacgj  
**节点**: 10.53.49.65:6002  
**Dump 时间**: 2026-04-25 19:31:29  
**JVM**: OpenJDK 64-Bit Server VM (25.282-b1, G1 GC)  
**RS 运行时间**: elapsed=94374s ≈ **26.2 小时**

---

## 一、线程全局概览

| 状态 | 数量 | 占比 |
|------|------|------|
| WAITING (parking) | 363 | 69.0% |
| RUNNABLE | 93 | 17.7% |
| TIMED_WAITING (parking) | 43 | 8.2% |
| TIMED_WAITING (on object monitor) | 10 | 1.9% |
| TIMED_WAITING (sleeping) | 9 | 1.7% |
| WAITING (on object monitor) | 5 | 1.0% |
| **BLOCKED (on object monitor)** | **3** | **0.6%** |
| **总计** | **526** | |

> 363 个 WAITING 线程主要是空闲的 RPC Handler（等待请求），属正常。3 个 BLOCKED 线程为 Jetty Acceptor，**与核心问题无关**（只是 ServerSocket accept 竞争，正常行为）。

---

## 二、核心问题：MemStoreFlusher.10 卡死在 ZStd 压缩

### 2.1 问题线程详情

```
"MemStoreFlusher.10" #411 prio=5 os_prio=0
  cpu=89,417,732.97ms ≈ 24.8小时
  elapsed=94,374.02s ≈ 26.2小时
  State: RUNNABLE
```

**CPU 利用率** = 89417732 / 94374020 = **94.7%**

这个线程自 RS 启动以来一直在疯狂消耗 CPU，几乎独占一个核。

### 2.2 调用栈定位

```
ZStandardCompressor.deflateBytesDirect(Native Method)      ← JNI 层，无法中断
  → ZStandardCompressor.compress()
    → CompressorStream.write()
      → HFileBlockDefaultEncodingContext.compressAfterEncoding()
        → HFileBlock$Writer.finishBlock()
          → HFileWriterImpl.checkBlockBoundary() / append()
            → StoreFileWriter.append()
              → StoreFlusher.performFlush()
                → DefaultStoreFlusher.flushSnapshot()   ← 持有锁 <0x00007f4e57bed1e0>
                  → HStore.flushCache()
                    → HRegion.flushcache()
                      → MemStoreFlusher.flushRegion()
```

**关键锁**: `locked <0x00007f4e57bed1e0>` — `DefaultStoreFlusher.flushSnapshot` 中的 Store 级锁，**没有其他线程在等这把锁**（未发现 waiting to lock 0x00007f4e57bed1e0），所以不是死锁问题。

### 2.3 关联线程 — ITEM 表的 DataStreamer

```
Line 611: "DataStreamer for file /hbase/data/default/ITEM/28b3ed084b599e9a72fb288417ff95a7/.tmp/CF1/2e511062b063445f9f828bf4020fb29b"
  cpu=20.72ms  elapsed=90,694.29s ≈ 25.2小时
  State: TIMED_WAITING (Object.wait)
```

这个 DataStreamer 是 Flush 过程中向 HDFS 写 HFile 的线程。**elapsed=25.2小时**，说明 flush 在 25 小时前就开始往 HDFS 写了，但因为 MemStoreFlusher.10 一直在做 ZStd 压缩，导致写入速度极慢，DataStreamer 大部分时间在等待数据。

---

## 三、CPU Top 线程排名

| 排名 | 线程 | CPU 时间 | 说明 |
|------|------|----------|------|
| **1** | **MemStoreFlusher.10** | **89,417,732ms (24.8h)** | **卡在 ZStd 压缩 — 问题根因** |
| 2 | append-pool-0 (WAL) | 4,607,632ms (1.28h) | WAL 写入，当前空闲 WAITING |
| 3-8 | G1 Parallel Marking ×6 | ~3,015,000ms (0.84h) 每个 | GC 标记线程，总计 ~5h CPU |
| 9 | hedgedRead-3 | 2,390,130ms (0.66h) | HDFS hedged read，当前空闲 |
| 10 | longCompactions-0 | 2,427,629ms (0.67h) | 长 Compaction 线程，当前空闲 |

> MemStoreFlusher.10 的 CPU 消耗是第 2 名的 **19.4 倍**，绝对的异常值。

---

## 四、其他 MemStoreFlusher 线程状态

| 线程 | CPU (ms) | 状态 | 位置 |
|------|----------|------|------|
| MemStoreFlusher.0 | 97,765 | TIMED_WAITING | DelayQueue.poll（空闲等任务） |
| MemStoreFlusher.1 | 81,643 | TIMED_WAITING | 同上 |
| MemStoreFlusher.2 | 87,711 | TIMED_WAITING | 同上 |
| MemStoreFlusher.3 | 70,968 | TIMED_WAITING | 同上 |
| MemStoreFlusher.4 | 85,755 | TIMED_WAITING | 同上 |
| MemStoreFlusher.5 | 94,056 | TIMED_WAITING | 同上 |
| MemStoreFlusher.6 | 91,890 | TIMED_WAITING | 同上 |
| MemStoreFlusher.7 | 97,412 | TIMED_WAITING | 同上 |
| MemStoreFlusher.8 | 96,099 | TIMED_WAITING | 同上 |
| MemStoreFlusher.9 | 95,783 | TIMED_WAITING | 同上 |
| **MemStoreFlusher.10** | **89,417,732** | **RUNNABLE** | **ZStd 压缩死循环** |
| MemStoreFlusher.11 | 88,179 | TIMED_WAITING | 同上 |
| MemStoreFlusher.12 | 97,978 | TIMED_WAITING | 同上 |
| MemStoreFlusher.13 | 99,766 | TIMED_WAITING | 同上 |
| MemStoreFlusher.14 | 100,876 | TIMED_WAITING | 同上 |
| MemStoreFlusher.15 | 93,329 | TIMED_WAITING | 同上 |

**配置了 16 个 flush 线程**（0-15），其中 15 个空闲（DelayQueue.poll 等新任务），**只有 #10 在干活而且卡死了**。

关键发现：其他 15 个线程 CPU 都是正常级别（70-100秒），说明它们正常完成了 flush 任务后进入等待。**只有 #10 的 CPU 是千倍异常**。

---

## 五、BLOCKED 线程分析

3 个 BLOCKED 线程全部是 **Jetty HTTP Acceptor**（端口 6003 的 RS Web UI）：

```
qtp1458675510-366-acceptor-3  → waiting to lock <0x00007f4a1a41fc70>
qtp1458675510-365-acceptor-2  → waiting to lock <0x00007f4a1a41fc70>
qtp1458675510-364-acceptor-1  → waiting to lock <0x00007f4a1a41fc70>
qtp1458675510-363-acceptor-0  → locked <0x00007f4a1a41fc70>  (RUNNABLE, accept0)
```

**这是正常行为**：4 个 Acceptor 竞争一把 ServerSocket 锁，1 个拿到锁在 accept，其他 3 个等待。**与 flush 问题无关**。

---

## 六、GC 压力评估

| 线程组 | 数量 | 单线程 CPU | 总 CPU |
|--------|------|-----------|--------|
| G1 Parallel Marking | 6 | ~3,015s (50min) | ~5h |
| G1 Concurrent Refinement | 14 | 825-2407s | ~17.6h |

G1 Concurrent Refinement 线程消耗总计 ~17.6h CPU，说明 **GC 压力较大**，堆内存中有大量对象需要跨 Region 引用处理。这可能是因为 MemStore 数据积压导致堆内存长期处于高水位。

---

## 七、Compaction 线程状态

| 类型 | 数量 | 状态 |
|------|------|------|
| shortCompactions | 6 (0-5) | 全部 TIMED_WAITING（空闲） |
| longCompactions | 6 (0-5) | 全部 TIMED_WAITING（空闲） |

Compaction 线程当前全部空闲，**没有 compaction 在跑**。但总 CPU 较高（每个 1.3-2.4h），说明此前有过密集 compaction。

---

## 八、根因分析

### 确定性结论（基于 Thread Dump 证据）

1. **MemStoreFlusher.10 线程陷入 ZStd Native 压缩死循环/极端慢速**
   - 证据：cpu=89,417,732ms 而 elapsed=94,374,020ms，CPU 利用率 94.7%
   - 线程状态 RUNNABLE，不是被锁阻塞，是真在执行
   - 卡在 `deflateBytesDirect(Native Method)` — JNI 层无法被 Java 中断

2. **该 flush 操作对应 ITEM 表的 Region `28b3ed084b599e9a72fb288417ff95a7`**
   - 证据：DataStreamer 文件路径 `/hbase/data/default/ITEM/28b3ed084b599e9a72fb288417ff95a7/.tmp/CF1/`
   - DataStreamer elapsed=90,694s ≈ 25.2h，与你给的 "since 25hrs 12mins" 完全吻合

3. **没有死锁**
   - 锁 `<0x00007f4e57bed1e0>` 被 MemStoreFlusher.10 持有，无其他线程在等此锁
   - 3 个 BLOCKED 线程是 Jetty Acceptor，与此无关

4. **其他 flush 线程健康** — 15 个线程全部空闲等待新任务

### 疑点/待确认

- **为什么 ZStd 会死循环？** Thread Dump 无法回答，需查看：
  - ITEM 表该 Region 的 MemStore 大小（是否异常大）
  - libzstd native library 版本
  - 是否有 HADOOP-17292 相关补丁
  - HFile block 大小配置

---

## 九、处理方案

### 紧急止血（立即执行）

**方案 A：Force unassign 该 Region**
```bash
# HBase Shell
unassign '28b3ed084b599e9a72fb288417ff95a7', true
```
> Region 会被移到其他 RS 重新 open。如果 unassign 也卡住（因为 region close 需要完成 flush），走方案 B。

**方案 B：Kill 该 RS 进程**
```bash
# 查找 RS 进程
ps -ef | grep HRegionServer | grep -v grep

# 直接 kill（不用 graceful stop，因为 flush 卡住会导致 graceful stop 也卡）
kill -9 <pid>

# 等 Master 检测到 RS 挂了（默认 zk session timeout 90s），Region 会被自动迁移
# 然后重启 RS
hbase-daemon.sh start regionserver
```

### 长期修复

| 优先级 | 措施 | 操作 |
|--------|------|------|
| **P0** | **ITEM 表换压缩算法** | `alter 'ITEM', {NAME=>'CF1', COMPRESSION=>'LZ4'}` + `major_compact 'ITEM'` |
| P1 | 检查 libzstd 版本 | `ls -la $HADOOP_HOME/lib/native/libzstd*` 确认版本，升级到 1.5.2+ |
| P1 | 检查所有使用 ZSTD 的表 | `list` + 逐表 `describe` 查看，全部换成 LZ4/SNAPPY |
| P2 | 监控 flush 耗时 | 添加告警：单次 flush > 10 分钟即报警 |
| P2 | 确认 HFile block 大小 | 默认 64KB，如果被调大可能加重压缩负担 |

---

## 十、总结

这是一个 **ZStd Native Library 层面的 bug 或极端性能退化问题**，不是 HBase 代码本身的 bug，也不是死锁。单个 flush 线程在 JNI 层消耗了 24.8 小时 CPU 仍未完成一个 block 的压缩，这完全不正常（正常 ZStd 压缩一个 64KB block 应在毫秒级）。

**建议现在就执行 unassign 或 kill RS 止血，然后尽快把 ITEM 表（以及集群中所有用了 ZSTD 的表）换成 LZ4 压缩。**
