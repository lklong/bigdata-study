# Apache Spark 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 一、核心引擎能力

### 1.1 Spark Core — 分布式计算引擎

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **RDD 计算** | 弹性分布式数据集，惰性求值 | `sc.parallelize()` / `sc.textFile()` → transformations → actions | 每个 action 触发一次 DAG 执行；无法跨 Stage 复用中间结果（除非 `persist()`） | RDD API 已不推荐直接使用，优先用 DataFrame/Dataset |
| **DAG 调度** | 将用户逻辑编译为 Stage→Task 的有向无环图 | 自动完成，用户无需干预 | Stage 数取决于 Shuffle 边界；Stage 内 Task 数 = 分区数 | `spark.sql.shuffle.partitions` 默认 200，大数据量要调大 |
| **内存管理** | 统一内存管理（Execution + Storage 动态共享） | `spark.memory.fraction=0.6` 控制总比例 | 堆内存受 JVM GC 限制；堆外内存不受 GC 影响但需手动管理 | K8s 容器场景 `memory.fraction` 别超 0.6，留给 cgroup overhead |
| **容错** | RDD lineage 重算丢失分区 | 自动完成；`checkpoint()` 可截断 lineage | checkpoint 需要可靠存储（HDFS）；长 lineage 重算代价大 | 迭代算法（ML）必须定期 checkpoint |
| **广播变量** | 将只读数据高效分发到所有 Executor | `sc.broadcast(data)` | 单个广播变量 < 8GB（`spark.driver.maxResultSize`）；序列化后传输 | 不要在循环中重复广播；用完 `unpersist()` 释放内存 |
| **累加器** | 分布式计数器/求和器 | `sc.longAccumulator("name")` | 只支持加法语义（满足交换律+结合律）；Task 重试可能重复累加 | 仅在 action 中读取最终值，transformation 中的值不保证准确 |

### 1.2 Spark SQL — 结构化数据处理

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **SQL 查询** | ANSI SQL 兼容的查询引擎 | `spark.sql("SELECT ...")` 或 DataFrame API | 不支持存储过程；部分 SQL 方言和 Hive SQL 不兼容 | 优先用 DataFrame API（编译时类型检查） |
| **Catalyst 优化器** | 基于规则+成本的查询优化 | 自动完成；`EXPLAIN EXTENDED` 查看执行计划 | CBO 需要手动收集统计信息 `ANALYZE TABLE` | 定期 `ANALYZE TABLE ... COMPUTE STATISTICS` |
| **AQE 自适应执行** | 运行时根据统计信息重优化 | `spark.sql.adaptive.enabled=true`（3.0+ 默认开启） | 仅优化 Shuffle 后的 Stage；不能改变 Join 类型（3.2 之前） | K8s 场景注意 AQE + dynamicAllocation 的"震荡"问题 |
| **数据源 API** | 读写 Parquet/ORC/JSON/CSV/JDBC/Iceberg/Hudi/Delta | `spark.read.format("parquet").load(path)` | JDBC 源全表拉取性能差；JSON/CSV 推断 schema 慢 | 大表用 Parquet/ORC + 列裁剪 + 谓词下推 |
| **UDF/UDAF** | 用户自定义函数 | `spark.udf.register("name", func)` | UDF 是黑盒，Catalyst 无法优化；Python UDF 有序列化开销 | 优先用内置函数 > Pandas UDF > Scala UDF > Python UDF |
| **Join 策略** | BroadcastHashJoin / SortMergeJoin / ShuffledHashJoin | 自动选择；`broadcast(df)` 强制广播 | Broadcast 要求小表 < `spark.sql.autoBroadcastJoinThreshold`（默认 10MB） | 大表 Join 大表必须走 SortMergeJoin；倾斜时开启 AQE skewJoin |
| **窗口函数** | `ROW_NUMBER`, `RANK`, `LAG`, `LEAD`, `SUM OVER` | `SELECT *, ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` | 窗口分区数据必须全部加载到单个 Task 内存 | 窗口分区不能太大（> 100M 行考虑拆分） |

### 1.3 Spark Streaming / Structured Streaming

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **微批处理** | 按时间间隔切分数据批次 | `readStream.format("kafka")...` + `trigger(Trigger.ProcessingTime("10s"))` | 延迟 = 批次间隔 + 处理时间（秒级） | 生产用 Structured Streaming，DStream API 已废弃 |
| **连续处理** | 毫秒级延迟（实验性） | `trigger(Trigger.Continuous("1s"))` | 仅支持 map 类算子；不支持聚合/窗口/Join | 不推荐生产使用（Spark 3.5 仍是实验性） |
| **Exactly-Once** | 精确一次语义 | Source 支持 replay + Sink 支持幂等/事务 | 需要 Source 和 Sink 同时支持；Kafka→Kafka 可保证端到端 | 文件 Sink 天然幂等；JDBC Sink 需要自己实现幂等 |
| **Watermark** | 处理事件时间乱序 | `withWatermark("eventTime", "10 minutes")` | 超过 watermark 的数据被丢弃 | watermark 设太大 → 状态膨胀；设太小 → 丢数据 |
| **状态管理** | 有状态处理（sessionWindow, flatMapGroupsWithState） | `groupByKey.flatMapGroupsWithState(...)` | 状态存储在 Executor 内存/RocksDB；状态太大影响 Checkpoint | 定期清理过期状态 |

