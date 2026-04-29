# [教案] Flink on YARN — Hive 数仓集成使用姿势

> 🎯 教学目标：掌握 Flink 与 Hive 的深度集成，包括 HiveCatalog 配置、读写 Hive 表、流式分区读取、Lookup Join 维表关联、Hive UDF 复用 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 什么场景需要 Flink + Hive？

**生活类比**：Hive 就像一个巨大的"档案仓库"，存储了公司多年的历史数据。Flink 是一条"高速传送带"，实时处理流式数据。当你需要：
- 实时流数据关联历史维表（如：实时订单流关联用户画像表）
- 将实时计算结果直接写入 Hive 供离线报表查询
- 用 Flink SQL 统一批流查询 Hive 数仓

这时就需要 Flink + Hive 集成。

### 1.2 核心能力一览

| 能力 | 说明 |
|------|------|
| HiveCatalog | 复用 Hive Metastore 元数据，表/库/分区统一管理 |
| 批量读 Hive | 全量扫描 Hive 表（等价于 Hive 查询） |
| 流式读 Hive | 监听分区变化，增量读取新分区数据 |
| 写 Hive 表 | Streaming Sink 写入 + 分区提交策略 |
| Lookup Join | 实时流关联 Hive 维表 |
| Hive UDF | 直接复用已有的 Hive UDF/UDTF/UDAF |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.16+ | 推荐 1.17/1.18 |
| Hive | 2.3.x / 3.1.x | 需要 Hive Metastore 服务运行 |
| Hadoop | 3.x | YARN + HDFS |
| Java | 8/11 | 与集群一致 |

### 2.2 JAR 依赖准备

```bash
# Flink Hive Connector（根据 Hive 版本选择）
# Hive 3.1.x
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-hive-3.1.3_2.12/1.17.2/flink-sql-connector-hive-3.1.3_2.12-1.17.2.jar

# Hive 2.3.x
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-hive-2.3.10_2.12/1.17.2/flink-sql-connector-hive-2.3.10_2.12-1.17.2.jar

# 放到 Flink 的 lib 目录
cp flink-sql-connector-hive-*.jar $FLINK_HOME/lib/

# 确保 Hadoop 相关 JAR 可用
export HADOOP_CLASSPATH=`hadoop classpath`
```

### 2.3 Hive 配置文件准备

```bash
# 拷贝 hive-site.xml 到 Flink conf 目录
cp $HIVE_HOME/conf/hive-site.xml $FLINK_HOME/conf/

# 或在提交时通过 -yD 指定
# hive-site.xml 关键配置项：
cat $HIVE_HOME/conf/hive-site.xml
```

`hive-site.xml` 关键配置：

```xml
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

### 2.4 启动 Hive Metastore

```bash
# 确保 Hive Metastore 服务已启动
hive --service metastore &

# 验证
netstat -tlnp | grep 9083
```

---

## 三、核心使用方式

### 3.1 HiveCatalog 配置

#### SQL Client 方式

```sql
-- 创建 HiveCatalog
CREATE CATALOG my_hive WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/etc/hive/conf'
);

-- 切换到 HiveCatalog
USE CATALOG my_hive;

-- 查看数据库
SHOW DATABASES;

-- 切换数据库
USE my_database;

-- 查看表
SHOW TABLES;
```

#### Java/DataStream API 方式

```java
import org.apache.flink.table.api.EnvironmentSettings;
import org.apache.flink.table.api.TableEnvironment;
import org.apache.flink.table.catalog.hive.HiveCatalog;

public class FlinkHiveIntegration {
    public static void main(String[] args) {
        EnvironmentSettings settings = EnvironmentSettings.inStreamingMode();
        TableEnvironment tableEnv = TableEnvironment.create(settings);

        // 创建 HiveCatalog
        String catalogName = "my_hive";
        String defaultDatabase = "default";
        String hiveConfDir = "/etc/hive/conf";

        HiveCatalog hiveCatalog = new HiveCatalog(catalogName, defaultDatabase, hiveConfDir);
        tableEnv.registerCatalog(catalogName, hiveCatalog);
        tableEnv.useCatalog(catalogName);
        tableEnv.useDatabase("my_database");

        // 后续可以直接用 SQL 操作 Hive 表
        tableEnv.executeSql("SELECT * FROM my_table LIMIT 10").print();
    }
}
```

### 3.2 参数详解表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `type` | - | 固定 `hive` |
| `default-database` | `default` | 默认数据库 |
| `hive-conf-dir` | - | hive-site.xml 所在目录 |
| `hive-version` | 自动检测 | 显式指定 Hive 版本 |
| `hadoop-conf-dir` | - | core-site.xml/hdfs-site.xml 目录 |

### 3.3 Hive 方言支持

```sql
-- 切换到 Hive 方言（支持 Hive DDL 语法）
SET table.sql-dialect = hive;

