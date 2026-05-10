# Ranger 增量更新（Policy Delta）机制深度解析

> **核心命题**：每次 PolicyRefresher 都拉全量策略代价巨大（单服务可能几万条策略）。Ranger 通过 **Policy Delta** 机制只下发变化的策略，并在客户端**复用旧 PolicyEngine 的 Trie 索引**，性能提升数十倍。

---

## 一、为什么需要 Policy Delta

### 1.1 全量更新的痛点

```
假设场景：
- 一个 Hive 服务有 10000 条策略
- 每 30 秒轮询一次
- Plugin 实例数：100 个 HiveServer2 节点

全量模式：
  每次刷新 → 下载 10000 条策略 JSON（~50MB）
                ↓
              重建整个 PolicyEngine（包括 Trie 索引）
                ↓
              CPU 消耗 + GC 压力
                ↓
  100 个节点 × 50MB × 每30秒 = 网络 IO 洪水
```

### 1.2 Delta 模式的优化

```
增量模式：
  Admin 只返回变化的策略（CREATE/UPDATE/DELETE）
                ↓
  100 条变化 → 只下载 100 条 delta（~500KB）
                ↓
  在旧 PolicyEngine 基础上 cloneWithDelta()
                ↓
  只更新 Trie 中受影响的部分
                ↓
  老 PolicyRepository 数据结构大量复用（共享引用）
```

**性能数据（Ranger 官方）**：
- 全量重建 10000 条策略 → 约 3-5 秒
- Delta 应用 100 条变化 → 约 50-100ms
- 加速比：**30-50 倍**

---

## 二、Delta 数据模型

### 2.1 RangerPolicyDelta（model/RangerPolicyDelta.java:37-80）

```java
public class RangerPolicyDelta {
    // 变化类型常量
    public static final int CHANGE_TYPE_POLICY_CREATE       = 0;
    public static final int CHANGE_TYPE_POLICY_UPDATE       = 1;
    public static final int CHANGE_TYPE_POLICY_DELETE       = 2;
    public static final int CHANGE_TYPE_SERVICE_CHANGE      = 3;
    public static final int CHANGE_TYPE_SERVICE_DEF_CHANGE  = 4;
    public static final int CHANGE_TYPE_RANGER_ADMIN_START  = 5;
    public static final int CHANGE_TYPE_LOG_ERROR           = 6;
    public static final int CHANGE_TYPE_INVALIDATE_POLICY_DELTAS = 7;
    public static final int CHANGE_TYPE_ROLE_UPDATE         = 8;

    private Long          id;          // delta 自身 ID
    private Integer       changeType;  // 变化类型（CREATE/UPDATE/DELETE）
    private RangerPolicy  policy;      // 完整策略对象（DELETE 时只需 id）
}
```

**关键设计**：
- DELETE 也会带上 policy 对象（用于通过 `policy.getId()` 找到旧 evaluator）
- `serviceType`/`policyType` 都从 policy 中派生（避免冗余）

### 2.2 ServicePolicies — 全量 vs 增量

```java
public class ServicePolicies {
    private List<RangerPolicy>      policies;       // 全量：所有策略
    private List<RangerPolicyDelta> policyDeltas;   // 增量：变化的策略

    // 关键：这两个字段互斥！
    // - 全量响应：policies 非空，policyDeltas 为空
    // - 增量响应：policies 为空，policyDeltas 非空
}
```

**判断逻辑**（RangerPolicyDeltaUtil.java:158-196）：

```java
public static Boolean hasPolicyDeltas(ServicePolicies servicePolicies) {
    boolean isPoliciesExist     = !empty(servicePolicies.getPolicies()) || ...
    boolean isPolicyDeltasExist = !empty(servicePolicies.getPolicyDeltas()) || ...

    if (isPoliciesExist && isPolicyDeltasExist) {
        LOG.warn("ServicePolicies contain both policies and policy-deltas!!");
        return null;  // ← 内部不一致，返回 null
    } else {
        return isPolicyDeltasExist;
    }
}
```

