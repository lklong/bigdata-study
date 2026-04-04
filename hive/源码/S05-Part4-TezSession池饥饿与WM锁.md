# 04 - Tez Session 池饥饿与 WorkloadManager 锁分析

> 风险等级: 🔴 P0 | 触发条件: Session 池为空 + AM 启动失败 | 影响: 所有新查询阻塞

---

## 一、问题概述

### 1.1 TezSessionPool — 无限等待

`TezSessionPool.getSession()` 在池为空时进入 `while(true)` 循环，每 10 秒检查一次。如果池中始终没有可用 session（AM 启动失败/session 泄漏），此方法**永远不会返回**。

### 1.2 WorkloadManager — 中心化锁

所有 WM 操作（获取/返回/销毁 session、资源计划更新等）都需要获取 `currentLock`，导致串行化。

---

## 二、源码分析

### 2.1 TezSessionPool.getSession()

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/TezSessionPool.java` 行 128-143

```java
SessionType getSession() throws Exception {
    while (true) {                                    // ⚠️ 无限循环
        SessionType result = null;
        poolLock.lock();
        try {
            while ((result = pool.poll()) == null) {
                LOG.info("Awaiting Tez session to become available");
                notEmpty.await(10, TimeUnit.SECONDS);  // ⚠️ 每10秒醒来检查
            }
        } finally {
            poolLock.unlock();
        }
        if (result.tryUse(false)) return result;
        // tryUse 失败则继续循环
    }
}
```

**问题**: 没有整体超时限制。如果所有 session 都坏了或正在重启，查询线程会永远等在这里。

### 2.2 WorkloadManager 中心化锁

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/WorkloadManager.java`

WM 使用 `currentLock` + 条件变量模式，主线程 `runWmThread()` 处理所有事件：

```java
// 行 411-419
private void runWmThread() {
    while (true) {
        currentLock.lock();
        try {
            while (!hasChanges) {
                hasChangesCondition.await(1, TimeUnit.SECONDS);  // 每秒检查
            }
            // 处理事件...
        }
    }
}
```

15+ 处 `currentLock.lock()` 调用（行 1476/1501/1516/1574/1599/1621/1639/1665/1685/1707/1719/1740），包括：
- `updateResourcePlanAsync` — 更新资源计划
- `applyMoveSessionAsync` — 移动 session
- `getSession` — 获取 session
- `destroy` — 销毁 session
- `returnAfterUse` — 返还 session
- `notifyOfClusterStateChange` — 集群状态变化

---

## 三、排查与修复

### jstack 识别

```bash
grep -A 15 "TezSessionPool\|WorkloadManager\|Awaiting Tez session" /tmp/hs2_jstack_*.txt
```

### 日志检查

```bash
grep -i "Awaiting Tez session\|Failed to use a session\|Session.*expired\|AM.*failed" \
  /var/log/hive/hiveserver2.log | tail -30
```

### 修复建议

1. **监控 Tez Session 池大小和可用数**
2. **确保 YARN 有足够资源启动 AM**
3. **设置 Session 过期和自动回收策略**
4. **关注 Session 泄漏** — 查询异常退出时 session 未归还
