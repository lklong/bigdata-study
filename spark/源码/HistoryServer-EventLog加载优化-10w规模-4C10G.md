# Spark HistoryServer · 10万 EventLog 加载优化深度分析

> **场景**：单台 HistoryServer 4C10G，面对 **10w+ EventLog** 的扫描、Listing 构建、UI Replay
> **版本**：Spark 3.3.2（社区分支一致）
> **作者**：eric · 2026-04-28
> **方法论**：`lkl-code-mastery-methodology`（L2 主链路深挖）+ `lkl-bigdata-ops-orchestrator` · Spark 专家
> **源码位置**：`D:\bigdata\txproject\spark\core\src\main\scala\org\apache\spark\deploy\history\`

---

## 一、结论先行（TL;DR）

**10w EventLog / 4C10G 单点 SHS 默认配置下必然崩溃**，根本矛盾在三条轴上：

| 轴 | 默认行为 | 10w 规模下的后果 |
|----|---------|----------------|
| **扫描轴** | `checkForLogs` 单线程每 10s 全量 `fs.listStatus(logDir)` | 一次 list 拉 10w FileStatus，HDFS NN / 对象存储 list 接口被打爆，GC 抖动 |
| **Replay 轴** | `replayExecutor` 线程数 = `CPU/4` = **1 线程** | 10w 未处理日志 → 积压数天，HS UI 看不到新作业 |
| **内存轴** | `InMemoryStore` 默认不落盘，`listing` KVStore 全内存 | 10w Listing 元数据 + 活跃 UI 缓存，10G 堆迅速 OOM / Full GC |

**核心优化四连击**：
1. **启用磁盘 KVStore**（`spark.history.store.path`）→ Listing 元数据不占堆
2. **开 Cleaner + maxNum**（`spark.history.fs.cleaner.enabled=true` + `maxNum=10000`）→ 控制规模
3. **扩 Replay 线程数**（`spark.history.fs.numReplayThreads=8~16`）→ 突破 1 线程瓶颈
4. **调大 update.interval**（10s → 60~120s）→ 降低扫描频率
5. **开 rolling + compaction**（`spark.eventLog.rolling.enabled=true`）→ 大 app 不再重复 replay

**但 4C10G 单机 10w 不是长久之计**。eric 强烈建议：
- **短期**：按优化方案压到 2w-3w 有效 listing + 启用 Cleaner
- **中期**：SHS 分片部署（按 queue 或 appId hash）
- **长期**：迁移 Spark History on K8s + 对象存储 + 独立元数据 KVStore

---

## 二、源码级完整调用链

### 2.1 全景图（主 Polling 线程）

```
SHS 启动
  └─ FsHistoryProvider.start()                                  [L428]
       └─ initialize() → startPolling()                         [L243,281]
            └─ pool.scheduleWithFixedDelay(checkForLogs,        [L313]
                 delay=UPDATE_INTERVAL_S)  ← 默认 10s
            └─ pool.scheduleWithFixedDelay(cleanLogs,           [L318]
                 delay=CLEAN_INTERVAL_S)   ← 默认 1d

每轮 checkForLogs （单线程、全量、同步）：           [L487-621]
  ┌─────────────────────────────────────────────────────────┐
  │ 1. fs.listStatus(logDir)   ← 一次拉全部 10w FileStatus  │
  │ 2. for each entry:                                      │
  │    ├─ isAccessible? / isProcessing? 过滤                │
  │    ├─ EventLogFileReader(fs, entry) 构造               │
  │    ├─ listing.read(LogInfo, path)  ← KVStore 查询      │
  │    ├─ shouldReloadLog(info, reader)  [L623]            │
  │    │    └─ 依据 completed / fileSize 判断是否需要重放  │
  │    └─ fastInProgressParsing 快路径分流                 │
  │ 3. 对需要 reload 的 entry:                              │
  │    submitLogProcessTask(rootPath) {                     │
  │       mergeApplicationListing(reader, ..., true)        │
  │    }   ← 提交到 replayExecutor                           │
  │ 4. stale 清理：KVStore 里 lastProcessed < now 的删除    │
  └─────────────────────────────────────────────────────────┘
                              │
                              ▼
