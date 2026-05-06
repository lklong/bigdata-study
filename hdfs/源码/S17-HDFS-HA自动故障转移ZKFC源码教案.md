# [教案] HDFS-HA自动故障转移ZKFC源码深度剖析

> 🎯 教学目标：掌握HDFS HA自动故障转移的完整架构，深入理解ZKFailoverController、ActiveStandbyElector、HealthMonitor三大核心组件的源码实现，掌握Fencing防脑裂机制  
> ⏰ 预计学时：3学时  
> 📊 难度：★★★★★

---

## 一、课前导入（生活类比/故障场景引入）

### 1.1 生活类比：总统继任与Secret Service

想象美国总统继任机制：
- **Active NameNode** = 现任总统（行使权力）
- **Standby NameNode** = 副总统（随时准备接替）
- **ZKFC (ZKFailoverController)** = Secret Service特勤局（监控总统健康，出事时启动继任程序）
- **ZooKeeper** = 国会（权威认证谁是总统，发放"核密码箱"——即ZK临时节点）
- **Fencing** = 核密码箱回收（确保旧总统不能再发射核弹——即旧Active不能再写数据）

### 1.2 生产故障场景引入

**场景**：某金融大数据集群，Active NameNode因Full GC 30秒无响应：
- ZKFC检测到NN不健康，触发自动failover
- 但旧Active GC恢复后继续处理写请求
- 两个Active同时写EditLog → **脑裂！数据损坏！**

**核心问题**：如何保证在任何时刻最多只有一个Active NameNode？

**答案**：ZKFC + ActiveStandbyElector（ZK选举）+ Fencing（防脑裂隔离）

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| ZKFC | ZK Failover Controller | 每个NN节点运行一个的守护进程，负责健康监控和选举 |
| ActiveStandbyElector | 主备选举器 | 基于ZK临时节点实现的选举库 |
| HealthMonitor | 健康监控器 | 定期RPC探测本地NN是否健康 |
| Fencing | 隔离/击剑 | 确保旧Active被"杀死"后新Active才能上任 |
| Ephemeral ZNode | 临时节点 | ZK会话断开后自动删除的节点，用于选举 |
| Breadcrumb | 面包屑 | ZK持久节点，记录上一个Active的信息，用于fence |
| sshfence | SSH隔离 | 通过SSH远程kill旧Active进程 |
| shellfence | Shell隔离 | 执行自定义shell脚本进行隔离 |

### 2.2 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        ZooKeeper 集群                                    │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  /hadoop-ha/mycluster/                                       │        │
│  │    ├── ActiveStandbyElectorLock (临时节点，谁创建谁是Active)  │        │
│  │    └── ActiveBreadCrumb (持久节点，记录Active信息用于fence)   │        │
│  └─────────────────────────────────────────────────────────────┘        │
└───────────────────────┬───────────────────┬─────────────────────────────┘
                        │                   │
           创建Lock成功  │                   │ Watch Lock
           = 成为Active  │                   │ = 等待Active失效
                        │                   │
┌───────────────────────▼──┐     ┌──────────▼─────────────────────┐
│     ZKFC #1 (nn1节点)     │     │     ZKFC #2 (nn2节点)           │
│  ┌─────────────────────┐ │     │  ┌─────────────────────────┐   │
│  │ ActiveStandbyElector │ │     │  │ ActiveStandbyElector     │   │
│  │ (ZK选举逻辑)         │ │     │  │ (Watch锁节点)            │   │
│  └─────────────────────┘ │     │  └─────────────────────────┘   │
│  ┌─────────────────────┐ │     │  ┌─────────────────────────┐   │
│  │   HealthMonitor      │ │     │  │   HealthMonitor          │   │
│  │ (定期RPC健康检查)    │ │     │  │ (定期RPC健康检查)        │   │
│  └──────────┬──────────┘ │     │  └──────────┬──────────────┘   │
└─────────────┼────────────┘     └─────────────┼──────────────────┘
              │ monitorHealth()                  │ monitorHealth()
              │ RPC                              │ RPC
              ▼                                  ▼
