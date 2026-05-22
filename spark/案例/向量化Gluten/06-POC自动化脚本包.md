# Gluten POC 自动化脚本包（专题 5）

> **沉淀来源**：明天上机用——不用现敲，直接拷贝执行  
> **使用前提**：先按《Hadoop28集群POC速成手册》完成 Step 1-3 部署 ⭐

---

## 〇、脚本包目录

```
/opt/spark-poc/
├── spark/                          ← Spark 3.5 安装目录（Step 2 完成）
├── scripts/
│   ├── 01-precheck.sh              ← 部署前依赖巡检
│   ├── 02-deploy.sh                ← 一键部署 Spark+Gluten
│   ├── 03-verify.sh                ← 验证 Gluten 生效
│   ├── 04-bench.sh                 ← Benchmark 对比
│   ├── 05-consistency.sh           ← 一致性校验
│   └── 99-rollback.sh              ← 一键回滚
├── queries/                        ← 你的测试 SQL
│   ├── q1.sql
│   ├── q2.sql
│   └── ...
├── results/                        ← 输出结果
└── README.md
```

---

## 一、01-precheck.sh — 部署前巡检

```bash
#!/bin/bash
# 用法: ./01-precheck.sh
# 作用: 检查 Gateway 机是否满足 Gluten 部署要求

set -e

echo "==================================================="
echo "  Gluten POC 部署前巡检 (8 项)"
echo "==================================================="

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
check_warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
check_fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# 1. CPU AVX2
echo "[1/8] 检查 CPU AVX2..."
if grep -wE "avx2" /proc/cpuinfo > /dev/null; then
    check_pass "AVX2 支持"
else
    check_fail "缺 AVX2，无法运行 Velox"
fi

# 2. CPU 架构
echo "[2/8] 检查 CPU 架构..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) check_pass "x86_64 (推荐)" ;;
    aarch64) check_warn "aarch64 (SIMD 收益打折)" ;;
    *) check_fail "$ARCH 不支持" ;;
esac

# 3. OS
echo "[3/8] 检查 OS..."
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
        ubuntu)
            [[ "$VERSION_ID" == "20.04" || "$VERSION_ID" == "22.04" ]] \
                && check_pass "Ubuntu $VERSION_ID" \
                || check_warn "Ubuntu $VERSION_ID 不在官方列表"
            ;;
        centos|rocky|almalinux)
            [[ "$VERSION_ID" =~ ^[78] ]] \
                && check_pass "$NAME $VERSION_ID" \
                || check_warn "$NAME $VERSION_ID 不在官方列表"
            ;;
        *) check_warn "$NAME 不在官方列表，可能要静态构建" ;;
    esac
else
    check_fail "无法识别 OS"
fi

# 4. 内存
echo "[4/8] 检查内存..."
MEM=$(free -g | awk 'NR==2 {print $2}')
[[ $MEM -ge 16 ]] && check_pass "${MEM}GB" || check_warn "${MEM}GB <16GB"

# 5. JDK
echo "[5/8] 检查 JDK..."
if java -version 2>&1 | head -1 | grep -qE '"(1\.8|11|17)'; then
    JAVA_VER=$(java -version 2>&1 | head -1)
    check_pass "$JAVA_VER"
else
    check_fail "JDK 不支持，需 1.8/11/17"
fi

# 6. HADOOP_HOME
echo "[6/8] 检查 HADOOP_HOME..."
if [[ -n "$HADOOP_HOME" && -d "$HADOOP_HOME" ]]; then
    check_pass "HADOOP_HOME=$HADOOP_HOME"
    if [[ -f "$HADOOP_HOME/lib/native/libhdfs.so" ]]; then
        check_pass "libhdfs.so 存在"
    else
        check_warn "libhdfs.so 不存在（Velox 会用 libhdfs3）"
    fi
else
    check_warn "HADOOP_HOME 未设置（短路读会失效）"
fi

# 7. HDFS 可达性
echo "[7/8] 检查 HDFS 可达..."
if hdfs dfs -ls / > /dev/null 2>&1; then
    check_pass "HDFS 可访问"
else
    check_warn "HDFS 不可达（可能是 Kerberos 未 kinit）"
fi

# 8. YARN 可达性
echo "[8/8] 检查 YARN 可达..."
if yarn application -list > /dev/null 2>&1; then
    check_pass "YARN 可访问"
else
    check_warn "YARN 不可达"
fi

echo ""
echo "==================================================="
echo "  巡检结果: ✅ ${PASS} 通过 | ⚠️ ${WARN} 警告 | ❌ ${FAIL} 失败"
echo "==================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "❌ 有 ${FAIL} 项硬性失败，需要先解决"
    exit 1
elif [[ $WARN -gt 3 ]]; then
    echo "⚠️ 警告较多，建议确认环境后再部署"
    exit 2
else
    echo "✅ 可以继续部署 Gluten"
    exit 0
fi
```

