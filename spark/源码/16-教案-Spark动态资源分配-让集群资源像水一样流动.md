# 教案 16：Spark 动态资源分配 — 让集群资源像水一样流动

> **课时**：30分钟 | **难度**：⭐⭐⭐

## 一、课前导入

> 你的 Spark 作业有 3 个 Stage：Stage 1 需要 100 个 Executor，Stage 2 只需要 10 个，Stage 3 又需要 50 个。如果固定分配 100 个 Executor，Stage 2 期间有 90 个 Executor 在空转浪费。动态资源分配让 Spark 自动伸缩。

## 二、工作原理

```
Task 堆积 → 申请更多 Executor (scale up)
Task 完成 → 空闲 Executor 被回收 (scale down)

具体:
  空闲超过 executorIdleTimeout(60s) → 移除该 Executor
  Task 排队等待 → 每个调度周期申请更多 Executor (指数增长: 1,2,4,8...)
  上限: spark.dynamicAllocation.maxExecutors
```

## 三、关键配置

```properties
spark.dynamicAllocation.enabled = true
spark.dynamicAllocation.minExecutors = 2       # 最少保留
spark.dynamicAllocation.maxExecutors = 100     # 最多申请
spark.dynamicAllocation.initialExecutors = 5    # 初始数量

# 伸缩时机
spark.dynamicAllocation.executorIdleTimeout = 60s      # 空闲多久回收
spark.dynamicAllocation.cachedExecutorIdleTimeout = ∞  # 有Cache的不回收
spark.dynamicAllocation.schedulerBacklogTimeout = 1s   # 排队多久开始扩容

# 必须配合 External Shuffle Service（否则 Executor 回收会丢 Shuffle 数据）
spark.shuffle.service.enabled = true
```

## 四、为什么需要 External Shuffle Service？

```
问题: Executor A 产生了 Shuffle 数据 → 空闲被回收 → Reduce Task 要拉 A 的数据 → 找不到了！

解决: External Shuffle Service (ESS) 运行在 NodeManager 上
      Executor 产生的 Shuffle 数据由 ESS 代管
      Executor 回收后，ESS 仍然可以提供数据

K8s 场景替代方案: Celeborn / Apache Uniffle
```

## 五、课堂练习

### 思考题：动态分配 + AQE 同时开启时，有什么交互效果？

<details>
<summary>参考答案</summary>

两者互补：
- AQE 减少了不必要的 Task 数（合并小分区）→ 需要的 Executor 更少 → 动态分配更快回收
- 动态分配在 Stage 间伸缩 → AQE 在 Stage 内优化
- 注意：AQE 可能导致 Stage 边界增多 → 更频繁的伸缩 → `schedulerBacklogTimeout` 别设太短
</details>

## 六、知识晶体

```
动态分配: 按需申请/释放 Executor，避免资源空转
必需: spark.shuffle.service.enabled=true (否则丢Shuffle)
伸缩: 空闲60s→回收, 排队1s→扩容(指数增长)
K8s: Celeborn/Uniffle 替代 ESS
```

*教案作者：Eric | 最后更新：2026-04-30*
