#!/bin/bash
# ============================================================
# NodeManager 堆外内存监控脚本
# 用法: ./monitor-nm-offheap.sh [采样间隔秒数] [采样次数]
# 示例: ./monitor-nm-offheap.sh 60 1440  # 每分钟采样一次，持续24小时
# ============================================================

INTERVAL=${1:-60}
COUNT=${2:-0}  # 0 = 无限

NM_PID=$(pgrep -f "org.apache.hadoop.yarn.server.nodemanager.NodeManager" | head -1)

if [ -z "$NM_PID" ]; then
    # 尝试其他匹配方式
    NM_PID=$(pgrep -f "NodeManager" | head -1)
fi

if [ -z "$NM_PID" ]; then
    echo "ERROR: NodeManager 进程未找到"
    echo "请确认 NodeManager 是否在运行:"
    echo "  ps -ef | grep NodeManager"
    exit 1
fi

echo "============================================================"
echo "NodeManager 堆外内存监控"
echo "PID: $NM_PID"
echo "采样间隔: ${INTERVAL}s"
echo "采样次数: $([ $COUNT -eq 0 ] && echo '无限' || echo $COUNT)"
echo "============================================================"
echo ""

# 获取 Xmx 设置
XMX_INFO=$(ps -p "$NM_PID" -o args= 2>/dev/null | grep -oP '\-Xmx\K[0-9]+[mgMG]' | head -1)
echo "NM JVM Xmx: ${XMX_INFO:-未知}"

# 获取 MALLOC_ARENA_MAX
ARENA_MAX=$(cat /proc/"$NM_PID"/environ 2>/dev/null | tr '\0' '\n' | grep MALLOC_ARENA_MAX | cut -d= -f2)
echo "MALLOC_ARENA_MAX: ${ARENA_MAX:-未设置(默认=8*cores)}"

# 获取 MaxDirectMemorySize
MAX_DIRECT=$(ps -p "$NM_PID" -o args= 2>/dev/null | grep -oP '\-XX:MaxDirectMemorySize=\K[0-9]+[mgMG]' | head -1)
echo "MaxDirectMemorySize: ${MAX_DIRECT:-未设置(默认=Xmx)}"

echo ""

LOG_FILE="nm-offheap-monitor-$(date +%Y%m%d_%H%M%S).csv"
echo "timestamp,rss_mb,vsz_mb,thread_count,fd_count,container_count,direct_buffer_count,direct_buffer_mb,mapped_buffer_count,mapped_buffer_mb,shuffle_connections" > "$LOG_FILE"
echo "数据输出到: $LOG_FILE"
echo ""

printf "%-20s %8s %8s %6s %6s %6s %12s %12s %8s\n" \
    "时间" "RSS(MB)" "VSZ(MB)" "线程" "FD数" "容器数" "DirectBuf" "MappedBuf" "Shuffle"
echo "-------------------- -------- -------- ------ ------ ------ ------------ ------------ --------"

