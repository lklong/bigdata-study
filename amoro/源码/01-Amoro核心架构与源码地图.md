# Amoro 核心架构与源码地图

> 基于本地源码 `/Users/kailongliu/bigdata/gitProjects/amoro/` 分析
> Eric | 2026-04-25

---

## 一、模块全景

```
amoro/
├── amoro-ams/              ← AMS（核心管理服务）：调度、表管理、Web Dashboard
├── amoro-common/           ← 通用模块：接口、配置、客户端、异常
├── amoro-format-iceberg/   ← Iceberg 格式集成：读写、优化、MixedTable
├── amoro-format-mixed/     ← Mixed 格式：mixed-flink/mixed-hive/mixed-spark/mixed-trino
├── amoro-format-hudi/      ← Hudi 格式集成
├── amoro-format-paimon/    ← Paimon 格式集成
├── amoro-optimizer/        ← Optimizer 执行器
│   ├── amoro-optimizer-common/     ← 通用 Optimizer 逻辑
│   ├── amoro-optimizer-standalone/ ← 独立进程 Optimizer
│   ├── amoro-optimizer-flink/      ← Flink Optimizer
│   └── amoro-optimizer-spark/      ← Spark Optimizer
├── amoro-metrics/          ← 指标系统（Prometheus）
├── amoro-web/              ← 前端 Web UI
└── dist/ docker/ charts/   ← 部署相关
```

---

## 二、核心架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    AMS (AmoroServiceContainer)               │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │CatalogManager│  │ TableService │  │OptimizingService │   │
│  │(DefaultCatalog│  │(DefaultTable │  │(DefaultOptimizing│   │
│  │  Manager)    │  │  Service)    │  │  Service)        │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬──────────┘   │
│         │                 │                  │              │
│  ┌──────▼──────┐  ┌──────▼───────┐  ┌──────▼──────────┐   │
│  │ServerCatalog│  │ TableRuntime │  │OptimizingQueue   │   │
│  │ Internal/   │  │ (表运行时状态│  │ (优化任务队列,  │   │
│  │ External    │  │  锁+快照+配置)│  │  按group分组)   │   │
│  └─────────────┘  └──────────────┘  └──────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           AsyncTableExecutors (后台执行器)             │   │
│  │  DataExpiring | SnapshotExpiring | OrphanCleaning     │   │
│  │  OptimizingCommit | TableRefresh | TagsAutoCreate     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────┐  ┌────────────────┐                        │
│  │ Thrift RPC  │  │  HTTP (Javalin)│  ← Dashboard + REST   │
│  └─────────────┘  └────────────────┘                        │
└─────────────────────────────────────────────────────────────┘
          ▲                    ▲
          │ pollTask/ackTask   │ Web UI
          │ completeTask       │
