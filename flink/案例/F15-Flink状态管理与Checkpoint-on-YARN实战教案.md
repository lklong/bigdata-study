# [教案] Flink on YARN — 状态管理与 Checkpoint 实战使用姿势

> 🎯 教学目标：掌握 Flink State Backend 选择、Checkpoint 配置调优、Savepoint 操作、状态 TTL、Checkpoint 失败排查 | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

| 场景 | 说明 |
|------|------|
| **容错恢复** | 任务异常重启后从 Checkpoint 恢复，不丢不重 |
| **精确一次语义** | 端到端 Exactly-Once 必须依赖 Checkpoint |
| **状态管理** | 窗口聚合、Join、去重等有状态计算 |
| **任务升级** | 修改代码后从 Savepoint 恢复 |
| **扩缩容** | 调整并行度后从 Savepoint 恢复 |

**核心概念**：
- **State**：算子的中间计算状态（如窗口数据、计数器）
- **Checkpoint**：State 的周期性持久化快照（自动触发，用于容错）
- **Savepoint**：State 的手动持久化快照（用于升级/迁移）

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.18+ | 推荐 1.18.1 |
| Hadoop/YARN | 3.x | |
| HDFS | 3.x | Checkpoint 存储 |
| Java | JDK 8/11 | |

### 2.2 环境准备命令

```bash
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)

# 创建 Checkpoint/Savepoint HDFS 目录
hdfs dfs -mkdir -p /flink/checkpoints
hdfs dfs -mkdir -p /flink/savepoints
hdfs dfs -chmod 777 /flink/checkpoints
hdfs dfs -chmod 777 /flink/savepoints

# 验证 HDFS 可写
hdfs dfs -touchz /flink/checkpoints/_test && hdfs dfs -rm /flink/checkpoints/_test
```

---

## 三、核心配置详解

### 3.1 State Backend 选择

| State Backend | 存储位置 | 适用场景 | 状态大小 | 性能 |
|---------------|----------|----------|----------|------|
| **HashMapStateBackend** | JVM 堆内存 | 状态小（<几GB）、对延迟敏感 | 小 | 极快 |
| **EmbeddedRocksDBStateBackend** | 磁盘(RocksDB) + HDFS | 状态大（GB~TB级）、生产首选 | 大 | 快 |

### 3.2 Checkpoint 核心参数详解

| 参数 | 说明 | 默认值 | 推荐值 |
|------|------|--------|--------|
| `execution.checkpointing.interval` | Checkpoint 触发间隔 | 无(关闭) | 60000ms |
| `execution.checkpointing.mode` | 一致性模式 | EXACTLY_ONCE | EXACTLY_ONCE |
| `execution.checkpointing.timeout` | 超时时间 | 600000ms | 300000ms |
| `execution.checkpointing.min-pause` | 两次 CK 最小间隔 | 0 | 30000ms |
| `execution.checkpointing.max-concurrent-checkpoints` | 最大并发 CK 数 | 1 | 1 |
| `execution.checkpointing.unaligned.enabled` | 非对齐 Checkpoint | false | true(大反压时) |
| `execution.checkpointing.tolerable-failed-checkpoints` | 可容忍失败次数 | 0 | 3~10 |
| `state.backend` | 状态后端 | hashmap | rocksdb |
| `state.checkpoints.dir` | CK 持久化路径 | 无 | hdfs:///flink/checkpoints |
| `state.savepoints.dir` | SP 持久化路径 | 无 | hdfs:///flink/savepoints |
| `state.backend.incremental` | 增量 CK (仅 RocksDB) | false | true |
| `state.backend.rocksdb.localdir` | RocksDB 本地路径 | tmp | /data/flink/rocksdb |

### 3.3 State TTL 参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `StateTtlConfig.newBuilder(Time)` | TTL 时长 | `Time.hours(24)` |
| `.setUpdateType(OnCreateAndWrite)` | 更新策略 | 创建和写入时刷新 |
| `.setStateVisibility(NeverReturnExpired)` | 过期可见性 | 不返回过期数据 |
| `.cleanupFullSnapshot()` | 全量快照时清理 | 适用 HashMap Backend |
| `.cleanupInRocksdbCompactFilter()` | RocksDB compaction 时清理 | 推荐 |

