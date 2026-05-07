# Hive 向量化 HIVE-20990 偶发数据错乱 · 案例归档

> 归档时间：2026-05-07
> 归档人：eric
> 组件：Hive on Tez（EMR Hive 3.x）
> 风险等级：🔴 P0（silent data corruption，无报错静默出错）
> 最后更新：2026-05-07 17:30（补入 4 份日志全量对比 + 线上验证结果）

---

## 一、案例一句话

新希望财务管报流水线 `ADS_SALES_CONTRI_WITHOUT_SEND` 昨天跑出来的 H4010 公司 202604 月折后收入 `147,893,249.51`，比今天重跑的正确值 `147,337,875.57` **多 55.5w**，条数也多 **438 条**。同一 SQL、同一参数、同一上游数据、同一 DAG 拓扑，**凌晨跑错、下午重跑对**，而且**两次 four1 的 DAG 全绿、零报错**。

**根因**：Apache Hive 官方未修 bug **[HIVE-20990](https://issues.apache.org/jira/browse/HIVE-20990)** —— 向量化执行引擎 `IfExprCondExprCondExpr` 在 `IF/CASE + COALESCE + 多键 LEFT OUTER MapJoin + GROUP BY + ORC` 组合下，存在**非确定性的 scratch column 错误复用**，两种表现共存：

- **表现 A**：抛 `AssertionError: Output column number expected to be 0 when isRepeating` → task 失败，被 Tez 重试拉起后通常数据正确
- **表现 B**：**没抛断言，但 scratch column 已经被错误覆盖** → DAG 全绿 + 字符串列静默写错位 → GROUP BY key 错乱 → 数据异常

凌晨那次 four1 正好踩中表现 B → silent data corruption。

---

## 二、核心证据链（四份日志对照）

| 对比维度 | 📄1 数据异常 | 📄2 正常 | 📄3 关skew | 📄4 关vec+skew |
|---|---|---|---|---|
| 启动时间 | 05-05 04:59（调度）| 05-05 13:54（手动）| 05-06 11:18（手动）| 05-07 11:19（手动）|
| `maxDateTime` | 2026-05-04 | 2026-05-05 | 2026-05-06 | 2026-05-07 |
| skew 参数 | true | true | false | false |
| vectorized 参数 | default(better) | default(better) | default(better) | **false**（仅 four1 前生效）|
| 总 DAG 耗时 | **5281s**（88min）| **2218s**（37min）| **2224s**（37min）| **2290s**（38min）|
| four1 DAG 顶点 | 10 | 10 | **7** | **7** |
| four1 Map1 FAILED | **30** 🔥 | 0 | 0 | 0 |
| four1 Reducer2 FAILED | **10** 🔥 | 0 | 0 | 0 |
| four1 耗时 | **751s** ⚠️ | 110s | **85s** ✅ | 135s |
| **数据结果** | ❌ **错** | ✅ 对 | 未验证 | ✅ **对（已核实）** |

**关键铁证**：
1. 异常和正常两次，four1 的 DAG 拓扑、task 切分数几乎完全相同（10 顶点 + Reducer 2/3/4 各 1009 task + Map 1 1153 task），**但**异常那次 four1 的 Map 1 / Reducer 2 / Reducer 10 一共有 **41 次 task attempt 失败 + 27 次被 KILLED**，被 Tez 自动重试拉起后 DAG 整体 SUCCEEDED，但写出的数据是错的 → silent data corruption
2. 📄4 跑出了唯一经过数据核对的正确结果（代价仅 +3% 耗时，+72s）

---

## 三、文档清单

| 文件 | 说明 |
|---|---|
| `case-data-loss-v5.md` | 📌 **数据异常根因报告 v5** — DEEPER 方法论 + Challenger 自审 + 源码级 bug 定位 |
| `report-timing-comparison.md` | 🔢 三份日志每段 SQL 耗时对比（基线版）|
| `report-timing-root-cause.md` | 🎯 三份日志耗时差异归因（含集群并发度分析）|
| `report-4logs-timing-analysis.md` | ⭐ **四份日志耗时对比与归因** — 最新版，含线上验证、三大归因矩阵、上线建议 |

阅读顺序建议：先看本 README（总览）→ `case-data-loss-v5.md`（搞清 bug 根因）→ `report-4logs-timing-analysis.md`（性能、验证、上线建议）

---

## 四、修复方案（按落地顺序 · 基于四份日志验证）

### 🟢 推荐主方案 · 关向量化 + 关 skew（已线上验证）

**脚本最开头加**（或配到 `.hiverc` 全局生效）：

```sql
-- 禁用向量化，规避 HIVE-20990（Apache 未修 bug）
set hive.vectorized.execution.enabled=false;

-- 关闭 skew 负优化（本 SQL 上开 skew 反而慢 23%）
set hive.groupby.skewindata=false;
set hive.optimize.skewjoin.compiletime=false;
```

**验证数据**：
- 📄4（05-07 11:19 手动跑）— 数据对账通过
- 总耗时 2290s vs 基线 2218s，**+3% 代价**
- 关 vec 的性能代价全部集中在 four1（+50s）和 four2（+26s）

**⚠️ 必须注意**：📄4 日志里 `set vec=false` 实际在 four1 前才 set，four 和 four0 仍在向量化开启下跑，其中 four0 第一次撞了 HIVE-20990（`return code 2`），靠客户端自动重试侥幸成功。**上线时必须前置到脚本最开头**，让所有 CTAS 全覆盖保护。

### 🟡 备选方案 · 仅关 skew（数据正确性未验证）

如果不能接受 +3% 耗时代价，可先试只关 skew：

```sql
-- set hive.groupby.skewindata=true;          ← 注释
-- set hive.optimize.skewjoin.compiletime=true; ← 注释
```

**理论分析**：关 skew 后 four1 DAG 从 10 顶点退化为 7 顶点，不再经过 `VectorMapJoinOuterMultiKey` 路径，HIVE-20990 触发概率大幅下降。

**风险**：
- 未经数据对账验证，仍可能偶发静默写错
- 其他 CTAS（four/four0/four2）仍在向量化下运行，仍有踩雷可能

**建议**：作为过渡方案，最终仍应合并主方案。

### 🟡 SQL 改写（1~2 周内）

把 `coalesce(sys.sys_name, sys1.sys_name, '') key_cust_flag` 从外层 SELECT/GROUP BY 抽到子查询里物化为普通字符串列，外层不再对 IF 表达式分组。详见 `case-data-loss-v5.md` §5。

### 🔴 集群级根治（排期）

**HIVE-26408 patch 已 backport 到腾讯内部 `emr-3.1.3` / `dev/edwin-3.1.3-xinxiwang` 分支**（commit `07d72a4bef`），但新希望生产环境可能未发版上线。patch 极简（单文件 1 处修改），风险低：

```diff
--- a/ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizationContext.java
+++ b/ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizationContext.java
@@ -2105,7 +2105,9 @@ private void freeNonColumns(VectorExpression[] vectorChildren) {
     for (VectorExpression v : vectorChildren) {
-      if (!(v instanceof IdentityExpression)) {
+      if (!(v instanceof IdentityExpression
+              || v instanceof ConstantVectorExpression)) {  // HIVE-26408
         ocm.freeOutputColumn(v.getOutputColumnNum());
       }
     }
```

建议：EMR 团队核实生产 `hive-exec-*.jar` 对应的 commit 是否已含 `07d72a4bef`；若未含则走发版流程升级。

### 兜底 · 数据探针

凌晨调度跑完后，立刻用 `hive.vectorized.execution.enabled=false` 重跑做哈希对账，差异 > 0.01% 自动告警 + 用关闭向量化版本覆盖。

---

## 五、三大耗时差异归因（来自四份日志对比）

| 归因 | 现象 | 量化 | 证据强度 |
|---|---|---|---|
| **1. 集群并发度差异** | Map1 RUNNING 列 3~10 vs 118~119 | 📄1 整体慢 **2.38×** | 🟢 高 |
| **2. HIVE-20990 触发重试** | four1 发生 41 次 task attempt 失败 | 额外 **+550s**（6.8× 放大）| 🟡 中 |
| **3. 关向量化代价** | four1 行模式逐行求值 | +66s / +3%（全集中在 four1/four2） | 🟢 高 |

**关键洞察**：📄2/📄3 跑得快，但 four1 同样可能偶发静默写错（只是本次没踩雷）。**"跑得快" ≠ "数据对"**，稳定性才是核心 KPI。

详见 `report-4logs-timing-analysis.md` 第四节。

---

## 六、经验教训（Lessons Learned）

### 6.1 本案排障过程中的教训

1. **日志阅读的行号归属必须精确**：`INFO execute <SQL>` 不是"开始执行该 SQL"，而是 SQL 执行完成后的结果回显，它**在 DAG 完成之后**才打印。早期报告多次因此把 four0 的 DAG 错当成 four1，导致结论反复翻车。
2. **"任务成功 ≠ 数据正确"**：调度系统看的是 return code，DAG 全绿只代表 task attempt 全部通过，不代表写出的数据是正确的。
3. **`wrong results OR AssertionError` 两种表现共存的 bug 最阴险**：不能因为"没报错"就认为数据对。
4. **challenger 一票否决机制起了关键作用**：用户连续多次纠正 eric 的错误结论（"bk 搞反了"、"four1 执行完全一样"、"18531 行还有 AssertionError"等），最终才对齐到真相。方法论上"先证据、再推断、强制自审"必须坚持。
5. **session 级 set 的 scope 必须仔细核对**：`set hive.vectorized.execution.enabled=false` 加在 four1 前和加在脚本最开头，保护范围完全不同。📄4 就踩了这个坑 —— 看起来"关向量化成功了"，实际 four0 仍在开启状态下跑且撞过一次雷。

### 6.2 通用规则沉淀

- 凡是 `IF/CASE + COALESCE + 多列 GROUP BY + 多表 LEFT OUTER MapJoin + ORC + 向量化`组合，都要警惕 HIVE-20990
- 调度任务的数据对账不能只看 return code，**必须有数据层面的独立校验**（行数 / 金额 / 关键字段哈希）
- `hive.groupby.skewindata=true` 不是万能优化，要基于是否有真实热点 key 评估，否则可能是负优化
- 关闭向量化类的 set 语句应放在脚本最开头或 `.hiverc`，避免 scope 不全导致的保护盲区
- Tez AM 重试机制不保证数据正确性 —— 第一次 task attempt 失败后，重试跑的 DAG 可能偶发"无报错但数据错"

---

## 七、线上验证记录

| 日期 | 版本 | 结果 | 备注 |
|---|---|---|---|
| 2026-05-05 04:59 | 调度版（skew=true, vec=default）| ❌ H4010 数据错（少 438 条 / 多 55.5w）| 📄1 |
| 2026-05-05 13:54 | 同参数手动重跑 | ✅ 数据对 | 📄2 — 但未彻底解决，同参数仍偶发风险 |
| 2026-05-06 11:18 | 注释 skew 两行 | 未做数据对账 | 📄3 — 耗时基线参考 |
| **2026-05-07 11:19** | **set vec=false + 注释 skew** | ✅ **数据对（已核对）** | 📄4 — 推荐方案验证 |

---

## 八、相关 JIRA / 链接

- [HIVE-20990 · ORC case when/if with coalesce wrong results or AssertionError](https://issues.apache.org/jira/browse/HIVE-20990)（Apache 官方未修复）
- [HIVE-26408 · Vectorization: Fix deallocation of scratch columns](https://issues.apache.org/jira/browse/HIVE-26408)（PR #3452，Fix Version 4.0.0-alpha-2）
- 内部 backport 到腾讯 EMR Hive 3.1.3 分支：commit `07d72a4bef`
- 本案原始日志目录（用户本地）：`C:/Users/lkl/Desktop/新希望sql丢数问题排查/`

---

*— eric · 案例归档 · 2026-05-07 17:30 更新版*
