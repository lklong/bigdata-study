#!/bin/bash
# ====================================================================
# env_init.sh — 进程内基础环境初始化（仅当前 shell 生效）
# 红线：不修改 /etc/profile / ~/.bashrc / update-alternatives
# 适用：远端 root 非交互 ssh 没有自动加载 PATH 时，临时注入
# 检测顺序：优先 /opt/spark-poc 软链 → /usr/local/service/* 真实路径
# ====================================================================

# Hadoop
if [ -z "${HADOOP_HOME:-}" ]; then
  for cand in /usr/local/service/hadoop /opt/hadoop /opt/cloudera/parcels/CDH/lib/hadoop ; do
    [ -x "${cand}/bin/hadoop" ] && export HADOOP_HOME="${cand}" && break
  done
fi
[ -n "${HADOOP_HOME:-}" ] && export PATH="${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"
[ -z "${HADOOP_CONF_DIR:-}" ] && [ -d "${HADOOP_HOME:-/x}/etc/hadoop" ] && export HADOOP_CONF_DIR="${HADOOP_HOME}/etc/hadoop"

# Spark — 强制锁定到 3.5.8（与 Gluten 1.6.0 jar 配套版本）
# 红线：不动 hadoop 用户 ~/.bash_profile，但本进程内必须覆盖 SPARK_HOME
# 探测顺序（先匹配先用）：env 注入的 SPARK_HOME_OVERRIDE → /opt/spark-poc → 真实 3.5.8 目录
SPARK_PREFERRED=""
for cand in \
    "${SPARK_HOME_OVERRIDE:-}" \
    "/opt/spark-poc" \
    "/usr/local/service/spark-3.5.8-bin-hadoop3" \
    "/opt/spark" ; do
  [ -n "${cand}" ] && [ -x "${cand}/bin/spark-submit" ] && SPARK_PREFERRED="${cand}" && break
done
# 兜底：如果上面都没找到，才用 hadoop 用户原本的 SPARK_HOME（一般是 3.0.2，不期望走到这里）
if [ -z "${SPARK_PREFERRED}" ] && [ -n "${SPARK_HOME:-}" ] && [ -x "${SPARK_HOME}/bin/spark-submit" ]; then
  SPARK_PREFERRED="${SPARK_HOME}"
fi
# 强制覆盖 hadoop 用户从 profile 继承的 SPARK_HOME
if [ -n "${SPARK_PREFERRED}" ]; then
  export SPARK_HOME="${SPARK_PREFERRED}"
  # 把当前 SPARK_HOME 的 bin 放到 PATH 最前，覆盖 hadoop profile 里写死的 /usr/local/service/spark/bin
  export PATH="${SPARK_HOME}/bin:${SPARK_HOME}/sbin:${PATH}"
fi
unset SPARK_PREFERRED
# spark-env.sh 里 export 的 HADOOP_CONF_DIR 等；source 时临时关 nounset，避免上游 set -u 踩雷
if [ -f "${SPARK_HOME:-/x}/conf/spark-env.sh" ]; then
  __saved_set_u="$(set +o | grep nounset)"
  set +u
  . "${SPARK_HOME}/conf/spark-env.sh" || true
  eval "${__saved_set_u}"
  unset __saved_set_u
fi
# spark-env.sh 可能再次 export SPARK_HOME（hadoop 默认 3.0.2 的 conf 就这么写），二次锁回 3.5.8
if [ -x "/opt/spark-poc/bin/spark-submit" ]; then
  export SPARK_HOME="/opt/spark-poc"
  export PATH="/opt/spark-poc/bin:/opt/spark-poc/sbin:${PATH}"
fi

# Hive
if [ -z "${HIVE_HOME:-}" ]; then
  for cand in /usr/local/service/hive /opt/hive ; do
    [ -x "${cand}/bin/hive" ] && export HIVE_HOME="${cand}" && break
  done
fi
[ -n "${HIVE_HOME:-}" ] && export PATH="${HIVE_HOME}/bin:${PATH}"

# JAVA_HOME（仅本进程；不改 /etc/profile）
if [ -z "${JAVA_HOME:-}" ]; then
  if [ -x /usr/lib/jvm/TencentKona-8.0.9-322/bin/java ]; then
    export JAVA_HOME=/usr/lib/jvm/TencentKona-8.0.9-322
  elif [ -L /usr/bin/java ]; then
    j=$(readlink -f /usr/bin/java)
    export JAVA_HOME="${j%/jre/bin/java}"
    export JAVA_HOME="${JAVA_HOME%/bin/java}"
  fi
fi
[ -n "${JAVA_HOME:-}" ] && export PATH="${JAVA_HOME}/bin:${PATH}"

# JDK17 路径（仅供 bench 脚本运行期 --conf 切换用，不改默认 JDK）
if [ -z "${JDK17_HOME:-}" ]; then
  for cand in /usr/lib/jvm/TencentKona-17.0.18.b1 /usr/lib/jvm/java-17-konajdk /usr/lib/jvm/jdk-17 ; do
    [ -x "${cand}/bin/java" ] && export JDK17_HOME="${cand}" && break
  done
fi

# 静默打印环境（出错时排查用）
if [ "${ENV_INIT_VERBOSE:-0}" = "1" ]; then
  echo "[env_init] HADOOP_HOME=${HADOOP_HOME:-<unset>}"
  echo "[env_init] HADOOP_CONF_DIR=${HADOOP_CONF_DIR:-<unset>}"
  echo "[env_init] SPARK_HOME=${SPARK_HOME:-<unset>}"
  echo "[env_init] HIVE_HOME=${HIVE_HOME:-<unset>}"
  echo "[env_init] JAVA_HOME=${JAVA_HOME:-<unset>}"
  echo "[env_init] JDK17_HOME=${JDK17_HOME:-<unset>}"
fi
