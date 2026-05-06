# [教案] HMS高可用与连接池源码深度剖析

> 🎯 教学目标：掌握HiveMetaStoreClient连接管理、RetryingMetaStoreClient重试机制、HMS多实例高可用架构的源码实现  
> ⏰ 预计学时：3学时  
> 📊 难度：⭐⭐⭐⭐（中高级）

---

## 一、课前导入（生活类比引入）

### 1.1 生活类比：银行柜台服务系统

- **单柜台（单HMS）**：所有客户排一个队，柜台故障则全部停摆
- **多柜台（多HMS实例）**：客户自动分流，某柜台故障时自动切换
- **叫号机（ZK服务发现）**：知道哪些柜台在工作，自动分配
- **排队重试（RetryingClient）**：遇到繁忙自动等待重试

### 1.2 生产故障场景

```
故障现象：Hive查询间歇性报错
org.apache.thrift.transport.TTransportException: java.net.SocketTimeoutException: Read timed out
但HMS进程正常运行

根因：
1. HMS连接未正确failover到健康实例
2. Thrift连接超时设置过短
3. 连接生命周期过长导致连接失效
4. 缺乏有效的连接池回收机制
```

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 含义 | 类比 |
|------|------|------|
| HiveMetaStoreClient | HMS客户端实现（Thrift） | 去柜台办业务的客户 |
| RetryingMetaStoreClient | 带重试的代理客户端 | 自动排队重试的客户 |
| IMetaStoreClient | 客户端接口 | 业务办理标准 |
| metastoreUris | HMS服务器地址列表 | 所有柜台地址 |
| connectionLifeTime | 连接最大存活时间 | 柜台服务时间限制 |
| retryLimit | 重试次数上限 | 最多排几次队 |
| retryDelaySeconds | 重试间隔 | 两次排队间等待时间 |

### 2.2 HMS连接架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    HMS Connection Architecture                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌───────────┐    ┌──────────────────────┐    ┌─────────────┐ │
│  │ HiveServer2│    │RetryingMetaStoreClient│    │HMS Instance1│ │
│  │ / Spark   │────▶│  (JDK Proxy)         │───▶│ :9083       │ │
│  │ / Beeline │    │  ├─ retryLimit=3      │    └─────────────┘ │
│  └───────────┘    │  ├─ retryDelay=1s     │    ┌─────────────┐ │
│                   │  ├─ connLifeTime=5min │───▶│HMS Instance2│ │
│                   │  └─ reconnect on fail │    │ :9083       │ │
│                   └──────────┬───────────┘    └─────────────┘ │
│                              │                  ┌─────────────┐ │
│                              │ implements       │HMS Instance3│ │
│                   ┌──────────▼───────────┐───▶│ :9083       │ │
│                   │ HiveMetaStoreClient   │    └─────────────┘ │
│                   │  ├─ TSocket transport │                     │
│                   │  ├─ TBinaryProtocol   │    ┌─────────────┐ │
│                   │  ├─ metastoreUris[]   │    │  ZooKeeper  │ │
│                   │  └─ open()/reconnect()│    │(服务发现可选)│ │
│                   └──────────────────────┘    └─────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 HiveMetaStoreClient：Thrift连接管理

> 📁 源码位置：`standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/HiveMetaStoreClient.java`

#### 3.1.1 核心字段（第97-120行）

```java
@InterfaceAudience.Public
@InterfaceStability.Evolving
public class HiveMetaStoreClient implements IMetaStoreClient, AutoCloseable {
    
    ThriftHiveMetastore.Iface client = null;  // Thrift客户端stub
    private TTransport transport = null;       // Thrift传输层
    private boolean isConnected = false;       // 连接状态
    private URI metastoreUris[];               // HMS实例地址数组
    private final HiveMetaHookLoader hookLoader;
    protected final Configuration conf;
    private String tokenStrForm;
    private final boolean localMetaStore;      // 是否嵌入式模式
    private final MetaStoreFilterHook filterHook;
    private final URIResolverHook uriResolverHook;
    private final int fileMetadataBatchSize;
}
```

#### 3.1.2 连接建立：open()方法

