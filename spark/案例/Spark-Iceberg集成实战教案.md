# Spark + Iceberg 集成实战教案 — 从建表到时间旅行

> **教学目标**：学完本课后，你能独立使用 Spark SQL 创建 Iceberg 表、执行 INSERT/UPDATE/DELETE/MERGE、进行时间旅行查询，并理解每个操作背后的元数据变化。
>
> **前置条件**：已有 Spark 3.3+ 环境 + Iceberg 1.4+ jar

---

## 一、课前故事 — 为什么需要 Iceberg？

想象你在 Excel 里编辑一份"员工表"：
- 每次保存都生成一个**版本**（Iceberg 叫 Snapshot）
- 你可以随时**回退到昨天的版本**（时间旅行）
- 多人同时编辑时，Excel 会**提醒冲突**（OCC 乐观锁）
- 你可以**重命名列**而不影响旧数据（Schema Evolution）

Iceberg = 给大数据表加上了 **"版本管理 + 事务 + Schema演化"** 能力。

---

## 二、环境配置（完整可运行）

### 2.1 spark-defaults.conf

```properties
# ===== Iceberg 基础配置 =====
spark.sql.extensions                   = org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.iceberg              = org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.iceberg.type         = hive           # 使用 Hive Metastore 作为 Catalog
spark.sql.catalog.iceberg.uri          = thrift://metastore-host:9083

# 如果用 Hadoop Catalog（无需 Metastore）:
# spark.sql.catalog.iceberg.type       = hadoop
# spark.sql.catalog.iceberg.warehouse  = hdfs:///warehouse/iceberg

# ===== 性能优化 =====
spark.sql.catalog.iceberg.cache-enabled = true          # 缓存表元数据
spark.sql.iceberg.handle-timestamp-without-timezone = true
```

### 2.2 提交命令

```bash
spark-sql \
  --packages org.apache.iceberg:iceberg-spark-runtime-3.3_2.12:1.4.3 \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.iceberg.type=hive \
  --conf spark.sql.catalog.iceberg.uri=thrift://localhost:9083
```

---

## 三、建表 — 你的第一张 Iceberg 表

### 3.1 基础建表

```sql
-- 创建数据库
CREATE DATABASE IF NOT EXISTS iceberg.my_db;

-- 创建表（分区表）
CREATE TABLE iceberg.my_db.orders (
    order_id    BIGINT,
    user_id     BIGINT,
    product     STRING,
    amount      DECIMAL(10,2),
    order_time  TIMESTAMP,
    status      STRING
)
USING iceberg
PARTITIONED BY (days(order_time))  -- ⭐ Hidden Partition：按天分区但不暴露分区列
TBLPROPERTIES (
    'format-version' = '2',                         -- V2 支持行级删除
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728'    -- 128MB
);
```

### 3.2 关键知识点

| 特性 | 说明 | 类比 |
|------|------|------|
| **Hidden Partition** | `days(order_time)` 自动从字段计算分区值，用户无需感知 | 像 MySQL 的表分区但更智能 |
| **Format V2** | 支持 Position Delete + Equality Delete（行级更新/删除） | 像 Git 的行级 diff |
| **Schema Evolution** | 后续可以加列/改名/删列，不影响历史数据 | 像数据库的 ALTER TABLE 但零成本 |

---

## 四、写入数据 — INSERT/INSERT OVERWRITE

### 4.1 追加写入

```sql
-- 追加新数据
INSERT INTO iceberg.my_db.orders VALUES
(1001, 1, 'iPhone', 5999.00, TIMESTAMP '2024-03-15 10:30:00', 'paid'),
(1002, 2, 'MacBook', 12999.00, TIMESTAMP '2024-03-15 14:20:00', 'shipped'),
(1003, 1, 'AirPods', 1299.00, TIMESTAMP '2024-03-16 09:10:00', 'paid');

-- 从其他表导入
INSERT INTO iceberg.my_db.orders
SELECT * FROM hive.legacy_db.old_orders WHERE order_time > '2024-01-01';
```

### 4.2 覆盖写入（按分区）

