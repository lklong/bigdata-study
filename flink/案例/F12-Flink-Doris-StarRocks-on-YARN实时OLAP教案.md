# [教案] Flink on YARN — Doris / StarRocks 实时 OLAP 写入使用姿势

> 🎯 教学目标：掌握 Flink 实时写入 Doris 和 StarRocks 的全流程，包括 Connector 配置、Stream Load 原理、Exactly-Once 语义 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

| 场景 | 说明 | 典型案例 |
|------|------|----------|
| **实时数仓** | Kafka → Flink → Doris/StarRocks，替代 T+1 离线报表 | 实时 GMV、实时活跃用户 |
| **实时大屏** | 秒级聚合写入 OLAP，前端直接查询 | 双十一大屏、运营监控 |
| **实时标签** | 流式计算用户标签，写入 OLAP 供画像圈人 | 用户画像实时更新 |
| **日志分析** | 结构化日志实时入 OLAP，替代 ES 部分场景 | 访问日志分析、错误监控 |
| **指标预聚合** | Flink 先做窗口聚合，减轻 OLAP 聚合压力 | 分钟级 PV/UV 预聚合 |

**为什么选 Doris / StarRocks？**
- 向量化执行引擎，聚合查询极快
- 支持 Stream Load 实时写入
- 支持明细 + 聚合 + 主键模型，灵活适配不同场景
- 兼容 MySQL 协议，BI 工具直接对接

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17+ / 1.18+ | 推荐 1.18.1 |
| Hadoop/YARN | 3.x | 需开启 YARN |
| Doris | 2.0+ | FE + BE |
| StarRocks | 3.0+ | FE + BE |
| Java | JDK 8 / JDK 11 | |
| Maven | 3.6+ | 构建项目 |

### 2.2 环境准备命令

```bash
# 1. 验证 Flink
export FLINK_HOME=/opt/flink-1.18.1
$FLINK_HOME/bin/flink --version

# 2. 验证 YARN
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)
yarn node -list

# 3. 验证 Doris 连通性
mysql -h doris-fe-host -P 9030 -uroot -p -e "SHOW FRONTENDS\G"
# 验证 Stream Load 端口（默认 8030/8040）
curl http://doris-fe-host:8030/api/bootstrap

# 4. 验证 StarRocks 连通性
mysql -h starrocks-fe-host -P 9030 -uroot -p -e "SHOW FRONTENDS\G"

# 5. 在 Doris 中创建测试库表
mysql -h doris-fe-host -P 9030 -uroot -p << 'EOF'
CREATE DATABASE IF NOT EXISTS flink_demo;
USE flink_demo;

-- 明细模型表（Duplicate Key）
CREATE TABLE IF NOT EXISTS order_detail (
    order_id VARCHAR(64),
    user_id VARCHAR(64),
    product_id VARCHAR(64),
    amount DECIMAL(10,2),
    status VARCHAR(16),
    order_time DATETIME,
    dt DATE
) ENGINE=OLAP
DUPLICATE KEY(order_id)
PARTITION BY RANGE(dt) (
    PARTITION p20260428 VALUES [('2026-04-28'), ('2026-04-29')),
    PARTITION p20260429 VALUES [('2026-04-29'), ('2026-04-30')),
    PARTITION p20260430 VALUES [('2026-04-30'), ('2026-05-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 8
PROPERTIES (
    "replication_num" = "3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-7",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "8"
);

-- 聚合模型表（Aggregate Key）
CREATE TABLE IF NOT EXISTS order_agg_1min (
    dt DATE,
    minute_ts DATETIME,
    user_id VARCHAR(64),
    order_count BIGINT SUM DEFAULT "0",
    total_amount DECIMAL(20,2) SUM DEFAULT "0.00",
    max_amount DECIMAL(10,2) MAX DEFAULT "0.00"
) ENGINE=OLAP
AGGREGATE KEY(dt, minute_ts, user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 8
PROPERTIES ("replication_num" = "3");

-- 主键模型表（Unique Key，用于 Upsert）
CREATE TABLE IF NOT EXISTS order_status (
    order_id VARCHAR(64),
    user_id VARCHAR(64),
    amount DECIMAL(10,2),
    status VARCHAR(16),
    update_time DATETIME
) ENGINE=OLAP
UNIQUE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 8
PROPERTIES (
    "replication_num" = "3",
    "enable_unique_key_merge_on_write" = "true"
);
EOF

# 6. 在 StarRocks 中创建测试库表
mysql -h starrocks-fe-host -P 9030 -uroot -p << 'EOF'
CREATE DATABASE IF NOT EXISTS flink_demo;
USE flink_demo;

CREATE TABLE IF NOT EXISTS order_detail (
    order_id VARCHAR(64),
    user_id VARCHAR(64),
    product_id VARCHAR(64),
    amount DECIMAL(10,2),
    status VARCHAR(16),
    order_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 8;

CREATE TABLE IF NOT EXISTS order_status (
    order_id VARCHAR(64),
    user_id VARCHAR(64),
    amount DECIMAL(10,2),
    status VARCHAR(16),
    update_time DATETIME
) ENGINE=OLAP
PRIMARY KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 8;
EOF

# 7. 下载 Connector JAR
# Doris Flink Connector
wget https://repo1.maven.org/maven2/org/apache/doris/flink-doris-connector-1.18/24.0.0/flink-doris-connector-1.18-24.0.0.jar \
  -P $FLINK_HOME/lib/

# StarRocks Flink Connector
wget https://repo1.maven.org/maven2/com/starrocks/flink-connector-starrocks/1.2.9_flink-1.18/flink-connector-starrocks-1.2.9_flink-1.18.jar \
  -P $FLINK_HOME/lib/
```

