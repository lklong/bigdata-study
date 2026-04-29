# [教案] Flink on YARN — Kafka 实时流处理使用姿势

> 🎯 教学目标：掌握 Flink + Kafka 在 YARN 上的实时流处理全流程，包括消费/写入 Kafka、Exactly-Once 语义、Application Mode 提交 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

Kafka + Flink 是实时数据处理的"黄金搭档"，几乎所有大厂的实时链路都是这个组合：

| 场景 | 架构 |
|------|------|
| 实时 ETL | Kafka（原始数据）→ Flink 清洗/转换 → Kafka（清洗后数据） |
| 实时指标 | Kafka（业务事件）→ Flink 聚合 → 数据库/Dashboard |
| 实时告警 | Kafka（日志/指标）→ Flink 规则匹配 → 告警系统 |
| CDC 同步 | MySQL → Canal → Kafka → Flink → 数仓/ES |
| 用户画像 | Kafka（行为日志）→ Flink 特征计算 → Redis/HBase |

本教案带你完整走通 Kafka → Flink → Kafka 实时 ETL 链路，涵盖 DataStream API 和 SQL 两种写法。

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17+ / 1.18 | - |
| Kafka | 2.4+ / 3.x | 推荐 Kafka 3.x |
| Hadoop/YARN | 2.8+ / 3.x | - |
| Java | JDK 8 / JDK 11 | - |

### 2.2 需要的 JAR 包

```bash
# Flink Kafka Connector（必须！）
# 注意：使用 sql-connector 版本（uber jar，包含所有依赖）
wget https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.1.0-1.18/flink-sql-connector-kafka-3.1.0-1.18.jar \
  -P $FLINK_HOME/lib/

# 如果用 DataStream API 开发，Maven 依赖：
# <dependency>
#     <groupId>org.apache.flink</groupId>
#     <artifactId>flink-connector-kafka</artifactId>
#     <version>3.1.0-1.18</version>
# </dependency>
```

### 2.3 环境准备

```bash
# 环境变量
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CLASSPATH=$(hadoop classpath)
export KAFKA_HOME=/opt/kafka

# 创建测试 Topic
$KAFKA_HOME/bin/kafka-topics.sh --create \
  --bootstrap-server kafka01:9092 \
  --topic source_events \
  --partitions 8 \
  --replication-factor 3

$KAFKA_HOME/bin/kafka-topics.sh --create \
  --bootstrap-server kafka01:9092 \
  --topic sink_events_cleaned \
  --partitions 8 \
  --replication-factor 3

# 验证 Topic
$KAFKA_HOME/bin/kafka-topics.sh --describe \
  --bootstrap-server kafka01:9092 \
  --topic source_events
```

---

## 三、核心使用方式

### 3.1 方式一: Flink SQL 方式（推荐，开发效率高）

#### Kafka Source 表

```sql
-- ============================================================
-- Kafka Source: 消费 Kafka Topic
-- ============================================================
CREATE TABLE kafka_source (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    page_url    STRING,
    referrer    STRING,
    event_time  TIMESTAMP(3),
    -- Metadata 列（Kafka 特有）
    `partition` INT METADATA FROM 'partition' VIRTUAL,
    `offset`    BIGINT METADATA FROM 'offset' VIRTUAL,
    `timestamp` TIMESTAMP(3) METADATA FROM 'timestamp' VIRTUAL,
    -- Watermark
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'source_events',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-etl-group',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);
```

**Kafka Source 关键参数详解表**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `connector` | 连接器类型 | `kafka` | - |
| `topic` | 订阅的 Topic | 业务 Topic | 支持多 Topic：`topic-1;topic-2` |
| `topic-pattern` | Topic 正则匹配 | `event_.*` | 与 topic 二选一 |
| `properties.bootstrap.servers` | Kafka Broker 列表 | 全部 Broker | 逗号分隔 |
| `properties.group.id` | Consumer Group | 有意义的名称 | 必须设置 |
| `scan.startup.mode` | 起始消费位置 | 见下表 | 关键参数 |
| `format` | 数据格式 | json/avro/csv | - |
| `json.ignore-parse-errors` | 忽略解析错误 | true | 防止脏数据导致作业失败 |

