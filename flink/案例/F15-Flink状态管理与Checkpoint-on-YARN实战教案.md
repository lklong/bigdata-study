# [教案] Flink on YARN — 状态管理与 Checkpoint 实战使用姿势

> 🎯 教学目标：掌握 State Backend 选择、Checkpoint 配置调优、Savepoint 操作、状态 TTL | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入

| 场景 | 说明 |
|------|------|
| **容错恢复** | 任务异常后从 Checkpoint 恢复 |
| **精确一次** | Exactly-Once 依赖 Checkpoint |
| **任务升级** | 从 Savepoint 恢复 |
| **扩缩容** | 调整并行度后恢复 |

---

## 二、前置条件

```bash
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)
hdfs dfs -mkdir -p /flink/checkpoints /flink/savepoints
```

---

## 三、核心配置

### 3.1 State Backend 对比

| Backend | 存储 | 状态大小 | 性能 | 适用 |
|---------|------|----------|------|------|
| HashMap | JVM 堆 | <几GB | 极快 | 状态小 |
| RocksDB | 磁盘 | GB~TB | 快 | **生产推荐** |

### 3.2 Checkpoint 参数

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| `execution.checkpointing.interval` | 间隔 | 60000ms |
| `execution.checkpointing.mode` | 模式 | EXACTLY_ONCE |
| `execution.checkpointing.timeout` | 超时 | 300000ms |
| `execution.checkpointing.min-pause` | 最小间隔 | 30000ms |
| `execution.checkpointing.unaligned.enabled` | 非对齐CK | true(反压时) |
| `execution.checkpointing.tolerable-failed-checkpoints` | 容忍失败 | 5 |
| `state.backend.incremental` | 增量CK | true |

---

## 四、完整实战

### 4.1 代码配置

```java
StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
env.setStateBackend(new EmbeddedRocksDBStateBackend(true));
env.enableCheckpointing(60000, CheckpointingMode.EXACTLY_ONCE);
env.getCheckpointConfig().setCheckpointTimeout(300000);
env.getCheckpointConfig().setMinPauseBetweenCheckpoints(30000);
env.getCheckpointConfig().setTolerableCheckpointFailureNumber(5);
env.getCheckpointConfig().setCheckpointStorage("hdfs:///flink/checkpoints/my-job");
env.getCheckpointConfig().setExternalizedCheckpointCleanup(
    CheckpointConfig.ExternalizedCheckpointCleanup.RETAIN_ON_CANCELLATION);
```

### 4.2 State TTL

```java
StateTtlConfig ttlConfig = StateTtlConfig.newBuilder(Time.hours(24))
    .setUpdateType(StateTtlConfig.UpdateType.OnCreateAndWrite)
    .setStateVisibility(StateTtlConfig.StateVisibility.NeverReturnExpired)
    .cleanupInRocksdbCompactFilter(1000)
    .build();
valueStateDescriptor.enableTimeToLive(ttlConfig);
```

### 4.3 SQL 配置

```sql
SET 'execution.checkpointing.interval' = '60s';
SET 'state.backend' = 'rocksdb';
SET 'state.backend.incremental' = 'true';
SET 'state.checkpoints.dir' = 'hdfs:///flink/checkpoints/sql-job';
SET 'table.exec.state.ttl' = '86400000';
```

### 4.4 提交命令

```bash
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dstate.backend=rocksdb \
    -Dstate.backend.incremental=true \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/job \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.timeout=300000 \
    -Dexecution.checkpointing.unaligned.enabled=true \
    -Dyarn.application.name="Stateful-Job" \
    -c com.example.StatefulJob \
    /path/to/job.jar
```

### 4.5 Savepoint 操作

```bash
# 创建 Savepoint
$FLINK_HOME/bin/flink savepoint <jobId> hdfs:///flink/savepoints/manual -yid app_xxx

# 优雅停止
$FLINK_HOME/bin/flink stop --savepointPath hdfs:///flink/savepoints/upgrade <jobId>

# 从 Savepoint 恢复
$FLINK_HOME/bin/flink run-application -t yarn-application \
    -s hdfs:///flink/savepoints/upgrade/savepoint-xxx \
    -c com.example.Job /path/to/job.jar
```

---

## 五、常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| CK 超时 | 状态大或反压 | 增大 timeout，启用 unaligned |
| CK declined | Task 崩溃 | 查 TM 日志 OOM |
| HDFS 写入失败 | 磁盘满 | 清理旧 CK |
| 恢复失败 | UID 变化 | 算子设置 `.uid()` |

---

## 六、最佳实践

```yaml
# 生产推荐配置
state.backend: rocksdb
state.backend.incremental: true
execution.checkpointing.interval: 60000
execution.checkpointing.timeout: 300000
execution.checkpointing.unaligned.enabled: true
execution.checkpointing.tolerable-failed-checkpoints: 5
execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
```

**算子 UID 规则**: 所有有状态算子必须设置 `.uid("xxx")`，上线后不能变。

---

## 七、举一反三

**Q: CK vs Savepoint？** → CK 自动/容错；SP 手动/升级迁移。
**Q: 为什么用增量 CK？** → 状态大时全量上传太慢。
**Q: Unaligned CK 何时用？** → 反压严重导致 Barrier 对齐超时时。

---

> 📅 **更新日期**: 2026-04-30
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
