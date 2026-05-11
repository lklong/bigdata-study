# SOP：批量永久下线 8 个 NM 节点专项预案（Flink 实时作业场景）

> **场景**：大集群（100+ NM）永久下线 8 个节点（占比 <10%），beaver 队列运行 5+ Flink 作业，部分节点上有 JM/AM，**必须今天完成**
> **关键背景**：`maxAppAttempts = 2`（源码已实证，详见关联文档）
> **策略**：分 2 批 × 每批 4 个 × 批间隔 30 分钟 + 混合处置（SP + HA 自恢复）
> **预计总耗时**：3~4 小时
> **作者**：eric ｜ **日期**：2026-05-11 ｜ **版本**：v1.0

---

## 0. TL;DR（操作员速查）

```
阶段 1：预检盘点（30min）
阶段 2：全量 exclude + 关键作业 Savepoint（30min）
阶段 3：关第一批 4 节点（非 AM 高密） + 观察 30min
阶段 4：关键作业补 SP + 关第二批 4 节点 + 观察 30min
阶段 5：永久下线收尾（30min）
```

**核心原则**：
- ✅ **先 exclude 后关机**（阻止新 container 飘到待关机节点）
- ✅ **分 2 批**（避免 maxAppAttempts=2 容错余量被一次耗尽）
- ✅ **混合策略**（关键作业 SP，普通作业 HA 自恢复）
- ❌ **禁止** `-g` 参数（对 Flink 流作业无效）
- ❌ **禁止** 一次性关 8 个（同时触发多作业 AM 迁移）

---

## 1. 决策依据（为什么这么设计）

### 1.1 为什么必须分批

**容错余量分析**（基于 `maxAppAttempts=2`）：

```
单次 AM 失败 → attempt_01 → _02 → 容错剩余 = 1 次
单次 AM 再失败 → attempt_02 → FAILED → 容错剩余 = 0 次
```

如果 8 个节点同时关：

```
时刻 T：节点 A（有 AM）和节点 B（无 AM）同时关
    ↓
T+50s：AM 失联 → YARN 启动 attempt_02
    ↓
T+60s：attempt_02 申请新 TM Container
    ↓
⚠️ 此时 exclude 可能还在生效传播中（RM → Scheduler → 下次心跳）
    ↓
⚠️ 新 AM/TM 可能被调度到【另一个】待关机节点（如 C）
    ↓
T+120s：节点 C 也关 → AM 再次失联 → attempt_02 失败
    ↓
FAILED（attempts 用完）→ DP 平台自愈介入
```

**分 2 批 + 批间隔 30 分钟的好处**：
- 第一批关完 → 作业 Failover 在正常节点完成 → 观察期间稳定
- `attempt-failures-validity-interval = 600000`（10 分钟）到期 → attempt 计数清零
- 第二批再关 → 作业又有完整的 2 次容错余量

### 1.2 为什么不全部 Savepoint

- 5+ 作业 × 每个 5~10 分钟 SP = 25~50 分钟
- 还要协调 DP 平台逐个暂停 + 验证 + 恢复
- **今天完成的约束下不现实**
- 性价比低：大多数作业 HA + CK 就够了，SP 是"重保障"

### 1.3 为什么不能一次性关

- `maxAppAttempts=2` 决定容错余量极低
- 8 个节点同时关 ≈ 同时触发 N 个 AM Failover
- AM 在迁移过程中有飘到其他待关机节点的风险
- 一旦多个作业同时 FAILED → DP 平台批量自愈 → 集群瞬间压力大

---

## 2. 前置条件检查

在开工前，**以下条件必须都满足**，否则不要开始：

| 检查项 | 要求 | 验证命令 |
|---|---|---|
| 集群 NM 剩余 ≥ 100 个 RUNNING | ✅ | `yarn node -list -states RUNNING \| wc -l` |
| 集群当前资源使用率 < 70% | ✅ | `yarn node -list -showDetails` 或 RM Web UI |
| yarn.exclude 文件存在且可写 | ✅ | `ls -l /etc/hadoop/conf/yarn.exclude` |
| exclude 路径已在 yarn-site.xml 配置 | ✅ | `grep exclude-path /etc/hadoop/conf/yarn-site.xml` |
| DP 平台有"暂停自动拉起"能力 | ✅ | 平台文档 / 找平台方确认 |
| 操作员具备所有节点的 sudo 权限 | ✅ | `ssh <nm> sudo systemctl status hadoop-yarn-nodemanager` |
| 有回滚预案（预留恢复窗口） | ✅ | 最差情况能拉回 NM 重新上线 |

