# [教案] Flink on YARN — 状态管理与 Checkpoint 实战使用姿势

> 🎯 教学目标：掌握 Flink 状态管理与 Checkpoint 机制，包括 HashMap/RocksDB StateBackend 选择与调优、CP 配置详解、增量/全量 CP、非对齐 CP、Savepoint 操作、状态 TTL、CP 失败排查 | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 什么是 Flink 状态？为什么重要？

**生活类比**：想象你在玩一个在线游戏，游戏进度（等级、装备、金币）就是"状态"。如果服务器崩溃了，你希望能从上次的进度继续，而不是从头开始——这就是 Checkpoint 做的事。

Flink 中的状态包括：
- 窗口聚合中间结果（如：过去5分钟的订单总额）
- KeyedState（如：每个用户的最后登录时间）
- Operator State（如：Kafka Consumer 的 offset）

**没有状态管理 = 流处理无法保证 Exactly-Once = 不能用于生产！**

### 1.2 核心概念速览

| 概念 | 说明 |
|------|------|
| State Backend | 状态存储引擎（HashMapStateBackend / EmbeddedRocksDBStateBackend） |
| Checkpoint | 定时快照（分布式一致性快照，基于 Chandy-Lamport 算法） |
| Savepoint | 手动触发的"存档点"（用于升级/迁移） |
| Barrier | CP 标记，随数据流传播实现一致性快照 |
| Aligned CP | 对齐 CP（等待所有输入通道 Barrier 对齐） |
| Unaligned CP | 非对齐 CP（不等待，Barrier 直接穿过缓冲数据） |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 要求 |
|------|------|
| Flink | 1.15+ |
| HDFS | 用于存储 CP/SP 文件 |
| 本地磁盘 | RocksDB 需要 SSD（推荐） |

### 2.2 HDFS 目录准备

```bash
hdfs dfs -mkdir -p /flink/checkpoints
hdfs dfs -mkdir -p /flink/savepoints
hdfs dfs -chmod 777 /flink/checkpoints
hdfs dfs -chmod 777 /flink/savepoints
```

---

## 三、核心使用方式

### 3.1 State Backend 选择

#### HashMap State Backend（内存型）

```yaml
# flink-conf.yaml
state.backend: hashmap
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints
```

```java
// Java 代码方式
env.setStateBackend(new HashMapStateBackend());
env.getCheckpointConfig().setCheckpointStorage("hdfs:///flink/checkpoints");
```

**特点**：
- 状态存储在 TM 堆内存中
- 读写速度快（纯内存操作）
- 受限于 JVM 堆大小（适合小状态 < 几GB）
- CP 时全量序列化到 HDFS

#### RocksDB State Backend（磁盘型，推荐生产）

```yaml
# flink-conf.yaml
state.backend: rocksdb
state.backend.rocksdb.localdir: /data/flink/rocksdb
state.backend.incremental: true
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints
```

```java
// Java 代码方式
EmbeddedRocksDBStateBackend rocksDB = new EmbeddedRocksDBStateBackend(true); // true=增量CP
env.setStateBackend(rocksDB);
env.getCheckpointConfig().setCheckpointStorage("hdfs:///flink/checkpoints");
```

**特点**：
- 状态存储在本地磁盘（RocksDB LSM-Tree）
- 支持超大状态（TB 级）
- 读写速度比内存慢（需要序列化/反序列化）
- 支持增量 Checkpoint（只上传变更的 SST 文件）

### 3.2 State Backend 对比

| 维度 | HashMapStateBackend | EmbeddedRocksDBStateBackend |
|------|--------------------|-----------------------------|
| 存储介质 | JVM Heap | 本地磁盘(RocksDB) |
| 状态大小上限 | ~几GB（受堆限制） | TB 级 |
| 读写性能 | 极快（内存） | 中等（磁盘+序列化） |
| CP 方式 | 全量 | 增量（推荐）/ 全量 |
| CP 大小 | 等于状态大小 | 只含变更 SST |
| 适用场景 | 小状态、低延迟 | 大状态、生产环境 |
| 资源需求 | 大堆内存 | SSD 磁盘 + 适量内存 |

### 3.3 Checkpoint 配置详解

