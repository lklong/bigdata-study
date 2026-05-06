# [教案] Hive 向量化执行引擎 Vectorization 源码深度剖析

> 🎯 教学目标：掌握 Hive 向量化执行引擎的核心数据结构、判断逻辑、表达式体系和降级机制 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：逐件检查 vs 整箱扫描

想象你是一名海关检查员。传统方式是**一件一件**打开包裹检查——拆开、查看、记录、封装、下一个。这就是 Hive 传统的**逐行处理（Row-at-a-time）**模式。

现在海关升级了X光机，可以**一整箱包裹同时扫描**，一次性判断1024个包裹有没有违禁品。这就是**向量化执行（Vectorized Execution）**——一次处理一批数据（默认1024行），利用 CPU 缓存和 SIMD 指令实现数量级的性能提升。

### 生产故障场景

```
现象：同一个查询，ORC 表跑 30 秒，TextFile 表跑 5 分钟
原因：ORC 表自动启用了向量化执行，TextFile 表降级为逐行模式
排查：EXPLAIN VECTORIZATION 发现 "Vectorized execution: false"
```

**核心问题**：Hive 是如何决定一个查询能否向量化？向量化的数据结构长什么样？为什么有些 UDF 会导致整个查询降级？

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| VectorizedRowBatch | 一批行的列式存储容器，默认1024行 | 快递分拣中心的标准托盘（固定放1024个包裹） |
| ColumnVector | 单列数据的一维数组表示 | 托盘上的一个槽位通道（所有包裹的重量放一列） |
| VectorExpression | 向量化的表达式计算树 | X光机的扫描规则（一次扫描一整列数据） |
| Vectorizer | 物理计划优化器，决定能否向量化 | 海关主管，决定哪些包裹走X光机、哪些走人工检查 |
| VectorizationContext | 向量化上下文，管理列映射和类型信息 | X光机的配置面板（知道每个通道放的是什么类型的数据） |
| selectedInUse | 标记哪些行被过滤后仍然有效 | 扫描后的合格清单（只处理没被过滤掉的包裹） |
| isRepeating | 标记整列数据是否为同一个值 | 整箱都是同一种货物，只需检查一次 |
| noNulls | 标记整列是否无 NULL 值 | 整箱没有空位，不需要逐个检查是否为空 |

### 2.2 架构图/流程图

```
┌─────────────────────────────────────────────────────────────┐
│                    SQL Query                                 │
│            SELECT a, SUM(b) FROM t WHERE c > 10              │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  逻辑计划 → 物理计划                                          │
│  TableScan → Filter → Select → GroupBy → FileSink            │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼  Vectorizer (PhysicalPlanResolver)
┌──────────────────────────────────────────────────────────────┐
│  向量化判断与转换                                              │
│  ┌────────────────┐  ┌──────────────┐  ┌────────────────┐   │
│  │ 数据类型检查    │→│ 算子支持检查  │→│ 表达式支持检查  │   │
│  │ supportedData  │  │ OperatorType │  │ UDF白名单      │   │
│  │ TypesPattern   │  │ 逐一验证     │  │ GenericUDF匹配 │   │
│  └────────────────┘  └──────────────┘  └────────────────┘   │
└──────────────────────┬──────────────────────────────────────┘
                       │ 全部通过
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  向量化算子树                                                 │
│  VectorMapOperator → VectorFilterOperator                    │
│  → VectorSelectOperator → VectorGroupByOperator              │
│  → VectorFileSinkOperator                                    │
│                                                              │
│  数据流: VectorizedRowBatch (1024行/批)                       │
│  ┌──────────────────────────────────────┐                    │
│  │  cols[0]: LongColumnVector   (列a)   │                    │
│  │  cols[1]: DoubleColumnVector (列b)   │                    │
│  │  cols[2]: LongColumnVector   (列c)   │                    │
│  │  size: 1024                          │                    │
│  │  selected: [0,1,3,5,...] (过滤后)     │                    │
│  │  selectedInUse: true                  │                    │
│  └──────────────────────────────────────┘                    │
└──────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|----------|------|
| `Vectorizer` | `ql/.../optimizer/physical/Vectorizer.java` | 物理计划阶段判断并转换算子为向量化版本 |
| `VectorizedRowBatch` | `storage-api/.../exec/vector/VectorizedRowBatch.java` | 一批行的列式存储容器 |
| `ColumnVector` | `storage-api/.../exec/vector/ColumnVector.java` | 单列数据的抽象基类 |
| `LongColumnVector` | `storage-api/.../exec/vector/LongColumnVector.java` | long 类型列（含 int/bigint/boolean/date） |
| `VectorExpression` | `ql/.../exec/vector/expressions/VectorExpression.java` | 向量化表达式基类 |
| `VectorFilterOperator` | `ql/.../exec/vector/VectorFilterOperator.java` | 向量化 Filter 算子 |
| `VectorSelectOperator` | `ql/.../exec/vector/VectorSelectOperator.java` | 向量化 Select 算子 |
| `VectorGroupByOperator` | `ql/.../exec/vector/VectorGroupByOperator.java` | 向量化 GroupBy 算子 |
| `VectorizationContext` | `ql/.../exec/vector/VectorizationContext.java` | 管理列名→列号映射、创建 VectorExpression |

### 3.2 关键方法逐行解读

#### 3.2.1 VectorizedRowBatch —— 一批数据的列式容器

```java
// 文件: storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizedRowBatch.java
// 行号: 34-101

