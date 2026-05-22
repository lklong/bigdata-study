# HDFS NameNode 元数据管理源码分析

> **源码路径**：`txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/NameNode.java`（70.96 KB）
> **铁律遵守**：所有方法名、行号引用均来自上述真实源码

---

## 一、NameNode 定位

NameNode 是 HDFS 的"大脑"，管理整个文件系统的命名空间和块到节点的映射。

**官方注释（NameNode.java:150-167）**：
```java
150: /**********************************************************
151:  * NameNode serves as both directory namespace manager and
152:  * "inode table" for the Hadoop DFS.  There is a single NameNode
153:  * running in any DFS deployment.
   ...
156:  * The NameNode controls two critical tables:
157:  *   1)  filename->blocksequence (namespace)
158:  *   2)  block->machinelist ("inodes")
159:  *
160:  * The first table is stored on disk and is very precious.
161:  * The second table is rebuilt every time the NameNode comes up.
   ...
164:  * The 'FSNamesystem' class actually performs most of the filesystem
165:  * management.
166:  **********************************************************/
```

**两张核心表**：
1. **filename → blocksequence**（命名空间）：持久化在 FSImage + EditLog
2. **block → machinelist**（块映射）：每次重启重建，由 DataNode 上报

---

## 二、NameNode 类继承关系

```java
187: @InterfaceAudience.Private
188: public class NameNode implements NameNodeStatusMXBean {
189:   static{
190:     HdfsConfiguration.init();
191:   }
```

**Operation 分类**（NameNode.java:196-199）：
```java
196: public static enum OperationCategory {
197:   /** Operations that are state agnostic */
198:   UNCHECKED,
199:   /** Read operation that does not change the namespace state */
```

**OperationCategory 枚举完整列表**：
- `UNCHECKED`：状态无关（如 ping）
- `READ`：只读操作，Standby 也能服务
- `WRITE`：必须 Active 才能执行
- `JOURNAL`：写入 EditLog
- `CHECKPOINT`：checkpoint 操作

---

## 三、initialize 启动核心流程（NameNode.java:673-714）

```java
673: protected void initialize(Configuration conf) throws IOException {
   ...
682:   UserGroupInformation.setConfiguration(conf);
683:   loginAsNameNodeUser(conf);              // ⭐ Kerberos 登录
   
685:   NameNode.initMetrics(conf, this.getRole());
686:   StartupProgressMetrics.register(startupProgress);
687:
688:   pauseMonitor = new JvmPauseMonitor(conf);  // ⭐ JVM 长停顿监控
689:   pauseMonitor.start();
690:   metrics.getJvmMetrics().setPauseMonitor(pauseMonitor);
691:
692:   if (NamenodeRole.NAMENODE == role) {
693:     startHttpServer(conf);                   // ⭐ HTTP 50070
694:   }
695:
696:   loadNamesystem(conf);                       // ⭐ 加载 FSImage + replay EditLog
697:
698:   rpcServer = createRpcServer(conf);          // ⭐ RPC 8020
   ...
712:   startCommonServices(conf);
713:   startMetricsLogger(conf);
714: }
```

**启动 6 步**：
1. **Kerberos 登录**（loginAsNameNodeUser）
2. **JVM Pause Monitor 启动**（监控 GC 长停顿，超过 1s 报警）
3. **HTTP Server 启动**（用于 fsck、JMX、Web UI）
4. **loadNamesystem**：加载 FSImage 并回放 EditLog
5. **RPC Server 创建**：但还未 start
6. **startCommonServices**：启动通用服务，最后 rpcServer.start()

---

## 四、loadNamesystem 元数据加载（NameNode.java:634-636）

```java
634: protected void loadNamesystem(Configuration conf) throws IOException {
635:   this.namesystem = FSNamesystem.loadFromDisk(conf);
636: }
```

