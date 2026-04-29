# [教案] Flink on YARN — Elasticsearch 实时索引使用姿势

> 🎯 教学目标：掌握 Flink Elasticsearch Connector 配置与调优，实现 Kafka → Flink → ES 实时索引链路 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：想象你经营一家大型图书馆，每天有成千上万本新书入库。如果每本书都要人工翻阅、分类、贴标签后才能上架检索，效率极低。你需要一条自动化流水线——书一到仓库，自动扫描内容、提取关键信息、建立索引卡片，读者随时能搜到。

**生产场景**：电商平台每秒产生数万条用户行为日志（点击、搜索、加购、下单），运营团队需要实时查询"最近5分钟哪些商品被搜索最多"、"某用户最近的浏览轨迹"。这些日志从 Kafka 流入，经 Flink 实时清洗、结构化后，写入 Elasticsearch 建立全文索引，供 Kibana 可视化和业务 API 实时查询。

**本教案解决的问题**：
- 如何配置 Flink Elasticsearch Connector（兼容 ES 6/7/8）
- 如何实现 Sink 写入 ES（index / upsert / delete）
- 如何调优批量写入参数提升吞吐
- 如何实现动态索引命名（按天/按月分索引）
- 如何保证故障重试与幂等性

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Flink | 1.17.x / 1.18.x / 1.19.x | 推荐 1.18+ |
| Hadoop/YARN | 3.x | 提供资源调度 |
| Elasticsearch | 6.x / 7.x / 8.x | 推荐 7.17+ 或 8.x |
| Kafka | 2.x / 3.x | 数据源 |
| Java | JDK 8 / 11 | Flink 运行时 |

### 2.2 所需 JAR 包

```bash
# Elasticsearch 7 Connector（最常用）
flink-sql-connector-elasticsearch7-3.0.1-1.17.jar

# Elasticsearch 6 Connector（老集群）
flink-sql-connector-elasticsearch6-3.0.1-1.17.jar

# 如果使用 Flink 1.18+，ES 8 有独立 connector
flink-connector-elasticsearch-3.1.0-1.18.jar

# Kafka Connector（数据源）
flink-sql-connector-kafka-3.1.0-1.18.jar

# JSON 格式支持
flink-json-1.18.1.jar
```

### 2.3 环境准备命令

```bash
# ========== 1. 设置环境变量 ==========
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CLASSPATH=$(hadoop classpath)
export HADOOP_CONF_DIR=/etc/hadoop/conf

# ========== 2. 下载并部署 Connector JAR ==========
cd $FLINK_HOME/lib

# ES 7 Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-elasticsearch7/3.0.1-1.17/flink-sql-connector-elasticsearch7-3.0.1-1.17.jar

# Kafka Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.1.0-1.18/flink-sql-connector-kafka-3.1.0-1.18.jar

# ========== 3. 验证 ES 集群可达 ==========
curl -X GET "http://es-node1:9200/_cluster/health?pretty"

# ========== 4. 验证 Kafka Topic 存在 ==========
kafka-topics.sh --bootstrap-server kafka01:9092 --describe --topic user_behavior

# ========== 5. 创建 ES 索引模板（推荐预先创建） ==========
curl -X PUT "http://es-node1:9200/_index_template/user_behavior_template" \
  -H 'Content-Type: application/json' -d '{
  "index_patterns": ["user_behavior_*"],
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "refresh_interval": "5s"
    },
    "mappings": {
      "properties": {
        "user_id":       { "type": "keyword" },
        "item_id":       { "type": "keyword" },
        "behavior":      { "type": "keyword" },
        "category":      { "type": "keyword" },
        "ts":            { "type": "date", "format": "yyyy-MM-dd HH:mm:ss||epoch_millis" },
        "dt":            { "type": "keyword" },
        "client_ip":     { "type": "ip" },
        "search_keyword": { "type": "text", "analyzer": "ik_max_word" }
      }
    }
  }
}'
```