public class VectorizedRowBatch implements Writable {
  public int numCols;           // 列数
  public ColumnVector[] cols;   // 每列一个 ColumnVector
  public int size;              // 当前批次有效行数（过滤后剩余的）
  public int[] selected;        // 选中行的位置索引数组
  public int[] projectedColumns;// 投影列索引
  public int projectionSize;    // 投影列数

  // 核心标志：是否启用了行选择
  // false = 所有行都有效；true = 只有 selected[] 中的行有效
  public boolean selectedInUse;

  // 是否已到达输入末尾
  public boolean endOfFile;

  // 精心选择的默认大小：1024行，刚好适配 CPU L1 Cache
  public static final int DEFAULT_SIZE = 1024;

  public VectorizedRowBatch(int numCols, int size) {
    this.numCols = numCols;
    this.size = size;
    selected = new int[size];
    selectedInUse = false;
    this.cols = new ColumnVector[numCols];
    projectedColumns = new int[numCols];

    // 初始所有列都参与投影，顺序一致
    projectionSize = numCols;
    for (int i = 0; i < numCols; i++) {
      projectedColumns[i] = i;
    }
  }
}
```

**为什么是 1024 行？**
- CPU L1 Data Cache 通常是 32KB~64KB
- 1024 个 long (8字节) = 8KB，3-4 列刚好填满 L1 Cache
- 行数太少→函数调用开销大；行数太多→数据溢出 Cache 反而变慢

#### 3.2.2 ColumnVector —— 列式数据的核心抽象

```java
// 文件: storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/ColumnVector.java
// 行号: 33-89

public abstract class ColumnVector {

  // 列向量类型枚举
  public static enum Type {
    NONE, LONG, DOUBLE, BYTES, DECIMAL, DECIMAL_64,
    TIMESTAMP, INTERVAL_DAY_TIME,
    STRUCT, LIST, MAP, UNION, VOID
  }

  public final Type type;

  // NULL 标记数组：isNull[i] = true 表示第 i 行为 NULL
  public boolean[] isNull;

  // 优化标志1：整列无 NULL → 跳过所有 NULL 检查
  public boolean noNulls;

  // 优化标志2：整列同一个值 → 只需要看 vector[0]
  public boolean isRepeating;

  public ColumnVector(Type type, int len) {
    this.type = type;
    isNull = new boolean[len];
    noNulls = true;          // 默认无 NULL
    isRepeating = false;     // 默认非重复
  }
}
```

**三大优化标志的威力**：

| 标志组合 | 处理逻辑 | 性能影响 |
|----------|----------|----------|
| `noNulls=true, isRepeating=true` | 只看 `vector[0]`，O(1) | 最快 |
| `noNulls=true, isRepeating=false` | 遍历数组，无需检查 NULL | 快 |
| `noNulls=false, isRepeating=false` | 遍历数组 + 检查 `isNull[i]` | 正常 |
| `noNulls=false, isRepeating=true` | 检查 `isNull[0]`，全列同值或全 NULL | 快 |

#### 3.2.3 LongColumnVector —— 整数列的具体实现

```java
// 文件: storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/LongColumnVector.java
// 行号: 33-53

