# Iceberg + Amoro 运维全景图：核心概念关联与知识体系总结

> Eric | 2026-04-27

---

## 一、知识体系全景

```
┌────────────────────────────────────────────────────────────────────┐
│                    数据湖表格式 + 湖仓管理                          │
│                                                                    │
│  ┌─────────────────────────────────┐  ┌──────────────────────────┐ │
│  │         Apache Iceberg          │  │        Amoro (AMS)       │ │
│  │     (表格式 + 事务 + 元数据)     │  │   (自动治理 + 调度管理)    │ │
│  │                                 │  │                          │ │
│  │  核心层:                        │  │  核心层:                  │ │
│  │  ├─ TableMetadata (元数据)      │  │  ├─ CatalogManager       │ │
│  │  ├─ Snapshot (版本)             │  │  ├─ TableService         │ │
│  │  ├─ Manifest (文件清单)         │  │  ├─ TableRuntime (状态机) │ │
│  │  └─ DataFile/DeleteFile (数据)  │  │  └─ OptimizingQueue      │ │
│  │                                 │  │                          │ │
│  │  演进层:                        │  │  执行层:                  │ │
│  │  ├─ Schema Evolution            │  │  ├─ Optimizer (执行器)   │ │
│  │  ├─ Partition Evolution         │  │  ├─ TableMaintainer      │ │
│  │  └─ Hidden Partitioning         │  │  └─ AsyncTableExecutors  │ │
│  │                                 │  │                          │ │
│  │  操作层:                        │  │  扩展层:                  │ │
│  │  ├─ Write Path (写入)           │  │  ├─ Mixed-Iceberg 格式   │ │
│  │  ├─ Scan Planning (读取)        │  │  ├─ REST Catalog 协议    │ │
│  │  ├─ V2 Row-Level Delete         │  │  └─ Prometheus 指标      │ │
│  │  └─ Maintenance Actions         │  │                          │ │
│  │      (Rewrite/Expire/Orphan)    │  │                          │ │
│  └─────────────────────────────────┘  └──────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

---

## 二、核心概念关联图

```
Iceberg 三层元数据:
  Catalog → metadata.json → manifest-list → manifest → data files

Amoro 管理层:
  CatalogManager → ServerCatalog → TableService → TableRuntime

两者的连接点:
  Amoro InternalCatalogImpl 实现了 Iceberg REST Catalog 协议
  Amoro TableMaintainer 调用 Iceberg 的 Maintenance Actions
  Amoro Optimizer 使用 Iceberg 的 RewriteFiles API 提交

完整链路:
  写入(Spark/Flink) → Iceberg Table → Snapshot 变化
    → Amoro TableRuntime.refresh() 检测变化
    → OptimizingQueue 调度
    → Optimizer 执行 (读取旧文件 + 合并 + 写新文件)
    → Iceberg RewriteFiles commit
    → TableMaintainer 清理 (expire + orphan clean)
