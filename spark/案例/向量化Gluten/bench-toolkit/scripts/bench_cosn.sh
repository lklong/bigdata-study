#!/bin/bash
# Bench 7 条 SQL，分 native / gluten 两轮
# 用法：./bench_all.sh native | gluten
set -e
export JAVA_HOME=/usr/lib/jvm/java-11
export PATH=$JAVA_HOME/bin:$PATH
export SPARK_HOME=/usr/local/service/spark
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop

MODE=${1:-native}
BENCH_DIR=/home/hadoop/bench
LOGDIR=$BENCH_DIR/results/cosn_$MODE
mkdir -p $LOGDIR

ADD_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

# YARN 总 48c96g，榨干用：driver 2c2g + 9 executor × 5c × 10g = 47c 92g
if [ "$MODE" = "native" ]; then
  RES="--num-executors 9 --executor-cores 5 --executor-memory 9g --driver-memory 2g --conf spark.executor.memoryOverhead=2g"
  EXTRA_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false"
else
  # Gluten: heap 6g + offHeap 4g = 10g, 9 executor 同样榨干
  RES="--num-executors 9 --executor-cores 5 --executor-memory 5g --driver-memory 2g --conf spark.executor.memoryOverhead=1g"
  EXTRA_CONF="--conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=8g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false"
fi

run_q() {
  local q=$1
  echo "========== $MODE / $q =========="
  local START=$(date +%s%3N)
  set +e
  $SPARK_HOME/bin/spark-sql \
    --master yarn --deploy-mode client \
    $RES \
    --conf spark.driver.host=172.21.240.111 \
    --conf spark.shuffle.service.enabled=false \
    --conf spark.dynamicAllocation.enabled=false \
    --conf spark.executorEnv.JAVA_HOME=/usr/lib/jvm/java-11 \
    --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/java-11 \
    --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
    --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
    --conf spark.eventLog.enabled=false \
    --conf spark.sql.adaptive.enabled=true --conf spark.sql.hive.convertMetastoreParquet=true --conf spark.sql.parquet.enableVectorizedReader=true \
    --conf spark.sql.shuffle.partitions=128 \
    $EXTRA_CONF \
    -f "$BENCH_DIR/queries_cosn/${q}.sql" > "$LOGDIR/${q}.log" 2>&1
  local RC=$?
  set -e
  local END=$(date +%s%3N)
  local DUR=$(( (END-START) ))
  echo "$q,$MODE,$DUR,$RC" >> "$BENCH_DIR/results/duration_cosn_${MODE}.csv"
  if [ $RC -eq 0 ]; then
    echo "  ✓ ${DUR}ms"
  else
    echo "  ✗ FAIL (rc=$RC) - tail of log:"
    tail -8 "$LOGDIR/${q}.log"
  fi
}

echo 'q,mode,duration_ms,rc' > $BENCH_DIR/results/duration_cosn_${MODE}.csv

QS=${2:-"q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables"}
for q in $QS; do
  run_q $q
done

echo
echo "====== $MODE 全部完成 ======"
cat $BENCH_DIR/results/duration_cosn_${MODE}.csv
