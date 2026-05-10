#!/usr/bin/env bash
# kerb-token-monitor.sh — Hadoop Delegation Token 健康监控（防长任务雪崩）
# 用途：找出未配 --keytab 的长任务，提前预警

set -uo pipefail

RM_HOST="${RM_HOST:-rm01.bigdata.com}"
RM_PORT="${RM_PORT:-8088}"
NN_HOST="${NN_HOST:-nn01.bigdata.com}"
NN_PORT="${NN_PORT:-9870}"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'

echo "===== Hadoop Token 健康监控 $(date) ====="
echo ""

# 1) NameNode JMX：看 token 数量和过期情况
echo "--- HDFS Token Statistics (from NN JMX) ---"
JMX=$(curl -s --negotiate -u : "http://$NN_HOST:$NN_PORT/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem" 2>/dev/null)
if [[ -n "$JMX" ]]; then
    echo "$JMX" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for bean in data.get('beans', []):
    print(f\"  TotalLoadedTokens:    {bean.get('NumberOfTokens', 'N/A')}\")
    print(f\"  ExpiredTokens:        {bean.get('NumberOfExpiredTokens', 'N/A')}\")
" 2>/dev/null || echo "  无法解析 JMX"
fi

echo ""

# 2) YARN：找运行中的长任务（> 6 天）
echo "--- 长任务 (running > 6 天) ---"
NOW=$(date +%s)
SIX_DAYS_AGO=$((NOW - 6 * 86400))

APPS=$(curl -s --negotiate -u : "http://$RM_HOST:$RM_PORT/ws/v1/cluster/apps?state=RUNNING&limit=200" 2>/dev/null)

echo "$APPS" | python3 -c "
import json, sys, time
data = json.load(sys.stdin)
apps = data.get('apps', {}).get('app', [])
six_days_ago = time.time() * 1000 - 6 * 86400 * 1000

print(f'{\"AppId\":<30} {\"User\":<15} {\"Type\":<10} {\"Days\":<5} {\"Name\"}')
for app in apps:
    started = app.get('startedTime', 0)
    if started < six_days_ago:
        days = int((time.time() * 1000 - started) / 86400000)
        print(f\"{app['id']:<30} {app['user']:<15} {app['applicationType']:<10} {days:<5} {app['name'][:50]}\")
" 2>/dev/null || echo "  无法解析 RM API"

echo ""

# 3) 找出未配 --keytab 的 Spark/Flink 任务（关键预警）
echo "--- 未配 --keytab 的长任务（高危！）---"
echo "$APPS" | python3 -c "
import json, sys, time, urllib.request, urllib.parse, ssl

data = json.load(sys.stdin)
apps = data.get('apps', {}).get('app', [])
two_days_ago = time.time() * 1000 - 2 * 86400 * 1000

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

print(f'{\"AppId\":<30} {\"User\":<15} {\"Type\":<10} {\"--keytab?\":<10}')
for app in apps:
    if app.get('startedTime', 0) > two_days_ago:
        continue
    if app.get('applicationType') not in ('SPARK', 'FLINK', 'TEZ'):
        continue
    
    # 通过 RM API 拿应用详情
    try:
        url = f\"http://$RM_HOST:$RM_PORT/ws/v1/cluster/apps/{app['id']}\"
        req = urllib.request.Request(url, headers={'Accept': 'application/json'})
        resp = urllib.request.urlopen(req, context=ctx, timeout=3).read().decode()
        info = json.loads(resp).get('app', {})
        diag = info.get('diagnostics', '') + info.get('amContainerLogs', '')
        # 启动命令通常在 logs 中
        keytab_used = 'keytab' in diag.lower()
        flag = '✅' if keytab_used else '❌'
    except Exception:
        flag = '?'
    
    print(f\"{app['id']:<30} {app['user']:<15} {app['applicationType']:<10} {flag:<10}\")
" 2>/dev/null

echo ""

# 4) 给出建议
echo "===== 建议 ====="
echo "1. 长任务（> 1 天）必须配 --keytab + --principal"
echo "2. 推荐启用强制检查脚本：safe-spark-submit"
echo "3. Prometheus 监控 hadoop_namenode_dt_count{type=\"expired_soon\"}"
