# [教案] Flink on YARN — Hudi 实时数据湖使用姿势

> 🎯 教学目标：掌握 Flink + Hudi 构建实时数据湖，包括 COW/MOR 表类型选择、流式写入(INSERT/UPSERT/DELETE)、增量读取(CDC)、MySQL CDC→Flink→Hudi 端到端、Compaction 与索引配置 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 什么场景需要 Flink + Hudi？

**生活类比**：传统 Hive 数仓就像一本"只能追加的账本"，你只能往后面加页，想改前面的记录就得重写整本。Hudi 就像一本"支持涂改液的账本"——你可以修改、删除历史记录，同时还能快速找到"最近改了哪些"。

典型场景：
- MySQL 业务数据实时同步到数据湖（CDC → Hudi）
- 需要更新/删除历史数据的 OLAP 场景
- 近实时数仓：分钟级可见性 + 增量读取

### 1.2 Hudi 核心概念

| 概念 | 说明 |
|------|------|
| COW | 写入时合并，读取无开销 |
| MOR | 写入快追加log，读取时合并 |
| Timeline | 记录所有操作的时间戳 |
| Compaction | MOR 表中 log → base file 合并 |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.15~1.18 | 对应 Hudi 版本 |
| Hudi | 0.14+ | 推荐 0.14.1/0.15.0 |
| Hadoop | 3.x | YARN + HDFS |

### 2.2 JAR 依赖

```bash
wget https://repo1.maven.org/maven2/org/apache/hudi/hudi-flink1.17-bundle/0.14.1/hudi-flink1.17-bundle-0.14.1.jar
cp hudi-flink1.17-bundle-0.14.1.jar $FLINK_HOME/lib/
export HADOOP_CLASSPATH=`hadoop classpath`
```

---

## 三、核心使用方式

### 3.1 建 Hudi 表 DDL

```sql
-- COW 表
CREATE TABLE hudi_orders_cow (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id STRING,
    amount DECIMAL(10, 2),
    status STRING,
    order_time TIMESTAMP(3),
    dt STRING
) PARTITIONED BY (dt) WITH (
    'connector' = 'hudi',
    'path' = 'hdfs:///data/hudi/orders_cow',
    'table.type' = 'COPY_ON_WRITE',
    'hoodie.datasource.write.recordkey.field' = 'order_id',
    'hoodie.datasource.write.precombine.field' = 'order_time',
    'write.tasks' = '4',
    'write.operation' = 'upsert'
);

-- MOR 表
CREATE TABLE hudi_orders_mor (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id STRING,
    amount DECIMAL(10, 2),
    status STRING,
    order_time TIMESTAMP(3),
    dt STRING
) PARTITIONED BY (dt) WITH (
    'connector' = 'hudi',
    'path' = 'hdfs:///data/hudi/orders_mor',
    'table.type' = 'MERGE_ON_READ',
    'hoodie.datasource.write.recordkey.field' = 'order_id',
    'hoodie.datasource.write.precombine.field' = 'order_time',
    'write.tasks' = '4',
    'write.operation' = 'upsert',
    'compaction.async.enabled' = 'true',
    'compaction.delta_commits' = '5'
);
```

### 3.2 COW vs MOR 选择

| 维度 | COW | MOR |
|------|-----|-----|
| 写入延迟 | 高 | 低 |
| 读取延迟 | 低 | 中 |
| 适用场景 | 读多写少 | CDC入湖 |

---

## 四、完整实战示例

### 4.1 MySQL CDC → Hudi

```sql
CREATE TABLE mysql_orders (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id VARCHAR(64),
    amount DECIMAL(10, 2),
    status VARCHAR(32),
    create_time TIMESTAMP(3),
    update_time TIMESTAMP(3)
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql-host',
    'port' = '3306',
    'username' = 'flink_cdc',
    'password' = 'your_password',
    'database-name' = 'ecommerce',
    'table-name' = 'orders',
    'server-time-zone' = 'Asia/Shanghai'
);

CREATE TABLE hudi_orders (
    order_id BIGINT PRIMARY KEY NOT ENFORCED,
    user_id STRING,
    amount DECIMAL(10, 2),
    status STRING,
    create_time TIMESTAMP(3),
    update_time TIMESTAMP(3),
    dt STRING
) PARTITIONED BY (dt) WITH (
    'connector' = 'hudi',
    'path' = 'hdfs:///data/hudi/ods_orders',
    'table.type' = 'MERGE_ON_READ',
    'hoodie.datasource.write.recordkey.field' = 'order_id',
    'hoodie.datasource.write.precombine.field' = 'update_time',
    'write.operation' = 'upsert',
    'write.tasks' = '4',
    'index.type' = 'BUCKET',
    'hoodie.bucket.index.num.buckets' = '8',
    'compaction.async.enabled' = 'true',
    'compaction.delta_commits' = '5',
    'hive_sync.enabled' = 'true',
    'hive_sync.db' = 'ods',
    'hive_sync.table' = 'orders',
    'hive_sync.mode' = 'hms',
    'hive_sync.metastore.uris' = 'thrift://hive-metastore:9083'
);

INSERT INTO hudi_orders
SELECT order_id, user_id, amount, status, create_time, update_time,
       DATE_FORMAT(create_time, 'yyyy-MM-dd') AS dt
FROM mysql_orders;
```

### 4.2 增量读取（CDC 模式）

```sql
CREATE TABLE hudi_orders_cdc (...) WITH (
    'connector' = 'hudi',
    'path' = 'hdfs:///data/hudi/ods_orders',
    'table.type' = 'MERGE_ON_READ',
    'read.streaming.enabled' = 'true',
    'read.start-commit' = '20240115120000',
    'read.streaming.check-interval' = '10',
    'changelog.enabled' = 'true'
);
```

### 4.3 提交命令

```bash
flink run-application -t yarn-application \
    -Dyarn.application.name="mysql-cdc-to-hudi" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/mysql-cdc-hudi \
    -c com.example.MySQLCDCToHudi \
    hdfs:///flink/jars/mysql-cdc-to-hudi.jar
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | `NoSuchMethodError` | Bundle JAR 与 Flink 版本不匹配 | 使用对应版本 |
| 2 | 写入延迟递增 | log files 未 compact | 检查 Compaction |
| 3 | State 持续膨胀 | FLINK_STATE 索引 | 换 BUCKET 索引 |
| 4 | CP 超时 | State 太大 | 增量 CP + 增大超时 |
| 5 | Hive 查询为空 | Hive Sync 失败 | 检查 hive_sync 配置 |

---

## 六、生产最佳实践

### 6.1 资源配置

```
write.tasks = Source并行度 / 2~4
num.buckets = 数据量(条) / 500000
TM Memory = 4GB + State开销
CP Interval = 60~120s
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: COW vs MOR 本质区别？**
> COW写时合并base file（写重读轻），MOR写时追加log（写轻读重需合并）。

**Q2: FLINK_STATE vs BUCKET 索引？**
> STATE精确但State大，BUCKET无State但需预规划桶数。

**Q3: Compaction 不执行的后果？**
> log files 累积→读取变慢→HDFS小文件激增。

---

**本教案结束。**
