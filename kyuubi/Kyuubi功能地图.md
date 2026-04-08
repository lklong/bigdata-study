# Kyuubi 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 一、核心能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **多租户 SQL 网关** | 为每个用户/组启动独立 Spark Engine | JDBC/ODBC/REST API 连接 | Engine 启动有延迟（首次 30-120s） | 用 Engine Pool 预热 |
| **Engine 管理** | 按 USER/GROUP/CONNECTION 级别隔离 | `kyuubi.engine.share.level=USER` | USER 级每个用户一个 Engine → 资源消耗大 | CONNECTION 级最隔离但最浪费 |
| **Engine Pool** | 预创建 Engine 池 | `kyuubi.engine.pool.size=5` | 池中 Engine 空闲也占资源 | 高并发场景必开 |
| **多引擎支持** | Spark / Flink / Trino / Hive / JDBC | `kyuubi.engine.type=SPARK_SQL` | 不同引擎功能差异大 | Spark 最成熟 |
| **SQL 审计** | 记录所有 SQL 执行 | 自动记录到事件日志 | 日志量大需要定期清理 | 合规场景必须 |
| **REST API** | HTTP 接口提交/查询 | `POST /api/v1/sessions` | 不支持流式结果返回 | 适合程序化调用 |
| **HA** | 多 Kyuubi Server + ZK 服务发现 | `kyuubi.ha.addresses=zk:2181` | 依赖 ZK 可用性 | 至少部署 2 个 Kyuubi Server |
| **认证** | Kerberos / LDAP / CUSTOM | `kyuubi.authentication=KERBEROS` | CUSTOM 需要自己实现 | 和下游引擎的认证要一致 |
| **授权** | Ranger / Spark AuthZ 插件 | `spark.sql.extensions=...AuthzExtension` | 仅 Spark 引擎支持 | 要配 Ranger Plugin |

---

## 二、功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 存储（不是数据库） | Hive Metastore / HDFS |
| 实时流处理 | 直接用 Flink |
| 低延迟点查 (< 1s) | Trino / Impala |

---

*Kyuubi Expert | 功能地图 v1.0 | 2026-04-08*
