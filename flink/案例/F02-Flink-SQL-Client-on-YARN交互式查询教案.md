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
# ============================================================
# SQL Client 依赖 JAR 清单
# ============================================================
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
# ============================================================
# 环境变量配置
# ============================================================
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_HOME=/opt/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)
export HIVE_HOME=/opt/hive           # 可选，使用 HiveCatalog 时需要
export HIVE_CONF_DIR=$HIVE_HOME/conf # 可选

# 验证
flink --version
yarn node -list
```

---

## 三、核心使用方式

### 3.1 方式一: Embedded 模式 — 连接 YARN Session 集群

**原理**：先启动一个 YARN Session 集群，然后 SQL Client 以 embedded 模式连接该集群执行 SQL。

#### 第一步：启动 YARN Session

```bash
# ============================================================
# 启动 YARN Session（为 SQL Client 提供执行资源）
# ============================================================
$FLINK_HOME/bin/yarn-session.sh \
  -nm "flink-sql-session" \
  -jm 2048 \
  -tm 4096 \
  -s 4 \
  -d \
  -qu default

# 记录输出的 Application ID: application_xxxx_yyyy
# 会自动写入 /tmp/.yarn-properties-$(whoami)
```

#### 第二步：启动 SQL Client（连接 Session）

```bash
# ============================================================
# 方式A：自动连接（读取 .yarn-properties 文件）
# ============================================================
$FLINK_HOME/bin/sql-client.sh

# ============================================================
# 方式B：指定 YARN Session 的 Application ID（推荐）
# ============================================================
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -Dexecution.target=yarn-session

# ============================================================
# 方式C：指定初始化 SQL 文件
# ============================================================
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

---

### 3.2 方式二: Embedded 模式 — YARN Application Mode（推荐生产使用）

```bash
# ============================================================
# SQL Client + Application Mode（每次启动独立集群）
# ============================================================
$FLINK_HOME/bin/sql-client.sh \
  -Dexecution.target=yarn-application \
  -Dyarn.application.name="sql-client-app-mode" \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=4 \
  -Dparallelism.default=4
```

> ⚠️ 注意：Application Mode 下，SQL Client 的交互体验稍差——每次执行 DML 都会创建新的 YARN Application。更适合脚本批量执行而非交互探查。

---

### 3.3 方式三: SQL 脚本批量执行

```bash
# ============================================================
# 非交互式执行 SQL 脚本（适合 CI/CD 和定时任务）
# ============================================================
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -f /path/to/my-etl-script.sql

# 示例脚本内容（my-etl-script.sql）：
# SET 'execution.runtime-mode' = 'streaming';
# SET 'parallelism.default' = '8';
#
# CREATE TABLE kafka_source (...) WITH (...);
# CREATE TABLE hdfs_sink (...) WITH (...);
# INSERT INTO hdfs_sink SELECT * FROM kafka_source;
```

---

## 四、完整实战示例

### 4.1 场景描述

完成一个典型的 SQL Client 工作流：启动 Session → 建表 → 查询 → 插入 → 验证。

### 4.2 启动 Session 并进入 SQL Client

```bash
# Step 1: 启动 YARN Session
$FLINK_HOME/bin/yarn-session.sh \
  -nm "sql-client-demo" \
  -jm 2048 \
  -tm 4096 \
  -s 4 \
  -d

# Step 2: 进入 SQL Client
$FLINK_HOME/bin/sql-client.sh
```

### 4.3 SQL Client 内基本操作

进入 SQL Client 后，你会看到一个交互式终端（类似 MySQL CLI）：

