# [教案] Flink on YARN — 三种部署模式详解（Session / Per-Job / Application）

> 🎯 教学目标：掌握 Flink on YARN 的三种部署模式，理解各模式的适用场景，能独立完成任务提交与运维 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

在生产环境中，Flink 作业几乎都跑在 YARN 上——YARN 提供了统一的资源管理、多租户隔离和弹性伸缩能力。但不同的业务场景对"如何把 Flink 作业跑到 YARN 上"有不同的需求：

| 场景 | 诉求 | 推荐模式 |
|------|------|----------|
| 开发调试，频繁提交小作业 | 启动快、共享资源 | Session Mode |
| 单个大作业，独占资源，互不影响 | 隔离性强 | Per-Job Mode（已废弃，Flink 1.15+） |
| 生产推荐，主类在集群运行 | 隔离 + 省带宽 | **Application Mode**（推荐） |

本教案将带你从零上手三种模式的完整操作流程。

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.15+ (推荐 1.17/1.18) | Application Mode 在 1.11 引入，Per-Job 在 1.15 废弃 |
| Hadoop/YARN | 2.8+ / 3.x | 需要 YARN ResourceManager 正常运行 |
| Java | JDK 8 或 JDK 11 | Flink 1.18+ 推荐 JDK 11 |
| 操作系统 | Linux（CentOS 7/8, Ubuntu 18+） | macOS 可用于本地开发 |

### 2.2 需要的 JAR 包和依赖

```
$FLINK_HOME/lib/
├── flink-dist-*.jar            # 核心包（自带）
├── flink-table-*.jar           # SQL 相关（自带）
└── flink-shaded-hadoop-*-uber.jar  # Hadoop 集成包（需手动添加）

# 或者通过环境变量指定 Hadoop classpath
export HADOOP_CLASSPATH=`hadoop classpath`
```

### 2.3 环境准备命令

```bash
# ============================================================
# 1. 下载并解压 Flink
# ============================================================
FLINK_VERSION=1.18.1
wget https://archive.apache.org/dist/flink/flink-${FLINK_VERSION}/flink-${FLINK_VERSION}-bin-scala_2.12.tgz
tar -xzf flink-${FLINK_VERSION}-bin-scala_2.12.tgz
export FLINK_HOME=$(pwd)/flink-${FLINK_VERSION}
export PATH=$FLINK_HOME/bin:$PATH

# ============================================================
# 2. 配置 Hadoop 环境变量（关键！）
# ============================================================
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)

# ============================================================
# 3. 验证环境
# ============================================================
# 检查 YARN 是否正常
yarn node -list
# 检查 Flink 版本
flink --version
# 检查 Hadoop classpath 是否生效
echo $HADOOP_CLASSPATH

# ============================================================
# 4. （可选）如果没有 hadoop classpath，手动放入 flink-shaded-hadoop
# ============================================================
# 下载 flink-shaded-hadoop-3-uber
wget https://repo.maven.apache.org/maven2/org/apache/flink/flink-shaded-hadoop-3-uber/1.18.1/flink-shaded-hadoop-3-uber-1.18.1.jar \
  -P $FLINK_HOME/lib/
```

### 2.4 关键配置文件

编辑 `$FLINK_HOME/conf/flink-conf.yaml`：

```yaml
# ============================================================
# flink-conf.yaml 基础配置
# ============================================================

# JobManager 内存
jobmanager.memory.process.size: 2048m

# TaskManager 内存
taskmanager.memory.process.size: 4096m

# 每个 TaskManager 的 Slot 数
taskmanager.numberOfTaskSlots: 4

# 并行度
parallelism.default: 4

# Classloader 配置（解决依赖冲突）
classloader.resolve-order: parent-first

# HA 配置（生产必须）
# high-availability: zookeeper
# high-availability.zookeeper.quorum: zk1:2181,zk2:2181,zk3:2181
# high-availability.storageDir: hdfs:///flink/ha/
# high-availability.zookeeper.path.root: /flink

# 历史服务器（推荐配置）
jobmanager.archive.fs.dir: hdfs:///flink/completed-jobs/
historyserver.archive.fs.dir: hdfs:///flink/completed-jobs/
historyserver.web.address: 0.0.0.0
historyserver.web.port: 8082
```

---

## 三、核心使用方式

### 3.1 方式一: Session Mode（会话模式）