┌─────────────────────────┐     ┌────────────────────────────────┐
│   NameNode #1 (Active)   │     │   NameNode #2 (Standby)        │
│   处理读写请求            │     │   追尾EditLog                   │
└─────────────────────────┘     └────────────────────────────────┘
```

### 2.3 自动Failover时序图

```
时间 ─────────────────────────────────────────────────────────────────►

NN1 (Active):    正常 ──── GC暂停/宕机 ────────────────────── (被fence)
                                │
ZKFC1:  healthy ── unhealthy ──┼── quitElection(needFence=true) ──────
                                │       │
ZooKeeper:                      │       ▼ 删除Lock临时节点
                                │       │
                                │       ▼ Watch触发
ZKFC2:           watching ──────┼───────── joinElection → 创建Lock
                                │                         │ 成功！
                                │                         ▼
                                │              fenceOldActive(nn1)
                                │                         │
                                │              ┌──────────▼──────────┐
                                │              │ 1. tryGracefulFence  │
                                │              │    (RPC: toStandby)  │
                                │              │ 2. sshfence/shell    │
                                │              │    (kill -9 nn1)     │
                                │              └──────────┬──────────┘
                                │                         │ fence成功
                                │                         ▼
NN2:             Standby ───────┼──────────── transitionToActive ─── Active!
```

---

## 三、源码深度剖析

### 3.1 DFSZKFailoverController——HDFS层入口

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/tools/DFSZKFailoverController.java`

```java
// 第59-66行：继承通用ZKFailoverController
@InterfaceAudience.Private
public class DFSZKFailoverController extends ZKFailoverController {
  private final AccessControlList adminAcl;
  private final NNHAServiceTarget localNNTarget;
}
```

DFSZKFailoverController是HDFS对通用ZKFC的适配层，主要职责：
1. 序列化/反序列化ZK节点中的NameNode信息（Protobuf格式）
2. 配置HDFS特有的安全认证（Kerberos）
3. 程序入口（main方法）

#### 3.1.1 targetToData / dataToTarget（第71-106行）

```java
// 将本地NN信息序列化为ZK节点数据
@Override
protected byte[] targetToData(HAServiceTarget target) {
  InetSocketAddress addr = target.getAddress();
  return ActiveNodeInfo.newBuilder()
    .setHostname(addr.getHostName())
    .setPort(addr.getPort())
    .setZkfcPort(target.getZKFCAddress().getPort())
    .setNameserviceId(localNNTarget.getNameServiceId())
    .setNamenodeId(localNNTarget.getNameNodeId())
    .build().toByteArray();
}

// 从ZK节点数据反序列化为NN目标（用于fence旧Active）
@Override
protected HAServiceTarget dataToTarget(byte[] data) {
  ActiveNodeInfo proto = ActiveNodeInfo.parseFrom(data);
  NNHAServiceTarget ret = new NNHAServiceTarget(
      conf, proto.getNameserviceId(), proto.getNamenodeId());
  // 验证ZK中存储的地址与本地配置一致
  InetSocketAddress addressFromProtobuf = new InetSocketAddress(
      proto.getHostname(), proto.getPort());
  if (!addressFromProtobuf.equals(ret.getAddress())) {
    throw new RuntimeException("Mismatched address stored in ZK");
  }
  ret.setZkfcPort(proto.getZkfcPort());
  return ret;
}
```

### 3.2 ZKFailoverController——核心控制器

**文件路径**: `hadoop-common/src/main/java/org/apache/hadoop/ha/ZKFailoverController.java`

#### 3.2.1 核心字段（第60-133行）

```java
public abstract class ZKFailoverController {
  protected Configuration conf;
  private String zkQuorum;                    // ZK连接串
  protected final HAServiceTarget localTarget; // 本地NN目标
  
  private HealthMonitor healthMonitor;         // 健康监控器
  private ActiveStandbyElector elector;        // ZK选举器
  protected ZKFCRpcServer rpcServer;           // ZKFC自己的RPC服务
  
  private State lastHealthState = State.INITIALIZING;  // 上次健康状态
  private volatile HAServiceState serviceState = HAServiceState.INITIALIZING;
  
  private String fatalError = null;            // 致命错误标记
  private long delayJoiningUntilNanotime = 0;  // 延迟加入选举的截止时间
}
```

