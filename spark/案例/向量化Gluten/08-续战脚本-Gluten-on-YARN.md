# Gluten POC 续战脚本包（08）

> **接续**：07-POC实测记录-43.143.233.211.md  
> **目标**：完成下次待办——Gluten on YARN 大数据量验证 + 加速比 + 一致性校验  
> **测试机**：43.143.233.211（腾讯云 EMR，3 节点 YARN，Hadoop 2.8.5）  
> **数据**：HDFS `/tmp/gluten_tpch`，1 亿行，2GB Parquet  
> **Native 基线**：92 秒（已实测）

---

## 〇、续战清单（待完成项）

```
[ ] 1. Gluten on YARN 跑相同 SQL（vs 92 秒基线）
[ ] 2. 出最终加速比数据
[ ] 3. 一致性校验：Native vs Gluten 输出 md5 对比
[ ] 4. 整理最终对比报告
```

---

## 一、环境一键设置（每次新开终端先跑）

```bash
# === 上传到 43.143.233.211 后保存为 /opt/spark-poc/env.sh ===

export SPARK_HOME=/opt/spark-poc
export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
export HADOOP_HOME=/usr/local/service/hadoop
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export YARN_CONF_DIR=$HADOOP_CONF_DIR
export LD_LIBRARY_PATH=$HADOOP_HOME/lib/native:$JAVA_HOME/lib/server:$JAVA_HOME/lib
export PATH=$JAVA_HOME/bin:$SPARK_HOME/bin:$PATH

# 验证
echo "JDK: $(java -version 2>&1 | head -1)"
echo "Spark: $($SPARK_HOME/bin/spark-submit --version 2>&1 | grep -i version | head -1)"
echo "HDFS: $(hdfs dfs -ls /tmp/gluten_tpch | head -3)"
```

**用法**：`source /opt/spark-poc/env.sh`

---

## 二、Gluten on YARN 续测脚本

### 2.1 测试 SQL（与 Native 基线相同，确保可比性）

```bash
# 保存为 /opt/spark-poc/queries/q_complex.sql
cat > /opt/spark-poc/queries/q_complex.sql <<'EOF'
-- 多层 CTE + Window 函数 + 环比 + TopN（与 Native 92秒基线同一条 SQL）
WITH base AS (
    SELECT 
        grp_id,
        date_id,
        val,
        cat
    FROM parquet.`/tmp/gluten_tpch`
    WHERE val > 0
),
agg AS (
    SELECT 
        grp_id,
        date_id,
        sum(val) AS total_val,
        count(*) AS cnt,
        avg(val) AS avg_val
    FROM base
    GROUP BY grp_id, date_id
),
ranked AS (
    SELECT 
        grp_id,
        date_id,
        total_val,
        cnt,
        avg_val,
        lag(total_val, 1) OVER (PARTITION BY grp_id ORDER BY date_id) AS prev_val,
        row_number() OVER (PARTITION BY date_id ORDER BY total_val DESC) AS rn
    FROM agg
)
SELECT 
    grp_id,
    date_id,
    total_val,
    cnt,
    avg_val,
    CASE 
        WHEN prev_val IS NULL OR prev_val = 0 THEN NULL
        ELSE round((total_val - prev_val) * 100.0 / prev_val, 2)
    END AS mom_ratio,
    rn
FROM ranked
WHERE rn <= 100
ORDER BY date_id, rn
LIMIT 1000;
EOF
```

> **如果你 Native 基线用的不是这条 SQL**，直接把基线那条放进去即可。**关键：两次测试必须用同一条 SQL**。

---

### 2.2 一键 Bench 脚本（`/opt/spark-poc/scripts/bench_yarn.sh`）

