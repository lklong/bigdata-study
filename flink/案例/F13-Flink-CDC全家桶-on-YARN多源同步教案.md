# [教案] Flink on YARN — CDC 全家桶多源同步使用姿势

> 🎯 教学目标：掌握 Flink CDC 2.x SQL 方式与 3.x Pipeline 模式，实现 MySQL 整库同步到 StarRocks | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：想象你有一本实时更新的账本（MySQL），你需要一面"魔法镜子"（数据仓库）能实时映射账本的每一次修改——新增一行、修改金额、删除记录，镜子里都同步变化。传统方式是每晚把整本账本复制一遍（全量同步），但现在业务要求秒级可见变更。

**生产场景**：
- 业务数据库（MySQL/PG）中的订单表需要实时同步到分析型数据库（StarRocks/Doris/ClickHouse）做实时报表
- 多个业务库需要整库同步到数据湖（Iceberg/Hudi），且自动跟踪 DDL 变更（加列、改类型）
- 分库分表场景需要"合库合表"同步到统一目标表

**Flink CDC 解决的核心问题**：
- 增量捕获数据库变更（INSERT/UPDATE/DELETE）
- 无需 Debezium 独立部署，Flink CDC 内置 Debezium 引擎
- 3.x 版本支持 YAML 配置免代码，整库同步 + Schema Evolution + 数据转换

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Flink | 1.18.x / 1.19.x | CDC 3.x 需要 Flink 1.18+ |
| Flink CDC | 2.4.x / 3.1.x / 3.2.x | 推荐 3.1+ |
| Hadoop/YARN | 3.x | 资源调度 |
| MySQL | 5.7+ / 8.0+ | 需开启 binlog |
| StarRocks | 3.x | 目标端（示例） |
| Java | JDK 8 / 11 | 运行时 |

### 2.2 支持的 CDC 源一览

| 数据源 | Connector 名称 | 最低版本 | 备注 |
|--------|---------------|---------|------|
| MySQL | `mysql-cdc` | CDC 2.0+ | 支持全量+增量无锁读取 |
| PostgreSQL | `postgres-cdc` | CDC 2.0+ | 基于 logical replication |
| MongoDB | `mongodb-cdc` | CDC 2.2+ | 基于 Change Streams |
| Oracle | `oracle-cdc` | CDC 2.1+ | 基于 LogMiner / XStream |
| SQL Server | `sqlserver-cdc` | CDC 2.1+ | 基于 CT（Change Tracking） |
| TiDB | `tidb-cdc` | CDC 2.2+ | 基于 TiKV Change Data Feed |
| OceanBase | `oceanbase-cdc` | CDC 2.3+ | 基于 OBLogProxy |
| DB2 | `db2-cdc` | CDC 2.4+ | 基于 ASN Capture |
| Vitess | `vitess-cdc` | CDC 2.4+ | 基于 VStream |

### 2.3 环境准备

```bash
# ========== 1. MySQL 开启 binlog ==========
# my.cnf 配置
cat >> /etc/my.cnf << 'EOF'
[mysqld]
server-id=1
log-bin=mysql-bin
binlog_format=ROW
binlog_row_image=FULL
expire_logs_days=7
# 对于 CDC 需要的权限
# GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%';
EOF

# 重启 MySQL
systemctl restart mysqld

# 创建 CDC 专用用户
mysql -uroot -p << 'EOF'
CREATE USER 'flink_cdc'@'%' IDENTIFIED BY 'FlinkCDC@2026';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%';
FLUSH PRIVILEGES;
EOF

# ========== 2. 下载 Flink CDC JAR ==========
export FLINK_HOME=/opt/flink-1.18.1
cd $FLINK_HOME/lib

# CDC 2.x SQL Connector（逐表模式）
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-mysql-cdc/2.4.2/flink-sql-connector-mysql-cdc-2.4.2.jar

# CDC 3.x Pipeline（整库模式）
wget https://github.com/apache/flink-cdc/releases/download/release-3.1.0/flink-cdc-3.1.0-bin.tar.gz
tar -xzf flink-cdc-3.1.0-bin.tar.gz
# 将 flink-cdc-pipeline-connectors/ 下的 jar 放到 lib/

# ========== 3. 设置环境 ==========
export HADOOP_CLASSPATH=$(hadoop classpath)
export HADOOP_CONF_DIR=/etc/hadoop/conf

# ========== 4. 准备测试数据 ==========
mysql -uflink_cdc -p'FlinkCDC@2026' << 'EOF'
CREATE DATABASE IF NOT EXISTS ecommerce;
USE ecommerce;

CREATE TABLE orders (
    order_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'CREATED',
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    update_time DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE products (
    product_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    product_name VARCHAR(200) NOT NULL,
    category VARCHAR(50),
    price DECIMAL(10,2),
    stock INT DEFAULT 0,
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE users (
    user_id BIGINT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(50) NOT NULL,
    email VARCHAR(100),
    phone VARCHAR(20),
    register_time DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 插入测试数据
INSERT INTO users (username, email, phone) VALUES
('alice', 'alice@example.com', '13800001111'),
('bob', 'bob@example.com', '13800002222'),
('charlie', 'charlie@example.com', '13800003333');

INSERT INTO products (product_name, category, price, stock) VALUES
('iPhone 16 Pro', 'electronics', 9999.00, 100),
('MacBook Pro M4', 'electronics', 19999.00, 50),
('AirPods Pro 3', 'electronics', 1999.00, 200);

INSERT INTO orders (user_id, product_id, amount, status) VALUES
(1, 1, 9999.00, 'PAID'),
(2, 2, 19999.00, 'CREATED'),
(3, 3, 1999.00, 'SHIPPED');
EOF
```

