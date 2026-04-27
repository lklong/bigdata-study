# 第九课：RDD 依赖链与 Stage 划分原理

> **教学目标**：学完本课后，你能看到任意一段 Spark 代码，立刻画出 RDD 依赖链、标出宽窄依赖、划分 Stage，并预测会产生几个 Shuffle。
>
> 源码版本：Spark 4.0.0-SNAPSHOT | 源码路径：`/Users/kailongliu/bigdata/txProjects/spark/`

---

## 一、先讲个故事（白话层）

想象你在做一道复杂的菜——"宫保鸡丁"：

1. **切鸡肉**（第一步，原材料加工）→ 窄依赖：每块鸡肉只需要自己被切
2. **切花生**（第一步，另一条线）→ 窄依赖
3. **炒鸡肉**（第二步）→ 窄依赖：切好的鸡肉直接下锅
4. **混合鸡肉和花生**（第三步）→ **宽依赖！** 需要把两边的结果"洗牌"混在一起

在 Spark 中：
- **窄依赖**（Narrow）= 流水线操作（切→炒可以连续做）
- **宽依赖**（Wide/Shuffle）= 需要等所有材料准备好才能混合

**Stage 的划分规则**：遇到"宽依赖"就切一刀，切出来的每段就是一个 Stage。

---

## 二、RDD 五大属性（必背！）

源码注释原文（`RDD.scala`）：

> Internally, each RDD is characterized by five main properties:
> 1. A list of **partitions**
> 2. A **function** for computing each split
> 3. A list of **dependencies** on other RDDs
> 4. Optionally, a **Partitioner** for key-value RDDs
> 5. Optionally, a list of **preferred locations** to compute each split on

| 属性 | 类比 | 作用 |
|------|------|------|
| `partitions()` | 工作台数量 | 决定并行度 |
| `compute()` | 加工方法 | 每个分区的计算逻辑 |
| `dependencies()` | 原材料来源 | 定义 RDD 之间的血缘关系 |
| `partitioner` | 分拣规则 | key-value RDD 的分区策略 |
| `preferredLocations()` | 就近取材 | 数据本地性优化 |

---

## 三、两种依赖 — 宽与窄

### 3.1 源码定义

```scala
// Dependency.scala

// 窄依赖：子 RDD 的每个分区只依赖父 RDD 的少量分区
abstract class NarrowDependency[T](_rdd: RDD[T]) extends Dependency[T] {
  def getParents(partitionId: Int): Seq[Int]  // 给定子分区 ID，返回父分区 ID 列表
}

// 宽依赖（Shuffle 依赖）：子 RDD 的每个分区可能依赖父 RDD 的所有分区
class ShuffleDependency[K, V, C](
    _rdd: RDD[_ <: Product2[K, V]],
    val partitioner: Partitioner,      // 分区器（决定 key 去哪个分区）
    val serializer: Serializer,
    val mapSideCombine: Boolean,       // 是否做 map 端预聚合
    ...) extends Dependency[Product2[K, V]]
```

### 3.2 判断口诀

```
问自己一个问题：
  "父 RDD 的一个分区，它的数据会去到子 RDD 的几个分区？"

  答"一个" → 窄依赖（一对一）    → map, filter, flatMap, union
  答"多个" → 宽依赖（一对多）    → reduceByKey, groupByKey, join, repartition
```

### 3.3 图解对比

```
窄依赖（NarrowDependency）         宽依赖（ShuffleDependency）
┌─────────┐                        ┌─────────┐
│ Parent   │                        │ Parent   │
│ Part-0 ──┼──→ Child Part-0       │ Part-0 ──┼──→ Child Part-0
│ Part-1 ──┼──→ Child Part-1       │          ├──→ Child Part-1
│ Part-2 ──┼──→ Child Part-2       │ Part-1 ──┼──→ Child Part-0
└─────────┘                        │          ├──→ Child Part-1
                                    │ Part-2 ──┼──→ Child Part-0
一条线连一条线                       │          ├──→ Child Part-1
→ 可以流水线（pipeline）             └─────────┘
→ 同一个 Stage                      
                                    多条线交叉
                                    → 需要 Shuffle（等全部写完才能读）
                                    → 必须切分 Stage
```

---

## 四、Stage 划分算法

### 4.1 核心思想

```
从最终结果 RDD 开始，往回追溯：
  遇到窄依赖 → 继续往回走（加入当前 Stage）
  遇到宽依赖 → 停！切一刀！创建新 Stage
```

### 4.2 DAGScheduler 的实现

```scala
// DAGScheduler.scala（简化版）

private def createResultStage(rdd, func, partitions, jobId): ResultStage = {
  val parents = getOrCreateParentStages(rdd, jobId)  // 递归找父 Stage
  new ResultStage(id, rdd, func, partitions, parents, jobId)
}

private def getOrCreateParentStages(rdd, jobId): List[Stage] = {
  // 遍历 RDD 依赖链
  rdd.dependencies.foreach {
    case shufDep: ShuffleDependency[_, _, _] =>
      // 宽依赖 → 创建 ShuffleMapStage
      getOrCreateShuffleMapStage(shufDep, jobId)
    case narrowDep: NarrowDependency[_] =>
      // 窄依赖 → 继续往回追溯（不切 Stage）
      waitingForVisit.push(narrowDep.rdd)
  }
}
```

