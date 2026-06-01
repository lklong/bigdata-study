#!/bin/bash
# 阶段二：单次轮询。每次执行打印一次心跳，可重复调用。
# 完成时返回 exit 0，未完成返回 exit 2。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_FILE="${SCRIPT_DIR}/_bench_state.env"
[ -f "${STATE_FILE}" ] || { echo "no state file: ${STATE_FILE}, run _bench_launch.sh first" >&2; exit 1; }
. "${STATE_FILE}"

HOST_IP="${HOST_IP:-101.43.161.139}"
SSH_USER="${SSH_USER:-root}"
PEM_PATH="${PEM_PATH:-/c/Users/lkl/Desktop/lkl_meson.pem}"
SSH_OPTS="-i ${PEM_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
HADOOP_DIR="/home/hadoop/bench-101"

ts() { date +'%H:%M:%S'; }

# 远端探测
PROBE=$(timeout 25 ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" "bash -s" <<EOF 2>/dev/null || echo "UNREACHABLE"
set +e
p=\$(cat ${REMOTE_BENCH_PID} 2>/dev/null)
if [ -n "\$p" ] && kill -0 \$p 2>/dev/null; then echo "STATUS:RUNNING pid=\$p"; else echo "STATUS:DONE"; fi
echo "---LOG-TAIL---"
tail -8 ${REMOTE_BENCH_LOG} 2>/dev/null
echo "---RC---"
cat ${REMOTE_BENCH_RC} 2>/dev/null
echo "---YARN---"
su - hadoop -c 'yarn application -list 2>/dev/null | grep -E "RUNNING|ACCEPTED" | head -3'
echo "---DUR-CSV---"
ls -la ${HADOOP_DIR}/results/ 2>/dev/null | tail -3
TS_LATEST=\$(ls -1 ${HADOOP_DIR}/results 2>/dev/null | sort | tail -1)
[ -n "\$TS_LATEST" ] && cat ${HADOOP_DIR}/results/\$TS_LATEST/duration_cosn_native.csv 2>/dev/null
[ -n "\$TS_LATEST" ] && cat ${HADOOP_DIR}/results/\$TS_LATEST/duration_cosn_gluten.csv 2>/dev/null
EOF
)

echo "[$(ts)] === bench poll ==="
echo "${PROBE}"

# 是否完成
echo "${PROBE}" | grep -q "STATUS:DONE" && exit 0 || exit 2
