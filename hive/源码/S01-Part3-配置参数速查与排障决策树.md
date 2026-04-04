# S01: 一条 SQL 从提交到返回结果的完整链路 — Part 3

## 8. 配置参数速查表

### 8.1 连接与会话层

| 参数 | 默认值 | 代码读取位置 | 作用 | 什么时候改 |
|------|--------|------------|------|-----------|
| `hive.server2.thrift.port` | `10000` | HiveConf.java:4091 | HS2 Thrift 端口 | 端口冲突 |
| `hive.server2.async.exec.threads` | `100` | SessionManager | 异步执行线程池大小 | 并发查询多时扩大 |
| `hive.server2.async.exec.wait.queue.size` | `100` | SessionManager | 异步执行等待队列 | 配合线程池 |
| `hive.server2.async.exec.async.compile` | `false` | SQLOperation.java:265 | 异步模式下是否异步编译 | 开启可减少 Thrift 线程占用 |
| `hive.server2.session.check.interval` | `6h` | SessionManager | Session 超时检查间隔 | Session 泄漏时缩短 |

### 8.2 编译层

| 参数 | 默认值 | 代码读取位置 | 作用 | 什么时候改 |
|------|--------|------------|------|-----------|
| `hive.server2.compile.lock.timeout` | `0`(无限等) | CompileLockFactory | 编译锁等待超时(秒) | 编译排队严重时设置上限 |
| `hive.cbo.enabled` | `true` | SemanticAnalyzerFactory.java:124 | 是否启用 Calcite CBO | CBO 有 bug 时可关闭 |
| `hive.cbo.fallback.strategy` | `CONSERVATIVE` | CalcitePlanner.java:467 | CBO 降级策略 | CBO 失败频繁时调整 |
| `hive.query.timeout.seconds` | `0`(无限) | SQLOperation.java:121 | 查询超时(秒) | 防止慢查询占资源 |

### 8.3 MetaStore 交互

| 参数 | 默认值 | 代码读取位置 | 作用 | 什么时候改 |
|------|--------|------------|------|-----------|
| `hive.metastore.client.connect.retry.delay` | `1s` | HiveConf.java:896 (Deprecated) | HMS 重连间隔 | HMS 不稳定时 |
| `hive.metastore.uris` | - | MetaStoreClient | HMS 地址列表 | 多 HMS 实例 HA |
| `hive.metastore.client.socket.timeout` | `600s` | MetaStoreClient | HMS Thrift 超时 | HMS 响应慢时 |

### 8.4 事务与锁

| 参数 | 默认值 | 代码读取位置 | 作用 | 什么时候改 |
|------|--------|------------|------|-----------|
| `hive.txn.manager` | `DbTxnManager` | SessionState | 事务管理器类 | 几乎不改 |
| `hive.txn.max.retrysnapshot.count` | `5` | Driver.java:231 | 快照失效最大重试次数 | 高并发写入时可调大 |
| `hive.lock.numretries` | `100` | DbLockManager | 锁重试次数 | 锁竞争严重时 |
| `hive.lock.sleep.between.retries` | `60s` | DbLockManager | 锁重试间隔 | 配合 numretries |

### 8.5 执行层 (Tez)

| 参数 | 默认值 | 代码读取位置 | 作用 | 什么时候改 |
|------|--------|------------|------|-----------|
| `hive.execution.engine` | `tez` | HiveConf.java:4503 | 执行引擎 | MR 已废弃，不要改 |
| `hive.exec.parallel` | `false` | HiveConf.java:657 | 并行执行无依赖的 Stage | 多 Stage 查询可开启 |
| `hive.exec.parallel.thread.number` | `8` | HiveConf.java:658 | 并行执行最大线程数 | 配合 exec.parallel |
| `tez.queue.name` | - | TezTask | YARN 队列名 | 多租户隔离 |

### 8.6 结果返回

| 参数 | 默认值 | 代码读取位置 | 作用 | 什么时候改 |
|------|--------|------------|------|-----------|
| `hive.server2.thrift.resultset.max.fetch.size` | `1000` | HS2 | 单次 fetch 最大行数 | 大结果集调大 |
| `hive.fetch.task.conversion` | `more` | SemanticAnalyzer | 简单查询直接 fetch 不走 MR/Tez | 保持 more |

---

## 9. 排障决策树（完整版）

