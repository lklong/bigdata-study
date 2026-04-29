# [教案] Flink on YARN — SQL Client 交互式查询使用姿势

> 🎯 教学目标：掌握 Flink SQL Client 在 YARN 上的使用方法，能进行交互式 SQL 开发、DDL 建表、DML 查询与脚本批量执行 | ⏰ 预计学时: 75分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

在大数据开发中，经常有这样的需求：

| 场景 | 诉求 |
|------|------|
| 数据探查 | 快速查看 Kafka/Hive/HDFS 中的数据长什么样 |
| SQL 调试 | 写完 Flink SQL 后先交互式验证再上线 |
| 临时 ETL | 一次性数据迁移，不值得写 Java 程序 |
| 报表查询 | 实时 Dashboard 的 Ad-hoc 查询 |
| 教学演示 | 给团队演示 Flink SQL 能力 |

**Flink SQL Client** 就是为这些场景而生的——它是一个命令行交互式工具，类似于 MySQL CLI / Hive Beeline，可以直接在终端写 SQL 并实时看结果。配合 YARN 集群，可以用分布式资源来执行 SQL 查询。

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.15+（推荐 1.17/1.18） | SQL Client 从 1.13 开始成熟 |
| Hadoop/YARN | 2.8+ / 3.x | YARN 集群正常运行 |
| Hive | 2.3+ / 3.1+（可选） | 如需使用 HiveCatalog |
| Java | JDK 8 / JDK 11 | - |

### 2.2 需要的 JAR 包

```bash
$FLINK_HOME/lib/
├── flink-sql-client-*.jar          # SQL Client 核心（自带）
├── flink-connector-kafka-*.jar     # Kafka 连接器（按需）
├── flink-connector-jdbc-*.jar      # JDBC 连接器（按需）
├── flink-connector-hive_*.jar      # Hive 连接器（按需）
├── flink-connector-filesystem-*.jar # 文件系统连接器（按需）
├── flink-json-*.jar                # JSON Format（自带）
├── flink-csv-*.jar                 # CSV Format（自带）
├── flink-avro-*.jar                # Avro Format（按需）
├── flink-parquet-*.jar             # Parquet Format（按需）
├── flink-orc-*.jar                 # ORC Format（按需）
└── hive-exec-*.jar                 # Hive 元数据（如用 HiveCatalog）

# 下载连接器示例（Kafka）
wget https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.1.0-1.18/flink-sql-connector-kafka-3.1.0-1.18.jar \
  -P $FLINK_HOME/lib/
```

### 2.3 环境准备命令

```bash
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)
export HIVE_HOME=/opt/hive
export HIVE_CONF_DIR=$HIVE_HOME/conf

# 验证
flink --version
yarn node -list
```

---

## 三、核心使用方式

### 3.1 方式一: Embedded 模式 — 连接 YARN Session 集群

#### 第一步：启动 YARN Session

```bash
$FLINK_HOME/bin/yarn-session.sh \
  -nm "flink-sql-session" \
  -jm 2048 \
  -tm 4096 \
  -s 4 \
  -d \
  -qu default
```

#### 第二步：启动 SQL Client

```bash
# 方式A：自动连接（读取 .yarn-properties 文件）
$FLINK_HOME/bin/sql-client.sh

# 方式B：指定 YARN Session Application ID（推荐）
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -Dexecution.target=yarn-session

# 方式C：指定初始化 SQL 文件
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -i /path/to/init.sql
```

**启动参数详解表**：

| 参数 | 含义 | 推荐值 | 注意事项 |
|------|------|--------|----------|
| `-Dyarn.application.id` | YARN Session 的 App ID | 从 yarn-session.sh 输出获取 | 不指定则读 .yarn-properties |
| `-Dexecution.target` | 执行目标 | `yarn-session` | 连接已有 Session |
| `-i <file>` | 初始化 SQL 文件 | 建表/SET 语句 | 启动时自动执行 |
| `-f <file>` | 执行 SQL 脚本并退出 | 批量 SQL | 非交互模式 |
| `-l <dir>` | 额外 JAR 目录 | 放连接器 JAR | 补充 $FLINK_HOME/lib |
| `-j <jar>` | 额外 JAR 文件 | 单个 JAR | - |

### 3.2 方式二: SQL 脚本批量执行

```bash
# 非交互式执行 SQL 脚本
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -f /path/to/my-etl-script.sql
```

### 3.3 方式三: SQL Gateway 模式（Flink 1.16+）

