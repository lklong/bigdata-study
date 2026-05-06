# B03 — Compaction 调度与执行机制

> **段位**: L2→L3 | **方法**: 分形剥离 L2 主链路 + 对抗性阅读  
> **核心类**: `CompactSplitThread`, `RatioBasedCompactionPolicy`, `DefaultCompactor`, `Compactor`  
> **关联**: LSM-Tree 核心操作，直接影响读性能和空间放大

---

## 一、为什么需要 Compaction

```
LSM-Tree 的代价：

写入: MemStore → Flush → 产生一个新 HFile
      每次 Flush 都产生一个新文件

问题：随着时间推移，HFile 越来越多
  → 读取时需要扫描所有 HFile（读放大）
  → 同一个 RowKey 可能存在于多个 HFile（版本/删除标记分散）
  → 磁盘空间被已删除数据占用（空间放大）

解决：Compaction = 合并多个 HFile 为更少的 HFile
  → Minor Compaction: 选部分 HFile 合并（不清理删除标记）
  → Major Compaction: 合并所有 HFile（清理删除标记 + 过期版本）
```

---

## 二、Compaction 触发方式

### 2.1 自动触发

```
三种自动触发时机：

1. Flush 后触发（最常见）
   HStore.flushCache() 完成后
     → CompactSplitThread.requestCompaction(store)
       → 检查是否满足 compaction 条件

2. CompactionChecker Chore（定期检查）
   每隔 hbase.server.thread.wakefrequency × multiplier（默认 10s × 1000 = 约 2.7h）
     → 遍历所有 Store
       → 检查 needsCompaction()

3. 写入阻塞时触发
   StoreFile 数量 > hbase.hstore.blockingStoreFiles (默认 16)
     → 阻塞写入 + 紧急请求 compaction
```

### 2.2 手动触发

```bash
# HBase Shell
major_compact 'TableName'              # 整表 Major Compaction
major_compact 'TableName', 'CF1'       # 指定 CF
compact 'TableName'                    # Minor Compaction
compact 'RegionName'                   # 指定 Region
```

---

## 三、CompactSplitThread — 调度核心

```java
// CompactSplitThread.java
public class CompactSplitThread implements CompactionRequester {
    
    // 两类线程池
    private final ThreadPoolExecutor longCompactions;   // 大文件合并
    private final ThreadPoolExecutor shortCompactions;  // 小文件合并
    
    // 区分大小 compaction 的阈值
    private final long throttlePoint;  // hbase.regionserver.thread.compaction.throttle
                                       // 默认 = 2 × flush.size × multiplier
    
    public synchronized CompactionContext requestCompaction(HRegion region, HStore store,
            String why, int priority, CompactionLifeCycleTracker tracker) {
        
        // 1. 选择 compaction 策略
        CompactionContext context = store.requestCompaction(priority, tracker);
        
        if (context == null) {
            // 不需要 compaction
            return null;
        }
        
        // 2. 判断走 long 还是 short 线程池
        long size = context.getRequest().getSize();
        ThreadPoolExecutor pool;
        if (size > throttlePoint) {
            pool = longCompactions;   // 大文件走慢池
        } else {
            pool = shortCompactions;  // 小文件走快池
        }
        
        // 3. 提交任务
        pool.execute(new CompactionRunner(store, region, context));
        
        return context;
    }
}
```

---

## 四、文件选择策略

### 4.1 RatioBasedCompactionPolicy（默认策略）

```java
// RatioBasedCompactionPolicy.java

public CompactionRequestImpl selectCompaction(Collection<HStoreFile> candidates,
        List<HStoreFile> filesCompacting, boolean isUserCompaction,
        boolean mayUseOffPeak, boolean forceMajor) {
    
    // 1. 过滤正在 compaction 的文件
    List<HStoreFile> candidateFiles = filterBulk(candidates, filesCompacting);
    
    // 2. 检查是否需要 Major Compaction
    if (forceMajor || isMajorCompaction(candidateFiles)) {
        return new CompactionRequestImpl(candidateFiles, true);  // Major
    }
    
    // 3. Minor Compaction 文件选择 — 比率算法
    //    核心思想: 选择一组文件，使得每个文件 size < ratio × 后续所有文件 size 之和
    //    ratio = hbase.hstore.compaction.ratio (默认 1.2)
    
    List<HStoreFile> selected = applyCompactionPolicy(candidateFiles, 
        mayUseOffPeak, forceMajor);
    
    // 4. 检查选中文件数是否在 [min, max] 范围
    //    hbase.hstore.compaction.min = 3 (默认)
    //    hbase.hstore.compaction.max = 10 (默认)
    if (selected.size() < minFilesToCompact) {
        return null;  // 文件太少，不做
    }
    
    return new CompactionRequestImpl(selected, false);  // Minor
}
```