```
                                   ▒▓██▓██▒▓
                               ▓████▒▒█▓▒▓███▓▒
                            ▓███▓░░        ▒▒▒▓██▒  ▒
                          ░██▒   ▒▒▓▓█▓▓▒░      ▒████
                          ██▒         ░▒▓███████████████
                            ░▓█            ███████████▓
                              ▓█       ▒▒▒▒▒▓████████▒
                                █░  ░░░░░░   ▒██████▓
                                 ▓█  ░░░     ░▓█████▒
                                  ██        ░▒▓███▒▒
                                   ██▓  ░▒▒▓▓████▒
                                    ▓██▓▓▓▓▓███▒
    ______ _ _       _       _____  ____  _         _____ _ _            _
   |  ____| (_)     | |     / ____|/ __ \| |       / ____| (_)          | |
   | |__  | |_ _ __ | | __ | (___ | |  | | |      | |    | |_  ___ _ __ | |_
   |  __| | | | '_ \| |/ /  \___ \| |  | | |      | |    | | |/ _ \ '_ \| __|
   | |    | | | | | |   <   ____) | |__| | |____  | |____| | |  __/ | | | |_
   |_|    |_|_|_| |_|_|\_\ |_____/ \___\_\______|  \_____|_|_|\___|_| |_|\__|

Flink SQL>
```

#### 4.3.1 常用 SET 参数

```sql
-- ============================================================
-- 1. 查看所有当前配置
-- ============================================================
SET;

-- ============================================================
-- 2. 设置运行模式
-- ============================================================
SET 'execution.runtime-mode' = 'streaming';   -- 流模式（默认）
-- SET 'execution.runtime-mode' = 'batch';    -- 批模式

-- ============================================================
-- 3. 设置并行度
-- ============================================================
SET 'parallelism.default' = '4';

-- ============================================================
-- 4. 设置结果展示模式
-- ============================================================
SET 'sql-client.execution.result-mode' = 'table';     -- 表格模式（默认）
-- SET 'sql-client.execution.result-mode' = 'changelog'; -- 变更日志模式
-- SET 'sql-client.execution.result-mode' = 'tableau';   -- 简洁表格模式

-- ============================================================
-- 5. 设置 Checkpoint
-- ============================================================
SET 'execution.checkpointing.interval' = '60s';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints';

-- ============================================================
-- 6. 设置时区（影响时间类型的显示）
-- ============================================================
SET 'table.local-time-zone' = 'Asia/Shanghai';

-- ============================================================
-- 7. Mini-Batch 聚合优化（提升吞吐）
-- ============================================================
SET 'table.exec.mini-batch.enabled' = 'true';
SET 'table.exec.mini-batch.allow-latency' = '5s';
SET 'table.exec.mini-batch.size' = '5000';
```

#### 4.3.2 DDL 建表示例

```sql
-- ============================================================
-- 示例1: 基于 Kafka 的 Source 表
-- ============================================================
CREATE TABLE kafka_orders (
    order_id    BIGINT,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(10, 2),
    order_time  TIMESTAMP(3),
    -- 定义 Watermark（事件时间处理必须）
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-sql-client-demo',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);

-- ============================================================
-- 示例2: 基于 HDFS 的 Sink 表（Parquet 格式）
-- ============================================================
CREATE TABLE hdfs_orders_archive (
    order_id    BIGINT,
    user_id     BIGINT,
    product_id  BIGINT,
    amount      DECIMAL(10, 2),
    order_time  TIMESTAMP(3),
    dt          STRING   -- 分区字段
) PARTITIONED BY (dt) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/warehouse/orders_archive',
    'format' = 'parquet',
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '1 h',
    'sink.partition-commit.policy.kind' = 'success-file'
);

-- ============================================================
-- 示例3: 基于 JDBC（MySQL）的维表
-- ============================================================
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

-- ============================================================
-- 示例4: Print 表（调试用，输出到 TaskManager 日志）
-- ============================================================
CREATE TABLE print_sink (
    order_id    BIGINT,
    user_id     BIGINT,
    product_name STRING,
    amount      DECIMAL(10, 2)
) WITH (
    'connector' = 'print'
);

-- ============================================================
-- 查看已创建的表
-- ============================================================
SHOW TABLES;
SHOW CREATE TABLE kafka_orders;
DESCRIBE kafka_orders;
```

