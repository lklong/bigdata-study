#!/bin/bash
# ============================================================
# Kyuubi YARN 残留 Spark Application 清理脚本
#
# 功能：精确匹配 Kyuubi 拉起的 Spark Application，清理残留进程
# 安全：支持 dry-run 模式（默认），先预览再执行
#
# 用法：
#   ./cleanup-orphan-spark-apps.sh                    # dry-run 模式（只查看不清理）
#   ./cleanup-orphan-spark-apps.sh --execute          # 执行清理
#   ./cleanup-orphan-spark-apps.sh --max-age 3600     # 只清理存活超过 1 小时的
#   ./cleanup-orphan-spark-apps.sh --auto             # 自动模式（用于 crontab）
#   ./cleanup-orphan-spark-apps.sh --execute --max-age 7200  # 清理存活超 2 小时的
#
# 匹配规则：Application Name 包含 "kyuubi" 或 "KyuubiSQLEngine"
# ============================================================

set -euo pipefail

# ===== 参数解析 =====
DRY_RUN=true
MAX_AGE_SECONDS=0  # 0 表示不限制
AUTO_MODE=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --execute)
            DRY_RUN=false
            shift
            ;;
        --max-age)
            MAX_AGE_SECONDS="$2"
            shift 2
            ;;
        --auto)
            AUTO_MODE=true
            DRY_RUN=false
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "用法: $0 [--execute] [--max-age <秒>] [--auto] [--verbose]"
            echo ""
            echo "选项:"
            echo "  --execute     执行清理（默认为 dry-run 只查看）"
            echo "  --max-age N   只清理存活超过 N 秒的应用（默认 0=不限制）"
            echo "  --auto        自动模式（用于 crontab，静默执行）"
            echo "  --verbose     详细输出"
            echo "  --help        显示此帮助"
            exit 0
            ;;
        *)
            echo "ERROR: 未知参数: $1"
            exit 1
            ;;
    esac
done

# ===== 配置 =====
# Kyuubi Application 匹配模式（Application Name 中包含这些关键字）
MATCH_PATTERNS="kyuubi|KyuubiSQLEngine|Kyuubi"

# 当前时间戳（毫秒）
CURRENT_TIME_MS=$(($(date +%s) * 1000))

# 日志函数
log() {
    if [ "$AUTO_MODE" = false ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    fi
}

log_auto() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ===== 主逻辑 =====

log "============================================================"
log "Kyuubi YARN 残留 Spark Application 清理"
log "============================================================"
log "模式: $([ "$DRY_RUN" = true ] && echo 'DRY-RUN（只查看不清理）' || echo '⚠️  执行清理')"
[ "$MAX_AGE_SECONDS" -gt 0 ] && log "最小存活时间: ${MAX_AGE_SECONDS} 秒"
log ""

# Step 1: 获取所有 RUNNING 的 Kyuubi Application
TEMP_FILE=$(mktemp /tmp/kyuubi-cleanup-XXXXXX.txt)
trap "rm -f $TEMP_FILE" EXIT

yarn application -list -appStates RUNNING 2>/dev/null \
    | grep -iE "$MATCH_PATTERNS" \
    > "$TEMP_FILE" || true

TOTAL=$(wc -l < "$TEMP_FILE" | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
    log "✅ 未发现残留的 Kyuubi Spark Application"
    exit 0
fi

log "发现 ${TOTAL} 个 RUNNING 状态的 Kyuubi Spark Application"
log ""

# Step 2: 过滤和展示
KILL_COUNT=0
SKIP_COUNT=0

if [ "$DRY_RUN" = true ] || [ "$VERBOSE" = true ]; then
    printf "%-30s %-20s %-15s %-10s %s\n" "Application ID" "User" "Elapsed" "State" "Name"
    echo "============================== ==================== =============== ========== =============================="
fi

while IFS= read -r line; do
    # 解析 YARN application 列表输出
    APP_ID=$(echo "$line" | awk '{print $1}')
    APP_NAME=$(echo "$line" | awk '{print $2}')
    APP_TYPE=$(echo "$line" | awk '{print $3}')
    APP_USER=$(echo "$line" | awk '{print $4}')
    APP_STATE=$(echo "$line" | awk '{print $6}')

    # 跳过非 Application ID 格式的行
    if [[ ! "$APP_ID" =~ ^application_ ]]; then
        continue
    fi

    # 获取应用详细信息（启动时间）
    STARTED_TIME=""
    ELAPSED=""
    SHOULD_KILL=true

    if [ "$MAX_AGE_SECONDS" -gt 0 ]; then
        # 通过 YARN REST API 获取启动时间（更精确）
        # 如果 REST API 不可用，则默认清理
        APP_INFO=$(yarn application -status "$APP_ID" 2>/dev/null || echo "")
        START_TIME_LINE=$(echo "$APP_INFO" | grep -i "Start-Time" | head -1)

        if [ -n "$START_TIME_LINE" ]; then
            START_TIME_MS=$(echo "$START_TIME_LINE" | awk -F: '{print $2}' | tr -d ' ')
            if [[ "$START_TIME_MS" =~ ^[0-9]+$ ]]; then
                AGE_SECONDS=$(( (CURRENT_TIME_MS - START_TIME_MS) / 1000 ))
                ELAPSED="${AGE_SECONDS}s"

                if [ "$AGE_SECONDS" -lt "$MAX_AGE_SECONDS" ]; then
                    SHOULD_KILL=false
                fi
            fi
        fi
    fi

    if [ "$DRY_RUN" = true ] || [ "$VERBOSE" = true ]; then
        KILL_TAG=""
        if [ "$MAX_AGE_SECONDS" -gt 0 ]; then
            if [ "$SHOULD_KILL" = true ]; then
                KILL_TAG="[WILL KILL]"
            else
                KILL_TAG="[SKIP-TOO-YOUNG]"
            fi
        fi
        printf "%-30s %-20s %-15s %-10s %s %s\n" \
            "$APP_ID" "$APP_USER" "${ELAPSED:-N/A}" "$APP_STATE" "$APP_NAME" "$KILL_TAG"
    fi

    if [ "$SHOULD_KILL" = true ]; then
        KILL_COUNT=$((KILL_COUNT + 1))

        if [ "$DRY_RUN" = false ]; then
            yarn application -kill "$APP_ID" 2>/dev/null && \
                log_auto "KILLED: $APP_ID ($APP_NAME, user=$APP_USER)" || \
                log_auto "FAILED to kill: $APP_ID"
        fi
    else
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi

done < "$TEMP_FILE"

# Step 3: 输出汇总
log ""
log "============================================================"
log "汇总"
log "============================================================"
log "总计发现: ${TOTAL}"
log "需清理:   ${KILL_COUNT}"
log "跳过:     ${SKIP_COUNT}"

if [ "$DRY_RUN" = true ]; then
    log ""
    log "⚠️  当前为 DRY-RUN 模式，未执行任何清理操作"
    log "    如需执行清理，请添加 --execute 参数："
    log "    $0 --execute $([ "$MAX_AGE_SECONDS" -gt 0 ] && echo "--max-age $MAX_AGE_SECONDS")"
else
    log "已清理:   ${KILL_COUNT}"
    log ""

    # 验证资源释放
    if [ "$AUTO_MODE" = false ]; then
        log "等待 5 秒后检查 YARN 资源..."
        sleep 5
        REMAINING=$(yarn application -list -appStates RUNNING 2>/dev/null | grep -icE "$MATCH_PATTERNS" || echo 0)
        log "清理后剩余 Kyuubi 应用: ${REMAINING}"
    fi
fi