---

## 三、核心使用方式

### 3.1 ES 版本差异对比

| 特性 | ES 6.x | ES 7.x | ES 8.x |
|------|--------|--------|--------|
| Flink Connector | flink-sql-connector-elasticsearch6 | flink-sql-connector-elasticsearch7 | flink-connector-elasticsearch (3.1.0+) |
| Type 概念 | 需要指定 `_type` | 默认 `_doc`，可省略 | 完全移除 Type |
| 认证方式 | 基础认证 / Shield | 基础认证 / X-Pack | API Key / 基础认证 / TLS |
| 连接协议 | REST (HTTP) | REST (HTTP) | REST (HTTPS 推荐) |
| SQL DDL 区别 | 需 `document-type` | 可选 `document-type` | 无需 `document-type` |

### 3.2 Flink SQL 方式 — 建表语法

#### ES 7 Sink 表（最常用）

```sql
CREATE TABLE es_user_behavior (
    user_id     STRING,
    item_id     STRING,
    behavior    STRING,
    category    STRING,
    ts          TIMESTAMP(3),
    dt          STRING,
    PRIMARY KEY (user_id, item_id, ts) NOT ENFORCED  -- 用于 upsert 模式
) WITH (
    'connector'                          = 'elasticsearch-7',
    'hosts'                              = 'http://es-node1:9200;http://es-node2:9200;http://es-node3:9200',
    'index'                              = 'user_behavior_{dt}',  -- 动态索引
    'document-id.key-delimiter'          = '_',                   -- 复合主键分隔符
    'sink.bulk-flush.max-actions'        = '1000',                -- 每批最大文档数
    'sink.bulk-flush.max-size'           = '10mb',                -- 每批最大字节
    'sink.bulk-flush.interval'           = '5s',                  -- 最大刷新间隔
    'sink.bulk-flush.backoff.strategy'   = 'EXPONENTIAL',         -- 重试策略
    'sink.bulk-flush.backoff.max-retries'= '3',                   -- 最大重试次数
    'sink.bulk-flush.backoff.delay'      = '1000',                -- 重试间隔(ms)
    'connection.max-retry-timeout'       = '3min',                -- 连接最大重试超时
    'format'                             = 'json'
);
```

#### ES 6 Sink 表

```sql
CREATE TABLE es6_sink (
    user_id     STRING,
    item_id     STRING,
    behavior    STRING,
    PRIMARY KEY (user_id) NOT ENFORCED
) WITH (
    'connector'        = 'elasticsearch-6',
    'hosts'            = 'http://es-node1:9200',
    'index'            = 'user_behavior',
    'document-type'    = '_doc',              -- ES 6 必须指定
    'format'           = 'json'
);
```

### 3.3 写入模式详解

| 写入模式 | 触发条件 | ES 操作 | 说明 |
|---------|---------|---------|------|
| **Append (index)** | 无 PRIMARY KEY | `Index` API | 每条数据生成新文档，可能重复 |
| **Upsert** | 定义了 PRIMARY KEY | `Index` API (带 `_id`) | 相同 `_id` 覆盖写入，天然幂等 |
| **Delete** | Retract 流（如 GROUP BY 后的撤回） | `Delete` API | 自动处理 Changelog 流的 -D 消息 |

```sql
-- Append 模式: 不定义主键，每条消息生成新文档
CREATE TABLE es_append_sink (
    user_id   STRING,
    behavior  STRING,
    ts        TIMESTAMP(3)
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts'     = 'http://es-node1:9200',
    'index'     = 'user_logs'
);

-- Upsert 模式: 定义主键，相同主键覆盖
CREATE TABLE es_upsert_sink (
    user_id       STRING,
    behavior_cnt  BIGINT,
    last_ts       TIMESTAMP(3),
    PRIMARY KEY (user_id) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts'     = 'http://es-node1:9200',
    'index'     = 'user_stats'
);

-- 写入（自动 upsert，相同 user_id 会更新）
INSERT INTO es_upsert_sink
SELECT user_id, COUNT(*) AS behavior_cnt, MAX(ts) AS last_ts
FROM kafka_source
GROUP BY user_id;
```

