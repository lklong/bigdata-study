# 教案 14：Amoro 多 Catalog 统一管理 — 打通 HMS/Iceberg REST/Glue

> **课时**：35分钟 | **难度**：⭐⭐⭐

## 一、课前导入 — 三个集群的元数据孤岛

> 公司有 3 套数据系统：Hive 数仓用 HMS、新湖仓用 Iceberg REST Catalog、AWS 上用 Glue Catalog。运维要分别管理，查表要到三个地方找。Amoro AMS 可以**统一管理所有 Catalog**。

## 二、核心架构

```
┌─────────────────────────────────┐
│        Amoro AMS Dashboard       │  ← 统一管理界面
├─────────────────────────────────┤
│      CatalogManager              │  ← 统一管理接口
│  ┌──────────┬──────────┬──────┐ │
│  │InternalCatalog│ExternalCatalog│ │
│  │(AMS自管理)   │(外部Catalog) │ │
│  └──────────┴──────────┴──────┘ │
├──────────┬────────────┬─────────┤
│ HMS      │ REST       │ Glue    │  ← 底层 Catalog 实现
│ (Hive)   │ (Iceberg)  │ (AWS)   │
└──────────┴────────────┴─────────┘
```

### CatalogType 枚举（源码）

```java
public enum CatalogType {
    AMS,     // Amoro 自管理（InternalCatalog）
    HIVE,    // 连接 Hive Metastore
    HADOOP,  // Hadoop 文件系统 Catalog
    GLUE,    // AWS Glue
    CUSTOM   // 自定义扩展
}
```

## 三、Internal vs External Catalog

| 特性 | InternalCatalog | ExternalCatalog |
|------|----------------|-----------------|
| **表创建** | 通过 AMS API 创建 | 外部引擎创建，AMS 发现 |
| **元数据** | AMS 数据库存储 | 外部 Catalog 存储 |
| **表管理** | 完全管理（CRUD） | 只读发现 + 优化任务 |
| **适用** | 新建的 Iceberg 表 | 已有 Hive/Glue 表 |

### ExternalCatalog 表发现机制

```java
// ExternalCatalog.java
public void syncTable(String database, String tableName, TableFormat format) {
    // 在 AMS 数据库中注册外部表的标识符
    // 后续 AMS 就可以对这张外部表执行优化任务了
    ServerTableIdentifier tableIdentifier = ServerTableIdentifier.of(
        catalogName, database, tableName, format);
    doAs(TableMetaMapper.class, mapper -> mapper.insertTable(tableIdentifier));
}
```

## 四、配置实战

```yaml
# ams 配置文件中注册多个 Catalog
catalogs:
  - name: hive_prod
    type: hive
    properties:
      uri: thrift://hms-prod:9083
      warehouse: hdfs:///warehouse

  - name: iceberg_lake
    type: ams
    properties:
      warehouse: s3://lake-bucket/iceberg

  - name: aws_glue
    type: glue
    properties:
      warehouse: s3://analytics-bucket/
      glue.region: us-east-1
```

## 五、课堂练习

### 思考题：为什么外部 Hive 表也需要 Amoro 管理？

<details>
<summary>参考答案</summary>

虽然 Hive 表的元数据在 HMS 里，但 Amoro 可以为它提供：
1. **统一监控**：在 Dashboard 看到所有表的健康状态
2. **自动优化**：对 Hive 表（ACID 格式）自动执行 Compaction
3. **统一 TTL**：跨 Catalog 统一的数据过期策略
4. **表发现**：自动扫描新建的表并注册管理
</details>

## 六、知识晶体

```
Amoro Catalog = CatalogManager → InternalCatalog(自管理) + ExternalCatalog(外部发现)
类型: AMS / HIVE / HADOOP / GLUE / CUSTOM
External: syncTable() 注册外部表 → AMS 可管理优化
统一价值: 一个 Dashboard 管所有表，跨 Catalog 统一策略
```

*教案作者：Eric | 最后更新：2026-04-30*