public class LongColumnVector extends ColumnVector {
  // 核心：原始 long 数组，公开以获得最高性能
  public long[] vector;

  public LongColumnVector(int len) {
    super(Type.LONG, len);
    vector = new long[len];     // 直接分配连续内存
  }
}
```

**为什么字段是 `public`？**

这是 Hive 向量化设计的一个大胆决策——**性能优先于封装**。在内层循环中，每次 getter 调用都有开销。通过 public 直接访问数组，JIT 编译器可以更好地优化循环，甚至可能利用 SIMD 指令。

**类型映射关系**：

| Hive 类型 | ColumnVector 子类 | Java 存储类型 |
|-----------|-------------------|---------------|
| tinyint/smallint/int/bigint | LongColumnVector | long[] |
| boolean | LongColumnVector | long[] (0/1) |
| date | LongColumnVector | long[] (epoch days) |
| float/double | DoubleColumnVector | double[] |
| string/varchar/char/binary | BytesColumnVector | byte[][] |
| decimal | DecimalColumnVector | HiveDecimalWritable[] |
| decimal(精度≤18) | Decimal64ColumnVector | long[] (DECIMAL_64) |
| timestamp | TimestampColumnVector | long[] + int[] (秒+纳秒) |
| array | ListColumnVector | child ColumnVector + offsets |
| map | MapColumnVector | keys + values ColumnVector |
| struct | StructColumnVector | ColumnVector[] fields |

#### 3.2.4 Vectorizer —— 向量化的"总指挥"

Vectorizer 是一个 `PhysicalPlanResolver`，在物理计划阶段对算子树进行向量化转换。

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java
// 行号: 240-277

public class Vectorizer implements PhysicalPlanResolver {

  // 支持向量化的数据类型正则模式
  private static final Pattern supportedDataTypesPattern;
  static {
    StringBuilder patternBuilder = new StringBuilder();
    patternBuilder.append("int");
    patternBuilder.append("|smallint");
    patternBuilder.append("|tinyint");
    patternBuilder.append("|bigint");
    patternBuilder.append("|integer");
    patternBuilder.append("|long");
    patternBuilder.append("|short");
    patternBuilder.append("|timestamp");
    patternBuilder.append("|boolean");
    patternBuilder.append("|binary");
    patternBuilder.append("|string");
    patternBuilder.append("|byte");
    patternBuilder.append("|float");
    patternBuilder.append("|double");
    patternBuilder.append("|date");
    patternBuilder.append("|void");
    patternBuilder.append("|decimal.*");
    patternBuilder.append("|char.*");
    patternBuilder.append("|varchar.*");
    supportedDataTypesPattern = Pattern.compile(patternBuilder.toString());
  }
}
```

#### 3.2.5 VectorizationDispatcher —— 根据任务类型分发向量化

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java
// 行号: 931-1005