### 3.4 批量写入参数详解

| 参数 | 默认值 | 建议值 | 说明 |
|------|-------|-------|------|
| `sink.bulk-flush.max-actions` | 1000 | 1000~5000 | 缓冲区积累到此文档数时触发一次 bulk 请求 |
| `sink.bulk-flush.max-size` | 2mb | 5mb~10mb | 缓冲区积累到此字节数时触发 bulk 请求 |
| `sink.bulk-flush.interval` | 1s | 3s~10s | 定时触发 bulk 请求的间隔 |
| `sink.bulk-flush.backoff.strategy` | DISABLED | EXPONENTIAL | 重试退避策略: DISABLED / CONSTANT / EXPONENTIAL |
| `sink.bulk-flush.backoff.max-retries` | 8 | 3~5 | 最大重试次数 |
| `sink.bulk-flush.backoff.delay` | 50ms | 1000ms | 重试间隔基数 |
| `connection.max-retry-timeout` | - | 3min | 连接失败最大重试超时 |
| `connection.path-prefix` | - | - | URL 路径前缀（反向代理场景） |

**触发 Flush 的条件（满足任一即触发）**：
1. 缓冲文档数 ≥ `max-actions`
2. 缓冲字节数 ≥ `max-size`
3. 距上次 flush 的时间 ≥ `interval`
4. Checkpoint 触发时强制 flush

### 3.5 动态索引命名策略

```sql
-- 方式1: 使用字段值作为索引后缀（按天分索引）
-- 表中必须有 dt 字段，值如 '2026-04-29'
CREATE TABLE es_dynamic_index (
    user_id   STRING,
    behavior  STRING,
    ts        TIMESTAMP(3),
    dt        STRING,   -- 日期分区字段
    PRIMARY KEY (user_id, ts) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts'     = 'http://es-node1:9200',
    'index'     = 'user_behavior_{dt}'   -- {dt} 会被替换为字段值
);

-- 方式2: 使用内置函数生成日期字段
INSERT INTO es_dynamic_index
SELECT 
    user_id,
    behavior,
    ts,
    DATE_FORMAT(ts, 'yyyy-MM-dd') AS dt
FROM kafka_source;

-- 方式3: 按月分索引
-- index = 'user_behavior_{month_str}'
-- month_str = DATE_FORMAT(ts, 'yyyy-MM')
```

### 3.6 ES 认证配置

```sql
-- 基础认证（用户名密码）
CREATE TABLE es_auth_sink (
    ...
) WITH (
    'connector'    = 'elasticsearch-7',
    'hosts'        = 'https://es-node1:9200',
    'username'     = 'elastic',
    'password'     = 'your_password',
    'index'        = 'my_index'
);

-- 如果 ES 使用自签名证书，DataStream API 中需配置:
-- restClientFactory 设置 SSLContext
```

---

## 四、完整实战示例

### 4.1 场景描述

**业务需求**：电商平台用户行为日志实时搜索系统
- **数据源**：Kafka Topic `user_behavior`，JSON 格式
- **处理逻辑**：Flink 实时读取 → 数据清洗（过滤异常数据、补全字段）→ 写入 ES
- **索引策略**：按天动态索引 `user_behavior_2026-04-29`
- **查询需求**：支持按 user_id、behavior、时间范围、搜索关键词检索

**Kafka 消息格式**：
```json
{
  "user_id": "user_10086",
  "item_id": "item_2001",
  "behavior": "click",
  "category": "electronics",
  "search_keyword": "iPhone 16",
  "client_ip": "192.168.1.100",
  "ts": "2026-04-29 14:30:00"
}
```