replayExecutor 线程池（默认 CPU/4 向上取整）：    [L233, L155]
  ┌─────────────────────────────────────────────────────────┐
  │ mergeApplicationListing(reader, ...)          [L712]    │
  │   └─ doMergeApplicationListingInternal(...)   [L769]    │
  │       ├─ ReplayListenerBus + AppListingListener         │
  │       ├─ parseAppEventLogs(logFiles, bus, ...) [L1141]  │
  │       │    └─ for f in logFiles:                        │
  │       │         EventLogFileReader.openEventLog(f, fs)  │
  │       │         ←─ 按后缀选 CompressionCodec [L138-150] │
  │       │         └─ replayBus.replay(in, ...)            │
  │       └─ 若 shouldHalt && appCompleted:                 │
  │            in.skip(fileLen - reparseChunkSize)  [L826]  │
  │            ← 跳过前面，只读尾部 1MB 找 AppEnd 事件       │
  │   └─ 成功后：submitLogProcessTask { compact(reader) }  │
  └─────────────────────────────────────────────────────────┘
```

### 2.2 关键源码片段标注

#### (A) Listing 线程池 —— 这就是 10w 下的第一瓶颈

```scala
// FsHistoryProvider.scala
// L124 —— pool 是单线程，负责所有周期任务
private val pool = ThreadUtils
  .newDaemonSingleThreadScheduledExecutor("spark-history-task-%d")
```

> **解读**：`checkForLogs` / `cleanLogs` / `cleanDriverLogs` **共用一个 scheduled 线程**，
> 一旦 `listStatus` 或 stale 扫描慢，Cleaner 就排不上队。

#### (B) Replay 线程数默认值极其保守

```scala
// History.scala : L155-158
val NUM_REPLAY_THREADS = ConfigBuilder("spark.history.fs.numReplayThreads")
  .intConf
  .createWithDefaultFunction(() =>
    Math.ceil(Runtime.getRuntime.availableProcessors() / 4f).toInt)
```

> **解读**：4 核机器 → `ceil(4/4)=1`。**一个线程 replay 10w 日志，光排队就排到天荒地老。**
>
> 但这也不是随便调大就好——下面会讲为什么 `numReplayThreads` 不能超过 `CPU核数*2`。

#### (C) checkForLogs 的全量 list 语义

```scala
// FsHistoryProvider.scala : L497
val updated = Option(fs.listStatus(new Path(logDir))).map(_.toSeq).getOrElse(Nil)
  .filter { entry => isAccessible(entry.getPath) }
  .filter { entry => ... }  // 过滤正在处理的
  .flatMap { entry => EventLogFileReader(fs, entry) }  // 每个都构造 Reader
  .filter { reader => ...shouldReloadLog(info, reader)... }  // 依 KVStore 决策
  .sortWith { case (e1, e2) => e1.modificationTime > e2.modificationTime }
```

> **解读**：这是一次**全量 list + 全量构造 Reader + 全量查询 KVStore**。
> 10w 文件时：
> - `listStatus` on HDFS：单 NN RPC，返回 10w FileStatus（约 200MB 堆内存）
> - `listStatus` on S3/COS：**分页调用**（默认 1000/页 × 100 页），30s+ 起步
> - `listing.read` 10w 次 LevelDB/RocksDB 查询：磁盘 IOPS 打满

#### (D) End-Event 跳跃式解析优化（已有的性能优化点）

```scala
// FsHistoryProvider.scala : L817-840
val lookForEndEvent = shouldHalt && (appCompleted || !fastInProgressParsing)
if (lookForEndEvent && listener.applicationInfo.isDefined) {
  val lastFile = logFiles.last
  Utils.tryWithResource(EventLogFileReader.openEventLog(lastFile.getPath, fs)) { in =>
    val target = lastFile.getLen - reparseChunkSize  // 默认 1MB
    if (target > 0) {
      var skipped = 0L
      while (skipped < target) {
        skipped += in.skip(target - skipped)
      }
    }
    val source = Source.fromInputStream(in)(Codec.UTF8).getLines()
    if (target > 0) source.next()   // 跳过可能半行
    bus.replay(source, lastFile.getPath.toString, !appCompleted, eventsFilter)
  }
}
```

> **解读**：这是 SPARK-25451 引入的关键优化（`spark.history.fs.endEventReparseChunkSize`）。
> - 已完成的 app，**不再从头 replay**，只 replay 文件尾部 1MB（找 AppEnd / Env 事件）
> - 前面靠 `AppListingListener` + `haltForApp()` 触发早停
> - **10w 规模下必须确保 `endEventReparseChunkSize > 0`**，否则每个 app 都全文读

#### (E) Rolling + Compaction（SPARK-28594）

```scala
// FsHistoryProvider.scala : L178-179 + L750-753
private val fileCompactor = new EventLogFileCompactor(conf, hadoopConf, fs,
  conf.get(EVENT_LOG_ROLLING_MAX_FILES_TO_RETAIN),
  conf.get(EVENT_LOG_COMPACTION_SCORE_THRESHOLD))

