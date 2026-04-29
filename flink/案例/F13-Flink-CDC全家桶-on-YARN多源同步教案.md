# [教案] Flink on YARN — CDC 全家桶多源同步使用姿势

> 🎯 教学目标：掌握 Flink CDC 多数据源支持（MySQL/PG/MongoDB/Oracle/SQL Server/TiDB）、CDC 2.x SQL 方式、CDC 3.x Pipeline YAML 免代码、整库同步、Schema Evolution、Route 路由、Transform 转换 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 什么是 Flink CDC 全家桶？

**生活类比**：如果说单个 MySQL CDC Connector 是"一个翻译官"（只翻译 MySQL 的语言），那 Flink CDC 全家桶就是"联合国同声传译团队"——支持 MySQL、PostgreSQL、MongoDB、Oracle、SQL Server、TiDB、OceanBase 等几乎所有主流数据库的实时变更捕获。

更重要的是，Flink CDC 3.x 引入了 **Pipeline** 模式——只需写一个 YAML 文件，就能实现整库同步、Schema Evolution（自动适配上游表结构变更）、数据路由和转换，真正做到"免代码数据集成"。

### 1.2 CDC 2.x vs 3.x 对比

| 维度 | CDC 2.x (SQL Connector) | CDC 3.x (Pipeline) |
|------|------------------------|---------------------|
| 使用方式 | Flink SQL DDL | YAML 配置文件 |
| 同步粒度 | 单表 | 整库/多表 |
| Schema Evolution | ❌ 不支持 | ✅ 自动适配 |
| 数据路由 | 需手动编码 | ✅ Route 配置 |
| 数据转换 | SQL 表达式 | ✅ Transform 配置 |
| 适用场景 | 灵活的单表 ETL | 整库搬迁/数据集成 |
| 编码量 | 中等（写 SQL） | 极少（写 YAML） |

---

## 二、前置条件

### 2.1 支持的数据源一览

| 数据源 | Connector | 版本要求 | 特点 |
|--------|-----------|----------|------|
| MySQL | mysql-cdc | 5.7+ / 8.0+ | 无锁快照，最成熟 |
| PostgreSQL | postgres-cdc | 9.6+ | 逻辑复制 |
| MongoDB | mongodb-cdc | 3.6+ | Change Stream |
| Oracle | oracle-cdc | 11g+ | LogMiner / XStream |
| SQL Server | sqlserver-cdc | 2012+ | CDC 功能 |
| TiDB | tidb-cdc | 5.x+ | TiKV Change Data |
| OceanBase | oceanbase-cdc | 3.x+ | OB Log Proxy |
| Db2 | db2-cdc | 11.5+ | SQL Replication |

### 2.2 JAR 依赖

```bash
# CDC 2.x 方式（各数据源 Connector）
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-mysql-cdc/2.4.2/flink-sql-connector-mysql-cdc-2.4.2.jar
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-postgres-cdc/2.4.2/flink-sql-connector-postgres-cdc-2.4.2.jar
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-mongodb-cdc/2.4.2/flink-sql-connector-mongodb-cdc-2.4.2.jar
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-oracle-cdc/2.4.2/flink-sql-connector-oracle-cdc-2.4.2.jar
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-sqlserver-cdc/2.4.2/flink-sql-connector-sqlserver-cdc-2.4.2.jar

cp flink-sql-connector-*-cdc-*.jar $FLINK_HOME/lib/

# CDC 3.x Pipeline 方式（独立二进制）
wget https://github.com/apache/flink-cdc/releases/download/release-3.1.0/flink-cdc-3.1.0-bin.tar.gz
tar -xzf flink-cdc-3.1.0-bin.tar.gz
export FLINK_CDC_HOME=/opt/flink-cdc-3.1.0
```

---

## 三、核心使用方式

### 3.1 CDC 2.x SQL 方式（各数据源示例）

#### PostgreSQL CDC

```sql
CREATE TABLE pg_users (
    id INT PRIMARY KEY NOT ENFORCED,
    name VARCHAR(128),
    email VARCHAR(256),
    created_at TIMESTAMP(3)
) WITH (
    'connector' = 'postgres-cdc',
    'hostname' = 'pg-host',
    'port' = '5432',
    'username' = 'flink_cdc',
    'password' = 'password',
    'database-name' = 'user_db',
    'schema-name' = 'public',
    'table-name' = 'users',
    'slot.name' = 'flink_slot_users',
    'decoding.plugin.name' = 'pgoutput'
);
```

