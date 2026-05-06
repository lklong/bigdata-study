# Amoro 源码深度解析：Mixed-Iceberg 格式 BaseTable 与 ChangeTable 合并机制

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-26

---

## 一、Mixed-Iceberg 格式概述

### 1.1 为什么需要 Mixed-Iceberg？

```
纯 Iceberg 表的局限：
  - 不支持高效 upsert（需要 Equality Delete + Merge-on-Read）
  - 流式写入产生大量小的 Delete File，严重影响读性能
  - 没有原生的 Change Data 概念

Mixed-Iceberg 的解决方案：
  一张逻辑表 = BaseTable + ChangeTable（两个独立的 Iceberg 表）
  
  BaseTable  — 存储最终合并后的数据（类似 LSM-Tree 的 SSTable）
  ChangeTable — 存储增量变更（INSERT/UPDATE/DELETE 的 CDC 记录）
  
  写入路径: 所有变更先写 ChangeTable（追加写，极快）
  读取路径: BaseTable + ChangeTable Merge-on-Read
  合并路径: Amoro Self-Optimizing 定期将 ChangeTable 合并到 BaseTable
```

### 1.2 架构图

```
┌──────────────────────────────────────────────────────┐
│                   KeyedTable (逻辑表)                  │
│                  primaryKeySpec: [order_id]            │
│                                                       │
│  ┌──────────────────────┐  ┌────────────────────────┐ │
│  │     BaseTable        │  │     ChangeTable        │ │
│  │  (Iceberg 表)        │  │  (Iceberg 表)          │ │
│  │                      │  │                        │ │
│  │  存储: 合并后的数据   │  │  存储: 增量 CDC 记录   │ │
│  │  路径: /base/        │  │  路径: /change/        │ │
│  │  文件: data files    │  │  文件: data files      │ │
│  │                      │  │  + 额外元数据列:       │ │
│  │                      │  │    _transaction_id     │ │
│  │                      │  │    _file_offset        │ │
│  │                      │  │    _change_action      │ │
│  │                      │  │    (INSERT/DELETE/      │ │
│  │                      │  │     UPDATE_BEFORE/      │ │
│  │                      │  │     UPDATE_AFTER)       │ │
│  └──────────────────────┘  └────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

---

## 二、BasicKeyedTable — 核心实现

**源码位置**: `amoro-format-iceberg/src/main/java/org/apache/amoro/table/BasicKeyedTable.java`

### 2.1 核心字段

```java
public class BasicKeyedTable implements KeyedTable {
    private final String tableLocation;
    private final PrimaryKeySpec primaryKeySpec;  // 主键定义
    protected final BaseTable baseTable;          // Base Store（合并后数据）
    protected final ChangeTable changeTable;      // Change Store（增量 CDC）
```

### 2.2 双表初始化

```java
// 构造函数 — 接收 BaseTable + ChangeTable
public BasicKeyedTable(
    String tableLocation,
    PrimaryKeySpec keySpec,
    BaseTable baseTable,
    ChangeTable changeTable) {
    this.tableLocation = tableLocation;
    this.primaryKeySpec = keySpec;
    this.baseTable = baseTable;
    this.changeTable = changeTable;
}
```

### 2.3 Schema 同步

```java
@Override
public Schema schema() {
    // 每次获取 Schema 时同步 BaseTable 和 ChangeTable 的 Schema
    KeyedSchemaUpdate.syncSchema(this);
    return baseTable.schema();
}

@Override
public PartitionSpec spec() {
    return baseTable.spec();  // 分区规范统一用 BaseTable 的
}
```

### 2.4 InternalCatalogImpl 中的加载逻辑

```java
// InternalCatalogImpl.java — 加载 Mixed-Iceberg 表
private AmoroTable<?> loadMixedIcebergTable(String db, String tbl, ...) {
    TableMetadata metadata = handler.tableMetadata();

    // 1. 加载 BaseTable
    BaseTable baseTable = loadTableStore(metadata, false);   // isChangeStore = false

    if (InternalTableUtil.isKeyedMixedTable(metadata)) {
        // 2. 加载 ChangeTable（有主键时）
        BaseTable changeTable = loadTableStore(metadata, true);  // isChangeStore = true

        // 3. 构建主键规范
        PrimaryKeySpec keySpec = PrimaryKeySpec.builderFor(baseTable.schema())
            .addColumn(...)  // 从 metadata 提取主键列
            .build();

        // 4. 组装 KeyedTable
        return new BasicKeyedTable(
            metadata.getTableLocation(),
            keySpec,
            new BasicKeyedTable.BaseInternalTable(..., baseTable, ...),
            new BasicKeyedTable.ChangeInternalTable(..., changeTable, ...));
    } else {
        // 无主键 → UnkeyedTable
        return new BasicUnkeyedTable(id, baseTable, fileIO, props);
    }
}
```

### 2.5 Catalog 层面的命名约定

```java
// InternalMixedIcebergCatalog.java
public class InternalMixedIcebergCatalog extends BasicMixedIcebergCatalog {
    // ChangeStore 表名后缀
    public static final String CHANGE_STORE_SEPARATOR = "@";
    // 例如：表 "orders" 的 Change Store 在 REST Catalog 中是 "orders@change"
}

// InternalCatalogImpl.java 中的处理逻辑
private boolean isChangeStoreName(String tableName) {
    return tableName.endsWith("@change");
}
private String realTableName(String tableStoreName) {
    // "orders@change" → "orders"
    return tableStoreName.substring(0, tableStoreName.length() - "@change".length());
}
```

---

## 三、写入路径 — ChangeTable 追加

### 3.1 写入流程

```
Flink/Spark 写入 Mixed-Iceberg 表
  │
  ├── INSERT 操作
  │    → 写入 ChangeTable，_change_action = INSERT
  │
  ├── UPDATE 操作
  │    → 写入 ChangeTable 两条记录：
  │      1. _change_action = UPDATE_BEFORE（旧值）
  │      2. _change_action = UPDATE_AFTER （新值）
  │
  └── DELETE 操作
       → 写入 ChangeTable，_change_action = DELETE
```

### 3.2 ChangeTable 额外元数据列

```
标准数据列 + 以下系统列：
  _transaction_id  BIGINT  — 事务 ID（保证 ChangeTable 内的有序性）
  _file_offset     BIGINT  — 文件内偏移
  _change_action   STRING  — INSERT / DELETE / UPDATE_BEFORE / UPDATE_AFTER
```

---

## 四、Self-Optimizing 合并机制

### 4.1 合并触发

```
TableRuntimeRefreshExecutor 检测到：
  - ChangeTable 有新 Snapshot
  - PendingInput.changeFileCount > 0
  → 标记表为 PENDING 状态
  → OptimizingQueue 调度优化任务
```

### 4.2 MixedIcebergRewriteExecutor — 合并执行器

**源码位置**: `amoro-format-iceberg/src/main/java/org/apache/amoro/optimizing/MixedIcebergRewriteExecutor.java`

```java
public class MixedIcebergRewriteExecutor extends AbstractRewriteFilesExecutor {

