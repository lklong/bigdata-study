# Hive 向量化 HIVE-20990 偶发数据错乱 · 案例归档

> 归档时间：2026-05-07
> 归档人：eric
> 组件：Hive on Tez（EMR Hive 3.x）
> 风险等级：🔴 P0（silent data corruption，无报错静默出错）

---

## 一、案例一句话

新希望财务管报流水线 `ADS_SALES_CONTRI_WITHOUT_SEND` 昨天跑出来的 H4010 公司 202604 月折后收入 `147,893,249.51`，比今天重跑的正确值 `147,337,875.57` **多 55.5w**，条数也多 **438 条**。同一 SQL、同一参数、同一上游数据、同一 DAG 拓扑，**凌晨跑错、下午重跑对**，而且**两次 four1 的 DAG 全绿、零报错**。

**根因**：Apache Hive 官方未修 bug **[HIVE-20990](https://issues.apache.org/jira/browse/HIVE-20990)** —— 向量化执行引擎 `IfExprCondExprCondExpr` 在 `IF/CASE + COALESCE + 多键 LEFT OUTER MapJoin + GROUP BY + ORC` 组合下，存在**非确定性的 scratch column 错误复用**，两种表现共存：

- **表现 A**：抛 `AssertionError: Output column number expected to be 0 when isRepeating` → task 失败，被 Tez 重试拉起后通常数据正确
- **表现 B**：**没抛断言，但 scratch column 已经被错误覆盖** → DAG 全绿 + 字符串列静默写错位 → GROUP BY key 错乱 → 数据异常

凌晨那次 four1 正好踩中表现 B → silent data corruption。

---

## 二、核心证据链（三份日志对照）

| 对比维度 | 数据异常那次 | 正常那次 | 关闭 skew 那次 |
|---|---|---|---|
| 启动时间 | 2026-05-05 04:59（调度自动）| 2026-05-05 13:54（手动重跑）| 2026-05-06 10:50（手动测试）|
| `maxDateTime` | 2026-05-04 | 2026-05-05 | 2026-05-06 |
| 总 DAG 耗时 | **5281.81s**（88min）| 2217.64s（37min）| 2224.00s（37min）|
| **four1 DAG 顶点** | 10 | 10 | **7**（拓扑不同）|
| **four1 Map 1 FAILED** | **30** 🔥 | 0 | 0 |
| **four1 Reducer 2 FAILED** | **10** 🔥 | 0 | 0 |
| **four1 耗时** | **751.50s** ⚠️ | 110.62s | 85.31s |
| 数据结果 | ❌ 错 | ✅ 对 | 未验证 |

**关键铁证**：异常和正常两次，four1 的 DAG 拓扑、task 切分数几乎完全相同（8 顶点 + Reducer 2/3/4 各 1009 task + Map 1 337 vs 338），**但**异常那次 four1 的 Map 1 / Reducer 2 / Reducer 10 一共有 **41 次 task attempt 失败 + 27 次被 KILLED**，被 Tez 自动重试拉起后 DAG 整体 SUCCEEDED。

---

## 三、文档清单

| 文件 | 说明 |
|---|---|
| `case-data-loss-v5.md` | 📌 **主报告 v5** — 数据异常根因分析，含 DEEPER 方法论、Challenger 自审、修复方案（终结版） |
| `report-timing-comparison.md` | 🔢 三份日志每段 SQL 耗时对比报告（纯耗时分析，不涉及数据正确性） |
| `report-timing-root-cause.md` | 🎯 耗时差异归因报告（Orchestrator + Challenger 双审） |

---

## 四、修复方案（按落地顺序）

### 🟢 SAFE · 立即止血（今晚上线）

在 four1 CTAS 前加一行：
```sql
set hive.vectorized.if.expr.mode=good;
```
零风险、秒级回滚、性能损失 < 5%。跳过踩雷的 `IfExprCondExprCondExpr` 代码路径。

### 🟡 CAUTION · 顺手关掉无收益参数

耗时对比发现 skew 参数对 four1 不但没提速、反而**慢 23%**（110s vs 85s）。可以一起关：
```sql
-- set hive.groupby.skewindata=true;         ← 注释
-- set hive.optimize.skewjoin.compiletime=true; ← 注释
```

### 🟡 CAUTION · SQL 改写（1 周内）

把 `coalesce(sys.sys_name, sys1.sys_name, '') key_cust_flag` 从外层 SELECT/GROUP BY 抽到子查询里物化为普通字符串列，外层不再对 IF 表达式分组。具体改写示例见 `case-data-loss-v5.md` §5。

### 🔴 DANGER · 集群级根治（排期）

EMR Hive 升级到含 HIVE-26408 补丁的版本，或在 hive-site.xml 设 `hive.vectorized.if.expr.mode=good` 全局默认。

### 兜底 · 数据探针

凌晨调度跑完后，立刻用 `hive.vectorized.execution.enabled=false` 重跑做哈希对账，差异 > 0.01% 自动告警 + 用关闭向量化版本覆盖。

---

## 五、经验教训（Lessons Learned）

### 5.1 本案排障过程中的教训

1. **日志阅读的行号归属必须精确**：`INFO execute <SQL>` 不是"开始执行该 SQL"，而是 SQL 执行完成后的结果回显，它**在 DAG 完成之后**才打印。早期报告多次因此把 four0 的 DAG 错当成 four1，导致结论反复翻车。
2. **"任务成功 ≠ 数据正确"**：调度系统看的是 return code，DAG 全绿只代表 task attempt 全部通过，不代表写出的数据是正确的。
3. **`wrong results OR AssertionError` 两种表现共存的 bug 最阴险**：不能因为"没报错"就认为数据对。
4. **challenger 一票否决机制起了关键作用**：用户连续 4 次纠正 eric 的错误结论（"bk 搞反了"、"four1 执行完全一样"等），最终才对齐到真相。方法论上"先证据、再推断、强制自审"必须坚持。

### 5.2 通用规则沉淀

- 凡是 `IF/CASE + COALESCE + 多列 GROUP BY + ORC + 向量化`的组合，都要警惕 HIVE-20990
- 调度任务的数据对账不能只看 return code，**必须有数据层面的独立校验**（行数 / 金额 / 关键字段哈希）
- `hive.groupby.skewindata=true` 不是万能优化，要基于是否有真实热点 key 评估，否则可能是负优化

---

## 六、相关 JIRA / 链接

- [HIVE-20990 · ORC case when/if with coalesce wrong results or AssertionError](https://issues.apache.org/jira/browse/HIVE-20990)
- HIVE-26408 · 相关补丁（已合入 Hive 4.0+）
- 本案原始日志目录（用户本地）：`C:/Users/lkl/Desktop/新希望sql丢数问题排查/`

---

*— eric · 案例归档 · 2026-05-07*
