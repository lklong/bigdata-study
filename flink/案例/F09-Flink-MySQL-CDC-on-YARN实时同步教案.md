# [教案] Flink on YARN — MySQL CDC 实时同步使用姿势

> 🎯 教学目标：掌握 Flink CDC 实现 MySQL 实时数据同步，覆盖数据分发、入仓入湖、异构同步、多表同步等核心场景 | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

| 场景 | 描述 | 示例 |
|------|------|------|
| **数据分发** | MySQL 变更实时分发到 Kafka | 订单变更广播给下游 |
| **实时入仓** | MySQL → Flink CDC → Hive/Iceberg/Hudi | 业务数据实时入湖 |
| **异构同步** | MySQL A → MySQL B | 跨机房/读写分离 |
| **实时搜索** | MySQL → ES | 变更实时索引 |
| **缓存更新** | MySQL → Redis | 实时刷新缓存 |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.17+ | 推荐 |
| flink-cdc-connectors | 2.4.x | 核心 |
| MySQL | 5.7+ / 8.0+ | 需开启 Binlog |

### 2.2 环境准备

```bash
export FLINK_HOME=/opt/flink-1.17.2
export HADOOP_CLASSPATH=$(hadoop classpath)

cd $FLINK_HOME/lib
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-mysql-cdc/2.4.2/flink-sql-connector-mysql-cdc-2.4.2.jar
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar
wget https://repo1.maven.org/maven2/org/apache/flink/flink-connector-jdbc/3.1.0-1.17/flink-connector-jdbc-3.1.0-1.17.jar
wget https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.33/mysql-connector-java-8.0.33.jar

# MySQL CDC 账号
mysql -e "
CREATE USER 'flink_cdc'@'%' IDENTIFIED BY 'Flink@CDC2026';
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%';
FLUSH PRIVILEGES;"
```

---

## 三、核心使用方式

### 3.1 MySQL CDC Source DDL

```sql
CREATE TABLE mysql_orders (
    order_id BIGINT, user_id BIGINT, product_name STRING,
    amount DECIMAL(10,2), status STRING,
    create_time TIMESTAMP(3), update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql-source',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'Flink@CDC2026',
    'database-name' = 'demo',
    'table-name' = 'orders',
    'scan.startup.mode' = 'initial',
    'server-time-zone' = 'Asia/Shanghai',
    'scan.incremental.snapshot.enabled' = 'true',
    'scan.incremental.snapshot.chunk.size' = '8096'
);
```

### 3.2 参数详解表

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `connector` | ✅ | - | `mysql-cdc` |
| `hostname` | ✅ | - | MySQL 地址 |
| `database-name` | ✅ | - | 库名（支持正则） |
| `table-name` | ✅ | - | 表名（支持正则） |
| `scan.startup.mode` | ❌ | `initial` | initial/latest-offset/timestamp |
| `scan.incremental.snapshot.enabled` | ❌ | `true` | 增量快照 |
| `scan.incremental.snapshot.chunk.size` | ❌ | `8096` | chunk 大小 |

---

## 四、完整实战示例

### 4.1 MySQL → Kafka（数据分发）

```sql
CREATE TABLE kafka_sink (
    order_id BIGINT, user_id BIGINT, product_name STRING,
    amount DECIMAL(10,2), status STRING,
    create_time TIMESTAMP(3), update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'kafka',
    'topic' = 'cdc_orders',
    'properties.bootstrap.servers' = 'kafka01:9092',
    'format' = 'debezium-json',
    'sink.delivery-guarantee' = 'exactly-once',
    'sink.transactional-id-prefix' = 'cdc-tx'
);

INSERT INTO kafka_sink SELECT * FROM mysql_orders;
```

### 4.2 MySQL → MySQL（异构同步）

```sql
CREATE TABLE mysql_sink (
    order_id BIGINT, user_id BIGINT, product_name STRING,
    amount DECIMAL(10,2), status STRING,
    create_time TIMESTAMP(3), update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'jdbc',
    'url' = 'jdbc:mysql://mysql-b:3306/demo',
    'table-name' = 'orders',
    'username' = 'writer', 'password' = 'password',
    'sink.buffer-flush.max-rows' = '1000',
    'sink.buffer-flush.interval' = '1s'
);

INSERT INTO mysql_sink SELECT * FROM mysql_orders;
```

### 4.3 Savepoint 断点续传

```bash
# 停止并创建 Savepoint
$FLINK_HOME/bin/flink stop --savepointPath hdfs:///flink/savepoints/ $JOB_ID

# 从 Savepoint 恢复
$FLINK_HOME/bin/flink run-application -t yarn-application \
  -s hdfs:///flink/savepoints/savepoint-xxx \
  -c com.example.MysqlCdcJob /path/to/job.jar
```

### 4.4 多表同步（Pipeline）

```yaml
# mysql-to-kafka-pipeline.yaml
source:
  type: mysql
  hostname: mysql-source
  port: 3306
  username: flink_cdc
  password: Flink@CDC2026
  tables: demo.\.*

sink:
  type: kafka
  properties.bootstrap.servers: kafka01:9092
  topic: cdc_${tableName}
  value.format: debezium-json
```

### 4.5 Application Mode 提交

```bash
$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dparallelism.default=4 \
  -Dyarn.application.name="MySQL-CDC-Sync" \
  -Dexecution.checkpointing.interval=60000 \
  -Dstate.backend=rocksdb \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/cdc \
  -c com.example.MysqlCdcJob /path/to/job.jar
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决 |
|------|------|------|
| Access denied | 权限不足 | 授予 REPLICATION SLAVE/CLIENT |
| Binlog not enabled | 未开启 | 配置 log-bin=ROW |
| 全量 OOM | 大表 | 增大 TM 内存，减小 chunk.size |
| server id conflict | ID 冲突 | 每个 Source 用不同 server-id |
| Binlog 被清理 | retention 短 | 增大 expire_logs_days |

---

## 六、生产最佳实践

```bash
# 高可用配置
restart-strategy: fixed-delay
restart-strategy.fixed-delay.attempts: 2147483647
restart-strategy.fixed-delay.delay: 30s
execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
```

---

## 七、举一反三

**Q: 无锁全量快照原理？**
> MVCC 一致性读 + 主键范围分片并行读取，不加锁不影响业务。

**Q: 如何 Exactly-Once 到 Kafka？**
> Flink Checkpoint + Kafka 事务。

**Q: 主从切换怎么办？**
> 从 Savepoint 恢复，指向新主库即可。

---

> 📝 **教案小结**：Flink CDC 核心要点 — 无锁全量快照不影响业务，Checkpoint 保证 Exactly-Once，Savepoint 断点续传，Pipeline 多表同步。
