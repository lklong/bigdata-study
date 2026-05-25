#!/bin/bash
# H2 集群 组2 纯净版：EMR Spark 3.5.3 + Gluten 1.5.0-SNAPSHOT vs Native
# 设计原则：
#   1) 不动集群默认 JDK / 配置
#   2) JDK 通过 HDFS archive 分发到 executor
#   3) Gluten so 文件已在 jar 内，jar 通过 --jars 分发
set -u

SPARK_HOME=/usr/local/service/spark
GLUTEN_JAR=/home/hadoop/lib/gluten-1.5.0.jar
DRIVER_JDK=/tmp/jdk-runtime/jdk-11.0.27

JDK_ARCHIVE=hdfs:///bench/lib/kona-jdk11.tar.gz
JDK_REL=./jdk/jdk-11.0.27

export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop
export HADOOP_HOME=/usr/local/service/hadoop

DRIVER_HOST=$(hostname -I | awk '{print $1}')
ADD_OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true'

QS='q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables'
RESULTS=/home/hadoop/bench/results
mkdir -p $RESULTS

run_one() {
  local mode=$1 round=$2
  local label=group2_${mode}_round${round}
  local LOGDIR=$RESULTS/$label
  mkdir -p $LOGDIR
  local CSV=$RESULTS/duration_${label}.csv
  echo 'q,mode,duration_ms,rc' > $CSV

  local RES EXTRA
  if [ "$mode" = native ]; then
    RES='--num-executors 9 --executor-cores 5 --executor-memory 9g --driver-memory 2g --conf spark.executor.memoryOverhead=2g'
    EXTRA='--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false'
  else
    RES='--num-executors 9 --executor-cores 5 --executor-memory 5g --driver-memory 2g --conf spark.executor.memoryOverhead=1g'
    EXTRA="--jars $GLUTEN_JAR --conf spark.driver.extraClassPath=$GLUTEN_JAR --conf spark.executor.extraClassPath=$(basename $GLUTEN_JAR) --conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=8g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false"
  fi

  echo "========= $label ========="
  for q in $QS; do
    echo "  >>> $q"
    local START=$(date +%s%3N)
    set +e
    JAVA_HOME=$DRIVER_JDK PATH=$DRIVER_JDK/bin:$PATH \
    $SPARK_HOME/bin/spark-sql \
      --master yarn --deploy-mode client $RES \
      --archives "${JDK_ARCHIVE}#jdk" \
      --conf spark.driver.host=$DRIVER_HOST \
      --conf spark.shuffle.service.enabled=false \
      --conf spark.dynamicAllocation.enabled=false \
      --conf spark.executorEnv.JAVA_HOME=$JDK_REL \
      --conf spark.yarn.appMasterEnv.JAVA_HOME=$JDK_REL \
      --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
      --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
      --conf spark.eventLog.enabled=false \
      --conf spark.sql.adaptive.enabled=true \
      --conf spark.sql.hive.convertMetastoreParquet=true \
      --conf spark.sql.parquet.enableVectorizedReader=true \
      --conf spark.sql.shuffle.partitions=128 \
      $EXTRA \
      -f /home/hadoop/bench/queries_cosn/${q}.sql > $LOGDIR/${q}.log 2>&1
    local RC=$?
    set -e
    local END=$(date +%s%3N)
    local DUR=$((END-START))
    echo "$q,$mode,$DUR,$RC" >> $CSV
    if [ $RC -eq 0 ]; then echo "    OK ${DUR}ms"; else echo "    FAIL rc=$RC"; fi
  done
  echo "----- $label CSV -----"
  cat $CSV
}

for r in 1 2; do
  run_one native $r
  sleep 10
  run_one gluten $r
  sleep 10
done

echo "===== ALL DONE ====="
ls -la $RESULTS/duration_group2*.csv
