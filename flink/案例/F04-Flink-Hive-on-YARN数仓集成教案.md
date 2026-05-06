# [教案] Flink on YARN — Hive 数仓集成使用姿势

> 🎯 教学目标：掌握 Flink 与 Hive 的集成使用方法，包括 HiveCatalog 配置、读写 Hive 表、流式写入分区、Lookup Join 维表关联 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

Hive 是大数据生态中的数仓核心，几乎所有公司的离线数仓都建在 Hive 上。Flink 与 Hive 集成后可以实现：

| 场景 | 架构 |
|------|------|
| 实时入湖 | Kafka → Flink → Hive 表（流式写入分区） |
| 批流一体 | 同一套 SQL 既能跑批（读 Hive）又能跑流（读 Kafka） |
| 维表关联 | 实时流 JOIN Hive 维表（Lookup Join） |
| 数仓加速 | 用 Flink 替代 Hive MR/Tez 做批处理 |
| 元数据复用 | 通过 HiveCatalog 共享 Hive Metastore 元数据 |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17+ / 1.18 | - |
| Hive | 2.3.x / 3.1.x | 推荐 Hive 3.1 |
| Hadoop/YARN | 2.8+ / 3.x | HDFS + YARN |
| Hive Metastore | 独立运行 | 端口 9083 |
| Java | JDK 8 / JDK 11 | - |

### 2.2 需要的 JAR 包

```bash
# ============================================================
# Hive Connector（必须！uber jar）
# ============================================================
# Hive 3.1.x 版本
wget https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-hive-3.1.3_2.12/1.18.1/flink-sql-connector-hive-3.1.3_2.12-1.18.1.jar \
  -P $FLINK_HOME/lib/

# Hive 2.3.x 版本
# wget https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-hive-2.3.10_2.12/1.18.1/flink-sql-connector-hive-2.3.10_2.12-1.18.1.jar \
#   -P $FLINK_HOME/lib/

# ============================================================
# 其他格式支持（按需）
# ============================================================
# Parquet
cp $FLINK_HOME/opt/flink-sql-parquet-*.jar $FLINK_HOME/lib/
# ORC
cp $FLINK_HOME/opt/flink-sql-orc-*.jar $FLINK_HOME/lib/
```

### 2.3 环境准备

```bash
# 环境变量
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)
export HIVE_HOME=/opt/hive
export HIVE_CONF_DIR=$HIVE_HOME/conf

# 将 hive-site.xml 放入 Flink conf 目录（关键！）
cp $HIVE_HOME/conf/hive-site.xml $FLINK_HOME/conf/

# 验证 Hive Metastore 是否运行
netstat -nltp | grep 9083
# 或
hive --service metastore --help

# 验证 Hive 连通性
beeline -u "jdbc:hive2://hiveserver2-host:10000" -e "SHOW DATABASES;"
```

### 2.4 hive-site.xml 关键配置

```xml
<!-- $FLINK_HOME/conf/hive-site.xml -->
<configuration>
    <property>
        <name>hive.metastore.uris</name>
        <value>thrift://metastore-host:9083</value>
    </property>
    <property>
        <name>hive.metastore.warehouse.dir</name>
        <value>/user/hive/warehouse</value>
    </property>
</configuration>
```

---

## 三、核心使用方式

### 3.1 HiveCatalog 配置与使用

```sql
-- ============================================================
-- 创建 HiveCatalog
-- ============================================================
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/opt/hive/conf'
    -- 'hadoop-conf-dir' = '/opt/hadoop/etc/hadoop'  -- 可选
);

-- 使用 HiveCatalog
USE CATALOG hive_catalog;
SHOW DATABASES;
USE my_database;
SHOW TABLES;

-- 查看表结构
DESCRIBE my_hive_table;
SHOW CREATE TABLE my_hive_table;
```

### 3.2 读取 Hive 表

#### 批模式读取（标准方式）

