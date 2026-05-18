# Amoro Orphan Clean 误删业务表 Manifest 事故分析

> **分析人**：eric
> **事故时间**：2026-04-29 14:09
> **Amoro 版本**：emr-0.7.0
> **AMS 节点**：10.3.2.221
> **影响范围**：单表查询失败；全集群当日 23+ 张表共 37,295 个 metadata 文件被误删

---

## 一、故障现象

业务表 `xy_rt_60d_snap.java_cardloan_db_data_user_check` 查询报 NotFoundException：

```
2026-04-29 15:11:05,544 [ERROR] [main] SparkSQLDriver: Failed in [select * from xy_rt_60d_snap.java_cardloan_db_data_user_check limit 1]
org.apache.iceberg.exceptions.NotFoundException: Failed to open input stream for file: ofs://.../xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata/d3cecc64-9de6-49b8-a237-6cb6b504e5f8-m14.avro
        at org.apache.iceberg.hadoop.HadoopInputFile.newStream(HadoopInputFile.java:185)
        at org.apache.iceberg.avro.AvroIterable.newFileReader(AvroIterable.java:100)
Caused by: java.io.FileNotFoundException: No such file or directory
```

---

## 二、用户的表修复 SOP（关键背景）

用户有一套标准的表恢复流程，利用 Iceberg 外表 rename 不改 location 的特性做"热交换"：

```
Step 1: 建一张带时间戳后缀的新表 (如 _1777452667)，走独立的新 location
Step 2: 把数据迁移到新表，验证无误
Step 3: 旧业务表 rename 成归档名 (bak_YYYYMMDD)
Step 4: 新表 rename 成业务表名
```

Iceberg 外表 rename 只改 HMS 中的表名映射，**不改变物理 location**。所以交换完后：
- 业务表名 `java_cardloan_db_data_user_check` 的 location 始终指向"某次建表时的时间戳目录"
- 被归档的 bak 表名 location 则是更早一次的时间戳目录

这里的关键问题是：**每次交换都会在 Amoro AMS 和 HMS 里留下一个带时间戳后缀的表名，如果不 DROP，这个表名就变成僵尸**。

---

## 三、本次事故的真实因果链

### 3.1 表名与 location 对应关系（事故当时）

| 表名（HMS） | Amoro tableId | location 对应的物理目录 | metadata 指针 | 状态 |
|------------|---------------|------------------------|---------------|------|
| `java_cardloan_db_data_user_check` | 153318 | `_1777000058` 目录 | 16017-...（Flink CDC 持续更新） | 活跃业务表 |
| `java_cardloan_db_data_user_check_1777000058` | 188662 | **同一** `_1777000058` 目录 | 00000-730f1fb2（停滞） | **历史僵尸表名** |

两张表在 HMS 里是两条独立记录，但它们的 location 指向同一个物理目录。

### 3.2 为什么 `_1777000058` 这个表名还在

这是**很久以前某次表修复**留下的：
- 以前某次建了 `java_cardloan_db_data_user_check_1777000058`（location 就是 `_1777000058` 目录）
- 迁数据、rename 成业务表之后，业务表的 location 就固定在 `_1777000058` 目录
- **但 `_1777000058` 这个表名本身没被 DROP**
- 这个表名在 HMS 和 Amoro AMS 里继续注册着，但它的 metadata 指针**永远停在表创建时的 `00000-` 版本**（因为没人再用这个表名去 commit）

### 3.3 Orphan Clean 触发过程

```
Amoro OrphanFilesCleaningExecutor 每 24h 轮询所有注册的表
  ↓
轮到僵尸表名 _1777000058 (tableId=188662)
  ↓
以这个表名加载 metadata → 拿到 00000-730f1fb2-...metadata.json → 0 snapshot
  ↓
getValidMetadataFiles() 在 0 snapshot 下只能识别出 2 个文件
  （当前 metadata.json + version-hint.text）
  ↓
扫描 location 物理目录的 metadata/ 子目录
  → 发现 3095 个文件（其中 3093 个是业务表 153318 正在使用的）
  ↓
2 个 valid 之外的 3093 个全判定为"孤儿" → 物理删除
  ↓
业务表 153318 下次 refresh → 读不到 manifest → NotFoundException
```

### 3.4 本次恢复又埋了一颗雷

