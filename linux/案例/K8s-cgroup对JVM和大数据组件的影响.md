# K8s cgroup 对 JVM/大数据组件的影响

> 来源案例：K8s vs YARN 性能对比（K8s 慢 8%），2026-04-07

---

## cgroup CFS quota 对 JVM 的影响链路

```
K8s Pod spec:
  resources.limits.cpu: 2     → cgroup cpu.cfs_quota_us = 200000
  resources.requests.cpu: 1   → scheduler 分配依据

JVM UseContainerSupport=true (JDK 8u191+):
  → 读 cpu.cfs_quota_us / cpu.cfs_period_us = available_cpus
  → ParallelGCThreads = f(available_cpus)
  → ConcGCThreads = max(1, ParallelGCThreads/4)
  → CICompilerCount = max(1, available_cpus)

影响:
  1. GC 并行线程减少 → STW 暂停时间增加
  2. JIT 编译线程减少 → 热点代码编译延迟
  3. CPU burst 被 CFS throttle → 微观延迟抖动
```

## K8s Pod vs YARN Container 资源隔离差异

| 维度 | K8s Pod | YARN Container |
|------|---------|---------------|
| **CPU 隔离** | cgroup CFS hard limit (quota/period) | vcore 软限制（默认不做 cgroup 硬限） |
| **CPU burst** | 被 quota 严格限制 | 可借用宿主机空闲 CPU |
| **内存隔离** | limit=request → Guaranteed QoS → OOM Kill | 物理内存 + pmem 监控 → Container Kill |
| **网络** | CNI 虚拟网络（veth + bridge/overlay） | 宿主机网络直连 |
| **磁盘** | hostPath/emptyDir/PVC | 本地磁盘直接访问 |

## CNI 网络对大流量 I/O 的影响

```
YARN (宿主机网络):
  Application → Socket → TCP/IP → NIC → VPC → COS
  延迟: ~0.1ms per packet

K8s (CNI overlay):
  Application → veth → CNI bridge → iptables/conntrack → NIC → VPC → COS
  延迟: ~0.2-0.5ms per packet

对大文件顺序读 (每 task ~380MB):
  - 每个 HTTP GET 分成多个 TCP segment (~64KB MTU)
  - 380MB / 64KB ≈ 6,100 packets
  - 每 packet 多 0.1-0.3ms → 每 task 多 0.6-1.8s
  - 乘以 34,466 tasks → 20,000-60,000s 总差距（分摊到 100 executor 后 ~200-600s 端到端）
```
