# Tez + Hive 分片计算全流程源码解析

> 基于 **Hive 3.1.3** + **Tez 0.10.2** 源码  
> 关联日志：`application_1776354878574_0006`，查询 `select count(1), sum(ss_ext_tax) ... from store_sales`

---

## 一、全景调用链

```
                            DAG 提交（HiveServer2）
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    DAGAppMaster（AM Container）                      │
│                                                                     │
│  1. DAGAppMaster.submitDAGToAppMaster()                             │
│     └─> DAGImpl.handle(DAG_INIT)                                    │
│         └─> VertexImpl.handle(V_INIT)                               │
│             └─> RootInputInitializerManager.runInputInitializers()   │
│                 └─> HiveSplitGenerator.initialize()    ← 入口       │
│                                                                     │
│  2. HiveSplitGenerator.initialize()                                 │
│     ├─ 2a. inputFormat.getSplits(jobConf, availableSlots*waves)      │
│     │       → 240 个原始 splits                                      │
│     ├─ 2b. Arrays.sort(splits, new InputSplitComparator())           │
│     │       排序：大小降序→路径→偏移量                                │
│     ├─ 2c. splitGrouper.generateGroupedSplits(6参)                   │
│     │   └─ generateGroupedSplits(8参) ← 补 inputName=null,          │
│     │       │                            groupAcrossFiles=true       │
│     │       ├─ schemaEvolved() → 按 schema 边界分桶                  │
│     │       └─ group(conf, bucketSplitMultiMap, availableSlots,      │
│     │            │    waves, locationProvider)                        │
│     │            ├─ estimateBucketSizes() → 按数据量比例分配 task 数  │
│     │            └─ tezGrouper.getGroupedSplits()                    │
│     │                 tezGrouper 类型 = TezMapredSplitsGrouper       │
│     │                 （TezSplitGrouper 的子类）                      │
│     │                 参数含 ColumnarSplitSizeEstimator              │
│     │                 → 80 grouped splits                            │
│     └─ 2d. createEventList() → 构建 InputDataInformationEvent       │
│                                                                     │
│  3. VertexImpl 接收事件                                              │
│     └─> setParallelism(80) → Map 1 启动 80 个 task                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 二、阶段一：AM 启动与 DAG 初始化

### 2.1 DAGAppMaster 创建

**源码位置**：`tez-dag/src/main/java/org/apache/tez/dag/app/DAGAppMaster.java`

```java
// DAGAppMaster.java — main 方法
public static void main(String[] args) {
    // ...
    DAGAppMaster appMaster = new DAGAppMaster(
        applicationAttemptId, containerId, nmHost, nmPort, nmHttpPort,
        new SystemClock(), appSubmitTime, isSession,
        userDir, currentUser.getShortUserName(), ...);
    // ...
    appMaster.init(conf);
    appMaster.start();
}
```

日志对应：
```
Creating DAGAppMaster for applicationId=application_1776354878574_0006, attemptNum=1
```

### 2.2 DAG 提交（通过 RPC）

**源码位置**：`DAGAppMaster.java#submitDAGToAppMaster()`

```java
// DAGAppMaster.java
public synchronized DAGClient submitDAGToAppMaster(DAGPlan dagPlan,
    Map<String, LocalResource> additionalAmResources) throws ... {
    // ...
    LOG.info("Starting DAG submitted via RPC: " + dagPlan.getName());
    // 合并凭证
    LOG.info("Merging AM credentials into DAG credentials");
    // 创建 DAG 实例
    dag = createDAG(dagPlan, ...);
    // 触发 DAG_INIT 事件
    sendEvent(new DAGEvent(dag.getID(), DAGEventType.DAG_INIT));
    // 触发 DAG_START 事件
    sendEvent(new DAGEventSchedulerUpdate(
        DAGEventSchedulerUpdate.UpdateType.DAG_COMPLETED, dag));
}
```

日志对应：
```
Starting DAG submitted via RPC: select count(1),sum(ss_ext...ss_sold_date_sk (Stage-1)
Merging AM credentials into DAG credentials
```

### 2.3 DAG 状态机：INIT → RUNNING

**源码位置**：`tez-dag/src/main/java/org/apache/tez/dag/app/dag/impl/DAGImpl.java`

```java
// DAGImpl.java — 状态转换表
.addTransition(DAGState.NEW, DAGState.INITED,
    DAGEventType.DAG_INIT, new InitTransition())
.addTransition(DAGState.INITED, DAGState.RUNNING,
    DAGEventType.DAG_START, new StartTransition())

// InitTransition — 初始化所有 Vertex
static class InitTransition implements MultipleArcTransition<...> {
    public DAGState transition(DAGImpl dag, DAGEvent event) {
        // 对每个 Vertex 发送 V_INIT 事件
        for (Vertex v : dag.vertices.values()) {
            if (v.getInputVerticesCount() == 0) {
                // 根 Vertex（Map 1）立即初始化
                dag.eventHandler.handle(
                    new VertexEvent(v.getVertexId(), VertexEventType.V_INIT));
            }
        }
    }
}
```

日志对应：
```
dag_1776354878574_0006_1 transitioned from NEW to INITED due to event DAG_INIT
dag_1776354878574_0006_1 transitioned from INITED to RUNNING due to event DAG_START
```

---

## 三、阶段二：Vertex 初始化 → InputInitializer 启动

### 3.1 VertexImpl 处理 V_INIT

**源码位置**：`tez-dag/src/main/java/org/apache/tez/dag/app/dag/impl/VertexImpl.java`

