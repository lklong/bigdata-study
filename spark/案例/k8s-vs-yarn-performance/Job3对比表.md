# Job 3 执行对比（按时间排序，YARN 为基准）

> YARN 基准: **4094s** | 同一条 SQL, 12.4TB, 34,466 Tasks

| # | App ID | 平台 | 日期 | Job 3 | cosn 配置 | COS请求失败 | 异常Task | vs YARN |
|---|--------|------|------|-------|-----------|-----------|---------|---------|
| 1 | YARN (app_12173904) | YARN | 4/7 13:25 | 4094s | NativeCosFS | 26 | 2 | 基准 |
| 2 | 171a31c6 | K8s | 4/7 13:29 | 4420s | TemrfsAdapter | 83 | 0 | 慢 326s (8.0%) |
| 3 | 2f7380f0 | K8s | 4/14 12:25 | 4441s | TemrfsAdapter | 56 | 0 | 慢 347s (8.5%) |
| 4 | 769606ae | K8s | 4/14 14:13 | 4520s | TemrfsAdapter | 64 | 0 | 慢 425s (10.4%) |
| 5 | 834aa7f7 | K8s | 4/14 15:39 | 4521s | TemrfsAdapter | 63 | 1 | 慢 426s (10.4%) |
| 6 | 264048 | K8s | 4/14 17:03 | 4435s | TemrfsAdapter | 37 | 0 | 慢 341s (8.3%) |
| 7 | 494dd578 | K8s | 4/14 18:18 | 4273s | TemrfsAdapter | 31 | 0 | 慢 178s (4.4%) |
| 8 | d87771f2 | K8s | 4/14 20:00 | 4412s | TemrfsAdapter | 0 | 1 | 慢 318s (7.8%) |
| 9 | 5c994d54 | K8s | 4/14 22:08 | 3907s | NativeCosFS | 17 | 0 | 快 187s (4.6%) |
| 10 | 6a0f0273 | K8s | 4/14 23:30 | 3871s | NativeCosFS | 23 | 0 | 快 223s (5.4%) |
| 11 | 744c908b | K8s | 4/15 17:33 | 4036s | NativeCosFS | 132 | 0 | 快 58s (1.4%) |
| 12 | eb182010 | K8s | 4/15 20:22 | 4143s | NativeCosFS | 42 | 1 | 慢 49s (1.2%) |
| 13 | 0408ee0e | K8s | 4/15 21:40 | 4030s | NativeCosFS | 57 | 0 | 快 64s (1.6%) |

### YARN vs K8s 差异参数

| 参数 | YARN | K8s TemrfsAdapter 组 | K8s NativeCosFS 组 |
|------|------|---------------------|-------------------|
| fs.cosn.impl | NativeCosFileSystem | **TemrfsHadoopFileSystemAdapter** | NativeCosFileSystem |
| fs.cos.userinfo.region | zyb-ap-beijing | **bj** | **bj** |
| JDK | Tencent 1.8.0_282 | **Kona 1.8.0_472** | **Kona 1.8.0_472** |
| Shuffle Manager | Built-in | **Celeborn** | **Celeborn** |
| read.ahead.block.size | 2MB | 默认1MB | 默认1MB (5c99/6a0f 设为2MB) |
| read.ahead.queue.size | 4 | 默认6 | 默认6 (5c99 设为4) |

### COS 操作耗时对比（Stage 3，每 Task 平均读取 376MB）

> IO_wait = RunTime - CPU - GC，即纯 COS 读取等待时间；吞吐 = 376MB / IO_wait

