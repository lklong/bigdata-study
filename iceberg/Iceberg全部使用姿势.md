# Apache Iceberg 全部使用姿势（权威版）

> 作者：eric  |  版本：v1.0  |  日期：2026-04-24  
> 覆盖面：定位 / 架构 / Catalog / DDL / 读写 / 维护 / 时空旅行 / 分支标签 / 引擎集成 / 权限 / 运维  
> 证据来源：`D:\bigdata\txproject\iceberg`（源码）+ `iceberg\docs`（官方手册）  
> 说明：所有 SQL 语法、Procedure 名、参数均以源码/docs 为准，Challenger 审查后标注。

---

## 0. 一句话定位

Iceberg = **面向 OLAP 的开放表格式 (Table Format)**，它不是存储、不是引擎、不是元数据服务，而是"元数据规范 + 客户端库"。  
典型定位：Spark/Flink/Trino 直接读写数据湖上同一份数据，具备 ACID、Schema/Partition Evolution、Time Travel、Branching、行级 DML。

对标：Delta Lake / Apache Hudi / Apache Paimon。

---

## 1. 体系结构（三层元数据）

```
表（Table）
  └─ metadata.json  (当前表状态：schema/partitionspec/snapshot 列表)
       └─ Snapshot  (一次提交=一个快照)
            └─ Manifest List  (.avro，列出该 snapshot 的所有 manifest)
                 └─ Manifest File  (.avro，列出一批 data/delete 文件)
                      └─ Data File   (parquet/orc/avro)
                      └─ Delete File (position delete / equality delete)
```

关键点：
- 每次写入 → **新 snapshot**；读者看的是某个 snapshot 下的完整文件列表，天然隔离。
- 元数据完全自描述，**不依赖 HMS 做分区**（HMS 只是可选 catalog）。
- 每个文件都有列级 min/max/null_count 统计，支持文件级剪枝。

---

## 2. Catalog（目录）姿势

Iceberg 的 Catalog = 表路由器。选什么 Catalog 决定表住在哪、元数据怎么加锁、跨引擎是否互通。

| Catalog | 类名 | 特点 | 典型场景 |
|---------|------|------|----------|
| **HiveCatalog** | `org.apache.iceberg.hive.HiveCatalog` | 元数据落 HMS，跨引擎通用 | 最常用，和现有 HMS 体系无缝 |
| **HadoopCatalog** | `org.apache.iceberg.hadoop.HadoopCatalog` | 元数据直接放 HDFS/S3 目录 | 无 HMS 的小集群、测试 |
| **RESTCatalog** | `org.apache.iceberg.rest.RESTCatalog` | 走标准 REST 协议 | 云原生、多租户、权限集中 |
| **GlueCatalog** | `org.apache.iceberg.aws.glue.GlueCatalog` | AWS Glue Data Catalog | AWS EMR 生态 |
| **NessieCatalog** | `org.apache.iceberg.nessie.NessieCatalog` | Git-like 版本化元数据 | 多分支数据工程 |
| **JdbcCatalog** | `org.apache.iceberg.jdbc.JdbcCatalog` | 元数据落 MySQL/PG | 轻量、无 HMS |
| **SnowflakeCatalog** | `org.apache.iceberg.snowflake.*` | 读 Snowflake 管理的 Iceberg 表 | Snowflake 集成 |

Spark 配置示例（HiveCatalog）：
```properties
spark.sql.catalog.prod                  = org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.prod.type             = hive
spark.sql.catalog.prod.uri              = thrift://hms:9083
spark.sql.catalog.prod.warehouse        = hdfs:///warehouse/iceberg
spark.sql.extensions                    = org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
```

> Challenger 提示：`spark.sql.extensions` 必须配，否则 `CALL system.xxx` / 分区演化 / MERGE INTO 部分语法会挂。

---

## 3. DDL 全家桶（Spark 3 为基准）

### 3.1 建表
```sql
CREATE TABLE prod.db.sample (
    id bigint, data string, category string, ts timestamp)
USING iceberg
PARTITIONED BY (bucket(16, id), days(ts), category)
TBLPROPERTIES ('format-version'='2', 'write.format.default'='parquet');
```

分区 transform：`years/months/days/hours/date/date_hour/bucket(N, col)/truncate(L, col)`。

### 3.2 CTAS / RTAS
```sql
CREATE TABLE prod.db.a USING iceberg AS SELECT * FROM src;
REPLACE TABLE  prod.db.a USING iceberg AS SELECT * FROM src;  -- 保留 history
CREATE OR REPLACE TABLE prod.db.a USING iceberg AS SELECT * FROM src;
```