### 4.2 比率算法图解

```
假设有 5 个 HFile（按大小排序）:
  F1=10MB, F2=20MB, F3=50MB, F4=100MB, F5=200MB

ratio = 1.2

从最小的开始检查：
  F1(10) < 1.2 × (20+50+100+200) = 444  ✓ 可选
  F2(20) < 1.2 × (50+100+200) = 420      ✓ 可选
  F3(50) < 1.2 × (100+200) = 360         ✓ 可选
  F4(100) < 1.2 × (200) = 240            ✓ 可选
  F5(200) < 1.2 × (0) = 0                ✗ 不选

结果: 选 F1+F2+F3+F4 做 Minor Compaction → 合并为一个 ~180MB 文件
```

### 4.3 Major Compaction 触发条件

```java
private boolean isMajorCompaction(List<HStoreFile> filesToCompact) {
    // 1. 只有 1 个文件 → 不需要 major
    if (filesToCompact.size() <= 1) return false;
    
    // 2. 检查时间: 最老的文件是否超过 major compaction 周期
    //    hbase.hregion.majorcompaction = 604800000 (7天, 默认)
    //    + 随机抖动 (±20%)，避免所有 Region 同时 major compact
    long now = System.currentTimeMillis();
    long oldest = getOldestFileTimestamp(filesToCompact);
    
    if (now - oldest > majorCompactionPeriod + jitter) {
        return true;
    }
    
    return false;
}
```

---

## 五、Compaction 执行过程

```java
// DefaultCompactor.java
public class DefaultCompactor extends Compactor<InternalScanner> {
    
    public List<Path> compact(CompactionRequestImpl request, 
                              ThroughputController ctrl) throws IOException {
        
        List<HStoreFile> filesToCompact = request.getFiles();
        boolean isMajor = request.isMajor();
        
        // 1. 创建 Scanner（多路归并所有待合并文件）
        List<StoreFileScanner> scanners = new ArrayList<>();
        for (HStoreFile file : filesToCompact) {
            scanners.add(file.getReader().getStoreFileScanner());
        }
        InternalScanner scanner = createScanner(store, scanners, 
            isMajor ? ScanType.COMPACT_DROP_DELETES : ScanType.COMPACT_RETAIN_DELETES);
        
        // 2. 创建 Writer
        StoreFileWriter writer = store.createWriterInTmp(maxKeyCount, 
            store.getColumnFamilyDescriptor().getCompressionType(),
            isMajor, true, ...);
        
        // 3. 逐 Cell 读取 + 过滤 + 写入
        List<Cell> cells = new ArrayList<>();
        boolean hasMore;
        do {
            hasMore = scanner.next(cells);
            
            for (Cell cell : cells) {
                // Major 时会过滤：
                //   - 超过 maxVersions 的旧版本
                //   - Delete 标记和对应的被删数据
                //   - TTL 过期的数据
                writer.append(cell);
            }
            
            // 限速控制（避免 compaction 占满磁盘 IO）
            ctrl.control(request.getCompactedFileTotalSize());
            
            cells.clear();
        } while (hasMore);
        
        // 4. 关闭 writer，移动文件
        writer.close();
        
        // 5. 原子替换：旧文件 → 新文件
        store.replaceStoreFiles(filesToCompact, writer.getPath());
        
        // 6. 归档旧文件（移到 archive 目录）
        for (HStoreFile f : filesToCompact) {
            store.archiveFile(f);
        }
        
        return Collections.singletonList(writer.getPath());
    }
}
```

---

## 六、Compaction 对读写的影响

```
Compaction 期间：
┌─────────────────────────────────────────────────────────┐
│  写入: 不受影响（写 MemStore，与 Compaction 无关）        │
│                                                         │
│  读取: 仍可正常读                                        │
│        旧文件: 仍可读（引用计数 > 0，不会被删）            │
│        新文件: compact 完成后切换                         │
│                                                         │
│  IO 影响: Compaction 会消耗大量磁盘 IO 和 CPU            │
│          可能导致读延迟上升                               │
└─────────────────────────────────────────────────────────┘

Compaction 完成后：
  - 旧文件引用计数归零后被删除
  - 读路径切换到新文件
  - 读放大降低（HFile 数量减少）
  - 空间释放（Major Compaction 后）
```

---

## 七、Compaction 限速机制

```java
// PressureAwareCompactionThroughputController.java

// 核心思想: 当 StoreFile 数量接近 blockingStoreFiles 时加速
//           当远离时限速，避免 IO 风暴

public void control(long compactedSize) throws InterruptedException {
    long now = System.currentTimeMillis();
    long elapsed = now - startTime;
    
    double currentThroughput = (double) compactedSize / elapsed;
    
    if (currentThroughput > maxThroughput) {
        // 超速了，sleep 一会
        long sleepTime = (long) (compactedSize / maxThroughput - elapsed);
        Thread.sleep(sleepTime);
    }
}

// 参数:
// hbase.hstore.compaction.throughput.lower.bound = 50MB/s
// hbase.hstore.compaction.throughput.higher.bound = 100MB/s
```

