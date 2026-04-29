# B01 — RegionServer 启动与初始化链路

> **段位**: L2 地图绘制者 | **方法**: 逆向工程 + 分形剥离 L2 主链路  
> **核心类**: `HRegionServer`, `RSRpcServices`, `WALFactory`, `MemStoreFlusher`, `CompactSplitThread`  
> **入口**: `HRegionServer.main()` → `HRegionServer.run()`

---

## 一、启动入口

```java
// hbase-server/src/main/java/org/apache/hadoop/hbase/regionserver/HRegionServer.java

public class HRegionServer extends HasThread implements RegionServerServices {

    public static void main(String[] args) {
        // 1. 解析参数、加载配置
        Configuration conf = HBaseConfiguration.create();
        // 2. 构造 HRegionServer 实例
        HRegionServer hrs = HRegionServer.constructRegionServer(rsClass, conf);
        // 3. 启动线程
        hrs.start();  // → Thread.start() → run()
    }
}
```

---

## 二、初始化全链路（`run()` → `preRegistrationInitialization()` → `reportForDuty()`）

```
HRegionServer.run()
│
├─ 1. preRegistrationInitialization()      ← 注册到 Master 之前的本地初始化
│     │
│     ├─ 1.1 initializeZooKeeper()         ← 连接 ZK，创建 ephemeral 节点
│     │       └─ ZKUtil.createEphemeralNodeAndWatch(/hbase/rs/host:port)
│     │
│     ├─ 1.2 setupClusterConnection()      ← 创建到集群的 Connection（用于 META 查询等）
│     │
│     ├─ 1.3 initializeThreads()           ← 关键！初始化各种后台线程
│     │       │
│     │       ├─ new MemStoreFlusher(conf, this)
│     │       │     └─ 创建 FlushHandler 线程池（hbase.hstore.flusher.count）
│     │       │
│     │       ├─ new CompactSplitThread(conf, this)
│     │       │     ├─ shortCompactions 线程池
│     │       │     ├─ longCompactions 线程池
│     │       │     └─ splits 线程池
│     │       │
│     │       ├─ new WALFactory(conf, ...)
│     │       │     └─ 创建 WAL Provider（FSHLog 或 AsyncFSWAL）
│     │       │
│     │       └─ 各种 Chore（周期性任务）:
│     │             ├─ CompactionChecker（检查是否需要 compaction）
│     │             ├─ PeriodicMemStoreFlusher（定时 flush）
│     │             ├─ healthCheckChore（健康检查）
│     │             └─ nonceManagerChore（去重管理）
│     │
│     └─ 1.4 createRpcServices()           ← RPC 服务
│             └─ new RSRpcServices(this)
│                   └─ RpcServer (Netty-based, handler ×N)
│
├─ 2. reportForDuty()                      ← 向 Master 注册
│     │
│     ├─ 2.1 RegionServerStartupRequest → Master
│     │       └─ 包含: host, port, startCode, memstoreSize, numberOfStores...
│     │
│     └─ 2.2 Master 返回 RegionServerStartupResponse
│             └─ 包含: 需要 open 的 Region 列表
│
├─ 3. handleReportForDutyResponse()        ← 处理 Master 分配
│     │
│     ├─ 3.1 startServices()               ← 启动各种服务
│     │       ├─ rpcServices.start()
│     │       ├─ walFactory.start()
│     │       ├─ memStoreFlusher.start()     ← 启动 flush 线程
│     │       ├─ compactSplitThread.start()  ← 启动 compaction 线程
│     │       └─ start all Chores
│     │
│     └─ 3.2 openRegions(regionsToOpen)    ← 打开分配的 Region
│             └─ for each region:
│                   HRegion.openHRegion()
│                   ├─ 加载 HFile 列表
│                   ├─ 回放 WAL（如果有未 flush 的数据）
│                   └─ 注册到 onlineRegions Map
│
└─ 4. 进入主循环 → 处理 RPC 请求 + 周期性 Chore
```

---

## 三、关键初始化组件详解

### 3.1 MemStoreFlusher 初始化

