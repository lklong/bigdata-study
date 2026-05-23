# Spark 3.5.3 + Gluten 1.5 在 62.234.130.135（Hadoop 2.8.5 / Hive 2.3.7）部署实测

> **日期**：2026-05-23 21:49  
> **目标机**：62.234.130.135（master 172.21.240.111 + 3 worker 41/24/246）  
> **服务对象**：大哥（Kailong Liu）  
> **执行人**：Eric（豹纹）SSH 远程上机直连  
> **耗时**：约 30 分钟（含踩坑）  
> **结果**：✅ 跑通，物理计划全栈 Velox*Transformer 化

---

## 〇、一句话结论

> **走"从已有 EMR 节点拷贝"路线 30 分钟搞定**，比下载 Apache 官方包 + Gluten release jar 自己组装更快。  
> **唯一的坑**：腾讯云 EMR 编译的 Spark 3.5.3 jar 字节码用了 JDK 9+ 的 ByteBuffer.flip 签名，**JDK 8 跑不了，必须 JDK 11**。  
> 集群所有节点装 Tencent Kona JDK 11 即可，yum 仓库里就有 `java-11-konajdk`。

---

## 一、目标集群环境画像

| 项 | 现状 |
|---|---|
| 节点 | 4 节点（1 master + 3 worker） |
| OS | TencentOS 2.4（基于 RHEL 7） |
| CPU | AMD EPYC 9K65 32 核（含 AVX2/AVX/BMI2/F16C） |
| 内存 | 123 GB / 节点 |
| 磁盘 | /data 500GB（NVMe 推荐） |
| **现有 Spark** | **3.0.2**（旧，要替换） |
| **Hadoop** | **2.8.5**（不动） |
| **Hive** | **2.3.7**（不动） |
| **JDK** | Tencent Kona 8（要补 JDK 11） |
| HDFS NN | hdfs://172.21.240.111:4007 |
| 现有 spark-history | hdfs:///spark-history |

---

## 二、为啥选"从已有节点拷贝" vs 下载预编译

### 路径 A：apache 官方 + Gluten release jar
- Spark 3.5.5 官方包 + gluten-velox-bundle-spark3.5_2.12-centos_7_x86_64-1.5.0.jar
- 优点：版本可控、文档全
- 缺点：还要解决 JDK、netty 反射、shuffle 协议等"组合配置坑"

### 路径 B（**本次走的**）：从 EMR 节点 101.43.161.139 拷贝 `/usr/local/service/spark/`
- 源机：腾讯云 EMR 节点，Spark 3.5.3（emr-release/emr-branch-3.5.3-658）
- jar 自带：`gluten-velox-bundle-spark3.5_2.12-linux_amd64-1.5.0-SNAPSHOT.jar` ✅
- 优点：腾讯 EMR 团队**已经把 Gluten + Velox + tcmalloc + 反射开关**都调通了，**直接抄作业**
- 缺点：源机配置（NN 地址/HistoryServer 地址）要手动改

**结论**：能抄作业就抄作业，省 4-6 小时编译 + 调坑。

---

## 三、踩坑实录（关键！）

### 坑 1：源机 → 目标机内网不通

源机 IDC 内网安全组限制，无法直连目标机 22 端口。**绕路**：本地 macOS 中转（也可用大哥的工蜂跳板机）。

```bash
# 源机 → 本地
sshpass -p '****' scp root@101.43.161.139:/data/spark.tgz ./
# 本地 → 目标机
sshpass -p '****' scp ./spark.tgz root@62.234.130.135:/home/hadoop/
```

### 坑 2（最大）：JDK 8 跑不动 EMR 编译的 Spark 3.5.3 jar

**症状**：
```
java.lang.NoSuchMethodError: java.nio.ByteBuffer.flip()Ljava/nio/ByteBuffer;
   at org.apache.spark.util.io.ChunkedByteBufferOutputStream.toChunkedByteBuffer
```

**根因**：
- spark-core_2.12-3.5.3.jar 的 class 文件 magic = `cafe babe 0000 0034`（JDK 8 编译）
- 但字节码中 `ByteBuffer.flip()` 方法引用的返回类型签名是 `Ljava/nio/ByteBuffer;`（**JDK 9+ covariant return 形态**）
- JDK 8 的 ByteBuffer.flip() 返回 `Buffer`（**没这个签名**）→ NoSuchMethodError
- 推断：腾讯 EMR 编译时 javac 加 `--release 8`，但 classpath 接了 JDK 11 的 rt.jar，导致字节码"半 JDK 8 + 半 JDK 11"

