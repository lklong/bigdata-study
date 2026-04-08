# Amoro 自优化调度与 Compaction 深度分析

> Amoro Expert 案例学习 — 数据湖自动化治理核心

## 一、Amoro (原 Arctic) 架构

```
┌────────────────────────────────────────────────┐
│               Amoro Management System           │
│  ┌──────────────┐  ┌───────────────────────┐   │
│  │ AMS Server   │  │ Self-Optimizing       │   │
│  │ (Dashboard)  │  │ Scheduler + Executor  │   │
│  └──────────────┘  └───────────────────────┘   │
└─────────────┬──────────────────────────────────┘
              │
    ┌─────────┼─────────┬────────────┐
    ↓         ↓         ↓            ↓
┌────────┐┌────────┐┌────────┐┌──────────┐
│Iceberg ││ Hive   ││ Mixed  ││ Paimon   │
│ Table  ││ Table  ││ Iceberg││ Table    │
└────────┘└────────┘└────────┘└──────────┘
```

## 二、Self-Optimizing 机制

### 2.1 两级优化策略

```
Minor Optimize (快速合并):
  - 触发: 分区内小文件数 > 阈值 (默认 12)
  - 动作: 合并小文件到目标大小
  - 频率: 高（可能每小时一次）
  - 特点: 快速，不重写大文件

Major Optimize (全量优化):
  - 触发: 分区内文件碎片率 > 阈值 或 定时触发
  - 动作: 重写整个分区的所有文件（按排序键排序）
  - 频率: 低（每天或每周一次）
  - 特点: 慢但效果好，优化数据布局

Full Optimize (Mixed-Iceberg 特有):
  - 将 ChangeStore 的增量数据合并到 BaseStore
  - 类似 LSM-Tree 的 Compaction
```

### 2.2 调度器源码核心逻辑

```java
// OptimizingPlanner.java — 决定哪些分区需要优化
public List<TaskDescriptor> planTasks() {
    for (PartitionFileGroup group : partitionFileGroups) {
        // 检查是否满足 Minor 触发条件
        if (group.getSmallFileCount() > minorTriggerFileCount) {
            plans.add(createMinorTask(group));
        }
        // 检查是否满足 Major 触发条件
        else if (group.getFragmentRatio() > majorTriggerRatio) {
            plans.add(createMajorTask(group));
        }
    }
    return plans;
}

// 关键: 优先级排序
// 1. 文件数最多的分区优先
// 2. 最近写入的分区优先（热数据优先优化）
// 3. 已等待时间最长的优先（防饥饿）
```

### 2.3 配置参数

```sql
-- 表级别配置
ALTER TABLE db.events SET TBLPROPERTIES (
  'self-optimizing.enabled' = 'true',
  
  -- Minor 触发条件
  'self-optimizing.minor.trigger.file-count' = '12',
  'self-optimizing.minor.trigger.interval' = '3600000',  -- 1小时
  
  -- Major 触发条件
  'self-optimizing.major.trigger.duplicate-ratio' = '0.5',
  
  -- 目标文件大小
  'self-optimizing.target-size' = '536870912',  -- 512MB
  
  -- 并发度
  'self-optimizing.max-task-parallelism' = '10',
  
  -- 资源配额
  'self-optimizing.quota' = '0.5'  -- 最多用集群 50% 资源
);
```

## 三、Mixed-Iceberg 表（Amoro 独有）

### 3.1 架构

```
Mixed-Iceberg 表 = BaseStore + ChangeStore

写入路径:
  Flink/Spark → ChangeStore (小文件, 实时写入)

读取路径:
  查询 → MOR (Merge-on-Read): BaseStore + ChangeStore 合并读取

Compaction:
  ChangeStore → 合并到 → BaseStore (定期)

类似:
  HBase: MemStore → HFile → Major Compaction
  RocksDB: MemTable → SST L0 → Compaction → SST L1+
```

### 3.2 优势

```
1. 写入零延迟: 直接写 ChangeStore（追加写，无锁）
2. 读取最新: MOR 模式读到最新数据
3. 后台优化: Compaction 不阻塞读写
4. 数据去重: Compaction 时自动 Merge 相同 PK 的记录
```

## 四、Amoro Dashboard 运维

### 4.1 关键监控

```
1. Optimizer 状态:
   - 运行中的 Optimizer 实例数
   - 队列中等待的 Optimize 任务数
   - 各 Optimizer 的 CPU/内存使用率

2. 表健康度:
   - 各分区的文件数/平均大小
   - 待优化任务积压数
   - 最近一次 Optimize 耗时

3. 资源使用:
   - Optimize 消耗的 CPU/内存
   - 数据读写量
```

### 4.2 常见问题排查

```
问题1: Optimize 任务一直 Pending
  原因: Optimizer 实例不够 / 资源配额用完
  解决: 增加 Optimizer 实例 / 调大 quota

问题2: Optimize 后文件反而变多
  原因: target-size 设太小 / 同时有写入在产生新文件
  解决: 调大 target-size / 错峰执行 Major Optimize

问题3: MOR 读取慢
  原因: ChangeStore 积累太多小文件还没被 Compact
  解决: 降低 Minor 触发阈值 / 增加 Optimize 频率
```

## 五、经验规则

```
R-AMORO-001: 流式写入表必须开启 Self-Optimizing
R-AMORO-002: Minor 触发文件数阈值 10-20，不要太大
R-AMORO-003: Optimizer 实例数 >= 活跃表数 / 5
R-AMORO-004: target-size 和 Iceberg 保持一致 (256MB-1GB)
R-AMORO-005: Major Optimize 安排在业务低峰期
```

---

*Amoro Expert 案例产出 | 2026-04-08*
