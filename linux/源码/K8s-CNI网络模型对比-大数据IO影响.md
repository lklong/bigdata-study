# K8s CNI 网络模型对比：对大数据 I/O 性能的影响

> OS Expert 延伸学习 — 从 K8s vs YARN 案例的 I/O 等待 82.4% 深入

## 一、为什么要关注 CNI 网络模型

K8s vs YARN 性能分析中，82.4% 的性能差距来自 **I/O 等待增加**（+28,722s）。Pod 访问 COS 对象存储、Shuffle 数据传输都经过 CNI 网络栈。不同 CNI 插件的转发路径和性能差异巨大。

## 二、主流 CNI 插件架构对比

### 2.1 Flannel（VXLAN 模式）

```
Pod → veth pair → cni0 bridge → flannel.1 (VXLAN encap) 
→ eth0 → 物理网络 → 对端 eth0 → flannel.1 (VXLAN decap) → cni0 → veth → Pod

数据包变化:
  原始: [IP:Pod-A → IP:Pod-B] [TCP] [Data]
  封装: [IP:Node-A → IP:Node-B] [UDP:8472] [VXLAN Header] [原始包]

额外开销:
  - VXLAN 封装/解封装: ~50 bytes header overhead
  - UDP 封装: 内核 UDP 处理
  - MTU 损失: 1500 → 1450 (需要分片或降 MTU)
```

**性能影响**：
- 延迟增加 ~10-30μs/包（内核态 VXLAN 处理）
- 吞吐降低 ~5-10%（封装开销 + MTU 碎片）
- **对大数据场景**：COS 大块 I/O（每次 64KB-1MB），VXLAN 开销占比小但累积可观

### 2.2 Calico（BGP 路由模式）

```
Pod → veth pair → 路由表 → eth0 → 物理网络 → 对端 eth0 → 路由表 → veth → Pod

数据包变化:
  [IP:Pod-A → IP:Pod-B] [TCP] [Data]  （无封装！纯三层路由）

额外开销:
  - 只有路由查找（O(1) 前缀匹配）
  - 无封装/解封装
  - MTU 无损失: 1500
```

**性能影响**：
- 延迟增加 ~3-5μs/包（仅路由查找）
- 吞吐接近物理网络（~95-98%）
- **对大数据场景**：几乎无额外开销，推荐！

### 2.3 Calico（IPIP 模式）

```
Pod → veth → 路由表 → tunl0 (IPIP encap) → eth0 → 物理 → 对端 → tunl0 (decap) → veth → Pod

额外开销:
  - IPIP 封装: 20 bytes (比 VXLAN 的 50 bytes 少)
  - MTU 损失: 1500 → 1480
```

**性能影响**：介于 BGP 和 Flannel VXLAN 之间

### 2.4 Cilium（eBPF 模式）

```
Pod → veth pair → eBPF程序（内核态直接处理） → eth0 → 物理网络

亮点:
  - 跳过 iptables/netfilter 整个链路
  - eBPF 直接在 TC (traffic control) 层做路由
  - 支持 XDP (eXpress Data Path) 在网卡驱动层处理
```

**性能影响**：
- 延迟: 比 Calico BGP 还低 ~2-3μs（跳过 iptables）
- 吞吐: 接近 100% 线速
- **对大数据场景**：最优选择！尤其是 Shuffle 密集型任务

## 三、性能对比数据（业界基准测试）

| CNI 模式 | Pod-to-Pod 延迟 | Pod-to-External 延迟 | 吞吐 (vs bare metal) | MTU |
|----------|:---------------:|:--------------------:|:---------------------:|:---:|
| **主机网络 (hostNetwork)** | **~0μs** | **~0μs** | **~100%** | **1500** |
| **Cilium eBPF** | ~3μs | ~3μs | ~98% | 1500 |
| **Calico BGP** | ~5μs | ~5μs | ~95% | 1500 |
| **Calico IPIP** | ~10μs | ~8μs | ~90% | 1480 |
| **Flannel VXLAN** | ~20μs | ~15μs | ~85% | 1450 |

