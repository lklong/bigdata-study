#!/bin/bash
# ============================================================
# Kyuubi 一键诊断脚本
#
# 功能：快速采集 Kyuubi Server / YARN / Spark Engine / ZK / HMS 的
#       诊断信息，输出结构化的诊断摘要
#
# 用法：
#   ./diagnose-kyuubi.sh                   # 输出到控制台
#   ./diagnose-kyuubi.sh -o /tmp/diag      # 输出到指定目录
# ============================================================

set -euo pipefail

# ===== 配置 =====
OUTPUT_DIR=""
KYUUBI_HOME="${KYUUBI_HOME:-/opt/kyuubi}"
MATCH_PATTERNS="kyuubi|KyuubiSQLEngine|Kyuubi"

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --kyuubi-home)
            KYUUBI_HOME="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [-o <输出目录>] [--kyuubi-home <路径>]"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# 创建输出目录
if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REPORT_FILE="$OUTPUT_DIR/kyuubi-diag-${TIMESTAMP}.txt"
    exec > >(tee "$REPORT_FILE") 2>&1
fi

TS=$(date '+%Y-%m-%d %H:%M:%S')

echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Kyuubi 一键诊断报告                              ║"
echo "║         时间: $TS                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ============================================================
# 1. 系统信息
# ============================================================
echo "▶ [1/7] 系统信息"
echo "======================================================"
echo "主机名:    $(hostname)"
echo "系统:      $(uname -srm)"
echo "负载:      $(uptime)"
echo "内存:      $(free -h 2>/dev/null | grep Mem || echo 'N/A')"
echo "磁盘:      $(df -h / 2>/dev/null | tail -1 || echo 'N/A')"
echo ""

# ============================================================
# 2. Kyuubi Server 状态
# ============================================================
echo "▶ [2/7] Kyuubi Server 状态"
echo "======================================================"

KYUUBI_PID=$(pgrep -f "org.apache.kyuubi" 2>/dev/null | head -1 || echo "")