### 4.2 Flink SQL 写法

```sql
-- ============================================================
-- Step 1: 创建 Kafka Source 表
-- ============================================================
CREATE TABLE kafka_user_behavior (
    user_id        STRING,
    item_id        STRING,
    behavior       STRING,
    category       STRING,
    search_keyword STRING,
    client_ip      STRING,
    ts             TIMESTAMP(3),
    -- 生成日期分区字段
    dt AS DATE_FORMAT(ts, 'yyyy-MM-dd'),
    -- 定义 Watermark
    WATERMARK FOR ts AS ts - INTERVAL '5' SECOND
) WITH (
    'connector'                  = 'kafka',
    'topic'                      = 'user_behavior',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id'        = 'flink_es_consumer',
    'scan.startup.mode'          = 'latest-offset',
    'format'                     = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors'   = 'true'
);

-- ============================================================
-- Step 2: 创建 ES Sink 表（按天动态索引 + Upsert 模式）
-- ============================================================
CREATE TABLE es_user_behavior_sink (
    user_id        STRING,
    item_id        STRING,
    behavior       STRING,
    category       STRING,
    search_keyword STRING,
    client_ip      STRING,
    ts             TIMESTAMP(3),
    dt             STRING,
    PRIMARY KEY (user_id, item_id, ts) NOT ENFORCED
) WITH (
    'connector'                           = 'elasticsearch-7',
    'hosts'                               = 'http://es-node1:9200;http://es-node2:9200;http://es-node3:9200',
    'index'                               = 'user_behavior_{dt}',
    'document-id.key-delimiter'           = '_',
    'sink.bulk-flush.max-actions'         = '2000',
    'sink.bulk-flush.max-size'            = '10mb',
    'sink.bulk-flush.interval'            = '5s',
    'sink.bulk-flush.backoff.strategy'    = 'EXPONENTIAL',
    'sink.bulk-flush.backoff.max-retries' = '3',
    'sink.bulk-flush.backoff.delay'       = '1000',
    'connection.max-retry-timeout'        = '3min',
    'format'                              = 'json'
);

-- ============================================================
-- Step 3: 数据清洗 + 写入 ES
-- ============================================================
INSERT INTO es_user_behavior_sink
SELECT
    user_id,
    item_id,
    behavior,
    COALESCE(category, 'unknown') AS category,
    COALESCE(search_keyword, '') AS search_keyword,
    COALESCE(client_ip, '0.0.0.0') AS client_ip,
    ts,
    dt
FROM kafka_user_behavior
WHERE user_id IS NOT NULL
  AND behavior IN ('click', 'search', 'cart', 'buy', 'fav')
  AND ts > TIMESTAMP '2020-01-01 00:00:00';

-- ============================================================
-- Step 4: 同时输出聚合统计到另一个 ES 索引（Upsert）
-- ============================================================
CREATE TABLE es_behavior_stats (
    behavior       STRING,
    dt             STRING,
    behavior_cnt   BIGINT,
    user_cnt       BIGINT,
    PRIMARY KEY (behavior, dt) NOT ENFORCED
) WITH (
    'connector'                    = 'elasticsearch-7',
    'hosts'                        = 'http://es-node1:9200',
    'index'                        = 'behavior_stats_{dt}',
    'sink.bulk-flush.max-actions'  = '100',
    'sink.bulk-flush.interval'     = '10s',
    'format'                       = 'json'
);

INSERT INTO es_behavior_stats
SELECT
    behavior,
    dt,
    COUNT(*) AS behavior_cnt,
    COUNT(DISTINCT user_id) AS user_cnt
FROM kafka_user_behavior
GROUP BY behavior, dt;
```

### 4.3 DataStream API 写法（Java）

