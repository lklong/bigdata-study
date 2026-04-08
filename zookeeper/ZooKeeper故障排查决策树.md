# ZooKeeper 故障排查决策树

---

```
ZK 集群问题
├── ZK 不可用
│   ├── Leader 挂了 → 检查选举 → 3 节点需 2 个存活
│   ├── 全部 LOOKING 状态 → 脑裂 → 检查网络分区
│   └── 端口被占 → netstat -tlnp | grep 2181
├── 延迟高
│   ├── GC 暂停 → 检查 ZK 的 GC 日志
│   ├── fsync 慢 → 事务日志放 SSD
│   ├── 大量 Watcher 同时触发 → 减少 Watcher 数 / 用持久化 Watcher
│   └── 连接数太多 → maxClientCnxns 调大 / 客户端连接池
├── Session 频繁过期
│   ├── Client 端 GC → 调优 Client JVM
│   ├── 网络抖动 → 调大 sessionTimeout
│   └── ZK Server 负载高 → 扩容 / 独立部署
└── 磁盘满
    ├── 快照累积 → autopurge 配置
    └── 事务日志累积 → autopurge + logrotate
```

---

---

*ZooKeeper Expert | 2026-04-08*
