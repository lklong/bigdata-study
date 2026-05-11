#!/bin/bash
# pre_check_nm_decommission.sh
# 批量下线 NM 节点前的预检脚本
#
# 用法：
#   ./pre_check_nm_decommission.sh "nm-1,nm-2,nm-3,nm-4,nm-5,nm-6,nm-7,nm-8"
#
# 输出：
#   - 每个待下线节点的 container 情况
#   - 所有 Flink 作业的 AM 位置（标红在待下线节点上的）
#   - 集群剩余资源估算
#   - 建议的分批方案
#
# 作者：eric
# 版本：v1.0 / 2026-05-11

set -o pipefail

if [ -z "$1" ]; then
    echo "用法: $0 \"nm-1,nm-2,nm-3,...\""
    exit 1
fi

NM_LIST="$1"
IFS=',' read -ra NMS <<< "$NM_LIST"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=================================================="
echo "  NM 节点下线预检报告 - $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="
echo "待下线节点数：${#NMS[@]}"
echo "待下线节点列表："
for nm in "${NMS[@]}"; do echo "  - $nm"; done
echo ""

# ============================================================
# [1] 集群总量与待下线占比
# ============================================================
echo "========== [1/5] 集群容量分析 =========="
TOTAL_NM=$(yarn node -list -states RUNNING 2>/dev/null | tail -n +3 | wc -l)
DECOM_RATIO=$(awk "BEGIN {printf \"%.1f\", ${#NMS[@]}/$TOTAL_NM*100}")
echo "集群 RUNNING NM 总数：$TOTAL_NM"
echo "待下线占比：$DECOM_RATIO%"

if awk "BEGIN {exit !($DECOM_RATIO > 20)}"; then
    echo -e "${RED}⚠️ 警告：下线占比超过 20%，风险较高${NC}"
elif awk "BEGIN {exit !($DECOM_RATIO > 10)}"; then
    echo -e "${YELLOW}⚠️ 提示：下线占比 >10%，建议分批${NC}"
else
    echo -e "${GREEN}✅ 下线占比 <10%，容量风险低${NC}"
fi
echo ""

# ============================================================
# [2] 每个待下线节点的 Container 情况
# ============================================================
echo "========== [2/5] 待下线节点 Container 详情 =========="
printf "%-40s %-15s %-15s %-15s\n" "NODE" "CONTAINERS" "MEM_USED" "VCORE_USED"
echo "---------------------------------------------------------------------------------------"

for h in "${NMS[@]}"; do
    NODE_ID=$(yarn node -list 2>/dev/null | grep "$h" | awk '{print $1}' | head -1)
    if [ -z "$NODE_ID" ]; then
        printf "%-40s ${RED}%-15s${NC}\n" "$h" "未找到"
        continue
    fi

    STATUS_OUTPUT=$(yarn node -status "$NODE_ID" 2>/dev/null)
    CONTAINERS=$(echo "$STATUS_OUTPUT" | grep -E "Num Containers" | awk -F':' '{print $2}' | tr -d ' ')
    MEM=$(echo "$STATUS_OUTPUT" | grep -E "Used Memory" | awk -F':' '{print $2}' | tr -d ' ')
    VCORE=$(echo "$STATUS_OUTPUT" | grep -E "Used VirtualCores" | awk -F':' '{print $2}' | tr -d ' ')

    printf "%-40s %-15s %-15s %-15s\n" "$h" "${CONTAINERS:-?}" "${MEM:-?}" "${VCORE:-?}"
done
echo ""

# ============================================================
# [3] Flink 作业 AM 位置分析（核心）
# ============================================================
echo "========== [3/5] Flink 作业 AM 位置分析 =========="
echo ""

RUNNING_FLINK_APPS=$(yarn application -list -appTypes "Apache Flink" -appStates RUNNING 2>/dev/null | tail -n +3 | awk '{print $1}')
APPS_COUNT=$(echo "$RUNNING_FLINK_APPS" | grep -c "^application_" || true)
echo "当前 RUNNING Flink 作业数：$APPS_COUNT"
echo ""

declare -A NODE_AM_COUNT
AT_RISK_APPS=()

printf "%-35s %-35s %-12s %-30s %s\n" "APP_ID" "APP_NAME" "QUEUE" "AM_HOST" "AT_RISK"
echo "------------------------------------------------------------------------------------------------------------------------"

