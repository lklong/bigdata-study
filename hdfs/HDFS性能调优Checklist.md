# HDFS 性能调优 Checklist

---

## P0 — 必须

- [ ] `dfs.namenode.handler.count` ≥ 100（默认 10 太小）
- [ ] `dfs.blocksize` = 128MB 或 256MB
- [ ] NameNode 堆内存 ≥ 文件数 × 300B × 2
- [ ] `dfs.datanode.max.transfer.threads` = 4096+
- [ ] DataNode 多盘配置（不要单盘）
- [ ] 定期 `hdfs fsck /` 检查集群健康

## P1 — 强烈建议

- [ ] 开启 FairCallQueue（`ipc.scheduler.impl=DecayRpcScheduler`）
- [ ] `dfs.namenode.fs-limits.max-directory-items` 合理设置
- [ ] 冷数据用 EC 纠删码（节省 50% 存储）
- [ ] 开启快照保护关键目录
- [ ] Balancer 定期执行（低峰期）
- [ ] DataNode 磁盘用 xfs + noatime

## P2 — 进阶

- [ ] Observer NameNode 分流读请求
- [ ] Short-Circuit Local Read 开启（`dfs.client.read.shortcircuit=true`）
- [ ] 小文件治理（HAR / 合并 / 清理）

---

*HDFS Expert | 2026-04-08*

---

# YARN 性能调优 Checklist

## P0 — 必须

- [ ] `yarn.nodemanager.resource.memory-mb` = 物理内存 × 0.8
- [ ] `yarn.nodemanager.resource.cpu-vcores` = 物理核数 × 0.8
- [ ] `yarn.nodemanager.vmem-check-enabled` = **false**（关闭虚拟内存检查）
- [ ] `yarn.log-aggregation-enable` = true
- [ ] RM HA 已开启
- [ ] Work-Preserving RM Recovery 已开启

## P1 — 强烈建议

- [ ] CPU CGroups 隔离已开启（多租户）
- [ ] 队列 capacity + max-capacity 合理规划
- [ ] Preemption 已配置（高优队列可抢占）
- [ ] `yarn.scheduler.minimum-allocation-mb` = 1024
- [ ] 节点标签分组（GPU/SSD 专用）

---

*YARN Expert | 2026-04-08*
