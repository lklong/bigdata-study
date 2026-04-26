# Amoro 源码深度解析：AMS Server 表管理与 Catalog 集成

> 基于 `/Users/kailongliu/bigdata/gitProjects/amoro/` 真实源码逐行分析
> Eric | 2026-04-25

---

## 一、架构总览

```
┌──────────────────────────────────────────────────────────────┐
│                    Thrift RPC / REST API                      │
│  TableManagementService        RestCatalogService             │
│  (Thrift: getCatalogs/         (Javalin: Iceberg REST         │
│   createTable/dropTable)        Catalog Protocol)             │
└──────────┬────────────────────────────┬──────────────────────┘
           │                            │
           ▼                            ▼
┌─────────────────────────┐  ┌─────────────────────────────────┐
│     TableManager        │  │       CatalogManager            │
│   (接口：聚合3个子接口)  │  │   (接口：Catalog CRUD + 加载)    │
│                         │  │                                 │
│  DefaultTableManager    │  │  DefaultCatalogManager          │
│  - createTable()        │  │  - LoadingCache<CatalogMeta>    │
│  - dropTableMetadata()  │  │  - ConcurrentMap<ServerCatalog> │
│  - block()/release()    │  │  - CatalogBuilder 工厂          │
└──────────┬──────────────┘  └──────────┬──────────────────────┘
           │                            │
           ▼                            ▼
┌─────────────────────────┐  ┌─────────────────────────────────┐
│     TableService        │  │       ServerCatalog             │
│   (接口：运行时管理)     │  │       (抽象基类)                │
│                         │  │                                 │
│  DefaultTableService    │  │  ├─ InternalCatalog (抽象)      │
│  - tableRuntimeMap      │  │  │   └─ InternalCatalogImpl     │
│    ConcurrentHashMap    │  │  │      (AMS 内置 REST Catalog) │
│  - initialize()         │  │  │                              │
│  - exploreTableRuntimes │  │  └─ ExternalCatalog             │
│  - RuntimeHandlerChain  │  │      (HMS/Hadoop/Glue/Custom)   │
└─────────────────────────┘  └─────────────────────────────────┘
```

---

## 二、CatalogManager — Catalog 生命周期管理

**源码位置**: `amoro-ams/src/main/java/org/apache/amoro/server/catalog/`

### 2.1 CatalogManager 接口

```java
// CatalogManager.java
public interface CatalogManager {
    List<CatalogMeta> listCatalogMetas();        // 列出所有 Catalog 元数据
    CatalogMeta getCatalogMeta(String name);     // 获取指定 Catalog 元数据
    boolean catalogExist(String name);           // 检查 Catalog 是否存在
    ServerCatalog getServerCatalog(String name); // 获取服务端 Catalog 实例
    InternalCatalog getInternalCatalog(String n);// 获取内部 Catalog（AMS 类型）
    List<ServerCatalog> getServerCatalogs();     // 获取所有 Catalog 实例
    void createCatalog(CatalogMeta meta);        // 创建 Catalog
    void dropCatalog(String name);               // 删除 Catalog
    void updateCatalog(CatalogMeta meta);        // 更新 Catalog 配置
    AmoroTable<?> loadTable(TableIdentifier id); // 加载表
}
```

### 2.2 DefaultCatalogManager — 缓存 + 懒加载

```java
// DefaultCatalogManager.java
public class DefaultCatalogManager extends PersistentBase implements CatalogManager {
    // 两级缓存
    private final LoadingCache<String, CatalogMeta> metaCache;    // Guava 缓存：Catalog 名 → 元数据
    private final ConcurrentMap<String, ServerCatalog> serverCatalogMap; // Catalog 实例缓存

    // 初始化：从数据库加载所有 Catalog
    public DefaultCatalogManager(Configurations config) {
        metaCache = CacheBuilder.newBuilder()
            .expireAfterWrite(...)
            .build(new CacheLoader<>() {
                public CatalogMeta load(String name) {
                    return getAs(CatalogMetaMapper.class, m -> m.getCatalog(name));
                }
            });
    }
```

**核心流程 — `getServerCatalog()`**:

