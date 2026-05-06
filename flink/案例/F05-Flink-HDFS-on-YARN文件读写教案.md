# [教案] Flink on YARN — HDFS 文件读写使用姿势

> 🎯 教学目标：掌握 Flink 通过 FileSystem Connector 读写 HDFS 文件的全流程，包括多种格式支持、分桶策略、小文件合并、Checkpoint 与文件提交机制 | ⏰ 预计学时: 75分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

HDFS 是大数据生态最基础的存储层，几乎所有数据最终都要落盘到 HDFS。Flink 读写 HDFS 的典型场景：

| 场景 | 架构 |
|------|------|
| 实时归档 | Kafka → Flink → HDFS（按时间分桶存储） |
| 数据湖写入 | 实时数据落地为 Parquet/ORC 供下游批分析 |
| 批处理 | 读取 HDFS 上的历史数据做 ETL/统计 |
| 数据回放 | 从 HDFS 文件重放数据到 Kafka/数据库 |
| 日志存储 | 实时日志写入 HDFS 长期保存 |

本教案覆盖 Flink FileSystem Connector 的完整使用方法，包括读取和写入 HDFS 的各种格式。

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17+ / 1.18 | - |
| Hadoop/HDFS | 2.8+ / 3.x | HDFS 集群正常运行 |
| YARN | 2.8+ / 3.x | - |
| Java | JDK 8 / JDK 11 | - |

### 2.2 需要的 JAR 包

```bash
# FileSystem Connector 已内置于 Flink，无需额外 JAR
# 但以下格式需要对应的 JAR：

# Parquet 格式支持
cp $FLINK_HOME/opt/flink-sql-parquet-*.jar $FLINK_HOME/lib/

# ORC 格式支持
cp $FLINK_HOME/opt/flink-sql-orc-*.jar $FLINK_HOME/lib/

# Avro 格式支持
cp $FLINK_HOME/opt/flink-sql-avro-*.jar $FLINK_HOME/lib/

# JSON 和 CSV 格式已内置
```

### 2.3 环境准备

```bash
# 环境变量
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)

# 创建 HDFS 目录
hdfs dfs -mkdir -p /data/source/events
hdfs dfs -mkdir -p /data/sink/events_archive
hdfs dfs -mkdir -p /flink/checkpoints

# 准备测试数据（JSON 格式）
cat > /tmp/test_events.json << 'EOF'
{"event_id":"e001","user_id":1001,"event_type":"page_view","amount":0,"ts":"2024-01-15 10:00:00"}
{"event_id":"e002","user_id":1002,"event_type":"click","amount":99.9,"ts":"2024-01-15 10:00:05"}
{"event_id":"e003","user_id":1003,"event_type":"purchase","amount":299.0,"ts":"2024-01-15 10:00:10"}
{"event_id":"e004","user_id":1001,"event_type":"page_view","amount":0,"ts":"2024-01-15 11:00:00"}
{"event_id":"e005","user_id":1004,"event_type":"purchase","amount":599.0,"ts":"2024-01-15 11:00:05"}
EOF
hdfs dfs -put /tmp/test_events.json /data/source/events/

# 准备 Parquet 测试数据（通过 Hive 或 Spark 生成）
# 这里先用 JSON，实战中 HDFS 上常见 Parquet/ORC
```

---

## 三、核心使用方式

### 3.1 读取 HDFS 文件（FileSystem Source）

#### SQL 方式 — 读取各种格式

