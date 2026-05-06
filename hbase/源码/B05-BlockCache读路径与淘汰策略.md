# B05 — BlockCache 读路径与淘汰策略

> **段位**: L2→L3 | **方法**: 分形剥离 L2 + 量化驱动理解  
> **核心类**: `LruBlockCache`, `BucketCache`, `CombinedBlockCache`, `CacheConfig`, `HFileReaderImpl`  
> **同构**: BlockCache ≈ OS Page Cache ≈ MySQL Buffer Pool ≈ HDFS BlockReaderCache

---

## 一、BlockCache 在读路径中的位置

```
Client.get(Get) / Client.scan(Scan)
  │
  ▼
HRegion.getScanner()
  │
  ▼
StoreScanner（多路归并）
  │
  ├─ MemStoreScanner (内存，最快)
  │
  └─ StoreFileScanner ×N (磁盘 HFile)
       │
       ▼
     HFileReaderImpl.readBlock(blockOffset)
       │
       ├─ 1. 查 BlockCache (命中 → 直接返回，延迟 ~μs)
       │     ├─ L1: LruBlockCache (堆内)
       │     └─ L2: BucketCache (堆外/文件)
       │
       └─ 2. Cache Miss → 从 HDFS 读取 Block (延迟 ~ms)
              │
              ├─ 解压缩 Block
              ├─ 放入 BlockCache
              └─ 返回 Block 数据
```

---

## 二、Block Cache 三种实现

### 2.1 LruBlockCache（默认，堆内）

```java
// LruBlockCache.java — 基于 ConcurrentHashMap 的 LRU 缓存

public class LruBlockCache implements FirstLevelBlockCache {
    
    private final ConcurrentHashMap<BlockCacheKey, LruCachedBlock> map;
    private final long maxSize;  // = 堆 × hfile.block.cache.size (0.4)
    
    // 三级优先级
    enum BlockPriority {
        SINGLE,    // 首次访问（25% 容量）
        MULTI,     // 多次访问（50% 容量）
        MEMORY     // In-memory CF（25% 容量）
    }
    
    public Cacheable getBlock(BlockCacheKey key, boolean caching) {
        LruCachedBlock block = map.get(key);
        if (block != null) {
            // 命中! 更新访问计数
            block.access(accessCount.incrementAndGet());
            
            // SINGLE → MULTI 提升
            if (block.getPriority() == SINGLE) {
                block.setPriority(MULTI);
            }
            
            return block.getBuffer();
        }
        return null;  // Miss
    }
    
    public void cacheBlock(BlockCacheKey key, Cacheable value, boolean inMemory) {
        // 放入缓存
        LruCachedBlock block = new LruCachedBlock(key, value, 
            inMemory ? MEMORY : SINGLE);
        map.put(key, block);
        currentSize.addAndGet(value.heapSize());
        
        // 检查是否需要淘汰
        if (currentSize.get() > acceptableSize) {
            runEviction();
        }
    }
}
```

### 2.2 淘汰策略

```
LRU 淘汰规则（三级优先级）:

容量分配:
  SINGLE (25%) ← 首次读取的 Block
  MULTI  (50%) ← 被读取 ≥2 次的 Block
  MEMORY (25%) ← IN_MEMORY CF 的 Block

淘汰顺序:
  1. 先淘汰 SINGLE 区最久未用的
  2. SINGLE 不够淘 → 淘汰 MULTI 区最久未用的
  3. MEMORY 区最后被淘汰

这保证了:
  - 全表 Scan 不会挤掉热点数据（Scan 的 Block 停留在 SINGLE 区）
  - 频繁访问的 Block 在 MULTI 区受保护
  - 标记为 IN_MEMORY 的 CF（如 meta 表）始终在缓存中
```

### 2.3 BucketCache（堆外/文件）

```java
// BucketCache.java — 大容量堆外缓存

public class BucketCache implements BlockCache {
    
    // 存储介质选择:
    //   "offheap" → DirectByteBuffer (堆外内存)
    //   "file:/path" → 文件 mmap（SSD 推荐）
    //   "pmem:/path" → Intel Optane 持久内存
    
    // 内部用 Bucket 管理，类似 Slab Allocator
    // 每个 Bucket 管理固定大小的 Block
    //   4KB, 8KB, 16KB, 32KB, 64KB, 128KB, 256KB, 512KB
    
    private final BucketAllocator allocator;
    private final IOEngine ioEngine;  // 实际存储引擎
    
    // 写缓存(异步):
    // 1. 放入 ramCache (ConcurrentHashMap)
    // 2. WriterThread 异步写入 IOEngine
    
    // 读缓存:
    // 1. 查 ramCache
    // 2. 查 backingMap → 从 IOEngine 读取
}
```

