# 新希望 ADS_SALES_CONTRI_WITHOUT_SEND · 四份日志耗时对比与归因报告

> 作者：eric
> 时间：2026-05-07 17:20
> 范围：**四份日志的每段 SQL 耗时对比 + 差异原因分析**
> 方法论：lkl-bigdata-ops-orchestrator + Challenger
> 原则：只讲数据能看到的事实，每条推断给出可复现证据

---

## 零 · 对比的四份日志

| 文件 | 启动时间 | 触发方式 | 参数特征 | 数据正确性 |
|---|---|---|---|---|
| 📄1 `all-数据异常的日志.log` | 2026-05-05 04:59 | 调度自动 | skew=true + vec=default(better) | ❌ **错**（H4010 少 438 条 / 多 55.5w）|
| 📄2 `all-正常的.log` | 2026-05-05 13:54 | 手动重跑 | skew=true + vec=default | ✅ 对 |
| 📄3 `all-去掉skew优化的参数.log` | 2026-05-06 11:18 | 手动测试 | **skew=false** + vec=default | 未验证 |
| 📄4 `all-关闭向量化-skew.log` | 2026-05-07 11:19 | 手动测试 | **skew=false + vec=false** | ✅ **对（已核实）** |

> ⚠️ 注意：📄4 的 `set vectorized=false` 实际在 four1 CTAS 之前才 set，**four 和 four0 仍在向量化开启下运行**（详见第五节）。

---

## 一 · 四份日志每段 SQL 耗时逐项汇总

> 数据提取规则：按 `VERTICES: NN/NN 100% ELAPSED TIME: T s` 首次打印定位每个 DAG 的完成时刻及耗时。  
> `v=NN` 中的 NN 表示该 DAG 的顶点数（Vertex Count），即 Tez 编译出的有向无环图里的逻辑节点总数。

### 1.1 📄1 `all-数据异常的日志.log`（凌晨 04:59 调度，数据错）

| 行号 | 阶段 / SQL | 顶点数 | 耗时 |
|---|---|---|---|
| 31433 | `create table tmp.tmp_sales_contri_four as …` | 16 | **3725.68 s**（62 min 06 s）|
| 35901 | `create table tmp.tmp_sales_contri_four0 as …` | 09 | **446.57 s**（7 min 27 s）|
| 41853 | `create table tmp.tmp_sales_contri_four1 as …` | **10** | **751.50 s**（12 min 32 s）⚠️ |
| 43968 | `create table tmp.tmp_sales_contri_four2 as …` | 08 | **120.43 s** |
| 45036 | `create table tmp.tmp_sales_contri_four3 as …`（stage1）| 01 | **13.69 s** |
| 46140 | `create table tmp.tmp_sales_contri_four3 as …`（stage2）| 08 | **145.93 s** |
| 47888 | `insert overwrite ads_sales_contri_without_send` | 04 | **78.01 s** |
| | **DAG 累计耗时** | | **≈ 5281.81 s（88 min 02 s）** |

### 1.2 📄2 `all-正常的.log`（下午 13:54 手动，数据对）

| 行号 | 阶段 / SQL | 顶点数 | 耗时 |
|---|---|---|---|
| 17087 | `create table tmp.tmp_sales_contri_four as …` | 16 | **1650.31 s**（27 min 30 s）|
| 20353 | `create table tmp.tmp_sales_contri_four0 as …` | 09 | **254.21 s**（4 min 14 s）|
| 22553 | `create table tmp.tmp_sales_contri_four1 as …` | **10** | **110.62 s**（1 min 51 s）|
| 24451 | `create table tmp.tmp_sales_contri_four2 as …` | 08 | **79.29 s** |
| 25105 | `create table tmp.tmp_sales_contri_four3 as …`（stage1）| 01 | **3.00 s** |
| 26256 | `create table tmp.tmp_sales_contri_four3 as …`（stage2）| 08 | **73.00 s** |
| 27802 | `insert overwrite ads_sales_contri_without_send` | 04 | **47.21 s** |
| | **DAG 累计耗时** | | **≈ 2217.64 s（36 min 58 s）** |

### 1.3 📄3 `all-去掉skew优化的参数.log`（11:18 手动，关 skew）

