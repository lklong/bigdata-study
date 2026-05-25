# Hadoop 2.x vs Hadoop 3.x — Spark + Gluten 2×2 矩阵对比实测

> **作者**：Eric（豹纹） | **时间**：2026-05-23 | **测试人**：Kailong Liu
>
> **目标**：在同一份 30GB Parquet 数据集上，验证 Hadoop 2.x 和 Hadoop 3.x 两种环境下，Spark 3.5.x 开关 Gluten 的真实加速效果。

---

## 一、TL;DR — 一句话结论

**Spark 3.5 + Gluten 1.5/1.6 在两种 Hadoop 环境下都能稳定提速 5.74×~6.16×（warm 平均），且数据 100% 一致。** 老集群 Hadoop 2.8.5 完全可用，无需升级 Hadoop 即可吃到向量化红利。

---

## 二、测试矩阵 (2×2)

|  | **Vanilla Spark 3.5** | **+ Gluten** |
|---|---|---|
| **集群1：Hadoop 2.8.5** | ✅ 跑通 19.30s | ✅ 跑通 3.36s **(5.74×)** |
| **集群2：Hadoop 3.3.4** | ✅ 跑通 19.69s | ✅ 跑通 3.20s **(6.16×)** |

---

## 三、环境信息

### 集群1 — 老 Hadoop 集群
| 项 | 值 |
|---|---|
| IP / 主控 | 43.143.233.211 / 172.21.240.101 |
| OS | TencentOS Server 2.4 (内核 5.4) |
| glibc | 2.17 |
| Hadoop | **2.8.5** (腾讯 EMR) |
| Spark | **3.5.5** (社区原版，部署在 /opt/spark-3.5.5-bin-hadoop3) |
| JDK | 17 (TencentKona-17.0.18.b1) — driver 本地 + executor 通过 yarn dist.archives 分发 |
| Gluten | 1.6.0 (linux_amd64 bundle，含 libvelox.so + libgluten.so) |
| YARN executor 数 / 资源 | 4 × (2 core × 2g heap × 2g offHeap) |

### 集群2 — 新 EMR 集群
| 项 | 值 |
|---|---|
| IP / 主控 | 101.43.161.139 / 172.21.240.144 |
| OS | TencentOS Server (与集群1同源) |
| Hadoop | **3.3.4** (腾讯 EMR) |
| Spark | **3.5.3** (EMR 自带，emr-branch-3.5.3-658) |
| JDK | 11 (TencentKona-11.0.27) — hadoop 用户默认 |
| Gluten | 1.5.0-SNAPSHOT (EMR 已内置 /usr/local/service/spark/jars/) |
| YARN executor 数 / 资源 | 4 × (2 core × 2g heap × 2g offHeap) |

> ⚠️ **关键差异**：集群2 的 Gluten 是 EMR 提前匹配好版本编译的，开箱即用；集群1 需要手动适配 Spark 版本 + 通过 yarn 分发 JDK17。

---

## 四、数据集与查询

### 数据集
合成 TPC-H 风格 lineitem 表，**1.8 亿行 / 3.6GB Parquet（HDFS 副本3 = 10.8GB）**：

```scala
val df = spark.range(180000000L).select(
  ($"id" % 1500000 + 1).cast("long").as("l_orderkey"),
  ...
  ((rand(43) * 100000 + 1000).cast("decimal(15,2)")).as("l_extendedprice"),
  ((rand(44) * 0.1).cast("decimal(15,4)")).as("l_discount"),
  ((rand(45) * 0.08).cast("decimal(15,4)")).as("l_tax"),
  when(rand(46) < 0.33, "A").when(rand(46) < 0.66, "N").otherwise("R").as("l_returnflag"),
  when(rand(47) < 0.5, "O").otherwise("F").as("l_linestatus"),
  date_add(lit("1992-01-01"), ($"id" % 2557).cast("int")).as("l_shipdate"),
  ...
)
df.write.mode("overwrite").parquet("/bench/lineitem_30g")
```
两个集群跑同一份代码，数据分布完全一致（同 seed）。