### 2.4 CombinedBlockCache（推荐！L1 + L2）

```
CombinedBlockCache = LruBlockCache(L1) + BucketCache(L2)

分工:
  L1 (LruBlockCache, 堆内):
    - 存放 Index Block（HFile 索引）
    - 存放 Bloom Filter Block
    - 容量小但查询最快（零拷贝）

  L2 (BucketCache, 堆外):
    - 存放 Data Block（实际数据）
    - 容量大（可以几十 GB）
    - 不影响 GC（堆外）

查找顺序:
  1. L1 查 Index/Bloom → 确定 Block 位置
  2. L2 查 Data Block → 命中返回
  3. Miss → HDFS 读取 → 放入 L2
```

---

## 三、读路径详解 — 从 Get 到 Block

```java
// HFileReaderImpl.java

public HFileBlock readBlock(long dataBlockOffset, boolean cacheBlock, 
                            boolean pread, boolean isCompaction) throws IOException {
    
    BlockCacheKey cacheKey = new BlockCacheKey(name, dataBlockOffset);
    
    // 1. 查 L1 Cache
    Cacheable cachedBlock = cacheConf.getBlockCache().getBlock(cacheKey, cacheBlock);
    if (cachedBlock != null) {
        // Cache Hit!
        HIT_COUNT.increment();
        return (HFileBlock) cachedBlock;
    }
    
    // 2. Cache Miss → 从 HDFS 读取
    MISS_COUNT.increment();
    HFileBlock block = readBlockFromHDFS(dataBlockOffset, pread);
    
    // 3. 解压缩（如果有压缩）
    block = block.unpack(hfileContext, fsBlockReader);
    //   → ZStd/LZ4/Snappy decompress
    
    // 4. 放入 Cache
    if (cacheBlock && cacheConf.shouldCacheDataOnRead()) {
        cacheConf.getBlockCache().cacheBlock(cacheKey, block, inMemory);
    }
    
    return block;
}
```

### 3.1 BloomFilter 快速跳过

```java
// StoreFileReader.java

public boolean passesGeneralRowBloomFilter(Cell cell) {
    // BloomFilter 判断: 该 RowKey 是否可能存在于此 HFile
    //   - 返回 true: 可能存在（需要继续读）
    //   - 返回 false: 一定不存在（跳过此 HFile）
    
    BloomFilter bloom = this.generalBloomFilter;
    if (bloom == null) return true;  // 没有 bloom → 不能跳过
    
    return bloom.contains(cell);
}

// BloomFilter 假阳性率 ≈ 1%（默认配置）
// 效果: 对于 Point Get，平均可跳过 99% 的不相关 HFile
```

---

## 四、性能模型

### 4.1 缓存命中率模型

```
命中率公式 (简化):
  Hit Rate = 1 - (Working Set Size / Cache Size)  （当 Working Set < Cache）
  Hit Rate ≈ Cache Size / Working Set Size         （当 Working Set > Cache）

举例:
  堆内存 32GB
  BlockCache = 32GB × 0.4 = 12.8GB (L1)
  BucketCache = 32GB (堆外配置)
  总 Cache = 44.8GB
  
  数据热点 = 100GB → 命中率 ≈ 44.8/100 = 44.8%
  数据热点 = 40GB  → 命中率 ≈ 90%+（热点数据全在缓存）
```

### 4.2 延迟模型

```
读延迟 = P(hit) × T(cache_read) + P(miss) × T(hdfs_read)

其中:
  T(cache_read) ≈ 0.01~0.1ms（堆内） 或 0.1~0.5ms（堆外）
  T(hdfs_read)  ≈ 1~10ms（SSD） 或 5~50ms（HDD）

举例（90% 命中率, SSD）:
  平均延迟 = 0.9 × 0.1ms + 0.1 × 3ms = 0.39ms

举例（50% 命中率, HDD）:
  平均延迟 = 0.5 × 0.1ms + 0.5 × 20ms = 10.05ms
```

---

## 五、缓存预热与 Prefetch

```java
// PrefetchExecutor.java — HFile 打开时预加载 Block 到缓存

// 配置: hbase.rs.prefetchblocksonopen = true
// 适用: Region 重新 open 后（重启/迁移），避免冷启动

// 工作方式:
// Region open → 遍历所有 HFile → 后台线程逐 Block 读入缓存
// 效果: 避免刚 open 后的大量 cache miss
```

---

## 六、Scan 场景的缓存策略

