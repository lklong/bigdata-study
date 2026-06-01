#!/bin/bash
# Bench 7 条 SQL，分 native / gluten 两轮
# 用法：./bench_all.sh native | gluten
set -e
export JAVA_HOME=/usr/local/jdk-11.0.10
export PATH=$JAVA_HOME/bin:$PATH
export SPARK_HOME=/usr/local/service/spark
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop

MODE=${1:-native}
BENCH_DIR=/home/hadoop/bench
LOGDIR=$BENCH_DIR/results/$MODE
mkdir -p $LOGDIR

# YARN executor 端 JDK11（EMR 镜像默认在 worker /usr/local/jdk-11.0.10上，无需分发）
WORKER_JAVA_HOME=${WORKER_JAVA_HOME:-/usr/local/jdk-11.0.10}
# tcmalloc（只在提交机上有，通过 --files 分发到 executor 容器）
TCMALLOC_SO=/usr/local/service/spark/meson/libtcmalloc_and_profiler.so
# driver IP（自动获取本机内网 IP，也可手动覆盖）
DRIVER_HOST=${DRIVER_HOST:-$(hostname -I | awk '{print $1}')}

ADD_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

# YARN 集群：2 worker × 4c14g。单容器 max vCores=4。
# 总资源 8c28g，包含 driver+executor。
if [ "$MODE" = "native" ]; then
  # 4 executor × 2c × 5g(heap)+1g(overhead) = 8c 24g
  RES="--num-executors 4 --executor-cores 2 --executor-memory 5g --driver-memory 2g --conf spark.executor.memoryOverhead=1g"
  EXTRA_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false"
else
  # Gluten: 4 executor × 2c × (heap 3g + overhead 0.5g + offHeap 3g) = 8c 26g
  RES="--num-executors 4 --executor-cores 2 --executor-memory 3g --driver-memory 2g --conf spark.executor.memoryOverhead=512m"
  EXTRA_CONF="--conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=3g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false"
fi

run_q() {
  local q=$1
  echo "========== $MODE / $q =========="
  local START=$(date +%s%3N)
  set +e
  # 构建 --files 参数（tcmalloc 存在时分发）
  local FILES_OPT=""
  local LD_PRELOAD_OPT=""
  if [ -f "$TCMALLOC_SO" ]; then
    FILES_OPT="--files $TCMALLOC_SO"
    LD_PRELOAD_OPT="--conf spark.executorEnv.LD_PRELOAD=./libtcmalloc_and_profiler.so"
  fi
  $SPARK_HOME/bin/spark-sql \
    --master yarn --deploy-mode client \
    $RES \
    $FILES_OPT \
    --conf spark.driver.host=${DRIVER_HOST} \
    --conf spark.shuffle.service.enabled=false \
    --conf spark.dynamicAllocation.enabled=false \
    --conf spark.executorEnv.JAVA_HOME=${WORKER_JAVA_HOME} \
    --conf spark.yarn.appMasterEnv.JAVA_HOME=${WORKER_JAVA_HOME} \
    $LD_PRELOAD_OPT \
    --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
    --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
    --conf spark.eventLog.enabled=false \
    --conf spark.sql.adaptive.enabled=true --conf spark.sql.hive.convertMetastoreParquet=true --conf spark.sql.parquet.enableVectorizedReader=true \
    --conf spark.sql.shuffle.partitions=128 \
    $EXTRA_CONF \
    -f "$BENCH_DIR/queries/${q}.sql" > "$LOGDIR/${q}.log" 2>&1
  local RC=$?
  set -e
  local END=$(date +%s%3N)
  local DUR=$(( (END-START) ))
  echo "$q,$MODE,$DUR,$RC" >> "$BENCH_DIR/results/duration_${MODE}.csv"
  if [ $RC -eq 0 ]; then
    echo "  ✓ ${DUR}ms"
  else
    echo "  ✗ FAIL (rc=$RC) - tail of log:"
    tail -8 "$LOGDIR/${q}.log"
  fi
}

echo 'q,mode,duration_ms,rc' > $BENCH_DIR/results/duration_${MODE}.csv

QS=${2:-"q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables"}
for q in $QS; do
  run_q $q
done

echo
echo "====== $MODE 全部完成 ======"
cat $BENCH_DIR/results/duration_${MODE}.csv