---

## 三、Delta 应用完整流程

### 3.1 入口：RangerBasePlugin.setPolicies()

```java
// RangerBasePlugin.java:236-260
Boolean hasPolicyDeltas = RangerPolicyDeltaUtil.hasPolicyDeltas(policies);

if (hasPolicyDeltas == null) {
    // ← 既有全量又有增量，逻辑错误，保持旧引擎
    LOG.warn("Downloaded policies are internally inconsistent!!");
    isNewEngineNeeded = false;
} else if (hasPolicyDeltas == true) {
    // ↓ 增量更新分支
    RangerPolicyEngineImpl policyEngine = (RangerPolicyEngineImpl) oldPolicyEngine;

    // ① 把 deltas 应用到 oldEngine 的策略列表上，得到新的 policies 列表
    servicePolicies = ServicePolicies.applyDelta(policies, policyEngine);

    if (servicePolicies != null) {
        usePolicyDeltas = true;
    } else {
        // delta 无效（serviceType 不匹配等），降级为保持旧引擎
        LOG.error("Could not apply deltas");
        isNewEngineNeeded = false;
    }
}
```

### 3.2 ServicePolicies.applyDelta() — 重建策略列表

```java
// ServicePolicies.java:388-434
public static ServicePolicies applyDelta(ServicePolicies servicePolicies, RangerPolicyEngineImpl policyEngine) {
    ServicePolicies ret = copyHeader(servicePolicies);  // 复制 header（serviceName, version 等）

    // ① 取出旧引擎中的资源策略列表
    List<RangerPolicy> oldResourcePolicies = policyEngine.getResourcePolicies();
    List<RangerPolicy> oldTagPolicies      = policyEngine.getTagPolicies();

    // ② 应用 deltas：旧列表 + deltas → 新列表
    List<RangerPolicy> newResourcePolicies =
        RangerPolicyDeltaUtil.applyDeltas(
            oldResourcePolicies,
            servicePolicies.getPolicyDeltas(),
            servicePolicies.getServiceDef().getName()
        );

    ret.setPolicies(newResourcePolicies);

    // ③ Tag 策略同样处理
    if (servicePolicies.getTagPolicies() != null) {
        newTagPolicies = RangerPolicyDeltaUtil.applyDeltas(
            oldTagPolicies, servicePolicies.getPolicyDeltas(),
            servicePolicies.getTagPolicies().getServiceDef().getName());
    }
    ret.getTagPolicies().setPolicies(newTagPolicies);

    // ④ 各 SecurityZone 也要应用 zone 自己的 deltas
    for (Map.Entry<String, SecurityZoneInfo> entry : servicePolicies.getSecurityZones().entrySet()) {
        List<RangerPolicy> zoneResourcePolicies = policyEngine.getResourcePolicies(zoneName);
        List<RangerPolicy> newZonePolicies = RangerPolicyDeltaUtil.applyDeltas(
            zoneResourcePolicies, zoneInfo.getPolicyDeltas(), serviceType);
        // ...
    }
    return ret;
}
```

### 3.3 RangerPolicyDeltaUtil.applyDeltas() — 核心算法

