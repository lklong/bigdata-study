# S01-NameNode 启动流程与安全模式源码分析

> **组件版本**: Apache Hadoop 3.x (基于 txProjects/hadoop 源码)
> **源码路径**: `hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/`
> **核心类**: `NameNode`、`FSNamesystem`、`SafeModeInfo`、`SafeModeMonitor`
> **分析日期**: 2026-04-27

---

## 一、问题/场景

### 1.1 核心问题
- NameNode 从 `main()` 方法启动到对外提供服务，经历了哪些关键步骤？
- FSImage 和 EditLog 是如何加载和回放的？
- 安全模式（Safe Mode）的进入和退出条件是什么？
- 为什么 NameNode 启动后不能立即处理写请求？

### 1.2 典型生产场景
- NameNode 重启后长时间处于安全模式，集群不可写
- 大集群启动时安全模式退出耗时过长
- HA 场景下 Active/Standby 切换时安全模式的行为

---

## 二、调用链总览

```
NameNode.main()
  └── StringUtils.startupShutdownMessage()
  └── NameNode.createNameNode(argv, null)
        └── HdfsConfiguration() // 加载配置
        └── parseArguments(argv) // 解析启动参数
        └── switch(startOpt):
            case FORMAT: → format() → terminate()
            case BOOTSTRAPSTANDBY: → BootstrapStandby.run()
            default:
              └── DefaultMetricsSystem.initialize("NameNode")
              └── new NameNode(conf)
                    └── NameNode(conf, NamenodeRole.NAMENODE)
                          ├── createHAState(startOpt) // 确定 HA 状态
                          ├── initializeGenericKeys(conf, nsId, namenodeId)
                          └── initialize(conf)
                          │     ├── loginAsNameNodeUser(conf) // Kerberos 认证
                          │     ├── NameNode.initMetrics(conf, role)
                          │     ├── JvmPauseMonitor.start()
                          │     ├── startHttpServer(conf) // 启动 HTTP 服务
                          │     ├── loadNamesystem(conf)
                          │     │     └── FSNamesystem.loadFromDisk(conf)
                          │     │           ├── new FSImage(conf, dirs, editsDirs)
                          │     │           ├── new FSNamesystem(conf, fsImage, false)
                          │     │           │     └── new BlockManager(this, conf)
                          │     │           │     └── new FSDirectory(this, conf)
                          │     │           │     └── new SafeModeInfo(conf) ★
                          │     │           └── namesystem.loadFSImage(startOpt)
                          │     │                 └── fsImage.recoverTransitionRead() // 加载 FSImage + 回放 EditLog
                          │     │                 └── fsImage.saveNamespace() // 如需要则持久化
                          │     ├── createRpcServer(conf) // 创建 RPC 服务
                          │     └── startCommonServices(conf)
                          │           └── namesystem.startCommonServices(conf, haContext)
                          │                 ├── checkAvailableResources()
                          │                 ├── setBlockTotal(completeBlocksTotal) ★ 触发安全模式检查
                          │                 └── blockManager.activate(conf) // 激活 BlockManager
                          │           └── rpcServer.start() // RPC 开始对外服务
                          └── state.prepareToEnterState(haContext)
                          └── state.enterState(haContext) // 进入 Active/Standby 状态
  └── namenode.join() // 等待进程结束
```

---

## 三、核心源码分析

### 3.1 NameNode.main() 入口

```java
// 文件: NameNode.java, 行 1687-1702
public static void main(String argv[]) throws Exception {
    if (DFSUtil.parseHelpArgument(argv, NameNode.USAGE, System.out, true)) {
      System.exit(0);
    }
    try {
      StringUtils.startupShutdownMessage(NameNode.class, argv, LOG);
      NameNode namenode = createNameNode(argv, null);
      if (namenode != null) {
        namenode.join();
      }
    } catch (Throwable e) {
      LOG.error("Failed to start namenode.", e);
      terminate(1, e);
    }
}
```

**设计意图**: 入口极简，核心逻辑委托给 `createNameNode()`。`join()` 方法阻塞主线程，等待 NameNode 进程结束。

### 3.2 createNameNode() — 启动参数分发

