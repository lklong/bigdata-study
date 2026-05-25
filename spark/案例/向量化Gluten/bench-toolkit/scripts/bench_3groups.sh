#!/bin/bash
# ====================================================================
# 三组对比测试 - 纯净测试方案（不改集群 JDK / so 全带上 / Kona JDK）
#
# 大哥要的 3 组：
#   组1: H2 + Spark 3.5.8 社区版 + Gluten 1.6.0 vs Native
#   组2: H2 + Spark 3.5.3        + Gluten 1.5.0 vs Native
#   组3: H3 + Spark 3.5.3        + Gluten 1.5.0 vs Native
#
# 数据：cosn://lkl-bj-update-1308597516/meson/data/bench/ （5表 91.7GB）
# 集群：H2=82.156.188.226 / H3=43.143.253.239
# Spark 包：cosn://lkl-bj-update-1308597516/meson  （已有 EMR 包）
#
# 测试规模：每组 7 个 Q × 2 遍取稳定值
# 用法：
#   ./bench_3groups.sh group1   # 只跑组1
#   ./bench_3groups.sh group2   # 只跑组2
#   ./bench_3groups.sh group3   # 只跑组3
#   ./bench_3groups.sh all      # 跑全部 3 组
# ====================================================================
set -u

GROUP=${1:-all}

# ====== 集群参数（部署到对应集群 master 后由 deploy 脚本自动改 IP）======
DRIVER_HOST_PLACEHOLDER=AUTO_DETECT  # 部署时自动改

# ====== Spark / Gluten 路径（部署时由对应集群提供）======
# 组1（H2 only）：Spark 3.5.8 社区版 + Gluten 1.6.0
# ⚠️ 纯净原则：Gluten jar 不放进 spark/jars/，单独 --jars 提交
SPARK_HOME_358="/opt/spark-3.5.8-bin-hadoop3"
GLUTEN_JAR_160="/opt/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.6.0.jar"

# 组2/组3：Spark 3.5.3 + Gluten 1.5.0-SNAPSHOT (集群默认安装位置)
SPARK_HOME_353="/usr/local/service/spark"
GLUTEN_JAR_150="$SPARK_HOME_353/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar"

# ====== JDK：Kona JDK，只在 shell session 临时设置，不污染集群 ======
# Driver 端：master 本地 JDK（master 上原本就有，不修改集群默认配置）
# Executor 端：通过 spark.yarn.dist.archives 从 HDFS 分发到 container，worker 节点不需要预装
KONA_JDK17="/usr/lib/jvm/TencentKona-17.0.18.b1"     # 组1 用（Spark 3.5.8 社区是 JDK17 编译）
KONA_JDK11="/usr/local/jdk-11.0.27"                  # 组2/3 用（master driver 端，绝对路径）

# HDFS 上预先打包好的 Kona JDK11 archive（executor 端用）
# 路径格式：hdfs:///bench/lib/kona-jdk11.tar.gz  解压后 container 内目录为 ./jdk/jdk-11.0.27
JDK11_ARCHIVE_HDFS="hdfs:///bench/lib/kona-jdk11.tar.gz"
JDK11_ARCHIVE_CONTAINER="./jdk/jdk-11.0.27"   # archive 解压后 container 中的相对路径

# ====== Hadoop 配置 ======
HADOOP_CONF_DIR="/usr/local/service/hadoop/etc/hadoop"
HADOOP_HOME="/usr/local/service/hadoop"

# ====== 资源（按集群最大资源拉满，每组对齐保证公平）======
EXEC_NUM=9
EXEC_CORES=5
DRIVER_MEM=2g
SHUFFLE_PARTS=128

# ====== 数据 / 结果路径 ======
BENCH_DIR=/home/hadoop/bench
QUERIES_DIR=$BENCH_DIR/queries_cosn
RESULTS_BASE=$BENCH_DIR/results

# JDK 高版本必须的 add-opens
ADD_OPENS="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true"

QS="q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables"

