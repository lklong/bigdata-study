# [教案] Flink on YARN — MySQL CDC 实时同步使用姿势

> 🎯 教学目标：掌握 flink-connector-mysql-cdc 的完整使用，包括全量+增量阶段原理、MySQL→Kafka/Iceberg/MySQL 三种典型链路、Debezium 格式解析、断点续传、多表同步 | ⏰ 预计学时: 85分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 什么场景需要 MySQL CDC？

**生活类比**：MySQL CDC 就像在 MySQL 数据库旁边装了一个"监控摄像头"，它能实时捕获数据库的每一次变更（INSERT/UPDATE/DELETE），然后将这些变更事件像"快递包裹"一样发送到下游系统。

典型场景：
- 实时数仓：MySQL 业务库 → Flink → 数据湖/OLAP（秒级延迟替代 T+1 离线同步）
- 异构数据同步：MySQL → Elasticsearch/Redis/HBase（搜索/缓存刷新）
- 数据库迁移：MySQL → MySQL（实时双写/灰度切换）
- 事件驱动架构：数据变更 → Kafka → 下游微服务

### 1.2 CDC 原理简述

```
                   ┌─────────────┐
                   │   MySQL     │
                   │  Binlog     │ ← 开启 ROW 模式
                   └──────┬──────┘
                          │ 模拟 Slave 读取 Binlog
                          ▼
                   ┌─────────────┐
                   │ Flink CDC   │ ← Debezium Engine
                   │ Connector   │
                   └──────┬──────┘
                          │ 转为 Flink RowData
                          ▼
                   ┌─────────────┐
                   │ Flink Job   │ → Kafka / Iceberg / Hudi / MySQL
                   └─────────────┘
```

### 1.3 全量+增量阶段

| 阶段 | 说明 |
|------|------|
| Snapshot（全量） | 首次启动时读取表的全量数据（类似 SELECT *） |
| Binlog（增量） | 全量完成后，从 Binlog 位点开始持续捕获变更 |
| 无锁快照 | Flink CDC 2.x+ 使用 chunk-based 无锁快照算法（不阻塞业务写入） |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.15+ | 推荐 1.17/1.18 |
| MySQL | 5.7+ / 8.0+ | 需开启 Binlog |
| flink-cdc-connector | 2.4+ | 对应 Flink 版本 |
| Hadoop | 3.x | YARN 运行 |

### 2.2 MySQL 配置要求

```sql
-- 检查 Binlog 是否开启
SHOW VARIABLES LIKE 'log_bin';              -- 必须为 ON
SHOW VARIABLES LIKE 'binlog_format';        -- 必须为 ROW
SHOW VARIABLES LIKE 'binlog_row_image';     -- 推荐 FULL

-- 如未开启，在 my.cnf 中配置：
-- [mysqld]
-- server-id=1
-- log-bin=mysql-bin
-- binlog-format=ROW
-- binlog-row-image=FULL
-- expire_logs_days=7

-- 创建 CDC 专用用户
CREATE USER 'flink_cdc'@'%' IDENTIFIED BY 'Flink_CDC_2024!';
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%';
FLUSH PRIVILEGES;
```

### 2.3 JAR 依赖

```bash
# Flink CDC MySQL Connector
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-mysql-cdc/2.4.2/flink-sql-connector-mysql-cdc-2.4.2.jar

# 放入 Flink lib
cp flink-sql-connector-mysql-cdc-2.4.2.jar $FLINK_HOME/lib/

# 如果需要输出到 Kafka：
cp flink-sql-connector-kafka-*.jar $FLINK_HOME/lib/

# 如果需要输出到 Iceberg：
cp iceberg-flink-runtime-*.jar $FLINK_HOME/lib/

export HADOOP_CLASSPATH=`hadoop classpath`
```

---

## 三、核心使用方式

### 3.1 SQL DDL 定义 MySQL CDC Source

```sql
CREATE TABLE mysql_source (
    id BIGINT PRIMARY KEY NOT ENFORCED,
    name VARCHAR(128),
    age INT,
    email VARCHAR(256),
    create_time TIMESTAMP(3),
    update_time TIMESTAMP(3)
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = '10.0.1.100',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'Flink_CDC_2024!',
    'database-name' = 'user_db',
    'table-name' = 'users',
    'server-time-zone' = 'Asia/Shanghai',
    'scan.startup.mode' = 'initial',
    'scan.incremental.snapshot.enabled' = 'true',
    'scan.incremental.snapshot.chunk.size' = '8096',
    'connect.timeout' = '30s',
    'debezium.snapshot.locking.mode' = 'none'
);
```

