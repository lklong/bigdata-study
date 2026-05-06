# Spark + Parquet / ORC 深度教案 — 列式存储、谓词下推与格式选型

> **教学目标**：学完本课后，你能解释列式存储为什么比行式快 10 倍、Spark 如何利用谓词下推跳过无关数据、Parquet 和 ORC 到底该选哪个。
>
> **适用场景**：数据湖/数仓中 90% 的文件格式选型问题

---

## 一、课前故事 — 行式 vs 列式

### 1.1 行式存储（MySQL/CSV）

想象一个**Excel 表格**，按**行**存到 U 盘里：

```
U盘内容: [Alice,25,北京] [Bob,30,上海] [Carol,28,广州] ...

要查所有人的年龄：
  → 读出 Alice 整行（3个字段），只取第2个
  → 读出 Bob 整行，只取第2个
  → 读出 Carol 整行，只取第2个
  → 读了 3 份多余数据！浪费 I/O！
```

### 1.2 列式存储（Parquet/ORC）

把**同一列的数据**连续存放：

```
U盘内容: [Alice,Bob,Carol] [25,30,28] [北京,上海,广州]
            ↑ name列          ↑ age列     ↑ city列

要查所有人的年龄：
  → 直接读 age列 [25,30,28]
  → 只读了 1/3 的数据！I/O 省 67%！

额外福利：
  同一列数据类型相同 → 压缩率极高（如 age 列只有整数，RLE 编码直接压到几字节）
```

**结论**：分析型查询（SELECT 少量列，扫描大量行）→ **列式存储快 10-100 倍**。

---

## 二、Parquet 文件结构深度图解

```
┌─────────────────────────────────────────────────────┐
│                   Parquet File                       │
├─────────────────────────────────────────────────────┤
│  Row Group 1 (通常 128MB)                           │
│  ┌─────────────┬──────────────┬──────────────┐     │
│  │ Column Chunk│ Column Chunk │ Column Chunk │     │
│  │   (name)    │   (age)      │   (city)     │     │
│  │ ┌─────────┐│ ┌──────────┐ │ ┌──────────┐ │     │
│  │ │ Page 1  ││ │ Page 1   │ │ │ Page 1   │ │     │
│  │ │(1MB,压缩)││ │(1MB,RLE) │ │ │(1MB,DICT)│ │     │
│  │ ├─────────┤│ ├──────────┤ │ ├──────────┤ │     │
│  │ │ Page 2  ││ │ Page 2   │ │ │ Page 2   │ │     │
│  │ └─────────┘│ └──────────┘ │ └──────────┘ │     │
│  └─────────────┴──────────────┴──────────────┘     │
│                                                     │
│  Row Group 2 (128MB)                               │
│  └─── ...                                          │
├─────────────────────────────────────────────────────┤
│  Footer                                             │
│  ├── Schema (列名、类型)                             │
│  ├── Row Group metadata (每个RG的offset、大小)       │
│  └── Column metadata (min/max值、null count、编码)   │
└─────────────────────────────────────────────────────┘

关键优化点：
  ① 列裁剪（Column Pruning）：只读需要的 Column Chunk
  ② 谓词下推（Predicate Pushdown）：通过 Footer 中的 min/max 跳过不匹配的 Row Group
  ③ 字典编码（Dictionary Encoding）：重复值多的列极致压缩
  ④ Page 级过滤：Bloom Filter 精确判断值是否存在
```

---

## 三、Spark 读写 Parquet — 完整示例

### 3.1 写入 Parquet

```python
# ===== DataFrame API =====
df.write \
    .mode("overwrite") \
    .partitionBy("dt") \
    .option("compression", "zstd") \
    .parquet("hdfs:///warehouse/orders/")

# ===== SQL =====
# spark-sql
CREATE TABLE orders_parquet (
    order_id BIGINT,
    product STRING,
    amount DOUBLE,
    dt STRING
) USING parquet
PARTITIONED BY (dt)
OPTIONS (
    'compression' = 'zstd',
    'parquet.block.size' = '134217728'  -- Row Group 大小 = 128MB
);

INSERT INTO orders_parquet SELECT * FROM raw_orders;
```

### 3.2 读取 Parquet（自动优化）

```python
# Spark 读 Parquet 时自动应用：
# ① Column Pruning — SELECT 哪些列就只读哪些列
# ② Predicate Pushdown — WHERE 条件下推到文件级
# ③ Partition Pruning — 分区列过滤时只扫描相关目录

df = spark.read.parquet("hdfs:///warehouse/orders/")

# 这条查询实际只读了 amount 列 + dt=2024-03-15 分区的文件：
result = df.filter("dt = '2024-03-15' AND amount > 100") \
           .select("order_id", "amount") \
           .show()
```