### 2.3 Maven 依赖

```xml
<properties>
    <flink.version>1.18.1</flink.version>
</properties>

<dependencies>
    <!-- Flink 核心 -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-streaming-java</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-table-api-java-bridge</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-clients</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>

    <!-- Flink Kafka Connector -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-connector-kafka</artifactId>
        <version>3.1.0-1.18</version>
    </dependency>

    <!-- Doris Flink Connector -->
    <dependency>
        <groupId>org.apache.doris</groupId>
        <artifactId>flink-doris-connector-1.18</artifactId>
        <version>24.0.0</version>
    </dependency>

    <!-- StarRocks Flink Connector -->
    <dependency>
        <groupId>com.starrocks</groupId>
        <artifactId>flink-connector-starrocks</artifactId>
        <version>1.2.9_flink-1.18</version>
    </dependency>

    <!-- JSON -->
    <dependency>
        <groupId>com.alibaba</groupId>
        <artifactId>fastjson</artifactId>
        <version>2.0.42</version>
    </dependency>
</dependencies>
```

---

## 三、核心使用方式

### 3.1 Stream Load 写入原理

```
┌────────┐    HTTP PUT    ┌──────────┐   Distribute   ┌──────────┐
│ Flink  │ ─────────────→ │ Doris FE │ ─────────────→ │ Doris BE │
│ Task   │   (CSV/JSON)   │ (Route)  │   (Tablet)     │ (Store)  │
└────────┘                └──────────┘                └──────────┘
```

**Stream Load 关键参数**：

| 参数 | 说明 | 默认值 | 建议值 |
|------|------|--------|--------|
| `format` | 数据格式 | csv | json（推荐） |
| `max_filter_ratio` | 最大容错率 | 0 | 0.01（允许 1% 脏数据） |
| `strip_outer_array` | JSON 数组剥离 | false | true（batch 写入时） |
| `read_json_by_line` | 逐行读 JSON | false | true（推荐） |
| `exec_mem_limit` | 单次 Load 内存限制 | 2GB | 根据 batch 大小调整 |
| `timeout` | Load 超时时间 | 600s | 根据数据量调整 |

### 3.2 Doris Flink Connector 参数详解

#### DataStream API 参数