```java
// 完整 CP 配置
StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

// 开启 Checkpoint
env.enableCheckpointing(60000); // 60秒间隔

CheckpointConfig cpConfig = env.getCheckpointConfig();

// CP 模式
cpConfig.setCheckpointingMode(CheckpointingMode.EXACTLY_ONCE);

// CP 超时
cpConfig.setCheckpointTimeout(600000); // 10分钟

// 最小间隔（上一次CP完成到下一次CP开始的最小时间）
cpConfig.setMinPauseBetweenCheckpoints(30000); // 30秒

// 最大并发CP数
cpConfig.setMaxConcurrentCheckpoints(1);

// CP 失败容忍次数
cpConfig.setTolerableCheckpointFailureNumber(3);

// 外部化 CP（作业取消后保留CP文件）
cpConfig.setExternalizedCheckpointCleanup(
    ExternalizedCheckpointCleanup.RETAIN_ON_CANCELLATION
);

// 非对齐 CP
cpConfig.enableUnalignedCheckpoints();
cpConfig.setAlignedCheckpointTimeout(Duration.ofSeconds(30));
```

#### flink-conf.yaml 等价配置

```yaml
execution.checkpointing.interval: 60000
execution.checkpointing.mode: EXACTLY_ONCE
execution.checkpointing.timeout: 600000
execution.checkpointing.min-pause: 30000
execution.checkpointing.max-concurrent-checkpoints: 1
execution.checkpointing.tolerable-failed-checkpoints: 3
execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
execution.checkpointing.unaligned.enabled: true
execution.checkpointing.aligned-checkpoint-timeout: 30s
state.backend: rocksdb
state.backend.incremental: true
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints
state.checkpoints.num-retained: 3
```

### 3.4 核心参数对照表

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `interval` | - | 60000~120000 | CP 触发间隔(ms) |
| `timeout` | 600000 | 600000~1200000 | CP 超时时间 |
| `min-pause` | 0 | interval/2 | 两次 CP 最小间隔 |
| `max-concurrent` | 1 | 1 | 最大并发 CP 数 |
| `tolerable-failed` | 0 | 3~10 | 容忍 CP 失败次数 |
| `num-retained` | 1 | 3 | 保留的历史 CP 数量 |
| `unaligned.enabled` | false | 按需开启 | 反压严重时开启 |

---

## 四、完整实战示例

### 4.1 场景一：RocksDB + 增量 CP 配置

#### SQL 方式

```sql
-- 在 SQL Client 中设置
SET execution.checkpointing.interval = 60000;
SET execution.checkpointing.mode = EXACTLY_ONCE;
SET execution.checkpointing.min-pause = 30000;
SET execution.checkpointing.timeout = 600000;
SET execution.checkpointing.tolerable-failed-checkpoints = 3;
SET state.backend = rocksdb;
SET state.backend.incremental = true;
SET state.backend.rocksdb.localdir = /data/flink/rocksdb;
SET state.checkpoints.dir = hdfs:///flink/checkpoints;
SET state.checkpoints.num-retained = 3;
```

#### Java 完整示例

```java
import org.apache.flink.contrib.streaming.state.EmbeddedRocksDBStateBackend;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.environment.CheckpointConfig;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

public class CheckpointExample {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // State Backend
        EmbeddedRocksDBStateBackend rocksDB = new EmbeddedRocksDBStateBackend(true);
        env.setStateBackend(rocksDB);

        // Checkpoint Storage
        env.getCheckpointConfig().setCheckpointStorage("hdfs:///flink/checkpoints");

        // Checkpoint 配置
        env.enableCheckpointing(60000);
        CheckpointConfig cpConfig = env.getCheckpointConfig();
        cpConfig.setCheckpointingMode(CheckpointingMode.EXACTLY_ONCE);
        cpConfig.setMinPauseBetweenCheckpoints(30000);
        cpConfig.setCheckpointTimeout(600000);
        cpConfig.setMaxConcurrentCheckpoints(1);
        cpConfig.setTolerableCheckpointFailureNumber(3);
        cpConfig.setExternalizedCheckpointCleanup(
            CheckpointConfig.ExternalizedCheckpointCleanup.RETAIN_ON_CANCELLATION
        );

        // 业务逻辑...
        env.execute("Checkpoint Example");
    }
}
```