```java
private void open() throws MetaException {
    isConnected = false;
    TTransportException tte = null;
    boolean useSSL = MetastoreConf.getBoolVar(conf, ConfVars.USE_SSL);
    boolean useSasl = MetastoreConf.getBoolVar(conf, ConfVars.USE_THRIFT_SASL);
    boolean useFramedTransport = MetastoreConf.getBoolVar(conf, ConfVars.USE_THRIFT_FRAMED_TRANSPORT);
    boolean useCompactProtocol = MetastoreConf.getBoolVar(conf, ConfVars.USE_THRIFT_COMPACT_PROTOCOL);
    int clientSocketTimeout = (int) MetastoreConf.getTimeVar(conf, 
        ConfVars.CLIENT_SOCKET_TIMEOUT, TimeUnit.MILLISECONDS);

    // 遍历所有HMS实例尝试连接（随机打散避免热点）
    for (int attempt = 0; !isConnected && attempt < retries; attempt++) {
        for (URI store : metastoreUris) {
            try {
                // 1. 创建TSocket
                transport = new TSocket(store.getHost(), store.getPort(), clientSocketTimeout);
                
                // 2. 根据配置选择传输层
                if (useFramedTransport) {
                    transport = new TFramedTransport(transport);
                }
                
                // 3. 选择协议
                TProtocol protocol;
                if (useCompactProtocol) {
                    protocol = new TCompactProtocol(transport);
                } else {
                    protocol = new TBinaryProtocol(transport);
                }
                
                // 4. 创建客户端
                client = new ThriftHiveMetastore.Client(protocol);
                transport.open();
                isConnected = true;
                
            } catch (TTransportException e) {
                tte = e;
                // 连接失败，尝试下一个URI
            }
        }
        // 重试间隔
        if (!isConnected) Thread.sleep(retryDelaySeconds * 1000);
    }
    
    if (!isConnected) {
        throw new MetaException("Could not connect to meta store using any of the URIs");
    }
}
```

#### 3.1.3 重连机制：reconnect()

```java
@Override
public void reconnect() throws MetaException {
    if (localMetaStore) {
        // 嵌入式模式无需重连
        return;
    }
    close();  // 先关闭旧连接
    // 重新随机选择URI并连接
    if (MetastoreConf.getBoolVar(conf, ConfVars.THRIFT_URI_SELECTION_RANDOM)) {
        List<URI> uriList = Arrays.asList(metastoreUris);
        Collections.shuffle(uriList);
        metastoreUris = uriList.toArray(new URI[0]);
    }
    open();   // 重新建立连接
}
```

---

### 3.2 RetryingMetaStoreClient：智能重试代理

> 📁 源码位置：`standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/RetryingMetaStoreClient.java`

#### 3.2.1 核心字段与构造（第59-100行）

```java
@InterfaceAudience.Public
public class RetryingMetaStoreClient implements InvocationHandler {
    
    private final IMetaStoreClient base;              // 被代理的真实客户端
    private final UserGroupInformation ugi;           // 用户认证信息
    private final int retryLimit;                     // 重试上限
    private final long retryDelaySeconds;             // 重试间隔
    private final ConcurrentHashMap<String, Long> metaCallTimeMap; // 方法调用耗时统计
    private final long connectionLifeTimeInMillis;    // 连接最大生命周期
    private long lastConnectionTime;                  // 上次连接时间
    private boolean localMetaStore;                   // 是否本地模式

    protected RetryingMetaStoreClient(Configuration conf, ...) throws MetaException {
        this.retryLimit = MetastoreConf.getIntVar(conf, ConfVars.THRIFT_FAILURE_RETRIES);      // 默认3
        this.retryDelaySeconds = MetastoreConf.getTimeVar(conf, 
            ConfVars.CLIENT_CONNECT_RETRY_DELAY, TimeUnit.SECONDS);  // 默认1s
        this.connectionLifeTimeInMillis = MetastoreConf.getTimeVar(conf,
            ConfVars.CLIENT_SOCKET_LIFETIME, TimeUnit.MILLISECONDS); // 默认0(不限制)
        this.lastConnectionTime = System.currentTimeMillis();
        
        // 创建真实客户端
        this.base = JavaUtils.newInstance(msClientClass, constructorArgTypes, constructorArgs);
    }
}
```

#### 3.2.2 JDK动态代理创建（第140-153行）

```java
public static IMetaStoreClient getProxy(Configuration hiveConf, Class<?>[] constructorArgTypes,
    Object[] constructorArgs, ConcurrentHashMap<String, Long> metaCallTimeMap,
    String mscClassName) throws MetaException {

    // 获取客户端实现类
    Class<? extends IMetaStoreClient> baseClass =
        JavaUtils.getClass(mscClassName, IMetaStoreClient.class);

    // 创建RetryingHandler
    RetryingMetaStoreClient handler =
        new RetryingMetaStoreClient(hiveConf, constructorArgTypes, constructorArgs,
            metaCallTimeMap, baseClass);
    
    // 返回JDK动态代理
    return (IMetaStoreClient) Proxy.newProxyInstance(
        RetryingMetaStoreClient.class.getClassLoader(), 
        baseClass.getInterfaces(), 
        handler);
}
```

#### 3.2.3 核心invoke方法：重试与重连逻辑（第156-249行）

