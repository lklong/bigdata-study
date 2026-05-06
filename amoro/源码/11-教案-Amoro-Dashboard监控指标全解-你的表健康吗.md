# 教案 02：Amoro Dashboard 监控指标全解 — 你的表健康吗？

> **适用对象**：大数据运维/平台工程师 | **前置知识**：了解 Amoro AMS 基础架构  
> **课时**：40 分钟 | **难度**：⭐⭐⭐

---

## 一、课前导入 — 你的表在偷偷生病

> 想象你是一个学校的校医。学校有 500 个学生（= 500 张表），你需要每天巡查所有人的健康状况。有些学生发烧了（优化任务积压），有些学生营养不良（小文件堆积），有些学生受伤了（任务失败）。
>
> 如果没有体温计和健康档案，你只能等学生倒下才知道他病了。**Amoro Dashboard 就是你的体温计 + 健康档案 + 预警系统。**

---

## 二、本课目标

1. **Dashboard 背后是什么在运转？** 数据从哪来、怎么算、怎么展示？
2. **30+ 个监控指标分别表示什么？** 哪些指标最关键，必须盯住？
3. **如何用指标判断一张表是否健康？** 给出诊断清单和阈值建议。

---

## 三、核心概念 — 体检报告

### 3.1 三层指标体系

Amoro 的监控指标分为三层，就像体检报告的三个章节：

| 层级 | 类比 | 内容 | 核心类 |
|------|------|------|--------|
| **全局总览** | 学校整体报告 | 总表数、总存储、Catalog数、CPU/内存使用 | `OverviewManager` |
| **Optimizer 组** | 班级报告 | 每个资源组的任务数、表状态分布、实例数 | `OptimizerGroupMetrics` |
| **单表** | 学生个人报告 | 优化状态持续时间、进程成功/失败数、数据文件统计 | `TableOptimizingMetrics` |

### 3.2 架构图

```
┌──────────────────────────────────────────┐
│            DashboardServer               │
│   (Javalin REST API, /api/ams/v1)        │
├──────────────────────────────────────────┤
│  OverviewController  TableController     │
│  OptimizerController OptimizerGroupCtrl  │
├──────────┬───────────┬───────────────────┤
│          │           │                   │
│  OverviewManager  MetricRegistry  TableRuntime
│  (定时刷新统计)  (全局指标注册中心) (单表运行时)
│          │           │                   │
│          ▼           ▼                   ▼
│  ┌──────────┐ ┌────────────┐ ┌──────────────────┐
│  │ DB查询    │ │ Gauge/Counter│ │ TableOptimizing   │
│  │ (MyBatis) │ │ (内存计算)   │ │ Metrics           │
│  └──────────┘ └────────────┘ └──────────────────┘
└──────────────────────────────────────────┘
```

---

## 四、源码精讲

### 4.1 全局总览 — OverviewManager

> 源码：`amoro-ams/.../server/dashboard/OverviewManager.java`

```java
public class OverviewManager extends PersistentBase {
  // 学校的整体统计数据
  private final AtomicInteger totalCatalog = new AtomicInteger();     // 几个年级（Catalog）
  private final AtomicLong totalDataSize = new AtomicLong();          // 学校总藏书量（数据量）
  private final AtomicInteger totalTableCount = new AtomicInteger();  // 学生总数（表数量）
  private final AtomicInteger totalCpu = new AtomicInteger();         // 学校总师资（CPU）
  private final AtomicLong totalMemory = new AtomicLong();            // 学校总校舍（内存）

  // 历史趋势（环形队列，最多保留 maxRecordCount 条）
  private final ConcurrentLinkedDeque<OverviewResourceUsageItem> resourceUsageHistory;
  private final ConcurrentLinkedDeque<OverviewDataSizeItem> dataSizeHistory;

  // 优化状态分布（5 种状态各有多少张表）
  private final Map<String, Long> optimizingStatusCountMap;
  // 资源消耗 Top 表
  private final List<OverviewTopTableItem> allTopTableItem;
}
```

