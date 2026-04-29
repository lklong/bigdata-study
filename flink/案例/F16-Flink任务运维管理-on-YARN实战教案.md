# [教案] Flink on YARN — 任务运维管理实战使用姿势

> 🎯 教学目标：掌握 Flink on YARN 的完整运维操作，包括命令大全(提交/查看/取消/停止/恢复)、YARN 日志获取、Web UI 访问、升级流程、并行度调整与扩缩容、资源配置公式、Prometheus+Grafana 监控、常见故障排查 | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 为什么需要掌握运维管理？

**生活类比**：开发 Flink 作业就像造一辆车，运维管理就像"开车上路"——你需要知道怎么启动、怎么换挡（调整并行度）、怎么加油（扩资源）、怎么看仪表盘（监控）、怎么处理抛锚（故障排查）。

生产环境中，80% 的时间花在运维上：
- 作业提交/升级/回滚
- 性能调优/扩缩容
- 故障发现/定位/恢复
- 监控告警

### 1.2 运维操作全景图

```
┌──────── 生命周期管理 ────────┐
│ 提交 → 运行 → 停止/取消     │
│ 恢复 → 升级 → 扩缩容        │
└─────────────────────────────┘

┌──────── 观测 ────────────────┐
│ Web UI / REST API            │
│ YARN 日志 / Container 日志    │
│ Prometheus + Grafana         │
└─────────────────────────────┘

┌──────── 故障处理 ────────────┐
│ CP 失败 / TM Lost           │
│ Container Kill / OOM         │
│ 重启循环 / 数据倾斜          │
└─────────────────────────────┘
```

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 说明 |
|------|------|
| Flink CLI | `$FLINK_HOME/bin/flink` |
| YARN CLI | `yarn` 命令可用 |
| HDFS | 存储 JAR/CP/SP |
| Prometheus + Grafana | 可选，用于监控 |

### 2.2 环境变量

```bash
export FLINK_HOME=/opt/flink
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=`hadoop classpath`
export PATH=$FLINK_HOME/bin:$PATH
```

---

## 三、核心使用方式 — 完整命令大全

### 3.1 作业提交

```bash
# ===== Per-Job 模式（已废弃，仅旧版本） =====
flink run -m yarn-cluster \
    -ynm "my-flink-job" \
    -yjm 4096 \
    -ytm 8192 \
    -ys 4 \
    -yD parallelism.default=8 \
    -c com.example.MyJob \
    /path/to/my-job.jar

# ===== Session 模式 =====
# 1. 启动 Session
yarn-session.sh -d \
    -nm "flink-session" \
    -jm 4096 \
    -tm 8192 \
    -s 4 \
    -D yarn.application.queue=production

# 2. 提交作业到 Session
flink run -c com.example.MyJob /path/to/my-job.jar

# ===== Application 模式（推荐） =====
flink run-application -t yarn-application \
    -Dyarn.application.name="my-flink-app" \
    -Dyarn.application.queue=production \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=8 \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar

# ===== SQL Client 模式 =====
# 1. 嵌入模式
sql-client.sh

# 2. 连接到 Session
sql-client.sh -s yarn-session
```

### 3.2 作业查看

```bash
# 查看运行中的作业（需要知道 YARN App ID）
flink list -m yarn-cluster -yid <yarn-application-id>

# 通过 YARN 查看所有 Flink 应用
yarn application -list -appTypes APACHE_FLINK

# 查看作业详情
flink list -r -yid <yarn-application-id>  # running
flink list -a -yid <yarn-application-id>  # all (包括完成的)

# 通过 REST API 查看
curl http://<jobmanager-host>:<rest-port>/jobs
curl http://<jobmanager-host>:<rest-port>/jobs/<job-id>
curl http://<jobmanager-host>:<rest-port>/jobs/<job-id>/checkpoints
```

### 3.3 作业停止/取消

