# Spark-SQL + DRA + ESS 的 Shuffle 管理生命周期（源码级）

> 基线：腾讯内部 fork `e.coding.net/tencentemr/spark`，分支 `gaotu-3.2.1`（Apache Spark 3.2.1）
> 本地路径：`D:\bigdata\txproject\spark`（线上代码）
> 分析对象：`spark.dynamicAllocation.enabled=true` + `spark.shuffle.service.enabled=true` 场景下，一份 Shuffle 数据从"产生→注册→被读→executor 被回收→最终清理"的完整生命周期。

---

## 一、结论速览（一句话）

开启 ESS 后，Shuffle 文件的**物理所有权从 executor 进程解耦到 NodeManager（ESS）**，因此 DRA 在判定 executor 空闲时**完全不把 Shuffle 数据计入"是否可回收"**——executor idle 满 `executorIdleTimeout`（默认 60s）即被杀，Shuffle 文件继续留在 NM 上由 ESS 服务 reduce 端读取。文件真正物理删除，发生在 **app 结束时由 YARN NodeManager 的 DeletionService 删 appcache 目录**，而**不是** ESS 自己删。

这条结论的两个反直觉点（详见第六节）：
1. `ExecutorMonitor` 里的 shuffle 追踪逻辑（`hasActiveShuffle`）**只在不开 ESS 时才生效**，二者互斥。
2. YARN 模式下 `YarnShuffleService.stopContainer` / `stopApplication` **都不删 shuffle 文件**。

---

## 二、前置约束：DRA 与 ESS 的硬绑定

DRA 启动时强制校验：没有 ESS 就不允许开 DRA（除非显式开实验性的 shuffleTracking / decommission）。

```206:218:core/src/main/scala/org/apache/spark/ExecutorAllocationManager.scala
    if (!conf.get(config.SHUFFLE_SERVICE_ENABLED)) {
      // If dynamic allocation shuffle tracking or worker decommissioning along with
      // storage shuffle decommissioning is enabled we have *experimental* support for
      // decommissioning without a shuffle service.
      if (conf.get(config.DYN_ALLOCATION_SHUFFLE_TRACKING_ENABLED) ||
          (decommissionEnabled &&
            conf.get(config.STORAGE_DECOMMISSION_SHUFFLE_BLOCKS_ENABLED))) {
        logWarning("Dynamic allocation without a shuffle service is an experimental feature.")
      } else if (!testing) {
        throw new SparkException("Dynamic allocation of executors requires the external " +
          "shuffle service. You may enable this through spark.shuffle.service.enabled.")
      }
    }
```

> 上面 `conf.get(config.XXX)` 里三个常量的实际意义（即时对照，免跳转）：
>
> | 代码常量 | 对应参数名 | 默认值 | 引入版本 | 定义位置 |
> |---|---|---|---|---|
> | `SHUFFLE_SERVICE_ENABLED` | `spark.shuffle.service.enabled` | `false` | 1.2.0 | `internal/config/package.scala` L656-660 |
> | `DYN_ALLOCATION_SHUFFLE_TRACKING_ENABLED` | `spark.dynamicAllocation.shuffleTracking.enabled` | `false` | 3.0.0 | `internal/config/package.scala` L618-622 |
> | `STORAGE_DECOMMISSION_SHUFFLE_BLOCKS_ENABLED` | `spark.storage.decommission.shuffleBlocks.enabled` | `false` | 3.1.0 | `internal/config/package.scala` L430-436 |
>
> （三件套完整源码引用见第 5.1 节。）

**原因**：DRA 的核心动作是"杀掉空闲 executor"。如果 Shuffle 文件只存在于 executor 本地、又没有 ESS 托管，杀掉 executor 就等于丢掉它产生的所有 map output，下游 reduce 会 `FetchFailedException` 触发整 Stage 重算。ESS 把文件托管出来，才让"杀 executor 不丢 shuffle"成为可能。

`ExecutorMonitor` 把这个互斥关系编码成两个布尔开关：

```52:55:core/src/main/scala/org/apache/spark/scheduler/dynalloc/ExecutorMonitor.scala
  private val fetchFromShuffleSvcEnabled = conf.get(SHUFFLE_SERVICE_ENABLED) &&
    conf.get(SHUFFLE_SERVICE_FETCH_RDD_ENABLED)
  private val shuffleTrackingEnabled = !conf.get(SHUFFLE_SERVICE_ENABLED) &&
    conf.get(DYN_ALLOCATION_SHUFFLE_TRACKING_ENABLED)
```

