# Hive Metastore 架构与核心服务源码分析

> **源码路径**：`txProjects/hive/standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/HiveMetaStore.java`（362.98 KB）
> **铁律遵守**：本文所有代码片段、行号均来自上述真实源码文件，未基于二手资料

---

## 一、定位与角色

Hive Metastore（HMS）是大数据生态的"元数据中枢"：

- **服务形态**：基于 Apache Thrift 的独立 RPC 服务（端口默认 9083）
- **共享对象**：Hive、Spark SQL、Trino/Presto、Flink、Iceberg HiveCatalog 全部读它
- **存储后端**：MySQL/PostgreSQL/Oracle/Derby（通过 DataNucleus JDO 抽象）

**类继承关系**（HiveMetaStore.java:199）：
```java
199: public class HiveMetaStore extends ThriftHiveMetastore {
255:   public static class HMSHandler extends FacebookBase implements IHMSHandler {
```

`ThriftHiveMetastore` 是 Thrift 编译生成的 RPC 框架基类，`HMSHandler` 是真正的服务实现。

---

## 二、HMSHandler 核心数据结构

### 2.1 ThreadLocal 存储模型（HiveMetaStore.java:275-296）

```java
275: private static final ThreadLocal<RawStore> threadLocalMS =
       new ThreadLocal<RawStore>() {
         @Override
         protected RawStore initialValue() {
           return null;
         }
       };

283: private static final ThreadLocal<TxnStore> threadLocalTxn = ...

290: private static final ThreadLocal<Map<String, com.codahale.metrics.Timer.Context>> timerContexts = ...
```

**设计意图**：
- 每个 Thrift handler 线程独立持有一份 `RawStore`（JDO 持久化层）
- 避免多线程共享 `PersistenceManager` 引发死锁
- `TxnStore` 同理用于事务管理

### 2.2 关键状态字段

```java
266:   private FileMetadataManager fileMetadataManager;
267:   private PartitionExpressionProxy expressionProxy;
268:   private StorageSchemaReader storageSchemaReader;
272:   static AtomicInteger databaseCount, tableCount, partCount;  // metrics 计数器
274:   private Warehouse wh;  // hdfs warehouse 操作封装
```

---

## 三、create_table 核心链路

### 3.1 入口路由（HiveMetaStore.java:1791-1797）

```java
1791: private void create_table_core(final RawStore ms, final Table tbl,
1792:     final EnvironmentContext envContext, List<SQLPrimaryKey> primaryKeys,
1793:     List<SQLForeignKey> foreignKeys, List<SQLUniqueConstraint> uniqueConstraints,
1794:     List<SQLNotNullConstraint> notNullConstraints, List<SQLDefaultConstraint> defaultConstraints,
1795:                                List<SQLCheckConstraint> checkConstraints)
1796:     throws AlreadyExistsException, MetaException,
1797:     InvalidObjectException, NoSuchObjectException {
```

### 3.2 校验阶段（HiveMetaStore.java:1798-1823）

```java
1798: if (!MetaStoreUtils.validateName(tbl.getTableName(), conf)) {
1799:   throw new InvalidObjectException(tbl.getTableName()
1800:       + " is not a valid object name");
1801: }
1802: String validate = MetaStoreUtils.validateTblColumns(tbl.getSd().getCols());
```

**校验三件套**：
1. 表名合法性（正则匹配）
2. 列定义合法性（无重复、有效类型）
3. 分区字段、Skewed 列校验

### 3.3 事务开启 + 数据库存在性检查（HiveMetaStore.java:1833-1843）

```java
1833: firePreEvent(new PreCreateTableEvent(tbl, this));
1834:
1835: ms.openTransaction();   // ⭐ 开启 JDO 事务
1836:
1837: db = ms.getDatabase(tbl.getCatName(), tbl.getDbName());
1838:
1839: // get_table checks whether database exists, it should be moved here
1840: if (is_table_exists(ms, tbl.getCatName(), tbl.getDbName(), tbl.getTableName())) {
1841:   throw new AlreadyExistsException("Table " + getCatalogQualifiedTableName(tbl)
1842:       + " already exists");
1843: }
```