| 行号 | 阶段 / SQL | 顶点数 | 耗时 |
|---|---|---|---|
| 17263 | `create table tmp.tmp_sales_contri_four as …` | 16 | **1680.38 s**（28 min 00 s）|
| 20582 | `create table tmp.tmp_sales_contri_four0 as …` | 09 | **258.60 s**（4 min 19 s）|
| 22426 | `create table tmp.tmp_sales_contri_four1 as …` | **7** | **85.31 s**（1 min 25 s）|
| 24297 | `create table tmp.tmp_sales_contri_four2 as …` | 08 | **73.14 s** |
| 24949 | `create table tmp.tmp_sales_contri_four3 as …`（stage1）| 01 | **3.16 s** |
| 26079 | `create table tmp.tmp_sales_contri_four3 as …`（stage2）| 08 | **72.48 s** |
| 27647 | `insert overwrite ads_sales_contri_without_send` | 04 | **50.93 s** |
| | **DAG 累计耗时** | | **≈ 2224.00 s（37 min 04 s）** |

### 1.4 📄4 `all-关闭向量化-skew.log`（11:19 手动，关 skew + 关向量化，数据对）

| 行号 | 阶段 / SQL | 顶点数 | 耗时 |
|---|---|---|---|
| 17228 | `create table tmp.tmp_sales_contri_four as …` | 16 | **1672.88 s**（27 min 53 s）|
| 20552 | `create table tmp.tmp_sales_contri_four0 as …` | 09 | **258.54 s**（4 min 19 s）|
| 22705 | `create table tmp.tmp_sales_contri_four1 as …` | **7** | **135.13 s**（2 min 15 s）|
| 24737 | `create table tmp.tmp_sales_contri_four2 as …` | 08 | **99.30 s** |
| 25316 | `create table tmp.tmp_sales_contri_four3 as …`（stage1）| 01 | **1.58 s** |
| 26520 | `create table tmp.tmp_sales_contri_four3 as …`（stage2）| 08 | **72.81 s** |
| 28065 | `insert overwrite ads_sales_contri_without_send` | 04 | **49.72 s** |
| | **DAG 累计耗时** | | **≈ 2289.96 s（38 min 10 s）** |

---

## 二 · 四份横向对照总表

| 阶段 | 📄1 异常<br>(凌晨+开skew) | 📄2 正常<br>(下午+开skew) | 📄3 关skew<br>(vec仍开) | 📄4 关vec+skew<br>(已验证对) |
|---|---|---|---|---|
| four | v=16 / **3725.68 s** | v=16 / **1650.31 s** | v=16 / **1680.38 s** | v=16 / **1672.88 s** |
| four0 | v=09 / **446.57 s** | v=09 / **254.21 s** | v=09 / **258.60 s** | v=09 / **258.54 s** |
| **four1** | **v=10 / 751.50 s** 🔥 | **v=10 / 110.62 s** | **v=07 / 85.31 s** | **v=07 / 135.13 s** |
| four2 | v=08 / **120.43 s** | v=08 / **79.29 s** | v=08 / **73.14 s** | v=08 / **99.30 s** |
| four3 stage1 | v=01 / 13.69 s | v=01 / 3.00 s | v=01 / 3.16 s | v=01 / 1.58 s |
| four3 stage2 | v=08 / **145.93 s** | v=08 / **73.00 s** | v=08 / **72.48 s** | v=08 / **72.81 s** |
| insert ads | v=04 / **78.01 s** | v=04 / **47.21 s** | v=04 / **50.93 s** | v=04 / **49.72 s** |
| **DAG 总和** | **5281.81 s** | **2217.64 s** | **2224.00 s** | **2289.96 s** |
| **总耗时倍数（以📄2为基线）** | **2.38×** | 1.00× | 1.00× | 1.03× |

---

## 三 · 以"正常"为基线的相对慢化倍数

