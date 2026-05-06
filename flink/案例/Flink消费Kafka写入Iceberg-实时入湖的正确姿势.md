# Flink 消费 Kafka 写入 Iceberg — 实时入湖的正确姿势

搞实时数仓的人，迟早要面对一个问题：**怎么把 Kafka 里的数据，稳稳当当地写进数据湖？**

答案是 Flink + Kafka + Iceberg。这三个组件的组合，是目前业界公认的"实时入湖"标准方案。

本文不讲概念，直接讲：怎么配、怎么写、哪里有坑、怎么绕。

---

## 为什么是这个组合？

先说结论：

- **Kafka**：数据的"入口"，所有业务数据先进 Kafka
- **Flink**：数据的"加工厂"，实时 ETL + 写入控制
- **Iceberg**：数据的"终点"，提供 ACID 事务 + 分钟级可见

为什么不直接 Spark Streaming？因为 Flink 的 Checkpoint 机制能和 Iceberg 的两阶段提交完美对接，**天然支持 Exactly-Once 写入**。Spark Structured Streaming 也行，但在超高吞吐 + 低延迟场景下，Flink 更适合。

---

## 完整代码 — 从 Kafka 到 Iceberg

### Flink SQL 版（最简洁，生产可用）

```sql
-- 1. 创建 Kafka Source 表
CREATE TABLE kafka_orders (
    order_id    BIGINT,
    user_id     BIGINT,
    product     STRING,
    amount      DECIMAL(10,2),
    order_time  TIMESTAMP(3),
    status      STRING,
    -- Kafka 元数据
    proc_time AS PROCTIME(),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka1:9092,kafka2:9092,kafka3:9092',
    'properties.group.id' = 'flink-iceberg-writer',
    'scan.startup.mode' = 'earliest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'    -- 脏数据不要炸掉整个作业
);

-- 2. 创建 Iceberg Sink 表
CREATE TABLE iceberg_orders (
    order_id    BIGINT,
    user_id     BIGINT,
    product     STRING,
    amount      DECIMAL(10,2),
    order_time  TIMESTAMP(3),
    status      STRING
) PARTITIONED BY (days(order_time))   -- Hidden Partition，按天
WITH (
    'connector' = 'iceberg',
    'catalog-name' = 'iceberg_catalog',
    'catalog-type' = 'hive',
    'uri' = 'thrift://metastore:9083',
    'warehouse' = 'hdfs:///warehouse/iceberg',
    'format-version' = '2',
    'write.format.default' = 'parquet',
    'write.parquet.compression-codec' = 'zstd',
    'write.target-file-size-bytes' = '134217728',     -- 128MB
    'write.upsert.enabled' = 'true'                    -- 开启 upsert（需要主键）
);

-- 3. 一条 SQL 搞定实时入湖
INSERT INTO iceberg_orders
SELECT order_id, user_id, product, amount, order_time, status
FROM kafka_orders;
```

就这么简单。Flink 会自动：
1. 从 Kafka 消费数据
2. 按 Checkpoint 周期（比如 1 分钟）攒一批
3. 写入 Parquet 文件到 HDFS
4. 提交 Iceberg Snapshot（两阶段提交，保证 Exactly-Once）

### 关键配置解释

```sql
-- Flink 作业级配置（在 flink-conf.yaml 或提交参数中）
SET 'execution.checkpointing.interval' = '60s';          -- 每分钟 Checkpoint 一次
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';     -- 精确一次
SET 'execution.checkpointing.min-pause' = '30s';         -- 两次 Checkpoint 间最小间隔
SET 'state.backend' = 'rocksdb';                         -- 大状态用 RocksDB
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints';
```

**Checkpoint 间隔 = 数据可见延迟**。设 60s 意味着下游最多等 60 秒才能看到新数据。设太短（比如 5s）会导致大量小文件。

---

## Upsert 模式 — CDC 场景必备

如果你的 Kafka 里是 CDC 数据（比如 Debezium 抓的 MySQL binlog），数据带有 INSERT/UPDATE/DELETE 操作类型，你需要 Upsert 模式：

```sql
-- Iceberg 表开启 upsert
CREATE TABLE iceberg_users (
    user_id     BIGINT,
    username    STRING,
    email       STRING,
    updated_at  TIMESTAMP(3),
    PRIMARY KEY (user_id) NOT ENFORCED    -- ⭐ 声明主键
) WITH (
    'connector' = 'iceberg',
    'write.upsert.enabled' = 'true',      -- ⭐ 开启 upsert
    'format-version' = '2'                 -- V2 才支持
);

-- 直接 INSERT 即可，Flink 会自动根据主键做 upsert
INSERT INTO iceberg_users
SELECT user_id, username, email, updated_at FROM kafka_cdc_users;
```

底层原理：Flink 写入时会先写 Equality Delete File（标记旧记录删除），再写 Data File（新记录）。读取时 Iceberg 自动合并。