┌─────────┴────────┐  ┌───────┴──────┐
│   Optimizer 集群  │  │   用户浏览器  │
│  (Standalone/    │  └──────────────┘
│   Flink/Spark)   │
└──────────────────┘
```

---

## 三、关键类索引

### 3.1 AMS 主入口

| 类 | 路径 | 说明 |
|----|------|------|
| **AmoroServiceContainer** | `amoro-ams/.../server/AmoroServiceContainer.java` | **AMS 主入口**，main()。初始化 CatalogManager/TableService/OptimizingService，启动 Thrift + HTTP |
| **HighAvailabilityContainer** | `amoro-ams/.../server/HighAvailabilityContainer.java` | HA 容器，Leader/Follower 切换 |
| **AmoroManagementConf** | `amoro-ams/.../server/AmoroManagementConf.java` | AMS 全部配置项 |
| **DashboardServer** | `amoro-ams/.../server/dashboard/DashboardServer.java` | Web Dashboard HTTP 服务 |

### 3.2 表服务

| 类 | 路径 | 说明 |
|----|------|------|
| **TableService** (接口) | `amoro-ams/.../server/table/TableService.java` | 表服务：initialize/onTableCreated/getRuntime |
| **DefaultTableService** | `amoro-ams/.../server/table/DefaultTableService.java` | 实现：维护 `tableRuntimeMap`，定期刷新 |
| **TableRuntime** | `amoro-ams/.../server/table/TableRuntime.java` | **核心**：表运行时状态（snapshotId/optimizingStatus/config），ReentrantLock 保证线程安全 |
| **RuntimeHandlerChain** | `amoro-ams/.../server/table/RuntimeHandlerChain.java` | 表事件处理链基类 |
| **TableManager** | `amoro-ams/.../server/table/TableManager.java` | 聚合接口（MaintainedTableManager + InternalTableManager + BlockerManager） |
| **TableManagementService** | `amoro-ams/.../server/TableManagementService.java` | Thrift 接口实现，对外提供 CRUD |

### 3.3 Catalog 管理

| 类 | 路径 | 说明 |
|----|------|------|
| **CatalogManager** (接口) | `amoro-ams/.../server/catalog/CatalogManager.java` | Catalog CRUD |
| **DefaultCatalogManager** | `amoro-ams/.../server/catalog/DefaultCatalogManager.java` | 实现 |
| **InternalCatalog** | `amoro-ams/.../server/catalog/InternalCatalog.java` | AMS 管理的 Catalog |
| **ExternalCatalog** | `amoro-ams/.../server/catalog/ExternalCatalog.java` | 外部 Catalog |
| **RestCatalogService** | `amoro-ams/.../server/RestCatalogService.java` | Iceberg REST Catalog 协议实现 |

### 3.4 优化调度（Self-Optimizing 核心）

| 类 | 路径 | 说明 |
|----|------|------|
| **DefaultOptimizingService** | `amoro-ams/.../server/DefaultOptimizingService.java` | **核心调度**：管理 OptimizingQueue，处理 optimizer 注册/pollTask/ackTask/completeTask |
| **OptimizingQueue** | `amoro-ams/.../server/optimizing/OptimizingQueue.java` (761行) | **优化队列**：按 optimizer group 分组，调度表的优化任务。包含 plan/schedule/commit 全流程 |
| **TaskRuntime** | `amoro-ams/.../server/optimizing/TaskRuntime.java` | 任务运行时：状态机 PLANNED→SCHEDULED→ACKED→SUCCESS/FAILED |
| **OptimizingProcess** | `amoro-ams/.../server/optimizing/OptimizingProcess.java` | 优化过程接口 |
| **OptimizingStatus** | `amoro-ams/.../server/optimizing/OptimizingStatus.java` | 表优化状态枚举 |
| **OptimizerGroupMetrics** | `amoro-ams/.../server/optimizing/OptimizerGroupMetrics.java` | Optimizer Group 指标 |

### 3.5 优化规划（Planner — amoro-format-iceberg）

| 类 | 路径 | 说明 |
|----|------|------|
| **AbstractOptimizingEvaluator** | `amoro-format-iceberg/.../plan/AbstractOptimizingEvaluator.java` | 评估器基类：扫描文件，判断哪些分区需要优化 |
| **AbstractOptimizingPlanner** | `amoro-format-iceberg/.../plan/AbstractOptimizingPlanner.java` | 规划器基类：基于评估结果，生成 RewriteStageTask 列表 |
| **AbstractPartitionPlan** | `amoro-format-iceberg/.../plan/AbstractPartitionPlan.java` | 分区级优化计划 |
| **CommonPartitionEvaluator** | `amoro-format-iceberg/.../plan/CommonPartitionEvaluator.java` (19KB) | **核心评估逻辑**：判断 Minor/Major/Full 优化类型 |
| **IcebergOptimizingPlanner** | `amoro-format-iceberg/.../plan/IcebergOptimizingPlanner.java` | Iceberg 表规划器 |
| **IcebergPartitionPlan** | `amoro-format-iceberg/.../plan/IcebergPartitionPlan.java` | Iceberg 分区计划 |
| **MixedIcebergOptimizingPlanner** | `amoro-format-iceberg/.../plan/MixedIcebergOptimizingPlanner.java` | Mixed-Iceberg 规划器 |

### 3.6 优化执行（Executor）

| 类 | 路径 | 说明 |
|----|------|------|
| **Optimizer** | `amoro-optimizer/common/.../Optimizer.java` | Optimizer 主进程 |
| **OptimizerExecutor** | `amoro-optimizer/common/.../OptimizerExecutor.java` | 执行线程：pollTask→ackTask→execute→completeTask |
| **OptimizerToucher** | `amoro-optimizer/common/.../OptimizerToucher.java` | 心跳保活线程 |
| **StandaloneOptimizer** | `amoro-optimizer/standalone/.../StandaloneOptimizer.java` | 独立进程 Optimizer |
| **AbstractRewriteFilesExecutor** | `amoro-format-iceberg/.../AbstractRewriteFilesExecutor.java` | 文件重写基类 |
| **IcebergRewriteExecutor** | `amoro-format-iceberg/.../IcebergRewriteExecutor.java` | Iceberg 格式重写 |
| **RewriteFilesInput** | `amoro-format-iceberg/.../RewriteFilesInput.java` | 重写任务输入 |
| **RewriteFilesOutput** | `amoro-format-iceberg/.../RewriteFilesOutput.java` | 重写任务输出 |

### 3.7 后台异步执行器

| 类 | 路径 | 说明 |
|----|------|------|
| **AsyncTableExecutors** | `amoro-ams/.../executor/AsyncTableExecutors.java` | 管理所有后台执行器 |
| DataExpiringExecutor | 数据过期清理 |
| SnapshotsExpiringExecutor | 快照过期清理 |
| OrphanFilesCleaningExecutor | 孤立文件清理 |
| DanglingDeleteFilesCleaningExecutor | 悬挂删除文件清理 |
| OptimizingCommitExecutor | 优化结果提交 |
| TableRuntimeRefreshExecutor | 表运行时刷新 |
| TagsAutoCreatingExecutor | 自动创建 Tag |
| HiveCommitSyncExecutor | Hive 提交同步 |

---

## 四、核心流程

### 4.1 Self-Optimizing 完整流程

```
1. TableRuntimeRefreshExecutor 定期刷新表状态
   └── TableRuntime 检测到 snapshot 变更

