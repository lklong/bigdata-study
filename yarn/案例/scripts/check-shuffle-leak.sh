#!/bin/bash
# ============================================================
# ShuffleHandler Netty ByteBuf 泄漏专项检测脚本
#
# 检测 NM 内置 ShuffleHandler 是否存在 Netty ByteBuf 泄漏
# 通过以下维度判断:
#   1. ShuffleHandler 端口活跃连接数
#   2. NM 日志中的 ByteBuf LEAK 警告
#   3. DirectByteBuffer 使用趋势
#   4. 文件描述符使用趋势（FadvisedFileRegion 泄漏指标）
#
# 用法: ./check-shuffle-leak.sh [持续采样秒数]
# 示例: ./check-shuffle-leak.sh 3600  # 持续检测 1 小时
# ============================================================

DURATION=${1:-0}  # 0 = 单次检测

NM_PID=$(pgrep -f "org.apache.hadoop.yarn.server.nodemanager.NodeManager" | head -1)
if [ -z "$NM_PID" ]; then
    NM_PID=$(pgrep -f "NodeManager" | head -1)
fi

if [ -z "$NM_PID" ]; then
    echo "ERROR: NodeManager 进程未找到"
    exit 1
fi

echo "============================================================"
echo "ShuffleHandler Netty ByteBuf 泄漏专项检测"
echo "NodeManager PID: $NM_PID"
echo "============================================================"
echo ""

# ---- 检测 ShuffleHandler 端口 ----
# 从配置文件获取 ShuffleHandler 端口
SHUFFLE_PORT=""
for CONF_DIR in /etc/hadoop/conf /etc/hadoop /opt/hadoop/etc/hadoop $HADOOP_HOME/etc/hadoop; do
    if [ -f "$CONF_DIR/yarn-site.xml" ]; then
        SHUFFLE_PORT=$(grep -A1 "mapreduce.shuffle.port" "$CONF_DIR/yarn-site.xml" 2>/dev/null | grep -oP '>\K[0-9]+' | head -1)
        break
    fi
done
SHUFFLE_PORT=${SHUFFLE_PORT:-13562}
echo "ShuffleHandler 端口: $SHUFFLE_PORT"

# ---- NM 日志路径 ----
NM_LOG_DIR=""
for LOG_DIR in /var/log/hadoop-yarn /var/log/hadoop /opt/hadoop/logs $HADOOP_HOME/logs; do
    if ls "$LOG_DIR"/yarn-*-nodemanager*.log 2>/dev/null | head -1 > /dev/null; then
        NM_LOG_DIR="$LOG_DIR"
        break
    fi
done

echo "NM 日志目录: ${NM_LOG_DIR:-未找到}"
echo ""

# ============================================================
# 检测函数
# ============================================================

