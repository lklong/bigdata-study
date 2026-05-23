# Spark Gluten + Velox 80GB Bench 完整 SOP（跨集群可复用）

> **作者**：Eric（豹纹）  
> **日期**：2026-05-24  
> **目标**：换到任意一台新的 Hadoop/EMR 集群，对照本文从 0 到出 Bench 报告。  
> **覆盖**：JDK11 安装 → Spark3.5 部署 → Gluten 部署 → 80GB 数据生成 → 7 条 Bench SQL → Native vs Gluten 对比 → 跨集群 distcp。  
> **已验证**：H2（Hadoop 2.8.5/Hive 2.3.7）、H3（Hadoop 3.3.4/Hive 3.1.3）。

---

## 〇、阅读说明

- 命令前用 `[ALL]` `[MASTER]` `[ALL-WORKERS]` 标注执行节点
- 所有路径写死 `/usr/local/service/spark`、`/usr/local/jdk`、`/home/hadoop/bench`，和腾讯云 EMR 一致
- **凡是脚本里出现的 IP（172.21.240.x）必须改成你新集群的 master IP**
- 数据库名 `bench`、对象存储桶名等可改，文中标注

---

## 一、前置体检（30 秒）

在 master 节点上执行，决定走哪条路：

```bash
# 1. JDK 版本
java -version 2>&1 | head -1
# 期望：openjdk 11.0.x（Tencent Kona JDK / OpenJDK 11 都行）
# 如果是 1.8 → 必须装 JDK 11（见第 2 章）

# 2. Hadoop / Hive 版本
hadoop version | head -2
hive --version 2>&1 | head -2

# 3. YARN 资源
yarn node -list -showDetails 2>/dev/null | grep -A2 'Configured Resources'

# 4. Spark 现有版本
ls /usr/local/service/spark/jars/ | grep -E '^spark-core' | head -1

# 5. Gluten 是否已就位
ls /usr/local/service/spark/jars/ | grep -i gluten
```

**判断决策树**：

| 现状 | 行动 |
|---|---|
| JDK 8 + Spark 3.0/3.2 + 没 Gluten | 走完第 2、3、4、5 章（全量部署） |
| JDK 11 + Spark 3.5 + 没 Gluten | 跳过 2、3，直接走 4、5 章 |
| JDK 11 + Spark 3.5 + 已有 Gluten | 跳过 2、3、4，直接走第 5 章（数据 + Bench） |
| 数据已有，只想再跑 Bench | 直接看第 8 章 |

---

## 二、安装 Tencent Kona JDK 11（必须）

### 2.1 为什么必须 JDK 11

EMR 自带的 Spark 3.5 jar 是 JDK 11 编译的，里面用了 `ByteBuffer.flip()`（JDK 9+ 协变返回类型）。JDK 8 跑会抛：
```
java.lang.NoSuchMethodError: 'java.nio.ByteBuffer java.nio.ByteBuffer.flip()'
```

### 2.2 装 Kona JDK 11（master + 所有 worker，全量都装）

```bash
# 下载（腾讯云内网通常直接给现成 rpm/tar）
# 公网下载：
wget https://github.com/Tencent/TencentKona-11/releases/download/kona11.0.27/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz
tar -xf TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz -C /usr/local/
ln -snf /usr/local/TencentKona-11.0.27.b1 /usr/local/jdk

# 验证
/usr/local/jdk/bin/java -version
# 期望：openjdk 11.0.27 ... TencentKonaJDK
```

**所有 worker 节点都要做一遍**。可以用 pssh / ansible / for 循环：

```bash
for h in worker1 worker2 worker3; do
  scp TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz $h:/tmp/
  ssh $h "tar -xf /tmp/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz -C /usr/local/ && ln -snf /usr/local/TencentKona-11.0.27.b1 /usr/local/jdk"
done
```

### 2.3 ⚠️ 不要动 YARN / HDFS 系统的 JAVA_HOME

血泪教训（2026-05-23 H2 集群事故）：把全局 `JAVA_HOME` 切到 11 会导致 ResourceManager / NodeManager 启动失败（HMon UI、JMX 等老组件依赖 JDK 8 行为）。

**正确做法**：YARN 系统继续用原来的 JDK，只在 **Spark 提交时** 通过环境变量指定 JDK 11：
```bash
export JAVA_HOME=/usr/local/jdk
--conf spark.executorEnv.JAVA_HOME=/usr/local/jdk \
--conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/local/jdk
```

---

## 三、部署 Spark 3.5（仅 master）

### 3.1 拿到 EMR 编译版 Spark 3.5.3 包

```bash
# 包名通常是 spark.tar.gz / spark-3.5.3-emr.tar.gz
# H2 集群下来的备份：/home/hadoop/spark.tar.gz
# 也可以从 EMR 控制台软件源 / 内网 cosn 取
```

### 3.2 安装到 /usr/local/service/spark

```bash
[MASTER]
# 备份原 Spark（如果有）
mv /usr/local/service/spark /usr/local/service/spark.bak.$(date +%Y%m%d)

# 解压新包
cd /usr/local/service/
tar -xf /home/hadoop/spark.tar.gz
# 假设解压出 spark-3.5.3-emr/，重命名
mv spark-3.5.3-emr spark
chown -R hadoop:hadoop spark

# 验证
/usr/local/service/spark/bin/spark-submit --version
```

