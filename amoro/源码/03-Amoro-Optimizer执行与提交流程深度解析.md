# Amoro 源码深度解析：Optimizer 执行与提交流程

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-25

---

## 一、Optimizer 进程架构

```
StandaloneOptimizer (main)
  └── Optimizer
       ├── OptimizerToucher（1 个线程）— 心跳保活
       └── OptimizerExecutor × N（N 个工作线程）— 执行任务
```

### 1.1 Optimizer 启动

```java
// Optimizer.java
public class Optimizer {
    private final OptimizerConfig config;
    private final OptimizerToucher toucher;      // 心跳线程
    private final OptimizerExecutor[] executors;  // 工作线程组

    public void startOptimizing() {
        // 1. 注册到 AMS
        toucher.start();  // 发送 register → 获得 token

        // 2. 启动 N 个执行线程
        for (int i = 0; i < config.getExecutionParallel(); i++) {
            executors[i] = new OptimizerExecutor(config, i);
            new Thread(executors[i]::start).start();
        }
    }
}
```

### 1.2 OptimizerToucher — 心跳保活

```java
// OptimizerToucher.java
// 定期向 AMS 发送 touch(token)
// AMS 侧：超过 touchTimeout 未 touch → 标记 optimizer 为 expired
// expired 后：该 optimizer 持有的任务会被重新分配
```

---

## 二、OptimizerExecutor — 任务执行核心

**源码位置**: `amoro-optimizer/amoro-optimizer-common/.../OptimizerExecutor.java`

### 2.1 主循环

```java
// OptimizerExecutor.java Line 48-60
public void start() {
    while (isStarted()) {
        try {
            // 1. 拉取任务（长轮询）
            OptimizingTask task = pollTask();

            // 2. 确认接收
            if (task != null && ackTask(task)) {
                // 3. 执行任务
                OptimizingTaskResult result = executeTask(task);

                // 4. 上报结果
                completeTask(result);
            }
        } catch (Throwable t) {
            LOG.error("unexpected error", t);
        }
    }
}
```

### 2.2 pollTask() — 任务拉取

```java
// Line 66-82
private OptimizingTask pollTask() {
    while (isStarted()) {
        try {
            // Thrift RPC: client.pollTask(token, threadId)
            task = callAuthenticatedAms(
                (client, token) -> client.pollTask(token, threadId));
        } catch (TException e) {
            LOG.error("polled task failed", e);
        }
        if (task != null) {
            break;
        } else {
            waitAShortTime();  // 无任务时短暂等待再重试
        }
    }
    return task;
}
```

### 2.3 executeTask() — 任务执行（核心）

```java
// Line 128-173
public static OptimizingTaskResult executeTask(
    OptimizerConfig config, int threadId, OptimizingTask task, Logger logger) {

    long startTime = System.currentTimeMillis();
    try {
        // 1. 解析任务属性
        OptimizingInputProperties properties =
            OptimizingInputProperties.parse(task.getProperties());

        // 2. 反序列化任务输入（RewriteFilesInput）
        TableOptimizing.OptimizingInput input =
            SerializationUtil.simpleDeserialize(task.getTaskInput());

        // 3. 通过反射创建 ExecutorFactory
        String executorFactoryImpl = properties.getExecutorFactoryImpl();
        // 例如: IcebergRewriteExecutorFactory / MixedIcebergRewriteExecutorFactory
        OptimizingExecutorFactory factory = DynConstructors.builder(...)
            .impl(executorFactoryImpl).buildChecked().newInstance();

        // 4. 配置 Spill-to-Disk（大任务防 OOM）
        if (config.isExtendDiskStorage()) {
            properties.enableSpillMap();
        }
        properties.setMaxSizeInMemory(config.getMemoryStorageSize() * 1024 * 1024);
        factory.initialize(properties.getProperties());

        // 5. 创建执行器并执行
        OptimizingExecutor executor = factory.createExecutor(input);
        TableOptimizing.OptimizingOutput output = executor.execute();

        // 6. 序列化输出
        ByteBuffer outputByteBuffer = SerializationUtil.simpleSerialize(output);

        // 7. 构建结果
        OptimizingTaskResult result = new OptimizingTaskResult(task.getTaskId(), threadId);
        result.setTaskOutput(outputByteBuffer);
        result.setSummary(output.summary());
        return result;

    } catch (Throwable t) {
        // 失败：返回错误信息（截断到 4000 字符）
        OptimizingTaskResult errorResult = new OptimizingTaskResult(...);
        errorResult.setErrorMessage(
            ExceptionUtil.getErrorMessage(t, ERROR_MESSAGE_MAX_LENGTH));
        return errorResult;
    }
}
```

---

## 三、IcebergRewriteExecutor — 文件重写实现

