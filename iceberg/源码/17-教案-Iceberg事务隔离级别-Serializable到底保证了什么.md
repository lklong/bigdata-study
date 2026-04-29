# 教案 17：Iceberg 事务隔离级别 — Serializable 到底保证了什么？

> **课时**：40分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入 — 两个 Job 同时写同一张表会怎样？

> Job A 正在向 orders 表 INSERT 1000 万条数据（5分钟），同时 Job B 在做 `DELETE FROM orders WHERE status='cancelled'`。两个 Job 同时执行，最终结果正确吗？会丢数据吗？

## 二、Iceberg 的事务模型

### MVCC + OCC = Iceberg 的事务基石

| 概念 | 全称 | Iceberg 实现 |
|------|------|-------------|
| **MVCC** | Multi-Version Concurrency Control | 每次写入产生新 Snapshot，读取不阻塞写入 |
| **OCC** | Optimistic Concurrency Control | 提交时检查冲突，冲突则重试 |

```
Reader 视角（MVCC）：
  Reader 1 读 Snapshot 5 ──→ 不受后续写入影响
  Reader 2 读 Snapshot 7 ──→ 看到最新数据

Writer 视角（OCC）：
  Writer A 基于 Snapshot 5 开始写 ──→ 提交时检查 base 是否还是 5
    ├── YES → 提交成功，产生 Snapshot 6
    └── NO（别人已提交了 6）→ 重试：刷新 base 到 6，重新提交
```

### Serializable Isolation

Iceberg 的 Serializable 不是"串行执行"，而是**验证结果等价于某种串行执行顺序**：

```java
// BaseTransaction.java 中的 OCC 验证
// 提交时通过 UpdateRequirement 验证：
// - ASSERT_TABLE_UUID — 表没被删重建
// - ASSERT_REF_SNAPSHOT_ID — 分支指向的快照没变
// - ASSERT_CURRENT_SCHEMA_ID — Schema 没变
// 如果验证失败 → CommitFailedException → 上层重试
```

## 三、冲突矩阵 — 什么操作之间会冲突？

| 操作 A \ 操作 B | INSERT | DELETE | REPLACE | SCHEMA变更 |
|---|---|---|---|---|
| **INSERT** | ✅不冲突 | ✅不冲突 | ⚠️可能冲突 | ✅不冲突 |
| **DELETE** | ✅不冲突 | ⚠️操作同分区则冲突 | ⚠️冲突 | ❌冲突 |
| **REPLACE** | ⚠️可能冲突 | ⚠️冲突 | ❌冲突 | ❌冲突 |
| **SCHEMA变更** | ✅不冲突 | ❌冲突 | ❌冲突 | ❌冲突 |

**关键洞察**：**INSERT 之间永远不冲突**！因为 INSERT 只添加新文件，不依赖现有数据。这使得 Streaming 高并发写入成为可能。

## 四、Transaction API — 批量原子操作

```java
// 一个 Transaction 内可以执行多个操作，原子提交
Transaction txn = table.newTransaction();
txn.updateSchema().addColumn("new_col", Types.StringType.get()).commit();
txn.newAppend().appendFile(dataFile1).commit();
txn.newOverwrite().deleteFile(oldFile).addFile(newFile).commit();
txn.commitTransaction();  // 所有操作原子性提交
```

## 五、课堂练习

### 思考题：为什么 INSERT 不冲突但 DELETE 可能冲突？

<details>
<summary>参考答案</summary>

- **INSERT**：只添加新的 DataFile，不对现有数据做任何假设。两个并发 INSERT 产生不同的文件，最终 Snapshot 包含两者的所有新文件。
- **DELETE**：依赖"哪些文件包含要删除的行"这个前提。如果别人已经重写了这些文件（文件路径变了），你的 Delete File 就指向了不存在的文件 → 语义错误 → 必须冲突。
</details>

## 六、知识晶体

```
Iceberg 事务 = MVCC(读不阻塞写) + OCC(写冲突检测+重试)
Serializable: 通过 UpdateRequirement 验证一致性
关键: INSERT间不冲突 → 高并发写入安全
Transaction: 多操作原子批量提交
冲突处理: CommitFailedException → refresh base → retry
```

*教案作者：Eric | 最后更新：2026-04-30*
