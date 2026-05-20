# Spark 向量化计算 — 完整知识体系（README 索引）

> **作者**：Eric（豹纹）/ 大数据 SRE AI 专家团队  
> **服务对象**：大哥（Kailong Liu）  
> **沉淀日期**：2026-05-20 晚  
> **用途**：明天上机 POC 验证 + 长期生产落地参考

---

## 〇、文档体系总览

```
spark/案例/
├── Spark向量化计算调研落地方案.md           ← 主报告（v1.0，技术调研+选型+落地）
├── Spark向量化-Gluten与Velox关系图谱.md     ← 专题1：架构关系
├── Spark向量化-Kyuubi集成方案澄清.md         ← 专题2：Kyuubi 维度
├── Spark向量化-Gluten运行时依赖清单.md       ← 专题3：依赖矩阵
├── Spark向量化-Hadoop28集群POC速成手册.md    ← 专题4：明天上机用 ⭐
├── Spark向量化-POC自动化脚本包.md            ← 专题5：脚本工具集 ⭐
└── README-Spark向量化知识体系.md             ← 本文件
```

---

## 一、阅读顺序（按场景）

### 场景 A：明天上机做 POC（首要！）
```
1. 《Hadoop28集群POC速成手册》  ← 核心
2. 《POC自动化脚本包》          ← 直接拷贝执行
3. 《Gluten运行时依赖清单》     ← 排坑参考
```

### 场景 B：技术汇报 / 给老板看
```
1. 《Spark向量化计算调研落地方案》（主报告）
2. 《Gluten与Velox关系图谱》
```

### 场景 C：选型决策
```
1. 《Spark向量化计算调研落地方案》第二、三章
2. 《Kyuubi集成方案澄清》
```

### 场景 D：踩坑排查
```
1. 《Hadoop28集群POC速成手册》第六章踩坑
2. 《Gluten运行时依赖清单》
3. 《Spark向量化计算调研落地方案》第五章踩坑库
```

---

## 二、核心结论速查（一页纸）

### 2.1 技术栈关系
> **Velox** = Meta 出品的通用 C++ 执行引擎（发动机）  
> **Gluten** = Intel 出品的 Spark→Native 适配层（变速箱）  
> **Spark** = 应用层（车壳）  
> 三层关系：`Spark → Gluten → Velox`

### 2.2 选型推荐
> **首选**：Apache Gluten + Velox（v1.5.0，Apache 顶级项目）  
> **备选**：DataFusion Comet（v0.16.0，押注 Spark 4.x）  
> **不选**：Photon（闭源）、Blaze（社区小）

### 2.3 预期收益
> 内存节省 **40%+**，加速 **1.7×–2×**，TPC-DS 1TB 整体 **1.72×**，  
> 千节点级集群 ≈170 万/年节省，ROI 周期 6 个月。

### 2.4 硬约束（必须满足）
| 项 | 要求 |
|---|---|
| Spark | **3.2 / 3.3 / 3.4 / 3.5**（默认 3.5）|
| JDK | OpenJDK 8 / 11 / 17（17 需 `--add-opens`）|
| OS | CentOS 7-8 / Ubuntu 20.04-22.04 |
| CPU | x86_64 + **AVX2**（必备） |
| Hadoop | **跟着 Spark 走**，Hadoop 2.7+ 都行（**含 2.8.5！**）|

### 2.5 老集群（Hadoop 2.8.5）能不能上？
> **能**。HDFS RPC 协议向后兼容，Spark 3.5 + Hadoop 3.x 客户端可访问 2.8.5 集群。  
> **不需要升级集群也能跑 POC**。

---

## 三、Q&A 速查表（今晚所有问答的索引）

