# 大数据源码学习 & 排障知识库

> **作者**: Kailong Liu | **AI 助手**: Eric
> **方法论**: [源码精通方法论 v2.0 — 科学家级别](./spark/源码/00-学习方法论-v2.md)

---

## 目录结构

每个组件下设 `源码/`（源码深度分析）和 `案例/`（线上排障案例）两个子目录。

| 组件 | 源码分析 | 排障案例 | 说明 |
|------|---------|---------|------|
| [spark/](./spark/) | ✅ 内存管理、Shuffle、调度、SQL/Catalyst/AQE、全局架构地图 | — | Spark 3.5.1 |
| [hive/](./hive/) | — | ✅ HS2/HMS Bug 知识库(27+泄漏点)、Hang 分析(10场景)、堆外泄漏、自研修复 | Hive 2.3.x / 3.x |
| [kyuubi/](./kyuubi/) | — | ✅ 排障手册、诊断脚本、孤儿 Spark App 清理 | Kyuubi |
| [amoro/](./amoro/) | — | — | 待补充 |
| [hdfs/](./hdfs/) | — | — | 待补充 |
| [yarn/](./yarn/) | — | ✅ NM 堆外内存泄漏分析、Shuffle 泄漏检测 | YARN NM |
| [tez/](./tez/) | — | — | 待补充 |
| [kerberos/](./kerberos/) | — | — | 待补充 |
| [ldap/](./ldap/) | — | — | 待补充 |
| [ranger/](./ranger/) | — | — | 待补充 |

---

## 快速导航

### Spark
- [全局架构地图](./spark/源码/05-全局架构地图.md) — 核心类速查 + SQL 流水线 + Shuffle + 调度
- [内存管理源码分析](./spark/源码/01-memory-management.md) — UnifiedMemoryManager 逐行分析
- [Shuffle 源码分析](./spark/源码/02-shuffle.md) — 三路写入 + 读取流控
- [调度系统源码分析](./spark/源码/03-scheduler.md) — DAGScheduler + TaskSchedulerImpl
- [SQL/Catalyst/AQE](./spark/源码/04-sql-catalyst-aqe.md) — QueryExecution 完整链路

### Hive
- [HS2/HMS Bug 知识库总览](./hive/案例/00-summary.md) — 6 大类 50+ Bug
- [堆外内存泄漏 27 个点](./hive/案例/01-offheap-memory-leak.md)
- [Hive Hang 全面分析](./hive/案例/hive-hang-analysis/00-overview.md) — 10 大卡住场景
- [自研修复方案](./hive/案例/08-self-developed-fixes.md) — Top 3 P0 Bug

### YARN
- [NM 堆外内存泄漏分析](./yarn/案例/report/full-analysis-report.md)

### Kyuubi
- [Kyuubi 排障手册](./kyuubi/案例/README.md)
