# [教案] Flink on YARN — Hudi 实时数据湖使用姿势

> 🎯 教学目标：掌握 Flink 与 Apache Hudi 集成的完整姿势，包括 COW/MOR 表的选择、流式写入/读取、Compaction 配置、CDC 入湖全链路 | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：传统图书馆(Hive)更新目录需整架重排(全量覆盖)。Hudi 引入智能系统：COW(整本替换)读快写慢；MOR(贴便签)写快读稍慢。

**生产场景**：MySQL CDC 实时入湖、GDPR 合规删除、近实时分析、流批一体数仓。

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.17.x | 1.17.2 |
| Hudi | 0.14.x | 0.14.1 |
| Hadoop/YARN | 3.x | 3.3.6 |

### 2.2 所需 JAR

```bash
hudi-flink1.17-bundle-0.14.1.jar       # 核心
flink-sql-connector-mysql-cdc-2.4.2.jar # CDC场景
```

### 2.3 环境准备

```bash
cd $FLINK_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/hudi/hudi-flink1.17-bundle/0.14.1/hudi-flink1.17-bundle-0.14.1.jar
export HADOOP_CLASSPATH=`hadoop classpath`
hdfs dfs -mkdir -p /hudi/warehouse/
```

---

## 三、核心使用方式

### 3.1 COW vs MOR

| 维度 | COW | MOR |
|------|-----|-----|
| 写入 | 重写整文件(慢) | 追加log(快) |
| 读取 | 直读base(快) | 合并base+log(稍慢) |
| 场景 | 读多写少 | 写多读少/CDC入湖 |
| Compaction | 不需要 | 必须 |

### 3.2 创建 Hudi MOR 表

```sql
CREATE TABLE hudi_order_mor (
    order_id STRING PRIMARY KEY NOT ENFORCED,
    user_id STRING, amount DECIMAL(10,2), status STRING,
    create_time TIMESTAMP(3), update_time TIMESTAMP(3), dt STRING
) PARTITIONED BY (dt) WITH (
    'connector'='hudi',
    'path'='hdfs:///hudi/warehouse/ods_orders',
    'table.type'='MERGE_ON_READ',
    'hoodie.table.name'='ods_orders',
    'hoodie.datasource.write.recordkey.field'='order_id',
    'hoodie.datasource.write.precombine.field'='update_time',
    'write.tasks'='4','write.operation'='upsert',
    'index.type'='BUCKET','hoodie.bucket.index.num.buckets'='8',
    'compaction.async.enabled'='true','compaction.delta_commits'='5',
    'hive_sync.enable'='true','hive_sync.mode'='hms',
    'hive_sync.metastore.uris'='thrift://hive-metastore:9083',
    'hive_sync.db'='hudi_ods','hive_sync.table'='ods_orders'
);
```

### 3.3 流式增量读取

```sql
'read.streaming.enabled'='true',
'read.start-commit'='20250420100000',
'read.streaming.check-interval'='30',
'changelog.enabled'='true'
```

### 3.4 完整示例：MySQL CDC → Hudi

```sql
-- CDC Source
CREATE TABLE mysql_orders_cdc (...) WITH ('connector'='mysql-cdc',...);
-- Hudi Sink
CREATE TABLE hudi_orders_mor (...) WITH ('connector'='hudi',...);
-- 入湖
INSERT INTO hudi_orders_mor
SELECT *, DATE_FORMAT(create_time,'yyyy-MM-dd') AS dt FROM mysql_orders_cdc;
```

### 3.5 提交命令

```bash
export HADOOP_CLASSPATH=`hadoop classpath`
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="MySQL-CDC-To-Hudi" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dclassloader.resolve-order=parent-first \
    -c com.example.flink.hudi.MySQLCDCToHudiJob \
    /opt/flink-jobs/cdc-to-hudi-1.0.jar
```

---

## 四、常见问题与排障

| 问题 | 原因 | 解决 |
|------|------|------|
| Compaction OOM | 内存不足 | 增大compaction.max_memory |
| 写入延迟高 | FLINK_STATE索引大 | 切BUCKET索引 |
| Hive Sync失败 | HMS不可达 | 检查metastore连接 |
| Checkpoint超时 | Compaction阻塞 | 独立Compaction作业 |

---

## 五、生产最佳实践

```properties
write.tasks: 4
index.type: BUCKET
hoodie.bucket.index.num.buckets: 8
compaction.async.enabled: true
compaction.delta_commits: 5
clean.retain_commits: 20
```

---

## 六、面试高频题

**Q1: COW vs MOR选择？** A: CDC入湖→MOR(写频繁)；批量ETL→COW(读高效)。

**Q2: precombine字段作用？** A: 同主键多条记录取precombine最大值，保证乱序下最终正确。

**Q3: Compaction阻塞写入怎么办？** A: 起独立Compaction Flink作业。

---

## 七、思考题

1. 1亿次/天更新，BUCKET桶数如何规划？
2. 分库分表64张源表，CDC入湖架构怎么设计？
3. Flink+Hudi vs Flink+Iceberg 各适合什么场景？