**老师画重点**：
- `OverviewManager` 用**定时线程**（`ScheduledExecutorService`）周期性刷新统计，不是每次 API 调用都去查数据库
- 刷新间隔由 `AmoroManagementConf.OVERVIEW_CACHE_REFRESH_INTERVAL` 控制
- 这意味着 Dashboard 看到的数据有一定延迟 — 这是正常的

### 4.2 Optimizer 组级指标

> 源码：`amoro-ams/.../server/optimizing/OptimizerGroupMetrics.java`

```java
// 每个资源组（班级）的健康指标
public class OptimizerGroupMetrics {
  // 任务维度
  static MetricDefine OPTIMIZER_GROUP_PENDING_TASKS;      // 排队中的任务数
  static MetricDefine OPTIMIZER_GROUP_EXECUTING_TASKS;     // 执行中的任务数

  // 表维度（按状态分）
  static MetricDefine OPTIMIZER_GROUP_PLANING_TABLES;      // 正在规划的表数
  static MetricDefine OPTIMIZER_GROUP_PENDING_TABLES;      // 等待资源的表数
  static MetricDefine OPTIMIZER_GROUP_EXECUTING_TABLES;    // 正在执行的表数
  static MetricDefine OPTIMIZER_GROUP_IDLE_TABLES;         // 空闲的表数
  static MetricDefine OPTIMIZER_GROUP_COMMITTING_TABLES;   // 正在提交的表数

  // 资源维度
  static MetricDefine OPTIMIZER_GROUP_OPTIMIZER_INSTANCES;  // Optimizer 实例数
  static MetricDefine OPTIMIZER_GROUP_MEMORY_BYTES_ALLOCATED; // 分配的内存
}
```

**直觉判断**：
- `pending_tasks` 持续增长 → **Optimizer 资源不足**，需要扩容
- `pending_tables` 远多于 `executing_tables` → **调度瓶颈**，表太多资源不够分
- `optimizer_instances = 0` → **Optimizer 全挂了**，紧急排查

### 4.3 单表级指标

> 源码：`amoro-ams/.../server/table/TableOptimizingMetrics.java`

```java
public class TableOptimizingMetrics {
  // 5 种状态的持续时间（毫秒）— 这是最关键的健康指标
  static MetricDefine TABLE_OPTIMIZING_STATUS_IDLE_DURATION;       // 空闲多久了
  static MetricDefine TABLE_OPTIMIZING_STATUS_PENDING_DURATION;    // 等了多久了
  static MetricDefine TABLE_OPTIMIZING_STATUS_PLANNING_DURATION;   // 规划了多久
  static MetricDefine TABLE_OPTIMIZING_STATUS_EXECUTING_DURATION;  // 执行了多久
  static MetricDefine TABLE_OPTIMIZING_STATUS_COMMITTING_DURATION; // 提交了多久

  // 优化进程计数
  static MetricDefine TABLE_OPTIMIZING_PROCESS_TOTAL_COUNT;   // 总共跑了几次
  static MetricDefine TABLE_OPTIMIZING_PROCESS_FAILED_COUNT;  // 失败了几次
}
```

**老师的诊断手册**：

| 症状 | 可能原因 | 处方 |
|------|---------|------|
| `pending_duration > 30min` | Optimizer 资源不足或配额耗尽 | 增加 Optimizer 实例或调整配额 |
| `executing_duration > 2h` | 表太大或 Minor Optimize 变成了 Major | 检查 `target-size`，拆分过大分区 |
| `committing_duration > 10min` | Catalog 慢（如 HMS 锁竞争） | 检查 HMS/Catalog 性能 |
| `failed_count / total_count > 10%` | 存在持续性错误 | 看 AMS 日志定位具体异常 |
| 长期 `IDLE` 但小文件堆积 | 触发阈值未达到 | 降低 `minor.trigger.file-count` |

---

## 五、MetricRegistry — 指标怎么注册和上报

### 5.1 注册流程

```
TableRuntime 创建时
    │
    ▼
new TableOptimizingMetrics(tableId, metricRegistry)
    │
    ▼
metricRegistry.register(TABLE_OPTIMIZING_STATUS_IDLE_DURATION,
    ImmutableMap.of("catalog", "hive", "database", "ods", "table", "orders"),
    (Gauge<Long>) () -> idleDurationMs)
    │
    ▼
MetricReporter（Prometheus/JMX/自定义）自动拉取
```

