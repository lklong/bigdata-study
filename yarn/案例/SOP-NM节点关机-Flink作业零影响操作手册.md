# SOP：NodeManager 节点关机 — Flink 实时作业零影响操作手册

> **适用场景**：Flink on YARN（Per-Job / Application Mode）+ HA 开启 + Checkpoint 常态化
> **目标**：单个或批量 NM 节点关机（硬件维护、下线、迁移）时，把 Flink 实时作业的中断时间和数据影响降到最小
> **作者**：eric
> **版本**：v1.0 / 2026-05-11

---

## 0. 一句话速查

> **先隔离调度（`refreshNodes` 不加 `-g`）→ 重要作业 `flink stop -p` 做 Savepoint → 次要作业靠 HA 自恢复 → 停 NM → 关机**。
> 千万不要用 `refreshNodes -g <timeout>`（Graceful Decommission），它对永不退出的流作业无效，只会白等超时。

---

## 1. 背景与原理（必读）

### 1.1 NM 关机对 Flink 作业的影响分级

| 关机节点上跑了什么 | 开启 HA | 默认中断时间 | 数据一致性 | 风险等级 |
|---|---|---|---|---|
| 仅 TaskManager | ✅ | ~2 min | CK 语义保证 | 🟢 低 |
| 仅 TaskManager | ❌ | 作业 FAILED | 依赖重启策略 | 🔴 高 |
| JobManager（AM） | ✅ | ~10~14 min（AM 超时主导） | CK 语义保证 | 🟡 中 |
| JobManager（AM） | ❌ | 作业彻底 FAILED | 状态丢失 | 🔴 高 |
| JM + 多 TM 同关 | ✅ | 10~15 min | 可能因资源不足 FAILED | 🔴 高 |

### 1.2 为什么 Graceful Decommission 对 Flink 无效

YARN 的 `-refreshNodes -g <timeout>` 核心假设是 **"Container 会自然结束"**，适用于 MapReduce/Spark Batch/Tez 这类批任务。

但 Flink 流作业的 TM/JM 是**常驻进程，永不退出**：

```
T+0s       节点 DECOMMISSIONING，RM 停止往该节点调度
T+0~3600s  Flink TM 照常运行，Graceful 等不到它结束
T+3600s    超时 → YARN 强制 kill → 和直接 kill 无差别
```

**结论**：Graceful Decommission 对 Flink 的"等待结束"能力**完全失效**，只有**"停止调度新容器"**这半个能力对 Flink 有用（见 3.3 节）。

### 1.3 HA 恢复链路（3 句话讲清）

1. AM/JM 挂 → YARN 在 `yarn.resourcemanager.am.liveness-monitor.expiry-interval-ms`（默认 **10 min**）后重拉新 AM Attempt
2. 新 AM 连 ZK → 选主成功 → 从 `high-availability.storageDir`（HDFS/COS）读回 **JobGraph** 和 **最新 Checkpoint 元数据**
3. TM 复用（`resourcemanager.taskmanager-timeout` 默认 30s 内未超时的老 TM 可直接重注册）+ 向 YARN 补齐缺失 TM → 从 CK 恢复状态 → Source 重放

**默认 10 分钟的 AM 超时是最大的业务感知点**，必须通过配置或主动操作规避。

---

## 2. 关机前预检（必做，5 分钟）

### 2.1 信息收集

```bash
# 1) 列出待关机节点（建议单次不超过集群 20%）
NM_LIST="nm-host-1 nm-host-2"

# 2) 集群剩余资源是否够用（关键！）
yarn node -list | grep RUNNING | wc -l
yarn node -list -showDetails

# 3) 列出所有 Flink 作业
yarn application -list -appTypes "Apache Flink"
```

### 2.2 按作业盘点影响

对每个 Flink 作业执行：

