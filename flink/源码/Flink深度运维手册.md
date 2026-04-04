# Flink — 流处理引擎

---

## 一、概述

Apache Flink 是大数据生态中最主流的流处理引擎，支持实时计算、事件驱动、流批一体。

**在集群中的角色**：实时数据处理（CDC、实时 ETL、实时告警、实时指标）。

---

## 二、架构

```
JobManager（作业管理）
  ├── Dispatcher（接收作业提交）
  ├── ResourceManager（管理 TaskManager 资源）
  └── JobMaster（每个 Job 一个，管理执行图）
        ↓
TaskManager × N（工作进程）
  ├── Task Slot（资源隔离单位）
  ├── Network Buffer（算子间数据传输）
  └── State Backend（状态存储：Memory/RocksDB）
```

---

## 三、版本信息

| 版本 | 关键变更 |
|------|---------|
| 1.20.x | 当前生产主力 |
| **2.0** | 大版本，大量弃用 API 被移除，`run-application` CLI 移除 |
| 2.2 | 增强 AI 能力、物化表 |
| **CDC 3.6.0** | 修复 MySQL GTID 数据丢失、JDK 升级至 11 |

---

## 四、常见故障排查

### 4.1 Checkpoint 超时/失败

**排查路径**（按概率排序）：

| 概率 | 方向 | 检查 |
|------|------|------|
| 50% | 反压导致 Barrier 对齐慢 | Web UI → 算子 BackPressure |
| 30% | State 过大 | Checkpoints → State Size |
| 15% | 磁盘 IO 瓶颈 | 检查 RocksDB 所在磁盘 |
| 5% | 配置不合理 | 超时时间/间隔设置 |

**解决方案**：
```properties
# 增量 Checkpoint（必须开）
state.backend.incremental = true
# Unaligned Checkpoint（缓解反压影响）
execution.checkpointing.unaligned.enabled = true
# 调大超时
execution.checkpointing.timeout = 600000
```

### 4.2 反压定位

**核心原则**：反压从下游向上游传播，从 Sink 往 Source 方向找第一个 HIGH 的算子

**常见瓶颈**：
| 位置 | 原因 | 解决 |
|------|------|------|
| Sink | 外部系统写入慢 | 优化 Sink 或扩容外部系统 |
| 算子 | UDF 计算重 | 增加并行度 / 优化代码 |
| 数据倾斜 | 某 subtask 过载 | rebalance / keyBy 打散 |
| GC | JVM GC 时间长 | 增加内存 / 调 GC |

### 4.3 State 持续增长

1. 检查 State TTL 是否配置
2. 检查 Key 基数是否无限增长
3. 使用 RocksDB + 增量 Checkpoint
4. `StateTtlConfig.newBuilder(Time.hours(24))...`

### 4.4 CDC MySQL 数据丢失风险

- CDC < 3.6.0 存在 GTID 恢复数据丢失 Bug
- 检查：`SHOW GLOBAL VARIABLES LIKE 'gtid_mode'`
- 解决：升级 CDC 3.6.0（注意 JDK 11 要求）

---

## 五、RocksDB State Backend 调优

```yaml
state.backend.rocksdb.block.cache-size: 268435456    # 256MB（默认 8MB 太小）
state.backend.rocksdb.writebuffer.size: 134217728     # 128MB
state.backend.rocksdb.writebuffer.count: 3            # 写缓冲数
state.backend.rocksdb.block.blocksize: 32768          # 32KB
state.backend.incremental: true                       # 增量 Checkpoint
state.backend.rocksdb.predefined-options: SPINNING_DISK_OPTIMIZED_HIGH_MEM
```

**调优顺序**：Block Cache → Write Buffer → 增量 Checkpoint → Block Size
