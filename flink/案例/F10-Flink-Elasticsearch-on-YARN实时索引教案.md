# [教案] Flink on YARN — Elasticsearch 实时索引使用姿势

> 🎯 教学目标：掌握 Flink + Elasticsearch Connector 实现实时数据清洗与索引写入，支持 ES 6/7/8 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

### 1.1 典型业务场景

| 场景 | 描述 | 示例 |
|------|------|------|
| **实时搜索** | 数据变更实时索引到 ES | 商品上架/更新实时可搜 |
| **日志分析** | 日志流实时写入 ES + Kibana 可视化 | 应用日志、访问日志 |
| **实时监控** | 指标数据实时写入 ES | 业务指标、系统指标 |
| **用户画像** | 用户行为实时聚合写入 ES | 实时推荐、实时标签 |
| **CDC 索引** | MySQL CDC → Flink → ES | 数据库变更实时同步到搜索引擎 |

### 1.2 为什么选 Flink + ES？

- **流式写入**：数据到达即写入 ES，秒级可搜
- **批量写入**：内置 Bulk API 支持，高吞吐
- **幂等写入**：基于文档 ID 的 Upsert，天然去重
- **动态索引**：支持按时间动态路由到不同索引
- **Flink SQL 友好**：DDL 声明即可写入，无需编码

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Flink | 1.17.x / 1.18.x | 推荐 1.17+ |
| Elasticsearch | 6.x / 7.x / 8.x | 推荐 7.x+ |
| Hadoop/YARN | 3.1+ | Flink on YARN |
| Kafka | 2.x / 3.x | 实时数据源 |
| Java | JDK 8 / JDK 11 | Flink 运行时 |

### 2.2 环境准备命令

```bash
# ============================================
# 1. 设置环境变量
# ============================================
export FLINK_HOME=/opt/flink-1.17.2
export HADOOP_HOME=/opt/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop

# ============================================
# 2. 下载必需 JAR 包
# ============================================
cd $FLINK_HOME/lib

# Elasticsearch 7 Connector（根据 ES 版本选择）
# ES 7.x:
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-elasticsearch7/1.17.2/flink-sql-connector-elasticsearch7-1.17.2.jar

# ES 6.x（如果用旧版 ES）:
# wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-elasticsearch6/1.17.2/flink-sql-connector-elasticsearch6-1.17.2.jar

# Flink Kafka Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar

# ============================================
# 3. 验证 ES 连通性
# ============================================
# 检查 ES 集群状态
curl -X GET "http://es01:9200/_cluster/health?pretty"

# 检查索引列表
curl -X GET "http://es01:9200/_cat/indices?v"

# ============================================
# 4. 创建测试索引模板（可选）
# ============================================
curl -X PUT "http://es01:9200/_template/order_template" -H 'Content-Type: application/json' -d '
{
  "index_patterns": ["orders_*"],
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1,
    "refresh_interval": "5s"
  },
  "mappings": {
    "properties": {
      "order_id": {"type": "keyword"},
      "user_id": {"type": "keyword"},
      "product_name": {"type": "text", "analyzer": "standard"},
      "amount": {"type": "double"},
      "status": {"type": "keyword"},
      "create_time": {"type": "date", "format": "yyyy-MM-dd HH:mm:ss||epoch_millis"},
      "update_time": {"type": "date", "format": "yyyy-MM-dd HH:mm:ss||epoch_millis"}
    }
  }
}'

# ============================================
# 5. 准备 Kafka 测试 Topic
# ============================================
kafka-topics.sh --create \
  --bootstrap-server kafka01:9092 \
  --topic user_logs \
  --partitions 6 \
  --replication-factor 2

# 写入测试数据
for i in $(seq 1 10); do
echo "{\"log_id\":\"LOG$(printf '%04d' $i)\",\"user_id\":\"U00$((i%5+1))\",\"action\":\"click\",\"page\":\"/product/$i\",\"ts\":$(date +%s)000}" | \
  kafka-console-producer.sh --bootstrap-server kafka01:9092 --topic user_logs
done
```

---

## 三、核心使用方式

### 3.1 Flink SQL — ES Sink 表定义