    // 数据读取器 — 读取 Base + Change 数据
    @Override
    protected OptimizingDataReader dataReader() {
        return new MixedIcebergOptimizingDataReader(table, structLikeCollections, input);
    }

    // Position Delete 写入器 — 标记被删除的行
    @Override
    protected FileWriter<PositionDelete<Record>, DeleteWriteResult> posWriter() {
        return new MixedTreeNodePosDeleteWriter<>(
            appenderFactory,
            deleteFileFormat(),
            partition(),
            io,
            encryptionManager(),
            getTransactionId(input.rePosDeletedDataFilesForMixed()),
            baseLocation(),
            table.spec());
    }

    // 数据写入器 — 写出合并后的新文件到 BaseTable
    @Override
    protected TaskWriter<Record> dataWriter() {
        return GenericTaskWriters.builderFor(table)
            .withTransactionId(
                table.isKeyedTable()
                    ? getTransactionId(input.rewrittenDataFilesForMixed())
                    : null)
            .withTaskId(0)
            .withTargetFileSize(targetSize())
            .buildBaseWriter();  // ← 写入 BaseTable！
    }
}
```

### 4.3 MixedIcebergOptimizingDataReader — 数据读取

**源码位置**: `amoro-format-iceberg/src/main/java/org/apache/amoro/optimizing/MixedIcebergOptimizingDataReader.java`

```java
public class MixedIcebergOptimizingDataReader implements OptimizingDataReader {
    private final MixedTable table;
    private final RewriteFilesInput input;

    // 读取需要重写的数据
    @Override
    public CloseableIterable<Record> readData() {
        // 使用 GenericKeyedDataReader 读取
        // 自动 Merge-on-Read: BaseTable + ChangeTable → 合并后的结果
        AbstractKeyedDataReader<Record> reader = mixedTableDataReader(table.schema());
        return reader.readData(nodeFileScanTask(input.rewrittenDataFilesForMixed()));
    }

