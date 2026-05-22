# Ranger Row Filter 与 Data Mask 实现原理深度解析

> **核心命题**：Row Filter 和 Data Mask 不是在 Ranger 里过滤数据，而是**让 Ranger 返回一个 SQL 片段**（WHERE 子句或列表达式），由 Hive 的 `HiveAuthorizer.applyRowFilterAndColumnMasking` 钩子将其**重写进用户的原始 SQL**，最终由 Hive 执行引擎自己完成过滤/脱敏。

---

## 一、整体思路：SQL 重写而非数据拦截

### 1.1 错误理解 vs 正确理解

❌ **常见误解**：
```
用户 SELECT * FROM user
        ↓
Hive 执行查询，返回全量数据
        ↓
Ranger 拦截结果集，逐行/逐列过滤
```

✅ **实际原理**：
```
用户 SELECT * FROM user
        ↓
Hive Semantic Analyzer → 调用 RangerHiveAuthorizer.applyRowFilterAndColumnMasking()
        ↓
Ranger 评估策略 → 返回 SQL 表达式
  Row Filter: "dept = current_user_dept()"
  Data Mask:  "mask_show_last_4(ssn)"
        ↓
Hive 把原 SQL 重写为：
  SELECT id, name, mask_show_last_4(ssn), ...
  FROM user
  WHERE dept = current_user_dept()
        ↓
Hive 执行引擎按重写后的 SQL 查询，Ranger 不参与数据流
```

**关键优势**：
- 零数据层性能开销（Ranger 不触碰数据）
- 谓词下推可正常发挥（Row Filter 进入 WHERE）
- 存储格式无关（Parquet/ORC 照常走 vectorization）

---

## 二、两种能力对比

| 维度 | Row Filter（行过滤） | Data Mask（列脱敏） |
|-----|---------------------|---------------------|
| 作用层级 | 表级 | 列级 |
| 策略类型 | `POLICY_TYPE_ROWFILTER=2` | `POLICY_TYPE_DATAMASK=1` |
| 输出 | WHERE 子句表达式 | 列值变换表达式 |
| Mask 类型 | — | NULL/SHA256/RedactByChar/ShowLast4/Custom |
| 典型场景 | 多租户（各部门只看自己的数据） | PII 脱敏（身份证只显示后4位） |

---

## 三、策略数据模型

### 3.1 Row Filter Policy

```java
// RangerPolicy.java（嵌套类）
public static class RangerRowFilterPolicyItem extends RangerPolicyItem {
    private RangerPolicyItemRowFilterInfo rowFilterInfo;
}

public static class RangerPolicyItemRowFilterInfo {
    private String filterExpr;  // WHERE 子句片段，如 "dept = 'engineering'"
}
```

**策略 JSON 示例**：
```json
{
  "id": 501,
  "name": "multi-tenant-user-table",
  "policyType": 2,
  "resources": {
    "database": {"values": ["hr"]},
    "table":    {"values": ["employee"]}
  },
  "rowFilterPolicyItems": [
    {
      "users":  ["alice"],
      "accesses": [{"type": "select"}],
      "rowFilterInfo": {
        "filterExpr": "dept = 'finance'"
      }
    },
    {
      "groups": ["engineering"],
      "accesses": [{"type": "select"}],
      "rowFilterInfo": {
        "filterExpr": "dept = 'engineering' OR is_public = true"
      }
    }
  ]
}
```

### 3.2 Data Mask Policy

```java
public static class RangerDataMaskPolicyItem extends RangerPolicyItem {
    private RangerPolicyItemDataMaskInfo dataMaskInfo;
}

public static class RangerPolicyItemDataMaskInfo {
    private String dataMaskType;     // MASK / MASK_SHOW_LAST_4 / MASK_HASH / CUSTOM 等
    private String conditionExpr;    // 附加条件（可选）
    private String valueExpr;        // CUSTOM 类型的自定义表达式
}
```

**内置 Mask 类型**（RangerPolicy.java）：

