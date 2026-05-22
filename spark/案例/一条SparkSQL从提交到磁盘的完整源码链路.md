# 一条 Spark SQL 从提交到磁盘的完整源码链路

> 综述文档 | 串联 Spark Catalyst + YARN NM + HDFS DataNode 三大组件
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20
>
> 本文是 2026-05-20 三篇深度源码解析的"总图"，将 [Catalyst][1] / [NM Container][2] / [HDFS DN 写][3] 三条独立链路串成一条完整故事线。
>
> [1]: ../spark/源码/Catalyst-优化器全链路源码深度解析.md
> [2]: ../yarn/源码/NodeManager-Container生命周期源码深度解析.md
> [3]: ../hdfs/源码/DataNode-写数据流水线源码深度解析.md

---

## 故事开始：一条 SQL 的旅程

```sql
INSERT INTO TABLE warehouse.fact_orders
SELECT user_id, sum(amount), current_date()
FROM staging.orders
WHERE dt = '2026-05-20' AND amount > 0
GROUP BY user_id;
```

这条 SQL 提交到 Spark on YARN 后，会经过**九大阶段**最终把数据写到 HDFS 三副本。

```
[阶段 1] Driver: spark.sql(...)               ─┐
[阶段 2] Catalyst: 五段流水线优化               │ Spark 端
[阶段 3] AM 申请 Executor Containers           ─┘
                                                 ── RM/NM ──
[阶段 4] RM 分配 Container token to AM         ─┐
[阶段 5] AM 调 NM startContainer RPC          │  YARN 端
[阶段 6] NM ContainerLaunch + Localizer      │
[阶段 7] NM ContainersMonitor 接管           ─┘
                                                 ── HDFS ──
[阶段 8] Executor write → DataXceiver          ─┐
[阶段 9] DN BlockReceiver pipeline 落盘三副本   │ HDFS 端
                                                 ─┘
```

---

## 阶段 1-2：Spark Driver 内 — Catalyst 五段流水线

**入口**：`SparkSession.sql(sqlText)` → `QueryExecution`

**五段链**（详见 [Catalyst 文档][1]）：

```
SparkSqlParser.parsePlan
   │ ANTLR4 → Unresolved LogicalPlan
   ▼
Analyzer.executeAndCheck
   │ 绑定 Catalog/Schema/UDF → Resolved LogicalPlan
   │ 比如 `staging.orders` 解析成 HiveRelation，`current_date()` 解析成 CurrentDate 表达式
   ▼
SparkOptimizer.executeAndTrack    ← RuleExecutor 三层循环（Batch/FixedPoint/Rule）
   │ 跑 100+ 规则（PushDownPredicate, ColumnPruning, ConstantFolding, ...）
   │ "amount > 0" 推到 Scan 旁；用不到的列被砍；CBO Join Reorder 不触发（无 join）
   ▼
SparkPlanner.plan
   │ Strategy 选物理算子：HashAggregateExec, FileSourceScanExec, InsertIntoHadoopFsRelationCommand
   ▼
prepareForExecution
   │ 插入 ShuffleExchangeExec、WholeStageCodegen、AdaptiveSparkPlanExec
```

**最终输出**：一棵 SparkPlan 树，根节点是 `InsertIntoHadoopFsRelationCommand`，叶子节点是 `FileSourceScanExec`。

**关键日志**（开 `spark.sql.planChangeLog.level=INFO`）：
```
=== Applying Rule org.apache.spark.sql.catalyst.optimizer.PushDownPredicates ===
Filter (isnotnull(dt) && dt = 2026-05-20 && amount > 0)
+- HiveTableRelation [...]
becomes
HiveTableRelation [...] with pushed filters: [dt=2026-05-20, amount>0]
```

---

## 阶段 3：AM 申请 Executor Container

`executedPlan.execute()` 触发 RDD 提交：
1. DAGScheduler 将 RDD 切分 Stage（ShuffleMapStage + ResultStage）
2. TaskScheduler 通过 `CoarseGrainedSchedulerBackend` 决定需要多少 Executor
3. `YarnAllocator.requestTotalExecutors(...)` 通过 ApplicationMasterProtocol 向 **RM** 申请 Container

申请请求中包含：
- `Resource{memory: 4096MB, vCores: 2}`
- `Priority{1}`
- `ContainerLaunchContext` 模板（Spark Executor 启动命令）

---

## 阶段 4-5：RM 分配 + AM 调用 NM

1. RM 的 `Capacity/FairScheduler` 给 AM 分配 Container（带 ContainerToken）
2. AM 的 `ContainerLauncher`（每个 Container 一次 RPC）调 `NodeManager.startContainers(ContainerToken, ContainerLaunchContext)`
3. NM 的 `ContainerManagerImpl.startContainerInternal` 接单：
   - 校验 ContainerToken 签名
   - 校验申请的资源 ≤ NM 注册的资源
   - 生成 `ContainerImpl` 状态机实例 (NEW)
   - 异步发 `INIT_CONTAINER` 事件 → 进入 LOCALIZING 状态

