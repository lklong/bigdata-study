# Flink 性能调优 Checklist

---

## P0 — 必须

- [ ] `state.backend` = rocksdb + `state.backend.incremental` = true
- [ ] Checkpoint 间隔 ≥ 30s（太频繁影响性能）
- [ ] Checkpoint 存储路径配到 HDFS（不用本地）
- [ ] 并行度 = Kafka partition 数（Source 不浪费 slot）
- [ ] 所有算子设 `.uid("xxx")`（Savepoint 恢复必需）
- [ ] State TTL 已配置（防止状态无限膨胀）

## P1 — 强烈建议

- [ ] Watermark 延迟合理（不太大不太小）
- [ ] Sink 批量写入（不要逐条）
- [ ] RocksDB memory managed = true
- [ ] `execution.checkpointing.tolerable-failed-checkpoints` ≥ 3
- [ ] 重启策略 `restart-strategy` = fixed-delay
- [ ] 背压严重时开启 Unaligned Checkpoint

## P2 — 进阶

- [ ] Async I/O 做维表 Lookup
- [ ] RocksDB compaction 线程数 ≥ 2
- [ ] 网络 buffer `taskmanager.memory.network.fraction` 调大（shuffle 密集型）
- [ ] Application Mode 部署（减少 Client 端开销）

---

*Flink Expert | 2026-04-08*
