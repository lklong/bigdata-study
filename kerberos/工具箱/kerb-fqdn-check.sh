#!/usr/bin/env bash
# kerb-fqdn-check.sh — 检查所有节点 FQDN/DNS 一致性（_HOST 替换前提）
# 排查 "Server not found in Kerberos database" 类的根因

set -uo pipefail

HOSTS_FILE="${1:-hosts.txt}"
TS=$(date +%Y%m%d_%H%M%S)
OUT="/tmp/fqdn_check_${TS}.csv"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'

echo "host,hostname,hostname_f,dns_forward,dns_reverse,consistent" > $OUT

check_one() {
    local h=$1
    ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes $h "
        hn=\$(hostname)
        hnf=\$(hostname -f 2>/dev/null)
        ip=\$(getent ahostsv4 \$hnf 2>/dev/null | head -1 | awk '{print \$1}')
        rev=\$(getent hosts \$ip 2>/dev/null | head -1 | awk '{print \$2}')
        
        consistent=1
        [[ \$hn != \$hnf ]] && consistent=0    # 短名 != FQDN，hostname 没设 FQDN
        [[ \$rev != \$hnf && -n \$rev ]] && consistent=0   # 反解不一致
        [[ \$hnf != *.* ]] && consistent=0     # 不含点号 = 不是 FQDN
        
        echo \"$h,\$hn,\$hnf,\$ip,\$rev,\$consistent\"
    " 2>/dev/null || echo "$h,UNREACHABLE,,,,0"
}

while read host; do
    [[ -z "$host" || "$host" =~ ^# ]] && continue
    check_one $host >> $OUT &
    [[ $(jobs -r | wc -l) -ge 20 ]] && wait -n
done < $HOSTS_FILE
wait

echo "===== FQDN 检查结果 ====="
echo ""
column -t -s, $OUT | head -20

echo ""
echo "异常节点（consistent=0）："
awk -F, 'NR>1 && $6 == "0"' $OUT | column -t -s,

NORMAL=$(awk -F, 'NR>1 && $6 == "1"' $OUT | wc -l)
BAD=$(awk -F, 'NR>1 && $6 == "0"' $OUT | wc -l)
TOTAL=$((NORMAL + BAD))

echo ""
echo -e "${GRN}✅ 正常: $NORMAL${NC}"
echo -e "${RED}❌ 异常: $BAD / $TOTAL${NC}"
echo "完整: $OUT"

[[ $BAD -gt 0 ]] && exit 1
exit 0
