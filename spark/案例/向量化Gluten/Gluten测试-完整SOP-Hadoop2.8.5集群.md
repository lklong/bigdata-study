# Gluten vs Native Spark 性能对比测试 — 完整 SOP

> **集群标识**：`43.143.233.211` (Hadoop 2.8.5 + Spark 3.5.3 + Gluten 1.5.0-SNAPSHOT)
> **维护人**：Eric（豹纹）/ 大哥
> **最后更新**：2026-05-24

---

## 一、目标

在 EMR Hadoop 2.8.5 集群上对比 **Native Spark** 与 **Spark + Gluten/Velox** 在 TPC-H 大数据量（200GB 规模）查询场景下的性能差异，验证向量化执行的加速效果。

---

## 二、环境信息（已就绪，勿再变动）

### 2.1 集群规格

| 项 | 值 |
|---|---|
| Master 节点 IP | `43.143.233.211` |
| 节点数 | 3 个 NodeManager |
| 单节点资源 | 64 vCores / 117965 MB (~115GB) |
| **集群总资源** | **192 vCores / ~345 GB** |
| Worker IP | `172.21.240.126` / `172.21.240.184` / `172.21.240.202` |

### 2.2 软件版本

| 组件 | 版本 | 路径 |
|---|---|---|
| Hadoop | **2.8.5** (EMR 内核) | `/usr/local/service/hadoop` |
| Spark | **3.5.3** (社区版，JDK17编译) | `/usr/local/service/spark` |
| Gluten | **1.5.0-SNAPSHOT** (Velox backend) | `/usr/local/service/spark/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar` |
| JDK 8 | TencentKona 8.0.21-442 | `/usr/lib/jvm/TencentKona-8.0.21-442` |
| JDK 17 | TencentKona 17.0.18.b1 | `/usr/lib/jvm/TencentKona-17.0.18.b1` |

> ⚠️ **关键约束**：
> - Spark 3.5.3 是 **JDK17 编译**的，driver 和 executor **必须**用 JDK17 启动，否则报 `NoSuchMethodError: java.nio.ByteBuffer.flip()`。
> - 系统默认 `JAVA_HOME` 是 JDK8，**提交脚本必须显式 export JDK17**。

### 2.3 备份/历史目录（仅参考，勿动）

| 路径 | 说明 |
|---|---|
| `/usr/local/service/spark.bak` | 老 EMR Spark 备份，含 Gluten 1.6.0 |
| `/usr/local/service/spark-3.5.3` | 早期 3.5.3 副本 |
| `/usr/local/service/spark-emr-3.5.3` | EMR 原版备份 |
| `/opt/spark-3.5.5-bin-hadoop3` | 社区 3.5.5 + Gluten 1.6.0 |
| `/opt/spark-3.5.8-bin-hadoop3` | 社区 3.5.8 + Gluten 1.6.0 |

---

## 三、测试数据（HDFS 上已生成）

### 3.1 数据位置与规模

```
HDFS: /bench/tpch_200g/
```

| 表 | 大小 | 行数估算 | Parquet 文件数 |
|---|---:|---:|---:|
| **lineitem** | **142.0 GB** | ~12 亿 | 513 个 part |
| orders | 46.7 GB | ~3 亿 | — |
| partsupp | 20.0 GB | ~1.6 亿 | — |
| part | 2.3 GB | ~4000 万 | — |
| customer | 1.2 GB | ~3000 万 | — |
| supplier | 74 MB | ~200 万 | — |
| nation | 15.4 KB | 25 | — |
| region | 5.2 KB | 5 | — |

**总计：~212 GB**（标准 TPC-H SF=200 规模）

### 3.2 数据格式

- 存储格式：**Parquet + Snappy 压缩**
- 副本数：**2**（节省空间）
- 单 part 文件大小：~290 MB（HDFS Block 友好）

### 3.3 关键表 DDL（标准 TPC-H 16列 lineitem）

