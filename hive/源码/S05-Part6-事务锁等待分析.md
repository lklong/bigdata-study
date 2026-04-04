# 06 - 事务锁等待分析

> 风险等级: 🟡 P1 | 触发条件: 并发 ACID 事务多/锁竞争 | 影响: 查询长时间等待

---

## 一、问题概述

Hive 的事务锁管理涉及三种锁机制：DbLockManager（HMS 事务锁）、ZooKeeper 分布式锁、Iceberg MetastoreLock。每种都有长时间等待的风险。

---

## 二、源码分析

### 2.1 DbLockManager — 指数退避重试

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/lockmgr/DbLockManager.java`

```java
// 行 86-119: lock 方法核心逻辑
LockState lock(LockRequest lock, String queryId, boolean isBlocking, 
    List<HiveLock> acquiredLocks) throws LockException {
    nextSleep = 50;
    // MAX_SLEEP = max(15000, hive.lock.sleep.between.retries) → 默认 60s
    MAX_SLEEP = Math.max(15000, conf.getTimeVar(...));
    // maxNumWaits = hive.lock.numretries → 默认 100
    int maxNumWaits = Math.max(0, conf.getIntVar(...));
    
    LockResponse res = txnManager.getMS().lock(lock);  // ⚠️ HMS RPC
    
    int numRetries = 0;
    while (res.getState() == LockState.WAITING && numRetries++ < maxNumWaits) {
        backoff();  // ⚠️ Thread.sleep，最多 MAX_SLEEP(60s)
        res = txnManager.getMS().checkLock(res.getLockid());  // ⚠️ HMS RPC
    }
    // 最大等待时间 ≈ 100 × 60s = 100 分钟!!!
}

// 行 376-391: 指数退避
private void backoff() {
    nextSleep *= 2;
    if (nextSleep > MAX_SLEEP) nextSleep = MAX_SLEEP;
    Thread.sleep(nextSleep);  // ⚠️ 不可中断
}
```

**默认配置风险**: 100 次重试 × 最大 60s/次 = **最长约 100 分钟等待**

### 2.2 ZooKeeper 分布式锁

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/lockmgr/zookeeper/ZooKeeperHiveLockManager.java`

```java
// 行 300-331: sleep 重试循环
do {
    if (tryNum > 1) {
        Thread.sleep(sleepTime);  // ⚠️ 
        prepareRetry();
    }
    ret = lockPrimitive(key, mode, keepAlive, parentCreated, conflictingLocks);
} while (tryNum < numRetriesForLock);

// 行 489-498: 释放锁也有 sleep 重试
do {
    if (tryNum > 1) {
        Thread.sleep(sleepTime);  // ⚠️ ZK 不可用时持续阻塞
    }
    unlockPrimitive(hiveLock, parent, curatorFramework);
} while (tryNum >= numRetriesForUnLock);
```

### 2.3 Iceberg MetastoreLock

**文件**: `iceberg/iceberg-catalog/src/main/java/org/apache/iceberg/hive/MetastoreLock.java`

```java
// 行 193-215: 锁获取重试
Tasks.foreach(lockInfo.lockId)
    .retry(Integer.MAX_VALUE - 100)         // ⚠️ 几乎无限重试
    .exponentialBackoff(
        lockCheckMinWaitTime,               // 默认 50ms
        lockCheckMaxWaitTime,               // 默认 5s
        lockAcquireTimeout,                 // 默认 3分钟
        1.5)
    .run(id -> {
        LockResponse response = metaClients.run(client -> client.checkLock(id));
        if (newState.equals(LockState.WAITING)) {
            throw new WaitingForLockException(...);  // 触发重试
        }
    });
```

### 2.4 HMSHandler Striped 表级锁

**文件**: `standalone-metastore/metastore-server/.../HMSHandler.java`

```java
// 行 131: Striped 锁
private static Striped<Lock> tablelocks;

// 行 3607: alter_partitions 中获取表锁
Lock tableLock = getTableLockFor(db_name, tbl_name);
tableLock.lock();  // ⚠️ 同表的 alter_partitions 串行化
```

---

## 三、排查与修复

### jstack 识别

```bash
grep -A 10 "DbLockManager\|backoff\|checkLock\|ZooKeeperHiveLock\|MetastoreLock" /tmp/hs2_jstack_*.txt
```

### 关键配置调优

```xml
<!-- 减少锁等待时间 -->
<property>
    <name>hive.lock.numretries</name>
    <value>50</value> <!-- 默认100，减半 -->
</property>
<property>
    <name>hive.lock.sleep.between.retries</name>
    <value>15</value> <!-- 默认60s，减到15s → 最大等待约12.5分钟 -->
</property>

<!-- 锁超时后 dump 锁状态（便于排查） -->
<property>
    <name>hive.txn.manager.dump.lock.state.on.acquire.timeout</name>
    <value>true</value>
</property>
```
