# S04: HiveServer2 查询结果不对 — 排障实战手册

> 适用版本：Hive 3.x 社区版（兼顾 Tez / MR / Spark 执行引擎）
> 更新时间：2026-04-04
> 关联文档：[S04-Part1 源码风险点](./S04-Part1-HS2结果错误源码分析.md) | [S04-Part3 Hive3.x 高危 Bug 索引](./S04-Part3-Hive3x高危结果Bug索引.md)

---

## 一、排障决策树

遇到"查询结果不对"，按以下流程逐步定位。**核心思路：先用开关对比法锁定子系统，再进入具体场景。**

```
查询结果不对？
│
├─ Step 0: 确认"不对"的具体现象
│   ├─ 行数多了？ ──────────→ 跳转 §1.1
│   ├─ 行数少了？ ──────────→ 跳转 §1.2
│   ├─ 值不对（精度/NULL/聚合）？ → 跳转 §1.3
│   ├─ 列错位/列数据串了？ ──→ 跳转 §1.4
│   └─ 结果为空（0行）？ ───→ 跳转 §1.5
│
├─ Step 1: 开关对比法（快速二分）
│   │
│   ├─ 1a. 关闭向量化对比
│   │   SET hive.vectorized.execution.enabled=false;
│   │   SET hive.vectorized.execution.reduce.enabled=false;
│   │   → 结果正确了？ ──→ 向量化 Bug，见 §1.3.1
│   │   → 还是不对？ ──→ 继续 1b
│   │
│   ├─ 1b. 关闭 CBO 对比
│   │   SET hive.cbo.enable=false;
│   │   → 结果正确了？ ──→ CBO 优化器 Bug，见 §1.3.4
│   │   → 还是不对？ ──→ 继续 1c
│   │
│   ├─ 1c. 切换执行引擎对比
│   │   SET hive.execution.engine=mr;  -- 或从 mr 切到 tez
│   │   → 某个引擎结果正确？ ──→ 引擎特定 Bug，见 §1.3.2 / §1.3.6
│   │   → 都不对？ ──→ 继续 1d
│   │
│   ├─ 1d. 检查 JOIN 相关
│   │   SET hive.auto.convert.join=false;  -- 关闭 Map Join
│   │   SET hive.join.emit.interval=0;     -- 关闭 emit 截断
│   │   → 结果正确了？ ──→ JOIN 优化 Bug，见 §1.1.1 / §1.2.1 / §1.3.2
│   │   → 还是不对？ ──→ 继续 1e
│   │
│   └─ 1e. 检查 PPD / 索引过滤
│       SET hive.optimize.ppd=false;
│       SET hive.optimize.index.filter=false;
│       → 结果正确了？ ──→ PPD Bug，见 §1.3.7
│       → 还是不对？ ──→ 可能是数据本身有问题，检查源数据 / 文件格式
```

### 1.1 数据多了（多行/重复行）

```
数据多了？
│
├─ 有 JOIN 吗？
│   ├─ 有 → 检查 JOIN 类型是否写对（INNER vs LEFT vs CROSS）
│   │   ├─ OUTER JOIN 场景 → 可能 OUTER JOIN 合并 Bug (HIVE-14326)
│   │   │   → SET hive.merge.nway.joins=false; 对比
│   │   └─ skew join 场景 → 可能 skew join 重复 Bug (HIVE-8518)
│   │       → SET hive.optimize.skewjoin=false; 对比
│   └─ 没有 JOIN →
│
├─ 是 ACID 事务表吗？
│   ├─ 是 → 检查并发写入是否产生了重复 ROW__ID (HIVE-16832)
│   │   → SELECT row__id, count(*) FROM t GROUP BY row__id HAVING count(*) > 1;
│   └─ 不是 →
│
├─ 是 RCFile 格式吗？
│   └─ 是 → 检查 split 边界重复读 (HIVE-1088)
│       → 换 ORC 格式验证
│
└─ 以上都不是 → 检查 SQL 逻辑本身（WHERE 条件是否漏了去重）
```

### 1.2 数据少了（丢行/缺行）

```
数据少了？
│
├─ 有 NOT IN / NOT EXISTS 吗？
│   ├─ NOT IN 子查询含 NULL →  Anti Join 转换 Bug (HIVE-26135, HIVE-29175)
│   │   → 改写为 NOT EXISTS 验证
│   │   → 或 SET hive.optimize.semijoin.conversion=false;
│   └─ 没有 →
│
├─ 有 OUTER JOIN 吗？
│   ├─ 多个 OUTER JOIN 合并 → HIVE-12465, HIVE-14326
│   │   → SET hive.merge.nway.joins=false; 对比
│   ├─ LEFT SEMI JOIN + emit interval → HIVE-4781
│   │   → SET hive.join.emit.interval=0; 对比
│   └─ 没有 →
│
├─ 有 UNION ALL 吗？
│   ├─ UNION ALL + Multi-insert → HIVE-10062
│   │   → 拆成单独的 INSERT 语句对比
│   ├─ UNION ALL + UDTF → HIVE-21915
│   │   → 单独执行每个 UNION 分支对比
│   └─ 没有 →
│
├─ 是 ACID 表吗？
│   ├─ 刚做了 compaction？ → HIVE-23703, HIVE-28700
│   │   → SHOW COMPACTIONS; 检查最近的 compaction 状态
│   ├─ LOAD DATA 后查询 → HIVE-21460
│   │   → INSERT ... SELECT 替代 LOAD DATA
│   └─ streaming 写入场景 → HIVE-24481
│
├─ LATERAL VIEW + WHERE → HIVE-29084
│   → 把 WHERE 条件移到外层 SELECT 对比
│
└─ 以上都不是 → 检查源数据文件是否完整（hdfs fsck）
```

### 1.3 数据值错了（值不对）