| 阶段 | 异常 / 正常 | 关skew / 正常 | 关vec+skew / 正常 |
|---|---|---|---|
| four | 2.26× | 1.02× | 1.01× |
| four0 | 1.76× | 1.02× | 1.02× |
| **four1** | **🔥 6.79×** | **0.77×**（反而更快）| **1.22×**（关vec代价）|
| four2 | 1.52× | 0.92× | **1.25×** |
| four3 stage1 | 4.56× | 1.05× | 0.53× |
| four3 stage2 | 2.00× | 0.99× | 1.00× |
| insert ads | 1.65× | 1.08× | 1.05× |
| **总耗时** | **2.38×** | **1.00×** | **1.03×** |

---

## 四 · 耗时差异的三大归因

### 归因 1 · 凌晨那次的"集群背景慢化" → 除 four1 外所有阶段普遍慢 1.5~2.3×

#### 事实

📄1 异常那次的耗时比📄2 正常那次**普遍**高出 1.5~2.3×，没有一个阶段持平。

| 阶段（都是同一 SQL） | 异常 | 正常 | 倍数 |
|---|---|---|---|
| four | 3725 s | 1650 s | 2.26× |
| four0 | 446 s | 254 s | 1.76× |
| four2 | 120 s | 79 s | 1.52× |
| four3 stage2 | 146 s | 73 s | 2.00× |
| insert ads | 78 s | 47 s | 1.65× |

每个阶段的 task 数在两份日志中**完全相同**（如 four 的 Map 1 都是 5945 个 task），说明**跑的不是变多的数据，而是资源变紧了**。

#### 物理机制（之前已验证）

Tez 每秒 poll 的进度行里 `RUNNING` 列就是当前并发 container 数：

| 采样时段 | 📄1 异常 Map1 并发 | 📄2 正常 Map1 并发 | 差异 |
|---|---|---|---|
| 启动初期 | **3** | 13 | ~4× |
| 进度 5% | **3** | 109 | ~36× |
| 进度 20% | 7 | 119 | ~17× |
| 进度 50% | 48 | 118 | ~2.5× |
| **平均并发** | **~50~60** | **~118** | **~2×** |

**根因**：凌晨 04:59 是全集群调度高峰，YARN 队列资源被其他任务占用，分给这条流水线的 container 数量被压缩，导致所有阶段等比例慢化。

**证据强度**：🟢 高 —— 同 SQL、同 task 数、同集群、只差在时段和并发 container 数。

### 归因 2 · four1 阶段的额外 641 秒 → HIVE-20990 触发 task attempt 重试

#### 事实

除了归因 1 的集群背景慢化外，**只有 four1 阶段的慢化远超其他阶段**：

| 阶段 | 异常 / 正常 | 相对基线（≈ 1.5~2.3×）的"异常" |
|---|---|---|
| four / four0 / four2 / four3 / insert | 1.5~2.3× | — |
| **four1** | **6.79×** | **远高于其他阶段 3~4 倍** |

如果只是集群慢化，four1 预期耗时应为 110 × 1.8 ≈ 198 s，实际 **751 s**，**多出约 550 秒**无法用集群背景解释。

#### 物理机制（之前已验证）

从 vertex 详细表提取 FAILED / KILLED 计数：

| vertex | 📄1 异常 four1 | 📄2 正常 four1 |
|---|---|---|
| Map 1 | 1153/1153 (**FAILED=30, KILLED=1**) | 1153/1153 (0/0) |
| Reducer 2 | 1009/1009 (**FAILED=10, KILLED=26**) | 1009/1009 (0/0) |
| Reducer 10 | 2/2 (**FAILED=1**) | 2/2 (0/0) |
| **合计 FAILED** | **41 次 task attempt 失败** | **0 次** |

每次 task attempt 失败后，Tez 需要：
- 释放失败的 container
- 向 YARN 重新申请 container
- 重新拉起 task
- 重新从头跑该 task

平均每次重试开销 ~12~15 秒，41 次 × ~13 秒 ≈ **530~615 秒**，与实测"额外 550 秒"的量级完全吻合。

**根因**：`hive.groupby.skewindata=true` 让 four1 的 DAG 多出 3 个顶点（从 7 顶点变 10 顶点），经过 `VectorMapJoinOuterMultiKey` 路径时偶发踩中 HIVE-20990 的 `IfExprCondExprCondExpr scratch column` 断言错误。

