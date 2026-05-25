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

# 1. 远端建目录（v2: 增加 queries_cosn）
ssh -o StrictHostKeyChecking=no $REMOTE_USER@$MASTER_IP \
  "su - hadoop -c 'mkdir -p $REMOTE_BASE/{gen,queries,queries_cosn,scripts,results}'"

# 2. 拷贝 SQL
echo "==> 拷贝 5 个数据生成 SQL..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/gen/*.sql $REMOTE_USER@$MASTER_IP:/tmp/
ssh $REMOTE_USER@$MASTER_IP "mv /tmp/_init.sql /tmp/0?_*.sql $REMOTE_BASE/gen/ && chown -R hadoop:hadoop $REMOTE_BASE/gen/"

echo "==> 拷贝 7 条 HDFS Bench SQL（USE bench;）..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/queries/*.sql $REMOTE_USER@$MASTER_IP:/tmp/
ssh $REMOTE_USER@$MASTER_IP "mkdir -p /tmp/q_hdfs && mv /tmp/q?_*.sql /tmp/q_hdfs/ && mv /tmp/q_hdfs/*.sql $REMOTE_BASE/queries/ && rmdir /tmp/q_hdfs && chown -R hadoop:hadoop $REMOTE_BASE/queries/"

echo "==> 拷贝 7 条 cosn Bench SQL（USE bench_cosn;）..."
# 用 tar pipe 避免文件名冲突
(cd $TOOLKIT_DIR/queries_cosn && tar cf - *.sql) | \
  ssh $REMOTE_USER@$MASTER_IP "cd $REMOTE_BASE/queries_cosn && tar xf - && chown -R hadoop:hadoop $REMOTE_BASE/queries_cosn/"

# 3. 拷贝脚本（v2: 包含 bench_cosn.sh）
echo "==> 拷贝跑批脚本（gen_all + bench_all + bench_cosn）..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/scripts/gen_all.sh \
                                 $TOOLKIT_DIR/scripts/bench_all.sh \
                                 $TOOLKIT_DIR/scripts/bench_cosn.sh \
  $REMOTE_USER@$MASTER_IP:$REMOTE_BASE/scripts/
ssh $REMOTE_USER@$MASTER_IP "chmod +x $REMOTE_BASE/scripts/*.sh && chown -R hadoop:hadoop $REMOTE_BASE/scripts/"

# 4. 拷贝 DDL
echo "==> 拷贝外部表 DDL..."
scp -o StrictHostKeyChecking=no $TOOLKIT_DIR/ddl/external_tables.sql $REMOTE_USER@$MASTER_IP:$REMOTE_BASE/external_tables.sql
ssh $REMOTE_USER@$MASTER_IP "chown hadoop:hadoop $REMOTE_BASE/external_tables.sql"

# 5. 列出远端结构
echo
echo "==> 部署完成，远端目录结构："
ssh $REMOTE_USER@$MASTER_IP "ls -la $REMOTE_BASE/{gen,queries,queries_cosn,scripts}/ $REMOTE_BASE/external_tables.sql 2>&1 | head -60"

echo
echo "============================================================"
echo "✓ Toolkit v2 已部署到 $MASTER_IP:$REMOTE_BASE"
echo
echo "下一步（在 master 上以 hadoop 用户执行）："
echo
echo "  # === 0. 改 2 个变量（必做） ==="
echo "  ssh root@$MASTER_IP"
echo "  MASTER_IP=\$(hostname -I | awk '{print \$1}')"
echo "  sed -i \"s|DRIVER_HOST=172.21.240.144|DRIVER_HOST=\$MASTER_IP|g\" $REMOTE_BASE/scripts/*.sh"
echo "  # 如果不用默认 cosn 桶，再改路径："
echo "  sed -i 's|cosn://lkl-bj-update-1308597516/meson/data/bench|你的桶路径|g' \\"
echo "    $REMOTE_BASE/gen/*.sql $REMOTE_BASE/queries_cosn/*.sql $REMOTE_BASE/external_tables.sql"
echo
echo "  # === 路线 A：HDFS Bench ==="
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/gen_all.sh all'             # 生成 80GB 到 HDFS"
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/bench_all.sh native'        # HDFS Native"
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/bench_all.sh gluten'        # HDFS Gluten"
echo
echo "  # === 路线 B：cosn Bench（需要先有 cosn 数据） ==="
echo "  # 如果数据在 HDFS，先 distcp 到 cosn："
echo "  su - hadoop -c 'hadoop distcp -m 100 -bandwidth 200 \\"
echo "    hdfs:///user/hadoop/bench/ cosn://你的桶/your-path/bench/'"
echo "  # 建 cosn 外部表："
echo "  su - hadoop -c 'hive -f $REMOTE_BASE/external_tables.sql'"
echo "  # 跑 cosn bench："
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/bench_cosn.sh native'       # cosn Native"
echo "  su - hadoop -c 'cd $REMOTE_BASE && ./scripts/bench_cosn.sh gluten'       # cosn Gluten"
echo
echo "  # === 看结果 ==="
echo "  cat $REMOTE_BASE/results/duration_native.csv          # HDFS Native"
echo "  cat $REMOTE_BASE/results/duration_gluten.csv          # HDFS Gluten"
echo "  cat $REMOTE_BASE/results/duration_cosn_native.csv     # cosn Native"
echo "  cat $REMOTE_BASE/results/duration_cosn_gluten.csv     # cosn Gluten"
echo "============================================================"
