# S15 - Hive 向量化执行引擎 Vectorization 源码深度分析

> **知识晶体化模板** | 基于 Hive 3.x 源码 | 作者: Eric (豹纹) for 大哥

---

## 一、问题/场景

向量化执行是 Hive 2.0+ 的核心性能优化，将逐行处理（row-at-a-time）转变为批量处理（batch-at-a-time），大幅提升 CPU 利用率：

1. **查询性能提升 2-10 倍**: 向量化利用 CPU cache、SIMD 指令和循环展开
2. **向量化不生效**: 查询使用了不支持向量化的 UDF 或数据类型，静默降级为行模式
3. **EXPLAIN 中看不到 vectorized**: 执行计划显示未向量化，但不知道原因
4. **ORC 必须配合**: 向量化读取目前最优支持 ORC 格式

**核心源码目录**:
- 数据结构: `storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/`
- 表达式: `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/expressions/`
- 向量化器: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java`
- 上下文: `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizationContext.java`

---

## 二、架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                      查询编译流程                                │
│                                                                 │
│  SQL → Parse → Analyze → Optimize → Physical Plan               │
│                                              ↓                   │
│                                    ┌─────────────────────┐      │
│                                    │    Vectorizer        │      │
│                                    │ (物理计划优化器)      │      │
│                                    │                     │      │
│                                    │ 1. 验证是否可向量化  │      │
│                                    │ 2. 替换为向量化算子  │      │
│                                    │ 3. 构建向量化表达式  │      │
│                                    └──────────┬──────────┘      │
│                                               │                  │
└───────────────────────────────────────────────┼──────────────────┘
                                                │
┌───────────────────────────────────────────────▼──────────────────┐
│                      运行时执行                                   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              VectorizedRowBatch (1024行/批)               │   │
│  │                                                          │   │
│  │  ColumnVector[] cols:                                    │   │
│  │    cols[0]: LongColumnVector   {vector: long[1024]}      │   │
│  │    cols[1]: BytesColumnVector  {vector: byte[][], ...}   │   │
│  │    cols[2]: DoubleColumnVector {vector: double[1024]}    │   │
│  │                                                          │   │
│  │  int size = 1024;            // 当前批次行数             │   │
│  │  int[] selected;             // 过滤后的行索引           │   │
│  │  boolean selectedInUse;      // 是否有过滤               │   │
│  └────────────────────────┬─────────────────────────────────┘   │
│                           │                                      │
│  ┌────────────────────────▼─────────────────────────────────┐   │
│  │        VectorExpression Tree (向量化表达式树)              │   │
│  │                                                          │   │
│  │  例: WHERE age > 18 AND name LIKE 'John%'               │   │
│  │                                                          │   │
│  │  FilterExprAndExpr                                       │   │
│  │    ├─ LongColGreaterLongScalar(col=0, val=18, out=3)    │   │
│  │    └─ SelectStringColLikeStringScalar(col=1, pat='John%')│   │
│  │                                                          │   │
│  │  evaluate(batch) → 修改 batch.selected[] 和 batch.size  │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 三、核心数据结构

### 3.1 VectorizedRowBatch — 批量数据容器

**文件**: `storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizedRowBatch.java`

```java
// VectorizedRowBatch.java:34-101
public class VectorizedRowBatch implements Writable {
    public int numCols;              // 列数
    public ColumnVector[] cols;      // 每列一个向量
    public int size;                 // 当前批次有效行数
    public int[] selected;           // 过滤后的行位置数组
    public boolean selectedInUse;    // 是否有过滤 (false=全部有效)
    public boolean endOfFile;        // 是否到达输入末尾
    
    public static final int DEFAULT_SIZE = 1024;  // 默认批大小: 1024 行
    
