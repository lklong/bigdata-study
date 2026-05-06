# Kyuubi 09 — Batch 模式与 REST API 批处理任务管理源码深度分析

> 源码版本：Apache Kyuubi 1.9.2（本地路径 `/Users/kailongliu/bigdata/txProjects/incubator-kyuubi/`）
> 分析日期：2026-04-27
> 作者：Eric（豹纹） | 大哥的 SRE AI 专家团队

---

## 一、概述

Kyuubi 的 Batch 模式是一套完整的**异步批处理作业管理系统**，通过 REST API 提交、监控、管理批处理作业。本篇从源码层面深度剖析：

1. **KyuubiBatchSession** — 批处理会话的核心模型
2. **BatchesResource** — REST API 端点实现
3. **KyuubiBatchService** — 后台作业提交服务（Batch Submitter）
4. **MetadataStore** — 作业元数据持久化与故障恢复
5. **Batch V1 vs V2** — 两种批处理实现的架构差异

---

## 二、架构全景图

```
                    ┌─────────────────────┐
                    │   REST Client        │  curl / kyuubi-admin / SDK
                    └──────────┬──────────┘
                               │ POST /api/v1/batches
                    ┌──────────▼──────────┐
                    │  BatchesResource     │  JAX-RS REST 端点
                    │  (api/v1/)          │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │ Batch V1       │ Batch V2        │
              │ (同步提交)      │ (异步提交)       │
              ▼                ▼                  │
    ┌──────────────┐  ┌────────────────┐         │
    │KyuubiBatch   │  │MetadataManager │         │
    │Session.open()│  │.insertMetadata │         │
    │              │  │               │          │
    │BatchJob      │  └───────┬───────┘         │
    │Submission    │          │ pickBatch        │
    │Operation     │  ┌───────▼───────┐         │
    └──────┬───────┘  │KyuubiBatch    │         │
           │          │Service         │         │
           │          │(submitter)    │          │
           ▼          └───────┬───────┘          │
    ┌──────────────┐          │                  │
    │ spark-submit │          ▼                  │
    │ / flink run  │  ┌──────────────┐           │
    └──────────────┘  │KyuubiBatch   │           │
                      │Session.open()│           │
                      └──────────────┘           │
                               │                 │
                      ┌────────▼────────┐        │
                      │  MetadataStore   │◄───────┘
                      │  (MySQL/内存)    │  状态持久化
                      └─────────────────┘
```

---

## 三、BatchesResource — REST API 端点

### 3.1 源码定位

**文件**：`kyuubi-server/.../server/api/v1/BatchesResource.scala`

### 3.2 核心 API 端点

| HTTP Method | Path | 功能 | 关键参数 |
|------------|------|------|---------|
| `POST` | `/api/v1/batches` | 提交批处理作业 | batchType, resource, className, args, conf |
| `GET` | `/api/v1/batches` | 查询批处理列表 | batchType, batchUser, batchState, from, size |
| `GET` | `/api/v1/batches/{batchId}` | 查询单个作业状态 | batchId |
| `GET` | `/api/v1/batches/{batchId}/localLog` | 获取作业本地日志 | batchId, from, size |
| `DELETE` | `/api/v1/batches/{batchId}` | 终止/删除作业 | batchId |

### 3.3 提交作业核心流程

```scala
@POST
@Consumes(Array(MediaType.APPLICATION_JSON, MediaType.MULTIPART_FORM_DATA))
def openBatchSession(request: BatchRequest): Batch = {
  // 1. 参数校验
  require(googlebatchType != null, "batchType is required")
  
  // 2. 判断使用 V1 还是 V2
  if (batchV2Enabled(reqConf)) {
    // V2: 只写入 MetadataStore，由 BatchSubmitter 异步提交
    metadataManager.insertMetadata(metadata)
    return buildBatchFromMetadata(metadata)
  }
  
  // V1: 同步创建 BatchSession 并提交
  // 3. 创建 KyuubiBatchSession
  val batchSession = sessionManager.createBatchSession(user, password, ipAddress, conf, ...)
  
  // 4. 打开 Session（触发作业提交）
  sessionManager.openBatchSession(batchSession)
  
  // 5. 返回 Batch 状态
  buildBatch(batchSession)
}
```

### 3.4 Batch V1 vs V2

| 维度 | V1 | V2 |
|------|----|----|
| 提交方式 | REST 请求线程同步提交 | 写入 MetadataStore，后台异步提交 |
| 配置开关 | 默认 | `kyuubi.batch.submitter.enabled=true` + `kyuubi.batch.impl.version=2` |
| 故障恢复 | 有限（Server 重启可恢复） | **完全**（MetadataStore 持久化所有状态） |
| 负载均衡 | 提交请求绑定到接收 Server | 任何 Server 都可以 pick 并提交 |
| 扩展性 | 受单 Server 并发限制 | **水平扩展**（多 Server 竞争 pick） |

---

## 四、KyuubiBatchService — 后台提交服务

### 4.1 源码定位

**文件**：`kyuubi-server/.../server/KyuubiBatchService.scala`

### 4.2 核心架构

