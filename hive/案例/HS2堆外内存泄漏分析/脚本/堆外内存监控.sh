#!/bin/bash
# ============================================================
# HiveServer2 堆外内存监控脚本
# 用法: ./monitor-offheap.sh [采样间隔秒数] [采样次数]
# 示例: ./monitor-offheap.sh 60 1440  # 每分钟采样一次，持续24小时
# ============================================================

INTERVAL=${1:-60}
COUNT=${2:-0}  # 0 = 无限

HS2_PID=$(pgrep -f "HiveServer2" | head -1)

if [ -z "$HS2_PID" ]; then
    echo "ERROR: HiveServer2 进程未找到"
    exit 1
fi

echo "============================================================"
echo "HiveServer2 堆外内存监控"
echo "PID: $HS2_PID"
echo "采样间隔: ${INTERVAL}s"
echo "采样次数: $([ $COUNT -eq 0 ] && echo '无限' || echo $COUNT)"
echo "============================================================"
echo ""

LOG_FILE="hs2-offheap-monitor-$(date +%Y%m%d_%H%M%S).csv"
echo "timestamp,rss_mb,vsz_mb,thread_count,direct_buffer_count,direct_buffer_mb,mapped_buffer_count,mapped_buffer_mb" > "$LOG_FILE"
echo "数据输出到: $LOG_FILE"
echo ""

printf "%-20s %10s %10s %8s %12s %12s\n" "时间" "RSS(MB)" "VSZ(MB)" "线程数" "DirectBuf" "MappedBuf"
echo "-------------------- ---------- ---------- -------- ------------ ------------"

i=0
while [ $COUNT -eq 0 ] || [ $i -lt $COUNT ]; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 检查进程是否存活
    if ! kill -0 "$HS2_PID" 2>/dev/null; then
        echo "[$TIMESTAMP] WARN: HiveServer2 进程 $HS2_PID 已退出!"
        break
    fi
    
    # RSS 和 VSZ
    MEM_INFO=$(ps -p "$HS2_PID" -o rss=,vsz= 2>/dev/null)
    RSS_KB=$(echo "$MEM_INFO" | awk '{print $1}')
    VSZ_KB=$(echo "$MEM_INFO" | awk '{print $2}')
    RSS_MB=$((RSS_KB / 1024))
    VSZ_MB=$((VSZ_KB / 1024))
    
    # 线程数
    THREAD_COUNT=$(ls /proc/"$HS2_PID"/task 2>/dev/null | wc -l || echo "N/A")
    
    # DirectByteBuffer 统计 (通过 jcmd)
    NIO_INFO=$(jcmd "$HS2_PID" VM.info 2>/dev/null | grep -A2 "Direct buffer" || echo "")
    DIRECT_COUNT=$(echo "$NIO_INFO" | grep -oP 'count=\K[0-9]+' | head -1 || echo "N/A")
    DIRECT_MB=$(echo "$NIO_INFO" | grep -oP 'total_capacity=\K[0-9]+' | head -1 | awk '{printf "%.1f", $1/1048576}' || echo "N/A")
    MAPPED_COUNT=$(echo "$NIO_INFO" | grep -A2 "Mapped buffer" | grep -oP 'count=\K[0-9]+' | head -1 || echo "N/A")
    MAPPED_MB=$(echo "$NIO_INFO" | grep -A2 "Mapped buffer" | grep -oP 'total_capacity=\K[0-9]+' | head -1 | awk '{printf "%.1f", $1/1048576}' || echo "N/A")
    
    # 输出到控制台
    printf "%-20s %10s %10s %8s %12s %12s\n" \
        "$TIMESTAMP" "${RSS_MB}" "${VSZ_MB}" "$THREAD_COUNT" \
        "${DIRECT_COUNT:-N/A}/${DIRECT_MB:-N/A}MB" "${MAPPED_COUNT:-N/A}/${MAPPED_MB:-N/A}MB"
    
    # 输出到 CSV
    echo "$TIMESTAMP,$RSS_MB,$VSZ_MB,$THREAD_COUNT,${DIRECT_COUNT:-0},${DIRECT_MB:-0},${MAPPED_COUNT:-0},${MAPPED_MB:-0}" >> "$LOG_FILE"
    
    # RSS 告警阈值 (默认 Xmx*1.5，这里假设 Xmx=8g，阈值=12g)
    ALERT_THRESHOLD_MB=${ALERT_THRESHOLD_MB:-12288}
    if [ "$RSS_MB" -gt "$ALERT_THRESHOLD_MB" ] 2>/dev/null; then
        echo "  ⚠️  ALERT: RSS ${RSS_MB}MB 超过阈值 ${ALERT_THRESHOLD_MB}MB!"
    fi
    
    i=$((i + 1))
    sleep "$INTERVAL"
done

echo ""
echo "监控结束。数据已保存到: $LOG_FILE"
