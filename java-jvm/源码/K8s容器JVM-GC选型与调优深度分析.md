# JVM GC 在 K8s 容器环境的选型与调优

> JVM Expert 延伸学习 — 从 ParallelGCThreads 1 vs 8 问题深入

## 一、问题回顾

K8s vs YARN 分析中发现：
- K8s：`ParallelGCThreads=1`（JVM 自动感知容器 CPU limit=2）
- YARN：`ParallelGCThreads=8`（显式配置）
- 导致 GC 总时间差异 +1,299s (+20%)

这揭示了一个核心问题：**JVM GC 在容器环境下的行为与裸机完全不同**。

## 二、JVM 容器感知机制

### 2.1 UseContainerSupport（JDK 8u191+）

```
JVM 启动时：
1. 检测 /proc/self/cgroup (cgroup v1) 或 /sys/fs/cgroup (cgroup v2)
2. 读取 CPU quota: cpu.cfs_quota_us / cpu.cfs_period_us
3. 读取 Memory limit: memory.limit_in_bytes
4. 计算 "可用 CPU 数" = quota / period (向下取整，最小为 1)
5. 设置 Runtime.availableProcessors() = 上述值
6. 所有 GC 线程数、JIT 编译器线程数都基于此值自动计算
```

### 2.2 CPU 数影响的 JVM 内部参数

| 参数 | 计算公式 | CPU=1 时 | CPU=2 时 | CPU=8 时 |
|------|---------|----------|----------|----------|
| ParallelGCThreads | `cpu <= 8 ? cpu : 8 + (cpu-8)*5/8` | **1** | **2** | **8** |
| ConcGCThreads (G1) | `max(1, ParallelGCThreads/4)` | **1** | **1** | **2** |
| CICompilerCount | `max(1, min(cpu/2, 2))` | **1** | **1** | **2** |
| G1ConcRefinementThreads | `ParallelGCThreads` | **1** | **2** | **8** |

**这就是为什么 CPU limit 设小了，整个 JVM 都变慢** — 不只是 GC，连 JIT 编译都受影响。

### 2.3 本案例的实际情况

```
K8s:
  spark.kubernetes.executor.request.cores = 1
  spark.kubernetes.executor.limit.cores = 2
  → JVM 看到 2 个 CPU
  → ParallelGCThreads = 2 (不是 1！之前的分析可能有误，需要从 JVM flags 再确认)
  → CICompilerCount = 1

YARN:
  显式配置 -XX:ParallelGCThreads=8
  → 覆盖了自动检测值
  → CICompilerCount = 2
```

## 三、G1 GC 深度分析

### 3.1 G1 在容器中的关键参数

```properties
# G1 核心参数
-XX:+UseG1GC                          # 使用 G1（JDK 9+ 默认）
-XX:G1HeapRegionSize=4m               # Region 大小（auto: heap/2048, min 1MB, max 32MB）
-XX:MaxGCPauseMillis=200              # 目标暂停时间
-XX:G1NewSizePercent=5                # 新生代最小比例
-XX:G1MaxNewSizePercent=60            # 新生代最大比例
-XX:InitiatingHeapOccupancyPercent=45 # 触发并发标记的堆占用率

# 容器环境必调
-XX:ParallelGCThreads=8               # STW 阶段并行线程数
-XX:ConcGCThreads=2                   # 并发标记线程数
-XX:G1ConcRefinementThreads=8         # Remembered Set 维护线程数
```

### 3.2 G1 GC 在低线程数下的退化

```
正常（8 线程）:
  Young GC STW:  扫描 8 个 Region 并行 → ~20ms
  Mixed GC STW:  并发标记 8 线程 → ~50ms
  总暂停: ~70ms / 次

退化（1-2 线程）:
  Young GC STW:  串行/2线程扫描 → ~80ms (4x)
  Mixed GC STW:  1-2 线程标记 → ~200ms (4x)
  总暂停: ~280ms / 次

影响:
  每 task 平均 GC 暂停: 188ms (YARN/8线程) vs 226ms (K8s/低线程) = +38ms
  34466 tasks → 累计 +1,299s
```

### 3.3 G1 Region 大小选择

```
heap = 4GB → G1HeapRegionSize = 4GB/2048 = 2MB (auto)

建议:
  heap < 4GB  → RegionSize = 2MB
  heap 4-8GB  → RegionSize = 4MB
  heap 8-16GB → RegionSize = 8MB
  heap > 16GB → RegionSize = 16MB

原则: 大 Region 减少 Region 数量 → 减少 GC 扫描开销，
      但大 Region 内部碎片增加。
```