| # | 问题 | 答案核心 | 详细文档 |
|---|---|---|---|
| Q1 | Spark 向量化怎么调研落地？ | Gluten+Velox 首选，五阶段法 | 主报告 |
| Q2 | Kyuubi 为啥集成 Gluten？ | 网关层做 CI 兜底兼容性，给用户开箱即用 | 专题2 |
| Q3 | Kyuubi+Gluten 怎么用？ | Spark 配置透传，三层启用模式 | 专题2 |
| Q4 | Kyuubi+Gluten vs Spark+Gluten 啥区别？ | **技术上零差异**，只是外围调度差异 | 专题2 |
| Q5 | Gluten 依赖啥？ | 仅硬依赖 Spark 3.2-3.5 + JDK + Linux + AVX2 | 专题3 |
| Q6 | Gluten 和 Velox 啥关系？ | 适配层 vs 执行引擎，Spark→Gluten→Velox | 专题1 |
| Q7 | 怎么落地到 Spark？ | 8 行配置 + 一个 jar，三种部署方式 | 主报告第四章 |
| Q8 | 阿里云为啥只做 3.5+H3？ | **前提不准**，AnalyticDB 是 3.2，EMR 是 3.3.1 | 主报告第二章 |
| Q9 | Hadoop 2.8.5 还能上吗？ | **能**，三条路径 ABC | 专题4 |
| Q10 | 怎么快速测试不动集群？ | Gateway 机独立部署 Spark 3.5+Gluten | 专题4 + 专题5 |

---

## 四、明天上机的 1 页 Cheat Sheet

```bash
# === Step 1: 找 Gateway 机 ===
cat /proc/cpuinfo | grep -wE "avx2"           # 必须有
cat /etc/os-release                            # CentOS 7-8 / Ubuntu 20-22
free -g                                        # ≥16GB
java -version                                  # JDK 8/11

# === Step 2: 部署 Spark + Gluten ===
sudo mkdir -p /opt/spark-poc && cd /opt/spark-poc
wget https://archive.apache.org/dist/spark/spark-3.5.5/spark-3.5.5-bin-hadoop3.tgz
tar -xzf spark-3.5.5-bin-hadoop3.tgz && ln -s spark-3.5.5-bin-hadoop3 spark
# Gluten 1.5 jar（按 OS 选）
wget https://github.com/apache/incubator-gluten/releases/download/v1.5.0/gluten-velox-bundle-spark3.5_2.12-centos_7_x86_64-1.5.0.jar
cp gluten-velox-bundle-*.jar spark/jars/

# === Step 3: 配置 ===
cat > spark/conf/spark-env.sh <<EOF
export HADOOP_CONF_DIR=/etc/hadoop/conf
export YARN_CONF_DIR=/etc/hadoop/conf
export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk
EOF

# === Step 4: 验证生效 ===
export SPARK_HOME=/opt/spark-poc/spark
$SPARK_HOME/bin/spark-sql --master yarn \
  --conf spark.plugins=org.apache.gluten.GlutenPlugin \
  --conf spark.memory.offHeap.enabled=true \
  --conf spark.memory.offHeap.size=4g \
  --conf spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager \
  -e "EXPLAIN SELECT count(*) FROM your_db.your_table WHERE dt='2026-05-19'"
# 看到 VeloxColumnarToRowExec = ✅ 成功
```

---

## 五、风险预案速查

| 风险 | 应对 |
|---|---|
| IPC version mismatch | 用 `without-hadoop` 包 + `SPARK_DIST_CLASSPATH` |
| Velox SIGSEGV | 检查 OS、glibc、AVX2，换 CentOS 8/Ubuntu 22 |
| OOM | 加 `spark.memory.offHeap.size` 到 8g+ |
| Kerberos 失败 | `kinit` + `--principal --keytab` |
| Fallback 率高 | EXPLAIN 看，剔除 textfile/UDF/ANSI 模式 |
| 短路读 socket 不存在 | 加 `spark.hadoop.dfs.client.read.shortcircuit=false` |

---

## 六、参考资料

| 类型 | 链接 |
|---|---|
| Gluten 官方 | https://gluten.apache.org/ |
| Gluten GitHub | https://github.com/apache/incubator-gluten |
| Velox GitHub | https://github.com/facebookincubator/velox |
| Comet 官方 | https://datafusion.apache.org/comet/ |
| 美团实践 | https://tech.meituan.com/2024/06/23/spark-gluten-velox.html |
| AWS Benchmark | https://awslabs.github.io/data-on-eks/docs/benchmarks/spark-gluten-velox-benchmark |
| Spark Hadoop Free | https://spark.apache.org/docs/latest/hadoop-provided.html |

---

**End of README**

> Eric 的话：大哥明天上机，先看《Hadoop28集群POC速成手册》和《POC自动化脚本包》，  
> 一天内能跑通拿到第一份数据。其他文档作为长期参考资料。  
> 任何意外查不到答案时，先看专题3《依赖清单》和主报告踩坑库。  
> 豹纹今晚守夜，明天上机随时呼叫，立刻支援 🐆。