---

## 二、02-deploy.sh — 一键部署

```bash
#!/bin/bash
# 用法: sudo ./02-deploy.sh [hadoop_conf_dir]
# 作用: 在 /opt/spark-poc 下部署 Spark 3.5 + Gluten 1.5

set -e

INSTALL_DIR=${INSTALL_DIR:-/opt/spark-poc}
SPARK_VERSION=${SPARK_VERSION:-3.5.5}
GLUTEN_VERSION=${GLUTEN_VERSION:-1.5.0}
HADOOP_CONF=${1:-/etc/hadoop/conf}
JAVA_HOME_PATH=${JAVA_HOME:-/usr/lib/jvm/java-1.8.0-openjdk}

# 自动识别 OS（CentOS 7 / Ubuntu 22）
. /etc/os-release
case "$ID" in
    ubuntu) OS_TAG="ubuntu_${VERSION_ID}" ;;
    centos|rocky|almalinux) OS_TAG="centos_${VERSION_ID%%.*}" ;;
    *) echo "OS 不支持，请手动选择 Gluten jar"; exit 1 ;;
esac

GLUTEN_JAR="gluten-velox-bundle-spark${SPARK_VERSION%.*}_2.12-${OS_TAG}_x86_64-${GLUTEN_VERSION}.jar"

echo "===== Gluten POC 部署 ====="
echo "目标目录: $INSTALL_DIR"
echo "Spark:    $SPARK_VERSION"
echo "Gluten:   $GLUTEN_VERSION"
echo "OS Tag:   $OS_TAG"
echo "Hadoop 配置: $HADOOP_CONF"

mkdir -p $INSTALL_DIR && cd $INSTALL_DIR

# 1. 下载 Spark
if [[ ! -d "spark-${SPARK_VERSION}-bin-hadoop3" ]]; then
    echo "[1/4] 下载 Spark ${SPARK_VERSION}..."
    wget -q --show-progress \
      "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz"
    tar -xzf spark-${SPARK_VERSION}-bin-hadoop3.tgz
fi
[[ -L spark ]] || ln -s spark-${SPARK_VERSION}-bin-hadoop3 spark

# 2. 下载 Gluten
if [[ ! -f "$GLUTEN_JAR" ]]; then
    echo "[2/4] 下载 Gluten ${GLUTEN_VERSION}..."
    wget -q --show-progress \
      "https://github.com/apache/incubator-gluten/releases/download/v${GLUTEN_VERSION}/${GLUTEN_JAR}" \
      || { echo "❌ 下载失败，请手动下载 $GLUTEN_JAR"; exit 1; }
fi
cp $GLUTEN_JAR spark/jars/

# 3. 写 spark-env.sh
echo "[3/4] 写入 spark-env.sh..."
cat > spark/conf/spark-env.sh <<EOF
#!/usr/bin/env bash
export HADOOP_CONF_DIR=$HADOOP_CONF
export YARN_CONF_DIR=$HADOOP_CONF
export JAVA_HOME=$JAVA_HOME_PATH
EOF
chmod +x spark/conf/spark-env.sh

# 4. 写 spark-defaults.conf（默认 Gluten 关闭，按需启用）
echo "[4/4] 写入 spark-defaults.conf..."
cat > spark/conf/spark-defaults.conf <<'EOF'
# === 默认配置 ===
spark.hadoop.ipc.client.fallback-to-simple-auth-allowed   true

# === Gluten 默认关闭（用 --conf 启用，避免影响所有作业）===
# spark.plugins                                              org.apache.gluten.GlutenPlugin
# spark.memory.offHeap.enabled                              true
# spark.memory.offHeap.size                                 4g
# spark.shuffle.manager                                     org.apache.spark.shuffle.sort.ColumnarShuffleManager

# === 通用优化 ===
spark.sql.adaptive.enabled                               true
spark.sql.adaptive.coalescePartitions.enabled            true

# === 防 OOM 预设（Gluten 启用时使用）===
spark.gluten.memory.allocator                            jemalloc
spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio  0.5

# === JDK 17 兼容（如果用 17，取消注释）===
# spark.driver.extraJavaOptions   --add-opens=java.base/java.nio=ALL-UNNAMED
# spark.executor.extraJavaOptions --add-opens=java.base/java.nio=ALL-UNNAMED
EOF

echo ""
echo "===== ✅ 部署完成 ====="
echo "SPARK_HOME=$INSTALL_DIR/spark"
echo "下一步: source 环境变量"
echo "    export SPARK_HOME=$INSTALL_DIR/spark"
echo "    export PATH=\$SPARK_HOME/bin:\$PATH"
```

