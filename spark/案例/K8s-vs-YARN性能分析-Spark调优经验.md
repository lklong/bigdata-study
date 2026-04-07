# Spark on K8s 性能调优经验

> 来源案例：K8s vs YARN 性能对比（K8s 慢 8%），2026-04-07

---

## 经验规则

### R-K8S-001: 必须显式设置 GC 线程数

```
问题: K8s UseContainerSupport=true → JVM 只看到 cgroup CPU limit
     当 limit ≤ 2 时 ParallelGCThreads 自动降为 1，GC 性能退化 20%+
修复: spark.executor.extraJavaOptions=... -XX:ParallelGCThreads=8 -XX:ConcGCThreads=2
诊断: Event Log 中 jvmGCTime P50 对比
安全: 🟢 SAFE — 只影响 GC 线程数，可秒级回滚
```

### R-K8S-002: executorCpuTime 是诊断 I/O vs CPU 瓶颈的关键指标

```
方法: 从 Event Log 的 SparkListenerTaskEnd 提取:
  - executorCpuTime (ns): JVM ThreadMXBean 统计的真实 CPU 消耗
  - executorRunTime (ms): wall clock 时间
公式: I/O等待 = executorRunTime - executorCpuTime/1e6
     CPU利用率 = executorCpuTime / (executorRunTime * 1e6)
判定: CPU利用率 < 40% = I/O bound; > 70% = CPU bound

源码: TaskMetrics.scala → ThreadMXBean.getCurrentThreadCpuTime()
```

### R-K8S-003: Spark 3.3.2 hostNetwork 需通过 Pod Template 实现

```
源码验证: Config.scala (720行) 无 hostNetwork 配置项
         BasicDriverFeatureStep.scala / BasicExecutorFeatureStep.scala 无 withHostNetwork()
实现方式: Pod Template YAML
  apiVersion: v1
  kind: Pod
  spec:
    hostNetwork: true
    dnsPolicy: ClusterFirstWithHostNet
配置: spark.kubernetes.executor.podTemplateFile=/path/to/template.yaml
```

### R-K8S-004: 动态分配应设置 initialExecutors

```
问题: 默认 initialExecutors=1，指数扩容 1→2→4→8→...→100 需要 ~25s
修复: spark.dynamicAllocation.initialExecutors=100
安全: 🟢 SAFE
```

### R-K8S-005: ORC + ZSTD 不依赖 Hadoop Native Library

```
源码验证:
  - ORC 1.7.8 → io.airlift.compress.zstd (aircompressor 纯 Java)
  - Spark Core → com.github.luben:zstd-jni:1.5.2-1 (JNI 自带 .so)
  - NativeCodeLoader 加载的是 libhadoop.so，不含 zstd
结论: "Unable to load native-hadoop library" WARN 不影响 zstd 性能
```

---

## scan time 源码解析

```scala
// DataSourceScanExec.scala 第 512-519 行
// scan time 仅在 columnar (向量化) 模式下存在
if (supportsColumnar) {
  Some("scanTime" -> SQLMetrics.createTimingMetric(sparkContext, "scan time"))
}

// 第 558-563 行 — 计量逻辑
override def hasNext: Boolean = {
  val startNs = System.nanoTime()
  val res = batches.hasNext  // ← COS GET + zstd 解压 + ORC 解码
  scanTime += NANOSECONDS.toMillis(System.nanoTime() - startNs)
  res
}
```

## K8s CPU 感知机制

```
JVM 8u472 (TencentKona) + UseContainerSupport=true:
  1. 读 /sys/fs/cgroup/cpu/cpu.cfs_quota_us 和 cpu.cfs_period_us
  2. available_cpus = quota / period
  3. ParallelGCThreads = max(1, ceil(available_cpus * 5/8))
  4. CICompilerCount = max(1, available_cpus)

当 limit.cores=2 → quota=200000, period=100000 → cpu=2
  → ParallelGCThreads = max(1, ceil(2*5/8)) = max(1, 2) = 2
  
实际观测 ParallelGCThreads=1，说明可能是 KonaJDK 的 ergonomics 策略略有不同
```
