#!/bin/bash
# ============================================================
# NodeManager NMT (Native Memory Tracking) 快照对比脚本
#
# 前提: NM 需要添加 JVM 参数 -XX:NativeMemoryTracking=detail
#
# 用法:
#   ./nmt-diff-nm.sh baseline    # 建立基线
#   ./nmt-diff-nm.sh diff        # 与基线对比
#   ./nmt-diff-nm.sh summary     # 查看当前摘要
#   ./nmt-diff-nm.sh auto [间隔秒数] [次数]  # 自动定期快照对比
#   ./nmt-diff-nm.sh check       # 检查 NMT 是否启用
# ============================================================

ACTION=${1:-summary}

NM_PID=$(pgrep -f "org.apache.hadoop.yarn.server.nodemanager.NodeManager" | head -1)

if [ -z "$NM_PID" ]; then
    NM_PID=$(pgrep -f "NodeManager" | head -1)
fi

if [ -z "$NM_PID" ]; then
    echo "ERROR: NodeManager 进程未找到"
    echo "请确认 NodeManager 是否在运行:"
    echo "  ps -ef | grep NodeManager"
    exit 1
fi

echo "NodeManager PID: $NM_PID"

# 检查 NMT 是否启用
NMT_CHECK=$(jcmd "$NM_PID" VM.native_memory summary 2>&1)
if echo "$NMT_CHECK" | grep -q "Native memory tracking is not enabled"; then
    echo "ERROR: NMT 未启用！请在 NM JVM 参数中添加:"
    echo ""
    echo "  在 yarn-env.sh 中添加:"
    echo "  export YARN_NODEMANAGER_OPTS=\"\$YARN_NODEMANAGER_OPTS -XX:NativeMemoryTracking=detail\""
    echo ""
    echo "  然后重启 NodeManager"
    exit 1
fi

OUTPUT_DIR="nmt-nm-snapshots"
mkdir -p "$OUTPUT_DIR"

