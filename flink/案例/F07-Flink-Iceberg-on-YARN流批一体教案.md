# [教案] Flink on YARN — Iceberg 流批一体使用姿势

> 🎯 教学目标：掌握 Flink + Iceberg 流批一体数据湖方案，实现 Kafka 实时入湖、流式读取、批量查询 | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

### 1.1 典型业务场景

| 场景 | 描述 | 示例 |
|------|------|------|
| **实时入湖** | Kafka 实时数据通过 Flink 写入 Iceberg 表 | 用户行为日志实时入湖，T+0 可查 |
| **CDC 入湖** | MySQL CDC 变更数据实时同步到 Iceberg | 业务数据库实时同步到数据湖 |
| **流批一体** | 同一张 Iceberg 表，流式写入 + 批量分析 | 实时写入，Spark/Trino/Hive 批量查询 |
| **数据回溯** | 利用 Iceberg 时间旅行查询历史版本 | 数据修复、审计、对比分析 |
| **Upsert 入湖** | 支持主键更新，实现数据去重 | 订单状态变更实时更新到湖表 |

### 1.2 为什么选 Flink + Iceberg？

- **流批一体**：同一张表支持流式写入和批量读取
- **ACID 事务**：每次 Checkpoint 生成一个 Iceberg Snapshot，保证数据一致性
- **Schema Evolution**：支持字段新增、删除、重命名，无需重建表
- **Time Travel**：基于 Snapshot 做时间旅行查询
- **开放格式**：Parquet/ORC 存储，Spark/Trino/Hive/Presto 都能查询
- **Hidden Partitioning**：自动分区转换，无需用户感知分区列

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Flink | 1.17.x / 1.18.x / 1.19.x | 推荐 1.17+ |
| Iceberg | 1.4.x / 1.5.x / 1.6.x | 推荐 1.4+ |
| Hadoop/YARN | 3.1+ | Flink on YARN 运行环境 |
| Hive Metastore | 3.1+ | HiveCatalog 需要 |
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
export HIVE_CONF_DIR=/opt/hive/conf

# ============================================
# 2. 下载必需 JAR 包
# ============================================
cd $FLINK_HOME/lib

# Iceberg Flink Runtime（核心依赖 — 注意版本匹配）
wget https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-flink-runtime-1.17/1.5.2/iceberg-flink-runtime-1.17-1.5.2.jar

# Flink Kafka Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar

# Hive Metastore 依赖（使用 HiveCatalog 时需要）
ln -s /opt/hive/lib/hive-exec-3.1.3.jar $FLINK_HOME/lib/
ln -s /opt/hive/lib/hive-metastore-3.1.3.jar $FLINK_HOME/lib/
ln -s /opt/hive/lib/libfb303-0.9.3.jar $FLINK_HOME/lib/

# ============================================
# 3. 拷贝配置文件
# ============================================
cp $HADOOP_HOME/etc/hadoop/core-site.xml $FLINK_HOME/conf/
cp $HADOOP_HOME/etc/hadoop/hdfs-site.xml $FLINK_HOME/conf/
cp /opt/hive/conf/hive-site.xml $FLINK_HOME/conf/

# ============================================
# 4. 验证 HDFS 和 Hive Metastore 连通性
# ============================================
hdfs dfs -ls /
beeline -u "jdbc:hive2://hive-metastore:10000" -e "show databases;"

# ============================================
# 5. 创建 Iceberg 数据目录
# ============================================
hdfs dfs -mkdir -p /warehouse/iceberg

# ============================================
# 6. 准备 Kafka 测试 Topic
# ============================================
kafka-topics.sh --create \
  --bootstrap-server kafka01:9092 \
  --topic user_behavior \
  --partitions 6 \
  --replication-factor 2
```

---

## 三、核心使用方式

### 3.1 创建 Iceberg Catalog

#### 方式一：HiveCatalog（生产推荐）

```sql
CREATE CATALOG hive_catalog WITH (
    'type' = 'iceberg',
    'catalog-type' = 'hive',
    'uri' = 'thrift://hive-metastore:9083',
    'warehouse' = 'hdfs:///warehouse/iceberg',
    'property-version' = '1'
);

