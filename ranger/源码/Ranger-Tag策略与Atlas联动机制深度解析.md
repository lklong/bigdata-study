# Ranger Tag 策略与 Atlas 联动机制深度解析

> **核心命题**：Tag 策略是 Ranger 的"属性级"访问控制能力，与 Atlas 元数据系统联动。通过 `RangerTagEnricher` 在鉴权前动态"打标"，再由 `TagPolicyRepository` 做基于标签的策略匹配，实现"PII 数据自动加密"、"敏感表跨系统统一管控"等高级场景。

---

## 一、什么是 Tag 策略

### 1.1 核心概念对比

| 维度 | Resource-Based Policy | Tag-Based Policy |
|-----|----------------------|------------------|
| 控制粒度 | 按资源路径（db/table/column） | 按资源的标签属性（PII/PHI/CONFIDENTIAL） |
| 策略数量 | N 个资源 → N 条策略 | 1 条 Tag 策略覆盖所有打了该 Tag 的资源 |
| 跨组件共享 | ❌ Hive/HBase/HDFS 各自独立 | ✅ 同一套 Tag 策略可覆盖所有组件 |
| 元数据依赖 | 无 | 依赖 Atlas（或其他 Tag 源） |
| 典型场景 | 授权单表/单列 | GDPR/HIPAA 合规，敏感数据全局管控 |

### 1.2 典型使用场景

**场景：GDPR 合规 — 所有 PII 数据自动脱敏**

```
资源侧（Atlas）：
  给所有包含身份证号的列打 Tag = PII
  - hive.db1.user.id_card → Tag: PII
  - hive.db2.customer.ssn → Tag: PII
  - hive.db5.transaction.phone → Tag: PII
  ...

策略侧（Ranger Tag Service）：
  只需 1 条策略：
  Policy: tag=PII, access=SELECT → user=analytics → Mask(SHA256)

效果：
  所有打了 PII 标签的列，SELECT 时自动 Mask。
  新增 PII 列只需要在 Atlas 打标，无需修改 Ranger 策略。
```

---

## 二、端到端架构

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           Apache Atlas                                    │
│  元数据 + 分类（Classification）管理                                       │
│  ├── Entity: hive_table(db1.user)                                         │
│  │   └── Classification: PII (applied=true, propagate=true)                │
│  └── Entity: hive_column(db1.user.id_card)                                 │
│      └── Classification: PII                                              │
└──────────────────────────────────────────────────────────────────────────┘
                               │
                               │ Atlas → Ranger Tag Sync Service
                               │ (Kafka topic: ATLAS_ENTITIES)
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                     Ranger Tag Sync Service                               │
│  监听 Atlas 的 Entity/Classification 变更                                   │
│  转换为 Ranger 的 ServiceTags 数据结构                                      │
│  推送到 Ranger Admin 的 tag service                                        │
└──────────────────────────────────────────────────────────────────────────┘
                               │
                               │ 持久化到 x_tag / x_tag_resource_map 表
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                     Ranger Admin Server                                   │
│  存储 ServiceTags + Tag-based Policy                                       │
└──────────────────────────────────────────────────────────────────────────┘
                               │
                               │ Plugin 定时拉取（独立于 Policy 拉取）
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│              Plugin 端（如 Hive Plugin）                                   │
│                                                                          │
│  ┌────────────────────────────┐    ┌────────────────────────────┐        │
│  │ PolicyRefresher             │    │ RangerTagRefresher          │        │
│  │ (30s 轮询 policies)          │    │ (60s 轮询 tags)             │        │
│  └────────────────────────────┘    └────────────────────────────┘        │
│          │                                    │                          │
│          ▼                                    ▼                          │
│  ┌────────────────────────────┐    ┌────────────────────────────┐        │
│  │ TagPolicyRepository         │    │ RangerTagEnricher           │        │
│  │ (Tag Policy Trie)           │    │ (ServiceResource → Tags 映射)│        │
│  └────────────────────────────┘    └────────────────────────────┘        │
└──────────────────────────────────────────────────────────────────────────┘
                               │
                               ▼ 鉴权时协同工作
                  ┌────────────────────────┐
                  │ evaluateTagPolicies()  │
                  └────────────────────────┘