### 3.3 关键配置（spark-defaults.conf）

```bash
[MASTER]
cat >> /usr/local/service/spark/conf/spark-defaults.conf <<'EOF'

# === Gluten 必须 ===
spark.plugins                                     org.apache.gluten.GlutenPlugin
spark.gluten.sql.columnar.backend.lib             velox
spark.shuffle.manager                             org.apache.spark.shuffle.sort.ColumnarShuffleManager
spark.memory.offHeap.enabled                      true
spark.memory.offHeap.size                         8g
spark.gluten.memory.allocator                     jemalloc

# === 关 Velox spill（规避 1.5 sumVector bug）===
spark.gluten.sql.columnar.backend.velox.spillEnabled            false
spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled false
spark.gluten.sql.columnar.backend.velox.joinSpillEnabled        false

# === Hive Parquet 兼容（H3/Hive3 必须）===
spark.sql.hive.convertMetastoreParquet            true
spark.sql.parquet.enableVectorizedReader          true

# === JDK 11 反射 ===
# 注意：bench_all.sh 已经在提交时透传，这里写不写都行
EOF
```

> ⚠️ **不要把上面 Gluten 配置写到全局 spark-defaults**，否则普通 Spark Hive 作业会被殃及。**生产推荐**只在 Bench 脚本提交时透传。本 SOP 的 `bench_all.sh` 已经这么做。

---

## 四、部署 Gluten Velox bundle jar

### 4.1 下载 bundle jar

Spark 3.5 + Velox 后端 + Linux x86_64：

```bash
# 公网（Apache 官方仓库）
wget https://repository.apache.org/content/repositories/snapshots/org/apache/gluten/gluten-velox-bundle/1.5.0-SNAPSHOT/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar \
  -O /usr/local/service/spark/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar

# 或腾讯云内网镜像 / 自建 nexus

chown hadoop:hadoop /usr/local/service/spark/jars/gluten-velox-bundle-*.jar
```

### 4.2 验证 Gluten 加载（不带数据）

```bash
[MASTER]
su - hadoop -c '/usr/local/service/spark/bin/spark-shell --master local[2] \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.gluten.sql.columnar.backend.lib=velox \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=2g \
  -e "spark.sql(\"select 1+1\").show()"' 2>&1 | grep -iE '(gluten|velox|GlutenPlugin)' | head -5
```

期望看到 `Gluten plugin initialized` / `velox` 字样，没有 stack trace 即成功。

---

## 五、准备 Bench 数据集（5 表 / 91.7GB）

### 5.1 目录结构（master 节点）

```bash
[MASTER]
su - hadoop
mkdir -p /home/hadoop/bench/{gen,queries,scripts,results}
```

### 5.2 数据生成 SQL（5 个文件）

#### 5.2.1 `/home/hadoop/bench/gen/_init.sql`

> ⚠️ 把 `LOCATION` 中的 cosn 桶 / HDFS 路径改成你新集群的目标路径。

```sql
SET spark.sql.adaptive.enabled=true;
SET spark.sql.adaptive.coalescePartitions.enabled=true;
SET spark.sql.parquet.compression.codec=snappy;

DROP DATABASE IF EXISTS bench CASCADE;
-- HDFS 版本
-- CREATE DATABASE bench LOCATION 'hdfs:///user/hadoop/bench';
-- COSN 版本（推荐：跨集群可共享）
CREATE DATABASE bench LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench';
USE bench;
```

#### 5.2.2 `/home/hadoop/bench/gen/01_customers.sql`（5 千万行 / 1.1G）

```sql
SET spark.sql.shuffle.partitions=60;
USE bench;
CREATE TABLE bench.customers USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/customers'
AS
SELECT
  id AS customer_id,
  CONCAT('user_', id) AS username,
  CONCAT('user_', id, '@example.com') AS email,
  CAST(pmod(hash(id), 34) AS INT) AS province_id,
  CAST(pmod(hash(id, 'city'), 300) + 1 AS INT) AS city_id,
  CAST(pmod(hash(id, 'age'), 50) + 18 AS INT) AS age,
  CASE WHEN pmod(id, 2) = 0 THEN 'M' ELSE 'F' END AS gender,
  CAST(pmod(hash(id, 'vip'), 10) AS INT) AS vip_level,
  CAST(rand(42) * 100000 AS DECIMAL(12,2)) AS total_spent,
  date_add('2020-01-01', CAST(pmod(id, 2200) AS INT)) AS register_date,
  date_add('2024-01-01', CAST(pmod(id, 800) AS INT)) AS last_active_date,
  CAST(pmod(id, 2) AS INT) AS is_active
FROM range(50000000)
DISTRIBUTE BY pmod(id, 60);
```

#### 5.2.3 `/home/hadoop/bench/gen/02_products.sql`（1 千万行 / 408M）

