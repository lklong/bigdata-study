#!/bin/bash
# ====================================================================
# 自动安装环境（按 cluster_inspect 输出的 env.json 决策）
#
# 用法：bash install_env.sh [env_json] [toolkit_dir]
# 默认：env_json=/tmp/env.json, toolkit_dir=/tmp/bench-toolkit
# ====================================================================
set -e

ENV_JSON=${1:-/tmp/env.json}
TOOLKIT_DIR=${2:-/tmp/bench-toolkit}

# 包源（可通过环境变量覆盖）
JDK11_URL=${JDK11_URL:-https://lkl-bj-update-1308597516.cos.ap-beijing.myqcloud.com/meson/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz}
# Gluten jar 已经打包在 Spark tar 内（spark/jars/ 下已有 gluten-velox-bundle*.jar），不再单独下载
SPARK_PKG_URL=${SPARK_PKG_URL:-https://lkl-bj-update-1308597516.cos.ap-beijing.myqcloud.com/meson/spark-emr3.5.3-gluten.tar.gz}
SPARK_PKG_PATH=${SPARK_PKG_PATH:-/home/hadoop/spark-emr3.5.3-gluten.tar.gz}  # 本地缓存路径（不存在时从 SPARK_PKG_URL 下载）

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] $*${NC}"; }
ok()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
err()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; }

# ------ 解析 env.json ------
[ -f $ENV_JSON ] || { err "env.json 不存在：$ENV_JSON"; exit 1; }
get() { grep -oE "\"$1\":\s*\"?[^,\"}]*" $ENV_JSON | head -1 | sed 's/.*: *"*//' | sed 's/"$//'; }
get_bool() { grep -oE "\"$1\":\s*(true|false)" $ENV_JSON | head -1 | awk -F: '{gsub(/[ ]/,"",$2); print $2}'; }

NEED_JDK11=$(get_bool need_install)  # JDK11 段
NEED_SPARK=$(grep -A3 '"spark"' $ENV_JSON | grep '"need_install"' | grep -oE 'true|false')
NEED_GLUTEN=$(grep -A3 '"gluten"' $ENV_JSON | grep '"need_install"' | grep -oE 'true|false')
WORKERS=$(grep '"workers"' $ENV_JSON | sed 's/.*: *"//' | sed 's/".*//')
WORKER_SSH=$(get worker_ssh)

# 重新精确解析（避免上面通用 get 抽错）
JDK11_INSTALLED=$(grep -A2 '"jdk11"' $ENV_JSON | grep '"installed"' | grep -oE 'true|false')
SPARK_VER=$(grep -A2 '"spark"' $ENV_JSON | grep '"version"' | head -1 | sed 's/.*: *"//' | sed 's/".*//')
GLUTEN_VER=$(grep -A2 '"gluten"' $ENV_JSON | grep '"version"' | head -1 | sed 's/.*: *"//' | sed 's/".*//')

log "依赖检查："
echo "  JDK 11 已装         : $JDK11_INSTALLED"
echo "  Spark 3.5 版本      : $SPARK_VER"
echo "  Gluten 版本         : $GLUTEN_VER"
echo "  Worker SSH 状态     : $WORKER_SSH"
echo

# ============= 安装 JDK 11（master）=============
if [ "$JDK11_INSTALLED" != "true" ]; then
  log "Step 1: 安装 Tencent Kona JDK 11 到 master"
  cd /tmp
  if [ ! -f kona11.tar.gz ]; then
  wget -q -O kona11.tar.gz "$JDK11_URL" || { err "JDK11 下载失败"; exit 1; }
  fi
  tar -xf kona11.tar.gz -C /usr/local/
  KONA_DIR=$(ls -d /usr/local/TencentKona-11* | head -1)
  ln -snf $KONA_DIR /usr/local/jdk
  ok "JDK 11 已装到 /usr/local/jdk"
else
  ok "JDK 11 已装（跳过）"
