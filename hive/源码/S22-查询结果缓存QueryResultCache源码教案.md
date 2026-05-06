# [教案] 查询结果缓存QueryResultsCache源码深度剖析

> 🎯 教学目标：掌握Hive查询结果缓存的完整架构，理解缓存key生成、命中判断、失效策略的源码实现 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：餐厅的"热菜保温台"

想象一家繁忙的餐厅。很多客人点的是同样的菜（相同的SQL查询），如果每次都从头做（重新计算），既浪费厨师时间又让客人等太久。解决方案：设一个**保温台**（QueryResultsCache），做好的热菜放在上面，下一个点同样菜的客人直接从保温台取。

但保温台也有规则：菜放久了会凉（TTL过期）、原料变了旧菜就不能吃了（表数据变更失效）、保温台空间有限（最大缓存容量）、太大的菜放不下（单条大小限制）。

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| QueryResultsCache | 全局缓存管理器（单例） | 保温台管理员 |
| CacheEntry | 单条缓存条目 | 保温台上的一道菜 |
| CacheEntryStatus | PENDING/VALID/INVALID | 制作中/可取/已废弃 |
| LookupInfo | 查找信息（查询文本+事务写ID） | 客人的菜单 |
| LRU | 最近最少使用淘汰 | 放最久没人要的菜先撤 |

### 2.2 核心数据结构

```java
// 三大索引结构
queryMap:       {queryText → Set<CacheEntry>}   // 查找索引
lru:            LinkedHashMap<CacheEntry>(accessOrder=true) // LRU淘汰
tableToEntryMap: {tableName → Set<CacheEntry>}  // 表级失效索引
```

---

## 三、源码深度剖析

### 3.1 缓存初始化（行362-409）

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/cache/results/QueryResultsCache.java
private QueryResultsCache(HiveConf configuration) throws IOException {
    Path rootCacheDir = new Path(conf.getVar(HiveConf.ConfVars.HIVE_QUERY_RESULTS_CACHE_DIRECTORY));
    cacheDirPath = new Path(rootCacheDir, "results-" + UUID.randomUUID().toString());
    FileSystem fs = cacheDirPath.getFileSystem(conf);
    fs.mkdirs(cacheDirPath, new FsPermission("700"));
    zeroRowsPath = new Path(cacheDirPath, "dummy_zero_rows");
    fs.deleteOnExit(cacheDirPath);
    maxCacheSize = conf.getLongVar(HiveConf.ConfVars.HIVE_QUERY_RESULTS_CACHE_MAX_SIZE);
    maxEntrySize = conf.getLongVar(HiveConf.ConfVars.HIVE_QUERY_RESULTS_CACHE_MAX_ENTRY_SIZE);
    maxEntryLifetime = conf.getTimeVar(HiveConf.ConfVars.HIVE_QUERY_RESULTS_CACHE_MAX_ENTRY_LIFETIME, TimeUnit.MILLISECONDS);
}
```

### 3.2 缓存查找 lookup()（行424-483）

```java
public CacheEntry lookup(LookupInfo request) {
    Lock readLock = rwLock.readLock();
    try {
      readLock.lock();
      Set<CacheEntry> candidates = queryMap.get(request.queryText);
      if (candidates != null) {
        for (CacheEntry candidate : candidates) {
          if (entryMatches(request, candidate, entriesToRemove)) {
            if (candidate.status == CacheEntryStatus.VALID) {
              result = candidate;
              break;
            } else if (candidate.status == CacheEntryStatus.PENDING) {
              pendingResult = candidate;
            }
          }
        }
      }
      if (result != null) lru.get(result); // 更新LRU
    } finally {
      readLock.unlock();
    }
    return result;
}
```

### 3.3 CacheEntry状态机

```
PENDING ──→ VALID ──→ INVALID
 (创建)    (填充完成)  (过期/表变更/LRU淘汰)
```

### 3.4 失效机制三触发

1. **TTL过期**：scheduleEntryInvalidation() 定时器
2. **表变更**：invalidateForTable(tableName) 按表名索引
3. **LRU淘汰**：shouldEntryBeAdded() 超容量时淘汰

---

## 四、生产实战

### 4.1 关键参数

| 参数名 | 默认值 | 说明 |
|--------|--------|------|
| `hive.query.results.cache.enabled` | true | 开启缓存 |
| `hive.query.results.cache.max.size` | 2GB | 总缓存大小 |
| `hive.query.results.cache.max.entry.size` | 10MB | 单条上限 |
| `hive.query.results.cache.max.entry.lifetime` | 3600s | TTL |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：缓存key是什么？** A：查询文本原文（未规范化）

**Q2：PENDING状态的作用？** A：防缓存击穿，多个相同查询只执行一次，其他等待

**Q3：ACID表如何保证一致性？** A：通过ValidTxnWriteIdList验证事务快照

---

## 六、知识晶体

```
缓存key=查询文本 | 状态机: PENDING→VALID→INVALID
失效: TTL + 表变更 + LRU | 并发: ReadWriteLock
防击穿: PENDING + waitForValidStatus()
```

---

## 七、参考资料

- `ql/src/java/org/apache/hadoop/hive/ql/cache/results/QueryResultsCache.java`
- HIVE-18513: Query results caching