#### 4.3.3 DML 查询与插入

```sql
-- ============================================================
-- 1. 简单查询（实时展示结果，Ctrl+C 停止）
-- ============================================================
SELECT * FROM kafka_orders;

-- ============================================================
-- 2. 聚合查询（实时更新的 TOP 用户消费）
-- ============================================================
SELECT
    user_id,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM kafka_orders
GROUP BY user_id;

-- ============================================================
-- 3. 窗口聚合（每分钟订单统计）
-- ============================================================
SELECT
    TUMBLE_START(order_time, INTERVAL '1' MINUTE) AS window_start,
    TUMBLE_END(order_time, INTERVAL '1' MINUTE) AS window_end,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM kafka_orders
GROUP BY TUMBLE(order_time, INTERVAL '1' MINUTE);

-- ============================================================
-- 4. Lookup Join（订单关联商品维表）
-- ============================================================
SELECT
    o.order_id,
    o.user_id,
    p.product_name,
    p.category,
    o.amount,
    o.order_time
FROM kafka_orders AS o
JOIN mysql_products FOR SYSTEM_TIME AS OF o.order_time AS p
    ON o.product_id = p.product_id;

-- ============================================================
-- 5. INSERT INTO（提交流作业，后台运行）
-- ============================================================
INSERT INTO hdfs_orders_archive
SELECT
    order_id,
    user_id,
    product_id,
    amount,
    order_time,
    DATE_FORMAT(order_time, 'yyyy-MM-dd') AS dt
FROM kafka_orders;

-- 执行后会返回 Job ID，作业在后台持续运行
-- Job ID: 4a5b6c7d8e9f...

-- ============================================================
-- 6. 查看正在运行的作业
-- ============================================================
SHOW JOBS;

-- ============================================================
-- 7. 停止作业
-- ============================================================
STOP JOB '4a5b6c7d8e9f...' WITH SAVEPOINT;
```

### 4.4 Catalog 配置（HiveCatalog）

```sql
-- ============================================================
-- 配置 HiveCatalog（可以直接读写 Hive 表）
-- ============================================================

-- 方式1：在 SQL Client 内创建
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/opt/hive/conf'
);

-- 切换到 Hive Catalog
USE CATALOG hive_catalog;

-- 查看 Hive 数据库
SHOW DATABASES;

-- 切换数据库
USE hive_db;

-- 查看 Hive 表
SHOW TABLES;

-- 直接查询 Hive 表（批模式）
SET 'execution.runtime-mode' = 'batch';
SELECT * FROM hive_db.user_info LIMIT 10;

-- 切回默认 Catalog
USE CATALOG default_catalog;

-- ============================================================
-- 方式2：在初始化文件中配置（推荐）
-- ============================================================
-- 创建 init.sql 文件:
-- /opt/flink/conf/sql-client-init.sql
--
-- CREATE CATALOG hive_catalog WITH (
--     'type' = 'hive',
--     'default-database' = 'default',
--     'hive-conf-dir' = '/opt/hive/conf'
-- );
-- USE CATALOG hive_catalog;
-- SET 'table.local-time-zone' = 'Asia/Shanghai';
-- SET 'execution.runtime-mode' = 'streaming';

-- 启动时使用:
-- $FLINK_HOME/bin/sql-client.sh -i /opt/flink/conf/sql-client-init.sql
```

**HiveCatalog 依赖 JAR**：

```bash
# 需要放入 $FLINK_HOME/lib/ 的 JAR
cp $FLINK_HOME/opt/flink-sql-connector-hive-3.1.3_2.12-1.18.1.jar $FLINK_HOME/lib/

# 或手动下载
wget https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-hive-3.1.3_2.12/1.18.1/flink-sql-connector-hive-3.1.3_2.12-1.18.1.jar \
  -P $FLINK_HOME/lib/

# 还需要 Hive 的 hive-exec JAR（避免版本冲突，用 Flink 提供的 shaded 版本）
```

