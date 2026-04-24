# 案例：Hive Metastore 大小写不敏感 vs 底层对象存储路径大小写敏感

> 归档人：天问  
> 日期：2026-04-24  
> 源码参考根：`D:\bigdata\txproject\hive`、`D:\bigdata\txproject\hadoop`  
> 关联 Skill：`hivemetastore-expert`、`hive-expert`、`challenger`

---

## 一、结论一句话

**Hive Metastore 的 MySQL 后端默认使用 `utf8_general_ci` 不区分大小写，但底层 HDFS / COS / CHDFS 路径全部区分大小写，两者在分区值、`SDS.LOCATION`、`DBS.DB_LOCATION_URI` 等字段上发生语义错配，导致分区丢失/重复、DROP PARTITION 误删、MSCK 修复结果飘忽。修复方案：把 Metastore 关键业务标识字段的 collation 从 `utf8_general_ci` 改为 `utf8_bin`（二进制、case-sensitive），与底层 FS 行为对齐。**

---

## 二、现象

1. 用户通过 Spark / Hive 写入一个 `EXTERNAL TABLE`，分区值包含大小写（如 `country=US`）。
2. 某次作业误将分区值写成小写（`country=us`），在对象存储上生成了**两个目录**：
   - `cosn://bucket/warehouse/db/t/country=US/`
   - `cosn://bucket/warehouse/db/t/country=us/`
3. 但 Metastore 里 `SELECT * FROM PARTITIONS WHERE PART_NAME='country=us'` 与 `...='country=US'` 返回**同一行**，`INSERT ... PARTITION(country='us')` 报错 `AlreadyExistsException`。
4. `MSCK REPAIR TABLE t`：有时识别出 US，有时识别出 us，结果不稳定。
5. `DROP PARTITION (country='us')`：逻辑上删了一条元数据，物理上可能删了 `US/` 或 `us/` 的其中一个（取决于 `SDS.LOCATION` 当初写入的是哪个大小写），剩下的孤儿目录数据被**遗弃或错读**。

下面截图（用户提供）就是通过 DMS 对 `PARTITIONS` 表结构的 `PART_NAME` 字段把校验规则改为 `utf8mb3_bin`：

- 操作路径：左侧选中 `hivemetastore` 库 → `PARTITIONS` → 操作 → 编辑表结构 → 第 4 行 `PART_NAME`（varchar(767)）→ 字符集 `utf8mb3` → 校验规则下拉选 `utf8mb3_bin` → 提交。
- 等效 SQL：`ALTER TABLE PARTITIONS MODIFY COLUMN PART_NAME VARCHAR(767) CHARACTER SET utf8 COLLATE utf8_bin;`

---

## 三、根因（源码证据链）

### 3.1 Hive Metastore 侧：存入时只对"列名"做小写化，不对"值"做

**文件**：`standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/utils/FileUtils.java` L384-396

```java
public static String makePartName(List<String> partCols, List<String> vals,
                                  String defaultStr) {
  StringBuilder name = new StringBuilder();
  for (int i = 0; i < partCols.size(); i++) {
    if (i > 0) name.append(Path.SEPARATOR);
    name.append(escapePathName((partCols.get(i)).toLowerCase(), defaultStr)); // ← key 被强制小写
    name.append('=');
    name.append(escapePathName(vals.get(i), defaultStr));                     // ← value 原样保留
  }
  return name.toString();
}
```

`escapePathName`（L258-283）只做 URL 百分号转义，**不改大小写**。

结论：`country='US'` 与 `country='us'` 在 `PART_NAME` 列的值分别是 `country=US`、`country=us`，**物理上是两个不同字符串**。

### 3.2 DirectSQL 分区查询：只对库名表名小写，对 PART_NAME 走裸等值比较

**文件**：`standalone-metastore/src/main/java/org/apache/hadoop/hive/metastore/MetaStoreDirectSql.java` L553-593

