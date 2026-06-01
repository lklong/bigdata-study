#!/bin/bash
# ====================================================================
# run_bench_101.sh — 一键编排：盘点 → 部署 → 建表 → 跑批 → 回收
# 红线：所有操作只在 /root/bench-101/ 与 /home/hadoop/bench-101/ 与本地 reports/ 之间进行；
#       不修改集群默认 JDK / *-site.xml / /etc/profile / spark.eventLog.enabled
# 用法：
#   bash run_bench_101.sh [light|standard]
# 可选环境变量：
#   BENCH_HEARTBEAT_SEC=60   每隔多少秒打印心跳（>=1 分钟必报，默认 60）
# ====================================================================
set -eu

PROFILE="${1:-max}"

HOST_IP="${HOST_IP:-101.43.161.139}"
SSH_USER="${SSH_USER:-root}"
PEM_PATH="${PEM_PATH:-/c/Users/lkl/Desktop/lkl_meson.pem}"
SSH_OPTS="-i ${PEM_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
REMOTE_DIR="${REMOTE_DIR:-/root/bench-101}"
HADOOP_DIR="${HADOOP_DIR:-/home/hadoop/bench-101}"
HEARTBEAT_SEC="${BENCH_HEARTBEAT_SEC:-60}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GLUTEN_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
LOCAL_REPORT_BASE="${GLUTEN_DIR}/reports"
TS=$(date +%Y%m%d_%H%M%S)
LOCAL_REPORT_DIR="${LOCAL_REPORT_BASE}/${HOST_IP}_${TS}"
mkdir -p "${LOCAL_REPORT_DIR}"

ts() { date +'%H:%M:%S'; }
stage() { echo; echo "########## [$(ts)] STAGE: $* ##########"; }
fail()  { echo "[$(ts)] [FATAL] stage failed: $*" >&2; exit 1; }

# ---------- watchdog：每 HEARTBEAT_SEC 秒打印心跳 + 远端进程摘要 ----------
# 用法：
#   start_watchdog "<stage_name>"
#   ... 真正命令 ...
#   stop_watchdog
WD_PID=""
WD_LOG=""
start_watchdog() {
  local name="$1"
  local start_epoch=$(date +%s)
  WD_LOG="${LOCAL_REPORT_DIR}/watchdog_${name//[^A-Za-z0-9_-]/_}_${TS}.log"
  : > "${WD_LOG}"
  (
    while true; do
      sleep "${HEARTBEAT_SEC}"
      local now=$(date +%s)
      local elapsed=$(( now - start_epoch ))
      local m=$(( elapsed / 60 ))
      local s=$(( elapsed % 60 ))
      # 远端进程快照（10s 超时，不阻塞主流程）
      local snap
      snap=$(timeout 10 ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
        "ps -u hadoop -o pid,etime,cmd 2>/dev/null | grep -E 'spark|hive|hadoop|java' | grep -v grep | head -5" \
        2>/dev/null || echo "(remote snapshot unavailable)")
      {
        echo "[$(ts)] [HEARTBEAT] stage=${name} elapsed=${m}m${s}s"
        echo "${snap}" | sed 's/^/    /'
      } | tee -a "${WD_LOG}"
    done
  ) &
  WD_PID=$!
  disown "${WD_PID}" 2>/dev/null || true
  echo "[$(ts)] [stage] start name=${name} watchdog_pid=${WD_PID} heartbeat=${HEARTBEAT_SEC}s log=${WD_LOG}"
}
stop_watchdog() {
  if [ -n "${WD_PID}" ] && kill -0 "${WD_PID}" 2>/dev/null; then
    kill "${WD_PID}" 2>/dev/null || true
    wait "${WD_PID}" 2>/dev/null || true
  fi
  WD_PID=""
}
trap 'stop_watchdog' EXIT INT TERM

# 用 watchdog 包裹一个命令；命令本身原样执行，stdout/stderr 透传
run_with_watchdog() {
  local name="$1"; shift
  local start_epoch=$(date +%s)
  start_watchdog "${name}"
  local rc=0
  "$@" || rc=$?
  stop_watchdog
  local now=$(date +%s)
  local elapsed=$(( now - start_epoch ))
  local m=$(( elapsed / 60 ))
  local s=$(( elapsed % 60 ))
  echo "[$(ts)] [stage] done name=${name} rc=${rc} elapsed=${m}m${s}s"
  return ${rc}
}

# ---------- Stage 1: 盘点 ----------
stage "1/5 inspect"
run_with_watchdog "inspect" bash "${SCRIPT_DIR}/inspect_101.sh" || fail "inspect"

# ---------- Stage 2: 部署 ----------
stage "2/5 deploy"
run_with_watchdog "deploy" bash "${SCRIPT_DIR}/deploy_to_101.sh" || fail "deploy"

# ---------- Stage 3: 数据探查 + 建表（以 hadoop 身份） ----------
if [ "${SKIP_PREPARE:-0}" = "1" ]; then
  stage "3/5 prepare cosn tables -- SKIPPED by SKIP_PREPARE=1"
else
  stage "3/5 prepare cosn tables (as user hadoop)"
  run_with_watchdog "prepare" \
    ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
    "su - hadoop -c 'bash ${HADOOP_DIR}/prepare_cosn_tables.sh'" \
    || fail "prepare_cosn_tables"
fi

# ---------- Stage 4: 跑批（远端 nohup 后台 + 本地轮询） ----------
stage "4/5 bench (profile=${PROFILE}, as user hadoop, background mode)"
BENCH_TS=$(date +%Y%m%d_%H%M%S)
REMOTE_BENCH_LOG="${HADOOP_DIR}/bench_run_${BENCH_TS}.log"
REMOTE_BENCH_PID="${HADOOP_DIR}/bench_run_${BENCH_TS}.pid"

