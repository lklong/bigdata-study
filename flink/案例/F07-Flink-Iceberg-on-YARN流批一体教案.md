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
# 如果 Hive 已安装，直接链接即可
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
-- 使用 Hive Metastore 管理 Iceberg 表元数据
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
-- 不依赖 Hive Metastore，元数据直接存 HDFS
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
-- ============================================
-- 创建 Iceberg 表（Append 模式，适合日志类数据）
-- ============================================
CREATE TABLE user_behavior (
    user_id     STRING,
    item_id     STRING,
    category_id STRING,
    behavior    STRING,         -- pv / buy / cart / fav
    ts          TIMESTAMP(3),
    dt          STRING          -- 分区字段
) PARTITIONED BY (dt)
WITH (
    'format-version' = '2',             -- 推荐 v2 格式（支持 upsert/delete）
    'write.format.default' = 'parquet', -- 文件格式
    'write.parquet.compression-codec' = 'zstd',   -- 压缩算法
    'write.target-file-size-bytes' = '134217728',  -- 目标文件 128MB
    'write.metadata.delete-after-commit.enabled' = 'true',
    'write.metadata.previous-versions-max' = '10'
);

-- ============================================
-- 创建 Iceberg 表（Upsert 模式，适合业务表）
-- ============================================
CREATE TABLE order_status (
    order_id    STRING,
    user_id     STRING,
    status      STRING,        -- created / paid / shipped / completed
    amount      DECIMAL(10,2),
    update_time TIMESTAMP(3),
    dt          STRING,
    PRIMARY KEY (order_id) NOT ENFORCED  -- Upsert 需要主键
) PARTITIONED BY (dt)
WITH (
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.upsert.enabled' = 'true',               -- 开启 Upsert
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728'
);
```

### 3.3 参数详解表 — Iceberg 表属性

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `format-version` | `1` | 表格式版本，v2 支持 row-level delete |
| `write.format.default` | `parquet` | 数据文件格式：parquet / orc / avro |
| `write.parquet.compression-codec` | `gzip` | 压缩算法：gzip / snappy / zstd / lz4 |
| `write.target-file-size-bytes` | `536870912` (512MB) | 目标文件大小 |
| `write.upsert.enabled` | `false` | 是否启用 Upsert 写入 |
| `write.distribution-mode` | `none` | 写入分布模式：none / hash / range |
| `write.metadata.delete-after-commit.enabled` | `false` | 是否自动清理旧元数据 |
| `write.metadata.previous-versions-max` | `100` | 保留历史元数据版本数 |
| `read.split.target-size` | `134217728` (128MB) | 读取时的 split 大小 |
| `read.split.planning-lookback` | `10` | 规划 split 时回看的 snapshot 数 |

### 3.4 参数详解表 — Flink 写入配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `write.format.default` | `parquet` | 数据文件格式 |
| `write.target-file-size-bytes` | `536870912` | 目标文件大小 |
| `write.upsert.enabled` | `false` | Upsert 模式 |
| `write.distribution-mode` | `none` | 数据分布模式 |
| Checkpoint Interval | - | 每次 Checkpoint 生成一个 Iceberg Snapshot |

### 3.5 参数详解表 — Flink 流式读取配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `streaming` | `false` | 是否流式读取 |
| `monitor-interval` | `60s` | 监控新 snapshot 的间隔 |
| `start-snapshot-id` | - | 从指定 snapshot 开始消费 |
| `end-snapshot-id` | - | 消费到指定 snapshot 停止 |
| `start-tag` | - | 从指定 tag 开始 |

---

## 四、完整实战示例

### 4.1 实战场景：Kafka → Flink → Iceberg 实时入湖

#### 4.1.1 完整 SQL 作业

创建文件 `iceberg_streaming_write.sql`：

```sql
-- ============================================================
-- Flink SQL: Kafka 实时数据写入 Iceberg
-- ============================================================

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