```java
private List<Partition> getPartitionsViaSqlFilterInternal(
    String catName, String dbName, String tblName, ...) {
  final String dbNameLcase = dbName.toLowerCase(),
               tblNameLcase = tblName.toLowerCase(); // ← Hive 保证库表名在 MetaStore 里全小写
  ...
  String queryText = "select ... from " + PARTITIONS +
      " inner join " + TBLS + " on ... and " + TBLS + ".\"TBL_NAME\" = ? " +
      " inner join " + DBS  + " on ... and " + DBS  + ".\"NAME\" = ? " +
      ...
  // PART_NAME 过滤是作为 sqlFilter 直接拼进来的，由 JDBC PreparedStatement 走 MySQL 的默认 collation 匹配
}
```

这里的关键：Java 侧 `tblName.toLowerCase()` 保证 `TBLS.TBL_NAME` 命中稳定（因为 Hive DDL 要求表名小写），**但 PART_NAME 是用户数据，Hive 不做任何规范化**，完全依赖 MySQL 的 collation 来决定 `WHERE PART_NAME = ?` 的匹配策略。

### 3.3 JDO 映射层：VARCHAR 字段没有声明 COLLATE

**文件**：`standalone-metastore/src/main/resources/package.jdo`

```xml
<class name="MTable" table="TBLS" ...>
  <field name="tableName">
    <column name="TBL_NAME" length="256" jdbc-type="VARCHAR"/>
  </field>
</class>
<!-- PART_NAME / DB_NAME / NAME / LOCATION 同样只声明了 jdbc-type="VARCHAR"，无 COLLATE -->
```

DataNucleus 建表时使用 MySQL 会话的默认 collation（绝大多数历史部署是 `utf8_general_ci`），因此数据库层的 `PART_NAME` 字段实际 collation 是 `utf8_general_ci` → **查询、唯一索引判定都忽略大小写**。

### 3.4 Hadoop FileSystem 侧：全部 case-sensitive

| FileSystem | 证据 | 结论 |
|---|---|---|
| **HDFS** | `INodeWithAdditionalFields.name` 是 `byte[]`；`INodeDirectory.searchChildren` 走 `Collections.binarySearch`，字节级比较；`FSDirectory.resolvePath` 全流程无 `toLowerCase`/`equalsIgnoreCase`。 | case-sensitive |
| **Hadoop Path** | `Path.normalizePath()` 只合并斜杠，`equals/hashCode/compareTo` 委托 `java.net.URI`；path 部分按 RFC 3986 不做大小写归一化。 | path 部分 case-sensitive |
| **COS (CosN)** | 源码在独立仓库 `github.com/tencentyun/hadoop-cos`，Maven 坐标 `com.qcloud.cos:hadoop-cos`。底层 COS 对象存储 Object Key 官方文档明确 case-sensitive。 | case-sensitive |
| **CHDFS** | 源码在独立仓库 `github.com/tencentyun/chdfs-hadoop-plugin`，坐标 `com.qcloud.chdfs:chdfs-hadoop-plugin-shaded`；服务端 HDFS 兼容语义。 | case-sensitive |

### 3.5 错配发生的链条

```
写入路径：
  INSERT PARTITION(country='US')
    → Hive 生成 PART_NAME = "country=US"
    → SDS.LOCATION = "cosn://.../country=US"
    → 对象存储真实目录：country=US/

  INSERT PARTITION(country='us')
    → Hive 生成 PART_NAME = "country=us"
    → DataNucleus 唯一索引 (TBL_ID, PART_NAME) 去重，MySQL 用 ci collation 比较
    → "country=US" ci== "country=us" → TRUE → 抛 AlreadyExistsException
    → 但此时对象存储上 country=us/ 目录可能已经被客户端直接写进去了
    → 元数据侧只认 country=US，country=us/ 成了孤儿

读取路径：
  SELECT * FROM t WHERE country='us'
    → Metastore 用 ci collation 返回的仍是 country=US 那行
    → Spark/Hive 根据 SDS.LOCATION 读 country=US/ 数据
    → 结果集丢失真正的 us/ 目录内容
```

### 3.6 相关社区 JIRA

