#!/bin/bash
# 5 张表数据生成（按从小到大顺序）
# 用法：./gen_all.sh [表序号 1-5，省略=全跑]
set -e
export JAVA_HOME=/usr/local/jdk-11.0.10
export PATH=$JAVA_HOME/bin:$PATH
export SPARK_HOME=/usr/local/service/spark
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop

ADD_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

BENCH_DIR=/home/hadoop/bench

# YARN executor 端 JDK11（EMR 镜像默认在 worker /usr/local/jdk-11.0.10上，无需分发）
WORKER_JAVA_HOME=${WORKER_JAVA_HOME:-/usr/local/jdk-11.0.10}
# tcmalloc（只在提交机上有，通过 --files 分发到 executor 容器）
TCMALLOC_SO=/usr/local/service/spark/meson/libtcmalloc_and_profiler.so
# driver IP（自动获取本机内网 IP，也可手动覆盖）
DRIVER_HOST=${DRIVER_HOST:-$(hostname -I | awk '{print $1}')}

run_sql() {
  local label="$1"
  local sql="$2"
  local extra_conf="$3"
  echo "=========== run $label ==========="
  local START=$(date +%s)
  # 构建 --files 参数（tcmalloc 存在时分发）
  local FILES_OPT=""
  local LD_PRELOAD_OPT=""
  if [ -f "$TCMALLOC_SO" ]; then
    FILES_OPT="--files $TCMALLOC_SO"
    LD_PRELOAD_OPT="--conf spark.executorEnv.LD_PRELOAD=./libtcmalloc_and_profiler.so"
  fi
  $SPARK_HOME/bin/spark-sql \
    --master yarn --deploy-mode client \
    --num-executors 9 --executor-cores 5 --executor-memory 9g --driver-memory 2g --conf spark.executor.memoryOverhead=2g \
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
    $extra_conf \
    -f "$sql" 2>&1 | tee "$BENCH_DIR/results/${label}.log" | tail -40
  local END=$(date +%s)
  echo "${label} DURATION = $((END-START))s" | tee -a "$BENCH_DIR/results/duration.txt"
}

# 数据生成必须 Native 跑（关 Gluten plugin）
GEN_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false --conf spark.sql.parquet.compression.codec=snappy"

case "$1" in
  init) run_sql "gen_init" "$BENCH_DIR/gen/_init.sql" "$GEN_CONF" ;;
  1) run_sql "gen_01_customers" "$BENCH_DIR/gen/01_customers.sql" "$GEN_CONF" ;;
  2) run_sql "gen_02_products" "$BENCH_DIR/gen/02_products.sql" "$GEN_CONF" ;;
  3) run_sql "gen_03_reviews" "$BENCH_DIR/gen/03_reviews.sql" "$GEN_CONF" ;;
  4) run_sql "gen_04_orders" "$BENCH_DIR/gen/04_orders.sql" "$GEN_CONF" ;;
  5) run_sql "gen_05_order_items" "$BENCH_DIR/gen/05_order_items.sql" "$GEN_CONF" ;;
  ''|all)
    run_sql "gen_init" "$BENCH_DIR/gen/_init.sql" "$GEN_CONF"
    run_sql "gen_01_customers" "$BENCH_DIR/gen/01_customers.sql" "$GEN_CONF"
    run_sql "gen_02_products" "$BENCH_DIR/gen/02_products.sql" "$GEN_CONF"
    run_sql "gen_03_reviews" "$BENCH_DIR/gen/03_reviews.sql" "$GEN_CONF"
    run_sql "gen_04_orders" "$BENCH_DIR/gen/04_orders.sql" "$GEN_CONF"
    run_sql "gen_05_order_items" "$BENCH_DIR/gen/05_order_items.sql" "$GEN_CONF"
    ;;
  *) echo "用法: $0 [init|1|2|3|4|5|all]"; exit 1 ;;
esac

echo "==== 数据汇总 ===="
hadoop fs -du -h hdfs://HDFS8028747/user/hadoop/bench/ 2>/dev/null || true
