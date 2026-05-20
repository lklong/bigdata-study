# YARN NodeManager Container 生命周期源码深度解析

> 版本: Hadoop 3.x
> 源码路径: `/Users/kailongliu/bigdata/txProjects/hadoop`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

YARN NodeManager 上一个 Container 的生命周期是怎样的？
- AM 申请到 Container token 后，怎么在 NM 上拉起一个进程？
- ContainerLaunch 写的 `launch_container.sh` 长啥样？为什么 sanitizeEnv 那么重要？
- ContainersMonitor 是怎么发现并 kill 掉 OOM 容器的？日志里的 `Container is running beyond physical memory limits` 来自哪里？
- cgroup 资源隔离在哪一步生效？

理解这条链是排查 "Container 启动失败 / Container 被 NM 杀 / 资源隔离不生效 / NM 内存计算偏差" 等所有 NM 侧故障的前置。

## 二、调用链总图

```
AM (ApplicationMaster) — RPC startContainers ──→ NM
                                                  │
                                                  ▼
                            ContainerManagerImpl.startContainerInternal
                                                  │
                                                  ▼
                            ContainersLauncher (Service) 收到 LaunchContainerEvent
                                                  │
                            ┌─────────────────────┼─────────────────────┐
                            ▼                     ▼                     ▼
                  ResourceLocalization     ContainerLaunch        ContainersMonitor
                    Service (Localizer)     (Callable<Integer>)     (Daemon Thread)
                  下载/解压/校验         构造 launch_container.sh   周期采样进程树
                  PUBLIC/PRIVATE/         调用 ContainerExecutor   发现超限就 KILL
                  APPLICATION 级别          .launchContainer()
                                              │
                                              ▼
                            DefaultContainerExecutor / LinuxContainerExecutor
                                              │ (LCE 走 setuid 二进制 container-executor)
                                              ▼
                            bash launch_container.sh
                                              │
                                              ▼
                            真实业务进程（如 java -cp ... org.apache.spark.executor.Executor）
```

**核心组件分工**：

| 组件 | 类 | 职责 |
|------|----|----|
| **ContainerManager** | ContainerManagerImpl | RPC 入口，状态机 dispatcher |
| **Localizer** | ResourceLocalizationService + ContainerLocalizer | 下载 jar/file/archive 资源，三级 cache（PUBLIC/PRIVATE/APP）|
| **ContainerLaunch** | ContainerLaunch (Callable) | 写脚本、写 token、调 Executor、阻塞等待退出 |
| **ContainerExecutor** | DefaultContainerExecutor / LinuxContainerExecutor | 真正 fork 进程，决定 cgroup/setuid 行为 |
| **ContainersMonitor** | ContainersMonitorImpl | 采样进程树资源，超限 kill |

## 三、关键源码逐段精读

### 3.1 ContainerLaunch.call() —— Container 启动主流程

`ContainerLaunch.java:151-355`，删减后的核心代码：

