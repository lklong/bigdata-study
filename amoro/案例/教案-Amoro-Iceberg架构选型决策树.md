# 教案：Amoro + Iceberg 架构选型决策树 — 什么场景该用什么方案？

> **课时**：40分钟 | **难度**：⭐⭐⭐

## 一、课前导入

> 老板说："我们要建数据湖"。但数据湖有 100 种建法。用不用 Amoro？选 Iceberg 还是 Hudi？MoR 还是 CoW？Flink 入湖还是 Spark？这张决策树帮你 5 分钟做出选择。

## 二、第一层决策 — 要不要用数据湖表格式？

```
你的数据需要以下能力吗？
├── ACID 事务（并发写入安全）     → YES 则需要
├── Schema Evolution（在线改列）  → YES 则需要  
├── 时间旅行（数据回滚/审计）     → YES 则需要
├── 行级更新/删除                → YES 则需要
└── 以上都不需要 → 直接用 Parquet/ORC 文件即可，不需要表格式
```

## 三、第二层决策 — Iceberg vs Hudi vs Delta Lake

| 维度 | Iceberg | Hudi | Delta Lake |
|------|---------|------|-----------|
| **社区** | Apache 顶级，中立 | Apache，Onehouse 主导 | Databricks 主导 |
| **引擎兼容** | 最好（Spark/Flink/Trino/Presto/StarRocks...） | 好（Spark/Flink/Presto） | 一般（Spark 最佳） |
| **更新性能** | MoR + Position Delete（优） | MoR（优，原生 Upsert） | CoW 为主（中） |
| **流式写入** | 好（配合 Amoro） | 最好（原生 Compaction） | 好（Auto Optimize） |
| **社区活跃度** | 最高（2024 起） | 高 | 中 |
| **推荐场景** | 新建湖仓首选 | 已有 Hudi 生态 | Databricks 生态 |

**结论：新项目首选 Iceberg**。

## 四、第三层决策 — 要不要用 Amoro？

```
你管理超过 50 张 Iceberg 表吗？
├── YES → 强烈推荐 Amoro（自动优化 + 统一监控）
└── NO (< 10 张) → 可以手动维护（Airflow + RewriteDataFiles）

你有实时写入（Streaming）场景吗？
├── YES → 强烈推荐 Amoro（自动合并小文件 + Minor/Major Optimize）
└── NO (纯批量) → Amoro 可选，但仍有价值（监控 + 自动清理）

你需要 Mixed-Iceberg（Change Store + Base Store）吗？
├── YES → 必须 Amoro（这是 Amoro 独有功能）
└── NO → 用原生 Iceberg V2 MoR 即可
```

## 五、第四层决策 — 入湖链路选型

| 场景 | 推荐方案 | 延迟 | 复杂度 |
|------|---------|------|--------|
| MySQL CDC 入湖 | Flink CDC → Iceberg | 秒级 | 中 |
| Kafka 消息入湖 | Flink/Spark Streaming → Iceberg | 秒-分钟级 | 中 |
| 批量 ETL 写入 | Spark SQL INSERT | 分钟-小时级 | 低 |
| 文件导入 | Spark LOAD DATA / Add Files | 分钟级 | 低 |

## 六、完整决策流程图

```
需要 ACID + Schema Evolution? ──NO──→ 用纯 Parquet/ORC
         │ YES
         ▼
新建还是迁移? ──迁移有 Hudi──→ 继续用 Hudi
         │ 新建
         ▼
选 Iceberg (社区最活跃，引擎兼容最好)
         │
         ▼
表数量 > 50 或有 Streaming? ──YES──→ 用 Amoro 管理
         │ NO                              │
         ▼                                 ▼
手动维护 (Airflow)              配置 Self-Optimizing 策略
         │                                 │
         ▼                                 ▼
选入湖链路:                     选入湖链路:
批量 → Spark SQL               实时 → Flink CDC
少量更新 → CoW                 高频更新 → MoR
```

## 七、课堂练习

### 思考题：什么时候 Amoro 反而是负担？

<details>
<summary>参考答案</summary>

1. **表很少（<5张）**：Amoro AMS 本身需要部署维护，overhead 不值得
2. **纯读场景**：表只读不写，不需要优化
3. **已有完善的调度系统**：如果 Airflow 已配好 RewriteDataFiles + ExpireSnapshots，Amoro 价值有限
4. **极简架构偏好**：不想多一个有状态服务（AMS 需要 MySQL + 高可用）
</details>

## 八、知识晶体

```
新建湖仓 → Iceberg（最佳兼容性）
表多/Streaming → Amoro（自动管理）
表少/批量 → 手动维护（Airflow）
CDC入湖 → Flink + Iceberg
批量入湖 → Spark + Iceberg
MoR适合高频更新，CoW适合读密集
```

*教案作者：Eric | 最后更新：2026-04-30*
