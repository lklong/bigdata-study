# 07 - Session 操作锁与死锁风险分析

> 风险等级: 🟡 P1 | 触发条件: 同 session 慢查询未结束 | 影响: 同 session 其他操作阻塞

---

## 一、问题概述

`HiveSessionImpl` 使用 `Semaphore` 限制同一 session 内的操作并发度。默认配置 `HIVE_SERVER2_PARALLEL_OPS_IN_SESSION=true` 时不限制，但如果设为 `false`，则使用 `Semaphore(1)` 严格串行化。

更严重的是，代码注释**明确指出**存在与 `HiveMetaStoreClient#SynchronizedHandler` 的**死锁风险**。

---

## 二、源码分析

### 2.1 operationLock

**文件**: `service/src/java/org/apache/hive/service/cli/session/HiveSessionImpl.java`

```java
// 行 127: 操作锁定义
private final Semaphore operationLock;

// 行 136: 根据配置决定是否限制
this.operationLock = serverConf.getBoolVar(
    ConfVars.HIVE_SERVER2_PARALLEL_OPS_IN_SESSION) ? null : new Semaphore(1);
// 默认 true → null → 不限制
// 设为 false → Semaphore(1) → 严格串行

// 行 372-389: acquire 方法
protected void acquire(boolean userAccess, boolean isOperation) {
    if (isOperation && operationLock != null) {
        try {
            operationLock.acquire();  // ⚠️ 无限等待直到获取许可
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException(e);
        }
    }
    acquireAfterOpLock(userAccess);
}
```

### 2.2 死锁风险（代码注释已标注）

```java
// 行 392-409
private synchronized void acquireAfterOpLock(boolean userAccess) {
    SessionState.setCurrentSessionState(sessionState);
    // ...
    
    // ⚠️ 行 407-409 的注释:
    // "If Hive.get() is being shared across different sessions,
    //  sessionHive and Hive.get() may be different, in such case,
    //  the risk of deadlock on HiveMetaStoreClient#SynchronizedHandler can happen."
    Hive.set(sessionHive);
}
```

**死锁路径**:
```
Thread A: HiveSessionImpl.acquireAfterOpLock (synchronized)
  → Hive.set() → 触发 getMSC() (synchronized on Hive object)

Thread B: 某操作持有 Hive 对象锁 (synchronized getMSC)
  → 回调需要 HiveSessionImpl (synchronized)
  
→ Thread A 等 Hive 锁，Thread B 等 Session 锁 → 死锁
```

---

## 三、排查与修复

### jstack 识别

```bash
# 搜索死锁
grep -A 30 "Found.*deadlock\|BLOCKED.*HiveSessionImpl\|BLOCKED.*getMSC" /tmp/hs2_jstack_*.txt
```

### 修复建议

1. **保持默认配置** `hive.server2.parallel.ops.in.session=true`（不启用 operationLock）
2. **如果必须设为 false**，确保同一 session 不并发提交查询
3. **监控** jstack 中的 deadlock 检测