class VectorizationDispatcher implements Dispatcher {
  @Override
  public Object dispatch(Node nd, Stack<Node> stack, Object... nodeOutputs)
      throws SemanticException {
    Task<? extends Serializable> currTask = (Task<? extends Serializable>) nd;

    if (currTask instanceof MapRedTask) {
      // MapReduce: 只向量化 Map 端，不向量化 Reduce 端
      MapredWork mapredWork = ((MapRedTask) currTask).getWork();
      convertMapWork(mapredWork.getMapWork(), false);
      // We do not vectorize MR Reduce.

    } else if (currTask instanceof TezTask) {
      // Tez: Map 和 Reduce 都可以向量化
      TezWork work = ((TezTask) currTask).getWork();
      for (BaseWork baseWork: work.getAllWork()) {
        if (baseWork instanceof MapWork) {
          convertMapWork((MapWork) baseWork, true);
        } else if (baseWork instanceof ReduceWork) {
          if (isReduceVectorizationEnabled) {
            convertReduceWork((ReduceWork) baseWork);
          }
        }
      }

    } else if (currTask instanceof SparkTask) {
      // Spark: 与 Tez 类似
      SparkWork sparkWork = (SparkWork) currTask.getWork();
      for (BaseWork baseWork : sparkWork.getAllWork()) {
        if (baseWork instanceof MapWork) {
          convertMapWork((MapWork) baseWork, true);
        } else if (baseWork instanceof ReduceWork) {
          if (isReduceVectorizationEnabled) {
            convertReduceWork((ReduceWork) baseWork);
          }
        }
      }
    }
    return null;
  }
}
```

**关键发现**：MR 模式下 Reduce 端不支持向量化！这是因为 MR Reduce 的 shuffle 机制不兼容向量化的批量传输。只有 Tez/Spark 才能在 Reduce 端向量化。

#### 3.2.6 validateAndVectorizeOperator —— 逐算子验证与转换

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java
// 行号: 4896-4967（节选）

public Operator<? extends OperatorDesc> validateAndVectorizeOperator(
    Operator<? extends OperatorDesc> op,
    VectorizationContext vContext, boolean isReduce,
    boolean isTezOrSpark,
    VectorTaskColumnInfo vectorTaskColumnInfo)
        throws HiveException, VectorizerCannotVectorizeException {

  Operator<? extends OperatorDesc> vectorOp = null;
  currentOperator = op;
  boolean isNative;

  try {
    switch (op.getType()) {
      case MAPJOIN:
        // 验证 MapJoin 是否可以向量化
        if (op instanceof MapJoinOperator) {
          if (!validateMapJoinOperator((MapJoinOperator) op)) {
            throw new VectorizerCannotVectorizeException();
          }
        }
        // ... 创建向量化 MapJoin 算子
        break;

      case FILTER:
        // Filter 算子 → VectorFilterOperator
        break;

      case SELECT:
        // Select 算子 → VectorSelectOperator
        break;

      case GROUPBY:
        // GroupBy 算子 → VectorGroupByOperator
        break;

      // ... 其他算子类型
    }
  } catch (VectorizerCannotVectorizeException e) {
    // 该算子不能向量化，整个子树降级
    throw e;
  }
  return vectorOp;
}
```

#### 3.2.7 支持的 UDF 白名单

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java
// 行号: 385-439（节选）

public Vectorizer() {
  // 算术运算
  supportedGenericUDFs.add(GenericUDFOPPlus.class);
  supportedGenericUDFs.add(GenericUDFOPMinus.class);
  supportedGenericUDFs.add(GenericUDFOPMultiply.class);
  supportedGenericUDFs.add(GenericUDFOPDivide.class);
  supportedGenericUDFs.add(GenericUDFOPMod.class);

  // 比较运算
  supportedGenericUDFs.add(GenericUDFOPEqualOrLessThan.class);
  supportedGenericUDFs.add(GenericUDFOPGreaterThan.class);
  supportedGenericUDFs.add(GenericUDFOPEqual.class);
  supportedGenericUDFs.add(GenericUDFOPNotEqual.class);
  supportedGenericUDFs.add(GenericUDFOPNotNull.class);
  supportedGenericUDFs.add(GenericUDFOPNull.class);

  // 逻辑运算
  supportedGenericUDFs.add(GenericUDFOPOr.class);
  supportedGenericUDFs.add(GenericUDFOPAnd.class);
  supportedGenericUDFs.add(GenericUDFOPNot.class);

  // 字符串函数
  supportedGenericUDFs.add(GenericUDFLength.class);
  supportedGenericUDFs.add(UDFLike.class);
  supportedGenericUDFs.add(UDFSubstr.class);
  supportedGenericUDFs.add(GenericUDFLTrim.class);
  supportedGenericUDFs.add(GenericUDFRTrim.class);

  // 日期函数
  supportedGenericUDFs.add(UDFYear.class);
  supportedGenericUDFs.add(UDFMonth.class);
  supportedGenericUDFs.add(GenericUDFDateAdd.class);
  supportedGenericUDFs.add(GenericUDFDateDiff.class);

  // 类型转换
  supportedGenericUDFs.add(UDFToBoolean.class);
  supportedGenericUDFs.add(UDFToInteger.class);
  supportedGenericUDFs.add(UDFToLong.class);
  supportedGenericUDFs.add(UDFToDouble.class);
  supportedGenericUDFs.add(UDFToString.class);
  // ... 更多 UDF
}
```

#### 3.2.8 VectorFilterOperator —— 向量化 Filter 的工作过程

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorFilterOperator.java
// 行号: 39-157

public class VectorFilterOperator extends FilterOperator
    implements VectorizationOperator {

  private VectorExpression predicateExpression = null;
  private transient int[] temporarySelected;

  // filterMode: 1=恒true, -1=恒false, 0=需要计算
  transient private int filterMode = 0;

  @Override
  protected void initializeOp(Configuration hconf) throws HiveException {
    super.initializeOp(hconf);
    VectorExpression.doTransientInit(predicateExpression);
    predicateExpression.init(hconf);

    // 常量表达式优化：如果过滤条件恒为 true 或 false
    if (predicateExpression instanceof ConstantVectorExpression) {
      ConstantVectorExpression cve = (ConstantVectorExpression) this.predicateExpression;
      if (cve.getLongValue() == 1) {
        filterMode = 1;    // 恒 true，全部通过
      } else {
        filterMode = -1;   // 恒 false，全部过滤
      }
    }
    temporarySelected = new int[VectorizedRowBatch.DEFAULT_SIZE];
  }

  @Override
  public void process(Object row, int tag) throws HiveException {
    VectorizedRowBatch vrg = (VectorizedRowBatch) row;

    // 备份 selected 数组（因为表达式会修改它）
    System.arraycopy(vrg.selected, 0, temporarySelected, 0, vrg.size);
    int[] selectedBackup = vrg.selected;
    vrg.selected = temporarySelected;
    int sizeBackup = vrg.size;
    boolean selectedInUseBackup = vrg.selectedInUse;

    // 根据 filterMode 评估谓词
    switch (filterMode) {
      case 0:
        // 需要计算：对整个 batch 求值
        predicateExpression.evaluate(vrg);
        break;
      case -1:
        // 恒 false：直接清空
        vrg.size = 0;
        break;
      case 1:
      default:
        // 恒 true：什么都不做
    }

    // 只有还有剩余行才向下游转发
    if (vrg.size > 0) {
      forward(vrg, null, true);
    }

    // 恢复 selected 数组（批次会被复用）
    vrg.selected = selectedBackup;
    vrg.size = sizeBackup;
    vrg.selectedInUse = selectedInUseBackup;
  }
}
```

