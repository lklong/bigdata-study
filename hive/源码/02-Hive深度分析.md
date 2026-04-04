# Hive 源码级深度手册（打样：Compaction + MetaStore + Lock 三个模块）

> 版本：v3.0 | 标准：代码级深入，小到方法 | 目标：知其然更知其所以然

---

# 模块一：ACID Compaction 系统（源码级）

## 1.1 为什么需要 Compaction

每次对 ACID 表做 INSERT/UPDATE/DELETE，Hive 不会修改原始文件，而是写一个增量文件：

```
table_dir/
  ├── base_0000001/              ← Major Compaction 的产物（全量快照）
  │     └── bucket_00000         ← ORC 文件
  ├── delta_0000002_0000002/     ← 一次 INSERT 产生的增量
  │     └── bucket_00000
  ├── delta_0000003_0000003/     ← 又一次 INSERT
  ├── delete_delta_0000004/      ← 一次 DELETE 产生的删除标记
  └── delta_0000005_0000005/     ← 又一次 INSERT
```

**查询时**，ORC Reader 需要：
1. 读 base 文件
2. 按 ZXID 顺序 merge 所有 delta
3. 过滤掉 delete_delta 标记的行

**delta 越多 → merge 开销越大 → 查询越慢。** Compaction 就是把多个 delta 合并。

---

## 1.2 Compaction 三线程架构（源码级）

Compaction 系统由 **3 个后台线程** 组成，运行在 **HMS 进程内**：

```
MetaStore 进程
  │
  ├── Initiator 线程（发起器）
  │     ↓ 扫描 → 发现需要 compaction 的分区
  │     ↓ 写入 COMPACTION_QUEUE 表（状态=INITIATED）
  │
  ├── Worker 线程 × N（工作器）
  │     ↓ 轮询 COMPACTION_QUEUE（状态=INITIATED）
  │     ↓ 锁定任务（状态→WORKING）
  │     ↓ 执行文件合并（提交 MR/Tez 任务）
  │     ↓ 完成后更新状态（→SUCCEEDED 或 FAILED）
  │
  └── Cleaner 线程（清理器）
        ↓ 扫描已完成的 compaction
        ↓ 删除旧的 delta 文件
        ↓ 清理 COMPACTION_QUEUE 历史记录
```

### 源码文件路径

```
ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/
├── CompactorThread.java              ← 抽象基类：生命周期管理
├── Initiator.java                     ← 发起器：发现候选分区
├── Worker.java                        ← 工作器：执行合并
├── Cleaner.java                       ← 清理器：删除旧文件
├── MajorCompactionTask.java           ← Major 合并逻辑
└── MinorCompactionTask.java           ← Minor 合并逻辑

standalone-metastore/metastore-server/src/main/java/org/apache/hadoop/hive/metastore/txn/
├── TxnHandler.java                    ← 事务管理基类
└── CompactionTxnHandler.java          ← Compaction 专用事务操作
```

---

## 1.3 Initiator（发起器）源码深入

### 类继承关系

```java
CompactorThread (abstract)               // 基类：线程生命周期
  └── MetaStoreCompactorThread           // HMS 进程内运行
       └── Initiator                     // 发起器
```

### 核心方法：`run()` 主循环

```java
// Initiator.java 简化逻辑
@Override
public void run() {
  while (!stop.get()) {
    try {
      // 1. 获取互斥锁（确保只有一个 Initiator 活跃）
      //    多 HMS 实例时通过 METASTORE_HOUSEKEEPING_LEADER_HOSTNAME 控制
      if (!acquireMutex()) {
        continue;
      }

      // 2. 从 CompactionTxnHandler 获取候选分区
      //    SQL: SELECT DISTINCT tc_database, tc_table, tc_partition
      //         FROM COMPLETED_TXN_COMPONENTS
      //    含义：最近有过写入操作（INSERT/UPDATE/DELETE）的分区
      Set<CompactionInfo> potentials = txnHandler.findPotentialCompactions(abortedThreshold);

      // 3. 对每个候选分区，评估是否需要 compaction
      for (CompactionInfo ci : potentials) {
        CompactionResponse response = scheduleCompactionIfNeeded(ci);
      }
    } finally {
      releaseMutex();
    }
    // 4. 休眠后继续下一轮
    Thread.sleep(checkInterval);  // 默认 300s (hive.compactor.check.interval)
  }
}
```