```
1. metaCache.get(name) → 从数据库/缓存加载 CatalogMeta
2. serverCatalogMap.computeIfAbsent(name, n ->
       CatalogBuilder.buildServerCatalog(meta, config))  // 首次访问时构建
3. serverCatalog.reload(meta)  // 刷新配置（热更新）
4. return serverCatalog
```

### 2.3 CatalogBuilder — 工厂模式构建 Catalog

```java
// CatalogBuilder.java
public class CatalogBuilder {
    // 格式支持矩阵
    static Map<String, Set<TableFormat>> formatSupportedMatrix = {
        "hadoop" → {ICEBERG, MIXED_ICEBERG, PAIMON, HUDI}
        "glue"   → {ICEBERG, MIXED_ICEBERG}
        "custom" → {ICEBERG, MIXED_ICEBERG}
        "hive"   → {ICEBERG, MIXED_ICEBERG, MIXED_HIVE, PAIMON, HUDI}
        "ams"    → {ICEBERG, MIXED_ICEBERG}
    };

    public static ServerCatalog buildServerCatalog(CatalogMeta meta, Configurations config) {
        if (CATALOG_TYPE_AMS.equals(meta.getCatalogType())) {
            return new InternalCatalogImpl(meta, config);  // AMS 内置 → REST Catalog
        } else {
            return new ExternalCatalog(meta);              // 外部 → 委托 UnifiedCatalog
        }
    }
}
```

---

## 三、ServerCatalog 继承体系

### 3.1 ServerCatalog — 抽象基类

```java
// ServerCatalog.java
public abstract class ServerCatalog extends PersistentBase {
    private CatalogMeta metadata;
    private TableMetaStore metaStore;

    public abstract boolean isInternal();                    // 是否内部 Catalog
    public abstract List<String> listDatabases();            // 列库
    public abstract List<TableIDWithFormat> listTables(String db); // 列表
    public abstract AmoroTable<?> loadTable(String db, String tbl); // 加载表
    public abstract void dispose();                          // 释放资源
}
```

### 3.2 InternalCatalog — AMS 内部管理

```java
// InternalCatalog.java
public abstract class InternalCatalog extends ServerCatalog {
    @Override
    public boolean isInternal() { return true; }

    // 库管理 — 直接操作 AMS 数据库
    public void createDatabase(String dbName) {
        doAsTransaction(
            () -> doAs(TableMetaMapper.class, m -> m.insertDatabase(...)),
            () -> doAsExisted(CatalogMetaMapper.class, m -> m.incDatabaseCount(1, name()), ...)
        );
    }

    // 表管理 — 事务性操作（4步原子）
    public TableMetadata createTable(TableMetadata meta) {
        doAsTransaction(
            () -> insertTable(id),       // 1. 插入表标识
            () -> insertTableMeta(meta), // 2. 插入表元数据
            () -> incTableCount(),       // 3. Catalog 表计数 +1
            () -> incDbTableCount()      // 4. Database 表计数 +1
        );
    }

    // 删除表 — 事务性操作（6步原子）
    public ServerTableIdentifier dropTable(String db, String tbl) {
        doAsTransaction(
            () -> deleteTableIdById(),        // 1. 删除表标识
            () -> deleteTableMetaById(),      // 2. 删除表元数据
            () -> deleteTableBlockers(),      // 3. 清理表阻塞器
            () -> dropTableInternal(),        // 4. 子类清理钩子
            () -> decTableCount(),            // 5. Catalog 表计数 -1
            () -> decDbTableCount()           // 6. Database 表计数 -1
        );
    }

    // 抽象方法 — 由 InternalCatalogImpl 实现
    public abstract InternalTableCreator newTableCreator(...);
    public abstract InternalTableHandler newTableHandler(...);
}
```

### 3.3 InternalCatalogImpl — Iceberg REST Catalog 集成

