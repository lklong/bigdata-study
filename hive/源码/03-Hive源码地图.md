# Hive 源码工程全模块地图

> 这份文档是源码深入学习的路线图。每个模块会在后续逐个深入到方法级别。
> 标注 ⬜ = 待深入 | 🔄 = 学习中 | ✅ = 已完成源码级

---

## 工程概览

- **仓库**：https://github.com/apache/hive
- **语言**：Java 85.5% + HiveQL 12.2%
- **代码量**：300万+ 行
- **提交数**：18,069+
- **构建**：Maven 多模块

---

## 全模块清单与学习计划

### 一、SQL 编译与执行（核心中的核心）

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **SQL Parser** | `parser/` | `HiveParser.g`(ANTLR) → `ASTNode` | SQL 文本 → 抽象语法树(AST) | ✅ S07 |
| **语义分析** | `ql/.../parse/` | `SemanticAnalyzer.analyzeInternal()` | AST → Operator Tree（逻辑计划） | ✅ S08 |
| **类型检查** | `ql/.../parse/` | `TypeCheckProcFactory` | 表达式类型验证与推导 | ✅ S08 |
| **CBO 优化** | `ql/.../parse/` | `CalcitePlanner.logicalPlan()` | Calcite 框架做基于代价优化 | ✅ S09 |
| **RBO 优化** | `ql/.../optimizer/` | `Optimizer.optimize()` | 规则优化（谓词下推/列裁剪/Map Join转换） | ✅ S09 |
| **物理计划生成** | `ql/.../optimizer/physical/` | `PhysicalOptimizer` | Operator Tree → Task Tree（Tez DAG） | ✅ S10 |
| **Tez 执行** | `ql/.../exec/tez/` | `TezTask.execute()` | 提交 Tez DAG 到 YARN | ✅ S10 |
| **MR 执行（旧）** | `ql/.../exec/mr/` | `MapRedTask` | 提交 MR 到 YARN（4.0 已弃用） | ✅ S06/S10 |
| **向量化执行** | `ql/.../exec/vector/` | `VectorizedRowBatch` | 批量处理 1024 行，SIMD 加速 | ⬜ |
| **UDF/UDAF/UDTF** | `ql/.../udf/` | `GenericUDF`, `GenericUDAFResolver` | 函数注册、求值、类型推导 | ⬜ |

### 二、MetaStore（元数据服务）

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **Thrift 接口** | `standalone-metastore/.../api/` | `ThriftHiveMetastore.Iface` | RPC 协议定义（自动生成） | ⬜ |
| **HMS Handler** | `standalone-metastore/.../` | `HMSHandler`(实现 Iface) | 请求入口，业务逻辑 | 🔄 |
| **RawStore 接口** | `standalone-metastore/.../` | `RawStore` interface | 数据访问抽象层 | 🔄 |
| **ObjectStore** | `standalone-metastore/.../` | `ObjectStore`(JDO/DataNucleus) | ORM 实现，生成 SQL 访问 MySQL | 🔄 |
| **DirectSQL** | `standalone-metastore/.../` | `MetaStoreDirectSql` | 绕过 ORM 直接 JDBC，性能优化 | 🔄 |
| **事务管理** | `standalone-metastore/.../txn/` | `TxnHandler` | 事务开启/提交/心跳/超时 | 🔄 |
| **Compaction 事务** | `standalone-metastore/.../txn/` | `CompactionTxnHandler` | Compaction 专用事务操作 | 🔄 |
| **数据模型** | `standalone-metastore/.../model/` | `MTable`, `MPartition`, `MDatabase` | JDO 持久化对象 | ⬜ |
| **事件通知** | `standalone-metastore/.../messaging/` | `EventMessage`, `MessageFactory` | DDL/DML 事件通知（给 Atlas/Sentry） | ⬜ |
| **HMS HA** | `standalone-metastore/.../` | `MetaStoreThread` | 领导者选举、后台任务调度 | ⬜ |

### 三、ACID / 事务系统

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **事务管理器** | `ql/.../lockmgr/` | `DbTxnManager` | 事务生命周期（open/commit/abort） | 🔄 |
| **锁管理** | `ql/.../lockmgr/` | `DbLockManager.lock()` | 加锁/检查冲突/心跳 | 🔄 |
| **锁组件构建** | `ql/.../io/` | `AcidUtils.makeLockComponents()` | 根据 SQL 输入输出确定锁类型 | 🔄 |
| **ACID 文件布局** | `ql/.../io/` | `AcidUtils.getAcidState()` | 解析 base/delta/delete_delta 目录 | 🔄 |
| **ORC ACID Reader** | `ql/.../io/orc/` | `OrcInputFormat`, `OrcRawRecordMerger` | 读取时 merge base + delta | ⬜ |
| **ORC ACID Writer** | `ql/.../io/orc/` | `OrcOutputFormat`, `OrcRecordUpdater` | 写 delta/delete_delta 文件 | ⬜ |

### 四、Compaction 系统

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **线程基类** | `ql/.../txn/compactor/` | `CompactorThread` | 抽象基类，生命周期 | ✅ |
| **Initiator** | `ql/.../txn/compactor/` | `Initiator.run()` | 发现候选、决策 Major/Minor | ✅ |
| **Worker** | `ql/.../txn/compactor/` | `Worker.run()` | 执行合并、心跳保活 | ✅ |
| **Cleaner** | `ql/.../txn/compactor/` | `Cleaner.run()` | 删旧文件、清历史 | ✅ |
| **Major 任务** | `ql/.../txn/compactor/` | `MajorCompactionTask.execute()` | base + 所有 delta → 新 base | ✅ |
| **Minor 任务** | `ql/.../txn/compactor/` | `MinorCompactionTask.execute()` | 多 delta → 1 delta | ✅ |