check_once() {
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] === 开始检测 ==="
    
    # 1. ShuffleHandler 连接数
    echo ""
    echo "--- 1. ShuffleHandler 连接统计 ---"
    SHUFFLE_ESTABLISHED=$(ss -tnp 2>/dev/null | grep ":${SHUFFLE_PORT}" | grep ESTAB | wc -l)
    SHUFFLE_TIMEWAIT=$(ss -tn 2>/dev/null | grep ":${SHUFFLE_PORT}" | grep TIME-WAIT | wc -l)
    SHUFFLE_CLOSEWAIT=$(ss -tn 2>/dev/null | grep ":${SHUFFLE_PORT}" | grep CLOSE-WAIT | wc -l)
    echo "  ESTABLISHED: $SHUFFLE_ESTABLISHED"
    echo "  TIME_WAIT:   $SHUFFLE_TIMEWAIT"
    echo "  CLOSE_WAIT:  $SHUFFLE_CLOSEWAIT"
    
    if [ "$SHUFFLE_CLOSEWAIT" -gt 50 ] 2>/dev/null; then
        echo "  ⚠️  CLOSE_WAIT 连接数过多！可能有连接资源未释放"
    fi
    
    # 2. Netty ByteBuf 泄漏日志检测
    echo ""
    echo "--- 2. Netty ByteBuf 泄漏日志检测 ---"
    if [ -n "$NM_LOG_DIR" ]; then
        LEAK_COUNT=$(grep -c "LEAK.*ByteBuf" "$NM_LOG_DIR"/yarn-*-nodemanager*.log 2>/dev/null || echo "0")
        echo "  ByteBuf LEAK 日志条数: $LEAK_COUNT"
        
        if [ "$LEAK_COUNT" -gt 0 ]; then
            echo "  ⚠️  发现 ByteBuf 泄漏日志！最近 5 条:"
            grep "LEAK.*ByteBuf" "$NM_LOG_DIR"/yarn-*-nodemanager*.log 2>/dev/null | tail -5
        fi
        
        # 检查 ShuffleHandler 异常日志
        SHUFFLE_ERROR_COUNT=$(grep -c "ShuffleHandler.*error\|ShuffleHandler.*exception\|sendError\|shuffle.*failed" \
            "$NM_LOG_DIR"/yarn-*-nodemanager*.log 2>/dev/null || echo "0")
        echo "  ShuffleHandler 错误日志条数: $SHUFFLE_ERROR_COUNT"
        
        if [ "$SHUFFLE_ERROR_COUNT" -gt 100 ]; then
            echo "  ⚠️  ShuffleHandler 错误频繁！这是 ByteBuf 泄漏的触发条件"
            echo "  最近 3 条错误:"
            grep -i "ShuffleHandler.*error\|ShuffleHandler.*exception\|sendError\|shuffle.*failed" \
                "$NM_LOG_DIR"/yarn-*-nodemanager*.log 2>/dev/null | tail -3
        fi
    else
        echo "  未找到 NM 日志目录，跳过日志检测"
    fi
    
    # 3. DirectByteBuffer 统计
    echo ""
    echo "--- 3. DirectByteBuffer / MappedByteBuffer 统计 ---"
    JCMD_INFO=$(jcmd "$NM_PID" VM.info 2>/dev/null)
    if [ -n "$JCMD_INFO" ]; then
        echo "$JCMD_INFO" | grep -A5 "Direct buffer\|Mapped buffer" | head -12
    else
        echo "  jcmd 执行失败（可能无权限或 JDK 不支持）"
    fi
    
    # 通过 jmap 检查 DirectByteBuffer 对象数
    echo ""
    DIRECT_OBJECTS=$(jmap -histo:live "$NM_PID" 2>/dev/null | grep "DirectByteBuffer\b" | head -3)
    if [ -n "$DIRECT_OBJECTS" ]; then
        echo "  DirectByteBuffer 对象统计:"
        echo "  $DIRECT_OBJECTS"
    fi
    
    # 4. 文件描述符统计
    echo ""
    echo "--- 4. 文件描述符统计 ---"
    TOTAL_FD=$(ls /proc/"$NM_PID"/fd 2>/dev/null | wc -l)
    SOCKET_FD=$(ls -l /proc/"$NM_PID"/fd 2>/dev/null | grep socket | wc -l)
    PIPE_FD=$(ls -l /proc/"$NM_PID"/fd 2>/dev/null | grep pipe | wc -l)
    FILE_FD=$((TOTAL_FD - SOCKET_FD - PIPE_FD))
    echo "  总 FD: $TOTAL_FD  (socket: $SOCKET_FD, pipe: $PIPE_FD, file: $FILE_FD)"
    
    FD_LIMIT=$(cat /proc/"$NM_PID"/limits 2>/dev/null | grep "Max open files" | awk '{print $4}')
    FD_USAGE_PCT=$(echo "scale=1; $TOTAL_FD * 100 / ${FD_LIMIT:-65536}" | bc 2>/dev/null || echo "N/A")
    echo "  FD 使用率: ${FD_USAGE_PCT}% (上限: ${FD_LIMIT:-65536})"
    
    if [ "$TOTAL_FD" -gt 10000 ] 2>/dev/null; then
        echo "  ⚠️  文件描述符数过多！可能存在 FadvisedFileRegion 泄漏 (NML-002)"
    fi
    
    # 5. RSS vs Xmx 对比
    echo ""
    echo "--- 5. 内存概览 ---"
    RSS_MB=$(ps -p "$NM_PID" -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
    VSZ_MB=$(ps -p "$NM_PID" -o vsz= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
    XMX=$(ps -p "$NM_PID" -o args= 2>/dev/null | grep -oP '\-Xmx\K[0-9]+[mgMG]' | head -1)
    
    echo "  RSS: ${RSS_MB}MB  VSZ: ${VSZ_MB}MB  Xmx: ${XMX:-未知}"
    
    # 解析 Xmx 为 MB
    XMX_MB=""
    if echo "$XMX" | grep -qiP '[0-9]+g'; then
        XMX_MB=$(echo "$XMX" | grep -oP '[0-9]+' | awk '{print $1*1024}')
    elif echo "$XMX" | grep -qiP '[0-9]+m'; then
        XMX_MB=$(echo "$XMX" | grep -oP '[0-9]+')
    fi
    
    if [ -n "$XMX_MB" ] && [ "$RSS_MB" -gt $((XMX_MB * 2)) ] 2>/dev/null; then
        echo "  🔴 RSS 是 Xmx 的 $(echo "scale=1; $RSS_MB / $XMX_MB" | bc)x 倍！存在严重堆外内存泄漏!"
    elif [ -n "$XMX_MB" ] && [ "$RSS_MB" -gt $((XMX_MB * 3 / 2)) ] 2>/dev/null; then
        echo "  ⚠️  RSS 是 Xmx 的 $(echo "scale=1; $RSS_MB / $XMX_MB" | bc)x 倍，可能存在堆外内存泄漏"
    fi
    
    # 6. 综合诊断
    echo ""
    echo "--- 6. 综合诊断 ---"
    ISSUES=0
    
    if [ "$SHUFFLE_CLOSEWAIT" -gt 50 ] 2>/dev/null; then
        echo "  [HIGH] ShuffleHandler CLOSE_WAIT 连接堆积 → 可能触发 ByteBuf 泄漏 (NML-001)"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ "$LEAK_COUNT" -gt 0 ] 2>/dev/null; then
        echo "  [HIGH] 发现 Netty ByteBuf LEAK 日志 → 确认存在 ByteBuf 泄漏 (NML-001/002)"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ "$SHUFFLE_ERROR_COUNT" -gt 100 ] 2>/dev/null; then
        echo "  [HIGH] ShuffleHandler 错误频繁 → 大量 sendError() 调用可能触发 ByteBuf 泄漏 (NML-001)"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ "$TOTAL_FD" -gt 10000 ] 2>/dev/null; then
        echo "  [MEDIUM] 文件描述符过多 → 可能存在 FadvisedFileRegion 泄漏 (NML-002)"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ -n "$XMX_MB" ] && [ "$RSS_MB" -gt $((XMX_MB * 2)) ] 2>/dev/null; then
        echo "  [HIGH] RSS 远超 Xmx → 确认存在堆外内存泄漏"
        ISSUES=$((ISSUES + 1))
    fi
    
    ARENA_MAX=$(cat /proc/"$NM_PID"/environ 2>/dev/null | tr '\0' '\n' | grep MALLOC_ARENA_MAX | cut -d= -f2)
    if [ -z "$ARENA_MAX" ] || [ "$ARENA_MAX" -gt 4 ] 2>/dev/null; then
        echo "  [MEDIUM] MALLOC_ARENA_MAX 未设置或过大 → RSS 可能因 arena 碎片化虚高 (NML-004)"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ $ISSUES -eq 0 ]; then
        echo "  ✅ 未发现明显 ShuffleHandler 泄漏迹象"
    else
        echo ""
        echo "  发现 $ISSUES 个潜在问题，建议："
        echo "  1. 立即设置 MALLOC_ARENA_MAX=4 并重启 NM"
        echo "  2. 应用 ShuffleHandler ByteBuf 释放 Patch (参见 patches/recommended-fixes.md)"
        echo "  3. 使用 monitor-nm-offheap.sh 持续监控 RSS 趋势"
        echo "  4. 使用 nmt-diff-nm.sh 对比 NMT 基线"
    fi
    
    echo ""
}

# ============================================================
# 主逻辑
# ============================================================

if [ "$DURATION" -eq 0 ] 2>/dev/null || [ "$DURATION" = "0" ]; then
    # 单次检测
    check_once
else
    # 持续检测
    echo "持续检测模式: ${DURATION}s (每 60s 检测一次)"
    echo ""
    
    END_TIME=$(($(date +%s) + DURATION))
    while [ $(date +%s) -lt $END_TIME ]; do
        check_once
        echo ""
        echo "==== 等待 60s 后再次检测 ===="
        echo ""
        sleep 60
    done
    
    echo "检测结束。"
fi
