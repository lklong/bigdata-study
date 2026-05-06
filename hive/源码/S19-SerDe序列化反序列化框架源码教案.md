# [教案] SerDe 序列化反序列化框架源码深度剖析

> 🎯 教学目标：掌握 Hive SerDe 接口体系、ObjectInspector 类型系统、主要 SerDe 实现和列裁剪/谓词下推机制 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：翻译官

想象你是一个联合国翻译官。不同国家的代表说不同的语言（TextFile、ORC、Parquet、JSON……），而联合国内部只使用一种标准语言（Hive 内部对象模型）。

**SerDe（Serializer/Deserializer）** 就是这个翻译官：
- **Deserialize（反序列化）**：把各国代表的语言翻译成标准语言（磁盘数据 → Hive 内部对象）
- **Serialize（序列化）**：把标准语言翻译成目标语言（Hive 内部对象 → 磁盘数据）
- **ObjectInspector**：翻译手册（描述数据的结构和类型）

### 生产故障场景

```
现象：CREATE TABLE t ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.JsonSerDe'
      INSERT INTO t SELECT * FROM source;
      SELECT * FROM t; -- 数据全是 NULL
原因：JSON 字段名与表列名大小写不匹配（JSON 区分大小写）
排查：使用 JsonSerDe 属性 'case.insensitive'='true'
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| SerDe | Serializer + Deserializer 的合称 | 翻译官（双向翻译） |
| AbstractSerDe | SerDe 抽象基类 | 翻译官培训教材（基础能力） |
| ObjectInspector | 对象检查器（类型系统的核心） | 翻译手册（描述数据结构） |
| LazySimpleSerDe | TextFile 的默认 SerDe（延迟解析） | 中文翻译官（逗号分隔文本） |
| OrcSerDe | ORC 文件格式的 SerDe | 英文翻译官（列式存储） |
| JsonSerDe | JSON 格式的 SerDe | 法语翻译官（JSON 文本） |
| ColumnProjectionUtils | 列裁剪工具（只读取需要的列） | 节选翻译（只翻译需要的段落） |
| Writable | Hadoop 的可序列化接口 | 密封信封（磁盘上的原始数据格式） |

### 2.2 架构图/流程图

```
┌────────────────────────────────────────────────────────────────┐
│                     Hive SerDe 架构                             │
│                                                                │
│  磁盘数据                SerDe                  Hive 内部模型    │
│  ┌──────────┐      ┌──────────────┐       ┌──────────────┐    │
│  │TextFile  │─────→│LazySimple    │─────→│              │    │
│  │a,b,c     │      │SerDe         │       │  Java Object │    │
│  └──────────┘      └──────────────┘       │  (LazyStruct)│    │
│  ┌──────────┐      ┌──────────────┐       │              │    │
│  │ORC File  │─────→│OrcSerDe      │─────→│  + Object    │    │
│  │(列式)    │      │              │       │    Inspector │    │
│  └──────────┘      └──────────────┘       │              │    │
│  ┌──────────┐      ┌──────────────┐       │              │    │
│  │JSON File │─────→│JsonSerDe     │─────→│              │    │
│  │{...}     │      │              │       └──────────────┘    │
│  └──────────┘      └──────────────┘              │            │
│  ┌──────────┐      ┌──────────────┐              ▼            │
│  │Parquet   │─────→│ParquetSerDe  │       ┌──────────────┐    │
│  │(列式)    │      │              │       │ ObjectInspec │    │
│  └──────────┘      └──────────────┘       │ tor 导航     │    │
│                                            │ 数据结构     │    │
│                                            └──────────────┘    │
└────────────────────────────────────────────────────────────────┘