-- 使用 Hive 语法建表
CREATE TABLE hive_table (
    id INT,
    name STRING,
    dt STRING
)
PARTITIONED BY (dt)
STORED AS PARQUET;

-- 切回 Flink 方言（默认）
SET table.sql-dialect = default;
```

---

## 四、完整实战示例

### 4.1 场景一：批量读取 Hive 表

#### SQL 写法

```sql
-- 启动 SQL Client（on YARN Session）
yarn-session.sh -d -nm flink-hive-session -jm 2048 -tm 4096 -s 2
sql-client.sh -s yarn-session

-- 注册 HiveCatalog
CREATE CATALOG my_hive WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/etc/hive/conf'
);

USE CATALOG my_hive;
USE my_database;

-- 设置为批模式读取
SET execution.runtime-mode = batch;

-- 查询 Hive 表
SELECT department, COUNT(*) AS cnt, AVG(salary) AS avg_salary
FROM employees
WHERE dt = '2024-01-15'
GROUP BY department
ORDER BY avg_salary DESC;
```

#### Java 写法

```java
import org.apache.flink.table.api.*;
import org.apache.flink.table.catalog.hive.HiveCatalog;

public class BatchReadHive {
    public static void main(String[] args) {
        // 批模式
        EnvironmentSettings settings = EnvironmentSettings.inBatchMode();
        TableEnvironment tableEnv = TableEnvironment.create(settings);

        // 注册 HiveCatalog
        HiveCatalog hiveCatalog = new HiveCatalog("my_hive", "default", "/etc/hive/conf");
        tableEnv.registerCatalog("my_hive", hiveCatalog);
        tableEnv.useCatalog("my_hive");
        tableEnv.useDatabase("my_database");

        // 查询
        TableResult result = tableEnv.executeSql(
            "SELECT department, COUNT(*) AS cnt, AVG(salary) AS avg_salary " +
            "FROM employees WHERE dt = '2024-01-15' " +
            "GROUP BY department ORDER BY avg_salary DESC"
        );
        result.print();
    }
}
```

#### 提交命令

```bash
flink run -m yarn-cluster \
    -ynm "batch-read-hive" \
    -yjm 2048 -ytm 4096 \
    -yD execution.runtime-mode=batch \
    -c com.example.BatchReadHive \
    my-flink-job.jar
```

### 4.2 场景二：流式监听 Hive 新分区

这是最强大的功能之一：Flink 持续监听 Hive 分区表，一旦有新分区写入立即读取。

#### SQL 写法

```sql
-- 流模式
SET execution.runtime-mode = streaming;

-- 配置流式读取 Hive 分区表
CREATE TABLE hive_streaming_source (
    user_id BIGINT,
    item_id BIGINT,
    action STRING,
    ts TIMESTAMP(3)
)
PARTITIONED BY (dt STRING, hr STRING)
WITH (
    'connector' = 'hive',
    'streaming-source.enable' = 'true',
    'streaming-source.monitor-interval' = '1 min',
    'streaming-source.partition-order' = 'partition-name',
    'streaming-source.consume-start-offset' = '2024-01-15'
);

