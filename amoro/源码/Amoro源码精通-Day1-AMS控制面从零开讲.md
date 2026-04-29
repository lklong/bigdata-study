# Amoro 源码精通 · Day1 · 《AMS 控制面从零开讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 01 讲  
> 本讲时长：45 分钟阅读 + 60 分钟动手  
> 源码版本：`D:\bigdata\dlcproject\amoro`（Apache Amoro incubating）

---

## 🎯 本讲学完你能干什么

读完这一讲，你将能够：

- ✅ **3 分钟给任何人讲清楚** Amoro 是什么、长什么样、开机做了什么。
- ✅ **30 秒定位** AMS 的任何一个启动失败问题该查哪行代码。
- ✅ **画出 AMS 的完整启动时序图**（12 个步骤），闭眼都能默写。
- ✅ **理解为什么 Amoro 要设计 `TableIdentifier`、`ServerTableIdentifier`、`AmoroTable` 三个看起来很像的东西**，并能解释给团队听。
- ✅ **识别 AMS 生产部署的 8 个关键端口/线程/配置**，排障不再瞎猜。

**一句话版**：读完能像老师一样给同事上 10 分钟课。

---

## 🪜 预备知识（没有就先补，10 分钟）

| 预备点 | 需要会什么 | 不会怎么办 |
|---|---|---|
| **Java 基础** | 接口/抽象类/Lambda | 去学《Java Core》 |
| **Iceberg 是啥** | 能说出 "Iceberg 是表格式，有 snapshot/manifest 两层元数据" | 读《Iceberg 功能地图》——你已经有了 |
| **Thrift 是啥** | 能说 "Thrift 是跨语言 RPC 协议，类似 gRPC 的前身" | 看 Apache Thrift 官网 10 分钟 |
| **MyBatis 是啥** | 能说 "MyBatis 是 Java ORM，XML/注解写 SQL" | 不深用，Day2 用到再补 |
| **Quartz / 定时任务** | 知道定时调度的一般套路 | Day3 才会大量用 |
| **Amoro 基础使用** | 会用 Dashboard 看表 | 读你已有的《Amoro 全部使用姿势》 |

> **不会别硬读**。源码精通 vs 一直卡在某一点打转，差别就在预备知识。

---

## 🧠 一句话心智模型

> **AMS 是一个"管控面"，它自己不存数据、也不跑计算，它的全部工作就是：**  
> **①管 Catalog（我要管谁的表） ②管 Table 生命周期（表进来了吗、走了吗、该优化了吗） ③管 Optimizer（谁来干活） ④提供 HTTP + Thrift 两类对外入口。**

把这一句话记住，后面所有源码都是在这句话的四个环节上打补丁。

---

## 🏛️ 从生活类比入手：把 AMS 想成"物业公司"

为了让外行也能听懂，先讲个比喻：

> 🏘️ **AMS = 一个高档小区的物业公司**
>
> - **业主** = 一张张 Iceberg / Mixed / Paimon 表
> - **楼盘** = Catalog（同一个楼盘下的业主统一管）
> - **物业大楼** = AMS 进程（一个 Java JVM）
> - **前台** = HTTP 1630 端口（业主从 Dashboard 进来办事）
> - **客服专线** = Thrift TableService 1260 端口（引擎代表业主打电话）
> - **调度中心** = Thrift Optimizing 1261 端口（派工人去业主家打扫）
> - **清洁工人** = Optimizer 进程（Flink/Spark Job）
> - **登记本** = MySQL 数据库（存了谁是业主、住几号）
> - **定时巡查** = `InlineTableExecutors`（每 5 分钟查一遍谁家漏水）

当你搞懂这几个角色之间的关系，源码里每一个类名你都能在大脑里一对一映射到角色上。**理解代码的本质，是把抽象类名翻译成生活化角色**。

---

## 🔍 源码逐层剥离

### L1 · 接口层：AMS 启动的 12 个步骤（必背）

**入口文件**：`amoro-ams/src/main/java/org/apache/amoro/server/AmoroServiceContainer.java`  
**启动脚本**：`dist/src/main/amoro-bin/bin/ams.sh`（第 58 行指定主类）