```bash
APP_ID=application_xxxxx_xxxxx

# 1) 查 AM 在哪个节点
yarn application -status $APP_ID | grep -E "AM Host|Tracking-URL|Start-Time"

# 2) 查所有 Container 分布
yarn applicationattempt -list $APP_ID
# 拿到最新 attempt_id 后
yarn container -list <appattempt_id>
# 逐行看 LOG-URL，提取 host 名

# 3) 查已用 AM 重试次数（看 attempt 编号）
yarn applicationattempt -list $APP_ID
# _01 = 首次，_02 = 已重试 1 次，依此类推
```

### 2.3 HA 元数据健康检查

假设作业配置如下（示例）：
```properties
high-availability.storageDir = cosn://bucket/flink/ha/
high-availability.zookeeper.quorum = zk1:2181,zk2:2181,zk3:2181
high-availability.cluster-id = application_xxx
```

**检查清单**：

```bash
# 1) 检查 HA 存储目录上的元数据（最近的 CK 是否在）
hadoop fs -ls -t cosn://bucket/flink/ha/application_xxx/ | head -10
# 期望看到：submittedJobGraph-*, completedCheckpoint-*

# 2) 检查最近一次 CK 的时间（不能太旧）
# 如果最新 CK 是 1 小时前 → 说明 CK 持续失败，关机前必须排查

# 3) 检查 ZK HA 路径
echo "ls /flink/application_xxx" | zkCli.sh -server zk1:2181
# 期望看到：leader, leaderlatch, checkpoints, running_job_registry

# 4) 检查 state.checkpoints.dir 可达性
hadoop fs -ls -t <state.checkpoints.dir>/application_xxx/ | head -5
```

### 2.4 出具预检结论（决策输入）

| 检查项 | 通过条件 | 不通过处置 |
|---|---|---|
| 最近 CK 时间 | < 2×checkpoint.interval | 先排查 CK 失败原因，不要关机 |
| HA 存储可达 | `hadoop fs -ls` 秒级返回 | 排查 COS/HDFS 访问问题 |
| ZK 节点完整 | leader 路径存在 | 排查 ZK，禁止关机 |
| AM 重试次数 | 剩余 >= 3 | 连续重试过多，先重启作业刷新计数 |
| 集群剩余资源 | ≥ 作业总需求 × 1.5 | 减少关机节点数或先腾空资源 |

---

## 3. 关机执行流程（SOP 主体）

### 3.1 决策树

```
开始
  │
  ├─ 待关机节点上有作业? ── 否 ── 直接走 3.3 + 3.5（停 NM → 关机）
  │
  ├─ 有作业 ── 作业是否重要（丢数据/停机敏感）?
  │         │
  │         ├─ 重要 ── 走路径 A：Savepoint 迁移
  │         │
  │         └─ 不重要 ── 有 HA + EXACTLY_ONCE CK?
  │                     │
  │                     ├─ 是 ── 走路径 B：HA 自恢复
  │                     │
  │                     └─ 否 ── 走路径 A（强制 Savepoint）
  │
  └─ 完成后走 3.3（隔离调度）+ 3.5（停服务）+ 3.6（关机）
```

### 3.2 路径 A：Savepoint 迁移（0 丢失 0 重复，推荐）

```bash
# 1) 拿到 Flink 层的 JobID（不是 YARN AppID）
APP_ID=application_xxxxx
flink list -yid $APP_ID
# 输出形如：  Running Jobs:
#   01.01.2026 12:00:00 : abcdef123456 : tdata_sync_job (RUNNING)
FLINK_JOB_ID=abcdef123456

# 2) 触发 Savepoint 并优雅停止
SP_DIR=cosn://bucket/flink/savepoints/       # 或 hdfs:///flink/savepoints/
flink stop \
  --savepointPath $SP_DIR \
  $FLINK_JOB_ID \
  -yid $APP_ID

# 成功输出：Savepoint completed. Path: cosn://bucket/flink/savepoints/savepoint-abcdef-xxxxx

# 3) 验证 Savepoint 完整性
hadoop fs -ls cosn://bucket/flink/savepoints/savepoint-abcdef-xxxxx/
# 必须看到 _metadata 文件

# 4) 记录 SP 路径（后面恢复要用）
echo "savepoint-abcdef-xxxxx" >> /tmp/flink_shutdown_savepoints.log
```