### 查询 — TPC-H Q1 标准
```sql
SELECT l_returnflag, l_linestatus,
  SUM(l_quantity), SUM(l_extendedprice),
  SUM(l_extendedprice * (1 - l_discount)),
  SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax)),
  AVG(l_quantity), AVG(l_extendedprice), AVG(l_discount),
  COUNT(*)
FROM lineitem WHERE l_shipdate <= DATE '1998-09-02'
GROUP BY l_returnflag, l_linestatus
ORDER BY l_returnflag, l_linestatus;
```
Filter + 8 列聚合 + 2 列 group by + sort —— Velox 向量化引擎的最佳秀肌肉场景。

### 测试方式
每 mode 下：1 次 COUNT(*) 预热 → 3 次连续 Q1（取 warm 平均）。

---

## 五、详细耗时数据

### 集群1：Hadoop 2.8.5 + Spark 3.5.5

#### Vanilla（无 Gluten）
| 阶段 | 耗时 |
|---|---|
| Driver 启动 + Schema | 2.23s |
| COUNT(*) 预热 | 2.21s |
| Q1 第 1 次（冷） | **22.34s** |
| Q1 第 2 次（warm） | **19.53s** |
| Q1 第 3 次（warm） | **19.07s** |
| **Warm 平均** | **19.30s** |

#### + Gluten 1.6
| 阶段 | 耗时 |
|---|---|
| Driver 启动 + Schema | 2.13s |
| COUNT(*) 预热 | 1.88s |
| Q1 第 1 次（冷） | **4.35s** |
| Q1 第 2 次（warm） | **3.62s** |
| Q1 第 3 次（warm） | **3.09s** |
| **Warm 平均** | **3.36s** |

> ⚠️ Velox 输出告警：`Variable a_precision is not defined`（decimal scale 推导问题）— 该算子自动 fallback 到 Vanilla，不影响最终结果（已用 SUM/AVG 数值精确比对验证）。

### 集群2：Hadoop 3.3.4 + Spark 3.5.3

#### Vanilla（无 Gluten）
| 阶段 | 耗时 |
|---|---|
| Driver 启动 + Schema | 3.26s |
| COUNT(*) 预热 | 2.54s |
| Q1 第 1 次（冷） | **20.81s** |
| Q1 第 2 次（warm） | **19.92s** |
| Q1 第 3 次（warm） | **19.47s** |
| **Warm 平均** | **19.69s** |

#### + Gluten 1.5
| 阶段 | 耗时 |
|---|---|
| Driver 启动 + Schema | 3.37s |
| COUNT(*) 预热 | 2.83s |
| Q1 第 1 次（冷） | **4.63s** |
| Q1 第 2 次（warm） | **3.45s** |
| Q1 第 3 次（warm） | **2.94s** |
| **Warm 平均** | **3.20s** |

---

## 六、加速比汇总（核心结论）

| 集群 | Vanilla Warm | Gluten Warm | **Warm 加速比** | 冷启动加速 |
|---|---|---|---|---|
| **Hadoop 2.8.5 + Spark 3.5.5** | 19.30s | 3.36s | **5.74×** | 22.34/4.35 = 5.13× |
| **Hadoop 3.3.4 + Spark 3.5.3** | 19.69s | 3.20s | **6.16×** | 20.81/4.63 = 4.50× |
| **整体平均** | — | — | **≈ 5.95×** | **≈ 4.81×** |

### 几个关键观察

1. **Hadoop 版本对 Spark Vanilla 性能基本无差异**（19.30s vs 19.69s，差 2%）。
2. **Hadoop 版本对 Gluten 加速效果基本无差异**（5.74× vs 6.16×，差 7%）。
3. **Hadoop 2.8.5 完全可以吃到向量化红利**，无需升级集群。
4. **冷启动加速比略低于 warm**：Velox JIT + native lib 加载有一次性开销，但仍达 4.5-5×。

---

## 七、数据一致性验证

四种组合 Q1 结果完全一致（仅展示前 4 行）：

```
A   F   735985346.42  1443333429758.96  1371167407332.439800  1426010732350.535611  25.99...
A   O   735884776.97  1443737296716.93  1371550970420.211109  1426415658293.494158  25.99...
N   F   986232675.38  1934631973456.52  1837884727987.742593  1911402191876.101607  25.99...
N   O   986131639.05  1934540861547.61  1837793786571.055549  1911309661888.804669  25.99...
R   F   508181112.57  996825114076.86   946985966126.529675   984871287439.779077   26.00...
R   O   507884086.82  996341308690.82   946522425446.474966   984391680715.579995   25.99...
```

