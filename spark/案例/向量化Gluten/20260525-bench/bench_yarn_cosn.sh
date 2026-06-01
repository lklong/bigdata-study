#!/bin/bash
# ====================================================================
# bench_yarn_cosn.sh — Native vs Gluten 7 条 SQL 双跑（cosn 数据 / bench_cosn 库）
# 来源：bench_yarn.sh（保留 JDK17 add-opens、Netty 反射开关、MD5 一致性校验结构）
# 改造：
#   - 输入支持「单文件」或「目录（按 q1..q7 顺序循环）」
#   - 资源档位 light(默认) / standard
#   - 默认从 bench_cosn 库读 cosn 数据
#   - JDK17 仅运行期 --conf 切换；找不到则自动跳过 Gluten（基础 JDK8 不动）
#   - 单条 SQL 失败不中断、抓 yarn logs 写 .diag
#   - 汇总 summary_<TS>.md（speedup / consistent / 已知坑位标签）
# 用法：
#   bash bench_yarn_cosn.sh <query_file_or_dir> [light|standard]
# 红线：禁止任何 export JAVA_HOME / update-alternatives / 改 *-site.xml
# ====================================================================
set -u

# ---------- 参数 ----------
INPUT="${1:-/root/bench-101/queries_cosn}"
PROFILE="${2:-light}"

if [ ! -e "${INPUT}" ]; then
  echo "[FATAL] input not found: ${INPUT}" >&2
  exit 2
fi

# ---------- 进程内 PATH 初始化（不动 /etc/profile） ----------
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "${SELF_DIR}/env_init.sh"

# ---------- 强制锁定到 Spark 3.5.8（与 Gluten 1.6.0 jar 配套） ----------
# hadoop 用户 profile 默认指向 3.0.2，必须用绝对路径 + 显式 SPARK_HOME 覆盖
if [ -x "/opt/spark-poc/bin/spark-sql" ]; then
  export SPARK_HOME="/opt/spark-poc"
  SPARK_BIN="/opt/spark-poc/bin/spark-sql"
else
  SPARK_BIN="${SPARK_BIN:-${SPARK_HOME:-/opt/spark-poc}/bin/spark-sql}"
fi
if [ ! -x "${SPARK_BIN}" ]; then
  echo "[FATAL] spark-sql not found: ${SPARK_BIN}" >&2
  exit 3
fi
# 实测确认版本，避免再次跑错版本
SPARK_VER=$("${SPARK_BIN}" --version 2>&1 | grep -oE 'version [0-9.]+' | head -1 | awk '{print $2}')
echo "[INFO] SPARK_HOME=${SPARK_HOME}"
echo "[INFO] SPARK_BIN =${SPARK_BIN}"
echo "[INFO] SPARK_VER =${SPARK_VER}"
if [ -n "${SPARK_VER}" ] && [[ "${SPARK_VER}" != 3.5.* ]]; then
  echo "[FATAL] expect Spark 3.5.x, got ${SPARK_VER}" >&2
  exit 6
fi

# ---------- 输出目录 ----------
TS=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RESULT_DIR="${SCRIPT_DIR}/results/${TS}"
mkdir -p "${RESULT_DIR}"
DUR_NATIVE_CSV="${RESULT_DIR}/duration_cosn_native.csv"
DUR_GLUTEN_CSV="${RESULT_DIR}/duration_cosn_gluten.csv"
SUMMARY_MD="${RESULT_DIR}/summary_${TS}.md"
echo "query,seconds,application_id" > "${DUR_NATIVE_CSV}"
echo "query,seconds,application_id" > "${DUR_GLUTEN_CSV}"

echo "=========================================="
echo "  bench_yarn_cosn — TS=${TS}"
echo "  input  = ${INPUT}"
echo "  profile= ${PROFILE}"
echo "  result = ${RESULT_DIR}"
echo "=========================================="

