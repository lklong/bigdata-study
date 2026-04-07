# Spark executorCpuTime 源码解析与 I/O 诊断方法

> 来源案例：K8s vs YARN 性能对比（K8s 慢 8%），2026-04-07
> 任务编号: SP-01, SP-02, CH-02

---

## executorCpuTime 源码追踪

### 定义位置

```
文件: core/src/main/scala/org/apache/spark/executor/TaskMetrics.scala
```

`executorCpuTime` 是 JVM 级别的 **真实 CPU 消耗纳秒数**，通过 `ThreadMXBean.getCurrentThreadCpuTime()` 获取。

**不包含**：I/O 等待、线程睡眠、锁等待、GC STW 暂停
**包含**：用户态 CPU + 内核态 CPU（数据拷贝、系统调用等）

### Event Log 中的字段

```json
{
  "Task Metrics": {
    "Executor Run Time": 12574,         // ms, wall clock
    "Executor CPU Time": 4012345678,    // ns, 真实 CPU
    "JVM GC Time": 221,                 // ms, GC 暂停
    "Executor Deserialize Time": 9,     // ms, task 反序列化
    "Result Serialization Time": 0,     // ms, 结果序列化
    "Getting Result Time": 0            // ms
  }
}
```

### 时间分解公式

```
executorRunTime (wall clock, ms)
  = executorCpuTime (ns → ms) 
  + jvmGCTime (ms)
  + I/O Wait (隐含, = wall - cpu - gc)
  + Thread Scheduling / Context Switch (极小)

I/O 等待时间 = executorRunTime - executorCpuTime/1e6 - jvmGCTime
CPU 利用率   = executorCpuTime / (executorRunTime × 1e6)
```

**注意**: jvmGCTime 包含在 executorRunTime 中，但不包含在 executorCpuTime 中。
所以严格的 I/O 等待 = wall - cpu/1e6（GC 时间已经被排除在 cpuTime 之外了）。

---

## scan time 源码解析

### 定义位置

```
文件: sql/core/src/main/scala/org/apache/spark/sql/execution/DataSourceScanExec.scala
```

### 源码（第 507-573 行）

```scala
// 第 512-519 行 — 仅 columnar 模式有 scan time
override lazy val metrics = Map(...) ++ {
  if (supportsColumnar) {
    Some("scanTime" -> SQLMetrics.createTimingMetric(sparkContext, "scan time"))
  } else {
    None  // row 模式没有 scan time！
  }
}

// 第 552-573 行 — 计量逻辑
protected override def doExecuteColumnar(): RDD[ColumnarBatch] = {
  val scanTime = longMetric("scanTime")
  inputRDD.asInstanceOf[RDD[ColumnarBatch]].mapPartitionsInternal { batches =>
    new Iterator[ColumnarBatch] {
      override def hasNext: Boolean = {
        val startNs = System.nanoTime()
        val res = batches.hasNext  // ← 文件 I/O + 解压 + 向量化解码 全在这里
        scanTime += NANOSECONDS.toMillis(System.nanoTime() - startNs)
        res
      }
      override def next(): ColumnarBatch = {
        val batch = batches.next()
        numOutputRows += batch.numRows()
        batch
      }
    }
  }
}
```

### 关键理解

1. **scan time = `batches.hasNext` 的累计耗时**，不是 `next()` 的时间
2. `hasNext` 内部调用链: `FileScanRDD.hasNext → OrcColumnarBatchReader.nextBatch → orc-core 读数据 → COS HTTP GET + zstd 解压 + ORC 列式解码`
3. **仅在 columnar（向量化）模式下才有** — row 模式的注释说"逐行追踪太昂贵"
4. **scan time ⊂ executorRunTime** — scan time 是 run time 的一部分

### duration vs scan time

Event Log Stage Accumulables 中有两个指标：
```
duration: 440,554,545 ms  ← 包含 scan + 非 scan（ORC write + COS upload + commit）
scan time: 212,424,224 ms ← 只包含读（COS GET + zstd 解压 + ORC 解码）
non-scan = duration - scan = 228,130,321 ms ← 写出部分
```

---

## I/O 诊断标准方法（从本案例提炼）

### Step 1: 从 Event Log 提取关键指标

```python
# 提取 Stage N 的 Task 级指标
grep 'SparkListenerTaskEnd' event_log | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    if d.get('Stage ID') != TARGET_STAGE: continue
    m = d['Task Metrics']
    run_time = m['Executor Run Time']      # ms
    cpu_time = m['Executor CPU Time']      # ns  
    gc_time  = m['JVM GC Time']            # ms
    io_wait  = run_time - cpu_time/1e6     # ms (包含 GC)
    cpu_util = cpu_time / (run_time * 1e6) # 0-1
"
```

### Step 2: 判断瓶颈类型

| CPU 利用率 | 瓶颈类型 | 优化方向 |
|-----------|---------|---------|
| < 30% | **重度 I/O bound** | 网络/存储优化、增大并发 |
| 30-50% | **I/O bound** | 本案例（32%），网络 + GC |
| 50-70% | **混合** | 两边都要调 |
| > 70% | **CPU bound** | 增加 CPU、优化算法/GC |

### Step 3: 进一步拆解 I/O

```
如果 I/O bound:
  1. scan time 占比高 → 读 I/O 是瓶颈 → 优化 COS/HDFS 读取
  2. non-scan 占比高 → 写 I/O 是瓶颈 → 优化写出/commit
  3. GC 占比高 → GC 也是因素 → ParallelGCThreads
  4. 都不高 → 可能是线程调度/cgroup throttle
```