**关键设计**：Filter 算子通过修改 `VectorizedRowBatch.selected` 数组和 `size` 来表示过滤结果，而不是创建新的批次。这避免了数据复制，是向量化高效的关键。

#### 3.2.9 VectorSelectOperator —— 向量化 Select 的工作过程

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorSelectOperator.java
// 行号: 134-163

@Override
public void process(Object row, int tag) throws HiveException {
  // SELECT * 无需计算，直接转发
  if (conf.isSelStarNoCompute()) {
    forward(row, inputObjInspectors[tag], true);
    return;
  }

  VectorizedRowBatch vrg = (VectorizedRowBatch) row;

  // 依次对每个表达式求值（结果写入 scratch 列）
  for (int i = 0; i < vExpressions.length; i++) {
    try {
      vExpressions[i].evaluate(vrg);
    } catch (RuntimeException e) {
      throw new HiveException("Error evaluating "
          + conf.getColList().get(i).getExprString(), e);
    }
  }

  // 修改投影列：只输出 SELECT 指定的列
  int[] originalProjections = vrg.projectedColumns;
  int originalProjectionSize = vrg.projectionSize;
  vrg.projectionSize = projectedOutputColumns.length;
  vrg.projectedColumns = this.projectedOutputColumns;

  forward(vrg, outputObjInspector, true);

  // 恢复投影列（批次会被复用）
  vrg.projectionSize = originalProjectionSize;
  vrg.projectedColumns = originalProjections;
}
```

#### 3.2.10 VectorExpression —— 向量化表达式的基类

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/vector/expressions/VectorExpression.java
// 行号: 63-274

public abstract class VectorExpression implements Serializable {

  // 子表达式（需要计算的参数）
  protected VectorExpression[] childExpressions;

  // 输入参数类型信息
  protected TypeInfo[] inputTypeInfos;
  protected DataTypePhysicalVariation[] inputDataTypePhysicalVariations;

  // 输出列号和类型
  protected final int outputColumnNum;
  protected TypeInfo outputTypeInfo;

  /**
   * 核心方法：对整个 batch 进行向量化求值
   * 每个子类必须实现此方法
   */
  public abstract void evaluate(VectorizedRowBatch batch) throws HiveException;

  /**
   * 先评估所有子表达式
   */
  final protected void evaluateChildren(VectorizedRowBatch vrg) throws HiveException {
    if (childExpressions != null) {
      for (VectorExpression ve : childExpressions) {
        ve.evaluate(vrg);
      }
    }
  }
}
```

