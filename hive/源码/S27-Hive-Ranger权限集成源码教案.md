# [教案] Hive-Ranger权限集成源码深度剖析

> 🎯 教学目标：掌握Hive V2授权框架(HiveAuthorizer)的插件化架构、Ranger集成的鉴权流程、行级过滤与列脱敏的SQL改写机制  
> ⏰ 预计学时：3学时  
> 📊 难度：⭐⭐⭐⭐（中高级）

---

## 一、课前导入（生活类比引入）

### 1.1 生活类比：机场安检系统

想象一个国际机场的安检流程：
- **身份验证（Authentication）**：出示护照确认"你是谁" → Kerberos
- **权限检查（Authorization）**：检查签证决定"你能去哪" → Ranger Policy
- **行李过滤（Row Filter）**：特定物品不允许带出国境 → 行级过滤
- **信息脱敏（Column Masking）**：护照号只显示后4位 → 列脱敏

### 1.2 生产故障场景

```
用户报错：Permission denied: user [analyst] does not have [SELECT] privilege on [db.sensitive_table]
但管理员确认Ranger中已授权 → 权限不生效

根因排查方向：
1. Ranger策略同步延迟（Plugin缓存未刷新）
2. HiveServer2未正确加载RangerHiveAuthorizer
3. 策略优先级冲突（deny > allow）
4. 行级过滤/列脱敏导致SQL改写后语法错误
```

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 含义 | 类比 |
|------|------|------|
| HiveAuthorizer | V2授权接口（插件化） | 安检标准接口 |
| HiveAuthorizerImpl | 默认实现（策略模式） | 标准安检流程 |
| HiveAccessController | 权限管理接口(GRANT/REVOKE) | 签证管理处 |
| HiveAuthorizationValidator | 权限验证接口(checkPrivileges) | 安检员 |
| applyRowFilterAndColumnMasking | 行过滤/列脱敏 | 行李检查 |
| HiveOperationType | 操作类型枚举(SELECT/INSERT...) | 出行目的 |
| HivePrivilegeObject | 权限对象(表/列/DB) | 目的地 |
| SessionHook | 会话级拦截 | 入境登记 |
| SemanticHook | 语义分析拦截 | 行程审核 |

### 2.2 Hive V2授权架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hive V2 Authorization Framework               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌────────────────────────────────────────────────────┐        │
│  │              HiveAuthorizer (接口)                  │        │
│  │  ├─ grantPrivileges() / revokePrivileges()         │        │
│  │  ├─ checkPrivileges()  ←── 核心鉴权方法            │        │
│  │  ├─ filterListCmdObjects()  ←── SHOW过滤           │        │
│  │  ├─ applyRowFilterAndColumnMasking() ←── 行列改写  │        │
│  │  └─ needTransform() ←── 是否需要改写              │        │
│  └───────────────────────┬────────────────────────────┘        │
│                          │ implements                            │
│  ┌───────────────────────▼────────────────────────────┐        │
│  │          HiveAuthorizerImpl (委托模式)              │        │
│  │  ├─ HiveAccessController   → 权限管理(DDL)         │        │
│  │  └─ HiveAuthorizationValidator → 权限验证(DML)     │        │
│  └───────────────────────┬────────────────────────────┘        │
│                          │ Ranger实现                            │
│  ┌───────────────────────▼────────────────────────────┐        │
│  │        RangerHiveAuthorizer (Ranger Plugin)        │        │
│  │  ├─ RangerHiveAccessController                     │        │
│  │  ├─ RangerHiveAuthorizationValidator               │        │
│  │  ├─ 策略缓存 + 定期从Ranger Admin同步              │        │
│  │  └─ 行过滤/列脱敏表达式生成                        │        │
│  └────────────────────────────────────────────────────┘        │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  调用入口：                                                      │
│  1. Driver.doAuthorization() → checkPrivileges()                │
│  2. SemanticAnalyzer → applyRowFilterAndColumnMasking()         │
│  3. SHOW命令 → filterListCmdObjects()                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 HiveAuthorizer接口核心方法

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/security/authorization/plugin/HiveAuthorizer.java`

```java
// 第49-283行：V2授权核心接口
@LimitedPrivate(value = { "Apache Argus (incubating)" })
@Evolving
public interface HiveAuthorizer {

