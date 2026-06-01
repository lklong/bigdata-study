#!/bin/bash
# ====================================================================
# prepare_cosn_tables.sh — cosn 数据探查 + bench_cosn 库 5 张外部表注册
# 运行位置：目标集群 101.43.161.139:/root/bench-101/
# 红线：仅读 cosn 数据 + 仅写 Hive 元数据；不动任何基础环境
# ====================================================================
set -u

# ---------- 进程内 PATH 初始化（不动 /etc/profile） ----------
# 非交互 ssh 不自动加载 profile.d，这里仅在当前脚本进程注入路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "${SCRIPT_DIR}/env_init.sh"

DDL_FILE="${SCRIPT_DIR}/external_tables_meson.sql"
INVENTORY="${SCRIPT_DIR}/data_inventory.txt"
COSN_BASE="cosn://lkl-bj-update-1308597516/meson/data/bench"
TABLES=(customers products reviews orders order_items)

# 强制锁定 Spark 3.5.8，避免 hadoop 用户默认 SPARK_HOME=3.0.2
if [ -x "/opt/spark-poc/bin/spark-sql" ]; then
  export SPARK_HOME="/opt/spark-poc"
fi
SPARK_SQL="${SPARK_HOME}/bin/spark-sql"
[ -x "${SPARK_SQL}" ] || SPARK_SQL="/opt/spark-poc/bin/spark-sql"

# EMR cosn / chdfs 适配器 jar（Spark 3.5.8 自带 jars 没有，从 3.0.2 路径借）
EMR_FS_JARS=""
for j in \
    /usr/local/service/spark/jars/temrfs_hadoop_plugin_network-1.1.jar \
    /usr/local/service/spark/jars/chdfs_hadoop_plugin_network-2.8.jar ; do
  [ -f "${j}" ] && EMR_FS_JARS="${EMR_FS_JARS}${EMR_FS_JARS:+,}${j}"
done
EMR_FS_CP=$(echo "${EMR_FS_JARS}" | tr ',' ':')

: > "${INVENTORY}"

log() { echo "[prepare][$(date '+%H:%M:%S')] $*" | tee -a "${INVENTORY}"; }

log "=== Step 1/3 : 数据存在性 + 大小盘点 ==="
MISSING=()
for t in "${TABLES[@]}"; do
  TPATH="${COSN_BASE}/${t}"
  log "---- ${t} : ${TPATH} ----"
  OUT=$(hadoop fs -du -s -h "${TPATH}" 2>&1)
  RC=$?
  echo "${OUT}" | tee -a "${INVENTORY}"
  if [ "${RC}" -ne 0 ]; then
    log "[ERROR] table ${t} cosn ls failed (rc=${RC})"
    MISSING+=("${t}")
    continue
  fi
  # 第一列是字节数；若为 0 视为缺失
  SIZE=$(echo "${OUT}" | awk 'NR==1{print $1}')
  if [ -z "${SIZE}" ] || [ "${SIZE}" = "0" ]; then
    log "[ERROR] table ${t} size is 0"
    MISSING+=("${t}")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  log "[FATAL] missing/empty tables: ${MISSING[*]}"
  echo "[prepare][FATAL] 数据缺失，停止建表：${MISSING[*]}" >&2
  exit 1
fi
log "[OK] 5 张表数据全部就位"

log "=== Step 2/3 : 创建 bench_cosn 库 + 5 张外部表 ==="
[ -s "${DDL_FILE}" ] || { log "[FATAL] DDL not found: ${DDL_FILE}"; exit 2; }

# 直接走 spark-sql 3.5.8（绕过 hive 2.3.7 读 cosn parquet 的 ETypeConverter 老 bug）
log "use ${SPARK_SQL} -f ${DDL_FILE} (Spark 3.5.8)"
"${SPARK_SQL}" --master local -f "${DDL_FILE}" 2>&1 | tee -a "${INVENTORY}"
DDL_RC=${PIPESTATUS[0]}
if [ "${DDL_RC}" -ne 0 ]; then
  log "[FATAL] DDL execute failed rc=${DDL_RC}"
  exit 3
fi
log "[OK] 外部表创建完成"

log "=== Step 3/3 : 行数抽检 select count(*) （spark-sql 3.5.8 yarn）==="
# 走 yarn 并发 + AQE，避免 local 模式 × 80GB 表超慢。hive 老 bug 跳过。
for t in "${TABLES[@]}"; do
  log "---- count(*) ${t} ----"
  OUT=$("${SPARK_SQL}" --master yarn --deploy-mode client \
    --num-executors 6 --executor-cores 4 --executor-memory 8g --driver-memory 4g \
    --jars "${EMR_FS_JARS}" \
    --conf "spark.driver.extraClassPath=${EMR_FS_CP}" \
    --conf "spark.executor.extraClassPath=${EMR_FS_CP}" \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.hive.convertMetastoreParquet=true \
    --conf spark.sql.parquet.enableVectorizedReader=true \
    -e "select count(*) from bench_cosn.${t};" 2>&1)
  echo "${OUT}" | tail -10 | tee -a "${INVENTORY}"
done

log "=== DONE，inventory: ${INVENTORY} ==="