// 每次 mergeApplicationListing 成功后：
if (succeeded) {
  submitLogProcessTask(rootPath) { () => compact(reader) }
}
```

> **解读**：Spark 3.0+ 支持 rolling eventlog，长作业可以滚动切片 + 合并旧片段。
> - 写入端：`spark.eventLog.rolling.enabled=true` + `spark.eventLog.rolling.maxFileSize=128m`
> - HistoryServer：自动对老片段做 compaction（删除死 RDD/ExecutorEvents）
> - **对于跑 10 天以上的流/长批作业，不开 rolling 会导致 GB 级 eventlog 每次全读**

#### (F) InMemory vs Disk KVStore —— 10G 堆的生死线

```scala
// FsHistoryProvider.scala : L140-167
private[history] val listing: KVStore = storePath.map { path =>
  val dir = hybridStoreDiskBackend match {
    case LEVELDB => "listing.ldb"
    case ROCKSDB => "listing.rdb"
  }
  val dbPath = Files.createDirectories(new File(path, dir).toPath()).toFile()
  ...
  open(dbPath, metadata, conf)
}.getOrElse(new InMemoryStore())  // ← 没配 storePath 就全内存！
```

> **解读**：如果没有配 `spark.history.store.path`，**整个 listing（10w 条 ApplicationInfo + LogInfo）全在堆里**，
> 每条约 2-5KB，10w 条就是 200-500MB **常驻堆**，再叠活跃 UI，10G 堆瞬间告急。

---

## 三、容量与性能建模

### 3.1 单次 checkForLogs 耗时估算

以 **HDFS 后端 + 10w eventlog** 为例：

| 阶段 | 单次成本 | 总耗时 |
|------|---------|--------|
| `fs.listStatus(logDir)` | NN 单次 RPC，约 200ms / 1w 条 | **2s** |
| 构造 EventLogFileReader × 10w | 每个约 0.1ms（含 getStatus） | 10s |
| `listing.read(LogInfo)` × 10w | LevelDB 点查约 0.1-0.5ms | **10-50s** |
| `shouldReloadLog` 判定 × 10w | CPU only，<1μs | <1s |
| sort by modtime × 10w | `O(n log n)`, CPU only | 0.1s |
| 提交 submitLogProcessTask | 有多少 reload 提多少 | 若 5% reload = 5000 任务 |

**单轮理论耗时 25-70s**，而默认 `UPDATE_INTERVAL_S=10s` —— **Polling 线程永远追不上自己**。

对象存储（S3/COS）下 `listStatus` 更是 10x 放大，**单轮 5 分钟+**。

### 3.2 Replay 吞吐建模

- 单个 eventlog 平均大小：假设 50MB（中等作业，带 rolling compact 后）
- Replay 单线程吞吐：约 **20-50 MB/s**（JSON 反序列化 CPU bound）
- 单个日志 replay 耗时：**1-3 秒**（启用 endEventReparse 后）
- 10w 日志 / 1 线程：**100,000 × 2s = 55 小时**（不含 HybridStore 落盘）
- 10w 日志 / 16 线程：**3.5 小时**（首次冷启动）
- 稳态增量（每小时新增 1000 个）：**16 线程处理 1000 个 = 125s**，完全跟得上

**结论**：`numReplayThreads` 必须 ≥ 8，否则冷启动永远追不上。

### 3.3 内存建模（10G 堆下的生死线）

| 占用项 | 每条/每个成本 | 10w 总量 | 占堆比 |
|-------|-------------|---------|--------|
| `listing` KVStore (InMemory) | 约 3KB × 2 entry（AppInfo + LogInfo） | **600MB** | 6% |
| `processing` ConcurrentHashMap | 约 100B × 10w | 10MB | 0.1% |
| `inaccessibleList` | 约 200B × 少量 | < 1MB | - |
| `activeUIs` 缓存 | 每个活跃 UI 约 50-200MB（SparkUI + Store） | 50 个活跃 = **2.5-10GB** | **25-100%** |
| `replayExecutor` 线程栈 | 约 1MB × N | 16MB | 0.2% |
| `pool` scheduled 线程 | 单个 | 1MB | - |
| **堆外** MaxDirectMemorySize | 默认 1G | 1GB | （堆外） |
| **HybridStore in-memory** | `spark.history.store.hybridStore.maxMemoryUsage`=2G | 2GB | 20% |

**致命项**：`activeUIs`。默认 `retainedApplications=50`，**单个 UI 能吃 200MB+**，
50 个就是 10GB —— 直接打爆堆。

**强烈建议**：
- 10G 堆下 `spark.history.retainedApplications` **必须降到 10-20**
- 启用磁盘 KVStore 后，UI Store 会换到 LevelDB/RocksDB，堆占用下降 5-10x

---

## 四、完整优化方案

### 4.1 推荐配置（4C10G × 10w EventLog）

```properties
# ================= 1. 存储/KVStore 架构 =================
# 【关键】磁盘 KVStore，listing + UI 全落盘
spark.history.store.path                  /data/spark-history/cache
spark.history.store.maxDiskUsage          50g               # 磁盘缓存上限
spark.history.store.hybridStore.enabled   true              # HybridStore 加速
spark.history.store.hybridStore.maxMemoryUsage  1g          # ← 10G 堆下降到 1G
spark.history.store.hybridStore.diskBackend     ROCKSDB     # 比 LEVELDB 稳

