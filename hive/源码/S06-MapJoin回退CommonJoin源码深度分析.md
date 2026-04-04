# S06: Hive MapJoin 失败回退 Common Join — 源码深度分析

> **创建时间**: 2026-04-04
> **分析版本**: Apache Hive 3.x / 4.x (master branch)
> **适用引擎**: MapReduce / Tez / Spark
> **标签**: #Hive #MapJoin #CommonJoin #ConditionalTask #源码分析 #Join优化

---

## 一、全局架构：MapJoin 回退的三层防线

Hive 的 MapJoin 回退机制并非单一逻辑，而是**编译期 + 物理优化期 + 运行期**三层防线协同工作：

```
┌─────────────────────────────────────────────────────────────┐
│                   MapJoin 回退三层防线                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Layer 1: 编译期 — 逻辑优化器                                │
│  ┌─────────────────────────────────────────────────┐       │
│  │ ConvertJoinMapJoin (Tez/Spark)                   │       │
│  │ MapJoinProcessor (MR)                            │       │
│  │                                                   │       │
│  │ 根据统计信息/hint决定是否生成 MapJoin 计划          │       │
│  │ 如果不满足条件 → 保留 Common Join (不转换)          │       │
│  └─────────────────────────────────────────────────┘       │
│                         ↓                                   │
│  Layer 2: 物理优化期 — 生成条件任务 + 备份计划               │
│  ┌─────────────────────────────────────────────────┐       │
│  │ CommonJoinResolver → 为 Common Join 生成 MapJoin │       │
│  │                      候选计划                     │       │
│  │ MapJoinResolver    → 为 MapJoin 注入 LocalTask   │       │
│  │                      并挂载 BackupTask            │       │
│  │ ConditionalTask    → 封装多个候选计划              │       │
│  └─────────────────────────────────────────────────┘       │
│                         ↓                                   │
│  Layer 3: 运行期 — 动态决策与故障回退                         │
│  ┌─────────────────────────────────────────────────┐       │
│  │ ConditionalResolver → 运行时检查文件大小决策        │       │
│  │ MapredLocalTask     → 执行 HashTable 构建          │       │
│  │   如果 OOM / 内存超限 → 触发 BackupTask            │       │
│  │   BackupTask = 原始 Common Join MR 任务            │       │
│  └─────────────────────────────────────────────────┘       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、核心参数矩阵

| 参数 | 默认值 | 作用 | 与回退的关系 |
|------|--------|------|-------------|
| `hive.auto.convert.join` | `true` (0.11+) | 是否自动将 Common Join 转为 MapJoin | 总开关，关闭则不做任何转换 |
| `hive.mapjoin.smalltable.filesize` | `25000000` (25MB) | 条件任务模式下小表文件大小阈值 | 超过此值 → 条件任务选择 Common Join |
| `hive.auto.convert.join.noconditionaltask` | `true` | 是否开启无条件转换模式 | `true` = 不生成备份计划，直接 MapJoin |
| `hive.auto.convert.join.noconditionaltask.size` | `10000000` (10MB) | 无条件转换模式的小表大小阈值 | n-1张表总和 ≤ 此值 → 直接 MapJoin，无回退 |
| `hive.mapjoin.localtask.max.memory.usage` | `0.9` | Local Task 内存使用率阈值 | 超过此值 → Local Task 自行中止 → 触发回退 |
| `hive.mapjoin.followby.gby.localtask.max.memory.usage` | `0.55` | MapJoin 后跟 GroupBy 时的内存阈值 | 更保守的内存限制 |
| `hive.mapred.local.mem` | `0` (auto) | Local Task JVM 堆大小 (MB) | 控制 Local Task 可用内存 |
| `hive.mapjoin.check.memory.rows` | `100000` | 每处理多少行检查一次内存 | 控制内存检查频率 |

---

## 三、两种转换模式对比

### 3.1 条件任务模式 (`noconditionaltask = false`)

```
编译期生成:
                    ConditionalTask (根任务)
                    /        |        \
                   /         |         \
        MapJoin Plan A  MapJoin Plan B  Common Join (备份)
        (假设 T1 大表)  (假设 T2 大表)  (原始 MR Join)

运行时决策:
  ConditionalResolver 检查各表实际文件大小
  → 如果某个 MapJoin Plan 满足条件 → 执行之
  → 如果都不满足 → 回退执行 Common Join
```

**特点**:
- 生成多个候选计划（每种大表假设一个 MapJoin 计划 + 1个 Common Join 备份）
- 运行时由 `ConditionalResolver` 根据实际文件大小动态决策
- **有容错保障**：MapJoin 失败时可回退

### 3.2 无条件任务模式 (`noconditionaltask = true`)

```
编译期生成:
        MapJoin Plan (最优的一个)
        ← 不生成 Common Join 备份 →

运行时:
  直接执行 MapJoin
  → 如果 OOM → 任务失败（无自动回退）
```

**特点**:
- 只生成一个最优 MapJoin 计划
- **无备份计划**，执行更高效
- 如果判断错误（统计信息不准），可能 OOM 且无法自动回退

---

## 四、源码深度剖析

### 4.1 编译期：MapJoinProcessor（MR 引擎）

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/MapJoinProcessor.java`