**`scan.startup.mode` 选项详解**：

| 模式 | 含义 | 适用场景 |
|------|------|----------|
| `earliest-offset` | 从最早的消息开始 | 全量回放、数据迁移 |
| `latest-offset` | 只消费新消息 | 实时处理，不关心历史 |
| `group-offsets` | 从 Group 上次提交的 offset 继续 | 故障恢复（需配合 Checkpoint） |
| `timestamp` | 从指定时间戳开始 | 按时间回溯 |
| `specific-offsets` | 从指定 partition:offset 开始 | 精确回放 |

```sql
-- timestamp 模式示例
-- 'scan.startup.mode' = 'timestamp',
-- 'scan.startup.timestamp-millis' = '1700000000000'

-- specific-offsets 模式示例
-- 'scan.startup.mode' = 'specific-offsets',
-- 'scan.startup.specific-offsets' = 'partition:0,offset:100;partition:1,offset:200'
```

#### Kafka Sink 表

```sql
-- ============================================================
-- Kafka Sink: 写入 Kafka Topic
-- ============================================================
CREATE TABLE kafka_sink (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    page_url    STRING,
    processed_time TIMESTAMP(3),
    -- 指定 Kafka Message Key（可选）
    PRIMARY KEY (event_id) NOT ENFORCED
) WITH (
    'connector' = 'kafka',
    'topic' = 'sink_events_cleaned',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'format' = 'json',
    'key.format' = 'json',
    'key.fields' = 'event_id',
    'value.format' = 'json',
    'value.fields-include' = 'ALL',
    -- Exactly-Once 配置
    'sink.delivery-guarantee' = 'exactly-once',
    'properties.transaction.timeout.ms' = '900000',
    'sink.transactional-id-prefix' = 'flink-etl'
);
```

**Kafka Sink 关键参数详解表**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `sink.delivery-guarantee` | 投递语义 | `exactly-once` | 需开启 Checkpoint |
| `properties.transaction.timeout.ms` | 事务超时 | 900000 (15min) | 必须 > Checkpoint 间隔 |
| `sink.transactional-id-prefix` | 事务 ID 前缀 | 作业唯一 | Exactly-Once 必须 |
| `key.format` | Key 序列化格式 | json | 决定 Kafka Message Key |
| `key.fields` | Key 字段 | 业务主键 | 影响分区路由 |
| `value.fields-include` | Value 包含的字段 | ALL / EXCEPT_KEY | - |
| `sink.partitioner` | 分区策略 | default / fixed / round-robin | - |
| `properties.acks` | 确认机制 | all | Exactly-Once 必须 all |
| `properties.enable.idempotence` | 幂等开关 | true | Exactly-Once 自动开启 |

#### 完整 ETL SQL

```sql
-- ============================================================
-- 实时 ETL: Kafka → 清洗/转换 → Kafka
-- ============================================================
INSERT INTO kafka_sink
SELECT
    event_id,
    user_id,
    event_type,
    page_url,
    CURRENT_TIMESTAMP AS processed_time
FROM kafka_source
WHERE event_type IS NOT NULL
  AND user_id > 0
  AND page_url IS NOT NULL;
```

---

### 3.2 方式二: DataStream API 方式

#### Maven 依赖（pom.xml）

```xml
<dependencies>
    <!-- Flink Core -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-streaming-java</artifactId>
        <version>1.18.1</version>
        <scope>provided</scope>
    </dependency>
    <!-- Flink Kafka Connector -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-connector-kafka</artifactId>
        <version>3.1.0-1.18</version>
    </dependency>
    <!-- JSON 序列化 -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-json</artifactId>
        <version>1.18.1</version>
    </dependency>
</dependencies>
```

#### Java 代码