```sql
-- ============================================
-- Elasticsearch 7.x Sink 表
-- ============================================
CREATE TABLE es_orders (
    order_id     STRING,
    user_id      STRING,
    product_name STRING,
    amount       DOUBLE,
    status       STRING,
    create_time  STRING,
    update_time  STRING,
    PRIMARY KEY (order_id) NOT ENFORCED       -- 有主键 → Upsert 模式
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200;http://es02:9200;http://es03:9200',
    'index' = 'orders',
    -- 批量写入配置
    'sink.bulk-flush.max-actions' = '1000',   -- 每批最大文档数
    'sink.bulk-flush.max-size' = '10mb',      -- 每批最大数据量
    'sink.bulk-flush.interval' = '1s',        -- 定时 flush 间隔
    -- 重试配置
    'sink.bulk-flush.backoff.strategy' = 'EXPONENTIAL',
    'sink.bulk-flush.backoff.max-retries' = '3',
    'sink.bulk-flush.backoff.delay' = '1000', -- 初始重试延迟 1s
    -- 连接配置
    'connection.path-prefix' = '',
    'format' = 'json'
);
```

### 3.2 动态索引（按日期分索引）

```sql
-- ============================================
-- 动态索引：按天分索引，如 orders_2026-04-29
-- ============================================
CREATE TABLE es_orders_daily (
    order_id     STRING,
    user_id      STRING,
    product_name STRING,
    amount       DOUBLE,
    status       STRING,
    create_time  STRING,
    dt           STRING,                       -- 用于动态索引
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200',
    'index' = 'orders_{dt}',                   -- 动态索引，{dt} 从字段取值
    'sink.bulk-flush.max-actions' = '1000',
    'sink.bulk-flush.interval' = '1s',
    'format' = 'json'
);

-- 写入时自动路由到 orders_2026-04-29 等索引
INSERT INTO es_orders_daily
SELECT
    order_id, user_id, product_name, amount, status, create_time,
    DATE_FORMAT(TO_TIMESTAMP(create_time), 'yyyy-MM-dd') AS dt
FROM kafka_orders;
```

### 3.3 参数详解表 — Elasticsearch Connector

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `connector` | ✅ | - | `elasticsearch-6` / `elasticsearch-7` |
| `hosts` | ✅ | - | ES 节点地址，分号分隔 |
| `index` | ✅ | - | 索引名（支持动态 `{field_name}`） |
| `document-id.key-delimiter` | ❌ | `_` | 复合主键分隔符 |
| `sink.bulk-flush.max-actions` | ❌ | `1000` | 每批最大文档数 |
| `sink.bulk-flush.max-size` | ❌ | `2mb` | 每批最大数据量 |
| `sink.bulk-flush.interval` | ❌ | `1s` | 定时 flush 间隔 |
| `sink.bulk-flush.backoff.strategy` | ❌ | `DISABLED` | 重试策略：CONSTANT / EXPONENTIAL |
| `sink.bulk-flush.backoff.max-retries` | ❌ | `8` | 最大重试次数 |
| `sink.bulk-flush.backoff.delay` | ❌ | `50` | 初始重试延迟（ms） |
| `sink.parallelism` | ❌ | - | Sink 并行度 |
| `connection.path-prefix` | ❌ | - | URL 前缀（用于反向代理） |
| `format` | ❌ | `json` | 数据格式 |

### 3.4 写入模式对比

| 模式 | 触发条件 | ES 操作 | 说明 |
|------|---------|--------|------|
| **Append** | DDL 无 PRIMARY KEY | Index（新增） | 每条记录生成新文档，可能重复 |
| **Upsert** | DDL 有 PRIMARY KEY | Index（覆盖） | 相同 ID 覆盖写入，天然幂等 |
| **Delete** | CDC -D 消息 | Delete | 配合 CDC 使用，删除文档 |

---

## 四、完整实战示例

### 4.1 实战场景：Kafka → Flink 实时清洗 → ES

#### 4.1.1 完整 SQL 作业

创建文件 `kafka_to_es_job.sql`：

