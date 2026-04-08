# Hive 性能调优 Checklist

---

## P0 — 必须

- [ ] `hive.execution.engine` = tez（不用 mr）
- [ ] `hive.vectorized.execution.enabled` = true（向量化）
- [ ] `hive.cbo.enable` = true + 定期 `ANALYZE TABLE`
- [ ] `hive.auto.convert.join` = true（自动 MapJoin）
- [ ] 表用 ORC/Parquet 列存（不用 TextFile）
- [ ] 分区列出现在 WHERE 条件中

## P1 — 强烈建议

- [ ] `hive.exec.parallel` = true（并行 Stage）
- [ ] `hive.optimize.skewjoin` = true（倾斜处理）
- [ ] `hive.tez.container.size` 适配节点（4096-8192）
- [ ] 小文件合并：`hive.merge.mapfiles` / `hive.merge.mapredfiles` = true
- [ ] `hive.auto.convert.join.noconditionaltask.size` 调大到 200MB
- [ ] ACID 表开启 Compaction

## P2 — 进阶

- [ ] SMB Join 配置（大表 Join 大表）
- [ ] `hive.exec.reducers.bytes.per.reducer` 调小（增加 Reducer 数）
- [ ] HMS 底层 DB 加索引优化慢查询
- [ ] HS2 并发连接池调优

---

*Hive Expert | 2026-04-08*