### 1.4 Spark MLlib — 机器学习

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **分类/回归** | LR, RF, GBT, SVM, NaiveBayes | `LogisticRegression().fit(train)` | 不支持深度学习；模型参数受 Driver 内存限制 | 大数据量用 `maxIter` 控制训练时间 |
| **聚类** | KMeans, GMM, LDA, BisectingKMeans | `KMeans(k=10).fit(data)` | K 值需预设；高维数据聚类效果差 | 先降维再聚类 |
| **Pipeline** | 特征工程 + 模型训练的流水线 | `Pipeline(stages=[tokenizer, hashingTF, lr])` | Pipeline 不支持自动特征选择 | 用 CrossValidator 做超参搜索 |
| **模型保存** | 保存/加载训练好的模型 | `model.save(path)` / `Model.load(path)` | 跨版本兼容性不保证 | 记录 Spark 版本号 |

### 1.5 GraphX — 图计算

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **图构建** | 顶点 + 边 → 分布式图 | `Graph(vertices, edges)` | 基于 RDD API，不支持 DataFrame | 大图考虑用 GraphFrames（基于 DataFrame） |
| **PageRank** | 页面排名算法 | `graph.pageRank(tol=0.01)` | 迭代算法，收敛慢时代价高 | 设 `maxIter` 防止无限迭代 |
| **Connected Components** | 连通分量 | `graph.connectedComponents()` | 大图内存消耗大 | 先做图裁剪 |

---

## 二、部署模式

| 模式 | 使用方式 | 适用场景 | 限制 | 注意 |
|------|---------|---------|------|------|
| **Local** | `--master local[*]` | 开发/测试 | 单机，不分布式 | 不要用于生产 |
| **YARN Client** | `--master yarn --deploy-mode client` | 交互式（Notebook, spark-shell） | Driver 在提交机器，网络断 → 任务挂 | 适合 Ad-hoc 查询 |
| **YARN Cluster** | `--master yarn --deploy-mode cluster` | 生产批处理 | Driver 在集群内，不便交互调试 | 推荐生产使用 |
| **K8s Client** | `--master k8s://... --deploy-mode client` | K8s 交互式 | 和 YARN Client 类似 | 需要 kubectl proxy |
| **K8s Cluster** | `--master k8s://... --deploy-mode cluster` | K8s 生产 | Pod 启动慢（vs YARN Container）；无数据本地性 | 用 Pod Template 定制网络/存储 |
| **Standalone** | `--master spark://host:7077` | 独立部署 | 资源管理简单，无队列 | 小规模集群可用 |

---

## 三、Shuffle 机制

| 能力 | 使用方式 | 限制 | 注意 |
|------|---------|------|------|
| **Sort Shuffle** | 默认 Shuffle Manager | 中间文件数 = Map Task 数 × 2（data + index） | 大 Shuffle 注意磁盘空间 |
| **External Shuffle Service (ESS)** | `spark.shuffle.service.enabled=true` | YARN 特有；需要在每个 NM 部署 | 开启后 dynamicAllocation 才能安全缩容 |
| **Celeborn (RSS)** | `spark.shuffle.manager=celeborn` | 需要独立部署 Celeborn 集群 | K8s 场景推荐；解决 Shuffle 数据在 Pod 间不共享的问题 |
| **Shuffle 排序** | `spark.shuffle.sort.bypassMergeThreshold=200` | bypass 仅适用于无排序需求的 Shuffle | 分区数 > 200 自动用 Sort |
| **压缩** | `spark.shuffle.compress=true` + `spark.io.compression.codec=zstd` | 压缩增加 CPU 消耗 | zstd 比 lz4 压缩率高 30%，速度接近 |

---

## 四、关键参数速查

| 参数 | 默认值 | 建议 | 说明 |
|------|--------|------|------|
| `spark.executor.memory` | 1g | 4-8g | Executor 堆内存 |
| `spark.executor.cores` | 1 | 2-5 | 每个 Executor 的 CPU 核数 |
| `spark.executor.instances` | 动态 | 根据数据量 | 固定 Executor 数 |
| `spark.sql.shuffle.partitions` | 200 | 数据量GB数×2~5 | Shuffle 后分区数 |
| `spark.sql.adaptive.enabled` | true | true | AQE 自适应 |
| `spark.serializer` | JavaSerializer | KryoSerializer | 序列化器 |
| `spark.default.parallelism` | 总core数 | 总core数×2~3 | RDD 默认并行度 |
| `spark.memory.fraction` | 0.6 | 0.6 | 统一内存占比 |
| `spark.memory.storageFraction` | 0.5 | 0.3~0.5 | 缓存占统一内存的比例 |
| `spark.dynamicAllocation.enabled` | false | true | 动态分配 |
| `spark.dynamicAllocation.minExecutors` | 0 | 10~20 | 最少 Executor |
| `spark.dynamicAllocation.maxExecutors` | ∞ | 根据集群 | 最多 Executor |
| `spark.sql.autoBroadcastJoinThreshold` | 10MB | 50-200MB | 广播 Join 阈值 |

---

## 五、功能边界 — Spark 做不到什么

| 不支持 | 替代方案 |
|--------|---------|
| 毫秒级实时处理 | Flink |
| 事务性更新（ACID 单行） | HBase / RDBMS |
| 存储过程 | Hive / Presto UDF |
| 图数据库查询 (Cypher) | Neo4j / JanusGraph |
| 深度学习训练 | TensorFlow / PyTorch (可用 Spark 做数据预处理) |
| 低延迟点查 (< 10ms) | HBase / Redis |

---

*Spark Expert | 功能地图 v1.0 | 2026-04-08*
