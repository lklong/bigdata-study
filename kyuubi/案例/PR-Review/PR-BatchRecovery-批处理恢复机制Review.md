# PR Review 分析：批处理恢复机制

> **方法论**：刻意练习 — PR 深度 Review（L4 创造者级别）
> **PR 背景**：Kyuubi Server 重启后，自动恢复 PENDING/RUNNING 状态的批处理作业

---

## 1. 变更概述

**目标**：Server 重启后不丢失已提交的批处理作业，自动恢复状态监控。

**核心变更**：
- `KyuubiSessionManager.scala` — 新增 `getBatchSessionsToRecover()` 调用
- `KyuubiBatchSession.scala` — 新增 `fromRecovery` 参数
- `MetadataManager.scala` — 新增 JDBC MetadataStore

## 2. 代码变更分析

### 2.1 恢复流程

```scala
// KyuubiSessionManager.start() 中新增
override def start(): Unit = {
  super.start()
  // ★ Server 启动时恢复批处理
  recoverBatchSessions()
}

private def recoverBatchSessions(): Unit = {
  val metadataList = metadataManager.getBatchesToRecover(
    kyuubiInstance = currentInstance,
    state = Set(PENDING, RUNNING)
  )
  metadataList.foreach { metadata =>
    val session = createBatchSession(metadata, fromRecovery = true)
    openBatchSession(session)
  }
}
```

### 2.2 MetadataStore 设计

```sql
-- 元数据表结构
CREATE TABLE metadata (
  identifier VARCHAR(36) PRIMARY KEY,    -- UUID
  session_type VARCHAR(32),              -- INTERACTIVE / BATCH
  real_user VARCHAR(256),
  user_name VARCHAR(256),
  ip_address VARCHAR(128),
  kyuubi_instance VARCHAR(1024),         -- 哪个 Server 实例
  state VARCHAR(128),                    -- PENDING/RUNNING/FINISHED/FAILED
  resource VARCHAR(2048),                -- 作业 JAR 路径
  class_name VARCHAR(1024),              -- 主类
  request_name VARCHAR(512),             -- 作业名
  request_conf MEDIUMTEXT,               -- 配置 JSON
  request_args MEDIUMTEXT,               -- 参数 JSON
  create_time BIGINT,
  engine_type VARCHAR(32),
  engine_id VARCHAR(128),                -- YARN app_id
  engine_name VARCHAR(512),
  engine_url VARCHAR(1024),
  engine_state VARCHAR(32),
  engine_error MEDIUMTEXT,
  end_time BIGINT,
  peer_instance_closed BOOLEAN DEFAULT FALSE
);
```

**Review 意见**：

| 评价 | 说明 |
|------|------|
| ✅ 优点 | 使用 JDBC（MySQL/PostgreSQL），支持多 Server 共享元数据 |
| ✅ 优点 | 查询时过滤 `kyuubi_instance`，只恢复本实例的批处理 |
| ⚠️ 风险 | 恢复期间如果 MetadataStore 不可用 → 所有批处理丢失 |
| ⚠️ 风险 | `reassign` 功能允许跨实例恢复，但依赖目标实例不可用的判断 |
| 🔧 建议 | 增加恢复失败的重试机制 + 告警 |

### 2.3 fromRecovery 标记

```scala
class KyuubiBatchSession(
    ...,
    fromRecovery: Boolean  // ★ 新增参数
) {
  override def open(): Unit = {
    if (fromRecovery) {
      // 不重新提交作业，只更新已有 metadata
      metadataManager.updateMetadata(metadata.copy(
        kyuubiInstance = currentInstance  // 更新归属实例
      ))
    } else {
      // 正常流程：插入新 metadata + 提交作业
      metadataManager.insertMetadata(metadata)
    }
    runOperation(batchJobSubmissionOp)
  }
}
```

## 3. 设计权衡

| 决策 | 选择 | 替代方案 | 理由 |
|------|------|---------|------|
| 存储后端 | JDBC (MySQL) | ZK / 嵌入式 Derby | ZK 不适合大量数据，Derby 不支持多 Server |
| 恢复范围 | 本实例的批处理 | 所有批处理 | 避免多 Server 同时恢复同一批处理 |
| 恢复时机 | Server 启动时 | 定时扫描 | 简单，启动后立即生效 |

## 4. 知识晶体

| 维度 | 内容 |
|------|------|
| **PR 核心** | 通过 JDBC MetadataStore 持久化批处理状态，Server 重启后自动恢复 |
| **关键设计** | `fromRecovery` 标记区分新建 vs 恢复，只更新归属不重新提交 |
| **隐患** | MetadataStore 不可用时恢复失败，无重试 |
| **学到的** | 有状态服务的"断点续传"设计：持久化+恢复+幂等 |