    public VectorizedRowBatch(int numCols, int size) {
        this.numCols = numCols;
        this.size = size;
        selected = new int[size];
        selectedInUse = false;
        this.cols = new ColumnVector[numCols];
        // 初始时所有列都投影
        projectionSize = numCols;
        for (int i = 0; i < numCols; i++) {
            projectedColumns[i] = i;
        }
    }
}
```

**设计意图**:
- **DEFAULT_SIZE = 1024**: 精心选择以确保一个 batch 能装进 CPU L2 cache
- **selectedInUse**: 避免数据复制，Filter 只修改 `selected[]` 数组标记哪些行通过
- **projectedColumns**: 列裁剪，只处理需要的列

### 3.2 ColumnVector — 列向量抽象基类

**文件**: `storage-api/src/java/org/apache/hadoop/hive/ql/exec/vector/ColumnVector.java`

```java
// ColumnVector.java:33-116
public abstract class ColumnVector {
    
    public static enum Type {
        NONE, LONG, DOUBLE, BYTES, DECIMAL, DECIMAL_64, 
        TIMESTAMP, INTERVAL_DAY_TIME, STRUCT, LIST, MAP, UNION, VOID
    }
    
    public final Type type;
    public boolean[] isNull;      // NULL 标记数组
    public boolean noNulls;       // 整列无 NULL 时为 true (快速路径)
    public boolean isRepeating;   // 整列值相同时为 true (常量折叠)
    
    public ColumnVector(Type type, int len) {
        this.type = type;
        isNull = new boolean[len];
        noNulls = true;
        isRepeating = false;
    }
    
    // 展开 isRepeating 到全量数组 (用于减少向量表达式的代码路径)
    abstract public void flatten(boolean selectedInUse, int[] sel, int size);
}
```

**类型体系**:

| ColumnVector 子类 | 底层存储 | 对应 Hive 类型 |
|-----------------|---------|--------------|
| `LongColumnVector` | `long[]` | TINYINT, SMALLINT, INT, BIGINT, BOOLEAN, DATE |
| `DoubleColumnVector` | `double[]` | FLOAT, DOUBLE |
| `BytesColumnVector` | `byte[][]` + `int[] start` + `int[] length` | STRING, VARCHAR, CHAR, BINARY |
| `DecimalColumnVector` | `HiveDecimalWritable[]` | DECIMAL |
| `Decimal64ColumnVector` | `long[]` (定点数编码) | DECIMAL(≤18位) |
| `TimestampColumnVector` | `long[] time` + `int[] nanos` | TIMESTAMP |
| `IntervalDayTimeColumnVector` | `long[] totalSeconds` + `int[] nanos` | INTERVAL DAY TO SECOND |
| `StructColumnVector` | `ColumnVector[] fields` | STRUCT |
| `ListColumnVector` | `ColumnVector child` + `long[] offsets` | ARRAY |
| `MapColumnVector` | `ColumnVector keys/values` + `long[] offsets` | MAP |

### 3.3 LongColumnVector — 整型列向量

```java
// LongColumnVector.java:33-53
public class LongColumnVector extends ColumnVector {
    public long[] vector;  // 核心: 原始 long 数组，直接内存访问

    public LongColumnVector(int len) {
        super(Type.LONG, len);
        vector = new long[len];  // 默认 1024 个 long = 8KB
    }
}
```

**性能关键**: `vector` 字段为 `public`，允许向量化表达式直接访问底层数组，避免方法调用开销。

### 3.4 isRepeating 优化

当整列值相同时（如常量列、分区列），只需存储一个值：

```java
// 常量列: isRepeating=true, vector[0]=常量值
// 处理时只需 O(1) 而非 O(N)
if (inputColVector.isRepeating) {
    // 只处理 vector[0]，结果也设为 repeating
    outputColVector.vector[0] = inputColVector.vector[0] + scalar;
    outputColVector.isRepeating = true;
} else {
    // 批量处理所有行
    for (int i = 0; i < n; i++) {
        outputColVector.vector[i] = inputColVector.vector[i] + scalar;
    }
}
```

---

## 四、Vectorizer — 向量化决策引擎

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/Vectorizer.java`

这是一个约 2000+ 行的物理计划优化器，决定哪些算子可以被向量化。

### 4.1 入口

