# Apache Flink 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 一、核心流计算能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **流处理** | 逐条/微批处理无界数据流 | `StreamExecutionEnvironment` + Source → Transform → Sink | 有状态算子受 State Backend 大小限制 | 优先用 DataStream API 或 Table/SQL API |
| **批处理** | 处理有界数据集 | Flink 1.12+ 流批一体：`execution.runtime-mode=BATCH` | 批模式下不支持某些流特性（如 Timer） | 用统一 API，通过 runtime-mode 切换 |
| **事件时间** | 按事件发生时间处理 | `assignTimestampsAndWatermarks(...)` | 需要数据中有时间字段；乱序依赖 Watermark | 生产必须用事件时间（不是处理时间） |
| **处理时间** | 按处理引擎时钟 | `TimeCharacteristic.ProcessingTime` | 不保证顺序；重放数据结果不一致 | 仅用于对时间不敏感的场景 |
| **Watermark** | 追踪事件时间进度 | `WatermarkStrategy.forBoundedOutOfOrderness(Duration.ofSeconds(10))` | 超过 Watermark 的数据被丢弃或走侧输出 | 设太大 → 延迟高；设太小 → 丢数据 |
| **窗口** | 将无界流切分为有限批次 | Tumbling / Sliding / Session / Global Window | Session Window 状态可能很大；Global Window 需自定义 Trigger | 窗口大小和数据到达率匹配 |
| **Join** | 流-流 Join / 流-维表 Join | `stream.join(otherStream).where(...).equalTo(...)` | 流-流 Join 需要窗口限制；维表 Join 需缓存或 Lookup | 大维表用 Async I/O |
| **CEP** | 复杂事件处理（模式匹配） | `Pattern.begin("start").where(...)...` | 模式越复杂，状态越大 | 设 `within()` 限制模式匹配窗口 |
| **侧输出** | 将不符合条件的数据路由到侧流 | `OutputTag<T> + ctx.output(tag, data)` | 侧输出只在 ProcessFunction 中可用 | 替代 filter + 重复计算 |

---

## 二、状态管理

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **Keyed State** | 按 Key 分区的状态 | `ValueState / ListState / MapState / ReducingState` | 必须在 KeyedStream 上使用 | 单 Key 状态不要太大 |
| **Operator State** | 算子级别状态（非 Keyed） | `ListCheckpointed / CheckpointedFunction` | 恢复时需要自己实现状态重分布 | 典型用途：Kafka Source 的 offset |
| **Broadcast State** | 广播状态 + 主流 Join | `BroadcastProcessFunction` | 广播端更新不能太频繁（全量同步） | 适合规则引擎动态更新 |
| **State TTL** | 状态自动过期 | `StateTtlConfig.newBuilder(Time.days(7)).build()` | TTL 检查粒度是访问时/清理器定期 | 防止状态无限膨胀 |
| **State Backend** | 状态存储引擎 | MemoryStateBackend / FsStateBackend / RocksDBStateBackend | RocksDB 读写比内存慢 10-50x；但支持超大状态 | 状态 > 几 GB 必须用 RocksDB |

---

## 三、容错机制

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **Checkpoint** | 自动定期快照 | `env.enableCheckpointing(60000)` | 快照期间有性能开销；背压可能导致超时 | 间隔不要太短（> 30s） |
| **Savepoint** | 手动全量快照 | `flink savepoint <jobId> [path]` | 全量快照，比增量 CP 慢 | 升级/迁移前必做 Savepoint |
| **Exactly-Once** | 精确一次语义 | `CheckpointingMode.EXACTLY_ONCE` + 支持事务的 Sink | Source 必须支持 replay；Sink 必须支持事务/幂等 | Kafka→Flink→Kafka 端到端 EOS |
| **At-Least-Once** | 至少一次 | `CheckpointingMode.AT_LEAST_ONCE` | 可能有重复数据 | 下游做幂等处理 |
| **非对齐 Checkpoint** | 背压场景下 CP 不阻塞 | `execution.checkpointing.unaligned=true` | 快照更大（含 in-flight 数据）；恢复更慢 | 背压严重时才开启 |
| **增量 Checkpoint** | 只传增量 SST 文件 | `state.backend.incremental=true`（仅 RocksDB） | 增量链过长影响恢复速度 | 定期做 Savepoint 截断增量链 |

---

## 四、Flink SQL / Table API

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **流式 SQL** | SQL 查询无界流 | `tableEnv.sqlQuery("SELECT ...")` | 聚合需要窗口/Group Window；不是所有 SQL 都能流式执行 | 避免无界 GROUP BY（状态会无限增长） |
| **Catalog** | 元数据管理 | HiveCatalog / JdbcCatalog / IcebergCatalog | 不同 Catalog 支持的 DDL 不同 | 生产用 HiveCatalog 兼容 Hive 元数据 |
| **Temporal Table** | 时态表（版本化维表） | `FOR SYSTEM_TIME AS OF` | 需要主键 + 时间属性 | 用于点查维表的历史版本 |
| **Lookup Join** | 流与外部维表 Join | `SELECT * FROM orders JOIN products FOR SYSTEM_TIME AS OF orders.proctime ON ...` | 需要 Connector 实现 LookupTableSource | 注意缓存策略 |
| **MATCH_RECOGNIZE** | SQL 级 CEP | `SELECT * FROM events MATCH_RECOGNIZE(...)` | SQL 方言，复杂模式表达力弱于 Java API | 简单模式匹配优先用 SQL |

---

## 五、部署模式

| 模式 | 使用方式 | 适用场景 | 限制 | 注意 |
|------|---------|---------|------|------|
| **Session Cluster** | 长期运行的集群，多 Job 共享 | `flink run -t yarn-session` | Job 间资源竞争 | 适合开发测试 |
| **Per-Job Cluster** | 每个 Job 独占集群 | `flink run -t yarn-per-job` | 每次启动新集群，启动慢 | YARN 生产推荐 |
| **Application Mode** | Job 在集群内解析 | `flink run-application -t yarn-application` | Flink 1.11+ | 推荐：减少 Client 端资源消耗 |
| **K8s Native** | Flink 直接管理 K8s Pod | `flink run -t kubernetes-application` | Pod 启动慢 | 云原生场景 |
| **Standalone** | 独立部署 | 手动启动 JM/TM | 无资源管理 | 仅测试 |

---

## 六、功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 大规模批处理（PB 级 ETL） | Spark |
| 交互式 SQL 查询 | Trino / Presto |
| 机器学习训练 | Spark MLlib / TensorFlow |
| 图计算 | Spark GraphX / Gelly（Flink 已废弃） |
| 点查服务 (< 10ms) | HBase / Redis |

---

## 七、关键参数速查

| 参数 | 默认 | 建议 | 说明 |
|------|------|------|------|
| `taskmanager.memory.process.size` | 1728m | 4-8g | TM 进程内存 |
| `taskmanager.numberOfTaskSlots` | 1 | 2-4 | 每个 TM 的 slot 数 |
| `parallelism.default` | 1 | 根据数据量 | 默认并行度 |
| `execution.checkpointing.interval` | 无 | 60000ms | CP 间隔 |
| `state.backend` | memory | rocksdb | 状态后端 |
| `state.backend.incremental` | false | **true** | 增量 CP |
| `restart-strategy` | none | fixed-delay(3, 10s) | 重启策略 |
| `table.exec.state.ttl` | 0 | 根据业务 | SQL 状态 TTL |

---

*Flink Expert | 功能地图 v1.0 | 2026-04-08*
