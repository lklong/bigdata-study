#!/bin/bash
# ====================================================================
# 终极一键入口：本地执行，给个 IP 就出 2x2 矩阵报告
#
# 用法：
#   ./oneshot.sh <master_ip>                  # 全自动（探测+装环境+跑 4 单元）
#   ./oneshot.sh <master_ip> inspect          # 只体检
#   ./oneshot.sh <master_ip> install          # 只装环境
#   ./oneshot.sh <master_ip> bench [hdfs|cosn|all]  # 只跑 bench
#   ./oneshot.sh <master_ip> report           # 只取报告
#
# 例子：
#   ./oneshot.sh 62.234.130.135               # H2 集群一键
#   ./oneshot.sh 101.43.161.139 bench cosn    # H3 只跑 cosn bench
#
# 前提：
#   1. 你能 ssh root@<master_ip>（公钥免密 / 已经在 known_hosts）
#   2. master 上 root 能 su - hadoop（EMR 默认 OK）
#
# 输出：
#   远端 /home/hadoop/bench/results/2x2_matrix_report.md（最终报告）
#   本地 ./reports/<ip>_<timestamp>_2x2_matrix_report.md（自动拷回）
# ====================================================================
set -e

MASTER_IP=${1:?用法: $0 <master_ip> [inspect|install|bench|report|all]}
ACTION=${2:-all}
BENCH_MODE=${3:-all}   # 给 bench 子命令用

TOOLKIT_DIR_ORIG="$(cd "$(dirname "$0")" && pwd)"
# 中文路径在 zsh/bash 下 scp 转义会出错，先 tar pipe 到纯英文临时目录
TOOLKIT_DIR="/tmp/bench-toolkit-local-$$"
rm -rf "$TOOLKIT_DIR"
mkdir -p "$TOOLKIT_DIR"
(cd "$TOOLKIT_DIR_ORIG" && tar cf - .) | (cd "$TOOLKIT_DIR" && tar xf -)

trap "rm -rf $TOOLKIT_DIR" EXIT

TS=$(date +%Y%m%d_%H%M%S)
# 报告也存中文路径外的地方
LOCAL_REPORT_DIR="$TOOLKIT_DIR_ORIG/../reports"
mkdir -p "$LOCAL_REPORT_DIR" 2>/dev/null || true
# 但 scp 不能写入中文路径，先放 /tmp
TMP_REPORT_DIR="/tmp/bench-reports-$$"
mkdir -p "$TMP_REPORT_DIR"
trap "rm -rf $TOOLKIT_DIR; cp -r $TMP_REPORT_DIR/* '$LOCAL_REPORT_DIR/' 2>/dev/null; rm -rf $TMP_REPORT_DIR" EXIT

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[oneshot $(date +'%H:%M:%S')] $*${NC}"; }
ok()   { echo -e "${GREEN}[oneshot $(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[oneshot $(date +'%H:%M:%S')] ⚠ $*${NC}"; }
err()  { echo -e "${RED}[oneshot $(date +'%H:%M:%S')] ✗ $*${NC}"; }

SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 root@$MASTER_IP"
SCP_OPTS="-o StrictHostKeyChecking=no"
# 中文路径会被 zsh/bash 转义成 \xxx，scp 解析不了。改用 cd 切换工作目录 + 相对路径
scp_to()   { (cd "$TOOLKIT_DIR" && scp $SCP_OPTS "$1" "root@$MASTER_IP:$2"); }
scp_from() { (cd "$TMP_REPORT_DIR" && scp $SCP_OPTS "root@$MASTER_IP:$1" "$2"); }

# ====== 测试 SSH 连通性 ======
test_ssh() {
  log "测试 SSH 连接 root@$MASTER_IP ..."
  if $SSH "echo connected; hostname" 2>&1 | grep -q connected; then
    ok "SSH 连接 OK"
  else
    err "无法 SSH 到 $MASTER_IP"
    err "请确保你的公钥 ~/.ssh/id_*.pub 已添加到目标 master 的 /root/.ssh/authorized_keys"
    exit 1
  fi
}