```java
package com.example.flink;

import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.sink.KafkaSinkBuilder;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.connector.base.DeliveryGuarantee;

import java.time.Duration;

public class KafkaETLJob {

    public static void main(String[] args) throws Exception {
        // ============================================================
        // 1. 创建执行环境
        // ============================================================
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // Checkpoint 配置（Exactly-Once 必须）
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(30000);
        env.getCheckpointConfig().setCheckpointTimeout(120000);
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);

        // ============================================================
        // 2. Kafka Source
        // ============================================================
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
                .setTopics("source_events")
                .setGroupId("flink-datastream-etl")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                // Consumer 配置
                .setProperty("partition.discovery.interval.ms", "30000")  // 动态发现新分区
                .setProperty("max.poll.records", "500")
                .build();

        DataStream<String> sourceStream = env.fromSource(
                kafkaSource,
                WatermarkStrategy.forBoundedOutOfOrderness(Duration.ofSeconds(5)),
                "Kafka Source"
        );

        // ============================================================
        // 3. 数据处理（清洗/转换）
        // ============================================================
        DataStream<String> processedStream = sourceStream
                .filter(json -> json != null && !json.isEmpty())
                .filter(json -> json.contains("\"event_type\""))  // 简单过滤
                .map(json -> {
                    // 实际项目中解析 JSON 并做清洗
                    // 这里简化为直接透传
                    return json;
                })
                .name("ETL Processing");

        // ============================================================
        // 4. Kafka Sink（Exactly-Once）
        // ============================================================
        KafkaSink<String> kafkaSink = KafkaSink.<String>builder()
                .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
                .setRecordSerializer(
                        KafkaRecordSerializationSchema.builder()
                                .setTopic("sink_events_cleaned")
                                .setValueSerializationSchema(new SimpleStringSchema())
                                .build()
                )
                .setDeliveryGuarantee(DeliveryGuarantee.EXACTLY_ONCE)
                .setTransactionalIdPrefix("flink-etl-tx")
                .setProperty("transaction.timeout.ms", "900000")  // 15 min
                .build();

        processedStream.sinkTo(kafkaSink).name("Kafka Sink");

        // ============================================================
        // 5. 执行
        // ============================================================
        env.execute("Kafka ETL Job");
    }
}
```

---

### 3.3 Application Mode 提交到 YARN

```bash
# ============================================================
# 打包（Maven shade 插件生成 uber jar）
# ============================================================
mvn clean package -DskipTests

# ============================================================
# 上传 JAR 到 HDFS
# ============================================================
hdfs dfs -mkdir -p /flink/jars
hdfs dfs -put target/kafka-etl-job-1.0.jar /flink/jars/

# ============================================================
# Application Mode 提交
# ============================================================
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -d \
  -Dyarn.application.name="kafka-etl-exactly-once" \
  -Dyarn.application.queue=production \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=8 \
  -Dexecution.checkpointing.interval=60000 \
  -Dexecution.checkpointing.mode=EXACTLY_ONCE \
  -Dstate.backend=rocksdb \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-etl \
  -Dstate.savepoints.dir=hdfs:///flink/savepoints/kafka-etl \
  -Drestart-strategy=fixed-delay \
  -Drestart-strategy.fixed-delay.attempts=3 \
  -Drestart-strategy.fixed-delay.delay=30s \
  -c com.example.flink.KafkaETLJob \
  hdfs:///flink/jars/kafka-etl-job-1.0.jar
```

**提交命令参数详解**：

| 参数 | 含义 | 推荐值 | 说明 |
|------|------|--------|------|
| `-t yarn-application` | Application Mode | - | 推荐 |
| `-Dparallelism.default` | 并行度 | = Kafka Partition 数 | 最佳对齐 |
| `-Dexecution.checkpointing.interval` | CP 间隔 | 60000ms | Exactly-Once 必须 |
| `-Dstate.backend` | 状态后端 | rocksdb | 大状态必须 |
| `-Dstate.checkpoints.dir` | CP 路径 | HDFS | 必须持久化 |
| `-Drestart-strategy` | 重启策略 | fixed-delay | 生产必须配 |

---

## 四、完整实战示例

### 4.1 场景描述

实现一个完整的 Kafka → Flink 实时 ETL → Kafka 链路：
- Source: `user_behavior` Topic（用户行为日志）
- 处理: 过滤无效数据、字段清洗、添加处理时间
- Sink: `user_behavior_cleaned` Topic

