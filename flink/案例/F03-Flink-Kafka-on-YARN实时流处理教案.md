# [教案] Flink on YARN — Kafka 实时流处理使用姿势

> 🎯 教学目标：掌握 Flink 消费/写入 Kafka 的完整姿势，包括 DataStream API 和 Flink SQL 两种写法，理解 Exactly-Once 语义配置 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：想象你是一个快递分拣中心的经理。每秒钟有成千上万的包裹（消息）从各个城市（Producer）涌入传送带（Kafka Topic），你需要实时地对这些包裹进行扫码、分类、贴标签（Flink 实时处理），然后再放到不同的出口传送带（目标 Kafka Topic）发往下游城市（Consumer）。

**生产场景**：
- 用户行为日志实时清洗 ETL（去除脏数据、格式标准化）
- 实时风控（从交易流水中检测异常交易）
- 实时数仓 ODS 层数据分发（一份原始数据分发到多个下游 Topic）
- 实时指标计算（PV/UV、GMV 等）

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17.x / 1.18.x / 1.19.x | 本教案以 1.17.2 为例 |
| Kafka | 2.x / 3.x | 本教案以 3.4.0 为例 |
| Hadoop/YARN | 3.x | 本教案以 3.3.6 为例 |
| Java | JDK 8 / JDK 11 | |
| Scala | 2.12 | Flink 默认 Scala 版本 |

### 2.2 所需 JAR 包

```bash
# Flink Kafka Connector（必须）
flink-connector-kafka-1.17.2.jar

# 如果使用 Flink SQL
flink-sql-connector-kafka-1.17.2.jar   # SQL 用的 uber jar，已包含所有依赖

# JSON 格式支持
flink-json-1.17.2.jar
```

### 2.3 环境准备命令

```bash
# 1. 确认 HADOOP 环境变量
echo $HADOOP_HOME        # 如 /opt/hadoop-3.3.6
echo $HADOOP_CONF_DIR    # 如 /opt/hadoop-3.3.6/etc/hadoop

# 2. 确认 Flink 安装
echo $FLINK_HOME         # 如 /opt/flink-1.17.2
ls $FLINK_HOME/lib/      # 检查基础 jar

# 3. 下载 Kafka Connector JAR
cd $FLINK_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar

# 4. 确认 Kafka 集群可达
kafka-topics.sh --bootstrap-server kafka01:9092,kafka02:9092,kafka03:9092 --list

# 5. 创建测试 Topic
kafka-topics.sh --bootstrap-server kafka01:9092 \
  --create --topic flink_source_topic \
  --partitions 6 --replication-factor 2

kafka-topics.sh --bootstrap-server kafka01:9092 \
  --create --topic flink_sink_topic \
  --partitions 6 --replication-factor 2
```

---

## 三、核心使用方式

### 3.1 方式一：DataStream API

#### Kafka Source（消费 Kafka）

```java
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

public class KafkaSourceDemo {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000L); // 60s checkpoint

        KafkaSource<String> source = KafkaSource.<String>builder()
            .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
            .setTopics("flink_source_topic")
            .setGroupId("flink-consumer-group-01")
            .setStartingOffsets(OffsetsInitializer.committedOffsets(
                org.apache.kafka.clients.consumer.OffsetResetStrategy.EARLIEST))
            .setValueOnlyDeserializer(new SimpleStringSchema())
            // 可选：设置 Kafka Consumer 属性
            .setProperty("max.poll.records", "500")
            .setProperty("fetch.max.bytes", "52428800")
            .build();

        env.fromSource(source, WatermarkStrategy.noWatermarks(), "Kafka Source")
            .print();

        env.execute("Kafka Source Demo");
    }
}
```

#### Kafka Sink（写入 Kafka）

```java
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.base.DeliveryGuarantee;
import org.apache.flink.api.common.serialization.SimpleStringSchema;

KafkaSink<String> sink = KafkaSink.<String>builder()
    .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
    .setRecordSerializer(KafkaRecordSerializationSchema.builder()
        .setTopic("flink_sink_topic")
        .setValueSerializationSchema(new SimpleStringSchema())
        .build())
    .setDeliveryGuarantee(DeliveryGuarantee.EXACTLY_ONCE)
    // Exactly-Once 必须设置事务前缀和超时
    .setTransactionalIdPrefix("flink-kafka-tx-")
    .setProperty("transaction.timeout.ms", "600000") // 10分钟，需小于 Kafka broker 的 transaction.max.timeout.ms
    .build();

dataStream.sinkTo(sink);
```

