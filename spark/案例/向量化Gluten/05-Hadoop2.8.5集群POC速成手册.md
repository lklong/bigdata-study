# Hadoop 2.8.5 老集群上 Gluten 快速 POC 速成手册（专题 4）

> **沉淀来源**：大哥的产线现状——只有 Hadoop 2.8.5，要在不动集群的前提下快速验证 Gluten  
> **明天上机就用这一份！** ⭐

---

## 〇、目标 & 约束

| 项 | 值 |
|---|---|
| **目标** | 1 天内在现有集群跑通一个 Gluten 加速的 SQL，拿到第一份性能对比数据 |
| **约束** | ❌ 不动 HDFS / YARN / NM / RM ❌ 不动其他用户作业 ❌ 不重启集群 |
| **方案** | **Spark 3.5（hadoop-3 客户端版）+ Gluten 1.5 客户端独立部署，YARN cluster 模式提交** |
| **耗时** | 准备 2h + 跑通 1h + Benchmark 2h ≈ 半天 |

---

## 一、为啥这个方案最快？

```
你的现有环境：
   ├── HDFS 2.8.5 ─┐
   ├── YARN 2.8.5 ─┼─ 服务端，不动
   └── NM/RM 2.8.5 ┘

你要做的事：
   └── 找一台边缘机（gateway/客户端机）
        ├── 装一个独立的 Spark 3.5 + Hadoop 3 客户端
        ├── 装 Gluten 1.5 jar
        └── spark-submit --master yarn 提交到现有集群
             └─→ HDFS RPC 协议向后兼容，能读 2.8.5
```

**核心原理**：Spark 客户端只是个"提交器"，**真正在 YARN 上跑的是 ApplicationMaster + Executor 进程**——这些进程会把自己的 jar（含 Hadoop 3.x 客户端）传到 NM 上隔离执行，**和 NM 上原有的 Hadoop 2.8.5 完全不冲突**。

---

## 二、Hadoop 2.8.5 + Gluten 兼容性铁证

### Spark 3.x 对 Hadoop 2.x 的态度

| Spark 版本 | Hadoop 2.x 支持 |
|---|---|
| Spark 3.0 - 3.3 | ✅ 官方支持（`-Phadoop-2.7`）|
| **Spark 3.4** | ⚠️ **官方移除 Hadoop 2.x 编译 profile** |
| **Spark 3.5** | ❌ 仅 Hadoop 3.x 编译，但**Hadoop Free 包可对接 H2** |

### Gluten 这一层

> Gluten 官方文档：*"Gluten supports dynamically loading both libhdfs.so and libhdfs3.so at runtime by using dlopen"*

**Gluten 自己不绑 Hadoop 版本**——通过运行时 `dlopen` 加载 libhdfs.so。**Gluten 跟你的 Hadoop 版本无关，只跟 Spark 用的 hadoop-client jar 版本有关**。

---

## 三、三条可行路径对比

| 维度 | 路径 A（3.3+H2.7）| **路径 B（3.5+Free+H2.8.5）** | **路径 C（3.5+H3 客户端）⭐** |
|---|---|---|---|
| Spark 版本 | 3.3.4（旧）| **3.5.5（最新）** | **3.5.5（最新）** |
| Hadoop 服务端 | 2.8.5 | 2.8.5 | 2.8.5 |
| Hadoop 客户端 jar | 2.7 | **2.8.5 自己的** | **3.3.x（兼容 2.8.5）** |
| Gluten 兼容 | ✅ | ✅ | ✅ |
| 性能 | 🟡 中 | 🟢 最优 | 🟢 最优 |
| 风险 | 🟢 低 | 🟡 中 | 🟡 中 |
| **推荐指数** | ⭐⭐⭐ | ⭐⭐⭐⭐ | **⭐⭐⭐⭐⭐** |

**明天大哥上机走路径 C**。

---

## 四、Step 1：找 Gateway 机（10 分钟）

### 4.1 选机器

| 选项 | 说明 |
|---|---|
| Gateway 节点 | 你已有的 spark-submit 跳板机 |
| 任意一台 NM 节点 | 用 root 在边角目录装，不污染原有 |
| 一台空闲服务器 | 能 ping 到 RM/NM 即可 |

### 4.2 必备前置检查