| maskType | 效果 | Transformer 模板 |
|---------|------|------------------|
| `MASK` | 完全隐藏 | `sha2({col}, 256)` |
| `MASK_SHOW_LAST_4` | 只显示后4位 | `mask_show_last_n({col}, 4, 'x', 'x', 'x', -1, '1')` |
| `MASK_SHOW_FIRST_4` | 只显示前4位 | `mask_show_first_n({col}, 4, 'x', 'x', 'x', -1, '1')` |
| `MASK_HASH` | SHA256 | `sha2({col}, 256)` |
| `MASK_NULL` | 返回 NULL | 列直接替换为 `NULL` |
| `MASK_NONE` | 不脱敏 | 保持原值 |
| `MASK_DATE_SHOW_YEAR` | 日期只保留年 | `mask({col}, 'x', 'x', 'x', -1, '1', 1, 0, -1)` |
| `CUSTOM` | 自定义表达式 | 使用 `valueExpr` 字段 |

**策略 JSON 示例**：
```json
{
  "id": 502,
  "name": "ssn-masking",
  "policyType": 1,
  "resources": {
    "database": {"values": ["hr"]},
    "table":    {"values": ["employee"]},
    "column":   {"values": ["ssn"]}
  },
  "dataMaskPolicyItems": [
    {
      "users": ["alice"],
      "accesses": [{"type": "select"}],
      "dataMaskInfo": {
        "dataMaskType": "MASK_SHOW_LAST_4"
      }
    },
    {
      "groups": ["guest"],
      "accesses": [{"type": "select"}],
      "dataMaskInfo": {
        "dataMaskType": "MASK_NULL"
      }
    }
  ]
}
```

---

## 四、Hive 端集成：applyRowFilterAndColumnMasking()

Hive 在 SQL 编译阶段会调用 `HiveAuthorizer.applyRowFilterAndColumnMasking()`，Ranger 实现在 `RangerHiveAuthorizer.applyRowFilterAndColumnMasking()`。

### 4.1 主流程（RangerHiveAuthorizer.java:1150-1200）

```java
// RangerHiveAuthorizer.java:1150-1200
for (HivePrivilegeObject hiveObj : hiveObjs) {
    boolean needToTransform = false;

    if (hiveObjType == HivePrivilegeObjectType.TABLE_OR_VIEW) {
        String database = hiveObj.getDbname();
        String table    = hiveObj.getObjectName();

        // ① Row Filter：返回 WHERE 表达式
        String rowFilterExpr = getRowFilterExpression(queryContext, database, table);
        if (StringUtils.isNotBlank(rowFilterExpr)) {
            hiveObj.setRowFilterExpression(rowFilterExpr);  // 回写到 hiveObj
            needToTransform = true;
        }

        // ② Data Mask：为每一列计算 transformer
        if (CollectionUtils.isNotEmpty(hiveObj.getColumns())) {
            List<String> columnTransformers = new ArrayList<>();
            for (String column : hiveObj.getColumns()) {
                boolean isColumnTransformed = addCellValueTransformerAndCheckIfTransformed(
                    queryContext, database, table, column, columnTransformers);
                needToTransform = needToTransform || isColumnTransformed;
            }
            hiveObj.setCellValueTransformers(columnTransformers);  // 回写
        }
    }

    if (needToTransform) {
        ret.add(hiveObj);
    }
}
return ret;
```

### 4.2 Row Filter 获取（行1243-1281）