### 3.3 关键配置

```properties
# 写入优化
spark.sql.parquet.compression.codec = zstd           # 压缩算法（zstd > snappy > gzip）
spark.sql.parquet.filterPushdown = true              # 谓词下推（默认 true）
spark.sql.parquet.writeLegacyFormat = false          # 新格式（支持 DECIMAL 等）
spark.sql.files.maxRecordsPerFile = 0                # 0=不限制每文件行数

# 读取优化
spark.sql.parquet.enableVectorizedReader = true      # 向量化读取（默认 true，大幅提速）
spark.sql.columnVector.offheap.enabled = true        # 堆外内存向量化
```

---

## 四、Spark 读写 ORC

### 4.1 写入 ORC

```python
df.write \
    .mode("overwrite") \
    .partitionBy("dt") \
    .option("compression", "zstd") \
    .orc("hdfs:///warehouse/orders_orc/")
```

### 4.2 ORC 的独特优势

```
ORC 文件结构：
┌────────────────────────────────┐
│  Stripe 1 (通常 64MB)          │  ← 类似 Parquet 的 Row Group
│  ├── Index Data               │  ← 每列的 min/max/sum + Row Index
│  ├── Row Data                 │  ← 列式存储的实际数据
│  └── Stripe Footer            │  ← Stripe 元数据
│                                │
│  Stripe 2                      │
│  └── ...                       │
├────────────────────────────────┤
│  File Footer                   │  ← 全文件统计信息
│  Postscript                    │  ← 版本、压缩信息
└────────────────────────────────┘

ORC 独有特性：
  ① Row Index（每 10000 行一个索引）→ 更细粒度的行级跳过
  ② Bloom Filter Index → 列级布隆过滤（Parquet 也支持但需显式开启）
  ③ 原生 ACID 支持（Hive 3.x 的 ACID 基于 ORC）
  ④ 谓词下推更深：支持 Stripe 级 + Row Group 级两层过滤
```

### 4.3 ORC 专属配置

```properties
spark.sql.orc.filterPushdown = true              # 谓词下推
spark.sql.orc.enableVectorizedReader = true      # 向量化读取
spark.sql.hive.convertMetastoreOrc = true        # 读 Hive ORC 表时用原生 Reader
```

---

## 五、Parquet vs ORC 终极对比