#### 3.2.2 doRun()——启动流程（第192-251行）

```java
private int doRun(String[] args) throws ... {
  // 1. 初始化ZooKeeper连接和ActiveStandbyElector
  initZK();
  
  // 2. 检查ZK父节点是否存在
  if (!elector.parentZNodeExists()) {
    LOG.fatal("Parent znode does not exist. Run with -formatZK flag.");
    return ERR_CODE_NO_PARENT_ZNODE;
  }
  
  // 3. 检查fencing配置（必须配置！否则不允许启动）
  try {
    localTarget.checkFencingConfigured();
  } catch (BadFencingConfigurationException e) {
    LOG.fatal("Fencing is not configured for " + localTarget);
    return ERR_CODE_NO_FENCER;
  }
  
  // 4. 初始化RPC服务（供graceful failover使用）
  initRPC();
  // 5. 初始化HealthMonitor并开始监控本地NN
  initHM();
  // 6. 启动RPC服务
  startRPC();
  
  // 7. 进入主循环（阻塞等待，直到fatalError）
  try {
    mainLoop();
  } finally {
    rpcServer.stopAndJoin();
    elector.quitElection(true);
    healthMonitor.shutdown();
    healthMonitor.join();
  }
  return 0;
}
```

#### 3.2.3 recheckElectability()——选举决策核心（第738-787行）

```java
private void recheckElectability() {
  synchronized (elector) {
    synchronized (this) {
      boolean healthy = lastHealthState == State.SERVICE_HEALTHY;
      
      // 检查是否在延迟加入期间（graceful failover时用）
      long remainingDelay = delayJoiningUntilNanotime - System.nanoTime();
      if (remainingDelay > 0) {
        scheduleRecheck(remainingDelay);  // 稍后重试
        return;
      }
      
      switch (lastHealthState) {
      case SERVICE_HEALTHY:
        // 健康：加入选举！
        elector.joinElection(targetToData(localTarget));
        break;
        
      case INITIALIZING:
        // 初始化中：退出选举
        elector.quitElection(false);
        serviceState = HAServiceState.INITIALIZING;
        break;
        
      case SERVICE_UNHEALTHY:
      case SERVICE_NOT_RESPONDING:
        // 不健康：退出选举，并标记需要fence
        LOG.info("Quitting master election and marking fencing necessary");
        elector.quitElection(true);  // needFence=true！
        serviceState = HAServiceState.INITIALIZING;
        break;
        
      case HEALTH_MONITOR_FAILED:
        fatalError("Health monitor failed!");
        break;
      }
    }
  }
}
```

**关键逻辑**：`quitElection(true)` 中的 `true` 表示需要fence。当本地NN变得不健康时，ZKFC退出选举并告诉ZK"我需要被fence"——这样新的Active在上任前会先fence旧的。

#### 3.2.4 becomeActive()——成为Active（第383-418行）

```java
private synchronized void becomeActive() throws ServiceFailedException {
  LOG.info("Trying to make " + localTarget + " active...");
  try {
    // 通过RPC调用本地NN的transitionToActive
    HAServiceProtocolHelper.transitionToActive(
        localTarget.getProxy(conf, FailoverController.getRpcTimeoutToNewActive(conf)),
        createReqInfo());
    LOG.info("Successfully transitioned " + localTarget + " to active state");
    serviceState = HAServiceState.ACTIVE;
    recordActiveAttempt(new ActiveAttemptRecord(true, msg));
  } catch (Throwable t) {
    LOG.fatal("Couldn't make " + localTarget + " active", t);
    recordActiveAttempt(new ActiveAttemptRecord(false, msg));
    throw new ServiceFailedException("Couldn't transition to active", t);
  }
}
```

#### 3.2.5 fenceOldActive()——隔离旧Active（第505-539行）

