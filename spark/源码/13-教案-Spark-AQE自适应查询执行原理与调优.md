# 教案 13：Spark AQE 自适应查询执行 — 让 Spark 自己学会调优

> **课时**：45分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入 — 优化器的预测永远不准

> 你的 SQL 在 Spark 上执行，优化器基于统计信息预估 JOIN 一侧只有 1000 条数据，选择了 BroadcastHashJoin。但实际运行时发现有 1 亿条！结果 Broadcast 变量 OOM 了。
>
> 问题根源：**执行前的优化（Static Optimization）基于过时或缺失的统计信息**。AQE 的解决方案：**运行时收集真实统计信息，动态调整执行计划**。

## 二、AQE 三大能力

| 能力 | 解决什么问题 | 触发条件 |
|------|-------------|---------|
| **自动合并小分区** | Shuffle 后大量空/小分区 → Task 数过多 | partition 小于 `advisoryPartitionSizeInBytes` |
| **动态 Join 策略切换** | 静态选错了 Join 类型 | 运行时发现数据量满足 Broadcast 条件 |
| **数据倾斜优化** | 某些 partition 数据量远大于平均值 | partition 大于 `skewedPartitionFactor × median` |

## 三、工作原理

```
传统 Spark:
  Logical Plan → Physical Plan → 固定执行

AQE Spark:
  Logical Plan → Physical Plan → 执行 Stage 1
                                      │
                                      ▼ (收集 Stage 1 的 Shuffle 统计)
                              重新优化 Stage 2 的计划
                                      │
                                      ▼
                              执行 Stage 2 (可能改了 Join 策略)
                                      │
                                      ▼ (收集 Stage 2 的 Shuffle 统计)
                              重新优化 Stage 3 ...
```

**核心思想**：在每个 **Shuffle 边界**停下来，收集真实的数据统计（每个 partition 的大小），然后**重新规划**下一个 Stage。

## 四、关键配置

```properties
# 开启 AQE（Spark 3.2+ 默认开启）
spark.sql.adaptive.enabled = true

# 合并小分区
spark.sql.adaptive.coalescePartitions.enabled = true
spark.sql.adaptive.advisoryPartitionSizeInBytes = 128MB  # 目标分区大小
spark.sql.adaptive.coalescePartitions.minPartitionSize = 1MB

# 动态 Join 切换
spark.sql.adaptive.localShuffleReader.enabled = true
spark.sql.adaptive.autoBroadcastJoinThreshold = 30MB  # 运行时 Broadcast 阈值

# 倾斜优化
spark.sql.adaptive.skewJoin.enabled = true
spark.sql.adaptive.skewJoin.skewedPartitionFactor = 5     # 超过中位数 5 倍算倾斜
spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes = 256MB  # 且超过此大小
```

## 五、AQE 的局限性

| 局限 | 原因 | 变通方案 |
|------|------|---------|
| **只在 Shuffle 边界生效** | 没有 Shuffle 就没有收集统计的机会 | 对关键操作强制加 repartition |
| **不优化第一个 Stage** | 第一个 Stage 之前没有 Shuffle 统计 | 手动 ANALYZE TABLE 更新统计信息 |
| **增加少量延迟** | 每个 Stage 结束后需要统计再重新规划 | 对延迟极敏感的场景权衡 |
| **不能减少 Shuffle** | 只能调整分区数和 Join 策略，不能消除 Shuffle | 代码层面优化（如用 mapPartitions） |

## 六、课堂练习

### 思考题 1：AQE 的合并小分区和手动 coalesce 有什么区别？

<details>
<summary>参考答案</summary>

| | AQE 合并 | 手动 coalesce(N) |
|--|--|--|
| **时机** | Shuffle 后自动，基于真实数据量 | 代码里硬编码 |
| **智能度** | 自动决定合并几个、怎么组合 | 固定 N 个分区 |
| **适应性** | 每次执行动态调整 | 数据量变了就不合适了 |
| **结论** | 优先用 AQE，除非有特殊需求 | |
</details>

### 思考题 2：AQE 倾斜优化怎么做的？

<details>
<summary>参考答案</summary>

检测到倾斜分区后：
1. 将倾斜的大 partition 拆成多个小 partition（按 `advisoryPartitionSizeInBytes` 拆）
2. 对拆出的每个小 partition，与 Join 的另一侧进行匹配
3. 另一侧的对应 partition 被**复制**多份，与拆分后的各份分别 Join
4. 最终合并所有结果

本质是**动态的 Skew Join 优化**，等价于手动加盐(salt)但更智能。
</details>

## 七、知识晶体

```
AQE = 运行时统计 + 动态重优化（在 Shuffle 边界）
三大能力: 合并小分区 + 动态Join切换 + 倾斜优化
核心配置: advisoryPartitionSizeInBytes=128MB + skewFactor=5
局限: 只在Shuffle边界生效，第一个Stage无法优化
同构: AQE ≈ 数据库的运行时 Re-Optimization (PostgreSQL 14+)
```

*教案作者：Eric | 最后更新：2026-04-30*