```sql
-- ============================================================
-- 1. 读取 JSON 格式文件
-- ============================================================
CREATE TABLE hdfs_json_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    ts          STRING
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/source/events/',
    'format' = 'json'
);

-- 批模式读取
SET 'execution.runtime-mode' = 'batch';
SELECT * FROM hdfs_json_source;

-- ============================================================
-- 2. 读取 Parquet 格式文件
-- ============================================================
CREATE TABLE hdfs_parquet_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    event_time  TIMESTAMP(3)
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/events_parquet/',
    'format' = 'parquet'
);

SELECT event_type, COUNT(*), SUM(amount)
FROM hdfs_parquet_source
GROUP BY event_type;

-- ============================================================
-- 3. 读取 ORC 格式文件
-- ============================================================
CREATE TABLE hdfs_orc_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    event_time  TIMESTAMP(3)
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/events_orc/',
    'format' = 'orc'
);

-- ============================================================
-- 4. 读取 CSV 格式文件
-- ============================================================
CREATE TABLE hdfs_csv_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    ts          STRING
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/source/csv_files/',
    'format' = 'csv',
    'csv.field-delimiter' = ',',
    'csv.ignore-parse-errors' = 'true',
    'csv.allow-comments' = 'true'
);

-- ============================================================
-- 5. 读取分区目录
-- ============================================================
CREATE TABLE hdfs_partitioned_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    event_time  TIMESTAMP(3),
    dt          STRING,   -- 分区字段
    hr          STRING    -- 分区字段
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/events/',
    'format' = 'parquet',
    'partition.default-name' = '__DEFAULT__'
);

-- 分区裁剪查询（只读指定分区）
SELECT * FROM hdfs_partitioned_source
WHERE dt = '2024-01-15' AND hr = '10';
```

#### 流模式监控 HDFS 目录（持续读取新文件）

```sql
-- ============================================================
-- 流式监控 HDFS 目录（新文件到达时自动读取）
-- ============================================================
SET 'execution.runtime-mode' = 'streaming';

CREATE TABLE hdfs_streaming_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    ts          STRING
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/source/events/',
    'format' = 'json',
    'source.monitor-interval' = '60s',     -- 目录监控间隔
    'source.path.regex-pattern' = '.*\\.json'  -- 只读 .json 文件
);

-- 这样 Flink 会每 60 秒检查目录中的新文件并读取
SELECT * FROM hdfs_streaming_source;
```

**Source 关键参数详解**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `connector` | 连接器 | filesystem | - |
| `path` | HDFS 路径 | `hdfs://...` | 支持目录和通配符 |
| `format` | 文件格式 | parquet/orc/json/csv | - |
| `source.monitor-interval` | 目录监控间隔 | 60s | 流模式生效 |
| `source.path.regex-pattern` | 文件名正则 | 按需 | 过滤特定文件 |
| `partition.default-name` | 默认分区名 | `__DEFAULT__` | 未匹配分区时使用 |

---

### 3.2 写入 HDFS 文件（FileSink）

#### SQL 方式 — 非分区写入

```sql
-- ============================================================
-- 写入 HDFS（非分区，适合简单归档）
-- ============================================================
CREATE TABLE hdfs_json_sink (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    processed_time TIMESTAMP(3)
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/sink/events_json/',
    'format' = 'json',
    'sink.rolling-policy.file-size' = '128MB',
    'sink.rolling-policy.rollover-interval' = '15min',
    'sink.rolling-policy.check-interval' = '1min'
);
```

#### SQL 方式 — 分区写入（推荐）

```sql
-- ============================================================
-- 写入 HDFS 分区目录（Parquet 格式，按天+小时分区）
-- ============================================================
CREATE TABLE hdfs_parquet_sink (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    amount      DECIMAL(10, 2),
    event_time  TIMESTAMP(3),
    dt          STRING,
    hr          STRING
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/sink/events_parquet/',
    'format' = 'parquet',
    -- 文件滚动策略
    'sink.rolling-policy.file-size' = '128MB',
    'sink.rolling-policy.rollover-interval' = '15min',
    'sink.rolling-policy.check-interval' = '1min',
    -- 分区提交策略
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '5min',
    'sink.partition-commit.watermark-time-zone' = 'Asia/Shanghai',
    'sink.partition-commit.policy.kind' = 'success-file',
    'sink.partition-commit.success-file.name' = '_SUCCESS',
    -- 小文件合并（Flink 1.15+）
    'auto-compaction' = 'true',
    'compaction.file-size' = '256MB'
);

-- 从 Kafka 实时写入 HDFS
INSERT INTO hdfs_parquet_sink
SELECT
    event_id,
    user_id,
    event_type,
    amount,
    event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(event_time, 'HH') AS hr
FROM kafka_source;
```

