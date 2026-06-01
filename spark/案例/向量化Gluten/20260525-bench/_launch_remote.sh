#!/bin/bash
# 远端启动新一轮 Gluten-only max 跑批
set -e
TS=$(date +%Y%m%d_%H%M%S)
LOG="/home/hadoop/bench-101/bench_run_${TS}.out"
PID="/home/hadoop/bench-101/bench_run_${TS}.pid"

# 校验新版 md5（必须与本地一致）
echo "[verify] md5 of remote bench_yarn_cosn.sh:"
md5sum /home/hadoop/bench-101/bench_yarn_cosn.sh

# 切到 hadoop 身份后台启动
sudo -u hadoop -H bash -c "
  cd /home/hadoop/bench-101
  nohup env BENCH_GLUTEN_ONLY=1 bash /home/hadoop/bench-101/bench_yarn_cosn.sh /home/hadoop/bench-101/queries_cosn max > ${LOG} 2>&1 &
  echo \$! > ${PID}
  sleep 2
  cat ${PID}
"

echo ""
echo "[launched]"
echo "  TS  = ${TS}"
echo "  LOG = ${LOG}"
echo "  PID = $(cat ${PID})"
echo "  pid_file = ${PID}"
echo ""
echo "tail -n 50 ${LOG}:"
sleep 3
tail -n 50 ${LOG} || true
