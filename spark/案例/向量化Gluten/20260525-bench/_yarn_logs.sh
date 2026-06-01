#!/bin/bash
# 抓 Gluten 失败的 yarn 容器日志
set +e
APP=$1
[ -z "$APP" ] && APP=application_1779692761850_0031

su - hadoop <<EOF
echo "=== yarn logs head 300 ==="
yarn logs -applicationId ${APP} 2>/dev/null | head -300
echo
echo "=== AM container last 80 ==="
yarn logs -applicationId ${APP} 2>/dev/null | tail -80
EOF
