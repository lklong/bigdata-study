# Gluten 运行时依赖完整清单（专题 3）

> **沉淀来源**：今晚大哥提问"插件使用上对哪些东西有依赖，比如 Hadoop"  
> **数据来源**：100% 基于 Apache Gluten v1.5.0 官方文档

---

## 〇、依赖全景图

```
                   [ Spark Application 进程 ]
                            │
        ┌───────────────────┼────────────────────┐
        │                   │                    │
   JVM 侧依赖           Native 侧依赖         外部环境依赖
        │                   │                    │
   ┌────┴─────┐       ┌─────┴──────┐      ┌─────┴──────┐
   │ JDK      │       │ libvelox.so│      │ Hadoop     │
   │ Scala    │       │ libgluten.so│     │ HDFS       │
   │ Spark    │       │ libarrow   │      │ Hive Meta  │
   │ Gluten jar│      │ libprotobuf│      │ S3/OSS/COS │
   └──────────┘       │ libfolly   │      │ Kerberos   │
                      │ libhdfs(3) │      │ OS/glibc   │
                      └────────────┘      │ CPU 指令集 │
                                          └────────────┘
```

---

## 一、硬依赖（必须满足）

### 1.1 操作系统

| OS | 版本 |
|---|---|
| **Ubuntu** | 20.04 / 22.04 |
| **CentOS** | 7 / 8 |

> 静态构建（vcpkg）模式理论支持任何 Linux，但官方仅以上发行版背书。

### 1.2 CPU 架构与指令集

| 项 | 要求 |
|---|---|
| 架构 | **x86_64**（首推）/ **aarch64** |
| 指令集 | 必须含 `bmi、bmi2、f16c、avx、avx2、sse` |
| 检查命令 | `cat /proc/cpuinfo \| grep -wE "bmi\|bmi2\|f16c\|avx\|avx2\|sse"` |

### 1.3 JVM / Spark / Scala

| 组件 | 支持版本 |
|---|---|
| **Spark** | 3.2.2 / 3.3.1 / 3.4.4 / **3.5.5**（默认）/ 4.0.1 / 4.1.0 |
| **JDK** | OpenJDK 8 或 JDK 17（17 必须加 `--add-opens=java.base/java.nio=ALL-UNNAMED`）|
| **Scala** | 2.12（Spark 3.x）/ 2.13（Spark 4.x）|

### 1.4 内存

| 项 | 要求 |
|---|---|
| Executor 堆外内存 | **≥4GB**（生产建议 20GB+，Executor 堆内 50%-70%）|
| Driver 堆内 | ≥4GB |
| 编译机内存 | ≥64GB（仅编译时需要，运行时不需要）|

---

## 二、Hadoop / HDFS 依赖

### 2.1 Hadoop 版本

**Gluten 官方文档没有硬性指定 Hadoop 版本**——**Gluten 本身不绑 Hadoop 版本**，通过两种方式访问 HDFS：

#### 路径 A：libhdfs（Hadoop 官方 JNI 库）

```
HADOOP_HOME 必须设置
└── ${HADOOP_HOME}/lib/native/libhdfs.so
     └── 走 JNI → 调用 Hadoop 的 Java 类
          └── Hadoop 版本由 Spark 自身的 hadoop-client 版本决定
```

**结论**：**Gluten 跟着 Spark 走**，Spark 配什么 Hadoop，Gluten 用什么。

#### 路径 B：libhdfs3（C++ 重写版）

```
自行编译：./dev/build_libhdfs3.sh
└── 纯 C++ 实现，不依赖 JNI 和 Hadoop jar
     └── 需要单独的 hdfs-client.xml + LIBHDFS3_CONF 环境变量
```

**libhdfs vs libhdfs3 选哪个**：

| 维度 | libhdfs（默认）| libhdfs3 |
|---|---|---|
| 实现 | JNI + Java | 纯 C++ |
| 性能 | 一般（JNI 开销）| 更好 |
| 配置 | 用 `hdfs-site.xml` | 独立 `hdfs-client.xml` |
| Kerberos | 跟 Spark 一起处理 | 自己配 `KRB5CCNAME` |
| 维护 | Hadoop 官方 | 老 HAWQ 项目 |
| **生产推荐** | **libhdfs** | 性能极致追求时用 |

> 默认行为：`HADOOP_HOME` 已设 → 用 libhdfs；未设 → libhdfs3。

### 2.2 HDFS 短路读

Velox 默认走短路读：
```
默认 socket：/var/lib/hadoop-hdfs/dn_socket
```
要求：DataNode 启用 `dfs.client.read.shortcircuit=true`，目录可访问。

### 2.3 Kerberos

| 路径 | 配置 |
|---|---|
| libhdfs | 跟 Spark 走（`spark.kerberos.principal/keytab`）|
| libhdfs3 | `hdfs-client.xml` 设 `hadoop.security.authentication=kerberos` + `KRB5CCNAME` |

