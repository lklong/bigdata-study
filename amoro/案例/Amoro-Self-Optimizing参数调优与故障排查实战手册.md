# Amoro Self-Optimizing 参数调优与故障排查实战手册

> Eric | 2026-04-27

---

## 一、Self-Optimizing 核心参数速查

### 1.1 优化触发参数

| 参数 | 含义 | 默认值 | 建议值 |
|------|------|--------|--------|
| `self-optimizing.enabled` | 启用自动优化 | `true` | `true` |
| `self-optimizing.group` | Optimizer 组 | `default` | 按业务分组 |
| `self-optimizing.quota` | CPU 配额 (0-1) | `0.1` | 流表 0.2-0.5，批表 0.01-0.05 |
| `self-optimizing.target-size` | 目标文件大小 | `128MB` | `128MB` |
| `self-optimizing.max-file-count` | 单次最大文件数 | `10000` | 按集群规模 |
| `self-optimizing.min-plan-interval` | 最小计划间隔(ms) | `60000` | 流表 30000，批表 300000 |
| `self-optimizing.minor.trigger.file-count` | Minor 触发文件数 | `12` | 流表 6-12，批表 24-48 |
| `self-optimizing.major.trigger.file-count` | Major 触发文件数 | `100` | 50-200 |
| `self-optimizing.minor.trigger.interval` | Minor 触发间隔 | `3600000`(1h) | 流表 1800000 |

### 1.2 维护参数

| 参数 | 含义 | 默认值 | 建议值 |
|------|------|--------|--------|
| `snapshot.retain-num` | 保留快照数 | `10` | 5-20 |
| `snapshot.retain-time` | 保留快照时间 | `7d` | 3d-14d |
| `clean-orphan-files.enabled` | 清理孤立文件 | `true` | `true` |
| `clean-orphan-files.delay` | 清理延迟(ms) | `259200000`(3d) | 3d |
| `data-expire.enabled` | 数据过期 | `false` | 按需 |
| `data-expire.field` | 过期字段 | — | 分区字段 |
| `data-expire.retention-time` | 保留时长 | — | `90d`/`180d` |
| `tag.auto-create.enabled` | 自动创建 Tag | `false` | 按需 |

---

## 二、调优场景与配方

### 2.1 场景 A：高频 Streaming 写入（每分钟 batch）

```sql
ALTER TABLE t SET TBLPROPERTIES (
    'self-optimizing.enabled' = 'true',
    'self-optimizing.quota' = '0.3',              -- 高配额
    'self-optimizing.minor.trigger.file-count' = '6', -- 低阈值快速合并
    'self-optimizing.min-plan-interval' = '30000', -- 30秒间隔
    'write.target-file-size-bytes' = '134217728'   -- 128MB
);
```

### 2.2 场景 B：每小时 Batch 写入

```sql
ALTER TABLE t SET TBLPROPERTIES (
    'self-optimizing.enabled' = 'true',
    'self-optimizing.quota' = '0.05',
    'self-optimizing.minor.trigger.file-count' = '24',
    'self-optimizing.min-plan-interval' = '300000'  -- 5分钟
);
```

### 2.3 场景 C：频繁 Upsert（MoR / Mixed-Iceberg）

```sql
ALTER TABLE t SET TBLPROPERTIES (
    'self-optimizing.enabled' = 'true',
    'self-optimizing.quota' = '0.5',              -- 高配额
    'self-optimizing.major.trigger.file-count' = '50', -- 低阈值
    'self-optimizing.minor.trigger.file-count' = '6'
);
```

### 2.4 场景 D：冷数据表（很少写入）

```sql
ALTER TABLE t SET TBLPROPERTIES (
    'self-optimizing.enabled' = 'true',
    'self-optimizing.quota' = '0.01',
    'self-optimizing.min-plan-interval' = '600000', -- 10分钟
    'data-expire.enabled' = 'true',
    'data-expire.field' = 'dt',
    'data-expire.retention-time' = '90d'
);
```

---

## 三、故障排查决策树

### 3.1 Self-Optimizing 不工作

```
表长时间处于 PENDING / IDLE 且小文件堆积？
│
├── 1. 检查 self-optimizing.enabled
│      SELECT properties FROM t → self-optimizing.enabled = true ?
│      ├── false → ALTER TABLE t SET TBLPROPERTIES ('self-optimizing.enabled'='true')
│      └── true → 下一步
│
├── 2. 检查 Optimizer 进程
│      AMS Dashboard → Optimizers
│      ├── 无 Optimizer → 部署: bin/optimizer.sh start --group default
│      └── 有 Optimizer → 下一步
│
├── 3. 检查 Group 匹配
│      表的 self-optimizing.group = ?
│      Optimizer 注册的 group = ?
│      ├── 不匹配 → 修改表的 group 或部署对应 group 的 Optimizer
│      └── 匹配 → 下一步
│
├── 4. 检查配额
│      AMS Dashboard → Tables → 表详情 → Optimizing Tab
│      quotaOccupy > 1.0 ?
│      ├── > 1.0 → 配额耗尽，提高 quota 或增加 Optimizer
│      └── < 1.0 → 下一步
│
├── 5. 检查 Blocker
│      AMS Dashboard → Tables → 表详情 → Blockers
│      有活跃 Blocker ?
│      ├── 有 → 等待 Blocker 释放或手动清理
│      └── 无 → 下一步
│
├── 6. 检查 min-plan-interval
│      self-optimizing.min-plan-interval 是否过大？
│      ├── 过大 → 缩短间隔
│      └── 正常 → 下一步
│
└── 7. 检查 AMS 日志
       grep "TableExplorer error" ams.log
       grep "plan failed" ams.log
       → 可能是元数据读取超时、权限问题等
```