---

## 三、核心使用方式

### 3.1 方式一：Flink CDC 2.x SQL 模式（逐表建 Source）

适用场景：少量表的精细化同步，需要对每张表做不同处理逻辑。

```sql
-- ============================================================
-- MySQL CDC Source 表
-- ============================================================
CREATE TABLE mysql_orders (
    order_id     BIGINT,
    user_id      BIGINT,
    product_id   BIGINT,
    amount       DECIMAL(10,2),
    status       STRING,
    create_time  TIMESTAMP(3),
    update_time  TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector'       = 'mysql-cdc',
    'hostname'        = 'mysql-host',
    'port'            = '3306',
    'username'        = 'flink_cdc',
    'password'        = 'FlinkCDC@2026',
    'database-name'   = 'ecommerce',
    'table-name'      = 'orders',
    'server-id'       = '5401-5404',           -- 多并行度时每个并行度一个 ID
    'scan.startup.mode' = 'initial',            -- 先全量再增量
    'debezium.snapshot.locking.mode' = 'none',  -- 无锁快照（MySQL 8+）
    'scan.incremental.snapshot.enabled' = 'true', -- 增量快照（推荐）
    'scan.incremental.snapshot.chunk.size' = '8096'
);
```

**关键参数详解**：

| 参数 | 默认值 | 说明 |
|------|-------|------|
| `scan.startup.mode` | `initial` | `initial`=全量+增量；`latest-offset`=仅增量 |
| `server-id` | - | MySQL server-id，多并行度用范围如 `5401-5404` |
| `scan.incremental.snapshot.enabled` | `true` | 增量快照读取（无锁、支持 Checkpoint） |
| `scan.incremental.snapshot.chunk.size` | `8096` | 每个快照分片的行数 |
| `debezium.snapshot.locking.mode` | `none` | 快照锁模式：`none`（无锁）/ `minimal` |
| `connect.timeout` | `30s` | 连接超时 |
| `heartbeat.interval` | `30s` | 心跳间隔，防止 binlog 位点丢失 |
| `scan.newly-added-table.enabled` | `false` | 是否动态感知新增表 |

### 3.2 方式二：Flink CDC 3.x Pipeline 模式（YAML 免代码）

适用场景：整库同步、多表同步、需要 Schema Evolution、免代码运维。

**核心优势**：
- 一个 YAML 文件定义整个同步管道
- 自动处理 DDL 变更（加列、改列类型）
- 支持 Route（路由映射）和 Transform（数据转换）
- 无需写 SQL 或 Java 代码

#### 3.2.1 YAML 配置结构