---

## 三、Hive / 表格式依赖

### 3.1 Hive Metastore

**官方未硬性指定版本**。Gluten 通过 Spark HiveCatalog 读元数据，Hive 版本跟 Spark 走（Spark 3.5 默认 hive-exec 2.3.x）。

⚠️ **美团踩坑**：Hive 0.13 之前的 ORC 文件在 Velox 下读会丢数据（Footer 不含列名）。**2.x 以上 Hive 没问题**。

### 3.2 表格式（编译 Profile）

| 表格式 | Profile | 支持程度 |
|---|---|---|
| **Hive 原生表** | 无需 | ✅ 默认支持 |
| **Delta Lake** | `-Pdelta` | ✅ 含 column mapping |
| **Iceberg** | `-Piceberg` | ✅ COW + MOR 读 |
| **Hudi** | `-Phudi` | ⚠️ 仅 COW 读 |
| **Paimon** | `-Ppaimon` | ⚠️ 仅 non-pk 表，需 Spark ≥ 3.3 |

### 3.3 文件格式

| 格式 | 支持 | 备注 |
|---|---|---|
| **Parquet** | ✅ 一等公民 | Velox 原生支持最完整 |
| **ORC** | ✅ 支持 | DwrfReader（Velox 内置）|
| **TextFile** | ❌ Fallback | 走原生 Spark |
| **Avro** | ❌ Fallback | 走原生 Spark |
| **JSON** | ❌ Fallback | 走原生 Spark |

> **生产建议**：textfile 转成 ORC/Parquet（美团做法）。

---

## 四、Shuffle 服务依赖

### 4.1 本地 Shuffle（默认）

```properties
spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager
```
不依赖外部组件，但需要：本地 NVMe SSD + 充足磁盘空间。

### 4.2 远程 Shuffle 服务（可选）

| RSS | 支持版本 | Profile |
|---|---|---|
| **Apache Celeborn** | 0.3.x / 0.4.x / **0.5.x** | `-Pceleborn` |
| **Apache Uniffle** | 0.9.2 | `-Puniffle` |

---

## 五、对象存储依赖（按需）

| 存储 | 编译开关 | 底层 SDK |
|---|---|---|
| **AWS S3** | `--enable_s3=ON` | AWS C++ SDK |
| **Azure ABFS** | `--enable_abfs=ON` | Azure SDK for C++ |
| **Google GCS** | 默认编进 | GCS C++ Client |
| **HDFS** | `--enable_hdfs=ON` | libhdfs / libhdfs3 |
| **腾讯 COS / 阿里 OSS** | 走 S3 协议 | 配 S3 endpoint 即可 |

---

## 六、Native 库依赖

### 6.1 静态构建（推荐 `--enable_vcpkg=ON`）

```
gluten-velox-bundle.jar （已包含全部 native 库）
   ├── libvelox.so      （Velox 引擎）
   ├── libgluten.so     （Gluten 桥接层）
   ├── libarrow.so      （内置 patch 版 Arrow）
   ├── libprotobuf      （静态链接）
   ├── libfolly         （Meta 工具库）
   ├── libfboost        （Meta 修改的 Boost）
   ├── libjemalloc      （内存分配器）
   └── ... 其他 vcpkg 依赖
```

**优点**：**部署只需一个 jar 包**，没有外部 so 依赖（除 libhdfs）。

### 6.2 系统库（运行时必须有）

```
glibc          # 由 OS 决定
libstdc++      # GCC 运行时
libgcc_s       # GCC 运行时
libdl          # 动态加载（dlopen libhdfs.so）
libpthread     # 线程
libm           # 数学库
libc           # C 标准库
```

---

## 七、可选依赖（功能增强）

| 依赖 | 用途 | 启用方式 |
|---|---|---|
| **jemalloc** | 替代默认分配器，减少碎片 | `spark.gluten.memory.allocator=jemalloc` |
| **Intel ISA-L** | 加速 zlib/gzip 解压（美团用了）| 编译时链接 |
| **Apache Arrow** | 列存内存格式 | Gluten 内置 patch 版 |

---

## 八、不依赖什么（容易误会的）

| 你以为要 | 实际上 | 说明 |
|---|---|---|
| 特定 Hadoop 版本 | ❌ 跟 Spark 走 | **Hadoop 2.7+ 都行（含 2.8.5！）** |
| 特定 Hive Metastore | ❌ 跟 Spark 走 | Hive 2.x+ 都行 |
| YARN | ❌ 不依赖 | YARN/K8s/Standalone 都行 |
| Zookeeper | ❌ 不依赖 | — |
| Kafka | ❌ 不依赖 | — |
| 改 Spark 源码 | ❌ 不需要 | 标准 Spark Plugin 机制 |
| 改 HDFS 源码 | ❌ 不需要 | 走标准客户端 |
| Python | ❌ 不需要 | 纯 JVM + C++ |
| GPU | ❌ 不需要 | 纯 CPU SIMD |