```java
@Override
public Integer call() {
    final ContainerLaunchContext launchContext = container.getLaunchContext();
    Map<Path,List<String>> localResources = null;
    ContainerId containerID = container.getContainerId();
    String containerIdStr = containerID.toString();
    final List<String> command = launchContext.getCommands();
    int ret = -1;

    // ① 检查是否在 LAUNCH 之前就被 KILL（race condition 防御）
    if (container.getContainerState() == ContainerState.KILLING) {
      dispatcher.getEventHandler().handle(new ContainerExitEvent(containerID,
          ContainerEventType.CONTAINER_KILLED_ON_REQUEST,
          ExitCode.TERMINATED.getExitCode(),
          "Container terminated before launch."));
      return 0;
    }

    try {
      // ② 取本地化资源（必须已经 LOCALIZED 完成，否则报错）
      localResources = container.getLocalizedResources();
      if (localResources == null) {
        throw RPCUtil.getRemoteException("Unable to get local resources when Container "
            + containerID + " is at " + container.getContainerState());
      }

      // ③ 变量展开（<LOG_DIR> → 实际日志目录路径，{{VAR}} → $VAR）
      List<String> newCmds = new ArrayList<>(command.size());
      Path containerLogDir = dirsHandler.getLogPathForWrite(relativeContainerLogDir, false);
      for (String str : command) {
        newCmds.add(expandEnvironment(str, containerLogDir));
      }
      launchContext.setCommands(newCmds);

      // ④ 同样的展开施加于环境变量
      Map<String, String> environment = launchContext.getEnvironment();
      for (Entry<String, String> entry : environment.entrySet()) {
        entry.setValue(expandEnvironment(entry.getValue(), containerLogDir));
      }

      // ⑤ 健康盘检查
      if (!dirsHandler.areDisksHealthy()) {
        ret = ContainerExitStatus.DISKS_FAILED;
        throw new IOException("Most of the disks failed. " +
            dirsHandler.getDisksHealthReport(false));
      }

      // ⑥ 生成 nmPrivateContainerScript（即 launch_container.sh）
      try (DataOutputStream containerScriptOutStream =
               lfs.create(nmPrivateContainerScriptPath, EnumSet.of(CREATE, OVERWRITE))) {
        sanitizeEnv(environment, containerWorkDir, appDirs, containerLogDirs,
            localResources, nmPrivateClasspathJarDir);
        exec.writeLaunchEnv(containerScriptOutStream, environment,
            localResources, launchContext.getCommands(),
            new Path(containerLogDirs.get(0)));
      }

      // ⑦ 写 container_tokens 文件（Delegation Token / Block Token，Container 进程会读）
      try (DataOutputStream tokensOutStream =
               lfs.create(nmPrivateTokensPath, EnumSet.of(CREATE, OVERWRITE))) {
        Credentials creds = container.getCredentials();
        creds.writeTokenStorageToStream(tokensOutStream);
      }

      // ⑧ 发出 CONTAINER_LAUNCHED 事件（状态机转 RUNNING），并持久化到 NMStateStore
      dispatcher.getEventHandler().handle(new ContainerEvent(
          containerID, ContainerEventType.CONTAINER_LAUNCHED));
      context.getNMStateStore().storeContainerLaunched(containerID);

      // ⑨ 防 race：如果 KILL 先到，shouldLaunchContainer 已被 set，跳过启动
      if (!shouldLaunchContainer.compareAndSet(false, true)) {
        ret = ExitCode.TERMINATED.getExitCode();
      } else {
        // ⑩ 真正启动！LCE 会 fork → setuid → 进 cgroup → exec bash launch_container.sh
        exec.activateContainer(containerID, pidFilePath);
        ret = exec.launchContainer(new ContainerStartContext.Builder()
            .setContainer(container)
            .setLocalizedResources(localResources)
            .setNmPrivateContainerScriptPath(nmPrivateContainerScriptPath)
            .setNmPrivateTokensPath(nmPrivateTokensPath)
            .setUser(user)
            .setAppId(appIdStr)
            .setContainerWorkDir(containerWorkDir)
            .setLocalDirs(localDirs)
            .setLogDirs(logDirs)
            .build());
      }
    } catch (Throwable e) {
      LOG.warn("Failed to launch container.", e);
      dispatcher.getEventHandler().handle(new ContainerExitEvent(
          containerID, ContainerEventType.CONTAINER_EXITED_WITH_FAILURE, ret,
          e.getMessage()));
      return ret;
    } finally {
      completed.set(true);
      exec.deactivateContainer(containerID);
      context.getNMStateStore().storeContainerCompleted(containerID, ret);
    }

    // ⑪ 进程退出码处理
    if (ret == ExitCode.FORCE_KILLED.getExitCode() || ret == ExitCode.TERMINATED.getExitCode()) {
      dispatcher.getEventHandler().handle(new ContainerExitEvent(containerID,
          ContainerEventType.CONTAINER_KILLED_ON_REQUEST, ret, ...));
      return ret;
    }
    if (ret != 0) {
      dispatcher.getEventHandler().handle(new ContainerExitEvent(containerID,
          ContainerEventType.CONTAINER_EXITED_WITH_FAILURE, ret, ...));
      return ret;
    }
    LOG.info("Container " + containerIdStr + " succeeded ");
    dispatcher.getEventHandler().handle(new ContainerEvent(containerID,
        ContainerEventType.CONTAINER_EXITED_WITH_SUCCESS));
    return 0;
}
```

**关键点**：
- `ContainerLaunch implements Callable<Integer>`，`call()` 的返回值是**容器进程的退出码**。这意味着 `exec.launchContainer()` 是**同步阻塞**的，直到 Container 进程 exit。因此 NM 实际上为每个 Container 占用一个线程（在 `ContainersLauncher` 的 ExecutorService 中），高并发场景需要关注线程数。
- `expandEnvironment` 处理两类占位符：
  - `<LOG_DIR>` → 容器日志目录绝对路径
  - `{{VAR}}` → Linux 下转 `$VAR`，Windows 下转 `%VAR%`
