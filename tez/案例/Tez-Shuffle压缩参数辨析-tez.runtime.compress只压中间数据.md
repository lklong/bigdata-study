# Tez Shuffle 压缩参数辨析：`tez.runtime.compress` 到底压什么数据

> 归档人：eric
> 归档日期：2026-05-12
> 关键词：tez · 压缩 · shuffle · IFile · 中间数据 · 最终结果
> 源码版本：apache/tez `rel/release-0.10.2`（`D:\bigdata\gitproject\tez`，github.com/apache/tez）

---

## 一、背景：网传配置里两个常见错误

某 Tez/Hive 调优文档里给出的"Shuffle 压缩"配置长这样：

```ini
tez.runtime.intermediate-output.compress=true
tez.runtime.intermediate-input.compress=true
tez.runtime.intermediate-output.compression.codec=org.apache.hadoop.io.compress.SnappyCodec
```

随后又模糊地说"开启可减少 50%+ 磁盘占用"。

这段话有 **两个错误**，本案例完整还原：

1. **参数名错**：上面三个 key 在 apache/tez 社区源码里**全都不存在**，配上去 Tez 不会报错也不会生效，被静默忽略；
2. **作用域错**：哪怕用对了参数（`tez.runtime.compress` / `tez.runtime.compress.codec`），它压缩的也只是**中间 shuffle 数据**（spill / map output / shuffle 流），**不是写到 HDFS/COS 的最终结果文件**。

---

## 二、论点 1：截图三个参数名社区源码里根本没有

### 证据 1.1 — 参数定义只有"裸 compress / compress.codec"

`tez-runtime-library/src/main/java/org/apache/tez/runtime/library/api/TezRuntimeConfiguration.java`：

```java
// 行 52
private static final String TEZ_RUNTIME_PREFIX = "tez.runtime.";

// 行 493-497
@ConfigurationProperty(type = "boolean")
public static final String TEZ_RUNTIME_COMPRESS = TEZ_RUNTIME_PREFIX + "compress";

@ConfigurationProperty
public static final String TEZ_RUNTIME_COMPRESS_CODEC = TEZ_RUNTIME_PREFIX + "compress.codec";
```

拼出来就是：

- `tez.runtime.compress`（boolean，shuffle 压缩开关）
- `tez.runtime.compress.codec`（string，codec 类全名）

### 证据 1.2 — 全代码库扫描 0 命中

对 `D:\bigdata\gitproject\tez` 执行：

```powershell
Get-ChildItem -Recurse -Include *.java,*.xml,*.md,*.properties |
  Select-String -Pattern "intermediate-output\.compress|intermediate-input\.compress|intermediate-output\.compression"
```

结果：**0 命中**。`*.java`、`*.xml`、文档 md 全部找不到这种写法。

### 证据 1.3 — 真名 vs 误传对照

| 网传错误 key | 社区真名 | 备注 |
|---|---|---|
| `tez.runtime.intermediate-output.compress` | `tez.runtime.compress` | output 一个开关 |
| `tez.runtime.intermediate-input.compress` | （**不存在独立 key**） | output 与下游 input 共用同一开关 |
| `tez.runtime.intermediate-output.compression.codec` | `tez.runtime.compress.codec` | 一个 codec 同时管写出与读入 |

> **重要**：拼错的参数名在 Tez/Hive 里**不会报错**。看起来 `set` 成功、`SET` 命令也能 echo 回值，但 IFile 永远走默认（不压），是经典"配了但没生效"陷阱。

---

## 三、论点 2：方法名为何容易把人误导成 `intermediate-output.compress`

源码里负责读这两个参数的工具类，方法名就叫 `IntermediateOutput`：

`tez-runtime-library/src/main/java/org/apache/tez/runtime/library/common/ConfigUtils.java`（行 42-64）：

```java
public static Class<? extends CompressionCodec> getIntermediateOutputCompressorClass(
    Configuration conf, Class<DefaultCodec> defaultValue) {
  ...
  String name = conf.get(TezRuntimeConfiguration.TEZ_RUNTIME_COMPRESS_CODEC);
  ...
}

public static boolean shouldCompressIntermediateOutput(Configuration conf) {
  return conf.getBoolean(TezRuntimeConfiguration.TEZ_RUNTIME_COMPRESS, false);
}
```

很多调优文章作者大概率是看到方法名 `IntermediateOutput`，就**反推**出参数名 `intermediate-output.compress`。但 Java 方法名 ≠ 配置 key，Tez 的真实 key 一直是不带 `intermediate-output` 段的扁平名。