```java
@Override
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    Object ret;
    int retriesMade = 0;
    TException caughtException;
    
    // 检查方法注解：是否允许重连/重试
    boolean allowReconnect = !method.isAnnotationPresent(NoReconnect.class);
    boolean allowRetry = true;
    for (Annotation a : method.getDeclaredAnnotations()) {
        if (a instanceof RetrySemantics.CannotRetry) {
            allowRetry = false;  // 标记不可重试的方法
        }
    }

    while (true) {
        try {
            // 1. Kerberos ticket续期
            reloginExpiringKeytabUser();
            
            // 2. 判断是否需要重连
            if (allowReconnect) {
                if (retriesMade > 0 || hasConnectionLifeTimeReached(method)) {
                    // 连接已超时或上次失败，需要重连
                    if (this.ugi != null) {
                        this.ugi.doAs(new PrivilegedExceptionAction<Object>() {
                            public Object run() throws MetaException {
                                base.reconnect();  // 重连
                                return null;
                            }
                        });
                        lastConnectionTime = System.currentTimeMillis();
                    }
                }
            }
            
            // 3. 执行实际方法调用
            if (metaCallTimeMap == null) {
                ret = method.invoke(base, args);
            } else {
                // 带耗时统计
                long startTime = System.currentTimeMillis();
                ret = method.invoke(base, args);
                long timeTaken = System.currentTimeMillis() - startTime;
                addMethodTime(method, timeTaken);
            }
            break;  // 成功则退出循环
            
        } catch (InvocationTargetException e) {
            Throwable t = e.getCause();
            
            // 4. 异常分类处理
            if (t instanceof TApplicationException) {
                TApplicationException tae = (TApplicationException) t;
                switch (tae.getType()) {
                    case TApplicationException.UNSUPPORTED_CLIENT_TYPE:
                    case TApplicationException.UNKNOWN_METHOD:
                        throw t;  // 不可恢复，直接抛出
                    default:
                        caughtException = tae;  // 可能可恢复
                }
            } else if (t instanceof TTransportException) {
                caughtException = (TException) t;  // 网络层异常，可重试
            } else if (t instanceof MetaException 
                && t.getMessage().matches(".*JDO.*Exception.*")) {
                caughtException = (MetaException) t;  // JDO异常可重试
            } else {
                throw t;  // 其他异常直接抛出
            }
        }
        
        // 5. 重试逻辑
        if (retriesMade >= retryLimit || !allowRetry) {
            throw caughtException;  // 超过重试上限
        }
        retriesMade++;
        LOG.warn("MetaStoreClient lost connection. Attempting to reconnect ("
            + retriesMade + " of " + retryLimit + ")");
        Thread.sleep(retryDelaySeconds * 1000);
    }
    return ret;
}
```

#### 3.2.4 连接生命周期检查

```java
private boolean hasConnectionLifeTimeReached(Method method) {
    if (connectionLifeTimeInMillis <= 0 || localMetaStore) {
        return false;  // 未配置或本地模式不检查
    }
    long now = System.currentTimeMillis();
    boolean shouldReconnect = (now - lastConnectionTime) >= connectionLifeTimeInMillis;
    if (shouldReconnect) {
        LOG.debug("%.3f secs have passed since last connection. Reconnecting...",
            (now - lastConnectionTime) / 1000.0);
    }
    return shouldReconnect;
}
```

---

### 3.3 HMS服务发现（ZooKeeper模式）

当配置`hive.metastore.uris`为空且启用ZK发现时：

```java
// MetastoreConf中相关配置
ConfVars.THRIFT_URIS              // hive.metastore.uris (静态配置)
ConfVars.THRIFT_ZOOKEEPER_CLIENT_PORT  // ZK端口
ConfVars.THRIFT_ZOOKEEPER_NAMESPACE    // ZK命名空间

// HMS启动时注册到ZK
// HiveMetaStore.startMetaStore() → 注册 ephemeral znode
// 路径：/hive_metastore/leader_uri_<sequence>
```

---

### 3.4 调用链时序图

```
┌────────┐  ┌─────────────────┐  ┌──────────────────┐  ┌────────┐
│ Client │  │RetryingMSClient │  │HiveMetaStoreClient│  │  HMS   │
└───┬────┘  └───────┬─────────┘  └────────┬─────────┘  └───┬────┘
    │               │                      │                │
    │─getTable()───▶│                      │                │
    │               │─invoke(getTable)────▶│                │
    │               │  hasLifeTimeReached? │                │
    │               │  retriesMade=0, NO   │                │
    │               │                      │─Thrift call───▶│
    │               │                      │◀─result────────│
    │◀──result──────│◀─────────────────────│                │
    │               │                      │                │
    │─getDB()──────▶│                      │                │
    │               │─invoke(getDB)───────▶│                │
    │               │                      │─Thrift call───▶│
    │               │                      │  ╳ TTransportException
    │               │  catch → retry#1     │                │
    │               │  sleep(retryDelay)   │                │
    │               │─reconnect()─────────▶│─close()        │
    │               │                      │─open(uri[1])──▶│(new instance)
    │               │                      │◀─connected─────│
    │               │─invoke(getDB)───────▶│                │
    │               │                      │─Thrift call───▶│
    │               │                      │◀─result────────│
    │◀──result──────│◀─────────────────────│                │
```

