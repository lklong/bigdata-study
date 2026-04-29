# [教案] Flink on YARN — Hive 数仓集成使用姿势

> 🎯 教学目标：掌握 Flink 与 Hive 数仓的深度集成，包括 HiveCatalog 配置、读写 Hive 表、流式分区写入、维表 Join 等 | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：想象你有一个巨大的仓库（Hive 数仓），里面存放着各种历史货物清单（离线数据）。现在你要做两件事：
1. **实时补货**：把实时到货的商品（流数据）不断地分类入库到正确的货架上（流式写入 Hive 分区）
2. **实时查价**：正在分拣的包裹需要实时查询价格表（Hive 维表 Join）来贴价签

**生产场景**：
- 实时数仓：流式数据实时写入 Hive ODS/DWD 层分区表
- 离线数据补充：Flink 流处理中关联 Hive 维表（用户画像、商品属性）
- 批流一体：同一套 SQL 既能跑批（读 Hive 历史数据）又能跑流（监听新分区）
- Hive UDF 复用：在 Flink SQL 中直接使用已有的 Hive UDF

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17.x / 1.18.x | 本教案以 1.17.2 为例 |
| Hive | 2.3.x / 3.1.x | 本教案以 3.1.3 为例 |
| Hadoop/YARN | 3.x | 本教案以 3.3.6 为例 |
| Hive Metastore | 需独立运行 | Thrift 服务模式 |
| Java | JDK 8 / JDK 11 | |

### 2.2 所需 JAR 包

```bash
# Flink Hive Connector（必须）
flink-sql-connector-hive-3.1.3_2.12-1.17.2.jar

# Hadoop 依赖（如果 Flink 发行版不含）
flink-shaded-hadoop-3-uber-3.3.6-1.17.2.jar

# Hive 相关 JAR（从 Hive 安装目录复制）
hive-exec-3.1.3.jar
hive-metastore-3.1.3.jar
libfb303-0.9.3.jar
```

### 2.3 环境准备命令

```bash
# 1. 确认 Hive Metastore 已启动
hive --service metastore &
netstat -tlnp | grep 9083

# 2. 确认 hive-site.xml 配置
cat $HIVE_HOME/conf/hive-site.xml | grep -A1 "hive.metastore.uris"

# 3. 复制 hive-site.xml 到 Flink conf 目录
cp $HIVE_HOME/conf/hive-site.xml $FLINK_HOME/conf/

# 4. 下载 Flink-Hive Connector
cd $FLINK_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-hive-3.1.3_2.12/1.17.2/flink-sql-connector-hive-3.1.3_2.12-1.17.2.jar

# 5. 设置 HADOOP_CLASSPATH（关键！）
export HADOOP_CLASSPATH=`hadoop classpath`

# 6. 在 Hive 中创建测试表
hive -e "
CREATE DATABASE IF NOT EXISTS flink_test;
USE flink_test;
CREATE TABLE IF NOT EXISTS dim_user (
    user_id STRING, user_name STRING, age INT, city STRING
) STORED AS ORC;
INSERT INTO dim_user VALUES ('10001','张三',28,'北京'),('10002','李四',32,'上海'),('10003','王五',25,'广州');
"
```

---

## 三、核心使用方式

### 3.1 HiveCatalog 配置

```sql
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'flink_test',
    'hive-conf-dir' = '/opt/hive-3.1.3/conf'
);
USE CATALOG hive_catalog;
USE flink_test;
SHOW TABLES;
```

### 3.2 读取 Hive 表

#### 批模式

```sql
SET 'execution.runtime-mode' = 'batch';
SELECT * FROM dim_user WHERE city = '北京';
```

#### 流式监控新分区

```sql
SET 'execution.runtime-mode' = 'streaming';
SELECT * FROM ods_order /*+ OPTIONS(
    'streaming-source.enable' = 'true',
    'streaming-source.monitor-interval' = '60s'
) */;
```

### 3.3 流式写入 Hive 分区表

```sql
CREATE TABLE hive_sink_table (
    order_id STRING, user_id STRING, amount DOUBLE, order_time TIMESTAMP(3)
) PARTITIONED BY (dt STRING, hr STRING) WITH (
    'connector' = 'hive',
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '1h',
    'sink.partition-commit.policy.kind' = 'metastore,success-file',
    'partition.time-extractor.timestamp-pattern' = '$dt $hr:00:00',
    'sink.rolling-policy.file-size' = '128MB',
    'auto-compaction' = 'true',
    'compaction.file-size' = '128MB'
);
```

| 参数 | 说明 | 可选值 |
|------|------|--------|
| `sink.partition-commit.trigger` | 提交触发条件 | `process-time` / `partition-time` |
| `sink.partition-commit.delay` | 触发延迟 | `1h`、`30min` |
| `sink.partition-commit.policy.kind` | 提交策略 | `metastore` / `success-file` / 组合 |
| `partition.time-extractor.timestamp-pattern` | 分区时间提取 | `$dt $hr:00:00` |
| `sink.rolling-policy.file-size` | 文件滚动大小 | 推荐 `128MB` |
| `auto-compaction` | 自动合并小文件 | `true` / `false` |

### 3.4 Hive 维表 Lookup Join

```sql
SELECT o.order_id, o.amount, u.user_name, u.city
FROM kafka_orders AS o
LEFT JOIN hive_catalog.flink_test.dim_user /*+ OPTIONS(
    'lookup.join.cache.ttl' = '1h',
    'streaming-source.enable' = 'true',
    'streaming-source.monitor-interval' = '5min'
) */ FOR SYSTEM_TIME AS OF o.proc_time AS u
ON o.user_id = u.user_id;
```