---

## 3. 阶段 1：预检盘点（30 分钟）

### 3.1 总体盘点

```bash
# 主机名列表（占位符，按实际填入）
export NM_LIST="<NM_1> <NM_2> <NM_3> <NM_4> <NM_5> <NM_6> <NM_7> <NM_8>"

# 运行预检脚本
./pre_check_nm_decommission.sh "${NM_LIST// /,}"
```

脚本会输出：
- 每个节点的 container 数量和资源占用
- 所有 Flink 作业的 AM 位置（是否在待关机节点）
- 集群剩余资源

### 3.2 作业分类（核心决策）

根据预检输出，把所有 Flink 作业分 3 类：

#### 🔴 类别 A：必须 Savepoint（关键 + 大状态 + AM 在待关机节点）
判定条件（满足任一）：
- 作业名含 `tdata_sync`、`cdc`、`etl` 等关键字
- AM 在 nm-1~nm-8 上
- State 大小 > 10GB（Flink Web UI 可查）
- 下游对数据一致性要求高（业务方明确）

→ **通过 DP 平台在阶段 2 做 Savepoint**

#### 🟡 类别 B：依赖 HA 自恢复（一般业务作业）
判定条件（满足所有）：
- 开启了 HA + Checkpoint
- State 中等规模（< 10GB）
- AM 不在待关机节点 或 业务允许 1~2 分钟中断

→ **直接关机，让 Flink HA 自动从 CK 恢复**

#### 🟢 类别 C：放任不管（测试/无状态）
判定条件（满足任一）：
- 作业名含 `test`、`demo`、`tmp`
- 无状态 ETL（不怕重跑）
- 已废弃但还在跑

→ **直接关机，允许 FAILED 后 DP 平台按需重启**

### 3.3 节点分批

基于 "AM 位置" 输出，把 8 个节点分两批：

```bash
# 第一批：AM 少或无 AM 的 4 个节点（风险低）
export BATCH_1="<NM_A1> <NM_A2> <NM_A3> <NM_A4>"

# 第二批：AM 较多的 4 个节点（风险高，需要先对关键作业 SP）
export BATCH_2="<NM_B1> <NM_B2> <NM_B3> <NM_B4>"
```

**分批原则**：
- 第一批优先选：无 AM 的节点、只有测试作业 AM 的节点
- 第二批放：有重要作业 AM 的节点（先 SP 再关）
- **绝对不要**：把"同一个作业的 AM 和多个 TM"放在同一批关机

---

## 4. 阶段 2：全量 exclude + 关键作业 Savepoint（30 分钟）

### 4.1 先 exclude 全部 8 个（无论第一批第二批）

**⚠️ 关键**：此刻只隔离调度，不关机。作业继续跑，但新 container 不会再飘过来。

```bash
# 备份原 exclude
sudo cp /etc/hadoop/conf/yarn.exclude \
        /etc/hadoop/conf/yarn.exclude.bak.$(date +%Y%m%d_%H%M%S)

# 一次性加入全部 8 个
for h in $NM_LIST; do
    echo "$h" | sudo tee -a /etc/hadoop/conf/yarn.exclude > /dev/null
done

# 刷新（不加 -g）
yarn rmadmin -refreshNodes

# 验证：应看到 8 个节点 DECOMMISSIONING
yarn node -list -states DECOMMISSIONING
```

### 4.2 对类别 A 作业做 Savepoint

**优先通过 DP 平台操作**（避免脱管）：

```
DP 平台侧流程：
  1. 逐个打开类别 A 作业详情页
  2. 暂停自动拉起（重要！）
  3. 点击 "Savepoint & Stop"
  4. 等待状态 → "已停止"
  5. 记录 SP 路径
```

**平台不可用时的手工兜底**：

```bash
# 对每个类别 A 作业
APP_ID=<application_xxx>
SP_DIR=cosn://your-bucket/flink/savepoints/nm-decommission-$(date +%Y%m%d)/

FLINK_JOB_ID=$(flink list -yid $APP_ID 2>/dev/null | \
  grep "RUNNING" | awk '{print $4}' | head -1)

flink stop -p $SP_DIR -yid $APP_ID $FLINK_JOB_ID

# 超时兜底
# flink cancel -s $SP_DIR -yid $APP_ID $FLINK_JOB_ID

# 记录
echo "[$(date)] $APP_ID -> $SP_DIR/savepoint-xxx" >> /tmp/nm_decommission_sp.log
```