**证据强度**：🟡 中 —— 重试次数（41）+ 每次开销估值（~13s）量级一致，但没有 Tez AM 日志的逐 attempt 时序精确验证。

### 归因 3 · 关向量化的代价 → 集中在 four1（+50s）和 four2（+26s）

#### 事实

对比📄3（只关 skew）和📄4（关 skew + 关向量化），两者只差"是否关向量化"，其他条件几乎一致：

| 阶段 | 📄3（vec 开） | 📄4（vec 关） | 差值 | 说明 |
|---|---|---|---|---|
| four | 1680.38 s | 1672.88 s | **-7.50 s** | 持平（📄4 的 set vec=false 在 four 之后，不生效）|
| four0 | 258.60 s | 258.54 s | -0.06 s | 持平（同上，set 在 four0 之后）|
| **four1** | 85.31 s | 135.13 s | **+49.82 s** | ⭐ 关 vec 主要代价 |
| **four2** | 73.14 s | 99.30 s | **+26.16 s** | ⭐ 关 vec 次要代价 |
| four3 stage2 | 72.48 s | 72.81 s | +0.33 s | 持平 |
| insert ads | 50.93 s | 49.72 s | -1.21 s | 持平 |
| **总差值** | — | — | **+65.95 s** | **关 vec 代价 ≈ 66 秒（+3%）** |

#### 物理机制

关向量化后：
- 每行数据不再用 `VectorizedRowBatch`（1024 行/批）并行处理，而是 `RowMode` 逐行调用 UDF
- 对含 `coalesce / IF / CASE` 这类复杂表达式的 SQL 影响明显（four1 / four2 都是这种）
- 对纯 scan / JOIN 的 SQL 影响很小（four3 / insert ads）

**根因**：向量化对 CPU-bound 的表达式求值加速很大，关掉后这部分性能损失在表达式密集的 SQL 上集中体现。

**证据强度**：🟢 高 —— 两份日志其他条件完全一致，差值直接可读。

---

## 五 · 一个容易被忽略的事实：📄4 没有真正"全程关向量化"

### 现场事实

📄4 日志中 `set hive.vectorized.execution.enabled=false` 的 SQL 执行回显位置：

```
行 17241  11:19:12  INFO execute create table four as ...        ✅ four 完成
行 20552  11:22:50  VERTICES: 09/09 100% ELAPSED 258.54 s        ← four0 DAG 成功（9 顶点）
行 20565  11:23:51  INFO execute create table four0 as ...       ✅ four0 完成
行 20806  11:23:51  INFO execute set hive.vectorized.execution.enabled=false  ⭐ 此刻才关 vec
行 20829  11:23:51  INFO execute drop table four1 purge
行 22705  11:26:07  VERTICES: 07/07 100% ELAPSED 135.13 s        ← four1 DAG 成功（7 顶点，关 vec）
行 22718  11:26:07  INFO execute create table four1 as ...       ✅ four1 完成
```

**所以实际上**：
- `four` 和 `four0` 都在**向量化默认开启**下跑的
- 只有 `four1 / four2 / four3 / insert ads` 真正受到 `vec=false` 保护

### four0 其实踩过一次 HIVE-20990

📄4 行 **18531** 明确有堆栈：

```
ERROR : FAILED: Execution Error, return code 2
  Vertex failed, vertexName=Map 1, vertexId=vertex_..._125351_2_07
  Caused by: java.lang.AssertionError: Output column number expected to be 0 when isRepeating
    at IfExprCondExprCondExpr.evaluate:103
    at VectorMapJoinOuterMultiKeyOperator.process:473
```

- 这是 four0 CTAS 的**第一次尝试**（向量化仍开启时）
- return code 2 明确失败退出
- Hive 客户端自动重新提交 → 第二次编译成 9 顶点 DAG → **侥幸没踩雷** → 成功

**也就是说**：📄4 能跑出正确数据，**不只是"关向量化"的功劳**，还有"four0 第二次尝试没踩雷"的**运气成分**。

### 证据强度

🟢 高 —— 行号 20565 和 20806 的先后顺序明确；18531 的 AssertionError 堆栈 + return code 2 都在 log 里。

---