> 上面 `conf.get(...)` 里三个常量的实际意义（即时对照，免跳转）：
>
> | 代码常量 | 对应参数名 | 默认值 | 引入版本 | 定义位置 |
> |---|---|---|---|---|
> | `SHUFFLE_SERVICE_ENABLED` | `spark.shuffle.service.enabled` | `false` | 1.2.0 | `internal/config/package.scala` L656-660 |
> | `SHUFFLE_SERVICE_FETCH_RDD_ENABLED` | `spark.shuffle.service.fetch.rdd.enabled` | `false` | 3.0.0 | `internal/config/package.scala` L662-670 |
> | `DYN_ALLOCATION_SHUFFLE_TRACKING_ENABLED` | `spark.dynamicAllocation.shuffleTracking.enabled` | `false` | 3.0.0 | `internal/config/package.scala` L618-622 |
>
> （三件套完整源码引用见第 5.1 节。）

> `shuffleTrackingEnabled = !ESS && tracking`。**只要开了 ESS，`shuffleTrackingEnabled` 恒为 false。** 这是理解后面 DRA 回收逻辑的总钥匙。

---

## 三、生命周期总览

### 3.1 阶段流转（Mermaid）

```mermaid
flowchart TD
    classDef driver  fill:#E8F0FE,stroke:#4285F4,stroke-width:1.5px,color:#1a3d8f
    classDef exec    fill:#FFF4E5,stroke:#F9A825,stroke-width:1.5px,color:#7a4f00
    classDef ess     fill:#E8F5E9,stroke:#43A047,stroke-width:1.5px,color:#1b5e20
    classDef clean   fill:#FCE4EC,stroke:#D81B60,stroke-width:1.5px,color:#880e4f
    classDef yarn    fill:#EDE7F6,stroke:#5E35B1,stroke-width:1.5px,color:#311b92

    subgraph S1["阶段1 · 产生（Driver 端）"]
        direction TB
        SQL["ShuffleExchangeExec<br/>(SQL 物理计划)"]
        DEP["new ShuffleDependency<br/>① shuffleId = newShuffleId()<br/>② shuffleManager.registerShuffle()<br/>③ cleaner.registerShuffleForCleanup(this)<br/>④ shuffleDriverComponents.registerShuffle()"]
        SQL --> DEP
    end

    subgraph S1B["阶段1 · 写盘（Executor 端）"]
        WRITE["ShuffleWriter 写本地盘<br/>shuffle_{id}_{mapId}_0.data / .index<br/>📁 NM appcache/&lt;appId&gt;/blockmgr-*/"]
    end

    subgraph S2["阶段2 · 注册"]
        REG["ExternalShuffleBlockResolver.registerExecutor()<br/>localDirs / subDirs / shuffleManager → LevelDB"]
    end

    subgraph S3["阶段3 · 读取"]
        READ["reduce task ──OpenBlocks──►<br/>ESS.getSortBasedShuffleBlockData()<br/><b>不经过 executor JVM</b>"]
    end

    subgraph S4["阶段4 · DRA 回收"]
        IDLE["executor idle ≥ 60s<br/>(executorIdleTimeout)"]
        KILL["ExecutorMonitor.timedOutExecutors()<br/>↓<br/>killExecutors()<br/><b>shuffle 文件不影响判定，继续留在 NM</b>"]
        IDLE --> KILL
    end

    subgraph S5["阶段5 · 清理（双路径）"]
        direction LR
        CLEAN_A["A. 逻辑清理<br/>ContextCleaner.doCleanupShuffle()<br/>(弱引用 GC + 30min 定时兜底)"]
        CLEAN_B["B. 物理清理<br/>app 结束 → YARN NM DeletionService<br/>删 appcache/&lt;appId&gt;/<br/><b>非 ESS 删</b>"]
    end

    DEP -- "submitMapStage" --> WRITE
    WRITE -- "BlockManager.registerWithExternalShuffleServer" --> REG
    REG --> READ
    READ --> IDLE
    KILL --> CLEAN_A
    KILL --> CLEAN_B
    DEP -.弱引用.-> CLEAN_A

    class SQL,DEP driver
    class WRITE exec
    class REG,READ ess
    class IDLE,KILL exec
    class CLEAN_A clean
    class CLEAN_B yarn
```

### 3.2 阶段总表（兜底速查）

| # | 阶段 | 主体 | 关键动作 | 物理位置 |
|---|---|---|---|---|
| 1a | 产生（Driver）| `ShuffleExchangeExec` / `ShuffleDependency` | 分配 shuffleId、注册 shuffleManager、**注册到 ContextCleaner（弱引用）** | Driver JVM |
| 1b | 写盘（Executor）| `ShuffleWriter` | 写 `shuffle_{id}_{mapId}_0.{data,index}` | NM `appcache/<appId>/blockmgr-*/` |
| 2 | 注册到 ESS | Executor `BlockManager` → ESS | 把 `localDirs` 注册进 ESS LevelDB（NM 重启可恢复）| ESS 内存 + LevelDB |
| 3 | 读取 | reduce task → ESS | `OpenBlocks` 直接读盘，**不过原 executor JVM** | ESS 进程内 |
| 4 | DRA 回收 | `ExecutorMonitor` + `ExecutorAllocationManager` | idle 满 60s 即杀，**不看是否有 shuffle 文件** | YARN container |
| 5a | 逻辑清理 | `ContextCleaner` | 弱引用入队 → `doCleanupShuffle` → 各 BlockManager 内部 unregister；30min 定时 GC 兜底 | Driver + executor 进程内 |
| 5b | 物理清理 | YARN NM DeletionService | app 结束删 `appcache/<appId>/` | NM 磁盘 |

