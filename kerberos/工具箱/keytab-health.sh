#!/usr/bin/env bash
# keytab-health.sh — Keytab 全集群健康巡检（cron 定时跑）
# Usage: bash keytab-health.sh [-h hosts.txt]
# 输出：表格化健康报告 + 邮件告警

set -uo pipefail

HOSTS_FILE="${1:-/etc/sre/hosts.txt}"
KEYTAB_DIR="/etc/security/keytabs"
TS=$(date +%Y%m%d_%H%M%S)
REPORT="/var/log/sre/keytab_health_${TS}.csv"
ALERT_LOG="/var/log/sre/keytab_alert.log"
MAIL_TO="${SRE_MAIL:-sre@bigdata.com}"
PARALLEL=20
mkdir -p $(dirname $REPORT) $(dirname $ALERT_LOG)

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'

# CSV 头
echo "host,keytab,principal,kvno,enctype_count,perm,owner,kinit_ok,kvno_match_kdc" > $REPORT

# KDC
KDC=$(awk '/^[[:space:]]*kdc[[:space:]]*=/{print $3; exit}' /etc/krb5.conf | cut -d: -f1)

check_one_host() {
    local host=$1
    local tmp=$(mktemp)
    
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $host "
        for kt in $KEYTAB_DIR/*.keytab; do
            [[ -f \$kt ]] || continue
            
            # 提取第一行 principal 信息
            line=\$(klist -kt \$kt 2>/dev/null | awk 'NR==4')
            [[ -z \"\$line\" ]] && continue
            
            kvno=\$(echo \$line | awk '{print \$1}')
            principal=\$(echo \$line | awk '{print \$4}')
            enctype_count=\$(klist -ket \$kt 2>/dev/null | awk -F'[()]' 'NF>1 && \$2 ~ /-/' | wc -l)
            perm=\$(stat -c %a \$kt)
            owner=\$(stat -c %U:%G \$kt)
            
            # 测试 kinit
            svc=\$(echo \$principal | cut -d/ -f1)
            if id \$svc >/dev/null 2>&1; then
                sudo -u \$svc kinit -kt \$kt \$principal 2>/dev/null && \
                    sudo -u \$svc kdestroy 2>/dev/null && kinit_ok=1 || kinit_ok=0
            else
                kinit -kt \$kt \$principal 2>/dev/null && kdestroy 2>/dev/null && kinit_ok=1 || kinit_ok=0
            fi
            
            echo \"$host,\$kt,\$principal,\$kvno,\$enctype_count,\$perm,\$owner,\$kinit_ok\"
        done
    " 2>/dev/null > $tmp
    
    # 与 KDC 比对 KVNO
    while IFS=, read -r h kt principal kvno enctype_count perm owner kinit_ok; do
        kdc_kvno=$(ssh -o ConnectTimeout=2 $KDC "kadmin.local -q 'getprinc $principal' 2>/dev/null | awk '/Key: vno/{print \$3; exit}'" 2>/dev/null)
        if [[ -n "$kdc_kvno" && "$kvno" == "$kdc_kvno" ]]; then
            kvno_match=1
        else
            kvno_match=0
        fi
        echo "$h,$kt,$principal,$kvno,$enctype_count,$perm,$owner,$kinit_ok,$kvno_match" >> $REPORT
    done < $tmp
    
    rm -f $tmp
}

echo "===== Keytab Health Check ====="
echo "Hosts: $HOSTS_FILE"
echo "Time:  $(date)"
echo ""

# 并发巡检
while read host; do
    [[ -z "$host" || "$host" =~ ^# ]] && continue
    check_one_host $host &
    [[ $(jobs -r | wc -l) -ge $PARALLEL ]] && wait -n
done < $HOSTS_FILE
wait

# 统计 + 告警
echo ""
echo "===== 巡检报告 ====="
TOTAL=$(($(wc -l < $REPORT) - 1))
echo "Total keytabs:     $TOTAL"

# 权限不安全
PERM_BAD=$(awk -F, 'NR>1 && $6 != "400" && $6 != "600" {count++} END{print count+0}' $REPORT)
echo "权限不安全(非400):  $PERM_BAD"

# kinit 失败
KINIT_FAIL=$(awk -F, 'NR>1 && $8 == "0" {count++} END{print count+0}' $REPORT)
echo "kinit 失败:         $KINIT_FAIL"

# KVNO 不一致
KVNO_MISMATCH=$(awk -F, 'NR>1 && $9 == "0" {count++} END{print count+0}' $REPORT)
echo "KVNO 不一致:        $KVNO_MISMATCH"

# enctype 缺失（< 2 个 enctype 视为异常）
ENCTYPE_BAD=$(awk -F, 'NR>1 && $5 < 2 {count++} END{print count+0}' $REPORT)
echo "enctype 不足:       $ENCTYPE_BAD"

# 异常详情
ALERT=""
if [[ $PERM_BAD -gt 0 ]]; then
    ALERT+="\n[权限不安全 $PERM_BAD 个]\n"
    ALERT+="$(awk -F, 'NR>1 && $6 != "400" && $6 != "600" {print $1,$2,$6}' OFS=, $REPORT | head -10)\n"
fi
if [[ $KINIT_FAIL -gt 0 ]]; then
    ALERT+="\n[kinit 失败 $KINIT_FAIL 个]\n"
    ALERT+="$(awk -F, 'NR>1 && $8 == "0" {print $1,$2,$3}' OFS=, $REPORT | head -10)\n"
fi
if [[ $KVNO_MISMATCH -gt 0 ]]; then
    ALERT+="\n[KVNO 不一致 $KVNO_MISMATCH 个]\n"
    ALERT+="$(awk -F, 'NR>1 && $9 == "0" {print $1,$2,$3,$4}' OFS=, $REPORT | head -10)\n"
fi

if [[ -n "$ALERT" ]]; then
    echo -e "$ALERT" | tee -a $ALERT_LOG
    if command -v mail >/dev/null; then
        echo -e "Kerberos Keytab 巡检告警 $TS\n\n$ALERT\n\n完整报告: $REPORT" | \
            mail -s "[Kerberos] Keytab 健康告警 (Bad: $((PERM_BAD+KINIT_FAIL+KVNO_MISMATCH+ENCTYPE_BAD)))" $MAIL_TO
    fi
    exit 1
else
    echo -e "${GRN}✅ 全部健康${NC}"
    exit 0
fi