### 关键方法：`scheduleCompactionIfNeeded()` —— 决策逻辑

```java
// 判断一个分区是否需要 compaction，以及用 Major 还是 Minor
private CompactionResponse scheduleCompactionIfNeeded(CompactionInfo ci) {
  
  // 获取该分区的 HDFS 目录结构
  AcidUtils.Directory dir = AcidUtils.getAcidState(path, conf, ...);
  
  // ====== 判断条件 1：Delta 文件数量 ======
  int numDeltas = dir.getCurrentDirectories().size();
  if (numDeltas > hive.compactor.delta.num.threshold) {
    // 默认阈值 = 10 (MetastoreConf.COMPACTOR_DELTA_NUM_THRESHOLD)
    // 触发 Minor Compaction
    return requestCompaction(ci, CompactionType.MINOR);
  }
  
  // ====== 判断条件 2：Delta 总大小 / Base 大小 ======
  long baseSize = dir.getBaseDirectory() != null ? getDirectorySize(dir.getBaseDirectory()) : 0;
  long deltaSize = sumDirectorySizes(dir.getCurrentDirectories());
  if (baseSize > 0 && (double)deltaSize / baseSize > hive.compactor.delta.pct.threshold) {
    // 默认阈值 = 0.1 即 10% (MetastoreConf.COMPACTOR_DELTA_PCT_THRESHOLD)
    // 触发 Major Compaction
    return requestCompaction(ci, CompactionType.MAJOR);
  }
  
  // ====== 判断条件 3：存在中止的事务 ======
  if (dir.hasAbortedDirectories()) {
    // 有中止的事务产生的 delta → 需要清理
    return requestCompaction(ci, CompactionType.MINOR);
  }
  
  // ====== 判断条件 4：距离上次 compaction 超过阈值 ======
  if (timeSinceLastCompaction > compactorTimeThreshold) {
    return requestCompaction(ci, CompactionType.MAJOR);
  }
  
  return null; // 不需要 compaction
}
```

### 为什么 Initiator 用互斥锁？

```
场景：HMS 多实例部署（HA）
如果没有互斥锁 → 两个 Initiator 同时扫描 → 同一个分区被发起两次 compaction → 资源浪费

实现方式：
- 配置 metastore.housekeeping.leader.hostname 指定某个 HMS 实例
- 或通过 DB 表锁实现分布式互斥
```

---

## 1.4 Worker（工作器）源码深入

### 核心方法：`run()` 主循环

```java
// Worker.java 简化逻辑
@Override
public void run() {
  while (!stop.get()) {
    // 1. 从队列中获取下一个任务
    //    SQL: SELECT * FROM COMPACTION_QUEUE WHERE CQ_STATE = 'i'
    //         ORDER BY CQ_ID LIMIT 1
    //    然后 UPDATE SET CQ_STATE = 'w', CQ_WORKER_ID = <this_worker>
    CompactionInfo ci = txnHandler.findNextToCompact(workerId);
    
    if (ci == null) {
      Thread.sleep(pollInterval);  // 没有任务就等
      continue;
    }
    
    try {
      // 2. 开启一个内部事务（用于 compaction 读取一致性）
      long compactorTxnId = txnHandler.openTxn("compactor_" + ci.id);
      
      // 3. 启动心跳线程（防止长时间运行被当成死事务）
      //    心跳间隔 = hive.txn.timeout / 2
      heartbeatThread.start(compactorTxnId);
      
      // 4. 根据类型选择任务
      CompactionTask task;
      if (ci.type == CompactionType.MAJOR) {
        task = new MajorCompactionTask();
      } else {
        task = new MinorCompactionTask();
      }
      
      // 5. 执行合并
      //    内部：提交一个 MR/Tez 作业，读取所有 delta + base，写出新文件
      task.execute(conf, ci, txnHandler);
      
      // 6. 标记成功
      txnHandler.markCompacted(ci);  // CQ_STATE = 'r' (ready for cleaning)
      txnHandler.commitTxn(compactorTxnId);
      
    } catch (Exception e) {
      // 7. 标记失败
      txnHandler.markFailed(ci);     // CQ_STATE = 'f'
      LOG.error("Compaction failed for " + ci, e);
    } finally {
      heartbeatThread.stop();
    }
  }
}
```