---

## 三、03-verify.sh — 验证 Gluten 生效

```bash
#!/bin/bash
# 用法: ./03-verify.sh
# 作用: 用 EXPLAIN 验证 Gluten 真的拦截了 Spark 物理计划

export SPARK_HOME=${SPARK_HOME:-/opt/spark-poc/spark}

# 简化测试 SQL（用 range 不依赖任何表）
TEST_SQL="EXPLAIN SELECT count(*), avg(id) FROM range(0, 1000000) GROUP BY id % 10"

echo "===== 验证 Gluten 生效 ====="
echo ""
echo "--- 1. 原生 Spark EXPLAIN ---"
$SPARK_HOME/bin/spark-sql --master local[2] -e "$TEST_SQL" 2>/dev/null

echo ""
echo "--- 2. Gluten 启用后 EXPLAIN ---"
$SPARK_HOME/bin/spark-sql --master local[2] \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=2g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  -e "$TEST_SQL" 2>/dev/null > /tmp/gluten_explain.out

cat /tmp/gluten_explain.out

echo ""
echo "===== 检查关键节点 ====="
if grep -E "Velox|Transformer" /tmp/gluten_explain.out > /dev/null; then
    echo "✅ Gluten 生效！发现以下关键节点："
    grep -E "Velox|Transformer" /tmp/gluten_explain.out | head -10
else
    echo "❌ Gluten 未生效，物理计划中没有 Velox*/Transformer 节点"
    echo "   排查方向："
    echo "   1. 检查 jar 是否在 spark/jars/ 下"
    echo "   2. 检查 spark.plugins 配置"
    echo "   3. 看 stderr 有没有报错"
fi
```

---

## 四、04-bench.sh — Benchmark 对比