```yaml
# flink-cdc-pipeline.yaml
################################################################################
# 全局配置
################################################################################
pipeline:
  name: MySQL-to-StarRocks-Sync
  parallelism: 4

################################################################################
# Source 配置（MySQL 整库）
################################################################################
source:
  type: mysql
  hostname: mysql-host
  port: 3306
  username: flink_cdc
  password: FlinkCDC@2026
  tables: ecommerce.\.*          # 正则匹配: ecommerce 库下所有表
  server-id: 5401-5404
  server-time-zone: Asia/Shanghai
  
################################################################################
# Sink 配置（StarRocks）
################################################################################
sink:
  type: starrocks
  jdbc-url: jdbc:mysql://starrocks-fe:9030
  load-url: starrocks-fe:8030
  username: root
  password: ""
  table.create.properties.replication_num: 1

################################################################################
# Route 路由规则（可选）
################################################################################
route:
  - source-table: ecommerce.orders
    sink-table: ecommerce_dw.ods_orders
    description: 订单表路由到 DW 层
  - source-table: ecommerce.users
    sink-table: ecommerce_dw.ods_users
  - source-table: ecommerce.products
    sink-table: ecommerce_dw.ods_products

################################################################################
# Transform 数据转换（可选）
################################################################################
transform:
  - source-table: ecommerce.orders
    projection: "*, DATE_FORMAT(create_time, 'yyyy-MM-dd') AS dt"  # 新增字段
    filter: "amount > 0"                                            # 过滤条件
  - source-table: ecommerce.users
    projection: "user_id, username, SUBSTR(phone, 1, 3) || '****' || SUBSTR(phone, 8) AS phone_masked, register_time"
    description: 手机号脱敏
```

#### 3.2.2 Schema Evolution（自动 DDL 变更同步）

Flink CDC 3.x 自动处理以下 DDL 变更：

| DDL 类型 | 支持情况 | 说明 |
|---------|---------|------|
| `ADD COLUMN` | ✅ 完全支持 | 自动在目标端加列 |
| `ALTER COLUMN TYPE`（兼容变更） | ✅ 支持 | 如 INT → BIGINT，VARCHAR(50) → VARCHAR(200) |
| `ALTER COLUMN TYPE`（不兼容） | ⚠️ 部分支持 | 如 INT → VARCHAR，需目标端支持 |
| `DROP COLUMN` | ✅ 支持 | 目标端列标记为可空或删除 |
| `RENAME COLUMN` | ✅ 支持 | 自动重命名 |
| `CREATE TABLE` | ✅ 支持 | 新表自动创建并同步 |
| `DROP TABLE` | ❌ 不同步 | 安全考虑，不自动删表 |
| `TRUNCATE TABLE` | ⚠️ 可配置 | 需额外配置 |

```yaml
# 开启 Schema Evolution
pipeline:
  name: CDC-with-SchemaEvolution
  parallelism: 4
  schema.change.behavior: evolve  # evolve=自动同步 / ignore=忽略 / exception=报错
```

### 3.3 整库同步配置详解

```yaml
# ===== 整库同步：同步 ecommerce 库下所有表 =====
source:
  type: mysql
  hostname: mysql-host
  port: 3306
  username: flink_cdc
  password: FlinkCDC@2026
  tables: ecommerce.\.*            # 正则: 匹配所有表
  # tables: ecommerce.(orders|users|products)  # 指定多表
  # tables: ecommerce.order_\d+    # 匹配分表: order_0, order_1, ...
  server-id: 5401-5404
  chunk-meta.group.size: 1000

# ===== 分库分表合并同步 =====
source:
  type: mysql
  hostname: mysql-host
  port: 3306
  username: flink_cdc
  password: FlinkCDC@2026
  tables: ecommerce_\d+.orders_\d+   # 匹配: ecommerce_0.orders_0, ecommerce_1.orders_1, ...

route:
  - source-table: ecommerce_\d+.orders_\d+
    sink-table: ecommerce_dw.orders_merged   # 所有分表合并到一张目标表
    description: 分库分表合并
```

---

## 四、完整实战示例

### 4.1 场景描述

**业务需求**：电商平台 MySQL 整库实时同步到 StarRocks
- **源端**：MySQL ecommerce 库，包含 orders / users / products 三张表
- **目标**：StarRocks ecommerce_dw 库
- **要求**：
  - 全量 + 增量同步
  - 自动跟踪 DDL 变更
  - 订单表新增日期分区字段
  - 用户表手机号脱敏
  - 使用 Application Mode on YARN 部署

### 4.2 CDC 3.x Pipeline YAML 配置

