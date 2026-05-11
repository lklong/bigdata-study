# 专项预案：tdata_sync (Flink 1.13.1) NM 关机下线操作

> **作业标识**：`application_1763473707704_1214`
> **Flink 版本**：**1.13.1**（⚠️ 已知 Bug 版本）
> **作业类型**：数据同步（tdata_sync，CDC/ETL 类）
> **HA 存储**：`cosn://zt-bigdata-emr-online-1256037416/tools/flink1131/tdata_sync/ha/`
> **关联 SOP**：[../../yarn/案例/SOP-NM节点关机-Flink作业零影响操作手册.md](../../yarn/案例/SOP-NM节点关机-Flink作业零影响操作手册.md)
> **作者**：eric ｜ **版本**：v1.0 / 2026-05-11

---

## 0. TL;DR（30 秒决策）

> **这是一个 Flink 1.13.1 的数据同步作业，不能走 HA 自恢复路径，必须 Savepoint。** 直接关机会踩到 FLINK-22483 / 22646 / 23456 三个已知 Bug 中的一个。
>
> **🔴 更糟的是**：`yarn.application-attempts=0` + `yarn.resourcemanager.am.max-attempts=0`，**HA 容灾能力基本失效**（详见 § 2.3）。**绝对禁止**依赖 HA 自恢复。
>
> **🟡 且**：这是 **DP 平台托管**作业（`dp-beaver-master-QF64y0ti.jar`），**必须通过平台操作**，不能直接动 YARN（详见 § 2.4）。

**执行顺序**：

```
① 预检（5min，含 max-attempts 验证）
② 【协调 DP 平台】暂停自动拉起
③ 【通过平台】Savepoint + 停止作业
④ 隔离调度（refreshNodes 不加 -g）
⑤ 停 NM → 关机
⑥ 节点上线后【通过平台】从 SP 恢复（先改 application-attempts=10）
```

---

## 1. 作业画像

| 维度 | 信息 | 备注 |
|---|---|---|
| YARN AppID | `application_1763473707704_1214` | Application Mode |
| Flink 版本 | 1.13.1 | ⚠️ 已知多个 CK/HA Bug |
| 部署模式 | YARN Application Mode（推断） | cluster-id = AppID |
| HA 类型 | ZooKeeper | quorum: `10.117.201.59:2181, .39:2181, .111:2181` |
| HA 存储 | COS（`cosn://`） | 最终一致性 + 延迟比 HDFS 高 |
| ZK ACL | `open` ⚠️ | 安全隐患，任何人可改 HA 元数据 |
| 作业名 | `dp-beaver-master-QF64y0ti.jar` | **DP 数据平台托管**，带平台 Task ID |
| 队列 | `beaver` | |
| **AM 重试** | `yarn.application-attempts = 0` ⚠️🔴 | **HA 容灾能力基本失效**，详见 § 2.3 |
| **RM 重试上限** | `yarn.resourcemanager.am.max-attempts = 0` ⚠️🔴 | 同上 |
| 失败窗口 | `attempt-failures-validity-interval = 600000`（10min）| ✅ 合理 |
| 作业语义 | tdata_sync（数据同步） | 对数据一致性敏感，丢/重数据影响大 |

---

## 2. 为什么这个作业必须特殊对待

### 2.1 三大"不走 HA 自恢复"的理由

#### 理由 1：FLINK-22483 — CK 超时后状态不一致
- 1.13.1 的 CK Coordinator 在 CK 超时路径上有竞态
- 表现：JM 标记 CK 超时 → TM 实际上 CK 已完成 → HA 元数据和 State 不一致
- **NM 关机触发的 Failover 正好命中这条路径的概率很高**

#### 理由 2：FLINK-22646 — RocksDB 增量 CK 元数据损坏
- tdata_sync 作业大概率用 RocksDB + 增量 CK（大状态场景标配）
- 1.13.1 的增量 CK 在 JM 重启时元数据引用可能断链
- 表现：新 JM 起来后从 CK 恢复 → `FileNotFoundException: shared/xxx.sst`