```java
private String getRowFilterExpression(HiveAuthzContext context, String database, String table)
        throws SemanticException {
    UserGroupInformation ugi = getCurrentUserGroupInfo();
    String ret = null;

    try {
        HiveAuthzSessionContext sessionContext = getHiveAuthzSessionContext();
        String         user      = ugi.getShortUserName();
        Set<String>    groups    = Sets.newHashSet(ugi.getGroupNames());
        Set<String>    roles     = getCurrentRoles();
        HiveObjectType objectType = HiveObjectType.TABLE;

        // ① 构造 RangerHiveResource（表级）
        RangerHiveResource resource = new RangerHiveResource(objectType, database, table);

        // ② 构造 AccessRequest
        RangerHiveAccessRequest request = new RangerHiveAccessRequest(
            resource, user, groups, roles, objectType.name(),
            HiveAccessType.SELECT, context, sessionContext);

        // ③ 专用入口：evalRowFilterPolicies
        RangerAccessResult result = hivePlugin.evalRowFilterPolicies(request, auditHandler);

        // ④ 从 result 中取出 filterExpr
        if (isRowFilterEnabled(result)) {
            ret = result.getFilterExpr();
        }
    } finally {
        auditHandler.flushAudit();
    }
    return ret;
}

private boolean isRowFilterEnabled(RangerAccessResult result) {
    return result != null
        && result.isRowFilterEnabled()
        && StringUtils.isNotEmpty(result.getFilterExpr());
}
```

### 4.3 Data Mask 获取（行1283-1354）

```java
private boolean addCellValueTransformerAndCheckIfTransformed(
        HiveAuthzContext context, String database, String table, String column,
        List<String> columnTransformers) throws SemanticException {

    String columnTransformer = column;  // 默认：保持列名不变

    try {
        // ① 构造列级资源
        RangerHiveResource resource = new RangerHiveResource(
            HiveObjectType.COLUMN, database, table, column);

        RangerHiveAccessRequest request = new RangerHiveAccessRequest(
            resource, user, groups, roles, HiveObjectType.COLUMN.name(),
            HiveAccessType.SELECT, context, sessionContext);

        // ② 专用入口：evalDataMaskPolicies
        RangerAccessResult result = hivePlugin.evalDataMaskPolicies(request, auditHandler);

        ret = isDataMaskEnabled(result);

        if (ret) {
            String                maskType    = result.getMaskType();
            RangerDataMaskTypeDef maskTypeDef = result.getMaskTypeDef();
            String transformer = maskTypeDef != null ? maskTypeDef.getTransformer() : null;

            // ③ 根据 maskType 生成 transformer 表达式
            if (StringUtils.equalsIgnoreCase(maskType, RangerPolicy.MASK_TYPE_NULL)) {
                columnTransformer = "NULL";
            } else if (StringUtils.equalsIgnoreCase(maskType, RangerPolicy.MASK_TYPE_CUSTOM)) {
                String maskedValue = result.getMaskedValue();
                if (maskedValue == null) {
                    columnTransformer = "NULL";
                } else {
                    columnTransformer = maskedValue.replace("{col}", column);
                    //                                ↑ 模板替换
                }
            } else if (StringUtils.isNotEmpty(transformer)) {
                columnTransformer = transformer.replace("{col}", column);
                //                                ↑ 例如 "mask_show_last_n({col}, 4, ...)"
            }
        }
    } finally {
        auditHandler.flushAudit();
    }

    columnTransformers.add(columnTransformer);
    return ret;
}
```

---

## 五、PolicyItemEvaluator 实现

### 5.1 RangerDefaultDataMaskPolicyItemEvaluator（完整源码）