```
值不对？
│
├─ 1.3.1 向量化相关（关闭向量化后正确）
│   ├─ NULL 值变成了非 NULL？ → HIVE-18622, HIVE-19384, HIVE-19564
│   │   → 尤其关注 Boolean NULL 变 true (ColumnBuffer 源码缺陷)
│   ├─ IF / CASE WHEN 结果错？ → HIVE-17682, HIVE-28301
│   ├─ 聚合函数（COUNT/SUM/AVG）错？ → HIVE-11172, HIVE-20174
│   │   → 尤其 WHERE 无 GROUP BY 的聚合
│   ├─ CAST 转换结果错？ → HIVE-19498, HIVE-11839
│   ├─ BETWEEN / IN 条件结果错？ → HIVE-20245
│   ├─ 字符串函数结果错？ → HIVE-19565, HIVE-5490
│   ├─ 日期函数结果错？ → HIVE-19493, HIVE-17892
│   ├─ PTF 窗口函数 + DISTINCT 结果错？ → HIVE-24245
│   └─ COALESCE / ELT 结果错？ → HIVE-20294, HIVE-18800
│
├─ 1.3.2 JOIN 值错误
│   ├─ Map Join ON 条件带过滤 → HIVE-2101
│   ├─ n-way join ON 条件顺序不同 → HIVE-8298, HIVE-9146
│   ├─ Outer Join + emit interval → HIVE-15327, HIVE-4689
│   │   → SET hive.join.emit.interval=0; 验证
│   ├─ Bucket Map Join → HIVE-11605, HIVE-27069
│   │   → SET hive.auto.convert.join=false; 验证
│   └─ SMB Join 不同 bucket 数 → HIVE-16965, HIVE-27357
│
├─ 1.3.3 数据类型/精度问题
│   ├─ Decimal 精度丢失 → HIVE-20004 (ConvertDecimal64ToDecimal)
│   ├─ Float/Double 精度偏差 → ColumnBuffer 源码缺陷 (toString 中转)
│   ├─ Timestamp 时区偏移 → HIVE-13948, HIVE-25268, HIVE-25299
│   │   → SET hive.local.time.zone=UTC; 对比
│   └─ CHAR 类型空格填充影响比较 → HIVE-11839
│
├─ 1.3.4 CBO 优化器（关闭 CBO 后正确）
│   ├─ 相关子查询聚合 → HIVE-16229
│   ├─ 多个 IN 条件组合 → HIVE-26209
│   ├─ EXISTS 子查询重写 → HIVE-27801
│   ├─ 非确定性函数 PPD → HIVE-19889
│   └─ OFFSET 无 ORDER BY → HIVE-27480
│
├─ 1.3.5 NOT IN / 子查询
│   ├─ NOT IN 子查询含 NULL → HIVE-27324
│   ├─ NOT IN 有类型强转 → HIVE-24817, HIVE-28000
│   ├─ EXISTS + LIMIT → HIVE-24199
│   └─ 子查询 + 物化视图 → HIVE-26737
│
├─ 1.3.6 UNION / GROUP BY
│   ├─ UNION ALL 类型不一致 → HIVE-14251
│   ├─ GROUP BY + skewindata=true + count distinct → HIVE-10971
│   ├─ multi-insert + 多 GBY + distinct → HIVE-19690
│   └─ count(*) 基于统计信息 → HIVE-11266
│       → SET hive.compute.query.using.stats=false; 对比
│
├─ 1.3.7 ORC/Parquet PPD / 存储格式
│   ├─ 同表引用两次 + index filter → HIVE-15680
│   │   → SET hive.optimize.index.filter=false; 对比
│   ├─ Parquet 不存在列的 PPD → HIVE-16869
│   ├─ ORC Timestamp PPD → HIVE-21862
│   └─ 压缩文本文件 split 边界 → HIVE-22769
│
├─ 1.3.8 ACID / 物化视图
│   ├─ UPDATE 导致其他列数据错乱 → HIVE-22945
│   ├─ MV 增量刷新 + compaction → HIVE-24840
│   ├─ MV + 非确定性函数 → HIVE-27948
│   └─ 重建表后查到过期数据 → HIVE-28551
│
└─ 1.3.9 其他
    ├─ 常量传播错误 → HIVE-22513, HIVE-25170
    │   → SET hive.optimize.constant.propagation=false; 对比
    ├─ Nested COALESCE → HIVE-20406
    ├─ MultiDelimitSerDe 最后一列 → HIVE-22360
    ├─ CASE 表达式类型错误 → HIVE-25734
    └─ __HIVE_DEFAULT_PARTITION__ 比较 → HIVE-16609
```

### 1.4 数据列错了（列错位/列类型不对）

```
列错了？
│
├─ Schema 演进场景（ALTER TABLE ADD COLUMNS 后）？
│   ├─ ORC + PPD → HIVE-14214 (ORC Schema Evolution + PPD 不兼容)
│   ├─ Parquet 不存在的列 → HIVE-16869
│   └─ 验证：对比 ALTER 前后的文件列映射
│       → hive --orcfiledump /path/to/file 查看实际列
│
├─ 向量化 scratch column 复用？ → HIVE-15588, HIVE-28880
│   → SET hive.vectorized.execution.enabled=false; 对比
│
├─ 列剪裁顺序错？ → HIVE-14564, HIVE-1341
│   → SELECT * 对比 SELECT 指定列
│
├─ Map Join 列混淆？ → HIVE-13191
│   → SET hive.auto.convert.join=false; 对比
│
├─ LLAP file column id 不匹配？ → HIVE-15964
│   → 非 LLAP 环境对比
│
├─ MV 引用列错误？ → HIVE-20379
│   → 不走 MV 对比：SET hive.materializedview.rewriting=false;
│
└─ Boolean 分区列路径错误？ → HIVE-6590
    → SHOW PARTITIONS 检查 HDFS 路径
```

### 1.5 数据集为空（该有结果但返回0行）

```
结果为空？
│
├─ ORC 表 + WHERE 条件 + ALTER TABLE ADD COLUMNS？
│   → HIVE-14214 (Schema Evolution + PPD 冲突)
│   → SET hive.optimize.index.filter=false; 对比
│
├─ WHERE 条件涉及 CHAR 类型？
│   → HIVE-11312 (CHAR 类型空格填充导致 PPD 匹配失败)
│   → CAST 为 VARCHAR 对比
│
├─ 聚合查询 + 空表/空分区？
│   → HIVE-124 (空表聚合应返回 1 行)
│   → HIVE-23712 (空 ACID 分区 metadata-only 查询)
│   → SET hive.compute.query.using.stats=false; 对比
│
├─ Decimal 列 JOIN？
│   → HIVE-5292 (Decimal 列 JOIN 隐式类型转换失败)
│   → 显式 CAST 两侧为相同 Decimal 精度
│
├─ ORC + BETWEEN + INTEGER 类型？
│   → HIVE-11372 (整数类型 BETWEEN PPD 失败)
│   → SET hive.optimize.index.filter=false; 对比
│
├─ ACID 表 + FetchOperator？
│   → HIVE-8103 (FetchOperator 路径不读 ACID 表)
│   → SET hive.fetch.task.conversion=none; 对比
│
├─ CASE 表达式类型错？
│   → HIVE-25734 (类型不匹配导致 CASE 返回空集)
│
└─ metadata-only 查询 + 不准确的统计？
    → HIVE-15397, HIVE-11266
    → SET hive.compute.query.using.stats=false; 对比
```