```bash
#!/bin/bash
# 用法: bash bench_yarn.sh
# 作用: 用相同 SQL 在 YARN 上跑 Native + Gluten，自动对比

set -e
source /opt/spark-poc/env.sh

SQL_FILE=/opt/spark-poc/queries/q_complex.sql
RESULT_DIR=/opt/spark-poc/results
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p $RESULT_DIR

# 共用资源参数（与 Native 基线 92 秒一致）
COMMON_OPTS="--master yarn --deploy-mode client \
             --num-executors 6 --executor-cores 2 --executor-memory 2g \
             --driver-memory 2g \
             --queue default"

# JDK 17 必备 add-opens
JAVA_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED \
            --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
            --add-opens=java.base/java.lang=ALL-UNNAMED \
            --add-opens=java.base/java.util=ALL-UNNAMED \
            --add-opens=java.base/java.lang.invoke=ALL-UNNAMED"

NATIVE_LOG=$RESULT_DIR/native_${TS}.log
GLUTEN_LOG=$RESULT_DIR/gluten_${TS}.log
NATIVE_OUT=$RESULT_DIR/native_${TS}.out
GLUTEN_OUT=$RESULT_DIR/gluten_${TS}.out

echo "=========================================="
echo "  Gluten on YARN 续战 Benchmark"
echo "  时间: $(date)"
echo "  SQL: $SQL_FILE"
echo "=========================================="

# ============================================
# 第一发：Native Spark
# ============================================
echo ""
echo "[1/2] 🚀 Native Spark on YARN..."
START=$(date +%s)

$SPARK_HOME/bin/spark-sql $COMMON_OPTS \
  --conf "spark.driver.extraJavaOptions=$JAVA_OPENS" \
  --conf "spark.executor.extraJavaOptions=$JAVA_OPENS" \
  --conf "spark.executorEnv.JAVA_HOME=$JAVA_HOME" \
  --conf "spark.sql.adaptive.enabled=false" \
  --conf "spark.sql.shuffle.partitions=50" \
  -f $SQL_FILE > $NATIVE_OUT 2> $NATIVE_LOG

END=$(date +%s)
NATIVE_TIME=$((END - START))
echo "  ⏱  Native 耗时: ${NATIVE_TIME}s"

# ============================================
# 第二发：Gluten + Velox
# ============================================
echo ""
echo "[2/2] 🚀 Gluten + Velox on YARN..."
START=$(date +%s)

$SPARK_HOME/bin/spark-sql $COMMON_OPTS \
  --conf "spark.plugins=org.apache.gluten.GlutenPlugin" \
  --conf "spark.memory.offHeap.enabled=true" \
  --conf "spark.memory.offHeap.size=3g" \
  --conf "spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager" \
  --conf "spark.gluten.memory.allocator=jemalloc" \
  --conf "spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5" \
  \
  --conf "spark.driver.extraJavaOptions=$JAVA_OPENS" \
  --conf "spark.executor.extraJavaOptions=$JAVA_OPENS" \
  --conf "spark.executor.extraLibraryPath=$HADOOP_HOME/lib/native" \
  --conf "spark.executorEnv.HADOOP_HOME=$HADOOP_HOME" \
  --conf "spark.executorEnv.JAVA_HOME=$JAVA_HOME" \
  --conf "spark.executorEnv.LD_LIBRARY_PATH=$HADOOP_HOME/lib/native:$JAVA_HOME/lib/server:$JAVA_HOME/lib" \
  \
  --conf "spark.sql.adaptive.enabled=false" \
  --conf "spark.sql.shuffle.partitions=50" \
  -f $SQL_FILE > $GLUTEN_OUT 2> $GLUTEN_LOG

END=$(date +%s)
GLUTEN_TIME=$((END - START))
echo "  ⏱  Gluten 耗时: ${GLUTEN_TIME}s"

# ============================================
# 一致性 + 加速比
# ============================================
echo ""
echo "=========================================="
echo "  📊 结果分析"
echo "=========================================="

NATIVE_MD5=$(md5sum $NATIVE_OUT | awk '{print $1}')
GLUTEN_MD5=$(md5sum $GLUTEN_OUT | awk '{print $1}')
NATIVE_LINES=$(wc -l < $NATIVE_OUT)
GLUTEN_LINES=$(wc -l < $GLUTEN_OUT)

if [[ $GLUTEN_TIME -gt 0 ]]; then
    SPEEDUP=$(echo "scale=2; ${NATIVE_TIME} / ${GLUTEN_TIME}" | bc)
else
    SPEEDUP="N/A"
fi

# ============================================
# 自动生成 Markdown 报告
# ============================================
REPORT=$RESULT_DIR/report_${TS}.md
cat > $REPORT <<REPEOF
# Gluten on YARN 续战 Benchmark Report

- **时间**: $(date)
- **测试机**: 43.143.233.211（腾讯云 EMR，3 节点 YARN）
- **数据**: HDFS \`/tmp/gluten_tpch\`，1 亿行
- **SQL**: \`q_complex.sql\`（多层 CTE + Window + 环比 + TopN）

## 一、性能对比

| 维度 | Native Spark 3.5.8 | Gluten 1.6.0 + Velox | 加速比 |
|------|------|------|------|
| **耗时** | **${NATIVE_TIME}s** | **${GLUTEN_TIME}s** | **${SPEEDUP}×** |
| Executor 数 | 6 | 6 | - |
| Executor 核数 | 2 | 2 | - |
| Executor 内存 | 2g | 2g + 3g(offHeap) | - |
| Shuffle Manager | SortShuffleManager | **ColumnarShuffleManager** | - |

## 二、一致性校验

| 项 | Native | Gluten | 一致性 |
|---|---|---|---|
| 输出行数 | $NATIVE_LINES | $GLUTEN_LINES | $([[ "$NATIVE_LINES" == "$GLUTEN_LINES" ]] && echo "✅" || echo "❌") |
| 输出 md5 | \`${NATIVE_MD5}\` | \`${GLUTEN_MD5}\` | $([[ "$NATIVE_MD5" == "$GLUTEN_MD5" ]] && echo "✅ 完全一致" || echo "❌ 不一致") |

## 三、详细日志

- Native 输出: \`$NATIVE_OUT\`
- Native 日志: \`$NATIVE_LOG\`
- Gluten 输出: \`$GLUTEN_OUT\`
- Gluten 日志: \`$GLUTEN_LOG\`

## 四、结论

$([[ $(echo "$SPEEDUP > 1.5" | bc -l 2>/dev/null) = "1" ]] && echo "✅ 加速比 ${SPEEDUP}× 达到预期（≥1.5×），可推进灰度" || echo "⚠️ 加速比 ${SPEEDUP}× 低于预期，需排查 Fallback 率")
$([[ "$NATIVE_MD5" == "$GLUTEN_MD5" ]] && echo "✅ 一致性校验通过，数据正确性可信" || echo "❌ 一致性校验失败，必须排查后再推进")

REPEOF

# ============================================
# 终端输出
# ============================================
echo ""
echo "Native:    ${NATIVE_TIME}s"
echo "Gluten:    ${GLUTEN_TIME}s"
echo "加速比:    ${SPEEDUP}×"
echo ""
echo "行数:      Native=$NATIVE_LINES, Gluten=$GLUTEN_LINES $([[ "$NATIVE_LINES" == "$GLUTEN_LINES" ]] && echo "✅" || echo "❌")"
echo "md5:       Native=$NATIVE_MD5"
echo "           Gluten=$GLUTEN_MD5"
echo "一致性:    $([[ "$NATIVE_MD5" == "$GLUTEN_MD5" ]] && echo "✅" || echo "❌")"
echo ""
echo "📄 完整报告: $REPORT"
echo "=========================================="
```