> **教训**：参数名只能从两处取——`*Configuration.java` 里的 `public static final String XXX = ...` 定义、`tez-default.xml`/`tez-site.xml` 里的 `<name>`。**永远别从方法名反推**。

---

## 四、论点 3：作用域只在中间 shuffle，不在最终输出

### 证据 3.1 — codec 实例的所有消费者

搜全 `tez-runtime-library` 模块里 `CodecUtils.getCodec` / `getCompressor` / `getDecompressor` 的调用方：

| 文件 | 行 | 用途 |
|---|---|---|
| `common/shuffle/orderedgrouped/Shuffle.java` | 115 | 有序 shuffle，**reduce 端 fetch 解压** |
| `common/sort/impl/ExternalSorter.java` | 225 | **map 端 sort spill 压缩** |
| `common/sort/impl/IFile.java` | 366 | **IFile.Writer：spill / map output 落盘压缩** |
| `common/sort/impl/IFile.java` | 776/821 | IFile.Reader：本地 spill / shuffle 文件解压 |
| `common/writers/BaseUnorderedPartitionedKVWriter.java` | 146 | 无序分区 KV 写，**vertex 间** |
| `input/UnorderedKVInput.java` | 114 | 下游 vertex **拉取数据时解压** |

**全部消费者都在 `runtime-library/{common/sort, common/shuffle, common/writers, input}` 包**，全是算子之间的 KV 通道；**没有任何一个**在 `FileOutputFormat`、`OrcOutputFormat`、`ParquetOutputFormat`、`AcidOutputFormat` 这种"最终落盘 writer"路径上。

### 证据 3.2 — MR 兼容映射给出语义铁证

`tez-mapreduce/src/main/java/org/apache/tez/mapreduce/hadoop/DeprecatedKeys.java`（行 162-164）：

```java
registerMRToRuntimeKeyTranslation(
    MRJobConfig.MAP_OUTPUT_COMPRESS,           // mapreduce.map.output.compress
    TezRuntimeConfiguration.TEZ_RUNTIME_COMPRESS);

registerMRToRuntimeKeyTranslation(
    MRJobConfig.MAP_OUTPUT_COMPRESS_CODEC,     // mapreduce.map.output.compress.codec
    TezRuntimeConfiguration.TEZ_RUNTIME_COMPRESS_CODEC);
```

Tez 把 MR 的 **`mapreduce.map.output.compress`**（即"map 中间输出"）翻译成 `tez.runtime.compress`。
**没有**翻译 `mapreduce.output.fileoutputformat.compress`（最终输出压缩）—— 那不归 Tez Runtime 管，归 Hive / OutputFormat 管。

### 证据 3.3 — 数据流定位图

```
Vertex A (Mapper / Map Task)
   │
   ├─ spill ─────────────────► [IFile compressed]   ← tez.runtime.compress 管
   │
   └─ sort/merge ────────────► map_output 文件      ← tez.runtime.compress 管
                                  │
                                  ▼ shuffle fetch (HTTP)
                          [stream compressed]      ← tez.runtime.compress 管
                                  │
Vertex B (Reducer)
   │
   └─ merge ─────────────────► [IFile compressed]   ← tez.runtime.compress 管
                                  │
                                  ▼  reduce 业务逻辑
                                  │
                                  ▼  FileSinkOperator / OutputFormat
                          HDFS/COS 上的最终结果文件   ✗ 这两个参数管不到
```

---

## 五、最终结果数据该怎么压

`tez.runtime.compress` 一概管不到 Hive 写表的最终文件。要压最终输出，按下表选：

| 目标 | 参数 / 表属性 | 备注 |
|---|---|---|
| Hive 最终查询结果落盘压缩开关 | `hive.exec.compress.output=true` | session/job 级 |
| Hive stage 之间临时表压缩 | `hive.exec.compress.intermediate=true` | 内部最后还是会落到 `tez.runtime.compress` 类似机制，但开关在 Hive 这层 |
| MR 引擎最终输出压缩 | `mapreduce.output.fileoutputformat.compress=true` + `.compress.codec` | MR 引擎专属 |
| 写 ORC 表 | 表属性 `orc.compress=SNAPPY/ZLIB/ZSTD` | 列存自身压缩，独立于 shuffle |
| 写 Parquet 表 | 表属性 `parquet.compression=SNAPPY/GZIP/ZSTD` | 列存自身压缩 |

> Hive 写 ORC/Parquet 表时，**表属性优先**于 `hive.exec.compress.output`。绝大多数生产数仓都在表属性级声明压缩。

