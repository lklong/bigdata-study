# S11 - Hive Metastore 事务管理与锁机制源码深度分析

> **知识晶体化模板** | 基于 Hive 3.x 源码 | 作者: Eric (豹纹) for 大哥

---

## 一、问题/场景

在 Hive ACID 表的读写场景中，事务管理和锁机制是保证数据一致性的核心基础设施。以下是常见的运维场景问题：

1. **长事务导致锁堆积**：某条查询执行数小时，其持有的 Shared Read 锁阻止了 ALTER TABLE 等 DDL 操作
2. **事务超时被 Abort**：客户端心跳发送不及时，Metastore HouseKeeper 线程将事务标记为 Aborted
3. **锁等待超时**：INSERT 操作等待 EXCLUSIVE 锁释放时超时报错 `LOCK_ACQUIRE_TIMEDOUT`
4. **Write-Write 冲突**：两个并发 UPDATE 操作同时修改同一分区，First-Committer-Wins 规则触发

**核心源码目录**:
- 客户端事务管理: `ql/src/java/org/apache/hadoop/hive/ql/lockmgr/`
- 服务端事务处理: `standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/txn/`

---

## 二、核心架构概览

```
┌─────────────────────────────────────────────────────────┐
│                     Hive Client (Driver)                 │
│                                                         │
│   ┌─────────────────┐     ┌──────────────────┐         │
│   │  DbTxnManager   │────▶│  DbLockManager   │         │
│   │ (事务管理入口)    │     │  (锁管理代理)     │         │
│   └────────┬────────┘     └────────┬─────────┘         │
│            │                       │                    │
│   ┌────────▼────────────────────────▼─────────┐        │
│   │         IMetaStoreClient (Thrift)          │        │
│   └────────────────────┬───────────────────────┘        │
└────────────────────────┼────────────────────────────────┘
                         │ Thrift RPC
┌────────────────────────▼────────────────────────────────┐
│              Hive Metastore Server                       │
│                                                         │
│   ┌──────────────────────────────────────────┐         │
│   │              TxnHandler                   │         │
│   │  (事务/锁核心实现, 操作 RDBMS)            │         │
│   │                                           │         │
│   │  ┌─────────┐ ┌───────────┐ ┌──────────┐ │         │
│   │  │openTxns │ │lock()     │ │heartbeat │ │         │
│   │  │commitTxn│ │checkLock()│ │timeOuts  │ │         │
│   │  │abortTxn │ │unlock()   │ │          │ │         │
│   │  └─────────┘ └───────────┘ └──────────┘ │         │
│   └──────────────────┬───────────────────────┘         │
│                      │                                  │
│   ┌──────────────────▼───────────────────────┐         │
│   │      Backend RDBMS (MySQL/Postgres/Derby) │         │
│   │  Tables: TXNS, HIVE_LOCKS, TXN_COMPONENTS│         │
│   │          NEXT_TXN_ID, NEXT_LOCK_ID,       │         │
│   │          WRITE_SET, MIN_HISTORY_LEVEL      │         │
│   └──────────────────────────────────────────┘         │
│                                                         │
│   ┌──────────────────────────────────────────┐         │
│   │       AcidHouseKeeperService             │         │
│   │  (后台定时线程: 清理超时事务/锁)          │         │
│   └──────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────┘
```

---

## 三、核心源码分析

