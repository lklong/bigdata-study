# Ranger 策略鉴权链路源码深度解析（PolicyEngine + Evaluator）

> 版本: Ranger 2.x
> 源码路径: `/Users/kailongliu/bigdata/txProjects/ranger`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

Ranger 是大数据生态权限治理的事实标准，HDFS / Hive / HBase / Kafka / Trino 都用它。但要真正用好它，必须搞清楚：
- 一次 HDFS / Hive 操作怎么触发 Ranger 鉴权？流转路径是什么？
- Deny / Allow / 隐式拒绝是怎么混合评估的？为什么有时候 Deny 不生效？
- Ranger 策略优先级、Resource 匹配、Tag-based policy 怎么工作？
- Audit 日志在哪一步生成？为什么有时候 audit 缺失？

理解 PolicyEngine 链路是排查 "Ranger 鉴权不一致 / 策略不生效 / Audit 缺失 / 性能瓶颈" 的前置。

## 二、Ranger 整体架构

```
[业务请求]
HiveServer2 / HDFS NN / HBase RS / Trino ...
   │
   │ 嵌入 Ranger Plugin（同 JVM 内）
   ▼
RangerBasePlugin (e.g. RangerHdfsPlugin)
   │
   │ delegate to PolicyEngine
   ▼
RangerPolicyEngineImpl.evaluatePolicies(request, policyType)   ← 入口
   │
   ├── ① preProcess（注入用户的所有 group/role）
   ├── ② zoneAware：先匹配 Security Zone（多租户）
   ├── ③ Tag-based Evaluator 评估（基于资源 tag）
   ├── ④ Resource Evaluator 评估（基于路径/库/表）
   │   └── 每个 RangerDefaultPolicyEvaluator.evaluate()
   │       ├── matchType 计算（SELF / DESCENDANT / ANCESTOR / NONE）
   │       ├── matchPolicyCustomConditions（IP/时间/地理等动态条件）
   │       ├── isAuditEnabled → 标记 audit
   │       └── evaluatePolicyItems → ALLOW / DENY 决策
   ├── ⑤ ABAC 表达式评估（Policy condition）
   └── ⑥ 默认策略 / 兜底
   │
   ▼
RangerAccessResult (isAllowed=true/false, isAudited=true/false, ...)
   │
   │ 业务系统根据结果允许/拒绝操作
   ▼
RangerAccessResultProcessor.processResult
   │
   └── 写 Audit (Solr/HDFS/Kafka/log4j)
```

## 三、关键源码逐段精读

### 3.1 入口：RangerPolicyEngineImpl.evaluatePolicies

`RangerPolicyEngineImpl.java:123-164`：

```java
public RangerAccessResult evaluatePolicies(
        RangerAccessRequest request,
        int policyType,                                    // ACCESS / DATAMASK / ROW_FILTER
        RangerAccessResultProcessor resultProcessor) {
    if (LOG.isDebugEnabled()) {
        LOG.debug("==> RangerPolicyEngineImpl.evaluatePolicies(" + request +
                  ", policyType=" + policyType + ")");
    }

    RangerPerfTracer perf = null;
    if(RangerPerfTracer.isPerfTraceEnabled(PERF_POLICYENGINE_REQUEST_LOG)) {
        String requestHashCode = Integer.toHexString(System.identityHashCode(request))
                                 + "_" + policyType;
        perf = RangerPerfTracer.getPerfTracer(PERF_POLICYENGINE_REQUEST_LOG,
            "RangerPolicyEngine.evaluatePolicies(requestHashCode=" + requestHashCode + ")");
        LOG.info("RangerPolicyEngineImpl.evaluatePolicies(" + requestHashCode + ", " + request + ")");
    }

    requestProcessor.preProcess(request);                  // ① 预处理
    useRangerGroup(request);                                // ② 注入 Ranger 内部 group

    RangerAccessResult ret = zoneAwareAccessEvaluationWithNoAudit(request, policyType);  // ③ 核心评估

    if (resultProcessor != null) {
        RangerPerfTracer perfAuditTracer = null;
        if(RangerPerfTracer.isPerfTraceEnabled(PERF_POLICYENGINE_AUDIT_LOG)) {
            perfAuditTracer = RangerPerfTracer.getPerfTracer(...);
        }
        resultProcessor.processResult(ret);                 // ④ Audit 写入
        RangerPerfTracer.log(perfAuditTracer);
    }

    RangerPerfTracer.log(perf);
    if (LOG.isDebugEnabled()) {
        LOG.debug("<== RangerPolicyEngineImpl.evaluatePolicies(" + request +
                  ", policyType=" + policyType + "): " + ret);
    }
    return ret;
}
```