---

## 三、可能的踩坑预案（基于 07 实测）

### 坑 1：Gluten 没生效（EXPLAIN 看不到 Velox 节点）
**原因**：07 实测验证过 AQE 开启会让 EXPLAIN 看不到 Columnar 节点  
**解法**：脚本里已加 `spark.sql.adaptive.enabled=false`  
**验证**：先单独跑 EXPLAIN
```bash
$SPARK_HOME/bin/spark-sql --master yarn ... -e "EXPLAIN $(cat q_complex.sql)" | grep -E "Velox|Transformer"
```

### 坑 2：YARN executor exit code 50
**原因**：07 实测 — Worker 节点没 JDK 17  
**预防**：开始前先确认
```bash
# 在所有 NM 节点检查
for node in nm1 nm2 nm3; do
    ssh $node "ls /usr/lib/jvm/TencentKona-17.0.18.b1/bin/java"
done
```

### 坑 3：Required memory above max threshold
**原因**：07 实测 — 单节点 max-allocation ~7.3GB，executor 4g + offHeap 4g 超了  
**当前脚本**：executor 2g + offHeap 3g + overhead 默认 ≈ 6GB，**安全**  
**如果还报错**：降低 offHeap 到 2g，或减少 executor 数

### 坑 4：libhdfs.so 找不到（SIGSEGV）
**原因**：07 实测  
**当前脚本已配**：
```
spark.executor.extraLibraryPath=/usr/local/service/hadoop/lib/native
spark.executorEnv.LD_LIBRARY_PATH=...
```