ObjectInspector 类型层次：
┌────────────────────────────────────────────────────┐
│              ObjectInspector                         │
│                     │                                │
│  ┌─────────────────┼──────────────────┐             │
│  │                 │                  │             │
│  ▼                 ▼                  ▼             │
│ PrimitiveOI    StructOI          ListOI/MapOI      │
│ (int,string,   (Row 结构)       (数组/映射)         │
│  date,...)                                          │
│                                                     │
│ 实现策略：                                           │
│ ├─ Standard (标准Java对象)                          │
│ ├─ Lazy (延迟解析，按需反序列化)                     │
│ ├─ LazyBinary (二进制延迟解析)                       │
│ └─ Writable (Hadoop Writable 对象)                  │
└────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|----------|------|
| `AbstractSerDe` | `serde/src/.../serde2/AbstractSerDe.java` | SerDe 抽象基类 |
| `Deserializer` | `serde/src/.../serde2/Deserializer.java` | 反序列化接口 |
| `Serializer` | `serde/src/.../serde2/Serializer.java` | 序列化接口 |
| `ObjectInspector` | `serde/src/.../serde2/objectinspector/ObjectInspector.java` | 类型检查器接口 |
| `LazySimpleSerDe` | `serde/src/.../serde2/lazy/LazySimpleSerDe.java` | TextFile 默认 SerDe |
| `JsonSerDe` | `serde/src/.../serde2/JsonSerDe.java` | JSON 格式 SerDe |
| `ColumnProjectionUtils` | `serde/src/.../serde2/ColumnProjectionUtils.java` | 列裁剪工具 |

### 3.2 关键方法逐行解读

#### 3.2.1 AbstractSerDe —— SerDe 的核心抽象

```java
// 文件: serde/src/java/org/apache/hadoop/hive/serde2/AbstractSerDe.java
// 行号: 35-127

public abstract class AbstractSerDe implements Deserializer, Serializer {

  protected String configErrors;

  /**
   * 初始化 SerDe
   * @param configuration  Hadoop 配置
   * @param tableProperties  表属性（如分隔符、列名等）
   * @param partitionProperties  分区属性
   */
  public void initialize(Configuration configuration,
      Properties tableProperties,
      Properties partitionProperties) throws SerDeException {
    // 默认合并表属性和分区属性
    initialize(configuration,
        SerDeUtils.createOverlayedProperties(tableProperties, partitionProperties));
  }

  /**
   * 反序列化：Writable（磁盘格式）→ Java Object（内存格式）
   * 返回值通常被复用！客户端如需保留需要 clone
   */
  public abstract Object deserialize(Writable blob) throws SerDeException;

  /**
   * 序列化：Java Object + ObjectInspector → Writable（磁盘格式）
   * 返回值通常被复用！客户端如需保留需要 clone
   */
  public abstract Writable serialize(Object obj, ObjectInspector objInspector)
      throws SerDeException;

  /**
   * 获取反序列化结果的 ObjectInspector
   * 用于导航反序列化后的对象结构
   */
  public abstract ObjectInspector getObjectInspector() throws SerDeException;

  /**
   * 获取序列化输出的 Writable 类型（用于初始化 SequenceFile）
   */
  public abstract Class<? extends Writable> getSerializedClass();
}
```

**SerDe 生命周期**：

```
initialize(conf, props)    → 读取配置（分隔符、列名、类型等）
        │
        ▼
getObjectInspector()       → 返回数据结构描述（StructObjectInspector）
        │
        ▼
deserialize(writable) × N → 每行调用，返回 Java 对象
        │
        ▼
serialize(obj, oi) × N    → 每行调用，返回 Writable
```

#### 3.2.2 Deserializer 接口

```java
// 文件: serde/src/java/org/apache/hadoop/hive/serde2/Deserializer.java
// 行号: 37-73

public interface Deserializer {

  // 初始化
  void initialize(Configuration conf, Properties tbl) throws SerDeException;

  // 反序列化：Writable → Object
  // 重要：返回值通常会被复用，如果需要保留需要 clone
  Object deserialize(Writable blob) throws SerDeException;

  // 获取 ObjectInspector（描述返回对象的结构）
  ObjectInspector getObjectInspector() throws SerDeException;

  // 获取序列化统计信息
  SerDeStats getSerDeStats();
}
```

#### 3.2.3 ObjectInspector —— Hive 类型系统的灵魂

