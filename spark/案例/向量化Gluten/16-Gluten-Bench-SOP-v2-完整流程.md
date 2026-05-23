# Spark Gluten Bench 测试 SOP v2 — 完整可复现操作手册

> **作者**：Eric（豹纹）  
> **版本**：v2.0（2026-05-24 凌晨）  
> **替代**：v1.0（14 号 SOP，仅含 HDFS 流程）  
> **覆盖**：HDFS + cosn 双存储 / 单集群 + 跨集群 / 4 个实验单元的完整测试方法  
> **目标**：明天换任意一个新集群，**对照本 SOP 一字不漏地抄**，**3 小时内**出 2×2 矩阵报告。  
> **已验证**：H2 集群（Hadoop 2.8.5/Hive 2.3.7）、H3 集群（Hadoop 3.3.4/Hive 3.1.3）。

---

## 〇、阅读说明

| 标记 | 含义 |
|---|---|
| `[MASTER]` | 在集群 master 节点 root 下执行 |
| `[MASTER@HADOOP]` | 在集群 master 节点 **切到 hadoop 用户**执行 |
| `[ALL-WORKERS]` | 所有 worker 节点都要执行 |
| `[LOCAL]` | 在本机（你自己的 Mac/Linux）执行 |
| ⚠️ | 一定不能漏 / 一定要看的关键点 |

**所有路径写死的约定**（与腾讯云 EMR 一致，**不要改**）：
- JDK：`/usr/local/jdk` → 软链接到 Kona JDK 11
- Spark：`/usr/local/service/spark`
- Bench 工作目录：`/home/hadoop/bench/`
- 数据库：`bench`（HDFS 用）、`bench_cosn`（cosn 用）
- cosn 桶：`cosn://lkl-bj-update-1308597516/meson/data/bench/`（**改成你自己的**）

---

## 一、总体流程图（先看清全貌）

```
┌────────────────────────────────────────────────────────────────┐
│ 阶段 1：环境准备（1 次性，每个新集群都做）                       │
│  ├─ JDK 11 部署（master + 全 worker）                          │
│  ├─ Spark 3.5.3 EMR 包部署（master）                           │
│  ├─ Gluten Velox bundle jar 部署（master）                     │
│  └─ Bench 工作目录 / SQL / 脚本部署                             │
└──────────────────────────┬─────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ 阶段 2：数据准备（2 选 1）                                       │
│  ├─ 路线 A：本集群从 0 生成 5 表 91.7G 数据（10-15 分钟）        │
│  └─ 路线 B：复用 cosn 上已有数据（建外部表，秒级）               │
└──────────────────────────┬─────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ 阶段 3：建表（按存储后端 2 选 1 或 2 个都建）                    │
│  ├─ HDFS 表（库名 bench，LOCATION hdfs:/...）                  │
│  └─ cosn 表（库名 bench_cosn，LOCATION cosn:/...）             │
└──────────────────────────┬─────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ 阶段 4：跑 Bench（每个存储后端跑 native + gluten 两轮）          │
│  ├─ HDFS 数据 → bench_all.sh native + gluten                  │
│  └─ cosn 数据 → bench_cosn.sh native + gluten                 │
└──────────────────────────┬─────────────────────────────────────┘
                           ↓
┌────────────────────────────────────────────────────────────────┐
│ 阶段 5：出报告（4 个 CSV 合并成 2×2 矩阵）                      │
└────────────────────────────────────────────────────────────────┘
```

---

## 二、阶段 1：环境准备

### 2.1 前置体检

`[MASTER]`：

```bash
# 1. JDK 版本（必须 11）
java -version 2>&1 | head -1

# 2. Hadoop 版本（2.8 / 3.3 都支持）
hadoop version 2>&1 | head -1

# 3. Hive 版本（2.3 / 3.1 都支持，但都需要修复 ETypeConverter bug，见后文）
hive --version 2>&1 | head -1

# 4. YARN 资源
yarn node -list -showDetails 2>/dev/null | grep -A2 'Configured Resources'

# 5. cosn 是否可用（如果要用对象存储）
hadoop fs -ls cosn://你的桶名/ 2>&1 | head -3
# 如果报 "No FileSystem for scheme: cosn"，需要在 core-site.xml 加 cosn 实现类（EMR 默认有）

# 6. master 内网 IP（后面脚本要用）
hostname -I | awk '{print $1}'
# 例如：172.21.240.111（H2 master）/ 172.21.240.144（H3 master）
```

⚠️ **一定要记录 master 内网 IP**，脚本里 `DRIVER_HOST` 必须改成它。

### 2.2 装 Tencent Kona JDK 11

#### 为什么必须 JDK 11
EMR 编译的 spark jar 用了 JDK 11 的 `ByteBuffer.flip()` 协变签名，JDK 8 跑会抛：
```
NoSuchMethodError: 'java.nio.ByteBuffer java.nio.ByteBuffer.flip()'
```