**Sink 关键参数详解**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `sink.rolling-policy.file-size` | 文件大小上限 | 128MB | 超过则滚动新文件 |
| `sink.rolling-policy.rollover-interval` | 文件时间上限 | 15min | 超过则滚动 |
| `sink.rolling-policy.check-interval` | 检查间隔 | 1min | 检查是否需要滚动 |
| `sink.partition-commit.trigger` | 分区完成触发方式 | partition-time | 基于 Watermark |
| `sink.partition-commit.delay` | 分区提交延迟 | 5min | 等待迟到数据 |
| `sink.partition-commit.policy.kind` | 提交策略 | success-file | 写 _SUCCESS 标记 |
| `auto-compaction` | 自动合并小文件 | true | 强烈推荐 |
| `compaction.file-size` | 合并目标大小 | 256MB | 合并后文件大小 |

---

### 3.3 DataStream API 方式（FileSink）

```java
package com.example.flink;

import org.apache.flink.api.common.serialization.SimpleStringEncoder;
import org.apache.flink.configuration.MemorySize;
import org.apache.flink.connector.file.sink.FileSink;
import org.apache.flink.core.fs.Path;
import org.apache.flink.formats.parquet.avro.ParquetAvroWriters;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.sink.filesystem.OutputFileConfig;
import org.apache.flink.streaming.api.functions.sink.filesystem.bucketassigners.DateTimeBucketAssigner;
import org.apache.flink.streaming.api.functions.sink.filesystem.rollingpolicies.DefaultRollingPolicy;

import java.time.Duration;
import java.time.ZoneId;

public class HDFSFileSinkJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // Checkpoint（写 HDFS 必须开启！）
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(30000);

        // 假设已有 Source DataStream
        DataStream<String> sourceStream = env.fromSource(/* kafka source */)
                .map(/* processing */);

        // ============================================================
        // FileSink 配置
        // ============================================================
        FileSink<String> fileSink = FileSink
                // Row-Format（文本/JSON 等行格式）
                .forRowFormat(
                        new Path("hdfs:///data/sink/events/"),
                        new SimpleStringEncoder<String>("UTF-8")
                )
                // 分桶策略（按时间分目录）
                .withBucketAssigner(
                        new DateTimeBucketAssigner<>(
                                "yyyy-MM-dd/HH",          // 目录格式: /2024-01-15/10/
                                ZoneId.of("Asia/Shanghai")
                        )
                )
                // 文件滚动策略
                .withRollingPolicy(
                        DefaultRollingPolicy.builder()
                                .withMaxPartSize(MemorySize.ofMebiBytes(128))   // 文件大小上限
                                .withRolloverInterval(Duration.ofMinutes(15))    // 时间上限
                                .withInactivityInterval(Duration.ofMinutes(5))   // 无数据时关闭
                                .build()
                )
                // 输出文件命名
                .withOutputFileConfig(
                        OutputFileConfig.builder()
                                .withPartPrefix("events")    // 文件前缀
                                .withPartSuffix(".json")     // 文件后缀
                                .build()
                )
                .build();

        sourceStream.sinkTo(fileSink).name("HDFS FileSink");

        env.execute("HDFS File Sink Job");
    }
}
```

#### Parquet 格式写入（Bulk Format）

```java
// ============================================================
// Parquet 格式 FileSink（适合列式存储场景）
// ============================================================
FileSink<GenericRecord> parquetSink = FileSink
        .forBulkFormat(
                new Path("hdfs:///data/sink/events_parquet/"),
                ParquetAvroWriters.forGenericRecord(avroSchema)
        )
        .withBucketAssigner(
                new DateTimeBucketAssigner<>("yyyy-MM-dd/HH", ZoneId.of("Asia/Shanghai"))
        )
        .withOutputFileConfig(
                OutputFileConfig.builder()
                        .withPartPrefix("data")
                        .withPartSuffix(".parquet")
                        .build()
        )
        .build();
```

---

### 3.4 分桶策略详解

