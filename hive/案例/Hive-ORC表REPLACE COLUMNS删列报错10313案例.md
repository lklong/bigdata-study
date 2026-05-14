# Hive ORC 表 REPLACE COLUMNS 删列报错 10313 案例

> 归档人：eric
> 归档日期：2026-05-14
> 适用版本：Hive 3.1.3（腾讯 EMR 内部 fork `dev/edwin-3.1.3-xinxiwang`）/ Hive 4.x 社区
> 关键词：REPLACE COLUMNS、ORC、Schema Evolution、10313、SerDe may be incompatible、按列号存储

---

## 一、问题现象

### 1.1 复现 SQL

```sql
-- Step 1：建表（ORC 格式，3 列）
CREATE TABLE `dwi_tmp.test_replace_01`(
  a string,
  b string,
  c string
)
STORED AS ORCFILE;

-- Step 2：尝试用 REPLACE COLUMNS 把 c 列去掉
ALTER TABLE dwi_tmp.test_replace_01 REPLACE COLUMNS (
  a string,
  b string
);
```

### 1.2 报错信息

线上 EMR 3.1.3 看到的报错：

```
FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask.
Replacing columns cannot drop columns for table dwi_tmp.test_replace_01.
SerDe may be incompatible
```

社区 master 版本（DDL 已重构后）会显示：

```
FAILED: Execution Error, return code 10313 from org.apache.hadoop.hive.ql.ddl.DDLTask.
Replacing columns cannot drop columns for table dwi_tmp.test_replace_01.
SerDe may be incompatible
```

错误码定义：`REPLACE_CANNOT_DROP_COLUMNS = 10313`。

---

## 二、REPLACE COLUMNS 语法语义

### 2.1 它到底做什么

`REPLACE COLUMNS (...)` = **用括号里的新列清单整体替换表的"非分区列"列表**。
注意是"替换"，不是"删某一列"，也不是"追加"。它要求把整张表的列清单重写一遍。

| 状态 | 列清单 |
|---|---|
| 执行前 | `a string, b string, c string` |
| 执行后（如果成功） | `a string, b string` |

由于 Hive 3 没有真正的 `ALTER TABLE ... DROP COLUMN`，社区把 REPLACE COLUMNS 作为"曲线删列"的官方途径，**前提是底层文件格式支持**（TEXTFILE/CSV 等行式格式 OK，ORC/Parquet 列式格式有限制）。

### 2.2 它和其他 ALTER 子句的关系

| 语法 | 作用 | 是否影响其他列 |
|---|---|---|
| `ADD COLUMNS (x int)` | 末尾追加列 | 否 |
| `CHANGE COLUMN a a bigint` | 改某列名/类型/位置 | 否 |
| `DROP COLUMN c` | Hive 3 **不支持**（语法错） | — |
| **`REPLACE COLUMNS (...)`** | **整表列定义重写** | **是，括号外的列全部丢掉** |

### 2.3 执行层面只做一件事

REPLACE COLUMNS 是**纯元数据操作**：

- ✅ 更新 Hive Metastore（MySQL）`SDS.COLS` 表中该表的列定义
- ❌ 不动 HDFS / COS 上的任何 ORC 数据文件
- ❌ 不重写、不裁剪、不迁移数据
- ❌ 不校验老数据是否仍能被新 schema 正确读出来

这就是 ORC 删列危险的根源——文件物理布局和 Metastore schema 一旦错位，后果是**静默错误**而不是异常。

---

## 三、根因（源码权威证据）

### 3.1 校验代码位置

**腾讯 EMR 3.1.3 fork（线上代码）**：
- 文件：`ql/src/java/org/apache/hadoop/hive/ql/exec/DDLTask.java`
- 行号：4172–4213
- 仓库：`D:\bigdata\txproject\hive` 分支 `dev/edwin-3.1.3-xinxiwang`

**Apache 社区 master**：
- 文件：`ql/src/java/org/apache/hadoop/hive/ql/ddl/table/column/replace/AlterTableReplaceColumnsOperation.java`
- 行号：62–73（已按 DDL Operation 拆类重构）
- 仓库：`D:\bigdata\gitproject\hive`

### 3.2 核心校验逻辑（线上代码）

```java
// DDLTask.java 4190-4201
final boolean isOrcSchemaEvolution =
    serializationLib.equals(OrcSerde.class.getName()) &&
    isSchemaEvolutionEnabled(tbl);
// adding columns and limited integer type promotion is supported for ORC schema evolution
if (isOrcSchemaEvolution) {
  final List<FieldSchema> existingCols = sd.getCols();
  final List<FieldSchema> replaceCols = alterTbl.getNewCols();

  if (replaceCols.size() < existingCols.size()) {
    throw new HiveException(ErrorMsg.REPLACE_CANNOT_DROP_COLUMNS, alterTbl.getOldName());
  }
}
```