```java
private synchronized void fenceOldActive(byte[] data) {
  // 从ZK节点数据中还原旧Active的信息
  HAServiceTarget target = dataToTarget(data);
  try {
    doFence(target);
  } catch (Throwable t) {
    recordActiveAttempt(new ActiveAttemptRecord(false, 
        "Unable to fence old active"));
    Throwables.propagate(t);
  }
}

private void doFence(HAServiceTarget target) {
  LOG.info("Should fence: " + target);
  // 1. 先尝试优雅隔离（RPC调用旧Active的transitionToStandby）
  boolean gracefulWorked = new FailoverController(conf,
      RequestSource.REQUEST_BY_ZKFC).tryGracefulFence(target);
  if (gracefulWorked) {
    LOG.info("Successfully transitioned " + target + " to standby without fencing");
    return;  // 优雅成功，不需要暴力fence
  }
  
  // 2. 优雅失败，执行配置的fencing方法（sshfence/shellfence）
  target.checkFencingConfigured();
  if (!target.getFencer().fence(target)) {
    throw new RuntimeException("Unable to fence " + target);
  }
}
```

**Fencing两阶段**：
1. **优雅阶段**：RPC调用`transitionToStandby()`，如果旧NN还能响应就切为Standby
2. **暴力阶段**：如果RPC超时（旧NN可能已宕机/GC），则执行sshfence（SSH过去kill -9）或shellfence

### 3.3 HealthMonitor——健康监控器

**文件路径**: `hadoop-common/src/main/java/org/apache/hadoop/ha/HealthMonitor.java`

#### 3.3.1 状态枚举（第84-111行）

```java
public enum State {
  INITIALIZING,           // 启动中
  SERVICE_NOT_RESPONDING, // NN无响应（RPC超时）
  SERVICE_HEALTHY,        // NN健康
  SERVICE_UNHEALTHY,      // NN不健康（响应了但报告不健康）
  HEALTH_MONITOR_FAILED;  // HealthMonitor自身故障
}
```

#### 3.3.2 doHealthChecks()——健康检查循环（第197-230行）

```java
private void doHealthChecks() throws InterruptedException {
  while (shouldRun) {
    HAServiceStatus status = null;
    boolean healthy = false;
    try {
      // 1. 获取服务状态（Active/Standby）
      status = proxy.getServiceStatus();
      // 2. 调用monitorHealth() RPC —— NN内部做全面检查
      proxy.monitorHealth();
      healthy = true;
    } catch (Throwable t) {
      if (isHealthCheckFailedException(t)) {
        // NN响应了但报告自己不健康
        LOG.warn("Service health check failed: " + t.getMessage());
        enterState(State.SERVICE_UNHEALTHY);
      } else {
        // RPC本身失败（超时/连接断开）
        LOG.warn("Transport-level exception monitoring " + targetToMonitor);
        RPC.stopProxy(proxy);
        proxy = null;
        enterState(State.SERVICE_NOT_RESPONDING);
        Thread.sleep(sleepAfterDisconnectMillis);
        return;  // 退出检查循环，重新连接
      }
    }
    
    if (status != null) setLastServiceStatus(status);
    if (healthy) enterState(State.SERVICE_HEALTHY);
    
    Thread.sleep(checkIntervalMillis);  // 默认1秒
  }
}
```

#### 3.3.3 回调机制

```java
// 状态变化时通知ZKFC
private synchronized void enterState(State newState) {
  if (newState != state) {
    state = newState;
    for (Callback cb : callbacks) {
      cb.enteredState(newState);  // → ZKFC.HealthCallbacks.enteredState()
    }
  }
}
```

ZKFC注册的回调（`ZKFailoverController.java` 第909-914行）：
```java
class HealthCallbacks implements HealthMonitor.Callback {
  @Override
  public void enteredState(HealthMonitor.State newState) {
    setLastHealthState(newState);
    recheckElectability();  // 状态变化 → 重新评估是否参与选举
  }
}
```

### 3.4 ActiveStandbyElector——ZK选举器

**文件路径**: `hadoop-common/src/main/java/org/apache/hadoop/ha/ActiveStandbyElector.java`

