# [教案] HDFS集中缓存管理CacheManager源码深度剖析

> 🎯 教学目标：掌握HDFS集中缓存（Centralized Cache Management）的架构设计、NameNode端CacheManager的核心逻辑、DataNode端mmap/mlock缓存实现、缓存调度算法及与短路读的配合机制  
> ⏰ 预计学时：3学时  
> 📊 难度：★★★★☆

---

## 一、课前导入（生活类比/故障场景引入）

### 1.1 生活类比：图书馆的"热门书架"

想象一个大型图书馆（HDFS集群），有数百万本书（数据块）分布在各个书架（DataNode磁盘）上。

- **传统模式**：每次读者（客户端）来借书，管理员都要去仓库翻找，即使某些书每天被借阅100次
- **集中缓存模式**：图书馆设立"热门书架"（内存缓存），馆长（NameNode）统一决策哪些书放到热门书架，各楼层管理员（DataNode）执行实际摆放

这就是HDFS集中缓存的核心思想——**由NameNode统一调度，DataNode执行缓存，将热点数据锁定在内存中**。

### 1.2 生产故障场景引入

**场景**：某数据仓库集群，每天8:00-10:00有200+个Hive查询并发访问同一张维度表（约50GB），导致：
- 磁盘IO打满，读吞吐下降80%
- 查询P99延迟从5s飙升到120s
- DataNode频繁Full GC

**解决方案**：使用HDFS集中缓存，将维度表数据缓存到DataNode内存中，查询直接从内存读取，磁盘IO降为0。

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| Cache Pool | 缓存池 | 缓存资源的管理单元，类似YARN队列，控制配额和权限 |
| Cache Directive | 缓存指令 | 描述"缓存哪个路径、几副本、何时过期"的策略 |
| CacheManager | 缓存管理器 | NameNode侧的核心组件，管理所有Pool和Directive |
| CacheReplicationMonitor | 缓存副本监控器 | 后台线程，扫描directive决定哪些block需要缓存/取消 |
| FsDatasetCache | DataNode缓存执行器 | DataNode侧执行mmap/mlock的组件 |
| MappableBlock | 可映射块 | DataNode中被mmap+mlock锁定在内存的数据块 |
| CachedBlock | 已缓存块 | NameNode中跟踪block缓存状态的数据结构 |
| Cache Report | 缓存报告 | DataNode向NameNode汇报已缓存block列表（类似BlockReport） |

### 2.2 整体架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client (hdfs cacheadmin)                  │
│   addPool / addDirective / listDirectives / removeDirective      │
└───────────────────────────────┬──────────────────────────────────┘
                                │ RPC
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                        NameNode                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    CacheManager                             │  │
│  │  ┌──────────┐  ┌──────────────┐  ┌────────────────────┐   │  │
│  │  │CachePool │  │CacheDirective│  │CacheReplication-   │   │  │
│  │  │ TreeMap   │  │ById/ByPath  │  │Monitor (后台线程)   │   │  │
│  │  └──────────┘  └──────────────┘  └────────────────────┘   │  │
│  │                                           │                │  │
│  │              ┌────────────────────────────┘                │  │
│  │              ▼                                              │  │
│  │  ┌──────────────────────────┐                              │  │
│  │  │ cachedBlocks (GSet)       │←─── Block到DataNode映射     │  │
│  │  │ pendingCached / Uncached  │                              │  │
│  │  └──────────────────────────┘                              │  │
│  └────────────────────────────────────────────────────────────┘  │
└───────────────────────────────┬──────────────────────────────────┘
                                │ 心跳指令下发 / CacheReport上报
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      DataNode                                     │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                  FsDatasetCache                             │  │
│  │  ┌──────────────┐   ┌────────────┐   ┌──────────────────┐ │  │
│  │  │mappableBlock- │   │CachingTask │   │UncachingTask     │ │  │
│  │  │Map (HashMap)  │   │(线程池执行) │   │(含延迟uncache)   │ │  │
│  │  └──────────────┘   └────────────┘   └──────────────────┘ │  │
│  │         │                   │                               │  │
│  │         ▼                   ▼                               │  │
│  │  ┌────────────────────────────────┐                        │  │
│  │  │      MappableBlock              │                        │  │
│  │  │  mmap() + mlock() + checksum   │                        │  │
│  │  └────────────────────────────────┘                        │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 数据流转全景

