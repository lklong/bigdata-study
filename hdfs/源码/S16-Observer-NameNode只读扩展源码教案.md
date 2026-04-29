# [教案] Observer NameNode只读扩展源码深度剖析

> 🎯 教学目标：掌握Observer NameNode的架构设计、EditLogTailer追尾机制、客户端ObserverReadProxyProvider自动路由、State ID一致性保证，以及如何通过Observer NN实现读扩展  
> ⏰ 预计学时：3学时  
> 📊 难度：★★★★☆

---

## 一、课前导入（生活类比/故障场景引入）

### 1.1 生活类比：银行总部与分行模式

想象一个银行系统：
- **Active NameNode** = 银行总部（处理所有存款/取款/转账业务）
- **Standby NameNode** = 灾备总部（同步所有流水，但不对外营业）
- **Observer NameNode** = 只读分行（同步流水、可查询余额/流水，但不能修改账户）

传统HA模式下，所有客户端都涌向Active NN查询文件信息，即使90%的操作是只读的（如`getFileInfo`、`listStatus`、`getBlockLocations`）。Observer NN就是为解决这个**读压力集中**问题而设计的。

### 1.2 生产故障场景引入

**场景**：某大数据集群有5000个DataNode，Active NameNode的RPC Handler线程（默认200）经常打满：
- `getBlockLocations` 占用60%的Handler
- `listStatus` 占用20%的Handler
- 写操作（create/mkdir/rename）等待RPC排队，导致HBase RegionServer lease超时
- P99 RPC延迟从5ms飙升到800ms

**根因**：HA模式下Standby NN不服务任何请求，所有读写都压在Active上。

**解决方案**：部署Observer NameNode，将读请求分流到Observer，Active只处理写操作。

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| Observer NameNode | 观察者NameNode | 第三种NN角色，同步EditLog并服务只读请求 |
| EditLogTailer | EditLog追尾器 | 后台线程，从JournalNode拉取EditLog并回放到命名空间 |
| State ID | 状态标识 | 单调递增的事务ID，用于一致性保证 |
| msync | 元数据同步 | 客户端向Active NN获取最新State ID的轻量级RPC |
| ObserverReadProxyProvider | 观察者读代理 | 客户端侧智能路由，自动将读请求发给Observer |
| Consistent Read | 一致性读 | 确保客户端读到的状态不早于其上次写操作的状态 |
| HAServiceState | HA服务状态 | ACTIVE / STANDBY / OBSERVER 三种状态枚举 |

### 2.2 架构全景图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Client（DFSClient）                          │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │            ObserverReadProxyProvider                            │  │
│  │  ┌─────────────────┬──────────────────┬────────────────────┐  │  │
│  │  │  写请求 → Active │  读请求 → Observer │  msync → Active    │  │  │
│  │  └─────────────────┴──────────────────┴────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
└────────┬──────────────────────┬───────────────────────┬─────────────┘
         │                      │                       │
         ▼                      ▼                       ▼
┌────────────────┐   ┌────────────────────┐   ┌────────────────────┐
│  Active NN     │   │   Observer NN #1    │   │   Observer NN #2    │
│  (读+写)       │   │   (只读服务)        │   │   (只读服务)        │
│                │   │                     │   │                     │
│ FSNamesystem   │   │  FSNamesystem       │   │  FSNamesystem       │
│ (可写)         │   │  (只读镜像)         │   │  (只读镜像)         │
│                │   │                     │   │                     │
│ State ID: 1000 │   │  State ID: 998     │   │  State ID: 995     │
└───────┬────────┘   └──────────┬─────────┘   └──────────┬─────────┘
        │                       │                         │
        │   EditLog写入         │ EditLogTailer           │ EditLogTailer
        ▼                       │ 追尾回放                │ 追尾回放
┌─────────────────────────────────────────────────────────────────────┐
│                    JournalNode集群 (QJM)                             │
│         edits_inprogress_0001-xxxx  /  edits_0001-0100_finalized    │
└─────────────────────────────────────────────────────────────────────┘
        │
        │ BlockReport / 心跳
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    DataNode 集群                                      │
│  (同时向Active和Observer发送BlockReport)                              │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 Observer vs Standby 对比