### 3.3 隔离调度（防止新 TM 飘到待关机节点，关键！）

**必须在关机前执行**，否则作业 Failover 申请新 TM 时可能又落到其他待关机节点上。

```bash
# 1) 加入 exclude 文件
for h in $NM_LIST; do
  echo "$h" >> /etc/hadoop/conf/yarn.exclude
done

# 2) 只刷新不等待（⚠️ 不要加 -g 参数）
yarn rmadmin -refreshNodes

# 3) 确认节点状态变为 DECOMMISSIONING
yarn node -list -states DECOMMISSIONING
```

**⚠️ 禁止用法**：
```bash
# ❌ 错误！对 Flink 流作业，-g 等超时白白浪费时间
yarn rmadmin -refreshNodes -g 3600 -server
```

### 3.4 路径 B：HA 自恢复（允许 2~10 分钟中断的作业）

前提：作业已开 HA + CK + `restart-strategy`。

```bash
# 场景 1：只有 TM 在待关机节点 → 直接进入 3.5
#   作业会在 TM 断连 ~50s 后自动 Failover，约 2min 恢复

# 场景 2：AM/JM 在待关机节点 → 建议主动触发 AM 迁移，避免默认 10 分钟超时

# 主动 kill 当前 AM Attempt，让 YARN 立即重新分配（落到非 exclude 节点）
ATTEMPT_ID=appattempt_xxxxx_xxxxx_000001
yarn applicationattempt -fail $ATTEMPT_ID

# 或在节点上直接 kill 进程（等效但更暴力）
ssh <jm-host> "jps | grep YarnJobClusterEntrypoint | awk '{print \$1}' | xargs -r kill -9"

# 观察新 Attempt 是否起来
watch -n 2 "yarn applicationattempt -list $APP_ID"
# 看到 _02 进入 RUNNING 即恢复成功
```

### 3.5 停 NodeManager 服务

```bash
# 逐台停 NM
for h in $NM_LIST; do
  ssh $h "sudo systemctl stop hadoop-yarn-nodemanager"
done

# 确认节点状态：DECOMMISSIONED 或 LOST
yarn node -list -states DECOMMISSIONED,LOST
```

### 3.6 关机

```bash
for h in $NM_LIST; do
  ssh $h "sudo shutdown -h now"
done
```

---

## 4. 节点上线恢复

### 4.1 节点重启后

```bash
# 1) 从 exclude 移除
for h in $NM_LIST; do
  sed -i "/^$h$/d" /etc/hadoop/conf/yarn.exclude
done

# 2) 刷新让 RM 重新接受该节点
yarn rmadmin -refreshNodes

# 3) 启动 NM
for h in $NM_LIST; do
  ssh $h "sudo systemctl start hadoop-yarn-nodemanager"
done

# 4) 确认节点 RUNNING
yarn node -list -states RUNNING | grep -E "$(echo $NM_LIST | tr ' ' '|')"
```

### 4.2 从 Savepoint 恢复作业（路径 A 后续）

```bash
# 从之前保存的 SP 启动
flink run-application -t yarn-application \
  -s cosn://bucket/flink/savepoints/savepoint-abcdef-xxxxx \
  -Dyarn.application.name=tdata_sync_job \
  -Dparallelism.default=8 \
  xxx.jar

# ⚠️ 注意：恢复后 cluster-id 会变成新的 YARN AppID
# 老的 HA 目录可清理：
hadoop fs -rm -r -skipTrash cosn://bucket/flink/ha/application_xxx_old/
```

---

## 5. 长期加固配置（落地到集群/作业默认参数）

这些配置让**任何 NM 故障/关机**都能自动最小化影响，建议写入基线配置。

### 5.1 Flink 作业侧（`flink-conf.yaml`）