**四步关键流程**：
1. **preProcess**：把用户隶属的所有 group / role 注入到 request context（Ranger 拿不到 IDP，依赖 plugin 提供）
2. **useRangerGroup**：识别 Ranger 内部用户组（如 `public`），用于"对所有人生效"的策略匹配
3. **zoneAwareAccessEvaluationWithNoAudit**：核心评估，包含 zone 匹配 + tag policy + resource policy
4. **resultProcessor.processResult**：写 audit（Solr / HDFS / Kafka）

**性能追踪点**：
- `PERF_POLICYENGINE_REQUEST_LOG` —— 整个评估耗时
- `PERF_POLICYENGINE_AUDIT_LOG` —— audit 写入耗时（生产中如果 audit 后端慢，鉴权会被拖慢）

### 3.2 单条策略评估：RangerDefaultPolicyEvaluator.evaluate

`RangerDefaultPolicyEvaluator.java:218-278`：

```java
@Override
public void evaluate(RangerAccessRequest request, RangerAccessResult result) {
    if (LOG.isDebugEnabled()) {
        LOG.debug("==> RangerDefaultPolicyEvaluator.evaluate(policyId=" +
                  getPolicy().getId() + ", " + request + ", " + result + ")");
    }

    RangerPerfTracer perf = null;
    if(RangerPerfTracer.isPerfTraceEnabled(PERF_POLICY_REQUEST_LOG)) {
        perf = RangerPerfTracer.getPerfTracer(PERF_POLICY_REQUEST_LOG,
            "RangerPolicyEvaluator.evaluate(requestHashCode=" + ...);
    }

    if (request != null && result != null) {
        // ★ 短路优化：如果 access 和 audit 都已确定，跳过评估
        if (!result.getIsAccessDetermined() || !result.getIsAuditedDetermined()) {

            RangerPolicyResourceMatcher.MatchType matchType;
            // ① 计算 Match Type
            if (RangerTagAccessRequest.class.isInstance(request)) {
                matchType = ((RangerTagAccessRequest) request).getMatchType();
                if (matchType == RangerPolicyResourceMatcher.MatchType.ANCESTOR) {
                    matchType = RangerPolicyResourceMatcher.MatchType.SELF;
                }
            } else {
                matchType = resourceMatcher != null
                    ? resourceMatcher.getMatchType(request.getResource(), request.getContext())
                    : RangerPolicyResourceMatcher.MatchType.NONE;
            }

            // ② 根据 matchType + accessType 决定是否真的"匹配"
            final boolean isMatched;
            if (request.isAccessTypeAny()) {
                isMatched = matchType != RangerPolicyResourceMatcher.MatchType.NONE;
            } else if (request.getResourceMatchingScope()
                       == RangerAccessRequest.ResourceMatchingScope.SELF_OR_DESCENDANTS) {
                isMatched = matchType != RangerPolicyResourceMatcher.MatchType.NONE;
            } else {
                isMatched = matchType == RangerPolicyResourceMatcher.MatchType.SELF
                         || matchType == RangerPolicyResourceMatcher.MatchType.SELF_AND_ALL_DESCENDANTS;
            }

            if (isMatched) {
                // ③ 评估策略级别的自定义条件（IP / 时间 / 地理 / 自定义 Java condition）
                if (matchPolicyCustomConditions(request)) {

                    // ④ 设置 Audit 标志（注意：Audit 决策可以独立于 Access 决策）
                    if (!result.getIsAuditedDetermined()) {
                        if (isAuditEnabled()) {
                            result.setIsAudited(true);
                            result.setAuditPolicyId(getPolicy().getId());
                        }
                    }

                    // ⑤ 评估 PolicyItems（具体的 ALLOW/DENY 规则）
                    if (!result.getIsAccessDetermined()) {
                        if (hasMatchablePolicyItem(request)) {
                            evaluatePolicyItems(request, matchType, result);
                        }
                    }
                }
            }
        }
    }
    RangerPerfTracer.log(perf);
}
```

**核心要点（生产排障必懂）**：
- **Access Determined 与 Audit Determined 是两个独立标志**：Access 已经决策（allow/deny），Audit 仍可能未决（要继续找 audit policy）
- **短路优化**：两个标志都已确定时，直接跳过 —— 这是 Ranger 性能关键
- **Match 三种结果**：`SELF` / `DESCENDANT` / `ANCESTOR` / `NONE`，不同的 access 场景需要不同 match
- **Custom Conditions** 在 PolicyItem 之前评估 —— IP/时间限制不通过，根本不进 ALLOW/DENY 评估

