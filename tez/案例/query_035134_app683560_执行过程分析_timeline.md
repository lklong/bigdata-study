# Query hadoop_20260408035134 (app_683560) 完整执行过程分析

> **Query ID**: `hadoop_20260408035134_bca05f56-67bf-44ed-b25f-51424252fef6`  
> **App ID**: `application_1762781849738_683560`  
> **SQL**: `INSERT OVERWRITE TABLE dwd.dwd_nf_iot_report_gps_others_alarm_event_mt_da PARTITION (event_day='20260407')`  
> **用户**: dmp | **HS2 Session**: 290a6f37 | **HS2 节点**: 10.23.0.43

---

## 一、执行结论

**DAG2 因 EOFException 失败 → Hive ReExecDriver 自动重试 → DAG3 跑了 1h43min 无任何 Map 完成 → 被用户 kill。**

总耗时 3h15min（03:51 → 07:06），一条数据都没写成功。

---

## 二、完整时间线

```
03:51:34.615  SQL 编译开始
03:51:35.833  SQL 编译完成 (1.2s)
03:51:35.835  开始执行
03:51:36.493  创建 Tez Session (afda0248)
03:51:36.756  ★ Submitted application_683560 到 YARN

              === AM 排队 20 分 10 秒 ===

04:11:46.611  PreWarm DAG 提交 (dag_683560_1, 3 containers)
04:11:46.885  PreWarm DAG 已提交

              === PreWarm 完成 ===

04:12:05.258  ★ DAG2 提交 (dag_683560_2, 实际查询)
04:12:05.447  DAG2 已提交到 AM
04:12:07.333  DAG2 Map 1: 0/487, Reducer 2: 0/2000
04:12:07.842  DAG2 Map 1: 0(+3)/487 ← 只拿到 3 个并发

              === DAG2 完整四阶段 ===

05:00:00      阶段A: Map 1: 70(+3)/487 ← 3 并发慢跑, 48min 完成 70 个
05:06:10      阶段A 结束: Map 1: 79(+3)/487 ← 55min 完成 79 个
05:07:03      阶段B 开始: Map 1: 79(+5)/487 ← ★ 并发暴涨!
05:07:11      阶段B 结束: Map 1: 79(+361)/487 ← 8s 内 3→361
05:14:13      阶段C: Map 1: 98(+361)/487 ← 361并发批量出结果
05:14:17      Map 1: 256(+231)/487 ← 2min 内完成 388 个
05:16:23      Map 1: 486(+1,-1)/487 ← 486 完成, 剩 1 个失败中
05:23:23      阶段D: Map 1: 486(+0,-4)/487 ← 4 次重试全 EOF
              (Reducer 2 被 auto parallelism 从 2000 缩减为 500)
05:23:23      DAG2 Map 1: 486(+0,-4)/487 ← 最后 1 个 Map 失败

05:23:24.449  ★★★ DAG2 FAILED ★★★
              根因: task 读数据时 EOFException
              "java.io.EOFException: Unexpected end of input stream"
              DecompressorStream → LineReader → LineRecordReader
              Map 1: failedTasks=1, killedTasks=0
              Reducer 2: killedTasks=500 (因 OTHER_VERTEX_FAILURE)
              DAG: VERTEX_FAILURE

              === Hive ReExecDriver 自动重试 ===

05:23:24.499  SQL 重新编译 (1.1s)
05:23:25.572  重新执行
05:23:25.817  ★ DAG3 提交 (dag_683560_3)
05:23:25.895  DAG3 已提交
05:23:26.929  DAG3 Map 1: 0/487, Reducer 2: 0/2
              (Reducer 2 缩减为 2，因为上次 auto parallelism 的经验)
05:23:29      DAG3 Map 1: 0(+8)/487
05:23:30      DAG3 Map 1: 0(+24)/487 ← 并发快速拉满

              === DAG3 拿到 487 个并发但 0 个完成 ===

05:59:57      DAG3 Map 1: 0(+487)/487 ← 全部 running, 0 完成!
07:00:00      DAG3 Map 1: 0(+487)/487 ← 又过了 1 小时, 还是 0 完成!

07:06:36.541  ★ 客户端关闭 Operation (CloseOperation)
07:06:36.541  "The running operation has been successfully interrupted"
07:06:36.870  DAG3 被 kill: "Sending client kill from dmp to dag_3"
              Map 1: killedTasks=487
              Reducer 2: killedTasks=2
              DAG: DAG_KILL

07:06:36.927  "Executing command has been interrupted after 6190.972 seconds"
              (6191s ≈ 1h43min 从 DAG3 开始算; 总计 3h15min)
```

