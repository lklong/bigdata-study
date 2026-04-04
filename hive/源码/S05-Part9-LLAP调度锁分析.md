# 09 - LLAP 相关阻塞与 DriverState 竞争分析

> 风险等级: 🟢 P2 | 触发条件: LLAP 调度竞争/任务抢占 | 影响: LLAP 任务调度延迟

---

## 一、LLAP TaskExecutorService

**文件**: `llap-server/src/java/org/apache/hadoop/hive/llap/daemon/impl/TaskExecutorService.java`

### 核心问题

所有调度操作共享一把 `synchronized (lock)` 锁：

```java
// 行 403-440: 调度线程
synchronized (lock) {
    task = waitQueue.peek();
    // tryScheduleUnderLock...
}

// 如果 trySchedule 抛 RejectedExecutionException:
synchronized (lock) {
    lock.wait(PREEMPTION_KILL_GRACE_SLEEP_MS);  // ⚠️ 等待被 kill 任务死亡
}

// 行 500-510: schedule 方法也需要同一把锁
public SubmissionState schedule(TaskRunnerCallable task) {
    synchronized (lock) {
        // 所有提交都串行化
    }
}

// 行 620-635: updateFragment, killFragment 等也需要锁
```

---

## 二、DriverState 竞争

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/DriverState.java`

```java
// 行 65: 状态转换锁
private final ReentrantLock stateLock = new ReentrantLock();

// Driver.java 中的竞争场景:
// 行 751: close() → driverState.lock()
// 行 782: releaseTaskQueue() → driverState.lock()
// 行 893: destroy() → driverState.lock()
```

**问题**: 如果编译/执行线程在等待 Metastore 或 HDFS（持有 driverState 锁），cancel/close 操作也无法中断。

---

## 三、排查与修复

### jstack 识别

```bash
# LLAP 调度锁
grep -A 10 "TaskExecutorService\|synchronized.*lock" /tmp/llap_jstack_*.txt

# DriverState 竞争
grep -A 10 "DriverState\|stateLock" /tmp/hs2_jstack_*.txt | grep -B 3 "BLOCKED"
```

### 修复建议

1. **LLAP**: 监控 wait queue 大小和调度延迟
2. **DriverState**: 设置查询级超时防止无限等待
3. 确保 `hive.server2.idle.operation.timeout` 配置合理