| 维度 | Standby NN | Observer NN |
|------|-----------|-------------|
| EditLog追尾 | ✅ 回放EditLog保持同步 | ✅ 回放EditLog保持同步 |
| 服务客户端读请求 | ❌ 拒绝所有客户端请求 | ✅ 服务只读请求 |
| 服务写请求 | ❌ | ❌ |
| BlockReport | ❌ 不接收（2.x）/✅（3.x） | ✅ 接收BlockReport |
| Failover候选 | ✅ 可被选举为Active | ❌ 不参与选举 |
| 数量限制 | 1个（HA模式） | 可以部署多个 |
| 典型延迟 | N/A | 毫秒~秒级落后Active |

---

## 三、源码深度剖析

### 3.1 EditLogTailer——Observer/Standby的核心追尾机制

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ha/EditLogTailer.java`

EditLogTailer是Observer NN实现的基石。Observer的读服务准确性完全取决于EditLogTailer的追尾速度和正确性。

#### 3.1.1 核心字段（第63-131行）

```java
public class EditLogTailer {
  private final EditLogTailerThread tailerThread;
  private final Configuration conf;
  private final FSNamesystem namesystem;
  private FSEditLog editLog;

  // Active NN的地址（用于触发log roll）
  private InetSocketAddress activeAddr;
  private NamenodeProtocol cachedActiveProxy = null;

  // 上次触发roll的事务ID
  private long lastRollTriggerTxId = HdfsServerConstants.INVALID_TXID;
  
  // Standby/Observer已加载的最高事务ID —— 这就是State ID的来源
  private long lastLoadedTxnId = HdfsServerConstants.INVALID_TXID;

  // 上次成功加载edits的时间
  private long lastLoadTimeMs;

  // Active多久roll一次EditLog（Standby只能读finalized的segment）
  private final long logRollPeriodMs;

  // Tailer的扫描间隔
  private final long sleepTimeMs;
}
```

**关键参数**：
- `dfs.ha.tail-edits.period`（默认60s）：追尾线程的轮询间隔
- `dfs.ha.log-roll.period`（默认120s）：触发Active做EditLog roll的间隔

在Observer模式下，这两个参数通常调小到1-5s以减少追尾延迟。

#### 3.1.2 doTailEdits()——核心追尾逻辑（第200-252行）

```java
@VisibleForTesting
void doTailEdits() throws IOException, InterruptedException {
  // 获取写锁（回放EditLog会修改namespace）
  namesystem.writeLockInterruptibly();
  try {
    FSImage image = namesystem.getFSImage();
    // 1. 获取当前已回放到的事务ID
    long lastTxnId = image.getLastAppliedTxId();
    
    // 2. 从共享存储（JournalNode）选择可读的EditLog流
    //    从lastTxnId+1开始，读取所有可用的segment
    Collection<EditLogInputStream> streams;
    try {
      streams = editLog.selectInputStreams(lastTxnId + 1, 0, null, false);
    } catch (IOException ioe) {
      // EditLog正在roll，新的inprogress文件还未创建，稍后重试
      LOG.warn("Edits tailer failed to find any streams. Will try again later.");
      return;
    }
    
    // 3. 加载并回放EditLog事务
    long editsLoaded = 0;
    try {
      editsLoaded = image.loadEdits(streams, namesystem);
    } catch (EditLogInputException elie) {
      editsLoaded = elie.getNumEditsLoaded();
      throw elie;
    }

    if (editsLoaded > 0) {
      lastLoadTimeMs = monotonicNow();
    }
    // 4. 更新lastLoadedTxnId（即State ID）
    lastLoadedTxnId = image.getLastAppliedTxId();
  } finally {
    namesystem.writeUnlock();
  }
}
```

**核心流程**：
1. 获取当前已回放的最高TxId
2. 从JournalNode拉取从`lastTxnId+1`开始的所有EditLog segment
3. 调用`FSImage.loadEdits()`逐条回放事务到命名空间
4. 更新`lastLoadedTxnId`作为当前节点的State ID

#### 3.1.3 EditLogTailerThread——后台追尾线程（第295-366行）

```java
private class EditLogTailerThread extends Thread {
  private volatile boolean shouldRun = true;
  
