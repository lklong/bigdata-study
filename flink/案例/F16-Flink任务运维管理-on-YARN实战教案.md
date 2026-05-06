# [教案] Flink on YARN — 任务运维管理实战使用姿势

> 🎯 教学目标：掌握 Flink on YARN 作业的全生命周期管理、日志排查、升级流程、监控接入 | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：你是一个养鱼场的管理员，鱼塘里有几十条不同品种的鱼（Flink 作业）。日常工作包括：巡查每条鱼是否健康（监控）、定期换水喂食（参数调整）、生病了治疗（故障排查）、品种升级（代码更新）、旺季增加鱼苗（扩容）。你需要一套标准化的管理流程来确保鱼塘稳定运营。

**生产场景**：
- 日常巡检：查看作业运行状态、消费延迟、Checkpoint 是否正常
- 代码升级：修 Bug 或加新功能后，需要不丢数据地替换旧作业
- 扩缩容：大促流量暴增需要紧急扩容；促销结束后缩容节省资源
- 故障处理：Container 被 Kill、TaskManager 丢失、作业重启循环

**本教案覆盖的运维场景**：
1. 作业生命周期管理（提交/查看/取消/恢复）
2. 日志获取与分析
3. 标准升级流程
4. 并行度调整与扩缩容
5. 资源配置最佳实践
6. 监控指标接入
7. 常见故障排查

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|-----|------|
| Flink | 1.17+ / 1.18+ | 推荐 1.18+ |
| Hadoop/YARN | 3.x | ResourceManager + NodeManager |
| HDFS | 3.x | 存储 JAR/Checkpoint/Savepoint/日志 |
| Java | JDK 8 / 11 | Flink 运行时 |

### 2.2 环境准备

```bash
# ========== 基础环境 ==========
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)

# ========== 创建 HDFS 目录 ==========
hdfs dfs -mkdir -p /flink/jars           # JAR 包存储
hdfs dfs -mkdir -p /flink/checkpoints    # Checkpoint 存储
hdfs dfs -mkdir -p /flink/savepoints     # Savepoint 存储
hdfs dfs -mkdir -p /flink/ha             # 高可用存储

# ========== 确认 YARN 队列可用 ==========
yarn queue -status flink
# 确保 flink 队列有足够资源

# ========== 上传 JAR 到 HDFS（推荐方式）==========
hdfs dfs -put my-flink-job.jar hdfs:///flink/jars/
```

---

## 三、核心使用方式

### 3.1 任务生命周期管理命令大全

#### 3.1.1 提交作业

```bash
# ============================================================
# Application Mode 提交（推荐生产使用）
# ============================================================
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="MyFlinkJob-v1.0" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/my-job \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/my-job \
    -c com.example.MyFlinkJob \
    hdfs:///flink/jars/my-flink-job.jar

# 输出: Job has been submitted with JobID <jobId>
# 记录 YARN Application ID: application_xxxxx_xxxx

# ============================================================
# Per-Job Mode 提交（Flink 1.18+ 已废弃，但老集群还在用）
# ============================================================
$FLINK_HOME/bin/flink run \
    -t yarn-per-job \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -c com.example.MyFlinkJob \
    my-flink-job.jar

# ============================================================
# 从 Savepoint 恢复提交
# ============================================================
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dparallelism.default=4 \
    -Dyarn.application.name="MyFlinkJob-v1.1-from-savepoint" \
    -Dyarn.application.queue=flink \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/my-job \
    -s hdfs:///flink/savepoints/my-job/savepoint-xxxxxx-xxxxxxxxxx \
    -c com.example.MyFlinkJob \
    hdfs:///flink/jars/my-flink-job-v1.1.jar
```

#### 3.1.2 查看作业

```bash
# ============================================================
# 查看作业列表
# ============================================================
$FLINK_HOME/bin/flink list \
    -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx

# 输出:
# ---- Running/Restarting Jobs -------------------
# 29.04.2026 14:00:00 : <jobId> : MyFlinkJob (RUNNING)

# 查看所有状态的作业（包括已完成的）
$FLINK_HOME/bin/flink list -a \
    -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx

# ============================================================
# 通过 YARN 命令查看
# ============================================================
# 查看所有运行中的 Flink 应用
yarn application -list -appTypes APACHE_FLINK | grep RUNNING

# 查看特定应用详情
yarn application -status application_xxxxx_xxxx

# 查看应用尝试次数
yarn applicationattempt -list application_xxxxx_xxxx
```

#### 3.1.3 取消作业

