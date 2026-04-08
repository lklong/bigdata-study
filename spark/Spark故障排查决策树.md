# Spark 故障排查决策树

> 遇到问题 → 按树走 → 定位根因 → 修复

---

## 1. 任务提交失败

```
任务提交失败
├── "Connection refused" / "Cannot connect to RM"
│   ├── YARN RM 挂了 → 检查 RM 状态: yarn rmadmin -getServiceState rm1
│   └── 网络不通 → telnet rm-host 8032
├── "Queue is not accessible"
│   └── 队列权限 → 检查 capacity-scheduler.xml 的 ACL
├── "Application is killed / rejected"
│   ├── 队列资源不够 → yarn application -status appId 看 diagnostics
│   └── AM 资源申请超限 → 调大 yarn.scheduler.maximum-allocation-mb
└── "ClassNotFoundException"
    ├── Jar 没上传 → --jars / --packages
    └── 依赖冲突 → spark.driver.userClassPathFirst=true
```

## 2. 任务运行慢

```
任务运行慢
├── 查 Spark UI → Stages Tab
│   ├── 某个 Stage 特别慢
│   │   ├── Task Duration 分布不均 → 数据倾斜
│   │   │   ├── 看 Summary Metrics: P50 vs Max 差 10 倍以上 → 确认倾斜
│   │   │   ├── 解决: AQE skewJoin / salting / 两阶段聚合
│   │   │   └── 查具体哪个 key 倾斜: 加 count group by key
│   │   ├── 所有 Task 都慢（均匀慢）
│   │   │   ├── GC Time 占比 > 10% → 内存不够 / GC 参数差
│   │   │   ├── Shuffle Read Blocked Time 高 → Shuffle 服务慢
│   │   │   ├── Input Size 很大但 Task 数少 → 增加分区数
│   │   │   └── Executor CPU 利用率低 → I/O bound，查存储性能
│   │   └── Task 数太多（几十万） → 合并小分区 coalesce
│   └── Stage 间等待时间长
│       ├── 上游 Stage 还没完 → 正常等待
│       └── Executor 启动慢 → dynamicAllocation 扩容延迟
├── 查 Executors Tab
│   ├── Executor 数不够 → 调大 maxExecutors / initialExecutors
│   ├── 个别 Executor 特别慢 → 检查对应节点（磁盘/网络/CPU）
│   └── Executor 频繁被杀/重启 → 内存不够 OOM
└── 查 SQL Tab
    ├── 执行计划有 BroadcastNestedLoopJoin → 改写 SQL 避免笛卡尔积
    ├── 没有 partition pruning → WHERE 条件没用到分区列
    └── Exchange 太多 → 减少不必要的 Shuffle
```

## 3. OOM (OutOfMemoryError)

```
OOM
├── Driver OOM
│   ├── "Java heap space"
│   │   ├── collect() 拉回太多数据 → 用 take(N) / limit
│   │   ├── broadcast 太大 → 调大 spark.driver.memory 或不广播
│   │   └── 调大 spark.driver.memory
│   └── "GC overhead limit exceeded"
│       └── 同上 + 检查是否有内存泄漏
├── Executor OOM
│   ├── "Java heap space"
│   │   ├── 单 Task 处理数据太大 → 增加分区数
│   │   ├── 缓存太多 → unpersist 不用的 RDD/DataFrame
│   │   └── 调大 spark.executor.memory
│   ├── "Direct buffer memory"
│   │   └── Netty 堆外内存不够 → 调大 spark.executor.memoryOverhead
│   └── "Container killed by YARN for exceeding memory limits"
│       ├── 物理内存超限 → 调大 spark.executor.memoryOverhead
│       └── 堆外内存泄漏 → 检查 UDF / Native 库
└── K8s OOMKilled
    └── Pod memory limit 太小 → 调大 spark.kubernetes.executor.limit.memory
```

## 4. 任务失败

```
任务失败
├── "Task failed N times"
│   ├── NullPointerException → 数据质量问题，加空值处理
│   ├── FileNotFoundException → 数据文件被删/移动
│   ├── IOException → 存储/网络问题
│   └── 自定义 UDF 异常 → 修复 UDF 逻辑
├── "Executor lost" / "ExecutorLostFailure"
│   ├── OOM 被杀 → 见 OOM 决策树
│   ├── 节点故障 → 检查 YARN NM 日志
│   └── 抢占 → 队列资源被抢占
├── "FetchFailedException"
│   ├── Shuffle 数据丢失（Executor 被杀后 Shuffle 文件丢了）
│   │   ├── 开启 External Shuffle Service
│   │   └── K8s: 用 Celeborn / 持久化 Shuffle 数据
│   └── 网络超时 → 调大 spark.shuffle.io.maxRetries / retryWait
├── "SparkException: Job aborted"
│   └── 看具体的 Cause → 通常是上面某种错误的包装
└── "TimeoutException"
    ├── Broadcast 超时 → spark.sql.broadcastTimeout 调大
    └── Heartbeat 超时 → spark.network.timeout 调大
```

## 5. Shuffle 问题

```
Shuffle 问题
├── "Shuffle block too large"
│   └── 单 partition 数据 > 2GB → 增加 shuffle.partitions
├── Shuffle 文件占满磁盘
│   ├── 清理 spark.local.dir 下的 blockmgr-*
│   └── 增加磁盘 / 多盘配置
├── Shuffle Read 慢
│   ├── 远程读取多 → 数据本地性差 → 检查 YARN 调度
│   └── 网络带宽瓶颈 → 检查节点间带宽
└── External Shuffle Service 挂了
    └── 检查 NM 上的 ESS 进程 → 重启 NM
```

---

*Spark Expert | 故障排查决策树 v1.0 | 2026-04-08*
