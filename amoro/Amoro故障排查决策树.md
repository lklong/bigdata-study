# Amoro 故障排查决策树

> Eric | 2026-04-25

---

## 小文件持续堆积（Self-Optimizing 不工作）

```
小文件堆积？
├── 检查 Self-Optimizing 是否启用
│   AMS Dashboard → Table → Properties
│   self-optimizing.enabled = true ?
│   ├── false → 启用：ALTER TABLE SET TBLPROPERTIES ('self-optimizing.enabled'='true')
│   └── true → 下一步
│
├── 检查 Optimizer 是否存活
│   AMS Dashboard → Optimizers
│   ├── 没有 Optimizer → 部署 Optimizer
│   │   └── bin/optimizer.sh start --group default
│   └── 有 Optimizer → 下一步
│
├── 检查 Optimizer Group 是否匹配
│   表的 self-optimizing.group = ?
│   Optimizer 注册的 group = ?
│   ├── 不匹配 → 修改表的 group 或部署对应 group 的 Optimizer
│   └── 匹配 → 下一步
│
├── 检查优化任务状态
│   AMS Dashboard → Table → Optimizing Tab
│   ├── 有 PLANNED 任务但没 SCHEDULED → Optimizer 线程不足/繁忙
│   │   └── 扩容 Optimizer 线程数
│   ├── ACKED 但长时间不完成 → 任务卡住
│   │   └── 检查 Optimizer 日志
│   ├── FAILED → 查看 failReason
│   │   └── OOM → 增大 Optimizer 内存
│   │   └── IOException → 检查存储访问
│   └── 没有任何任务 → 下一步
│
└── 检查评估阈值
    minor.trigger.file-count 是否设太高？
    └── 降低阈值或手动触发
```

## 优化任务卡住/失败

```
任务卡住？
├── 检查 Optimizer 进程是否存活
│   ps aux | grep Optimizer
│   ├── 已死 → 重启 Optimizer
│   └── 存活 → 下一步
│
├── 检查 Optimizer 日志
│   logs/optimizer-*.log
│   ├── OOM / GC overhead → 增大 -Xmx
│   ├── IOException → 存储访问问题
│   ├── TException → AMS 连接断开
│   │   └── 检查 AMS 是否正常
│   └── OptimizingClosedException → 表被删除或优化被取消
│
├── 检查 AMS 日志
│   logs/ams-*.log
│   ├── Task timeout → 任务超时被 AMS 回收
│   │   └── 增大超时时间或优化任务粒度
│   └── Commit failed → 提交冲突
│       └── 检查是否有其他写入并发
│
└── 检查任务状态
    AMS Dashboard → Table → Tasks
    └── 多次 FAILED → 达到重试上限 → 手动重置
```

## AMS 启动失败

```
AMS 启动失败？
├── 检查端口占用
│   netstat -tlnp | grep 1630
│   netstat -tlnp | grep 1260
│   └── 端口占用 → kill 旧进程
│
├── 检查数据库连接
│   config.yaml → database 配置
│   ├── MySQL 连接失败 → 检查 MySQL 服务
│   └── Derby（嵌入式）→ 检查 derby.log
│
├── 检查 HA 配置（如启用了 ZK HA）
│   ├── ZK 不可达 → 检查 ZK 集群
│   └── HA 节点冲突 → 清理 ZK 上的 AMS 锁节点
│
└── 检查日志
    logs/ams-*.log
    └── 具体异常栈 → 对症处理
```

## 表在 AMS Dashboard 不显示

```
表不显示？
├── 检查 Catalog 是否注册
│   AMS Dashboard → Catalogs
│   ├── 没有 → 注册 Catalog
│   └── 有 → 下一步
│
├── 检查 Catalog 类型
│   ├── Internal Catalog → 表必须通过 AMS API 创建
│   └── External Catalog → 等待 AMS 定期同步
│       └── 同步间隔：检查 TableRuntimeRefreshExecutor 配置
│
└── 检查表格式
    AMS 只管理注册的格式（Iceberg/Hive/Paimon/Hudi）
    └── 非支持格式 → 不会显示
```

---

*Amoro 排障决策树 v1.0 | Eric | 2026-04-25*