```java
// ObjectInspector 是 Hive 类型系统的核心抽象
// 它允许 Hive 在不知道具体 Java 类型的情况下访问数据

public interface ObjectInspector {

  // 对象类别
  public enum Category {
    PRIMITIVE,  // 基本类型（int, string, date...）
    LIST,       // 列表类型（Array）
    MAP,        // 映射类型
    STRUCT,     // 结构体类型（Row）
    UNION       // 联合类型
  }

  // 获取类别
  Category getCategory();

  // 获取类型名称
  String getTypeName();
}

// StructObjectInspector：结构体检查器（最常用，代表一行数据）
public interface StructObjectInspector extends ObjectInspector {
  // 获取所有字段
  List<? extends StructField> getAllStructFieldRefs();

  // 按名称获取字段
  StructField getStructFieldRef(String fieldName);

  // 获取字段值
  Object getStructFieldData(Object data, StructField fieldRef);

  // 获取所有字段值
  List<Object> getStructFieldsDataAsList(Object data);
}

// PrimitiveObjectInspector：基本类型检查器
public interface PrimitiveObjectInspector extends ObjectInspector {
  PrimitiveCategory getPrimitiveCategory();  // int/string/date...
  Class<?> getPrimitiveWritableClass();      // IntWritable/Text/...
  Object getPrimitiveWritableObject(Object o); // 转为 Writable
  Object getPrimitiveJavaObject(Object o);     // 转为 Java 对象
}
```

**ObjectInspector 的精妙之处**：

同一份数据可以有不同的物理表示（LazyObject、StandardObject、WritableObject），但通过 ObjectInspector 统一导航。这是一种**桥接模式**——将数据的逻辑视图与物理存储分离。

#### 3.2.4 常见 SerDe 实现对比

| SerDe | 文件格式 | 分隔符 | 列裁剪 | 谓词下推 | 向量化 |
|-------|----------|--------|--------|----------|--------|
| LazySimpleSerDe | TextFile | 可配置（默认 `\001`） | 部分支持 | 不支持 | 通过适配器 |
| OrcSerDe | ORC | N/A（列式二进制） | 原生支持 | 原生支持 | 原生支持 |
| ParquetSerDe | Parquet | N/A（列式二进制） | 原生支持 | 原生支持 | 原生支持 |
| JsonSerDe | JSON | N/A（JSON 格式） | 不支持 | 不支持 | 通过适配器 |
| OpenCSVSerde | CSV | 逗号 | 不支持 | 不支持 | 通过适配器 |
| AvroSerDe | Avro | N/A（Schema-aware 二进制） | 支持 | 部分支持 | 通过适配器 |
| RegexSerDe | 正则匹配文本 | 正则表达式 | 不支持 | 不支持 | 不支持 |

#### 3.2.5 列裁剪在 SerDe 层的实现

```java
// 文件: serde/src/java/org/apache/hadoop/hive/serde2/ColumnProjectionUtils.java
// 核心逻辑

public final class ColumnProjectionUtils {

  // JobConf 中存储需要读取的列 ID
  public static final String READ_COLUMN_IDS_CONF_STR = "hive.io.file.readcolumn.ids";

  // 是否读取所有列
  public static final String READ_ALL_COLUMNS = "hive.io.file.read.all.columns";

  // 设置需要读取的列
  public static void appendReadColumns(Configuration conf, List<Integer> ids) {
    // 将列ID追加到配置中
    // 如 "0,2,5" 表示只读取第0、2、5列
  }

  // 获取需要读取的列
  public static List<Integer> getReadColumnIDs(Configuration conf) {
    String skips = conf.get(READ_COLUMN_IDS_CONF_STR, "");
    // 解析 "0,2,5" → [0, 2, 5]
  }

  // 是否读取所有列
  public static boolean isReadAllColumns(Configuration conf) {
    return conf.getBoolean(READ_ALL_COLUMNS, true);
  }
}
```

**列裁剪流程**：

```
SQL: SELECT name, age FROM users WHERE id > 100

优化器阶段:
  1. 分析 SELECT 和 WHERE 中引用的列: name(1), age(2), id(0)
  2. 设置 ColumnProjectionUtils:
     hive.io.file.readcolumn.ids = "0,1,2"
     hive.io.file.read.all.columns = false

读取阶段（以 ORC 为例）:
  1. ORC Reader 读取配置，只打开第 0,1,2 列的 column stripe
  2. 其他列（如 address, phone）的 stripe 完全跳过
  3. 节省大量 IO（尤其是宽表场景）

对比不同格式：
  TextFile: 每行仍需完整读取（行式存储），只是反序列化时跳过不需要的列
  ORC/Parquet: 物理层面只读取需要的列（列式存储），IO 优势巨大
```

### 3.3 调用链时序图