| 参数 | 说明 | 默认值 | 推荐值 |
|------|------|--------|--------|
| `fenodes` | FE HTTP 地址 | 必填 | `doris-fe:8030` |
| `benodes` | BE HTTP 地址（绕过 FE 路由） | 可选 | 大流量时使用 |
| `username` | 用户名 | 必填 | `root` |
| `password` | 密码 | 必填 | |
| `table.identifier` | 库表名 | 必填 | `db.table` |
| `sink.batch.size` | batch 行数 | 50000 | 10000~100000 |
| `sink.batch.bytes` | batch 字节数 | 10MB | 5MB~50MB |
| `sink.batch.interval` | flush 间隔 | 10s | 5s~30s |
| `sink.max-retries` | 最大重试次数 | 3 | 3~5 |
| `sink.properties.format` | Stream Load 格式 | csv | json |
| `sink.properties.read_json_by_line` | 逐行读 JSON | false | true |
| `sink.enable-2pc` | 开启两阶段提交 | true | true（Exactly-Once） |
| `sink.label-prefix` | Label 前缀 | 空 | 应用名称 |

#### Flink SQL WITH 参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `connector` | 连接器类型 | `doris` |
| `fenodes` | FE 节点 | `doris-fe:8030` |
| `table.identifier` | 库.表 | `flink_demo.order_detail` |
| `username` | 用户名 | `root` |
| `password` | 密码 | |
| `sink.batch.size` | batch 行数 | `10000` |
| `sink.batch.interval` | flush 间隔 | `5s` |
| `sink.properties.format` | 格式 | `json` |
| `sink.enable-2pc` | 两阶段提交 | `true` |

### 3.3 StarRocks Flink Connector 参数详解

| 参数 | 说明 | 默认值 | 推荐值 |
|------|------|--------|--------|
| `jdbc-url` | JDBC 地址 | 必填 | `jdbc:mysql://sr-fe:9030` |
| `load-url` | FE HTTP 地址 | 必填 | `sr-fe:8030` |
| `database-name` | 数据库 | 必填 | |
| `table-name` | 表名 | 必填 | |
| `username` | 用户名 | 必填 | |
| `password` | 密码 | 必填 | |
| `sink.buffer-flush.max-rows` | batch 行数 | 500000 | 10000~100000 |
| `sink.buffer-flush.max-bytes` | batch 字节数 | 300MB | 50MB~100MB |
| `sink.buffer-flush.interval-ms` | flush 间隔 | 300000 | 5000~30000 |
| `sink.max-retries` | 最大重试次数 | 3 | 3 |
| `sink.semantic` | 语义 | at-least-once | exactly-once |
| `sink.properties.format` | 格式 | csv | json |
| `sink.properties.strip_outer_array` | 剥离 JSON 数组 | false | true |

---

## 四、完整实战示例

### 4.1 示例一：Kafka → Flink → Doris（DataStream API）

```java
import org.apache.doris.flink.cfg.DorisExecutionOptions;
import org.apache.doris.flink.cfg.DorisOptions;
import org.apache.doris.flink.cfg.DorisReadOptions;
import org.apache.doris.flink.sink.DorisSink;
import org.apache.doris.flink.sink.writer.serializer.SimpleStringSerializer;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

import java.util.Properties;

public class Kafka2DorisJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(4);

        // Checkpoint 配置（Exactly-Once 必须开启）
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setCheckpointTimeout(120000);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(30000);
        env.getCheckpointConfig().setMaxConcurrentCheckpoints(1);

        // ===== 1. Kafka Source =====
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka-host:9092")
                .setTopics("orders")
                .setGroupId("flink-doris-sink")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<String> sourceStream = env.fromSource(
                kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-source");

        // ===== 2. Doris Sink =====
        Properties sinkProps = new Properties();
        sinkProps.setProperty("format", "json");
        sinkProps.setProperty("read_json_by_line", "true");

        DorisSink.Builder<String> dorisBuilder = DorisSink.builder();
        dorisBuilder.setDorisReadOptions(DorisReadOptions.builder().build())
                .setDorisExecutionOptions(DorisExecutionOptions.builder()
                        .setLabelPrefix("flink-doris-orders")
                        .setStreamLoadProp(sinkProps)
                        .setDeletable(false)
                        .setBatchSize(10000)            // 10000 行 flush
                        .setBatchIntervalMs(5000L)      // 5s flush
                        .setMaxRetries(3)
                        .setEnable2PC(true)             // 开启 Exactly-Once
                        .build())
                .setDorisOptions(DorisOptions.builder()
                        .setFenodes("doris-fe-host:8030")
                        .setTableIdentifier("flink_demo.order_detail")
                        .setUsername("root")
                        .setPassword("your-password")
                        .build())
                .setSerializer(new SimpleStringSerializer());

        sourceStream.sinkTo(dorisBuilder.build()).name("doris-sink");

        env.execute("Kafka-to-Doris-Job");
    }
}
```