**核心职责**: 将 `JoinOperator` 替换为 `MapJoinOperator`

```java
public class MapJoinProcessor implements Transform {
    
    // 入口：遍历 Operator 树，寻找可转换的 Join
    public ParseContext transform(ParseContext pCtx) throws SemanticException {
        // 使用 GenMapRedWalker 遍历 DAG
        // 规则链: CurrentMapJoin → MapJoinFS → MapJoinDefault
        // 决定哪些 MapJoin 可以直接执行（无 Reduce），哪些需要保留 Reduce
    }

    // 核心转换方法
    public MapJoinOperator convertMapJoin(..., int mapJoinPos, ...) {
        // Step 1: 检查 Outer Join 约束
        if (!noCheckOuterJoin) {
            if (checkMapJoin(mapJoinPos, condns) < 0) {
                throw new SemanticException(ErrorMsg.NO_OUTER_MAPJOIN.getMsg());
                // → 转换失败，保留 Common Join
            }
        }
        
        // Step 2: 移除父级 ReduceSinkOperator
        // 将 Join 直接连到上游算子，消除 Shuffle
        
        // Step 3: 创建 MapJoinOperator
        MapJoinOperator mapJoinOp = convertJoinOpMapJoinOp(...);
        
        // Step 4: 生成 LocalWork（小表读取和 HashTable 构建）
        genMapJoinLocalWork(newWork, mapJoinOp, bigTablePos);
        
        return mapJoinOp;
    }
    
    // 判断哪些表可以作为大表
    public static Set<Integer> getBigTableCandidates(JoinCondDesc[] condns, 
                                                      boolean isSupportFullOuter) {
        Set<Integer> candidates = new HashSet<>();
        for (JoinCondDesc cond : condns) {
            switch (cond.getType()) {
                case JoinDesc.INNER_JOIN:
                    // 内连接：任何表都可以是大表
                    candidates.add(cond.getLeft());
                    candidates.add(cond.getRight());
                    break;
                case JoinDesc.LEFT_OUTER_JOIN:
                    // 左外连接：只有左表可以是大表
                    candidates.add(cond.getLeft());
                    break;
                case JoinDesc.RIGHT_OUTER_JOIN:
                    // 右外连接：只有右表可以是大表
                    candidates.add(cond.getRight());
                    break;
                case JoinDesc.FULL_OUTER_JOIN:
                    // Full Outer Join：需要特殊支持
                    if (!isSupportFullOuter) {
                        return new HashSet<>(); // 不支持 → 无候选 → 不转换
                    }
                    break;
            }
        }
        return candidates;
    }
    
    // 生成 Local Work —— 小表加载和 HashTable 构建
    private static void genMapJoinLocalWork(MapredWork newWork, 
                                             MapJoinOperator mapJoinOp,
                                             int bigTablePos) {
        MapredLocalWork newLocalWork = new MapredLocalWork();
        
        for (Map.Entry<String, Operator<?>> entry : aliasToWork.entrySet()) {
            if (i == bigTablePos) {
                continue;  // 跳过大表
            }
            // 小表 → 加入 LocalWork
            newLocalWork.getAliasToWork().put(alias, op);
            
            // 创建 FetchWork 读取小表数据
            FetchWork fetchWork = new FetchWork(tableScan.getConf().getTableMetadata(), ...);
            newLocalWork.getAliasToFetchWork().put(alias, fetchWork);
        }
        
        newWork.getMapWork().setMapRedLocalWork(newLocalWork);
    }
}
```

**关键点**:
1. `checkMapJoin()` — 语义检查，确保 Outer Join 的大表位置合法
2. `getBigTableCandidates()` — 计算可作为大表的候选位置
3. `genMapJoinLocalWork()` — 生成小表的本地读取任务
4. 如果检查失败 → 抛异常 → 不转换 → **编译期回退到 Common Join**

### 4.2 编译期：ConvertJoinMapJoin（Tez/Spark 引擎）

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/ConvertJoinMapJoin.java`

**核心职责**: 在 Tez/Spark DAG 优化阶段，根据统计信息将 Join 转为 MapJoin

```java
public class ConvertJoinMapJoin implements SemanticNodeProcessor {
    
    // 核心处理方法
    public Object process(Node nd, Stack<Node> stack, ...) {
        JoinOperator joinOp = (JoinOperator) nd;
        
        // Step 1: 获取表统计信息
        // 通过 Metastore 统计或运行时采集获取各输入表大小
        
        // Step 2: 无条件任务模式判断
        if (conf.getBoolVar(HiveConf.ConfVars.HIVECONVERTJOINNOCONDITIONALTASK)) {
            long threshold = conf.getLongVar(
                HiveConf.ConfVars.HIVECONVERTJOINNOCONDITIONALTASKTHRESHOLD);
            
            // 计算 n-1 张小表的总大小
            long smallTablesTotalSize = calculateSmallTablesSize(...);
            
            if (smallTablesTotalSize <= threshold) {
                // 满足条件 → 直接转为 MapJoin，不生成备份计划
                convertToMapJoin(joinOp, bigTablePos);
                return null;
            }
        }
        
        // Step 3: 条件任务模式判断
        if (conf.getBoolVar(HiveConf.ConfVars.HIVECONVERTJOIN)) {
            long threshold = conf.getLongVar(
                HiveConf.ConfVars.HIVESMALLTABLESFILESIZE);
            
            // 为每种可能的大表位置生成候选 MapJoin 计划
            // 保留 Common Join 作为备份
            // 封装到 ConditionalTask 中
        }
    }
    