```
用户执行 hdfs cacheadmin -addDirective -path /data/hot -pool mypool
    │
    ▼
1. CacheManager.addDirective() → 验证Pool/路径/副本数/过期时间/配额
    │
    ▼
2. CacheReplicationMonitor.rescan() → 遍历directive对应文件的所有block
    │                                   → 计算需要缓存的副本数
    │                                   → 选择DataNode加入pendingCached列表
    ▼
3. DataNode心跳响应 → 携带DNA_CACHE指令(待缓存blockId列表)
    │
    ▼
4. DataNode.FsDatasetCache.cacheBlock() → 提交CachingTask到线程池
    │
    ▼
5. CachingTask.run() → mmap → mlock → verifyChecksum → 状态改为CACHED
    │
    ▼
6. DataNode定期发送CacheReport → NameNode.processCacheReport()
    │                              → 更新cachedBlocks映射
    ▼
7. 客户端读取时 → NameNode在LocatedBlocks中标注cachedLocations
                 → 客户端优先从缓存节点读取（零拷贝短路读）
```

---

## 三、源码深度剖析

### 3.1 CacheManager核心数据结构

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/CacheManager.java`

```java
// 第126-165行：核心数据结构
/**
 * Cache directives, sorted by ID.
 * listCacheDirectives relies on the ordering of elements in this map
 * to track what has already been listed by the client.
 */
private final TreeMap<Long, CacheDirective> directivesById =
    new TreeMap<Long, CacheDirective>();

/**
 * The directive ID to use for a new directive. IDs always increase, and are never reused.
 */
private long nextDirectiveId;

/**
 * Cache directives, sorted by path
 */
private final TreeMap<String, List<CacheDirective>> directivesByPath =
    new TreeMap<String, List<CacheDirective>>();

/**
 * Cache pools, sorted by name.
 */
private final TreeMap<String, CachePool> cachePools =
    new TreeMap<String, CachePool>();

/**
 * All cached blocks.
 */
private final GSet<CachedBlock, CachedBlock> cachedBlocks;
```

**设计要点**：
- `directivesById`：按ID排序的TreeMap，支持分批列举（tailMap游标翻页）
- `directivesByPath`：按路径索引，方便CRM扫描时快速定位
- `cachedBlocks`：使用LightWeightGSet（开放寻址哈希表），内存效率高于HashMap
- 双索引设计（byId + byPath）保证了查询和扫描的O(logN)效率

### 3.2 addDirective——添加缓存指令

**文件路径**: `CacheManager.java` 第516-542行

```java
public CacheDirectiveInfo addDirective(
    CacheDirectiveInfo info, FSPermissionChecker pc, EnumSet<CacheFlag> flags)
    throws IOException {
  assert namesystem.hasWriteLock();  // 必须持有写锁
  CacheDirective directive;
  try {
    // 1. 验证Pool存在性
    CachePool pool = getCachePool(validatePoolName(info));
    // 2. 检查用户对Pool的WRITE权限
    checkWritePermission(pc, pool);
    // 3. 验证路径合法性
    String path = validatePath(info);
    // 4. 验证副本因子
    short replication = validateReplication(info, (short)1);
    // 5. 验证过期时间（不超过Pool的maxRelativeExpiry）
    long expiryTime = validateExpiryTime(info, pool.getMaxRelativeExpiryMs());
    // 6. 配额检查（除非FORCE标志跳过）
    if (!flags.contains(CacheFlag.FORCE)) {
      checkLimit(pool, path, replication);
    }
    // 7. 分配ID并创建directive
    long id = getNextDirectiveId();
    directive = new CacheDirective(id, path, replication, expiryTime);
    // 8. 加入内部数据结构
    addInternal(directive, pool);
  } catch (IOException e) {
    LOG.warn("addDirective of " + info + " failed: ", e);
    throw e;
  }
  LOG.info("addDirective of {} successful.", info);
  return directive.toInfo();
}
```

### 3.3 addInternal——内部注册逻辑

**文件路径**: `CacheManager.java` 第480-498行

```java
private void addInternal(CacheDirective directive, CachePool pool) {
  // 1. 将directive加入Pool的directive链表（IntrusiveCollection）
  boolean addedDirective = pool.getDirectiveList().add(directive);
  assert addedDirective;
  // 2. 加入byId索引
  directivesById.put(directive.getId(), directive);
  // 3. 加入byPath索引
  String path = directive.getPath();
  List<CacheDirective> directives = directivesByPath.get(path);
  if (directives == null) {
    directives = new ArrayList<CacheDirective>(1);
    directivesByPath.put(path, directives);
  }
  directives.add(directive);
  // 4. 计算需要缓存的字节数并更新Pool统计
  CacheDirectiveStats stats =
      computeNeeded(directive.getPath(), directive.getReplication());
  directive.addBytesNeeded(stats.getBytesNeeded());
  directive.addFilesNeeded(directive.getFilesNeeded());
  // 5. 通知CRM需要重新扫描
  setNeedsRescan();
}
```

**关键点**：`setNeedsRescan()` 会唤醒CacheReplicationMonitor线程，触发新一轮block调度。

### 3.4 CachePool——缓存池模型

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/CachePool.java`