### 3.2 核心参数详解

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `connector` | - | 固定 `mysql-cdc` |
| `hostname` | - | MySQL 主机地址 |
| `port` | `3306` | MySQL 端口 |
| `username` | - | 用户名（需有 REPLICATION 权限） |
| `password` | - | 密码 |
| `database-name` | - | 数据库名（支持正则: `db1\|db2`） |
| `table-name` | - | 表名（支持正则: `orders\|products`） |
| `server-time-zone` | UTC | MySQL 服务器时区 |
| `scan.startup.mode` | `initial` | 启动模式: initial/earliest-offset/latest-offset/specific-offset/timestamp |
| `scan.incremental.snapshot.enabled` | `true` | 无锁快照 |
| `scan.incremental.snapshot.chunk.size` | `8096` | 快照分片大小 |
| `scan.snapshot.fetch.size` | `1024` | 快照每次 fetch 行数 |
| `server-id` | 自动 | MySQL server-id（多任务需不同） |
| `debezium.snapshot.locking.mode` | `none` | 快照锁模式 |

### 3.3 启动模式详解

```sql
-- initial: 先全量快照，再增量 Binlog（默认，最常用）
'scan.startup.mode' = 'initial'

-- earliest-offset: 从最早的 Binlog 位点开始（不做快照）
'scan.startup.mode' = 'earliest-offset'

-- latest-offset: 从最新 Binlog 位点开始（只看新变更）
'scan.startup.mode' = 'latest-offset'

-- specific-offset: 从指定 Binlog 位点开始
'scan.startup.mode' = 'specific-offset'
'scan.startup.specific-offset.file' = 'mysql-bin.000003'
'scan.startup.specific-offset.pos' = '4'

-- timestamp: 从指定时间戳开始
'scan.startup.mode' = 'timestamp'
'scan.startup.timestamp-millis' = '1705276800000'
```

---

## 四、完整实战示例

### 4.1 示例一：MySQL → Kafka（实时变更投递）

#### SQL 写法

```sql
-- 1. MySQL CDC Source
CREATE TABLE mysql_orders (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id VARCHAR(64),
    product_id BIGINT,
    amount DECIMAL(10, 2),
    status VARCHAR(32),
    create_time TIMESTAMP(3),
    update_time TIMESTAMP(3)
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = '10.0.1.100',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'Flink_CDC_2024!',
    'database-name' = 'ecommerce',
    'table-name' = 'orders',
    'server-time-zone' = 'Asia/Shanghai',
    'scan.startup.mode' = 'initial'
);

-- 2. Kafka Sink（Debezium JSON 格式，保留 CDC 语义）
CREATE TABLE kafka_orders_cdc (
    order_id BIGINT,
    user_id STRING,
    product_id BIGINT,
    amount DECIMAL(10, 2),
    status STRING,
    create_time TIMESTAMP(3),
    update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders-cdc',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092',
    'format' = 'debezium-json',
    'sink.parallelism' = '4'
);

-- 3. 同步
INSERT INTO kafka_orders_cdc
SELECT * FROM mysql_orders;
```

#### Java DataStream 写法

```java
import com.ververica.cdc.connectors.mysql.source.MySqlSource;
import com.ververica.cdc.connectors.mysql.table.StartupOptions;
import com.ververica.cdc.debezium.JsonDebeziumDeserializationSchema;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

public class MySQLToKafka {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);
        env.setParallelism(4);

        // MySQL CDC Source
        MySqlSource<String> mySqlSource = MySqlSource.<String>builder()
            .hostname("10.0.1.100")
            .port(3306)
            .databaseList("ecommerce")
            .tableList("ecommerce.orders")
            .username("flink_cdc")
            .password("Flink_CDC_2024!")
            .serverTimeZone("Asia/Shanghai")
            .startupOptions(StartupOptions.initial())
            .deserializer(new JsonDebeziumDeserializationSchema())
            .build();

        // Kafka Sink
        KafkaSink<String> kafkaSink = KafkaSink.<String>builder()
            .setBootstrapServers("kafka01:9092,kafka02:9092")
            .setRecordSerializer(
                KafkaRecordSerializationSchema.builder()
                    .setTopic("orders-cdc")
                    .setValueSerializationSchema(new SimpleStringSchema())
                    .build()
            )
            .build();

        env.fromSource(mySqlSource, WatermarkStrategy.noWatermarks(), "MySQL CDC Source")
            .sinkTo(kafkaSink);

        env.execute("MySQL CDC to Kafka");
    }
}
```

### 4.2 示例二：MySQL → Iceberg（实时入湖）

