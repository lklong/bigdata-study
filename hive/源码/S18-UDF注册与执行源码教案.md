# [教案] UDF 注册与执行源码深度剖析

> 🎯 教学目标：掌握 Hive UDF 注册表机制、GenericUDF/UDAF/UDTF 体系架构、UDF 生命周期和自定义开发 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：瑞士军刀的刀片注册表

想象 Hive 是一把**超级瑞士军刀**，每种刀片（UDF）都有特定功能：
- **剪刀**（`substr`）：裁剪字符串
- **开瓶器**（`unix_timestamp`）：转换时间格式  
- **锯子**（`regexp_extract`）：正则提取

`FunctionRegistry` 就是这把军刀的**刀片注册表**——记录了所有可用的刀片名称和位置。当你说 `SELECT substr(name, 1, 3)` 时，Hive 就通过注册表找到 `substr` 这把刀片（`UDFSubstr.class`），取出来用。

如果注册表里没有你要的刀片？你可以**自己打造**（自定义 UDF）并注册上去！

### 生产故障场景

```
现象：CREATE FUNCTION my_udf AS 'com.example.MyUDF' USING JAR 'hdfs:///jars/my-udf.jar';
      SELECT my_udf(col) FROM t; -- 报错 ClassNotFoundException
原因：UDF JAR 未正确上传到 HDFS，或类路径错误
排查：检查 HDFS 路径、类全限定名、JAR 内 class 文件
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| FunctionRegistry | 函数注册表（静态单例） | 瑞士军刀的刀片目录册 |
| Registry | 实际的注册表实现（system + session 两级） | 分为"出厂刀片"和"用户自装刀片" |
| GenericUDF | 通用 UDF 基类（一进一出） | 单输入单输出的工具刀片 |
| GenericUDAF | 通用聚合函数基类（多进一出） | 榨汁机（多个水果→一杯果汁） |
| GenericUDTF | 通用表生成函数基类（一进多出） | 碎纸机（一张纸→多条纸片） |
| DeferredObject | 延迟求值对象（短路优化） | 按需加载——不打开包装就不取出来 |
| ObjectInspector | 对象检查器（类型系统的核心） | 快递检查员（知道包裹里是什么类型） |
| FunctionInfo | 函数元信息（名称、类型、类引用） | 刀片的说明书 |

### 2.2 架构图/流程图

```
┌─────────────────────────────────────────────────────────────┐
│                    FunctionRegistry                          │
│                                                              │
│  ┌────────────────────────────────────┐                     │
│  │  System Registry (内置函数)        │                     │
│  │  ┌──────────┐  ┌───────────────┐  │                     │
│  │  │ UDF      │  │ GenericUDF    │  │                     │
│  │  │ substr   │  │ concat        │  │                     │
│  │  │ year     │  │ split         │  │                     │
│  │  │ sin/cos  │  │ from_json     │  │                     │
│  │  └──────────┘  └───────────────┘  │                     │
│  │  ┌──────────┐  ┌───────────────┐  │                     │
│  │  │ UDAF     │  │ UDTF         │  │                     │
│  │  │ sum/avg  │  │ explode      │  │                     │
│  │  │ count    │  │ json_tuple   │  │                     │
│  │  └──────────┘  └───────────────┘  │                     │
│  └────────────────────────────────────┘                     │
│                                                              │
│  ┌────────────────────────────────────┐                     │
│  │  Session Registry (用户自定义函数)  │                     │
│  │  CREATE TEMPORARY FUNCTION ...     │                     │
│  │  CREATE FUNCTION ... USING JAR ... │                     │
│  └────────────────────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘

UDF 类型体系：
┌────────────────────────────────────────────────────────────┐
│                  UDF 家族树                                  │
│                                                             │
│  ┌──────────┐  ┌──────────────────┐  ┌────────────────┐   │
│  │ UDF      │  │ GenericUDF       │  │ GenericUDAF    │   │
│  │ (旧API)  │  │ (推荐API)        │  │ (聚合函数)     │   │
│  │          │  │                  │  │                │   │
│  │ evaluate │  │ initialize()     │  │ getEvaluator() │   │
│  │ (Java反射│  │ evaluate()       │  │ → Evaluator:   │   │
│  │  匹配)   │  │ getDisplayString │  │   iterate()    │   │
│  │          │  │ close()          │  │   merge()      │   │
│  └──────────┘  └──────────────────┘  │   terminate()  │   │
│                                       └────────────────┘   │
│  ┌──────────────────┐                                      │
│  │ GenericUDTF      │                                      │
│  │ (表生成函数)      │                                      │
│  │                  │                                      │
│  │ initialize()     │                                      │
│  │ process()        │                                      │
│  │ close()          │                                      │
│  └──────────────────┘                                      │
└────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|----------|------|
| `FunctionRegistry` | `ql/.../exec/FunctionRegistry.java` | 静态函数注册表入口 |
| `Registry` | `ql/.../exec/Registry.java` | 实际的注册表实现 |
| `FunctionInfo` | `ql/.../exec/FunctionInfo.java` | 函数元信息 |
| `GenericUDF` | `ql/.../udf/generic/GenericUDF.java` | 通用 UDF 基类 |
| `GenericUDAFResolver2` | `ql/.../udf/generic/GenericUDAFResolver2.java` | 聚合函数解析器 |
| `GenericUDTF` | `ql/.../udf/generic/GenericUDTF.java` | 表生成函数基类 |
| `GenericUDFBridge` | `ql/.../udf/generic/GenericUDFBridge.java` | 旧 UDF API → GenericUDF 适配器 |