#### master 节点

`[MASTER]`：

```bash
# 公网下载（内网用腾讯云镜像更快）
cd /tmp
wget https://github.com/Tencent/TencentKona-11/releases/download/kona11.0.27/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz

tar -xf TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz -C /usr/local/
ln -snf /usr/local/TencentKona-11.0.27.b1 /usr/local/jdk

# 验证
/usr/local/jdk/bin/java -version
# 期望输出：openjdk version "11.0.27" ... TencentKonaJDK
```

#### 所有 worker 节点

`[ALL-WORKERS]`：

```bash
# 假设 worker hostname 是 worker1/2/3，或者 IP
for h in worker1 worker2 worker3; do
  scp /tmp/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz root@$h:/tmp/
  ssh root@$h "tar -xf /tmp/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz -C /usr/local/ && ln -snf /usr/local/TencentKona-11.0.27.b1 /usr/local/jdk && /usr/local/jdk/bin/java -version"
done
```

⚠️ **不要改全局 JAVA_HOME**！YARN ResourceManager / NodeManager 继续用集群原 JDK，只在 spark 提交时通过 `--conf spark.executorEnv.JAVA_HOME=/usr/local/jdk` 透传。否则 RM/NM 启动失败，集群崩溃（H2 集群血泪教训）。

### 2.3 部署 Spark 3.5.3

`[MASTER]`：

```bash
# 1. 拿 EMR 包（途径 3 选 1）：
#    a. 从已有 EMR 集群 scp 过来：scp root@old-master:/home/hadoop/spark.tar.gz /home/hadoop/
#    b. 从 cosn 下载：hadoop fs -copyToLocal cosn://你的桶/spark.tar.gz /home/hadoop/
#    c. 从 EMR 控制台下载

# 2. 备份 + 安装
mv /usr/local/service/spark /usr/local/service/spark.bak.$(date +%Y%m%d) 2>/dev/null

cd /usr/local/service/
tar -xf /home/hadoop/spark.tar.gz
# 解压出来的目录可能叫 spark-3.5.3-emr / spark / meson 等，查一下：
ls -la
# 假设是 spark-3.5.3-emr：
[ -d spark-3.5.3-emr ] && mv spark-3.5.3-emr spark
chown -R hadoop:hadoop spark

# 3. 验证版本
/usr/local/service/spark/bin/spark-submit --version 2>&1 | head -5
# 期望看到：Spark 3.5.3
```

### 2.4 部署 Gluten Velox bundle jar

`[MASTER]`：

```bash
# 公网下载（约 100MB）
cd /tmp
wget -O gluten.jar \
  "https://repository.apache.org/content/repositories/snapshots/org/apache/gluten/gluten-velox-bundle/1.5.0-SNAPSHOT/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar"

# 也可以直接从已部署的集群拷：
# scp root@h2-master:/usr/local/service/spark/jars/gluten-velox-bundle-*.jar /tmp/gluten.jar

mv /tmp/gluten.jar /usr/local/service/spark/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar
chown hadoop:hadoop /usr/local/service/spark/jars/gluten-velox-bundle-*.jar
```

### 2.5 部署 Bench 工作目录

#### 方式 A：从 toolkit 一键部署（推荐）

`[LOCAL]`：

```bash
cd /Users/kailongliu/CodeBuddy/20260401235241/spark/案例/向量化Gluten/bench-toolkit

# 一键部署到目标集群 master
./scripts/deploy_to_cluster.sh <new_master_ip>

# 例如 H4 集群：
./scripts/deploy_to_cluster.sh 1.2.3.4
```

#### 方式 B：手动建目录

`[MASTER@HADOOP]`：

```bash
mkdir -p /home/hadoop/bench/{gen,queries,queries_cosn,scripts,results}
```

然后从 `bench-toolkit/` 拷文件：
- `gen/*.sql` → `/home/hadoop/bench/gen/`
- `queries/*.sql` → `/home/hadoop/bench/queries/`（HDFS 库 bench 用）
- `queries_cosn/*.sql` → `/home/hadoop/bench/queries_cosn/`（cosn 库 bench_cosn 用）
- `scripts/*.sh` → `/home/hadoop/bench/scripts/`
- `ddl/external_tables.sql` → `/home/hadoop/bench/`

### 2.6 改 2 个变量（必做）

`[MASTER@HADOOP]`：

```bash
# A. 把脚本里的 DRIVER_HOST 改成本集群 master 内网 IP
MASTER_IP=$(hostname -I | awk '{print $1}')
sed -i "s|DRIVER_HOST=172.21.240.144|DRIVER_HOST=$MASTER_IP|g" /home/hadoop/bench/scripts/*.sh
grep DRIVER_HOST /home/hadoop/bench/scripts/*.sh

# B. 改 cosn 桶路径（如果你不用默认那个桶）
# 默认：cosn://lkl-bj-update-1308597516/meson/data/bench
# 改成你的桶：
NEW_COSN="cosn://你的桶/your-path/bench"
sed -i "s|cosn://lkl-bj-update-1308597516/meson/data/bench|$NEW_COSN|g" \
  /home/hadoop/bench/gen/*.sql \
  /home/hadoop/bench/queries_cosn/*.sql \
  /home/hadoop/bench/external_tables.sql 2>/dev/null
```

