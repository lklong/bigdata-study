# ORC ZSTD 解压完整调用链源码分析

> 来源案例：K8s vs YARN 性能对比，2026-04-07
> 任务编号: SP-03
> 源码分支: emr-3.3.2-zyb

---

## 调用链全景图

```
SQL 查询执行
  → FileSourceScanExec.doExecuteColumnar()              [DataSourceScanExec.scala:552]
    → FileScanRDD.compute()                              [FileScanRDD.scala:78]
      → OrcFileFormat.buildReaderWithPartitionValues()   [OrcFileFormat.scala:126]
        → OrcColumnarBatchReader.initialize()            [OrcColumnarBatchReader.java:77]
          → OrcFile.createReader(filePath, readerOptions) [orc-core]
          → reader.rows(options)                          [orc-core RecordReader]
            → InStream.read()                            [orc-core 内部]
              → io.airlift.compress.zstd.ZstdDecompressor.decompress()  [aircompressor]
```

## 关键源码节点

### 1. OrcFileFormat — 入口

```scala
// OrcFileFormat.scala 第 200-218 行
if (enableVectorizedReader) {
  val batchReader = new OrcColumnarBatchReader(capacity)
  val iter = new RecordReaderIterator(batchReader)
  batchReader.initialize(fileSplit, taskAttemptContext)
  batchReader.initBatch(
    TypeDescription.fromString(resultSchemaString),
    resultSchema.fields,
    requestedDataColIds,
    requestedPartitionColIds,
    file.partitionValues)
  iter.asInstanceOf[Iterator[InternalRow]]
}
```

**向量化读取器**（`OrcColumnarBatchReader`）是默认路径，由 `spark.sql.orc.enableVectorizedReader=true` 控制。

### 2. OrcColumnarBatchReader — 批量读取

```java
// OrcColumnarBatchReader.java 第 46-79 行
public class OrcColumnarBatchReader extends RecordReader<Void, ColumnarBatch> {
  private int capacity;                    // batch 大小
  private VectorizedRowBatchWrap wrap;     // ORC 向量化批次
  private org.apache.orc.RecordReader recordReader;  // ← orc-core 的 reader
}
```

**关键**: `recordReader` 是 `orc-core` 提供的，Spark 不参与解压逻辑。

### 3. orc-core 1.7.8 — ZSTD 压缩处理

ORC 的压缩/解压在 `org.apache.orc.impl.InStream` 中处理：

```
读取流程:
  RecordReaderImpl.nextBatch()
    → TreeReaderFactory 读各列
      → InStream.read()
        → 如果是 ZSTD 压缩: 调用 aircompressor 的 ZstdDecompressor
        → 解压后放入 ColumnVector
```

ORC 1.7.8 的 codec 选择（在 `orc-core` 内部，非 Spark 代码）：
```java
// orc-core: WriterImpl.java
case ZSTD:
  return new ZstdCodec();
// ZstdCodec 内部使用 io.airlift.compress.zstd.ZstdCompressor/ZstdDecompressor
```

### 4. aircompressor — 实际解压实现

```
io.airlift.compress.zstd.ZstdDecompressor.decompress(
    byte[] input, int inputOffset, int inputLength,
    byte[] output, int outputOffset, int outputLength)
```

**纯 Java 实现**，不调用任何 JNI 或 native 库。性能特征：
- 比 zstd-jni (C native) 慢约 2-3x
- 但两端都用同一个实现，所以**无差异**
- 这是 ORC 1.7.8 的架构决定，和 Spark/Hadoop 配置无关

### 5. 三条 zstd 路径对照表

| 路径 | 使用场景 | 实现库 | JNI? | 依赖 libhadoop? |
|------|---------|--------|------|----------------|
| **aircompressor** | ORC 文件读写 | `io.airlift.compress.zstd` | 否（纯 Java） | 否 |
| **zstd-jni** | Spark Core (shuffle/broadcast/eventlog) | `com.github.luben:zstd-jni:1.5.2-1` | 是（自带 .so） | 否 |
| **Hadoop CodecPool** | COS/HDFS 文件级压缩 | `org.apache.hadoop.io.compress.zstd.ZStandardCodec` → 内部用 zstd-jni | 是 | 否 |

**三条路径都不依赖 `libhadoop.so`**。

---

## ORC 压缩配置

```scala
// OrcOptions.scala 第 75-82 行
private val shortOrcCompressionCodecNames = Map(
  "none" -> "NONE",
  "uncompressed" -> "NONE",
  "snappy" -> "SNAPPY",
  "zlib" -> "ZLIB",
  "lzo" -> "LZO",
  "lz4" -> "LZ4",
  "zstd" -> "ZSTD")

// OrcFileFormat.scala 第 76 行 — 写入时设置压缩
conf.set(COMPRESS.getAttribute, orcOptions.compressionCodec)
```

日志确认本次使用 ZSTD：
```
PhysicalFsWriter: ORC writer created ... compression: Compress: ZSTD buffer: 262144
```

## ORC 向量化读取配置

```
spark.sql.orc.enableVectorizedReader = true (默认)
spark.sql.orc.enableNestedColumnVectorizedReader = true (本次开启)
spark.sql.orc.columnarReaderBatchSize = 4096 (默认)
```