    // MapJoin 转换的核心判断
    enum MapJoinConversion {
        NONE,              // 不转换
        FULL_OUTER,        // Full Outer Join 特殊处理
        CONVERT_JOIN       // 可以转换
    }
}
```

**关键决策流程**:
```
ConvertJoinMapJoin.process()
  ├── 检查 noconditionaltask = true?
  │     ├── YES: 计算小表总和 ≤ noconditionaltask.size?
  │     │     ├── YES → 直接转 MapJoin（无备份）
  │     │     └── NO  → 继续下一步
  │     └── NO: 继续下一步
  ├── 检查 auto.convert.join = true?
  │     ├── YES: 小表大小 ≤ smalltable.filesize?
  │     │     ├── YES → 生成 ConditionalTask（含备份计划）
  │     │     └── NO  → 保留 Common Join
  │     └── NO: 保留 Common Join
  └── 都不满足 → 保留 Common Join
```

### 4.3 物理优化期：CommonJoinResolver

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/CommonJoinResolver.java`

**核心职责**: 遍历物理计划中的 Common Join 任务，为其生成 MapJoin 替代方案，并封装到 `ConditionalTask` 中

```java
public class CommonJoinResolver implements PhysicalPlanResolver {

    public PhysicalContext resolve(PhysicalContext pctx) {
        // 遍历所有 MapReduce 任务
        for (Task<?> task : rootTasks) {
            if (task instanceof MapRedTask) {
                // 检查是否包含 Join 操作
                // 如果包含 → 尝试生成 MapJoin 替代计划
                processCurrentTask(task, ...);
            }
        }
    }
    
    private void processCurrentTask(Task<?> currTask, ...) {
        // Step 1: 提取 Join 信息
        MapredWork work = (MapredWork) currTask.getWork();
        
        // Step 2: 为每个可能的大表位置生成 MapJoin 计划
        List<Task<?>> mapJoinTasks = new ArrayList<>();
        for (int pos : bigTableCandidates) {
            Task<?> mapJoinTask = createMapJoinTask(work, pos);
            if (mapJoinTask != null) {
                mapJoinTasks.add(mapJoinTask);
            }
        }
        
        // Step 3: 创建 ConditionalTask
        if (!mapJoinTasks.isEmpty()) {
            // 候选列表 = MapJoin Plan A + MapJoin Plan B + ... + Common Join (原任务)
            List<Task<?>> allTasks = new ArrayList<>(mapJoinTasks);
            allTasks.add(currTask);  // Common Join 作为备份
            
            ConditionalTask conditionalTask = new ConditionalTask();
            conditionalTask.setListTasks(allTasks);
            
            // 设置 ConditionalResolver —— 运行时决策器
            conditionalTask.setResolver(new ConditionalResolverCommonJoin());
            conditionalTask.setResolverCtx(new ConditionalResolverCommonJoinCtx(
                aliasToPath, // 各表的 HDFS 路径 → 运行时读取文件大小
                threshold    // 小表大小阈值
            ));
            
            // 替换原任务
            replaceTask(currTask, conditionalTask);
        }
    }
}
```

**核心逻辑**:
1. 找到所有 Common Join 的 MR 任务
2. 为每种"大表假设"生成一个 MapJoin 候选方案
3. 将所有候选 + 原始 Common Join 封装到 `ConditionalTask`
4. 绑定 `ConditionalResolverCommonJoin` 用于运行时决策

### 4.4 物理优化期：MapJoinResolver

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/optimizer/physical/MapJoinResolver.java`

**核心职责**: 为已确定的 MapJoin 任务注入 `LocalTask`（HashTable 构建任务）并挂载备份任务

```java
public class MapJoinResolver implements PhysicalPlanResolver {
    
    // 内部调度器：遍历任务树
    class LocalMapJoinTaskDispatcher implements Dispatcher {
        
        public Object dispatch(Node nd, ...) {
            Task<?> currTask = (Task<?>) nd;
            MapredWork work = (MapredWork) currTask.getWork();
            
            // 检查是否存在 LocalWork（即 MapJoin 需要的小表加载）
            MapredLocalWork localWork = work.getMapWork().getMapRedLocalWork();
            if (localWork == null) {
                return null;  // 不是 MapJoin 任务
            }
            
            return processCurrentTask(currTask, localWork);
        }
    }
    