---

## 三、阶段 2：数据准备（2 选 1 或都做）

### 路线 A：本集群从 0 生成数据（约 10-15 分钟）

#### A.1 修改 `gen/_init.sql` 的 LOCATION

`[MASTER@HADOOP]`：

```bash
# 默认 _init.sql 是建在 cosn 上的，如果你想生成到 HDFS：
sed -i "s|cosn://[^']*|hdfs:///user/hadoop/bench|g" /home/hadoop/bench/gen/_init.sql
sed -i "s|cosn://[^']*|hdfs:///user/hadoop/bench|g" /home/hadoop/bench/gen/0[1-5]_*.sql
```

#### A.2 跑数据生成

`[MASTER@HADOOP]`：

```bash
cd /home/hadoop/bench
./scripts/gen_all.sh all 2>&1 | tee results/gen_all.log
```

执行顺序（已固化）：init（建库）→ customers（5kw）→ products（1kw）→ reviews（1.5亿）→ orders（4亿）→ order_items（24亿）。

⚠️ **order_items 生成必须用 `REPARTITION(800)` hint，不要用 `DISTRIBUTE BY pmod(id, N)`**——24 亿行用 N 个 partition 会把每个 partition 撑到 GB 级，executor OOM。

#### A.3 验数据

```bash
hadoop fs -du -s -h hdfs:///user/hadoop/bench/   # 期望 ~92G
hive -e "USE bench;
  SELECT 'customers',   COUNT(*) FROM customers;    -- 50000000
  SELECT 'products',    COUNT(*) FROM products;     -- 10000000
  SELECT 'reviews',     COUNT(*) FROM reviews;      -- 150000000
  SELECT 'orders',      COUNT(*) FROM orders;       -- 400000000
  SELECT 'order_items', COUNT(*) FROM order_items;  -- 2400000000"
```

⚠️ 如果 hive count 报 `UnsupportedOperationException: ETypeConverter`，那是 Hive 自己的 InputFormat bug，**不影响 Spark**——后面 spark-sql 跑 bench 时强开 `convertMetastoreParquet=true` 就 OK。

### 路线 B：复用 cosn 上已有数据（秒级）

如果你之前已经生成过数据，或者其他集群已经把数据 distcp 到 cosn 共享桶，直接建外部表用：

`[MASTER@HADOOP]`：

```bash
# 1. 验数据存在
hadoop fs -ls cosn://你的桶/your-path/bench/
# 期望看到 5 个目录：customers / products / reviews / orders / order_items

# 2. 用 spark.read.parquet 自动反推 schema（不依赖原集群 Hive 元数据）
cat > /tmp/infer_schema.scala <<'SCALAEOF'
val tables = Seq("customers","products","reviews","orders","order_items")
tables.foreach { t =>
  val df = spark.read.parquet(s"cosn://你的桶/your-path/bench/${t}")
  println(s"===TABLE: ${t}===")
  df.printSchema()
  println(s"===END ${t}===")
}
sys.exit(0)
SCALAEOF

/usr/local/service/spark/bin/spark-shell --master local[2] -i /tmp/infer_schema.scala 2>/dev/null \
  | grep -E '(TABLE:|END|^ \|--|^root)'
```

---

## 四、阶段 3：建表（HDFS 库 / cosn 库）

### 4.1 HDFS 库（数据库名 = bench）

如果走路线 A 已经生成到 HDFS，**库已经建好了**（gen_all.sh init 步骤建的），直接用即可。

如果是手动建：

```sql
CREATE DATABASE IF NOT EXISTS bench LOCATION 'hdfs:///user/hadoop/bench';
USE bench;
-- 5 张表 DDL 见 §4.3，把 LOCATION 都换成 hdfs:///user/hadoop/bench/<表名>
```

### 4.2 cosn 库（数据库名 = bench_cosn）

⚠️ **重要**：库名必须叫 `bench_cosn`，不要和 HDFS 的 `bench` 同名，否则同一个集群上想同时测两个存储就冲突了。

`[MASTER@HADOOP]`：

```bash
# /home/hadoop/bench/external_tables.sql 已经写好（库名 bench_cosn）
hive -f /home/hadoop/bench/external_tables.sql 2>&1 | tail -20
```

### 4.3 完整 5 张表 DDL（cosn 版）

⚠️ **schema 必须严格按下面来**（已用 spark.read.parquet 反推确认），列名/类型错一个就 100% 读不出来：

