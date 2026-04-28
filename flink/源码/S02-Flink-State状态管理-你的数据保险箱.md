# 教案 S02：Flink State 状态管理 — 你的数据保险箱

> **适用对象**：大数据开发/运维工程师 | **前置知识**：了解 Flink Checkpoint 基础  
> **课时**：45 分钟 | **难度**：⭐⭐⭐⭐

---

## 一、课前导入 — 你的实时计数器丢数了

> 你写了一个 Flink 作业统计每分钟的 PV 数。跑了 3 天一切正常，第 4 天作业重启后，计数器从 0 开始了！3 天的数据白算了。原因：你用了普通的 Java 变量，没有用 Flink 的状态 API。只有通过 Flink State API 管理的数据，才能被 Checkpoint 保存和恢复。

---

## 二、本课目标

1. **Keyed State 和 Operator State 有什么区别？** 分别在什么场景用？
2. **ValueState / ListState / MapState 怎么选？** 性能差异在哪？
3. **状态 TTL 怎么配？** 怎么防止状态无限增长撑爆内存？

---

## 三、核心概念 — 储物柜的比喻

把 Flink 的状态想象成一个**智能储物柜系统**：

| 类型 | 比喻 | 适用场景 |
|------|------|---------|
| **ValueState** | 每人一个小格子，放一样东西 | 记录每个用户的最后登录时间 |
| **ListState** | 每人一个抽屉，能放一串东西 | 记录每个订单的所有事件 |
| **MapState** | 每人一个文件柜，按 key 查找 | 记录每个用户的所有商品浏览次数 |
| **ReducingState** | 每人一个计算器，自动累加 | 实时 SUM/COUNT |
| **AggregatingState** | 每人一个高级计算器，支持自定义聚合 | 实时 AVG/自定义聚合 |

**Keyed State**：每个 key 有自己独立的储物柜（通过 keyBy 分区后使用）
**Operator State**：整个算子共享一个储物柜（如 Kafka Source 的 offset）

---

## 四、源码精讲

### 4.1 StateBackend 的两种实现

```
                    StateBackend
                    /          \
    HashMapStateBackend    EmbeddedRocksDBStateBackend
    (堆内存，快但小)         (RocksDB，慢但大)
```

**选型决策树**：
```
状态大小 > 单 TM 堆内存的 50%？
├── YES → 用 RocksDB，开启增量 Checkpoint
└── NO → 状态访问延迟敏感？
    ├── YES → 用 HashMap（微秒级访问）
    └── NO → 用 RocksDB（更安全）
```

### 4.2 状态 TTL — 防止状态爆炸

```java
// 配置状态自动过期
StateTtlConfig ttlConfig = StateTtlConfig
    .newBuilder(Time.days(7))                    // 7 天后过期
    .setUpdateType(UpdateType.OnReadAndWrite)    // 读写都刷新过期时间
    .setStateVisibility(NeverReturnExpired)      // 绝不返回过期数据
    .cleanupInRocksdbCompactFilter(1000)         // RocksDB Compaction 时清理
    .build();

ValueStateDescriptor<String> descriptor = new ValueStateDescriptor<>("user-state", String.class);
descriptor.enableTimeToLive(ttlConfig);
```

**老师画重点**：
- 不设 TTL 的 Keyed State 会**永远增长**，直到 OOM
- TTL 清理是**惰性**的 — 过期数据不会立即删除，而是在访问或 Compaction 时才删
- `cleanupFullSnapshot()` 在全量快照时清理（HashMap 后端专用）
- `cleanupInRocksdbCompactFilter()` 在 RocksDB Compaction 时清理（RocksDB 后端专用）

---

## 五、课堂练习

### 思考题 1：状态大小监控

> 你的 Flink 作业运行一周后，TaskManager 内存使用从 4GB 涨到了 12GB。怎么诊断是哪个状态在增长？

<details>
<summary>参考答案</summary>

1. **Flink Web UI → Task → State Size** — 查看每个 Operator 的状态大小
2. **Metrics** — `state.size` 指标，按算子名分组
3. **Checkpoint 大小趋势** — 如果 Checkpoint 文件越来越大，说明状态在增长
4. **对策**：给可疑的 Keyed State 加 TTL，或检查是否有 key 倾斜

</details>

### 思考题 2：HashMap vs RocksDB

> 如果你的 Flink 作业有 1 亿个 key，每个 key 的 ValueState 只有 100 字节，应该用 HashMap 还是 RocksDB？

<details>
<summary>参考答案</summary>

1 亿 × 100B = 10GB 裸数据 + Java 对象头开销（约 3-5 倍）= 30-50GB
- **HashMap**：需要 30-50GB 堆内存 → 可能 GC 严重，且单次 Checkpoint 要全量序列化
- **RocksDB**：只需少量堆内存（做缓存），数据存在磁盘。Checkpoint 可增量
- **结论**：选 RocksDB，开启增量 Checkpoint

</details>

---

## 六、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Flink State 状态管理                              │
├──────────────────────────────────────────────────┤
│  Keyed State: ValueState/ListState/MapState       │
│  Operator State: ListState/BroadcastState         │
│  Backend: HashMap(快/小) vs RocksDB(慢/大)        │
├──────────────────────────────────────────────────┤
│  TTL: 必须配！防止状态无限增长                      │
│  清理策略: 惰性删除 + Compaction/Snapshot 时清理    │
├──────────────────────────────────────────────────┤
│  生产经验:                                         │
│  - 1亿+ key → 必须 RocksDB + 增量 Checkpoint      │
│  - State 大小必须监控，Checkpoint 大小是信号        │
│  - MapState 比 ValueState<Map> 好！前者按 key 序列化│
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Flink 源码 | 最后更新：2026-04-29*
