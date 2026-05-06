# 教案 16：Iceberg REST Catalog 协议 — 为什么它是未来标准？

> **课时**：40分钟 | **难度**：⭐⭐⭐

## 一、课前导入 — Catalog 碎片化之痛

> 你的公司有 3 个计算引擎（Spark/Flink/Trino），每个都需要连 Hive Metastore。HMS 是 Thrift 协议，Go/Rust 写的新引擎对接很痛苦。而且 HMS 的语义是 Hive 专属的，不完全匹配 Iceberg 需求。
>
> REST Catalog 用**标准 HTTP + JSON**，任何语言都能对接，且语义完全为 Iceberg 设计。

## 二、核心架构

```
┌──────────────────────────┐
│  Spark / Flink / Trino    │  ← 多引擎
├──────────────────────────┤
│  RESTCatalog (客户端)     │  ← HTTP Client
│  - loadTable → GET /v1/namespaces/{ns}/tables/{t}
│  - commit   → POST /v1/namespaces/{ns}/tables/{t}
├──────────────────────────┤
│      HTTP / HTTPS         │  ← 标准协议，跨语言
├──────────────────────────┤
│  REST Catalog Server      │  ← 服务端（可独立部署）
│  (Amoro AMS / Polaris /   │
│   Tabular / Gravitino)    │
├──────────────────────────┤
│  底层存储: HMS / JDBC /   │  ← 元数据实际存储
│  DynamoDB / PostgreSQL    │
└──────────────────────────┘
```

## 三、REST vs HMS vs Hadoop Catalog 对比

| 维度 | REST Catalog | Hive Catalog | Hadoop Catalog |
|------|-------------|-------------|----------------|
| **协议** | HTTP/JSON | Thrift | 直接访问文件系统 |
| **多引擎** | 优秀（任何语言） | 一般（需 Thrift 客户端） | 差（Java only） |
| **Auth** | OAuth2/Token | Kerberos | 文件系统权限 |
| **原子性** | 服务端保证 | HMS 锁（有问题） | 文件 rename（最弱） |
| **多租户** | 原生支持 | 需额外设计 | 不支持 |
| **部署** | 需 Server | 需 HMS | 零依赖 |
| **未来趋势** | ★★★★★ | ★★★ | ★★ |

## 四、源码核心（RESTCatalog.java）

```java
// RESTCatalog 本质是一个代理类
public class RESTCatalog implements Catalog, ViewCatalog, SupportsNamespaces {
    private RESTSessionCatalog sessionCatalog;  // 实际工作者
    
    @Override
    public Table loadTable(TableIdentifier ident) {
        // 委托给 sessionCatalog → 通过 HTTP GET 获取表元数据
        return sessionCatalog.asCatalog(context).loadTable(ident);
    }
}

// RESTTableOperations 负责 commit
// commit 时发送 POST 请求，包含 UpdateRequirement + MetadataUpdate
// 服务端验证 Requirements（OCC 条件），成功则更新元数据
```

## 五、Amoro 作为 REST Catalog Server

Amoro AMS **内置了 REST Catalog Server**，路径前缀 `/api/iceberg/rest/`：
- 注册 Iceberg 表时自动提供 REST API
- Spark/Flink/Trino 通过 REST 协议访问，无需连接 HMS
- Amoro 同时管理表的优化任务 — 一石二鸟

## 六、课堂练习

### 思考题：REST Catalog 的安全性

> REST Catalog 支持 OAuth2 认证。相比 Kerberos，优缺点是什么？

<details>
<summary>参考答案</summary>

优点：
- 跨语言兼容（任何 HTTP 客户端都能用 Bearer Token）
- 更细粒度的权限控制（Scope/Role 级别）
- 容器/K8s 环境友好（不需要 keytab 文件）

缺点：
- 不如 Kerberos 适合内部大型 Hadoop 集群的统一认证
- Token 过期管理需要额外设计
- 与现有 Kerberos 基础设施不兼容

最佳实践：内部集群用 Kerberos + Hive Catalog，对外服务/多云用 REST + OAuth2
</details>

## 七、知识晶体

```
REST Catalog = HTTP + JSON + OAuth2 + 标准化语义
优势: 跨语言/多租户/原子性由服务端保证
实现: RESTCatalog(客户端) → HTTP → Server(Amoro/Polaris/Tabular)
趋势: Iceberg 社区全力推进，Spark 4.0 默认支持
```

*教案作者：Eric | 最后更新：2026-04-30*