```java
// RangerDefaultDataMaskPolicyItemEvaluator.java:1-57
public class RangerDefaultDataMaskPolicyItemEvaluator extends RangerDefaultPolicyItemEvaluator
        implements RangerDataMaskPolicyItemEvaluator {

    final private RangerDataMaskPolicyItem dataMaskPolicyItem;

    public RangerDefaultDataMaskPolicyItemEvaluator(
            RangerServiceDef serviceDef,
            RangerPolicy policy,
            RangerDataMaskPolicyItem policyItem,
            int policyItemIndex,
            RangerPolicyEngineOptions options) {
        super(serviceDef, policy, policyItem,
              RangerPolicyItemEvaluator.POLICY_ITEM_TYPE_DATAMASK,
              policyItemIndex, options);
        dataMaskPolicyItem = policyItem;
    }

    @Override
    public RangerPolicyItemDataMaskInfo getDataMaskInfo() {
        return dataMaskPolicyItem == null ? null : dataMaskPolicyItem.getDataMaskInfo();
    }

    @Override
    public void updateAccessResult(
            RangerPolicyEvaluator policyEvaluator,
            RangerAccessResult result,
            RangerPolicyResourceMatcher.MatchType matchType) {
        RangerPolicyItemDataMaskInfo dataMaskInfo = getDataMaskInfo();

        // 关键：只有 result 中还没有 maskType 时才设置（首个匹配生效）
        if (result.getMaskType() == null && dataMaskInfo != null) {
            result.setMaskType(dataMaskInfo.getDataMaskType());     // 如 MASK_SHOW_LAST_4
            result.setMaskCondition(dataMaskInfo.getConditionExpr()); // 附加条件
            result.setMaskedValue(dataMaskInfo.getValueExpr());       // CUSTOM 的表达式
            policyEvaluator.updateAccessResult(result, matchType, true, getComments());
        }
    }
}
```

### 5.2 RangerDefaultRowFilterPolicyItemEvaluator（完整源码）

```java
// RangerDefaultRowFilterPolicyItemEvaluator.java:1-54
public class RangerDefaultRowFilterPolicyItemEvaluator extends RangerDefaultPolicyItemEvaluator
        implements RangerRowFilterPolicyItemEvaluator {

    final private RangerRowFilterPolicyItem rowFilterPolicyItem;

    @Override
    public RangerPolicyItemRowFilterInfo getRowFilterInfo() {
        return rowFilterPolicyItem == null ? null : rowFilterPolicyItem.getRowFilterInfo();
    }

    @Override
    public void updateAccessResult(
            RangerPolicyEvaluator policyEvaluator,
            RangerAccessResult result,
            RangerPolicyResourceMatcher.MatchType matchType) {
        RangerPolicyItemRowFilterInfo rowFilterInfo = getRowFilterInfo();

        // 关键：只有 result 中还没有 filterExpr 时才设置（首个匹配生效）
        if (result.getFilterExpr() == null && rowFilterInfo != null) {
            result.setFilterExpr(rowFilterInfo.getFilterExpr());
            policyEvaluator.updateAccessResult(result, matchType, true, getComments());
        }
    }
}
```

**关键设计**：
- 两者继承的父类都是 `RangerDefaultPolicyItemEvaluator`，策略评估（用户/组/条件匹配）逻辑与普通策略完全一致
- 只在 `updateAccessResult()` 时把结果写到 `RangerAccessResult` 的不同字段

---

## 六、PolicyEngine 端的专用入口

### 6.1 evalDataMaskPolicies / evalRowFilterPolicies

```java
// RangerPolicyEngineImpl.java 中（简化）
public RangerAccessResult evalDataMaskPolicies(
        RangerAccessRequest request, RangerAccessResultProcessor resultProcessor) {
    return evaluatePolicies(request, RangerPolicy.POLICY_TYPE_DATAMASK, resultProcessor);
    //                                                ↑ 策略类型=1
}

public RangerAccessResult evalRowFilterPolicies(
        RangerAccessRequest request, RangerAccessResultProcessor resultProcessor) {
    return evaluatePolicies(request, RangerPolicy.POLICY_TYPE_ROWFILTER, resultProcessor);
    //                                                ↑ 策略类型=2
}
```

### 6.2 PolicyRepository 的三个并行 Evaluator 列表

```java
// RangerPolicyRepository.java
private List<RangerPolicyEvaluator> policyEvaluators;          // POLICY_TYPE_ACCESS
private List<RangerPolicyEvaluator> dataMaskPolicyEvaluators;  // POLICY_TYPE_DATAMASK
private List<RangerPolicyEvaluator> rowFilterPolicyEvaluators; // POLICY_TYPE_ROWFILTER

private Map<String, RangerResourceTrie> policyResourceTrie;         // 访问策略 Trie
private Map<String, RangerResourceTrie> dataMaskResourceTrie;        // Mask 策略 Trie
private Map<String, RangerResourceTrie> rowFilterResourceTrie;      // RowFilter 策略 Trie
```

