# 4月27日 COS 上传带宽治理案例

## 背景
- **集群**：阿帕大数据集群（EMR + COS chdfs 存储）
- **现象**：4/27 凌晨 ~ 晚间多个时段 COS 上传带宽打爆 8GB/min 阈值（峰值 13.4GB/min）
- **目标**：从 COS 日志 + HS2 日志 + 带宽 CSV 反查罪魁任务（appId/queryId/SQL），制定错峰调度方案

## 数据来源
| 文件 | 来源 | 用途 |
|---|---|---|
| 4月27日_上传带宽（已换算）-详细数据.csv | 腾讯云监控（出口带宽） | 真实带宽时间序列（GB/min） |
| 4月27/*.csv（4 个 ~803MB） | COS 日志投递 | 应用层 PUT 字节级日志 |
| 6f16714a/4a38dde9 hiveserver2.tar.gz | EMR HS2 日志 | 反查 staging-id → queryId/SQL/appId |

## 产物清单

| 产物 | 用途 |
|---|---|
| `4月27日_带宽趋势图.html` | 全天分钟级带宽折线，红点标注 12 个超 8GB 时刻 |
| `4月27日_带宽24小时分图.html` | 每小时一张子图，红框标注超阈值小时 |
| `4月27日_任务流量带宽叠加图.html` | COS 任务流量堆叠 + CSV 带宽折线，验证两者吻合度 |
| `4月27日_COS日志按小时任务流量.html` | **核心产物** — 24 小时分图 + 40 个着色表清单 + queryId/appId/SQL 关联 |
| `4月27日_COS分钟级流量.csv` | 每分钟 COS bytessent 累计字节（GB） |
| `4月27日_带宽超8G任务清单.md` | 8 个罪魁任务时间线 + 错峰调度方案 |
| `4月27日_带宽HS2关联完整报告.md` | HS2 日志关联分析报告（双实例对比） |

## 关键结论

### 12 个超 8GB/min 时刻 → 8 个罪魁任务

| CSV引爆时刻 | 带宽 | 罪魁表 | appId |
|---|---|---|---|
| 01:10 | 13.42 GB | dwd_bd_order_cashier_bike_pay_df | application_1762781849738_771952 |
| 01:12 | 9.17 GB | 同上（持续） | 同上 |
| 01:21 | 10.02 GB | dwd_bd_order_extend_binlog_new_da | application_1762781849738_771655 |
| 01:29 | 8.10 GB | dwd_bd_order_wallet_new_df | application_1762781849738_772061 |
| 01:36 | 10.97 GB | 同上（峰值） | 同上 |
| 01:46 | 10.07 GB | dwd_nf_nf_user_action_nm_da | application_1762781849738_772228 |
| 03:55 | 11.89 GB | dwd_bd_atm_user_coupon_df | application_1762781849738_772507 |
| 04:00 | 8.87 GB | 同上（持续） | 同上 |
| 10:27 | 9.85 GB | dwd_bd_order_cashier_pay_df | application_1762781849738_774629 |
| 10:34 | 8.20 GB | dwd_bd_order_cashier_payment_order_his | application_1762781849738_774649 |
| 19:57 | 8.22 GB | dwd_bd_atm_user_coupon_update_df | application_1762781849738_775646 |
| 20:10 | 9.25 GB | 同上（峰值） | 同上 |

### 4 个波峰

| 波峰 | 时段 | 类型 | 治理方向 |
|---|---|---|---|
| ① | 01:10~01:46 | **多任务并发**（4 个任务叠加） | **错峰调度**，拉开 15-20 分钟间距 |
| ② | 03:55~04:00 | 单任务（coupon_df，UNION ALL + window） | **优化 SQL**：MERGE INTO 增量替代全量重写 |
| ③ | 10:27~10:34 | 单任务（cashier_pay_df + payment_order_his） | **降 reducer 并发**，开 ZSTD 压缩 |
| ④ | 19:57~20:10 | 单任务（coupon_update_df） | 同 ② |

## 方法论沉淀

### 时间错位问题（核心难点）
- **COS 日志 eventtime** = 请求完成时间戳（应用层）
- **CSV "上传带宽"** = 网卡分钟槽聚合值（基础设施层）
- 同一上传请求横跨分钟边界时，两者天然错位 0~2 分钟
- **解决**：识别罪魁时使用 ±2 分钟容差窗口取 CSV 最大值，作为"CSV 引爆时刻"，与 HS2 query 提交时间正向匹配

### staging-id 关联链路
```
COS 日志 reqpath
  → /user/hive/warehouse/{db}.db/{table}/.hive-staging_hive_YYYY-MM-DD_HH-MM-SS_NNN_<staging-id>/
  → grep staging-id 在 HS2 inst1 + inst2 日志（注意双实例避免覆盖）
  → 提取 queryId（hadoop_YYYYMMDDHHMMSS_<uuid>）
  → 提取 appId（application_xxx_yyy）
  → 提取 SQL（INSERT 语句）
```

### 着色规则避坑
- ❌ 错误：仅展示**全天累计 Top5** 表（漏掉短时尖峰任务，如 message_subscribe_df）
- ✅ 正确：**全天累计 Top10 ∪ 单分钟峰值≥1GB 的表**（最多 40 个）

## 相关文件路径
- 工作区：`C:\Users\lkl\CodeBuddy\20260428102039\`
- 原始数据：`C:\Users\lkl\Desktop\阿帕大任务流量\`
- HS2 日志解压：`C:\Users\lkl\Desktop\hs2_apr27\hs2_logs\inst1\`、`inst2\`
- 分析脚本：`C:\Users\lkl\Desktop\hs2_apr27\gen_hourly_task.py`（核心生成脚本）

---
*归档时间：2026-05-13 · eric*