```bash
# ============================================================
# 直接取消（不保存状态 - 慎用！）
# ============================================================
$FLINK_HOME/bin/flink cancel \
    -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx \
    <jobId>

# ============================================================
# 停止 + 保存 Savepoint（推荐方式）
# ============================================================
$FLINK_HOME/bin/flink stop \
    -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx \
    --savepointPath hdfs:///flink/savepoints/my-job \
    <jobId>

# 输出:
# Suspending job "xxxxxxxx" with a savepoint.
# Savepoint completed. Path: hdfs:///flink/savepoints/my-job/savepoint-xxxxxx-xxxxxxxxxx

# ============================================================
# 仅触发 Savepoint（不停止作业）
# ============================================================
$FLINK_HOME/bin/flink savepoint \
    -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx \
    <jobId> \
    hdfs:///flink/savepoints/my-job

# ============================================================
# 强制杀死 YARN Application（最后手段）
# ============================================================
yarn application -kill application_xxxxx_xxxx
```

#### 3.1.4 命令参数速查表

| 命令 | 作用 | 是否保存状态 | 适用场景 |
|------|------|-----------|---------|
| `flink stop --savepointPath` | 优雅停止 + Savepoint | ✅ | 升级/迁移 |
| `flink savepoint` | 触发 Savepoint 不停止 | ✅（不影响运行） | 定期备份 |
| `flink cancel` | 取消作业 | ❌（除非有 externalized CP） | 废弃作业 |
| `yarn application -kill` | 杀死 YARN 应用 | ❌ | 作业无响应 |

### 3.2 YARN Application 日志获取

```bash
# ============================================================
# 方式1: yarn logs 命令（最常用）
# ============================================================
# 获取整个应用的所有 Container 日志
yarn logs -applicationId application_xxxxx_xxxx

# 获取特定 Container 日志
yarn logs -applicationId application_xxxxx_xxxx \
    -containerId container_e01_xxxxx_xxxx_01_000001

# 获取 JobManager 日志（通常是第一个 Container）
yarn logs -applicationId application_xxxxx_xxxx \
    -containerId container_e01_xxxxx_xxxx_01_000001 \
    -log_files jobmanager.log

# 获取 TaskManager 日志
yarn logs -applicationId application_xxxxx_xxxx \
    -containerId container_e01_xxxxx_xxxx_01_000002 \
    -log_files taskmanager.log

# 只看 stderr（异常堆栈通常在这里）
yarn logs -applicationId application_xxxxx_xxxx \
    -log_files stderr

# 输出到文件
yarn logs -applicationId application_xxxxx_xxxx > /tmp/flink-app.log 2>&1

# ============================================================
# 方式2: YARN ResourceManager Web UI
# ============================================================
# 访问: http://yarn-rm-host:8088/
# → Applications → 找到对应 Application → Logs
# 每个 Container 的 stdout/stderr/jobmanager.log/taskmanager.log 都可查看

# ============================================================
# 方式3: Flink Web UI（通过 YARN Proxy 访问）
# ============================================================
# URL 格式: http://yarn-rm-host:8088/proxy/application_xxxxx_xxxx/
# 
# 在 Web UI 中可以:
# - 查看 Job Graph（DAG）
# - 查看各算子的 Metrics
# - 查看 Checkpoint 历史
# - 查看 TaskManager 日志
# - 查看异常堆栈

# ============================================================
# 方式4: HDFS 日志归档（如果配置了 log aggregation）
# ============================================================
# yarn-site.xml 中配置:
# yarn.log-aggregation-enable = true
# yarn.log-aggregation.retain-seconds = 604800 (7天)
# yarn.nodemanager.remote-app-log-dir = /tmp/logs

hdfs dfs -ls /tmp/logs/$(whoami)/logs/application_xxxxx_xxxx/
```

### 3.3 Flink Web UI 通过 YARN Proxy 访问

```bash
# ============================================================
# URL 拼接方式
# ============================================================
# 标准 YARN Proxy URL:
# http://<yarn-rm-host>:<rm-webapp-port>/proxy/<application-id>/

# 示例:
# http://yarn-rm01:8088/proxy/application_1234567890_0001/

# 如果 YARN RM 开启了 HA:
# http://<active-rm-host>:8088/proxy/<application-id>/
# 获取 Active RM:
yarn rmadmin -getServiceState rm1
yarn rmadmin -getServiceState rm2

# ============================================================
# 常用 REST API 端点
# ============================================================
BASE_URL="http://yarn-rm01:8088/proxy/application_xxxxx_xxxx"

# 获取作业概览
curl $BASE_URL/jobs | python -m json.tool

# 获取 Checkpoint 信息
curl $BASE_URL/jobs/<jobId>/checkpoints | python -m json.tool

# 获取各算子指标
curl "$BASE_URL/jobs/<jobId>/vertices/<vertexId>/metrics?get=numRecordsInPerSecond,numRecordsOutPerSecond"

# 获取 TaskManager 列表
curl $BASE_URL/taskmanagers | python -m json.tool

# 获取背压信息
curl $BASE_URL/jobs/<jobId>/vertices/<vertexId>/backpressure | python -m json.tool
```