```
问题: 全表 Scan 会把大量数据读入缓存，挤掉热点数据（Cache Thrashing）

解决方案:

1. CacheBlocks = false (Scan 不缓存)
   scan.setCacheBlocks(false);
   → Scan 读取的 Block 不放入 BlockCache
   → 保护热点数据不被挤掉

2. SINGLE 区淘汰保护（LruBlockCache 默认行为）
   → Scan 读取的 Block 进入 SINGLE 区（25% 容量）
   → 不影响 MULTI 区的热点数据
   → SINGLE 区很快被后续 Scan 的 Block 替换

3. BucketCache 的 Memory-Type 隔离
   → 不同优先级的 Block 放在不同 Bucket
   → Scan 数据不会挤占 Index/Bloom 缓存
```

---

## 七、GC 影响与堆外缓存

```
堆内 BlockCache (LruBlockCache) 的问题:
  - 大量 Block 对象在老年代 → Full GC 时标记扫描慢
  - 缓存越大 → GC 停顿越长
  - 32GB 堆 × 40% = 12.8GB 缓存对象 → GC 可能 10s+

解决: BucketCache (堆外)
  - Block 数据存储在 DirectByteBuffer
  - 不参与 GC 标记
  - 索引（backingMap）在堆内，但很小
  - 效果: 可以配 100GB+ 缓存而 GC 不受影响

推荐配置:
  hbase-env.sh:
    -XX:MaxDirectMemorySize=34g
  
  hbase-site.xml:
    hfile.block.cache.size = 0.1       # L1 堆内只放 Index/Bloom
    hbase.bucketcache.ioengine = offheap
    hbase.bucketcache.size = 32768     # 32GB 堆外
```

---

## 八、关键配置清单

| 配置项 | 默认值 | 建议值 | 说明 |
|--------|--------|--------|------|
| `hfile.block.cache.size` | 0.4 | 0.1(有BucketCache) / 0.4(无) | L1 堆内缓存占比 |
| `hbase.bucketcache.ioengine` | — | offheap | BucketCache 引擎 |
| `hbase.bucketcache.size` | 0 | 32768+ (MB) | BucketCache 容量 |
| `hbase.bucketcache.combinedcache.enabled` | true | true | L1+L2 组合模式 |
| `hbase.rs.cacheblocksonwrite` | false | false | 写时是否缓存 |
| `hbase.rs.prefetchblocksonopen` | false | true (SSD) | 开表时预加载 |
| `hbase.block.data.cachecompressed` | false | false | 缓存压缩数据 |
| `hbase.lru.blockcache.single.percentage` | 0.25 | 0.25 | SINGLE 区占比 |
| `hbase.lru.blockcache.multi.percentage` | 0.50 | 0.50 | MULTI 区占比 |
| `hbase.lru.blockcache.memory.percentage` | 0.25 | 0.25 | MEMORY 区占比 |

---

## 九、监控指标

```
关键 JMX 指标:
  BlockCache:
    - blockCacheHitPercent         → 命中率（目标 > 90%）
    - blockCacheHitCount           → 命中次数/秒
    - blockCacheMissCount          → 未命中次数/秒
    - blockCacheEvictionCount      → 淘汰次数/秒
    - blockCacheSize               → 当前缓存大小
    - blockCacheCount              → 缓存 Block 数
    
  BucketCache 特有:
    - bucketCacheHitPercent        → L2 命中率
    - bucketCacheFreeSize          → 剩余空间
    - bucketCacheIOHitCount        → 从 IOEngine 读取次数

告警:
  - hitPercent < 80% → 预警（缓存不够或访问模式变化）
  - hitPercent < 60% → 报警（需要扩容或调整策略）
  - evictionCount 突增 → 缓存压力大
```

---

## 十、排障决策树

```
读延迟高？
│
├─ 检查 BlockCache 命中率
│   ├─ > 90% → 缓存没问题，查 HDFS/网络
│   ├─ 70-90% → 缓存偏小，考虑扩容
│   └─ < 70% → 严重！
│         ├─ 检查是否有大量 Scan（setCacheBlocks=false）
│         ├─ 检查 Working Set 是否远大于 Cache
│         └─ 检查是否有 Major Compaction 导致缓存失效
│
├─ GC 停顿长？
│   └─ 堆内 BlockCache 过大 → 切换 BucketCache
│
└─ 缓存命中但延迟高？
    └─ 检查是否堆内 GC 影响
    └─ 检查是否 BucketCache IOEngine 读取慢（文件模式）
```

---

*— Eric HBase 源码精通 B05 | 2026-04-30 —*
