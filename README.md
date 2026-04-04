# 大数据源码学习 & 排障知识库

> **作者**: Kailong Liu | **AI 助手**: Eric
> **方法论**: [源码精通方法论 v2.0](./spark/源码/学习方法论.md) — 九大法则 + 四段位 + 90天路线图
> **技术手册总览**: [技术手册目录](./技术手册目录.md) — 12 个组件 + 50 条经验规则

---

## 目录结构

每个组件下设 `源码/`（源码深度分析）和 `案例/`（线上排障案例）。

| 组件 | 源码 | 案例 | 说明 |
|------|------|------|------|
| [spark/](./spark/) | ✅ 内存管理、Shuffle、调度、SQL/AQE、全局架构地图 | — | Spark 3.5.1 |
| [hive/](./hive/) | ✅ 基础、深度分析、源码地图、**S系列24篇深度场景文档** | ✅ HS2 Bug(7大类)、查询卡住(10场景)、堆外泄漏、查询结果错误 | Hive 2.3/3.x |
| [kyuubi/](./kyuubi/) | ✅ 源码分析 | ✅ 排障手册、诊断脚本、推荐配置 | Kyuubi |
| [yarn/](./yarn/) | ✅ 源码分析 | ✅ NM 堆外内存泄漏分析 | YARN |
| [hdfs/](./hdfs/) | ✅ 源码分析 | — | HDFS |
| [amoro/](./amoro/) | ✅ 源码分析 | — | Amoro |
| [flink/](./flink/) | ✅ 深度运维手册 | — | Flink |
| [iceberg/](./iceberg/) | ✅ 深度运维手册 | — | Iceberg |
| [zookeeper/](./zookeeper/) | ✅ 深度运维手册 | — | ZooKeeper |
| [tez/](./tez/) | — | — | 待补充 |
| [kerberos/](./kerberos/) | ✅ 原理与排障 | — | Kerberos |
| [ldap/](./ldap/) | ✅ 原理与排障 | — | LDAP |
| [ranger/](./ranger/) | ✅ 源码分析 | — | Ranger |
| [linux/](./linux/) | ✅ 操作系统运维手册 | — | Linux |
| [java-jvm/](./java-jvm/) | ✅ JVM 调优手册 | — | Java/JVM |
| [os-kernel/](./os-kernel/) | ✅ OS 内核调优手册 | — | OS Kernel |

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

#### Hive S 系列深度场景文档（源码级）
| 编号 | 主题 | 文档 |
|------|------|------|
| S01 | HS2 请求全链路源码分析 | [Part1](./hive/源码/S01-Part1-请求链路图与Thrift到编译.md) [Part2](./hive/源码/S01-Part2-语义分析到执行与故障点地图.md) [Part3](./hive/源码/S01-Part3-配置参数速查与排障决策树.md) |
| S02 | HS2 OOM 进程不退出端口不响应 | [分析](./hive/源码/S02-HS2-OOM进程不退出端口不响应.md) |
| S04 | HS2 查询结果正确性排障 | [Part1](./hive/源码/S04-Part1-HS2结果错误源码分析.md) [Part2](./hive/源码/S04-Part2-HS2结果不对排障实战手册.md) [Part3](./hive/源码/S04-Part3-Hive3x高危结果Bug索引.md) |
| S05 | Hive 查询卡住全场景分析 | [总览](./hive/源码/S05-Part0-Hive-Hang总览与风险矩阵.md) + [11篇](./hive/源码/) |
| S06 | MapJoin 回退 CommonJoin | [深度分析](./hive/源码/S06-MapJoin回退CommonJoin源码深度分析.md) |
| S07 | SQL Parser 词法语法解析 | [源码分析](./hive/源码/S07-SQL-Parser词法语法解析源码分析.md) |
| S08 | 语义分析 SemanticAnalyzer | [源码分析](./hive/源码/S08-语义分析SemanticAnalyzer源码分析.md) |
| S09 | CBO/RBO 优化器 | [源码分析](./hive/源码/S09-CBO-RBO优化器源码分析.md) |
| S10 | 物理计划生成与 Tez 执行 | [源码分析](./hive/源码/S10-物理计划生成与Tez执行源码分析.md) |

### Kyuubi
- [Kyuubi 排障手册](./kyuubi/案例/Kyuubi问题排查/分析报告.md)

### YARN
- [NM 堆外内存泄漏分析](./yarn/案例/NM堆外内存泄漏分析/分析报告.md)

### 基础设施
- [Linux 操作系统运维手册](./linux/Linux操作系统运维手册.md) — 大数据运维必精通
- [Java/JVM 调优手册](./java-jvm/Java-JVM调优手册.md) — 大数据组件运行时基石
- [OS 内核调优手册](./os-kernel/OS内核调优手册.md) — 操作系统层面深度调优
