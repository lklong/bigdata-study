# 08 - 缓存锁竞争分析

> 风险等级: 🟢 P2 | 触发条件: 缓存预热/大量并发读写 | 影响: 缓存操作延迟

---

## 一、问题概述

Hive 中有多个缓存组件使用锁来保证一致性，在高并发场景下可能产生锁竞争。

---

## 二、源码分析

### 2.1 SharedCache — 全局 + 表级读写锁

**文件**: `standalone-metastore/metastore-server/.../cache/SharedCache.java`

```java
// 行 92: 全局公平读写锁
private static ReentrantReadWriteLock cacheLock = new ReentrantReadWriteLock(true);

// 行 291: 每个表一个读写锁
private ReentrantReadWriteLock tableLock = new ReentrantReadWriteLock(true);
```

**问题**: 公平模式下写者优先，缓存预热/刷新时持有写锁会阻塞所有读操作。大量并发对同一表的分区操作会竞争 `tableLock`。

### 2.2 QueryResultsCache — 等待 pending 条目

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/cache/results/QueryResultsCache.java`

```java
// 行 324-326: 等待缓存条目变为 valid
synchronized (this) {
    this.wait(timeout);  // ⚠️ 等待 pending 的缓存条目完成
}
// 如果缓存条目长时间不完成，查询会一直等待
```

### 2.3 LlapObjectCache — 嵌套锁

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/LlapObjectCache.java`

```java
// 行 84-131: 两层锁嵌套
lock.lock();                    // 全局锁
  objectLock = locks.get(key);  // 获取 per-key 锁
lock.unlock();

objectLock.lock();              // per-key 锁
  lock.lock();                  // 再次获取全局锁检查缓存
  lock.unlock();
  value = fn.call();            // ⚠️ 如果 fn.call() 很慢，持有 objectLock
objectLock.unlock();
```

### 2.4 HiveClientCache

**文件**: `metastore/src/java/org/apache/hadoop/hive/metastore/HiveClientCache.java`

```java
// 行 258-263: 全局锁保护缓存操作
synchronized (CACHE_TEARDOWN_LOCK) {
    cacheableHiveMetaStoreClient = getOrCreate(cacheKey);
    cacheableHiveMetaStoreClient.acquire();
}
// ⚠️ 如果 MetaStoreClient 创建慢，所有缓存操作被阻塞
```

---

## 三、排查与修复

### jstack 识别

```bash
grep -A 10 "SharedCache\|QueryResultsCache\|LlapObjectCache\|HiveClientCache\|CACHE_TEARDOWN" \
  /tmp/hs2_jstack_*.txt | grep -B 3 "BLOCKED\|WAITING"
```

### 修复建议

1. **SharedCache**: 监控缓存预热时间，避免在高峰期刷新
2. **QueryResultsCache**: 设置合理的缓存超时 `hive.query.results.cache.wait.for.pending.results.timeout`
3. **LlapObjectCache**: 缓存 miss 时的 `fn.call()` 应有超时控制
4. **HiveClientCache**: 增大缓存容量减少 eviction 频率
