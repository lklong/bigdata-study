# Amoro + Iceberg 生产环境最佳配置组合 — 不丢数据的稳妥方案

> **来源**：源码逐行验证（Amoro TableProperties.java + Iceberg TableProperties.java）+ 社区 Issue/PR 修复 + 官方文档 + 生产实践
> **原则**：宁可多留、少删、慢清，绝不在任何环节冒丢数据的风险
> **适用版本**：Amoro 0.7.x+ / Iceberg 1.4.x+ / Spark 3.3+
> **作者**：Eric（豹纹） | 2026-04-29

---

## 一、配置全景架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    Iceberg 表级配置                          │
│  (通过 ALTER TABLE SET TBLPROPERTIES 设置)                   │
│                                                             │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────────┐   │
│  │ Commit 安全  │ │ Snapshot 保留 │ │ 文件格式与写入      │   │
│  │ (OCC 重试)   │ │ (GC 策略)    │ │ (性能与压缩)       │   │
│  └─────────────┘ └──────────────┘ └────────────────────┘   │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    Amoro 表级配置                            │
│  (通过 Amoro Dashboard 或 ALTER TABLE 设置)                  │
│                                                             │
│  ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐  │
│  │ Self-Optimizing│ │ 快照过期      │ │ 孤儿文件清理       │  │
│  │ (小文件合并)   │ │ (Amoro 管控)  │ │ (危险操作保护)     │  │
│  └──────────────┘ └──────────────┘ └────────────────────┘  │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                    维护操作执行顺序                          │
│                                                             │
│    ① Expire Snapshots  →  ② Remove Orphan Files            │
│              →  ③ Rewrite Manifests / Data Files            │
│                                                             │
│    ⚠️ 顺序不可颠倒！否则可能丢数据！                          │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、Iceberg 表级配置（不丢数据底线）

### 2.1 Commit 安全配置 — OCC 并发冲突保护

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⭐ Commit 重试：防止并发写入冲突导致数据丢失
  'commit.retry.num-retries'           = '10',      -- 默认4，生产建议10（高并发场景）
  'commit.retry.min-wait-ms'           = '100',     -- 默认100，保持不变
  'commit.retry.max-wait-ms'           = '60000',   -- 默认60s，保持不变
  'commit.retry.total-timeout-ms'      = '3600000', -- 默认30min，生产建议60min（大表commit慢）

  -- ⭐ Commit 状态检查：网络抖动后确认commit是否成功（防重复提交）
  'commit.status-check.num-retries'        = '5',       -- 默认3，建议5
  'commit.status-check.min-wait-ms'        = '1000',    -- 默认1s
  'commit.status-check.max-wait-ms'        = '60000',   -- 默认60s
  'commit.status-check.total-timeout-ms'   = '3600000'  -- 默认30min，建议60min
);
```

**为什么这样配**：
- Iceberg 使用 OCC（乐观并发控制），commit 冲突时靠重试保证数据不丢
- `num-retries=10` 是因为 Amoro self-optimizing 和用户写入会并发 commit
- `total-timeout-ms=60min` 是因为大表（TB 级）commit 可能需要合并大量 manifest

### 2.2 Snapshot 保留配置 — 时间旅行 + 回滚安全

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⭐ 快照保留策略：宁多勿少
  'history.expire.max-snapshot-age-ms'     = '604800000',  -- 7天（默认5天）
  'history.expire.min-snapshots-to-keep'   = '5',          -- 至少保留5个（默认1个，太危险！）

  -- ⭐ GC 开关：生产环境必须开启
  'gc.enabled'                             = 'true'         -- 默认true，确保不被误关
);
```

**为什么 `min-snapshots-to-keep = 5` 而不是默认的 1**：
- 值为 1 意味着只保留最新快照，**无法回滚坏数据**
- 值为 5 提供了 5 次写入的回滚窗口
- 流式写入场景（Flink/SparkStreaming）建议设为 **50-100**