### 4.5 初始化文件完整示例

创建 `/opt/flink/conf/sql-client-init.sql`：

```sql
-- ============================================================
-- SQL Client 初始化文件（启动时自动执行）
-- ============================================================

-- 1. 基础配置
SET 'table.local-time-zone' = 'Asia/Shanghai';
SET 'execution.runtime-mode' = 'streaming';
SET 'parallelism.default' = '4';
SET 'sql-client.execution.result-mode' = 'tableau';

-- 2. Checkpoint 配置
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints';

-- 3. 注册 Catalog
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/opt/hive/conf'
);

-- 4. 常用临时表
CREATE TEMPORARY TABLE datagen_source (
    id BIGINT,
    name STRING,
    ts TIMESTAMP(3),
    WATERMARK FOR ts AS ts - INTERVAL '5' SECOND
) WITH (
    'connector' = 'datagen',
    'rows-per-second' = '100',
    'fields.id.min' = '1',
    'fields.id.max' = '1000000',
    'fields.name.length' = '10'
);
```

启动命令：

```bash
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -i /opt/flink/conf/sql-client-init.sql
```

### 4.6 SQL 脚本批量执行实战

创建 ETL 脚本 `/opt/flink/scripts/daily-etl.sql`：

```sql
-- ============================================================
-- daily-etl.sql — 每日 ETL 脚本
-- ============================================================

-- 配置
SET 'execution.runtime-mode' = 'streaming';
SET 'parallelism.default' = '8';
SET 'execution.checkpointing.interval' = '120s';
SET 'state.backend' = 'rocksdb';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints/daily-etl';

-- Source: Kafka
CREATE TABLE IF NOT EXISTS kafka_events (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    event_data  STRING,
    event_time  TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '10' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'user_events',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092',
    'properties.group.id' = 'daily-etl-group',
    'scan.startup.mode' = 'earliest-offset',
    'format' = 'json'
);

-- Sink: HDFS (Parquet)
CREATE TABLE IF NOT EXISTS hdfs_events_dwd (
    event_id    STRING,
    user_id     BIGINT,
    event_type  STRING,
    event_data  STRING,
    event_time  TIMESTAMP(3),
    dt          STRING,
    hr          STRING
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///data/dwd/events',
    'format' = 'parquet',
    'sink.partition-commit.trigger' = 'partition-time',
    'sink.partition-commit.delay' = '5 min',
    'sink.partition-commit.policy.kind' = 'success-file',
    'sink.rolling-policy.file-size' = '128MB',
    'sink.rolling-policy.rollover-interval' = '15 min'
);

-- Execute ETL
INSERT INTO hdfs_events_dwd
SELECT
    event_id,
    user_id,
    event_type,
    event_data,
    event_time,
    DATE_FORMAT(event_time, 'yyyy-MM-dd') AS dt,
    DATE_FORMAT(event_time, 'HH') AS hr
FROM kafka_events
WHERE event_type IS NOT NULL;
```

执行脚本：