### 3.3 ALTER
```sql
ALTER TABLE prod.db.a RENAME TO prod.db.b;
ALTER TABLE prod.db.a SET TBLPROPERTIES ('read.split.target-size'='268435456');
ALTER TABLE prod.db.a UNSET TBLPROPERTIES ('key');
ALTER TABLE prod.db.a ADD COLUMN addr string AFTER data;
ALTER TABLE prod.db.a DROP COLUMN addr;
ALTER TABLE prod.db.a RENAME COLUMN data TO payload;
ALTER TABLE prod.db.a ALTER COLUMN id TYPE bigint;       -- 仅类型拓宽
ALTER TABLE prod.db.a ALTER COLUMN addr DROP NOT NULL;
```

### 3.4 DROP
```sql
DROP TABLE prod.db.a;          -- 0.14+ 仅删 catalog 条目，不删数据
DROP TABLE prod.db.a PURGE;    -- 连数据一起删
```

### 3.5 分区演化（重量级能力）
```sql
ALTER TABLE prod.db.sample ADD PARTITION FIELD days(ts);
ALTER TABLE prod.db.sample DROP PARTITION FIELD days(ts);
ALTER TABLE prod.db.sample REPLACE PARTITION FIELD days(ts) WITH hours(ts);
```

**关键语义**：旧数据保留原分区；新数据按新分区写入；查询时 Iceberg 自动按 snapshot 的 spec-id 应用正确的分区。**不需要重写历史数据**。

### 3.6 写入排序（Write Order）
```sql
ALTER TABLE prod.db.sample WRITE ORDERED BY category, ts;
```
写入时按该顺序排序文件内数据，有利于按 category/ts 过滤的查询。

---

## 4. 读写姿势

### 4.1 Spark 读
```sql
-- 常规读（自动 metadata filter + split planning）
SELECT * FROM prod.db.sample WHERE ts > current_date() - 1;

-- 时间旅行
SELECT * FROM prod.db.sample VERSION AS OF 3821550127947089009;
SELECT * FROM prod.db.sample TIMESTAMP AS OF '2025-12-01 00:00:00';

-- 按 branch / tag 读（Iceberg 1.2+）
SELECT * FROM prod.db.sample VERSION AS OF 'audit-2025';

-- 增量读（CDC）
SELECT * FROM prod.db.sample.changes
 WHERE snapshot_id > 100 AND snapshot_id <= 200;
```

### 4.2 Spark 写
```sql
INSERT INTO  prod.db.sample VALUES (1, 'a', 'x', now());
INSERT OVERWRITE prod.db.sample PARTITION (category='x') SELECT ...;

-- 行级 DML（v2 表）
UPDATE prod.db.sample SET data = 'xx' WHERE id = 1;
DELETE FROM prod.db.sample WHERE id = 1;

MERGE INTO prod.db.sample t USING src s
ON t.id = s.id
WHEN MATCHED THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT *;
```

**两种行级写模式**（表属性控制）：

| 模式 | 属性 | 写放大 | 读放大 | 适用 |
|------|------|--------|--------|------|
| **Copy-on-Write (CoW)** | `write.update.mode=copy-on-write` | 高 | 低 | 少量更新，读多 |
| **Merge-on-Read (MoR)** | `write.update.mode=merge-on-read` | 低 | 高 | 大量更新，读少/能承受 compaction |

同理 `write.delete.mode` / `write.merge.mode`。

### 4.3 Flink 读写
```sql
-- Flink SQL：批
INSERT INTO hive_catalog.default.sample SELECT * FROM src;

-- Flink SQL：流
INSERT INTO hive_catalog.default.sample /*+ OPTIONS('streaming'='true') */
SELECT * FROM kafka_source;

-- 流读 Iceberg
SELECT * FROM hive_catalog.default.sample /*+ OPTIONS(
  'streaming'='true',
  'monitor-interval'='1s',
  'start-snapshot-id'='xxx') */;
```

> **限制**：Flink 流作业不支持 `INSERT OVERWRITE`；只有 batch 才行。

### 4.4 Trino / Presto
```sql
-- 读写几乎对等 Spark
SELECT * FROM iceberg.db.sample FOR VERSION AS OF 123;
INSERT INTO iceberg.db.sample ...;
CALL iceberg.system.rewrite_data_files('db.sample');
```

### 4.5 Java API（写管道必备）
```java
Table table = catalog.loadTable(TableIdentifier.of("db", "sample"));
DataFile df = DataFiles.builder(table.spec())
    .withPath("hdfs:///.../data.parquet")
    .withFileSizeInBytes(...)
    .withRecordCount(...)
    .build();
table.newAppend().appendFile(df).commit();
```