    // === 权限管理(DDL) ===
    void grantPrivileges(List<HivePrincipal>, List<HivePrivilege>, 
        HivePrivilegeObject, HivePrincipal grantorPrincipal, boolean grantOption);
    void revokePrivileges(...);
    void createRole(String roleName, HivePrincipal adminGrantor);
    void dropRole(String roleName);
    
    // === 权限验证(DML) ===
    // 核心鉴权方法：检查用户对输入/输出对象的操作权限
    void checkPrivileges(
        HiveOperationType hiveOpType,      // 操作类型：SELECT/INSERT/DDL...
        List<HivePrivilegeObject> inputsHObjs,  // 输入对象（读取的表/列）
        List<HivePrivilegeObject> outputHObjs,  // 输出对象（写入的表）
        HiveAuthzContext context            // 授权上下文（SQL文本等）
    ) throws HiveAuthzPluginException, HiveAccessControlException;
    
    // === 对象过滤 ===
    // SHOW TABLES/DATABASES时过滤无权限的对象
    List<HivePrivilegeObject> filterListCmdObjects(
        List<HivePrivilegeObject> listObjs, HiveAuthzContext context);
    
    // === 行过滤 & 列脱敏 ===
    // 是否需要对查询进行安全改写
    boolean needTransform();
    
    // 返回需要行过滤/列脱敏的对象列表（带改写表达式）
    List<HivePrivilegeObject> applyRowFilterAndColumnMasking(
        HiveAuthzContext context, List<HivePrivilegeObject> privObjs)
        throws SemanticException;
    
    // === 配置策略 ===
    void applyAuthorizationConfigPolicy(HiveConf hiveConf);
}
```

### 3.2 HiveAuthorizerImpl委托实现

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/security/authorization/plugin/HiveAuthorizerImpl.java`

```java
// 第35-150行：策略模式 - 委托给Controller和Validator
public class HiveAuthorizerImpl extends AbstractHiveAuthorizer {
    HiveAccessController accessController;      // 管理权限（GRANT/REVOKE）
    HiveAuthorizationValidator authValidator;    // 验证权限（CHECK）

    public HiveAuthorizerImpl(HiveAccessController accessController, 
                              HiveAuthorizationValidator authValidator) {
        this.accessController = accessController;
        this.authValidator = authValidator;
    }

    @Override
    public void checkPrivileges(HiveOperationType hiveOpType, 
        List<HivePrivilegeObject> inputHObjs,
        List<HivePrivilegeObject> outputHObjs, HiveAuthzContext context) {
        // 委托给validator
        authValidator.checkPrivileges(hiveOpType, inputHObjs, outputHObjs, context);
    }

    @Override
    public List<HivePrivilegeObject> filterListCmdObjects(...) {
        return authValidator.filterListCmdObjects(listObjs, context);
    }

    @Override
    public boolean needTransform() {
        return authValidator.needTransform();
    }

    @Override
    public List<HivePrivilegeObject> applyRowFilterAndColumnMasking(
        HiveAuthzContext context, List<HivePrivilegeObject> privObjs) {
        return authValidator.applyRowFilterAndColumnMasking(context, privObjs);
    }
    
    @Override
    public void applyAuthorizationConfigPolicy(HiveConf hiveConf) {
        // Ranger利用此方法注入安全配置
        accessController.applyAuthorizationConfigPolicy(hiveConf);
    }
}
```

