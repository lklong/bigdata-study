# Ranger RangerPolicyEngineImpl 权限决策源码分析

> **源码路径**：`txProjects/ranger/agents-common/src/main/java/org/apache/ranger/plugin/policyengine/RangerPolicyEngineImpl.java`（35.53 KB）
> **铁律遵守**：所有方法名、行号引用均来自上述真实源码

---

## 一、定位

Ranger 是 **Apache Hadoop 生态的权限中枢**（与 Apache Sentry 竞争，已淘汰 Sentry）。
`RangerPolicyEngineImpl` 是所有 Plugin（HDFS/Hive/HBase/Kafka/Trino）权限决策的**核心实现**。

**关键职责**：
- 接收 `RangerAccessRequest`（user/resource/action/context）
- 匹配策略（Allow/Deny + 行级过滤 + 列级脱敏）
- 产生 `RangerAccessResult`
- 异步 Audit 记录

---

## 二、类声明（RangerPolicyEngineImpl.java:55-60）

```java
55: public class RangerPolicyEngineImpl implements RangerPolicyEngine {
56: 	private static final Log LOG = LogFactory.getLog(RangerPolicyEngineImpl.class);
57:
58: 	private static final Log PERF_POLICYENGINE_REQUEST_LOG  = RangerPerfTracer.getPerfLogger("policyengine.request");
59: 	private static final Log PERF_POLICYENGINE_AUDIT_LOG    = RangerPerfTracer.getPerfLogger("policyengine.audit");
60: 	private static final Log PERF_POLICYENGINE_GET_ACLS_LOG = RangerPerfTracer.getPerfLogger("policyengine.getResourceACLs");
```

**三大性能 Logger**：
- `policyengine.request` — 单次鉴权耗时
- `policyengine.audit` — Audit 写入耗时
- `policyengine.getResourceACLs` — ACL 列表查询耗时

生产开启这些 logger 可以精确定位鉴权瓶颈。

---

## 三、核心字段（RangerPolicyEngineImpl.java:62-65）

```java
62: 	private final PolicyEngine                 policyEngine;           // ⭐ 策略树容器
63: 	private final RangerAccessRequestProcessor requestProcessor;       // 请求预处理
64: 	private final ServiceConfig                serviceConfig;          // 服务定义（HDFS/Hive/...）
65: 	private Map<String,List<String>>           user2userGroupMap;      // 用户→组映射
```

**设计观察**：
- `PolicyEngine` 是内存中的策略索引（按 resource 前缀树 + tagged policy）
- `requestProcessor` 做 resource 规范化（如 HDFS 路径去尾斜杠）
- `user2userGroupMap` 避免每次鉴权查 LDAP

---

## 四、evaluatePolicies 核心鉴权入口（RangerPolicyEngineImpl.java:123-164）⭐⭐

```java
123: public RangerAccessResult evaluatePolicies(RangerAccessRequest request, int policyType, RangerAccessResultProcessor resultProcessor) {
124: 	if (LOG.isDebugEnabled()) {
125: 		LOG.debug("==> RangerPolicyEngineImpl.evaluatePolicies(" + request + ", policyType=" + policyType + ")");
126: 	}
127:
128: 	RangerPerfTracer perf = null;
129:
130: 	if(RangerPerfTracer.isPerfTraceEnabled(PERF_POLICYENGINE_REQUEST_LOG)) {
131: 		String requestHashCode = Integer.toHexString(System.identityHashCode(request)) + "_" + policyType;
132:
133: 		perf = RangerPerfTracer.getPerfTracer(PERF_POLICYENGINE_REQUEST_LOG, "RangerPolicyEngine.evaluatePolicies(requestHashCode=" + requestHashCode + ")");
134:
135: 		LOG.info("RangerPolicyEngineImpl.evaluatePolicies(" + requestHashCode + ", " + request + ")");
136: 	}
137:
138: 	requestProcessor.preProcess(request);                              // ⭐ 规范化请求
139: 	useRangerGroup(request);                                            // ⭐ 填充用户组
140:
141: 	RangerAccessResult ret = zoneAwareAccessEvaluationWithNoAudit(request, policyType);   // ⭐ 真正决策
142:
143: 	if (resultProcessor != null) {
144: 		RangerPerfTracer perfAuditTracer = null;
145:
146: 		if(RangerPerfTracer.isPerfTraceEnabled(PERF_POLICYENGINE_AUDIT_LOG)) {
147: 			String requestHashCode = Integer.toHexString(System.identityHashCode(request)) + "_" + policyType;
148:
149: 			perfAuditTracer = RangerPerfTracer.getPerfTracer(PERF_POLICYENGINE_AUDIT_LOG, "RangerPolicyEngine.processAudit(requestHashCode=" + requestHashCode + ")");
150: 		}
151:
152: 		resultProcessor.processResult(ret);                            // ⭐ 异步 Audit
153:
154: 		RangerPerfTracer.log(perfAuditTracer);
155: 	}
156:
157: 	RangerPerfTracer.log(perf);
158:
159: 	if (LOG.isDebugEnabled()) {
160: 		LOG.debug("<== RangerPolicyEngineImpl.evaluatePolicies(" + request + ", policyType=" + policyType + "): " + ret);
161: 	}
162:
163: 	return ret;
164: }
```