```java
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.elasticsearch.sink.Elasticsearch7SinkBuilder;
import org.apache.flink.connector.elasticsearch.sink.ElasticsearchSink;
import org.apache.flink.connector.elasticsearch.sink.FlushBackoffType;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.http.HttpHost;
import org.elasticsearch.action.index.IndexRequest;
import org.elasticsearch.client.Requests;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.Map;

public class UserBehaviorToES {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000); // 60s Checkpoint

        // ========== 1. Kafka Source ==========
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
                .setTopics("user_behavior")
                .setGroupId("flink_es_datastream")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<String> kafkaStream = env.fromSource(
                kafkaSource,
                org.apache.flink.api.common.eventtime.WatermarkStrategy.noWatermarks(),
                "Kafka Source"
        );

        // ========== 2. JSON 解析 + 清洗 ==========
        ObjectMapper mapper = new ObjectMapper();
        DataStream<Map<String, Object>> cleanedStream = kafkaStream
                .map((MapFunction<String, Map<String, Object>>) value -> {
                    JsonNode node = mapper.readTree(value);
                    Map<String, Object> doc = new HashMap<>();
                    doc.put("user_id", node.path("user_id").asText(""));
                    doc.put("item_id", node.path("item_id").asText(""));
                    doc.put("behavior", node.path("behavior").asText(""));
                    doc.put("category", node.path("category").asText("unknown"));
                    doc.put("search_keyword", node.path("search_keyword").asText(""));
                    doc.put("client_ip", node.path("client_ip").asText("0.0.0.0"));
                    doc.put("ts", node.path("ts").asText());
                    // 提取日期用于动态索引
                    String tsStr = node.path("ts").asText("");
                    if (tsStr.length() >= 10) {
                        doc.put("dt", tsStr.substring(0, 10)); // yyyy-MM-dd
                    } else {
                        doc.put("dt", LocalDateTime.now().format(
                            DateTimeFormatter.ofPattern("yyyy-MM-dd")));
                    }
                    return doc;
                })
                .filter(doc -> doc.get("user_id") != null 
                        && !doc.get("user_id").toString().isEmpty());

        // ========== 3. Elasticsearch Sink ==========
        ElasticsearchSink<Map<String, Object>> esSink = new Elasticsearch7SinkBuilder<Map<String, Object>>()
                .setHosts(
                    new HttpHost("es-node1", 9200, "http"),
                    new HttpHost("es-node2", 9200, "http"),
                    new HttpHost("es-node3", 9200, "http")
                )
                .setEmitter((element, context, indexer) -> {
                    // 动态索引名
                    String indexName = "user_behavior_" + element.get("dt");
                    // 文档 ID（用于 upsert 幂等）
                    String docId = element.get("user_id") + "_" 
                                 + element.get("item_id") + "_" 
                                 + element.get("ts");

                    IndexRequest request = Requests.indexRequest()
                            .index(indexName)
                            .id(docId)
                            .source(element);
                    indexer.add(request);
                })
                .setBulkFlushMaxActions(2000)
                .setBulkFlushMaxSizeMb(10)
                .setBulkFlushInterval(5000)
                .setBulkFlushBackoffStrategy(FlushBackoffType.EXPONENTIAL, 3, 1000)
                .build();

        cleanedStream.sinkTo(esSink);

        env.execute("User Behavior to Elasticsearch");
    }
}
```

### 4.4 Application Mode on YARN 提交命令

```bash
# ============================================================
# SQL 作业提交（使用 sql-client 导出的 SQL 文件）
# ============================================================
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Flink-Kafka2ES-UserBehavior" \
    -Dyarn.application.queue=flink \
    -Dyarn.ship-files="/opt/flink-1.18.1/lib/flink-sql-connector-elasticsearch7-3.0.1-1.17.jar;/opt/flink-1.18.1/lib/flink-sql-connector-kafka-3.1.0-1.18.jar" \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka2es \
    -c com.example.UserBehaviorToES \
    /path/to/user-behavior-es-job.jar

# ============================================================
# DataStream JAR 包提交
# ============================================================
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=6 \
    -Dyarn.application.name="Flink-UserBehavior2ES-DataStream" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/user-behavior-es \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/user-behavior-es \
    -c com.example.UserBehaviorToES \
    hdfs:///flink/jars/user-behavior-es-job.jar
```