```bash
# 启动 SQL Gateway
$FLINK_HOME/bin/sql-gateway.sh start \
  -Dsql-gateway.endpoint.rest.address=0.0.0.0 \
  -Dsql-gateway.endpoint.rest.port=8083 \
  -Dexecution.target=yarn-session \
  -Dyarn.application.id=application_1234567890_0001

# SQL Client 连接 Gateway
$FLINK_HOME/bin/sql-client.sh gateway --endpoint http://localhost:8083
```

---

## 四、完整实战示例

### 4.1 场景描述

完成完整的 SQL Client 工作流：启动 Session → 建表 → 查询 → 插入 → 验证。

### 4.2 常用 SET 参数

```sql
-- 查看所有当前配置
SET;

-- 设置运行模式
SET 'execution.runtime-mode' = 'streaming';

-- 设置并行度
SET 'parallelism.default' = '4';

-- 设置结果展示模式
SET 'sql-client.execution.result-mode' = 'tableau';

-- 设置 Checkpoint
SET 'execution.checkpointing.interval' = '60s';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints';

-- 设置时区
SET 'table.local-time-zone' = 'Asia/Shanghai';

-- Mini-Batch 聚合优化
SET 'table.exec.mini-batch.enabled' = 'true';
SET 'table.exec.mini-batch.allow-latency' = '5s';
SET 'table.exec.mini-batch.size' = '5000';
```

### 4.3 DDL 建表示例

```sql
-- Kafka Source 表
CREATE TABLE kafka_orders (
    order_id    BIGINT,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(10, 2),
    order_time  TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-sql-demo',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.ignore-parse-errors' = 'true'
);

-- HDFS Sink 表（Parquet）
CREATE TABLE hdfs_orders_archive (
    order_id    BIGINT,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(10, 2),
    order_time  TIMESTAMP(3),
    dt          STRING
) PARTITIONED BY (dt) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/orders_archive',
    'format' = 'parquet',
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '1 h',
    'sink.partition-commit.policy.kind' = 'success-file'
);

-- JDBC 维表（MySQL）
CREATE TABLE mysql_products (
    product_id  BIGINT,
    product_name STRING,
    category    STRING,
    price       DECIMAL(10, 2),
    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://mysql-host:3306/shop',
    'table-name' = 'products',
    'username' = 'flink_reader',
    'password' = 'your_password',
    'lookup.cache.max-rows' = '5000',
    'lookup.cache.ttl' = '10min'
);

-- Print 表（调试）
CREATE TABLE print_sink (
    order_id    BIGINT,
    user_id     BIGINT,
    product_name STRING,
    amount      DECIMAL(10, 2)
) WITH (
    'connector' = 'print'
);

-- 查看已创建的表
SHOW TABLES;
DESCRIBE kafka_orders;
```

### 4.4 DML 查询与插入

```sql
-- 简单查询（Ctrl+C 停止）
SELECT * FROM kafka_orders;

-- 聚合查询
SELECT user_id, COUNT(*) AS cnt, SUM(amount) AS total
FROM kafka_orders GROUP BY user_id;

-- 窗口聚合
SELECT
    TUMBLE_START(order_time, INTERVAL '1' MINUTE) AS window_start,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM kafka_orders
GROUP BY TUMBLE(order_time, INTERVAL '1' MINUTE);

-- Lookup Join
SELECT o.order_id, o.user_id, p.product_name, o.amount
FROM kafka_orders AS o
JOIN mysql_products FOR SYSTEM_TIME AS OF o.order_time AS p
    ON o.product_id = p.product_id;

-- INSERT INTO（后台提交流作业）
INSERT INTO hdfs_orders_archive
SELECT order_id, user_id, product_id, amount, order_time,
       DATE_FORMAT(order_time, 'yyyy-MM-dd') AS dt
FROM kafka_orders;

-- 查看运行中的作业
SHOW JOBS;

-- 停止作业
STOP JOB '4a5b6c7d...' WITH SAVEPOINT;
```

### 4.5 HiveCatalog 配置

```sql
-- 创建 HiveCatalog
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/opt/hive/conf'
);

-- 切换 Catalog
USE CATALOG hive_catalog;
SHOW DATABASES;
USE my_database;
SHOW TABLES;

-- 批模式查询 Hive 表
SET 'execution.runtime-mode' = 'batch';
SELECT * FROM hive_table LIMIT 10;
```

### 4.6 初始化文件示例

创建 `/opt/flink/conf/sql-client-init.sql`：

