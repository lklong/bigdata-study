# Apache Hive 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 一、核心 SQL 引擎能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **SQL 查询** | 类 SQL (HiveQL) 查询大数据 | `beeline -u "jdbc:hive2://hs2:10000"` → `SELECT ...` | 不完全兼容 ANSI SQL；子查询支持有限 | 某些 SQL 需要特定引擎（Tez/Spark/MR） |
| **DDL** | 建表/改表/删表 | `CREATE TABLE / ALTER TABLE / DROP TABLE` | 外部表删除不删数据；内部表删除连数据一起删 | 生产用外部表为主 |
| **DML** | 数据操作 | `INSERT INTO/OVERWRITE / LOAD DATA / EXPORT/IMPORT` | 不支持单行 UPDATE/DELETE（需 ACID 表） | `INSERT OVERWRITE` 会先删后写 |
| **ACID 表** | 事务性表，支持 UPDATE/DELETE | `CREATE TABLE ... STORED AS ORC TBLPROPERTIES ('transactional'='true')` | 仅支持 ORC 格式；Compaction 是必须的 | 性能比非 ACID 表差 30-50% |
| **Join** | 多表关联 | `SELECT * FROM a JOIN b ON a.id = b.id` | MapJoin 要求小表 < `hive.auto.convert.join.noconditionaltask.size`（25MB） | 大表 Join 大表用 SMB Join |
| **窗口函数** | 分析函数 | `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` | 窗口数据全部加载到 Reducer 内存 | 分区太大会 OOM |
| **CTE** | 公共表表达式 | `WITH cte AS (SELECT ...) SELECT * FROM cte` | CTE 不能物化（每次引用重新计算） | 复杂 CTE 可能导致重复计算 |
| **LATERAL VIEW** | 行转列 | `SELECT * FROM t LATERAL VIEW explode(array_col) AS item` | 每行 explode 一次 | 大数组 explode 后数据膨胀 |

---

## 二、存储格式

| 格式 | 使用方式 | 适用场景 | 限制 | 注意 |
|------|---------|---------|------|------|
| **ORC** | `STORED AS ORC` | ACID 表/Hive 原生最优 | 仅 Hive 生态最佳支持 | Hive 表默认推荐 |
| **Parquet** | `STORED AS PARQUET` | 跨引擎兼容 (Spark/Presto/Flink) | 不支持 Hive ACID | 跨引擎场景推荐 |
| **TextFile** | `STORED AS TEXTFILE` | 简单文本/日志 | 无列裁剪/无压缩/无谓词下推 | 仅导入原始数据，尽快转为列存 |
| **Avro** | `STORED AS AVRO` | Schema Evolution 场景 | 不如列存性能好 | 配合 Schema Registry |
| **RCFile** | `STORED AS RCFILE` | 历史遗留 | 已被 ORC 取代 | 不要用于新表 |

---

## 三、分区与分桶

| 能力 | 使用方式 | 限制 | 注意 |
|------|---------|------|------|
| **静态分区** | `INSERT INTO t PARTITION (dt='2026-04-08') SELECT ...` | 需要预知分区值 | 适合 ETL 按日期写入 |
| **动态分区** | `INSERT INTO t PARTITION (dt) SELECT ..., dt FROM src` | `hive.exec.dynamic.partition.mode=nonstrict` | 可能产生大量小文件 |
| **分桶 (Bucket)** | `CLUSTERED BY (id) INTO 64 BUCKETS` | 写入时必须按桶分布（用 `hive.enforce.bucketing=true`） | SMB Join 要求两表桶数一致 |
| **分区裁剪** | WHERE 条件自动跳过不匹配分区 | 只有分区列的等值/范围条件生效 | `WHERE func(dt) = xxx` 不会裁剪 |

---

