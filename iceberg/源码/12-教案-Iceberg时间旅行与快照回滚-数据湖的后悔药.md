# 教案 01：Iceberg 时间旅行与快照回滚 — 数据湖的「后悔药」

> **适用对象**：大数据开发/运维工程师 | **前置知识**：了解 Iceberg 基础表结构  
> **课时**：45 分钟 | **难度**：⭐⭐⭐

---

## 一、课前导入 — 一个真实的生产事故

> 周五晚上 11 点，你收到告警：线上报表数据全部为零。排查发现，有人误执行了一条 `DELETE FROM orders WHERE 1=1`，把整张表清空了。传统数据仓库里，这意味着要从备份恢复，可能需要几个小时。
>
> 但如果你用的是 Iceberg，只需一条命令：
> ```sql
> CALL catalog.system.rollback_to_snapshot('db.orders', 1234567890);
> ```
> **30 秒恢复，零数据丢失。** 这就是时间旅行的力量。

---

## 二、本课目标

学完本课，你能回答这 3 个问题：
1. **Iceberg 快照到底存了什么？** 为什么能做到零成本时间旅行？
2. **rollback 和 cherrypick 有什么区别？** 什么场景用哪个？
3. **分支（Branch）和标签（Tag）解决了什么问题？** 跟 Git 的分支有什么异同？

---

## 三、核心概念 — 用生活类比讲清楚

### 3.1 快照 = 相册里的照片

把 Iceberg 表想象成一本**不断增厚的相册**：

```
相册（Table）
├── 第1张照片（Snapshot 1）—— 建表时
├── 第2张照片（Snapshot 2）—— INSERT 100万条
├── 第3张照片（Snapshot 3）—— UPDATE 某些行
├── 第4张照片（Snapshot 4）—— 误DELETE（灾难！）
└── 当前展示（current-snapshot-id → 4）
```

**关键理解**：每张"照片"并不是数据的完整拷贝，而是一份**文件清单**（manifest list → manifest files → data files）。类比：照片不是重新拍一张全景，而是记录了"此刻房间里有哪些家具"。

**所以时间旅行几乎零成本** —— 你只是把"当前展示"的指针从第 4 张照片移回第 3 张。数据文件本身一个字节都没变。

### 3.2 Rollback = 撕掉最后几张照片

```
Rollback 前：current → Snapshot 4（灾难）
Rollback 后：current → Snapshot 3（正常）
```

Snapshot 4 并没有被物理删除，只是不再是"当前"。后续写入会在 Snapshot 3 基础上继续，Snapshot 4 变成"孤立快照"。

### 3.3 Cherry-pick = 从别的相册里偷一张照片贴过来

这是**审计工作流**的核心操作：

```
主线：  S1 → S2 → S3（当前）
审计分支：  S1 → S2 → S3 → S4（审计通过的变更）

Cherry-pick S4 到主线：
主线：  S1 → S2 → S3 → S5（S5 = S4 的变更应用到 S3 上）
```

### 3.4 分支与标签 = 相册的目录标签

| 概念 | Git 类比 | 作用 |
|------|---------|------|
| **Branch** | `git branch feature` | 允许多条时间线并行，互不干扰 |
| **Tag** | `git tag v1.0` | 给某个时刻打上不可变标记 |
| **main** | `git main` | 默认分支，所有查询默认走这里 |

---

## 四、源码精讲 — 像在黑板上一行行写

### 4.1 ManageSnapshots 接口 — 总指挥

> 源码位置：`api/src/main/java/org/apache/iceberg/ManageSnapshots.java`

```java
// 这是快照管理的"遥控器"，所有按钮都在这里
public interface ManageSnapshots extends PendingUpdate<Snapshot> {

  // 按钮1：回滚到指定快照ID（必须是当前快照的祖先）
  ManageSnapshots rollbackTo(long snapshotId);

  // 按钮2：回滚到某个时间点之前的最后一个快照
  ManageSnapshots rollbackToTime(long timestampMillis);

  // 按钮3：直接跳到任意快照（不要求是祖先，更危险）
  ManageSnapshots setCurrentSnapshot(long snapshotId);

  // 按钮4：审计工作流 — 把某个孤立快照的变更cherry-pick过来
  ManageSnapshots cherrypick(long snapshotId);

  // 按钮5-N：分支和标签管理
  ManageSnapshots createBranch(String name, long snapshotId);
  ManageSnapshots createTag(String name, long snapshotId);
  ManageSnapshots removeBranch(String name);
  ManageSnapshots removeTag(String name);
  // ...
}
```