```java
// VertexImpl.java — InitTransition
static class InitTransition implements MultipleArcTransition<...> {
    public VertexState transition(VertexImpl vertex, VertexEvent event) {
        // ...
        // 检查是否有 Root Input（Map 1 有 store_sales 输入）
        if (vertex.sourceVertices.isEmpty()) {
            // 这是根 Vertex
            if (vertex.rootInputDescriptors != null
                && !vertex.rootInputDescriptors.isEmpty()) {
                // 存在 Root Input → 启动 InputInitializer
                LOG.info("Root Inputs exist for Vertex: " + vertex.getName()
                    + " : " + vertex.rootInputDescriptors);

                // 设置 VertexManager 为 RootInputVertexManager
                LOG.info("Setting vertexManager to RootInputVertexManager for "
                    + vertex.logIdentifier);

                // 启动 InputInitializer
                vertex.rootInputInitializerManager.runInputInitializers(
                    vertex.rootInputDescriptors);

                // numTasks = -1，等待 InputInitializer 设置
                return VertexState.INITIALIZING;
            }
        }
    }
}
```

日志对应：
```
Root Inputs exist for Vertex: Map 1 : {store_sales=...}
Setting vertexManager to RootInputVertexManager for vertex_..._00 [Map 1]
Num tasks is -1. Expecting VertexManager/InputInitializers/1-1 split to set #tasks
vertex_..._00 [Map 1] transitioned from NEW to INITIALIZING due to event V_INIT
```

### 3.2 RootInputInitializerManager 启动 Initializer

**源码位置**：`tez-dag/src/main/java/org/apache/tez/dag/app/dag/RootInputInitializerManager.java`

```java
// RootInputInitializerManager.java
public void runInputInitializers(
    Map<String, RootInputLeafOutput<InputDescriptor, InputInitializerDescriptor>> inputs) {

    for (Map.Entry<String, ...> entry : inputs.entrySet()) {
        String inputName = entry.getKey();  // "store_sales"
        // 获取 Initializer 类名
        // → org.apache.hadoop.hive.ql.exec.tez.HiveSplitGenerator
        String className = entry.getValue()
            .getControllerDescriptor().getClassName();

        LOG.info("Starting InputInitializer for Input: " + inputName
            + " on vertex " + vertex.logIdentifier);

        // 在线程池中异步执行
        ListenableFuture<List<Event>> future =
            executor.submit(new InputInitializerCallable(initializer, ...));
    }
}
```

日志对应：
```
Starting root input initializer for input: store_sales, 
  with class: [org.apache.hadoop.hive.ql.exec.tez.HiveSplitGenerator]
Starting InputInitializer for Input: store_sales on vertex ... [Map 1]
```

---

## 四、阶段三：HiveSplitGenerator（核心分片逻辑）

**源码位置**：`hive-3.1.3/ql/src/java/org/apache/hadoop/hive/ql/exec/tez/HiveSplitGenerator.java`

### 4.1 initialize() 方法 — 入口

```java
// HiveSplitGenerator.java — 完整真实源码（Hive 3.1.3）
// 类方法列表：
//   构造: HiveSplitGenerator(Configuration, MapWork, boolean)
//   构造: HiveSplitGenerator(InputInitializerContext)
//   核心: initialize()
//   辅助: pruneBuckets(), createEventList()
//   回调: onVertexStateUpdated(), handleInputInitializerEvent()
//   内部类: InputSplitComparator

@Override
public List<Event> initialize() throws Exception {
    Utilities.setMapWork(jobConf, work);
    try {
      boolean sendSerializedEvents =
          conf.getBoolean("mapreduce.tez.input.initializer.serialize.event.payload", true);

      // 1. 动态分区修剪
      if (pruner != null) {
        pruner.prune();
      }

      InputSplitInfoMem inputSplitInfo = null;
      boolean generateConsistentSplits =
          HiveConf.getBoolVar(conf, HiveConf.ConfVars.HIVE_TEZ_GENERATE_CONSISTENT_SPLITS);
      LOG.info("GenerateConsistentSplitsInHive=" + generateConsistentSplits);

      String realInputFormatName = conf.get("mapred.input.format.class");
      boolean groupingEnabled = userPayloadProto.getGroupingEnabled();

      if (groupingEnabled) {
        // 2. 反射实例化 InputFormat
        InputFormat<?, ?> inputFormat =
            (InputFormat<?, ?>) ReflectionUtils.newInstance(
                JavaUtils.loadClass(realInputFormatName), jobConf);

        // 3. 计算可用 slots
        int totalResource = 0;
        int taskResource = 0;
        int availableSlots = 0;
        if (getContext() == null) {
          availableSlots = 1;  // LLAP 模式
        }
        if (getContext() != null) {
          totalResource = getContext().getTotalAvailableResource().getMemory();
          taskResource = getContext().getVertexTaskResource().getMemory();
          availableSlots = totalResource / taskResource;
        }
        // 本案例: totalResource=20592MB, taskResource=4096MB
        // availableSlots = 20592 / 4096 = 5

        // 4. ★★★ preferredSplitSize 计算（大哥指出的关键逻辑）★★★
        if (HiveConf.getLongVar(conf, HiveConf.ConfVars.MAPREDMINSPLITSIZE, 1) <= 1) {
          // mapred-default.xml 的默认值是 1（broken configuration）
          // 需要重新计算一个合理的 preferredSplitSize
          final long blockSize = conf.getLong(DFSConfigKeys.DFS_BLOCK_SIZE_KEY,
              DFSConfigKeys.DFS_BLOCK_SIZE_DEFAULT);
          // DFS_BLOCK_SIZE_DEFAULT = 128MB = 134217728

          final long minGrouping = conf.getLong(
              TezMapReduceSplitsGrouper.TEZ_GROUPING_SPLIT_MIN_SIZE,
              TezMapReduceSplitsGrouper.TEZ_GROUPING_SPLIT_MIN_SIZE_DEFAULT);
          // TEZ_GROUPING_SPLIT_MIN_SIZE_DEFAULT = 50MB = 52428800

          final long preferredSplitSize = Math.min(blockSize / 2, minGrouping);
          // Math.min(128MB/2, 50MB) = Math.min(64MB, 50MB) = 50MB
          // ★ 但日志显示 "The preferred split size is 67108864"(64MB)
          //   说明实际 minGrouping 被配置为 >= 64MB，
          //   或 blockSize 被配置为 128MB → blockSize/2 = 64MB < minGrouping
          //   → preferredSplitSize = 64MB

          HiveConf.setLongVar(jobConf, HiveConf.ConfVars.MAPREDMINSPLITSIZE, preferredSplitSize);
          LOG.info("The preferred split size is " + preferredSplitSize);
        }

        // 5. 获取 waves 参数
        float waves = conf.getFloat(
            TezMapReduceSplitsGrouper.TEZ_GROUPING_SPLIT_WAVES,
            TezMapReduceSplitsGrouper.TEZ_GROUPING_SPLIT_WAVES_DEFAULT);
        // waves = 1.7

        // 6. 生成原始 splits
        InputSplit[] splits;
        if (generateSingleSplit
            && conf.get(HiveConf.ConfVars.HIVETEZINPUTFORMAT.varname)
                   .equals(HiveInputFormat.class.getName())) {
          // ORDER BY 单文件场景：手动构造单个 FileSplit
          // ...（省略，本案例不走此分支）
        } else {
          // ★★★ 正常路径：直接调用 inputFormat.getSplits() ★★★
          splits = inputFormat.getSplits(jobConf, (int)(availableSlots * waves));
          // numSplits 参数 = (int)(5 * 1.7) = (int)8.5 = 8
          // 但这只是 hint，实际 split 数由文件数和 splitSize 决定
        }

        // 7. 排序（保证分组一致性）
        Arrays.sort(splits, new InputSplitComparator());
        LOG.info("Number of input splits: " + splits.length + ". " + availableSlots
            + " available slots, " + waves + " waves. Input format is: " + realInputFormatName);

        // 8. 更新计数器（RAW_INPUT_SPLITS, INPUT_DIRECTORIES, INPUT_FILES）
        InputInitializerContext inputInitializerContext = getContext();
        TezCounters tezCounters = null;
        // ...（计数器逻辑省略）

        // 9. Bucket 修剪
        if (work.getIncludedBuckets() != null) {
          splits = pruneBuckets(work, splits);
        }

        // 10. ★★★ 核心：调用 SplitGrouper.generateGroupedSplits() ★★★
        Multimap<Integer, InputSplit> groupedSplits =
            splitGrouper.generateGroupedSplits(jobConf, conf, splits,
                waves, availableSlots, splitLocationProvider);

        // 11. 展平为数组
        InputSplit[] flatSplits = groupedSplits.values().toArray(new InputSplit[0]);
        LOG.info("Number of split groups: " + flatSplits.length);

        // 12. 生成 TaskLocationHint
        List<TaskLocationHint> locationHints =
            splitGrouper.createTaskLocationHints(flatSplits, generateConsistentSplits);

        inputSplitInfo = new InputSplitInfoMem(
            flatSplits, locationHints, flatSplits.length, null, jobConf);
      } else {
        // grouping 未启用 → 抛异常（当前代码路径不支持）
        throw new RuntimeException("HiveInputFormat does not support non-grouped splits");
      }

      // 13. 构建事件列表返回给 AM
      return createEventList(sendSerializedEvents, inputSplitInfo);
    } finally {
      Utilities.clearWork(jobConf);
    }
}
```