### 4.3 阶段 2 检查点

```
[ ] 8 个节点全部 DECOMMISSIONING
[ ] 类别 A 作业全部已 Savepoint 完成
[ ] DP 平台已暂停类别 A 作业的自动拉起
[ ] 当前 Flink 作业列表（用于阶段 3/4 对比）已保存
  yarn application -list -appTypes "Apache Flink" > /tmp/before_batch1.txt
```

---

## 5. 阶段 3：关第一批 4 个节点（45 分钟 = 15min 操作 + 30min 观察）

### 5.1 执行关机

```bash
# 停 NM
for h in $BATCH_1; do
    echo "[$(date)] Stopping NM on $h"
    ssh $h "sudo systemctl stop hadoop-yarn-nodemanager"
    sleep 5   # 错开停止避免 RM 瞬时压力
done

# 等 30 秒让 RM 标记节点状态
sleep 30

# 关机
for h in $BATCH_1; do
    echo "[$(date)] Shutting down $h"
    ssh $h "sudo shutdown -h +1"   # 1 分钟后关机，给 ssh 退出留时间
done
```

### 5.2 观察 30 分钟（不要跳过）

```bash
# 启动观察脚本
./watch_nm_decommission.sh

# 或手工观察：
# [1] 节点状态
watch -n 10 "yarn node -list -all | grep -E '$(echo $BATCH_1 | tr ' ' '|')'"

# [2] Flink 作业状态对比
yarn application -list -appTypes "Apache Flink" > /tmp/after_batch1.txt
diff /tmp/before_batch1.txt /tmp/after_batch1.txt

# [3] 关注 FAILED 作业
yarn application -list -appStates FAILED | grep beaver

# [4] 关注 attempt 变化（采样每个类别 A/B 作业）
for APP in <需要关注的 APP_ID 列表>; do
    echo "=== $APP ==="
    yarn applicationattempt -list $APP
done
```

### 5.3 阶段 3 判断点（GO / HOLD / ROLLBACK）

| 现象 | 决策 |
|---|---|
| 所有类别 B 作业都恢复 RUNNING，attempts 未到上限 | ✅ GO 到阶段 4 |
| 1~2 个作业 FAILED，DP 平台已自愈拉起 | ✅ GO，但阶段 4 加观察时长 |
| 多个作业 FAILED 且平台未能自愈 | 🟡 HOLD，先处理完再继续 |
| 集群资源告警 / RM 过载 | 🔴 ROLLBACK，先恢复第一批节点 |
| attempt_02 已有作业用完（ATTEMPT_02 FAILED）| 🔴 HOLD，剩余作业必须先 SP |

---

## 6. 阶段 4：关第二批 4 个节点（45 分钟）

### 6.1 第二批 SP 补做（重要）

第一批观察期结束后，在关第二批前，**对 AM 仍在第二批节点上的关键作业再做一次 SP**：

```bash
# 识别：AM 在 BATCH_2 上的作业
for APP in $(yarn application -list -appTypes "Apache Flink" -appStates RUNNING | awk 'NR>2 {print $1}'); do
    AM_HOST=$(yarn application -status $APP 2>/dev/null | grep "AM Host" | awk -F':' '{print $2}' | tr -d ' ')
    for nm in $BATCH_2; do
        if [[ "$AM_HOST" == *"$nm"* ]]; then
            echo "⚠️ $APP 的 AM 在待关机节点 $nm - 建议 SP"
        fi
    done
done
```

对识别出来的作业，通过 DP 平台做 SP（同阶段 2.2）。

### 6.2 关第二批

```bash
for h in $BATCH_2; do
    ssh $h "sudo systemctl stop hadoop-yarn-nodemanager"
    sleep 5
done

sleep 30

for h in $BATCH_2; do
    ssh $h "sudo shutdown -h +1"
done
```

### 6.3 观察 30 分钟（同阶段 3.2）

---

## 7. 阶段 5：永久下线收尾（30 分钟）

### 7.1 确认所有作业正常

```bash
# 当前 RUNNING 作业数应接近初始值（允许 DP 平台自愈后的新 AppID）
yarn application -list -appTypes "Apache Flink" -appStates RUNNING | wc -l

# 没有遗留 FAILED
yarn application -list -appStates FAILED | grep beaver
```

### 7.2 从 Savepoint 恢复类别 A 作业

**通过 DP 平台**（推荐）：
```
平台侧流程：
  1. 打开之前 SP 停止的作业
  2. 在配置里指定"从 Savepoint 恢复" + SP 路径
  3. 恢复自动拉起
  4. 启动作业
```

