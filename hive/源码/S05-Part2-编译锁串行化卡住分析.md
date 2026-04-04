# 02 - 编译锁卡住分析

> 风险等级: 🔴 P0 | 触发条件: 默认配置即触发 | 影响: 所有查询编译排队

---

## 一、问题概述

HiveServer2 **默认配置下**，所有查询的编译过程共享一把全局互斥锁（`SERIALIZABLE_COMPILE_LOCK`），且超时时间为 0（无限等待）。这意味着只要有一个查询的编译过程变慢（如 Metastore 连接慢、优化器处理复杂查询），所有其他查询都会排队等待。

**这是 Hive 最常见的卡住根因之一，且默认配置即存在风险。**

### 因果链

```
[任一查询编译慢（Metastore RPC/复杂优化器/大量分区）]
  → [持有全局编译锁不释放]
    → [COMPILE_LOCK_TIMEOUT=0s → 其他查询无限等待]
      → [所有新查询排队]
        → [用户感知: beeline 提交查询后无响应]
```

---

## 二、源码深度分析

### 2.1 锁的创建: CompileLockFactory

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/lock/CompileLockFactory.java`

```java
// 行 35: 全局单锁 — 所有查询共享
private static final ReentrantLock SERIALIZABLE_COMPILE_LOCK = new ReentrantLock(true);
//                                                                               ^^^^ 公平锁

// 行 40-57: 锁创建逻辑
public static CompileLock newInstance(HiveConf conf, String command) {
    Lock underlying = SERIALIZABLE_COMPILE_LOCK;  // 默认: 全局单锁

    boolean isParallelEnabled = (conf != null)
        && HiveConf.getBoolVar(conf, HiveConf.ConfVars.HIVE_SERVER2_PARALLEL_COMPILATION);
    // ⚠️ 默认 false → 不进入 if 分支 → 使用全局单锁

    if (isParallelEnabled) {
        int compileQuota = HiveConf.getIntVar(conf, 
            HiveConf.ConfVars.HIVE_SERVER2_PARALLEL_COMPILATION_LIMIT);
        underlying = (compileQuota > 0) ?
            SessionWithQuotaCompileLock.instance : 
            SessionState.get().getCompileLock();
    }

    long timeout = HiveConf.getTimeVar(conf,
        HiveConf.ConfVars.HIVE_SERVER2_COMPILE_LOCK_TIMEOUT, TimeUnit.SECONDS);
    // ⚠️ 默认 "0s" → timeout = 0

    return new CompileLock(underlying, timeout, command);
}
```

**关键问题**:
1. `HIVE_SERVER2_PARALLEL_COMPILATION` 默认 `false` → 全局单锁
2. `HIVE_SERVER2_COMPILE_LOCK_TIMEOUT` 默认 `"0s"` → 无限等待
3. 公平锁 `ReentrantLock(true)` 虽然保证 FIFO，但队列中的所有查询都在等

### 2.2 锁的获取: CompileLock

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/lock/CompileLock.java`

```java
// 行 64-99: 核心获取逻辑
private boolean tryAcquire(long timeout, TimeUnit unit) {
    // 第一次尝试: 非阻塞
    try {
        if (underlying.tryLock(0, unit)) {
            return acquired();
        }
    } catch (InterruptedException e) { ... }

    // 第一次失败后:
    if (timeout > 0) {
        // 有超时: tryLock 带超时
        if (!underlying.tryLock(timeout, unit)) {
            LOG.error(ErrorMsg.COMPILE_LOCK_TIMED_OUT...);
            return failedToAcquire();
        }
    } else {
        underlying.lock();  // ⚠️⚠️⚠️ timeout <= 0 → 无限等待!!!
    }
    return acquired();
}
```

**行 93-94 是最危险的代码**:
- 当 `timeout <= 0`（默认就是 0），直接调用 `underlying.lock()` 
- `lock()` 是无限阻塞的，没有超时，没有中断检查
- 如果持锁线程卡在 Metastore RPC 或 HDFS 操作上，所有其他线程永远等待

### 2.3 编译流程中的锁使用: Driver

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/Driver.java`

```java
// 行 428-465: compileInternal 方法
private void compileInternal(String command, boolean deferClose) throws CommandProcessorException {
    // 步骤 1: 等待获取编译锁
    try (CompileLock compileLock = CompileLockFactory.newInstance(driverContext.getConf(), command)) {
        boolean success = compileLock.tryAcquire();  // ⚠️ 可能无限等待

        if (!success) {
            // 只有配置了 timeout > 0 才可能走到这里
            throw ...(COMPILE_LOCK_TIMED_OUT);
        }

        // 步骤 2: 实际编译（持有锁期间）
        try {
            compile(command, true, deferClose);  // ⚠️ 编译全程持锁
        } catch (...) { ... }
    }
    // 步骤 3: 释放锁（try-with-resources 自动释放）
}
```

### 2.4 编译过程中可能卡住的点

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/Compiler.java`

```java
// 行 198: 编译前刷新 Metastore 缓存 — 持有编译锁时的 RPC 调用
Hive.get().getMSC().flushCache();  // ⚠️ synchronized getMSC() + Metastore RPC

// 行 224: 语义分析 — 编译最耗时的阶段
sem.analyze(tree, context);  
// 内部会调用:
//   getMSC().getTable()      — Metastore RPC
//   getMSC().getPartitions()  — Metastore RPC (分区多时非常慢)
//   各种优化器                — 复杂查询耗时长
```

**问题**: 编译全程持有编译锁，而编译过程中有大量可能阻塞的操作

