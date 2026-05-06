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
curl http://doris-fe-host:8030/api/bootstrap

# 4. 验证 StarRocks 连通性
mysql -h starrocks-fe-host -P 9030 -uroot -p -e "SHOW FRONTENDS\G"

# 5. 在 Doris 中创建测试库表
mysql -h doris-fe-host -P 9030 -uroot -p << 'EOF'
CREATE DATABASE IF NOT EXISTS flink_demo;
USE flink_demo;

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

# 6. 下载 Connector JAR
wget https://repo1.maven.org/maven2/org/apache/doris/flink-doris-connector-1.18/24.0.0/flink-doris-connector-1.18-24.0.0.jar \
  -P $FLINK_HOME/lib/
wget https://repo1.maven.org/maven2/com/starrocks/flink-connector-starrocks/1.2.9_flink-1.18/flink-connector-starrocks-1.2.9_flink-1.18.jar \
  -P $FLINK_HOME/lib/
```

### 2.3 Maven 依赖

```xml
<properties>
    <flink.version>1.18.1</flink.version>
</properties>

<dependencies>
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
        <artifactId>flink-connector-kafka</artifactId>
        <version>3.1.0-1.18</version>
    </dependency>
    <dependency>
        <groupId>org.apache.doris</groupId>
        <artifactId>flink-doris-connector-1.18</artifactId>
        <version>24.0.0</version>
    </dependency>
    <dependency>
        <groupId>com.starrocks</groupId>
        <artifactId>flink-connector-starrocks</artifactId>
        <version>1.2.9_flink-1.18</version>
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
| `max_filter_ratio` | 最大容错率 | 0 | 0.01 |
| `strip_outer_array` | JSON 数组剥离 | false | true |
| `read_json_by_line` | 逐行读 JSON | false | true |
| `exec_mem_limit` | 单次 Load 内存限制 | 2GB | 根据 batch 调整 |
| `timeout` | Load 超时时间 | 600s | 根据数据量调整 |

### 3.2 Doris Flink Connector 参数详解

| 参数 | 说明 | 默认值 | 推荐值 |
|------|------|--------|--------|
| `fenodes` | FE HTTP 地址 | 必填 | `doris-fe:8030` |
| `table.identifier` | 库表名 | 必填 | `db.table` |
| `sink.batch.size` | batch 行数 | 50000 | 10000~100000 |
| `sink.batch.bytes` | batch 字节数 | 10MB | 5MB~50MB |
| `sink.batch.interval` | flush 间隔 | 10s | 5s~30s |
| `sink.max-retries` | 最大重试次数 | 3 | 3~5 |
| `sink.properties.format` | Stream Load 格式 | csv | json |
| `sink.enable-2pc` | 开启两阶段提交 | true | true |
| `sink.label-prefix` | Label 前缀 | 空 | 应用名称 |

### 3.3 StarRocks Flink Connector 参数详解

| 参数 | 说明 | 默认值 | 推荐值 |
|------|------|--------|--------|
| `jdbc-url` | JDBC 地址 | 必填 | `jdbc:mysql://sr-fe:9030` |
| `load-url` | FE HTTP 地址 | 必填 | `sr-fe:8030` |
| `sink.buffer-flush.max-rows` | batch 行数 | 500000 | 10000~100000 |
| `sink.buffer-flush.max-bytes` | batch 字节数 | 300MB | 50MB~100MB |
| `sink.buffer-flush.interval-ms` | flush 间隔 | 300000 | 5000~30000 |
| `sink.semantic` | 语义 | at-least-once | exactly-once |
| `sink.properties.format` | 格式 | csv | json |

---

## 四、完整实战示例

