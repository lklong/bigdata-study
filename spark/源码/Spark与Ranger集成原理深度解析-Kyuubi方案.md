# Spark 与 Ranger 集成原理深度解析（Submarine vs Kyuubi）

> **核心命题**：Spark 不像 Hive 那样有现成的 `HiveAuthorizer` 接口，Ranger 官方 spark-plugin（Submarine）方案存在性能/功能短板。Apache Kyuubi 通过 `kyuubi-spark-authz` 扩展，利用 Spark 的 `SparkSessionExtensions` 注入 Optimizer/Resolution Rule，把鉴权深度嵌入 Catalyst 优化器，成为生产级首选方案。

---

## 一、为什么 Spark + Ranger 这么难

### 1.1 Hive 与 Spark 的鉴权架构差异

| 维度 | Hive | Spark |
|-----|------|-------|
| 鉴权接口 | `HiveAuthorizer`（标准接口） | 无内置接口 |
| SQL 解析 | Hive 自己的 SemanticAnalyzer | Catalyst 优化器 |
| 注入点 | `applyRowFilterAndColumnMasking()` 钩子 | 需通过 `SparkSessionExtensions` 注入 Rule |
| 元数据 | HMS（HiveMetaStore） | DataSource V1/V2、Catalog V2 |
| 用户上下文 | UGI + Hive Session | SparkContext + 自定义 |

### 1.2 集成挑战

```
挑战1：Spark SQL 入口不统一
  ├── spark-sql CLI
  ├── PySpark / SparkR
  ├── DataFrame API（df.write.saveAsTable）
  ├── Spark Thrift Server
  └── Structured Streaming
  
  → 任何一个入口绕过都是漏洞

挑战2：Spark Catalog V2 + 多 DataSource
  ├── Hive Catalog
  ├── Iceberg Catalog
  ├── Delta Lake
  └── 自定义 DataSource
  
  → 资源路径需要动态解析

挑战3：DataMask/RowFilter 实现
  ├── Hive 直接用 UDF（mask_show_last_n）
  └── Spark 需要把 Mask 表达式转成 Catalyst Expression 注入逻辑计划
```

---

## 二、三种主流集成方案对比

### 2.1 方案概览

| 方案 | 来源 | 状态 | 推荐度 |
|-----|------|------|-------|
| **Submarine（Ranger 官方 spark-plugin）** | Ranger 项目 | 维护中但功能有限 | ⭐⭐ |
| **Apache Kyuubi (kyuubi-spark-authz)** | Kyuubi 项目 | 活跃，生产可用 | ⭐⭐⭐⭐⭐ |
| **OPA (Open Policy Agent)** | 第三方 | 通用方案，与 Ranger 平行 | ⭐⭐⭐ |

### 2.2 详细对比

| 能力 | Submarine | Kyuubi-Authz | OPA |
|-----|-----------|--------------|-----|
| 表/列级鉴权 | ✅ | ✅ | ✅ |
| Row Filter | ⚠️ 仅部分 | ✅ 完整 | ✅ |
| Data Mask | ⚠️ 仅部分 | ✅ 完整 | ✅ |
| Spark Streaming | ❌ | ✅ | ✅ |
| Catalog V2 (Iceberg) | ❌ | ✅ | ⚠️ |
| Tag 策略 | ⚠️ 部分 | ✅ | 需自实现 |
| 性能 | 一般（解析慢） | 好 | 很好（缓存机制） |
| 社区活跃度 | 低 | 高 | 高 |
| 生产案例 | 较少 | 滴滴/网易/B 站等 | Netflix 等 |

---

## 三、Kyuubi-Spark-Authz 架构

### 3.1 核心入口（RangerSparkExtension.scala 完整源码）

