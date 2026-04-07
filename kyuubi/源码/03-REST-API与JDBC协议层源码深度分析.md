# Kyuubi REST API 与 JDBC 协议层 — L4 源码深度分析

> **源码版本**：Apache Kyuubi master 分支（2026-04, commit ba854d3c）
> **段位目标**：L4 创造者/科学家
> **方法论**：源码精通九大法则 × 费曼三层输出
> **本文重点**：多协议前端架构、Thrift Binary/HTTP、REST API、MySQL Protocol、JDBC 连接全链路

---

# 模块一：多协议前端架构

## 1.1 白话版（费曼 L1）

> 想象 Kyuubi 是一家**多语言客服中心**。同一个业务（SQL 网关），但客户可以用不同的"语言"（协议）来沟通：
>
> - **Thrift Binary**（默认，端口 10009）：最标准的方式，像打电话。用 beeline/JDBC Driver 连接。
> - **Thrift HTTP**（端口 10010）：通过 HTTP 隧道传输 Thrift，像发传真。防火墙友好。
> - **REST API**（端口 10099）：用 HTTP JSON，像发微信。任何 curl/浏览器都能用。
> - **MySQL Protocol**（端口 3309）：伪装成 MySQL 数据库。用 MySQL 客户端直接连。
> - **Trino Protocol**：伪装成 Trino 集群。用 Trino CLI 直接连。
>
> 不管客户用什么"语言"，最终都翻译成统一的内部指令：openSession / executeStatement / fetchResults。

## 1.2 架构版（费曼 L2）

### 1.2.1 协议架构总览

```
客户端                              Kyuubi Server
┌──────────┐                    ┌──────────────────────────────┐
│ beeline  │──Thrift Binary───▶│ KyuubiTBinaryFrontendService │─┐
│ JDBC     │                    │ (端口 10009)                  │ │
└──────────┘                    └──────────────────────────────┘ │
┌──────────┐                    ┌──────────────────────────────┐ │
│ HTTP     │──Thrift HTTP─────▶│ KyuubiTHttpFrontendService   │─┤
│ Client   │                    │ (端口 10010)                  │ │
└──────────┘                    └──────────────────────────────┘ │
┌──────────┐                    ┌──────────────────────────────┐ │  BackendService
│ curl     │──REST JSON───────▶│ KyuubiRestFrontendService    │─┤  (统一入口)
│ Postman  │                    │ (端口 10099, Jersey)          │ │     │
└──────────┘                    └──────────────────────────────┘ │     ▼
┌──────────┐                    ┌──────────────────────────────┐ │  SessionManager
│ mysql    │──MySQL Protocol──▶│ KyuubiMySQLFrontendService   │─┤     │
│ CLI      │                    │ (端口 3309, Netty)            │ │     ▼
└──────────┘                    └──────────────────────────────┘ │  EngineRef
┌──────────┐                    ┌──────────────────────────────┐ │
│ trino    │──Trino Protocol──▶│ KyuubiTrinoFrontendService   │─┘
│ CLI      │                    │ (端口 7333)                   │
└──────────┘                    └──────────────────────────────┘
```

### 1.2.2 Thrift Binary Frontend

**源码位置**：`kyuubi-server/.../KyuubiTBinaryFrontendService.scala`

```
继承链: AbstractFrontendService → TBinaryFrontendService → KyuubiTBinaryFrontendService

实现 TCLIService.Iface 接口 (Hive Thrift 协议):
  OpenSession / CloseSession
  ExecuteStatement / GetOperationStatus
  FetchResults / GetResultSetMetadata
  GetTypeInfo / GetCatalogs / GetSchemas / GetTables / GetColumns
```

**请求处理链路**：
```
beeline → JDBC Driver → TCP 连接到 10009
  → SASL 认证 (Kerberos/LDAP/NONE)
  → Thrift 反序列化
  → TBinaryFrontendService.OpenSession()
    → backendService.openSession()
      → KyuubiSessionManager.openSession()
```

**线程模型**：
```
ThreadPool (kyuubi.frontend.thrift.max.worker.threads = 999)
  ├── Worker-1 → 处理客户端 A 的请求
  ├── Worker-2 → 处理客户端 B 的请求
  └── ...
```

### 1.2.3 REST Frontend

**源码位置**：`kyuubi-server/.../KyuubiRestFrontendService.scala`

基于 **Jersey (JAX-RS)** + **Jetty** 实现。

```
REST 端点:
  /api/v1/sessions     → SessionsResource.scala
  /api/v1/batches      → BatchesResource.scala
  /api/v1/operations   → OperationsResource.scala
  /api/v1/admin        → AdminResource.scala
```

**JDBC 连接 URL 示例**：

```
# Thrift Binary (标准)
jdbc:hive2://host:10009/default

# Thrift Binary + ZK 服务发现
jdbc:hive2://zk1:2181,zk2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=kyuubi

# Thrift HTTP
jdbc:hive2://host:10010/default;transportMode=http;httpPath=cliservice

# REST (通过 REST API，非 JDBC)
curl -X POST http://host:10099/api/v1/sessions
```

### 1.2.4 MySQL Protocol Frontend

**源码位置**：`kyuubi-server/.../KyuubiMySQLFrontendService.scala`

基于 **Netty** 实现 MySQL 协议。

```
mysql -h kyuubi-host -P 3309 -u alice -p
mysql> SELECT * FROM db.table;
```

**协议适配**：将 MySQL 协议翻译为 Kyuubi 内部操作：
- `COM_QUERY` → `executeStatement()`
- `COM_QUIT` → `closeSession()`
- `COM_INIT_DB` → `executeStatement("USE database")`

