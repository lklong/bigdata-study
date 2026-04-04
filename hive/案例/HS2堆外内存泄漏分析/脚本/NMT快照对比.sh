#!/bin/bash
# ============================================================
# HiveServer2 NMT (Native Memory Tracking) 快照对比脚本
# 
# 前提: HS2 需要添加 JVM 参数 -XX:NativeMemoryTracking=detail
#
# 用法:
#   ./nmt-diff.sh baseline    # 建立基线
#   ./nmt-diff.sh diff        # 与基线对比
#   ./nmt-diff.sh summary     # 查看当前摘要
#   ./nmt-diff.sh auto [间隔秒数] [次数]  # 自动定期快照对比
# ============================================================

ACTION=${1:-summary}
HS2_PID=$(pgrep -f "HiveServer2" | head -1)

if [ -z "$HS2_PID" ]; then
    echo "ERROR: HiveServer2 进程未找到"
    exit 1
fi

# 检查 NMT 是否启用
NMT_CHECK=$(jcmd "$HS2_PID" VM.native_memory summary 2>&1)
if echo "$NMT_CHECK" | grep -q "Native memory tracking is not enabled"; then
    echo "ERROR: NMT 未启用！请在 HS2 JVM 参数中添加:"
    echo "  -XX:NativeMemoryTracking=detail"
    echo "然后重启 HS2"
    exit 1
fi

OUTPUT_DIR="nmt-snapshots"
mkdir -p "$OUTPUT_DIR"

case "$ACTION" in
    baseline)
        echo "正在建立 NMT 基线..."
        jcmd "$HS2_PID" VM.native_memory baseline
        echo "基线已建立。"
        
        # 同时保存一份 summary 快照
        SNAP_FILE="$OUTPUT_DIR/baseline-$(date +%Y%m%d_%H%M%S).txt"
        jcmd "$HS2_PID" VM.native_memory detail > "$SNAP_FILE"
        echo "基线快照已保存到: $SNAP_FILE"
        ;;
    
    diff)
        echo "正在与基线对比..."
        DIFF_FILE="$OUTPUT_DIR/diff-$(date +%Y%m%d_%H%M%S).txt"
        jcmd "$HS2_PID" VM.native_memory detail.diff > "$DIFF_FILE"
        
        echo "=========================================="
        echo "NMT 差异摘要"
        echo "=========================================="
        
        # 提取关键增长区域
        echo ""
        echo "【内存增长区域（按增量排序）】"
        grep -E "^\-\s+.*\+[0-9]+" "$DIFF_FILE" | sort -t'+' -k2 -rn | head -20
        
        echo ""
        echo "完整差异已保存到: $DIFF_FILE"
        
        # 告警：检查是否有异常增长
        TOTAL_GROWTH=$(grep "Total:" "$DIFF_FILE" | grep -oP '\+\K[0-9]+' | head -1)
        if [ -n "$TOTAL_GROWTH" ] && [ "$TOTAL_GROWTH" -gt 1073741824 ]; then
            GROWTH_GB=$((TOTAL_GROWTH / 1073741824))
            echo ""
            echo "⚠️  ALERT: 自基线以来总内存增长 ${GROWTH_GB}GB，可能存在泄漏！"
        fi
        ;;
    
    summary)
        echo "HiveServer2 (PID: $HS2_PID) NMT 摘要:"
        echo "=========================================="
        jcmd "$HS2_PID" VM.native_memory summary
        ;;
    
    auto)
        INTERVAL=${2:-300}  # 默认5分钟
        COUNT=${3:-0}       # 默认无限
        
        echo "自动 NMT 快照模式"
        echo "间隔: ${INTERVAL}s  次数: $([ $COUNT -eq 0 ] && echo '无限' || echo $COUNT)"
        echo ""
        
        # 先建立基线
        jcmd "$HS2_PID" VM.native_memory baseline
        echo "基线已建立"
        echo ""
        
        i=0
        while [ $COUNT -eq 0 ] || [ $i -lt $COUNT ]; do
            sleep "$INTERVAL"
            
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            SNAP_FILE="$OUTPUT_DIR/auto-$(date +%Y%m%d_%H%M%S).txt"
            
            jcmd "$HS2_PID" VM.native_memory detail.diff > "$SNAP_FILE"
            
            # 提取 Total 行
            TOTAL_LINE=$(grep "Total:" "$SNAP_FILE" | head -1)
            echo "[$TIMESTAMP] $TOTAL_LINE  → $SNAP_FILE"
            
            i=$((i + 1))
        done
        ;;
    
    *)
        echo "用法: $0 {baseline|diff|summary|auto [间隔] [次数]}"
        exit 1
        ;;
esac