### 4.2 示例二：Kafka → Flink → Doris（Flink SQL）

```sql
-- 设置 Checkpoint
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';

-- Kafka Source 表
CREATE TABLE kafka_orders (
    order_id STRING,
    user_id STRING,
    product_id STRING,
    amount DECIMAL(10,2),
    status STRING,
    order_time TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka-host:9092',
    'properties.group.id' = 'flink-doris-sql',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);

-- Doris Sink 表
CREATE TABLE doris_order_detail (
    order_id STRING,
    user_id STRING,
    product_id STRING,
    amount DECIMAL(10,2),
    status STRING,
    order_time TIMESTAMP(3),
    dt DATE
) WITH (
    'connector' = 'doris',
    'fenodes' = 'doris-fe-host:8030',
    'table.identifier' = 'flink_demo.order_detail',
    'username' = 'root',
    'password' = 'your-password',
    'sink.batch.size' = '10000',
    'sink.batch.interval' = '5s',
    'sink.properties.format' = 'json',
    'sink.properties.read_json_by_line' = 'true',
    'sink.enable-2pc' = 'true',
    'sink.label-prefix' = 'flink_sql_orders'
);

-- 写入（添加分区字段 dt）
INSERT INTO doris_order_detail
SELECT
    order_id,
    user_id,
    product_id,
    amount,
    status,
    order_time,
    CAST(order_time AS DATE) AS dt
FROM kafka_orders;
```

### 4.3 示例三：Kafka → Flink → StarRocks（DataStream API）

```java
import com.starrocks.connector.flink.StarRocksSink;
import com.starrocks.connector.flink.table.sink.StarRocksSinkOptions;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

public class Kafka2StarRocksJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(4);
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);

        // ===== 1. Kafka Source =====
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka-host:9092")
                .setTopics("orders")
                .setGroupId("flink-starrocks-sink")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<String> sourceStream = env.fromSource(
                kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-source");

        // ===== 2. StarRocks Sink =====
        StarRocksSinkOptions sinkOptions = StarRocksSinkOptions.builder()
                .withProperty("jdbc-url", "jdbc:mysql://starrocks-fe:9030")
                .withProperty("load-url", "starrocks-fe:8030")
                .withProperty("database-name", "flink_demo")
                .withProperty("table-name", "order_detail")
                .withProperty("username", "root")
                .withProperty("password", "your-password")
                .withProperty("sink.buffer-flush.max-rows", "10000")
                .withProperty("sink.buffer-flush.max-bytes", "52428800")  // 50MB
                .withProperty("sink.buffer-flush.interval-ms", "5000")
                .withProperty("sink.max-retries", "3")
                .withProperty("sink.semantic", "exactly-once")
                .withProperty("sink.properties.format", "json")
                .withProperty("sink.properties.strip_outer_array", "true")
                .build();

        sourceStream
                .addSink(StarRocksSink.sink(sinkOptions))
                .name("starrocks-sink");

        env.execute("Kafka-to-StarRocks-Job");
    }
}
```

### 4.4 示例四：Kafka → Flink → StarRocks（Flink SQL）