```
main()                          (L118)
  │
  ├─ 01. new AmoroServiceContainer()                (L113)
  │      └─ initConfig()                            (L240)  ← 读 config.yaml
  │          └─ ConfigurationHelper.init()          (L443)
  │              ├─ initEnvConfig()                 环境变量 → Map
  │              ├─ initServiceConfig()             YAML → Configurations
  │              │   ├─ Yaml().loadAs(...)          (L456)
  │              │   ├─ 展平嵌套配置 expandConfigMap  (L544)
  │              │   ├─ ConfigShadeUtils.decrypt()  敏感字段解密
  │              │   ├─ validateConfig()            校验
  │              │   ├─ DataSourceFactory.create()  ★建 MySQL/Derby 连接池
  │              │   └─ SqlSessionFactoryProvider.init()  ★MyBatis 会话工厂
  │              ├─ setIcebergSystemProperties()    Iceberg 线程池参数
  │              └─ initContainerConfig()           Optimizer 容器元数据
  │      └─ new HighAvailabilityContainer(conf)    (L115)  ← HA 模式必建 ZK
  │
  ├─ 02. addShutdownHook()                          (L121)  优雅下线
  │
  └─ while (true) {                                 (L129)  ★核心循环
       ├─ 03. waitLeaderShip()                      HA 模式等自己成主
       ├─ 04. startService()                        (L154) ★启动所有组件
       │       │
       │       ├─ 05. EventsManager + MetricManager       单例启动
       │       ├─ 06. DefaultCatalogManager              管"谁家的楼盘"
       │       ├─ 07. DefaultTableManager                表元数据查询门面
       │       ├─ 08. DefaultOptimizerManager            管"工人池子"
       │       ├─ 09. DefaultTableService                ★表运行时核心
       │       ├─ 10. DefaultOptimizingService           ★自优化核心
       │       │
       │       ├─ 11. InlineTableExecutors.setup()       10 种定时任务
       │       │       ├─ TableRuntimeHandler           表状态监听
       │       │       ├─ DataExpiringExecutor          过期数据清理
       │       │       ├─ SnapshotsExpiringExecutor     过期快照清理
       │       │       ├─ OrphanFilesCleaningExecutor   孤儿文件清理
       │       │       ├─ DanglingDeleteFilesCleaning   悬空删文件清理
       │       │       ├─ OptimizingCommitExecutor      优化结果提交
       │       │       ├─ OptimizingExpiringExecutor    优化任务过期
       │       │       ├─ BlockerExpiringExecutor       锁过期
       │       │       ├─ HiveCommitSyncExecutor        Hive 提交同步
       │       │       ├─ TableRefreshingExecutor       ★表刷新
       │       │       └─ TagsAutoCreatingExecutor      自动打 Tag
       │       │
       │       ├─ 12. tableService.initialize()          （实际拉起上面的 Chain）
       │       │
       │       ├─ 13. new TerminalManager()              SQL 终端（Kyuubi/Spark）
       │       │
       │       ├─ 14. initThriftService()                建 2 个 Thrift server
       │       │       ├─ AmoroTableMetastore proc       1260 端口
       │       │       └─ OptimizingService proc         1261 端口
       │       ├─ 15. startThriftService()               启动 Thrift 线程
       │       │
       │       ├─ 16. initHttpService()                  Javalin + Dashboard
       │       │       ├─ DashboardServer endpoints      前端页面
       │       │       └─ RestCatalogService endpoints   Iceberg REST
       │       ├─ 17. startHttpService()                 1630 端口 + 打 logo
       │       │
       │       └─ 18. registerAmsServiceMetric()         Prometheus 指标
       │
       ├─ 19. waitFollowerShip()                       HA 模式等自己掉主
       └─ finally { dispose() }                        ★关所有资源
     }
```

**学这张图要记住三个关键锚点**：