```

---

## 三、已完成学习成果索引

### Iceberg 源码分析（9 篇）

| # | 文档 | 核心知识点 |
|---|------|-----------|
| 01 | 核心架构与源码地图 | 模块全景、三层元数据、项目结构 |
| 02 | TableMetadata/Snapshot/Commit | 元数据字段、Snapshot 链、OCC 提交 |
| 03 | ScanPlanning 与 Manifest 过滤 | 查询入口链路、ManifestGroup、谓词下推 |
| 04 | RewriteDataFiles/ExpireSnapshots | 小文件合并、快照过期、孤立文件清理 |
| 05 | PartitionSpec Evolution | Hidden Partitioning、Transform、零成本演进 |
| 06 | V2 行级删除 | Equality/Position Delete、RowDelta、MoR |
| 07 | Schema Evolution | Column ID、类型提升、unionByNameWith |
| 08 | Catalog 体系 | HiveCatalog/HadoopCatalog/RESTCatalog 对比 |
| 09 | Write Path | DataWriter/TaskWriter/OutputFileFactory/文件命名 |

### Amoro 源码分析（8 篇）

| # | 文档 | 核心知识点 |
|---|------|-----------|
| 01 | 核心架构与源码地图 | 模块全景、AMS/Optimizer/Format 三大核心 |
| 02 | SelfOptimizing 调度核心 | TableRuntimeRefreshExecutor → OptimizingQueue 链路 |
| 03 | Optimizer 执行与提交 | OptimizerToucher/OptimizerExecutor、RewriteFiles 提交 |
| 04 | AMS Server 表管理与 Catalog | CatalogManager/TableService/Internal-External Catalog |
| 05 | Mixed-Iceberg BaseTable 与 ChangeTable | 双表模型、CDC 写入、MoR、Minor/Major |
| 06 | IcebergTableMaintainer | 6 大 Executor、快照保护、孤立文件、数据 TTL |
| 07 | OptimizingQueue 调度策略 | SchedulingPolicy SPI、QuotaOccupy/Balanced、配额 |
| 08 | TableRuntime 状态机 | 7 种状态、状态流转、OptimizingProcess/TaskRuntime |

### 实战案例（4 篇）

| # | 文档 | 场景 |
|---|------|------|
| 1 | Amoro 自优化调度与 Compaction 实战 | Self-Optimizing 两级优化 |
| 2 | Iceberg 小文件治理实战 | 200 万小文件诊断 + 治理 |
| 3 | Amoro 管理 Iceberg 表完整生命周期 | 建表→写入→自动优化→监控→故障 |
| 4 | Spark Streaming 写入 Iceberg 调优 | 写入侧/维护侧/读取侧全面优化 |
| 5 | Self-Optimizing 参数调优与故障排查 | 4 场景配方 + 3 故障决策树 + 告警模板 |

### 其他文档

| 文档 | 类型 |
|------|------|
| Amoro 功能地图 | 能力清单 |
| Amoro 故障排查决策树 | 排障指南 |
| Iceberg 功能地图 | 能力清单 |
| Iceberg 故障排查决策树 | 排障指南 |

---

## 四、核心设计模式总览

| 设计模式 | Iceberg 中的应用 | Amoro 中的应用 |
|---------|-----------------|---------------|
| **Column ID** | Schema 按 ID 映射 | — |
| **Sequence Number** | Delete File 版本控制 | — |
| **Copy-on-Write** | metadata.json 不可变 | — |
| **Merge-on-Read** | V2 Delete + Data 合并 | Mixed-Iceberg BaseTable + ChangeTable |
| **工厂模式** | Transforms/Catalog | CatalogBuilder |
| **Builder 模式** | PartitionSpec.Builder | — |
| **责任链** | — | RuntimeHandlerChain |
| **SPI 扩展** | FileIO/Catalog | SchedulingPolicy/SorterFactory |
| **观察者/事件** | — | fireTableAdded/fireStatusChanged |
| **乐观并发** | OCC Commit (CAS) | — |
| **状态机** | — | OptimizingStatus 7 状态 |

---

## 五、关键运维数字

| 指标 | 健康值 | 告警值 | 危险值 |
|------|--------|--------|--------|
| 平均文件大小 | 100-256MB | 32-100MB | < 32MB |
| 数据文件数/分区 | < 50 | 50-200 | > 200 |
| Delete File 数 | < 10 | 10-50 | > 50 |
| 快照数 | < 100 | 100-500 | > 500 |
| Manifest 数 | < 200 | 200-1000 | > 1000 |
| 查询 Planning 时间 | < 1s | 1-10s | > 10s |
| PENDING 持续时间 | < 10min | 10-60min | > 60min |
| quotaOccupy | < 0.8 | 0.8-1.0 | > 1.0 |

---

## 六、下一步学习方向

```
已完成:
  ✅ Iceberg 核心原理（9 篇源码）
  ✅ Amoro 核心原理（8 篇源码）
  ✅ 实战案例（5 篇）
  ✅ 功能地图 + 故障决策树

可深入方向:
  → Iceberg V3 格式新特性（Multi-Arg Transform 等）
  → Flink + Iceberg 流式写入源码
  → Amoro Dashboard 前后端交互
  → Amoro + Kerberos 安全集成
  → Iceberg REST Catalog 协议深度解读
  → Amoro 多租户与资源隔离
  → Iceberg 与 Hudi/Paimon/Delta Lake 横向对比
```
