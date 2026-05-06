# Spark + Kafka 集成实战教案 — Structured Streaming 消费 Kafka

> **教学目标**：学完本课后，你能用 Spark Structured Streaming 从 Kafka 实时消费数据，进行 ETL 处理后写入 Iceberg/Parquet/Console，并理解 exactly-once 的实现原理。
>
> **前置条件**：Spark 3.3+ / Kafka 2.8+

---

## 一、课前故事 — 为什么 Spark + Kafka？

想象一个**自来水处理厂**：
- **Kafka** = 河流（源源不断的水流入）
- **Spark Streaming** = 水处理厂（过滤、净化、检测）
- **Sink（Iceberg/HDFS）** = 储水池（处理后的干净水存起来）

Spark Structured Streaming 就是这个水处理厂的**自动化控制系统**——它能持续从 Kafka 取水、处理、存储，且保证**每滴水只处理一次**（exactly-once）。

---

## 二、环境配置

### 2.1 依赖

```bash
# spark-submit 添加 Kafka 包
spark-submit \
  --packages org.apache.spark:spark-sql-kafka-0-10_2.12:3.3.4 \
  your_app.py
```

### 2.2 基础读取模板

```python
# Python / PySpark
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("Kafka-Consumer") \
    .config("spark.sql.streaming.checkpointLocation", "/checkpoint/kafka_app") \
    .getOrCreate()

# 从 Kafka 读取
df = spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "broker1:9092,broker2:9092,broker3:9092") \
    .option("subscribe", "orders_topic") \
    .option("startingOffsets", "earliest") \
    .option("failOnDataLoss", "false") \
    .load()
```

---

## 三、读取 Kafka — 完整参数详解

### 3.1 三种订阅方式

```python
# 方式1：订阅固定 Topic
.option("subscribe", "topic1,topic2")

# 方式2：正则匹配 Topic
.option("subscribePattern", "order_.*")

# 方式3：指定 Topic+Partition+Offset（精确控制）
.option("assign", '{"topic1": [0,1,2], "topic2": [0]}')
```

### 3.2 起始偏移量

```python
# 从最早开始（全量消费）
.option("startingOffsets", "earliest")

# 从最新开始（只消费新数据）
.option("startingOffsets", "latest")

# 从指定 offset 开始
.option("startingOffsets", '{"topic1": {"0": 100, "1": 200}}')

# 从指定时间戳开始
.option("startingOffsetsByTimestamp", '{"topic1": {"0": 1680000000000}}')
```

### 3.3 Kafka 消息结构

```
读取后的 DataFrame Schema:
root
 |-- key: binary        ← 消息 Key（需要 CAST）
 |-- value: binary      ← 消息 Value（需要 CAST）
 |-- topic: string      ← 来源 Topic
 |-- partition: integer ← 来源 Partition
 |-- offset: long       ← 消息 Offset
 |-- timestamp: timestamp ← Kafka 时间戳
 |-- timestampType: integer
```

---

## 四、数据解析 — 从 binary 到结构化

### 4.1 JSON 消息解析（最常见）

```python
from pyspark.sql.functions import from_json, col
from pyspark.sql.types import StructType, StringType, LongType, DoubleType, TimestampType

# 定义消息 Schema
order_schema = StructType() \
    .add("order_id", LongType()) \
    .add("user_id", LongType()) \
    .add("product", StringType()) \
    .add("amount", DoubleType()) \
    .add("order_time", TimestampType()) \
    .add("status", StringType())

# 解析 JSON
orders_df = df \
    .selectExpr("CAST(value AS STRING) as json_str") \
    .select(from_json(col("json_str"), order_schema).alias("data")) \
    .select("data.*")
```

### 4.2 Avro 消息解析（Schema Registry）

```python
from pyspark.sql.avro.functions import from_avro

# 使用 Schema Registry
orders_df = df.select(
    from_avro(col("value"), schema_registry_url, "orders-value").alias("data")
).select("data.*")
```

### 4.3 CSV / 简单文本

```python
# CSV 格式
orders_df = df \
    .selectExpr("CAST(value AS STRING)") \
    .selectExpr("split(value, ',')[0] as order_id",
                "split(value, ',')[1] as product",
                "CAST(split(value, ',')[2] AS DOUBLE) as amount")
```

---

## 五、写出数据 — 三种 Sink

### 5.1 写入 Console（调试用）

```python
query = orders_df.writeStream \
    .outputMode("append") \
    .format("console") \
    .option("truncate", "false") \
    .trigger(processingTime="10 seconds") \
    .start()

query.awaitTermination()
```

### 5.2 写入 Parquet/HDFS

```python
query = orders_df.writeStream \
    .outputMode("append") \
    .format("parquet") \
    .option("path", "hdfs:///warehouse/orders_streaming/") \
    .option("checkpointLocation", "/checkpoint/orders_parquet") \
    .partitionBy("status") \
    .trigger(processingTime="1 minute") \
    .start()
```

### 5.3 写入 Iceberg（推荐！）

```python
query = orders_df.writeStream \
    .outputMode("append") \
    .format("iceberg") \
    .option("checkpointLocation", "/checkpoint/orders_iceberg") \
    .option("fanout-enabled", "true") \
    .trigger(processingTime="1 minute") \
    .toTable("iceberg.my_db.orders_realtime")
```

---

## 六、核心概念 — Trigger、OutputMode、Checkpoint

### 6.1 Trigger（触发频率）

```python
# 固定间隔微批（最常用）
.trigger(processingTime="30 seconds")

# 一次性执行（类似批处理）
.trigger(once=True)

# 可用时立即处理（最低延迟，资源消耗最大）
.trigger(availableNow=True)

# 连续处理（实验性，毫秒级延迟）
.trigger(continuous="1 second")
```

