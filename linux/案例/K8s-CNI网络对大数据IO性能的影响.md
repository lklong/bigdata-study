# K8s Pod 网络性能深度分析 — CNI vs 宿主机网络

> 来源案例：K8s vs YARN 性能对比，2026-04-07
> 任务编号: OS-02

---

## CNI 网络数据路径

### YARN Container（宿主机网络）

```
Application → Socket API
  → TCP/IP Stack (内核)
  → NIC Driver
  → Physical NIC → VPC → COS/HDFS

跳数: 1 跳
封装: 无额外封装
连接跟踪: 无 conntrack
MTU: 1500 (标准以太网) 或 9000 (Jumbo Frame)
```

### K8s Pod（Overlay 网络，如 Flannel VXLAN）

```
Application → Socket API
  → TCP/IP Stack (Pod network namespace)
  → veth pair (虚拟网卡对)
  → Linux Bridge (cbr0) 或 CNI 插件处理
  → iptables/nftables (DNAT/SNAT/conntrack)
  → VXLAN 封装 (如果是 overlay)
  → Host TCP/IP Stack
  → NIC Driver
  → Physical NIC → VPC → COS/HDFS

跳数: 3-5 跳 (取决于 CNI 插件)
封装: VXLAN 头 (50 bytes) 或 IPIP 头 (20 bytes)
连接跟踪: conntrack 表查询 (每 packet)
MTU: 1450 (VXLAN) 或 1480 (IPIP) — 比宿主机小
```

### K8s Pod（hostNetwork=true）

```
Application → Socket API
  → TCP/IP Stack (Host network namespace) ← 直接用宿主机
  → NIC Driver
  → Physical NIC → VPC → COS/HDFS

跳数: 1 跳 (和 YARN 相同!)
封装: 无
连接跟踪: 无额外 conntrack
MTU: 1500/9000 (和宿主机相同)
```

## 性能影响量化

### Per-packet 开销

| 操作 | CNI Overlay | hostNetwork | 差异 |
|------|------------|-------------|------|
| veth 数据拷贝 | ~50ns | 0 | +50ns |
| iptables 规则匹配 | ~100-500ns | 0 | +100-500ns |
| conntrack 查询 | ~200ns | 0 | +200ns |
| VXLAN 封装/解封装 | ~200ns | 0 | +200ns |
| **合计 per-packet** | **+550-950ns** | **0** | |

### 对 COS 大文件读取的影响

```
每个 Task 读取 ~380 MB (0.5 × 760MB 文件)
TCP segment 大小: ~1400 bytes (VXLAN MTU 1450 - TCP/IP headers)
每 Task packets: 380MB / 1400B ≈ 285,000 packets

Per-packet 额外延迟: 700ns (取中间值)
每 Task 额外延迟: 285,000 × 700ns ≈ 200ms

但这是纯 CPU 开销（内核态），会被 pipelining 掩盖
实际影响: 每 Task ~50-200ms (取决于 CPU 竞争)
```

### 对 34,466 Tasks 的总影响

```
保守估计 (50ms/task):  50 × 34,466 = 1,723s (分摊到 100 executor → ~17s 端到端)
中间估计 (100ms/task): 100 × 34,466 = 3,447s (→ ~34s 端到端)
激进估计 (200ms/task): 200 × 34,466 = 6,893s (→ ~69s 端到端)

结论: CNI 网络开销贡献约 17-69s 端到端差距 (占 325s 的 5-21%)
     不是主因，但也不可忽略
```

## 更可能的 I/O 差异来源

CNI 开销只能解释一小部分（5-21%），剩余的 I/O 差距可能来自：

1. **COS 接入点差异** — K8s Pod 和 YARN Node 可能走不同的 VPC endpoint
2. **TCP 拥塞窗口** — VXLAN 的 MTU 更小 (1450 vs 1500)，MSS 更小，需要更多 packets
3. **K8s Node 的网络带宽竞争** — 多个 Pod 共享节点网络带宽
4. **COS SDK 配置差异** — retry times 200 vs 1000 (虽然正常不触发)
5. **DNS 解析缓存** — K8s 的 CoreDNS 可能有偶发延迟

## 诊断命令

```bash
# 在 K8s Pod 内测试 COS 带宽
kubectl exec -it <pod> -- bash
# 安装测试工具
time hadoop fs -cat cosn://bucket/path/large-file > /dev/null
# 测试网络延迟
ping -c 10 <cos-endpoint>
# 查看 CNI 类型
ip link show  # 看是否有 vxlan/ipip 设备
cat /etc/cni/net.d/*.conf  # CNI 配置

# 在 YARN 节点做同样的测试对比
ssh <yarn-node>
time hadoop fs -cat cosn://bucket/path/large-file > /dev/null
ping -c 10 <cos-endpoint>

# 检查 cgroup CPU throttle
cat /sys/fs/cgroup/cpu/cpu.stat
# nr_throttled > 0 说明被 throttle 过
```