```sql
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';

-- Kafka Source 表
CREATE TABLE kafka_orders (
    order_id STRING,
    user_id STRING,
    product_id STRING,
    amount DECIMAL(10,2),
    status STRING,
    order_time TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka-host:9092',
    'properties.group.id' = 'flink-sr-sql',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json'
);

-- StarRocks Sink 表
CREATE TABLE sr_order_detail (
    order_id STRING,
    user_id STRING,
    product_id STRING,
    amount DECIMAL(10,2),
    status STRING,
    order_time TIMESTAMP(3)
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://starrocks-fe:9030',
    'load-url' = 'starrocks-fe:8030',
    'database-name' = 'flink_demo',
    'table-name' = 'order_detail',
    'username' = 'root',
    'password' = 'your-password',
    'sink.buffer-flush.max-rows' = '10000',
    'sink.buffer-flush.interval-ms' = '5000',
    'sink.semantic' = 'exactly-once',
    'sink.properties.format' = 'json',
    'sink.properties.strip_outer_array' = 'true'
);

-- 写入
INSERT INTO sr_order_detail
SELECT * FROM kafka_orders;
```

### 4.5 Application Mode 提交命令

```bash
# ===== Doris 任务提交 =====
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Kafka-to-Doris" \
    -Dyarn.application.queue=default \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-doris \
    -c com.example.Kafka2DorisJob \
    /path/to/flink-doris-demo-1.0.jar

# ===== StarRocks 任务提交 =====
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Kafka-to-StarRocks" \
    -Dyarn.application.queue=default \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-starrocks \
    -c com.example.Kafka2StarRocksJob \
    /path/to/flink-starrocks-demo-1.0.jar

# ===== Flink SQL 通过 sql-client 提交 =====
$FLINK_HOME/bin/sql-client.sh embedded \
    -l $FLINK_HOME/lib/ \
    -f /path/to/kafka-to-doris.sql
```

### 4.6 验证

```bash
# 1. 发送测试数据到 Kafka
kafka-console-producer.sh --broker-list kafka-host:9092 --topic orders << 'EOF'
{"order_id":"ORD001","user_id":"U1001","product_id":"P001","amount":99.9,"status":"CREATED","order_time":"2026-04-29 10:00:00"}
{"order_id":"ORD002","user_id":"U1002","product_id":"P002","amount":259.0,"status":"PAID","order_time":"2026-04-29 10:01:00"}
{"order_id":"ORD003","user_id":"U1003","product_id":"P003","amount":188.5,"status":"CREATED","order_time":"2026-04-29 10:02:00"}
EOF

# 2. 查看 Doris 数据
mysql -h doris-fe-host -P 9030 -uroot -p -e "
  SELECT * FROM flink_demo.order_detail ORDER BY order_time;
"

# 3. 查看 StarRocks 数据
mysql -h starrocks-fe-host -P 9030 -uroot -p -e "
  SELECT * FROM flink_demo.order_detail ORDER BY order_time;
"

# 4. 查看 YARN 应用
yarn application -list | grep -E "Kafka-to-(Doris|StarRocks)"

# 5. 查看 Doris Stream Load 状态
curl -u root:password http://doris-fe-host:8030/api/flink_demo/_stream_load_info
```

---

## 五、常见问题与排障

### 5.1 问题速查表

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `ANALYSIS ERROR: Batch too large` | 单次 Stream Load 数据过大 | 减小 `sink.batch.size` 和 `sink.batch.bytes` |
| `Label Already Exists` | Label 重复（通常是重试导致） | 确保 `sink.label-prefix` 唯一，Doris 默认保留 label 3 天 |
| `Failed to load data: -235` | Stream Load 内存不足 | 增大 BE `load_process_max_memory_limit_bytes` |
| `TOO MANY VERSIONS` | 写入频率过高导致版本堆积 | 增大 batch size，降低 flush 频率，检查 BE compaction |
| `SEND BATCH TIMEOUT` | Stream Load 超时 | 增大 `sink.properties.timeout`，检查 FE/BE 网络 |
| Checkpoint 超时 | 2PC 提交太慢 | 增大 Checkpoint timeout，减少并行度 |
| `Connection refused: doris-fe:8030` | FE HTTP 端口不通 | 检查防火墙/安全组，确认 `http_port` 配置 |
| StarRocks `CANCELLED: Memory exceed limit` | BE 内存不足 | 减小 batch 大小，增加 BE 内存 |