### 3.3 调用链时序图

```
用户提交查询
    │
    ▼
Driver.compile()
    │
    ▼
PhysicalOptimizer
    │
    ▼
Vectorizer.resolve()
    │
    ├─→ TaskGraphWalker 遍历所有 Task
    │       │
    │       ▼
    │   VectorizationDispatcher.dispatch()
    │       │
    │       ├─ MapRedTask → convertMapWork(isTezOrSpark=false)
    │       │                  (MR Reduce 不向量化)
    │       │
    │       ├─ TezTask → 遍历所有 BaseWork
    │       │     ├─ MapWork → convertMapWork(isTezOrSpark=true)
    │       │     └─ ReduceWork → convertReduceWork()
    │       │
    │       └─ SparkTask → (类似 Tez)
    │
    ▼
validateAndVectorizeMapWork()
    │
    ├─ 1. 检查输入格式是否支持向量化
    │     (ORC/Parquet → VectorizedInputFormat)
    │
    ├─ 2. 收集列信息 (allColumnNames, allTypeInfos)
    │
    ├─ 3. 检查所有数据类型是否支持
    │     (supportedDataTypesPattern 正则匹配)
    │
    └─ 4. validateAndVectorizeOperatorTree()
          │
          ├─ 创建 VectorizationContext
          │
          └─ 遍历算子树，逐个验证并转换:
              │
              ├─ validateAndVectorizeOperator(Filter)
              │   → 验证谓词表达式
              │   → 创建 VectorFilterOperator
              │
              ├─ validateAndVectorizeOperator(Select)
              │   → 验证投影表达式
              │   → 创建 VectorSelectOperator
              │
              ├─ validateAndVectorizeOperator(GroupBy)
              │   → 验证聚合 UDF
              │   → 创建 VectorGroupByOperator
              │
              └─ 任一算子验证失败
                  → VectorizerCannotVectorizeException
                  → 整个子树回退到逐行模式
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：查询性能突然下降 10 倍

```
现象：从 ORC 表查询耗时从 30s 变成 300s
排查：
  EXPLAIN VECTORIZATION SELECT ...;
  -- 发现: "Vectorized execution: false"
  -- 原因: "Not vectorized: UDF org.example.MyCustomUDF not in supported list"
```

#### 场景2：同样的 SQL 在不同表上性能差异巨大

```
现象：ORC 表 10s，TextFile 表 120s
原因：
  - ORC 表: 原生向量化读取（VectorizedInputFormat）
  - TextFile 表: 需要先行式读取再转向量化（DeserializeRead）
  - 某些 TextFile 列类型不支持向量化 → 完全降级
```

#### 场景3：DECIMAL 精度导致向量化降级

```sql
-- 这个查询可能不走向量化
SELECT SUM(amount) FROM orders WHERE amount > 100.00;
-- 如果 amount 是 DECIMAL(38,18)，某些表达式可能不支持
-- 而 DECIMAL(18,2) 可以走 Decimal64 快速路径
```

### 4.2 排障步骤

**Step 1：确认向量化是否启用**

```sql
SET hive.vectorized.execution.enabled;
-- 应该为 true（Hive 2.0+ 默认开启）

SET hive.vectorized.execution.reduce.enabled;
-- Reduce 端向量化（Tez/Spark 可用）
```

**Step 2：用 EXPLAIN VECTORIZATION 诊断**

```sql
EXPLAIN VECTORIZATION DETAIL
SELECT department, SUM(salary) FROM employees
WHERE hire_date > '2020-01-01'
GROUP BY department;
```

关键输出字段：
- `Vectorized execution: true/false`
- `notVectorizedReason`: 不能向量化的原因
- `nativeVectorized`: 是否为原生向量化（vs 适配器模式）

**Step 3：查看具体降级原因**

```sql
-- 常见降级原因：
-- "Data type void not supported"
-- "UDF xxx is not supported"
-- "GROUPBY operator: UDAF xxx does not have a vectorized version"
-- "Vectorizing map work only when input format is org.apache.hadoop.hive.ql.io.orc.OrcInputFormat"
```

**Step 4：针对性修复**

```sql
-- 方案1：使用 ORC 格式
ALTER TABLE t SET FILEFORMAT ORC;