**老师画重点**：
- `rollbackTo` 有安全检查 — 目标必须是当前快照的**祖先**，防止你回滚到不相关的快照
- `setCurrentSnapshot` 没有这个限制 — 可以跳到任何快照，适合高级场景
- `rollbackToTime` 最实用 — 你不需要知道精确的 snapshotId，只需说"回到今天下午 3 点"

### 4.2 SnapshotRef — 分支和标签的数据结构

> 源码位置：`api/src/main/java/org/apache/iceberg/SnapshotRef.java`

```java
public class SnapshotRef implements Serializable {
  public static final String MAIN_BRANCH = "main";  // 默认分支名

  private final long snapshotId;        // 指向哪个快照
  private final SnapshotRefType type;   // BRANCH 或 TAG
  private final Integer minSnapshotsToKeep;  // 分支独有：最少保留几个快照
  private final Long maxSnapshotAgeMs;       // 分支独有：快照最大存活时间
  private final Long maxRefAgeMs;            // 引用本身的过期时间

  public boolean isBranch() { return type == SnapshotRefType.BRANCH; }
  public boolean isTag()    { return type == SnapshotRefType.TAG; }
}
```

**老师画重点**：
- Branch 是**可移动指针** — 每次写入都会更新它指向最新快照
- Tag 是**不可移动指针** — 一旦创建，永远指向同一个快照（除非手动 replace）
- `minSnapshotsToKeep` 和 `maxSnapshotAgeMs` 只对 Branch 有意义 — 控制这条分支上的快照保留策略

### 4.3 SnapshotManager — 核心实现

> 源码位置：`core/src/main/java/org/apache/iceberg/SnapshotManager.java`

```java
// SnapshotManager 是 ManageSnapshots 接口的实现
// 内部用 Transaction 来保证原子性

class SnapshotManager implements ManageSnapshots {
  private final BaseTransaction transaction;

  @Override
  public ManageSnapshots rollbackTo(long snapshotId) {
    // 关键：通过 transaction 设置分支快照
    transaction.setBranchSnapshot(snapshotId, SnapshotRef.MAIN_BRANCH);
    return this;
  }

  @Override
  public ManageSnapshots cherrypick(long snapshotId) {
    // 关键：cherry-pick 走的是完全不同的路径
    transaction.cherryPick().cherrypick(snapshotId).commit();
    return this;
  }
}
```

**设计洞察**：
- Rollback 本质上就是**修改 main 分支指向的 snapshotId** — 简单到令人发指
- Cherry-pick 则是**真的创建了一个新快照** — 把源快照的变更（新增/删除的文件）应用到当前状态上

---

## 五、实战操作速查

### 5.1 时间旅行查询（只读，不改表）

```sql
-- 查询历史版本（Spark）
SELECT * FROM db.orders VERSION AS OF 1234567890;        -- 按快照ID
SELECT * FROM db.orders TIMESTAMP AS OF '2024-01-15 15:00:00';  -- 按时间

-- 查询某个分支（Spark 3.4+）
SELECT * FROM db.orders VERSION AS OF 'audit-branch';
```

### 5.2 回滚操作（会改表的当前状态）

```sql
-- Spark Stored Procedure
CALL catalog.system.rollback_to_snapshot('db.orders', 1234567890);
CALL catalog.system.rollback_to_timestamp('db.orders', TIMESTAMP '2024-01-15 15:00:00');

-- Java API
table.manageSnapshots().rollbackTo(snapshotId).commit();
```

### 5.3 分支与标签管理

```sql
-- 创建标签（相当于 git tag）
CALL catalog.system.create_tag('db.orders', 'eod-20240115', 1234567890);

-- 创建分支（相当于 git branch）
CALL catalog.system.create_branch('db.orders', 'audit', 1234567890);

-- 写入分支
INSERT INTO db.orders.branch_audit VALUES (...);

-- 快进合并（相当于 git merge --ff）
CALL catalog.system.fast_forward('db.orders', 'main', 'audit');
```