### MajorCompactionTask vs MinorCompactionTask

```java
// MajorCompactionTask.execute() 简化逻辑
void execute() {
  // 读取：base + 所有 delta + 所有 delete_delta
  // 写出：一个新的 base 目录
  // 效果：所有历史都合并成一个快照
  
  // 伪代码：
  OrcReader baseReader = open(baseDir);
  List<OrcReader> deltaReaders = openAll(deltaDirectories);
  OrcWriter newBaseWriter = create(newBaseDir);
  
  // 三路归并：base + insert_deltas - delete_deltas
  while (hasNext(baseReader, deltaReaders)) {
    Row row = mergeNext();
    if (!isDeleted(row)) {
      newBaseWriter.write(row);
    }
  }
}

// MinorCompactionTask.execute() 简化逻辑
void execute() {
  // 读取：只读取 delta 文件（不碰 base）
  // 写出：一个新的合并后的 delta 目录
  // 效果：N 个 delta → 1 个 delta，base 不变
  
  List<OrcReader> deltaReaders = openAll(deltaDirectories);
  OrcWriter mergedDelta = create(mergedDeltaDir);
  
  while (hasNext(deltaReaders)) {
    mergedDelta.write(mergeNext());
  }
}
```

### 为什么 Worker 需要心跳？

```
问题：Major Compaction 可能跑几个小时（重写 TB 级数据）
TxnHandler 有事务超时机制：hive.txn.timeout = 600s
如果 compaction 事务超过 600s 没有心跳 → 被当作死事务 → 被 abort → compaction 失败

解决：Worker 启动一个心跳线程，每 hive.txn.timeout/2 秒发一次心跳
心跳方法：txnHandler.heartbeat(txnId, lockId)
内部 SQL：UPDATE TXNS SET TXN_LAST_HEARTBEAT = current_timestamp WHERE TXN_ID = ?
```

---

## 1.5 CompactionTxnHandler 关键方法速查

| 方法 | SQL 操作 | 调用方 | 含义 |
|------|----------|--------|------|
| `findPotentialCompactions()` | `SELECT FROM COMPLETED_TXN_COMPONENTS` | Initiator | 找最近有写入的分区 |
| `compact(CompactionInfo)` | `INSERT INTO COMPACTION_QUEUE` | Initiator | 创建 compaction 任务 |
| `findNextToCompact(workerId)` | `SELECT + UPDATE COMPACTION_QUEUE` | Worker | 领取任务（原子操作） |
| `markCompacted(ci)` | `UPDATE CQ_STATE='r'` | Worker | 标记完成待清理 |
| `markFailed(ci)` | `UPDATE CQ_STATE='f'` | Worker | 标记失败 |
| `markCleaned(ci)` | `DELETE FROM COMPACTION_QUEUE` | Cleaner | 清理完成 |
| `purgeCompactionHistory()` | `DELETE WHERE age > retention` | Cleaner | 清理历史记录 |

### Compaction 状态机

```
INITIATED (i) → WORKING (w) → SUCCEEDED/READY_FOR_CLEANING (r) → CLEANED (删除)
                     ↓
                 FAILED (f) → 可手动重试
```

---

## 1.6 Compaction 排障：源码级定位

### 问题 1：Compaction 一直处于 INITIATED 不执行

```
源码定位：Worker.findNextToCompact() 返回 null

可能原因：
1. Worker 线程数为 0 → hive.compactor.worker.threads 默认值在 Hive 4.x 是 5
   但老版本默认是 0！（Hive 2.x）
   
   验证：SET hive.compactor.worker.threads;
   
2. Worker 挑了其他任务 → 如果有多个 compaction，Worker 按 CQ_ID 顺序取
   大的 Major Compaction 会阻塞后面的任务

3. HMS Initiator 和 Worker 不在同一个实例
   如果配了 METASTORE_HOUSEKEEPING_LEADER_HOSTNAME 只指向一个 HMS
   但 Worker 可以在所有 HMS 实例上运行
   检查：是否所有 HMS 实例都启用了 compactor worker
```