```yaml
# /opt/flink-cdc/conf/mysql2starrocks.yaml
################################################################################
# Pipeline 全局配置
################################################################################
pipeline:
  name: Ecommerce-MySQL-to-StarRocks
  parallelism: 4
  schema.change.behavior: evolve
  schema-operator.rpc-timeout: 60s

################################################################################
# Source: MySQL 整库
################################################################################
source:
  type: mysql
  hostname: mysql-host
  port: 3306
  username: flink_cdc
  password: FlinkCDC@2026
  tables: ecommerce.\.*
  server-id: 5401-5404
  server-time-zone: Asia/Shanghai
  scan.incremental.snapshot.chunk.size: 8096
  scan.snapshot.fetch.size: 1024
  connect.timeout: 30s
  connection.pool.size: 20
  heartbeat.interval: 30s
  debezium.snapshot.locking.mode: none

################################################################################
# Sink: StarRocks
################################################################################
sink:
  type: starrocks
  jdbc-url: jdbc:mysql://starrocks-fe:9030
  load-url: starrocks-fe:8030
  username: root
  password: ""
  table.create.properties.replication_num: 1
  table.create.properties.fast_schema_evolution: true
  sink.properties.format: json
  sink.properties.strip_outer_array: true
  sink.buffer-flush.max-rows: 5000
  sink.buffer-flush.interval-ms: 10000

################################################################################
# Route: 路由映射
################################################################################
route:
  - source-table: ecommerce.orders
    sink-table: ecommerce_dw.ods_orders
  - source-table: ecommerce.users
    sink-table: ecommerce_dw.ods_users
  - source-table: ecommerce.products
    sink-table: ecommerce_dw.ods_products

################################################################################
# Transform: 数据转换
################################################################################
transform:
  - source-table: ecommerce.orders
    projection: "order_id, user_id, product_id, amount, status, create_time, update_time, DATE_FORMAT(create_time, 'yyyy-MM-dd') AS dt"
    filter: "amount > 0"
    description: 订单表-增加日期分区字段并过滤异常数据
  - source-table: ecommerce.users
    projection: "user_id, username, email, SUBSTR(phone, 1, 3) || '****' || SUBSTR(phone, 8) AS phone, register_time"
    filter: ""
    description: 用户表-手机号脱敏
  - source-table: ecommerce.products
    projection: "*"
    filter: "stock >= 0"
    description: 产品表-过滤库存异常
```

### 4.3 Flink CDC 2.x SQL 写法（对比）

```sql
-- ============================================================
-- 传统 SQL 方式: 逐表定义 Source + Sink + INSERT
-- ============================================================

-- Source: MySQL orders
CREATE TABLE mysql_orders (
    order_id     BIGINT,
    user_id      BIGINT,
    product_id   BIGINT,
    amount       DECIMAL(10,2),
    status       STRING,
    create_time  TIMESTAMP(3),
    update_time  TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector'     = 'mysql-cdc',
    'hostname'      = 'mysql-host',
    'port'          = '3306',
    'username'      = 'flink_cdc',
    'password'      = 'FlinkCDC@2026',
    'database-name' = 'ecommerce',
    'table-name'    = 'orders',
    'server-id'     = '5401-5404'
);

-- Sink: StarRocks orders
CREATE TABLE sr_orders (
    order_id     BIGINT,
    user_id      BIGINT,
    product_id   BIGINT,
    amount       DECIMAL(10,2),
    status       STRING,
    create_time  TIMESTAMP(3),
    update_time  TIMESTAMP(3),
    dt           STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector'      = 'starrocks',
    'jdbc-url'       = 'jdbc:mysql://starrocks-fe:9030',
    'load-url'       = 'starrocks-fe:8030',
    'database-name'  = 'ecommerce_dw',
    'table-name'     = 'ods_orders',
    'username'       = 'root',
    'password'       = '',
    'sink.properties.format'             = 'json',
    'sink.properties.strip_outer_array'  = 'true',
    'sink.buffer-flush.max-rows'         = '5000',
    'sink.buffer-flush.interval-ms'      = '10000'
);

-- ETL: 清洗 + 写入
INSERT INTO sr_orders
SELECT
    order_id, user_id, product_id, amount, status,
    create_time, update_time,
    DATE_FORMAT(create_time, 'yyyy-MM-dd') AS dt
FROM mysql_orders
WHERE amount > 0;
```

### 4.4 DataStream API 写法（Java）

