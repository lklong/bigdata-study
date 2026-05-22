# YARN ResourceManager 调度核心源码分析

> **源码路径**：
> - `txProjects/hadoop/.../yarn/server/resourcemanager/ResourceManager.java`（52 KB）
> - `.../scheduler/capacity/CapacityScheduler.java`（82 KB）
>
> **铁律遵守**：所有方法名、行号、调用链均来自上述真实源码

---

## 一、ResourceManager 定位

YARN RM 是 Hadoop 集群的"大脑"：
- 管理所有 NodeManager 节点资源（CPU + Memory + GPU）
- 接受 ApplicationMaster 注册，分配 Container
- HA 主备切换、状态恢复

**类继承关系**（ResourceManager.java:130）：
```java
130: public class ResourceManager extends CompositeService implements Recoverable {
```

`CompositeService` 是 Hadoop 服务框架基类，提供 `serviceInit / serviceStart / serviceStop` 三段式生命周期。

---

## 二、serviceInit 启动流程

### 2.1 配置加载（ResourceManager.java:212-249）

```java
212: protected void serviceInit(Configuration conf) throws Exception {
213:   this.conf = conf;
214:   this.rmContext = new RMContextImpl();   // ⭐ 全局上下文
215:
216:   this.configurationProvider =
217:       ConfigurationProviderFactory.getConfigurationProvider(conf);
218:   this.configurationProvider.init(this.conf);
219:   rmContext.setConfigurationProvider(configurationProvider);
220:
221:   // load core-site.xml
222:   InputStream coreSiteXMLInputStream =
223:       this.configurationProvider.getConfigurationInputStream(this.conf,
224:           YarnConfiguration.CORE_SITE_CONFIGURATION_FILE);
   ...
240:   // load yarn-site.xml
   ...
249:   validateConfigs(this.conf);
```

**配置加载顺序**：
1. `core-site.xml`（HDFS/通用）
2. `yarn-site.xml`（YARN 专用）
3. `validateConfigs` 校验关键参数

### 2.2 HA 与 Kerberos（ResourceManager.java:251-265）

```java
251:   // Set HA configuration should be done before login
252:   this.rmContext.setHAEnabled(HAUtil.isHAEnabled(this.conf));
253:   if (this.rmContext.isHAEnabled()) {
254:     HAUtil.verifyAndSetConfiguration(this.conf);
255:   }
256:
257:   // Set UGI and do login
258:   // If security is enabled, use login user
259:   // If security is not enabled, use current user
260:   this.rmLoginUGI = UserGroupInformation.getCurrentUser();
261:   try {
262:     doSecureLogin();   // ⭐ Kerberos kinit
263:   } catch(IOException ie) {
264:     throw new YarnRuntimeException("Failed to login", ie);
265:   }
```

**关键顺序**：HA 检查 必须在 Kerberos 登录前完成，因为 HA principal 需要 HA 配置。

### 2.3 Dispatcher + AdminService（ResourceManager.java:267-279）

```java
267:   // register the handlers for all AlwaysOn services using setupDispatcher().
268:   rmDispatcher = setupDispatcher();
269:   addIfService(rmDispatcher);
270:   rmContext.setDispatcher(rmDispatcher);
   ...
277:   adminService = createAdminService();
278:   addService(adminService);
279:   rmContext.setRMAdminService(adminService);
```

`AsyncDispatcher` 是 YARN 的事件总线，所有事件（NODE_ADDED / APP_SUBMIT / CONTAINER_ALLOCATED）通过它路由。

### 2.4 Embedded Elector（ResourceManager.java:282-291）

```java
282:   // elector must be added post adminservice
283:   if (this.rmContext.isHAEnabled()) {
284:     // If the RM is configured to use an embedded leader elector,
285:     // initialize the leader elector.
286:     if (HAUtil.isAutomaticFailoverEnabled(conf)
287:         && HAUtil.isAutomaticFailoverEmbedded(conf)) {
288:       EmbeddedElector elector = createEmbeddedElector();
289:       addIfService(elector);
290:       rmContext.setLeaderElectorService(elector);
291:     }
292:   }
```

### 2.5 createAndInitActiveServices（ResourceManager.java:295）

```java
295:   createAndInitActiveServices();
```