```bash
#!/bin/bash
# 用法: ./04-bench.sh <sql_file> [queue] [num_executors]
# 作用: 同一个 SQL 跑两遍，对比 Native Spark vs Gluten

set -e

export SPARK_HOME=${SPARK_HOME:-/opt/spark-poc/spark}

SQL_FILE=${1:?"用法: 04-bench.sh <sql文件> [queue] [num_executors]"}
QUEUE=${2:-default}
NUM_EXECUTORS=${3:-8}

[[ ! -f "$SQL_FILE" ]] && { echo "SQL 文件不存在: $SQL_FILE"; exit 1; }

RESULT_DIR=${RESULT_DIR:-/opt/spark-poc/results}
mkdir -p $RESULT_DIR
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SQL_NAME=$(basename $SQL_FILE .sql)

NATIVE_LOG=$RESULT_DIR/${SQL_NAME}_native_${TIMESTAMP}.log
GLUTEN_LOG=$RESULT_DIR/${SQL_NAME}_gluten_${TIMESTAMP}.log

# 共同配置
COMMON_OPTS="--master yarn --deploy-mode client --queue ${QUEUE} \
             --num-executors ${NUM_EXECUTORS} --executor-cores 4 --executor-memory 16g \
             --driver-memory 4g"

echo "===== Benchmark: $SQL_NAME ====="
echo "队列: $QUEUE | Executors: $NUM_EXECUTORS"
echo ""

# 1. 原生 Spark
echo "[1/2] 运行原生 Spark..."
START=$(date +%s)
$SPARK_HOME/bin/spark-sql $COMMON_OPTS -f $SQL_FILE > $NATIVE_LOG 2>&1 || \
    { echo "❌ 原生 Spark 失败，看日志: $NATIVE_LOG"; exit 1; }
END=$(date +%s)
NATIVE_TIME=$((END - START))
echo "  ⏱  ${NATIVE_TIME}s"

# 2. Gluten
echo "[2/2] 运行 Gluten + Velox..."
START=$(date +%s)
$SPARK_HOME/bin/spark-sql $COMMON_OPTS \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=8g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf spark.gluten.memory.allocator=jemalloc \
  --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 \
  -f $SQL_FILE > $GLUTEN_LOG 2>&1 || \
    { echo "❌ Gluten 失败，看日志: $GLUTEN_LOG"; exit 1; }
END=$(date +%s)
GLUTEN_TIME=$((END - START))
echo "  ⏱  ${GLUTEN_TIME}s"

# 加速比
SPEEDUP=$(echo "scale=2; ${NATIVE_TIME} / ${GLUTEN_TIME}" | bc)

# 一致性
NATIVE_OUT=$(grep -v "^[A-Z][a-z]*:" $NATIVE_LOG | tail -50 | md5sum | awk '{print $1}')
GLUTEN_OUT=$(grep -v "^[A-Z][a-z]*:" $GLUTEN_LOG | tail -50 | md5sum | awk '{print $1}')

# 输出报告
REPORT=$RESULT_DIR/${SQL_NAME}_report_${TIMESTAMP}.md
cat > $REPORT <<EOF
# Benchmark Report: $SQL_NAME

- **时间**: $(date)
- **队列**: $QUEUE
- **Executors**: $NUM_EXECUTORS

| 指标 | Native Spark | Gluten + Velox | 加速比 |
|------|-------------|----------------|--------|
| 耗时 | ${NATIVE_TIME}s | ${GLUTEN_TIME}s | **${SPEEDUP}x** |

| 项 | Native | Gluten | 一致 |
|---|---|---|---|
| 输出 md5 | \`${NATIVE_OUT}\` | \`${GLUTEN_OUT}\` | $([[ "$NATIVE_OUT" == "$GLUTEN_OUT" ]] && echo "✅" || echo "❌") |

详细日志:
- Native: $NATIVE_LOG
- Gluten: $GLUTEN_LOG
EOF

echo ""
echo "===== 📊 结果 ====="
echo "Native:    ${NATIVE_TIME}s"
echo "Gluten:    ${GLUTEN_TIME}s"
echo "加速比:    ${SPEEDUP}x"
echo "报告:      $REPORT"
[[ "$NATIVE_OUT" == "$GLUTEN_OUT" ]] && echo "一致性:    ✅" || echo "一致性:    ❌"
```

---

## 五、05-consistency.sh — 一致性校验