```java
import org.apache.flink.cdc.connectors.mysql.source.MySqlSource;
import org.apache.flink.cdc.connectors.mysql.table.StartupOptions;
import org.apache.flink.cdc.debezium.JsonDebeziumDeserializationSchema;
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.datastream.DataStreamSource;

public class MySQLCDCToStarRocks {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);
        env.setParallelism(4);

        // MySQL CDC Source
        MySqlSource<String> mySqlSource = MySqlSource.<String>builder()
                .hostname("mysql-host")
                .port(3306)
                .databaseList("ecommerce")
                .tableList("ecommerce.orders", "ecommerce.users", "ecommerce.products")
                .username("flink_cdc")
                .password("FlinkCDC@2026")
                .serverId("5401-5404")
                .deserializer(new JsonDebeziumDeserializationSchema())
                .startupOptions(StartupOptions.initial())
                .includeSchemaChanges(true)  // 捕获 DDL 变更
                .build();

        DataStreamSource<String> cdcStream = env.fromSource(
                mySqlSource,
                WatermarkStrategy.noWatermarks(),
                "MySQL CDC Source"
        );

        // 处理 CDC 记录并写入 StarRocks
        cdcStream
                .map(json -> {
                    // 解析 Debezium JSON，提取 op/before/after
                    // 根据表名路由到不同处理逻辑
                    return json;
                })
                .print(); // 实际替换为 StarRocks Sink

        env.execute("MySQL CDC to StarRocks");
    }
}
```

### 4.5 Application Mode on YARN 提交命令

```bash
# ============================================================
# 方式1: CDC 3.x Pipeline 提交（推荐）
# ============================================================
export FLINK_HOME=/opt/flink-1.18.1
export FLINK_CDC_HOME=/opt/flink-cdc-3.1.0
export HADOOP_CLASSPATH=$(hadoop classpath)

# 使用 flink-cdc.sh 提交 Pipeline 作业
$FLINK_CDC_HOME/bin/flink-cdc.sh \
    /opt/flink-cdc/conf/mysql2starrocks.yaml \
    --flink-home $FLINK_HOME \
    --target yarn-application \
    --jobmanager-memory 2048m \
    --taskmanager-memory 4096m

# 或手动通过 flink run-application 提交
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Flink-CDC-MySQL2StarRocks" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/cdc-mysql2sr \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/cdc-mysql2sr \
    -c org.apache.flink.cdc.cli.CliFrontend \
    $FLINK_CDC_HOME/lib/flink-cdc-dist-3.1.0.jar \
    /opt/flink-cdc/conf/mysql2starrocks.yaml

# ============================================================
# 方式2: CDC 2.x SQL 作业提交
# ============================================================
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Flink-CDC-SQL-MySQL2StarRocks" \
    -Dyarn.application.queue=flink \
    -Dyarn.ship-files="$FLINK_HOME/lib/flink-sql-connector-mysql-cdc-2.4.2.jar" \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/cdc-sql \
    -c com.example.MySQLCDCToStarRocks \
    hdfs:///flink/jars/mysql-cdc-job.jar
```

### 4.6 验证结果

```bash
# 1. 查看 YARN Application 状态
yarn application -list | grep CDC

# 2. 验证 StarRocks 目标表数据
mysql -h starrocks-fe -P 9030 -uroot << 'EOF'
USE ecommerce_dw;
SELECT COUNT(*) FROM ods_orders;
SELECT COUNT(*) FROM ods_users;
SELECT COUNT(*) FROM ods_products;
-- 查看最新同步的数据
SELECT * FROM ods_orders ORDER BY update_time DESC LIMIT 5;
EOF

# 3. 验证增量同步 - 在源端插入新数据
mysql -uflink_cdc -p'FlinkCDC@2026' -e "
INSERT INTO ecommerce.orders (user_id, product_id, amount, status) 
VALUES (1, 2, 19999.00, 'CREATED');
"
# 等待几秒后查看 StarRocks
mysql -h starrocks-fe -P 9030 -uroot -e "
SELECT * FROM ecommerce_dw.ods_orders ORDER BY order_id DESC LIMIT 3;
"

# 4. 验证 DDL 同步 - 在源端加列
mysql -uflink_cdc -p'FlinkCDC@2026' -e "
ALTER TABLE ecommerce.orders ADD COLUMN remark VARCHAR(500) DEFAULT '';
"
# 查看 StarRocks 是否自动加列
mysql -h starrocks-fe -P 9030 -uroot -e "DESC ecommerce_dw.ods_orders;"

# 5. 查看 Flink 作业状态
$FLINK_HOME/bin/flink list -t yarn-application \
    -Dyarn.application.id=application_xxxxx_xxxx
```