### 4.3 两种 Stage

| Stage 类型 | 职责 | 产出 |
|-----------|------|------|
| `ShuffleMapStage` | 产生 Shuffle 数据 | MapStatus（每个分区写到哪了） |
| `ResultStage` | 产生最终结果 | 返回给 Driver 的计算结果 |

**规律**：最后一个 Stage 一定是 `ResultStage`，其余都是 `ShuffleMapStage`。

---

## 五、实战演练 — 画 Stage

### 示例代码

```scala
val rdd1 = sc.textFile("hdfs://data.txt")    // HadoopRDD
val rdd2 = rdd1.flatMap(_.split(" "))          // MapPartitionsRDD（窄依赖）
val rdd3 = rdd2.map(word => (word, 1))         // MapPartitionsRDD（窄依赖）
val rdd4 = rdd3.reduceByKey(_ + _)             // ShuffledRDD（宽依赖！）
val rdd5 = rdd4.filter(_._2 > 5)              // MapPartitionsRDD（窄依赖）
rdd5.collect()                                  // 触发 Action
```

### 画图

```
Stage 0 (ShuffleMapStage):
  textFile → flatMap → map → [Shuffle Write]
                                    │
                                    │ Shuffle (reduceByKey)
                                    │
Stage 1 (ResultStage):              ▼
                    [Shuffle Read] → reduceByKey → filter → collect
```

**结论**：
- 2 个 Stage
- 1 次 Shuffle
- Stage 0 中的 3 个算子（textFile/flatMap/map）被**流水线化**在一起执行

---

## 六、为什么窄依赖可以流水线化？

```
窄依赖的执行：
  读取 Part-0 的数据
    → 立即 flatMap
    → 立即 map
    → 写入 Shuffle 文件
  
  整个过程是"一条流水线"——数据不需要落盘等待！
  
宽依赖为什么不行？
  因为 reduceByKey 需要知道 key=hello 的所有数据在哪
  → 必须等所有上游分区都写完
  → 才能开始读取和聚合
  → 这就是"Shuffle Barrier"（Shuffle 屏障）
```

**类比**：窄依赖就像工厂流水线（前一步做完直接传后一步），宽依赖就像快递分拣中心（必须等所有快递到齐才能按目的地分拣）。

---

## 七、常见误区纠正

### 误区 1："join 一定产生宽依赖"

**错！** 如果两个 RDD 已经用**相同的 Partitioner** 分区过了（比如都做过 `partitionBy(new HashPartitioner(10))`），那么 join 是**窄依赖**，不产生 Shuffle。

### 误区 2："map 一定是窄依赖"

**对！** `map` 操作永远是窄依赖——每个输出分区只依赖一个输入分区。

### 误区 3："Stage 数 = Shuffle 数"

**错！** `Stage 数 = Shuffle 数 + 1`。因为最后还有一个 ResultStage。

---

## 八、课堂练习

### 练习 1：数 Stage

```scala
val a = sc.textFile("a.txt")
val b = sc.textFile("b.txt")
val c = a.map(x => (x, 1)).reduceByKey(_ + _)
val d = b.map(x => (x, 1)).reduceByKey(_ + _)
val e = c.join(d)
e.count()
```

问：有几个 Stage？几次 Shuffle？

**答案**：5 个 Stage，4 次 Shuffle
- Stage 0: a.map（ShuffleMapStage，为 a 的 reduceByKey 准备）
- Stage 1: b.map（ShuffleMapStage，为 b 的 reduceByKey 准备）
- Stage 2: a.reduceByKey（ShuffleMapStage，为 join 准备）
- Stage 3: b.reduceByKey（ShuffleMapStage，为 join 准备）
- Stage 4: join + count（ResultStage）

### 练习 2：举一反三

> "MapReduce 中的 Map 阶段和 Reduce 阶段，对应 Spark 中的什么概念？"

答：Map 阶段 ≈ ShuffleMapStage，Reduce 阶段 ≈ ResultStage。但 Spark 可以有多个 ShuffleMapStage 串联，MapReduce 只有一个 Map + 一个 Reduce。

---

## 九、知识晶体

```
问题/场景: 如何判断一段 Spark 代码会产生几次 Shuffle？
核心源码: Dependency.scala, DAGScheduler.scala
调用链: Action → DAGScheduler.submitJob → createResultStage → getOrCreateParentStages → 递归遍历依赖
设计意图: 宽依赖处需要数据重分区，窄依赖可流水线化，以此为边界划分 Stage 实现最大并行度
关键参数:
  spark.default.parallelism  → 默认分区数（影响 Shuffle 后的分区数）
  spark.sql.shuffle.partitions → SQL 场景下的 Shuffle 分区数（默认 200）
踩坑记录:
  - 过多的 Shuffle 是性能杀手，每次 Shuffle 都是一次全量磁盘 IO
  - 可以用 coalesce 代替 repartition 来减少分区（避免一次 Shuffle）
认知更新: Stage 划分本质是"流水线优化"——把可以连续执行的操作打包，遇到必须等待的点才切割
```

---

> **下课小结**：记住三句话：①窄依赖可流水线，宽依赖必须等 ②遇到宽依赖就切 Stage ③Stage 数 = Shuffle 数 + 1。掌握这三句话，你就能分析任何 Spark 作业的执行计划。