**关键细节：preferredSplitSize 的计算**

```java
// 当 MAPREDMINSPLITSIZE <= 1 时（mapred-default.xml 默认值就是 1）：
final long blockSize = DFS_BLOCK_SIZE_KEY;          // 默认 128MB
final long minGrouping = TEZ_GROUPING_SPLIT_MIN_SIZE; // 默认 50MB
final long preferredSplitSize = Math.min(blockSize / 2, minGrouping);
// Math.min(64MB, 50MB) = 50MB（默认情况）
// 但如果 minGrouping 被配置为 >= 64MB，则 preferredSplitSize = 64MB

// 然后设置回 MAPREDMINSPLITSIZE，影响后续 inputFormat.getSplits() 的行为
HiveConf.setLongVar(jobConf, HiveConf.ConfVars.MAPREDMINSPLITSIZE, preferredSplitSize);
```

> **本案例日志**：`The preferred split size is 67108864`（64MB），说明 `blockSize/2 = 67108864`，
> 即 `blockSize = 134217728 = 128MB`（DFS 默认值），且 `minGrouping >= 64MB`（被 Hive/集群配置覆盖）。

**InputSplitComparator 内部类**（真实源码）：

```java
// Descending sort based on split size | Followed by file name | Followed by startPosition
static class InputSplitComparator implements Comparator<InputSplit> {
    @Override
    public int compare(InputSplit o1, InputSplit o2) {
        long len1 = o1.getLength();
        long len2 = o2.getLength();
        if (len1 < len2) {
            return 1;   // 大的排前面（降序）
        } else if (len1 == len2) {
            if (o1 instanceof FileSplit && o2 instanceof FileSplit) {
                FileSplit fs1 = (FileSplit) o1;
                FileSplit fs2 = (FileSplit) o2;
                if (fs1.getPath() != null && fs2.getPath() != null) {
                    int pathComp = fs1.getPath().compareTo(fs2.getPath());
                    if (pathComp == 0) {
                        // 同文件：按 startPosition 升序
                        return Long.compare(fs1.getStart(), fs2.getStart());
                    }
                    return pathComp;  // 不同文件：按路径字典序
                }
            }
            return 0;
        } else {
            return -1;
        }
    }
}
```

### 4.2 inputFormat.getSplits() — 生成原始 Splits

> 在 `initialize()` 方法内直接调用，没有独立的 `generateSplits()` 包装方法。