# ---------- JDK 运行期切换探测（只读）----------
# 红线：不动集群默认 JDK / /etc/profile / update-alternatives
# JDK17_HOME 由 env_init.sh 探测注入；这里允许 JDK17_HOME_OVERRIDE 覆盖
if [ -n "${JDK17_HOME_OVERRIDE:-}" ] && [ -x "${JDK17_HOME_OVERRIDE}/bin/java" ]; then
  JDK17_HOME="${JDK17_HOME_OVERRIDE}"
fi
JDK17_HOME="${JDK17_HOME:-}"

GLUTEN_ENABLED="yes"
GLUTEN_SKIP_REASON=""
if [ -z "${JDK17_HOME}" ]; then
  GLUTEN_ENABLED="no"
  GLUTEN_SKIP_REASON="Gluten skipped: JDK17 not found on cluster (only default JDK8 available, baseline env not modified)"
  echo "[WARN] ${GLUTEN_SKIP_REASON}"
else
  echo "[INFO] JDK17 detected (runtime only): ${JDK17_HOME}"
fi

# ---------- JDK17 add-opens（仅 Gluten 段使用，跑 Native 用集群默认 JDK8 不需要） ----------
JAVA_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED \
--add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.lang.invoke=ALL-UNNAMED \
--add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED \
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
--add-opens=java.base/java.io=ALL-UNNAMED \
--add-opens=java.base/java.net=ALL-UNNAMED \
--add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
--add-opens=java.base/jdk.internal.misc=ALL-UNNAMED \
--add-opens=java.base/jdk.internal.ref=ALL-UNNAMED \
-Dio.netty.tryReflectionSetAccessible=true"

# ---------- cosn / chdfs jar 探测（3.5.8/jars 里没这些腾讯 EMR 适配器，必须从 3.0.2 路径借过来） ----------
EMR_FS_JARS=""
for j in \
    /usr/local/service/spark/jars/temrfs_hadoop_plugin_network-1.1.jar \
    /usr/local/service/spark/jars/chdfs_hadoop_plugin_network-2.8.jar ; do
  [ -f "${j}" ] && EMR_FS_JARS="${EMR_FS_JARS}${EMR_FS_JARS:+,}${j}"
done
if [ -n "${EMR_FS_JARS}" ]; then
  echo "[INFO] EMR_FS_JARS=${EMR_FS_JARS}"
else
  echo "[WARN] EMR cosn/chdfs jar not found, cosn:// will likely fail"
fi

# ---------- Gluten jar 探测（必须显式 --jars 加载，3.5.8/jars 里 bundle 不一定自动 load） ----------
GLUTEN_JAR=""
for cand in \
    "${GLUTEN_JAR_OVERRIDE:-}" \
    "/opt/spark-poc/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.6.0.jar" ; do
  [ -n "${cand}" ] && [ -f "${cand}" ] && GLUTEN_JAR="${cand}" && break
done
if [ -z "${GLUTEN_JAR}" ]; then
  GLUTEN_JAR=$(ls -1 /opt/spark-poc/jars/gluten-velox-bundle-*.jar 2>/dev/null | head -1)
fi
if [ -z "${GLUTEN_JAR}" ] || [ ! -f "${GLUTEN_JAR}" ]; then
  GLUTEN_ENABLED="no"
  GLUTEN_SKIP_REASON="${GLUTEN_SKIP_REASON:-Gluten skipped: gluten-velox-bundle jar not found under /opt/spark-poc/jars/}"
  echo "[WARN] ${GLUTEN_SKIP_REASON}"
else
  echo "[INFO] GLUTEN_JAR=${GLUTEN_JAR}"
fi

# ---------- 资源档位 ----------
case "${PROFILE}" in
  light)
    RES_OPTS="--num-executors 6 --executor-cores 2 --executor-memory 2g --driver-memory 2g"
    GLUTEN_OFFHEAP="3g"
    ;;
  standard)
    RES_OPTS="--num-executors 9 --executor-cores 5 --executor-memory 5g --driver-memory 4g"
    GLUTEN_OFFHEAP="8g"
    ;;
  max)
    # 集群规格：3 节点 × <memory:117965 MB, vCores:32>，总 354G/96 vCore
    # 留 ~30% 给 NM/系统/HDFS/Hive；executor JVM heap 16g + 6g overhead = 22g/容器
    # 12 executors × 6 cores × 22g = 72 cores / 264G，并发拉满（仍留约 90G/24 vcore 余量）
    # memoryOverhead=6g：Velox 1.6 推荐 ≥6G（log WARN 已提示）
    RES_OPTS="--num-executors 12 --executor-cores 6 --executor-memory 16g --driver-memory 8g \
      --conf spark.executor.memoryOverhead=6g"
    GLUTEN_OFFHEAP="20g"
    ;;
  *)
    echo "[FATAL] unknown profile: ${PROFILE}" >&2
    exit 4
    ;;
