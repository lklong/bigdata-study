#!/bin/bash
# ====================================================================
# inspect_101.sh — 集群 101.43.161.139 环境只读盘点
# 红线：仅执行只读命令，禁止任何写操作；不修改任何基础环境
# 输出：spark/案例/向量化Gluten/reports/101.43.161.139_<TS>_inspect.md
# ====================================================================
set -u

# ---- 可调参数 ----
HOST_IP="${HOST_IP:-101.43.161.139}"
SSH_USER="${SSH_USER:-root}"
PEM_PATH="${PEM_PATH:-/c/Users/lkl/Desktop/lkl_meson.pem}"
SSH_OPTS="-i ${PEM_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ---- 输出位置 ----
TS=$(date +%Y%m%d_%H%M%S)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPORT_DIR="${SCRIPT_DIR}/../reports"
mkdir -p "${REPORT_DIR}"
OUT="${REPORT_DIR}/${HOST_IP}_${TS}_inspect.md"

echo "[inspect] target=${SSH_USER}@${HOST_IP}"
echo "[inspect] pem=${PEM_PATH}"
echo "[inspect] out=${OUT}"

# ---- 远端要执行的只读命令（heredoc 单引号防本地展开） ----
REMOTE_SCRIPT='
set +e

# 进程内 PATH 注入（不动 /etc/profile）
for cand in /usr/local/service/hadoop /opt/hadoop ; do
  [ -x "$cand/bin/hadoop" ] && export HADOOP_HOME="$cand" && break
done
[ -n "${HADOOP_HOME:-}" ] && export PATH="$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH"
[ -d "${HADOOP_HOME:-/x}/etc/hadoop" ] && export HADOOP_CONF_DIR="$HADOOP_HOME/etc/hadoop"

for cand in /opt/spark-poc /usr/local/service/spark-3.5.8-bin-hadoop3 /usr/local/service/spark ; do
  [ -x "$cand/bin/spark-submit" ] && export SPARK_HOME="$cand" && break
done
[ -n "${SPARK_HOME:-}" ] && export PATH="$SPARK_HOME/bin:$SPARK_HOME/sbin:$PATH"

for cand in /usr/local/service/hive /opt/hive ; do
  [ -x "$cand/bin/hive" ] && export HIVE_HOME="$cand" && break
done
[ -n "${HIVE_HOME:-}" ] && export PATH="$HIVE_HOME/bin:$PATH"

sep() { echo; echo "## $1"; echo; echo "\`\`\`"; }
end() { echo "\`\`\`"; }

sep "hostname / uname"
hostname
uname -a
end

sep "默认 JDK（基础环境，禁止修改）"
java -version 2>&1
echo "----"
echo "which java: $(which java 2>/dev/null)"
echo "readlink /usr/bin/java: $(readlink -f /usr/bin/java 2>/dev/null)"
echo "echo \$JAVA_HOME : ${JAVA_HOME:-<unset>}"
end

sep "机器上其他 JDK 路径（任务运行期可通过 --conf 切换，不动默认）"
ls -la /usr/lib/jvm 2>/dev/null
echo "----"
ls -d /usr/lib/jvm/*jdk* /usr/lib/jvm/*Kona* /usr/lib/jvm/jdk-* 2>/dev/null
end

sep "Spark 版本与路径"
which spark-submit 2>/dev/null
spark-submit --version 2>&1 | head -30
echo "----"
echo "SPARK_HOME=${SPARK_HOME:-<unset>}"
ls -la "${SPARK_HOME:-/opt/spark}" 2>/dev/null | head -10
end

sep "Hadoop 版本与配置目录"
which hadoop 2>/dev/null
hadoop version 2>&1 | head -10
echo "----"
echo "HADOOP_HOME=${HADOOP_HOME:-<unset>}"
echo "HADOOP_CONF_DIR=${HADOOP_CONF_DIR:-<unset>}"
ls -la "${HADOOP_CONF_DIR:-/etc/hadoop/conf}" 2>/dev/null | head -20
end

sep "Hive 版本"
which hive 2>/dev/null
hive --version 2>&1 | head -10
end

sep "YARN 队列"
yarn queue -status default 2>&1 | head -30
echo "----"
yarn queue -list 2>&1 | head -30
end

sep "cosn 插件 jar 探测"
find /opt /usr/local /home /root -maxdepth 6 -type f \
  \( -name "hadoop-cos*.jar" -o -name "cos_api*.jar" -o -name "cos-bundle*.jar" \) 2>/dev/null
end

sep "Gluten / Velox jar 探测"
find /opt /usr/local /home /root -maxdepth 6 -type f \
  \( -name "gluten*.jar" -o -name "velox*.jar" \) 2>/dev/null
end

sep "/opt/spark-poc 现存内容（如果存在则可复用）"
ls -la /opt/spark-poc 2>/dev/null | head -30
[ -f /opt/spark-poc/conf/spark-env.sh ] && echo "---- spark-env.sh ----" && cat /opt/spark-poc/conf/spark-env.sh 2>/dev/null | head -40
end

sep "core-site.xml 中 fs.cosn 配置（只读 grep）"
for f in /etc/hadoop/conf/core-site.xml ${HADOOP_CONF_DIR}/core-site.xml ${HADOOP_HOME}/etc/hadoop/core-site.xml; do
  [ -f "$f" ] && echo "==> $f" && grep -A1 -E "fs\\.cosn|fs\\.AbstractFileSystem\\.cosn" "$f" 2>/dev/null
done
end

sep "cosn 路径连通性（只读 ls）"
hadoop fs -ls cosn://lkl-bj-update-1308597516/meson/ 2>&1 | head -20
echo "----"
hadoop fs -ls cosn://lkl-bj-update-1308597516/meson/data/ 2>&1 | head -20
end
'

# ---- 写报告头 ----
{
  echo "# 集群环境盘点报告 — ${HOST_IP}"
  echo
  echo "- 采集时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "- 入口：${SSH_USER}@${HOST_IP}"
  echo "- 红线：**仅只读命令；未修改任何基础环境（默认 JDK8 / *-site.xml 一律不动）**"
  echo
} > "${OUT}"

# ---- 远程执行 ----
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" "bash -s" <<EOF >> "${OUT}" 2>&1
${REMOTE_SCRIPT}
EOF

RC=$?
{
  echo
  echo "## 退出码"
  echo
  echo "ssh_exit_code=${RC}"
} >> "${OUT}"

echo "[inspect] done, exit=${RC}, report=${OUT}"
exit ${RC}
