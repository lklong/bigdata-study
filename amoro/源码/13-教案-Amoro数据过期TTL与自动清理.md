# 教案 13：Amoro 数据过期 TTL 与自动清理 — 存储成本的隐形杀手

> **课时**：35分钟 | **难度**：⭐⭐⭐

## 一、课前导入 — 你的存储费用为什么每月涨 20%？

> 你的 Iceberg 表每天写入 10GB 新数据，从不删除旧数据。半年后存储量 1.8TB，年底 3.6TB。老板问：半年前的数据还有人查吗？存储费谁买单？
>
> Amoro 的 Data Expiration 功能可以**自动删除超过保留期的旧数据**，就像设置了数据的"保质期"。

## 二、Amoro 的自动清理体系（6 大清理机制）

| 清理类型 | 清理对象 | 触发条件 | 源码类 |
|---------|---------|---------|--------|
| **Snapshot Expiration** | 过期的 Snapshot 元数据 | 超过 max-age | SnapshotsExpiringExecutor |
| **Orphan File Cleaning** | 无任何 Snapshot 引用的文件 | 文件创建超过 3 天 | OrphanFilesCleaningExecutor |
| **Dangling Delete File** | 无效的 Delete File | 对应数据文件已不存在 | DanglingDeleteFilesCleaningExecutor |
| **Data Expiration** | 超过 TTL 的数据分区 | 数据时间超过保留期 | DataExpiringExecutor |
| **Tags Auto Creating** | 自动打 Tag 保护重要快照 | 按配置周期 | TagsAutoCreatingExecutor |
| **Blocker Expiring** | 过期的 Blocker 锁 | 锁超时 | BlockerExpiringExecutor |

## 三、Data Expiration 配置

```properties
# 开启数据过期（AMS 全局配置）
ams.data-expiration.enabled = true
ams.data-expiration.thread-count = 4

# 表级别配置
table-expiration.enabled = true
table-expiration.expire-field = order_time          # 过期判断字段
table-expiration.retention-time = 90d               # 保留 90 天
table-expiration.expire-since = current_timestamp   # 基于当前时间计算
```

## 四、工作原理

```
DataExpiringExecutor 定期扫描:
    │
    ▼
遍历所有启用了 TTL 的表
    │
    ▼
对每张表: 找到 expire-field 最早的分区
    │
    ▼
如果 分区最大时间 < (当前时间 - retention-time)
    │
    ▼
通过 TableMaintainer.expireDataFrom() 删除该分区
    │
    ▼
产生新的 Snapshot（记录删除操作）
    │
    ▼
旧数据文件等下次 Snapshot Expiration 时物理删除
```

## 五、课堂练习

### 思考题：数据过期 vs 快照过期，区别是什么？

<details>
<summary>参考答案</summary>

| | 数据过期 (Data Expiration) | 快照过期 (Snapshot Expiration) |
|--|--|--|
| **删什么** | 旧分区的数据文件 | 旧 Snapshot 的元数据引用 |
| **依据** | 数据中的时间字段 | Snapshot 的创建时间 |
| **效果** | 释放存储空间（删数据） | 释放元数据空间 + 允许清理孤立文件 |
| **关系** | 数据过期后产生新 Snapshot → 旧 Snapshot 过期后 → 旧数据文件被物理删除 |

两者是**级联关系**：数据过期是逻辑删除，快照过期才是物理删除的前提。
</details>

## 六、知识晶体

```
Amoro 6 大清理 = Snapshot过期 + 孤立文件 + 悬挂Delete + 数据TTL + 自动Tag + Blocker过期
Data TTL: 基于时间字段自动删除旧分区数据
配置: expire-field + retention-time + enabled
级联: 数据过期(逻辑删) → Snapshot过期 → 物理删除文件
```

*教案作者：Eric | 最后更新：2026-04-30*