fi

# ============= Worker JDK11 校验（EMR 镜像默认有 /usr/local/jdk-11.0.10）=============
# 思路：EMR 出厂镜像 worker 已经有 /usr/local/jdk-11.0.10，无需分发；
#      bench_all.sh 等通过绝对路径 ${WORKER_JAVA_HOME} 引用即可。
log "Step 1b: 校验 worker 上的 JDK 11（不分发，直接引用 EMR 自带 /usr/local/jdk-11.0.10）"

WORKER_JAVA_HOME_EXPECT=/usr/local/jdk-11.0.10
PROBE=/tmp/probe_worker_jdk_inner.sh
cat > $PROBE << 'PROBE_EOF'
#!/bin/bash
H=$(hostname); IP=$(hostname -I | awk '{print $1}')
if [ -x /usr/local/jdk-11.0.10/bin/java ]; then
  V=$(/usr/local/jdk-11.0.10/bin/java -version 2>&1 | head -1)
  echo "OK $H $IP $V"
else
  echo "MISS $H $IP /usr/local/jdk-11.0.10 NOT FOUND"
fi
exit 0
PROBE_EOF
chmod +x $PROBE
chown hadoop:hadoop $PROBE

# 用 hadoop streaming 跑 mapper-only：让每个 worker 节点都跑一次
INPUT_PROBE=/tmp/probe_input_jdk
echo -e "1\n2\n3\n4\n5\n6\n7\n8" > /tmp/probe_lines.txt
su - hadoop -c "hadoop fs -rm -r -f $INPUT_PROBE /tmp/probe_jdk_output 2>/dev/null; hadoop fs -mkdir -p $INPUT_PROBE; hadoop fs -put -f /tmp/probe_lines.txt $INPUT_PROBE/"

STREAM_JAR=$(find /usr/local/service/hadoop -name "hadoop-streaming-*.jar" 2>/dev/null | head -1)
if [ -z "$STREAM_JAR" ]; then
  warn "  未找到 hadoop-streaming jar，跳过 worker JDK 校验"
else
  log "  通过 YARN 在所有 worker 上探测 JDK11（streaming map-only job）"
  PROBE_LOG=$(su - hadoop -c "hadoop jar $STREAM_JAR \
    -D mapreduce.job.reduces=0 \
    -D mapreduce.map.memory.mb=512 \
    -input $INPUT_PROBE \
    -output /tmp/probe_jdk_output \
    -mapper $PROBE \
    -file $PROBE 2>&1" | tail -3)
  
  PROBE_RESULT=$(su - hadoop -c "hadoop fs -cat /tmp/probe_jdk_output/part-* 2>/dev/null" | sort -u)
  echo "$PROBE_RESULT" | while read line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -q "^OK"; then
      ok "  $line"
    else
      err "  $line"
    fi
  done
  
  if echo "$PROBE_RESULT" | grep -q "^MISS"; then
    err "  有 worker 缺少 $WORKER_JAVA_HOME_EXPECT，spark executor 启动会失败"
    err "  对应 worker 需手动安装 JDK11 到 /usr/local/jdk-11.0.10"
    exit 1
  fi
  ok "  所有 worker 已有 $WORKER_JAVA_HOME_EXPECT"
fi