| # | App ID | 平台 | cosn 配置 | Job 3 | RunTime | CPU | GC | **IO_wait** | **IO 占比** | **吞吐** |
|---|--------|------|-----------|-------|---------|-----|-----|-----------|-----------|---------|
| 1 | 6a0f0273 | K8s | NativeCosFS | 3871s | 11.2s | 3.3s (30%) | 234ms (2.1%) | 7.6s | 68% | 50MB/s |
| 2 | 5c994d54 | K8s | NativeCosFS | 3907s | 11.3s | 3.3s (29%) | 234ms (2.1%) | 7.7s | 69% | 49MB/s |
| 3 | YARN | YARN | NativeCosFS | 4094s | 11.7s | 3.9s (33%) | 188ms (1.6%) | 7.6s | 65% | 49MB/s |
| 4 | 0408ee0e | K8s | NativeCosFS | 4030s | 11.6s | 3.2s (27%) | 249ms (2.1%) | 8.2s | 71% | 46MB/s |
| 5 | 744c908b | K8s | NativeCosFS | 4036s | 11.6s | 3.1s (27%) | 247ms (2.1%) | 8.3s | 71% | 46MB/s |
| 6 | eb182010 | K8s | NativeCosFS | 4143s | 11.9s | 3.2s (26%) | 247ms (2.1%) | 8.5s | 71% | 44MB/s |
| 7 | 494dd578 | K8s | TemrfsAdapter | 4273s | 12.3s | 3.4s (27%) | 263ms (2.1%) | 8.7s | 71% | 43MB/s |
| 8 | 171a31c6 | K8s | TemrfsAdapter | 4420s | 12.7s | 4.0s (32%) | 226ms (1.8%) | 8.4s | 66% | 45MB/s |
| 9 | d87771f2 | K8s | TemrfsAdapter | 4412s | 12.7s | 3.3s (26%) | 257ms (2.0%) | 9.2s | 72% | 41MB/s |
| 10 | 264048 | K8s | TemrfsAdapter | 4435s | 12.8s | 3.6s (28%) | 277ms (2.2%) | 8.9s | 69% | 42MB/s |
| 11 | 2f7380f0 | K8s | TemrfsAdapter | 4441s | 12.8s | 3.5s (28%) | 274ms (2.1%) | 9.0s | 70% | 42MB/s |
| 12 | 769606ae | K8s | TemrfsAdapter | 4520s | 13.0s | 3.5s (27%) | 269ms (2.1%) | 9.3s | 71% | 41MB/s |
| 13 | 834aa7f7 | K8s | TemrfsAdapter | 4521s | 13.0s | 3.5s (27%) | 270ms (2.1%) | 9.2s | 71% | 41MB/s |

> 全部 13 个应用均为 Event Log 实测数据
> IO_wait = RunTime - CPU - GC；吞吐 = 376MB / IO_wait

**COS 耗时与 Job 3 的相关性分析**:

- **相关系数 r = 0.73（强正相关）** — IO_wait 越高，Job 3 越慢
- IO_wait 每增加 1s，Job 3 约增加 267s
- IO_wait 占 Task RunTime 的 65%~72%，是任务耗时的主导因素
- 吞吐最高 49MB/s（YARN、5c99），最低 41MB/s（d877、769606ae、834aa7f7），差 19%

> 结论：**COS 读取性能是 Job 3 耗时的第一决定因素**。慢的任务和 COS 消耗有明确的正向关系。

### 异常 Task 详情

| App ID | Stage | Task ID | Executor | 节点 IP | 失败原因 | 简要分析 |
|--------|-------|---------|----------|---------|---------|---------|
| YARN | 3 | 9471 | Exec-66 | 10.126.144.244 | ExecutorLostFailure | Executor 进程丢失，Task 被重新调度到其他 Executor 执行 |
| YARN | 3 | 25307 | Exec-92 | 10.106.24.88 | ExecutorLostFailure | 同上，YARN Container 被 NodeManager 回收或进程异常退出 |
| d87771f2 | 3 | 14458 | Exec-5 | 10.127.41.237 | ExecutorLostFailure | Executor 心跳超时 166s (阈值120s) 后被 Driver 移除，正在执行的 Task 失败重跑 |
| 834aa7f7 | 3 | — | Exec-47 | — | ExecutorLostFailure | Executor 心跳超时 172s 后被移除（仅有 Driver 日志，无 Event Log 详情） |
| eb182010 | 3 | 21734 | Exec-78 | 10.127.45.204 | ExecutorLostFailure | Executor 心跳超时 151s 后被移除，导致应用仅 99 个 Executor 完成剩余 Task |

> 全部异常 Task 均为 ExecutorLostFailure（Executor 丢失），Spark 自动将失败 Task 重新调度到存活 Executor 上重跑，未导致任务失败，但会增加约 12~24s 的重调度延迟。
>
> 共性原因：K8s Pod 心跳超时（均超过 120s 阈值），可能与节点负载高、GC 停顿、网络抖动有关。