```java
// Vectorizer.java:240
public class Vectorizer implements PhysicalPlanResolver {
    // 遍历物理执行计划的所有 Task
    // 对每个 MapWork/ReduceWork 尝试向量化
}
```

### 4.2 核心验证流程

```java
// Vectorizer.java:729+ (简化)
private Operator<? extends OperatorDesc> validateAndVectorizeOperatorTree(
    Operator<? extends OperatorDesc> op, boolean isReduce, boolean isTezOrSpark, ...) {
    
    // 递归遍历算子树
    for (Operator<? extends OperatorDesc> child : op.getChildOperators()) {
        validateAndVectorizeOperator(child, vContext, isReduce, isTezOrSpark, ...);
    }
}
```

**向量化决策树** (Vectorizer 内部逻辑):
```
validateAndVectorizeMapWork(mapWork)
  │
  ├─ 检查输入格式: 是否实现 VectorizedInputFormatInterface?
  │   └─ OrcInputFormat ✓  (原生向量化读取)
  │   └─ ParquetInputFormat ✓ (3.0+ 支持)
  │   └─ TextInputFormat ✗ (需 VectorizedRowBatch 适配)
  │
  ├─ 检查表属性: ACID/MM 表是否支持?
  │
  └─ validateAndVectorizeOperatorTree()
       │
       ├─ TableScanOperator → VectorizedTableScan ✓
       │
       ├─ FilterOperator → 检查谓词表达式
       │   └─ VectorizationContext.getVectorExpression(filterExpr)
       │       ├─ 成功 → VectorFilterOperator ✓
       │       └─ 失败 → 记录原因, 整个分支回退行模式
       │
       ├─ SelectOperator → 检查投影表达式
       │   └─ 同上
       │
       ├─ GroupByOperator → 检查聚合函数
       │   └─ 是否有向量化UDAF实现?
       │
       ├─ MapJoinOperator → 检查 JOIN 键类型
       │   └─ Long/String/MultiKey → 特化向量化实现
       │
       └─ ReduceSinkOperator → 检查排序键和值类型
```

### 4.3 不支持向量化的场景

以下情况会导致向量化降级：

| 场景 | 原因 | 源码位置 |
|------|------|---------|
| 非 ORC/Parquet 格式 | 不支持向量化读取 | Vectorizer 输入格式检查 |
| 自定义 UDF | 无向量化实现 | VectorizationContext |
| STRUCT/MAP/ARRAY 在表达式中 | 复杂类型向量化不完整 | VectorExpressionDescriptor |
| 非确定性函数 (rand()) | 不可批量计算 | VectorizationContext |
| ACID DELETE delta 读取 | 部分版本不支持 | Vectorizer ACID 检查 |
| PTF 窗口函数 (部分) | 实现不完整 | Vectorizer PTF 检查 |

---

## 五、VectorExpression — 向量化表达式

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/expressions/VectorExpression.java`

### 5.1 基类设计

```java
// VectorExpression.java:63-100
public abstract class VectorExpression implements Serializable {
    protected VectorExpression[] childExpressions;  // 子表达式 (需计算的参数)
    protected TypeInfo[] inputTypeInfos;            // 输入类型信息
    protected final int outputColumnNum;            // 输出列号 (scratch column)
    protected TypeInfo outputTypeInfo;              // 输出类型
    
    // 核心方法: 在整个 batch 上求值
    public abstract void evaluate(VectorizedRowBatch batch) throws HiveException;
}
```

### 5.2 表达式求值示例: LongColGreaterLongScalar

```java
// 假设生成的向量化表达式 (概念等价代码):
// WHERE age > 18
public class LongColGreaterLongScalar extends VectorExpression {
    private final int colNum;     // age 列号
    private final long value;     // 常量 18
    