**真实调用链**（源码路径 `/Users/kailongliu/bigdata/txProjects/hive/ql/.../HiveInputFormat.java`）：
```
inputFormat.getSplits(jobConf, numSplits)
  │
  └─> HiveInputFormat.getSplits(job, numSplits)          ← 第679行
      │
      │  // 不是简单地调 FileInputFormat.getSplits()！
      │  // 而是按分区/输入目录遍历，每个目录获取对应的 InputFormat
      │
      ├─ getInputPaths(job) → 获取所有输入路径（dirs）
      ├─ for (Path dir : dirs):
      │    ├─ getPartitionDescFromPath() → 获取分区描述
      │    ├─ part.getInputFileFormatClass() → 获取该分区的实际 InputFormat
      │    │   （如 OrcInputFormat / ParquetInputFormat / TextInputFormat）
      │    ├─ pushFilters() → 谓词下推
      │    ├─ pushProjection() → 列裁剪（投影下推）
      │    │   日志: hive.io.file.readcolumn.ids = 0,18
      │    │   日志: hive.io.file.readcolumn.names = ss_sold_date_sk,ss_ext_tax
      │    └─ 按相同 InputFormat + Table + TableScan 合并 dirs
      │
      ├─ addSplitsForGroup(currentDirs, ...)              ← 第746/768行
      │    ├─ FileInputFormat.setInputPaths(conf, dirs)
      │    ├─ inputFormat.getSplits(conf, splits)
      │    │   └─> 实际 InputFormat（如 OrcInputFormat）的 getSplits()
      │    │       └─> 内部调 FileInputFormat.getSplits()
      │    │           ├─ listStatus() → 列出文件
      │    │           │   日志: Total input files to process : 80
      │    │           └─ 按 splitSize 切分文件
      │    └─ 每个 InputSplit 包装为 HiveInputSplit(is, inputFormatClass.getName())
      │
      └─ LOG.info("number of splits " + result.size())
         日志: number of splits 240
         返回: HiveInputSplit[]（不是裸的 FileSplit）
```

**关键区别**：`HiveInputFormat.getSplits()` **不是直接调 `FileInputFormat.getSplits()`**，而是：
1. 按 **分区目录** 遍历
2. 每个分区获取自己的 **实际 InputFormat**（ORC/Parquet/Text 等）
3. 对相同 InputFormat + Table 的目录 **合并后** 调 `addSplitsForGroup()`
4. `addSplitsForGroup()` 内部才调实际 InputFormat 的 `getSplits()`
5. 每个原始 split 被 **包装为 `HiveInputSplit`**（包含原始 split + inputFormatClass 名称）

**addSplitsForGroup() 核心逻辑**（第462-539行）：

```java
// HiveInputFormat.java 第462行
private void addSplitsForGroup(List<Path> dirs, TableScanOperator tableScan, JobConf conf,
    InputFormat inputFormat, Class<? extends InputFormat> inputFormatClass, int splits,
    TableDesc table, List<InputSplit> result) throws IOException {

    // 1. ACID 事务表相关处理（validWriteIdList 等）
    // ...

    // 2. 设置输入路径
    FileInputFormat.setInputPaths(conf, finalDirs.toArray(new Path[0]));

    // 3. ★★★ 调用实际 InputFormat 的 getSplits() ★★★
    //    这里的 inputFormat 是分区实际的 InputFormat（如 OrcInputFormat）
    //    而非 HiveInputFormat 本身（不会递归）
    InputSplit[] iss = inputFormat.getSplits(conf, splits);

    // 4. 包装为 HiveInputSplit
    for (InputSplit is : iss) {
      result.add(new HiveInputSplit(is, inputFormatClass.getName()));
    }
}
```

**FileInputFormat.getSplits() 核心逻辑**（Hadoop 源码）：

```java
// FileInputFormat.java (Hadoop)
public InputSplit[] getSplits(JobConf job, int numSplits) throws IOException {
    long totalSize = 0;
    for (FileStatus file : files) {
        totalSize += file.getLen();
    }
    // totalSize = 32,474,979,529 bytes ≈ 30.24 GB

    long goalSize = totalSize / (numSplits == 0 ? 1 : numSplits);
    long minSize = Math.max(job.getLong("mapreduce.input.fileinputformat.split.minsize", 1),
                           minSplitSize);
    // minSize 已被 HiveSplitGenerator 设为 preferredSplitSize = 64MB

    for (FileStatus file : files) {
        long length = file.getLen();
        long blockSize = file.getBlockSize();

        long splitSize = computeSplitSize(goalSize, minSize, blockSize);
        // splitSize = Math.max(minSize, Math.min(goalSize, blockSize))

        long bytesRemaining = length;
        while (bytesRemaining / splitSize > 1.1) {  // 注意 1.1 的余量
            splits.add(makeSplit(path, length - bytesRemaining, splitSize, ...));
            bytesRemaining -= splitSize;
        }
        if (bytesRemaining != 0) {
            splits.add(makeSplit(path, length - bytesRemaining, bytesRemaining, ...));
        }
    }
    // 最终: 240 个 InputSplit
}
```

### 4.3 createEventList() — 构建事件返回给 AM

```java
// HiveSplitGenerator.java — 真实方法
private List<Event> createEventList(boolean sendSerializedEvents,
    InputSplitInfoMem inputSplitInfo) throws ... {

    List<Event> events = new ArrayList<>();

    // 1. 构建 InputConfigureVertexTasksEvent（设置 Vertex 的 task 数和 location hints）
    InputConfigureVertexTasksEvent configEvent =
        InputConfigureVertexTasksEvent.create(
            inputSplitInfo.getNumTasks(),              // 80
            inputSplitInfo.getTaskLocationHints(),      // location hints
            InputSpecUpdate.getDefaultSinglePhysicalInputSpecUpdate());
    events.add(configEvent);

    // 2. 为每个 grouped split 构建 InputDataInformationEvent
    for (int i = 0; i < inputSplitInfo.getNumTasks(); i++) {
        if (sendSerializedEvents) {
            // 序列化模式：发送字节数组
            events.add(InputDataInformationEvent.createWithSerializedPayload(
                i, inputSplitInfo.getSerializedSplits()[i]));
        } else {
            // 对象模式：直接发送 InputSplit 对象
            events.add(InputDataInformationEvent.createWithObjectPayload(
                i, inputSplitInfo.getSplits()[i]));
        }
    }

    return events;
}
```

