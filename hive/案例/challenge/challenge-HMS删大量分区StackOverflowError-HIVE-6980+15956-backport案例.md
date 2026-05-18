# challenge — HMS 删大量分区 StackOverflowError 案例处理复盘

> 对应正式案例：[HMS删大量分区StackOverflowError-HIVE-6980+15956-backport案例.md](../HMS删大量分区StackOverflowError-HIVE-6980+15956-backport案例.md)
> 复盘时间：2026-05-18 20:25
> 复盘人：eric（用户视角） + 编排器（AI 视角，自我反思）

本文件**只**记录处理过程中的判断失误、方法论盲点、改进方向。技术结论不重复（看正式案例）。

---

## 一、关键失误清单

### 失误 1：错误把社区 case 数字当成栈临界值

| 维度 | 内容 |
|---|---|
| 现象 | 第一轮分析时 AI 说"9000 OR 链是栈临界值，所以 -Xss10m 应该够" |
| 实际 | 9000 是社区 HIVE-15956 JIRA 复现 case 里的具体数字，跟当前现场栈大小无任何对应关系 |
| 后果 | 误判建议方向（让 eric 去加大 Xss），偏离根因 |
| 根因 | AI 把"听过的数字"当"通用阈值"，没核对推导 |
| 改进规则 | **凡是给"临界阈值"必须附带推导链：栈大小 ÷ 单帧大小 ≈ 最大递归深度。不能直接引用别的 case 的数字** |

### 失误 2：把 Plan B 的结构性冲突误判为"不可补"

| 维度 | 内容 |
|---|---|
| 现象 | cherry-pick HIVE-15956 时遇到 ObjectStore.dropPartitions 大段冲突，AI 第一反应是"这是代码漂移，不可补"，提议放弃 |
| 实际 | 冲突的根源是缺前置 PR HIVE-6980。补完 6980 后冲突自动消失（这就是冲突驱动反推依赖的标准操作） |
| 后果 | 多花 1 轮对话才回到正确路径，eric 主动提示"HIVE-6980 看看是不是缺这个" |
| 根因 | AI 的 cherry-pick 经验只想到"上下文版本不一致"，没主动想到"前置 PR 缺失" |
| 改进规则 | **遇到 cherry-pick 冲突时，先 grep 冲突代码引用的方法/类是否存在；不存在的 → 99% 是缺前置 PR，立即去 git log --grep 查相关 JIRA**|

### 失误 3：HIVE-6890 笔误未及时纠正

| 维度 | 内容 |
|---|---|
| 现象 | 内部 backport 早期 commit 把 HIVE-6980 写成 HIVE-6890；本次 squash commit 又一次写成 HIVE-6890 |
| 实际 | 实际是 HIVE-6980（Drop table by using direct sql） |
| 后果 | JIRA 追溯歧义，搜内部仓 git log 找不到正确 PR |
| 根因 | AI 没在第一次看到时核对 JIRA 标题，让笔误继续传播 |
| 改进规则 | **每次提到 HIVE-XXXX 必须对照 JIRA title 一次，不能仅凭别人 commit message 复读**|

### 失误 4：本地工程目录写错

| 维度 | 内容 |
|---|---|
| 现象 | 实验工程默认建到 `D:\bigdata\2026project\hms-sof-repro\`，但 eric 的 AI 实验目录是 `D:\bigdata\2026aiproject\` |
| 实际 | 2026project 是 eric 自己人工开发，2026aiproject 才是 AI 实验区 |
| 后果 | 文件迁移占用一次对话 |
| 根因 | lkl-java-remote-runner skill 文档默认写的就是 2026project，AI 没问 eric 偏好就直接套用 |
| 改进规则 | 已沉淀进 memory（[78261303]）：**AI 协作工程默认 D:\bigdata\2026aiproject\<artifact-id>\**；skill 文档内的默认值要被 memory 覆盖 |

### 失误 5：配置过度添加（"对齐生产"型借口）

| 维度 | 内容 |
|---|---|
| 现象 | backport 上线时给 hive-site.xml 加了 3 个配置：`metastore.rawstore.batch.size=300` + `hive.metastore.try.direct.sql=true` + `hive.metastore.batch.retrieve.table.partition.max=300` |
| 实际 | 只有第 1 个跟 SOF 修复有关；第 2 个是默认值（多余）；第 3 个是控制 retrieve 路径（与 drop/SOF 完全无关） |
| 后果 | 配置语义不干净；后人维护时会困惑"为什么要这三个" |
| 根因 | AI 用"对齐生产现场"做借口，没逐条核对每个配置的实际作用域 |
| 改进规则 | **每加一条配置必须证明"它属于本次修复链路"。不属于的不加，哪怕是默认值也不显式写**|

### 失误 6：watch 脚本等待时间不足

| 维度 | 内容 |
|---|---|
| 现象 | A2 阶段（ORM 路径）跑完后 watch 用 60 秒判定，但 ORM 实际要 91.8 秒 → watch 抓到的是"java 进程已结束、表分区数仍 12000"的快照，错误暗示"drop 失败" |
| 实际 | drop 成功了，watch 跑得太早 |
| 后果 | 多花一轮对话用 check_a2_result.sh 重新读 drop.out 才发现实际成功 |
| 根因 | 没考虑路径性能差异：DirectSQL ~2s vs ORM ~90s，差 40 倍。watch 时间窗口不能写死 |
| 改进规则 | **耗时类验证脚本，等待时间应基于"理论最长耗时 × 2 安全系数"，不要写 60s 这种武断值**|

---

## 二、方法论改进

### 改进点 1：给"临界阈值"建立推导卡片

任何"X 数量会触发 Y 问题"的论断，必须附 3 件套：
1. **机制**：为什么是这个量级（递归 / 内存 / 网络包大小 / SQL 包长度）
2. **推导**：能/资源 = 单位消耗 × N，求 N 上限
3. **置信度**：是计算值 / 经验值 / 道听途说 — 标注清楚

模板：
```
阈值: 9000 OR 链炸 -Xss1m 栈
机制: DataNucleus ExpressionCompiler 每层 OR 用 2 帧栈（compileExpression + compileOrAndExpression）
推导: 1MB ÷ 平均帧 ~50 字节 ≈ 20000 帧 = 10000 层 OR；考虑 JIT/异常栈预留，9000-10000 是经验合理区间
置信度: 经验值（社区 case + 本次实测推算）
```

### 改进点 2：cherry-pick 冲突的标准 SOP

```
1. 看冲突 → 提取冲突区域引用的"陌生符号"（方法名/类名/字段名）
2. grep 当前分支：grep -r "<symbol>" src/   是否完全不存在
3. 完全不存在 → 99% 缺前置 PR
4. git log --all --grep="<symbol>" 找出引入这个 symbol 的 commit
5. 看那个 commit 的 message 找 JIRA 号 → 这是真正缺的前置 PR
6. 把前置 PR cherry-pick 上来 → 再回去 cherry-pick 当前 PR
```

不要轻易说"代码漂移大不可补"。

### 改进点 3：每个配置都要写"为什么加它"注释

`hive-site.xml` 加任何配置时，给 AI 自己写一份 markdown 注释：

```
metastore.rawstore.batch.size = 300
  why: HIVE-15956 ORM 路径分批阈值，默认 -1 表示不分批，必须显式 >0 让 backport 真生效
  scope: dropPartitionsViaJdo / getPartitionsViaOrmFilter
  side-effect: 内存压力 / 多次小 SQL，对 MySQL 后端无害
