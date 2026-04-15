# Job 3 执行对比（按时间排序，YARN 为基准）

> YARN 基准: **4094s** | 同一条 SQL, 12.4TB, 34,466 Tasks

| # | App ID | 平台 | 日期 | Job 3 | cosn 配置 | vs YARN |
|---|--------|------|------|-------|-----------|---------|
| 1 | YARN (app_12173904) | YARN | 4/7 13:25 | 4094s | NativeCosFS | 基准 |
| 2 | 171a31c6 | K8s | 4/7 13:29 | 4420s | TemrfsAdapter | 慢 326s (8.0%) |
| 3 | 2f7380f0 | K8s | 4/14 12:25 | 4441s | TemrfsAdapter | 慢 347s (8.5%) |
| 4 | 769606ae | K8s | 4/14 14:13 | 4520s | TemrfsAdapter | 慢 425s (10.4%) |
| 5 | 834aa7f7 | K8s | 4/14 15:39 | 4521s | TemrfsAdapter | 慢 426s (10.4%) |
| 6 | 264048 | K8s | 4/14 17:03 | 4435s | TemrfsAdapter | 慢 341s (8.3%) |
| 7 | 494dd578 | K8s | 4/14 18:18 | 4273s | TemrfsAdapter | 慢 178s (4.4%) |
| 8 | d87771f2 | K8s | 4/14 20:00 | 4412s | TemrfsAdapter | 慢 318s (7.8%) |
| 9 | 5c994d54 | K8s | 4/14 22:08 | 3907s | NativeCosFS | 快 187s (4.6%) |
| 10 | 744c908b | K8s | 4/15 17:33 | 4036s | NativeCosFS | 快 58s (1.4%) |
| 11 | eb182010 | K8s | 4/15 20:22 | 4143s | NativeCosFS | 慢 49s (1.2%) |
| 12 | 0408ee0e | K8s | 4/15 21:40 | 4030s | NativeCosFS | 快 64s (1.6%) |

### YARN vs K8s 差异参数

| 参数 | YARN | K8s TemrfsAdapter 组 | K8s NativeCosFS 组 |
|------|------|---------------------|-------------------|
| fs.cosn.impl | NativeCosFileSystem | **TemrfsHadoopFileSystemAdapter** | NativeCosFileSystem |
| fs.cos.userinfo.region | zyb-ap-beijing | **bj** | **bj** |
| JDK | Tencent 1.8.0_282 | **Kona 1.8.0_472** | **Kona 1.8.0_472** |
| Shuffle Manager | Built-in | **Celeborn** | **Celeborn** |
| read.ahead.block.size | 2MB | 默认1MB | 默认1MB (5c99 设为2MB) |
| read.ahead.queue.size | 4 | 默认6 | 默认6 (5c99 设为4) |