---

## 八、写阻塞机制（Too Many StoreFiles）

```java
// HStore.java
public void throttleCompaction(long compactionSize) {
    int numStoreFiles = getStorefilesCount();
    int blockingFileCount = conf.getInt("hbase.hstore.blockingStoreFiles", 16);
    
    if (numStoreFiles >= blockingFileCount) {
        // 阻塞写入！等待 Compaction 减少文件数
        LOG.warn("Too many store files ({}); blocking updates for {}ms", 
            numStoreFiles, blockingWaitTime);
        
        // 等待 compaction 完成或超时
        synchronized (this) {
            this.wait(blockingWaitTime);  
            // hbase.hstore.blockingWaitTime = 90000 (90s)
        }
        
        // 超时后如果仍然超标 → 写入继续（避免永久阻塞）
    }
}
```

---

## 九、Compaction 性能模型

```
Minor Compaction 耗时:
  = (选中文件总大小) / (磁盘顺序读速度) × 读放大系数
  + (输出文件大小) / (磁盘顺序写速度) × 压缩系数
  
  例: 4个50MB文件 Minor Compact
  读: 200MB / 200MB/s = 1s
  压缩: ×1.5 (ZStd 正常)
  写: 150MB / 200MB/s = 0.75s
  总计: ~3s

Major Compaction 耗时:
  = Region 所有数据量 / 磁盘吞吐
  例: 10GB Region Major Compact
  读+写: 20GB IO / 200MB/s = 100s ≈ 1.7min
  
  生产环境单 Region 几十 GB → Major Compact 可能需要 30min+
```

---

## 十、关键配置清单

| 配置项 | 默认值 | 建议值 | 说明 |
|--------|--------|--------|------|
| `hbase.hstore.compaction.min` | 3 | 3~4 | 触发 Minor 的最少文件数 |
| `hbase.hstore.compaction.max` | 10 | 10~15 | 单次 Minor 最多合并文件数 |
| `hbase.hstore.compaction.ratio` | 1.2 | 1.2~1.5 | 文件选择比率 |
| `hbase.hstore.blockingStoreFiles` | 16 | 32~64 | 阻塞写入的文件数阈值 |
| `hbase.hregion.majorcompaction` | 604800000 (7d) | 0 (禁用自动) | Major Compaction 周期 |
| `hbase.regionserver.thread.compaction.large` | 1 | 4~6 | 长 Compaction 线程数 |
| `hbase.regionserver.thread.compaction.small` | 1 | 4~6 | 短 Compaction 线程数 |
| `hbase.hstore.compaction.throughput.lower.bound` | 50MB/s | 50~100MB/s | 限速下限 |
| `hbase.hstore.compaction.throughput.higher.bound` | 100MB/s | 100~200MB/s | 限速上限 |

### 生产建议

1. **禁用自动 Major Compaction**（`hbase.hregion.majorcompaction=0`），改为业务低峰手动/定时触发
2. **调高 blockingStoreFiles**（32~64），减少写阻塞概率
3. **Compaction 线程数按磁盘数配置**（每块盘 1~2 个线程）
4. **使用 FIFO Compaction** 或 **Date Tiered Compaction**（时序数据场景）

---

## 十一、Compaction 策略选型

| 策略 | 适用场景 | 特点 |
|------|----------|------|
| **RatioBasedCompactionPolicy** | 通用（默认） | 比率选文件，平衡读写 |
| **ExploringCompactionPolicy** | 2.x 默认 | 遍历所有组合选最优 |
| **FIFOCompactionPolicy** | TTL 数据（日志类） | 过期文件直接删，零 IO |
| **DateTieredCompactionPolicy** | 时序数据 | 按时间窗口分层合并 |
| **StripeCompactionPolicy** | 大 Region | 按 key range 分条带 |

---

## 十二、同构关系

| 概念 | HBase Compaction | Kafka Log Compaction | LSM-Tree (RocksDB) | MySQL |
|------|-----------------|---------------------|-------------------|-------|
| Minor | Minor Compact | — | L0→L1 Compact | — |
| Major | Major Compact | Log Compact (key-based) | L1→L2→... Compact | OPTIMIZE TABLE |
| 删除处理 | Tombstone 标记 | Tombstone 标记 | Tombstone 标记 | MVCC Purge |
| 限速 | ThroughputController | — | rate_limiter | — |
| 写阻塞 | blockingStoreFiles | — | level0_stop_writes_trigger | — |

---

*— Eric HBase 源码精通 B03 | 2026-04-30 —*
