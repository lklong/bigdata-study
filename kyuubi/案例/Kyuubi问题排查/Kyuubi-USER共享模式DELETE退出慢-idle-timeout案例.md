# Kyuubi USER 共享模式下 DELETE 跑完后 engine 退出慢案例

## 一、问题概述

| 字段 | 值 |
|---|---|
| **现象** | 用户提交一条 Iceberg DELETE，SQL 6~7s 内执行完成，但 Kyuubi engine 还要再等 ~6 分钟才真正退出 |
| **业务感知** | "DELETE 怎么这么慢？怎么客户端都断了，driver pod 还不退？" |
| **真实根因** | DELETE 不慢；engine 跑在 **USER 共享模式**，session 关闭后还要等满 `kyuubi.session.engine.idle.timeout`（默认 5 分钟）才主动 stop，是**设计行为**不是 bug |
| **结论** | 不需要修；如要消除等待，改 share level 为 `CONNECTION` 或缩短 idle timeout |

---

## 二、环境信息

| 项 | 值 |
|---|---|
| 部署 | Spark 3.3.2 on K8s（cluster mode）+ Kyuubi 1.9.4 engine |
| 表 | `iceberg.ods_prod_v1.op_parser` ，存储 COSN，HiveCatalog |
| 表规模（DELETE 前） | 56 万+ 数据文件 / 87 万 partition / 515 亿行 / ~101 TB |
| Spark 资源 | driver 1c/16g + 2 executor × (2c/1g) |
| Kyuubi engine 共享模式 | **USER**（关键） |
| `kyuubi.session.engine.idle.timeout` | 默认 300000 ms = 5 min |
| 分析对象 | 同一用户、同一 SQL 模板的两次任务 driver/executor stderr.log |

样本任务：

| 任务 | application id | DELETE 谓词 |
|---|---|---|
| A | `spark-470139f20d4340c19be448bb65e0b4ba` | `block_section = '0-50'` |
| B | `spark-5c9f760328144fed924eb0990834ea65` | `block_section = '50-100'` |

---

## 三、时间线（任务 A 为例，任务 B 同构）

| 时刻 | 事件 |
|---|---|
| 16:23:03 | spark-submit 启动 |
| 16:23:42 | Kyuubi engine 服务起齐，注册到 ZK 节点 `/kyuubi_1.9.4_USER_SPARK_SQL/zhengyuhong/default/...` |
| 16:23:43.151 | DELETE 进入 `RUNNING_STATE` |
| 16:23:49.859 | DELETE `FINISHED_STATE`，**time taken: 6.705 s** |
| 16:23:50.117 | session 关闭，`current opening sessions 0` |
| 16:23:50 ~ 16:28:42 | **空转 4 分 52 秒**（只有 Ranger UserRefresher 每 3s 一次 404 噪声） |
| 16:28:42.652 | `SparkSQLSessionManager-timeout-checker` 第一次扫描，count=0 开始计时 |
| 16:29:42.723 | **`Idled for more than 300000 ms, terminating`** ← 触发 stop |
| 16:29:42.724 ~ 16:29:53.890 | stop 串行（注销 ZK → 停 Frontend/Backend → 停 SparkContext → ShutdownHook → 关 COSN），共 ~11 s |

**核心比例**：DELETE 实跑 6.7s，session 关闭到进程退出 ~6m4s，其中 5m52s 是 idle 等待，11s 是 stop 串行。

---

## 四、关键证据：share level = USER

### 4.1 ZK 节点路径

driver 日志（任务 A 第 326 行 / 任务 B 同位置）：

```
Created a /kyuubi_1.9.4_USER_SPARK_SQL/zhengyuhong/default/serverUri=...
```

Kyuubi engine 在 ZK 上的命名规则：

```
/kyuubi_<version>_<SHARE_LEVEL>_<ENGINE_TYPE>/<user>/<subdomain>/...
```

路径里 `_USER_SPARK_SQL` 这一段直接说明 share level = **USER**。

### 4.2 Engine banner

driver 日志 banner 段：

```
Spark application name: job_20260515063026259_2026-05-18T16:20:06+08:00
...
User: zhengyuhong (shared mode: USER)
```

### 4.3 ZK 注销日志（USER 模式特征）

```
This Kyuubi instance 10.16.33.76:42735 is now de-registered from ZooKeeper.
The server will be shut down after the last client session completes.
```

