#!/usr/bin/env bash
# kerb-doctor.sh — Kerberos 综合体检脚本（一键诊断）
# Usage: bash kerb-doctor.sh [-p principal] [-k keytab] [-K kdc_host]
# Author: Eric · 大数据 SRE · 2026-05-10
#
# 输出：彩色终端报告 + /tmp/kerb_doctor_<ts>.log
# 退出码：0 全绿  1 有黄  2 有红

set -uo pipefail

# 颜色
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'

PRINCIPAL=""
KEYTAB=""
KDC_HOST=""
TS=$(date +%Y%m%d_%H%M%S)
LOG="/tmp/kerb_doctor_${TS}.log"
RED_COUNT=0
YEL_COUNT=0
GRN_COUNT=0

# 参数解析
while getopts "p:k:K:h" opt; do
    case $opt in
        p) PRINCIPAL=$OPTARG ;;
        k) KEYTAB=$OPTARG ;;
        K) KDC_HOST=$OPTARG ;;
        h) echo "Usage: $0 [-p principal] [-k keytab] [-K kdc_host]"; exit 0 ;;
    esac
done

# 自动探测 KDC
[[ -z "$KDC_HOST" ]] && KDC_HOST=$(awk '/^[[:space:]]*kdc[[:space:]]*=/{print $3; exit}' /etc/krb5.conf 2>/dev/null | cut -d: -f1)

ok()    { echo -e "${GRN}✅ $*${NC}" | tee -a $LOG; ((GRN_COUNT++)); }
warn()  { echo -e "${YEL}⚠️  $*${NC}" | tee -a $LOG; ((YEL_COUNT++)); }
fail()  { echo -e "${RED}❌ $*${NC}" | tee -a $LOG; ((RED_COUNT++)); }
info()  { echo -e "${BLU}ℹ️  $*${NC}" | tee -a $LOG; }
title() { echo -e "\n${BLU}===== $* =====${NC}" | tee -a $LOG; }

# ============ Step 1 基础环境 ============
title "Step 1 基础环境"
info "Hostname: $(hostname -f 2>/dev/null || hostname)"
info "User: $(id)"
info "Date: $(date)"
info "JAVA_HOME: ${JAVA_HOME:-<unset>}"
info "Log: $LOG"

if [[ "$(hostname -f 2>/dev/null)" == "$(hostname)" ]]; then
    warn "hostname -f 与 hostname 相同，可能不是 FQDN（影响 _HOST 替换）"
else
    ok "FQDN 配置正常"
fi