---

## 四、逐阶段源码追踪

### 阶段 1：Shuffle 产生（SQL → ShuffleDependency）

SQL 物理计划中的 `ShuffleExchangeExec` 持有一个惰性的 `shuffleDependency`，AQE 下通过 `submitMapStage` 提交 map 阶段：

```166:179:sql/core/src/main/scala/org/apache/spark/sql/execution/exchange/ShuffleExchangeExec.scala
  @transient
  lazy val shuffleDependency : ShuffleDependency[Int, InternalRow, InternalRow] = {
    val dep = ShuffleExchangeExec.prepareShuffleDependency(
      inputRDD,
      child.output,
      outputPartitioning,
      serializer,
      writeMetrics)
    metrics("numPartitions").set(dep.partitioner.numPartitions)
    ...
    dep
  }
```

`ShuffleDependency` 构造时即完成三件事：分配 `shuffleId`、向 `ShuffleManager` 注册拿到 `ShuffleHandle`、**注册到 ContextCleaner（弱引用，为阶段 5-A 埋点）**：

```96:99:core/src/main/scala/org/apache/spark/Dependency.scala
  val shuffleId: Int = _rdd.context.newShuffleId()

  val shuffleHandle: ShuffleHandle = _rdd.context.env.shuffleManager.registerShuffle(
    shuffleId, this)
```

```177:178:core/src/main/scala/org/apache/spark/Dependency.scala
  _rdd.sparkContext.cleaner.foreach(_.registerShuffleForCleanup(this))
  _rdd.sparkContext.shuffleDriverComponents.registerShuffle(shuffleId)
```

map task 执行时由 `SortShuffleManager` 的 `ShuffleWriter` 把数据写成 `shuffle_{shuffleId}_{mapId}_0.data` + `.index`，落在 executor 的 `localDirs`。YARN 模式下 `localDirs` 即 `usercache/<user>/appcache/<appId>/blockmgr-*`——**物理上就在 NM 管理的目录里**，这是阶段 5-B 的伏笔。

### 阶段 2：Shuffle 注册到 ESS

executor 启动时通过 `BlockManager.registerWithExternalShuffleServer` 把自己的 `localDirs`、`subDirsPerLocalDir`、shuffleManager 注册给 ESS：

```143:159:common/network-shuffle/src/main/java/org/apache/spark/network/shuffle/ExternalShuffleBlockResolver.java
  public void registerExecutor(
      String appId,
      String execId,
      ExecutorShuffleInfo executorInfo) {
    AppExecId fullId = new AppExecId(appId, execId);
    logger.info("Registered executor {} with {}", fullId, executorInfo);
    try {
      if (db != null) {
        byte[] key = dbAppExecKey(fullId);
        byte[] value = mapper.writeValueAsString(executorInfo).getBytes(StandardCharsets.UTF_8);
        db.put(key, value);
      }
    } catch (Exception e) {
      logger.error("Error saving registered executors", e);
    }
    executors.put(fullId, executorInfo);
  }
```

注册信息写入 LevelDB（`registeredExecutors.ldb`），NM 重启后可 `reloadRegisteredExecutors` 恢复（L452-472），保证 NM 滚动重启不丢 shuffle 路由。**注册完成后，"如何找到这份 shuffle 文件"这件事 ESS 已经完全掌握，与 executor 进程是否存活无关。**

### 阶段 3：Shuffle 读取（reduce 端，跨越 executor 生死）

reduce task 从 `MapOutputTracker` 拿到 map output 的位置（`BlockManagerId` 指向 ESS 的 host:port），向 ESS 发 `OpenBlocks`，ESS 直接读盘返回文件片段：

```305:323:common/network-shuffle/src/main/java/org/apache/spark/network/shuffle/ExternalShuffleBlockResolver.java
  private ManagedBuffer getSortBasedShuffleBlockData(
    ExecutorShuffleInfo executor, int shuffleId, long mapId, int startReduceId, int endReduceId) {
    File indexFile = ExecutorDiskUtils.getFile(executor.localDirs, executor.subDirsPerLocalDir,
      "shuffle_" + shuffleId + "_" + mapId + "_0.index");
    try {
      ShuffleIndexInformation shuffleIndexInformation = shuffleIndexCache.get(indexFile);
      ShuffleIndexRecord shuffleIndexRecord = shuffleIndexInformation.getIndex(
        startReduceId, endReduceId);
      return new FileSegmentManagedBuffer(
        conf,
        ExecutorDiskUtils.getFile(executor.localDirs, executor.subDirsPerLocalDir,
          "shuffle_" + shuffleId + "_" + mapId + "_0.data"),
        shuffleIndexRecord.getOffset(),
        shuffleIndexRecord.getLength());
    } catch (ExecutionException e) {
      throw new RuntimeException("Failed to open file: " + indexFile, e);
    }
  }
```