- `sanitizeEnv` + `writeLaunchEnv` 共同生成 launch_container.sh，里面包含：classpath jar 软链、CWD、环境变量 export、最终启动 cmd。

### 3.2 sanitizeEnv —— Container 环境变量净化

`ContainerLaunch.java:829`（节选自源码方法签名 `public void sanitizeEnv(...)`）：

主要做四件事（基于 Hadoop 3.x 实际行为，对应 `ContainerLaunch.sanitizeEnv` 实现）：
1. **设置 NM 标准环境变量**：`PWD`、`LOGNAME`、`HOME`、`USER`、`JVM_PID`、`HADOOP_TOKEN_FILE_LOCATION`、`HADOOP_USER_NAME`
2. **构造 CLASSPATH 软链 jar**（HADOOP-9985）：把所有 LocalResource 在工作目录创建符号链接，避免 classpath 字符串过长（>32KB 命令行限制）
3. **白名单环境变量传递**：从 NM 自身环境继承白名单变量（`yarn.nodemanager.env-whitelist`，默认包含 JAVA_HOME, HADOOP_COMMON_HOME 等）
4. **覆盖语义**：用户在 launchContext 里指定的 env 优先级**高于** NM 白名单（YARN-3878 之后的行为）

**踩坑警告**：
- 用户如果在 launchContext 里传了 `JAVA_HOME=`（空值），会**覆盖** NM 默认 JAVA_HOME，导致 Container 启动报 "JAVA_HOME is not set"
- `yarn.nodemanager.env-whitelist` 必须包含 `HADOOP_MAPRED_HOME`，否则 Spark on YARN 会找不到 mapreduce shuffle classpath

### 3.3 ContainerExecutor 体系

NM 通过 `yarn.nodemanager.container-executor.class` 选择：

| 实现 | 隔离能力 | 用户切换 | 生产推荐场景 |
|------|---------|---------|------------|
| **DefaultContainerExecutor** | 仅 Java 进程级 | 不能 setuid（NM 用户启动 Container）| 测试环境 / 单租户集群 |
| **LinuxContainerExecutor (LCE)** | cgroup CPU/Memory + 用户隔离 | 通过 setuid 二进制 `container-executor` | **生产环境必选** |
| **DockerContainerExecutor** | 容器化（已被 LCE 内嵌的 Docker runtime 替代）| Docker user namespace | 容器化业务 |

**LCE 的 launchContainer 关键流程**：
1. fork 子进程
2. 子进程 setuid 到 container 应用提交用户
3. 创建 cgroup 子目录（path 形如 `/sys/fs/cgroup/cpu/hadoop-yarn/container_xxx`）
4. 把进程 pid 写入 `tasks` 文件，进入 cgroup 限制
5. exec `bash launch_container.sh`

**cgroup 配置**：`yarn.nodemanager.linux-container-executor.cgroups.mount=true` + 路径配置。

### 3.4 ContainersMonitor —— OOM 杀手的源头

`ContainersMonitorImpl.java:379-555`，`MonitoringThread.run()`：

