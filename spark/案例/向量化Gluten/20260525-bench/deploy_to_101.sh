#!/bin/bash
# ====================================================================
# deploy_to_101.sh — 把测试资产部署到 101.43.161.139:/root/bench-101/
# 红线：仅写用户态目录 /root/bench-101/，绝不向 /opt /etc /usr 写文件
#       严禁修改集群默认 JDK8 / *-site.xml / /etc/profile
# ====================================================================
set -eu

# ---- 可调参数 ----
HOST_IP="${HOST_IP:-101.43.161.139}"
SSH_USER="${SSH_USER:-root}"
PEM_PATH="${PEM_PATH:-/c/Users/lkl/Desktop/lkl_meson.pem}"
SSH_OPTS="-i ${PEM_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
REMOTE_DIR="${REMOTE_DIR:-/root/bench-101}"

# ---- 本地资产路径 ----
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GLUTEN_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)               # spark/案例/向量化Gluten
TOOLKIT_DIR="${GLUTEN_DIR}/bench-toolkit"
QUERIES_COSN="${TOOLKIT_DIR}/queries_cosn"
QUERIES_COSN_VELOX="${TOOLKIT_DIR}/queries_cosn_velox"  # Velox 兼容版（DECIMAL 列 CAST AS DOUBLE）

# 待上传文件清单
DDL_LOCAL="${SCRIPT_DIR}/external_tables_meson.sql"      # 任务 3 产物
BENCH_SCRIPT="${SCRIPT_DIR}/bench_yarn_cosn.sh"          # 任务 5/6/7 产物
PREPARE_SCRIPT="${SCRIPT_DIR}/prepare_cosn_tables.sh"    # 任务 4 产物
ENV_INIT_SCRIPT="${SCRIPT_DIR}/env_init.sh"              # 进程内 PATH 注入

echo "[deploy] target=${SSH_USER}@${HOST_IP}:${REMOTE_DIR}"

# ---- 上传前校验本地资产存在 ----
for f in "${QUERIES_COSN}" "${DDL_LOCAL}" "${BENCH_SCRIPT}" "${PREPARE_SCRIPT}" "${ENV_INIT_SCRIPT}"; do
  if [ ! -e "${f}" ]; then
    echo "[deploy][ERROR] missing local asset: ${f}" >&2
    echo "[deploy][hint ] 请先完成对应的任务（任务 3/4/5/6/7）后再执行 deploy" >&2
    exit 2
  fi
done

# ---- 远端：备份旧目录 + 创建新目录 ----
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" "bash -s" <<EOF
set -e
TS=\$(date +%Y%m%d_%H%M%S)
if [ -d "${REMOTE_DIR}" ]; then
  echo "[remote] backup old dir to ${REMOTE_DIR}.bak.\${TS}"
  mv "${REMOTE_DIR}" "${REMOTE_DIR}.bak.\${TS}"
fi
mkdir -p "${REMOTE_DIR}/queries_cosn"
mkdir -p "${REMOTE_DIR}/queries_cosn_velox"
mkdir -p "${REMOTE_DIR}/results"
echo "[remote] mkdir done: ${REMOTE_DIR}"
EOF

# ---- 上传 7 条 SQL ----
echo "[deploy] scp queries_cosn/*.sql ..."
scp ${SSH_OPTS} "${QUERIES_COSN}"/q*.sql \
    "${SSH_USER}@${HOST_IP}:${REMOTE_DIR}/queries_cosn/"

# ---- 上传 Velox 兼容版 SQL（仅在本地存在时上传） ----
if [ -d "${QUERIES_COSN_VELOX}" ]; then
  echo "[deploy] scp queries_cosn_velox/*.sql ..."
  scp ${SSH_OPTS} "${QUERIES_COSN_VELOX}"/q*.sql \
      "${SSH_USER}@${HOST_IP}:${REMOTE_DIR}/queries_cosn_velox/"
else
  echo "[deploy] no queries_cosn_velox/ locally, skip"
fi

# ---- 上传 DDL / 各 .sh ----
echo "[deploy] scp DDL & scripts ..."
scp ${SSH_OPTS} \
    "${DDL_LOCAL}" \
    "${BENCH_SCRIPT}" \
    "${PREPARE_SCRIPT}" \
    "${ENV_INIT_SCRIPT}" \
    "${SSH_USER}@${HOST_IP}:${REMOTE_DIR}/"

# ---- 远端校验 + 赋权 ----
ssh ${SSH_OPTS} "${SSH_USER}@${HOST_IP}" "bash -s" <<EOF
set -e
cd "${REMOTE_DIR}"

echo "[remote] verify 7 sql files ..."
MISS=0
for q in q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables; do
  f="queries_cosn/\${q}.sql"
  if [ ! -s "\${f}" ]; then
    echo "[remote][ERROR] missing or empty: \${f}" >&2
    MISS=\$((MISS+1))
  fi
done
[ "\${MISS}" -eq 0 ] || { echo "[remote][FATAL] \${MISS} sql files missing" >&2; exit 3; }

echo "[remote] chmod +x *.sh ..."
chmod +x ./*.sh

echo "[remote] verify external_tables_meson.sql ..."
[ -s external_tables_meson.sql ] || { echo "[remote][FATAL] DDL missing" >&2; exit 4; }

# ---- 同步到 hadoop 用户家目录（执行身份为 hadoop，避免 root 没 HDFS 写权限） ----
HADOOP_DIR="/home/hadoop/bench-101"
echo "[remote] sync to \${HADOOP_DIR} (run as user hadoop)"
rm -rf "\${HADOOP_DIR}"
mkdir -p "\${HADOOP_DIR}"
cp -r "${REMOTE_DIR}/." "\${HADOOP_DIR}/"
chown -R hadoop:hadoop "\${HADOOP_DIR}"
chmod +x "\${HADOOP_DIR}"/*.sh

echo "[remote] tree ${REMOTE_DIR}:"
ls -la "${REMOTE_DIR}"
echo "[remote] tree \${HADOOP_DIR}:"
ls -la "\${HADOOP_DIR}"

echo "[remote] DONE"
EOF

echo "[deploy] OK"