---

## 六、推荐配置（直接抄）

### 6.1 Tez Shuffle 压缩（中间数据，省本地盘 + 减网络）

`tez-site.xml`：

```xml
<property>
  <name>tez.runtime.compress</name>
  <value>true</value>
</property>
<property>
  <name>tez.runtime.compress.codec</name>
  <value>org.apache.hadoop.io.compress.SnappyCodec</value>
</property>
```

或 Hive session 级：

```sql
set tez.runtime.compress=true;
set tez.runtime.compress.codec=org.apache.hadoop.io.compress.SnappyCodec;
```

> Codec 选型：Snappy 最常用（CPU 低、压缩比中等）；磁盘紧 + CPU 富裕选 ZSTD（`org.apache.hadoop.io.compress.ZStandardCodec`，需 Hadoop 2.9+ 且本地库就绪）；坚决不要选 Gzip（CPU 太重，shuffle 路径吃不消）。

### 6.2 验证生效（重要，避免拼错被静默忽略）

提交一个 Hive on Tez 作业后：

1. **Tez UI** → DAG → Vertex → Counter 里看 `OUTPUT_BYTES_PHYSICAL` vs `OUTPUT_BYTES`，前者明显小于后者即压缩生效；
2. **NodeManager 本地盘**：`/data*/yarn/local/usercache/*/appcache/application_*/*/output/` 下的 `file.out` 文件用 `file` 命令看不再是明文文本流；
3. **JobConf 落地**：`Tez UI → Configurations` 里看 `tez.runtime.compress` 是否真的为 `true`（不是 `set` 命令的 echo，而是作业实际生效配置）。

---

## 七、易错点 / 反模式清单

| 反模式 | 后果 | 正确做法 |
|---|---|---|
| 写 `tez.runtime.intermediate-output.compress=true` | 静默忽略，shuffle 数据全程不压 | 写 `tez.runtime.compress=true` |
| 把 `tez.runtime.compress=true` 当成"结果压缩开关" | 期望 HDFS 上的表文件变小，实际表大小不变 | 用 `orc.compress` / `parquet.compression` 或 `hive.exec.compress.output` |
| 期待"input 压缩开关" `tez.runtime.intermediate-input.compress` | 该 key 不存在 | output 端开了，下游 input 自动按 IFile header 解压，不需要单独开关 |
| 从 `ConfigUtils.shouldCompressIntermediateOutput` 这种方法名反推 key | 拼出不存在的 key | 只看 `*Configuration.java` 常量定义和 `tez-default.xml` |
| 用 Gzip 做 shuffle codec | CPU 上去后 shuffle 阶段反而变慢 | Snappy / ZSTD（`level=3` 默认） |

---

## 八、复盘要点（方法论沉淀）

1. **参数核查铁律**：任何"调优参数"在拍板写进集群配置前，必须在源码里定位到 `public static final String` 定义；找不到就是不存在，别信博客和截图。
2. **方法名 ≠ 配置 key**：Java 方法/类常喜欢用更"表意"的命名（如 `IntermediateOutput`），但配置 key 历史上经常是扁平、简短的（如 `compress`）。两者要分别从对应渠道核实。
3. **作用域核查靠"消费者"**：一个参数压缩"什么数据"，最可靠的判定方法是看这个参数最终被读出后传给了**哪个 writer/reader 类**——是 `IFile.Writer` 还是 `OrcWriter`，决定了它压的是 shuffle 还是最终文件。
4. **静默失败比报错更危险**：Hadoop 系大量配置错拼后**不报错**，靠人眼和监控验证。任何调优变更后都要看 Counter / 落盘文件 / JobConf 三件套验证。

---

## 九、关联材料

- 源码（社区）：`D:\bigdata\gitproject\tez`（`rel/release-0.10.2`，github.com/apache/tez）
- 关键文件：
  - `tez-runtime-library/src/main/java/org/apache/tez/runtime/library/api/TezRuntimeConfiguration.java`
  - `tez-runtime-library/src/main/java/org/apache/tez/runtime/library/common/ConfigUtils.java`
  - `tez-runtime-library/src/main/java/org/apache/tez/runtime/library/utils/CodecUtils.java`
  - `tez-mapreduce/src/main/java/org/apache/tez/mapreduce/hadoop/DeprecatedKeys.java`
  - `tez-runtime-library/src/main/java/org/apache/tez/runtime/library/common/sort/impl/IFile.java`
- 相关案例：本目录下 `tez切片完整链路_源码+实际对照.md`（同样使用"源码-实际对照"范式）