```java
// RangerPolicyDeltaUtil.java:41-111
public static List<RangerPolicy> applyDeltas(
        List<RangerPolicy> policies,           // 旧列表
        List<RangerPolicyDelta> deltas,        // 增量
        String serviceType) {

    if (CollectionUtils.isEmpty(deltas)) {
        return policies;  // 无变化直接返回旧列表
    }

    List<RangerPolicy> ret = new ArrayList<>(policies);  // 浅拷贝（重要！）

    for (RangerPolicyDelta delta : deltas) {
        int changeType = delta.getChangeType();

        // 跳过其他服务类型的 delta（一次响应可能包含 Tag 服务的 delta）
        if (!serviceType.equals(delta.getServiceType())) {
            continue;
        }

        switch (changeType) {
            case CHANGE_TYPE_POLICY_CREATE:
                if (delta.getPolicy() != null) {
                    ret.add(delta.getPolicy());  // 直接追加
                }
                break;

            case CHANGE_TYPE_POLICY_UPDATE:
            case CHANGE_TYPE_POLICY_DELETE:
                Long policyId = delta.getPolicyId();

                // ① 先按 ID 删除旧策略
                Iterator<RangerPolicy> iter = ret.iterator();
                while (iter.hasNext()) {
                    if (policyId.equals(iter.next().getId())) {
                        iter.remove();
                        break;
                    }
                }

                // ② UPDATE 还要把新策略加回来
                if (changeType == CHANGE_TYPE_POLICY_UPDATE && delta.getPolicy() != null) {
                    ret.add(delta.getPolicy());
                }
                break;
        }
    }

    // 按 policyId 排序保证确定性
    if (CollectionUtils.isNotEmpty(deltas) && CollectionUtils.isNotEmpty(ret)) {
        ret.sort(RangerPolicy.POLICY_ID_COMPARATOR);
    }
    return ret;
}
```

**关键点**：
- `UPDATE` = `DELETE` + `CREATE`（先删除旧的，再添加新的）
- 跨 serviceType 的 delta 直接跳过（避免错乱）
- 排序保证两次相同输入得到相同输出（幂等性）

---

## 四、PolicyEngine.cloneWithDelta() — 引擎级克隆

### 4.1 调用链

```
RangerBasePlugin.setPolicies()
  ├── ServicePolicies.applyDelta()           ← ① 计算新策略列表
  │
  └── RangerPolicyEngineImpl.getPolicyEngine(oldEngine, policies)
        │
        └── new RangerPolicyEngineImpl(oldEngine, policies)
              │
              └── policyEngine.cloneWithDelta(policies)   ← ② 引擎克隆
                    │
                    └── new PolicyEngine(this, servicePolicies)
```

### 4.2 cloneWithDelta() 源码（PolicyEngine.java:250-297）

```java
public PolicyEngine cloneWithDelta(ServicePolicies servicePolicies) {
    final PolicyEngine ret;

    RangerServiceDef serviceDef = this.getServiceDef();
    String serviceType = (serviceDef != null) ? serviceDef.getName() : "";
    boolean isValidDeltas = false;

    // ① 校验 delta 合法性
    if (CollectionUtils.isNotEmpty(servicePolicies.getPolicyDeltas())
            || MapUtils.isNotEmpty(servicePolicies.getSecurityZones())) {

        isValidDeltas = CollectionUtils.isEmpty(servicePolicies.getPolicyDeltas())
                || RangerPolicyDeltaUtil.isValidDeltas(servicePolicies.getPolicyDeltas(), serviceType);

        // 各 SecurityZone 的 delta 也要校验
        if (isValidDeltas && MapUtils.isNotEmpty(servicePolicies.getSecurityZones())) {
            for (Map.Entry<String, SecurityZoneInfo> entry : servicePolicies.getSecurityZones().entrySet()) {
                if (!RangerPolicyDeltaUtil.isValidDeltas(entry.getValue().getPolicyDeltas(), serviceType)) {
                    isValidDeltas = false;
                    break;
                }
            }
        }
    }

    // ② 校验通过 → 创建新引擎（共享旧引擎大量数据）
    if (isValidDeltas) {
        ret = new PolicyEngine(this, servicePolicies);  // ← 关键：复用 this
    } else {
        ret = null;  // 校验失败，外层会降级走全量重建
    }

    return ret;
}
```

### 4.3 isValidDeltas() — 防御性校验

