# Iceberg 源码深度解析：Write Path — DataWriter / TaskWriter / 文件组织全链路

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-27

---

## 一、写入全链路概览

```
Spark/Flink DataFrame
  │
  ▼
SparkWrite (引擎适配层)
  │
  ├── distribution: 数据分布策略（none/hash/range）
  ├── ordering: 排序策略
  │
  ▼
TaskWriter (任务级写入器)
  ├── UnpartitionedWriter (无分区)
  ├── PartitionedWriter (分区表 — clustered)
  └── FanoutWriter (分区表 — fanout)
       │
       ▼
  RollingDataWriter (文件滚动)
    └── 按 targetFileSize 自动切分文件
         │
         ▼
    DataWriter (单文件写入)
      └── FileAppender (Parquet/ORC/Avro)
           │
           ▼
      OutputFileFactory (文件命名)
        └── {partitionId}-{taskId}-{operationId}-{fileCount}.parquet
             │
             ▼
        FileIO (HDFS/S3/OSS)
```

---

## 二、OutputFileFactory — 文件命名规则

**源码位置**: `core/src/main/java/org/apache/iceberg/io/OutputFileFactory.java`

```java
public class OutputFileFactory {
    private final int partitionId;        // Spark partition id
    private final long taskId;            // 任务 id
    private final String operationId;     // UUID（标识一次写入操作）
    private final AtomicInteger fileCount; // 文件计数器（递增）
    private final String suffix;          // 后缀

    // 文件名生成规则
    private String generateFilename() {
        return format.addExtension(
            String.format("%05d-%d-%s-%05d%s",
                partitionId,      // 5 位 partition id
                taskId,           // task id
                operationId,      // UUID
                fileCount.incrementAndGet(), // 5 位文件序号
                suffix));
    }
    // 示例: 00003-7-a1b2c3d4-00001.parquet
}
```

**文件路径生成**:

```
无分区表:
  /warehouse/db/table/data/00003-7-uuid-00001.parquet

分区表:
  /warehouse/db/table/data/dt=2026-04-27/00003-7-uuid-00001.parquet
  /warehouse/db/table/data/dt=2026-04-27/region=US/00003-7-uuid-00001.parquet
```

---

## 三、DataWriter — 单文件写入器

**源码位置**: `core/src/main/java/org/apache/iceberg/io/DataWriter.java`

```java
public class DataWriter<T> implements FileWriter<T, DataWriteResult> {
    private final FileAppender<T> appender;  // 底层 Parquet/ORC writer
    private final FileFormat format;
    private final String location;
    private final PartitionSpec spec;
    private final StructLike partition;
    private DataFile dataFile = null;

    @Override
    public void write(T row) {
        appender.add(row);  // 委托给 FileAppender
    }

    @Override
    public void close() throws IOException {
        if (dataFile == null) {
            appender.close();
            // 构建 DataFile 元数据
            this.dataFile = DataFiles.builder(spec)
                .withFormat(format)
                .withPath(location)
                .withPartition(partition)
                .withFileSizeInBytes(appender.length())
                .withMetrics(appender.metrics())        // 列统计信息
                .withSplitOffsets(appender.splitOffsets()) // Row Group 偏移
                .withSortOrder(sortOrder)
                .build();
        }
    }
}
```

**DataFile 包含的元数据**:

```
DataFile {
  path: "/data/dt=2026-04-27/00003-7-uuid-00001.parquet"
  format: PARQUET
  partition: {dt=20568}
  recordCount: 125000
  fileSizeInBytes: 134217728  (128MB)
  columnSizes: {1→4MB, 2→8MB, ...}
  valueCounts: {1→125000, 2→125000}
  nullValueCounts: {1→0, 2→50}
  lowerBounds: {1→100, 2→"Alice"}
  upperBounds: {1→999999, 2→"Zoe"}
  splitOffsets: [0, 33554432, 67108864, 100663296]
  sortOrder: id ASC
}
```

---

## 四、RollingDataWriter — 文件滚动切分

**源码位置**: `core/src/main/java/org/apache/iceberg/io/RollingDataWriter.java`

```java
public class RollingDataWriter<T>
    extends RollingFileWriter<T, DataWriter<T>, DataWriteResult> {

    private final FileWriterFactory<T> writerFactory;
    private final List<DataFile> dataFiles;

    // 当文件大小 > targetFileSizeInBytes 时自动切分
    // 继承自 RollingFileWriter:
    //   write(row) → currentWriter.write(row)
    //   if (currentWriter.length() >= targetSize) {
    //     closeCurrentWriter()
    //     openNewWriter()
    //   }

    @Override
    protected DataWriter<T> newWriter(EncryptedOutputFile file) {
        return writerFactory.newDataWriter(file, spec(), partition());
    }

    @Override
    protected void addResult(DataWriteResult result) {
        dataFiles.addAll(result.dataFiles());
    }
}
```

---

## 五、TaskWriter — 任务级写入器

**源码位置**: `core/src/main/java/org/apache/iceberg/io/BaseTaskWriter.java`

### 5.1 接口定义

```java
public interface TaskWriter<T> extends Closeable {
    void write(T row) throws IOException;
    void abort() throws IOException;         // 清理已写文件
    WriteResult complete() throws IOException; // 关闭并返回结果
}
```