#### MongoDB CDC

```sql
CREATE TABLE mongo_products (
    _id STRING PRIMARY KEY NOT ENFORCED,
    name STRING,
    price DECIMAL(10, 2),
    category STRING,
    update_time TIMESTAMP_LTZ(3)
) WITH (
    'connector' = 'mongodb-cdc',
    'hosts' = 'mongo01:27017,mongo02:27017,mongo03:27017',
    'username' = 'flink_cdc',
    'password' = 'password',
    'database' = 'ecommerce',
    'collection' = 'products'
);
```

#### Oracle CDC

```sql
CREATE TABLE oracle_employees (
    employee_id NUMBER PRIMARY KEY NOT ENFORCED,
    first_name VARCHAR(64),
    last_name VARCHAR(64),
    salary NUMBER(10, 2),
    department_id NUMBER
) WITH (
    'connector' = 'oracle-cdc',
    'hostname' = 'oracle-host',
    'port' = '1521',
    'username' = 'flink_cdc',
    'password' = 'password',
    'database-name' = 'ORCL',
    'schema-name' = 'HR',
    'table-name' = 'EMPLOYEES',
    'debezium.log.mining.strategy' = 'online_catalog'
);
```

#### SQL Server CDC

```sql
CREATE TABLE sqlserver_orders (
    order_id INT PRIMARY KEY NOT ENFORCED,
    customer_id INT,
    total_amount DECIMAL(10, 2),
    order_date TIMESTAMP(3)
) WITH (
    'connector' = 'sqlserver-cdc',
    'hostname' = 'sqlserver-host',
    'port' = '1433',
    'username' = 'flink_cdc',
    'password' = 'password',
    'database-name' = 'OrderDB',
    'schema-name' = 'dbo',
    'table-name' = 'Orders'
);
```

### 3.2 CDC 3.x Pipeline YAML 免代码方式

#### 安装与配置

```bash
# CDC 3.x 目录结构
$FLINK_CDC_HOME/
├── bin/
│   └── flink-cdc.sh        # 提交脚本
├── lib/                     # 核心 JAR
├── conf/
│   └── flink-cdc.yaml      # 全局配置
└── pipelines/               # 自定义 Pipeline YAML
```

#### 全局配置 (`conf/flink-cdc.yaml`)

```yaml
# Flink 集群配置
flink:
  execution.target: yarn-application
  jobmanager.memory.process.size: 4096m
  taskmanager.memory.process.size: 8192m
  taskmanager.numberOfTaskSlots: 4
  parallelism.default: 4
  execution.checkpointing.interval: 60000
  state.backend: rocksdb
  state.checkpoints.dir: hdfs:///flink/checkpoints/cdc-pipeline
```

---

## 四、完整实战示例

### 4.1 场景一：MySQL 整库同步到 Kafka（CDC 3.x Pipeline）

#### YAML 配置

```yaml
# mysql-to-kafka-pipeline.yaml
source:
  type: mysql
  hostname: 10.0.1.100
  port: 3306
  username: flink_cdc
  password: Flink_CDC_2024!
  tables: ecommerce.\.*           # 整库所有表
  server-id: 5400-5404
  server-time-zone: Asia/Shanghai

sink:
  type: kafka
  properties.bootstrap.servers: kafka01:9092,kafka02:9092
  topic: ${tableName}             # 每个表对应一个 Topic
  value.format: debezium-json

pipeline:
  name: MySQL to Kafka Full DB Sync
  parallelism: 4
  schema.change.behavior: evolve  # 自动适配 DDL 变更
```

#### 提交命令

```bash
$FLINK_CDC_HOME/bin/flink-cdc.sh \
    mysql-to-kafka-pipeline.yaml \
    --flink-home $FLINK_HOME \
    --target yarn-application \
    -D jobmanager.memory.process.size=4096m \
    -D taskmanager.memory.process.size=8192m
```

### 4.2 场景二：MySQL 整库同步到 Iceberg（带 Route 路由）

