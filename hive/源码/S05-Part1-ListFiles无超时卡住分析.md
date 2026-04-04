# 01 - List 文件操作卡住分析

> 风险等级: 🟡 P1 | 触发条件: NN 高负载/不可达/大量小文件 | 影响: 当前线程无限阻塞

---

## 一、问题概述

Hive 源码中存在 **17+ 处** 无超时保护的 `listStatus`/`globStatus`/`listFiles` 调用。这些调用底层是 HDFS NameNode 的 RPC 请求，当 NN 负载高、网络异常或目录下文件极多时，会导致当前线程无限阻塞。

### 因果链

```
[NN 高负载/网络抖动/大量小文件] 
  → [listStatus RPC 无超时，线程阻塞在 HDFS 客户端] 
    → [持有编译锁/执行锁的线程卡住]
      → [其他查询等待编译锁]
        → [用户感知: beeline 无响应]
```

---

## 二、关键阻塞点详细分析

### 2.1 Hive.java — 核心数据操作类（7172行）

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/metadata/Hive.java`

#### 高风险调用点

| # | 行号 | 方法 | 调用 | 场景 | 风险 |
|---|------|------|------|------|------|
| 1 | ~3119 | `listFilesInsideAcidDirectory()` | `srcFs.listStatus(acidDir, filter)` | ACID 目录递归遍历 | 🔴 递归无深度限制 |
| 2 | ~3119 | `listFilesInsideAcidDirectory()` | `srcFs.listStatus(acidDir)` | 同上无 filter 版本 | 🔴 递归无深度限制 |
| 3 | ~4096 | `constructInsertEventData()` | `fileSystem.listStatus(dir)` | BFS 遍历，`while(!directories.isEmpty())` | 🔴 无限循环+无超时 |
| 4 | ~5041 | 数据加载 | `srcFs.listStatus(src.getPath(), ...)` | 加载数据列出源文件 | 🟡 大分区时阻塞 |
| 5 | ~5274 | 文件检查 | `destFS.listStatus(dest, ...)` | 检查目标目录已有文件 | 🟡 |
| 6 | ~5377 | 源目录交叉 | `destFs.listStatus(srcf, ...)` | srcIsSubDirOfDest 场景 | 🟡 |
| 7 | ~5592 | `addFiles()` | `srcFs.globStatus(srcf)` | 正则匹配，可能扫描大量文件 | 🟡 glob 比 list 更慢 |
| 8 | ~5653 | ACID 文件移动 | `fs.listStatus(srcPath, AcidUtils.originalBucketFilter)` | 列出 bucket 文件 | 🟡 |
| 9 | ~5675 | Union 子目录 | `fs.globStatus(new Path(srcPath, ...))` | Union 子目录扫描 | 🟡 |
| 10 | ~5675 | Union 子目录 | `fs.listStatus(unionSubdir.getPath(), ...)` | 逐个 union 子目录 list | 🟡 |
| 11 | ~5712 | Delta 文件查找 | `fs.listStatus(origBucketPath, pathFilter)` | 查找 delta 文件 | 🟡 |
| 12 | ~5798 | ACID 移动 | `fs.listStatus(deltaPath, AcidUtils.bucketFileFilter)` | 列出 bucket 文件 | 🟡 |
| 13 | ~5854 | `addFiles()` 另一入口 | `srcFs.globStatus(srcf)` | 同 #7 | 🟡 |
| 14 | ~5991 | 通用文件遍历 | `fs.listStatus(path, pathFilter)` | 通用路径 | 🟡 |
| 15 | ~3217 | ListBucketing | `fSys.listStatus(fSta.getPath(), ...)` | ListBucketing 目录遍历 | 🟢 |
| 16 | ~3623 | 分区加载 | `listFilesCreatedByQuery(loadPath, ...)` | 新文件列表（事件通知） | 🟡 |
| 17 | ~2872 | 分区加载 | `listFilesCreatedByQuery(loadPath, ...)` | 同上 | 🟡 |

#### 最危险代码段: `listFilesInsideAcidDirectory()`

```java
// Hive.java ~行3114-3137
public static void listFilesInsideAcidDirectory(Path acidDir, FileSystem srcFs, 
    List<Path> newFiles, PathFilter filter) throws IOException {
    FileStatus[] acidFiles = null;
    if (filter != null) {
        acidFiles = srcFs.listStatus(acidDir, filter);  // ⚠️ 无超时
    } else {
        acidFiles = srcFs.listStatus(acidDir);           // ⚠️ 无超时
    }
    if (acidFiles == null) return;
    for (FileStatus acidFile : acidFiles) {
        if (!acidFile.isDirectory()) {
            newFiles.add(acidFile.getPath());
        } else {
            listFilesInsideAcidDirectory(acidFile.getPath(), srcFs, newFiles, null);
            // ⚠️ 递归调用自身，无深度限制！
        }
    }
}
```

**问题**:
1. 每次 `listStatus` 都是一次 NN RPC，无超时保护
2. 递归调用无深度限制，深层目录结构会导致指数级 RPC 调用
3. ACID 表的 delta/base 目录可能非常深

#### 最危险代码段: `constructInsertEventData()`

```java
// Hive.java ~行4094-4107
while (!directories.isEmpty()) {       // ⚠️ 无限循环
    Path dir = directories.poll();
    FileStatus[] contents = fileSystem.listStatus(dir);  // ⚠️ 无超时
    if (contents == null) continue;
    for (FileStatus status : contents) {
        if (status.isDirectory()) {
            directories.add(status.getPath());  // ⚠️ 不断加入新目录
            continue;
        }
        addInsertNonDirectoryInformation(status.getPath(), fileSystem, insertData);
    }
}
```

**问题**: BFS 遍历，目录数随深度增长，每个目录一次 RPC

### 2.2 BasicStats.java — 统计信息计算

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/stats/BasicStats.java`

