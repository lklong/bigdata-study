# S04: Hive 3.x 高危结果正确性 Bug 索引

> 从 310+ 社区 JIRA 中筛选 Hive 3.x 相关 Critical/Blocker 级条目
> 筛选标准：fixVersion 含 3.x 或影响 3.x 且已修复 + 优先级 Critical 或 Blocker
> 排障详情见 [S04-Part2 排障实战手册](./S04-Part2-HS2结果不对排障实战手册.md)

---

## 一、数据多了（Blocker/Critical）

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-16832 | 多 INSERT 事务表产生重复 ROW__ID | ≤3.0 | 3.0.0 | 3.0 已含 |

## 二、数据少了（Blocker/Critical）

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-12465 | OUTER JOIN 合并丢条件导致结果丢行 | 1.x-2.x | 2.0.0 | 3.x 已含 |
| HIVE-8394 | Pig MultiQuery 可能导致数据丢失 | ≤0.14 | 0.14.0 | 3.x 已含 |
| HIVE-8498 | 向量化 INSERT 丢行 | ≤0.14 | 0.14.0 | 3.x 已含 |
| HIVE-10062 | UNION + Multi-GB + Multi-insert 丢数据 (Tez) | ≤1.2 | 1.2.0 | 3.x 已含 |
| HIVE-18490 | EXISTS + NOT EXISTS + 非等值谓词结果错 | 3.x | 3.0.0, 3.1.0 | 3.0/3.1 已含 |
| HIVE-21460 | LOAD DATA 到 ACID 表后 SELECT 结果错 | 3.1.x | 3.1.1 | **3.1.0 需回合** |
| HIVE-23703 | Major compaction + 多 FileSinkOperator 丢数据 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-28700 | MRCompactor major compaction 丢数据 | ≤4.1 | 4.1.0 | **3.x 需回合** |

## 三、数据值错了（Blocker/Critical，Hive 3.x 相关）

### 向量化系列

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-19498 | 向量化 CAST 结果错误 | ≤3.1 | 3.1.0 | 3.0 需回合 |
| HIVE-19564 | 向量化算术 NULL 处理错误 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-20174 | 向量化 GROUP BY 聚合 NULL 错误 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-20207 | 向量化 Filter/Compare NULL 错误 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-20245 | 向量化 BETWEEN/IN NULL 错误 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-20294 | 向量化 COALESCE/ELT NULL 错误 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-20315 | 向量化更多 NULL/Wrong 修复 + 去冗余 CAST | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-19565 | 向量化字符串函数 NULL 错误 | ≤3.1 | 3.1.0 | 3.0 需回合 |
| HIVE-19384 | 向量化 IfExprTimestamp NULL 处理错误 | ≤3.0 | 3.0.0 | 3.0 已含 |
| HIVE-18622 | 向量化 IF/Compare NULL 处理错误 | ≤3.0 | 3.0.0 | 3.0 已含 |
| HIVE-19275 | 向量化开启后 defer Wrong Results | 3.0-3.1 | 3.0.0, 3.1.0 | 3.0/3.1 已含 |
| HIVE-11172 | 向量化 WHERE 无 GROUP BY 聚合错误 | ≤1.2 | 1.2.2, 2.0.0 | 3.x 已含 |
| HIVE-15588 | 向量化 scratch column 复用错误 | ≤2.2 | 2.2.0 | 3.x 已含 |
| HIVE-16065 | 向量化 Key/Value 信息错误 | ≤2.2 | 2.2.0 | 3.x 已含 |
| HIVE-20004 | ConvertDecimal64ToDecimal 精度丢失 | 3.x | 3.2.0, 4.0.0-alpha-1 | **3.1.x 需回合** |
| HIVE-24245 | 向量化 PTF + count distinct 结果错 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |

### JOIN 系列

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-14326 | OUTER JOIN 无条件合并产生错误结果 | ≤2.1 | 2.1.1, 2.2.0 | 3.x 已含 |
| HIVE-15327 | OUTER JOIN + joinEmitInterval 结果错 | ≤2.2 | 2.2.0 | 3.x 已含 |
| HIVE-15493 | Tez LEFT OUTER Map Join 结果错 | ≤2.2 | 2.2.0 | 3.x 已含 |
| HIVE-11605 | Tez bucket map join 结果错 | ≤1.0 | 1.0.2, 2.0.0 | 3.x 已含 |
| HIVE-27069 | Bucket map join 结果不正确 | 3.x+ | 未指定 | **未修复，需关注** |
| HIVE-8298 | n-way join ON 条件顺序不同导致结果错 | ≤0.14 | 0.14.0 | 3.x 已含 |

### 数据类型/精度

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-13948 | Timestamp 时区处理错误导致日期偏移 | ≤1.2 | 1.2.2, 2.0.2 | 3.x 已含 |
| HIVE-13111 | timestamp/interval_day_time 结果错 | ≤1.3 | 1.3.0, 2.0.1 | 3.x 已含 |
| HIVE-12315 | 向量化 double 计算结果错 | ≤1.3 | 1.3.0, 2.0.0 | 3.x 已含 |
| HIVE-15338 | 非向量化 DATEDIFF 标量结果错 | ≤2.3 | 2.3.0 | 3.x 已含 |