```java
// 第49-100行：核心字段
public final class CachePool {
  private final String poolName;       // 池名称
  private String ownerName;             // 所有者
  private String groupName;             // 组
  private FsPermission mode;            // 权限（READ=列举, WRITE=增删改directive）
  private long limit;                   // 容量上限（字节）
  private long maxRelativeExpiryMs;     // directive最大有效期
  
  // 统计信息（由CRM扫描时重算）
  private long bytesNeeded;    // 需要缓存的总字节
  private long bytesCached;    // 已缓存的总字节
  private long filesNeeded;    // 需要缓存的文件数
  private long filesCached;    // 已完全缓存的文件数

  // 侵入式链表持有该Pool下所有directive
  public final static class DirectiveList
      extends IntrusiveCollection<CacheDirective> {
    private final CachePool cachePool;
    public CachePool getCachePool() { return cachePool; }
  }
  private final DirectiveList directiveList = new DirectiveList(this);
}
```

**设计亮点**：使用`IntrusiveCollection`（侵入式链表），CacheDirective本身是链表节点，避免额外的Node对象分配，减少GC压力。

### 3.5 CacheReplicationMonitor——缓存调度核心

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/CacheReplicationMonitor.java`

#### 3.5.1 主循环逻辑（第156-210行）

```java
@Override
public void run() {
  while (true) {
    lock.lock();
    try {
      while (true) {
        if (shutdown) return;
        // 条件1：有待处理的rescan请求
        if (completedScanCount < neededScanCount) break;
        // 条件2：到达定时扫描间隔
        long delta = (startTimeMs + intervalMs) - curTimeMs;
        if (delta <= 0) break;
        // 等待唤醒或超时
        doRescan.await(delta, TimeUnit.MILLISECONDS);
      }
    } finally { lock.unlock(); }
    
    mark = !mark;  // 翻转mark位，用于识别"本轮扫描是否处理过某block"
    rescan();      // 执行实际扫描
    
    lock.lock();
    try {
      completedScanCount = curScanCount;
      scanFinished.signalAll();  // 通知等待者扫描完成
    } finally { lock.unlock(); }
  }
}
```

#### 3.5.2 rescan()——全量扫描（第284-307行）

```java
private void rescan() throws InterruptedException {
  namesystem.writeLock();
  try {
    // 1. 重置所有Pool和Directive的统计信息
    resetStatistics();
    // 2. 扫描所有CacheDirective，确定每个block需要的缓存副本数
    rescanCacheDirectives();
    // 3. 扫描cachedBlocks，调度缓存/取消缓存
    rescanCachedBlockMap();
    // 4. 重置DN的lastCachingDirectiveSentTime，允许下次心跳携带缓存指令
    blockManager.getDatanodeManager().resetLastCachingDirectiveSentTime();
  } finally {
    namesystem.writeUnlock();
  }
}
```

#### 3.5.3 rescanCacheDirectives()——确定缓存需求（第322-362行）

```java
private void rescanCacheDirectives() {
  FSDirectory fsDir = namesystem.getFSDirectory();
  final long now = new Date().getTime();
  for (CacheDirective directive : cacheManager.getCacheDirectives()) {
    scannedDirectives++;
    // 跳过已过期的directive
    if (directive.getExpiryTime() > 0 && directive.getExpiryTime() <= now) {
      continue;
    }
    String path = directive.getPath();
    INode node = fsDir.getINode(path, DirOp.READ);
    if (node == null) continue;
    
    if (node.isDirectory()) {
      // 目录：遍历子文件逐个处理
      INodeDirectory dir = node.asDirectory();
      for (INode child : dir.getChildrenList(Snapshot.CURRENT_STATE_ID)) {
        if (child.isFile()) {
          rescanFile(directive, child.asFile());
        }
      }
    } else if (node.isFile()) {
      rescanFile(directive, node.asFile());
    }
  }
}
```

#### 3.5.4 rescanFile()——文件级缓存调度（第370-452行）

```java
private void rescanFile(CacheDirective directive, INodeFile file) {
  BlockInfo[] blockInfos = file.getBlocks();
  directive.addFilesNeeded(1);
  // 计算需要缓存的总字节（不含最后一个UC块）
  long neededTotal = file.computeFileSizeNotIncludingLastUcBlock() *
      directive.getReplication();
  directive.addBytesNeeded(neededTotal);
  
  // 配额检查：如果Pool已超限，跳过此文件
  CachePool pool = directive.getPool();
  if (pool.getBytesNeeded() > pool.getLimit()) return;

  long cachedTotal = 0;
  for (BlockInfo blockInfo : blockInfos) {
    // 不缓存未完成的块
    if (!blockInfo.getBlockUCState().equals(BlockUCState.COMPLETE)) continue;
    
    // 在cachedBlocks中创建或更新CachedBlock
    CachedBlock ncblock = new CachedBlock(blockInfo.getBlockId(),
        directive.getReplication(), mark);
    CachedBlock ocblock = cachedBlocks.get(ncblock);
    if (ocblock == null) {
      cachedBlocks.put(ncblock);  // 新增
      ocblock = ncblock;
    } else {
      // 已存在：统计当前已缓存字节
      List<DatanodeDescriptor> cachedOn = ocblock.getDatanodes(Type.CACHED);
      long cachedByBlock = Math.min(cachedOn.size(),
          directive.getReplication()) * blockInfo.getNumBytes();
      cachedTotal += cachedByBlock;
      // 更新replication和mark（取最大副本数）
      if ((mark != ocblock.getMark()) ||
          (ocblock.getReplication() < directive.getReplication())) {
        ocblock.setReplicationAndMark(directive.getReplication(), mark);
      }
    }
  }
  directive.addBytesCached(cachedTotal);
  if (cachedTotal == neededTotal) directive.addFilesCached(1);
}
```

**Mark机制详解**：
- 每轮扫描翻转mark位（true↔false）
- 如果某block的mark与当前轮次不同，说明没有任何directive在本轮引用它
- 这种block将被标记为"不再需要缓存"，触发uncache

#### 3.5.5 DataNode选择算法——addNewPendingCached()（第653-744行）

```java
private void addNewPendingCached(final int neededCached,
    CachedBlock cachedBlock, List<DatanodeDescriptor> cached,
    List<DatanodeDescriptor> pendingCached) {
  BlockInfo blockInfo = blockManager.getStoredBlock(
      new Block(cachedBlock.getBlockId()));
  
  // 构建候选节点列表（过滤条件）
  List<DatanodeDescriptor> possibilities = new LinkedList<>();
  for (int i = 0; i < blockInfo.getCapacity(); i++) {
    DatanodeDescriptor datanode = blockInfo.getDatanode(i);
    if (datanode == null) continue;
    if (datanode.isDecommissioned() || datanode.isDecommissionInProgress()) continue;
    if (corrupt != null && corrupt.contains(datanode)) continue;  // 排除损坏副本
    if (pendingCached.contains(datanode) || cached.contains(datanode)) continue;
    // 计算有效缓存容量
    long pendingCapacity = pendingBytes + datanode.getCacheRemaining();
    if (pendingCapacity < blockInfo.getNumBytes()) continue;  // 容量不足
    possibilities.add(datanode);
  }
  
  // 按剩余缓存容量加权随机选择
  List<DatanodeDescriptor> chosen = chooseDatanodesForCaching(
      possibilities, neededCached, staleInterval);
}
```

**选择策略**：`chooseRandomDatanodeByRemainingCapacity()`——按剩余缓存空间百分比做加权随机，空间越大被选中概率越高。这避免了所有缓存集中到少数节点。

### 3.6 DataNode侧——FsDatasetCache缓存执行

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/FsDatasetCache.java`