这句"The server will be shut down after the last client session completes"是共享模式（USER/GROUP/SUBDOMAIN/SERVER）的退出路径标志；**CONNECTION 模式不会打这句**——CONNECTION 模式 session 一关 engine 立刻 stop，没有"等 last session"的概念。

### 4.4 share level 五档对照

| 取值 | 复用范围 | engine 何时退出 |
|---|---|---|
| `SERVER` | 整个 Kyuubi server 共享 | 几乎不退 |
| `GROUP` | 同 group / 租户共享 | idle timeout 后 |
| **`USER`** | **同一 OS 用户共享** | **idle timeout 后（默认 5min）** ← 本案例 |
| `CONNECTION` | 一个 JDBC 连接独占 | session 关闭立刻退 |
| `SUBDOMAIN` | 同 user + 同 subdomain 共享 | idle timeout 后 |

---

## 五、DELETE 性能分项（顺手归档，证明 SQL 自身不慢）

DELETE 走 Iceberg `OptimizeMetadataOnlyDeleteFromIcebergTable` 优化 → metadata-only delete，**不读数据文件，executor 没参与**。

任务 A 的 7 段拆分（共 6.705s）：

| 阶段 | 耗时 | 说明 |
|---|---|---|
| HMS 连接 + loadTable | ~0.45s | 拿表元信息 |
| 刷新当前 metadata.json | ~0.65s | 读 `05076-….metadata.json` |
| 规则识别 + 改写 | ~0.25s | 命中 metadata delete |
| **planFiles：扫 90 个 manifest** | **~1.42s** | `totalDataManifests=90`，候选 `resultDataFiles=563419` |
| 写新 manifest avro（8.36 MB） | ~2.13s | COSN 单流上传 |
| 写 snap-*.avro（9.5 KB） | ~0.08s | |
| 写新 metadata.json（4.83 MB） | ~0.17s | |
| **HMS commit** | **~0.39s** | `Successfully committed in 610 ms` |
| 刷新 + 收尾 | ~0.30s | 输出 CommitReport |

CommitReport（任务 A）：

| 指标 | 值 |
|---|---|
| removedDataFiles | 300 |
| removedRecords | 59 594 315（≈5960 万行） |
| removedFilesSizeInBytes | ≈ 110 GB |
| totalDataFiles（删后） | 563 119 |
| totalRecords（删后） | 51 543 510 535（≈515 亿行） |

任务 B 几乎同分布（删 300 文件 / 5813 万行 / 108 GB），DELETE 耗时 7.289 s（commit 多耗 0.5s，从 610ms→1092ms），完全在抖动范围内。

**结论**：56 万数据文件 / 515 亿行规模下，metadata-only delete 6~7s 是健康水平，无需优化。

---

## 六、退出阶段拆解（11s stop 串行）

任务 A：

| 子阶段 | 起止 | 耗时 | 性质 |
|---|---|---|---|
| 注销 ZK + 停 Frontend | 16:29:42.724 → 42.748 | ~24 ms | 健康 |
| Service[OperationManager/SessionManager] stopped | 16:29:42.742 | <10 ms | 健康 |
| **空白：BackendService.stop 静默** | **16:29:42.742 → 52.745** | **~10 s** | ⚠️ 见下文 |
| Service[SparkSQLEngine] stopped | 16:29:52.746 | | |
| Stop SparkUI / Shutdown executors | 16:29:52.756 → 52.759 | <5 ms | |
| `Kubernetes client has been closed` (WARN) | 16:29:52.765 | | 正常 |
| 写 EventLog 到 COSN | 16:29:53.073 → 53.171 | ~100 ms | 上传 208 KB |
| Stop MapOutputTracker / BlockManager / OutputCommitCoordinator | 16:29:53.844 → 53.871 | ~30 ms | |
| `Successfully stopped SparkContext` | 16:29:53.871 | | |
| ShutdownHook（清理 /tmp、/var/data、关闭 COSN BufferPool） | 16:29:53.876 → 53.890 | ~14 ms | |

**这 10s 静默是 Spark 自身关闭 dispatcher / netty 线程池的常态延迟**（`SparkSQLBackendService.stop` 内部等 awaitTermination），不是 bug。任务 B 这段也是精确的 ~10s，可重现。

---

## 七、A/B 两次任务对比（同条件 = 同退出时长）

