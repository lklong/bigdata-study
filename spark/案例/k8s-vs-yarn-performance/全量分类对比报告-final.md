# K8s vs YARN Spark 任务执行对比报告

> **SQL**: `SELECT ... FROM info_cungong.view_cinfo_dayinc WHERE content rlike '蝴蝶的眼泪是白色的' AND status in (201) ...`
> **数据量**: 12.4TB, 34,466 Tasks, 153 分区, 100 Executors (1core/2560M)
> **基准**: YARN application_1760404906372_12173904, Job 3 = 4094s
> **总计**: 14 个应用 (1 YARN + 13 K8s), 跨 4/7, 4/14, 4/15 三天

---

## 一、YARN 基准

| 项目 | 值 |
|------|-----|
| App ID | application_1760404906372_12173904 |
| 平台 | YARN on EMR |
| 日期 | 2026-04-07 13:25 |
| **Job 3 耗时** | **4094s** |
| Task avg / p50 / p99 / max | 11.7s / 11.4s / 19.7s / 34.6s |
| CPU avg / 总量 | 3.9s / 37.0h |
| GC 占比 | 1.6% |
| Executors | 102 |
| cosn.impl | NativeCosFileSystem |
| read.ahead | 2MB |
| JDK | 1.8.0_282 (Tencent) |
| Driver IP | 10.126.144.96 |
| Executor 节点 | 10.106.24.x, 10.106.25.x, 10.126.144.x, 10.126.145.x |
| 异常 | 无 ERROR。Job 结束后 DRA 正常回收全部 Executor |

---

## 二、K8s TemrfsHadoopFileSystemAdapter 组（默认配置，比 YARN 慢）

按日期排序：

| # | App ID | 日期 | Job 3 耗时 | vs YARN | Task avg | CPU avg | GC% | Exec | Driver IP | 节点段 | 异常情况 |
|---|--------|------|-----------|---------|----------|---------|-----|------|-----------|--------|---------|
| 1 | 171a31c6 | 4/7 13:29 | 4420s | 慢 326s (8.0%) | 12.7s | 4.0s | 1.8% | 100 | cql-test-ds-a513c39d-driver-svc | 10.127.37, 10.127.40 | 无 ERROR |
| 2 | 2f7380f0 | 4/14 12:25 | 4441s | 慢 347s (8.5%) | — | — | — | 100 | 10.127.42.97 | — | 无 ERROR |
| 3 | 769606ae | 4/14 14:13 | 4520s | 慢 425s (10.4%) | — | — | — | 100 | 10.127.40.162 | — | ERROR: COS HttpClient 超时 |
| 4 | 834aa7f7 | 4/14 15:39 | 4521s | 慢 426s (10.4%) | — | — | — | 100 | 10.127.41.164 | — | WARN: Exec-47 心跳超时移除 |
| 5 | 264048 | 4/14 17:03 | 4435s | 慢 341s (8.3%) | — | — | — | 100 | 10.127.41.139 | — | 无 ERROR |
| 6 | 494dd578 | 4/14 18:18 | 4273s | 慢 178s (4.4%) | — | — | — | 100 | 10.127.37.5 | — | 无 ERROR |
| 7 | d87771f2 | 4/14 20:00 | 4412s | 慢 318s (7.8%) | 12.7s | 3.3s | 2.0% | 100 | cql-test-ds-5e77129d-driver-svc | 10.127.37~42 | WARN: Exec-5 心跳超时移除 |

**本组统计**:
- 应用数: 7
- 平均 Job 3: **4432s**, 比 YARN 慢 **338s (8.3%)**
- 范围: 4273s ~ 4521s (极差 248s)
- cosn.impl: `com.qcloud.emr.fs.TemrfsHadoopFileSystemAdapter` (EMR 封装层)
- read.ahead: 未配置
- 共性异常: 3 个应用有 Executor 心跳超时移除; 1 个 COS HttpClient 超时

---

## 三、K8s NativeCosFileSystem 组（手动切换 cosn.impl）

按日期排序：

| # | App ID | 日期 | Job 3 耗时 | vs YARN | Task avg | CPU avg | GC% | Exec | read.ahead | Driver IP | 节点段 | 异常情况 |
|---|--------|------|-----------|---------|----------|---------|-----|------|------------|-----------|--------|---------|
| 1 | 5c994d54 | 4/14 22:08 | 3907s | 快 187s (4.6%) | 11.3s | 3.3s | 2.1% | 100 | **有(2MB)** | cql-test-1960b49d-driver-svc | 10.127.37~42 | 无 ERROR |
| 2 | 6a0f0273 | 4/14 ~23:30 | ~4020s | 快 74s (1.8%) | — | — | — | 100 | **有(2MB)** | — | — | 无 Driver 日志 |
| 3 | f8d69dea | 4/15 15:44 | **4643s** | **慢 549s (13.4%)** | **13.4s** | **4.3s** | 2.3% | 100 | 无 | cql-test-ds-fb87b659-driver-svc | **10.127.40 为主** | **WARN: Exec-37 心跳超时 137939ms** |
| 4 | 744c908b | 4/15 17:33 | 4036s | 快 58s (1.4%) | 11.7s | 3.1s | 2.1% | 100 | 无 | cql-test-ds-46e6fad4-driver-svc | 10.127.37~45 | ERROR: COS HttpClient 超时(任务结束后清理阶段) |
| 5 | eb182010 | 4/15 20:22 | 4143s | 慢 49s (1.2%) | 12.0s | 3.2s | 2.1% | 100→99 | 无 | cql-test-ds-beb35996-driver-svc | 10.127.37~45 | **WARN: Exec-78 心跳超时 151036ms 被移除; ERROR: COS HttpClient 超时; WARN: MetaStoreClient 连接丢失** |
| 6 | 0408ee0e | 4/15 21:40 | 4030s | 快 64s (1.6%) | 11.6s | 3.2s | 2.1% | 100 | 无 | cql-test-ds-46e6fad4-driver-svc | 10.127.37~45 | 无 ERROR |