-- 或者直接对已有 Hive 表设置 Hint
SELECT * FROM my_hive_table
/*+ OPTIONS(
    'streaming-source.enable' = 'true',
    'streaming-source.monitor-interval' = '60s',
    'streaming-source.partition-order' = 'partition-name'
) */;
```

#### 流式读取参数详解

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `streaming-source.enable` | `false` | 开启流式读取 |
| `streaming-source.monitor-interval` | `1m` | 分区发现间隔 |
| `streaming-source.partition-order` | `partition-name` | 分区排序方式: partition-name/create-time/partition-time |
| `streaming-source.consume-start-offset` | - | 起始消费偏移（分区名） |
| `streaming-source.partition.include` | `all` | 分区包含策略: all/latest |

### 4.3 场景三：流式写入 Hive 表

#### SQL 写法

```sql
-- Kafka Source → Hive Sink
-- 1. 创建 Kafka Source 表
CREATE TABLE kafka_orders (
    order_id BIGINT,
    user_id BIGINT,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka01:9092',
    'properties.group.id' = 'flink-hive-writer',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json'
);

-- 2. 创建 Hive Sink 表（带分区提交策略）
SET table.sql-dialect = hive;
CREATE TABLE hive_orders (
    order_id BIGINT,
    user_id BIGINT,
    amount DECIMAL(10, 2),
    order_time TIMESTAMP(3)
)
PARTITIONED BY (dt STRING, hr STRING)
STORED AS PARQUET
TBLPROPERTIES (
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '1 h',
    'sink.partition-commit.watermark-time-zone' = 'Asia/Shanghai',
    'sink.partition-commit.policy.kind' = 'metastore,success-file',
    'partition.time-extractor.timestamp-pattern' = '$dt $hr:00:00'
);
SET table.sql-dialect = default;