#### 理由 3：TM 复用不稳定
- 1.13 的 `resourcemanager.taskmanager-timeout` 行为不如 1.17+
- JM 切换时，老 TM 有较大概率被新 JM 拒绝注册 → 全部重建
- **叠加 COS LIST 延迟**，恢复时间可能拉到 5~10 分钟

### 2.2 一张表对比"直接关机" vs "Savepoint 迁移"

| 维度 | 直接关机（HA 自恢复） | Savepoint 迁移（推荐） |
|---|---|---|
| 中断时间 | 10~15 分钟 | 3~5 分钟（可控）|
| 数据一致性 | ⚠️ 有丢失/重复风险（FLINK-22483）| ✅ 0 丢失 0 重复 |
| 恢复失败概率 | 中（踩 1.13 Bug 10%+）| 极低 |
| 可观测性 | 低（Failover 过程不透明）| 高（SP 路径可见）|
| 回滚难度 | 难（HA 元数据已被新 AM 覆盖）| 容易（SP 文件保留）|

### 2.3 🔴 额外致命项：AM 重试配置失效

```properties
yarn.application-attempts                = 0     ⚠️ 字面值为 0
yarn.resourcemanager.am.max-attempts     = 0     ⚠️ RM 级别上限也为 0
```

**影响分析**：

HA 机制依赖链：`AM 挂 → YARN 重拉新 Attempt → 新 AM 从 ZK/HA 存储恢复 → 作业继续`

如果 `max-attempts = 0` 被严格解释：
- **AM 挂了就彻底 FAILED**，YARN 不会拉新 Attempt
- 配置里的 `high-availability=zookeeper` 完全用不上
- **HA 链路第一环就断了**

如果被当作"用集群默认值"处理（部分版本会）：
- 回退到默认 2（或集群设定值），比合理配置（10）差很多
- 稍微多几次 Failover 就触顶，作业永久 FAILED

**结论**：无论哪种解读，**不能依赖 HA 自恢复**，必须走 Savepoint 路径。

**紧急验证方法**：

```bash
APP_ID=application_1763473707704_1214

# 方法 1：RM REST API 看实际生效值（最准）
curl -s "http://<rm-host>:8088/ws/v1/cluster/apps/$APP_ID" | \
  python -m json.tool | grep -iE "maxAppAttempts"

# 方法 2：yarn 命令看已用次数
yarn applicationattempt -list $APP_ID

# 方法 3：RM 日志
grep "$APP_ID" /var/log/hadoop-yarn/yarn-*-resourcemanager-*.log | \
  grep -iE "maxAppAttempts" | head
```

**配置修复建议**（恢复作业前必做）：

```yaml
# 作业侧 flink-conf.yaml 或 -D 参数
yarn.application-attempts: 10
# yarn.resourcemanager.am.max-attempts 不建议在作业侧覆盖，让它用集群默认
# 如果必须设，应 >= 10
```

### 2.4 🟡 额外项：DP 平台托管作业

作业名 `dp-beaver-master-QF64y0ti.jar` 显示这是 **DP 数据平台**托管的作业：
- `QF64y0ti` 是平台生成的 Task ID
- 平台侧可能有**自动拉起策略**（作业 FAILED 自动重提）
- 直接 `yarn application -kill` 会导致平台状态不一致

**操作规范**：
1. **必须通过 DP 平台界面操作**，不要直接动 YARN
2. 关机窗口期前，在平台侧**暂停自动拉起**
3. 平台确认作业已停 + 不会自动拉起 → 再动 NM
4. 恢复时也走平台，不要 `flink run` 手工提交（会脱管）

---

## 3. 预检清单（必做）

### 3.1 作业当前状态

