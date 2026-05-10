# HS2 SELECT 鉴权完整代码路径与 PolicyCache 机制

> **核心结论镇楼**：每次鉴权请求**不访问 Ranger Admin**！完全在本地内存 `RangerPolicyEngine` 中完成。Ranger Admin 只参与"启动加载 + 后台定时刷新"。

---

## 一、整体架构图

```
┌──────────────────────────────────────────────────────────────────────┐
│                        启动阶段（一次性）                              │
│                                                                      │
│  PolicyRefresher(后台线程) ──定时 30s──> Ranger Admin 获取全量策略     │
│            │                                                         │
│            ├─→ saveToCache() 落盘到本地 JSON 文件（兜底）              │
│            │                                                         │
│            └─→ plugIn.setPolicies() → 构建 RangerPolicyRepository     │
│                                       (内存 + Trie 索引)              │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       每次鉴权请求（纯内存）                           │
│                                                                      │
│  HS2 ──> RangerHiveAuthorizer ──> RangerBasePlugin                    │
│                                       │                              │
│                                       ▼                              │
│                              RangerPolicyEngine (内存)                │
│                                       │                              │
│                                       ▼                              │
│                          RangerPolicyRepository                       │
│                          (Trie 索引 → O(1) 候选筛选)                  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 二、启动阶段：PolicyCache 是如何建立的

### 2.1 RangerBasePlugin 初始化链路

```
RangerBasePlugin.init()
  │
  ├── PolicyRefresher refresher = new PolicyRefresher(this)
  │
  └── refresher.startRefresher()
        │
        ├── loadRoles()                                    // 加载用户组/角色
        │
        ├── loadPolicy()                                   // 加载策略到内存
        │     │
        │     ├── loadPolicyfromPolicyAdmin()              // 从 Ranger Admin 获取
        │     │      └── rangerAdmin.getServicePoliciesIfUpdated()
        │     │              └── HTTP REST 调用
        │     │
        │     ├── if (svcPolicies == null) {               // Admin 不可达兜底
        │     │     if (!policiesSetInPlugin) {
        │     │         svcPolicies = loadFromCache();     // 从本地文件加载
        │     │     }
        │     │ }
        │     │
        │     └── plugIn.setPolicies(svcPolicies)          // 构建 PolicyEngine
        │
        └── policyDownloadTimer.schedule(...)              // 启动 30s 定时器
```

### 2.2 PolicyEngine 构建过程

`new RangerPolicyEngineImpl(policies, ...)`
- → `new PolicyEngine(servicePolicies, ...)` [PolicyEngine.java:162]
  - → `policyRepository = new RangerPolicyRepository(...)` // 资源策略库
  - → `tagPolicyRepository = new RangerPolicyRepository(...)` // Tag 策略库
  - → `buildZoneTrie(servicePolicies)` // 构建 Zone Trie

---

## 三、每次鉴权请求的完整代码路径

以 `SELECT * FROM db1.tbl1 WHERE col1 = 'xxx'` 为例。

### 3.1 入口：HiveServer2

```
HiveServer2.startOperation()
  └── SemanticAnalyzer.checkPrivileges()
        └── RangerHiveAuthorizer.checkPrivileges()
              [RangerHiveAuthorizer.java:222]
```

### 3.2 RangerHiveAuthorizer.checkPrivileges() — 构建 AccessRequest

```java
// RangerHiveAuthorizer.java:222
@Override
public AuthorizationResponse checkPrivileges(Operation operation, List<HivePrivilegeObject> privObjList) {
    for (HivePrivilegeObject hivePrivObject : privObjList) {
        RangerHiveResource resource = new RangerHiveResource(hivePrivObject);

        String user = ugi.getShortUserName();
        Set<String> groups = ugi.getGroupNames();

        RangerAccessRequest request = new RangerHiveAccessRequest(
            resource, user, groups, accessType  // SELECT/UPDATE/INSERT
        );

        RangerAccessResult result = hivePlugin.isAccessAllowed(request, auditHandler);
    }
}
```

### 3.3 RangerBasePlugin.isAccessAllowed() — 纯内存

```java
// RangerBasePlugin.java:382
public RangerAccessResult isAccessAllowed(RangerAccessRequest request, RangerAccessResultProcessor resultProcessor) {
    RangerPolicyEngine policyEngine = this.policyEngine;  // ← 本地内存中的引擎！

    if (policyEngine != null) {
        ret = policyEngine.evaluatePolicies(request, RangerPolicy.POLICY_TYPE_ACCESS, null);
        //   ↑ 纯内存操作，不访问网络 ↑
    }
    return ret;
}
```

### 3.4 RangerPolicyEngineImpl.evaluatePolicies()

```java
// RangerPolicyEngineImpl.java:123
public RangerAccessResult evaluatePolicies(RangerAccessRequest request, int policyType, ...) {
    requestProcessor.preProcess(request);                  // 补充用户组、IP
    useRangerGroup(request);                               // 合并外部用户组

    RangerAccessResult ret = zoneAwareAccessEvaluationWithNoAudit(request, policyType);
    return ret;
}
```

### 3.5 zoneAwareAccessEvaluationWithNoAudit() — Zone 路由

```java
// RangerPolicyEngineImpl.java:466
Set<String> zoneNames = policyEngine.getMatchedZonesForResourceAndChildren(request.getResource());