4-29 约 16:00 用户做恢复：
- 建 `java_cardloan_db_data_user_check_1777452667`（新 location）
- 数据迁移
- 旧表 rename 成 `bak_20260429`
- 新表 rename 成业务表

**如果 `_1777452667` 这个表名不 DROP，24h 后 orphan clean 会再次以这个僵尸表名的视角执行，把当前业务表（location = `_1777452667`）的文件全部删掉。**

---

## 四、关键日志证据（真实原文）

### 僵尸表名的 metadata 指针停在 `00000-`

```
2026-04-29 12:49:45,767 INFO [async-snapshots-expiring-executor-7] [org.apache.iceberg.BaseMetastoreTableOperations] [] - Refreshing table metadata from new version: ofs://.../xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata/00000-730f1fb2-c459-41e4-9085-a1a436c125be.metadata.json
```

### 业务表的 metadata 指针已到 16017（同一物理目录）

```
2026-04-29 14:10:04,159 INFO [xxx] Refreshing table metadata from new version: ofs://.../xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata/16017-32397a38-...metadata.json
```

### Orphan Clean 执行过程

```
2026-04-29 14:09:16,751 INFO [async-orphan-files-cleaning-executor-3] [IcebergTableMaintainer] iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 start cleaning orphan files in content

2026-04-29 14:09:40,093 INFO [async-orphan-files-cleaning-executor-3] [IcebergTableMaintainer] iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058: There were 79 files slated for deletion and 79 files were successfully deleted

2026-04-29 14:09:40,101 INFO [async-orphan-files-cleaning-executor-3] [IcebergTableMaintainer] iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 getRuntime 0 snapshots to scan

2026-04-29 14:09:40,101 INFO [async-orphan-files-cleaning-executor-3] [IcebergTableMaintainer] iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 table getRuntime 2 valid files

2026-04-29 14:09:43,644 INFO [async-orphan-files-cleaning-executor-3] [IcebergTableMaintainer] iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058: There were 3093 metadata files to be deleted and 3093 metadata files were successfully deleted
```

### 业务表 refresh 失败

```
2026-04-29 14:10:04,544 ERROR Refreshing table iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check(tableId=153318) failed.
org.apache.iceberg.exceptions.NotFoundException: Failed to open input stream for file: ofs://.../metadata/d3cecc64-9de6-49b8-a237-6cb6b504e5f8-m14.avro
```

---

## 五、Amoro 代码 Bug

**文件**：`amoro-ams/amoro-ams-server/src/main/java/org/apache/amoro/server/optimizing/maintainer/IcebergTableMaintainer.java`

**方法**：`getValidMetadataFiles()` (L577-601)

```java
private static Set<String> getValidMetadataFiles(Table internalTable) {
    Set<String> validFiles = new HashSet<>();
    Iterable<Snapshot> snapshots = internalTable.snapshots();
    int size = Iterables.size(snapshots);
    LOG.info("{} getRuntime {} snapshots to scan", tableName, size);
    for (Snapshot snapshot : snapshots) {
        validFiles.add(snapshot.manifestListLocation());  // size=0 时不执行
    }
    Set<String> allManifestFiles = IcebergTableUtil.getAllManifestFiles(internalTable);
    allManifestFiles.forEach(f -> validFiles.add(TableFileUtil.getUriPath(f)));  // size=0 时为空

    // 下面这段即使 size=0 仍会加入：当前 metadata.json + version-hint.text（共 2 个）
    Stream.of(
            ReachableFileUtil.metadataFileLocations(internalTable, false).stream(),
            ReachableFileUtil.statisticsFilesLocations(internalTable).stream(),
            Stream.of(ReachableFileUtil.versionHintLocation(internalTable)))
        .reduce(Stream::concat)
        .orElse(Stream.empty())
        .map(TableFileUtil::getUriPath)
        .forEach(validFiles::add);

    return validFiles;  // size=0 时返回 2 个文件，导致后续误删
}
```

**缺陷**：snapshot=0 时没有任何安全校验，返回一个"看似合法但实际残缺"的集合（只有 2 个文件），调用方拿去做"不在集合中的就是孤儿"判断，导致业务表文件被大规模误删。

---

## 六、影响范围（全集群）

| 指标 | 数据 |
|------|------|
| 出现 `0 snapshots to scan` 的表 | 48 张 |
| 被执行 metadata 删除的表 | 23+ 张 |
| 被删除的 metadata 文件总数 | 37,295 个 |
| 已报 NotFoundException 的表 | 至少 3 张（java_cardloan_db_data_user_check、cardloan_referral_db_t_referral_quota_loan、cardloan_referral_db_t_referral_sub_order） |