```java
// ============================================================
// 1. DateTimeBucketAssigner（按时间分桶，最常用）
// ============================================================
// 目录结构: /base-path/2024-01-15/10/events-xxx.json
new DateTimeBucketAssigner<>("yyyy-MM-dd/HH", ZoneId.of("Asia/Shanghai"))

// 按天: /base-path/2024-01-15/
new DateTimeBucketAssigner<>("yyyy-MM-dd", ZoneId.of("Asia/Shanghai"))

// ============================================================
// 2. BasePathBucketAssigner（不分桶，全部写到根目录）
// ============================================================
// 目录结构: /base-path/events-xxx.json
new BasePathBucketAssigner<>()

// ============================================================
// 3. 自定义 BucketAssigner
// ============================================================
new BucketAssigner<MyEvent, String>() {
    @Override
    public String getBucketId(MyEvent event, Context context) {
        // 按业务字段分桶
        return String.format("dt=%s/category=%s",
                event.getDate(), event.getCategory());
    }

    @Override
    public SimpleVersionedSerializer<String> getSerializer() {
        return SimpleVersionedStringSerializer.INSTANCE;
    }
}
```

---

### 3.5 Checkpoint 与文件提交的关系

```
┌─────────────────────────────────────────────────────────────────┐
│              文件生命周期（与 Checkpoint 强关联）                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  In-Progress (.inprogress)                                      │
│  ├── 正在写入的文件                                               │
│  ├── Checkpoint 时文件关闭 → 变为 Pending                        │
│  └── 如果作业失败，in-progress 文件被清理                         │
│                                                                 │
│  Pending                                                        │
│  ├── Checkpoint 完成后文件变为 Pending 状态                       │
│  ├── 等待下一个 Checkpoint 确认                                  │
│  └── 对下游不可见                                                │
│                                                                 │
│  Finished                                                       │
│  ├── Checkpoint 成功后 Pending → Finished                       │
│  ├── 文件重命名（去掉 .inprogress 后缀）                        │
│  └── 对下游可见 ✅                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

关键理解：
- 没有 Checkpoint = 文件永远不会变成 Finished
- Checkpoint 间隔越短 = 文件越快对下游可见（但文件越小）
- Checkpoint 失败 = Pending 文件被丢弃，从上个 CP 重来
```

**关键含义**：

| 要点 | 说明 |
|------|------|
| **必须开启 Checkpoint** | 不开 Checkpoint 文件永远是 in-progress 状态 |
| CP 间隔影响文件可见性 | CP 间隔 = 文件最快对下游可见的延迟 |
| CP 间隔影响文件大小 | CP 太频繁 → 每个 CP 产生一个文件 → 小文件 |
| 故障恢复 | 从最近 CP 恢复，in-progress 文件被丢弃重写 |
| Exactly-Once 保证 | CP 机制确保每条数据精确写一次到最终文件 |

---

## 四、完整实战示例

### 4.1 场景描述

Kafka 实时日志 → Flink ETL → HDFS Parquet 归档（按天+小时分区）

### 4.2 完整 SQL 脚本

```sql
-- ============================================================
-- hdfs-archive.sql — 实时日志归档到 HDFS
-- ============================================================

SET 'execution.runtime-mode' = 'streaming';
SET 'parallelism.default' = '8';
SET 'execution.checkpointing.interval' = '120s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints/hdfs-archive';

-- Source: Kafka
CREATE TABLE kafka_logs (
    log_id      STRING,
    service     STRING,
    level       STRING,
    message     STRING,
    log_time    TIMESTAMP(3),
    WATERMARK FOR log_time AS log_time - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'service_logs',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092',
    'properties.group.id' = 'flink-hdfs-archive',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- Sink: HDFS Parquet 分区表
CREATE TABLE hdfs_logs_archive (
    log_id      STRING,
    service     STRING,
    level       STRING,
    message     STRING,
    log_time    TIMESTAMP(3),
    dt          STRING,
    hr          STRING
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/archive/service_logs/',
    'format' = 'parquet',
    'parquet.compression' = 'SNAPPY',
    'sink.rolling-policy.file-size' = '128MB',
    'sink.rolling-policy.rollover-interval' = '15min',
    'sink.rolling-policy.check-interval' = '1min',
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '5min',
    'sink.partition-commit.watermark-time-zone' = 'Asia/Shanghai',
    'sink.partition-commit.policy.kind' = 'success-file',
    'auto-compaction' = 'true',
    'compaction.file-size' = '256MB'
);

-- ETL
INSERT INTO hdfs_logs_archive
SELECT
    log_id,
    service,
    UPPER(level) AS level,
    message,
    log_time,
    DATE_FORMAT(log_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(log_time, 'HH') AS hr
FROM kafka_logs
WHERE level IN ('ERROR', 'WARN', 'INFO');
```