### 4.5 验证结果

```bash
# 1. 查看 ES 索引是否创建
curl -X GET "http://es-node1:9200/_cat/indices/user_behavior_*?v&s=index"

# 2. 查看文档数量
curl -X GET "http://es-node1:9200/user_behavior_2026-04-29/_count?pretty"

# 3. 搜索验证
curl -X GET "http://es-node1:9200/user_behavior_2026-04-29/_search?pretty" \
  -H 'Content-Type: application/json' -d '{
  "query": {
    "bool": {
      "must": [
        { "term": { "user_id": "user_10086" } },
        { "term": { "behavior": "click" } }
      ]
    }
  },
  "sort": [{ "ts": { "order": "desc" } }],
  "size": 10
}'

# 4. 全文搜索验证
curl -X GET "http://es-node1:9200/user_behavior_*/_search?pretty" \
  -H 'Content-Type: application/json' -d '{
  "query": {
    "match": {
      "search_keyword": "iPhone"
    }
  },
  "size": 5
}'

# 5. 聚合统计验证
curl -X GET "http://es-node1:9200/user_behavior_*/_search?pretty" \
  -H 'Content-Type: application/json' -d '{
  "size": 0,
  "aggs": {
    "by_behavior": {
      "terms": { "field": "behavior", "size": 10 }
    }
  }
}'

# 6. 查看 Flink 作业状态
$FLINK_HOME/bin/flink list -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|---------|------|---------|
| `NoNodeAvailableException` | ES 集群不可达或端口错误 | 检查 `hosts` 配置，确认网络连通性 `curl es-node:9200` |
| `ElasticsearchException: Bulk has failures` | 部分文档写入失败（字段类型冲突、mapping 不匹配） | 查看 Flink 日志中详细错误，修正数据类型或更新 ES mapping |
| `index_not_found_exception` | 动态索引未自动创建，ES 禁用了自动建索引 | ES 设置 `action.auto_create_index: true` 或预先创建索引模板 |
| `mapper_parsing_exception` | 写入数据的字段类型与 ES mapping 不匹配 | 确保 Flink 输出字段类型与 ES mapping 一致；使用 `CAST()` 转换 |
| 写入吞吐量低 | bulk 参数太小，flush 太频繁 | 增大 `max-actions`(5000+)、`max-size`(10mb+)、延长 `interval` |
| ES 集群负载过高 | bulk 参数太大，flush 不够频繁导致峰值压力 | 减小 bulk 参数，增加 ES 节点或分片数 |
| `circuit_breaking_exception` | ES JVM 内存不足触发熔断 | 增加 ES 堆内存或减少 Flink 并发/bulk 大小 |
| Checkpoint 时 ES Sink 超时 | flush 时间过长阻塞 Checkpoint | 减小 bulk 参数；增加 `connection.max-retry-timeout` |
| 文档重复 | 未使用 upsert 模式（无主键） | 定义 PRIMARY KEY 开启 upsert；或在 DataStream 中手动设置 `_id` |
| 动态索引名不生效 | `{field}` 引用了不存在的字段或字段为 null | 确保 SELECT 中包含该字段且不为 null；使用 COALESCE 兜底 |

---

## 六、生产最佳实践

### 6.1 资源配置建议

| 场景 | Kafka 分区数 | Flink 并行度 | TM 内存 | TM Slot | ES Shard 数 |
|------|------------|-------------|---------|---------|-------------|
| 低流量（<1000 TPS） | 3~6 | 3~6 | 2GB | 1 | 3 |
| 中流量（1K~10K TPS） | 6~12 | 6~12 | 4GB | 2 | 6~9 |
| 高流量（10K~100K TPS） | 12~24 | 12~24 | 8GB | 2~4 | 9~15 |
| 超高流量（>100K TPS） | 24+ | 24+ | 8~16GB | 2~4 | 15~30 |

**Container 数量计算**：`Container 数 = ceil(并行度 / Slot数) + 1(JobManager)`

### 6.2 关键参数调优

```yaml
# ========== flink-conf.yaml 关键配置 ==========