### 5.2 与 Prometheus + Grafana 集成

Amoro 支持通过 SPI 机制加载 `MetricReporter` 插件：

```yaml
# amoro 配置
metric-reporters:
  - name: prometheus
    class: org.apache.amoro.server.metrics.PrometheusReporter
    properties:
      port: 9090
```

然后在 Grafana 中配置 Prometheus 数据源，就能看到所有指标的实时图表。

---

## 六、课堂练习

### 思考题 1：设计告警规则

> 你管理着 200 张 Iceberg 表。请基于上面学到的指标，设计 3 条最重要的告警规则（写出指标名、阈值、告警级别、处理建议）。

<details>
<summary>参考答案</summary>

| 告警 | 指标 | 阈值 | 级别 | 处理 |
|------|------|------|------|------|
| Optimizer 全挂 | `optimizer_group_optimizer_instances` | = 0 持续 5min | P0 紧急 | 重启 Optimizer 容器 |
| 表卡在 Pending | `table_optimizing_status_pending_duration_mills` | > 1800000 (30min) | P1 重要 | 检查资源组配额和队列 |
| 优化失败率高 | `failed_count / total_count` | > 0.2 持续 1h | P2 一般 | 查 AMS 日志定位异常 |

</details>

### 思考题 2：OverviewManager 的刷新延迟

> `OverviewManager` 使用定时刷新而非实时查询。**问：如果刷新间隔设为 1 分钟，在什么场景下可能导致问题？如何平衡实时性和性能？**

<details>
<summary>参考答案</summary>

- **问题场景**：Optimizer 突然全部下线，但 Dashboard 还显示"一切正常"，运维人员被误导
- **平衡方案**：
  1. 普通统计（表数量、存储量）—— 分钟级刷新足够
  2. 关键状态（Optimizer 在线数）—— 应该用实时查询或更短的刷新间隔
  3. 告警系统不应该依赖 Dashboard 刷新 —— 应该用 Prometheus 指标直接触发

</details>

### 思考题 3：跨组件联动

> 你发现某张表的 `executing_duration` 突然从平时的 5 分钟变成了 2 小时。**问：除了看 Amoro 指标，你还应该去看哪些组件的什么指标来定位根因？**

<details>
<summary>参考答案</summary>

1. **Iceberg 层**：检查表的 manifest 数量（Planning 变慢？）和数据文件大小分布
2. **计算引擎层**：Spark/Flink UI 看 Optimizer 的 Task 是否有 shuffle spill、GC 暂停
3. **存储层**：HDFS/S3 的 IO 延迟和吞吐量是否异常
4. **HMS/Catalog 层**：如果是 committing 阶段慢，看 HMS 的锁等待时间
5. **OS 层**：Optimizer 节点的 CPU/内存/磁盘 IO 是否打满

</details>

---

## 七、知识晶体卡片

```
┌─────────────────────────────────────────────────┐
│  Amoro Dashboard 监控指标体系                      │
├─────────────────────────────────────────────────┤
│  三层结构:                                        │
│  L1 全局: OverviewManager (定时刷新)               │
│  L2 组级: OptimizerGroupMetrics (9个核心指标)      │
│  L3 表级: TableOptimizingMetrics (7个核心指标)     │
├─────────────────────────────────────────────────┤
│  必盯指标 TOP 3:                                  │
│  1. optimizer_group_optimizer_instances (≠0)      │
│  2. table_optimizing_status_pending_duration      │
│  3. table_optimizing_process_failed_count         │
├─────────────────────────────────────────────────┤
│  数据流: TableRuntime → MetricRegistry            │
│        → MetricReporter → Prometheus → Grafana    │
├─────────────────────────────────────────────────┤
│  DashboardServer: Javalin REST API               │
│  路径前缀: /api/ams/v1                            │
│  认证: Basic Auth (admin/password)                │
└─────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Amoro 源码 amoro-ams/ | 最后更新：2026-04-27*
