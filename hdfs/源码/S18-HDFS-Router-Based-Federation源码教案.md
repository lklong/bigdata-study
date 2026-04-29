# [教案] HDFS Router-Based Federation源码深度剖析

> 🎯 教学目标：掌握HDFS Router-Based Federation的架构设计、Router路由机制、StateStore状态管理、MountTable挂载表配置，以及与传统ViewFS Federation的对比  
> ⏰ 预计学时：3学时  
> 📊 难度：★★★★☆

---

## 一、课前导入（生活类比/故障场景引入）

### 1.1 生活类比：大型商场的"总服务台"

想象一座超大型商业综合体，由A、B、C三栋独立大楼组成：
- **各栋大楼** = 各个NameNode命名空间（子集群）
- **总服务台（Router）** = 统一入口，顾客不需要知道想去的店在哪栋楼
- **楼层目录（MountTable）** = `/服装` → A栋3层，`/餐饮` → B栋1层
- **物业管理系统（StateStore）** = 记录各栋楼的运营状态

顾客（客户端）只需告诉总服务台"我要去优衣库"，服务台查目录后自动引导到正确的楼，顾客无需了解后端三栋楼的划分。

### 1.2 生产痛点引入

**问题1：ViewFS的痛苦**
- 每个客户端都要配置完整的命名空间映射（core-site.xml的viewfs配置）
- 新增子集群要推送配置到所有客户端节点（数千台）
- 配置错误导致作业写错集群

**问题2：单NN扩展瓶颈**
- 单个NameNode支撑不了超过5亿文件
- 内存限制（300GB堆→约6亿对象）
- 但传统Federation需要客户端感知拓扑

**解决方案**：Router-Based Federation——在NN前面加一层透明路由层。

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| Router | 路由器 | 无状态代理层，接收客户端请求并路由到正确的子集群 |
| StateStore | 状态存储 | 存储集群拓扑、挂载表、Router心跳等元数据（ZK/文件/DB） |
| MountTable | 挂载表 | 路径到子集群的映射关系 |
| SubCluster | 子集群 | 一个独立的NameNode命名空间 |
| RouterRpcServer | Router RPC服务 | 实现ClientProtocol接口，伪装成NameNode |
| RouterClientProtocol | Router客户端协议 | Router对外暴露的文件系统API |
| Nameservice | 命名服务 | 一个HA NameNode对（Active+Standby）的逻辑名 |
| MountTableResolver | 挂载表解析器 | 根据路径前缀查找目标子集群的组件 |

### 2.2 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Client                                       │
│  DFSClient → hdfs://myfed/data/warehouse/...                        │
│  (不需要知道后端有几个子集群!)                                        │
└────────────────────────────────┬────────────────────────────────────┘
                                 │ ClientProtocol RPC
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Router Layer (可部署多个)                          │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  RouterRpcServer (实现ClientNamenodeProtocol)                 │    │
│  │    │                                                          │    │
│  │    ├── MountTableResolver                                     │    │
│  │    │     /data/warehouse → ns1                               │    │
│  │    │     /data/logs      → ns2                               │    │
│  │    │     /user           → ns1                               │    │
│  │    │     /tmp            → ns3                               │    │
│  │    │                                                          │    │
│  │    ├── RouterRpcClient → 转发RPC到目标NameNode                │    │
│  │    │                                                          │    │
│  │    └── StateStoreDriver → 读取/更新集群状态                    │    │
│  └─────────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  RouterAdminServer (管理接口)                                  │    │
│  │    addMount / removeMount / listMounts / refreshMountTable    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└───────────┬──────────────────────────┬──────────────────┬───────────┘
            │                          │                  │
            ▼                          ▼                  ▼
┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐
│  SubCluster ns1   │  │  SubCluster ns2   │  │  SubCluster ns3   │
│  (Active + Standby)│  │  (Active + Standby)│  │  (Active + Standby)│
│  /data/warehouse  │  │  /data/logs       │  │  /tmp             │
│  /user            │  │                   │  │                   │
│  DataNodes...     │  │  DataNodes...     │  │  DataNodes...     │
└───────────────────┘  └───────────────────┘  └───────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    StateStore (ZooKeeper / File / MySQL)              │
│  ┌────────────┐  ┌──────────────────┐  ┌──────────────────────┐    │
│  │ MountTable │  │ MembershipStore  │  │ RouterStateStore     │    │
│  │ (挂载映射) │  │ (子集群注册信息) │  │ (Router心跳状态)    │    │
│  └────────────┘  └──────────────────┘  └──────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 Router vs ViewFS 对比