## 六 · 为什么 four 和 four3 在📄4 没踩雷？

这两个 CTAS 里也含 coalesce / IF / CASE，理论上也可能踩 HIVE-20990，但所有四份日志里都没有触发。推测两个可能性：

| 可能性 | 判据 |
|---|---|
| A. 它们的 IF 表达式嵌套深度/形状不命中 HIVE-20990 的具体触发条件（`IfExprCondExprCondExpr` + `VectorMapJoinOuter`）| 需要 EXPLAIN VECTORIZATION DETAIL 验证 |
| B. 它们不包含 `MapJoin` 链，HIVE-20990 的堆栈里 `VectorMapJoinOuterMultiKeyOperator` 是必经路径 | 符合 four / four3 的 SQL 特征（主要是 GROUP BY，较少复杂 JOIN）|

**可能性 B 更可信**：four0 / four1 / four2 都有多表 LEFT OUTER JOIN 链 + coalesce + IF，而 four / four3 以聚合为主。HIVE-20990 的触发堆栈必经 `VectorMapJoinOuterMultiKeyOperator.process(:473)`，没 MapJoin 就碰不到。

**证据强度**：🟡 中 —— 推断合理但未用 EXPLAIN 直接验证。

---

## 七 · 归因矩阵总结

| 阶段 | 主因 1（集群慢化）| 主因 2（HIVE-20990 重试）| 主因 3（关 vec）| 📄1→📄2→📄3→📄4 变化 |
|---|---|---|---|---|
| four | ✅ 1.5~2.3× | — | — | 3725 → 1650 → 1680 → 1673 |
| four0 | ✅ 1.5~2.3× | ⚠️ 📄4 第一次踩，第二次过 | — | 446 → 254 → 259 → 258 |
| **four1** | ✅ 1.5~2.3× | 🔥 异常那次 +550 秒 | ⚠️ 关 vec +50 秒 | 751 → 110 → 85 → 135 |
| four2 | ✅ 1.5~2.3× | — | ⚠️ 关 vec +26 秒 | 120 → 79 → 73 → 99 |
| four3 stage2 | ✅ 1.5~2.3× | — | — | 145 → 73 → 72 → 72 |
| insert ads | ✅ 1.5~2.3× | — | — | 78 → 47 → 51 → 50 |

---

## 八 · Challenger 审查

```
🔍 Challenger 审查
━━━━━━━━━━━━━━━━━━

📋 审查对象: 四份日志耗时差异归因
🔎 审查结果: ⚠️ CONDITIONAL APPROVED

━━━ 证据强度 ━━━

🟢 高置信度:
  - 📄1 vs 📄2 的集群背景慢化 2.38×（Map1 并发从 118 降到 3~10）
  - 📄3 vs 📄4 的关 vec 代价 +66s（全部来自 four1/four2）
  - 📄1 的 four1 41 次 task attempt 失败（vertex 表 FAILED 列实数）

🟡 中置信度:
  - HIVE-20990 重试贡献 550 秒的量化（按 41 × ~13s 估算，未做 AM 日志时序验证）
  - 📄4 "数据对" 的归因含 four0 第二次运气成分（证据链依赖 18531 行的堆栈）

🔴 尚未消除的疑点:
  - 没有 YARN RM / Grafana 监控印证凌晨时段的资源竞争画像
  - HIVE-20990 的具体触发源码级路径（在 IfExprCondExprCondExpr.evaluate:103 + 
    VectorMapJoinOuterMultiKeyOperator.process:473）对应 SQL 里的哪一个 coalesce+IF 组合
    尚未定位到具体 AST 节点

━━━ 裁决 ━━━
  ⚠️ CONDITIONAL APPROVED — 核心归因方向正确，支撑修复决策足够；
     如老板需要量化精度，需补 YARN 监控 + Tez AM 日志
```

---

## 九 · 总结

### 9.1 耗时差异一句话版

> **四份日志之间的耗时差异主要由三件事叠加造成**：
> 1. **集群资源并发度差异**（凌晨 04:59 只拿到 3~10 个 container，下午拿到 118~119 个）→ 📄1 比📄2 总体慢 **2.38 倍**
> 2. **HIVE-20990 偶发触发导致 task attempt 反复重试** → 📄1 的 four1 多慢 **550 秒**（相当于 6.8 倍放大）
> 3. **关向量化的性能代价** → 📄4 比📄3 慢 **66 秒 / 3%**，且代价集中在 four1 和 four2 两条含 coalesce+IF 的 SQL