**原理**：先在 YARN 上启动一个长期运行的 Flink 集群（Session），然后向该集群反复提交作业。所有作业共享 JobManager 和 TaskManager 资源。

**适用场景**：开发调试、频繁提交小作业、交互式查询（SQL Client）。

#### 第一步：启动 YARN Session

```bash
# ============================================================
# 启动 Flink YARN Session 集群
# ============================================================
$FLINK_HOME/bin/yarn-session.sh \
  -nm "flink-session-cluster" \
  -jm 2048 \
  -tm 4096 \
  -s 4 \
  -d \
  -qu default \
  -Dyarn.application.name="Flink Session Cluster" \
  -Dyarn.provided.lib.dirs="hdfs:///flink/libs" \
  -Dweb.upload.dir=/tmp/flink-web-upload
```

**参数详解表**：

| 参数 | 全称 | 含义 | 推荐值 | 注意事项 |
|------|------|------|--------|----------|
| `-nm` | `--name` | YARN Application 名称 | 有意义的名称 | 方便在 YARN UI 中识别 |
| `-jm` | `--jobManagerMemory` | JobManager 内存（MB） | 2048-4096 | 包含 JVM Heap + Off-Heap + Metaspace |
| `-tm` | `--taskManagerMemory` | 每个 TaskManager 内存（MB） | 4096-8192 | 根据作业需求调整 |
| `-s` | `--slots` | 每个 TM 的 Slot 数 | 2-8 | 通常等于 TM 可用 CPU 核数 |
| `-d` | `--detached` | 后台运行 | 必加 | 不加会阻塞终端 |
| `-qu` | `--queue` | YARN 队列 | 业务队列名 | 注意队列容量和权限 |
| `-Dyarn.provided.lib.dirs` | - | 预上传的 Flink lib 目录 | HDFS 路径 | 避免每次上传，加速启动 |

启动成功后输出：

```
JobManager Web Interface: http://host:port
# 并生成 /tmp/.yarn-properties-<user> 文件
```

#### 第二步：向 Session 提交作业

```bash
# ============================================================
# 方式A：自动连接（使用 .yarn-properties 文件）
# ============================================================
$FLINK_HOME/bin/flink run \
  -c com.example.MyFlinkJob \
  /path/to/my-flink-job.jar \
  --input hdfs:///data/input \
  --output hdfs:///data/output

# ============================================================
# 方式B：指定 YARN Application ID（推荐，更明确）
# ============================================================
$FLINK_HOME/bin/flink run \
  -t yarn-session \
  -Dyarn.application.id=application_1234567890_0001 \
  -c com.example.MyFlinkJob \
  /path/to/my-flink-job.jar

# ============================================================
# 方式C：指定 JobManager 地址
# ============================================================
$FLINK_HOME/bin/flink run \
  -m yarn-cluster \
  -yid application_1234567890_0001 \
  -c com.example.MyFlinkJob \
  /path/to/my-flink-job.jar
```

#### 第三步：管理 Session 集群

```bash
# 查看正在运行的作业
$FLINK_HOME/bin/flink list \
  -t yarn-session \
  -Dyarn.application.id=application_1234567890_0001

# 取消某个作业（带 Savepoint）
$FLINK_HOME/bin/flink cancel \
  -t yarn-session \
  -Dyarn.application.id=application_1234567890_0001 \
  -s hdfs:///flink/savepoints/ \
  <job-id>

# 停止整个 Session 集群
echo "stop" | $FLINK_HOME/bin/yarn-session.sh -id application_1234567890_0001

# 或直接用 yarn 命令 kill
yarn application -kill application_1234567890_0001
```

---

### 3.2 方式二: Per-Job Mode（单作业模式）

> ⚠️ **注意**：Per-Job Mode 在 Flink 1.15 中被标记为废弃（deprecated），推荐使用 Application Mode 替代。本节仅作了解。

**原理**：每提交一个作业，YARN 就创建一个独立的 Flink 集群（独立的 JobManager + TaskManagers）。作业结束后集群自动销毁。

**适用场景**：需要严格资源隔离的大作业。

```bash
# ============================================================
# Per-Job Mode 提交（Flink < 1.15）
# ============================================================
$FLINK_HOME/bin/flink run \
  -t yarn-per-job \
  -d \
  -ynm "per-job-etl-task" \
  -yjm 2048 \
  -ytm 4096 \
  -ys 4 \
  -yqu production \
  -p 8 \
  -c com.example.MyFlinkJob \
  /path/to/my-flink-job.jar \
  --input hdfs:///data/input \
  --output hdfs:///data/output
```

