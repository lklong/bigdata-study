# Kyuubi 故障排查决策树

---

连接失败
├── "Connection refused"
│   ├── Kyuubi Server 没启动 → 检查进程
│   ├── ZK 服务发现失败 → 检查 ZK
│   └── 端口不对 → 默认 10009
├── Engine 启动失败
│   ├── Spark Engine 超时 → spark-submit 参数有问题 → 检查 Engine 日志
│   ├── YARN 队列没资源 → 切队列
│   └── Kerberos 认证失败 → 检查 keytab
├── 查询慢
│   ├── Engine 冷启动 → 用 Engine Pool 预热
│   └── SQL 执行慢 → 转到 Spark 决策树
└── Engine 频繁挂
    ├── OOM → 调大 Engine 内存
    └── 空闲超时被杀 → 调大 engine.idle.timeout
```

---

---

*Kyuubi Expert | 2026-04-08*