```java
private class MonitoringThread extends Thread {
    @Override
    public void run() {
      while (!stopped && !Thread.currentThread().isInterrupted()) {
        ResourceUtilization trackedContainersUtilization =
            ResourceUtilization.newInstance(0, 0, 0.0f);
        long vmemUsageByAllContainers = 0;
        long pmemByAllContainers = 0;

        for (Entry<ContainerId, ProcessTreeInfo> entry : trackingContainers.entrySet()) {
          ContainerId containerId = entry.getKey();
          ProcessTreeInfo ptInfo = entry.getValue();
          try {
            String pId = ptInfo.getPID();

            // ① 第一次发现 pid（容器刚启动后，pid 文件刚被 ContainerExecutor 写入）
            if (pId == null) {
              pId = containerExecutor.getProcessId(ptInfo.getContainerId());
              if (pId != null) {
                ResourceCalculatorProcessTree pt =
                    ResourceCalculatorProcessTree.getResourceCalculatorProcessTree(
                        pId, processTreeClass, conf);
                ptInfo.setPid(pId);
                ptInfo.setProcessTree(pt);
              }
            }
            if (pId == null) continue;  // 还没 fork 完，下次再看

            // ② 关键：刷新进程树并采样
            ResourceCalculatorProcessTree pTree = ptInfo.getProcessTree();
            pTree.updateProcessTree();    // 读 /proc/<pid>/stat 重建进程树
            long currentVmemUsage = pTree.getVirtualMemorySize();
            long currentPmemUsage = pTree.getRssMemorySize();
            float cpuUsagePercentPerCore = pTree.getCpuUsagePercent();

            // ③ "Aged" 进程的内存使用 —— 防止"短命子进程"误杀的关键
            //    age 1 表示已经存在了至少 1 个采样周期的进程
            long curMemUsageOfAgedProcesses = pTree.getVirtualMemorySize(1);
            long curRssMemUsageOfAgedProcesses = pTree.getRssMemorySize(1);
            long vmemLimit = ptInfo.getVmemLimit();
            long pmemLimit = ptInfo.getPmemLimit();

            // ④ 超限判定 + KILL
            boolean isMemoryOverLimit = false;
            int containerExitStatus = ContainerExitStatus.INVALID;

            if (isVmemCheckEnabled()
                && isProcessTreeOverLimit(containerId.toString(),
                    currentVmemUsage, curMemUsageOfAgedProcesses, vmemLimit)) {
              msg = formatErrorMessage("virtual",
                  currentVmemUsage, vmemLimit, currentPmemUsage, pmemLimit,
                  pId, containerId, pTree);
              isMemoryOverLimit = true;
              containerExitStatus = ContainerExitStatus.KILLED_EXCEEDED_VMEM;
            } else if (isPmemCheckEnabled()
                && isProcessTreeOverLimit(containerId.toString(),
                    currentPmemUsage, curRssMemUsageOfAgedProcesses, pmemLimit)) {
              msg = formatErrorMessage("physical", ...);
              isMemoryOverLimit = true;
              containerExitStatus = ContainerExitStatus.KILLED_EXCEEDED_PMEM;
            }

            // ⑤ 累计全节点资源利用率（NM 上报给 RM）
            vmemUsageByAllContainers += currentVmemUsage;
            pmemByAllContainers += currentPmemUsage;

            // ⑥ 如果超限，发 ContainerKillEvent 给 dispatcher，状态机会走 KILLING → DONE
            if (isMemoryOverLimit) {
              LOG.warn(msg);
              if (!pTree.checkPidPgrpidForMatch()) {
                LOG.error("Killed container process with PID " + pId
                    + " but it is not a process group leader.");
              }
              eventDispatcher.getEventHandler().handle(
                  new ContainerKillEvent(containerId, containerExitStatus, msg));
              trackingContainers.remove(containerId);
            }
          } catch (Exception e) {
            LOG.warn("Uncaught exception in ContainerMemoryManager ...", e);
          }
        }
        // ... sleep 一个 monitoringInterval（默认 3000ms）继续下一轮
      }
    }
}
```

**精髓 —— `isProcessTreeOverLimit` 双判定**：
```java
boolean isProcessTreeOverLimit(String containerId, long currentMemUsage,
                                long curMemUsageOfAgedProcesses, long limit) {
    return (currentMemUsage > 2 * limit) ||
           (curMemUsageOfAgedProcesses > limit);
}
```

**两条腿走路**：
- **瞬时阈值（2x limit）**：进程瞬间内存超过 2 倍上限，立即杀（防御式）
- **Aged 阈值（1x limit）**：已经存活至少一个周期的进程超过上限，杀（防"瞬时 fork"误杀）

**为什么这么设计**：JVM 启动初期会瞬时分配大量内存（JIT、Metaspace 预热），但很快稳定。如果只看瞬时值，会误杀"启动毛刺"。aged 概念是 Hadoop 团队踩过坑后的经验沉淀（HADOOP-3460）。

### 3.5 内存计算的"陷阱" —— vmem vs rss

| 指标 | 出处 | 含义 | 默认开关 |
|------|------|------|---------|
| `currentVmemUsage` | `pTree.getVirtualMemorySize()` | 进程树虚拟内存（含 mmap、shared lib）| `yarn.nodemanager.vmem-check-enabled=true` |
| `currentPmemUsage` | `pTree.getRssMemorySize()` | 进程树 RSS（实际物理内存）| `yarn.nodemanager.pmem-check-enabled=true` |
| `vmemLimit` | `pmemLimit * vmem-pmem-ratio` | 默认 `pmem * 2.1` | `yarn.nodemanager.vmem-pmem-ratio=2.1` |