### 3.2 关键方法逐行解读

#### 3.2.1 FunctionRegistry —— 函数注册总入口

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/FunctionRegistry.java
// 行号: 157-220（节选）

public final class FunctionRegistry {

  // 系统级注册表（内置函数，全局共享）
  private static final Registry system = new Registry(true);

  static {
    // 字符串函数
    system.registerGenericUDF("concat", GenericUDFConcat.class);
    system.registerUDF("substr", UDFSubstr.class, false);
    system.registerUDF("substring", UDFSubstr.class, false);
    system.registerGenericUDF("lpad", GenericUDFLpad.class);
    system.registerGenericUDF("rpad", GenericUDFRpad.class);

    // 数学函数
    system.registerGenericUDF("round", GenericUDFRound.class);
    system.registerGenericUDF("floor", GenericUDFFloor.class);
    system.registerUDF("sqrt", UDFSqrt.class, false);
    system.registerUDF("rand", UDFRand.class, false);
    system.registerGenericUDF("abs", GenericUDFAbs.class);

    // 日期函数
    system.registerUDF("year", UDFYear.class, false);
    system.registerUDF("month", UDFMonth.class, false);
    system.registerGenericUDF("date_add", GenericUDFDateAdd.class);

    // 聚合函数
    system.registerGenericUDAF("sum", new GenericUDAFSum());
    system.registerGenericUDAF("count", new GenericUDAFCount());
    system.registerGenericUDAF("avg", new GenericUDAFAverage());
    system.registerGenericUDAF("min", new GenericUDAFMin());
    system.registerGenericUDAF("max", new GenericUDAFMax());

    // 表生成函数
    system.registerGenericUDTF("explode", GenericUDTFExplode.class);
    system.registerGenericUDTF("json_tuple", GenericUDTFJSONTuple.class);
    system.registerGenericUDTF("parse_url_tuple", GenericUDTFParseUrlTuple.class);

    // 运算符（也是 UDF！）
    system.registerGenericUDF("+", GenericUDFOPPlus.class);
    system.registerGenericUDF("-", GenericUDFOPMinus.class);
    system.registerGenericUDF("*", GenericUDFOPMultiply.class);
    system.registerGenericUDF("/", GenericUDFOPDivide.class);
    system.registerGenericUDF("=", GenericUDFOPEqual.class);
    system.registerGenericUDF("and", GenericUDFOPAnd.class);
    system.registerGenericUDF("or", GenericUDFOPOr.class);
  }
}
```

**关键发现**：在 Hive 中，**运算符也是 UDF**！`a + b` 实际上等价于 `GenericUDFOPPlus.evaluate(a, b)`。这种统一的设计让表达式处理非常优雅。

#### 3.2.2 GenericUDF —— 通用 UDF 的核心抽象

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/udf/generic/GenericUDF.java
// 行号: 73-108

@UDFType(deterministic = true)
public abstract class GenericUDF implements Closeable {

  // 延迟求值对象（支持短路求值）
  public static interface DeferredObject {
    void prepare(int version) throws HiveException;
    Object get() throws HiveException;  // 延迟获取值
  }

  /**
   * 1. 初始化阶段：接收参数的 ObjectInspector，返回输出的 ObjectInspector
   *    在这里做参数类型检查和返回类型推断
   */
  public abstract ObjectInspector initialize(ObjectInspector[] arguments)
      throws UDFArgumentException;

  /**
   * 2. 求值阶段：对每行数据调用，返回计算结果
   *    参数通过 DeferredObject 传入（延迟求值）
   */
  public abstract Object evaluate(DeferredObject[] arguments)
      throws HiveException;

  /**
   * 3. 显示名称（用于 EXPLAIN 输出）
   */
  public abstract String getDisplayString(String[] children);

  /**
   * 4. 关闭阶段：清理资源
   */
  @Override
  public void close() throws IOException {
    // 默认空实现
  }

  // 可选：接收 MapredContext（获取 JobConf 等运行时信息）
  public void configure(MapredContext context) {
    // 默认空实现
  }
}
```