#### 3.6.1 状态机模型

```java
// 第81-111行
private enum State {
  CACHING,           // 正在缓存中（mmap+mlock进行中）
  CACHING_CANCELLED, // 缓存过程中被取消
  CACHED,            // 已缓存（可通告给NN）
  UNCACHING;         // 正在取消缓存中

  public boolean shouldAdvertise() {
    return (this == CACHED);  // 只有CACHED状态才上报给NameNode
  }
}
```

状态转换图：
```
               cacheBlock()          CachingTask完成
    (null) ──────────────> CACHING ──────────────> CACHED
                              │                       │
                   uncacheBlock()              uncacheBlock()
                              │                       │
                              ▼                       ▼
                    CACHING_CANCELLED            UNCACHING
                              │                       │
                   CachingTask检测到            UncachingTask完成
                              │                       │
                              ▼                       ▼
                          (移除)                   (移除)
```

#### 3.6.2 cacheBlock()——发起缓存（第294-311行）

```java
synchronized void cacheBlock(long blockId, String bpid,
    String blockFileName, long length, long genstamp,
    Executor volumeExecutor) {
  ExtendedBlockId key = new ExtendedBlockId(blockId, bpid);
  Value prevValue = mappableBlockMap.get(key);
  if (prevValue != null) {
    // 重复缓存请求，忽略
    numBlocksFailedToCache.incrementAndGet();
    return;
  }
  // 设置初始状态为CACHING
  mappableBlockMap.put(key, new Value(null, State.CACHING));
  // 提交异步缓存任务
  volumeExecutor.execute(
      new CachingTask(key, blockFileName, length, genstamp));
}
```

