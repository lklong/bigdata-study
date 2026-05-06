# 第十课：BlockManager 存储体系与数据本地性

> **教学目标**：学完本课后，你能解释 Spark 的数据为什么能"存在内存里"，BlockManager 如何在 Driver 和 Executor 之间协调数据存储，以及数据本地性如何影响性能。

---

## 一、先讲个故事（白话层）

把 Spark 集群想象成一个**图书馆系统**：

- 每个 **Executor** 是一个**分馆**，有自己的书架（内存）和仓库（磁盘）
- **Driver** 是**总馆**，维护着一本"全馆藏书目录"
- **BlockManager** 就是每个分馆的**管理员**
- **BlockManagerMaster** 就是总馆的**馆长**，知道每本书在哪个分馆

当你做 `rdd.cache()` 时，就是在说："把这批数据放到各分馆的书架上，下次要用时不用再去出版社（HDFS）买了。"

---

## 二、架构总览

```
Driver 端:
┌─────────────────────────────┐
│ BlockManagerMaster           │  "馆长"：维护全局 Block 元数据
│ ├── Block 位置映射表         │  blockId → Set[BlockManagerId]
│ └── Executor 存活状态        │
└─────────────────────────────┘

Executor 端 (每个 Executor 一个):
┌─────────────────────────────┐
│ BlockManager                 │  "分馆管理员"
│ ├── MemoryStore             │  内存存储（on-heap / off-heap）
│ │    └── LinkedHashMap       │  LRU 淘汰策略
│ ├── DiskStore               │  磁盘存储
│ │    └── DiskBlockManager    │  磁盘文件管理
│ └── BlockTransferService    │  网络传输服务
│      └── NettyBlockTransfer  │  基于 Netty 的块传输
└─────────────────────────────┘
```

## 三、StorageLevel — 存储级别

| 级别 | 内存 | 磁盘 | 序列化 | 副本数 | 适用场景 |
|------|------|------|--------|--------|---------|
| `MEMORY_ONLY` | ✅ | ❌ | ❌ | 1 | 内存充足，小数据集 |
| `MEMORY_AND_DISK` | ✅ | ✅ | ❌ | 1 | **最常用**：内存放不下的溢出到磁盘 |
| `MEMORY_ONLY_SER` | ✅ | ❌ | ✅ | 1 | 内存紧张时减少 GC |
| `DISK_ONLY` | ❌ | ✅ | ✅ | 1 | 数据很大，内存完全放不下 |
| `MEMORY_AND_DISK_2` | ✅ | ✅ | ❌ | 2 | 需要容错的场景 |
| `OFF_HEAP` | ✅(堆外) | ❌ | ✅ | 1 | 避免 GC，Tungsten 优化 |

**类比**：就像图书馆的书可以放在"开放书架"（内存）、"仓库"（磁盘）、或者"密集书架"（序列化压缩存储）。

## 四、数据本地性 — 为什么"就近取材"很重要

### 4.1 五个本地性级别

```
PROCESS_LOCAL  ← 最快：数据在同一个 Executor 的内存中（0延迟）
    ↓ 降级
NODE_LOCAL     ← 快：数据在同一台机器上（本机磁盘读取）
    ↓ 降级
RACK_LOCAL     ← 中等：数据在同一机架（机架内网络传输）
    ↓ 降级
ANY            ← 最慢：数据在其他机架（跨机架网络传输）
```

### 4.2 延迟调度机制

```
TaskScheduler 收到一个 Task:
  "这个 Task 的数据在 Executor-3 上"
  
  ① 检查 Executor-3 有空闲 core 吗？
     → 有：PROCESS_LOCAL 调度 ✓
     → 没有：等 3 秒（spark.locality.wait）
  
  ② 3 秒后还没空闲？降级到 NODE_LOCAL
     → 同机器有其他 Executor 有空闲 core 吗？
     → 有：NODE_LOCAL 调度 ✓
     → 没有：继续等...
  
  ③ 最终降级到 ANY
```

**调优建议**：如果 Spark UI 显示大量 `ANY` 级别的 Task，说明数据本地性差，可以：
- 增大 `spark.locality.wait`（让调度器多等一会儿）
- 增加 Executor 数量（提高命中率）
- 使用 `repartition` 改善数据分布

## 五、课堂练习

### 练习 1：选择存储级别

> 场景：你有一个 100GB 的 RDD，集群每个 Executor 有 4GB 内存，共 50 个 Executor。应该选哪个 StorageLevel？

答：`MEMORY_AND_DISK_SER` — 总内存只有 200GB，100GB RDD 序列化后约 30-50GB，大部分可以放内存，放不下的溢出到磁盘，序列化可以减少内存占用。

### 练习 2：举一反三

> "HDFS 的 DataNode 本地读取与 Spark 的 PROCESS_LOCAL 有什么同构关系？"

答：都是"数据不动代码动"的设计思想——把计算任务调度到数据所在的节点，避免网络传输。HDFS 的 `short-circuit read` 对应 Spark 的 `PROCESS_LOCAL`。

---

## 六、知识晶体

```
问题/场景: Spark 的 cache/persist 数据存在哪里？如何管理？
核心源码: BlockManager.scala, MemoryStore.scala, DiskStore.scala
设计意图: 统一管理内存和磁盘上的数据块，为 RDD 缓存、Shuffle 数据、广播变量提供存储服务
关键参数:
  spark.storage.memoryFraction    → 存储内存占比
  spark.memory.storageFraction    → 统一内存中存储内存的初始占比（默认 0.5）
  spark.locality.wait             → 本地性等待时间（默认 3s）
踩坑记录:
  - cache() 不是立即执行的，而是在第一次 Action 时才缓存
  - 频繁 cache 大量 RDD 会导致内存不足，触发 LRU 淘汰
认知更新: BlockManager 是 Spark 的"统一存储层"——RDD 数据、Shuffle 数据、广播变量、Task 结果都通过它管理
```