    private Object processCurrentTask(Task<?> currTask, MapredLocalWork localWork) {
        
        // ★ Step 1: 创建 LocalTask（HashTable 构建任务）
        MapredLocalTask localTask = (MapredLocalTask) TaskFactory.get(localWork);
        
        // ★ Step 2: 重构任务依赖关系
        // 原来: ParentTask → currTask (MapJoin MR)
        // 改为: ParentTask → localTask (HashTable构建) → currTask (MapJoin MR)
        
        for (Task<?> parentTask : currTask.getParentTasks()) {
            parentTask.addDependentTask(localTask);
            parentTask.removeDependentTask(currTask);
        }
        localTask.addDependentTask(currTask);
        
        // ★ Step 3: 核心——转移备份任务到 LocalTask
        // 备份任务 = 原始 Common Join MR 任务
        // 如果 LocalTask(HashTable构建) 失败 → 执行 BackupTask(Common Join)
        localTask.setBackupTask(currTask.getBackupTask());
        localTask.setBackupChildrenTasks(currTask.getBackupChildrenTasks());
        
        // 清除原任务的备份信息（已转移到 LocalTask）
        currTask.setBackupTask(null);
        currTask.setBackupChildrenTasks(null);
        
        // ★ Step 4: 设置任务标签
        if (currTask.getTaskTag() == Task.CONVERTED_MAPJOIN) {
            localTask.setTaskTag(Task.CONVERTED_MAPJOIN_LOCAL);
        } else if (currTask.getTaskTag() == Task.HINTED_MAPJOIN) {
            localTask.setTaskTag(Task.HINTED_MAPJOIN_LOCAL);
        }
        
        // Step 5: 处理条件任务上下文（如果在 ConditionalTask 内）
        // 更新 ConditionalResolver 中的任务映射
        
        return null;
    }
}
```

**执行流程图**:
```
优化前:
  ConditionalTask
    ├── MapJoin MR Task (contains LocalWork + BackupTask)
    └── Common Join MR Task (备份)

优化后（MapJoinResolver 处理后）:
  ConditionalTask
    ├── LocalTask (HashTable 构建)  ← 持有 BackupTask
    │     ├── 成功 → MapJoin MR Task
    │     └── 失败(OOM) → BackupTask → Common Join MR Task
    └── Common Join MR Task (备份)
```

### 4.5 运行期：ConditionalTask

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/ConditionalTask.java`

**核心职责**: 运行时封装多个候选任务，委托 `ConditionalResolver` 做出动态决策

```java
public class ConditionalTask extends Task<ConditionalWork> {
    
    private List<Task<?>> listTasks;         // 所有候选任务
    private ConditionalResolver resolver;     // 决策器
    private Object resolverCtx;              // 决策上下文
    
    @Override
    public int execute() {
        // ★ 核心：调用 Resolver 获取应执行的任务列表
        resTasks = resolver.getTasks(conf, resolverCtx);
        // resTasks 可能是 [MapJoin Task] 或 [Common Join Task]
        
        resolved = true;
        
        // 锁定后调用 resolveTask 进行任务图修改
        resolverLock.lock();
        try {
            resolveTask(driverContext);
        } finally {
            resolverLock.unlock();
        }
        
        return 0;
    }
    
    private void resolveTask(DriverContext driverContext) {
        for (Task<?> task : listTasks) {
            if (resTasks.contains(task)) {
                // ★ 选中的任务：加入执行队列
                console.printInfo(task.getId() + " is selected by condition resolver.");
                taskQueue.addToRunnable(task);
                // 重建与子任务的依赖关系
            } else {
                // ★ 未选中的任务：从任务图中移除
                console.printInfo(task.getId() + " is filtered out by condition resolver.");
                taskQueue.remove(task);
                // 移除与子任务的依赖关系
            }
        }
    }
}
```

**运行时日志示例**:
```
INFO  : Stage-4 is a root stage, consists of Stage-5, Stage-1
INFO  : Stage-5 has a backup stage: Stage-1
INFO  : Stage-5 is selected by condition resolver.
           ← MapJoin 被选中
或
INFO  : Stage-1 is selected by condition resolver.
           ← Common Join 被选中（MapJoin 条件不满足）
```

### 4.6 运行期：ConditionalResolverCommonJoin

**核心职责**: 在运行时读取输入文件的实际大小，决定执行 MapJoin 还是 Common Join

```java
public class ConditionalResolverCommonJoin implements ConditionalResolver {
    
    @Override
    public List<Task<?>> getTasks(HiveConf conf, Object ctx) {
        ConditionalResolverCommonJoinCtx context = 
            (ConditionalResolverCommonJoinCtx) ctx;
        
        // ★ 核心逻辑：读取各表输入文件的实际大小
        Map<String, Long> aliasToSize = new HashMap<>();
        for (Map.Entry<String, List<String>> entry : aliasToPath.entrySet()) {
            long totalSize = 0;
            for (String path : entry.getValue()) {
                // 从 HDFS 获取文件实际大小
                totalSize += getFileSize(path, conf);
            }
            aliasToSize.put(entry.getKey(), totalSize);
        }
        
        long threshold = conf.getLongVar(
            HiveConf.ConfVars.HIVESMALLTABLESFILESIZE); // 默认 25MB
        
        // ★ 遍历每个 MapJoin 候选计划
        for (MapJoinCandidate candidate : candidates) {
            long smallTablesTotal = 0;
            for (String alias : candidate.getSmallTableAliases()) {
                smallTablesTotal += aliasToSize.get(alias);
            }
            
            if (smallTablesTotal <= threshold) {
                // 找到满足条件的 MapJoin 计划 → 返回之
                return Collections.singletonList(candidate.getMapJoinTask());
            }
        }
        
        // ★ 所有 MapJoin 候选都不满足条件 → 回退到 Common Join
        return Collections.singletonList(commonJoinTask);
    }
}
```