### 3.4 任务升级标准流程

```bash
#!/bin/bash
# ============================================================
# upgrade-flink-job.sh - Flink 作业标准升级脚本
# ============================================================

set -e

# ===== 配置参数 =====
FLINK_HOME=/opt/flink-1.18.1
APP_ID="application_xxxxx_xxxx"
JOB_NAME="MyFlinkJob"
SAVEPOINT_DIR="hdfs:///flink/savepoints/my-job"
NEW_JAR="hdfs:///flink/jars/my-flink-job-v1.1.jar"
MAIN_CLASS="com.example.MyFlinkJob"

echo "========== Step 1: 获取 Job ID =========="
JOB_ID=$($FLINK_HOME/bin/flink list \
    -t yarn-application \
    -Dyarn.application.id=$APP_ID 2>/dev/null \
    | grep RUNNING | awk '{print $4}')

if [ -z "$JOB_ID" ]; then
    echo "ERROR: 未找到运行中的 Job"
    exit 1
fi
echo "当前 Job ID: $JOB_ID"

echo "========== Step 2: 触发 Savepoint 并停止 =========="
SAVEPOINT_PATH=$($FLINK_HOME/bin/flink stop \
    -t yarn-application \
    -Dyarn.application.id=$APP_ID \
    --savepointPath $SAVEPOINT_DIR \
    $JOB_ID 2>&1 | grep "Savepoint completed" | awk '{print $NF}')

if [ -z "$SAVEPOINT_PATH" ]; then
    echo "ERROR: Savepoint 创建失败"
    exit 1
fi
echo "Savepoint 路径: $SAVEPOINT_PATH"

echo "========== Step 3: 验证 Savepoint =========="
hdfs dfs -ls $SAVEPOINT_PATH/_metadata
if [ $? -ne 0 ]; then
    echo "ERROR: Savepoint 文件不完整"
    exit 1
fi
echo "Savepoint 验证通过 ✓"

echo "========== Step 4: 等待旧 Application 结束 =========="
while yarn application -status $APP_ID 2>/dev/null | grep -q "State : RUNNING"; do
    echo "等待旧 Application 结束..."
    sleep 5
done
echo "旧 Application 已停止 ✓"

echo "========== Step 5: 从 Savepoint 启动新版本 =========="
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="${JOB_NAME}-v1.1" \
    -Dyarn.application.queue=flink \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/my-job \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/my-job \
    -s $SAVEPOINT_PATH \
    -c $MAIN_CLASS \
    $NEW_JAR

echo "========== Step 6: 验证新作业启动 =========="
sleep 30  # 等待 YARN 分配资源
NEW_APP_ID=$(yarn application -list -appTypes APACHE_FLINK 2>/dev/null \
    | grep "${JOB_NAME}-v1.1" | grep RUNNING | awk '{print $1}')

if [ -z "$NEW_APP_ID" ]; then
    echo "WARNING: 新作业可能还在启动中，请手动确认"
    echo "检查命令: yarn application -list | grep $JOB_NAME"
else
    echo "新 Application ID: $NEW_APP_ID"
    echo "Web UI: http://yarn-rm01:8088/proxy/$NEW_APP_ID/"
fi

echo "========== 升级完成 ✓ =========="
echo "旧 Savepoint: $SAVEPOINT_PATH（建议保留 7 天后删除）"
```

### 3.5 并行度调整与扩缩容

```bash
# ============================================================
# 方式1: 手动调整并行度（Savepoint → 停止 → 修改并行度 → 恢复）
# ============================================================

# Step 1: Savepoint + 停止
$FLINK_HOME/bin/flink stop \
    -t yarn-application \
    -Dyarn.application.id=$APP_ID \
    --savepointPath hdfs:///flink/savepoints/my-job \
    $JOB_ID

# Step 2: 以新并行度恢复
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Dparallelism.default=8 \                    # 从 4 调整到 8
    -Dtaskmanager.numberOfTaskSlots=2 \          # 每个 TM 2 个 slot
    # Container 数 = ceil(8/2) = 4 个 TM
    -s $SAVEPOINT_PATH \
    ...

# ============================================================
# 方式2: Reactive Mode（自动扩缩容）— Flink 1.18+
# ============================================================
# Reactive Mode 下 Flink 会根据可用 TaskSlot 自动调整并行度
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Dscheduler-mode=reactive \                   # 开启 Reactive Mode
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dyarn.application.name="MyJob-Reactive" \
    # 注意: Reactive Mode 下不设 parallelism.default
    # Flink 会根据 YARN 分配的 Container 数自动调整
    -c com.example.MyFlinkJob \
    my-job.jar

# Reactive Mode 扩容: 向 YARN 请求更多 Container
# Reactive Mode 缩容: YARN 回收 Container 后自动降低并行度
# 注意: Reactive Mode 仍是实验特性，生产慎用

# ============================================================
# 方式3: YARN 资源层扩缩容
# ============================================================
# 调整 YARN 队列容量
yarn queue -set capacity flink 30   # 将 flink 队列容量从 20% 调到 30%

# 或通过 Capacity Scheduler 配置
# <property>
#   <name>yarn.scheduler.capacity.root.flink.capacity</name>
#   <value>30</value>
# </property>
```