```java
// RangerPolicyDeltaUtil.java:113-156
public static boolean isValidDeltas(List<RangerPolicyDelta> deltas, String componentServiceType) {
    for (RangerPolicyDelta delta : deltas) {
        Integer changeType = delta.getChangeType();
        Long policyId      = delta.getPolicyId();

        if (changeType == null) return false;

        // 必须是 CREATE/UPDATE/DELETE 三种
        if (changeType != CHANGE_TYPE_POLICY_CREATE
                && changeType != CHANGE_TYPE_POLICY_UPDATE
                && changeType != CHANGE_TYPE_POLICY_DELETE) {
            return false;
        }
        if (policyId == null) return false;

        String serviceType = delta.getServiceType();
        Integer policyType = delta.getPolicyType();

        // serviceType 必须匹配，或为 tag 服务
        if (serviceType == null || (!serviceType.equals(EMBEDDED_SERVICEDEF_TAG_NAME)
                && !serviceType.equals(componentServiceType))) {
            return false;
        }

        // policyType 必须是 ACCESS/DATAMASK/ROWFILTER
        if (policyType == null || (policyType != POLICY_TYPE_ACCESS
                && policyType != POLICY_TYPE_DATAMASK
                && policyType != POLICY_TYPE_ROWFILTER)) {
            return false;
        }
    }
    return true;
}
```

---

## 五、RangerPolicyRepository 增量构造（核心）

PolicyEngine 复用旧的 Repository 时，调用 `RangerPolicyRepository(other, deltas, policyVersion)` 构造函数。

### 5.1 数据共享与 COW（Copy-On-Write）

```java
// RangerPolicyRepository.java:88-110
RangerPolicyRepository(RangerPolicyRepository other, List<RangerPolicyDelta> deltas, long policyVersion) {
    // ① 不可变字段直接引用（共享）
    this.serviceName               = other.serviceName;
    this.zoneName                  = other.zoneName;
    this.options                   = other.options;
    this.serviceDef                = other.serviceDef;

    // ② 可变集合浅拷贝（写时复制）
    this.policies                  = new ArrayList<>(other.policies);
    this.policyEvaluators          = new ArrayList<>(other.policyEvaluators);
    this.dataMaskPolicyEvaluators  = new ArrayList<>(other.dataMaskPolicyEvaluators);
    this.rowFilterPolicyEvaluators = new ArrayList<>(other.rowFilterPolicyEvaluators);
    this.policyEvaluatorsMap       = new HashMap<>(other.policyEvaluatorsMap);

    // ③ Trie 完整克隆（保留旧索引结构 + 写时复制节点）
    if (other.policyResourceTrie != null) {
        this.policyResourceTrie = new HashMap<>();
        for (Map.Entry<String, RangerResourceTrie> entry : other.policyResourceTrie.entrySet()) {
            policyResourceTrie.put(entry.getKey(), new RangerResourceTrie(entry.getValue()));
            //                                       ↑ Trie 复制构造（COW）
        }
    }
    // ... 同样处理 dataMaskResourceTrie, rowFilterResourceTrie ...
```

### 5.2 应用 delta 到 Trie

```java
// RangerPolicyRepository.java:142-225
boolean[] flags = new boolean[RangerPolicy.POLICY_TYPES.length];

for (RangerPolicyDelta delta : deltas) {
    Integer changeType = delta.getChangeType();
    String  serviceType = delta.getServiceType();
    Long    policyId    = delta.getPolicyId();
    Integer policyType  = delta.getPolicyType();

    // 跳过其他服务类型的 delta
    if (!serviceType.equals(this.serviceDef.getName())) {
        continue;
    }

    RangerPolicyEvaluator evaluator = null;

    switch (changeType) {
        case CHANGE_TYPE_POLICY_CREATE:
            // CREATE：evaluator = null（在 update() 中创建）
            if (delta.getPolicy() == null) continue;
            break;

        case CHANGE_TYPE_POLICY_UPDATE:
        case CHANGE_TYPE_POLICY_DELETE:
            // UPDATE/DELETE：先找到旧 evaluator
            evaluator = getPolicyEvaluator(policyId);
            break;
    }

    // 关键调用：update() 处理 evaluator 生命周期 + Trie 增量更新
    evaluator = update(delta, evaluator);

    if (evaluator != null) {
        switch (changeType) {
            case CHANGE_TYPE_POLICY_CREATE:
            case CHANGE_TYPE_POLICY_UPDATE:
                policyEvaluatorsMap.put(policyId, evaluator);
                break;
            case CHANGE_TYPE_POLICY_DELETE:
                policyEvaluatorsMap.remove(policyId);
                break;
        }
        flags[policyType] = true;
    }
}

// 标记哪些 policyType 的 Trie 需要 wrap up（合并/优化）
for (int policyType = 0; policyType < flags.length; policyType++) {
    if (flags[policyType]) {
        Map<String, RangerResourceTrie> trie = getTrie(policyType);
        if (trie != null) {
            for (Map.Entry<String, RangerResourceTrie> entry : trie.entrySet()) {
                entry.getValue().wrapUpUpdate();  // ← 优化 Trie 结构
            }
        }
    }
}
```

