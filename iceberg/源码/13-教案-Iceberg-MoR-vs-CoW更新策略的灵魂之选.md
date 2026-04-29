# 教案 13：Iceberg Merge-on-Read vs Copy-on-Write — 更新策略的灵魂之选

> **适用对象**：大数据开发/架构师 | **前置知识**：了解 Iceberg V2 行级删除  
> **课时**：45 分钟 | **难度**：⭐⭐⭐⭐

---

## 一、课前导入 — 一条 UPDATE 引发的性能血案

> 你的数据湖表有 10 亿行数据，现在要更新其中 1000 行的状态字段。两种极端方案：
> - **方案 A**：把包含这 1000 行的整个 Parquet 文件重写一遍（可能 128MB）—— 写放大 10 万倍
> - **方案 B**：只记录"这 1000 行被删了"，下次读的时候临时合并 —— 读放大
>
> 这就是 **Copy-on-Write（CoW）** vs **Merge-on-Read（MoR）** 的核心权衡。

---

## 二、本课目标

1. **CoW 和 MoR 的本质区别是什么？** 各自的读写代价如何？
2. **什么场景选 CoW，什么场景选 MoR？** 给出决策树
3. **Iceberg V2 的 Delete File 机制是 MoR 的核心** —— 它如何避免读放大？

---

## 三、核心概念 — 图书馆的比喻

### Copy-on-Write = 重印整本书

> 你发现百科全书第 500 页有个错字。CoW 的做法是：**把整本书重新印一遍**，只改第 500 页的那个字。代价高（写放大），但以后读这本书的人不需要额外操作。

### Merge-on-Read = 贴一张勘误表

> MoR 的做法是：**不重印书，只贴一张勘误表**在封底，写"第 500 页第 3 行'的'改为'地'"。写很快（只写勘误表），但以后每个读者都要先看勘误表再看正文（读放大）。

---

## 四、技术对比

| 维度 | Copy-on-Write | Merge-on-Read |
|------|--------------|---------------|
| **写路径** | 重写整个数据文件（慢） | 只写 Delete File + 新数据文件（快） |
| **读路径** | 直接读数据文件（快） | 读数据文件 + 合并 Delete File（较慢） |
| **写放大** | 高（整个文件重写） | 低（只写变更） |
| **读放大** | 无 | 有（需运行时合并） |
| **适合场景** | 读多写少、批量更新 | 写频繁、实时更新 |
| **Iceberg 实现** | OverwriteFiles API | RowDelta + DeleteFile |

### Iceberg 的 Delete File 类型

| 类型 | 内容 | 大小 | 合并效率 |
|------|------|------|---------|
| **Position Delete** | (文件路径, 行号) 列表 | 小 | O(1) 跳过 |
| **Equality Delete** | 被删除行的 key 值列表 | 取决于 key 数 | O(N) 匹配 |

```
数据文件: orders.parquet (100万行)
Position Delete: [(orders.parquet, 500), (orders.parquet, 1500), ...]
                  → 读 orders.parquet 时跳过第 500、1500 行

Equality Delete: [order_id=123, order_id=456, ...]
                  → 读任何数据文件时，过滤掉 order_id 为 123、456 的行
```

---

## 五、决策树 — 选 CoW 还是 MoR？

```
更新频率高吗？（每分钟级别）
├── YES → 用 MoR（避免写放大拖垮吞吐）
│         └── 配合 Amoro 定期 Major Optimize（合并 Delete File）
└── NO（每天/每小时批量更新）
    ├── 读性能极敏感吗？（亚秒级查询）
    │   ├── YES → 用 CoW（写时多花时间，读时零开销）
    │   └── NO → 都可以，MoR + 定期合并是性价比最高的方案
    └── 更新量占总数据比例？
        ├── >30% → CoW（大量更新时 MoR 的 Delete File 会很大，读时合并代价更高）
        └── <5% → MoR（少量更新不值得重写整个文件）
```

---

## 六、Spark 中的配置

```sql
-- 设置写模式为 MoR（默认）
ALTER TABLE db.orders SET TBLPROPERTIES (
    'write.delete.mode' = 'merge-on-read',      -- DELETE 操作
    'write.update.mode' = 'merge-on-read',      -- UPDATE 操作
    'write.merge.mode'  = 'merge-on-read'       -- MERGE INTO 操作
);

-- 设置为 CoW
ALTER TABLE db.orders SET TBLPROPERTIES (
    'write.delete.mode' = 'copy-on-write',
    'write.update.mode' = 'copy-on-write',
    'write.merge.mode'  = 'copy-on-write'
);
```

---

## 七、课堂练习

### 思考题 1：MoR 的读放大什么时候会变得不可接受？

<details>
<summary>参考答案</summary>

当 Delete File 数量过多（几百个）或 Equality Delete 的 key 集合很大时：
- 每次读一个数据文件都要加载所有 Delete File → IO 放大
- Equality Delete 需要对每行做 key 匹配 → CPU 放大
- **解决**：定期运行 `RewriteDataFiles`（Iceberg）或让 Amoro 自动 Major Optimize 合并
</details>

### 思考题 2：为什么 Amoro 在 MoR 模式下特别有价值？

<details>
<summary>参考答案</summary>

MoR 的核心问题是 Delete File 积累导致读放大。Amoro 的 Self-Optimizing 会：
1. **Minor Optimize**：合并小的 Delete File
2. **Major Optimize**：将 Delete File 与数据文件合并（消除 Delete File）
3. **自动触发**：当 Delete File 数量/比例超过阈值时自动执行

没有 Amoro，你需要手动定期运行 `RewriteDataFiles`，或者用 Airflow 调度。
</details>

### 思考题 3：同构类比

<details>
<summary>参考答案</summary>

| Iceberg | LSM-Tree | 数据库 |
|---------|----------|--------|
| CoW | 不使用 WAL，直接写 SST | PostgreSQL MVCC（HOT Update） |
| MoR | WAL + Compaction | MySQL InnoDB Undo Log + Purge |
| Delete File | Tombstone | 删除标记 |
| Major Optimize | Major Compaction | Vacuum/Purge |
</details>

---

## 八、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Iceberg MoR vs CoW                               │
├──────────────────────────────────────────────────┤
│  CoW: 写时重写整个文件，读时零开销                  │
│  MoR: 写时只记录删除，读时合并（需定期Compact）     │
├──────────────────────────────────────────────────┤
│  Delete File 类型:                                 │
│  Position Delete — (文件,行号) → 跳过效率 O(1)     │
│  Equality Delete — key值列表 → 匹配效率 O(N)       │
├──────────────────────────────────────────────────┤
│  选型决策:                                         │
│  写频繁+少量更新 → MoR + Amoro自动合并             │
│  读敏感+批量更新 → CoW                             │
│  MoR 不维护 = 读性能持续恶化（Delete File堆积）     │
├──────────────────────────────────────────────────┤
│  同构: MoR ≈ LSM-Tree, CoW ≈ B-Tree in-place更新  │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Iceberg 源码 + Amoro 文档 | 最后更新：2026-04-30*
