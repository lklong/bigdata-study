# H2/H3 Gluten 测试执行脚本（产出）

## 文件说明

| 文件 | 用途 | 状态 |
|---|---|---|
| `run_h2_emr_group2_baseline.sh` | **组2** H2 + EMR Spark 3.5.3 + Gluten 1.5.0 vs Native | ✅ 已跑通（28/28，平均加速 1.29×） |
| `run_h3_group3_pure.sh` | **组3** H3 + EMR Spark 3.5.3 + Gluten 1.5.0 vs Native | ✅ 已跑通（28/28，平均加速 1.31×） |
| `run_h2_gluten.sh` | **组1** H2 + 社区版 Spark 3.5.8 + Gluten 1.6.0 (gluten 单独脚本) | 🔄 调试中 |
| `spark358_defaults.conf` | 社区版 Spark 3.5.8 的 spark-defaults.conf（合并 EMR 关键配置） | 🔄 调试中 |

## 三组测试矩阵

| 组 | 集群 | Hadoop | Spark | Gluten | JDK | 数据 |
|---|---|---|---|---|---|---|
| 组1 | H2 (82.156.188.226) | 2.8.5 | 3.5.8 社区版 | 1.6.0 | Kona JDK17 | cosn |
| 组2 | H2 (82.156.188.226) | 2.8.5 | 3.5.3 EMR | 1.5.0-SNAPSHOT | Kona JDK11 | cosn |
| 组3 | H3 (43.143.253.239) | 3.3.4 | 3.5.3 EMR | 1.5.0-SNAPSHOT | Kona JDK11 | cosn |

## 集群资源

- 两个集群完全对等：3 节点 × 32 vCores × 117GB ≈ **96c / 345GB**
- 数据：`cosn://lkl-bj-update-1308597516/meson/data/bench/`（5 表 / 29 亿行 / 91.7GB）

## 测试规模

- 7 个 TPC-H Query (q1_agg, q2_join_2tables, q3_join_3tables, q4_window, q5_subquery, q6_self_join, q7_5tables)
- 每个 Q 跑 2 轮取最小值
- Native + Gluten 各 2 轮 = 28 次提交/组

## 关键设计原则（纯净测试）

1. **不动集群默认 JDK / spark conf**（H2/H3 都是 EMR 装好的状态）
2. **JDK 通过 HDFS archive 分发到 executor**：
   - HDFS 上传：`hadoop fs -put kona-jdk{11,17}.tar.gz /bench/lib/`
   - spark-submit 用 `--archives hdfs:///bench/lib/jdk17.tar.gz#jdk` + `spark.executorEnv.JAVA_HOME=./jdk/TencentKona-17.0.18.b1`
3. **Gluten so 文件已在 jar 内**（97MB jar，包含 libvelox.so 等）
4. **Gluten jar 通过 `--jars` 唯一分发**（不放进 `$SPARK_HOME/jars/` 避免重复加载）
5. **关闭 external shuffle service**（`spark.shuffle.service.enabled=false`），让 Gluten ColumnarShuffleManager 不被 NM 上的旧 shuffle service 拒绝

## 关键踩坑（组1 调试历程）

| 版本 | 问题 | 解决 |
|---|---|---|
| v1 | offHeap 8g, gluten q1_agg hang 3.5h | NOOP arbitrator 默认只用 768MB |
| v2 | 加大 overhead + dynamic sizing | 仍 timeout 15min |
| v3 | 加 tcmalloc + meson archive | 仍 hang，hive metastore 未配 |
| v4 | 复制 EMR hive-site.xml + 加 add-opens | bash 引号问题 |
| v4.1 | 引号修复 | HDFS archive 路径写错 |
| v4.2 | HDFS 路径修复，6×2c×2g 小资源 | 跑到 q3 时 executor OOM lost |
| v5 | 拉满到 24×4c×8g, dynamic sizing | Velox 实际只用 3GB（ignored offHeap） |
| v6 | 去掉 dynamic sizing, offHeap=8g 真生效 | shuffle service 不识别 ColumnarShuffleManager |
| v7（当前） | 加 `spark.shuffle.service.enabled=false`、Gluten jar 移出 spark/jars/、去 extraClassPath | 等验证 |

## 用法

### 组2（H2 EMR Spark 3.5.3 + Gluten 1.5.0）
```bash
bash /home/hadoop/bench/scripts/run_h2_emr.sh
```

### 组3（H3 EMR Spark 3.5.3 + Gluten 1.5.0）
```bash
bash /home/hadoop/bench/scripts/run_group3_pure.sh
```

### 组1（H2 社区版 Spark 3.5.8 + Gluten 1.6.0，gluten 单独）
```bash
# 跑全部 7Q × 2 round
bash /home/hadoop/bench/scripts/run_h2_gluten.sh

# 单 Q 调试
bash /home/hadoop/bench/scripts/run_h2_gluten.sh q1_agg 1
```

## 资源利用

- Native (H2/H3 EMR): 9 executor × 5c × 9g = 45c/81GB（1/2 利用率）
- Gluten (H2/H3 EMR): 9 executor × 5c × 5g + 8g offheap = 45c/117GB
- Gluten (H2 社区版 v7): 24 executor × 4c × 6g + 2g overhead + 8g offheap = 96c/384GB（拉满）

## 结果路径

集群上：
- H2: `/home/hadoop/bench/results/duration_group{1,2}_*.csv`
- H3: `/home/hadoop/bench/results/duration_group3_*.csv`

本地：
- `/Users/kailongliu/CodeBuddy/20260516092456/向量化Gluten/results-h2/`
- `/Users/kailongliu/CodeBuddy/20260516092456/向量化Gluten/results-h3/`