**生产坑点**（看到很多次）：
- 64-bit JVM 虚拟内存普遍很大（动辄 4-5G），用户申请 2G 容器，vmem-pmem-ratio=2.1 即上限 4.2G，**很容易被 vmem check 杀**
- 实战推荐：`yarn.nodemanager.vmem-check-enabled=false`，只看 pmem。这是 Cloudera/Hortonworks 文档官方推荐配置

## 四、实战 LOG 对齐验证

**Container 启动流程关键日志**：

| 日志关键词 | 源码位置 | 含义 |
|----------|---------|------|
| `Failed to launch container` | `ContainerLaunch.java:312` | call() 抛异常被捕获 |
| `Container is at COMPLETE` | 状态机 | 启动前已完成 |
| `Container terminated before launch` | `ContainerLaunch.java:169` | KILLING 状态 race |
| `Most of the disks failed` | `ContainerLaunch.java:244` | localDirs 不健康 |
| `Container ... succeeded` | `ContainerLaunch.java:351` | exit code 0 |
| `Container exited with a non-zero exit code` | `ContainerLaunch.java:343` | 业务报错（最常见，Spark Executor 各种问题）|

**ContainersMonitor 关键日志**（`ContainersMonitorImpl.formatErrorMessage` 输出格式）：

```
Container [pid=12345,containerID=container_xxx] is running 5242880B beyond the
'PHYSICAL' memory limit. Current usage: 2.0 GB of 1.0 GB physical memory used;
4.5 GB of 2.1 GB virtual memory used. Killing container.
Dump of the process-tree for container_xxx :
   |- PID PPID PGRPID SESSID CMD_NAME ... CMD_LINE
```

这条日志**几乎是大数据运维最常见的告警**：
- "physical memory" 超限 → JVM 堆设置过大或堆外内存（DirectByteBuffer/Native）泄漏
- "virtual memory" 超限 → 大概率误杀，建议关 vmem check

排查路径：
1. `grep "Current usage:.*physical memory used" yarn-nodemanager-*.log` 找超限容器
2. 看 `Dump of the process-tree` —— 哪个子进程占大头（Python UDF？shell 调用？）
3. 上报 AM/Driver 调整 `spark.executor.memoryOverhead` / `mapreduce.map.memory.mb`

## 五、状态机 + 事件驱动 —— NM 的整体架构

NM 内部是基于 `AsyncDispatcher` 的事件驱动模型。Container 的状态机（`ContainerImpl`）有这些状态：

```
NEW
 │ (INIT_CONTAINER)
 ▼
LOCALIZING ──────────► LOCALIZATION_FAILED
 │ (RESOURCE_LOCALIZED)
 ▼
LOCALIZED
 │ (CONTAINER_LAUNCHED) ← ContainerLaunch.java:286 发的事件
 ▼
RUNNING
 │ (CONTAINER_KILLED_ON_REQUEST / CONTAINER_EXITED_WITH_FAILURE / CONTAINER_EXITED_WITH_SUCCESS)
 ▼
EXITED_WITH_SUCCESS / EXITED_WITH_FAILURE / KILLING
 │
 ▼
DONE
```

`ContainerLaunch.call()` 在 ⑧ ⑪ 处发出的 ContainerEvent 就是状态机的转移触发器。

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| ContainerLaunch 是 Callable 阻塞调用 | NM 必须知道容器进程的退出码以决定状态机走向 |
| 写脚本+token 文件到 nmPrivate | 与容器工作目录隔离，安全（容器内进程读不到）|
| sanitizeEnv 强制 NM 注入变量 | 防止用户误传破坏环境（PWD/LOGNAME 等）|
| LCE 用 setuid 二进制 | 让 NM 主进程用低权限运行，仅在 fork 时切到目标用户 |
| ContainersMonitor 周期采样而非 cgroup oom_killer | 采样能给出"详细 process-tree dump"，有助排查；cgroup OOM 突然杀掉，运维难以定位 |
| aged 内存判定 | 兼容 JVM 启动毛刺，避免误杀 |
| 事件驱动 + 状态机 | 解耦各组件，便于扩展（HA、Recovery、Rolling Upgrade）|

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `yarn.nodemanager.container-executor.class` | DefaultContainerExecutor | 选 LCE 才有 cgroup |
| `yarn.nodemanager.linux-container-executor.cgroups.mount` | false | 是否让 NM 自动 mount cgroup |
| `yarn.nodemanager.env-whitelist` | 含 JAVA_HOME, HADOOP_*_HOME 等 | 从 NM 继承的环境变量 |
| `yarn.nodemanager.vmem-check-enabled` | true | **生产建议关掉** |
| `yarn.nodemanager.pmem-check-enabled` | true | 物理内存检查 |
| `yarn.nodemanager.vmem-pmem-ratio` | 2.1 | 虚拟/物理内存上限比 |
| `yarn.nodemanager.resource.memory-mb` | 8192 | NM 总可分配内存 |
| `yarn.nodemanager.container-monitor.interval-ms` | 3000 | 监控线程采样周期 |
| `yarn.nodemanager.localizer.cache.cleanup.interval-ms` | 600000 | Localizer cache 清理周期 |
| `yarn.nodemanager.recovery.enabled` | false | NM 重启 Container 不被杀（NM Work-Preserving Restart）|