### 5.2 BaseTaskWriter — 抽象基类

```java
public abstract class BaseTaskWriter<T> implements TaskWriter<T> {
    private final List<DataFile> completedDataFiles;
    private final List<DeleteFile> completedDeleteFiles;

    private final PartitionSpec spec;
    private final FileFormat format;
    private final FileAppenderFactory<T> appenderFactory;
    private final OutputFileFactory fileFactory;
    private final FileIO io;
    private final long targetFileSize;

    // abort — 清理已写的所有文件
    @Override
    public void abort() throws IOException {
        close();
        Tasks.foreach(concat(completedDataFiles, completedDeleteFiles))
            .executeWith(ThreadPools.getWorkerPool())
            .noRetry()
            .run(file -> io.deleteFile(file.path().toString()));
    }

    // complete — 返回写入结果
    @Override
    public WriteResult complete() throws IOException {
        close();
        return WriteResult.builder()
            .addDataFiles(completedDataFiles)
            .addDeleteFiles(completedDeleteFiles)
            .addReferencedDataFiles(referencedDataFiles)
            .build();
    }
}
```

### 5.3 三种写入模式

```
1. UnpartitionedWriter（无分区）
   所有数据写入同一个 RollingDataWriter
   
2. PartitionedWriter（分区 — Clustered 模式）
   要求数据按分区排序到达
   每次分区切换时关闭当前 writer，打开新 writer
   内存效率高，但要求上游做 Sort/Hash Shuffle
   
3. FanoutWriter（分区 — Fanout 模式）
   同时为多个分区维护 writer
   数据可以乱序到达
   内存占用更高（每个分区一个 writer buffer）
```

---

## 六、Spark Write 入口

**源码位置**: `spark/v3.5/spark/src/main/java/org/apache/iceberg/spark/source/SparkWrite.java`

```java
public abstract class SparkWrite implements Write, RequiresDistributionAndOrdering {
    private final Table table;
    private final SparkWriteConf writeConf;
    private final FileFormat format;
    private final long targetFileSize;

    // 数据分布策略
    @Override
    public Distribution requiredDistribution() {
        // none: 不做分布（使用 FanoutWriter）
        // hash: 按分区 hash 分布（使用 PartitionedWriter）
        // range: 按分区+排序 range 分布
    }

    // 排序策略
    @Override
    public SortOrder[] requiredOrdering() {
        // 按分区字段 + 用户定义的 sort order 排序
    }
}
```

**写入提交流程**:

```
Spark Driver:
  1. SparkWrite.toBatchWrite() → 创建 BatchWrite
  2. BatchWrite.createBatchWriterFactory() → 创建 WriterFactory
  3. 分发给各 Executor

Spark Executor (并行):
  4. WriterFactory.createWriter() → 创建 TaskWriter
  5. TaskWriter.write(row) → 循环写入
  6. TaskWriter.complete() → 返回 WriteResult

Spark Driver:
  7. BatchWrite.commit(WriterCommitMessage[])
     → 收集所有 Executor 的 DataFile/DeleteFile
     → table.newAppend().appendFile(dataFile).commit()
     → 或 table.newRowDelta().addRows(dataFile).addDeletes(deleteFile).commit()
     → 生成新 Snapshot
```

---

## 七、文件格式与列统计

```
Parquet 文件内部结构:
  ┌──────────────────────────┐
  │ Row Group 1 (128MB max)  │ ← splitOffset[0]
  │   Column Chunk: order_id │ → min=1, max=50000
  │   Column Chunk: amount   │ → min=0.01, max=9999.99
  │   Column Chunk: region   │ → min="AS", max="US"
  │   ...                    │
  ├──────────────────────────┤
  │ Row Group 2              │ ← splitOffset[1]
  │   ...                    │
  ├──────────────────────────┤
  │ Footer                   │
  │   Schema, Row Group Info │
  │   Column Statistics       │
  └──────────────────────────┘

Iceberg 利用这些统计信息做:
  1. File-level pruning: min/max 不满足查询条件 → 跳过整个文件
  2. Row Group pruning: min/max 不满足 → 跳过特定 Row Group
  3. Column projection: 只读需要的列
```

---

## 八、写入参数调优

| 参数 | 含义 | 推荐值 |
|------|------|--------|
| `write.target-file-size-bytes` | 目标文件大小 | `134217728` (128MB) |
| `write.format.default` | 文件格式 | `parquet` |
| `write.parquet.row-group-size-bytes` | Row Group 大小 | `134217728` (128MB) |
| `write.distribution-mode` | 分布模式 | `hash`（分区表） |
| `write.fanout.enabled` | Fanout 写入 | `true`（小分区数） |
| `write.metadata.compression-codec` | 元数据压缩 | `gzip` |
| `write.parquet.compression-codec` | 数据压缩 | `zstd` (推荐) |
| `write.parquet.dict-size-bytes` | 字典大小 | `2097152` (2MB) |

```sql
ALTER TABLE catalog.db.orders SET TBLPROPERTIES (
    'write.target-file-size-bytes' = '134217728',
    'write.parquet.compression-codec' = 'zstd',
    'write.distribution-mode' = 'hash'
);
```