- **HIVE-8485**：早期已讨论 Metastore 表名应存小写，但未涉及分区值。
- **HIVE-6384 / HIVE-20613**：关于分区路径大小写的周边讨论，结论是 Hive 不对 value 做 normalize，**需要通过 MySQL collation 来对齐**。
- **HIVE-22961 / HIVE-24436**：涉及 MetaStore schema 中部分关键字段显式加 `BINARY` / `utf8_bin` 的 patch，但并未完整覆盖 PART_NAME / LOCATION。

---

## 四、解决方案（经 Challenger 审查）

### 4.1 最小修改集（只改关键业务标识字段）

```sql
-- ⚠️ 执行前必须：1) Metastore 全量备份  2) 停机或冷窗口  3) 确认无存量大小写冲突分区（见 4.3 预检 SQL）

USE hivemetastore;

-- 分区名（最关键）
ALTER TABLE PARTITIONS MODIFY COLUMN PART_NAME VARCHAR(767)
  CHARACTER SET utf8 COLLATE utf8_bin;

-- 数据库与表名路径相关（Hive 本身会 toLowerCase 表名/库名，但 LOCATION 不会）
ALTER TABLE DBS MODIFY COLUMN DB_LOCATION_URI VARCHAR(4000)
  CHARACTER SET utf8 COLLATE utf8_bin;
ALTER TABLE SDS MODIFY COLUMN LOCATION VARCHAR(4000)
  CHARACTER SET utf8 COLLATE utf8_bin;

-- 可选：如果你的 Skew / PartitionKeyValue 也出现过大小写问题
ALTER TABLE SKEWED_STRING_LIST_VALUES MODIFY COLUMN STRING_LIST_ID_KID BIGINT; -- 纯数值无需改
ALTER TABLE PARTITION_KEY_VALS MODIFY COLUMN PART_KEY_VAL VARCHAR(256)
  CHARACTER SET utf8 COLLATE utf8_bin;
```

**不建议改的字段**：

| 字段 | 原因 |
|---|---|
| `TBLS.TBL_NAME` / `DBS.NAME` | Hive 在 Java 层已经 `toLowerCase()`，改成 bin 反而暴露任何绕过 Java 层的脏写入（但一般更安全），**可选**改 |
| `TABLE_PARAMS.PARAM_VALUE` / `SD_PARAMS.PARAM_VALUE` | 参数键值，业务型非路径型，改 collation 可能导致旧参数查询不中 |
| `COLUMNS_V2.COLUMN_NAME` | 列名 Hive 默认 lower case，不涉及物理路径 |

### 4.2 验证 SQL

```sql
-- 验证 collation 是否生效
SELECT TABLE_NAME, COLUMN_NAME, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'hivemetastore'
  AND COLUMN_NAME IN ('PART_NAME','LOCATION','DB_LOCATION_URI');
-- 期望：COLLATION_NAME = utf8_bin

-- 验证大小写区分生效
SELECT PART_NAME FROM PARTITIONS
WHERE BINARY PART_NAME = 'country=US';  -- 显式 BINARY 比较，与 utf8_bin 等价
```

### 4.3 执行前预检（Challenger 强制要求）

```sql
-- 找出所有 ci 视角下重复、bin 视角下不同的 PART_NAME（存量大小写冲突）
SELECT TBL_ID, LOWER(PART_NAME) AS lkey, COUNT(*) cnt, GROUP_CONCAT(PART_NAME)
FROM PARTITIONS
GROUP BY TBL_ID, LOWER(PART_NAME)
HAVING COUNT(*) > 1;
```

如果返回非空：**必须先清洗**（归一为一种大小写，合并/删除对应对象存储目录）才能执行 ALTER。否则改完 collation，UNIQUE KEY `UNIQUEPARTITION(TBL_ID, PART_NAME)` 仍会在 bin 模式下保留多条，但下次 INSERT 可能因历史孤儿触发异常。

### 4.4 回归测试用例