---

## 二、快速验证 SQL 集

> 每组 SQL 自包含（建表+插数据+查询+预期），可直接在 Hive 3.x 环境执行。
> 对比方法：先用默认参数执行，再改参数执行，结果不同则命中该 Bug。

### 2.1 验证向量化 Bug

```sql
-- ========================================
-- 测试 1: 向量化 NULL 值处理 (HIVE-18622)
-- 预期：id=3 的 flag 应为 NULL，不应为 true
-- ========================================
CREATE TABLE IF NOT EXISTS _test_vec_null (id INT, flag BOOLEAN) STORED AS ORC;
TRUNCATE TABLE _test_vec_null;
INSERT INTO _test_vec_null VALUES (1, true), (2, false), (3, NULL);

-- 开启向量化（默认）
SET hive.vectorized.execution.enabled=true;
SELECT id, flag, CASE WHEN flag IS NULL THEN 'IS_NULL' ELSE 'NOT_NULL' END AS null_check 
FROM _test_vec_null ORDER BY id;

-- 关闭向量化对比
SET hive.vectorized.execution.enabled=false;
SELECT id, flag, CASE WHEN flag IS NULL THEN 'IS_NULL' ELSE 'NOT_NULL' END AS null_check 
FROM _test_vec_null ORDER BY id;

-- 结果不同 → 命中向量化 NULL 处理 Bug
```

```sql
-- ========================================
-- 测试 2: 向量化 IF/CASE 表达式 (HIVE-17682, HIVE-28301)
-- 预期：两次结果应完全一致
-- ========================================
CREATE TABLE IF NOT EXISTS _test_vec_case (id INT, val INT) STORED AS ORC;
TRUNCATE TABLE _test_vec_case;
INSERT INTO _test_vec_case VALUES (1, 10), (2, NULL), (3, 30), (4, NULL), (5, 50);

SET hive.vectorized.execution.enabled=true;
SELECT id, CASE WHEN val IS NULL THEN -1 WHEN val > 20 THEN val * 2 ELSE val END AS result
FROM _test_vec_case ORDER BY id;

SET hive.vectorized.execution.enabled=false;
SELECT id, CASE WHEN val IS NULL THEN -1 WHEN val > 20 THEN val * 2 ELSE val END AS result
FROM _test_vec_case ORDER BY id;
```

```sql
-- ========================================
-- 测试 3: 向量化聚合 + WHERE 无 GROUP BY (HIVE-11172)
-- 预期：两次结果应完全一致
-- ========================================
CREATE TABLE IF NOT EXISTS _test_vec_agg (id INT, val INT) STORED AS ORC;
TRUNCATE TABLE _test_vec_agg;
INSERT INTO _test_vec_agg VALUES (1,10),(2,20),(3,30),(4,40),(5,50);

SET hive.vectorized.execution.enabled=true;
SELECT SUM(val), COUNT(val), AVG(val) FROM _test_vec_agg WHERE id > 2;

SET hive.vectorized.execution.enabled=false;
SELECT SUM(val), COUNT(val), AVG(val) FROM _test_vec_agg WHERE id > 2;
```

```sql
-- ========================================
-- 测试 4: 向量化 Decimal 分区表 (HIVE-29080)
-- 预期：两次结果应完全一致
-- ========================================
CREATE TABLE IF NOT EXISTS _test_vec_dec (id INT) PARTITIONED BY (amt DECIMAL(10,2)) STORED AS ORC;
ALTER TABLE _test_vec_dec DROP IF EXISTS PARTITION (amt=99.99);
INSERT INTO _test_vec_dec PARTITION(amt=99.99) VALUES (1), (2), (3);

SET hive.vectorized.execution.enabled=true;
SELECT * FROM _test_vec_dec WHERE amt = 99.99;

SET hive.vectorized.execution.enabled=false;
SELECT * FROM _test_vec_dec WHERE amt = 99.99;
```

### 2.2 验证 JOIN Bug

```sql
-- ========================================
-- 测试 5: joinEmitInterval 截断 (HIVE-4781, HIVE-15327)
-- 准备 > 1000 行右表，检查 LEFT JOIN 是否被截断
-- ========================================
CREATE TABLE IF NOT EXISTS _test_join_left (id INT) STORED AS ORC;
CREATE TABLE IF NOT EXISTS _test_join_right (id INT, val STRING) STORED AS ORC;
TRUNCATE TABLE _test_join_left;
TRUNCATE TABLE _test_join_right;
INSERT INTO _test_join_left VALUES (1);
-- 插入 2000 行右表（同一个 id=1）
INSERT INTO _test_join_right 
SELECT 1, CONCAT('row_', idx) FROM (
  SELECT ROW_NUMBER() OVER () AS idx FROM _test_vec_agg a 
  CROSS JOIN _test_vec_agg b 
  CROSS JOIN _test_vec_agg c 
  CROSS JOIN _test_vec_agg d LIMIT 2000
) t;

-- 默认 emit.interval=1000
SET hive.join.emit.interval=1000;
SELECT COUNT(*) FROM _test_join_left a LEFT JOIN _test_join_right b ON a.id = b.id;
-- 预期 2000，如果返回 1000 则命中 Bug

-- 关闭 emit 截断
SET hive.join.emit.interval=0;
SELECT COUNT(*) FROM _test_join_left a LEFT JOIN _test_join_right b ON a.id = b.id;
```

```sql
-- ========================================
-- 测试 6: Bucket Map Join 正确性 (HIVE-11605, HIVE-27069)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_bmj_a (id INT, val STRING) 
  CLUSTERED BY (id) INTO 4 BUCKETS STORED AS ORC;
CREATE TABLE IF NOT EXISTS _test_bmj_b (id INT, val STRING) 
  CLUSTERED BY (id) INTO 4 BUCKETS STORED AS ORC;
TRUNCATE TABLE _test_bmj_a;
TRUNCATE TABLE _test_bmj_b;
INSERT INTO _test_bmj_a VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d');
INSERT INTO _test_bmj_b VALUES (1,'x'),(2,'y'),(5,'z');

-- 开启 bucket map join
SET hive.auto.convert.join=true;
SET hive.optimize.bucketmapjoin=true;
SELECT a.id, a.val, b.val FROM _test_bmj_a a JOIN _test_bmj_b b ON a.id = b.id ORDER BY a.id;

-- 关闭 map join 对比
SET hive.auto.convert.join=false;
SELECT a.id, a.val, b.val FROM _test_bmj_a a JOIN _test_bmj_b b ON a.id = b.id ORDER BY a.id;

-- 结果不同 → 命中 Bucket Map Join Bug
```