i=0
while [ $COUNT -eq 0 ] || [ $i -lt $COUNT ]; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 检查进程是否存活
    if ! kill -0 "$NM_PID" 2>/dev/null; then
        echo "[$TIMESTAMP] WARN: NodeManager 进程 $NM_PID 已退出!"
        break
    fi
    
    # RSS 和 VSZ
    MEM_INFO=$(ps -p "$NM_PID" -o rss=,vsz= 2>/dev/null)
    RSS_KB=$(echo "$MEM_INFO" | awk '{print $1}')
    VSZ_KB=$(echo "$MEM_INFO" | awk '{print $2}')
    RSS_MB=$((RSS_KB / 1024))
    VSZ_MB=$((VSZ_KB / 1024))
    
    # 线程数
    THREAD_COUNT=$(ls /proc/"$NM_PID"/task 2>/dev/null | wc -l || echo "N/A")
    
    # 文件描述符数（FadvisedFileRegion 泄漏时 fd 也会增长）
    FD_COUNT=$(ls /proc/"$NM_PID"/fd 2>/dev/null | wc -l || echo "N/A")
    
    # Container 数量（通过 NM REST API 获取）
    CONTAINER_COUNT=$(curl -s "http://localhost:8042/ws/v1/node/containers" 2>/dev/null | \
        python -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('containers',{}).get('container',[])))" 2>/dev/null || echo "N/A")
    
    # DirectByteBuffer 统计 (通过 jcmd)
    NIO_INFO=$(jcmd "$NM_PID" VM.info 2>/dev/null | grep -A2 "Direct buffer" || echo "")
    DIRECT_COUNT=$(echo "$NIO_INFO" | grep -oP 'count=\K[0-9]+' | head -1)
    DIRECT_MB=$(echo "$NIO_INFO" | grep -oP 'total_capacity=\K[0-9]+' | head -1 | awk '{printf "%.1f", $1/1048576}')
    MAPPED_COUNT=$(echo "$NIO_INFO" | grep -A2 "Mapped buffer" | grep -oP 'count=\K[0-9]+' | head -1)
    MAPPED_MB=$(echo "$NIO_INFO" | grep -A2 "Mapped buffer" | grep -oP 'total_capacity=\K[0-9]+' | head -1 | awk '{printf "%.1f", $1/1048576}')
    
    # ShuffleHandler 连接数（通过 netstat 统计 ShuffleHandler 端口连接）
    SHUFFLE_PORT=$(grep "mapreduce.shuffle.port" /etc/hadoop/conf/yarn-site.xml 2>/dev/null | grep -oP '>\K[0-9]+' | head -1)
    SHUFFLE_PORT=${SHUFFLE_PORT:-13562}  # 默认端口
    SHUFFLE_CONN=$(ss -tnp 2>/dev/null | grep ":${SHUFFLE_PORT}" | wc -l || echo "N/A")
    
    # 输出到控制台
    printf "%-20s %8s %8s %6s %6s %6s %12s %12s %8s\n" \
        "$TIMESTAMP" "${RSS_MB}" "${VSZ_MB}" "$THREAD_COUNT" "$FD_COUNT" \
        "${CONTAINER_COUNT:-N/A}" \
        "${DIRECT_COUNT:-N/A}/${DIRECT_MB:-N/A}MB" \
        "${MAPPED_COUNT:-N/A}/${MAPPED_MB:-N/A}MB" \
        "${SHUFFLE_CONN:-N/A}"
    
    # 输出到 CSV
    echo "$TIMESTAMP,$RSS_MB,$VSZ_MB,$THREAD_COUNT,$FD_COUNT,${CONTAINER_COUNT:-0},${DIRECT_COUNT:-0},${DIRECT_MB:-0},${MAPPED_COUNT:-0},${MAPPED_MB:-0},${SHUFFLE_CONN:-0}" >> "$LOG_FILE"
    
    # RSS 告警阈值 (默认 Xmx*2，这里假设 Xmx=4g，阈值=8g)
    ALERT_THRESHOLD_MB=${ALERT_THRESHOLD_MB:-8192}
    if [ "$RSS_MB" -gt "$ALERT_THRESHOLD_MB" ] 2>/dev/null; then
        echo "  ⚠️  ALERT: RSS ${RSS_MB}MB 超过阈值 ${ALERT_THRESHOLD_MB}MB! 可能存在堆外内存泄漏!"
        echo "  建议立即执行: jcmd $NM_PID VM.native_memory summary"
    fi
    
    # FD 告警阈值
    FD_ALERT=${FD_ALERT:-10000}
    if [ "$FD_COUNT" -gt "$FD_ALERT" ] 2>/dev/null; then
        echo "  ⚠️  ALERT: 文件描述符 ${FD_COUNT} 超过阈值 ${FD_ALERT}! 可能存在 FadvisedFileRegion 泄漏!"
    fi
    
    i=$((i + 1))
    sleep "$INTERVAL"
done

echo ""
echo "监控结束。数据已保存到: $LOG_FILE"
echo ""
echo "分析建议:"
echo "  1. 检查 RSS 增长趋势: awk -F',' '{print \$1,\$2}' $LOG_FILE"
echo "  2. 检查线程数趋势:    awk -F',' '{print \$1,\$4}' $LOG_FILE"
echo "  3. 检查 FD 数趋势:    awk -F',' '{print \$1,\$5}' $LOG_FILE"
echo "  4. 对比正常节点和异常节点的 CSV 数据差异"
