# HDFS Federation 与 Router-Based Federation 深度分析

> HDFS Expert 补充学习 — 大规模集群下的 NameNode 扩展方案

## 一、为什么需要 Federation

### 1.1 单 NameNode 瓶颈

```
单 NameNode 限制:
  - 内存: 1 亿文件 ≈ 150GB 堆内存 (每个 inode ~300 bytes)
  - 吞吐: ~10,000 RPC/s (受 FSNamesystem 全局锁限制)
  - 启动: 加载 1 亿 fsimage ≈ 30-60 分钟
  - 可用性: 单点故障 → 整个集群不可用（HA 只解决故障转移，不解决性能）
```

### 1.2 什么时候需要 Federation

```
检查清单:
  □ NameNode 堆内存 > 100GB
  □ RPC 平均延迟 > 50ms
  □ RPC 队列经常满 (CallQueueOverflowException)
  □ NN 启动时间 > 30 分钟
  □ 文件数 > 5 亿
  
→ 以上任意一条命中，考虑 Federation
```

## 二、传统 Federation (HDFS-1052, Hadoop 2.0+)

### 2.1 架构

```
              ┌─────────────────────────────────┐
              │        Client (ViewFS)           │
              │   viewfs://cluster/user → ns1    │
              │   viewfs://cluster/data → ns2    │
              │   viewfs://cluster/tmp  → ns3    │
              └─────────┬──────┬──────┬──────────┘
                        │      │      │
                ┌───────┘      │      └───────┐
                ↓              ↓              ↓
        ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
        │ NameNode-1  │ │ NameNode-2  │ │ NameNode-3  │
        │ (ns1)       │ │ (ns2)       │ │ (ns3)       │
        │ /user/*     │ │ /data/*     │ │ /tmp/*      │
        └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
               │               │               │
        ┌──────┴──────────────┴──────────────┴──────┐
        │              DataNode Pool                 │
        │  (所有 DataNode 向所有 NameNode 注册)      │
        └────────────────────────────────────────────┘

特点:
  - 每个 NameNode 管理独立的 namespace (Block Pool)
  - DataNode 共享，向所有 NN 注册
  - Client 用 ViewFS 做路由
  - 跨 namespace 不支持 rename/hardlink
```

### 2.2 ViewFS 配置

```xml
<!-- core-site.xml -->
<property>
  <name>fs.defaultFS</name>
  <value>viewfs://cluster</value>
</property>

<!-- 挂载表 -->
<property>
  <name>fs.viewfs.mounttable.cluster.link./user</name>
  <value>hdfs://ns1/user</value>
</property>
<property>
  <name>fs.viewfs.mounttable.cluster.link./data</name>
  <value>hdfs://ns2/data</value>
</property>
<property>
  <name>fs.viewfs.mounttable.cluster.link./tmp</name>
  <value>hdfs://ns3/tmp</value>
</property>
```

### 2.3 优缺点

```
✅ 优点:
  - 水平扩展 NameNode（理论无上限）
  - 每个 NN 内存压力降低
  - 故障隔离（一个 NN 挂不影响其他 namespace）

❌ 缺点:
  - Client 必须知道挂载表（配置复杂）
  - 挂载表变更需要重启 Client
  - 跨 namespace 操作受限
  - 负载不均衡（人工划分 namespace，某些热点目录在同一个 NN）
```

## 三、Router-Based Federation (HDFS-10467, Hadoop 3.0+)

### 3.1 架构

```
              ┌─────────────────────────────────┐
              │        Client (hdfs://)          │
              │   对 client 完全透明！            │
              └─────────────┬────────────────────┘
                            │
              ┌─────────────┴────────────────────┐
              │        Router (RBF)               │
              │  ┌───────────────────────────┐   │
              │  │ State Store (ZK/DB)       │   │
              │  │  mount table (动态更新)    │   │
              │  │  router membership        │   │
              │  │  namespace 状态           │   │
              │  └───────────────────────────┘   │
              └──────┬──────────┬────────────────┘
                     │          │
              ┌──────┘          └──────┐
              ↓                        ↓
        ┌─────────────┐         ┌─────────────┐
        │ NameNode-1  │         │ NameNode-2  │
        │ (ns1)       │         │ (ns2)       │
        └─────────────┘         └─────────────┘

关键改进:
  - Client 不需要知道挂载表 → 全部由 Router 代理
  - 挂载表存在 State Store (ZooKeeper) → 动态更新无需重启
  - Router 无状态 → 可以水平扩展（加 LB）
  - 跨 namespace rename → Router 层面实现（两阶段提交）
```

