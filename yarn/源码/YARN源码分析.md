# YARN — 资源调度引擎

---

## 一、概述

YARN（Yet Another Resource Negotiator）是 Hadoop 集群的资源管理和作业调度框架。Spark/Flink/Hive/MapReduce 的任务都通过 YARN 申请资源运行。

**在集群中的角色**：资源调度中心，决定谁能用多少 CPU 和内存。

---

## 二、架构

```
ResourceManager（全局资源管理）
  ├── Scheduler（调度器：分配资源给队列/应用）
  └── ApplicationsManager（管理应用生命周期）
        ↕
NodeManager（每个节点一个，管理本机 Container）
  └── Container（资源单位：CPU + 内存）
        ↕
ApplicationMaster（每个应用一个，协调任务执行）
```

---

## 三、调度器选型

| 维度 | CapacityScheduler | FairScheduler |
|------|-------------------|---------------|
| 资源保障 | 严格按队列容量分配 | 动态公平共享 |
| 资源抢占 | 支持，需显式开启 | 内置支持 |
| 适用场景 | 多租户生产环境，强隔离 | 研发/测试，灵活共享 |
| 默认调度器 | Hadoop 3.x 默认 | CDH 默认 |

### CapacityScheduler 关键参数

```xml
yarn.scheduler.capacity.root.*.capacity          <!-- 队列容量% -->
yarn.scheduler.capacity.root.*.maximum-capacity   <!-- 队列弹性上限% -->
yarn.scheduler.capacity.root.*.user-limit-factor  <!-- 单用户可占队列比例 -->
yarn.scheduler.capacity.root.*.maximum-am-resource-percent  <!-- AM 资源上限 -->
```

---

## 四、常见故障排查

### 4.1 任务 PENDING（长时间不运行）

**排查路径**（由浅到深）：

1. **查队列资源**：`yarn queue -status [queue_name]` → used/max capacity
2. **查集群总资源**：`yarn top` 或 RM UI → Cluster → Metrics
3. **查节点状态**：`yarn node -list -all` → 有没有 UNHEALTHY/LOST
4. **查应用详情**：`yarn application -status [appId]` → 看 diagnostics 信息
5. **查调度器配置**：是否 maximum-capacity 设太低

### 4.2 NodeManager UNHEALTHY

**常见原因**：磁盘使用超阈值（默认 90%）
**排查**：`yarn node -status <nodeId>` → 看 Health Report
**解决**：清理磁盘 or 调大 `yarn.nodemanager.disk-health-checker.max-disk-utilization-per-disk-percentage`

---

## 五、命令速查

```bash
yarn top                                 # 资源使用概览
yarn queue -status default               # 队列状态
yarn node -list -all                     # 节点列表
yarn application -list                   # 运行中应用
yarn application -status <appId>         # 应用详情
yarn logs -applicationId <appId>         # 应用日志
yarn application -kill <appId>           # 杀死应用
```