-- 2. 创建 Kafka Source 表
CREATE TABLE default_catalog.default_database.kafka_user_behavior (
    user_id     STRING,
    item_id     STRING,
    category_id STRING,
    behavior    STRING,
    ts          BIGINT,                          -- Unix 时间戳（毫秒）
    event_time AS TO_TIMESTAMP_LTZ(ts, 3),       -- 转换为 TIMESTAMP
    proc_time AS PROCTIME(),
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

-- 3. 创建 Iceberg Sink 表
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

-- 4. 流式写入 Iceberg（Append 模式）
INSERT INTO user_behavior
SELECT
    user_id,
    item_id,
    category_id,
    behavior,
    event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt
FROM default_catalog.default_database.kafka_user_behavior;
```

#### 4.1.2 Upsert 写入示例（订单状态更新）

```sql
-- ============================================================
-- Upsert 写入：订单状态变更实时更新到 Iceberg
-- ============================================================

-- Kafka Source（订单状态变更事件）
CREATE TABLE default_catalog.default_database.kafka_order_status (
    order_id    STRING,
    user_id     STRING,
    status      STRING,
    amount      DECIMAL(10,2),
    update_time BIGINT,
    event_time AS TO_TIMESTAMP_LTZ(update_time, 3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'order_status_events',
    'properties.bootstrap.servers' = 'kafka01:9092',
    'properties.group.id' = 'flink-iceberg-upsert',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json'
);

-- Iceberg Upsert 目标表
CREATE TABLE IF NOT EXISTS order_status (
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
    'write.upsert.enabled' = 'true',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd'
);

-- Upsert 写入
INSERT INTO order_status
SELECT
    order_id,
    user_id,
    status,
    amount,
    event_time AS update_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt
FROM default_catalog.default_database.kafka_order_status;
```

#### 4.1.3 流式读取 Iceberg 表（Streaming Read）

```sql
-- ============================================================
-- 流式读取 Iceberg 表（增量消费新 Snapshot）
-- ============================================================

-- 创建流式读取视图
SELECT * FROM user_behavior /*+ OPTIONS(
    'streaming' = 'true',
    'monitor-interval' = '30s'
) */;

-- 流式读取 + 写入另一张表（ETL 链路）
INSERT INTO dwd_user_behavior_detail
SELECT
    user_id,
    item_id,
    category_id,
    behavior,
    event_time,
    dt
FROM user_behavior /*+ OPTIONS(
    'streaming' = 'true',
    'monitor-interval' = '10s',
    'start-snapshot-id' = '1234567890'  -- 可选：从指定 snapshot 开始
) */;
```

#### 4.1.4 批量读取 Iceberg 表

```sql
-- ============================================================
-- 批量读取：Time Travel 查询
-- ============================================================

-- 查询最新数据
SELECT behavior, COUNT(*) AS cnt
FROM user_behavior
WHERE dt = '2026-04-29'
GROUP BY behavior;

-- 时间旅行：查询指定 Snapshot
SELECT * FROM user_behavior /*+ OPTIONS(
    'snapshot-id' = '1234567890123456789'
) */;

-- 时间旅行：查询指定时间点
SELECT * FROM user_behavior /*+ OPTIONS(
    'as-of-timestamp' = '1714300800000'  -- Unix 毫秒时间戳
) */;

-- 增量查询：两个 Snapshot 之间的变更
SELECT * FROM user_behavior /*+ OPTIONS(
    'start-snapshot-id' = '111111',
    'end-snapshot-id' = '222222'
) */;
```

#### 4.1.5 DataStream API 写入 Iceberg

```java
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.table.data.GenericRowData;
import org.apache.flink.table.data.RowData;
import org.apache.flink.table.data.StringData;
import org.apache.flink.table.data.TimestampData;
import org.apache.iceberg.Schema;
import org.apache.iceberg.catalog.TableIdentifier;
import org.apache.iceberg.flink.CatalogLoader;
import org.apache.iceberg.flink.TableLoader;
import org.apache.iceberg.flink.sink.FlinkSink;
import org.apache.iceberg.types.Types;

import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.Map;

/**
 * DataStream API: 写入 Iceberg
 */
public class IcebergDataStreamWriteJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);  // 60s Checkpoint

        // 1. 构建 Kafka DataStream（简化示例）
        DataStream<RowData> dataStream = env
                .fromSource(/* Kafka Source */)
                .map(json -> {
                    GenericRowData row = new GenericRowData(6);
                    row.setField(0, StringData.fromString(json.get("user_id")));
                    row.setField(1, StringData.fromString(json.get("item_id")));
                    row.setField(2, StringData.fromString(json.get("category_id")));
                    row.setField(3, StringData.fromString(json.get("behavior")));
                    row.setField(4, TimestampData.fromLocalDateTime(LocalDateTime.now()));
                    row.setField(5, StringData.fromString("2026-04-29"));
                    return (RowData) row;
                });

        // 2. 配置 Iceberg Catalog
        Map<String, String> catalogProperties = new HashMap<>();
        catalogProperties.put("type", "iceberg");
        catalogProperties.put("catalog-type", "hive");
        catalogProperties.put("uri", "thrift://hive-metastore:9083");
        catalogProperties.put("warehouse", "hdfs:///warehouse/iceberg");

        CatalogLoader catalogLoader = CatalogLoader.hive(
                "hive_catalog", new org.apache.hadoop.conf.Configuration(), catalogProperties);

        TableLoader tableLoader = TableLoader.fromCatalog(
                catalogLoader, TableIdentifier.of("ods", "user_behavior"));

        // 3. 写入 Iceberg
        FlinkSink.forRowData(dataStream)
                .tableLoader(tableLoader)
                .overwrite(false)
                .distributionMode(DistributionMode.NONE)
                .writeParallelism(4)
                .build();

        env.execute("Iceberg-DataStream-Write-Job");
    }
}
```

#### 4.1.6 Application Mode on YARN 提交命令

```bash
# ============================================================
# Application Mode on YARN 提交
# ============================================================
export HADOOP_CLASSPATH=$(hadoop classpath)

