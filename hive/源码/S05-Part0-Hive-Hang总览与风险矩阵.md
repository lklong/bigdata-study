# Hive 卡住问题（Hang/Block）源码级全面分析 — 总览

> 分析时间：2026-04-04 | 分析对象：Apache Hive 源码 | 分析人：豹纹 (BigData Ops Orchestrator)

---

## 一、问题概述

Hive（HiveServer2 / Hive Metastore）在生产环境中频繁出现"卡住"现象，表现为查询无响应、beeline 挂起、编译超时等。经过对源码的系统性分析，共发现 **10 大类卡住场景**，涉及 **50+ 个具体阻塞点**。

### 核心结论

| 维度 | 结果 |
|------|------|
| 发现卡住类别 | 10 大类 |
| 具体阻塞点 | 50+ 处 |
| 最高风险点 | 编译锁无限等待（默认配置） |
| 最常见场景 | listStatus 无超时 + Metastore RPC 阻塞 |
| 涉及模块 | ql、service、standalone-metastore、llap-server、iceberg-catalog |

---

## 二、风险等级矩阵

| 风险等级 | 场景 | 触发条件 | 影响范围 | 默认配置是否触发 | 详细文档 |
|:--------:|------|----------|----------|:----------------:|----------|
| 🔴 **P0** | **编译锁无限等待** | 并行编译关闭(默认) + timeout=0(默认) | 所有查询阻塞 | **是** | [02-compile-lock-hang.md](02-compile-lock-hang.md) |
| 🔴 **P0** | **Tez Session 池饥饿** | Session 池为空 + AM 启动失败 | 所有新查询阻塞 | 条件触发 | [04-tez-session-pool-hang.md](04-tez-session-pool-hang.md) |
| 🔴 **P0** | **DPP queue.take() 永久阻塞** | Source Vertex 失败无信号 | 单查询永久挂起 | 条件触发 | [05-dpp-hang.md](05-dpp-hang.md) |
| 🟡 **P1** | **listStatus/globStatus 无超时** | NN 高负载/不可达/大量小文件 | 当前线程阻塞 | 条件触发 | [01-list-files-hang.md](01-list-files-hang.md) |
| 🟡 **P1** | **getMSC() synchronized** | Metastore 不可用/创建慢 | 同 Hive 实例所有操作 | 条件触发 | [03-metastore-client-hang.md](03-metastore-client-hang.md) |
| 🟡 **P1** | **DbLockManager 锁等待** | 并发 ACID 事务多/锁竞争 | 当前查询长时间等待 | 条件触发 | [06-txn-lock-hang.md](06-txn-lock-hang.md) |
| 🟡 **P1** | **HiveSession operationLock** | 同 session 慢查询未结束 | 同 session 其他操作 | 配置相关 | [07-session-lock-hang.md](07-session-lock-hang.md) |
| 🟢 **P2** | **SharedCache 读写锁竞争** | 缓存预热/大量写操作 | Metastore 读请求阻塞 | 条件触发 | [08-cache-lock-hang.md](08-cache-lock-hang.md) |
| 🟢 **P2** | **LLAP TaskExecutorService** | 调度锁竞争/任务抢占 | LLAP 任务调度延迟 | 条件触发 | [09-llap-hang.md](09-llap-hang.md) |
| 🟢 **P2** | **WorkloadManager 中心化锁** | WM 事件处理慢 | 所有 WM 操作排队 | 条件触发 | [04-tez-session-pool-hang.md](04-tez-session-pool-hang.md) |

---