| 维度 | ViewFS (客户端Federation) | Router-Based Federation |
|------|--------------------------|------------------------|
| 路由位置 | 客户端 | 服务端(Router代理) |
| 配置管理 | 每个客户端都要配置 | 集中管理(StateStore) |
| 新增子集群 | 推送配置到所有客户端 | 更新MountTable即可 |
| 透明性 | 客户端必须知道拓扑 | 客户端完全无感 |
| 性能 | 无额外跳转 | 多一跳(Router→NN) |
| 高可用 | N/A | 多Router+负载均衡 |
| 跨子集群操作 | 不支持 | 部分支持(ls跨子集群) |

---

## 三、源码深度剖析

### 3.1 Router核心模块设计

> **注意**：Router-Based Federation于HDFS-10467（Hadoop 2.9+/3.0+）引入。本教案基于设计文档和Hadoop 3.x源码架构进行分析。
> 源码路径: `hadoop-hdfs-project/hadoop-hdfs-rbf/src/main/java/org/apache/hadoop/hdfs/server/federation/router/`

#### 3.1.1 Router启动入口

```java
// Router.java - 主入口类
public class Router extends CompositeService {
  private RouterRpcServer rpcServer;        // RPC服务（对外暴露ClientProtocol）
  private RouterAdminServer adminServer;    // 管理服务
  private RouterHttpServer httpServer;      // Web UI
  private StateStoreService stateStore;     // 状态存储连接
  private RouterHeartbeatService heartbeat; // Router自身心跳
  private Namenodes namenodes;              // 子集群NN发现
  
  @Override
  protected void serviceInit(Configuration conf) {
    // 1. 初始化StateStore连接
    this.stateStore = new StateStoreService();
    addService(this.stateStore);
    
    // 2. 初始化RPC Server
    this.rpcServer = new RouterRpcServer(conf, this);
    addService(this.rpcServer);
    
    // 3. 初始化Admin Server
    this.adminServer = new RouterAdminServer(conf, this);
    addService(this.adminServer);
    
    // 4. 初始化心跳服务
    this.heartbeat = new RouterHeartbeatService(this);
    addService(this.heartbeat);
  }
}
```

#### 3.1.2 RouterRpcServer——请求路由核心

```java
// RouterRpcServer.java
public class RouterRpcServer extends AbstractService 
    implements ClientProtocol, NamenodeProtocol {
  
  private final Router router;
  private final RouterRpcClient rpcClient;      // 到子集群NN的RPC客户端
  private final FileSubclusterResolver subclusterResolver;  // 路径解析器
  
  // 实现 ClientProtocol 的核心方法
  @Override
  public HdfsFileStatus getFileInfo(String src) throws IOException {
    // 1. 解析路径→目标子集群
    RemoteLocation location = getDestination(src);
    // 2. 转发RPC到目标子集群的NameNode
    return rpcClient.invokeSingle(location, "getFileInfo", 
        new Class[]{String.class}, new Object[]{location.getDest()});
  }
  
  @Override
  public DirectoryListing getListing(String src, byte[] startAfter, 
      boolean needLocation) throws IOException {
    // 特殊处理：如果src是挂载点的父目录，需要聚合多个子集群的结果
    List<RemoteLocation> locations = getDestinations(src);
    if (locations.size() > 1) {
      // 跨子集群listing —— 并行调用多个NN并合并结果
      return getListingFromMultipleNamespaces(src, locations, startAfter);
    }
    // 单子集群直接转发
    return rpcClient.invokeSingle(locations.get(0), "getListing", ...);
  }
  
  @Override
  public LocatedBlocks getBlockLocations(String src, long offset, long length) {
    RemoteLocation location = getDestination(src);
    return rpcClient.invokeSingle(location, "getBlockLocations", ...);
  }
  
  // 路径解析：根据MountTable确定目标子集群
  private RemoteLocation getDestination(String path) throws IOException {
    PathLocation pathLocation = subclusterResolver.getDestinationForPath(path);
    return pathLocation.getDefaultLocation();
  }
}
```

