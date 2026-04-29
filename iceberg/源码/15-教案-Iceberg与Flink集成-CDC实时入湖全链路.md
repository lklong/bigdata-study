# 教案 15：Iceberg 与 Flink 集成 — CDC 实时入湖全链路

> **适用对象**：大数据开发工程师 | **前置知识**：了解 Flink CDC 基础  
> **课时**：50 分钟 | **难度**：⭐⭐⭐⭐

---

## 一、课前导入 — MySQL 数据怎么实时进数据湖？

> 业务库 MySQL 有一张 orders 表，每秒数千条 INSERT/UPDATE/DELETE。你需要把这些变更**实时**同步到数据湖，供下游分析查询。传统方案是每天全量导出，延迟 24 小时。
>
> Flink CDC + Iceberg 方案：**秒级延迟、增量同步、支持 UPDATE/DELETE、Exactly-Once**。

---

## 二、架构全景

```
MySQL (Binlog) → Flink CDC Source → Flink Processing → Iceberg Sink
                                                              │
                                                    IcebergFilesCommitter
                                                    (Checkpoint 时原子提交)
                                                              │
                                                              ▼
                                                    Iceberg Table (S3/HDFS)
                                                              │
                                                    Spark / Trino / Presto 查询
```

### 核心组件

| 组件 | 源码文件 | 职责 |
|------|---------|------|
| **FlinkCatalog** | `FlinkCatalog.java` (30KB) | 桥接 Flink SQL 和 Iceberg Catalog |
| **FlinkSink** | `FlinkSink.java` (32KB) | DataStream API 写入入口 |
| **IcebergFilesCommitter** | `IcebergFilesCommitter.java` (21KB) | Checkpoint 时原子提交文件 |

---

## 三、IcebergFilesCommitter — Exactly-Once 的关键

```java
// 核心设计：利用 Flink Checkpoint 实现 Exactly-Once 写入

class IcebergFilesCommitter extends AbstractStreamOperator<Void> {
    // 关键常量：记录最后成功提交的 Checkpoint ID
    static final String MAX_COMMITTED_CHECKPOINT_ID = "flink.max-committed-checkpoint-id";

    // Checkpoint 完成时触发提交
    void notifyCheckpointComplete(long checkpointId) {
        // Step 1: 收集本 Checkpoint 周期内所有 Writer 产生的 DataFile
        // Step 2: 调用 Iceberg 的 AppendFiles / RowDelta API 提交
        // Step 3: 将 checkpointId 写入 Iceberg Snapshot 的 summary
        // → 下次恢复时，对比 MAX_COMMITTED_CHECKPOINT_ID 避免重复提交
    }
}
```

**Exactly-Once 保证原理**：
1. Writer 在 Checkpoint 时把文件信息序列化到 Flink State
2. Committer 在 `notifyCheckpointComplete` 时才真正提交到 Iceberg
3. 如果 Checkpoint 失败 → 文件已写但未提交 → 下次恢复时 Writer 重写 → 旧文件变成孤立文件（等 Expire 清理）

---

## 四、实战 — CDC 入湖

### 4.1 Flink SQL 方式

```sql
-- 创建 Flink CDC Source
CREATE TABLE mysql_orders (
    order_id BIGINT,
    user_id BIGINT,
    amount DECIMAL(10,2),
    status STRING,
    update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'mysql-host',
    'port' = '3306',
    'database-name' = 'shop',
    'table-name' = 'orders'
);

-- 创建 Iceberg Sink
CREATE TABLE iceberg_orders (
    order_id BIGINT,
    user_id BIGINT,
    amount DECIMAL(10,2),
    status STRING,
    update_time TIMESTAMP(3),
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'iceberg',
    'catalog-name' = 'iceberg',
    'catalog-type' = 'hive',
    'uri' = 'thrift://hms:9083',
    'warehouse' = 's3://bucket/warehouse'
);

-- 开始同步（INSERT/UPDATE/DELETE 全部同步）
INSERT INTO iceberg_orders SELECT * FROM mysql_orders;
```

### 4.2 关键配置

| 配置 | 推荐值 | 说明 |
|------|--------|------|
| `write.upsert.enabled` | true | 启用 UPSERT 模式（基于 Primary Key 去重） |
| `write.distribution-mode` | hash | 按 PK hash 分桶，保证同 key 到同 Writer |
| Checkpoint 间隔 | 60s - 300s | 控制提交频率（= 数据可见延迟） |
| `write.target-file-size-bytes` | 128MB | 防止 Streaming 产生大量小文件 |

---

## 五、课堂练习

### 思考题 1：Checkpoint 间隔设多少合适？

<details>
<summary>参考答案</summary>

权衡：
- **短间隔（10s）**：数据延迟低，但每 10 秒一个 Snapshot + 一批小文件 → 元数据膨胀
- **长间隔（5min）**：数据延迟高，但文件更大更少 → 查询性能好
- **推荐**：60s - 120s，配合 Amoro 自动小文件合并

计算：如果每秒 1000 条 × 100 字节 = 100KB/s，60s = 6MB 一个文件 → 太小！
→ 增大 Checkpoint 间隔到 300s，或增大 parallelism 让更多数据写入同一文件
</details>

### 思考题 2：UPSERT 模式下 Iceberg 怎么处理 UPDATE？

<details>
<summary>参考答案</summary>

1. Flink 收到 CDC 的 UPDATE 事件（包含 before + after）
2. 转化为：DELETE(before) + INSERT(after)
3. Iceberg Sink 用 `RowDelta` API：
   - 写一个 Equality Delete File（按 PK 删除旧行）
   - 写一个 Data File（包含新行）
4. 后续读取时 MoR 合并：数据文件 - Delete File = 最新状态
</details>

---

## 六、知识晶体卡片

```
┌──────────────────────────────────────────────────┐
│  Flink + Iceberg CDC 入湖                          │
├──────────────────────────────────────────────────┤
│  链路: MySQL Binlog → Flink CDC → IcebergSink     │
│  提交: IcebergFilesCommitter (Checkpoint 时原子提交)│
│  幂等: MAX_COMMITTED_CHECKPOINT_ID 防重复提交       │
├──────────────────────────────────────────────────┤
│  Exactly-Once 条件:                                │
│  1. Flink Checkpoint 正常完成                      │
│  2. Iceberg OCC commit 成功                        │
│  3. 失败时孤立文件等 Expire 清理                    │
├──────────────────────────────────────────────────┤
│  UPSERT: CDC UPDATE → EqualityDelete + DataFile   │
│  关键配置: upsert=true + distribution=hash         │
│  + checkpoint间隔60-300s + Amoro自动合并小文件      │
└──────────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Iceberg Flink Sink 源码 v1.20 | 最后更新：2026-04-30*