| 维度 | Parquet | ORC |
|------|---------|-----|
| **生态** | Spark/Iceberg/Trino/**全生态通用** | Hive/Presto/**Hive 生态最优** |
| **默认压缩** | Snappy → Zstd (1.4+) | Zlib → Zstd |
| **嵌套类型** | ✅ 原生支持（Dremel 编码） | ⚠️ 支持但性能略差 |
| **ACID** | ❌（需 Iceberg/Hudi/Delta） | ✅ 原生（Hive ACID） |
| **索引** | Footer min/max + Bloom Filter | **更细粒度** Row Index + Bloom Filter |
| **Row Group 大小** | 128MB（默认） | 64MB（Stripe） |
| **向量化读取** | ✅ Spark 原生 | ✅ Spark/Hive 原生 |
| **谓词下推** | Row Group 级 | **Stripe 级 + Row Group 级**（两层） |
| **压缩率** | ★★★★ | ★★★★★（稍优，因为 Row Index 辅助） |
| **写入速度** | ★★★★★ | ★★★★ |
| **读取速度** | ★★★★ | ★★★★★（索引更细） |
| **社区活跃度** | Apache 顶级项目 | Apache 顶级项目 |

### 5.1 选型决策树

```
你的场景是什么？
│
├─ 用 Iceberg/Delta/Hudi 做湖仓？ → ✅ 选 Parquet
│     (这三个表格式都以 Parquet 为主要底层格式)
│
├─ 用 Hive ACID 做事务表？ → ✅ 选 ORC
│     (Hive ACID 只支持 ORC)
│
├─ 有大量嵌套结构（JSON-like）？ → ✅ 选 Parquet
│     (Parquet 的 Dremel 编码对嵌套类型最优)
│
├─ 主要用 Hive + Presto 查询？ → ✅ 选 ORC
│     (Hive 的 LLAP 对 ORC 有深度优化)
│
├─ 需要跨引擎兼容（Spark + Trino + Flink + Impala）？ → ✅ 选 Parquet
│     (生态兼容性 Parquet > ORC)
│
└─ 都可以？ → ✅ 默认选 Parquet
      (2024年后新项目的主流选择)
```

---

## 六、谓词下推实战验证

### 6.1 验证 Parquet 谓词下推是否生效

```python
# 写入测试数据
spark.range(10000000).withColumn("value", (col("id") % 100).cast("int")) \
    .write.mode("overwrite").parquet("/tmp/test_pushdown")

# 查询（WHERE 条件应该被下推）
df = spark.read.parquet("/tmp/test_pushdown")
result = df.filter("id > 9000000").select("id", "value")

# 查看执行计划
result.explain(True)
# 在 Physical Plan 中看到：
# PushedFilters: [IsNotNull(id), GreaterThan(id, 9000000)]
# ↑ 说明谓词已下推到 Parquet Reader 层！
```

### 6.2 验证列裁剪效果

```python
# 全列扫描（慢）
spark.read.parquet("/data").count()  # 读所有列

# 只读一列（快 5-10 倍）
spark.read.parquet("/data").select("amount").filter("amount > 100").count()
# 只读 amount 列的 Column Chunk，其他列完全跳过
```

---

## 七、压缩算法选择

| 算法 | 压缩率 | 压缩速度 | 解压速度 | 推荐场景 |
|------|--------|---------|---------|---------|
| **Zstd** | ★★★★★ | ★★★★ | ★★★★★ | **生产首选**（压缩比+速度最均衡） |
| Snappy | ★★★ | ★★★★★ | ★★★★★ | 延迟敏感（最快但压缩差） |
| Gzip | ★★★★★ | ★★ | ★★★ | 冷数据归档（最小但慢） |
| LZ4 | ★★★ | ★★★★★ | ★★★★★ | 类似 Snappy |
| Uncompressed | ★ | N/A | N/A | 调试/临时 |

**2024 年结论**：**统一用 Zstd**。Iceberg 1.4+ 默认就是 Zstd。

---

## 八、课堂练习

### 练习 1：估算 I/O 节省

> 一张表有 100 列，每列平均 10 字节。查询只需要 3 列，WHERE 条件能跳过 80% 的 Row Group。
> 全表 1TB 数据，使用 Parquet 列式存储 + 谓词下推后，实际需要读多少？

答：
- 列裁剪：1TB × (3/100) = **30GB**
- 谓词下推：30GB × (1 - 80%) = **6GB**
- 总 I/O 从 1TB → 6GB，节省 **99.4%**！

### 练习 2：举一反三

> "Parquet 的 Row Group 与 HDFS 的 Block 有什么关系？为什么建议 Row Group = HDFS Block Size？"

答：
- 如果 Row Group = 128MB = HDFS Block Size
- 则一个 Row Group 完全在一个 HDFS Block 内
- 读取时只需一次网络请求（本地读取）
- 如果 Row Group 跨 Block → 一次读取要两次网络请求 → 性能下降

### 练习 3：性能对比实验

> 用相同数据分别存为 Parquet（Zstd）和 ORC（Zstd），对比：①文件大小 ②全表 Scan 时间 ③带 WHERE 的查询时间

```python
# 写入
df.write.parquet("/test/parquet_zstd", compression="zstd")
df.write.orc("/test/orc_zstd", compression="zstd")

# 比较文件大小
!hdfs dfs -du -s -h /test/parquet_zstd
!hdfs dfs -du -s -h /test/orc_zstd

# 比较查询速度
spark.read.parquet("/test/parquet_zstd").filter("col1 > 1000").count()
spark.read.orc("/test/orc_zstd").filter("col1 > 1000").count()
```

---

## 九、知识晶体

```
问题/场景: 大数据分析场景下应该选什么文件格式？如何配置？
核心原理: 列式存储(Column Pruning) + 统计信息(Predicate Pushdown) + 高效编码(Dictionary/RLE/Zstd)
选型结论:
  - 新项目/湖仓 → Parquet + Zstd
  - Hive ACID → ORC + Zstd
  - 嵌套数据 → Parquet
  - 需要最细粒度索引 → ORC
关键配置:
  write.parquet.compression-codec = zstd
  spark.sql.parquet.filterPushdown = true
  spark.sql.parquet.enableVectorizedReader = true
  write.target-file-size-bytes = 128MB（与 HDFS Block 对齐）
踩坑记录:
  - Parquet 谓词下推只支持简单谓词（=, >, <, IN），不支持 LIKE/函数
  - 向量化读取对嵌套类型（struct/array/map）可能回退到行式
  - 文件太小（< 10MB）会导致 metadata 开销占比过大，丧失列式优势
认知更新: 列式格式的性能 = 列裁剪 × 谓词下推 × 压缩。三者缺一，效果打折。
```
