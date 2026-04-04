# 大数据源码学习 & 排障知识库

> **作者**: Kailong Liu | **AI 助手**: Eric
> **方法论**: [源码精通方法论 v2.0](./spark/源码/学习方法论.md) — 九大法则 + 四段位 + 90天路线图

---

## 目录结构

每个组件下设 `源码/`（源码深度分析）和 `案例/`（线上排障案例）。

| 组件 | 源码 | 案例 | 说明 |
|------|------|------|------|
| [spark/](./spark/) | ✅ 内存管理、Shuffle、调度、SQL/AQE、全局架构地图 | — | Spark 3.5.1 |
| [hive/](./hive/) | ✅ 基础、深度分析、源码地图 | ✅ HS2 Bug(7大类)、查询卡住(10场景)、堆外泄漏、查询结果错误 | Hive 2.3/3.x |
| [kyuubi/](./kyuubi/) | ✅ 源码分析 | ✅ 排障手册、诊断脚本、推荐配置 | Kyuubi |
| [yarn/](./yarn/) | ✅ 源码分析 | ✅ NM 堆外内存泄漏分析 | YARN |
| [hdfs/](./hdfs/) | ✅ 源码分析 | — | HDFS |
| [amoro/](./amoro/) | ✅ 源码分析 | — | Amoro |
| [tez/](./tez/) | — | — | 待补充 |
| [kerberos/](./kerberos/) | ✅ 原理与排障 | — | Kerberos |
| [ldap/](./ldap/) | ✅ 原理与排障 | — | LDAP |
| [ranger/](./ranger/) | ✅ 源码分析 | — | Ranger |

---

## 快速导航

### Spark
- [全局架构地图](./spark/源码/05-全局架构地图.md) — 核心类 + SQL 流水线 + Shuffle + 调度
- [内存管理](./spark/源码/01-内存管理.md) — UnifiedMemoryManager 逐行分析
- [Shuffle 机制](./spark/源码/02-Shuffle机制.md) — 三路写入 + 读取流控
- [调度系统](./spark/源码/03-调度系统.md) — DAGScheduler + TaskSchedulerImpl
- [SQL 引擎与 AQE](./spark/源码/04-SQL引擎与AQE.md) — QueryExecution 完整链路

### Hive
- [HS2 堆外内存泄漏](./hive/案例/HS2堆外内存泄漏分析/分析报告.md) — 27 个泄漏点 + 修复补丁
- [Hive 查询卡住全面分析](./hive/案例/Hive查询卡住分析/分析报告.md) — 10 大卡住场景
- [HS2 死锁与锁竞争](./hive/案例/HS2死锁与锁竞争/分析报告.md)
- [HS2 查询结果不对](./hive/案例/HS2查询结果不对排障/分析报告.md)

### Kyuubi
- [Kyuubi 排障手册](./kyuubi/案例/Kyuubi问题排查/分析报告.md)

### YARN
- [NM 堆外内存泄漏分析](./yarn/案例/NM堆外内存泄漏分析/分析报告.md)
