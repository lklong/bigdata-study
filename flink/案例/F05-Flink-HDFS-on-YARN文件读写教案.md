# [教案] Flink on YARN — HDFS 文件读写使用姿势

> 🎯 教学目标：掌握 Flink FileSystem Connector 读写 HDFS，包括 Parquet/ORC/CSV 格式读取、FileSink 写入、分桶策略、小文件合并、Checkpoint 与文件三态转换、RollingPolicy | ⏰ 预计学时: 75分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入

### 1.1 什么场景需要 Flink 直接读写 HDFS？

**生活类比**：如果说 Hive 是一个"有目录管理的图书馆"，那 HDFS 就是"原始的文件仓库"。有些场景你不需要 Hive 那套元数据管理，只需要：
- 实时流数据直接落地 HDFS（供下游 Spark/Hive 外表读取）
- 批处理读取 HDFS 上的原始文件（日志、埋点、导出数据）
- 实时 ETL：Kafka → Flink → HDFS Parquet 文件（替代 Flume）

Flink 的 FileSystem Connector 就是为这种"直接和文件系统打交道"的场景设计的。

### 1.2 与 Hive Connector 的区别

| 维度 | FileSystem Connector | Hive Connector |
|------|---------------------|----------------|
| 元数据 | 无（纯文件） | Hive Metastore |
| 建表 | Flink DDL 定义 Schema | 复用 Hive 表 |
| 分区管理 | 目录级别自管理 | Metastore 管理 |
| 适用场景 | 纯文件落地/读取 | 数仓集成 |
| 依赖 | 无额外依赖 | 需要 Hive JAR |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.15+ | FileSystem Connector 内置 |
| Hadoop | 3.x | YARN + HDFS |
| Java | 8/11 | - |

### 2.2 JAR 依赖

```bash
# FileSystem Connector 是 Flink 内置的，无需额外下载！
# 但需要格式相关的 JAR：

# Parquet 格式支持
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-parquet/1.17.2/flink-sql-connector-parquet-1.17.2.jar

# ORC 格式支持
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-orc/1.17.2/flink-sql-connector-orc-1.17.2.jar

# 放入 lib 目录
cp flink-sql-connector-parquet-*.jar $FLINK_HOME/lib/
cp flink-sql-connector-orc-*.jar $FLINK_HOME/lib/

# Hadoop 环境变量
export HADOOP_CLASSPATH=`hadoop classpath`
```

### 2.3 HDFS 目录准备

```bash
# 创建测试数据目录
hdfs dfs -mkdir -p /data/raw/orders/
hdfs dfs -mkdir -p /data/output/flink-sink/

# 上传测试 CSV 文件
cat > /tmp/test_orders.csv << 'EOF'
1001,user_001,99.50,2024-01-15 10:30:00
1002,user_002,150.00,2024-01-15 11:00:00
1003,user_003,28.90,2024-01-15 11:30:00
EOF
hdfs dfs -put /tmp/test_orders.csv /data/raw/orders/

# 确认
hdfs dfs -ls /data/raw/orders/
```

---

## 三、核心使用方式

### 3.1 读取 HDFS 文件（Source）

#### SQL DDL 定义

```sql
-- 读取 CSV 文件
CREATE TABLE hdfs_csv_source (
    order_id BIGINT,
    user_id STRING,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3)
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/raw/orders/',
    'format' = 'csv',
    'csv.field-delimiter' = ',',
    'csv.ignore-parse-errors' = 'true'
);

-- 读取 Parquet 文件
CREATE TABLE hdfs_parquet_source (
    order_id BIGINT,
    user_id STRING,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3),
    dt STRING
) PARTITIONED BY (dt) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/orders/',
    'format' = 'parquet'
);

-- 读取 ORC 文件
CREATE TABLE hdfs_orc_source (
    order_id BIGINT,
    user_id STRING,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3)
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/orders_orc/',
    'format' = 'orc'
);

-- 读取 JSON Lines 文件
CREATE TABLE hdfs_json_source (
    order_id BIGINT,
    user_id STRING,
    amount DECIMAL(10, 2),
    order_time STRING
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/raw/json_logs/',
    'format' = 'json'
);
```

### 3.2 写入 HDFS 文件（Sink）

```sql
-- 写入 Parquet 格式（带分区）
CREATE TABLE hdfs_parquet_sink (
    order_id BIGINT,
    user_id STRING,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3),
    dt STRING,
    hr STRING
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/output/orders_parquet/',
    'format' = 'parquet',
    'sink.partition-commit.trigger' = 'process-time',
    'sink.partition-commit.delay' = '1 h',
    'sink.partition-commit.policy.kind' = 'success-file',
    'sink.rolling-policy.file-size' = '256MB',
    'sink.rolling-policy.rollover-interval' = '15 min',
    'sink.rolling-policy.check-interval' = '1 min'
);
```