# ============================================================
# 通用执行函数
# ============================================================
run_one() {
  local label=$1     # group1_native / group1_gluten / group2_native ...
  local spark_home=$2
  local java_home=$3
  local mode=$4      # native | gluten
  local extra_conf=$5
  local round=$6     # 1 | 2

  local LOGDIR=$RESULTS_BASE/${label}_round${round}
  mkdir -p "$LOGDIR"

  # 资源配置：Native vs Gluten 对齐
  local RES
  if [ "$mode" = "native" ]; then
    RES="--num-executors $EXEC_NUM --executor-cores $EXEC_CORES --executor-memory 9g --driver-memory $DRIVER_MEM --conf spark.executor.memoryOverhead=2g"
  else
    RES="--num-executors $EXEC_NUM --executor-cores $EXEC_CORES --executor-memory 5g --driver-memory $DRIVER_MEM --conf spark.executor.memoryOverhead=1g"
  fi

  local CSV=$RESULTS_BASE/duration_${label}_round${round}.csv
  echo 'q,mode,duration_ms,rc' > "$CSV"

  echo "==================== $label round-$round ===================="

  for q in $QS; do
    echo "  >>> $q"
    local START=$(date +%s%3N)
    set +e
    # 临时设置 JAVA_HOME，只对当前命令生效（driver 端用 master 本地 JDK），不污染集群
    # executor 端 JAVA_HOME 由 extra_conf 里的 spark.executorEnv.JAVA_HOME 控制（archive 方式）
    JAVA_HOME=$java_home PATH=$java_home/bin:$PATH \
    $spark_home/bin/spark-sql \
      --master yarn --deploy-mode client \
      $RES \
      --conf spark.driver.host=$DRIVER_HOST \
      --conf spark.shuffle.service.enabled=false \
      --conf spark.dynamicAllocation.enabled=false \
      --conf "spark.driver.extraJavaOptions=$ADD_OPENS" \
      --conf "spark.executor.extraJavaOptions=$ADD_OPENS" \
      --conf spark.eventLog.enabled=false \
      --conf spark.sql.adaptive.enabled=true \
      --conf spark.sql.hive.convertMetastoreParquet=true \
      --conf spark.sql.parquet.enableVectorizedReader=true \
      --conf spark.sql.shuffle.partitions=$SHUFFLE_PARTS \
      $extra_conf \
      -f "$QUERIES_DIR/${q}.sql" > "$LOGDIR/${q}.log" 2>&1
    local RC=$?
    set -e
    local END=$(date +%s%3N)
    local DUR=$(( END - START ))
    echo "$q,$mode,$DUR,$RC" >> "$CSV"
    if [ $RC -eq 0 ]; then
      echo "    ✓ ${DUR}ms"
    else
      echo "    ✗ FAIL rc=$RC -- $(tail -3 $LOGDIR/${q}.log | tr '\n' ' ')"
    fi
  done
  echo
  echo "------ $label round-$round 汇总 ------"
  cat "$CSV"
  echo
}

# ============================================================
# 组1: H2 + Spark 3.5.8 社区版 + Gluten 1.6.0 vs Native (Kona JDK17)
# ============================================================
group1() {
  if [ ! -d "$SPARK_HOME_358" ]; then
    echo "✗ Spark 3.5.8 不存在: $SPARK_HOME_358"
    echo "  请先把社区版 spark-3.5.8-bin-hadoop3 解压到该路径"
    return 1
  fi
  if [ ! -f "$GLUTEN_JAR_160" ]; then
    echo "✗ Gluten 1.6.0 jar 不存在: $GLUTEN_JAR_160"
    return 1
  fi
  if [ ! -d "$KONA_JDK17" ]; then
    echo "✗ Kona JDK17 不存在: $KONA_JDK17"
    return 1
  fi

  local NATIVE_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false"
  local GLUTEN_CONF="--jars $GLUTEN_JAR_160 --conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=8g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false --conf spark.driver.extraClassPath=$GLUTEN_JAR_160 --conf spark.executor.extraClassPath=$GLUTEN_JAR_160"

  for round in 1 2; do
    run_one group1_native "$SPARK_HOME_358" "$KONA_JDK17" native "$NATIVE_CONF" $round
    sleep 10
    run_one group1_gluten "$SPARK_HOME_358" "$KONA_JDK17" gluten "$GLUTEN_CONF" $round
    sleep 10
  done
}

# ============================================================
# 组2: H2 + Spark 3.5.3 + Gluten 1.5.0-SNAPSHOT vs Native (Kona JDK11)
# ============================================================
group2() {
  if [ ! -d "$SPARK_HOME_353" ]; then
    echo "✗ Spark 3.5.3 不存在: $SPARK_HOME_353"
    return 1
  fi
  if [ ! -f "$GLUTEN_JAR_150" ]; then
    echo "✗ Gluten 1.5.0 jar 不存在: $GLUTEN_JAR_150"
    return 1
  fi
  if [ ! -d "$KONA_JDK11" ]; then
    echo "✗ Kona JDK11 不存在: $KONA_JDK11"
    return 1
  fi

  local NATIVE_CONF="--conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false"
  local GLUTEN_CONF="--conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=8g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false"

  for round in 1 2; do
    run_one group2_native "$SPARK_HOME_353" "$KONA_JDK11" native "$NATIVE_CONF" $round
    sleep 10
    run_one group2_gluten "$SPARK_HOME_353" "$KONA_JDK11" gluten "$GLUTEN_CONF" $round
    sleep 10
  done
}