---

## 六、课堂练习 — 举一反三

### 思考题 1：快照保留与存储成本

> 如果你的表每分钟产生一个快照（Streaming 写入），一天就是 1440 个快照。每个快照虽然不复制数据，但会引用很多 manifest 文件。**问：如何在保留时间旅行能力的同时控制存储成本？**

<details>
<summary>参考答案</summary>

组合使用：
1. **`history.expire.max-snapshot-age-ms`** — 设置快照最大保留时间（如 7 天）
2. **`history.expire.min-snapshots-to-keep`** — 设置最少保留快照数（如 10 个）
3. **定期 Tag** — 对重要时间点（如每天凌晨）打 Tag，Tag 引用的快照不会被自动过期
4. **Amoro 自动维护** — 配置 `table-expiration.enabled=true`，让 AMS 自动清理过期快照

</details>

### 思考题 2：Rollback vs Cherry-pick

> 场景：你有一条 ETL 管道，每天凌晨 2 点跑。今天的任务因为数据质量问题写入了脏数据（Snapshot 10），但昨天的数据（Snapshot 9）是好的。**问：你应该用 rollback 还是 cherry-pick？如果 Snapshot 10 之后又有人手动修复了一些数据（Snapshot 11），你的策略会变吗？**

<details>
<summary>参考答案</summary>

- **只有 Snapshot 10 是坏的**：用 `rollbackTo(9)` — 简单直接
- **Snapshot 10 坏但 Snapshot 11 有修复**：这时 rollbackTo(9) 会丢失 Snapshot 11 的修复。应该考虑：
  1. 先 rollbackTo(9) 回到好的状态
  2. 然后 cherrypick(11) 把修复的变更应用上来
  3. 或者直接在 Snapshot 11 基础上重跑 ETL

</details>

### 思考题 3：分支隔离

> 你的 BI 团队需要在不影响线上查询的情况下，对 orders 表做一些"假设分析"（What-if Analysis）—— 比如模拟涨价 10% 后的收入变化。**问：如何用 Iceberg 分支实现？有什么注意事项？**

<details>
<summary>参考答案</summary>

```sql
-- 1. 创建分析分支
CALL catalog.system.create_branch('db.orders', 'whatif-price', current_snapshot_id);

-- 2. 在分支上修改数据（不影响 main）
UPDATE db.orders.branch_whatif_price SET price = price * 1.1;

-- 3. 分析
SELECT SUM(price * quantity) FROM db.orders.branch_whatif_price;

-- 4. 分析完毕，删除分支
CALL catalog.system.drop_branch('db.orders', 'whatif-price');
```

注意事项：
- 分支上的数据文件是真实占用存储的（新写入的文件）
- 删除分支后，相关数据文件要等 `expire_snapshots` 清理后才释放空间
- 分支越多、存活越久，元数据负担越重

</details>

---

## 七、知识晶体卡片

```
┌─────────────────────────────────────────────┐
│  Iceberg 时间旅行与快照回滚                    │
├─────────────────────────────────────────────┤
│  核心接口: ManageSnapshots                    │
│  核心实现: SnapshotManager (委托Transaction)   │
│  数据结构: SnapshotRef (Branch/Tag + 指针)    │
├─────────────────────────────────────────────┤
│  rollbackTo  → 移动 main 指针（零成本）        │
│  cherrypick  → 创建新快照（有写入开销）         │
│  Branch      → 可移动指针，支持多时间线        │
│  Tag         → 不可移动指针，标记重要时刻       │
├─────────────────────────────────────────────┤
│  同构类比: Git 版本控制                        │
│  rollback ≈ git reset --hard                 │
│  cherrypick ≈ git cherry-pick                │
│  Branch ≈ git branch                         │
│  Tag ≈ git tag                               │
├─────────────────────────────────────────────┤
│  生产经验:                                    │
│  - Streaming 场景必须配置快照过期策略           │
│  - 重要时间点用 Tag 而非 Branch 保护            │
│  - rollback 是紧急恢复首选（30秒内完成）        │
└─────────────────────────────────────────────┘
```

---

*教案作者：Eric | 数据来源：Iceberg 源码 api/ + core/ | 最后更新：2026-04-27*