#### 3.6.3 CachingTask.run()——mmap/mlock核心实现（第431-511行）

```java
@Override
public void run() {
  boolean success = false;
  MappableBlock mappableBlock = null;
  // 1. 预留内存配额
  long newUsedBytes = reserve(length);
  if (newUsedBytes < 0) {
    LOG.warn("Failed to cache: could not reserve " + length + " bytes, " +
        "DFS_DATANODE_MAX_LOCKED_MEMORY of " + maxBytes + " exceeded.");
    return;
  }
  try {
    // 2. 打开block文件和meta文件
    blockIn = (FileInputStream)dataset.getBlockInputStream(extBlk, 0);
    metaIn = DatanodeUtil.getMetaDataInputStream(extBlk, dataset);
    
    // 3. 执行mmap + mlock + checksum验证
    mappableBlock = MappableBlock.load(length, blockIn, metaIn, blockFileName);
    
    // 4. 更新状态为CACHED
    synchronized (FsDatasetCache.this) {
      Value value = mappableBlockMap.get(key);
      if (value.state == State.CACHING_CANCELLED) {
        mappableBlockMap.remove(key);  // 被取消了
        return;
      }
      mappableBlockMap.put(key, new Value(mappableBlock, State.CACHED));
    }
    // 5. 通知短路读注册表
    dataset.datanode.getShortCircuitRegistry().processBlockMlockEvent(key);
    numBlocksCached.addAndGet(1);
  } finally {
    if (!success) {
      release(length);  // 释放预留配额
      if (mappableBlock != null) mappableBlock.close();
      mappableBlockMap.remove(key);
    }
  }
}
```