#### 关键参数详解（DataStream API）

| 参数/方法 | 说明 | 推荐值 |
|-----------|------|--------|
| `setBootstrapServers()` | Kafka Broker 地址列表 | 多个以逗号分隔 |
| `setTopics()` | 消费的 Topic（支持多个） | 单个或逗号分隔 |
| `setGroupId()` | Consumer Group ID | 有业务含义的名称 |
| `setStartingOffsets()` | 起始消费位点 | `committedOffsets()` / `earliest()` / `latest()` |
| `setDeliveryGuarantee()` | 投递语义 | `EXACTLY_ONCE` / `AT_LEAST_ONCE` / `NONE` |
| `setTransactionalIdPrefix()` | 事务 ID 前缀（EOS 必须） | 每个作业唯一 |
| `transaction.timeout.ms` | 事务超时（EOS 必须） | 建议 600000 (10min) |

### 3.2 方式二：Flink SQL

#### Kafka Source 建表

```sql
CREATE TABLE kafka_source (
    `user_id`    STRING,
    `item_id`    STRING,
    `behavior`   STRING,
    `ts`         TIMESTAMP(3),
    -- 声明 Watermark
    WATERMARK FOR ts AS ts - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'flink_source_topic',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-sql-group-01',
    'scan.startup.mode' = 'group-offsets',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);
```

#### Kafka Sink 建表

```sql
CREATE TABLE kafka_sink (
    `user_id`    STRING,
    `item_id`    STRING,
    `behavior`   STRING,
    `ts`         TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'flink_sink_topic',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'format' = 'json',
    'sink.delivery-guarantee' = 'exactly-once',
    'sink.transactional-id-prefix' = 'flink-sql-tx-',
    'properties.transaction.timeout.ms' = '600000'
);
```

#### SQL 关键参数详解

| 参数 | 说明 | 可选值 |
|------|------|--------|
| `connector` | 连接器类型 | `kafka` |
| `topic` | Kafka Topic 名称 | |
| `properties.bootstrap.servers` | Broker 地址 | |
| `properties.group.id` | 消费组 ID | |
| `scan.startup.mode` | 起始消费模式 | `earliest-offset` / `latest-offset` / `group-offsets` / `timestamp` / `specific-offsets` |
| `scan.startup.timestamp-millis` | timestamp 模式的起始时间戳 | 毫秒级时间戳 |
| `format` | 数据格式 | `json` / `csv` / `avro` / `debezium-json` / `canal-json` |
| `sink.delivery-guarantee` | Sink 投递保证 | `exactly-once` / `at-least-once` / `none` |
| `sink.transactional-id-prefix` | 事务 ID 前缀 | EOS 模式必须设置 |
| `sink.parallelism` | Sink 并行度 | 默认与作业并行度一致 |
| `json.fail-on-missing-field` | JSON 字段缺失是否报错 | `false`（推荐） |
| `json.ignore-parse-errors` | 是否忽略解析错误 | `true`（推荐生产环境） |

---

## 四、完整实战示例

### 4.1 场景描述

**业务需求**：用户行为日志从 Kafka `user_behavior_raw` Topic 流入，需要实时清洗（过滤非法记录、补全字段），然后写入 Kafka `user_behavior_clean` Topic 供下游消费。

原始数据格式（JSON）：
```json
{"user_id": "10001", "item_id": "A001", "behavior": "click", "ts": "2025-04-20 10:30:00"}
```

### 4.2 Java 代码（DataStream API 写法）

