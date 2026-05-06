# 第十一课：Broadcast 广播变量实现原理

> **教学目标**：学完本课后，你能解释广播变量如何避免"每个 Task 都拷贝一份大数据"的问题，理解 TorrentBroadcast 的 P2P 分发机制。

---

## 一、先讲个故事（白话层）

假设你是一个老师，要给 1000 个学生发同一份考试卷：

**笨方法（不用广播）**：你站在讲台上，每个学生排队来拿一份。1000 个学生 = 你复印 1000 次 = Driver 给每个 Task 发一份 = 网络爆炸！

**聪明方法（Broadcast）**：你复印 10 份给 10 个班长，每个班长再复印 10 份给 10 个组长，组长再发给组员。这就是 **P2P 分发**（TorrentBroadcast）——每个人只需要从最近的人那里拿，不需要全找老师。

---

## 二、为什么需要广播变量？

```scala
// ❌ 不好的做法：大表数据在闭包中被序列化 1000 次
val bigMap = Map("a" -> 1, "b" -> 2, ... /* 100MB */)
rdd.map(x => bigMap(x))  // bigMap 被序列化到每个 Task 中！
// 如果有 1000 个 Task → 100MB × 1000 = 100GB 网络传输！

// ✅ 好的做法：广播一次，所有 Task 共享
val bigMapBc = sc.broadcast(bigMap)  // 只广播一次
rdd.map(x => bigMapBc.value(x))     // 每个 Executor 只保存一份
// 如果有 50 个 Executor → 100MB × 50 = 5GB 网络传输！节省 20 倍！
```

## 三、TorrentBroadcast — P2P 分发机制

```
Driver 端：
  ① 将数据切成小块（默认 4MB/块）
  ② 块存入 Driver 的 BlockManager
  ③ 返回 BroadcastId 给用户

Executor 端（第一次访问 .value 时）：
  ① 检查本地 BlockManager 有没有 → 有则直接返回
  ② 没有 → 去 Driver 或其他 Executor 拉取各个块
  ③ 每拉到一个块，立即注册到自己的 BlockManager
  ④ 其他 Executor 后续可以从我这里拉取（P2P！）
  ⑤ 所有块拉齐后，反序列化还原完整数据

分发过程（像 BitTorrent 下载）：
  时间 T1: 只有 Driver 有数据
  时间 T2: Executor-1 从 Driver 拉到 Block-0, Executor-2 拉到 Block-1
  时间 T3: Executor-3 可以从 Executor-1 拉 Block-0（不需要找 Driver！）
  → 像病毒传播一样，越来越快！
```

## 四、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.broadcast.blockSize` | `4m` | 切块大小，太小增加块数量开销，太大减少并行度 |
| `spark.broadcast.compress` | `true` | 是否压缩广播数据 |

## 五、使用场景与反模式

| 场景 | 是否应该广播 | 原因 |
|------|------------|------|
| 100MB 的维度表做 Map-Side Join | ✅ **必须广播** | 避免 Shuffle |
| 10KB 的配置 Map | ⚠️ 可以但不必 | 数据太小，闭包传输也没多大开销 |
| 5GB 的大表 | ❌ **不要广播** | 超出 Executor 内存，OOM |
| RDD（而非普通变量） | ❌ **不能广播 RDD** | 广播的是 Driver 端的值，不是分布式数据 |

## 六、课堂练习

### 练习 1：计算网络传输量

> 一个 200MB 的 Map，50 个 Executor，每个 Executor 运行 20 个 Task（共 1000 个 Task）。
> 不用广播 vs 用广播，分别需要多少网络传输？

答：
- 不用广播：200MB × 1000 Task = **200GB**（每个 Task 闭包包含一份）
- 用广播：200MB × 50 Executor = **10GB**（每个 Executor 只拉一份）
- 节省：200GB → 10GB = **20 倍**

### 练习 2：举一反三

> "Hadoop 的 DistributedCache 与 Spark 的 Broadcast 有什么同构关系？"

答：都是"大数据广播"机制，但实现不同：
- DistributedCache：文件存到 HDFS，每个节点下载到本地磁盘
- Broadcast：P2P 分发，不需要所有节点都去 HDFS 下载

---

## 七、知识晶体

```
问题/场景: 如何高效地在所有 Task 间共享大的只读数据？
核心源码: TorrentBroadcast.scala, BlockManager.scala
调用链: sc.broadcast(value) → TorrentBroadcast.writeBlocks() → [P2P 分发] → TorrentBroadcast.readBroadcastBlock()
设计意图: 通过 P2P 分发避免 Driver 成为瓶颈，O(log N) 的分发效率
踩坑记录:
  - 广播变量是只读的，修改了本地副本不会同步到其他 Executor
  - 大广播变量会长期占用 Executor 内存，记得 unpersist()
  - Spark SQL 的 BroadcastHashJoin 自动使用广播，阈值由 spark.sql.autoBroadcastJoinThreshold 控制（默认 10MB）
```