```java
// InternalCatalogImpl.java
public class InternalCatalogImpl extends InternalCatalog {
    private final String exposedHost;
    private final int httpPort;
    private final Cache<AmoroTable<?>, FileIO> fileIOCloser; // Caffeine 弱引用缓存

    // 构造时自动注入 REST Catalog 配置
    public InternalCatalogImpl(CatalogMeta meta, Configurations config) {
        // 自动设置 catalog-impl = RESTCatalog
        // 自动设置 uri = http://{exposedHost}:{httpPort}/api/iceberg/rest
        meta.putToCatalogProperties("uri", defaultRestURI());
        meta.putToCatalogProperties("catalog-impl", "org.apache.iceberg.rest.RESTCatalog");
    }

    // 加载表 — 根据格式分发
    @Override
    public AmoroTable<?> loadTable(String db, String tbl) {
        InternalTableHandler<TableOperations> handler = newTableHandler(db, tbl);
        if (ICEBERG.equals(handler.tableMetadata().getFormat())) {
            return loadIcebergTable(db, tbl, handler);       // 纯 Iceberg
        } else if (MIXED_ICEBERG.equals(handler.tableMetadata().getFormat())) {
            return loadMixedIcebergTable(db, tbl, handler);  // Mixed Iceberg
        }
    }

    // 加载 Mixed-Iceberg 表 — BaseStore + ChangeStore
    private AmoroTable<?> loadMixedIcebergTable(...) {
        BaseTable baseTable = loadTableStore(metadata, false);    // BaseStore
        if (InternalTableUtil.isKeyedMixedTable(metadata)) {
            BaseTable changeTable = loadTableStore(metadata, true); // ChangeStore
            return new BasicKeyedTable(location, keySpec, baseTable, changeTable);
        } else {
            return new BasicUnkeyedTable(id, baseTable, fileIO, props);
        }
    }

    // 创建表 — 根据格式分发
    @Override
    public InternalTableCreator newTableCreator(String db, String tbl, TableFormat format, ...) {
        if (ICEBERG.equals(format)) {
            return new InternalIcebergCreator(meta, db, tbl, args);
        } else if (MIXED_ICEBERG.equals(format)) {
            return new InternalMixedIcebergCreator(meta, db, tbl, args);
        }
    }
}
```

### 3.4 ExternalCatalog — 外部 Catalog 委托

```java
// ExternalCatalog.java
public class ExternalCatalog extends ServerCatalog {
    private CommonUnifiedCatalog unifiedCatalog;  // 委托对象
    private Pattern databaseFilterPattern;        // 库名正则过滤
    private Pattern tableFilterPattern;           // 表名正则过滤

    @Override
    public boolean isInternal() { return false; }

    @Override
    public AmoroTable<?> loadTable(String db, String tbl) {
        return doAs(() -> unifiedCatalog.loadTable(db, tbl));  // 直接委托
    }

    // 同步外部表到 AMS
    public void syncTable(ServerTableIdentifier id) {
        doAs(TableMetaMapper.class, m -> m.insertTable(id));
    }

    // 移除不再存在的表
    public void disposeTable(ServerTableIdentifier id) {
        doAs(TableMetaMapper.class, m -> m.deleteTableIdById(id.getId()));
    }
}
```

---

## 四、TableService — 表运行时管理

### 4.1 核心数据结构

```java
// DefaultTableService.java
public class DefaultTableService extends PersistentBase implements TableService {
    private final ConcurrentHashMap<Long, TableRuntime> tableRuntimeMap;  // 核心：所有表运行时
    private RuntimeHandlerChain headHandler;  // 责任链头节点
    private final CatalogManager catalogManager;
    private ScheduledExecutorService tableExplorerScheduler;  // 定时同步线程
    private ThreadPoolExecutor tableExplorerExecutors;        // 同步工作线程池
```

### 4.2 初始化流程

```
initialize()
  │
  ├── 1. 从数据库加载所有 TableRuntimeMeta
  │      getAs(TableMetaMapper.class, ::selectTableRuntimeMetas)
  │
  ├── 2. 构建 TableRuntime 对象并注册到 map
  │      for each meta:
  │        TableRuntime runtime = new TableRuntime(meta, this)
  │        tableRuntimeMap.put(meta.tableId, runtime)
  │        runtime.registerMetric(globalRegistry)  // 注册 Prometheus 指标
  │
  ├── 3. 初始化责任链（事件处理器）
  │      headHandler.initialize(tableRuntimes)
  │
  └── 4. 启动定时同步任务
         tableExplorerScheduler.scheduleAtFixedRate(
             this::exploreTableRuntimes,       // 同步内外部 Catalog 的表
             0, refreshInterval, MILLISECONDS)
```