---

## 四、完整实战示例

### 4.1 代码中配置 Checkpoint + RocksDB

```java
import org.apache.flink.contrib.streaming.state.EmbeddedRocksDBStateBackend;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.environment.CheckpointConfig;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

public class CheckpointConfigExample {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // ===== 1. 设置 State Backend =====
        EmbeddedRocksDBStateBackend rocksDB = new EmbeddedRocksDBStateBackend(true); // true = 增量
        rocksDB.setDbStoragePath("/data/flink/rocksdb");
        env.setStateBackend(rocksDB);

        // ===== 2. Checkpoint 配置 =====
        // 启用 Checkpoint，间隔 60 秒
        env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);

        CheckpointConfig ckConfig = env.getCheckpointConfig();
        // Checkpoint 超时时间
        ckConfig.setCheckpointTimeout(300000);  // 5 分钟
        // 两次 Checkpoint 最小间隔
        ckConfig.setMinPauseBetweenCheckpoints(30000);  // 30 秒
        // 最大并发 Checkpoint 数
        ckConfig.setMaxConcurrentCheckpoints(1);
        // 可容忍的连续失败次数
        ckConfig.setTolerableCheckpointFailureNumber(5);
        // 任务取消时保留 Checkpoint
        ckConfig.setExternalizedCheckpointCleanup(
                CheckpointConfig.ExternalizedCheckpointCleanup.RETAIN_ON_CANCELLATION
        );
        // 非对齐 Checkpoint（高反压时使用）
        ckConfig.enableUnalignedCheckpoints();

        // ===== 3. Checkpoint 存储路径 =====
        ckConfig.setCheckpointStorage("hdfs:///flink/checkpoints/my-job");

        // ===== 4. 设置重启策略 =====
        env.setRestartStrategy(
                org.apache.flink.api.common.restartstrategy.RestartStrategies
                        .exponentialDelayRestart(
                                org.apache.flink.api.common.time.Time.seconds(1),   // 初始延迟
                                org.apache.flink.api.common.time.Time.seconds(60),  // 最大延迟
                                2.0,    // 指数倍增因子
                                org.apache.flink.api.common.time.Time.hours(1),     // 重置间隔
                                0.1     // 抖动因子
                        )
        );

        // ... 业务逻辑 ...

        env.execute("Checkpoint-Config-Demo");
    }
}
```

### 4.2 State TTL 配置示例

```java
import org.apache.flink.api.common.state.StateTtlConfig;
import org.apache.flink.api.common.state.ValueState;
import org.apache.flink.api.common.state.ValueStateDescriptor;
import org.apache.flink.api.common.time.Time;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.streaming.api.functions.KeyedProcessFunction;

public class StateTtlExample extends KeyedProcessFunction<String, OrderEvent, String> {

    private transient ValueState<Long> orderCountState;
    private transient ValueState<Double> totalAmountState;

    @Override
    public void open(Configuration parameters) {
        // 配置 State TTL: 24 小时过期
        StateTtlConfig ttlConfig = StateTtlConfig.newBuilder(Time.hours(24))
                .setUpdateType(StateTtlConfig.UpdateType.OnCreateAndWrite)
                .setStateVisibility(StateTtlConfig.StateVisibility.NeverReturnExpired)
                .cleanupInRocksdbCompactFilter(1000)  // 每 1000 条检查一次
                .build();

        // 订单计数状态
        ValueStateDescriptor<Long> countDesc = new ValueStateDescriptor<>("order-count", Long.class);
        countDesc.enableTimeToLive(ttlConfig);
        orderCountState = getRuntimeContext().getState(countDesc);

        // 总金额状态
        ValueStateDescriptor<Double> amountDesc = new ValueStateDescriptor<>("total-amount", Double.class);
        amountDesc.enableTimeToLive(ttlConfig);
        totalAmountState = getRuntimeContext().getState(amountDesc);
    }

    @Override
    public void processElement(OrderEvent event, Context ctx, Collector<String> out) throws Exception {
        Long count = orderCountState.value();
        Double amount = totalAmountState.value();

        count = (count == null) ? 1L : count + 1;
        amount = (amount == null) ? event.getAmount() : amount + event.getAmount();

        orderCountState.update(count);
        totalAmountState.update(amount);

        out.collect(String.format("User=%s, Orders=%d, TotalAmount=%.2f",
                event.getUserId(), count, amount));
    }
}
```