```sql
-- 1. MySQL CDC Source（同上）
CREATE TABLE mysql_orders (...) WITH ('connector' = 'mysql-cdc', ...);

-- 2. Iceberg Sink
CREATE CATALOG iceberg_catalog WITH (
    'type' = 'iceberg',
    'catalog-type' = 'hive',
    'uri' = 'thrift://hive-metastore:9083',
    'warehouse' = 'hdfs:///data/iceberg/warehouse'
);

USE CATALOG iceberg_catalog;

CREATE TABLE ods.orders (
    order_id BIGINT,
    user_id STRING,
    product_id BIGINT,
    amount DECIMAL(10, 2),
    status STRING,
    create_time TIMESTAMP(6),
    update_time TIMESTAMP(6)
) PARTITIONED BY (days(create_time))  -- Iceberg 隐式分区
WITH (
    'format-version' = '2',
    'write.upsert.enabled' = 'true'
);

-- 3. UPSERT 同步
INSERT INTO ods.orders
SELECT * FROM default_catalog.default_database.mysql_orders;
```

### 4.3 示例三：MySQL → MySQL（异构同步/分库分表归并）

```sql
-- 1. MySQL CDC Source（多库多表正则匹配）
CREATE TABLE mysql_orders_shards (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id VARCHAR(64),
    amount DECIMAL(10, 2),
    status VARCHAR(32),
    shard_id INT,
    create_time TIMESTAMP(3)
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = '10.0.1.100',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'Flink_CDC_2024!',
    'database-name' = 'order_db_[0-9]+',           -- 正则匹配多库
    'table-name' = 'orders_[0-9]+',                -- 正则匹配多表
    'server-time-zone' = 'Asia/Shanghai'
);

-- 2. 目标 MySQL JDBC Sink
CREATE TABLE target_mysql_orders (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id STRING,
    amount DECIMAL(10, 2),
    status STRING,
    shard_id INT,
    create_time TIMESTAMP(3)
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://10.0.2.100:3306/data_warehouse',
    'table-name' = 'all_orders',
    'username' = 'writer',
    'password' = 'Writer2024!',
    'sink.buffer-flush.max-rows' = '1000',
    'sink.buffer-flush.interval' = '5s',
    'sink.max-retries' = '3'
);

-- 3. 分库分表归并写入
INSERT INTO target_mysql_orders
SELECT * FROM mysql_orders_shards;
```

### 4.4 Debezium 消息格式

```json
{
  "before": {
    "order_id": 1001,
    "status": "PENDING",
    "amount": 99.50
  },
  "after": {
    "order_id": 1001,
    "status": "PAID",
    "amount": 99.50
  },
  "op": "u",
  "ts_ms": 1705276800000,
  "source": {
    "db": "ecommerce",
    "table": "orders",
    "file": "mysql-bin.000003",
    "pos": 12345
  }
}
```

| op 字段 | 含义 |
|---------|------|
| `c` | CREATE (INSERT) |
| `u` | UPDATE |
| `d` | DELETE |
| `r` | READ (snapshot) |

### 4.5 断点续传（Checkpoint 恢复）

```bash
# 1. 正常停止作业（带 Savepoint）
flink stop --savepointPath hdfs:///flink/savepoints/ <job-id>

# 2. 从 Savepoint 恢复（断点续传）
flink run-application -t yarn-application \
    -Dyarn.application.name="mysql-cdc-resume" \
    -s hdfs:///flink/savepoints/savepoint-xxx \
    -Dexecution.checkpointing.interval=60000 \
    -c com.example.MySQLCDCJob \
    hdfs:///flink/jars/mysql-cdc-job.jar

# Flink CDC 会从上次的 Binlog 位点继续消费，不会丢数据
```

### 4.6 多表同步

```sql
-- 方式1：正则匹配多表（相同 Schema）
CREATE TABLE multi_table_source (
    id BIGINT PRIMARY KEY NOT ENFORCED,
    data STRING,
    update_time TIMESTAMP(3)
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = '10.0.1.100',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'Flink_CDC_2024!',
    'database-name' = 'ecommerce',
    'table-name' = 'user_action_.*',  -- 匹配所有 user_action_ 开头的表
    'server-time-zone' = 'Asia/Shanghai'
);

-- 方式2：多个 CDC Source（不同 Schema）
-- 分别定义每张表的 Source DDL，然后 UNION ALL 或分别写入不同 Sink
```

### 4.7 提交命令

