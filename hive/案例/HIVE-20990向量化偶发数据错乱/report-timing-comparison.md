# 新希望 ADS_SALES_CONTRI_WITHOUT_SEND · 三份日志耗时对比报告

> 作者：eric
> 时间：2026-05-06
> 范围：**仅限耗时分析**，不涉及数据正确性问题
> 数据来源：三份 Hive on Tez 执行日志的 DAG_DONE 事件（VERTICES: NN/NN 100% ELAPSED TIME 首次打印）

---

## 一、任务背景

`ADS_SALES_CONTRI_WITHOUT_SEND` 是新希望财务管报流水线中的核心任务，每日 04:59 调度执行，包含 7 段连续 DAG：

```
four (16 顶点)
  └→ four0 (9 顶点)
       └→ four1 (7 或 10 顶点)  ← 受 hive.groupby.skewindata 参数影响
            └→ four2 (8 顶点)
                 └→ four3 stage1 (1 顶点) + stage2 (8 顶点)
                      └→ insert overwrite ads (4 顶点)
```

本次分析围绕三份日志：

| 日志文件 | 启动时间 | 触发方式 | 参数特征 |
|---|---|---|---|
| `all-数据异常的日志.log` | 2026-05-05 04:59:44 | 调度自动 | skew 全部开启 |
| `all-正常的.log` | 2026-05-05 13:54:26 | 手动重跑 | skew 全部开启 |
| `all-去掉skew优化的参数.log` | 2026-05-06 10:50 左右 | 手动测试 | four1 前的 skew 参数被注释 |

---

## 二、三份日志每段 SQL 耗时逐项汇总

### 2.1 📄 `all-数据异常的日志.log`（凌晨 04:59 调度）

| 行号 | 阶段 / SQL | DAG 顶点数 | 耗时 |
|---|---|---|---|
| 31433 | `create table tmp_sales_contri_four as …` | 16 | **3725.68 s**（62 min 06 s）|
| 35901 | `create table tmp_sales_contri_four0 as …` | 9 | **446.57 s**（7 min 27 s）|
| 41853 | `create table tmp_sales_contri_four1 as …` | 10 | **751.50 s**（12 min 32 s）|
| 43968 | `create table tmp_sales_contri_four2 as …` | 8 | **120.43 s** |
| 45036 | `create table tmp_sales_contri_four3 as …`（stage1）| 1 | **13.69 s** |
| 46140 | `create table tmp_sales_contri_four3 as …`（stage2）| 8 | **145.93 s** |
| 47888 | `insert overwrite ads_sales_contri_without_send` | 4 | **78.01 s** |
| | **DAG 累计耗时** | | **≈ 5281.81 s（88 min 02 s）** |

### 2.2 📄 `all-正常的.log`（下午 13:54 手动重跑）

| 行号 | 阶段 / SQL | DAG 顶点数 | 耗时 |
|---|---|---|---|
| 17087 | `create table tmp_sales_contri_four as …` | 16 | **1650.31 s**（27 min 30 s）|
| 20353 | `create table tmp_sales_contri_four0 as …` | 9 | **254.21 s**（4 min 14 s）|
| 22553 | `create table tmp_sales_contri_four1 as …` | 10 | **110.62 s**（1 min 51 s）|
| 24451 | `create table tmp_sales_contri_four2 as …` | 8 | **79.29 s** |
| 25105 | `create table tmp_sales_contri_four3 as …`（stage1）| 1 | **3.00 s** |
| 26256 | `create table tmp_sales_contri_four3 as …`（stage2）| 8 | **73.00 s** |
| 27802 | `insert overwrite ads_sales_contri_without_send` | 4 | **47.21 s** |
| | **DAG 累计耗时** | | **≈ 2217.64 s（36 min 58 s）** |

### 2.3 📄 `all-去掉skew优化的参数.log`（关闭 skew 参数版）

| 行号 | 阶段 / SQL | DAG 顶点数 | 耗时 |
|---|---|---|---|
| 17263 | `create table tmp_sales_contri_four as …` | 16 | **1680.38 s**（28 min 00 s）|
| 20582 | `create table tmp_sales_contri_four0 as …` | 9 | **258.60 s**（4 min 19 s）|
| 22426 | `create table tmp_sales_contri_four1 as …` | **7** | **85.31 s**（1 min 25 s）|
| 24297 | `create table tmp_sales_contri_four2 as …` | 8 | **73.14 s** |
| 24949 | `create table tmp_sales_contri_four3 as …`（stage1）| 1 | **3.16 s** |
| 26079 | `create table tmp_sales_contri_four3 as …`（stage2）| 8 | **72.48 s** |
| 27647 | `insert overwrite ads_sales_contri_without_send` | 4 | **50.93 s** |
| | **DAG 累计耗时** | | **≈ 2224.00 s（37 min 04 s）** |

---

## 三、三份日志横向对照

| 阶段 | 📄 `all-数据异常的日志.log` | 📄 `all-正常的.log` | 📄 `all-去掉skew优化的参数.log` |
|---|---|---|---|
| four（CTAS） | v=16 / **3725.68 s** | v=16 / **1650.31 s** | v=16 / **1680.38 s** |
| four0（CTAS） | v=09 / **446.57 s** | v=09 / **254.21 s** | v=09 / **258.60 s** |
| **four1（CTAS）** | **v=10 / 751.50 s** | **v=10 / 110.62 s** | **v=07 / 85.31 s** |
| four2（CTAS） | v=08 / **120.43 s** | v=08 / **79.29 s** | v=08 / **73.14 s** |
| four3 stage1 | v=01 / 13.69 s | v=01 / 3.00 s | v=01 / 3.16 s |
| four3 stage2 | v=08 / **145.93 s** | v=08 / **73.00 s** | v=08 / **72.48 s** |
| insert ads | v=04 / **78.01 s** | v=04 / **47.21 s** | v=04 / **50.93 s** |
| **DAG 总和** | **5281.81 s** | **2217.64 s** | **2224.00 s** |
| **总耗时倍数** | **1.00× 基准** | **0.42×** | **0.42×** |

