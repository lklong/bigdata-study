# [教案] Flink on YARN — MySQL CDC 实时同步使用姿势

> 🎯 教学目标：掌握 Flink CDC Connector 实时捕获 MySQL 变更数据的完整姿势，包括全量+增量同步、多种下游写入、断点续传、多表同步 | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：你有"原始账本"(MySQL)，需要"影子抄写员"(Flink CDC)实时监视变动，同步到多个"副本账本"(Kafka/Iceberg/MySQL)。

**生产场景**：数据分发、实时入湖、异构同步、实时物化视图、数据库迁移。

---

## 二、前置条件

### 2.1 MySQL 配置

```sql
-- 确认 Binlog 开启
SHOW VARIABLES LIKE 'log_bin';         -- ON
SHOW VARIABLES LIKE 'binlog_format';   -- ROW
-- 创建 CDC 用户
CREATE USER 'flink_cdc'@'%' IDENTIFIED BY 'Flink@CDC2025';
GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%';
```

### 2.2 所需 JAR

```bash
flink-sql-connector-mysql-cdc-2.4.2.jar    # CDC核心
flink-sql-connector-kafka-1.17.2.jar       # Kafka Sink
flink-connector-jdbc-3.1.0-1.17.jar        # JDBC Sink
```

---

## 三、核心使用方式

### 3.1 CDC Source

```sql
CREATE TABLE mysql_cdc_source (
    order_id BIGINT, user_id STRING, amount DECIMAL(10,2), status STRING,
    create_time TIMESTAMP(3), update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector'='mysql-cdc',
    'hostname'='192.168.1.100','port'='3306',
    'username'='flink_cdc','password'='Flink@CDC2025',
    'database-name'='cdc_demo','table-name'='orders',
    'server-id'='5401-5404',
    'scan.startup.mode'='initial'
);
```

### 3.2 startup.mode

| 模式 | 行为 | 场景 |
|------|------|------|
| `initial` | 全量快照+增量Binlog | 首次启动(最常用) |
| `latest-offset` | 仅增量 | 只关心新变更 |
| `timestamp` | 从指定时间 | 回溯 |

### 3.3 三种下游写法

**→ Kafka**（debezium-json 格式保留CDC语义）
```sql
INSERT INTO kafka_sink SELECT * FROM mysql_cdc_source;
```

**→ Iceberg**（UPSERT 入湖）
```sql
INSERT INTO iceberg_sink SELECT * FROM mysql_cdc_source;
```

**→ MySQL**（JDBC Sink 异构同步）
```sql
INSERT INTO target_mysql SELECT * FROM mysql_cdc_source;
```

---

## 四、提交命令

```bash
export HADOOP_CLASSPATH=`hadoop classpath`
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="MySQL-CDC-Sync" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/cdc \
    -c com.example.flink.cdc.CDCSyncJob \
    /opt/flink-jobs/cdc-sync-1.0.jar
```

---

## 五、断点续传

```bash
# 触发 Savepoint
flink savepoint <job-id> hdfs:///flink/savepoints/cdc/
# 从 Savepoint 恢复
flink run-application -s hdfs:///flink/savepoints/cdc/savepoint-xxx ...
```

---

## 六、多表同步

```sql
-- 正则匹配
'database-name'='cdc_demo', 'table-name'='order_.*'
```

---

## 七、常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| REPLICATION权限不足 | 用户权限 | GRANT REPLICATION SLAVE |
| server-id冲突 | 与其他Slave重复 | 修改范围 |
| Binlog已purge | 过期清理 | 重新initial |
| 全量阶段慢 | chunk太大 | 减小chunk.size |
| 时区偏移 | 时区不匹配 | server-time-zone=Asia/Shanghai |

---

## 八、面试高频题

**Q1: 增量快照为何无锁？** A: 按主键分Chunk，每Chunk前后记录Binlog位点(Low/High Watermark)，通过期间Binlog修正快照，无需FTWRL。

**Q2: 全量→增量如何衔接？** A: 所有Chunk完成后取最大Binlog位点作为增量起始，通过Checkpoint保一致性。

**Q3: server-id注意事项？** A: 范围≥并行度，不与其他Slave冲突，作业唯一。

**Q4: 平滑升级？** A: Savepoint → Cancel → 部署新JAR → 从Savepoint恢复。

---

## 九、思考题

1. 100张分表，每张1000万行，CDC入湖架构怎么设计？
2. Savepoint恢复后Binlog已purge怎么办？
3. CDC到Kafka后如何保证同一行UPDATE顺序？