**解法**：装 **Tencent Kona JDK 11**，所有节点都要装。

```bash
# tlinux 仓库自带 java-11-konajdk
yum install -y java-11-konajdk
# 实际路径
ls -d /usr/lib/jvm/TencentKona-11.0.30.b1
ls -l /usr/lib/jvm/java-11   # → /usr/lib/jvm/TencentKona-11.0.30.b1
```

### 坑 3：worker 节点 launch_container 报 java 找不到

**症状**：
```
Container exited with exit code 127
/bin/bash: /usr/lib/jvm/java-11-openjdk-...: 没有那个文件或目录
```

**根因**：master 装了 OpenJDK 11，worker 没装。

**解法**：所有 4 个节点（master + 3 worker）都 yum install。**推荐用 Kona 11**（避免 OpenJDK 路径变 + brand 统一）。

### 坑 4：master 到 worker 没免密 ssh

**绕开**：master 装 sshpass，用密码远程批量执行：
```bash
yum install -y sshpass
for h in 172.21.240.41 172.21.240.24 172.21.240.246; do
  sshpass -p '****' ssh -o StrictHostKeyChecking=no root@$h \
    'yum install -y java-11-konajdk'
done
```

### 坑 5：源机 spark-defaults.conf 里写死了源机 NN/HistoryServer 地址

源机：`spark.eventLog.dir = hdfs://HDFS8028747/spark-history`  
目标机：`spark.eventLog.dir = hdfs://172.21.240.111:4007/spark-history`

```bash
sed -i 's|hdfs://HDFS8028747/spark-history|hdfs://172.21.240.111:4007/spark-history|g' \
  $SPARK_HOME/conf/spark-defaults.conf $SPARK_HOME/conf/spark-env.sh
sed -i 's|http://172.21.240.144:10000|http://172.21.240.111:10000|g' \
  $SPARK_HOME/conf/spark-defaults.conf
# 删掉源机的 JMX 端口（避免端口冲突）
sed -i 's| -Dcom.sun.management.jmxremote .*-Dcom.sun.management.jmxremote.ssl=false||g' \
  $SPARK_HOME/conf/spark-env.sh
```

### 坑 6：LD_PRELOAD libtcmalloc 在 worker 找不到

**症状**：`ERROR: ld.so: object '...libtcmalloc_and_profiler.so' from LD_PRELOAD cannot be preloaded: ignored.`

**实情**：master 上有 `/usr/local/service/spark/meson/libtcmalloc_and_profiler.so`（拷贝包带了），但 worker 上没 spark 目录 → 报 warning。**不影响执行**，可暂时忽略。

**彻底解决**：要么把 spark 也部署到所有 worker 上，要么删掉 spark-defaults.conf 里的两行：
```
spark.executorEnv.LD_PRELOAD
spark.yarn.appMasterEnv.LD_PRELOAD
```

---

## 四、最终成功配置

### 4.1 spark-env.sh 关键

```bash
export HADOOP_CONF_DIR=/usr/local/service/hadoop/etc/hadoop
export SPARK_DAEMON_MEMORY=1g
export SPARK_HISTORY_OPTS="-Dspark.history.ui.port=10000 -Dspark.history.fs.logDirectory=hdfs://172.21.240.111:4007/spark-history -Dfile.encoding=UTF-8"
export JAVA_HOME=/usr/lib/jvm/java-11
```

### 4.2 spark-defaults.conf 关键（默认开启 Gluten）

```properties
# 基础
spark.eventLog.dir                  hdfs://172.21.240.111:4007/spark-history
spark.eventLog.enabled              true
spark.yarn.historyServer.address    http://172.21.240.111:10000

# Gluten + Velox（默认开启）
spark.plugins                                            org.apache.gluten.GlutenPlugin
spark.gluten.sql.columnar.backend.lib                    velox
spark.memory.offHeap.enabled                             true
spark.memory.offHeap.size                                2g
spark.shuffle.manager                                    org.apache.spark.shuffle.sort.ColumnarShuffleManager
spark.gluten.memory.allocator                            jemalloc
spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio 0.5
```

### 4.3 spark-submit 模板（含 JDK 11 add-opens）

```bash
$SPARK_HOME/bin/spark-sql \
  --master yarn --deploy-mode client \
  --num-executors 2 --executor-cores 2 --executor-memory 4g --driver-memory 2g \
  --conf spark.driver.host=172.21.240.111 \
  --conf spark.shuffle.service.enabled=false \
  --conf spark.dynamicAllocation.enabled=false \
  --conf spark.executorEnv.JAVA_HOME=/usr/lib/jvm/java-11 \
  --conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/java-11 \
  --conf spark.driver.extraJavaOptions="--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/jdk.internal.misc=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED -Dio.netty.tryReflectionSetAccessible=true" \
  --conf spark.executor.extraJavaOptions="(同上)" \
  -e "<your_sql>"
```