### CBO / 子查询

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-26209 | CBO 多 IN 条件结果错误 | 3.x+ | 未指定 | **未修复，需关注** |
| HIVE-27801 | EXISTS 子查询重写产生错误计划 | ≤4.0 | 4.0.0 | **3.x 需回合** |
| HIVE-14652 | NOT IN 分区列结果不正确 | ≤2.1 | 2.1.1 | 3.x 已含 |
| HIVE-27324 | NOT IN + NULL 值结果不正确 | ≤4.0 | 4.0.0 | **3.x 需回合** |

### UNION / GROUP BY

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-11266 | 外部表 count(*) 基于统计信息返回错误 | ≤3.0 | 3.0.0 | 3.0 已含 |
| HIVE-21387 | UNION + GROUP BY PK 结果错 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-19690 | multi-insert + 多 GBY + distinct 结果错 | ≤3.1 | 3.1.0 | 3.0 需回合 |

### ACID / 存储

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-22945 | UPDATE 损坏其他列数据 | 3.x+ | 未指定 | **未修复，需关注** |
| HIVE-24840 | MV 增量刷新 + compaction 结果错 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-22769 | 压缩文本 split 生成返回错误结果 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |
| HIVE-16869 | Parquet 不存在列 PPD 结果错 | ≤3.0 | 3.0.0 | 3.0 已含 |

## 四、数据列错了（Blocker/Critical）

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-8162 | 动态排序优化传播了多余列 | ≤0.14 | 0.14.0 | 3.x 已含 |
| HIVE-14564 | 列剪裁生成乱序列导致 AIOOBE | ≤3.0 | 3.0.0 | 3.0 已含 |
| HIVE-15588 | 向量化 scratch column 释放复用错误 | ≤2.2 | 2.2.0 | 3.x 已含 |
| HIVE-16869 | Parquet 不存在列谓词下推到错误列 | ≤3.0 | 3.0.0 | 3.0 已含 |
| HIVE-23768 | MetaStore 缓存错误剥离分区列统计 | ≤4.0 | 4.0.0-alpha-1 | **3.x 需回合** |

## 五、数据集为空（Blocker/Critical）

| JIRA | 一句话描述 | 影响版本 | 修复版本 | 需回合？ |
|------|-----------|---------|---------|---------|
| HIVE-11312 | ORC CHAR 类型 WHERE 不返回行 | ≤2.0 | 2.0.0 | 3.x 已含 |
| HIVE-14214 | ORC Schema Evolution + PPD 不兼容 | ≤2.1 | 2.1.1, 2.2.0 | 3.x 已含 |
| HIVE-8103 | FetchOperator 不读 ACID 表 | ≤0.14 | 0.14.0 | 3.x 已含 |

---

## 六、Hive 3.x 需回合的高危 Bug 汇总

以下是**修复版本在 4.x 但影响 3.x 的 Critical/Blocker 级 Bug**，如果你的 Hive 3.x 没有回合这些，建议重点关注：

| 优先级 | JIRA | 核心风险 | 临时规避 |
|--------|------|---------|---------|
| **Blocker** | HIVE-28700 | Compaction 丢数据 | 手动验证 compaction 前后行数 |
| **Critical** | HIVE-19564 | 向量化算术 NULL 错误 | 关向量化 |
| **Critical** | HIVE-20174 | 向量化聚合 NULL 错误 | 关向量化 |
| **Critical** | HIVE-20207 | 向量化 Filter NULL 错误 | 关向量化 |
| **Critical** | HIVE-20245 | 向量化 BETWEEN/IN NULL 错误 | 关向量化 |
| **Critical** | HIVE-20294 | 向量化 COALESCE NULL 错误 | 关向量化 |
| **Critical** | HIVE-20315 | 向量化更多 NULL 修复 | 关向量化 |
| **Critical** | HIVE-20004 | Decimal64 精度丢失 | 关向量化 |
| **Critical** | HIVE-24245 | PTF + count distinct 错 | 关向量化 |
| **Critical** | HIVE-26209 | CBO 多 IN 条件错（未修复） | 关 CBO |
| **Critical** | HIVE-27801 | EXISTS 子查询重写错 | 关 CBO |
| **Critical** | HIVE-22945 | UPDATE 损坏列（未修复） | 用 INSERT OVERWRITE |
| **Critical** | HIVE-24840 | MV 增量刷新错 | 全量刷新 MV |
| **Critical** | HIVE-22769 | 压缩文本 split 结果错 | 用 ORC 替代文本格式 |
| **Critical** | HIVE-23703 | Compaction 丢数据 | 验证 compaction 前后 |
| **Critical** | HIVE-23768 | MetaStore 缓存列统计错 | 重启 HMS 缓存 |
| Major | HIVE-27324 | NOT IN + NULL 结果错 | 改写 NOT EXISTS |
| Major | HIVE-21387 | UNION + GROUP BY PK 错 | 去掉 PK 优化 |

---

> 完整排障流程见 [S04-Part2 排障实战手册](./S04-Part2-HS2结果不对排障实战手册.md)
> 源码风险点见 [S04-Part1 源码分析](./S04-Part1-HS2结果错误源码分析.md)