```bash
# 1. 能访问 RM
yarn rmadmin -getServiceState rm1

# 2. 能解析 NameNode
hdfs dfs -ls /

# 3. CPU 支持 AVX2（Velox 必需）
cat /proc/cpuinfo | grep -wE "avx2" | head -1

# 4. OS 是 CentOS 7-8 / Ubuntu 20-22
cat /etc/os-release | head -2

# 5. 内存 ≥16GB
free -g

# 6. JDK 8 或 11
java -version
```

**6 项全过 → 继续；任一不过 → 换机器。**

---

## 五、Step 2：装 Spark 3.5 + Gluten（30 分钟）

### 5.1 下载

```bash
# 找个目录（不要污染 /opt/spark 之类的现有路径）
sudo mkdir -p /opt/spark-poc
cd /opt/spark-poc

# Spark 3.5（带 hadoop-3 客户端）
wget https://archive.apache.org/dist/spark/spark-3.5.5/spark-3.5.5-bin-hadoop3.tgz
tar -xzf spark-3.5.5-bin-hadoop3.tgz
ln -s spark-3.5.5-bin-hadoop3 spark

# Gluten 1.5 预编译包（按你的 OS 选）
# CentOS 7：
wget https://github.com/apache/incubator-gluten/releases/download/v1.5.0/gluten-velox-bundle-spark3.5_2.12-centos_7_x86_64-1.5.0.jar
# Ubuntu 22.04：
# wget https://github.com/apache/incubator-gluten/releases/download/v1.5.0/gluten-velox-bundle-spark3.5_2.12-ubuntu_22.04_x86_64-1.5.0.jar

# 放进 Spark jars
cp gluten-velox-bundle-spark3.5_2.12-*-1.5.0.jar /opt/spark-poc/spark/jars/
```

### 5.2 配置指向现有集群

```bash
cat > /opt/spark-poc/spark/conf/spark-env.sh <<'EOF'
#!/usr/bin/env bash

# 现有 Hadoop 集群配置（关键！）
export HADOOP_CONF_DIR=/etc/hadoop/conf       # 你的 2.8.5 集群配置目录
export YARN_CONF_DIR=/etc/hadoop/conf

# Java 路径
export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk

# 不要导出 SPARK_DIST_CLASSPATH（让 Spark 用自己带的 hadoop-3 jar）
EOF

chmod +x /opt/spark-poc/spark/conf/spark-env.sh
```

### 5.3 验证客户端能读 HDFS

```bash
export SPARK_HOME=/opt/spark-poc/spark
export PATH=$SPARK_HOME/bin:$PATH

$SPARK_HOME/bin/spark-shell --master local[2] -e "
spark.read.text('hdfs:///user/').limit(1).show()
"
```

**报错** `Server IPC version 9 cannot communicate with client version X`：
```bash
# 加配置降级 RPC 版本
echo "spark.hadoop.ipc.client.fallback-to-simple-auth-allowed true" \
  >> $SPARK_HOME/conf/spark-defaults.conf
```

**仍报错** → 切换路径 B（Hadoop Free 版）：
```bash
wget https://archive.apache.org/dist/spark/spark-3.5.5/spark-3.5.5-bin-without-hadoop.tgz
# 用集群已有的 Hadoop 客户端
echo "export SPARK_DIST_CLASSPATH=\$(/usr/bin/hadoop classpath)" \
  >> $SPARK_HOME/conf/spark-env.sh
```

---

## 六、Step 3：跑通第一个 Gluten SQL（30 分钟）

### 6.1 准备最小测试 SQL

```bash
TEST_DB=your_db
TEST_TABLE=your_table   # 选 1-10GB 的 Parquet/ORC 表

TEST_SQL="SELECT count(*), sum(some_col), avg(other_col) FROM ${TEST_DB}.${TEST_TABLE} WHERE dt='2026-05-19'"
```

### 6.2 第一发：原生 Spark（基线）

```bash
$SPARK_HOME/bin/spark-sql \
  --master yarn \
  --deploy-mode client \
  --num-executors 4 \
  --executor-cores 2 \
  --executor-memory 8g \
  --driver-memory 4g \
  --queue your_queue \
  -e "${TEST_SQL}" \
  2>&1 | tee /tmp/native_spark.log

grep "Time taken" /tmp/native_spark.log
```

### 6.3 第二发：Gluten 加速

