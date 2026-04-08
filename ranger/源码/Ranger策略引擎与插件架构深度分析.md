# Apache Ranger 策略引擎与插件架构深度分析

> Ranger Expert 补课学习 — 统一授权管理核心

## 一、Ranger 架构总览

```
┌──────────────────────────────────────────────────────┐
│                    Ranger Admin                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │ Policy    │  │ Audit    │  │ User/Group Sync  │   │
│  │ Manager   │  │ Store    │  │ (LDAP/AD/Unix)   │   │
│  └──────────┘  └──────────┘  └──────────────────┘   │
└────────────┬─────────────────────────────────────────┘
             │ REST API (策略下发)
    ┌────────┼────────┬────────────┐
    ↓        ↓        ↓            ↓
┌────────┐┌────────┐┌────────┐┌──────────┐
│ HDFS   ││ Hive   ││ HBase  ││ Kafka    │
│ Plugin ││ Plugin ││ Plugin ││ Plugin   │
└────────┘└────────┘└────────┘└──────────┘
    ↕        ↕        ↕            ↕
┌────────┐┌────────┐┌────────┐┌──────────┐
│ HDFS   ││ HS2    ││ HBase  ││ Kafka    │
│ NameNode│ Server ││ Master ││ Broker   │
└────────┘└────────┘└────────┘└──────────┘
```

## 二、策略引擎核心

### 2.1 策略模型

```json
{
  "policyType": 0,  // 0=Access, 1=Masking, 2=RowFilter
  "service": "hive_prod",
  "resources": {
    "database": {"values": ["analytics"], "isRecursive": false},
    "table":    {"values": ["user_events"], "isRecursive": false},
    "column":   {"values": ["*"], "isRecursive": false}
  },
  "policyItems": [
    {
      "users": ["analyst_team"],
      "groups": ["data_analysts"],
      "accesses": [
        {"type": "select", "isAllowed": true},
        {"type": "update", "isAllowed": false}
      ],
      "conditions": [
        {"type": "ip-range", "values": ["10.0.0.0/8"]}
      ]
    }
  ],
  "denyPolicyItems": [...],
  "denyExceptions": [...]
}
```

### 2.2 策略评估顺序

```
请求进入 Ranger Plugin:

1. 检查 Deny 策略 (最高优先级)
   ├ 命中 Deny → 检查 Deny Exception
   │              ├ 命中 Exception → 继续
   │              └ 未命中 → DENIED ❌
   └ 未命中 → 继续

2. 检查 Allow 策略
   ├ 命中 Allow → ALLOWED ✅
   └ 未命中 → 继续

3. 检查 Public Group (默认策略)
   ├ 命中 → ALLOWED ✅
   └ 未命中 → 继续

4. Fallback 到组件原生权限 (如 HDFS ACL)
   ├ 允许 → ALLOWED ✅
   └ 拒绝 → DENIED ❌

口诀: Deny 优先, Allow 其次, 默认拒绝
```

### 2.3 策略引擎源码

```java
// RangerDefaultPolicyEvaluator.java
public RangerAccessResult evaluate(RangerAccessRequest request) {
    // 1. 资源匹配
    if (!isMatch(request.getResource(), policy.getResources())) {
        return null;  // 不匹配此策略
    }
    
    // 2. Deny 检查
    if (matchDenyPolicy(request)) {
        if (!matchDenyException(request)) {
            return DENIED;
        }
    }
    
    // 3. Allow 检查
    if (matchAllowPolicy(request)) {
        return ALLOWED;
    }
    
    return null;  // 此策略无决定
}

// RangerPolicyEngineImpl.java
public RangerAccessResult evaluatePolicies(RangerAccessRequest request) {
    // 遍历所有策略，按优先级排序
    for (RangerPolicyEvaluator evaluator : policyEvaluators) {
        RangerAccessResult result = evaluator.evaluate(request);
        if (result != null) {
            return result;  // 第一个匹配的策略决定结果
        }
    }
    return getDefaultResult();  // 无策略匹配 → 默认拒绝
}
```