# 收集所有依赖 JAR
ICEBERG_JAR=$FLINK_HOME/lib/iceberg-flink-runtime-1.17-1.5.2.jar
KAFKA_JAR=$FLINK_HOME/lib/flink-sql-connector-kafka-1.17.2.jar

# 方式一：SQL 作业提交（通过 sql-client 打包）
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
  -c com.example.IcebergDataStreamWriteJob \
  /path/to/flink-iceberg-job.jar

# 方式二：如果 JAR 在 HDFS 上
$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=8192m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=8 \
  -Dyarn.application.name="Flink-Iceberg-Production" \
  -Dyarn.application.queue=production \
  -Dyarn.provided.lib.dirs="hdfs:///flink/libs" \
  -Dexecution.checkpointing.interval=60000 \
  -Dstate.backend=rocksdb \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/iceberg \
  -c com.example.IcebergDataStreamWriteJob \
  hdfs:///flink/jars/flink-iceberg-job.jar
```

#### 4.1.7 验证结果

```bash
# ============================================================
# 验证 Iceberg 表数据
# ============================================================

# 1. Flink SQL Client 查询
$FLINK_HOME/bin/sql-client.sh embedded -l $FLINK_HOME/lib
# 在 SQL Client 中执行：
# SET execution.runtime-mode = batch;
# SELECT * FROM hive_catalog.ods.user_behavior LIMIT 10;
# SELECT behavior, COUNT(*) FROM hive_catalog.ods.user_behavior GROUP BY behavior;

# 2. 查看 HDFS 上的数据文件
hdfs dfs -ls -R /warehouse/iceberg/ods/user_behavior/data/

# 3. 查看 Iceberg 元数据（Snapshot 列表）
hdfs dfs -ls /warehouse/iceberg/ods/user_behavior/metadata/

# 4. 通过 Spark 查询验证（如果有 Spark 环境）
spark-sql --conf spark.sql.catalog.hive_catalog=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.hive_catalog.type=hive \
  --conf spark.sql.catalog.hive_catalog.uri=thrift://hive-metastore:9083 \
  -e "SELECT * FROM hive_catalog.ods.user_behavior LIMIT 10;"

# 5. 查看 Snapshot 历史
spark-sql -e "SELECT * FROM hive_catalog.ods.user_behavior.snapshots;"
```

### 4.2 Checkpoint 与 Iceberg Snapshot 的关系

```
Flink Checkpoint 流程与 Iceberg 写入的对应关系：

