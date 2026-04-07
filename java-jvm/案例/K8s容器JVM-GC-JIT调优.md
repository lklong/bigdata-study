# K8s 容器中 JVM GC/JIT 调优

> 来源案例：K8s vs YARN 性能对比（K8s 慢 8%），2026-04-07

---

## G1 GC 在低 CPU 环境下的退化

```
JVM G1 GC ParallelGCThreads 自动计算:
  if (cpu <= 8):
    ParallelGCThreads = max(1, cpu)
  else:
    ParallelGCThreads = 8 + (cpu - 8) * 5/8

当 K8s limit.cores=2, UseContainerSupport=true:
  JVM 感知到 cpu=2 → ParallelGCThreads 可能降到 1-2
  (TencentKonaJDK 8u472 实测: ParallelGCThreads=1)

影响:
  GC P50: 178ms (8线程) → 221ms (1线程) = +24%
  GC Total: 6,482s → 7,781s = +1,299s (+20%)
```

## CICompilerCount 对 JIT 的影响

```
K8s (cpu=2):  CICompilerCount=2
YARN (显式):  CICompilerCount ≥ 4

影响:
  - JIT 编译线程减少 → 热点方法编译排队延迟
  - 前几分钟更多代码走解释执行（interpreter）
  - 稳态后影响减小（大部分热点已编译）
  - 对长时间运行的任务(如 74 分钟)影响有限，但前期 warmup 会慢
```

## K8s 容器 JVM 调优推荐参数

```bash
# 显式覆盖容器自动检测（适用于所有 K8s Spark 任务）
-XX:ParallelGCThreads=8       # 强制 8 个 GC 并行线程
-XX:ConcGCThreads=2            # 2 个并发标记线程
-XX:+UseStringDeduplication    # 字符串去重（减少堆压力）
-XX:InitiatingHeapOccupancyPercent=35  # 更早触发 Mixed GC
-XX:+UseG1GC                   # 确保用 G1

# 可选: 直接告诉 JVM 可用 CPU 数（覆盖 cgroup 检测）
-XX:ActiveProcessorCount=4     # 让 JVM 认为有 4 CPU

# 可选: 关闭容器感知（不推荐，但可用于调试）
-XX:-UseContainerSupport       # 回退到宿主机 CPU 数
```
