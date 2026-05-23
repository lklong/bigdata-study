# Spark Gluten Bench Toolkit

完整可复用资产包，覆盖 80GB 5 表 Bench 全流程。

## 目录结构

```
bench-toolkit/
├── README.md                       # 本文件
├── gen/                            # 数据生成 SQL
│   ├── _init.sql                   # 库 + 优化参数
│   ├── 01_customers.sql            # 5kw 行 / 1.1G
│   ├── 02_products.sql             # 1kw 行 / 408M
│   ├── 03_reviews.sql              # 1.5亿 / 3.0G
│   ├── 04_orders.sql               # 4亿 / 8.2G
│   └── 05_order_items.sql          # 24亿 / 79.1G（最大）
├── queries/                        # 7 条 Bench SQL
│   ├── q1_agg.sql                  # 单表大宽聚合
│   ├── q2_join_2tables.sql         # 2 表 join
│   ├── q3_join_3tables.sql         # 3 表 join
│   ├── q4_window.sql               # 窗口函数 TopN
│   ├── q5_subquery.sql             # CTE + 子查询
│   ├── q6_self_join.sql            # self join + LAG
│   └── q7_5tables.sql              # 5 表全 join
├── scripts/                        # 跑批脚本
│   ├── gen_all.sh                  # 数据生成
│   ├── bench_all.sh                # Native vs Gluten 对比 Bench
│   └── deploy_to_cluster.sh        # 一键部署到目标集群
└── ddl/
    └── external_tables.sql         # 共享 cosn 数据时建外部表
```

## 三步上手（新集群部署）

### 1. 一键部署到目标集群

```bash
# 在本地执行（前提：你能 ssh root@<master_ip> 免密）
./scripts/deploy_to_cluster.sh 101.43.161.139
```

脚本会自动：
- 在远端 master 上建 `/home/hadoop/bench/{gen,queries,scripts,results}`
- 拷贝所有 SQL/脚本/DDL
- 设置权限和 owner=hadoop

### 2. 在远端 master 上改 2 个变量

```bash
ssh root@<master_ip>

# A. 改脚本里的 master 内网 IP
vi /home/hadoop/bench/scripts/gen_all.sh    # 第 14 行 DRIVER_HOST
vi /home/hadoop/bench/scripts/bench_all.sh  # 第 14 行 DRIVER_HOST

# B. 改 SQL 里的 LOCATION 路径（如果不用默认 cosn 桶）
sed -i 's|cosn://lkl-bj-update-1308597516/meson|你的桶路径|g' \
  /home/hadoop/bench/gen/*.sql \
  /home/hadoop/bench/external_tables.sql
```

### 3. 跑批

```bash
su - hadoop
cd /home/hadoop/bench

# 生成 80GB 数据（10-15 分钟）
./scripts/gen_all.sh all

# Native 一轮
./scripts/bench_all.sh native

# Gluten 一轮
./scripts/bench_all.sh gluten

# 看结果
cat results/duration_native.csv
cat results/duration_gluten.csv
```

## 共享数据场景

如果数据已经放在 cosn 上（其他集群已经生成过），直接建外部表用：

```bash
hive -f /home/hadoop/bench/external_tables.sql
```

## 关键配置（脚本里已写死）

### Native 模式
- 9 executor × 5c × 9g heap + 2g overhead
- spark.plugins=（空，关闭 Gluten）
- spark.shuffle.manager=SortShuffleManager

### Gluten 模式
- 9 executor × 5c × 5g heap + 8g offHeap + 1g overhead
- spark.plugins=org.apache.gluten.GlutenPlugin
- spark.shuffle.manager=ColumnarShuffleManager
- **关 Velox spill**（避开 1.5 sumVector bug）

### 通用
- JDK 11（KonaJDK 11 推荐）
- spark.sql.hive.convertMetastoreParquet=true（**Hive 3.x 必须**）
- spark.sql.parquet.enableVectorizedReader=true

## 期望性能基线

| 集群 | 存储 | Native 总耗时 | Gluten 总耗时 | 加速比 |
|---|---|---|---|---|
| Hadoop2.8.5 / 3w × 16c32g | HDFS | 492.8s | 243.6s | **2.02×** |
| Hadoop3.3.4 / 3w × 32c128g | cosn | 513.2s | 437.9s | **1.17×** |

## 故障排查

详见 `../14-Gluten-Bench-完整SOP-跨集群可复用.md` 第十章。

## 资料

- SOP 完整版：`../14-Gluten-Bench-完整SOP-跨集群可复用.md`
- H2 实测报告：`../12-Gluten-80GB-Bench实测-62.234.130.135.md`
- H3 横向对比：`../13-Gluten-横向对比-H2vsH3-Hadoop2vs3.md`