### 3.7 MappableBlock.load()——mmap+mlock+校验

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/MappableBlock.java` 第75-99行

```java
public static MappableBlock load(long length,
    FileInputStream blockIn, FileInputStream metaIn,
    String blockFileName) throws IOException {
  MappedByteBuffer mmap = null;
  FileChannel blockChannel = null;
  try {
    blockChannel = blockIn.getChannel();
    // 1. mmap：将文件映射到虚拟地址空间
    mmap = blockChannel.map(MapMode.READ_ONLY, 0, length);
    // 2. mlock：锁定物理内存页，防止被OS换出
    NativeIO.POSIX.getCacheManipulator().mlock(blockFileName, mmap, length);
    // 3. 校验checksum确保数据完整性
    verifyChecksum(length, metaIn, blockChannel, blockFileName);
    return new MappableBlock(mmap, length);
  } finally {
    IOUtils.closeQuietly(blockChannel);
    if (mappableBlock == null && mmap != null) {
      NativeIO.POSIX.munmap(mmap);  // 失败时释放
    }
  }
}
```

**系统调用解析**：
- `mmap()`：建立文件到进程虚拟地址空间的映射，不立即加载数据
- `mlock()`：锁定映射区域对应的物理页帧，防止被page swap出去
- 效果：后续读取该block时，不走`read()`系统调用，直接内存访问（零拷贝）

### 3.8 processCacheReport——缓存报告处理

**文件路径**: `CacheManager.java` 第937-999行

```java
public final void processCacheReport(final DatanodeID datanodeID,
    final List<Long> blockIds) throws IOException {
  namesystem.writeLock();
  try {
    DatanodeDescriptor datanode = 
        blockManager.getDatanodeManager().getDatanode(datanodeID);
    processCacheReportImpl(datanode, blockIds);
  } finally {
    namesystem.writeUnlock("processCacheReport");
  }
}

private void processCacheReportImpl(final DatanodeDescriptor datanode,
    final List<Long> blockIds) {
  // 1. 清空DN的cached列表（全量上报）
  CachedBlocksList cached = datanode.getCached();
  cached.clear();
  
  for (Long blockId : blockIds) {
    CachedBlock cachedBlock = new CachedBlock(blockId, (short)0, false);
    CachedBlock prevCachedBlock = cachedBlocks.get(cachedBlock);
    if (prevCachedBlock != null) {
      cachedBlock = prevCachedBlock;
    } else {
      cachedBlocks.put(cachedBlock);  // 新发现的缓存块
    }
    // 2. 加入DN的cached列表
    CachedBlocksList cachedList = datanode.getCached();
    if (!cachedBlock.isPresent(cachedList)) {
      cachedList.add(cachedBlock);
    }
    // 3. 从pendingCached中移除（说明已完成缓存）
    CachedBlocksList pendingCachedList = datanode.getPendingCached();
    if (cachedBlock.isPresent(pendingCachedList)) {
      pendingCachedList.remove(cachedBlock);
    }
  }
}
```

### 3.9 与短路读的配合——setCachedLocations

**文件路径**: `CacheManager.java` 第897-935行

```java
public void setCachedLocations(LocatedBlocks locations) {
  if (cachedBlocks.size() > 0) {
    for (LocatedBlock lb : locations.getLocatedBlocks()) {
      setCachedLocations(lb);
    }
  }
}

private void setCachedLocations(LocatedBlock block) {
  CachedBlock cachedBlock = new CachedBlock(block.getBlock().getBlockId(),
      (short)0, false);
  cachedBlock = cachedBlocks.get(cachedBlock);
  if (cachedBlock == null) return;
  
  // 找到缓存了此block的DataNode列表
  List<DatanodeDescriptor> cachedDNs = cachedBlock.getDatanodes(Type.CACHED);
  for (DatanodeDescriptor datanode : cachedDNs) {
    // 验证该DN确实持有此block的副本
    for (DatanodeInfo loc : block.getLocations()) {
      if (loc.equals(datanode)) {
        block.addCachedLoc(loc);  // 标记为缓存位置
        break;
      }
    }
  }
}
```

**客户端行为**：当`LocatedBlock.cachedLocations`不为空时，DFSClient优先从缓存节点发起短路读（通过Unix Domain Socket + SharedMemorySegment），实现零拷贝。

---

## 四、生产实战案例

### 4.1 案例一：热表缓存加速Hive查询

**场景**：Hive维度表`dim_user`（30GB）每天被500+查询Join，磁盘IO成瓶颈。

**操作步骤**：
```bash
# 1. 创建缓存池（限额100GB）
hdfs cacheadmin -addPool hot_tables -owner hive -limit 107374182400