  private void doWork() {
    while (shouldRun) {
      try {
        // 1. 检查是否需要触发Active做EditLog roll
        //    条件：距离上次加载超过logRollPeriod，且确实有新事务
        if (tooLongSinceLastLoad() &&
            lastRollTriggerTxId < lastLoadedTxnId) {
          triggerActiveLogRoll();
        }
        
        if (!shouldRun) break;
        
        // 2. 获取checkpoint锁（防止与checkpoint冲突）
        namesystem.cpLockInterruptibly();
        try {
          // 3. 执行追尾
          doTailEdits();
        } finally {
          namesystem.cpUnlock();
        }
      } catch (EditLogInputException elie) {
        LOG.warn("Error while reading edits from disk. Will try again.", elie);
      } catch (InterruptedException ie) {
        continue;
      } catch (Throwable t) {
        LOG.fatal("Unknown error encountered while tailing edits. " +
            "Shutting down standby NN.", t);
        terminate(1, t);
      }
      
      // 4. 休眠等待下一轮
      try {
        Thread.sleep(sleepTimeMs);
      } catch (InterruptedException e) {
        LOG.warn("Edit log tailer interrupted", e);
      }
    }
  }
}
```

#### 3.1.4 triggerActiveLogRoll()——触发Active滚动日志（第272-289行）

```java
private void triggerActiveLogRoll() {
  LOG.info("Triggering log roll on remote NameNode " + activeAddr);
  try {
    // 通过NamenodeProtocol RPC调用Active的rollEditLog()
    getActiveNodeProxy().rollEditLog();
    lastRollTriggerTxId = lastLoadedTxnId;
  } catch (IOException ioe) {
    if (ioe instanceof RemoteException) {
      ioe = ((RemoteException)ioe).unwrapRemoteException();
      if (ioe instanceof StandbyException) {
        // Active可能已经切换，忽略
        LOG.info("Skipping log roll. Remote node is not in Active state");
        return;
      }
    }
    LOG.warn("Unable to trigger a roll of the active NN", ioe);
  }
}
```

**为什么需要触发roll？**

EditLogTailer默认只能读取**已finalized**的EditLog segment（`edits_startTxId-endTxId`），而Active正在写入的`edits_inprogress_xxx`默认不可读。通过触发roll，Active会关闭当前inprogress文件并开启新的，使得之前的segment变为finalized可读。

> **注意**：在Hadoop 3.x的Observer模式中，引入了"in-progress tailing"优化，Observer可以直接读取inprogress文件，大幅减少追尾延迟。

### 3.2 HAState状态机——Observer状态的基础

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ha/HAState.java`

```java
// 第31-68行：状态机基类
abstract public class HAState {
  protected final HAServiceState state;  // ACTIVE / STANDBY / OBSERVER

  // 状态转换方法（模板方法模式）
  protected final void setStateInternal(final HAContext context, final HAState s)
      throws ServiceFailedException {
    prepareToExitState(context);  // 1. 准备退出当前状态
    s.prepareToEnterState(context);  // 2. 准备进入新状态
    context.writeLock();
    try {
      exitState(context);      // 3. 退出当前状态
      context.setState(s);     // 4. 设置新状态
      s.enterState(context);   // 5. 进入新状态
    } finally {
      context.writeUnlock();
    }
  }

  // 检查操作是否允许（Observer覆写此方法）
  public abstract void checkOperation(final HAContext context, 
      final OperationCategory op) throws StandbyException;
}
```