## 三、Plugin 架构

### 3.1 Plugin 工作机制

```
Plugin 嵌入到各组件进程内（非独立进程）:

HDFS NameNode 进程:
  ├── NameNode 核心逻辑
  ├── Ranger HDFS Plugin (通过 Java SPI 加载)
  │   ├── PolicyRefresher — 定期从 Ranger Admin 拉取最新策略
  │   ├── PolicyEngine — 本地策略评估（无需每次 RPC 到 Admin）
  │   └── AuditHandler — 审计日志发送
  └── ...

关键设计:
  - 策略本地缓存: Plugin 缓存策略到本地文件，即使 Admin 挂了也能鉴权
  - 增量更新: 只拉取上次之后变更的策略
  - 异步审计: 审计日志异步批量发送，不阻塞请求
```

### 3.2 Plugin 配置示例（Hive）

```xml
<!-- ranger-hive-security.xml -->
<property>
  <name>ranger.plugin.hive.service.name</name>
  <value>hive_prod</value>
</property>
<property>
  <name>ranger.plugin.hive.policy.rest.url</name>
  <value>http://ranger-admin:6080</value>
</property>
<property>
  <name>ranger.plugin.hive.policy.pollIntervalMs</name>
  <value>30000</value>  <!-- 30秒拉取一次策略 -->
</property>
<property>
  <name>ranger.plugin.hive.policy.cache.dir</name>
  <value>/etc/ranger/hive/policycache</value>
</property>
```

## 四、数据脱敏与行过滤

### 4.1 Column Masking（列脱敏）

```
策略类型: policyType = 1

支持的脱敏方式:
  - MASK:           "张三" → "x三"
  - MASK_SHOW_LAST_4: "13812345678" → "xxxxxxx5678"
  - MASK_HASH:      "secret" → "5ebe2294..."
  - MASK_NULL:      任意值 → NULL
  - CUSTOM:         自定义 UDF

实现原理:
  Hive Plugin 改写 SQL:
    原始: SELECT name, phone FROM users
    改写: SELECT mask(name), mask_show_last_4(phone) FROM users
```

### 4.2 Row-Level Filter（行过滤）

```
策略类型: policyType = 2

示例: 用户只能看自己部门的数据
  Filter: dept_id = {USER.dept}

实现原理:
  Hive Plugin 改写 SQL:
    原始: SELECT * FROM employees
    改写: SELECT * FROM employees WHERE dept_id = 'engineering'
```

## 五、运维实战

### 5.1 常见问题

```
问题1: 策略不生效
  排查: 
    - 检查 Plugin 是否正确加载: grep "ranger" hive-server2.log
    - 检查策略拉取: grep "PolicyRefresher" hive-server2.log
    - 本地策略缓存: cat /etc/ranger/hive/policycache/*.json | jq
  解决:
    - 确认 service name 一致
    - 手动触发策略刷新: curl ranger-admin:6080/service/plugins/policies/download/hive_prod

问题2: 审计日志丢失
  排查:
    - 检查 Solr/ES 是否可达
    - 检查审计队列: grep "AuditQueue" 日志
  解决:
    - 增大审计 batch size 和 queue size
    - 确保 Solr/ES 集群健康

问题3: Plugin 导致服务启动慢
  原因: 首次启动拉取大量策略
  解决: 
    - 预热策略缓存文件
    - 减少无用策略数量
```

### 5.2 安全最佳实践

```
1. 最小权限原则: 默认 Deny，按需 Allow
2. 用 Group 而不是 User 授权: 便于管理
3. 定期审计: 检查异常访问模式
4. 策略版本控制: Ranger 支持策略导出/导入
5. 多级审批: 敏感数据的策略变更需要审批流
```

---

*Ranger Expert 学习产出 | 2026-04-08 | 补课：策略引擎与插件架构*
