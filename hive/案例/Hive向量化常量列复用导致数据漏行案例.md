# Hive 向量化常量列复用导致数据漏行案例

> 作者：eric  
> 时间：2026-05-12  
> 影响版本：Apache Hive 3.1.x（含 EMR 内部 fork dev/edwin-3.1.3-xinxiwang）  
> 修复 PR：HIVE-26408（社区 commit `b8ed1f8b43`，首发 4.0.0-alpha-2）  
> 触发组件：Hive on Tez（vectorization 开启）  
> 关键词：vectorization、ConstantVectorExpression、isRepeating、scratch column 复用、coalesce、CASE WHEN、漏数据、Tez 容错假成功

---

## 一、事故一句话定性

**同一条 9 步 Hive on Tez 流水线，凌晨首次跑（app_122773）和下午重跑（app_123051）的 SQL/源数据/DAG 拓扑完全相同，最终落库 `ads.ads_sales_contri_without_send` 第一次比第二次少 66,954 行（占比 0.466%）。根因是 Hive 3.1.3 的 vectorization scratch column 复用 bug（HIVE-26408），叠加当天集群 lost node + Tez 容错把 task 失败吞掉，最终调度系统看到 status=SUCCEEDED 但数据已悄悄丢了。**

---

## 二、现场事实链（从 Tez ATS dump 提取，每条都有出处）

### 2.1 流水线全貌（同一 application 内 9 个独立 DAG）

| DAG | Status | 7773 task | 3051 task | 写入表 |
|---|---|---:|---:|---|
| 1 | SUCCEEDED | 7,986 | 7,987 | tmp.tmp_sales_contri_four |
| 2 | **FAILED**（两次都败）| 1,530 | 1,530 | (failed before write) |
| 3 | SUCCEEDED | 2,403 | **2,602** | tmp.tmp_sales_contri_four**0** |
| 4 | SUCCEEDED | 3,183 | 3,183 | tmp.tmp_sales_contri_four**1** |
| 5 | SUCCEEDED | 3,416 | 3,418 | tmp.tmp_sales_contri_four**2** |
| 6 | SUCCEEDED | 1 | 1 | (准备阶段) |
| 7 | SUCCEEDED | 2 | 2 | tmp.tmp_sales_contri_four**3** |
| 8 | SUCCEEDED | 726 | 727 | (中间) |
| 9 | SUCCEEDED | 299 | **404** | **ads.ads_sales_contri_without_send（最终落库）** |

业务流水线：
```
ads_sales_contri → DAG1 → tmp_four → DAG3 → four0 → DAG4 → four1 
               → DAG5 → four2 → DAG7 → four3 → DAG9 → 最终表
```

DAG 2 在两次运行里都 fail（同一 vectorization 断言堆栈），HiveServer2 用同一 callerId 自动重试为 DAG 3，等于"DAG 2 失败被吞了"。

### 2.2 数据差异的逐 DAG 演进（关键裁判证据）

| DAG | 关键 vertex/counter | 7773 | 3051 | 差异 |
|---|---|---:|---:|---:|
| 1 | Map 1 INPUT_RECORDS（扫源表）| 192,448,493 | 192,448,493 | 0 ✅ 源数据完全一致 |
| 1 | Map 1 SEL_99 输出（过滤后）| 87,283,353 | 87,283,353 | 0 ✅ |
| 1 | Map 1 RS_100（ReduceSink）| **5,187,222,488** | **2,912,816,420** | +22.7 亿 ⚠ 副本倍数异常 |
| 1 | Reducer 3 写 tmp_four | 87,283,353 | 87,283,353 | 0（**行数同**）|
| 2 | FAILED 堆栈（Map 1 task）| `AssertionError: Output column number expected to be 0 when isRepeating` | 同 | — |
| 3 | Reducer 2 numTasks | 810 | **1,009** | -199 |
| 3 | 写 four0（HDFS bytes）| 116,708,035,521 | 116,708,032,332 | +3,189 字节 |
| **4** | **Map 1 读 four0（INPUT_RECORDS_PROCESSED）** | **88,347,129** | **88,413,615** | **-66,486 ⚠ 漏数据首次显现** |
| 4 | Reducer 3 写 four1 | **14,292,858** | **14,359,812** | **-66,954** |
| 5/7 | 写 four2/four3 | 14,292,858 | 14,359,812 | -66,954（透传）|
| **9** | **最终落库 ads.ads_sales_contri_without_send** | **14,292,858** | **14,359,812** | **-66,954 + 117 MB** |

