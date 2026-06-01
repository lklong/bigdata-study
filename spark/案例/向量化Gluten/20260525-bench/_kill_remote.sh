#!/bin/bash
# 临时辅助：杀掉远端 hadoop 用户的 bench 进程 + YARN application
set +e

echo "--- step 1: kill bash bench ---"
pkill -u hadoop -f 'bench_yarn_cosn.sh' 2>/dev/null
pkill -u hadoop -f 'prepare_cosn_tables.sh' 2>/dev/null
pkill -u hadoop -f 'SparkSubmit.*queries_cosn' 2>/dev/null
pkill -u hadoop -f 'SparkSubmit.*external_tables' 2>/dev/null
sleep 3

echo "--- step 2: yarn kill RUNNING ---"
su - hadoop -c '
  apps=$(yarn application -list 2>/dev/null | awk "/RUNNING|ACCEPTED/ {print \$1}" | grep "^application_")
  for a in $apps; do
    echo "kill $a"
    yarn application -kill "$a" 2>&1 | tail -3
  done
'
sleep 2

echo "--- step 3: leftover ---"
ps -u hadoop -o pid,etime,cmd 2>/dev/null | grep -E 'spark|bench|java.*queries' | grep -v grep
su - hadoop -c 'yarn application -list 2>/dev/null'
echo "--- DONE ---"