```yaml
# === HA 必开 ===
high-availability: zookeeper
high-availability.storageDir: hdfs:///flink/ha/      # 优先 HDFS，COS 为次选
high-availability.zookeeper.quorum: zk1:2181,zk2:2181,zk3:2181
high-availability.zookeeper.client.acl: creator      # ⚠️ 不要用 open
yarn.application-attempts: 10
yarn.application-attempt-failures-validity-interval: 600000

# === TM 复用（加快恢复，关键！）===
resourcemanager.taskmanager-timeout: 300000          # TM 等新 JM 的时间，5min

# === 心跳容忍 ===
heartbeat.timeout: 120000                            # 2min，防误判
heartbeat.interval: 10000

# === Checkpoint ===
execution.checkpointing.interval: 60s
execution.checkpointing.mode: EXACTLY_ONCE
state.checkpoints.dir: hdfs:///flink/checkpoints/
state.checkpoints.num-retained: 3
execution.checkpointing.tolerable-failed-checkpoints: 3

# === 重启策略（指数退避，避免雪崩重启）===
restart-strategy: exponential-delay
restart-strategy.exponential-delay.initial-backoff: 10s
restart-strategy.exponential-delay.max-backoff: 2min
restart-strategy.exponential-delay.backoff-multiplier: 2.0
restart-strategy.exponential-delay.reset-backoff-threshold: 10min
```

### 5.2 YARN 侧（`yarn-site.xml`）

```xml
<!-- 缩短 AM 失联判定，默认 10min 太长 -->
<property>
  <name>yarn.resourcemanager.am.liveness-monitor.expiry-interval-ms</name>
  <value>120000</value>
</property>

<!-- NM 重启不杀容器（对滚动重启 NM 有用）-->
<property>
  <name>yarn.nodemanager.recovery.enabled</name>
  <value>true</value>
</property>
<property>
  <name>yarn.nodemanager.recovery.dir</name>
  <value>/data/hadoop/yarn/nm-recovery</value>
</property>

<!-- exclude 文件路径 -->
<property>
  <name>yarn.resourcemanager.nodes.exclude-path</name>
  <value>/etc/hadoop/conf/yarn.exclude</value>
</property>
```

### 5.3 运维规范

| 规则 | 说明 |
|---|---|
| **分批关机** | 单批 ≤ 集群 NM 的 20%，且避开 AM 所在节点 |
| **时间窗口** | 业务低峰 + CK 刚完成后 5 分钟内 |
| **反亲和（可选）** | 关键作业用 `yarn.nodemanager.labels` 让 JM 只落稳定节点 |
| **预检脚本** | 每次关机前必跑 `flink_pre_shutdown_check.sh`（见附录） |
| **回滚预案** | 提前拿到 Savepoint 路径，任何异常都能从 SP 重启 |

---

## 6. 常见坑与规避

| 坑 | 现象 | 规避 |
|---|---|---|
| 用了 `-g 3600` | 等 1 小时还没关机 | 永远不加 `-g`，只用 `refreshNodes` |
| 没先 exclude 就关机 | 新 TM 飘到下一个待关机节点，作业反复 Failover | 步骤 3.3 必做 |
| HA 存储用 COS 未验证 | 恢复时 CK 元数据读不到，作业 FAILED | 步骤 2.3 必查 `_metadata` |
| ZK ACL=open 被误删 | 恢复时 `/flink/<cluster-id>` 不存在 | 改 `creator` + SASL |
| `yarn.application-attempts` 已用完 | 再失败一次作业就彻底死 | 步骤 2.2 查 Attempt 编号 |
| **`yarn.application-attempts=0`** 🔴 | **AM 挂了不重试，HA 完全失效**；作业 FAILED 后不会自动恢复 | 关机前必查，实际值应 >= 5，推荐 10 |
| `yarn.resourcemanager.am.max-attempts=0` 🔴 | RM 侧限死重试上限，application-attempts 失效 | 作业侧不要设，让它用集群默认；必设也要 >= 10 |
| DP/数据平台托管作业被手动 kill | 平台状态不一致，可能自动重提新 AppID 干扰流程 | 操作前先通过平台暂停自动拉起 |
| 批量关机超过集群容量 | 作业申请不到 TM，卡 SCHEDULED | 步骤 2.1 算剩余资源 |
| JM 和多 TM 同节点 | 节点关机=双重故障 | 提前用 node label 做反亲和 |
| Savepoint 失败但作业已停 | 无法从 SP 恢复，只能从老 CK 恢复（可能丢数据） | `flink stop` 失败时先 `flink cancel -s` 重试 |