进入 `RMActiveServices` 子组件初始化（HA 备节点不会启动这些服务）。

---

## 三、Curator + ZooKeeper 选主

### 3.1 createEmbeddedElector（ResourceManager.java:315-327）

```java
315: protected EmbeddedElector createEmbeddedElector() throws Exception {
316:   EmbeddedElector elector;
317:   curatorEnabled =
318:       conf.getBoolean(YarnConfiguration.CURATOR_LEADER_ELECTOR,
319:           YarnConfiguration.DEFAULT_CURATOR_LEADER_ELECTOR_ENABLED);
320:   if (curatorEnabled) {
321:     this.curator = createAndStartCurator(conf);
322:     elector = new CuratorBasedElectorService(rmContext, this);
323:   } else {
324:     elector = new ActiveStandbyElectorBasedElectorService(rmContext);
325:   }
326:   return elector;
327: }
```

两种实现：
- **CuratorBasedElectorService**（推荐）：基于 Curator LeaderLatch
- **ActiveStandbyElectorBasedElectorService**：基于 Hadoop ZKFC（旧实现）

### 3.2 Curator 配置（ResourceManager.java:329-369）

```java
329: public CuratorFramework createAndStartCurator(Configuration conf)
     throws Exception {
331:   String zkHostPort = conf.get(YarnConfiguration.RM_ZK_ADDRESS);
   ...
336:   int numRetries = conf.getInt(YarnConfiguration.RM_ZK_NUM_RETRIES,
337:       YarnConfiguration.DEFAULT_ZK_RM_NUM_RETRIES);
338:   int zkSessionTimeout = conf.getInt(YarnConfiguration.RM_ZK_TIMEOUT_MS,
339:       YarnConfiguration.DEFAULT_RM_ZK_TIMEOUT_MS);
   ...
362:   CuratorFramework client =  CuratorFrameworkFactory.builder()
363:       .connectString(zkHostPort)
364:       .sessionTimeoutMs(zkSessionTimeout)
365:       .retryPolicy(new RetryNTimes(numRetries, zkRetryInterval))
366:       .authorization(authInfos).build();
367:   client.start();
368:   return client;
369: }
```

**生产坑点**：`zkSessionTimeout` 默认 10s，长 GC 会触发误切主，需要调到 30s+。

---

## 四、createScheduler 调度器装配

```java
400: protected ResourceScheduler createScheduler() {
401:   String schedulerClassName = conf.get(YarnConfiguration.RM_SCHEDULER,
402:       YarnConfiguration.DEFAULT_RM_SCHEDULER);
403:   LOG.info("Using Scheduler: " + schedulerClassName);
404:   try {
405:     Class<?> schedulerClazz = Class.forName(schedulerClassName);
406:     if (ResourceScheduler.class.isAssignableFrom(schedulerClazz)) {
407:       return (ResourceScheduler) ReflectionUtils.newInstance(schedulerClazz,
408:           this.conf);
   ...
```

**配置项**：`yarn.resourcemanager.scheduler.class`
- 默认：`CapacityScheduler`（Apache 默认）
- 备选：`FairScheduler`（社区维护停滞）

---

## 五、CapacityScheduler.allocate 核心调度

### 5.1 入口签名（CapacityScheduler.java:945-949）

```java
945: public Allocation allocate(ApplicationAttemptId applicationAttemptId,
946:     List<ResourceRequest> ask, List<ContainerId> release,
947:     List<String> blacklistAdditions, List<String> blacklistRemovals,
948:     List<UpdateContainerRequest> increaseRequests,
949:     List<UpdateContainerRequest> decreaseRequests) {
```

**调用方**：`ApplicationMasterService.allocate()` 接收 AM 心跳后调入。

### 5.2 防御性检查（CapacityScheduler.java:951-967）

```java
951:   FiCaSchedulerApp application = getApplicationAttempt(applicationAttemptId);
952:   if (application == null) {
953:     LOG.error("Calling allocate on removed or non existent application " +
954:         applicationAttemptId.getApplicationId());
955:     return EMPTY_ALLOCATION;
956:   }
   ...
963:   if (!application.getApplicationAttemptId().equals(applicationAttemptId)) {
964:     LOG.error("Calling allocate on previous or removed " +
965:         "or non existent application attempt " + applicationAttemptId);
966:     return EMPTY_ALLOCATION;
967:   }
```