**关键：整个读路径只依赖注册时记录的 `localDirs` + 磁盘上的文件，完全不经过产生该 shuffle 的 executor JVM。** 这正是 ESS 让 DRA 敢杀 executor 的底层支撑。

### 阶段 4：DRA 回收 executor（核心）

`ExecutorAllocationManager` 每 100ms 调度一次，取出超时 executor 并请求集群管理器杀掉：

```340:351:core/src/main/scala/org/apache/spark/ExecutorAllocationManager.scala
  private def schedule(): Unit = synchronized {
    val executorIdsToBeRemoved = executorMonitor.timedOutExecutors()
    if (executorIdsToBeRemoved.nonEmpty) {
      initializing = false
    }
    updateAndSyncNumExecutorsTarget(clock.nanoTime())
    if (executorIdsToBeRemoved.nonEmpty) {
      removeExecutors(executorIdsToBeRemoved)
    }
  }
```

"谁超时"由 `ExecutorMonitor.timedOutExecutors()` 决定，过滤条件中包含 `!exec.hasActiveShuffle`：

```118:133:core/src/main/scala/org/apache/spark/scheduler/dynalloc/ExecutorMonitor.scala
      timedOutExecs = executors.asScala
        .filter { case (_, exec) =>
          !exec.pendingRemoval && !exec.hasActiveShuffle && !exec.decommissioning}
        .filter { case (_, exec) =>
          val deadline = exec.timeoutAt
          if (deadline > now) {
            newNextTimeout = math.min(newNextTimeout, deadline)
            exec.timedOut = false
            false
          } else {
            exec.timedOut = true
            true
          }
        }
        .map { case (name, exec) => (name, exec.resourceProfileId)}
        .toSeq
```

**`hasActiveShuffle` 是否会被置 true？看 `onTaskEnd`：**

```329:333:core/src/main/scala/org/apache/spark/scheduler/dynalloc/ExecutorMonitor.scala
      if (shuffleTrackingEnabled && event.reason == Success) {
        stageToShuffleID.get(event.stageId).foreach { shuffleId =>
          exec.addShuffle(shuffleId)
        }
      }
```

> **开了 ESS ⇒ `shuffleTrackingEnabled=false` ⇒ 永远不会 `addShuffle` ⇒ `hasActiveShuffle` 恒为 false。**
> 而且 `Tracker.shuffleIds` 在不开 tracking 时直接是 `null`（L547：`if (shuffleTrackingEnabled) new mutable.HashSet[Int]() else null`）。

再看超时时长的计算 `updateTimeout()`：

```557:570:core/src/main/scala/org/apache/spark/scheduler/dynalloc/ExecutorMonitor.scala
    def updateTimeout(): Unit = {
      val oldDeadline = timeoutAt
      val newDeadline = if (idleStart >= 0) {
        val timeout = if (cachedBlocks.nonEmpty || (shuffleIds != null && shuffleIds.nonEmpty)) {
          val _cacheTimeout = if (cachedBlocks.nonEmpty) storageTimeoutNs else Long.MaxValue
          val _shuffleTimeout = if (shuffleIds != null && shuffleIds.nonEmpty) {
            shuffleTimeoutNs
          } else {
            Long.MaxValue
          }
          math.min(_cacheTimeout, _shuffleTimeout)
        } else {
          idleTimeoutNs
        }
```

**开 ESS 时，`shuffleIds=null`，`cachedBlocks`（若无 cache）也为空 ⇒ `timeout = idleTimeoutNs`（`spark.dynamicAllocation.executorIdleTimeout`，默认 60s）。**

> 即：开 ESS 后，一个 executor 只要空闲满 60s 就会被 DRA 回收，**不管它上面写了多少 GB 的 shuffle 文件**。Shuffle 文件随它"留守"在 NM 上，由 ESS 继续服务。

**对照组（不开 ESS、开 shuffleTracking）**：`onJobStart`/`onJobEnd`（L201-306）维护 `shuffleToActiveJobs`，`onTaskEnd` 会 `addShuffle` 把 `hasActiveShuffle` 置 true。这种 executor 在 shuffle 仍被 active job 引用期间**不会**被选入 `timedOutExecs`，从而避免丢数据；只有当所有引用该 shuffle 的 job 结束、且空闲超过 `shuffleTrackingTimeout`（默认 `Long.MaxValue`）后才可回收。这正是没有 ESS 时 DRA 能勉强工作的"实验性"机制。