```java
package com.example.flink.kafka;

import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.base.DeliveryGuarantee;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

public class KafkaETLJob {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // Checkpoint 配置（Exactly-Once 必须）
        env.enableCheckpointing(60000L, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(30000L);
        env.getCheckpointConfig().setCheckpointTimeout(120000L);
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);

        // Kafka Source
        KafkaSource<String> source = KafkaSource.<String>builder()
            .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
            .setTopics("user_behavior_raw")
            .setGroupId("flink-etl-group")
            .setStartingOffsets(OffsetsInitializer.committedOffsets(
                org.apache.kafka.clients.consumer.OffsetResetStrategy.EARLIEST))
            .setValueOnlyDeserializer(new SimpleStringSchema())
            .build();

        DataStream<String> sourceStream = env.fromSource(
            source, WatermarkStrategy.noWatermarks(), "Kafka-Source");

        // 实时清洗逻辑：过滤非法记录
        ObjectMapper mapper = new ObjectMapper();
        DataStream<String> cleanStream = sourceStream
            .filter(value -> {
                try {
                    JsonNode node = mapper.readTree(value);
                    // 过滤条件：user_id 和 behavior 不能为空
                    return node.has("user_id") && node.has("behavior")
                        && !node.get("user_id").asText().isEmpty()
                        && !node.get("behavior").asText().isEmpty();
                } catch (Exception e) {
                    return false; // JSON 解析失败直接过滤
                }
            })
            .name("Filter-Invalid-Records");

        // Kafka Sink（Exactly-Once）
        KafkaSink<String> sink = KafkaSink.<String>builder()
            .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
            .setRecordSerializer(KafkaRecordSerializationSchema.builder()
                .setTopic("user_behavior_clean")
                .setValueSerializationSchema(new SimpleStringSchema())
                .build())
            .setDeliveryGuarantee(DeliveryGuarantee.EXACTLY_ONCE)
            .setTransactionalIdPrefix("flink-etl-tx-")
            .setProperty("transaction.timeout.ms", "600000")
            .build();

        cleanStream.sinkTo(sink).name("Kafka-Sink");

        env.execute("Kafka-ETL-Job");
    }
}
```

### 4.3 Flink SQL 写法

```sql
-- 创建 Source 表
CREATE TABLE user_behavior_raw (
    `user_id`    STRING,
    `item_id`    STRING,
    `behavior`   STRING,
    `ts`         STRING
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_behavior_raw',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-sql-etl-group',
    'scan.startup.mode' = 'group-offsets',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- 创建 Sink 表
CREATE TABLE user_behavior_clean (
    `user_id`    STRING,
    `item_id`    STRING,
    `behavior`   STRING,
    `ts`         STRING
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_behavior_clean',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'format' = 'json',
    'sink.delivery-guarantee' = 'exactly-once',
    'sink.transactional-id-prefix' = 'flink-sql-etl-tx-',
    'properties.transaction.timeout.ms' = '600000'
);

-- ETL: 过滤非法记录
INSERT INTO user_behavior_clean
SELECT user_id, item_id, behavior, ts
FROM user_behavior_raw
WHERE user_id IS NOT NULL
  AND user_id <> ''
  AND behavior IS NOT NULL
  AND behavior <> '';
```

### 4.4 Application Mode on YARN 提交命令

```bash
# DataStream API 提交（打包为 uber jar）
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=6 \
    -Dyarn.application.name="Kafka-ETL-Job" \
    -Dyarn.application.queue=flink \
    -Dclassloader.resolve-order=parent-first \
    -c com.example.flink.kafka.KafkaETLJob \
    /opt/flink-jobs/kafka-etl-job-1.0.jar

# Flink SQL 提交（使用 sql-client 生成的 JAR 或使用 StatementSet 打包）
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=6 \
    -Dyarn.application.name="Kafka-SQL-ETL-Job" \
    -Dyarn.application.queue=flink \
    -Dyarn.ship-files="/opt/flink-jobs/sql/" \
    -c org.apache.flink.table.gateway.SqlGateway \
    $FLINK_HOME/lib/flink-sql-connector-kafka-1.17.2.jar
```

### 4.5 验证结果