```

---

## 三、两种 Tag 拉取机制

### 3.1 RangerAdminTagRetriever（推荐）

从 Ranger Admin 拉取 tag service 的数据：

```java
// RangerAdminTagRetriever.java:54-80
@Override
public ServiceTags retrieveTags(long lastKnownVersion, long lastActivationTimeInMillis) throws Exception {
    ServiceTags serviceTags = null;

    if (adminClient != null) {
        serviceTags = adminClient.getServiceTagsIfUpdated(lastKnownVersion, lastActivationTimeInMillis);
        //            ↑ HTTP REST 调用 Ranger Admin 的 tag 接口
    }
    return serviceTags;
}
```

### 3.2 RangerFileBasedTagRetriever（测试用）

从本地 JSON 文件读取 tags（本地开发/测试场景）。

### 3.3 配置（hive-security.xml）

```xml
<property>
  <name>ranger.plugin.hive.tag.retriever.classname</name>
  <value>org.apache.ranger.plugin.contextenricher.RangerAdminTagRetriever</value>
</property>
<property>
  <name>ranger.plugin.hive.policy.rest.url</name>
  <value>http://ranger-admin:6080</value>
</property>
```

---

## 四、Plugin 端 Tag 初始化

### 4.1 RangerTagEnricher.init()（RangerTagEnricher.java:87-150）

```java
public void init() {
    super.init();

    // ① 读取配置
    String tagRetrieverClassName = getOption(TAG_RETRIEVER_CLASSNAME_OPTION);
    long pollingIntervalMs = getLongOption(TAG_REFRESHER_POLLINGINTERVAL_OPTION, 60 * 1000);
    disableTrieLookupPrefilter = getBooleanOption(TAG_DISABLE_TRIE_PREFILTER_OPTION, false);

    if (StringUtils.isNotBlank(tagRetrieverClassName)) {
        // ② 反射创建 tagRetriever（RangerAdminTagRetriever 或 FileBased）
        Class<RangerTagRetriever> clazz = (Class<RangerTagRetriever>) Class.forName(tagRetrieverClassName);
        tagRetriever = clazz.newInstance();

        // ③ 配置缓存文件路径：{cacheDir}/{appId}_{serviceName}_tag.json
        String cacheFilename = String.format("%s_%s_tag.json", appId, serviceName);
        String cacheFile = cacheDir == null ? null : (cacheDir + File.separator + cacheFilename);

        tagRetriever.setServiceName(serviceName);
        tagRetriever.setServiceDef(serviceDef);
        tagRetriever.init(enricherDef.getEnricherOptions());

        // ④ 创建 TagRefresher 后台线程
        tagRefresher = new RangerTagRefresher(tagRetriever, this, -1L, tagDownloadQueue, cacheFile);

        // ⑤ 首次同步拉取
        tagRefresher.populateTags();

        // ⑥ 启动定时器（独立于 PolicyRefresher，默认 60s）
        tagRefresher.startRefresher();
        tagDownloadTimer.schedule(new DownloaderTask(tagDownloadQueue), pollingIntervalMs, pollingIntervalMs);
    }
}
```

**关键设计点**：
- Tag 拉取频率独立于 Policy（默认 60s vs 30s）
- Tag 缓存文件独立：`{appId}_{serviceName}_tag.json`
- Tag 与 Policy 缓存互不干扰

---

## 五、ServiceTags 数据模型

```java
public class ServiceTags {
    private String serviceName;                          // 关联的服务名
    private Long   tagVersion;                            // 版本号
    private boolean isDelta;                             // 是否增量
    private Map<Long, RangerTagDef>       tagDefinitions;   // Tag 定义（id → TagDef）
    private Map<Long, RangerTag>          tags;             // 具体 Tag 实例（id → Tag）
    private List<RangerServiceResource>   serviceResources; // 服务资源
    private Map<Long, List<Long>>         resourceToTagIds; // resource_id → [tag_id1, tag_id2]
}
```

**数据关系示例**：

```
tagDefinitions:
  100 → { name: "PII", attributeDefs: [{name: "propagate", type: "boolean"}] }
  101 → { name: "CONFIDENTIAL" }

tags:
  1001 → { type: 100, attributes: {"propagate": "true"} }
  1002 → { type: 101 }

serviceResources:
  500 → { resource: {"database": ["db1"], "table": ["user"], "column": ["id_card"]} }
  501 → { resource: {"database": ["db2"], "table": ["customer"], "column": ["ssn"]} }

