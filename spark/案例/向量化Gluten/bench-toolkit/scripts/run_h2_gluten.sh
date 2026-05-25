#!/bin/bash
# H2 集群 组1 Gluten - Spark 3.5.8 社区版 + Gluten 1.6.0 + Kona JDK17
# 完全 1:1 复刻组2跑通的 run_h2_emr.sh 配置，仅替换：
#   - SPARK_HOME: EMR → 社区版 3.5.8
#   - Gluten: 1.5.0 → 1.6.0
#   - JDK: 11 → 17
#   - 资源拉满: 9×5c×5g → 24×4c×12g (96c/384GB)

set -u

SPARK_HOME=/opt/spark-3.5.8-bin-hadoop3
GLUTEN_JAR=/opt/gluten-jars-stash/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.6.0.jar
DRIVER_JDK=/tmp/jdk-runtime/TencentKona-17.0.18.b1

JDK_ARCHIVE=hdfs:///bench/lib/jdk17.tar.gz
JDK_REL=./jdk/TencentKona-17.0.18.b1

export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop
export HADOOP_HOME=/usr/local/service/hadoop

DRIVER_HOST=$(hostname -I | awk '{print $1}')
ADD_OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true'

QS='q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables'
RESULTS=/home/hadoop/bench/results
mkdir -p $RESULTS

# 资源拉满（H2 集群: 3 节点 x 32c/115GB = 96c/345GB）
# Native:  24 executor x 4c x 11g + 2g overhead = 96c, 24*13=312GB
# Gluten:  24 executor x 4c x 6g  + 2g overhead + 8g offheap = 96c, 24*16=384GB
RES_NATIVE='--num-executors 24 --executor-cores 4 --executor-memory 11g --driver-memory 4g --conf spark.executor.memoryOverhead=2g'
RES_GLUTEN='--num-executors 24 --executor-cores 4 --executor-memory 6g  --driver-memory 4g --conf spark.executor.memoryOverhead=2g'

run_one() {
  local mode=$1 round=$2
  local label=group1_${mode}_round${round}
  local LOGDIR=$RESULTS/$label
  mkdir -p $LOGDIR
  local CSV=$RESULTS/duration_${label}.csv
  echo 'q,mode,duration_ms,rc' > $CSV

  local RES EXTRA
  if [ "$mode" = native ]; then
    RES="$RES_NATIVE"
    EXTRA='--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false'
  else
    RES="$RES_GLUTEN"
    EXTRA="--jars $GLUTEN_JAR --conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=8g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false"
  fi

  echo "========= $label ========="
  # 允许命令行只跑某个 Q
  local QLIST="$QS"
  [ -n "${ONLY_Q:-}" ] && QLIST="$ONLY_Q"

  for q in $QLIST; do
    echo "  >>> $q"
    local START=$(date +%s%3N)
    set +e
    JAVA_HOME=$DRIVER_JDK PATH=$DRIVER_JDK/bin:$PATH \
    timeout 1800 $SPARK_HOME/bin/spark-sql \
      --master yarn --deploy-mode client $RES \
      --archives "${JDK_ARCHIVE}#jdk" \
      --conf spark.driver.host=$DRIVER_HOST \
      --conf spark.shuffle.service.enabled=false \
      --conf spark.dynamicAllocation.enabled=false \
      --conf spark.executorEnv.JAVA_HOME=$JDK_REL \
      --conf spark.yarn.appMasterEnv.JAVA_HOME=$JDK_REL \
      --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
      --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
      --conf spark.eventLog.enabled=true \
      --conf spark.eventLog.dir=hdfs://172.21.240.197:4007/spark-history \
      --conf spark.sql.adaptive.enabled=true \
      --conf spark.sql.hive.convertMetastoreParquet=true \
      --conf spark.sql.parquet.enableVectorizedReader=true \
      --conf spark.sql.shuffle.partitions=400 \
      $EXTRA \
      -f /home/hadoop/bench/queries_cosn/${q}.sql > $LOGDIR/${q}.log 2>&1
    local RC=$?
    set -e
    local END=$(date +%s%3N)
    local DUR=$((END-START))
    echo "$q,$mode,$DUR,$RC" >> $CSV
    if [ $RC -eq 0 ]; then echo "    OK ${DUR}ms"; else echo "    FAIL rc=$RC"; fi
  done
}

# 用法: bash run_h2_gluten.sh             跑全部 7Q × 2 round
#       bash run_h2_gluten.sh q1_agg      只跑 q1_agg × 2 round
#       bash run_h2_gluten.sh q1_agg 1    只跑 q1_agg × round 1
ONLY_Q="${1:-}"
ONLY_ROUND="${2:-}"

if [ -n "$ONLY_ROUND" ]; then
  run_one gluten $ONLY_ROUND
else
  for r in 1 2; do
    run_one gluten $r
    sleep 10
  done
fi

echo "===== Gluten 完成 ====="
ls -la $RESULTS/duration_group1_gluten*.csv 2>/dev/null