# ================= 2. 扫描/Polling 频率 =================
spark.history.fs.update.interval          120s              # 默认 10s → 120s
spark.history.fs.inProgressOptimization.enabled   true      # 默认就是 true
spark.history.fs.endEventReparseChunkSize         1m        # 保持默认，勿设 0

# ================= 3. Replay 并发 =================
spark.history.fs.numReplayThreads         8                 # 4C 下压满：4核×2
# 不要超过 CPU*2，否则 CPU 争抢 + KVStore 锁竞争反而更慢

# ================= 4. Cleaner（生死线） =================
spark.history.fs.cleaner.enabled          true
spark.history.fs.cleaner.interval         1h                # 默认 1d → 1h
spark.history.fs.cleaner.maxAge           7d                # 保留 7 天
spark.history.fs.cleaner.maxNum           20000             # 最多保留 2w 个
#   ↑ 把 10w 压到 2w 是最核心的止血，不这么干机器不够

# ================= 5. UI 活跃缓存 =================
spark.history.retainedApplications        20                # 默认 50 → 20
spark.history.ui.maxApplications          500               # UI 一次展示数

# ================= 6. 作业侧（配合）：启用 rolling =================
# 写入端 spark-defaults.conf 要加：
#   spark.eventLog.rolling.enabled                  true
#   spark.eventLog.rolling.maxFileSize              128m
#   spark.history.fs.eventLog.rolling.maxFilesToRetain  2
#   spark.eventLog.compress                         true
#   spark.eventLog.compression.codec                zstd    # 注意与 SHS 一致

# ================= 7. 压缩 Compaction 门槛 =================
spark.history.fs.eventLog.rolling.compaction.score.threshold  0.7   # 默认即可
```

### 4.2 JVM 参数（10G 堆）

```bash
# conf/spark-env.sh → SPARK_HISTORY_OPTS
export SPARK_HISTORY_OPTS="
  -Xms10g -Xmx10g
  -XX:MaxDirectMemorySize=2g
  -XX:+UseG1GC
  -XX:MaxGCPauseMillis=200
  -XX:+ParallelRefProcEnabled
  -XX:+UnlockDiagnosticVMOptions
  -XX:G1HeapRegionSize=16m
  -XX:InitiatingHeapOccupancyPercent=35
  -XX:+UseStringDeduplication

  -Xlog:gc*,gc+heap=debug,gc+age=trace:file=/var/log/spark/shs-gc-%t.log:time,uptime,level,tags:filecount=10,filesize=200m
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath=/var/log/spark/shs-oom.hprof

  -Dspark.history.fs.logDirectory=cosn://xxx/apps/spark/event/
  -Dspark.history.ui.port=18080