---

## 五、阶段四：SplitGrouper — 分组核心算法

**源码位置**：`hive-3.1.3/ql/src/java/org/apache/hadoop/hive/ql/exec/tez/SplitGrouper.java`

**SplitGrouper 真实方法列表**（源码路径 `/Users/kailongliu/bigdata/txProjects/hive/ql/.../SplitGrouper.java`）：
- `generateGroupedSplits(6参)` — HiveSplitGenerator 调用的入口
- `generateGroupedSplits(8参)` — 实际分桶逻辑，6参版本转调此方法
- `group()` — 按 bucket 调用 tezGrouper
- `estimateBucketSizes()` — 按 bucket 数据量比例分配 task 数
- `schemaEvolved()` — 判断两个 split 是否跨 schema（InputFormat/Deserializer 变化）
- `createTaskLocationHints()` — 生成任务位置提示
- `populateMapWork()` — 获取 MapWork（私有静态）

字段：`private final TezMapredSplitsGrouper tezGrouper = new TezMapredSplitsGrouper()`
> 注意：`TezMapredSplitsGrouper` 是 `TezSplitGrouper` 的子类

### 5.1 generateGroupedSplits(6参) — 入口，转调8参版本

```java
// SplitGrouper.java 第154-161行 — 真实源码
public Multimap<Integer, InputSplit> generateGroupedSplits(JobConf jobConf,
    Configuration conf, InputSplit[] splits, float waves, int availableSlots,
    SplitLocationProvider locationProvider) throws Exception {
    // 转调8参版本，补充默认参数：inputName=null, groupAcrossFiles=true
    return generateGroupedSplits(jobConf, conf, splits, waves, availableSlots,
        null, true, locationProvider);
}
```

### 5.2 generateGroupedSplits(8参) — 按 schema 边界分桶

```java
// SplitGrouper.java 第164-196行 — 真实源码
public Multimap<Integer, InputSplit> generateGroupedSplits(JobConf jobConf,
    Configuration conf, InputSplit[] splits, float waves, int availableSlots,
    String inputName, boolean groupAcrossFiles,
    SplitLocationProvider locationProvider) throws Exception {

    MapWork work = populateMapWork(jobConf, inputName);

    Multimap<Integer, InputSplit> bucketSplitMultiMap =
        ArrayListMultimap.<Integer, InputSplit>create();

    int i = 0;
    InputSplit prevSplit = null;
    for (InputSplit s : splits) {
      // 按 schema 边界分桶：InputFormat 或 Deserializer 类变了就开新桶
      if (schemaEvolved(s, prevSplit, groupAcrossFiles, work)) {
        ++i;
        prevSplit = s;
      }
      bucketSplitMultiMap.put(i, s);
    }
    LOG.info("# Src groups for split generation: " + (i + 1));
    // 日志: # Src groups for split generation: 2

    // 调用 group() 进行实际分组
    Multimap<Integer, InputSplit> groupedSplits =
        this.group(jobConf, bucketSplitMultiMap, availableSlots, waves, locationProvider);

    return groupedSplits;
}
```

### 5.3 group() — 按 Bucket 调用 TezMapredSplitsGrouper

```java
// SplitGrouper.java 第72-103行 — 真实源码
public Multimap<Integer, InputSplit> group(Configuration conf,
    Multimap<Integer, InputSplit> bucketSplitMultimap, int availableSlots, float waves,
    SplitLocationProvider splitLocationProvider) throws IOException {

    // 1. 按数据量比例分配每个 bucket 的 task 数
    Map<Integer, Integer> bucketTaskMap =
        estimateBucketSizes(availableSlots, waves, bucketSplitMultimap.asMap());

    Multimap<Integer, InputSplit> bucketGroupedSplitMultimap =
        ArrayListMultimap.<Integer, InputSplit>create();

    // 2. 逐个 bucket 调用 tezGrouper 分组
    for (int bucketId : bucketSplitMultimap.keySet()) {
      Collection<InputSplit> inputSplitCollection = bucketSplitMultimap.get(bucketId);
      InputSplit[] rawSplits = inputSplitCollection.toArray(new InputSplit[0]);

      // ★★★ 关键调用 ★★★
      // tezGrouper 类型 = TezMapredSplitsGrouper（TezSplitGrouper 的子类）
      InputSplit[] groupedSplits = tezGrouper.getGroupedSplits(
          conf,                                    // Configuration
          rawSplits,                                // 原始 splits
          bucketTaskMap.get(bucketId),              // desiredNumSplits（如 8）
          HiveInputFormat.class.getName(),          // wrappedInputFormatName
          new ColumnarSplitSizeEstimator(),          // 列式存储大小估算器
          splitLocationProvider);                    // 位置提供者

      LOG.info("Original split count is " + rawSplits.length + " grouped split count is "
          + groupedSplits.length + ", for bucket: " + bucketId);
      // 日志: Original split count is 240 grouped split count is 80, for bucket: 1

      for (InputSplit inSplit : groupedSplits) {
        bucketGroupedSplitMultimap.put(bucketId, inSplit);
      }
    }
    return bucketGroupedSplitMultimap;
}
```

### 5.4 estimateBucketSizes() — 按数据量比例分配 task 数