### 3.3 PolicyItem 评估顺序 —— Ranger 鉴权的精髓

`RangerDefaultPolicyEvaluator.evaluatePolicyItems` 内部调用顺序（基于源码逻辑梳理）：

```
对每个匹配的 RangerPolicyEvaluator（按 evalOrder 排序）：

  ┌─────────────────────────────────────────────┐
  │ Step 1: Deny PolicyItems                    │
  │   → 命中即 result.setAccessDetermined(false) │
  │   → 不再评估其他 item                        │
  └─────────────────────────────────────────────┘
  ┌─────────────────────────────────────────────┐
  │ Step 2: Deny Exception PolicyItems          │
  │   → 推翻 Step 1 的 deny（即 deny 例外）      │
  └─────────────────────────────────────────────┘
  ┌─────────────────────────────────────────────┐
  │ Step 3: Allow PolicyItems                   │
  │   → 命中即 result.setAccessDetermined(true)  │
  └─────────────────────────────────────────────┘
  ┌─────────────────────────────────────────────┐
  │ Step 4: Allow Exception PolicyItems         │
  │   → 推翻 Step 3 的 allow（即 allow 例外）    │
  └─────────────────────────────────────────────┘
```

**评估顺序铁律**：**Deny 优先 + 双重例外**。这是 Ranger 区别于其他 ACL 系统的关键设计。

### 3.4 多策略评估：getResourceACLs 与策略优先级

`RangerPolicyEngineImpl.java:217-251`：

```java
allEvaluators.sort(RangerPolicyEvaluator.EVAL_ORDER_COMPARATOR);

if (CollectionUtils.isNotEmpty(allEvaluators)) {
    Integer policyPriority = null;

    for (RangerPolicyEvaluator evaluator : allEvaluators) {
        if (policyPriority == null) {
            policyPriority = evaluator.getPolicyPriority();
        }

        // ★ 优先级跳变 → 当前优先级的所有策略已评估完，"封盘"前面的 ACL
        if (policyPriority != evaluator.getPolicyPriority()) {
            ret.finalizeAcls();
            policyPriority = evaluator.getPolicyPriority();
        }

        RangerPolicyResourceMatcher.MatchType matchType = tagMatchTypeMap.get(evaluator.getId());
        if (matchType == null) {
            matchType = evaluator.getPolicyResourceMatcher()
                                 .getMatchType(request.getResource(), request.getContext());
        }

        final boolean isMatched;
        if (request.getResourceMatchingScope()
            == RangerAccessRequest.ResourceMatchingScope.SELF_OR_DESCENDANTS) {
            isMatched = matchType != RangerPolicyResourceMatcher.MatchType.NONE;
        } else {
            isMatched = matchType == RangerPolicyResourceMatcher.MatchType.SELF
                     || matchType == RangerPolicyResourceMatcher.MatchType.SELF_AND_ALL_DESCENDANTS;
        }
        ...
    }
}
```

**策略优先级（Policy Priority）的作用**：
- Ranger 支持给策略设置优先级（默认 NORMAL=0，可调 OVERRIDE=1）
- **高优先级先评估**，结果可以"封盘"低优先级的决策
- 用法：例外授权（一个白名单策略 priority=OVERRIDE 强制 ALLOW，覆盖其他 DENY）

### 3.5 UGI loginUserFromKeytab —— 与 Hadoop 安全的耦合点

虽然不在 Ranger 模块，但 Ranger 鉴权的"用户身份"来源于 Hadoop UGI。补一下入口：

`UserGroupInformation.java:1042-1071`（Hadoop）：

```java
static void loginUserFromKeytab(String user, String path) throws IOException {
    if (!isSecurityEnabled()) return;

    keytabFile = path;
    keytabPrincipal = user;
    Subject subject = new Subject();
    LoginContext login;
    long start = 0;
    try {
        login = newLoginContext(HadoopConfiguration.KEYTAB_KERBEROS_CONFIG_NAME,
                                 subject, new HadoopConfiguration());
        start = Time.now();
        login.login();                                 // ← 这里调 JAAS Krb5LoginModule
        metrics.loginSuccess.add(Time.now() - start);
        loginUser = new UserGroupInformation(subject);
        loginUser.setLogin(login);
        loginUser.setAuthenticationMethod(AuthenticationMethod.KERBEROS);
    } catch (LoginException le) {
        if (start > 0) metrics.loginFailure.add(Time.now() - start);
        throw new IOException("Login failure for " + user + " from keytab " + path + ": " + le, le);
    }
    LOG.info("Login successful for user " + keytabPrincipal +
             " using keytab file " + keytabFile);
}
```