### 6.2 OutputMode（输出模式）

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| `append` | 只输出新增行 | INSERT 场景 |
| `update` | 只输出变化的行 | Aggregation 场景 |
| `complete` | 输出全部结果 | 全量聚合结果 |

### 6.3 Checkpoint（检查点 — exactly-once 的关键！）

```
Checkpoint 目录结构：
/checkpoint/my_app/
├── metadata        ← 查询元数据
├── offsets/        ← 每个微批消费的 Kafka offset
│   ├── 0          ← 第0批的 offset 范围
│   ├── 1
│   └── ...
├── commits/        ← 每个微批的提交确认
│   ├── 0
│   └── ...
└── state/          ← 有状态操作的 state（如 aggregation）

Exactly-Once 保证原理：
  ① 开始微批前，记录要消费的 offset 范围到 checkpoint
  ② 处理数据
  ③ 写出结果
  ④ 提交确认到 checkpoint
  
  如果步骤③失败重试，会从 checkpoint 恢复 offset，重新处理
  如果步骤④失败，下次启动时发现未提交，重新处理该批次
  → 每条消息恰好处理一次
```

---

## 七、完整实战示例 — 实时订单统计

```python
from pyspark.sql import SparkSession
from pyspark.sql.functions import *
from pyspark.sql.types import *

spark = SparkSession.builder.appName("RealTimeOrderStats").getOrCreate()

# 1. 读取 Kafka
raw_df = spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "kafka:9092") \
    .option("subscribe", "orders") \
    .option("startingOffsets", "latest") \
    .load()

# 2. 解析 JSON
schema = StructType([
    StructField("order_id", LongType()),
    StructField("user_id", LongType()),
    StructField("amount", DoubleType()),
    StructField("order_time", TimestampType()),
    StructField("status", StringType())
])

orders = raw_df \
    .selectExpr("CAST(value AS STRING)") \
    .select(from_json(col("value"), schema).alias("o")) \
    .select("o.*") \
    .withWatermark("order_time", "5 minutes")  # 水位线：允许5分钟延迟

# 3. 10分钟窗口统计
stats = orders \
    .groupBy(window("order_time", "10 minutes"), "status") \
    .agg(
        count("*").alias("order_count"),
        sum("amount").alias("total_amount"),
        avg("amount").alias("avg_amount")
    )

# 4. 写入 Console 调试
query = stats.writeStream \
    .outputMode("update") \
    .format("console") \
    .option("truncate", "false") \
    .trigger(processingTime="30 seconds") \
    .start()

query.awaitTermination()
```

---

## 八、踩坑大全

| 坑 | 症状 | 解决 |
|----|------|------|
| `failOnDataLoss` 报错 | Kafka retention 删了消息，Spark 找不到 offset | 设为 `false`，或增大 Kafka retention |
| OOM | Driver/Executor OOM | 减小 `maxOffsetsPerTrigger`（限制每批数据量） |
| 延迟越来越大 | 处理速度 < 数据产生速度 | 增加 Executor 数 / 减小 trigger 间隔 / 优化处理逻辑 |
| 重启后重复消费 | Checkpoint 损坏或路径错误 | 确保 checkpoint 路径持久化（HDFS/S3） |
| Schema 变更 | Kafka 消息格式变了，解析失败 | 使用 Schema Registry + Avro |

---

## 九、关键配置速查

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `kafka.bootstrap.servers` | 至少3个Broker | HA 保证 |
| `startingOffsets` | `earliest`（首次）/ 自动（重启） | Checkpoint 恢复时自动从上次位置 |
| `maxOffsetsPerTrigger` | `100000` | 限制每批最大消息数（防 OOM） |
| `failOnDataLoss` | `false` | 生产建议 false，记日志但不失败 |
| `kafka.group.id` | 不设置 | Structured Streaming 自管 offset，不用 Kafka Group |
| `checkpointLocation` | HDFS/S3 路径 | **必须持久化！** 本地路径重启就丢 |

---

## 十、课堂练习

### 练习 1：设计实时告警

> 需求：从 Kafka 的 `metrics` topic 消费服务器 CPU 指标，如果 5 分钟窗口内平均 CPU > 80%，输出告警。

提示：使用 `withWatermark` + `groupBy(window(...))` + `filter`

### 练习 2：举一反三

> "Spark Structured Streaming 的 Checkpoint 机制与 Flink 的 Checkpoint 有什么异同？"

答：
- 同：都是持久化状态 + offset，保证 exactly-once
- 异：Spark 是微批模式（每批一个 checkpoint），Flink 是流式（周期性异步 checkpoint）
- 异：Spark checkpoint 在 Driver 端协调，Flink 通过 JobManager 的 Checkpoint Coordinator

---

## 十一、知识晶体

```
问题/场景: 如何用 Spark 实时消费 Kafka 数据并保证 exactly-once？
核心机制: Structured Streaming + Kafka Source + Checkpoint + WAL
关键配置:
  format("kafka")                  → Kafka 数据源
  checkpointLocation               → exactly-once 的基础
  trigger(processingTime="N sec")  → 微批间隔
  maxOffsetsPerTrigger             → 防止数据洪峰 OOM
踩坑记录:
  - Checkpoint 不要放本地文件系统（重启丢失 = 重复消费）
  - 不要设 kafka.group.id（Spark 自管 offset，设了反而冲突）
  - Watermark 设太小会丢延迟数据，设太大会增加内存消耗
认知更新: Structured Streaming 的 exactly-once = "幂等写入 + checkpoint 原子提交"，不是 Kafka 的 Consumer Group offset 管理
```