- **锚点 A**：`main()` 里有个 `while(true)` 循环（L129），这不是 bug，是 HA 的灵魂——**节点掉主会自动重启 service**。
- **锚点 B**：`startService()` 里组件建立的顺序**不可乱**：CatalogManager → TableManager → OptimizerManager → TableService → OptimizingService，**依赖单向向下**。
- **锚点 C**：Thrift **建两个 server**（1260 管元数据、1261 管优化），不是一个。排障时别混。

---

### L1 · 接口层：三个"长得很像"的核心抽象

大量 Amoro 新人第一次读源码都会被这组名字搞晕：

```
TableIdentifier
ServerTableIdentifier
AmoroTable<T>
```

**看起来都在表示"一张表"，到底有啥区别？用一个类比秒懂**：

| 抽象 | 生活类比 | 数据内容 | 谁持有 | 典型字段 |
|---|---|---|---|---|
| **TableIdentifier** | 业主的"身份证号" | 3 段名字 | 到处都用 | `catalog + database + tableName` |
| **ServerTableIdentifier** | 物业登记本上的"内部编号" | 身份证号 + 物业自编 ID + 表格式 | AMS 内部 | `id + catalog + db + table + TableFormat` |
| **AmoroTable<T>** | 业主的"入户后照片档案" | 编号 + 元数据 + 属性 + 当前快照 + 原始对象 | 运行时对象 | `id() + format() + properties() + currentSnapshot() + originalTable()` |

**通俗版本**：

- `TableIdentifier` = "我叫张三"
- `ServerTableIdentifier` = "我叫张三，物业编号 #00137，我是住 Iceberg 小区的"
- `AmoroTable` = "我叫张三，编号 #00137，住 Iceberg 小区，我家现在有 200 平方米、有 5 张床、昨晚最后一次开灯是 20:30"

**为什么要分三个？** 这是 **"分层抽象"** 的典型设计：

1. `TableIdentifier` 跨所有模块、跨进程都在用，字段越少越好（3 段名字 + 序列化友好）。
2. `ServerTableIdentifier` 进 AMS DB 后多了一个自增 ID（MyBatis 主键），方便内部高频查找。
3. `AmoroTable` 是运行时对象，持有真实的 Iceberg/Mixed/Paimon 表引用（`T originalTable()` 就是泛型），属性实时从文件系统读。

**记住这个设计，以后看到任何系统有三层类似抽象，你都能秒懂设计意图**。

---

### L2 · 主链路层：一次"业主报修"完整链路

**场景**：一个 Spark 作业写了张 Iceberg 表，过了 5 分钟 AMS 的 Dashboard 上显示这张表"有小文件需要优化"。

**问：从写表那一刻到 Dashboard 点亮"需要优化"的红灯，内部到底发生了什么？**

这条链路就是 AMS 的 **L2 主链路**，涉及 Day1 今天读到的全部类：

```
Spark写入表（AMS 感知不到）
     │
     ▼ (外部事件)
┌──────────────────────────────────────────────────────┐
│  TableRefreshingExecutor                             │  ← 每 N 秒巡查一次
│  (InlineTableExecutors)                              │
│                                                      │
│  for each tableRuntime in tableRuntimeMap:           │
│      tableRuntime.refresh()  ← 读表最新 snapshot     │
│                                                      │
└──────────────────┬───────────────────────────────────┘
                   │  发现有新 snapshot
                   ▼
┌──────────────────────────────────────────────────────┐
│  DefaultTableService                                 │
│  ├─ tableRuntimeMap: Map<Long, DefaultTableRuntime>  │  ★ 核心数据结构
│  └─ handleTableChanged(rt, originalStatus)           │
│     └─ headHandler.fireStatusChanged(rt, st)         │  ★ 责任链入口
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼ (责任链传播)
┌──────────────────────────────────────────────────────┐
│ RuntimeHandlerChain（链式处理）                       │
│                                                      │
│  OptimizingService.TableRuntimeHandler               │  ← 判断要不要优化
│        ↓                                             │
│  DataExpiringExecutor                                │  ← 过期数据检查
│        ↓                                             │
│  SnapshotsExpiringExecutor                           │  ← 快照过期
│        ↓                                             │
│  OrphanFilesCleaningExecutor                         │  ← 孤儿文件
│        ↓                                             │
│  （更多 Handler ...）                                │
└──────────────────┬───────────────────────────────────┘
                   │  判断"需要优化"
                   ▼
┌──────────────────────────────────────────────────────┐
│  DefaultOptimizingService（Day3 再深挖）              │
│  │                                                   │
│  └─ 推入 OptimizingQueue，等 Optimizer 来拉活         │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
       Dashboard 轮询 → 看到 "needs optimizing" → 点亮红灯
```