```sql
CREATE DATABASE IF NOT EXISTS bench_cosn LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench';
USE bench_cosn;

DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS order_items;

-- ① customers（5kw 行 / 1.1G）
CREATE EXTERNAL TABLE customers (
  customer_id BIGINT,
  username STRING,
  email STRING,
  province_id INT,
  city_id INT,
  age INT,
  gender STRING,
  vip_level INT,
  total_spent DECIMAL(12,2),
  register_date DATE,
  last_active_date DATE,
  is_active INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/customers';

-- ② products（1kw 行 / 408M）
CREATE EXTERNAL TABLE products (
  product_id BIGINT,
  sku STRING,
  product_name STRING,
  category_id INT,
  brand_id INT,
  shop_id INT,
  price DECIMAL(12,2),
  cost DECIMAL(12,2),
  stock INT,
  rating DECIMAL(3,2),
  sales_count INT,
  review_count INT,
  create_date DATE,
  is_active INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/products';

-- ③ reviews（1.5亿 / 3.0G）
CREATE EXTERNAL TABLE reviews (
  review_id BIGINT,
  customer_id BIGINT,
  product_id BIGINT,
  order_id BIGINT,
  rating INT,
  useful_count INT,
  comment_length INT,
  review_date DATE,
  is_verified INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/reviews';

-- ④ orders（4亿 / 8.2G）
CREATE EXTERNAL TABLE orders (
  order_id BIGINT,
  customer_id BIGINT,
  order_date DATE,
  order_ts TIMESTAMP,
  province_id INT,
  city_id INT,
  total_amount DECIMAL(12,2),
  discount_amount DECIMAL(8,2),
  shipping_fee DECIMAL(8,2),
  payment_method INT,
  order_status INT,
  channel_id INT,
  item_count INT,
  is_paid INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/orders';

-- ⑤ order_items（24亿 / 79.1G — 最大）
CREATE EXTERNAL TABLE order_items (
  item_id BIGINT,
  order_id BIGINT,
  product_id BIGINT,
  customer_id BIGINT,
  quantity INT,
  unit_price DECIMAL(12,2),
  item_discount DECIMAL(8,2),
  item_date DATE,
  category_id INT,
  shop_id INT,
  is_returned INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/order_items';
```

### 4.4 数据关联模型（5 表关系，画在一起）

```
                        customers (5kw)
                           │
                           │ customer_id
                           ↓
   order_items (24亿) ──── customer_id ───┐
        │                                 │
        │ product_id                      │
        ↓                                 │
    products (1kw)                        │
        │                                 │
        │                                 │
        │ order_id                        │
        ↓                                 │
    orders (4亿) ─────── customer_id ─────┘
        │                                 │
        │ order_id                        │
        │                                 │
        ↓                                 │
    reviews (1.5亿) ──── customer_id ─────┘
                  └── product_id ──→ products
```

**关联键说明**（**bench SQL 全靠这些 join key**）：

| 关联 | 左表.字段 = 右表.字段 | 说明 |
|---|---|---|
| 用户-订单 | `customers.customer_id = orders.customer_id` | 1:N |
| 订单-订单项 | `orders.order_id = order_items.order_id` | 1:N |
| 商品-订单项 | `products.product_id = order_items.product_id` | 1:N |
| 用户-订单项 | `customers.customer_id = order_items.customer_id` | 1:N（冗余字段，方便 join） |
| 用户-评论 | `customers.customer_id = reviews.customer_id` | 1:N |
| 商品-评论 | `products.product_id = reviews.product_id` | 1:N |
| 订单-评论 | `orders.order_id = reviews.order_id` | 1:N |

---

## 五、阶段 4：跑 Bench

### 5.1 4 个实验单元说明

| 单元 | 集群 | 存储 | 库 | 用脚本 | 用 query 目录 |
|---|---|---|---|---|---|
| **A** | H2 / 任意集群 | HDFS | bench | `bench_all.sh` | `queries/` |
| **B** | H2 / 任意集群 | cosn | bench_cosn | `bench_cosn.sh` | `queries_cosn/` |
| **C** | H3 / 另一集群 | cosn | bench_cosn（或 bench）| `bench_all.sh` 或 `bench_cosn.sh` | 看库名 |
| **D** | H3 / 另一集群 | HDFS | bench | `bench_all.sh` | `queries/` |

⚠️ **本质区别**：
- `bench_all.sh` 用 `queries/`（SQL 里写 `USE bench;`），跑 HDFS 库
- `bench_cosn.sh` 用 `queries_cosn/`（SQL 里写 `USE bench_cosn;`），跑 cosn 库
- **两个脚本都强制开了 `convertMetastoreParquet=true` 和 `enableVectorizedReader=true`**

### 5.2 跑 HDFS Bench（单元 A 或 D）

`[MASTER@HADOOP]`：

