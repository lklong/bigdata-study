# HDFS 故障排查决策树

---

## 1. 文件读写失败

```
读写失败
├── "No such file or directory"
│   └── 文件确实不存在 → hdfs dfs -ls 确认 / 检查回收站
├── "Permission denied"
│   ├── POSIX 权限 → hdfs dfs -chmod
│   ├── ACL → hdfs dfs -getfacl
│   └── Ranger 策略拒绝 → 检查 Ranger 审计日志
├── "Could not obtain block"
│   ├── Block 所有副本都不可用 → hdfs fsck /path -files -blocks
│   ├── DataNode 掉线 → 检查 DN 状态
│   └── 网络不通 → Client 到 DN 的连接
├── "Lease mismatch" / "AlreadyBeingCreatedException"
│   └── 上一个 Writer 没正常关闭 → 等 lease 过期 / hdfs debug recoverLease
└── "Standby NameNode"
    └── Client 连了 Standby NN → 检查 HA 配置 / failover 状态
```

## 2. NameNode 问题

```
NameNode 问题
├── NN 启动慢
│   ├── fsimage 太大 → 减少文件数 / Federation
│   ├── Block 报告处理慢 → DN 太多需要等待
│   └── 安全模式不退出 → 检查 Block 丢失率
├── NN RPC 慢
│   ├── CallQueueLength 高 → 开启 FairCallQueue
│   ├── FSNamesystemLock 等待长 → 大目录 listStatus / 多写入竞争
│   ├── GC 暂停 → NN JVM 调优
│   └── Audit Log 写入慢 → 日志异步化
├── NN OOM
│   ├── 文件数太多 → Federation / 清理文件
│   └── Block 数太多 → 合并小文件 / 增大 blocksize
└── NN HA failover 失败
    ├── ZK 不可用 → 检查 ZK 集群
    ├── Fencing 失败 → 检查 fencing 方法 (sshfence / shellfence)
    └── JournalNode 不可用 → JN 多数必须存活
```

## 3. DataNode 问题

```
DataNode 问题
├── DN 掉线 / Dead
│   ├── 进程挂了 → 检查 DN 日志 → 重启
│   ├── 心跳超时 → 网络问题 / DN GC 暂停
│   └── 被管理员退役 → 检查 dfs.hosts.exclude
├── DN 磁盘满
│   ├── 数据增长 → 扩容 / 清理
│   ├── Shuffle 临时文件 → 清理 spark.local.dir
│   └── DN 日志膨胀 → logrotate
├── DN 写入慢
│   ├── 磁盘 I/O 瓶颈 → iostat 检查 → 换 SSD
│   ├── Pipeline 写入某个 DN 慢 → 检查该 DN 负载
│   └── 网络带宽满 → iftop / nload 检查
└── Block 副本不足
    ├── Under-replicated → hdfs dfsadmin -report
    └── 触发副本修复 → NN 自动调度 / 手动 hdfs balancer
```

---

*HDFS Expert | 故障排查决策树 v1.0 | 2026-04-08*