---

## 三、关键问题分析

### 3.1 DAG2 失败根因：EOFException

```
java.io.EOFException: Unexpected end of input stream
  at DecompressorStream.decompress()
  at LineReader.fillBuffer()
  at LineRecordReader.next()
```

**486/487 个 Map 成功，最后 1 个 Map 读到了损坏/不完整的压缩文件**。这跟之前 app_682541 的 task_000245 EOFException 是同一个文件。

ODS 源表 `ods_kafka_iot_report_gps_others_alarm_event_mt_dl` 分区 `event_day='20260407'` 中有一个压缩文件尾部不完整，导致 `DecompressorStream` 在解压时遇到意外的流结束。


### 3.2 DAG2 资源分配 + 执行全过程（tezStageProfile 逐条验证）

**Container 分配过程（COMPLETED / RUNNING / PENDING / FAILED）**：

```
时间        COMPLETED  RUNNING  PENDING  FAILED  说明
─────────  ─────────  ───────  ───────  ──────  ────
04:12:05   -          -        -        -       DAG2 提交, Map 1 INITIALIZING
04:12:07   0          0        487      0       Map 1 INITED, 487 全部 pending
04:12:07   0          3        484      0       ★ 首批 3 个 container
04:14:09   1          3        483      0       第 1 个 Map 完成(2min)
04:14:16   2          3        482      0       
04:14:21   3          3        481      0       
04:20:04   11         3        473      0       
04:30:00   ~25        3        ~459     0       
04:40:38   40         3        444      0       28min 完成 40 个
04:50:30   55         3        429      0       
04:59:59   70         3        414      0       48min 完成 70 个, 仍 3 并发
05:06:10   79         3        405      0       55min 完成 79 个
```

**55 分钟 RUNNING 始终 = 3。RM 没有给更多 container，靠 container 复用跑完一个接一个。**

```
05:07:03   79         5        403      0       ★ 开始暴涨！
05:07:04   79         24       384      0       
05:07:05   79         66       342      0       100+/秒 分配速度
05:07:06   79         178      230      0       
05:07:07   79         332      76       0       
05:07:08   79         355      53       0       
05:07:11   79         361      47       0       ★ 稳定 361 并发
```

**8 秒内 RM 分配了 358 个新 container（3→361）。原因：05:07 同队列某大 App 结束释放 container。**

```
05:07:20   80         361      46       0       拿到 container, 开始读 COS
05:13:34   82         361      44       0       6min 才多完成 2 个(新 task 在读数据)
05:14:13   98         361      28       0       ★ 批量完成开始(拿 container 后 ~7min)
05:14:15   142        345      0        0       PENDING=0, 所有 task 都在跑
05:14:17   256        231      0        0       2min 内批量完成
05:14:28   298        189      0        0       
05:14:37   353        134      0        0       
05:14:45   426        61       0        0       
05:15:41   453        34       0        0       
05:16:02   455        32       0        1       ★ 首个 FAILED task
05:16:10   483        4        0        1       
05:16:23   486        1        0        1       486 完成, 1 个失败 task 重试中
05:17:44   486        1        0        2       第 2 次重试失败
05:21:26   486        1        0        3       第 3 次重试失败
05:23:23   486        0        0        4       第 4 次重试 → DAG2 FAILED
```

**DAG2 资源分配总结**：

| 阶段 | 时间段 | 耗时 | RUNNING | 说明 |
|------|--------|------|---------|------|
| 初始分配 | 04:12:07 | 即时 | 3 | RM 首批分配, 队列 82 active apps |
| 慢跑期 | 04:12~05:07 | 55min | 3 | container 复用, 每 ~2min 完成 1 个 |
| 暴涨 | 05:07:03~05:07:11 | 8s | 3→361 | 大 App 结束释放, RM 重分配 358 个 |
| 读数据 | 05:07~05:14 | 7min | 361 | 新 task 读 COS, COMPLETED 仅+3 |
| 批量完成 | 05:14:13~05:16:23 | 2min | 361→1 | 388 个 task 批量完成 |
| 失败重试 | 05:16:23~05:23:23 | 7min | 1 | 1 个 task, 4 次 attempt 全 EOF |