```sql
-- lineitem 标准 16 列定义（与 TPC-H 官方 schema 完全一致）
CREATE TABLE lineitem (
    l_orderkey      BIGINT,
    l_partkey       BIGINT,
    l_suppkey       BIGINT,
    l_linenumber    INT,
    l_quantity      DECIMAL(12,2),
    l_extendedprice DECIMAL(12,2),
    l_discount      DECIMAL(12,2),
    l_tax           DECIMAL(12,2),
    l_returnflag    STRING,
    l_linestatus    STRING,
    l_shipdate      DATE,
    l_commitdate    DATE,
    l_receiptdate   DATE,
    l_shipinstruct  STRING,
    l_shipmode      STRING,
    l_comment       STRING
) USING parquet
LOCATION 'hdfs:///bench/tpch_200g/lineitem';
```

> 测试时使用 `parquet.\`/bench/tpch_200g/lineitem\`` 直接读取，无需 metastore 注册。

---

## 四、配置文件（已部署，勿改）

### 4.1 `spark-defaults.conf`（位于 `/usr/local/service/spark/conf/`）

```properties
# === 基础 ===
spark.driver.cores                    2
spark.driver.memory                   4g
spark.driver.extraJavaOptions         -Dlog4j.ignoreTCL=true -Dfile.encoding=utf-8
spark.eventLog.dir                    hdfs://HDFS8025737/spark-history
spark.eventLog.enabled                true
spark.history.fs.cleaner.enabled      true
spark.shuffle.service.enabled         true
spark.yarn.historyServer.address      http://172.21.240.101:10000
spark.hadoop.yarn.timeline-service.enabled   false

# === 动态分配（拉满集群）===
spark.dynamicAllocation.enabled       true
spark.dynamicAllocation.minExecutors  2
spark.dynamicAllocation.maxExecutors  180
spark.dynamicAllocation.initialExecutors  8

# === Executor（1:1.5 cpu:mem）===
spark.executor.cores                  4
spark.executor.memory                 6g
spark.executor.memoryOverhead         2g
spark.executor.extraJavaOptions       -Dlog4j.ignoreTCL=true -Dfile.encoding=utf-8
spark.executor.processTreeMetrics.enabled   true

# === Velox OffHeap ===
spark.memory.offHeap.enabled          true
spark.memory.offHeap.size             8g

# === Shuffle / 并行度 ===
spark.sql.shuffle.partitions          512
spark.sql.adaptive.enabled            true
spark.sql.adaptive.coalescePartitions.enabled   true

# === Native Lib Path ===
spark.driver.extraLibraryPath    /usr/local/service/hadoop/lib/native:/usr/local/service/hadoop/lib/native/Linux-amd64-64/lib
spark.executor.extraLibraryPath  /usr/local/service/hadoop/lib/native:/usr/local/service/hadoop/lib/native/Linux-amd64-64/lib
```

---

## 五、一键启动测试（核心）

### 5.1 启动入口（在 master 上执行）

```bash
# 必须用 hadoop 用户跑（HDFS /user/hadoop 已存在，root 没权限）
ssh root@43.143.233.211
su - hadoop
bash /bench/run_bench_hadoop3.sh
```

### 5.2 后台执行（电脑要关机时用这个）

```bash
ssh root@43.143.233.211 "su - hadoop -c 'nohup /bench/run_bench_hadoop3.sh > /bench/results/\$(date +%Y%m%d)/bench_main.log 2>&1 &'"
```

### 5.3 查看进度

```bash
# 实时跟踪
ssh root@43.143.233.211 "tail -f /bench/results/$(date +%Y%m%d)/bench_main.log"

# 看 YARN 任务
ssh root@43.143.233.211 "/usr/local/service/hadoop/bin/yarn application -list 2>/dev/null"

# 看每个 Q 的耗时
ssh root@43.143.233.211 "grep -E 'START|END|Time taken' /bench/results/$(date +%Y%m%d)/native_q*.log /bench/results/$(date +%Y%m%d)/gluten_q*.log"
```

---

## 六、测试脚本内容（`/bench/run_bench_hadoop3.sh`）