**FSNamesystem.loadFromDisk 核心动作**：
1. 读取 `dfs.namenode.name.dir` 下最新的 `fsimage_NNNN`
2. 反序列化 INode 树到 JVM 内存
3. 应用 `edits_NNNN-MMMM` 中的所有未 checkpoint 操作
4. 标记进入 SafeMode，等待 DataNode 上报块

**关键性能**：
- 大集群（10 亿+ inode）启动时间可达 30+ 分钟
- 启动期间所有 RPC 走 SafeMode 拒绝
- HA 场景下，Standby 通过 JournalNode 持续 tail editlog

---

## 五、Kerberos 登录（NameNode.java:662-666）

```java
662: void loginAsNameNodeUser(Configuration conf) throws IOException {
663:   InetSocketAddress socAddr = getRpcServerAddress(conf);
664:   SecurityUtil.login(conf, DFS_NAMENODE_KEYTAB_FILE_KEY,
665:       DFS_NAMENODE_KERBEROS_PRINCIPAL_KEY, socAddr.getHostName());
666: }
```

**配置项**：
- `dfs.namenode.kerberos.principal`：principal 模板（如 `nn/_HOST@REALM`）
- `dfs.namenode.keytab.file`：keytab 路径
- `_HOST` 占位符会被替换为 `socAddr.getHostName()`，支持多 NN 部署

---

## 六、RPC Server 创建（NameNode.java:754-757）

```java
754: protected NameNodeRpcServer createRpcServer(Configuration conf)
755:     throws IOException {
756:   return new NameNodeRpcServer(conf, this);
757: }
```

`NameNodeRpcServer` 实现的协议：
- **ClientProtocol**：客户端（hdfs dfs / Spark / Hive）调用
- **DatanodeProtocol**：DN 注册、心跳、blockReport
- **NamenodeProtocol**：SecondaryNameNode 拉取 FSImage
- **HAServiceProtocol**：HA 切换控制

---

## 七、startCommonServices（NameNode.java:760-790）

```java
760: private void startCommonServices(Configuration conf) throws IOException {
761:   namesystem.startCommonServices(conf, haContext);  // ⭐ 启动块管理、心跳监控
762:   registerNNSMXBean();                                // 注册 JMX
763:   if (NamenodeRole.NAMENODE != role) {
764:     startHttpServer(conf);
765:     httpServer.setNameNodeAddress(getNameNodeAddress());
766:     httpServer.setFSImage(getFSImage());
767:   }
768:   rpcServer.start();                                  // ⭐ RPC 真正开始服务
769:   try {
770:     plugins = conf.getInstances(DFS_NAMENODE_PLUGINS_KEY,
771:         ServicePlugin.class);
772:   } catch (RuntimeException e) {
   ...
778:   for (ServicePlugin p: plugins) {
779:     try {
780:       p.start(this);                                  // ⭐ 加载第三方插件（Ranger 等）
   ...
785:   LOG.info(getRole() + " RPC up at: " + getNameNodeAddress());
   ...
790: }
```

**关键启动顺序**：
1. `namesystem.startCommonServices`：启动 BlockManager、HeartbeatManager、ReplicationMonitor
2. `rpcServer.start()`：开始接受 RPC 请求
3. `plugins.start()`：加载第三方扩展（如 Ranger HDFS Plugin）

---

## 八、NameNode 服务全景