```sql
SET spark.sql.shuffle.partitions=40;
USE bench;
CREATE TABLE bench.products USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/products'
AS
SELECT
  id AS product_id,
  CONCAT('sku_', id) AS sku,
  CONCAT('product_name_', id) AS product_name,
  CAST(pmod(hash(id, 'cat'), 50) AS INT) AS category_id,
  CAST(pmod(hash(id, 'brand'), 2000) AS INT) AS brand_id,
  CAST(pmod(hash(id, 'shop'), 50000) AS INT) AS shop_id,
  CAST(rand(11) * 9000 + 100 AS DECIMAL(12,2)) AS price,
  CAST(rand(12) * 9000 AS DECIMAL(12,2)) AS cost,
  CAST(rand(13) * 100000 AS INT) AS stock,
  CAST(rand(14) * 5 AS DECIMAL(3,2)) AS rating,
  CAST(rand(15) * 100000 AS INT) AS sales_count,
  CAST(rand(16) * 50000 AS INT) AS review_count,
  date_add('2020-01-01', CAST(pmod(id, 2000) AS INT)) AS create_date,
  CAST(pmod(id, 2) AS INT) AS is_active
FROM range(10000000)
DISTRIBUTE BY pmod(id, 40);
```

#### 5.2.4 `/home/hadoop/bench/gen/03_reviews.sql`（1.5 亿行 / 3.0G）

```sql
SET spark.sql.shuffle.partitions=80;
USE bench;
CREATE TABLE bench.reviews USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/reviews'
AS
SELECT
  id AS review_id,
  pmod(hash(id, 'cust'), 50000000L) AS customer_id,
  pmod(hash(id, 'prod'), 10000000L) AS product_id,
  pmod(id, 400000000L) AS order_id,
  CAST(rand(41) * 5 + 1 AS INT) AS rating,
  CAST(rand(42) * 500 AS INT) AS useful_count,
  CAST(rand(43) * 100 AS INT) AS comment_length,
  date_add('2024-01-01', CAST(pmod(id, 700) AS INT)) AS review_date,
  CAST(pmod(id, 2) AS INT) AS is_verified
FROM range(150000000)
DISTRIBUTE BY pmod(id, 80);
```

#### 5.2.5 `/home/hadoop/bench/gen/04_orders.sql`（4 亿行 / 8.2G）

```sql
SET spark.sql.shuffle.partitions=200;
USE bench;
CREATE TABLE bench.orders USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/orders'
AS
SELECT
  id AS order_id,
  pmod(hash(id, 'cust'), 50000000L) AS customer_id,
  date_add('2024-01-01', CAST(pmod(id, 700) AS INT)) AS order_date,
  CAST(unix_timestamp('2024-01-01') + pmod(id, 700) * 86400 + pmod(id, 86400) AS TIMESTAMP) AS order_ts,
  CAST(pmod(hash(id, 'prov'), 34) AS INT) AS province_id,
  CAST(pmod(hash(id, 'city'), 300) AS INT) AS city_id,
  CAST(rand(21) * 9999 + 1 AS DECIMAL(12,2)) AS total_amount,
  CAST(rand(22) * 100 AS DECIMAL(8,2)) AS discount_amount,
  CAST(rand(23) * 30 + 1 AS DECIMAL(8,2)) AS shipping_fee,
  CAST(pmod(hash(id, 'pay'), 5) AS INT) AS payment_method,
  CAST(pmod(hash(id, 'st'), 6) AS INT) AS order_status,
  CAST(pmod(hash(id, 'chan'), 8) AS INT) AS channel_id,
  CAST(rand(24) * 10 + 1 AS INT) AS item_count,
  CAST(pmod(id, 2) AS INT) AS is_paid
FROM range(400000000)
DISTRIBUTE BY pmod(id, 200);
```

#### 5.2.6 `/home/hadoop/bench/gen/05_order_items.sql`（24 亿行 / 79.1G — 最大表）

```sql
SET spark.sql.shuffle.partitions=1600;
USE bench;

DROP TABLE IF EXISTS bench.order_items;

CREATE TABLE bench.order_items USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/order_items'
AS
SELECT /*+ REPARTITION(800) */
  id AS item_id,
  pmod(id, 400000000L) AS order_id,
  pmod(hash(id, 'prod'), 10000000L) AS product_id,
  pmod(hash(id, 'cust'), 50000000L) AS customer_id,
  CAST(rand(31) * 5 + 1 AS INT) AS quantity,
  CAST(rand(32) * 1000 + 10 AS DECIMAL(12,2)) AS unit_price,
  CAST(rand(33) * 100 AS DECIMAL(8,2)) AS item_discount,
  date_add('2024-01-01', CAST(pmod(id, 700) AS INT)) AS item_date,
  CAST(pmod(hash(id, 'cat'), 50) AS INT) AS category_id,
  CAST(pmod(hash(id, 'shop'), 50000) AS INT) AS shop_id,
  CAST(pmod(id, 2) AS INT) AS is_returned
FROM range(2400000000);
```

> ⚠️ **order_items OOM 防御**：用 `REPARTITION(800)` hint 替代 `DISTRIBUTE BY`，**别用 DISTRIBUTE BY pmod(id, 400)**，会把 24 亿行挤到 400 个超大 partition，每个 5GB+ 直接写爆 executor。

### 5.3 数据生成跑批脚本 `/home/hadoop/bench/scripts/gen_all.sh`