### 3.6 资源配置最佳实践

#### 3.6.1 内存配置详解

```
┌──────────────────────────────────────────────────────┐
│           TaskManager Memory Model                   │
├──────────────────────────────────────────────────────┤
│                                                      │
│  taskmanager.memory.process.size = 4096m             │
│  ├── Framework Heap (128m 固定)                       │
│  ├── Task Heap (用户代码)                              │
│  │     = process - framework - managed - network     │
│  │       - overhead - metaspace                      │
│  ├── Managed Memory (状态/排序/缓存)                   │
│  │     = process × 0.4 (默认 40%)                    │
│  ├── Network Memory (Shuffle Buffer)                 │
│  │     = process × 0.1 (默认 10%)                    │
│  ├── JVM Overhead (GC/线程栈/JIT)                     │
│  │     = process × 0.1 (默认 10%)                    │
│  └── JVM Metaspace (256m 默认)                        │
│                                                      │
│  关键公式:                                             │
│  Task Heap ≈ process × (1 - 0.4 - 0.1 - 0.1) - 384m │
│  例: 4096 × 0.4 - 384 = 约 1254m 可用 Task Heap      │
│                                                      │
└──────────────────────────────────────────────────────┘
```

| 参数 | 默认值 | 生产建议 | 说明 |
|------|-------|---------|------|
| `jobmanager.memory.process.size` | 1600m | 2048~4096m | JM 进程总内存 |
| `taskmanager.memory.process.size` | 1728m | 4096~16384m | TM 进程总内存 |
| `taskmanager.numberOfTaskSlots` | 1 | 2~4 | 每个 TM 的 Slot 数 |
| `taskmanager.memory.managed.fraction` | 0.4 | 0.3~0.5 | Managed 内存占比 |
| `taskmanager.network.memory.fraction` | 0.1 | 0.1~0.15 | Network 内存占比 |
| `taskmanager.memory.jvm-overhead.fraction` | 0.1 | 0.1 | JVM Overhead 占比 |

#### 3.6.2 Container 数量计算公式

```
总并行度 = 所有算子的最大并行度
Container(TM) 数 = ceil(总并行度 / taskmanager.numberOfTaskSlots)
总 Container 数 = TM Container 数 + 1 (JM Container)

示例:
  并行度 = 12, Slot = 2
  TM 数 = ceil(12/2) = 6
  总 Container = 6 + 1 = 7
  
资源总量:
  JM: 1 × 2048m = 2GB
  TM: 6 × 4096m = 24GB
  总内存需求: 26GB
  总 vCore: 7 (每 Container 1 vCore 默认)
```

#### 3.6.3 不同场景资源配置模板

```yaml
# ===== 场景1: 轻量 ETL（低状态、低延迟） =====
jobmanager.memory.process.size: 2048m
taskmanager.memory.process.size: 2048m
taskmanager.numberOfTaskSlots: 2
parallelism.default: 4
# Container: 1 JM + 2 TM = 3 个, 总内存 ~6GB

# ===== 场景2: 中等聚合统计（中状态、RocksDB） =====
jobmanager.memory.process.size: 2048m
taskmanager.memory.process.size: 4096m
taskmanager.numberOfTaskSlots: 2
parallelism.default: 8
taskmanager.memory.managed.fraction: 0.4
# Container: 1 JM + 4 TM = 5 个, 总内存 ~18GB

# ===== 场景3: 大状态 Join/窗口（TB级状态） =====
jobmanager.memory.process.size: 4096m
taskmanager.memory.process.size: 8192m
taskmanager.numberOfTaskSlots: 2
parallelism.default: 16
taskmanager.memory.managed.fraction: 0.5
state.backend: rocksdb
state.backend.incremental: true
# Container: 1 JM + 8 TM = 9 个, 总内存 ~70GB

# ===== 场景4: 超高吞吐流处理（Kafka 100+ 分区） =====
jobmanager.memory.process.size: 4096m
taskmanager.memory.process.size: 16384m
taskmanager.numberOfTaskSlots: 4
parallelism.default: 48
taskmanager.network.memory.fraction: 0.15
# Container: 1 JM + 12 TM = 13 个, 总内存 ~200GB
```