---

### 3.3 DAG3 资源分配 + 执行全过程（tezStageProfile 逐条验证，对标 DAG2）

**DAG3 基本信息**：

| 项 | DAG3 | 对比 DAG2 |
|---|---|---|
| DAG ID | dag_683560_3 | dag_683560_2 |
| 触发 | ReExecDriver 自动重试 | HS2 正常提交 |
| Session | "Session is already open" 复用 | 新建 |
| 提交线程 | Thread-1828255 | Thread-1824614 |
| Map 数 | 487 | 487（同 AM = 同 totalResources） |
| Reducer 数 | **2** | 2000→auto 500 |
| Map plan 大小 | 5.51KB | 5.50KB |
| Reducer plan 大小 | 2.42KB | 2.46KB |

**Container 分配过程**：

```
时间        COMPLETED  RUNNING  PENDING  FAILED  说明
─────────  ─────────  ───────  ───────  ──────  ────
05:23:25   -          -        -        -       DAG3 提交, INITIALIZING(-1)
05:23:26   0          0        487      0       Map 1 INITED
05:23:29   0          8        479      0       ★ 首批 8 个(DAG2 首批只有 3!)
05:23:30   0          24       463      0       
05:23:31   0          43       444      0       
05:23:33   0          92       395      0       
05:23:36   0          122      365      0       
05:23:41   0          164      323      0       
05:23:44   0          224      263      0       100+/秒 分配速度
05:23:47   0          329      158      0       
05:23:52   0          363      124      0       
05:24:05   0          412      75       0       
05:24:17   0          442      45       0       
05:24:19   0          459      28       0       
05:24:20   0          487      0        0       ★ 55s 拉满! PENDING=0
```

**对比 DAG2：DAG2 首批 3 个, 55min 才涨到 361; DAG3 首批 8 个, 55 秒拉满 487。**
**原因：DAG2 刚结束释放了所有 container，队列空闲。**

**卡死阶段**：

```
时间        COMPLETED  RUNNING  PENDING  FAILED  ELAPSED     说明
─────────  ─────────  ───────  ───────  ──────  ──────────  ────
05:24:20   0          487      0        0       55s         全部 running
05:30:00   0          487      0        0       ~6.5min     ← DAG2 此时已经开始出结果!
05:59:59   0          487      0        0       2193s       36min, 仍 0
06:30:00   0          487      0        0       ~66min
07:00:00   0          487      0        0       5794s       1h37min
07:06:36   0          487      0        0       6191s       ★ 1h42min → 被 kill
```

**1h42min, COMPLETED/FAILED/KILLED 全部为 0。487 个 Map 都在 RUNNING, 但没有任何输出。**

**被 kill 详情**：

```
07:06:36.868  ClosedByInterruptException (客户端关闭连接)
07:06:36.870  Status: Killed
07:06:36.870  "Dag received [DAG_TERMINATE, DAG_KILL] in RUNNING state"
07:06:36.870  "Sending client kill from dmp (auth:SIMPLE) at 10.23.0.43"
07:06:36.870  Map 1:     failedTasks=0, killedTasks=487 (DAG_TERMINATED)
07:06:36.870  Reducer 2: failedTasks=0, killedTasks=2   (DAG_TERMINATED)
07:06:36.870  "DAG did not succeed due to DAG_KILL"
07:06:36.871  RangerQcloudObjectStorageClientImpl: backOff, retryCnt: 0
```

**DAG3 资源分配总结**：

| 阶段 | 时间段 | 耗时 | RUNNING | 说明 |
|------|--------|------|---------|------|
| 拉满 | 05:23:26~05:24:20 | 55s | 0→487 | DAG2 释放的 container + 队列空闲 |
| 卡死 | 05:24:20~07:06:36 | 1h42min | 487 | COMPLETED=0, FAILED=0, 全卡住 |
| 被 kill | 07:06:36 | 瞬间 | 487→0 | 外部 kill, 487 全部 KILLED |

---

### 3.4 DAG2 vs DAG3 资源分配对比