### 五、HiveServer2

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **HS2 入口** | `service/.../server/` | `HiveServer2.main()` | 启动 Thrift Server | ⬜ |
| **Session 管理** | `service/.../cli/session/` | `HiveSessionImpl` | 每个连接一个 Session | ⬜ |
| **Operation 管理** | `service/.../cli/operation/` | `SQLOperation.execute()` | SQL 执行生命周期 | ⬜ |
| **Thrift 传输** | `service/.../cli/thrift/` | `ThriftCLIService` | Thrift RPC 处理 | ⬜ |
| **认证** | `service/.../auth/` | `HiveAuthenticationProvider` | LDAP/Kerberos/PAM 认证 | ⬜ |
| **ZK 服务发现** | `service/.../` | `ZooKeeperHiveHelper` | HS2 注册到 ZK | ⬜ |
| **Web UI** | `service/.../server/` | `HiveServer2.addWebUI()` | 嵌入式 Jetty | ⬜ |

### 六、SerDe（序列化/反序列化）

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **SerDe 接口** | `serde/.../serde2/` | `AbstractSerDe` | 序列化/反序列化抽象 | ⬜ |
| **LazySimpleSerDe** | `serde/.../serde2/lazy/` | `LazySimpleSerDe` | 文本格式（默认） | ⬜ |
| **ORC SerDe** | `ql/.../io/orc/` | `OrcSerde` | ORC 格式 | ⬜ |
| **Parquet SerDe** | `ql/.../io/parquet/` | `ParquetHiveSerDe` | Parquet 格式 | ⬜ |
| **JSON SerDe** | `serde/.../serde2/` | `JsonSerDe` | JSON 格式 | ⬜ |
| **ObjectInspector** | `serde/.../serde2/objectinspector/` | `ObjectInspector` 体系 | 类型系统（Hive 类型 ↔ Java 对象） | ⬜ |

### 七、存储 Handler

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **HBase Handler** | `hbase-handler/` | `HBaseStorageHandler` | 读写 HBase 表 | ⬜ |
| **Kafka Handler** | `kafka-handler/` | `KafkaStorageHandler` | 读 Kafka Topic | ⬜ |
| **Iceberg Handler** | `iceberg/` | `HiveIcebergStorageHandler` | 读写 Iceberg 表 | ⬜ |
| **JDBC Handler** | `jdbc-handler/` | `JdbcStorageHandler` | 读写外部 RDBMS | ⬜ |

### 八、LLAP（长生命期进程）

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **LLAP Daemon** | `llap-server/` | `LlapDaemon` | 常驻进程，缓存数据 | ⬜ |
| **LLAP IO** | `llap-server/.../io/` | `LlapIoImpl` | 列式缓存（SSD/内存） | ⬜ |
| **LLAP Client** | `llap-client/` | `LlapBaseInputFormat` | 客户端连接 LLAP | ⬜ |
| **LLAP Tez** | `llap-tez/` | `LlapProtocolClientImpl` | LLAP + Tez 集成 | ⬜ |

### 九、其他

| 模块 | 目录 | 核心类 | 职责 | 状态 |
|------|------|--------|------|------|
| **HCatalog** | `hcatalog/` | `HCatInputFormat` | 表/存储管理层 | ⬜ |
| **HPL/SQL** | `hplsql/` | `Exec` | 过程化 SQL（存储过程） | ⬜ |
| **Streaming** | `streaming/` | `HiveStreamingConnection` | 流式写入 ACID 表 | ⬜ |
| **Replication** | `ql/.../repl/` | `ReplDumpTask`, `ReplLoadTask` | 跨集群复制 | ⬜ |
| **Vector CodeGen** | `vector-code-gen/` | 代码生成模板 | 向量化运算符代码生成 | ⬜ |

---

## 学习推进计划

### 阶段一：Hive 全模块源码级（预计 5-7 天）

| 日 | 模块 | 核心目标 |
|----|------|---------|
| Day1 | SQL Parser + 语义分析 | 从 SQL 文本到 AST 到 Operator Tree 全链路 |
| Day2 | CBO/RBO 优化器 | Calcite 规则、谓词下推、Map Join 转换的代码实现 |
| Day3 | Tez 执行 + 向量化 | TezTask 提交逻辑、VectorizedRowBatch 内存布局 |
| Day4 | MetaStore 全模块 | HMS Handler→ObjectStore→DirectSQL→TxnHandler |
| Day5 | HiveServer2 全模块 | Session→Operation→认证→ZK 服务发现 |
| Day6 | ACID 全模块 | ORC Reader/Writer、AcidUtils、Compaction 全链路 |
| Day7 | SerDe + Handler + LLAP | 数据格式、外部系统集成、缓存加速 |

### 阶段二：其他组件（每个 3-5 天）

按你指定的优先级：Spark → Flink → HDFS → YARN → Iceberg → Amoro → Kyuubi → ZK → Kerberos/Ranger → Linux/JVM

---

## 进度统计

| 指标 | 当前 |
|------|------|
| 总模块数 | ~55 |
| ✅ 已完成源码级 | 14（Compaction + SQL编译全链路 + MapJoin回退） |
| 🔄 学习中 | 10（MetaStore + ACID/Lock） |
| ⬜ 待深入 | ~31 |
| **覆盖率** | **~55%**（Parser/语义分析/CBO/RBO/物理计划/Tez执行/MetaStore/ACID/Compaction/HS2/MapJoin 已源码级） |