### 3.2 优化任务频繁失败

```
任务状态反复 FAILED ?
│
├── 1. 查看失败原因
│      AMS Dashboard → Tables → Optimizing → History → 失败任务 → 详情
│      常见原因:
│
├── 2. OOM (Out of Memory)
│      Optimizer 内存不足
│      ├── 增加 Optimizer JVM 内存: -Xmx4g → -Xmx8g
│      ├── 减小 self-optimizing.target-size
│      └── 减小 self-optimizing.max-file-count
│
├── 3. 文件不存在 (FileNotFoundException)
│      数据文件被外部操作删除
│      ├── 检查是否有并发的 expire_snapshots 操作
│      ├── 检查是否有外部工具直接删除了 HDFS 文件
│      └── 解决: 等待下次 refresh → 重新规划
│
├── 4. 权限问题 (AccessDeniedException)
│      Optimizer 进程权限不足
│      ├── 检查 Optimizer 运行用户
│      ├── 检查 HDFS/S3 权限
│      └── Kerberos 环境: 检查 keytab 是否过期
│
├── 5. 网络超时
│      Optimizer 与 AMS 通信超时
│      ├── 检查网络连通性
│      ├── 检查 AMS 负载（CPU/内存/连接数）
│      └── 增加超时配置
│
└── 6. 并发冲突 (CommitFailedException)
       其他写入操作与优化冲突
       ├── 正常情况: 自动重试
       └── 频繁冲突: 增加 min-plan-interval
```

### 3.3 优化后查询仍然慢

```
优化执行了但查询没改善？
│
├── 1. 确认优化真正执行了
│      AMS Dashboard → Tables → Optimizing → History
│      最近的优化是否 SUCCESS?
│
├── 2. 检查是否只做了 Minor
│      Minor 只合并小文件，不处理 Delete File
│      ├── 如果 Delete File 很多 → 需要 Major Optimize
│      └── 降低 major.trigger.file-count 触发 Major
│
├── 3. 检查 Snapshot 数量
│      SELECT count(*) FROM t.snapshots
│      ├── > 1000 → 快照过多导致 Planning 慢
│      └── 减小 snapshot.retain-num
│
├── 4. 检查 Manifest 数量
│      SELECT count(*) FROM t.manifests
│      ├── > 1000 → Manifest 过多
│      └── CALL system.rewrite_manifests(table=>'t')
│
└── 5. 检查查询侧
       开启 vectorized read？
       谓词下推是否生效？
       是否使用了正确的分区字段？
```

---

## 四、监控告警模板

### 4.1 Prometheus 告警规则

```yaml
groups:
- name: amoro_table_alerts
  rules:
  # 表长时间 PENDING
  - alert: TablePendingTooLong
    expr: amoro_table_optimizing_status_duration_ms{status="pending"} > 3600000
    labels:
      severity: warning
    annotations:
      summary: "表 {{ $labels.table }} PENDING 超过 1 小时"

  # 数据文件过多
  - alert: TooManyDataFiles
    expr: amoro_table_data_files_count > 10000
    labels:
      severity: critical
    annotations:
      summary: "表 {{ $labels.table }} 数据文件 {{ $value }} 超过 10000"

  # Delete 文件堆积
  - alert: DeleteFileAccumulation
    expr: amoro_table_pos_delete_files_count + amoro_table_eq_delete_files_count > 100
    labels:
      severity: warning
    annotations:
      summary: "表 {{ $labels.table }} Delete 文件堆积 {{ $value }}"

  # Optimizer 全部离线
  - alert: NoActiveOptimizer
    expr: amoro_optimizer_threads_active == 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Optimizer 组 {{ $labels.group }} 无活跃线程"
```

### 4.2 巡检 SQL

```sql
-- 每日巡检查询
-- 1. 所有表的文件状况
SELECT
    t.table_name,
    t.file_count,
    t.avg_file_size_mb,
    t.delete_file_count,
    t.snapshot_count
FROM (
    SELECT
        table_name,
        (SELECT count(*) FROM {table}.files WHERE content=0) as file_count,
        (SELECT avg(file_size_in_bytes)/1024/1024 FROM {table}.files WHERE content=0) as avg_file_size_mb,
        (SELECT count(*) FROM {table}.files WHERE content>0) as delete_file_count,
        (SELECT count(*) FROM {table}.snapshots) as snapshot_count
    FROM information_schema.tables
) t
WHERE t.file_count > 1000 OR t.avg_file_size_mb < 32 OR t.delete_file_count > 50;
```

---

## 五、应急操作手册

### 5.1 紧急手动合并

```sql
-- 指定分区紧急合并
CALL catalog.system.rewrite_data_files(
    table => 'db.orders',
    where => 'dt = "2026-04-27"',
    options => map(
        'target-file-size-bytes', '134217728',
        'max-concurrent-file-group-rewrites', '10',
        'partial-progress.enabled', 'true'
    )
);
```

### 5.2 紧急清理快照

```sql
CALL catalog.system.expire_snapshots(
    table => 'db.orders',
    retain_last => 3
);
```

### 5.3 重启 Optimizer

```bash
# 停止
bin/optimizer.sh stop --group default

# 增加内存后启动
export OPTIMIZER_HEAP_SIZE=8192
bin/optimizer.sh start --group default --parallelism 8
```

### 5.4 重置卡住的表状态

```
如果表状态卡在 COMMITTING 或 *_OPTIMIZING:
  AMS Dashboard → Tables → 表详情 → Optimizing → Cancel Process
  或等待 AMS 自动超时回收（默认 30 分钟）
```