```
读取路径:
HDFS → InputFormat.getRecordReader()
         │
         ▼
       RecordReader.next(key, value)
         │ 返回 Writable (如 Text, OrcStruct)
         ▼
       SerDe.deserialize(writable)
         │
         ├─ LazySimpleSerDe: 创建 LazyStruct（延迟解析）
         │   └─ 只在访问具体列时才解析字段
         │
         ├─ OrcSerDe: 返回 OrcStruct（已按列解析）
         │   └─ 列裁剪：只返回投影列
         │
         └─ JsonSerDe: 解析 JSON → JavaObject
             └─ 按字段名匹配列
         │
         ▼
       ObjectInspector 导航对象结构
         │
         ├─ StructOI.getStructFieldData(row, field)
         │   → 获取某一列的值
         │
         └─ PrimitiveOI.getPrimitiveJavaObject(value)
             → 转换为 Java 原生类型


写入路径:
算子处理结果（Object + ObjectInspector）
         │
         ▼
       SerDe.serialize(obj, oi)
         │
         ├─ LazySimpleSerDe: Object → Text（分隔符连接）
         ├─ OrcSerDe: Object → OrcStruct（列式编码）
         └─ JsonSerDe: Object → Text（JSON 格式）
         │
         ▼
       OutputFormat.getRecordWriter()
         │
         ▼
       RecordWriter.write(key, writable) → HDFS
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：TextFile 表查询慢

```
现象：200列的 TextFile 表，查 2 列也要全表扫描
原因：TextFile 是行式存储，每行必须完整读取再拆分
解决：ALTER TABLE t SET FILEFORMAT ORC;
      -- ORC 列裁剪：只读取需要的列，IO 减少 99%
```

#### 场景2：SerDe 不匹配导致数据错乱

```sql
-- 问题：用 LazySimpleSerDe 读 JSON 数据
CREATE TABLE t (name STRING, age INT) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',';
-- 数据实际是 JSON: {"name":"Alice","age":30}
-- 结果：name = '{"name":"Alice"', age = NULL

-- 解决：使用正确的 SerDe
CREATE TABLE t (name STRING, age INT)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.JsonSerDe';
```

#### 场景3：LazySimpleSerDe 的延迟解析优势

```
场景：100列宽表，查询 SELECT col1 FROM t;
LazySimpleSerDe 优化：
  1. deserialize() 只创建 LazyStruct 壳，不解析任何列
  2. 当算子访问 col1 时，才解析第 1 个字段
  3. 其他 99 列完全不解析 → 节省 CPU
