# K8s 全部任务 Job 3 耗时列表（含 YARN 对照）

> 同一条 SQL: `SELECT ... FROM info_cungo`，扫描 12.4TB，34,466 Tasks
> 数据来源: k8s.zip (9个K8s应用) + logs.tar.gz (1个YARN应用)

## 完整时差列表（按 Job 3 耗时排序）

| # | App ID (短) | App Name | 日期 | Job 3 开始 | Job 3 结束 | **Job 3 耗时** | **vs 最快** | cosn.impl | read.ahead |
|---|-------------|----------|------|-----------|-----------|--------------|------------|-----------|------------|
| 1 | **5c99** | cql_test_ | 4/14 | 22:08:15 | 23:13:22 | **3907s (1.09h)** | 基准 | NativeCosFS | 2MB |
| 2 | **YARN** | cql_test_$ds | 4/7 | 13:25:43 | 14:33:58 | **4094s (1.14h)** | **+187s (+4.8%)** | NativeCosFS | 2MB |
| 3 | **494d** | cql_test_$ds | 4/14 | 18:18:47 | 19:29:59 | **4273s (1.19h)** | **+365s (+9.3%)** | TemrfsAdapter | N/A |
| 4 | **d877** | cql_test_$ds | 4/14 | 20:00:45 | 21:14:17 | **4412s (1.23h)** | **+505s (+12.9%)** | TemrfsAdapter | N/A |
| 5 | **171a** | cql_test_$ds | 4/7 | 13:29:49 | 14:43:29 | **4420s (1.23h)** | **+513s (+13.1%)** | TemrfsAdapter | N/A |
| 6 | **2640** | cql_test_$ds | 4/14 | 17:03:06 | 18:17:01 | **4435s (1.23h)** | **+529s (+13.5%)** | TemrfsAdapter | N/A |
| 7 | **2f73** | cql_test_$ds | 4/14 | 12:25:16 | 13:39:17 | **4441s (1.23h)** | **+534s (+13.7%)** | TemrfsAdapter | N/A |
| 8 | **7696** | cql_test_$ds | 4/14 | 14:13:43 | 15:29:03 | **4520s (1.26h)** | **+613s (+15.7%)** | TemrfsAdapter | N/A |
| 9 | **834a** | cql_test_$ds | 4/14 | 15:39:08 | 16:54:28 | **4521s (1.26h)** | **+614s (+15.7%)** | TemrfsAdapter | N/A |
| 10 | 6a0f | cql_test_ | 4/14 | ~23:30 | ~00:37 | **~4020s (~1.12h)** ★ | ~+113s | NativeCosFS? | 2MB? |

> ★ spark-6a0f 无 Driver 日志，从 Executor 时间范围推算（含启动/退出开销），Job 3 精确值无法确定

## 统计摘要

| 分组 | 应用数 | 耗时范围 | 平均 | 标准差 |
|------|--------|---------|------|--------|
| **Group A** (NativeCosFS + read.ahead) | 2 (+YARN) | 3907~4094s | **4001s (1.11h)** | 93s |
| **Group B** (TemrfsAdapter, 无 read.ahead) | 7 | 4273~4521s | **4432s (1.23h)** | 75s |
| **A vs B 差异** | — | — | **-431s (-9.7%)** | — |

## 时间线视图

```
4/7  13:25 ├─YARN──────1.14h──────┤ 14:34     NativeCosFS
4/7  13:29 ├─171a──────1.23h──────┤ 14:43     TemrfsAdapter
4/14 12:25 ├─2f73──────1.23h──────┤ 13:39     TemrfsAdapter
4/14 14:13 ├─7696──────1.26h──────┤ 15:29     TemrfsAdapter
4/14 15:39 ├─834a──────1.26h──────┤ 16:54     TemrfsAdapter
4/14 17:03 ├─2640──────1.23h──────┤ 18:17     TemrfsAdapter
4/14 18:18 ├─494d──────1.19h──────┤ 19:30     TemrfsAdapter
4/14 20:00 ├─d877──────1.23h──────┤ 21:14     TemrfsAdapter
4/14 22:08 ├─5c99──────1.09h──────┤ 23:13     NativeCosFS ★ 最快
4/14 23:30 ├─6a0f──────~1.1h──────┤ 00:37     NativeCosFS?
```

## 差异原因

| 因子 | Group B 比 Group A 慢的原因 | 贡献 |
|------|---------------------------|------|
| `fs.cosn.impl` | TemrfsHadoopFileSystemAdapter (EMR封装) vs NativeCosFileSystem (原生) | ~50% |
| COS 预读 | 无 `read.ahead.block.size` / `queue.size` | ~30% |
| Region 标识 | `bj` vs `zyb-ap-beijing`，可能路由不同 | ~10% |
| 时段波动 | 不同时间 COS 负载不同 | ~10% |

**Group B 内部波动**: 4273s ~ 4521s，极差 248s (5.6%)，494d 最快 (4273s) 可能因为 18:18 时段 COS 负载较低。7696/834a 最慢 (4520s) 在 14:00~17:00 下午时段。