```sql
-- ========================================
-- 测试 7: NOT IN + NULL 值 (HIVE-27324)
-- 预期：NOT IN 子查询含 NULL 时应返回空集
-- ========================================
CREATE TABLE IF NOT EXISTS _test_notin_main (id INT) STORED AS ORC;
CREATE TABLE IF NOT EXISTS _test_notin_sub (id INT) STORED AS ORC;
TRUNCATE TABLE _test_notin_main;
TRUNCATE TABLE _test_notin_sub;
INSERT INTO _test_notin_main VALUES (1),(2),(3);
INSERT INTO _test_notin_sub VALUES (1),(NULL);

-- NOT IN 含 NULL：三值逻辑下应返回 0 行
SELECT * FROM _test_notin_main WHERE id NOT IN (SELECT id FROM _test_notin_sub);
-- 如果返回了行 → 命中 Bug，改用 NOT EXISTS：
SELECT * FROM _test_notin_main m WHERE NOT EXISTS (SELECT 1 FROM _test_notin_sub s WHERE s.id = m.id);
```

### 2.3 验证 CBO Bug

```sql
-- ========================================
-- 测试 8: CBO 多 IN 条件 (HIVE-26209)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_cbo_in (a INT, b INT, c INT) STORED AS ORC;
TRUNCATE TABLE _test_cbo_in;
INSERT INTO _test_cbo_in VALUES (1,2,3),(4,5,6),(7,8,9),(1,5,9);

SET hive.cbo.enable=true;
SELECT * FROM _test_cbo_in WHERE a IN (1,4) AND b IN (2,5) ORDER BY a,b;

SET hive.cbo.enable=false;
SELECT * FROM _test_cbo_in WHERE a IN (1,4) AND b IN (2,5) ORDER BY a,b;
```

```sql
-- ========================================
-- 测试 9: CBO 非确定性函数 PPD (HIVE-19889)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_cbo_rand (id INT, val INT) STORED AS ORC;
TRUNCATE TABLE _test_cbo_rand;
INSERT INTO _test_cbo_rand SELECT id, id*10 FROM (SELECT EXPLODE(ARRAY(1,2,3,4,5,6,7,8,9,10)) AS id) t;

-- CBO 可能将 rand() 下推导致每行都用不同随机数
SET hive.cbo.enable=true;
SELECT COUNT(*) FROM _test_cbo_rand WHERE val > 50 AND rand() < 0.999;

SET hive.cbo.enable=false;
SELECT COUNT(*) FROM _test_cbo_rand WHERE val > 50 AND rand() < 0.999;
-- 多次执行，CBO 开启时结果波动更大说明 rand() 被错误下推
```

### 2.4 验证 ORC/PPD Bug

```sql
-- ========================================
-- 测试 10: ORC Schema Evolution + PPD (HIVE-14214)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_orc_evo (a INT, b STRING) STORED AS ORC;
TRUNCATE TABLE _test_orc_evo;
INSERT INTO _test_orc_evo VALUES (1,'hello'),(2,'world');

-- 添加新列
ALTER TABLE _test_orc_evo ADD COLUMNS (c INT);
INSERT INTO _test_orc_evo VALUES (3,'new',100);

-- PPD 开启
SET hive.optimize.index.filter=true;
SELECT * FROM _test_orc_evo WHERE c = 100;
-- 预期返回 1 行

-- PPD 关闭对比
SET hive.optimize.index.filter=false;
SELECT * FROM _test_orc_evo WHERE c = 100;

-- 返回行数不同 → 命中 Schema Evolution + PPD Bug
```

```sql
-- ========================================
-- 测试 11: CHAR 类型 PPD (HIVE-11312)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_char_ppd (id INT, name CHAR(10)) STORED AS ORC;
TRUNCATE TABLE _test_char_ppd;
INSERT INTO _test_char_ppd VALUES (1, 'abc'), (2, 'def');

SET hive.optimize.index.filter=true;
SELECT * FROM _test_char_ppd WHERE name = 'abc';
-- 注意 CHAR(10) 存储时会右补空格为 'abc       '

SET hive.optimize.index.filter=false;
SELECT * FROM _test_char_ppd WHERE name = 'abc';
```

### 2.5 验证统计信息 / metadata-only Bug

```sql
-- ========================================
-- 测试 12: count(*) 基于统计信息 (HIVE-11266)
-- ========================================
CREATE EXTERNAL TABLE IF NOT EXISTS _test_stats_ext (id INT) STORED AS ORC 
  LOCATION '/tmp/_test_stats_ext';
-- 手动插入数据后不更新统计
INSERT INTO _test_stats_ext VALUES (1),(2),(3);

SET hive.compute.query.using.stats=true;
SELECT COUNT(*) FROM _test_stats_ext;

SET hive.compute.query.using.stats=false;
SELECT COUNT(*) FROM _test_stats_ext;
-- 外部表统计信息不准时，两者可能不一致
```

### 2.6 验证 Timestamp / 精度 Bug

```sql
-- ========================================
-- 测试 13: Timestamp 时区偏移 (HIVE-13948)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_ts_tz (id INT, ts TIMESTAMP) STORED AS ORC;
TRUNCATE TABLE _test_ts_tz;
INSERT INTO _test_ts_tz VALUES (1, '2026-01-01 00:00:00'), (2, '2026-06-15 12:30:00');

SET hive.local.time.zone=UTC;
SELECT id, ts FROM _test_ts_tz ORDER BY id;

SET hive.local.time.zone=Asia/Shanghai;
SELECT id, ts FROM _test_ts_tz ORDER BY id;
-- 如果两次 ts 值不同（不只是显示不同），说明存储层写入就有时区偏移
```

```sql
-- ========================================
-- 测试 14: Decimal64 精度 (HIVE-20004)
-- ========================================
CREATE TABLE IF NOT EXISTS _test_dec64 (id INT, val DECIMAL(18,6)) STORED AS ORC;
TRUNCATE TABLE _test_dec64;
INSERT INTO _test_dec64 VALUES (1, 123456.789012), (2, 0.000001), (3, 999999.999999);

SET hive.vectorized.execution.enabled=true;
SELECT id, val, val * 2 AS doubled FROM _test_dec64 ORDER BY id;

SET hive.vectorized.execution.enabled=false;
SELECT id, val, val * 2 AS doubled FROM _test_dec64 ORDER BY id;
-- 精度不一致 → 命中 ConvertDecimal64ToDecimal Bug
```