```scala
// extensions/spark/kyuubi-spark-authz/.../ranger/RangerSparkExtension.scala
class RangerSparkExtension extends (SparkSessionExtensions => Unit) {
  // 启动时初始化 Plugin（只执行一次）
  SparkRangerAdminPlugin.initialize()

  override def apply(v1: SparkSessionExtensions): Unit = {
    // ① CheckRule：早期校验，防止用户绕过 Authz
    v1.injectCheckRule(AuthzConfigurationChecker)

    // ② Resolution Rules：在 Logical Plan 解析阶段注入
    v1.injectResolutionRule(_ => RuleReplaceShowObjectCommands)        // SHOW 命令权限过滤
    v1.injectResolutionRule(_ => RuleApplyPermanentViewMarker)          // 永久视图标记
    v1.injectResolutionRule(_ => RuleApplyTypeOfMarker)                // typeof 标记
    v1.injectResolutionRule(RuleApplyRowFilter)                          // ★ Row Filter 注入
    v1.injectResolutionRule(RuleApplyDataMaskingStage0)                 // ★ Data Mask 注入 Stage 0
    v1.injectResolutionRule(RuleApplyDataMaskingStage1)                 // ★ Data Mask 注入 Stage 1

    // ③ Optimizer Rules：在优化阶段执行鉴权和清理
    v1.injectOptimizerRule(_ => RuleEliminateMarker)
    v1.injectOptimizerRule(RuleAuthorization)                            // ★ 真正的鉴权动作
    v1.injectOptimizerRule(RuleEliminatePermanentViewMarker)
    v1.injectOptimizerRule(_ => RuleEliminateTypeOf)

    // ④ Planner Strategy：DataSource V2 过滤
    v1.injectPlannerStrategy(FilterDataSourceV2Strategy)
  }
}
```

### 3.2 启用配置

```bash
# spark-defaults.conf
spark.sql.extensions=org.apache.kyuubi.plugin.spark.authz.ranger.RangerSparkExtension

# 或命令行
spark-sql --conf spark.sql.extensions=org.apache.kyuubi.plugin.spark.authz.ranger.RangerSparkExtension
```

---

## 四、Catalyst 集成的核心思想

### 4.1 Spark SQL 执行流程

```
SQL 文本
   │
   ▼
┌──────────────────────┐
│ Parser              │  → Unresolved LogicalPlan
└──────────────────────┘
   │
   ▼
┌──────────────────────┐
│ Analyzer (Resolver)  │  ← Kyuubi 注入 RuleApplyRowFilter / RuleApplyDataMaskingStage0/1
│                      │     (在 Resolution Rules 阶段把策略转换成 Filter/Project 节点)
└──────────────────────┘
   │
   ▼
┌──────────────────────┐
│ Optimizer            │  ← Kyuubi 注入 RuleAuthorization
│                      │     (在 Optimizer 末尾真正调用 Ranger 鉴权)
└──────────────────────┘
   │
   ▼
┌──────────────────────┐
│ Planner             │  ← Kyuubi 注入 FilterDataSourceV2Strategy
└──────────────────────┘
   │
   ▼
┌──────────────────────┐
│ Physical Plan        │
└──────────────────────┘
```

### 4.2 RuleAuthorization — 鉴权核心

```scala
// 简化逻辑
object RuleAuthorization extends Rule[LogicalPlan] {
  override def apply(plan: LogicalPlan): LogicalPlan = {
    val privileges = PrivilegeExtractor.extractPrivileges(plan)
    
    // 转换为 Ranger 的 AccessRequest
    val requests = privileges.flatMap(buildAccessRequest)
    
    // 调用 SparkRangerAdminPlugin.verify
    SparkRangerAdminPlugin.verify(requests, auditHandler)
    
    plan
  }
}
```

### 4.3 RuleApplyRowFilter — 行级过滤

