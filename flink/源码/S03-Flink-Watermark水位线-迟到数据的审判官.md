# 教案 S03：Flink Watermark 水位线 — 迟到数据的审判官

> **适用对象**：大数据开发工程师 | **前置知识**：了解 Event Time 概念  
> **课时**：40 分钟 | **难度**：⭐⭐⭐

---

## 一、课前导入 — 外卖订单为什么算错了？

> 你的实时报表统计每分钟的订单数。一个用户在 12:00:05 下单，但由于网络延迟，这条数据在 12:01:30 才到达 Flink。你的 1 分钟窗口（12:00 - 12:01）已经关闭输出了，这条数据就**丢了**。
>
> Watermark 就是解决这个问题的——它告诉 Flink：**"到目前为止，我认为不会再有时间戳早于 W 的数据到来了"**。

---

## 二、核心概念 — 排队叫号的比喻

把 Watermark 想象成银行取号排队系统中的**叫号屏幕**：

- 当前叫号到 **42 号**（Watermark = 42）意味着：系统认为 42 号之前的客户都已经办理完毕了
- 如果突然来了一个 **35 号**（迟到数据），两种处理方式：
  1. **直接拒绝**："对不起，您已过号" → 数据丢弃
  2. **允许补办**："给您安排一个侧输出通道" → Side Output 处理迟到数据

```java
// Watermark 定义（源码 Watermark.java）
public class Watermark extends StreamElement {
    public static final Watermark MAX_WATERMARK = new Watermark(Long.MAX_VALUE);  // 终止信号
    public static final Watermark UNINITIALIZED = new Watermark(Long.MIN_VALUE);   // 初始值

    protected final long timestamp;  // 核心：这个时间戳之前的数据"应该"都到了
}
```

### Watermark 生成策略

| 策略 | 公式 | 适用场景 |
|------|------|---------|
| **单调递增** | W = 当前最大 EventTime | 数据严格有序 |
| **固定延迟** | W = 当前最大 EventTime - 允许延迟 | 大多数场景 |
| **自定义** | 用户自定义逻辑 | 数据乱序严重 |

```java
// 最常用：固定 5 秒延迟
WatermarkStrategy.<Event>forBoundedOutOfOrderness(Duration.ofSeconds(5))
    .withTimestampAssigner((event, timestamp) -> event.getTimestamp());
```

### 多流 Watermark 对齐

当一个算子有多个输入时，Watermark = **所有输入中最小的 Watermark**

```
Input 1: W=100  ─┐
                  ├─ Operator Watermark = min(100, 80) = 80
Input 2: W=80   ─┘
```

**隐患**：如果一个输入源停止发数据（空闲分区），它的 Watermark 永远不更新 → 整个算子的 Watermark 卡住！

**解决**：`withIdleness(Duration.ofMinutes(5))` — 5 分钟没数据的分区被标记为 idle，不参与 Watermark 计算

---

## 三、课堂练习

### 思考题：如何确定允许延迟的大小？

> 设置 `BoundedOutOfOrderness(5 seconds)` 意味着什么？设太大和太小各有什么后果？

<details>
<summary>参考答案</summary>

- **设太小**（如 1 秒）：很多迟到数据被丢弃，结果不准确
- **设太大**（如 10 分钟）：窗口延迟 10 分钟才输出结果，实时性差
- **确定方法**：分析历史数据中 99 分位的乱序延迟，设为该值 + 安全余量
- **兜底方案**：配合 `allowedLateness` + `sideOutputLateData` 处理超出 Watermark 的极端迟到数据

</details>

---

## 四、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Flink Watermark                                   │
├──────────────────────────────────────────────────┤
│  本质: 事件时间的进度指示器                         │
│  公式: W = maxEventTime - allowedDelay             │
│  传播: 多输入取 min，idle 源被排除                  │
│  迟到处理: 丢弃 / allowedLateness / sideOutput     │
├──────────────────────────────────────────────────┤
│  生产经验:                                         │
│  1. 必须设 withIdleness 防止 Kafka 空分区卡水位     │
│  2. 延迟值参考数据 P99 乱序延迟                     │
│  3. 关键业务用 sideOutput 捕获迟到数据              │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Flink 源码 | 最后更新：2026-04-29*