### 3.3 isSchemaEvolutionEnabled 实现（3.1.3）

```java
// DDLTask.java 4039-4045
private boolean isSchemaEvolutionEnabled(Table tbl) {
  boolean isAcid = AcidUtils.isTablePropertyTransactional(tbl.getMetadata());
  if (isAcid || HiveConf.getBoolVar(conf, ConfVars.HIVE_SCHEMA_EVOLUTION)) {
    return true;
  }
  return false;
}
```

### 3.4 默认开关（3.1.3）

```java
// HiveConf.java 1803-1804
HIVE_SCHEMA_EVOLUTION("hive.exec.schema.evolution", true,
    "Use schema evolution to convert self-describing file format's data to the schema desired by the reader."),
```

### 3.5 错误码定义

```java
// ErrorMsg.java 422
REPLACE_CANNOT_DROP_COLUMNS(10313, "Replacing columns cannot drop columns for table {0}. SerDe may be incompatible", true),
```

### 3.6 推导链（这条 SQL 的执行轨迹）

1. `STORED AS ORCFILE` ⇒ `serializationLib = OrcSerde`
2. 普通非 ACID 表，`HIVE_SCHEMA_EVOLUTION` 默认 true ⇒ `isSchemaEvolutionEnabled(tbl) = true`
3. ⇒ `isOrcSchemaEvolution = true`
4. `existingCols.size() = 3`（a/b/c），`replaceCols.size() = 2`（a/b）
5. `2 < 3` ⇒ **抛 `REPLACE_CANNOT_DROP_COLUMNS` (10313)**

---

## 四、为什么 Hive 要硬卡这一刀

### 4.1 ORC 是按"列号"存储的

ORC 文件内部 **不存列名**，只存列的位置编号（column id）和类型。Reader 读数据时按"第 N 个字段"匹配 schema。

### 4.2 REPLACE COLUMNS 只改 Metastore，不动文件

如果允许减列，会出现物理文件和 schema 错位：

| 物理 ORC 文件（列号 0/1/2） | "v1" | "v2" | "v3" |
|---|---|---|---|
| Schema Evolution 后只看前两列 | a="v1" | b="v2" | （丢失 c） |

更恶劣的场景：如果 REPLACE 成 `(a string, c string)`（想"删中间的 b"），物理文件里 c 仍在第 3 槽位，但 Hive 把读到的第 2 个字段当成新 schema 的 c，返回的是 **老 b 的值，类型还可能不匹配**——**静默错误**，远比直接报 10313 危险。

### 4.3 ORC Schema Evolution 只支持向后扩展

`hive.exec.schema.evolution=true` 时只允许：

- ✅ 末尾新增列
- ✅ 有限的类型晋升（int → bigint 等）
- ❌ 删除列
- ❌ 改列序

社区干脆禁掉「REPLACE COLUMNS 减列」这种最易被滥用的写法，强制让用户走"重建表 + 数据迁移"路径。

### 4.4 ACID 表的兜底

如果是事务表（`transactional=true`），`isAcid` 永远返 true，`isSchemaEvolutionEnabled` 短路返 true，**`hive.exec.schema.evolution` 这个开关都关不掉**——这是社区的安全兜底。

---

## 五、txproject vs gitproject 差异对照

| 维度 | gitproject（社区 master） | **txproject（EMR 3.1.3 线上）** |
|---|---|---|
| 校验代码位置 | `AlterTableReplaceColumnsOperation#doAlteration` | `DDLTask.java`（4172–4213）|
| 类组织 | DDL 已按 Operation 拆类 | 还是巨石类 `DDLTask` |
| SerDe 白名单 | 含 IcebergSerDe，不含 DynamicSerDe | 含 DynamicSerDe，不含 IcebergSerDe |
| 用户可见返回码 | `return code 10313` | **`return code 1`**（DDLTask 失败码） |
| 错误信息文案 | 完全一致 | 完全一致 |
| 核心校验逻辑 | **完全一致**：`replaceCols.size() < existingCols.size()` ⇒ 抛 10313 | 完全一致 |
| `hive.exec.schema.evolution` 默认值 | true | **true** |
| ACID 强制 schema evolution | 是 | 是 |

**结论**：腾讯内部对这段逻辑**没有打 patch**，行为与社区 3.1.3 完全一致，无法靠改腾讯专属参数绕过。

