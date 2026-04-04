# Amoro — 湖仓管理系统

---

## 一、概述

Apache Amoro（原名 Arctic）是构建在 Iceberg/Paimon/Hive 之上的湖仓管理系统。核心价值：**自动化治理**——让你不用手动跑 compaction、清理 snapshot。

**在集群中的角色**：Iceberg 表的自动管家。

---

## 二、架构

```
Amoro Management Service (AMS)
  ├── Catalog Service（统一目录，对接 Spark/Flink/Trino）
  ├── Optimizing Service（自动优化调度）
  │     └── Optimizer（Flink/Spark Job 执行合并）
  └── Web UI（表管理、监控）
        ↓
  Iceberg / Paimon / Mixed-Hive 表
        ↓
  HDFS / S3（实际存储）
```

---

## 三、核心能力

| 能力 | 说明 |
|------|------|
| **Self-optimizing** | 自动小文件合并、变更文件处理、过期数据清理 |
| **统一 Catalog** | Spark/Flink/Trino 统一入口 |
| **多格式** | Iceberg、Paimon、Mixed-Iceberg、Mixed-Hive |
| **元数据集成** | Hive MetaStore、AWS Glue |

---

## 四、Self-optimizing 排障

| 现象 | 根因 | 解决 |
|------|------|------|
| 小文件持续堆积 | Optimizer 挂了或资源不足 | 检查 Optimizer 进程/扩容 |
| 优化任务卡住 | Flink/Spark job 异常 | 查 Optimizer 日志 |
| 优化后没变快 | 排序/分区不合理 | 调整优化策略 |
| 元数据膨胀 | Snapshot 清理未配置 | 配置自动过期 |

**排查入口**：Amoro Web UI → Tables → 选表 → Optimizing Tab