```java
// 文件: NameNode.java, 行 1549-1629
public static NameNode createNameNode(String argv[], Configuration conf)
    throws IOException {
    LOG.info("createNameNode " + Arrays.asList(argv));
    if (conf == null)
      conf = new HdfsConfiguration();
    GenericOptionsParser hParser = new GenericOptionsParser(conf, argv);
    argv = hParser.getRemainingArgs();
    StartupOption startOpt = parseArguments(argv);
    if (startOpt == null) {
      printUsage(System.err);
      return null;
    }
    setStartupOption(conf, startOpt);

    switch (startOpt) {
      case FORMAT: {
        boolean aborted = format(conf, startOpt.getForceFormat(),
            startOpt.getInteractiveFormat());
        terminate(aborted ? 1 : 0);
        return null;
      }
      case BOOTSTRAPSTANDBY: {
        String toolArgs[] = Arrays.copyOfRange(argv, 1, argv.length);
        int rc = BootstrapStandby.run(toolArgs, conf);
        terminate(rc);
        return null;
      }
      case ROLLBACK: {
        boolean aborted = doRollback(conf, true);
        terminate(aborted ? 1 : 0);
        return null;
      }
      // ... 其他启动选项
      default: {
        DefaultMetricsSystem.initialize("NameNode");
        return new NameNode(conf);
      }
    }
}
```

**设计意图**: `createNameNode()` 实际上是一个 **命令分发器**，根据启动选项（`-format`、`-bootstrapStandby`、`-rollback` 等）执行不同逻辑。默认情况下（`default` 分支），创建并返回 `NameNode` 实例。

### 3.3 NameNode 构造函数 — 核心初始化链

```java
// 文件: NameNode.java, 行 888-922
protected NameNode(Configuration conf, NamenodeRole role)
    throws IOException {
    this.tracer = new Tracer.Builder("NameNode").
        conf(TraceUtils.wrapHadoopConf(NAMENODE_HTRACE_PREFIX, conf)).
        build();
    this.conf = conf;
    this.role = role;
    setClientNamenodeAddress(conf);
    String nsId = getNameServiceId(conf);
    String namenodeId = HAUtil.getNameNodeId(conf, nsId);
    this.haEnabled = HAUtil.isHAEnabled(conf, nsId);
    state = createHAState(getStartupOption(conf));      // ★ 决定 Active/Standby
    this.allowStaleStandbyReads = HAUtil.shouldAllowStandbyReads(conf);
    this.haContext = createHAContext();
    try {
      initializeGenericKeys(conf, nsId, namenodeId);
      initialize(conf);                                  // ★ 核心初始化
      try {
        haContext.writeLock();
        state.prepareToEnterState(haContext);
        state.enterState(haContext);                      // ★ 进入 HA 状态
      } finally {
        haContext.writeUnlock();
      }
    } catch (IOException e) {
      this.stopAtException(e);
      throw e;
    }
    this.started.set(true);
}
```

**关键逻辑**:
1. **HA 状态决定**: `createHAState()` 根据是否启用 HA 和启动选项决定初始状态
   - 未启用 HA → `ACTIVE_STATE`
   - 启用 HA → `STANDBY_STATE`（默认以 Standby 启动，后续由 ZKFC 触发切换为 Active）

2. **initialize(conf)**: 真正的初始化入口，下文详述

3. **enterState()**: 进入目标 HA 状态，如果是 Active 则触发 `startActiveServices()`

### 3.4 initialize() — 启动核心流程

```java
// 文件: NameNode.java, 行 673-714
protected void initialize(Configuration conf) throws IOException {
    UserGroupInformation.setConfiguration(conf);
    loginAsNameNodeUser(conf);                    // 1. Kerberos 登录

    NameNode.initMetrics(conf, this.getRole());   // 2. 初始化 Metrics
    StartupProgressMetrics.register(startupProgress);

    pauseMonitor = new JvmPauseMonitor(conf);     // 3. JVM 暂停监控
    pauseMonitor.start();
    metrics.getJvmMetrics().setPauseMonitor(pauseMonitor);

    if (NamenodeRole.NAMENODE == role) {
      startHttpServer(conf);                      // 4. 启动 HTTP 服务 (Web UI)
    }

    loadNamesystem(conf);                         // 5. ★ 加载命名空间（FSImage + EditLog）

    rpcServer = createRpcServer(conf);            // 6. 创建 RPC 服务

    if (NamenodeRole.NAMENODE == role) {
      httpServer.setNameNodeAddress(getNameNodeAddress());
      httpServer.setFSImage(getFSImage());
    }

    startCommonServices(conf);                    // 7. ★ 启动公共服务（安全模式入口）
    startMetricsLogger(conf);                     // 8. Metrics 日志
}
```

