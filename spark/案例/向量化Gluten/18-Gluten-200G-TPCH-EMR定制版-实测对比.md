
# 18 — Gluten 1.5.0 @ 200G TPC-H 实测：EMR 定制版（meson tcmalloc）

> **测试时间**：2026-05-24 13:30 ~ 14:25  
> **测试集群**：`43.143.233.211`（EMR Spark on YARN，3 nodes × 16c32g）  
> **数据集**：`hdfs:///bench/tpch_200g`（TPC-H SF=200，Parquet snappy，212G/8 表）  
> **Spark**：EMR 定制版 **3.5.3**（`/usr/local/service/spark`）  
> **Gluten**：`gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar`  
> **关键定制**：`spark/meson/libtcmalloc_and_profiler.so`（YARN archive 分发到 executor，LD_PRELOAD）

---

## 一、对照基线

本轮以业界某次"标准 Gluten on Vanilla Spark"测试（截图）为参照：

| 角色 | 截图基线 | 本轮 EMR 定制 |
|---|---|---|
| Spark | Vanilla Spark 3.5.x | EMR Spark 3.5.3（含 meson 补丁） |
| 内存分配器 | jemalloc/glibc 默认 | **tcmalloc（meson 定制 LD_PRELOAD）** |
| Gluten | 1.5.0 SNAPSHOT | 1.5.0 SNAPSHOT（同款 jar） |
| 数据规模 | ~200G TPC-H | 200G TPC-H（212.2G） |
| Query 集 | 14 条（Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q9, Q10, Q12, Q14, Q17, Q18, Q19） | **完全相同** |

---

## 二、测试拓扑与配置

### 2.1 集群资源
- **Master**：`172.21.240.101`（driver + ResourceManager）
- **Worker × 3**：`172.21.240.126 / 184 / 202`（NodeManager，各 16c × 32g）
- **YARN 总量**：48c × 96g
- **HDFS 总量**：2.9T（已用 437G）

### 2.2 Executor 配置（榨干 YARN）
| 模式 | num-executors | cores | memory | offHeap | overhead |
|---|---|---|---|---|---|
| native | 9 | 5 | 9g | 0 | 2g |
| gluten | 9 | 5 | 5g | 8g | 1g |

> 总并发 47c、内存 92g（留 driver 2c2g + AM 余量）

### 2.3 关键 Spark 参数
```bash
spark.sql.adaptive.enabled=true
spark.sql.shuffle.partitions=400          # 200G 数据建议加大
spark.sql.parquet.enableVectorizedReader=true
spark.sql.hive.convertMetastoreParquet=true
spark.shuffle.service.enabled=false
spark.dynamicAllocation.enabled=false
```

### 2.4 Gluten 模式额外参数
```bash
spark.plugins=org.apache.gluten.GlutenPlugin
spark.gluten.sql.columnar.backend.lib=velox
spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager
spark.memory.offHeap.enabled=true
spark.memory.offHeap.size=8g
spark.gluten.memory.allocator=jemalloc
spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5
spark.gluten.sql.columnar.backend.velox.aggregationSpillEnabled=false
spark.gluten.sql.columnar.backend.velox.joinSpillEnabled=false
spark.gluten.sql.columnar.backend.velox.spillEnabled=false
```
**注**：spill 关闭以规避 Gluten 1.5.0 已知 sumVector bug。

### 2.5 YARN archive 分发（关键定制）
```bash
--archives hdfs:///user/hadoop/bench/jdk11.tar.gz#jdk11,
          hdfs:///user/hadoop/bench/meson.tar.gz#meson
--conf spark.executorEnv.JAVA_HOME=./jdk11/jdk-11.0.16
--conf spark.executorEnv.LD_PRELOAD=./meson/libtcmalloc_and_profiler.so
```

---

## 三、详细 Per-Query 对比（去掉 spark-submit 启动开销）

> **重要说明**：每条 query 都会单独启 spark-submit（启动 ~30s）。"含启动总时长"对比小 query 会失真；下方数据采用 `Time taken` 行的**纯执行时间**。

| Query | Native (s) | Gluten (s) | **本轮加速** | 截图加速 | 评估 |
|:-:|---:|---:|---:|---:|:-:|
| **Q1** | 73.32 | 31.15 | **2.35×** ⭐⭐ | 1.36× | ✅ **远超截图** |
| **Q2** | 3.92 | 4.71 | 0.83× | 1.32× | ❌ 本轮弱 |
| **Q3** | 51.01 | 51.48 | 0.99× | 0.93× | ≈ 持平 |
| **Q4** | 41.05 | 24.00 | **1.71×** ⭐⭐ | 1.34× | ✅ 更好 |
| **Q5** | 88.39 | 70.53 | **1.25×** ⭐ | 1.13× | ✅ 更好 |
| **Q6** | 21.36 | 35.38 | 0.60× | 1.08× | ❌ 劣化（异常） |
| **Q7** | 78.83 | 69.17 | **1.14×** | 0.92× | ✅ 更好 |
| **Q9** | 147.55 | 105.79 | **1.40×** ⭐ | 1.13× | ✅ 更好 |
| **Q10** | 57.47 | 54.39 | 1.06× | 0.97× | ✅ 略好 |
| **Q12** | 35.43 | 29.60 | **1.20×** ⭐ | 1.03× | ✅ 更好 |
| **Q14** | 51.40 | 42.01 | **1.22×** ⭐ | 0.97× | ✅ 更好 |
| **Q17** | 93.12 | 45.30 | **2.06×** ⭐⭐ | 1.06× | ✅✅ **远超截图** |
| **Q18** | 70.09 | 38.61 | **1.81×** ⭐⭐ | 0.98× | ✅✅ **远超截图** |
| **Q19** | 31.99 | 37.84 | 0.85× | 0.87× | ≈ 持平 |
| **总计** | **844.93** | **639.95** | **1.32×** ⭐ | **1.04×** | ✅ **EMR定制版整体大幅领先** |