**关键观察**：
- DAG 1 输出**行数完全相同**（87,283,353）——单看 DAG 1 dump 看不出问题
- 但 DAG 1 已触发 31 次 isRepeating 断言（task 失败重试，被 Tez 容错吞掉，最终 status=SUCCEEDED）
- 漏数据**首次显现是 DAG 4 Map 1 读 four0** —— 说明 DAG 3 写 four0 已经少
- Map 1 RS_100 的 59x vs 33x 副本倍数差异是另一条隐性证据（运行时 plan 优化路径分化）

### 2.3 集群健康度证据

| DAG | 7773 attempt FAILED | 3051 attempt FAILED |
|---|---:|---:|
| 1 | 0 | 0 |
| 2 (FAILED) | 1 | 0 |
| 3 | **7** | **0** |
| 4 | **41** | **0** |
| 其他 | 0 | 0 |
| **合计** | **49** | **0** |

7773 当天的失败诊断信息（来自 task_attempts dump）：
```
Container failed, exitCode=-100. Container released on a *lost* node
attempt ... being failed for too many output errors.
hostFailureFraction=0.625 (5/8), MAX_ALLOWED_DOWNSTREAM_HOST_FAILURES_FRACTION=0.2
```

→ 7773 跑期间（5/5 04:59~06:01）集群至少丢过一台节点（`10.6.176.*` 网段），触发级联 shuffle fetch 失败。3051 重跑时（5/5 13:54~14:22）集群健康，0 失败。

### 2.4 异常堆栈（DAG 1 Map 11 + DAG 2 Map 1 都抛）
```
java.lang.RuntimeException: java.lang.AssertionError:
  Output column number expected to be 0 when isRepeating
    at org.apache.hadoop.hive.ql.exec.tez.MapRecordSource.processRow:101
    at org.apache.hadoop.hive.ql.exec.tez.MapRecordSource.pushRecord:76
    at org.apache.hadoop.hive.ql.exec.tez.MapRecordProcessor.run:419
```

真实抛错点在 `LongColumnVector.setElement():272`：
```java
if (isRepeating && outputElementNum != 0) {
    throw new RuntimeException("Output column number expected to be 0 when isRepeating");
}
```

7773 触发 31 次，3051 触发 1 次。

---

## 三、根因定位（基于 Apache Hive 上游源码 + 本案 SQL 精确匹配）

### 3.1 真凶：HIVE-26408 — ConstantVectorExpression scratch 列复用

**社区 commit b8ed1f8b43**（首发 Hive 4.0.0-alpha-2，**3.1.3 release 没有**），修复 `VectorizationContext.java::freeNonColumns()`：

```java
// 3.1.3 (有 bug):
private void freeNonColumns(VectorExpression[] vectorChildren) {
    for (VectorExpression v : vectorChildren) {
        if (!(v instanceof IdentityExpression)) {
            ocm.freeOutputColumn(v.getOutputColumnNum());   // 把常量子表达式输出列也释放了
        }
    }
}

// 4.0.0-alpha-2 (修复):
private void freeNonColumns(VectorExpression[] vectorChildren) {
    for (VectorExpression v : vectorChildren) {
        if (!(v instanceof IdentityExpression
              || v instanceof ConstantVectorExpression)) {  // ← 跳过常量
            ocm.freeOutputColumn(v.getOutputColumnNum());
        }
    }
}
```

### 3.2 Bug 触发机制（三层剥离）

**第 1 层：scratch 列复用机制**  
Hive vectorization 为节省内存，对 1024 行一批的 batch 中间计算结果做 scratch column 复用：表达式算完结果就 `freeOutputColumn(N)` 标记可回收，下个表达式申请就拿这个 N。

**第 2 层：ConstantVectorExpression 的特殊性**  
`ConstantVectorExpression` 表示 SQL 字面常量（`''`、`NULL`、`'低温酸奶'` 等）。其 ColumnVector **强制 `isRepeating=true`** 且只填第 0 行（`ConstantVectorExpression.java` 内 7 处 `cv.isRepeating = true`）。这是合法优化——一个常量值整批 1024 行都一样。