```bash
#!/bin/bash
# 5 张表数据生成（按从小到大顺序）
# 用法：./gen_all.sh [init|1|2|3|4|5|all]
set -e
export JAVA_HOME=/usr/local/jdk
export PATH=$JAVA_HOME/bin:$PATH
export SPARK_HOME=/usr/local/service/spark
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop

ADD_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

# !!! 改成你的 master 内网 IP !!!
DRIVER_HOST=172.21.240.144

BENCH_DIR=/home/hadoop/bench
mkdir -p $BENCH_DIR/results

run_sql() {
  local label="$1"
  local sql="$2"
  local extra_conf="$3"
  echo "=========== run $label ==========="
  local START=$(date +%s)
  $SPARK_HOME/bin/spark-sql \
    --master yarn --deploy-mode client \
    --num-executors 9 --executor-cores 5 --executor-memory 9g --driver-memory 2g --conf spark.executor.memoryOverhead=2g \
    --conf spark.driver.host=$DRIVER_HOST \
    --conf spark.shuffle.service.enabled=false \
    --conf spark.dynamicAllocation.enabled=false \
    --conf spark.executorEnv.JAVA_HOME=/usr/local/jdk \
    --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/local/jdk \
    --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
    --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
    --conf spark.eventLog.enabled=false \
    $extra_conf \
    -f "$sql" 2>&1 | tee "$BENCH_DIR/results/${label}.log" | tail -40
  local END=$(date +%s)
  echo "${label} DURATION = $((END-START))s" | tee -a "$BENCH_DIR/results/duration.txt"
}

# 数据生成必须 Native 跑（关 Gluten plugin，避免 Velox writer 不全的问题）
GEN_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false --conf spark.sql.parquet.compression.codec=snappy"

case "$1" in
  init) run_sql "gen_init" "$BENCH_DIR/gen/_init.sql" "$GEN_CONF" ;;
  1) run_sql "gen_01_customers" "$BENCH_DIR/gen/01_customers.sql" "$GEN_CONF" ;;
  2) run_sql "gen_02_products" "$BENCH_DIR/gen/02_products.sql" "$GEN_CONF" ;;
  3) run_sql "gen_03_reviews" "$BENCH_DIR/gen/03_reviews.sql" "$GEN_CONF" ;;
  4) run_sql "gen_04_orders" "$BENCH_DIR/gen/04_orders.sql" "$GEN_CONF" ;;
  5) run_sql "gen_05_order_items" "$BENCH_DIR/gen/05_order_items.sql" "$GEN_CONF" ;;
  ''|all)
    run_sql "gen_init"            "$BENCH_DIR/gen/_init.sql"            "$GEN_CONF"
    run_sql "gen_01_customers"    "$BENCH_DIR/gen/01_customers.sql"     "$GEN_CONF"
    run_sql "gen_02_products"     "$BENCH_DIR/gen/02_products.sql"      "$GEN_CONF"
    run_sql "gen_03_reviews"      "$BENCH_DIR/gen/03_reviews.sql"       "$GEN_CONF"
    run_sql "gen_04_orders"       "$BENCH_DIR/gen/04_orders.sql"        "$GEN_CONF"
    run_sql "gen_05_order_items"  "$BENCH_DIR/gen/05_order_items.sql"   "$GEN_CONF"
    ;;
  *) echo "用法: $0 [init|1|2|3|4|5|all]"; exit 1 ;;
esac
```

```bash
chmod +x /home/hadoop/bench/scripts/gen_all.sh
```

### 5.4 执行数据生成

```bash
[MASTER, hadoop user]
cd /home/hadoop/bench
./scripts/gen_all.sh all 2>&1 | tee results/gen_all.log
# 80GB 数据生成总耗时：8-15 分钟（取决于集群规模和存储后端）
```

### 5.5 生成完毕后验证

```bash
hadoop fs -du -s -h cosn://lkl-bj-update-1308597516/meson/data/bench/
# 期望：~92G

hive -e "USE bench; SHOW TABLES;
  SELECT 'customers', COUNT(*) FROM customers;
  SELECT 'products', COUNT(*) FROM products;
  SELECT 'reviews', COUNT(*) FROM reviews;
  SELECT 'orders', COUNT(*) FROM orders;
  SELECT 'order_items', COUNT(*) FROM order_items;"
# 期望：50000000 / 10000000 / 150000000 / 400000000 / 2400000000
```

---

## 六、外部表建表 DDL（共享数据时用）

> 适用场景：**集群 A 已生成好数据，集群 B 想直接用**（数据放 cosn 共享）。

### 6.1 自动反推 schema（推荐，不依赖原集群）

如果不知道字段名，用 spark.read.parquet 直接读 schema：

```bash
cat > /tmp/infer_schema.scala <<'SCALAEOF'
val tables = Seq("customers","products","reviews","orders","order_items")
tables.foreach { t =>
  val df = spark.read.parquet(s"cosn://lkl-bj-update-1308597516/meson/data/bench/${t}")
  println(s"===TABLE: ${t}===")
  df.printSchema()
  println(s"===END ${t}===")
}
sys.exit(0)
SCALAEOF

su - hadoop -c '/usr/local/service/spark/bin/spark-shell --master local[2] -i /tmp/infer_schema.scala 2>/dev/null' \
  | grep -E '(TABLE:|END|^ \|--|^root)'
```

### 6.2 完整建表 DDL（直接抄）