```bash
cd /home/hadoop/bench

# Native（约 8-10 分钟）
nohup bash scripts/bench_all.sh native > results/native_run.log 2>&1 < /dev/null &
tail -f results/native_run.log    # 看进度，结束 Ctrl+C

# Gluten（约 4-7 分钟）
nohup bash scripts/bench_all.sh gluten > results/gluten_run.log 2>&1 < /dev/null &
tail -f results/gluten_run.log
```

结果：
- `results/duration_native.csv` ← 单元 A/D Native
- `results/duration_gluten.csv` ← 单元 A/D Gluten

### 5.3 跑 cosn Bench（单元 B 或 C）

`[MASTER@HADOOP]`：

```bash
cd /home/hadoop/bench

# Native
nohup bash scripts/bench_cosn.sh native > results/cosn_native_run.log 2>&1 < /dev/null &
tail -f results/cosn_native_run.log

# Gluten
nohup bash scripts/bench_cosn.sh gluten > results/cosn_gluten_run.log 2>&1 < /dev/null &
tail -f results/cosn_gluten_run.log
```

结果：
- `results/duration_cosn_native.csv` ← 单元 B/C Native
- `results/duration_cosn_gluten.csv` ← 单元 B/C Gluten

### 5.4 ⚠️ 关键提交参数（已固化在脚本里，仅供参考）

#### Native 模式
```bash
--num-executors 9 --executor-cores 5 --executor-memory 9g --driver-memory 2g \
--conf spark.executor.memoryOverhead=2g \
--conf spark.plugins= \                                              # 显式关 Gluten
--conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager \
--conf spark.memory.offHeap.enabled=false
```

#### Gluten 模式
```bash
--num-executors 9 --executor-cores 5 --executor-memory 5g --driver-memory 2g \
--conf spark.executor.memoryOverhead=1g \
--conf spark.plugins=org.apache.gluten.GlutenPlugin \
--conf spark.gluten.sql.columnar.backend.lib=velox \
--conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
--conf spark.memory.offHeap.enabled=true \
--conf spark.memory.offHeap.size=8g \                                # ⚠️ 至少 8g
--conf spark.gluten.memory.allocator=jemalloc \
--conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 \
--conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false \
--conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false \
--conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false    # ⚠️ 必须关
```

#### 通用（两者都要）
```bash
--conf spark.executorEnv.JAVA_HOME=/usr/local/jdk \                  # ⚠️ 强制 JDK 11
--conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/local/jdk \
--conf "spark.driver.extraJavaOptions=$ADD_OPENS" \                  # ⚠️ JDK 11 反射开关
--conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
--conf spark.sql.adaptive.enabled=true \
--conf spark.sql.hive.convertMetastoreParquet=true \                 # ⚠️ Hive 兼容必开
--conf spark.sql.parquet.enableVectorizedReader=true \
--conf spark.sql.shuffle.partitions=128
```

`ADD_OPENS` 是 13 个 `--add-opens` 参数（脚本里已写死），别漏。

---

## 六、阶段 5：跨集群共享数据（distcp）

### 6.1 场景：H2 已生成数据 → 让 H3 也能用

#### 方式 1：H2 → cosn → H3 直接读（推荐，不占 H3 HDFS）

`[H2 MASTER@HADOOP]`：

```bash
hadoop distcp \
  -m 100 \
  -bandwidth 200 \
  -update \
  -strategy dynamic \
  -Dmapreduce.map.memory.mb=4096 \
  -Dmapreduce.map.java.opts=-Xmx3g \
  hdfs:///user/hadoop/bench/ \
  cosn://lkl-bj-update-1308597516/meson/data/bench/
```

实测：91.7G / 100 mapper / 200MB 限速，约 2 分钟。

`[H3 MASTER@HADOOP]`：

```bash
# 验收数据
hadoop fs -du -s -h cosn://lkl-bj-update-1308597516/meson/data/bench/

# 建外部表（指向 cosn）
hive -f /home/hadoop/bench/external_tables.sql

# 跑 cosn bench
cd /home/hadoop/bench
bash scripts/bench_cosn.sh native
bash scripts/bench_cosn.sh gluten
```

#### 方式 2：cosn → H3 HDFS（如果 H3 想测 HDFS 性能）

`[H3 MASTER@HADOOP]`：

```bash
hadoop distcp \
  -m 100 \
  -bandwidth 200 \
  cosn://lkl-bj-update-1308597516/meson/data/bench/ \
  hdfs:///user/hadoop/bench/

# 然后建 HDFS 库
hive -e "
CREATE DATABASE IF NOT EXISTS bench LOCATION 'hdfs:///user/hadoop/bench';
USE bench;
-- 把 5 张表 DDL 的 LOCATION 改成 hdfs:///user/hadoop/bench/<表名>
-- ...
"

# 跑 HDFS bench
cd /home/hadoop/bench
bash scripts/bench_all.sh native
bash scripts/bench_all.sh gluten
```

