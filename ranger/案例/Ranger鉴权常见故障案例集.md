# Ranger 鉴权常见故障案例集

> **用途**：大数据运维工程师排障速查手册。每个案例包含**现象 → 根因 → 证据定位 → 处置方案**四段式结构。
> **源码依据**：本手册所有结论均有对应 Ranger 源码证据，非猜测。

---

## 案例索引

| 分类 | 案例 | 紧急度 |
|-----|------|-------|
| **策略不生效** | [案例1：用户明明有策略却被 DENY](#案例1) | 🔴 |
| **策略不生效** | [案例2：新建策略迟迟不生效](#案例2) | 🔴 |
| **策略不生效** | [案例3：Policy Delta 版本号对不上](#案例3) | 🟡 |
| **缓存问题** | [案例4：Ranger Admin 重启后 Plugin 拒绝所有请求](#案例4) | 🔴 |
| **缓存问题** | [案例5：PolicyCache 无限增长](#案例5) | 🟡 |
| **Tag 问题** | [案例6：Atlas 打标后 Tag 策略不触发](#案例6) | 🟡 |
| **Mask/Filter** | [案例7：Row Filter 返回全量数据](#案例7) | 🔴 |
| **Mask/Filter** | [案例8：Mask 列 UDF 不存在报错](#案例8) | 🟡 |
| **性能问题** | [案例9：鉴权 RPC 延迟突增](#案例9) | 🔴 |
| **性能问题** | [案例10：策略数量膨胀导致 OOM](#案例10) | 🔴 |
| **Zone 问题** | [案例11：Security Zone 策略失效](#案例11) | 🟡 |
| **审计问题** | [案例12：审计日志缺失](#案例12) | 🟡 |

---

## <a id="案例1"></a>案例1：用户明明有策略却被 DENY

### 现象
- 用户 `alice` 被授予 `SELECT db1.user` 权限
- Ranger UI 上策略可见，状态 Enabled
- 实际查询报错：`Permission denied: user=alice, access=SELECT on TABLE:db1.user`

### 根因分析

**优先级由高到低排查**：

#### 根因 A：Deny 策略覆盖

```
评估顺序（RangerPolicyEngineImpl:541）：
  ① Tag 策略（可强制 DENY）
  ② Resource 策略
       ├── 先评估 deny policy items
       └── 后评估 allow policy items
  
  一旦命中任一 DENY，且无更高优先级的 ALLOW → 最终 DENY
```

**定位**：
```bash
# 开启 Debug 日志
grep "Result after:" /var/log/hive/hiveserver2.log | grep "alice"

# 查看具体命中了哪条策略
# 日志片段：
# Result after: evaluator-id=[501], isAllowed=false, isDenied=true, policyId=501, ...
```

**处置**：登 Ranger UI → Policy 501 → 检查 Deny Conditions

#### 根因 B：Condition 表达式不满足

```json
{
  "conditions": [
    {"type": "accessTime", "values": ["09:00-18:00"]},
    {"type": "ipAddress",  "values": ["10.0.0.0/8"]}
  ]
}
```

**定位**：检查策略的 `conditions` 字段，对照用户当前的 IP / 时间。

#### 根因 C：用户组映射未生效

Ranger 依赖 `UserGroupSync` 或 Hadoop 的 UGI：
```
用户 alice 应该属于 analytics 组
  ↓
但 HiveServer2 内部的 UGI.getGroupNames() 返回空
  ↓
策略命中条件 group=analytics 失败 → DENY
```

**定位**：
```bash
# 在 HiveServer2 节点执行
id alice
hdfs groups alice

# Ranger Admin 执行
curl -u admin:... http://ranger-admin:6080/service/xusers/users/alice/groups
```

**处置**：触发 UserGroupSync 强制同步 或 检查 LDAP/AD 配置

#### 根因 D：Policy Priority 冲突

```
Policy A (priority=0, ALLOW) + Policy B (priority=1, DENY)
→ B 优先级高，最终 DENY
```

**定位**：Ranger UI 过滤所有命中当前资源的策略，检查 `policyPriority` 字段。

---

## <a id="案例2"></a>案例2：新建策略迟迟不生效

### 现象
- 在 Ranger UI 新建策略 PolicyID=1234
- 保存成功，但过了 5 分钟用户执行 SQL 还是提示无权限

### 根因分析

#### 根因 A：PolicyRefresher 轮询周期（默认 30s）

```java
// PolicyRefresher.java:97
this.pollingIntervalMs = pluginConfig.getLong(
    propertyPrefix + ".policy.pollIntervalMs", 30 * 1000);
```

**定位**：Plugin 下次拉取策略前不生效。

**处置**：
```bash
# 方式1：等待 30s
# 方式2：重启 HiveServer2 立即生效
systemctl restart hive-server2

# 方式3：调小轮询间隔（ranger-hive-security.xml）
<property>
  <name>ranger.plugin.hive.policy.pollIntervalMs</name>
  <value>5000</value>  <!-- 5秒 -->
</property>
```

#### 根因 B：策略版本号回退（版本错乱）

```java
// PolicyRefresher.java:306
svcPolicies = rangerAdmin.getServicePoliciesIfUpdated(
    lastKnownVersion,   // Plugin 已知版本
    lastActivationTimeInMillis);

// Admin 端判断：自 lastKnownVersion 以来有变化吗？
//   - 有变化 → 返回 ServicePolicies
//   - 无变化 → 返回 null
```

**现象**：数据库中 policyVersion 被人手动改过，Plugin 内存中 version 反而更高。

**定位**：
```sql
-- Ranger Admin 端
SELECT service_id, policy_version FROM x_service_version_info;
SELECT MAX(id) FROM x_policy_change_log WHERE service_id = ?;
```

**处置**：
```sql
-- 强制版本号 +1
UPDATE x_service_version_info
SET policy_version = policy_version + 100
WHERE service_id = ?;
```

#### 根因 C：Tag 策略需要等 TagRefresher 拉取

Tag 策略由独立的 `RangerTagRefresher` 拉取（默认 60s），比 PolicyRefresher 慢。

**定位**：
```bash
grep "RangerTagRefresher" /var/log/hive/hiveserver2.log | tail -20
```

---

## <a id="案例3"></a>案例3：Policy Delta 版本号对不上

### 现象
- 日志反复出现：`ServicePolicies contain both policies and policy-deltas!!`
- 随后：`Keeping old policy-engine!`

### 根因

```java
// RangerPolicyDeltaUtil.java:185-189
if (isPoliciesExist && isPolicyDeltasExist) {
    LOG.warn("ServicePolicies contain both policies and policy-deltas!!");
    ret = null;  // ← 返回 null，上层保持旧引擎
}
```

**Admin 端 Bug 或缓存错乱**导致同时下发了全量 policies 和增量 deltas，Plugin 判断为内部不一致，丢弃本次更新。

### 处置

```bash
# 方式1：强制触发 Admin 全量重算
curl -X POST -u admin:... http://ranger-admin:6080/service/admin/policies/reset

# 方式2：重启 Ranger Admin
systemctl restart ranger-admin

# 方式3：清除某个 service 的 change log
DELETE FROM x_policy_change_log WHERE service_id = ? AND id < ?;
```

---

## <a id="案例4"></a>案例4：Ranger Admin 重启后 Plugin 拒绝所有请求

### 现象
- Ranger Admin 维护重启了 30 分钟
- 期间所有 HiveServer2 上的查询都被拒绝
- Admin 恢复后仍未自动恢复

### 根因分析

#### 重点：回顾 loadPolicy 流程

```java
// PolicyRefresher.java:229-289
ServicePolicies svcPolicies = loadPolicyfromPolicyAdmin();  // 失败 → null

if (svcPolicies == null) {
    if (!policiesSetInPlugin) {        // ← 关键！
        svcPolicies = loadFromCache();
    }
}
```

#### 场景分析

```
场景A：Plugin 在 Admin 重启前已成功加载过策略
  → policiesSetInPlugin = true
  → 内存中有旧策略
  → 即使 Admin 挂了，鉴权继续工作 ✓

场景B：Plugin 首次启动时 Admin 就挂了
  → policiesSetInPlugin = false
  → 走 loadFromCache()
  → 本地文件存在 → 用文件里的策略 ✓
  → 本地文件不存在 → setPolicies(null) → 鉴权全 DENY ✗
```

### 定位

```bash
# ① 检查 Plugin 是否加载了策略
grep "policiesSetInPlugin\|setPolicies" /var/log/hive/hiveserver2.log | tail -20

# ② 检查本地缓存文件
ls -la /etc/ranger/hive2/cache/hive2_hive_cluster.json

# ③ 检查日志中是否有 "cache file does not exist"
grep "cache file does not exist" /var/log/hive/hiveserver2.log
```

### 处置

```bash
# 应急方案1：临时禁用 Ranger
# hive-site.xml
<property>
  <name>hive.security.authorization.enabled</name>
  <value>false</value>
</property>
# 重启 HiveServer2

# 应急方案2：从其他正常节点拷贝缓存文件
scp hive-node-healthy:/etc/ranger/hive2/cache/hive2_*.json /etc/ranger/hive2/cache/
# 重启 HiveServer2

# 应急方案3：从 Ranger Admin 数据库手动导出策略
curl -u admin:... "http://ranger-admin:6080/service/plugins/policies/download/hive_cluster" \
  > /etc/ranger/hive2/cache/hive2_hive_cluster.json
```

### 预防

1. **Ranger Admin 必须高可用**（至少 2 节点 + VIP）
2. **Plugin 启动前预热缓存**：滚动重启前确保本地 cache 文件存在
3. **监控缓存文件 mtime**：超过 5 分钟未更新告警

---

## <a id="案例5"></a>案例5：PolicyCache 无限增长

### 现象
- HiveServer2 内存从 8GB 涨到 16GB
- Heap dump 显示 `RangerPolicyRepository` 占用 5GB+
- 重启后又会慢慢涨回来

### 根因分析

#### 根因 A：策略数量真的很多

```sql
-- Admin 端检查
SELECT service_name, COUNT(*) as policy_count
FROM x_policy p JOIN x_service s ON p.service_id = s.id
GROUP BY service_name
ORDER BY policy_count DESC;

-- 正常：单服务 < 5000
-- 异常：单服务 > 20000
```

**处置**：合并冗余策略 / 使用 Tag 策略替代重复的资源策略

#### 根因 B：accessAuditCache 泄漏

```java
// RangerPolicyRepository.java:137
this.accessAuditCache = Collections.synchronizedMap(
    new CacheMap<String, AuditInfo>(auditResultCacheSize));
```

`auditResultCacheSize` 默认较大，如果鉴权请求的 resource 组合多样化，缓存无限增长。

**处置**：
```xml
<!-- 限制审计缓存大小 -->
<property>
  <name>ranger.plugin.hive.policyengine.option.cache.audit.results</name>
  <value>2048</value>  <!-- 默认 64k，建议 2k-8k -->
</property>
```

#### 根因 C：Trie 索引膨胀

如果策略中大量使用通配符：
```
P1: database=*, table=*, column=* → 1条策略 → Trie 索引所有节点
P2: database=db1_*, ...             → 正则匹配，慢
```

**处置**：避免 `*` 通配符，使用更精确的资源路径

---

## <a id="案例6"></a>案例6：Atlas 打标后 Tag 策略不触发

### 现象
- Atlas 上给 `db1.user.id_card` 打了 `PII` 标签
- Ranger 上有 `tag=PII, Mask(MASK_SHOW_LAST_4)` 策略
- 用户查询 id_card 列仍然返回原值，未脱敏

### 根因排查清单

#### 检查1：Plugin 是否加载了 TagEnricher

```bash
grep "RangerTagEnricher.init" /var/log/hive/hiveserver2.log

# 如果没有 → 配置问题
# 期望日志：==> RangerTagEnricher.init()
```

**配置检查**（ranger-hive-security.xml）：
```xml
<property>
  <name>ranger.plugin.hive.tag.retriever.classname</name>
  <value>org.apache.ranger.plugin.contextenricher.RangerAdminTagRetriever</value>
</property>
```

#### 检查2：Tag 缓存文件是否更新

```bash
ls -la /etc/ranger/hive2/cache/hive2_hive_cluster_tag.json
# 检查 mtime，应该每 60s 内被更新
stat /etc/ranger/hive2/cache/hive2_hive_cluster_tag.json
```

#### 检查3：Atlas → Ranger Tag Sync 是否正常

```bash
# Tag Sync Service 日志
tail -100 /var/log/ranger/tagsync/tagsync.log | grep -E "ERROR|WARN"

# 检查 Kafka 消费位点
/usr/hdp/current/kafka-broker/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka:9092 \
  --describe --group ranger_entities_consumer

# Ranger Admin 端查 Tag 数据
curl -u admin:... \
  "http://ranger-admin:6080/service/tags/service/hive_cluster/tags"
```

#### 检查4：Policy 类型是否匹配

```
POLICY_TYPE_ACCESS=0    (普通访问)
POLICY_TYPE_DATAMASK=1  (Mask)  ← 本案例需要这个
POLICY_TYPE_ROWFILTER=2 (RowFilter)
```

**常见错误**：在 Ranger UI 上建了 "Access Policy" 而非 "Masking Policy"。

#### 检查5：Propagate 传播设置

Atlas 打标时如果 `propagate=false`，则标签只在当前实体生效，不传播到列。

**排查**：
```bash
# Atlas API 查 classification
curl -u admin:... \
  "http://atlas-server:21000/api/atlas/v2/entity/guid/{guid}"

# 看 "propagate": true/false
```

---

## <a id="案例7"></a>案例7：Row Filter 返回全量数据

### 现象
- 配置了 Row Filter：`dept = 'finance'`
- 用户 `alice` 执行 `SELECT * FROM hr.employee`
- 返回结果包含所有部门，未过滤

### 根因分析

#### 根因 A：Hive 版本不支持

```java
// RangerHiveAuthorizer.java:1150
// 依赖 HiveAuthorizer API
public List<HivePrivilegeObject> applyRowFilterAndColumnMasking(
    HiveAuthzContext context,
    List<HivePrivilegeObject> hiveObjs);
```

此 API 需要 **Hive 2.1+**。老版本 Hive 根本不会调用这个方法。

**定位**：
```bash
hive --version
# 小于 2.1 → 不支持
```

#### 根因 B：SQL 未经过 SemanticAnalyzer

某些场景 SQL 直接走 MetaStore API（如 Spark 直接读取 Hive 表），绕过 HiveServer2 → 不触发 Ranger 重写。

**处置**：
- Spark 端使用 Kyuubi + RangerSparkExtension
- 或通过 HiveServer2 统一入口

#### 根因 C：filterExpr 为空字符串

```java
// RangerHiveAuthorizer.java:1240
private boolean isRowFilterEnabled(RangerAccessResult result) {
    return result != null
        && result.isRowFilterEnabled()
        && StringUtils.isNotEmpty(result.getFilterExpr());  // ← 非空判断
}
```

Ranger UI 上 filterExpr 填了空格或空字符串，被视为无效。

---

## <a id="案例8"></a>案例8：Mask 列 UDF 不存在报错

### 现象

```
FAILED: SemanticException No matching method for class
org.apache.hadoop.hive.ql.udf.generic.GenericUDFMaskShowLastN
```

### 根因

Mask 依赖 Hive 内置 UDF：

| Mask 类型 | UDF |
|----------|-----|
| `MASK` | `mask(col, ...)` |
| `MASK_SHOW_LAST_4` | `mask_show_last_n(col, 4, ...)` |
| `MASK_SHOW_FIRST_4` | `mask_show_first_n(col, 4, ...)` |
| `MASK_HASH` | `sha2(col, 256)` |

需要 Hive 2.1+ 且开启 security UDF。

### 处置

```xml
<!-- hive-site.xml -->
<property>
  <name>hive.security.authorization.manager</name>
  <value>org.apache.ranger.authorization.hive.authorizer.RangerHiveAuthorizerFactory</value>
</property>
<property>
  <name>hive.security.mask.authorization.udf</name>
  <value>true</value>
</property>
```

验证 UDF：
```sql
DESCRIBE FUNCTION mask_show_last_n;
-- 期望输出函数签名
```

---

## <a id="案例9"></a>案例9：鉴权 RPC 延迟突增

### 现象
- HiveServer2 上 SQL 执行 P99 从 100ms 涨到 5s
- 日志中大量 `PolicyEngine.evaluatePolicies()` 耗时 > 1s
- Ranger Admin 监控显示 CPU 不高

### 关键定位：**鉴权不走 Ranger Admin！**

回顾源码（RangerBasePlugin.java:382）：
```java
public RangerAccessResult isAccessAllowed(RangerAccessRequest request, ...) {
    RangerPolicyEngine policyEngine = this.policyEngine;
    if (policyEngine != null) {
        ret = policyEngine.evaluatePolicies(request, ...);  // ← 纯内存！
    }
}
```

**所以慢的不是网络，而是本地计算**。

### 根因排查

#### 根因 A：Trie 索引退化

```bash
# 开启性能日志
# hive-log4j2.properties
logger.ranger.name = org.apache.ranger.plugin.util.RangerPerfTracer
logger.ranger.level = DEBUG

# 过滤慢日志
grep "resourcetrie.retrieval" /var/log/hive/ranger-perf.log | awk '$NF > 100'
```

**常见原因**：
- 策略中使用复杂正则（`policyResources.resource.isExcludes=true`）
- 策略数 > 50000，Trie 节点爆炸

#### 根因 B：accessAuditCache 锁竞争

```java
// RangerPolicyRepository.java:137
this.accessAuditCache = Collections.synchronizedMap(new CacheMap<...>(size));
//                                    ↑ 同步 Map，高并发下锁冲突
```

**定位**：
```bash
# 线程 dump
jstack <hive-server2-pid> | grep -A 5 "accessAuditCache"
# 大量线程 BLOCKED 在 CacheMap.put
```

**处置**：
```xml
<!-- 减小缓存避免锁竞争 -->
<property>
  <name>ranger.plugin.hive.policyengine.option.cache.audit.results</name>
  <value>1024</value>
</property>
```

#### 根因 C：ContextEnricher 耗时

```java
// RangerPolicyEngineImpl.java:139
requestProcessor.preProcess(request);  // ← 调用所有 Enricher
```

`RangerTagEnricher.enrich()` 内部做 `findMatchingTags()`，如果 ServiceResource 数量庞大（几十万），这里会慢。

**处置**：关闭不用的 Enricher：
```xml
<property>
  <name>ranger.plugin.hive.contextenrichers.disabled</name>
  <value>TagEnricher</value>  <!-- 不需要 Tag 可以关 -->
</property>
```

---

## <a id="案例10"></a>案例10：策略数量膨胀导致 OOM

### 现象
- HiveServer2 OOM：`java.lang.OutOfMemoryError: Java heap space`
- Heap dump 显示 50% 内存被 `List<RangerPolicyEvaluator>` 占用

### 根因

每个策略 = 1 个 PolicyEvaluator 对象（含所有 PolicyItem、ResourceMatcher 等）：
- 平均每个 Evaluator 约 5-50KB
- 50000 条策略 × 20KB = 1GB

如果同时有 3 种策略类型（Access/Mask/RowFilter）：
- 最坏情况：50000 × 20KB × 3 = 3GB

### 定位

```bash
# Admin 端查每个 service 的策略数
curl -u admin:... "http://ranger-admin:6080/service/plugins/policies/count"

# 或 SQL
SELECT s.name, COUNT(*) as cnt
FROM x_policy p JOIN x_service s ON p.service_id = s.id
GROUP BY s.name HAVING COUNT(*) > 10000;
```

### 处置

#### 方案 A：合并冗余策略

```
原：
  P1: db=db1, table=tbl1, user=alice, SELECT
  P2: db=db1, table=tbl2, user=alice, SELECT
  P3: db=db1, table=tbl3, user=alice, SELECT
  ... (100 条)

合并为：
  P1: db=db1, table=*, user=alice, SELECT
```

#### 方案 B：用 Tag 策略替代

```
原：10000 条 PII 列各自的 Mask 策略

改为：
  1 条 Tag 策略：tag=PII → Mask(SHA256)
  + Atlas 给 10000 列打 PII 标签
```

#### 方案 C：垂直拆分服务

一个庞大的 service → 拆成按业务域的多个 service：
- `hive_finance` / `hive_marketing` / `hive_engineering`

#### 方案 D：增加 JVM 堆

```bash
# hive-env.sh
export HADOOP_HEAPSIZE=8192  # 最后兜底方案
```

---

## <a id="案例11"></a>案例11：Security Zone 策略失效

### 现象
- 在 Zone `zone_hr` 下建了策略
- 资源 `hr.employee` 绑定了 zone_hr
- 查询时策略不生效，走的是 default zone 策略

### 根因排查

#### 根因 A：资源未命中 Zone

```java
// RangerPolicyEngineImpl.java:474
Set<String> zoneNames = policyEngine.getMatchedZonesForResourceAndChildren(request.getResource());
```

Zone 匹配通过 `resourceZoneTrie` 实现，如果资源定义不精确则命中不到。

**定位**：
```bash
# 开 Debug 日志
grep "zoneNames:" /var/log/hive/hiveserver2.log

# 期望看到：zoneNames:[zone_hr]
# 实际看到：zoneNames:[]
```

#### 根因 B：Zone 定义与资源匹配规则不一致

```
Zone 定义：database=hr, table=*
实际查询：database=hr, table=employee

匹配规则：
  - Zone Trie 按资源层级匹配
  - 如果 zone 定义缺少某层资源 → 不匹配
```

#### 根因 C：Zone 关联的 User/Admin 未包含查询用户

Zone 有自己的 "Zone Admin" 和 "Zone User" 列表，不在列表里的用户即使查询命中 Zone 也无法受益。

**定位**：Ranger UI → Security Zone → zone_hr → Admin Users / Admin Groups

---

## <a id="案例12"></a>案例12：审计日志缺失

### 现象
- Ranger UI 的 Audit 页面看不到 Hive 查询记录
- Solr 中也没数据

### 根因排查

#### 根因 A：AuditMode 配置为 NONE

```java
// RangerPolicyRepository
public enum AuditModeEnum { AUDIT_ALL, AUDIT_NONE, AUDIT_DEFAULT }
```

**定位**：
```xml
<!-- ranger-hive-audit.xml -->
<property>
  <name>xasecure.audit.is.enabled</name>
  <value>true</value>  <!-- 必须 true -->
</property>
```

#### 根因 B：Solr/Elasticsearch 连接失败

```bash
grep "AuditProviderFactory" /var/log/hive/hiveserver2.log | tail -20

# 检查 Audit 队列堆积
grep "AuditAsyncQueue" /var/log/hive/hiveserver2.log
```

#### 根因 C：审计缓存去重导致丢失

```java
// RangerPolicyRepository:137
// accessAuditCache 会对相同 request 的结果缓存，短时间内同样的请求不重复审计
```

**定位**：策略开启了 `isAuditEnabled=false` → 完全不审计。

---

## 故障排查通用流程图

```
用户反馈 Ranger 问题
        │
        ▼
┌─────────────────────────────────────────┐
│ 1. 收集基本信息                          │
│   - 用户、资源、动作                      │
│   - 时间戳                              │
│   - 错误消息                            │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────┐
│ 2. 开启 Debug 日志                       │
│ log4j: org.apache.ranger=DEBUG          │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────┐
│ 3. 复现问题 → 抓日志                      │
│   grep "user=xxx" hiveserver2.log       │
└─────────────────────────────────────────┘
        │
        ▼
┌──────────────────┐
│ 策略是否命中？    │
└──────────────────┘
    │        │
   YES       NO
    │        │
    ▼        ▼
┌────────┐  ┌─────────────────────┐
│ Deny   │  │ 检查 Plugin 是否加载  │
│ 或条件  │  │ 了最新策略            │
│ 不满足  │  │  - lastKnownVersion │
└────────┘  │  - cache file mtime │
           │  - policyVersion    │
           └─────────────────────┘
                    │
                    ▼
           ┌─────────────────────┐
           │ 检查 Admin 端策略     │
           │  - UI 可见？          │
           │  - DB 中 enabled=Y？ │
           └─────────────────────┘
```

---

## 实用排查工具箱

### 工具 1：开启全链路 Debug

```xml
<!-- hive-log4j2.properties -->
logger.ranger.name = org.apache.ranger
logger.ranger.level = DEBUG

logger.ranger_perf.name = org.apache.ranger.plugin.util.RangerPerfTracer
logger.ranger_perf.level = DEBUG

logger.ranger_audit.name = org.apache.ranger.audit
logger.ranger_audit.level = DEBUG
```

### 工具 2：查询策略命中情况

```bash
# 提取某用户的所有鉴权日志
grep 'RangerHiveAuthorizer' /var/log/hive/hiveserver2.log | \
  grep 'user=alice' | \
  tail -100

# 查看具体命中的 policyId
grep 'matchedPolicy=' /var/log/hive/hiveserver2.log | \
  awk -F'matchedPolicy=' '{print $2}' | \
  awk -F',' '{print $1}' | sort | uniq -c
```

### 工具 3：查看 Plugin 状态

```bash
# Plugin 向 Admin 汇报的状态
curl -u admin:... \
  "http://ranger-admin:6080/service/plugins/info"

# 输出示例：
# {
#   "hostname": "hive-node-1",
#   "appType": "hive2",
#   "pluginCapabilities": ...,
#   "infoMap": {
#     "lastPolicyDownloadTime": "2026-05-10 09:30:00",
#     "lastPolicyActivationTime": "2026-05-10 09:30:05",
#     "latestPolicyVersion": 47
#   }
# }
```

### 工具 4：直接查策略 JSON

```bash
# 从 Admin 下载某服务的策略
curl -u admin:... \
  "http://ranger-admin:6080/service/plugins/policies/download/hive_cluster?lastKnownVersion=0" \
  | jq '.policies[] | select(.id==1234)'
```

---

**文档版本**：v1.0
**更新时间**：2026-05-10
**Eric（豹纹）出品**
