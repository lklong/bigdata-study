# S02: HS2 OOM 后进程不退出、端口不响应

## 1. 场景描述

> HS2 经常出现 OutOfMemoryError，但 JVM 进程不退出（`ps aux | grep HiveServer2` 还在），Thrift 服务端口 7001 已经不响应了。

---

## 2. 根因分析（源码级）

### 2.1 OOM 在代码中的传播路径

OOM 发生在查询执行线程中，关键问题是 **OOM 无法传播到让进程退出的位置**。

```
OOM 发生
  │
  ▼ 异步模式（Beeline 默认 runAsync=true）
SQLOperation.BackgroundWork.run()                        ← SQLOperation.java:314
  │
  ├─ prepare() 或 runQuery() 抛出 OutOfMemoryError
  │    ├─ SQLOperation.prepare():215  → throw e（OOM 重抛 ✅）
  │    └─ SQLOperation.runQuery():250 → throw (OutOfMemoryError) e（OOM 重抛 ✅）
  │
  ├─ 但上层 catch 链断了：
  │    BackgroundWork.run() 内部:
  │    try {
  │        runQuery();
  │    } catch (HiveSQLException e) {     ← ⚠️ 只 catch HiveSQLException，不 catch Error
  │        setOperationException(e);
  │    }
  │    // OOM 从这里飞出去
  │
  │    外层:
  │    try {
  │        currentUGI.doAs(doAsAction);
  │    } catch (Exception e) {            ← ⚠️ 只 catch Exception，不 catch Error
  │        setOperationException(new HiveSQLException(e));
  │    }
  │    // OOM 继续飞出去，杀死当前后台线程
  │
  ▼ OOM 最终去了哪里？
ThreadPoolExecutor 的 worker 线程被杀死
  │
  ├─ 但 TThreadPoolServer.serve() 的 accept 循环在另一个线程
  │   ThriftBinaryCLIService.run():
  │     server.serve()  ← accept 循环不受 worker 线程 OOM 影响
  │
  └─ ThriftBinaryCLIService.run() 的 catch (Throwable t) + ExitUtil.terminate(-1)
     永远不会触发，因为 OOM 不在 serve() 线程中
```

### 2.2 关键代码证据

**证据 1**: `ThriftCLIService.ExecuteStatement()` — 有意只 catch Exception

```java
// ThriftCLIService.java:670-675
} catch (Exception e) {
    // Note: it's rather important that this (and other methods) catch Exception, not Throwable;
    // in combination with HiveSessionProxy.invoke code, perhaps unintentionally, it used
    // to also catch all errors; and now it allows OOMs only to propagate.
    LOG.error("Failed to execute statement [request: {}]", req, e);
```

**设计意图**：让 OOM 穿透到 Thrift worker 线程，杀死该线程。但问题是：
- 异步模式下，SQL 在**后台线程池**执行，OOM 杀死的是后台线程
- Thrift worker 线程只是提交了异步任务就返回了

**证据 2**: `BackgroundWork.run()` — OOM 在后台线程被静默消化

```java
// SQLOperation.java:330-357
try {
    runQuery();                          // OOM 从这里抛出
} catch (HiveSQLException e) {           // ← 不 catch OutOfMemoryError
    setOperationException(e);
}
// OOM 飞出 PrivilegedExceptionAction.run()

try {
    currentUGI.doAs(doAsAction);
} catch (Exception e) {                  // ← 不 catch Error
    setOperationException(new HiveSQLException(e));
}
// OOM 飞出 BackgroundWork.run()，杀死这一个后台线程
// ThreadPoolExecutor 默认行为：该 worker 线程死亡，池会补一个新线程
```

**证据 3**: `ThriftBinaryCLIService.run()` — ExitUtil 永远不会被调用

```java
// ThriftBinaryCLIService.java:206-218
public void run() {
    try {
        server.serve();  // TThreadPoolServer 的 accept 循环
    } catch (Throwable t) {
        ExitUtil.terminate(-1);  // ← 只有 serve() 本身异常才到这里
    }
}
```

`TThreadPoolServer.serve()` 内部是 `while (!stopped) { socket = serverTransport.accept(); threadPool.execute(processor); }`，OOM 在 threadPool 的 worker 线程中，不在 accept 主循环中。

**证据 4**: Shutdown Hook 不响应 OOM

```java
// HiveServer2.java:456-460
ShutdownHookManager.addGracefulShutDownHook(() -> graceful_stop(), timeout);
// 只响应 SIGTERM/SIGINT，OOM 不会触发 JVM shutdown
```

### 2.3 社区确认: HIVE-27414

> **[HIVE-27414] HiveServer2 is not shut down properly in OOM**
> - 确认了 OOM 时 HS2 不正确关闭的问题
> - 涉及 `oomHook` 调用 `HiveServer2.stop()`

---

## 3. 为什么端口不响应但进程还在

```
JVM 堆 OOM 后的状态：

┌─ 进程主线程（main）           → 还活着，阻塞在 CountDownLatch
├─ Thrift Server 线程           → 还活着，accept 循环正常
├─ Thrift Worker 线程池         → 部分线程已死，但 accept 还在接新连接
├─ 后台执行线程池               → 部分线程已死
└─ GC 线程                      → 疯狂 Full GC，99% 时间在 GC

实际表现：
1. 端口还在监听（accept 循环还活着）
2. 新连接可以建立（TCP 三次握手成功）
3. 但执行任何操作都失败：
   - 新对象分配失败 → OOM
   - GC overhead limit exceeded → CPU 100% GC
   - Thrift worker 线程死光 → 新请求无线程处理
```