if (zoneNames 为空) {
    policyRepository = policyEngine.getRepositoryForZone(null);   // 默认策略
} else {
    for (String zoneName : zoneNames) {
        policyRepository = policyEngine.getRepositoryForZone(zoneName);  // Zone 策略
        ret = evaluatePoliciesNoAudit(request, ..., policyRepository, tagPolicyRepository);
    }
}
```

### 3.6 evaluatePoliciesNoAudit() — 核心评估

```java
// RangerPolicyEngineImpl.java:541
// ① 先评估 Tag 策略（可强制覆盖）
evaluateTagPolicies(request, policyType, zoneName, tagPolicyRepository, ret);

// ② Trie 预筛选 → 候选策略
List<RangerPolicyEvaluator> evaluators =
    policyRepository.getLikelyMatchPolicyEvaluators(request.getResource(), policyType);
//   ↑ Trie 索引 O(1) 定位候选，不是遍历所有策略！

// ③ 逐个评估候选策略
for (RangerPolicyEvaluator evaluator : evaluators) {
    if (!evaluator.isApplicable(accessTime)) continue;
    evaluator.evaluate(request, ret);
    if (ret.getIsAuditedDetermined() && ret.getIsAccessDetermined()) break;
}
```

### 3.7 Trie 索引原理

```
策略：
  P1: database=db1, table=tbl1                 → admin, ALL
  P2: database=db1, table=*, column=col1       → analytics, SELECT
  P3: database=db1, table=tbl1, column=col2    → *, SELECT + Mask

Trie 倒排索引：
  database trie: db1 → {P1, P2, P3}
  table trie:    tbl1 → {P1, P3};   * → {P2}
  column trie:   col1 → {P2};   col2 → {P3}

查询 SELECT col1 FROM db1.tbl1：
  database=db1   → {P1, P2, P3}
  table=tbl1     → {P1, P3} ∪ {P2}（* 命中）= {P1, P2, P3}
  column=col1    → {P2}
  取交集 → {P2}（候选只有 1 条，无需遍历全量）
```

---

## 四、PolicyCache 三层缓存架构

```
┌──────────────────────────────────────────────────────────────────┐
│                  ① Ranger Admin Server                          │
│                  (策略持久化 + 版本管理)                          │
└──────────────────────────────────────────────────────────────────┘
                            │
                            │ 30s 轮询（pollIntervalMs 可配）
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│              ② 本地文件缓存                                       │
│  路径：{cacheDir}/{appId}_{serviceName}.json                     │
│  例：/etc/ranger/hive2/cache/hive2_hive_cluster.json              │
│  内容：全量策略 JSON + policyVersion                             │
└──────────────────────────────────────────────────────────────────┘
                            │
                            │ 启动时加载兜底
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│              ③ 内存 PolicyRepository                              │
│   ┌─────────────────────────────────────────────────────┐        │
│   │ policies: List<RangerPolicy>                        │        │
│   │ policyResourceTrie: Map<String, RangerResourceTrie> │        │
│   │ policyEvaluators: List<RangerPolicyEvaluator>       │        │
│   │ accessAuditCache: Map<String, AuditInfo>            │        │
│   └─────────────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 五、Load from Local Cache 完整机制（重点）

### 5.1 触发时机：loadPolicy() 流程（PolicyRefresher.java:229-289）

```java
private void loadPolicy() {
    // ① 先尝试从 Ranger Admin Server 获取
    ServicePolicies svcPolicies = loadPolicyfromPolicyAdmin();

    // ② 如果从 Admin 获取失败，且之前从未成功过，才走本地缓存
    if (svcPolicies == null) {
        if (!policiesSetInPlugin) {           // ← 关键判断
            svcPolicies = loadFromCache();
        }
    }

    // ③ 设置到 Plugin
    if (svcPolicies != null) {
        plugIn.setPolicies(svcPolicies);
        policiesSetInPlugin = true;            // 标记已成功加载
    }
}
```

### 5.2 "加载失败"的三种场景