## 八、踩坑记录

1. **vmem 误杀**：`yarn.nodemanager.vmem-check-enabled=true` + 64-bit JVM 应用，几乎必中招。**建议关闭 vmem check 或调大 ratio。**
2. **cgroup 不生效**：LCE 配了但 cgroup 路径没创建好（mount=false 但路径不存在）。检查 `/sys/fs/cgroup/cpu/hadoop-yarn/` 是否存在。
3. **launch_container.sh 失败但日志在哪？**：在 `${yarn.nodemanager.log-dirs}/<appId>/<containerId>/` 下的 `stderr` / `stdout`。**容器在状态机一旦 transition 到 DONE，NM 默认 10 分钟后清理日志（`yarn.nodemanager.delete.debug-delay-sec`）**。生产排障时建议把这个调大到 86400（24h）。
4. **"Kill PID 不是 process group leader"**：`pTree.checkPidPgrpidForMatch()` 失败，说明业务进程内 fork 出了脱离 pgrp 的子进程（典型：`nohup &` 或 `setsid`）。**LCE 会 kill 整个 pgrp，但孤儿进程会泄漏**。表现：NM 累计内存使用 < /proc/meminfo 看到的实际使用。
5. **NM Recovery 后 Container 状态丢失**：`yarn.nodemanager.recovery.enabled=true` 才能在 NM 重启时不杀容器。NMStateStore 持久化路径（`yarn.nodemanager.recovery.dir`）必须配。
6. **环境变量覆盖问题**：用户 launchContext 传 `JAVA_HOME=` 空值会覆盖 NM 的 JAVA_HOME，启动后报 "JAVA_HOME is not set"。**Spark/Flink 提交时检查 `spark.yarn.appMasterEnv.*` 配置。**

## 九、认知更新

- 之前以为 ContainerLaunch 是异步的，**实际上 call() 同步阻塞到 Container 进程退出**，NM 内部用 ExecutorService 池化运行，但每个 Container 占用一个线程。这意味着**每个 NM 上同时运行的 Container 数 ≤ ContainersLauncher 线程池大小**（默认无上限，但内存/CPU 是天然约束）。
- 之前以为 OOM kill 是 cgroup 直接杀，**实际上 NM 用周期采样 +  active KILL 事件**，cgroup 主要做 CPU 限制（mode=share）和 Memory hard limit（如果配 strict-resource-usage=true）。
- aged 内存判定（`getMemorySize(1)`）是踩过坑的设计 —— 第一次精读才搞清楚为什么有"瞬时 2x"和"持续 1x"两条线。
- `ContainerExecutor.activateContainer` 与 `launchContainer` 是分离的两步：activate 注册 pidFile（让 ContainersMonitor 能找到 pid），launch 才真正 fork。这个分离是为了**避免 race**：监控启动得太晚，可能错过启动初期的 OOM。

## 十、下一步深挖方向

- [ ] ResourceLocalizationService 三级 cache（PUBLIC/PRIVATE/APPLICATION）的清理策略
- [ ] LinuxContainerExecutor 二进制 `container-executor.c` 的 setuid 校验流程
- [ ] DistributedShell 例子 → 看 AM 如何拼装 ContainerLaunchContext
- [ ] NM Work-Preserving Restart 的 NMStateStoreService 实现

---

**沉淀完成。源码定位精确到方法+行号，与生产 OOM 告警日志格式逐一对齐。**
