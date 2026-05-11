#!/bin/bash
# watch_nm_decommission.sh
# 观察 NM 下线后的 Flink 作业恢复情况
#
# 用法：
#   ./watch_nm_decommission.sh "nm-1 nm-2 nm-3 nm-4"    # 监控这一批
#
# 功能：
#   - 每 30s 刷新一次节点状态
#   - 检测作业 FAILED / attempt 升级
#   - 观察 30 分钟自动退出；按 Ctrl+C 提前退出
#
# 作者：eric
# 版本：v1.0 / 2026-05-11

set -o pipefail

BATCH_NODES="${1:-}"
DURATION_SEC="${2:-1800}"   # 默认观察 30 分钟
INTERVAL=30

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$BATCH_NODES" ]; then
    echo "用法: $0 \"nm-1 nm-2 nm-3 nm-4\" [观察秒数=1800]"
    exit 1
fi

echo "=================================================="
echo "  NM 下线观察窗口 - $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo "观察节点：$BATCH_NODES"
echo "观察时长：$((DURATION_SEC / 60)) 分钟"
echo "刷新间隔：${INTERVAL}s"
echo ""
echo "按 Ctrl+C 可提前退出"
echo ""

# 记录初始作业状态
BASELINE_FILE=$(mktemp)
yarn application -list -appTypes "Apache Flink" 2>/dev/null | tail -n +3 > "$BASELINE_FILE"
BASELINE_COUNT=$(wc -l < "$BASELINE_FILE")
echo "基线 Flink 作业数：$BASELINE_COUNT"
echo "基线已保存到：$BASELINE_FILE"
echo ""

START_TIME=$(date +%s)
ROUND=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [ $ELAPSED -ge $DURATION_SEC ]; then
        echo ""
        echo -e "${GREEN}========== 观察期结束 ==========${NC}"
        break
    fi

    ROUND=$((ROUND + 1))
    REMAIN=$((DURATION_SEC - ELAPSED))
    echo "---------- Round $ROUND @ $(date '+%H:%M:%S') (剩余 $((REMAIN / 60))min) ----------"

    # [1] 节点状态
    echo "[节点状态]"
    for nm in $BATCH_NODES; do
        STATE=$(yarn node -list -all 2>/dev/null | grep "$nm" | awk '{print $2}' | head -1)
        case "$STATE" in
            DECOMMISSIONED) echo -e "  $nm: ${GREEN}$STATE${NC}" ;;
            DECOMMISSIONING) echo -e "  $nm: ${YELLOW}$STATE${NC}（还在跑 container）" ;;
            LOST) echo -e "  $nm: ${YELLOW}$STATE${NC}（已断连，正常）" ;;
            RUNNING) echo -e "  $nm: ${RED}$STATE（异常！未生效）${NC}" ;;
            *) echo "  $nm: ${STATE:-unknown}" ;;
        esac
    done

    # [2] Flink 作业状态
    CURRENT_FILE=$(mktemp)
    yarn application -list -appTypes "Apache Flink" 2>/dev/null | tail -n +3 > "$CURRENT_FILE"
    CURRENT_COUNT=$(wc -l < "$CURRENT_FILE")

    FAILED_COUNT=$(yarn application -list -appStates FAILED 2>/dev/null | \
        tail -n +3 | grep -c "Flink" || true)
    RUNNING_COUNT=$(grep -c "RUNNING" "$CURRENT_FILE" || true)
    ACCEPTED_COUNT=$(grep -c "ACCEPTED" "$CURRENT_FILE" || true)

    echo "[作业统计]"
    echo "  RUNNING: $RUNNING_COUNT / ACCEPTED: $ACCEPTED_COUNT / 最近 FAILED: $FAILED_COUNT"

    # [3] 新增的 FAILED 作业告警
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo -e "${RED}[告警] 发现 FAILED 作业：${NC}"
        yarn application -list -appStates FAILED 2>/dev/null | \
            tail -n +3 | grep "Flink" | head -5 | awk '{print "  - " $1, $2}'
    fi

    # [4] 作业数大幅波动告警
    DIFF=$((BASELINE_COUNT - CURRENT_COUNT))
    if [ "$DIFF" -gt 2 ]; then
        echo -e "${YELLOW}[注意] 作业数减少 $DIFF 个（可能 FAILED 或 FINISHED）${NC}"
    fi

    # [5] ACCEPTED 堆积告警（资源不足）
    if [ "$ACCEPTED_COUNT" -gt 3 ]; then
        echo -e "${YELLOW}[注意] ACCEPTED 作业数 $ACCEPTED_COUNT - 可能资源不足${NC}"
    fi

    rm -f "$CURRENT_FILE"
    echo ""

    sleep $INTERVAL
done

echo ""
echo "========== 观察总结 =========="
echo "观察时长：$((ELAPSED / 60)) 分钟"
echo "最终作业数：$CURRENT_COUNT（基线 $BASELINE_COUNT）"
echo "最终 FAILED：$FAILED_COUNT"
echo ""

# 判决建议
if [ "$FAILED_COUNT" -eq 0 ] && [ "$CURRENT_COUNT" -ge $((BASELINE_COUNT - 1)) ]; then
    echo -e "${GREEN}✅ 建议：可以继续下一批${NC}"
elif [ "$FAILED_COUNT" -le 2 ]; then
    echo -e "${YELLOW}⚠️ 建议：少量 FAILED，确认 DP 平台已自愈后可继续${NC}"
else
    echo -e "${RED}🔴 建议：停止后续批次，按 SOP §8.2 处理${NC}"
fi

rm -f "$BASELINE_FILE"