-- 3. 流式插入
INSERT INTO hive_orders
SELECT
    order_id,
    user_id,
    amount,
    order_time,
    DATE_FORMAT(order_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(order_time, 'HH') AS hr
FROM kafka_orders;
```

#### 分区提交策略参数

| 参数 | 说明 |
|------|------|
| `sink.partition-commit.trigger` | 触发方式: `process-time`/`partition-time` |
| `sink.partition-commit.delay` | 延迟时间（等分区数据完整后提交） |
| `sink.partition-commit.policy.kind` | 提交动作: `metastore`(通知HMS)/`success-file`(写_SUCCESS) |
| `sink.partition-commit.policy.class` | 自定义提交策略类 |
| `sink.partition-commit.success-file.name` | 成功标记文件名, 默认 `_SUCCESS` |
| `auto-compaction` | 是否开启小文件自动合并 |
| `compaction.file-size` | 目标文件大小, 默认 `128MB` |

### 4.4 场景四：Hive 维表 Lookup Join

```sql
-- 订单流表
CREATE TABLE order_stream (
    order_id BIGINT,
    user_id BIGINT,
    amount DECIMAL(10, 2),
    proc_time AS PROCTIME()
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka01:9092',
    'format' = 'json'
);

-- Hive 维表（开启 Lookup 模式）
CREATE TABLE dim_user (
    user_id BIGINT,
    user_name STRING,
    city STRING,
    level STRING
) WITH (
    'connector' = 'hive',
    'streaming-source.enable' = 'true',
    'streaming-source.partition.include' = 'latest',
    'streaming-source.monitor-interval' = '12 h',
    'lookup.join.cache.ttl' = '1 h'
);

-- Temporal Join（Lookup Join）
SELECT
    o.order_id,
    o.amount,
    u.user_name,
    u.city,
    u.level
FROM order_stream AS o
JOIN dim_user FOR SYSTEM_TIME AS OF o.proc_time AS u
    ON o.user_id = u.user_id;
```

### 4.5 场景五：复用 Hive UDF

```sql
-- 加载 Hive UDF（自动从 HiveCatalog 加载）
-- 方式1：自动加载（已在 Hive 中注册的 UDF 直接可用）
USE CATALOG my_hive;
SELECT my_custom_udf(name) FROM my_table;

-- 方式2：手动创建 Hive UDF
CREATE FUNCTION my_upper AS 'com.example.hive.udf.MyUpperUDF'
USING JAR 'hdfs:///libs/my-hive-udf.jar';

-- 方式3：创建临时函数
CREATE TEMPORARY FUNCTION tmp_encrypt AS 'com.example.hive.udf.EncryptUDF'
USING JAR 'hdfs:///libs/encrypt-udf.jar';

SELECT tmp_encrypt(phone) AS encrypted_phone FROM orders;
```

### 4.6 验证结果

```bash
# 检查 Hive 分区是否提交成功
hive -e "SHOW PARTITIONS hive_orders;"

# 检查 _SUCCESS 文件
hdfs dfs -ls /user/hive/warehouse/my_database.db/hive_orders/dt=2024-01-15/hr=10/

# 查询写入数据
hive -e "SELECT COUNT(*) FROM hive_orders WHERE dt='2024-01-15';"

# Flink Web UI 查看任务状态
echo "http://$(yarn application -list | grep flink-hive | awk '{print $9}')"
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | `ClassNotFoundException: org.apache.hadoop.hive.conf.HiveConf` | 缺少 Hive 依赖 JAR | 确保 `flink-sql-connector-hive-*.jar` 在 lib/ 下, 且 `HADOOP_CLASSPATH` 已设置 |
| 2 | `Unable to instantiate org.apache.hadoop.hive.metastore.HiveMetaStoreClient` | Metastore 连接失败 | 检查 hive-site.xml 中 `hive.metastore.uris`, 确认 Metastore 进程存活 |
| 3 | `Table not found` | Catalog/Database 未切换 | 确认 `USE CATALOG` 和 `USE DATABASE` 已执行 |
| 4 | 流式写入无数据到 Hive | 分区未提交 | 检查 `sink.partition-commit.trigger` 配置, 确认 Watermark 正常推进 |
| 5 | Hive 表查不到新写入数据 | Metastore 未通知 | 设置 `sink.partition-commit.policy.kind=metastore` |
| 6 | 流式读分区延迟大 | 监控间隔太长 | 减小 `streaming-source.monitor-interval` |
| 7 | OOM 读大分区 | 单个分区文件过大 | 增加 TM 内存, 或用 `table.exec.hive.infer-source-parallelism=true` |
| 8 | Hive UDF 找不到 | JAR 未加载 | 使用 `USING JAR` 指定 HDFS 路径 |
| 9 | 版本不兼容 | Hive Connector 版本与集群 Hive 版本不匹配 | 使用对应版本的 connector JAR |
| 10 | 小文件问题 | 流式写入产生大量小文件 | 开启 `auto-compaction=true` |

---

## 六、生产最佳实践

### 6.1 资源配置推荐

```bash
# 流式写入 Hive 典型配置
flink run -m yarn-cluster \
    -ynm "streaming-to-hive" \
    -yjm 4096 \
    -ytm 8192 \
    -ys 4 \
    -yD taskmanager.numberOfTaskSlots=4 \
    -yD parallelism.default=8 \
    -yD state.backend=rocksdb \
    -yD state.checkpoints.dir=hdfs:///flink/checkpoints \
    -yD execution.checkpointing.interval=60000 \
    -yD execution.checkpointing.min-pause=30000 \
    -c com.example.StreamingToHive \
    my-job.jar
```

### 6.2 参数调优

```sql
-- 写入性能优化
SET table.exec.hive.fallback-mapred-writer = false;  -- 使用 Flink 原生 Writer
SET table.exec.hive.infer-source-parallelism = true;  -- 自动推断并行度
SET table.exec.hive.infer-source-parallelism.max = 100;  -- 最大推断并行度

-- 小文件合并
SET auto-compaction = true;
SET compaction.file-size = 128MB;

-- Parquet 写入优化
SET sink.rolling-policy.file-size = 256MB;
SET sink.rolling-policy.rollover-interval = 10min;
```

### 6.3 监控告警

```yaml
# Prometheus 监控关键指标
- flink_taskmanager_job_task_numRecordsOut  # 输出记录数
- flink_taskmanager_job_task_numRecordsIn   # 输入记录数
- flink_jobmanager_job_numRestarts          # 重启次数
- flink_taskmanager_Status_JVM_Memory_Heap_Used  # JVM 堆使用

# 告警规则
groups:
  - name: flink-hive-alerts
    rules:
      - alert: FlinkCheckpointFailed
        expr: increase(flink_jobmanager_job_numberOfFailedCheckpoints[5m]) > 0
        for: 5m
        annotations:
          summary: "Flink Checkpoint 失败"
      - alert: FlinkHivePartitionDelay
        expr: time() - flink_custom_last_partition_commit_time > 7200
        for: 10m
        annotations:
          summary: "Hive 分区提交延迟超过2小时"
```

### 6.4 分区管理

```bash
# 定期清理过期分区（保留30天）
hive -e "
ALTER TABLE hive_orders DROP IF EXISTS PARTITION (dt < '$(date -d '-30 days' +%Y-%m-%d)');
"

# 定时合并小文件
hive -e "
ALTER TABLE hive_orders PARTITION (dt='2024-01-15', hr='10') CONCATENATE;
"
```

---

## 七、举一反三

### 7.1 Flink Hive 集成 vs Spark Hive 集成

| 维度 | Flink + Hive | Spark + Hive |
|------|-------------|--------------|
| 模式 | 流+批统一 | 主要批处理(Structured Streaming流) |
| 延迟 | 分钟级(分区监控间隔) | 分钟~小时级 |
| 写入 | 流式持续写入 | 微批写入 |
| Catalog | HiveCatalog(复用元数据) | 直接集成(SparkSession) |
| 适用场景 | 实时ETL→Hive | 离线批量ETL |

### 7.2 面试高频题

**Q1: Flink 读写 Hive 表底层走的什么协议？**

> A: 读取时底层走的是 MapReduce InputFormat（Flink 封装了 HiveTableSource 适配 InputFormat），写入时使用 Flink 原生 StreamingFileSink（或可选 fallback 到 MapRed Writer）。元数据交互通过 Thrift RPC 访问 Hive Metastore Service。

**Q2: Flink 流式写 Hive 如何保证 Exactly-Once？**

> A: 通过 Checkpoint + 两阶段提交实现：
> 1. 数据先写入临时文件（.inprogress）
> 2. Checkpoint 完成时将文件 rename 为正式文件（pending → finished）
> 3. 分区提交策略在所有文件 finished 后通知 Metastore
> 4. 如果 Checkpoint 失败回滚，临时文件被清理

**Q3: streaming-source.partition-order 三种模式区别？**

> A:
> - `partition-name`: 按分区名字典序（适用于 dt=2024-01-15 这类有序分区）
> - `create-time`: 按分区在 Metastore 中的创建时间排序
> - `partition-time`: 按从分区名提取的时间排序（需配合 partition.time-extractor）

**Q4: Flink Lookup Join Hive 维表的缓存机制？**

> A: 分为两种模式：
> - `streaming-source.partition.include=latest`: 只加载最新分区数据到内存，定期刷新
> - `lookup.join.cache.ttl`: 设置缓存过期时间，过期后重新加载
> - 底层维表数据全量加载到 TaskManager 内存，适合中小维表（< 几百MB）

### 7.3 思考题

1. **如果 Hive 维表有 10GB，Lookup Join 会有什么问题？如何解决？**
   - 提示：考虑内存占用、加载时间、是否需要分区裁剪

2. **流式写 Hive 产生大量小文件，除了 auto-compaction 还有什么方案？**
   - 提示：考虑 RollingPolicy、并行度设置、上游攒批

3. **如何实现 Flink 实时写入 Hive，同时保证 Hive 下游 Spark/Presto 查询不受影响？**
   - 提示：考虑分区可见性、_SUCCESS 文件、Metastore 通知时机

---

## 附录：完整提交命令参考

```bash
# Per-Job 模式提交 Flink Hive 集成作业
flink run -m yarn-cluster \
    -ynm "flink-hive-integration" \
    -yjm 4096 \
    -ytm 8192 \
    -ys 4 \
    -yD execution.checkpointing.interval=60000 \
    -yD state.backend=rocksdb \
    -yD state.checkpoints.dir=hdfs:///flink/checkpoints \
    -yD table.exec.hive.fallback-mapred-writer=false \
    -yD table.exec.hive.infer-source-parallelism=true \
    -yD env.hadoop.conf.dir=/etc/hadoop/conf \
    -yD env.hive.conf.dir=/etc/hive/conf \
    -yt /etc/hive/conf/hive-site.xml \
    -c com.example.FlinkHiveJob \
    /path/to/my-flink-hive-job.jar

# Application 模式（推荐）
flink run-application -t yarn-application \
    -Dyarn.application.name="flink-hive-app" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=8 \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints \
    -c com.example.FlinkHiveJob \
    hdfs:///flink/jars/my-flink-hive-job.jar
```

---

**本教案结束。下一篇：F05-Flink-HDFS-on-YARN 文件读写教案**