```scala
// 简化逻辑
object RuleApplyRowFilter extends Rule[LogicalPlan] {
  override def apply(plan: LogicalPlan): LogicalPlan = {
    plan.transformDown {
      case h: HiveTableRelation =>
        val req = AccessRequest.forRowFilter(h.tableMeta, currentUser)
        SparkRangerAdminPlugin.getFilterExpr(req) match {
          case Some(filterExpr) =>
            // 把 Filter 注入到逻辑计划：相当于 SELECT * FROM t WHERE <filterExpr>
            val parsedExpr = parseExpression(filterExpr)
            Filter(parsedExpr, h)
          case None => h
        }
    }
  }
}
```

**核心点**：和 Hive 不同，Spark 是把 **filter 表达式 parse 成 Catalyst Expression** 后**直接拼入逻辑计划**，无需 SQL 文本重写。

---

## 五、SparkRangerAdminPlugin — 复用 Ranger Java SDK

### 5.1 类继承关系

```scala
// SparkRangerAdminPlugin.scala:30
object SparkRangerAdminPlugin extends RangerBasePlugin("spark", "sparkSql")
  with RangerConfigProvider {
```

继承自 Ranger 官方 `RangerBasePlugin`，**完全复用 Java SDK 的 PolicyRefresher / PolicyEngine / PolicyCache 机制**。

### 5.2 Plugin 初始化

```scala
// 行 67-70
def initialize(): Unit = {
  this.init()                        // 调用 RangerBasePlugin.init()
  registerCleanupShutdownHook(this)   // 注册 JVM 关闭钩子
}

private def registerCleanupShutdownHook(plugin: RangerBasePlugin): Unit = {
  ShutdownHookManager.get().addShutdownHook(() => {
    if (plugin != null) {
      LOG.info(s"clean up ranger plugin, appId: ${plugin.getAppId}")
      plugin.cleanup()
      plugin.getAuditProviderFactory.shutdown()
    }
  }, Integer.MAX_VALUE)
}
```

**关键**：因为 `extends RangerBasePlugin`，所以会自动启动 `PolicyRefresher` 后台线程，按 30s 轮询拉取策略到内存。

### 5.3 鉴权批量调用（行144-173）

```scala
def verify(
    requests: Seq[RangerAccessRequest],
    auditHandler: SparkRangerAuditHandler): Unit = {
  if (requests.nonEmpty) {
    // ★ 批量鉴权：一次调用多个 request
    val results = SparkRangerAdminPlugin.isAccessAllowed(requests.asJava, auditHandler)

    if (results != null) {
      val indices = results.asScala.zipWithIndex.filter { case (result, idx) =>
        result != null && !result.getIsAllowed
      }.map(_._2)

      if (indices.nonEmpty) {
        val user = requests.head.getUser
        val accessTypeToResource =
          indices.foldLeft(LinkedHashMap.empty[String, ArrayBuffer[String]])((m, idx) => {
            val req = requests(idx)
            val accessType = req.getAccessType
            val resource = req.getResource.getAsString
            m.getOrElseUpdate(accessType, ArrayBuffer.empty[String])
              .append(resource)
            m
          })
        // 抛出包含所有失败资源的异常
        val errorMsg = accessTypeToResource.map { case (accessType, resources) =>
          s"[$accessType] ${resources.mkString("privilege on [", ",", "]")}"
        }.mkString(", ")
        throw new AccessControlException(
          s"Permission denied: user [$user] does not have $errorMsg")
      }
    }
  }
}
```

**对比 Hive**：Hive 是逐个 `HivePrivilegeObject` 调用 `isAccessAllowed`，Kyuubi 一次性批量调用，性能更好。

---

## 六、Data Mask 实现细节（getMaskingExpr）

### 6.1 Hive vs Spark 的 Mask 差异

```
Hive 端：
  Ranger 返回 transformer 模板（含 {col} 占位符）
  → Hive 把模板替换 {col} 后填入 SQL
  → 依赖 Hive 内置 UDF（mask_show_last_n）

Spark 端：
  Ranger 返回的 transformer 不能直接用（Spark 没有 mask_show_last_n UDF）
  → Kyuubi 自己实现转换：用 Spark 内置函数 regexp_replace + concat 模拟
```