**启动顺序的设计意图**:
1. **先认证后服务**: Kerberos 认证在最前面，确保后续操作有合法身份
2. **先加载后对外**: `loadNamesystem()` 完成元数据加载后才创建 RPC 服务
3. **HTTP 先于 RPC**: Web UI 先启动便于运维观察启动进度
4. **startCommonServices 最后**: 在所有准备就绪后才激活 BlockManager 和安全模式检查

### 3.5 loadNamesystem() — 元数据加载

```java
// 文件: NameNode.java, 行 634-636
protected void loadNamesystem(Configuration conf) throws IOException {
    this.namesystem = FSNamesystem.loadFromDisk(conf);
}
```

委托给 `FSNamesystem.loadFromDisk()`：

```java
// 文件: FSNamesystem.java, 行 693-721
static FSNamesystem loadFromDisk(Configuration conf) throws IOException {
    checkConfiguration(conf);
    FSImage fsImage = new FSImage(conf,
        FSNamesystem.getNamespaceDirs(conf),
        FSNamesystem.getNamespaceEditsDirs(conf));
    FSNamesystem namesystem = new FSNamesystem(conf, fsImage, false);
    StartupOption startOpt = NameNode.getStartupOption(conf);
    if (startOpt == StartupOption.RECOVER) {
      namesystem.setSafeMode(SafeModeAction.SAFEMODE_ENTER);
    }

    long loadStart = monotonicNow();
    try {
      namesystem.loadFSImage(startOpt);                // ★ 加载 FSImage
    } catch (IOException ioe) {
      LOG.warn("Encountered exception loading fsimage", ioe);
      fsImage.close();
      throw ioe;
    }
    long timeTakenToLoadFSImage = monotonicNow() - loadStart;
    LOG.info("Finished loading FSImage in " + timeTakenToLoadFSImage + " msecs");
    NameNodeMetrics nnMetrics = NameNode.getNameNodeMetrics();
    if (nnMetrics != null) {
      nnMetrics.setFsImageLoadTime((int) timeTakenToLoadFSImage);
    }
    namesystem.getFSDirectory().createReservedStatuses(namesystem.getCTime());
    return namesystem;
}
```

**关键点**:
- `FSNamesystem` 构造函数中创建了 `BlockManager`、`FSDirectory`、`SafeModeInfo`
- `loadFSImage()` 负责实际的 FSImage 加载和 EditLog 回放

### 3.6 loadFSImage() — FSImage 加载与 EditLog 回放

```java
// 文件: FSNamesystem.java, 行 1029-1076
private void loadFSImage(StartupOption startOpt) throws IOException {
    final FSImage fsImage = getFSImage();

    if (startOpt == StartupOption.FORMAT) {
      fsImage.format(this, fsImage.getStorage().determineClusterId());
      startOpt = StartupOption.REGULAR;
    }
    boolean success = false;
    writeLock();
    try {
      MetaRecoveryContext recovery = startOpt.createRecoveryContext();
      final boolean staleImage
          = fsImage.recoverTransitionRead(startOpt, this, recovery);  // ★ 核心！
      if (RollingUpgradeStartupOption.ROLLBACK.matches(startOpt) ||
          RollingUpgradeStartupOption.DOWNGRADE.matches(startOpt)) {
        rollingUpgradeInfo = null;
      }
      final boolean needToSave = staleImage && !haEnabled && !isRollingUpgrade();
      LOG.info("Need to save fs image? " + needToSave
          + " (staleImage=" + staleImage + ", haEnabled=" + haEnabled
          + ", isRollingUpgrade=" + isRollingUpgrade() + ")");
      if (needToSave) {
        fsImage.saveNamespace(this);              // EditLog 回放后合并保存
      }
      if (!haEnabled || (haEnabled && startOpt == StartupOption.UPGRADE)
          || (haEnabled && startOpt == StartupOption.UPGRADEONLY)) {
        fsImage.openEditLogForWrite(getEffectiveLayoutVersion());
      }
      success = true;
    } finally {
      if (!success) {
        fsImage.close();
      }
      writeUnlock("loadFSImage");
    }
    imageLoadComplete();
}
```