### 3.3 StandbyState.checkOperation()——读请求拦截逻辑

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ha/StandbyState.java` 第79-89行

```java
@Override
public void checkOperation(HAContext context, OperationCategory op)
    throws StandbyException {
  // UNCHECKED类型的操作总是允许
  if (op == OperationCategory.UNCHECKED ||
      // 如果配置允许stale reads，则放行READ操作
      (op == OperationCategory.READ && context.allowStaleReads())) {
    return;
  }
  // 其他操作（包括WRITE和默认的READ）抛出StandbyException
  String msg = "Operation category " + op + " is not supported in state "
      + context.getState();
  throw new StandbyException(msg);
}
```

**Observer模式的差异**：Observer状态的`checkOperation()`对`READ`操作返回通过，对`WRITE`操作抛出`StandbyException`。这是Observer能服务读请求的关键：

```java
// ObserverState.checkOperation()（Hadoop 3.x）
@Override
public void checkOperation(HAContext context, OperationCategory op)
    throws StandbyException {
  if (op == OperationCategory.READ || op == OperationCategory.UNCHECKED) {
    return;  // Observer允许所有读操作
  }
  // 写操作仍然拒绝
  throw new StandbyException("Operation category " + op + 
      " is not supported in state OBSERVER");
}
```

### 3.4 Observer NameNode的State ID一致性机制

#### 3.4.1 设计原理

State ID是一个单调递增的事务序号（即`lastAppliedTxId`），用于保证**"read-your-writes"**语义：

```
时间线：
Client:  write(create /foo) ──> stateId=100 ──> read(ls /foo) ──> 
                                                      │
                                                      ▼ 携带stateId=100
Active NN: ─── TxId 100: create /foo ────────────────────────────
                    │
                    ▼ EditLog
Observer NN: ─── TxId 95 → 96 → 97 → 98 → 99 → 100 ───────────
                                                    │
                                        此时才能响应读请求
```

#### 3.4.2 核心流程

```java
// 客户端侧（ObserverReadProxyProvider）伪代码
public Object invoke(Method method, Object[] args) {
  if (isReadOperation(method)) {
    // 1. 如果从未写过，直接发给Observer
    // 2. 如果刚执行过写操作，先msync获取Active的最新stateId
    if (needsMsync()) {
      long latestStateId = activeProxy.msync();
      this.lastSeenStateId = latestStateId;
    }
    // 3. 尝试发给Observer，携带lastSeenStateId
    try {
      return observerProxy.invoke(method, args, lastSeenStateId);
    } catch (ObserverRetryOnActiveException e) {
      // Observer的stateId还没追上，回退到Active读
      return activeProxy.invoke(method, args);
    }
  } else {
    // 写操作直接发给Active
    Object result = activeProxy.invoke(method, args);
    // 更新lastSeenStateId
    this.lastSeenStateId = extractStateId(result);
    return result;
  }
}

// Observer NN侧处理逻辑
public GetFileInfoResponseProto getFileInfo(request) {
  long clientStateId = request.getStateId();
  long myStateId = namesystem.getLastAppliedTxId();
  
  if (myStateId < clientStateId) {
    // 我还没追上客户端要求的一致性级别
    // 选项1：等待（短暂spin-wait直到追上）
    // 选项2：抛出异常让客户端重试或回退Active
    if (!waitForStateId(clientStateId, timeoutMs)) {
      throw new ObserverRetryOnActiveException(
          "Observer stateId " + myStateId + " < required " + clientStateId);
    }
  }
  // 正常处理读请求
  return super.getFileInfo(request);
}
```

#### 3.4.3 msync RPC

`msync`是一个非常轻量的RPC，它的唯一作用是让客户端获取Active NN当前的最新TxId：

```java
// Active NN侧
public long msync() {
  // 仅返回当前最新事务ID，不做任何阻塞操作
  return namesystem.getLastWrittenTransactionId();
}
```

客户端在以下时机调用msync：
1. 刚完成一次写操作后的首次读
2. 距离上次msync已超过配置的间隔（`dfs.client.observer.stateId.refresh.period`）
3. Observer返回`ObserverRetryOnActiveException`时

### 3.5 ObserverReadProxyProvider——客户端智能路由

#### 3.5.1 路由决策流程

```java
// ObserverReadProxyProvider核心逻辑（Hadoop 3.x设计）
public class ObserverReadProxyProvider<T> extends ConfiguredFailoverProxyProvider<T> {
  
  // Observer节点列表
  private List<AddressRpcProxyPair<T>> observerProxies;
  // 当前使用的Observer索引
  private int currentObserverIndex = 0;
  // 最后看到的StateId
  private long lastSeenStateId = 0;
  
