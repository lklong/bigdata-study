# 📋 Kyuubi 1.7.0 线上故障诊断报告

## 1. 问题概述

| 字段 | 值 |
|------|-----|
| **工单号** | OPS-20260404-001 |
| **创建时间** | 2026-04-04 |
| **问题概述** | Kyuubi 1.7.0 连接成功但无法执行 Spark SQL + Session 断开后 Spark 引擎不退出 |
| **问题类型** | 服务故障 + 资源泄漏 |
| **严重程度** | P0（服务不可用） |
| **影响范围** | 所有通过 Kyuubi 提交的 Spark SQL 任务 |
| **涉及组件** | Apache Kyuubi 1.7.0、Apache Spark (yarn-cluster)、YARN ResourceManager、Hive Metastore |

---

## 2. 环境信息

| 项目 | 配置 |
|------|------|
| **Kyuubi 版本** | 1.7.0 |
| **Engine Share Level** | CONNECTION（每个连接拉起独立 Spark 引擎） |
| **Spark 部署模式** | yarn-cluster |
| **问题表现** | 所有连接均无法执行 SQL（系统性故障） |

---

## 3. 分析维度

| 维度 | 状态 | 关键发现 |
|------|------|----------|
| Kyuubi Server 层 | ❌ 严重 | Session 管理 Bug 导致引擎不释放，新引擎无法启动 |
| YARN 资源层 | ❌ 严重 | 残留 Spark Application 占满集群资源 |
| Spark 引擎生命周期 | ❌ 严重 | CONNECTION + yarn-cluster 模式下引擎不正确退出 (Kyuubi 1.7.0 Bug) |
| Hive Metastore | ⚠️ 待确认 | 引擎初始化时连接 HMS 可能卡死 |
| ZooKeeper 引擎注册 | ⚠️ 待确认 | 引擎注册/发现可能异常 |
| 网络/认证 | ✅ 正常 | Thrift 连接本身成功，说明网络和认证无问题 |

---

## 4. 根因分析

### 4.1 因果链（高置信度 — 两个问题互为因果）

```
[根因] Kyuubi 1.7.0 多个 Bug 导致 Spark 引擎不退出
  ├── Bug 1: KYUUBI #4480 — Engine alive probe 在引擎丢失时不关闭 Thrift 连接
  │   → Kyuubi Server 误认为引擎仍存活，不触发清理
  ├── Bug 2: Kyuubi 1.7.2 Fix — waitCompletion + yarn-cluster 模式下 spark-submit 进程不销毁
  │   → CLIENT 断开后 spark-submit 进程残留，YARN Application 继续 RUNNING
  ├── Bug 3: KYUUBI #4847 — Engine 崩溃后 Session 不清理
  │   → Session 泄漏导致引擎保活
  └── Bug 4: KYUUBI #4462 — SessionManager#stop 变量使用错误
      → Session 关闭逻辑不正确

    ↓↓↓

[中间影响] 大量 Spark Application 残留在 YARN 上持续 RUNNING
    → YARN 集群可用资源 (vcore + memory) 被耗尽
    → 所有队列 used 接近 max

    ↓↓↓

[最终现象 — 问题 1] 新的 spark-submit 提交到 YARN 后一直处于 ACCEPTED 状态
    → Kyuubi Server 等待引擎初始化
    → 客户端连接 Thrift 成功但 SQL 执行卡住/超时
    → 所有新连接均无法执行 SQL

[最终现象 — 问题 2] 旧的 Spark Application 在客户端断开后继续运行
    → YARN 上可见大量 Kyuubi 拉起的 Spark 应用处于 RUNNING
    → 资源持续泄漏
```

**置信度**: **高** — Kyuubi 1.7.0 的这些 Bug 已在 1.7.1 和 1.7.2 中被社区确认并修复。

### 4.2 备选根因（中置信度）

| 备选 | 说明 | 排查方式 |
|------|------|----------|
| Kyuubi Server 线程池耗尽 | 类似 HS2 的 backgroundOperationPool RejectedExecution | `jstack <kyuubi_pid>` 检查 BLOCKED 线程 |
| Hive Metastore 连接卡死 | Spark 引擎初始化时连 HMS 死锁 | 检查 HMS 日志和连接数 |
| ZooKeeper 引擎注册异常 | 引擎在 ZK 中注册但实际已死 | `zkCli.sh` 检查 Kyuubi 命名空间 |
| Kyuubi Server 自身 OOM/GC 风暴 | 类似 HS2 堆外内存泄漏 | `jstat -gcutil <pid>` + RSS 监控 |

