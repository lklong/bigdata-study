# 教案 18：Iceberg 生产环境最佳实践 20 条 — 血泪教训汇总

> **课时**：45分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入

> 这 20 条实践来自生产环境的**真实踩坑经验**。每条都对应一个"如果不这样做会怎样"的痛苦故事。

## 二、建表阶段 (5 条)

### 1. 必须用 Hidden Partitioning
```sql
-- 错误：暴露分区列
PARTITIONED BY (dt STRING)  -- Hive 风格，用户必须知道分区列

-- 正确：隐式分区
PARTITIONED BY (days(event_time))  -- 用户只写 WHERE event_time > xxx
```
**不这样做会怎样**：用户查询不带分区条件时全表扫描。

### 2. 设置合理的 target-file-size
```sql
TBLPROPERTIES ('write.target-file-size-bytes' = '134217728')  -- 128MB
```
**不这样做会怎样**：默认太小会产生大量小文件，默认太大会影响并行度。

### 3. 选择正确的写模式
```sql
-- 读多写少 → CoW
TBLPROPERTIES ('write.delete.mode' = 'copy-on-write')
-- 写频繁 → MoR
TBLPROPERTIES ('write.delete.mode' = 'merge-on-read')
```

### 4. 设置 Schema 的 identifier-fields（主键）
用于 UPSERT/MERGE 操作的去重依据。

### 5. 开启元数据自动清理
```sql
TBLPROPERTIES ('write.metadata.delete-after-commit.enabled' = 'true')
```

## 三、写入阶段 (5 条)

### 6. Streaming 写入必须配 distribution-mode=hash
```sql
TBLPROPERTIES ('write.distribution-mode' = 'hash')
```
**不这样做会怎样**：每个 Writer 都写所有分区 → 爆炸性小文件。

### 7. Checkpoint/Commit 间隔不能太短
最短 60 秒，推荐 120-300 秒。太短 = 太多 Snapshot + 太多小文件。

### 8. 并发写入必须理解 OCC
两个 Job 写同一分区可能冲突。`commit.retry.num-retries=4` 确保重试。

### 9. Spark INSERT OVERWRITE 用 dynamic 模式
```sql
SET spark.sql.sources.partitionOverwriteMode=dynamic;
-- 只覆盖涉及的分区，不影响其他分区
```

### 10. 大批量写入前先排序
```python
df.sortWithinPartitions("partition_col").writeTo("table")
```
减少小文件，提高压缩率。

## 四、维护阶段 (5 条)

### 11. 必须定期 Expire Snapshots
```sql
CALL catalog.system.expire_snapshots('db.table', TIMESTAMP '2024-01-01', 10);
```
**不这样做会怎样**：元数据膨胀 → Planning 越来越慢。

### 12. 必须定期 Rewrite Data Files
```sql
CALL catalog.system.rewrite_data_files('db.table');
```
合并小文件，消除 Delete File。

### 13. 必须清理 Orphan Files
```sql
CALL catalog.system.remove_orphan_files('db.table');
```
**不这样做会怎样**：存储费用每月增长。

### 14. 用 Amoro 自动化以上三项
配置 Self-Optimizing 后以上全自动，不用手动跑。

### 15. 监控 Manifest 数量
`SELECT * FROM db.table.manifests` — 超过 1000 个就该重写了。

## 五、查询阶段 (5 条)

### 16. 利用列裁剪 + 谓词下推
只 SELECT 需要的列，WHERE 条件写在分区字段上。

### 17. 大表查询设置 split-size
```sql
SET spark.sql.files.maxPartitionBytes=268435456;  -- 256MB
```

### 18. 时间旅行查询要带 Snapshot ID 而非时间戳
```sql
-- 快（精确）
SELECT * FROM db.table VERSION AS OF 12345;
-- 慢（需要扫描 Snapshot 列表）
SELECT * FROM db.table TIMESTAMP AS OF '2024-01-15';
```

### 19. 开启 Bloom Filter 加速点查
```sql
ALTER TABLE db.table SET TBLPROPERTIES (
    'write.parquet.bloom-filter-enabled.column.user_id' = 'true'
);
```

### 20. 定期 ANALYZE TABLE 更新统计信息
```sql
ANALYZE TABLE db.table COMPUTE STATISTICS FOR ALL COLUMNS;
```
让优化器做出正确的 Join 策略决策。

## 六、知识晶体

```
建表5条: Hidden分区 + target-size=128MB + 写模式 + 主键 + 元数据清理
写入5条: distribution=hash + commit间隔≥60s + OCC重试 + 排序写入
维护5条: Expire + Rewrite + Orphan + Amoro自动化 + 监控Manifest
查询5条: 列裁剪 + split-size + SnapshotID查 + BloomFilter + ANALYZE
```

*教案作者：Eric | 最后更新：2026-04-30*