---

## 四、各阶段相对基线的慢化倍数

以**「正常那次」**作为基线（1.00×），分别看「异常那次」和「关闭 skew 那次」的慢化倍数：

| 阶段 | 异常 / 正常 | 关闭skew / 正常 |
|---|---|---|
| four | 2.26× | 1.02× |
| four0 | 1.76× | 1.02× |
| **four1** | **🔥 6.79×** | **0.77×**（反而更快）|
| four2 | 1.52× | 0.92× |
| four3 stage1 | 4.56× | 1.05× |
| four3 stage2 | 2.00× | 0.99× |
| insert ads | 1.65× | 1.08× |
| **总耗时** | **2.38×** | **1.00×** |

---

## 五、只看数据能看到的五个事实

### 事实 1 · 正常 vs 关闭 skew 的整体基线几乎一致
- 正常：2217.64 s
- 关闭 skew：2224.00 s
- 差异 < 0.3%，说明两次跑时集群的资源状况、数据量是几乎一致的，可作为干净的基线对照

### 事实 2 · 异常那次整体慢化 2.38 倍，是普遍性的
除 four1 外，其他阶段异常那次都比基线慢 1.5~2.3 倍。这是**系统级的背景慢化**（凌晨时段集群负载、YARN 队列竞争、HDFS IO 等因素），与单条 SQL 无关。

### 事实 3 · four1 阶段的慢化异常突出
- 异常 / 正常 = **6.79×**（其他阶段 1.5~2.3×）
- 异常 / 关闭 skew = **8.81×**
- 即便扣除集群基线慢化（约 2×），four1 仍多出约 3~4 倍的额外延迟

### 事实 4 · four1 是唯一一个拓扑受 skew 参数影响的阶段
- 开 skew（异常 + 正常）：**10 顶点**
- 关 skew（关闭 skew）：**7 顶点**
- 其他 6 个阶段在三份日志里顶点数完全一致（16 / 9 / 8 / 1 / 8 / 4）
- 这是因为 `set hive.groupby.skewindata=true` 和 `set hive.optimize.skewjoin.compiletime=true` 仅作用在 four1 的 CTAS 上（set=true 在 four1 前、set=false 在 four1 后）

### 事实 5 · skew 参数在 four1 上并未带来性能收益
- 正常（开 skew）：110.62 s
- 关闭 skew：85.31 s
- 关闭反而快 23%
- 额外 3 个顶点带来的 shuffle 开销并没有被 skew 优化收益抵消

---

## 六、耗时层面给出的性能优化建议

> **以下建议仅从耗时角度出发，与其他问题无关。**

### 建议 1：four 阶段是流水线最大瓶颈，应优先优化
- 正常情况下 four 占总耗时的 **74.4%**（1650/2217）
- 异常情况下 four 占 **70.5%**（3725/5281）
- 可从执行计划、数据量、reducer 数等方面分析 four 这条 SQL，这里是性能优化的最大抓手

### 建议 2：four1 上的 skew 参数可以评估移除
- 开 skew：110.62 s，10 顶点
- 关 skew：85.31 s，7 顶点
- 从耗时角度无收益，反而有 23% 的额外开销
- 若该 SQL 的 GROUP BY 业务上没有真实热点 key，这两个参数属于**负优化**

### 建议 3：异常那次的集群级慢化需单独排查
- 凌晨 04:59 整体慢化 2.38×，除 four1 外其他阶段也普遍慢 1.5~2.3 倍
- 排查方向：
  - 该时段 YARN 队列有没有被其他大任务占用
  - HDFS/COS 的 IO 有没有被写满
  - 凌晨其他并发调度任务的资源画像
- 属于集群调度层面问题，不是这条 SQL 的问题

### 建议 4：four1 异常那次额外的 ~550s 延迟需单独分析
- 异常 four1 = 751.50 s，按基线推算应为 ~200 s（正常的 2 倍）
- 多出约 550 s 无法用集群级慢化解释
- 这部分延迟的成因应做独立的 DAG 级深挖（与本份耗时对比报告分开处理）

---

## 七、附录 · 数据提取方法

为保证耗时数据可复现，本报告使用以下规则从日志中提取：

1. **SQL 阶段识别**：按 `INFO execute <SQL 正文>` 事件定位（该事件在 Hive 执行该 SQL 结束后打印）
2. **DAG 耗时提取**：按 `VERTICES: NN/NN [==>>] 100% ELAPSED TIME: T s` 事件定位，取每个 DAG 完成时**首次打印**的 ELAPSED TIME 值作为该 DAG 的实际耗时
3. **DAG 与 SQL 对应关系**：DAG_DONE 事件永远出现在对应 SQL 的 `INFO execute` 之前，按行号顺序即可一一对齐
4. **DAG 顶点数**：取 `VERTICES: NN/NN` 中的 NN 值
5. **所有原始行号已在第二节列出**，可直接回到日志原文核对

---

*— eric · 三文件耗时对比报告 · 仅限性能分析*