### 4.3 提交命令

```bash
# Application Mode 提交
$FLINK_HOME/bin/sql-client.sh \
  -Dexecution.target=yarn-application \
  -Dyarn.application.name="hdfs-log-archive" \
  -Dyarn.application.queue=production \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -f /opt/flink/scripts/hdfs-archive.sql

# DataStream JAR 方式
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -d \
  -Dyarn.application.name="hdfs-archive-job" \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=8 \
  -Dexecution.checkpointing.interval=120000 \
  -c com.example.flink.HDFSArchiveJob \
  hdfs:///flink/jars/hdfs-archive-job.jar
```

### 4.4 验证结果

```bash
# 查看分区目录结构
hdfs dfs -ls /data/archive/service_logs/
# 输出:
# drwxr-xr-x   - flink supergroup  0 2024-01-15 11:05 /data/archive/service_logs/dt=2024-01-15

hdfs dfs -ls /data/archive/service_logs/dt=2024-01-15/
# 输出:
# drwxr-xr-x   - flink supergroup  0 2024-01-15 11:05 .../hr=10
# drwxr-xr-x   - flink supergroup  0 2024-01-15 12:05 .../hr=11

# 查看文件（合并后应该是大文件）
hdfs dfs -ls -h /data/archive/service_logs/dt=2024-01-15/hr=10/
# 输出:
# -rw-r--r--   3 flink supergroup  128.5M .../part-xxx.parquet
# -rw-r--r--   3 flink supergroup    0    .../_SUCCESS

# 检查 _SUCCESS 标记
hdfs dfs -test -f /data/archive/service_logs/dt=2024-01-15/hr=10/_SUCCESS && echo "Partition committed"

# 用 parquet-tools 查看内容（可选）
hadoop jar parquet-tools.jar head hdfs:///data/archive/service_logs/dt=2024-01-15/hr=10/part-xxx.parquet
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| 文件一直是 `.inprogress` 状态 | 未开启 Checkpoint | 配置 `execution.checkpointing.interval` |
| 大量小文件 | CP 间隔太短或流量太小 | 增大 CP 间隔、开启 `auto-compaction` |
| 数据延迟才可见 | CP 间隔 + 分区提交延迟 | 可见延迟 ≈ CP间隔 + partition-commit.delay |
| `Permission denied` | HDFS 权限 | 确保 Flink 用户有写权限 |
| `Could not create FileSystem` | Hadoop 配置缺失 | 检查 `HADOOP_CLASSPATH` 和 `core-site.xml` |
| 分区目录没有 `_SUCCESS` | 分区提交策略未配置 | 配置 `sink.partition-commit.policy.kind` |
| OOM 写入 Parquet | Parquet 缓存过大 | 减小 `parquet.block-size`，增大 TM 内存 |
| 文件名冲突 | 并行度变化后恢复 | Flink 会自动处理，确保 CP 目录一致 |

---

## 六、生产最佳实践

### 6.1 资源配置建议

```yaml
# HDFS 归档作业推荐配置
jobmanager.memory.process.size: 2048m
taskmanager.memory.process.size: 4096m
taskmanager.numberOfTaskSlots: 4
parallelism.default: 8

# Checkpoint 配置（关键！）
execution.checkpointing.interval: 120000     # 2min
execution.checkpointing.min-pause: 60000     # 最小间隔 1min
execution.checkpointing.timeout: 300000      # 5min 超时