### 5.2 排障命令

```bash
# 查看 Flink 任务日志
yarn logs -applicationId application_xxxxx_xxxx | grep -i "doris\|stream.load\|starrocks"

# 查看 Doris Stream Load 错误
# 从 Flink 日志中找到 ErrorURL，然后下载
wget -O error.txt "http://doris-be-host:8040/api/_load_error_log?file=xxx"

# 查看 Doris BE compaction 状态
curl http://doris-be-host:8040/api/compaction/run_status

# 查看 Doris 导入任务历史
mysql -h doris-fe -P 9030 -uroot -p -e "
  SHOW LOAD FROM flink_demo ORDER BY CreateTime DESC LIMIT 10;
"

# 查看 StarRocks 导入历史
mysql -h sr-fe -P 9030 -uroot -p -e "
  SELECT * FROM information_schema.loads
  WHERE database_name='flink_demo'
  ORDER BY create_time DESC LIMIT 10;
"
```

---

## 六、生产最佳实践

### 6.1 写入性能优化参数

#### Doris 推荐配置

```properties
# 中等吞吐（1K~10K TPS）
sink.batch.size = 10000
sink.batch.bytes = 10485760       # 10MB
sink.batch.interval = 10s
sink.max-retries = 3
sink.properties.format = json
sink.enable-2pc = true

# 高吞吐（10K~100K TPS）
sink.batch.size = 50000
sink.batch.bytes = 52428800       # 50MB
sink.batch.interval = 15s
sink.max-retries = 5
sink.properties.format = json
sink.enable-2pc = true
```

#### StarRocks 推荐配置

```properties
# 中等吞吐
sink.buffer-flush.max-rows = 10000
sink.buffer-flush.max-bytes = 52428800     # 50MB
sink.buffer-flush.interval-ms = 10000      # 10s
sink.semantic = exactly-once

# 高吞吐
sink.buffer-flush.max-rows = 50000
sink.buffer-flush.max-bytes = 104857600    # 100MB
sink.buffer-flush.interval-ms = 15000      # 15s
sink.semantic = exactly-once
```

### 6.2 Exactly-Once 写入机制（2PC）

```
┌─────────────────────────── Flink Checkpoint ───────────────────────────┐
│                                                                         │
│  Phase 1 (Pre-commit):                                                  │
│    Flink Task → Stream Load → Doris/StarRocks                          │
│    (写入数据，但不对外可见)                                                │
│                                                                         │
│  Phase 2 (Commit):                                                      │
│    Checkpoint 完成 → 调用 Commit 接口 → 数据可见                         │
│                                                                         │
│  Phase 2 (Abort):                                                       │
│    Checkpoint 失败 → 调用 Abort 接口 → 数据回滚                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**注意事项**：
- 必须开启 Flink Checkpoint（`EXACTLY_ONCE` 模式）
- Doris 需要确保 `sink.enable-2pc = true`
- StarRocks 需要设置 `sink.semantic = exactly-once`
- Checkpoint interval 决定了数据可见延迟（数据在 Checkpoint 完成后才可见）

### 6.3 资源配置参考

| 场景 | 吞吐量(TPS) | 并行度 | JM 内存 | TM 内存 | Slots | Batch Size | Flush Interval |
|------|-------------|--------|---------|---------|-------|-----------|----------------|
| 小流量 | <1K | 2 | 1G | 2G | 2 | 5000 | 10s |
| 中流量 | 1K~10K | 4 | 2G | 4G | 4 | 10000 | 10s |
| 大流量 | 10K~100K | 8~16 | 2G | 4~8G | 4 | 50000 | 15s |
| 超大流量 | >100K | 16~32 | 4G | 8G | 4 | 100000 | 20s |

### 6.4 监控告警

```yaml
# flink-conf.yaml 配置 Prometheus
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporter
metrics.reporter.prom.port: 9249