### 4.3 表同步机制 — `exploreTableRuntimes()`

```
exploreTableRuntimes()
  │
  ├── 遍历所有 ServerCatalog
  │    for each catalog in catalogManager.getServerCatalogs():
  │
  ├── Internal Catalog → exploreInternalCatalog()
  │    对比数据库中的表 vs tableRuntimeMap
  │    ├── 新表 → 创建 TableRuntime + 注册指标 + 触发 headHandler.fireTableAdded()
  │    └── 已删除表 → 移除 TableRuntime + 触发 headHandler.fireTableRemoved()
  │
  └── External Catalog → exploreExternalCatalog()
       1. unifiedCatalog.listDatabases() + listTables()  获取外部最新表列表
       2. 对比已同步的表：
          ├── 新表 → syncTable() + 创建 TableRuntime
          └── 已删除表 → disposeTable() + 移除 TableRuntime
       3. 清理不存在的 Catalog 残留 TableRuntime
```

### 4.4 RuntimeHandlerChain — 事件驱动

```java
// RuntimeHandlerChain.java（责任链模式）
public abstract class RuntimeHandlerChain implements TableRuntimeHandler {
    private RuntimeHandlerChain next;

    // 事件传播
    public void fireTableAdded(TableRuntime runtime) {
        handleTableAdded(runtime);         // 当前处理
        if (next != null) next.fireTableAdded(runtime);  // 传递给下一个
    }

    public void fireStatusChanged(TableRuntime runtime, OptimizingStatus oldStatus) {
        handleStatusChanged(runtime, oldStatus);
        if (next != null) next.fireStatusChanged(runtime, oldStatus);
    }

    public void fireConfigChanged(TableRuntime runtime, TableConfiguration oldConfig) {
        handleConfigChanged(runtime, oldConfig);
        if (next != null) next.fireConfigChanged(runtime, oldConfig);
    }
}
```

**核心 Handler 链**:

```
DefaultTableService
  └── headHandler → [OptimizingQueue] → [AsyncTableExecutors] → ...
                     (调度优化任务)       (异步维护任务：
                                           - SnapshotExpiring
                                           - OrphanFileCleaning
                                           - DataExpiring
                                           - TagAutoCreating)
```

---

## 五、TableManager — 表 CRUD 操作

```java
// DefaultTableManager.java
public class DefaultTableManager extends PersistentBase implements TableManager {
    private final CatalogManager catalogManager;
    private final long blockerTimeout;

    // 创建表
    public void createTable(String catalogName, TableMetadata metadata) {
        InternalCatalog catalog = catalogManager.getInternalCatalog(catalogName);
        if (catalog.tableExists(db, tbl)) throw AlreadyExistsException;
        TableMetadata meta = catalog.createTable(metadata);         // 写库
        tableService().ifPresent(s -> s.onTableCreated(catalog, meta.getTableIdentifier()));
        // → 触发 DefaultTableService.onTableCreated()
        //   → 创建 TableRuntime
        //   → 注册指标
        //   → 触发 headHandler.fireTableAdded()
    }

    // 删除表
    public void dropTableMetadata(TableIdentifier id) {
        InternalCatalog catalog = catalogManager.getInternalCatalog(id.getCatalog());
        ServerTableIdentifier serverId = catalog.dropTable(db, tbl);  // 写库（6步事务）
        tableService().ifPresent(s -> s.onTableDropped(catalog, serverId));
        // → 触发 headHandler.fireTableRemoved()
        // → runtime.dispose()
        // → tableRuntimeMap.remove()
    }

    // 阻塞器管理（防并发冲突）
    public Blocker block(TableIdentifier id, List<BlockableOperation> ops, ...) {
        // 1. 清理过期 blocker
        // 2. 检查冲突（conflict detection）
        // 3. CAS 插入新 blocker（重试 TABLE_BLOCKER_RETRY 次）
    }
}
```