┌──────────────────────────────────────────────────────────────┐
│  Checkpoint N                                                │
│                                                              │
│  1. Barrier 到达所有 Sink 算子                               │
│  2. Iceberg Sink Writer flush 数据文件到 HDFS                │
│     → 生成 data-00001.parquet, data-00002.parquet ...        │
│  3. Iceberg Sink Committer 提交 Snapshot                     │
│     → 生成 snap-xxx.avro 元数据文件                          │
│  4. Checkpoint 完成                                          │
│                                                              │
│  关键点：                                                    │
│  - 每个 Checkpoint = 一个 Iceberg Snapshot                   │
│  - Checkpoint 间隔 = 数据可见延迟                            │
│  - Checkpoint 失败 → Snapshot 不提交 → 数据不可见            │
│  - 建议 Checkpoint 间隔 1~5 分钟                             │
└──────────────────────────────────────────────────────────────┘
```

| Checkpoint 间隔 | 数据可见延迟 | 小文件数量 | 建议场景 |
|----------------|-------------|-----------|---------|
| 30s | 30s | 多（需要频繁 Compaction） | 实时性要求极高 |
| 1min | 1min | 较多 | 准实时场景 |
| 5min | 5min | 适中 | 一般生产环境（推荐） |
| 10min | 10min | 少 | 批量导入场景 |

---

## 五、常见问题与排障

### 5.1 问题排查速查表

| 问题现象 | 可能原因 | 排查命令 / 解决方案 |
|---------|---------|-------------------|
| `NoSuchTableException` | Catalog 配置错误或表不存在 | 检查 Catalog 类型、URI、warehouse 路径 |
| Checkpoint 超时 | 数据量大，flush 慢 | 增大 Checkpoint timeout，减小并行度 |
| 小文件过多 | Checkpoint 间隔过短 | 增大 Checkpoint 间隔 + 配置 Compaction |
| Upsert 不生效 | 表格式版本为 v1 | 设置 `format-version = 2` |
| 数据延迟高 | Checkpoint 间隔过大 | 减小 Checkpoint 间隔 |
| `ClassNotFoundException: IcebergXxx` | 缺少 iceberg-flink-runtime jar | 检查 lib 目录下 jar 是否完整 |
| HMS 连不上 | thrift URI 错误 | `telnet hive-metastore 9083` 验证 |
| HDFS 写入权限不足 | 用户权限问题 | `hdfs dfs -ls /warehouse/iceberg` 检查权限 |
| 流式读取没有新数据 | monitor-interval 过大 | 减小 `monitor-interval` |

### 5.2 小文件治理

```sql
-- ============================================================
-- Iceberg Compaction（小文件合并）
-- ============================================================

-- 方式一：Flink SQL 触发 Rewrite（需要 Iceberg 1.4+）
CALL hive_catalog.system.rewrite_data_files(
    table => 'ods.user_behavior',
    strategy => 'binpack',
    options => map(
        'target-file-size-bytes', '134217728',    -- 128MB
        'min-file-size-bytes', '67108864',         -- 64MB
        'max-file-size-bytes', '268435456'         -- 256MB
    )
);

-- 方式二：Spark 触发（更成熟）
-- spark-sql -e "
-- CALL hive_catalog.system.rewrite_data_files(table => 'ods.user_behavior');
-- "

-- 方式三：定时清理过期 Snapshot
CALL hive_catalog.system.expire_snapshots(
    table => 'ods.user_behavior',
    older_than => TIMESTAMP '2026-04-22 00:00:00',
    retain_last => 5
);

-- 方式四：清理孤立文件
CALL hive_catalog.system.remove_orphan_files(
    table => 'ods.user_behavior',
    older_than => TIMESTAMP '2026-04-22 00:00:00'
);
```

---

## 六、生产最佳实践

### 6.1 资源配置推荐

| 场景 | JM 内存 | TM 内存 | Parallelism | Checkpoint 间隔 |
|------|---------|---------|-------------|----------------|
| 小流量（< 5K TPS） | 2G | 4G | 2-4 | 2min |
| 中流量（5K ~ 50K TPS） | 2G | 8G | 4-8 | 1min |
| 大流量（50K ~ 500K TPS） | 4G | 16G | 8-16 | 1min |
| 超大流量（> 500K TPS） | 4G | 32G | 16-32 | 2min |

### 6.2 写入优化

```sql
-- 生产环境推荐配置
CREATE TABLE production_table (
    ...
) WITH (
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728',     -- 128MB
    'write.distribution-mode' = 'hash',               -- 按分区键 hash 分布
    'write.metadata.delete-after-commit.enabled' = 'true',
    'write.metadata.previous-versions-max' = '20',
    -- 分区排序优化查询性能
    'write.parquet.row-group-size-bytes' = '134217728'
);
```

### 6.3 Checkpoint 配置

```bash
# flink-conf.yaml 生产推荐
execution.checkpointing.interval: 60000        # 1 分钟
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 300000        # 5 分钟超时
execution.checkpointing.min-pause: 30000       # 最小间隔 30s
execution.checkpointing.max-concurrent-checkpoints: 1
state.backend: rocksdb
state.checkpoints.dir: hdfs:///flink/checkpoints
state.backend.rocksdb.memory.managed: true
```

### 6.4 监控告警

```bash
# 关键监控指标
# 1. Iceberg 写入：
#    - committedFilesCount（每次 Checkpoint 提交的文件数）
#    - committedDataFilesCount / committedDeleteFilesCount
#    - elapsedSecondsSinceLastSuccessfulCommit（上次成功提交距今秒数）