# 文件写入优化
sink.rolling-policy.file-size: 128MB
sink.rolling-policy.rollover-interval: 15min
auto-compaction: true
compaction.file-size: 256MB
```

### 6.2 关键参数调优

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `execution.checkpointing.interval` | 120s | 写文件不宜太频繁 |
| `sink.rolling-policy.file-size` | 128MB | HDFS Block 大小对齐 |
| `sink.rolling-policy.rollover-interval` | 15min | 保证文件定时关闭 |
| `auto-compaction` | true | 自动合并小文件 |
| `compaction.file-size` | 256MB | 合并目标（≈2*rolling-size） |
| `parquet.compression` | SNAPPY / ZSTD | SNAPPY 快，ZSTD 比率高 |
| `parquet.block-size` | 128MB | 对齐 HDFS Block |
| `orc.compress` | SNAPPY / ZLIB | - |

### 6.3 小文件问题终极方案

```sql
-- ============================================================
-- 方案1: auto-compaction（推荐，Flink 原生）
-- ============================================================
-- 在 WITH 参数中添加:
'auto-compaction' = 'true',
'compaction.file-size' = '256MB'
-- 原理: Checkpoint 完成后，Flink 自动将小文件合并为大文件

-- ============================================================
-- 方案2: 增大 Checkpoint 间隔 + Rolling Policy
-- ============================================================
-- CP 间隔 2-5min + file-size 128-256MB
-- 减少文件切换频率

-- ============================================================
-- 方案3: 下游批处理合并（兜底方案）
-- ============================================================
-- 定时运行 Spark/Hive compact 任务:
-- INSERT OVERWRITE TABLE ... SELECT * FROM ... WHERE dt = '...';
```

---

## 七、举一反三

### 7.1 与其他组件的对比

| 维度 | Flink FileSink | Spark Structured Streaming | Hive Streaming | Flume HDFS Sink |
|------|---------------|---------------------------|----------------|-----------------|
| 延迟 | 秒-分钟级 | 分钟级 | 分钟级 | 秒级 |
| Exactly-Once | ✅ | ✅ | ✅ | ❌ (At-Least-Once) |
| 格式支持 | Parquet/ORC/JSON/CSV | 同 | ORC | Text/Avro |
| 小文件处理 | auto-compaction | 需配置 | 需 compaction | 严重 |
| 灵活性 | 高 | 高 | 低 | 低 |

### 7.2 面试高频题

**Q1: Flink 写 HDFS 如何保证 Exactly-Once？**
> 通过 Checkpoint + 文件状态机：in-progress → pending → finished。只有 Checkpoint 成功后文件才变为 finished（可见）。故障恢复时，未完成的 in-progress 文件被丢弃，从上个 CP 重新写。

**Q2: 为什么 Flink 写 HDFS 必须开启 Checkpoint？**
> 因为文件从 in-progress 变为 finished 依赖 Checkpoint 完成。不开 CP 文件永远是 in-progress 状态，下游无法读取。

**Q3: 如何解决 Flink 写 HDFS 的小文件问题？**
> (1) 开启 `auto-compaction`（Flink 1.15+，最佳方案）；(2) 增大 Checkpoint 间隔和 rolling-policy；(3) 下游定时跑合并任务。

**Q4: DateTimeBucketAssigner 和分区表的关系？**
> DateTimeBucketAssigner 决定 HDFS 目录结构（如 `/dt=2024-01-15/hr=10/`），对应分区表的分区路径。配合 `sink.partition-commit.policy.kind=metastore` 可以自动注册 Hive 分区。

### 7.3 思考题

1. 设计一个日志归档系统：保留最近 30 天数据，超过 30 天自动清理
2. 如果 Checkpoint 频繁失败（超时），对 HDFS 写入有什么影响？如何排查？
3. 对比 Flink FileSink 与 Flink + Iceberg/Hudi 写入 HDFS 的优缺点

---

> 📝 **教案总结**：Flink 写 HDFS 的核心是理解 Checkpoint 与文件生命周期的关系。关键要点：(1) 必须开启 Checkpoint；(2) rolling-policy 控制文件大小；(3) auto-compaction 解决小文件；(4) partition-commit 控制分区可见性。