```sql
-- 动态覆盖：只覆盖有数据的分区
INSERT OVERWRITE iceberg.my_db.orders
SELECT * FROM staging.today_orders;

-- 静态覆盖：覆盖指定分区
INSERT OVERWRITE iceberg.my_db.orders
PARTITION (order_time_day = '2024-03-15')
SELECT * FROM staging.orders_20240315;
```

**类比**：
- `INSERT INTO` = Git 的 `commit`（追加变更）
- `INSERT OVERWRITE` = Git 的 `force push`（覆盖指定分支）

---

## 五、更新与删除 — V2 的行级能力

### 5.1 UPDATE

```sql
-- 更新订单状态
UPDATE iceberg.my_db.orders
SET status = 'cancelled'
WHERE order_id = 1001;

-- 批量更新
UPDATE iceberg.my_db.orders
SET status = 'delivered', amount = amount * 0.9  -- 打9折
WHERE status = 'shipped' AND order_time < TIMESTAMP '2024-03-01 00:00:00';
```

### 5.2 DELETE

```sql
-- 删除特定订单
DELETE FROM iceberg.my_db.orders
WHERE order_id = 1003;

-- 按条件批量删除
DELETE FROM iceberg.my_db.orders
WHERE status = 'cancelled' AND order_time < TIMESTAMP '2024-01-01 00:00:00';
```

### 5.3 MERGE INTO（Upsert 最常用！）

```sql
-- 典型场景：CDC 增量更新
MERGE INTO iceberg.my_db.orders AS target
USING (SELECT * FROM staging.orders_update) AS source
ON target.order_id = source.order_id
WHEN MATCHED AND source.status = 'deleted' THEN DELETE
WHEN MATCHED THEN UPDATE SET
    status = source.status,
    amount = source.amount
WHEN NOT MATCHED THEN INSERT *;
```

**课堂提问**：MERGE INTO 的底层是怎么实现的？
> 答：Copy-On-Write (COW) 模式下，受影响的数据文件会被全量重写；
> Merge-On-Read (MOR) 模式下，只写入 Delete File + Insert File，读取时合并。

---

## 六、时间旅行 — Iceberg 的"后悔药"

### 6.1 查看快照历史

```sql
-- 查看所有快照
SELECT * FROM iceberg.my_db.orders.snapshots;

-- 查看快照文件
SELECT * FROM iceberg.my_db.orders.files;

-- 查看操作历史
SELECT * FROM iceberg.my_db.orders.history;
```

### 6.2 按时间旅行

```sql
-- 查询昨天的数据
SELECT * FROM iceberg.my_db.orders
TIMESTAMP AS OF '2024-03-15 00:00:00';

-- 查询某个快照版本的数据
SELECT * FROM iceberg.my_db.orders
VERSION AS OF 1234567890;  -- snapshot_id
```

### 6.3 回滚操作

```sql
-- 回滚到某个快照（撤销错误操作）
CALL iceberg.system.rollback_to_snapshot('my_db.orders', 1234567890);

-- 回滚到某个时间点
CALL iceberg.system.rollback_to_timestamp('my_db.orders', TIMESTAMP '2024-03-15 00:00:00');
```

**类比**：
- 时间旅行 = Git 的 `git checkout <commit-hash>`
- 回滚 = Git 的 `git revert`

---

## 七、Schema Evolution — 零成本表结构变更

```sql
-- 加列
ALTER TABLE iceberg.my_db.orders ADD COLUMNS (
    coupon_code STRING COMMENT '优惠券码',
    delivery_address STRING COMMENT '收货地址'
);

-- 重命名列
ALTER TABLE iceberg.my_db.orders RENAME COLUMN product TO product_name;

-- 修改列类型（只能宽化：int→bigint, float→double）
ALTER TABLE iceberg.my_db.orders ALTER COLUMN amount TYPE DECIMAL(12,2);

-- 删列（只标记删除，不重写文件！）
ALTER TABLE iceberg.my_db.orders DROP COLUMN coupon_code;
```