### 3.3 核心参数详解

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `connector` | - | 固定 `filesystem` |
| `path` | - | HDFS 路径（hdfs://namenode:8020/path 或 hdfs:///path） |
| `format` | - | 文件格式: csv/json/parquet/orc/avro/raw |
| `sink.rolling-policy.file-size` | `128MB` | 单文件最大大小，超过则滚动 |
| `sink.rolling-policy.rollover-interval` | `30min` | 最大滚动间隔 |
| `sink.rolling-policy.check-interval` | `1min` | 检查是否需要滚动的间隔 |
| `sink.partition-commit.trigger` | `process-time` | 分区提交触发: process-time/partition-time |
| `sink.partition-commit.delay` | `0` | 分区提交延迟 |
| `sink.partition-commit.policy.kind` | - | 提交动作: success-file/custom |
| `auto-compaction` | `false` | 是否自动合并小文件 |
| `compaction.file-size` | `128MB` | 合并后目标文件大小 |

---

## 四、完整实战示例

### 4.1 场景一：Kafka → Flink → HDFS Parquet（实时日志落地）

#### SQL 写法

```sql
-- 1. Kafka Source
CREATE TABLE kafka_access_log (
    request_id STRING,
    user_id STRING,
    url STRING,
    method STRING,
    status_code INT,
    response_time INT,
    event_time TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'access-log',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092',
    'properties.group.id' = 'flink-hdfs-writer',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.timestamp-format.standard' = 'ISO-8601'
);

-- 2. HDFS Parquet Sink（按日期+小时分区）
CREATE TABLE hdfs_access_log_sink (
    request_id STRING,
    user_id STRING,
    url STRING,
    method STRING,
    status_code INT,
    response_time INT,
    event_time TIMESTAMP(3),
    dt STRING,
    hr STRING
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/dw/access_log/',
    'format' = 'parquet',
    'parquet.compression' = 'SNAPPY',
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '5 min',
    'sink.partition-commit.watermark-time-zone' = 'Asia/Shanghai',
    'sink.partition-commit.policy.kind' = 'success-file',
    'sink.rolling-policy.file-size' = '256MB',
    'sink.rolling-policy.rollover-interval' = '10 min',
    'sink.rolling-policy.check-interval' = '1 min',
    'partition.time-extractor.timestamp-pattern' = '$dt $hr:00:00',
    'auto-compaction' = 'true',
    'compaction.file-size' = '256MB'
);

-- 3. ETL 插入
INSERT INTO hdfs_access_log_sink
SELECT
    request_id,
    user_id,
    url,
    method,
    status_code,
    response_time,
    event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(event_time, 'HH') AS hr
FROM kafka_access_log
WHERE status_code IS NOT NULL;
```

#### Java/DataStream API 写法

```java
import org.apache.flink.api.common.serialization.SimpleStringEncoder;
import org.apache.flink.configuration.MemorySize;
import org.apache.flink.connector.file.sink.FileSink;
import org.apache.flink.core.fs.Path;
import org.apache.flink.formats.parquet.avro.ParquetAvroWriters;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.sink.filesystem.OutputFileConfig;
import org.apache.flink.streaming.api.functions.sink.filesystem.bucketassigners.DateTimeBucketAssigner;
import org.apache.flink.streaming.api.functions.sink.filesystem.rollingpolicies.DefaultRollingPolicy;
import org.apache.flink.streaming.api.functions.sink.filesystem.rollingpolicies.OnCheckpointRollingPolicy;

import java.time.Duration;
import java.time.ZoneId;

public class KafkaToHDFS {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // 开启 Checkpoint（FileSink 必须）
        env.enableCheckpointing(60000);

        // 从 Kafka 读取数据
        DataStream<AccessLog> logStream = env
            .addSource(createKafkaSource())
            .map(json -> parseAccessLog(json));

        // 方式1：写入文本文件（Row Format）
        FileSink<String> textSink = FileSink
            .forRowFormat(
                new Path("hdfs:///data/output/text_logs/"),
                new SimpleStringEncoder<String>("UTF-8")
            )
            .withBucketAssigner(new DateTimeBucketAssigner<>("yyyy-MM-dd/HH", ZoneId.of("Asia/Shanghai")))
            .withRollingPolicy(
                DefaultRollingPolicy.builder()
                    .withMaxPartSize(MemorySize.ofMebiBytes(256))
                    .withRolloverInterval(Duration.ofMinutes(10))
                    .withInactivityInterval(Duration.ofMinutes(5))
                    .build()
            )
            .withOutputFileConfig(
                OutputFileConfig.builder()
                    .withPartPrefix("access-log")
                    .withPartSuffix(".txt")
                    .build()
            )
            .build();

        // 方式2：写入 Parquet 文件（Bulk Format）
        FileSink<AccessLog> parquetSink = FileSink
            .forBulkFormat(
                new Path("hdfs:///data/output/parquet_logs/"),
                ParquetAvroWriters.forReflectRecord(AccessLog.class)
            )
            .withBucketAssigner(new DateTimeBucketAssigner<>("yyyy-MM-dd/HH", ZoneId.of("Asia/Shanghai")))
            .withRollingPolicy(OnCheckpointRollingPolicy.build())
            .withOutputFileConfig(
                OutputFileConfig.builder()
                    .withPartPrefix("log")
                    .withPartSuffix(".parquet")
                    .build()
            )
            .build();

        logStream.map(AccessLog::toString).sinkTo(textSink);
        logStream.sinkTo(parquetSink);

        env.execute("Kafka to HDFS");
    }
}
```