**参数详解表**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `-t yarn-per-job` | 指定 Per-Job 模式 | - | Flink 1.15+ 已废弃 |
| `-d` | 后台运行 | 必加 | 否则会阻塞终端 |
| `-ynm` | YARN Application 名称 | 有意义的名称 | - |
| `-yjm` | JobManager 内存（MB） | 2048+ | - |
| `-ytm` | TaskManager 内存（MB） | 4096+ | - |
| `-ys` | 每个 TM 的 Slot 数 | 2-8 | - |
| `-yqu` | YARN 队列 | 按业务分 | - |
| `-p` | 并行度 | 根据数据量 | 决定 TM 数量 |
| `-c` | 入口类 | 全限定名 | - |

---

### 3.3 方式三: Application Mode（应用模式） ⭐ 推荐

**原理**：用户的 `main()` 方法在 YARN 集群的 JobManager 上执行（而非客户端）。客户端只负责提交，不参与作业执行。每个 Application 对应一个独立的 YARN Application。

**核心优势**：
- ✅ 客户端轻量（不执行 main，不加载用户 JAR）
- ✅ 资源隔离（每个作业独立集群）
- ✅ 适合 CI/CD 自动化部署
- ✅ 减少客户端 OOM 风险（main 中生成 JobGraph 可能很消耗资源）

```bash
# ============================================================
# Application Mode 提交（推荐方式）
# ============================================================
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -d \
  -Dyarn.application.name="app-mode-realtime-etl" \
  -Dyarn.application.queue=production \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=8 \
  -Dyarn.application.priority=5 \
  -Dyarn.ship-files=/opt/flink/plugins/metrics-prometheus/ \
  -c com.example.MyFlinkJob \
  hdfs:///flink/jars/my-flink-job.jar \
  --input hdfs:///data/input \
  --output hdfs:///data/output
```

**参数详解表**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `-t yarn-application` | 指定 Application 模式 | - | Flink 1.11+ 支持 |
| `-d` | 后台运行 | 必加 | - |
| `-Dyarn.application.name` | YARN Application 名称 | 有意义的名称 | 便于 YARN UI 查找 |
| `-Dyarn.application.queue` | YARN 队列 | 按业务分 | - |
| `-Djobmanager.memory.process.size` | JM 进程总内存 | 2048m-4096m | 包含 Heap + Metaspace |
| `-Dtaskmanager.memory.process.size` | TM 进程总内存 | 4096m-8192m | 根据作业复杂度调整 |
| `-Dtaskmanager.numberOfTaskSlots` | 每个 TM 的 Slot 数 | 2-8 | ≈ CPU 核数 |
| `-Dparallelism.default` | 默认并行度 | 4-64 | TM数 = parallelism / slots |
| `-Dyarn.application.priority` | YARN 优先级 | 0-10 | 数值越大优先级越高 |
| `-Dyarn.ship-files` | 随作业分发的文件/目录 | 插件/配置路径 | 会上传到 HDFS |
| `-c` | 入口主类 | 全限定名 | Application Mode 必须指定 |
| 最后的 JAR 路径 | 作业 JAR | 支持 hdfs:// 路径 | **推荐放 HDFS，避免反复上传** |

#### Application Mode 高级用法

```bash
# ============================================================
# 1. JAR 包预上传到 HDFS（推荐！大幅加速启动）
# ============================================================
# 先上传用户 JAR
hdfs dfs -mkdir -p /flink/jars
hdfs dfs -put my-flink-job.jar /flink/jars/

# 先上传 Flink Dist（所有作业共用，只传一次）
hdfs dfs -mkdir -p /flink/libs
hdfs dfs -put $FLINK_HOME/lib/* /flink/libs/
hdfs dfs -put $FLINK_HOME/plugins/* /flink/plugins/

# 提交时引用 HDFS 路径
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -Dyarn.provided.lib.dirs="hdfs:///flink/libs;hdfs:///flink/plugins" \
  -c com.example.MyFlinkJob \
  hdfs:///flink/jars/my-flink-job.jar

# ============================================================
# 2. 使用动态资源（TM 自动伸缩）
# ============================================================
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -Dslotmanager.number-of-slots.min=4 \
  -Dresourcemanager.adaptive-scheduler.enabled=true \
  -c com.example.MyFlinkJob \
  hdfs:///flink/jars/my-flink-job.jar
```