```bash
#!/bin/bash
# 用法: ./05-consistency.sh <table> <partition_filter>
# 作用: 对比 Native vs Gluten 读同一张表，行数 + 每列 crc32 加和

set -e

export SPARK_HOME=${SPARK_HOME:-/opt/spark-poc/spark}

TABLE=${1:?"用法: 05-consistency.sh <db.table> <partition_filter>"}
FILTER=${2:-"1=1"}

# 自动从 Hive Metastore 读列名
COLS=$($SPARK_HOME/bin/spark-sql -e "DESCRIBE $TABLE" 2>/dev/null | \
       awk '{print $1}' | grep -vE "^(#|col_name|$)" | head -20)

# 拼一致性 SQL
SUM_EXPRS=""
for col in $COLS; do
    SUM_EXPRS="${SUM_EXPRS}sum(crc32(cast($col AS string))) AS sum_$col, "
done
SUM_EXPRS=${SUM_EXPRS%, }

CONSISTENCY_SQL="SELECT count(*) AS row_cnt, $SUM_EXPRS FROM $TABLE WHERE $FILTER"

echo "===== 一致性校验: $TABLE ====="
echo "过滤: $FILTER"
echo ""

# 原生
echo "[1/2] 原生 Spark..."
NATIVE=$($SPARK_HOME/bin/spark-sql --master yarn -e "$CONSISTENCY_SQL" 2>/dev/null | tail -1)

# Gluten
echo "[2/2] Gluten..."
GLUTEN=$($SPARK_HOME/bin/spark-sql --master yarn \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=8g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  -e "$CONSISTENCY_SQL" 2>/dev/null | tail -1)

echo ""
echo "Native:  $NATIVE"
echo "Gluten:  $GLUTEN"

if [[ "$NATIVE" == "$GLUTEN" ]]; then
    echo "✅ 完全一致"
    exit 0
else
    echo "❌ 不一致！排查："
    echo "  1. EXPLAIN 看 Gluten 是否 fallback"
    echo "  2. 检查列里是否有 float/double（精度问题）"
    echo "  3. 检查是否有 UDF（fallback 可能引入差异）"
    exit 1
fi
```

---

## 六、99-rollback.sh — 一键回滚

```bash
#!/bin/bash
# 用法: ./99-rollback.sh
# 作用: 回滚到原生 Spark（去掉 Gluten 配置，但保留部署目录）

export SPARK_HOME=${SPARK_HOME:-/opt/spark-poc/spark}

echo "===== Gluten 回滚 ====="
echo "1. 备份当前 spark-defaults.conf..."
cp $SPARK_HOME/conf/spark-defaults.conf $SPARK_HOME/conf/spark-defaults.conf.bak.$(date +%s)

echo "2. 注释掉所有 Gluten 配置..."
sed -i 's/^spark\.plugins.*org\.apache\.gluten\.GlutenPlugin/# &/' $SPARK_HOME/conf/spark-defaults.conf
sed -i 's/^spark\.memory\.offHeap/# &/' $SPARK_HOME/conf/spark-defaults.conf
sed -i 's/^spark\.shuffle\.manager.*ColumnarShuffleManager/# &/' $SPARK_HOME/conf/spark-defaults.conf
sed -i 's/^spark\.gluten/# &/' $SPARK_HOME/conf/spark-defaults.conf

echo "3. 验证..."
$SPARK_HOME/bin/spark-sql --master local[2] -e "SELECT 1" 2>/dev/null

echo ""
echo "✅ 已回滚到原生 Spark"
echo "如需重新启用 Gluten，编辑 $SPARK_HOME/conf/spark-defaults.conf 取消注释"
```

---

## 七、queries/ 目录示例 SQL 模板

### 7.1 q1.sql — 大聚合（Gluten 加速最明显）
```sql
SELECT
  category,
  count(*) AS cnt,
  sum(amount) AS total,
  avg(amount) AS avg_amt
FROM your_db.fact_table
WHERE dt >= '2026-05-01'
GROUP BY category
ORDER BY total DESC
LIMIT 100;
```

### 7.2 q2.sql — Join（中等加速）
```sql
SELECT
  d.dim_name,
  count(*) AS cnt,
  sum(f.amount) AS total
FROM your_db.fact_table f
JOIN your_db.dim_table d
  ON f.dim_id = d.dim_id
WHERE f.dt = '2026-05-19'
GROUP BY d.dim_name
ORDER BY total DESC
LIMIT 50;
```