esac

# 合并为逗号分隔的 --jars 列表（cosn jar 必加，gluten jar 仅 Gluten 段加）
NATIVE_JARS="${EMR_FS_JARS}"
GLUTEN_JARS="${EMR_FS_JARS}"
[ -n "${GLUTEN_JAR}" ] && GLUTEN_JARS="${GLUTEN_JARS}${GLUTEN_JARS:+,}${GLUTEN_JAR}"
# extraClassPath 用冷号（3.5.8 driver/executor 启动需要）
NATIVE_CP=$(echo "${NATIVE_JARS}" | tr ',' ':')
GLUTEN_CP=$(echo "${GLUTEN_JARS}" | tr ',' ':')

COMMON_OPTS="--master yarn --deploy-mode client \
  ${RES_OPTS} \
  --conf spark.sql.adaptive.enabled=false \
  --conf spark.sql.shuffle.partitions=50 \
  --conf spark.sql.hive.convertMetastoreParquet=true \
  --conf spark.sql.parquet.enableVectorizedReader=true \
  --database bench_cosn"

# ---------- 已知坑位扫描 ----------
scan_known_pitfalls() {
  local logf="$1"
  local tags=""
  grep -q "ETypeConverter"  "${logf}" 2>/dev/null && tags="${tags} ETypeConverter→加 spark.sql.hive.convertMetastoreParquet=true;"
  grep -q "sumVector"        "${logf}" 2>/dev/null && tags="${tags} sumVector→关 Velox spill;"
  grep -q "ByteBuffer.flip"  "${logf}" 2>/dev/null && tags="${tags} ByteBuffer.flip→Kona JDK11/17 + 透传 spark.executorEnv.JAVA_HOME;"
  echo "${tags}"
}

# ---------- 抓诊断（yarn logs ERROR/WARN 前 200 行） ----------
collect_diag() {
  local stem="$1"  # 不含后缀的输出基路径
  local logf="${stem}.log"
  local diagf="${stem}.diag"
  local appid
  appid=$(grep -oE 'application_[0-9]+_[0-9]+' "${logf}" 2>/dev/null | tail -1)
  if [ -n "${appid}" ]; then
    echo "[diag] yarn logs -applicationId ${appid} ..." | tee -a "${diagf}"
    yarn logs -applicationId "${appid}" 2>/dev/null \
      | grep -E "ERROR|WARN" | head -200 >> "${diagf}" || true
    echo "${appid}"
  else
    echo "[diag] no applicationId found in ${logf}" > "${diagf}"
    echo ""
  fi
}