# 2. 告警规则示例：
#    - 如果 elapsedSecondsSinceLastSuccessfulCommit > 300 → 报警
#    - 如果 committedFilesCount 每次 > 100 → 小文件过多告警
#    - Checkpoint 连续失败 3 次 → 告警
```

---

## 七、举一反三

### 7.1 对比：Iceberg vs Hudi vs Delta Lake

| 对比维度 | Iceberg | Hudi | Delta Lake |
|---------|---------|------|------------|
| **Flink 支持** | 官方一等公民 | 官方支持 | 社区支持 |
| **Upsert 性能** | v2 支持 equality delete | COW/MOR 两种模式 | 基于 log |
| **Schema Evolution** | 完整支持 | 支持 | 支持 |
| **Time Travel** | Snapshot ID / Timestamp | Instant Time | Version |
| **Compaction** | rewrite_data_files | 自动/手动 | OPTIMIZE |
| **引擎兼容性** | Spark/Flink/Trino/Hive | Spark/Flink/Hive | Spark 最佳 |
| **分区演进** | 支持 | 不支持 | 不支持 |
| **Hidden Partition** | 支持 | 不支持 | 不支持 |

### 7.2 面试高频题

**Q1: Flink 写入 Iceberg 是如何保证 Exactly-Once 的？**

> 通过 Flink 的两阶段提交协议：Checkpoint 时 Writer 算子先将数据文件 flush 到 HDFS（预提交），Committer 算子在所有 Writer 完成后提交 Iceberg Snapshot。如果 Checkpoint 失败，数据文件虽然存在于 HDFS 但不会被 Snapshot 引用，后续可被 orphan file 清理。

**Q2: Iceberg format-version 1 和 2 有什么区别？**

> v1 只支持 append 和 overwrite 操作；v2 引入了 row-level delete（equality delete 和 position delete），支持 Upsert 和 Delete 操作。生产推荐使用 v2。

**Q3: 如何解决 Iceberg 小文件问题？**

> 三管齐下：1) 适当增大 Checkpoint 间隔减少 Snapshot 频率；2) 增大 `write.target-file-size-bytes`；3) 定期运行 `rewrite_data_files` 做 Compaction。

**Q4: Iceberg 的 Hidden Partitioning 是什么？**

> 传统 Hive 分区需要用户显式指定分区值，而 Iceberg 的 Hidden Partitioning 可以自动从字段值推导分区（如 `day(ts)` 自动按天分区），查询时无需感知分区列，引擎自动裁剪。

### 7.3 思考题

1. **Checkpoint 间隔权衡**：某实时入湖场景要求数据可见延迟 < 30s，但 Checkpoint 间隔设为 30s 会导致大量小文件。你会如何解决？
2. **多表入湖**：如果有 20 张 Kafka Topic 要同时写入 20 张 Iceberg 表，是部署 20 个 Flink 作业还是一个作业？各有什么优劣？
3. **Upsert 性能**：Iceberg v2 的 equality delete 在大数据量下可能导致读取性能下降，你会如何优化？
4. **跨引擎一致性**：Flink 写入 Iceberg 表后，Spark 能立即查到吗？如果不能，需要怎么处理？

---

> 📝 **教案小结**：本教案覆盖了 Flink + Iceberg 流批一体的完整使用姿势，包括 HiveCatalog/HadoopCatalog 配置、流式/批量写入、Upsert、流式读取、时间旅行、小文件治理。核心要点：**每个 Checkpoint 等于一个 Snapshot，Checkpoint 间隔决定数据可见延迟和小文件数量，format-version=2 是 Upsert 的前提**。
