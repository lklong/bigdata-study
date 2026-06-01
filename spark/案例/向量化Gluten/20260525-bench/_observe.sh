#!/bin/bash
# 远端轮询观察脚本：进程 + q1 log + yarn app
echo "=== ps SparkSubmit / bench_yarn ==="
ps -ef | grep -E 'SparkSubmit|bench_yarn|spark-sql' | grep -v grep | head -5

echo ""
echo "=== yarn running ==="
sudo -u hadoop yarn application -list -appStates RUNNING 2>/dev/null | head -10

echo ""
echo "=== latest run.out tail 20 ==="
LATEST_OUT=$(ls -t /home/hadoop/bench-101/bench_run_*.out 2>/dev/null | head -1)
echo "file: ${LATEST_OUT}"
tail -n 20 "${LATEST_OUT}" 2>/dev/null

echo ""
echo "=== latest result dir ==="
LATEST_RESULT=$(ls -td /home/hadoop/bench-101/results/*/ 2>/dev/null | head -1)
echo "dir: ${LATEST_RESULT}"
ls -lh "${LATEST_RESULT}" 2>/dev/null

echo ""
echo "=== q1_agg_gluten.log tail 50 ==="
tail -n 50 "${LATEST_RESULT}/q1_agg_gluten.log" 2>/dev/null || echo 'log not yet created'