```sql
-- ============================================================
-- Kafka 日志流 → Flink 清洗 → Elasticsearch
-- ============================================================

-- 1. Kafka Source（用户行为日志）
CREATE TABLE kafka_user_logs (
    log_id      STRING,
    user_id     STRING,
    action      STRING,       -- click / view / buy / search
    page        STRING,
    ip          STRING,
    user_agent  STRING,
    ts          BIGINT,
    event_time AS TO_TIMESTAMP_LTZ(ts, 3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_logs',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-es-writer',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- 2. Elasticsearch Sink（清洗后的日志）
CREATE TABLE es_user_logs (
    log_id      STRING,
    user_id     STRING,
    action      STRING,
    page        STRING,
    ip          STRING,
    device_type STRING,       -- 从 user_agent 提取
    event_time  TIMESTAMP(3),
    dt          STRING,
    PRIMARY KEY (log_id) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200;http://es02:9200;http://es03:9200',
    'index' = 'user_logs_{dt}',              -- 按天分索引
    'sink.bulk-flush.max-actions' = '2000',
    'sink.bulk-flush.max-size' = '10mb',
    'sink.bulk-flush.interval' = '2s',
    'sink.bulk-flush.backoff.strategy' = 'EXPONENTIAL',
    'sink.bulk-flush.backoff.max-retries' = '5',
    'sink.bulk-flush.backoff.delay' = '1000',
    'format' = 'json'
);

-- 3. 数据清洗 + 写入 ES
INSERT INTO es_user_logs
SELECT
    log_id,
    user_id,
    action,
    page,
    ip,
    -- 简单设备类型提取
    CASE
        WHEN user_agent LIKE '%Mobile%' THEN 'mobile'
        WHEN user_agent LIKE '%Tablet%' THEN 'tablet'
        ELSE 'desktop'
    END AS device_type,
    event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt
FROM kafka_user_logs
WHERE action IS NOT NULL
  AND user_id IS NOT NULL;
```

#### 4.1.2 聚合后写入 ES（实时指标）

```sql
-- ============================================================
-- 实时聚合：每分钟 PV/UV 统计 → ES
-- ============================================================

CREATE TABLE es_page_metrics (
    window_start TIMESTAMP(3),
    window_end   TIMESTAMP(3),
    page         STRING,
    pv           BIGINT,
    uv           BIGINT,
    dt           STRING,
    PRIMARY KEY (page, window_start) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200',
    'index' = 'page_metrics_{dt}',
    'sink.bulk-flush.max-actions' = '500',
    'sink.bulk-flush.interval' = '5s',
    'format' = 'json'
);

INSERT INTO es_page_metrics
SELECT
    TUMBLE_START(event_time, INTERVAL '1' MINUTE) AS window_start,
    TUMBLE_END(event_time, INTERVAL '1' MINUTE) AS window_end,
    page,
    COUNT(*) AS pv,
    COUNT(DISTINCT user_id) AS uv,
    DATE_FORMAT(TUMBLE_START(event_time, INTERVAL '1' MINUTE), 'yyyy-MM-dd') AS dt
FROM kafka_user_logs
GROUP BY
    TUMBLE(event_time, INTERVAL '1' MINUTE),
    page;
```

#### 4.1.3 DataStream API 写入 ES

```java
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.connector.elasticsearch.sink.Elasticsearch7SinkBuilder;
import org.apache.flink.connector.elasticsearch.sink.ElasticsearchSink;
import org.apache.flink.connector.elasticsearch.sink.FlushBackoffType;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.http.HttpHost;
import org.elasticsearch.action.index.IndexRequest;
import org.elasticsearch.client.Requests;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.HashMap;
import java.util.Map;

/**
 * DataStream API: Kafka → 清洗 → ES
 */
public class KafkaToEsJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);

        // 1. Kafka Source
        DataStream<String> kafkaStream = env.fromSource(/* Kafka Source 配置 */);

        // 2. 数据清洗
        DataStream<Map<String, Object>> cleanedStream = kafkaStream
                .map(new LogCleanFunction())
                .filter(map -> map != null && map.containsKey("user_id"));

        // 3. ES Sink（Flink 1.17+ 新 API）
        ElasticsearchSink<Map<String, Object>> esSink = new Elasticsearch7SinkBuilder<Map<String, Object>>()
                .setHosts(
                    new HttpHost("es01", 9200, "http"),
                    new HttpHost("es02", 9200, "http"),
                    new HttpHost("es03", 9200, "http")
                )
                .setEmitter((element, context, indexer) -> {
                    String docId = (String) element.get("log_id");
                    String dt = (String) element.get("dt");
                    String indexName = "user_logs_" + dt;

                    IndexRequest request = Requests.indexRequest()
                            .index(indexName)
                            .id(docId)
                            .source(element);
                    indexer.add(request);
                })
                .setBulkFlushMaxActions(2000)
                .setBulkFlushMaxSizeMb(10)
                .setBulkFlushInterval(2000)
                .setBulkFlushBackoffStrategy(FlushBackoffType.EXPONENTIAL, 5, 1000)
                .build();

        cleanedStream.sinkTo(esSink);

        env.execute("Kafka-to-ES-Job");
    }

    public static class LogCleanFunction implements MapFunction<String, Map<String, Object>> {
        private transient ObjectMapper mapper;

        @Override
        public Map<String, Object> map(String value) throws Exception {
            if (mapper == null) mapper = new ObjectMapper();
            try {
                JsonNode node = mapper.readTree(value);
                Map<String, Object> result = new HashMap<>();
                result.put("log_id", node.get("log_id").asText());
                result.put("user_id", node.get("user_id").asText());
                result.put("action", node.get("action").asText());
                result.put("page", node.get("page").asText());
                result.put("event_time", node.get("ts").asLong());
                result.put("dt", java.time.LocalDate.now().toString());
                return result;
            } catch (Exception e) {
                return null;  // 过滤脏数据
            }
        }
    }
}
```