USE CATALOG hive_catalog;
CREATE DATABASE IF NOT EXISTS ods;
USE ods;
```

#### 方式二：HadoopCatalog（无 Hive 环境时使用）

```sql
CREATE CATALOG hadoop_catalog WITH (
    'type' = 'iceberg',
    'catalog-type' = 'hadoop',
    'warehouse' = 'hdfs:///warehouse/iceberg'
);

USE CATALOG hadoop_catalog;
CREATE DATABASE IF NOT EXISTS ods;
USE ods;
```

### 3.2 Flink SQL — 创建 Iceberg 表

```sql
-- Append 模式（适合日志类数据）
CREATE TABLE user_behavior (
    user_id     STRING,
    item_id     STRING,
    category_id STRING,
    behavior    STRING,
    ts          TIMESTAMP(3),
    dt          STRING
) PARTITIONED BY (dt)
WITH (
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728',
    'write.metadata.delete-after-commit.enabled' = 'true',
    'write.metadata.previous-versions-max' = '10'
);

-- Upsert 模式（适合业务表）
CREATE TABLE order_status (
    order_id    STRING,
    user_id     STRING,
    status      STRING,
    amount      DECIMAL(10,2),
    update_time TIMESTAMP(3),
    dt          STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) PARTITIONED BY (dt)
WITH (
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.upsert.enabled' = 'true',
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728'
);
```

### 3.3 参数详解表 — Iceberg 表属性

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `format-version` | `1` | 表格式版本，v2 支持 row-level delete |
| `write.format.default` | `parquet` | 数据文件格式：parquet / orc / avro |
| `write.parquet.compression-codec` | `gzip` | 压缩：gzip / snappy / zstd / lz4 |
| `write.target-file-size-bytes` | `536870912` (512MB) | 目标文件大小 |
| `write.upsert.enabled` | `false` | 是否启用 Upsert 写入 |
| `write.distribution-mode` | `none` | 写入分布：none / hash / range |
| `write.metadata.delete-after-commit.enabled` | `false` | 自动清理旧元数据 |
| `write.metadata.previous-versions-max` | `100` | 保留历史元数据版本数 |
| `read.split.target-size` | `134217728` (128MB) | 读取 split 大小 |

### 3.4 参数详解表 — Flink 流式读取配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `streaming` | `false` | 是否流式读取 |
| `monitor-interval` | `60s` | 监控新 snapshot 间隔 |
| `start-snapshot-id` | - | 从指定 snapshot 开始消费 |
| `end-snapshot-id` | - | 消费到指定 snapshot 停止 |
| `start-tag` | - | 从指定 tag 开始 |

---

## 四、完整实战示例

### 4.1 实战场景：Kafka → Flink → Iceberg 实时入湖

#### 4.1.1 完整 SQL 作业

```sql
-- 1. 创建 Iceberg Catalog
CREATE CATALOG hive_catalog WITH (
    'type' = 'iceberg',
    'catalog-type' = 'hive',
    'uri' = 'thrift://hive-metastore:9083',
    'warehouse' = 'hdfs:///warehouse/iceberg'
);

USE CATALOG hive_catalog;
CREATE DATABASE IF NOT EXISTS ods;
USE ods;