```bash
APP_ID=application_1763473707704_1214

# [1] 作业是否 RUNNING
yarn application -status $APP_ID | grep -E "State|Final-State|Progress"
# 期望：State: RUNNING, Final-State: UNDEFINED, Progress: 100%

# [2] AM 在哪个节点（核心！决定是否必须迁移 AM）
yarn application -status $APP_ID | grep -E "AM Host|Tracking-URL"

# [3] Attempt 编号（看是否已经多次重试过）
yarn applicationattempt -list $APP_ID
# 如果看到 _03 / _04 → 作业已不稳定，关机前先排查

# [4] 所有 Container 分布
LATEST_ATTEMPT=$(yarn applicationattempt -list $APP_ID | grep -oE "appattempt_[0-9_]+" | tail -1)
yarn container -list $LATEST_ATTEMPT
# 对比 LOG-URL 里的 host 和待关机节点列表

# [5] 🔴 实际生效的 AM 最大重试次数（本作业特别重要）
RM_HOST=<your-rm-host>
curl -s "http://$RM_HOST:8088/ws/v1/cluster/apps/$APP_ID" | \
  python -m json.tool | grep -iE "maxAppAttempts"
# 如果返回 0 或 1 → ⚠️ 必须走 Savepoint，禁止任何可能触发 AM 重启的操作
# 如果返回 >= 5 → 相对安全，但仍建议走 Savepoint
```

### 3.2 Checkpoint 健康检查（1.13 专项）

```bash
# [1] 从 JM 日志确认最新 CK 状态（只看文件不够，1.13 有元数据和实际状态不一致的 Bug）
yarn logs -applicationId $APP_ID -log_files jobmanager.log | \
  grep -E "Completed checkpoint|Checkpoint.*failed|Checkpoint.*expired" | tail -30

# 期望：最近 3 次都是 "Completed checkpoint"
# 如果看到最近有 "failed" 或 "expired" → 关机前必须先解决
# 如果看到 "Decline checkpoint" → TM 端拒绝，状态可能不一致

# [2] 检查 RocksDB 增量 CK 警告
yarn logs -applicationId $APP_ID -log_files jobmanager.log | \
  grep -iE "incremental|rocksdb.*warn|state.*corrupt|FileNotFoundException.*sst" | tail -20
# 任何命中都说明有潜在问题

# [3] COS 上 HA 元数据实际状态
hadoop fs -ls -t cosn://zt-bigdata-emr-online-1256037416/tools/flink1131/tdata_sync/ha/application_1763473707704_1214/ | head -10

# 期望看到：
# submittedJobGraph-xxxxx
# completedCheckpoint1xxxxx（数字递增，最新的在最上面）

# [4] 最新 CK 时间新鲜度（不能超过 2×CK 间隔）
hadoop fs -ls -t cosn://.../flink1131/tdata_sync/ha/application_1763473707704_1214/ | \
  grep completedCheckpoint | head -1
# 对比当前时间，如果超过 5 分钟（假设 CK 间隔 60s）→ CK 不健康
```

### 3.3 Backpressure & 资源状态

```bash
# [1] Backpressure（Flink Web UI）
# 访问 $TRACKING_URL → Jobs → <job> → Backpressure
# HIGH/SEVERE → 必须先等背压缓解（背压下 Savepoint 很容易超时）

# [2] 当前 slot 占用
# Flink Web UI → TaskManagers → 确认 slot 分布

# [3] 集群剩余资源（关机后够不够重新起作业）
yarn node -list | grep RUNNING | wc -l
yarn node -list -showDetails | grep -E "Memory-Used|Vcores-Used"
```

### 3.4 HA 僵尸目录检查（1.13 特有）

```bash
# Flink 1.13 的 FLINK-23456 Bug：老作业的 HA 目录不会自动清理
hadoop fs -ls cosn://.../flink1131/tdata_sync/ha/ | awk '{print $NF}' | \
  grep "application_" | head -30
hadoop fs -ls cosn://.../flink1131/tdata_sync/ha/ | grep "application_" | wc -l

# 如果 > 20 个 → 清理（保留当前作业的）
# hadoop fs -rm -r -skipTrash cosn://.../flink1131/tdata_sync/ha/application_XXX_OLD/
```

### 3.5 预检结论模板

```
[ ] AM 位置：_______________ （是否在待关机节点？）
[ ] AM Attempt：_____________ （已用次数 / 上限）
[ ] 最近 CK 状态：_________ （Completed/Failed）
[ ] 最近 CK 时间：_________ （距当前 _____ 分钟）
[ ] RocksDB 告警：_________ （有/无）
[ ] Backpressure：_________ （OK/HIGH/SEVERE）
[ ] 集群剩余资源：_________ vCores / ______ GB
[ ] HA 僵尸目录数：________

→ 结论：GO / CAUTION / NO-GO
```