```bash
# ============================================================
# 方式A：连接已有 Session 执行
# ============================================================
$FLINK_HOME/bin/sql-client.sh \
  -Dyarn.application.id=application_1234567890_0001 \
  -f /opt/flink/scripts/daily-etl.sql

# ============================================================
# 方式B：Application Mode 执行（推荐生产使用）
# ============================================================
$FLINK_HOME/bin/sql-client.sh \
  -Dexecution.target=yarn-application \
  -Dyarn.application.name="daily-etl-job" \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -f /opt/flink/scripts/daily-etl.sql
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|----------|------|----------|
| `Could not find any factory for 'kafka'` | 缺少 Kafka 连接器 JAR | 下载 `flink-sql-connector-kafka-*.jar` 到 `$FLINK_HOME/lib/` |
| `ClassNotFoundException: org.apache.hive.HiveConf` | 缺少 Hive 依赖 | 添加 `flink-sql-connector-hive-*.jar` 和 `hive-exec-*.jar` |
| SELECT 查询无结果 | Kafka 没有数据 / offset 位置不对 | 检查 `scan.startup.mode`，用 `latest-offset` 然后手动产数据 |
| `Table already exists` | 重复建表 | 使用 `CREATE TABLE IF NOT EXISTS` |
| SQL Client 退出后作业消失 | Session 模式下 SQL Client 是客户端 | 使用 `INSERT INTO` 提交的作业会后台运行，`SELECT` 查询随客户端退出 |
| `INSERT INTO` 报 `No operators defined` | SQL 语法错误或表结构不匹配 | 检查 Schema 对齐、WITH 参数 |
| 内存不足 OOM | TM 内存配置过小 | 增大 `taskmanager.memory.process.size` |
| 连接 HiveCatalog 超时 | Hive Metastore 连接问题 | 检查 `hive-site.xml` 中 `hive.metastore.uris` 配置 |
| Checkpoint 失败 | HDFS 写入权限或连接问题 | 检查 `state.checkpoints.dir` 路径权限 |
| `-f` 执行脚本无输出 | 脚本模式不显示 SELECT 结果 | `-f` 只适合 DDL + INSERT INTO，调试用交互模式 |

---

## 六、生产最佳实践

### 6.1 资源配置建议

```yaml
# ============================================================
# SQL Client Session 集群推荐配置
# ============================================================

# --- Session 集群规格 ---
# 小型（开发调试）: JM 2G + TM 4G*2 + Slot 4
# 中型（日常查询）: JM 4G + TM 8G*4 + Slot 4
# 大型（生产 ETL）: JM 4G + TM 8G*8 + Slot 4

# --- 核心配置 ---
jobmanager.memory.process.size: 4096m
taskmanager.memory.process.size: 8192m
taskmanager.numberOfTaskSlots: 4
parallelism.default: 8

# --- SQL 相关调优 ---
table.exec.mini-batch.enabled: true
table.exec.mini-batch.allow-latency: 5s
table.exec.mini-batch.size: 5000
table.optimizer.agg-phase-strategy: TWO_PHASE  # 两阶段聚合
table.exec.state.ttl: 36h                       # State 过期时间
```

### 6.2 关键参数调优

| 参数 | 默认值 | 推荐值 | 调优说明 |
|------|--------|--------|----------|
| `table.exec.mini-batch.enabled` | false | true | 开启微批，提升聚合吞吐 |
| `table.exec.mini-batch.allow-latency` | 0 | 5s | 微批延迟，越大吞吐越高 |
| `table.exec.mini-batch.size` | -1 | 5000 | 微批大小 |
| `table.optimizer.agg-phase-strategy` | AUTO | TWO_PHASE | 两阶段聚合减少 Shuffle |
| `table.exec.state.ttl` | 0 (永不过期) | 24h-72h | 状态过期，防止 State 无限增长 |
| `table.optimizer.distinct-agg.split.enabled` | false | true | COUNT DISTINCT 优化 |
| `table.exec.resource.default-parallelism` | -1 | 根据作业 | 覆盖默认并行度 |
| `sql-client.execution.result-mode` | table | tableau | 更紧凑的输出 |
| `table.exec.sink.not-null-enforcer` | ERROR | DROP | 忽略 null 违规，避免作业失败 |

### 6.3 监控与告警

```bash
# ============================================================
# SQL Client 作业监控
# ============================================================

# 1. 在 SQL Client 内查看运行中的作业
SHOW JOBS;

# 2. 通过 Flink REST API 查看（需知道 JM 地址）
# 获取 JM 地址
yarn application -status application_xxxx | grep "Tracking-URL"

# 获取所有 Job
curl http://<jm-host>:<jm-port>/jobs

# 获取 Job 详情
curl http://<jm-host>:<jm-port>/jobs/<job-id>

# 获取 Job 的 Checkpoint 信息
curl http://<jm-host>:<jm-port>/jobs/<job-id>/checkpoints