```bash
#!/bin/bash
# Gluten vs Native Benchmark - Hadoop2.8.5 Cluster
# 数据: /bench/tpch_200g/lineitem (142GB)
# 集群: 3节点 x 64core/115GB

# === 关键：必须用 JDK17 启动 driver ===
export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop
export HADOOP_HOME=/usr/local/service/hadoop
export LD_LIBRARY_PATH=$HADOOP_HOME/lib/native:$JAVA_HOME/lib/server:$JAVA_HOME/lib
export SPARK_HOME=/usr/local/service/spark
export PATH=$HADOOP_HOME/bin:$SPARK_HOME/bin:$PATH

GLUTEN_JAR=$SPARK_HOME/jars/gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar
DATA_DIR=/bench/tpch_200g/lineitem
LOGDIR=/bench/results/$(date +%Y%m%d)
mkdir -p $LOGDIR

# JDK17 必备的 add-opens
JVM_OPTS="--add-opens=java.base/java.nio=ALL-UNNAMED \
--add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.lang.invoke=ALL-UNNAMED"

# 资源对齐：Native 和 Gluten 用同一组参数，保证公平
MAX_EXEC=48          # 192core / 4core_per_exec = 48
EXEC_CORES=4
EXEC_MEM=6g
EXEC_OVERHEAD=2g
OFFHEAP=8g
SHUFFLE_PARTS=512

run_native() {
    local q=$1
    local sql=$2
    local LOG=$LOGDIR/native_q${q}.log
    echo ">>> NATIVE Q${q} START $(date)" | tee $LOG
    spark-sql --master yarn --deploy-mode client \
      --conf spark.dynamicAllocation.enabled=true \
      --conf spark.dynamicAllocation.maxExecutors=$MAX_EXEC \
      --conf spark.executor.cores=$EXEC_CORES \
      --conf spark.executor.memory=$EXEC_MEM \
      --conf spark.executor.memoryOverhead=$EXEC_OVERHEAD \
      --conf spark.memory.offHeap.enabled=true \
      --conf spark.memory.offHeap.size=$OFFHEAP \
      --conf spark.sql.shuffle.partitions=$SHUFFLE_PARTS \
      --conf "spark.driver.extraJavaOptions=${JVM_OPTS}" \
      --conf "spark.executor.extraJavaOptions=${JVM_OPTS}" \
      --conf spark.executorEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1 \
      --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1 \
      --name "TPCH-Native-Q${q}" \
      -e "$sql" 2>&1 | tee -a $LOG
    echo ">>> NATIVE Q${q} END $(date)" | tee -a $LOG
}

run_gluten() {
    local q=$1
    local sql=$2
    local LOG=$LOGDIR/gluten_q${q}.log
    echo ">>> GLUTEN Q${q} START $(date)" | tee $LOG
    spark-sql --master yarn --deploy-mode client \
      --conf "spark.plugins=org.apache.gluten.GlutenPlugin" \
      --conf "spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager" \
      --conf spark.driver.extraClassPath=$GLUTEN_JAR \
      --conf spark.executor.extraClassPath=$GLUTEN_JAR \
      --conf spark.dynamicAllocation.enabled=true \
      --conf spark.dynamicAllocation.maxExecutors=$MAX_EXEC \
      --conf spark.executor.cores=$EXEC_CORES \
      --conf spark.executor.memory=$EXEC_MEM \
      --conf spark.executor.memoryOverhead=$EXEC_OVERHEAD \
      --conf spark.memory.offHeap.enabled=true \
      --conf spark.memory.offHeap.size=$OFFHEAP \
      --conf spark.sql.shuffle.partitions=$SHUFFLE_PARTS \
      --conf "spark.driver.extraJavaOptions=${JVM_OPTS}" \
      --conf "spark.executor.extraJavaOptions=${JVM_OPTS}" \
      --conf spark.executor.extraLibraryPath=/usr/local/service/hadoop/lib/native \
      --conf spark.executorEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1 \
      --conf spark.executorEnv.LD_LIBRARY_PATH=/usr/local/service/hadoop/lib/native:/usr/lib/jvm/TencentKona-17.0.18.b1/lib/server \
      --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1 \
      --jars $GLUTEN_JAR \
      --name "TPCH-Gluten-Q${q}" \
      -e "$sql" 2>&1 | tee -a $LOG
    echo ">>> GLUTEN Q${q} END $(date)" | tee -a $LOG
}

# === 测试 SQL 集 ===
Q1="SELECT l_returnflag, l_linestatus, sum(l_quantity) sum_qty, sum(l_extendedprice) sum_base, avg(l_quantity) avg_qty, count(*) cnt FROM parquet.\`$DATA_DIR\` WHERE l_shipdate <= '1998-09-01' GROUP BY l_returnflag, l_linestatus ORDER BY l_returnflag, l_linestatus"
Q6="SELECT sum(l_extendedprice * l_discount) revenue FROM parquet.\`$DATA_DIR\` WHERE l_shipdate >= '1994-01-01' AND l_shipdate < '1995-01-01' AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24"
Q14="SELECT 100.00 * sum(CASE WHEN l_returnflag='R' THEN l_extendedprice * (1 - l_discount) ELSE 0 END) / sum(l_extendedprice * (1 - l_discount)) promo_revenue FROM parquet.\`$DATA_DIR\` WHERE l_shipdate >= '1995-09-01' AND l_shipdate < '1995-10-01'"

echo "========================================" | tee $LOGDIR/benchmark.log
echo "Benchmark Start @ $(date)" | tee -a $LOGDIR/benchmark.log
echo "Cluster: 3nodes x 64core/115GB | maxExec=$MAX_EXEC" | tee -a $LOGDIR/benchmark.log
echo "Data: $DATA_DIR (142GB lineitem)" | tee -a $LOGDIR/benchmark.log
echo "========================================" | tee -a $LOGDIR/benchmark.log

# 串行: Native -> Gluten 配对，每个 Q 跑完一对再下一个
for pair in "1:$Q1" "6:$Q6" "14:$Q14"; do
    q="${pair%%:*}"
    sql="${pair#*:}"
    echo "" | tee -a $LOGDIR/benchmark.log
    run_native "$q" "$sql"
    sleep 15
    run_gluten "$q" "$sql"
    sleep 15
done

echo "" | tee -a $LOGDIR/benchmark.log
echo "Benchmark Done @ $(date)" | tee -a $LOGDIR/benchmark.log
echo "Results: $LOGDIR" | tee -a $LOGDIR/benchmark.log
```