-- 方案2：替换不支持的 UDF
-- 将自定义 UDF 替换为内置函数

-- 方案3：启用 VectorUDFAdaptor（性能稍差但可用）
SET hive.vectorized.adaptor.usage.mode=all;
```

### 4.3 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.vectorized.execution.enabled` | true | 总开关 |
| `hive.vectorized.execution.reduce.enabled` | true | Reduce 端向量化 |
| `hive.vectorized.execution.reduce.groupby.enabled` | true | GroupBy 向量化 |
| `hive.vectorized.execution.mapjoin.native.enabled` | true | 原生 MapJoin 向量化 |
| `hive.vectorized.adaptor.usage.mode` | chosen | UDF 适配器模式（none/chosen/all） |
| `hive.vectorized.input.format.supports.enabled` | decimal_64 | 输入格式支持级别 |
| `hive.vectorized.execution.ptf.enabled` | true | PTF 窗口函数向量化 |
| `hive.vectorized.row.identifier.enabled` | true | ROW__ID 向量化 |
| `hive.vectorized.use.row.serde.deserialize` | true | 行式 SerDe 反序列化支持 |
| `hive.vectorized.use.vector.serde.deserialize` | true | 向量化 SerDe 反序列化 |
| `hive.vectorized.use.checked.expressions` | true | 溢出检查表达式 |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 概念 | Hive Vectorization | Spark Tungsten | ClickHouse | DuckDB |
|------|-------------------|----------------|------------|--------|
| 批量处理单位 | VectorizedRowBatch(1024) | UnsafeRow batch | Column Block(65536) | DataChunk(2048) |
| 列式存储 | ColumnVector | ColumnarBatch | Column | Vector |
| NULL 处理 | boolean[] isNull + noNulls | Bitmask | Bitmask | Validity mask |
| 重复值优化 | isRepeating | 无 | 常量列 | Constant vector |
| 表达式求值 | VectorExpression.evaluate(batch) | Whole-stage codegen | 编译期特化 | 向量化原语 |
| 不支持时降级 | 回退到逐行模式 | 回退到 Volcano 模式 | 不降级（都支持） | 不降级 |

**核心差异**：
- Hive 采用**解释执行**的向量化（VectorExpression 树遍历），每个表达式是一个虚方法调用
- Spark Tungsten 采用**代码生成**（Whole-stage CodeGen），编译成 Java 字节码
- ClickHouse 采用**编译期模板特化**，C++ 模板实例化
- Hive 的向量化是**渐进式**的——不支持就降级；其他系统通常是全有或全无

### 5.2 面试高频题

**Q1：Hive 向量化的核心原理是什么？为什么能提升性能？**

> A: 核心是将逐行处理（Row-at-a-time）改为批量列式处理（Batch-at-a-time）。性能提升来自三方面：
> 1. **CPU Cache 友好**：列式数据在内存中连续存储，一次加载可被 Cache 行命中多个元素
> 2. **减少虚方法调用**：一次 evaluate() 处理 1024 行，而非 1024 次 process()
> 3. **优化分支预测**：noNulls、isRepeating 标志消除了内层循环中的条件判断
> 4. **潜在 SIMD 利用**：紧凑数组循环可被 JVM auto-vectorize 为 SIMD 指令

**Q2：哪些情况会导致向量化降级？**

> A: 主要有以下情况：
> 1. 使用了不在 supportedGenericUDFs 白名单中的自定义 UDF
> 2. 输入格式不支持（如某些自定义 InputFormat）
> 3. 数据类型不在 supportedDataTypesPattern 中
> 4. MR 引擎的 Reduce 端（只有 Tez/Spark 支持）
> 5. 某些复杂类型的聚合操作
> 6. 使用了不支持向量化的 SerDe

**Q3：VectorizedRowBatch 默认 1024 行，这个数字怎么来的？**

> A: 1024 是经过性能测试选择的值，核心考虑是 CPU L1 Cache。L1 Data Cache 通常 32-64KB，1024 个 long(8B) = 8KB，3-4 个列刚好填满 L1 Cache。太小会增加函数调用开销（摊薄不够），太大会导致 Cache 溢出（数据要从 L2/L3 Cache 甚至内存加载）。

