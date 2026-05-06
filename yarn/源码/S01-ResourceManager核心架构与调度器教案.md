# YARN 第一课：ResourceManager 核心架构与调度器

> **教学目标**：学完本课后，你能画出 YARN 的整体架构图，解释 RM 内部的调度器如何分配资源，以及三种调度器（FIFO/Capacity/Fair）的区别。

---

## 一、先讲个故事（白话层）

把 YARN 想象成一个**共享办公空间（WeWork）**：

- **ResourceManager（RM）** = WeWork 的**总部管理**，负责分配工位和会议室
- **NodeManager（NM）** = 每栋楼的**物业管理**，管理本栋楼的工位和资源
- **ApplicationMaster（AM）** = 每家公司的**行政经理**，为自己公司的人申请工位
- **Container** = 一个**工位**，包含固定的桌子（CPU）和储物柜（内存）

工作流程：
1. 某公司要入驻（提交应用）
2. 总部分配一个工位给行政经理（启动 AM）
3. 行政经理根据团队大小，向总部申请更多工位（申请 Container）
4. 总部按照分配策略（排队/容量/公平）分配工位
5. 员工入驻工位开始工作（Task 在 Container 中执行）

---

## 二、YARN 架构全景图

```
┌──────────────────────────────────────────────┐
│               ResourceManager (RM)            │
│  ┌─────────────┐  ┌────────────────────────┐ │
│  │ Scheduler    │  │ ApplicationsManager    │ │
│  │ (分配资源)    │  │ (管理应用生命周期)      │ │
│  │              │  │                        │ │
│  │ CapacitySch  │  │ 接受提交/监控AM/重启AM  │ │
│  │ FairSch      │  │                        │ │
│  │ FIFOSch      │  │                        │ │
│  └─────────────┘  └────────────────────────┘ │
└──────────────┬───────────────────────────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐
│ NM-1   │ │ NM-2   │ │ NM-3   │
│ ┌────┐ │ │ ┌────┐ │ │ ┌────┐ │
│ │ AM │ │ │ │ C  │ │ │ │ C  │ │  AM = ApplicationMaster
│ ├────┤ │ │ ├────┤ │ │ ├────┤ │  C  = Container (Task)
│ │ C  │ │ │ │ C  │ │ │ │ C  │ │
│ └────┘ │ │ └────┘ │ │ └────┘ │
└────────┘ └────────┘ └────────┘
```

## 三、三种调度器对比

### 3.1 FIFO 调度器 — 先来先服务

```
队列: [App-1 ████████] [App-2 ████] [App-3 ██]
      ← 先到的先分配所有资源，后面的等着

优点: 简单
缺点: 大作业霸占资源，小作业饿死
适用: 测试环境、单用户场景
```

### 3.2 CapacityScheduler — 容量调度器（**YARN 默认**）

```
总资源 100%
├── 队列 A (60%): 部门 A 的作业
│   ├── 子队列 A1 (30%): 生产作业
│   └── 子队列 A2 (30%): 开发作业
└── 队列 B (40%): 部门 B 的作业

核心规则:
  ① 每个队列保证最低容量（60%/40%）
  ② 空闲资源可以被其他队列"借用"（弹性）
  ③ 当"主人"队列需要资源时，通过"抢占"回收
```

**类比**：就像合租房间——你有固定的房间（保障容量），但如果室友出差了，你可以临时用他的房间（弹性分配），等他回来你就得还（抢占）。

### 3.3 FairScheduler — 公平调度器

```
总资源 100%

时间 T1: 只有 App-1 在运行 → App-1 获得 100%
时间 T2: App-2 来了 → App-1: 50%, App-2: 50%（公平分配）
时间 T3: App-3 来了 → App-1: 33%, App-2: 33%, App-3: 33%
时间 T4: App-1 完成 → App-2: 50%, App-3: 50%

核心思想: 动态平均分配，让每个应用都能"公平"地获得资源
```

### 3.4 三者对比总结

| 维度 | FIFO | Capacity | Fair |
|------|------|----------|------|
| 设计理念 | 先到先得 | 分配固定容量 | 动态公平分配 |
| 多租户 | ❌ | ✅ 通过队列 | ✅ 通过队列 |
| 弹性 | ❌ | ✅ 可借用空闲 | ✅ 动态调整 |
| 抢占 | ❌ | ✅ | ✅ |
| 适用场景 | 测试 | **生产环境首选** | CDH 默认 |
| 复杂度 | 低 | 中 | 中 |

---

## 四、应用提交全流程

```
Client 提交应用
    │
    ▼ ① 提交到 RM
RM.ApplicationsManager
    │ ② 在某个 NM 上启动 AM
    ▼
AM 启动（在 Container-0 中运行）
    │ ③ AM 向 RM 注册
    │ ④ AM 向 RM 请求资源（N 个 Container）
    ▼
RM.Scheduler 分配 Container
    │ ⑤ AM 拿到 Container 列表
    │ ⑥ AM 联系对应的 NM 启动 Container
    ▼
NM 启动 Container
    │ ⑦ Container 中运行 Task
    │ ⑧ Task 完成后 Container 释放
    ▼
AM 所有 Task 完成
    │ ⑨ AM 向 RM 注销
    ▼
应用完成
```

## 五、课堂练习

### 练习 1：设计队列

> 场景：公司有 3 个团队，数据团队（50%资源）、算法团队（30%资源）、开发团队（20%资源）。数据团队有生产和开发两类作业。如何配置 CapacityScheduler？

答：
```xml
root (100%)
├── data (50%)
│   ├── data.prod (35%)   ← 生产作业优先
│   └── data.dev  (15%)   ← 开发作业
├── algo (30%)
└── dev  (20%)
```

### 练习 2：举一反三

> "K8s 的 ResourceQuota + LimitRange 与 YARN 的 CapacityScheduler 有什么同构关系？"

答：
- ResourceQuota ≈ 队列的 `capacity`（保障容量）
- LimitRange ≈ `maximum-capacity`（最大弹性上限）
- K8s Namespace ≈ YARN Queue
- K8s Pod ≈ YARN Container

---

## 六、知识晶体

```
问题/场景: YARN 如何在多租户环境下高效分配集群资源？
核心源码: CapacityScheduler.java, FairScheduler.java
设计意图: 通过队列隔离保证各团队的最低资源，通过弹性借用提高整体利用率
关键参数:
  yarn.scheduler.capacity.root.queues     → 顶级队列列表
  yarn.scheduler.capacity.root.X.capacity → 队列 X 的容量百分比
  yarn.scheduler.capacity.root.X.maximum-capacity → 最大弹性容量
  yarn.resourcemanager.scheduler.class    → 调度器类名
踩坑记录:
  - 队列容量之和必须 = 100%，否则 RM 启动报错
  - 抢占默认关闭（yarn.resourcemanager.scheduler.monitor.enable=false），生产环境建议开启
  - AM 也占一个 Container，计算资源时别忘了减去 AM 的开销
认知更新: YARN 的调度本质是"资源的时分复用"——同一份物理资源，通过队列和调度策略，在时间维度上被多个租户共享
```