### 6.2 完整源码（SparkRangerAdminPlugin.scala:95-128）

```scala
def getMaskingExpr(req: AccessRequest): Option[String] = {
  val col = req.getResource.asInstanceOf[AccessResource].getColumn
  val result = evalDataMaskPolicies(req, null)

  Option(result).filter(_.isMaskEnabled).map { res =>
    if ("MASK_NULL".equalsIgnoreCase(res.getMaskType)) {
      "NULL"

    } else if ("CUSTOM".equalsIgnoreCase(result.getMaskType)) {
      val maskVal = res.getMaskedValue
      if (maskVal == null) "NULL"
      else s"${maskVal.replace("{col}", col)}"

    } else if (result.getMaskTypeDef != null) {
      result.getMaskTypeDef.getName match {
        case "MASK"             => regexp_replace(col)
        case "MASK_SHOW_FIRST_4" => regexp_replace(col, hasLen = true)
        case "MASK_SHOW_LAST_4" =>
          val left = regexp_replace(s"left($col, length($col) - 4)")
          s"concat($left, right($col, 4))"
        case "MASK_HASH"          => s"md5(cast($col as string))"
        case "MASK_DATE_SHOW_YEAR" => s"date_trunc('YEAR', $col)"
        case _ => result.getMaskTypeDef.getTransformer match {
            case transformer if transformer != null && transformer.nonEmpty =>
              s"${transformer.replace("{col}", col)}"
            case _ => null
          }
      }
    } else null
  }
}

// 用 regexp_replace 模拟 Hive 的 mask 函数
private def regexp_replace(expr: String, hasLen: Boolean = false): String = {
  val pos = if (hasLen) ", 5" else ""
  val upper  = s"regexp_replace($expr, '[A-Z]', 'X'$pos)"
  val lower  = s"regexp_replace($upper, '[a-z]', 'x'$pos)"
  val digits = s"regexp_replace($lower, '[0-9]', 'n'$pos)"
  val other  = s"regexp_replace($digits, '[^A-Za-z0-9]', 'U'$pos)"
  other
}
```

### 6.3 转换示例

| Mask 类型 | Hive UDF | Kyuubi 转换 |
|----------|---------|-------------|
| `MASK` | `mask(col)` | `regexp_replace(...)` 4层嵌套 |
| `MASK_SHOW_LAST_4` | `mask_show_last_n(col, 4)` | `concat(regexp_replace(left(col, length(col)-4)), right(col, 4))` |
| `MASK_HASH` | `sha2(col, 256)` | `md5(cast(col as string))` |
| `MASK_DATE_SHOW_YEAR` | `mask(...)` | `date_trunc('YEAR', col)` |

---

## 七、UserStore 增强（高级特性）

### 7.1 UserStore 是什么

Ranger 2.1+ 引入 UserStore，把"用户 → 用户组"映射独立同步到 Plugin，避免依赖 OS 的 UGI：

```scala
// SparkRangerAdminPlugin.scala:59-61
def useUserGroupsFromUserStoreEnabled: Boolean = getRangerConf.getBoolean(
  s"ranger.plugin.$getServiceType.use.usergroups.from.userstore.enabled",
  false)
```

### 7.2 启用配置

```xml
<property>
  <name>ranger.plugin.spark.use.usergroups.from.userstore.enabled</name>
  <value>true</value>
</property>
<property>
  <name>ranger.plugin.spark.enable.implicit.userstore.enricher</name>
  <value>true</value>
</property>
<property>
  <name>ranger.plugin.spark.policy.cache.dir</name>
  <value>/etc/ranger/spark/cache</value>
</property>
```

### 7.3 应用场景

- 策略中使用 `{{USER.attr}}` 表达式（如 `dept = '{{USER.dept}}'`）
- Spark Driver 进程的 OS UGI 与 Ranger 中的用户不一致
- 需要使用扩展属性（如部门、职级）做 RowFilter

