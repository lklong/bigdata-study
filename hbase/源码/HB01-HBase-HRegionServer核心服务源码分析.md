# HBase HRegionServer 核心服务源码分析

> **源码路径**：`txProjects/hbase/hbase-server/src/main/java/org/apache/hadoop/hbase/regionserver/HRegionServer.java`（151.76 KB）
> **铁律遵守**：所有方法名、行号引用均来自上述真实源码

---

## 一、定位

`HRegionServer`（RS）是 HBase **分布式表服务的数据节点**。每个 RS 承载多个 Region，处理读写 RPC，与 HMaster + ZK + HDFS 三方协作。

**官方注释（HRegionServer.java:243-247）**：
```java
243: /**
244:  * HRegionServer makes a set of HRegions available to clients. It checks in with
245:  * the HMaster. There are many HRegionServers in a single HBase deployment.
246:  */
247: @InterfaceAudience.LimitedPrivate(HBaseInterfaceAudience.TOOLS)
```

---

## 二、类声明（HRegionServer.java:249-250）

```java
249: public class HRegionServer extends Thread implements
250:     RegionServerServices, LastSequenceId, ConfigurationObserver {
```

- **继承 Thread** — RS 本身就是主线程，`run()` 即其生命周期
- `RegionServerServices` — 内部服务回调接口
- `ConfigurationObserver` — 配置热更新

---

## 三、核心状态字段（HRegionServer.java:265-278）

```java
265: private final ConcurrentMap<byte[], Boolean> regionsInTransitionInRS =
266:   new ConcurrentSkipListMap<>(Bytes.BYTES_COMPARATOR);
   ...
272: private final ConcurrentMap<Long, Long> submittedRegionProcedures = new ConcurrentHashMap<>();
   ...
277: private final Cache<Long, Long> executedRegionProcedures =
278:     CacheBuilder.newBuilder().expireAfterAccess(600, TimeUnit.SECONDS).build();
```

**三大状态**：
- `regionsInTransitionInRS` — 正在 open/close 的 region（`ConcurrentSkipListMap` 按 rowkey 排序）
- `submittedRegionProcedures` — 已提交 procedure
- `executedRegionProcedures` — 已执行 procedure（10min TTL，幂等保护）

---

## 四、run 主循环（HRegionServer.java:979-1074）⭐

### 4.1 预检查与初始化（979-989）

```java
979: public void run() {
980:     if (isStopped()) {
981:         LOG.info("Skipping run; stopped");
982:         return;
983:     }
984:     try {
985:         // Do pre-registration initializations; zookeeper, lease threads, etc.
986:         preRegistrationInitialization();
987:     } catch (Throwable e) {
988:         abort("Fatal exception during initialization", e);
989:     }
```

### 4.2 向 Master 注册（991-1016）

```java
1002:        LOG.debug("About to register with Master.");
1003:        RetryCounterFactory rcf =
1004:          new RetryCounterFactory(Integer.MAX_VALUE, this.sleeper.getPeriod(), 1000 * 60 * 5);
1005:        RetryCounter rc = rcf.create();
1006:        while (keepLooping()) {
1007:            RegionServerStartupResponse w = reportForDuty();
1008:            if (w == null) {
1009:                long sleepTime = rc.getBackoffTimeAndIncrementAttempts();
1010:                LOG.warn("reportForDuty failed; sleeping {} ms and then retrying.", sleepTime);
1011:                this.sleeper.sleep(sleepTime);
1012:            } else {
1013:                handleReportForDutyResponse(w);
1014:                break;
1015:            }
1016:        }
```

**关键特性**：
- `Integer.MAX_VALUE` 无限重试
- 指数退避，最大 5 分钟
- `reportForDuty()` 向 Master 报到

### 4.3 主循环（1034-1074）⭐⭐