  @Override
  public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    // 判断是否为读操作
    if (isRead(method)) {
      return invokeObserver(method, args);
    } else {
      // 写操作发给Active
      Object result = invokeActive(method, args);
      // 从响应中提取stateId
      updateStateId(result);
      return result;
    }
  }
  
  private Object invokeObserver(Method method, Object[] args) {
    int maxRetries = observerProxies.size();
    for (int i = 0; i < maxRetries; i++) {
      T observer = getNextObserver();
      try {
        // 在RPC header中携带lastSeenStateId
        Object result = method.invoke(observer, args);
        return result;
      } catch (ObserverRetryOnActiveException e) {
        // Observer落后太多，尝试下一个Observer或回退Active
        continue;
      } catch (StandbyException e) {
        // 该节点可能已从Observer切为Standby
        continue;
      }
    }
    // 所有Observer都不可用，回退到Active
    return invokeActive(method, args);
  }
}
```

#### 3.5.2 负载均衡策略

Observer NN可以部署多个，ObserverReadProxyProvider支持以下负载均衡：
- **Round-Robin**：轮询各Observer
- **Random**：随机选择
- **Weighted**：按Observer的追尾延迟加权（延迟小的权重高）

### 3.6 EditLog回放与Block Location的同步

Observer NN需要准确的Block Location信息才能正确响应`getBlockLocations`。这涉及两个数据来源：

1. **EditLog回放**：获知文件→Block映射（`addBlock`、`close`等事务）
2. **BlockReport**：获知Block→DataNode映射

```
┌──────────────────────────────────────────────────┐
│           Observer NN 数据同步                     │
├──────────────────────────────────────────────────┤
│                                                  │
│  EditLog回放提供：                                │
│  • 文件系统树（目录/文件/INode）                  │
│  • 文件→Block列表映射                            │
│  • Block元信息（generation stamp, 大小）          │
│                                                  │
│  BlockReport提供：                                │
│  • Block→DataNode位置映射                        │
│  • Block实际大小/状态                            │
│                                                  │
│  两者结合才能完整回答 getBlockLocations           │
│                                                  │
└──────────────────────────────────────────────────┘
```

DataNode需要配置为同时向Active和Observer发送BlockReport：
```xml
<property>
  <name>dfs.namenode.servicerpc-address.mycluster.nn3</name>
  <value>observer-host:8020</value>
</property>
```

---

## 四、生产实战案例

### 4.1 案例一：部署Observer NN分流读压力

**场景**：Active NN的RPC Handler被getBlockLocations请求打满，写操作排队。

**部署步骤**：

```xml
<!-- hdfs-site.xml：添加Observer节点 -->
<property>
  <name>dfs.ha.namenodes.mycluster</name>
  <value>nn1,nn2,nn3</value>  <!-- nn3为Observer -->
</property>
<property>
  <name>dfs.namenode.rpc-address.mycluster.nn3</name>
  <value>observer-host:8020</value>
</property>

<!-- Observer特有配置 -->
<property>
  <name>dfs.ha.tail-edits.period</name>
  <value>1</value>  <!-- 1秒追尾一次（默认60秒太慢） -->
</property>
<property>
  <name>dfs.ha.tail-edits.in-progress</name>
  <value>true</value>  <!-- 允许读inprogress文件，减少延迟 -->
</property>

<!-- 客户端配置 -->
<property>
  <name>dfs.client.failover.proxy.provider.mycluster</name>
  <value>org.apache.hadoop.hdfs.server.namenode.ha.ObserverReadProxyProvider</value>
</property>
<property>
  <name>dfs.client.failover.observer.retries</name>
  <value>3</value>
</property>
```

**启动Observer**：
```bash
# 格式化Observer（如果是新增节点）
hdfs namenode -bootstrapStandby

# 以Observer角色启动
hdfs --daemon start namenode

# 切换为Observer状态
hdfs haadmin -transitionToObserver nn3
```

### 4.2 案例二：Observer追尾延迟过大排障

**症状**：客户端频繁收到`ObserverRetryOnActiveException`，读请求全部回退到Active。

**排查步骤**：
```bash
# 1. 检查Observer的State ID与Active差距
hdfs haadmin -getServiceState nn1  # ACTIVE, stateId=100000
hdfs haadmin -getServiceState nn3  # OBSERVER, stateId=99500
# 差距500个事务

