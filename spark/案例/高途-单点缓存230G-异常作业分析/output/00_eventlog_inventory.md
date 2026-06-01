# 00 — Event Log 清单核验

> 扫描目录：`C:\Users\lkl\Desktop\高途异常作业分析`  
> 扫描时间：2026-05-26T12:23:15  
> 解压目录：`C:\Users\lkl\Desktop\高途异常作业分析\_extracted`（**不**拷入 IDE workspace，遵循需求 7.5）

## 1. 4 个目标 Application 文件清单

| ApplicationID | 业务名 | 调度 | 任务ID | 告警状态 | zip 大小 | 解压后大小 | 首事件 | 尾事件 | 总行数 | 置信度 |
|---|---|---|---|---|---|---|---|---|---:|---|
| `application_1767599787371_13233986` | service_dw.dm_crm_trace_lead_full_link_data_hf | zeus | 1729816 | **FAIL** | 11.38 MB | 161.93 MB | `SparkListenerLogStart` | `SparkListenerBlockManagerRemoved` | 47,541 | **LOW** |
| `application_1767599787371_13230312` | renew_lift_train_fpc_em_zonghesuyang_spring_and_autumn_stage4 | u_strategy | 2386919 | **FAIL** | 35.14 MB | 456.12 MB | `SparkListenerLogStart` | `SparkListenerStageCompleted` | 195,903 | **LOW** |
| `application_1767599787371_13232163` | service_dw.dm_crm_trace_lead_full_link_data_hf | zeus | 1672415 | **FAIL** | - | - | `-` | `-` | 0 | **MISSING** |
| `application_1767599787371_13236774` | (对照组：打平到3从 成功) | - | - | **SUCCESS_CONTROL** | 11.55 MB | 163.50 MB | `SparkListenerLogStart` | `org.apache.kyuubi.engine.spark.events.SessionEvent` | 47,444 | **MEDIUM** |

## 2. 完整性结论（每个 App 一条）

- 🔴 **`application_1767599787371_13233986`** — 置信度 **LOW**：文件名为 .inprogress 且缺少 SparkListenerApplicationEnd → 作业异常终止
- 🔴 **`application_1767599787371_13230312`** — 置信度 **LOW**：文件名为 .inprogress 且缺少 SparkListenerApplicationEnd → 作业异常终止
- ⚫ **`application_1767599787371_13232163`** — 置信度 **MISSING**：桌面目录下未找到该 ApplicationID 对应的任何 zip / 解压文件 → 证据完全缺失
- 🟡 **`application_1767599787371_13236774`** — 置信度 **MEDIUM**：未知组合：is_inprogress=False, last_event=org.apache.kyuubi.engine.spark.events.SessionEvent

## 3. 关键观察（基于首尾事件嗅探）

> 这一节是后续根因分析的**第一组证据**，请在主报告中显式引用。

1. **3 个失败作业中有 2 个文件停留在 `.inprogress` 状态**——这是 Spark History Server 没收到 `ApplicationEnd` 事件的直接物证，与告警"自动处理失败"现象一致。
2. **缺失 1 个 Application 的 Event Log**：`application_1767599787371_13232163`。该作业的根因分析将仅基于告警原文与同业务作业（`dm_crm_trace_lead_full_link_data_hf`）的横向对比，**结论为低置信度推断**。
3. **对照组 `application_1767599787371_13236774` 的尾事件为 `SparkListenerApplicationEnd`**——作业正常结束，证据链完整，可作为成功打散的基准。

## 4. 给后续步骤的输入

| 用途 | 文件路径 |
|---|---|
| 解析输入（13233986） | `C:\Users\lkl\Desktop\高途异常作业分析\_extracted\application_1767599787371_13233986_1.inprogress` |
| 解析输入（13230312） | `C:\Users\lkl\Desktop\高途异常作业分析\_extracted\application_1767599787371_13230312_1.inprogress` |
| 解析输入（13236774） | `C:\Users\lkl\Desktop\高途异常作业分析\_extracted\application_1767599787371_13236774_1` |
