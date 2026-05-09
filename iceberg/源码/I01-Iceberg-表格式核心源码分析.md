# Iceberg 表格式核心源码分析

> **源码路径**：
> - `txProjects/iceberg/api/src/main/java/org/apache/iceberg/Table.java`
> - `txProjects/iceberg/core/src/main/java/org/apache/iceberg/BaseTable.java`
> - `txProjects/iceberg/core/src/main/java/org/apache/iceberg/TableMetadata.java`
> - `txProjects/iceberg/core/src/main/java/org/apache/iceberg/SnapshotProducer.java`
> - `txProjects/iceberg/core/src/main/java/org/apache/iceberg/hadoop/HadoopTableOperations.java`
>
> **铁律遵守**：所有代码片段、行号均来自上述真实源码

---

## 一、Iceberg 三层抽象

```
┌─────────────────────────────────────┐
│  api/      Table.java               │  ← 接口层（用户编程入口）
│  core/     BaseTable.java           │  ← 实现层（绑定 TableOperations）
│            TableMetadata.java       │  ← 元数据模型
│            SnapshotProducer.java    │  ← 写入抽象（commit 重试）
│            HadoopTableOperations    │  ← FS 后端实现
│            HiveCatalog              │  ← HMS 后端实现
└─────────────────────────────────────┘
```

---

## 二、Table 接口设计（Table.java）

### 2.1 完整 API 入口

```java
27: /** Represents a table. */
28: public interface Table {

35:   default String name() {
36:     return toString();
37:   }

39:   /** Refresh the current table metadata. */
40:   void refresh();

49:   TableScan newScan();

58:   default BatchScan newBatchScan() {
59:     return new BatchScanAdapter(newScan());
60:   }

69:   default IncrementalAppendScan newIncrementalAppendScan() {
70:     throw new UnsupportedOperationException("Incremental append scan is not supported");
71:   }

80:   default IncrementalChangelogScan newIncrementalChangelogScan() {
```

**核心设计意图**：
- **不可变接口**：`Table` 本身只读，所有写操作通过返回的 `Update*` builder 完成
- **多种 Scan 工厂**：批量、增量 append、增量 changelog 三类
- **default 方法**：保证向后兼容，旧 catalog 实现不需要改代码

---

## 三、BaseTable 实现（BaseTable.java）

### 3.1 类定义（BaseTable.java:39-47）

```java
39: public class BaseTable implements Table, HasTableOperations, Serializable {
40:   private final TableOperations ops;
41:   private final String name;
42:   private final MetricsReporter reporter;
43:
44:   public BaseTable(TableOperations ops, String name) {
45:     this.ops = ops;
46:     this.name = name;
47:     this.reporter = new LoggingMetricsReporter();
48:   }
```

**关键观察**：
- `BaseTable` 只持有 `TableOperations`，所有数据来自 `ops.current()`
- `Serializable` — 支持 Spark task 反序列化（`writeReplace` 转 `SerializableTable`）

### 3.2 元数据访问（BaseTable.java:88-145）

```java
88:   @Override
89:   public Schema schema() {
90:     return ops.current().schema();      // ⭐ 通过 ops 拿当前 metadata
91:   }
92:
   ...
98:   public PartitionSpec spec() {
99:     return ops.current().spec();
100:   }
   ...
128:   public Snapshot currentSnapshot() {
129:     return ops.current().currentSnapshot();
130:   }
   ...
138:   public Iterable<Snapshot> snapshots() {
139:     return ops.current().snapshots();
140:   }
142:   @Override
143:   public List<HistoryEntry> history() {
144:     return ops.current().snapshotLog();
145:   }
```

**核心设计**：
- 所有读取**永远走 `ops.current()`**，由 ops 决定是否需要 refresh
- 多次调用 `ops.current()` 在快照内是幂等的

### 3.3 写入操作工厂（BaseTable.java:172-209）

```java
172:   @Override
173:   public AppendFiles newAppend() {
174:     return new MergeAppend(name, ops);     // 默认走 MergeAppend
175:   }
176:
177:   @Override
178:   public AppendFiles newFastAppend() {
179:     return new FastAppend(name, ops);      // 不合并 manifest，更快
180:   }
181:
182:   @Override
183:   public RewriteFiles newRewrite() {
184:     return new BaseRewriteFiles(name, ops);
185:   }
   ...
192:   public OverwriteFiles newOverwrite() {
193:     return new BaseOverwriteFiles(name, ops);
194:   }
   ...
197:   public RowDelta newRowDelta() {
198:     return new BaseRowDelta(name, ops);    // 行级删除（v2 表）
199:   }
   ...
207:   public DeleteFiles newDelete() {
208:     return new StreamingDelete(name, ops);
209:   }
```