```bash
# ===== 优雅停止（带 Savepoint，推荐） =====
# 先创建 Savepoint 再停止
flink stop --savepointPath hdfs:///flink/savepoints/ <job-id> -yid <yarn-app-id>

# ===== 取消作业（不带 Savepoint） =====
flink cancel <job-id> -yid <yarn-app-id>

# ===== 取消并创建 Savepoint =====
flink cancel -s hdfs:///flink/savepoints/ <job-id> -yid <yarn-app-id>

# ===== 强制杀死 YARN Application =====
yarn application -kill <yarn-application-id>
```

### 3.4 作业恢复

```bash
# 从 Savepoint 恢复
flink run-application -t yarn-application \
    -s hdfs:///flink/savepoints/savepoint-abc123 \
    -Dyarn.application.name="my-job-recovered" \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar

# 从 Checkpoint 恢复
flink run-application -t yarn-application \
    -s hdfs:///flink/checkpoints/<job-id>/chk-100 \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar

# 允许跳过无法恢复的状态
flink run-application -t yarn-application \
    -s hdfs:///flink/savepoints/savepoint-abc123 \
    -Dexecution.savepoint.ignore-unclaimed-state=true \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar
```

### 3.5 手动触发 Savepoint

```bash
# 触发 Savepoint（不停止作业）
flink savepoint <job-id> hdfs:///flink/savepoints/ -yid <yarn-app-id>

# 使用 REST API 触发
curl -X POST http://<jm-host>:<port>/jobs/<job-id>/savepoints \
    -H "Content-Type: application/json" \
    -d '{"target-directory": "hdfs:///flink/savepoints/", "cancel-job": false}'
```

---

## 四、完整实战示例

### 4.1 场景一：YARN 日志获取

```bash
# 方式1：获取已完成应用的全部日志
yarn logs -applicationId <yarn-app-id>

# 方式2：获取特定 Container 的日志
yarn logs -applicationId <yarn-app-id> -containerId <container-id>

# 方式3：获取运行中应用的日志（实时）
yarn logs -applicationId <yarn-app-id> -am  # 只看 AM(JM) 日志

# 方式4：按关键字搜索
yarn logs -applicationId <yarn-app-id> | grep -i "exception\|error\|oom"

# 方式5：获取 Container 日志目录
# 运行中的 Container 日志在 NodeManager 本地：
# /data/yarn/logs/<user>/logs/<app-id>/<container-id>/

# 方式6：Web UI 查看日志
# YARN ResourceManager UI → Application → Logs
echo "http://$(hostname):8088/cluster/app/<yarn-app-id>"
```

### 4.2 场景二：Web UI 访问

```bash
# 获取 Flink Web UI 地址
# 方式1：从 YARN 获取
yarn application -status <yarn-app-id> | grep "Tracking-URL"

# 方式2：通过 YARN Proxy（推荐，安全环境）
echo "http://yarn-rm-host:8088/proxy/<yarn-app-id>/"

# 方式3：直接访问 JM（需要知道 JM 所在节点）
# 从 YARN 获取 AM Container 所在节点
yarn application -status <yarn-app-id> | grep "AM Host"
# 默认端口：8081

# Web UI 关键页面
# /jobs                    - 作业列表
# /jobs/<id>              - 作业详情
# /jobs/<id>/checkpoints  - CP 信息
# /taskmanagers           - TM 列表
# /jobmanager/config      - JM 配置
# /jobmanager/metrics     - JM 指标
```

### 4.3 场景三：作业升级流程