### 2.7 清理测试表

```sql
-- 用完后清理
DROP TABLE IF EXISTS _test_vec_null;
DROP TABLE IF EXISTS _test_vec_case;
DROP TABLE IF EXISTS _test_vec_agg;
DROP TABLE IF EXISTS _test_vec_dec;
DROP TABLE IF EXISTS _test_join_left;
DROP TABLE IF EXISTS _test_join_right;
DROP TABLE IF EXISTS _test_bmj_a;
DROP TABLE IF EXISTS _test_bmj_b;
DROP TABLE IF EXISTS _test_notin_main;
DROP TABLE IF EXISTS _test_notin_sub;
DROP TABLE IF EXISTS _test_cbo_in;
DROP TABLE IF EXISTS _test_cbo_rand;
DROP TABLE IF EXISTS _test_orc_evo;
DROP TABLE IF EXISTS _test_char_ppd;
DROP TABLE IF EXISTS _test_stats_ext;
DROP TABLE IF EXISTS _test_ts_tz;
DROP TABLE IF EXISTS _test_dec64;
```

---

## 三、结果正确性配置参数速查表

> 只收录**会影响查询结果正确性**的参数。性能类/连接类参数见 [S01-Part3](./S01-Part3-配置参数速查与排障决策树.md)。
> 默认值来源：Hive 4.3.0-SNAPSHOT 源码 `HiveConf.java`（与 Hive 3.x 基本一致，个别差异已标注）。

### 3.1 向量化执行

| 参数 | 默认值 | 风险场景 | 建议值 | 涉及现象 |
|------|--------|---------|--------|---------|
| `hive.vectorized.execution.enabled` | `true` | 向量化模式下 NULL 处理、类型转换、聚合均有已知 Bug | 排障时临时 `false` 对比 | 值错了、列错了 |
| `hive.vectorized.execution.reduce.enabled` | `true` | Reduce 侧向量化聚合错误 | 排障时临时 `false` | 值错了 |

### 3.2 CBO 优化器

| 参数 | 默认值 | 风险场景 | 建议值 | 涉及现象 |
|------|--------|---------|--------|---------|
| `hive.cbo.enable` | `true` | CBO 子查询重写、IN 条件合并、非确定性函数下推可能出错 | 排障时临时 `false` 对比 | 值错了、少了、为空 |
| `hive.optimize.constant.propagation` | `true` | 常量传播导致类型错误或条件丢失 (HIVE-22513, HIVE-25170) | 排障时临时 `false` | 值错了、为空 |

### 3.3 JOIN 相关

| 参数 | 默认值 | 风险场景 | 建议值 | 涉及现象 |
|------|--------|---------|--------|---------|
| `hive.join.emit.interval` | `1000` | 单 key 右表 >1000 行时 OUTER/SEMI JOIN 结果被截断 | `0`（排障时关闭） | 少了、值错了 |
| `hive.auto.convert.join` | `true` | Map Join 在边界条件、列映射上有多个已知 Bug | 排障时临时 `false` | 多了、少了、值错了、列错了 |
| `hive.merge.nway.joins` | `false` | 开启后多个 OUTER JOIN 合并可能丢条件 (HIVE-14326) | 保持 `false` | 多了、少了 |
| `hive.mapjoin.optimized.hashtable` | `true` | 优化哈希表在 Tez 场景下的边界 Bug | 排障时临时 `false` | 值错了 |
| `hive.optimize.semijoin.conversion` | `true` | Semi Join 转换在含 NULL 的场景可能丢行 | 排障时临时 `false` | 少了 |

### 3.4 谓词下推 / 索引过滤

| 参数 | 默认值 | 风险场景 | 建议值 | 涉及现象 |
|------|--------|---------|--------|---------|
| `hive.optimize.ppd` | `true` | PPD 在 OUTER JOIN 后、CHAR 类型、非确定性函数场景错误 | 排障时临时 `false` | 值错了、为空 |
| `hive.optimize.index.filter` | `true` | ORC/Parquet Schema Evolution 后 PPD 返回错误 (HIVE-14214, HIVE-15680) | 排障时临时 `false` | 值错了、为空 |

### 3.5 统计信息 / 元数据查询

| 参数 | 默认值 | 风险场景 | 建议值 | 涉及现象 |
|------|--------|---------|--------|---------|
| `hive.compute.query.using.stats` | `true` | 统计信息不准时 count(*) 等聚合返回错误值 (HIVE-11266, HIVE-15397) | 排障时 `false`；外部表建议长期 `false` | 值错了、为空 |
| `hive.fetch.task.conversion` | `more` | FetchOperator 路径不处理 ACID 表 (HIVE-8103) | ACID 表排障时 `none` | 为空 |

### 3.6 数据倾斜 / 其他

| 参数 | 默认值 | 风险场景 | 建议值 | 涉及现象 |
|------|--------|---------|--------|---------|
| `hive.groupby.skewindata` | `false` | 开启后 count(*) + count(distinct) 结果可能错误 (HIVE-10971) | 保持 `false`，除非确认有严重倾斜 | 值错了 |
| `hive.server2.thrift.resultset.serialize.in.tasks` | `false` | 开启后 binaryColumns 路径存在双重反序列化 Bug（见 Part1 风险点1） | 保持 `false` | 值错了、列错了 |

### 排障"万能组合"

当不确定哪个参数导致结果错误时，用以下组合一键关闭所有优化，对比结果：

```sql
-- 一键关闭所有可能影响结果正确性的优化
SET hive.vectorized.execution.enabled=false;
SET hive.vectorized.execution.reduce.enabled=false;
SET hive.cbo.enable=false;
SET hive.auto.convert.join=false;
SET hive.join.emit.interval=0;
SET hive.optimize.ppd=false;
SET hive.optimize.index.filter=false;
SET hive.compute.query.using.stats=false;
SET hive.optimize.constant.propagation=false;
SET hive.optimize.semijoin.conversion=false;
SET hive.groupby.skewindata=false;
SET hive.fetch.task.conversion=none;

-- 执行你的查询，如果结果正确了，说明是某个优化导致的
-- 然后逐个开启参数，二分法定位具体是哪个
```

---

## 四、Hive 3.x 高频 Bug 根因分析与修复方案

> 每个 Bug 用"**现象 → 根因 → 修复**"三段式描述，聚焦 Hive 3.x 实际会遇到的问题。
> 按影响严重度排序（Blocker > Critical > Major）。

### 4.1 向量化类

