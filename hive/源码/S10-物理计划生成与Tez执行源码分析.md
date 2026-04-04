# S10: 物理计划生成与 Tez 执行 — Task Tree 到 DAG 提交源码深度分析

> **创建时间**: 2026-04-04
> **分析版本**: Apache Hive 3.x / 4.x
> **标签**: #Hive #TezTask #TezWork #PhysicalOptimizer #DAG #YARN #源码分析

---

## 一、物理计划在编译链路中的位置

```
优化后的 Operator Tree (来自 S09 优化器)
  ↓
┌──────────────────────────────────────────────────────┐
│ Phase 4: TaskCompiler（物理计划生成）← 本文聚焦       │
│   Operator Tree → Task Tree (TezTask / MapRedTask)   │
│                                                      │
│ Phase 5: PhysicalOptimizer（物理优化）                │
│   Task Tree → 优化后的 Task Tree                      │
│                                                      │
│ Phase 6: TezTask 执行                                 │
│   Task Tree → Tez DAG → 提交到 YARN                  │
└──────────────────────────────────────────────────────┘
```

---

## 二、TaskCompiler — 物理计划编译器

### 2.1 编译器选择

```java
// SemanticAnalyzer.analyzeInternal() 的最后阶段
private void generateTaskTree() throws SemanticException {
    
    // ★ 通过工厂获取对应执行引擎的编译器
    TaskCompiler compiler = TaskCompilerFactory.getCompiler(
        conf, db);
    
    // 根据 hive.execution.engine 参数选择:
    // - "mr"    → MapReduceCompiler
    // - "tez"   → TezCompiler (主流)
    // - "spark"  → SparkCompiler
    
    compiler.init(queryState, console, db);
    compiler.compile(pCtx, rootTasks, inputs, outputs);
}
```

### 2.2 TaskCompilerFactory

```java
public class TaskCompilerFactory {
    
    public static TaskCompiler getCompiler(HiveConf conf, Hive db) {
        
        String engine = conf.getVar(HiveConf.ConfVars.HIVE_EXECUTION_ENGINE);
        
        switch (engine) {
            case "tez":
                return new TezCompiler();
            case "spark":
                return new SparkCompiler();
            case "mr":
            default:
                return new MapReduceCompiler();
        }
    }
}
```

---

## 三、TezCompiler — Tez 物理计划编译

### 3.1 核心编译流程

```java
public class TezCompiler extends TaskCompiler {
    
    @Override
    public void compile(ParseContext pCtx, 
                        List<Task<?>> rootTasks,
                        Set<ReadEntity> inputs, 
                        Set<WriteEntity> outputs) 
        throws SemanticException {
        
        // ★ Step 1: 优化 Operator Tree（Tez 特有优化）
        optimizeOperatorPlan(pCtx);
        
        // ★ Step 2: Operator Tree → Task Tree
        generateTaskTree(rootTasks, pCtx);
        
        // ★ Step 3: 物理优化
        optimizeTaskPlan(rootTasks, pCtx);
        
        // ★ Step 4: 收尾（设置 FetchTask、统计信息等）
        decideExecMode(rootTasks, pCtx);
    }
    
    // Tez 特有的 Operator 优化
    private void optimizeOperatorPlan(ParseContext pCtx) {
        // DPP (Dynamic Partition Pruning) 优化
        // → 在 Join 时动态裁剪另一侧的分区
        new DynamicPartitionPruningOptimization().transform(pCtx);
        
        // 向量化
        if (conf.getBoolVar(HiveConf.ConfVars.HIVE_VECTORIZATION_ENABLED)) {
            new Vectorizer().transform(pCtx);
        }
        
        // 其他 Tez 特有优化...
    }
}
```

### 3.2 生成 Task Tree（generateTaskTree）