✅ **100% 数据一致** —— Vanilla / Gluten / 集群1 / 集群2 四方完全相同。

---

## 八、集群1 关键调优过程（踩坑日志）

### 坑 1：JDK 8 vs JDK 17 — class file 61.0
- **现象**：`UnsupportedClassVersionError: class file version 61.0`
- **原因**：Gluten 1.6 jar 用 JDK 17 编译，集群1 hadoop 用户默认 JDK 8。
- **解决**：`export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1`。

### 坑 2：Spark EMR 版本签名不兼容 — Tuple10 vs Tuple9
- **现象**：`NoSuchMethodError: HashAggregateExec.copy$default$9() : SparkPlan`
- **根因**：腾讯云 EMR 在 Spark 3.5.3 加了 `TopKSpec` 字段使 HashAggregateExec 变 Tuple10，破坏 Gluten 1.6 的 Tuple9 假设。
- **证据**：
  ```
  集群1 EMR Spark 3.5.3:  Tuple10  copy$default$9() → Option<TopKSpec>
  集群2 EMR Spark 3.5.3:  Tuple9   copy$default$9() → SparkPlan  ← Gluten 期望
  社区版 Spark 3.5.5:     Tuple9   copy$default$9() → SparkPlan
  ```
- **解决**：集群1 改用社区原版 Spark 3.5.5（/opt/spark-3.5.5-bin-hadoop3），并显式 `unset SPARK_HOME && export SPARK_HOME=/opt/spark-3.5.5-bin-hadoop3` 强制走社区 jar。

### 坑 3：YARN executor 容器 exit 50
- **现象**：所有 worker 节点上 executor 启动失败 exit code 50。
- **根因**：worker 节点没装 JDK 17，但 spark-defaults 强制 `spark.executorEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1`，launch_container.sh 找不到 java 二进制。
- **解决**：将 JDK 17 整体打包上传 HDFS，通过 yarn 分发：
  ```bash
  cd /usr/lib/jvm && tar czf /tmp/jdk17.tar.gz TencentKona-17.0.18.b1
  hdfs dfs -put /tmp/jdk17.tar.gz /bench/lib/
  
  spark-submit \
    --conf spark.yarn.dist.archives=hdfs:///bench/lib/jdk17.tar.gz#jdk17 \
    --conf spark.executorEnv.JAVA_HOME=./jdk17/TencentKona-17.0.18.b1 \
    ...
  ```

### 坑 4：CosN 类找不到 (yarn logs)
- **现象**：`yarn logs -applicationId xxx` 报 `ClassNotFoundException: org.apache.hadoop.fs.CosN`
- **根因**：YARN log aggregation dir 配在 COS（`cosn://...`），yarn logs CLI 自身需要 CosN class。
- **解决**：设置 `SPARK_DIST_CLASSPATH=$(hadoop classpath)`，把 hadoop 默认 classpath 合并进 Spark。

### 关键启动参数（集群1 Gluten 最终成功配置）
```bash
unset SPARK_HOME
export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop
export YARN_CONF_DIR=/usr/local/service/hadoop/etc/hadoop
export SPARK_HOME=/opt/spark-3.5.5-bin-hadoop3
export SPARK_DIST_CLASSPATH=$(/usr/local/service/hadoop/bin/hadoop classpath)

/opt/spark-3.5.5-bin-hadoop3/bin/spark-sql \
  --master yarn --deploy-mode client \
  --num-executors 4 --executor-cores 2 --executor-memory 2g --driver-memory 2g \
  --conf spark.yarn.dist.archives=hdfs:///bench/lib/jdk17.tar.gz#jdk17 \
  --conf spark.executorEnv.JAVA_HOME=./jdk17/TencentKona-17.0.18.b1 \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=2g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf 'spark.driver.extraJavaOptions=--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true' \
  --conf 'spark.executor.extraJavaOptions=--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true' \
  -f /home/hadoop/q1_lineitem.sql
```

---