最后 `removeExecutors` 受下限保护（`minNumExecutors` / `numExecutorsTarget`），再走 `killExecutors` 或 `decommissionExecutors`：

```556:567:core/src/main/scala/org/apache/spark/ExecutorAllocationManager.scala
        if (newExecutorTotal - 1 < minNumExecutors) {
          logDebug(s"Not removing idle executor $executorIdToBeRemoved because there " +
            s"are only $newExecutorTotal executor(s) left (minimum number of executor limit " +
            s"$minNumExecutors)")
        } else if (newExecutorTotal - 1 < numExecutorsTargetPerResourceProfileId(rpId)) {
          ...
        } else {
          executorIdsToBeRemoved += executorIdToBeRemoved
          numExecutorsTotalPerRpId(rpId) -= 1
        }
```

### 阶段 5：Shuffle 清理（两条独立路径）

#### 路径 A：逻辑清理 —— Driver 端 ContextCleaner（shuffle 不再被引用）

`ShuffleDependency` 对象不再被任何存活的 RDD/Stage 引用后变为弱可达，弱引用进入 `referenceQueue`，清理线程触发 `doCleanupShuffle`：

```234:248:core/src/main/scala/org/apache/spark/ContextCleaner.scala
  def doCleanupShuffle(shuffleId: Int, blocking: Boolean): Unit = {
    try {
      if (mapOutputTrackerMaster.containsShuffle(shuffleId)) {
        logDebug("Cleaning shuffle " + shuffleId)
        mapOutputTrackerMaster.unregisterShuffle(shuffleId)
        shuffleDriverComponents.removeShuffle(shuffleId, blocking)
        listeners.asScala.foreach(_.shuffleCleaned(shuffleId))
        logDebug("Cleaned shuffle " + shuffleId)
      } else {
        logDebug("Asked to cleanup non-existent shuffle (maybe it was already removed)")
      }
    } catch {
      case e: Exception => logError("Error cleaning shuffle " + shuffleId, e)
    }
  }
```

为防止 driver 长期不 GC 导致 shuffle 文件堆积，ContextCleaner 还有定时 `System.gc()` 兜底（`spark.cleaner.periodicGC.interval`，默认 30min）：

```131:132:core/src/main/scala/org/apache/spark/ContextCleaner.scala
    periodicGCService.scheduleAtFixedRate(() => System.gc(),
      periodicGCInterval, periodicGCInterval, TimeUnit.SECONDS)
```

`removeShuffle` 会经由 `BlockManagerMaster` 通知各端删除该 shuffle 的物理文件（含 ESS 注册的目录中对应文件）。

#### 路径 B：物理清理 —— executor / app 退出

**Standalone 模式**（`ExternalShuffleService`，Worker 进程内）：
- executor 退出 → `executorRemoved` → **只删非 shuffle/RDD 文件，保留 `.data`/`.index`**：

```245:260:common/network-shuffle/src/main/java/org/apache/spark/network/shuffle/ExternalShuffleBlockResolver.java
  public void executorRemoved(String executorId, String appId) {
    logger.info("Clean up non-shuffle and non-RDD files associated with the finished executor {}",
      executorId);
    AppExecId fullId = new AppExecId(appId, executorId);
    final ExecutorShuffleInfo executor = executors.get(fullId);
    if (executor == null) {
      logger.info("Executor is not registered (appId={}, execId={})", appId, executorId);
    } else {
      ...
      directoryCleaner.execute(() -> deleteNonShuffleServiceServedFiles(executor.localDirs));
    }
  }
```

```281:286:common/network-shuffle/src/main/java/org/apache/spark/network/shuffle/ExternalShuffleBlockResolver.java
  private void deleteNonShuffleServiceServedFiles(String[] dirs) {
    FilenameFilter filter = (dir, name) -> {
      // Don't delete shuffle data, shuffle index files or cached RDD files.
      return !name.endsWith(".index") && !name.endsWith(".data")
        && (!rddFetchEnabled || !name.startsWith("rdd_"));
    };
```

- app 退出 → `applicationRemoved(appId, true)`（standalone 传 `true`）→ `deleteExecutorDirs` 删整个 localDirs。

**YARN 模式（线上主流）—— 反直觉**：ESS 是 NM 的 auxiliary service `YarnShuffleService`：

```354:373:common/network-yarn/src/main/java/org/apache/spark/network/yarn/YarnShuffleService.java
  @Override
  public void stopApplication(ApplicationTerminationContext context) {
    String appId = context.getApplicationId().toString();
    try {
      if (isAuthenticationEnabled()) {
        ...
        secretManager.unregisterApp(appId);
      }
      blockHandler.applicationRemoved(appId, false /* clean up local dirs */);
    } catch (Exception e) {
      logger.error("Exception when stopping application {}", appId, e);
    }
  }
```