```java
/**
 * 将 Operator Tree 切割为多个 Task
 * 
 * 核心思想：
 * 遇到 ReduceSinkOperator → 切分为新的 Map/Reduce Work
 * 遇到 FileSinkOperator   → 当前 Work 结束
 * 多个 Work 组成一个 TezWork (DAG)
 */
private void generateTaskTree(List<Task<?>> rootTasks, ParseContext pCtx) {
    
    // ★ 创建 TezWork（DAG 容器）
    TezWork tezWork = new TezWork(queryId);
    
    // ★ 遍历 Operator Tree，按 ReduceSinkOperator 切分
    // 每个切分生成一个 BaseWork:
    //   - MapWork: 处理 Map 阶段（TableScan → ... → ReduceSink）
    //   - ReduceWork: 处理 Reduce 阶段（接收 Shuffle 数据 → ... → FileSink）
    
    GenTezUtils.generateTasks(pCtx, rootTasks, tezWork);
    
    // ★ 构建 TezTask 封装 TezWork
    TezTask tezTask = (TezTask) TaskFactory.get(tezWork);
    rootTasks.add(tezTask);
}
```

---

## 四、TezWork — DAG 数据结构

### 4.1 TezWork 结构

```java
public class TezWork extends AbstractOperatorDesc {
    
    // ★ 核心: DAG 图结构
    private Set<BaseWork> roots;           // 根节点（无依赖的 Work）
    private Set<BaseWork> leaves;          // 叶子节点（无后续的 Work）
    private Map<BaseWork, List<BaseWork>> 
        workGraph;                         // 邻接表：Work → 下游 Work 列表
    
    // Edge 信息
    private Map<BaseWork, Map<BaseWork, EdgeProperty>> 
        edgeProperties;                    // 边属性（Shuffle 方式）
    
    // 所有 Work
    private List<BaseWork> allWork;
    
    // ★ 添加 Work 到 DAG
    public void addWork(BaseWork work) {
        allWork.add(work);
    }
    
    // ★ 添加边（依赖关系）
    public void connect(BaseWork parent, BaseWork child, EdgeProperty edgeProp) {
        workGraph.get(parent).add(child);
        edgeProperties.get(parent).put(child, edgeProp);
    }
}
```

### 4.2 BaseWork 子类

```java
// Work 继承体系
BaseWork (抽象基类)
  ├── MapWork          ← Map 阶段（TableScan → Operators → ReduceSink/FileSink）
  ├── ReduceWork       ← Reduce 阶段（Shuffle 后 → Operators → FileSink）
  ├── MergeJoinWork    ← SMB Join 专用
  └── UnionWork        ← Union All 专用
```

```java
public class MapWork extends BaseWork {
    
    // 输入路径 → Operator 映射
    private LinkedHashMap<Path, List<String>> 
        pathToAliases;                     // HDFS 路径 → 表别名
    private LinkedHashMap<Path, PartitionDesc> 
        pathToPartitionInfo;               // HDFS 路径 → 分区信息
    private LinkedHashMap<String, Operator<?>> 
        aliasToWork;                       // 别名 → Operator 子树根节点
    
    // 向量化
    private VectorizedRowBatchCtx 
        vectorizedRowBatchCtx;             // 向量化上下文
    
    // MapJoin 本地工作
    private MapredLocalWork mapRedLocalWork; // 小表加载信息
}

public class ReduceWork extends BaseWork {
    
    private Operator<?> reducer;            // Reduce 端 Operator 子树根节点
    private int numReduceTasks = -1;        // Reducer 数量（-1 = 自动）
    private boolean needsTagging;           // 是否需要标记（多输入 Join）
    
    // Shuffle Key 信息
    private TableDesc keyDesc;              // Key 的序列化描述
    private List<TableDesc> tagToValueDesc; // 各输入的 Value 序列化描述
}
```

### 4.3 EdgeProperty — 边属性

```java
public class EdgeProperty {
    
    // ★ 边类型（数据分发方式）
    public enum DataMovementType {
        SCATTER_GATHER,     // Shuffle（Hash 分区）
        BROADCAST,          // 广播（MapJoin 小表分发）
        ONE_TO_ONE,         // 一对一（无 Shuffle）
        CUSTOM              // 自定义
    }
    
    // ★ 数据源类型
    public enum DataSourceType {
        PERSISTED,          // 持久化到 HDFS
        PERSISTED_RELIABLE, // 可靠持久化
        EPHEMERAL           // 临时（内存/本地磁盘）
    }
    
    // ★ 调度类型
    public enum SchedulingType {
        SEQUENTIAL,         // 顺序执行
        CONCURRENT          // 并发执行
    }
    
    private DataMovementType dataMovementType;
    private DataSourceType dataSourceType;
    private SchedulingType schedulingType;
    private int numTasks;  // 下游 Task 数量
}
```

