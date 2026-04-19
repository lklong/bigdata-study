# Tez 分片文档集 — 审核报告

> **审核角色**：合规守卫（Compliance Guardian）+ 质疑检查员 + Eric 负责人终审  
> **审核时间**：2026-04-18 09:33  
> **审核范围**：当前工作区 6 篇 Tez 分片相关文档 + 1 张时序图

---

## 一、审核文档清单

| # | 文档 | 行数 | 定位 |
|---|------|------|------|
| 1 | `tez-hive-split-calculation-源码解析.md` | 1112 | 核心源码链路文档 |
| 2 | `tez切片完整链路_源码+实际对照.md` | 360 | 理论+实际时间对照 |
| 3 | `tez分片逻辑与解法.md` | 224 | 分片逻辑 + 配置级解法 |
| 4 | `tez分片availableSlots源码解法.md` | 249 | 源码级解法（4种方案） |
| 5 | `app_683560_vs_682541_map数差异分析.md` | 210 | 两个 App 对比 |
| 6 | `app_683560_资源分析报告.md` | 231 | RM 端资源变化分析 |
| 7 | `tez-split-sequence-diagram.html` | — | 时序图 |

---

## 二、合规守卫审核（事实准确性 + 源码对齐）

### 2.1 已确认正确的内容 ✅

| 项 | 内容 | 验证方式 |
|----|------|----------|
| ✅ | `totalResources` 只在 `getProgress()` 中 `if(memory==0)` 时赋值一次 | 源码 `YarnTaskSchedulerService.java` L901 已 read_file 验证 |
| ✅ | 调用链 `getTotalAvailableResource() → TezRootInputInitializerContextImpl → TaskSchedulerManager → YarnTaskSchedulerService.getTotalResources()` | 源码逐层 read_file 验证 |
| ✅ | `HiveSplitGenerator.initialize()` 三步：①计算 availableSlots → ②getSplits → ③generateGroupedSplits | 源码 read_file 验证 |
| ✅ | `preferredSplitSize = Math.min(blockSize/2, minGrouping)` | 源码 read_file 验证 |
| ✅ | `SplitGrouper.generateGroupedSplits(6参→8参)` 转调关系 | 源码 read_file 验证 |
| ✅ | `tezGrouper` 类型是 `TezMapredSplitsGrouper`（非 `TezSplitGrouper`） | 源码字段声明 read_file 验证 |
| ✅ | `HiveInputFormat.getSplits()` 按分区遍历 + `addSplitsForGroup()`，不是直接调 `FileInputFormat` | 源码 read_file 验证 |
| ✅ | TEZ-3168 / HIVE-24734 社区 JIRA 存在且状态正确 | web_fetch 验证过 |
| ✅ | 两个 App 时间线（提交/启动/DAG/失败时间）| HS2+RM 日志已验证 |
| ✅ | 682541 的 task_000245 EOFException | HS2 日志已验证 |

### 2.2 发现的问题 ⚠️

#### 问题 1：`app_683560_vs_682541_map数差异分析.md` 第 193-197 行 — 旧结论残留 ❌

```
第193行: **源表...是 Kafka 实时落地表，分区...在 04-08 凌晨持续写入数据。**
第196行: - **03:51**（683560）：经过 3.5 小时 Kafka 持续写入，分区数据量约 2X → 487 个 Map
第197行: - **Map 数 ≈ 数据量 / grouping.max-size**，数据量翻倍 → Map 数翻倍
```

**问题**：大哥在后续对话中明确指出"数据是7号生产的不会变"。这篇文档的结论部分仍然把"Kafka 持续写入导致数据量翻倍"作为根因，**与后续修正后的正确结论（availableSlots 不同）矛盾**。

**正确结论**：数据量不变，根因是 availableSlots（headroom 快照）不同。

**严重度**：🔴 高 — 这是根因判断错误，直接影响分析可信度。

#### 问题 2：`app_683560_vs_682541_map数差异分析.md` 第 115 行 — 表述不精确 ⚠️

```
`availableSlots` 是 **AM 注册那一瞬间** RM 返回的队列资源快照。
```

**问题**：不是"注册那一瞬间"，而是"第一次心跳（allocate RPC #1）的 headroom"。`registerApplicationMaster()` 的返回值不含 headroom。这个区别在 `tez切片完整链路` 文档中已经纠正了，但本文档仍有旧表述。

**严重度**：🟡 中 — 技术细节不精确，但不影响整体结论。

