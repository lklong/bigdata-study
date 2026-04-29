# [教案] Flink on YARN — Flink CDC 全家桶多源同步使用姿势

> 🎯 教学目标：掌握 Flink CDC 3.x Pipeline 模式整库同步、Schema Evolution、多源 CDC 配置 | ⏰ 预计学时: 120分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

| 场景 | 说明 | 典型案例 |
|------|------|----------|
| **整库同步** | 将 MySQL/PG 整个库实时同步到数据湖/OLAP | MySQL → Iceberg/Hudi/StarRocks |
| **CDC 实时入湖** | 捕获增量变更写入数据湖 | MySQL binlog → Iceberg |
| **异构数据库迁移** | 不停机迁移数据库 | Oracle → MySQL / PG |
| **实时数据集成** | 多源汇聚到统一存储 | MySQL + PG + MongoDB → 数据湖 |
| **DDL 自动同步** | 源表加字段，目标表自动加 | Schema Evolution |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.18+ | 推荐 1.18.1 |
| Flink CDC | 3.1+ | Pipeline 模式需 3.x |
| Hadoop/YARN | 3.x | |
| MySQL | 5.7+ / 8.0+ | 需开启 binlog |
| PostgreSQL | 10+ | 需配置逻辑复制 |
| MongoDB | 4.0+ | 需开启 Change Stream |

### 2.2 环境准备命令

```bash
# 1. 下载 Flink CDC Pipeline 发行包
wget https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-dist/3.1.0/flink-cdc-dist-3.1.0-bin.tar.gz
tar -xzf flink-cdc-dist-3.1.0-bin.tar.gz -C /opt/
export FLINK_CDC_HOME=/opt/flink-cdc-3.1.0

# 2. 下载 Connector JARs
wget https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-mysql/3.1.0/flink-cdc-pipeline-connector-mysql-3.1.0.jar \
  -P $FLINK_CDC_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-starrocks/3.1.0/flink-cdc-pipeline-connector-starrocks-3.1.0.jar \
  -P $FLINK_CDC_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-doris/3.1.0/flink-cdc-pipeline-connector-doris-3.1.0.jar \
  -P $FLINK_CDC_HOME/lib/

# 3. 创建 MySQL CDC 账号
mysql -h mysql-host -uroot -p -e "
  CREATE USER 'flink_cdc'@'%' IDENTIFIED BY 'Cdc@2026!';
  GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'flink_cdc'@'%';
  FLUSH PRIVILEGES;
"

# 4. 验证 binlog 配置
mysql -h mysql-host -uroot -p -e "
  SHOW VARIABLES LIKE 'log_bin';           -- ON
  SHOW VARIABLES LIKE 'binlog_format';     -- ROW
  SHOW VARIABLES LIKE 'binlog_row_image';  -- FULL
"
```

---

## 三、核心使用方式

### 3.1 Flink CDC 3.x Pipeline 架构

```
YAML Config → Source (MySQL/PG/Mongo) → Transform → Route → Sink
特点: 整库同步 / Schema Evolution / 无需写代码
```

### 3.2 支持的 CDC 源

| 数据源 | Connector | 全量+增量 | Schema Evolution |
|--------|-----------|-----------|-----------------|
| MySQL | `mysql` | ✅ | ✅ |
| PostgreSQL | `postgres` | ✅ | ✅ |
| MongoDB | `mongodb` | ✅ | ✅ |
| Oracle | `oracle` | ✅ | ✅ |
| SQL Server | `sqlserver` | ✅ | ✅ |
| TiDB | `tidb` | ✅ | ✅ |

### 3.3 Pipeline YAML 参数详解

| 参数 | 说明 | 示例 |
|------|------|------|
| `source.type` | 源类型 | `mysql` |
| `source.tables` | 表列表（正则） | `ecommerce.\.*` |
| `source.server-id` | Server ID 范围 | `5400-5404` |
| `sink.type` | Sink 类型 | `starrocks` / `doris` / `kafka` |
| `sink.table.schema-change.strategy` | DDL 策略 | `evolve` |
| `route.source-table` | 源表匹配 | `ecommerce.\.*` |
| `route.sink-table` | 目标表映射 | `ods.ecommerce_<table-name>` |
| `pipeline.parallelism` | 并行度 | `4` |

---

## 四、完整实战示例

### 4.1 MySQL 整库 → StarRocks（Pipeline YAML）