**NO-GO 条件**（满足任一）：
- 最近 CK 是 Failed/Expired
- RocksDB 有 corrupt 警告
- Backpressure = SEVERE
- AM Attempt 已用 >= 上限 80%

---

## 4. 执行步骤

### 4.1 Step 1：【通过 DP 平台】暂停自动拉起 + 做 Savepoint

**⚠️ 重要**：这是 DP 平台托管作业，以下操作**优先走平台界面**，以下 Shell 命令作为"平台能力不支持时的兜底"。

```
DP 平台侧操作流程（示意，具体按平台 UI）：
  a) 进入 tdata_sync 任务详情页
  b) 点击 "暂停" / "停止调度"，阻止平台自动重提
  c) 触发 "Savepoint & Stop" 操作
  d) 等待任务状态变为 "已停止" + SP 路径显示
  e) 记录 SP 路径（后面恢复要用）
```

**兜底 Shell 命令**（仅在平台界面不可用时使用，且需事先通知平台方）：

```bash
APP_ID=application_1763473707704_1214
SP_DIR=cosn://zt-bigdata-emr-online-1256037416/tools/flink1131/tdata_sync/savepoints/

# [a] 拿 Flink JobID
flink list -yid $APP_ID
FLINK_JOB_ID=<从输出复制>

# [b] 触发 stop-with-savepoint
# ⚠️ 1.13 推荐用 -p 简写；不要加 --drain（1.13 有 Bug）
flink stop \
  -p $SP_DIR \
  -yid $APP_ID \
  $FLINK_JOB_ID

# 成功输出：
#   Savepoint completed. Path: cosn://.../savepoints/savepoint-abcdef-xxxxx

# [c] ⚠️ 如果 flink stop 卡超过 10 分钟 → 兜底方案
flink cancel -s $SP_DIR -yid $APP_ID $FLINK_JOB_ID

# [d] 记录 SP 路径！
SP_PATH=cosn://.../savepoints/savepoint-abcdef-xxxxx
echo "[$(date)] tdata_sync_1131 $APP_ID -> $SP_PATH" >> /tmp/flink_savepoints.log
```

**🔴 绝对禁止的操作**（会触发 `max-attempts=0` 陷阱）：

```bash
# ❌ 禁止：直接 kill 作业
yarn application -kill $APP_ID
# 后果：作业 FAILED，max-attempts=0 下 HA 不会拉起；
#       DP 平台可能自动重提一个新 AppID，造成状态混乱

# ❌ 禁止：kill AM Attempt 期待 HA 恢复
yarn applicationattempt -fail <attempt_id>
# 后果：max-attempts=0 下 AM 不会重启，作业直接 FAILED

# ❌ 禁止：直接让 AM 所在节点关机（没做 SP 的情况下）
# 后果：AM 进程消失 → 等超时 → YARN 不会重拉（max-attempts=0）→ 作业死
```

### 4.2 Step 2：验证 Savepoint 完整性

```bash
# [1] 基础验证
hadoop fs -ls $SP_PATH/
# 必须看到：
#   _metadata           (不能为空，几 KB ~ 几 MB)
#   很多 uuid 文件       (State 实际数据)

hadoop fs -du -h $SP_PATH/
# 总大小应该和作业状态规模匹配（比如几 GB）

# [2] 元数据可读性验证（使用 Flink 工具）
# 1.13 没有官方 CLI 工具，但可以用 HDFS dfs 看文件完整性
hadoop fs -stat "%b %n" $SP_PATH/_metadata
# 文件大小 > 0 即可

# [3] ⚠️ 重要：SP 完成后，作业已停，确认 YARN 侧状态
yarn application -status $APP_ID | grep "Final-State"
# 期望：FINISHED（不是 FAILED）
```

### 4.3 Step 3：隔离待关机节点

