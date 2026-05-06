# Iceberg 源码深度解析：PartitionSpec Evolution 与 Hidden Partitioning 机制

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-26

---

## 一、Hidden Partitioning — Iceberg 的杀手级特性

### 1.1 传统分区 vs Hidden Partitioning

```
传统 Hive 分区：
  CREATE TABLE orders PARTITIONED BY (dt STRING)
  - 用户必须手动管理分区列
  - 写入时必须手动计算分区值
  - 查询时必须写 WHERE dt = '2026-04-25'
  - 分区列在数据中冗余存储
  
Iceberg Hidden Partitioning：
  CREATE TABLE orders PARTITIONED BY (days(created_at))
  - 分区从源数据列自动派生（hidden）
  - 用户只需 WHERE created_at > '2026-04-25'
  - Iceberg 自动推导出分区裁剪
  - 分区值不存储在数据文件中
  - 分区策略可以随时演进（Partition Evolution）
```

### 1.2 核心概念关系

```
Schema（表结构）
  └── Column: created_at TIMESTAMP
       │
       ▼
PartitionSpec（分区规范）
  └── PartitionField
       ├── sourceId: 指向 Schema 中的列 ID
       ├── fieldId: 分区字段自身 ID（从 1000 起）
       ├── name: 分区字段名（如 "created_at_day"）
       └── transform: 转换函数（如 Days）
              │
              ▼
Transform（转换函数）
  ├── Identity   — 值不变（等同传统分区）
  ├── Year       — 提取年份
  ├── Month      — 提取年月
  ├── Day        — 提取年月日
  ├── Hour       — 提取到小时
  ├── Bucket[N]  — 哈希分桶
  ├── Truncate[W]— 截断到宽度
  └── Void       — 已废弃的分区字段标记
```

---

## 二、PartitionSpec — 分区规范

**源码位置**: `api/src/main/java/org/apache/iceberg/PartitionSpec.java`

### 2.1 核心字段

```java
// PartitionSpec.java
public class PartitionSpec implements Serializable {
    private static final int PARTITION_DATA_ID_START = 1000; // 分区字段 ID 起始值

    private final Schema schema;             // 关联的表 Schema
    private final int specId;                // 分区规范 ID（从 0 开始递增）
    private final PartitionField[] fields;   // 分区字段数组（有序）
    private final int lastAssignedFieldId;   // 最后分配的字段 ID
```

### 2.2 PartitionField

```java
// PartitionField.java
public class PartitionField implements Serializable {
    private final int sourceId;              // 源列 ID（指向 Schema 中的列）
    private final int fieldId;               // 分区字段 ID（≥ 1000）
    private final String name;               // 分区字段名
    private final Transform<?, ?> transform; // 转换函数
}
```

### 2.3 Builder — 构建分区规范

```java
// 使用示例
PartitionSpec spec = PartitionSpec.builderFor(schema)
    .identity("region")           // identity(region) → region
    .day("created_at")            // day(created_at)  → created_at_day
    .bucket("user_id", 16)        // bucket[16](user_id) → user_id_bucket
    .truncate("city", 4)          // truncate[4](city) → city_trunc
    .build();

// Builder 内部实现
public static class Builder {
    private final Schema schema;
    private final List<PartitionField> fields = Lists.newArrayList();
    private int specId = 0;

    // 字段 ID 从 PARTITION_DATA_ID_START (1000) 开始分配
    private final AtomicInteger lastAssignedFieldId =
        new AtomicInteger(PARTITION_DATA_ID_START - 1);

    public Builder identity(String sourceName) {
        return add(schema.findField(sourceName).fieldId(), sourceName, Transforms.identity());
    }

    public Builder day(String sourceName) {
        return add(schema.findField(sourceName).fieldId(), sourceName + "_day", Transforms.day());
    }

    public Builder bucket(String sourceName, int numBuckets) {
        return add(..., sourceName + "_bucket", Transforms.bucket(numBuckets));
    }

    private Builder add(int sourceId, String name, Transform<?, ?> transform) {
        fields.add(new PartitionField(sourceId, lastAssignedFieldId.incrementAndGet(), name, transform));
        return this;
    }
}
```