resourceToTagIds:
  500 → [1001]        ← db1.user.id_card 有 PII 标签
  501 → [1001, 1002]  ← db2.customer.ssn 有 PII + CONFIDENTIAL
```

---

## 六、RangerTagEnricher — 打标核心

### 6.1 enrich() — 为请求动态补充 Tag（行182-205）

```java
@Override
public void enrich(RangerAccessRequest request, Object dataStore) {
    final EnrichedServiceTags enrichedServiceTags;
    if (dataStore instanceof EnrichedServiceTags) {
        enrichedServiceTags = (EnrichedServiceTags) dataStore;
    } else {
        enrichedServiceTags = this.enrichedServiceTags;  // 内存中的 Tag 索引
    }

    // ① 根据 request 的 resource 找到所有匹配的 Tag
    final Set<RangerTagForEval> matchedTags =
        enrichedServiceTags == null ? null : findMatchingTags(request, enrichedServiceTags);

    // ② 把 tags 写入 request 的 context，后续 evaluateTagPolicies 读取
    RangerAccessRequestUtil.setRequestTagsInContext(request.getContext(), matchedTags);
}
```

**调用时机**：在 `RangerPolicyEngineImpl.evaluatePolicies()` 中的 `requestProcessor.preProcess(request)` 里调用。

### 6.2 findMatchingTags() — 资源 → Tag 匹配（行602-662）

```java
private Set<RangerTagForEval> findMatchingTags(RangerAccessRequest request, EnrichedServiceTags dataStore) {
    RangerAccessResource resource = request.getResource();

    Set<RangerTagForEval> ret = null;

    // 特殊情况：无 resource + isAccessTypeAny → 返回"任意资源任意访问"的 tags
    if ((resource == null || resource.getKeys() == null || resource.getKeys().isEmpty())
            && request.isAccessTypeAny()) {
        ret = enrichedServiceTags.getTagsForEmptyResourceAndAnyAccess();
    } else {
        // ① 从 Trie 索引中获取候选 matcher（Trie 预筛选优化）
        final List<RangerServiceResourceMatcher> serviceResourceMatchers =
            getEvaluators(resource, enrichedServiceTags);

        if (CollectionUtils.isNotEmpty(serviceResourceMatchers)) {
            // ② 逐个 matcher 评估
            for (RangerServiceResourceMatcher resourceMatcher : serviceResourceMatchers) {
                final MatchType matchType = resourceMatcher.getMatchType(resource, request.getContext());

                final boolean isMatched;
                if (request.isAccessTypeAny()) {
                    isMatched = matchType != MatchType.NONE;
                } else if (request.getResourceMatchingScope() == SELF_OR_DESCENDANTS) {
                    isMatched = matchType != MatchType.NONE;
                } else {
                    // 默认：只接受 SELF 或 ANCESTOR 匹配
                    isMatched = matchType == MatchType.SELF || matchType == MatchType.ANCESTOR;
                }

                // ③ 匹配成功 → 把资源上的所有 tag 加入结果
                if (isMatched) {
                    if (ret == null) ret = new HashSet<>();
                    ret.addAll(getTagsForServiceResource(
                        enrichedServiceTags.getServiceTags(),
                        resourceMatcher.getServiceResource(),
                        matchType));
                }
            }
        }
    }
    return ret;
}
```

### 6.3 MatchType 详解

| MatchType | 含义 | 示例 |
|-----------|-----|------|
| `SELF` | 请求资源本身有 Tag | 查询 `db1.user.id_card`，该列直接打了 PII |
| `ANCESTOR` | 祖先有 Tag，通过传播生效 | 查询 `db1.user.id_card`，Tag 打在 `db1.user` 上（表级）向下传播 |
| `DESCENDANT` | 后代有 Tag | 查询 `db1.user`（整表），其中某列有 PII |
| `NONE` | 完全不匹配 | — |

---

## 七、evaluateTagPolicies() — Tag 策略评估

### 7.1 核心源码（RangerPolicyEngineImpl.java:639-721）

```java
private void evaluateTagPolicies(
        RangerAccessRequest request,
        int policyType,
        String zoneName,
        RangerPolicyRepository tagPolicyRepository,
        RangerAccessResult result) {

    Date accessTime = request.getAccessTime() != null ? request.getAccessTime() : new Date();

    // ① 从 request context 中取出 Enricher 已经补充好的 tags
    Set<RangerTagForEval> tags = RangerAccessRequestUtil.getRequestTagsFromContext(request.getContext());

    // ② Tag Policy Trie 预筛选候选策略
    List<PolicyEvaluatorForTag> policyEvaluators =
        tagPolicyRepository == null ? null :
        tagPolicyRepository.getLikelyMatchPolicyEvaluators(tags, policyType, accessTime);

    if (CollectionUtils.isNotEmpty(policyEvaluators)) {
        final boolean useTagPoliciesFromDefaultZone =
            !policyEngine.isResourceZoneAssociatedWithTagService(zoneName);

        for (PolicyEvaluatorForTag policyEvaluator : policyEvaluators) {
            RangerPolicyEvaluator evaluator = policyEvaluator.getEvaluator();
            String policyZoneName = evaluator.getPolicy().getZoneName();

            // ③ Zone 隔离判断：Tag 策略所属 zone 必须匹配访问资源的 zone
            if (useTagPoliciesFromDefaultZone) {
                if (StringUtils.isNotEmpty(policyZoneName)) continue;
            } else {
                if (!StringUtils.equals(zoneName, policyZoneName)) continue;
            }

            // ④ 构造虚拟的 TagAccessRequest（resource 替换成 tag）
            RangerTagForEval tag = policyEvaluator.getTag();
            RangerAccessRequest tagEvalRequest = new RangerTagAccessRequest(
                tag, tagPolicyRepository.getServiceDef(), request);
            RangerAccessResult tagEvalResult = createAccessResult(tagEvalRequest, policyType);

            // ⑤ 评估策略
            tagEvalResult.setAccessResultFrom(result);
            tagEvalResult.setAuditResultFrom(result);
            result.incrementEvaluatedPoliciesCount();
            evaluator.evaluate(tagEvalRequest, tagEvalResult);

            // ⑥ 合并结果到主 result
            if (tagEvalResult.getIsAllowed()) {
                if (!evaluator.hasDeny()) {
                    tagEvalResult.setIsAccessDetermined(true);
                }
            }

            if (tagEvalResult.getIsAudited()) {
                result.setAuditResultFrom(tagEvalResult);
            }

            if (!result.getIsAccessDetermined()) {
                if (tagEvalResult.getIsAccessDetermined()) {
                    result.setAccessResultFrom(tagEvalResult);
                } else if (!result.getIsAllowed() && tagEvalResult.getIsAllowed()) {
                    result.setAccessResultFrom(tagEvalResult);
                }
            }

            if (result.getIsAuditedDetermined() && result.getIsAccessDetermined()) {
                break;
            }
        }
    }

    if (result.getIsAllowed()) {
        result.setIsAccessDetermined(true);
    }
}
```

### 7.2 虚拟的 RangerTagAccessRequest

Tag 策略评估的关键技巧：**把 Tag 当作一个"虚拟资源"来复用现有的策略评估框架**。

```java
RangerAccessRequest tagEvalRequest = new RangerTagAccessRequest(
    tag,                               // 被评估的 tag（如 PII）
    tagPolicyRepository.getServiceDef(),  // 使用 tag service 的 serviceDef
    request                            // 保留原始请求的用户/上下文
);
```

**效果**：
- 原请求：`user=alice, resource={db:db1, table:user, column:id_card}, access=SELECT`
- Tag 请求：`user=alice, resource={tag:PII}, access=SELECT`

用同一套 `evaluator.evaluate()` 逻辑处理，保持代码一致性。

---

## 八、Tag 策略与 Resource 策略的关系

### 8.1 执行顺序（RangerPolicyEngineImpl:541-637）

```
evaluatePoliciesNoAudit()
  │
  ├── ① 先评估 Tag 策略（evaluateTagPolicies）
  │       │
  │       ├── 如果 Tag 策略给出 ALLOW → result.isAllowed = true
  │       ├── 如果 Tag 策略给出 DENY → result.isAllowed = false
  │       └── 如果 Tag 策略无定论 → 继续评估资源策略
  │
  └── ② 再评估资源策略（Resource Policies）
          │
          ├── 资源策略可以"覆盖" Tag 策略（通过 policyPriority）
          └── 最终结果合并
