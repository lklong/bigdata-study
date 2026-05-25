#!/bin/bash
# ====================================================================
# L1 一键 Bench 脚本：HDFS+cosn 双存储 4 单元自动跑完 + 自动出报告
#
# 前提：JDK11 / Spark3.5 / Gluten 已部署、bench-toolkit 已 deploy 到 master
#
# 用法：
#   在目标集群 master 上以 root 执行：
#     bash run_bench.sh                   # 全自动（HDFS gen+bench + cosn bench）
#     bash run_bench.sh hdfs              # 只跑 HDFS（gen+bench）
#     bash run_bench.sh cosn              # 只跑 cosn（数据已在 cosn）
#     bash run_bench.sh distcp_then_cosn  # 先 distcp HDFS→cosn 再跑 cosn bench
#     bash run_bench.sh report            # 只汇总现有 CSV 出报告
#
# 输出：/home/hadoop/bench/results/2x2_matrix_report.md（最终报告）
# ====================================================================
set -e

MODE=${1:-all}
BENCH_DIR=/home/hadoop/bench
COSN_BUCKET=${COSN_BUCKET:-cosn://lkl-bj-update-1308597516/meson/data/bench}
HDFS_PATH=${HDFS_PATH:-hdfs:///user/hadoop/bench}

# 颜色（终端可视化）
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +'%H:%M:%S')] $*${NC}"; }
ok()   { echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $*${NC}"; }
err()  { echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $*${NC}"; }

# ====== 体检 ======
preflight() {
  log "Step 0: 环境体检"
  [ -d $BENCH_DIR/scripts ] || { err "$BENCH_DIR 不存在，先跑 deploy_to_cluster.sh"; exit 1; }
  [ -x $BENCH_DIR/scripts/bench_all.sh ] || { err "bench_all.sh 不存在"; exit 1; }
  [ -x $BENCH_DIR/scripts/bench_cosn.sh ] || { err "bench_cosn.sh 不存在"; exit 1; }
  [ -d /usr/local/jdk ] || { err "/usr/local/jdk 软链不存在，请先装 Kona JDK 11"; exit 1; }
  [ -x /usr/local/service/spark/bin/spark-sql ] || { err "Spark 3.5 未部署"; exit 1; }
  ls /usr/local/service/spark/jars/gluten-velox-bundle-*.jar &>/dev/null || \
    { err "Gluten jar 未部署"; exit 1; }
  
  # 自动改 DRIVER_HOST 为本机内网 IP
  local IP=$(hostname -I | awk '{print $1}')
  sed -i "s|^DRIVER_HOST=.*|DRIVER_HOST=$IP|" $BENCH_DIR/scripts/*.sh
  ok "DRIVER_HOST 已设置为 $IP"
  
  # 创建结果目录
  su - hadoop -c "mkdir -p $BENCH_DIR/results"
  ok "环境体检通过"
  echo
}

# ====== HDFS：数据生成 + Bench ======
run_hdfs_gen() {
  log "Step 1: 生成 HDFS 数据（5 表 91.7G，约 10-15 分钟）"
  if su - hadoop -c "hadoop fs -test -d $HDFS_PATH/order_items" 2>/dev/null; then
    warn "HDFS 数据已存在，跳过生成。如需重新生成：hadoop fs -rm -r $HDFS_PATH"
    return 0
  fi
  # 把 gen/*.sql 的 LOCATION 改成 HDFS
  su - hadoop -c "sed -i 's|LOCATION .[a-z]*://[^\"\\x27]*|LOCATION \"$HDFS_PATH|g' $BENCH_DIR/gen/_init.sql"
  for n in 01 02 03 04 05; do
    su - hadoop -c "sed -i 's|LOCATION .[a-z]*://[^\"\\x27]*|LOCATION \"$HDFS_PATH|g' $BENCH_DIR/gen/${n}_*.sql"
  done
  
  su - hadoop -c "cd $BENCH_DIR && bash scripts/gen_all.sh all" 2>&1 | tail -20
  ok "HDFS 数据生成完成"
  echo
}

run_hdfs_bench() {
  log "Step 2: 跑 HDFS Bench（Native + Gluten 两轮，约 12-17 分钟）"
  su - hadoop -c "cd $BENCH_DIR && bash scripts/bench_all.sh native" 2>&1 | tail -20
  su - hadoop -c "cd $BENCH_DIR && bash scripts/bench_all.sh gluten" 2>&1 | tail -20
  ok "HDFS Bench 完成"
  echo
}

# ====== distcp HDFS → cosn ======
run_distcp() {
  log "Step 3: distcp HDFS → cosn（约 2-5 分钟）"
  if ! su - hadoop -c "hadoop fs -test -d $HDFS_PATH/order_items" 2>/dev/null; then
    err "HDFS 数据不存在，无法 distcp"; return 1
  fi
  if su - hadoop -c "hadoop fs -test -d $COSN_BUCKET/order_items" 2>/dev/null; then
    warn "cosn 已有数据，跳过 distcp。如需重传：hadoop fs -rm -r $COSN_BUCKET"
    return 0
  fi
  su - hadoop -c "hadoop distcp -m 100 -bandwidth 200 -update \
    $HDFS_PATH/ $COSN_BUCKET/" 2>&1 | tail -20
  ok "distcp 完成"
  echo
}

# ====== cosn 建外部表 + Bench ======
run_cosn_setup() {
  log "Step 4: 在 cosn 上建外部表 bench_cosn"
  if ! su - hadoop -c "hadoop fs -test -d $COSN_BUCKET/order_items" 2>/dev/null; then
    err "cosn 数据不存在，请先 distcp 或运行 'run_bench.sh distcp_then_cosn'"; return 1
  fi
  # 改外部表 DDL 的 LOCATION 为当前 COSN_BUCKET
  su - hadoop -c "sed -i 's|cosn://[^\\x27]*/bench|$COSN_BUCKET|g' $BENCH_DIR/external_tables.sql 2>/dev/null || true"
  su - hadoop -c "hive -f $BENCH_DIR/external_tables.sql" 2>&1 | grep -vE 'SLF4J|^WARN|Logging|illegal|Hive Session' | tail -10
  ok "cosn 外部表建好"
  echo
}

run_cosn_bench() {
  log "Step 5: 跑 cosn Bench（Native + Gluten 两轮）"
  # 同步改 queries_cosn 里的 USE 子句（如果库名不是默认 bench_cosn 的话保持）
  su - hadoop -c "cd $BENCH_DIR && bash scripts/bench_cosn.sh native" 2>&1 | tail -20
  su - hadoop -c "cd $BENCH_DIR && bash scripts/bench_cosn.sh gluten" 2>&1 | tail -20
  ok "cosn Bench 完成"
  echo
}

# ====== 出报告 ======
gen_report() {
  log "Step 6: 整理结果生成 2x2 矩阵报告"
  local REPORT=$BENCH_DIR/results/2x2_matrix_report.md
  local IP=$(hostname -I | awk '{print $1}')
  local HOST=$(hostname)
  
  {
    echo "# Spark Gluten Bench 2x2 矩阵实测报告（自动生成）"
    echo
    echo "> **集群**：\`$HOST\` (\`$IP\`)"
    echo "> **生成时间**：\`$(date +'%Y-%m-%d %H:%M:%S')\`"
    echo "> **数据**：5 表 / 29 亿行 / 91.7G Parquet"
    echo
    echo "## 一、4 个实验单元结果"
    echo
    
    for combo in "HDFS Native:duration_native.csv" \
                 "HDFS Gluten:duration_gluten.csv" \
                 "cosn Native:duration_cosn_native.csv" \
                 "cosn Gluten:duration_cosn_gluten.csv"; do
      local label=${combo%:*}; local file=${combo##*:}
      echo "### $label"
      if [ -s "$BENCH_DIR/results/$file" ]; then
        echo '```'
        cat "$BENCH_DIR/results/$file"
        echo '```'
      else
        echo "_（未跑或无结果）_"
      fi
      echo
    done
    
    echo "## 二、加速比对比"
    echo
    echo "| Query | HDFS Native(s) | HDFS Gluten(s) | HDFS 加速 | cosn Native(s) | cosn Gluten(s) | cosn 加速 |"
    echo "|---|---|---|---|---|---|---|"
    
    local h_native=$BENCH_DIR/results/duration_native.csv
    local h_gluten=$BENCH_DIR/results/duration_gluten.csv
    local c_native=$BENCH_DIR/results/duration_cosn_native.csv
    local c_gluten=$BENCH_DIR/results/duration_cosn_gluten.csv
    
    for q in q1_agg q2_join_2tables q3_join_3tables q4_window q5_subquery q6_self_join q7_5tables; do
      local hn=$(awk -F, -v q=$q '$1==q {printf "%.1f",$3/1000}' $h_native 2>/dev/null)
      local hg=$(awk -F, -v q=$q '$1==q {printf "%.1f",$3/1000}' $h_gluten 2>/dev/null)
      local cn=$(awk -F, -v q=$q '$1==q {printf "%.1f",$3/1000}' $c_native 2>/dev/null)
      local cg=$(awk -F, -v q=$q '$1==q {printf "%.1f",$3/1000}' $c_gluten 2>/dev/null)
      local hr=$(awk -v n=${hn:-0} -v g=${hg:-1} 'BEGIN{if(g>0)printf "%.2fx",n/g; else print "-"}')
      local cr=$(awk -v n=${cn:-0} -v g=${cg:-1} 'BEGIN{if(g>0)printf "%.2fx",n/g; else print "-"}')
      echo "| $q | ${hn:-—} | ${hg:-—} | ${hr:-—} | ${cn:-—} | ${cg:-—} | ${cr:-—} |"
    done
    
    # 总计行
    local hn_sum=$(awk -F, 'NR>1{s+=$3} END{printf "%.1f",s/1000}' $h_native 2>/dev/null)
    local hg_sum=$(awk -F, 'NR>1{s+=$3} END{printf "%.1f",s/1000}' $h_gluten 2>/dev/null)
    local cn_sum=$(awk -F, 'NR>1{s+=$3} END{printf "%.1f",s/1000}' $c_native 2>/dev/null)
    local cg_sum=$(awk -F, 'NR>1{s+=$3} END{printf "%.1f",s/1000}' $c_gluten 2>/dev/null)
    local hr_sum=$(awk -v n=${hn_sum:-0} -v g=${hg_sum:-1} 'BEGIN{if(g>0)printf "%.2fx",n/g; else print "-"}')
    local cr_sum=$(awk -v n=${cn_sum:-0} -v g=${cg_sum:-1} 'BEGIN{if(g>0)printf "%.2fx",n/g; else print "-"}')
    echo "| **总计** | **${hn_sum:-—}** | **${hg_sum:-—}** | **${hr_sum:-—}** | **${cn_sum:-—}** | **${cg_sum:-—}** | **${cr_sum:-—}** |"
    echo
    
    echo "## 三、性能基线对比（与历史数据）"
    echo
    echo "| 单元 | 当前结果 | H2-HDFS 基线 | H2-cosn 基线 | H3-cosn 基线 |"
    echo "|---|---|---|---|---|"
    echo "| HDFS Native | ${hn_sum:-—}s | 492.8s | — | — |"
    echo "| HDFS Gluten | ${hg_sum:-—}s | 243.6s | — | — |"
    echo "| HDFS 加速比 | ${hr_sum:-—} | 2.02× | — | — |"
    echo "| cosn Native | ${cn_sum:-—}s | — | 420.2s | 513.2s |"
    echo "| cosn Gluten | ${cg_sum:-—}s | — | 325.0s | 437.9s |"
    echo "| cosn 加速比 | ${cr_sum:-—} | — | 1.29× | 1.17× |"
    echo
    echo "---"
    echo
    echo "**报告原始 CSV**：$BENCH_DIR/results/duration_*.csv"
  } > $REPORT
  chown hadoop:hadoop $REPORT
  
  ok "报告已生成：$REPORT"
  echo
  echo -e "${YELLOW}====== 报告预览 ======${NC}"
  cat $REPORT
}

# ====== 主入口 ======
case "$MODE" in
  all)
    preflight
    run_hdfs_gen
    run_hdfs_bench
    run_distcp
    run_cosn_setup
    run_cosn_bench
    gen_report
    ;;
  hdfs)
    preflight
    run_hdfs_gen
    run_hdfs_bench
    gen_report
    ;;
  cosn)
    preflight
    run_cosn_setup
    run_cosn_bench
    gen_report
    ;;
  distcp_then_cosn)
    preflight
    run_distcp
    run_cosn_setup
    run_cosn_bench
    gen_report
    ;;
  report)
    gen_report
    ;;
  *)
    echo "用法: $0 [all|hdfs|cosn|distcp_then_cosn|report]"
    exit 1
    ;;
esac

ok "✓ 全部完成！报告：$BENCH_DIR/results/2x2_matrix_report.md"