#### 提交命令

```bash
# Application 模式提交
flink run-application -t yarn-application \
    -Dyarn.application.name="kafka-to-hdfs" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=8 \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-to-hdfs \
    -c com.example.KafkaToHDFS \
    hdfs:///flink/jars/kafka-to-hdfs.jar
```

### 4.2 场景二：批量读取 HDFS 文件进行分析

#### SQL 写法

```sql
SET execution.runtime-mode = batch;

-- 读取 HDFS 上的 Parquet 文件
CREATE TABLE hdfs_orders (
    order_id BIGINT,
    user_id STRING,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3),
    dt STRING
) PARTITIONED BY (dt) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/dw/orders/',
    'format' = 'parquet'
);

-- 分区裁剪 + 聚合
SELECT
    dt,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount,
    AVG(amount) AS avg_amount
FROM hdfs_orders
WHERE dt BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY dt
ORDER BY dt;
```

#### Java 写法

```java
import org.apache.flink.table.api.*;

public class BatchReadHDFS {
    public static void main(String[] args) {
        EnvironmentSettings settings = EnvironmentSettings.inBatchMode();
        TableEnvironment tableEnv = TableEnvironment.create(settings);

        tableEnv.executeSql(
            "CREATE TABLE hdfs_orders (" +
            "  order_id BIGINT," +
            "  user_id STRING," +
            "  amount DECIMAL(10, 2)," +
            "  order_time TIMESTAMP(3)," +
            "  dt STRING" +
            ") PARTITIONED BY (dt) WITH (" +
            "  'connector' = 'filesystem'," +
            "  'path' = 'hdfs:///data/dw/orders/'," +
            "  'format' = 'parquet'" +
            ")"
        );

        tableEnv.executeSql(
            "SELECT dt, COUNT(*) AS cnt, SUM(amount) AS total " +
            "FROM hdfs_orders WHERE dt >= '2024-01-01' " +
            "GROUP BY dt ORDER BY dt"
        ).print();
    }
}
```

### 4.3 Checkpoint 与文件三态详解

FileSink 的文件生命周期：

```
┌─────────────┐     Checkpoint触发      ┌─────────────┐     Checkpoint完成     ┌─────────────┐
│  In-Progress │ ──────────────────────→ │   Pending   │ ─────────────────────→ │  Finished   │
│  (.inprogress)│                         │ (.part-xxx) │                        │ (part-xxx)  │
└─────────────┘                          └─────────────┘                        └─────────────┘
     正在写入                                 等待确认                               写入完成
```

**关键理解**：
- `In-Progress`: 正在写入的文件，文件名带 `.inprogress` 后缀
- `Pending`: Checkpoint 触发 Rolling 后的文件，等待 Checkpoint 完成确认
- `Finished`: Checkpoint 完成后 rename 为最终文件名，数据可见

**这就是为什么 FileSink 必须开启 Checkpoint！**

### 4.4 RollingPolicy 详解

```java
// Row Format（文本类）支持细粒度 RollingPolicy
DefaultRollingPolicy.builder()
    .withMaxPartSize(MemorySize.ofMebiBytes(256))      // 单文件最大256MB
    .withRolloverInterval(Duration.ofMinutes(15))       // 最长15分钟滚动
    .withInactivityInterval(Duration.ofMinutes(5))      // 无数据5分钟也滚动
    .build();

// Bulk Format（Parquet/ORC）只支持按 Checkpoint 滚动
OnCheckpointRollingPolicy.build();
// 每次 Checkpoint 时都会滚动文件
```

