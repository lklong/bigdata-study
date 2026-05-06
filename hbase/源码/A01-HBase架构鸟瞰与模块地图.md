# A01 — HBase 架构鸟瞰与模块地图

> **段位**: L1→L2 | **方法**: 分形剥离 L1 接口层 | **产出**: 架构全景 + 模块依赖 + 核心类索引  
> **源码版本**: HBase 2.4.x（EMR 集群常见版本）  
> **代码量**: ~100 万行 Java | ~35 核心模块

---

## 一、HBase 在大数据生态中的定位

```
┌─────────────────────────────────────────────────────────────┐
│                     应用层（业务系统）                        │
│         实时写入/随机读/Scan/二级索引/计数器                   │
└──────────────────────────┬──────────────────────────────────┘
                           │ Put/Get/Scan/Delete RPC
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              HBase（分布式列族存储引擎）                       │
│  ┌──────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │  Client   │  │    Master    │  │   RegionServer(s)  │    │
│  │ (API/Shell)│  │  (协调/DDL)  │  │   (数据读写核心)    │    │
│  └──────────┘  └──────────────┘  └────────────────────┘    │
└──────────────────────────┬──────────────────────────────────┘
                           │ Block Read/Write
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  HDFS（持久化存储层）                         │
│            WAL + HFile + Snapshot + Archive                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│         ZooKeeper（协调层：Master选举/Region分配/RS存活）      │
└─────────────────────────────────────────────────────────────┘
```

### 核心角色

| 角色 | 职责 | 类比 |
|------|------|------|
| **HMaster** | DDL、Region 分配、负载均衡、故障转移 | ≈ YARN ResourceManager |
| **RegionServer** | 数据读写、MemStore、Flush、Compaction | ≈ YARN NodeManager |
| **Region** | 表的水平分片（一段连续 RowKey 范围） | ≈ HDFS Block |
| **Store** | Region 内一个 Column Family 的存储单元 | ≈ 一个分区目录 |
| **MemStore** | 写缓冲区（内存有序 KV） | ≈ OS Page Cache |
| **HFile** | 磁盘存储格式（LSM-Tree SSTable） | ≈ Hive ORC/Parquet |
| **WAL** | Write-Ahead Log（崩溃恢复） | ≈ HDFS EditLog / MySQL binlog |
| **BlockCache** | 读缓存（LRU/BucketCache） | ≈ HDFS BlockReaderCache |

---

## 二、Maven 模块依赖图

```
hbase/
├── hbase-client            ← 客户端 API（Connection/Table/Put/Get/Scan）
├── hbase-common            ← 公共工具（Cell/KeyValue/Bytes/CellUtil）
├── hbase-protocol          ← Protobuf 定义（Client↔RS/Client↔Master RPC）
├── hbase-protocol-shaded   ← Protobuf shaded 版本
│
├── hbase-server            ← 核心！RegionServer + Master 实现
│   ├── regionserver/       ← Region/Store/MemStore/Flush/Compaction/Split
│   ├── master/             ← HMaster/AssignmentManager/Balancer
│   ├── io/                 ← HFile/WAL/BlockCache/Compression
│   ├── wal/                ← WAL 实现（FSHLog/AsyncFSWAL）
│   └── coprocessor/        ← 协处理器框架
│
├── hbase-mapreduce         ← MR 集成（ImportTsv/Export/BulkLoad）
├── hbase-thrift            ← Thrift Gateway
├── hbase-rest              ← REST Gateway
├── hbase-shell             ← JRuby Shell
├── hbase-zookeeper         ← ZK 交互封装
├── hbase-replication       ← 跨集群复制
├── hbase-balancer          ← 负载均衡策略
├── hbase-backup            ← 备份恢复
├── hbase-metrics           ← 指标采集
├── hbase-testing-util      ← 测试框架（MiniHBaseCluster）
└── hbase-assembly          ← 打包
```

**核心模块代码量分布**:

| 模块 | 行数（估） | 占比 | 重要度 |
|------|-----------|------|--------|
| hbase-server | ~450K | 45% | ★★★★★ |
| hbase-client | ~80K | 8% | ★★★★ |
| hbase-common | ~60K | 6% | ★★★ |
| hbase-protocol | ~150K | 15% | ★★★ |
| hbase-mapreduce | ~40K | 4% | ★★ |
| 其他 | ~220K | 22% | ★~★★ |