```scala
class KyuubiBatchService(server: Serverable, sessionManager: KyuubiSessionManager)
  extends AbstractService {
  
  private lazy val batchExecutor = ThreadUtils.newDaemonFixedThreadPool(
    conf.get(BATCH_SUBMITTER_THREADS),  // 并发提交线程数
    "kyuubi-batch-submitter"
  )
}
```

### 4.3 提交循环（核心逻辑）

```scala
val submitTask: Runnable = () => {
  while (running.get) {
    // 1. 从 MetadataStore 竞争获取一个待提交的 batch
    metadataManager.pickBatchForSubmitting(kyuubiInstance) match {
      case None => 
        Thread.sleep(1000)  // 无待提交任务，休眠 1 秒
      
      case Some(metadata) =>
        // 2. 创建 KyuubiBatchSession
        val batchSession = sessionManager.createBatchSession(
          metadata.username, "anonymous", metadata.ipAddress,
          metadata.requestConf, metadata.engineType, ...)
        
        // 3. 打开 Session（触发 spark-submit / flink run）
        sessionManager.openBatchSession(batchSession)
        
        // 4. 阻塞等待作业提交完成
        var submitted = false
        while (!submitted) {
          submitted = checkBatchSubmitted(batchId, batchSession)
          if (!submitted) Thread.sleep(1000)
        }
    }
  }
}
```

### 4.4 竞争提交机制

`pickBatchForSubmitting()` 通过数据库级别的**乐观锁**（CAS 更新）实现多 Server 间的作业竞争分配：

```
MetadataStore:
  UPDATE batches 
  SET state = 'PENDING', kyuubi_instance = '{myInstance}'
  WHERE state = 'INITIALIZED' 
    AND kyuubi_instance IS NULL
  LIMIT 1
```

**保证**：每个 batch 只被一个 Server pick，避免重复提交。

### 4.5 提交完成判断

```scala
submitted = metadataManager.getBatchSessionMetadata(batchId) match {
  case Some(metadata) if OperationState.isTerminal(metadata.opState) =>
    true  // 作业已终止（成功/失败/取消）
  case Some(metadata) if metadata.opState == OperationState.RUNNING =>
    metadata.appState match {
      case None | Some(ApplicationState.NOT_FOUND) => false  // 还没提交到 RM
      case Some(ApplicationState.PENDING) if batchSession.startupProcessAlive => false  // 等待 AM
      case Some(ApplicationState.UNKNOWN) => false
      case _ => true  // 已提交成功，提交线程可以释放
    }
  case _ => false
}
```

**关键设计**：提交线程不等待作业完成，只等待作业**成功提交到资源管理器**（YARN/K8s）。一旦提交成功，线程释放，继续 pick 下一个 batch。

---

## 五、KyuubiBatchSession — 批处理会话

### 5.1 与 KyuubiSessionImpl 的对比

| 维度 | KyuubiSessionImpl（Interactive） | KyuubiBatchSession（Batch） |
|------|--------------------------------|---------------------------|
| 引擎创建 | `EngineRef.getOrCreate()` → 共享引擎 | `BatchJobSubmissionOperation` → 独立作业 |
| 会话类型 | `SessionType.INTERACTIVE` | `SessionType.BATCH` |
| 操作方式 | Thrift RPC 双向通信 | 异步提交 + 状态轮询 |
| 元数据 | 不持久化 | 持久化到 MetadataStore |
| 故障恢复 | 需要重新连接 | `fromRecovery=true` 恢复 |

### 5.2 open() 流程详解

```
KyuubiBatchSession.open()
│
├─ 1. 元数据处理（三种情况）
│     ├─ V2 新建：更新 requestConf + clusterManager 到 MetadataStore
│     ├─ V1 新建：插入完整 Metadata 记录（含 user, resource, className, args...）
│     └─ 恢复模式：跳过
│
├─ 2. checkSessionAccessPathURIs()
│     ├─ 检查 resource 路径是否可访问
│     └─ 检查 batchType 对应的引擎配置中的路径
│
├─ 3. super.open()
│     └─ 创建 OperationLog 目录
│
└─ 4. runOperation(batchJobSubmissionOp)
      └─ 异步执行 BatchJobSubmissionOperation
          ├─ 创建 SparkProcessBuilder（或其他引擎的 Builder）
          ├─ builder.start() 启动 spark-submit 进程
          └─ 监控进程状态，更新 MetadataStore
```

### 5.3 故障恢复

```scala
class KyuubiBatchSession(
    ...,
    metadata: Option[Metadata] = None,
    fromRecovery: Boolean)          // 是否从故障恢复

// 当 fromRecovery = true 时：
// 1. SessionHandle 从 metadata.identifier 恢复（保持原 batchId）
// 2. 不重新插入 metadata
// 3. 直接从 MetadataStore 获取已有状态继续追踪
```

---

## 六、MetadataStore — 元数据持久化

### 6.1 Metadata 数据模型