---

## 5. 维护姿势（生产级必做）

Iceberg 不会自动做小文件合并和垃圾回收，**必须**配调度。

### 5.1 过期快照 `expire_snapshots`
```sql
-- Spark SQL 调用
CALL prod.system.expire_snapshots(
  table => 'db.sample',
  older_than => TIMESTAMP '2025-12-01 00:00:00',
  retain_last => 5
);
```
释放旧快照对应的数据文件；默认只会删"无人引用"的文件。

### 5.2 删除孤儿文件 `remove_orphan_files`
```sql
CALL prod.system.remove_orphan_files(
  table => 'db.sample',
  older_than => TIMESTAMP '2025-12-01 00:00:00'
);
```
清理任务失败遗留、快照机制外的文件。**默认保留阈值 3 天**，谨慎缩短。

### 5.3 合并数据文件 `rewrite_data_files`
```sql
CALL prod.system.rewrite_data_files(
  table => 'db.sample',
  strategy => 'binpack',       -- 或 'sort'
  options => map(
    'target-file-size-bytes','536870912',
    'max-concurrent-file-group-rewrites','5')
);
```

### 5.4 合并 manifest `rewrite_manifests`
```sql
CALL prod.system.rewrite_manifests('db.sample');
```

### 5.5 自动元数据清理（写侧配置）
```sql
ALTER TABLE prod.db.sample SET TBLPROPERTIES (
  'write.metadata.delete-after-commit.enabled'='true',
  'write.metadata.previous-versions-max'='50'
);
```

### 5.6 完整清单（源码 `spark/v3.5/.../procedures/`）

| Procedure | 用途 |
|-----------|------|
| `rollback_to_snapshot` | 回滚到快照 |
| `rollback_to_timestamp` | 回滚到时间 |
| `set_current_snapshot` | 强设当前快照（可以不是祖先） |
| `cherrypick_snapshot` | 挑拣快照合入 |
| `publish_changes` | 发布 WAP 分支改动 |
| `expire_snapshots` | 过期快照 |
| `remove_orphan_files` | 删孤儿文件 |
| `rewrite_data_files` | 合并数据文件 |
| `rewrite_manifests` | 合并 manifest |
| `rewrite_position_delete_files` | 合并 position delete |
| `register_table` | 注册外部元数据到当前 catalog |
| `migrate` | Hive 表迁入 Iceberg（原地） |
| `snapshot` | 从 Hive 复制出 Iceberg 影子表 |
| `ancestors_of` | 查快照祖先链 |
| `fast_forward` | 快进分支 |

---

## 6. 分支 / 标签（Branching & Tagging）

```sql
-- 创建标签（保留 180 天）
ALTER TABLE prod.db.sample CREATE TAG 'EOY-2025'
  AS OF VERSION 365 RETAIN 180 DAYS;

-- 创建分支（保留 7 天，分支上保留最近 2 个快照）
ALTER TABLE prod.db.sample CREATE BRANCH 'test-branch'
  RETAIN 7 DAYS WITH RETENTION 2 SNAPSHOTS;

-- 删除
ALTER TABLE prod.db.sample DROP TAG 'EOY-2025';
ALTER TABLE prod.db.sample DROP BRANCH 'test-branch';

-- 在分支上写
INSERT INTO prod.db.sample.branch_test_branch VALUES (...);
```

使用场景：
- **GDPR 合规审计** → tag 关键时点
- **WAP (Write-Audit-Publish)** → 在 staging 分支写 → 校验 → `publish_changes` 合入 main
- **回滚演练** → 分支上做修复，验收后切回主线

---

## 7. 引擎集成总览

| 引擎 | 读 | 写 | 流 | MERGE | Procedure | Branching | 备注 |
|------|----|----|----|-------|-----------|-----------|------|
| Spark 3.3+ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 功能最完整 |
| Flink 1.16+ | ✅ | ✅ | ✅ | ❌ | ❌ | 部分 | 批流一体 |
| Trino 400+ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | 即席查询佳 |
| Presto | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | 功能少于 Trino |
| Hive 3.x | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | 通过 Storage Handler |
| Impala 4.x | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | |
| PyIceberg | ✅ | ✅（有限） | ❌ | ❌ | ❌ | ✅ | 无需 JVM |
| StarRocks | ✅ | 部分 | ❌ | ❌ | ❌ | 部分 | 外表加速 |
| Doris | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | 只读 |

---

## 8. 权限与安全

Iceberg 本身不做权限，依赖：
- **Ranger Iceberg Plugin**（Spark/Hive/Trino 各自的 plugin）
- **RESTCatalog** 级权限（更干净，token/OAuth）
- **HMS + HDFS ACL**（保守做法，文件级）