### 坑 5：HashAggregateExec API 不兼容
**原因**：07 实测 — Gluten 1.6 编译目标是 Spark 3.5.5+，但 EMR 自带的是 3.5.3  
**当前用 Spark 3.5.8 社区版**，已规避

---

## 四、上机执行流程

```bash
# === 1. 同步脚本到测试机 ===
scp 08-续战脚本.md root@43.143.233.211:/tmp/
scp bench_yarn.sh root@43.143.233.211:/opt/spark-poc/scripts/

# === 2. 登录测试机 ===
ssh root@43.143.233.211

# === 3. 准备测试 SQL ===
mkdir -p /opt/spark-poc/queries
vi /opt/spark-poc/queries/q_complex.sql   # 贴入 SQL（与 Native 基线相同）

# === 4. 设置环境 ===
source /opt/spark-poc/env.sh

# === 5. 跑 Bench ===
bash /opt/spark-poc/scripts/bench_yarn.sh

# === 6. 看结果 ===
cat /opt/spark-poc/results/report_*.md | tail -40

# === 7. 如果一致性失败 ===
diff /opt/spark-poc/results/native_*.out /opt/spark-poc/results/gluten_*.out | head -50
```

---

## 五、预期结果（参考业界数据）

基于美团/AWS 实测：

| 查询类型 | 加速比预期 |
|---|---|
| 多层 CTE + 聚合 + Window | **2× - 4×** |
| 简单聚合 | 1.5× - 2× |
| 复杂 Join | 1.5× - 3× |

**大哥的 Native 基线 92 秒**：
- 如果 Gluten 能跑到 **30-50 秒** → 加速 1.8-3×，**优秀**
- 跑到 60-80 秒 → 加速 1.1-1.5×，**及格**，可能 fallback 多
- 跑到 90 秒以上 → **有问题**，必须排查

---

## 六、跑完后的下一步路线图

### 如果加速比 ≥ 1.5× 且一致性通过 ✅
```
1. 继续测 3-5 条业务 SQL（不同算子覆盖：Join / Sort / 多 Window）
2. 评估上灰度
3. 沉淀 09-业务SQL兼容性矩阵.md
```

### 如果加速比 < 1.5× ⚠️
```
1. EXPLAIN 看物理计划，统计 Velox*Transformer 节点 vs Row2Columnar 节点
2. 高 Fallback 率 → 排查具体哪个算子没走 Velox
3. 可能原因：UDF / textfile / ANSI 模式 / 不支持的函数
```

### 如果一致性失败 ❌
```
1. diff 输出找出哪些行不同
2. 检查浮点列（float/double 精度差异）
3. 检查 NULL 处理 / 排序稳定性
4. 单独跑每个 CTE 子查询，定位是哪一层引入差异
```

---

## 七、本次续战交付物

跑完应该产出 4 件套：

```
/opt/spark-poc/results/
├── native_<时间戳>.out      ← Native 输出
├── native_<时间戳>.log      ← Native 日志
├── gluten_<时间戳>.out      ← Gluten 输出
├── gluten_<时间戳>.log      ← Gluten 日志
└── report_<时间戳>.md       ← 自动报告（含加速比 + md5）
```

把 `report_<时间戳>.md` 复制回本地 → 推到 bigdata-study/spark/案例/向量化Gluten/ 作为 09-续战结果.md。

---

**End of 08 — 拷贝即用！**

> Eric 守夜中，明天上机有任何问题随时 @ 豹纹 🐆