#### 3.4.1 ZK节点结构

```
/hadoop-ha/mycluster/
  ├── ActiveStandbyElectorLock   (临时节点 EPHEMERAL)
  │     数据: ActiveNodeInfo protobuf (hostname, port, zkfcPort, nsId, nnId)
  │     创建者的ZK session断开 → 节点自动删除 → 触发Watch → 重新选举
  │
  └── ActiveBreadCrumb           (持久节点 PERSISTENT)
        数据: 同上ActiveNodeInfo
        用途: 记录"谁曾经是Active"，新Active上任时读取，用于fence旧Active
```

#### 3.4.2 joinElection()——加入选举

```java
public void joinElection(byte[] data) {
  // data = 本地NN的ActiveNodeInfo protobuf序列化
  this.appData = data;
  this.wantToBeInElection = true;
  // 尝试创建临时节点
  elector.joinElection(data);
  // 内部调用: zoo_create(LOCK_FILENAME, data, EPHEMERAL)
  // → 成功: becomeActive回调
  // → 节点已存在(NodeExistsException): 设置Watch，等待删除 → becomeStandby
}
```

#### 3.4.3 选举核心——创建临时节点

```java
// ActiveStandbyElector内部（简化逻辑）
private void createLockNode() {
  try {
    // 尝试创建临时节点（原子操作，只有一个能成功）
    zkClient.create(zkLockFilePath, appData, zkAcl, CreateMode.EPHEMERAL);
    // 成功！我是Active
    // 写入Breadcrumb持久节点（记录自己是Active）
    writeBreadCrumbNode();
    appClient.becomeActive();
  } catch (KeeperException.NodeExistsException e) {
    // 节点已存在，说明别人是Active
    // 监视该节点（Watch），等待其消失
    monitorLockNode();
    appClient.becomeStandby();
  }
}

// 当Watch触发（锁节点被删除）
private void monitorLockNodeCallback(WatchedEvent event) {
  if (event.getType() == Event.EventType.NodeDeleted) {
    // Active挂了！尝试抢锁
    // 但在创建之前，先检查Breadcrumb → fence旧Active
    byte[] oldActiveData = readBreadCrumbNode();
    if (oldActiveData != null) {
      appClient.fenceOldActive(oldActiveData);
    }
    createLockNode();  // 重新尝试创建
  }
}
```

### 3.5 Graceful Failover——优雅切换流程

**文件路径**: `ZKFailoverController.java` 第631-691行

```java
/**
 * 优雅failover五阶段：
 * 1. 预检查：确保本地节点健康
 * 2. 确定当前Active
 * 3. 要求旧Active让位（cedeActive）
 * 4. 等待正常选举流程让本地节点成为Active
 * 5. 允许旧Active重新加入选举（支持failback）
 */
private void doGracefulFailover() throws ... {
  int timeout = FailoverController.getGracefulFenceTimeout(conf) * 2;
  
  // Phase 1: 预检查
  checkEligibleForFailover();
  
  // Phase 2: 确定当前Active
  HAServiceTarget oldActive = getCurrentActive();
  if (oldActive == null) {
    throw new ServiceFailedException("No other node is currently active.");
  }
  if (oldActive.getAddress().equals(localTarget.getAddress())) {
    LOG.info("Local node is already active. No need to failover.");
    return;
  }
  
  // Phase 3: 要求旧Active让位
  LOG.info("Asking " + oldActive + " to cede its active state for " + timeout + "ms");
  ZKFCProtocol oldZkfc = oldActive.getZKFCProxy(conf, timeout);
  oldZkfc.cedeActive(timeout);  // RPC到旧ZKFC：退出选举timeout毫秒
  
  // Phase 4: 等待选举结果
  ActiveAttemptRecord attempt = waitForActiveAttempt(timeout + 60000);
  
  // Phase 5: 让旧Active可以重新加入
  oldZkfc.cedeActive(-1);  // -1表示立即可以重新加入
  
  if (attempt.succeeded) {
    LOG.info("Successfully became active.");
  } else {
    throw new ServiceFailedException("Failed to become active: " + attempt.status);
  }
}
```