**关键设计**：三套独立的 Trie 索引，三种策略互不干扰。

---

## 七、完整时序图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HiveServer2 SQL 编译阶段                             │
│                                                                             │
│  SELECT id, name, ssn, dept FROM hr.employee                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  SemanticAnalyzer.analyzeInternal()                                          │
│     └── HiveAuthorizer.applyRowFilterAndColumnMasking()                      │
│           ↓                                                                  │
│         RangerHiveAuthorizer.applyRowFilterAndColumnMasking()                │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
┌──────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│ getRowFilter         │  │ addCellValueTransformer (per column) │            │
│ Expression()         │  │                                                   │
│                      │  │                                                   │
│ 表级 resource         │  │ 列级 resource                                      │
│ {db, table}          │  │ {db, table, col}                                  │
│        │             │  │        │                                          │
│        ▼             │  │        ▼                                          │
│ evalRowFilter        │  │ evalDataMask                                      │
│ Policies()           │  │ Policies()                                        │
│ POLICY_TYPE=2        │  │ POLICY_TYPE=1                                     │
└──────────────────────┘  └──────────────────────────────────────────────────┘
              │                       │
              ▼                       ▼
┌──────────────────────┐  ┌──────────────────────────────────────────────────┐
│ rowFilterEvaluator   │  │ dataMaskEvaluator                                 │
│ .updateAccessResult()│  │ .updateAccessResult()                             │
│                      │  │                                                   │
│ result.setFilterExpr │  │ result.setMaskType(MASK_SHOW_LAST_4)              │
│   ("dept='finance'") │  │ result.setMaskedValue(valueExpr)                  │
└──────────────────────┘  └──────────────────────────────────────────────────┘
              │                       │
              ▼                       ▼
┌──────────────────────┐  ┌──────────────────────────────────────────────────┐
│ hiveObj.setRow       │  │ columnTransformer =                               │
│ FilterExpression(    │  │   "mask_show_last_n({col}, 4, ...)                │
│   "dept='finance'")  │  │       .replace("{col}", "ssn")                    │
│                      │  │                                                   │
│                      │  │ hiveObj.setCellValueTransformers([...])           │
└──────────────────────┘  └──────────────────────────────────────────────────┘
              │                       │
              └───────────┬───────────┘
                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Hive 完成 SQL 重写                                       │
│                                                                             │
│  重写后的 SQL：                                                               │
│    SELECT id, name,                                                          │
│           mask_show_last_n(ssn, 4, 'x', 'x', 'x', -1, '1') AS ssn,           │
│           dept                                                               │
│    FROM hr.employee                                                          │
│    WHERE dept='finance'                                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│               Hive 执行引擎按重写 SQL 执行，Ranger 不再参与                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 八、典型场景示例

### 8.1 多租户行过滤

**场景**：HR 系统中每个部门经理只能看到自己部门的员工。

**策略**：
```json
{
  "name": "dept-row-filter",
  "policyType": 2,
  "resources": {"database":{"values":["hr"]}, "table":{"values":["employee"]}},
  "rowFilterPolicyItems": [
    {
      "users": ["manager_a"],
      "accesses": [{"type": "select"}],
      "rowFilterInfo": {"filterExpr": "dept_id = 101"}
    },
    {
      "users": ["manager_b"],
      "accesses": [{"type": "select"}],
      "rowFilterInfo": {"filterExpr": "dept_id = 102"}
    }
  ]
}
```

**效果**：
```sql
-- manager_a 执行：
SELECT * FROM hr.employee;

-- Hive 实际执行：
SELECT * FROM hr.employee WHERE dept_id = 101;
```

### 8.2 PII 列脱敏

**场景**：普通员工只能看到身份证后 4 位。