---

## 三、Transforms — 转换函数工厂

**源码位置**: `api/src/main/java/org/apache/iceberg/transforms/Transforms.java`

### 3.1 fromString() — 字符串解析

```java
// Transforms.java
public static Transform<?, ?> fromString(String transform) {
    // 1. 带参数的 Transform: bucket[16] / truncate[4]
    Matcher widthMatcher = Pattern.compile("(\\w+)\\[(\\d+)\\]").matcher(transform);
    if (widthMatcher.matches()) {
        String name = widthMatcher.group(1);
        int parsedWidth = Integer.parseInt(widthMatcher.group(2));
        if (name.equalsIgnoreCase("truncate")) return Truncate.get(parsedWidth);
        if (name.equalsIgnoreCase("bucket"))   return Bucket.get(parsedWidth);
    }

    // 2. 无参数的 Transform
    if (transform.equalsIgnoreCase("identity")) return Identity.get();
    if (transform.equalsIgnoreCase("year"))     return Years.get();
    if (transform.equalsIgnoreCase("month"))    return Months.get();
    if (transform.equalsIgnoreCase("day"))      return Days.get();
    if (transform.equalsIgnoreCase("hour"))     return Hours.get();
    if (transform.equalsIgnoreCase("void"))     return VoidTransform.get();

    return new UnknownTransform<>(transform); // 未知 → 保留兼容
}
```

### 3.2 Transform 类型详解

| Transform | 输入类型 | 输出类型 | 示例 | 分区路径 |
|-----------|---------|---------|------|---------|
| `identity` | 任意 | 相同 | `"US"` → `"US"` | `region=US/` |
| `year` | date/timestamp | int (年偏移) | `2026-04-25` → `56` | `created_at_year=2026/` |
| `month` | date/timestamp | int (月偏移) | `2026-04-25` → `675` | `created_at_month=2026-04/` |
| `day` | date/timestamp | int (天偏移) | `2026-04-25` → `20568` | `created_at_day=2026-04-25/` |
| `hour` | timestamp | int (小时偏移) | `2026-04-25T14:00` → `493646` | `created_at_hour=2026-04-25-14/` |
| `bucket[N]` | 任意 | int [0, N) | `123` → `7` (bucket[16]) | `user_id_bucket=7/` |
| `truncate[W]` | string/int/... | 截断值 | `"abcdefg"` → `"abcd"` | `city_trunc=abcd/` |
| `void` | 任意 | null | 任意 → `null` | 不产生分区 |

### 3.3 Hidden Partitioning 的查询优化原理

```
用户 SQL:
  SELECT * FROM orders WHERE created_at >= '2026-04-25'

Iceberg 的优化链路：
  1. Expression: greaterThanOrEqual(created_at, '2026-04-25')
  2. 分区规范: days(created_at) → created_at_day
  3. 自动推导: created_at >= '2026-04-25'
       → created_at_day >= day('2026-04-25')
       → created_at_day >= 20568
  4. Manifest 过滤: 只读取 created_at_day >= 20568 的 Manifest
  5. Data File 过滤: 跳过不满足条件的文件

关键：用户不需要知道分区字段是 days(created_at)！
Iceberg 通过 Transform 的单调性自动完成谓词下推到分区层。
```

---

## 四、Partition Evolution — 分区策略演进

### 4.1 UpdatePartitionSpec — API 接口

**源码位置**: `api/src/main/java/org/apache/iceberg/UpdatePartitionSpec.java`