---

## 四、完整实战示例

### 4.1 场景描述

使用 Flink 自带的 WordCount 示例，分别用三种模式提交到 YARN，并对比执行效果。

### 4.2 准备测试数据

```bash
# 创建测试输入
echo "hello world hello flink hello yarn flink on yarn" > /tmp/wordcount-input.txt
hdfs dfs -mkdir -p /flink/test/input
hdfs dfs -put /tmp/wordcount-input.txt /flink/test/input/
```

### 4.3 Session Mode 示例

```bash
# Step 1: 启动 Session
$FLINK_HOME/bin/yarn-session.sh \
  -nm "wordcount-session" \
  -jm 1024 \
  -tm 2048 \
  -s 2 \
  -d

# Step 2: 提交 WordCount
$FLINK_HOME/bin/flink run \
  $FLINK_HOME/examples/batch/WordCount.jar \
  --input hdfs:///flink/test/input/wordcount-input.txt \
  --output hdfs:///flink/test/output/session-result

# Step 3: 查看结果
hdfs dfs -cat /flink/test/output/session-result/*

# Step 4: 关闭 Session
yarn application -kill $(yarn application -list | grep "wordcount-session" | awk '{print $1}')
```

### 4.4 Per-Job Mode 示例

```bash
# 一步提交（Flink < 1.15）
$FLINK_HOME/bin/flink run \
  -t yarn-per-job \
  -d \
  -ynm "wordcount-perjob" \
  -yjm 1024 \
  -ytm 2048 \
  $FLINK_HOME/examples/batch/WordCount.jar \
  --input hdfs:///flink/test/input/wordcount-input.txt \
  --output hdfs:///flink/test/output/perjob-result

# 查看结果
hdfs dfs -cat /flink/test/output/perjob-result/*
```

### 4.5 Application Mode 示例

```bash
# 先上传 JAR 到 HDFS
hdfs dfs -mkdir -p /flink/examples
hdfs dfs -put $FLINK_HOME/examples/batch/WordCount.jar /flink/examples/

# Application Mode 提交
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -d \
  -Dyarn.application.name="wordcount-app-mode" \
  -Djobmanager.memory.process.size=1024m \
  -Dtaskmanager.memory.process.size=2048m \
  -Dtaskmanager.numberOfTaskSlots=2 \
  -c org.apache.flink.examples.java.wordcount.WordCount \
  hdfs:///flink/examples/WordCount.jar \
  --input hdfs:///flink/test/input/wordcount-input.txt \
  --output hdfs:///flink/test/output/app-result

# 查看结果
hdfs dfs -cat /flink/test/output/app-result/*
```

### 4.6 验证结果与日志查看

```bash
# ============================================================
# 查看 YARN Application 状态
# ============================================================
yarn application -list -appStates ALL | grep wordcount

# ============================================================
# 查看 YARN Application 日志（最重要的排障手段）
# ============================================================
# 查看全部日志
yarn logs -applicationId application_1234567890_0001

# 只看 JobManager 日志
yarn logs -applicationId application_1234567890_0001 -containerId <am-container-id>

# 只看特定 TaskManager 日志
yarn logs -applicationId application_1234567890_0001 -containerId <tm-container-id>

# 日志聚合到 HDFS 后查看（需开启 yarn.log-aggregation-enable）
yarn logs -applicationId application_1234567890_0001 | less

# ============================================================
# 通过 YARN Web UI 查看
# ============================================================
# ResourceManager UI: http://<rm-host>:8088
# 点击 Application → Logs 可查看各 Container 日志
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `ClassNotFoundException: org.apache.hadoop.yarn.client...` | 缺少 Hadoop 依赖 | `export HADOOP_CLASSPATH=$(hadoop classpath)` 或放入 flink-shaded-hadoop JAR |
| `Could not build the program from JAR file` | main 类找不到或 JAR 有问题 | 检查 `-c` 参数和 JAR 的 MANIFEST.MF |
| YARN 报 `AM is not registered` | JM 启动超时 | 增大 `yarn.application.attempt-failures-validity-interval` 和 JM 内存 |
| `Insufficient number of network buffers` | 网络缓冲不足 | 增大 `taskmanager.memory.network.fraction`（默认 0.1） |
| YARN 报 `Container killed by YARN for exceeding memory limits` | TM 物理内存超限 | 增大 `taskmanager.memory.process.size` 或设 `containerized.heap-newRatio` |
| `java.io.IOException: No space left on device` | TM 本地磁盘满 | 清理 `/tmp` 或配置 `io.tmp.dirs` 到大容量磁盘 |
| 作业提交后一直 ACCEPTED 不运行 | YARN 队列资源不足 | 检查队列容量：`yarn queue -status <queue>` |
| Application Mode: `FlinkUserCodeClassLoaders ... NoClassDefFoundError` | JAR 依赖缺失 | 使用 fat jar（shade 插件打包）或 `-Dyarn.ship-files` 附加依赖 |
| Session 集群中某作业 OOM 影响其他作业 | Session 模式隔离性差 | 生产用 Application Mode；或设置 `taskmanager.memory.task.heap.size` 限制单个 Slot |
| `Could not find a valid YARN environment` | YARN 环境变量未配置 | 检查 `HADOOP_HOME`、`HADOOP_CONF_DIR`、`YARN_CONF_DIR` |

---

## 六、生产最佳实践

### 6.1 资源配置建议

```yaml
# ============================================================
# 生产环境推荐配置（Application Mode）
# ============================================================