---

## 阶段 6：NM ContainerLaunch — Container 启动主流程

详见 [NM Container 文档][2]，关键步骤回顾：

```
LOCALIZING → ResourceLocalizationService 下载 jar 资源
            (Spark Executor 用的依赖、conf 文件、应用 jar)
            │
            ▼
LOCALIZED → 状态机触发 LAUNCH_CONTAINER 事件
            │
            ▼
ContainerLaunch.call() 同步阻塞执行：
  ① 展开环境变量（{{JAVA_HOME}} → $JAVA_HOME）
  ② sanitizeEnv 注入 NM 标准变量
  ③ 写 launch_container.sh
  ④ 写 container_tokens（Block Token / Delegation Token）
  ⑤ 发 CONTAINER_LAUNCHED 事件 → 状态机进 RUNNING
  ⑥ exec.launchContainer() （LCE: setuid + cgroup + bash launch_container.sh）
  ⑦ 阻塞等进程退出 → 返回 exit code
```

**生成的 launch_container.sh**（节选）：
```bash
#!/bin/bash
export PWD="/data/yarn/local/usercache/.../container_xxx"
export LOGNAME="hadoop"
export JAVA_HOME="/usr/lib/jvm/java-1.8.0"
export HADOOP_TOKEN_FILE_LOCATION="$PWD/container_tokens"
export CLASSPATH="$PWD/__spark_libs__/*:..."

ln -sf /data/yarn/local/filecache/.../spark-3.4.0.tar.gz/* $PWD/

exec /usr/lib/jvm/java-1.8.0/bin/java \
  -server -Xmx3072m -Xss4m \
  -Djava.io.tmpdir=$PWD/tmp \
  org.apache.spark.executor.YarnCoarseGrainedExecutorBackend \
  --driver-url spark://...
```

---

## 阶段 7：NM ContainersMonitor 实时监控

ContainerLaunch 完成 ⑤（state=RUNNING）的同时，**ContainersMonitor 线程**已经把这个 Container 加入 `trackingContainers` 监控池。

每 3 秒（默认）：
1. 通过 pid 文件拿 Container 主进程 pid
2. 读 `/proc/<pid>/stat` 构建进程树（`ResourceCalculatorProcessTree`）
3. 计算 `vmem`、`rss`、`cpu%`
4. 与 `vmemLimit` / `pmemLimit` 比较
5. **超限 → 发 ContainerKillEvent → 状态机进 KILLING → 进程被 SIGKILL**

如果业务正常，进程一直运行直到任务完成。

---

## 阶段 8-9：Executor 写 HDFS — Pipeline 三副本落盘

Spark Executor 启动后，开始执行 task。最后阶段 `InsertIntoHadoopFsRelationCommand` 调用 `FileFormatWriter.write()`，每个 task 创建一个 `HadoopMapReduceCommitProtocol` 实例，写入流程：

```
DataFrame writer → FileSystem.create(path)
   │
   ▼
DistributedFileSystem.create
   │ → NameNode RPC: addBlock(...) 拿到 LocatedBlock(块ID + 三个 DN 地址)
   ▼
DFSOutputStream
   │ DataStreamer 线程 → 与 DN1 建 TCP，发 OP_WRITE_BLOCK
   ▼
[DN1] DataXceiver.writeBlock
   │ new BlockReceiver
   │ 与 DN2 建 TCP（mirror）
   ▼
[DN2] DataXceiver.writeBlock
   │ 与 DN3 建 TCP（mirror）
   ▼
[DN3] DataXceiver.writeBlock (LAST_IN_PIPELINE)
```

**之后每个 4KB packet** 沿 [HDFS DN 写文档][3] 描述的链路：

```
DN1.receivePacket()
  ① 收到 client 的 packet
  ② enqueue(seqno) → PacketResponder 队列
  ③ mirrorOut.flush → 发给 DN2
  ④ out.write(disk) → 写本地磁盘 (dfs.datanode.data.dir)
  ⑤ ↘
[DN2 同样的流程，再转发给 DN3]
[DN3 同样的流程，但没有 mirrorOut]

DN3.PacketResponder.run()  ← LAST_IN_PIPELINE
  发 ACK to DN2 ─→ DN2.PacketResponder ─→ DN1.PacketResponder ─→ client
```

**最后一个 packet** 触发 `finalizeBlock()`：
- DN 把 `current/rbw/blk_xxx` rename 到 `current/finalized/subdirN/blk_xxx`
- DN 通过 BPOfferService 发 `BlockReceivedAndDeleted` RPC 给 NN
- NN 把这个副本计入 blocksMap

---

## 跨组件关键时序总览

