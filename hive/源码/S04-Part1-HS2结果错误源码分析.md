# S04: HiveServer2 结果错误 — 源码风险点分析

> 适用版本：Hive 3.x / 4.x（基于 Hive 4.3.0-SNAPSHOT 源码，核心逻辑与 3.x 一致）
> 关联文档：[S04-Part2 排障实战手册](./S04-Part2-HS2结果不对排障实战手册.md) | [S04-Part3 Hive3.x 高危 Bug 索引](./S04-Part3-Hive3x高危结果Bug索引.md)

## 一、代码库版本

**Hive 4.3.0-SNAPSHOT**（基于当前代码库 `pom.xml` 第 24 行）

---

## 二、HS2 结果集数据流全景

```
查询执行 → Driver.getResults()
    → FetchTask/ListSinkOperator → ThriftFormatter/DefaultFetchFormatter
    → SQLOperation.decode() → RowSet (ColumnBasedSet/RowBasedSet) → ColumnBuffer
    → TRowSet (Thrift 序列化) → 网络传输
    → JDBC 客户端 RowSetFactory.create() → ColumnBasedSet (反序列化)
    → HiveQueryResultSet.next() → HiveBaseResultSet.getColumnValue()
    → evaluate() → 用户获取值
```

---

## 三、代码层面发现的致命风险点（可导致结果错误）

### 🔴 风险点 1：JDBC 客户端双重创建 RowSet（最致命）

**文件**: `HiveQueryResultSet.java` 第 406-411 行

```java
// 第一次创建（用于判断 fetchDone）
fetchedRows = RowSetFactory.create(results, protocol);  // 第406行
fetchDone = !fetchResp.isHasMoreRows() && fetchedRows.numRows() == 0;
// ...
// 第二次创建（真正使用的）
fetchedRows = RowSetFactory.create(results, protocol);  // 第411行
```

**问题**：同一个 `TRowSet` 被反序列化了两次。如果 `binaryColumns` 字段使用了流式读取路径（`TCompactProtocol` + `ByteArrayInputStream`），**第一次 `read()` 后流的位置已经改变**，第二次反序列化将读取到错误的数据或空数据。

**多线程 fetch 路径同样存在此问题**（第 470-477 行）：
```java
result.fetchedRows = RowSetFactory.create(results, protocol);  // 第1次
result.numRows = result.fetchedRows.numRows();
// ...
result.fetchedRows = RowSetFactory.create(results, protocol);  // 第2次 ← 数据可能已被消费
```

**影响**：当 `hive.server2.thrift.resultset.serialize.in.tasks=true`（启用 binaryColumns 路径）时，**结果集数据完全错误或为空**。

---

### 🔴 风险点 2：ColumnBasedSet 迭代器复用同一个 Object[] 数组

**文件**: `ColumnBasedSet.java` 第 172-197 行

```java
public Iterator<Object[]> iterator() {
    return new Iterator<Object[]>() {
        private final Object[] convey = new Object[numColumns()]; // 复用同一数组
        public Object[] next() {
            for (int i = 0; i < columns.size(); i++) {
                convey[i] = columns.get(i).get(index);
            }
            return convey;  // 每次返回的是同一个引用！
        }
    };
}
```

**问题**：如果调用方缓存了返回的数组引用（而非拷贝），**所有缓存的行都会指向同一个数组，最终都是最后一行的数据**。

**当前代码中的影响**：
- `ConvertedResultSet` 构造函数：正确处理（第 72 行创建了新的 `dstRow`）✅
- `HiveQueryResultSet.next()`：直接 `row = fetchedRowsItr.next()` 赋值，一次只用一行，通常没问题 ✅
- **但**：如果有任何第三方代码或插件对迭代器做了缓存操作，就会出问题 ⚠️

---

### 🔴 风险点 3：Boolean 类型 null 值默认为 `true`

**文件**: `ColumnBuffer.java` 第 362-365 行

```java
case BOOLEAN_TYPE:
    nulls.set(size, field == null);
    boolVars()[size] = field == null ? true : (Boolean) field;  // null → true!
    break;
```

**对比其他类型**：
- `TINYINT_TYPE` → null 默认 `0`
- `INT_TYPE` → null 默认 `0`
- `BIGINT_TYPE` → null 默认 `0`
- `DOUBLE_TYPE` → null 默认 `0`
- **BOOLEAN_TYPE** → null 默认 `true` ❌

**问题**：如果 null bitmap (`nulls`) 的任何处理环节出现偏差（如 `toBitset()`/`toBinary()` 的 bit 边界计算错误），null 的 boolean 值会被误读为 `true` 而非 `false`，**直接导致查询结果错误**。

---

### 🔴 风险点 4：Float 类型精度损失

**文件**: `ColumnBuffer.java` 第 382-388 行

```java
case FLOAT_TYPE:
    doubleVars()[size] = field == null ? 0.0 : Double.parseDouble(field.toString());
    // Float → toString() → Double.parseDouble() ← 字符串中转！
    break;
case DOUBLE_TYPE:
    doubleVars()[size] = field == null ? 0 : (Double) field;
    // Double → 直接强转 ← 正确
    break;
```

