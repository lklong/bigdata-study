# Iceberg 源码深度解析：V2 行级删除 — Equality Delete 与 Position Delete

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-26

---

## 一、V2 行级删除概述

### 1.1 V1 vs V2 删除能力

```
Iceberg V1：
  - 只能删除整个文件（Copy-on-Write）
  - DELETE/UPDATE → 重写整个数据文件
  - 开销大，不适合频繁 upsert

Iceberg V2：
  - 支持行级删除（Merge-on-Read）
  - DELETE/UPDATE → 只写一个小的 delete file
  - 读取时合并 data file + delete file → 过滤被删除的行
  - 两种 delete file：Equality Delete + Position Delete
```

### 1.2 两种 Delete File 对比

```
┌──────────────────────────────────────────────────────────────┐
│              Equality Delete File                            │
│  ┌──────────────────────────────────────────────────┐       │
│  │ equality_field_ids: [user_id]                    │       │
│  │                                                   │       │
│  │ user_id │                                        │       │
│  │ ────────│                                        │       │
│  │ 1001    │  ← 删除 user_id=1001 的所有行          │       │
│  │ 1005    │  ← 删除 user_id=1005 的所有行          │       │
│  │ 1009    │                                        │       │
│  └──────────────────────────────────────────────────┘       │
│  应用范围: 同一分区内所有 sequence number 更早的 data file    │
│  适用场景: DELETE WHERE user_id = 1001                      │
│  优点: 不需要知道行在哪个文件                                │
│  缺点: 读取时需要全分区 Join，慢                            │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│              Position Delete File                            │
│  ┌──────────────────────────────────────────────────┐       │
│  │ file_path                    │ pos │ row(可选)   │       │
│  │ ────────────────────────────│─────│────────────  │       │
│  │ /data/part-00001.parquet    │  42 │ {...}        │       │
│  │ /data/part-00001.parquet    │ 108 │ {...}        │       │
│  │ /data/part-00003.parquet    │   7 │ {...}        │       │
│  └──────────────────────────────────────────────────┘       │
│  应用范围: 精确到文件 + 行号                                  │
│  适用场景: Spark MoR UPDATE（先读取定位 → 再写 pos delete）  │
│  优点: 读取时只需按 (file, pos) 过滤，极快                   │
│  缺点: 需要先读取数据确定行位置                               │
└──────────────────────────────────────────────────────────────┘
```

---

## 二、DeleteFile 接口

**源码位置**: `api/src/main/java/org/apache/iceberg/DeleteFile.java`

```java
public interface DeleteFile extends ContentFile<DeleteFile> {
    // 继承自 ContentFile:
    //   FileContent content()  → EQUALITY_DELETES / POSITION_DELETES
    //   int[] equalityFieldIds()  → Equality Delete 的字段 ID 列表
    //   String referencedDataFile() → Position Delete 关联的数据文件

    List<Long> splitOffsets();  // 推荐的分割偏移量
}
```

**FileContent 枚举**:

```java
public enum FileContent {
    DATA(0),                // content=0: 数据文件
    POSITION_DELETES(1),    // content=1: 位置删除文件
    EQUALITY_DELETES(2);    // content=2: 等值删除文件
}
```

---

## 三、RowDelta — 行级变更 API

**源码位置**: `api/src/main/java/org/apache/iceberg/RowDelta.java`

```java
public interface RowDelta extends SnapshotUpdate<RowDelta> {
    RowDelta addRows(DataFile inserts);                      // 添加数据文件（INSERT）
    RowDelta addDeletes(DeleteFile deletes);                  // 添加删除文件（DELETE）
    RowDelta removeDeletes(DeleteFile deletes);               // 移除已重写的删除文件
    RowDelta validateFromSnapshot(long snapshotId);           // 设置验证起点
    RowDelta conflictDetectionFilter(Expression expr);        // 冲突检测过滤器
    RowDelta validateNoConflictingDataFiles();                // 验证无冲突数据文件
    RowDelta validateNoConflictingDeleteFiles();              // 验证无冲突删除文件
    RowDelta validateDataFilesExist(Iterable<> refs);         // 验证引用文件存在
    RowDelta validateDeletedFiles();                          // 验证文件未被删除
}
```

**隔离级别控制**:

```
Snapshot Isolation（默认）:
  rowDelta.addDeletes(deleteFile).commit();
  → 不做冲突检测，允许并发写入

Serializable Isolation:
  rowDelta
    .validateFromSnapshot(readSnapshotId)
    .conflictDetectionFilter(filter)
    .validateNoConflictingDataFiles()   // ← Serializable 必需
    .validateNoConflictingDeleteFiles() // ← UPDATE/MERGE 必需
    .addDeletes(deleteFile)
    .commit();
```