```

不能写出 why/scope 的配置就是没必要加。

### 改进点 4：远程异步任务的"最长合理时间"估算法

启动后台 java 任务前，先估一个"最长合理时间"，watch 间隔基于这个值定：

| 操作 | 单元成本估计 | 12k 分区耗时估计 |
|---|---|---|
| add_partitions | thrift RPC ~3-4ms × 24 批 | ~50s |
| dropPartitions DirectSQL | ~30 条 SQL × 50ms | ~3s |
| dropPartitions ORM 分批 300 | 40 批 × 1.5-2s/批 | ~80-100s |
| listPartitionNames | 单次 RPC | <1s |

watch 等待时间 = max(理论估算) × 2 = 200s 安全。

---

## 三、本次处理的方法论亮点（保留发扬）

不是只挑刺。本次也有几个做对的地方，可以沉淀成正向规则：

1. **冲突驱动反推依赖 PR**（虽然初判失误，最终通过 eric 提示 + 实操矫正了）：从"diff 看不懂"→ "缺哪个符号" → "查 JIRA" → "前置 PR" 这条路径在 backport 类工作里值得形成肌肉记忆
2. **复现 + 正向验证 + 强制 fallback 验证三连**：覆盖 backport 三个 PR 全部功能，矩阵验证比仅"主路径能跑就行"更扎实
3. **配置极简化**：A 路径删多余配置，是良性的"删冗余"动作。维护是减法不是加法
4. **远程实验改 setsid + nohup + 文件落盘**：避开 SSH session 中断把 java 进程一起带走的坑，这套样板值得在 lkl-java-remote-runner skill 里固化
5. **每次给 eric 终止前都给"接下来选什么"的菜单**：让用户保持驾驶位，不会被 AI 带跑

---

## 四、待沉淀的经验规则（可放入 knowledge/经验规则.md）

| Rule ID | 模式 | 推导 |
|---|---|---|
| EXP-RULE-HIVE-DROP-SOF | HMS 删大量分区出 `StackOverflowError @ DataNucleus.compileOrAndExpression` | 99% 是 dropPartitions 走 ORM 长 OR 链；try.direct.sql=true 不能修；需 backport HIVE-6980+15956 或客户端分批 ≤500 |
| EXP-RULE-CHERRY-PICK-MISSING-DEPS | cherry-pick 冲突区引用了当前分支不存在的符号 | 立即查"该符号是哪个 commit/PR 引入的" → 几乎必然是缺前置 PR |
| EXP-RULE-CONFIG-MUST-PROVE-RELEVANCE | hive-site/yarn-site 加配置时，必须证明它在本次修复链路上 | 不能用"对齐生产现场"做万能借口；不属于的不加 |
| EXP-RULE-HMS-DROP-NOT-DIRECTSQL | Hive 3.1.x 原版的 drop 路径**不**走 DirectSQL | 反直觉点；try.direct.sql 控制 select 路径，不控制 drop |

---

## 五、改进项落实清单

| 改进项 | 落地位置 | 状态 |
|---|---|---|
| AI 实验工程目录 → 2026aiproject | memory[78261303] | ✅ 已固化 |
| 远程异步任务 setsid+nohup 模板 | 待写入 lkl-java-remote-runner 的 references/code_skeleton.md | ⬜ 待办 |
| 配置变更必证关联 | 待写入 lkl-bigdata-ops-orchestrator 的 agents/16-compliance.md | ⬜ 待办 |
| HMS 删分区 SOF 经验规则 | bigdata-study/rules（如有）+ knowledge/经验规则.md | ⬜ 待办 |
| watch 脚本等待时间标准 | 待写入 lkl-java-remote-runner 的 SKILL.md | ⬜ 待办 |
