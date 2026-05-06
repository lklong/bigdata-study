# Iceberg 故障排查决策树

> Eric | 2026-04-25

---

## 查询慢

```
查询慢？
├── 检查小文件数量
│   SELECT count(*), avg(file_size_in_bytes) FROM db.t.files
│   ├── avg < 32MB → 小文件堆积
│   │   └── CALL system.rewrite_data_files(table=>'db.t')
│   └── 正常 → 下一步
│
├── 检查 Snapshot 数量
│   SELECT count(*) FROM db.t.snapshots
│   ├── > 1000 → Snapshot 膨胀导致元数据臃肿
│   │   └── CALL system.expire_snapshots(table=>'db.t', retain_last=>5)
│   └── < 100 → 下一步
│
├── 检查 Delete File 数量
│   SELECT count(*) FROM db.t.files WHERE content = 1 OR content = 2
│   ├── 大量 equality delete → 查询需要 merge 读，很慢
│   │   └── CALL system.rewrite_data_files(table=>'db.t') 合并 delete
│   └── 少量 → 下一步
│
├── 检查 Manifest 数量
│   SELECT count(*) FROM db.t.manifests
│   ├── > 10000 → Manifest 碎片化
│   │   └── CALL system.rewrite_manifests(table=>'db.t')
│   └── 正常 → 下一步
│
├── 检查分区/排序
│   DESCRIBE EXTENDED db.t
│   ├── 未分区 + 大表 → 全表扫描
│   │   └── 添加合理分区：ALTER TABLE SET PARTITION SPEC
│   └── 有分区但查询未命中 → 检查查询条件是否包含分区列
│
└── 检查数据倾斜
    SELECT partition, count(*), sum(file_size_in_bytes)
    FROM db.t.files GROUP BY partition ORDER BY 3 DESC
    └── 某分区数据量异常大 → 考虑 bucket/zorder 优化
```

## 存储空间持续增长

```
存储空间持续增长？
├── 孤立文件（orphan files）
│   任务失败留下的残留文件
│   └── CALL system.remove_orphan_files(table=>'db.t', older_than=>TIMESTAMP'...')
│       ⚠️ older_than 至少 3 天前，太短会删正在写的文件
│
├── 过期 Snapshot 未清理
│   旧 Snapshot 引用的数据文件无法被删除
│   └── CALL system.expire_snapshots(table=>'db.t', older_than=>TIMESTAMP'...')
│
└── metadata.json 文件过多
    └── ALTER TABLE SET TBLPROPERTIES (
          'write.metadata.delete-after-commit.enabled'='true',
          'write.metadata.previous-versions-max'='10')
```

## 写入失败

```
写入失败？
├── CommitFailedException: Requirement failed
│   ├── 并发写冲突（乐观锁）
│   │   └── 自动重试 / 减少并发写同分区
│   └── Metadata location changed
│       └── 检查是否有其他 Compaction/Expire 任务同时运行
│
├── ValidationException: Found conflicting files
│   ├── OverwriteFiles 冲突
│   │   └── 两个任务覆盖同一分区 → 串行化 / 用 RowDelta
│   └── 正常 → 重试
│
├── FileNotFoundException
│   ├── 数据文件被误删（expire_snapshots 太激进）
│   │   └── 检查 expire 配置：retain_last >= 3
│   └── orphan_files 清理误删
│       └── older_than 调大到 7 天
│
└── IOException: Unable to write / 磁盘满
    └── 检查存储空间 / HDFS quota
```

## 元数据损坏

```
元数据损坏？
├── metadata.json 丢失/损坏
│   └── 从 metadata-log 恢复：
│       ls <table-location>/metadata/v*.metadata.json
│       选最新的可用版本
│       → HadoopTableOperations 手动指向
│
├── Manifest 文件损坏
│   └── 从上一个 Snapshot 恢复：
│       SELECT * FROM db.t.snapshots ORDER BY committed_at DESC
│       → CALL system.rollback_to_snapshot(table=>'db.t', snapshot_id=>XXX)
│
└── 表无法打开 / NullPointerException
    └── 检查 Catalog 中 metadata_location 是否指向有效文件
```

---

*Iceberg 排障决策树 v1.0 | Eric | 2026-04-25*
