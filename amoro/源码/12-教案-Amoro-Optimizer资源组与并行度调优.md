# 教案 12：Amoro Optimizer 资源组与并行度调优 — 优化器为什么跑不动？

> **课时**：45分钟 | **难度**：⭐⭐⭐

## 一、课前导入 — 200 张表排队优化，只有 3 个在跑

> Dashboard 显示 200 张表 Pending，但只有 3 张在 Executing。明明集群有资源，为什么 Optimizer 就是不给力？答案藏在**资源组配置和配额管理**里。

## 二、核心概念 — 资源组 = 泳道

```
Amoro 资源管理层次：
Container (物理资源池) → ResourceGroup (逻辑分组) → OptimizerInstance (执行者)

例如：
├── Container: "k8s-cluster"
│   ├── ResourceGroup: "production" (8 Optimizer, 64GB)
│   │   ├── Optimizer-1 (1 thread, 8GB)
│   │   ├── Optimizer-2 (1 thread, 8GB)
│   │   └── ... × 8
│   └── ResourceGroup: "dev" (2 Optimizer, 8GB)
│       ├── Optimizer-1 (1 thread, 4GB)
│       └── Optimizer-2 (1 thread, 4GB)
```

## 三、源码核心

### DefaultOptimizerManager（资源组管理）

```java
// 核心方法
public void createResourceGroup(ResourceGroup group);    // 创建资源组
public void deleteResourceGroup(String groupName);       // 删除（需检查是否在用）
public List<OptimizerInstance> listOptimizers(String group); // 查看组内实例
```

### 配额计算（为什么表排队？）

每个资源组的**配额**决定了同时能优化多少张表：
- `quota = 组内 Optimizer 线程总数`
- 每个正在执行的优化进程**占用 1 个线程配额**
- 配额用完 → 新表只能 Pending

## 四、调优指南

| 问题 | 现象 | 解法 |
|------|------|------|
| 大量表 Pending | executing_tables << pending_tables | 增加 Optimizer 实例 |
| 单表优化超慢 | executing_duration > 2h | 增大 Optimizer 内存、检查数据量 |
| 优化频繁失败 | failed_count 高 | 查 AMS 日志，通常是 OOM 或冲突 |
| 资源浪费 | idle_tables 很多但 Optimizer 全忙 | 调整 `self-optimizing.quota-occupy-timeout` |

### 关键参数

```properties
# 资源组配置
self-optimizing.group = "production"           # 表绑定到哪个资源组
self-optimizing.quota-occupy-timeout = 30000   # 配额占用超时(ms)
self-optimizing.execute.num-retries = 5        # 任务失败重试次数

# Optimizer 启动参数
-Xmx8g                                        # 单个 Optimizer 最大内存
--execution-parallel 1                          # 每个 Optimizer 的线程数
```

## 五、课堂练习

### 思考题：如何计算需要多少个 Optimizer？

<details>
<summary>参考答案</summary>

公式：`需要的 Optimizer 数 = 高峰期同时需要优化的表数 × 平均优化时间 / 可接受的最大等待时间`

例如：100 张表每小时需要优化一次，每次优化平均 10 分钟，期望等待不超过 5 分钟：
- 每小时需要 100 × 10min = 1000 分钟的优化算力
- 60min / (10min + 5min) = 4 轮/小时/Optimizer
- 100 / 4 = 25 个 Optimizer

实际还要考虑 Major Optimize（耗时更长）和流量波动，建议 × 1.5 安全系数。
</details>

## 六、知识晶体

```
资源组 = Container → ResourceGroup → OptimizerInstance
配额 = 组内总线程数，决定同时优化多少张表
调优: pending多→加Optimizer, 单表慢→加内存, 失败多→查日志
计算: 需求表数 × 平均耗时 / 可接受等待 × 1.5安全系数
```

*教案作者：Eric | 最后更新：2026-04-30*