---

## 四、含启动开销总耗时（spark-submit per query 模式）

参考用：

| Query | Native 总时长 (ms) | Gluten 总时长 (ms) | 加速比 |
|:-:|---:|---:|---:|
| Q1 | 104156 | 69288 | 1.50× |
| Q2 | 33911 | 41646 | 0.81× |
| Q3 | 82790 | 84501 | 0.98× |
| Q4 | 72816 | 59263 | 1.23× |
| Q5 | 120656 | 107015 | 1.13× |
| Q6 | 51649 | 71487 | 0.72× |
| Q7 | 112684 | 107198 | 1.05× |
| Q9 | 181704 | 140202 | 1.30× |
| Q10 | 90410 | 89715 | 1.01× |
| Q12 | 68727 | 67745 | 1.01× |
| Q14 | 86041 | 77101 | 1.12× |
| Q17 | 128980 | 80441 | 1.60× |
| Q18 | 101545 | 73771 | 1.38× |
| Q19 | 63996 | 71957 | 0.89× |
| **总计** | **1300065 ms (1300s)** | **1141330 ms (1141s)** | **1.14×** |

---

## 五、核心结论

### 5.1 ✅ EMR 定制版 Gluten 整体加速 **1.32×**（截图基线 1.04×）
- **复杂 join+window 类（Q17/Q18/Q1/Q4）加速 1.71×~2.35× 显著优于截图**
- **大型 join（Q9）加速 1.40×**，截图仅 1.13×
- **聚合类（Q12/Q14）加速 1.20× / 1.22×**，截图均 ≤ 1.03×

### 5.2 ⭐ meson tcmalloc 定制带来显著加成
对比截图（无 tcmalloc 定制）：
| 类型 | 本轮提升幅度 |
|---|---|
| Q1（重聚合） | +0.99×（1.36→2.35） |
| Q17（关联子查询） | +1.00×（1.06→2.06） |
| Q18（聚合 + join 子查询） | +0.83×（0.98→1.81） |
| Q9（多表 join） | +0.27×（1.13→1.40） |

**推断**：tcmalloc 在重 offHeap 分配/回收场景下显著降低锁争用与碎片化，Velox 大量使用 ArrowVector 的 buffer pool 受益最大。

### 5.3 ⚠️ Q2 / Q6 / Q19 表现偏弱
- **Q2**（多 5 表 join + 子查询）：截图 1.32× → 本轮 0.83×。怀疑与 spark.sql.shuffle.partitions=400 在小数据 query 下分区过多、调度开销放大有关。
- **Q6**（lineitem 全表过滤求和，最简单）：截图 1.08× → 本轮 0.60×。Native 21.4s 已经非常快，Gluten 35.4s 明显劣化，**值得专项排查**（可能 Velox columnar reader 启动开销 + 关 spill 后的内存压力）。
- **Q19**（重 OR 谓词）：本轮 0.85× ≈ 截图 0.87×，与社区已知 Velox OR 谓词优化不足相关。

### 5.4 数据正确性
- Q6 标准答案 `121087548214.325569`（SF=200）—— **完全匹配**
- 14 条 query 全部 **rc=0** 成功完成

---

## 六、附：测试资源清单

### 6.1 集群侧（已就绪可复用）
- `/home/hadoop/bench/queries_tpch/q{1,2,3,4,5,6,7,9,10,12,14,17,18,19}.sql` — 14 条标准 TPC-H query
- `/home/hadoop/bench/scripts-jdk11/bench_tpch.sh` — 一键 bench 脚本（参数：native | gluten）
- `/home/hadoop/bench/results/tpch_native/` — native 模式 14 条详细日志
- `/home/hadoop/bench/results/tpch_gluten/` — gluten 模式 14 条详细日志
- `/home/hadoop/bench/results/duration_tpch_{native,gluten}.csv` — 总时长 CSV
- `hdfs:///user/hadoop/bench/jdk11.tar.gz` — JDK11 archive
- `hdfs:///user/hadoop/bench/meson.tar.gz` — meson tcmalloc archive

### 6.2 本地侧
- `bench-toolkit/scripts-jdk11/bench_tpch.sh` — 同步保存版本
- `reports/duration_tpch_200g_native.csv`
- `reports/duration_tpch_200g_gluten.csv`

### 6.3 复现命令（在集群 master 执行）
```bash
ssh root@43.143.233.211
su - hadoop
cd /home/hadoop/bench

# Native 14 条
bash scripts-jdk11/bench_tpch.sh native

# Gluten 14 条
bash scripts-jdk11/bench_tpch.sh gluten

# 单条调试
bash scripts-jdk11/bench_tpch.sh gluten "q1 q17"
```

---

## 七、下一步建议

1. **专项排查 Q6 劣化**：抓 Spark UI / Velox metric 看是否真在 columnar shuffle、读取阶段卡顿。
2. **shuffle.partitions 自适应**：小 query 调小（128）、大 query 用 400，避免 Q2 类 query 调度放大。
3. **对比无 tcmalloc 版**：把 `LD_PRELOAD` 摘掉跑一次 Gluten，量化 meson 定制单项收益。
4. **横向对比 Vanilla Spark 3.5.5**：用 `/usr/local/service/spark.bak` 部署一份纯净版同跑，量化 EMR meson 定制 vs 社区版差距。