```381:385:common/network-yarn/src/main/java/org/apache/spark/network/yarn/YarnShuffleService.java
  @Override
  public void stopContainer(ContainerTerminationContext context) {
    ContainerId containerId = context.getContainerId();
    logger.info("Stopping container {}", containerId);
  }
```

> - `stopContainer`（即 executor 容器退出，含被 DRA 杀掉）：**只打日志，不删任何文件**，也不调 `executorRemoved`。
> - `stopApplication`：调 `applicationRemoved(appId, **false**)`——**传 false，不清理 local dirs**，只清 auth secret。
>
> **那么 YARN 模式下 shuffle 文件由谁物理删除？** 答案是 **YARN NodeManager 自己的 DeletionService**：当 application 结束，NM 按 `yarn.nodemanager.delete.debug-delay-sec` 删除 `usercache/<user>/appcache/<appId>/` 整个目录（shuffle 文件就在其中的 `blockmgr-*` 子目录）。**ESS 不负责按 app 删盘，它依赖 YARN 的 appcache 生命周期。**

这正解释了为什么 DRA 频繁回收 executor 不会导致 shuffle 文件提前被删：文件按 **app 维度** 由 NM 管理，与 **container 维度** 的 executor 生死无关。

---

## 五、关键参数表

| 参数 | 默认 | 作用阶段 | 说明 |
|---|---|---|---|
| `spark.dynamicAllocation.enabled` | false | 全局 | 开 DRA |
| `spark.shuffle.service.enabled` | false | 全局 | 开 ESS；与 shuffleTracking 互斥（见第二节）|
| `spark.dynamicAllocation.executorIdleTimeout` | 60s | 阶段4 | **开 ESS 后 executor 回收的唯一时钟**（无 cache 时）|
| `spark.dynamicAllocation.cachedExecutorIdleTimeout` | Infinity | 阶段4 | 持有 cache block 的 executor idle 超时 |
| `spark.dynamicAllocation.shuffleTracking.enabled` | false | 阶段4 | 仅 **不开 ESS** 时生效 |
| `spark.dynamicAllocation.shuffleTracking.timeout` | Long.MaxValue | 阶段4 | shuffleTracking 下 shuffle 空闲超时 |
| `spark.dynamicAllocation.minExecutors` | 0 | 阶段4 | 回收下限保护 |
| `spark.shuffle.service.fetch.rdd.enabled` | false | 阶段3/5 | ESS 是否也服务持久化到磁盘的 RDD block |
| `spark.cleaner.periodicGC.interval` | 30min | 阶段5-A | ContextCleaner 定时 GC 兜底 |
| `spark.shuffle.service.db.enabled` | true | 阶段2 | ESS 用 LevelDB 持久化注册信息，支持 NM 重启恢复 |

### 5.1 关键参数源码三件套（定义 / 默认值 / 引入版本）

> 文档纪律：提到任何参数必须配源码引用，避免"凭印象写默认值"。所有引用基于 `txproject/spark`（腾讯 fork，分支 `gaotu-3.2.1` / Spark 3.2.1）。

#### `spark.dynamicAllocation.executorIdleTimeout` —— 默认 **60s**，引入 1.2.0

```611:616:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val DYN_ALLOCATION_EXECUTOR_IDLE_TIMEOUT =
    ConfigBuilder("spark.dynamicAllocation.executorIdleTimeout")
      .version("1.2.0")
      .timeConf(TimeUnit.SECONDS)
      .checkValue(_ >= 0L, "Timeout must be >= 0.")
      .createWithDefault(60)
```

#### `spark.dynamicAllocation.cachedExecutorIdleTimeout` —— 默认 **Integer.MAX_VALUE 秒**（实际就是"永不超时"），引入 1.4.0

```603:609:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val DYN_ALLOCATION_CACHED_EXECUTOR_IDLE_TIMEOUT =
    ConfigBuilder("spark.dynamicAllocation.cachedExecutorIdleTimeout")
      .version("1.4.0")
      .timeConf(TimeUnit.SECONDS)
      .checkValue(_ >= 0L, "Timeout must be >= 0.")
      .createWithDefault(Integer.MAX_VALUE)
```

#### `spark.dynamicAllocation.shuffleTracking.enabled` —— 默认 **false**，引入 3.0.0

```618:622:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val DYN_ALLOCATION_SHUFFLE_TRACKING_ENABLED =
    ConfigBuilder("spark.dynamicAllocation.shuffleTracking.enabled")
      .version("3.0.0")
      .booleanConf
      .createWithDefault(false)
```

#### `spark.dynamicAllocation.shuffleTracking.timeout` —— 默认 **Long.MaxValue 毫秒**（永不超时），引入 3.0.0