---

## 五、常见问题与排障

| 问题现象 | 原因 | 解决方案 |
|---------|------|---------|
| `Access denied; you need REPLICATION SLAVE privilege` | CDC 用户缺少复制权限 | `GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%'` |
| `binlog is not enabled` | MySQL 未开启 binlog | 配置 `log-bin=mysql-bin` + `binlog_format=ROW` 后重启 |
| `The connector is trying to read binlog but binlog has been purged` | binlog 被清理，全量快照未完成 | 增大 `expire_logs_days`；从最新位点重启任务 |
| `server-id conflict` | 多个 CDC 任务使用相同 server-id | 为每个任务分配不同的 server-id 范围 |
| `Encountered change event for table X whose schema isn't known` | 表结构变更但 CDC 未识别 | 检查是否开启 `includeSchemaChanges`；重启任务从 Savepoint 恢复 |
| Checkpoint 超时 | 全量阶段数据量大导致 Source 阻塞 | 增大 `execution.checkpointing.timeout`；减小 `chunk.size` |
| `ConnectException: Connection refused` | MySQL 网络不通或端口错误 | 检查网络连通性、防火墙、MySQL 监听地址 |
| StarRocks 写入失败 `too many versions` | StarRocks Compaction 跟不上写入速度 | 增大 `sink.buffer-flush.interval-ms`；调优 StarRocks BE 参数 |
| 同步延迟持续增大 | 并行度不足或大事务阻塞 | 增加并行度；检查源端是否有大事务；增大 `chunk.size` |
| Schema Evolution 加列失败 | 目标端不支持 Online DDL 或列类型不兼容 | 检查目标端 DDL 能力；手动处理不兼容变更 |

---

## 六、生产最佳实践

### 6.1 资源配置建议

| 场景 | 表数量 | 并行度 | TM 内存 | Checkpoint 间隔 |
|------|-------|--------|---------|----------------|
| 单表同步 | 1 | 1~4 | 2GB | 60s |
| 多表同步（<10表） | <10 | 4~8 | 4GB | 60s |
| 整库同步（10~50表） | 10~50 | 4~8 | 4~8GB | 120s |
| 整库同步（>50表） | >50 | 8~16 | 8~16GB | 180s |
| 分库分表合并 | N×M | 8~16 | 8GB | 120s |

### 6.2 关键参数调优

```yaml
# ========== flink-conf.yaml ==========

# Checkpoint 配置（CDC 场景建议）
execution.checkpointing.interval: 60000
execution.checkpointing.timeout: 600000        # 全量阶段可能耗时长
execution.checkpointing.min-pause: 30000
execution.checkpointing.max-concurrent-checkpoints: 1
execution.checkpointing.mode: EXACTLY_ONCE

# State Backend（CDC 必须用 RocksDB）
state.backend: rocksdb
state.backend.incremental: true
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints

# RocksDB 调优
state.backend.rocksdb.memory.managed: true
state.backend.rocksdb.block.cache-size: 256mb

# 网络配置
taskmanager.network.memory.fraction: 0.15
taskmanager.network.memory.min: 128mb

# 重启策略
restart-strategy: fixed-delay
restart-strategy.fixed-delay.attempts: 5
restart-strategy.fixed-delay.delay: 30s
```

### 6.3 监控与告警

**CDC 特有监控指标**：

| 指标 | 含义 | 告警阈值 |
|------|------|---------|
| `currentFetchEventTimeLag` | 当前事件延迟（binlog 产生时间到 Flink 处理的时间差） | >60s 告警 |
| `currentEmitEventTimeLag` | 当前发射延迟 | >120s 告警 |
| `sourceIdleTime` | Source 空闲时间（无新数据） | >300s 预警（可能 binlog 断开） |
| `numRecordsIn` / `numRecordsOut` | 入口/出口记录数 | 持续为0告警 |
| `snapshotPhase` | 快照阶段标记 | 全量阶段持续过久告警 |

---

## 七、举一反三

### 7.1 CDC 2.x vs 3.x 对比