**写入操作分类**：
| 方法 | 实现类 | 用途 |
|------|--------|------|
| `newAppend()` | MergeAppend | 默认追加，合并小 manifest |
| `newFastAppend()` | FastAppend | 流写入，不合并 manifest |
| `newOverwrite()` | BaseOverwriteFiles | 整批替换分区 |
| `newReplacePartitions()` | BaseReplacePartitions | Hive 风格动态分区覆盖 |
| `newRowDelta()` | BaseRowDelta | v2 表的 MERGE INTO 行级 |
| `newDelete()` | StreamingDelete | DELETE FROM 分区级 |
| `newRewrite()` | BaseRewriteFiles | 小文件合并 |

### 3.4 序列化优化（BaseTable.java:262-264）

```java
262:   Object writeReplace() {
263:     return SerializableTable.copyOf(this);
264:   }
```

**Spark 场景**：Driver 端的 BaseTable 序列化到 Executor 时，转成 `SerializableTable`（不再持有 catalog 引用），避免 task 反序列化时再连 HMS。

---

## 四、TableMetadata 不可变模型

### 4.1 关键常量（TableMetadata.java:48-56）

```java
48: public class TableMetadata implements Serializable {
49:   static final long INITIAL_SEQUENCE_NUMBER = 0;
50:   static final long INVALID_SEQUENCE_NUMBER = -1;
51:   static final int DEFAULT_TABLE_FORMAT_VERSION = 1;
52:   static final int SUPPORTED_TABLE_FORMAT_VERSION = 2;
53:   static final int INITIAL_SPEC_ID = 0;
54:   static final int INITIAL_SORT_ORDER_ID = 1;
55:   static final int INITIAL_SCHEMA_ID = 0;
```

**版本支持**：当前最高 v2（含 row-level delete），v3 草案中。

### 4.2 newTableMetadata 工厂（TableMetadata.java:88-132）

```java
88:   static TableMetadata newTableMetadata(
89:       Schema schema,
90:       PartitionSpec spec,
91:       SortOrder sortOrder,
92:       String location,
93:       Map<String, String> properties,
94:       int formatVersion) {
   ...
100:     // reassign all column ids to ensure consistency
101:     AtomicInteger lastColumnId = new AtomicInteger(0);
102:     Schema freshSchema =
103:         TypeUtil.assignFreshIds(INITIAL_SCHEMA_ID, schema, lastColumnId::incrementAndGet);
104:
105:     // rebuild the partition spec using the new column ids
106:     PartitionSpec.Builder specBuilder =
107:         PartitionSpec.builderFor(freshSchema).withSpecId(INITIAL_SPEC_ID);
   ...
124:     return new Builder()
125:         .upgradeFormatVersion(formatVersion)
126:         .setCurrentSchema(freshSchema, lastColumnId.get())
127:         .setDefaultPartitionSpec(freshSpec)
128:         .setDefaultSortOrder(freshSortOrder)
129:         .setLocation(location)
130:         .setProperties(properties)
131:         .build();
132:   }
```

**关键设计：Fresh ID 重分配**
- 用户传入的 Schema 字段可能没有 ID（或冲突）
- Iceberg 强制分配全局唯一的整数 ID
- **支持后续 Schema Evolution**（重命名列不破坏数据）

---

## 五、SnapshotProducer.commit 核心提交逻辑

### 5.1 commit 重试框架（SnapshotProducer.java:355-394）