```624:629:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val DYN_ALLOCATION_SHUFFLE_TRACKING_TIMEOUT =
    ConfigBuilder("spark.dynamicAllocation.shuffleTracking.timeout")
      .version("3.0.0")
      .timeConf(TimeUnit.MILLISECONDS)
      .checkValue(_ >= 0L, "Timeout must be >= 0.")
      .createWithDefault(Long.MaxValue)
```

#### `spark.shuffle.service.enabled` —— 默认 **false**，引入 1.2.0

```656:660:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val SHUFFLE_SERVICE_ENABLED =
    ConfigBuilder("spark.shuffle.service.enabled")
      .version("1.2.0")
      .booleanConf
      .createWithDefault(false)
```

#### `spark.shuffle.service.fetch.rdd.enabled` —— 默认 **false**，引入 3.0.0

```662:670:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val SHUFFLE_SERVICE_FETCH_RDD_ENABLED =
    ConfigBuilder(Constants.SHUFFLE_SERVICE_FETCH_RDD_ENABLED)
      .doc("Whether to use the ExternalShuffleService for fetching disk persisted RDD blocks. " +
        "In case of dynamic allocation if this feature is enabled executors having only disk " +
        "persisted blocks are considered idle after " +
        "'spark.dynamicAllocation.executorIdleTimeout' and will be released accordingly.")
      .version("3.0.0")
      .booleanConf
      .createWithDefault(false)
```

> 注意 `ConfigBuilder` 的 key 来自 `Constants.SHUFFLE_SERVICE_FETCH_RDD_ENABLED`（`common/network-shuffle/src/main/java/org/apache/spark/network/shuffle/Constants.java`，常量值即 `spark.shuffle.service.fetch.rdd.enabled`）—— 这是 driver 端 Scala config 与 ESS 端 Java/Netty 共享同一个 key，避免双方写错的设计。

#### `spark.shuffle.service.db.enabled` —— 默认 **true**，引入 3.0.0

```672:678:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val SHUFFLE_SERVICE_DB_ENABLED =
    ConfigBuilder("spark.shuffle.service.db.enabled")
      .doc("Whether to use db in ExternalShuffleService. Note that this only affects " +
        "standalone mode.")
      .version("3.0.0")
      .booleanConf
      .createWithDefault(true)
```

#### `spark.shuffle.service.port` —— 默认 **7337**，引入 1.2.0

```680:681:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val SHUFFLE_SERVICE_PORT =
    ConfigBuilder("spark.shuffle.service.port").version("1.2.0").intConf.createWithDefault(7337)
```

#### `spark.shuffle.service.name` —— 默认 **`spark_shuffle`**，引入 3.2.0

```683:691:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val SHUFFLE_SERVICE_NAME =
    ConfigBuilder("spark.shuffle.service.name")
      .doc("The configured name of the Spark shuffle service the client should communicate with. " +
        "This must match the name used to configure the Shuffle within the YARN NodeManager " +
        "configuration (`yarn.nodemanager.aux-services`). Only takes effect when " +
        s"$SHUFFLE_SERVICE_ENABLED is set to true.")
      .version("3.2.0")
      .stringConf
      .createWithDefault("spark_shuffle")
```

> 与 `yarn-site.xml` 里 `yarn.nodemanager.aux-services=mapreduce_shuffle,spark_shuffle` 配置一一对应，名字必须一致才能被 RPC 路由到。

#### `spark.storage.decommission.shuffleBlocks.enabled` —— 默认 **false**，引入 3.1.0

```430:436:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val STORAGE_DECOMMISSION_SHUFFLE_BLOCKS_ENABLED =
    ConfigBuilder("spark.storage.decommission.shuffleBlocks.enabled")
      .doc("Whether to transfer shuffle blocks during block manager decommissioning. Requires " +
        "a migratable shuffle resolver (like sort based shuffle)")
      .version("3.1.0")
      .booleanConf
      .createWithDefault(false)
```

> 与 `spark.decommission.enabled` / `spark.storage.decommission.enabled` 配套使用，是 K8s/对象存储路线下"不靠 ESS、靠迁移 shuffle 块"机制的核心开关，详见上一份《SPARK-37618 演进》文档。

#### `spark.cleaner.periodicGC.interval` —— 默认 **30min**，引入 1.6.0

```1641:1645:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val CLEANER_PERIODIC_GC_INTERVAL =
    ConfigBuilder("spark.cleaner.periodicGC.interval")
      .version("1.6.0")
      .timeConf(TimeUnit.SECONDS)
      .createWithDefaultString("30min")
```

> 这是 ContextCleaner 的兜底节奏。3.2.1 下"shuffle 不被引用 → 弱引用入队"等驱动 GC 才能触发，所以这个 30min 既是清理上限延迟、也是 driver full GC 频率（每个 interval 都会主动 `System.gc()`）。

#### `spark.cleaner.referenceTracking.blocking.shuffle` —— 默认 **false**