**社区教训**：
> Iceberg 社区多个 Issue 报告：`min-snapshots-to-keep=1` 时，如果 expire 和写入并发执行，可能导致读取器看到的 snapshot 被删除，查询报 `FileNotFoundException`。

### 2.3 元数据文件管理 — 防止元数据膨胀

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⭐ 元数据文件保留
  'write.metadata.previous-versions-max'           = '100',   -- 默认100，保持不变
  'write.metadata.delete-after-commit.enabled'     = 'false', -- 默认false，生产环境不要开！

  -- ⭐ Manifest 合并
  'commit.manifest-merge.enabled'                  = 'true',  -- 默认true，必须开启
  'commit.manifest.target-size-bytes'              = '8388608', -- 8MB，保持默认
  'commit.manifest.min-count-to-merge'             = '100'     -- 默认100，保持不变
);
```

**为什么 `delete-after-commit.enabled = false`**：
- 设为 true 会在每次 commit 后自动删除旧的 metadata.json
- 但如果此时有并发读取器正在引用旧 metadata，会导致读取失败
- **由 Amoro 统一管理过期**比自行删除更安全

### 2.4 写入格式与压缩

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⭐ 表格式版本
  'format-version'                      = '2',            -- V2 支持行级删除（MOR）

  -- ⭐ 文件格式与压缩
  'write.format.default'                = 'parquet',       -- Parquet 生态最成熟
  'write.parquet.compression-codec'     = 'zstd',          -- zstd 压缩比和速度最优
  'write.target-file-size-bytes'        = '134217728',     -- 128MB（与 Amoro target-size 对齐）
  'write.delete.target-file-size-bytes' = '67108864',      -- 64MB

  -- ⭐ 分布模式（防数据倾斜）
  'write.distribution-mode'             = 'hash',          -- hash 分布，写入均匀
  'write.delete.granularity'            = 'partition'       -- partition 粒度删除（默认，性能最好）
);
```

---

## 三、Amoro 表级配置 — Self-Optimizing 最稳妥方案

### 3.1 Self-Optimizing 核心配置

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⭐ 自优化开关
  'self-optimizing.enabled'                   = 'true',

  -- ⭐ 优化器组（按业务隔离资源）
  'self-optimizing.group'                     = 'default',

  -- ⭐ 资源配额（0.1 = 占优化器组 10% 资源）
  'self-optimizing.quota'                     = '0.1',

  -- ⭐ 目标文件大小（与 Iceberg write.target-file-size-bytes 对齐！）
  'self-optimizing.target-size'               = '134217728',  -- 128MB

  -- ⭐ 最大任务大小（单次 Rewrite 任务的最大输入）
  'self-optimizing.max-task-size-bytes'        = '134217728',  -- 128MB

  -- ⭐ 最大文件数（防止一次性 Rewrite 过多文件导致 OOM）
  'self-optimizing.max-file-count'             = '10000',

  -- ⭐ 碎片文件比率（文件 < target-size / fragment-ratio 视为碎片）
  'self-optimizing.fragment-ratio'             = '8',  -- < 16MB 的文件视为碎片

  -- ⭐ 最小目标大小比率（文件 > target-size * 0.75 不参与 Rewrite）
  'self-optimizing.min-target-size-ratio'      = '0.75',

  -- ⭐ 执行重试次数（Task 级重试）
  'self-optimizing.execute.num-retries'        = '5',

  -- ⭐ 最小计划间隔（防止频繁规划消耗 AMS 资源）
  'self-optimizing.min-plan-interval'          = '60000'  -- 1分钟
);
```

### 3.2 Minor Optimizing（小文件合并 — 最频繁的操作）

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- Minor 触发条件：碎片文件数 >= 12 或距上次 Minor >= 1小时
  'self-optimizing.minor.trigger.file-count'   = '12',       -- 默认12
  'self-optimizing.minor.trigger.interval'     = '3600000'   -- 1小时（默认）
);
```

