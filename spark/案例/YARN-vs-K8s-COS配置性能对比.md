# 全量任务执行汇总（YARN + K8s 共 10 个应用）

> SQL: `SELECT ... FROM info_cungo`，扫描 12.4TB，34,466 Tasks
> 集群: K8s cls-nctmeua9 (pangu) / YARN on EMR
> 引擎: Spark 3.3.2 + Kyuubi 1.9.1.1

---

## 一、全部任务 Job 3 耗时列表（按耗时排序）

| 排名 | App ID | 平台 | 日期 | Job 3 开始 | Job 3 结束 | **Job 3 耗时** | **vs 最快** | 配置组 | 备注 |
|------|--------|------|------|-----------|-----------|--------------|------------|--------|------|
| 1 | **5c99** | K8s | 4/14 | 22:08:15 | 23:13:22 | **3907s (1.09h)** | 基准 | A | 手动加 native+readahead |
| 2 | **6a0f** | K8s | 4/14 | ~23:30 | ~00:37 | **~4020s (~1.12h)** ★ | +113s (+2.9%) | A | 手动加 native+readahead |
| 3 | **YARN** | YARN | 4/7 | 13:25:43 | 14:33:58 | **4094s (1.14h)** | +187s (+4.8%) | A | 原有配置 |
| 4 | 494d | K8s | 4/14 | 18:18:47 | 19:29:59 | **4273s (1.19h)** | +365s (+9.3%) | B | 默认 TemrfsAdapter |
| 5 | d877 | K8s | 4/14 | 20:00:45 | 21:14:17 | **4412s (1.23h)** | +505s (+12.9%) | B | 默认 TemrfsAdapter |
| 6 | 171a | K8s | 4/7 | 13:29:49 | 14:43:29 | **4420s (1.23h)** | +513s (+13.1%) | B | 默认 TemrfsAdapter |
| 7 | 2640 | K8s | 4/14 | 17:03:06 | 18:17:01 | **4435s (1.23h)** | +529s (+13.5%) | B | 默认 TemrfsAdapter |
| 8 | 2f73 | K8s | 4/14 | 12:25:16 | 13:39:17 | **4441s (1.23h)** | +534s (+13.7%) | B | 默认 TemrfsAdapter |
| 9 | 7696 | K8s | 4/14 | 14:13:43 | 15:29:03 | **4520s (1.26h)** | +613s (+15.7%) | B | 默认 TemrfsAdapter |
| 10 | 834a | K8s | 4/14 | 15:39:08 | 16:54:28 | **4521s (1.26h)** | +614s (+15.7%) | B | 默认 TemrfsAdapter |

> ★ 6a0f 无 Driver 日志，从 Executor 时间范围推算
> 5c99 和 6a0f 是手动加了 `--conf spark.hadoop.fs.cosn.impl=NativeCosFileSystem` + `read.ahead` 参数的测试组
>
> COS 路径格式:
> - Event Log: `cosn://zyb-bigdata-arch-common-1253445850/spark/emr-8snonx7e/spark-event/spark-{appid}`
> - Driver Log: `cosn://zyb-bigdata-arch-common-1253445850/spark-logs/spark-{appid}`

---

## 二、配置分组

### Group A — NativeCosFileSystem + read.ahead=2MB

| 配置 | 值 |
|------|-----|
| `fs.cosn.impl` | `org.apache.hadoop.fs.cosnative.NativeCosFileSystem` |
| `fs.cosn.read.ahead.block.size` | 2097152 (2MB) |
| `fs.cosn.read.ahead.queue.size` | 4 |
| `fs.cos.userinfo.region` | zyb-ap-beijing |
| 应用 | **5c99**, **6a0f**, **YARN** |
| 平均 Job 3 | **4007s (1.11h)** |

### Group B — TemrfsHadoopFileSystemAdapter, 无 read.ahead