```sql
-- Hive 侧
CREATE EXTERNAL TABLE test_case_t(id INT) PARTITIONED BY (c STRING)
LOCATION 'cosn://bucket/warehouse/test_case_t/';

INSERT INTO test_case_t PARTITION (c='US') VALUES (1);
INSERT INTO test_case_t PARTITION (c='us') VALUES (2);  -- 应能成功（改前会报 AlreadyExists）
SHOW PARTITIONS test_case_t;                            -- 应看到两行：c=US 和 c=us
SELECT * FROM test_case_t WHERE c='US';                 -- 期望 id=1
SELECT * FROM test_case_t WHERE c='us';                 -- 期望 id=2
```

---

## 五、风险点与回滚

| 风险 | 缓解 |
|---|---|
| 改 collation 后，过往**不区分大小写的查询**（如 `WHERE partcol='US'`，实际数据是 `us`）会查不出结果 | 事先排查业务 SQL 中的分区过滤；如有历史脏数据先清洗 |
| `ALTER TABLE PARTITIONS MODIFY` 在大表上耗时较长 | 预留停机窗口；使用 `pt-online-schema-change` 在线改（需 MySQL ≥ 5.6） |
| 低版本 MySQL（<5.5.3）不支持 `utf8mb4`，注意别混用 | 统一使用 `utf8`（三字节）+ `utf8_bin` |
| 若后续升级到 Hive 4 / 使用 Iceberg/Hudi 管理元数据 | Iceberg/Hudi 有自己的分区 schema，不走 Hive Metastore 的 PART_NAME，影响有限 |
| 回滚 | `ALTER TABLE ... MODIFY COLUMN ... COLLATE utf8_general_ci;` 即可，但回滚后若已经产生了大小写差异分区，会再次触发 AlreadyExists |

---

## 六、源码分析总结（给后续同事的一页速查）

| 层次 | 对大小写的态度 | 关键代码 |
|---|---|---|
| **HDFS NameNode** | byte 级严格 case-sensitive | `INode.name: byte[]`、`searchChildren` binarySearch |
| **Hadoop Path** | path 部分 case-sensitive，scheme/host 不敏感（URI 规范） | `Path.normalizePath`、`java.net.URI.equals` |
| **COS / CHDFS** | case-sensitive（源码在腾讯云独立仓库） | `hadoop-cos` / `chdfs-hadoop-plugin` |
| **Hive Warehouse** | 库名/表名 `toLowerCase`，**分区值原样**，路径拼接保留原大小写 | `Warehouse.dbDirFromDbName`、`FileUtils.makePartName` |
| **Hive ObjectStore (JDO)** | 对库名/表名调 `normalizeIdentifier`（小写化），**对分区值和 LOCATION 不做归一化** | `ObjectStore.getMTable` 入口、`normalizeIdentifier` |
| **Hive package.jdo** | 字段只声明 VARCHAR，无 COLLATE → 随 MySQL 默认走 | `package.jdo` 全文无 `collate` 关键字 |
| **MySQL Metastore schema** | 历史脚本 `hive-schema-*.mysql.sql` 仅对 `MASTER_KEY`、token 字段用 `BINARY`，核心业务字段未加 | `standalone-metastore/src/main/sql/mysql/` |

**一句话**：Hive 把"大小写处理"这个职责**隐式下放给了 MySQL collation**，而默认 collation 选了 `ci`，与底层 case-sensitive 的对象存储相矛盾 → 本质是**Hive 存储层与计算层的 case-sensitivity 约定未对齐**。

---

## 七、后续动作建议（长期）

1. **巡检模板**：把 4.3 的预检 SQL 纳入 Metastore 周期巡检，提前发现潜在冲突分区。
2. **新集群 init script**：在 `hive-schema-*.mysql.sql` 执行之后，自动追加本文 4.1 的 ALTER，成为部署标准动作。
3. **社区贡献**：给 Hive 社区提 PR / JIRA，在 `package.jdo` 中对 `PART_NAME`、`SDS.LOCATION`、`DBS.DB_LOCATION_URI` 显式声明 `column.extension jdbc-type="VARCHAR" length="..."` 并加 `<extension vendor-name="datanucleus" key="mysql-collation" value="utf8_bin"/>`，彻底根治。
4. **文档沉淀**：本文归档路径 `case-hive-metastore-collation.md`，加入内部知识库 `hivemetastore-expert` Skill 的 FAQ 段。