```bash
# 避免后续恢复时，新 TM 又飘回这些节点
NM_HOSTS="nm-host-1 nm-host-2"  # 按实际填

for h in $NM_HOSTS; do
  echo "$h" >> /etc/hadoop/conf/yarn.exclude
done

yarn rmadmin -refreshNodes   # ⚠️ 不加 -g

# 确认状态
yarn node -list -states DECOMMISSIONING
```

### 4.4 Step 4：停 NM + 关机

```bash
for h in $NM_HOSTS; do
  ssh $h "sudo systemctl stop hadoop-yarn-nodemanager"
done

# 确认 NM 已停
yarn node -list -states DECOMMISSIONED,LOST

# 关机
for h in $NM_HOSTS; do
  ssh $h "sudo shutdown -h now"
done
```

### 4.5 Step 5：节点上线后从 Savepoint 恢复

节点维护完成重新上线后：

```bash
# [1] 从 exclude 移除
for h in $NM_HOSTS; do
  sed -i "/^$h$/d" /etc/hadoop/conf/yarn.exclude
done
yarn rmadmin -refreshNodes

# [2] 启动 NM
for h in $NM_HOSTS; do
  ssh $h "sudo systemctl start hadoop-yarn-nodemanager"
done
```

**[3] 恢复作业 —— 必须先修 `application-attempts` 配置！**

```
❗ 恢复前必做：把 yarn.application-attempts 从 0 改为 10
   - 如是 DP 平台托管：在平台任务配置里修改
   - 如手工提交：在 flink-conf.yaml 或启动命令 -D 里设置
```

**DP 平台恢复（推荐）**：
```
a) 在平台任务配置里修改：
     yarn.application-attempts = 10
     (yarn.resourcemanager.am.max-attempts 留空，用集群默认)
b) 指定 "从 Savepoint 启动" + 填入 SP 路径
c) 恢复自动拉起开关
d) 启动任务
```

**手工兜底恢复**（仅平台不可用时）：

```bash
SP_PATH=<上面记录的 SP 路径>

# ⚠️ 1.13 用 flink run（不是 run-application）+ -m yarn-cluster
flink run \
  -m yarn-cluster \
  -ynm tdata_sync_1131 \
  -yqu beaver \
  -yjm 2048 \
  -ytm 4096 \
  -ys 2 \
  -d \
  -s $SP_PATH \
  -Dyarn.application-attempts=10 \
  /path/to/tdata_sync.jar <作业参数>
```

### 4.6 Step 6：恢复后验证

```bash
# [1] 新作业 RUNNING
NEW_APP_ID=<新的 AppID>
yarn application -status $NEW_APP_ID | grep State

# [2] 首次 CK 成功
yarn logs -applicationId $NEW_APP_ID -log_files jobmanager.log | \
  grep "Completed checkpoint" | tail -5

# [3] 数据同步无堆积
# 检查 tdata_sync 的 Source 端 lag（Kafka/CDC）
# 检查 Sink 端落库时间戳

# [4] 清理老 HA 目录（可选，节省 COS 空间）
hadoop fs -rm -r -skipTrash \
  cosn://.../flink1131/tdata_sync/ha/application_1763473707704_1214/
```

---

## 5. 建议在这次维护窗口顺便做的事

既然作业已经停了，强烈建议同窗口完成以下加固：

### 5.1 升级 Flink 1.13.1 → 1.13.6（最低成本）

```bash
# 只换 flink-dist jar，作业代码不改
# 修复 FLINK-22483、FLINK-22646、FLINK-23456 等多个稳定性 Bug
```

### 5.2 加固配置（写入作业 `flink-conf.yaml`）

```yaml
# 🔴 致命配置修正（本作业当前 = 0，必改）
yarn.application-attempts: 10
# yarn.resourcemanager.am.max-attempts 不建议作业侧覆盖
#   若要设置，应 >= 10，不能为 0
yarn.application-attempt-failures-validity-interval: 600000   # 已是合理值

# 关键参数修正
high-availability.zookeeper.client.acl: creator       # ⚠️ 从 open 改为 creator
zookeeper.sasl.disable: false                          # 配合启用 SASL

# CK 稳定性
execution.checkpointing.tolerable-failed-checkpoints: 0   # 1.13 建议 0，出问题立刻发现
state.backend.rocksdb.checkpoint.transfer.thread.num: 4   # COS 多线程上传

# TM 复用（1.13 收益有限但有胜于无）
resourcemanager.taskmanager-timeout: 120000

# 心跳
heartbeat.timeout: 120000
```