```java
1034:    // We registered with the Master.  Go into run mode.
1035:    long lastMsg = System.currentTimeMillis();
1036:    long oldRequestCount = -1;
1037:    // The main run loop.
1038:    while (!isStopped() && isHealthy()) {
1039:        if (!isClusterUp()) {
1040:            if (onlineRegions.isEmpty()) {
1041:                stop("Exiting; cluster shutdown set and not carrying any regions");
1042:            } else if (!this.stopping) {
1043:                this.stopping = true;
1044:                LOG.info("Closing user regions");
1045:                closeUserRegions(this.abortRequested.get());
   ...
1060:        long now = System.currentTimeMillis();
1061:        if ((now - lastMsg) >= msgInterval) {
1062:            tryRegionServerReport(lastMsg, now);
1063:            lastMsg = System.currentTimeMillis();
1064:        }
1065:        if (!isStopped() && !isAborted()) {
1066:            this.sleeper.sleep();
1067:        }
1068:    } // for
1069: } catch (Throwable t) {
1070:    if (!rpcServices.checkOOME(t)) {
1071:        String prefix = t instanceof YouAreDeadException? "": "Unhandled: ";
1072:        abort(prefix + t.getMessage(), t);
1073:    }
1074: }
```

**核心机制**：
1. **优雅下线**：先关 user region，保留 meta region 最后关
2. **周期心跳**：每 `msgInterval`（默认 3s）向 Master 报告
3. **YouAreDeadException**：Master 判定 RS 已死 → RS 立即自杀（1071 行静默 abort，防脑裂）

### 4.4 关闭清理（1082-1108）

```java
1082:    if (this.leaseManager != null) {
1083:        this.leaseManager.closeAfterLeasesExpire();
1084:    }
1085:    if (this.splitLogWorker != null) {
1086:        splitLogWorker.stop();
1087:    }
   ...
1097:    if (blockCache != null) {
1098:        blockCache.shutdown();
1099:    }
   ...
1106:    if (this.hMemManager != null) this.hMemManager.stop();
1107:    if (this.cacheFlusher != null) this.cacheFlusher.interruptIfNecessary();
1108:    if (this.compactSplitThread != null) this.compactSplitThread.interruptIfNecessary();
```

**关闭顺序**：Lease → SplitLog → BlockCache → MobFileCache → HMemManager → CacheFlusher → CompactSplit。

---

## 五、核心方法位置速查

| 方法 | 行号 | 作用 |
|------|------|------|
| `run()` | 979 | RS 生命周期主线程 |
| `tryRegionServerReport()` | 1237 | 周期心跳上报 |
| `handleReportForDutyResponse()` | 1555 | 处理 Master 注册响应 |
| `createMyEphemeralNode()` | 1681 | 在 ZK 创建 ephemeral 节点 |
| `createRegionServerStatusStub()` | 2701, 2714 | 从 ZK 发现 Active Master |
| `reportForDuty()` | 2799 | 向 Master 报到注册 |

---

## 六、HRegionServer 服务全景

```
┌────────────────────────────────────────────────────────┐
│ HRegionServer (extends Thread)                         │
│                                                         │
│  启动 run() [979]                                      │
│   1. preRegistrationInitialization                     │
│   2. reportForDuty（永不放弃，指数退避）               │
│   3. handleReportForDutyResponse                       │
│   4. 启动 Quota/Snapshot                               │
│   5. 主循环（心跳 + 集群下线处理）                     │
│                                                         │
│  核心服务：                                             │
│  RpcServices / RegionScanners / CompactSplit           │
│  MemStoreChoreFlusher / BlockCache / WAL               │
│  LeaseManager / SplitLogWorker / CoprocessorHost       │
│                                                         │
│  外部依赖：                                             │
│  - ZooKeeper：ephemeral node + 集群状态                │
│  - HMaster：region 分配、全局协调                      │
│  - HDFS：HFile + WAL 存储                              │
└────────────────────────────────────────────────────────┘
```

---

## 七、读写路径