### 4.7 运行期：MapredLocalTask（HashTable 构建与 OOM 回退）

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/mr/MapredLocalTask.java`

**核心职责**: 在客户端本地执行小表读取和 HashTable 构建

```java
public class MapredLocalTask extends Task<MapredLocalWork> {
    
    // 两种执行模式
    @Override
    public int executeTask() {
        if (conf.getBoolVar(HiveConf.ConfVars.SUBMIT_LOCAL_TASK_VIA_CHILD)) {
            return executeInChildVM();  // 推荐：子 JVM 隔离执行
        } else {
            return executeInProcess();  // 进程内执行
        }
    }
    
    // ★ 进程内执行（关键的 OOM 捕获逻辑）
    private int executeInProcess() {
        int retVal = 0;
        try {
            MemoryMXBean memoryMXBean = ManagementFactory.getMemoryMXBean();
            console.printInfo("Maximum memory = " + 
                memoryMXBean.getHeapMemoryUsage().getMax());
            
            // 初始化 Fetch Operators
            initializeOperators();
            
            // ★ 核心循环：逐行读取小表数据，构建 HashTable
            startForward(inputFileChangeSensitive);
            // 在此过程中：
            //   - HashTableSinkOperator 将数据写入内存 HashTable
            //   - 如果内存使用率超过 hive.mapjoin.localtask.max.memory.usage
            //   - HashTableSinkOperator 会抛出 MapJoinMemoryExhaustionError
            
        } catch (Throwable throwable) {
            // ★ OOM / 内存超限捕获
            if (throwable instanceof OutOfMemoryError 
                || throwable instanceof MapJoinMemoryExhaustionError) {
                
                message = "Hive Runtime Error: Map local work exhausted memory";
                retVal = 3;  // 特殊错误码 3 = 内存耗尽
                
                LOG.error("MapJoin local task exhausted memory. " +
                    "Table too large to hold in memory.");
            } else {
                retVal = 2;  // 其他错误
            }
        }
        
        return retVal;  // 返回给上层调度器
    }
    
    // ★ 子 JVM 执行模式
    private int executeInChildVM() {
        // 构造子进程命令行
        String childJavaOpts = getChildJavaOpts();
        
        // 序列化执行计划到本地文件
        serializePlan(work, planFileName);
        
        // 设置 JVM 堆大小
        // HADOOP_HEAPSIZE = hive.mapred.local.mem
        
        // 启动子进程
        Process executor = Runtime.getRuntime().exec(cmdLine);
        int exitVal = executor.waitFor();
        
        // exitVal == 0: 成功
        // exitVal == 3: OOM → 触发回退
        // exitVal != 0: 其他错误
        return exitVal;
    }
}
```

**OOM 回退的上层调度逻辑**（在 `Task.java` / `DriverContext` 中）:

```java
// 伪代码：上层调度器处理 LocalTask 失败
if (localTask.execute() != 0) {
    // LocalTask 失败
    if (localTask.getBackupTask() != null) {
        // ★ 存在备份任务 → 执行回退
        LOG.info("Local task failed, falling back to backup task: " + 
            localTask.getBackupTask().getId());
        
        // 清理失败的 HashTable 文件
        cleanupHashTableFiles();
        
        // 执行 BackupTask = Common Join MR 任务
        return executeBackupTask(localTask.getBackupTask());
    } else {
        // 无备份 → 任务直接失败
        throw new HiveException("MapJoin local task failed with no backup");
    }
}
```

---

## 五、回退触发的 7 种场景

### 场景 1：编译期 — 统计信息判断不适合 MapJoin
```
条件: 表的统计大小 > hive.mapjoin.smalltable.filesize (25MB)
行为: 编译器不生成 MapJoin 计划，保留 Common Join
阶段: 编译期 (ConvertJoinMapJoin / MapJoinProcessor)
```

### 场景 2：编译期 — Join 类型不支持
```
条件: Full Outer Join 且不支持 Full Outer MapJoin
      (需要 MapJoinProcessor.checkFullOuterMapJoinCompatible() 返回 true)
行为: getBigTableCandidates() 返回空集 → 不转换
阶段: 编译期
```

### 场景 3：运行时 — ConditionalResolver 文件大小检查
```
条件: 运行时读取 HDFS 文件实际大小 > threshold
行为: ConditionalTask 选择 Common Join 任务
阶段: 运行期 (ConditionalResolverCommonJoin.getTasks())
日志: "Stage-1 is selected by condition resolver."
```

### 场景 4：运行时 — LocalTask 内存使用率超限
```
条件: HashTable 构建过程中内存使用率 > hive.mapjoin.localtask.max.memory.usage (0.9)
行为: HashTableSinkOperator 抛出 MapJoinMemoryExhaustionError
      LocalTask 返回错误码 3 → 上层触发 BackupTask
