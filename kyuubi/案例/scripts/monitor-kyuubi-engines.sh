#!/bin/bash
# ============================================================
# Kyuubi 引擎健康监控脚本
#
# 功能：定期检查 YARN 上 Kyuubi Spark App 数量/状态/资源占用
#       超阈值时输出告警信息
#
# 用法：
#   ./monitor-kyuubi-engines.sh              # 单次检查
#   ./monitor-kyuubi-engines.sh --loop 300   # 持续监控（每 5 分钟）
#
# crontab 示例：
#   */10 * * * * /path/to/monitor-kyuubi-engines.sh >> /var/log/kyuubi-monitor.log 2>&1
# ============================================================

set -euo pipefail

# ===== 配置 =====
MATCH_PATTERNS="kyuubi|KyuubiSQLEngine|Kyuubi"
WARN_THRESHOLD=${KYUUBI_WARN_THRESHOLD:-20}      # WARNING 阈值
CRIT_THRESHOLD=${KYUUBI_CRIT_THRESHOLD:-50}      # CRITICAL 阈值
MAX_APP_AGE_HOURS=${KYUUBI_MAX_APP_AGE_HOURS:-2} # 单个应用最大存活小时数
LOOP_INTERVAL=0  # 0=单次

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        --loop)
            LOOP_INTERVAL="$2"
            shift 2
            ;;
        --warn)
            WARN_THRESHOLD="$2"
            shift 2
            ;;
        --crit)
            CRIT_THRESHOLD="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [--loop <秒>] [--warn <阈值>] [--crit <阈值>]"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# ===== 函数 =====
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

check_once() {
    local TS
    TS=$(timestamp)

    # 1. 获取 Kyuubi RUNNING 应用数量
    local RUNNING_COUNT
    RUNNING_COUNT=$(yarn application -list -appStates RUNNING 2>/dev/null \
        | grep -icE "$MATCH_PATTERNS" || echo 0)

    # 2. 获取 ACCEPTED 状态的应用（等待资源）
    local ACCEPTED_COUNT
    ACCEPTED_COUNT=$(yarn application -list -appStates ACCEPTED 2>/dev/null \
        | grep -icE "$MATCH_PATTERNS" || echo 0)

    # 3. Kyuubi Server 进程检查
    local KYUUBI_PID
    KYUUBI_PID=$(pgrep -f "org.apache.kyuubi" 2>/dev/null | head -1 || echo "")
    local KYUUBI_STATUS
    if [ -n "$KYUUBI_PID" ]; then
        KYUUBI_STATUS="RUNNING (PID: $KYUUBI_PID)"
        # 获取 RSS 内存
        local RSS_KB
        RSS_KB=$(ps -p "$KYUUBI_PID" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
        local RSS_MB=$((RSS_KB / 1024))
        KYUUBI_STATUS="$KYUUBI_STATUS, RSS=${RSS_MB}MB"
        # 获取线程数
        local THREAD_COUNT
        THREAD_COUNT=$(ls /proc/"$KYUUBI_PID"/task 2>/dev/null | wc -l || echo "N/A")
        KYUUBI_STATUS="$KYUUBI_STATUS, Threads=${THREAD_COUNT}"
    else
        KYUUBI_STATUS="NOT RUNNING ⚠️"
    fi

    # 4. 告警判断
    local ALERT_LEVEL="OK"
    local ALERT_MSG=""

    if [ "$RUNNING_COUNT" -ge "$CRIT_THRESHOLD" ]; then
        ALERT_LEVEL="CRITICAL"
        ALERT_MSG="YARN 上 Kyuubi 应用数 ${RUNNING_COUNT} 超过 CRITICAL 阈值 ${CRIT_THRESHOLD}！可能存在严重的引擎泄漏。"
    elif [ "$RUNNING_COUNT" -ge "$WARN_THRESHOLD" ]; then
        ALERT_LEVEL="WARNING"
        ALERT_MSG="YARN 上 Kyuubi 应用数 ${RUNNING_COUNT} 超过 WARNING 阈值 ${WARN_THRESHOLD}。请关注是否有引擎泄漏。"
    fi

    if [ "$ACCEPTED_COUNT" -gt 5 ]; then
        ALERT_LEVEL="WARNING"
        ALERT_MSG="${ALERT_MSG} 有 ${ACCEPTED_COUNT} 个应用等待资源（ACCEPTED），YARN 资源可能不足。"
    fi

    if [ -z "$KYUUBI_PID" ]; then
        ALERT_LEVEL="CRITICAL"
        ALERT_MSG="${ALERT_MSG} Kyuubi Server 进程未运行！"
    fi

    # 5. 输出
    echo "[$TS] [${ALERT_LEVEL}] Kyuubi Monitor | RUNNING=${RUNNING_COUNT} ACCEPTED=${ACCEPTED_COUNT} | Server: ${KYUUBI_STATUS}"

    if [ -n "$ALERT_MSG" ]; then
        echo "[$TS] >>> ALERT: ${ALERT_MSG}"
    fi

    # 6. 检查长时间运行的应用
    local CURRENT_EPOCH
    CURRENT_EPOCH=$(date +%s)
    local MAX_AGE_SECONDS=$((MAX_APP_AGE_HOURS * 3600))

    yarn application -list -appStates RUNNING 2>/dev/null \
        | grep -iE "$MATCH_PATTERNS" \
        | while IFS= read -r line; do
            local APP_ID
            APP_ID=$(echo "$line" | awk '{print $1}')
            if [[ ! "$APP_ID" =~ ^application_ ]]; then
                continue
            fi

            # 获取启动时间
            local APP_INFO
            APP_INFO=$(yarn application -status "$APP_ID" 2>/dev/null || echo "")
            local START_LINE
            START_LINE=$(echo "$APP_INFO" | grep -i "Start-Time" | head -1)

            if [ -n "$START_LINE" ]; then
                local START_MS
                START_MS=$(echo "$START_LINE" | awk -F: '{print $2}' | tr -d ' ')
                if [[ "$START_MS" =~ ^[0-9]+$ ]]; then
                    local START_EPOCH=$((START_MS / 1000))
                    local AGE_SEC=$((CURRENT_EPOCH - START_EPOCH))

                    if [ "$AGE_SEC" -gt "$MAX_AGE_SECONDS" ]; then
                        local AGE_HOURS=$((AGE_SEC / 3600))
                        echo "[$TS] >>> LONG-RUNNING: $APP_ID 已运行 ${AGE_HOURS}h（阈值 ${MAX_APP_AGE_HOURS}h），可能是残留引擎"
                    fi
                fi
            fi
        done 2>/dev/null || true
}

# ===== 主逻辑 =====

if [ "$LOOP_INTERVAL" -gt 0 ]; then
    echo "[$(timestamp)] Kyuubi 引擎监控启动（间隔 ${LOOP_INTERVAL}s）"
    echo "======================================================"
    while true; do
        check_once
        sleep "$LOOP_INTERVAL"
    done
else
    check_once
fi