```bash
# 1. 往 Source Topic 写入测试数据
kafka-console-producer.sh --bootstrap-server kafka01:9092 --topic user_behavior_raw << 'EOF'
{"user_id": "10001", "item_id": "A001", "behavior": "click", "ts": "2025-04-20 10:30:00"}
{"user_id": "", "item_id": "A002", "behavior": "buy", "ts": "2025-04-20 10:31:00"}
{"user_id": "10002", "item_id": "A003", "behavior": "", "ts": "2025-04-20 10:32:00"}
{"user_id": "10003", "item_id": "A004", "behavior": "click", "ts": "2025-04-20 10:33:00"}
EOF

# 2. 消费 Sink Topic 验证（应该只有 user_id=10001 和 10003 的记录）
kafka-console-consumer.sh --bootstrap-server kafka01:9092 \
    --topic user_behavior_clean \
    --from-beginning --max-messages 10

# 3. 检查 YARN 上的作业状态
yarn application -list | grep Kafka-ETL

# 4. 通过 Flink Web UI 查看
# 访问 http://<ResourceManager>:8088 → 点击 Flink 作业 → Tracking URL
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `org.apache.kafka.common.errors.TimeoutException` | Kafka Broker 不可达 | 检查网络连通性、bootstrap.servers 配置、防火墙 |
| `No resolvable bootstrap urls` | Broker 地址解析失败 | 确认 /etc/hosts 或 DNS 配置正确 |
| `InvalidTxnStateException` | 事务超时被 Broker 关闭 | 增大 `transaction.timeout.ms`，确保 < broker 端 `transaction.max.timeout.ms`（默认 900000） |
| `ProducerFencedException` | 相同 transactional.id 有多实例 | 确保 `transactional-id-prefix` 每个作业唯一，或作业重启前 cancel 旧作业 |
| 消费延迟持续增大（Consumer Lag） | 并行度不够 / 处理逻辑慢 | 增加 parallelism、优化处理逻辑、增加 TaskManager 资源 |
| `ClassNotFoundException: KafkaSource` | JAR 包未加载 | 确认 `flink-sql-connector-kafka-*.jar` 在 `$FLINK_HOME/lib/` 或 `-C` 参数指定 |
| Exactly-Once 模式下 Consumer 读不到数据 | Consumer 未设置 `isolation.level=read_committed` | 下游 Consumer 配置 `isolation.level=read_committed` |
| Checkpoint 频繁失败 | Kafka 事务提交慢 / 网络抖动 | 增大 `checkpoint.timeout`，减少 checkpoint interval |

---

## 六、生产最佳实践

### 6.1 资源配置建议

| 场景 | JobManager 内存 | TaskManager 内存 | 并行度 | Slot数 |
|------|----------------|-----------------|--------|--------|
| 低流量（<1万条/秒） | 1GB | 2GB | 2 | 2 |
| 中流量（1-10万条/秒） | 2GB | 4GB | 6 | 2 |
| 高流量（>10万条/秒） | 4GB | 8GB | 12+ | 4 |

**经验公式**：并行度 ≈ Kafka Source Topic 分区数（确保每个分区被一个并行子任务消费）

### 6.2 关键参数调优

```properties
# Checkpoint 配置
execution.checkpointing.interval: 60000       # 60秒
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 120000       # 2分钟
execution.checkpointing.min-pause: 30000      # 两次 ckp 最小间隔
state.checkpoints.num-retained: 3             # 保留3个 ckp

# Kafka Consumer 调优
properties.fetch.min.bytes: 1048576           # 1MB，减少空拉取
properties.fetch.max.wait.ms: 500             # 最大等待 500ms
properties.max.poll.records: 500              # 每次拉取最大记录数

# Kafka Producer 调优（Exactly-Once）
properties.transaction.timeout.ms: 600000     # 10分钟
properties.batch.size: 65536                  # 64KB batch
properties.linger.ms: 100                     # 100ms 聚合延迟
properties.buffer.memory: 67108864            # 64MB 缓冲

# 网络缓冲
taskmanager.network.memory.fraction: 0.15
taskmanager.network.memory.min: 128mb
taskmanager.network.memory.max: 512mb
```

### 6.3 监控与告警

```bash
# 关键监控指标
# 1. Consumer Lag（消费延迟）
kafka-consumer-groups.sh --bootstrap-server kafka01:9092 \
    --describe --group flink-etl-group

# 2. Flink Metrics（通过 REST API）
# 作业运行状态
curl http://<jobmanager>:8081/jobs/<job-id>
# Source 吞吐
curl http://<jobmanager>:8081/jobs/<job-id>/vertices/<source-id>/metrics?get=numRecordsInPerSecond
# Checkpoint 统计
curl http://<jobmanager>:8081/jobs/<job-id>/checkpoints