**核心流程**:
1. **`fsImage.recoverTransitionRead()`**: 这是最关键的调用，内部执行：
   - 加载最新的 FSImage（从 `fsimage_*` 文件中反序列化整个命名空间）
   - 回放所有 EditLog（将 FSImage 之后的操作逐条重放）
   - 返回值 `staleImage` 表示 FSImage 是否过时（有大量 EditLog 需要回放）

2. **条件保存**: 如果 `staleImage=true` 且非 HA 模式，则立即保存合并后的 FSImage（减少下次启动时间）

3. **EditLog 打开**: 非 HA 模式下打开 EditLog 准备写入新的操作

### 3.7 FSNamesystem 构造函数中的关键初始化

```java
// 文件: FSNamesystem.java, 行 739-904 (关键片段)
FSNamesystem(Configuration conf, FSImage fsImage, boolean ignoreRetryCache)
    throws IOException {
    // ...
    this.fsImage = fsImage;
    this.blockManager = new BlockManager(this, conf);        // ★ 块管理器
    this.datanodeStatistics = blockManager.getDatanodeManager().getDatanodeStatistics();
    this.blockIdManager = new BlockIdManager(blockManager);

    this.dir = new FSDirectory(this, conf);                  // ★ 目录树
    this.snapshotManager = new SnapshotManager(dir);
    this.cacheManager = new CacheManager(this, conf, blockManager);
    this.safeMode = new SafeModeInfo(conf);                  // ★ 安全模式初始化
    // ...
}
```

---

## 四、安全模式 (Safe Mode) 深度分析

### 4.1 SafeModeInfo 数据结构

```java
// 文件: FSNamesystem.java, 行 4346-4428
public class SafeModeInfo {
    // 配置字段
    private final double threshold;          // 安全模式阈值（默认 0.999）
    private final int datanodeThreshold;     // 最少存活 DataNode 数（默认 0）
    private volatile int extension;          // 阈值达到后的延迟时间（毫秒，默认 0）
    private final int safeReplication;       // 安全副本数（默认 = dfs.namenode.replication.min）
    private final double replQueueThreshold; // 复制队列填充阈值

    // 运行时状态
    private long reached = -1;       // -1=安全模式关闭, 0=开启但未达阈值, >0=达到阈值的时间
    private long reachedTimestamp = -1;
    int blockTotal;                  // 总块数
    int blockSafe;                   // 安全块数（副本数 >= safeReplication）
    private int blockThreshold;      // 安全块阈值 = blockTotal * threshold
    private int blockReplQueueThreshold; // 复制队列阈值
    private volatile boolean resourcesLow = false;

    private SafeModeInfo(Configuration conf) {
        this.threshold = conf.getFloat(DFS_NAMENODE_SAFEMODE_THRESHOLD_PCT_KEY,
            DFS_NAMENODE_SAFEMODE_THRESHOLD_PCT_DEFAULT);       // 默认 0.999
        this.datanodeThreshold = conf.getInt(
            DFS_NAMENODE_SAFEMODE_MIN_DATANODES_KEY,
            DFS_NAMENODE_SAFEMODE_MIN_DATANODES_DEFAULT);       // 默认 0
        this.extension = conf.getInt(DFS_NAMENODE_SAFEMODE_EXTENSION_KEY, 0);
        this.safeReplication = conf.getInt(
            DFS_NAMENODE_SAFEMODE_REPLICATION_MIN_KEY, minReplication); // 默认 1
        this.replQueueThreshold = conf.getFloat(
            DFS_NAMENODE_REPL_QUEUE_THRESHOLD_PCT_KEY, (float) threshold);
        this.blockTotal = 0;
        this.blockSafe = 0;
    }
}
```

### 4.2 安全模式的进入条件

```java
// 文件: FSNamesystem.java, 行 4570-4574
private boolean needEnter() {
    return (threshold != 0 && blockSafe < blockThreshold) ||
      (datanodeThreshold != 0 && getNumLiveDataNodes() < datanodeThreshold) ||
      (!nameNodeHasResourcesAvailable());
}
```