#### Bug-01: 向量化 IF/CASE WHEN NULL 处理错误
- **现象**: IF(expr, val1, val2) 或 CASE WHEN 中涉及 NULL 时返回错误值。Boolean NULL 可能变成 true。向量化开启时出现，关闭后正确。
- **根因**: 向量化 batch 处理时，isNull bitmap 的偏移未正确对齐，导致 NULL 标记丢失。ColumnBuffer 源码中 Boolean null 默认填充为 `true`（其他数值类型填充为 0），null bitmap 偏差时暴露。
- **修复**: 
  - 短期：`SET hive.vectorized.execution.enabled=false;` 规避
  - 长期：升级到 Hive 4.0.0-alpha-1+（HIVE-18622, HIVE-19384, HIVE-17682 集中修复）
- **验证**: 测试 1（§2.1）

#### Bug-02: 向量化 CAST 表达式返回错误结果
- **现象**: `CAST(col AS CHAR(n))` 或 `CAST(col AS VARCHAR(n))` 在向量化模式下结果截断方式不正确；CAST timestamp 结果偏移。
- **根因**: 向量化 CAST 表达式的目标类型宽度计算逻辑与非向量化路径不一致，`VectorAssignRow` 中 Char/Varchar 截断逻辑有缺陷。
- **修复**:
  - 短期：规避 `SET hive.vectorized.execution.enabled=false;`
  - 长期：升级到含 HIVE-19498 修复的版本（3.1.0+）
- **验证**: CAST 查询开关向量化对比

#### Bug-03: 向量化聚合 WHERE 无 GROUP BY 结果错误
- **现象**: `SELECT SUM(col) FROM t WHERE condition`（无 GROUP BY）向量化模式下结果不对，例如多算或少算。
- **根因**: VectorGroupByOperator 在无 GROUP BY 场景下对过滤后的 batch 行数计算错误，isRepeating 标记未正确传播。
- **修复**:
  - 短期：`SET hive.vectorized.execution.enabled=false;`
  - 长期：HIVE-11172（修复版本 1.2.2+, 2.0.0+），但后续版本仍有回归，建议同时检查 HIVE-20174
- **验证**: 测试 3（§2.1）

#### Bug-04: 向量化 scratch column 复用导致列错位
- **现象**: 复杂表达式（嵌套函数、多层 CASE）结果中列数据串到了其他列，或计算结果异常。
- **根因**: Vectorizer 的 scratch column 分配/释放逻辑有 Bug，已释放的临时列被复用后未正确清零，导致后续计算读到脏数据（HIVE-15588）。
- **修复**:
  - 短期：`SET hive.vectorized.execution.enabled=false;`
  - 长期：升级到含 HIVE-15588 修复的版本（2.2.0+）
- **验证**: 复杂表达式开关向量化对比

#### Bug-05: Decimal 分区表向量化查询结果错误
- **现象**: 查询 Decimal 类型分区列的分区表时，向量化模式下 WHERE 过滤或返回值不正确。
- **根因**: 向量化执行引擎的 Decimal64 快速路径在处理分区列时使用了错误的 scale 值进行转换（HIVE-20004），ConvertDecimal64ToDecimal 丢精度。
- **修复**:
  - 短期：`SET hive.vectorized.execution.enabled=false;`
  - 长期：HIVE-20004（3.2.0+, 4.0.0-alpha-1+），HIVE-29080（4.1.0+）

### 4.2 JOIN 类

#### Bug-06: joinEmitInterval 截断 OUTER/SEMI JOIN
- **现象**: LEFT JOIN 或 LEFT SEMI JOIN 结果行数不对，当右表同一个 key 的行数超过 1000 时结果被截断。
- **根因**: `hive.join.emit.interval=1000` 导致 JOIN 算子每处理 1000 行就 flush 一次结果。对 OUTER JOIN，flush 后重新初始化 match flag，导致后续行被误判为不匹配而丢弃。对 SEMI JOIN，flush 后误认为已找到匹配而跳过剩余行。
- **修复**:
  - 短期：`SET hive.join.emit.interval=0;`（关闭 flush，但可能增加内存使用）
  - 长期：HIVE-4781（0.12.0+），HIVE-15327（2.2.0+），但不同 JOIN 类型修复进度不同
- **验证**: 测试 5（§2.2）

#### Bug-07: OUTER JOIN 合并丢失条件
- **现象**: 多个 LEFT/RIGHT JOIN 串联时结果行数不对（多了或少了），将查询拆成多步执行结果正确。
- **根因**: 优化器将相邻的 OUTER JOIN 合并为 n-way join 时，部分 ON 条件被错误丢弃或合并（HIVE-12465, HIVE-14326）。
- **修复**:
  - 短期：`SET hive.merge.nway.joins=false;`（默认就是 false，检查是否被改了）
  - 长期：HIVE-14326（2.1.1+, 2.2.0+）

#### Bug-08: Bucket Map Join 结果错误
- **现象**: 两个分桶表 JOIN 结果不对（值错或行丢失），关闭 auto.convert.join 后正确。
- **根因**: 当两表 bucket 列类型不完全一致（如 Decimal 精度不同）或 bucket 数不同时，Bucket Map Join 的 hash 分桶逻辑对不上，导致某些 key 的匹配失败。
- **修复**:
  - 短期：`SET hive.auto.convert.join=false;`
  - 长期：HIVE-11605（1.0.2+），HIVE-27069（未指定），HIVE-27267（未指定）
- **验证**: 测试 6（§2.2）

#### Bug-09: Anti Join 转换丢结果
- **现象**: `WHERE col NOT IN (subquery)` 或 `WHERE col IS NULL` 被错误转换为 Anti Join 后返回行数错误（通常少了）。
- **根因**: 优化器将 IS NULL 过滤条件转换为 Anti Join 时，未正确处理 nullable 列的三值逻辑（HIVE-26135, HIVE-29175, HIVE-29176）。
- **修复**:
  - 短期：改写 NOT IN 为 NOT EXISTS；或 `SET hive.optimize.semijoin.conversion=false;`
  - 长期：HIVE-29175（4.2.0+），HIVE-29176（4.2.0+）
- **验证**: 测试 7（§2.2）

#### Bug-10: Map Join 列混淆
- **现象**: Map Join 后结果中 A 表的列值出现在了 B 表的位置，或多表 JOIN 时列串了。
- **根因**: DummyTable 在 Map Join 中用作占位表时，列映射索引计算错误（HIVE-13191）。
- **修复**:
  - 短期：`SET hive.auto.convert.join=false;`
  - 长期：HIVE-13191（2.0.0+）