# ============= 装 Spark 3.5 =============
if [ "$NEED_SPARK" = "true" ]; then
  log "Step 2: 安装 Spark 3.5（自带 Gluten）"
  if [ ! -f "$SPARK_PKG_PATH" ]; then
    log "  本地未发现 $SPARK_PKG_PATH，从 COS 下载：$SPARK_PKG_URL"
    mkdir -p "$(dirname "$SPARK_PKG_PATH")"
    wget -q -O "$SPARK_PKG_PATH" "$SPARK_PKG_URL" || { err "Spark 包下载失败：$SPARK_PKG_URL"; rm -f "$SPARK_PKG_PATH"; exit 1; }
    ok "  已下载到 $SPARK_PKG_PATH ($(du -h "$SPARK_PKG_PATH" | awk '{print $1}'))"
  fi
  log "  使用本地包：$SPARK_PKG_PATH"
  [ -d /usr/local/service/spark ] && mv /usr/local/service/spark /usr/local/service/spark.bak.$(date +%Y%m%d_%H%M%S)
  mkdir -p /usr/local/service
  tar -xf "$SPARK_PKG_PATH" -C /usr/local/service/
  # 解压后可能叫 spark-3.5.3-emr / spark-emr3.5.3-gluten / spark 等，统一规整
  cd /usr/local/service
  if [ ! -d spark ]; then
    SPARK_EXTRACTED=$(ls -dt spark-* spark_* 2>/dev/null | head -1)
    if [ -n "$SPARK_EXTRACTED" ] && [ -d "$SPARK_EXTRACTED" ]; then
      mv "$SPARK_EXTRACTED" spark
    fi
  fi
  if [ ! -d /usr/local/service/spark ]; then
    err "解压后未找到 spark 目录，请检查 tar 内层结构"
    ls -la /usr/local/service/
    exit 1
  fi
  chown -R hadoop:hadoop spark
  ok "Spark 3.5 已装到 /usr/local/service/spark"
else
  ok "Spark $SPARK_VER 已装（跳过）"
fi

# ============= 装 Gluten =============
if [ "$NEED_GLUTEN" = "true" ]; then
  log "Step 3: 校验 Gluten Velox bundle jar（已随 Spark 包附带）"
  GLUTEN_JAR=$(ls /usr/local/service/spark/jars/gluten-velox-bundle-*.jar 2>/dev/null | head -1)
  if [ -n "$GLUTEN_JAR" ]; then
    chown hadoop:hadoop "$GLUTEN_JAR"
    ok "Gluten 已随 Spark 包安装：$GLUTEN_JAR"
  else
    err "Spark jars/ 下未发现 gluten-velox-bundle*.jar"
    err "请确认 $SPARK_PKG_PATH 已包含 Gluten jar，或手动放入 /usr/local/service/spark/jars/"
    exit 1
  fi
else
  ok "Gluten $GLUTEN_VER 已装（跳过）"
fi

# ============= 部署 bench-toolkit =============
log "Step 4: 部署 bench-toolkit 到 /home/hadoop/bench"
if [ ! -d "$TOOLKIT_DIR" ]; then
  err "bench-toolkit 源目录不存在：$TOOLKIT_DIR"
  exit 1
fi

su - hadoop -c "mkdir -p /home/hadoop/bench/{gen,queries,queries_cosn,scripts,results}"
cp -f $TOOLKIT_DIR/gen/*.sql /home/hadoop/bench/gen/
cp -f $TOOLKIT_DIR/queries/*.sql /home/hadoop/bench/queries/
cp -f $TOOLKIT_DIR/queries_cosn/*.sql /home/hadoop/bench/queries_cosn/
cp -f $TOOLKIT_DIR/scripts/*.sh /home/hadoop/bench/scripts/
cp -f $TOOLKIT_DIR/ddl/external_tables.sql /home/hadoop/bench/
chmod +x /home/hadoop/bench/scripts/*.sh
chown -R hadoop:hadoop /home/hadoop/bench
ok "bench-toolkit 已部署"

# ============= 自动配置 DRIVER_HOST =============
log "Step 5: 自动配置 DRIVER_HOST 为本机内网 IP"
MASTER_IP=$(hostname -I | awk '{print $1}')
sed -i "s|^DRIVER_HOST=.*|DRIVER_HOST=$MASTER_IP|" /home/hadoop/bench/scripts/*.sh
ok "DRIVER_HOST = $MASTER_IP"

echo
ok "=========================================="
ok "  环境安装完成！"
ok "  下一步：bash run_bench.sh all"
ok "=========================================="