# 重点监控指标：
# 1. numRecordsOutPerSecond   — Sink 写出吞吐
# 2. currentSendTime          — Stream Load 耗时
# 3. numBytesOutPerSecond     — Sink 字节吞吐
# 4. checkpointDuration       — Checkpoint 耗时（2PC 场景很关键）
# 5. numberOfFailedCheckpoints — 失败 Checkpoint 次数

# 告警规则建议：
# - Checkpoint 连续失败 > 3次 → 告警
# - Sink 吞吐为 0 持续 > 5分钟 → 告警
# - Checkpoint 耗时 > Checkpoint Interval 的 80% → 告警
```

### 6.5 Doris BE 端优化

```sql
-- BE 配置优化（be.conf）
-- 增大 Stream Load 线程数
streaming_load_max_mb = 10240
load_process_max_memory_limit_bytes = 8589934592   -- 8GB
max_running_txn_num_per_db = 1000                  -- 并发 txn 上限

-- compaction 优化（避免 TOO MANY VERSIONS）
max_tablet_version_num = 500
cumulative_compaction_skip_window_seconds = 30
```

---

## 七、举一反三

### 7.1 Doris vs StarRocks 对比

| 维度 | Doris | StarRocks |
|------|-------|-----------|
| 数据模型 | Duplicate / Aggregate / Unique | Duplicate / Aggregate / Primary Key / Update |
| Stream Load | 支持 | 支持 |
| Exactly-Once | 2PC 支持 | 2PC 支持 |
| Flink Connector | apache-doris 官方维护 | starrocks 官方维护 |
| 向量化引擎 | 2.0+ 全面向量化 | 原生向量化 |
| 物化视图 | 同步物化视图 | 同步 + 异步物化视图 |
| 社区活跃度 | Apache 顶级项目 | Linux Foundation 项目 |

### 7.2 面试高频题

**Q1: Flink 写 Doris 如何保证 Exactly-Once？**

> 通过两阶段提交（2PC）：Phase 1 中 Flink 调用 Stream Load 写入但不提交（BE 端事务 PREPARED 状态），
> Phase 2 在 Checkpoint 成功后调用 Commit 使数据可见。若 Checkpoint 失败则调用 Abort 回滚。
> 前提条件：Flink 必须开启 EXACTLY_ONCE Checkpoint，Connector 开启 `sink.enable-2pc`。

**Q2: Stream Load 和 Routine Load 有什么区别？**

| 维度 | Stream Load | Routine Load |
|------|-------------|--------------|
| 调用方 | 客户端主动推 | Doris/SR 主动拉（Kafka） |
| 适用场景 | Flink/Spark 写入 | 简单 Kafka → Doris |
| 灵活性 | 高（可预处理） | 低（只能简单 ETL） |
| Exactly-Once | 通过 Flink 2PC | 内置支持 |

**Q3: 为什么写入 Doris/StarRocks 时要控制 batch size？**

- 过小：Stream Load 请求过于频繁，FE/BE 开销大，可能触发 `TOO MANY VERSIONS`
- 过大：单次 Load 耗时长，内存占用大，Checkpoint 延迟增大
- 最佳实践：10000~50000 行一批，或 10~50MB 一批，flush 间隔 5~15s

### 7.3 思考题

1. 如果 Doris/StarRocks 集群扩容（新增 BE 节点），Flink 任务是否需要重启？
2. 当 Flink 任务写入 Doris 出现 `TOO MANY VERSIONS` 时，除了调整 batch size，还有什么方法？
3. 如何设计一个 Lambda 架构，让 Flink 实时写入 StarRocks 同时保证离线数据的准确性？
4. Exactly-Once 语义下，Checkpoint interval 设为 10s 和 60s 分别有什么优缺点？

---

> 📝 **本教案配套代码仓库**: [bigdata-study/flink/案例/](https://github.com/lklong/bigdata-study/tree/main/flink/案例/)
> 📅 **更新日期**: 2026-04-29
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