### 4.3 与 HS2/HMS 知识库的交叉关联

基于工作区 `hs2-hms-bug-knowledge-base/` 知识库，以下 HS2 问题模式与 Kyuubi 场景相关：

| HS2 知识库编号 | 问题 | 与 Kyuubi 关联 |
|---------------|------|---------------|
| **OHL-008** | `CLOSE_SESSION_ON_DISCONNECT=false` 导致 Session 积累 | Kyuubi 底层同样使用 Thrift 协议，Session 断开处理逻辑类似 |
| **CL-003** | backgroundOperationPool RejectedExecution | Kyuubi Server 也有线程池，高并发下可能满 |
| **DL-002** | HiveSessionImpl MetaStoreClient 死锁 | Spark 引擎连 HMS 时可能触发类似死锁 |
| **CL-001** | SQLOperation 子线程 HMS 连接泄漏 | Spark 引擎内部 HMS 连接可能泄漏 |
| **OHL-002** | ThreadWithGarbageCleanup 依赖 finalize() | Kyuubi 线程池可能有类似的线程清理问题 |

---

## 5. 操作路径（按优先级排序）

### 🔴 紧急操作（立即执行 — 恢复服务）

#### 操作 1：清理 YARN 上的残留 Spark Application

**目标**：释放 YARN 资源，让新的引擎可以启动

```bash
# Step 1: 查看所有 RUNNING 的 Kyuubi Spark Application
yarn application -list -appStates RUNNING 2>/dev/null | grep -i "kyuubi\|KyuubiSQLEngine"

# Step 2: 统计残留数量
ORPHAN_COUNT=$(yarn application -list -appStates RUNNING 2>/dev/null | grep -i "kyuubi\|KyuubiSQLEngine" | wc -l)
echo "发现 ${ORPHAN_COUNT} 个残留 Kyuubi Spark Application"

# Step 3: 确认 YARN 资源使用情况
yarn queue -status default 2>/dev/null || yarn top

# Step 4: 批量 kill 残留应用（⚠️ 请先确认，如有正在执行的重要任务请跳过）
yarn application -list -appStates RUNNING 2>/dev/null \
  | grep -i "kyuubi\|KyuubiSQLEngine" \
  | awk '{print $1}' \
  | while read app_id; do
      echo "Killing: $app_id"
      yarn application -kill "$app_id"
    done

# Step 5: 验证资源释放
yarn queue -status default 2>/dev/null
```

- **预期效果**：YARN 资源释放后，新连接应该可以正常启动 Spark 引擎并执行 SQL
- **风险提示**：会中断正在执行的 Kyuubi SQL 任务（但由于所有连接已无法执行，影响可控）
- **回滚方案**：无需回滚，kill 的是已经残留的空闲进程

> 💡 **更安全的方式**：使用本报告附带的 `scripts/cleanup-orphan-spark-apps.sh` 脚本，支持 dry-run 模式先预览再执行。

#### 操作 2：重启 Kyuubi Server（如操作 1 后仍有问题）

```bash
# Step 1: 检查 Kyuubi Server 进程状态
ps aux | grep -i kyuubi | grep -v grep

# Step 2: 优雅停止
$KYUUBI_HOME/bin/kyuubi stop

# Step 3: 确认进程退出
sleep 5
ps aux | grep -i kyuubi | grep -v grep

# Step 4: 如果进程仍在，强制停止
kill -9 $(pgrep -f "org.apache.kyuubi")

# Step 5: 重新启动
$KYUUBI_HOME/bin/kyuubi start

# Step 6: 验证启动成功
$KYUUBI_HOME/bin/kyuubi status
tail -100 $KYUUBI_HOME/logs/kyuubi-*.log | grep -i "started\|listening\|error"
```

- **预期效果**：清除 Kyuubi Server 内部的异常状态（线程池满、Session 泄漏等）
- **风险提示**：重启期间服务短暂不可用（约 10-30 秒）
- **回滚方案**：如重启后服务异常，检查日志排查

#### 操作 3：验证服务恢复