### 4.2 准备测试数据

```bash
# 向 Source Topic 写入测试数据
$KAFKA_HOME/bin/kafka-console-producer.sh \
  --bootstrap-server kafka01:9092 \
  --topic source_events << 'EOF'
{"event_id":"e001","user_id":1001,"event_type":"page_view","page_url":"/home","referrer":"google.com","event_time":"2024-01-15 10:30:00"}
{"event_id":"e002","user_id":1002,"event_type":"click","page_url":"/product/123","referrer":"/home","event_time":"2024-01-15 10:30:05"}
{"event_id":"e003","user_id":0,"event_type":null,"page_url":null,"referrer":null,"event_time":"2024-01-15 10:30:10"}
{"event_id":"e004","user_id":1003,"event_type":"purchase","page_url":"/checkout","referrer":"/cart","event_time":"2024-01-15 10:30:15"}
EOF
```

### 4.3 SQL 方式完整提交

创建 `/opt/flink/scripts/kafka-etl.sql`：

```sql
-- ============================================================
-- kafka-etl.sql — Kafka 实时 ETL 完整脚本
-- ============================================================

-- 配置
SET 'execution.runtime-mode' = 'streaming';
SET 'parallelism.default' = '8';
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints/kafka-etl';
SET 'restart-strategy' = 'fixed-delay';
SET 'restart-strategy.fixed-delay.attempts' = '3';
SET 'restart-strategy.fixed-delay.delay' = '30s';

-- Source
CREATE TABLE source_events (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    page_url    STRING,
    referrer    STRING,
    event_time  TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'source_events',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-sql-etl',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- Sink (Exactly-Once)
CREATE TABLE sink_events_cleaned (
    event_id       STRING,
    user_id        BIGINT,
    event_type     STRING,
    page_url       STRING,
    referrer       STRING,
    event_time     TIMESTAMP(3),
    processed_time TIMESTAMP(3),
    PRIMARY KEY (event_id) NOT ENFORCED
) WITH (
    'connector' = 'kafka',
    'topic' = 'sink_events_cleaned',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'key.format' = 'json',
    'key.fields' = 'event_id',
    'value.format' = 'json',
    'value.fields-include' = 'EXCEPT_KEY',
    'sink.delivery-guarantee' = 'exactly-once',
    'properties.transaction.timeout.ms' = '900000',
    'sink.transactional-id-prefix' = 'flink-sql-etl'
);

-- ETL
INSERT INTO sink_events_cleaned
SELECT
    event_id,
    user_id,
    LOWER(event_type) AS event_type,
    page_url,
    COALESCE(referrer, 'direct') AS referrer,
    event_time,
    CURRENT_TIMESTAMP AS processed_time
FROM source_events
WHERE event_type IS NOT NULL
  AND user_id > 0
  AND page_url IS NOT NULL;
```

提交命令：

```bash
$FLINK_HOME/bin/sql-client.sh \
  -Dexecution.target=yarn-application \
  -Dyarn.application.name="kafka-etl-sql" \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -f /opt/flink/scripts/kafka-etl.sql
```

### 4.4 验证结果

```bash
# 消费 Sink Topic 验证输出
$KAFKA_HOME/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka01:9092 \
  --topic sink_events_cleaned \
  --from-beginning \
  --max-messages 10

# 查看 Consumer Group Offset
$KAFKA_HOME/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka01:9092 \
  --group flink-sql-etl \
  --describe

# 查看 YARN Application 状态
yarn application -list -appStates RUNNING | grep kafka-etl
```

---

## 五、Exactly-Once 语义配置详解

### 5.1 Exactly-Once 全链路要求

```
┌─────────────────────────────────────────────────────────┐
│            Exactly-Once 端到端保证                        │
├─────────────────────────────────────────────────────────┤
│ Kafka Source                                             │
│   → Checkpoint 时记录 offset，恢复时从 offset 重放       │
│                                                         │
│ Flink 内部                                              │
│   → Checkpoint 保证状态一致性                            │
│                                                         │
│ Kafka Sink                                              │
│   → 两阶段提交（2PC）事务写入                            │
│   → Pre-commit: Checkpoint 时 flush 数据到 Kafka 事务    │
│   → Commit: Checkpoint 完成后提交事务                    │
└─────────────────────────────────────────────────────────┘
```

