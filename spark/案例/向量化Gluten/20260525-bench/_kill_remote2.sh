#!/bin/bash
# 远端清理：杀掉所有 bench/Spark 残留 + YARN 上残留 app
echo "[1] kill local processes"
pkill -9 -f 'bench_yarn_cosn' 2>/dev/null || true
pkill -9 -f 'SparkSubmit'      2>/dev/null || true
pkill -9 -f 'spark-submit'     2>/dev/null || true
sleep 2
echo "[2] residual check"
ps -ef | grep -E 'spark-submit|SparkSubmit|bench_yarn' | grep -v grep || echo "[clean] no residual processes"

echo "[3] yarn running apps"
APPS=$(sudo -u hadoop yarn application -list 2>/dev/null | awk '/RUNNING|ACCEPTED/ && /SparkSQL/ {print $1}')
echo "running_apps=[${APPS}]"
for a in ${APPS}; do
  echo "killing ${a}"
  sudo -u hadoop yarn application -kill "${a}" 2>&1 | tail -2
done
echo "[done]"
