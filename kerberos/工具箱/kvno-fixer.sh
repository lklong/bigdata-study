#!/usr/bin/env bash
# kvno-fixer.sh — 批量 KVNO 不一致修复（生产 Top1 故障）
# Usage: bash kvno-fixer.sh -h hosts.txt [-K kdc01.bigdata.com] [--dry-run]
# hosts.txt 格式：每行 host_or_fqdn

set -euo pipefail

HOSTS_FILE=""
KDC=""
DRY_RUN=false
KEYTAB_DIR="/etc/security/keytabs"
PARALLEL=10

while [[ $# -gt 0 ]]; do
    case $1 in
        -h) HOSTS_FILE=$2; shift 2 ;;
        -K) KDC=$2; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) echo "Usage: $0 -h hosts.txt [-K kdc] [--dry-run]"; exit 0 ;;
        *) shift ;;
    esac
done

[[ -z "$HOSTS_FILE" ]] && { echo "ERROR: 必须指定 -h hosts.txt"; exit 1; }
[[ -z "$KDC" ]] && KDC=$(awk '/^[[:space:]]*kdc[[:space:]]*=/{print $3; exit}' /etc/krb5.conf | cut -d: -f1)
[[ -z "$KDC" ]] && { echo "ERROR: 无法确定 KDC，请用 -K 指定"; exit 1; }

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'
TS=$(date +%Y%m%d_%H%M%S)
WORKDIR="/tmp/kvno_fix_${TS}"
mkdir -p $WORKDIR

echo "===== Kerberos KVNO Fixer ====="
echo "KDC:       $KDC"
echo "Hosts:     $HOSTS_FILE ($(wc -l < $HOSTS_FILE) 个)"
echo "Workdir:   $WORKDIR"
echo "Dry-run:   $DRY_RUN"
echo ""

# Step 1: 探测 KVNO 不一致
echo "===== Step 1: 探测 KVNO 不一致 ====="
> $WORKDIR/mismatch.txt