-- 2. Kafka Source
CREATE TABLE default_catalog.default_database.kafka_user_behavior (
    user_id     STRING,
    item_id     STRING,
    category_id STRING,
    behavior    STRING,
    ts          BIGINT,
    event_time AS TO_TIMESTAMP_LTZ(ts, 3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_behavior',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-iceberg-writer',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- 3. Iceberg Sink
CREATE TABLE IF NOT EXISTS user_behavior (
    user_id     STRING,
    item_id     STRING,
    category_id STRING,
    behavior    STRING,
    event_time  TIMESTAMP(3),
    dt          STRING
) PARTITIONED BY (dt)
WITH (
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728'
);

-- 4. 流式写入
INSERT INTO user_behavior
SELECT
    user_id, item_id, category_id, behavior, event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt
FROM default_catalog.default_database.kafka_user_behavior;
```

#### 4.1.2 流式读取 Iceberg 表

```sql
-- 增量消费新 Snapshot
SELECT * FROM user_behavior /*+ OPTIONS(
    'streaming' = 'true',
    'monitor-interval' = '30s'
) */;
```

#### 4.1.3 批量读取 + 时间旅行

```sql
-- 查询指定 Snapshot
SELECT * FROM user_behavior /*+ OPTIONS('snapshot-id' = '123456789') */;

-- 查询指定时间点
SELECT * FROM user_behavior /*+ OPTIONS('as-of-timestamp' = '1714300800000') */;
```

#### 4.1.4 Application Mode 提交命令

```bash
export HADOOP_CLASSPATH=$(hadoop classpath)

$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=2 \
  -Dparallelism.default=4 \
  -Dyarn.application.name="Flink-Iceberg-Streaming-Write" \
  -Dyarn.application.queue=production \
  -Dexecution.checkpointing.interval=60000 \
  -Dexecution.checkpointing.mode=EXACTLY_ONCE \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/iceberg-write \
  -Dyarn.ship-files="$FLINK_HOME/conf/hive-site.xml" \
  -c com.example.IcebergStreamingWriteJob \
  /path/to/flink-iceberg-job.jar
```

### 4.2 Checkpoint 与 Iceberg Snapshot 的关系

| Checkpoint 间隔 | 数据可见延迟 | 小文件数量 | 建议场景 |
|----------------|-------------|-----------|---------|
| 30s | 30s | 多 | 实时性要求极高 |
| 1min | 1min | 较多 | 准实时 |
| 5min | 5min | 适中 | 生产推荐 |
| 10min | 10min | 少 | 批量导入 |

---

## 五、常见问题与排障

| 问题现象 | 可能原因 | 解决方案 |
|---------|---------|---------|
| `NoSuchTableException` | Catalog 配置错误 | 检查 URI、warehouse 路径 |
| Checkpoint 超时 | flush 慢 | 增大 timeout，减小并行度 |
| 小文件过多 | Checkpoint 间隔过短 | 增大间隔 + Compaction |
| Upsert 不生效 | format-version=1 | 改为 `format-version = 2` |
| 流式读取无新数据 | monitor-interval 过大 | 减小 monitor-interval |

---

## 六、生产最佳实践

### 6.1 小文件治理

```sql
-- Compaction
CALL hive_catalog.system.rewrite_data_files(
    table => 'ods.user_behavior',
    strategy => 'binpack',
    options => map('target-file-size-bytes', '134217728')
);

-- 清理过期 Snapshot
CALL hive_catalog.system.expire_snapshots(
    table => 'ods.user_behavior',
    older_than => TIMESTAMP '2026-04-22 00:00:00',
    retain_last => 5
);
```

### 6.2 Checkpoint 配置

```yaml
execution.checkpointing.interval: 60000
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 300000
state.backend: rocksdb
state.checkpoints.dir: hdfs:///flink/checkpoints
```

---

## 七、举一反三

### 7.1 对比：Iceberg vs Hudi vs Delta Lake

| 维度 | Iceberg | Hudi | Delta Lake |
|------|---------|------|------------|
| Flink 支持 | 官方一等公民 | 官方支持 | 社区支持 |
| Upsert | v2 equality delete | COW/MOR | 基于 log |
| Hidden Partition | ✅ | ❌ | ❌ |
| 引擎兼容 | Spark/Flink/Trino/Hive | Spark/Flink/Hive | Spark 最佳 |

### 7.2 面试高频题

**Q1: Flink 写 Iceberg 如何保证 Exactly-Once？**
> 两阶段提交：Checkpoint 时 flush 数据文件，Committer 提交 Snapshot。失败则不提交。

**Q2: format-version 1 vs 2？**
> v1 只支持 append/overwrite；v2 支持 row-level delete，可做 Upsert。

**Q3: 如何解决小文件？**
> 增大 Checkpoint 间隔 + rewrite_data_files Compaction + expire_snapshots。

---

> 📝 **教案小结**：核心要点 — 每个 Checkpoint = 一个 Snapshot，Checkpoint 间隔决定延迟和小文件，format-version=2 是 Upsert 前提。