```

### 8.2 优先级对比（policyPriority）

```java
// 简化规则：
// 1. Tag 策略 DENY + 优先级高 → 最终 DENY
// 2. Tag 策略 ALLOW + 资源策略 DENY + 资源优先级高 → 最终 DENY
// 3. 仅有 Tag 策略 ALLOW → 最终 ALLOW
```

**举例**：

```
场景：用户 alice 想 SELECT db1.user.id_card

Tag 策略：
  P_tag_1: tag=PII, access=SELECT, user=analytics_team → ALLOW + Mask(SHA256)

资源策略：
  P_res_1: db1.user, access=SELECT, user=alice → ALLOW

评估结果：
  - 资源匹配：alice 属于 analytics_team 且 列有 PII 标签 → Tag 策略命中 P_tag_1 → ALLOW + Mask
  - 资源策略 P_res_1 → ALLOW
  - 最终：ALLOW（数据被 Mask 返回）
```

---

## 九、Security Zone 与 Tag 的交互

### 9.1 Zone 隔离规则（代码行649, 655-671）

```java
final boolean useTagPoliciesFromDefaultZone =
    !policyEngine.isResourceZoneAssociatedWithTagService(zoneName);

if (useTagPoliciesFromDefaultZone) {
    // ① 资源 Zone 没关联 Tag 服务 → 只用 Default Zone 的 Tag 策略
    if (StringUtils.isNotEmpty(policyZoneName)) continue;  // 跳过 zone 特定的 tag 策略
} else {
    // ② 资源 Zone 关联了 Tag 服务 → 只用该 Zone 的 Tag 策略
    if (!StringUtils.equals(zoneName, policyZoneName)) continue;
}
```

### 9.2 `containsAssociatedTagService` 字段

在 `SecurityZoneInfo` 中：
```java
private Boolean containsAssociatedTagService;
```

标记该 Zone 是否关联了 Tag 服务：
- `true` → Zone 内的资源使用 Zone 自己的 Tag 策略
- `false` → Zone 内的资源使用 Default Zone 的 Tag 策略

---

## 十、Atlas 联动的全链路

### 10.1 Atlas 事件 → Ranger Tag 同步

```
Atlas 端：
  1. 用户在 Atlas UI 给 hive_column(db1.user.id_card) 打 PII 标签
  2. Atlas 触发 Kafka 事件到 topic ATLAS_ENTITIES
  3. 事件 payload：
     {
       "entity": "hive_column:db1.user.id_card",
       "classification": "PII",
       "propagate": true
     }