#### 3.1.3 MountTableResolver——挂载表解析器

```java
// MountTableResolver.java
public class MountTableResolver implements FileSubclusterResolver {
  
  // 挂载表：路径前缀 → 子集群映射
  // 使用TreeMap实现最长前缀匹配
  private final TreeMap<String, MountTable> mountTable = new TreeMap<>();
  // 缓存：避免每次请求都做前缀匹配
  private final Cache<String, PathLocation> locationCache;
  
  @Override
  public PathLocation getDestinationForPath(String path) throws IOException {
    // 1. 先查缓存
    PathLocation cached = locationCache.get(path);
    if (cached != null) return cached;
    
    // 2. 缓存未命中，做最长前缀匹配
    //    例如: path="/data/warehouse/dim/user"
    //    挂载表有: /data/warehouse → ns1, /data → ns2
    //    最长匹配: /data/warehouse → ns1
    String longestMatch = findLongestPrefix(path);
    MountTable entry = mountTable.get(longestMatch);
    
    // 3. 构造结果：目标子集群 + 子集群内路径
    RemoteLocation dest = entry.getDefaultLocation();
    // dest.nameserviceId = "ns1"
    // dest.dest = path (或经过路径转换后的path)
    
    PathLocation result = new PathLocation(dest, entry);
    locationCache.put(path, result);
    return result;
  }
  
  private String findLongestPrefix(String path) {
    // TreeMap的floorKey给出<=path的最大key
    // 逐级向上查找直到匹配
    String current = path;
    while (current != null && !current.isEmpty()) {
      if (mountTable.containsKey(current)) {
        return current;
      }
      current = getParentPath(current);
    }
    return "/";  // 默认挂载点
  }
}
```

#### 3.1.4 StateStore——集群状态存储

```java
// StateStoreService.java
public class StateStoreService extends CompositeService {
  
  private StateStoreDriver driver;  // 后端存储驱动（ZK/File/DB）
  
  // 核心存储表
  private MembershipStore membershipStore;     // 子集群注册信息
  private MountTableStore mountTableStore;     // 挂载表
  private RouterStore routerStore;             // Router状态
  private DisabledNameserviceStore disabledStore; // 禁用的子集群
  
  // 子集群注册信息
  public interface MembershipStore {
    // NN状态: nameserviceId, namenodeId, state(ACTIVE/STANDBY), 
    //         blocksTotal, filesTotal, capacity, etc.
    boolean namenodeHeartbeat(NamenodeMembershipRecord record);
    List<MembershipState> getActiveMemberships();
  }
  
  // 挂载表CRUD
  public interface MountTableStore {
    boolean addEntry(MountTable entry);
    boolean removeEntry(String path);
    boolean updateEntry(MountTable entry);
    List<MountTable> getMountTableEntries(String path);
  }
}
```

#### 3.1.5 RouterRpcClient——多子集群RPC调用

```java
// RouterRpcClient.java
public class RouterRpcClient {
  
  // 到各子集群NN的连接池
  private final ConnectionManager connectionManager;
  
  // 单目标调用
  public <T> T invokeSingle(RemoteLocation location, String method,
      Class<?>[] paramTypes, Object[] params) throws IOException {
    // 1. 从连接池获取到目标NN的connection
    ConnectionContext conn = connectionManager.getConnection(
        location.getNameserviceId(), UserGroupInformation.getCurrentUser());
    // 2. 通过代理调用目标NN的方法
    ClientProtocol proxy = conn.getClient().getProxy();
    return (T) method.invoke(proxy, params);
  }
  
  // 多目标并行调用（如跨子集群ls）
  public <T> List<T> invokeAll(List<RemoteLocation> locations, 
      String method, Class<?>[] paramTypes, Object[] params) {
    // 并行提交到线程池
    List<Future<T>> futures = new ArrayList<>();
    for (RemoteLocation loc : locations) {
      futures.add(executorService.submit(() -> invokeSingle(loc, method, ...)));
    }
    // 等待所有结果
    return collectResults(futures);
  }
}
```

### 3.2 请求路由完整流程

