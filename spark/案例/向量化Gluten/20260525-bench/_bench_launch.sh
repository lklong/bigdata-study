#!/bin/bash
# 阶段一：deploy + 远端 nohup 启动 bench（不等待完成，立刻返回）
set -eu

PROFILE="${1:-max}"
HOST_IP="${HOST_IP:-101.43.161.139}"
SSH_USER="${SSH_USER:-root}"
PEM_PATH="${PEM_PATH:-/c/Users/lkl/Desktop/lkl_meson.pem}"
SSH_OPTS="-i ${PEM_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
REMOTE_DIR="/root/bench-101"
HADOOP_DIR="/home/hadoop/bench-101"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GLUTEN_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
TS=$(date +%Y%m%d_%H%M%S)
LOCAL_REPORT_DIR="${GLUTEN_DIR}/reports/${HOST_IP}_${TS}"
mkdir -p "${LOCAL_REPORT_DIR}"
STATE_FILE="${SCRIPT_DIR}/_bench_state.env"

GLUTEN_ONLY_VAL="${BENCH_GLUTEN_ONLY:-0}"
NATIVE_ONLY_VAL="${BENCH_NATIVE_ONLY:-0}"

ts() { date +'%H:%M:%S'; }

echo "[$(ts)] === Stage A: deploy ==="
bash "${SCRIPT_DIR}/deploy_to_101.sh"

echo
echo "[$(ts)] === Stage B: nohup launch bench (profile=${PROFILE}) on remote ==="
BENCH_TS=$(date +%Y%m%d_%H%M%S)
REMOTE_BENCH_LOG="${HADOOP_DIR}/bench_run_${BENCH_TS}.log"
REMOTE_BENCH_PID="${HADOOP_DIR}/bench_run_${BENCH_TS}.pid"
REMOTE_BENCH_RC="${HADOOP_DIR}/bench_run_${BENCH_TS}.rc"
REMOTE_LAUNCHER="${HADOOP_DIR}/.launcher_${BENCH_TS}.sh"

# 1) 在本地生成远端 launcher 脚本（已展开所有变量），再 scp 上去执行
LOCAL_LAUNCHER=$(mktemp -t bench_launcher.XXXXXX.sh)
cat > "${LOCAL_LAUNCHER}" <<EOL
#!/bin/bash
set -e
cd ${HADOOP_DIR}
export BENCH_GLUTEN_ONLY=${GLUTEN_ONLY_VAL}
export BENCH_NATIVE_ONLY=${NATIVE_ONLY_VAL}
echo "[launcher] BENCH_GLUTEN_ONLY=\${BENCH_GLUTEN_ONLY} BENCH_NATIVE_ONLY=\${BENCH_NATIVE_ONLY} PROFILE=${PROFILE}"
nohup bash -c '
  bash ${HADOOP_DIR}/bench_yarn_cosn.sh ${HADOOP_DIR}/queries_cosn ${PROFILE}
  rc=\$?
  echo \$rc > ${REMOTE_BENCH_RC}
' > ${REMOTE_BENCH_LOG} 2>&1 &
echo \$! > ${REMOTE_BENCH_PID}
sleep 2
cat ${REMOTE_BENCH_PID}
ls -la ${REMOTE_BENCH_LOG}
EOL

# 2) 上传 launcher 并 chown 给 hadoop
scp ${SSH_OPTS} "${LOCAL_LAUNCHER}" "${SSH_USER}@${HOST_IP}:${REMOTE_LAUNCHER}" >/dev/null
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" "chown hadoop:hadoop ${REMOTE_LAUNCHER}; chmod +x ${REMOTE_LAUNCHER}"
rm -f "${LOCAL_LAUNCHER}"

# 3) 以 hadoop 身份执行 launcher
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" "su - hadoop -c 'bash ${REMOTE_LAUNCHER}'"

cat > "${STATE_FILE}" <<EOS
LOCAL_REPORT_DIR=${LOCAL_REPORT_DIR}
BENCH_TS=${BENCH_TS}
REMOTE_BENCH_LOG=${REMOTE_BENCH_LOG}
REMOTE_BENCH_PID=${REMOTE_BENCH_PID}
REMOTE_BENCH_RC=${REMOTE_BENCH_RC}
PROFILE=${PROFILE}
EOS

echo
echo "[$(ts)] === Launch DONE ==="
echo "  LOCAL_REPORT_DIR = ${LOCAL_REPORT_DIR}"
echo "  REMOTE_BENCH_LOG = ${REMOTE_BENCH_LOG}"
echo "  REMOTE_BENCH_PID = ${REMOTE_BENCH_PID}"
echo "  REMOTE_BENCH_RC  = ${REMOTE_BENCH_RC}"
echo "  state file       = ${STATE_FILE}"
echo
echo "下一步轮询：bash _bench_poll.sh"