```java
// MemStoreFlusher.java
public class MemStoreFlusher implements FlushRequester {
    
    private final FlushHandler[] flushHandlers;  // flush 工作线程
    private final DelayQueue<FlushQueueEntry> flushQueue;  // flush 请求队列
    
    // 全局 MemStore 监控阈值
    private final long globalMemStoreLimit;       // 堆 × 0.4
    private final long globalMemStoreLimitLow;    // globalMemStoreLimit × 0.95
    
    public MemStoreFlusher(Configuration conf, HRegionServer server) {
        int handlerCount = conf.getInt("hbase.hstore.flusher.count", 2);
        this.flushHandlers = new FlushHandler[handlerCount];
        this.flushQueue = new DelayQueue<>();
        
        // 计算阈值
        this.globalMemStoreLimit = (long)(Runtime.maxMemory() * 
            conf.getFloat("hbase.regionserver.global.memstore.size", 0.4f));
    }
    
    // FlushHandler 是消费者线程
    private class FlushHandler extends HasThread {
        public void run() {
            while (!server.isStopped()) {
                FlushQueueEntry entry = flushQueue.poll(timeout, TimeUnit.MILLISECONDS);
                if (entry != null) {
                    flushRegion(entry);  // 执行 flush
                }
            }
        }
    }
}
```

**对应你的 Thread Dump**:
- 看到 16 个 `MemStoreFlusher.0` ~ `MemStoreFlusher.15` 线程 → `hbase.hstore.flusher.count = 16`
- 15 个在 `DelayQueue.poll()` 等待（空闲）
- 1 个（#10）卡在 `StoreFlusher.performFlush` → `ZStd.compress`

### 3.2 CompactSplitThread 初始化

```java
// CompactSplitThread.java
public class CompactSplitThread implements CompactionRequester {
    
    private final ThreadPoolExecutor longCompactions;
    private final ThreadPoolExecutor shortCompactions;
    private final ThreadPoolExecutor splits;
    
    public CompactSplitThread(Configuration conf, HRegionServer server) {
        int largeThreads = conf.getInt("hbase.regionserver.thread.compaction.large", 1);
        int smallThreads = conf.getInt("hbase.regionserver.thread.compaction.small", 1);
        
        this.longCompactions = new ThreadPoolExecutor(largeThreads, ...);
        this.shortCompactions = new ThreadPoolExecutor(smallThreads, ...);
    }
}
```

**对应你的 Thread Dump**:
- 6 个 `shortCompactions` + 6 个 `longCompactions` = 12 个 compaction 线程
- 全部空闲（`TIMED_WAITING`），说明当前无 compaction 在跑

### 3.3 WAL 初始化

```java
// WALFactory.java
public class WALFactory {
    
    public WALFactory(Configuration conf, String factoryId) {
        // 选择 WAL Provider
        String providerClass = conf.get("hbase.wal.provider", "asyncfs");
        //   "filesystem" → FSHLog（同步，旧版默认）
        //   "asyncfs"    → AsyncFSWAL（异步，2.x 默认，推荐）
        
        this.provider = getProvider(providerClass);
    }
}
```

**对应你的 Thread Dump**:
- `append-pool-0` 使用 `BlockingWaitStrategy`（Disruptor） → 说明使用的是 **AsyncFSWAL**

### 3.4 RPC Server 初始化

```java
// RSRpcServices.java
public class RSRpcServices implements HBaseRPCErrorHandler {
    
    public RSRpcServices(HRegionServer rs) {
        Configuration conf = rs.getConfiguration();
        
        // Handler 数量
        int handlerCount = conf.getInt("hbase.regionserver.handler.count", 30);
        
        // 创建 RpcServer
        this.rpcServer = RpcServerFactory.createRpcServer(rs, ...);
    }
}
```

---

## 四、Region Open 过程（启动时最耗时的操作）

```
HRegion.openHRegion(regionInfo, tableDescriptor, wal, conf)
│
├─ 1. new HRegion(regionInfo, wal, conf, tableDescriptor)
│     └─ 为每个 CF 创建 HStore
│
├─ 2. HRegion.initialize()
│     │
│     ├─ 2a. 初始化每个 Store
│     │       └─ HStore.loadStoreFiles()
│     │             └─ 列出 HDFS 上该 Store 目录下所有 HFile
│     │             └─ 打开每个 HFile（读取 Trailer + Index）
│     │
│     ├─ 2b. WAL Replay（关键！）
│     │       └─ 如果 RS 之前崩溃，WAL 中可能有未 flush 的数据
│     │       └─ 读取 WAL → 按 Region 过滤 → 重放到 MemStore
│     │       └─ 重放完成后 → flush MemStore → 数据恢复完成
│     │
│     └─ 2c. 标记 Region 为 OPEN
│             └─ 写入 hbase:meta 表
│             └─ 通知 Master: RegionStateTransition(OPENED)
│
└─ 3. 注册到 onlineRegions ConcurrentHashMap
       └─ 此后可以接受 RPC 请求
```