### 3.1 DbTxnManager — 客户端事务管理入口

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/lockmgr/DbTxnManager.java`

`DbTxnManager` 是 `HiveTxnManager` 的核心实现，每个 `SessionState` 对应一个实例。它负责事务的完整生命周期管理。

#### 3.1.1 类结构与关键成员

```java
// DbTxnManager.java:93-117
public final class DbTxnManager extends HiveTxnManagerImpl {
    private volatile DbLockManager lockMgr = null;
    private volatile long txnId = 0;                    // 当前事务ID
    private Map<String, Long> tableWriteIds = new HashMap<>();  // 表写ID缓存
    private int stmtId = -1;                            // 当前语句ID (用于delta子目录命名)
    private int numStatements = 0;                      // 当前事务语句计数
    private boolean isExplicitTransaction = false;      // 是否显式事务 (START TRANSACTION)
    private static ScheduledExecutorService heartbeatExecutorService = null;  // 心跳线程池
    private ScheduledFuture<?> heartbeatTask = null;    // 当前心跳任务
}
```

**设计意图**:
- `stmtId` 是一个单调递增的语句 ID，用于在同一事务内的多次写操作中区分不同的 delta 子目录 (`delta_<txnId>_<txnId>_<stmtId>`)
- `isExplicitTransaction` 区分隐式事务（单条语句自动提交）和显式事务（用户 START TRANSACTION），显式事务不允许不可回滚的操作（如 DROP TABLE）

#### 3.1.2 openTxn() — 开启事务

```java
// DbTxnManager.java:234-258
long openTxn(Context ctx, String user, long delay) throws LockException {
    init();
    getLockManager();
    if(isTxnOpen()) {
        throw new LockException("Transaction already opened. " + JavaUtils.txnIdToString(txnId));
    }
    try {
        txnId = getMS().openTxn(user);       // 通过Thrift调用Metastore分配txnId
        stmtId = 0;                           // 重置语句计数器
        numStatements = 0;
        tableWriteIds.clear();
        isExplicitTransaction = false;
        startTransactionCount = 0;
        LOG.debug("Opened " + JavaUtils.txnIdToString(txnId));
        ctx.setHeartbeater(startHeartbeat(delay));  // 启动心跳
        return txnId;
    } catch (TException e) {
        throw new LockException(e, ErrorMsg.METASTORE_COMMUNICATION_FAILED);
    }
}
```

**调用链**:
```
Driver.execute()
  └─▶ DbTxnManager.openTxn(ctx, user)
        ├─▶ init()                         // 初始化
        ├─▶ getLockManager()               // 创建 DbLockManager
        ├─▶ getMS().openTxn(user)          // Thrift → TxnHandler.openTxns()
        │     └─▶ 在TXNS表插入记录(TXN_OPEN状态)
        │     └─▶ 分配txnId (NEXT_TXN_ID)
        └─▶ startHeartbeat(delay)          // 启动心跳定时任务