```
Client: hdfs dfs -ls /data/warehouse/dim/
    │
    ▼ ClientProtocol.getListing("/data/warehouse/dim/")
RouterRpcServer.getListing()
    │
    ├── 1. subclusterResolver.getDestinationForPath("/data/warehouse/dim/")
    │        → MountTable匹配: /data/warehouse → ns1
    │        → RemoteLocation{nsId="ns1", dest="/data/warehouse/dim/"}
    │
    ├── 2. rpcClient.invokeSingle(location, "getListing", ...)
    │        → ConnectionManager.getConnection("ns1", ugi)
    │        → 获取ns1 Active NN的代理
    │        → proxy.getListing("/data/warehouse/dim/", ...)
    │
    └── 3. 返回结果给Client
```

---

## 四、生产实战案例

### 4.1 案例一：部署Router Federation

```xml
<!-- router配置 hdfs-rbf-site.xml -->
<property>
  <name>dfs.federation.router.store.driver.class</name>
  <value>org.apache.hadoop.hdfs.server.federation.store.driver.impl.StateStoreZooKeeperImpl</value>
</property>
<property>
  <name>dfs.federation.router.store.connection.string</name>
  <value>zk1:2181,zk2:2181,zk3:2181</value>
</property>

<!-- 客户端配置 -->
<property>
  <name>dfs.nameservices</name>
  <value>myfed</value>
</property>
<property>
  <name>dfs.ha.namenodes.myfed</name>
  <value>router1,router2,router3</value>
</property>
<property>
  <name>dfs.namenode.rpc-address.myfed.router1</name>
  <value>router1-host:8888</value>
</property>
```

**管理挂载表**：
```bash
# 添加挂载点
hdfs dfsrouteradmin -add /data/warehouse ns1 /data/warehouse
hdfs dfsrouteradmin -add /data/logs ns2 /data/logs
hdfs dfsrouteradmin -add /user ns1 /user

# 查看挂载表
hdfs dfsrouteradmin -ls

# 刷新Router缓存
hdfs dfsrouteradmin -refresh
```

### 4.2 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.federation.router.rpc-address` | 0.0.0.0:8888 | Router RPC地址 |
| `dfs.federation.router.admin-address` | 0.0.0.0:8111 | Admin地址 |
| `dfs.federation.router.http-address` | 0.0.0.0:50071 | Web UI |
| `dfs.federation.router.cache.ttl` | 60000 | MountTable缓存TTL |
| `dfs.federation.router.rpc.max.handler.count` | 100 | RPC Handler线程数 |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：Router是有状态还是无状态的？如何实现高可用？**

A：Router是无状态的。所有状态（MountTable、子集群信息）存储在StateStore中。可以部署多个Router实例，通过客户端轮询或LVS/HAProxy做负载均衡。任一Router宕机不影响服务。

**Q2：跨子集群rename怎么处理？**

A：不支持！跨子集群rename需要原子性地操作两个独立的NameNode，目前无法保证。Router会直接拒绝源和目标在不同子集群的rename操作。

**Q3：Router Federation的性能开销？**

A：额外一跳的延迟（通常<1ms局域网），但带来的收益是：消除客户端配置管理成本、支持透明扩展、集中化管理。

### 5.2 思考题

1. 如果一个子集群的NN宕机了，Router如何处理发往该子集群的请求？
2. MountTable支持通配符吗？如何处理`/user/${user}`这种per-user映射？
3. Router本身会不会成为性能瓶颈？如何做容量规划？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────────┐
│       HDFS Router-Based Federation · 知识晶体                        │
├─────────────────────────────────────────────────────────────────────┤
│  【核心思想】在客户端和NN之间加一层透明路由层                         │
│  【Router = 无状态代理】ClientProtocol接口透传                       │
│  【MountTable = 路由表】路径前缀→子集群最长匹配                      │
│  【StateStore = 元数据库】ZK/File/DB存储集群拓扑                     │
│  【vs ViewFS】服务端路由 vs 客户端路由，集中管理 vs 分散配置          │
│  【限制】不支持跨子集群rename/move，跨子集群ls有性能开销              │
│  【高可用】多Router+无状态+LVS负载均衡                               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码目录**: `hadoop-hdfs-project/hadoop-hdfs-rbf/src/main/java/org/apache/hadoop/hdfs/server/federation/`
2. **设计文档**: HDFS-10467: Router-Based HDFS Federation
3. **官方文档**: Apache Hadoop: HDFS Federation with Router