### 6.2 distcp 现象速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 命令 exit 254 但 stdout 空 | YARN client 模式不打 progress | 看 `yarn application -list -appStates FINISHED` 确认 SUCCEEDED |
| 部分文件大小不一致 | 上次残留 | 加 `-update -overwrite` |
| 写入超时 | cosn 桶限速 | 减 `-m`，加 `-bandwidth` |
| 同名目录重复（products 815M 实际 408M） | 同名 mv 冲突 | `hadoop fs -rm -r 目标` 后重传 |

---

## 七、阶段 5：出报告

### 7.1 整理 4 个 CSV

每个集群的 results 目录下：

```bash
# HDFS
results/duration_native.csv
results/duration_gluten.csv

# cosn
results/duration_cosn_native.csv
results/duration_cosn_gluten.csv
```

### 7.2 自动算加速比的命令

```bash
echo "=== HDFS ==="
paste -d, results/duration_native.csv results/duration_gluten.csv | \
  awk -F, 'NR>1 {printf "%-22s %8.1fs %8.1fs %.2fx\n", $1, $3/1000, $7/1000, $3/$7}'

echo "=== cosn ==="
paste -d, results/duration_cosn_native.csv results/duration_cosn_gluten.csv | \
  awk -F, 'NR>1 {printf "%-22s %8.1fs %8.1fs %.2fx\n", $1, $3/1000, $7/1000, $3/$7}'
```

### 7.3 性能基线（比对你跑出来的数据）

| 单元 | 集群+存储 | Native | Gluten | 加速 |
|---|---|---|---|---|
| A | H2-HDFS | 492.8s | 243.6s | **2.02×** |
| B | H2-cosn | 420.2s | 325.0s | **1.29×** |
| C | H3-cosn | 513.2s | 437.9s | **1.17×** |
| D | H3-HDFS | （未测）| | |

**判断你的集群是否健康**：
- HDFS 跑出 **1.5×–2.5×** = 正常
- cosn 跑出 **1.0×–1.5×** = 正常
- 跑出 < 1.0×（且不在 cosn）= 配置错了，先排查 `spark.plugins` 和 `shuffle.manager` 是否生效

---

## 八、踩坑速查表（按现象→根因→解法）

### 8.1 启动阶段

| 现象 | 根因 | 解法 |
|---|---|---|
| `NoSuchMethodError: ByteBuffer.flip()` | JDK 8 跑 JDK11 编译的 jar | 装 Kona JDK 11 + 提交时 `--conf spark.executorEnv.JAVA_HOME=/usr/local/jdk` |
| `IllegalAccessError` 反射 | JDK 11 模块化 | 加全套 `--add-opens`（脚本 `ADD_OPENS` 已带 13 个） |
| YARN container exit 127 | worker 缺 JDK 11 | 每个 worker 都装 Kona JDK 11 |
| `ClassNotFoundException: GlutenPlugin` | Gluten jar 不在 classpath | 确认 `/usr/local/service/spark/jars/gluten-velox-bundle-*.jar` 存在 |

### 8.2 数据读阶段（最容易踩）

| 现象 | 根因 | 解法 |
|---|---|---|
| `UnsupportedOperationException: PlainIntegerDictionary` | **Hive 3.x** + Parquet INT32 字典编码 | `--conf spark.sql.hive.convertMetastoreParquet=true` |
| `UnsupportedOperationException: ETypeConverter$8$1` | **Hive 2.3.7** + Parquet INT64 字典编码（H2 集群本次新坑）| 同上 |
| `FAILED: Execution Error, return code 2 from MapRedTask` | hive count 走 MR + Hive InputFormat | hive 直接 count 注定失败，改用 spark-sql 跑（spark 自己的 reader 正确） |
| Parquet timestamp 类型不兼容 | INT96 vs INT64 | `spark.gluten.sql.parquet.timestampType.scan.fallback.enabled=true` |
| cosn 读慢 | 单连接吞吐 | `fs.cosn.read.parallel=true` + `fs.cosn.read.parts.size=8388608` |

### 8.3 执行阶段

| 现象 | 根因 | 解法 |
|---|---|---|
| `VeloxUserError: sumVector != nullptr` | Velox 1.5 partial agg spill bug | 关 spill：`spillEnabled=false` + `aggregationSpillEnabled=false` + `joinSpillEnabled=false`，加大 offHeap 到 8g |
| `Container killed by YARN for exceeding physical memory` | partition 太大 | `REPARTITION(N)` + `spark.executor.memoryOverhead=2g` |
| `Lost task ... ExecutorLost` | offHeap 不够 | offHeap.size 加到 8g，重 query 加到 12g |
| Gluten < Native | 对象存储 IO bound | **不是 Gluten 锅**，先治 IO（Alluxio 缓存、cosn 并发读） |
| Native < 30s 的 query Gluten 倒挂 | 启动开销 > 加速收益 | 这种短查询不要上 Gluten |