### 4.3 数据类型 / 精度类

#### Bug-11: Timestamp 时区处理错误
- **现象**: Timestamp 值在写入和读取之间存在时区偏移（通常偏移 8 小时 / 当地时区偏移量），导致查询结果中的时间不对。
- **根因**: TimestampWritable 在序列化时使用了 JVM 默认时区而非 UTC，导致跨时区读写时值偏移（HIVE-13948）。2.x → 3.x 升级后 timestamp 语义有变更，旧 ORC 文件中的 timestamp 可能被错误解读。
- **修复**:
  - 短期：`SET hive.local.time.zone=UTC;` 统一时区
  - 长期：HIVE-13948（1.2.2+, 2.0.2+），后续 HIVE-25268（4.0.0-alpha-1+）继续修复 1900 年前的日期问题
- **验证**: 测试 13（§2.6）

#### Bug-12: Decimal64 精度丢失
- **现象**: Decimal 类型列的计算结果（乘除法、聚合）精度不正确，末尾几位与预期不符。
- **根因**: ConvertDecimal64ToDecimal 使用了错误的 scale 值进行转换（HIVE-20004），向量化模式下 Decimal64 快速路径的精度截断逻辑与标准 HiveDecimal 不一致。
- **修复**:
  - 短期：`SET hive.vectorized.execution.enabled=false;`
  - 长期：HIVE-20004（3.2.0+）
- **验证**: 测试 14（§2.6）

#### Bug-13: Float 类型 JDBC 传输精度偏差
- **现象**: Beeline 中查询 FLOAT 列，返回值与实际写入值有微小偏差（如 `3.14` 变成 `3.140000104904175`）。
- **根因**: ColumnBuffer 源码中 FLOAT 值通过 `Float.toString()` → `Double.parseDouble()` 中转，而非直接 `(double)(float)field.doubleValue()`，导致浮点精度损失。
- **修复**:
  - 短期：查询中 CAST 为 DECIMAL 获取精确值：`SELECT CAST(float_col AS DECIMAL(10,2)) FROM t;`
  - 长期：修改 ColumnBuffer.java（见 Part1 风险点 4）

### 4.4 CBO / 优化器类

#### Bug-14: CBO 多 IN 条件组合错误
- **现象**: `WHERE a IN (1,2) AND b IN (3,4)` CBO 开启时返回结果不对（多了或少了），关闭 CBO 正确。
- **根因**: Calcite CBO 在合并多个 IN 条件时的 RexNode 重写逻辑有缺陷，某些组合被错误地转换为 OR 条件（HIVE-26209）。
- **修复**:
  - 短期：`SET hive.cbo.enable=false;`
  - 长期：HIVE-26209（未指定修复版本，需关注社区进展）
- **验证**: 测试 8（§2.3）

#### Bug-15: EXISTS 子查询重写产生错误执行计划
- **现象**: 含 EXISTS 子查询的查询在 CBO 开启时结果错误。
- **根因**: CBO 将 EXISTS 子查询重写为 semi join 时，关联条件处理不当，导致执行计划语义改变（HIVE-27801）。
- **修复**:
  - 短期：`SET hive.cbo.enable=false;`
  - 长期：HIVE-27801（4.0.0+）

#### Bug-16: 常量传播导致结果错误
- **现象**: 含等值条件的查询结果不对，EXPLAIN 发现 WHERE 条件被意外替换。
- **根因**: 常量传播优化器在传递常量时使用了错误的 colExprMap，导致替换到了不相关列的值（HIVE-22513, HIVE-25170）。
- **修复**:
  - 短期：`SET hive.optimize.constant.propagation=false;`
  - 长期：HIVE-22513（4.0.0-alpha-1+），HIVE-25170（4.0.0-alpha-1+）

### 4.5 PPD / 存储格式类

#### Bug-17: ORC Schema Evolution + PPD 不兼容
- **现象**: 对 ORC 表做了 `ALTER TABLE ADD COLUMNS` 后，WHERE 条件对新列的查询返回 0 行或错误结果。
- **根因**: ORC Reader 的 PPD 模块使用文件中的 column index，ADD COLUMNS 后新列在旧文件中不存在，PPD 用了错误的 column index 匹配，导致过滤失效或过度过滤（HIVE-14214）。
- **修复**:
  - 短期：`SET hive.optimize.index.filter=false;`
  - 长期：HIVE-14214（2.1.1+, 2.2.0+）
- **验证**: 测试 10（§2.4）

#### Bug-18: ORC 同表引用两次 + index filter 错误
- **现象**: 同一个查询中两次引用同一张 ORC 表（如 self join 或 UNION），开启 index filter 时结果错误。
- **根因**: ORC 的 split 缓存在同一个查询中被共享，两次引用的过滤条件互相干扰（HIVE-15680）。
- **修复**:
  - 短期：`SET hive.optimize.index.filter=false;`
  - 长期：HIVE-15680（2.4.0+, 3.0.0+）

#### Bug-19: Parquet 不存在列的 PPD 返回错误
- **现象**: 对 Parquet 表做了 Schema Evolution 后，WHERE 条件涉及不存在的列时不是返回 0 行，而是返回了不正确的数据。
- **根因**: Parquet reader 将不存在列的谓词下推到了错误的列位置上（HIVE-16869）。
- **修复**:
  - 短期：`SET hive.optimize.ppd=false;`
  - 长期：HIVE-16869（3.0.0+）

### 4.6 统计信息 / 元数据类

#### Bug-20: count(*) 基于过期统计信息返回错误
- **现象**: 外部表的 `SELECT COUNT(*)` 返回值与实际行数不一致，尤其是在外部工具写入数据后。
- **根因**: `hive.compute.query.using.stats=true` 时，Hive 直接从 MetaStore 统计信息中获取 count 值，外部表的统计信息可能过期或从未更新（HIVE-11266）。
- **修复**:
  - 短期：`SET hive.compute.query.using.stats=false;`
  - 长期：对外部表建议长期关闭此参数；或定期 `ANALYZE TABLE t COMPUTE STATISTICS;`
- **验证**: 测试 12（§2.5）

#### Bug-21: 空表/空分区 metadata-only 查询返回错误
- **现象**: 空表上执行 `SELECT COUNT(*)` 返回 NULL 而非 0，或空 ACID 分区的 metadata-only 查询返回不正确的值。
- **根因**: metadata-only 查询路径对空表/空分区的 null 统计值处理不当（HIVE-124, HIVE-15397, HIVE-23712）。
- **修复**:
  - 短期：`SET hive.compute.query.using.stats=false;`
  - 长期：HIVE-15397（2.2.0+），HIVE-23712（4.0.0-alpha-1+）