阶段: 运行期 (MapredLocalTask.executeInProcess())
日志: "Hive Runtime Error: Map local work exhausted memory"
```

### 场景 5：运行时 — LocalTask OOM
```
条件: 小表数据过大，直接 JVM OOM
行为: 捕获 OutOfMemoryError → 错误码 3 → BackupTask
阶段: 运行期
日志: "java.lang.OutOfMemoryError: Java heap space"
```

### 场景 6：运行时 — LocalTask 子进程 OOM
```
条件: executeInChildVM() 模式下子 JVM OOM
行为: 子进程 exitVal = 3 → 父进程触发 BackupTask
阶段: 运行期
特点: 不影响 HiveServer2 主进程（推荐模式）
```

### 场景 7：编译期 — noconditionaltask 模式下的"隐式不回退"
```
条件: noconditionaltask = true 且 noconditionaltask.size 设置过大
      实际运行时小表远超预期
行为: 无备份计划 → 直接 OOM 失败 → 任务报错
阶段: 运行期
风险: ★ 高风险场景，需要统计信息准确
```

---

## 六、执行计划分析（EXPLAIN 解读）

### 6.1 条件任务模式的执行计划

```sql
SET hive.auto.convert.join = true;
SET hive.auto.convert.join.noconditionaltask = false;

EXPLAIN
SELECT * FROM large_table a JOIN small_table b ON a.key = b.key;
```

```
STAGE DEPENDENCIES:
  Stage-4 is a root stage                    ← ConditionalTask (根)
  Stage-5 depends on stages: Stage-4         ← LocalTask (HashTable)
  Stage-3 depends on stages: Stage-5         ← MapJoin MR Task
  Stage-1 depends on stages: Stage-4         ← Common Join MR Task (备份)

STAGE PLANS:
  Stage: Stage-4                             ← ConditionalTask
    Conditional Operator
      list of tasks:
        Stage-5                               ← MapJoin 路径的入口
        Stage-1                               ← Common Join 备份

  Stage: Stage-5                             ← LocalTask
    Map Reduce Local Work
      Alias -> Map Local Tables:
        b                                     ← 小表 b 被加载到内存
          Fetch Operator                      ← 从 HDFS 读取小表
      Alias -> Map Local Operator Tree:
        b
          TableScan → HashTable Sink Operator  ← 构建 HashTable
    ★ backup stage: Stage-1                    ← 备份任务

  Stage: Stage-3                             ← MapJoin MR (只有 Map，无 Reduce)
    Map Reduce
      Map Operator Tree:
        TableScan (large_table)
          Map Join Operator                   ← Map 端 Join
            keys: a.key = b.key
            outputColumnNames: ...
            Select Operator
              File Output Operator

  Stage: Stage-1                             ← Common Join MR (备份)
    Map Reduce
      Map Operator Tree:
        TableScan (large_table)
          Reduce Output Operator              ← Shuffle
        TableScan (small_table)
          Reduce Output Operator              ← Shuffle
      Reduce Operator Tree:
        Join Operator                         ← Reduce 端 Join
          Select Operator
            File Output Operator
```

**关键标识**:
- `Stage-4: Conditional Operator` — 运行时条件任务
- `Stage-5: backup stage: Stage-1` — LocalTask 持有备份任务
- `Stage-3: Map Join Operator` — 纯 Map 任务（无 Reduce）
- `Stage-1: Join Operator` — 传统 Shuffle + Reduce Join

### 6.2 无条件任务模式的执行计划

```sql
SET hive.auto.convert.join = true;
SET hive.auto.convert.join.noconditionaltask = true;
SET hive.auto.convert.join.noconditionaltask.size = 10000000;

EXPLAIN
SELECT * FROM large_table a JOIN small_table b ON a.key = b.key;
```

```
STAGE DEPENDENCIES:
  Stage-5 is a root stage                    ← 直接 LocalTask
  Stage-3 depends on stages: Stage-5         ← MapJoin MR Task

STAGE PLANS:
  Stage: Stage-5                             ← LocalTask (无备份)
    Map Reduce Local Work
      Alias -> Map Local Tables: b
      ← ★ 注意：没有 backup stage

  Stage: Stage-3                             ← MapJoin MR
    Map Reduce
      Map Operator Tree:
        TableScan (large_table)
          Map Join Operator
            ...
```

**关键区别**: 没有 `Conditional Operator`，没有 `backup stage`。

---

## 七、Tez 引擎的差异

### 7.1 Tez 下的 MapJoin 实现差异

Tez 引擎下 MapJoin 的实现与 MR 引擎有显著差异：

| 特性 | MR 引擎 | Tez 引擎 |
|------|---------|----------|
| 小表加载方式 | LocalTask 在客户端构建 HashTable → Distributed Cache | 小表作为 broadcast edge 直接广播到 Map 顶点 |
| 回退机制 | LocalTask 失败 → BackupTask | 编译期由 ConvertJoinMapJoin 决策，运行时 Tez AM 不自动回退 |
| 条件任务 | CommonJoinResolver 生成 ConditionalTask | Tez DAG 优化直接选择最优计划 |
| 内存管理 | JVM 堆内存（`hive.mapred.local.mem`） | Tez Container 内存（`hive.tez.container.size`） |

### 7.2 Tez 下的回退策略

在 Tez 引擎中，MapJoin 回退主要发生在**编译期**：

```java
// ConvertJoinMapJoin.java — Tez 优化路径
// 在 Tez DAG 构建阶段决定 Join 策略
// 不像 MR 那样有运行时 ConditionalTask 动态回退