```java
// SplitGrouper.java 第203-258行 — 真实源码
private Map<Integer, Integer> estimateBucketSizes(int availableSlots, float waves,
    Map<Integer, Collection<InputSplit>> bucketSplitMap) {

    Map<Integer, Long> bucketSizeMap = new HashMap<>();
    Map<Integer, Integer> bucketTaskMap = new HashMap<>();

    long totalSize = 0;
    boolean earlyExit = false;
    for (int bucketId : bucketSplitMap.keySet()) {
      long size = 0;
      for (InputSplit s : bucketSplitMap.get(bucketId)) {
        // SMB Join 场景：非 FileSplit → 直接用 availableSlots * waves
        if (!(s instanceof FileSplit)) {
          bucketTaskMap.put(bucketId, (int)(availableSlots * waves));
          earlyExit = true;
          continue;
        }
        FileSplit fsplit = (FileSplit) s;
        size += fsplit.getLength();
        totalSize += fsplit.getLength();
      }
      bucketSizeMap.put(bucketId, size);
    }
    if (earlyExit) return bucketTaskMap;

    // 按数据量占比分配 task 数
    for (int bucketId : bucketSizeMap.keySet()) {
      int numEstimatedTasks = 0;
      if (totalSize != 0) {
        // 公式：availableSlots * waves * (bucketSize / totalSize)
        numEstimatedTasks =
            (int)(availableSlots * waves * bucketSizeMap.get(bucketId) / totalSize);
      }
      LOG.info("Estimated number of tasks: " + numEstimatedTasks + " for bucket " + bucketId);
      // 日志: Estimated number of tasks: 8 for bucket 1
      if (numEstimatedTasks == 0) numEstimatedTasks = 1;
      bucketTaskMap.put(bucketId, numEstimatedTasks);
    }
    return bucketTaskMap;
}
```

### 5.5 TezSplitGrouper.getGroupedSplits() — 分组核心算法

**源码位置**：`/Users/kailongliu/bigdata/gitproject/tez/tez-mapreduce/src/main/java/org/apache/tez/mapreduce/grouper/TezSplitGrouper.java`

**核心配置常量**：

| 常量 | 默认值 | 作用 |
|------|--------|------|
| `TEZ_GROUPING_SPLIT_WAVES` | 1.7f | 任务波次倍数 |
| `TEZ_GROUPING_SPLIT_MAX_SIZE` | 1GB（Tez默认）/ 500MB（Hive覆盖）| 分组大小上限 |
| `TEZ_GROUPING_SPLIT_MIN_SIZE` | 50MB | 分组大小下限 |
| `TEZ_GROUPING_SPLIT_BY_LENGTH` | true | 按大小分组 |
| `TEZ_GROUPING_SPLIT_BY_COUNT` | false | 按数量分组 |
| `TEZ_GROUPING_NODE_LOCAL_ONLY` | false | 仅节点本地 |
| `TEZ_GROUPING_RACK_SPLIT_SIZE_REDUCTION` | 0.75f | 机架本地缩减因子 |

```java
// TezSplitGrouper.java — 真实源码逻辑
public List<GroupedSplitContainer> getGroupedSplits(Configuration conf,
    List<SplitContainer> originalSplits, int desiredNumSplits,
    ...) throws IOException {

    // ===== Step 1: 参数初始化 =====
    // 检查 TEZ_GROUPING_SPLIT_COUNT 配置覆盖
    int configNumSplits = conf.getInt(TEZ_GROUPING_SPLIT_COUNT, 0);
    if (configNumSplits > 0) {
        desiredNumSplits = configNumSplits;  // 配置优先
    }

    // ===== Step 2: 计算总数据量 + 构建 Location 映射 =====
    long totalLength = 0;
    Map<String, LocationHolder> distinctLocations = new HashMap<>();
    for (SplitContainer split : originalSplits) {
        totalLength += estimator.getEstimatedSize(split);
        String[] locations = locationProvider.getPreferredLocations(split);
        for (String loc : locations) {
            distinctLocations.putIfAbsent(loc, new LocationHolder());
        }
    }
    // totalLength = 32,474,979,529 bytes

    // ===== Step 3: 计算 lengthPerGroup + 边界检查 =====
    long lengthPerGroup = totalLength / desiredNumSplits;
    // lengthPerGroup = 32,474,979,529 / 8 = 4,059,372,441 ≈ 3.78 GB

    long maxLengthPerGroup = conf.getLong(TEZ_GROUPING_SPLIT_MAX_SIZE, ...);  // 500MB
    long minLengthPerGroup = conf.getLong(TEZ_GROUPING_SPLIT_MIN_SIZE, ...);  // 50MB

    // ★★★ 关键：超过 max 时重算 ★★★
    if (lengthPerGroup > maxLengthPerGroup) {
        desiredNumSplits = (int) Math.ceil((double) totalLength / maxLengthPerGroup);
        lengthPerGroup = maxLengthPerGroup;
        LOG.info("Desired splits: " + configNumSplits + " too small. ...");
    }
    // 日志: Desired splits: 8 too small. New desired splits: 65

    // ★ 低于 min 时也重算 ★
    if (lengthPerGroup < minLengthPerGroup) {
        desiredNumSplits = (int) Math.ceil((double) totalLength / minLengthPerGroup);
        lengthPerGroup = minLengthPerGroup;
    }

    // ===== Step 4: 早期退出检查 =====
    if (desiredNumSplits == 0 || originalSplits.isEmpty()
        || desiredNumSplits >= originalSplits.size()) {
        // 直接返回原始 splits，不分组
        return wrapSplits(originalSplits);
    }

    int numSplitsInGroup = originalSplits.size() / desiredNumSplits;  // 240/65 ≈ 3

    LOG.info("Desired numSplits: " + desiredNumSplits
        + " lengthPerGroup: " + lengthPerGroup
        + " numLocations: " + distinctLocations.size()
        + " numSplitsPerLocation: " + (originalSplits.size() / distinctLocations.size())
        + " numSplitsInGroup: " + numSplitsInGroup
        + " totalLength: " + totalLength
        + " numOriginalSplits: " + originalSplits.size()
        + " . Grouping by length: " + groupByLength
        + " count: " + groupByCount
        + " nodeLocalOnly: " + nodeLocalOnly);

    // ===== Step 5: 填充 LocationHolder =====
    for (SplitContainer split : originalSplits) {
        String[] locations = locationProvider.getPreferredLocations(split);
        // COS: locations 为空或统一 → 所有 splits 归入同一 location
        for (String loc : locations) {
            distinctLocations.get(loc).splits.add(split);
        }
    }

    // ===== Step 6: ★★★ 多轮迭代分组（核心！）★★★ =====
    List<GroupedSplitContainer> groupedSplits = new ArrayList<>();
    boolean allowSmallGroups = false;

    // --- 第一轮：节点本地分组 ---
    while (true) {
        int numFullGroupsCreated = 0;

        for (Map.Entry<String, LocationHolder> entry : distinctLocations.entrySet()) {
            String location = entry.getKey();
            LocationHolder holder = entry.getValue();

            GroupedSplitContainer currentGroup = new GroupedSplitContainer();
            long currentGroupLength = 0;
            int currentGroupCount = 0;

            Iterator<SplitContainer> iter = holder.splits.iterator();
            while (iter.hasNext()) {
                SplitContainer split = iter.next();
                if (split.isProcessed()) continue;  // 已被其他 location 处理

                currentGroup.addSplit(split);
                currentGroupLength += split.getLength();
                currentGroupCount++;
                split.setProcessed(true);
                iter.remove();

                // 判断当前组是否已满
                boolean groupComplete = false;
                if (groupByLength && currentGroupLength >= lengthPerGroup) {
                    groupComplete = true;
                }
                if (groupByCount && currentGroupCount >= numSplitsInGroup) {
                    groupComplete = true;
                }

                if (groupComplete) {
                    groupedSplits.add(currentGroup);
                    numFullGroupsCreated++;
                    // 重置
                    currentGroup = new GroupedSplitContainer();
                    currentGroupLength = 0;
                    currentGroupCount = 0;
                }
            }

            // 处理剩余（不足一组的尾巴）
            if (currentGroup.getSize() > 0) {
                if (allowSmallGroups ||
                    currentGroupLength >= lengthPerGroup / 2) {
                    groupedSplits.add(currentGroup);
                }
                // 否则留给下一轮处理
            }
        }

        // --- 是否切换到机架本地？---
        if (numFullGroupsCreated < 1 && !nodeLocalOnly) {
            // 节点本地几乎没有产生完整分组 → 切换机架本地
            // 用 RackResolver 重建 location 映射
            // 应用 rackSplitSizeReduction = 0.75
            lengthPerGroup = (long)(lengthPerGroup * 0.75);
            numSplitsInGroup = (int)(numSplitsInGroup * 0.75);
            // 重建基于 rack 的 LocationHolder...
            continue;
        }

        // --- 是否允许小组？---
        if (numFullGroupsCreated < distinctLocations.size() * 0.1) {
            allowSmallGroups = true;
            continue;
        }

        break;  // 分组完成
    }

    LOG.info("Number of splits desired: " + desiredNumSplits
        + " created: " + groupedSplits.size()
        + " splitsProcessed: " + originalSplits.size());

    return groupedSplits;
}
```