```java
public interface UpdatePartitionSpec extends PendingUpdate<PartitionSpec> {
    UpdatePartitionSpec addField(String sourceName);       // 添加 identity 分区
    UpdatePartitionSpec addField(Term term);               // 添加带 transform 的分区
    UpdatePartitionSpec addField(String name, Term term);  // 添加命名分区
    UpdatePartitionSpec removeField(String name);          // 移除分区字段
    UpdatePartitionSpec removeField(Term term);            // 按 transform 移除
    UpdatePartitionSpec renameField(String name, String newName); // 重命名
    UpdatePartitionSpec addNonDefaultSpec();                // 不设为默认 spec
}
```

### 4.2 BaseUpdatePartitionSpec — 核心实现

**源码位置**: `core/src/main/java/org/apache/iceberg/BaseUpdatePartitionSpec.java`

```java
class BaseUpdatePartitionSpec implements UpdatePartitionSpec {
    private final TableOperations ops;
    private final PartitionSpec spec;            // 当前分区规范
    private final Schema schema;

    // 变更追踪
    private final List<PartitionField> adds;     // 新增的分区字段
    private final Set<Object> deletes;           // 删除的分区字段
    private final Map<String, String> renames;   // 重命名映射

    private int lastAssignedPartitionId;         // 最后分配的 ID
```

#### 核心方法 — `addField()`

```java
@Override
public UpdatePartitionSpec addField(String name, Term term) {
    // 1. 绑定 Term 到 Schema
    BoundTerm<?> boundTerm = bind(term);

    // 2. 提取 sourceId 和 transform
    Pair<Integer, String> sourceTransform = toTransform(boundTerm);
    int sourceId = sourceTransform.first();
    Transform<?, ?> transform = Transforms.fromString(sourceTransform.second());

    // 3. 冲突检测
    checkForRedundantAddedPartitions(sourceTransform);

    // 4. 复用或创建 PartitionField
    PartitionField newField = recycleOrCreatePartitionField(
        Pair.of(sourceId, transform), name);

    adds.add(newField);
    return this;
}
```

#### 关键设计 — `recycleOrCreatePartitionField()`

```java
// V2 格式下，尝试复用历史 spec 中相同的分区字段
private PartitionField recycleOrCreatePartitionField(
    Pair<Integer, Transform<?, ?>> sourceTransform, String name) {
    if (formatVersion >= 2 && base != null) {
        // 遍历所有历史 PartitionSpec
        Set<PartitionField> allHistoricalFields = Sets.newHashSet();
        for (PartitionSpec partitionSpec : base.specs()) {
            allHistoricalFields.addAll(partitionSpec.fields());
        }
        // 查找相同 sourceId + transform 的字段
        for (PartitionField field : allHistoricalFields) {
            if (field.sourceId() == sourceId && field.transform().equals(transform)) {
                if (name == null || field.name().equals(name)) {
                    return field;  // 复用！保持相同的 fieldId
                }
            }
        }
    }
    // 未找到 → 分配新 ID
    return new PartitionField(sourceId, assignFieldId(), name, transform);
}
```

**为什么要复用？** — Partition Evolution 的核心设计：
```
TableMetadata 保存所有历史 PartitionSpec：
  specs: [
    spec-0: {fields: [day(created_at)]},          // 创建时
    spec-1: {fields: [day(created_at), region]},   // 添加 region
    spec-2: {fields: [hour(created_at), region]}   // 改为 hour 粒度
  ]
  currentSpecId: 2

每个 Manifest/DataFile 记录自己的 specId：
  - 旧文件用 spec-0 → 按天分区
  - 新文件用 spec-2 → 按小时分区
  - 查询时 Iceberg 知道每个文件的分区方式，分别应用过滤

所以分区演进是零成本的！不需要重写历史数据！
```

#### `removeField()` — VoidTransform 标记

```java
@Override
public UpdatePartitionSpec removeField(String name) {
    PartitionField field = nameToField.get(name);
    deletes.add(field.fieldId());  // 标记删除
    return this;
}

// 在 apply() 时，被删除的字段会被替换为 VoidTransform：
// PartitionField(sourceId, fieldId, name, VoidTransform)
// VoidTransform 永远返回 null，不会产生分区目录
// 但字段 ID 保留，确保历史 Manifest 仍然可读
```

