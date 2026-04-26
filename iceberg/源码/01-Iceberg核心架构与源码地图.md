# Iceberg 核心架构与源码地图

> 基于本地源码 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 分析
> Eric | 2026-04-25

---

## 一、模块全景

```
iceberg/
├── api/          ← 核心接口定义（Table、Snapshot、Schema、Scan、Expression）
├── core/         ← 核心实现（TableMetadata、Manifest、Transaction、Commit、Scan Planning）
├── data/         ← 通用数据读写（GenericReader、DeleteFilter）
├── hive-metastore/ ← HiveCatalog 实现
├── spark/        ← Spark 集成（v3.3/v3.4/v3.5）
├── flink/        ← Flink 集成（v1.18/v1.19/v1.20）
├── parquet/      ← Parquet 文件格式支持
├── orc/          ← ORC 文件格式支持
├── arrow/        ← Arrow 向量化读取
├── aws/          ← AWS 集成（GlueCatalog、DynamoDBCatalog、S3FileIO）
├── rest/         ← REST Catalog（core 内部）
└── open-api/     ← REST Catalog OpenAPI 规范
```

---

## 二、核心类关系图

```
┌──────────────────────────────────────────────────────────────────┐
│                        Catalog 层                                │
│  Catalog (api) ──→ BaseMetastoreCatalog (core)                  │
│       ├── HiveCatalog (hive-metastore)                          │
│       ├── HadoopCatalog (core)                                  │
│       ├── JdbcCatalog (core)                                    │
│       ├── RESTCatalog (core)                                    │
│       ├── NessieCatalog (nessie)                                │
│       └── GlueCatalog / DynamoDbCatalog (aws)                   │
└──────────────────────────┬───────────────────────────────────────┘
                           │ loadTable()
┌──────────────────────────▼───────────────────────────────────────┐
│                      Table 层                                    │
│  Table (api) ──→ BaseTable (core)                               │
│       └── HasTableOperations ──→ TableOperations (core)         │
│              ├── HiveTableOperations                             │
│              ├── HadoopTableOperations                           │
│              ├── JdbcTableOperations                             │
│              ├── RESTTableOperations                             │
│              └── GlueTableOperations / DynamoDbTableOperations   │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│                  Metadata 层（核心数据结构）                       │
│                                                                  │
│  TableMetadata (core, 64KB!)                                    │
│    ├── Schema (api) ──→ Types.NestedField                       │
│    ├── PartitionSpec (api) ──→ PartitionField + Transform       │
│    ├── SortOrder                                                 │
│    ├── snapshots: List<Snapshot>                                 │
│    │     └── Snapshot (api) ──→ BaseSnapshot (core)             │
│    │           ├── manifestListLocation → ManifestList          │
│    │           │     └── ManifestFile (api)                     │
│    │           │           └── GenericManifestFile (core)       │
│    │           └── ManifestFile → ManifestEntry                 │
│    │                 └── DataFile / DeleteFile                   │
│    └── refs: Map<String, SnapshotRef>  (branch/tag)             │
└──────────────────────────────────────────────────────────────────┘
```

---

## 三、关键类索引

### 3.1 API 层（接口定义）

| 类 | 路径 | 说明 |
|----|------|------|
| `Table` | `api/.../iceberg/Table.java` | 表顶级接口：schema/spec/snapshots/io/newScan |
| `Snapshot` | `api/.../iceberg/Snapshot.java` | 快照：snapshotId/parentId/manifestListLocation |
| `Schema` | `api/.../iceberg/Schema.java` | Schema：columns/fieldId/evolution |
| `PartitionSpec` | `api/.../iceberg/PartitionSpec.java` | 分区规格：fields/transforms |
| `DataFile` | `api/.../iceberg/DataFile.java` | 数据文件元信息 |
| `ContentFile` | `api/.../iceberg/ContentFile.java` | DataFile + DeleteFile 的父接口 |
| `DeleteFile` | `api/.../iceberg/DeleteFile.java` | 删除文件（Position/Equality） |
| `ManifestFile` | `api/.../iceberg/ManifestFile.java` | Manifest 文件元信息 |
| `Transaction` | `api/.../iceberg/Transaction.java` | 事务接口 |
| `Scan` / `TableScan` | `api/.../iceberg/Scan.java` | 扫描接口 |
| `Expression` | `api/.../iceberg/expressions/Expression.java` | 过滤表达式 |
| `FileIO` | `api/.../iceberg/io/FileIO.java` | 文件 IO 抽象 |
| `Catalog` | `api/.../iceberg/catalog/Catalog.java` | Catalog 接口 |