```sql
CREATE DATABASE IF NOT EXISTS bench;
USE bench;

DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS order_items;

-- ① customers
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

-- ② products
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

-- ③ reviews
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

-- ④ orders
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

-- ⑤ order_items
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

> 把上面整段保存为 `/tmp/h3_create_tables.sql`，执行：
> ```bash
> chown hadoop:hadoop /tmp/h3_create_tables.sql
> su - hadoop -c 'hive -f /tmp/h3_create_tables.sql'
> ```

---

## 七、7 条 Bench SQL（业务真实场景模型）

完整放在 `/home/hadoop/bench/queries/`：

| 文件 | 类型 | 触及表 | 复杂度 |
|---|---|---|---|
| q1_agg.sql | 单表大宽聚合 | orders（4亿） | filter + group by + 9 聚合（含 stddev） |
| q2_join_2tables.sql | 双表 join | orders ⋈ customers | 4亿 ⋈ 5kw + count distinct |
| q3_join_3tables.sql | 三表 join | order_items ⋈ products ⋈ customers | 24亿 ⋈ 1kw ⋈ 5kw |
| q4_window.sql | 窗口 + TopN | orders ⋈ customers + Window | row_number / dense_rank / avg over |
| q5_subquery.sql | CTE + 子查询 | products + reviews + order_items | CTE + IN 子查询 + having |
| q6_self_join.sql | self join + LAG | orders self | 复购间隔分析 |
| q7_5tables.sql | 5 表全 join | order_items ⋈ orders ⋈ products ⋈ customers ⋈ reviews | 4 inner + 1 left join + having |

### 7.1 完整 SQL 全文

#### `queries/q1_agg.sql`
```sql
USE bench;
SELECT
  province_id,
  date_format(order_date, 'yyyy-MM') AS month,
  channel_id,
  COUNT(*) AS order_cnt,
  SUM(total_amount) AS total_gmv,
  AVG(total_amount) AS avg_amount,
  SUM(discount_amount) AS total_discount,
  MAX(total_amount) AS max_amount,
  MIN(total_amount) AS min_amount,
  STDDEV(total_amount) AS stddev_amount
FROM orders
WHERE order_date BETWEEN '2024-06-01' AND '2025-06-30'
GROUP BY province_id, date_format(order_date, 'yyyy-MM'), channel_id
ORDER BY total_gmv DESC
LIMIT 50;
```

#### `queries/q2_join_2tables.sql`
```sql
USE bench;
SELECT
  c.gender,
  c.vip_level,
  CASE
    WHEN c.age < 25 THEN '<25'
    WHEN c.age < 35 THEN '25-35'
    WHEN c.age < 50 THEN '35-50'
    ELSE '50+'
  END AS age_group,
  COUNT(DISTINCT o.customer_id) AS uv,
  COUNT(*) AS order_cnt,
  SUM(o.total_amount) AS gmv,
  AVG(o.total_amount) AS avg_order_value
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date BETWEEN '2024-06-01' AND '2025-12-31'
  AND o.is_paid = 1
GROUP BY c.gender, c.vip_level,
  CASE
    WHEN c.age < 25 THEN '<25'
    WHEN c.age < 35 THEN '25-35'
    WHEN c.age < 50 THEN '35-50'
    ELSE '50+'
  END
ORDER BY gmv DESC;
```

#### `queries/q3_join_3tables.sql`
```sql
USE bench;
SELECT
  p.category_id,
  c.gender,
  COUNT(*) AS item_cnt,
  COUNT(DISTINCT oi.customer_id) AS unique_buyers,
  SUM(oi.quantity) AS total_qty,
  SUM(oi.unit_price * oi.quantity) AS gross_amount,
  AVG(p.price) AS avg_product_price
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN customers c ON oi.customer_id = c.customer_id
WHERE oi.item_date BETWEEN '2024-06-01' AND '2025-06-30'
  AND oi.is_returned = 0
GROUP BY p.category_id, c.gender
ORDER BY gross_amount DESC
LIMIT 100;
```

#### `queries/q4_window.sql`
```sql
USE bench;
WITH user_gmv AS (
  SELECT
    o.customer_id,
    c.province_id,
    c.vip_level,
    SUM(o.total_amount) AS user_gmv,
    COUNT(*) AS order_cnt
  FROM orders o
  JOIN customers c ON o.customer_id = c.customer_id
  WHERE o.is_paid = 1
    AND o.order_date BETWEEN '2024-01-01' AND '2025-12-31'
  GROUP BY o.customer_id, c.province_id, c.vip_level
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY province_id ORDER BY user_gmv DESC) AS rn,
    DENSE_RANK() OVER (PARTITION BY province_id ORDER BY vip_level DESC) AS vip_rank,
    AVG(user_gmv) OVER (PARTITION BY province_id) AS province_avg_gmv
  FROM user_gmv
)
SELECT province_id, customer_id, user_gmv, order_cnt, vip_rank, province_avg_gmv
FROM ranked
WHERE rn <= 10
ORDER BY province_id, rn;
```

#### `queries/q5_subquery.sql`
```sql
USE bench;
WITH product_review AS (
  SELECT
    r.product_id,
    AVG(r.rating) AS avg_rating,
    COUNT(*) AS review_cnt,
    SUM(r.useful_count) AS total_useful
  FROM reviews r
  WHERE r.is_verified = 1
  GROUP BY r.product_id
),
hot_products AS (
  SELECT product_id
  FROM order_items
  WHERE item_date BETWEEN '2024-06-01' AND '2025-06-30'
  GROUP BY product_id
  HAVING COUNT(*) > 100
)
SELECT
  p.product_id,
  p.product_name,
  p.category_id,
  p.brand_id,
  p.price,
  p.sales_count,
  pr.avg_rating,
  pr.review_cnt,
  pr.total_useful
