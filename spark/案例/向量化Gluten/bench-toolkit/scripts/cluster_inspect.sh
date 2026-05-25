#!/bin/bash
# ====================================================================
# 集群体检：自动探测环境，输出 env.json 供后续脚本决策
#
# 用法：bash cluster_inspect.sh [output_path]
# 输出：/tmp/env.json （或指定路径）
# ====================================================================
set -e

OUT=${1:-/tmp/env.json}

# ------ 颜色 ------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

# ------ 收集信息 ------
MASTER_IP=$(hostname -I | awk '{print $1}')
HOSTNAME_=$(hostname)

# JDK11
JDK11_PATH=""
if [ -x /usr/local/jdk/bin/java ] && /usr/local/jdk/bin/java -version 2>&1 | grep -q '11\.'; then
  JDK11_PATH="/usr/local/jdk"
elif [ -x /usr/lib/jvm/java-11/bin/java ]; then
  JDK11_PATH="/usr/lib/jvm/java-11"
fi

# 系统 JDK
SYS_JAVA=$(readlink -f $(which java) 2>/dev/null || echo "")
SYS_JAVA_VER=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([^"]+)".*/\1/' || echo "unknown")

# Hadoop / Hive
HADOOP_VER=$(su - hadoop -c 'hadoop version' 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
HIVE_VER=$(su - hadoop -c 'hive --version' 2>/dev/null | grep -E '^Hive ' | head -1 | awk '{print $2}' || echo "unknown")

# Spark
SPARK_HOME="/usr/local/service/spark"
SPARK_VER="none"
if [ -x $SPARK_HOME/bin/spark-submit ]; then
  SPARK_VER=$($SPARK_HOME/bin/spark-submit --version 2>&1 | grep -oE 'version [0-9.]+' | head -1 | awk '{print $2}')
fi

# Gluten
GLUTEN_JAR=$(ls $SPARK_HOME/jars/gluten-velox-bundle-*.jar 2>/dev/null | head -1)
GLUTEN_VER="none"
[ -n "$GLUTEN_JAR" ] && GLUTEN_VER=$(basename "$GLUTEN_JAR" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?' | head -1)

# YARN workers（自动从 yarn node -list 拿）
WORKERS=$(su - hadoop -c 'yarn node -list 2>/dev/null' | grep RUNNING | awk -F: '{print $1}' | sort -u | tr '\n' ',' | sed 's/,$//')
WORKER_COUNT=$(echo "$WORKERS" | tr ',' '\n' | grep -c .)

# YARN 资源
YARN_TOTAL=$(su - hadoop -c 'yarn node -list -showDetails 2>/dev/null' | grep -E 'Configured Resources' | head -1 | grep -oE 'memory:[0-9]+, vCores:[0-9]+' | head -1)

# cosn 是否可用
COSN_OK="false"
if su - hadoop -c 'hadoop fs -ls cosn:// 2>&1' | grep -qE 'No FileSystem|UnsupportedFileSystem' 2>/dev/null; then
  COSN_OK="false"
elif su - hadoop -c 'hadoop fs -ls cosn:// 2>&1 | head -2' &>/dev/null; then
  COSN_OK="true"
fi

# bench 工作目录是否已部署
BENCH_DEPLOYED="false"
[ -x /home/hadoop/bench/scripts/bench_all.sh ] && BENCH_DEPLOYED="true"

# 判断是否需要装 JDK11
NEED_INSTALL_JDK11="false"
[ -z "$JDK11_PATH" ] && NEED_INSTALL_JDK11="true"

# 判断是否需要装 Spark
NEED_INSTALL_SPARK="false"
if [ "$SPARK_VER" = "none" ] || [[ ! "$SPARK_VER" =~ ^3\.5 ]]; then
  NEED_INSTALL_SPARK="true"
fi

# 判断是否需要装 Gluten
NEED_INSTALL_GLUTEN="false"
[ "$GLUTEN_VER" = "none" ] && NEED_INSTALL_GLUTEN="true"

# Worker 互通测试（hadoop 用户）
WORKER_SSH_OK="unknown"
if [ -n "$WORKERS" ]; then
  FIRST_WORKER=$(echo "$WORKERS" | cut -d, -f1)
  if su - hadoop -c "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes hadoop@$FIRST_WORKER 'hostname' 2>/dev/null" &>/dev/null; then
    WORKER_SSH_OK="true"
  else
    # root 试试
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes root@$FIRST_WORKER 'hostname' 2>/dev/null &>/dev/null; then
      WORKER_SSH_OK="root_only"
    else
      WORKER_SSH_OK="false"
    fi
  fi
fi

# ------ 输出 JSON ------
cat > $OUT <<EOF
{
  "hostname": "$HOSTNAME_",
  "master_ip": "$MASTER_IP",
  "system_java": {
    "path": "$SYS_JAVA",
    "version": "$SYS_JAVA_VER"
  },
  "jdk11": {
    "path": "$JDK11_PATH",
    "installed": $([ -n "$JDK11_PATH" ] && echo true || echo false),
    "need_install": $NEED_INSTALL_JDK11
  },
  "hadoop": {
    "version": "$HADOOP_VER"
  },
  "hive": {
    "version": "$HIVE_VER"
  },
  "spark": {
    "home": "$SPARK_HOME",
    "version": "$SPARK_VER",
    "need_install": $NEED_INSTALL_SPARK
  },
  "gluten": {
    "jar": "$GLUTEN_JAR",
    "version": "$GLUTEN_VER",
    "need_install": $NEED_INSTALL_GLUTEN
  },
  "yarn": {
    "workers": "$WORKERS",
    "worker_count": $WORKER_COUNT,
    "total_resource": "$YARN_TOTAL",
    "worker_ssh": "$WORKER_SSH_OK"
  },
  "cosn": {
    "available": $COSN_OK
  },
  "bench": {
    "deployed": $BENCH_DEPLOYED
  }
}
EOF

# ------ 打印漂亮报告 ------
echo
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              集群体检报告 ($(date +'%Y-%m-%d %H:%M:%S'))                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
printf "  %-22s : %s\n" "Hostname" "$HOSTNAME_"
printf "  %-22s : %s\n" "Master 内网 IP" "$MASTER_IP"
printf "  %-22s : %s ($SYS_JAVA_VER)\n" "系统 JDK" "$SYS_JAVA"
printf "  %-22s : " "JDK 11"
[ -n "$JDK11_PATH" ] && echo -e "${GREEN}✓ $JDK11_PATH${NC}" || echo -e "${RED}✗ 未装${NC}"
printf "  %-22s : %s\n" "Hadoop" "$HADOOP_VER"
printf "  %-22s : %s\n" "Hive" "$HIVE_VER"
printf "  %-22s : " "Spark 3.5"
if [[ "$SPARK_VER" =~ ^3\.5 ]]; then echo -e "${GREEN}✓ $SPARK_VER${NC}"; else echo -e "${RED}✗ ${SPARK_VER}${NC}"; fi
printf "  %-22s : " "Gluten"
[ "$GLUTEN_VER" != "none" ] && echo -e "${GREEN}✓ $GLUTEN_VER${NC}" || echo -e "${RED}✗ 未装${NC}"
printf "  %-22s : %d 个 [%s]\n" "YARN Workers" "$WORKER_COUNT" "$WORKERS"
printf "  %-22s : %s\n" "YARN 单节点资源" "$YARN_TOTAL"
printf "  %-22s : " "Worker SSH (hadoop)"
case "$WORKER_SSH_OK" in
  true) echo -e "${GREEN}✓ 互通${NC}" ;;
  root_only) echo -e "${YELLOW}⚠ 只有 root 互通${NC}" ;;
  false) echo -e "${RED}✗ 不互通（需手动装 worker JDK）${NC}" ;;
  *) echo -e "${YELLOW}? 未知${NC}" ;;