### 4.2 场景二：RocksDB 调优

```yaml
# RocksDB 调优参数
state.backend.rocksdb.localdir: /ssd1/flink/rocksdb,/ssd2/flink/rocksdb  # 多磁盘
state.backend.rocksdb.memory.managed: true          # 使用 Flink 管理内存
state.backend.rocksdb.memory.fixed-per-slot: 256mb  # 每 slot 固定 RocksDB 内存
state.backend.rocksdb.block.cache-size: 64mb        # Block Cache 大小
state.backend.rocksdb.writebuffer.size: 64mb        # Write Buffer 大小
state.backend.rocksdb.writebuffer.count: 3          # Write Buffer 数量
state.backend.rocksdb.compaction.level.max-size-level-base: 256mb
state.backend.rocksdb.thread.num: 4                 # 后台线程数
state.backend.rocksdb.checkpoint.transfer.thread.num: 4  # CP 传输线程
```

```java
// Java 代码方式精细调优
EmbeddedRocksDBStateBackend rocksDB = new EmbeddedRocksDBStateBackend(true);
rocksDB.setDbStoragePaths("/ssd1/rocksdb", "/ssd2/rocksdb");
rocksDB.setRocksDBOptions(new RocksDBOptionsFactory() {
    @Override
    public DBOptions createDBOptions(DBOptions currentOptions, Collection<AutoCloseable> handlesToClose) {
        return currentOptions
            .setMaxBackgroundJobs(4)
            .setMaxOpenFiles(-1);
    }

    @Override
    public ColumnFamilyOptions createColumnOptions(ColumnFamilyOptions currentOptions, Collection<AutoCloseable> handlesToClose) {
        return currentOptions
            .setCompactionStyle(CompactionStyle.LEVEL)
            .setTargetFileSizeBase(64 * 1024 * 1024)  // 64MB
            .setMaxBytesForLevelBase(256 * 1024 * 1024); // 256MB
    }
});
```

### 4.3 场景三：增量 CP vs 全量 CP

```
全量 Checkpoint:
  每次 CP 都上传完整的状态数据
  状态 10GB → 每次 CP 上传 10GB
  适合：小状态（< 1GB）
  
增量 Checkpoint (仅 RocksDB):
  只上传自上次 CP 以来变更的 SST 文件
  状态 10GB → 每次 CP 可能只上传 100MB~1GB
  适合：大状态（> 1GB）
  注意：恢复时需要合并多个增量 CP
```

### 4.4 场景四：非对齐 Checkpoint

```java
// 当作业存在严重反压时，对齐 CP 可能永远完不成
// 非对齐 CP 不等待 Barrier 对齐，直接将 Buffer 中的数据也纳入 CP

CheckpointConfig cpConfig = env.getCheckpointConfig();
cpConfig.enableUnalignedCheckpoints();

// 混合模式：先尝试对齐，超时后切换非对齐
cpConfig.setAlignedCheckpointTimeout(Duration.ofSeconds(30));
```

| 维度 | 对齐 CP | 非对齐 CP |
|------|---------|-----------|
| Barrier 处理 | 等待所有通道对齐 | 不等待，直接穿过 |
| 反压影响 | 反压时 CP 延迟大甚至失败 | 不受反压影响 |
| CP 大小 | 只含状态 | 状态 + 网络缓冲数据 |
| 恢复时间 | 快 | 稍慢（需重放缓冲） |
| 适用场景 | 正常/轻微反压 | 严重反压 |

### 4.5 场景五：Savepoint 操作

```bash
# 1. 创建 Savepoint（优雅停止）
flink stop --savepointPath hdfs:///flink/savepoints/ <job-id> -yid <yarn-app-id>

# 2. 手动触发 Savepoint（不停止作业）
flink savepoint <job-id> hdfs:///flink/savepoints/ -yid <yarn-app-id>

# 3. 从 Savepoint 恢复
flink run-application -t yarn-application \
    -s hdfs:///flink/savepoints/savepoint-abcdef-123456 \
    -Dexecution.savepoint.ignore-unclaimed-state=false \
    -c com.example.MyJob \
    hdfs:///flink/jars/my-job.jar

# 4. 允许跳过无法恢复的状态（用于算子变更后）
flink run -s hdfs:///flink/savepoints/savepoint-xxx \
    --allowNonRestoredState \
    ...

# 5. 列出可用 Savepoints
hdfs dfs -ls /flink/savepoints/

# 6. 从 retained Checkpoint 恢复（等价于 Savepoint）
flink run -s hdfs:///flink/checkpoints/<job-id>/chk-100 ...
```