**GenericUDF 生命周期**：

```
创建实例 → initialize(OI[]) → [configure(ctx)] → evaluate(args) × N次 → close()
   │              │                    │                 │              │
   │         检查参数类型           可选初始化        每行调用一次      清理资源
   │         推断返回类型                           返回计算结果
```

#### 3.2.3 自定义 UDF 示例 —— 开发最佳实践

```java
// 示例：自定义 mask_email UDF，将邮箱部分字符替换为 *

@Description(
  name = "mask_email",
  value = "_FUNC_(email) - Masks the email address",
  extended = "Example: mask_email('user@example.com') = 'u***@example.com'"
)
@UDFType(deterministic = true, stateful = false)
public class GenericUDFMaskEmail extends GenericUDF {

  private transient ObjectInspectorConverters.Converter converter;

  @Override
  public ObjectInspector initialize(ObjectInspector[] arguments)
      throws UDFArgumentException {
    // 1. 参数数量检查
    if (arguments.length != 1) {
      throw new UDFArgumentLengthException(
          "mask_email requires 1 argument, got " + arguments.length);
    }
    // 2. 参数类型检查
    if (arguments[0].getCategory() != ObjectInspector.Category.PRIMITIVE) {
      throw new UDFArgumentTypeException(0,
          "mask_email only takes primitive types");
    }
    // 3. 设置类型转换器
    converter = ObjectInspectorConverters.getConverter(
        arguments[0],
        PrimitiveObjectInspectorFactory.writableStringObjectInspector);
    // 4. 返回输出类型
    return PrimitiveObjectInspectorFactory.writableStringObjectInspector;
  }

  @Override
  public Object evaluate(DeferredObject[] arguments) throws HiveException {
    // 延迟获取参数值
    Object input = arguments[0].get();
    if (input == null) return null;

    String email = converter.convert(input).toString();
    // 业务逻辑：掩码邮箱
    int atIndex = email.indexOf('@');
    if (atIndex <= 1) return new Text(email);

    String masked = email.charAt(0)
        + "***"
        + email.substring(atIndex);
    return new Text(masked);
  }

  @Override
  public String getDisplayString(String[] children) {
    return "mask_email(" + children[0] + ")";
  }
}
```

### 3.3 调用链时序图

```
SQL: SELECT mask_email(email) FROM users WHERE id > 100

解析阶段 (SemanticAnalyzer)
    │
    ├─ 识别 mask_email 为函数调用
    ├─ FunctionRegistry.getFunctionInfo("mask_email")
    │   ├─ 先查 session registry（用户自定义）
    │   └─ 再查 system registry（内置）
    │
    ├─ 创建 ExprNodeGenericFuncDesc
    │   ├─ genericUDF = new GenericUDFMaskEmail()
    │   └─ children = [ExprNodeColumnDesc("email")]
    │
    └─ genericUDF.initialize(argumentOIs)
        → 检查参数类型、推断返回类型

执行阶段 (逐行模式)
    │
    ├─ ExprNodeGenericFuncEvaluator.initialize(outputOI)
    │
    └─ 对每行调用:
        ExprNodeGenericFuncEvaluator.evaluate(row)
          │
          ├─ 先 evaluate 子表达式（获取 email 列值）
          └─ genericUDF.evaluate(deferredObjects)
              → 返回掩码后的邮箱

执行阶段 (向量化模式)
    │
    ├─ VectorizationContext 查找向量化版本
    │   ├─ 找到 → 使用 VectorExpression 子类
    │   └─ 找不到 → VectorUDFAdaptor 包装
    │
    └─ 对每批1024行调用:
        vectorExpression.evaluate(batch)
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：自定义 UDF 导致向量化降级

```sql
-- 问题：使用自定义 UDF 后查询从 5s 变成 50s
EXPLAIN VECTORIZATION SELECT my_udf(col) FROM t;
-- 输出: "Not vectorized: UDF my_udf not in supported list"

-- 解决方案1：设置适配器模式
SET hive.vectorized.adaptor.usage.mode=all;

-- 解决方案2：将 UDF 实现为 VectorExpression
```

#### 场景2：UDF 内存泄露

```
现象：长时间运行的 UDF 导致 OOM
原因：UDF 在 evaluate() 中分配对象但未在 close() 中释放
解决：
  1. 实现 close() 方法释放资源
  2. 复用返回对象（不要每次 new）
  3. 使用 @UDFType(stateful=false) 标记无状态 UDF