---

## 三、RegionServer 核心架构（最重要）

```
┌─────────────────── RegionServer (HRegionServer) ───────────────────┐
│                                                                     │
│  ┌─── RPC Layer ───┐    ┌─── WAL ───┐    ┌─── MemStore Flusher ──┐│
│  │ RpcServer        │    │ FSHLog /   │    │ FlushHandler ×N       ││
│  │ (Netty/NIO)      │    │ AsyncFSWAL │    │ DelayQueue<FlushReq>  ││
│  │ Handler ×300     │    │            │    │                       ││
│  └──────┬───────────┘    └─────┬──────┘    └───────┬───────────────┘│
│         │                      │                   │                │
│         ▼                      ▼                   ▼                │
│  ┌──────────────── HRegion ────────────────────────────────────┐   │
│  │                                                              │   │
│  │  ┌── Store (CF1) ──┐  ┌── Store (CF2) ──┐                  │   │
│  │  │  MemStore        │  │  MemStore        │                  │   │
│  │  │  ┌───────────┐   │  │  ┌───────────┐   │                  │   │
│  │  │  │ CellSet    │   │  │  │ CellSet    │   │                  │   │
│  │  │  │ (SkipList) │   │  │  │ (SkipList) │   │                  │   │
│  │  │  └───────────┘   │  │  └───────────┘   │                  │   │
│  │  │                   │  │                   │                  │   │
│  │  │  StoreFiles:      │  │  StoreFiles:      │                  │   │
│  │  │  [HFile1][HFile2] │  │  [HFile1]         │                  │   │
│  │  └───────────────────┘  └───────────────────┘                  │   │
│  │                                                              │   │
│  │  ┌── BlockCache (读缓存) ──────────────────────────────┐     │   │
│  │  │  LRUBlockCache / CombinedBlockCache / BucketCache    │     │   │
│  │  └──────────────────────────────────────────────────────┘     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─── Compaction ──────┐   ┌─── Split ─────────────────────────┐  │
│  │ shortCompactions ×N  │   │ SplitTransaction                   │  │
│  │ longCompactions ×N   │   │ (Region 一分为二)                    │  │
│  └──────────────────────┘   └────────────────────────────────────┘  │
│                                                                     │
│  ┌─── MemStoreFlusher ─┐   ┌─── CompactSplitThread ─────────────┐ │
│  │ Global MemStore 监控  │   │ 调度 Compaction/Split 请求          │ │
│  │ 超上限触发全局 flush  │   │                                     │ │
│  └──────────────────────┘   └─────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 四、写路径全链路（Write Path）

```
Client.put(Put)
  │
  ▼
1. RpcServer 接收请求 → RpcHandler 线程处理
  │
  ▼
2. HRegion.put()
  │
  ├─ 2a. 获取 Region 行锁（RowLock）
  │
  ├─ 2b. 写 WAL（FSHLog.append → HDFS Pipeline）
  │     └─ WAL 持久化后才能 ack 客户端
  │
  ├─ 2c. 写 MemStore（ConcurrentSkipListMap.put）
  │     └─ 内存中排序存储
  │
  ├─ 2d. 释放行锁
  │
  └─ 2e. 检查 MemStore 大小
        └─ 超过 flush.size → 触发 flush 请求
           └─ MemStoreFlusher.requestFlush()
              └─ 放入 DelayQueue → FlushHandler 消费
                 └─ MemStore snapshot → 写 HFile → 归档
```

**关键参数**:

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `hbase.hregion.memstore.flush.size` | 128MB | 单 Region MemStore 触发 flush 的阈值 |
| `hbase.regionserver.global.memstore.size` | 0.4 | RS 堆内存的 40% 为 MemStore 上限 |
| `hbase.regionserver.global.memstore.size.lower.limit` | 0.95 | 达到上限的 95% 开始强制 flush |
| `hbase.hstore.flusher.count` | 2 | Flush 线程数（你的集群配了 16） |
| `hbase.hstore.blockingStoreFiles` | 16 | StoreFile 数超此值则阻塞写入等 compaction |

---

## 五、读路径全链路（Read Path）

```
Client.get(Get) / Client.scan(Scan)
  │
  ▼
1. RpcServer → RpcHandler
  │
  ▼