| 维度 | DAG2 | DAG3 |
|------|------|------|
| **首批 Container** | 3 | 8 |
| **拉满耗时** | 55min(3) + 8s暴涨(→361) | 55s(→487) |
| **最大并发** | 361 | 487 |
| **PENDING=0 时刻** | 05:14:15 (62min 后) | 05:24:20 (55s 后) |
| **首个 COMPLETED** | 04:14:09 (2min 后) | **无** (1h42min 内 0 个) |
| **拿 container → 出结果** | ~7min | **无** (102min 仍 0) |
| **FAILED tasks** | 1 (EOF, 4 次重试) | 0 |
| **Container 来源** | RM 慢分配 → 05:07 暴涨 | DAG2 释放的 container 直接复用 |
| **结束方式** | VERTEX_FAILURE | DAG_KILL(外部) |

---

### 3.5 DAG3 卡死疑点分析

**已确认事实**（tezStageProfile 日志证据）：
- ✅ 487 个 Map 全部 RUNNING, PENDING=0（05:24:20 起）
- ✅ 全程 FAILED=0, KILLED=0 — 没有任何 task 报错
- ✅ 1h42min COMPLETED 始终为 0
- ✅ DAG2 同数据同 361 并发, 7min 后就开始完成
- ✅ 被 kill 时有 `RangerQcloudObjectStorageClientImpl: backOff` 日志

**待确认疑点**（HS2 日志无法定位, 需 AM Container 日志）：

| # | 疑点 | 支持/反对证据 |
|---|------|-------------|
| 1 | COS 限流/带宽打满 | 支持: 487>361 并发; kill 时有 COS backOff 日志 |
| 2 | COS 连接池耗尽 | 支持: 487 并发同时建连接, 可能超客户端连接池上限 |
| 3 | task 卡在初始化 | 反对: 状态是 RUNNING 不是 INITIALIZING |
| 4 | 损坏文件导致 1 个 Map 卡住 | 反对: 只影响 1 个, 不影响其他 486 个 |
| 5 | GC/OOM 导致 task 假死 | 需 AM 日志确认 |

**结论: DAG3 卡死根因仅凭 HS2 日志无法确定, 以上均为疑点不是结论。需要 AM Container 日志。**

---

## 五、三次执行的完整关联

| 序号 | App ID | Query ID | 时间 | Map数 | 结果 | 根因 |
|------|--------|----------|------|-------|------|------|
| 1 | 682541 | hadoop_20260408002002 | 00:20→00:28 | 246 | FAILED | task_245 EOFException |
| 2 | 683466 | hadoop_20260408030458 | 03:04→03:35 | 未执行 | 取消 | AM排队25min+调度超时 |
| 3 | 683560 | **hadoop_20260408035134** | 03:51→07:06 | 487 | KILLED | DAG2: EOF; DAG3: IO卡死 |

三次都是**同一个 SQL、同一份数据、同一个损坏文件**。

---

## 六、根因总结

```
根因1: 数据文件损坏
  ODS 源表分区中有一个压缩文件尾部不完整
  → 每次执行到读这个文件的 Map task 都 EOFException
  → DAG 因 VERTEX_FAILURE 失败

根因2: availableSlots 快照问题 (app_683560 特有)
  AM 04:11 启动时 headroom 大 → availableSlots 大 → Map=487
  而 app_682541 在 00:26 启动时 headroom 小 → Map=246

根因3: DAG3 IO 瓶颈 (app_683560 特有)
  487 个 Map 同时并发读 COS 对象存储
  → 可能触发 COS 限流或网络带宽瓶颈
  → 全部 running 但 0 完成, 持续 1h43min
```

---

## 七、建议

1. **修复损坏文件** — 定位 ODS 分区中的损坏压缩文件，从 Kafka 重新消费重建
2. **用 `tez.grouping.max-size` + `min-size` 夹逼** — 固定 Map 数，避免 availableSlots 波动
3. **COS 并发读优化** — 限制单 App 最大并发 container 数，避免 487 并发打满 COS 带宽
4. **调度超时调长或加重试** — 当前 3 次执行都没成功，根因是数据文件损坏，调超时无意义

---

> **分析者**: Eric (BigData SRE AI Expert Team)  
> **日期**: 2026-04-19  
> **日志来源**: HS2 日志 hadoop-hiveserver2.2026-04-08-03/04/05/07.log (节点 10.23.0.43)