```sql
-- ============================================================
-- 批模式读取 Hive 表
-- ============================================================
SET 'execution.runtime-mode' = 'batch';

-- 直接查询 Hive 表
SELECT * FROM hive_catalog.my_db.user_info WHERE dt = '2024-01-15' LIMIT 10;

-- 聚合查询
SELECT
    dt,
    COUNT(*) AS user_count,
    SUM(amount) AS total_amount
FROM hive_catalog.my_db.order_fact
WHERE dt BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY dt
ORDER BY dt;
```

#### 流模式读取 Hive 分区（Streaming Read）

```sql
-- ============================================================
-- 流式读取 Hive 分区表（监听新分区到达）
-- ============================================================
SET 'execution.runtime-mode' = 'streaming';

-- Hive 分区表需要配置 streaming-source 参数
CREATE TABLE IF NOT EXISTS hive_catalog.my_db.streaming_orders (
    order_id    BIGINT,
    user_id     BIGINT,
    amount      DECIMAL(10,2),
    order_time  STRING
) PARTITIONED BY (dt STRING, hr STRING)
TBLPROPERTIES (
    'streaming-source.enable' = 'true',
    'streaming-source.monitor-interval' = '1min',
    'streaming-source.partition-order' = 'partition-name',
    'streaming-source.consume-start-offset' = '2024-01-15'
);

-- 或者用 Table Hints 临时开启流式读取
SELECT * FROM hive_catalog.my_db.order_fact
/*+ OPTIONS(
    'streaming-source.enable' = 'true',
    'streaming-source.monitor-interval' = '60s',
    'streaming-source.partition-order' = 'partition-name'
) */;
```

**流式读取参数详解**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `streaming-source.enable` | 开启流式读取 | true | - |
| `streaming-source.monitor-interval` | 新分区检测间隔 | 1min-5min | 越短发现越快，开销越大 |
| `streaming-source.partition-order` | 分区排序方式 | partition-name | 按分区名字典序 |
| `streaming-source.consume-start-offset` | 起始分区 | 具体分区值 | 避免读取全部历史分区 |

### 3.3 写入 Hive 表（流式写入）

```sql
-- ============================================================
-- 流式写入 Hive 分区表
-- ============================================================

-- 1. 在 Hive Catalog 下建表
USE CATALOG hive_catalog;
USE my_db;

CREATE TABLE IF NOT EXISTS dwd_events (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    page_url    STRING,
    event_time  TIMESTAMP(3)
) PARTITIONED BY (dt STRING, hr STRING)
STORED AS PARQUET
TBLPROPERTIES (
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '5 min',
    'sink.partition-commit.watermark-time-zone' = 'Asia/Shanghai',
    'sink.partition-commit.policy.kind' = 'metastore,success-file',
    'sink.rolling-policy.file-size' = '128MB',
    'sink.rolling-policy.rollover-interval' = '15 min',
    'sink.rolling-policy.check-interval' = '1 min',
    'auto-compaction' = 'true',
    'compaction.file-size' = '256MB'
);

-- 2. 切换到 default_catalog 创建 Kafka Source
USE CATALOG default_catalog;

CREATE TABLE kafka_events (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    page_url    STRING,
    event_time  TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_events',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092',
    'properties.group.id' = 'flink-hive-writer',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- 3. 流式写入 Hive
INSERT INTO hive_catalog.my_db.dwd_events
SELECT
    event_id,
    user_id,
    event_type,
    page_url,
    event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(event_time, 'HH') AS hr
FROM kafka_events;
```