---

## 4. 解决方案（按优先级）

### 方案 1: JVM 参数 — OOM 时自动退出（推荐，立即生效）

在 `hive-env.sh` 中添加：

```bash
# 方案 A: JDK 8u92+ 推荐
export HIVE_SERVER2_HADOOP_OPTS="$HIVE_SERVER2_HADOOP_OPTS -XX:+ExitOnOutOfMemoryError"

# 方案 B: 生成 core dump 后退出（便于事后分析）
export HIVE_SERVER2_HADOOP_OPTS="$HIVE_SERVER2_HADOOP_OPTS -XX:+CrashOnOutOfMemoryError"

# 方案 C: 自定义脚本（可以在退出前做清理/告警）
export HIVE_SERVER2_HADOOP_OPTS="$HIVE_SERVER2_HADOOP_OPTS -XX:OnOutOfMemoryError='kill -9 %p'"
```

**推荐方案 A**，配合外部监控自动重启（systemd/supervisor/K8s）。

### 方案 2: OOM 前预防 — 内存调优

```bash
# 1. 增大 HS2 堆内存（根据并发量调整）
export HIVE_SERVER2_HADOOP_OPTS="-Xms8g -Xmx8g"

# 2. 限制并发查询数（减少内存压力）
hive.server2.thrift.max.worker.threads = 200  # 默认 500，改小
hive.server2.async.exec.threads = 50          # 默认 100，改小

# 3. 限制单查询内存
hive.query.timeout.seconds = 600              # 查询超时
hive.tez.container.size = 4096                # Tez Container 内存

# 4. G1GC 调优
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+ParallelRefProcEnabled
-XX:+UnlockExperimentalVMOptions
-XX:G1NewSizePercent=20
```

### 方案 3: 外部健康检查 — 自动重启

```bash
#!/bin/bash
# hs2_health_check.sh — 每分钟 cron 执行
PORT=7001
if ! nc -z localhost $PORT 2>/dev/null; then
    echo "$(date) HS2 port $PORT not responding, restarting..." >> /var/log/hs2_watchdog.log
    # dump 现场
    jstack $(pgrep -f HiveServer2) > /tmp/hs2_jstack_$(date +%s).log 2>&1
    jmap -heap $(pgrep -f HiveServer2) > /tmp/hs2_heap_$(date +%s).log 2>&1
    # kill 并重启
    kill -9 $(pgrep -f HiveServer2)
    sleep 5
    nohup hive --service hiveserver2 &
fi
```

### 方案 4: OOM 根因排查 — 找到内存泄漏

```bash
# 1. OOM 前自动 dump
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/hs2_oom.hprof

# 2. 常见 HS2 内存泄漏点（源码级）
# a) SessionState 未释放 — Session 关闭但 SessionState 对象还在
# b) HiveMetaStoreClient 连接泄漏 — Hive.closeCurrent() 未调用
# c) 大结果集缓存 — hive.server2.thrift.resultset.max.fetch.size 过大
# d) 查询计划缓存 — QueryResultsCache 过大
# e) 日志对象累积 — operationLog 未清理

# 3. 排查步骤
jmap -histo:live <pid> | head -30   # 查看对象分布
jmap -heap <pid>                     # 查看堆使用率
jstat -gcutil <pid> 1000 10          # 观察 GC 频率
```

---

## 5. 排障决策树

```
现象: HS2 进程在但端口不响应
│
├─ 1. 确认进程状态
│   ps aux | grep HiveServer2
│   jps -l | grep HiveServer2
│   ├─ 进程不在 → 查 HS2 日志最后异常，重启
│   └─ 进程在 →
│
├─ 2. 检查 GC 状态
│   jstat -gcutil <pid> 1000 5
│   ├─ Old Gen 接近 100% + Full GC 频繁 → OOM/GC overhead
│   │   ├─ 立即: kill -9 <pid> + 重启
│   │   ├─ 长期: 加 -XX:+ExitOnOutOfMemoryError
│   │   └─ 根因: jmap -histo / 分析 heap dump
│   └─ GC 正常 →
│
├─ 3. 检查线程状态
│   jstack <pid> | grep -c "HiveServer2-Handler-Pool"
│   ├─ 所有线程都在 WAITING/TIMED_WAITING → 线程池正常但 accept 出问题
│   ├─ 线程数为 0 或极少 → 线程池被 OOM 杀光
│   └─ 大量线程 BLOCKED → 死锁（jstack 分析）
│
├─ 4. 检查端口
│   netstat -tlnp | grep 7001
│   ├─ 端口不在 → Thrift Server 线程已死
│   └─ 端口在但连不上 → accept 正常但处理请求 OOM
│
└─ 5. 检查 HS2 日志
    grep -i "OutOfMemory\|GC overhead" /var/log/hive/hiveserver2.log
    ├─ 有 OOM → 确认是内存问题
    └─ 无 OOM → 检查其他异常
```

---

## 6. JIRA 参考

| JIRA | 描述 |
|------|------|
| **HIVE-27414** | HS2 OOM 时不正确关闭 |
| HIVE-27213 | CBO 降级导致查询结果错误 |
| HIVE-26379 | 编译锁异常时不释放 |