```
┌─────────────────────────────────────────────────┐
│ NameNode (extends NameNodeStatusMXBean)         │
│  ┌─────────────────────────────────────────┐    │
│  │ FSNamesystem (273 KB)                   │    │
│  │  ┌─────────────┐  ┌────────────────┐    │    │
│  │  │ FSDirectory │  │ BlockManager  │    │    │
│  │  │ (INode 树)  │  │ blockMap +    │    │    │
│  │  │             │  │ 副本管理       │    │    │
│  │  └─────────────┘  └────────────────┘    │    │
│  │  ┌─────────────┐  ┌────────────────┐    │    │
│  │  │ FSEditLog   │  │HeartbeatManager│    │    │
│  │  │JournalSet   │  │NodeManager     │    │    │
│  │  └─────────────┘  └────────────────┘    │    │
│  └─────────────────────────────────────────┘    │
│                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────┐   │
│  │NameNodeRpc   │  │NameNodeHttp  │  │Plugins│  │
│  │Server (8020) │  │Server (50070)│  │  集合 │  │
│  └──────────────┘  └──────────────┘  └──────┘   │
│  ┌──────────────┐  ┌──────────────┐             │
│  │JvmPauseMonitor│ │HAContext     │             │
│  │              │  │(主备切换状态机)│             │
│  └──────────────┘  └──────────────┘             │
└─────────────────────────────────────────────────┘
```

---

## 九、HA 状态机

NameNode 的 HA 状态由 `HAState` 枚举管理：
- **ACTIVE**：处理写请求、维护 EditLog
- **STANDBY**：tail JournalNode、不接受写
- **OBSERVER**：tail EditLog 后可服务读请求（HDFS 3.x 引入）

**OperationCategory 检查**（NameNode.java:196）控制不同状态下哪些操作能执行。

---

## 十、生产关注点

### 10.1 FSImage 大小

- 每个 INode 大约 200-300 字节
- 1 亿 inode ≈ 30 GB FSImage 文件
- 建议开启 FSImage 增量 checkpoint（HDFS 3.x）

### 10.2 EditLog 写入

- 默认 `dfs.journalnode.edits.dir` 写本地磁盘
- HA 场景下，EditLog 必须**多数派 JournalNode 都写成功**才返回（QJM 协议）
- JournalNode 之间故障会拖累 NN 写入延迟

### 10.3 JVM Pause Monitor

```
WARN org.apache.hadoop.util.JvmPauseMonitor: 
Detected pause in JVM or host machine (eg GC): pause of approximately 5234ms
GC pool 'ParNew' had collection(s): count=1 time=5232ms
```

任何 > 1s 的 pause 都会被记录，> 10s 触发 ZKFC 切主。

### 10.4 RPC 队列

- `ipc.8020.callqueue.impl`：默认 LinkedBlockingQueue
- 建议用 `FairCallQueue` 防止单租户打爆 RPC

---

## 十一、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.namenode.name.dir` | - | FSImage + EditLog 存储路径 |
| `dfs.namenode.shared.edits.dir` | - | HA 模式下 JournalNode 路径 |
| `dfs.namenode.handler.count` | 10 | RPC 处理线程数（大集群建议 200+） |
| `dfs.namenode.service.handler.count` | 10 | 服务 RPC 端口处理线程数 |
| `dfs.namenode.checkpoint.period` | 3600s | Checkpoint 周期 |
| `dfs.namenode.checkpoint.txns` | 1000000 | Checkpoint 事务数阈值 |

---

## 十二、Eric 点评

NameNode 是大数据栈中**最朴素、最稳健**的组件之一，架构 17 年来基本未变。它的核心设计哲学：

1. **集中式元数据**：单点设计，但通过 HA + 高速 RPC 抗住了百亿级文件
2. **EditLog + FSImage**：经典的 WAL + Snapshot 模式
3. **Block 映射不持久化**：用启动时间换运行时一致性

NameNode 也有它的**老顽固问题**：
- **单 JVM 内存上限**：通常 256GB JVM = 5-10 亿 inode 极限
- **Federation 不解决根问题**：多 NN 切分 namespace，应用层感知
- **小文件杀手**：100 万 小文件 ≈ 100 万 INode + 100 万 Block ≈ 600MB 元数据

**进化方向**：
- **Ozone** — 基于 Raft 的对象存储，元数据分布式
- **HDFS 3.x Observer NN** — 缓解读压力
- **HDFS Router-based Federation** — 无侵入挂载多 NN

理解 NameNode 是理解所有大数据系统"元数据中心化 vs 分布式"权衡的起点。