# ============ Step 2 时钟检查 ============
title "Step 2 时钟检查"
LOCAL_TS=$(date +%s)
info "本地时间: $(date)"
if [[ -n "$KDC_HOST" ]]; then
    KDC_TS=$(ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no $KDC_HOST "date +%s" 2>/dev/null || echo "")
    if [[ -n "$KDC_TS" ]]; then
        SKEW=$((LOCAL_TS - KDC_TS))
        SKEW_ABS=${SKEW#-}
        info "KDC 时间偏差: ${SKEW}秒"
        if [[ $SKEW_ABS -gt 300 ]]; then
            fail "时钟偏差 ${SKEW_ABS}秒 > 300秒（5min），将报 Clock skew"
        elif [[ $SKEW_ABS -gt 60 ]]; then
            warn "时钟偏差 ${SKEW_ABS}秒 > 60秒，建议同步"
        else
            ok "时钟偏差 ${SKEW_ABS}秒，正常"
        fi
    else
        warn "无法 SSH KDC ($KDC_HOST) 检查时钟"
    fi
fi

if command -v chronyc >/dev/null; then
    OFFSET=$(chronyc tracking 2>/dev/null | awk '/Last offset/{print $4}')
    [[ -n "$OFFSET" ]] && info "chrony last offset: $OFFSET"
fi

# ============ Step 3 网络检查 ============
title "Step 3 网络检查"
if [[ -n "$KDC_HOST" ]]; then
    info "KDC: $KDC_HOST"
    
    # DNS
    if getent hosts "$KDC_HOST" >/dev/null 2>&1; then
        ok "DNS 解析: $(getent hosts $KDC_HOST | head -1)"
    else
        fail "DNS 无法解析 $KDC_HOST"
    fi
    
    # TCP 88
    if nc -zv -w2 "$KDC_HOST" 88 >/dev/null 2>&1; then
        ok "TCP 88 通"
    else
        fail "TCP 88 不通"
    fi
    
    # UDP 88
    if timeout 2 bash -c "echo > /dev/udp/$KDC_HOST/88" 2>/dev/null; then
        ok "UDP 88 可达"
    else
        warn "UDP 88 不可达（如果走 TCP 不影响）"
    fi
    
    # kadmin
    if nc -zv -w2 "$KDC_HOST" 749 >/dev/null 2>&1; then
        ok "kadmin TCP 749 通"
    else
        warn "kadmin 749 不通（仅影响远程 kadmin）"
    fi
fi

# ============ Step 4 krb5.conf 关键项 ============
title "Step 4 krb5.conf 关键项"
KRB5_CONF=${KRB5_CONFIG:-/etc/krb5.conf}
if [[ ! -f $KRB5_CONF ]]; then
    fail "$KRB5_CONF 不存在"
else
    ok "$KRB5_CONF 存在"
    
    DEFAULT_REALM=$(awk '/default_realm/{print $3}' $KRB5_CONF | head -1)
    info "default_realm: $DEFAULT_REALM"
    [[ -z "$DEFAULT_REALM" ]] && fail "default_realm 未配置"
    
    RDNS=$(awk '/rdns/{print $3}' $KRB5_CONF | head -1)
    if [[ "$RDNS" == "false" ]]; then
        ok "rdns = false（生产推荐）"
    else
        warn "rdns 未设为 false（DNS 反解失败会导致认证失败）"
    fi
    
    UDP_PREF=$(awk '/udp_preference_limit/{print $3}' $KRB5_CONF | head -1)
    if [[ "$UDP_PREF" == "1" ]]; then
        ok "udp_preference_limit = 1（强制 TCP）"
    else
        warn "udp_preference_limit 未设为 1（大票据 UDP 截断可能失败）"
    fi
    
    FORWARDABLE=$(awk '/forwardable/{print $3}' $KRB5_CONF | head -1)
    if [[ "$FORWARDABLE" == "true" ]]; then
        ok "forwardable = true"
    else
        warn "forwardable 未设为 true（YARN/Spark 跨节点会失败）"
    fi
    
    if grep -q "default_ccache_name" $KRB5_CONF; then
        CC=$(awk '/default_ccache_name/{print $3}' $KRB5_CONF | head -1)
        info "default_ccache_name: $CC"
        if [[ "$CC" == KEYRING* ]] && [[ -f /.dockerenv ]]; then
            warn "容器中用 KEYRING ccache 会失效，建议改 FILE:/tmp/krb5cc_%{uid}"
        fi
    fi
    
    # enctype
    ENCTYPES=$(awk '/permitted_enctypes/{$1=$2=""; print}' $KRB5_CONF | head -1)
    info "permitted_enctypes: $ENCTYPES"
    if echo "$ENCTYPES" | grep -q "des"; then
        warn "包含 DES enctype（已不安全，建议移除）"
    fi
fi

# ============ Step 5 当前 ccache ============
title "Step 5 当前 ccache"
info "KRB5CCNAME: ${KRB5CCNAME:-<unset>}"
if klist 2>/dev/null | head -10 | tee -a $LOG | grep -q "Ticket cache"; then
    ok "当前有票据"
    EXPIRES=$(klist 2>/dev/null | grep "krbtgt" | awk '{print $3, $4}')
    [[ -n "$EXPIRES" ]] && info "TGT 过期时间: $EXPIRES"
else
    warn "当前用户无 TGT（如果是服务账户可忽略）"
fi

# ============ Step 6 keytab 检查 ============
if [[ -n "$KEYTAB" ]]; then
    title "Step 6 keytab 检查"
    if [[ ! -f $KEYTAB ]]; then
        fail "$KEYTAB 文件不存在"
    else
        ok "$KEYTAB 文件存在"
        
        # 权限
        PERM=$(stat -c %a $KEYTAB 2>/dev/null || stat -f %Lp $KEYTAB 2>/dev/null)
        if [[ "$PERM" == "400" ]] || [[ "$PERM" == "600" ]]; then
            ok "权限 $PERM 安全"
        else
            warn "权限 $PERM 不够严格（生产建议 400）"
        fi
        
        # 属主
        OWNER=$(stat -c "%U:%G" $KEYTAB 2>/dev/null || stat -f "%Su:%Sg" $KEYTAB 2>/dev/null)
        info "属主: $OWNER"
        
        # 内容
        info "条目："
        klist -kt $KEYTAB 2>/dev/null | tee -a $LOG | head -20
        
        # enctype
        info "enctype 列表："
        klist -ket $KEYTAB 2>/dev/null | awk -F'[()]' 'NF>1{print $2}' | sort -u | tee -a $LOG
        
        if klist -ket $KEYTAB 2>/dev/null | grep -q "aes256-cts"; then
            ok "包含 aes256-cts（推荐）"
        else
            warn "不包含 aes256-cts"
        fi
    fi
fi

# ============ Step 7 KVNO 一致性 ============
if [[ -n "$PRINCIPAL" && -n "$KEYTAB" && -f "$KEYTAB" ]]; then
    title "Step 7 KVNO 一致性"
    KT_KVNO=$(klist -kt $KEYTAB 2>/dev/null | grep "$PRINCIPAL" | awk '{print $1}' | sort -u | head -1)
    
    # 先 kinit 才能 kvno
    KDC_KVNO=""
    if klist 2>/dev/null | grep -q "Default principal"; then
        KDC_KVNO=$(kvno $PRINCIPAL 2>/dev/null | awk '{print $NF}')
    else
        # 临时 kinit
        kinit -kt $KEYTAB $PRINCIPAL 2>/dev/null && \
            KDC_KVNO=$(kvno $PRINCIPAL 2>/dev/null | awk '{print $NF}')
    fi
    
    info "Keytab KVNO: ${KT_KVNO:-<未找到>}"
    info "KDC KVNO:    ${KDC_KVNO:-<未取到>}"
    
    if [[ -n "$KT_KVNO" && -n "$KDC_KVNO" ]]; then
        if [[ "$KT_KVNO" == "$KDC_KVNO" ]]; then
            ok "KVNO 一致"
        else
            fail "KVNO 不一致! 修复命令："
            echo "  kadmin.local -q 'ktadd -norandkey -k /tmp/$(basename $KEYTAB) $PRINCIPAL'" | tee -a $LOG
        fi
    fi
fi

# ============ Step 8 测试 kinit (with TRACE) ============
if [[ -n "$PRINCIPAL" && -n "$KEYTAB" && -f "$KEYTAB" ]]; then
    title "Step 8 测试 kinit (KRB5_TRACE)"
    TRACE_LOG=$(mktemp)
    if KRB5_TRACE=$TRACE_LOG kinit -V -kt $KEYTAB $PRINCIPAL 2>&1 | head -10 | tee -a $LOG; then
        ok "kinit 成功"
        klist 2>/dev/null | head -10 | tee -a $LOG
    else
        fail "kinit 失败"
    fi
    
    info "TRACE 关键行："
    grep -E "Sending|Received|error|Selected etype|Salt" $TRACE_LOG 2>/dev/null | head -10 | tee -a $LOG
    info "完整 TRACE: $TRACE_LOG"
    
    kdestroy 2>/dev/null
fi

# ============ Step 9 JCE 解锁 ============
title "Step 9 JCE 解锁状态"
if command -v jrunscript >/dev/null; then
    KEY_LEN=$(jrunscript -e 'print(javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))' 2>/dev/null)
    info "AES Max Key Length: $KEY_LEN"
    if [[ "$KEY_LEN" == "2147483647" ]]; then
        ok "JCE 已解锁"
    elif [[ "$KEY_LEN" == "128" ]]; then
        fail "JCE 限制版（AES256 不可用）"
        echo "  修复：sed -i 's/^#crypto.policy=unlimited/crypto.policy=unlimited/' \$JAVA_HOME/jre/lib/security/java.security"
    fi
else
    warn "未找到 jrunscript（无 JDK），跳过 JCE 检查"
fi

# ============ Step 10 Hadoop 配置 ============
title "Step 10 Hadoop 配置"
HC=${HADOOP_CONF_DIR:-/etc/hadoop/conf}
if [[ -d $HC ]]; then
    AUTH_TYPE=$(xmllint --xpath "//property[name='hadoop.security.authentication']/value/text()" $HC/core-site.xml 2>/dev/null || \
                grep -A1 "hadoop.security.authentication" $HC/core-site.xml 2>/dev/null | grep -oP "(?<=<value>)[^<]+")
    if [[ "$AUTH_TYPE" == "kerberos" ]]; then
        ok "Hadoop authentication = kerberos"
    else
        warn "Hadoop authentication = $AUTH_TYPE (期望 kerberos)"
    fi
    
    # auth_to_local
    if grep -q "auth_to_local" $HC/core-site.xml 2>/dev/null; then
        ok "auth_to_local 规则已配置"
    else
        warn "auth_to_local 未配置"
    fi
else
    info "未找到 Hadoop 配置目录（$HC），跳过"
fi

# ============ 总结 ============
title "诊断总结"
echo -e "${GRN}✅ 通过: $GRN_COUNT${NC}" | tee -a $LOG
echo -e "${YEL}⚠️  警告: $YEL_COUNT${NC}" | tee -a $LOG
echo -e "${RED}❌ 失败: $RED_COUNT${NC}" | tee -a $LOG
echo "" | tee -a $LOG
echo "完整报告: $LOG"

if [[ $RED_COUNT -gt 0 ]]; then
    exit 2
elif [[ $YEL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