---

## 四、完整实战示例

### 4.1 场景描述

完整演示一个 Flink 作业的生命周期管理：提交 → 监控 → 升级 → 扩容 → 故障恢复。

### 4.2 完整操作流程

```bash
# ============================================================
# Phase 1: 提交作业
# ============================================================
APP_NAME="OrderPipeline-v1.0"

$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name=$APP_NAME \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.externalized-checkpoint-retention=RETAIN_ON_CANCELLATION \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/order-pipeline \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/order-pipeline \
    -Drestart-strategy=fixed-delay \
    -Drestart-strategy.fixed-delay.attempts=3 \
    -Drestart-strategy.fixed-delay.delay=30s \
    -c com.example.OrderPipeline \
    hdfs:///flink/jars/order-pipeline-1.0.jar

# 获取 Application ID
APP_ID=$(yarn application -list -appTypes APACHE_FLINK 2>/dev/null \
    | grep "$APP_NAME" | grep RUNNING | awk '{print $1}')
echo "Application ID: $APP_ID"

# ============================================================
# Phase 2: 日常监控
# ============================================================
# 获取 Job ID
JOB_ID=$($FLINK_HOME/bin/flink list \
    -t yarn-application \
    -Dyarn.application.id=$APP_ID 2>/dev/null \
    | grep RUNNING | awk '{print $4}')
echo "Job ID: $JOB_ID"

# 查看 Checkpoint 状态
curl -s "http://yarn-rm01:8088/proxy/$APP_ID/jobs/$JOB_ID/checkpoints" \
    | python -m json.tool | head -30

# 查看背压
curl -s "http://yarn-rm01:8088/proxy/$APP_ID/jobs/$JOB_ID/vertices" \
    | python -m json.tool

# ============================================================
# Phase 3: 代码升级（v1.0 → v1.1）
# ============================================================
# 上传新版本 JAR
hdfs dfs -put -f order-pipeline-1.1.jar hdfs:///flink/jars/

# 停止 + Savepoint
SP_PATH=$($FLINK_HOME/bin/flink stop \
    -t yarn-application \
    -Dyarn.application.id=$APP_ID \
    --savepointPath hdfs:///flink/savepoints/order-pipeline \
    $JOB_ID 2>&1 | grep "Savepoint completed" | awk -F': ' '{print $2}')
echo "Savepoint: $SP_PATH"

# 等待旧应用结束
sleep 10

# 从 Savepoint 启动新版本
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="OrderPipeline-v1.1" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/order-pipeline \
    -s $SP_PATH \
    -c com.example.OrderPipeline \
    hdfs:///flink/jars/order-pipeline-1.1.jar

# ============================================================
# Phase 4: 扩容（并行度 4 → 8）
# ============================================================
# 获取新 APP_ID 和 JOB_ID
NEW_APP_ID=$(yarn application -list -appTypes APACHE_FLINK | grep "v1.1" | awk '{print $1}')
NEW_JOB_ID=$($FLINK_HOME/bin/flink list -t yarn-application \
    -Dyarn.application.id=$NEW_APP_ID | grep RUNNING | awk '{print $4}')

# Savepoint + 停止
SP_PATH2=$($FLINK_HOME/bin/flink stop \
    -t yarn-application \
    -Dyarn.application.id=$NEW_APP_ID \
    --savepointPath hdfs:///flink/savepoints/order-pipeline \
    $NEW_JOB_ID 2>&1 | grep "Savepoint completed" | awk -F': ' '{print $2}')

# 以新并行度恢复
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=8 \
    -Dyarn.application.name="OrderPipeline-v1.1-scaled" \
    -Dyarn.application.queue=flink \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/order-pipeline \
    -s $SP_PATH2 \
    -c com.example.OrderPipeline \
    hdfs:///flink/jars/order-pipeline-1.1.jar
```

### 4.3 监控指标接入

#### Prometheus + Grafana 配置

```yaml
# ============================================================
# flink-conf.yaml - Prometheus 监控配置
# ============================================================
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporterFactory
metrics.reporter.prom.port: 9249-9260    # 端口范围（多 TM 场景）

# 可选: 推送到 Pushgateway（适用于 YARN 动态 Container）
# metrics.reporter.promgateway.factory.class: org.apache.flink.metrics.prometheus.PrometheusPushGatewayReporterFactory
# metrics.reporter.promgateway.hostUrl: http://pushgateway:9091
# metrics.reporter.promgateway.jobName: flink-metrics
# metrics.reporter.promgateway.randomJobNameSuffix: true
# metrics.reporter.promgateway.deleteOnShutdown: false
# metrics.reporter.promgateway.groupingKey: "instance={{hostname}}"

# 指标过滤（减少指标数量）
metrics.scope.jm: <host>.jobmanager
metrics.scope.jm.job: <host>.jobmanager.<job_name>
metrics.scope.tm: <host>.taskmanager.<tm_id>
metrics.scope.tm.job: <host>.taskmanager.<tm_id>.<job_name>
metrics.scope.task: <host>.taskmanager.<tm_id>.<job_name>.<task_name>.<subtask_index>
metrics.scope.operator: <host>.taskmanager.<tm_id>.<job_name>.<operator_name>.<subtask_index>
```

