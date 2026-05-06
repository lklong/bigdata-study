# 教案 S05：Flink BackPressure 背压 — 数据高速公路的堵车预警

> **课时**：40分钟 | **难度**：⭐⭐⭐

## 一、课前导入
> 你的 Flink 作业延迟突然从毫秒级飙升到分钟级。不是数据量变了，而是某个算子处理不过来了。上游数据像堵在高速公路上的车一样不断堆积——这就是背压。

## 二、核心概念 — 水管模型
背压就像水管系统：下游水管变细了（处理慢），水压会**反向传导**到上游。

InputGate（数据入口）有固定大小的 Buffer Pool：
- Buffer 满了 → 上游 ResultPartition 写不进去 → 上游算子阻塞 → 背压向上传播

## 三、诊断三板斧

| 指标 | 含义 | 阈值 |
|------|------|------|
| backPressuredTimeMsPerSecond | 每秒被压的毫秒数 | >500ms 为 HIGH |
| idleTimeMsPerSecond | 每秒空闲的毫秒数 | >500ms 说明上游慢 |
| busyTimeMsPerSecond | 每秒忙碌的毫秒数 | >800ms 说明自己是瓶颈 |

```
Step 1: 找到第一个 backPressured=HIGH 的算子
Step 2: 看它下游的 busyTime — 下游忙说明下游是瓶颈
Step 3: 看瓶颈算子的 CPU/GC/IO — 定位根因
```

## 四、常见根因与解法

| 根因 | 现象 | 解法 |
|------|------|------|
| 数据倾斜 | 部分 subtask busy 其他 idle | rebalance / 打散 key |
| 外部 IO 慢 | Sink 写入延迟高 | 异步 IO / 批量写 |
| GC 频繁 | TM 日志大量 GC | 增大内存 / 优化状态 |
| 序列化慢 | CPU 高但吞吐低 | 用 POJO 避免 Kryo |
| 窗口聚合量大 | 窗口触发时 CPU 飙高 | 增量聚合 ReduceFunction |

## 五、课堂练习
> Source 的 backPressured 很高，但所有中间算子的 busyTime 都很低，只有 Sink 的 busyTime 很高。这说明什么？

<details>
<summary>参考答案</summary>
Sink 是瓶颈，背压从 Sink 一直传导到 Source。验证：看 Sink 的写入延迟和吞吐量。常见原因：数据库连接池不够、HDFS IO 慢。
</details>

## 六、知识晶体
```
BackPressure = 下游慢 → Buffer满 → 上游阻塞 → 向上传播
诊断: 找第一个 HIGH → 看下游 busyTime → 定位根因
根因TOP3: 数据倾斜 / 外部IO / GC
```

*教案作者：Eric | 最后更新：2026-04-29*