# 2. 添加缓存指令（2副本缓存）
hdfs cacheadmin -addDirective -path /warehouse/dim_user -pool hot_tables -replication 2

# 3. 查看缓存进度
hdfs cacheadmin -listDirectives -pool hot_tables
# ID  Pool        Repl  Expiry  Path
# 1   hot_tables  2     never   /warehouse/dim_user
# Bytes Needed: 32212254720   Bytes Cached: 32212254720  (100%)

# 4. 验证短路读生效
hdfs debug verifyMeta -meta /warehouse/dim_user/000000_0
```

**效果**：查询延迟从12s降至1.8s，IO wait从65%降至3%。

### 4.2 案例二：缓存未生效排障

**症状**：执行addDirective后，Bytes Cached始终为0。

**排查步骤**：
```bash
# 1. 检查DataNode locked memory配置
hdfs getconf -confKey dfs.datanode.max.locked.memory
# 如果为0，缓存不会执行

# 2. 检查系统ulimit
cat /proc/$(pgrep -f DataNode)/limits | grep "locked memory"
# Max locked memory  unlimited  unlimited  bytes

# 3. 检查DataNode日志
grep "Failed to cache" /var/log/hadoop/datanode.log
# "could not reserve 134217728 more bytes: dfs.datanode.max.locked.memory of 0 exceeded"

# 4. 修复：设置DataNode最大锁定内存
# hdfs-site.xml
<property>
  <name>dfs.datanode.max.locked.memory</name>
  <value>68719476736</value>  <!-- 64GB -->
</property>

# 5. 设置OS级别
echo "* - memlock unlimited" >> /etc/security/limits.conf
# 或使用 ulimit -l unlimited
```

### 4.3 关键参数调优

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `dfs.datanode.max.locked.memory` | 0 | 物理内存的50-70% | DN最大锁定内存 |
| `dfs.namenode.path.based.cache.refresh.interval.ms` | 30000 | 10000-30000 | CRM扫描间隔 |
| `dfs.namenode.path.based.cache.block.map.allocation.percent` | 0.25 | 0.25-1.0 | cachedBlocks占堆比例 |
| `dfs.datanode.cache.revocation.timeout.ms` | 900000 | 300000-900000 | uncache前等待客户端释放的超时 |
| `dfs.datanode.cache.revocation.polling.ms` | 500 | 500-2000 | uncache轮询间隔 |

### 4.4 监控指标

```bash
# NameNode JMX
curl http://namenode:9870/jmx | jq '.beans[] | select(.name | contains("CacheAdmin"))'
# CacheCapacity, CacheUsed, CacheDirectivesNum, TotalCachedBlocks

