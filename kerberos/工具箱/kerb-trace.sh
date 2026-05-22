#!/usr/bin/env bash
# kerb-trace.sh — KRB5_TRACE 一键采集 + 智能分析
# Usage: bash kerb-trace.sh [-c "命令"] [-p principal] [-k keytab]
# 
# 例：bash kerb-trace.sh -c "hdfs dfs -ls /"
#     bash kerb-trace.sh -p alice@REALM
#     bash kerb-trace.sh -k /etc/security/keytabs/hdfs.service.keytab -p hdfs/host@REALM

set -uo pipefail

CMD=""
PRINCIPAL=""
KEYTAB=""
TRACE_LOG=$(mktemp -t kerb_trace_XXXXXX.log)
JAVA_LOG=$(mktemp -t java_krb_XXXXXX.log)

while getopts "c:p:k:h" opt; do
    case $opt in
        c) CMD=$OPTARG ;;
        p) PRINCIPAL=$OPTARG ;;
        k) KEYTAB=$OPTARG ;;
        h) echo "Usage: $0 [-c '命令'] [-p principal] [-k keytab]"; exit 0 ;;
    esac
done

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'

echo -e "${BLU}===== Kerberos Trace Collector =====${NC}"
echo "TRACE: $TRACE_LOG"
echo ""

# 模式 1: 直接 kinit 测试
if [[ -n "$PRINCIPAL" && -n "$KEYTAB" ]]; then
    echo -e "${BLU}>> 模式 1: kinit 测试${NC}"
    KRB5_TRACE=$TRACE_LOG kinit -V -kt $KEYTAB $PRINCIPAL 2>&1
elif [[ -n "$PRINCIPAL" ]]; then
    echo -e "${BLU}>> 模式 1: kinit 密码测试${NC}"
    KRB5_TRACE=$TRACE_LOG kinit -V $PRINCIPAL
fi

# 模式 2: 包装命令
if [[ -n "$CMD" ]]; then
    echo -e "${BLU}>> 模式 2: 包装命令 '$CMD'${NC}"
    
    # 如果是 Java 程序（hdfs/yarn/hive 等），同时开 JVM debug
    if echo "$CMD" | grep -qE "hdfs|yarn|hive|hbase|spark|kafka|impala|beeline"; then
        export HADOOP_OPTS="-Dsun.security.krb5.debug=true -Dsun.security.spnego.debug=true ${HADOOP_OPTS:-}"
        export HADOOP_CLIENT_OPTS="-Dsun.security.krb5.debug=true ${HADOOP_CLIENT_OPTS:-}"
    fi
    
    KRB5_TRACE=$TRACE_LOG bash -c "$CMD" 2>$JAVA_LOG
fi

# ===== 智能分析 =====
echo ""
echo -e "${BLU}===== 智能分析 =====${NC}"

# 1) 错误码识别
ERROR_CODE=$(grep -oP "Received error from KDC: \K-?\d+" $TRACE_LOG | head -1)
ERROR_MSG=$(grep "Received error" $TRACE_LOG | head -1)

if [[ -n "$ERROR_CODE" ]]; then
    echo -e "${RED}❌ 错误码: $ERROR_CODE${NC}"
    echo "$ERROR_MSG"
    echo ""
    
    case $ERROR_CODE in
        -1765328359) echo -e "${YEL}诊断: Clock skew - 时钟偏差${NC}"; echo "修复: chronyc -a makestep" ;;
        -1765328370) echo -e "${YEL}诊断: Cannot find KDC - krb5.conf 缺 realm${NC}"; echo "修复: 检查 /etc/krb5.conf [realms] 段" ;;
        -1765328351) echo -e "${YEL}诊断: Cannot contact KDC - 网络/进程${NC}"; echo "修复: nc -zv kdc 88; systemctl status krb5kdc" ;;
        -1765328378) echo -e "${YEL}诊断: Pre-auth failed - 密码/KVNO/enctype${NC}"; echo "修复: 核对密码或 ktadd -norandkey" ;;
        -1765328353) echo -e "${YEL}诊断: Server not found - SPN 不存在${NC}"; echo "修复: 检查 hostname -f 与 KDC listprincs" ;;
        -1765328377) echo -e "${YEL}诊断: Decrypt integrity check - 密钥不一致${NC}"; echo "修复: 单域重 ktadd / 跨域重置 krbtgt" ;;
        -1765328324) echo -e "${YEL}诊断: Ticket expired - TGT 过期${NC}"; echo "修复: kinit" ;;
        -1765328230) echo -e "${YEL}诊断: KVNO 不一致${NC}"; echo "修复: ktadd -norandkey" ;;
        -1765328383) echo -e "${YEL}诊断: Encryption type 不支持${NC}"; echo "修复: JCE 解锁" ;;
        -1765328369) echo -e "${YEL}诊断: KDC 不支持此 enctype${NC}"; echo "修复: krb5.conf permitted_enctypes 加 AES" ;;
        *) echo -e "${YEL}诊断: 未知错误码，查 08-错误码字典${NC}" ;;
    esac
fi

# 2) 关键事件提取
echo ""
echo -e "${BLU}--- 关键事件 ---${NC}"

# 请求
echo -e "${BLU}[请求]${NC}"
grep -E "Sending (initial|TCP|UDP)" $TRACE_LOG | head -5

# 响应
echo -e "${BLU}[响应]${NC}"
grep -E "Decoded AS-REP|Decoded TGS-REP|Received error" $TRACE_LOG | head -5

# enctype
echo -e "${BLU}[加密协商]${NC}"
grep -E "Selected etype|using etype|crypto:" $TRACE_LOG | head -5

# SPN 请求
echo -e "${BLU}[SPN 请求]${NC}"
grep -oP "TGS-REQ for \K[^ ]+" $TRACE_LOG | sort -u | head -10

# 3) Java 端关键日志（如果有）
if [[ -s $JAVA_LOG ]]; then
    echo ""
    echo -e "${BLU}--- Java 端关键日志 ---${NC}"
    grep -E "Krb5LoginModule|GSSException|KrbException|principal is|Found ticket|Default principal|Authentication failed" $JAVA_LOG | head -15
fi

# 4) 最终建议
echo ""
echo -e "${BLU}===== 文件 =====${NC}"
echo "TRACE 完整日志: $TRACE_LOG"
[[ -s $JAVA_LOG ]] && echo "Java 日志:      $JAVA_LOG"
echo ""
echo -e "${GRN}建议下一步：${NC}"
if [[ -n "$ERROR_CODE" ]]; then
    echo "1. 查阅 08-Kerberos错误码全字典.md 错误码 $ERROR_CODE"
    echo "2. 查阅 09-Kerberos5分钟根因定位手册.md"
fi
echo "3. 复制 $TRACE_LOG 内容贴给 Eric 升级分析"