**关键设计**：
- `firePreEvent` 触发监听器（PreEventListener），可拦截非法操作（如 Ranger ACL 拦截）
- `openTransaction()` 是嵌套事务计数（reference counting），不是真正的 BEGIN

### 3.4 HDFS 路径管理（HiveMetaStore.java:1845-1867）

```java
1845: if (!TableType.VIRTUAL_VIEW.toString().equals(tbl.getTableType())) {
1846:   if (tbl.getSd().getLocation() == null
1847:       || tbl.getSd().getLocation().isEmpty()) {
1848:     tblPath = wh.getDefaultTablePath(db, tbl);   // 用 warehouse 默认路径
1849:   } else {
1850:     if (!isExternal(tbl) && !MetaStoreUtils.isNonNativeTable(tbl)) {
1851:       LOG.warn("Location: " + tbl.getSd().getLocation()
1852:           + " specified for non-external table:" + tbl.getTableName());
1853:     }
1854:     tblPath = wh.getDnsPath(new Path(tbl.getSd().getLocation()));
1855:   }
1856:   tbl.getSd().setLocation(tblPath.toString());
1857: }
1858:
1859: if (tblPath != null) {
1860:   if (!wh.isDir(tblPath)) {
1861:     if (!wh.mkdirs(tblPath)) {       // ⭐ HDFS mkdir
1862:       throw new MetaException(tblPath
1863:           + " is not a directory or unable to create one");
1864:     }
1865:     madeDir = true;
1866:   }
1867: }
```

**坑点**：
- 非 EXTERNAL 表如果指定了 `LOCATION`，会打 WARN 日志（数据可能不被 DROP TABLE 清理）
- `madeDir = true` 标记，后续失败回滚时需要删除已创建的目录

### 3.5 持久化阶段（HiveMetaStore.java:1881-1907）

```java
1881: if (primaryKeys == null && foreignKeys == null
1882:         && uniqueConstraints == null && notNullConstraints == null && defaultConstraints == null
1883:     && checkConstraints == null) {
1884:   ms.createTable(tbl);            // ⭐ 简单路径
1885: } else {
   ...
1906:   List<String> constraintNames = ms.createTableWithConstraints(tbl, primaryKeys, foreignKeys,
1907:       uniqueConstraints, notNullConstraints, defaultConstraints, checkConstraints);
```

**RawStore.createTable 实现位于 ObjectStore.java**，通过 JDO `pm.makePersistent(mtbl)` 写入 DB。

### 3.6 Stats 自动收集（HiveMetaStore.java:1868-1871）

```java
1868: if (MetastoreConf.getBoolVar(conf, ConfVars.STATS_AUTO_GATHER) &&
1869:     !MetaStoreUtils.isView(tbl)) {
1870:   MetaStoreUtils.updateTableStatsSlow(db, tbl, wh, madeDir, false, envContext);
1871: }
```

**对应配置**：`hive.stats.autogather=true`（默认 true）

---

## 四、create_database 链路（HiveMetaStore.java:1242）

```java
1242: private void create_database_core(RawStore ms, final Database db)
   ...
1302: public void create_database(final Database db)
1303:     throws AlreadyExistsException, InvalidObjectException, MetaException {
1304:   startFunction("create_database", ": " + db.toString());
   ...
1327:   create_database_core(getMS(), db);
   ...
1341:   endFunction("create_database", success, ex);
```

**双层封装设计**：
- 外层 `create_database`：负责 metrics 计时、监听器、异常翻译
- 内层 `create_database_core`：纯业务逻辑

`startFunction/endFunction` 模式贯穿所有 RPC 入口，是 HMS 监控指标的核心机制。

---

## 五、调用链全景