# 2. 检查追尾线程日志
grep "Loaded.*edits" /var/log/hadoop/namenode-observer.log | tail -5
# "Loaded 0 edits starting from txid 99501"  ← 没有可读的新segment！

# 3. 检查JournalNode上的EditLog状态
hdfs dfsadmin -fetchImage /tmp/observer-image
# 或直接看JN目录
ls /data/journal/mycluster/current/
# edits_inprogress_0000000000000099501  ← Active还没roll！

# 4. 根因：logRollPeriod太大
# 解决：减小roll间隔或启用in-progress tailing
```

**修复**：
```xml
<!-- 方案1：减小Active的EditLog roll间隔 -->
<property>
  <name>dfs.ha.log-roll.period</name>
  <value>2</value>  <!-- 每2秒roll一次 -->
</property>

<!-- 方案2：启用in-progress追尾（推荐） -->
<property>
  <name>dfs.ha.tail-edits.in-progress</name>
  <value>true</value>
</property>
<property>
  <name>dfs.journalnode.edit-cache-size.bytes</name>
  <value>1048576</value>  <!-- JournalNode缓存最近1MB的edits -->
</property>
```

### 4.3 关键参数调优

| 参数 | 默认值 | Observer推荐值 | 说明 |
|------|--------|---------------|------|
| `dfs.ha.tail-edits.period` | 60s | 0.5-2s | 追尾轮询间隔 |
| `dfs.ha.log-roll.period` | 120s | 2-5s | 触发Active roll间隔 |
| `dfs.ha.tail-edits.in-progress` | false | true | 读inprogress文件 |
| `dfs.journalnode.edit-cache-size.bytes` | 1MB | 1-10MB | JN缓存大小 |
| `dfs.client.failover.observer.retries` | 0 | 3 | Observer失败重试次数 |
| `dfs.namenode.observer.stateId.wait.timeout` | 0 | 5000ms | Observer等待追上stateId的超时 |

### 4.4 监控指标

```bash
# Observer NN JMX
curl http://observer:9870/jmx | jq '.beans[] | select(.name | contains("NameNodeStatus"))'
# State: "observer"
# LastAppliedTxId: 99998  (即State ID)
# LastWrittenTransactionId: 同上（Observer不写）

# 关键指标
# - TransactionsSinceLastCheckpoint: 自上次checkpoint以来的事务数
# - LastCheckpointTime: 上次checkpoint时间
# - MillisSinceLastLoadedEdits: 距上次加载edits的毫秒数