if [ -n "$KYUUBI_PID" ]; then
    echo "状态:      RUNNING"
    echo "PID:       $KYUUBI_PID"

    # 进程信息
    RSS_KB=$(ps -p "$KYUUBI_PID" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
    RSS_MB=$((RSS_KB / 1024))
    VSZ_KB=$(ps -p "$KYUUBI_PID" -o vsz= 2>/dev/null | tr -d ' ' || echo "0")
    VSZ_MB=$((VSZ_KB / 1024))
    echo "RSS:       ${RSS_MB}MB"
    echo "VSZ:       ${VSZ_MB}MB"

    # 线程数
    THREAD_COUNT=$(ls /proc/"$KYUUBI_PID"/task 2>/dev/null | wc -l || echo "N/A")
    echo "线程数:    $THREAD_COUNT"

    # 运行时间
    ELAPSED=$(ps -p "$KYUUBI_PID" -o etime= 2>/dev/null | tr -d ' ' || echo "N/A")
    echo "运行时间:  $ELAPSED"

    # JVM GC 概况
    echo ""
    echo "JVM GC 概况:"
    jstat -gcutil "$KYUUBI_PID" 2>/dev/null | head -2 || echo "  jstat 不可用"

    # 最近日志错误
    echo ""
    echo "最近日志错误 (最后 20 条):"
    if [ -d "$KYUUBI_HOME/logs" ]; then
        grep -i "error\|exception\|fatal" "$KYUUBI_HOME"/logs/kyuubi-*.log 2>/dev/null \
            | tail -20 \
            | sed 's/^/  /' \
            || echo "  未发现错误日志"
    else
        echo "  日志目录 $KYUUBI_HOME/logs 不存在"
    fi
else
    echo "状态:      ⚠️  NOT RUNNING"
    echo "Kyuubi Server 进程未找到！"
fi
echo ""

# ============================================================
# 3. YARN 资源概况
# ============================================================
echo "▶ [3/7] YARN 资源概况"
echo "======================================================"

echo "YARN 集群状态:"
yarn node -list -all 2>/dev/null | head -5 || echo "  yarn 命令不可用"
echo ""

echo "YARN 队列状态:"
yarn queue -status default 2>/dev/null | head -20 || echo "  队列查询不可用"
echo ""

# ============================================================
# 4. Kyuubi Spark Application 概况
# ============================================================
echo "▶ [4/7] Kyuubi Spark Application 概况"
echo "======================================================"

for STATE in RUNNING ACCEPTED KILLED FAILED FINISHED; do
    COUNT=$(yarn application -list -appStates "$STATE" 2>/dev/null \
        | grep -icE "$MATCH_PATTERNS" || echo 0)
    printf "  %-12s: %d\n" "$STATE" "$COUNT"
done
echo ""

echo "RUNNING 的 Kyuubi 应用详情:"
yarn application -list -appStates RUNNING 2>/dev/null \
    | grep -iE "$MATCH_PATTERNS" \
    | head -30 \
    | sed 's/^/  /' \
    || echo "  无"
echo ""

echo "ACCEPTED 的 Kyuubi 应用（等待资源）:"
yarn application -list -appStates ACCEPTED 2>/dev/null \
    | grep -iE "$MATCH_PATTERNS" \
    | head -10 \
    | sed 's/^/  /' \
    || echo "  无"
echo ""

# ============================================================
# 5. ZooKeeper 引擎注册
# ============================================================
echo "▶ [5/7] ZooKeeper 引擎注册"
echo "======================================================"

# 尝试从 Kyuubi 配置中获取 ZK 信息
ZK_QUORUM=""
ZK_NAMESPACE=""
if [ -f "$KYUUBI_HOME/conf/kyuubi-defaults.conf" ]; then
    ZK_QUORUM=$(grep -i "kyuubi.ha.addresses\|kyuubi.zookeeper.quorum" "$KYUUBI_HOME/conf/kyuubi-defaults.conf" 2>/dev/null \
        | grep -v "^#" | head -1 | awk -F= '{print $2}' | tr -d ' ' || echo "")
    ZK_NAMESPACE=$(grep -i "kyuubi.ha.namespace\|kyuubi.zookeeper.namespace" "$KYUUBI_HOME/conf/kyuubi-defaults.conf" 2>/dev/null \
        | grep -v "^#" | head -1 | awk -F= '{print $2}' | tr -d ' ' || echo "kyuubi")
fi

if [ -n "$ZK_QUORUM" ]; then
    echo "ZK 地址: $ZK_QUORUM"
    echo "ZK 命名空间: $ZK_NAMESPACE"
    echo ""
    echo "ZK 中注册的引擎:"
    ZK_HOST=$(echo "$ZK_QUORUM" | cut -d, -f1)
    echo "ls /${ZK_NAMESPACE}" | zkCli.sh -server "$ZK_HOST" 2>/dev/null \
        | grep "^\[" | sed 's/^/  /' \
        || echo "  zkCli.sh 不可用或命名空间不存在"
else
    echo "未能从 $KYUUBI_HOME/conf/kyuubi-defaults.conf 获取 ZK 配置"
    echo "请手动检查: echo 'ls /kyuubi' | zkCli.sh -server <zk_host>:2181"
fi
echo ""

# ============================================================
# 6. Hive Metastore 状态
# ============================================================
echo "▶ [6/7] Hive Metastore 状态"
echo "======================================================"

HMS_PID=$(pgrep -f "HiveMetaStore\|metastore" 2>/dev/null | head -1 || echo "")
if [ -n "$HMS_PID" ]; then
    echo "HMS 状态:  RUNNING (PID: $HMS_PID)"
    HMS_RSS_KB=$(ps -p "$HMS_PID" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
    HMS_RSS_MB=$((HMS_RSS_KB / 1024))
    echo "HMS RSS:   ${HMS_RSS_MB}MB"
else
    echo "HMS 状态:  未在本机运行（可能部署在其他节点）"
fi
echo ""

# ============================================================
# 7. Kyuubi 配置摘要
# ============================================================
echo "▶ [7/7] Kyuubi 关键配置"
echo "======================================================"

CONF_FILE="$KYUUBI_HOME/conf/kyuubi-defaults.conf"
if [ -f "$CONF_FILE" ]; then
    echo "配置文件: $CONF_FILE"
    echo ""
    echo "关键参数:"
    for KEY in \
        "kyuubi.engine.share.level" \
        "kyuubi.engine.idle.timeout" \
        "kyuubi.session.idle.timeout" \
        "kyuubi.session.engine.initialize.timeout" \
        "kyuubi.session.check.interval" \
        "kyuubi.ha.addresses" \
        "kyuubi.frontend.thrift.binary.bind.port" \
        "spark.master" \
        "spark.submit.deployMode"; do
        VALUE=$(grep -i "^${KEY}" "$CONF_FILE" 2>/dev/null | head -1 || echo "")
        if [ -n "$VALUE" ]; then
            printf "  %-50s = %s\n" "$KEY" "$(echo "$VALUE" | awk -F= '{print $2}' | tr -d ' ')"
        else
            printf "  %-50s = %s\n" "$KEY" "(未配置 — 使用默认值)"
        fi
    done
else
    echo "配置文件 $CONF_FILE 不存在"
fi
echo ""

# ============================================================
# 诊断结论
# ============================================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    诊断摘要                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# 自动诊断
RUNNING_KYUUBI=$(yarn application -list -appStates RUNNING 2>/dev/null \
    | grep -icE "$MATCH_PATTERNS" || echo 0)
ACCEPTED_KYUUBI=$(yarn application -list -appStates ACCEPTED 2>/dev/null \
    | grep -icE "$MATCH_PATTERNS" || echo 0)

ISSUES_FOUND=0

if [ -z "$KYUUBI_PID" ]; then
    echo "❌ [CRITICAL] Kyuubi Server 进程未运行"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ "$RUNNING_KYUUBI" -gt 20 ]; then
    echo "⚠️  [WARNING] YARN 上有 ${RUNNING_KYUUBI} 个 Kyuubi 应用在运行，可能存在引擎泄漏"
    echo "   → 建议执行: cleanup-orphan-spark-apps.sh --execute --max-age 3600"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ "$ACCEPTED_KYUUBI" -gt 0 ]; then
    echo "⚠️  [WARNING] 有 ${ACCEPTED_KYUUBI} 个 Kyuubi 应用在等待资源（ACCEPTED）"
    echo "   → YARN 资源可能不足，可能是残留应用占满资源导致"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ "$ISSUES_FOUND" -eq 0 ]; then
    echo "✅ 未发现明显异常"
fi

echo ""
if [ -n "$OUTPUT_DIR" ]; then
    echo "完整诊断报告已保存到: $REPORT_FILE"
fi