esac
printf "  %-22s : " "cosn 可用"
[ "$COSN_OK" = "true" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
printf "  %-22s : " "Bench 工作目录"
[ "$BENCH_DEPLOYED" = "true" ] && echo -e "${GREEN}✓ /home/hadoop/bench${NC}" || echo -e "${YELLOW}⚠ 未部署${NC}"
echo

# ------ 给出建议 ------
echo -e "${YELLOW}── 决策建议 ──${NC}"
[ "$NEED_INSTALL_JDK11" = "true" ] && echo "  • 需装 JDK 11（master + 所有 worker）"
[ "$NEED_INSTALL_SPARK" = "true" ] && echo "  • 需装 Spark 3.5"
[ "$NEED_INSTALL_GLUTEN" = "true" ] && echo "  • 需装 Gluten Velox bundle jar"
[ "$BENCH_DEPLOYED" = "false" ] && echo "  • 需部署 bench-toolkit"
[ "$COSN_OK" = "false" ] && echo "  • cosn 不可用，只能跑 HDFS bench"
[ "$WORKER_SSH_OK" = "false" ] && echo "  • Worker SSH 不互通，无法批量装 JDK，需手动或 YARN 分发"

echo
echo -e "${GREEN}✓ env.json 已写入：${OUT}${NC}"