### 7.3 q3.sql — 复杂多 Join（重 Gluten 受益）
```sql
SELECT
  d1.region,
  d2.product,
  count(*) AS cnt,
  sum(f.amount) AS total,
  approx_count_distinct(f.user_id) AS uv
FROM your_db.fact_table f
JOIN your_db.dim_region d1 ON f.region_id = d1.id
JOIN your_db.dim_product d2 ON f.product_id = d2.id
WHERE f.dt BETWEEN '2026-05-01' AND '2026-05-19'
  AND f.amount > 100
GROUP BY d1.region, d2.product
HAVING count(*) > 1000
ORDER BY total DESC
LIMIT 200;
```

---

## 八、一键使用流程（明天上机）

```bash
# 1. 巡检
sudo bash /opt/spark-poc/scripts/01-precheck.sh
# 通过 → 继续

# 2. 部署
sudo bash /opt/spark-poc/scripts/02-deploy.sh /etc/hadoop/conf
# 输出 SPARK_HOME

# 3. 设置环境
export SPARK_HOME=/opt/spark-poc/spark
export PATH=$SPARK_HOME/bin:$PATH

# 4. 验证生效
bash /opt/spark-poc/scripts/03-verify.sh
# 看到 Velox*/Transformer = ✅

# 5. 准备 SQL
vi /opt/spark-poc/queries/q1.sql

# 6. 跑 Benchmark
bash /opt/spark-poc/scripts/04-bench.sh \
  /opt/spark-poc/queries/q1.sql \
  your_queue \
  8

# 7. 一致性校验
bash /opt/spark-poc/scripts/05-consistency.sh \
  your_db.fact_table \
  "dt='2026-05-19'"

# 8. 看结果
ls -lh /opt/spark-poc/results/
cat /opt/spark-poc/results/*.md

# 9. 出问题回滚
bash /opt/spark-poc/scripts/99-rollback.sh
```

---

## 九、明天 1 天的时间分配建议

| 时段 | 任务 |
|---|---|
| **上午 9-10 点** | 找 Gateway 机，跑 `01-precheck.sh` |
| **上午 10-11 点** | 跑 `02-deploy.sh` 部署 |
| **上午 11-12 点** | 跑 `03-verify.sh` 验证 + 解决 IPC/Kerberos 问题 |
| **下午 13-15 点** | 准备 3-5 条业务 SQL，跑 `04-bench.sh` |
| **下午 15-17 点** | 跑 `05-consistency.sh` 一致性校验 |
| **下午 17-18 点** | 整理结果，写 1 页测试报告 |

---

## 十、常见问题应急 FAQ

### Q1：jar 下载不到？
A：去 https://github.com/apache/incubator-gluten/releases 看最新版本，或用阿里云/腾讯云镜像。

### Q2：bench 跑了但加速比 < 1？
A：1) 数据太小（<1GB JNI 开销大于收益）；2) Fallback 率高，看 EXPLAIN

### Q3：Executor 突然挂？
A：看 stderr：1) SIGSEGV → OS/glibc 问题，换机器；2) OOM → 加 offHeap.size

### Q4：Kerberos 报错？
A：先 `kinit -kt your.keytab principal` 再 spark-submit

### Q5：HDFS 读失败？
A：看错误：1) IPC mismatch → 用 Hadoop Free 版；2) Kerberos → 同 Q4

---

## 十一、明天测试完后的产出物

应该交付：

1. **Benchmark 报告**：`/opt/spark-poc/results/*_report_*.md`
2. **一致性证明**：每条 SQL 的 row_cnt + crc32 一致
3. **EXPLAIN 截图**：证明 Gluten 真的生效
4. **踩坑记录**：遇到了什么问题，怎么解决的
5. **下一步建议**：基于实测数据决定是否扩大灰度

---

**End of 专题 5 — 这一份是大哥明天的工具箱！**

> Eric 守夜中，明天上机有任何问题随时 @ 豹纹 🐆