### 4.6 场景六：状态 TTL

```java
import org.apache.flink.api.common.state.StateTtlConfig;
import org.apache.flink.api.common.state.ValueStateDescriptor;
import org.apache.flink.api.common.time.Time;

// 配置状态 TTL
StateTtlConfig ttlConfig = StateTtlConfig
    .newBuilder(Time.days(7))  // 7天过期
    .setUpdateType(StateTtlConfig.UpdateType.OnCreateAndWrite)  // 写入时更新TTL
    .setStateVisibility(StateTtlConfig.StateVisibility.NeverReturnExpired)  // 永不返回过期数据
    .cleanupFullSnapshot()  // 全量快照时清理
    .cleanupInRocksdbCompactFilter(1000)  // RocksDB Compaction 时清理
    .build();

ValueStateDescriptor<UserProfile> descriptor = new ValueStateDescriptor<>("user-profile", UserProfile.class);
descriptor.enableTimeToLive(ttlConfig);
```

```sql
-- SQL 中设置状态 TTL
SET table.exec.state.ttl = 86400000;  -- 1天(毫秒)
-- 适用于 JOIN/聚合等 SQL 算子的状态
```

### 4.7 提交命令

```bash
flink run-application -t yarn-application \
    -Dyarn.application.name="stateful-stream-job" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=8 \
    \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.backend.rocksdb.localdir=/data/ssd/rocksdb \
    -Dstate.backend.rocksdb.memory.fixed-per-slot=256mb \
    -Dstate.backend.rocksdb.checkpoint.transfer.thread.num=4 \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints \
    -Dstate.checkpoints.num-retained=3 \
    \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    -Dexecution.checkpointing.min-pause=30000 \
    -Dexecution.checkpointing.timeout=600000 \
    -Dexecution.checkpointing.tolerable-failed-checkpoints=5 \
    -Dexecution.checkpointing.externalized-checkpoint-retention=RETAIN_ON_CANCELLATION \
    \
    -c com.example.StatefulJob \
    hdfs:///flink/jars/stateful-job.jar
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | CP 超时（Checkpoint expired） | 状态太大/反压/网络慢 | 增大 timeout / 开启增量CP / 开启非对齐CP |
| 2 | CP 越来越慢 | 状态持续增长（无TTL） | 设置 State TTL / 检查数据倾斜 |
| 3 | `OutOfMemoryError` in CP | 全量CP序列化时内存不足 | 切换 RocksDB + 增量CP |
| 4 | `IOException: Not enough space` | RocksDB 本地磁盘满 | 清理磁盘 / 配置多磁盘路径 |
| 5 | 从 Savepoint 恢复失败 | 算子 UID 变更 | 确保所有有状态算子设置了 `.uid("xxx")` |
| 6 | `Checkpoint was declined` | 某个 TM 拒绝 CP | 查看 TM 日志，通常是内存/磁盘问题 |
| 7 | CP 对齐时间过长 | 存在反压 | 开启非对齐 CP 或解决反压 |
| 8 | 恢复后数据重复 | Sink 不支持幂等 | 使用支持 2PC 的 Sink 或实现幂等写入 |
| 9 | State 恢复 KeyGroup 不匹配 | 并行度变更 | SP/CP 恢复允许并行度变更（KeyGroup重新分配） |
| 10 | RocksDB compaction 导致性能抖动 | 后台 Compaction 占资源 | 调优 `max-background-jobs` 和限速参数 |

### CP 失败排查流程

```bash
# 1. Web UI 查看 CP 历史
# Job → Checkpoints → History → 查看失败原因

# 2. 查看 TM 日志
yarn logs -applicationId <app-id> -containerId <container-id> | grep -i "checkpoint\|barrier\|snapshot"

# 3. 常见失败原因排查
# - Timeout: 看哪个 subtask 最慢（Web UI → Subtasks → End to End Duration）
# - Declined: TM 内部错误，看 TM 日志
# - Expired: CP 触发太频繁，上一次还没完成下一次又触发了