### 4.3 Flink SQL 中配置 Checkpoint 和 State TTL

```sql
-- Checkpoint 配置
SET 'execution.checkpointing.interval' = '60s';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.timeout' = '300s';
SET 'execution.checkpointing.min-pause' = '30s';
SET 'execution.checkpointing.tolerable-failed-checkpoints' = '5';

-- State Backend
SET 'state.backend' = 'rocksdb';
SET 'state.backend.incremental' = 'true';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints/sql-job';
SET 'state.savepoints.dir' = 'hdfs:///flink/savepoints/sql-job';

-- State TTL（SQL 中通过 table.exec.state.ttl 配置）
SET 'table.exec.state.ttl' = '86400000';  -- 24 小时（毫秒）

-- 示例: 带 State TTL 的聚合查询
SELECT
    user_id,
    TUMBLE_START(order_time, INTERVAL '1' MINUTE) AS window_start,
    COUNT(*) AS order_count,
    SUM(amount) AS total_amount
FROM kafka_orders
GROUP BY user_id, TUMBLE(order_time, INTERVAL '1' MINUTE);
```

### 4.4 Application Mode 完整提交命令

```bash
# 完整提交命令（包含所有 Checkpoint 配置）
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Stateful-Checkpoint-Job" \
    -Dyarn.application.queue=default \
    \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.backend.rocksdb.localdir=/data/flink/rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/stateful-job \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/stateful-job \
    \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dexecution.checkpointing.timeout=300000 \
    -Dexecution.checkpointing.min-pause=30000 \
    -Dexecution.checkpointing.max-concurrent-checkpoints=1 \
    -Dexecution.checkpointing.tolerable-failed-checkpoints=5 \
    -Dexecution.checkpointing.externalized-checkpoint-retention=RETAIN_ON_CANCELLATION \
    -Dexecution.checkpointing.unaligned.enabled=true \
    \
    -Drestart-strategy.type=exponential-delay \
    -Drestart-strategy.exponential-delay.initial-backoff=1s \
    -Drestart-strategy.exponential-delay.max-backoff=60s \
    \
    -c com.example.StatefulJob \
    /path/to/stateful-job-1.0.jar
```

### 4.5 Savepoint 操作命令大全

```bash
# ===== 创建 Savepoint =====
# 方式1: 通过 Flink CLI（需要知道 Job ID）
$FLINK_HOME/bin/flink savepoint <jobId> hdfs:///flink/savepoints/manual \
    -yid application_xxxxx_xxxx

# 方式2: 通过 REST API
curl -X POST http://jm-host:8081/jobs/<jobId>/savepoints \
    -d '{"cancel-job": false, "target-directory": "hdfs:///flink/savepoints/manual"}'

# ===== 停止任务并创建 Savepoint（优雅停止） =====
$FLINK_HOME/bin/flink stop --savepointPath hdfs:///flink/savepoints/upgrade \
    <jobId> -yid application_xxxxx_xxxx

# ===== 从 Savepoint 恢复 =====
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -s hdfs:///flink/savepoints/upgrade/savepoint-xxxxxx \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/stateful-job \
    -c com.example.StatefulJob \
    /path/to/stateful-job-2.0.jar

# ===== 从 Checkpoint 恢复（任务异常退出时） =====
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -s hdfs:///flink/checkpoints/stateful-job/xxxxxxxx \
    --allowNonRestoredState \
    -c com.example.StatefulJob \
    /path/to/stateful-job-2.0.jar

# ===== 列出 HDFS 上的 Savepoint/Checkpoint =====
hdfs dfs -ls /flink/savepoints/
hdfs dfs -ls /flink/checkpoints/stateful-job/
```