    @Override
    public void evaluate(VectorizedRowBatch batch) {
        int n = batch.size;
        if (n == 0) return;
        
        long[] vector = ((LongColumnVector) batch.cols[colNum]).vector;
        int[] sel = batch.selected;
        
        if (batch.selectedInUse) {
            // 已有过滤: 只检查已选中的行
            int newSize = 0;
            for (int j = 0; j < n; j++) {
                int i = sel[j];
                if (vector[i] > value) {
                    sel[newSize++] = i;  // 通过的行保留在 selected 中
                }
            }
            batch.size = newSize;
        } else {
            // 无过滤: 检查所有行
            int newSize = 0;
            for (int i = 0; i < n; i++) {
                if (vector[i] > value) {
                    sel[newSize++] = i;
                }
            }
            if (newSize < n) {
                batch.selectedInUse = true;
                batch.size = newSize;
            }
        }
    }
}
```

**性能优势**:
1. **紧凑循环**: 内层循环只有数组访问和比较，CPU 分支预测友好
2. **数据局部性**: `long[]` 连续内存，L1/L2 cache 命中率高
3. **无对象创建**: 无装箱/拆箱，无 Object 分配
4. **SIMD 友好**: JVM 可自动向量化简单数组循环

### 5.3 VectorizationContext — 表达式构建工厂

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizationContext.java`

这是一个约 5000+ 行的工厂类，负责将 `ExprNodeDesc` 树转换为 `VectorExpression` 树：

```java
// VectorizationContext.java (概念)
public class VectorizationContext {
    
    // 将表达式描述符转换为向量化表达式
    public VectorExpression getVectorExpression(ExprNodeDesc exprDesc) {
        if (exprDesc instanceof ExprNodeColumnDesc) {
            return new IdentityExpression(columnNum);
        }
        if (exprDesc instanceof ExprNodeConstantDesc) {
            return new ConstantVectorExpression(outputCol, value);
        }
        if (exprDesc instanceof ExprNodeGenericFuncDesc) {
            // 根据函数类型 + 参数类型 选择特化实现
            // 例: GenericUDFOPGreaterThan + (LONG col, LONG scalar) 
            //     → LongColGreaterLongScalar
            return getGenericFuncVectorExpression(funcDesc);
        }
        // ... 无法向量化时抛异常或使用 VectorUDFAdaptor
    }
}
```

**VectorUDFAdaptor** — UDF 降级适配器:
```java
// 当 UDF 没有原生向量化实现时，使用适配器逐行调用
// hive.vectorized.adaptor.usage.mode 控制:
//   none:   不使用适配器 → 整个算子降级行模式
//   chosen: 部分 UDF 使用适配器
//   all:    所有不可向量化 UDF 都用适配器
```

---

## 六、调用链 — 向量化查询执行完整流程

```
SQL: SELECT name, SUM(amount) FROM orders WHERE dt='2024-01-01' GROUP BY name;

═══ 编译期 ═══

1. Physical Plan 生成后:
   TableScan → Filter(dt='2024-01-01') → Select(name,amount) → GroupBy → FileSink

2. Vectorizer.resolve()
   ├─ validateAndVectorizeMapWork()
   │   ├─ 检查输入: OrcInputFormat → 支持向量化读取 ✓
   │   ├─ TableScan → VectorizedTableScan (配置 VectorizedRowBatchCtx)
   │   ├─ Filter: VectorizationContext.getVectorExpression(dt='2024-01-01')
   │   │   → FilterStringColEqualStringScalar ✓
   │   ├─ Select: 投影 name, amount → IdentityExpression ✓
   │   └─ GroupBy: SUM(amount) → VectorUDAFSumLong ✓
   │
   └─ 所有算子通过 → 标记为向量化执行

═══ 运行时 ═══

3. ORC Reader 直接生成 VectorizedRowBatch:
   batch.cols[0] = BytesColumnVector (dt)     // "2024-01-01"...
   batch.cols[1] = BytesColumnVector (name)   // "Alice", "Bob"...
   batch.cols[2] = LongColumnVector  (amount) // 100, 200, 150...
   batch.size = 1024

4. VectorFilterOperator.process(batch):
   FilterStringColEqualStringScalar.evaluate(batch)
   // 扫描 cols[0]，把 dt='2024-01-01' 的行标记到 selected[]
   // batch.size = 156 (假设 156 行匹配)
   // batch.selectedInUse = true

5. VectorSelectOperator.process(batch):
   // 投影: 只保留 cols[1](name) 和 cols[2](amount)
   // 无数据复制，只修改 projectedColumns

6. VectorGroupByOperator.process(batch):
   // 按 name 分组，对 amount 累加
   // 使用向量化聚合: VectorUDAFSumLong
   // 输出到下游

═══ 全程无 Object 创建，无序列化/反序列化 ═══
```

