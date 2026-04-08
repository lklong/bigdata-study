# Flink 背压排查实战案例

> Flink Expert 案例学习 — 生产环境背压问题诊断与修复

## 案例背景

```
环境: Flink 1.15 on YARN, 32 TaskManagers, 每个 4 slots
作业: Kafka → Flink (keyBy + window + aggregate) → HBase
现象: 
  - 消费延迟从 0 飙升到 30 分钟
  - Checkpoint 频繁超时 (10 分钟)
  - TaskManager CPU 使用率 < 30%（不是 CPU 瓶颈）
```

## 排查过程

### Step 1: 确认背压位置

```
Flink Web UI → Job Graph → 背压面板:

Source (Kafka) → [Map] → [KeyBy] → [Window] → [Sink (HBase)]
   🟢 OK          🟢       🔴 HIGH   🟡 LOW     🟢 OK

背压在 KeyBy → Window 之间最严重
```

### Step 2: 分析背压原因

```
可能原因:
  ① 数据倾斜: 某些 key 的数据量远大于其他 key
  ② Window 状态太大: 窗口内数据量太多
  ③ 下游 HBase 写入慢: Sink 阻塞导致上游背压
  ④ GC 导致 TaskManager 暂停

排查:
  # 1. 检查各 subtask 的处理速率
  Flink UI → Task → Subtasks → Records/s
  → subtask-15: 500 records/s (其他都是 5000+) → 数据倾斜！

  # 2. 确认倾斜 key
  在 Map 算子后加计数:
    .map(x => { MetricGroup.counter(x.key).inc(); x })
  → key="hot_user_123" 占总数据量的 40%

  # 3. RocksDB 状态大小
  通过 JMX/Metrics 检查:
    flink.taskmanager.job.task.operator.state_size
  → subtask-15 的状态 50GB，其他 subtask 平均 2GB
```

### Step 3: 修复

```java
// 方案1: 两阶段聚合（打散热点 key）
stream
  .map(event -> {
      // 第一阶段: 给热点 key 加随机后缀打散
      String newKey = event.key + "_" + ThreadLocalRandom.current().nextInt(10);
      return new KeyedEvent(newKey, event);
  })
  .keyBy(e -> e.key)
  .window(TumblingEventTimeWindows.of(Time.minutes(5)))
  .aggregate(new PreAggregator())  // 预聚合
  .map(result -> {
      // 第二阶段: 去掉后缀恢复原始 key
      result.key = result.key.split("_")[0];
      return result;
  })
  .keyBy(e -> e.key)
  .window(TumblingEventTimeWindows.of(Time.minutes(5)))
  .aggregate(new FinalAggregator()); // 最终聚合
```

### Step 4: 效果

```
修复前: 消费延迟 30 分钟, Checkpoint 超时率 80%
修复后: 消费延迟 < 10 秒, Checkpoint 全部成功 (平均 15s)

根因: 单个 key 占 40% 数据量导致单 subtask 成为瓶颈
经验: keyBy 前必须检查 key 分布，热点 key 用两阶段聚合打散
```

## 经验规则

```
R-FLINK-001: keyBy 前必检 key 分布，top 1% key 不能占 > 10% 数据
R-FLINK-002: 背压排查顺序 — 先看 subtask 均衡性，再看 GC，最后看下游
R-FLINK-003: 大状态 + 背压 → 考虑开启非对齐 Checkpoint
R-FLINK-004: HBase Sink 批量写入用 BufferedMutator，不要逐条 Put
```

---

*Flink Expert 案例产出 | 2026-04-08*