// Tez 下的回退方式:
// 1. 编译期: 统计信息不满足 → 不转换 → 保留 Common Join
// 2. 运行期: Tez runtime OOM → 任务失败 → 需要手动重跑
//    (Tez 没有 MR 那种 BackupTask 自动回退机制)
```

**Tez 下的应对策略**:
- 确保 `hive.tez.container.size` 足够大
- 确保统计信息准确（`ANALYZE TABLE ... COMPUTE STATISTICS`）
- 使用 `noconditionaltask.size` 保守设置
- 开启 AQE 自适应查询（Hive 3.x+ / Tez）

---

## 八、HashTableSinkOperator 内存检查机制

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/exec/HashTableSinkOperator.java`

```java
public class HashTableSinkOperator extends TerminalOperator<HashTableSinkDesc> {
    
    private float memoryThreshold;  // hive.mapjoin.localtask.max.memory.usage
    private int rowsProcessed = 0;
    private int checkInterval;      // hive.mapjoin.check.memory.rows
    
    @Override
    protected void initializeOp(Configuration hconf) {
        memoryThreshold = conf.getFloatVar(
            HiveConf.ConfVars.HIVEHASHTABLEKEYCOUNTADJUSTMENT);
        checkInterval = conf.getIntVar(
            HiveConf.ConfVars.HIVEMAPJOINCHECKBUCKETROWS);
    }
    
    @Override
    public void process(Object row, int tag) throws HiveException {
        // 将 row 写入 HashTable
        hashTable.put(key, value);
        
        rowsProcessed++;
        
        // ★ 每 N 行检查一次内存
        if (rowsProcessed % checkInterval == 0) {
            checkMemoryUsage();
        }
    }
    
    private void checkMemoryUsage() throws MapJoinMemoryExhaustionError {
        MemoryMXBean memoryMXBean = ManagementFactory.getMemoryMXBean();
        long usedMemory = memoryMXBean.getHeapMemoryUsage().getUsed();
        long maxMemory = memoryMXBean.getHeapMemoryUsage().getMax();
        
        float usage = (float) usedMemory / maxMemory;
        
        if (usage > memoryThreshold) {
            // ★ 内存超限 → 抛出自定义错误 → 触发回退
            String msg = String.format(
                "Memory usage %.2f exceeded threshold %.2f. " +
                "Used: %d, Max: %d, Rows processed: %d",
                usage, memoryThreshold, usedMemory, maxMemory, rowsProcessed);
            
            LOG.error(msg);
            throw new MapJoinMemoryExhaustionError(msg);
            // 此异常被 MapredLocalTask.executeInProcess() 捕获
            // → 返回错误码 3
            // → 上层调度器触发 BackupTask
        }
    }
}
```

**MapJoinMemoryExhaustionError** 是 Hive 自定义的 Error（不是 Exception），继承自 `Error`，与 `OutOfMemoryError` 同级处理：

```java
public class MapJoinMemoryExhaustionError extends Error {
    public MapJoinMemoryExhaustionError(String message) {
        super(message);
    }
}
```

---

## 九、完整回退调用链

```
SQL 提交
  ↓
编译期 (SemanticAnalyzer)
  ↓ hive.auto.convert.join = true?
  ├── NO → Common Join, 不做任何转换
  └── YES → 进入优化
        ↓ noconditionaltask = true?
        ├── YES → 小表总和 ≤ noconditionaltask.size?
        │     ├── YES → 直接 MapJoin（无备份计划）
        │     └── NO  → 保留 Common Join
        └── NO → 小表大小 ≤ smalltable.filesize?
              ├── YES → 生成 ConditionalTask
              └── NO  → 保留 Common Join
  ↓
物理优化期 (PhysicalOptimizer)
  ↓ CommonJoinResolver
  │  为 Common Join 生成 MapJoin 候选 → ConditionalTask
  ↓ MapJoinResolver
  │  为 MapJoin 注入 LocalTask + 挂载 BackupTask
  ↓
运行期 (Driver.execute())
  ↓ ConditionalTask.execute()
  │  ConditionalResolver.getTasks()
  │  读取文件实际大小 → 选择执行计划
  ├── 选择 MapJoin
  │     ↓ LocalTask.execute()
  │     │  构建 HashTable
  │     ├── 成功 → MapJoin MR Task 执行 → 完成 ✓
  │     └── 失败 (OOM/内存超限)
  │           ↓ 错误码 3
  │           ↓ 检查 BackupTask 是否存在
  │           ├── 存在 → 执行 Common Join MR Task → 完成 ✓
  │           └── 不存在 → 任务失败 ✗
  └── 选择 Common Join
        ↓ Common Join MR Task 执行 → 完成 ✓
```