```

#### 3.1.3 acquireLocks() — 锁获取的完整流程

```java
// DbTxnManager.java:274-286
public void acquireLocks(QueryPlan plan, Context ctx, String username) throws LockException {
    try {
        acquireLocksWithHeartbeatDelay(plan, ctx, username, 0);
    }
    catch(LockException e) {
        if(e.getCause() instanceof TxnAbortedException) {
            txnId = 0;       // 事务已被Abort，清理状态
            stmtId = -1;
            tableWriteIds.clear();
        }
        throw e;
    }
}
```

锁获取的核心流程在 `acquireLocks(plan, ctx, username, isBlocking)` 方法中:

```java
// DbTxnManager.java:411-618 (简化)
LockState acquireLocks(QueryPlan plan, Context ctx, String username, boolean isBlocking) {
    // 1. 构建 LockRequest
    LockRequestBuilder rqstBuilder = new LockRequestBuilder(queryId);
    rqstBuilder.setTransactionId(txnId).setUser(username);
    
    // 2. 为每个读输入添加 SHARED_READ 锁
    for (ReadEntity input : plan.getInputs()) {
        if (!input.needsLock() || input.isUpdateOrDelete() || !needsLock(input)) continue;
        LockComponentBuilder compBuilder = new LockComponentBuilder();
        compBuilder.setShared();  // SHARED_READ
        compBuilder.setOperationType(DataOperationType.SELECT);
        // ... 设置 DB/Table/Partition
    }
    
    // 3. 为每个写输出添加相应锁
    for (WriteEntity output : plan.getOutputs()) {
        // INSERT → SHARED_WRITE (允许并发插入)
        // UPDATE/DELETE → SHARED_WRITE (DP模式) 或 EXCLUSIVE
        // INSERT_OVERWRITE → EXCLUSIVE
        // DDL (CREATE/ALTER/DROP) → EXCLUSIVE
    }
    
    // 4. 通过 DbLockManager 发送锁请求
    return lockMgr.lock(rqstBuilder.build(), plan.getQueryId(), isBlocking, acquiredLocks);
}
```

**锁类型与操作的映射关系**:

| 操作类型 | 锁类型 | 说明 |
|---------|--------|------|
| SELECT | SHARED_READ | 允许并发读 |
| INSERT | SHARED_WRITE | 允许并发插入不同分区 |
| UPDATE/DELETE | SHARED_WRITE | First-Committer-Wins |
| INSERT OVERWRITE | EXCLUSIVE | 独占写，阻塞所有并发 |
| DROP TABLE/ALTER | EXCLUSIVE | DDL 独占 |

#### 3.1.4 commitTxn() / rollbackTxn()

```java
// DbTxnManager.java:657-682
public void commitTxn() throws LockException {
    if (!isTxnOpen()) {
        throw new RuntimeException("Attempt to commit before opening a transaction");
    }
    try {
        lockMgr.clearLocalLockRecords();  // 清理本地锁记录
        stopHeartbeat();                   // 停止心跳
        LOG.debug("Committing txn " + JavaUtils.txnIdToString(txnId));
        getMS().commitTxn(txnId);          // Thrift → TxnHandler.commitTxn()
    } catch (NoSuchTxnException e) {
        // 事务可能已被超时Abort
        throw new LockException(e, ErrorMsg.TXN_NO_SUCH_TRANSACTION, ...);
    } catch (TxnAbortedException e) {
        // Write-Write冲突检测：First-Committer-Wins
        throw new LockException(e, ErrorMsg.TXN_ABORTED, ...);
    } finally {
        txnId = 0;        // 无论成功失败都重置
        stmtId = -1;
        numStatements = 0;
        tableWriteIds.clear();
    }
}
```

---

### 3.2 心跳机制 — 防止事务超时

#### 3.2.1 startHeartbeat()

```java
// DbTxnManager.java:794-809
private Heartbeater startHeartbeat(long initialDelay) throws LockException {
    long heartbeatInterval = getHeartbeatInterval(conf);  
    // 默认: hive.txn.timeout / 2 (即 150秒，因为默认timeout=300秒)
    
    UserGroupInformation currentUser = UserGroupInformation.getCurrentUser();
    Heartbeater heartbeater = new Heartbeater(this, conf, queryId, currentUser);
    heartbeatTask = startHeartbeat(initialDelay, heartbeatInterval, heartbeater);
    return heartbeater;
}
```

**关键细节**: `initialDelay` 不为0时是一个 `[0, 0.75*heartbeatInterval]` 的随机值，防止大量查询同时到达时心跳风暴。

#### 3.2.2 heartbeat() — 心跳发送

```java
// DbTxnManager.java:736-787
public void heartbeat() throws LockException {
    List<HiveLock> locks;
    if(isTxnOpen()) {
        // 有事务时只需心跳事务ID，锁通过事务自动续期
        DbLockManager.DbHiveLock dummyLock = new DbLockManager.DbHiveLock(0L);
        locks = new ArrayList<>(1);
        locks.add(dummyLock);
    } else {
        // 无事务时需要心跳每个锁
        locks = lockMgr.getLocks(false, false);
    }
    
    for (HiveLock lock : locks) {
        long lockId = ((DbLockManager.DbHiveLock)lock).lockId;
        getMS().heartbeat(txnId, lockId);  // Thrift → TxnHandler.heartbeat()
    }
}
```

**设计意图**: 对于关联事务的锁，`HIVE_LOCKS.hl_last_heartbeat` 设为 0，只更新 `TXNS.txn_last_heartbeat`。这样简化了心跳逻辑——只需心跳事务即可保活所有关联锁。

---

### 3.3 TxnHandler — 服务端事务/锁核心实现

**文件**: `standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/txn/TxnHandler.java`

这是一个约 5000+ 行的核心类，直接操作 RDBMS 来管理事务和锁的全部状态。

#### 3.3.1 lock() — 锁入队与检查

```java
// TxnHandler.java:1831-1840
public LockResponse lock(LockRequest rqst) throws NoSuchTxnException, TxnAbortedException, MetaException {
    // 第一步: 将锁以 WAITING 状态写入 HIVE_LOCKS 表
    ConnectionLockIdPair connAndLockId = enqueueLockWithRetry(rqst);
    try {
        // 第二步: 检查锁是否可以立即获取
        return checkLockWithRetry(connAndLockId.dbConn, connAndLockId.extLockId, rqst.getTxnid());
    } catch(NoSuchLockException e) {
        throw new MetaException("Couldn't find a lock we just created! " + e.getMessage());
    }
}
```

**调用链 — lock() 完整流程**:
```
TxnHandler.lock(LockRequest)
  │
  ├─▶ enqueueLockWithRetry(rqst)
  │     ├─▶ lockInternal()                    // 获取JVM级别互斥锁(Derby)
  │     ├─▶ getDbConn(READ_COMMITTED)
  │     ├─▶ lockTransactionRecord(stmt, txnId, TXN_OPEN)  // S4U锁定TXNS行
  │     ├─▶ SELECT nl_next FROM NEXT_LOCK_ID FOR UPDATE    // 分配lockId
  │     ├─▶ UPDATE NEXT_LOCK_ID SET nl_next = nl_next + 1
  │     ├─▶ INSERT INTO TXN_COMPONENTS                     // 记录事务组件
  │     ├─▶ INSERT INTO HIVE_LOCKS (state=WAITING)         // 所有锁先入WAITING队列
  │     ├─▶ dbConn.commit()
  │     └─▶ unlockInternal()
  │
  └─▶ checkLockWithRetry(dbConn, extLockId, txnId)
        └─▶ checkLock(dbConn, extLockId)
              ├─▶ acquireLock(MUTEX_KEY.CheckLock)         // 全局互斥
              ├─▶ getLockInfoFromLockId()                    // 查询当前锁信息
              ├─▶ 检查 WRITE_SET 冲突 (First-Committer-Wins优化)
              ├─▶ SELECT * FROM HIVE_LOCKS WHERE hl_lock_ext_id < extLockId
              │   (只查看更早的锁，保证公平性FIFO)
              ├─▶ 使用 jumpTable 判断兼容性
              │   ├─ ACQUIRE → 标记为 ACQUIRED
              │   ├─ WAIT → 标记 BLOCKEDBY 信息，返回 WAITING
              │   └─ KEEP_LOOKING → 继续检查前面的锁
              └─▶ 若所有锁都兼容 → acquire() → UPDATE HIVE_LOCKS SET state=ACQUIRED