**Minor 的作用**：合并 insert delta 文件（小文件），不重写 base 文件。安全性高，频繁执行无害。

### 3.3 Major Optimizing（去重合并）

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- Major 触发条件：重复数据占碎片大小的比率 >= 10%
  'self-optimizing.major.trigger.duplicate-ratio' = '0.1'  -- 默认 10%
);
```

**Major 的作用**：合并 base 文件中的重复数据（delete file 引用的数据），实质是 MOR → COW 转换。

### 3.4 Full Optimizing（全量重写 — 最危险的操作）

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⚠️ Full Optimizing：生产环境建议关闭自动触发！
  'self-optimizing.full.trigger.interval'        = '-1',    -- -1 表示不自动触发（默认）
  'self-optimizing.full.rewrite-all-files'       = 'true'   -- 若手动触发，重写所有文件
);
```

**为什么 Full Optimizing 要关闭自动触发**：
- Full 会重写所有数据文件，I/O 开销巨大
- 大表 Full Rewrite 可能耗时数小时，期间占用大量 Executor 资源
- 如果与正常写入并发，commit 冲突概率极高
- **建议**：在业务低峰期手动触发，或通过调度系统（Airflow/DolphinScheduler）定期执行

---

## 四、Amoro 维护操作配置 — 孤儿文件清理与快照过期

### 4.1 快照过期（由 Amoro 管控）

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⭐ 启用 Amoro 管理的快照过期
  'table-expire.enabled'               = 'true',         -- 默认true

  -- ⭐ 快照保留时长
  'snapshot.keep.duration'             = '10080min',      -- 7天（默认720min=12h，太短！）

  -- ⭐ 快照最小保留数
  'snapshot.keep.min-count'            = '5',             -- 默认1，生产必须 >= 5

  -- ⭐ Change 数据 TTL（Mixed-Iceberg 表的 Change 分支数据）
  'change.data.ttl.minutes'            = '10080'          -- 7天（默认7天）
);
```

**源码验证**（`TableProperties.java`）：
- `SNAPSHOT_KEEP_DURATION` 默认 `720min`（12 小时），**对于生产环境太短**
- `SNAPSHOT_MIN_COUNT` 默认 `1`，**极度危险**——一次坏提交就无法回滚

### 4.2 孤儿文件清理（最危险的操作——务必保守！）

```sql
ALTER TABLE catalog.db.your_table SET TBLPROPERTIES (
  -- ⚠️ 生产环境建议关闭 Amoro 自动孤儿清理！
  'clean-orphan-file.enabled'                      = 'false',  -- 默认false

  -- 如果确实要开启，必须设置足够长的保护期
  'clean-orphan-file.min-existing-time-minutes'    = '4320',   -- 3天 = 4320分钟（默认2880=2天）

  -- ⭐ 悬挂 delete 文件清理：可以安全开启
  'clean-dangling-delete-files.enabled'            = 'true'    -- 默认true
);
```

**为什么孤儿清理要格外保守**：
- 孤儿文件清理的逻辑是：扫描目录中所有文件，对比当前快照引用的文件，**删除不在引用中的文件**
- 如果此时有 Spark/Flink 作业正在写入但尚未 commit，这些**写了一半的文件会被当作孤儿删除**
- `min-existing-time-minutes = 4320`（3 天）提供了足够的保护窗口
- **更安全的做法**：关闭 Amoro 自动清理，改为手动/调度执行，且执行前确认无活跃写入

---

## 五、社区 Issue 踩坑与修复汇总

### 5.1 已知高危问题

| Issue | 问题 | 影响 | 修复/规避 |
|-------|------|------|----------|
| **AMORO-2250** | 禁用 self-optimizing 后表状态不更新为 idle | 表卡在 PENDING 状态 | 升级到 0.7.0+，已修复 |
| **AMORO-1924** | Major Optimizing 重复执行 | 资源浪费，可能与 Full 冲突 | 检查 duplicate-ratio 配置，升级到 0.7.0+ |
| **AMORO-2388** | 修改 self-optimizing.enabled 配置触发 NPE | AMS 崩溃 | 升级到 0.6.1+，已修复 |
| **Iceberg 并发 commit** | expire_snapshots 与写入并发导致 FileNotFoundException | 查询失败 | `min-snapshots-to-keep >= 5` |
| **Orphan cleanup 误删** | 孤儿清理删除了正在写入的文件 | **数据丢失** | `min-existing-time >= 3天`，或关闭自动清理 |

### 5.2 Manifest 合并导致 Planning 变慢

- **症状**：表运行一段时间后，查询规划时间从秒级增长到分钟级
- **根因**：Manifest 文件过多，每次 Planning 需要打开所有 Manifest
- **修复**：确保 `commit.manifest-merge.enabled = true`，定期执行 `rewrite_manifests`

---

## 六、维护操作执行手册

### 6.1 执行顺序铁律

```
① Expire Snapshots → ② Remove Orphan Files → ③ Rewrite Manifests/Data Files