---

## 七、关键参数与调优建议

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.vectorized.execution.enabled` | true | 全局开关 |
| `hive.vectorized.execution.reduce.enabled` | true | Reduce 端向量化 |
| `hive.vectorized.execution.reduce.groupby.enabled` | true | GroupBy 向量化 |
| `hive.vectorized.use.vectorized.input.format` | true | 使用向量化输入格式 |
| `hive.vectorized.use.checked.expressions` | true | 使用类型检查的表达式 |
| `hive.vectorized.adaptor.usage.mode` | chosen | UDF 适配器模式 |
| `hive.vectorized.input.format.supports.enabled` | decimal_64 | 输入格式支持特性 |
| `hive.vectorized.execution.vectorized.ptf.enabled` | true | PTF 向量化 |

### 调优建议

1. **确保使用 ORC 格式**: 向量化 + ORC = 最佳性能
2. **检查 EXPLAIN VECTORIZATION**: `EXPLAIN VECTORIZATION DETAIL SELECT ...` 查看向量化状态
3. **避免自定义 UDF**: 使用内置函数，或为 UDF 提供向量化实现
4. **利用 Decimal64**: 对 precision ≤ 18 的 DECIMAL，使用 long 编码加速
5. **监控降级**: 关注日志中 `Vectorizer` 相关的 WARN/INFO，了解降级原因

---

## 八、踩坑记录

### 8.1 向量化静默降级

**现象**: 查询变慢但无明显报错。

**排查**: 使用 `EXPLAIN VECTORIZATION DETAIL` 查看:
```sql
EXPLAIN VECTORIZATION DETAIL
SELECT * FROM orders WHERE dt = '2024-01-01';
```

输出中关注:
- `vectorized: true/false` — 是否向量化
- `notVectorizedReason` — 降级原因

### 8.2 TextFile 不支持向量化读取

**现象**: TextFile 表查询无法向量化。

**根因**: TextFile 没有实现 `VectorizedInputFormatInterface`，无法直接产出 `VectorizedRowBatch`。

**解决**: 将表转换为 ORC: `CREATE TABLE t_orc STORED AS ORC AS SELECT * FROM t_text;`

### 8.3 复杂类型表达式降级

**现象**: 包含 STRUCT/ARRAY/MAP 列操作的查询未向量化。

**根因**: 复杂类型的向量化表达式实现不完整，`VectorizationContext` 在匹配时找不到对应的 VectorExpression 类。

**解决**: 避免在 WHERE/SELECT 中直接操作复杂类型字段，先用 LATERAL VIEW EXPLODE 展开。

---

## 九、总结

Hive 向量化执行的核心设计：

1. **列式内存布局** (`VectorizedRowBatch` + `ColumnVector[]`): 数据按列组织，利用 CPU cache 和 SIMD
2. **批量处理** (DEFAULT_SIZE=1024): 减少虚函数调用次数，摊薄每行开销
3. **selected[] 过滤传播**: Filter 不复制数据，只标记有效行位置
4. **isRepeating/noNulls 快速路径**: 常量和无 NULL 列的 O(1) 处理
5. **特化表达式生成**: 根据类型组合选择最优实现（代码生成/模板）
6. **物理优化器验证**: `Vectorizer` 在编译期决定是否可向量化，不可行则优雅降级

**性能提升本质**: 将 N 次虚函数调用（行模式）转变为 1 次函数调用处理 N 行（向量模式），循环内只有原始数组操作。
