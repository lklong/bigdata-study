# Spark Gluten Bench Toolkit v2

完整可复用资产包，覆盖 80GB 5 表 Bench 全流程。**v2 升级：支持 HDFS + cosn 双存储，2×2 矩阵实验**。

## 目录结构

```
bench-toolkit/
├── README.md                       # 本文件
├── gen/                            # 数据生成 SQL（5 张表）
│   ├── _init.sql                   # 库 + 优化参数
│   ├── 01_customers.sql            # 5kw 行 / 1.1G
│   ├── 02_products.sql             # 1kw 行 / 408M
│   ├── 03_reviews.sql              # 1.5亿 / 3.0G
│   ├── 04_orders.sql               # 4亿 / 8.2G
│   └── 05_order_items.sql          # 24亿 / 79.1G（最大）
├── queries/                        # 7 条 Bench SQL（用 HDFS 库 bench）
│   ├── q1_agg.sql                  # 单表大宽聚合
│   ├── q2_join_2tables.sql         # 2 表 join
│   ├── q3_join_3tables.sql         # 3 表 join
│   ├── q4_window.sql               # 窗口函数 TopN
│   ├── q5_subquery.sql             # CTE + 子查询
│   ├── q6_self_join.sql            # self join + LAG
│   └── q7_5tables.sql              # 5 表全 join
├── queries_cosn/                   # ⭐ v2 新增：7 条 Bench SQL（用 cosn 库 bench_cosn）
│   └── q[1-7]*.sql                 # 内容同 queries/，仅 USE 子句不同
├── scripts/
│   ├── gen_all.sh                  # 数据生成
│   ├── bench_all.sh                # HDFS Bench 跑批（用 queries/）
│   ├── bench_cosn.sh               # ⭐ v2 新增：cosn Bench 跑批（用 queries_cosn/）
│   └── deploy_to_cluster.sh        # 一键部署到目标集群
└── ddl/
    └── external_tables.sql         # cosn 外部表 DDL（建 bench_cosn 库）
```

## 三步上手（新集群部署）

### 1. 一键部署到目标集群

```bash
# 在本地执行（前提：你能 ssh root@<master_ip> 免密）
./scripts/deploy_to_cluster.sh 1.2.3.4
```

### 2. 在远端 master 上改 2 个变量

```bash
ssh root@<master_ip>

# A. 改脚本里的 master 内网 IP
MASTER_IP=$(hostname -I | awk '{print $1}')
sed -i "s|DRIVER_HOST=172.21.240.144|DRIVER_HOST=$MASTER_IP|g" /home/hadoop/bench/scripts/*.sh

# B. 改 SQL 里的 cosn 桶路径（如果不用默认桶）
sed -i 's|cosn://lkl-bj-update-1308597516/meson/data/bench|你的桶路径|g' \
  /home/hadoop/bench/gen/*.sql \
  /home/hadoop/bench/queries_cosn/*.sql \
  /home/hadoop/bench/external_tables.sql
```

### 3. 跑 Bench

```bash
su - hadoop
cd /home/hadoop/bench

# === HDFS Bench（单元 A 或 D） ===
./scripts/gen_all.sh all                # 生成 80GB 数据到 HDFS（10-15 分钟）
./scripts/bench_all.sh native           # HDFS Native（8-10 分钟）
./scripts/bench_all.sh gluten           # HDFS Gluten（4-7 分钟）

# === cosn Bench（单元 B 或 C） ===
# 先把数据 distcp 到 cosn
hadoop distcp -m 100 -bandwidth 200 \
  hdfs:///user/hadoop/bench/ cosn://你的桶/your-path/bench/

# 建 cosn 外部表
hive -f external_tables.sql

# 跑 cosn bench
./scripts/bench_cosn.sh native
./scripts/bench_cosn.sh gluten

# === 看结果 ===
cat results/duration_native.csv         # HDFS Native
cat results/duration_gluten.csv         # HDFS Gluten
cat results/duration_cosn_native.csv    # cosn Native
cat results/duration_cosn_gluten.csv    # cosn Gluten
```