```

#### 3.3.2 enqueueLockWithRetry() — 锁入队

```java
// TxnHandler.java:1882-2079 (关键逻辑)
private ConnectionLockIdPair enqueueLockWithRetry(LockRequest rqst) {
    // 1. 锁定事务记录防止并发修改
    lockHandle = lockTransactionRecord(stmt, txnid, TXN_OPEN);
    
    // 2. 分配 extLockId (全局唯一锁ID)
    String s = sqlGenerator.addForUpdateClause("select nl_next from NEXT_LOCK_ID");
    rs = stmt.executeQuery(s);
    long extLockId = rs.getLong(1);
    stmt.executeUpdate("update NEXT_LOCK_ID set nl_next = " + (extLockId + 1));
    
    // 3. 记录事务组件 (TXN_COMPONENTS表)
    for (LockComponent lc : rqst.getComponent()) {
        // INSERT/UPDATE/DELETE 操作记录到 TXN_COMPONENTS
        // SELECT/NO_TXN 不记录
    }
    
    // 4. 所有锁以 WAITING 状态插入 HIVE_LOCKS
    for (LockComponent lc : rqst.getComponent()) {
        intLockId++;
        // 锁类型映射: EXCLUSIVE→'e', SHARED_READ→'r', SHARED_WRITE→'w'
        // 关键: 关联事务的锁 hl_last_heartbeat = 0 (通过事务心跳续期)
        //       独立锁 hl_last_heartbeat = now (需要独立心跳)
        rows.add(extLockId + ", " + intLockId + ", " + txnid + ", " +
            ... + quoteChar(LOCK_WAITING) + ", " + quoteChar(lockChar) + ", " +
            (isValidTxn(txnid) ? 0 : now) + ...);
    }
    INSERT INTO HIVE_LOCKS (...) VALUES ...;
    dbConn.commit();
}
```

#### 3.3.3 锁兼容性判断 — jumpTable

`jumpTable` 是一个三维映射: `请求锁类型 → 已有锁类型 → 已有锁状态 → 动作`

```java
// TxnHandler.java:4532-4639
private static synchronized void buildJumpTable() {
    jumpTable = new HashMap<>(3);
    // ...
}
```

**锁兼容矩阵** (从源码直接提取):

| 请求\已有 | SR(Acquired) | SR(Waiting) | SW(Acquired) | SW(Waiting) | E(Acquired) | E(Waiting) |
|----------|:----------:|:---------:|:----------:|:---------:|:---------:|:--------:|
| **SR** | ACQUIRE | KEEP_LOOKING | ACQUIRE | KEEP_LOOKING | WAIT | WAIT |
| **SW** | KEEP_LOOKING | KEEP_LOOKING | WAIT | WAIT | WAIT | WAIT |
| **E** | WAIT | WAIT | WAIT | WAIT | WAIT | WAIT |

- **ACQUIRE**: 可以直接获取锁
- **WAIT**: 必须等待，记录 BLOCKEDBY 信息
- **KEEP_LOOKING**: 继续检查前面的锁（因为前面可能有更严格的锁阻塞）

**关键设计**: 只查看 `hl_lock_ext_id < extLockId` 的锁（即更早入队的锁），保证 FIFO 公平调度。

#### 3.3.4 checkLock() — 锁冲突检测核心

```java
// TxnHandler.java:3671-3931 (核心逻辑)
private LockResponse checkLock(Connection dbConn, long extLockId) {
    // 1. 获取 CheckLock 全局互斥锁
    handle = getMutexAPI().acquireLock(MUTEX_KEY.CheckLock.name());
    
    // 2. 获取当前要检查的锁列表
    List<LockInfo> locksBeingChecked = getLockInfoFromLockId(dbConn, extLockId);
    
    // 3. First-Committer-Wins 优化检查
    // 如果有 SHARED_WRITE 锁，检查 WRITE_SET 中是否有已提交事务写了相同资源
    if (writeSet is not empty) {
        rs = SELECT FROM WRITE_SET WHERE ws_commit_id >= txnId AND (same resource);
        if (rs.next()) {
            // 发现冲突! 直接 Abort 当前事务
            abortTxns(dbConn, txnId);
            throw new TxnAbortedException("concurrent committed transaction has already updated resource");
        }
    }
    
    // 4. 查询所有比当前更早的锁
    SELECT FROM HIVE_LOCKS WHERE hl_db IN (...) AND hl_lock_ext_id < extLockId;
    
    // 5. 对每个待检查锁，遍历所有更早的锁，使用 jumpTable 判断
    for (LockInfo info : locksBeingChecked) {
        if (info.state == LockState.ACQUIRED) continue;  // 已获取的跳过(幂等)
        
        for (int i = locks.length - 1; i >= 0; i--) {
            if (!same_db || !same_table || !same_partition) continue;
            
            LockAction lockAction = jumpTable.get(info.type).get(locks[i].type).get(locks[i].state);
            switch (lockAction) {
                case WAIT:
                    if(!ignoreConflict(info, locks[i])) {
                        // 回滚到savepoint，记录阻塞信息
                        UPDATE HIVE_LOCKS SET HL_BLOCKEDBY_EXT_ID=..., HL_BLOCKEDBY_INT_ID=...;
                        return LockState.WAITING;
                    }
                    // fall through to ACQUIRE
                case ACQUIRE:
                    break;  // 可以获取
                case KEEP_LOOKING:
                    continue;  // 继续看前面
            }
            break;  // 确定可获取，跳出内层循环
        }
    }
    
    // 6. 所有锁都通过检查，批量获取
    acquire(dbConn, stmt, locksBeingChecked);
    // UPDATE HIVE_LOCKS SET hl_lock_state='a', hl_acquired_at=now WHERE hl_lock_ext_id=extLockId
    return LockState.ACQUIRED;
}
```

---

### 3.4 心跳与超时清理 — AcidHouseKeeperService

**文件**: `standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/txn/AcidHouseKeeperService.java`

```java
// AcidHouseKeeperService.java:32-71
public class AcidHouseKeeperService implements MetastoreTaskThread {
    