### 5.2 关键配置清单

```yaml
# ============================================================
# Exactly-Once 完整配置
# ============================================================

# 1. Flink Checkpoint（必须开启！）
execution.checkpointing.interval: 60000
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.min-pause: 30000
execution.checkpointing.timeout: 120000
execution.checkpointing.max-concurrent-checkpoints: 1

# 2. Kafka Sink 事务配置
# transaction.timeout.ms 必须 > checkpoint interval
# Kafka Broker 端 transaction.max.timeout.ms 默认 15min，需确认
# 公式: transaction.timeout.ms > checkpoint.interval + checkpoint.timeout

# 3. Kafka Broker 配置检查
# transaction.max.timeout.ms = 900000 (15min)  ← Broker 端
# 如果 Flink 设置的事务超时大于此值，事务会被 Broker 拒绝
```

### 5.3 Consumer Group 与 Offset 管理

```sql
-- ============================================================
-- Offset 管理策略
-- ============================================================

-- 策略1: Flink 管理 Offset（推荐！配合 Checkpoint）
-- Checkpoint 时 Flink 会记录每个 partition 的 offset
-- 恢复时从 Checkpoint 中的 offset 开始消费
-- 此时 group.id 的 committed offset 仅作参考

-- 策略2: Kafka 管理 Offset（不推荐用于 Exactly-Once）
-- 'properties.enable.auto.commit' = 'true'
-- 'properties.auto.commit.interval.ms' = '5000'

-- 最佳实践: 让 Flink 管理 Offset，但也提交到 Kafka（方便监控）
-- 'properties.enable.auto.commit' = 'false'  -- Flink 控制
-- Flink 会在 Checkpoint 成功后自动提交 offset 到 Kafka
```

---

## 六、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `ProducerFencedException` | 事务 ID 冲突或事务超时 | 确保 `transactional-id-prefix` 唯一；增大 `transaction.timeout.ms` |
| `InvalidTxnStateException` | Kafka 事务状态异常 | 检查 Broker `transaction.max.timeout.ms` >= Flink 配置 |
| Consumer Lag 持续增长 | 消费能力不足 | 增大并行度（= Kafka Partition 数）；增大 TM 内存 |
| 数据重复 | At-Least-Once 语义 | 检查是否开启 Checkpoint + Exactly-Once Sink |
| `TimeoutException` 消费超时 | 网络或 Broker 问题 | 增大 `request.timeout.ms`、`session.timeout.ms` |
| Checkpoint 超时 | 状态过大或反压 | 增大 CP 超时、用增量 CP、排查反压 |
| 新增 Partition 消费不到 | 未开启分区发现 | 设置 `partition.discovery.interval.ms` = 30000 |
| 数据乱序 | Kafka 分区间无序 | 使用 Watermark + 窗口处理 |

---

## 七、生产最佳实践

### 6.1 资源配置建议

```bash
# ============================================================
# 生产环境 Kafka ETL 作业资源配置
# ============================================================

# 原则: parallelism = Kafka Source Partition 数
# 例: Source Topic 16 个 Partition → parallelism = 16

# TM 数量 = parallelism / slots = 16 / 4 = 4 个 TM
# 每个 TM: 4 Slot, 8G 内存, 4 vCore

$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -d \
  -Dyarn.application.name="production-kafka-etl" \
  -Djobmanager.memory.process.size=4096m \
  -Dtaskmanager.memory.process.size=8192m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=16 \
  -Dyarn.containers.vcores=4 \
  -c com.example.flink.KafkaETLJob \
  hdfs:///flink/jars/kafka-etl-job-1.0.jar
```

