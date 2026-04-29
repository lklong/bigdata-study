# 教案 14：Spark Shuffle 全链路 — 性能瓶颈的万恶之源

> **课时**：50分钟 | **难度**：⭐⭐⭐⭐⭐

## 一、课前导入

> "Spark 作业慢？80% 的原因在 Shuffle。" Shuffle 是 Map 端输出数据经过网络传输到 Reduce 端的过程。它涉及**磁盘写入、网络传输、内存管理**三大瓶颈。

## 二、Shuffle 全景图

```
Map Task (Executor A)                    Reduce Task (Executor B)
┌──────────────────┐                    ┌──────────────────┐
│ 计算结果          │                    │                  │
│      │           │                    │  ShuffleReader    │
│      ▼           │                    │      │           │
│ ShuffleWriter    │                    │      ▼           │
│ ┌──────────────┐ │                    │ 拉取远程数据     │
│ │ 排序+分区     │ │    网络传输         │      │           │
│ │ 溢写到磁盘   │ ├───────────────────→│      ▼           │
│ │ 生成索引文件 │ │    (Netty/NIO)     │ 合并+聚合        │
│ └──────────────┘ │                    │                  │
└──────────────────┘                    └──────────────────┘
```

## 三、三种 ShuffleWriter

| Writer | 适用条件 | 机制 |
|--------|---------|------|
| **BypassMergeSortShuffleWriter** | 分区数 ≤ 200 且无 Map 端聚合 | 每个分区一个文件，最后 merge |
| **UnsafeShuffleWriter** | 序列化后的记录可排序 + 无聚合 | 基于 Tungsten 内存，高效 |
| **SortShuffleWriter** | 通用情况 | 内存排序 + 溢写合并 |

## 四、关键优化参数

| 参数 | 默认值 | 作用 | 调优 |
|------|--------|------|------|
| `spark.shuffle.file.buffer` | 32KB | 写文件的缓冲区 | 调大到 64KB-128KB |
| `spark.reducer.maxSizeInFlight` | 48MB | Reduce 端拉取缓冲 | 调大到 96MB |
| `spark.shuffle.sort.bypassMergeThreshold` | 200 | Bypass 阈值 | 分区少可调大 |
| `spark.shuffle.compress` | true | 是否压缩 | 保持 true |
| `spark.shuffle.spill.compress` | true | 溢写是否压缩 | 保持 true |
| `spark.sql.shuffle.partitions` | 200 | SQL Shuffle 分区数 | 按数据量调整 |

## 五、Shuffle 性能诊断

```
Spark UI → Stage → Shuffle Read / Write 指标:
- Shuffle Write Time: Map 端写磁盘时间
- Shuffle Read Blocked Time: Reduce 端等待数据时间
- Fetch Wait Time: 网络拉取等待

诊断:
Write Time 长 → 磁盘 IO 瓶颈 → 用 SSD / 增大 buffer
Blocked Time 长 → 网络瓶颈 → 增大 maxSizeInFlight / 用 Celeborn
数据倾斜 → 某些 Reduce Task 的 Shuffle Read 远大于平均
```

## 六、External Shuffle Service vs Celeborn

| | ESS (传统) | Celeborn (新一代) |
|--|--|--|
| 架构 | NM 上的服务 | 独立 Worker 集群 |
| 存储 | 本地磁盘 | Worker 磁盘（可多副本） |
| Executor 退出 | 数据在 ESS，不影响 | 数据在 Worker，不影响 |
| 性能 | 受单机磁盘限制 | Push-Based，网络利用率高 |
| 适用 | YARN 环境 | K8s + 大规模 Shuffle |

## 七、课堂练习

### 思考题：`spark.sql.shuffle.partitions=200` 对所有查询都合适吗？

<details>
<summary>参考答案</summary>

绝对不合适！
- 数据量 1MB，200 分区 → 每个分区 5KB → 大量小 Task 开销 > 计算本身
- 数据量 1TB，200 分区 → 每个分区 5GB → 单 Task 处理太慢，容易 OOM

最佳实践：
- 开启 AQE（自动合并小分区）
- 或手动计算：`partitions = 总Shuffle数据量 / 128MB`
- Spark 3.2+ 用 `spark.sql.adaptive.coalescePartitions.initialPartitionNum=1000` 初始设大，AQE 自动合并
</details>

## 八、知识晶体

```
Shuffle = Map端写(Sort+Spill) → 网络传输 → Reduce端读(Merge)
三种Writer: Bypass(分区少) / Unsafe(Tungsten) / Sort(通用)
性能瓶颈: 磁盘IO + 网络传输 + 数据倾斜
调优: buffer调大 + AQE + partitions按数据量算 + Celeborn
```

*教案作者：Eric | 最后更新：2026-04-30*