典型做法：
```properties
# Spark + Ranger
spark.sql.extensions = org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions,\
                       org.apache.kyuubi.plugin.spark.authz.ranger.RangerSparkExtension
```

> Challenger 提示：Ranger 的 Iceberg 策略作用在 Catalog + Namespace + Table，**对 `system.<procedure>` 的授权单独设计**，别漏。

---

## 9. 关键表属性（常用调优）

| 属性 | 默认 | 含义 |
|------|------|------|
| `format-version` | 2 | v2 支持行级 delete；v1 仅 append |
| `write.format.default` | parquet | data 文件格式：parquet/orc/avro |
| `write.parquet.row-group-size-bytes` | 128MB | Parquet row group 大小 |
| `write.target-file-size-bytes` | 512MB | 目标单文件大小 |
| `write.distribution-mode` | none | none/hash/range（写时 shuffle 策略） |
| `write.update.mode` | copy-on-write | 更新语义 |
| `write.delete.mode` | copy-on-write | 删除语义 |
| `write.merge.mode` | copy-on-write | merge 语义 |
| `read.split.target-size` | 128MB | 读时 split 大小 |
| `read.split.planning-lookback` | 10 | 并发规划 split |
| `history.expire.max-snapshot-age-ms` | 5 天 | snapshot 最大年龄 |
| `history.expire.min-snapshots-to-keep` | 1 | 至少保留几个 |
| `write.metadata.delete-after-commit.enabled` | false | 自动清理老 metadata.json |
| `write.metadata.previous-versions-max` | 100 | 保留多少 metadata |

---

## 10. 迁移 / 注册姿势

### 10.1 Hive → Iceberg 原地迁移
```sql
CALL prod.system.migrate('db.hive_table', map('some-key','value'));
```
原地把 Hive 表改为 Iceberg（**不可逆**）。

### 10.2 Hive → Iceberg 影子表（推荐 POC）
```sql
CALL prod.system.snapshot('db.hive_table', 'prod.db.iceberg_shadow');
```
读同一份数据但以 Iceberg 形式查询，Hive 侧不受影响。

### 10.3 注册已有 metadata.json
```sql
CALL prod.system.register_table(
  table => 'prod.db.sample',
  metadata_file => 'hdfs:///.../metadata/v123.metadata.json'
);
```

### 10.4 Delta Lake → Iceberg
参考 `docs/delta-lake-migration.md`，走 `snapshotDeltaLakeTable`。

---

## 11. 典型使用场景对照

| 场景 | 推荐配置 |
|------|----------|
| 离线数仓（T+1 全量/增量） | v2 + CoW + HiveCatalog + 每日 `rewrite_data_files` |
| 近实时（分钟级 CDC） | v2 + MoR + Flink Upsert + 每小时 compaction（推荐 Amoro 自动化） |
| 审计/合规 | v2 + Tag 保留关键时点 + WAP 分支发布 |
| 跨区多机房 | RESTCatalog + 对象存储 + `write.metadata.metrics.default=full` |
| 非结构化外接 | v1 + HadoopCatalog + 只读查询 |
| Python 数据科学 | PyIceberg + Arrow + Duckdb 本地查询 |

---

## 12. 功能边界

| 不是 | 替代 |
|------|------|
| 存储系统 | HDFS/S3/OSS/COS/ADLS 等 |
| 查询引擎 | Spark/Flink/Trino |
| 实时流处理 | Flink（Iceberg 是 sink/source） |
| 低延迟点查 | 用 HBase/ClickHouse |
| **自动 Compaction** | **用 Amoro** / 自己调 Airflow |

---

## 13. Challenger 审查记录

| 审查项 | 问题 | 处置 |
|--------|------|------|
| "DROP TABLE 删数据" | 0.14 前的旧行为 | ✅ 已标注版本分界 |
| "分区 transform 不可变" | 早期描述不准确 | ✅ 已改为"Partition Evolution"语义 |
| "MERGE INTO 全引擎支持" | Flink/Hive 不支持 | ✅ 已改为矩阵标注 |
| "Flink 流支持 INSERT OVERWRITE" | 明确不支持（源码） | ✅ 已在 §4.3 写出限制 |
| "MOR 读放大" | 细化为 "delete file 合并代价" | ✅ |
| "remove_orphan_files 默认 3 天" | 原文确认 | ✅ 已保留警告 |
| "format-version=1 也支持 MERGE" | 错误，MERGE/Delete 要 v2 | ✅ 已明示 v2 |

**裁决：APPROVED**。

---

*eric | Iceberg 全部使用姿势 v1.0 | 2026-04-24*
