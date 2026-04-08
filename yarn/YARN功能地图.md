# YARN 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 一、核心资源管理能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **资源分配** | CPU + Memory 按需分配给应用 | AM 向 RM 申请 Container | 最小分配单元由 `yarn.scheduler.minimum-allocation-mb/vcores` 控制 | 申请过大浪费；过小频繁申请 |
| **队列管理** | 多租户资源隔离 | CapacityScheduler / FairScheduler 配置队列 | 队列层级最多 5 层 | 队列设计是 YARN 调优的核心 |
| **动态资源** | 应用运行时动态增减 Container | `spark.dynamicAllocation.enabled=true` | 需要 External Shuffle Service | 缩容时不能丢 Shuffle 数据 |
| **抢占** | 高优应用抢低优的资源 | `yarn.scheduler.capacity.scheduling.mode=preemption` | 被抢占的 Container 直接被杀 | 生产配 grace period 让被抢 Container 优雅退出 |
| **资源预留** | 为大应用预留资源 | CapacityScheduler 自动处理 | 预留期间资源空闲不可用 | 避免长时间预留 |
| **节点标签** | 按 Label 将 Node 分组 | `yarn rmadmin -addToClusterNodeLabels "gpu,ssd"` | 标签和队列绑定，配置复杂 | GPU 节点/SSD 节点场景 |
| **GPU 支持** | 分配 GPU 资源 | `yarn.resource-types=yarn.io/gpu` | 需要 GPU isolation（cgroups devices） | Hadoop 3.1+ |

---

## 二、调度器能力

### 2.1 CapacityScheduler

| 能力 | 使用方式 | 限制 | 注意 |
|------|---------|------|------|
| **层级队列** | `capacity-scheduler.xml` | 子队列 capacity 之和必须 = 100 | 规划好层级结构 |
| **弹性扩展** | `maximum-capacity` > `capacity` | 只能用其他队列的空闲资源 | 设 `max-capacity` 防止一个队列吃光 |
| **用户限制** | `user-limit-factor` | 单用户不能超过队列 capacity × factor | 多用户共享队列必设 |
| **应用优先级** | `priority` 字段 | 同队列内有效；跨队列看队列优先级 | 优先级 0 最低 |
| **队列 ACL** | `acl_submit_applications` | 只控制提交权限，不控制队列内资源 | 和 Ranger 配合做细粒度 |

### 2.2 FairScheduler

| 能力 | 使用方式 | 限制 | 注意 |
|------|---------|------|------|
| **公平共享** | `fair-scheduler.xml` | DRF 计算复杂度高 | 大集群性能不如 CapacityScheduler |
| **权重** | `<weight>2.0</weight>` | 权重只是相对值 | 和 capacity 百分比含义不同 |
| **最小共享** | `<minResources>` | 保证最低资源，但可能浪费 | 设太大导致资源碎片 |
| **抢占** | `<fairSharePreemptionTimeout>` | 抢占有延迟（timeout 到期才抢） | 不要设太短 |

---

## 三、Container 管理

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **Container 启动** | NM 在本地启动 JVM 进程 | AM 收到分配后向 NM 发起启动 | 启动延迟 3-10s（JVM 初始化） | 比 K8s Pod 快很多 |
| **资源隔离 (CPU)** | CGroups 控制 CPU 使用 | `yarn.nodemanager.linux-container-executor.cgroups.enabled=true` | 默认不隔离 CPU（只做记账）；开启后有 2-3% 额外开销 | 多租户生产集群必须开启 |
| **资源隔离 (Memory)** | 物理内存硬限制 | `yarn.nodemanager.pmem-check-enabled=true` | 超限直接 kill Container | Spark Executor OOM 常见原因 |
| **虚拟内存检查** | vmem/pmem 比例 | `yarn.nodemanager.vmem-pmem-ratio=2.1` | JVM 虚拟内存通常远大于物理内存 | 建议关闭 vmem-check（误杀率高） |
| **日志聚合** | Container 日志收集到 HDFS | `yarn.log-aggregation-enable=true` | 聚合有延迟（应用完成后） | 日志保留时间 `yarn.log-aggregation.retain-seconds` |
| **Container 重试** | Task 失败自动重试 | `mapreduce.map.maxattempts=4` / Spark `spark.task.maxFailures=4` | 重试有上限 | 排查是否是确定性失败（重试无效） |

---

## 四、ApplicationMaster 管理

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **AM 启动** | RM 在某个 NM 上启动 AM | 提交应用时自动完成 | AM 也需要 Container 资源（`yarn.app.mapreduce.am.resource.mb`） | AM 内存不够会 OOM |
| **AM 重试** | AM 挂了自动重启 | `yarn.resourcemanager.am.max-attempts=2` | 重启后需要重新请求资源 | Spark AM 重启 = 整个任务重跑 |
| **AM 心跳** | AM 定期向 RM 报告 | 自动完成 | 超时未报告 → RM 认为 AM 挂了 | 长 GC 可能导致误判 |

---

## 五、高可用

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **RM HA** | Active/Standby 双 RM | `yarn.resourcemanager.ha.enabled=true` + ZK | 切换时间 ~30s；切换期间不能提交新应用 | 运行中的应用不受影响（AM 自管理） |
| **Work-Preserving RM Recovery** | RM 重启不杀运行中的应用 | `yarn.resourcemanager.recovery.enabled=true` | 需要 ZK 或 LevelDB 持久化状态 | 必须开启！否则 RM 重启杀全部应用 |

---

## 六、功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 容器化部署 (Docker) | K8s |
| 弹性 Node 伸缩 | K8s Cluster Autoscaler |
| 微服务调度 | K8s |
| 混合调度（大数据+AI+Web） | K8s |
| 分钟级 Node 扩容 | 云 EMR 弹性扩容 |

---

## 七、关键参数速查

| 参数 | 默认 | 建议 | 说明 |
|------|------|------|------|
| `yarn.nodemanager.resource.memory-mb` | 8192 | 物理内存 × 0.8 | NM 可分配内存 |
| `yarn.nodemanager.resource.cpu-vcores` | 8 | 物理核数 × 0.8 | NM 可分配 CPU |
| `yarn.scheduler.minimum-allocation-mb` | 1024 | 1024 | 最小内存分配单位 |
| `yarn.scheduler.maximum-allocation-mb` | 8192 | 根据最大 Executor | 最大内存分配单位 |
| `yarn.nodemanager.pmem-check-enabled` | true | true | 物理内存检查 |
| `yarn.nodemanager.vmem-check-enabled` | true | **false** | 建议关闭虚拟内存检查 |
| `yarn.log-aggregation-enable` | false | **true** | 日志聚合 |

---

*YARN Expert | 功能地图 v1.0 | 2026-04-08*