**这条链路最核心的一行代码**（L131-136）：

```java
@Override
public void handleTableChanged(
    DefaultTableRuntime tableRuntime, OptimizingStatus originalStatus) {
  if (headHandler != null) {
    headHandler.fireStatusChanged(tableRuntime, originalStatus);  // ★
  }
}
```

**教学点**：这是**责任链模式（Chain of Responsibility）**的教科书实现。`addHandlerChain()` 在启动时把 10 个 Executor 串成一条单链，任何一个 table 状态变化，链头一触发，所有 Handler 顺序执行。

### L2 · Catalog 加载：LoadingCache 的精妙用法

**场景**：Dashboard 每秒多次查某个 Catalog 的 meta，如果每次都查 MySQL 性能顶不住。

**看 Amoro 怎么解决**（`DefaultCatalogManager.java` L66-77）：

```java
metaCache =
    CacheBuilder.newBuilder()
        .maximumSize(100)                    // 最多缓存 100 个 Catalog
        .expireAfterWrite(cacheTtl)          // 定时过期
        .build(
            new CacheLoader<String, Optional<CatalogMeta>>() {
              @Override
              public @NotNull Optional<CatalogMeta> load(@NotNull String key) {
                return Optional.ofNullable(
                    getAs(CatalogMetaMapper.class, mapper -> mapper.getCatalog(key)));
              }
            });
```

**教学点**：这是 **Guava LoadingCache** 的经典用法。它的价值在：

1. **查 Catalog** 时 `metaCache.get(key)` —— **缓存命中就直接返回，不命中自动走 loader 查 DB**。
2. 用 `Optional` 包装——**让"查过但不存在"和"还没查过"能被区分**，避免缓存击穿。
3. `expireAfterWrite` —— 自动过期，不用手动清理。

**举一反三**：你在自己写代码的时候，任何"读多写少 + 读源是慢数据库"的场景，都可以抄这个模式。

---

### L3 · 异常/边界层预警（Day3-5 深挖）

读 Day1 这些代码时，eric 已经嗅到 **6 处潜在 L3 坑**，登记如下：

| 编号 | 文件 | 行号 | 嫌疑 | 类比 |
|---|---|---|---|---|
| **W1** | `AmoroServiceContainer` | L129 `while(true)` | HA 频繁切主会导致 service 反复 dispose/start；若 dispose 不干净，会有资源泄漏累积 | 物业交接班没做好，东西丢了 |
| **W2** | `AmoroServiceContainer` | L154 `startService` | 组件初始化顺序依赖强，某个组件 init 失败时后面的已初始化资源会不会都被正确清理？ | 装修顺序错，前面砌的墙要砸掉 |
| **W3** | `DefaultTableService` | L73 `tableRuntimeMap` | 这是个 ConcurrentHashMap，但 `onTableDropped` 里先 `dispose` 再 `remove`（L108-110），dispose 抛异常会留一个"僵尸 runtime" | 退房没注销，登记本上永远有这个人 |
| **W4** | `DefaultTableService` | L121 `addHandlerChain` | `checkNotStarted()` 说明这是启动期一次性注册；运行期不能动。如果需要动态加新 handler？ | 物业规章启动后不能改 |
| **W5** | `DefaultCatalogManager` | L82-87 构造器里 `for each → buildServerCatalog` | 一个 Catalog 构建失败会不会导致**整个 AMS 起不来**？ | 一个业主资料错，整个楼盘瘫痪 |
| **W6** | `DefaultCatalogManager` | L60 `serverCatalogMap` ConcurrentMap 配 `metaCache` LoadingCache | 两套缓存，**是否存在一致性窗口**？`getServerCatalog` 里 `reload` 调用的时机决定答案 | 前台和后厨菜单不同步 |