### 3.2 Core 层（核心实现）

| 类 | 路径 | 核心职责 |
|----|------|---------|
| **TableMetadata** | `core/.../TableMetadata.java` (64KB) | **最核心类**：表的完整元数据，包含 schema/spec/snapshots/properties/refs |
| **BaseTable** | `core/.../BaseTable.java` | Table 实现，持有 TableOperations |
| **TableOperations** | `core/.../TableOperations.java` | 元数据 CRUD 接口，每种 Catalog 有自己的实现 |
| **BaseMetastoreTableOperations** | `core/.../BaseMetastoreTableOperations.java` | TableOps 基类：refresh/commit/乐观锁 |
| **SnapshotProducer** | `core/.../SnapshotProducer.java` | **写入核心**：生成新 Snapshot 的基类 |
| **MergeAppend** | `core/.../MergeAppend.java` | 合并追加（会 rewrite manifest） |
| **FastAppend** | `core/.../FastAppend.java` | 快速追加（只加新 manifest） |
| **BaseOverwriteFiles** | `core/.../BaseOverwriteFiles.java` | 文件覆盖写 |
| **BaseRowDelta** | `core/.../BaseRowDelta.java` | 行级 Delta（MOR 写入） |
| **BaseReplacePartitions** | `core/.../BaseReplacePartitions.java` | 分区替换写 |
| **BaseTransaction** | `core/.../BaseTransaction.java` | 事务实现 |
| **RemoveSnapshots** | `core/.../RemoveSnapshots.java` | 过期快照删除 |
| **ManifestReader** | `core/.../ManifestReader.java` | 读取 Manifest 文件 |
| **ManifestWriter** | `core/.../ManifestWriter.java` | 写入 Manifest 文件 |
| **ManifestListWriter** | `core/.../ManifestListWriter.java` | 写入 ManifestList |
| **ManifestGroup** | `core/.../ManifestGroup.java` | Manifest 分组扫描 |
| **ManifestFilterManager** | `core/.../ManifestFilterManager.java` | Manifest 过滤 |
| **ManifestMergeManager** | `core/.../ManifestMergeManager.java` | Manifest 合并管理 |
| **SchemaUpdate** | `core/.../SchemaUpdate.java` | Schema Evolution 实现 |
| **BaseUpdatePartitionSpec** | `core/.../BaseUpdatePartitionSpec.java` | 分区演化实现 |
| **DataTableScan** | `core/.../DataTableScan.java` | 数据表扫描（计划 FileScanTask） |
| **BaseFileScanTask** | `core/.../BaseFileScanTask.java` | 文件扫描任务 |
| **SnapshotScan** | `core/.../SnapshotScan.java` | 基于快照的扫描 |
| **TableScanContext** | `core/.../TableScanContext.java` | 扫描上下文 |

### 3.3 Actions 层（维护操作）

| 类 | 路径 | 说明 |
|----|------|------|
| `RewriteDataFiles` | `api/.../actions/RewriteDataFiles.java` | Compaction 接口 |
| `RewriteDataFilesSparkAction` | `spark/v3.5/.../RewriteDataFilesSparkAction.java` | Spark Compaction 实现 |
| `SizeBasedFileRewriter` | `core/.../actions/SizeBasedFileRewriter.java` | binpack/sort 策略 |
| `RewriteDataFilesCommitManager` | `core/.../actions/RewriteDataFilesCommitManager.java` | Compaction 提交管理 |
| `ExpireSnapshots` | `api/.../actions/ExpireSnapshots.java` | 过期快照接口 |
| `ExpireSnapshotsSparkAction` | `spark/v3.5/.../ExpireSnapshotsSparkAction.java` | Spark 快照过期实现 |
| `RewriteManifestsSparkAction` | `spark/v3.5/.../RewriteManifestsSparkAction.java` | Manifest 重写 |
| `DeleteOrphanFilesSparkAction` | `spark/v3.5/.../DeleteOrphanFilesSparkAction.java` | 孤立文件清理 |

### 3.4 Catalog 实现