**设计模式解析**：
- **策略模式**：将"权限管理"和"权限验证"分离为两个策略接口
- **委托模式**：HiveAuthorizerImpl不做任何逻辑，纯委托
- **插件化**：Ranger只需实现AccessController + Validator即可接入

### 3.3 HivePrivilegeObject：权限对象模型

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/security/authorization/plugin/HivePrivilegeObject.java`

```java
public class HivePrivilegeObject implements Comparable<HivePrivilegeObject> {
    public enum HivePrivilegeObjectType {
        DATABASE, TABLE_OR_VIEW, PARTITION, 
        LOCAL_URI, DFS_URI, COMMAND_PARAMS,
        FUNCTION, SERVICE_NAME, COLUMN
    }
    
    private final HivePrivilegeObjectType type;
    private final String dbname;
    private final String objectName;           // 表名
    private final List<String> partKeys;       // 分区列
    private final List<String> columns;        // 涉及的列
    private String rowFilterExpression;        // 行过滤表达式（Ranger填充）
    private List<String> cellValueTransformers; // 列脱敏表达式（Ranger填充）
    
    // Ranger鉴权后填充以下字段：
    public void setRowFilterExpression(String expr) { ... }
    public void setCellValueTransformers(List<String> transformers) { ... }
}
```

### 3.4 行过滤与列脱敏的SQL改写流程

#### 3.4.1 改写触发时机

```
SQL提交 → Parser → SemanticAnalyzer.analyzeInternal()
    │
    ├── needTransform() == true?
    │       │
    │       ▼ YES
    │   applyRowFilterAndColumnMasking(context, privObjs)
    │       │
    │       ▼ Ranger返回带表达式的privObjs
    │   对每个表：
    │       ├── rowFilterExpression != null → 添加WHERE子句
    │       └── cellValueTransformers != null → 替换SELECT列
    │
    └── 继续后续优化
```

#### 3.4.2 行过滤改写示例

```sql
-- 原始SQL
SELECT name, salary FROM employees;

-- Ranger策略：用户analyst只能看自己部门的数据
-- rowFilterExpression = "dept_id = current_user_dept()"

-- 改写后（SemanticAnalyzer自动注入）
SELECT name, salary FROM (
    SELECT * FROM employees WHERE dept_id = current_user_dept()
) employees;
```

#### 3.4.3 列脱敏改写示例

```sql
-- 原始SQL
SELECT name, phone, ssn FROM customers;

-- Ranger策略：
-- phone列 → MASK_SHOW_LAST_4: cellValueTransformer = "mask_show_last_n(phone, 4)"
-- ssn列 → MASK: cellValueTransformer = "'***-**-****'"

-- 改写后
SELECT name, mask_show_last_n(phone, 4) as phone, '***-**-****' as ssn 
FROM customers;
```

### 3.5 HiveOperationType：操作类型枚举

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/security/authorization/plugin/HiveOperationType.java`

```java
public enum HiveOperationType {
    // DML操作
    QUERY,              // SELECT
    LOAD,               // LOAD DATA
    EXPORT,             // EXPORT TABLE
    IMPORT,             // IMPORT TABLE
    
    // DDL操作
    CREATETABLE,        // CREATE TABLE
    DROPTABLE,          // DROP TABLE
    ALTERTABLE_ADDCOLS, // ALTER TABLE ADD COLUMNS
    ALTERTABLE_REPLACECOLS,
    ALTERTABLE_RENAME,
    ALTERTABLE_DROPPARTS,
    ALTERTABLE_ADDPARTS,
    ALTERTABLE_LOCATION,
    
    // Admin操作
    CREATEDATABASE,
    DROPDATABASE,
    SWITCHDATABASE,
    CREATEFUNCTION,
    DROPFUNCTION,
    
    // Show操作
    SHOWTABLES,
    SHOWDATABASES,
    SHOWCOLUMNS,
    
    // ... 更多操作类型
}
```

### 3.6 Ranger集成的初始化流程