### 3.2 核心组件

```
Router:
  - RouterRpcServer: 接收 Client RPC，路由到对应 NameNode
  - RouterClientProtocol: 实现 ClientProtocol 接口
  - MountTableResolver: 根据路径查挂载表，找目标 NN
  - ActiveNamenodeResolver: 跟踪每个 namespace 的 Active NN

State Store:
  - MountTable: 路径 → namespace 映射
  - MembershipState: Router 存活状态
  - RouterState: Router 统计信息
  - DisabledNameservice: 临时禁用某个 namespace

存储后端:
  - ZooKeeper (推荐生产使用)
  - 文件系统 (测试用)
```

### 3.3 RBF 关键配置

```xml
<!-- hdfs-rbf-site.xml -->

<!-- 启用 Router -->
<property>
  <name>dfs.federation.router.rpc.enable</name>
  <value>true</value>
</property>

<!-- State Store 配置 -->
<property>
  <name>dfs.federation.router.store.driver.class</name>
  <value>org.apache.hadoop.hdfs.server.federation.store.driver.impl.StateStoreZooKeeperImpl</value>
</property>

<!-- Router RPC 地址 -->
<property>
  <name>dfs.federation.router.rpc-address</name>
  <value>0.0.0.0:8888</value>
</property>

<!-- 挂载表缓存刷新间隔 -->
<property>
  <name>dfs.federation.router.cache.ttl</name>
  <value>60000</value>
</property>

<!-- Router 数量（建议 >= 3，前面加 LB）-->
```

### 3.4 挂载表管理

```bash
# 添加挂载点
hdfs dfsrouteradmin -add /data ns2 /data

# 查看挂载表
hdfs dfsrouteradmin -ls

# 删除挂载点
hdfs dfsrouteradmin -rm /data

# 更新挂载点
hdfs dfsrouteradmin -update /data ns3 /data

# 以上操作立即生效，无需重启！
```

## 四、RBF 性能影响

### 4.1 额外延迟

```
无 RBF:
  Client → NameNode: ~1ms

有 RBF:
  Client → Router → NameNode: ~2-3ms
  额外延迟: ~1-2ms (路由查找 + 代理转发)

对大数据任务影响:
  - HDFS 密集操作（ls 大目录、小文件读写）: 可感知
  - 大文件顺序读写: 几乎不影响（数据走 DataNode 直连）
  - COS 场景: 无关（不走 HDFS）
```

### 4.2 Router 扩展

```
单 Router 吞吐: ~20,000 RPC/s
推荐部署:
  - 3 个 Router + 1 个 VIP/LB
  - 总吞吐: ~60,000 RPC/s
  - 横向扩展: 加 Router 实例即可
```

## 五、运维实战

### 5.1 监控指标

```bash
# Router 状态
hdfs dfsrouteradmin -safemode get

# Namespace 状态
hdfs dfsrouteradmin -getDisabledNameservices

# Router JMX 指标
curl http://router:8089/jmx | jq '.beans[] | select(.name | contains("Router"))'

# 关键指标:
#   RouterRpcActivity.ProxyOpLatency  — Router 代理延迟
#   RouterRpcActivity.ProcessingOps   — 处理中的 RPC 数
#   StateStoreActivity.CacheUpdates   — State Store 缓存刷新次数
```

### 5.2 常见故障处理

```
故障1: Router 挂了
  影响: Client 连不上 → 切到其他 Router (LB 自动摘除)
  恢复: 重启 Router，自动从 State Store 恢复挂载表

故障2: 某个 NameNode 挂了
  影响: 对应 namespace 不可用，其他 namespace 正常
  Router 行为: 自动标记该 namespace 为 unavailable
  恢复: NN HA failover → Router 自动检测新 Active NN

故障3: State Store (ZK) 挂了
  影响: 挂载表无法更新，但 Router 缓存仍可服务
  恢复: 修复 ZK → Router 自动重连
```

---

*HDFS Expert 学习产出 | 2026-04-08 | 补充薄弱知识点*