---

## 五、Partition Evolution 实战

### 5.1 从按天分区变为按小时分区

```sql
-- 创建表（按天分区）
CREATE TABLE orders (
    order_id BIGINT,
    created_at TIMESTAMP
) USING iceberg
PARTITIONED BY (days(created_at));

-- 写入一些数据（使用 spec-0）
INSERT INTO orders VALUES (1, '2026-04-25 10:00:00');

-- 演进为按小时分区
ALTER TABLE orders REPLACE PARTITION FIELD days(created_at) WITH hours(created_at);

-- 此后写入的数据使用新的 spec-1（按小时）
INSERT INTO orders VALUES (2, '2026-04-25 14:00:00');

-- 查询时 Iceberg 自动处理两种分区格式
SELECT * FROM orders WHERE created_at >= '2026-04-25 12:00:00';
-- 旧数据: 按天过滤 → 2026-04-25 满足条件 → 扫描
-- 新数据: 按小时过滤 → 14:00 满足条件 → 扫描
```

### 5.2 添加新分区维度

```sql
-- 添加 region 分区
ALTER TABLE orders ADD PARTITION FIELD region;

-- 此后写入的数据按 hours(created_at) + identity(region) 双重分区
-- 历史数据不受影响
```

### 5.3 Java API

```java
// 分区演进 API
table.updateSpec()
    .removeField("created_at_day")                    // 移除按天分区
    .addField(Expressions.hour("created_at"))         // 添加按小时分区
    .addField("region_bucket", Expressions.bucket("region", 8)) // 添加 bucket 分区
    .commit();
```

---

## 六、元数据存储格式

### 6.1 metadata.json 中的 partition-specs

```json
{
  "format-version": 2,
  "partition-specs": [
    {
      "spec-id": 0,
      "fields": [
        {
          "source-id": 4,
          "field-id": 1000,
          "name": "created_at_day",
          "transform": "day"
        }
      ]
    },
    {
      "spec-id": 1,
      "fields": [
        {
          "source-id": 4,
          "field-id": 1000,
          "name": "created_at_day",
          "transform": "void"
        },
        {
          "source-id": 4,
          "field-id": 1001,
          "name": "created_at_hour",
          "transform": "hour"
        },
        {
          "source-id": 5,
          "field-id": 1002,
          "name": "region",
          "transform": "identity"
        }
      ]
    }
  ],
  "default-spec-id": 1,
  "last-partition-id": 1002
}
```

**关键观察**：
- `spec-0` 的 `created_at_day` (field-id=1000) 在 `spec-1` 中变为 `void`
- `void` 表示该字段已废弃，但保留 field-id 确保历史兼容
- `spec-1` 新增了 `created_at_hour` (1001) 和 `region` (1002)

---

## 七、设计精髓总结

| 特性 | 传统分区（Hive） | Iceberg Hidden Partitioning |
|------|-----------------|----------------------------|
| 分区列 | 显式列，存储在数据中 | 隐式派生，不存储在数据中 |
| 分区策略变更 | 需要重写所有数据 | 零成本演进，不影响历史数据 |
| 查询过滤 | 必须写分区列条件 | 自动从源列推导分区过滤 |
| 多版本兼容 | 不支持 | 每个文件记录自己的 specId |
| 字段 ID 回收 | N/A | V2 格式下自动复用历史 field-id |
| 废弃标记 | 删除列 | VoidTransform 保留占位 |

```
Iceberg Partition Evolution 的三大核心设计：
  1. 每个文件绑定自己的 specId → 新旧数据共存
  2. VoidTransform 标记废弃 → 字段 ID 不复用，保持历史一致
  3. Transform 单调性 → 自动谓词下推，用户无感知
```