---

## 四、EqualityDeleteWriter — 等值删除写入

**源码位置**: `core/src/main/java/org/apache/iceberg/deletes/EqualityDeleteWriter.java`

```java
public class EqualityDeleteWriter<T> implements FileWriter<T, DeleteWriteResult> {
    private final FileAppender<T> appender;
    private final int[] equalityFieldIds;    // 等值匹配的字段 ID
    private final SortOrder sortOrder;       // 删除文件的排序

    @Override
    public void write(T row) {
        appender.add(row);  // 只写等值字段的值
    }

    @Override
    public void close() throws IOException {
        appender.close();
        this.deleteFile = FileMetadata.deleteFileBuilder(spec)
            .ofEqualityDeletes(equalityFieldIds)  // ← 标记为 equality delete
            .withFormat(format)
            .withPath(location)
            .withPartition(partition)
            .withFileSizeInBytes(appender.length())
            .withMetrics(appender.metrics())
            .withSortOrder(sortOrder)
            .build();
    }
}
```

**Equality Delete 的匹配规则**:

```
对于 equality_field_ids = [user_id]:
  delete file 中每一行包含: {user_id: 1001}
  
  匹配条件:
  1. 同一分区内的数据文件
  2. 数据文件的 sequence number < delete 文件的 sequence number
  3. 数据行的 user_id = 1001 → 被删除

  sequence number 是关键！确保只删除"比 delete file 更早写入的数据"
```

---

## 五、PositionDeleteWriter — 位置删除写入

**源码位置**: `core/src/main/java/org/apache/iceberg/deletes/PositionDeleteWriter.java`

```java
public class PositionDeleteWriter<T> implements FileWriter<PositionDelete<T>, DeleteWriteResult> {
    private final FileAppender<PositionDelete<T>> appender;
    private final CharSequenceSet referencedDataFiles;  // 跟踪引用了哪些数据文件

    @Override
    public void write(PositionDelete<T> posDelete) {
        // posDelete 包含: file_path + pos + 可选的 row
        referencedDataFiles.add(posDelete.path());  // 记录引用的数据文件
        appender.add(posDelete);
    }

    @Override
    public void close() throws IOException {
        appender.close();
        // 构建 delete file 元数据
        this.deleteFile = FileMetadata.deleteFileBuilder(spec)
            .ofPositionDeletes()                       // ← 标记为 position delete
            .withFormat(format)
            .withPath(location)
            .withPartition(partition)
            .withFileSizeInBytes(appender.length())
            .withMetrics(buildMetrics())               // 若仅引用一个文件，保留 bounds
            .withReferencedDataFile(referencedDataFile) // V2 可选关联
            .build();
    }
}
```

**Position Delete Schema**:

```java
// DeleteSchemaUtil.java
// 不带行数据（只记录位置）
Schema pathPosSchema = new Schema(
    MetadataColumns.DELETE_FILE_PATH,   // file_path STRING
    MetadataColumns.DELETE_FILE_POS     // pos LONG
);

// 带行数据（可选，用于加速 Merge-on-Read）
Schema pathPosRowSchema = new Schema(
    MetadataColumns.DELETE_FILE_PATH,
    MetadataColumns.DELETE_FILE_POS,
    MetadataColumns.DELETE_FILE_ROW     // row STRUCT<...> 完整行
);
```

---

## 六、DeleteFileIndex — 读取时的删除文件索引

**源码位置**: `core/src/main/java/org/apache/iceberg/DeleteFileIndex.java`

```java
class DeleteFileIndex {
    private final EqualityDeletes globalDeletes;                   // 全局 equality deletes
    private final PartitionMap<EqualityDeletes> eqDeletesByPartition; // 按分区的 eq deletes
    private final PartitionMap<PositionDeletes> posDeletesByPartition; // 按分区的 pos deletes
    private final Map<String, PositionDeletes> posDeletesByPath;      // 按文件路径的 pos deletes

    // 核心方法: 给定一个 data file，返回需要应用的所有 delete files
    DeleteFile[] forDataFile(long dataSequenceNumber, DataFile dataFile) {
        List<DeleteFile> result = Lists.newArrayList();

        // 1. 查找 Position Deletes
        if (hasPosDeletes) {
            // 按文件路径精确匹配 + 按分区匹配
            PositionDeletes pathDeletes = posDeletesByPath.get(dataFile.path());
            PositionDeletes partDeletes = posDeletesByPartition.get(spec, partition);
            // 合并两类 position deletes
        }

        // 2. 查找 Equality Deletes
        if (hasEqDeletes) {
            // 全局 equality deletes
            if (globalDeletes != null) {
                globalDeletes.filter(dataSequenceNumber, result);
            }
            // 按分区的 equality deletes
            EqualityDeletes partEqDeletes = eqDeletesByPartition.get(spec, partition);
            if (partEqDeletes != null) {
                partEqDeletes.filter(dataSequenceNumber, result);
                // 只应用 sequence number > data file 的 delete files！
            }
        }

        return result.toArray(EMPTY_DELETES);
    }
}
```