### 4.1 鉴权三步

| 步骤 | 行号 | 说明 |
|------|------|------|
| **preProcess** | 138 | 规范化 request（补全 group、转小写等） |
| **zoneAwareAccessEvaluationWithNoAudit** | 141 | 核心决策（security zone 路由 + policy 匹配） |
| **processResult** | 152 | 异步 Audit（Solr/Kafka/DB） |

### 4.2 policyType 参数语义

Ranger 四种策略类型：
- `POLICY_TYPE_ACCESS` = 0 — 访问控制（Allow/Deny）
- `POLICY_TYPE_DATAMASK` = 1 — 列级数据脱敏
- `POLICY_TYPE_ROWFILTER` = 2 — 行级过滤
- `POLICY_TYPE_AUDIT` = 3 — Audit 规则

---

## 五、批量鉴权（RangerPolicyEngineImpl.java:167-194）

```java
167: public Collection<RangerAccessResult> evaluatePolicies(Collection<RangerAccessRequest> requests, int policyType, RangerAccessResultProcessor resultProcessor) {
   ...
172: 	Collection<RangerAccessResult> ret = new ArrayList<>();
173:
174: 	if (requests != null) {
175: 		for (RangerAccessRequest request : requests) {
176: 			requestProcessor.preProcess(request);
177: 			useRangerGroup(request);
178:
179: 			RangerAccessResult result = zoneAwareAccessEvaluationWithNoAudit(request, policyType);
180:
181: 			ret.add(result);
182: 		}
183: 	}
184:
185: 	if (resultProcessor != null) {
186: 		resultProcessor.processResults(ret);                         // ⭐ 批量 audit
187: 	}
   ...
194: }
```

**批量优化**：
- 遍历内部循环调用核心方法（无并行）
- **Audit 批量处理**（`processResults` 而非 `processResult`）— 减少写 Solr 的 IO

**为何不并行**：策略树只读，但 audit 写入按顺序更容易聚合。

---

## 六、getResourceACLs 资源 ACL 查询（RangerPolicyEngineImpl.java:197+）

```java
196: @Override
197: public RangerResourceACLs getResourceACLs(RangerAccessRequest request) {
   ...
201: 	RangerResourceACLs ret  = new RangerResourceACLs();
202: 	RangerPerfTracer   perf = null;
   ...
209: 	requestProcessor.preProcess(request);
210: 	useRangerGroup(request);
211:
212: 	String zoneName = policyEngine.getUniquelyMatchedZoneName(request.getResource().getAsMap());
```

**用途**：
- 给 SQL 引擎（Hive/Trino）用
- 返回 "user X 对 resource Y 有哪些权限"（不是单次鉴权，是完整列表）
- 用于 `SHOW GRANT ON TABLE t`、`list_privileges` 等元数据 API

---

## 七、useRangerGroup 用户组填充（RangerPolicyEngineImpl.java:79-80）

```java
79: private void useRangerGroup(RangerAccessRequest request) {
80:     String user = request.getUser();
```

**填充逻辑**（完整代码在原文件中）：
- 从 `user2userGroupMap` 查用户所属组
- 合并到 request 的 `userGroups` 字段
- 后续策略匹配时，用户组参与匹配

**性能**：Map 查找 O(1)，无任何 IO。每次鉴权 **必然会调用此方法**。

---

## 八、核心方法位置速查

| 方法 | 行号 | 作用 |
|------|------|------|
| `evaluatePolicies(单个)` | 123 | 核心鉴权（Plugin 最常调用） |
| `evaluatePolicies(批量)` | 167 | 批量鉴权 |
| `getResourceACLs` | 197 | 查询完整 ACL 列表 |
| `useRangerGroup` | 79 | 填充用户组 |
| `setUser2GroupMap` | 73 | 外部注入用户-组 |

---

## 九、整体鉴权链路

```
Hive/Trino/HDFS 代码
        │
        ▼
 RangerXxxAuthorizer (组件特定封装)
        │
        ▼ 构造 RangerAccessRequest
        │   (user, userGroups, resource, accessType, clientIp, ...)
        │
        ▼
 RangerPolicyEngineImpl.evaluatePolicies()   [line 123]
        │
        ├─ requestProcessor.preProcess()              ← 规范化
        ├─ useRangerGroup()                           ← 填充组  [line 79]
        ├─ zoneAwareAccessEvaluationWithNoAudit()    ← 核心决策
        │     │
        │     ▼
        │  1. 路由到 Security Zone
        │  2. 在 Zone 内匹配 Policy（前缀树/Tag-based）
        │  3. 先 Deny 后 Allow（Deny 优先）
        │  4. 条件策略（ACCESS_CONDITIONAL）
        │  5. 产生 RangerAccessResult
        │
        └─ resultProcessor.processResult()           ← 异步 Audit
              │
              ▼
           Audit Provider
              ├─ Solr（近实时检索）
              ├─ Kafka（下游订阅）
              ├─ HDFS（长期归档）
              └─ DB（关系查询）
```

