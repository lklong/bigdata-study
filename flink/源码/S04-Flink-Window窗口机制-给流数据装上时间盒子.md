# 教案 S04：Flink Window 窗口机制 — 给流数据装上时间盒子

> **适用对象**：大数据开发工程师 | **课时**：45 分钟 | **难度**：⭐⭐⭐

## 一、课前导入
> 流数据是无限的，但业务需要有限的结果。"每分钟订单量"、"每小时 GMV"——这些都需要把无限流切成有限的块来计算。Window 就是切块的工具。

## 二、四种窗口类型

| 类型 | 比喻 | 触发条件 | 适用场景 |
|------|------|---------|---------|
| **Tumbling** | 切面包（等宽不重叠） | 时间到 | 每分钟统计、每小时报表 |
| **Sliding** | 传送带上的滑动窗 | 每个滑动步长 | 最近5分钟的移动平均 |
| **Session** | 对话（gap 超时则关闭） | 超时无数据 | 用户会话分析 |
| **Global** | 整个宇宙（手动触发） | 自定义 Trigger | 特殊业务逻辑 |

## 三、源码核心：WindowOperator

> 源码：`flink-streaming-java/.../windowing/WindowOperator.java` (41KB)

```java
// WindowOperator 的核心处理流程
public void processElement(StreamRecord<IN> element) {
    // Step 1: WindowAssigner 决定这条数据属于哪个窗口
    Collection<W> windows = windowAssigner.assignWindows(element, timestamp);
    
    // Step 2: 把数据加入窗口的状态
    for (W window : windows) {
        windowState.add(element.getValue());  // 追加到窗口状态
    }
    
    // Step 3: Trigger 决定是否该输出了
    TriggerResult result = trigger.onElement(element, timestamp, window);
    if (result.isFire()) {
        emitWindowContents(window);  // 输出窗口结果
    }
    if (result.isPurge()) {
        windowState.clear();  // 清理窗口状态
    }
}
```

## 四、Trigger（触发器）— 窗口的闹钟

| Trigger | 触发时机 | 常用场景 |
|---------|---------|---------|
| EventTimeTrigger | Watermark 越过窗口结束时间 | Event Time 窗口默认 |
| ProcessingTimeTrigger | 系统时钟到达窗口结束时间 | Processing Time 窗口 |
| CountTrigger | 窗口内元素数达到阈值 | 按数量触发 |
| ContinuousEventTimeTrigger | 每隔固定事件时间触发一次 | 提前输出中间结果 |

## 五、课堂练习

### 思考题：窗口状态爆炸
> 你用 Session Window 处理用户行为数据，gap=30min。某个爬虫用户每秒发一条请求，永远不会超时。这个用户的 Session Window 会怎样？

<details>
<summary>参考答案</summary>

Session Window 永远不会关闭 → 状态无限增长 → 最终 OOM。
解决方案：
1. 在 Source 端过滤爬虫
2. 给 Session Window 设最大持续时间（自定义 Trigger）
3. 给状态设 TTL
</details>

## 六、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Flink Window = WindowAssigner + Trigger + Evictor│
│  四种窗口: Tumbling / Sliding / Session / Global  │
│  状态存储: 每个 key × 每个 window = 独立状态       │
│  生产经验: Session Window 必须防爬虫 + 状态TTL     │
└──────────────────────────────────────────────────┘
```

*教案作者：Eric | 最后更新：2026-04-29*
