# Flink 故障排查决策树

---

## 1. 作业启动失败

```
启动失败
├── "Could not find a suitable slot"
│   ├── TaskManager 没启动 → 检查 TM 日志
│   ├── slot 数不够 → 调大 numberOfTaskSlots / 加 TM
│   └── 资源不够 → 调大 YARN/K8s 资源
├── "ClassNotFoundException"
│   └── Jar 依赖缺失 → 检查 lib 目录 / --classpath
├── "NoResourceAvailableException"
│   └── YARN 队列没资源 → 切队列 / 等待
└── "ConfigurationException"
    └── 配置参数错误 → 检查 flink-conf.yaml
```

## 2. 背压

```
背压
├── 查 Web UI → BackPressure 面板
│   ├── 只有个别 subtask 背压 → 数据倾斜
│   │   └── 打散 key / 两阶段聚合
│   ├── 所有 subtask 都背压
│   │   ├── 从 Sink 开始排查（Sink 写入慢？）
│   │   │   ├── HBase/ES/JDBC 写入慢 → 批量写 / 加连接池
│   │   │   └── Kafka 写入慢 → 检查 Kafka 集群
│   │   ├── 中间算子慢 → 检查 UDF 性能
│   │   └── GC 导致暂停 → 检查 GC 日志
│   └── 源头就背压 → Source 吞吐跟不上
│       └── Kafka Source: 增加并行度 = partition 数
└── Checkpoint 受背压影响
    └── Barrier 传播被阻塞 → 开启 Unaligned Checkpoint
```

## 3. Checkpoint 失败

```
Checkpoint 失败
├── "Checkpoint expired before completing"
│   ├── 背压导致 Barrier 传播慢 → 见背压决策树
│   ├── 状态太大 → 开启增量 CP + RocksDB
│   └── HDFS 写入慢 → 检查 HDFS 集群
├── "IOException during snapshot"
│   ├── HDFS 不可用 → 检查 HDFS
│   └── 磁盘满 → 清理 RocksDB 本地目录
├── "CheckpointCoordinator: Decline"
│   └── TM 拒绝 CP → 检查 TM 日志具体原因
└── CP 越来越慢
    ├── 状态持续增长 → 检查 State TTL 是否配置
    └── 增量 CP 链太长 → 做一次 Savepoint 截断
```

## 4. 数据不一致

```
数据不一致
├── 下游有重复数据
│   ├── At-Least-Once 模式 → 改为 Exactly-Once
│   ├── Sink 不支持事务 → 实现幂等写入
│   └── 从 Checkpoint 恢复后重放 → 正常行为，下游需幂等
├── 下游丢数据
│   ├── Watermark 设太小 → 调大允许延迟
│   ├── 侧输出没处理 → 检查 late data 是否被丢弃
│   └── Source 数据过期（Kafka retention） → 调大 Kafka retention
└── 结果不对
    ├── 窗口边界问题 → 检查窗口定义和时间语义
    └── State 恢复后数据不对 → 检查算子 UID 是否匹配
```

---

*Flink Expert | 故障排查决策树 v1.0 | 2026-04-08*