```bash
# 标准升级流程（零数据丢失）

# Step 1: 触发 Savepoint 并停止当前作业
flink stop --savepointPath hdfs:///flink/savepoints/ <old-job-id> -yid <old-app-id>
# 记录 Savepoint 路径: hdfs:///flink/savepoints/savepoint-xxx

# Step 2: 部署新版本 JAR
hdfs dfs -put my-job-v2.jar hdfs:///flink/jars/my-job-v2.jar

# Step 3: 从 Savepoint 启动新版本
flink run-application -t yarn-application \
    -s hdfs:///flink/savepoints/savepoint-xxx \
    -Dyarn.application.name="my-job-v2" \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job-v2.jar

# Step 4: 验证新版本正常运行
flink list -m yarn-cluster -yid <new-app-id>
# 检查 CP 是否正常、数据是否正常处理

# Step 5: 清理旧版本（确认无问题后）
hdfs dfs -rm hdfs:///flink/jars/my-job-v1.jar
```

### 4.4 场景四：并行度调整与扩缩容

```bash
# Flink 1.18+ 支持 Reactive Mode（自动扩缩容）
flink run-application -t yarn-application \
    -Dscheduler-mode=reactive \
    -Dyarn.application.name="reactive-job" \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar

# 手动扩缩容流程（传统方式）
# 1. 停止 + Savepoint
flink stop --savepointPath hdfs:///flink/savepoints/ <job-id> -yid <app-id>

# 2. 以新并行度恢复
flink run-application -t yarn-application \
    -s hdfs:///flink/savepoints/savepoint-xxx \
    -Dparallelism.default=16 \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar
# 新并行度16 / 4slots = 需要 4 个 TM

# Session 模式下动态添加 TM
# 通过 YARN 命令增加 Container
yarn container -signal <container-id> <signal>
```

### 4.5 场景五：JM/TM 资源配置公式

```bash
# ===== JobManager 内存配置 =====
# JM 内存 = JVM Heap + Off-Heap + Metaspace + Overhead
# 推荐：小作业 2-4GB，大作业 4-8GB
-Djobmanager.memory.process.size=4096m
-Djobmanager.memory.heap.size=2048m         # 可选，否则自动计算

# ===== TaskManager 内存配置 =====
# TM 总内存 = Framework Heap + Task Heap + Managed + Network + Framework Off-Heap + Task Off-Heap + Metaspace + Overhead
-Dtaskmanager.memory.process.size=8192m

# 各部分计算：
# Task Heap: 业务逻辑使用（推荐总内存的 40-60%）
-Dtaskmanager.memory.task.heap.size=3072m

# Managed Memory: RocksDB/排序/缓存（推荐总内存的 30-40%）
-Dtaskmanager.memory.managed.fraction=0.4

# Network: 网络缓冲区（推荐总内存的 10%）
-Dtaskmanager.memory.network.fraction=0.1
-Dtaskmanager.memory.network.min=256mb
-Dtaskmanager.memory.network.max=1024mb

# ===== 资源计算公式 =====
# TM 数量 = ceil(parallelism / taskmanager.numberOfTaskSlots)
# 例：并行度=16, slots=4 → 需要 4 个 TM

# 总内存 = JM内存 + TM数量 × TM内存
# 例：4096 + 4 × 8192 = 36864 MB ≈ 36GB

# Slot 数量选择：
# CPU 密集型：slots = CPU cores per TM
# IO 密集型：slots = 2~4 × CPU cores per TM
```

### 4.6 场景六：Prometheus + Grafana 监控

#### 配置 Flink Metrics Reporter

```yaml
# flink-conf.yaml
metrics.reporters: prom
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporterFactory
metrics.reporter.prom.port: 9249

# 如果在 YARN 上，使用随机端口 + Pushgateway
metrics.reporter.promgateway.factory.class: org.apache.flink.metrics.prometheus.PrometheusPushGatewayReporterFactory
metrics.reporter.promgateway.hostUrl: http://pushgateway:9091
metrics.reporter.promgateway.jobName: flink-metrics
metrics.reporter.promgateway.randomJobNameSuffix: true
metrics.reporter.promgateway.deleteOnShutdown: false
metrics.reporter.promgateway.groupingKey: "instance=flink-yarn"
```

#### Prometheus 配置