---

## 八、批量鉴权配置

```scala
// SparkRangerAdminPlugin.scala:41-43
def authorizeInSingleCall: Boolean = getRangerConf.getBoolean(
  s"ranger.plugin.${getServiceType}.authorize.in.single.call",
  false)
```

```xml
<!-- 启用单次批量调用 -->
<property>
  <name>ranger.plugin.spark.authorize.in.single.call</name>
  <value>true</value>
</property>
```

**效果**：
- `false`（默认）：N 个对象 → N 次 `isAccessAllowed` 调用
- `true`：N 个对象 → 1 次 `isAccessAllowed(List<Request>)` 调用

JOIN 多表查询场景下性能差异 5-10 倍。

---

## 九、完整鉴权流程

```
用户提交：SELECT a.id, b.ssn FROM tbl_a a JOIN tbl_b b ON a.id = b.id;
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Spark Catalyst Parser                                                       │
│  → Unresolved LogicalPlan                                                    │
│     Project [a.id, b.ssn]                                                    │
│       Join                                                                   │
│         UnresolvedRelation(tbl_a as a)                                       │
│         UnresolvedRelation(tbl_b as b)                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Analyzer (with Kyuubi Resolution Rules)                                     │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ ① RuleApplyRowFilter                                                │    │
│  │    - 对每个表调用 SparkRangerAdminPlugin.getFilterExpr()            │    │
│  │    - 把 filter 表达式 parse 成 Catalyst Expression                  │    │
│  │    - 注入 Filter 节点                                               │    │
│  │                                                                     │    │
│  │    Project [a.id, b.ssn]                                            │    │
│  │      Join                                                           │    │
│  │        Filter (a.dept = 'finance')   ← 新增                         │    │
│  │          Relation(tbl_a)                                            │    │
│  │        Filter (b.region = 'us-west') ← 新增                         │    │
│  │          Relation(tbl_b)                                            │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ ② RuleApplyDataMaskingStage0/Stage1                                 │    │
│  │    - 对每列调用 SparkRangerAdminPlugin.getMaskingExpr()             │    │
│  │    - 用 regexp_replace 等内置函数生成 mask 表达式                   │    │
│  │    - 替换 Project 中的列引用                                        │    │
│  │                                                                     │    │
│  │    Project [a.id,                                                   │    │
│  │             concat(regexp_replace(left(b.ssn, length(b.ssn)-4)),    │    │
│  │                    right(b.ssn, 4)) as ssn]   ← Mask                 │    │
│  │      Join                                                           │    │
│  │        Filter (a.dept = 'finance')                                  │    │
│  │          Relation(tbl_a)                                            │    │
│  │        Filter (b.region = 'us-west')                                │    │
│  │          Relation(tbl_b)                                            │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Optimizer                                                                  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ ③ RuleAuthorization                                                 │    │
│  │    - 提取所有访问的 Privilege Objects                               │    │
│  │    - 构建 RangerAccessRequest 批次                                  │    │
│  │    - 调用 SparkRangerAdminPlugin.verify(requests, auditHandler)    │    │
│  │    - 任一不通过 → 抛 AccessControlException                         │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Spark Physical Plan & Execution                                             │
│  按重写后的 Logical Plan 正常执行                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 十、配置 Kyuubi-Authz 完整步骤

### 10.1 部署 jar 到 Spark

```bash
# 编译/下载 jar
wget https://kyuubi.apache.org/.../kyuubi-spark-authz_2.12-1.8.0.jar