---

## 七、结果存放

| 内容 | 路径 |
|---|---|
| 主日志 | `/bench/results/YYYYMMDD/bench_main.log` |
| Native 各 Query 日志 | `/bench/results/YYYYMMDD/native_q{1,6,14}.log` |
| Gluten 各 Query 日志 | `/bench/results/YYYYMMDD/gluten_q{1,6,14}.log` |
| Spark History UI | `http://43.143.233.211:18080/` 或 `http://172.21.240.101:10000` |
| YARN UI | `http://43.143.233.211:8088/` |

### 7.1 提取关键耗时

```bash
ssh root@43.143.233.211 "
for f in /bench/results/$(date +%Y%m%d)/native_q*.log /bench/results/$(date +%Y%m%d)/gluten_q*.log; do
  echo '=== '\$f' ==='
  grep -E 'Time taken|Application report|Final-State' \$f | head -5
done"
```

---

## 八、踩坑记录（必看，避免重复掉坑）

| 坑 | 现象 | 解决 |
|---|---|---|
| **JDK 版本** | `NoSuchMethodError: ByteBuffer.flip()` | Spark 3.5.3 是 JDK17 编译的，driver 和 executor 必须用 JDK17，**显式 export JAVA_HOME** |
| **HDFS staging 权限** | `Permission denied: user=root, /user` | 用 `hadoop` 用户提交，或先 `hdfs dfs -mkdir /user/root && chown root /user/root` |
| **EMR Spark 不兼容 Gluten** | `HashAggregateExec.copy$default$9 NoSuchMethodError` | 用社区版 Spark，**不要用 `spark-emr-3.5.3`**（已改了 HashAggregateExec 增加 TopKSpec 参数） |
| **Worker 没 JDK17** | executor 启动失败 exit 50 | 三种方案：① 集群所有节点本地装 JDK17（当前用这个）；② `spark.yarn.dist.archives=hdfs:///bench/lib/jdk17.tar.gz#jdk17` 分发；③ 在 client 端打包分发 |
| **Velox OffHeap 失效** | Gluten 报 OOM 或没加速 | `spark.memory.offHeap.enabled=true` + `spark.memory.offHeap.size=8g`，且 executor.memoryOverhead 至少 2g |
| **Shuffle 分区太少** | 只有 4 个 task，并发拉不上去 | `spark.sql.shuffle.partitions=512`，`spark.dynamicAllocation.maxExecutors=48+` |
| **集群层配置改坏** | NodeManager 起不来 | yarn-site.xml/hdfs-site.xml 改之前先备份，**worker 和 master 配置可能不同**，不要 scp 覆盖 |