```yaml
# prometheus.yml
scrape_configs:
  # 方式1：直接抓取（Session模式，端口固定）
  - job_name: 'flink'
    static_configs:
      - targets: ['flink-jm:9249', 'flink-tm-1:9249', 'flink-tm-2:9249']

  # 方式2：通过 Pushgateway（YARN模式推荐）
  - job_name: 'flink-pushgateway'
    static_configs:
      - targets: ['pushgateway:9091']
```

#### 关键 Grafana Dashboard 指标

```
# 作业概览
- flink_jobmanager_job_uptime: 运行时长
- flink_jobmanager_job_numRestarts: 重启次数
- flink_jobmanager_job_lastCheckpointDuration: 最近CP耗时
- flink_jobmanager_job_lastCheckpointSize: 最近CP大小

# 吞吐量
- rate(flink_taskmanager_job_task_numRecordsIn[1m]): 输入速率
- rate(flink_taskmanager_job_task_numRecordsOut[1m]): 输出速率
- rate(flink_taskmanager_job_task_numBytesIn[1m]): 输入字节率

# 延迟
- flink_taskmanager_job_task_operator_currentInputWatermark: 当前 Watermark
- flink_taskmanager_job_latency_source_id_*: Source 到 Sink 延迟

# 反压
- flink_taskmanager_job_task_isBackPressured: 是否反压
- flink_taskmanager_job_task_busyTimeMsPerSecond: 算子繁忙率

# JVM
- flink_taskmanager_Status_JVM_Memory_Heap_Used: 堆内存使用
- flink_taskmanager_Status_JVM_GarbageCollector_G1_Old_Generation_Count: Full GC 次数
- flink_taskmanager_Status_JVM_Threads_Count: 线程数
```

### 4.7 场景七：常见故障排查

#### Container 被 Kill (OOM)

```bash
# 1. 确认是 YARN Kill
yarn logs -applicationId <app-id> | grep "Container killed"
# 输出: Container [xxx] is running beyond physical memory limits

# 2. 解决方案
# 增加 TM 内存
-Dtaskmanager.memory.process.size=12288m

# 关闭 YARN 严格内存检查（临时）
yarn.nodemanager.pmem-check-enabled=false
yarn.nodemanager.vmem-check-enabled=false

# 或增加 overhead
-Dtaskmanager.memory.jvm-overhead.fraction=0.15
```

#### TM Lost

```bash
# 1. 检查 YARN NodeManager 日志
ssh <nm-host> && tail -500 /var/log/hadoop-yarn/yarn-yarn-nodemanager-*.log | grep "container\|kill"

# 2. 常见原因
# - 磁盘满 → 清理日志/临时文件
# - 网络断开 → 检查交换机/网线
# - NM 进程挂了 → 重启 NM
# - 节点维护 → 等待/手动恢复
```

#### Checkpoint 失败

```bash
# 1. Web UI → Checkpoints → 查看失败原因

# 2. 常见原因及解决
# Timeout → 增大 timeout / 开启增量CP / 非对齐CP
# Declined → 查看 TM 日志（磁盘满/内存不足）
# Expired → 减少 CP 频率 / 增大 min-pause

# 3. 开启 CP 调试日志
-Dlog4j.logger.org.apache.flink.runtime.checkpoint=DEBUG
```

#### 重启循环

```bash
# 1. 查看重启原因
yarn logs -applicationId <app-id> | grep -B5 "restarting\|restart strategy"

# 2. 配置重启策略
-Drestart-strategy=fixed-delay
-Drestart-strategy.fixed-delay.attempts=10
-Drestart-strategy.fixed-delay.delay=30s

# 3. 如果是 OOM 导致的循环重启
# 增加内存 或 优化业务逻辑（减少状态大小）
```

---

