# Iceberg 源码深度解析：Schema Evolution 与列级别安全演进机制

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-26

---

## 一、Schema Evolution — Iceberg 的另一个杀手级特性

### 1.1 传统表 vs Iceberg Schema Evolution

```
传统 Hive 表:
  - ALTER TABLE ADD COLUMNS → 新列只能加到末尾
  - 重命名列 → 需要重写所有数据（或靠列位置映射，极易出错）
  - 修改类型 → 几乎不可能安全完成
  - 删除列 → 数据不变，只是不可见

Iceberg Schema Evolution:
  - 每列有唯一 ID → 按 ID 映射，不依赖列名或位置
  - 添加列 → 任意位置，旧文件返回 null
  - 删除列 → 旧文件的该列数据自动跳过
  - 重命名列 → 只改名，ID 不变，旧文件无缝兼容
  - 类型提升 → int → long，float → double，自动安全转换
  - 重排序 → 改变列顺序不影响旧数据
  - 全部是零成本操作，不重写数据！
```

### 1.2 核心设计：Column ID

```
Schema 中每列都有唯一 ID（递增分配）：
  Schema {
    1: order_id LONG
    2: customer_id LONG
    3: amount DECIMAL(10,2)
    4: status STRING
    5: created_at TIMESTAMP
  }

Parquet 文件也记录 Column ID：
  message orders {
    required int64 order_id (id=1);
    required int64 customer_id (id=2);
    required decimal amount (id=3);
    optional string status (id=4);
    optional timestamp created_at (id=5);
  }

读取时按 Column ID 映射！不管列名/位置怎么变：
  - 重命名 customer_id → buyer_id → 旧文件的 id=2 仍然映射正确
  - 删除 status 列 → 旧文件的 id=4 直接跳过
  - 新增 region 列 (id=6) → 旧文件没有 id=6 → 返回 null
```

---

## 二、UpdateSchema — API 接口

**源码位置**: `api/src/main/java/org/apache/iceberg/UpdateSchema.java`

```java
public interface UpdateSchema extends PendingUpdate<Schema> {

    // ========== 添加列 ==========
    UpdateSchema addColumn(String name, Type type);              // 顶层列
    UpdateSchema addColumn(String name, Type type, String doc);  // 带注释
    UpdateSchema addColumn(String parent, String name, Type type); // 嵌套结构

    // ========== 删除列 ==========
    UpdateSchema deleteColumn(String name);

    // ========== 重命名 ==========
    UpdateSchema renameColumn(String name, String newName);

    // ========== 类型变更 ==========
    UpdateSchema updateColumn(String name, Type.PrimitiveType newType); // 类型提升
    UpdateSchema updateColumnDoc(String name, String doc);              // 修改注释

    // ========== 列顺序 ==========
    UpdateSchema moveFirst(String name);                // 移到第一列
    UpdateSchema moveBefore(String name, String before); // 移到某列之前
    UpdateSchema moveAfter(String name, String after);   // 移到某列之后

    // ========== 必填/可选 ==========
    UpdateSchema makeColumnOptional(String name);   // required → optional（安全）
    UpdateSchema requireColumn(String name);         // optional → required（不兼容！）

    // ========== 安全控制 ==========
    UpdateSchema allowIncompatibleChanges();  // 允许不兼容变更

    // ========== 联合操作 ==========
    UpdateSchema unionByNameWith(Schema newSchema); // 按名称合并 Schema
}
```

---

## 三、安全类型提升规则

```
Iceberg 允许的安全类型提升（不需要重写数据）：

  int       → long         ✅ 安全（Parquet 自动扩展）
  float     → double       ✅ 安全
  decimal   → 更高精度     ✅ decimal(10,2) → decimal(20,2)

不允许的（需要 allowIncompatibleChanges）：

  long      → int          ❌ 精度丢失
  double    → float        ❌ 精度丢失
  string    → int          ❌ 类型不兼容
  optional  → required     ❌ 旧文件可能有 null
```

---

## 四、SchemaUpdate — 核心实现

**源码位置**: `core/src/main/java/org/apache/iceberg/SchemaUpdate.java` (29KB)

### 4.1 核心字段

```java
class SchemaUpdate implements UpdateSchema {
    private final TableOperations ops;
    private final Schema schema;                    // 当前 Schema
    private final List<Integer> deletes;            // 待删除的列 ID
    private final Map<Integer, Types.NestedField> updates; // 待更新的列
    private final Map<Integer, Integer> moves;      // 列顺序变更
    private final List<Types.NestedField> adds;     // 待添加的列
    private int lastColumnId;                       // 最后分配的列 ID
    private boolean allowIncompatible = false;
```

### 4.2 addColumn — 列 ID 分配

```java
@Override
public UpdateSchema addColumn(String parent, String name, Type type, String doc) {
    // 1. 检查列名不存在
    Preconditions.checkArgument(schema.findField(name) == null, ...);

    // 2. 分配新 ID
    int newId = assignNewColumnId();
    // lastColumnId 递增，确保全局唯一

    // 3. 如果 type 是嵌套结构，递归分配子列 ID
    Type typeWithIds = assignFreshIds(type);

    // 4. 添加到 adds 列表
    adds.add(Types.NestedField.optional(newId, name, typeWithIds, doc));

    return this;
}
```

### 4.3 deleteColumn — 标记删除（不真删数据）

```java
@Override
public UpdateSchema deleteColumn(String name) {
    Types.NestedField field = schema.findField(name);
    // 只记录要删除的列 ID
    deletes.add(field.fieldId());
    return this;
}
// 实际效果: 新的 Schema 中不包含该列
// 旧数据文件中该列的数据仍然存在，但读取时会被跳过
```