**策略**：
```json
{
  "name": "ssn-mask",
  "policyType": 1,
  "resources": {
    "database":{"values":["hr"]},
    "table":{"values":["employee"]},
    "column":{"values":["id_card"]}
  },
  "dataMaskPolicyItems": [
    {
      "groups": ["employee"],
      "accesses": [{"type": "select"}],
      "dataMaskInfo": {"dataMaskType": "MASK_SHOW_LAST_4"}
    }
  ]
}
```

**效果**：
```sql
-- employee 组用户执行：
SELECT id, name, id_card FROM hr.employee;

-- Hive 实际执行：
SELECT id, name,
       mask_show_last_n(id_card, 4, 'x', 'x', 'x', -1, '1') AS id_card
FROM hr.employee;

-- 返回结果：id=1, name=张三, id_card=xxxxxxxxxxxxxx1234
```

### 8.3 CUSTOM 自定义 Mask

**策略**：
```json
{
  "dataMaskPolicyItems": [{
    "groups": ["guest"],
    "dataMaskInfo": {
      "dataMaskType": "CUSTOM",
      "valueExpr": "CONCAT(SUBSTR({col}, 1, 3), '****', SUBSTR({col}, LENGTH({col})-3))"
    }
  }]
}
```

**效果**：
```sql
-- guest 组执行：
SELECT id_card FROM hr.employee;

-- Hive 实际执行：
SELECT CONCAT(SUBSTR(id_card, 1, 3), '****', SUBSTR(id_card, LENGTH(id_card)-3)) AS id_card
FROM hr.employee;
```

---

## 九、组合效应与优先级

### 9.1 多条 Mask 策略同时命中

```java
// RangerDefaultDataMaskPolicyItemEvaluator.java:48
if (result.getMaskType() == null && dataMaskInfo != null) {
    // ← 只有 result.maskType 为 null 时才设置
```

**规则**：按策略的 `policyPriority`（DESC）+ `policyId`（ASC）排序，**第一个命中的策略生效**。

### 9.2 Row Filter 与 DataMask 可并存

一个 SELECT 语句可能同时触发：
- Row Filter（表级）→ 过滤行
- Data Mask（列级）→ 脱敏列

Ranger 对两者分别评估，互不干扰。

### 9.3 与 Access 策略的关系

```
用户 SELECT 列 ssn：

  ① Access 策略评估（POLICY_TYPE_ACCESS=0）
     ├── ALLOW  → 进入 ②
     └── DENY   → 直接拒绝，不再评估 Mask
  
  ② Data Mask 评估（POLICY_TYPE_DATAMASK=1）
     └── 返回 mask 表达式
  
  ③ Row Filter 评估（POLICY_TYPE_ROWFILTER=2）
     └── 返回 filter 表达式
```

**顺序**：必须先过 Access 策略，再进行 Mask/Filter。

---

## 十、Tag 策略的 Mask/Filter

Tag 策略也支持 DataMask 和 RowFilter（`isValidDeltas` 校验中包含）：

```java
// RangerPolicyDeltaUtil.java:141-145
} else if (policyType == null || (policyType != POLICY_TYPE_ACCESS
        && policyType != POLICY_TYPE_DATAMASK
        && policyType != POLICY_TYPE_ROWFILTER)) {
    isValid = false;
}
```

**效果**：

```
Tag 策略：tag=PII, type=DATAMASK → MASK_SHOW_LAST_4

Atlas 给 db1.user.ssn 打了 PII 标签

用户 SELECT ssn
  ├── TagEnricher 发现列有 PII 标签
  ├── Tag 策略 Mask 生效 → 返回 mask_show_last_n(...)
  └── Hive 重写 SQL
```

---

## 十一、关键源码索引