## 五、常见问题与排障总表

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | Container 被 Kill | 物理内存超限(OOM) | 增大 TM 内存/增大 overhead/关闭 pmem-check |
| 2 | TM Lost/断连 | 节点故障/NM 挂了 | 检查 NM 日志，等待自动恢复 |
| 3 | CP 超时 | 状态大/反压 | 增量CP/非对齐CP/增大timeout |
| 4 | 持续反压 | 下游慢/数据倾斜 | 增加并行度/优化Sink/解决倾斜 |
| 5 | 重启循环 | 代码bug/资源不足 | 查日志定位异常/增加资源 |
| 6 | 作业提交失败 | YARN 队列资源不足 | 检查队列容量/等待/换队列 |
| 7 | Savepoint 恢复失败 | 算子UID变更 | 设置uid()/用allowNonRestoredState |
| 8 | 数据延迟越来越大 | 吞吐跟不上输入 | 增加并行度/优化逻辑/增加资源 |
| 9 | Web UI 无法访问 | 代理问题/端口 | 通过 YARN Proxy 访问 |
| 10 | GC 频繁 | 堆内存不足/对象过多 | 增大堆/优化数据结构/减少状态 |

---

## 六、生产最佳实践

### 6.1 作业提交标准模板

```bash
#!/bin/bash
# submit-flink-job.sh - 生产环境标准提交脚本

JOB_NAME="${1:-my-flink-job}"
JAR_PATH="${2:-hdfs:///flink/jars/my-job.jar}"
MAIN_CLASS="${3:-com.example.MyJob}"
SAVEPOINT_PATH="${4:-}"  # 可选，恢复时传入

FLINK_ARGS=(
    -t yarn-application
    -Dyarn.application.name="${JOB_NAME}"
    -Dyarn.application.queue=production
    -Djobmanager.memory.process.size=4096m
    -Dtaskmanager.memory.process.size=8192m
    -Dtaskmanager.numberOfTaskSlots=4
    -Dparallelism.default=8
    # Checkpoint
    -Dexecution.checkpointing.interval=60000
    -Dexecution.checkpointing.mode=EXACTLY_ONCE
    -Dexecution.checkpointing.min-pause=30000
    -Dexecution.checkpointing.timeout=600000
    -Dexecution.checkpointing.tolerable-failed-checkpoints=5
    -Dexecution.checkpointing.externalized-checkpoint-retention=RETAIN_ON_CANCELLATION
    # State
    -Dstate.backend=rocksdb
    -Dstate.backend.incremental=true
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints
    -Dstate.savepoints.dir=hdfs:///flink/savepoints
    -Dstate.checkpoints.num-retained=3
    # Metrics
    -Dmetrics.reporter.promgateway.factory.class=org.apache.flink.metrics.prometheus.PrometheusPushGatewayReporterFactory
    -Dmetrics.reporter.promgateway.hostUrl=http://pushgateway:9091
    -Dmetrics.reporter.promgateway.jobName=${JOB_NAME}
    # Restart
    -Drestart-strategy=fixed-delay
    -Drestart-strategy.fixed-delay.attempts=10
    -Drestart-strategy.fixed-delay.delay=30s
)

# 如果有 Savepoint，添加恢复参数
if [ -n "$SAVEPOINT_PATH" ]; then
    FLINK_ARGS+=(-s "$SAVEPOINT_PATH")
fi

# 提交
flink run-application "${FLINK_ARGS[@]}" -c "$MAIN_CLASS" "$JAR_PATH"
```

### 6.2 日常运维 Checklist

```bash
# 每日巡检脚本
#!/bin/bash

echo "=== Flink Applications on YARN ==="
yarn application -list -appTypes APACHE_FLINK

echo "=== Failed Applications (last 24h) ==="
yarn application -list -appStates FAILED | tail -20

echo "=== YARN Queue Usage ==="
yarn queue -status production

echo "=== HDFS Checkpoint 空间 ==="
hdfs dfs -du -h /flink/checkpoints/ | tail -10

echo "=== 告警检查 ==="
# 检查 Prometheus 告警
curl -s http://alertmanager:9093/api/v1/alerts | python3 -m json.tool
```