**三个条件（OR 关系，任一满足即需要安全模式）**:
1. **块安全比例不足**: `blockSafe < blockThreshold`（即安全块数 < 总块数 × 阈值）
2. **存活 DataNode 不足**: 存活 DataNode 数 < 配置的最小值
3. **资源不足**: NameNode 本地磁盘空间不足

### 4.3 安全模式的退出流程

```java
// 文件: FSNamesystem.java, 行 4548-4564
private synchronized boolean canLeave() {
    if (reached == 0) {       // 阈值还未到达
      return false;
    }
    if (monotonicNow() - reached < extension) {  // 延迟期未到
      reportStatus("STATE* Safe mode ON, in safe mode extension.", false);
      return false;
    }
    if (needEnter()) {        // 条件仍然满足
      reportStatus("STATE* Safe mode ON, thresholds not met.", false);
      return false;
    }
    return true;
}
```

**退出需要同时满足**:
1. `reached > 0`: 安全块阈值已经到达过
2. 延迟期已过: `monotonicNow() - reached >= extension`
3. 不再需要进入: `!needEnter()`

### 4.4 checkMode() — 安全模式状态机核心

```java
// 文件: FSNamesystem.java, 行 4579-4621
private void checkMode() {
    assert hasWriteLock();
    if (inTransitionToActive()) {
      return;
    }
    // 如果 SafeModeMonitor 线程还未启动，且需要进入安全模式
    if (smmthread == null && needEnter()) {
      enter();
      if (canInitializeReplQueues() && !blockManager.isPopulatingReplQueues()
          && !haEnabled) {
        blockManager.initializeReplQueues();
      }
      reportStatus("STATE* Safe mode ON.", false);
      return;
    }
    // 安全模式已关闭，或不需要等待
    if (!isOn() || extension <= 0 || threshold <= 0) {
      this.leave(false);
      return;
    }
    if (reached > 0) {  // 阈值已经到达过
      reportStatus("STATE* Safe mode ON.", false);
      return;
    }
    // 首次到达阈值，启动 SafeModeMonitor
    reached = monotonicNow();
    reachedTimestamp = now();
    if (smmthread == null) {
      smmthread = new Daemon(new SafeModeMonitor());
      smmthread.start();
      reportStatus("STATE* Safe mode extension entered.", true);
    }
    if (canInitializeReplQueues() && !blockManager.isPopulatingReplQueues() && !haEnabled) {
      blockManager.initializeReplQueues();
    }
}
```

### 4.5 SafeModeMonitor — 周期性检查退出

```java
// 文件: FSNamesystem.java, 行 4852-4886
class SafeModeMonitor implements Runnable {
    private static final long recheckInterval = 1000;  // 每秒检查一次

    @Override
    public void run() {
      while (fsRunning) {
        writeLock();
        try {
          if (safeMode == null) {     // 已退出安全模式
            break;
          }
          if (safeMode.canLeave()) {  // 可以退出
            safeMode.leave(false);
            smmthread = null;
            break;
          }
        } finally {
          writeUnlock();
        }
        try {
          Thread.sleep(recheckInterval);
        } catch (InterruptedException ie) {}
      }
    }
}
```

### 4.6 安全模式退出时的 leave() 方法

```java
// 文件: FSNamesystem.java, 行 4487-4531
private synchronized void leave(boolean force) {
    // 初始化复制队列
    if (!blockManager.isPopulatingReplQueues() && blockManager.shouldPopulateReplQueues()) {
      blockManager.initializeReplQueues();
    }

    // 检查是否有 future blocks
    if (!force && (blockManager.getBytesInFuture() > 0)) {
      LOG.error("Refusing to leave safe mode without a force flag...");
      return;
    }

    long timeInSafemode = now() - startTime;
    NameNode.stateChangeLog.info("STATE* Leaving safe mode after "
                                  + timeInSafemode/1000 + " secs");
    
    if (reached >= 0) {
      NameNode.stateChangeLog.info("STATE* Safe mode is OFF");
    }
    reached = -1;
    reachedTimestamp = -1;
    safeMode = null;              // ★ 置空表示退出安全模式

    // 日志输出网络拓扑信息
    final NetworkTopology nt = blockManager.getDatanodeManager().getNetworkTopology();
    NameNode.stateChangeLog.info("STATE* Network topology has "
        + nt.getNumOfRacks() + " racks and "
        + nt.getNumOfLeaves() + " datanodes");
    NameNode.stateChangeLog.info("STATE* UnderReplicatedBlocks has "
        + blockManager.numOfUnderReplicatedBlocks() + " blocks");

    startSecretManagerIfNecessary();

    // 结束启动进度追踪
    StartupProgress prog = NameNode.getStartupProgress();
    if (prog.getStatus(Phase.SAFEMODE) != Status.COMPLETE) {
      prog.endStep(Phase.SAFEMODE, STEP_AWAITING_REPORTED_BLOCKS);
      prog.endPhase(Phase.SAFEMODE);
    }
}
```