#### 问题 3：`app_683560_vs_682541_map数差异分析.md` 第 121-124 行 — "其他可能因素"中把小文件列为"中"概率 ⚠️

```
| **小文件数量差异** | 中 | Kafka 落地表持续写入小文件，3.5 小时后文件数翻倍 |
```

**问题**：同问题1，大哥已明确数据不变。"中"概率评级不应保留。

**严重度**：🟡 中 — 与正确结论矛盾。

#### 问题 4：`tez分片逻辑与解法.md` 第 8-9 行 — "瞬时可用资源"表述 ⚠️

```
availableSlots = totalResource / taskResource
                 ↑ AM注册时RM返回的队列瞬时可用资源
```

**问题**：同问题2，不是"注册时"，是"第一次心跳时"。

**严重度**：🟡 中 — 技术细节不精确。

#### 问题 5：`tez-hive-split-calculation-源码解析.md` 第 91-93 行 — DAGAppMaster 源码片段 ⚠️

```java
sendEvent(new DAGEventSchedulerUpdate(
    DAGEventSchedulerUpdate.UpdateType.DAG_COMPLETED, dag));
```

**问题**：这里的事件类型应该是 `DAG_STARTED` 或 `DAG_COMPLETED` 需要再确认。从上下文看，DAG 刚提交就触发 `DAG_COMPLETED` 的 `SchedulerUpdate` 看起来不合理——这个事件的用途是通知 scheduler DAG 状态变化，但在 `submitDAGToAppMaster` 中发 `DAG_COMPLETED` 类型可能是为了触发后续调度。不过此处的源码引用需要再核对一下，因为正常流程应该是 `DAG_INIT` → `DAG_START`。

**严重度**：🟡 低 — 非核心链路，不影响分片计算结论。

#### 问题 6：时序图 `tez-split-sequence-diagram.html` — label 位置偏移

**问题**：由于使用 JavaScript 动态计算位置，部分标签在窄屏下可能超出边界或重叠。这是 UI 展示问题，不是内容错误。

**严重度**：🟢 低

---

## 三、质疑检查员审核（逻辑自洽性 + 反向推演）

### 3.1 核心论点质疑

**论点**：availableSlots 差 2 倍 → Map 数差 2 倍

**质疑**：availableSlots 影响了三层，但并不意味着线性传递。需要验证：

| 层 | 影响机制 | 是否线性？ |
|----|----------|-----------|
| 第一层 | numSplits hint → goalSize → splitSize → 原始splits | 非严格线性。`splitSize = max(minSize, min(goalSize, blockSize))`，如果 goalSize 被 minSize 兜底，则不受 numSplits 影响 |
| 第二层 | desiredNumSplits = availableSlots * waves | 线性 |
| 第三层 | TezSplitGrouper 边界检查 | 非线性。如果两次都被 max-size 兜底，则 Map 数完全由数据量/max-size 决定，跟 availableSlots 无关 |

**质疑结论**：如果两次执行都走了"路径A（max-size 兜底）"，那 Map 数应该相同（都等于 `totalLength / maxSize`），不可能差 2 倍。所以**至少有一次没被 max-size 兜底**。

**可能的场景**：
- 682541：desiredNumSplits 小 → lengthPerGroup > maxSize → 走路径A → Map ≈ totalLength/maxSize ≈ 246
- 683560：desiredNumSplits 大到 >= 原始splits数 → 走路径C（不分组）→ Map = 原始splits数 = 487

**这解释了为什么不是"差 2 倍"而是"246 vs 487"这个具体数字**。487 是原始 splits 数直接透传（不分组），246 是被 max-size 约束后的分组结果。

**评价**：文档（`tez切片完整链路` 和 `tez分片逻辑与解法.md`）都正确描述了三种路径，且在对比框中标注了"682541 可能 A 或 D，683560 可能 C 或 D"，逻辑自洽。✅

### 3.2 时间线质疑

**质疑**：682541 的 AM 在 00:26 启动时"队列繁忙"，但 683560 在 04:11 启动时"队列空闲"——有证据吗？

**验证**：
- 682541 等了 ~7 分钟拿到 AM Container → 队列有一定排队
- 683560 等了 ~20 分钟拿到 AM Container → 队列更拥挤
- 但 headroom 和 Container 分配等待时间**不是一回事**：等 AM Container 长说明队列忙，但 headroom 反映的是"用户当前剩余可用资源总量"
- 682541 在 00:26 启动，此时 dmp 用户可能同时跑多个 app → headroom 小
- 683560 在 04:11 启动，682541 已在 00:28 结束 → dmp 用户的其他 app 也可能陆续结束 → headroom 可能大