### 1.2.5 JDBC 连接全链路

```
1. JDBC Driver 解析 URL
   jdbc:hive2://zk1:2181/;serviceDiscoveryMode=zooKeeper
   
2. 服务发现
   HiveConnection → ZK getChildren("/kyuubi-server")
   → 随机选择一个 Server 实例 → 获取 host:port

3. TCP 连接 + SASL 认证
   TSocket.open() → SASL handshake (Kerberos/LDAP/NONE)

4. OpenSession RPC
   TOpenSessionReq { user, password, configuration }
   → TOpenSessionResp { sessionHandle, serverProtocolVersion }

5. ExecuteStatement RPC
   TExecuteStatementReq { sessionHandle, statement, runAsync }
   → TExecuteStatementResp { operationHandle }

6. FetchResults RPC (分页)
   TFetchResultsReq { operationHandle, orientation, maxRows }
   → TFetchResultsResp { results: TRowSet }

7. CloseSession RPC
   TCloseSessionReq { sessionHandle }
```

---

## 1.3 论文版（费曼 L3）

### 1.3.1 多协议架构的设计模式

Kyuubi 的多协议支持采用**适配器模式 (Adapter Pattern)**：

```
                    ┌─────────────────────┐
                    │ BackendService      │ ← 统一接口
                    │ (openSession,       │
                    │  executeStatement)  │
                    └──────────▲──────────┘
                               │
         ┌────────────────┬────┴───────────┬─────────────────┐
         │                │                │                 │
   ThriftAdapter    RESTAdapter     MySQLAdapter     TrinoAdapter
   (TBinaryFrontend) (RestFrontend) (MySQLFrontend)  (TrinoFrontend)
```

每个 Adapter 负责将特定协议的请求翻译为 BackendService 的统一调用。新增协议只需实现新的 Adapter。

### 1.3.2 协议开销对比

| 协议 | 序列化开销 | 连接开销 | 适用场景 |
|------|-----------|---------|---------|
| Thrift Binary | 低（二进制） | TCP | 标准 JDBC 客户端 |
| Thrift HTTP | 中（二进制+HTTP） | HTTP | 防火墙/代理环境 |
| REST | 高（JSON 文本） | HTTP | 脚本/浏览器/监控 |
| MySQL | 中（MySQL 协议） | TCP | MySQL 客户端兼容 |

---

## 1.4 对抗性分析

### 1.4.1 REST API 认证绕过

**风险**：REST Frontend 默认不独立认证，依赖全局 `kyuubi.authentication` 配置。如果未配置认证：

```bash
curl -X POST http://kyuubi:10099/api/v1/sessions \
  -d '{"user":"admin","configs":{}}'
# → 成功创建 admin 的 Session！
```

**缓解**：生产环境必须配置认证。REST 前端也走相同的认证链。

### 1.4.2 MySQL Protocol 的 SQL 注入

MySQL 协议的 `COM_QUERY` 直接传递 SQL 字符串。如果 Kyuubi 不做额外校验，恶意 SQL 会直接到达 Engine。

**防护**：Kyuubi 本身不做 SQL 过滤（透传给 Engine），但可以通过：
1. Ranger 授权限制表/列访问
2. WatchDog 规则限制扫描行数/分区数

### 1.4.3 大结果集通过 Thrift 传输

**场景**：`SELECT * FROM huge_table`（1000 万行），通过 Thrift Binary 传输。

**问题**：Thrift `TRowSet` 会序列化整个结果集到内存中。如果结果集超过 Driver 内存 → OOM。

**防护链**：
1. Engine 端 `OPERATION_RESULT_MAX_ROWS` 限制
2. FetchResults 分页（每次 `maxRows` 行）
3. Server 端 `SERVER_LIMIT_CLIENT_FETCH_MAX_ROWS`

---

## 1.5 知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | 如何让一个 SQL 网关同时支持 5 种协议，且保持统一的会话和执行模型？ |
| **核心源码** | `TBinaryFrontendService`, `RestFrontendService`, `MySQLFrontendService` |
| **调用链** | `Client → 协议层(Thrift/REST/MySQL) → BackendService → SessionManager → EngineRef` |
| **设计意图** | 适配器模式统一多协议，新增协议只需实现 FrontendService |
| **关键参数** | `FRONTEND_PROTOCOLS`, `thrift.binary.bind.port=10009`, `rest.bind.port=10099` |
| **踩坑记录** | ① REST 无认证 = 安全灾难 ② MySQL 协议不支持所有 Hive 语法 ③ Thrift HTTP 性能低于 Binary |
| **认知更新** | 从"只有 beeline 能连"→ "5 种协议 × 适配器模式 × 统一后端的完整多协议架构" |

---

## 源码文件索引

| 文件 | 核心职责 |
|------|----------|
| `KyuubiTBinaryFrontendService.scala` | Thrift Binary 前端 |
| `KyuubiTHttpFrontendService.scala` | Thrift HTTP 前端 |
| `KyuubiRestFrontendService.scala` | REST API 前端 (Jersey) |
| `KyuubiMySQLFrontendService.scala` | MySQL 协议前端 (Netty) |
| `KyuubiTrinoFrontendService.scala` | Trino 协议前端 |
| `SessionsResource.scala` | REST /sessions 端点 |
| `BatchesResource.scala` | REST /batches 端点 |
| `AdminResource.scala` | REST /admin 端点 |

---

> 本文档遵循"源码精通方法论"L4 标准。
> 源码版本：Apache Kyuubi master 分支 (2026-04, commit ba854d3c)