Ranger Tag Sync Service：
  4. 消费 Kafka 事件（通过 AtlasChangeEventProcessor）
  5. 查 Atlas REST API 获取完整的 entity 元数据
  6. 转换为 RangerServiceResource + RangerTag
  7. 调用 Ranger Admin REST API：POST /service/tags/importservicetags
  8. Ranger Admin 持久化到 x_tag / x_tag_resource_map 表

Plugin 端：
  9. RangerTagRefresher 下次轮询时（60s 内）感知变化
  10. 拉取 ServiceTags 更新到 enrichedServiceTags
  11. 下次鉴权请求中，该 column 自动携带 PII 标签
```

### 10.2 配置 ranger-tagsync.properties（关键配置）

```properties
# Atlas → Ranger Tag Sync
ranger.tagsync.atlas.to.ranger.service.mapping=hive_cluster,hbase_cluster
ranger.tagsync.source.atlasrest.endpoint=http://atlas-server:21000
ranger.tagsync.source.atlasrest.username=admin
ranger.tagsync.source.atlasrest.password=...

# Kafka 消费端
ranger.tagsync.source.atlas.kafka.bootstrap.servers=kafka-broker:9092
ranger.tagsync.source.atlas.kafka.consumer.group=ranger_entities_consumer

# 目标：Ranger Admin
ranger.tagsync.dest.ranger.endpoint=http://ranger-admin:6080
ranger.tagsync.dest.ranger.username=rangertagsync
```

---

## 十一、关键源码索引

| 步骤 | 源码文件 | 行号 | 作用 |
|-----|---------|------|------|
| Tag Enricher 入口 | `RangerTagEnricher.java` | 87-162 | `init()` 创建 refresher 启动定时 |
| enrich 请求 | `RangerTagEnricher.java` | 182-205 | `enrich()` 为 request 补充 tags |
| Tag 匹配 | `RangerTagEnricher.java` | 602-662 | `findMatchingTags()` |
| Tag 策略评估入口 | `RangerPolicyEngineImpl.java` | 559 | 在 evaluatePoliciesNoAudit 中调用 |
| Tag 策略核心 | `RangerPolicyEngineImpl.java` | 639-721 | `evaluateTagPolicies()` |
| Tag 虚拟请求 | `RangerPolicyEngineImpl.java` | 674 | `new RangerTagAccessRequest(tag, ...)` |
| Tag 拉取 | `RangerAdminTagRetriever.java` | 54-80 | `retrieveTags()` HTTP 调用 |
| Tag Repository | `RangerPolicyRepository` | — | `policyEvaluatorsMap` + Trie |
| Tag 缓存文件 | `RangerTagEnricher.java` | 123 | `{appId}_{serviceName}_tag.json` |
| Tag Delta | `RangerServiceTagsDeltaUtil.java` | — | Tag 增量更新 |

---

## 十二、典型故障排查

### 12.1 "Tag 策略不生效"排查清单

1. **Plugin 端有没有加载 Tag Enricher？**
   ```bash
   # 检查日志
   grep "RangerTagEnricher.init" /var/log/hive/hiveserver2.log
   ```

2. **Tag 缓存文件有没有更新？**
   ```bash
   ls -la /etc/ranger/hive2/cache/hive2_hive_cluster_tag.json
   # 检查 mtime，应该每 60s 内被更新
   ```

3. **Atlas 那边标签是否已打？**
   ```bash
   curl -u admin:... http://atlas-server:21000/api/atlas/v2/entity/guid/{guid}/classifications
   ```

4. **Ranger Admin 有没有收到 Tag 同步？**
   ```sql
   SELECT COUNT(*) FROM x_tag WHERE name='PII';
   SELECT COUNT(*) FROM x_tag_resource_map WHERE tag_id=?;
   ```

5. **Tag Sync Service 日志**
   ```bash
   tail -f /var/log/ranger/tagsync/tagsync.log
   ```

### 12.2 常见配置错误

| 症状 | 可能原因 |
|------|---------|
| Tag 策略完全不触发 | `tagRetrieverClassName` 未配置 |
| 部分 Tag 不生效 | Atlas 侧 `propagate=false`，而策略要 ANCESTOR 匹配 |
| 策略触发但行为不符 | Tag 策略与资源策略的 `policyPriority` 冲突 |
| Zone 内 Tag 策略不生效 | `containsAssociatedTagService` 未设置 |

---

## 十三、核心问答

| 问题 | 答案 |
|-----|------|
| Tag 从哪里来？ | Atlas（主）或文件（测试），通过 RangerTagRetriever 拉取 |
| Tag 和 Policy 是一起拉的吗？ | 不是。PolicyRefresher 管 policy（30s），TagRefresher 管 tags（60s） |
| Tag 策略和资源策略谁先评估？ | Tag 策略先，资源策略后，通过 `policyPriority` 协调 |
| 1 个列能有多少 Tag？ | 无上限，常见为 1-3 个（如 PII + HIGH_SENSITIVE） |
| Tag 传播（propagate）是什么？ | 祖先的标签自动传播到后代（表的标签 → 表的所有列） |
| Atlas 挂了 Ranger 还能工作吗？ | 能。Tag 本地缓存仍生效（JSON 文件），只是 Tag 不再更新 |
| Tag 策略的 Trie 索引按什么建？ | 按 Tag 名（如 PII/CONFIDENTIAL），不是按资源 |
| 同一资源被多个 Tag 命中怎么评估？ | 对每个 Tag 生成一个虚拟 TagAccessRequest，逐个评估，结果合并 |
| Tag 策略可以 Mask/Row Filter 吗？ | 可以！Tag Policy 也支持 DataMask 和 RowFilter 类型 |
| Plugin 首次启动无法连 Admin？ | 读取 `{appId}_{serviceName}_tag.json` 兜底（与 Policy 缓存逻辑一致） |

---

**文档版本**：v1.0
**更新时间**：2026-05-10
**Eric（豹纹）出品**