**问题**：Float 走了 `toString()` 中转，而非直接 `(double)(Float)field`。`Float.toString()` 输出的精度与 `Double.parseDouble()` 重新解析后可能不完全一致，**导致浮点精度偏差**。

**示例**：`Float 0.1f` → `toString()` = `"0.1"` → `Double.parseDouble("0.1")` = `0.1`（碰巧一致），但对某些边界值可能不一致。

---

### 🟡 风险点 5：convey 字段非线程安全

**文件**: `SQLOperation.java` 第 99 行和 460-498 行

```java
private final ArrayList<Object> convey = new ArrayList<>();  // 实例字段，非线程安全

public RowSet getNextRowSet(...) {  // 无 synchronized！
    convey.ensureCapacity(capacity);
    driver.setMaxRows(capacity);
    if (driver.getResults(convey)) {
        return decode(convey, rowSet);
    }
    convey.clear();
}
```

**问题**：如果有并发 fetch 请求到达同一个 Operation，`convey` 会出现数据竞争。

---

### 🟡 风险点 6：hasMoreRows 硬编码为 false

**文件**: `ThriftCLIService.java` 第 903 行

```java
resp.setHasMoreRows(false);   // 始终 false！
```

**问题**：客户端无法依赖此字段判断是否还有更多数据。当结果集恰好在 fetch size 边界时，可能导致提前终止 fetch 而**丢失尾部数据**。

---

### 🟡 风险点 7：BYTE → BINARY_TYPE 类型映射存疑

**文件**: `Type.java` 第 196-199 行

```java
// Double check if this is the right mapping
case BYTE: {
    return Type.BINARY_TYPE;  // 官方都说 "Double check" ！
}
```

**问题**：如果 `PrimitiveCategory.BYTE` 实际应该映射为 `TINYINT_TYPE`，那么列的类型会被错误识别，**客户端按 binary 解析 tinyint 数据 → 结果完全错误**。

---

### 🟡 风险点 8：ColumnBasedSet 二进制列反序列化依赖 columnCount

**文件**: `ColumnBasedSet.java` 第 61-88 行

```java
if (tRowSet.isSetBinaryColumns()) {
    for (int i = 0; i < tRowSet.getColumnCount(); i++) {  // 依赖 columnCount！
        TColumn tvalue = new TColumn();
        tvalue.read(protocol);
        columns.add(new ColumnBuffer(tvalue));
    }
}
```

**问题**：如果 `columnCount` 与实际序列化的列数不一致，反序列化会出现**列错位**或异常。

---

## 四、社区修复的数据结果集错误 JIRA（按版本排序）

以下是 Apache Hive 社区中**已修复或已报告**的与「查询/数据结果错误」直接相关的 JIRA，按 Fix Version 从低到高排序：

### Hive 1.x

| JIRA | 标题 | Fix Version | 关键描述 |
|------|------|-------------|---------|
| **HIVE-1631** | JDBC driver returns wrong precision, scale, or column size for some data types | 1.x | JDBC 驱动返回错误的精度、scale 或列大小 |

### Hive 2.x

| JIRA | 标题 | Fix Version | 关键描述 |
|------|------|-------------|---------|
| **HIVE-11802** | Float-point numbers are displayed with different precision | 2.x | 浮点数在 beeline/JDBC 显示精度不一致 |
| **HIVE-14530** | Union All query returns incorrect results | 2.1.0 | UNION ALL 返回错误结果，CBO 常量上拉导致 |
| **HIVE-15680** | Incorrect results when hive.optimize.index.filter=true and same ORC table referenced twice | 2.x | ORC 索引过滤 + 同表引用两次 → 结果错误 |

### Hive 3.x

| JIRA | 标题 | Fix Version | 关键描述 |
|------|------|-------------|---------|
| **HIVE-20315** | Vectorization: Fix more NULL / Wrong Results issues | 3.x | 向量化执行引擎 NULL 处理和错误结果修复 |
| **HIVE-22098** | Data loss occurs when multiple tables are joined | 3.x | 多表 JOIN 数据丢失 |
| **HIVE-22160** | ORC vectorized BETWEEN wrong results | 3.x | ORC 向量化 BETWEEN 条件返回错误结果 |
| **HIVE-22360** | MultiDelimitSerDe returns wrong results in last column | 3.x | 多分隔符 SerDe 最后一列结果错误 |
| **HIVE-24078** | Result rows not equal in MR and Tez | 3.x | MR 和 Tez 引擎返回结果行数不一致 |
| **HIVE-24421** | Wrong results with vectorized execution and complex types | 3.x | 向量化执行 + 复杂类型组合导致错误结果 |
| **HIVE-25487** | Wrong results due to incorrect transitive predicate inference | 3.x | 传递谓词推断错误导致结果错误 |
| **HIVE-25835** | Bucket version mismatch causes wrong join results | 3.x | bucket_version 不一致导致 JOIN 数据异常 |

### Hive 4.x

