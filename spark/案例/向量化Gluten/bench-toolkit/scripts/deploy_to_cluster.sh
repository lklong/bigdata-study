#!/bin/bash
# ====================================================================
# 一键部署 Bench Toolkit 到目标集群的 master 节点
# 用法：./deploy_to_cluster.sh <master_ip>
# 例如：./deploy_to_cluster.sh 101.43.161.139
# ====================================================================
set -e

MASTER_IP=${1:?用法: $0 <master_ip>}
TOOLKIT_DIR=$(cd "$(dirname "$0")/.." && pwd)
REMOTE_USER=root
REMOTE_BASE=/home/hadoop/bench

echo "==> Toolkit 源目录: $TOOLKIT_DIR"
echo "==> 目标集群 master: $MASTER_IP"
echo "==> 远端目录: $REMOTE_BASE"
echo

# 1. 远端建目录
ssh -o StrictHostKeyChecking=no $REMOTE_USER@$MASTER_IP \
  "su - hadoop -c 'mkdir -p $REMOTE_BASE/{gen,queries,scripts,results}'"

# 2. 拷贝 SQL
echo "==> 拷贝 5 个数据生成 SQL..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/gen/*.sql $REMOTE_USER@$MASTER_IP:/tmp/
ssh $REMOTE_USER@$MASTER_IP "mv /tmp/_init.sql /tmp/0?_*.sql $REMOTE_BASE/gen/ && chown -R hadoop:hadoop $REMOTE_BASE/gen/"

echo "==> 拷贝 7 条 Bench SQL..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/queries/*.sql $REMOTE_USER@$MASTER_IP:/tmp/
ssh $REMOTE_USER@$MASTER_IP "mv /tmp/q?_*.sql $REMOTE_BASE/queries/ && chown -R hadoop:hadoop $REMOTE_BASE/queries/"

# 3. 拷贝脚本
echo "==> 拷贝跑批脚本..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/scripts/*.sh $REMOTE_USER@$MASTER_IP:/tmp/
ssh $REMOTE_USER@$MASTER_IP "mv /tmp/gen_all.sh /tmp/bench_all.sh $REMOTE_BASE/scripts/ && chmod +x $REMOTE_BASE/scripts/*.sh && chown -R hadoop:hadoop $REMOTE_BASE/scripts/"

# 4. 拷贝 DDL
echo "==> 拷贝外部表 DDL..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/ddl/external_tables.sql $REMOTE_USER@$MASTER_IP:/tmp/
ssh $REMOTE_USER@$MASTER_IP "mv /tmp/external_tables.sql $REMOTE_BASE/ && chown hadoop:hadoop $REMOTE_BASE/external_tables.sql"

# 5. 列出远端结构
echo
echo "==> 部署完成，远端目录结构："
ssh $REMOTE_USER@$MASTER_IP "ls -la $REMOTE_BASE/{gen,queries,scripts}/ $REMOTE_BASE/external_tables.sql"

echo
echo "============================================================"
echo "✓ Toolkit 已部署到 $MASTER_IP:$REMOTE_BASE"
echo
echo "下一步操作（在 master 上）："
echo "  # 1. 修改 driver host（脚本里默认 172.21.240.144）"
echo "  vi $REMOTE_BASE/scripts/gen_all.sh    # 改 DRIVER_HOST"
echo "  vi $REMOTE_BASE/scripts/bench_all.sh  # 改 DRIVER_HOST"
echo
echo "  # 2. 修改 LOCATION 路径（如果用的不是默认 cosn 桶）"
echo "  sed -i 's|cosn://lkl-bj-update-1308597516/meson|你的路径|g' $REMOTE_BASE/gen/*.sql"
echo
echo "  # 3. 生成 5 张表（耗时 8-15 分钟）"
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/gen_all.sh all'"
echo
echo "  # 4. 跑 Native Bench"
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/bench_all.sh native'"
echo
echo "  # 5. 跑 Gluten Bench"
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/bench_all.sh gluten'"
echo "============================================================"