```
用户反馈: "Beeline 查询卡住/慢/报错"
│
├─ 1. Beeline 能连上 HS2 吗？
│   ├─ 不能 → 检查 HS2 进程: ps aux | grep HiveServer2
│   │   ├─ 进程不在 → 查 HS2 日志最后的异常，重启
│   │   └─ 进程在 → 检查端口: netstat -tlnp | grep 10000
│   │       ├─ 端口不通 → 防火墙 / HS2 还在启动
│   │       └─ 端口通 → Thrift 线程池满 → 检查活跃连接数
│   └─ 能连上 →
│
├─ 2. 查 HS2 日志中的 "executing <SQL>" (日志点①)
│   ├─ 没有 → 请求没到 HS2 → 检查客户端/网络/ZK (HA模式)
│   └─ 有 →
│
├─ 3. 查 "Compiling command(queryId=xxx)" (日志点②)
│   ├─ 没有 → 卡在编译锁
│   │   └─ 查 "Compile lock timed out" → hive.server2.compile.lock.timeout
│   │      另一个查询正在编译 → 等待或 kill 那个查询
│   └─ 有 →
│
├─ 4. 查 "Semantic Analysis Completed" (日志点③)
│   ├─ 没有 → 卡在语义分析
│   │   ├─ 查 "Table not found" → 表名错误 / HMS 不可达
│   │   ├─ 查 "MetaException" → HMS 后端 DB 问题
│   │   │   └─ 检查 HMS: ps aux | grep HiveMetaStore
│   │   │      检查 MySQL: SHOW PROCESSLIST
│   │   └─ 查 "Plan not optimized by CBO" → CBO 问题,不影响正确性
│   └─ 有 →
│
├─ 5. 查 "Query ID: [xxx], Dag ID: [xxx]" (日志点④)
│   ├─ 没有 → 卡在锁获取或快照验证
│   │   ├─ 查 "Re-compiling after acquiring locks" → 快照失效重编译
│   │   ├─ SHOW LOCKS → 查看锁等待
│   │   └─ SHOW TRANSACTIONS → 查看事务状态
│   └─ 有 →
│
├─ 6. DAG 提交了但未完成
│   ├─ 查 YARN UI → Application 状态
│   │   ├─ ACCEPTED → YARN 资源不足 → yarn queue -status
│   │   ├─ RUNNING → 查 Tez UI → 找慢 Task
│   │   │   ├─ 某个 Task 特别慢 → 数据倾斜 → 查 Shuffle Read 分布
│   │   │   ├─ 所有 Task 都慢 → 资源不足 / 数据量太大
│   │   │   └─ Task 失败 → 查 Container 日志: yarn logs -applicationId <appId>
│   │   │       ├─ OOM → 加 executor memory / memoryOverhead
│   │   │       ├─ 磁盘满 → 清理 / 加磁盘
│   │   │       └─ UDF 异常 → 查用户代码
│   │   └─ FAILED → 查 diagnostics
│   └─ 完成但结果慢 → FetchTask 拉取慢 → 结果集太大
│
└─ 7. 查询报错
    ├─ ParseException → SQL 语法错误 → 检查 SQL
    ├─ SemanticException → 表/列/类型错误
    ├─ AuthorizationException → Ranger 权限不足
    ├─ LockException → 锁超时
    ├─ TezRuntimeException → Tez 执行失败
    └─ OutOfMemoryError → JVM 内存不足
```

---

## 10. 已知 Bug 索引

| JIRA | 版本 | 描述 | 根因代码位置 | 影响 |
|------|------|------|------------|------|
| HIVE-27791 | 4.0.0 | Kyuubi 通过 HS2 提交查询时 Session 泄漏 | HiveSessionImpl.executeStatementInternal() | 异步模式下锁释放不正确 |
| HIVE-27213 | 3.1.x | CBO 降级导致查询结果错误 | CalcitePlanner | CBO 某些场景降级后行为不一致 |
| HIVE-26379 | 3.1.x | 编译锁在异常时不释放 | Driver.compileInternal() | 后续查询永远等锁 |

---

## 11. 线程模型总结

```
Thrift Worker Thread (hive.server2.thrift.min/max.worker.threads)
  │
  ├─ 同步模式: 全程在此线程完成（编译 + 执行 + 结果返回）
  │
  └─ 异步模式:
       ├─ 当前线程: 创建 Operation + 可能同步编译 → 返回 OperationHandle
       └─ Background Thread (hive.server2.async.exec.threads):
            编译(如果 async.compile=true) + 执行 + 状态更新
            ├─ 内部: Tez AM 线程管理 DAG 执行
            └─ 完成后: OperationState → FINISHED / ERROR
```

---

## 12. SessionState vs QueryState 层次关系

```
SessionState (会话级，1 个 Beeline 连接 = 1 个)
├── sessionConf (HiveConf)
├── userName, currentDatabase
├── tezSessionState (Tez AM 连接)
├── txnMgr (事务管理器)
├── tempTables (临时表)
├── compileLock (ReentrantLock, 公平锁)
└── queryStateMap: Map<queryId, QueryState>
     │
     └── QueryState (查询级，1 条 SQL = 1 个)
         ├── queryConf (HiveConf 克隆，隔离)
         ├── commandType (SELECT/INSERT/DDL)
         ├── lineageState (血缘)
         ├── txnManager (查询的事务)
         ├── hmsCache (HMS 请求缓存)
         └── resolveConditionalTaskLock
```

**为什么隔离**: 同一个 Session 可以并发多个查询（异步模式），QueryState 独立 HiveConf 防止互相干扰。Builder 模式创建时 `new HiveConf(hiveConf)` 做深拷贝。