```sql
SET 'table.local-time-zone' = 'Asia/Shanghai';
SET 'execution.runtime-mode' = 'streaming';
SET 'parallelism.default' = '4';
SET 'sql-client.execution.result-mode' = 'tableau';
SET 'execution.checkpointing.interval' = '60s';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints';

CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/opt/hive/conf'
);

CREATE TEMPORARY TABLE datagen_source (
    id BIGINT, name STRING, ts TIMESTAMP(3),
    WATERMARK FOR ts AS ts - INTERVAL '5' SECOND
) WITH ('connector'='datagen','rows-per-second'='100');
```

启动：`$FLINK_HOME/bin/sql-client.sh -i /opt/flink/conf/sql-client-init.sql`

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `Could not find any factory for 'kafka'` | 缺少 Kafka 连接器 JAR | 下载 `flink-sql-connector-kafka-*.jar` 放入 `$FLINK_HOME/lib/` |
| `ClassNotFoundException: HiveConf` | 缺少 Hive 依赖 | 添加 `flink-sql-connector-hive-*.jar` |
| SELECT 查询无结果 | Kafka 无数据/offset 不对 | 检查 `scan.startup.mode`，先 `earliest-offset` |
| SQL Client 退出后作业消失 | SELECT 查询随客户端退出 | INSERT INTO 的作业不受影响 |
| `-f` 执行无输出 | 脚本模式不显示 SELECT | 只适合 DDL + INSERT INTO |
| 内存不足 OOM | TM 内存过小 | 增大 `taskmanager.memory.process.size` |
| HiveCatalog 连接超时 | Metastore 问题 | 检查 `hive-site.xml` 中 `hive.metastore.uris` |

---

## 六、生产最佳实践

### 6.1 资源配置建议

| 规模 | JM 内存 | TM 内存 | TM 数量 | Slot/TM |
|------|---------|---------|---------|---------|
| 开发调试 | 2G | 4G | 2 | 4 |
| 日常查询 | 4G | 8G | 4 | 4 |
| 生产 ETL | 4G | 8G | 8+ | 4 |

### 6.2 关键参数调优

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `table.exec.mini-batch.enabled` | true | 提升聚合吞吐 |
| `table.exec.mini-batch.allow-latency` | 5s | 微批延迟 |
| `table.optimizer.agg-phase-strategy` | TWO_PHASE | 两阶段聚合 |
| `table.exec.state.ttl` | 24h-72h | 防止 State 无限增长 |
| `table.optimizer.distinct-agg.split.enabled` | true | COUNT DISTINCT 优化 |

### 6.3 监控与告警

```bash
# 查看运行中的 Job
SHOW JOBS;

# REST API 获取 Job 状态
curl http://<jm-host>:8081/jobs

# 获取 Checkpoint 信息
curl http://<jm-host>:8081/jobs/<job-id>/checkpoints
```

---

## 七、举一反三

### 7.1 与其他组件的对比

| 维度 | Flink SQL Client | Hive Beeline | Spark SQL | Presto CLI |
|------|------------------|--------------|-----------|------------|
| 流处理 | ✅ 原生 | ❌ | ❌ | ❌ |
| 批处理 | ✅ | ✅ | ✅ | ✅ |
| 实时性 | 毫秒级 | 分钟级 | 秒级 | 秒级 |
| 适合场景 | 实时+批 | 批处理 | 批处理 | Ad-hoc |

### 7.2 面试高频题

**Q1: SQL Client embedded 和 gateway 模式的区别？**
> Embedded：SQL Client 直接做 Flink 客户端。Gateway：多用户共享 SQL Gateway 服务，RESTful 接口。

**Q2: SELECT 和 INSERT INTO 行为有何不同？**
> SELECT 交互式显示，退出即停止。INSERT INTO 提交后台作业，SQL Client 退出不影响。

**Q3: HiveCatalog 的作用？**
> 访问 Hive 元数据、持久化 Flink 表定义、与 Hive 生态集成。

### 7.3 思考题

1. 用 `datagen` + `print` 验证 SQL Client 的数据流转
2. 设计多人共享 SQL Client 的方案（提示：SQL Gateway）
3. 用 Statement Set 实现多路输出

---

> 📝 **教案总结**：SQL Client 是实时数据开发利器。关键要点：(1) 用 `-i` 初始化配置；(2) SELECT 调试，INSERT INTO 生产；(3) HiveCatalog 持久化元数据；(4) 生产用 `-f` 脚本 + Application Mode。