---

## 四、生产实战案例

### 4.1 案例一：自动Failover未触发排障

**症状**：Active NN宕机后Standby未自动接管。

```bash
# 1. 检查ZKFC是否在运行
jps | grep DFSZKFailoverController
# 如果没有 → ZKFC进程挂了，需重启

# 2. 检查ZKFC日志
grep -E "FATAL|ERROR|fencing" /var/log/hadoop/zkfc.log
# "Fencing is not configured" → 未配置fencing方法
# "Unable to fence" → fence失败，新Active无法上任

# 3. 检查ZK连接
echo "stat" | nc zk-host 2181
# 如果ZK集群不可用，选举无法进行

# 4. 检查ZK中的锁节点
zkCli.sh -server zk-host:2181
ls /hadoop-ha/mycluster
get /hadoop-ha/mycluster/ActiveStandbyElectorLock
# 查看锁的session是否还有效
```

### 4.2 案例二：Fencing配置

```xml
<!-- hdfs-site.xml -->
<!-- 方案1：sshfence（推荐） -->
<property>
  <name>dfs.ha.fencing.methods</name>
  <value>sshfence</value>
</property>
<property>
  <name>dfs.ha.fencing.ssh.private-key-files</name>
  <value>/root/.ssh/id_rsa</value>
</property>
<property>
  <name>dfs.ha.fencing.ssh.connect-timeout</name>
  <value>30000</value>
</property>

<!-- 方案2：sshfence + shell（多重保障） -->
<property>
  <name>dfs.ha.fencing.methods</name>
  <value>
    sshfence
    shell(/path/to/fence-script.sh)
  </value>
</property>

<!-- 方案3：PowerShell/IPMI远程关机（物理机） -->
<property>
  <name>dfs.ha.fencing.methods</name>
  <value>shell(/usr/local/bin/ipmi-fence.sh)</value>
</property>
```

### 4.3 关键参数调优

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `ha.zookeeper.session-timeout.ms` | 10000 | 5000-10000 | ZK会话超时（太短易误切，太长恢复慢） |
| `ha.health-monitor.check-interval.ms` | 1000 | 1000 | 健康检查间隔 |
| `ha.health-monitor.connect-retry-interval.ms` | 1000 | 1000 | 连接重试间隔 |
| `ha.health-monitor.rpc-timeout.ms` | 45000 | 30000 | 健康检查RPC超时 |
| `dfs.ha.fencing.ssh.connect-timeout` | 30000 | 30000 | SSH fence连接超时 |

### 4.4 监控告警

```bash
# ZKFC健康指标（通过JMX或日志监控）
# 1. HealthMonitor状态变化
grep "entered state" /var/log/hadoop/zkfc.log | tail -10

# 2. 选举事件
grep -E "becomeActive|becomeStandby|joinElection|quitElection" /var/log/hadoop/zkfc.log

# 3. Fence事件（严重！需立即关注）
grep -i "fence" /var/log/hadoop/zkfc.log
```

---

## 五、举一反三

### 5.1 与其他选举机制的对比

| 系统 | 选举机制 | 防脑裂方式 |
|------|---------|-----------|
| HDFS ZKFC | ZK临时节点抢锁 | Fencing（sshfence/shellfence） |
| HBase Master | ZK临时节点 | Master启动时检查旧Master | 
| Kafka Controller | ZK临时节点 | Epoch递增（Controller Epoch） |
| etcd/Raft | Raft协议多数派投票 | Term递增 + 日志匹配 |
| MySQL Group Repl | Paxos/Raft变体 | View Change + 多数派确认 |

### 5.2 面试高频题

**Q1：ZKFC的三大组件各自的职责是什么？**

A：
- **HealthMonitor**：定期RPC探测本地NameNode，状态变化时通知ZKFC
- **ActiveStandbyElector**：与ZK交互，通过临时节点实现选举，Watch机制感知Active失效
- **ZKFailoverController**：协调者，根据HealthMonitor的状态决定是否参与选举，选举成功时执行Fence和状态转换