### 2.5 并行编译模式下的配额锁

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/lock/CompileLockFactory.java`

```java
// 行 73-77: SessionWithQuotaCompileLock
@Override
public void lock() {
    SessionState.get().getCompileLock().lock();
    globalCompileQuotas.acquireUninterruptibly();  
    // ⚠️ acquireUninterruptibly() — 不可中断地等待
    // 即使查询被 cancel，这里也不会响应中断
}
```

---

## 三、配置参数详解

| 参数 | 键名 | 默认值 | 说明 |
|------|------|--------|------|
| 并行编译开关 | `hive.driver.parallel.compilation` | `false` | 是否开启并行编译 |
| 编译锁超时 | `hive.server2.compile.lock.timeout` | `0s` | 0 = 无限等待 |
| 并行编译全局限制 | `hive.driver.parallel.compilation.global.limit` | `-1` | -1 = 不限制 |

### 默认配置的问题

```
并行编译=false + 超时=0s
  → 全局单锁 + 无限等待
  → 一个慢编译卡住所有查询
  → HS2 看起来"死了"
```

---

## 四、线上排查

### 4.1 jstack 识别

```bash
# 搜索编译锁等待
grep -B 2 -A 15 "CompileLock\|SERIALIZABLE_COMPILE_LOCK\|compile.*lock" /tmp/hs2_jstack_*.txt
```

**典型 jstack — 等待编译锁的线程**:
```
"HiveServer2-Handler-Pool: Thread-456" WAITING (parking)
  at sun.misc.Unsafe.park(Native Method)
  at java.util.concurrent.locks.LockSupport.park(LockSupport.java:175)
  at java.util.concurrent.locks.AbstractQueuedSynchronizer.parkAndCheckInterrupt(...)
  at java.util.concurrent.locks.AbstractQueuedSynchronizer.acquireQueued(...)
  at java.util.concurrent.locks.AbstractQueuedSynchronizer.acquire(...)
  at java.util.concurrent.locks.ReentrantLock$FairSync.lock(...)
  at java.util.concurrent.locks.ReentrantLock.lock(ReentrantLock.java:228)
  at org.apache.hadoop.hive.ql.lock.CompileLock.tryAcquire(CompileLock.java:94)
  ...
```

**典型 jstack — 持有编译锁但卡在 Metastore 的线程**:
```
"HiveServer2-Handler-Pool: Thread-123" RUNNABLE
  at org.apache.thrift.transport.TSocket.read(TSocket.java:xxx)
  at org.apache.hadoop.hive.metastore.HiveMetaStoreClient.getTable(...)
  at org.apache.hadoop.hive.ql.metadata.Hive.getTable(Hive.java:1797)
  at org.apache.hadoop.hive.ql.parse.SemanticAnalyzer.getMetaData(...)
  at org.apache.hadoop.hive.ql.parse.SemanticAnalyzer.analyzeInternal(...)
  at org.apache.hadoop.hive.ql.Compiler.analyze(Compiler.java:224)
  ...
  - locked <0x00000007xxxxx> (a java.util.concurrent.locks.ReentrantLock$FairSync)
```

### 4.2 日志检查

```bash
# 编译锁超时日志（只有配置了 timeout > 0 才会出现）
grep "COMPILE_LOCK_TIMED_OUT" /var/log/hive/hiveserver2.log | tail -20

# 等待编译锁的日志
grep "Waiting to acquire compile lock" /var/log/hive/hiveserver2.log | tail -20

# 编译耗时
grep "Compiling command\|Semantic Analysis Completed" /var/log/hive/hiveserver2.log | tail -40
```

### 4.3 Metrics 监控

```
# HS2 Metrics 中的编译等待计数
WAITING_COMPILE_OPS  — 当前等待编译锁的操作数
# 如果这个值 > 0 且持续增长，说明编译锁是瓶颈
```

---

## 五、修复建议

### 🔴 紧急操作（立即执行）

**1. 设置编译锁超时（防止无限等待）**:
```xml
<property>
    <name>hive.server2.compile.lock.timeout</name>
    <value>60</value> <!-- 60秒超时，超时后查询报错而不是无限等待 -->
</property>
```

**2. 开启并行编译（解除全局串行化）**:
```xml
<property>
    <name>hive.driver.parallel.compilation</name>
    <value>true</value>
</property>
```

### 🟡 短期修复

**3. 设置并行编译限制（防止编译过多导致 OOM）**:
```xml
<property>
    <name>hive.driver.parallel.compilation.global.limit</name>
    <value>16</value> <!-- 建议: CPU核数 × 2 -->
</property>
```

### 🟢 长期优化

**4. 优化编译速度**:
- 启用 Metastore 本地缓存减少 RPC: `hive.metastore.client.cache.enabled=true`
- 减少分区数量（大量分区导致 `getPartitions` 慢）
- 优化复杂查询的执行计划（减少优化器耗时）

**5. 监控编译耗时**:
- 监控 `WAITING_COMPILE_OPS` 指标
- 对编译时间 > 30s 的查询告警
- 定期分析编译慢的查询并优化

---

## 六、验证修复效果

```bash
# 修改配置后重启 HS2
# 然后并发提交多个查询，观察:

# 1. 确认并行编译生效
grep "Acquired the compile lock" /var/log/hive/hiveserver2.log | wc -l

# 2. 确认没有超时报错
grep "COMPILE_LOCK_TIMED_OUT" /var/log/hive/hiveserver2.log | wc -l

# 3. 监控编译等待时间
grep "WAIT_COMPILE" /var/log/hive/hiveserver2.log | tail -20
```