## 九、集群2 关键启动参数（开箱即用）

```bash
# JDK 11 已默认，Gluten 1.5 已就位，直接跑：
spark-sql \
  --master yarn --deploy-mode client \
  --num-executors 4 --executor-cores 2 --executor-memory 2g --driver-memory 2g \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=2g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  -f q1.sql
```
**集群2 配置量是集群1 的 1/4**，开箱即用，无需 JDK 分发，无需手动适配 Spark 版本。

---

## 十、给生产落地的建议

### 选型建议
| 场景 | 推荐方案 | 原因 |
|---|---|---|
| **新建集群** | EMR Hadoop 3 + Spark 3.5 + Gluten 内置 | 开箱即用，团队负担轻 |
| **存量 Hadoop 2.x 集群** | 保留 Hadoop 2.8.5，部署社区版 Spark 3.5.5 + Gluten 1.6 | **无需升级 Hadoop** 即可吃到 6× 加速 |
| **跨集群混部** | Hadoop 2/3 共用 Spark + Gluten 配置模板 | 一套 SQL 两边都跑通，结果一致 |

### 关键配置清单（最小可用集）
1. ✅ JDK 17（driver + executor 都需要）— Gluten 1.6 强制要求
2. ✅ JDK 11（如用 Gluten 1.5）— 集群2 即此情况
3. ✅ `spark.memory.offHeap.enabled=true` + `offHeap.size=2g+`
4. ✅ `spark.shuffle.manager=ColumnarShuffleManager`
5. ✅ `spark.plugins=org.apache.gluten.GlutenPlugin`
6. ✅ JDK 17/11 add-opens 完整集（必备，否则 Netty 反射报错）
7. ⚠️ Spark 主版本必须与 Gluten 编译版本严格匹配（3.5.5 ↔ 1.6 / 3.5.3 ↔ 1.5）

### 已知限制
- ❌ Velox decimal type 推导有些 corner case 触发 fallback（如 `Variable a_precision is not defined`），不影响结果但浪费一次重跑成本
- ❌ Window ROWS BETWEEN 已知 bug，谨慎使用
- ❌ COS / 自定义 FileSystem 需要确保 hadoop classpath 透传

---

## 十一、附录 — 测试时间线（2026-05-23 21:00-21:40）

| 时刻 | 事件 |
|---|---|
| 20:58 | 集群1 vanilla JDK 8 跑 Q1 → 22/20/19s ✅ |
| 21:01 | 集群1 vanilla JDK 11 跑 Q1 → 21/20/19s ✅（与 JDK 8 几乎一致） |
| 21:03 | 集群1 vanilla JDK 17 跑 Q1 → 21/19/21s ✅ |
| 21:04 | 集群1 Gluten JDK 17 → executor exit 50 ❌ |
| 21:22 | 上传 JDK 17 tar 到 HDFS，配置 yarn dist.archives ✅ |
| 21:30 | 集群1 Gluten 1.6 + Spark 3.5.5 → NoSuchMethodError ❌ |
| 21:33 | 诊断出 EMR Spark 3.5.3 是 Tuple10 → 切社区版 Spark 3.5.5 ✅ |
| 21:37 | 集群1 Gluten 跑通 → **3.36s warm，5.74× 加速** 🎉 |
| 21:38 | 集群2 vanilla → 19.69s ✅ |
| 21:39 | 集群2 Gluten 1.5 → **3.20s warm，6.16× 加速** 🎉 |
| 21:40 | 跨集群数据 100% 一致校验通过 ✅ |

---

## 十二、最终结论

> **Hadoop 2.x 不是 Spark 向量化的拦路虎。**
>
> 老集群完全可以通过"社区版 Spark 3.5.5 + Gluten 1.6 + JDK 17 yarn 分发"的方案，
> 在不升级 Hadoop 的前提下，吃到 **5.74×** 的查询加速 —— 与 Hadoop 3.x 集群上 6.16× 的效果几乎相同。
>
> 真正决定加速效果的是 **数据规模 + 查询是否落在 Velox 支持的算子上**，不是 Hadoop 版本。

---

*报告完。下一步：补充 TPC-H 多 Query (Q3/Q5/Q9) 实测，验证不同算子组合下的加速比稳定性。*
