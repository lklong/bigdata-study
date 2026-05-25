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
JDK11_URL=${JDK11_URL:-https://github.com/Tencent/TencentKona-11/releases/download/kona11.0.27/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz}
GLUTEN_URL=${GLUTEN_URL:-https://repository.apache.org/content/repositories/snapshots/org/apache/gluten/gluten-velox-bundle/1.5.0-SNAPSHOT/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar}
SPARK_PKG_PATH=${SPARK_PKG_PATH:-/home/hadoop/spark.tar.gz}  # 已存在的本地 EMR Spark 包

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
    wget -q --show-progress -O kona11.tar.gz "$JDK11_URL" || { err "JDK11 下载失败"; exit 1; }
  fi
  tar -xf kona11.tar.gz -C /usr/local/
  KONA_DIR=$(ls -d /usr/local/TencentKona-11* | head -1)
  ln -snf $KONA_DIR /usr/local/jdk
  ok "JDK 11 已装到 /usr/local/jdk"
else
  ok "JDK 11 已装（跳过）"
fi

# ============= 装 JDK 11 到 worker（如果 SSH 互通）=============
if [ "$WORKER_SSH" = "true" ] || [ "$WORKER_SSH" = "root_only" ]; then
  log "Step 1b: 批量装 JDK 11 到 worker（$WORKERS）"
  USER_=hadoop
  [ "$WORKER_SSH" = "root_only" ] && USER_=root
  
  for w in $(echo "$WORKERS" | tr ',' ' '); do
    log "  → $w"
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $USER_@$w "[ -x /usr/local/jdk/bin/java ]" 2>/dev/null; then
      ok "    $w JDK11 已装，跳过"
      continue
    fi
    scp -o StrictHostKeyChecking=no /tmp/kona11.tar.gz $USER_@$w:/tmp/ 2>&1 | tail -1
    if [ "$USER_" = "root" ]; then
      ssh -o StrictHostKeyChecking=no root@$w "tar -xf /tmp/kona11.tar.gz -C /usr/local/ && ln -snf /usr/local/TencentKona-11* /usr/local/jdk && /usr/local/jdk/bin/java -version 2>&1 | head -1"
    else
      ssh -o StrictHostKeyChecking=no hadoop@$w "tar -xf /tmp/kona11.tar.gz -C ~/ && ln -snf ~/TencentKona-11* ~/jdk11"
      warn "    $w 装到了 ~hadoop/jdk11（无 root 权限装到 /usr/local），spark 提交时 spark.executorEnv.JAVA_HOME 要指这个"
    fi
  done
  ok "Worker JDK 11 批量安装完成"
elif [ "$WORKER_SSH" = "false" ]; then
  warn "Step 1b: Worker SSH 不互通，跳过批量装 JDK 11"
  warn "  如果 worker 上还没有 JDK 11，spark executor 会启动失败"
  warn "  请大哥手动装：每个 worker 上跑安装命令"
  echo
  echo "  手动装命令（在每个 worker 上以 root 执行）："
  for w in $(echo "$WORKERS" | tr ',' ' '); do
    echo "    ssh root@$w 'wget -O /tmp/k.tar.gz $JDK11_URL && tar -xf /tmp/k.tar.gz -C /usr/local/ && ln -snf /usr/local/TencentKona-11* /usr/local/jdk'"
  done
  echo
fi

# ============= 装 Spark 3.5 =============
if [ "$NEED_SPARK" = "true" ]; then
  log "Step 2: 安装 Spark 3.5"
  if [ -f "$SPARK_PKG_PATH" ]; then
    log "  使用本地包：$SPARK_PKG_PATH"
    [ -d /usr/local/service/spark ] && mv /usr/local/service/spark /usr/local/service/spark.bak.$(date +%Y%m%d_%H%M%S)
    mkdir -p /usr/local/service
    tar -xf $SPARK_PKG_PATH -C /usr/local/service/
    # 解压后可能叫 spark-3.5.3-emr 或 spark
    cd /usr/local/service
    if [ -d spark-3.5.3-emr ]; then mv spark-3.5.3-emr spark; fi
    chown -R hadoop:hadoop spark
    ok "Spark 3.5 已装到 /usr/local/service/spark"
  else
    err "未找到 Spark 包：$SPARK_PKG_PATH"
    err "请把 EMR 的 spark.tar.gz 放到 /home/hadoop/，或设置 SPARK_PKG_PATH 环境变量"
    exit 1
  fi
else
  ok "Spark $SPARK_VER 已装（跳过）"
fi

# ============= 装 Gluten =============
if [ "$NEED_GLUTEN" = "true" ]; then
  log "Step 3: 安装 Gluten Velox bundle jar"
  cd /tmp
  if [ ! -f gluten.jar ]; then
    wget -q --show-progress -O gluten.jar "$GLUTEN_URL" || { err "Gluten 下载失败"; exit 1; }
  fi
  cp gluten.jar /usr/local/service/spark/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar
  chown hadoop:hadoop /usr/local/service/spark/jars/gluten-velox-bundle-*.jar
  ok "Gluten 1.5.0-SNAPSHOT 已装"
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