### 5.3 HA 存储建议从 COS 迁到 HDFS/CHDFS（如条件允许）

COS 作为 HA 存储的问题：
- 最终一致性可能导致恢复读到旧元数据
- LIST 操作慢，恢复时间拉长
- 鉴权失败直接导致 HA 失效

**如果集群有 HDFS/CHDFS，建议**：
```yaml
high-availability.storageDir: hdfs:///flink/ha/tdata_sync/
state.checkpoints.dir: hdfs:///flink/checkpoints/tdata_sync/
# 仅 Savepoint 保留在 COS（跨集群可用）
state.savepoints.dir: cosn://.../flink-savepoints/
```

---

## 6. 应急预案（Plan B）

如果 Savepoint 失败/超时，按以下顺序降级：

### 6.1 Level 1：`flink cancel -s` 兜底

```bash
# stop -p 超时 → 切换到 cancel -s
flink cancel -s $SP_DIR -yid $APP_ID $FLINK_JOB_ID
# 差异：不 drain，可能有少量 in-flight 数据丢失到下游
```

### 6.2 Level 2：从最新 CK 恢复（放弃 SP）

```bash
# cancel -s 也失败 → 直接 kill，依赖 HA CK 恢复
yarn application -kill $APP_ID

# 找最新成功的 CK
LATEST_CK=$(hadoop fs -ls -t cosn://.../ha/application_xxx/ | \
  grep completedCheckpoint | head -1 | awk '{print $NF}')

# 新作业从这个 CK 恢复（注意：语义接近 -s SP，但可能丢最后一次 CK 之后的数据）
flink run-application -t yarn-application \
  -s $LATEST_CK/... \
  ...
```

### 6.3 Level 3：完全重启，从 Source 源头回溯

```bash
# 最坏情况：所有 SP/CK 都不可用
# tdata_sync 场景下：依赖 Kafka/CDC 的 offset 保留能力从头消费
# 需要下游有去重能力（否则会产生重复数据）
```

---

## 7. 关键命令速查卡

```bash
# 基础变量
APP_ID=application_1763473707704_1214
SP_DIR=cosn://zt-bigdata-emr-online-1256037416/tools/flink1131/tdata_sync/savepoints/

# 一条龙预检
yarn application -status $APP_ID | grep -E "State|AM Host"
yarn applicationattempt -list $APP_ID
yarn logs -applicationId $APP_ID -log_files jobmanager.log | grep "Completed checkpoint" | tail -5
hadoop fs -ls -t cosn://.../flink1131/tdata_sync/ha/application_1763473707704_1214/ | head -5

# 一条龙操作
flink list -yid $APP_ID
flink stop -p $SP_DIR -yid $APP_ID <job_id>
# 如超时：flink cancel -s $SP_DIR -yid $APP_ID <job_id>

# 恢复
flink run -m yarn-cluster -s <sp_path> -d /path/to/jar
```

---

## 8. 关联文档

- [主 SOP](../../yarn/案例/SOP-NM节点关机-Flink作业零影响操作手册.md) — 通用流程
- 主 SOP § 8 — Flink 版本差异注意事项（1.13 专项表在这里）
- [Flink 故障排查决策树](../Flink故障排查决策树.md)

---

## 9. 变更记录

| 版本 | 日期 | 作者 | 变更说明 |
|---|---|---|---|
| v1.0 | 2026-05-11 | eric | 初版，基于 1.13.1 的 HA/CK Bug 专项设计 |
| v1.1 | 2026-05-11 | eric | 新增 §2.3 `max-attempts=0` 致命配置分析 + §2.4 DP 平台托管操作规范；更新执行步骤和恢复流程 |