---

## 九、版本兼容矩阵速查

| 你的环境 | Gluten 是否能跑 |
|---|---|
| Spark 2.4 + Hadoop 2.7 | ❌ Spark 太老 |
| Spark 3.0 + Hadoop 3.0 | ❌ 不在支持列表 |
| **Spark 3.2/3.3/3.4/3.5 + Hadoop 2.7+** | ✅ 推荐 |
| **Spark 3.5 + Hadoop 2.8.5** | ✅ 可（HDFS RPC 向后兼容）|
| Spark 4.0 + Hadoop 3.x | ⚠️ 试验性 |
| CDH 5.x（Hadoop 2.6）| ⚠️ 可能跑，不保证 |
| CDH/CDP 6.x+ / HDP 3.x | ✅ |
| EMR / TDH / TBDS 6.0+ | ✅ |

---

## 十、最简部署清单（实操）

```bash
# 节点必备（所有 Spark Worker）
1. OS: Ubuntu 22.04 / CentOS 7
2. JDK 8 或 17
3. CPU: x86_64 + AVX2
4. HADOOP_HOME 已设置（如果用 HDFS）
5. /var/lib/hadoop-hdfs/dn_socket 存在（如果用短路读）

# 部署一个 jar
6. cp gluten-velox-bundle-spark3.5_2.12-1.5.0.jar $SPARK_HOME/jars/

# Spark 配置（8 行）
7. spark.plugins=org.apache.gluten.GlutenPlugin
8. spark.memory.offHeap.enabled=true
9. spark.memory.offHeap.size=20g
10. spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager
```

---

## 十一、一键依赖巡检脚本

```bash
#!/bin/bash
# gluten-precheck.sh — 部署前依赖巡检

echo "===== Gluten 部署前依赖检查 ====="

# 1. CPU 指令集
echo -n "[1/8] CPU AVX2: "
if grep -wE "avx2" /proc/cpuinfo > /dev/null; then
    echo "✅"
else
    echo "❌ 缺 AVX2，无法运行"; exit 1
fi

# 2. CPU 架构
echo -n "[2/8] 架构: "
ARCH=$(uname -m)
echo $ARCH
[[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]] && { echo "❌ 不支持"; exit 1; }

# 3. OS
echo -n "[3/8] OS: "
. /etc/os-release
echo "$NAME $VERSION_ID"
case "$NAME" in
    *Ubuntu*) [[ "$VERSION_ID" == "20.04" || "$VERSION_ID" == "22.04" ]] && echo "✅" || echo "⚠️ 不在官方列表" ;;
    *CentOS*|*Rocky*|*Alma*) [[ "$VERSION_ID" =~ ^[78] ]] && echo "✅" || echo "⚠️" ;;
    *) echo "⚠️ 不在官方列表" ;;
esac

# 4. 内存
echo -n "[4/8] 内存: "
MEM=$(free -g | awk 'NR==2 {print $2}')
echo "${MEM}GB"
[[ $MEM -lt 16 ]] && echo "⚠️ <16GB"

# 5. JDK
echo -n "[5/8] JDK: "
if java -version 2>&1 | head -1 | grep -qE '"(1\.8|11|17)'; then
    java -version 2>&1 | head -1
    echo "✅"
else
    echo "❌"; exit 1
fi

# 6. HADOOP_HOME
echo -n "[6/8] HADOOP_HOME: "
if [[ -n "$HADOOP_HOME" && -d "$HADOOP_HOME" ]]; then
    echo "$HADOOP_HOME ✅"
    ls $HADOOP_HOME/lib/native/libhdfs.so 2>/dev/null && echo "  libhdfs.so ✅"
else
    echo "⚠️ 未设置"
fi

# 7. SPARK_HOME
echo -n "[7/8] SPARK_HOME: "
if [[ -n "$SPARK_HOME" && -d "$SPARK_HOME" ]]; then
    echo "$SPARK_HOME ✅"
    $SPARK_HOME/bin/spark-submit --version 2>&1 | grep -E "version" | head -1
else
    echo "⚠️ 未设置"
fi

# 8. glibc
echo -n "[8/8] glibc: "
ldd --version | head -1

echo "===== 检查结束 ====="
```

---

## 十二、一句话总结

> **Gluten 只硬依赖：Spark 3.2-3.5 + JDK 8/17 + Linux x86_64 (AVX2)**。  
> **Hadoop / Hive 跟着 Spark 走，没硬性版本（含 Hadoop 2.8.5）**。  
> **HDFS 通过 libhdfs（dlopen）访问，不需要重编 Hadoop**。  
> **静态构建模式下，部署就是一个 jar，零外部 so 依赖**。

---

**End of 专题 3**