while read host; do
    [[ -z "$host" || "$host" =~ ^# ]] && continue
    
    # 远程获取该主机所有 keytab 的 KVNO
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $host "
        for kt in $KEYTAB_DIR/*.keytab; do
            [[ -f \$kt ]] || continue
            klist -kt \$kt 2>/dev/null | awk -v h='$host' -v k=\$kt 'NR>3 && \$4 ~ /@/ {print h \",\" k \",\" \$4 \",\" \$1}'
        done
    " 2>/dev/null | sort -u >> $WORKDIR/inventory.txt &
    
    [[ $(jobs -r | wc -l) -ge $PARALLEL ]] && wait -n
done < $HOSTS_FILE
wait

echo "Inventory: $(wc -l < $WORKDIR/inventory.txt) 条 keytab 条目"

# 与 KDC 比对
echo "比对 KDC..."
while IFS=, read -r host kt principal kt_kvno; do
    kdc_kvno=$(ssh -o ConnectTimeout=2 $KDC "kadmin.local -q 'getprinc $principal' 2>/dev/null | awk '/Key: vno/{print \$3; exit}'" 2>/dev/null)
    if [[ -n "$kdc_kvno" && "$kt_kvno" != "$kdc_kvno" ]]; then
        echo "$host,$kt,$principal,$kt_kvno,$kdc_kvno" >> $WORKDIR/mismatch.txt
    fi
done < $WORKDIR/inventory.txt

MISMATCH_COUNT=$(wc -l < $WORKDIR/mismatch.txt)
echo ""
if [[ $MISMATCH_COUNT -eq 0 ]]; then
    echo -e "${GRN}✅ 所有 keytab KVNO 一致，无需修复${NC}"
    exit 0
fi

echo -e "${RED}❌ 发现 $MISMATCH_COUNT 个 KVNO 不一致${NC}"
echo ""
echo "Host,Keytab,Principal,KT_KVNO,KDC_KVNO"
column -t -s, $WORKDIR/mismatch.txt | head -20
[[ $MISMATCH_COUNT -gt 20 ]] && echo "... (更多请看 $WORKDIR/mismatch.txt)"

if $DRY_RUN; then
    echo ""
    echo -e "${YEL}Dry-run 模式，不执行修复。去掉 --dry-run 实际修复。${NC}"
    exit 0
fi

# Step 2: 在 KDC 上重新导出 keytab（带 -norandkey）
echo ""
echo "===== Step 2: KDC 上重新导出 keytab ====="
read -p "确认要在 KDC 上批量 ktadd -norandkey 吗？(yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "用户取消"; exit 0; }

ssh $KDC "mkdir -p /tmp/keytab_redeploy_$TS && rm -f /tmp/keytab_redeploy_$TS/*"

while IFS=, read -r host kt principal kt_kvno kdc_kvno; do
    out_kt="/tmp/keytab_redeploy_$TS/$(basename $kt).${host}"
    echo "  ktadd -norandkey $principal -> $out_kt"
    ssh $KDC "kadmin.local -q 'ktadd -norandkey -k $out_kt $principal' 2>&1 | tail -1"
done < $WORKDIR/mismatch.txt

# Step 3: 拉取到本地
echo ""
echo "===== Step 3: 从 KDC 拉取 keytab ====="
mkdir -p $WORKDIR/keytabs_to_deploy
rsync -av $KDC:/tmp/keytab_redeploy_$TS/ $WORKDIR/keytabs_to_deploy/

# Step 4: 分发 + 部署 + 重启
echo ""
echo "===== Step 4: 分发 + 部署 ====="

deploy_one() {
    local host=$1 kt=$2 principal=$3
    local svc=$(echo $principal | cut -d/ -f1)
    local local_kt="$WORKDIR/keytabs_to_deploy/$(basename $kt).${host}"
    
    [[ ! -f $local_kt ]] && { echo "❌ $host $kt 缺少新 keytab"; return 1; }
    
    scp -o StrictHostKeyChecking=no $local_kt $host:/tmp/$(basename $kt).new >/dev/null
    ssh -o StrictHostKeyChecking=no $host "
        cp $kt ${kt}.bak_$TS
        mv /tmp/$(basename $kt).new $kt
        chown $svc:hadoop $kt 2>/dev/null || chown $svc:$svc $kt 2>/dev/null
        chmod 400 $kt
        sudo -u $svc kinit -kt $kt $principal && sudo -u $svc kdestroy
    " && echo "  ✅ $host $kt" || echo "  ❌ $host $kt"
}

while IFS=, read -r host kt principal kt_kvno kdc_kvno; do
    deploy_one $host $kt $principal &
    [[ $(jobs -r | wc -l) -ge $PARALLEL ]] && wait -n
done < $WORKDIR/mismatch.txt
wait

# Step 5: 滚动重启服务（用户决定）
echo ""
echo "===== Step 5: 重启服务（手动） ====="
echo "请按服务批次手动滚动重启："
awk -F, '{print $1, $2}' $WORKDIR/mismatch.txt | sort -u | while read host kt; do
    svc=$(basename $kt | cut -d. -f1)
    case $svc in
        hdfs) echo "  ssh $host 'systemctl restart hadoop-hdfs-datanode'" ;;
        yarn) echo "  ssh $host 'systemctl restart hadoop-yarn-nodemanager'" ;;
        hive) echo "  ssh $host 'systemctl restart hive-server2'" ;;
        *)    echo "  ssh $host 'systemctl restart <service for $svc>'" ;;
    esac
done | head -20

# Step 6: 清理 KDC 临时文件
echo ""
echo "===== Step 6: 清理 KDC 临时文件 ====="
ssh $KDC "rm -rf /tmp/keytab_redeploy_$TS"

echo ""
echo -e "${GRN}===== 修复流程完成 =====${NC}"
echo "工作目录: $WORKDIR"
echo "回滚：cp ${kt}.bak_$TS $kt （在每台机器上）"