# ----- Checkpoint -----
execution.checkpointing.interval: 60000        # 60秒
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 300000         # 5分钟超时
state.backend: rocksdb
state.backend.incremental: true
state.checkpoints.dir: hdfs:///flink/checkpoints

# ----- ES Sink 调优 -----
# 在 SQL DDL WITH 子句或 DataStream Builder 中设置:
# sink.bulk-flush.max-actions: 2000~5000
# sink.bulk-flush.max-size: 10mb
# sink.bulk-flush.interval: 5s~10s
# sink.bulk-flush.backoff.strategy: EXPONENTIAL
# sink.bulk-flush.backoff.max-retries: 3

# ----- 网络缓冲 -----
taskmanager.network.memory.fraction: 0.15
taskmanager.network.memory.min: 128mb
taskmanager.network.memory.max: 1gb

# ----- 重启策略 -----
restart-strategy: fixed-delay
restart-strategy.fixed-delay.attempts: 3
restart-strategy.fixed-delay.delay: 30s
```

### 6.3 监控与告警

**关键监控指标**：

| 指标 | 含义 | 告警阈值 |
|------|------|---------|
| `numRecordsOutPerSecond` | ES Sink 每秒写入记录数 | 持续 <预期TPS的50% 告警 |
| `currentSendTime` | ES bulk 请求平均耗时 | >10s 告警 |
| `numBytesOutPerSecond` | ES Sink 每秒写入字节数 | 异常波动告警 |
| `numRecordsInPerSecond` | Kafka Source 每秒消费数 | 持续为0告警 |
| `pendingRecords` (Kafka) | Kafka 消费延迟 | >100000 告警 |
| `lastCheckpointDuration` | 最近一次 CP 耗时 | >CP间隔的50% 告警 |
| `numberOfFailedCheckpoints` | 失败的 CP 次数 | >0 告警 |

**Prometheus + Grafana 配置**：

```yaml
# flink-conf.yaml
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporterFactory
metrics.reporter.prom.port: 9249
```

---

## 七、举一反三

### 7.1 与其他方案的对比

| 对比维度 | Flink → ES | Logstash → ES | Kafka Connect → ES | Spark Streaming → ES |
|---------|-----------|--------------|-------------------|---------------------|
| 实时性 | 毫秒~秒级 | 秒级 | 秒级 | 秒~分钟级 |
| 吞吐量 | 高（10万+ TPS） | 中（受限于 Logstash） | 中高 | 高 |
| Exactly-Once | ✅（Checkpoint + upsert） | ❌（At-Least-Once） | ❌（At-Least-Once） | 近似（需手动处理） |
| 数据转换能力 | 强（SQL + Java API） | 中（Filter 插件） | 弱（SMT） | 强（Spark API） |
| 运维复杂度 | 中（需 YARN 集群） | 低 | 低 | 高（需 Spark 集群） |
| 动态索引 | ✅ 原生支持 | ✅ 原生支持 | ✅ SMT 支持 | 需自行实现 |
| 适用场景 | 复杂实时 ETL | 简单日志采集 | 标准管道同步 | 批+微批场景 |

### 7.2 面试高频题

**Q1: Flink 写入 ES 如何保证 Exactly-Once 语义？**

> **A**: Flink 写入 ES 的 Exactly-Once 通过两个机制保证：
> 1. **Checkpoint 机制**：Flink Checkpoint 时会 flush 所有缓冲的 bulk 请求到 ES，确保 Checkpoint 完成时数据已持久化到 ES。如果 Checkpoint 失败，任务从上一个成功的 Checkpoint 恢复，重新消费 Kafka 数据。
> 2. **Upsert 幂等写入**：通过定义 PRIMARY KEY（对应 ES 的 `_id`），相同 `_id` 的文档会被覆盖而非追加。即使因故障恢复导致重复消费，写入的结果仍然是幂等的。
> 
> 注意：严格来说，ES Sink 不支持两阶段提交（2PC），所以不是真正的端到端 Exactly-Once，而是通过"At-Least-Once 投递 + 幂等写入"实现的"效果等价于 Exactly-Once"。

**Q2: Flink 写入 ES 时如何处理背压和批量写入优化？**

> **A**: 
> 1. **批量参数调优**：通过 `sink.bulk-flush.max-actions`、`max-size`、`interval` 三个维度控制 bulk 请求的大小和频率，减少 ES 的请求次数。
> 2. **背压传导**：当 ES 响应变慢时，Flink 的 bulk flush 会阻塞，自然产生背压传导到上游 Kafka Source，降低消费速率，防止 OOM。
> 3. **重试策略**：配置 `EXPONENTIAL` 退避重试，避免 ES 短暂过载时大量请求同时重试造成雪崩。
> 4. **Checkpoint 对齐**：Checkpoint 时强制 flush，如果 bulk 很大，可能导致 CP 超时，需要合理设置 bulk 参数和 CP 超时时间。

**Q3: Flink 写入 ES 的动态索引是如何实现的？有什么注意事项？**

> **A**: 
> 1. **实现方式**：在 SQL DDL 的 `index` 参数中使用 `{field_name}` 占位符，Flink 会在运行时将占位符替换为每条记录中该字段的实际值。例如 `index = 'logs_{dt}'`，如果 `dt` 字段值为 `2026-04-29`，则写入索引 `logs_2026-04-29`。
> 2. **注意事项**：
>    - 引用的字段必须是 STRING 类型
>    - 字段值不能为 null，否则索引名生成失败，建议用 COALESCE 兜底
>    - 建议提前创建 Index Template，否则依赖 ES 自动创建可能导致 mapping 不符合预期
>    - 按天分索引时，注意配合 ILM（Index Lifecycle Management）策略管理旧索引的删除/归档

**Q4: ES 6、7、8 在 Flink Connector 使用上有什么区别？**

> **A**: 
> - **ES 6**：必须指定 `document-type`（如 `_doc`），使用 `elasticsearch-6` connector
> - **ES 7**：`document-type` 可选（默认 `_doc`），使用 `elasticsearch-7` connector
> - **ES 8**：完全移除了 Type 概念，使用新版 `elasticsearch` connector（Flink 1.18+），默认走 HTTPS，需配置认证

### 7.3 思考题

1. **场景设计题**：如果 ES 集群需要升级从 7.x 到 8.x，Flink 作业如何做到不停机平滑迁移？请设计迁移方案。

2. **优化题**：某业务 Flink 写入 ES 的作业，发现 ES 集群 CPU 使用率持续 90%+，但 Flink 端显示 `numRecordsOutPerSecond` 远低于 `numRecordsInPerSecond`（消费跟不上生产），请分析可能的原因并给出优化方案。

3. **架构题**：电商大促期间，用户行为日志量是日常的 10 倍。如何设计 Flink → ES 链路的弹性扩缩容方案，使其在大促期间自动扩容，大促结束后自动缩容？

---

> 📝 **本教案配套资源**
> - ES Index Template 配置文件: `es-templates/user_behavior_template.json`
> - Flink SQL 脚本: `sql-scripts/kafka2es.sql`
> - DataStream JAR 工程: `java-projects/user-behavior-es/`
> - Grafana Dashboard 模板: `monitoring/flink-es-dashboard.json`