    @Override
    public long runFrequency(TimeUnit unit) {
        // 运行频率由 metastore.timedout.txn.reaper.interval 控制 (默认60秒)
        return MetastoreConf.getTimeVar(conf, MetastoreConf.ConfVars.TIMEDOUT_TXN_REAPER_INTERVAL, unit);
    }
    
    @Override
    public void run() {
        TxnStore.MutexAPI.LockHandle handle = null;
        try {
            handle = txnHandler.getMutexAPI().acquireLock(TxnStore.MUTEX_KEY.HouseKeeper.name());
            txnHandler.performTimeOuts();  // 执行超时清理
        } finally {
            if(handle != null) handle.releaseLocks();
        }
    }
}
```

#### 3.4.1 performTimeOuts() — 超时清理逻辑

```java
// TxnHandler.java:4388-4458
public void performTimeOuts() {
    long now = getDbTime(dbConn);
    
    // 第一步: 清理超时的独立锁 (非事务关联)
    timeOutLocks(dbConn, now);
    // DELETE FROM HIVE_LOCKS WHERE hl_last_heartbeat < (now - timeout) AND hl_txnid = 0
    
    // 第二步: 清理超时事务 (循环批处理)
    while(true) {
        // 查找超时事务 (心跳时间 < now - timeout)
        SELECT txn_id FROM TXNS 
        WHERE txn_state = 'o' 
        AND txn_last_heartbeat < (now - timeout) 
        AND txn_type != REPL_CREATED;
        
        if (!rs.next()) return;  // 没有超时事务
        
        // 分批 Abort (每批 50000)
        for (List<Long> batchToAbort : timedOutTxns) {
            UPDATE TXNS SET txn_state = 'a' 
            WHERE txn_state = 'o' AND txn_id IN (...) 
            AND txn_last_heartbeat < max_heartbeat;
            // 同时删除关联锁和 MIN_HISTORY_LEVEL 记录
        }
    }
}
```

**超时时序图**:
```
时间轴 ─────────────────────────────────────────────────▶
   T0        T1          T2          T3          T4
   │         │           │           │           │
   │ openTxn │           │ heartbeat │           │
   │─────────│───────────│───────────│───────────│──
   │         │           │           │           │
   │         │           │           │  HouseKeeper检查:
   │         │           │           │  txn_last_heartbeat < now - timeout?
   │         │           │           │  如果 T3 - T2 > timeout → ABORT!
   │         │           │           │