```
Hive CLI / Spark / Trino
        │
        ▼ Thrift RPC (port 9083)
ThriftHiveMetastore.Iface.create_table()
        │
        ▼
HMSHandler.create_table()                      [HiveMetaStore.java]
   ├─ startFunction()                          → metrics + log
   ├─ firePreEvent(PreCreateTableEvent)        → listener 拦截
   ├─ getMS()  → ThreadLocal<RawStore>
   └─ create_table_core()                      [line 1791]
       ├─ MetaStoreUtils.validateName()
       ├─ ms.openTransaction()                 → JDO transaction
       ├─ ms.getDatabase()                     → 检查 DB 存在
       ├─ is_table_exists()                    → 防重
       ├─ wh.mkdirs(tblPath)                   → HDFS 操作
       ├─ MetaStoreUtils.updateTableStatsSlow() → 自动收集 stats
       ├─ ms.createTable(tbl)                  → JDO 持久化
       │      └─ ObjectStore.createTable()
       │             └─ pm.makePersistent(mtbl) → 写入 RDBMS
       ├─ transactionalListenerResponses       → 触发后置事件
       └─ ms.commitTransaction()
```

---

## 六、生产关注点

### 6.1 DataNucleus JDO 性能瓶颈

- **PersistenceManager 缓存**：每个 Thread 独占一份，避免锁竞争但内存翻倍
- **N+1 查询陷阱**：getTable 时如果级联 fetch 分区会爆内存
- **缓解**：开启 `datanucleus.connectionPool.maxPoolSize` 限流

### 6.2 元数据锁

- HMS 本身**无显式行锁**，依赖 RDBMS 隔离级别
- 高并发 alter table 会出现 `ConcurrentModificationException`
- 生产建议：MySQL 改用 RR（Repeatable Read），并控制 alter 并发

### 6.3 监听器扩展点

- **PreEventListener**：操作前拦截（Ranger 鉴权）
- **MetaStoreEventListener**：操作后通知（Atlas 血缘）
- **TransactionalMetaStoreEventListener**：事务内通知（Notification Log）

### 6.4 Notification Log

- 每次元数据变更写入 `NOTIFICATION_LOG` 表
- 用于 Hive Replication（DR）、Ranger Tag 同步、Atlas 增量血缘
- **必须定期清理**：`metastore.event.db.listener.timetolive` 控制 TTL

---

## 七、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `metastore.thrift.uris` | - | HMS Thrift 端点 |
| `javax.jdo.option.ConnectionURL` | - | 后端 RDBMS JDBC URL |
| `metastore.warehouse.dir` | /user/hive/warehouse | 默认表路径前缀 |
| `metastore.event.db.listener.timetolive` | 86400 秒 | NOTIFICATION_LOG TTL |
| `hive.stats.autogather` | true | 自动收集 stats |
| `metastore.batch.retrieve.max` | 300 | 批量拉取分区数 |

---

## 八、Eric 点评

HMS 是大数据生态的"老古董"，2009 年 Apache Hive 设计的架构，至今仍是几乎所有 SQL 引擎的元数据中心。它的核心设计哲学是 **"薄"**：

1. **极薄的业务逻辑层**：HMSHandler 主要做校验、HDFS 路径管理、监听器派发，真正的 CRUD 委托给 ObjectStore + JDO
2. **可插拔监听器**：Ranger / Atlas / Apache Sentry 等所有外围系统都通过监听器接入
3. **ThreadLocal 隔离**：用最朴素的方式解决并发，不引入复杂连接池

但它的**老问题**也很顽固：
- DataNucleus JDO 性能远不如 MyBatis/JPA Hibernate
- 没有读写分离，所有读流量都打到主库
- 元数据 schema 演进（schemaTool）操作笨重

这也是为什么近年 **HMS Catalog**（Iceberg/Polaris/Unity Catalog）开始替代它的趋势。理解 HMS 是理解整个数据湖元数据演进的起点。