---

## 十、运维排障指南

### 10.1 判断是否发生了回退

**日志关键词**:
```bash
# 条件任务选择了 Common Join（文件大小不满足）
grep "is selected by condition resolver" hive-server2.log
grep "is filtered out by condition resolver" hive-server2.log

# LocalTask OOM 回退
grep "Map local work exhausted memory" hive-server2.log
grep "MapJoinMemoryExhaustionError" hive-server2.log
grep "OutOfMemoryError" hive-server2.log

# 备份任务被执行
grep "backup" hive-server2.log | grep -i "stage\|task"
```

### 10.2 常见回退原因与解决方案

| 回退原因 | 日志特征 | 解决方案 |
|----------|----------|----------|
| 统计信息不准 | ConditionalResolver 频繁选择 Common Join | `ANALYZE TABLE t COMPUTE STATISTICS FOR COLUMNS` |
| 小表实际过大 | "exhausted memory" | 增大 `hive.mapjoin.smalltable.filesize` 或用 Common Join |
| LocalTask OOM | "OutOfMemoryError" | 增大 `hive.mapred.local.mem`，或降低 `localtask.max.memory.usage` |
| 压缩数据膨胀 | LocalTask 解压后 OOM | 压缩文件的统计大小 ≠ 实际内存占用，保守设置阈值 |
| noconditionaltask 误判 | 无回退直接失败 | 减小 `noconditionaltask.size` 或关闭 noconditionaltask |

### 10.3 参数调优建议

```sql
-- 1. 确保统计信息准确（最重要！）
ANALYZE TABLE my_table COMPUTE STATISTICS;
ANALYZE TABLE my_table COMPUTE STATISTICS FOR COLUMNS;

-- 2. 保守设置（线上推荐）
SET hive.auto.convert.join = true;
SET hive.auto.convert.join.noconditionaltask = true;
SET hive.auto.convert.join.noconditionaltask.size = 10000000;  -- 10MB
SET hive.mapjoin.smalltable.filesize = 25000000;               -- 25MB
SET hive.mapjoin.localtask.max.memory.usage = 0.9;

-- 3. 如果频繁 OOM 回退
SET hive.mapred.local.mem = 1024;  -- 给 LocalTask 1GB 堆内存
SET hive.mapjoin.localtask.max.memory.usage = 0.999;  -- 放宽内存限制

-- 4. 完全关闭 MapJoin（兜底方案）
SET hive.auto.convert.join = false;
```

---

## 十一、源码文件索引

| 文件 | 路径 | 职责 |
|------|------|------|
| **MapJoinProcessor** | `ql/.../optimizer/MapJoinProcessor.java` | 编译期：将 JoinOp 转为 MapJoinOp |
| **ConvertJoinMapJoin** | `ql/.../optimizer/ConvertJoinMapJoin.java` | 编译期(Tez/Spark)：基于统计信息决策 |
| **CommonJoinResolver** | `ql/.../optimizer/physical/CommonJoinResolver.java` | 物理优化：为 CommonJoin 生成 MapJoin 候选 |
| **MapJoinResolver** | `ql/.../optimizer/physical/MapJoinResolver.java` | 物理优化：注入 LocalTask + 挂载 BackupTask |
| **ConditionalTask** | `ql/.../exec/ConditionalTask.java` | 运行期：封装候选计划，委托 Resolver 决策 |
| **ConditionalResolverCommonJoin** | `ql/.../exec/ConditionalResolverCommonJoin.java` | 运行期：检查文件大小，选择执行计划 |
| **MapredLocalTask** | `ql/.../exec/mr/MapredLocalTask.java` | 运行期：执行 HashTable 构建，捕获 OOM |
| **HashTableSinkOperator** | `ql/.../exec/HashTableSinkOperator.java` | 运行期：内存使用率周期检查 |
| **MapJoinMemoryExhaustionError** | `ql/.../exec/MapJoinMemoryExhaustionError.java` | 自定义 Error：内存超限信号 |

---

## 十二、认知总结

### 核心设计思想
1. **编译期乐观 + 运行期兜底**: 编译期尽量生成 MapJoin 计划提升性能，运行期通过 ConditionalTask + BackupTask 确保容错
2. **渐进式防线**: 统计信息检查 → 文件大小检查 → 内存使用率检查 → OOM 捕获，层层递进
3. **透明回退**: 用户无感知，MapJoin 失败自动切换到 Common Join

### 区分"会用"和"精通"的关键
- **会用**: 知道 `hive.auto.convert.join` 开启 MapJoin
- **精通**: 理解 ConditionalTask 的运行时决策机制、LocalTask 的 OOM 捕获与 BackupTask 回退链路、noconditionaltask 模式的风险

### 实战价值
- 排查 MapJoin 性能不稳定：检查是否频繁回退
- 排查 OOM：区分 LocalTask OOM（可回退）vs noconditionaltask OOM（不可回退）
- 参数调优：根据业务场景选择条件任务 vs 无条件任务模式