**这 6 处会在 Phase 3（Day 46-70）逐个复现验证**。

---

## 💡 精妙设计拆解（记住就能举一反三）

### 精妙一：`Container` / `Service` / `Manager` 三级命名法

Amoro 代码里的类名非常讲究，你可以从名字一眼看穿它的职责：

| 后缀 | 角色 | 例子 | 职责 |
|---|---|---|---|
| `Container` | 容器/装配器 | `AmoroServiceContainer`、`HighAvailabilityContainer`、`InlineTableExecutors` | 负责"装配 + 生命周期"，不持业务逻辑 |
| `Manager` | 门面/查询中心 | `CatalogManager`、`TableManager`、`OptimizerManager`、`TerminalManager` | 提供只读/查询/简单 CRUD，偏门面 |
| `Service` | 业务核心 | `TableService`、`OptimizingService` | 承载最重的业务逻辑、触发链路 |

**对比**：`TableManager` 和 `TableService` 并存（你看 `startService` 里 L159 和 L162），不是冗余，是**分层**：

- `TableManager` = 门面 / 提供只读 API 给上层 Dashboard 用
- `TableService` = 业务 / 管表运行时状态、触发优化、管 Handler 链

**对应工业级实践**：Microsoft 的 Clean Architecture 里，Manager 对应 UseCase 门面，Service 对应 Application Service。Amoro 的设计是老中医水平的。

### 精妙二：`main` 里的 `while(true)` 不是 bug

很多人初读这段代码的第一反应："这代码写错了吧？main 怎么死循环？"

```java
while (true) {
    try {
      service.waitLeaderShip();   // ← 阻塞等自己成主
      service.startService();     // ← 成主后启动全部组件
      service.waitFollowerShip(); // ← 阻塞等自己掉主
    } catch (...) { LOG.error(...); }
    finally { service.dispose(); } // ← 掉主后清理
}
```

**这个循环是 Amoro HA 的灵魂**。它的精妙在：

1. 三个阻塞点（等成主 → 启服务 → 等掉主）组成一个**主从切换机的状态机**。
2. `finally { dispose() }` 保证**掉主必然清理资源**，不会变"脑裂僵尸"。
3. `while(true)` 让**掉主后能重新竞选**而不用重启 JVM。

**对比 Kyuubi**：Kyuubi 的 HA 是让 Server 和 Engine 都写 ZK，客户端去 ZK 抢一个。Amoro 的 HA 是**"Server 自己管主从"**，更像 HBase Master 的选型。这也告诉我们：**HA 有两种流派，客户端发现型 vs 服务端选主型**，各有优劣。

### 精妙三：`TableRuntimeHandler` 责任链 vs 事件总线

为什么 Amoro 选责任链而不是事件总线？

| 维度 | 责任链（Amoro 选择） | 事件总线（其他项目常见） |
|---|---|---|
| 触发顺序 | **严格有序**，按 append 顺序 | 无序或按优先级 |
| 失败处理 | 前一个失败可以阻断后一个 | 各 Handler 独立，一个挂不影响别的 |
| 性能 | 同线程直接方法调用，低开销 | 通常异步，带队列，开销高 |
| 动态性 | 启动期 append，运行期不改（`checkNotStarted`） | 运行期动态订阅 |
| 适用场景 | 像 pipeline 那样有严格前后依赖 | 广播式，松耦合 |

**Amoro 选责任链的判据**：自优化的 10 个 Executor 有**逻辑前后依赖**——必须先 refresh 拿到最新 snapshot，才能判断要不要优化，才能清过期快照。用事件总线反而会丢掉这层依赖关系。

---

## 🎓 举一反三：这些模式在哪里还见过？