## 共享数据场景

如果数据已经在 cosn 上（其他集群已生成），跳过数据生成，直接：

```bash
# 1. 验证数据存在
hadoop fs -du -s -h cosn://你的桶/your-path/bench/

# 2. 建外部表
hive -f /home/hadoop/bench/external_tables.sql

# 3. 跑 cosn bench（不需要 HDFS 数据）
./scripts/bench_cosn.sh native
./scripts/bench_cosn.sh gluten
```

## 4 个实验单元（2×2 矩阵）

| 单元 | 集群 | 存储 | 库 | 用脚本 | 用 query 目录 |
|---|---|---|---|---|---|
| **A** | 集群 1 | HDFS | bench | bench_all.sh | queries/ |
| **B** | 集群 1 | cosn | bench_cosn | bench_cosn.sh | queries_cosn/ |
| **C** | 集群 2 | cosn | bench_cosn | bench_cosn.sh | queries_cosn/ |
| **D** | 集群 2 | HDFS | bench | bench_all.sh | queries/ |

## 关键配置（脚本里已写死，不用动）

### Native
- 9 executor × 5c × 9g heap + 2g overhead
- spark.plugins=（关 Gluten）
- SortShuffleManager

### Gluten
- 9 executor × 5c × 5g heap + 8g offHeap + 1g overhead
- spark.plugins=org.apache.gluten.GlutenPlugin
- ColumnarShuffleManager
- **关 Velox spill**（避开 1.5 sumVector bug）

### 通用必加（v2 新加，针对 Hive 兼容）
- spark.sql.hive.convertMetastoreParquet=true（**Hive 2.3.7 / 3.1.3 都必须**）
- spark.sql.parquet.enableVectorizedReader=true

## 期望性能基线

| 单元 | 集群+存储 | Native | Gluten | 加速 |
|---|---|---|---|---|
| A | H2-HDFS | 492.8s | 243.6s | **2.02×** |
| B | H2-cosn | 420.2s | 325.0s | **1.29×** |
| C | H3-cosn | 513.2s | 437.9s | **1.17×** |
| D | H3-HDFS | （未测） | | |

## 关键洞察

1. **存储后端 >> Hadoop 版本**：HDFS→cosn 加速比掉 36%，H2→H3 只掉 9%
2. **cosn Native 反而比 HDFS Native 快**（H2 上）：distcp 大文件读 vs HDFS 多分区小文件
3. **cosn 上 Gluten 加速稳定 1.2-1.3×**，无论 H2/H3
4. **计算密集型 query 不怕 cosn**：q5/q4 在 cosn 上仍有 1.5-1.7× 加速
5. **Native < 30s 的 query 别上 Gluten**：启动开销吃掉加速

## 故障排查

详见 SOP v2 主文档 `../16-Gluten-Bench-SOP-v2-完整流程.md` 第八章。

最高频 3 个坑（必看）：

| 坑 | 现象 | 解法 |
|---|---|---|
| 1 | `UnsupportedOperationException: ETypeConverter` | `--conf spark.sql.hive.convertMetastoreParquet=true`（脚本里已加） |
| 2 | `VeloxUserError: sumVector != nullptr` | 关 spill（脚本里已加） |
| 3 | `NoSuchMethodError: ByteBuffer.flip()` | 装 Kona JDK 11 + 透传 spark.executorEnv.JAVA_HOME |

## 资料

- SOP v2（终极版）：`../16-Gluten-Bench-SOP-v2-完整流程.md`
- 2×2 矩阵报告：`../15-Gluten-2x2矩阵完整对比-Hadoop版本x存储后端.md`
- H2-HDFS 实测报告：`../12-Gluten-80GB-Bench实测-62.234.130.135.md`
- 横向对比报告：`../13-Gluten-横向对比-H2vsH3-Hadoop2vs3.md`