#### 关键监控指标

| 分类 | 指标名 | 含义 | 告警阈值 |
|------|-------|------|---------|
| **吞吐** | `numRecordsInPerSecond` | 每秒输入记录数 | 持续为0 → 告警 |
| **吞吐** | `numRecordsOutPerSecond` | 每秒输出记录数 | 骤降50%+ → 告警 |
| **延迟** | `currentInputWatermark` | 当前水位线（反映事件时间延迟） | 与当前时间差 >5min → 告警 |
| **Kafka** | `pendingRecords` | Kafka 未消费消息数 | >100000 → 告警 |
| **Kafka** | `committedOffsets` | 已提交 offset | 长期不变 → 告警 |
| **CP** | `lastCheckpointDuration` | 最近 CP 耗时 | > interval × 50% → 预警 |
| **CP** | `lastCheckpointSize` | 最近 CP 大小 | 持续增长 → 预警 |
| **CP** | `numberOfFailedCheckpoints` | 失败 CP 数 | > 0 → 告警 |
| **背压** | `isBackPressured` | 是否背压 | = true 持续 >5min → 告警 |
| **JVM** | `Status.JVM.GarbageCollector.*.Time` | GC 耗时 | Full GC >10s → 告警 |
| **JVM** | `Status.JVM.Memory.Heap.Used` | 堆内存使用 | >90% → 告警 |
| **作业** | `numRestarts` | 作业重启次数 | 短时间内 >3 → 告警 |
| **TM** | `Status.Shuffle.Netty.UsedMemorySegments` | 网络缓冲使用 | 接近上限 → 预警 |

#### Grafana Dashboard 模板（关键面板）

```json
{
  "panels": [
    {
      "title": "Records In/Out Per Second",
      "targets": [
        {"expr": "flink_taskmanager_job_task_operator_numRecordsInPerSecond"},
        {"expr": "flink_taskmanager_job_task_operator_numRecordsOutPerSecond"}
      ]
    },
    {
      "title": "Checkpoint Duration",
      "targets": [
        {"expr": "flink_jobmanager_job_lastCheckpointDuration"}
      ]
    },
    {
      "title": "Kafka Consumer Lag",
      "targets": [
        {"expr": "flink_taskmanager_job_task_operator_KafkaSourceReader_KafkaConsumer_records_lag_max"}
      ]
    },
    {
      "title": "Heap Memory Usage",
      "targets": [
        {"expr": "flink_taskmanager_Status_JVM_Memory_Heap_Used / flink_taskmanager_Status_JVM_Memory_Heap_Max"}
      ]
    }
  ]
}
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|---------|------|---------|
| **YARN Container 被 Kill** `Container killed by YARN for exceeding memory limits` | TM 物理内存（含堆外）超过 YARN Container 限制 | 增大 `taskmanager.memory.process.size`；减小 `taskmanager.memory.jvm-overhead.fraction`；检查是否有内存泄漏 |
| **TaskManager Lost** `Connection to TaskManager lost` | TM 进程 OOM/崩溃或网络断开 | 查看 TM Container 日志定位 OOM 原因；增大内存；检查 GC |
| **Checkpoint 持续失败** | 背压/HDFS 慢/状态过大/超时 | 见 F15 教案详细排查步骤 |
| **任务重启循环** `Job entered RESTARTING` | 异常未处理导致 Task 反复失败 | 查看异常堆栈定位根因；增大重启间隔/次数；修复代码 Bug |
| **提交失败** `Could not submit job` | YARN 队列资源不足或 JAR 找不到 | 检查队列剩余资源 `yarn queue -status`；确认 JAR 路径正确 |
| **作业无法取消** `Cancel command timed out` | AM 无响应或 JM 挂掉 | 使用 `yarn application -kill` 强制终止 |
| **Savepoint 创建失败** | Source 不支持暂停/Sink 不支持 flush | 使用 `flink cancel --withSavepoint` 替代 stop |
| **从 Savepoint 恢复失败** | Operator UID 变更/状态不兼容 | 保持 UID 一致；使用 `--allowNonRestoredState` 跳过不兼容状态 |
| **YARN 资源不足** `AM Container not allocated` | 队列无空闲资源 | 等待资源释放；调整队列配置；抢占低优先级作业 |
| **Flink Web UI 无法访问** | YARN Proxy 未启动或防火墙 | 确认 `yarn.web-proxy.address` 配置；检查网络 |

### 详细排障流程

```bash
# ============================================================
# 故障1: Container 被 Kill（最常见）
# ============================================================
# 1. 查看 YARN 事件
yarn application -status $APP_ID | grep -A5 "Diagnostics"