# ---------- 跑单条 ----------
# args: mode(native|gluten)  qname  sqlfile
run_one() {
  local mode="$1" qname="$2" sqlf="$3"
  local stem="${RESULT_DIR}/${qname}_${mode}"
  local outf="${stem}.out"
  local logf="${stem}.log"
  echo ""
  echo "---- ${mode} : ${qname} ----"
  local start end elapsed appid rc=0

  start=$(date +%s)
  if [ "${mode}" = "native" ]; then
    # 对齐 bench_yarn.sh 踩过坑的样板：Native 也加 add-opens（跳 JDK17 则不设 JAVA_HOME）
    "${SPARK_BIN}" ${COMMON_OPTS} \
      --jars "${NATIVE_JARS}" \
      --conf "spark.driver.extraClassPath=${NATIVE_CP}" \
      --conf "spark.executor.extraClassPath=${NATIVE_CP}" \
      --conf "spark.driver.extraJavaOptions=${JAVA_OPENS}" \
      --conf "spark.executor.extraJavaOptions=${JAVA_OPENS}" \
      -f "${sqlf}" > "${outf}" 2> "${logf}"
    rc=$?
  else
    # Gluten 段 — 对齐 bench_yarn.sh 踩过坑的参数，cosn-bench 增量必须项：
    #   1) --database bench_cosn（库定位）
    #   2) --jars 加 cosn jar + gluten jar（集群默认 SPARK_HOME=3.0.2，必须显式加载）
    #   3) --archives 分发 JDK17（NodeManager 节点未装 JDK17，不允许改集群环境）
    #   4) spark.shuffle.service.enabled=false（集群外部 SHS 是 3.0.2 不识别 ColumnarShuffleManager）
    #   5) JAVA_HOME 前缀（仅本次 spark-sql 子进程）：
    #      该集群 /opt/spark-poc/bin/spark-sql 默认走 JDK8（与样板机器不同），
    #      若不带前缀则 client driver 用 JDK8 加载 Gluten jar 立即 UnsupportedClassVersionError(61.0)。
    #      仅前缀临时变量，不改集群默认 JDK / /etc/profile / update-alternatives。
    JDK17_ARCHIVE="${JDK17_ARCHIVE:-hdfs:///user/hadoop/jdk17.tgz}"
    JDK17_INNER="${JDK17_INNER:-TencentKona-17.0.18.b1}"
    JAVA_HOME="${JDK17_HOME}" PATH="${JDK17_HOME}/bin:${PATH}" \
    "${SPARK_BIN}" ${COMMON_OPTS} \
      --jars "${GLUTEN_JARS}" \
      --archives "${JDK17_ARCHIVE}#jdk17" \
      --conf "spark.driver.extraClassPath=${GLUTEN_CP}" \
      --conf "spark.executor.extraClassPath=${GLUTEN_CP}" \
      --conf "spark.yarn.appMasterEnv.JAVA_HOME=./jdk17/${JDK17_INNER}" \
      --conf "spark.executorEnv.JAVA_HOME=./jdk17/${JDK17_INNER}" \
      --conf "spark.driver.extraJavaOptions=${JAVA_OPENS}" \
      --conf "spark.executor.extraJavaOptions=${JAVA_OPENS}" \
      --conf spark.plugins=org.apache.gluten.GlutenPlugin \
      --conf spark.shuffle.service.enabled=false \
      --conf spark.memory.offHeap.enabled=true \
      --conf "spark.memory.offHeap.size=${GLUTEN_OFFHEAP}" \
      --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
      --conf spark.gluten.memory.allocator=jemalloc \
      --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 \
      --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=true \
      --conf spark.gluten.sql.columnar.backend.velox.spillStrategy=auto \
      --conf spark.gluten.sql.columnar.wholeStage.fallback.threshold=1 \
      --conf spark.gluten.sql.columnar.physicalPlanValidator.fallbackOnFailedPlan=true \
      --conf spark.gluten.sql.columnar.physicalPlanValidator.enabled=false \
      --conf spark.gluten.sql.columnar.preferColumnar=false \
      --conf spark.gluten.sql.fallback.enabled=true \
      --conf spark.gluten.expression.blacklist=Decimal,CheckOverflow,MakeDecimal,UnscaledValue,PromotePrecision \
      --conf spark.task.maxFailures=2 \
      --conf spark.network.timeout=600s \
      --conf spark.executor.heartbeatInterval=60s \
      -f "${sqlf}" > "${outf}" 2> "${logf}" &
    local sql_pid=$!
    # SQL 级超时强 kill（默认 600s = 10min/SQL，遇 native 死锁快速失败；可用 BENCH_SQL_TIMEOUT 覆盖）
    local sql_timeout="${BENCH_SQL_TIMEOUT:-600}"
    ( sleep "${sql_timeout}"; if kill -0 ${sql_pid} 2>/dev/null; then
        echo "[gluten][TIMEOUT] ${qname} exceeded ${sql_timeout}s, killing pid=${sql_pid}" >> "${logf}"
        kill -9 ${sql_pid} 2>/dev/null
      fi ) &
    local watchdog_pid=$!
    wait ${sql_pid}
    rc=$?
    kill ${watchdog_pid} 2>/dev/null
  fi
  end=$(date +%s)
  elapsed=$((end - start))

  if [ "${rc}" -ne 0 ]; then
    appid=$(collect_diag "${stem}")
    echo "[${mode}][FAIL] ${qname} rc=${rc} appId=${appid} -> ${logf}"
    elapsed=0
  else
    appid=$(grep -oE 'application_[0-9]+_[0-9]+' "${logf}" 2>/dev/null | tail -1)
    echo "[${mode}][OK  ] ${qname} ${elapsed}s appId=${appid:-N/A}"
  fi

  if [ "${mode}" = "native" ]; then
    echo "${qname},${elapsed},${appid:-}" >> "${DUR_NATIVE_CSV}"
  else
    echo "${qname},${elapsed},${appid:-}" >> "${DUR_GLUTEN_CSV}"
  fi
  return ${rc}
}