| 对比维度 | CDC 2.x（SQL 模式） | CDC 3.x（Pipeline 模式） |
|---------|-------------------|------------------------|
| 配置方式 | SQL DDL + INSERT INTO | YAML 声明式配置 |
| 整库同步 | 需逐表写 SQL | 一行正则搞定 |
| Schema Evolution | ❌ 不支持 | ✅ 自动同步 DDL |
| Route 路由 | 手动 INSERT INTO 控制 | YAML 声明式路由 |
| Transform 转换 | SQL 函数处理 | YAML 内置表达式 |
| 新增表感知 | ⚠️ 有限支持 | ✅ 自动感知 |
| 灵活性 | 高（可嵌入复杂逻辑） | 中（预定义转换能力） |
| 适用场景 | 少量表精细化处理 | 整库/多库批量同步 |
| 部署复杂度 | 低（标准 Flink SQL） | 中（需额外 CDC CLI） |

### 7.2 面试高频题

**Q1: Flink CDC 如何实现全量 + 增量无锁读取？**

> **A**: Flink CDC 2.x+ 使用"增量快照"算法（Incremental Snapshot）：
> 1. **全量阶段**：将表按主键范围分成多个 Chunk（默认 8096 行/chunk），每个 Chunk 通过 `SELECT * WHERE pk BETWEEN ? AND ?` 并行读取，不加锁。
> 2. **一致性保证**：每个 Chunk 读取完成后记录当时的 Binlog 位点，后续通过 Binlog 补偿该 Chunk 读取期间的变更。
> 3. **增量阶段**：全部 Chunk 读完后，从最低水位的 Binlog 位点开始消费增量。
> 4. **优势**：全程无锁、支持 Checkpoint（中断后从已完成的 Chunk 继续）、支持并行读取。

**Q2: Flink CDC 3.x 的 Schema Evolution 是如何实现的？**

> **A**: 
> 1. CDC Source 捕获到 DDL 事件（如 `ALTER TABLE ADD COLUMN`）
> 2. Pipeline 框架中的 SchemaOperator 接收到 DDL 变更事件
> 3. SchemaOperator 暂停数据流，等待所有上游数据处理完毕（类似 Barrier 对齐）
> 4. 向 Sink 端发送 Schema 变更请求（如调用 StarRocks 的 `ALTER TABLE`）
> 5. Sink 端完成 DDL 后，SchemaOperator 恢复数据流
> 6. 后续数据按新 Schema 写入
> 
> 关键点：DDL 变更是"阻塞式"处理的，保证数据与 Schema 的一致性。

**Q3: Flink CDC 如何处理分库分表合并同步？**

> **A**: 
> 1. **Source 配置**：使用正则表达式匹配多个库/表，如 `tables: db_\d+.orders_\d+`
> 2. **Route 配置**：将多个源表映射到同一目标表，如 `source-table: db_\d+.orders_\d+ → sink-table: dw.orders_all`
> 3. **Schema 合并**：CDC 框架自动合并各分表的 Schema（取并集），在目标端创建包含所有列的宽表
> 4. **冲突处理**：如果分表 Schema 不一致（如 A 表有 col_x，B 表没有），目标表中该列设为 NULLABLE
> 5. **DDL 处理**：任一分表的 DDL 变更都会反映到目标表

**Q4: CDC 全量阶段 Checkpoint 超时怎么办？**

> **A**: 
> 1. 增大 `execution.checkpointing.timeout`（全量阶段数据量大时可设为 10~30 分钟）
> 2. 减小 `scan.incremental.snapshot.chunk.size`（更小的 chunk 更快完成单次快照）
> 3. 增大并行度让更多 chunk 并行读取
> 4. 如果是大表（>1亿行），考虑先手动全量导入目标端，再用 CDC `latest-offset` 模式只消费增量

### 7.3 思考题

1. **架构设计题**：公司有 100+ 个微服务，每个服务有自己的 MySQL 实例，需要将所有库统一同步到数据湖。请设计一个可扩展的 CDC 同步平台架构。

2. **故障恢复题**：CDC 任务运行 3 天后，发现源端 MySQL 做了一次主从切换（Failover），binlog 文件名和位点都变了。Flink CDC 任务会怎样？如何恢复？

3. **性能优化题**：某业务表单表 5 亿行，全量快照阶段耗时超过 24 小时仍未完成。请设计优化方案。

---

> 📝 **本教案配套资源**
> - Pipeline YAML 配置: `cdc-configs/mysql2starrocks.yaml`
> - MySQL 初始化脚本: `sql-scripts/init-ecommerce.sql`
> - StarRocks 建表脚本: `sql-scripts/starrocks-ddl.sql`
> - DataStream 工程: `java-projects/mysql-cdc-sync/`