```yaml
# mysql-to-iceberg-pipeline.yaml
source:
  type: mysql
  hostname: 10.0.1.100
  port: 3306
  username: flink_cdc
  password: Flink_CDC_2024!
  tables: ecommerce.\.*
  server-time-zone: Asia/Shanghai

sink:
  type: iceberg
  catalog-type: hive
  uri: thrift://hive-metastore:9083
  warehouse: hdfs:///data/iceberg/warehouse

route:
  # 分库分表合并
  - source-table: ecommerce.orders_\d+       # 多个分表
    sink-table: ods.orders                    # 合并到一张表
    description: "合并分表 orders_0~9 到 ods.orders"
  
  # 库名映射
  - source-table: ecommerce.(.*)             # 其他表
    sink-table: ods.$1                       # 保持表名不变，放入 ods 库

transform:
  # 数据脱敏
  - source-table: ecommerce.users
    projection: id, name, SUBSTR(phone, 1, 3) || '****' || SUBSTR(phone, 8) AS phone, city
    description: "手机号脱敏"
  
  # 过滤
  - source-table: ecommerce.orders_\d+
    filter: amount > 0 AND status != 'CANCELLED'
    description: "过滤无效订单"

pipeline:
  name: MySQL to Iceberg with Route
  parallelism: 4
  schema.change.behavior: evolve
```

### 4.3 场景三：PostgreSQL → MySQL（异构同步）

```yaml
# pg-to-mysql-pipeline.yaml
source:
  type: postgres
  hostname: pg-host
  port: 5432
  username: flink_cdc
  password: password
  database-name: analytics
  schema-name: public
  tables: public.user_profiles, public.user_events
  slot.name: flink_cdc_slot
  decoding.plugin.name: pgoutput

sink:
  type: jdbc
  url: jdbc:mysql://mysql-target:3306/analytics_copy
  username: writer
  password: Writer2024!

route:
  - source-table: public.user_profiles
    sink-table: analytics_copy.user_profiles
  - source-table: public.user_events
    sink-table: analytics_copy.user_events

pipeline:
  name: PG to MySQL Sync
  parallelism: 2
```

### 4.4 场景四：MongoDB → Kafka（文档型数据库 CDC）

```yaml
# mongo-to-kafka-pipeline.yaml
source:
  type: mongodb
  hosts: mongo01:27017,mongo02:27017,mongo03:27017
  username: flink_cdc
  password: password
  database: ecommerce
  collection: orders, products, users

sink:
  type: kafka
  properties.bootstrap.servers: kafka01:9092
  topic: mongo_cdc_${collectionName}
  value.format: canal-json

pipeline:
  name: MongoDB to Kafka CDC
  parallelism: 2
```

### 4.5 Schema Evolution 示例

```yaml
# 当上游 MySQL 执行 DDL：
# ALTER TABLE orders ADD COLUMN discount DECIMAL(10,2) DEFAULT 0;

# CDC 3.x Pipeline 会自动：
# 1. 捕获 DDL 事件
# 2. 将新列同步到下游（如 Iceberg/Kafka Schema）
# 3. 历史数据的新列值为 NULL

pipeline:
  schema.change.behavior: evolve    # 自动演化
  # 其他选项：
  # ignore: 忽略 DDL 变更
  # exception: DDL 变更时抛异常停止
  # lenient: 宽松模式（仅添加列）
```

### 4.6 Transform 转换详解

```yaml
transform:
  # 1. 列投影（选择/重命名列）
  - source-table: db.users
    projection: id, name AS user_name, email, created_at
  
  # 2. 计算列
  - source-table: db.orders
    projection: "*, amount * 0.9 AS discounted_amount"
  
  # 3. 过滤条件
  - source-table: db.logs
    filter: "level = 'ERROR' OR level = 'WARN'"
  
  # 4. 数据脱敏
  - source-table: db.users
    projection: "id, name, MD5(id_card) AS id_card_hash, city"
  
  # 5. 添加元数据列
  - source-table: db.\.*
    projection: "*, __table_name__ AS source_table, __database_name__ AS source_db"
    metadata-columns:
      __table_name__: table_name
      __database_name__: database_name
```

### 4.7 验证命令