| JIRA | 标题 | Fix Version | 关键描述 |
|------|------|-------------|---------|
| **HIVE-26111** | FULL JOIN returns incorrect result | 4.0.0-alpha-1 | FULL JOIN 对单个 join key 产生两条记录（一条一侧为 NULL）|
| **HIVE-26209** | CBO: Wrong results with SQL query with WHERE having range conditions | 4.x | CBO 启用后 WHERE 范围条件返回错误结果 |
| **HIVE-27876** | Incorrect query results on tables with ClusterBy | 4.0.0 | 带 ClusterBy 的表查询结果不正确 |
| **HIVE-29084** | Wrong results for LATERAL VIEW queries due to incorrect WHERE filter removal | 4.x+ | LATERAL VIEW + WHERE 过滤条件被错误移除 → 结果错误 |

### 跨版本 / 通用

| JIRA | 标题 | 影响版本 | 关键描述 |
|------|------|---------|---------|
| **HIVE-5269** | Binary type handling in JDBC (referenced in code TODO) | 全版本 | Binary 类型在 JDBC 中的处理问题（代码中 TODO 引用）|
| **HIVE-11892** | Closing operator can yield more rows | 全版本 | 关闭算子时可能产生额外行（FetchTask 第 199 行注释引用）|
| **HIVE-25203** | ResultSet should not control parent Statement lifecycle | 全版本 | ResultSet 不应控制父 Statement 生命周期 |

---

## 五、根因分析总结

基于代码审查，HS2 计算结果错误最可能的**根因优先级排序**：

| 优先级 | 根因 | 置信度 | 影响范围 |
|--------|------|--------|---------|
| **#1** | JDBC 客户端双重 `RowSetFactory.create()`，二进制列模式下第二次反序列化读取脏数据 | 🔴 高 | 启用 `serialize.in.tasks=true` 的所有查询 |
| **#2** | Boolean null 默认 `true`（其他类型默认 `0`），null bitmap 边界偏差时错误暴露 | 🔴 高 | 包含 BOOLEAN 类型 NULL 值的查询 |
| **#3** | Float 类型 `toString()` 中转导致精度损失 | 🟡 中 | FLOAT 类型列 |
| **#4** | `columnCount` 与实际列数不一致导致反序列化列错位 | 🟡 中 | 二进制列模式 |
| **#5** | `BYTE → BINARY_TYPE` 映射可能错误 | 🟡 中 | TINYINT 类型列 |
| **#6** | `hasMoreRows=false` 硬编码可能导致尾部数据丢失 | 🟡 中 | 结果集恰好在 fetchSize 边界的查询 |
| **#7** | `convey` 非线程安全 + 迭代器共享数组 | 🟢 低 | 并发 fetch 场景 |

---

## 六、操作路径

> 完整的排障决策树和验证 SQL 见 [S04-Part2 排障实战手册](./S04-Part2-HS2结果不对排障实战手册.md)。以下为源码级修复路径。

### 🔴 紧急操作（立即执行）

1. **确认当前 `serialize.in.tasks` 配置**
   ```sql
   SET hive.server2.thrift.resultset.serialize.in.tasks;
   ```
   - 如果为 `true`，暂时关闭以规避双重反序列化问题：
   ```sql
   SET hive.server2.thrift.resultset.serialize.in.tasks=false;
   ```

2. **确认具体哪类查询结果错误**
   - Boolean 列是否含 NULL？
   - Float 列精度是否偏差？
   - 结果行数是否缺失？
   - 列数据是否错位？

### 🟡 短期修复（当天完成）

1. **修复 HiveQueryResultSet 双重 RowSet 创建**
   - 删除第 406 行和第 470 行的冗余 `RowSetFactory.create()` 调用
   - 只保留第 411 行和第 477 行的创建

2. **修复 ColumnBuffer Boolean null 默认值**
   ```java
   // 修改前
   boolVars()[size] = field == null ? true : (Boolean) field;
   // 修改后
   boolVars()[size] = field == null ? false : (Boolean) field;
   ```

3. **修复 Float 类型精度损失**
   ```java
   // 修改前
   doubleVars()[size] = field == null ? 0.0 : Double.parseDouble(field.toString());
   // 修改后
   doubleVars()[size] = field == null ? 0.0 : ((Number) field).doubleValue();
   ```

### 🟢 长期优化

1. 关注并回合社区 HIVE-29084、HIVE-27876 等修复
2. 对 `Type.getType(TypeInfo)` 中标记 "Double check" 的映射进行验证
3. 为 `SQLOperation.getNextRowSet()` 添加同步保护

---

## 七、验证方法

```sql
-- 验证 Boolean NULL 场景
CREATE TABLE test_bool (id INT, flag BOOLEAN);
INSERT INTO test_bool VALUES (1, true), (2, false), (3, NULL);
SELECT * FROM test_bool;
-- 检查 id=3 的 flag 是否为 NULL（而非 true）

-- 验证 Float 精度
CREATE TABLE test_float (id INT, val FLOAT);
INSERT INTO test_float VALUES (1, 0.1), (2, 3.14159);
SELECT val FROM test_float;
-- 检查值是否精确

-- 验证结果行数完整性
SELECT COUNT(*) FROM large_table;
SELECT * FROM large_table;
-- 比对行数是否一致
```