**第 3 层：3 个调用点 = 3 个高风险算子**  
3.1.3 上 `VectorizationContext.java::freeNonColumns` 在 3 个地方被调用：
- 行 2141：构造 `VectorCoalesce`（即 SQL `coalesce()`）后
- 行 2172：构造 `VectorElt`（即 `elt()`）后
- 行 2255：构造 `VectorCase`（即 `CASE WHEN`）后

这三个算子内部都用 `setElement(batchIndex, ...)` 按行写出。如果某个 child 是常量被错误释放然后被复用为某个需要按行写的输出列，setElement 就会触发 `LongColumnVector.setElement():272` 的 isRepeating 断言。

### 3.3 本案 SQL 精确命中（DAG 1 SQL）

```sql
-- 6 处 coalesce(列, 常量) → 6 次 VectorCoalesce + 6 个 ConstantVectorExpression
,coalesce(i.new_4,'')           name
,coalesce(i.new_3,'')           classify
,coalesce(i.new_2,'')           new_2
,coalesce(i.new_1,'')           new_1
,coalesce(dsxs1.vtweg, dsxs2.vtweg)              shang_flag
,coalesce(case when ... end, '')                 key_prod_class

-- 2 个超大嵌套 CASE WHEN，每个 ELSE 分支都是字符串常量
CASE WHEN locate('活润',mat_name)>0 AND prod_mid_categ_name='低温酸奶' THEN '活润-酸奶'
     ELSE CASE WHEN ... THEN '活润-乳酸菌饮料'
     ELSE CASE WHEN ... THEN '24小时'
     ELSE CASE WHEN ... THEN '初心'
     ELSE CASE WHEN ... THEN '今日鲜奶铺'
     ELSE CASE WHEN ... THEN '澳特兰'
     ELSE NULL
     END END END END END END END  tssn_flag    -- 6 层嵌套 + 7 个常量分支
```

社区 patch 自带 reproducer `ql/src/test/queries/clientpositive/scratch_col_issue.q` 的核心模式：
```sql
CASE WHEN val IN ('TermDeposit', 'RecurringDeposit', 'CertificateOfDeposit')
     THEN NVL(complex_expr, ' ')
     ELSE ''
END
```

**本案 SQL = 这个 reproducer 的"超浓缩升级版"**，CASE 嵌套更深、常量分支更多、coalesce 更多层嵌套。

### 3.4 现象-原因因果链闭合

| 现象 | 原因 |
|---|---|
| 7773 触发 31 次 / 3051 触发 1 次 | scratch 池分配顺序受运行时 batch 数据分布影响，是概率事件。同 SQL 同源数据不同次跑触发不同次数符合"复用碰撞"特征 |
| 抛错都在 Map 11（join 后字段合并算子）+ DAG 2 Map 1 | Map 11 内部正是 coalesce/case 表达式密集区 |
| 行数最终少 66,954 | 31 次断言失败 → task attempt 重试 → 与 lost-node 5/8 host failure + downstream output errors 叠加 → 边界 batch 数据被 Tez 容错吞掉 |
| 整体 status=SUCCEEDED 但数据丢 | DAG 2 失败被 HS2 自动重试（DAG 3）；DAG 3/4 共 48 个 attempt FAILED 被 Tez 重试机制吞掉。调度层无感知 |

---

## 四、4 个候选 PR 的硬碰硬验证（这一节是排查走过的弯路，留作教训）

排查中我先后列过 22 个 PR、其中 4 个标为 P0。用本案 6 个硬证据逐个核查后大幅修正：

| PR | 之前定级 | 修正定级 | 修正理由（用本案具体证据） |
|---|---|---|---|
| **HIVE-26408** | P1 | **P0 必修** | ConstantVectorExpression 复用，本案 SQL 6+ coalesce + 嵌套 CASE WHEN 直接命中，触发 isRepeating 断言 |
| HIVE-21923 | P0 | **剔除** | patch 只改 `VectorMapJoinInnerBigOnly`（INNER JOIN only），本案 8 个 LEFT JOIN，**代码路径不命中** |
| HIVE-22120 | P0 | P2 | 修 `finishOuterRepeated` NOMATCH 边界，需要复合 key 整批 isRepeating + 整批 NOMATCH，本案概率低；且不触发 isRepeating 断言 |
| HIVE-21837 | P0 | **剔除** | 修 `makeLikeColumnVector` 缺 `VoidColumnVector` 分支，未打 patch 时抛 `HiveException: Column vector class ... is not supported`，**异常类型与本案完全不符** |
| HIVE-20985 | P0 | P1 | 修 SELECT operator 输入输出复用（算子之间），与本案同病（scratch 复用）但不同药——本案是 freeNonColumns 路径（算子内部子表达式之间），不是 SELECT operator 路径 |