---

## 十、策略评估哲学

### 10.1 Deny 优先原则

在 `zoneAwareAccessEvaluationWithNoAudit` 内部：
1. 先检查所有 DENY 策略 — 任何命中 → 拒绝
2. 再检查 ALLOW 策略 — 任何命中 → 通过
3. 都没命中 → 根据默认策略（通常 deny）

### 10.2 Security Zone

- 一个 Ranger Service 下可以配置多个 Zone
- 按资源前缀分区（如 `/secure/*` 归 zone-finance）
- 不同 Zone 策略互不干扰

### 10.3 Tag-Based Policy

- 资源可以打 tag（通过 Apache Atlas 同步）
- 策略可以针对 tag（如 PII）
- 覆盖面更广（一次打标，多表生效）

### 10.4 ACCESS_CONDITIONAL

```java
53: import static org.apache.ranger.plugin.policyevaluator.RangerPolicyEvaluator.ACCESS_CONDITIONAL;
```

条件策略：如"工作日 9-18 点才能访问"、"来自内网 IP 才能访问"。
用 MVEL 表达式实现。

---

## 十一、生产关注点

### 11.1 性能瓶颈

Ranger 单次鉴权耗时典型值：
- **内存匹配**：< 1ms
- **首次匹配**（policy tree 构建）：10-100ms
- **Audit 写入**（异步不阻塞）：不影响鉴权

监控指标：
- `policyengine.request` 日志 > 10ms 的请求数
- `policyengine.audit` 堆积情况

### 11.2 策略刷新

- Plugin 默认每 30s polling Admin（`ranger.plugin.<service>.policy.pollIntervalMs`）
- 拉取变更后**原子替换**整个 PolicyEngine（无停机）
- 大集群（1000+ 策略）时刷新耗时 1-5s

### 11.3 Audit 写入策略

- **Solr**：查询方便，但写入压力大时会失败
- **Kafka**：吞吐最好，推荐生产使用
- **HDFS spool**：断连时兜底（buffer 到本地磁盘）

### 11.4 常见坑

1. **User-Group 映射不一致**：Ranger 从 UnixUserGroup 或 LDAP 取组，与 Hadoop `hadoop.security.group.mapping` 必须一致
2. **Zone 匹配优先级**：越具体的 zone 优先级越高
3. **Deny 不会被 Allow 覆盖**：即使同一用户同一资源的 Allow 策略存在

---

## 十二、关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ranger.plugin.hdfs.policy.pollIntervalMs` | 30000 | 策略刷新周期 |
| `xasecure.audit.destination.solr` | true | 启用 Solr Audit |
| `xasecure.audit.destination.kafka` | false | 启用 Kafka Audit |
| `ranger.plugin.<svc>.policy.cache.dir` | /etc/ranger/... | Plugin 本地缓存目录 |

---

## 十三、Eric 点评

Ranger 是**大数据权限管理的事实标准**，战胜了 Apache Sentry。它的核心设计哲学：

### 13.1 中心化策略 + 本地 Enforcer

- 所有策略在 Admin（Web UI + DB）
- Plugin 定期拉取，本地评估
- **零网络延迟**的鉴权（内存决策）
- 代价：策略变更有 30s 延迟

### 13.2 单点 API 覆盖所有组件

`evaluatePolicies(request, policyType, processor)` 一个方法覆盖：
- HDFS 文件系统权限
- Hive 表/列/行级权限
- HBase CF/CQ 权限
- Kafka Topic 权限
- Trino 连接/表/行级权限
- YARN 队列权限

**统一语义** 是 Ranger 最大价值。

### 13.3 与 RBAC / ABAC 的融合

Ranger 同时支持：
- RBAC（通过 Roles）
- ABAC（通过 Tag + 条件表达式）
- Zone 级隔离

### 13.4 痛点与未来

**痛点**：
- 策略刷新仍是 polling，不是 push（心跳延迟）
- Audit 写入 Solr 性能瓶颈（大集群建议 Kafka + 流处理）
- Admin 单点（HA 靠 DB + Load Balancer）

**未来方向**：
- **OpenPolicyAgent (OPA) 集成** — Kubernetes 生态迁移
- **Apache Polaris** 替代趋势（Iceberg Catalog 原生权限）

### 13.5 学习价值

**`RangerPolicyEngineImpl.evaluatePolicies` 是大数据生态最常被调用的单个方法之一**：
- HDFS 每次 open/read/write
- Hive/Trino 每次查询每张表
- 日调用量：百亿级（大中型企业）

理解这个方法的决策链路，就理解了**大数据企业级安全的第一性原理**。

> 权限不是限制，是信任的工程化。