```
T0     Driver: spark.sql(...).write.insertInto(...)
T0+ms  Catalyst 五段优化（毫秒级，完全在 Driver JVM 内）
T0+s   AM 向 RM 申请 Container
T0+s+  RM 分配，AM 调用 NM startContainer
T0+~s  NM Localizer 下载资源（依赖文件大小，10s~分钟）
T0+~s  NM ContainerLaunch.call() 执行 launchContainer
T0+~s+ Executor JVM 启动（5-30s，依赖代码包大小、JVM 启动时间）
T0+~s+ Executor 注册到 Driver，开始接 task
T1     Task 执行：扫表 → 过滤 → 聚合 → 写 HDFS
T1+ms  每个 packet 4KB 写穿三个 DN（毫秒级 ACK 链）
T2     最后 packet → finalizeBlock → NN 收到 BR_AND_DELETED
T2+ms  Task 完成，向 Driver 汇报
TF     所有 Stage 完成，Driver shutdown，AM 注销
TF+    NM 接到 stopContainer，ContainersMonitor 移除监控，进程清理
```

---

## 故障定位地图（按阶段反查）

| 现象 | 大概率出在 | 关键日志/源码位置 |
|------|----------|----------------|
| SQL 提交后秒回错误 | 阶段 1-2 (Catalyst Analyzer) | Driver `AnalysisException` |
| 优化后 plan 不下推 | 阶段 2 (Optimizer 规则被排除) | `spark.sql.planChangeLog.level=INFO` |
| AM 申请不到资源 | 阶段 3-4 (RM Scheduler 资源不足) | RM 日志 `Application is in state ACCEPTED but ...` |
| Container 状态卡 LOCALIZING | 阶段 6 (Localizer 拉资源失败) | NM 日志 `Failed to download resource` |
| Container 启动后秒挂 | 阶段 6 (launch_container.sh 报错) | NM `<containerId>/stderr` 文件 |
| Container 跑一会被杀 | 阶段 7 (ContainersMonitor) | NM 日志 `running beyond physical memory limits` |
| HDFS 写慢 | 阶段 8-9 (DN 写盘 / mirror) | DN 日志 `Slow BlockReceiver write packet to mirror took XXXms` |
| 写到一半 ChecksumException | 阶段 9 (DN verifyChunks) | DN 日志 `Terminating due to a checksum error` |
| 数据写完 close 慢 | 阶段 9 (finalizeBlock fsync) | DN 日志最后一行的 ClientTraceLog |

---

## 方法论沉淀

通过这次"端到端"串联，**总结三大跨组件设计共性**：

### 共性 1：状态机 + 事件驱动
- Spark：QueryPlanningTracker 跟踪每阶段
- YARN NM：ContainerImpl 状态机（NEW→LOCALIZING→RUNNING→DONE）
- HDFS DN：Replica 状态机（RBW→FINALIZED）

→ 大型分布式系统几乎都用状态机管理生命周期，避免命令式控制流的状态错乱。

### 共性 2：异步解耦 + 同步关键路径
- Spark：lazy val 链式触发，但每阶段内同步执行
- YARN NM：ContainerLaunch.call() 同步阻塞，但发出的事件异步分发
- HDFS DN：BlockReceiver 同步写盘，但 PacketResponder 独立线程异步处理 ACK

→ 异步用于"不阻塞主线程"，同步用于"保证关键路径一致性"。混合用法是工程艺术。

### 共性 3：可观测性内嵌
- Spark：PlanChangeLogger，每条规则前后 plan 对比
- YARN：ContainersMonitor 周期 dump process-tree，OOM 时打印完整树
- HDFS：DN_CLIENTTRACE_FORMAT，每个 packet 写完都 trace；Slow IO 阈值告警

→ 没有可观测性的代码就是黑盒。优秀系统的日志/metric 是"主动设计"的，不是"事后补救"的。

---

## 引用源码文件清单

**Spark Catalyst**：
- `sql/core/src/main/scala/org/apache/spark/sql/execution/QueryExecution.scala`
- `sql/catalyst/src/main/scala/org/apache/spark/sql/catalyst/rules/RuleExecutor.scala`
- `sql/core/src/main/scala/org/apache/spark/sql/execution/SparkOptimizer.scala`
- `sql/catalyst/src/main/scala/org/apache/spark/sql/catalyst/optimizer/Optimizer.scala`

**YARN NodeManager**：
- `hadoop-yarn/.../nodemanager/containermanager/launcher/ContainerLaunch.java`
- `hadoop-yarn/.../nodemanager/containermanager/monitor/ContainersMonitorImpl.java`

**HDFS DataNode**：
- `hadoop-hdfs/.../server/datanode/DataXceiver.java`
- `hadoop-hdfs/.../server/datanode/BlockReceiver.java`

---

**完。这条 SQL 落到磁盘的旅程，全部源码证据完整，可作为团队"端到端排障演练"教材。**