---

## 五、TezWork DAG 示例

### 5.1 简单 Join 查询

```sql
SELECT a.id, b.name
FROM t1 a JOIN t2 b ON a.id = b.id
WHERE a.age > 25
```

生成的 TezWork DAG:
```
MapWork-1 (扫描 t1)                MapWork-2 (扫描 t2)
├── TableScanOp(t1)               ├── TableScanOp(t2)
├── FilterOp(age > 25)            └── ReduceSinkOp(key=b.id)
└── ReduceSinkOp(key=a.id)
        \                              /
         \  SCATTER_GATHER            /  SCATTER_GATHER
          ↘                         ↙
           ReduceWork-1 (Join)
           ├── JoinOp(a.id = b.id)
           ├── SelectOp(a.id, b.name)
           └── FileSinkOp
```

### 5.2 MapJoin 查询（广播边）

```sql
-- t2 是小表，自动转为 MapJoin
SELECT a.id, b.name
FROM t1 a JOIN t2 b ON a.id = b.id
```

生成的 TezWork DAG:
```
MapWork-2 (扫描 t2)  ──BROADCAST──→  MapWork-1 (扫描 t1 + MapJoin)
├── TableScanOp(t2)                   ├── TableScanOp(t1)
├── HashTableSinkOp                   ├── MapJoinOp(a.id = b.id)
                                      ├── SelectOp
                                      └── FileSinkOp

注: t2 作为 broadcast edge 广播到 MapWork-1 的每个 Map Task
```

### 5.3 MRR 链式 Reduce

```sql
SELECT dept, COUNT(*) as cnt
FROM employees
WHERE age > 25
GROUP BY dept
ORDER BY cnt DESC
```

生成的 TezWork DAG (MRR 模式):
```
MapWork-1 (扫描 + 预聚合)
├── TableScanOp(employees)
├── FilterOp(age > 25)
├── GroupByOp(Map端预聚合: dept, count)
└── ReduceSinkOp(key=dept)
        |
        | SCATTER_GATHER
        ↓
ReduceWork-1 (聚合)
├── GroupByOp(dept, count(*))
└── ReduceSinkOp(key=cnt, order=DESC)
        |
        | SCATTER_GATHER
        ↓
ReduceWork-2 (排序)
├── ExtractOp
└── FileSinkOp

优化: 传统 MR 需要 2 个独立 Job
      Tez 合并为 1 个 DAG，ReduceWork-1 直接 pipeline 到 ReduceWork-2
      省去了中间写 HDFS 的开销
```

---

## 六、PhysicalOptimizer — 物理优化

### 6.1 物理优化规则

```java
public class PhysicalOptimizer {
    
    private List<PhysicalPlanResolver> resolvers;
    
    public void initialize(HiveConf conf) {
        resolvers = new ArrayList<>();
        
        // ★ MR 引擎的物理优化
        if (engine == "mr") {
            // Common Join → MapJoin 候选方案
            resolvers.add(new CommonJoinResolver());
            // MapJoin 注入 LocalTask + BackupTask (→ S06)
            resolvers.add(new MapJoinResolver());
            // Skew Join 优化
            resolvers.add(new SkewJoinResolver());
        }
        
        // ★ Tez 引擎的物理优化
        if (engine == "tez") {
            // 交叉积检测
            resolvers.add(new CrossProductHandler());
            // 向量化选择
            resolvers.add(new Vectorizer());
            // NullScan 优化
            resolvers.add(new NullScanOptimizer());
            // Stage ID 分配
            resolvers.add(new StageIDsRearranger());
        }
        
        // 通用优化
        resolvers.add(new SortMergeJoinResolver());
        resolvers.add(new MetadataOnlyOptimizer());
    }
    
    public PhysicalContext resolve(PhysicalContext pctx) {
        for (PhysicalPlanResolver r : resolvers) {
            pctx = r.resolve(pctx);
        }
        return pctx;
    }
}
```

---

## 七、TezTask — 执行引擎

### 7.1 TezTask 生命周期