**Ranger 拿到的 user**：通过 `UserGroupInformation.getCurrentUser().getShortUserName()` 取得，是 KDC 认证的 short name（如 `hive`）。

## 四、Ranger 评估完整流程图

```
RangerAccessRequest {
  resource: { database: "db1", table: "tbl1" }
  user: "alice"
  groups: ["analyst"]
  accessType: "select"
  context: { ip: "10.0.0.1" }
}
   │
   ▼
[Step 1] preProcess → 注入 alice 的 group/role
[Step 2] zoneAware → 匹配 default zone
[Step 3] Tag-based Evaluators
   │ 1. 找资源关联的 tag（如 PII）
   │ 2. 评估 tag policies
   │ 3. 设置 result if matched
   ▼
[Step 4] Resource-based Evaluators
   │ 1. 排序：按 evalOrder + policyPriority
   │ 2. 对每个 evaluator：
   │    a. matchType 计算
   │    b. matchPolicyCustomConditions
   │    c. evaluatePolicyItems：DENY → DENY_EXCEPT → ALLOW → ALLOW_EXCEPT
   │    d. 任一 step 决定 → result.setIsAccessDetermined(true)
   ▼
[Step 5] 返回 RangerAccessResult
   │ isAllowed: true/false
   │ isAudited: true/false
   │ policyId: 决定本次决策的策略 ID
   ▼
[Step 6] resultProcessor.processResult
   │ if (isAudited) writeAuditLog(...)
   ▼
返回业务系统
```

## 五、实战 LOG 对齐

| 日志关键词 | 出处 | 含义 |
|----------|------|------|
| `==> RangerPolicyEngineImpl.evaluatePolicies(...)` | `RangerPolicyEngineImpl.java:124` (DEBUG) | 进入评估 |
| `RangerPolicyEngineImpl.evaluatePolicies(<hash>, ...)` | `:135` (INFO) | 性能追踪开启时打 INFO |
| `==> RangerDefaultPolicyEvaluator.evaluate(policyId=X, ...)` | `RangerDefaultPolicyEvaluator.java:220` (DEBUG) | 单条策略评估 |
| `==> RangerDefaultPolicyEvaluator.isMatch(<resource>, ...)` | `:283` (DEBUG) | 资源匹配 |
| Audit 日志 (Solr/HDFS) | resultProcessor 实现 | `isAudited=true` 时写入 |

**故障排查公式**：
- 鉴权决策不对 → 开 `log4j.logger.org.apache.ranger=DEBUG`，看 evaluator 决策路径
- Audit 缺失 → 检查 audit policy 是否配；audit destination（Solr/HDFS）是否健康
- 鉴权慢 → `PERF_POLICYENGINE_REQUEST_LOG=DEBUG`，看哪个 evaluator 慢
- "公开"权限不生效 → 检查 `useRangerGroup` 是否把 `public` 加进了 user groups

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| Plugin 同 JVM 嵌入业务系统 | 鉴权是性能敏感操作，跨 RPC 不可接受 |
| PolicyEngine 双层缓存（PolicyDelta + 全量）| 支持热更新，定期 pull policy 不需要重启 |
| Tag-based + Resource-based 双轨制 | Tag 满足"按数据敏感级别分类"，Resource 满足"按物理位置授权" |
| Deny-First + 双重例外 | 平衡"安全默认 deny"和"灵活白名单"两个需求 |
| Match Type (SELF/DESCENDANT/ANCESTOR) | HDFS 路径需要 ANCESTOR 匹配（写 `/a/b/c` 需要 `/a` 的写权限）|
| Audit/Access 独立决策 | 监管要求：即使 access 决策有了（短路优化），audit 该写还得写 |
| Custom Conditions 可插拔 | 时间、IP、地理位置等动态条件，框架不预定义全部 |
| Eval Order + Policy Priority | 大量策略时性能可控，少量"高优先级覆盖"策略可前置 |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `ranger.plugin.<service>.policy.pollIntervalMs` | 30000 | 策略 pull 间隔（30s）|
| `ranger.plugin.<service>.policy.cache.dir` | /etc/ranger/.../cache | 策略本地缓存目录（admin 挂了也能跑）|
| `ranger.plugin.<service>.tag.policy.pollIntervalMs` | 60000 | tag 策略 pull 间隔 |
| `ranger.plugin.<service>.policy.rest.client.connection.timeoutMs` | 120000 | admin pull 连接超时 |
| `ranger.audit.solr.solr_url` / `audit.hdfs.config.destination.directory` | (无) | Audit 目的地 |
| `xasecure.audit.destination.solr.batch.filespool.dir` | (本地) | Audit 离线 spool 目录 |
| `xasecure.audit.is.enabled` | true | 全局 audit 开关 |
| `ranger.plugin.<service>.policy.source.impl` | RangerAdminRESTClient | 策略来源（也可以 LocalFile）|