```

---

### 3.5 死锁处理机制

Hive 的锁模型是基于 **FIFO 队列** 而非传统的 Wait-For-Graph，因此 **应用层不存在死锁**。但 RDBMS 层面的死锁需要处理:

```java
// TxnHandler.java:3232-3294
protected void checkRetryable(Connection conn, SQLException e, String caller) {
    boolean sendRetrySignal = false;
    
    if (DatabaseProduct.isDeadlock(dbProduct, e)) {
        // DB 死锁检测: MySQL/MSSQL用40001, Postgres用40001/40P01
        if (deadlockCnt++ < ALLOWED_REPEATED_DEADLOCKS) {
            long waitInterval = deadlockRetryInterval * deadlockCnt;
            LOG.warn("Deadlock detected in " + caller + ". Will wait " + waitInterval + "ms");
            Thread.sleep(waitInterval);  // 指数退避
            sendRetrySignal = true;
        } else {
            LOG.error("Too many repeated deadlocks in " + caller + ", giving up.");
        }
    } else if (isRetryable(conf, e)) {
        // 可重试的瞬态错误 (如通信中断)
        if (retryNum++ < retryLimit) {
            Thread.sleep(retryInterval);
            sendRetrySignal = true;
        }
    }
    
    if (sendRetrySignal) throw new RetryException();
}
```

**设计要点**:
- RDBMS 死锁通过**递归重试**解决: 每个公共方法 catch `RetryException` 后递归调用自身
- `deadlockRetryInterval = retryInterval / 10`，初始退避较短
- `deadlockCnt` 逐次递增实现指数退避效果

---

## 四、调用链总结 — 一条 INSERT 语句的完整事务生命周期

```
用户: INSERT INTO acid_table VALUES (1, 'hello');

