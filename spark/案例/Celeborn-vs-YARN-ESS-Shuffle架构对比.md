# Celeborn vs YARN ESS Shuffle 架构对比

> 来源案例：K8s vs YARN 性能对比，2026-04-07
> 任务编号: SP-05

---

## 架构对比

### YARN External Shuffle Service (ESS)

```
Executor A (map)                    Executor B (reduce)
  ↓ shuffle write                     ↓ shuffle read
  → 写入本地磁盘                       → 从 ESS 拉取
    /data1/yarn/local/.../shuffle/      ← NodeManager 上的 ESS 进程服务
    
特点:
  - Shuffle 数据存在 executor 所在节点的本地磁盘
  - ESS 是 NodeManager 的常驻服务进程
  - Executor 死了数据还在（ESS 独立于 Executor）
  - 同节点读取 = 本地磁盘 I/O（极快）
  - 跨节点读取 = 网络 I/O
```

### Celeborn Remote Shuffle Service

```
Executor A (map)                    Celeborn Worker
  ↓ shuffle write                     ↓ 存储
  → push 到 Celeborn Worker            → 磁盘/SSD
    (网络传输)                          
                                    Executor B (reduce)
                                      ↓ shuffle read
                                      → 从 Celeborn Worker 拉取
                                        (网络传输)

特点:
  - Shuffle 数据集中存储在 Celeborn Worker 集群
  - 写入: Executor → 网络 → Celeborn Worker（多了一次网络）
  - 读取: Celeborn Worker → 网络 → Executor（也是网络）
  - 没有本地读优化（所以 localShuffleReader.enabled=false）
  - 适合 K8s（Pod 无本地持久存储，ESS 不可用）
```

## 配置差异对照

| 配置项 | YARN (ESS) | K8s (Celeborn) | 影响 |
|--------|-----------|----------------|------|
| `spark.shuffle.manager` | 默认 (SortShuffleManager) | `celeborn.SparkShuffleManager` | Shuffle 数据路径完全不同 |
| `spark.shuffle.service.enabled` | **true** | **false** | YARN 用 ESS, K8s 不用 |
| `spark.shuffle.useOldFetchProtocol` | **true** | **false** | 协议不同 |
| `spark.sql.adaptive.localShuffleReader.enabled` | **true** (默认) | **false** | **K8s 禁用了本地读** |
| `spark.dynamicAllocation.shuffleTracking.enabled` | — | **false** | Celeborn 不需要 |

## 对本次查询的影响

```
本次查询 Stage 3: 纯 Scan → Write，零 Shuffle
  - Shuffle Write Bytes: 0
  - Shuffle Read Bytes: 0
  - Disk Bytes Spilled: 0

结论: Celeborn vs ESS 对本次查询无影响
      但对有 Shuffle 的查询（如 JOIN、GROUP BY）影响很大
```

## 有 Shuffle 查询的预期差异

```
YARN ESS:
  - 同节点 Shuffle: 本地磁盘直读（~500MB/s SSD）
  - localShuffleReader=true 优化：reduce task 调度到 map 所在节点
  
Celeborn:
  - 所有 Shuffle 都走网络（~1-5Gbps，取决于 Celeborn Worker 数量和网络）
  - localShuffleReader=false（无法本地读）
  - 优势: 解耦 shuffle 和 executor 生命周期（K8s 必须）
  - 劣势: 额外网络开销

预期: 有大量 Shuffle 的查询，Celeborn 可能比 ESS 慢 10-30%
     但 Stage 3 这种纯 Scan 任务没影响
```

## Celeborn 调优参数

```properties
# Push 缓冲区（影响写入性能）
spark.celeborn.client.push.buffer.max.size = 64k  (默认)
spark.celeborn.client.push.maxReqsInFlight = 32   (默认)

# 副本（当前关闭，性能优先）
spark.celeborn.client.push.replicate.enabled = false

# 动态写入模式
spark.celeborn.client.spark.push.dynamicWriteMode.enabled = true
spark.celeborn.client.spark.push.dynamicWriteMode.partitionNum.threshold = 1000
```