2. HRegion.get() / HRegion.getScanner()
  │
  ▼
3. 构造 StoreScanner（多路归并）
  │
  ├─ 3a. MemStoreScanner（内存最新数据）
  │
  ├─ 3b. StoreFileScanner ×N（HFile 磁盘数据）
  │       └─ 先查 BlockCache
  │           ├─ Cache Hit → 直接返回 Block
  │           └─ Cache Miss → 从 HDFS 读 Block → 放入 Cache
  │
  └─ 3c. KeyValueHeap（优先队列归并排序）
         └─ 按 RowKey + CF + Qualifier + Timestamp 排序
            └─ 返回最新版本（或指定版本）
```

**关键参数**:

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `hfile.block.cache.size` | 0.4 | RS 堆内存的 40% 用于 BlockCache |
| `hbase.bucketcache.size` | 0 | 堆外 BucketCache 大小（建议开启） |
| `hbase.block.data.cachecompressed` | false | 是否缓存压缩后的 block |
| `hbase.storescanner.parallel.seek.enable` | false | 并行 seek 优化 |

---

## 六、LSM-Tree 存储模型

```
          写入                         读取
           │                            │
           ▼                            ▼
     ┌──────────┐                ┌──────────┐
     │ MemStore  │ (L0, 内存)     │ 多路归并  │
     │ (有序)    │                │ Scanner   │
     └─────┬────┘                └──────────┘
           │ Flush                     ↑
           ▼                           │ 从所有层读取
     ┌──────────┐                      │
     │ HFile L0  │ (刚 flush 的)  ─────┘
     ├──────────┤                      │
     │ HFile L1  │ (Minor Compact) ────┘
     ├──────────┤                      │
     │ HFile L2  │ (Major Compact) ────┘
     └──────────┘

   写放大: 1次写入 → flush 1次 → minor compact N次 → major compact 1次
   读放大: 1次读取 → 查 MemStore + 查所有 HFile（通过 BloomFilter 跳过）
   空间放大: 旧版本数据在 major compact 前一直占空间
