# 05 - 动态分区裁剪（DPP）永久阻塞分析

> 风险等级: 🔴 P0 | 触发条件: Source Vertex 失败无信号 | 影响: 单查询永久挂起

---

## 一、问题概述

`DynamicPartitionPruner` 使用 `BlockingQueue.take()` 等待分区裁剪事件。如果 Source Vertex 失败了但没有发送完成信号，`take()` 会**永远阻塞**，导致查询永远不会结束。

---

## 二、源码分析

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/tez/DynamicPartitionPruner.java`

```java
// 行 101-102: 事件队列
private final BlockingQueue<Object> queue = new LinkedBlockingQueue<>();
private static final Object VERTEX_FINISH_TOKEN = new Object();

// 行 407-420: 核心等待逻辑
private void processEvents() throws SerDeException, IOException, InterruptedException {
    int eventCount = 0;
    while (true) {
        Object element = queue.take();  // ⚠️⚠️⚠️ 无超时！永久阻塞！

        if (element == VERTEX_FINISH_TOKEN) {
            String updatedSource = finishedVertices.poll();
            calculateFinishCondition(updatedSource);
            if (checkForSourceCompletion(updatedSource)) {
                break;  // 只有所有 source 都完成才退出
            }
        } else {
            // 处理分区裁剪事件
        }
    }
}
```

**问题**: 
- `queue.take()` 没有超时版本（应该用 `queue.poll(timeout, unit)`）
- 如果某个 Source Vertex 的 task 失败且没有发送 `VERTEX_FINISH_TOKEN`，`take()` 永远阻塞
- 这个线程阻塞不会被 cancel 中断（除非线程被 interrupt）

---

## 三、排查与修复

### jstack 识别

```bash
grep -A 10 "DynamicPartitionPruner\|LinkedBlockingQueue.take" /tmp/hs2_jstack_*.txt
```

**典型 jstack**:
```
"Thread-xxx" WAITING (parking)
  at java.util.concurrent.locks.LockSupport.park(...)
  at java.util.concurrent.LinkedBlockingQueue.take(...)
  at org.apache.hadoop.hive.ql.exec.tez.DynamicPartitionPruner.processEvents(DynamicPartitionPruner.java:412)
```

### 修复建议

1. **代码修复**: 将 `queue.take()` 改为 `queue.poll(timeout, TimeUnit.MINUTES)` 并处理超时
2. **监控**: 对执行时间异常长的查询告警
3. **Workaround**: 设置查询级超时 `hive.server2.idle.operation.timeout`