```bash
$SPARK_HOME/bin/spark-sql \
  --master yarn \
  --deploy-mode client \
  --num-executors 4 \
  --executor-cores 2 \
  --executor-memory 8g \
  --driver-memory 4g \
  --queue your_queue \
  \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=4g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  --conf spark.gluten.memory.allocator=jemalloc \
  --conf spark.gluten.sql.columnar.backend.velox.partialAggregationMemoryRatio=0.5 \
  \
  -e "${TEST_SQL}" \
  2>&1 | tee /tmp/gluten_spark.log

grep "Time taken" /tmp/gluten_spark.log
```

### 6.4 验证 Gluten 真的生效

```bash
$SPARK_HOME/bin/spark-sql \
  --master yarn \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=4g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  -e "EXPLAIN ${TEST_SQL}" 2>&1 | grep -E "Velox|Transformer"
```

**应该看到**：
```
*(2) VeloxColumnarToRowExec
+- WholeStageTransformer
   +- HashAggregateTransformer
```

**只要看到 `Velox*` 关键字 = ✅ Gluten 在你的集群上跑起来了**。

---

## 七、Step 4：扩展到 Benchmark（2 小时）

详见独立文档：《Spark向量化-POC自动化脚本包.md》。

### 7.1 期望结果

| 查询类型 | 预期加速比 |
|---|---|
| 大聚合（GROUP BY + SUM/COUNT）| **2x - 5x** |
| Join（大表 join 小表）| **1.5x - 3x** |
| 简单 SELECT + WHERE | **1.2x - 2x** |
| TPC-H 整体 | **1.5x - 2x** |
| 复杂多 Join | **1.7x - 4x** |

**如果加速比 < 1.0x（变慢）**：
- 数据量太小（<1GB），JNI 开销 > 收益 → 换大数据测
- Fallback 率太高 → EXPLAIN 看哪些算子没走 Velox

---

## 八、可能踩到的坑及解法（Top 6）

### 8.1 IPC Version Mismatch
**报错**：`Server IPC version 9 cannot communicate with client version X`  
**解法**：切到 Hadoop Free 版（路径 B），用集群自有客户端。

### 8.2 Kerberos 认证失败
**报错**：`Failed to find any Kerberos tgt`  
**解法**：
```bash
kinit -kt /path/to/your.keytab your_principal
# 或 spark-submit 加：
--conf spark.kerberos.principal=your_principal \
--conf spark.kerberos.keytab=/path/to/your.keytab
```

### 8.3 Velox SIGSEGV（最棘手）
**报错**：Executor 突然死掉，stderr 看到 `SIGSEGV` / `core dump`  
**解法**：
```bash
cat /etc/os-release      # 必须 CentOS 7-8 或 Ubuntu 20-22
ldd --version            # CentOS 7 是 2.17，可能太老
# glibc 太老 → 换 CentOS 8 / Ubuntu 22 机器
# 或编译静态构建版（vcpkg）
```

### 8.4 OOM: Cannot allocate buffer
**解法**：增大堆外内存
```bash
--conf spark.memory.offHeap.size=8g       # 从 4g 加到 8g
--conf spark.executor.memoryOverhead=4g    # YARN container 也要加
```

### 8.5 Fallback 率太高
**诊断**：
```sql
EXPLAIN your_sql;
-- 数 Velox*Transformer 节点 vs RowToVeloxColumnar 节点
-- 后者多 = fallback 严重
```
**应对**：
- 检查表是否 Parquet/ORC（textfile 不支持向量化）
- 检查 SQL 里有没有 UDF（Java UDF 必 fallback）
- 检查有没有 ANSI 模式（开启时 Gluten 全 fallback）

### 8.6 短路读 socket 路径不存在
**报错**：`Failed to connect to /var/lib/hadoop-hdfs/dn_socket`  
**解法**：禁用短路读（POC 阶段）
```bash
--conf spark.hadoop.dfs.client.read.shortcircuit=false
```

---

## 九、Hadoop 2.8.5 特定痛点

### 9.1 ECS NM Auxiliary 服务限制
Hadoop 2.8.5 NM 不支持某些 Spark 3.5 才有的 shuffle 协议。如用 ESS：
```bash
# 把 Spark 3.5 的 spark-network-shuffle jar 推到所有 NM 节点
cp spark-3.5.5/yarn/spark-3.5.5-yarn-shuffle.jar \
   $HADOOP_HOME/share/hadoop/yarn/lib/
# 重启所有 NM
```