| 指标 | 任务 A | 任务 B | 差异 |
|---|---|---|---|
| DELETE 耗时 | 6.705 s | 7.289 s | +0.58 s（commit 抖动）|
| session 关闭 → timeout-checker terminating | **5m52s** | **5m51s** | 1 s |
| BackendService.stop 静默 | **10.00 s** | **10.00 s** | 0 |
| session 关闭 → 进程退出 | **6m3.8s** | **6m2.2s** | 1.6 s |

**结论**：USER 共享模式下，同样的 idle timeout 配置 → 退出时长完全一致，没有差异。

如有"感知差异"，常见来源：

1. **端到端总耗时**包括了冷启动差异（任务 A 总 6m50s / 任务 B 总 6m31s，差 19s 来自冷启动 + 噪声日志多寡），**不是退出阶段**
2. **timeout-checker 调度对齐抖动**：checker 每 60s 扫一次，`session 关闭时刻` 与 `下一次 tick` 之间有 0~60s 错位，所以同配置下实测 idle 等待会在 5m0s ~ 6m0s 间随机
3. ZK 上 engine 的 de-register 在 idle timeout 触发那一刻就完成（A: 16:29:42.733 / B: 16:45:58.630），后续 11s 进程清理已经不阻塞新任务调度——业务方如果是看 Kyuubi server 端 engine 列表，"消失"时间比"进程退出"时间早 11s

---

## 八、修复建议（按收益从高到低）

| # | 方案 | 命令 / 配置 | 收益 | 代价 |
|---|---|---|---|---|
| 1 | 一次性 batch 任务改 CONNECTION 模式 | `--conf kyuubi.engine.share.level=CONNECTION` | session 关闭立刻 stop，省 5min idle | 后续 SQL 不能复用 engine，每次冷启动 ~36s |
| 2 | 保持 USER 共享但缩短 idle timeout | `--conf kyuubi.session.engine.idle.timeout=PT60S`（甚至 PT10S） | 5min → 1min | 相邻 SQL 命中复用率下降 |
| 3 | 缩短 timeout-checker 周期 | `kyuubi.session.engine.check.interval`（默认 60s 调到 10s） | 消除 0~60s 调度抖动 | 极少量 CPU |
| 4 | stop 那 10s 静默 | — | — | 不用动，Spark 内部行为 |

---

## 九、附带问题（同日志里的脏数据，与本案例正交）

| 项 | 表现 | 建议 |
|---|---|---|
| `zhengyuhong` 在 driver/executor 镜像 OS 上找不到 | `id: zhengyuhong: no such user`，每次 group 解析抛 `PartialGroupNameException` 长栈 | 把用户加到镜像 /etc/passwd 或 SSSD，消除栈日志 |
| Ranger `UserRefresher(serviceName=USERSYNC)` 每 3s 打 404 | driver 日志 ~40% 行是这条 WARN | 把 logger `org.apache.ranger.plugin.util.UserRefresher` / `RangerAdminRESTClient` 调到 ERROR；或在 Ranger admin 起空 USERSYNC service |
| Ranger 多个二级配置文件加载失败 | `ranger-spark-policymgr-ssl.xml`、`ranger-spark-hive-*.xml` 等启动期 4 行 ERROR | 不用就移除引用；要用就补全 |
| 表 `op_parser` 56 万 datafile / 87 万 partition | 已属 Iceberg 大表预警线 | 周期性 `rewrite_manifests` + `expire_snapshots`，巡检分区设计 |

---

## 十、原始日志关键锚点（任务 A）

| 行号 | 关键内容 |
|---|---|
| 326 | `_USER_SPARK_SQL` ← share level 直接证据 |
| 346 | banner: `User: zhengyuhong (shared mode: USER)` |
| 350-351 | DELETE 进入 RUNNING + 完整 SQL |
| 366 | metadata-only delete 优化命中 |
| 373 | ScanReport（90 manifest / 563419 datafile / 1.4s planning） |
| 374 | UnknownPartitioning 874119 partitions |
| 389-390 | HMS commit 成功 + `Successfully committed in 610 ms` |
| 393 | CommitReport（删 300 文件 / 5959 万行） |
| 395 | DELETE FINISHED + `time taken: 6.705 seconds` |
| 399-402 | session close |
| 597 | timeout-checker 首次扫描 count=0 |
| 639 | `Idled for more than 300000 ms, terminating` |
| 642 | `de-registered from ZooKeeper. The server will be shut down after the last client session completes` |
| 660-675 | stop 串行全过程 |
| 687-694 | ShutdownHook 清理本地目录 + COSN BufferPool |

— eric