## 四、元数据管理 (Metastore)

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **HMS** | Hive Metastore Service | 独立进程 `hive --service metastore` | 单点瓶颈（高并发下） | 可部署多个 HMS 实例 + LB |
| **元数据存储** | MySQL/PostgreSQL | `javax.jdo.option.ConnectionURL` | 元数据库性能影响整个 Hive | 用 SSD + 连接池 |
| **表/分区管理** | CRUD 操作 | DDL 或 Thrift API | 分区数上限受元数据库限制（百万级） | 分区太多影响查询计划时间 |
| **统计信息** | 表/列统计 | `ANALYZE TABLE t COMPUTE STATISTICS FOR COLUMNS` | 统计信息不自动更新 | 定期 ANALYZE，CBO 才有效 |
| **Catalog 集成** | Spark/Flink/Trino 通过 HMS 读 Hive 表 | 配置 `hive.metastore.uris` | 不同引擎对 HMS API 版本兼容性不同 | 统一 HMS 版本 |

---

## 五、执行引擎

| 引擎 | 使用方式 | 适用场景 | 限制 | 注意 |
|------|---------|---------|------|------|
| **Tez** | `SET hive.execution.engine=tez` | 默认推荐 | 需要独立部署 Tez AM | 比 MR 快 2-10 倍 |
| **Spark** | `SET hive.execution.engine=spark` | Spark 生态 | Hive on Spark 兼容性不如原生 Spark SQL | 版本匹配问题多 |
| **MapReduce** | `SET hive.execution.engine=mr` | 兼容性最好 | 最慢（多次磁盘落地） | 已不推荐 |

---

## 六、安全能力

| 能力 | 使用方式 | 限制 | 注意 |
|------|---------|------|------|
| **Kerberos 认证** | `hive.server2.authentication=KERBEROS` | 需要 KDC | 和 HMS/HDFS 的认证要统一 |
| **LDAP 认证** | `hive.server2.authentication=LDAP` | 仅验证身份，不做授权 | 和 Ranger 配合做授权 |
| **列级权限** | Ranger 策略 | 需要 Ranger Plugin | Plugin 对 HS2 有轻微性能影响 |
| **数据脱敏** | Ranger Column Masking | 自动改写 SQL | 用户无感知 |
| **行级过滤** | Ranger Row Filter | 自动加 WHERE 条件 | 对 ACID 表无效的场景需测试 |

---

## 七、HiveServer2 (HS2)

| 能力 | 使用方式 | 限制 | 注意 |
|------|---------|------|------|
| **JDBC/ODBC** | `beeline -u "jdbc:hive2://host:10000"` | 单 HS2 并发连接数受限（默认 100） | 多 HS2 + ZK 服务发现做 HA |
| **HTTP 模式** | `hive.server2.transport.mode=http` | 经过 HTTP 代理（如 Knox） | 延迟略高于 binary 模式 |
| **多租户** | 不同用户走不同队列 | 通过 `hive.server2.tez.default.queues` 或 `mapreduce.job.queuename` | 需要配合队列 ACL | 设 `hive.server2.map.fair.scheduler.queue=true` |
| **连接池** | HS2 内部 Session 管理 | `hive.server2.session.check.interval` 清理空闲 | Session 泄漏会耗尽资源 | 设超时清理 |

---

## 八、功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 低延迟查询 (< 1s) | Trino / Presto / Impala |
| 实时流处理 | Flink |
| 单行级 CRUD（高并发） | HBase / RDBMS |
| 机器学习 | Spark MLlib |
| 交互式探索（秒级） | Trino + Hive Metastore |

---

## 九、关键参数速查

| 参数 | 默认 | 建议 | 说明 |
|------|------|------|------|
| `hive.execution.engine` | mr | **tez** | 执行引擎 |
| `hive.auto.convert.join` | true | true | 自动 MapJoin |
| `hive.auto.convert.join.noconditionaltask.size` | 25MB | 50-200MB | MapJoin 阈值 |
| `hive.exec.parallel` | false | **true** | 并行执行无依赖 Stage |
| `hive.exec.dynamic.partition.mode` | strict | nonstrict | 动态分区 |
| `hive.vectorized.execution.enabled` | true | true | 向量化执行 |
| `hive.cbo.enable` | true | true | 基于成本优化 |
| `hive.compactor.initiator.on` | false | **true** (ACID 表) | Compaction |
| `hive.tez.container.size` | -1 | 4096-8192 | Tez Container 大小 |
| `hive.server2.thrift.max.worker.threads` | 500 | 200-500 | HS2 最大工作线程 |

---

*Hive Expert | 功能地图 v1.0 | 2026-04-08*