1. Driver.compile()
   └─▶ SemanticAnalyzer 解析 → 确定需要 SHARED_WRITE 锁

2. Driver.execute()  
   │
   ├─▶ DbTxnManager.openTxn(ctx, user)
   │     ├─▶ Thrift → TxnHandler.openTxns()
   │     │     └─▶ INSERT INTO TXNS (txn_id, txn_state='o', txn_started, txn_last_heartbeat)
   │     └─▶ startHeartbeat() → 创建定时心跳任务
   │
   ├─▶ DbTxnManager.acquireLocks(plan, ctx, username)
   │     ├─▶ 构建 LockRequest: {txnId, [SHARED_WRITE on db.table]}
   │     └─▶ DbLockManager.lock(lockRequest, queryId, isBlocking=true)
   │           └─▶ Thrift → TxnHandler.lock(lockRequest)
   │                 ├─▶ enqueueLockWithRetry()
   │                 │     ├─▶ S4U on TXNS (确保txn仍为OPEN)
   │                 │     ├─▶ 分配 extLockId
   │                 │     ├─▶ INSERT INTO TXN_COMPONENTS
   │                 │     └─▶ INSERT INTO HIVE_LOCKS (state=WAITING)
   │                 └─▶ checkLockWithRetry()
   │                       └─▶ checkLock()
   │                             ├─▶ 获取 CheckLock mutex
   │                             ├─▶ 查询更早的锁
   │                             ├─▶ jumpTable 判断兼容性
   │                             └─▶ acquire() → UPDATE state=ACQUIRED
   │
   ├─▶ [执行 MapReduce/Tez 任务写入数据]
   │
   │   (后台: heartbeat 定时器每 150秒 发送一次心跳)
   │     └─▶ Thrift → TxnHandler.heartbeat()
   │           └─▶ UPDATE TXNS SET txn_last_heartbeat = now WHERE txn_id = ?
   │
   └─▶ DbTxnManager.commitTxn()
         ├─▶ lockMgr.clearLocalLockRecords()
         ├─▶ stopHeartbeat()
         └─▶ Thrift → TxnHandler.commitTxn(txnId)
               ├─▶ S4U on TXNS (确保txn仍为OPEN)
               ├─▶ Write-Write 冲突检测 (检查 WRITE_SET)
               ├─▶ UPDATE TXNS SET txn_state = 'c'
               ├─▶ INSERT INTO COMPLETED_TXN_COMPONENTS
               ├─▶ INSERT INTO WRITE_SET (用于后续 W-W 冲突检测)
               └─▶ DELETE FROM HIVE_LOCKS WHERE hl_txnid = txnId