### 9.2 ResourceManager 资源类型
Hadoop 2.8.5 不支持 Resource Types（YARN-3926，3.0+）。  
**实际表现**：`spark.executor.memoryOverhead=20g` 没问题；`spark.yarn.executor.resource.xxx` 高级特性可能失效。

### 9.3 Kerberos / Delegation Token
Hadoop 2 → 3 之间 Token 续期、刷新机制改动较大。**优先验证 spark-submit 的 Token 流程**。

### 9.4 短路读
Hadoop 2.8.5 SCR 实现没问题，但如未开启：
```xml
<!-- hdfs-site.xml -->
<property>
  <name>dfs.client.read.shortcircuit</name>
  <value>true</value>
</property>
<property>
  <name>dfs.domain.socket.path</name>
  <value>/var/lib/hadoop-hdfs/dn_socket</value>
</property>
```

---

## 十、最小验证清单（贴墙上！）

```
[ ] 1. Gateway 机 AVX2 ✅
[ ] 2. Spark 3.5 + Gluten jar 部署到 /opt/spark-poc/
[ ] 3. HADOOP_CONF_DIR 指向现有集群配置
[ ] 4. spark-shell --master yarn 能跑 SELECT 1
[ ] 5. EXPLAIN 看到 VeloxColumnarToRowExec
[ ] 6. 一致性测试：行数+md5 一致
[ ] 7. 至少 3 条业务 SQL 加速比 ≥ 1.5x
[ ] 8. 没踩到 IPC mismatch / Kerberos / SIGSEGV 坑
```

**8 项全过 = POC 成功**。

---

## 十一、不需要做的事（避免过度工程）

| 不要做 | 原因 |
|---|---|
| ❌ 升级 Hadoop | 不必要，HDFS RPC 向后兼容 |
| ❌ 重启 NM/RM | 客户端独立部署，集群不知道你在跑 Spark 3.5 |
| ❌ 改 yarn-site.xml | 不动配置 |
| ❌ 编译 Gluten | 直接用预编译包 |
| ❌ 装 jemalloc 系统包 | Gluten jar 里自带 |
| ❌ 部署到所有节点 | 客户端机一台就够，executor 自己拉 jar |
| ❌ 改 Hive Metastore | Spark 3.5 兼容老 HMS |
| ❌ 申请新队列 | 用现有队列就行 |

---

## 十二、POC 完成后路线图

```
今天    ─┬─ POC 跑通 → 拿到第一份加速数据
         │
1 周    ─┼─ 扩大测试到 20 条业务 SQL
         │   - 一致性测试覆盖
         │   - 找出哪些查询不适合 Gluten
         │
2 周    ─┼─ 准备灰度方案
         │   - 1 个低风险作业生产试点
         │   - 监控告警接入
         │
1 月    ─┼─ 灰度扩到 10% 作业
         │
3 月    ─┴─ 评估是否升级 Hadoop 3.x
            （如果 POC 数据漂亮，业务方愿意推）
```

---

## 十三、降级备选

### Plan B：升级到路径 A
Spark 3.3 + Hadoop 2.7 编译版，性能略低但稳。

### Plan C：先升级 Hadoop
长期看，**Hadoop 2.8.5 已 EOL**：
- Hadoop 2.x 系列最后一个 release 是 2.10.2（2022 年）
- 之后官方不再发布 patch
- **CVE 安全漏洞修复也停了**

如果集群是核心生产，**两年内必须升 Hadoop 3.x**。

### Plan D：自建独立 Hadoop 3.x 子集群
专门给向量化作业用：
- 数据通过 DistCp 双写或同步
- 老集群跑老作业
- 新集群跑 Gluten 加速作业
- 逐步迁移

---

## 十四、一句话总结

> **Hadoop 2.8.5 不是死路，是绕路**。  
> 你的真正瓶颈不是 Hadoop 版本，是 Spark 版本——**只要 Spark 升到 3.5，集群该是 2.8.5 还是 2.8.5**。  
> 用 Hadoop 3.x 的客户端 jar 去访问 2.8.5 的服务端，是业界很多公司没钱升级 HDFS 但又想用新 Spark 的标准操作。

---

**End of 专题 4 — 这一份是大哥明天上机的核心！**
