# Amoro Orphan Files Clean 误删活跃表 Manifest 文件

## 问题概述

Amoro AMS 的 OrphanFilesCleaningExecutor 在清理一张新注册的空壳表时，由于该表与原始业务表共享同一物理目录，将原始表正在使用的 3093 个 metadata 文件和 79 个 data 文件全部误删，导致原始表查询报 NotFoundException。

## 环境信息

| 项目 | 值 |
|------|-----|
| Amoro 版本 | emr-0.7.0 |
| AMS 节点 | 10.3.2.221 |
| 时间 | 2026-04-29 14:09 |
| 影响 | 当天 23+ 张表共 37,295 个文件被误删 |
| 存储 | CHDFS (ofs://) |

## 根因

### 两张表共享同一物理目录

| 表 | tableId | metadata 版本 | 身份 |
|---|---------|--------------|------|
| `java_cardloan_db_data_user_check` | 153318 | 16017 | 原始业务表（有大量 snapshot 和数据） |
| `java_cardloan_db_data_user_check_1777000058` | 188662 | 00000 | 新注册的空壳表（0 snapshot） |

两张表的 table location 指向同一物理路径：
```
ofs://f14ml4o7gota-ZEzY.chdfs.ap-guangzhou.myqcloud.com/user/hive/warehouse/xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/
```

### 事故因果链

1. 新表 (tableId=188662) 被注册到 Amoro，location 指向旧表的目录，metadata 版本 = 00000（空表）
2. OrphanFilesCleaningExecutor 轮到新表执行 orphan clean
3. `table.refresh()` 加载 `00000-730f1fb2-...metadata.json` → 0 snapshot
4. `getValidMetadataFiles()` → 0 snapshot → valid files = 2（仅 metadata.json + version-hint.text）
5. 扫描 metadata/ 目录 → 目录里有旧表 153318 的 16000+ 个文件 → 除 2 个外全判定为孤儿
6. 删除 3093 个 metadata 文件（全是旧表的 manifest-list、manifest avro、历史 metadata.json）
7. 扫描 data/ 目录 → 同理删除 79 个 content 文件
8. 旧表 153318 下一次 refresh → NotFoundException

### 代码缺陷

`IcebergTableMaintainer.getValidMetadataFiles()` (L577-601) 在 snapshot=0 时只返回 2 个 valid 文件（当前 metadata.json + version-hint.text），没有任何安全校验就允许后续删除 metadata 目录下的所有其他文件。

## 事故时间线（附完整日志）

### 14:09:16 — 新表开始 orphan clean

```
2026-04-29 14:09:16,751 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 start cleaning orphan files in content
```

### 14:09:40 — 删除 79 个 content 文件

```
2026-04-29 14:09:40,093 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058: There were 79 files slated for deletion and 79 files were successfully deleted
```

### 14:09:40 — 发现 0 snapshot，仅 2 个 valid files

```
2026-04-29 14:09:40,101 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 getRuntime 0 snapshots to scan
```

```
2026-04-29 14:09:40,101 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 table getRuntime 2 valid files
```

```
2026-04-29 14:09:40,101 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058 table getRuntime exclude file name pattern null
```

### 14:09:40 — 开始扫描 metadata 目录

```
2026-04-29 14:09:40,101 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - start orphan files clean in ofs://f14ml4o7gota-ZEzY.chdfs.ap-guangzhou.myqcloud.com/user/hive/warehouse/xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata
```

### 14:09:43 — 删除 3093 个 metadata 文件

```
2026-04-29 14:09:43,644 INFO [async-orphan-files-cleaning-executor-3] [org.apache.amoro.server.optimizing.maintainer.IcebergTableMaintainer] [] - iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check_1777000058: There were 3093 metadata files to be deleted and 3093 metadata files were successfully deleted
```

### 14:10:04 — 旧表 refresh 失败

```
2026-04-29 14:10:04,544 ERROR Refreshing table iceberg.xy_rt_60d_snap.java_cardloan_db_data_user_check(tableId=153318) failed.
org.apache.iceberg.exceptions.NotFoundException: Failed to open input stream for file: ofs://f14ml4o7gota-ZEzY.chdfs.ap-guangzhou.myqcloud.com/user/hive/warehouse/xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata/d3cecc64-9de6-49b8-a237-6cb6b504e5f8-m14.avro
```

### 15:11:05 — 用户查询报错

```
2026-04-29 15:11:05,544 [ERROR] [main] SparkSQLDriver: Failed in [select * from xy_rt_60d_snap.java_cardloan_db_data_user_check limit 1]
org.apache.iceberg.exceptions.NotFoundException: Failed to open input stream for file: ofs://f14ml4o7gota-ZEzY.chdfs.ap-guangzhou.myqcloud.com/user/hive/warehouse/xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata/d3cecc64-9de6-49b8-a237-6cb6b504e5f8-m14.avro
        at org.apache.iceberg.hadoop.HadoopInputFile.newStream(HadoopInputFile.java:185)
        at org.apache.iceberg.avro.AvroIterable.newFileReader(AvroIterable.java:100)
Caused by: java.io.FileNotFoundException: No such file or directory 'ofs://f14ml4o7gota-ZEzY.chdfs.ap-guangzhou.myqcloud.com/user/hive/warehouse/xy_rt_60d_snap.db/java_cardloan_db_data_user_check_1777000058/metadata/d3cecc64-9de6-49b8-a237-6cb6b504e5f8-m14.avro'
```

## 影响范围

仅 4 月 29 日当天：

| 指标 | 数据 |
|------|------|
| 出现 0-snapshot 的表 | 48 张 |
| 被执行 metadata 删除的表 | 23+ 张 |
| 被删除的 metadata 文件总数 | 37,295 个 |
| 已报 NotFoundException 的表 | 至少 3 张 |

## 修复方案

### 源码修复（已在 emr-0.7.0 分支实施）

文件：`amoro-ams/amoro-ams-server/src/main/java/org/apache/amoro/server/optimizing/maintainer/IcebergTableMaintainer.java`

**Guard 1 — 源头防护 (`getValidMetadataFiles()` 内部)**：

```java
if (size == 0) {
    LOG.warn("{} has 0 snapshots, cannot determine valid metadata files reliably", tableName);
    return Collections.emptySet();
}
```

snapshot=0 时返回空集合，表示"无法可靠判断哪些文件是 valid"。

**Guard 2 — 调用方拦截 (`clearInternalTableMetadata()` 入口)**：

```java
if (validFiles.size() <= 5) {
    LOG.warn("{} has only {} valid metadata files, which is suspiciously low. "
        + "Skipping orphan metadata clean to prevent potential data loss",
        table.name(), validFiles.size());
    return;
}
```

valid files 过少时直接跳过清理。

### 运维止血

```yaml
# config.yaml 临时关闭 orphan clean
clean-orphan-files:
  enabled: false
```

## 经验规则

1. **Orphan clean 必须有 snapshot=0 安全校验** — snapshot 为空时无法构建完整的 valid 文件集合，不应执行任何删除
2. **禁止多张表共享同一物理目录** — 如果无法避免，orphan clean 必须检查目录是否被其他表引用
3. **删除操作前必须有比例校验** — 一次性删除超过 90% 的 metadata 文件在任何场景下都不合理
4. **新注册的空表应延迟 orphan clean** — 至少等到有 1 个以上有效 snapshot 后才开启