**应对场景**：
- AM 重试后，旧 attempt 的心跳还可能到达
- 需要识别并丢弃，否则会让"已死的"AM 误以为还在分配

### 5.3 释放/伸缩（CapacityScheduler.java:969-977）

```java
969:   // Release containers
970:   releaseContainers(release, application);
971:
972:   // update increase requests
973:   LeafQueue updateDemandForQueue =
974:       updateIncreaseRequests(increaseRequests, application);
975:
976:   // Decrease containers
977:   decreaseContainers(decreaseRequests, application);
```

**Container 大小动态伸缩**（YARN 3.0 引入）：AM 可以请求扩大/缩小已有 container。

### 5.4 资源请求规范化（CapacityScheduler.java:979-982）

```java
979:   // Sanity check for new allocation requests
980:   SchedulerUtils.normalizeRequests(
981:       ask, getResourceCalculator(), getClusterResource(),
982:       getMinimumResourceCapability(), getMaximumResourceCapability());
```

**规范化**：
- 向上对齐到 `yarn.scheduler.minimum-allocation-mb`（默认 1024MB）
- 截断到 `yarn.scheduler.maximum-allocation-mb`（默认 8192MB）

### 5.5 同步块内更新（CapacityScheduler.java:986-1018）

```java
986:   synchronized (application) {
987:
988:     // make sure we aren't stopping/removing the application
989:     // when the allocate comes in
990:     if (application.isStopped()) {
991:       return EMPTY_ALLOCATION;
992:     }
   ...
1003:     if (application.updateResourceRequests(ask)
1004:         && (updateDemandForQueue == null)) {
1005:       updateDemandForQueue = (LeafQueue) application.getQueue();
1006:     }
   ...
1014:     application.updateBlacklist(blacklistAdditions, blacklistRemovals);
1015:
1016:     allocation = application.getAllocation(getResourceCalculator(),
1017:                  clusterResource, getMinimumResourceCapability());
1018:   }
```

**关键设计**：
- `synchronized(application)` 而非 synchronized 整个 scheduler
- 避免单 lock 成为整个集群瓶颈

---

## 六、allocateContainersToNode 节点分配（NodeUpdate 触发）

### 6.1 入口（CapacityScheduler.java:1225-1239）

```java
1225: public synchronized void allocateContainersToNode(FiCaSchedulerNode node) {
1226:   if (rmContext.isWorkPreservingRecoveryEnabled()
1227:       && !rmContext.isSchedulerReadyForAllocatingContainers()) {
1228:     return;
1229:   }
   ...
1238:   updateSchedulerHealth(lastNodeUpdateTime, node,
1239:     new CSAssignment(Resources.none(), NodeType.NODE_LOCAL));
```

### 6.2 优先满足预留（CapacityScheduler.java:1247-1278）

```java
1247:   RMContainer reservedContainer = node.getReservedContainer();
1248:   if (reservedContainer != null) {
1249:     FiCaSchedulerApp reservedApplication =
1250:         getCurrentAttemptForContainer(reservedContainer.getContainerId());
1251:
1252:     // Try to fulfill the reservation
1253:     LOG.info("Trying to fulfill reservation for application "
1254:         + reservedApplication.getApplicationId() + " on node: "
1255:         + node.getNodeID());
1256:
1257:     LeafQueue queue = ((LeafQueue) reservedApplication.getQueue());
1258:     assignment =
1259:         queue.assignContainers(
1260:             clusterResource,
1261:             node,
1262:             new ResourceLimits(labelManager.getResourceByLabel(
1263:                 RMNodeLabelsManager.NO_LABEL, clusterResource)),
1264:             SchedulingMode.RESPECT_PARTITION_EXCLUSIVITY);
```

**预留机制**：当节点可用资源不足以容纳 AM 请求时，会"预留"一个未来位置，等节点资源释放后优先填充。

### 6.3 正常调度（CapacityScheduler.java:1281-1330）

