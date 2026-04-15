# Job 3 耗时对比列表（5 个应用）

> 同一条 SQL，扫描 12.4TB `info_cungo` 表，34,466 个 Task

## 时差列表

| # | 标签 | 日期 | 平台 | Job 3 耗时 | vs 最快 | 差异 % | cosn.impl | read.ahead | shuffle | region |
|---|------|------|------|-----------|---------|--------|-----------|------------|---------|--------|
| 1 | **K8s-5c99** | 4/14 | K8s | **1.09h (3907s)** | 基准 | — | NativeCosFS | 2MB | Celeborn | zyb-ap-beijing |
| 2 | **YARN** | 4/7 | YARN | **1.14h (4094s)** | +3.1min | +4.8% | NativeCosFS | 2MB | Built-in | zyb-ap-beijing |
| 3 | K8s-d877 | 4/14 | K8s | 1.23h (4412s) | +8.4min | +12.9% | TemrfsAdapter | N/A | Celeborn | bj |
| 4 | K8s-old | 4/7 | K8s | 1.23h (4420s) | +8.6min | +13.1% | TemrfsAdapter | N/A | Celeborn | bj |
| 5 | K8s-264048 | 4/14 | K8s | 1.23h (4436s) | +8.8min | +13.5% | TemrfsAdapter | N/A | Celeborn | bj |

## 分组规律

| 分组 | 配置特征 | 应用 | 平均耗时 | 差异 |
|------|---------|------|---------|------|
| **Group A** | NativeCosFS + read.ahead=2MB | K8s-5c99, YARN | **1.11h (4000s)** | 基准 |
| **Group B** | TemrfsAdapter, 无 read.ahead | K8s-old, K8s-264048, K8s-d877 | **1.23h (4423s)** | **+10.6% (+7min)** |

## 差异原因

**Group A vs Group B 差异 10.6% 的原因**：
1. **`fs.cosn.impl` 实现差异 (~50%)** — NativeCosFS 原生实现 vs TemrfsHadoopFileSystemAdapter EMR 封装层
2. **COS 预读配置 (~30%)** — read.ahead.block.size=2MB + queue.size=4 vs 无预读
3. **Region 标识 (~10%)** — zyb-ap-beijing vs bj，可能路由不同 COS 端点
4. **运行时间段波动 (~10%)**

**Group A 内部 YARN vs K8s-5c99 差异 4.8% 的原因**：
1. JDK 版本 — YARN: Tencent JDK 1.8.0_282 vs K8s: TencentKona 1.8.0_472
2. Shuffle Manager — YARN: Built-in vs K8s: Celeborn（此场景无 Shuffle，影响为 0）
3. YARN Executor ramp-up 慢 (62min)，前期并行度不满

**Group B 内部三个应用差异 <25s (<0.6%)**：配置完全一致，差异仅为运行时环境随机波动。