### 4.1 Kafka → Flink → Doris（DataStream API）

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
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setCheckpointTimeout(120000);

        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka-host:9092")
                .setTopics("orders")
                .setGroupId("flink-doris-sink")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<String> sourceStream = env.fromSource(
                kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-source");

        Properties sinkProps = new Properties();
        sinkProps.setProperty("format", "json");
        sinkProps.setProperty("read_json_by_line", "true");

        DorisSink.Builder<String> dorisBuilder = DorisSink.builder();
        dorisBuilder.setDorisReadOptions(DorisReadOptions.builder().build())
                .setDorisExecutionOptions(DorisExecutionOptions.builder()
                        .setLabelPrefix("flink-doris-orders")
                        .setStreamLoadProp(sinkProps)
                        .setBatchSize(10000)
                        .setBatchIntervalMs(5000L)
                        .setMaxRetries(3)
                        .setEnable2PC(true)
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

### 4.2 Kafka → Flink → Doris（Flink SQL）

```sql
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';

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
    'format' = 'json'
);

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

INSERT INTO doris_order_detail
SELECT order_id, user_id, product_id, amount, status, order_time,
       CAST(order_time AS DATE) AS dt
FROM kafka_orders;
```

### 4.3 Kafka → Flink → StarRocks（DataStream API）

```java
import com.starrocks.connector.flink.StarRocksSink;
import com.starrocks.connector.flink.table.sink.StarRocksSinkOptions;

public class Kafka2StarRocksJob {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(4);
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);

        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka-host:9092")
                .setTopics("orders")
                .setGroupId("flink-starrocks-sink")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<String> sourceStream = env.fromSource(
                kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-source");

        StarRocksSinkOptions sinkOptions = StarRocksSinkOptions.builder()
                .withProperty("jdbc-url", "jdbc:mysql://starrocks-fe:9030")
                .withProperty("load-url", "starrocks-fe:8030")
                .withProperty("database-name", "flink_demo")
                .withProperty("table-name", "order_detail")
                .withProperty("username", "root")
                .withProperty("password", "your-password")
                .withProperty("sink.buffer-flush.max-rows", "10000")
                .withProperty("sink.buffer-flush.max-bytes", "52428800")
                .withProperty("sink.buffer-flush.interval-ms", "5000")
                .withProperty("sink.semantic", "exactly-once")
                .withProperty("sink.properties.format", "json")
                .withProperty("sink.properties.strip_outer_array", "true")
                .build();

        sourceStream.addSink(StarRocksSink.sink(sinkOptions)).name("starrocks-sink");
        env.execute("Kafka-to-StarRocks-Job");
    }
}
```

### 4.4 Application Mode 提交命令

```bash
# Doris 任务提交
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Kafka-to-Doris" \
    -Dyarn.application.queue=default \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-doris \
    -c com.example.Kafka2DorisJob \
    /path/to/flink-doris-demo-1.0.jar

# StarRocks 任务提交
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Kafka-to-StarRocks" \
    -Dyarn.application.queue=default \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-starrocks \
    -c com.example.Kafka2StarRocksJob \
    /path/to/flink-starrocks-demo-1.0.jar
```

### 4.5 验证

```bash
# 发送测试数据
kafka-console-producer.sh --broker-list kafka-host:9092 --topic orders << 'EOF'
{"order_id":"ORD001","user_id":"U1001","product_id":"P001","amount":99.9,"status":"CREATED","order_time":"2026-04-29 10:00:00"}
{"order_id":"ORD002","user_id":"U1002","product_id":"P002","amount":259.0,"status":"PAID","order_time":"2026-04-29 10:01:00"}
EOF

# 查看 Doris 数据
mysql -h doris-fe-host -P 9030 -uroot -p -e "SELECT * FROM flink_demo.order_detail;"

# 查看 StarRocks 数据
mysql -h starrocks-fe-host -P 9030 -uroot -p -e "SELECT * FROM flink_demo.order_detail;"
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `Batch too large` | 单次 Stream Load 数据过大 | 减小 `sink.batch.size` |
| `Label Already Exists` | Label 重复 | 确保 `sink.label-prefix` 唯一 |
| `TOO MANY VERSIONS` | 写入频率过高 | 增大 batch size，降低 flush 频率 |
| `SEND BATCH TIMEOUT` | Stream Load 超时 | 增大 timeout，检查网络 |
| Checkpoint 超时 | 2PC 提交太慢 | 增大 Checkpoint timeout |
| `Connection refused` | FE HTTP 端口不通 | 检查防火墙 |

```bash
# 排障命令
yarn logs -applicationId application_xxxxx_xxxx | grep -i "doris\|starrocks"
curl http://doris-be-host:8040/api/compaction/run_status
mysql -h doris-fe -P 9030 -uroot -p -e "SHOW LOAD FROM flink_demo ORDER BY CreateTime DESC LIMIT 10;"
```

---

## 六、生产最佳实践

### 6.1 Exactly-Once 机制（2PC）

```
Phase 1: Flink Task → Stream Load → Doris BE（数据写入但不可见）
Phase 2: Checkpoint 成功 → Commit → 数据可见
         Checkpoint 失败 → Abort → 数据回滚
```

### 6.2 资源配置参考

| 吞吐量(TPS) | 并行度 | TM 内存 | Batch Size | Flush Interval |
|-------------|--------|---------|-----------|----------------|
| <1K | 2 | 2G | 5000 | 10s |
| 1K~10K | 4 | 4G | 10000 | 10s |
| 10K~100K | 8~16 | 4~8G | 50000 | 15s |
| >100K | 16~32 | 8G | 100000 | 20s |

### 6.3 监控告警

```yaml
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporter
metrics.reporter.prom.port: 9249
# 重点: numRecordsOutPerSecond / checkpointDuration / numberOfFailedCheckpoints
```

---

## 七、举一反三

### 7.1 Doris vs StarRocks

| 维度 | Doris | StarRocks |
|------|-------|-----------|
| 数据模型 | Duplicate/Aggregate/Unique | Duplicate/Aggregate/Primary Key |
| 2PC 支持 | ✅ | ✅ |
| 向量化 | 2.0+ 全面 | 原生 |
| 物化视图 | 同步 | 同步+异步 |

### 7.2 面试题

**Q: Flink 写 Doris 如何保证 Exactly-Once？**
> 两阶段提交：Phase 1 写入不提交，Phase 2 Checkpoint 成功后 Commit。需开启 Checkpoint + `sink.enable-2pc`。

**Q: 为什么要控制 batch size？**
> 过小：请求频繁，触发 TOO MANY VERSIONS；过大：内存占用高，Checkpoint 延迟大。建议 10000~50000 行。

### 7.3 思考题

1. 如果 Doris 集群扩容，Flink 任务是否需要重启？
2. 如何设计 Lambda 架构让实时和离线数据共存？
3. Checkpoint interval 10s vs 60s 各有什么优缺点？

---

> 📅 **更新日期**: 2026-04-29
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