**质疑结论**：推断合理，但**缺少 AM 端日志直接验证**。文档中也标注了"需要 AM 日志确认 totalResource 具体值"，诚实可信。✅

### 3.3 EOFException 归因质疑

**质疑**：`app_683560_vs_682541_map数差异分析.md` 将 EOFException 归因为"Kafka 正在写入文件"，但大哥说数据 7 号就产好了不会变。

**验证**：如果文件不变，EOFException 更可能是：
1. COS 对象存储读取超时/连接断开导致的不完整读
2. 文件本身在 7 号生产时就有部分损坏（尾部截断）
3. ORC 文件 footer 损坏

**评价**：EOFException 的归因在该文档中是错误的（基于"Kafka 持续写入"这个错误前提）。🔴

---

## 四、Eric 负责人终审

### 4.1 整体评价

| 维度 | 评分 | 说明 |
|------|------|------|
| **源码准确性** | ⭐⭐⭐⭐⭐ | 核心链路（HiveSplitGenerator→SplitGrouper→TezSplitGrouper→YarnTaskSchedulerService）全部从真实 .java 文件 read_file 验证，方法名、参数、行号准确 |
| **逻辑自洽性** | ⭐⭐⭐⭐ | 三层影响链路和四条路径的分析严谨，但"数据量变化"这个旧结论在差异分析文档中未清理干净 |
| **理论+实践对照** | ⭐⭐⭐⭐⭐ | `tez切片完整链路_源码+实际对照.md` 做到了 8 阶段源码+两个 App 时间戳对照，质量很高 |
| **解法实用性** | ⭐⭐⭐⭐⭐ | 从"零改动配置方案"到"源码 patch"到"社区 JIRA"分层给出，适合不同场景 |
| **已知缺陷诚实度** | ⭐⭐⭐⭐⭐ | 文档中明确标注了"需要 AM 日志确认"、"以上是推断"，没有把推断当成确定结论 |
| **旧结论清理** | ⭐⭐⭐ | `app_683560_vs_682541_map数差异分析.md` 的结论部分仍保留旧的"数据量翻倍"归因，需修正 |

### 4.2 必须修正的问题（Blocking）

| # | 文档 | 问题 | 修正方案 |
|---|------|------|----------|
| 🔴 1 | `app_683560_vs_682541_map数差异分析.md` | 第五节"结论"仍把"Kafka 持续写入数据量翻倍"作为根因 | 重写第五节，改为 availableSlots 差异 |
| 🔴 2 | 同上 | 第 121-124 行"小文件数量差异: 中" | 改为"极低"并删除"Kafka 落地表持续写入"描述 |
| 🔴 3 | 同上 | 第 182-185 行 EOFException 归因为"Kafka 正在写入" | 改为"COS 读取异常或文件本身不完整" |

### 4.3 建议修正的问题（Non-blocking）

| # | 文档 | 问题 | 建议 |
|---|------|------|------|
| 🟡 1 | `app_683560_vs_682541_map数差异分析.md` 第 115 行 | "AM 注册那一瞬间" | 改为"第一次心跳 allocate RPC" |
| 🟡 2 | `tez分片逻辑与解法.md` 第 8-9 行 | "AM注册时RM返回" | 改为"AM 第一次心跳时 RM 返回" |
| 🟡 3 | `tez-hive-split-calculation-源码解析.md` 第 91-93 行 | `DAG_COMPLETED` 事件需核实 | 建议 read_file 验证 |

### 4.4 终审结论

> **总体评价：优良，核心链路分析高质量，但有一篇旧文档的结论未跟随后续纠正更新。**
>
> 6 篇文档中，5 篇质量过关（源码解析、完整链路对照、分片逻辑解法、availableSlots 解法、资源分析报告）。
> 
> `app_683560_vs_682541_map数差异分析.md` 是**最早写的文档**，当时还没有深入到 availableSlots 源码链路，结论基于"数据量变化"的假设。后续纠正后，其他文档都更新了，但这篇遗漏了。**需要修正第五节结论 + EOFException 归因**。
>
> 修正后可推送。

---

> **审核者**：Eric (Orchestrator) + Compliance Guardian + 质疑检查员  
> **日期**：2026-04-18  
> **状态**：✅ 3 个 Blocking 问题已修正，2 个 Non-blocking 问题已修正，审核通过