| 步骤 | 源码文件 | 行号 | 作用 |
|-----|---------|------|------|
| Hive 入口 | `RangerHiveAuthorizer.java` | 1150-1200 | `applyRowFilterAndColumnMasking()` |
| Row Filter 评估 | `RangerHiveAuthorizer.java` | 1243-1281 | `getRowFilterExpression()` |
| Mask 评估 | `RangerHiveAuthorizer.java` | 1283-1354 | `addCellValueTransformerAndCheckIfTransformed()` |
| Row Filter Evaluator | `RangerDefaultRowFilterPolicyItemEvaluator.java` | 1-54 | 完整源码 |
| Mask Evaluator | `RangerDefaultDataMaskPolicyItemEvaluator.java` | 1-57 | 完整源码 |
| Plugin 专用入口 | `RangerBasePlugin.java` | — | `evalDataMaskPolicies` / `evalRowFilterPolicies` |
| Repository 独立 Trie | `RangerPolicyRepository.java` | — | `dataMaskResourceTrie` / `rowFilterResourceTrie` |
| AccessResult 字段 | `RangerAccessResult.java` | — | `maskType` / `filterExpr` / `maskedValue` |
| Mask 类型常量 | `RangerPolicy.java` | — | `MASK_TYPE_NULL` / `MASK_TYPE_CUSTOM` / `MASK` 等 |

---

## 十二、常见坑点

### 12.1 UDF 不存在

**现象**：查询报错 `Function 'mask_show_last_n' not found`

**原因**：`mask_show_last_n` / `mask` 等是 Hive 内置 UDF，需 Hive 2.1+ 且开启 `hive.security.mask.authorization.udf`。

**解决**：
```sql
-- 检查 UDF 是否可用
DESCRIBE FUNCTION mask_show_last_n;
```

### 12.2 RowFilter 破坏谓词下推

**现象**：应用 Row Filter 后查询慢了很多。

**原因**：Row Filter 表达式过于复杂（如嵌套子查询），Hive 无法下推到存储层（Parquet/ORC）。

**解决**：
- Row Filter 表达式尽量简单（`dept = ?` 而非 `dept IN (SELECT ...)`）
- 使用分区列做过滤

### 12.3 Mask 表达式注入

**风险**：CUSTOM 类型的 `valueExpr` 直接拼接进 SQL，如果允许用户自定义可能有 SQL 注入。

**防范**：
- CUSTOM 策略只允许管理员创建
- `valueExpr` 中禁止使用危险函数（REFLECT/JAVA_METHOD）

### 12.4 Mask 列不可聚合

```sql
-- 错误：对脱敏列做 SUM 会报错或结果错误
SELECT SUM(id_card) FROM hr.employee;
-- 重写为：SELECT SUM(mask_show_last_n(id_card, 4, ...))
```

**解决**：业务上不要对 Mask 列做聚合。

---

## 十三、核心问答

| 问题 | 答案 |
|-----|------|
| Row Filter 是 Ranger 过滤数据吗？ | **不是**。Ranger 只返回 SQL 片段，Hive 重写 SQL 后自己执行 |
| 性能开销大吗？ | 几乎为 0（只多一次策略评估 RPC，不触碰数据） |
| 支持所有 Hive 版本吗？ | Hive 2.1+（`HiveAuthorizer.applyRowFilterAndColumnMasking` API） |
| 支持哪些 Mask 类型？ | 8 种内置 + CUSTOM 自定义（通过 `valueExpr`） |
| Row Filter 可以跨表 JOIN 吗？ | 只能引用当前表的列，不能引用其他表 |
| 和 Access 策略的关系？ | Access 先评估，DENY 直接拒绝；ALLOW 再进入 Mask/Filter |
| 多条 Mask 策略同时命中？ | 按 `policyPriority` DESC + `policyId` ASC 排序，首个命中生效 |
| Tag 策略能做 Mask 吗？ | 可以，Tag 策略同样支持 DATAMASK/ROWFILTER 类型 |
| Spark/Impala 支持吗？ | Impala 支持（Sentry→Ranger 迁移后），Spark 需通过 Kyuubi 适配 |
| Ranger 端的 Trie 索引？ | 三套独立：Access/DataMask/RowFilter 各自一套 Trie |

---

**文档版本**：v1.0
**更新时间**：2026-05-10
**Eric（豹纹）出品**