"
```

**RocksDB 堆外内存**：`MaxDirectMemorySize` 必须从默认 1G 提到 **2G**，否则 RocksDB BlockCache 很容易 `OutOfDirectMemoryError`。

### 4.3 操作系统侧

```bash
# 1. 磁盘 IOPS 要够：store.path 建议 SSD，最低 2000 IOPS
# 2. 文件描述符
ulimit -n 65536
echo "* soft nofile 65536" >> /etc/security/limits.conf
echo "* hard nofile 65536" >> /etc/security/limits.conf

# 3. 内核参数（对象存储场景）
sysctl -w net.core.somaxconn=4096
sysctl -w net.ipv4.tcp_max_syn_backlog=4096
```

### 4.4 对象存储（COS/S3）专项

若你的 `logDirectory` 是 `cosn://` 或 `s3a://`：

```properties
# Hadoop 配置（core-site.xml 或 spark-defaults.conf 前缀 spark.hadoop.）
fs.cosn.list.max-keys                     5000       # 默认 1000，提到 5000
fs.cosn.client.max-retries                3
fs.cosn.read.ahead.queue.size             8
fs.cosn.buffer.size                       67108864   # 64MB
fs.cosn.upload.buffer                     mapped_disk  # 避免堆占用

# S3A 同类：
# fs.s3a.paging.maximum                   5000
# fs.s3a.connection.maximum               64
# fs.s3a.threads.max                      64
# fs.s3a.fast.upload.buffer                disk
```

---

## 五、分层优化策略（按规模演进）

### L1 · 单机能扛（< 2w EventLog / 4C10G）
**做好上面的配置即可**。Cleaner + maxNum 把规模压住。

### L2 · 单机吃紧（2w - 5w / 4C10G）
1. 机器升配：**8C32G**
2. 堆 24G + HybridStore 4G + MaxDirectMemorySize 4G
3. `numReplayThreads=16`
4. eventlog 迁移到 **独立冷存储** + 定期归档
5. 打开 rolling + compaction，让单 app 日志可控

### L3 · 单机扛不住（5w+）
**必须分片**。常见两种方案：

#### 方案 A：按 queue/租户 拆 SHS
```
SHS-1  → logDirectory = cosn://.../event/queue=ads/
SHS-2  → logDirectory = cosn://.../event/queue=adhoc/
SHS-N  → logDirectory = cosn://.../event/queue=etl/
```
**需要改写入端**：`spark.eventLog.dir` 带上 queue 子目录。

#### 方案 B：按 appId 哈希分片
- 独立的 listing 聚合服务
- 前端 UI 根据 appId hash 转发到具体 SHS 实例

### L4 · 彻底云原生
- SHS on K8s，多副本无状态
- eventlog on 对象存储
- **元数据 KVStore 用共享 Redis/TiKV** → SHS 实例任意扩缩

---

## 六、关键监控指标

上线后必须盯以下指标，出现异常立即告警：

| 指标 | 来源 | 阈值 |
|------|------|------|
| `FsHistoryProvider.getEventLogsUnderProcess()` | JMX | < `numReplayThreads * 3` |
| 单轮 `checkForLogs` 耗时 | 日志 "Scanning $logDir" 到 "New/updated attempts found" | < `update.interval * 0.5` |
| JVM Heap Used | JMX `java.lang:type=Memory` | < 80% |
| JVM G1 Young GC 频率 | GC log | < 10 次/min |
| JVM G1 Full GC | GC log | = 0 |
| RocksDB 磁盘占用 | `du -sh /data/spark-history/cache` | < `maxDiskUsage * 0.8` |
| `listStatus` 延迟 | 日志对象存储客户端 | < 10s |
| eventlog 数量 | `hadoop fs -count $logDir` 定时 | < `maxNum * 0.9` |

### 6.1 Prometheus 采集示例

Spark 3.x SHS 内置 metrics：开启 `spark.metrics.conf.history.source.history.class` 通过 JMX Exporter 或 DropWizard 导出，关注：
- `history.totalEventLogsMerged`
- `history.countEventLogsToReplay`
- `history.replayQueuePending`

---

## 七、验证与压测