```

---

## 五、关键参数与调优建议

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|---------|
| `hive.txn.timeout` | 300s | 事务超时时间 | 长查询环境适当增大到 600s-900s |
| `hive.txn.heartbeat.interval` | 自动(timeout/2) | 心跳间隔 | 通常无需修改，保证 < timeout |
| `hive.lock.sleep.between.retries` | 15s | 锁等待重试间隔 | 高并发时可减小到 5s-10s |
| `hive.lock.numretries` | 100 | 锁等待最大重试次数 | 根据 SLA 调整 |
| `hive.support.concurrency` | true | 启用并发支持 | DbTxnManager 必须为 true |
| `hive.txn.manager` | DbTxnManager | 事务管理器 | ACID 表必须使用此实现 |
| `metastore.txn.timeout` | 300s | Metastore 端超时 | 与 hive.txn.timeout 保持一致 |
| `metastore.timedout.txn.reaper.interval` | 60s | 超时清理检查频率 | 通常保持默认 |
| `hive.txn.retryable.sqlex.regex` | (空) | RDBMS 可重试错误正则 | 添加特定DB错误模式 |
| `hive.txn.max.open.batch` | 1000 | 批量打开事务数 | Streaming API 场景调整 |

---

## 六、踩坑记录

### 6.1 事务超时导致查询失败

**现象**: 查询运行数小时后报错 `TxnAbortedException: Transaction txnid:XXX has already been aborted`

**根因**: AcidHouseKeeperService 的 `performTimeOuts()` 在 `txn_last_heartbeat < now - timeout` 时 Abort 事务。如果心跳线程因 GC、网络抖动等原因未能及时发送，事务会被误 Abort。

**源码证据** (TxnHandler.java:4397-4402):
> *With current (RC + multiple txns) implementation it is possible for someone to send heartbeat at the very end of the expire interval, and just after the Select from TXNS is made, in which case heartbeat will succeed but txn will still be Aborted.*

**解决**: 
1. 增大 `hive.txn.timeout` (如 900s)
2. 确保 Metastore RDBMS 响应时间稳定
3. 监控 GC 暂停时间

### 6.2 HIVE_LOCKS 表膨胀

**现象**: SHOW LOCKS 响应极慢，Metastore RDBMS CPU 飙高。

**根因**: 大量 WAITING 状态的锁未被清理。`checkLock()` 每次检查都要扫描 `hl_lock_ext_id < extLockId` 的所有锁，表越大性能越差。

**解决**:
1. 定期检查是否有泄漏的锁: `SELECT * FROM HIVE_LOCKS WHERE hl_acquired_at IS NULL AND hl_last_heartbeat < NOW() - INTERVAL 1 HOUR;`
2. 确保 AcidHouseKeeperService 正常运行
3. 合理设置 `hive.lock.numretries`，避免无限等待

### 6.3 checkLock() 互斥导致的性能瓶颈

**现象**: 高并发场景下锁获取延迟极高。

**根因**: `checkLock()` 使用 `MUTEX_KEY.CheckLock` 全局互斥，同一时间只有一个 checkLock 在执行。这是为了防止两个冲突锁被并行授予。

**源码证据** (TxnHandler.java:3690-3693):
```java
// checkLock() must be mutex'd against any other checkLock to make sure 
// 2 conflicting locks are not granted by parallel checkLock() calls.
handle = getMutexAPI().acquireLock(MUTEX_KEY.CheckLock.name());
```

**缓解**: 减少每个查询请求的锁组件数（减少分区粒度锁），使用分区裁剪减少锁范围。

---

## 七、相关 RDBMS 表结构

```sql
-- 事务表
TXNS (txn_id, txn_state, txn_started, txn_last_heartbeat, txn_user, txn_host, txn_type)

-- 锁表  
HIVE_LOCKS (hl_lock_ext_id, hl_lock_int_id, hl_txnid, hl_db, hl_table, hl_partition,
            hl_lock_state, hl_lock_type, hl_last_heartbeat, hl_acquired_at,
            hl_user, hl_host, hl_agent_info, hl_blockedby_ext_id, hl_blockedby_int_id)

-- 事务组件
TXN_COMPONENTS (tc_txnid, tc_database, tc_table, tc_partition, tc_operation_type, tc_writeid)

-- 写集合 (用于 W-W 冲突检测)
WRITE_SET (ws_database, ws_table, ws_partition, ws_txnid, ws_commit_id, ws_operation_type)

-- ID 生成器
NEXT_TXN_ID (ntxn_next)
NEXT_LOCK_ID (nl_next)
```

---

## 八、总结

Hive 的事务和锁机制采用了 **基于 RDBMS 的集中式锁管理** 方案：

1. **两阶段锁获取**: 先入队(WAITING) → 再检查兼容性(checkLock) → 获取(ACQUIRED)
2. **FIFO 公平调度**: 只与 extLockId 更小的锁比较，天然无死锁
3. **心跳续期**: 客户端定时发送心跳，服务端 HouseKeeper 定时清理超时事务
4. **First-Committer-Wins**: 通过 WRITE_SET 在 commit 时检测 Write-Write 冲突
5. **RDBMS 死锁重试**: 递归调用 + 指数退避处理底层数据库死锁

这套设计在中等并发场景下工作良好，但 checkLock 的全局互斥是高并发场景的主要瓶颈。
