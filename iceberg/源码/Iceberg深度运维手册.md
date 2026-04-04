# Iceberg — 数据湖表格式

---

## 一、概述

Apache Iceberg 是新一代数据湖表格式，提供 ACID 事务、Schema Evolution、Time Travel、分区演化等能力。

**在集群中的角色**：替代传统 Hive 表存储，作为数据湖的标准表格式。

---

## 二、架构

```
Catalog（表元数据管理：Hive MetaStore / REST / Glue）
  ↓
Metadata Layer
  ├── metadata.json（表版本 → 指向 manifest list）
  ├── manifest-list（快照 → 包含哪些 manifest）
  └── manifest（数据文件清单 → 统计信息/分区信息）
  ↓
Data Layer
  └── data files（Parquet/ORC/Avro 格式）
```

每次写入 = 一个新 Snapshot → 一个新 manifest-list → 新的 manifest → 新的 data files

---

## 三、常见故障排查

### 3.1 查询变慢

| 概率 | 方向 | 检查 |
|------|------|------|
| 50% | 小文件过多 | `SELECT count(*), avg(file_size_in_bytes) FROM db.t.files` |
| 30% | Snapshot 堆积 | `SELECT count(*) FROM db.t.snapshots` |
| 15% | 未排序/未分区 | 检查表分区策略 |
| 5% | 删除文件过多 | Equality delete files 导致查询开销 |

### 3.2 存储空间持续增长

→ 孤立文件（orphan files）未清理。任务失败留下的残留文件。
```sql
CALL spark_catalog.system.remove_orphan_files(
  table => 'db.t',
  older_than => TIMESTAMP '2026-03-30 00:00:00'  -- 至少 3 天前！
)
```
⚠️ **间隔设太短会删正在写的文件，导致表损坏**

---

## 四、Compaction 三种策略

| 策略 | 适用场景 | 参数 |
|------|----------|------|
| **binpack** | 通用合并，不改排序 | 默认 |
| **sort** | 按列排序，提升范围查询 | `sort_order => 'dt ASC'` |
| **zorder** | 多列组合查询优化 | `var => 'col1,col2'` |

```sql
CALL spark_catalog.system.rewrite_data_files(
  table => 'db.t', strategy => 'binpack',
  where => 'dt >= "2026-04-01"',
  options => map('target-file-size-bytes','536870912')
)
```

---

## 五、Schema Evolution 安全表

| 操作 | 安全？ | 说明 |
|------|--------|------|
| 添加列 | ✅ | 历史数据该列为 null |
| 重命名列 | ✅ | 不影响数据 |
| 拓宽类型（int→long） | ✅ | 兼容 |
| 删除列 | ⚠️ | 历史数据仍存在，新查询不返回 |
| 修改分区 | ⚠️ | 新旧分区并存 |
| 类型收窄（long→int） | ❌ | 不支持 |

---

## 六、流式场景防元数据膨胀

```sql
ALTER TABLE t SET TBLPROPERTIES (
  'write.metadata.delete-after-commit.enabled' = 'true',
  'write.metadata.previous-versions-max' = '10',
  'history.expire.max-snapshot-age-ms' = '86400000',
  'history.expire.min-snapshots-to-keep' = '5'
);
```

---

## 七、维护命令速查

```sql
-- 过期快照
CALL system.expire_snapshots(table=>'db.t', older_than=>TIMESTAMP'...', retain_last=>5)
-- 合并小文件
CALL system.rewrite_data_files(table=>'db.t')
-- 清理孤立文件
CALL system.remove_orphan_files(table=>'db.t', older_than=>TIMESTAMP'...')
-- 重写 Manifest
CALL system.rewrite_manifests(table=>'db.t')
-- 查看快照
SELECT * FROM db.t.snapshots
-- 查看数据文件
SELECT file_path, file_size_in_bytes, record_count FROM db.t.files
-- 时间旅行
SELECT * FROM db.t TIMESTAMP AS OF '2026-04-01 00:00:00'
```