### 问题 2：Compaction 频繁 FAILED

```
源码定位：Worker.execute() 抛出异常 → markFailed()

排查路径：
1. HMS 日志搜索：grep "Compaction failed" hive-metastore-*.log
2. 看异常栈：
   - OOM → compaction 读取太多数据，内存不够
     解决：调大 compaction MR/Tez 任务的内存
     hive.compactor.job.queue = compaction_queue  （专用队列）
     
   - FileNotFoundException → delta 文件被其他进程删了
     可能原因：手动清理了 HDFS 上的文件
     
   - LockException → 获取不到 compaction 所需的锁
     可能原因：有长时间运行的查询锁住了分区
```

---

# 模块二：MetaStore 请求链路（源码级）

## 2.1 一个 getTable() 请求的完整链路

```
客户端 (Beeline/Spark)
  │
  │ 1. ThriftHiveMetastore.Client.getTable(dbName, tableName)
  │    Thrift RPC 序列化 → TCP 发送到 HMS 端口 9083
  │
  ▼
HMS 进程 (ThriftServer)
  │
  │ 2. ThriftHiveMetastore.Processor.process()
  │    反序列化请求 → 路由到 HMSHandler
  │
  ▼
HMSHandler.getTable(dbName, tableName)              [入口方法]
  │
  │ 3. 权限检查（如果开启了 Ranger/Sentry）
  │
  ▼
HMSHandler.get_table_core(dbName, tableName)
  │
  │ 4. 调用 RawStore 接口
  │
  ▼
ObjectStore.getTable(catName, dbName, tableName)     [ORM 层]
  │
  │ 5. 方案 A：JDO/DataNucleus ORM 查询
  │    pm.getObjectById(MTable.class, key)
  │    → JDO 生成 SQL：
  │      SELECT t.*, s.*, sd.*
  │      FROM TBLS t
  │      JOIN SDS s ON t.SD_ID = s.SD_ID
  │      JOIN DBS d ON t.DB_ID = d.DB_ID
  │      LEFT JOIN SERDES sd ON s.SERDE_ID = sd.SERDE_ID
  │      LEFT JOIN TABLE_PARAMS tp ON t.TBL_ID = tp.TBL_ID
  │      WHERE d.NAME = ? AND t.TBL_NAME = ?
  │    → 多表 JOIN！表多/分区多时 MySQL 压力大
  │
  │ 5. 方案 B：DirectSQL 优化路径
  │    MetaStoreDirectSql.getTable(catName, dbName, tableName)
  │    → 拆成多个单表查询 + 内存组装
  │    → 减轻 MySQL JOIN 压力
  │
  ▼
返回 Table 对象 → Thrift 序列化 → 返回客户端
```

### 为什么 DirectSQL 更快？

```
ORM 路径：一条复杂 SQL（5+ 表 JOIN）→ MySQL 执行器压力大
DirectSQL：5 条简单 SQL（各查一张表）→ 应用层内存 JOIN

示例：getPartitions 查 10000 个分区
- ORM：SELECT ... FROM PARTITIONS JOIN SDS JOIN SERDES JOIN ... WHERE TBL_ID = ?
  MySQL 需要在磁盘上做大 JOIN → 慢
- DirectSQL：
  ① SELECT * FROM PARTITIONS WHERE TBL_ID = ?
  ② SELECT * FROM SDS WHERE SD_ID IN (...)
  ③ SELECT * FROM PARTITION_KEY_VALS WHERE PART_ID IN (...)
  应用层 HashMap 组装 → 快

配置：
hive.metastore.try.direct.sql = true          ← 默认开启
hive.metastore.try.direct.sql.ddl = true      ← DDL 操作也用 DirectSQL
```

### getPartitions() 性能瓶颈定位