**启动慢的常见原因**:
1. Region 数过多 → 大量 HFile 需要 list/open
2. WAL Replay 数据量大 → flush 之前的写入都要重放
3. HDFS 延迟高 → list/read 操作慢

---

## 五、生命周期状态机

```
     ┌──────────┐
     │  OFFLINE  │ ← 初始状态 / 停止后状态
     └─────┬────┘
           │ start()
           ▼
     ┌──────────┐
     │  STARTING │ ← preRegistrationInitialization
     └─────┬────┘
           │ reportForDuty() 成功
           ▼
     ┌──────────┐
     │  RUNNING  │ ← 正常服务中，处理 RPC + 后台任务
     └─────┬────┘
           │ stop() / abort()
           ▼
     ┌──────────┐
     │  STOPPING │ ← 关闭 Region、flush 数据、关闭 WAL
     └─────┬────┘
           │ 所有 Region closed
           ▼
     ┌──────────┐
     │  STOPPED  │ ← 进程退出
     └──────────┘
```

---

## 六、故障点地图（启动阶段）

| 故障点 | 现象 | 根因 | 排查 |
|--------|------|------|------|
| ZK 连接超时 | 启动卡住/失败 | ZK 集群不可用或网络不通 | `zkCli.sh` 测试连接 |
| Region Open 超时 | RS 启动慢（10min+） | Region 太多 / HDFS 慢 / WAL 大 | 检查 RS 日志 `Opening region` 耗时 |
| WAL Replay OOM | RS 启动时 OOM 崩溃 | 崩溃前积累大量未 flush 的 WAL | 增大 RS 堆内存，或手动 split WAL |
| Master 不可达 | reportForDuty 失败 | Master 进程挂了或 HA 切换中 | 检查 Master 日志 |
| Port 冲突 | bind 失败 | 旧进程未完全退出 | `lsof -i :16020` |
| HDFS SafeMode | 无法写 WAL/HFile | HDFS NN 在安全模式 | `hdfs dfsadmin -safemode get` |

---

## 七、关键配置清单（启动相关）

| 配置项 | 默认值 | 建议值 | 说明 |
|--------|--------|--------|------|
| `hbase.regionserver.handler.count` | 30 | 200~400 | RPC Handler 线程数 |
| `hbase.hstore.flusher.count` | 2 | 8~16 | Flush 线程数 |
| `hbase.regionserver.thread.compaction.large` | 1 | 4~6 | 长 Compaction 线程数 |
| `hbase.regionserver.thread.compaction.small` | 1 | 4~6 | 短 Compaction 线程数 |
| `hbase.regionserver.global.memstore.size` | 0.4 | 0.4 | MemStore 占堆比例 |
| `hfile.block.cache.size` | 0.4 | 0.3~0.4 | BlockCache 占堆比例 |
| `hbase.wal.provider` | asyncfs | asyncfs | WAL 实现（推荐 asyncfs） |
| `hbase.regionserver.maxlogs` | 32 | 64~128 | WAL 文件数上限 |
| `hbase.zookeeper.property.tickTime` | 2000 | 6000 | ZK tick 时间（影响 session 超时） |

---

## 八、与你线上案例的关联

从 Thread Dump 可以看到你的 RS 配置：
- **Flush 线程**: 16 个 (`MemStoreFlusher.0` ~ `.15`) → `hbase.hstore.flusher.count=16`（已调优）
- **Compaction 线程**: 6+6=12 个 → `compaction.large=6`, `compaction.small=6`（已调优）
- **WAL**: AsyncFSWAL（Disruptor `append-pool-0`）
- **RPC**: Netty（`RS-EventLoopGroup` 64 线程）
- **RS 已运行**: 94374s ≈ 26.2 小时（最近一次重启后）

**这些配置都是合理的**。问题不在启动/初始化，而在运行时 ZStd 压缩 native 层的 bug。

---

*— Eric HBase 源码精通 B01 | 2026-04-30 —*