**真正命中本案的就 HIVE-26408 一个**。其他都是同模块预防性修复，没有本案具体证据要求必打。

---

## 五、处置方案

### 5.1 立刻（事故当天必做）

**回滚 7773 那次产出的下游表**，按依赖顺序，全部用 3051 的覆盖：
```
tmp.tmp_sales_contri_four → four0 → four1 → four2 → four3 → ads.ads_sales_contri_without_send
```

**临时关闭向量化**（最稳）：
```sql
set hive.vectorized.execution.enabled=false;
set hive.vectorized.execution.reduce.enabled=false;
```

或只关 native MapJoin（更小代价）：
```sql
set hive.vectorized.execution.mapjoin.native.enabled=false;
set hive.vectorized.execution.mapjoin.native.fast.hashtable.enabled=false;
```

### 5.2 本周（backport patch + 监控加固）

**Backport HIVE-26408 到内部分支**（最小 patch，3 行有效代码）：

```java
// ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizationContext.java
// 3.1.3 第 2107 行附近的 freeNonColumns 函数内
for (VectorExpression v : vectorChildren) {
-   if (!(v instanceof IdentityExpression)) {
+   if (!(v instanceof IdentityExpression
+         || v instanceof ConstantVectorExpression)) {  // HIVE-26408
        ocm.freeOutputColumn(v.getOutputColumnNum());
    }
}
```

cherry-pick 命令：
```bash
cd D:\bigdata\gitproject\hive
git checkout dev/edwin-3.1.3-xinxiwang
git cherry-pick b8ed1f8b43      # 行号会偏，手工 apply 即可
```

**调度系统加防线**（重要，根治"假成功"）：
- 流水线最终落库表 row_count 与昨日基线 diff > 0.1% **强制告警**
- 单 DAG 内 attempt FAILED > 5 触发告警，不要被 Tez 的"假成功"骗
- 关键作业 `tez.am.task.max.failed.attempts=1`，宁可整体失败也不要"数据丢但报成功"

**集群层面**：排查 5/5 04:59~06:01 时段 `10.6.176.*` 节点 lost 根因（OOM/磁盘/网络/重启）

### 5.3 中期（本月内）

按需要 backport 这些次级 PR（不影响本案，但消除同类型其他场景风险）：
- HIVE-22120（outer mapjoin NOMATCH 边界）
- HIVE-20985（SELECT operator scratch 复用）
- HIVE-22814（mapjoin overflow batch dataTypePhysicalVariation）
- HIVE-26269（CASE WHEN ClassCastException）
- HIVE-26447（filter on repeating map key）

### 5.4 长期

**强烈建议升级到 Hive 4.0.1+**：所有相关 PR 已合入，3.1.3 已是社区 EOL。

---

## 六、检测脚本（用于定期排查同类风险）

### 6.1 检测正在运行的 Hive 是否带 HIVE-26408 patch

```bash
# 检查方法 1：源码 marker
grep -A1 "freeNonColumns" $HIVE_HOME/lib/hive-exec-*.jar:VectorizationContext.class \
  | grep "ConstantVectorExpression"
# 命中 → 有 patch；无命中 → 缺 patch
```

### 6.2 SQL 静态扫描（找高危 SQL）

```sql
-- 在 HiveServer2 历史日志里捞这些模式：
-- 模式 1：coalesce(任意, '常量') 出现 ≥3 次
-- 模式 2：CASE WHEN 嵌套深度 ≥3 且每层 ELSE 是字符串常量
-- 模式 3：select 列表 + 8 个以上 LEFT JOIN
-- 任何一个命中 + Hive 3.1.x + vectorization 开启 → 高危
```

### 6.3 Tez 失败模式监控（配合 Grafana/Prometheus）

```
# 告警条件
ALERT TezVectorizationAssertion
  EXPR (sum(rate(tez_task_attempt_failures{reason="isRepeating"}[5m])) > 0)
  FOR 1m
  ANNOTATION "Hive vectorization isRepeating assertion triggered, possible HIVE-26408"
```

---

## 七、本次排查方法论沉淀