**Q2：为什么必须配置Fencing？不配会怎样？**

A：
- 不配置Fencing，ZKFC拒绝启动（`ERR_CODE_NO_FENCER`）
- 如果没有Fencing，可能出现：旧Active的ZK session尚未过期，但新Active已被选举
- 更糟的是：旧Active网络分区恢复后，它仍以为自己是Active → 两个Active同时写 → 脑裂
- Fencing确保旧Active被确认"死亡"后，新Active才能上任

**Q3：ZK session超时设多大合适？**

A：
- 太短（如2s）：一次Full GC就可能导致session过期 → 不必要的failover → 频繁切换
- 太长（如60s）：真正宕机时恢复时间长 → 服务不可用时间长
- 建议5-10s，需要根据GC调优（目标GC pause < session timeout / 3）
- 公式：session_timeout > 3 × max_gc_pause + network_latency

**Q4：Breadcrumb节点的作用是什么？**

A：Breadcrumb是一个持久节点，记录"上一个Active是谁"。当Active NN突然宕机时：
1. 其ZK session超时 → 临时锁节点被删除
2. Standby的ZKFC Watch触发 → 尝试创建锁节点
3. 创建前先读取Breadcrumb → 得知旧Active的地址
4. 对旧Active执行fence → 确保它不再是Active
5. fence成功后才创建锁节点、成为新Active
6. 更新Breadcrumb为自己

### 5.3 思考题

1. 如果ZooKeeper集群自身出现网络分区，会对HDFS HA产生什么影响？
2. 为什么graceful failover时旧Active需要"cedeActive"一段时间后才重新加入选举？
3. 如果两个ZKFC同时检测到本地NN健康并同时创建锁节点，ZK如何保证只有一个成功？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────────┐
│         HDFS HA 自动故障转移 ZKFC · 知识晶体                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  【三大组件】                                                        │
│  HealthMonitor:  monitorHealth() RPC探测 → 5种状态                  │
│  ActiveStandbyElector: ZK临时节点抢锁 + Watch + Breadcrumb          │
│  ZKFailoverController: 协调者，recheckElectability() 决策核心        │
│                                                                     │
│  【自动Failover流程】                                                │
│  NN不健康 → HM通知ZKFC → quitElection(needFence=true)              │
│  → ZK锁节点因session超时删除 → 对端Watch触发                       │
│  → 读Breadcrumb → fenceOldActive → 创建锁 → becomeActive          │
│  → transitionToActive RPC → 新Active上线                           │
│                                                                     │
│  【Fencing两阶段】                                                   │
│  1. tryGracefulFence: RPC调transitionToStandby（旧NN还活着时）     │
│  2. sshfence/shellfence: SSH kill -9 / 自定义脚本（暴力保底）       │
│                                                                     │
│  【关键ZK节点】                                                      │
│  /hadoop-ha/{ns}/ActiveStandbyElectorLock → 临时节点（选举锁）      │
│  /hadoop-ha/{ns}/ActiveBreadCrumb → 持久节点（记录旧Active）        │
│                                                                     │
│  【关键参数】                                                        │
│  ha.zookeeper.session-timeout.ms = 5000-10000                       │
│  ha.health-monitor.check-interval.ms = 1000                         │
│  dfs.ha.fencing.methods = sshfence (必须配置!)                      │
│                                                                     │
│  【防脑裂保证】                                                      │
│  ZK原子性 + Fencing + Epoch/Breadcrumb → 任何时刻最多一个Active    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/tools/DFSZKFailoverController.java`
   - `hadoop-common/src/main/java/org/apache/hadoop/ha/ZKFailoverController.java`
   - `hadoop-common/src/main/java/org/apache/hadoop/ha/ActiveStandbyElector.java`
   - `hadoop-common/src/main/java/org/apache/hadoop/ha/HealthMonitor.java`

2. **设计文档**
   - HDFS-3042: Automatic failover support for HDFS HA
   - HDFS-2185: HDFS High Availability Design Document

3. **ZooKeeper相关**
   - ZooKeeper Recipes: Leader Election
   - ZooKeeper Session Management