**本组统计**:
- 应用数: 6
- cosn.impl: `org.apache.hadoop.fs.cosnative.NativeCosFileSystem`
- 有 read.ahead 的 (5c99, 6a0f): 平均 **3964s**, 比 YARN 快 **130s (3.2%)**
- 无 read.ahead 的 (去掉异常 f8d69): 平均 **4070s**, 与 YARN 基本持平 (慢 24s, 0.6%)
- f8d69 异常: **4643s**, 比 YARN 慢 **549s (13.4%)** — 原因见下方分析

---

## 四、异常任务分析

### f8d69 — 比 YARN 慢 549s (13.4%)

| 项目 | f8d69 | 744c (正常参照) |
|------|-------|-----------------|
| Job 3 | 4643s | 4036s |
| Task avg | 13.4s | 11.7s |
| CPU avg/task | **4.3s** | **3.1s** |
| CPU 总量 | **41.4h** | **30.0h** |
| GC avg | 308ms | 247ms |
| 主要节点段 | **10.127.40.x (集中)** | 10.127.37~45 (分散) |

**根因**: f8d69 被 K8s 调度到 `10.127.40.x` 节点池为主，该节点池 CPU 算力弱。全部 101 个 Executor 的 CPU 均匀偏高（4.0~4.7s），不是个别 Executor 问题。Exec-37 在运行 1 小时后因心跳超时 137939ms 被移除。

### Executor 心跳超时汇总

| App ID | 被移除 Executor | 超时时长 | 影响 |
|--------|----------------|---------|------|
| d87771f2 | Exec-5 | 166000ms | 轻微 |
| 834aa7f7 | Exec-47 | 172007ms | 轻微 |
| f8d69dea | Exec-37 | 137939ms | 轻微 |
| eb182010 | Exec-78 | 151036ms | Job 3 多耗约 49s |

### COS HttpClient 超时

| App ID | 时间 | 说明 |
|--------|------|------|
| 769606ae | 4/14 15:37 | COS HTTP 请求超时 |
| 744c908b | 4/15 18:57 | 任务结束后清理阶段超时，不影响 Job 3 |
| eb182010 | 4/15 21:38 | 任务结束后清理阶段超时，不影响 Job 3 |

### MetaStoreClient 连接丢失

| App ID | 时间 | 说明 |
|--------|------|------|
| eb182010 | 4/15 20:21 | HMS 连接断开后自动重连成功，不影响 Job 3 |

---

## 五、汇总对比

| 配置组 | cosn.impl | read.ahead | 应用数 | 平均 Job 3 | vs YARN | 范围 |
|--------|-----------|------------|--------|-----------|---------|------|
| **YARN (基准)** | NativeCosFileSystem | 2MB | 1 | **4094s** | 基准 | — |
| **K8s NativeCosFS + readahead** | NativeCosFileSystem | 2MB | 2 | **3964s** | 快 130s (3.2%) | 3907~4020s |
| **K8s NativeCosFS 无 readahead** | NativeCosFileSystem | 无 | 3* | **4070s** | 慢 24s (0.6%) | 4030~4143s |
| **K8s NativeCosFS 异常 (f8d69)** | NativeCosFileSystem | 无 | 1 | **4643s** | 慢 549s (13.4%) | 慢节点池 |
| **K8s TemrfsAdapter (默认)** | TemrfsHadoopFileSystemAdapter | 无 | 7 | **4432s** | 慢 338s (8.3%) | 4273~4521s |

> *去掉 f8d69 异常值

---

## 六、结论

1. **K8s 默认配置 (TemrfsHadoopFileSystemAdapter) 比 YARN 慢 8.3%** — EMR 封装层引入额外 I/O 开销
2. **切换到 NativeCosFileSystem 后与 YARN 基本持平** (慢 0.6%) — 消除了封装层开销
3. **加上 readahead=2MB 后比 YARN 快 3.2%** — K8s 更新 JDK (Kona 472 vs 282) 的优势体现
4. **K8s 存在节点算力不均风险** — f8d69 因调度到弱 CPU 节点池，比 YARN 慢 13.4%
5. **Executor 心跳超时是共性问题** — 4 个应用出现 Executor 被移除，超时 137~172s (阈值 120s)
