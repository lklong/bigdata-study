# [教案] Flink on YARN — Hudi 实时数据湖使用姿势

> 🎯 教学目标：掌握 Flink + Hudi 实时数据湖方案，实现 MySQL CDC 实时入湖、流式增量读取、COW/MOR 表管理 | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

### 1.1 典型业务场景

| 场景 | 描述 | 示例 |
|------|------|------|
| **CDC 入湖** | MySQL/PostgreSQL 变更数据实时同步到 Hudi | 业务库订单表实时入湖 |
| **实时宽表** | 多源数据 Join 后写入 Hudi 宽表 | 订单 + 用户 + 商品 → 宽表 |
| **增量 ETL** | 流式增量读取 Hudi 表，实现链式 ETL | ODS → DWD → DWS 层级流转 |
| **数据修正** | 支持 Update/Delete，修正历史错误数据 | 数据回刷、GDPR 删除 |
| **近实时分析** | 写入即可查，分钟级延迟 | 实时报表、实时指标 |

### 1.2 COW vs MOR 决策表

| 维度 | COW (Copy on Write) | MOR (Merge on Read) |
|------|--------------------|--------------------|
| **写入性能** | 慢（重写整个文件） | 快（写 log 文件） |
| **读取性能** | 快（直接读 parquet） | 较慢（合并 base + log） |
| **适用场景** | 读多写少 | 写多读少，实时入湖 |
| **Compaction** | 写入时完成 | 需要独立配置 |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Flink | 1.17.x / 1.18.x | 推荐 1.17 |
| Hudi | 0.14.x / 0.15.x | 推荐 0.14+ |
| Hadoop/YARN | 3.1+ | Flink on YARN |
| Hive Metastore | 3.1+ | 元数据管理 |
| MySQL | 5.7+ / 8.0+ | CDC 数据源 |

### 2.2 环境准备命令

```bash
export FLINK_HOME=/opt/flink-1.17.2
export HADOOP_HOME=/opt/hadoop
export HADOOP_CLASSPATH=$(hadoop classpath)

cd $FLINK_HOME/lib

# Hudi Flink Bundle
wget https://repo1.maven.org/maven2/org/apache/hudi/hudi-flink1.17-bundle/0.14.1/hudi-flink1.17-bundle-0.14.1.jar

# Flink CDC MySQL Connector
wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-mysql-cdc/2.4.2/flink-sql-connector-mysql-cdc-2.4.2.jar

# Kafka Connector
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar

# 拷贝配置
cp $HADOOP_HOME/etc/hadoop/core-site.xml $FLINK_HOME/conf/
cp $HADOOP_HOME/etc/hadoop/hdfs-site.xml $FLINK_HOME/conf/
cp /opt/hive/conf/hive-site.xml $FLINK_HOME/conf/

hdfs dfs -mkdir -p /warehouse/hudi
```

---

## 三、核心使用方式

### 3.1 Hudi MOR 表 DDL

```sql
CREATE TABLE hudi_orders_mor (
    order_id    BIGINT,
    user_id     BIGINT,
    product_name STRING,
    amount      DECIMAL(10,2),
    status      STRING,
    update_time TIMESTAMP(3),
    dt          STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) PARTITIONED BY (dt)
WITH (
    'connector' = 'hudi',
    'path' = 'hdfs:///warehouse/hudi/orders_mor',
    'table.type' = 'MERGE_ON_READ',
    'hoodie.datasource.write.recordkey.field' = 'order_id',
    'hoodie.datasource.write.precombine.field' = 'update_time',
    'hoodie.table.name' = 'orders_mor',
    'write.tasks' = '4',
    'compaction.async.enabled' = 'true',
    'compaction.trigger.strategy' = 'num_commits',
    'compaction.delta_commits' = '5',
    'compaction.tasks' = '4',
    'hive_sync.enable' = 'true',
    'hive_sync.db' = 'ods',
    'hive_sync.table' = 'ods_orders',
    'hive_sync.mode' = 'hms',
    'hive_sync.metastore.uris' = 'thrift://hive-metastore:9083'
);
```

