#!/usr/bin/env bash
# kerb-log-grep.sh — Kerberos 相关日志一键聚合分析
# 在大数据节点跑，自动从所有 Hadoop 服务日志中提取 Kerberos 相关错误
# Usage: bash kerb-log-grep.sh [--last-hours N]

set -uo pipefail

LAST_HOURS="${1:-24}"
TS=$(date +%Y%m%d_%H%M%S)
OUT="/tmp/kerb_log_${TS}.txt"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'

# Hadoop 日志目录候选
LOG_DIRS=(
    "/var/log/hadoop-hdfs"
    "/var/log/hadoop-yarn"
    "/var/log/hive"
    "/var/log/hbase"
    "/var/log/spark"
    "/var/log/kafka"
    "/var/log/zookeeper"
    "/var/log/kyuubi"
    "/var/log/ranger"
    "/var/log/krb5kdc.log"
    "/var/log/kadmin.log"
    "/var/log/krb5libs.log"
)

# Kerberos 错误关键字（按严重性排序）
PATTERNS=(
    "GSSException"
    "KrbException"
    "javax.security.auth.login.LoginException"
    "Failed to find any Kerberos tgt"
    "No valid credentials provided"
    "Clock skew"
    "Ticket expired"
    "Pre-authentication failed"
    "Specified version of key"
    "Decrypt integrity check failed"
    "Server not found in Kerberos database"
    "Client not found in Kerberos database"
    "Cannot find KDC"
    "Cannot contact any KDC"
    "Encryption type.*not supported"
    "Defective token"
    "SaslException"
    "Cannot authenticate via"
    "InvalidToken"
    "token.*expired"
    "PREAUTH_FAILED"
    "UNKNOWN_SERVER"
    "TKT_EXPIRED"
    "auth_to_local"
    "AccessControlException.*kerberos"
)

PATTERN_REGEX=$(IFS='|'; echo "${PATTERNS[*]}")

echo "===== Kerberos 日志分析 ($(date)) =====" | tee $OUT
echo "时间窗口: 最近 $LAST_HOURS 小时" | tee -a $OUT
echo "" | tee -a $OUT

# 总命中数
TOTAL=0
declare -A PATTERN_COUNT

for d in "${LOG_DIRS[@]}"; do
    [[ ! -e "$d" ]] && continue
    
    if [[ -f "$d" ]]; then
        FILES=("$d")
    else
        FILES=($(find "$d" -name "*.log" -mtime -1 2>/dev/null | head -50))
    fi
    
    [[ ${#FILES[@]} -eq 0 ]] && continue
    
    echo -e "${BLU}>> $d${NC}" | tee -a $OUT
    
    for f in "${FILES[@]}"; do
        # 仅最近 N 小时
        if [[ $(stat -c %Y $f 2>/dev/null) -lt $(($(date +%s) - LAST_HOURS * 3600)) ]]; then
            continue
        fi
        
        HITS=$(grep -E "$PATTERN_REGEX" "$f" 2>/dev/null | wc -l)
        if [[ $HITS -gt 0 ]]; then
            echo "  $(basename $f): $HITS 条命中" | tee -a $OUT
            TOTAL=$((TOTAL + HITS))
            
            # 各模式计数
            for p in "${PATTERNS[@]}"; do
                CNT=$(grep -cE "$p" "$f" 2>/dev/null || echo 0)
                PATTERN_COUNT[$p]=$((${PATTERN_COUNT[$p]:-0} + CNT))
            done
        fi
    done
    echo "" | tee -a $OUT
done

# 总结
echo "" | tee -a $OUT
echo -e "${BLU}===== 命中模式 TOP =====${NC}" | tee -a $OUT
for p in "${PATTERNS[@]}"; do
    cnt=${PATTERN_COUNT[$p]:-0}
    [[ $cnt -gt 0 ]] && printf "  %5d  %s\n" $cnt "$p" | tee -a $OUT
done | sort -rn

echo "" | tee -a $OUT
echo "总命中: $TOTAL" | tee -a $OUT

# 错误样本（最近 5 条）
echo "" | tee -a $OUT
echo -e "${BLU}===== 最近错误样本 =====${NC}" | tee -a $OUT
for d in "${LOG_DIRS[@]}"; do
    [[ ! -e "$d" ]] && continue
    if [[ -f "$d" ]]; then
        FILES=("$d")
    else
        FILES=($(find "$d" -name "*.log" -mtime -1 2>/dev/null))
    fi
    
    for f in "${FILES[@]}"; do
        SAMPLES=$(grep -E "$PATTERN_REGEX" "$f" 2>/dev/null | tail -3)
        if [[ -n "$SAMPLES" ]]; then
            echo "" | tee -a $OUT
            echo "[$f]" | tee -a $OUT
            echo "$SAMPLES" | tee -a $OUT
        fi
    done
done

echo "" | tee -a $OUT
echo "完整报告: $OUT"

# 给出修复建议
echo "" | tee -a $OUT
echo -e "${BLU}===== 智能建议 =====${NC}" | tee -a $OUT

[[ ${PATTERN_COUNT[Clock skew]:-0} -gt 0 ]]                && echo -e "${YEL}⚠️  时钟问题 → chronyc -a makestep${NC}"
[[ ${PATTERN_COUNT[Specified version of key]:-0} -gt 0 ]]  && echo -e "${YEL}⚠️  KVNO 不一致 → bash kvno-fixer.sh${NC}"
[[ ${PATTERN_COUNT[Server not found in Kerberos database]:-0} -gt 0 ]] && echo -e "${YEL}⚠️  SPN 不存在 → 检查 hostname -f 与 KDC listprincs${NC}"
[[ ${PATTERN_COUNT[token.*expired]:-0} -gt 0 ]]            && echo -e "${YEL}⚠️  长任务 token 过期 → 强制 --keytab${NC}"
[[ ${PATTERN_COUNT[Cannot contact any KDC]:-0} -gt 0 ]]    && echo -e "${YEL}⚠️  KDC 不可达 → 检查 KDC 进程/网络${NC}"
[[ ${PATTERN_COUNT[Pre-authentication failed]:-0} -gt 0 ]] && echo -e "${YEL}⚠️  预认证失败 → 密码/keytab 错${NC}"

if [[ $TOTAL -eq 0 ]]; then
    echo -e "${GRN}✅ 没发现 Kerberos 错误${NC}"
fi