```java
355:   public void commit() {
356:     // this is always set to the latest commit attempt's snapshot id.
357:     AtomicLong newSnapshotId = new AtomicLong(-1L);
358:     try {
359:       Tasks.foreach(ops)
360:           .retry(base.propertyAsInt(COMMIT_NUM_RETRIES, COMMIT_NUM_RETRIES_DEFAULT))
361:           .exponentialBackoff(
362:               base.propertyAsInt(COMMIT_MIN_RETRY_WAIT_MS, COMMIT_MIN_RETRY_WAIT_MS_DEFAULT),
363:               base.propertyAsInt(COMMIT_MAX_RETRY_WAIT_MS, COMMIT_MAX_RETRY_WAIT_MS_DEFAULT),
364:               base.propertyAsInt(COMMIT_TOTAL_RETRY_TIME_MS, COMMIT_TOTAL_RETRY_TIME_MS_DEFAULT),
365:               2.0 /* exponential */)
366:           .onlyRetryOn(CommitFailedException.class)
367:           .run(
368:               taskOps -> {
369:                 Snapshot newSnapshot = apply();   // ⭐ 子类实现
370:                 newSnapshotId.set(newSnapshot.snapshotId());
371:                 TableMetadata.Builder update = TableMetadata.buildFrom(base);
372:                 if (base.snapshot(newSnapshot.snapshotId()) != null) {
373:                   // this is a rollback operation
374:                   update.setBranchSnapshot(newSnapshot.snapshotId(), targetBranch);
375:                 } else if (stageOnly) {
376:                   update.addSnapshot(newSnapshot);
377:                 } else {
378:                   update.setBranchSnapshot(newSnapshot, targetBranch);
379:                 }
380:
381:                 TableMetadata updated = update.build();
382:                 if (updated.changes().isEmpty()) {
383:                   return;
384:                 }
385:
386:                 // if the table UUID is missing, add it here.
   ...
393:                 taskOps.commit(base, updated.withUUID());
394:               });
```

**核心设计**：
- **指数退避重试**：默认 4 次重试，基础间隔 100ms，2 倍递增
- **CommitFailedException 触发重试**：对应"乐观锁冲突"
- **每次重试都重新 apply()**：因为 base metadata 可能已被其他 commit 修改

### 5.2 提交后清理（SnapshotProducer.java:402-432）

```java
402:     try {
403:       LOG.info("Committed snapshot {} ({})", newSnapshotId.get(), getClass().getSimpleName());
404:
405:       // at this point, the commit must have succeeded.
406:       Snapshot saved = ops.refresh().snapshot(newSnapshotId.get());
407:       if (saved != null) {
408:         cleanUncommitted(Sets.newHashSet(saved.allManifests(ops.io())));
409:         // also clean up unused manifest lists created by multiple attempts
410:         for (String manifestList : manifestLists) {
411:           if (!saved.manifestListLocation().equals(manifestList)) {
412:             deleteFile(manifestList);
413:           }
414:         }
415:       }
   ...
427:     try {
428:       notifyListeners();
429:     } catch (Throwable e) {
430:       LOG.warn("Failed to notify event listeners", e);
431:     }
432:   }
```

**孤儿文件清理**：
- 多次重试可能产生多份临时 manifest_list 文件
- commit 成功后，删除非最终 snapshot 引用的中间文件

---

## 六、HadoopTableOperations.commit 原子提交

### 6.1 commit 入口（HadoopTableOperations.java:130-172）

```java
130:   @Override
131:   public void commit(TableMetadata base, TableMetadata metadata) {
132:     Pair<Integer, TableMetadata> current = versionAndMetadata();
133:     if (base != current.second()) {
134:       throw new CommitFailedException("Cannot commit changes based on stale table metadata");
135:     }
   ...
142:     Preconditions.checkArgument(
143:         base == null || base.location().equals(metadata.location()),
144:         "Hadoop path-based tables cannot be relocated");
   ...
149:     String codecName =
150:         metadata.property(
151:             TableProperties.METADATA_COMPRESSION, TableProperties.METADATA_COMPRESSION_DEFAULT);
152:     TableMetadataParser.Codec codec = TableMetadataParser.Codec.fromName(codecName);
153:     String fileExtension = TableMetadataParser.getFileExtension(codec);
154:     Path tempMetadataFile = metadataPath(UUID.randomUUID().toString() + fileExtension);
155:     TableMetadataParser.write(metadata, io().newOutputFile(tempMetadataFile.toString()));
156:
157:     int nextVersion = (current.first() != null ? current.first() : 0) + 1;
158:     Path finalMetadataFile = metadataFilePath(nextVersion, codec);
159:     FileSystem fs = getFileSystem(tempMetadataFile, conf);
160:
161:     // this rename operation is the atomic commit operation
162:     renameToFinal(fs, tempMetadataFile, finalMetadataFile, nextVersion);   // ⭐ 原子 rename
163:
164:     LOG.info("Committed a new metadata file {}", finalMetadataFile);
165:
166:     // update the best-effort version pointer
167:     writeVersionHint(nextVersion);
168:
169:     deleteRemovedMetadataFiles(base, metadata);
170:
171:     this.shouldRefresh = true;
172:   }
```