    // 读取需要生成 Position Delete 的数据
    @Override
    public CloseableIterable<Record> readDeletedData() {
        Schema schema = new Schema(
            MetadataColumns.FILE_PATH,
            MetadataColumns.ROW_POSITION,
            MetadataColumns.TREE_NODE_FIELD);
        AbstractKeyedDataReader<Record> reader = mixedTableDataReader(schema);
        return reader.readDeletedData(nodeFileScanTask(input.rePosDeletedDataFilesForMixed()));
    }
}
```

### 4.4 完整合并流程

```
Optimizer 执行 Mixed-Iceberg 优化任务
  │
  ├── 1. MixedIcebergOptimizingDataReader.readData()
  │      读取 BaseTable 旧文件 + ChangeTable 增量数据
  │      通过主键合并（Merge-on-Read）得到最终数据
  │
  ├── 2. MixedIcebergRewriteExecutor.dataWriter()
  │      将合并后的数据写入 BaseTable 新文件
  │      buildBaseWriter() → 写入 /base/ 目录
  │
  ├── 3. MixedIcebergRewriteExecutor.posWriter()
  │      为被删除的行生成 Position Delete 文件
  │
  ├── 4. 提交到 AMS
  │      RewriteFilesOutput {
  │        dataFiles: [新的 base 文件]
  │        deleteFiles: [新的 position delete 文件]
  │      }
  │
  └── 5. UnKeyedTableCommit / KeyedTableCommit
         对 BaseTable 执行 Iceberg Rewrite 提交：
           - deleteFile(旧 base 文件)
           - deleteFile(旧 change 文件) ← 清理已合并的 change 数据
           - addFile(新 base 文件)
         原子提交！
```

---

## 五、读取路径 — Merge-on-Read

```
查询 Mixed-Iceberg 表
  │
  ├── BasicKeyedTableScan
  │    同时扫描 BaseTable 和 ChangeTable
  │
  ├── GenericKeyedDataReader
  │    对每个分区/文件组：
  │    1. 读取 BaseTable 数据
  │    2. 读取 ChangeTable 增量
  │    3. 按主键合并：
  │       - ChangeTable DELETE → 从结果中移除该行
  │       - ChangeTable UPDATE_AFTER → 替换 BaseTable 中的旧行
  │       - ChangeTable INSERT → 添加到结果
  │    4. 输出合并后的 Record
  │
  └── 返回给查询引擎
```

---

## 六、Minor vs Major Optimize

### 6.1 Minor Optimize（快速合并）

```
目标: 快速减少 ChangeTable 文件数量
范围: 只合并 ChangeTable 内的小文件
结果: ChangeTable 小文件 → 更大的 ChangeTable 文件
不涉及 BaseTable！
```

### 6.2 Major Optimize（完整合并）

```
目标: 将 ChangeTable 数据合并到 BaseTable
范围: BaseTable + ChangeTable 全量合并
结果: 
  - BaseTable 旧文件 + ChangeTable 文件 → BaseTable 新文件
  - ChangeTable 文件被清理
等效于: 一次完整的 Compaction
```

### 6.3 MixedIcebergPartitionPlan 中的决策

```java
// MixedIcebergPartitionPlan.java (简化)
// Minor 触发: change 文件数 > minor-trigger-file-count
// Major 触发: 
//   - base 文件数 > major-trigger-file-count
//   - 或 change 文件过多导致读取退化
//   - 或 delete file 堆积
```

---

## 七、与纯 Iceberg 的对比

| 维度 | 纯 Iceberg | Mixed-Iceberg |
|------|-----------|---------------|
| 表结构 | 单表 | BaseTable + ChangeTable |
| Upsert | Equality Delete + MoR | ChangeTable CDC + MoR |
| 写入延迟 | 低 | 极低（追加写 ChangeTable） |
| 读取性能 | 高（无 delete 堆积时） | 需要 Merge（change 多时慢） |
| 合并方式 | `rewrite_data_files` | Self-Optimizing（Minor+Major） |
| 主键支持 | V2 支持（通过 delete file） | 原生支持 PrimaryKeySpec |
| 增量消费 | 通过 Snapshot 差异 | ChangeTable 天然是 CDC 流 |
| Catalog | 标准 Iceberg Catalog | AMS 内置 REST Catalog（`@change` 后缀） |

---

## 八、运维建议

### 8.1 何时选择 Mixed-Iceberg

```
选择 Mixed-Iceberg 当：
  ✅ 有频繁的 upsert/delete 操作
  ✅ 需要低延迟写入 + 定期合并
  ✅ 需要原生 CDC 增量消费能力
  ✅ 已部署 Amoro AMS

选择纯 Iceberg 当：
  ✅ 以 append-only 写入为主
  ✅ upsert 频率低
  ✅ 不需要独立的 CDC 流
  ✅ 追求生态兼容性（所有引擎原生支持）
```

### 8.2 关键监控指标

| 指标 | 告警阈值 | 含义 |
|------|---------|------|
| ChangeTable 文件数 | > 100 | 合并不及时，读取退化 |
| ChangeTable 数据量 | > BaseTable 的 20% | 需要触发 Major Optimize |
| Merge-on-Read 延迟 | > 正常查询 3 倍 | ChangeTable 堆积严重 |
| Self-Optimizing 状态 | PENDING > 1h | Optimizer 资源不足 |