**Sequence Number 过滤关键逻辑**:

```
Equality Delete 文件的 sequence_number = 100
Data File A 的 sequence_number = 50   → 会被过滤（50 < 100）
Data File B 的 sequence_number = 120  → 不会被过滤（120 > 100）

这就是 V2 的核心设计：delete file 只影响"比自己更早"的数据！
```

---

## 七、Merge-on-Read 读取流程

```
查询: SELECT * FROM orders WHERE created_at > '2026-04-25'
  │
  ├── 1. Scan Planning（ManifestGroup）
  │      扫描 data manifests + delete manifests
  │      构建 DeleteFileIndex
  │
  ├── 2. 对每个 DataFile，查找关联的 DeleteFiles
  │      DeleteFile[] deletes = deleteIndex.forDataFile(seqNum, dataFile)
  │      构建 FileScanTask(dataFile, deletes)
  │
  ├── 3. 读取 DataFile
  │      DataReader 读取 Parquet/ORC 数据行
  │
  ├── 4. 应用 Position Deletes
  │      PositionDeleteIndex: 构建 (file, pos) → bitmap
  │      按行号过滤: if posDeleteBitmap.contains(rowIndex) → 跳过
  │
  ├── 5. 应用 Equality Deletes
  │      EqualityDeleteIndex: 构建等值字段 → hash set
  │      按字段匹配: if eqDeleteSet.contains(row.getField(eqFieldId)) → 跳过
  │
  └── 6. 返回过滤后的结果
```

---

## 八、写入路径选择

### 8.1 Copy-on-Write (CoW)

```sql
-- Spark 默认 V2 写入
SET spark.sql.catalog.mycatalog.write.delete.mode = copy-on-write;

DELETE FROM orders WHERE user_id = 1001;
-- 重写包含 user_id=1001 的整个文件
-- 新文件不包含被删除的行
-- 快读慢写
```

### 8.2 Merge-on-Read (MoR)

```sql
SET spark.sql.catalog.mycatalog.write.delete.mode = merge-on-read;

DELETE FROM orders WHERE user_id = 1001;
-- 写一个 equality delete file: {user_id: 1001}
-- 不重写数据文件
-- 快写慢读（读时需要 merge）

UPDATE orders SET amount = 100 WHERE order_id = 42;
-- 1. 读取 order_id=42 所在的 (file, pos)
-- 2. 写一个 position delete file: {file_path, pos=42}
-- 3. 写一个新的 data file: {新行数据}
```

---

## 九、Delete File 堆积与治理

### 9.1 问题

```
频繁 MoR 操作 → delete file 持续堆积
  → 读取时需要 merge 大量 delete files
  → 查询性能严重退化

监控指标:
  SELECT content, count(*), sum(file_size_in_bytes)
  FROM db.orders.files
  GROUP BY content;
  -- content=0: data, content=1: position deletes, content=2: equality deletes
```

### 9.2 治理手段

```sql
-- 1. rewrite_data_files: 合并 data + delete → 新的纯净 data files
CALL catalog.system.rewrite_data_files(table => 'db.orders');

-- 2. rewrite_position_deletes: 合并多个小 position delete 文件
CALL catalog.system.rewrite_position_delete_files(table => 'db.orders');

-- 3. Amoro Self-Optimizing: 自动执行上述操作
-- 无需手动干预，Amoro 检测到 delete file 堆积后自动触发 Major Optimize
```

---

## 十、关键设计总结

| 设计 | 目的 |
|------|------|
| **Sequence Number** | 确保 delete file 只影响更早的数据，新数据不受影响 |
| **Equality Delete 全分区匹配** | 不需要知道行位置，适合 batch DELETE |
| **Position Delete 精确匹配** | file_path + pos 精确定位，读取更快 |
| **DeleteFileIndex 缓存** | 按分区/路径索引 delete files，避免全表扫描 |
| **RowDelta 冲突检测** | serializable isolation 保证并发安全 |
| **VoidTransform 兼容** | delete file 也记录 partition，支持分区裁剪 |