```bash
flink run-application -t yarn-application \
    -Dyarn.application.name="mysql-cdc-sync" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dexecution.checkpointing.min-pause=30000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/mysql-cdc \
    -Dstate.backend.incremental=true \
    -c com.example.MySQLCDCSync \
    hdfs:///flink/jars/mysql-cdc-sync.jar
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | `Access denied; need REPLICATION SLAVE` | 权限不足 | 授予 REPLICATION SLAVE, REPLICATION CLIENT 权限 |
| 2 | `Binlog is not enabled` | MySQL 未开 Binlog | 配置 log-bin=mysql-bin, binlog-format=ROW |
| 3 | 全量阶段 OOM | 大表全量快照 | 减小 `scan.incremental.snapshot.chunk.size`，增大 TM 内存 |
| 4 | `server-id conflicts` | 多个 CDC 任务 server-id 冲突 | 每个任务指定不同的 `server-id` 范围 |
| 5 | 时区不对导致时间偏移 | `server-time-zone` 配置错误 | 设为 MySQL 实际时区 `Asia/Shanghai` |
| 6 | 恢复后重复消费 | 未正确从 Savepoint 恢复 | 使用 `-s savepoint-path` 恢复 |
| 7 | 连接超时 | 网络不通或 MySQL 连接数满 | 检查网络 + 增大 max_connections |
| 8 | Schema 变更导致任务失败 | DDL 变更未处理 | 使用 CDC 3.x Pipeline 的 Schema Evolution |
| 9 | 数据延迟越来越大 | 写入速度跟不上 Binlog 产生速度 | 增加并行度 / 优化 Sink 写入 |
| 10 | `The MySQL server is not running with GTID mode` | 配置了 GTID 模式但服务未开启 | 开启 GTID 或改用 Binlog 位点模式 |

---

## 六、生产最佳实践

### 6.1 MySQL 侧准备

```sql
-- 生产环境推荐配置
[mysqld]
server-id=1
log-bin=mysql-bin
binlog-format=ROW
binlog-row-image=FULL
expire_logs_days=7
max_binlog_size=512M
gtid_mode=ON
enforce_gtid_consistency=ON
```

### 6.2 Flink 侧配置

```bash
# 推荐参数
-Dexecution.checkpointing.interval=60000
-Dexecution.checkpointing.min-pause=30000
-Dstate.backend=rocksdb
-Dstate.backend.incremental=true
-Dstate.checkpoints.num-retained=3
-Drest.flamegraph.enabled=true
```

### 6.3 并行度规划

```
# CDC Source 并行度
source.parallelism = min(MySQL表数, 希望的并行度)
# 注意：单个 CDC Source 的并行度在全量阶段有效
# 增量阶段只有 1 个 reader（单线程读 Binlog）

# Sink 并行度
sink.parallelism = 根据写入目标调整
# Kafka Sink: 等于 topic partition 数
# JDBC Sink: 2~8（避免连接池过大）
# Hudi/Iceberg: 4~16
```

### 6.4 监控告警

```yaml
# 关键指标
- currentEmitEventTimeLag: CDC 延迟（当前事件时间与现在的差）
- sourceIdleTime: Source 空闲时间
- numRecordsIn/Out: 输入输出记录数

# 告警规则
- alert: CDCLagTooHigh
  expr: flink_taskmanager_job_task_operator_currentEmitEventTimeLag > 300000
  for: 5m
  annotations:
    summary: "CDC 延迟超过5分钟"
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: Flink CDC 无锁快照算法的原理？**

> A: 基于 chunk-based 分片读取：
> 1. 将表按主键范围分为多个 chunk
> 2. 每个 chunk 独立进行 snapshot（SELECT WHERE pk BETWEEN x AND y）
> 3. 分片之间可以并行读取（全量阶段可并行）
> 4. 记录每个 chunk 的高水位 Binlog 位点
> 5. 全部 chunk 完成后，切换到 Binlog 增量阶段
> 6. 全程无需加锁，不阻塞业务写入

**Q2: CDC 任务从 Savepoint 恢复后，会不会丢数据或重复？**

> A: 不会丢数据。Flink CDC 在 Checkpoint 时会保存当前的 Binlog 位点到 State 中。从 Savepoint 恢复时：
> - Binlog Reader 从保存的位点继续读取
> - 可能会有少量重复读取（at-least-once at source level）
> - 通过 Flink 的 Exactly-Once 语义 + Sink 的幂等性保证端到端不重复

**Q3: 为什么增量阶段只有 1 个并行度？**

> A: MySQL Binlog 是全局有序的单条日志流（一个 server 一份 Binlog），只能有一个 reader 线程来保证顺序性。如果需要扩展并行度，可以在 Source 后通过 keyBy 分发到多个并行的 Sink。

**Q4: 多表同步时如何处理不同表的 Schema 差异？**

> A: 两种方式：
> 1. CDC 2.x：每张表定义独立的 DDL → 独立的 Source → 各自写入不同 Sink
> 2. CDC 3.x Pipeline：YAML 配置整库同步，支持 Schema Evolution 自动适配

### 7.2 思考题

1. **如果 MySQL 有一张 10 亿行的大表，CDC 全量阶段需要多久？如何加速？**
2. **CDC 任务消费的 Binlog 被 MySQL expire_logs_days 清理了怎么办？**
3. **如何监控 CDC 任务的端到端延迟，从 MySQL 写入到下游可见？**

---

**本教案结束。下一篇：F13-Flink-CDC全家桶-on-YARN 多源同步教案**