---

## 五、验证证据（铁证）

### 5.1 EXPLAIN FORMATTED 输出（节选关键节点）

```
(6) FilterExecTransformer
    Input [1]: [id#17L]
    Arguments: (id#17L > 100)

(7) FlushableHashAggregateExecTransformer
    Functions [2]: [partial_count(1), partial_sum(id#17L)]

(8) WholeStageCodegenTransformer (1)

(9) VeloxResizeBatches
    Arguments: 1024, 2147483647

(10) ColumnarExchange
    Arguments: SinglePartition, ENSURE_REQUIREMENTS, [shuffle_writer_type=hash]

(13) RegularHashAggregateExecTransformer
    Functions [2]: [count(1), sum(id#17L)]

(15) VeloxColumnarToRow
```

**全栈 Velox*Transformer**，零 fallback。

### 5.2 真实查询执行结果

```sql
SELECT count(*) cnt, sum(id) total 
FROM range(1, 100000000) 
WHERE id % 7 = 0;

-- Time taken: 4.437 seconds, Fetched 1 row(s)
```

1 亿行 range + 过滤 + count + sum → 4.4 秒（2 executor × 2 cores × 4g）。

### 5.3 application 列表

```
application_1779541981205_0007  SparkSQL  SUCCEEDED  Native Spark 3.5.3 验证
application_1779541981205_0008  SparkSQL  SUCCEEDED  EXPLAIN 含 Velox*Transformer
application_1779541981205_0010  SparkSQL  SUCCEEDED  默认配置烟囱测试
```

---

## 六、回滚方案

万一线上跑挂了，**单作业回退**：

```bash
spark-submit \
  --conf spark.plugins= \
  --conf spark.memory.offHeap.enabled=false \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.SortShuffleManager \
  ...
```

**全集群回退**：

```bash
cd /usr/local/service
mv spark spark-3.5.3-gluten-bak
mv spark-3.0.2-bak-20260523-213332 spark
```

旧 Spark 3.0.2 + 旧 conf 完整保留。

---

## 七、09 报告 vs 11 报告对比

| 维度 | 09（43.143.233.211） | 11（62.234.130.135 本次） |
|---|---|---|
| 集群规模 | 3 节点 EMR | 4 节点（1m+3w） |
| 部署方式 | 自己下 Spark 3.5.5 + Gluten 1.6.0 release | **从 EMR 节点拷贝整套 spark** |
| 耗时 | 数小时（含踩坑） | **30 分钟** |
| Hadoop | 2.8.5 | 2.8.5 |
| JDK | Tencent Kona 17 | Tencent Kona 11 |
| Gluten | 1.6.0 | 1.5.0-SNAPSHOT（EMR 内部版） |
| 加速比 | 1.02-1.08× | 待测（下次 50GB Bench） |
| Window frame bug | 复现 | 待测 |
| HLL 不一致 | 复现 | 待测 |

**新发现**：JDK 8 → 11 的 ByteBuffer 字节码兼容性，**比 09 报告里的 JDK 17 add-opens 套路更隐蔽**，是个值得记入"踩坑库"的新坑。

---

## 八、下一步建议

1. **生产化**：把 spark/jdk11/conf 部署到所有 4 个节点的 `/usr/local/service/`，避免 LD_PRELOAD warning
2. **加大 Bench**：用 TPC-H 100GB 数据测真实加速比（09 报告里大哥的本次 1.02× 是因为数据量太小）
3. **接 Hive 表**：用 hive-site.xml 已配的 metastore，跑业务 SQL，验证 ORC/Parquet 读
4. **黑名单算子**：approx_count_distinct、Window frame、三角函数 → 强制 fallback 到 Native（防数据不一致）

---

## 九、给大哥的一句话总结

> **30 分钟，4 节点集群上线 Spark 3.5.3 + Gluten + Velox**。  
> 关键洞察：**腾讯 EMR 已经把所有坑趟平了，复用他们的产物比从零搭建快 10 倍**。  
> 唯一新坑：JDK 11 必装（不是 8），全节点都要装，**Tencent Kona 11.0.30 yum 仓库直接装**。

---

**End of 11 — Eric 豹纹 上机直连完成 🐆**