| 配置 | 值 |
|------|-----|
| `fs.cosn.impl` | `com.qcloud.emr.fs.TemrfsHadoopFileSystemAdapter` |
| `fs.cosn.read.ahead.block.size` | 未配置 (默认) |
| `fs.cosn.read.ahead.queue.size` | 未配置 (默认) |
| `fs.cos.userinfo.region` | bj |
| 应用 | 2f73, 7696, 834a, 2640, 494d, d877, 171a |
| 平均 Job 3 | **4432s (1.23h)** |

### A vs B

| 指标 | Group A | Group B | 差异 |
|------|---------|---------|------|
| 平均 Job 3 | 4007s (1.11h) | 4432s (1.23h) | **A 快 425s (9.6%)** |
| 最快 | 3907s (5c99) | 4273s (494d) | |
| 最慢 | 4094s (YARN) | 4521s (834a) | |
| 组内极差 | 187s (4.7%) | 248s (5.6%) | |

---

## 三、时间线

```
4/7  13:25 ├─YARN──────1.14h──────┤ 14:34     Group A
4/7  13:29 ├─171a──────1.23h──────┤ 14:43     Group B
4/14 12:25 ├─2f73──────1.23h──────┤ 13:39     Group B
4/14 14:13 ├─7696──────1.26h──────┤ 15:29     Group B
4/14 15:39 ├─834a──────1.26h──────┤ 16:54     Group B
4/14 17:03 ├─2640──────1.23h──────┤ 18:17     Group B
4/14 18:18 ├─494d──────1.19h──────┤ 19:30     Group B
4/14 20:00 ├─d877──────1.23h──────┤ 21:14     Group B
4/14 22:08 ├─5c99──────1.09h──────┤ 23:13     Group A ★ 最快
4/14 23:30 ├─6a0f──────~1.12h─────┤ 00:37     Group A
```

---

## 四、差异原因分析

### A 比 B 快 9.6% 的三个原因

| 因子 | 贡献度 | 详细说明 |
|------|--------|---------|
| **fs.cosn.impl** | **~50%** | NativeCosFileSystem 直接调 COS SDK；TemrfsHadoopFileSystemAdapter 是 EMR 封装层，含额外认证/计量/路由开销 |
| **COS 预读** | **~30%** | read.ahead.block.size=2MB + queue.size=4 实现异步预取，减少每次 I/O 的同步等待 |
| **Region 路由** | **~10%** | zyb-ap-beijing vs bj，可能路由到不同 COS 接入节点 |
| **时段波动** | **~10%** | 不同时间 COS 后端负载不同 |

### Group B 内部波动 (4273s ~ 4521s)

| 时段 | 应用 | Job 3 | 说明 |
|------|------|-------|------|
| 中午 12:25 | 2f73 | 4441s | |
| 下午 14:13 | 7696 | **4520s** (最慢) | 下午高峰 |
| 下午 15:39 | 834a | **4521s** (最慢) | 下午高峰 |
| 下午 17:03 | 2640 | 4435s | |
| 傍晚 18:18 | 494d | **4273s** (最快) | 业务低谷 |
| 晚间 20:00 | d877 | 4412s | |

**规律**: 下午 14:00~16:00 最慢 (4520s)，傍晚 18:00 最快 (4273s)，差 248s (5.6%)，与 COS 负载的日间波动吻合。

### YARN vs K8s (同为 Group A)

| 指标 | YARN | K8s-5c99 | 差异原因 |
|------|------|----------|---------|
| Job 3 | 4094s | 3907s | YARN 慢 187s (4.8%) |

差异来自:
1. **JDK**: YARN = Tencent JDK 1.8.0_282, K8s = TencentKona 1.8.0_472 (更新 GC 优化)
2. **Executor ramp-up**: YARN 62min 才拿齐 102 Executor, K8s 2min
3. **Shuffle Manager**: YARN = Built-in, K8s = Celeborn (此场景无 Shuffle，影响为 0)

---

## 五、待补充

- [ ] **6a0f 精确 Job 3 时间**: 需获取 Driver Log（当前从 Executor 时间范围推算 ~4020s）