---

## 7. 附录

### 7.1 一键预检脚本（伪代码）

```bash
#!/bin/bash
# flink_pre_shutdown_check.sh
# 用法：./flink_pre_shutdown_check.sh <app_id> <nm_host_list>

APP_ID=$1
NM_HOSTS=$2   # 逗号分隔

echo "=== [1/5] AM 位置 ==="
yarn application -status $APP_ID | grep -E "AM Host|Start-Time"

echo "=== [2/5] AM Attempt 次数 ==="
yarn applicationattempt -list $APP_ID

echo "=== [3/5] 待关机节点是否有该作业容器 ==="
# 从 yarn container -list 输出中匹配 $NM_HOSTS

echo "=== [4/5] HA 元数据检查 ==="
STORAGE_DIR=$(... 从作业 conf 拿 high-availability.storageDir)
hadoop fs -ls -t $STORAGE_DIR/$APP_ID/ | head -5

echo "=== [5/5] 最近 CK 时间 ==="
# 取最新 completedCheckpoint 的 mtime，对比当前时间

echo "=== 结论 ==="
# 根据以上输出给出 GO / CAUTION / NO-GO
```

### 7.2 核心参考文档

- Flink HA with ZooKeeper：https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/deployment/ha/zookeeper_ha/
- YARN Graceful Decommission：https://hadoop.apache.org/docs/current/hadoop-yarn/hadoop-yarn-site/GracefulDecommission.html
- Flink Savepoint vs Checkpoint：https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/ops/state/savepoints/

### 7.3 关联案例

- `yarn/案例/NM堆外内存泄漏分析/` — NM 内存问题导致 UNHEALTHY，也可能触发关机需求
- `flink/` 目录下的 Checkpoint / HA 相关笔记

---

## 8. Flink 版本差异注意事项（重要）

关机 SOP 的"标准流程"基于 **Flink 1.17+ 的行为**，但生产环境常有 1.13 / 1.14 等老版本作业，行为差异显著。本章列出高频差异点。

### 8.1 关键能力版本矩阵

| 能力 | 1.13.x | 1.14.x | 1.15.x | 1.17+ | 1.19+ |
|---|---|---|---|---|---|
| TM 复用（JM 切换时老 TM 重注册） | ⚠️ 不稳定 | ⚠️ 改进中 | ✅ 稳定 | ✅ 稳定 | ✅ 稳定 |
| `resourcemanager.taskmanager-timeout` 生效 | ⚠️ 打折 | ✅ | ✅ | ✅ | ✅ |
| Unaligned Checkpoint | 🧪 实验 | ✅ | ✅ | ✅ | ✅ |
| Reactive Mode / Adaptive Scheduler | ❌ | 🧪 | ✅ | ✅ | ✅ |
| Application Mode 稳定性 | 🧪 | ✅ | ✅ | ✅ | ✅ |
| KafkaSource（新版） | ❌（用 FlinkKafkaConsumer）| 🧪 | ✅ | ✅ | ✅ |
| `flink stop --drain` | ⚠️ 有 Bug | ✅ | ✅ | ✅ | ✅ |
| Savepoint 格式兼容 | v2 | v2 | v3（兼容 v2）| v3 | v3 |

### 8.2 Flink 1.13.x 专项风险

**1.13 是已知"稳定性过渡版本"，关机/恢复场景下有多个 Bug**，建议优先走 Savepoint 路径，不要依赖 HA 自恢复。