# 1) 远端 nohup 后台启动
echo "[$(ts)] [bench] nohup start on remote, log=${REMOTE_BENCH_LOG}"
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
  "su - hadoop -c 'cd ${HADOOP_DIR} && nohup bash ${HADOOP_DIR}/bench_yarn_cosn.sh ${HADOOP_DIR}/queries_cosn ${PROFILE} > ${REMOTE_BENCH_LOG} 2>&1 & echo \$! > ${REMOTE_BENCH_PID}; sleep 1; cat ${REMOTE_BENCH_PID}'" \
  || fail "bench: nohup start"

# 2) 本地轮询：每 HEARTBEAT_SEC 秒抓一次远端进度尾部 + yarn app 状态
BENCH_START_EPOCH=$(date +%s)
LOCAL_BENCH_LOG="${LOCAL_REPORT_DIR}/bench_run_${BENCH_TS}.log"
: > "${LOCAL_BENCH_LOG}"
PREV_TAIL=""
while true; do
  sleep "${HEARTBEAT_SEC}"
  NOW_EPOCH=$(date +%s)
  ELAPSED=$(( NOW_EPOCH - BENCH_START_EPOCH ))
  M=$(( ELAPSED / 60 )); S=$(( ELAPSED % 60 ))
  # 是否仍在跑
  STILL=$(timeout 15 ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
    "p=\$(cat ${REMOTE_BENCH_PID} 2>/dev/null); [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null && echo RUNNING || echo DONE" 2>/dev/null \
    || echo "UNREACHABLE")
  # 远端日志最后 5 行 + yarn app 状态
  TAIL=$(timeout 20 ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
    "su - hadoop -c 'tail -5 ${REMOTE_BENCH_LOG} 2>/dev/null; echo ---YARN---; yarn application -list 2>/dev/null | grep -E \"RUNNING|ACCEPTED\" | head -3'" 2>/dev/null \
    || echo "(remote tail unavailable)")
  {
    echo "[$(ts)] [HEARTBEAT bench] elapsed=${M}m${S}s status=${STILL}"
    echo "${TAIL}" | sed 's/^/    /'
  } | tee -a "${LOCAL_BENCH_LOG}"

  if [ "${STILL}" = "DONE" ]; then
    echo "[$(ts)] [bench] remote process exited"
    break
  fi
  if [ "${STILL}" = "UNREACHABLE" ]; then
    echo "[$(ts)] [bench][WARN] remote unreachable, will retry next heartbeat"
  fi
done

# 3) 把远端完整日志拉回本地
scp ${SSH_OPTS} \
  "${SSH_USER}@${HOST_IP}:${REMOTE_BENCH_LOG}" \
  "${LOCAL_REPORT_DIR}/bench_run_${BENCH_TS}.full.log" \
  || echo "[$(ts)] [bench][warn] scp full log failed"

BENCH_RC=$(ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
  "su - hadoop -c 'cat ${HADOOP_DIR}/bench_run_${BENCH_TS}.rc 2>/dev/null'" 2>/dev/null || echo "?")
echo "[$(ts)] [stage] done name=bench rc=${BENCH_RC} (see ${LOCAL_REPORT_DIR}/bench_run_${BENCH_TS}.full.log)"

# ---------- Stage 5: 收尾打包 + 回传 ----------
stage "5/5 collect"
REMOTE_TS=$(ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
  "su - hadoop -c 'ls -1 ${HADOOP_DIR}/results 2>/dev/null | sort | tail -1'" || true)
if [ -z "${REMOTE_TS}" ]; then
  fail "collect: no results dir on remote"
fi
echo "[$(ts)] [collect] remote TS=${REMOTE_TS}"

run_with_watchdog "collect_tar" \
  ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
  "su - hadoop -c 'tar czf ${HADOOP_DIR}/bench_${REMOTE_TS}.tar.gz -C ${HADOOP_DIR}/results ${REMOTE_TS} && ls -lh ${HADOOP_DIR}/bench_${REMOTE_TS}.tar.gz'" \
  || fail "collect: tar"

# 让 root 也能 scp（hadoop 家目录可读）
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" \
  "chmod a+r ${HADOOP_DIR}/bench_${REMOTE_TS}.tar.gz ${HADOOP_DIR}/data_inventory.txt 2>/dev/null; chmod a+rx ${HADOOP_DIR}" \
  || true

run_with_watchdog "collect_scp" \
  scp ${SSH_OPTS} \
  "${SSH_USER}@${HOST_IP}:${HADOOP_DIR}/bench_${REMOTE_TS}.tar.gz" \
  "${LOCAL_REPORT_DIR}/" \
  || fail "collect: scp"

# 顺手把 data_inventory.txt 也拉回本地
scp ${SSH_OPTS} \
  "${SSH_USER}@${HOST_IP}:${HADOOP_DIR}/data_inventory.txt" \
  "${LOCAL_REPORT_DIR}/" \
  || echo "[$(ts)] [warn] no data_inventory.txt"

# 解压便于阅读
( cd "${LOCAL_REPORT_DIR}" && tar xzf "bench_${REMOTE_TS}.tar.gz" ) || true

echo
echo "=========================================="
echo "  [$(ts)] ALL DONE"
echo "  remote results: ${HADOOP_DIR}/results/${REMOTE_TS}"
echo "  local mirror  : ${LOCAL_REPORT_DIR}"
echo "  summary       : ${LOCAL_REPORT_DIR}/${REMOTE_TS}/summary_${REMOTE_TS}.md"
echo "=========================================="