### 4.7 UNION / GROUP BY / 子查询类

#### Bug-22: NOT IN 子查询含 NULL 返回错误结果
- **现象**: `WHERE id NOT IN (SELECT id FROM t2)` 当 t2 中有 NULL 值时返回了行（应返回空集）。
- **根因**: Hive 的 NOT IN → Anti Join 转换未正确实现 SQL 标准的三值逻辑：当子查询结果集含 NULL 时，NOT IN 对所有行都应返回 UNKNOWN（即不匹配）（HIVE-27324）。
- **修复**:
  - 短期：改写为 `WHERE NOT EXISTS (SELECT 1 FROM t2 WHERE t2.id = t1.id)`
  - 长期：HIVE-27324（4.0.0+）
- **验证**: 测试 7（§2.2）

#### Bug-23: count(*) + count(distinct) + skewindata 错误
- **现象**: `SELECT count(*), count(distinct col) FROM t` 当 `hive.groupby.skewindata=true` 时 count(*) 值翻倍。
- **根因**: skewindata 优化将 GROUP BY 拆成两阶段，但 count(*) 和 count(distinct) 的两阶段合并逻辑不兼容（HIVE-10971）。
- **修复**:
  - 短期：`SET hive.groupby.skewindata=false;`
  - 长期：HIVE-10971（1.2.1+）

#### Bug-24: UNION ALL 类型不一致导致数据错误
- **现象**: `SELECT int_col FROM t1 UNION ALL SELECT double_col FROM t2` 结果中某些值被截断或精度丢失。
- **根因**: UNION ALL 的类型推导在某些组合下（INT + DOUBLE, STRING + DATE）选择了不合适的目标类型或未做正确的隐式转换（HIVE-14251）。
- **修复**:
  - 短期：手动 CAST 为统一类型：`SELECT CAST(int_col AS DOUBLE) FROM t1 UNION ALL SELECT double_col FROM t2`
  - 长期：HIVE-14251（2.2.0+）

### 4.8 ACID / 事务类

#### Bug-25: ACID 表 UPDATE 导致其他列数据错乱
- **现象**: UPDATE 了某一列后，查询发现其他列的值也变了。
- **根因**: ORC ACID 的行级 UPDATE 在某些场景下未正确复制未修改列的值，导致数据损坏（HIVE-22945）。
- **修复**:
  - 短期：INSERT OVERWRITE 替代 UPDATE
  - 长期：HIVE-22945（未指定修复版本，需关注社区）

#### Bug-26: Compaction 后数据丢失
- **现象**: Major compaction 执行后部分数据丢失，特别是 streaming 写入场景。
- **根因**: MRCompactor 在 major compaction 时未正确合并所有 delta 文件（HIVE-28700），streaming 场景下 skipped compaction 可能跳过未 flush 的数据（HIVE-24481）。
- **修复**:
  - 短期：手动检查 compaction 前后行数：`SELECT COUNT(*) FROM t;` 对比
  - 长期：HIVE-28700（4.1.0+），HIVE-24481（4.0.0-alpha-1+）

#### Bug-27: LOAD DATA + ACID 表查询结果错误
- **现象**: 对 ACID 表执行 `LOAD DATA` 后 `SELECT *` 返回错误结果（列错位或值不对）。
- **根因**: LOAD DATA 对 ACID 表的事务处理不完整，delta 文件的元数据未正确更新（HIVE-21460）。
- **修复**:
  - 短期：改用 `INSERT INTO ... SELECT ... FROM` 替代 LOAD DATA
  - 长期：HIVE-21460（3.1.1+）

### 4.9 HS2 传输层（见 Part1 源码分析详情）

#### Bug-28: JDBC binaryColumns 路径双重反序列化
- **现象**: 当 `hive.server2.thrift.resultset.serialize.in.tasks=true` 时，JDBC 客户端接收到的结果数据完全错误或为空。
- **根因**: HiveQueryResultSet.java 中对同一个 TRowSet 调用了两次 `RowSetFactory.create()`，binaryColumns 模式下第一次反序列化消费了底层流，第二次读到脏数据（详见 [Part1 风险点1](./S04-Part1-HS2结果错误源码分析.md#-风险点-1jdbc-客户端双重创建-rowset最致命)）。
- **修复**:
  - 短期：确保 `hive.server2.thrift.resultset.serialize.in.tasks=false;`（这是默认值）
  - 长期：修改 HiveQueryResultSet.java，删除冗余的 RowSetFactory.create() 调用

#### Bug-29: hasMoreRows 硬编码导致尾部数据丢失
- **现象**: 大结果集查询偶尔丢失最后几行，尤其当结果行数恰好是 fetchSize 的整数倍时。
- **根因**: ThriftCLIService.java 中 `resp.setHasMoreRows(false)` 硬编码为 false，客户端在结果集恰好在 fetchSize 边界时可能提前终止 fetch。
- **修复**:
  - 短期：增大 fetchSize（减少命中边界的概率）：`SET hive.server2.thrift.resultset.max.fetch.size=10000;`
  - 长期：修改 ThriftCLIService.java，根据实际情况设置 hasMoreRows

---

## 五、排障流程速记卡

```
┌─────────────────────────────────────────────────────┐
│         Hive 查询结果不对？速记排障卡               │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Step 0: 确认现象（多了/少了/值错/列错/为空）       │
│                                                     │
│  Step 1: 一键关闭优化 → 结果对了吗？               │
│    SET hive.vectorized.execution.enabled=false;     │
│    SET hive.cbo.enable=false;                       │
│    SET hive.auto.convert.join=false;                │
│    SET hive.optimize.ppd=false;                     │
│    SET hive.optimize.index.filter=false;            │
│    SET hive.compute.query.using.stats=false;        │
│    SET hive.join.emit.interval=0;                   │
│                                                     │
│  Step 2: 逐个开启，二分法定位                       │
│                                                     │
│  Step 3: 找到后查本手册 §4 对应 Bug                 │
│    → 有临时规避方案 → 有长期修复建议                │
│                                                     │
│  Step 4: 关键验证 SQL 在 §2                         │
│                                                     │
│  Step 5: 参数速查在 §3                              │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

> 本文档是 S04 系列的核心排障手册。
> 源码级风险点详见 [S04-Part1](./S04-Part1-HS2结果错误源码分析.md)。
> Hive 3.x 高危 Bug 精简索引详见 [S04-Part3](./S04-Part3-Hive3x高危结果Bug索引.md)。
