#!/bin/bash
# 检查 bench_cosn 库与 5 张表是否已就绪
set +e
su - hadoop <<'EOF'
export SPARK_HOME=/opt/spark-poc
/opt/spark-poc/bin/spark-sql --master local -e "show databases; show tables in bench_cosn;" 2>/dev/null | tail -30
EOF