# 3. 告警规则建议
# - Consumer Lag > 100000 持续 5 分钟 → P2 告警
# - Checkpoint 连续失败 3 次 → P1 告警
# - 作业 Restart 次数 > 3/小时 → P1 告警
# - 反压（BackPressure）> 0.8 持续 10 分钟 → P2 告警
```

---

## 七、举一反三

### 7.1 与其他方案的对比

| 对比维度 | Flink + Kafka | Spark Structured Streaming + Kafka | Kafka Streams |
|----------|--------------|--------------------------------------|---------------|
| 延迟 | 毫秒级（真正的流处理） | 秒级（微批） | 毫秒级 |
| Exactly-Once | 支持（两阶段提交） | 支持（幂等写 + 事务） | 支持（Kafka 事务） |
| 状态管理 | RocksDB，支持超大状态 | 内存受限 | Kafka 内部 Topic 存储 |
| 部署方式 | 独立进程 / YARN / K8s | YARN / K8s | 嵌入应用（轻量） |
| SQL 支持 | Flink SQL（功能完整） | Spark SQL | KSQL（独立产品） |
| 适用场景 | 复杂 ETL、CEP、大状态 | 批流一体、ML Pipeline | 轻量级流处理、微服务内嵌 |

### 7.2 面试高频题

**Q1: Flink 消费 Kafka 时如何保证 Exactly-Once 语义？**

A: Flink 通过 **两阶段提交（2PC）** 协议实现端到端 Exactly-Once：
1. **Source 端**：Checkpoint 时将 Kafka Consumer 的 offset 保存到状态后端
2. **Sink 端**：使用 Kafka 事务 Producer
   - pre-commit 阶段：Checkpoint 触发时，将数据写入 Kafka 但不提交事务
   - commit 阶段：Checkpoint 成功完成后，提交 Kafka 事务
   - abort 阶段：Checkpoint 失败时，回滚事务
3. **关键配置**：`DeliveryGuarantee.EXACTLY_ONCE` + `setTransactionalIdPrefix` + `transaction.timeout.ms`
4. **下游限制**：消费者需设置 `isolation.level=read_committed` 才能看到已提交的事务数据

**Q2: scan.startup.mode 各模式的区别和使用场景？**

A:
| 模式 | 行为 | 场景 |
|------|------|------|
| `group-offsets` | 从已提交的 offset 继续消费，无提交则用 `auto.offset.reset` | 生产环境首选，支持断点续传 |
| `earliest-offset` | 从最早的 offset 开始 | 首次启动、数据重放 |
| `latest-offset` | 从最新的 offset 开始 | 只关心新数据，不关心历史 |
| `timestamp` | 从指定时间戳对应的 offset 开始 | 数据回溯到特定时间点 |
| `specific-offsets` | 从指定的 partition:offset 开始 | 精确控制，排障时使用 |

**Q3: Flink 消费 Kafka 并行度和 Kafka 分区数的关系？**

A:
- 并行度 = 分区数：最佳，每个子任务消费一个分区
- 并行度 < 分区数：部分子任务消费多个分区，吞吐可能受限
- 并行度 > 分区数：多余的子任务空闲浪费资源
- **最佳实践**：Source 并行度 = Topic 分区数，下游算子并行度根据计算复杂度调整

**Q4: 如何处理 Kafka 消息的乱序和延迟？**

A:
1. 设置 Watermark 策略：`WatermarkStrategy.forBoundedOutOfOrderness(Duration.ofSeconds(5))`
2. 允许的最大乱序时间根据业务容忍度设定
3. 迟到数据可通过 Side Output 旁路输出，单独处理
4. 窗口的 `allowedLateness` 允许迟到触发更新

### 7.3 思考题

1. **设计题**：如果 Kafka Source Topic 突然增加了分区数（从 6 扩到 12），Flink 作业需要怎么处理？是否需要重启？
2. **排障题**：Flink 作业使用 Exactly-Once 语义写入 Kafka，发现下游消费者偶尔读到重复数据，可能的原因是什么？
3. **优化题**：一个 Kafka → Flink → Kafka 的 ETL 任务，Consumer Lag 持续增长，但 TaskManager CPU 利用率只有 30%，瓶颈可能在哪里？如何定位？

---

## 附录：Maven 依赖

```xml
<properties>
    <flink.version>1.17.2</flink.version>
    <kafka.version>3.4.0</kafka.version>
</properties>

<dependencies>
    <!-- Flink Core -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-streaming-java</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>

    <!-- Flink Kafka Connector -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-connector-kafka</artifactId>
        <version>${flink.version}</version>
    </dependency>

    <!-- Flink Table/SQL（如果用 SQL） -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-table-api-java-bridge</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>

    <!-- JSON 处理 -->
    <dependency>
        <groupId>com.fasterxml.jackson.core</groupId>
        <artifactId>jackson-databind</artifactId>
        <version>2.15.2</version>
    </dependency>
</dependencies>
```