### 6.2 关键参数调优

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `parallelism.default` | = Kafka Partition 数 | 最佳吞吐对齐 |
| `execution.checkpointing.interval` | 60s-120s | 越短恢复越快，但开销越大 |
| `state.backend` | rocksdb | 支持增量 CP |
| `state.backend.rocksdb.localdir` | SSD 路径 | RocksDB 性能优化 |
| `state.backend.incremental` | true | 增量 Checkpoint |
| `taskmanager.memory.managed.fraction` | 0.4 | 给 RocksDB 更多内存 |
| `partition.discovery.interval.ms` | 30000 | 动态发现新 Partition |
| `properties.fetch.max.bytes` | 52428800 (50MB) | 批量拉取提升吞吐 |
| `properties.max.poll.records` | 500-2000 | 每次 poll 记录数 |

### 6.3 监控与告警

```bash
# ============================================================
# Kafka Consumer Lag 监控（最重要！）
# ============================================================
$KAFKA_HOME/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka01:9092 \
  --group flink-etl-group \
  --describe

# 输出示例:
# GROUP    TOPIC         PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
# flink..  source_events 0          1000000         1000050         50
# flink..  source_events 1          980000          980000          0

# ============================================================
# 告警规则
# ============================================================
# | 指标 | 阈值 | 说明 |
# | Consumer Lag (总) | > 10000 | 处理延迟 |
# | Consumer Lag 增长率 | > 0 持续 5min | 追不上生产速率 |
# | Checkpoint Duration | > interval * 0.8 | CP 快要超时 |
# | Checkpoint Failure | > 0 | 状态持久化失败 |
```

---

## 七、举一反三

### 7.1 与其他组件的对比

| 维度 | Flink + Kafka | Spark Streaming + Kafka | Kafka Streams |
|------|---------------|------------------------|---------------|
| 延迟 | 毫秒级 | 秒级（micro-batch） | 毫秒级 |
| Exactly-Once | ✅ 原生支持 | ✅ 需配置 | ✅ 原生 |
| 复杂处理 | ✅ Window/CEP/Async | ✅ 基本支持 | ⚠️ 有限 |
| 部署方式 | YARN/K8s/Standalone | YARN/K8s | 嵌入应用 |
| 适合场景 | 通用实时处理 | 已有 Spark 栈 | 轻量级流处理 |

### 7.2 面试高频题

**Q1: Flink Kafka Exactly-Once 的实现原理？**
> 基于 Kafka 事务 + Flink Checkpoint 两阶段提交：Checkpoint 时 pre-commit（flush 数据到 Kafka 事务），Checkpoint 成功后 commit 事务。Source 通过 Checkpoint 记录 offset 实现精确回放。

**Q2: 并行度应该设置为多少？**
> 对于 Kafka Source，最佳并行度 = Source Topic 的 Partition 数。Partition 数 > 并行度时部分 subtask 消费多个分区；并行度 > Partition 数时多余 subtask 空闲。

**Q3: Consumer Lag 持续增长怎么办？**
> (1) 增大并行度；(2) 增大 TM 内存和 CPU；(3) 检查是否有反压（看 Flink UI 的 BackPressure）；(4) 优化处理逻辑（减少 IO）；(5) 增加 Source Topic Partition 数。

**Q4: `transaction.timeout.ms` 为什么要大于 Checkpoint 间隔？**
> 因为事务从 pre-commit 到 commit 的时间跨度 ≈ Checkpoint 间隔。如果事务超时 < CP 间隔，事务会在 commit 前被 Broker 超时关闭，导致数据丢失。

### 7.3 思考题

1. 如果 Source Topic 增加了 Partition，Flink 作业需要重启吗？如何自动发现？
2. 设计一个 Kafka → Flink → Kafka + HDFS 的多路输出方案（Statement Set）
3. 如果下游 Kafka 集群故障 10 分钟，对 Exactly-Once 作业有什么影响？如何应对？

---

> 📝 **教案总结**：Flink + Kafka 是实时处理标配。核心要点：(1) 并行度对齐 Kafka Partition；(2) Exactly-Once 需要 Checkpoint + 事务 Sink；(3) `transaction.timeout.ms` > CP 间隔；(4) 监控 Consumer Lag 是核心指标。