### 4.5 验证结果

```bash
# 查看写入的文件
hdfs dfs -ls -R /data/output/flink-sink/

# 检查文件大小
hdfs dfs -du -h /data/output/flink-sink/dt=2024-01-15/

# 检查 _SUCCESS 文件
hdfs dfs -ls /data/output/flink-sink/dt=2024-01-15/hr=10/_SUCCESS

# 用 parquet-tools 查看 Parquet 文件
hadoop jar parquet-tools.jar head hdfs:///data/output/flink-sink/dt=2024-01-15/hr=10/part-xxx.parquet
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | 文件一直是 `.inprogress` 状态 | 未开启 Checkpoint | 必须开启 `execution.checkpointing.interval` |
| 2 | 产生大量小文件 | CP 间隔太短或并行度过高 | 增大 CP 间隔/减少并行度/开启 auto-compaction |
| 3 | Parquet 文件 0 字节 | 没有数据或 CP 未完成 | 等待下一次 CP 完成 |
| 4 | `FileNotFoundException` | HDFS 路径不存在 | 提前创建目录 `hdfs dfs -mkdir -p` |
| 5 | 文件名乱码 | OutputFileConfig 未设置 | 配置 `withPartPrefix`/`withPartSuffix` |
| 6 | OOM 写大文件 | Parquet/ORC 内存缓冲过大 | 减小 `parquet.block.size` 或增大 TM 内存 |
| 7 | 恢复后出现重复文件 | Pending 文件未清理 | 正常现象，FileSink 会在恢复时处理 |
| 8 | 下游读到不完整数据 | 读了 In-Progress 文件 | 只读 Finished 文件（无 .inprogress 后缀） |
| 9 | 分区目录层级错误 | `PARTITIONED BY` 与字段顺序不匹配 | 检查 DDL 中分区字段在最后 |
| 10 | 压缩格式不支持 | 缺少 codec 库 | 确保 `snappy`/`lz4`/`zstd` native 库存在 |

---

## 六、生产最佳实践

### 6.1 资源配置

```bash
flink run-application -t yarn-application \
    -Dyarn.application.name="streaming-to-hdfs" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dexecution.checkpointing.interval=120000 \
    -Dexecution.checkpointing.min-pause=60000 \
    -Dexecution.checkpointing.timeout=600000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints \
    -c com.example.StreamToHDFS \
    hdfs:///flink/jars/stream-to-hdfs.jar
```

### 6.2 小文件合并策略

```sql
-- 方式1：SQL 中开启 auto-compaction
CREATE TABLE hdfs_sink (...) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/output/',
    'format' = 'parquet',
    'auto-compaction' = 'true',
    'compaction.file-size' = '256MB'
);

-- 方式2：调整 CP 间隔（Parquet 每次 CP 生成一个文件）
SET execution.checkpointing.interval = 300000;  -- 5分钟

-- 方式3：减少并行度
SET parallelism.default = 2;
```

### 6.3 文件大小计算公式

```
单文件大小 ≈ (数据吞吐量 / 并行度) × Checkpoint间隔

例：
- 吞吐量: 100MB/min
- 并行度: 4
- CP间隔: 5min
- 单文件大小 ≈ (100/4) × 5 = 125MB
```

### 6.4 监控建议

```yaml
# 关键监控指标
- flink_taskmanager_job_task_numRecordsOut
- flink_taskmanager_job_task_numBytesOut
- flink_jobmanager_job_numberOfCompletedCheckpoints
- flink_jobmanager_job_lastCheckpointDuration
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: Flink FileSink 如何保证 Exactly-Once 语义？**

> A: 通过文件三态机制 + Checkpoint 实现：数据写入 In-Progress → CP 触发变为 Pending → CP 成功 rename 为 Finished（原子操作）→ 失败回滚。

**Q2: 为什么 Parquet/ORC 格式只支持 OnCheckpointRollingPolicy？**

> A: 列式存储需要在文件末尾写 Footer（schema、统计信息等），不支持中途 flush。

**Q3: 如何减少 Flink 写 HDFS 产生的小文件？**

> A: 增大 CP 间隔 + 降低 Sink 并行度 + 开启 auto-compaction + 增大 rolling-policy.file-size。

### 7.2 思考题

1. **Checkpoint 间隔设为 1 小时，会有什么问题？**
2. **并行度 16 + CP 间隔 1 分钟 + 流量 160MB/min，会产生什么问题？**
3. **如何让下游 Hive 查询 Flink 写入 HDFS 的 Parquet 文件？**

---

**本教案结束。下一篇：F08-Flink-Hudi-on-YARN 实时数据湖教案**