### 5.3 update() — Evaluator 生命周期

```java
// RangerPolicyRepository.java:1340-1390
private RangerPolicyEvaluator update(RangerPolicyDelta delta, RangerPolicyEvaluator currentEvaluator) {
    int changeType = delta.getChangeType();
    RangerPolicy policy = delta.getPolicy();

    RangerPolicyEvaluator newEvaluator = null;

    switch (changeType) {
        case CHANGE_TYPE_POLICY_CREATE:
            // 创建新 evaluator + 加入 Trie
            newEvaluator = buildPolicyEvaluator(policy, serviceDef, options);
            break;

        case CHANGE_TYPE_POLICY_UPDATE: {
            // 旧的从 Trie 移除
            removePolicyFromTrie(currentEvaluator);
            newEvaluator = buildPolicyEvaluator(policy, serviceDef, options);
            break;
        }

        case CHANGE_TYPE_POLICY_DELETE: {
            removePolicyFromTrie(currentEvaluator);
            // newEvaluator 保持 null
            break;
        }
    }

    // UPDATE/DELETE 都要从对应列表移除旧的
    if (changeType == CHANGE_TYPE_POLICY_UPDATE || changeType == CHANGE_TYPE_POLICY_DELETE) {
        // 从 policyEvaluators / dataMaskPolicyEvaluators / rowFilterPolicyEvaluators 中移除
    }

    // CREATE/UPDATE 把新 evaluator 加入 Trie
    if (newEvaluator != null) {
        addPolicyToTrie(newEvaluator);
    }

    return changeType == CHANGE_TYPE_POLICY_DELETE ? currentEvaluator : newEvaluator;
}
```

---

## 六、完整时序图

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          PolicyRefresher 30s 触发                         │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  loadPolicyfromPolicyAdmin() → rangerAdmin.getServicePoliciesIfUpdated() │
│                                                                          │
│  Admin 端判断：自上次 lastKnownVersion 以来是否有变化？                   │
│  ├── 无变化 → 返回 null（304 Not Modified）                              │
│  ├── 全量场景（首次/版本回退）→ ServicePolicies.policies 非空             │
│  └── 增量场景（常态）→ ServicePolicies.policyDeltas 非空                 │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  RangerBasePlugin.setPolicies()                                          │
│                                                                          │
│  hasPolicyDeltas = RangerPolicyDeltaUtil.hasPolicyDeltas(policies)       │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
        ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
        │   == null    │    │   == false   │    │   == true    │
        │ (内部不一致)  │    │  (全量响应)  │    │  (增量响应)  │
        └──────────────┘    └──────────────┘    └──────────────┘
                │                   │                   │
                ▼                   ▼                   ▼
        ┌──────────────┐    ┌──────────────────┐ ┌──────────────────────┐
        │ 保持旧引擎    │    │ new RangerPolicy │ │ ServicePolicies      │
        │              │    │ EngineImpl(...)   │ │ .applyDelta()        │
        │              │    │ 全量重建          │ │  ↓ 计算新策略列表    │
        │              │    │                  │ │                      │
        │              │    │                  │ │ getPolicyEngine(     │
        │              │    │                  │ │   oldEngine, policies)│
        │              │    │                  │ │  ↓ cloneWithDelta()  │
        │              │    │                  │ │                      │
        │              │    │                  │ │ new PolicyEngine(    │
        │              │    │                  │ │   this, ...)         │
        │              │    │                  │ │  ↓ 复用旧 Trie + 增量│
        │              │    │                  │ │ 应用 delta           │
        └──────────────┘    └──────────────────┘ └──────────────────────┘
                                    │                   │
                                    ▼                   ▼
                          ┌────────────────────────────────────┐
                          │ this.policyEngine = newPolicyEngine │
                          │ pluginContext.notifyAuthContextChanged() │
                          │ oldEngine.releaseResources(...)     │
                          │ refresher.saveToCache(...)          │
                          └────────────────────────────────────┘