```bash
# 1. 准备 10w 个 mock eventlog（生产前在预发环境跑）
for i in $(seq 1 100000); do
  cp /path/to/template.eventlog cosn://.../event/application_20260428_$(printf "%06d" $i).lz4
done

# 2. 启 SHS，看首次冷启动耗时
./sbin/start-history-server.sh
tail -f /var/log/spark/spark-history-server-*.out | grep -E "Scanning|Finished parsing|checkForLogs"

# 3. JVM 实时观察
jstat -gcutil <pid> 1s 60      # GC 观察
jmap -histo:live <pid> | head  # 堆内热点对象

# 4. 线程池状态
jstack <pid> | grep -E "log-replay-executor|spark-history-task"
```

**验收指标**：
- 冷启动 10w 日志完成时间 < 4h
- 稳态增量跟上（单轮 checkForLogs 内处理完新增）
- Full GC 为 0
- 堆使用 < 80%
- UI 打开任意 app P95 < 3s

---

## 八、与其他组件的联动治理

1. **写入端规范**（这是根）：
   - 强制开 `spark.eventLog.compress=true` + `zstd`
   - 强制开 rolling + `maxFileSize=128m`
   - `maxFilesToRetain=2` —— 老片段只留 2 个
   - 每个作业必须 `sc.stop()` 触发 AppEnd 事件

2. **Cleaner 必须启用** — 生产环境从不关闭，否则就是定时炸弹

3. **冷热分层**：
   - 热：近 7 天 eventlog 在 SHS 的 logDirectory
   - 冷：更早的归档到低频存储（COS INFREQUENT_ACCESS / S3 Glacier）
   - SHS 只服务热区

---

## 九、常见坑位清单（Troubleshooting）

| 现象 | 根因 | 参考案例 |
|------|------|---------|
| `MalformedInputException: Input length = 1` | 写入端压缩 codec 与 SHS 读取端不一致 / 文件损坏 | 本次 4C10G 场景同步遇到 |
| UI 长期看不到新作业 | `replayQueuePending` 积压，线程不够 | `numReplayThreads` |
| Full GC 连环 | `activeUIs` 过多 / InMemoryStore | 开磁盘 Store + 降 retainedApps |
| `Too many open files` | 同时 replay 过多 rolling eventlog | `ulimit -n` + 降线程数 |
| 启动失败 `MetadataMismatchException` | 升级版本后 KVStore schema 不兼容 | 删 `spark.history.store.path` 目录重建 |
| Cleaner 不生效 | `spark.history.fs.cleaner.enabled=false` | 检查配置 |
| RocksDB `OutOfDirectMemory` | MaxDirectMemorySize 不够 | 提到 2-4G |

---

## 十、源码索引（速查表）

| 功能 | 类 | 方法/行号 |
|------|-----|---------|
| 主调度入口 | `FsHistoryProvider` | `startPolling` L281 |
| 全量扫描 | `FsHistoryProvider` | `checkForLogs` L487 |
| 是否重新解析 | `FsHistoryProvider` | `shouldReloadLog` L623 |
| Listing 合并 | `FsHistoryProvider` | `mergeApplicationListing` L712 |
| Replay 核心 | `FsHistoryProvider` | `doMergeApplicationListingInternal` L769 |
| 尾部跳读优化 | `FsHistoryProvider` | L817-840 |
| 重建 UI Store | `FsHistoryProvider` | `rebuildAppStore` L1108 |
| 解析事件流 | `FsHistoryProvider` | `parseAppEventLogs` L1141 |
| 清理 | `FsHistoryProvider` | `cleanLogs` L964 |
| 任务提交 | `FsHistoryProvider` | `submitLogProcessTask` L1413 |
| 打开 EventLog | `EventLogFileReader` | `openEventLog` L138 |
| 压缩 codec 选择 | `EventLogFileReader` | `codecMap` L102 |
| 单文件 Reader | `SingleFileEventLogFileReader` | L173 |
| Rolling Reader | `RollingEventLogFilesFileReader` | L215 |
| 配置项定义 | `History`（config） | 整个文件 |
| Compaction 策略 | `EventLogFileCompactor` | - |

---

## 十一、参考资料

- **SPARK-25451**：End-event reparse chunk（尾部跳读优化）
- **SPARK-28594**：Rolling event log（滚动日志）
- **SPARK-29779**：HybridStore
- **SPARK-31608**：EventLogCompactor（压缩合并）
- Apache Spark 3.3.2 官方文档：Monitoring → History Server
- 本地源码路径：`D:\bigdata\txproject\spark\core\src\main\scala\org\apache\spark\deploy\history\`

---

*— eric · Spark 源码精通 · L2 主链路深挖 · 2026-04-28*