# ====== Stage 1: 体检 ======
do_inspect() {
  log "Stage 1: 集群体检 ($MASTER_IP)"
  scp_to "scripts/cluster_inspect.sh" /tmp/ >/dev/null
  $SSH "chmod +x /tmp/cluster_inspect.sh && bash /tmp/cluster_inspect.sh /tmp/env.json"
  scp_from /tmp/env.json "${MASTER_IP}_${TS}_env.json" >/dev/null
  ok "环境信息已保存到本地：$LOCAL_REPORT_DIR/${MASTER_IP}_${TS}_env.json（trap 自动 cp）"
}

# ====== Stage 2: 装环境 ======
do_install() {
  log "Stage 2: 安装环境（按 env.json 决策）"
  
  # 把整个 toolkit 打包送过去
  log "  → 打包 bench-toolkit 上传到 master"
  TARNAME="bench-toolkit-${TS}.tar.gz"
  # 用临时英文目录的 toolkit 打包
  (cd "$(dirname "$TOOLKIT_DIR")" && tar czf "/tmp/$TARNAME" "$(basename "$TOOLKIT_DIR")")
  scp $SCP_OPTS "/tmp/$TARNAME" "root@$MASTER_IP:/tmp/" >/dev/null
  $SSH "cd /tmp && rm -rf bench-toolkit && tar xzf $TARNAME && mv $(basename "$TOOLKIT_DIR") bench-toolkit"
  rm -f "/tmp/$TARNAME"
  
  log "  → 跑 install_env.sh"
  $SSH "chmod +x /tmp/bench-toolkit/scripts/install_env.sh && bash /tmp/bench-toolkit/scripts/install_env.sh /tmp/env.json /tmp/bench-toolkit"
  ok "Stage 2 完成"
}

# ====== Stage 3: 跑 Bench ======
do_bench() {
  log "Stage 3: 跑 Bench（mode=$BENCH_MODE）"
  $SSH "chmod +x /home/hadoop/bench/scripts/run_bench.sh && bash /home/hadoop/bench/scripts/run_bench.sh $BENCH_MODE"
  ok "Stage 3 完成"
}

# ====== Stage 4: 取报告 ======
do_report() {
  log "Stage 4: 拷回报告"
  local REMOTE_REPORT=/home/hadoop/bench/results/2x2_matrix_report.md
  local REPORT_NAME="${MASTER_IP}_${TS}_2x2_matrix_report.md"
  local LOCAL_REPORT="$TMP_REPORT_DIR/$REPORT_NAME"
  
  if $SSH "[ -f $REMOTE_REPORT ]"; then
    scp_from "$REMOTE_REPORT" "$REPORT_NAME"
    ok "报告已拷到（临时）：$LOCAL_REPORT"
    ok "脚本退出时 trap 会自动 cp 到：$LOCAL_REPORT_DIR/"
    echo
    echo -e "${YELLOW}========== 报告预览 ==========${NC}"
    cat "$LOCAL_REPORT"
  else
    warn "远端报告不存在，可能还没跑 Bench"
  fi
  
  # 顺便把所有 csv 也拉回来
  (cd "$TMP_REPORT_DIR" && scp $SCP_OPTS "root@$MASTER_IP:/home/hadoop/bench/results/duration_*.csv" . 2>/dev/null) && \
    ok "CSV 也拷回了：$LOCAL_REPORT_DIR/duration_*.csv（trap 会自动 cp 到中文目录）"
}

# ====== 主流程 ======
test_ssh

case "$ACTION" in
  inspect)
    do_inspect
    ;;
  install)
    do_inspect
    do_install
    ;;
  bench)
    do_bench
    do_report
    ;;
  report)
    do_report
    ;;
  all)
    do_inspect
    do_install
    do_bench
    do_report
    ;;
  *)
    err "未知 action: $ACTION"
    echo "用法: $0 <master_ip> [inspect|install|bench|report|all]"
    exit 1
    ;;
esac

echo
ok "============================================"
ok "  oneshot 完成！集群: $MASTER_IP"
ok "  本地产物目录: $LOCAL_REPORT_DIR"
ok "============================================"