```
场景：Spark 读取一张分区表，有 50000 个分区
Spark 调用 HMS.getPartitionsByFilter() 获取分区列表

源码链路：
HMSHandler.getPartitionsByFilter()
  → ObjectStore.getPartitionsByFilter()
    → MetaStoreDirectSql.getPartitionsViaSqlFilter()
      → 构建 SQL：SELECT PART_ID FROM PARTITIONS WHERE TBL_ID = ? AND <filter>
      → 批量获取分区详情（每批 1000 个）

如果 50000 个分区 → 50 批 → 50 次 DB 查询
每次查询 ~100ms → 总计 5 秒

优化手段：
1. hive.metastore.batch.retrieve.max = 1000  ← 调大批次
2. MySQL 端 PARTITIONS 表加索引：INDEX(TBL_ID, PART_NAME)
3. 使用 partition pruning 减少返回的分区数
```

---

# 模块三：锁管理系统（源码级）

## 3.1 锁的获取流程

```
SQL 执行入口
  │
  ▼
Driver.compile(sql)                          ← 编译 SQL
  │
  ▼
Driver.acquireLocks()                        ← 获取锁
  │
  ▼
DbTxnManager.acquireLocks(plan, ctx, user)   ← 事务管理器
```

### DbTxnManager.acquireLocks() 关键步骤

```java
// 简化后的核心逻辑
public LockState acquireLocks(QueryPlan plan, Context ctx, String user) {
  
  // 步骤 1：验证事务状态
  verifyState(plan);
  // - 检查是否在显式事务中执行了不允许的操作
  // - 防止嵌套事务
  
  // 步骤 2：根据 SQL 的输入/输出确定需要的锁
  List<LockComponent> components = AcidUtils.makeLockComponents(
    plan.getInputs(),   // SELECT 读的表 → SHARED_READ
    plan.getOutputs(),  // INSERT/UPDATE 写的表 → SHARED_WRITE 或 EXCLUSIVE
    operationType,
    conf
  );
  // 输入表 → SHARED_READ（读锁）
  // 输出表（INSERT）→ SHARED_WRITE（写锁，不阻塞读）
  // 输出表（INSERT OVERWRITE）→ EXCLUSIVE（排他锁，阻塞一切）
  
  // 步骤 3：构建锁请求
  LockRequest lockRqst = new LockRequestBuilder()
    .setTransactionId(txnId)
    .setUser(username)
    .addLockComponents(components)
    .build();
  
  // 步骤 4：发送给 HMS 加锁
  // RPC: ThriftHiveMetastore.Client.lock(lockRqst)
  LockResponse response = lockMgr.lock(lockRqst);
  
  // 步骤 5：检查结果
  // response.state = ACQUIRED → 成功获取
  // response.state = WAITING  → 需要等待（有人持有冲突锁）
  // response.state = NOT_ACQUIRED → 获取失败
  
  // 步骤 6：如果 WAITING → 循环 checkLock 直到获取或超时
  while (response.state == WAITING) {
    Thread.sleep(retryInterval);  // hive.lock.sleep.between.retries = 10s
    response = txnHandler.checkLock(lockId);
    retryCount++;
    if (retryCount > maxRetries) {  // hive.lock.numretries = 100
      throw new LockException("锁等待超时");
    }
  }
  
  // 步骤 7：获取到锁后启动心跳
  startHeartbeat(txnId, lockId);
  // 心跳间隔 = hive.txn.timeout / 2
  // 心跳 SQL：UPDATE TXNS SET TXN_LAST_HEARTBEAT = now() WHERE TXN_ID = ?
  //           UPDATE HIVE_LOCKS SET HL_LAST_HEARTBEAT = now() WHERE HL_LOCK_EXT_ID = ?
  
  return response.state;
}
```

### 锁冲突矩阵（HMS 端 checkLock 使用）

```
请求\已有     SHARED_READ    SHARED_WRITE    EXCLUSIVE
SHARED_READ      ✅ 兼容        ✅ 兼容         ❌ 冲突
SHARED_WRITE     ✅ 兼容        ✅ 兼容         ❌ 冲突
EXCLUSIVE        ❌ 冲突        ❌ 冲突         ❌ 冲突
```