### 4.6 验证 Checkpoint 工作正常

```bash
# 1. 查看 Flink Web UI（通过 YARN Proxy）
# http://yarn-rm:8088/proxy/application_xxxxx_xxxx/#/overview

# 2. 查看 Checkpoint 历史
curl http://yarn-rm:8088/proxy/application_xxxxx_xxxx/jobs/<jobId>/checkpoints

# 3. 查看 HDFS 上的 Checkpoint 文件
hdfs dfs -ls -R /flink/checkpoints/stateful-job/ | head -20

# 4. 查看 Checkpoint 大小趋势
hdfs dfs -ls /flink/checkpoints/stateful-job/ | awk '{print $5, $8}' | sort -n

# 5. 查看日志中 Checkpoint 相关信息
yarn logs -applicationId application_xxxxx_xxxx | grep -i "checkpoint completed\|checkpoint expired\|checkpoint declined"
```

---

## 五、常见问题与排障

### 5.1 Checkpoint 失败原因速查

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `Checkpoint expired before completing` | Checkpoint 超时 | 增大 `timeout`，减少状态大小 |
| `Checkpoint was declined (Task not running)` | Task 异常退出 | 查看 TM 日志，排查 OOM |
| `Failed to write checkpoint` | HDFS 写入失败 | 检查 HDFS 健康状态，磁盘空间 |
| `Barriers could not be aligned` | 反压严重 | 启用 Unaligned Checkpoint |
| 增量 CK 越来越大 | RocksDB compaction 不及时 | 增大 TM 内存/磁盘，调优 RocksDB |
| `OutOfMemoryError` during CK | 状态太大，堆内存不足 | 切换到 RocksDB Backend |
| Savepoint 恢复失败 | 算子 UID 变化 | 为算子设置 `.uid("xxx")` |
| `State migration not supported` | 状态序列化格式变化 | 使用兼容的序列化器 |

### 5.2 Checkpoint 性能分析

```bash
# 通过 REST API 查看 Checkpoint 详情
curl -s http://jm-host:8081/jobs/<jobId>/checkpoints | python -m json.tool

# 关键指标:
# - end_to_end_duration: 端到端耗时（应 < checkpoint interval 的 50%）
# - state_size: 状态大小（关注增长趋势）
# - alignment_buffered: 对齐缓冲数据量（大说明反压严重）
# - sync_duration: 同步阶段耗时
# - async_duration: 异步阶段耗时

# 判断标准:
# - 正常: end_to_end_duration < 30s (interval=60s 时)
# - 警告: end_to_end_duration > 50% of interval
# - 危险: end_to_end_duration > interval（会导致 Checkpoint 堆积）
```

### 5.3 RocksDB 调优

```yaml
# flink-conf.yaml 中 RocksDB 优化配置
state.backend.rocksdb.localdir: /data1/flink/rocksdb,/data2/flink/rocksdb  # 多磁盘
state.backend.rocksdb.memory.managed: true   # 使用 Flink 管理内存
state.backend.rocksdb.memory.fixed-per-slot: 256mb  # 每 slot 分配内存
state.backend.rocksdb.block.cache-size: 64mb         # Block Cache
state.backend.rocksdb.writebuffer.size: 64mb         # Write Buffer
state.backend.rocksdb.writebuffer.count: 3           # Write Buffer 数量
state.backend.rocksdb.compaction.level.max-size-level-base: 256mb
state.backend.rocksdb.thread.num: 4                  # 后台线程数
```

---

## 六、生产最佳实践

### 6.1 增量 vs 全量 Checkpoint

| 维度 | 全量 Checkpoint | 增量 Checkpoint |
|------|----------------|----------------|
| 方式 | 每次写入完整状态 | 只写入变化部分(delta) |
| CK 大小 | 大（= 总状态） | 小（= 增量变化） |
| CK 耗时 | 长 | 短 |
| 恢复速度 | 快（直接读） | 慢（需合并多个增量） |
| 适用场景 | 状态小 | 状态大（**生产推荐**） |
| 要求 | 任意 Backend | 仅 RocksDB |