**HadoopCatalog 原子性的核心**：
1. **乐观锁**：`base != current.second()` 检测 ABA
2. **临时文件 + rename**：先写 UUID 临时文件，再 rename 到 `vN.metadata.json`
3. **Rename 原子性**：依赖 HDFS / S3-Hadoop 的 rename 语义
4. **version-hint.txt**：best-effort 指针，提供快速读路径（坏掉时 fallback 到 ls 扫描）

**S3 坑点**：S3 没有原子 rename！必须用 HiveCatalog 或 GlueCatalog 提供锁。

---

## 七、Iceberg Commit 全流程

```
用户调用 table.newAppend().appendFile(f1).commit()
                ↓
SnapshotProducer.commit()                  [SnapshotProducer.java:355]
   ├─ Tasks.retry(4 次).run()
   │     ├─ apply() → 生成新 Snapshot
   │     ├─ TableMetadata.buildFrom(base).setBranchSnapshot(newSnapshot)
   │     ├─ ops.commit(base, updated)      ← 实际提交
   │     │   ↓
   │     │  HadoopTableOperations.commit()  [HadoopTableOperations.java:130]
   │     │     ├─ check base == current   ← 乐观锁
   │     │     ├─ 写 temp UUID.metadata.json
   │     │     ├─ rename(temp → vN.metadata.json)  ← 原子提交
   │     │     ├─ write version-hint.txt
   │     │     └─ delete 旧文件
   │     │
   │     └─ 失败 CommitFailedException → 重试
   │
   ├─ ops.refresh()
   ├─ cleanUncommitted(中间 manifest)
   └─ notifyListeners()
```

---

## 八、关键文件结构

```
{table_location}/
├── metadata/
│   ├── version-hint.text        ← "5"（指向当前最新版本）
│   ├── v1.metadata.json
│   ├── v2.metadata.json
│   ├── v3.metadata.json
│   ├── v4.metadata.json
│   ├── v5.metadata.json         ← 当前指针
│   ├── snap-{snapshot_id}-1-{uuid}.avro    ← manifest list
│   └── {uuid}-m0.avro                       ← manifest file
└── data/
    └── {partition_dir}/
        └── {uuid}.parquet
```

---

## 九、生产关注点

### 9.1 元数据膨胀

- 长期 append 后 `metadata/` 下 `vN.metadata.json` 可能上千个
- 配置 `write.metadata.previous-versions-max=100` 限制保留数

### 9.2 小文件合并

```sql
CALL spark_catalog.system.rewrite_data_files(
  table => 'db.table',
  options => map('target-file-size-bytes', '536870912')
);
```

### 9.3 Snapshot Expire

```sql
CALL spark_catalog.system.expire_snapshots(
  table => 'db.table',
  older_than => TIMESTAMP '2024-01-01 00:00:00'
);
```

### 9.4 Manifest Rewrite（GA 优化）

- 多次 append 后 manifest 数量爆炸 → query plan 慢
- 调用 `rewrite_manifests` 合并

---

## 十、Eric 点评

Iceberg 是数据湖三剑客（Iceberg / Hudi / Delta Lake）中**架构最干净的**。它的核心设计哲学：

1. **不可变快照**：每次写入产生新 metadata.json，永不修改旧文件
2. **乐观锁 + 重试**：天然支持高并发，不需要 Hive 那种重量级表锁
3. **元数据 = JSON + Avro**：纯文件即可读写，不依赖任何外部 service（HadoopCatalog 模式）
4. **Pluggable Catalog**：HMS / Glue / Nessie / Polaris 任选，元数据真理来源解耦

**对比 Delta Lake**：Iceberg manifest 比 Delta JSON log 更紧凑，大表 query plan 时间快 3-5 倍。

**对比 Hudi**：Iceberg 不需要 Timeline Server，纯文件就能跑，运维成本低一个数量级。

但 Iceberg 也有它的痛点：
- **小文件 + 频繁 commit 会击穿性能**：每次 commit 都重写整个 metadata.json
- **行级 delete 在 v2 才支持**：MOR 模式仍不如 Hudi 流式优势大
- **HadoopCatalog 在 S3 不可靠**：必须 HiveCatalog/GlueCatalog 承担锁

理解 Iceberg 的"不可变 + 乐观锁"模型，是理解整个现代数据湖（包括 Polaris/Unity Catalog）的钥匙。