**分区提交参数详解**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `sink.partition-commit.trigger` | 提交触发器 | partition-time | 基于 Watermark 判断分区完成 |
| `sink.partition-commit.delay` | 提交延迟 | 5min | 等待迟到数据 |
| `sink.partition-commit.policy.kind` | 提交策略 | metastore,success-file | 通知 Metastore + 写 _SUCCESS |
| `sink.rolling-policy.file-size` | 文件滚动大小 | 128MB | 避免小文件 |
| `sink.rolling-policy.rollover-interval` | 文件滚动间隔 | 15min | 控制文件关闭频率 |
| `auto-compaction` | 自动合并小文件 | true | Flink 1.15+ 支持 |
| `compaction.file-size` | 合并目标大小 | 256MB | 合并后的文件大小 |

### 3.4 Hive 维表 Lookup Join

```sql
-- ============================================================
-- Lookup Join: 实时流关联 Hive 维表
-- ============================================================

-- Hive 维表（需要配置 lookup 参数）
-- 假设 hive_catalog.my_db.dim_user 已存在

-- 方式1: Table Hints 指定 Lookup 参数
SELECT
    e.event_id,
    e.user_id,
    u.user_name,
    u.city,
    e.event_type,
    e.event_time
FROM kafka_events AS e
JOIN hive_catalog.my_db.dim_user
/*+ OPTIONS(
    'streaming-source.enable' = 'true',
    'streaming-source.partition.include' = 'latest',
    'streaming-source.monitor-interval' = '1h',
    'lookup.join.cache.ttl' = '12h'
) */ FOR SYSTEM_TIME AS OF e.event_time AS u
ON e.user_id = u.user_id;

-- 方式2: 在建表时指定 TBLPROPERTIES
-- ALTER TABLE dim_user SET TBLPROPERTIES (
--     'streaming-source.enable' = 'true',
--     'streaming-source.partition.include' = 'latest',
--     'streaming-source.monitor-interval' = '1h',
--     'lookup.join.cache.ttl' = '12h'
-- );
```

**Lookup Join 参数详解**：

| 参数 | 含义 | 推荐值 | 说明 |
|------|------|--------|------|
| `streaming-source.partition.include` | 加载分区范围 | latest | 只加载最新分区 |
| `streaming-source.monitor-interval` | 刷新间隔 | 1h | 维表更新频率 |
| `lookup.join.cache.ttl` | 缓存过期时间 | 12h | 过期后重新加载 |

### 3.5 Hive UDF 在 Flink 中使用

```sql
-- ============================================================
-- 使用 Hive 已注册的 UDF
-- ============================================================
USE CATALOG hive_catalog;

-- Hive 内置函数可直接使用
SELECT
    user_id,
    regexp_extract(url, '.*/(.*)', 1) AS page_name,
    from_unixtime(ts, 'yyyy-MM-dd HH:mm:ss') AS event_time
FROM my_table;

-- 自定义 UDF（需要 UDF JAR 在 classpath 中）
-- 如果 Hive 中已注册，通过 HiveCatalog 可以直接调用
CREATE FUNCTION my_udf AS 'com.example.MyUDF'
USING JAR 'hdfs:///udf/my-udf.jar';

SELECT my_udf(column1) FROM my_table;
```

---

## 四、完整实战示例

### 4.1 场景描述

完整的实时入 Hive 数仓链路：
- Source: Kafka `user_orders` Topic
- 处理: 数据清洗 + 维表关联（Hive dim_product）
- Sink: Hive DWD 层分区表

### 4.2 完整 SQL 脚本

创建 `/opt/flink/scripts/hive-etl.sql`：

