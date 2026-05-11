#!/bin/bash
# shutdown_nm_batch.sh
# 批量关机 NM 节点（分批执行的辅助脚本）
#
# 用法：
#   ./shutdown_nm_batch.sh "nm-1 nm-2 nm-3 nm-4"
#
# 前置条件：
#   - 已完成全量 exclude（yarn rmadmin -refreshNodes 已执行）
#   - 已对关键作业做 Savepoint
#   - 已识别本批节点为风险最低的 4 个
#
# 作者：eric
# 版本：v1.0 / 2026-05-11

set -e
set -o pipefail

BATCH_NODES="${1:-}"
DRY_RUN="${DRY_RUN:-false}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$BATCH_NODES" ]; then
    echo "用法: $0 \"nm-1 nm-2 nm-3 nm-4\""
    echo ""
    echo "环境变量："
    echo "  DRY_RUN=true   只打印不执行（强烈建议先跑一遍）"
    exit 1
fi

echo "=================================================="
echo "  NM 批量关机 - $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo "本批节点：$BATCH_NODES"
echo "DRY_RUN：$DRY_RUN"
echo ""

# ============================================================
# 前置检查
# ============================================================
echo "========== 前置检查 =========="

# [1] 确认节点都在 exclude 里
EXCLUDE_FILE="/etc/hadoop/conf/yarn.exclude"
MISSING=""
for nm in $BATCH_NODES; do
    if ! grep -qE "^${nm}$" "$EXCLUDE_FILE" 2>/dev/null; then
        MISSING="$MISSING $nm"
    fi
done

if [ -n "$MISSING" ]; then
    echo -e "${RED}❌ 以下节点未在 exclude 中：$MISSING${NC}"
    echo "   请先完成 SOP §4.1 步骤（全量 exclude）"
    exit 1
fi
echo -e "${GREEN}✅ 所有节点已在 exclude 列表${NC}"

# [2] 确认节点当前状态
echo ""
echo "节点当前状态："
for nm in $BATCH_NODES; do
    STATE=$(yarn node -list -all 2>/dev/null | grep "$nm" | awk '{print $2}' | head -1)
    echo "  $nm: ${STATE:-UNKNOWN}"
done

# [3] 确认操作员意图
echo ""
if [ "$DRY_RUN" != "true" ]; then
    echo -e "${YELLOW}⚠️ 即将执行真实关机操作${NC}"
    read -p "输入 'YES' 确认继续: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "操作已取消"
        exit 0
    fi
fi

# ============================================================
# 阶段 1：停止 NodeManager
# ============================================================
echo ""
echo "========== 阶段 1：停止 NodeManager =========="

for nm in $BATCH_NODES; do
    echo -n "[$(date '+%H:%M:%S')] Stopping NM on $nm ... "

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY_RUN] ssh $nm 'sudo systemctl stop hadoop-yarn-nodemanager'"
    else
        if ssh -o ConnectTimeout=10 "$nm" "sudo systemctl stop hadoop-yarn-nodemanager" 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    fi
    sleep 5   # 错开停止
done

echo ""
echo "等待 30s 让 RM 同步节点状态..."
[ "$DRY_RUN" != "true" ] && sleep 30

# ============================================================
# 阶段 2：关机
# ============================================================
echo ""
echo "========== 阶段 2：关机 =========="

for nm in $BATCH_NODES; do
    echo -n "[$(date '+%H:%M:%S')] Shutting down $nm ... "

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY_RUN] ssh $nm 'sudo shutdown -h +1'"
    else
        # +1 分钟后关机，给 ssh 会话退出留时间
        if ssh -o ConnectTimeout=10 "$nm" "sudo shutdown -h +1" 2>&1; then
            echo -e "${GREEN}关机命令已下发${NC}"
        else
            echo -e "${YELLOW}ssh 失败或节点已不可达${NC}"
        fi
    fi
    sleep 2
done

# ============================================================
# 完成
# ============================================================
echo ""
echo "========== 批次关机完成 =========="
echo "完成时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "下一步操作："
echo "  1. 运行观察脚本：./watch_nm_decommission.sh \"$BATCH_NODES\""
echo "  2. 观察 30 分钟后根据 SOP §5.3 判决表决定是否继续下一批"
echo ""