```java
private ServicePolicies loadPolicyfromPolicyAdmin() throws RangerServiceNotFoundException {
    try {
        svcPolicies = rangerAdmin.getServicePoliciesIfUpdated(
            lastKnownVersion, lastActivationTimeInMillis
        );  // HTTP REST 调用 Ranger Admin
    } catch (RangerServiceNotFoundException snfe) {
        throw snfe;                            // 场景A：服务被删
    } catch (Exception excp) {
        svcPolicies = null;                    // 场景B：网络不通/超时
    }
    return svcPolicies;
}
```

| 场景 | 异常 | 后续动作 |
|-----|------|---------|
| **A：服务被删除** | `RangerServiceNotFoundException` | `disableCache()` 重命名缓存文件，Plugin 置空 |
| **B：网络不通/Admin 宕机** | `Exception` | `svcPolicies = null`，进入 ② 兜底分支 |
| **C：正常返回** | — | 直接用新策略 |

### 5.3 `!policiesSetInPlugin` 的真实含义

| 状态 | 含义 |
|------|------|
| `policiesSetInPlugin = false` | 之前**从未**从 Admin 成功拿到过策略（首次启动） |
| `policiesSetInPlugin = true` | 之前**已经**从 Admin 成功加载过，内存里有策略 |

**为什么这样设计**：

```
场景X：Admin 正常运行 1 小时后突然挂了

1. 1 小时内：每次刷新都成功
   - policiesSetInPlugin = true
   - 内存中有最新策略
   - 本地文件也是最新的（每次成功后 saveToCache）

2. Admin 挂了：
   - loadPolicyfromPolicyAdmin() 返回 null
   - if (!policiesSetInPlugin) → false（已成功过）
   - loadFromCache() 不会执行
   - 内存中的 PolicyEngine 仍持有上次的策略
   - 鉴权继续工作，降级但不中断 ✓

设计意图：
  - Admin 临时不可达 → 用内存中旧策略续命
  - 只有"首次启动 + Admin 不可达"才读本地文件兜底
```

### 5.4 loadFromCache() 实现（PolicyRefresher.java:344-399）

```java
private ServicePolicies loadFromCache() {
    File cacheFile = new File(cacheDir + File.separator + cacheFileName);

    if (cacheFile != null && cacheFile.isFile() && cacheFile.canRead()) {
        Reader reader = new FileReader(cacheFile);
        policies = gson.fromJson(reader, ServicePolicies.class);  // JSON → Java 对象

        if (policies != null) {
            lastKnownVersion = policies.getPolicyVersion() != null
                ? policies.getPolicyVersion().longValue() : -1;
        }
    } else {
        LOG.warn("cache file does not exist or not readable");
    }
    return policies;
}
```

**配置参数**：
- `cacheDir`：`{propertyPrefix}.policy.cache.dir`，例 `ranger.hive.policy.cache.dir`
- `cacheFileName`：`{appId}_{serviceName}.json`
- 完整路径示例：`/etc/ranger/hive2/cache/hive2_hive_cluster.json`

### 5.5 saveToCache() — 写入时机（PolicyRefresher.java:401-459）

```java
public void saveToCache(ServicePolicies policies) {
    File cacheFile = new File(cacheDir + File.separator + cacheFileName);
    Writer writer = new FileWriter(cacheFile);
    gson.toJson(policies, writer);  // Java 对象 → JSON 文件
}
```

**调用时机**：在 `RangerBasePlugin.setPolicies()` 成功后自动触发：

```java
// RangerBasePlugin.java:316-324
plugIn.setPolicies(svcPolicies);

if (this.refresher != null) {
    this.refresher.saveToCache(usePolicyDeltas ? servicePolicies : policies);
}
```

### 5.6 完整状态机

```
                    PolicyRefresher 启动
                         │
                         ▼
         ┌──────────────────────────────────┐
         │ loadPolicyfromPolicyAdmin()      │
         │ (HTTP → Ranger Admin)            │
         └──────────────────────────────────┘
              │                    │
              │ 成功               │ 失败（svcPolicies=null）
              ▼                    ▼
   ┌──────────────────┐   ┌──────────────────────────────────┐
   │ svcPolicies≠null │   │ if (!policiesSetInPlugin) {      │
   │                  │   │     loadFromCache()  ← 读本地     │
   └──────────────────┘   │ }                                │
              │           └──────────────────────────────────┘
              │                │                       │
              │                │ 首次（false）          │ 非首次（true）
              │                ▼                       ▼
              │     ┌──────────────────┐   ┌────────────────────────┐
              │     │ 读到本地缓存      │   │ 不读文件，               │
              │     │ → setPolicies   │   │ 用内存中旧策略继续鉴权   │
              │     └──────────────────┘   └────────────────────────┘
              │                │
              ▼                ▼
   ┌──────────────────────────────────┐
   │ plugIn.setPolicies(svcPolicies)  │
   │ policiesSetInPlugin = true       │
   └──────────────────────────────────┘
              │
              ▼
   ┌──────────────────────────────────┐
   │ saveToCache() 写本地文件          │
   └──────────────────────────────────┘
```