```bash
# 查看 Pipeline 状态
yarn application -list | grep "cdc-pipeline"

# 查看 Flink Web UI
yarn application -status <app-id>

# 验证 Kafka Topic 数据
kafka-console-consumer.sh \
    --bootstrap-server kafka01:9092 \
    --topic orders \
    --from-beginning \
    --max-messages 5

# 验证 Iceberg 表
spark-sql --catalog iceberg --database ods -e "SELECT COUNT(*) FROM orders"
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | PG: `replication slot already exists` | Slot 冲突 | 删除旧 slot: `SELECT pg_drop_replication_slot('xxx')` |
| 2 | Oracle: `ORA-01291 missing logfile` | 归档日志被清理 | 增大归档保留时间 |
| 3 | MongoDB: `ChangeStream not available` | 未配置副本集 | MongoDB 必须为副本集模式 |
| 4 | SQL Server: `CDC is not enabled` | 表未开启 CDC | `EXEC sys.sp_cdc_enable_table` |
| 5 | Schema Evolution 失败 | 下游不支持某种 DDL | 检查 Sink 兼容性，使用 lenient 模式 |
| 6 | Route 正则不匹配 | 正则语法错误 | 使用 Java 正则语法，`.` 需要转义 `\\.` |
| 7 | Pipeline 提交失败 | YAML 格式错误 | 用 yamllint 检查语法 |
| 8 | 整库同步漏表 | tables 正则不对 | 使用 `db.\.*` 匹配所有表 |
| 9 | Transform 报错 | 表达式语法错误 | 检查 Flink SQL 表达式语法 |
| 10 | 多源并行度不均 | 表大小差异大 | 单独为大表配置并行度 |

---

## 六、生产最佳实践

### 6.1 整库同步配置模板

```yaml
# 生产环境整库同步模板
source:
  type: mysql
  hostname: ${MYSQL_HOST}
  port: 3306
  username: ${CDC_USER}
  password: ${CDC_PASS}
  tables: ${DB_NAME}.\.*
  server-id: 5400-5404
  server-time-zone: Asia/Shanghai
  scan.incremental.snapshot.chunk.size: 8096

sink:
  type: iceberg  # 或 kafka/starrocks/doris
  catalog-type: hive
  uri: thrift://${HMS_HOST}:9083
  warehouse: hdfs:///data/iceberg/warehouse

route:
  - source-table: ${DB_NAME}.\.*
    sink-table: ods.$1

pipeline:
  name: "${DB_NAME} Full DB Sync"
  parallelism: 4
  schema.change.behavior: evolve
  schema.operator.uid: schema-operator
```

### 6.2 CDC 3.x 提交命令模板

```bash
$FLINK_CDC_HOME/bin/flink-cdc.sh \
    pipelines/mysql-to-iceberg.yaml \
    --flink-home $FLINK_HOME \
    --target yarn-application \
    -D yarn.application.name="cdc-full-db-sync" \
    -D jobmanager.memory.process.size=4096m \
    -D taskmanager.memory.process.size=8192m \
    -D taskmanager.numberOfTaskSlots=4 \
    -D parallelism.default=4 \
    -D execution.checkpointing.interval=60000 \
    -D state.backend=rocksdb \
    -D state.checkpoints.dir=hdfs:///flink/checkpoints/cdc-pipeline
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: CDC 2.x 和 3.x 的核心区别？什么场景用哪个？**

> A:
> - 2.x 是 SQL Connector 模式，每张表需要写 DDL + INSERT INTO，灵活但工作量大
> - 3.x 是 Pipeline 模式，YAML 配置整库同步，支持 Schema Evolution/Route/Transform
> - 单表复杂 ETL → 2.x SQL（可做 JOIN、窗口聚合等）
> - 整库搬迁/多表同步 → 3.x Pipeline（免代码、自动适配）

**Q2: Schema Evolution 的原理是什么？**

> A: CDC 3.x 在捕获到上游 DDL 事件时：
> 1. DDL 事件通过 SchemaOperator 处理
> 2. 根据 `schema.change.behavior` 策略决定动作
> 3. `evolve` 模式下自动将 DDL 转换为下游对应操作（如 Iceberg 的 ALTER TABLE）
> 4. 更新内部 Schema Registry，后续数据按新 Schema 写入

**Q3: Route 路由的典型应用场景？**

> A:
> 1. 分库分表合并：`order_db_\d+.orders_\d+` → `ods.orders`
> 2. 库名映射：`prod_db.xxx` → `ods.xxx`
> 3. 多租户隔离：`tenant_\d+.orders` → `warehouse.orders_$1`

### 7.2 思考题

1. **如果上游 MySQL 执行了 DROP COLUMN，CDC 3.x 的 evolve 模式会如何处理？下游 Iceberg/Kafka 表会怎样？**
2. **整库同步 100 张表，其中有 5 张大表（>10亿行），如何优化初始全量阶段？**
3. **CDC Pipeline 运行中，上游新建了一张表，Pipeline 能自动感知并同步吗？**

---

**本教案结束。下一篇：F14-Flink-Kerberos安全集群-on-YARN 配置教案**