---

## 六、解决方案

### 方案 A：保留列定义不写入（**强烈推荐**）

什么都不改，建模上把 c 列当作 deprecated。零风险、零成本。

### 方案 B：CTAS 重建 + RENAME（推荐）

```sql
-- 1) 新表
CREATE TABLE dwi_tmp.test_replace_01_new STORED AS ORC AS
SELECT a, b FROM dwi_tmp.test_replace_01;

-- 2) 切换
ALTER TABLE dwi_tmp.test_replace_01     RENAME TO dwi_tmp.test_replace_01_bak;
ALTER TABLE dwi_tmp.test_replace_01_new RENAME TO dwi_tmp.test_replace_01;

-- 3) 观察 1~2 个调度周期后再 DROP bak
```

分区大表请按分区 INSERT OVERWRITE 灌，避免一把 CTAS 撑爆 YARN。

### 方案 C：会话级关闭 schema evolution（**严禁线上用**）

```sql
SET hive.exec.schema.evolution=false;
ALTER TABLE dwi_tmp.test_replace_01 REPLACE COLUMNS (a string, b string);
```

**踩坑警告**（基于 3.1.3 源码验证）：

1. 线上 ORC 文件按列号存数据，Metastore schema 改 2 列后，ORC reader 在某些查询路径下会**静默错位**（尤其 c 不在末尾、或后续又 ADD 新列时）。
2. 如果是 ACID 表，`isAcid=true` 短路，**这个开关根本关不掉**，照样抛 10313。
3. 即便绕过去了，下次 `ANALYZE TABLE`、`MSCK REPAIR`、向量化 reader 走到 ORC 文件时仍可能踩雷。
4. 该方法**仅作排障验证**，且必须在隔离测试库执行。

---

## 七、经验规则（沉淀到规则库）

### 规则 1：列式存储格式禁止用 REPLACE COLUMNS 减列

- **覆盖范围**：ORC、Parquet
- **判定**：`replaceCols.size() < existingCols.size()` 且表是 ORC/Parquet 列式格式
- **强制做法**：CTAS 重建表 → RENAME 切换 → DROP 旧表

### 规则 2：识别报错的双关键字

线上看到 **"return code 1 + Replacing columns cannot drop columns"** 双关键字，立即定位为本案例，不要再花时间排查 SerDe 兼容性、不要去找 Metastore 异常。

### 规则 3：删列操作前置检查清单

| 检查项 | 必须满足 |
|---|---|
| 表的 STORED AS 格式 | 行式（TEXTFILE）才允许 REPLACE 减列 |
| 是否 ACID 表 | ACID 表无论格式都禁止 REPLACE 减列 |
| `hive.exec.schema.evolution` | 不要尝试用关闭这个开关绕过校验 |
| 删列方案 | 优先 CTAS 重建，其次"逻辑下线但保留 schema" |

### 规则 4：CHANGE/REPLACE COLUMNS 的列序坑

即便你做的是"加列+改序"，对 ORC 表来说改列序也会触发数据错位。任何涉及"删列、换序"的需求 → 一律 CTAS。

---

## 八、一句话总结

> ORC 是按**列号**存储的，REPLACE COLUMNS 只改 Metastore 不改文件。一旦减少列数，老 ORC 文件读出来就会**错位**。Hive 在 `DDLTask.java`（3.1.3）/ `AlterTableReplaceColumnsOperation`（master）里硬卡了一刀：`replaceCols.size() < existingCols.size()` ⇒ 抛 10313，**默认不可绕**。删列请 CTAS 重建表。

---

## 九、参考资料

- 社区源码：`D:\bigdata\gitproject\hive` 分支 master，commit 639aa03ee5
- 线上源码：`D:\bigdata\txproject\hive` 分支 dev/edwin-3.1.3-xinxiwang，HEAD 69ec3659cc
- 关键文件：
  - `ql/src/java/org/apache/hadoop/hive/ql/exec/DDLTask.java`（3.1.3）
  - `ql/src/java/org/apache/hadoop/hive/ql/ddl/table/column/replace/AlterTableReplaceColumnsOperation.java`（master）
  - `common/src/java/org/apache/hadoop/hive/ql/ErrorMsg.java`
  - `common/src/java/org/apache/hadoop/hive/conf/HiveConf.java`
- 相关 negative 测试用例：
  - `ql/src/test/results/clientnegative/orc_replace_columns1.q.out`
  - `ql/src/test/results/clientnegative/orc_replace_columns1_acid.q.out`
  - `ql/src/test/results/clientnegative/parquet_alter_part_table_drop_columns.q.out`