---

## 五、startCommonServices — 安全模式激活触发点

```java
// 文件: FSNamesystem.java, 行 1108-1137
void startCommonServices(Configuration conf, HAContext haContext) throws IOException {
    this.registerMBean();
    writeLock();
    this.haContext = haContext;
    try {
      nnResourceChecker = new NameNodeResourceChecker(conf);
      checkAvailableResources();
      assert safeMode != null && !blockManager.isPopulatingReplQueues();
      StartupProgress prog = NameNode.getStartupProgress();
      prog.beginPhase(Phase.SAFEMODE);
      long completeBlocksTotal = getCompleteBlocksTotal();
      prog.setTotal(Phase.SAFEMODE, STEP_AWAITING_REPORTED_BLOCKS, completeBlocksTotal);
      setBlockTotal(completeBlocksTotal);          // ★ 设置总块数，触发安全模式检查
      blockManager.activate(conf);                 // ★ 激活 BlockManager
    } finally {
      writeUnlock("startCommonServices");
    }
    // ...
}
```

**关键**: `setBlockTotal()` 调用后，`SafeModeInfo.checkMode()` 被触发，这是安全模式真正开始工作的时刻。`blockManager.activate()` 启动了 DataNode 心跳处理、块报告处理等后台线程。

---

## 六、Block 报告与安全模式关系

当 DataNode 向 NameNode 发送块报告时：
1. NameNode 处理每个 Block 报告
2. 对于每个有效 Block，调用 `addStoredBlock()`
3. 当 Block 的副本数从 `safeReplication-1` 增加到 `safeReplication` 时
4. 触发 `SafeModeInfo.incrementSafeBlockCount()`

```java
// 文件: FSNamesystem.java, 行 4647-4663
private synchronized void incrementSafeBlockCount(short replication) {
    if (replication == safeReplication) {
      this.blockSafe++;
      StartupProgress prog = NameNode.getStartupProgress();
      if (prog.getStatus(Phase.SAFEMODE) != Status.COMPLETE) {
        if (this.awaitingReportedBlocksCounter == null) {
          this.awaitingReportedBlocksCounter = prog.getCounter(Phase.SAFEMODE,
            STEP_AWAITING_REPORTED_BLOCKS);
        }
        this.awaitingReportedBlocksCounter.increment();
      }
      checkMode();    // ★ 每次增加都检查是否可以退出安全模式
    }
}
```

---

## 七、安全模式状态机时序图

```
时间线
│
├── NameNode 启动
│   └── FSNamesystem 构造: new SafeModeInfo(conf)
│       └── reached = -1 (安全模式 OFF)
│
├── loadFSImage()
│   └── 加载 FSImage + 回放 EditLog
│   └── 构建内存中的 blockTotal
│
├── startCommonServices()
│   └── setBlockTotal(completeBlocksTotal)
│       └── blockThreshold = blockTotal * threshold (如: 1000 * 0.999 = 999)
│       └── checkMode()
│           └── needEnter() = true (blockSafe=0 < blockThreshold=999)
│           └── enter(): reached = 0 (安全模式 ON)
│
├── blockManager.activate()
│   └── 开始接收 DataNode 心跳和块报告
│
├── DataNode 块报告阶段
│   ├── Block 1 报告 → incrementSafeBlockCount → blockSafe=1 → checkMode()
│   ├── Block 2 报告 → incrementSafeBlockCount → blockSafe=2 → checkMode()
│   ├── ...
│   └── Block 999 报告 → incrementSafeBlockCount → blockSafe=999 → checkMode()
│       └── blockSafe(999) >= blockThreshold(999)
│       └── reached = monotonicNow() (记录到达时间)
│       └── 启动 SafeModeMonitor 线程
│
├── SafeModeMonitor 周期检查 (每秒一次)
│   ├── canLeave() → false (extension 延迟期未到)
│   ├── canLeave() → false (extension 延迟期未到)
│   └── canLeave() → true (延迟期已过 && !needEnter())
│       └── leave(false)
│           └── initializeReplQueues() (初始化副本复制队列)
│           └── safeMode = null (安全模式 OFF)
│           └── LOG: "STATE* Safe mode is OFF"
│
└── NameNode 开始正常处理读写请求
```