### 3.2 参数详解表

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `connector` | ✅ | - | 固定 `hudi` |
| `path` | ✅ | - | HDFS 存储路径 |
| `table.type` | ❌ | `COPY_ON_WRITE` | COW / MOR |
| `hoodie.datasource.write.recordkey.field` | ✅ | - | 主键字段 |
| `hoodie.datasource.write.precombine.field` | ✅ | - | 预合并字段 |
| `write.tasks` | ❌ | `4` | 写入并行度 |
| `write.operation` | ❌ | `upsert` | upsert / insert / bulk_insert |
| `compaction.async.enabled` | ❌ | `true` | 异步 Compaction |
| `compaction.delta_commits` | ❌ | `5` | 触发 Compaction 的 commit 数 |
| `hive_sync.enable` | ❌ | `false` | 是否同步 Hive |

---

## 四、完整实战示例

### 4.1 MySQL CDC → Flink → Hudi

```sql
-- MySQL CDC Source
CREATE TABLE mysql_orders (
    order_id BIGINT, user_id BIGINT, product_name STRING,
    amount DECIMAL(10,2), status STRING,
    create_time TIMESTAMP(3), update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql-host', 'port' = '3306',
    'username' = 'flink_cdc', 'password' = 'Flink@CDC2026',
    'database-name' = 'demo', 'table-name' = 'orders',
    'scan.startup.mode' = 'initial'
);

-- 写入 Hudi
INSERT INTO hudi_orders_mor
SELECT order_id, user_id, product_name, amount, status,
       update_time, DATE_FORMAT(update_time, 'yyyy-MM-dd') AS dt
FROM mysql_orders;
```

### 4.2 流式增量读取

```sql
CREATE TABLE hudi_cdc_source (...) WITH (
    'connector' = 'hudi',
    'path' = 'hdfs:///warehouse/hudi/ods_orders',
    'read.streaming.enabled' = 'true',
    'read.streaming.check-interval' = '30',
    'changelog.enabled' = 'true'
);
```

### 4.3 Application Mode 提交

```bash
$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dparallelism.default=4 \
  -Dyarn.application.name="MySQL-CDC-to-Hudi" \
  -Dexecution.checkpointing.interval=60000 \
  -Dstate.backend=rocksdb \
  -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/cdc-hudi \
  -c com.example.MysqlCdcToHudiJob \
  /path/to/flink-hudi-job.jar
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决 |
|------|------|------|
| `ConcurrentModificationException` | 多 Writer | 一张表只能一个 Writer |
| Compaction 卡住 | TM 内存不足 | 增大内存 / compaction.tasks |
| Hive 查不到数据 | 同步未开启 | `hive_sync.enable=true` |
| recordkey null | 数据质量 | 过滤 null 主键 |

---

## 六、生产最佳实践

### 6.1 Compaction 调优

```sql
'compaction.trigger.strategy' = 'num_and_time',
'compaction.delta_commits' = '5',
'compaction.delta_seconds' = '300',
'compaction.tasks' = '8',
'clean.async.enabled' = 'true',
'hoodie.cleaner.commits.retained' = '10'
```

### 6.2 资源配置

| 场景 | TM 内存 | write.tasks | compaction.tasks |
|------|---------|-------------|-----------------|
| 小表 | 4G | 2 | 2 |
| 中表 | 8G | 4 | 4 |
| 大表 | 16G | 8 | 8 |

---

## 七、举一反三

### 7.1 面试高频题

**Q: COW vs MOR 如何选择？**
> 读多写少选 COW，写多读少（如 CDC 实时入湖）选 MOR。

**Q: precombine field 的作用？**
> 同一 Rowkey 多条记录时，取 precombine field 最大值保留。通常用 update_time。

**Q: Hudi 表能多 Writer 吗？**
> 不能。Timeline 加锁机制保证同一时刻只有一个 Writer。

---

> 📝 **教案小结**：Flink + Hudi 最适合 CDC 入湖场景。核心：COW/MOR 按读写比选择，precombine field 决定版本，Compaction 是 MOR 的生命线。