# 2. 查看被 Kill 的 Container
yarn logs -applicationId $APP_ID -log_files stderr | grep -i "kill\|memory\|exceed"

# 3. 计算实际内存使用
# Container 限制 = taskmanager.memory.process.size × (1 + yarn.nodemanager.vmem-pmem-ratio)
# 如果 vmem 超限（虚拟内存），在 yarn-site.xml 中设置:
# yarn.nodemanager.vmem-check-enabled = false

# 4. 解决方案
# 增大 TM 内存:
-Dtaskmanager.memory.process.size=8192m

# ============================================================
# 故障2: 作业重启循环
# ============================================================
# 1. 查看异常堆栈
yarn logs -applicationId $APP_ID -log_files taskmanager.log | grep -A20 "Exception\|Error" | head -50

# 2. 常见原因:
# - NPE（数据格式异常）→ 代码加空值检查
# - ClassNotFoundException → JAR 依赖缺失
# - Kafka offset 越界 → 重置 offset
# - 反序列化失败 → 数据格式变更

# 3. 临时措施: 增大重启间隔和次数
-Drestart-strategy=fixed-delay
-Drestart-strategy.fixed-delay.attempts=10
-Drestart-strategy.fixed-delay.delay=60s

# ============================================================
# 故障3: TaskManager Lost
# ============================================================
# 1. 查看 JM 日志
yarn logs -applicationId $APP_ID -containerId <jm-container> -log_files jobmanager.log \
    | grep "TaskManager.*lost\|heartbeat.*timeout"

# 2. 查看丢失的 TM Container 的 NodeManager 日志
# 在对应 NodeManager 节点:
cat /var/log/hadoop/yarn/yarn-yarn-nodemanager-*.log | grep <container-id>

# 3. 常见原因:
# - NM 节点宕机/重启
# - 网络分区
# - GC 暂停超过心跳超时
# 解决: 
-Dheartbeat.timeout=180000    # 增大心跳超时（默认50s）
-Dheartbeat.interval=10000     # 心跳间隔
```

---

## 六、生产最佳实践

### 6.1 资源配置建议

**黄金法则**：
1. **JM 内存**：一般 2~4GB 足够，超大 DAG（>100 算子）可调到 8GB
2. **TM 内存**：根据状态大小决定，无状态 ETL 用 2~4GB，有状态用 4~16GB
3. **Slot 数**：建议 2~4，与 CPU 核数匹配
4. **并行度**：等于 Kafka 分区数（Source 算子）；下游算子可适当调小

### 6.2 作业命名规范

```bash
# 推荐命名格式:
# <团队>-<业务>-<版本>-<环境>
# 示例:
-Dyarn.application.name="data-team-order-pipeline-v1.2-prod"
-Dyarn.application.name="risk-team-fraud-detection-v2.0-staging"
```

### 6.3 日常运维 Checklist

```bash
#!/bin/bash
# daily-check.sh - Flink 作业日常巡检脚本

echo "===== Flink 作业巡检 $(date) ====="

# 1. 检查所有运行中的 Flink 应用
echo "--- 运行中的 Flink 应用 ---"
yarn application -list -appTypes APACHE_FLINK 2>/dev/null | grep RUNNING

# 2. 检查 Checkpoint 状态
for APP_ID in $(yarn application -list -appTypes APACHE_FLINK 2>/dev/null | grep RUNNING | awk '{print $1}'); do
    echo "--- $APP_ID Checkpoint ---"
    JOB_ID=$(curl -s "http://yarn-rm01:8088/proxy/$APP_ID/jobs" \
        | python -c "import sys,json;jobs=json.load(sys.stdin).get('jobs',[]);print(jobs[0]['id'] if jobs else '')" 2>/dev/null)
    if [ -n "$JOB_ID" ]; then
        curl -s "http://yarn-rm01:8088/proxy/$APP_ID/jobs/$JOB_ID/checkpoints" \
            | python -c "import sys,json;d=json.load(sys.stdin);print(f'  Last CP: {d.get(\"latest\",{}).get(\"completed\",{}).get(\"duration\",\"N/A\")}ms, Failed: {d.get(\"counts\",{}).get(\"failed\",0)}')" 2>/dev/null
    fi
done

# 3. 检查 HDFS Checkpoint 目录大小
echo "--- Checkpoint 存储 ---"
hdfs dfs -du -h /flink/checkpoints/ 2>/dev/null | tail -10