# ---------- 收集 SQL 列表 ----------
SQLS=()
if [ -d "${INPUT}" ]; then
  for q in q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables; do
    f="${INPUT}/${q}.sql"
    [ -s "${f}" ] && SQLS+=("${f}")
  done
else
  SQLS+=("${INPUT}")
fi
[ "${#SQLS[@]}" -gt 0 ] || { echo "[FATAL] no sql to run under ${INPUT}" >&2; exit 5; }

echo "[plan] ${#SQLS[@]} SQL(s) to run, profile=${PROFILE}, gluten=${GLUTEN_ENABLED}"

# ---------- 执行：先 Native 后 Gluten；逐条 SQL ----------
# 可选开关：
#   BENCH_NATIVE_ONLY=1  只跑 Native，跳过 Gluten
#   BENCH_GLUTEN_ONLY=1  只跑 Gluten，跳过 Native（用于 Native 已 OK 后单独验证 Gluten）
COSN_ABORT="no"
if [ "${BENCH_GLUTEN_ONLY:-0}" != "1" ]; then
  for sqlf in "${SQLS[@]}"; do
    qname=$(basename "${sqlf}" .sql)
    run_one native "${qname}" "${sqlf}" || true
    # cosn 第一条就失败检测（仅"连不上"才 abort，ClassNotFound 不算 unreachable）
    if [ "${COSN_ABORT}" = "no" ] && [ "${qname}" = "q1_agg" ]; then
      nlog="${RESULT_DIR}/${qname}_native.log"
      if [ -s "${nlog}" ] && grep -qE 'No FileSystem for scheme.*cosn|UnsupportedFileSystemException.*cosn|fs\.cosn\.impl' "${nlog}" \
         && [ "$(awk -F, -v q="${qname}" '$1==q{print $2; exit}' "${DUR_NATIVE_CSV}")" = "0" ]; then
        echo "[FATAL] cosn unreachable, abort batch." >&2
        echo "请检查 core-site.xml 中 fs.cosn.* 配置（仅提示，不修改）。" >&2
        COSN_ABORT="yes"
        break
      fi
    fi
  done
else
  echo "[plan] BENCH_GLUTEN_ONLY=1, skipping native phase"
fi

if [ "${COSN_ABORT}" = "no" ] && [ "${GLUTEN_ENABLED}" = "yes" ] && [ "${BENCH_NATIVE_ONLY:-0}" != "1" ]; then
  for sqlf in "${SQLS[@]}"; do
    qname=$(basename "${sqlf}" .sql)
    run_one gluten "${qname}" "${sqlf}" || true
  done
elif [ "${BENCH_NATIVE_ONLY:-0}" = "1" ]; then
  echo "[plan] BENCH_NATIVE_ONLY=1, skipping gluten phase"
fi

