# [教案] Flink on YARN — Elasticsearch 实时索引使用姿势

> 🎯 教学目标：掌握 Flink + Elasticsearch Connector 实现实时数据清洗与索引写入，支持 ES 6/7/8 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

| 场景 | 描述 | 示例 |
|------|------|------|
| **实时搜索** | 变更实时索引到 ES | 商品上下架实时可搜 |
| **日志分析** | 日志流实时写入 ES | Kibana 可视化 |
| **CDC 索引** | MySQL CDC → ES | 数据库同步搜索引擎 |
| **实时指标** | 聚合写入 ES | 实时监控大屏 |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.17+ | 推荐 |
| Elasticsearch | 7.x / 8.x | 推荐 7+ |
| Kafka | 2.x / 3.x | 数据源 |

### 2.2 环境准备

```bash
export FLINK_HOME=/opt/flink-1.17.2
export HADOOP_CLASSPATH=$(hadoop classpath)

cd $FLINK_HOME/lib
# ES 7 Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-elasticsearch7/1.17.2/flink-sql-connector-elasticsearch7-1.17.2.jar
# Kafka Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar

# 验证 ES
curl "http://es01:9200/_cluster/health?pretty"
```

---

## 三、核心使用方式

### 3.1 ES Sink DDL

```sql
CREATE TABLE es_orders (
    order_id STRING,
    user_id STRING,
    amount DOUBLE,
    status STRING,
    create_time STRING,
    PRIMARY KEY (order_id) NOT ENFORCED    -- Upsert 模式
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200;http://es02:9200',
    'index' = 'orders',
    'sink.bulk-flush.max-actions' = '1000',
    'sink.bulk-flush.max-size' = '10mb',
    'sink.bulk-flush.interval' = '1s',
    'sink.bulk-flush.backoff.strategy' = 'EXPONENTIAL',
    'sink.bulk-flush.backoff.max-retries' = '5',
    'sink.bulk-flush.backoff.delay' = '1000',
    'format' = 'json'
);
```

### 3.2 动态索引

```sql
CREATE TABLE es_logs (
    log_id STRING, user_id STRING, action STRING,
    event_time TIMESTAMP(3), dt STRING,
    PRIMARY KEY (log_id) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200',
    'index' = 'logs_{dt}',            -- 按天分索引
    'sink.bulk-flush.max-actions' = '2000',
    'sink.bulk-flush.interval' = '1s',
    'format' = 'json'
);
```

### 3.3 参数详解表

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `connector` | ✅ | - | `elasticsearch-7` |
| `hosts` | ✅ | - | ES 节点，分号分隔 |
| `index` | ✅ | - | 索引名（支持 `{field}`） |
| `sink.bulk-flush.max-actions` | ❌ | `1000` | 每批最大文档数 |
| `sink.bulk-flush.max-size` | ❌ | `2mb` | 每批最大数据量 |
| `sink.bulk-flush.interval` | ❌ | `1s` | 定时 flush |
| `sink.bulk-flush.backoff.strategy` | ❌ | `DISABLED` | 重试：EXPONENTIAL |
| `sink.bulk-flush.backoff.max-retries` | ❌ | `8` | 最大重试 |

---

## 四、完整实战示例

### 4.1 Kafka → 清洗 → ES

```sql
-- Kafka Source
CREATE TABLE kafka_logs (
    log_id STRING, user_id STRING, action STRING,
    page STRING, ts BIGINT,
    event_time AS TO_TIMESTAMP_LTZ(ts, 3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_logs',
    'properties.bootstrap.servers' = 'kafka01:9092',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json'
);

-- ES Sink
CREATE TABLE es_user_logs (
    log_id STRING, user_id STRING, action STRING,
    page STRING, event_time TIMESTAMP(3), dt STRING,
    PRIMARY KEY (log_id) NOT ENFORCED
) WITH (
    'connector' = 'elasticsearch-7',
    'hosts' = 'http://es01:9200',
    'index' = 'user_logs_{dt}',
    'sink.bulk-flush.max-actions' = '2000',
    'sink.bulk-flush.interval' = '1s',
    'format' = 'json'
);

-- 清洗写入
INSERT INTO es_user_logs
SELECT log_id, user_id, action, page, event_time,
       DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt
FROM kafka_logs
WHERE user_id IS NOT NULL;
```

### 4.2 Application Mode 提交

```bash
$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dparallelism.default=4 \
  -Dyarn.application.name="Flink-Kafka-to-ES" \
  -Dexecution.checkpointing.interval=60000 \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/es \
  -c com.example.KafkaToEsJob /path/to/job.jar
```

### 4.3 验证

```bash
curl "http://es01:9200/user_logs_2026-04-29/_count"
curl "http://es01:9200/user_logs_2026-04-29/_search?pretty&size=3"
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决 |
|------|------|------|
| 429 Too Many Requests | ES 写入队列满 | 增大 queue_size + backoff |
| Mapping 冲突 | 字段类型不一致 | 提前创建 template |
| 延迟高 | bulk 参数过小 | 增大 max-actions |
| 重复文档 | 无 PRIMARY KEY | 声明 PK 开启 Upsert |

---

## 六、生产最佳实践

```sql
-- 高吞吐配置
'sink.bulk-flush.max-actions' = '5000',
'sink.bulk-flush.max-size' = '20mb',
'sink.bulk-flush.interval' = '500',
'sink.bulk-flush.backoff.strategy' = 'EXPONENTIAL',
'sink.bulk-flush.backoff.max-retries' = '5',
'sink.bulk-flush.backoff.delay' = '1000'
```

```bash
# ES 端优化
curl -X PUT "es01:9200/index/_settings" -d '{"index":{"refresh_interval":"5s"}}'
```

---

## 七、举一反三

**Q: 如何保证不丢数据？**
> Checkpoint + Upsert 幂等。重启后从 Checkpoint 重新消费，相同 _id 覆盖写入。

**Q: 动态索引原理？**
> 运行时从记录字段取值替换 `{field}` 占位符。

**Q: 有 PK vs 无 PK？**
> 有 PK → Upsert 幂等 + 支持 Delete；无 PK → Append 可能重复。

---

> 📝 **教案小结**：核心要点 — PRIMARY KEY 决定幂等性，Bulk 参数决定吞吐，动态索引按时间分片，backoff 应对 ES 抖动。