### 4.4 updateColumn — 类型安全检查

```java
@Override
public UpdateSchema updateColumn(String name, Type.PrimitiveType newType) {
    Types.NestedField field = schema.findField(name);
    Type currentType = field.type();

    // 安全性检查
    if (!allowIncompatible) {
        Preconditions.checkArgument(
            TypeUtil.isPromotionAllowed(currentType, newType),
            "Cannot change column type: %s -> %s (not a safe promotion)",
            currentType, newType);
    }

    updates.put(field.fieldId(), field.withType(newType));
    return this;
}
```

### 4.5 apply — 构建新 Schema

```java
@Override
public Schema apply() {
    // 1. 从当前 Schema 开始
    List<Types.NestedField> newColumns = Lists.newArrayList();

    for (Types.NestedField field : schema.columns()) {
        if (deletes.contains(field.fieldId())) {
            continue;  // 跳过被删除的列
        }

        if (updates.containsKey(field.fieldId())) {
            newColumns.add(updates.get(field.fieldId()));  // 应用更新
        } else {
            newColumns.add(field);
        }
    }

    // 2. 添加新列
    newColumns.addAll(adds);

    // 3. 应用列顺序变更
    applyMoves(newColumns, moves);

    // 4. 构建新 Schema（schemaId 递增）
    return new Schema(newSchemaId, newColumns);
}
```

---

## 五、Schema Evolution 在元数据中的存储

```json
// metadata.json
{
  "current-schema-id": 2,
  "schemas": [
    {
      "schema-id": 0,
      "fields": [
        {"id": 1, "name": "order_id", "type": "long", "required": true},
        {"id": 2, "name": "customer_id", "type": "long", "required": true},
        {"id": 3, "name": "amount", "type": "decimal(10,2)", "required": false}
      ]
    },
    {
      "schema-id": 1,
      "fields": [
        {"id": 1, "name": "order_id", "type": "long", "required": true},
        {"id": 2, "name": "buyer_id", "type": "long", "required": true},
        {"id": 3, "name": "amount", "type": "decimal(20,2)", "required": false},
        {"id": 4, "name": "region", "type": "string", "required": false}
      ]
    },
    {
      "schema-id": 2,
      "fields": [
        {"id": 1, "name": "order_id", "type": "long", "required": true},
        {"id": 2, "name": "buyer_id", "type": "long", "required": true},
        {"id": 3, "name": "amount", "type": "decimal(20,2)", "required": false},
        {"id": 4, "name": "region", "type": "string", "required": false},
        {"id": 5, "name": "tags", "type": "list<string>", "required": false}
      ]
    }
  ]
}
```

**关键设计**:
- `schemas` 保留所有历史版本（不删除）
- 每个 Snapshot 记录自己的 `schema-id`
- 读取时自动将旧 Schema 映射到当前 Schema

---

## 六、实战操作

### 6.1 SQL 方式

```sql
-- 添加列
ALTER TABLE catalog.db.orders ADD COLUMN region STRING;
ALTER TABLE catalog.db.orders ADD COLUMN tags ARRAY<STRING>;

-- 删除列
ALTER TABLE catalog.db.orders DROP COLUMN status;

-- 重命名
ALTER TABLE catalog.db.orders RENAME COLUMN customer_id TO buyer_id;

-- 类型提升
ALTER TABLE catalog.db.orders ALTER COLUMN amount TYPE DECIMAL(20,2);

-- 调整列顺序
ALTER TABLE catalog.db.orders ALTER COLUMN region FIRST;
ALTER TABLE catalog.db.orders ALTER COLUMN region AFTER order_id;
```

### 6.2 Java API

```java
table.updateSchema()
    .addColumn("region", Types.StringType.get())
    .renameColumn("customer_id", "buyer_id")
    .updateColumn("amount", Types.DecimalType.of(20, 2))
    .deleteColumn("status")
    .moveAfter("region", "order_id")
    .commit();
```

### 6.3 unionByNameWith — Schema 合并

```java
// 从外部系统推断 Schema 并合并（常用于 Kafka/CDC 场景）
Schema newSchema = SchemaParser.fromJson(kafkaSchemaJson);
table.updateSchema()
    .unionByNameWith(newSchema)
    .commit();
// 自动添加新列，更新类型（安全提升），保留已有列
```

---

## 七、与 Partition Evolution 的联动

```
Schema Evolution 和 Partition Evolution 独立但协同：

1. 添加列 + 添加分区:
   ALTER TABLE t ADD COLUMN region STRING;
   ALTER TABLE t ADD PARTITION FIELD region;
   → 旧数据: 无 region 列，分区值为 null
   → 新数据: 有 region 列，按 region 分区

2. 删除列 + 删除分区:
   ALTER TABLE t DROP COLUMN region;
   ALTER TABLE t DROP PARTITION FIELD region;
   → 旧分区文件仍然存在，但 region 列不可见
   → 分区字段变为 VoidTransform

两者都是零成本操作，不需要重写任何历史数据！
```

---

## 八、设计精髓总结

| 设计 | 目的 |
|------|------|
| **Column ID** | 按 ID 映射而非位置/名称，重命名/重排序零成本 |
| **schemas 列表** | 保留所有历史 Schema，任何时间点都可回溯 |
| **安全类型提升** | 默认只允许安全提升（int→long），防止精度丢失 |
| **lastColumnId** | 全局递增，删除的列 ID 不复用，确保唯一性 |
| **allowIncompatible** | 显式开关，不兼容变更需要用户确认 |
| **unionByNameWith** | 自动 Schema 合并，适配动态 Schema 源（Kafka/CDC） |