### 对大数据任务的累积影响估算

假设 Stage 3 的 34,466 个 task，每个 task 读取 ~375MB COS 数据：
- 每次 COS HTTP GET 读取 1MB 数据块 → ~375 次请求/task
- 每次请求经过 CNI 网络栈 → 额外延迟 × 请求数 × task 数

```
Flannel VXLAN:  20μs × 375 × 34466 = ~258s 额外延迟
Calico BGP:      5μs × 375 × 34466 =  ~65s 额外延迟
Cilium eBPF:     3μs × 375 × 34466 =  ~39s 额外延迟
hostNetwork:     0μs × 375 × 34466 =    0s 额外延迟
```

**注意**：这只是网络栈的处理延迟，不包括实际网络传输时间。实际影响还取决于连接复用、TCP window 等因素。

## 四、COS 访问路径分析

### 4.1 YARN 节点直接访问 COS

```
JVM → COS SDK (HTTP Client) → OS TCP Stack → eth0 → 物理网络 
→ COS VIP (同可用区内网) → COS 存储节点
```

### 4.2 K8s Pod 访问 COS（Flannel VXLAN）

```
JVM → COS SDK → OS TCP Stack → veth → cni0 bridge → iptables SNAT 
→ flannel.1 (VXLAN) → eth0 → 物理网络 → COS VIP
```

多了 3 步：**veth → cni0 → iptables SNAT**。其中 iptables SNAT（源地址转换）在高并发下是已知瓶颈，conntrack 表满会导致丢包。

### 4.3 K8s Pod 访问 COS（hostNetwork=true）

```
JVM → COS SDK → OS TCP Stack → eth0 → 物理网络 → COS VIP
```

和 YARN 完全一致！**零额外开销**。

## 五、推荐方案

### 5.1 短期（零成本）

```yaml
# executor-pod-template.yaml
apiVersion: v1
kind: Pod
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
```

```properties
spark.kubernetes.executor.podTemplateFile=/opt/spark/conf/executor-pod-template.yaml
```

### 5.2 中期（CNI 升级）

如果不能用 hostNetwork（安全策略限制），按优先级：
1. **Cilium eBPF** — 最佳性能，但需要 Linux 5.4+ 内核
2. **Calico BGP** — 次优，但需要网络规划（BGP peer 配置）
3. **Calico IPIP** — 折中方案

### 5.3 长期（网络架构优化）

```
1. COS 私有 VPC Endpoint — Pod 直接走私有连接到 COS，不经公网
2. Node-local COS Cache — 在每个 K8s Node 上部署 COS 读缓存（如 JuiceFS）
3. RDMA 网络 — 下一代高性能计算集群
```

## 六、验证命令

```bash
# 1. 确认当前 CNI 类型
kubectl get pods -n kube-system | grep -E "flannel|calico|cilium"

# 2. 检查 Pod 网络路径
kubectl exec <spark-executor-pod> -- traceroute <cos-endpoint>

# 3. COS 带宽 benchmark
kubectl exec <spark-executor-pod> -- dd if=/dev/zero bs=1M count=1000 | \
  hadoop fs -put - cosn://bucket/benchmark-test

# 4. 检查 conntrack 表使用率
kubectl exec <spark-executor-pod> -- cat /proc/sys/net/netfilter/nf_conntrack_count
kubectl exec <spark-executor-pod> -- cat /proc/sys/net/netfilter/nf_conntrack_max

# 5. 对比 hostNetwork vs 默认网络
# Pod A: hostNetwork=true
# Pod B: 默认 CNI 网络
# 在两个 Pod 中分别 curl COS 同一个文件，对比延迟
```

---

*OS Expert 学习产出 | 2026-04-08 | 来源：K8s vs YARN 案例 I/O 等待 82.4% 延伸*