**写路径**：
```
Put → RpcServices.multi() → HRegion.put()
  ├─ 写 WAL（HLog.append）⭐ 持久化
  ├─ 写 MemStore（skiplist）
  └─ 超过 flush.size → 触发 flush 到 HFile
```

**读路径**：
```
Get → RpcServices.get() → HRegion.get()
  ├─ 查 BlockCache（LRU）
  ├─ 查 MemStore
  └─ 查 HFile（BloomFilter → DataBlock）
```

---

## 八、故障检测机制

**HBase 的故障检测哲学极其简洁**：
- 活着 = ZK ephemeral 节点存在
- 死了 = 节点消失（ZK session 超时，默认 90s）
- Master 感知后 split log → 重新 assign region

**`createMyEphemeralNode()`（1681 行）** 就是这套机制的入口：RS 启动时在 `/hbase/rs/$serverName` 创建 ephemeral node。

---

## 九、生产关注点

### 9.1 Region 数量规划
- 每 RS **100-200 region**（HBase 2.x 可到 500+）
- 过多 → MemStore 碎片、GC 压力
- 过少 → 热点

### 9.2 MemStore 刷写
- `hbase.hregion.memstore.flush.size` = 128MB（单 region）
- `hbase.regionserver.global.memstore.size` = 堆 40%（全局）

### 9.3 Compaction 调优
- **Minor Compaction** 日常自动
- **Major Compaction** 默认 7 天 —— **生产建议关闭自动**，低峰期 cron 触发

### 9.4 RS 宕机恢复瓶颈
- `zookeeper.session.timeout` = 90s
- split log 是恢复瓶颈（10+ 分钟常见）

---

## 十、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hbase.regionserver.msginterval` | 3000ms | RS→Master 心跳间隔 |
| `zookeeper.session.timeout` | 90000ms | ZK session 超时 |
| `hbase.hregion.memstore.flush.size` | 128MB | MemStore flush 阈值 |
| `hbase.regionserver.global.memstore.size` | 0.4 | 全局 MemStore 最大占堆比 |
| `hbase.hstore.blockingStoreFiles` | 16 | 单 Store 阻塞写入的 HFile 数 |
| `hbase.regionserver.handler.count` | 30 | RPC 处理线程数 |

---

## 十一、Eric 点评

HRegionServer 是**"Thread = Server"设计范式的典型**。

### 11.1 极简启动模型

整个 RS 启动就是一个 `run()` 方法：前置初始化 → Master 注册（无限重试）→ 启动辅助服务 → 心跳循环。对比 YARN NM 的 Hadoop Service 框架，RS 更朴素直接。

### 11.2 ZK Ephemeral 故障检测

HBase 没有自研心跳协议，全靠 ZK：
- 活着 = 节点在
- 死了 = 节点消失
- 代价：90 秒恢复时间（这也是 HBase 不适合超低延迟场景的原因之一）

### 11.3 YouAreDeadException 的精妙

1071 行的 `YouAreDeadException` 处理：
- Master 发现两个 RS 都声称持有同一 region（脑裂）
- 给其中一个返回 YouAreDeadException
- RS 收到后**静默 abort**（1071 行 prefix 为空字符串）
- 保证**单 region 单 RS**的严格约束

### 11.4 与其他分布式存储对比

| 特性 | HBase RS | Cassandra | TiKV | MongoDB |
|------|----------|-----------|------|---------|
| 协调方式 | ZK + Master | Gossip | PD (etcd) | Config Server |
| Region 所有权 | 严格单 owner | 多副本 | Raft Group | 多副本 |
| 故障检测 | ZK ephemeral | Gossip | Raft heartbeat | Replica Set |

### 11.5 学习价值

HBase 的 151KB 单文件挑战了一切"短函数、小类"的现代设计原则，但它也证明了：**稳定性 > 美学**。

在生产中稳定运行 15 年的 HBase，其 `HRegionServer.run()` 方法的每一行都经过真实故障打磨。读懂这个 run 方法，就理解了"如何让分布式系统永不死"的第一性原理。

> HBase 不优雅，但它活着。