| Catalog | 路径 | 元数据存储 |
|---------|------|-----------|
| **HiveCatalog** | `hive-metastore/.../HiveCatalog.java` | Hive Metastore |
| **HiveTableOperations** | `hive-metastore/.../HiveTableOperations.java` | HMS + 乐观锁 |
| HadoopCatalog | `core/.../hadoop/HadoopCatalog.java` | 文件系统 |
| JdbcCatalog | `core/.../jdbc/JdbcCatalog.java` | JDBC 数据库 |
| RESTCatalog | `core/.../rest/RESTCatalog.java` | REST API |
| GlueCatalog | `aws/.../glue/GlueCatalog.java` | AWS Glue |

---

## 四、核心流程源码路径

### 4.1 写入流程

```
用户 INSERT → Spark/Flink Writer
  → OutputFileFactory.newOutputFile()          # 创建数据文件
  → AppenderFactory.newAppender()              # 写入 Parquet/ORC
  → commit:
      FastAppend / MergeAppend / OverwriteFiles
        → SnapshotProducer.apply()             # 生成新 ManifestFile
        → ManifestWriter.write()               # 写 Manifest
        → ManifestListWriter.write()           # 写 ManifestList
        → TableOperations.commit()             # 原子提交 metadata.json
           → BaseMetastoreTableOperations.commit()
              → refreshFromMetadataLocation()  # 读取最新 metadata
              → 比对 base → 乐观锁检测冲突
              → 写新 metadata.json
              → 更新 Catalog 指针（HMS/JDBC/REST）
```

### 4.2 读取流程

```
用户 SELECT → Spark/Flink Reader
  → TableScan.planFiles()                     # 扫描规划
     → DataTableScan → SnapshotScan
        → 读 metadata.json → 获取 current snapshot
        → 读 ManifestList → 获取 ManifestFile 列表
        → ManifestGroup.planFiles()
           → ManifestReader.read() × N        # 并行读取 Manifest
           → ManifestEvaluator.eval()          # min/max 统计过滤
           → PartitionFilter                   # 分区裁剪
        → 生成 FileScanTask 列表
  → Reader 按 FileScanTask 读取数据文件
```

### 4.3 Compaction 流程

```
CALL system.rewrite_data_files(table => 'db.t')
  → RewriteDataFilesSparkAction.execute()
     → planFileGroups()                        # 按分区分组
        → SizeBasedFileRewriter.planGroups()   # 按大小分组
     → rewriteFiles() per group                # 每组重写
        → 读旧文件 → 写新文件
     → RewriteDataFilesCommitManager.commit()  # 提交
        → RewriteFiles API → SnapshotProducer
```

### 4.4 Schema Evolution 流程

```
ALTER TABLE ADD COLUMN
  → Table.updateSchema()                      # 返回 UpdateSchema
  → SchemaUpdate.addColumn()                  # 记录变更
  → SchemaUpdate.apply()                      # 生成新 Schema（分配新 field_id）
  → SchemaUpdate.commit()                     # 更新 TableMetadata
     → TableMetadata.Builder.setCurrentSchema()
     → TableOperations.commit()               # 原子提交
```

---

## 五、核心设计亮点

### 5.1 乐观并发控制

```java
// BaseMetastoreTableOperations.commit()
while (true) {
  TableMetadata base = current();      // 读取当前 metadata
  TableMetadata updated = update(base); // 应用变更
  // 写新 metadata.json 到存储
  String newMetadataLocation = writeNewMetadata(updated);
  try {
    // 原子更新 Catalog 中的指针（HMS/JDBC 行锁）
    doCommit(base, updated);
    break;
  } catch (CommitFailedException e) {
    // 冲突 → 重试（重新 refresh → 再 apply → 再 commit）
  }
}
```

### 5.2 Field ID 解耦列名

Schema 中每个列有唯一的 `field_id`（递增分配），数据文件按 `field_id` 而非列名存储。这使得 **重命名列不需要重写数据**。

### 5.3 Hidden Partitioning

分区用 Transform 表达式（`days(ts)`、`bucket(16, id)`）而非物理目录。查询引擎自动做 partition pruning，用户不需要感知分区列。

### 5.4 三层元数据

```
metadata.json → manifest-list → manifest → data files
```

每层都有统计信息（min/max/null_count），逐层过滤，避免读取不必要的文件。

---

*Iceberg Source Map v1.0 | Eric | 2026-04-25*