| Bug/限制 | 影响 | 规避 |
|---|---|---|
| **FLINK-22483** — CK 超时后状态不一致 | 恢复时数据重复或丢失 | 关机前必须等一次完整 CK 成功，`tolerable-failed-checkpoints=0` |
| **FLINK-22646** — RocksDB 增量 CK 元数据损坏 | 从 CK 恢复直接 FAILED | 关机前做 Savepoint（全量），不依赖增量 CK |
| **FLINK-23456** — HA 路径清理不彻底 | 僵尸 HA 目录累积，拖慢恢复 | 定期清理 `storageDir` 下历史 `application_xxx/` 目录 |
| **TM 复用不稳定** | JM 切换时老 TM 全部重建，恢复慢 2~3 倍 | JM 所在节点关机前主动 Savepoint，不靠 AM Retry |
| **`flink stop --drain` Bug** | Drain 不彻底，Watermark 推进异常 | 用 `flink stop -p`（不加 --drain），或 `flink cancel -s` 兜底 |
| **FlinkKafkaConsumer offset 语义** | CK 之外有窗口期 offset 已 commit 到 Kafka | 下游幂等消费，不要完全信任 EXACTLY_ONCE |

**1.13.x 关机前额外检查清单**：

```bash
APP_ID=application_xxxxx

# 1) 确认最近 CK 真的 Completed（不只是文件存在）
yarn logs -applicationId $APP_ID -log_files jobmanager.log | \
  grep -E "Completed checkpoint|Checkpoint.*failed" | tail -20

# 2) 检查 RocksDB 增量 CK 警告
yarn logs -applicationId $APP_ID -log_files jobmanager.log | \
  grep -iE "incremental|rocksdb.*warn|state.*corrupt" | tail -20

# 3) 检查 Backpressure（1.13 在背压下 CK 超时率高）
# Flink Web UI → Job → Backpressure
# HIGH/SEVERE 必须先缓解

# 4) 检查 HA 僵尸目录
hadoop fs -ls <storageDir> | wc -l
# 超过 50 个 → 清理历史 application_xxx/
```

### 8.3 不同版本的推荐处置路径

| Flink 版本 | 关机时推荐路径 | 原因 |
|---|---|---|
| 1.13.x | **强制路径 A（Savepoint）** | HA 恢复 Bug 多，不能冒险 |
| 1.14.x | 路径 A 优先，路径 B 可接受 | 大部分 Bug 已修，但 TM 复用仍不够稳 |
| 1.15.x | 路径 A/B 均可 | TM 复用稳定 |
| 1.17+ | 路径 B（HA 自恢复）可作为默认 | 全特性成熟 |

### 8.4 版本识别方法

```bash
# 从作业本身识别
flink --version

# 从 YARN 应用识别（如果走命名规范）
yarn application -status <app_id> | grep -oE "flink[0-9]+"
# 常见规范：flink1131 = 1.13.1，flink1190 = 1.19.0

# 从 HA storageDir 路径识别（如果路径有版本号约定）
# 例：cosn://.../tools/flink1131/... → 1.13.1

# 从 Flink Web UI 右上角
```

### 8.5 升级建议

对仍在使用 1.13/1.14 的作业，建议推动升级：

| 升级路径 | 成本 | 收益 | 建议窗口 |
|---|---|---|---|
| 1.13.x → 1.13.6 | 极低（仅 patch）| 修复已知 Bug | 任意 CK 后 |
| 1.13.x → 1.14.6 | 低 | 更稳定 CK | 季度维护 |
| 1.13.x → 1.17/1.19 | 中（Source/Sink API 迁移）| 长期一致 | 大版本维护窗口 |

**黄金组合**：NM 关机维护窗口 + Flink 版本升级，一次停机同时完成。

---

## 9. 变更记录

| 版本 | 日期 | 作者 | 变更说明 |
|---|---|---|---|
| v1.0 | 2026-05-11 | eric | 初版，整合 NM 关机 + Flink HA + Savepoint 完整流程 |
| v1.1 | 2026-05-11 | eric | 新增 §8 Flink 版本差异注意事项，专项覆盖 1.13.x 风险 |
| v1.2 | 2026-05-11 | eric | §6 常见坑补充 `application-attempts=0` / `max-attempts=0` 陷阱 + DP 平台托管作业操作规范 |