```sql
-- ============================================================
-- hive-etl.sql — Kafka 实时入 Hive 数仓
-- ============================================================

-- 基础配置
SET 'execution.runtime-mode' = 'streaming';
SET 'parallelism.default' = '8';
SET 'table.local-time-zone' = 'Asia/Shanghai';

-- Checkpoint（写 Hive 必须开启！）
SET 'execution.checkpointing.interval' = '120s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints/hive-etl';

-- 注册 HiveCatalog
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'dwd',
    'hive-conf-dir' = '/opt/hive/conf'
);

-- Kafka Source（default catalog）
CREATE TABLE kafka_orders (
    order_id    BIGINT,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(10, 2),
    order_time  TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_orders',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-hive-etl',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- 确保 Hive Sink 表存在
-- (通常在 Hive 中预先建好，这里用 IF NOT EXISTS)

-- 写入 Hive DWD 层
INSERT INTO hive_catalog.dwd.dwd_order_detail
SELECT
    o.order_id,
    o.user_id,
    o.product_id,
    o.amount,
    o.order_time,
    DATE_FORMAT(o.order_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(o.order_time, 'HH') AS hr
FROM kafka_orders AS o
WHERE o.order_id IS NOT NULL
  AND o.amount > 0;
```

### 4.3 Application Mode 提交命令

```bash
# ============================================================
# Application Mode 提交 Hive ETL 作业
# ============================================================
$FLINK_HOME/bin/sql-client.sh \
  -Dexecution.target=yarn-application \
  -Dyarn.application.name="realtime-hive-etl" \
  -Dyarn.application.queue=production \
  -Djobmanager.memory.process.size=4096m \
  -Dtaskmanager.memory.process.size=8192m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dyarn.ship-files="/opt/hive/conf/hive-site.xml" \
  -f /opt/flink/scripts/hive-etl.sql

# 或者用 flink run-application（DataStream API 打的 JAR）
$FLINK_HOME/bin/flink run-application \
  -t yarn-application \
  -d \
  -Dyarn.application.name="hive-etl-datastream" \
  -Djobmanager.memory.process.size=4096m \
  -Dtaskmanager.memory.process.size=8192m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=8 \
  -c com.example.flink.HiveETLJob \
  hdfs:///flink/jars/hive-etl-job.jar
```

### 4.4 验证结果

```bash
# 在 Hive 中验证数据
beeline -u "jdbc:hive2://hiveserver2:10000" -e "
SELECT COUNT(*) FROM dwd.dwd_order_detail WHERE dt = '2024-01-15';
SHOW PARTITIONS dwd.dwd_order_detail;
"

# 检查 HDFS 上的文件
hdfs dfs -ls /user/hive/warehouse/dwd.db/dwd_order_detail/dt=2024-01-15/hr=10/

# 检查 _SUCCESS 文件（分区提交成功标志）
hdfs dfs -ls /user/hive/warehouse/dwd.db/dwd_order_detail/dt=2024-01-15/hr=09/_SUCCESS
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `NoSuchObjectException: database not found` | HiveCatalog 连接 Metastore 失败 | 检查 `hive-site.xml` 和 Metastore 服务 |
| 写入 Hive 后查询为空 | 分区未提交到 Metastore | 检查 `sink.partition-commit.policy.kind` 包含 `metastore` |
| 小文件过多 | rolling-policy 配置过小或 CP 太频繁 | 增大 `sink.rolling-policy.file-size`，开启 `auto-compaction` |
| `ClassNotFoundException: OrcSerde` | 缺少 ORC 相关 JAR | 添加 `flink-sql-orc-*.jar` 到 lib |
| Lookup Join 数据不一致 | 维表缓存过期 | 调小 `lookup.join.cache.ttl` 或 `streaming-source.monitor-interval` |
| Hive 表 Schema 变更后 Flink 不识别 | Catalog 缓存 | 重启作业或使用 `ALTER TABLE ... SET TBLPROPERTIES` |
| `Permission denied` 写入 HDFS | 用户权限不足 | 检查 HDFS 目录权限，确保 Flink 用户有写权限 |
| Checkpoint 很慢 | 写入大量小文件 | 增大 rolling-policy 参数，减少文件数 |

---

## 六、生产最佳实践

### 6.1 资源配置建议

```yaml
# Hive ETL 作业推荐配置
jobmanager.memory.process.size: 4096m
taskmanager.memory.process.size: 8192m
taskmanager.numberOfTaskSlots: 4
parallelism.default: 8