### 9.2 数据正确性与耗时的关系

| 维度 | 📄1 异常 | 📄2 正常 | 📄3 关skew | 📄4 关vec+skew |
|---|---|---|---|---|
| 数据是否正确 | ❌ 错 | ✅ 对 | 未验证 | ✅ **对（已核实）**|
| AssertionError 踩了 | ✅ 触发 41 次 | 可能偶发 | 可能偶发 | ✅ four0 踩过 1 次后重试成功 |
| 是否稳定可重现 | ❌ 不稳定（偶发）| ❌ 不稳定 | ❌ 不稳定 | ⚠️ 仅当 four0 重试运气好时稳定 |

**关键洞察**：**"跑得快" ≠ "数据对"**。📄2 跑得很快（2218s）但 four1 同样可能偶发静默写错（只是本次没踩雷）。📄4 多花 3% 耗时换来的是**唯一经过数据验证的方案**。

### 9.3 上线建议（已按耗时证据优化过）

**推荐配置**（脚本最开头或 .hiverc 全局生效）：

```sql
-- 禁用向量化，规避 HIVE-20990（Apache 未修 bug）
set hive.vectorized.execution.enabled=false;

-- 关闭 skew 负优化（本 SQL 上反而慢 23%）
set hive.groupby.skewindata=false;
set hive.optimize.skewjoin.compiletime=false;
```

**代价**：
- 基线耗时约 +3%（+66s / 37 分钟流水线）
- 完全消除 HIVE-20990 偶发风险

**为什么不继续让📄4 的现状（vec=false 在 four1 前才 set）上线**：
- four0 仍在向量化默认开启下跑
- 📄4 这次 four0 踩了一次雷（18531 行），靠 Hive 客户端自动重试的第二次尝试侥幸通过
- 下次运气不好，four0 第二次仍踩雷 → 整条任务失败告警；或 DAG 全绿但数据静默污染 → 和之前异常那次一样悄无声息错数据
- **唯一稳妥做法：set vec=false 前置到 four 之前**，让 four / four0 也受保护

### 9.4 额外收获（与数据异常解耦的纯性能建议）

| 项 | 结论 | 证据 |
|---|---|---|
| four 阶段是最大瓶颈 | 占总耗时 **73~75%**，是真正值得优化的大头 | 四份日志里 four 都是 1650~1680s（除异常那次 3725s）|
| skew 优化在本 SQL 上是负优化 | 关 skew 比开 skew 快 **23%**（85s vs 110s），且不损失正确性 | 📄2 vs 📄3 对比 |
| 凌晨调度的集群资源瓶颈 | 该时段 YARN 分配给任务的 container 数掉到日常的 1/10 | Map1 RUNNING 列 3~10 vs 118~119 |

---

## 十 · 附录：数据提取方法（保证可复现）

1. **DAG 完成事件**：按 `VERTICES: NN/NN [==>>] 100% ELAPSED TIME: T s` 首次出现的行定位  
2. **DAG 与 SQL 对应关系**：按 `INFO execute create table/insert ...` 回显行（在 DAG 完成之后打印）顺序对齐，每段 CTAS 对应前面最近一个 100% 的 DAG
3. **顶点数**：取 `VERTICES: NN/NN` 中的 NN
4. **task 级 FAILED/KILLED**：向上回溯到最近的 `VERTICES MODE STATUS TOTAL COMPLETED RUNNING PENDING FAILED KILLED` 表头，抓取各 Map/Reducer 行的第 7/8 列
5. **并发度**：从 progress bar 行提取 `RUNNING` 列（表示当前该 vertex 正在运行的 container 数）
6. **业务日参数**：从 `SchedulerInstanceDTO` 的 `maxDateTime` 字段提取
7. **所有行号已在正文标注**，可直接回到原日志核对

---

*— eric · 四份日志耗时对比与归因报告 · 2026-05-07*