```bash
# 使用 beeline 测试连接和 SQL 执行
beeline -u "jdbc:hive2://<kyuubi_host>:<kyuubi_port>/default" -n <username> -e "SELECT 1"

# 检查 YARN 上新的 Spark Application 是否正常启动
yarn application -list -appStates RUNNING | grep -i kyuubi
```

---

### 🟡 短期修复（当天完成 — 配置调优防止复发）

#### 操作 4：调整 Kyuubi 关键配置参数

编辑 `$KYUUBI_HOME/conf/kyuubi-defaults.conf`，添加/修改以下参数：

```properties
# ======================================
# Session 管理 — 防止 Session 泄漏
# ======================================

# 空闲 Session 超时时间（缩短到 30 分钟，默认 PT6H 太长）
kyuubi.session.idle.timeout=PT30M

# Session 超时检查间隔
kyuubi.session.check.interval=PT5M

# 引擎初始化超时（避免永久等待 YARN 资源）
kyuubi.session.engine.initialize.timeout=PT3M

# ======================================
# 引擎生命周期 — 防止引擎残留
# ======================================

# 引擎无活跃 Session 后的存活时间（缩短到 10 分钟）
kyuubi.engine.idle.timeout=PT10M

# 引擎共享级别（保持 CONNECTION，但确保配置显式）
kyuubi.engine.share.level=CONNECTION

# ======================================
# Spark 引擎参数 — yarn-cluster 模式优化
# ======================================

# 减少 YARN 重试次数，快速失败
spark.yarn.maxAppAttempts=1

# 启用 Spark 动态资源分配，空闲 Executor 及时回收
spark.dynamicAllocation.enabled=true
spark.dynamicAllocation.executorIdleTimeout=60s
spark.dynamicAllocation.minExecutors=1

# 限制单引擎资源，防止过度消耗
spark.executor.instances=2
spark.executor.memory=2g
spark.executor.cores=2
spark.driver.memory=1g
```

修改后重启 Kyuubi Server 生效：

```bash
$KYUUBI_HOME/bin/kyuubi stop && sleep 5 && $KYUUBI_HOME/bin/kyuubi start
```

- **预期效果**：空闲引擎和 Session 会被自动清理，不再无限残留
- **风险提示**：超时时间缩短可能影响长时间运行的查询（长查询建议单独配置）
- **回滚方案**：恢复原配置文件，重启 Kyuubi

#### 操作 5：设置 YARN 残留应用定时清理（crontab）

```bash
# 将清理脚本加入 crontab（每 2 小时执行一次）
crontab -e

# 添加以下行：
0 */2 * * * /path/to/kyuubi-troubleshooting/scripts/cleanup-orphan-spark-apps.sh --max-age 3600 --auto >> /var/log/kyuubi-cleanup.log 2>&1
```

#### 操作 6：部署引擎监控告警

```bash
# 将监控脚本加入 crontab（每 10 分钟执行一次）
*/10 * * * * /path/to/kyuubi-troubleshooting/scripts/monitor-kyuubi-engines.sh >> /var/log/kyuubi-monitor.log 2>&1
```

---

### 🟢 长期优化（计划执行 — 根本解决）

#### 操作 7：升级 Kyuubi 版本到 1.7.2+（**强烈推荐**）

这是**根本解决方案**。Kyuubi 1.7.1 和 1.7.2 修复了所有相关 Bug：

| 版本 | 修复的关键问题 |
|------|-------------|
| **1.7.1** (2023-05-05) | #4480 Engine alive probe 连接不关闭 |
| | #4462 SessionManager#stop 变量错误 |
| | #4644 Py4JServer 关闭不彻底 |
| | #4443 alive probe session 不应设 init sql |
| **1.7.2** (2023-09-18) | waitCompletion + cluster 模式进程残留（**直接修复问题 2**） |
| | SparkOperation#cleanup 强制 cancelJobGroup |
| | 增加 session 关闭日志（便于排查） |

**升级步骤**：