# Hive 写入特有配置
execution.checkpointing.interval: 120000   # 2min（写 Hive 不宜太频繁）
sink.rolling-policy.file-size: 128MB
sink.rolling-policy.rollover-interval: 15min
auto-compaction: true
compaction.file-size: 256MB
```

### 6.2 关键参数调优

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `execution.checkpointing.interval` | 120s+ | Hive 写入不宜太频繁 |
| `sink.rolling-policy.file-size` | 128MB | 避免小文件 |
| `sink.partition-commit.trigger` | partition-time | 基于 Watermark |
| `sink.partition-commit.delay` | 5min | 等待迟到数据 |
| `auto-compaction` | true | 自动合并小文件 |
| `table.exec.hive.fallback-mapred-reader` | true | 兼容旧格式 |

### 6.3 监控与告警

```bash
# 检查 Hive 分区是否正常产出
# 定时脚本检查最新分区
LATEST_PARTITION=$(hive -e "SHOW PARTITIONS dwd.dwd_order_detail" 2>/dev/null | tail -1)
echo "Latest partition: $LATEST_PARTITION"

# 检查分区数据量
hive -e "SELECT COUNT(*) FROM dwd.dwd_order_detail WHERE dt = CURRENT_DATE();"

# 检查 HDFS 文件大小（是否有小文件问题）
hdfs dfs -du -s -h /user/hive/warehouse/dwd.db/dwd_order_detail/dt=$(date +%Y-%m-%d)/
```

---

## 七、举一反三

### 7.1 与其他组件的对比

| 维度 | Flink + Hive | Spark + Hive | Hive on Tez | Flink + Iceberg/Hudi |
|------|-------------|--------------|-------------|---------------------|
| 实时写入 | ✅ 流式 | ⚠️ micro-batch | ❌ 批 | ✅ 流式 |
| 批处理 | ✅ | ✅ | ✅ | ✅ |
| ACID | ❌ | ❌ | ✅ Hive 3 | ✅ 原生 |
| 小文件处理 | auto-compaction | 需额外 compact | 需手动 | 自动 compaction |
| 元数据 | HiveCatalog | 直连 HMS | 直连 HMS | HMS/自带 |

### 7.2 面试高频题

**Q1: Flink 写入 Hive 分区表的原理？**
> Flink 使用 StreamingFileSink 将数据写入 HDFS 路径（对应 Hive 分区目录），Checkpoint 时文件从 in-progress 变为 finished，分区完成后通过 Metastore API 注册分区（ADD PARTITION），使 Hive 可查询。

**Q2: 如何解决 Flink 写入 Hive 的小文件问题？**
> (1) 增大 `sink.rolling-policy.file-size`（如 128MB/256MB）；(2) 增大 Checkpoint 间隔（2-5min）；(3) 开启 `auto-compaction`；(4) 配合下游 Hive compaction 任务定期合并。

**Q3: HiveCatalog 和 default_catalog 有什么区别？**
> default_catalog 是内存 Catalog，表定义随作业消亡而丢失。HiveCatalog 将表元数据持久化到 Hive Metastore，作业重启后表定义仍在，且可与 Hive/Spark 等其他引擎共享。

### 7.3 思考题

1. 设计一个 Flink 实时数仓分层架构：ODS(Kafka) → DWD(Hive) → DWS(Hive) → ADS(MySQL)
2. 如何用 Flink 实现 Hive 表的实时去重（Exactly-Once + Hive ACID？）
3. 比较 Flink + Hive 与 Flink + Iceberg 的优缺点

---

> 📝 **教案总结**：Flink + Hive 是实时入湖的主流方案。核心要点：(1) HiveCatalog 实现元数据共享；(2) 分区提交策略决定数据可见性；(3) rolling-policy + auto-compaction 解决小文件；(4) Lookup Join 实现维表关联。