### 3.5 Hive UDF 使用

```sql
USE CATALOG hive_catalog;
-- 已注册的 Hive UDF 可直接使用
SELECT my_hive_udf(column1) FROM my_table;
-- 手动注册
CREATE FUNCTION my_udf AS 'com.example.hive.udf.MyUDF' USING JAR 'hdfs:///udfs/my-udf.jar';
```

---

## 四、完整实战示例

### 4.1 场景描述

Kafka 实时订单流 → 关联 Hive 用户维表 → 写入 Hive 分区表，供下游离线报表查询。

### 4.2 完整 SQL

```sql
CREATE CATALOG hive_catalog WITH ('type'='hive','default-database'='flink_test','hive-conf-dir'='/opt/hive-3.1.3/conf');

CREATE TABLE kafka_orders (
    order_id STRING, user_id STRING, amount DOUBLE,
    order_time TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND,
    proc_time AS PROCTIME()
) WITH (
    'connector'='kafka','topic'='orders_topic',
    'properties.bootstrap.servers'='kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id'='flink-hive-integration',
    'scan.startup.mode'='latest-offset','format'='json','json.ignore-parse-errors'='true'
);

INSERT INTO hive_catalog.flink_test.dwd_order_detail
SELECT o.order_id, o.user_id, u.user_name, u.city, o.amount, o.order_time,
    DATE_FORMAT(o.order_time,'yyyy-MM-dd') AS dt, DATE_FORMAT(o.order_time,'HH') AS hr
FROM kafka_orders AS o
LEFT JOIN hive_catalog.flink_test.dim_user FOR SYSTEM_TIME AS OF o.proc_time AS u
ON o.user_id = u.user_id;
```

### 4.3 提交命令（Application Mode on YARN）

```bash
export HADOOP_CLASSPATH=`hadoop classpath`
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Flink-Hive-Integration" \
    -Dyarn.application.queue=flink \
    -Dyarn.ship-files="/opt/hive-3.1.3/conf/hive-site.xml" \
    -Dclassloader.resolve-order=parent-first \
    -c com.example.flink.hive.HiveIntegrationJob \
    /opt/flink-jobs/hive-integration-1.0.jar
```

### 4.4 验证结果

```bash
# Hive 中查询
hive -e "SHOW PARTITIONS flink_test.dwd_order_detail; SELECT * FROM flink_test.dwd_order_detail WHERE dt='2025-04-20';"
# HDFS 检查
hdfs dfs -ls /user/hive/warehouse/flink_test.db/dwd_order_detail/dt=2025-04-20/
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `NoClassDefFoundError: HiveConf` | Hive 依赖未加载 | 设置 `HADOOP_CLASSPATH` |
| `MetaException: Could not connect` | Metastore 不可达 | 确认 Metastore 已启动 |
| 分区写入但 Hive 查不到 | 分区未提交 | 检查 `partition-commit.policy.kind` 含 `metastore` |
| 大量小文件 | 并行度高/ckp 频繁 | 开启 `auto-compaction` |
| Lookup Join 结果为 null | 类型不匹配/无数据 | 检查 Join key 类型一致 |
| `TableNotExistException` | Catalog 路径错误 | 使用全限定名 |

---

## 六、生产最佳实践

### 6.1 资源配置建议

| 场景 | JM | TM | 并行度 |
|------|----|----|--------|
| 维表 Join | 2GB | 4GB | 4 |
| 流式写 Hive | 2GB | 8GB | 匹配 Kafka 分区数 |
| 批量读 Hive | 2GB | 4GB | 根据数据量 |

### 6.2 关键参数调优

```properties
execution.checkpointing.interval: 120000
sink.rolling-policy.file-size: 128MB
auto-compaction: true
lookup.join.cache.ttl: 3600000
taskmanager.memory.managed.fraction: 0.4
```

### 6.3 监控与告警

- 分区提交延迟 > 2h → P2
- 单分区文件数 > 1000 → P3
- Checkpoint 连续失败 → P1
- Metastore 不可达 → P1

---

## 七、举一反三

### 7.1 与其他方案对比

| 维度 | Flink+Hive | Spark+Hive | Hive Streaming |
|------|-----------|-----------|----------------|
| 延迟 | 分钟级 | 分钟级 | 秒级(功能有限) |
| 格式 | ORC/Parquet/CSV | ORC/Parquet | 仅ORC(ACID) |
| 维表Join | 支持Lookup | DataFrame Join | 不支持 |

### 7.2 面试高频题

**Q1: 流式写 Hive 如何保证下游能查到新数据？**
A: 通过分区提交策略（trigger=partition-time + policy=metastore,success-file），在 Checkpoint 完成时提交分区到 HMS。

**Q2: Lookup Join 原理和限制？**
A: 基于 PROCTIME() 查询维表，缓存到 TM 内存。限制：仅处理时间、大维表耗内存、变化感知有延迟。

**Q3: 小文件问题解决？**
A: auto-compaction=true、调大 rolling-policy.file-size、延长 checkpoint 间隔、降低 sink 并行度。

### 7.3 思考题

1. Hive 维表 1 亿行，直接 Lookup Join 会怎样？如何优化？
2. 数据写入 HDFS 但分区未提交导致不一致如何处理？
3. Flink 写 Hive vs 写 Iceberg/Hudi 再用 Hive 外表查询，各有何优劣？
