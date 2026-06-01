#!/bin/bash
# ====================================================================
# 终极一键入口：本地执行，给个 IP 就出 2x2 矩阵报告
#
# 用法：
#   ./oneshot.sh <master_ip> [action] [bench_mode] [ssh_key]
#
#   ./oneshot.sh <master_ip>                                  # 全自动（探测+装环境+跑 4 单元）
#   ./oneshot.sh <master_ip> inspect                          # 只体检
#   ./oneshot.sh <master_ip> install                          # 只装环境
#   ./oneshot.sh <master_ip> bench [hdfs|cosn|all]            # 只跑 bench
#   ./oneshot.sh <master_ip> report                           # 只取报告
#
# 例子：
#   ./oneshot.sh 62.234.130.135                               # H2 集群一键（默认免密）
#   ./oneshot.sh 101.43.161.139 bench cosn                    # H3 只跑 cosn bench
#   ./oneshot.sh 152.136.174.154 all all "C:\Users\lkl\Desktop\lkl_meson.pem"   # 用密钥登录
#   SSH_KEY=~/lkl_meson.pem ./oneshot.sh 152.136.174.154      # 也可用环境变量传密钥
#
# 前提：
#   1. 你能 ssh root@<master_ip>（公钥免密 / 已经在 known_hosts / 或者提供 -i <key>）
#   2. master 上 root 能 su - hadoop（EMR 默认 OK）
#
# 输出：
#   远端 /home/hadoop/bench/results/2x2_matrix_report.md（最终报告）
#   本地 ./reports/<ip>_<timestamp>_2x2_matrix_report.md（自动拷回）
# ====================================================================
set -e

MASTER_IP=${1:?用法: $0 <master_ip> [inspect|install|bench|report|all] [bench_mode] [ssh_key_path]}
ACTION=${2:-all}
BENCH_MODE=${3:-all}   # 给 bench 子命令用
# 第 4 个参数当 ssh 私钥用；如果是合法 action（inspect/install/bench/report/all）说明用户跳过了 bench_mode
# 也支持 SSH_KEY 环境变量
SSH_KEY="${4:-${SSH_KEY:-}}"

# 兼容：用户在 bench 模式下顺序应该是 ip bench <mode> <key>，其它 action 不需要 bench_mode，
# 如果 $3 看起来像个文件路径而非 hdfs/cosn/all，则把它当 key
if [ -z "$SSH_KEY" ] && [ -n "$3" ] && [ "$ACTION" != "bench" ]; then
  case "$3" in
    hdfs|cosn|all) : ;;  # 是合法 bench_mode，保持
    *)
      # 看起来是路径
      if [ -f "$3" ] || echo "$3" | grep -qE '\.(pem|key)$|[/\\]'; then
        SSH_KEY="$3"
        BENCH_MODE="all"
      fi
      ;;
  esac
fi

TOOLKIT_DIR_ORIG="$(cd "$(dirname "$0")" && pwd)"
# 中文路径在 zsh/bash 下 scp 转义会出错，先 tar pipe 到纯英文临时目录
TOOLKIT_DIR="/tmp/bench-toolkit-local-$$"
rm -rf "$TOOLKIT_DIR"
mkdir -p "$TOOLKIT_DIR"
(cd "$TOOLKIT_DIR_ORIG" && tar cf - .) | (cd "$TOOLKIT_DIR" && tar xf -)

# Windows 下 .sh 行尾是 CRLF，传到 Linux 会报 $'\r': command not found，统一去掉 \r
# 仅处理常见文本脚本类型（避免误伤 jar/zip 等二进制）
find "$TOOLKIT_DIR" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.sql' -o -name '*.conf' -o -name '*.properties' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.md' -o -name '*.txt' \) -print0 \
  | xargs -0 -I{} sed -i 's/\r$//' "{}" 2>/dev/null || true

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

# ====== 处理 SSH 私钥 ======
# 把 Windows 风格路径（含反斜杠 / 盘符）转成 Git-Bash 能用的 /c/... 形式
normalize_key_path() {
  local p="$1"
  [ -z "$p" ] && return 0
  # C:\Users\lkl\... → /c/Users/lkl/...
  if echo "$p" | grep -qE '^[A-Za-z]:[\\/]'; then
    local drive
    drive=$(echo "$p" | cut -c1 | tr 'A-Z' 'a-z')
    p=$(echo "$p" | sed -E "s|^[A-Za-z]:[\\\\/]|/${drive}/|" | tr '\\' '/')
  fi
  echo "$p"
}

SSH_KEY_OPT=""
if [ -n "$SSH_KEY" ]; then
  SSH_KEY=$(normalize_key_path "$SSH_KEY")
  if [ ! -f "$SSH_KEY" ]; then
    err "SSH 私钥文件不存在：$SSH_KEY"
    exit 1
  fi
  # OpenSSH 要求私钥权限 ≤ 600，否则拒绝使用
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  SSH_KEY_OPT="-i $SSH_KEY -o IdentitiesOnly=yes"
  log "使用 SSH 私钥登录：$SSH_KEY"
fi

SSH="ssh $SSH_KEY_OPT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 root@$MASTER_IP"
SCP_OPTS="$SSH_KEY_OPT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
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
    if [ -n "$SSH_KEY" ]; then
      err "请确认私钥 $SSH_KEY 与目标机器 /root/.ssh/authorized_keys 匹配"
    else
      err "请确保你的公钥 ~/.ssh/id_*.pub 已添加到目标 master 的 /root/.ssh/authorized_keys"
      err "或者通过参数提供私钥：$0 <master_ip> all all <ssh_key_path>"
    fi
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