### 7.3 永久下线：更新集群配置

```bash
# [1] workers 文件移除（避免重启脚本重新启用）
for h in $NM_LIST; do
    sudo sed -i "/^$h$/d" /etc/hadoop/conf/workers
done

# [2] exclude 文件保留（防止运维脚本意外加回）
# 或清理（节点永远不会回来了）：
# 建议保留，并加备注
echo "# Permanently decommissioned on $(date +%Y-%m-%d)" | \
    sudo tee -a /etc/hadoop/conf/yarn.exclude

# [3] 如果有监控/CMDB 系统，同步下线状态
# - Prometheus/Grafana 节点列表
# - Ambari/CM 移除
# - CMDB 资产状态变更
```

### 7.4 最终验收

```bash
# ✅ 节点数减少 8 个
echo "RUNNING NM count: $(yarn node -list -states RUNNING | wc -l)"

# ✅ beaver 队列作业数正常
yarn application -list -appTypes "Apache Flink" -appStates RUNNING | grep -c beaver

# ✅ 集群容量下降 < 10%
yarn node -list -showDetails 2>&1 | grep -E "Total|Available"

# ✅ 无 ACCEPTED 作业堆积
yarn application -list -appStates ACCEPTED | wc -l
```

---

## 8. 应急预案（Playbook）

### 8.1 单作业 FAILED

```
触发条件：beaver 队列某个作业 FAILED（非类别 A）
应对：
  1. 优先等 DP 平台自愈（30s~2min）
  2. 观察 3 次自愈都失败 → 人工介入
  3. 手工从最新 CK 恢复：
     LATEST_CK=$(hadoop fs -ls -t cosn://.../<cluster-id>/ | \
       grep completedCheckpoint | head -1 | awk '{print $NF}')
     flink run-application -t yarn-application -s $LATEST_CK ...
```

### 8.2 多作业批量 FAILED（事故级）

```
触发条件：阶段 3 或 4 观察期 >3 个作业 FAILED
应对：
  🔴 立即：停止剩余阶段执行
  1. 暂停 DP 平台自愈（避免雪崩重提）
  2. 排查共性：
     - 是否集群资源不足？
     - 是否 ZK 压力大？
     - 是否 COS 访问异常？
  3. 从 SP 批量恢复（之前阶段 2 做过的作业）
  4. 剩余作业改走 Savepoint 路径（不再分批关机）
```

### 8.3 节点关机后 RM 显示 LOST 不变 DECOMMISSIONED

```
触发条件：节点已关机，yarn node -list 仍显示 LOST 而不是 DECOMMISSIONED
原因：正常现象（节点不可达 RM 无法收到 decommission 确认）
应对：不影响业务，忽略
  - 永久下线场景下，LOST 最终会被 RM 清理（yarn.resourcemanager.nodes.lost.timeout-ms）
  - 如需立即清理：重启 RM 或等默认超时
```

### 8.4 回滚（极端情况）

```
触发条件：阶段 3 发生 Level 2 以上事故，且剩余作业风险太高
回滚步骤：
  1. 重启关机的节点（如果硬件还在）
  2. 从 exclude 移除相关节点：
     sudo sed -i "/^$NODE$/d" /etc/hadoop/conf/yarn.exclude
     yarn rmadmin -refreshNodes
  3. 启动 NM：
     ssh $NODE "sudo systemctl start hadoop-yarn-nodemanager"
  4. 等节点重新 RUNNING
  5. 重新评估方案（延期下线）
```

---

## 9. 关联文档

| 文档 | 路径 | 用途 |
|---|---|---|
| 通用 SOP | `../../yarn/案例/SOP-NM节点关机-Flink作业零影响操作手册.md` | 单点关机通用流程 |
| 作业 B 专项 | `case-tdata-sync-1131-shutdown-plan.md` | tdata_sync 单作业预案 |
| 源码分析 | `../../yarn/源码/am-max-attempts-源码分析.md` | maxAppAttempts=2 的证据链 |
| 预检脚本 | `scripts/pre_check_nm_decommission.sh` | 阶段 1 盘点工具 |
| 观察脚本 | `scripts/watch_nm_decommission.sh` | 阶段 3/4 实时观察工具 |

---

## 10. 变更记录

| 版本 | 日期 | 作者 | 变更说明 |
|---|---|---|---|
| v1.0 | 2026-05-11 | eric | 初版，针对"大集群永久下线 8 个 NM + 今日完成"场景专项设计 |