```

---

## 七、为什么"复用旧 Engine"是性能关键

### 7.1 Trie 索引重建的成本

`RangerResourceTrie` 是按资源层级建立的多层 Trie，全量重建需要：

```
对每条策略：
  ├── 解析 resources（database/table/column 等）
  ├── 对每个 resource 值，沿 Trie 路径插入
  ├── 处理通配符（*）/ 正则 / isRecursive 标志
  └── 关联到 PolicyEvaluator 引用

10000 条策略 × 平均 3 层资源 × 平均 5 个值 = 150000 次 Trie 插入
```

### 7.2 增量更新只动受影响的节点

```
delta = [POLICY_UPDATE id=1234]
                ↓
只需：
  1. 从 Trie 中找到 oldEvaluator 关联的所有节点
  2. 移除节点对 oldEvaluator 的引用
  3. 创建 newEvaluator
  4. 把 newEvaluator 重新插入 Trie 受影响的节点

性能：O(变化策略数) vs O(全量策略数)
```

### 7.3 PolicyEvaluator 复用

```java
// 未变化的策略 → policyEvaluatorsMap 中的 evaluator 直接共享
// 变化的策略 → 移除旧 evaluator，创建新 evaluator，插入新 evaluator
//
// 节省：
//  - 未变化策略的 evaluator 重新构造成本（解析 conditions/accesses 等）
//  - GC 压力（大量临时对象）
//  - JIT 失效
```

---

## 八、降级与异常处理

### 8.1 Delta 失效的兜底

```java
// RangerBasePlugin.java:281-300
if (oldPolicyEngine != null) {
    newPolicyEngine = RangerPolicyEngineImpl.getPolicyEngine(oldPolicyEngineImpl, policies);
    //                ↑ 内部调用 cloneWithDelta，失败返回 null
}

if (newPolicyEngine != null) {
    isPolicyEngineShared = true;  // ← 增量成功
} else {
    // 增量失败，降级为全量重建
    LOG.debug("Failed to apply policyDeltas, Creating engine from policies");
    newPolicyEngine = new RangerPolicyEngineImpl(servicePolicies, pluginContext, roles);
}
```

### 8.2 失败场景汇总

| 失败场景 | 检测点 | 后果 |
|---------|-------|------|
| 既有全量又有增量 | `hasPolicyDeltas() == null` | 保持旧引擎 |
| oldEngine 为 null | `if (oldPolicyEngine != null)` | 降级全量重建 |
| delta serviceType 不匹配 | `isValidDeltas() == false` | 降级全量重建 |
| delta changeType 非法 | `isValidDeltas() == false` | 降级全量重建 |
| policyType 非法 | `isValidDeltas() == false` | 降级全量重建 |
| applyDeltas 抛异常 | catch 块 | 保持旧引擎 + 错误日志 |

---

## 九、Admin 端 Delta 生成机制（简介）

虽然本文聚焦 Plugin 端，但理解端到端需要知道 Admin 如何生成 delta：

```
Ranger Admin Policy 表
        │
        │ 每次 Policy 变更（CREATE/UPDATE/DELETE）
        ▼