```

### HFile 内部结构

```
┌─────────────────────────────────────────┐
│             HFile v3                     │
├─────────────────────────────────────────┤
│  Data Block 1 (64KB, 含多个 KV)          │
│  Data Block 2                            │
│  Data Block 3                            │
│  ...                                     │
├─────────────────────────────────────────┤
│  Meta Block (BloomFilter)                │
├─────────────────────────────────────────┤
│  Leaf Index Block                        │
│  Intermediate Index Block                │
│  Root Index Block                        │
├─────────────────────────────────────────┤
│  FileInfo (metadata)                     │
├─────────────────────────────────────────┤
│  Trailer (magic, version, offsets)       │
└─────────────────────────────────────────┘
```

---

## 七、核心类索引（Top 35）

### RegionServer 核心

| 类名 | 包 | 职责 | 重要度 |
|------|-----|------|--------|
| `HRegionServer` | regionserver | RS 主入口，管理所有 Region | ★★★★★ |
| `HRegion` | regionserver | 单个 Region 实现（读写核心） | ★★★★★ |
| `HStore` | regionserver | 单个 CF 的存储管理 | ★★★★★ |
| `MemStoreFlusher` | regionserver | 全局 flush 调度器 | ★★★★★ |
| `CompactSplitThread` | regionserver | Compaction/Split 调度 | ★★★★ |
| `DefaultMemStore` / `CompactingMemStore` | regionserver | MemStore 实现 | ★★★★ |
| `DefaultStoreFlusher` | regionserver | Flush 执行（MemStore→HFile） | ★★★★ |
| `StoreFileWriter` | regionserver | HFile 写入器 | ★★★★ |
| `StoreScanner` | regionserver | 读路径核心扫描器 | ★★★★ |
| `RSRpcServices` | regionserver | RPC 请求分发 | ★★★★ |

### WAL 核心

| 类名 | 包 | 职责 | 重要度 |
|------|-----|------|--------|
| `FSHLog` | wal | 同步 WAL 实现 | ★★★★★ |
| `AsyncFSWAL` | wal | 异步 WAL 实现（推荐） | ★★★★★ |
| `WALEdit` | wal | 一次事务的 WAL 条目 | ★★★ |
| `WALSplitter` | wal | 崩溃恢复时拆分 WAL | ★★★★ |

### Master 核心

| 类名 | 包 | 职责 | 重要度 |
|------|-----|------|--------|
| `HMaster` | master | Master 主入口 | ★★★★ |
| `AssignmentManager` | master.assignment | Region 分配/迁移 | ★★★★★ |
| `RegionStateStore` | master.assignment | Region 状态持久化 | ★★★ |
| `BalancerChore` | master.balancer | 负载均衡调度 | ★★★ |
| `StochasticLoadBalancer` | master.balancer | 随机负载均衡算法 | ★★★ |

### IO/Cache 核心

| 类名 | 包 | 职责 | 重要度 |
|------|-----|------|--------|
| `HFileBlock` | io.hfile | HFile Block 读写 | ★★★★ |
| `HFileWriterImpl` | io.hfile | HFile 写入实现 | ★★★★ |
| `HFileReaderImpl` | io.hfile | HFile 读取实现 | ★★★★ |
| `LruBlockCache` | io.hfile | LRU 读缓存 | ★★★★ |
| `BucketCache` | io.hfile.bucket | 堆外读缓存 | ★★★★ |
| `HFileBlockDefaultEncodingContext` | io.encoding | Block 编码/压缩上下文 | ★★★ |

### Client 核心

| 类名 | 包 | 职责 | 重要度 |
|------|-----|------|--------|
| `ConnectionImplementation` | client | 连接管理 | ★★★★ |
| `HTable` / `Table` | client | 表操作接口 | ★★★★ |
| `ClientScanner` | client | 客户端 Scan 实现 | ★★★ |
| `AsyncConnectionImpl` | client | 异步连接 | ★★★ |
| `RegionLocator` | client | Region 定位 | ★★★ |

---

## 八、同构关系映射

| 概念 | HBase | HDFS | Kafka | MySQL |
|------|-------|------|-------|-------|
| 写缓冲 | MemStore | EditLog Buffer | Page Cache | Buffer Pool |
| 预写日志 | WAL | EditLog | Partition Log | Redo Log |
| 持久化文件 | HFile | Block File | Log Segment | .ibd File |
| 读缓存 | BlockCache | BlockReaderCache | Page Cache | Buffer Pool |
| 数据分片 | Region | Block | Partition | Shard |
| 元数据管理 | hbase:meta | FSNamesystem | Controller | information_schema |
| 负载均衡 | Balancer | Balancer | Partition Reassign | ProxySQL |
| 故障恢复 | WAL Replay | EditLog Replay | Leader Election | Crash Recovery |
| 后台合并 | Compaction | — | Log Compaction | — |
| 数据压缩 | Block Compress | — | Batch Compress | Page Compress |

---

## 九、HBase 版本演化关键节点

| 版本 | 年份 | 关键特性 |
|------|------|----------|
| 0.98 | 2014 | Visibility Labels, Cell-level ACL |
| 1.0 | 2015 | 稳定 API, Region Replicas |
| 1.2 | 2016 | MOB (Medium Object), Offheap Read |
| 1.4 | 2017 | LTS, In-memory Compaction |
| **2.0** | **2018** | **Procedure v2, AMv2, Offheap Write, AsyncWAL** |
| 2.2 | 2019 | Master Registry, RegionServer Group |
| **2.4** | **2021** | **LTS, Snapshot Scan, Normalizer v2** |
| 2.5 | 2022 | StoreFileTracker, RegionServer Crash Recovery 优化 |
| 3.0 | 2024 | 重写存储层(PFD), Master 架构重构 |

> **你的集群用的大概率是 2.4.x**（EMR 常见版本）

---

## 十、学习路线图（Phase 1 → Phase 4）

| Phase | 周期 | 目标 | 产出 |
|-------|------|------|------|
| **Phase 1** | 2周 | 全局地图+核心概念 | A01~A05 架构文档（本篇） |
| **Phase 2** | 4周 | 写路径+读路径+Flush+Compaction 主链路 | B01~B20 源码分析 |
| **Phase 3** | 3周 | 异常/边界/故障（结合实际线上案例） | C01~C15 |
| **Phase 4** | 3周 | 性能建模+调优+Bug 考古 | D/E/F/G 综合 |

**下一步**: B01 — RegionServer 启动与初始化链路（源码级）

---

*— Eric HBase 源码精通 A01 | 2026-04-30 —*
