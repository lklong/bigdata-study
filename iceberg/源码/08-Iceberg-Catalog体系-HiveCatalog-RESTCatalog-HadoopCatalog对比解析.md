# Iceberg 源码深度解析：Catalog 体系 — HiveCatalog / RESTCatalog / HadoopCatalog

> 基于 `/Users/kailongliu/bigdata/gitProjects/iceberg/` 真实源码逐行分析
> Eric | 2026-04-27

---

## 一、Catalog 在 Iceberg 中的角色

```
Catalog 是表的"电话簿"：
  给定 namespace + table name → 返回 Table 对象

                   ┌────────────┐
                   │  Catalog   │ ← 接口
                   └─────┬──────┘
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌────────────┐ ┌────────────┐ ┌────────────┐
   │HiveCatalog │ │HadoopCatlog│ │RESTCatalog │
   │(HMS)       │ │(文件系统)   │ │(HTTP API)  │
   └────────────┘ └────────────┘ └────────────┘
```

---

## 二、Catalog 接口

**源码位置**: `api/src/main/java/org/apache/iceberg/catalog/Catalog.java`

```java
public interface Catalog {
    // ========== 表 CRUD ==========
    List<TableIdentifier> listTables(Namespace ns);     // 列表
    Table createTable(TableIdentifier id, Schema schema, PartitionSpec spec, ...); // 创建
    Table loadTable(TableIdentifier id);                // 加载
    boolean dropTable(TableIdentifier id, boolean purge); // 删除
    void renameTable(TableIdentifier from, TableIdentifier to); // 重命名
    boolean tableExists(TableIdentifier id);            // 存在检查

    // ========== 注册外部表 ==========
    Table registerTable(TableIdentifier id, String metadataFileLocation);

    // ========== 事务式操作 ==========
    TableBuilder buildTable(TableIdentifier id, Schema schema); // 返回 Builder
    // Builder 提供: withPartitionSpec/withSortOrder/withLocation/withProperties
    //   .create()           → 创建表
    //   .createTransaction() → 创建事务
    //   .replaceTransaction() → 替换事务

    // ========== 生命周期 ==========
    String name();
    void initialize(String name, Map<String, String> properties);
    void close();
}
```

### TableIdentifier 与 Namespace

```java
// TableIdentifier = Namespace + name
TableIdentifier id = TableIdentifier.of("db", "orders");
// 等价于 TableIdentifier.of(Namespace.of("db"), "orders")
// toString() → "db.orders"

// 多级 Namespace
Namespace ns = Namespace.of("catalog", "db");
TableIdentifier id = TableIdentifier.of(ns, "orders");
// toString() → "catalog.db.orders"
```

---

## 三、三大 Catalog 实现对比

| 维度 | HiveCatalog | HadoopCatalog | RESTCatalog |
|------|-------------|---------------|-------------|
| **元数据存储** | Hive MetaStore (MySQL/Derby) | 文件系统目录结构 | REST API 服务端 |
| **依赖** | HMS Thrift 客户端 | Hadoop FileSystem | HTTP 客户端 |
| **原子性** | HMS 事务 + 锁 | 文件系统 atomic rename | 服务端保证 |
| **renameTable** | 支持 | **不支持** | 支持 |
| **适用场景** | 已有 Hive 集群 | 轻量级/测试 | 多租户/云原生/Amoro |
| **并发安全** | HMS 锁 | LockManager | 服务端乐观并发 |
| **源码位置** | `hive-metastore/` | `core/hadoop/` | `core/rest/` |

---

## 四、HiveCatalog — HMS 集成

**源码位置**: `hive-metastore/src/main/java/org/apache/iceberg/hive/HiveCatalog.java`

```java
public class HiveCatalog extends BaseMetastoreViewCatalog
    implements SupportsNamespaces, Configurable {

    private String name;
    private Configuration conf;
    private FileIO fileIO;
    private ClientPool<IMetaStoreClient, TException> clients; // HMS 连接池

    // 初始化
    @Override
    public void initialize(String catalogName, Map<String, String> properties) {
        this.name = catalogName;
        this.conf = new Configuration();
        // 配置 HMS URI
        String metastoreUri = properties.get(CatalogProperties.URI);
        conf.set("hive.metastore.uris", metastoreUri);
        // 创建 HMS 客户端池
        this.clients = new CachedClientPool(conf, properties);
        this.fileIO = CatalogUtil.loadFileIO(properties, conf);
    }

    // loadTable — 从 HMS 获取表位置 → 加载 metadata.json
    @Override
    public Table loadTable(TableIdentifier id) {
        // 1. 从 HMS 获取 Hive Table 对象
        org.apache.hadoop.hive.metastore.api.Table hiveTable =
            clients.run(client -> client.getTable(db, tbl));
        // 2. 从表属性中提取 metadata_location
        String metadataLocation = hiveTable.getParameters().get("metadata_location");
        // 3. 构建 TableOperations
        return new BaseTable(new HiveTableOperations(conf, clients, fileIO, id, metadataLocation));
    }
}
```

**HiveCatalog 的元数据流转**:

```
HMS (MySQL) 存储:
  TBLS: table_name, location, ...
  TABLE_PARAMS: key="metadata_location", value="/warehouse/db/t/metadata/v3.metadata.json"

loadTable() 流程:
  HMS.getTable() → 拿到 metadata_location
    → FileIO.readFile(metadata_location)
    → 解析 metadata.json → TableMetadata
    → 构建 Table 对象
```

---

## 五、HadoopCatalog — 文件系统 Catalog

**源码位置**: `core/src/main/java/org/apache/iceberg/hadoop/HadoopCatalog.java`

```java
public class HadoopCatalog extends BaseMetastoreCatalog
    implements SupportsNamespaces, Configurable {

    private String warehouseLocation;  // 仓库根目录
    private FileSystem fs;
    private FileIO fileIO;
    private LockManager lockManager;

    // 目录结构即 Catalog 结构
    // warehouse/db/table/metadata/*.metadata.json
    // warehouse/db/table/data/*.parquet

    // loadTable — 直接从文件系统读取 metadata
    @Override
    protected TableOperations newTableOps(TableIdentifier id) {
        String location = SLASH.join(warehouseLocation, id.namespace().toString(), id.name());
        return new HadoopTableOperations(
            new Path(location), fileIO, conf, lockManager);
    }
    
    // listTables — 扫描目录
    @Override
    public List<TableIdentifier> listTables(Namespace ns) {
        Path nsPath = new Path(warehouseLocation, ns.toString());
        // 列出子目录，检查哪些包含 metadata/*.metadata.json
        FileStatus[] files = fs.listStatus(nsPath, TABLE_FILTER);
        // 有 metadata.json 的目录就是一张表
    }

    // 不支持 rename！
    @Override
    public void renameTable(TableIdentifier from, TableIdentifier to) {
        throw new UnsupportedOperationException("HadoopCatalog does not support rename");
    }
}
```

---

## 六、RESTCatalog — HTTP API Catalog

**源码位置**: `core/src/main/java/org/apache/iceberg/rest/RESTCatalog.java`

```java
public class RESTCatalog implements Catalog, ViewCatalog,
    SupportsNamespaces, Configurable<Object>, Closeable {

    private RESTSessionCatalog sessionCatalog;  // 委托对象

    @Override
    public void initialize(String name, Map<String, String> properties) {
        this.sessionCatalog = new RESTSessionCatalog();
        sessionCatalog.initialize(name, properties);
        // 连接到 REST 服务端（如 Amoro AMS）
        // URI: http://ams-host:1630/api/iceberg/rest
    }

    // 所有操作都委托给 sessionCatalog（HTTP 请求）
    @Override
    public Table loadTable(TableIdentifier id) {
        return sessionCatalog.loadTable(context(), id);
        // → GET /v1/namespaces/{ns}/tables/{tbl}
    }

    @Override
    public Table createTable(TableIdentifier id, Schema schema, ...) {
        return sessionCatalog.buildTable(context(), id, schema)...create();
        // → POST /v1/namespaces/{ns}/tables
    }
}
```

**REST Catalog 协议端点**:

```
GET    /v1/config                          → 获取 Catalog 配置
GET    /v1/namespaces                      → 列出 Namespace
POST   /v1/namespaces                      → 创建 Namespace
GET    /v1/namespaces/{ns}                 → 获取 Namespace
DELETE /v1/namespaces/{ns}                 → 删除 Namespace
GET    /v1/namespaces/{ns}/tables          → 列出表
POST   /v1/namespaces/{ns}/tables          → 创建表
GET    /v1/namespaces/{ns}/tables/{tbl}    → 加载表
POST   /v1/namespaces/{ns}/tables/{tbl}    → 更新表（commit）
DELETE /v1/namespaces/{ns}/tables/{tbl}    → 删除表
HEAD   /v1/namespaces/{ns}/tables/{tbl}    → 检查表存在
POST   /v1/namespaces/{ns}/tables/{tbl}/metrics → 上报指标
```

---

## 七、Amoro 如何利用 RESTCatalog

```
Amoro AMS 内置了 Iceberg REST Catalog 服务端:

  RestCatalogService (Javalin HTTP Server)
    → 实现 Iceberg REST API 全部端点
    → 后端委托给 InternalCatalogImpl
    → 表元数据持久化到 AMS 数据库

Spark/Flink 客户端配置:
  spark.sql.catalog.amoro = org.apache.iceberg.spark.SparkCatalog
  spark.sql.catalog.amoro.type = rest
  spark.sql.catalog.amoro.uri = http://ams-host:1630/api/iceberg/rest

客户端使用标准 RESTCatalog → HTTP → AMS RestCatalogService
  完全兼容 Iceberg 标准协议！
```

---

## 八、选型指南

```
选择 HiveCatalog 当:
  ✅ 已有 Hive MetaStore 基础设施
  ✅ 需要 Hive/Presto/Trino 等多引擎共享表
  ✅ 需要 renameTable 支持

选择 HadoopCatalog 当:
  ✅ 轻量级测试/POC
  ✅ 不想引入额外依赖
  ⚠️ 不适合生产（无 rename、并发控制弱）

选择 RESTCatalog 当:
  ✅ 云原生部署
  ✅ 多租户隔离
  ✅ 使用 Amoro/Gravitino/Unity Catalog 等管理平台
  ✅ 需要细粒度权限控制
```