```java
public class TezTask extends Task<TezWork> {
    
    @Override
    public int execute() {
        
        // ★ Step 1: 获取或创建 TezSession
        TezSessionState session = getTezSession();
        // Tez Session 可以复用（Session 池化），避免重复启动 AM
        
        // ★ Step 2: TezWork → Tez DAG
        DAG dag = build(conf, work, ...);
        
        // ★ Step 3: 提交 DAG 到 Tez AM
        DAGClient dagClient = session.submitDAG(dag);
        
        // ★ Step 4: 监控执行
        TezJobMonitor monitor = new TezJobMonitor(dagClient);
        int rc = monitor.monitorExecution();
        
        // ★ Step 5: 获取结果
        if (rc == 0) {
            // 成功：获取计数器
            counters = dagClient.getDAGCounters();
        } else {
            // 失败：获取诊断信息
            diagnostics = dagClient.getDAGDiagnostics();
        }
        
        return rc;
    }
}
```

### 7.2 构建 Tez DAG

```java
private DAG build(HiveConf conf, TezWork work, ...) {
    
    DAG dag = DAG.create(work.getName());
    
    // ★ Step 1: 为每个 BaseWork 创建 Tez Vertex
    Map<BaseWork, Vertex> workToVertex = new HashMap<>();
    
    for (BaseWork w : work.getAllWork()) {
        
        // 序列化 Work 描述
        byte[] serializedWork = SerializationUtilities.serializePlan(w);
        
        // 创建 Vertex
        Vertex vertex;
        if (w instanceof MapWork) {
            vertex = createMapVertex((MapWork) w, conf, serializedWork);
            // 设置输入: HDFS 输入路径
            // 设置并行度: 基于输入 split 数
            // 设置 Processor: ExecMapper.class
        } else if (w instanceof ReduceWork) {
            vertex = createReduceVertex((ReduceWork) w, conf, serializedWork);
            // 设置并行度: numReduceTasks
            // 设置 Processor: ExecReducer.class
        }
        
        // 设置资源
        vertex.setTaskResource(Resource.newInstance(
            memoryMb,    // hive.tez.container.size
            vcores));    // hive.tez.container.vcores
        
        // 设置 JVM 参数
        vertex.setTaskLaunchCmdOpts(javaOpts);
        
        dag.addVertex(vertex);
        workToVertex.put(w, vertex);
    }
    
    // ★ Step 2: 为每条边创建 Tez Edge
    for (BaseWork parent : work.getAllWork()) {
        for (BaseWork child : work.getChildren(parent)) {
            EdgeProperty edgeProp = work.getEdgeProperty(parent, child);
            
            Edge edge = Edge.create(
                workToVertex.get(parent),
                workToVertex.get(child),
                convertEdgeProperty(edgeProp));
            
            dag.addEdge(edge);
        }
    }
    
    return dag;
}
```

### 7.3 TezJobMonitor — 执行监控

```java
public class TezJobMonitor {
    
    private DAGClient dagClient;
    
    public int monitorExecution() {
        
        DAGStatus status;
        
        while (true) {
            status = dagClient.getDAGStatus(
                EnumSet.of(StatusGetOpts.GET_COUNTERS));
            
            DAGStatus.State state = status.getState();
            
            switch (state) {
                case RUNNING:
                    // 打印进度条
                    printProgress(status);
                    // Map 1: 45/100  Reducer 2: 10/50
                    break;
                    
                case SUCCEEDED:
                    printProgress(status);
                    return 0;
                    
                case FAILED:
                    printDiagnostics(status);
                    return 2;
                    
                case KILLED:
                    return 2;
                    
                case ERROR:
                    return 3;
            }
            
            Thread.sleep(checkInterval);
        }
    }
    
    // 打印进度
    private void printProgress(DAGStatus status) {
        // 格式: Map 1: 100(+5)/200  Reducer 2: 50(+3)/100
        //        完成数(+运行中)/总数
        for (Progress vertexProgress : status.getVertexProgress()) {
            console.printInfo(String.format(
                "%-20s %d(+%d)/%d",
                vertexProgress.getName(),
                vertexProgress.getSucceededTaskCount(),
                vertexProgress.getRunningTaskCount(),
                vertexProgress.getTotalTaskCount()));
        }
    }
}
```

---

## 八、Session 管理与 AM 复用

### 8.1 TezSessionPool