| Amoro 模式 | 同构系统 | 共同点 |
|---|---|---|
| `ServiceContainer.while(true){wait主→start→wait掉主→dispose}` | HBase Master、Flink JobManager、Kubernetes kube-scheduler | 所有自选主型 HA 都长这样 |
| `CatalogManager` 用 LoadingCache | Hive Metastore、Presto Catalog | 元数据访问都爱用 |
| `TableRuntimeMeta` 存 MySQL + 内存 `tableRuntimeMap` 做 cache | HBase `RegionServer` 的 regions 内存索引 | 冷热分层永恒真理 |
| 启动时 `addHandlerChain` 固化责任链 | Netty 的 `ChannelPipeline` | pipeline 都是启动期装配 |
| 两个 Thrift Server 分 port（元数据 vs 优化任务） | HDFS NameNode（8020 RPC / 9000 RPC / 50070 HTTP） | 按流量性质分端口，便于限流和排障 |
| `TableIdentifier` 3 段式 + `ServerTableIdentifier` 加 ID | HBase `TableName`（namespace+qualifier） + `RegionInfo`（encodedName） | "业务 ID + 内部 ID"双层表示 |

**关键启示**：**学任何新系统，先找它和你熟悉系统的同构关系**。90% 的"新知识"其实是旧知识的变种。

---

## 📝 课后习题（做完才算学会）

### ⭐ 题目 1：口播检测（必做）

不看本文，用**3 分钟 + 不超过 300 字**讲清楚：

1. AMS 进程启动时做了哪些事（至少列 5 件）？
2. AMS 监听了哪 3 个端口？各自干嘛用？
3. `TableManager` 和 `TableService` 有啥区别？

**评分标准**：讲完把录音发给你自己听，能听懂不卡壳 = 合格；能举类比讲给非技术人听 = 优秀。

### ⭐⭐ 题目 2：追链路（推荐做）

打开 IDEA，从 `main()` 开始设断点，follow 启动流程，亲眼看到：

- 何时建立 MySQL 连接池？
- 何时加载第一个 Catalog？
- 何时 Dashboard 1630 端口开始 LISTENING？

用 `netstat -ano | findstr :1630` 观察端口占用时间轴。

### ⭐⭐⭐ 题目 3：假想 Bug（进阶做）

假设生产 AMS 启动日志卡在 `Load catalog xxx, type:xxx` 之后 **10 分钟没进下一行**，根据今天读的源码，请列出**至少 3 个**可能的根因，每个根因对应 `DefaultCatalogManager` / `CatalogBuilder` 的哪段代码。

### ⭐⭐⭐⭐ 题目 4：压力测试（高阶）

写一个小 demo，在本地跑 AMS，然后：

- 连续注册 1000 个 Catalog（模拟大规模生产）
- 观察 `LoadingCache(maximumSize=100)` 的行为
- 思考：如果用户真的有 >100 个 Catalog，会怎样？`DefaultCatalogManager` 这处硬编码 100 合理吗？

**把你的分析写下来**，这就是后面 Phase 4 "提 PR" 的素材。

### ⭐⭐⭐⭐⭐ 题目 5：源码考古（挑战级）

用 `git log` 找到 `AmoroServiceContainer.java` 最近 5 个重大 commit，读 commit message + diff + 关联的 PR/Issue，写出：**Amoro 的 HA 机制是从哪一版、为什么加进来的？**

**提示**：`git log --all --oneline -- amoro-ams/src/main/java/org/apache/amoro/server/AmoroServiceContainer.java`

---

## 🧪 本讲知识晶体（按法则 9 沉淀）

### 问题/场景
一个 Amoro 新手接手运维 AMS 后，第一次遇到启动失败、Dashboard 打不开、Thrift 连不上——不知道从何下手。

### 核心源码锚点
- `AmoroServiceContainer.main` (L118-144) — 启动入口
- `AmoroServiceContainer.startService` (L154-191) — 组件装配顺序
- `AmoroServiceContainer.initThriftService` (L345-389) — Thrift 双端口
- `AmoroServiceContainer.startHttpService` (L323-338) — Dashboard 1630
- `DefaultCatalogManager` 构造器 (L62-89) — Catalog 启动加载
- `DefaultTableService.initialize` (L147+) — 表运行时初始化入口