事故不是单表，是**大规模僵尸表名批量触发**。

---

## 七、修复方案

### 7.1 Amoro 源码修复（已在 emr-0.7.0 分支实施）

**Guard 1 — `getValidMetadataFiles()` 内部源头拦截**：

```java
if (size == 0) {
    LOG.warn("{} has 0 snapshots, cannot determine valid metadata files reliably", tableName);
    return Collections.emptySet();
}
```

**Guard 2 — `clearInternalTableMetadata()` 入口兜底**：

```java
if (validFiles.size() <= 5) {
    LOG.warn("{} has only {} valid metadata files, skipping orphan metadata clean",
        table.name(), validFiles.size());
    return;
}
```

### 7.2 运维立即止血

```bash
# 在 AMS 节点 10.3.2.221 上执行
vi /usr/local/service/amoro/conf/config.yaml
# 修改：
#   clean-orphan-files:
#     enabled: false

cd /usr/local/service/amoro && ./bin/ams.sh restart
```

### 7.3 清理 4-29 本次恢复埋下的新僵尸表名

4-29 16:00 恢复时建的 `_1777452667` 表名已经变成僵尸（业务表 rename 覆盖了它的业务意义，但它作为表名本身还在 HMS）。**不清理的话下次 orphan clean 周期再炸**。

```sql
-- 在 Kyuubi 里执行
DROP TABLE IF EXISTS xy_rt_60d_snap.java_cardloan_db_data_user_check_1777452667;
```

### 7.4 清理 Amoro AMS MySQL 里的历史僵尸注册

```bash
mysql -h 10.3.2.93 -uroot -p'Uhw876%1298a' amoro
```

```sql
-- 查所有带时间戳后缀的表名
SELECT table_id, catalog_name, db_name, table_name
FROM table_identifier
WHERE table_name REGEXP '_17[0-9]{8}$';

-- 逐条确认后清理 runtime 记录（以 tableId=188662 为例）
DELETE FROM table_runtime WHERE table_id = 188662;
DELETE FROM table_identifier WHERE table_id = 188662;
```

### 7.5 全量排查当日受影响的 23+ 张表

```sql
-- 对每张日志里出现过"metadata files to be deleted"的表执行
SELECT COUNT(*) FROM xy_rt_3d_snap.yingzhongtong_rc_db_flows LIMIT 1;
-- 如果报 NotFoundException，走同样的恢复 SOP
```

---

## 八、修订后的表恢复 SOP（根治）

```
Step 1: CREATE TABLE <业务表名>_<时间戳后缀> ... （新 location）
Step 2: INSERT INTO 新表 SELECT FROM 备份表 / 重跑 CDC
Step 3: 验证数据量 + 抽样
Step 4: ALTER TABLE <业务表名> RENAME TO <业务表名>_bak_<日期>
Step 5: ALTER TABLE <业务表名>_<时间戳后缀> RENAME TO <业务表名>
Step 6: DROP TABLE <业务表名>_<时间戳后缀>    ← 历史上漏掉的关键步骤
Step 7: 登录 AMS MySQL (10.3.2.93)，确认 table_identifier/table_runtime 里
        不再有 <业务表名>_<时间戳后缀> 的僵尸记录，有则 DELETE
Step 8: （如有必要）drop 掉不再使用的 bak 归档表
```

**一句话总结**：`rename` 不改 location 导致表名与物理目录的绑定被隐式转移，原时间戳表名如果不 DROP，就成了一颗会在下次 orphan clean 周期引爆的雷。

---

## 九、经验规则（沉淀到知识库）

| 规则 | 内容 |
|------|------|
| **R1** | Iceberg 外表 rename 不改 location。做表名热交换后，原表名必须 DROP |
| **R2** | Amoro orphan clean 对 snapshot=0 的表必须跳过，不应以残缺的 valid 集合去删除 |
| **R3** | Amoro AMS 的 table_identifier 注册独立于 HMS，DROP 表后要同步检查 AMS 是否有残留 |
| **R4** | 任何"目录级扫描删除"类逻辑都必须有兜底校验（valid 集合过小 / 删除比例过高） |
| **R5** | 生产表恢复 SOP 必须以"可重复执行 + 无残留"为验收标准，不能只看"业务能查数据了" |