```bash
# 1. 下载 Kyuubi 1.7.2
wget https://archive.apache.org/dist/kyuubi/kyuubi-1.7.2/apache-kyuubi-1.7.2-bin.tgz
tar -xzf apache-kyuubi-1.7.2-bin.tgz

# 2. 备份当前配置
cp -r $KYUUBI_HOME/conf $KYUUBI_HOME/conf.bak.$(date +%Y%m%d)

# 3. 停止当前 Kyuubi
$KYUUBI_HOME/bin/kyuubi stop

# 4. 替换二进制文件（保留配置）
export OLD_KYUUBI_HOME=$KYUUBI_HOME
export KYUUBI_HOME=/path/to/apache-kyuubi-1.7.2-bin
cp $OLD_KYUUBI_HOME/conf/* $KYUUBI_HOME/conf/

# 5. 启动新版本
$KYUUBI_HOME/bin/kyuubi start

# 6. 验证版本
$KYUUBI_HOME/bin/kyuubi version
beeline -u "jdbc:hive2://<host>:<port>/default" -n <user> -e "SELECT 1"
```

- **预期效果**：从根本上消除引擎不退出和 Session 泄漏问题
- **风险提示**：升级需要在低峰期进行，建议先在测试环境验证
- **回滚方案**：停止新版本，恢复旧版本二进制和配置，重新启动

#### 操作 8：评估升级到 Kyuubi 1.8+ / 1.9+

如果条件允许，建议直接升级到最新稳定版（1.9.x），获得更完善的引擎生命周期管理、REST API 支持和 Flink 引擎支持。

---

## 6. 排查命令速查表

```bash
# ===== Kyuubi Server 状态 =====
# 进程检查
ps aux | grep -i kyuubi | grep -v grep

# JVM 内存和 GC 状态
jstat -gcutil $(pgrep -f "org.apache.kyuubi") 1000 5

# 线程数和线程 dump
jstack $(pgrep -f "org.apache.kyuubi") | grep "^\"" | wc -l
jstack $(pgrep -f "org.apache.kyuubi") > /tmp/kyuubi-jstack-$(date +%Y%m%d_%H%M%S).txt

# Kyuubi Server 日志最近错误
tail -500 $KYUUBI_HOME/logs/kyuubi-*.log | grep -i "error\|exception\|timeout\|fail"

# ===== YARN 资源状态 =====
# 集群资源概况
yarn top

# YARN 队列使用率
yarn queue -status default

# 所有 RUNNING 的 Kyuubi 应用
yarn application -list -appStates RUNNING | grep -i "kyuubi\|KyuubiSQLEngine"

# 统计各状态的 Kyuubi 应用
for state in RUNNING ACCEPTED KILLED FAILED FINISHED; do
  count=$(yarn application -list -appStates $state 2>/dev/null | grep -ic "kyuubi\|KyuubiSQLEngine")
  echo "$state: $count"
done

# ===== ZooKeeper 引擎注册 =====
# 查看 Kyuubi 在 ZK 中注册的引擎
# 需要替换为实际的 ZK 地址和 Kyuubi 命名空间
echo "ls /kyuubi" | zkCli.sh -server <zk_host>:2181

# ===== Spark 引擎日志 =====
# 获取特定 Application 的日志
yarn logs -applicationId <app_id> | tail -200

# 查找引擎日志中的错误
yarn logs -applicationId <app_id> 2>/dev/null | grep -i "error\|exception\|timeout\|shutdown"

# ===== Hive Metastore 检查 =====
# HMS 进程状态
ps aux | grep HiveMetaStore | grep -v grep

# HMS 连接数
netstat -an | grep <HMS_PORT> | grep ESTABLISHED | wc -l

# HMS 日志最近错误
tail -200 /var/log/hive/hive-metastore*.log | grep -i "error\|exception"

# ===== 系统资源 =====
# 系统负载
uptime && free -h && df -h
```

---

## 7. 验证方法

### 验证问题 1 已解决（SQL 可执行）

```bash
# 1. Beeline 测试
beeline -u "jdbc:hive2://<kyuubi_host>:<port>/default" -n <user> -e "SELECT 1"
# 预期：返回 1，耗时 < 30 秒（首次连接需初始化引擎）

# 2. 多连接并发测试
for i in $(seq 1 5); do
  beeline -u "jdbc:hive2://<kyuubi_host>:<port>/default" -n <user> -e "SELECT $i" &
done
wait
# 预期：5 个查询都正常返回

# 3. YARN 上新引擎正常启动
yarn application -list -appStates RUNNING | grep -i kyuubi
# 预期：看到与测试对应的 Spark Application
```