---

## 四、生产实战案例

### 4.1 案例一：HMS连接频繁超时

**排障步骤**：
```bash
# 1. 检查HMS存活
netstat -tlnp | grep 9083

# 2. 检查客户端超时设置
grep "hive.metastore.client.socket.timeout" hive-site.xml
# 默认600s，如果HMS慢应增大

# 3. 检查连接生命周期
grep "hive.metastore.client.socket.lifetime" hive-site.xml
# 默认0(无限)，建议设置为5-10分钟防止连接老化

# 4. 检查重试配置
grep "hive.metastore.failure.retries" hive-site.xml
# 默认1，建议设为3

# 5. 检查GC暂停（HMS端）
jstat -gcutil <hms_pid> 1000
```

### 4.2 参数调优

| 参数 | 默认值 | 建议 | 说明 |
|------|--------|------|------|
| `hive.metastore.uris` | - | 多URI逗号分隔 | HMS地址列表 |
| `hive.metastore.failure.retries` | 1 | 3 | 重试次数 |
| `hive.metastore.client.connect.retry.delay` | 1s | 1s | 重试间隔 |
| `hive.metastore.client.socket.timeout` | 600s | 600s | 单次调用超时 |
| `hive.metastore.client.socket.lifetime` | 0 | 300s | 连接最大生命周期 |
| `hive.metastore.connect.retries` | 3 | 5 | 初始连接重试 |
| `hive.metastore.uri.selection` | RANDOM | RANDOM | URI选择策略 |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：RetryingMetaStoreClient使用了什么设计模式？为什么？**

A：JDK动态代理模式。好处：
1. 对调用方透明，无需修改IMetaStoreClient接口
2. 所有方法统一拦截，一处实现重试逻辑
3. 支持@NoReconnect/@CannotRetry注解细粒度控制

**Q2：connectionLifeTime的作用是什么？设置过短/过长各有什么问题？**

A：定期强制重连，避免连接"半死"状态。过短：频繁重连增加开销；过长：可能使用已失效的连接。

**Q3：如果配置了3个HMS URI，客户端如何选择？**

A：默认RANDOM策略，每次reconnect随机打散URI列表，避免所有客户端都连接同一实例造成热点。

### 5.2 思考题

1. 为什么HMS不使用连接池而是单连接+重试模式？与JDBC连接池的设计差异是什么？
2. 如果HMS切换了Leader（ZK模式），正在执行的Thrift调用会怎样？
3. 如何实现一个HMS客户端连接池（类似HikariCP），需要考虑哪些问题？

---

## 六、知识晶体（一页纸总结）

```
┌────────────────────────────────────────────────────────────────┐
│          HMS 高可用与连接管理核心知识晶体                        │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  架构：Client → RetryingProxy → HiveMetaStoreClient → HMS     │
│                                                                │
│  RetryingMetaStoreClient (JDK动态代理)：                        │
│  ├── invoke() 拦截所有方法调用                                  │
│  ├── 异常分类：Transport/JDO=可重试 | Unknown=直接抛            │
│  ├── 重试循环：retry ≤ retryLimit, sleep(retryDelay)           │
│  ├── 连接生命周期：elapsed > connLifeTime → reconnect          │
│  └── Kerberos续期：每次调用前reloginExpiringKeytabUser()       │
│                                                                │
│  HiveMetaStoreClient：                                         │
│  ├── open()：遍历metastoreUris[]，TSocket + TBinaryProtocol    │
│  ├── reconnect()：close() + shuffle(uris) + open()             │
│  └── 支持：SSL / SASL / Framed / Compact 多种传输协议           │
│                                                                │
│  高可用模式：                                                    │
│  ├── 静态：hive.metastore.uris 配多个地址                       │
│  └── 动态：ZK服务发现 ephemeral znode                           │
│                                                                │
│  关键参数：retryLimit=3, retryDelay=1s, socketLifetime=300s    │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. Hive源码：`standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/HiveMetaStoreClient.java`
2. Hive源码：`standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/RetryingMetaStoreClient.java`
3. HIVE-7947: MetaStoreClient connection pooling
4. Thrift官方文档：Transport/Protocol层
5. Hive Wiki: AdminManual Metastore HA