```1659:1663:core/src/main/scala/org/apache/spark/internal/config/package.scala
  private[spark] val CLEANER_REFERENCE_TRACKING_BLOCKING_SHUFFLE =
    ConfigBuilder("spark.cleaner.referenceTracking.blocking.shuffle")
      .version("1.1.1")
      .booleanConf
      .createWithDefault(false)
```

> SPARK-3139 历史问题导致默认 false（异步清理），如果调成 true 可能在 broadcast 高频清理场景下 RPC 超时，谨慎使用。

---

## 六、Challenger 审查报告

```
🔍 Challenger 审查报告
━━━━━━━━━━━━━━━━━━━━━━
📋 审查对象: spark-sql + DRA + ESS Shuffle 生命周期源码分析（基于 gaotu-3.2.1）
🔎 审查结果: CONDITIONAL（核心结论 APPROVED，2 项跨模块结论标注待验证）

━━━ 证据质疑 ━━━
🟢 疑点1（已消除）: "开 ESS 后 shuffle 不阻塞 executor 回收"是否仅凭推测？
   证据: ExecutorMonitor L52-55（shuffleTrackingEnabled=!ESS&&tracking）
        + L329（onTaskEnd 仅在 shuffleTrackingEnabled 时 addShuffle）
        + L547（shuffleIds 在不开 tracking 时为 null）
        + L557-570（updateTimeout 此时落到 idleTimeoutNs）。
        四处源码交叉印证，链条闭合，非推测。

🟢 疑点2（已消除）: ESS 读 shuffle 是否真的不经过原 executor？
   证据: ExternalShuffleBlockResolver.getSortBasedShuffleBlockData L305-323
        只用注册时的 localDirs 直接读盘，无 RPC 到原 executor。

🟡 疑点3（待验证）: "YARN 模式物理删除靠 NM DeletionService 删 appcache" 这一结论，
   在本仓库（spark 源码）内只能证明"ESS 不删"（stopContainer/stopApplication 不删盘），
   "NM DeletionService 删 appcache" 属于 hadoop-yarn 侧逻辑，不在本仓库。
   需要: 在 hadoop 源码（ContainerLaunch / DeletionService / LocalDirsHandlerService）
        或线上 NM 日志验证 appcache 删除时机。标注【待验证-跨仓库】。

━━━ 逻辑质疑 ━━━
🟡 逻辑点1（待验证）: doCleanupShuffle → shuffleDriverComponents.removeShuffle 最终是否
   会向 ESS 发删除请求删掉 NM 上的 .data/.index？本次未追到 BlockManagerMaster →
   ESS RemoveBlocks 的完整链路。结论"路径A会删物理文件"标注【待验证】，
   不影响"路径B（app结束）兜底删除"的主结论。

━━━ 遗漏项 ━━━
⚠️ 未覆盖: Push-based shuffle（magnet / ESS merged shuffle，Dependency.scala L103-175 有
   mergerLocs/shuffleMergeId 等字段）的生命周期未展开，3.2.1 下默认关闭，本文聚焦经典 ESS。

━━━ 安全审查 ━━━
🟢 SAFE: 本文为源码静态分析，无任何生产变更操作。
🟢 SAFE: 涉及的参数均为只读说明，未给出"上生产改配置"的建议。

━━━ 裁决 ━━━
CONDITIONAL —— 主干生命周期（阶段1~4 + 阶段5-B）证据链完整、源码可逐行复核，APPROVED；
阶段5-A 的物理删除链路、YARN appcache 删除时机两项跨模块结论标注【待验证】，
不影响"DRA 回收 executor 不丢 shuffle、文件按 app 维度生命周期管理"的核心结论成立。
下一步（如需）: 追 BlockManagerMaster→ESS 删除链路 + hadoop NM DeletionService 佐证。
```

---

## 七、核心源码索引（便于复核）

| 阶段 | 类 / 文件 | 关键行 |
|---|---|---|
| 前置约束 | `ExecutorAllocationManager.scala` | 206-218（强制 ESS）|
| 互斥开关 | `ExecutorMonitor.scala` | 52-55 |
| 产生-SQL | `ShuffleExchangeExec.scala` | 166-179 |
| 产生-注册清理 | `Dependency.scala` | 96-99 / 177-178 |
| ESS 注册 | `ExternalShuffleBlockResolver.java` | 143-159 / 452-472 |
| ESS 读取 | `ExternalShuffleBlockResolver.java` | 305-323 |
| DRA 调度 | `ExecutorAllocationManager.scala` | 340-351 / 538-615 |
| DRA 超时判定 | `ExecutorMonitor.scala` | 108-137 / 329-333 / 547 / 557-586 |
| 清理-逻辑 | `ContextCleaner.scala` | 131-132 / 161-163 / 234-248 |
| 清理-物理(standalone) | `ExternalShuffleBlockResolver.java` | 245-260 / 281-298 / 212-239 |
| 清理-物理(YARN) | `YarnShuffleService.java` | 354-373 / 381-385 |