# --- JobManager ---
jobmanager.memory.process.size: 4096m
jobmanager.memory.jvm-metaspace.size: 256m
# JM Heap 主要用于: JobGraph、ExecutionGraph、Checkpoint 协调

# --- TaskManager ---
taskmanager.memory.process.size: 8192m
taskmanager.memory.task.heap.size: 4096m        # 用户代码可用堆内存
taskmanager.memory.managed.size: 2048m           # RocksDB / Sort / Hash 用
taskmanager.memory.network.fraction: 0.1         # 网络缓冲占比
taskmanager.memory.network.min: 256m
taskmanager.memory.network.max: 1024m
taskmanager.memory.jvm-metaspace.size: 256m
taskmanager.memory.jvm-overhead.fraction: 0.1    # JVM Overhead (Native Memory)

# --- Slot 配置 ---
taskmanager.numberOfTaskSlots: 4
# 原则: slots ≈ 可用 CPU 核数
# TM 数量 = ceil(parallelism / slots)

# --- YARN 特有配置 ---
yarn.application.queue: production
yarn.application.priority: 5
yarn.containers.vcores: 4                        # 每个 Container 的虚拟核数
```

### 6.2 关键参数调优

| 参数 | 默认值 | 推荐值 | 调优说明 |
|------|--------|--------|----------|
| `parallelism.default` | 1 | 4-64 | 根据 Kafka Partition 数或数据量调整 |
| `state.backend` | hashmap | rocksdb | 大状态必须用 RocksDB |
| `state.checkpoints.dir` | - | `hdfs:///flink/checkpoints` | 必须配置为 HDFS |
| `state.savepoints.dir` | - | `hdfs:///flink/savepoints` | 方便停止恢复 |
| `execution.checkpointing.interval` | - | 60000 (1min) | 根据容忍的数据丢失量调 |
| `execution.checkpointing.min-pause` | 0 | 30000 | 避免 checkpoint 过于频繁 |
| `restart-strategy` | - | `fixed-delay` | 生产必须配置重启策略 |
| `restart-strategy.fixed-delay.attempts` | - | 3 | 最多重启 3 次 |
| `restart-strategy.fixed-delay.delay` | - | 30s | 重启间隔 |
| `yarn.provided.lib.dirs` | - | `hdfs:///flink/libs` | **大幅加速启动**，生产必配 |
| `yarn.application.attempt-failures-validity-interval` | 10000 | 60000 | 避免因短暂故障用完重试 |

### 6.3 监控与告警