FROM products p
JOIN product_review pr ON p.product_id = pr.product_id
WHERE pr.avg_rating >= 4.0
  AND pr.review_cnt >= 50
  AND p.sales_count < 5000
  AND p.product_id IN (SELECT product_id FROM hot_products)
  AND p.is_active = 1
ORDER BY pr.avg_rating DESC, pr.total_useful DESC
LIMIT 200;
```

#### `queries/q6_self_join.sql`
```sql
USE bench;
WITH order_seq AS (
  SELECT
    customer_id,
    order_id,
    order_date,
    total_amount,
    LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS prev_order_date,
    LAG(total_amount) OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS prev_amount
  FROM orders
  WHERE is_paid = 1
    AND order_date BETWEEN '2024-06-01' AND '2025-06-30'
)
SELECT
  CASE
    WHEN datediff(order_date, prev_order_date) <= 7 THEN '0-7d'
    WHEN datediff(order_date, prev_order_date) <= 30 THEN '8-30d'
    WHEN datediff(order_date, prev_order_date) <= 90 THEN '31-90d'
    ELSE '>90d'
  END AS gap_bucket,
  COUNT(*) AS repurchase_cnt,
  AVG(total_amount) AS avg_curr_amount,
  AVG(prev_amount) AS avg_prev_amount,
  AVG(total_amount - prev_amount) AS avg_amount_diff
FROM order_seq
WHERE prev_order_date IS NOT NULL
GROUP BY 1
ORDER BY 1;
```

#### `queries/q7_5tables.sql`
```sql
USE bench;
SELECT
  p.category_id,
  c.province_id,
  COUNT(DISTINCT oi.product_id) AS unique_products,
  COUNT(DISTINCT oi.customer_id) AS unique_buyers,
  COUNT(DISTINCT oi.order_id) AS unique_orders,
  SUM(oi.unit_price * oi.quantity) AS gross_amount,
  AVG(o.total_amount) AS avg_order_amount,
  AVG(r.rating) AS avg_rating,
  COUNT(r.review_id) AS review_cnt
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN products p ON oi.product_id = p.product_id
JOIN customers c ON oi.customer_id = c.customer_id
LEFT JOIN reviews r ON r.order_id = oi.order_id AND r.product_id = oi.product_id
WHERE oi.item_date BETWEEN '2024-06-01' AND '2025-06-30'
  AND oi.is_returned = 0
  AND o.is_paid = 1
GROUP BY p.category_id, c.province_id
HAVING COUNT(*) > 1000
ORDER BY gross_amount DESC
LIMIT 100;
```

---

## 八、Bench 跑批脚本 `bench_all.sh`（最终版，含所有踩坑修复）

`/home/hadoop/bench/scripts/bench_all.sh`：

```bash
#!/bin/bash
# Bench 7 条 SQL，分 native / gluten 两轮
# 用法：./bench_all.sh native | gluten [可选 query 列表]
# 例如：./bench_all.sh gluten q3_join_3tables
set -e
export JAVA_HOME=/usr/local/jdk
export PATH=$JAVA_HOME/bin:$PATH
export SPARK_HOME=/usr/local/service/spark
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop

# !!! 改成你的 master 内网 IP !!!
DRIVER_HOST=172.21.240.144

MODE=${1:-native}
BENCH_DIR=/home/hadoop/bench
LOGDIR=$BENCH_DIR/results/$MODE
mkdir -p $LOGDIR

# JDK 11 反射开关，必须传给 driver 和 executor
ADD_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

# YARN 总 48c96g（可按集群调整 num-executors / executor-cores / memory）
if [ "$MODE" = "native" ]; then
  RES="--num-executors 9 --executor-cores 5 --executor-memory 9g --driver-memory 2g --conf spark.executor.memoryOverhead=2g"
  EXTRA_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false"
else
  # Gluten: heap 5g + offHeap 8g + overhead 1g = 14g/executor，9 个 executor
  RES="--num-executors 9 --executor-cores 5 --executor-memory 5g --driver-memory 2g --conf spark.executor.memoryOverhead=1g"
  EXTRA_CONF="--conf spark.plugins=org.apache.gluten.GlutenPlugin \
    --conf spark.gluten.sql.columnar.backend.lib=velox \
    --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
    --conf spark.memory.offHeap.enabled=true \
    --conf spark.memory.offHeap.size=8g \
    --conf spark.gluten.memory.allocator=jemalloc \
    --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 \
    --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false \
    --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false \
    --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false"
fi

run_q() {
  local q=$1
  echo "========== $MODE / $q =========="
  local START=$(date +%s%3N)
  set +e
  $SPARK_HOME/bin/spark-sql \
    --master yarn --deploy-mode client \
    $RES \
    --conf spark.driver.host=$DRIVER_HOST \
    --conf spark.shuffle.service.enabled=false \
    --conf spark.dynamicAllocation.enabled=false \
    --conf spark.executorEnv.JAVA_HOME=/usr/local/jdk \
    --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/local/jdk \
    --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
    --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
    --conf spark.eventLog.enabled=false \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.hive.convertMetastoreParquet=true \
    --conf spark.sql.parquet.enableVectorizedReader=true \
    --conf spark.sql.shuffle.partitions=128 \
    $EXTRA_CONF \
    -f "$BENCH_DIR/queries/${q}.sql" > "$LOGDIR/${q}.log" 2>&1
  local RC=$?
  set -e
  local END=$(date +%s%3N)
  local DUR=$(( (END-START) ))
  echo "$q,$MODE,$DUR,$RC" >> "$BENCH_DIR/results/duration_${MODE}.csv"
  if [ $RC -eq 0 ]; then
    echo "  ✓ ${DUR}ms"
  else
    echo "  ✗ FAIL (rc=$RC) - tail of log:"
    tail -8 "$LOGDIR/${q}.log"
  fi
}