---

## 九、回滚 / 清理

```bash
# 清理测试数据（小心，142GB lineitem 重新生成要1小时+）
# /usr/local/service/hadoop/bin/hdfs dfs -rm -r -skipTrash /bench/tpch_200g

# 切换 spark 目录（如需要）
# /usr/local/service/spark        <- 当前 (3.5.3 + Gluten 1.5.0-SNAPSHOT)
# /usr/local/service/spark.bak    <- 备份的 EMR 版 (含 Gluten 1.6.0)
# /opt/spark-3.5.5-bin-hadoop3    <- 社区 3.5.5 + Gluten 1.6.0
# /opt/spark-3.5.8-bin-hadoop3    <- 社区 3.5.8 + Gluten 1.6.0
```

---

## 十、版本兼容性矩阵（验证过的）

| Spark | Gluten | JDK | Hadoop | 状态 |
|---|---|---|---|---|
| **3.5.3 社区** | **1.5.0-SNAPSHOT** | **17** | **2.8.5** | ✅ 当前生产用 |
| 3.5.3 EMR | 1.6.0 | 17 | 2.8.5 | ❌ HashAggregateExec 不兼容 |
| 3.5.5 社区 | 1.6.0 | 17 | 2.8.5 | ⚠️ 未充分验证 |
| 3.5.8 社区 | 1.6.0 | 17 | 2.8.5 | ⚠️ 未充分验证 |

---

## 附录 A：从零生成数据（如果数据丢了）

```bash
# 用 spark-sql 生成 200GB lineitem（约 30 亿行）
ssh root@43.143.233.211 "su - hadoop -c '
export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
/usr/local/service/spark/bin/spark-sql --master yarn \
  --conf spark.dynamicAllocation.maxExecutors=48 \
  --conf spark.executor.cores=4 \
  --conf spark.executor.memory=6g \
  -e \"
INSERT OVERWRITE DIRECTORY \\\"/bench/tpch_200g/lineitem\\\" USING parquet
SELECT 
  cast(l_orderkey as bigint), cast(l_partkey as bigint), cast(l_suppkey as bigint),
  cast(l_linenumber as int), cast(l_quantity as decimal(12,2)),
  cast(l_extendedprice as decimal(12,2)), cast(l_discount as decimal(12,2)),
  cast(l_tax as decimal(12,2)), l_returnflag, l_linestatus,
  cast(l_shipdate as date), cast(l_commitdate as date), cast(l_receiptdate as date),
  l_shipinstruct, l_shipmode, l_comment
FROM tpch_data_gen_function(scale_factor=200);
\"'"
```

> 实际生成方式参考 `/tmp/bench-2x2/gen_lineitem_std.scala`

---

**完成标志**：执行 `bash /bench/run_bench_hadoop3.sh` 后，在 `/bench/results/YYYYMMDD/` 下能看到所有 `native_q*.log` 和 `gluten_q*.log` 文件，且 `bench_main.log` 末尾显示 `Benchmark Done`。