> **注**：以上是简化后的逻辑骨架，真实源码还包含 `repeatable` 排序、S3 localhost 特殊处理等细节。

---

## 六、为什么期望 65 但实际生成 80？

### 关键分析

```
期望 65 个 grouped splits，实际生成 80 个
```

**原因在于文件边界**：

```java
// TezSplitGrouper 在合并时，实际上还受文件边界影响
// COS 对象存储返回的 locations 为空数组，但 splits 是按文件顺序排列的
// 每个文件 ≈ 406MB，被切为 3 个 split（约 135MB × 3）
//
// 按 lengthPerGroup ≈ 500MB 合并：
//   - 每个文件的 3 个 split 总计 ≈ 406MB < 500MB → 刚好合成 1 组
//   - 跨文件合并时，406MB + 135MB = 541MB > 500MB → 不会跨文件合并
//
// 所以最终：80 个文件 → 80 个 grouped splits（1:1 映射）
//
// 只有当单个文件 > 500MB 时才会 1 文件 → 多个 grouped splits
// 只有当多个文件加起来 < 500MB 时才会多文件 → 1 个 grouped split
```

**数值验证**：
```
总数据量 = 32,474,979,529 bytes
80 个文件 → 平均每个文件 = 32,474,979,529 / 80 ≈ 405,937,244 bytes ≈ 387MB
每个文件 387MB < maxGroupSize 500MB → 1 文件 = 1 组
但 387MB + 387MB = 774MB > 500MB → 不会跨文件合并
结果：80 个 grouped splits
```

---

## 七、阶段五：通知 VertexImpl 设置并行度

### 7.1 InputInitializer 完成回调

```java
// RootInputInitializerManager.java — Callback
public void onSuccess(List<Event> result) {
    LOG.info("Succeeded InputInitializer for Input: " + inputName
        + " on vertex " + vertex.logIdentifier);

    // 将 events 发送给 Vertex
    vertex.handle(new VertexEventRootInputInitialized(
        vertex.getVertexId(), inputName, result));
}
```

日志对应：
```
Succeeded InputInitializer for Input: store_sales on vertex ... [Map 1]
```

### 7.2 VertexImpl 设置并行度

```java
// VertexImpl.java — handleInputInitializerEvent
private void handleRootInputInitializerEvent(VertexEventRootInputInitialized event) {
    // 收到 InputDataInformationEvent 列表
    List<InputDataInformationEvent> events = ...;

    // 事件数量 = grouped split 数量 = 80
    int numTasks = events.size();

    LOG.info("Vertex " + logIdentifier + " parallelism set to " + numTasks);
    // → setParallelism(80)

    // 创建 80 个 Task
    for (int i = 0; i < numTasks; i++) {
        addTask(new TaskImpl(...));
    }
}
```

日志对应：
```
Got updated RootInputsSpecs: {store_sales=forAllWorkUnits=true, update=[1]}
Vertex vertex_..._00 [Map 1] parallelism set to 80
```

### 7.3 Vertex 状态机转换

```
INITIALIZING → INITED → RUNNING

具体事件链：
1. V_INPUT_DATA_INFORMATION → INITIALIZING → INITED
2. V_START → INITED → RUNNING
```