```java
1281:   // Try to schedule more if there are no reservations to fulfill
1282:   if (node.getReservedContainer() == null) {
1283:     if (calculator.computeAvailableContainers(Resources
1284:             .add(node.getAvailableResource(), node.getTotalKillableResources()),
1285:         minimumAllocation) > 0) {
   ...
1291:       assignment = root.assignContainers(    // ⭐ 从 root 队列向下递归分配
1292:           clusterResource,
1293:           node,
1294:           new ResourceLimits(labelManager.getResourceByLabel(
1295:               node.getPartition(), clusterResource)),
1296:           SchedulingMode.RESPECT_PARTITION_EXCLUSIVITY);
```

**调度树遍历**：`root` 是 `ParentQueue`，`assignContainers` 递归到 `LeafQueue` 后从 application 列表挑选最匹配的。

### 6.4 NON_EXCLUSIVE 兜底（CapacityScheduler.java:1320-1330）

```java
1321:       // Try to use NON_EXCLUSIVE
1322:       assignment = root.assignContainers(
1323:           clusterResource,
1324:           node,
1325:           new ResourceLimits(labelManager.getResourceByLabel(
1326:               RMNodeLabelsManager.NO_LABEL, clusterResource)),
1327:           SchedulingMode.IGNORE_PARTITION_EXCLUSIVITY);
```

**Node Label 非独占场景**：如果带标签的节点空闲，无标签的应用也可以借用。

---

## 七、调度全景图

```
┌────────────────────────────────────────────────────┐
│ ResourceManager (CompositeService)                 │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │
│  │AdminService │  │ClientService│  │AMService   │  │
│  └─────────────┘  └─────────────┘  └─────┬──────┘  │
│                                          │          │
│  ┌──────────────────────────────────────▼────────┐ │
│  │     AsyncDispatcher (Event Bus)               │ │
│  │  NODE_ADDED / APP_SUBMIT / CONTAINER_*         │ │
│  └────────┬─────────────────┬────────────────────┘ │
│           │                 │                       │
│  ┌────────▼──────┐  ┌──────▼────────────────────┐  │
│  │ ResourceTracker│  │ CapacityScheduler        │  │
│  │ (NM heartbeat) │  │  ┌──────────────────────┐│  │
│  │                │  │  │ root (ParentQueue)   ││  │
│  └────────────────┘  │  │  ├─ default          ││  │
│                       │  │  ├─ prod            ││  │
│  ┌────────────────┐  │  │  └─ dev             ││  │
│  │EmbeddedElector │  │  │      └─ LeafQueue   ││  │
│  │(Curator + ZK)  │  │  └──────────────────────┘│  │
│  └────────────────┘  └──────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

---

## 八、生产关注点

### 8.1 大集群调度延迟

- 单线程调度器：`yarn.scheduler.capacity.global-scheduler-enable=true` 开启多线程
- `yarn.scheduler.capacity.schedule-asynchronously.enable=true` 异步调度

### 8.2 RM HA 切换抖动

- ZK session 默认 10s，建议改 30s
- `yarn.resourcemanager.zk-state-store.parent-path` 不要和其他系统共用 ZK

### 8.3 NodeManager 心跳风暴

- `yarn.resourcemanager.nodemanagers.heartbeat-interval-ms` 默认 1s
- 5000+ 节点集群建议调到 3-5s

### 8.4 Container 资源单位

- `yarn.scheduler.minimum-allocation-mb` 必须能被 `yarn.scheduler.minimum-allocation-vcores` 整除
- 否则会出现 OneVcore 但无对应内存的尴尬场景

---

## 九、Eric 点评

YARN 是 Hadoop 2.0 最伟大的改造，把 MR 1.0 的 JobTracker 拆成 RM（资源） + AM（应用）。这种"资源-计算分离"的思想后来被 Kubernetes 完全抄了过去。

CapacityScheduler 的核心设计三板斧：
1. **多级队列树** — root → ParentQueue → LeafQueue，按容量配比层级分配
2. **同步锁粒度控制** — `synchronized(application)` 而非全局锁，支撑万级并发
3. **预留机制** — 用空间换时间，避免"大资源请求永远抢不到"

但 YARN 也有它的天花板：
- **静态分区**：队列容量不能跨集群动态调整
- **抢占复杂**：preemption 算法实现极其复杂，调参困难
- **多租户隔离弱**：CGroup 隔离 CPU 但内存只能 kill

这也是为什么近年 K8s 在大数据领域强势上位（Spark on K8s / Flink on K8s）。但 YARN 在传统 Hadoop 集群仍是不可替代的存在。