### 调用链速查
```
main → while(true) → waitLeader → startService
   → CatalogManager → TableManager → OptimizerManager
   → TableService → OptimizingService
   → InlineTableExecutors (10 handlers)
   → tableService.initialize()
   → TerminalManager
   → 2 Thrift Servers (1260 / 1261)
   → Javalin HTTP (1630) → print ASCII logo
```

### 设计意图速记
- **容器化组织**：`ServiceContainer` 管生命周期，业务类管逻辑
- **分层命名**：`Manager` 门面、`Service` 业务、`Container` 装配
- **HA 一体化**：HA 用 while(true) 内聚在 main 里，不散落
- **责任链强顺序**：`RuntimeHandlerChain` 替代事件总线
- **LoadingCache 防击穿**：Catalog meta 缓存的正确姿势

### 关键端口/参数速查
| 项 | 默认值 | 配置 key | 排障用 |
|---|---|---|---|
| HTTP/Dashboard | 1630 | `ams.server.http.port` | 排 `netstat \| findstr :1630` |
| Thrift TableService | 1260 | `ams.server.thrift.table.port` | 引擎连 AMS 的口 |
| Thrift OptimizingService | 1261 | `ams.server.thrift.optimizing.port` | Optimizer 连 AMS 的口 |
| Thrift selector threads | - | `ams.server.thrift.selector.threads` | 高并发扩它 |
| Thrift worker threads | - | `ams.server.thrift.worker.threads` | 高并发扩它 |
| Thrift max message | - | `ams.server.thrift.max.message.size` | 大 Schema 提这个 |
| Catalog meta TTL | - | `ams.server.catalog.meta.cache.expiration.interval` | Catalog 频繁变更调短 |
| 表刷新间隔 | - | `ams.server.refresh.external.catalogs.interval` | 大集群调长省资源 |

### 关联知识
- **上游调用**：`bin/ams.sh` → `java org.apache.amoro.server.AmoroServiceContainer`
- **下游调用**：`DefaultOptimizingService`（Day3 深挖）、`InlineTableExecutors`（Day4 深挖）
- **同构系统**：HBase Master、Flink JobManager、HMS

### 踩坑记录
- Day1 整理 6 处 L3 预警（W1-W6），Phase 3 验证
- 注意 `while(true)` 不是 bug，是 HA 状态机

---

## 🔚 本讲收尾

### 今天我学会了

- [x] AMS 启动 12 步流程（默画）
- [x] 三个 Table 抽象的分层设计意图
- [x] 10 个 InlineTableExecutor 的名字和职责
- [x] 两个 Thrift Server 分口的理由
- [x] 责任链 vs 事件总线的判据
- [x] LoadingCache 防击穿的正确姿势
- [x] Amoro HA 靠 `while(true)` + `dispose()` 状态机

### 段位变化

| 维度 | Day0 | Day1 |
|---|---|---|
| Amoro 使用 | L2 | L2（不变） |
| Amoro 源码 | L1 偏下 | **L1.5**（进入 L2 门口）|
| 能画架构图 | 只能画框框 | **能画带 12 步启动顺序的完整图** |
| 能定位代码 | 不能 | **能定位到启动阶段的行号** |

### 下次开工（Day2 任务清单）

1. 🔍 读 `DefaultTableService.initialize()` 完整实现（今天只读到 L150，还有 600 行）
2. 🔍 读 `DefaultTableRuntime` —— 单表运行时的核心载体
3. 🔍 读 `RuntimeHandlerChain` —— 责任链的具体实现
4. 🔍 读 `ExternalCatalog.refresh()` —— 外部 Catalog 探测器
5. ✍️ 按"教授讲课八段式"产出 Day2 教学笔记
6. ✍️ 完成今天的课后习题 1（口播 3 分钟）

---

> **信条**：读源码不是读代码，是读作者脑中的世界。能把作者的设计意图教给别人，你就到了 L3。

— eric · Amoro 源码精通 · 第 01 讲