#### 4.1.4 Application Mode on YARN 提交命令

```bash
# ============================================================
# Application Mode on YARN
# ============================================================
export HADOOP_CLASSPATH=$(hadoop classpath)

$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=2 \
  -Dparallelism.default=4 \
  -Dyarn.application.name="Flink-Kafka-to-ES" \
  -Dyarn.application.queue=production \
  -Dexecution.checkpointing.interval=60000 \
  -Dexecution.checkpointing.mode=EXACTLY_ONCE \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kafka-es \
  -c com.example.KafkaToEsJob \
  /path/to/flink-es-job.jar

# SQL Client 快速验证
$FLINK_HOME/bin/sql-client.sh embedded \
  -l $FLINK_HOME/lib \
  -f kafka_to_es_job.sql
```

#### 4.1.5 验证结果

```bash
# ============================================
# 验证 ES 索引数据
# ============================================

# 1. 查看索引列表
curl -s "http://es01:9200/_cat/indices/user_logs_*?v"

# 预期输出:
# health status index               docs.count store.size
# green  open   user_logs_2026-04-29      1234     2.3mb

# 2. 查询索引数据
curl -s "http://es01:9200/user_logs_2026-04-29/_search?pretty&size=3"

# 3. 按字段搜索
curl -s "http://es01:9200/user_logs_2026-04-29/_search?pretty" -H 'Content-Type: application/json' -d '
{
  "query": {
    "term": { "user_id": "U001" }
  },
  "size": 5
}'

# 4. 聚合查询
curl -s "http://es01:9200/user_logs_2026-04-29/_search?pretty" -H 'Content-Type: application/json' -d '
{
  "size": 0,
  "aggs": {
    "actions": {
      "terms": { "field": "action" }
    }
  }
}'

# 5. 检查文档数量增长（实时性验证）
watch -n 5 'curl -s "http://es01:9200/user_logs_2026-04-29/_count" | python -m json.tool'
```

### 4.2 实战场景：MySQL CDC → Flink → ES（数据库同步到搜索）

```sql
-- ============================================================
-- MySQL 商品表变更实时同步到 ES（支持新增/修改/删除）
-- ============================================================

-- MySQL CDC Source
CREATE TABLE mysql_products (
    product_id   BIGINT,
    name         STRING,
    category     STRING,
    price        DECIMAL(10,2),
    description  STRING,
    status       TINYINT,      -- 1:上架 0:下架
    update_time  TIMESTAMP(3),
    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql-host',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'Flink@CDC2026',
    'database-name' = 'shop',
    'table-name' = 'products',
    'scan.startup.mode' = 'initial'
);

-- ES Sink（Upsert + Delete）
CREATE TABLE es_products (
    product_id   BIGINT,
    name         STRING,
    category     STRING,
    price        DOUBLE,
    description  STRING,
    status       INT,
    update_time  STRING,
    PRIMARY KEY (product_id) NOT ENFORCED      -- 有 PK → 支持 Upsert & Delete
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200',
    'index' = 'products',
    'sink.bulk-flush.max-actions' = '500',
    'sink.bulk-flush.interval' = '1s',
    'format' = 'json'
);

-- CDC 同步（INSERT/UPDATE 写入，DELETE 自动删除 ES 文档）
INSERT INTO es_products
SELECT
    product_id,
    name,
    category,
    CAST(price AS DOUBLE),
    description,
    CAST(status AS INT),
    CAST(update_time AS STRING)
FROM mysql_products;
```