```yaml
source:
  type: mysql
  hostname: mysql-host
  port: 3306
  username: flink_cdc
  password: "Cdc@2026!"
  tables: ecommerce.\.*
  server-id: 5400-5404
  server-time-zone: Asia/Shanghai

sink:
  type: starrocks
  jdbc-url: jdbc:mysql://starrocks-fe:9030
  load-url: starrocks-fe:8030
  username: root
  password: "your-password"
  table.create.properties.replication_num: 3
  table.schema-change.strategy: evolve

route:
  - source-table: ecommerce.\.*
    sink-table: ods.ecommerce_<table-name>

pipeline:
  name: MySQL-to-StarRocks-CDC
  parallelism: 4
  schema.change.behavior: evolve
```

### 4.2 提交命令

```bash
$FLINK_CDC_HOME/bin/flink-cdc.sh \
    --flink-home $FLINK_HOME \
    --target yarn-application \
    --yarn-application-name "MySQL-CDC-to-StarRocks" \
    -D jobmanager.memory.process.size=2048m \
    -D taskmanager.memory.process.size=4096m \
    -D execution.checkpointing.interval=60000 \
    -D state.checkpoints.dir=hdfs:///flink/checkpoints/cdc-mysql-sr \
    mysql-to-starrocks.yaml
```

### 4.3 MySQL → Doris

```yaml
source:
  type: mysql
  hostname: mysql-host
  port: 3306
  username: flink_cdc
  password: "Cdc@2026!"
  tables: ecommerce.\.*
  server-id: 5410-5414

sink:
  type: doris
  fenodes: doris-fe:8030
  username: root
  password: "your-password"
  table.schema-change.strategy: evolve

route:
  - source-table: ecommerce.\.*
    sink-table: ods.ecommerce_<table-name>

pipeline:
  name: MySQL-to-Doris-CDC
  parallelism: 4
```

### 4.4 分库分表合并

```yaml
route:
  - source-table: ecommerce_\d+.orders_\d+
    sink-table: ods.orders_merged
    description: "分库分表合并到一张表"
```

### 4.5 验证 Schema Evolution

```bash
# 源表加字段
mysql -h mysql-host -uroot -p -e "
  ALTER TABLE ecommerce.orders ADD COLUMN remark VARCHAR(256);
"
# 验证目标表自动加字段
mysql -h starrocks-fe -P 9030 -uroot -p -e "DESC ods.ecommerce_orders;"
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `Access denied for binlog` | 缺少 REPLICATION 权限 | GRANT 权限 |
| `binlog_format not ROW` | 配置不对 | 修改 my.cnf |
| `Server id conflict` | ID 冲突 | 使用不同范围 |
| 全量 OOM | 大表内存不足 | 增大 TM 内存 |
| Schema Evolution 失败 | 目标不支持某 DDL | 用 `try_evolve` 策略 |
| binlog 被清理 | expire_logs_days 太小 | 增大保留天数 |

---

## 六、生产最佳实践

### 6.1 资源配置

| 场景 | 表数量 | 并行度 | TM 内存 | Checkpoint |
|------|--------|--------|---------|-----------|
| 小库 | <10 | 2 | 2G | 60s |
| 中库 | 10~50 | 4 | 4G | 60s |
| 大库 | 50~200 | 8 | 8G | 120s |
| 分库分表 | >200 | 16 | 8G | 120s |

### 6.2 生产提交模板

```bash
$FLINK_CDC_HOME/bin/flink-cdc.sh \
    --flink-home $FLINK_HOME \
    --target yarn-application \
    --yarn-application-name "Prod-CDC" \
    -D taskmanager.memory.process.size=8192m \
    -D state.backend=rocksdb \
    -D state.backend.incremental=true \
    -D execution.checkpointing.interval=60000 \
    mysql-to-starrocks.yaml
```

---

## 七、举一反三

### 7.1 面试题

**Q: Flink CDC 如何无锁全量读取？**
> 增量快照算法：按主键分 chunk → 每 chunk 独立 SELECT → High/Low Watermark 保证一致性 → 无缝切换增量。

**Q: Schema Evolution 原理？**
> Source 监听 binlog DDL 事件 → 作为特殊 Record 发往下游 → Sink 调用目标系统 DDL 接口。

### 7.2 思考题

1. binlog 被清理后 CDC 任务如何恢复？
2. 分库分表合并时如何解决主键冲突？
3. 整库同步中某张大表 OOM，如何单独处理？

---

> 📅 **更新日期**: 2026-04-30
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