```java
// Hive 支持 Tez Session 复用，避免每次查询都启动新的 AM
public class TezSessionPoolManager {
    
    private Queue<TezSessionState> pool;
    
    // 获取 Session（从池中取或新建）
    public TezSessionState getSession(HiveConf conf) {
        TezSessionState session = pool.poll();
        if (session == null || !session.isOpen()) {
            session = createNewSession(conf);
        }
        return session;
    }
    
    // 归还 Session 到池
    public void returnSession(TezSessionState session) {
        if (session.isOpen()) {
            pool.offer(session);
        }
    }
}
```

### 8.2 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.execution.engine` | `mr` (旧) / `tez` (新) | 执行引擎选择 |
| `hive.tez.container.size` | `-1` (自动) | Tez Container 内存 (MB) |
| `hive.tez.java.opts` | 空 (自动) | Tez JVM 参数 |
| `hive.server2.tez.default.queues` | 空 | Tez Session 默认 YARN 队列 |
| `hive.server2.tez.sessions.per.default.queue` | `1` | 每个队列的 Session 数 |
| `hive.server2.tez.initialize.default.sessions` | `false` | 是否预初始化 Session |
| `tez.grouping.min-size` | `16MB` | 最小输入分组大小 |
| `tez.grouping.max-size` | `1GB` | 最大输入分组大小 |
| `tez.am.resource.memory.mb` | `1024` | AM 内存 |

---

## 九、完整编译执行链路总结

```
SQL 字符串
  ↓ ParseDriver.parse() ← S07
ASTNode (抽象语法树)
  ↓ SemanticAnalyzerFactory.get()
  ↓ SemanticAnalyzer.analyzeInternal() ← S08
    ├── doPhase1(): AST → QB
    ├── getMetaData(): 填充元数据
    └── genOPTree(): QB → Operator Tree
        (如果 CBO 开启 → CalcitePlanner 介入 ← S09)
  ↓ Optimizer.optimize() ← S09
优化后的 Operator Tree
  ↓ TaskCompilerFactory.getCompiler() ← S10
  ↓ TezCompiler.compile()
    ├── optimizeOperatorPlan(): DPP/向量化
    ├── generateTaskTree(): Operator Tree → TezWork (DAG)
    └── optimizeTaskPlan(): PhysicalOptimizer
  ↓
TezTask (封装 TezWork)
  ↓ TezTask.execute()
    ├── build(): TezWork → Tez DAG (Vertex + Edge)
    ├── session.submitDAG(): 提交到 YARN
    └── TezJobMonitor.monitorExecution(): 监控执行
  ↓
YARN → Tez AM → Map/Reduce Tasks → 结果写入 HDFS
  ↓
结果返回给用户
```

---

## 十、源码文件索引

| 文件 | 路径 | 职责 |
|------|------|------|
| **TaskCompiler** | `ql/.../parse/TaskCompiler.java` | 物理编译器抽象基类 |
| **TezCompiler** | `ql/.../parse/TezCompiler.java` | Tez 物理编译器 |
| **MapReduceCompiler** | `ql/.../parse/MapReduceCompiler.java` | MR 物理编译器 |
| **TaskCompilerFactory** | `ql/.../parse/TaskCompilerFactory.java` | 编译器工厂 |
| **TezWork** | `ql/.../plan/TezWork.java` | Tez DAG 数据结构 |
| **MapWork** | `ql/.../plan/MapWork.java` | Map 阶段描述 |
| **ReduceWork** | `ql/.../plan/ReduceWork.java` | Reduce 阶段描述 |
| **TezTask** | `ql/.../exec/tez/TezTask.java` | Tez 任务执行 |
| **TezJobMonitor** | `ql/.../exec/tez/TezJobMonitor.java` | 执行监控 |
| **TezSessionState** | `ql/.../exec/tez/TezSessionState.java` | Session 管理 |
| **TezSessionPoolManager** | `ql/.../exec/tez/TezSessionPoolManager.java` | Session 池 |
| **PhysicalOptimizer** | `ql/.../optimizer/physical/PhysicalOptimizer.java` | 物理优化器 |
| **GenTezUtils** | `ql/.../optimizer/GenTezUtils.java` | Operator→TezWork 工具 |