# 放到 Spark jars 目录
cp kyuubi-spark-authz_2.12-1.8.0.jar $SPARK_HOME/jars/
```

### 10.2 配置 Spark 启用 Extension

```properties
# $SPARK_HOME/conf/spark-defaults.conf
spark.sql.extensions=org.apache.kyuubi.plugin.spark.authz.ranger.RangerSparkExtension
```

### 10.3 配置 Ranger Plugin

```bash
# $SPARK_HOME/conf/ranger-spark-security.xml
```

```xml
<configuration>
  <property>
    <name>ranger.plugin.spark.policy.rest.url</name>
    <value>http://ranger-admin:6080</value>
  </property>
  <property>
    <name>ranger.plugin.spark.service.name</name>
    <value>spark_cluster</value>
  </property>
  <property>
    <name>ranger.plugin.spark.policy.cache.dir</name>
    <value>/etc/ranger/spark/cache</value>
  </property>
  <property>
    <name>ranger.plugin.spark.policy.pollIntervalMs</name>
    <value>30000</value>
  </property>
  <property>
    <name>ranger.plugin.spark.authorize.in.single.call</name>
    <value>true</value>
  </property>
</configuration>
```

### 10.4 在 Ranger Admin 创建 Spark Service

```bash
# Ranger UI → Service Manager → 选择 Spark2/Spark3 类型
# Service Name: spark_cluster
# 配置 Policy 时使用 database/table/column 资源类型（与 Hive 一致）
```

---

## 十一、对比 Submarine 方案

### 11.1 Submarine 架构（Ranger 官方）

```
位置：ranger/plugin-spark/

依赖 Spark Listener API：
  - SparkListenerSQLExecutionStart
  - 通过反射拦截 LogicalPlan

缺陷：
  ① 拦截时机靠后，部分操作已经执行
  ② 不支持 Catalog V2（Iceberg/Delta）
  ③ Row Filter / Data Mask 实现不完整
  ④ 与 Spark 内核耦合度高，升级 Spark 易出问题
```

### 11.2 Kyuubi 方案优势

| 优势 | 详情 |
|-----|------|
| **深度集成** | 通过 SparkSessionExtensions 注入 Catalyst Rule，标准 API |
| **Catalog V2 支持** | 支持 Iceberg/Delta/Hudi 等新型 DataSource |
| **完整功能** | RowFilter/DataMask 完整实现，无功能阉割 |
| **生产验证** | 滴滴/网易/腾讯/B 站等大规模生产使用 |
| **解耦** | 通过 Service Loader (META-INF/services) 实现可扩展 |
| **批量鉴权** | 一次 RPC 鉴权多个对象 |
| **UserStore** | 支持 Ranger 2.1+ 的 UserStore 特性 |

---

## 十二、关键源码索引

| 模块 | 源码文件 | 行号 | 作用 |
|-----|---------|------|------|
| 入口 | `RangerSparkExtension.scala` | 43-60 | Spark Extension 注入点 |
| Plugin | `SparkRangerAdminPlugin.scala` | 30 | 继承 RangerBasePlugin |
| 初始化 | `SparkRangerAdminPlugin.scala` | 67-85 | initialize + ShutdownHook |
| 行过滤获取 | `SparkRangerAdminPlugin.scala` | 87-93 | `getFilterExpr()` |
| 列脱敏获取 | `SparkRangerAdminPlugin.scala` | 95-128 | `getMaskingExpr()` 转换内置函数 |
| 批量鉴权 | `SparkRangerAdminPlugin.scala` | 144-173 | `verify()` 批量调用 |
| Authz Rule | `RuleAuthorization.scala` | — | Optimizer Rule 执行鉴权 |
| RowFilter Rule | `RuleApplyRowFilter.scala` | — | 注入 Filter 节点 |
| Mask Rule | `RuleApplyDataMaskingStage0/1.scala` | — | 注入 Project Mask 表达式 |
| ResourceExtractor | `serde.TableExtractor` 等 | — | 从逻辑计划提取资源信息 |

---

## 十三、性能优化建议

### 13.1 启用批量鉴权

```xml
<property>
  <name>ranger.plugin.spark.authorize.in.single.call</name>
  <value>true</value>