```bash
# ============================================================
# 1. 配置 Prometheus + Grafana 监控
# ============================================================
# flink-conf.yaml 添加:
metrics.reporter.prometheus.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporterFactory
metrics.reporter.prometheus.port: 9249-9260

# 需要额外拷贝 prometheus reporter JAR:
cp $FLINK_HOME/opt/flink-metrics-prometheus-*.jar $FLINK_HOME/lib/

# ============================================================
# 2. 关键监控指标
# ============================================================
# | 指标 | 说明 | 告警阈值 |
# | flink_taskmanager_job_task_operator_numRecordsInPerSecond | 输入 QPS | 下降 50% |
# | flink_taskmanager_job_task_bufferPool_inPoolUsage | 反压指标 | > 0.9 |
# | flink_jobmanager_job_lastCheckpointDuration | CP 耗时 | > interval*0.8 |
# | flink_jobmanager_job_numberOfFailedCheckpoints | CP 失败数 | > 0 |
# | flink_taskmanager_Status_JVM_Memory_Heap_Used | 堆内存 | > 85% |

# ============================================================
# 3. YARN 级别监控
# ============================================================
# 检查 Application 是否在运行
yarn application -status application_xxxx | grep State

# 脚本化监控（加入 crontab）
#!/bin/bash
APP_NAME="my-flink-app"
RUNNING=$(yarn application -list -appStates RUNNING 2>/dev/null | grep "$APP_NAME" | wc -l)
if [ "$RUNNING" -eq 0 ]; then
  echo "[ALERT] Flink Application '$APP_NAME' is NOT running!" | \
    mail -s "Flink Alert" admin@example.com
fi
```

---

## 七、举一反三

### 7.1 三种模式对比总结

| 维度 | Session Mode | Per-Job Mode | Application Mode |
|------|-------------|--------------|------------------|
| 集群生命周期 | 手动启停，长期运行 | 随作业创建/销毁 | 随作业创建/销毁 |
| main() 执行位置 | 客户端 | 客户端 | **集群（JM）** |
| 资源隔离 | ❌ 共享 | ✅ 独立 | ✅ 独立 |
| 启动速度 | ⚡ 快（复用集群） | 🐢 慢（创建集群） | 🐢 慢（创建集群） |
| 客户端负载 | 重（执行 main） | 重（执行 main） | **轻（不执行 main）** |
| 适合场景 | 开发/调试/SQL Client | 已废弃 | **生产推荐** |
| 多作业支持 | ✅ 支持 | ❌ 一个 | ⚠️ 一个（可多 job） |
| Flink 版本 | 全版本 | < 1.15 | 1.11+ |

### 7.2 面试高频题

**Q1: Flink on YARN 三种模式的核心区别？**

> 核心差异在于两点：(1) 集群生命周期管理——Session 是预创建长期运行，Per-Job 和 Application 都是随作业创建/销毁；(2) main() 方法的执行位置——Session 和 Per-Job 在客户端执行（可能导致客户端资源消耗大），Application Mode 在 JobManager 上执行（客户端轻量）。

**Q2: 为什么推荐 Application Mode？**

> (1) main() 在 JM 上运行，避免客户端 OOM 和网络瓶颈；(2) JAR 可以预上传到 HDFS，客户端不需要传输大 JAR；(3) 天然资源隔离，每个作业独立集群；(4) 适合 CI/CD 自动化，客户端只做提交动作。

**Q3: Session Mode 下一个作业 OOM 会影响其他作业吗？**

> 会。Session 模式下所有作业共享 TaskManager，一个作业的 OOM 可能导致 TM 进程崩溃，同一 TM 上的其他作业 Task 也会失败。这是 Session 模式不推荐用于生产的主要原因。

**Q4: YARN Application 日志怎么查看？**

> 方式一：`yarn logs -applicationId <appId>`（需开启日志聚合）；方式二：通过 YARN RM Web UI 点击 Application → Logs；方式三：在 Flink Web UI 的 TaskManager 页面直接看 stdout/stderr。

### 7.3 思考题

1. **动手题**：在你的测试环境中，分别用 Session Mode 和 Application Mode 提交 WordCount，对比两种模式的 YARN Container 分配情况（`yarn application -status` 查看）。

2. **设计题**：你的团队有 10 个 Flink 流作业和 50 个 Flink 批作业，如何选择部署模式？（提示：流作业用 Application Mode，批作业可以考虑 Session Mode 提高启动速度）

3. **排障题**：Application Mode 提交后，YARN 状态显示 ACCEPTED 但始终不变为 RUNNING，可能的原因有哪些？如何排查？（提示：检查队列资源、AM 资源限制、节点标签约束等）

4. **进阶题**：如果需要实现 Flink 作业的"热更新"（不丢数据地更新作业逻辑），应该怎么做？（提示：Savepoint + Cancel + 从 Savepoint 恢复）

---

> 📝 **教案总结**：本教案覆盖了 Flink on YARN 的三种部署模式，重点推荐 Application Mode 用于生产环境。掌握要点：(1) 环境配置（HADOOP_CLASSPATH 是关键）；(2) Application Mode 命令和参数；(3) YARN 日志查看方法；(4) 资源配置与监控。