### 6.2 生产推荐配置模板

```yaml
# ===== 状态管理 =====
state.backend: rocksdb
state.backend.incremental: true
state.backend.rocksdb.localdir: /data/flink/rocksdb
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints

# ===== Checkpoint =====
execution.checkpointing.interval: 60000
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 300000
execution.checkpointing.min-pause: 30000
execution.checkpointing.max-concurrent-checkpoints: 1
execution.checkpointing.tolerable-failed-checkpoints: 5
execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
execution.checkpointing.unaligned.enabled: true

# ===== 重启策略 =====
restart-strategy.type: exponential-delay
restart-strategy.exponential-delay.initial-backoff: 1s
restart-strategy.exponential-delay.max-backoff: 60s
restart-strategy.exponential-delay.backoff-multiplier: 2.0
restart-strategy.exponential-delay.reset-backoff-threshold: 1h
restart-strategy.exponential-delay.jitter-factor: 0.1
```

### 6.3 算子 UID 最佳实践

```java
// 为所有有状态算子设置 UID（Savepoint 恢复依赖此 UID）
env.fromSource(kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-source")
        .uid("kafka-source-uid")
        .map(new MyMapFunction())
        .uid("map-function-uid")
        .keyBy(event -> event.getUserId())
        .window(TumblingEventTimeWindows.of(Time.minutes(1)))
        .aggregate(new MyAggregateFunction())
        .uid("window-agg-uid")
        .addSink(new MySink())
        .uid("sink-uid");

// 规则: 一旦上线，UID 不能变！否则 Savepoint 无法恢复
```

### 6.4 监控指标

```yaml
# 重点监控:
# 1. lastCheckpointDuration — CK 耗时
# 2. numberOfCompletedCheckpoints — 成功次数
# 3. numberOfFailedCheckpoints — 失败次数（> 0 告警）
# 4. lastCheckpointSize — CK 大小（关注增长趋势）
# 5. checkpointAlignmentTime — 对齐耗时（大说明反压）

# Grafana 告警规则:
# - CK 连续失败 > 3 次 → P1
# - CK 耗时 > 50% interval → P2
# - CK 大小 1 小时增长 > 50% → P2
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: Checkpoint 和 Savepoint 的区别？**

| 维度 | Checkpoint | Savepoint |
|------|-----------|-----------|
| 触发方式 | 自动周期触发 | 手动触发 |
| 用途 | 容错恢复 | 升级/迁移/扩缩容 |
| 格式 | 优化过的内部格式 | 标准可移植格式 |
| 清理 | 可配置自动清理 | 手动清理 |
| 增量支持 | 支持 | 总是全量 |

**Q2: Unaligned Checkpoint 解决什么问题？**

> 普通 Aligned CK：需要等待所有 Channel 的 Barrier 对齐，反压时对齐慢 → CK 超时。
> Unaligned CK：不等对齐，直接快照 + 缓冲区数据一起持久化 → 即使反压也能快速 CK。
> 代价：CK 文件更大（包含了缓冲区数据），恢复更慢。

**Q3: 为什么推荐增量 Checkpoint？**

> 状态大（几十GB）时，全量 CK 每次都要上传全部状态，耗时长且占带宽。
> 增量 CK 只上传 RocksDB 的 SST 文件差异，大大减少 IO。
> 缺点：恢复时需要回溯多个增量，但可通过定期全量合并缓解。

### 7.2 思考题

1. 如果 Checkpoint 存储的 HDFS 目录满了，会发生什么？如何优雅处理？
2. 增量 Checkpoint 越积越多，恢复越来越慢，如何优化？
3. 非对齐 Checkpoint 在哪些场景下不适用？
4. 如何实现「零停机升级」——修改业务逻辑但保持状态？

---

> 📝 **本教案配套代码仓库**: [bigdata-study/flink/案例/](https://github.com/lklong/bigdata-study/tree/main/flink/案例/)
> 📅 **更新日期**: 2026-04-30
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