# DataNode JMX  
curl http://datanode:9864/jmx | jq '.beans[] | select(.name | contains("FSDatasetState"))'
# CacheCapacity, CacheUsed, NumBlocksCached, NumBlocksFailedToCache
```

---

## 五、举一反三

### 5.1 与其他系统的类比

| 维度 | HDFS集中缓存 | Linux Page Cache | Redis缓存 |
|------|-------------|-----------------|-----------|
| 管理方式 | 集中式（NN决策） | 分布式（OS自动） | 集中式（Redis Server） |
| 淘汰策略 | 用户指定+过期 | LRU | LRU/LFU/TTL |
| 数据持久化 | 磁盘原始副本 | 磁盘文件 | 可选RDB/AOF |
| 一致性 | 强一致（NN权威） | 最终一致 | 最终一致 |
| 适用场景 | 大批量顺序热数据 | 通用文件IO | 小对象随机读 |

### 5.2 为什么不用OS Page Cache？

HDFS集中缓存相比依赖OS Page Cache的优势：
1. **确定性**：管理员明确知道哪些数据在缓存中，不会被其他进程挤出
2. **全局视图**：NN知道集群所有缓存分布，可让客户端精确路由
3. **零拷贝**：mlock后结合短路读，避免kernel↔user space拷贝
4. **避免双缓冲**：OS缓存 + JVM堆缓存会浪费2倍内存

### 5.3 面试高频题

**Q1：HDFS集中缓存的生命周期是怎样的？**

A：用户创建CachePool → 添加CacheDirective → CacheReplicationMonitor扫描确定需要缓存的block → 通过心跳下发DNA_CACHE指令给DataNode → DataNode执行mmap+mlock → 上报CacheReport → NameNode更新cachedLocations → 客户端获取LocatedBlock时带缓存位置信息 → 优先短路读。

**Q2：CacheReplicationMonitor的Mark机制有什么作用？**

A：Mark是一个boolean标志位，每轮扫描翻转一次。CachedBlock记录自己最后被设置的mark值。当CRM扫描cachedBlockMap时，如果发现某block的mark与当前轮次不同，说明该block在本轮没有被任何directive引用，应该被uncache。这是一种"标记-清除"的垃圾回收思想。

**Q3：如果DataNode缓存空间不足会怎样？**

A：
- CachingTask在执行前先调用`reserve(length)`预留空间
- 如果预留失败（超过`dfs.datanode.max.locked.memory`），直接返回失败
- CRM下次扫描时发现该block仍在pendingCached中，会重新选择其他有空间的DN
- NN侧`chooseRandomDatanodeByRemainingCapacity()`在选择时已考虑pendingCapacity

**Q4：集中缓存如何保证数据一致性？**

A：
- 缓存是只读的（MapMode.READ_ONLY），不会修改block数据
- 写入时，block状态变为UNDER_CONSTRUCTION，CRM跳过非COMPLETE的block
- 如果被缓存的文件被删除/覆盖，block的引用关系变化，下轮CRM扫描会发现该block不再被任何directive需要，触发uncache
- uncache通过`munmap()`释放映射，不影响磁盘上的block（如果还存在的话）

### 5.4 思考题

1. 如果一个目录下有10万个小文件，为该目录添加缓存指令会有什么性能问题？CRM的扫描复杂度是多少？
2. 在HA模式下，Active NN和Standby NN的CacheManager状态如何同步？（提示：EditLog）
3. 为什么`FsDatasetCache.uncacheBlock()`要检查`ShortCircuitRegistry`？如果有客户端正在短路读怎么办？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────────┐
│            HDFS 集中缓存管理 · 知识晶体                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  【核心组件】                                                        │
│  NameNode: CacheManager → CachePool + CacheDirective + CachedBlock │
│           CacheReplicationMonitor → 定期扫描+触发调度                │
│  DataNode: FsDatasetCache → CachingTask(mmap+mlock) + UncachingTask│
│           MappableBlock → 内存映射+锁定的block实体                   │
│                                                                     │
│  【数据流】                                                          │
│  addDirective → setNeedsRescan → CRM扫描 → pendingCached           │
│  → 心跳下发DNA_CACHE → mmap+mlock → CacheReport → cachedBlocks    │
│  → getBlockLocations附带cachedLoc → 客户端短路读(零拷贝)             │
│                                                                     │
│  【关键设计】                                                        │
│  • Mark翻转机制：标记-清除式识别不再需要的缓存block                   │
│  • 加权随机选DN：按剩余缓存容量加权，均匀分布                         │
│  • 延迟uncache：等待短路读客户端释放（revocationTimeout）             │
│  • 容量预留：CachingTask先reserve再执行，避免OOM                     │
│  • IntrusiveCollection：零额外内存的链表，减少GC                     │
│                                                                     │
│  【关键参数】                                                        │
│  dfs.datanode.max.locked.memory = 物理内存50-70%                    │
│  dfs.namenode.path.based.cache.refresh.interval.ms = 30000          │
│  ulimit -l unlimited (或 memlock unlimited in limits.conf)          │
│                                                                     │
│  【适用场景】                                                        │
│  ✓ 维度表/热点表反复读取    ✓ 实时查询低延迟要求                     │
│  ✓ Hive/Impala等OLAP工作负载  ✗ 一次性扫描/写入密集型                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/CacheManager.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/CachePool.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/protocol/CacheDirective.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/CacheReplicationMonitor.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/FsDatasetCache.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/datanode/fsdataset/impl/MappableBlock.java`

2. **设计文档**
   - HDFS-4949: Centralized cache management in HDFS (JIRA)
   - Apache Hadoop官方文档: Centralized Cache Management

3. **Linux内存管理**
   - `mmap(2)` man page
   - `mlock(2)` / `mlockall(2)` man page
   - Understanding the Linux Virtual Memory Manager (Mel Gorman)