日志对应：
```
vertex_..._00 [Map 1] transitioned from INITIALIZING to INITED due to event V_INPUT_DATA_INFORMATION
vertex_..._00 [Map 1] transitioned from INITED to RUNNING due to event V_START
```

---

## 八、阶段六：Reducer 2 的并行度

### 8.1 ShuffleVertexManager 设置

**源码位置**：`tez-runtime-library/src/main/java/org/apache/tez/dag/library/vertexmanager/ShuffleVertexManager.java`

```java
// ShuffleVertexManager（在 DAG 提交时由 Hive 预设）
// Reducer 2 的并行度由 Hive 在编译阶段计算：
//
// hive.exec.reducers.bytes.per.reducer = 67108864 (64MB, Hive 默认)
// 但从日志看 desiredTaskInput = 104857600 (100MB)
//
// 预设 Reducer 数 = ceil(totalInputSize / bytesPerReducer)
// 如果 totalInputSize 按估算的输出大小（非输入大小）计算
// 可能是 Hive 优化器估算 Map 输出 ≈ 100GB → 100GB / 100MB = 1009

// 日志:
// ShuffleVertexManagerBase Settings:
//   minFrac: 1.0       ← 等所有 source 完成才考虑调整
//   maxFrac: 1.0
//   auto: false         ← ★ auto parallelism 关闭！
//   desiredTaskInput: 104857600 (100MB)
// minTaskParallelism 1
// Creating 1009 tasks for vertex: ... [Reducer 2]
```

**注意**：`auto: false` 意味着 **Reducer 不会自动调整并行度**，1009 是固定值。

---

## 九、完整参数影响图

```
┌─────────────────────────────────────────────────────────────┐
│                   分片参数决策树                              │
│                                                             │
│  输入文件 (80 files, 30.24GB on COS)                        │
│      │                                                      │
│      ▼                                                      │
│  FileInputFormat.getSplits()                                │
│  ├─ mapreduce.input.fileinputformat.split.maxsize           │
│  │  (由 preferredSplitSize=64MB 控制)                       │
│  └─→ 240 原始 splits                                       │
│      │                                                      │
│      ▼                                                      │
│  SplitGrouper.generateGroupedSplits()                        │
│  ├─ group() → estimateBucketSizes()                          │
│  ├─ tez.grouping.split-waves = 1.7                          │
│  ├─ 初始期望 = 5 × 1.7 = 8.5 ≈ 8                          │
│  │                                                          │
│  └─ TezSplitGrouper.getGroupedSplits()                     │
│     ├─ tez.grouping.max-size = 500MB                        │
│     ├─ tez.grouping.min-size = 50MB                         │
│     ├─ 期望每组 = 30.24GB / 8 = 3.78GB > 500MB ✗           │
│     ├─ 重算: 30.24GB / 500MB = 65                           │
│     ├─ 按 500MB 合并，但文件边界约束                          │
│     └─→ 80 grouped splits（1 文件 = 1 组）                  │
│                                                             │
│  最终: Map 1 = 80 tasks, Reducer 2 = 1009 tasks            │
└─────────────────────────────────────────────────────────────┘
```

---

## 十、优化建议

### 10.1 Reducer 数过多

```sql
-- 当前 1009 个 Reducer，对于聚合查询过多
-- 方案1: 开启自动并行度
SET hive.tez.auto.reducer.parallelism=true;

-- 方案2: 手动指定
SET mapred.reduce.tasks=10;
-- count/sum 聚合最终只需要 1 个 Reducer
```

### 10.2 Map 数调优

```sql
-- 当前 80 个 Map 处理 30GB 数据（每个 ~380MB），合理
-- 如果想减少 Map 数（增大分组）：
SET tez.grouping.max-size=1073741824;  -- 1GB
-- 则 30GB / 1GB = 30 个 Map

-- 如果想增加 Map 数（减小分组）：
SET tez.grouping.max-size=134217728;   -- 128MB
-- 则 30GB / 128MB = 240 个 Map（退化为原始 split 数）
```

### 10.3 COS 对象存储优化

```sql
-- COS 无数据本地性，所有 split 在同一 location
-- nodeLocalOnly=false 是正确的
-- 重点优化 COS 读取并发和带宽
SET fs.cosn.read.ahead.block.size=4194304;      -- 预读 4MB
SET fs.cosn.read.ahead.queue.size=8;             -- 预读队列深度
SET fs.cosn.maxRetries=5;                        -- 重试次数
```

---

## 十一、关键类索引

| 类名 | 所属模块 | 职责 |
|------|---------|------|
| `DAGAppMaster` | tez-dag | AM 主类，管理 DAG 生命周期 |
| `DAGImpl` | tez-dag | DAG 状态机实现 |
| `VertexImpl` | tez-dag | Vertex 状态机，管理 task 并行度 |
| `RootInputInitializerManager` | tez-dag | 管理 InputInitializer 线程池 |
| `HiveSplitGenerator` | hive-ql | Hive 的 InputInitializer 实现，入口类 |
| `SplitGrouper` | hive-ql | Hive 层分组逻辑，管理 bucket 分桶 |
| `TezSplitGrouper` | tez-mapreduce | Tez 层核心分组算法（按 location/length 合并） |
| `HiveInputFormat` | hive-ql | 生成原始 InputSplit |
| `FileInputFormat` | hadoop-mapreduce | Hadoop 基础 split 切分逻辑 |
| `RootInputVertexManager` | tez-dag | 管理根 Vertex 的 task 调度 |
| `ShuffleVertexManager` | tez-runtime-library | 管理 Shuffle Vertex（Reducer）的并行度 |
| `GroupedSplit` | tez-mapreduce | 分组后的 Split 包装类 |

---

> **作者**：Eric (BigData SRE AI Expert Team)  
> **日期**：2026-04-17  
> **版本**：v1.0  
> **标签**：Tez, Hive, Split, 分片计算, 源码分析