---

## 五、常见问题与排障

### 5.1 问题排查速查表

| 问题现象 | 可能原因 | 解决方案 |
|---------|---------|---------|
| `ConnectionClosedException` | ES 节点不可达 | 检查网络，验证 `curl ES_URL` |
| `ElasticsearchException[Bulk]` | 文档格式不匹配 mapping | 检查字段类型是否一致 |
| 写入延迟高 | bulk 参数过小 | 增大 `max-actions` 和 `max-size` |
| ES 磁盘写满 | 索引无生命周期管理 | 配置 ILM 策略或定期删除旧索引 |
| 文档 ID 冲突 | 主键设计不唯一 | 确保 PRIMARY KEY 字段全局唯一 |
| 写入被拒绝（429） | ES 写入队列满 | 增大 ES `thread_pool.write.queue_size` |
| `MapperParsingException` | 动态 mapping 类型推断错误 | 提前创建 mapping 或 index template |
| Checkpoint 失败 | ES 重试耗时过长 | 调整 backoff 参数 |

### 5.2 ES 索引生命周期管理

```bash
# 创建 ILM 策略（自动管理索引生命周期）
curl -X PUT "http://es01:9200/_ilm/policy/logs_policy" -H 'Content-Type: application/json' -d '
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_size": "50gb",
            "max_age": "1d"
          }
        }
      },
      "warm": {
        "min_age": "3d",
        "actions": {
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": { "delete": {} }
      }
    }
  }
}'
```

---

## 六、生产最佳实践

### 6.1 资源配置推荐

| 场景 | JM 内存 | TM 内存 | 并行度 | bulk.max-actions | bulk.interval |
|------|---------|---------|--------|-----------------|--------------|
| 小流量（< 1K TPS） | 1G | 2G | 2 | 500 | 2s |
| 中流量（1K-10K TPS） | 2G | 4G | 4 | 2000 | 1s |
| 大流量（10K-100K TPS） | 2G | 8G | 8 | 5000 | 500ms |
| 超大流量（> 100K TPS） | 4G | 16G | 16 | 10000 | 500ms |

### 6.2 Bulk 写入调优

```sql
-- 高吞吐场景推荐配置
CREATE TABLE es_high_throughput (
    ...
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200;http://es02:9200;http://es03:9200',
    'index' = 'high_throughput_index',
    -- Bulk 配置（三个条件任一满足即 flush）
    'sink.bulk-flush.max-actions' = '5000',       -- 5000 条
    'sink.bulk-flush.max-size' = '20mb',          -- 20MB
    'sink.bulk-flush.interval' = '500',           -- 500ms
    -- 重试策略（ES 偶尔 429 时自动重试）
    'sink.bulk-flush.backoff.strategy' = 'EXPONENTIAL',
    'sink.bulk-flush.backoff.max-retries' = '5',
    'sink.bulk-flush.backoff.delay' = '1000',     -- 初始 1s，指数退避
    -- 连接配置
    'connection.request-timeout' = '60000',
    'connection.timeout' = '10000',
    'socket.timeout' = '60000',
    'format' = 'json'
);
```

### 6.3 动态索引命名策略

| 策略 | 示例 | 适用场景 |
|------|------|---------|
| **按天** | `logs_{dt}` → `logs_2026-04-29` | 日志类，按天查询 |
| **按月** | `metrics_{ym}` → `metrics_2026-04` | 指标类，长期保留 |
| **按业务** | `orders_{region}` → `orders_cn` | 多租户/多区域 |
| **固定索引** | `products` | 全量数据，频繁更新 |

### 6.4 ES 端优化