# ---------- 汇总 summary_<TS>.md ----------
{
  echo "# Bench Summary — ${TS}"
  echo
  echo "- profile: \`${PROFILE}\`"
  echo "- input  : \`${INPUT}\`"
  echo "- result : \`${RESULT_DIR}\`"
  echo "- gluten : \`${GLUTEN_ENABLED}\`"
  [ -n "${GLUTEN_SKIP_REASON}" ] && echo "- 跳过原因：${GLUTEN_SKIP_REASON}"
  [ "${COSN_ABORT}" = "yes" ] && echo "- ⚠️ cosn 不可达，整批提前终止（仅 q1_agg native 尝试过）"
  echo
  echo "## 7×2 耗时对比"
  echo
  echo "| SQL | Native(s) | Gluten(s) | Speedup | Consistent | 备注 |"
  echo "|---|---|---|---|---|---|"

  for sqlf in "${SQLS[@]}"; do
    q=$(basename "${sqlf}" .sql)
    n=$(awk -F, -v q="${q}" '$1==q{print $2; exit}' "${DUR_NATIVE_CSV}")
    g=$(awk -F, -v q="${q}" '$1==q{print $2; exit}' "${DUR_GLUTEN_CSV}")
    n="${n:-0}"; g="${g:-0}"

    if [ "${GLUTEN_ENABLED}" = "no" ]; then
      gcell="-"; speedup="-"; consistent="-"
    else
      gcell="${g}"
      if [ "${n}" -gt 0 ] && [ "${g}" -gt 0 ]; then
        speedup=$(awk -v n="${n}" -v g="${g}" 'BEGIN{printf "%.2f", n/g}')
      else
        speedup="N/A"
      fi
      nout="${RESULT_DIR}/${q}_native.out"
      gout="${RESULT_DIR}/${q}_gluten.out"
      if [ -f "${nout}" ] && [ -f "${gout}" ]; then
        nm=$(grep -v "^Time taken\|^$" "${nout}" 2>/dev/null | md5sum | awk '{print $1}')
        gm=$(grep -v "^Time taken\|^$" "${gout}" 2>/dev/null | md5sum | awk '{print $1}')
        [ "${nm}" = "${gm}" ] && consistent="YES" || consistent="NO"
      else
        consistent="N/A"
      fi
    fi

    note=""
    [ "${n}" != "0" ] && [ "${n}" -lt 30 ] && note+="启动开销主导，加速比仅供参考；"
    [ "${n}" = "0" ] && note+="Native FAILED；"
    [ "${GLUTEN_ENABLED}" = "yes" ] && [ "${g}" = "0" ] && note+="Gluten FAILED；"

    nlog="${RESULT_DIR}/${q}_native.log"; glog="${RESULT_DIR}/${q}_gluten.log"
    [ -f "${nlog}" ] && tag=$(scan_known_pitfalls "${nlog}") && [ -n "${tag}" ] && note+="[已知坑位 native]${tag}"
    [ -f "${glog}" ] && tag=$(scan_known_pitfalls "${glog}") && [ -n "${tag}" ] && note+="[已知坑位 gluten]${tag}"

    echo "| ${q} | ${n} | ${gcell} | ${speedup} | ${consistent} | ${note} |"
  done

  echo
  echo "## 资源参数（运行期 --conf，不动基础环境）"
  echo
  echo "- ${RES_OPTS}"
  echo "- spark.sql.adaptive.enabled=false"
  echo "- spark.sql.shuffle.partitions=50"
  echo "- spark.sql.hive.convertMetastoreParquet=true"
  echo "- spark.sql.parquet.enableVectorizedReader=true"
  if [ "${GLUTEN_ENABLED}" = "yes" ]; then
    echo "- spark.yarn.appMasterEnv.JAVA_HOME=${JDK17_HOME}"
    echo "- spark.executorEnv.JAVA_HOME=${JDK17_HOME}"
    echo "- spark.plugins=org.apache.gluten.GlutenPlugin"
    echo "- spark.memory.offHeap.enabled=true / size=${GLUTEN_OFFHEAP}"
    echo "- spark.shuffle.manager=ColumnarShuffleManager"
    echo "- spark.gluten.sql.columnar.backend.velox.spillEnabled=false"
  fi
} > "${SUMMARY_MD}"

echo "=========================================="
echo "  Summary: ${SUMMARY_MD}"
echo "=========================================="