```

### 4.2 关键参数

| 参数 | 说明 |
|------|------|
| `hive.vectorized.adaptor.usage.mode` | UDF 向量化适配器模式 |
| `hive.security.authorization.sqlstd.confwhitelist.append` | SQL 标准授权白名单 |
| `hive.added.jars.path` | 额外 JAR 路径 |

### 4.3 UDF 开发最佳实践

1. **优先使用 GenericUDF** 而非旧的 `UDF` API
2. **initialize() 中做所有类型检查**，不要在 evaluate() 中检查
3. **复用返回对象**：在类中定义 `private Text result = new Text()`，避免每次 new
4. **实现 close()**：释放外部资源（数据库连接、文件句柄等）
5. **标注 @UDFType**：`deterministic=true`（相同输入相同输出）可被优化器利用
6. **测试 NULL 输入**：evaluate() 中第一件事就是检查 NULL

---

## 五、举一反三

### 5.1 与其他系统的类比

| 概念 | Hive UDF | Spark UDF | Presto UDF | Flink UDF |
|------|----------|-----------|------------|-----------|
| 标量函数 | GenericUDF | UserDefinedFunction | ScalarFunction | ScalarFunction |
| 聚合函数 | GenericUDAF | UserDefinedAggregateFunction | AggregationFunction | AggregateFunction |
| 表函数 | GenericUDTF | — | ConnectorTableFunction | TableFunction |
| 类型系统 | ObjectInspector | DataType | Type | TypeInformation |
| 注册方式 | FunctionRegistry | spark.udf.register() | Plugin SPI | env.registerFunction() |

### 5.2 面试高频题

**Q1：GenericUDF 和旧 UDF API 有什么区别？**

> A: 旧 UDF API 使用 Java 反射匹配 `evaluate()` 方法签名，只支持基础类型。GenericUDF 通过 `ObjectInspector` 体系支持复杂类型（Array/Map/Struct）、可变参数、延迟求值（DeferredObject）和短路计算。新 API 是推荐的开发方式。

**Q2：DeferredObject 的作用是什么？**

> A: DeferredObject 支持**延迟求值**和**短路计算**。比如 `IF(condition, expr1, expr2)` 中，如果 condition 为 true，就不需要计算 expr2。通过 DeferredObject，只有调用 `get()` 时才真正计算值。

**Q3：UDAF 的四个阶段是什么？**

> A: `init()` → `iterate()`(逐行累加) → `terminatePartial()`(输出部分结果) → `merge()`(合并部分结果) → `terminate()`(输出最终结果)。Map 端执行 iterate + terminatePartial，Reduce 端执行 merge + terminate。

### 5.3 思考题

1. **为什么 Hive 中 `+`、`-`、`=` 这些运算符也是 UDF？这样设计有什么好处？**
2. **如何让自定义 UDF 支持向量化执行？需要做哪些额外工作？**
3. **UDTF 的 `forward()` 方法和普通 UDF 的 `return` 有什么区别？**

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────┐
│                UDF 注册与执行 · 知识晶体                          │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  注册表：FunctionRegistry → Registry (system + session)          │
│                                                                  │
│  UDF 三大家族：                                                   │
│    GenericUDF (标量)：一行进→一行出  如 substr, concat            │
│    GenericUDAF (聚合)：多行进→一行出  如 sum, count, avg          │
│    GenericUDTF (表生成)：一行进→多行出  如 explode, lateral view  │
│                                                                  │
│  GenericUDF 生命周期：                                            │
│    initialize(OI[]) → evaluate(DeferredObject[]) × N → close()  │
│         ↓                      ↓                         ↓       │
│    类型检查/推断            每行计算                    释放资源    │
│                                                                  │
│  运算符也是UDF：+ → GenericUDFOPPlus  = → GenericUDFOPEqual     │
│                                                                  │
│  开发要点：                                                       │
│    1. 用 GenericUDF 不用 UDF  2. initialize 中检查类型            │
│    3. 复用返回对象  4. 实现 close()  5. 处理 NULL                 │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/FunctionRegistry.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/udf/generic/GenericUDF.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/udf/generic/GenericUDAFResolver2.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/udf/generic/GenericUDTF.java`
   - `ql/src/java/org/apache/hadoop/hive/ql/udf/generic/GenericUDFBridge.java`

2. **官方文档**
   - [Hive UDF Development Guide](https://cwiki.apache.org/confluence/display/Hive/GenericUDFCaseStudy)
   - [Hive Operators and UDFs](https://cwiki.apache.org/confluence/display/Hive/LanguageManual+UDF)