```bash
# ES 写入性能优化建议
# 1. 适当增大 refresh_interval（默认 1s，可改为 5s-30s）
curl -X PUT "http://es01:9200/user_logs_*/_settings" -H 'Content-Type: application/json' -d '
{"index": {"refresh_interval": "5s"}}'

# 2. 增大 translog flush 间隔
curl -X PUT "http://es01:9200/user_logs_*/_settings" -H 'Content-Type: application/json' -d '
{"index": {"translog": {"sync_interval": "5s", "durability": "async"}}}'

# 3. 增大写入线程队列
# elasticsearch.yml:
# thread_pool.write.queue_size: 2000

# 4. 关闭不需要的副本（批量导入时）
curl -X PUT "http://es01:9200/user_logs_*/_settings" -H 'Content-Type: application/json' -d '
{"index": {"number_of_replicas": 0}}'
# 导入完成后恢复副本
```

### 6.5 故障重试与幂等性

```
幂等写入机制：

1. 有 PRIMARY KEY 的 Flink 表：
   → ES 操作为 Index（带 _id）
   → 相同 _id 的文档会被覆盖（天然幂等）
   → Flink 重启后重复写入不会产生重复数据

2. 无 PRIMARY KEY 的 Flink 表：
   → ES 操作为 Index（自动生成 _id）
   → 重启可能产生重复文档
   → 建议始终声明 PRIMARY KEY

3. 重试策略：
   → ES 返回 429 (Too Many Requests) 时自动退避重试
   → 配置 EXPONENTIAL 退避：1s → 2s → 4s → 8s → 16s
   → 超过 max-retries 后抛出异常，触发 Flink 容错机制
```

---

## 七、举一反三

### 7.1 对比：直接写 ES vs 经过 Kafka 再写 ES

| 维度 | Flink → ES（直接） | Flink → Kafka → Logstash → ES |
|------|-------------------|-------------------------------|
| **延迟** | 低（秒级） | 较高（可能分钟级） |
| **吞吐** | 高（Bulk 优化） | 较高（Logstash 有瓶颈） |
| **运维** | 简单（一个组件） | 复杂（多组件） |
| **灵活性** | 一般 | 高（Kafka 可多消费者） |
| **数据缓冲** | 无（ES 不可用时丢数据或阻塞） | 有（Kafka 缓冲） |

### 7.2 面试高频题

**Q1: Flink 写 ES 如何保证不丢数据？**

> 通过 Checkpoint + 重试机制。Flink 的 ES Connector 在 Checkpoint 时会 flush 所有 pending 的 bulk 请求。如果 ES 不可用，退避重试；重试超限后触发 Flink 故障恢复从上次 Checkpoint 重新消费。配合 Upsert 幂等性，保证 At-Least-Once。

**Q2: 动态索引 `{field}` 的原理是什么？**

> Flink ES Connector 在写入每条记录时，从 record 中提取指定字段的值，替换 index 配置中的 `{field}` 占位符，得到实际的索引名。例如 `index = 'logs_{dt}'`，如果 dt 字段值为 `2026-04-29`，则写入 `logs_2026-04-29` 索引。

**Q3: ES 写入被拒绝（429）时 Flink 如何处理？**

> 配置了 backoff 策略后，Flink 会自动退避重试。EXPONENTIAL 模式下，延迟呈指数增长（如 1s, 2s, 4s...）。达到 max-retries 后抛出异常，触发 Flink 的 restart strategy 进行作业级重启。

**Q4: 为什么建议有 PRIMARY KEY？**

> 有 PK 时：1) 写入为 Upsert（幂等），重启不产生重复；2) 支持 CDC DELETE 语义（删除 ES 文档）；3) ES 文档 ID 可控，便于调试和查询。无 PK 时 ES 自动生成 ID，重启会重复写入。

### 7.3 思考题

1. **索引策略**：某业务每天产生 1 亿条日志，保留 90 天。你会如何设计索引策略和 ILM？
2. **写入抖动**：ES 集群在 GC 期间写入延迟飙升，导致 Flink 反压。你会如何配置 backoff 参数？
3. **Schema 变更**：ES 索引 mapping 已有 `amount` 为 `long` 类型，但业务要改为 `double`。如何处理？
4. **数据一致性**：Flink 作业重启后，如何验证 ES 中的数据与 Kafka 中的数据一致？

---

> 📝 **教案小结**：Flink + ES 的核心要点：**有 PRIMARY KEY 即 Upsert 幂等写入；Bulk 参数决定吞吐与延迟的平衡；动态索引实现按时间/维度分索引；backoff 策略应对 ES 抖动**。