# 3. 监控脚本
#!/bin/bash
JM_URL="http://flink-jm-host:8081"
JOBS=$(curl -s "$JM_URL/jobs" | jq -r '.jobs[] | select(.status != "RUNNING") | .id')
if [ -n "$JOBS" ]; then
    echo "[ALERT] Non-running Flink jobs detected: $JOBS"
fi
```

---

## 七、举一反三

### 7.1 与其他组件的对比

| 维度 | Flink SQL Client | Hive Beeline | Spark SQL Shell | Presto CLI |
|------|------------------|--------------|-----------------|------------|
| 流处理 | ✅ 原生支持 | ❌ | ❌（Structured Streaming 需代码） | ❌ |
| 批处理 | ✅ | ✅ | ✅ | ✅ |
| 交互式 | ✅ | ✅ | ✅ | ✅ |
| 脚本执行 | ✅ `-f` | ✅ `-f` | ✅ `-f` | ✅ `-f` |
| Hive 兼容 | ✅ HiveCatalog | 原生 | ✅ | ✅ Hive Connector |
| 实时性 | 毫秒级 | 秒-分钟级 | 秒级 | 秒级 |
| 适合场景 | 实时 + 批 | 批处理 | 批处理 | Ad-hoc |

### 7.2 面试高频题

**Q1: Flink SQL Client 的两种模式有什么区别？**

> Embedded 模式（默认）：SQL Client 直接作为 Flink 客户端提交作业，适合单人使用。Gateway 模式：SQL Client 连接独立的 SQL Gateway 服务，Gateway 负责管理会话和作业提交，适合多人共享、RESTful API 调用。

**Q2: 在 SQL Client 中执行 SELECT 和 INSERT INTO 有什么区别？**

> `SELECT` 是交互式查询，结果实时展示在终端，退出 SQL Client 后查询自动停止。`INSERT INTO` 会提交一个后台流作业（返回 Job ID），即使退出 SQL Client 作业仍在 YARN 集群上运行。

**Q3: HiveCatalog 在 Flink SQL 中的作用？**

> HiveCatalog 让 Flink SQL 能直接访问 Hive Metastore 中注册的表元数据，实现：(1) 读写 Hive 表；(2) 持久化 Flink 表的元数据（不用每次重新 CREATE TABLE）；(3) 与 Hive 生态无缝集成。

**Q4: `scan.startup.mode` 有哪些选项？各自适用什么场景？**

> `earliest-offset`：从最早的数据开始消费，适合全量回放；`latest-offset`：只消费新数据，适合实时场景；`group-offsets`：从 Consumer Group 上次消费的位置继续，适合故障恢复；`timestamp`：从指定时间戳开始，适合按时间回溯。

### 7.3 思考题

1. **动手题**：启动一个 YARN Session，在 SQL Client 中用 `datagen` 连接器生成测试数据，然后用 `print` Sink 输出到 TaskManager 日志，验证数据流转。

2. **设计题**：你的团队有 5 个数据分析师，都需要使用 Flink SQL 做实时查询。如何设计 SQL Client 的使用方案？（提示：考虑 SQL Gateway + 共享 Session 集群）

3. **排障题**：使用 `-f` 执行 SQL 脚本时，脚本包含多个 `INSERT INTO`，发现只有最后一个作业在运行。可能原因是什么？（提示：检查 SET 'pipeline.name' 配置和 Statement Set）

4. **进阶题**：如何用 Flink SQL 实现一个简单的实时大屏——每秒更新 PV/UV 数据？写出完整的 SQL。

---

> 📝 **教案总结**：Flink SQL Client 是实时数据开发的利器，配合 YARN Session 可实现快速交互式开发。关键要点：(1) 使用 `-i` 初始化常用配置和 Catalog；(2) `SELECT` 用于调试，`INSERT INTO` 用于生产；(3) 使用 HiveCatalog 实现元数据持久化；(4) 生产环境用 `-f` 脚本模式 + Application Mode。