# ============================================================
# 组3: H3 + Spark 3.5.3 + Gluten 1.5.0-SNAPSHOT vs Native (Kona JDK11)
# 与组2 完全相同的命令，区别在于运行集群是 H3
# ============================================================
group3() {
  group2_implementation_for_h3
}

group2_implementation_for_h3() {
  if [ ! -d "$SPARK_HOME_353" ]; then echo "✗ Spark 3.5.3 不存在"; return 1; fi
  if [ ! -f "$GLUTEN_JAR_150" ]; then echo "✗ Gluten 1.5.0 不存在"; return 1; fi
  if [ ! -d "$KONA_JDK11" ]; then echo "✗ Kona JDK11 不存在: $KONA_JDK11"; return 1; fi

  # 验证 HDFS 上的 JDK archive 是否存在
  if ! hadoop fs -test -e "$JDK11_ARCHIVE_HDFS"; then
    echo "✗ HDFS 上未找到 JDK archive: $JDK11_ARCHIVE_HDFS"
    echo "  请先运行: hadoop fs -mkdir -p /bench/lib && cd /usr/local && tar czf /tmp/kona-jdk11.tar.gz jdk-11.0.27/ && hadoop fs -put -f /tmp/kona-jdk11.tar.gz /bench/lib/"
    return 1
  fi

  # JDK archive 分发 conf：所有 executor 都用 container 内解压出的 JDK，集群节点不需要预装
  local JDK_ARCHIVE_CONF="--conf spark.yarn.dist.archives=$JDK11_ARCHIVE_HDFS#jdk --conf spark.executorEnv.JAVA_HOME=$JDK11_ARCHIVE_CONTAINER --conf spark.yarn.appMasterEnv.JAVA_HOME=$JDK11_ARCHIVE_CONTAINER"

  # Native：纯 Spark，不带 Gluten
  local NATIVE_CONF="$JDK_ARCHIVE_CONF --conf spark.plugins= --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager --conf spark.memory.offHeap.enabled=false"

  # Gluten：通过 --jars 分发 jar（jar 内嵌所有 .so，纯净测试不依赖集群预装）
  # executor 端 extraClassPath 用 jar 文件名（YARN 会把 --jars 分发的文件放到 container 工作目录）
  local GLUTEN_JAR_NAME=$(basename "$GLUTEN_JAR_150")
  local GLUTEN_CONF="$JDK_ARCHIVE_CONF --jars $GLUTEN_JAR_150 --conf spark.driver.extraClassPath=$GLUTEN_JAR_150 --conf spark.executor.extraClassPath=$GLUTEN_JAR_NAME --conf spark.plugins=org.apache.gluten.GlutenPlugin --conf spark.gluten.sql.columnar.backend.lib=velox --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager --conf spark.memory.offHeap.enabled=true --conf spark.memory.offHeap.size=8g --conf spark.gluten.memory.allocator=jemalloc --conf spark.gluten.sql.columnar.backend.velox.spillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false --conf spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false"

  for round in 1 2; do
    run_one group3_native "$SPARK_HOME_353" "$KONA_JDK11" native "$NATIVE_CONF" $round
    sleep 10
    run_one group3_gluten "$SPARK_HOME_353" "$KONA_JDK11" gluten "$GLUTEN_CONF" $round
    sleep 10
  done
}

# ============================================================
# 自动检测 driver host
# ============================================================
DRIVER_HOST=$(hostname -I | awk '{print $1}')
echo "DRIVER_HOST = $DRIVER_HOST"
echo "GROUP       = $GROUP"
echo

case "$GROUP" in
  group1) group1 ;;
  group2) group2 ;;
  group3) group3 ;;
  all)
    group1
    group2
    group3
    ;;
  *) echo "用法: $0 {group1|group2|group3|all}" ; exit 1 ;;
esac

echo
echo "============================================================"
echo "  全部完成！结果在: $RESULTS_BASE/duration_*.csv"
echo "============================================================"
ls -la $RESULTS_BASE/duration_*.csv 2>/dev/null