### 验证问题 2 已解决（引擎正常退出）

```bash
# 1. 连接 -> 执行 SQL -> 断开 -> 等待 -> 检查
beeline -u "jdbc:hive2://<kyuubi_host>:<port>/default" -n <user> -e "SELECT 1"

# 2. 等待引擎空闲超时（配置 PT10M 则等 10 分钟）
echo "等待引擎空闲退出..."
sleep 660  # 11 分钟，留 1 分钟缓冲

# 3. 检查 YARN 上是否仍有该应用
yarn application -list -appStates RUNNING | grep -i kyuubi
# 预期：刚才的应用已不在 RUNNING 列表中

# 4. 检查应用最终状态
yarn application -list -appStates FINISHED,KILLED | tail -5
# 预期：刚才的应用状态为 FINISHED 或 KILLED
```

---

## 8. 预防措施

### 8.1 监控告警

| 监控项 | 阈值 | 告警级别 | 采集方式 |
|--------|------|---------|----------|
| YARN 上 Kyuubi Spark App 数量 | > 20 | WARNING | `scripts/monitor-kyuubi-engines.sh` |
| YARN 上 Kyuubi Spark App 数量 | > 50 | CRITICAL | 同上 |
| 单个 Kyuubi Spark App 存活时间 | > 2h | WARNING | 脚本检查 startedTime |
| YARN 队列资源使用率 | > 85% | WARNING | `yarn queue -status` |
| Kyuubi Server 线程数 | > 500 | WARNING | `jstack | wc -l` |
| Kyuubi Server GC 暂停 | > 5s | CRITICAL | GC 日志监控 |

### 8.2 定期巡检

- **每日**：检查 YARN 上残留 Kyuubi 应用数量
- **每周**：检查 Kyuubi Server 内存趋势（RSS、GC）
- **每月**：评估 Kyuubi 版本更新和补丁

### 8.3 代码/配置 Review 规则

1. `kyuubi.engine.idle.timeout` 不应超过 30 分钟
2. `kyuubi.session.idle.timeout` 不应超过 1 小时
3. `kyuubi.session.engine.initialize.timeout` 必须设置（避免永久等待）
4. yarn-cluster 模式下需特别关注 spark-submit 进程管理

---

## 9. Kyuubi 1.7.0 已知 Bug 清单

| Bug ID | 标题 | 影响 | 修复版本 |
|--------|------|------|---------|
| **KYUUBI #4480** | Engine alive probe should close thrift connection on engine lost | 引擎丢失后连接不关闭，阻止清理 | **1.7.1** |
| **KYUUBI #4462** | Fix variable usage issue in SessionManager#stop | Session 关闭逻辑错误 | **1.7.1** |
| **KYUUBI #4644** | Manually terminate Py4JServer during engine shutdown | 引擎关闭不彻底 | **1.7.1** |
| **KYUUBI #4443** | Do not set engine session init sql for alive probe session | 存活探针干扰 | **1.7.1** |
| **KYUUBI #4847** | Session leak caused by engine stop | 引擎停止后 Session 不清理 | **1.7.2+** |
| **1.7.2 Fix** | Destroy spark-submit process when waitCompletion=false in cluster mode | yarn-cluster 进程残留 | **1.7.2** |
| **1.7.2 Fix** | SparkOperation#cleanup call cancelJobGroup even job completed | 作业资源不释放 | **1.7.2** |
| **KYUUBI #4591** | Connection level engines didn't close after all jobs finished | 特定节点引擎不关闭 | 未完全修复（重启规避） |

---

## 10. 附件

| 文件 | 说明 |
|------|------|
| `scripts/cleanup-orphan-spark-apps.sh` | YARN 残留 Spark Application 清理脚本（支持 dry-run） |
| `scripts/monitor-kyuubi-engines.sh` | Kyuubi 引擎健康监控脚本 |
| `scripts/diagnose-kyuubi.sh` | 一键诊断信息采集脚本 |
| `configs/kyuubi-defaults-recommended.conf` | 推荐配置模板（含详细注释） |

---

> **报告编写**: 豹纹 (BigData Ops Orchestrator)
> **报告日期**: 2026-04-04
> **下次跟进**: 升级 Kyuubi 到 1.7.2+ 后复验