---

## 八、关键参数与调优建议

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `dfs.namenode.safemode.threshold-pct` | 0.999 | 安全块比例阈值 | 大集群可适当降低到 0.99 |
| `dfs.namenode.safemode.min.datanodes` | 0 | 最少存活 DataNode 数 | 生产建议设置为 1 |
| `dfs.namenode.safemode.extension` | 0 | 阈值达到后的等待时间(ms) | 大集群建议 30000ms |
| `dfs.namenode.replication.min` | 1 | 最小安全副本数 | 通常不改 |
| `dfs.namenode.safemode.replication.min` | = replication.min | 安全模式最小副本数 | 专家级参数，慎改 |
| `dfs.namenode.repl.queue.threshold-pct` | = threshold | 复制队列填充阈值 | 可设低于 threshold 提前开始复制 |

### 调优场景

**场景 1: 大集群启动安全模式退出慢**
```xml
<!-- 降低阈值，加快退出 -->
<property>
  <name>dfs.namenode.safemode.threshold-pct</name>
  <value>0.99</value>
</property>
<!-- 减少等待时间 -->
<property>
  <name>dfs.namenode.safemode.extension</name>
  <value>10000</value>
</property>
```

**场景 2: 强制退出安全模式**
```bash
hdfs dfsadmin -safemode leave
# 如果有 future blocks:
hdfs dfsadmin -safemode forceExit
```

**场景 3: NameNode 反复进入安全模式（资源不足）**
```bash
# 检查 NameNode 本地磁盘空间
df -h <namenode.name.dir>
# 清理日志或扩容磁盘后重启
```

---

## 九、踩坑记录

### 坑 1: safeMode 对象为 null 的含义
`FSNamesystem` 中 `safeMode` 字段为 `null` 表示**不在安全模式**，而不是"安全模式对象不存在"。`leave()` 方法中 `safeMode = null` 正是退出安全模式的标志。

### 坑 2: HA 场景下 Standby 的安全模式
Standby NameNode **始终处于安全模式**。在 `shouldIncrementallyTrackBlocks` 标志的控制下，Standby 会增量追踪块数变化（通过 `adjustBlockTotals`），但不会退出安全模式。

### 坑 3: extension=0 的快速退出
如果 `extension=0`（默认值），阈值一旦到达，`checkMode()` 中直接调用 `leave()` 而**不启动 SafeModeMonitor 线程**：
```java
if (!isOn() || extension <= 0 || threshold <= 0) {
    this.leave(false);
    return;
}
```

### 坑 4: future blocks 阻止退出
如果 `blockManager.getBytesInFuture() > 0`（存在 generation stamp 超前的块），`leave(false)` 会拒绝退出。这通常发生在 NameNode 元数据被手动替换后。需要使用 `hdfs dfsadmin -safemode forceExit` 强制退出。

---

## 十、认知更新

1. **安全模式是渐进式退出**: 不是一个开关，而是通过 `blockSafe` 逐步积累到阈值的过程
2. **SafeModeMonitor 只在有 extension 时才启动**: `extension=0` 时直接在 `checkMode()` 中同步退出
3. **安全模式期间 NameNode 可读不可写**: 所有写操作都会检查 `checkNameNodeSafeMode()` 并抛出 `SafeModeException`
4. **手动安全模式设置了不可能达到的阈值**: `threshold=1.5f` 确保永远不会自动退出，只能通过 `dfsadmin -safemode leave` 手动退出
5. **startCommonServices 是安全模式的真正起点**: `setBlockTotal()` 调用触发首次 `checkMode()`，开始安全模式流程