case "$ACTION" in
    check)
        echo "NMT 已启用。当前摘要:"
        echo "=========================================="
        jcmd "$NM_PID" VM.native_memory summary
        ;;
    
    baseline)
        echo "正在建立 NMT 基线..."
        jcmd "$NM_PID" VM.native_memory baseline
        echo "基线已建立。"
        
        # 同时保存一份 detail 快照
        SNAP_FILE="$OUTPUT_DIR/baseline-$(date +%Y%m%d_%H%M%S).txt"
        jcmd "$NM_PID" VM.native_memory detail > "$SNAP_FILE"
        echo "基线快照已保存到: $SNAP_FILE"
        
        # 同时记录当前进程状态
        STATUS_FILE="$OUTPUT_DIR/baseline-status-$(date +%Y%m%d_%H%M%S).txt"
        {
            echo "=== NM 进程状态 ==="
            echo "PID: $NM_PID"
            echo "Time: $(date)"
            echo ""
            echo "=== RSS/VSZ ==="
            ps -p "$NM_PID" -o pid,rss,vsz --no-headers | awk '{printf "PID=%s RSS=%sMB VSZ=%sMB\n", $1, $2/1024, $3/1024}'
            echo ""
            echo "=== 线程数 ==="
            ls /proc/"$NM_PID"/task 2>/dev/null | wc -l
            echo ""
            echo "=== FD 数 ==="
            ls /proc/"$NM_PID"/fd 2>/dev/null | wc -l
            echo ""
            echo "=== MALLOC_ARENA_MAX ==="
            cat /proc/"$NM_PID"/environ 2>/dev/null | tr '\0' '\n' | grep MALLOC_ARENA_MAX || echo "未设置"
            echo ""
            echo "=== smaps 摘要 ==="
            cat /proc/"$NM_PID"/status 2>/dev/null | grep -E "VmRSS|VmSize|VmPeak|RssAnon|RssFile|RssShmem|Threads"
        } > "$STATUS_FILE"
        echo "进程状态已保存到: $STATUS_FILE"
        ;;
    
    diff)
        echo "正在与基线对比..."
        DIFF_FILE="$OUTPUT_DIR/diff-$(date +%Y%m%d_%H%M%S).txt"
        jcmd "$NM_PID" VM.native_memory detail.diff > "$DIFF_FILE"
        
        echo "=========================================="
        echo "NMT 差异摘要 (NodeManager)"
        echo "=========================================="
        
        # 提取 Total 行
        echo ""
        echo "【总体变化】"
        grep "Total:" "$DIFF_FILE" | head -1
        
        # 提取关键增长区域
        echo ""
        echo "【内存增长区域（按增量排序）】"
        grep -E "^\-\s+.*\+[0-9]+" "$DIFF_FILE" | sort -t'+' -k2 -rn | head -20
        
        # 特别关注的区域
        echo ""
        echo "【重点关注区域】"
        echo "--- Internal (含 Netty ByteBuf/DirectByteBuffer) ---"
        grep -A2 "Internal" "$DIFF_FILE" | head -3
        echo "--- Thread (线程栈) ---"
        grep -A2 "Thread" "$DIFF_FILE" | head -3
        echo "--- Other (含 JNI/Deflater/Inflater) ---"
        grep -A2 "Other" "$DIFF_FILE" | head -3
        
        echo ""
        echo "完整差异已保存到: $DIFF_FILE"
        
        # 告警：检查是否有异常增长
        TOTAL_GROWTH=$(grep "Total:" "$DIFF_FILE" | grep -oP '\+\K[0-9]+' | head -1)
        if [ -n "$TOTAL_GROWTH" ] && [ "$TOTAL_GROWTH" -gt 536870912 ]; then  # 512MB
            GROWTH_MB=$((TOTAL_GROWTH / 1048576))
            echo ""
            echo "⚠️  ALERT: 自基线以来 native memory 增长 ${GROWTH_MB}MB，可能存在泄漏！"
            echo ""
            echo "建议排查:"
            echo "  1. Internal 增长 → 可能是 Netty ByteBuf 泄漏 (NML-001/002)"
            echo "  2. Other 增长   → 可能是 Deflater/Inflater JNI 泄漏 (NML-003)"
            echo "  3. Thread 增长  → 可能是线程池泄漏 (NML-009)"
        fi
        ;;
    
    summary)
        echo "NodeManager (PID: $NM_PID) NMT 摘要:"
        echo "=========================================="
        jcmd "$NM_PID" VM.native_memory summary
        
        echo ""
        echo "=========================================="
        echo "进程状态:"
        ps -p "$NM_PID" -o pid,rss,vsz --no-headers | awk '{printf "PID=%s RSS=%sMB VSZ=%sMB\n", $1, $2/1024, $3/1024}'
        echo "线程数: $(ls /proc/"$NM_PID"/task 2>/dev/null | wc -l)"
        echo "FD 数: $(ls /proc/"$NM_PID"/fd 2>/dev/null | wc -l)"
        ;;
    
    auto)
        INTERVAL=${2:-300}  # 默认5分钟
        COUNT=${3:-0}       # 默认无限
        
        echo "自动 NMT 快照模式 (NodeManager)"
        echo "间隔: ${INTERVAL}s  次数: $([ $COUNT -eq 0 ] && echo '无限' || echo $COUNT)"
        echo ""
        
        # 先建立基线
        jcmd "$NM_PID" VM.native_memory baseline
        echo "基线已建立"
        
        # 记录初始 RSS
        INIT_RSS=$(ps -p "$NM_PID" -o rss= 2>/dev/null | awk '{print $1/1024}')
        echo "初始 RSS: ${INIT_RSS}MB"
        echo ""
        
        # CSV 输出
        AUTO_LOG="$OUTPUT_DIR/auto-trend-$(date +%Y%m%d_%H%M%S).csv"
        echo "timestamp,rss_mb,nmt_total_committed,nmt_total_reserved,threads,fds" > "$AUTO_LOG"
        
        printf "%-20s %10s %15s %15s %8s %8s\n" "时间" "RSS(MB)" "NMT Committed" "NMT Reserved" "线程" "FD"
        echo "-------------------- ---------- --------------- --------------- -------- --------"
        
        i=0
        while [ $COUNT -eq 0 ] || [ $i -lt $COUNT ]; do
            sleep "$INTERVAL"
            
            if ! kill -0 "$NM_PID" 2>/dev/null; then
                echo "WARN: NodeManager 进程已退出!"
                break
            fi
            
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            SNAP_FILE="$OUTPUT_DIR/auto-$(date +%Y%m%d_%H%M%S).txt"
            
            # NMT diff
            jcmd "$NM_PID" VM.native_memory detail.diff > "$SNAP_FILE"
            
            # 提取 Total 行
            TOTAL_LINE=$(grep "Total:" "$SNAP_FILE" | head -1)
            
            # RSS
            CURR_RSS=$(ps -p "$NM_PID" -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
            
            # NMT committed/reserved
            NMT_COMMITTED=$(echo "$TOTAL_LINE" | grep -oP 'committed=\K[0-9]+' | head -1 | awk '{printf "%.0f", $1/1048576}')
            NMT_RESERVED=$(echo "$TOTAL_LINE" | grep -oP 'reserved=\K[0-9]+' | head -1 | awk '{printf "%.0f", $1/1048576}')
            
            # 线程和 FD
            THREADS=$(ls /proc/"$NM_PID"/task 2>/dev/null | wc -l)
            FDS=$(ls /proc/"$NM_PID"/fd 2>/dev/null | wc -l)
            
            printf "%-20s %10s %15s %15s %8s %8s\n" \
                "$TIMESTAMP" "${CURR_RSS:-N/A}MB" "${NMT_COMMITTED:-N/A}MB" "${NMT_RESERVED:-N/A}MB" "$THREADS" "$FDS"
            
            echo "$TIMESTAMP,${CURR_RSS:-0},${NMT_COMMITTED:-0},${NMT_RESERVED:-0},$THREADS,$FDS" >> "$AUTO_LOG"
            
            i=$((i + 1))
        done
        
        echo ""
        echo "自动快照结束。趋势数据: $AUTO_LOG"
        echo "快照文件: $OUTPUT_DIR/auto-*.txt"
        ;;
    
    *)
        echo "用法: $0 {baseline|diff|summary|auto [间隔] [次数]|check}"
        echo ""
        echo "  check    检查 NMT 是否启用"
        echo "  baseline 建立 NMT 基线"
        echo "  diff     与基线对比差异"
        echo "  summary  查看当前 NMT 摘要"
        echo "  auto     自动定期快照对比 (默认 5 分钟间隔)"
        exit 1
        ;;
esac