echo 'q,mode,duration_ms,rc' > $BENCH_DIR/results/duration_${MODE}.csv

QS=${2:-"q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables"}
for q in $QS; do
  run_q $q
done

echo
echo "====== $MODE 全部完成 ======"
cat $BENCH_DIR/results/duration_${MODE}.csv
```

```bash
chmod +x /home/hadoop/bench/scripts/bench_all.sh
```

### 8.1 启动 Bench

```bash
[MASTER, hadoop user]
cd /home/hadoop/bench

# 第一轮：Native
nohup bash scripts/bench_all.sh native > results/native_run.log 2>&1 &

# 等 native 跑完（10-15 分钟）
tail -f results/native_run.log

# 第二轮：Gluten
nohup bash scripts/bench_all.sh gluten > results/gluten_run.log 2>&1 &
```

### 8.2 查结果

```bash
# 两个 CSV：
cat results/duration_native.csv
cat results/duration_gluten.csv

# 计算每条 query 的加速比：
paste -d, results/duration_native.csv results/duration_gluten.csv | \
  awk -F, 'NR>1 {printf "%-22s %8.1fs %8.1fs %.2fx\n", $1, $3/1000, $7/1000, $3/$7}'
```

---

## 九、跨集群数据同步（distcp）

> 场景：H2 集群已生成数据，要给 H3 集群用，**用 cosn 当中转 + 共享存储**。

### 9.1 H2 上 distcp 到 cosn

```bash
[MASTER@H2, hadoop user]
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

> 91.7G / 100 mapper / 200MB 限速，**实测耗时 ~2 分钟**。

### 9.2 H3 上验收 + 建外部表

```bash
[MASTER@H3, hadoop user]
# 1. 看数据齐没齐
hadoop fs -ls cosn://lkl-bj-update-1308597516/meson/data/bench/
hadoop fs -du -s -h cosn://lkl-bj-update-1308597516/meson/data/bench/

# 2. 反推 schema（见 §6.1）
# 3. 建外部表（见 §6.2）

# 4. 验行数
hive -e "USE bench;
  SELECT 'customers', COUNT(*) FROM customers;
  SELECT 'order_items', COUNT(*) FROM order_items;"
```

### 9.3 distcp 常见现象

| 现象 | 原因 | 处理 |
|---|---|---|
| 命令 exit 254 但 stdout 空 | YARN client 模式默认不打 progress | 看 `yarn application -list -appStates FINISHED` 确认 SUCCEEDED |
| 部分文件大小不一致 | 上一次 distcp 残留 | 加 `-update -overwrite` 强制覆盖 |
| cosn 写入超时 | 桶限速 | 减小 `-m`、加 `-bandwidth` |
| products 重复 815M（实际 408M） | 同名文件被复制两次 | `hadoop fs -rm -r 目标目录` 后重传 |

---

## 十、故障排查速查表（按现象→根因→解法）

### 10.1 启动阶段

| 现象 | 根因 | 解法 |
|---|---|---|
| `NoSuchMethodError: ByteBuffer.flip()` | JDK 8 跑 JDK11 编译的 spark jar | 装 Kona JDK 11 + 提交时 `--conf spark.executorEnv.JAVA_HOME=/usr/local/jdk` |
| `IllegalAccessError` 反射 | JDK 11 模块化 | 加 `--add-opens` 全套（脚本里已带 `ADD_OPENS`） |
| YARN container exit 127 | worker 缺 JDK 11 | **每个 worker** 都装 Kona JDK 11 |
| `ClassNotFoundException: org.apache.gluten.GlutenPlugin` | gluten jar 未在 classpath | 确认 `/usr/local/service/spark/jars/gluten-*.jar` 存在 |

### 10.2 数据读阶段

| 现象 | 根因 | 解法 |
|---|---|---|
| `UnsupportedOperationException: PlainIntegerDictionary` | Hive 3.x InputFormat + Parquet 1.10 字典编码 bug | `--conf spark.sql.hive.convertMetastoreParquet=true` |
| Parquet timestamp 类型不兼容 | INT96 vs INT64 | `spark.gluten.sql.parquet.timestampType.scan.fallback.enabled=true` |
| cosn 读慢得吓人 | 单连接吞吐有限 | 加并发：`fs.cosn.read.parallel=true`、`fs.cosn.read.parts.size=8388608` |

### 10.3 执行阶段

| 现象 | 根因 | 解法 |
|---|---|---|
| `VeloxUserError: sumVector != nullptr` | Velox 1.5 partial agg spill bug | 关 spill：`spillEnabled=false` + `aggregationSpillEnabled=false` + `joinSpillEnabled=false`，加大 `offHeap.size=8g` |
| `Container killed by YARN for exceeding physical memory limits` | 大 partition + 没留 overhead | `REPARTITION(N)` + `spark.executor.memoryOverhead=2g` |
| `Lost task ... ExecutorLost` | offHeap 不够 | 加 offHeap 到 8g 起步；执行规模大时上 12g |
| Gluten 加速比 < 1（比 Native 慢） | 对象存储 IO bound | **不是 Gluten 的锅**，先治 IO（Alluxio 缓存、cosn 并发读） |

