#!/bin/bash
set -e
source /opt/spark-poc/conf/spark-env.sh

SQL_FILE=${1:-/opt/spark-poc/queries/q_complex.sql}
RESULT_DIR=/opt/spark-poc/results
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p $RESULT_DIR

# JDK 17 完整 add-opens（含 jdk.internal）+ Netty 反射开关
JAVA_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

COMMON_OPTS="--master yarn --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1 --conf spark.executorEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1 --deploy-mode client --num-executors 6 --executor-cores 2 --executor-memory 2g --driver-memory 2g --conf spark.eventLog.enabled=false --conf spark.sql.adaptive.enabled=false --conf spark.sql.shuffle.partitions=50"

NATIVE_OUT=$RESULT_DIR/native_${TS}.out
NATIVE_LOG=$RESULT_DIR/native_${TS}.log
GLUTEN_OUT=$RESULT_DIR/gluten_${TS}.out
GLUTEN_LOG=$RESULT_DIR/gluten_${TS}.log

echo "=========================================="
echo "  Bench - $(date)"
echo "=========================================="

echo ""
echo "[1/2] Native Spark..."
START=$(date +%s)
/opt/spark-poc/bin/spark-sql $COMMON_OPTS \
  --conf "spark.driver.extraJavaOptions=$JAVA_OPENS" \
  --conf "spark.executor.extraJavaOptions=$JAVA_OPENS" \
  -f $SQL_FILE > $NATIVE_OUT 2> $NATIVE_LOG && \
  END=$(date +%s) && NATIVE_TIME=$((END - START)) || \
  { NATIVE_TIME=0; echo "  Native FAILED"; }
echo "  Native: ${NATIVE_TIME}s"

echo ""
echo "[2/2] Gluten + Velox..."
START=$(date +%s)
/opt/spark-poc/bin/spark-sql $COMMON_OPTS \
  --conf "spark.driver.extraJavaOptions=$JAVA_OPENS" \
  --conf "spark.executor.extraJavaOptions=$JAVA_OPENS" \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=3g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf spark.gluten.memory.allocator=jemalloc \
  --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 \
  -f $SQL_FILE > $GLUTEN_OUT 2> $GLUTEN_LOG && \
  END=$(date +%s) && GLUTEN_TIME=$((END - START)) || \
  { GLUTEN_TIME=0; echo "  Gluten FAILED, see $GLUTEN_LOG"; }
echo "  Gluten: ${GLUTEN_TIME}s"

NATIVE_MD5=$(grep -v "^Time taken\|^$" $NATIVE_OUT 2>/dev/null | md5sum | awk '{print $1}')
GLUTEN_MD5=$(grep -v "^Time taken\|^$" $GLUTEN_OUT 2>/dev/null | md5sum | awk '{print $1}')

if [ $GLUTEN_TIME -gt 0 ] && [ $NATIVE_TIME -gt 0 ]; then
    SPEEDUP=$(echo "scale=2; $NATIVE_TIME / $GLUTEN_TIME" | bc)
else
    SPEEDUP="N/A"
fi
[ "$NATIVE_MD5" = "$GLUTEN_MD5" ] && CONSISTENT="YES" || CONSISTENT="NO"

echo ""
echo "=========================================="
echo "  Native:    ${NATIVE_TIME}s"
echo "  Gluten:    ${GLUTEN_TIME}s"
echo "  Speedup:   ${SPEEDUP}x"
echo "  Consistent: $CONSISTENT"
echo "  Logs: $GLUTEN_LOG"
echo "=========================================="