```java
// BasicStats.java ~行211
private long getFileSizeForPath(Path path) throws IOException {
    FileSystem fs = path.getFileSystem(conf);
    RemoteIterator<LocatedFileStatus> it = fs.listFiles(path, true);  // ⚠️ 递归=true
    long size = 0;
    while (it.hasNext()) {     // ⚠️ 每次 hasNext()/next() 都是一次 RPC
        size += it.next().getLen();
    }
    return size;
}
```

**问题**:
- `listFiles(path, true)` 递归列出所有文件
- `RemoteIterator` 的每次迭代都是一次 NN RPC
- 在 `BasicStats.Factory.buildAll()` 中被线程池并行调用（线程数由 `hive.metastore.fshandler.threads` 控制，默认 15），但当分区多且每个分区文件多时，15 个线程全部被阻塞

### 2.3 其他文件操作阻塞

| 文件 | 调用 | 场景 |
|------|------|------|
| `ClearDanglingScratchDir.java` | `listStatus` | 清理临时目录 |
| `FSStatsAggregator.java` | `listStatus` | 聚合统计信息 |
| `SyslogInputFormat.java` | `listStatus` | 系统日志输入格式 |
| `RowContainer.java` | `listStatus` | 行容器 |

---

## 三、线上排查

### 3.1 jstack 识别

```bash
# 搜索 listStatus 相关的阻塞
grep -A 20 "listStatus\|listFiles\|globStatus" /tmp/hs2_jstack_*.txt | grep -B 5 "BLOCKED\|WAITING\|RUNNABLE"
```

**典型 jstack 特征**:
```
"HiveServer2-Handler-Pool: Thread-123" RUNNABLE
  at org.apache.hadoop.hdfs.DFSClient.listPaths(DFSClient.java:xxxx)
  at org.apache.hadoop.hdfs.DistributedFileSystem$DirListingIterator.next(...)
  at org.apache.hadoop.fs.FileSystem.listStatus(FileSystem.java:xxxx)
  at org.apache.hadoop.hive.ql.metadata.Hive.listFilesInsideAcidDirectory(Hive.java:3119)
```

注意：线程状态通常是 **RUNNABLE**（因为在等待网络 I/O），而不是 BLOCKED。

### 3.2 日志检查

```bash
# 查看 HDFS 操作慢日志
grep -i "slow.*listStatus\|listStatus.*took\|FileSystem.*timeout" /var/log/hive/hiveserver2.log | tail -20

# 查看 HDFS 客户端超时
grep "SocketTimeoutException\|ConnectTimeoutException\|NameNode.*not.*reachable" /var/log/hive/hiveserver2.log | tail -20
```

---

## 四、修复建议

### 🔴 紧急操作

1. **HDFS 客户端超时配置**（在 `hdfs-site.xml` / `core-site.xml`）:
```xml
<!-- NN RPC 超时 -->
<property>
    <name>ipc.client.connect.timeout</name>
    <value>20000</value> <!-- 20秒 -->
</property>
<property>
    <name>ipc.client.connect.max.retries.on.timeouts</name>
    <value>3</value>
</property>
<!-- 重要：为 listStatus 等操作设置 socket 超时 -->
<property>
    <name>dfs.client.socket-timeout</name>
    <value>60000</value> <!-- 60秒 -->
</property>
```

### 🟡 短期修复

2. **增加 FS 处理线程数**:
```xml
<property>
    <name>hive.metastore.fshandler.threads</name>
    <value>25</value> <!-- 默认15，增加并行度 -->
</property>
```

3. **小文件合并**（治根本）:
```sql
-- 开启自动合并小文件
SET hive.merge.mapfiles=true;
SET hive.merge.mapredfiles=true;
SET hive.merge.smallfiles.avgsize=128000000; -- 128MB
SET hive.merge.size.per.task=256000000;      -- 256MB
```

### 🟢 长期优化

4. **代码层面**：为关键 listStatus 调用添加超时包装
5. **架构层面**：使用 Iceberg/Hudi 替代大量小文件的 Hive 表
6. **HDFS 层面**：开启 NN 的 RPC 公平调度，避免大量 list 请求饿死其他操作