**为什么"零成本"？** 因为 Iceberg 用 Schema ID 映射，旧文件不需要重写，读取时自动适配。

---

## 八、维护操作 — 保持表健康

```sql
-- ① 过期快照（释放存储空间）
CALL iceberg.system.expire_snapshots(
    table => 'my_db.orders',
    older_than => TIMESTAMP '2024-03-08 00:00:00',
    retain_last => 5
);

-- ② 清理孤儿文件
CALL iceberg.system.remove_orphan_files(
    table => 'my_db.orders',
    older_than => TIMESTAMP '2024-03-10 00:00:00'
);

-- ③ 重写数据文件（小文件合并）
CALL iceberg.system.rewrite_data_files(
    table => 'my_db.orders',
    options => map('target-file-size-bytes', '134217728')
);

-- ④ 重写 Manifest 文件（元数据优化）
CALL iceberg.system.rewrite_manifests('my_db.orders');
```

**执行顺序铁律**：expire_snapshots → remove_orphan_files → rewrite_data_files → rewrite_manifests

---

## 九、踩坑大全

| 坑 | 症状 | 解决 |
|----|------|------|
| 小文件爆炸 | 流式写入产生大量小文件，查询变慢 | 定期 `rewrite_data_files` 或接入 Amoro |
| MERGE 性能差 | MERGE INTO 大表耗时很长 | 确认使用 `write.distribution-mode=hash` |
| 时间旅行查询慢 | 历史快照太多，Planning 慢 | 定期 `expire_snapshots` + `rewrite_manifests` |
| 并发写入冲突 | CommitFailedException | 增大 `commit.retry.num-retries` |
| OOM | Spark Driver OOM | 大表 MERGE 时增大 `spark.driver.memory` |

---

## 十、课堂练习

### 练习 1：设计一张用户行为表

> 需求：存储用户点击事件（user_id, event_type, page_url, event_time），按天分区，支持按 user_id 更新，保留 30 天数据。

参考答案：
```sql
CREATE TABLE iceberg.analytics.user_events (
    user_id     BIGINT,
    event_type  STRING,
    page_url    STRING,
    event_time  TIMESTAMP
) USING iceberg
PARTITIONED BY (days(event_time))
TBLPROPERTIES (
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd',
    'write.distribution-mode' = 'hash',
    'history.expire.max-snapshot-age-ms' = '2592000000',  -- 30天
    'history.expire.min-snapshots-to-keep' = '10'
);
```

### 练习 2：举一反三

> "Iceberg 的 MERGE INTO 与 MySQL 的 INSERT ... ON DUPLICATE KEY UPDATE 有什么同构关系？两者的性能特点有何不同？"

答：
- 功能等价：都是"有则更新，无则插入"
- 性能差异巨大：MySQL 是单条行级操作，Iceberg 是批量文件级重写
- Iceberg 适合**批量 Upsert**（如 CDC），不适合高频单条 Upsert

---

## 十一、知识晶体

```
问题/场景: 如何用 Spark 操作 Iceberg 表实现湖仓一体？
核心配置: SparkSessionExtensions + SparkCatalog + format-version=2
调用链: Spark SQL → IcebergSparkSessionExtensions → DataSourceV2 → Iceberg Core → 文件系统
设计意图: 通过 DataSourceV2 API 将 Iceberg 的事务/快照/Schema演化能力无缝接入 Spark
关键配置:
  spark.sql.extensions              → 注册 Iceberg SQL 扩展
  spark.sql.catalog.{name}.type     → hive/hadoop/rest（Catalog 类型）
  format-version                    → 2（支持行级操作）
  write.distribution-mode           → hash（MERGE 性能关键）
踩坑记录:
  - Catalog 名称必须在 SQL 中作为前缀使用（iceberg.db.table）
  - MERGE INTO 需要 format-version=2，V1 不支持
  - Hidden Partition 修改后历史数据不受影响（Partition Evolution）
认知更新: Iceberg 不是"另一种文件格式"，它是一个"表管理层"——站在 Parquet/ORC 之上，提供事务/版本/Schema 管理
```
