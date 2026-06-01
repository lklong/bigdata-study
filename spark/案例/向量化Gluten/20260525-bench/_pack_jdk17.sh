#!/bin/bash
# 一次性把 Master 节点的 JDK17 打包到 hadoop 家目录，供 bench 脚本 --archives 分发
set -e

echo "[step 1] tar -czf /home/hadoop/jdk17.tgz ..."
if [ ! -f /home/hadoop/jdk17.tgz ]; then
  cd /usr/lib/jvm
  tar -czf /tmp/jdk17.tgz TencentKona-17.0.18.b1
  mv /tmp/jdk17.tgz /home/hadoop/jdk17.tgz
  chown hadoop:hadoop /home/hadoop/jdk17.tgz
fi
ls -lh /home/hadoop/jdk17.tgz

echo "[step 2] hadoop fs -put to /user/hadoop/jdk17.tgz (用户态 HDFS 路径)"
su - hadoop -c "
  hadoop fs -test -e /user/hadoop/jdk17.tgz 2>/dev/null || hadoop fs -put -f /home/hadoop/jdk17.tgz /user/hadoop/jdk17.tgz
  hadoop fs -ls /user/hadoop/jdk17.tgz
"
echo "[done]"