### 5.7 ServiceNotFound 处理（disableCache: 461-485）

```java
private void disableCache() {
    File cacheFile = new File(cacheDir + File.separator + cacheFileName);
    if (cacheFile != null && cacheFile.isFile() && cacheFile.canRead()) {
        // 重命名备份：hive2_hive_cluster.json → hive2_hive_cluster.json_1749999999999
        String renamed = cacheFile.getAbsolutePath() + "_" + System.currentTimeMillis();
        cacheFile.renameTo(new File(renamed));
    }
}
```

**作用**：服务在 Admin 上被删除时，重命名旧缓存避免脏数据。

### 5.8 缓存文件内容示例

```json
{
  "serviceName": "hive_cluster",
  "serviceId": 301,
  "policyVersion": 47,
  "serviceDef": { ... },
  "policies": [
    {
      "id": 1,
      "name": "db1-tbl1-select",
      "resources": {
        "database": { "values": ["db1"], "isRecursive": false },
        "table":   { "values": ["tbl1"], "isRecursive": false }
      },
      "accesses": [{ "type": "select", "isAllowed": true }],
      "conditions": [{ "type": "user", "values": ["alice"] }],
      "policyPriority": 0
    }
  ],
  "tagPolicies": { ... }
}
```

---

## 六、关键源码索引表

| 步骤 | 源码文件 | 行号 | 作用 |
|-----|---------|------|------|
| Plugin 初始化 | `RangerBasePlugin.java` | 169-200 | 启动 PolicyRefresher |
| Refresher 启动 | `PolicyRefresher.java` | 142-162 | loadPolicy + 启动定时器 |
| 加载策略入口 | `PolicyRefresher.java` | 229-289 | `loadPolicy()` |
| 从 Admin 获取 | `PolicyRefresher.java` | 291-341 | `loadPolicyfromPolicyAdmin()` |
| **本地缓存加载** | `PolicyRefresher.java` | 344-399 | `loadFromCache()` |
| **本地缓存写入** | `PolicyRefresher.java` | 401-459 | `saveToCache()` |
| 缓存清理 | `PolicyRefresher.java` | 461-485 | `disableCache()` |
| 策略落地 | `RangerBasePlugin.java` | 262-324 | `setPolicies()` + saveToCache 调用 |
| **鉴权入口** | `RangerBasePlugin.java` | 382-406 | `isAccessAllowed()` 纯内存 |
| 引擎评估 | `RangerPolicyEngineImpl.java` | 123-164 | `evaluatePolicies()` |
| Zone 路由 | `RangerPolicyEngineImpl.java` | 466-539 | `zoneAwareAccessEvaluationWithNoAudit()` |
| 策略评估核心 | `RangerPolicyEngineImpl.java` | 541-637 | `evaluatePoliciesNoAudit()` |
| Trie 候选筛选 | `RangerPolicyRepository.java` | — | `getLikelyMatchPolicyEvaluators()` |
| 增量更新 | `RangerBasePlugin.java` | 250-306 | `applyDelta()` |

---

## 七、核心问答总结

| 问题 | 答案 |
|-----|------|
| 鉴权是否每次请求 Ranger Admin？ | **否**。完全在本地内存 `RangerPolicyEngine` 中完成 |
| PolicyCache 作用？ | 启动时从 Ranger Admin 拉取全量策略存入内存，后续鉴权直接查内存 |
| 后台如何更新？ | `PolicyRefresher` 线程每 30s 轮询 Admin，有更新则增量刷新（Delta） |
| Trie 索引作用？ | 空间换时间，按资源层级倒排索引，O(1) 定位候选策略，避免遍历全量 |
| 服务不可达怎么办？ | 首次启动失败 → 读本地 JSON 文件兜底；运行时失败 → 用内存旧策略续命 |
| `!policiesSetInPlugin` 含义？ | 标记"是否曾从 Admin 成功加载过"，只有从未成功过才读本地文件 |
| 缓存文件路径？ | `{cacheDir}/{appId}_{serviceName}.json`，如 `/etc/ranger/hive2/cache/hive2_hive_cluster.json` |
| 缓存写入时机？ | 每次从 Admin 成功获取策略并 setPolicies 后自动 saveToCache |
| 服务被删除怎么办？ | `disableCache()` 重命名旧缓存文件，避免脏数据残留 |

---

**文档版本**：v1.0
**更新时间**：2026-05-10
**Eric（豹纹）出品**