┌──────────────────────────────────────────┐
│ x_policy_change_log 表                    │
│ ├── id (单调递增)                         │
│ ├── service_id                           │
│ ├── policy_id                            │
│ ├── change_type (0/1/2)                  │
│ ├── policy_version                       │
│ └── created_time                         │
└──────────────────────────────────────────┘
        │
        │ Plugin 请求 GET /service/plugins/policies/download?lastKnownVersion=N
        ▼
┌──────────────────────────────────────────┐
│ ServiceREST.getServicePoliciesIfUpdated  │
│  ├── SELECT * FROM x_policy_change_log   │
│  │   WHERE service_id = ? AND id > N     │
│  └── 转换为 List<RangerPolicyDelta>      │
│       └── 返回给 Plugin                  │
└──────────────────────────────────────────┘
```

**版本号规则**：
- `lastKnownVersion = -1`：Plugin 第一次拉取，Admin 必须返回全量
- `lastKnownVersion = N`：Plugin 已有 N 版本，Admin 返回 N+1 ~ latest 之间的 deltas
- 如果 deltas 数量超过阈值（如 100），Admin 可能直接返回全量（避免太多增量）

---

## 十、关键源码索引

| 步骤 | 源码文件 | 行号 | 作用 |
|-----|---------|------|------|
| Delta 模型 | `RangerPolicyDelta.java` | 39-47 | 定义 9 种 changeType |
| Delta 列表 | `ServicePolicies.java` | 61, 185 | `policyDeltas` 字段 |
| 全量/增量判断 | `RangerPolicyDeltaUtil.java` | 158-196 | `hasPolicyDeltas()` |
| 增量入口 | `RangerBasePlugin.java` | 236-260 | setPolicies 中的 delta 分支 |
| 策略列表合并 | `ServicePolicies.java` | 388-434 | `applyDelta()` |
| 核心算法 | `RangerPolicyDeltaUtil.java` | 41-111 | `applyDeltas()` CREATE/UPDATE/DELETE |
| Delta 校验 | `RangerPolicyDeltaUtil.java` | 113-156 | `isValidDeltas()` |
| 引擎克隆 | `PolicyEngine.java` | 250-297 | `cloneWithDelta()` |
| Repository 增量构造 | `RangerPolicyRepository.java` | 88-250 | `RangerPolicyRepository(other, deltas, ver)` |
| Trie 增量更新 | `RangerPolicyRepository.java` | 1340-1390 | `update()` |
| Trie wrap up | `RangerPolicyRepository.java` | 215-225 | `wrapUpUpdate()` |
| 降级路径 | `RangerBasePlugin.java` | 287-300 | `cloneWithDelta` 失败 → 全量重建 |

---

## 十一、核心问答

| 问题 | 答案 |
|-----|------|
| 全量和增量怎么区分？ | `ServicePolicies.policies` vs `policyDeltas` 字段，互斥 |
| 增量带来多大收益？ | 100 条变化 vs 10000 条全量，性能提升 30-50 倍 |
| Trie 索引怎么处理？ | 复制构造（COW）+ 局部更新，未变化的节点共享旧 Trie |
| Evaluator 怎么复用？ | `policyEvaluatorsMap` 浅拷贝，未变化策略直接共享 evaluator 引用 |
| 增量失败怎么办？ | 降级为全量重建（`new RangerPolicyEngineImpl(...)`） |
| 服务变更（SERVICE_CHANGE）会触发什么？ | 强制全量重建（不能用 delta） |
| Plugin 第一次启动 | `lastKnownVersion = -1`，Admin 必返回全量 |
| ServiceDef 变更怎么处理？ | `CHANGE_TYPE_SERVICE_DEF_CHANGE`，强制全量重建（resource schema 都变了） |
| 有 SecurityZone 怎么办？ | 每个 zone 独立维护策略列表，每个 zone 的 deltas 单独 apply |

---

**文档版本**：v1.0
**更新时间**：2026-05-10
**Eric（豹纹）出品**