### 8.4 SSH / 集群管理

| 现象 | 根因 | 解法 |
|---|---|---|
| `Permission denied (publickey,...)` 连续 | **没配 SSH 公钥免密**（不是 fail2ban）| 在目标 master 上 `echo '<public_key>' >> /root/.ssh/authorized_keys` |
| `Connection timed out` 跨 VPC | 内网不通 | 走公网 IP 或者跳板机 |
| nohup 在 ssh 中没真后台 | ssh 等所有子进程退出 | 加 `< /dev/null` 或者用 screen/tmux |

### 8.5 集群配置（铁律，不许犯！）

⚠️ **2026-05-23 H2 事故**：擅自 scp master 的 yarn-site.xml 覆盖 worker，worker NM bind master IP 失败，集群全瘫。

**铁律**：
1. 应用层配置（`spark-defaults.conf`、JDK）随便改
2. **集群层（yarn-site / hdfs-site / core-site / capacity-scheduler）改之前必须问大哥**
3. 真要改：只改 master + 备份到 `/root/yarn-site.xml.original`，**不要 scp 给 worker**
4. 改坏了**不要重启 RM/NM 试好**，立即 stop + 还原 + 求助
5. 不要"自作主张"扩资源/改调度，大哥让测什么就测什么

---

## 九、完整 Checklist（明天对着勾）

### 9.1 单集群完整 SOP（A + B 两单元）

```
□ 1. 体检：JDK 版本、Hadoop 版本、Hive 版本、master 内网 IP、cosn 可用性
□ 2. 装 Kona JDK 11（master + 全 worker）
□ 3. 装 Spark 3.5.3 EMR（master）
□ 4. 装 Gluten Velox bundle jar（master）
□ 5. deploy_to_cluster.sh 部署 toolkit
□ 6. 改 DRIVER_HOST 为本集群 master 内网 IP
□ 7. 改 cosn 桶路径（如果不用默认桶）
□ 8. （路线 A）./gen_all.sh all 生成 5 表 91.7G 数据到 HDFS（10-15 分钟）
□ 9. 验数据：hadoop fs -du / spark-sql count
□ 10. （HDFS bench）./bench_all.sh native（8-10 分钟）
□ 11. （HDFS bench）./bench_all.sh gluten（4-7 分钟）
□ 12. distcp HDFS → cosn（2 分钟）
□ 13. hive -f external_tables.sql 建 cosn 库 bench_cosn
□ 14. （cosn bench）./bench_cosn.sh native
□ 15. （cosn bench）./bench_cosn.sh gluten
□ 16. 整理 4 个 CSV，输出 2×2 矩阵报告
```

### 9.2 跨集群完整 SOP（A→B→C→D 全 4 单元）

```
□ 集群 1（H2）：完成 9.1 全部 16 步
□ distcp 数据到 cosn 共享桶（让 H3 能读）
□ 集群 2（H3）：跳过步骤 8-12（数据已在 cosn）
□ 集群 2：执行步骤 1-7、13-16
□ 如果要测 D 单元（H3-HDFS）：
   □ distcp cosn → H3 HDFS
   □ 在 H3 上建 HDFS bench 库
   □ 跑 ./bench_all.sh native + gluten
□ 整理 4 个集群×2 模式 = 8 个 CSV，输出完整 2×2 矩阵报告
```

---

## 十、目录结构 & 资产清单

```
/home/hadoop/bench/                   # 集群 master 上的工作目录
├── gen/                              # 数据生成 SQL（5 张表）
│   ├── _init.sql
│   ├── 01_customers.sql
│   ├── 02_products.sql
│   ├── 03_reviews.sql
│   ├── 04_orders.sql
│   └── 05_order_items.sql
├── queries/                          # HDFS 库 bench 用（USE bench;）
│   └── q[1-7]*.sql
├── queries_cosn/                     # cosn 库 bench_cosn 用（USE bench_cosn;）
│   └── q[1-7]*.sql                  # ← 仅库名不同，SQL 内容相同
├── scripts/
│   ├── gen_all.sh                    # 数据生成跑批（HDFS 和 cosn 都能用）
│   ├── bench_all.sh                  # HDFS 跑批（用 queries/）
│   ├── bench_cosn.sh                 # cosn 跑批（用 queries_cosn/）
│   └── deploy_to_cluster.sh          # 一键部署到目标集群
├── external_tables.sql               # cosn 外部表 DDL（建 bench_cosn 库）
└── results/                          # 自动生成
    ├── duration_native.csv           # HDFS Native 结果
    ├── duration_gluten.csv           # HDFS Gluten 结果
    ├── duration_cosn_native.csv      # cosn Native 结果
    ├── duration_cosn_gluten.csv      # cosn Gluten 结果
    ├── native/                       # HDFS Native 每条 SQL 详细日志
    ├── gluten/                       # HDFS Gluten
    ├── cosn_native/                  # cosn Native
    └── cosn_gluten/                  # cosn Gluten
```