for APP_ID in $RUNNING_FLINK_APPS; do
    [ -z "$APP_ID" ] && continue

    STATUS=$(yarn application -status "$APP_ID" 2>/dev/null)
    AM_HOST=$(echo "$STATUS" | grep "AM Host" | awk -F':' '{print $2}' | tr -d ' ' | head -1)
    APP_NAME=$(echo "$STATUS" | grep "Application-Name" | awk -F':' '{print $2}' | tr -d ' ' | head -c 30)
    QUEUE=$(echo "$STATUS" | grep "Application Queue" | awk -F':' '{print $2}' | tr -d ' ' | head -1)

    AT_RISK=""
    for nm in "${NMS[@]}"; do
        if [[ "$AM_HOST" == *"$nm"* ]]; then
            AT_RISK="${RED}⚠️ YES ($nm)${NC}"
            AT_RISK_APPS+=("$APP_ID|$APP_NAME|$nm")
            NODE_AM_COUNT[$nm]=$((${NODE_AM_COUNT[$nm]:-0} + 1))
            break
        fi
    done
    [ -z "$AT_RISK" ] && AT_RISK="${GREEN}NO${NC}"

    printf "%-35s %-35s %-12s %-30s %b\n" "$APP_ID" "$APP_NAME" "$QUEUE" "$AM_HOST" "$AT_RISK"
done
echo ""

echo "--- AM 在待下线节点上的作业数：${#AT_RISK_APPS[@]} ---"
if [ ${#AT_RISK_APPS[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠️ 这些作业在关机时会经历 AM Failover，消耗 1 次 attempt${NC}"
    for app in "${AT_RISK_APPS[@]}"; do
        echo "   - $app"
    done
fi
echo ""

# ============================================================
# [4] 节点分批建议
# ============================================================
echo "========== [4/5] 分批建议（基于 AM 分布）=========="
echo ""
echo "节点 AM 密度："
BATCH_1_CANDIDATES=()
BATCH_2_CANDIDATES=()

for nm in "${NMS[@]}"; do
    COUNT=${NODE_AM_COUNT[$nm]:-0}
    echo "  $nm: $COUNT 个 AM"
    if [ "$COUNT" -eq 0 ]; then
        BATCH_1_CANDIDATES+=("$nm")
    else
        BATCH_2_CANDIDATES+=("$nm")
    fi
done
echo ""

# 凑够每批 4 个
while [ ${#BATCH_1_CANDIDATES[@]} -lt 4 ] && [ ${#BATCH_2_CANDIDATES[@]} -gt 0 ]; do
    BATCH_1_CANDIDATES+=("${BATCH_2_CANDIDATES[0]}")
    BATCH_2_CANDIDATES=("${BATCH_2_CANDIDATES[@]:1}")
done

echo -e "${GREEN}推荐第一批（AM 少，风险低）：${NC}"
printf "  "
printf "%s " "${BATCH_1_CANDIDATES[@]:0:4}"
echo ""
echo -e "${YELLOW}推荐第二批（AM 多，需先对关键作业 SP）：${NC}"
printf "  "
printf "%s " "${BATCH_1_CANDIDATES[@]:4}" "${BATCH_2_CANDIDATES[@]}"
echo ""
echo ""

# ============================================================
# [5] 操作员 Checklist
# ============================================================
echo "========== [5/5] 操作员 Checklist =========="
echo ""
echo "请操作员在开始前确认："
echo "  [ ] 已和 DP 平台同事沟通，能在平台侧暂停类别 A 作业的自动拉起"
echo "  [ ] 已准备好 SP 目标目录（类别 A 作业会用到）"
echo "  [ ] 已备份 /etc/hadoop/conf/yarn.exclude"
echo "  [ ] 已对类别 A 作业的 Flink JobID 有记录"
echo "  [ ] 集群 RM 监控正常，无当前活跃告警"
echo ""

# ============================================================
# 输出供后续使用的环境变量
# ============================================================
echo "========== 导出环境变量（复制到后续操作终端）=========="
echo ""
printf "export BATCH_1=\""
printf "%s " "${BATCH_1_CANDIDATES[@]:0:4}"
printf "\"\n"
printf "export BATCH_2=\""
printf "%s " "${BATCH_1_CANDIDATES[@]:4}" "${BATCH_2_CANDIDATES[@]}"
printf "\"\n"
echo "export AT_RISK_APPS_COUNT=${#AT_RISK_APPS[@]}"
echo ""
echo "预检完成：$(date '+%Y-%m-%d %H:%M:%S')"
