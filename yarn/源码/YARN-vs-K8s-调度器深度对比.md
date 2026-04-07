# YARN 调度器深度对比：CapacityScheduler vs FairScheduler vs K8s Scheduler

> YARN Expert 补充学习 — 从 K8s vs YARN 资源调度差异深入

## 一、为什么需要对比调度器

K8s vs YARN 案例中，两端的资源分配方式完全不同：
- **YARN**：CapacityScheduler 分配 Container，Container 得到 vcore + memory 软隔离
- **K8s**：kube-scheduler 分配 Pod，Pod 得到 cgroup 硬隔离

这导致了资源利用效率和任务启动延迟的显著差异。

## 二、YARN CapacityScheduler 核心机制

### 2.1 队列层级调度

```
root (100%)
├── default (40%)
│   ├── batch (20%)
│   └── interactive (20%)
├── prod (50%)
│   ├── etl (30%)
│   └── adhoc (20%)
└── dev (10%)

每个队列:
  - capacity: 保证资源比例
  - max-capacity: 弹性扩展上限
  - user-limit-factor: 单用户最多占队列的比例
```

### 2.2 Container 分配流程

```
ApplicationMaster 请求资源
  → ResourceManager 接收请求
  → CapacityScheduler 按 DRF (Dominant Resource Fairness) 排序
  → 选择满足约束的 NodeManager
  → NM 启动 Container (JVM 进程)

关键特点:
  - 增量分配: AM 可以请求 1 个 container，也可以批量请求 100 个
  - 数据本地性: 优先分配到数据所在节点（NODE_LOCAL > RACK_LOCAL > ANY）
  - 延迟调度: 为了数据本地性，可以等几轮心跳
```

### 2.3 YARN 资源隔离模型

```
CPU: LinuxContainerExecutor + CGroups (可选)
  - 默认: 不隔离 CPU，只做 vcore 记账
  - 开启 CGroups: cpu.shares (软隔离，可超用)

Memory: 严格限制
  - JVM Heap: -Xmx 限制
  - 物理内存: pmem-check-enabled (超限被 kill)
  - 虚拟内存: vmem-check-enabled (默认开启，比例 2.1x)
```

## 三、K8s Scheduler 核心机制

### 3.1 调度流程

```
Spark Driver 创建 Pod Spec
  → API Server → etcd
  → kube-scheduler 监听 Pending Pod
  → Filtering (过滤不满足条件的 Node)
  → Scoring (打分选最优 Node)
  → Binding (绑定 Pod 到 Node)
  → kubelet 启动容器

关键特点:
  - 非增量: 每个 Pod 独立调度（不像 YARN 批量分配）
  - 无数据本地性: 默认不考虑数据在哪个节点（可以用 nodeAffinity 手动指定）
  - 无延迟调度: 第一个满足条件的 Node 就绑定
```

### 3.2 K8s 资源隔离模型

```
CPU:
  - request: 保证值 → cpu.shares (相对权重)
  - limit: 硬上限 → cpu.cfs_quota_us / cpu.cfs_period_us (CFS bandwidth throttle)
  - 超过 limit → 被 throttle (不是 kill，是降速)

Memory:
  - request: 保证值 → 影响调度
  - limit: 硬上限 → cgroup memory.limit_in_bytes
  - 超过 limit → OOMKilled (直接被杀)
```

## 四、关键差异对比

### 4.1 资源分配

| 维度 | YARN CapacityScheduler | K8s Scheduler |
|------|----------------------|---------------|
| 分配单位 | Container (进程) | Pod (容器) |
| 批量分配 | ✅ AM 一次请求多个 | ❌ 每个 Pod 独立调度 |
| 数据本地性 | ✅ NODE_LOCAL/RACK_LOCAL | ❌ 默认无（需手动配） |
| 延迟调度 | ✅ 等待本地 Node | ❌ 立即调度 |
| 启动延迟 | ~5-15s (JVM 进程) | ~20-60s (镜像拉取+容器创建) |
| 资源超卖 | ✅ CPU 可超用(soft) | 仅 request < limit 时 |

### 4.2 CPU 隔离