---

## 六、ServerTableIdentifier — 服务端表标识

```java
// ServerTableIdentifier.java (amoro-common)
public class ServerTableIdentifier {
    private Long id;             // 服务端自增 ID（MySQL auto_increment）
    private String catalog;      // Catalog 名
    private String database;     // Database 名
    private String tableName;    // 表名
    private TableFormat format;  // 表格式（ICEBERG / MIXED_ICEBERG / MIXED_HIVE / PAIMON / HUDI）

    // 转换为通用 TableIdentifier
    public TableIdentifier getIdentifier() {
        return new TableIdentifier(catalog, database, tableName);
    }
}
```

---

## 七、RestCatalogService — Iceberg REST Protocol

```java
// RestCatalogService.java
public class RestCatalogService extends PersistentBase {
    public static final String ICEBERG_REST_API_PREFIX = "/api/iceberg/rest";

    // HTTP 路由（Javalin）
    public EndpointGroup endpoints() {
        return () -> path(ICEBERG_REST_API_PREFIX, () -> {
            get("v1/config",                    this::getCatalogConfig);
            get("v1/namespaces",                this::listNamespaces);
            post("v1/namespaces",               this::createNamespace);
            get("v1/namespaces/{ns}",           this::getNamespace);
            delete("v1/namespaces/{ns}",        this::dropNamespace);
            get("v1/namespaces/{ns}/tables",    this::listTables);
            post("v1/namespaces/{ns}/tables",   this::createTable);
            get("v1/namespaces/{ns}/tables/{t}",  this::loadTable);
            post("v1/namespaces/{ns}/tables/{t}", this::updateTable);
            delete("v1/namespaces/{ns}/tables/{t}", this::dropTable);
            head("v1/namespaces/{ns}/tables/{t}",   this::tableExists);
            post("v1/namespaces/{ns}/tables/{t}/metrics", this::reportMetrics);
        });
    }
}
```

**核心调用链**:

```
Spark/Flink Client
  → RESTCatalog (Iceberg 标准客户端)
    → HTTP POST /api/iceberg/rest/v1/namespaces/{ns}/tables
      → RestCatalogService.createTable()
        → InternalCatalogImpl.newTableCreator()
          → InternalIcebergCreator / InternalMixedIcebergCreator
            → 写入 AMS 数据库 + 创建底层 Iceberg 表元数据
```

---

## 八、关键设计模式总结

| 模式 | 应用 | 作用 |
|------|------|------|
| **工厂模式** | `CatalogBuilder.buildServerCatalog()` | 根据 Catalog 类型构建对应实例 |
| **委托模式** | `ExternalCatalog → UnifiedCatalog` | 外部 Catalog 操作透明委托 |
| **责任链** | `RuntimeHandlerChain` | 表状态变更事件多 Handler 串行处理 |
| **缓存 + 懒加载** | `LoadingCache<CatalogMeta>` | Catalog 元数据按需加载 + 过期刷新 |
| **弱引用缓存** | `Caffeine<AmoroTable, FileIO>` | FileIO 自动 GC 回收 |
| **事务聚合** | `doAsTransaction(...)` | 多步数据库操作原子执行 |
| **定时同步** | `exploreTableRuntimes()` | 持续发现外部 Catalog 新增/删除的表 |
| **阻塞器** | `TableBlocker` | 防止表级并发操作冲突 |

---

## 九、运维关键参数

| 参数 | 含义 | 默认值 |
|------|------|--------|
| `refresh-external-catalogs.thread-count` | 同步外部 Catalog 的线程数 | `10` |
| `refresh-external-catalogs.queue-size` | 同步任务队列大小 | `1000` |
| `refresh-external-catalogs.interval` | 同步间隔（ms） | `180000`（3分钟） |
| `blocker.timeout` | 表阻塞器超时时间（ms） | `60000`（1分钟） |
| `database-filter` | External Catalog 库名过滤正则 | — |
| `table-filter` | External Catalog 表名过滤正则 | — |