# 4. 监控指标
# lastCheckpointDuration: 最近一次 CP 耗时
# lastCheckpointSize: 最近一次 CP 大小
# numberOfFailedCheckpoints: 失败 CP 累计数
```

---

## 六、生产最佳实践

### 6.1 资源规划公式

```
# RocksDB 内存
rocksdb.memory.per-slot = (write_buffer_size × write_buffer_count + block_cache_size) × 1.2
推荐: 256MB ~ 512MB per slot

# CP 存储空间
CP Storage = (State Size / Parallelism) × num-retained × 1.5 (增量CP)
CP Storage = State Size × num-retained × 1.5 (全量CP)

# CP 间隔选择
if (State < 1GB): interval = 30~60s
if (1GB < State < 10GB): interval = 60~120s  
if (State > 10GB): interval = 120~300s
```

### 6.2 算子 UID 最佳实践

```java
// 必须为所有有状态算子设置 UID（否则 Savepoint 无法恢复！）
dataStream
    .keyBy(event -> event.getUserId())
    .window(TumblingEventTimeWindows.of(Time.minutes(5)))
    .reduce(new MyReduceFunction())
    .uid("5min-window-reduce")  // ← 关键！
    .name("5 Minute Window Aggregation")
    .addSink(new MySink())
    .uid("my-sink")  // ← 关键！
    .name("Output Sink");
```

### 6.3 监控告警配置

```yaml
# Prometheus 告警规则
groups:
  - name: flink-checkpoint-alerts
    rules:
      - alert: CheckpointDurationHigh
        expr: flink_jobmanager_job_lastCheckpointDuration > 120000
        for: 5m
        annotations:
          summary: "CP 耗时超过 2 分钟"
      
      - alert: CheckpointFailing
        expr: increase(flink_jobmanager_job_numberOfFailedCheckpoints[10m]) > 3
        for: 1m
        annotations:
          summary: "10 分钟内 CP 失败超过 3 次"
      
      - alert: CheckpointSizeTooLarge
        expr: flink_jobmanager_job_lastCheckpointSize > 10737418240
        for: 5m
        annotations:
          summary: "CP 大小超过 10GB"
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: Checkpoint 和 Savepoint 的区别？**

> A:
> | 维度 | Checkpoint | Savepoint |
> |------|-----------|-----------|
> | 触发方式 | 自动定时 | 手动触发 |
> | 目的 | 故障恢复 | 版本升级/迁移 |
> | 格式 | 可用增量 | 总是全量标准格式 |
> | 生命周期 | 自动管理（retain N个） | 永久保留（手动删除） |
> | 恢复兼容性 | 同一作业 | 可跨版本/修改后恢复 |

**Q2: RocksDB 增量 Checkpoint 的原理？**

> A: RocksDB 基于 LSM-Tree，数据存储为 SST (Sorted String Table) 文件。增量 CP 只上传自上次 CP 以来新生成的 SST 文件。恢复时需要拼接多个增量 CP 的 SST 文件来重建完整状态。

**Q3: 如何处理 Checkpoint 反压导致的超时？**

> A: 三种方案：
> 1. 根本解决：定位并消除反压根因（数据倾斜/外部系统慢/资源不足）
> 2. 开启非对齐 CP：`execution.checkpointing.unaligned.enabled=true`
> 3. 混合模式：先对齐，超时后切换非对齐 `aligned-checkpoint-timeout=30s`

**Q4: 并行度变更后能从 Savepoint 恢复吗？**

> A: 可以。Flink 的 Keyed State 使用 Key Group 机制分片，Key Group 数量固定（= max parallelism），并行度变更时只是重新分配 Key Group 到不同 TM。Operator State 需要实现 `ListCheckpointed` 或 `UnionListState` 才支持 rescale。

### 7.2 思考题

1. **状态 10TB 的 Flink 作业，CP 间隔设为多少合适？为什么？**
2. **增量 CP 保留 3 个历史版本，恢复时为什么可能需要读取所有 3 个版本的文件？**
3. **如果忘记给算子设置 UID，从 Savepoint 恢复会怎样？如何补救？**

---

**本教案结束。下一篇：F16-Flink任务运维管理-on-YARN 实战教案**