整个排查经历 4 轮才稳健，每轮被用户纠错一次：

| 轮次 | 错误 | 教训 |
|---|---|---|
| v1 | 只看 dag_1 zip 就出结论；列 4 个 JIRA（HIVE-21580/22016/24655/25296）有 3 个根本不存在 | 不要凭印象列 PR；要从 git log 实际查 |
| v2 | 把 9 个 zip 当成一个 DAG 的分片，没意识到是 9 个独立 DAG | 解压前先核实文件结构（callerId、dagName、status 都不一样就是不同 DAG）|
| v3 | 在内部 fork 用 commit-hash 判 PR 落地版本，被 cherry-pick 改 hash 误导（误判 HIVE-22120 已在 3.1.3）| 用上游 apache/hive 仓库做权威判断；marker 校验必须带函数名上下文 |
| v4 | 列 22 个 PR 当"知识广度"，没结合本案具体证据筛 | 每个 PR 必须用本案现场事实硬碰硬验证：触发条件 vs 本案数据，不命中就剔除 |

最终结论的可信度依靠的是：
- **6 个本案现场硬证据当裁判**（断言堆栈、抛错位置、SQL join 类型、Tez counter、漏数据首现位置、attempt 失败次数）
- **每个 PR 的真实 patch 内容**（不是 JIRA 标题或脑补）
- **PR 触发条件与本案 SQL/join 类型/抛错堆栈的精确匹配**
- **不能解释证据的就剔除**

---

## 八、TL;DR

1. **数据少了 66,954 行**，最终落库 `ads.ads_sales_contri_without_send` 受影响
2. **真凶：Hive 3.1.3 的 ConstantVectorExpression scratch 列复用 bug（HIVE-26408），叠加当天集群 lost node**
3. **本案 SQL 用了 6+ 个 `coalesce(col,'')` + 2 个超大嵌套 `CASE WHEN`**，是 bug 触发的极端命中模式
4. **Tez 容错把 31 次 task 失败 + 集群抖动吞掉**，最终 status=SUCCEEDED 但数据已丢
5. **立即关向量化 + 重跑下游表；本周 backport HIVE-26408（3 行代码）；长期升级 Hive 4.0+**

---

## 九、附录

### 9.1 关键术语

| 术语 | 含义 |
|---|---|
| Tez DAG | 一次 SQL 查询的执行计划图，由若干 Map/Reducer vertex 组成 |
| Tez Vertex | DAG 中的一个执行节点，对应 SQL 的某个 stage（Map / Reducer） |
| Vectorization | Hive 把 1024 行打包成一个 batch 用列式 ColumnVector 处理的优化 |
| ColumnVector | 向量化中存一列 1024 行数据的容器 |
| isRepeating | ColumnVector 的优化标志，表示这一列整批 1024 行值都相同，只用第 0 行存 |
| ConstantVectorExpression | 表示字面常量的向量化表达式，强制 isRepeating=true |
| scratch column | vectorization 编译期分配的临时列号，用于存中间计算结果，可回收复用 |
| freeNonColumns | VectorizationContext 内部函数，构造 VectorCoalesce/VectorElt/VectorCase 后释放 child 子表达式占用的 scratch 列 |

### 9.2 证据文件清单

| 文件 | 内容 |
|---|---|
| `final-summary.md` | 最终总结 |
| `case-tez-dag-diff-122773-vs-123051-v2.md` | 9 DAG 完整对比报告 |
| `hive-26408-deep-analysis.md` | HIVE-26408 patch 三层剥离 + 本案命中分析 |
| `hive-4-pr-硬碰硬验证.md` | 4 个候选 PR 的逐个证据审查 |
| `hive-patch-audit-v4-community.md` | 社区上游仓库权威核查（22 个 PR 落地版本）|
| `all_dags_summary.txt` | 9 个 DAG 全部 vertex 级 RECORDS 对比 |
| `verify_in_community.py` 等 | 复现核查的脚本 |

源码核查仓库：`D:\bigdata\gitproject\hive`（origin = github.com/apache/hive）  
内部基线：`D:\bigdata\txproject\hive`，分支 `dev/edwin-3.1.3-xinxiwang`

### 9.3 关联案例

- `HIVE-20990向量化偶发数据错乱/`（同模块同根源的另一个 vectorization 偶发数据错乱案）
- `HS2查询结果不对排障/`（同类"行数对但值不对"问题）