## 四、ZGC — 容器环境的更优选择？

### 4.1 ZGC 核心优势

```
ZGC (JDK 15+):
  - 暂停时间 < 1ms（不随堆大小增长）
  - 不需要设置 ParallelGCThreads（并发染色指针，非 STW）
  - 内存开销略高（~3% 额外堆空间用于 colored pointers）

对比:
  G1 暂停时间: 50-500ms（随堆/region 数增加）
  ZGC 暂停时间: < 1ms（恒定）
```

### 4.2 ZGC 在容器中的注意事项

```properties
# ZGC 参数（JDK 17+）
-XX:+UseZGC
-XX:ZCollectionInterval=0          # 自动触发（不要手动设）
-XX:SoftMaxHeapSize=3g             # 软上限，ZGC 尽量在此范围内

# 容器环境注意:
# 1. ZGC 需要额外 3% 虚拟内存 → container memory limit 要留余量
# 2. ZGC 不受 ParallelGCThreads 影响 → 容器 CPU 感知问题消失！
# 3. ZGC 需要 Linux 4.15+ 内核（K8s 集群通常满足）
```

### 4.3 为什么 Spark on K8s 暂时不推荐 ZGC

```
1. Spark 3.3.2 默认 JDK 8 → ZGC 不可用（需要 JDK 15+）
2. Spark 3.5+ 支持 JDK 17 → 可以用 ZGC
3. ZGC 的内存开销在 executor 内存紧张时是问题
4. G1 + 正确的 ParallelGCThreads 设置已经够用
```

## 五、容器 JVM GC 最佳实践

### 5.1 通用推荐（Spark on K8s）

```properties
# executor JVM 参数
spark.executor.extraJavaOptions=\
  -XX:+UseG1GC \
  -XX:ParallelGCThreads=8 \
  -XX:ConcGCThreads=2 \
  -XX:G1ConcRefinementThreads=8 \
  -XX:CICompilerCount=2 \
  -XX:+UseContainerSupport \
  -XX:ActiveProcessorCount=4 \
  -XX:InitiatingHeapOccupancyPercent=35 \
  -XX:G1HeapRegionSize=4m \
  -XX:MaxGCPauseMillis=200
```

关键点：
- `ParallelGCThreads=8` — **显式覆盖容器自动检测**
- `ActiveProcessorCount=4` — 告诉 JVM "我有 4 个 CPU"，即使 cgroup 只分了 1-2 个
- `CICompilerCount=2` — 保证 JIT 编译不拖慢热点代码

### 5.2 内存配置

```properties
# K8s Pod memory limit 必须 > executor memory + overhead
# 公式: pod_limit = spark.executor.memory + spark.executor.memoryOverhead + 384MB(JVM元数据)

spark.executor.memory=4g
spark.executor.memoryOverhead=1g
# Pod limit 应 ≥ 5.5g (加 384MB 安全余量)
spark.kubernetes.executor.limit.memory=6g
```

### 5.3 CPU 配置

```properties
# request = 实际需要的 CPU 核数
# limit = request × 2~4（给 GC/JIT 留空间）
spark.kubernetes.executor.request.cores=2
spark.kubernetes.executor.limit.cores=4
# 这样 JVM 看到 4 个 CPU → ParallelGCThreads=4（如果不显式设）
```

## 六、GC 日志分析方法

```properties
# 开启 GC 详细日志
spark.executor.extraJavaOptions=... \
  -Xlog:gc*:file=/tmp/gc.log:time,level,tags:filecount=5,filesize=10M
```

```bash
# 分析 GC 日志
# 1. GC 频率和暂停时间
grep "Pause" gc.log | awk '{print $NF}' | sort -n | tail -20

# 2. 吞吐率 (应 > 95%)
# 应用时间 / (应用时间 + GC暂停时间)

# 3. 堆使用率趋势
grep "Heap" gc.log | grep "after" | awk '{print $NF}'
```

## 七、决策树

```
Spark on K8s GC 选型:
│
├─ JDK 8 (Spark 3.3.x)
│  └─ 用 G1 + 显式设 ParallelGCThreads ✅
│
├─ JDK 11 (Spark 3.4+)
│  ├─ 内存 < 8GB → G1 ✅
│  └─ 内存 ≥ 8GB → G1（ZGC 实验性）
│
└─ JDK 17 (Spark 3.5+)
   ├─ 延迟敏感 → ZGC ✅
   ├─ 吞吐优先 → G1 ✅
   └─ 内存紧张 → G1 ✅
```

---

*JVM Expert 学习产出 | 2026-04-08 | 来源：K8s vs YARN 案例 GC 差异延伸*