| 维度 | YARN (默认) | YARN (CGroups) | K8s |
|------|------------|----------------|-----|
| 机制 | 无隔离 | cpu.shares (软) | CFS quota (硬) |
| 超用 | ✅ 自由超用 | ✅ 按比例借用 | ❌ throttle |
| GC 影响 | 无 | 低 | **高** (GC 线程被限速) |
| burst | ✅ | ✅ | ❌ (quota 限制) |

**这解释了 K8s 任务更慢的根因之一**：YARN 的 CPU 是"软隔离"，GC/JIT 可以临时借用空闲 CPU；K8s 是"硬隔离"，quota 用完就被 throttle。

### 4.3 Executor 扩容速度

```
YARN 扩容一个 executor:
  1. AM 发送资源请求 → RM (~0.1s)
  2. RM 分配 Container → NM (~0.5-2s)
  3. NM 启动 JVM 进程 (~3-8s)
  总计: ~5-10s

K8s 扩容一个 executor:
  1. Driver 创建 Pod Spec → API Server (~0.1s)
  2. kube-scheduler 调度 (~0.5-2s)
  3. kubelet 拉取镜像 (~5-30s, 有缓存则跳过)
  4. 创建容器 + 启动 JVM (~3-10s)
  总计: ~10-40s (有镜像缓存 ~10-15s, 无缓存 ~30-60s)
```

## 五、大数据场景的调度优化

### 5.1 YARN 调优要点

```xml
<!-- capacity-scheduler.xml -->
<!-- 1. 抢占: 保证高优队列能从低优队列抢回资源 -->
<property>
  <name>yarn.scheduler.capacity.scheduling.mode</name>
  <value>preemption</value>
</property>

<!-- 2. 最大并行应用数 -->
<property>
  <name>yarn.scheduler.capacity.root.prod.maximum-applications</name>
  <value>200</value>
</property>

<!-- 3. 节点标签: 将 GPU/SSD 节点专门给特定队列 -->
<property>
  <name>yarn.scheduler.capacity.root.prod.accessible-node-labels</name>
  <value>gpu,ssd</value>
</property>
```

### 5.2 K8s 调度优化

```yaml
# 1. Pod Priority — 高优任务抢占低优
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: spark-production
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority

---
# 2. Node Affinity — 将 Spark 调度到大数据专用节点池
apiVersion: v1
kind: Pod
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-pool
            operator: In
            values: ["bigdata"]

---
# 3. Topology Spread — executor 均匀分布到各节点
spec:
  topologySpreadConstraints:
  - maxSkew: 2
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        spark-role: executor
```

```properties
# 4. Spark 参数优化
# 预分配所有 executor，避免逐个扩容
spark.dynamicAllocation.initialExecutors=100
spark.dynamicAllocation.minExecutors=50

# Executor Pod 模板
spark.kubernetes.executor.podTemplateFile=/opt/spark/conf/executor-template.yaml

# 镜像预拉取（DaemonSet 方式）
# 在每个 Node 上预拉取 Spark 镜像，消除冷启动延迟
```

## 六、YARN vs K8s 选型决策树

```
你的大数据任务:
│
├─ 数据本地性很重要 (HDFS 上的数据)
│  └─ 选 YARN ✅ (NODE_LOCAL 调度)
│
├─ 需要弹性伸缩 (突发流量)
│  └─ 选 K8s ✅ (Cluster Autoscaler 自动扩 Node)
│
├─ 混合负载 (大数据 + 微服务 + AI)
│  └─ 选 K8s ✅ (统一调度平面)
│
├─ CPU 敏感任务 (需要 burst)
│  └─ 选 YARN ✅ (CPU 软隔离可超用)
│
├─ 内存敏感任务 (不能 OOM)
│  └─ 都可以 (YARN pmem-check / K8s memory limit)
│
└─ 成本优先 (共享集群资源)
   ├─ 静态集群 → YARN ✅ (Queue + DRF 成熟)
   └─ 云环境 → K8s ✅ (弹性 + Spot Instance)
```

---

*YARN Expert 学习产出 | 2026-04-08 | 来源：K8s vs YARN 案例调度差异延伸*