</property>
```

### 13.2 调整 Policy 缓存

```xml
<property>
  <name>ranger.plugin.spark.policy.pollIntervalMs</name>
  <value>60000</value>  <!-- 60s，降低频率 -->
</property>
<property>
  <name>ranger.plugin.spark.policyengine.option.cache.audit.results</name>
  <value>2048</value>
</property>
```

### 13.3 关闭不用的 Enricher

如果不用 Tag 策略：
```xml
<property>
  <name>ranger.plugin.spark.contextenrichers.disabled</name>
  <value>TagEnricher</value>
</property>
```

### 13.4 避免广播 ExecutorPlugin

`SparkRangerAdminPlugin` 是单例，且只在 Driver 加载，**不在 Executor 端工作**。Executor 不参与鉴权。

**风险**：如果用户能直接访问 HDFS 数据文件（绕过 Spark SQL），则 Ranger Spark Plugin 失效。需配合 **HDFS Ranger Plugin** 双重保险。

---

## 十四、生产环境踩坑记录

### 坑 1：Spark Streaming 不触发鉴权

**现象**：用 `df.writeStream.toTable()` 写入受保护表，没有触发 Ranger。

**原因**：早期版本 Kyuubi-Authz 不支持 Streaming，需 1.7.0+。

**处置**：升级 Kyuubi-Authz 版本。

### 坑 2：Driver OOM

**现象**：开启 Authz 后 Driver 频繁 OOM。

**原因**：策略数量大（>20000）且通过 Hive Service 共享，`PolicyEngine` 占用 2GB+。

**处置**：
- 拆分 Spark Service（独立于 Hive）
- 增加 Driver 内存

### 坑 3：DataFrame API 绕过

**现象**：`df.write.parquet("/path")` 直接写 HDFS，绕过 Ranger Spark Plugin。

**原因**：DataFrame API 不经过 Catalog 解析，没有 LogicalPlan 注入点。

**处置**：
- 必须配合 HDFS Ranger Plugin（在 NameNode 端控制）
- 或者强制走 SparkSQL（禁用直接路径写入）

### 坑 4：Iceberg V2 类型转换错误

**现象**：Iceberg 表查询时报 `cannot cast string to int`。

**原因**：DataMask 用 `concat(regexp_replace(...))` 返回 string，但原列是 int。

**处置**：CUSTOM Mask 时显式 cast：
```sql
maskedValue = "CAST(0 AS INT)"  -- 或
              "regexp_replace(cast({col} as string), ...)"
```

---

## 十五、核心问答

| 问题 | 答案 |
|-----|------|
| Spark 与 Ranger 集成的难点？ | Spark 没有标准 Authorizer 接口，需要 Hook 到 Catalyst |
| Kyuubi 如何注入鉴权？ | 通过 SparkSessionExtensions 注入 ResolutionRule + OptimizerRule |
| Mask 是怎么实现的？ | Kyuubi 把 Ranger 返回的 mask 类型转换成 Spark 内置函数表达式 |
| 是否复用 Ranger Java SDK？ | 完全复用，SparkRangerAdminPlugin extends RangerBasePlugin |
| 鉴权何时触发？ | Optimizer 阶段的 RuleAuthorization 调用 plugin.verify() |
| 缓存机制？ | 复用 Ranger PolicyRefresher（30s 轮询） |
| 性能瓶颈？ | LogicalPlan 解析 + Privilege 提取 + Trie 索引匹配 |
| Submarine 还能用吗？ | 不推荐，新项目优先选 Kyuubi-Authz |
| 是否支持 Iceberg/Delta？ | Kyuubi-Authz 支持 Catalog V2 |
| Executor 参与鉴权吗？ | 不参与，只在 Driver 端鉴权 |
| 如何防止 DataFrame API 绕过？ | 配合 HDFS Ranger Plugin 形成双重防护 |

---

**文档版本**：v1.0
**更新时间**：2026-05-10
**Eric（豹纹）出品**