## 八、踩坑记录

1. **Deny 不生效** —— 90% 是 Allow Exception 把 Deny 推翻了。**应对**：检查 deny policy 的 priority 是否够高，或者用 deny exception。
2. **Audit 暴增打爆 Solr** —— Hive 高频小查询，每次都写 audit。**应对**：开 `xasecure.audit.solr.async.queue.size=10240` 缓冲，调大 batch；或者用 HDFS audit + Kafka 异步。
3. **策略加载延迟** —— 改了策略，等 30s 才生效。**应对**：调小 `pollIntervalMs`（注意频繁拉会压垮 admin），或者用 `Reload Policy` API 主动通知。
4. **Plugin Cache 缓存陈旧** —— admin 挂了，plugin 用 30 分钟前的缓存。**应对**：`policy.cache.dir` 是兜底，但不是越久越好；监控 `ranger.plugin.last.policy.update.time` metrics。
5. **ANCESTOR 匹配遗忘** —— HDFS 写 `/a/b/c.parquet` 但只配了 `/a/b/c.parquet` 的 write 策略，结果 NN 鉴权 `/a/b` 的 writeAccess 失败。**应对**：父目录至少有 `_any_` 权限；或者用 SELF_OR_DESCENDANTS 范围。
6. **getResourceACLs 性能差** —— 被 Hive `SHOW PERMISSIONS` 高频触发。`PERF_POLICYENGINE_GET_ACLS_LOG` 看耗时。**应对**：减少 SHOW 频率或上 caching。
7. **Tag-based policy 不生效** —— 资源没有同步 Atlas tag，或 Atlas 与 Ranger sync 有延迟。**应对**：检查 `ranger.plugin.atlas.tagsync.zookeeper.connect` 连接。
8. **MatchType ANCESTOR 错误** —— 自定义 RangerAccessRequest 时 matchType 设错，导致父目录策略被当 SELF 匹配。**应对**：参考 `RangerTagAccessRequest` 的处理逻辑。

## 九、认知更新

- **Audit 决策与 Access 决策是两条独立路径**：之前以为 access 决策出来 audit 就跟着出，**实际上是两个独立标志**，分别决定。即使 access 已经命中 deny，audit 仍可能由另一条策略决定要不要写日志。
- **短路优化机制**：`!result.getIsAccessDetermined() || !result.getIsAuditedDetermined()` 是核心 —— 双标志都"已决"时直接跳过后续策略。**理解这点才能解释"前面策略命中，后面策略不评估"的现象**。
- **Match Type 不止 SELF/NONE 两种**：还有 `DESCENDANT`（请求资源是策略资源的子节点）、`ANCESTOR`（请求资源是策略资源的祖先节点）、`SELF_AND_ALL_DESCENDANTS`。HDFS 路径权限大量用 ANCESTOR 匹配。
- **PolicyPriority 是真实存在的**：之前以为 Ranger 没有优先级，所有策略平等。**实际上 OVERRIDE 优先级会前置评估并"封盘"低优先级**（`finalizeAcls()`），这是高级用法。
- Ranger 的 `useRangerGroup` 把 `public` 加进 group 列表，所以"公开权限"实际上是 `public` 这个 Ranger 内置 group 的权限，**不是 LDAP 里的 public**。

## 十、下一步深挖方向

- [ ] DataMask / RowFilter 策略类型的评估特殊性
- [ ] Tag-based policy 与 Atlas 的 tagsync 协议
- [ ] Policy Delta 增量更新机制（避免每次拉全量）
- [ ] RangerPolicyEvaluator 的 `evalOrder` 计算（如何决定策略评估顺序）
- [ ] Conditional Macros / ABAC 表达式引擎（JS / Custom Conditions）

---

**沉淀完成。Ranger 鉴权评估"Deny-First + 双重例外"四步顺序、Match Type 体系、Audit/Access 独立决策机制源码精确对齐。**