```scala
case class Metadata(
  identifier: String,          // batchId (UUID)
  sessionType: SessionType,    // BATCH
  realUser: String,            // 真实用户
  username: String,            // 提交用户
  ipAddress: String,           // 客户端 IP
  kyuubiInstance: String,      // 处理该 batch 的 Kyuubi Server 实例
  state: String,               // INITIALIZED → PENDING → RUNNING → FINISHED/FAILED/CANCELED
  resource: String,            // Jar/Py 路径
  className: String,           // 主类名
  requestName: String,         // 作业名称
  requestConf: Map[String, String],  // 配置
  requestArgs: Seq[String],    // 参数
  createTime: Long,            // 创建时间
  engineType: String,          // 引擎类型
  engineId: String,            // YARN AppId / K8s Pod
  engineUrl: String,           // Spark UI / Flink UI
  engineState: String,         // 引擎应用状态
  engineError: Option[String], // 引擎错误信息
  clusterManager: String,      // yarn / kubernetes / local
  priority: Int                // 作业优先级
)
```

### 6.2 状态流转

```
INITIALIZED  → 刚创建，等待 pick
     │
     ▼ pickBatchForSubmitting()
  PENDING    → 已被某 Server pick，等待提交
     │
     ▼ spark-submit / flink run
  RUNNING    → 作业已提交到资源管理器
     │
     ├──→ FINISHED  (成功)
     ├──→ FAILED    (失败)
     └──→ CANCELED  (用户取消)
```

### 6.3 存储后端

| 后端 | 配置 | 适用场景 |
|------|------|---------|
| 内存 | `kyuubi.metadata.store.jdbc.url=jdbc:derby:memory:kyuubi` | 测试/开发 |
| MySQL | `kyuubi.metadata.store.jdbc.url=jdbc:mysql://...` | **生产环境** |
| 自定义 | 实现 `MetadataStore` 接口 | 特殊需求 |

---

## 七、REST API 使用示例

### 7.1 提交 Spark Batch 作业

```bash
curl -X POST http://kyuubi-server:10099/api/v1/batches \
  -H 'Content-Type: application/json' \
  -d '{
    "batchType": "SPARK",
    "resource": "hdfs:///user/spark/app.jar",
    "className": "com.example.MyApp",
    "name": "my-batch-job",
    "conf": {
      "spark.master": "yarn",
      "spark.submit.deployMode": "cluster",
      "spark.executor.instances": "10",
      "spark.executor.memory": "4g"
    },
    "args": ["arg1", "arg2"]
  }'
```

### 7.2 查询作业状态

```bash
curl http://kyuubi-server:10099/api/v1/batches/{batchId}
```

### 7.3 获取作业日志

```bash
curl "http://kyuubi-server:10099/api/v1/batches/{batchId}/localLog?from=0&size=100"
```

### 7.4 终止作业

```bash
curl -X DELETE http://kyuubi-server:10099/api/v1/batches/{batchId}
```

---

## 八、运维关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `kyuubi.batch.submitter.enabled` | `false` | 是否启用 Batch V2 |
| `kyuubi.batch.impl.version` | `1` | Batch 实现版本 |
| `kyuubi.batch.submitter.threads` | `16` | 后台提交线程数 |
| `kyuubi.batch.session.idle.timeout` | `24h` | Batch Session 空闲超时 |
| `kyuubi.metadata.store.jdbc.url` | Derby 内存 | MetadataStore JDBC URL |
| `kyuubi.metadata.store.jdbc.driver` | 自动检测 | JDBC 驱动类 |
| `kyuubi.batch.internal.rest.client.socket.timeout` | `20000` | 内部 REST 通信超时（ms） |

---

## 九、设计模式总结

### 9.1 生产者-消费者模式

```
REST API (生产者) → MetadataStore (队列) → BatchSubmitter (消费者)
```

Batch V2 将作业提交解耦为写入（生产）和执行（消费），提升了系统的吞吐量和容错性。

### 9.2 乐观锁竞争分配

多个 Kyuubi Server 通过数据库级 CAS 操作竞争 pick batch，实现无中心化的负载均衡。

### 9.3 状态机持久化

所有状态转换都持久化到 MetadataStore，Server 任何时候崩溃都不会丢失作业信息。

---

## 十、与竞品对比

| 特性 | Kyuubi Batch | Livy | Spark REST (standalone) |
|------|-------------|------|-------------------------|
| 引擎类型 | Spark/Flink/Hive/Trino | 仅 Spark | 仅 Spark |
| 异步提交 | ✅ V2 | ✅ | ❌ |
| 故障恢复 | ✅ MetadataStore | 部分 | ❌ |
| 多 Server | ✅ 竞争分配 | ❌ 单实例 | ❌ |
| 日志获取 | ✅ localLog API | ✅ | ❌ |
| 资源上传 | ✅ multipart | ✅ | ❌ |
| HA | ✅ 原生支持 | 需 Zeppelin HA | ❌ |

---

> **认知更新**：Kyuubi Batch V2 的核心思想是将 **「提交」和「执行」解耦**——REST API 只负责写入元数据（毫秒级响应），后台 BatchSubmitter 负责实际的 spark-submit（秒/分钟级）。这种架构使得 Kyuubi 可以在高并发场景下平稳处理大量 batch 提交请求，同时任何 Server 崩溃都不会丢失作业。