### 10.4 集群配置（强烈警告）

> ⚠️ **2026-05-23 H2 事故**：擅自 scp master 的 `yarn-site.xml` 覆盖 worker，worker NM 试图 bind master IP 失败，集群全瘫。

**铁律**：
1. 应用层配置（`spark-defaults.conf`、JDK 路径）随便改没事
2. **集群层配置（`yarn-site.xml` / `hdfs-site.xml` / `core-site.xml`）改之前必须问大哥**
3. 如果一定要改，**只改 master + 备份到 `/root/yarn-site.xml.original`**，**不要 scp 到 worker**（主从 NM hostname/address 可能本来就不同）
4. 改坏了不要靠"重启 RM/NM 试好"，立即 stop + 还原 + 求助

---

## 十一、目录结构 & 资产清单

```
/home/hadoop/bench/
├── gen/
│   ├── _init.sql                 # 库 + 优化参数
│   ├── 01_customers.sql          # 5kw 行
│   ├── 02_products.sql           # 1kw 行
│   ├── 03_reviews.sql            # 1.5亿
│   ├── 04_orders.sql             # 4亿
│   └── 05_order_items.sql        # 24亿（最大）
├── queries/
│   ├── q1_agg.sql
│   ├── q2_join_2tables.sql
│   ├── q3_join_3tables.sql
│   ├── q4_window.sql
│   ├── q5_subquery.sql
│   ├── q6_self_join.sql
│   └── q7_5tables.sql
├── scripts/
│   ├── gen_all.sh                # 数据生成
│   └── bench_all.sh              # Bench 跑批
└── results/                      # 自动生成
    ├── duration_native.csv
    ├── duration_gluten.csv
    ├── native/                   # 每条 SQL 详细日志
    └── gluten/
```

---

## 十二、跨集群部署 Checklist（拿来对照打勾）

新集群从 0 到出 Bench 报告，用这个清单：

```
□ 1. 检查 JDK 版本（≥11）
□ 2. 装 Tencent Kona JDK 11 到 master + 所有 worker
□ 3. 部署 Spark 3.5.x EMR 包到 /usr/local/service/spark
□ 4. 下载 Gluten 1.5+ velox bundle jar 到 spark/jars/
□ 5. 创建 /home/hadoop/bench 目录树
□ 6. 写入 gen/{_init,01,02,03,04,05}.sql（5 张表 DDL+INSERT）
□ 7. 写入 queries/q1-q7.sql（7 条 Bench SQL）
□ 8. 写入 scripts/{gen_all,bench_all}.sh（2 个跑批脚本）
□ 9. 修改 scripts 里的 DRIVER_HOST 为本集群 master IP
□ 10. 修改 gen/*.sql 里的 LOCATION 路径（cosn 桶名 / HDFS 路径）
□ 11. ./gen_all.sh all 生成 5 张表（耗时 ~10 分钟）
□ 12. 验数据：hadoop fs -du / hive count(*)
□ 13. ./bench_all.sh native 跑 native 一轮（耗时 ~10 分钟）
□ 14. ./bench_all.sh gluten 跑 gluten 一轮（耗时 ~7 分钟）
□ 15. 整理 duration_native.csv vs duration_gluten.csv，算加速比
□ 16. 跨集群共享：distcp 到 cosn，对端集群按 §6.2 建外部表
```

---

## 十三、性能数据基线（对照参考）

| 集群 | 存储 | Native 总耗时 | Gluten 总耗时 | 加速比 |
|---|---|---|---|---|
| H2（Hadoop2.8.5 / 3worker × 16c32g） | HDFS | 492.8s | 243.6s | **2.02×** |
| H3（Hadoop3.3.4 / 3worker × 32c128g）| cosn | 513.2s | 437.9s | **1.17×** |
| AWS Labs（v1.5+Velox） | TPC-DS 1TB | - | - | 1.72× |
| 美团（Gluten+Velox） | 数万节点产线 | - | - | 1.7-2× |

**判断你的新集群是否健康**：
- HDFS 跑出 1.5×–2.5× = 正常
- cosn 跑出 1.0×–1.5× = 正常
- 跑出 < 1.0× 且不在 cosn = 配置有问题，先排查 spark.plugins / shuffle.manager 是否生效

---

## 十四、改进路线图

| 优先级 | 事项 | 收益 |
|---|---|---|
| P0 | 升级 Gluten 1.5-SNAPSHOT → 1.6 | 修 sumVector spill bug，q3 加速可恢复到 2.0×+ |
| P1 | cosn 集群上 Alluxio 做缓存层 | H3 加速比从 1.17× 拉到 1.7×+ |
| P1 | TPC-DS 1TB 标准 Bench | 跟 AWS / 美团 横向可比 |
| P2 | 接 Prometheus 监控 Gluten 关键指标 | gluten_offheap_used / fallback_count / native_execution_ratio |
| P2 | 黑盒一致性测试（行数+md5）覆盖 SQL Top 100 | 生产灰度前置 |

---

**End of 14 — 跨集群可复用 SOP。从此别的集群上手，半小时内出 Bench 报告。🐆**