### 6.3 告警规则

```yaml
groups:
  - name: flink-ops-alerts
    rules:
      - alert: FlinkJobDown
        expr: absent(flink_jobmanager_job_uptime) == 1
        for: 5m
        annotations:
          summary: "Flink 作业不在运行"

      - alert: FlinkHighRestarts
        expr: increase(flink_jobmanager_job_numRestarts[1h]) > 5
        for: 1m
        annotations:
          summary: "1小时内重启超过5次"

      - alert: FlinkBackpressure
        expr: flink_taskmanager_job_task_busyTimeMsPerSecond > 900
        for: 10m
        annotations:
          summary: "持续反压超过10分钟"

      - alert: FlinkConsumerLag
        expr: flink_taskmanager_job_task_operator_KafkaSourceReader_KafkaConsumer_records_lag_max > 100000
        for: 5m
        annotations:
          summary: "Kafka 消费延迟超过10万条"
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: Flink on YARN 的三种部署模式区别？**

> A:
> | 模式 | JM 生命周期 | 主类执行位置 | 适用场景 |
> |------|------------|-------------|----------|
> | Session | 预启动，多作业共享 | Client | 开发/测试/频繁提交 |
> | Per-Job (已废弃) | 每作业独立 | Client | 生产隔离 |
> | Application | 每作业独立 | JM 上执行 | 生产推荐（减少Client依赖） |

**Q2: 如何实现 Flink 作业的零停机升级？**

> A:
> 1. `flink stop --savepointPath` 优雅停止旧版本
> 2. 部署新版本 JAR
> 3. `flink run -s <savepoint-path>` 从 Savepoint 恢复新版本
> 4. 验证新版本运行正常
> 5. 如果异常，从同一 Savepoint 回滚到旧版本

**Q3: TM 被 YARN Kill 的常见原因和排查方法？**

> A:
> 1. **物理内存超限**：TM 实际使用内存 > `yarn.scheduler.maximum-allocation-mb` 或 Container 申请的内存。解决：增大 `taskmanager.memory.process.size` 或增大 `jvm-overhead.fraction`
> 2. **虚拟内存超限**：在开启 vmem-check 时，JVM 的虚拟内存很容易超限。解决：关闭 `yarn.nodemanager.vmem-check-enabled`
> 3. **节点磁盘满**：NM 健康检查失败，杀掉所有 Container。解决：清理磁盘

**Q4: 如何选择并行度？**

> A: 经验公式：
> - Kafka Source: 并行度 = Topic Partition 数
> - 计算算子: 并行度 = 峰值QPS / 单并行实例处理能力
> - Sink: 并行度 = 下游写入限制（如 JDBC 连接池大小）
> - 总的 TM 数 = max(各算子并行度) / slots per TM

### 7.2 思考题

1. **Flink 作业运行 30 天后突然 CP 开始失败，可能的原因有哪些？**
2. **如何在不停止作业的情况下获取 Thread Dump 来排查性能问题？**
3. **生产中如何实现 Flink 作业的灰度发布（同时运行新旧版本）？**

---

## 附录：常用命令速查

```bash
# 提交
flink run-application -t yarn-application -c <class> <jar>

# 查看
yarn application -list -appTypes APACHE_FLINK
flink list -yid <app-id>

# 停止（带SP）
flink stop --savepointPath hdfs:///flink/savepoints/ <job-id> -yid <app-id>

# 取消
flink cancel <job-id> -yid <app-id>

# 恢复
flink run-application -t yarn-application -s <sp-path> -c <class> <jar>

# Savepoint
flink savepoint <job-id> <target-dir> -yid <app-id>

# 日志
yarn logs -applicationId <app-id>
yarn logs -applicationId <app-id> -containerId <container-id>

# 强杀
yarn application -kill <app-id>
```

---

**本教案结束。8 篇 Flink on YARN 使用姿势教案全部完成。**