**核心代码**：`TxnHandler.checkLock()` 方法中

```java
// checkLock() 简化逻辑
// SQL: 查询 HIVE_LOCKS 表中和当前请求冲突的锁
SELECT * FROM HIVE_LOCKS 
WHERE HL_DB = ? AND HL_TABLE = ? 
  AND HL_LOCK_EXT_ID != ?          -- 排除自己
  AND HL_LOCK_STATE = 'a'          -- 只看已获取的锁
ORDER BY HL_LOCK_INT_ID;

// 遍历每一把已有的锁，检查是否和请求冲突
for (HiveLock existingLock : existingLocks) {
  if (conflicts(existingLock.type, requestedLock.type)) {
    return WAITING;  // 有冲突，等待
  }
}
return ACQUIRED;  // 无冲突，授予锁
```

## 3.2 锁等待排障：源码级定位

### 为什么我的 SQL 卡在锁等待？

```
步骤 1：SHOW LOCKS → 看谁持有锁

步骤 2：找到锁持有者的事务
SHOW TRANSACTIONS → State=OPEN 的事务

步骤 3：判断根因
- 如果持有者是一个长查询（SELECT）→ SHARED_READ 锁
  你的 INSERT OVERWRITE 需要 EXCLUSIVE → 被 SELECT 阻塞
  解决：等 SELECT 完成，或用 INSERT INTO + 分区覆盖代替 INSERT OVERWRITE

- 如果持有者是调度系统的另一个任务
  解决：调度系统加任务依赖，避免并发写同一张表

- 如果持有者的事务心跳停了（进程已死但事务未清理）
  源码：TxnHandler 中有 reaper 线程
  hive.txn.timeout = 600s → 超过 600s 无心跳的事务被自动 abort
  解决：等 600s 或手动 ABORT TRANSACTIONS <txn_id>

步骤 4：如果 reaper 没生效
  检查 HMS 日志：grep "AcidHouseKeeperService" metastore.log
  这个线程负责清理超时事务和锁
  如果这个线程挂了 → 重启 HMS
```

---

# 附录：源码阅读入口索引

| 你想了解 | 从这个类/方法入手 | 文件路径 |
|---------|-------------------|---------|
| SQL 编译全流程 | `Driver.compileInternal()` | `ql/src/java/org/apache/hadoop/hive/ql/Driver.java` |
| 语义分析 | `SemanticAnalyzer.analyzeInternal()` | `ql/src/java/org/apache/hadoop/hive/ql/parse/SemanticAnalyzer.java` |
| CBO 优化 | `CalcitePlanner.logicalPlan()` | `ql/src/java/org/apache/hadoop/hive/ql/parse/CalcitePlanner.java` |
| Tez 任务提交 | `TezTask.execute()` | `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezTask.java` |
| MetaStore 入口 | `HMSHandler` (实现 `ThriftHiveMetastore.Iface`) | `standalone-metastore/metastore-server/...HiveMetaStore.java` |
| ORM 存储 | `ObjectStore` (实现 `RawStore`) | `standalone-metastore/metastore-server/...ObjectStore.java` |
| DirectSQL | `MetaStoreDirectSql` | `standalone-metastore/metastore-server/...MetaStoreDirectSql.java` |
| 事务管理 | `DbTxnManager.acquireLocks()` | `ql/.../lockmgr/DbTxnManager.java` |
| 锁检查 | `TxnHandler.checkLock()` | `standalone-metastore/.../txn/TxnHandler.java` |
| Compaction 发起 | `Initiator.run()` | `ql/.../txn/compactor/Initiator.java` |
| Compaction 执行 | `Worker.run()` | `ql/.../txn/compactor/Worker.java` |
| Compaction 清理 | `Cleaner.run()` | `ql/.../txn/compactor/Cleaner.java` |
| ORC 读取 | `OrcInputFormat.getSplits()` | `ql/.../io/orc/OrcInputFormat.java` |
| ACID 文件合并 | `AcidUtils.getAcidState()` | `ql/.../io/AcidUtils.java` |