#### 配置入口

```xml
<!-- hive-site.xml -->
<property>
    <name>hive.security.authorization.enabled</name>
    <value>true</value>
</property>
<property>
    <name>hive.security.authorization.manager</name>
    <value>org.apache.ranger.authorization.hive.authorizer.RangerHiveAuthorizerFactory</value>
</property>
<property>
    <name>hive.security.authenticator.manager</name>
    <value>org.apache.hadoop.hive.ql.security.SessionStateUserAuthenticator</value>
</property>
```

#### 初始化时序

```
HS2启动
  │
  ├── HiveSessionImpl.open()
  │     └── setupAuth() 
  │           └── HiveAuthorizerFactory.createHiveAuthorizer()
  │                 └── RangerHiveAuthorizerFactory.createHiveAuthorizer()
  │                       ├── new RangerHivePlugin(serviceName)
  │                       │     ├── init() → 从Ranger Admin下载策略
  │                       │     └── startPolicyRefreshThread() → 定期同步
  │                       ├── new RangerHiveAccessController(plugin)
  │                       └── new RangerHiveAuthorizationValidator(plugin)
  │
  └── 每次SQL执行
        ├── Driver.doAuthorization()
        │     └── authorizer.checkPrivileges(opType, inputs, outputs, ctx)
        │           └── RangerHiveAuthorizationValidator.checkPrivileges()
        │                 └── plugin.isAccessAllowed(request) → 查本地策略缓存
        │
        └── SemanticAnalyzer
              ├── authorizer.needTransform() → true
              └── authorizer.applyRowFilterAndColumnMasking()
                    └── 从策略中提取行过滤/列脱敏表达式
```

### 3.7 调用链时序图

```
┌────────┐  ┌──────────┐  ┌────────────────┐  ┌──────────────┐  ┌───────────┐
│ Client │  │ HiveServer2│  │SemanticAnalyzer│  │HiveAuthorizer│  │RangerPlugin│
└───┬────┘  └─────┬─────┘  └───────┬────────┘  └──────┬───────┘  └─────┬─────┘
    │             │                │                   │                │
    │──SQL───────▶│                │                   │                │
    │             │──parse/analyze─▶│                   │                │
    │             │                │                   │                │
    │             │                │──needTransform()──▶│                │
    │             │                │◀──true────────────│                │
    │             │                │                   │                │
    │             │                │──applyRowFilter───▶│──getPolicy()──▶│
    │             │                │   AndColumnMasking │◀──filter/mask──│
    │             │                │◀──modified privObjs│                │
    │             │                │                   │                │
    │             │                │──inject WHERE/mask │                │
    │             │                │                   │                │
    │             │──doAuthorize───▶│                   │                │
    │             │                │──checkPrivileges──▶│──isAllowed()──▶│
    │             │                │                   │◀──allow/deny───│
    │             │                │◀──pass/exception──│                │
    │             │                │                   │                │
    │◀──result────│                │                   │                │
```

---

## 四、生产实战案例

### 4.1 案例一：权限生效延迟

**现象**：Ranger Admin已添加策略，但Hive查询仍报Permission denied

**排障**：
```bash
# 1. 检查策略同步间隔
grep "ranger.plugin.hive.policy.pollIntervalMs" /etc/hive/conf/ranger-hive-security.xml
# 默认30秒

# 2. 强制刷新缓存
# 方法1：重启HS2
# 方法2：等待pollInterval到期
# 方法3：调用Ranger Admin的刷新API

# 3. 检查HS2日志
grep "RangerHivePlugin" /var/log/hive/hiveserver2.log | grep -i "policy"
# 确认策略下载成功

# 4. 检查策略优先级
# Ranger中 deny策略 > allow策略
# 检查是否有deny策略覆盖了allow
```

### 4.2 案例二：列脱敏导致查询失败

**现象**：`SELECT * FROM table WHERE phone = '13800138000'` 报错