## 三、Hive 核心锁层级关系图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Hive 查询执行锁层级                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Level 0 ─ Session 操作锁                                               │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ HiveSessionImpl.operationLock (Semaphore)                    │       │
│  │ 默认: PARALLEL_OPS_IN_SESSION=true → null (不限制)            │       │
│  │ 关闭时: Semaphore(1) → 同session严格串行                      │       │
│  └──────────────────────────┬───────────────────────────────────┘       │
│                             ↓                                           │
│  Level 1 ─ 编译锁                                                       │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ CompileLockFactory.SERIALIZABLE_COMPILE_LOCK (ReentrantLock) │       │
│  │ 默认: PARALLEL_COMPILATION=false → 全局单锁                   │       │
│  │       COMPILE_LOCK_TIMEOUT=0s → 无限等待                      │       │
│  │ ⚠️ 一个慢编译阻塞所有其他查询！                                │       │
│  └──────────────────────────┬───────────────────────────────────┘       │
│                             ↓                                           │
│  Level 2 ─ Metastore 客户端锁                                           │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ Hive.getMSC() (synchronized)                                 │       │
│  │ → 所有 Metastore 操作入口，90+ 处调用                          │       │
│  │ → MSC 创建失败/慢时阻塞所有后续调用                             │       │
│  │                                                              │       │
│  │ Hive.registerAllFunctionsOnce() (wait/notify)                │       │
│  │ → 函数注册期间其他线程轮询等待                                  │       │
│  └──────────────────────────┬───────────────────────────────────┘       │
│                             ↓                                           │
│  Level 3 ─ HMS 服务端锁                                                 │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ HMSHandler.tablelocks (Striped<Lock>)                        │       │
│  │ → alter_partitions 等操作表级串行化                             │       │
│  │                                                              │       │
│  │ SharedCache.tableLock (ReentrantReadWriteLock)                │       │
│  │ → 缓存读写竞争，写者优先饿死读者                                │       │
│  └──────────────────────────┬───────────────────────────────────┘       │
│                             ↓                                           │
│  Level 4 ─ 分布式锁 / HDFS 操作                                         │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ DbLockManager.lock() → HMS事务锁 (backoff 重试)              │       │
│  │ → 默认: 100次重试 × 最大60s/次 = 最长约100分钟               │       │
│  │                                                              │       │
│  │ ZooKeeperHiveLockManager → ZK 分布式锁 (sleep 重试)          │       │
│  │                                                              │       │
│  │ FileSystem.listStatus/globStatus → HDFS RPC (无超时!!!)       │       │
│  │ → NN 不可达时线程无限阻塞                                      │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  ═══════════════════ 并行路径 ═══════════════════                       │
│                                                                         │
│  Tez 执行路径:                                                          │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ TezSessionPool.getSession() → while(true)+await (无限等待)    │       │
│  │ WorkloadManager.currentLock → 中心化锁 (所有WM操作串行)       │       │
│  │ DynamicPartitionPruner.queue.take() → 永久阻塞(无超时)       │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  缓存路径:                                                              │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │ QueryResultsCache → ReadWriteLock + wait()/notifyAll()       │       │
│  │ LlapObjectCache → 嵌套锁 (lock → objectLock → lock)          │       │
│  │ HiveClientCache → synchronized(CACHE_TEARDOWN_LOCK)          │       │
│  └──────────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 四、潜在死锁路径

### 死锁路径 1: HiveSessionImpl ↔ HiveMetaStoreClient

```
Thread A: HiveSessionImpl.acquireAfterOpLock(synchronized)
          → Hive.set(sessionHive) 
          → getMSC()(synchronized)

Thread B: Hive.getMSC()(synchronized) 正在创建 MSC
          → 回调触发 HiveSessionImpl 方法(synchronized)

风险: HiveSessionImpl.java 行 407-409 代码注释已明确标注此死锁风险
```

### 死锁路径 2: LlapObjectCache 嵌套锁

```
Thread A: retrieve(key1, fn) → lock.lock() → objectLock1.lock() → fn.call() (长时间)
Thread B: retrieve(key1) → lock.lock() 被阻塞（Thread A 持有 lock + objectLock1）
Thread C: retrieve(key2, fn) → lock.lock() 被阻塞（即使是不同 key）
```

### 死锁路径 3: DriverState 竞争

```
Thread A (查询线程): Driver.compileInternal → driverState.lock() → 编译中...
Thread B (cancel线程): Driver.close() → driverState.lock() 被阻塞
→ 如果编译线程在等待 Metastore，cancel 也无法中断
```

---

## 五、关键配置参数一览（默认值 vs 推荐值）

| 参数 | 配置键 | 默认值 | 风险 | 推荐值 |
|------|--------|--------|------|--------|
| 并行编译 | `hive.driver.parallel.compilation` | `false` | 🔴 全局串行 | `true` |
| 编译锁超时 | `hive.server2.compile.lock.timeout` | `0s` | 🔴 无限等待 | `60s` |
| 并行编译限制 | `hive.driver.parallel.compilation.global.limit` | `-1` | 开启并行后无限制 | CPU核数×2 |
| Session并行操作 | `hive.server2.parallel.ops.in.session` | `true` | — | `true` |
| 锁重试次数 | `hive.lock.numretries` | `100` | 最长100分钟等待 | `50` |
| 锁重试间隔 | `hive.lock.sleep.between.retries` | `60s` | — | `15s` |
| FS处理线程数 | `hive.metastore.fshandler.threads` | `15` | — | `20-30` |
| 移动文件线程数 | `hive.mv.files.thread` | `15` | — | `25` |
| Tez初始化线程 | `hive.server2.tez.sessions.init.threads` | `16` | — | `16` |

---

## 六、快速排查入口

当 Hive 出现卡住时，按以下优先级排查：

