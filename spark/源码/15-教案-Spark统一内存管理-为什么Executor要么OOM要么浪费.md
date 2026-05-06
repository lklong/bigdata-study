# 教案 15：Spark 统一内存管理 — 为什么你的 Executor 要么 OOM 要么浪费？

> **课时**：40分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入

> Executor 配了 8GB，Spark UI 显示只用了 2GB，但作业还是 OOM 了。为什么？因为 Spark 把内存切成了几块，相互之间有**动态借用**机制，但借来的可能要不回来。

## 二、统一内存管理模型（Spark 1.6+）

```
Executor Memory (spark.executor.memory = 8GB)
├── Reserved Memory (300MB, 固定)
└── Usable Memory (7.7GB)
    ├── User Memory (40%, 3.08GB) — 用户代码的对象/数据结构
    └── Unified Memory (60%, 4.62GB) — Spark 管理
        ├── Storage Memory (50% of Unified = 2.31GB) — Cache/Broadcast
        └── Execution Memory (50% of Unified = 2.31GB) — Shuffle/Sort/Agg
```

### 动态借用规则

```
Storage 空闲时 → Execution 可以借用 Storage 的内存
Execution 空闲时 → Storage 可以借用 Execution 的内存

但！重要区别：
- Execution 借了 Storage 的 → Storage 需要时可以驱逐 Cache 要回来
- Storage 借了 Execution 的 → Execution 需要时 Storage 必须让出！(Execution 优先)
```

**为什么 Execution 优先？**
- Execution 内存不够 = Task 直接失败（OOM）
- Storage 内存不够 = 只是 Cache 被驱逐，数据可以重算

## 三、堆外内存

```
Off-Heap Memory (spark.memory.offHeap.enabled=true, spark.memory.offHeap.size=4GB)
├── Storage Off-Heap — Tungsten 格式的 Cache
└── Execution Off-Heap — Tungsten 排序/Shuffle 缓冲

优势: 无 GC 压力，适合大内存场景
配置: 额外增加的，不算在 executor.memory 内
```

## 四、OOM 诊断指南

| 现象 | 原因 | 解法 |
|------|------|------|
| `java.lang.OutOfMemoryError: Java heap space` | User Memory 或 Unified 不够 | 增大 executor.memory |
| GC 占比 > 30% | 堆内对象太多 | 开启 off-heap 或增大内存 |
| `Container killed by YARN (exit 137)` | 堆外内存超限 | 增大 `spark.executor.memoryOverhead` |
| Shuffle 溢写频繁 | Execution Memory 不够 | 减少 `spark.memory.storageFraction` |
| Cache 被频繁驱逐 | Storage 被 Execution 借走 | 增大总内存或减少 Cache 量 |

## 五、课堂练习

### 思考题：executor.memory=4g 时，一个 Task 最多能用多少 Execution Memory？

<details>
<summary>参考答案</summary>

```
Usable = 4GB - 300MB = 3.7GB
Unified = 3.7GB × 0.6 = 2.22GB
Execution Pool = Unified × 0.5 = 1.11GB (初始)
但如果 Storage 空闲 → 最多可借到整个 Unified = 2.22GB
单 Task 份额 = Execution Pool / numCoresPerExecutor

如果 4 核 Executor：单 Task 最大 = 2.22GB / 4 = 555MB
```

所以 4GB Executor 跑 4 个 Task，每个 Task 处理的数据不能超过 ~500MB，否则溢写到磁盘。
</details>

## 六、知识晶体

```
统一内存 = User(40%) + Unified(60% = Storage + Execution)
动态借用: Execution优先 > Storage可驱逐
堆外: offHeap.enabled + offHeap.size（无GC，大内存必开）
OOM决策: 堆内→加memory, 堆外→加memoryOverhead
单Task上限 = UnifiedMemory / cores
```

*教案作者：Eric | 最后更新：2026-04-30*