**源码位置**: `amoro-format-iceberg/.../optimizing/IcebergRewriteExecutor.java`

```java
// IcebergRewriteExecutor.java
public class IcebergRewriteExecutor extends AbstractRewriteFilesExecutor {

    // 数据读取器
    @Override
    protected OptimizingDataReader dataReader() {
        return new GenericCombinedIcebergDataReader(
            io, table.schema(), table.spec(), ...);
        // 读取旧文件 + 应用 delete 过滤
    }

    // Position Delete 写入器
    @Override
    protected FileWriter<PositionDelete<Record>, DeleteWriteResult> posWriter() {
        return new IcebergFanoutPosDeleteWriter<>(...);
    }

    // 数据写入器
    @Override
    protected TaskWriter<Record> dataWriter() {
        if (table.spec().isUnpartitioned()) {
            return new UnpartitionedWriter<>(...);
        } else {
            return new GenericIcebergPartitionedFanoutWriter(
                table.schema(), table.spec(), dataFileFormat(),
                appenderFactory, outputFileFactory, io, targetSize());
        }
    }
}
```

**AbstractRewriteFilesExecutor.execute() 流程**:

```
1. 读取旧文件（含 delete 过滤）
   → GenericCombinedIcebergDataReader.read()
   → 应用 Position Delete + Equality Delete
   → 输出有效记录

2. 写入新文件
   → dataWriter.write(record)
   → 按分区 fanout 写入
   → 达到 targetSize 自动滚动新文件

3. 如果有 pos-delete 需要重写
   → posWriter.write(positionDelete)

4. 返回 RewriteFilesOutput
   └── newDataFiles + newDeleteFiles
```

---

## 四、提交流程

### 4.1 AMS 侧 — DefaultOptimizingService.completeTask()

```java
// DefaultOptimizingService.java
public void completeTask(String token, OptimizingTaskResult result) {
    // 1. 验证 token
    // 2. 找到对应的 TaskRuntime
    // 3. 更新任务状态 → SUCCESS 或 FAILED
    taskRuntime.complete(thread, result);

    // 4. 如果所有任务都完成 → 标记 Process 完成
    // 5. OptimizingCommitExecutor 异步提交
}
```

### 4.2 AMS 侧 — UnKeyedTableCommit

```java
// UnKeyedTableCommit.java（amoro-ams）
// 将所有 task 的 output 汇总，执行 Iceberg 表级提交：

// 1. 收集所有新文件和旧文件
List<DataFile> addedDataFiles = collectFromAllTasks();
List<DataFile> removedDataFiles = collectFromAllTasks();

// 2. 执行 Iceberg RewriteFiles 操作
RewriteFiles rewrite = table.newRewrite();
rewrite.rewriteFiles(removedDataFiles, addedDataFiles);
rewrite.commit();  // 触发 Iceberg 的乐观并发提交
```

---

## 五、完整执行时序

```
时间轴 →

AMS 侧:
  [plan] → 生成 N 个 TaskRuntime (PLANNED)
                ↓
  [poll] → Optimizer 拉取 → SCHEDULED
                ↓
  [ack]  → Optimizer 确认 → ACKED
                ↓
           ... (Optimizer 执行中) ...
                ↓
  [complete] → SUCCESS/FAILED
                ↓
  [commit] → OptimizingCommitExecutor
             → UnKeyedTableCommit.execute()
             → Iceberg RewriteFiles.commit()
             → 更新 TableRuntime 状态

Optimizer 侧:
  pollTask() ──→ ackTask() ──→ executeTask() ──→ completeTask()
     │              │              │                    │
     │              │         IcebergRewrite            │
     │              │         Executor:                 │
     │              │         ├─ 读旧文件              │
     │              │         ├─ 过滤 delete            │
     │              │         ├─ 写新文件              │
     │              │         └─ 返回 output            │
     ▼              ▼              ▼                    ▼
   Thrift RPC     Thrift RPC    本地执行            Thrift RPC
```

---

## 六、关键调优参数

| 参数 | 位置 | 默认 | 说明 |
|------|------|------|------|
| `execution.parallel` | Optimizer 配置 | CPU 核数 | 执行线程数 |
| `memory-storage-size` | Optimizer 配置 | 512 (MB) | 内存缓存大小 |
| `extend-disk-storage` | Optimizer 配置 | false | 是否启用磁盘溢写 |
| `disk-storage-path` | Optimizer 配置 | /tmp | 溢写路径 |

**常见问题**：
- Optimizer OOM → 调大 `memory-storage-size` 或开启 `extend-disk-storage`
- 任务超时 → 检查文件数量是否过大，调小 `max-file-count`
- 提交冲突 → 其他写入任务并发 → Iceberg 自动重试

---

*Amoro Optimizer 执行深度解析 v1.0 | Eric | 2026-04-25*