# 4. 检查 YARN 队列资源
echo "--- YARN flink 队列 ---"
yarn queue -status flink 2>/dev/null | grep -E "Capacity|Used|Available"

echo "===== 巡检完成 ====="
```

---

## 七、举一反三

### 7.1 运维工具对比

| 对比维度 | Flink CLI | YARN CLI | REST API | Flink Dashboard |
|---------|----------|---------|---------|----------------|
| 提交作业 | ✅ | ❌ | ✅ | ❌ |
| 取消作业 | ✅ | ✅（kill） | ✅ | ✅ |
| Savepoint | ✅ | ❌ | ✅ | ✅ |
| 查看日志 | ❌ | ✅ | ❌ | ✅（部分） |
| 查看指标 | ❌ | ❌ | ✅ | ✅ |
| 批量操作 | ❌ | ✅ | ✅（脚本化） | ❌ |
| 适用场景 | 单作业操作 | 资源管理 | 自动化运维 | 可视化监控 |

### 7.2 面试高频题

**Q1: Flink on YARN Application Mode 和 Per-Job Mode 有什么区别？为什么推荐 Application Mode？**

> **A**: 
> - **Per-Job Mode**（已废弃）：main() 方法在客户端执行，生成 JobGraph 后提交给 YARN。客户端依赖重，需要上传 JAR 到 YARN。
> - **Application Mode**：main() 方法在 JobManager（YARN Container）中执行。优势：
>   1. 客户端轻量化，不需要大量资源
>   2. JAR 可以预先放在 HDFS，避免每次提交上传
>   3. 隔离性好，每个应用独立的 ClassLoader
>   4. 支持一个 Application 内运行多个 Job

**Q2: Flink 作业在 YARN 上如何优雅升级？**

> **A**: 标准流程：
> 1. 触发 Savepoint（`flink stop --savepointPath`）
> 2. 等待旧 YARN Application 结束
> 3. 上传新版本 JAR
> 4. 从 Savepoint 恢复新版本（`flink run-application -s <savepoint-path>`）
> 5. 验证新版本正常运行（检查 CP 是否成功、消费是否正常）
> 6. 保留旧 Savepoint 至少 7 天作为回退点
> 
> 关键注意点：保持 Operator UID 不变，避免状态恢复失败。

**Q3: YARN Container 被 Kill 的常见原因和解决方案？**

> **A**: 
> 1. **物理内存超限**：Container 实际使用内存超过 `taskmanager.memory.process.size` → 增大 TM 内存
> 2. **虚拟内存超限**：YARN 默认检查虚拟内存（vmem = pmem × 2.1）→ 关闭 `yarn.nodemanager.vmem-check-enabled`
> 3. **RocksDB 堆外内存**：RocksDB 的 block cache / memtable 不受 JVM Heap 管理 → 增大 managed memory
> 4. **用户代码内存泄漏**：JNI/DirectByteBuffer 泄漏 → 排查代码
> 5. **YARN 资源抢占**：高优先级队列抢占低优先级 Container → 调整队列优先级

**Q4: 如何监控 Flink 作业的消费延迟？**

> **A**: 多层监控：
> 1. **Kafka Consumer Lag**：`pendingRecords` 指标，反映 Kafka 未消费消息数
> 2. **Event Time Watermark**：`currentInputWatermark` 与当前时间的差值，反映事件时间处理延迟
> 3. **处理延迟**：`latency.source_id.operator_id.operator_subtask_index.latency_max`
> 4. **Checkpoint 指标**：CP 耗时增加通常意味着吞吐下降
> 
> 告警规则：Kafka Lag >10万 或 Watermark 延迟 >5分钟 或 CP 持续失败 → 触发告警

### 7.3 思考题

1. **自动化运维题**：设计一个 Flink 作业自动化运维平台，需要支持：一键提交/升级/扩缩容、自动故障恢复（从最近 CP 恢复）、资源弹性伸缩。请画出架构图并说明核心模块。

2. **容灾设计题**：公司有两个数据中心（北京和上海），需要设计 Flink 作业的跨机房容灾方案。当北京机房故障时，上海机房的 Flink 作业能在 5 分钟内接管。请设计方案。

3. **成本优化题**：团队有 50+ 个 Flink 作业运行在 YARN 上，总资源占用 500 个 Container。经分析发现 60% 的作业 CPU 利用率不到 20%。如何优化资源利用率同时保证作业稳定性？

---

> 📝 **本教案配套资源**
> - 升级脚本模板: `scripts/upgrade-flink-job.sh`
> - 日常巡检脚本: `scripts/daily-check.sh`
> - Prometheus 配置: `monitoring/prometheus-flink.yml`
> - Grafana Dashboard: `monitoring/flink-ops-dashboard.json`
> - AlertManager 规则: `monitoring/flink-alert-rules.yml`