```

### 4.2 关键参数

| 参数 | 说明 |
|------|------|
| `serialization.format` | 序列化分隔符 |
| `field.delim` | 字段分隔符（LazySimpleSerDe） |
| `collection.delim` | 集合分隔符 |
| `mapkey.delim` | Map 键值分隔符 |
| `serialization.null.format` | NULL 值表示（默认 `\N`） |
| `hive.io.file.readcolumn.ids` | 列裁剪：需要读取的列 ID |
| `hive.io.file.read.all.columns` | 是否读取所有列 |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 概念 | Hive SerDe | Spark DataSource | Flink Format | Presto Connector |
|------|-----------|-----------------|-------------|-----------------|
| 数据读取 | Deserializer | DataSourceReader | DeserializationSchema | RecordCursor |
| 数据写入 | Serializer | DataSourceWriter | SerializationSchema | PageSink |
| 类型系统 | ObjectInspector | StructType | TypeInformation | Type |
| 列裁剪 | ColumnProjectionUtils | pruneColumns() | 配置级 | ColumnHandle |
| 谓词下推 | SearchArgument(ORC) | pushFilters() | FilterPushdown | TupleDomain |

### 5.2 面试高频题

**Q1：SerDe 在 Hive 架构中的位置和作用？**

> A: SerDe 位于 InputFormat/OutputFormat 和 Hive 算子之间，负责数据格式的桥接。InputFormat 从文件读取原始 Writable 数据，SerDe 将其反序列化为 Hive 内部对象模型（通过 ObjectInspector 导航）。这种设计实现了**存储格式与计算逻辑的解耦**——只要实现对应的 SerDe，Hive 就能读写任意格式。

**Q2：ObjectInspector 的设计目的是什么？**

> A: ObjectInspector 是 Hive 的**统一类型系统**，解决了以下问题：
> 1. 同一份数据可以有不同的物理表示（Lazy/Standard/Writable）
> 2. 算子不需要关心数据的具体 Java 类型，只通过 OI 导航
> 3. 支持延迟解析（LazyObjectInspector）——按需反序列化
> 4. 实现了逻辑类型和物理存储的完全解耦

**Q3：为什么 ORC/Parquet 的列裁剪比 TextFile 高效得多？**

> A: ORC/Parquet 是**物理列式存储**，数据按列分开存放在不同的数据块中。列裁剪时可以直接跳过不需要的列的数据块，**在 IO 层面**就减少了读取量。而 TextFile 是行式存储，每行数据是连续的，必须**全部读入内存**后再拆分字段，列裁剪只能在**CPU 层面**跳过不需要的字段的解析，IO 量不变。

**Q4：LazySimpleSerDe 中"Lazy"是什么意思？**

> A: Lazy 表示**延迟解析**。deserialize() 不会立即解析所有字段，而是只创建一个 LazyStruct 壳。只有当具体字段被访问时（通过 ObjectInspector.getStructFieldData），才会去原始字节数组中查找分隔符、解析该字段。对于宽表只查少数列的场景，这能显著减少 CPU 开销。

### 5.3 思考题

1. **如何实现一个自定义 SerDe 来读取 XML 格式的数据？需要实现哪些方法？**
2. **ORC 的 SearchArgument（谓词下推）和 SerDe 层的列裁剪有什么区别？**
3. **为什么 SerDe.deserialize() 的返回值通常被复用，客户端需要 clone？这样设计的目的是什么？**

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────┐
│            SerDe 序列化反序列化框架 · 知识晶体                    │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  核心思想：存储格式 ↔ SerDe ↔ Hive 内部对象模型                  │
│                                                                  │
│  接口体系：                                                       │
│    AbstractSerDe                                                 │
│      ├─ initialize(conf, props)   初始化                         │
│      ├─ deserialize(Writable)     磁盘→内存                     │
│      ├─ serialize(Object, OI)     内存→磁盘                     │
│      └─ getObjectInspector()      返回类型描述                   │
│                                                                  │
│  ObjectInspector 类型导航：                                       │
│    StructOI.getStructFieldData(row, field) → 获取列值            │
│    PrimitiveOI.getPrimitiveJavaObject(val) → 获取原生值          │
│                                                                  │
│  主要实现：                                                       │
│    LazySimpleSerDe (TextFile) → 延迟解析，行式                   │
│    OrcSerDe (ORC)    → 列式，列裁剪+谓词下推+向量化             │
│    ParquetSerDe (Parquet) → 列式，列裁剪+谓词下推               │
│    JsonSerDe (JSON)  → 按字段名匹配                              │
│                                                                  │
│  列裁剪：ColumnProjectionUtils                                   │
│    TextFile: 只省 CPU（仍需读全行）                               │
│    ORC/Parquet: 省 IO + 省 CPU（物理跳过列）                     │
│                                                                  │
│  最佳实践：生产用 ORC/Parquet，开发调试用 TextFile/JSON           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `serde/src/java/org/apache/hadoop/hive/serde2/AbstractSerDe.java`
   - `serde/src/java/org/apache/hadoop/hive/serde2/Deserializer.java`
   - `serde/src/java/org/apache/hadoop/hive/serde2/Serializer.java`
   - `serde/src/java/org/apache/hadoop/hive/serde2/objectinspector/ObjectInspector.java`
   - `serde/src/java/org/apache/hadoop/hive/serde2/lazy/LazySimpleSerDe.java`
   - `serde/src/java/org/apache/hadoop/hive/serde2/JsonSerDe.java`
   - `serde/src/java/org/apache/hadoop/hive/serde2/ColumnProjectionUtils.java`

2. **官方文档**
   - [Hive SerDe](https://cwiki.apache.org/confluence/display/Hive/SerDe)
   - [Hive DeveloperGuide - SerDe](https://cwiki.apache.org/confluence/display/Hive/DeveloperGuide#DeveloperGuide-HiveSerDe)
   - [ObjectInspector](https://cwiki.apache.org/confluence/display/Hive/ObjectInspector)