⚠️ 顺序不可颠倒！
  - 先过期快照：解锁可删除的文件引用
  - 再清理孤儿：删除物理文件
  - 最后重写 manifest：优化元数据结构
```

### 6.2 推荐调度策略

| 操作 | 频率 | 执行窗口 | 注意事项 |
|------|------|---------|---------|
| Amoro Minor Optimizing | 自动（1 小时/12 文件触发） | 7×24 | 安全，可持续运行 |
| Amoro Major Optimizing | 自动（10% 重复触发） | 7×24 | 安全，资源占用中等 |
| Amoro 快照过期 | 自动（AMS 后台执行） | 7×24 | 确保 min-count >= 5 |
| **Amoro Full Optimizing** | **手动/调度** | **凌晨 2-6 点** | 大 I/O，避免与生产写入并发 |
| **孤儿文件清理** | **手动/调度，每周 1 次** | **周日凌晨** | 确保无活跃写入 |
| **Manifest 重写** | 每天 1 次 | 凌晨 | Amoro Minor 已包含，额外执行为保险 |

---

## 七、完整配置模板（可直接使用）

### 7.1 批处理表（每日写入 1-10 次）

```sql
ALTER TABLE catalog.db.batch_table SET TBLPROPERTIES (
  -- Iceberg 核心安全配置
  'format-version'                                 = '2',
  'write.format.default'                           = 'parquet',
  'write.parquet.compression-codec'                = 'zstd',
  'write.target-file-size-bytes'                   = '134217728',
  'commit.retry.num-retries'                       = '10',
  'commit.retry.total-timeout-ms'                  = '3600000',
  'commit.status-check.num-retries'                = '5',
  'commit.manifest-merge.enabled'                  = 'true',
  'history.expire.max-snapshot-age-ms'             = '604800000',
  'history.expire.min-snapshots-to-keep'           = '5',
  'write.metadata.delete-after-commit.enabled'     = 'false',
  'write.metadata.previous-versions-max'           = '100',

  -- Amoro Self-Optimizing
  'self-optimizing.enabled'                        = 'true',
  'self-optimizing.group'                          = 'default',
  'self-optimizing.quota'                          = '0.1',
  'self-optimizing.target-size'                    = '134217728',
  'self-optimizing.fragment-ratio'                 = '8',
  'self-optimizing.minor.trigger.file-count'       = '12',
  'self-optimizing.minor.trigger.interval'         = '3600000',
  'self-optimizing.major.trigger.duplicate-ratio'  = '0.1',
  'self-optimizing.full.trigger.interval'          = '-1',
  'self-optimizing.execute.num-retries'            = '5',

  -- Amoro 快照/孤儿管理
  'table-expire.enabled'                           = 'true',
  'snapshot.keep.duration'                         = '10080min',
  'snapshot.keep.min-count'                        = '5',
  'clean-orphan-file.enabled'                      = 'false',
  'clean-orphan-file.min-existing-time-minutes'    = '4320',
  'clean-dangling-delete-files.enabled'            = 'true'
);
```

### 7.2 流式表（Flink/SparkStreaming 持续写入）

```sql
ALTER TABLE catalog.db.streaming_table SET TBLPROPERTIES (
  -- Iceberg 核心安全配置
  'format-version'                                 = '2',
  'write.format.default'                           = 'parquet',
  'write.parquet.compression-codec'                = 'zstd',
  'write.target-file-size-bytes'                   = '134217728',
  'commit.retry.num-retries'                       = '20',           -- 流式写入并发高，加大重试
  'commit.retry.total-timeout-ms'                  = '7200000',      -- 2小时
  'commit.status-check.num-retries'                = '10',
  'commit.manifest-merge.enabled'                  = 'true',
  'commit.manifest.min-count-to-merge'             = '50',           -- 流式写入manifest多，降低合并阈值
  'history.expire.max-snapshot-age-ms'             = '259200000',    -- 3天（流式快照多，可以短一点）
  'history.expire.min-snapshots-to-keep'           = '100',          -- 流式表必须保留更多快照！
  'write.metadata.delete-after-commit.enabled'     = 'false',
  'write.metadata.previous-versions-max'           = '500',          -- 流式表metadata版本更多

  -- Amoro Self-Optimizing（流式表更激进）
  'self-optimizing.enabled'                        = 'true',
  'self-optimizing.group'                          = 'streaming',    -- 独立优化器组
  'self-optimizing.quota'                          = '0.3',          -- 更多配额
  'self-optimizing.target-size'                    = '134217728',
  'self-optimizing.fragment-ratio'                 = '8',
  'self-optimizing.minor.trigger.file-count'       = '6',            -- 更敏感地触发Minor
  'self-optimizing.minor.trigger.interval'         = '600000',       -- 10分钟
  'self-optimizing.major.trigger.duplicate-ratio'  = '0.05',         -- 5% 即触发Major
  'self-optimizing.full.trigger.interval'          = '-1',           -- 仍然关闭自动Full
  'self-optimizing.execute.num-retries'            = '10',

  -- Amoro 快照/孤儿管理
  'table-expire.enabled'                           = 'true',
  'snapshot.keep.duration'                         = '4320min',      -- 3天
  'snapshot.keep.min-count'                        = '100',
  'change.data.ttl.minutes'                        = '4320',         -- 3天
  'clean-orphan-file.enabled'                      = 'false',
  'clean-orphan-file.min-existing-time-minutes'    = '5760',         -- 4天
  'clean-dangling-delete-files.enabled'            = 'true'
);
```

---

## 八、数据安全红线总结

| 红线 | 说明 | 违反后果 |
|------|------|---------|
| `min-snapshots-to-keep >= 5` | 至少保留 5 个快照 | 违反：无法回滚坏数据 |
| `clean-orphan-file.enabled = false` | 关闭自动孤儿清理 | 违反：可能删除正在写入的文件 |
| `orphan min-existing-time >= 3天` | 孤儿文件至少存活 3 天 | 违反：写入中的文件被误删 |
| `write.metadata.delete-after-commit.enabled = false` | 不自动删除 metadata | 违反：并发读取器失败 |
| `self-optimizing.full.trigger.interval = -1` | 不自动触发 Full | 违反：大 I/O 冲击 + commit 冲突 |
| 维护顺序：Expire → Orphan → Rewrite | 严格顺序执行 | 违反：删除仍被引用的文件 |
| `commit.retry.num-retries >= 10` | 足够的 commit 重试 | 违反：并发冲突导致写入失败 |

---

> **Eric 的底线哲学**：配置 Iceberg + Amoro 就像管理核电站——安全冗余永远大于效率优化。宁可多保留几天快照多占点存储，也不能让任何清理操作有机会删除还在使用的数据。