资产位置（本机）：

```
/Users/kailongliu/CodeBuddy/20260401235241/spark/案例/向量化Gluten/
├── 11-Gluten部署实测-62.234.130.135-Hadoop2.8.5.md
├── 12-Gluten-80GB-Bench实测-62.234.130.135.md         # H2-HDFS 报告
├── 13-Gluten-横向对比-H2vsH3-Hadoop2vs3.md            # H2-HDFS vs H3-cosn
├── 14-Gluten-Bench-完整SOP-跨集群可复用.md            # SOP v1（仅 HDFS）
├── 15-Gluten-2x2矩阵完整对比-Hadoop版本x存储后端.md    # 2×2 矩阵
├── 16-Gluten-Bench-SOP-v2-完整流程.md                 # ⭐ 本文件（SOP v2）
└── bench-toolkit/                                     # 可执行资产
    ├── README.md
    ├── ddl/external_tables.sql
    ├── gen/{_init,01-05}*.sql
    ├── queries/q[1-7]*.sql
    ├── queries_cosn/q[1-7]*.sql                       # ⭐ 本次新增
    └── scripts/{gen_all,bench_all,bench_cosn,deploy_to_cluster}.sh
                                                       # ⭐ bench_cosn.sh 本次新增
```

---

## 十一、重要：明天要测的 D 单元（H3-HDFS）操作步骤

H3 上还没有 D 单元（HDFS 数据），如果明天要补：

```bash
# 在 H3 master 上以 hadoop 用户：
cd /home/hadoop/bench

# 1. distcp cosn → H3 HDFS（约 5 分钟）
hadoop distcp -m 100 -bandwidth 200 \
  cosn://lkl-bj-update-1308597516/meson/data/bench/ \
  hdfs:///user/hadoop/bench/

hadoop fs -du -s -h hdfs:///user/hadoop/bench/   # 期望 ~92G

# 2. 建 HDFS 库 bench
hive -e "
CREATE DATABASE IF NOT EXISTS bench LOCATION 'hdfs:///user/hadoop/bench';
USE bench;
-- DDL 同 external_tables.sql，但 LOCATION 改成 hdfs:///user/hadoop/bench/<表名>
-- 简单办法：复制一份 external_tables.sql 改一下
"

# 一键改：
sed 's|cosn://[^"]*/bench|hdfs:///user/hadoop/bench|g; s|bench_cosn|bench|g' \
  /home/hadoop/bench/external_tables.sql > /tmp/h3_hdfs_tables.sql
chown hadoop:hadoop /tmp/h3_hdfs_tables.sql
hive -f /tmp/h3_hdfs_tables.sql

# 3. 跑 HDFS bench
nohup bash scripts/bench_all.sh native > results/native_run.log 2>&1 < /dev/null &
nohup bash scripts/bench_all.sh gluten > results/gluten_run.log 2>&1 < /dev/null &

# 4. 期望结果范围
# Native 总耗时：450-550s（H3 32c 节点应该和 H2 16c 节点同等资源差不多）
# Gluten 加速比：预计 1.6-2.0×（同 HDFS 介质，应该接近 H2-HDFS 的 2.02×）
# 这一组数据出来后，2×2 矩阵彻底闭环
```

---

## 十二、可疑点 / 待确认（明天复测时关注）

按大哥铁律：**疑点要标记，不当结论写**。

| # | 疑点 | 当前推断 | 怎么验证 |
|---|---|---|---|
| 1 | H2-cosn Native 比 HDFS Native 快 14.7% | 推测是 distcp 重组的大文件 vs HDFS 多分区小文件 | 查 cosn 上文件数 vs HDFS 上文件数 + parquet row group 大小 |
| 2 | H3 上 Gluten q3 关 spill 后比 H2 慢 41% | 推测是 cosn IO 拖累 | 在 H3-HDFS 上跑同 query 看是否恢复 |
| 3 | q6 在 H2-cosn 上 Gluten 倒挂 0.82× | 推测 Native 太快 (32.7s) 启动开销吃掉加速 | 跑 3 次取最快值排除偶发 |
| 4 | H3 上 q1/q2/q3 Gluten 比 Native 慢 | 推测 cosn IO bound + 读 schema 开销 | 用 `spark.eventLog` 看物理计划是否真的走 Velox transformer |
| 5 | bench_cosn.sh nohup 在 ssh 中实际是同步 | 已知现象 | 用 `< /dev/null` 或 screen/tmux 真后台 |

---

**End of 16 — SOP v2 终极版。明天换集群，照抄就行。🐆**

> 大哥，这版 SOP 已经把今天踩的所有坑都焊死。明天测 D 单元只要看 §11，1 小时搞定。