---

## 小文件问题 — 实时入湖的头号敌人

**问题**：每次 Checkpoint 都会产生一批文件。如果 Checkpoint 间隔 1 分钟，一天就是 1440 次 × 每次几个文件 = **几千个小文件**。

**解决方案**：

| 方案 | 说明 | 推荐度 |
|------|------|--------|
| 增大 Checkpoint 间隔 | 60s → 300s，文件数减少 5 倍，但延迟增大 | ★★★ |
| 接入 Amoro Self-Optimizing | 自动后台合并小文件，无需人工干预 | ★★★★★ |
| 定时跑 `rewrite_data_files` | 每天凌晨用 Spark 合并一次 | ★★★★ |
| 调大 `write.target-file-size-bytes` | 让每个文件写满 128MB 再切 | ★★★ |

**最优解**：Checkpoint 间隔 60-120s + Amoro 自动 Minor Compaction。这样延迟在 1-2 分钟，小文件由 Amoro 后台自动处理。

---

## Exactly-Once 是怎么保证的？

很多人说"Flink 写 Iceberg 是 Exactly-Once"，但具体怎么做到的？

```
时间线：

T0: Flink 开始 Checkpoint
     │
T1: 所有 Writer Task 停止写入，flush 内存中的数据到临时文件
     │
T2: Writer 向 Committer 汇报写入的文件列表
     │
T3: Committer（JobManager 触发）执行 Iceberg Commit
     ├─ 如果成功：Checkpoint 完成，文件对下游可见
     └─ 如果失败：Checkpoint 失败，文件不会被任何 Snapshot 引用
         → 下次 Checkpoint 重新写这批数据
         → 上次写的临时文件变成孤儿文件（等后续清理）

关键点：
  ① 文件写入和元数据提交是分开的
  ② 只有 Checkpoint 成功，Snapshot 才对外可见
  ③ 失败时不会有"半提交"状态
```

这就是为什么 Iceberg 的两阶段提交和 Flink 的 Checkpoint 机制是天作之合——两者都基于"先写数据，最后原子性提交元数据"的设计哲学。

---

## 生产踩坑清单

### 坑 1：Kafka 数据格式变了，作业挂了

**症状**：Kafka 里某些消息的 JSON 字段多了/少了/类型变了，Flink 解析报错。

**解法**：
```sql
'json.ignore-parse-errors' = 'true'    -- 解析失败的消息直接丢弃
'json.fail-on-missing-field' = 'false' -- 缺字段不报错，填 null
```

生产环境**必须**加这两个配置，否则一条脏数据就能炸掉整个作业。

### 坑 2：Checkpoint 超时导致作业反复重启

**症状**：`Checkpoint expired before completing` 日志刷屏。

**原因**：数据量大 + 写入慢 → 一个 Checkpoint 周期内写不完。

**解法**：
```yaml
execution.checkpointing.timeout: 600000    # 超时设为 10 分钟
execution.checkpointing.interval: 120000   # 间隔设为 2 分钟
execution.checkpointing.max-concurrent-checkpoints: 1
```

### 坑 3：Iceberg Commit 冲突

**症状**：`CommitFailedException: Commit failed due to conflict`

**原因**：Flink 作业和 Amoro Self-Optimizing 同时 Commit，OCC 冲突。

**解法**：增大 Iceberg 的 commit 重试次数：
```sql
'commit.retry.num-retries' = '10',
'commit.retry.total-timeout-ms' = '600000'
```

### 坑 4：Watermark 设太大导致内存爆炸

**症状**：Flink TaskManager OOM。

**原因**：Watermark 允许的延迟太大（比如 1 小时），窗口状态在内存中堆积。

**解法**：
- 如果不需要窗口计算，不要设 Watermark
- 如果需要，Watermark 延迟设为业务可接受的最小值（通常 5-30 秒）

---

## 监控指标 — 怎么知道作业健康

| 指标 | 健康值 | 告警阈值 |
|------|--------|---------|
| Checkpoint Duration | < 30s | > 60s |
| Checkpoint Size | 稳定 | 持续增长 |
| Records Lag (Kafka) | < 10000 | > 100000 |
| Iceberg Commit 成功率 | 100% | < 95% |
| 小文件数（每天） | < 500 | > 2000 |

---

## 总结

```
实时入湖的正确姿势：

Kafka (数据源)
  → Flink SQL (实时 ETL + 精确一次写入)
    → Iceberg (ACID 事务 + 分钟级可见)
      → Amoro (自动小文件合并 + 快照管理)
        → Spark/Trino (下游分析查询)

关键参数：
  Checkpoint 间隔: 60-120s（延迟 vs 小文件的平衡点）
  Iceberg format-version: 2（支持 upsert/delete）
  write.upsert.enabled: true（CDC 场景必开）
  json.ignore-parse-errors: true（脏数据保护）
  commit.retry.num-retries: 10（防 OCC 冲突）
```