**根因**：phone列被脱敏为`mask_show_last_n(phone,4)`，WHERE中引用原始列 vs SELECT中的脱敏列冲突

**解决**：Ranger策略中确保WHERE条件中的列不会被脱敏，或调整查询方式。

### 4.3 参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hive.security.authorization.enabled` | false | 授权总开关 |
| `hive.security.authorization.manager` | - | Authorizer工厂类 |
| `ranger.plugin.hive.policy.pollIntervalMs` | 30000 | 策略同步间隔(ms) |
| `ranger.plugin.hive.policy.cache.dir` | /etc/ranger/hive/policycache | 策略缓存目录 |
| `hive.security.authorization.sqlstd.confwhitelist` | - | SQL标准模式白名单 |
| `hive.server2.enable.doAs` | true | 是否代理用户执行 |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：Hive V1和V2授权有什么区别？**

A：V1(HiveAuthorizationProvider)基于POSIX权限模型，只检查表级权限，无法做列级/行级控制。V2(HiveAuthorizer)是插件化架构，支持：
- 列级权限控制
- 行级过滤
- 列脱敏
- 对象过滤（SHOW命令）
- 第三方插件（Ranger/Sentry）

**Q2：行过滤和列脱敏在哪个阶段注入SQL？对执行计划有何影响？**

A：在SemanticAnalyzer阶段注入：
- 行过滤：将原表包装为子查询 + WHERE条件 → 产生额外的Filter算子
- 列脱敏：替换SELECT中的列表达式 → 产生额外的Project算子
影响：可能阻止分区裁剪、列裁剪优化。

**Q3：如果Ranger Admin宕机，Hive查询还能正常工作吗？**

A：能。Ranger Plugin本地缓存了策略（`policy.cache.dir`），Admin宕机时使用本地缓存鉴权。但新策略无法同步下来。

### 5.2 思考题

1. 如果需要实现"某用户只能查询最近7天的数据"，如何用Ranger行级过滤实现？
2. 列脱敏和数据加密的区别是什么？各自适用于什么场景？
3. 如何设计一个审计系统，记录所有被Ranger拒绝的访问请求？

---

## 六、知识晶体（一页纸总结）

```
┌────────────────────────────────────────────────────────────────┐
│          Hive-Ranger 权限集成核心知识晶体                       │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  接口层：HiveAuthorizer (V2)                                   │
│    ├── checkPrivileges() → 操作级鉴权                          │
│    ├── filterListCmdObjects() → SHOW过滤                       │
│    ├── applyRowFilterAndColumnMasking() → 行列安全改写          │
│    └── needTransform() → 是否启用改写                          │
│                                                                │
│  实现层：HiveAuthorizerImpl（策略+委托模式）                     │
│    ├── HiveAccessController → GRANT/REVOKE管理                 │
│    └── HiveAuthorizationValidator → 运行时鉴权                 │
│                                                                │
│  Ranger层：RangerHivePlugin                                    │
│    ├── 策略同步：Admin → 本地缓存（pollInterval=30s）           │
│    ├── 鉴权逻辑：deny > allow > 默认deny                      │
│    └── 安全改写：行过滤表达式 + 列脱敏函数                      │
│                                                                │
│  调用链：SQL → Analyzer → needTransform → applyFilter →        │
│         Driver.doAuthorization → checkPrivileges → 执行        │
│                                                                │
│  生产关键：                                                     │
│  • 策略同步延迟（30s窗口）                                      │
│  • 本地缓存保障Admin宕机时可用                                   │
│  • 行过滤可能阻止分区裁剪优化                                   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/security/authorization/plugin/`
2. Apache Ranger源码：`ranger-hive-plugin/`
3. HIVE-5155: Authorization plugin framework
4. HIVE-12756: Row/Column level filtering
5. Ranger官方文档：https://ranger.apache.org/