2. OptimizingQueue.planInternal()
   ├── AbstractOptimizingEvaluator.initEvaluator()
   │   └── 扫描所有文件，按分区评估
   ├── CommonPartitionEvaluator 判断优化类型
   │   ├── MINOR: 小文件合并（fragment file count > threshold）
   │   ├── MAJOR: 删除文件清理（delete ratio > threshold）
   │   └── FULL: 全量重写（file size 严重偏离 target）
   └── AbstractOptimizingPlanner.planTasks()
       └── 生成 RewriteStageTask 列表

3. Optimizer 执行
   ├── OptimizerExecutor.pollTask()   → Thrift RPC → AMS
   ├── OptimizerExecutor.ackTask()    → 确认接收
   ├── OptimizerExecutor.executeTask()
   │   └── IcebergRewriteExecutor.execute()
   │       ├── 读旧文件 (dataReader)
   │       ├── 写新文件 (dataWriter)
   │       └── 写删除文件 (posWriter) [如果需要]
   └── OptimizerExecutor.completeTask() → 上报结果

4. OptimizingCommitExecutor 提交
   ├── UnKeyedTableCommit / KeyedTableCommit
   └── 更新 TableRuntime 状态
```

### 4.2 Optimizer 注册与心跳

```
Optimizer 启动
  → register(OptimizerRegisterInfo) via Thrift
     → DefaultOptimizingService.authenticate()
     → 分配 token
  → OptimizerToucher 定期 touch(token)
     → AMS 更新 lastTouchTime
     → 超时未 touch → 标记为 expired → 重新分配任务
```

### 4.3 任务状态机

```
PLANNED → SCHEDULED → ACKED → SUCCESS
                  ↘           ↗
                   → FAILED → PLANNED (retry)
                   → CANCELED
```

---

## 五、关键配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `self-optimizing.enabled` | true | 是否启用自动优化 |
| `self-optimizing.group` | default | Optimizer Group 名称 |
| `self-optimizing.target-size` | 134217728 (128MB) | 目标文件大小 |
| `self-optimizing.max-file-count` | - | 单次优化最大文件数 |
| `self-optimizing.fragment-ratio` | 8 | 小文件判定比例（target-size/ratio） |
| `self-optimizing.minor.trigger.file-count` | 12 | Minor 优化触发文件数阈值 |
| `self-optimizing.major.trigger.duplicate-ratio` | 0.1 | Major 优化触发删除比 |
| `self-optimizing.full.trigger.interval` | -1 (disabled) | Full 优化触发间隔 |

---

*Amoro Source Map v1.0 | Eric | 2026-04-25*