### Step 1: 拿 jstack（最重要）

```bash
# 找到 HiveServer2 进程
jps -l | grep HiveServer2
# 或
ps aux | grep HiveServer2 | grep -v grep

# 连续取3次 jstack，间隔5秒
for i in 1 2 3; do
  jstack -l <PID> > /tmp/hs2_jstack_$(date +%Y%m%d_%H%M%S).txt
  sleep 5
done
```

### Step 2: 分析 jstack 关键模式

| 搜索模式 | 对应问题 | 详细文档 |
|----------|----------|----------|
| `BLOCKED.*CompileLock` | 编译锁等待 | [02](02-compile-lock-hang.md) |
| `WAITING.*listStatus` | HDFS list 阻塞 | [01](01-list-files-hang.md) |
| `BLOCKED.*getMSC` | Metastore 连接阻塞 | [03](03-metastore-client-hang.md) |
| `WAITING.*TezSessionPool` | Tez Session 等待 | [04](04-tez-session-pool-hang.md) |
| `WAITING.*LinkedBlockingQueue.take` | DPP 阻塞 | [05](05-dpp-hang.md) |
| `WAITING.*DbLockManager.*backoff` | 事务锁等待 | [06](06-txn-lock-hang.md) |
| `WAITING.*operationLock` | Session 操作锁 | [07](07-session-lock-hang.md) |
| `BLOCKED.*SharedCache` | 缓存锁竞争 | [08](08-cache-lock-hang.md) |
| `BLOCKED.*TaskExecutorService` | LLAP 调度锁 | [09](09-llap-hang.md) |

### Step 3: 查看 HS2 日志

```bash
# 查看最近的编译锁超时
grep -i "COMPILE_LOCK_TIMED_OUT\|Waiting to acquire compile lock" /var/log/hive/hiveserver2.log | tail -20

# 查看 Metastore 连接错误
grep -i "MetaException\|Could not connect\|Connection refused" /var/log/hive/hiveserver2.log | tail -20

# 查看 Tez session 问题
grep -i "Awaiting Tez session\|Failed to use a session" /var/log/hive/hiveserver2.log | tail -20
```

---

## 七、因果链总图

```
[HDFS NN 高负载] ──→ [listStatus 无超时阻塞] ──→ [编译/执行线程卡死]
                                                      ↓
[Metastore 不可用] ──→ [getMSC synchronized 阻塞] ──→ [编译锁长时间持有]
                                                      ↓
[编译锁默认无限等待] ──────────────────────────────→ [所有新查询排队]
                                                      ↓
[Session operationLock] ←── [慢查询未结束] ──────→ [同session所有操作阻塞]
                                                      ↓
                                                 [用户感知: beeline无响应]

[YARN 资源不足] ──→ [Tez AM 启动失败] ──→ [Session池为空] ──→ [getSession无限等待]

[Vertex 失败] ──→ [无完成信号] ──→ [DPP queue.take 永久阻塞] ──→ [单查询永久挂起]

[并发 ACID] ──→ [锁竞争] ──→ [DbLockManager backoff] ──→ [最长100分钟等待]
```

---

## 八、文档索引

| 文档 | 内容 | 阅读建议 |
|------|------|----------|
| [01-list-files-hang.md](01-list-files-hang.md) | List 文件操作卡住 | NN 慢/小文件多时必看 |
| [02-compile-lock-hang.md](02-compile-lock-hang.md) | 编译锁卡住 | **所有环境必看，默认配置有风险** |
| [03-metastore-client-hang.md](03-metastore-client-hang.md) | Metastore 客户端阻塞 | HMS 不稳定时必看 |
| [04-tez-session-pool-hang.md](04-tez-session-pool-hang.md) | Tez Session 池饥饿 | 使用 Tez 引擎时必看 |
| [05-dpp-hang.md](05-dpp-hang.md) | DPP 永久阻塞 | 使用动态分区裁剪时必看 |
| [06-txn-lock-hang.md](06-txn-lock-hang.md) | 事务锁等待 | ACID 表高并发时必看 |
| [07-session-lock-hang.md](07-session-lock-hang.md) | Session 操作锁 | 同 session 多操作时必看 |
| [08-cache-lock-hang.md](08-cache-lock-hang.md) | 缓存锁竞争 | 使用缓存 Metastore 时看 |
| [09-llap-hang.md](09-llap-hang.md) | LLAP 相关阻塞 | 使用 LLAP 时看 |
| [10-config-tuning-guide.md](10-config-tuning-guide.md) | 配置调优指南 | **所有环境必看** |
| [11-troubleshooting-commands.md](11-troubleshooting-commands.md) | 排查命令大全 | 故障时参考 |