**Q4：noNulls 和 isRepeating 标志如何优化性能？**

> A: 这两个标志通过**消除内层循环中的条件分支**来优化性能：
> - `noNulls=true` 时，循环体无需检查 `isNull[i]`，可以直接处理数据
> - `isRepeating=true` 时，只需处理 `vector[0]`，O(1) 完成
> - 组合使用时可以将 4 种分支路径简化为 1 种，JIT 编译器可以更好地优化

**Q5：hive.vectorized.adaptor.usage.mode 的三种模式有什么区别？**

> A:
> - `none`：只允许原生向量化 UDF，不在白名单的 UDF 直接导致降级
> - `chosen`（默认）：白名单中的走原生向量化，其他在通过适配器包装后尝试向量化
> - `all`：所有 UDF 都尝试通过 VectorUDFAdaptor 包装为向量化版本（性能不如原生但至少能走向量化流程）

### 5.3 思考题

1. **为什么 Hive 选择了 VectorExpression 解释执行而非代码生成（Code Generation）？** 
   提示：考虑开发复杂度、编译延迟、动态查询适应性

2. **如果一个列 100% 是 NULL，isRepeating 和 noNulls 分别是什么值？处理逻辑是怎样的？**
   提示：isRepeating=true, noNulls=false, isNull[0]=true

3. **假设你要给 Hive 新增一个向量化 UDF（比如 `base64_encode`），需要修改哪些类？**
   提示：VectorExpression 子类 + Vectorizer 白名单 + VectorizationContext 注册

---

## 六、知识晶体（一页纸总结）

```
┌──────────────────────────────────────────────────────────────────┐
│              Hive 向量化执行引擎 · 知识晶体                       │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  核心思想：Row-at-a-time → Batch-at-a-time (1024行/批)           │
│                                                                  │
│  数据结构三层：                                                   │
│    VectorizedRowBatch                                            │
│      └─ ColumnVector[]                                           │
│           ├─ LongColumnVector  (int/bigint/boolean/date)         │
│           ├─ DoubleColumnVector (float/double)                   │
│           ├─ BytesColumnVector  (string/varchar/binary)          │
│           ├─ DecimalColumnVector (decimal)                       │
│           └─ TimestampColumnVector (timestamp)                   │
│                                                                  │
│  三大优化标志：noNulls / isRepeating / selectedInUse             │
│                                                                  │
│  向量化判断链路：                                                 │
│    Vectorizer → VectorizationDispatcher                          │
│    → validateAndVectorizeOperatorTree                            │
│    → 逐算子: 类型检查 → UDF检查 → 创建 VectorXxxOperator         │
│                                                                  │
│  降级原因 TOP5：                                                  │
│    1. 不支持的 UDF   2. 不支持的数据类型                           │
│    3. 不支持的输入格式  4. MR Reduce端                            │
│    5. 复杂类型聚合                                                │
│                                                                  │
│  诊断工具：EXPLAIN VECTORIZATION DETAIL                           │
│  救命参数：hive.vectorized.adaptor.usage.mode=all                 │
│                                                                  │
│  性能公式：向量化 ≈ 3~100x 提升（取决于 CPU Cache 命中率）         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java` — 向量化总控制器
   - `storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizedRowBatch.java` — 批次容器
   - `storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/ColumnVector.java` — 列向量基类
   - `storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/LongColumnVector.java` — Long 列实现
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/expressions/VectorExpression.java` — 表达式基类
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorFilterOperator.java` — 向量化 Filter
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorSelectOperator.java` — 向量化 Select
   - `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorGroupByOperator.java` — 向量化 GroupBy

2. **官方文档**
   - [Hive Vectorized Query Execution](https://cwiki.apache.org/confluence/display/Hive/Vectorized+Query+Execution)
   - [HIVE-4160: Vectorized Query Execution](https://issues.apache.org/jira/browse/HIVE-4160)

3. **经典论文**
   - *MonetDB/X100: Hyper-Pipelining Query Execution* (Peter Boncz, 2005) — 向量化执行的理论基础
   - *Vectorization vs. Compilation in Query Execution* (Sompolski et al., 2011)