# 观察追尾延迟
# Active TxId - Observer TxId = 追尾延迟（事务数）
# MillisSinceLastLoadedEdits 持续增大 = 追尾卡住
```

---

## 五、举一反三

### 5.1 与其他系统的类比

| 系统 | 主节点 | 只读副本 | 一致性保证 |
|------|--------|---------|-----------|
| HDFS Observer NN | Active NN | Observer NN | State ID（因果一致性） |
| MySQL | Master | Read Replica | GTID / semi-sync |
| PostgreSQL | Primary | Hot Standby | LSN（Log Sequence Number） |
| ZooKeeper | Leader | Follower（读） | ZxId（Transaction ID） |
| etcd (Raft) | Leader | Follower（线性化读需lease） | Raft Log Index |

**共同模式**：所有系统都使用某种"日志序列号"来标识一致性点位，客户端通过携带"我上次见过的序列号"来保证"read-your-writes"。

### 5.2 Observer NN vs 客户端缓存

为什么不在客户端做metadata缓存？
1. **缓存失效难**：文件系统变化频繁，客户端无法得知何时失效
2. **一致性难保证**：多客户端之间缓存不一致
3. **大量连接**：每个客户端都要感知变化，连接数爆炸
4. **Observer方案**：单点追尾、集中管理、天然一致

### 5.3 面试高频题

**Q1：Observer NameNode和Standby NameNode有什么本质区别？**

A：
- Standby不服务任何客户端请求，仅作为failover备份
- Observer主动服务只读请求（getFileInfo、listStatus、getBlockLocations等）
- Observer不参与Active选举，不能被提升为Active
- 可以部署多个Observer实现读水平扩展，但Standby通常只有一个

**Q2：Observer如何保证一致性？客户端写完后读Observer能读到吗？**

A：通过State ID机制保证"read-your-writes"：
1. 客户端每次写操作后，从响应中获取Active的最新TxId（State ID）
2. 后续读请求携带该State ID发给Observer
3. Observer检查自己的lastAppliedTxId是否≥客户端要求的State ID
4. 如果不够，Observer可以短暂等待追尾追上，或者拒绝让客户端重试/回退Active
5. msync操作允许客户端主动向Active查询最新State ID

**Q3：EditLogTailer为什么要触发Active做log roll？能不能直接读inprogress文件？**

A：
- 早期设计（Hadoop 2.x）中，inprogress文件格式不保证随时可读（可能有未flush的数据）
- 触发roll后，Active关闭当前segment并finalize，Standby/Observer就能安全读取
- Hadoop 3.x引入了"in-progress tailing"优化，通过JournalNode的RPC接口（而非直接读文件）获取最新的edits，避免了文件完整性问题
- in-progress tailing可将追尾延迟从分钟级降到毫秒级

**Q4：如果Observer NN宕机了会怎样？**

A：
- 客户端的ObserverReadProxyProvider会自动failover到其他Observer或回退Active
- 不影响写操作（写始终走Active）
- 不影响HA failover（Observer不参与Active选举）
- 重启后Observer重新追尾EditLog，追上后恢复服务

### 5.4 思考题

1. 如果Observer追尾延迟为5秒，那么客户端通过Observer读到的文件列表最多落后多久？这对Hive查询有什么影响？
2. 为什么Observer需要接收BlockReport？如果Observer没有Block Location信息，能回答`getBlockLocations`吗？
3. 在一个有3个Observer的集群中，不同Observer的State ID可能不同。客户端如何选择"最优"的Observer？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────────┐
│          Observer NameNode 只读扩展 · 知识晶体                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  【角色三兄弟】                                                      │
│  Active: 读+写，权威状态，生成EditLog                               │
│  Standby: 追尾EditLog，不服务请求，failover候选                     │
│  Observer: 追尾EditLog，服务只读请求，不参与选举                     │
│                                                                     │
│  【追尾机制 - EditLogTailer】                                        │
│  while(true) {                                                      │
│    if (太久没加载 && 有新事务) → triggerActiveLogRoll()              │
│    streams = editLog.selectInputStreams(lastTxnId + 1)              │
│    image.loadEdits(streams)  // 回放到namespace                     │
│    lastLoadedTxnId = image.getLastAppliedTxId()  // 更新State ID    │
│    sleep(sleepTimeMs)                                               │
│  }                                                                  │
│                                                                     │
│  【一致性保证 - State ID + msync】                                   │
│  Client write → Active返回stateId=N → Client记住N                  │
│  Client read → 携带stateId=N发给Observer                           │
│  Observer检查: myTxId >= N? → 是:响应 / 否:等待或拒绝              │
│  msync: Client向Active查询最新TxId的轻量级RPC                      │
│                                                                     │
│  【客户端路由 - ObserverReadProxyProvider】                          │
│  写操作 → 始终发给Active                                            │
│  读操作 → 优先Observer，失败重试其他Observer，最后回退Active         │
│                                                                     │
│  【关键调优】                                                        │
│  dfs.ha.tail-edits.period = 1s (降低追尾延迟)                       │
│  dfs.ha.tail-edits.in-progress = true (读inprogress减少延迟)        │
│  dfs.ha.log-roll.period = 2s (频繁roll加速finalize)                 │
│                                                                     │
│  【适用场景】                                                        │
│  ✓ NN读压力大（>70%为读操作）  ✓ 大集群(5000+节点)                  │
│  ✓ 对读一致性要求非强一致      ✗ 写密集型（Observer帮不上忙）        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ha/EditLogTailer.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ha/HAState.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ha/StandbyState.java`
   - `hadoop-hdfs-client/.../ha/ObserverReadProxyProvider.java`（Hadoop 3.x）

2. **设计文档**
   - HDFS-12943: Consistent reads from Observer NameNode
   - HDFS-13572: ObserverReadProxyProvider
   - HDFS-14235: In-progress edit log tailing

3. **官方文档**
   - Apache Hadoop: Observer NameNode Guide
   - HDFS High Availability with NFS / QJM
