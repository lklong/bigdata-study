# UDF 调用 FileSystem.close() 导致 Hive Task 报 "Filesystem closed"

## 现象

Hive 3.1.3 MR 引擎执行 INSERT OVERWRITE + UNION ALL 查询时，Reduce Task 在 configure 阶段失败：

```
ERROR Utilities: Failed to load plan: hdfs://nameservice1/tmp/hive/hdfs/.../reduce.xml
org.apache.hive.com.esotericsoftware.kryo.KryoException: java.io.IOException: Filesystem closed
Serialization trace: tagToInput (org.apache.hadoop.hive.ql.plan.ReduceWork)
    at kryo.io.Input.fill(Input.java:166)
    ...
    at Utilities.getBaseWork(Utilities.java:474)
    at Utilities.getReduceWork(Utilities.java:346)
    at ExecReducer.configure(ExecReducer.java:110)
Caused by: java.io.IOException: Filesystem closed
    at org.apache.hadoop.hdfs.DFSClient.checkOpen(DFSClient.java:566)
    at DFSInputStream.readWithStrategy(DFSInputStream.java:877)
```

## 根因

SQL 中通过 `add jar` 引入了自定义 UDF jar（`onlineip.jar`），其中 `com.inke.udf.GitParser` 类内部使用了类似以下写法：

```java
FileSystem fs = FileSystem.get(conf);  // 获取全局缓存实例
// ... 读取 IP 库文件 ...
fs.close();                             // ❌ 关闭了全局缓存的共享实例
```

`FileSystem.get(conf)` 返回的是 Hadoop **全局缓存**（`FileSystem.CACHE`）中的共享实例，同一 scheme + authority + UGI 在整个 JVM 中只有一个。UDF 中调用 `fs.close()` 会导致同 JVM 内所有组件（包括 Hive 自身的 plan 文件读取）后续使用该 FileSystem 时报 `Filesystem closed`。

### 触发链路

```
Map Task 执行 UDF (GitParser)
  └── FileSystem.get(conf) → 缓存实例 FS@0x1234
  └── fs.close()            → FS@0x1234 被关闭

Reduce Task (同一 JVM)
  └── Utilities.getBaseWork()
      └── localPath.getFileSystem(conf) → 返回已关闭的 FS@0x1234
      └── fs.open(reduce.xml)           → 💥 Filesystem closed
      └── Kryo 反序列化中途读流失败
```

## 源码定位

### Hive 侧（Utilities.java:453-458）

```java
// getBaseWork() 中读取 plan 文件
FileSystem fs = localPath.getFileSystem(conf);  // 走全局缓存
in = fs.open(localPath);                         // 如果 fs 已关闭，此处或后续 read 报错
```

**社区状态**：从 Hive 3.1.3 到 4.3.0-SNAPSHOT，此处无重试逻辑、无 Filesystem closed 防护。

### Hadoop 侧（DFSClient.java:566）

```java
void checkOpen() throws IOException {
    if (!clientRunning) {
        throw new IOException("Filesystem closed");  // 就是这里
    }
}
```

## 修复方案

### UDF 修复（根治）

| 方案 | 代码 | 说明 |
|------|------|------|
| **A. 不关闭缓存 FS** | 删掉 `fs.close()`，只关 InputStream | 最简单 |
| **B. 用非缓存实例** | `FileSystem.newInstance(conf)` + close | 独立实例，关闭安全 |
| **C. 初始化时预加载** | `initialize()` 中读入内存，`evaluate()` 不碰 FS | 最佳实践 |

#### 方案 A 示例

```java
FileSystem fs = FileSystem.get(conf);
InputStream in = fs.open(path);
try {
    // 处理逻辑
} finally {
    IOUtils.closeStream(in);  // ✅ 只关流
    // ❌ 不要 fs.close()
}
```

#### 方案 B 示例

```java
try (FileSystem fs = FileSystem.newInstance(uri, conf)) {  // ✅ 独立实例
    InputStream in = fs.open(path);
    // ...
}  // ✅ 安全关闭
```

#### 方案 C 示例（推荐）

```java
public class GitParser extends GenericUDF {
    private byte[] ipData;

    @Override
    public void initialize(ObjectInspector[] args) {
        FileSystem fs = null;
        try {
            fs = FileSystem.newInstance(conf);
            try (FSDataInputStream in = fs.open(ipDbPath)) {
                ipData = IOUtils.toByteArray(in);
            }
        } finally {
            if (fs != null) fs.close();
        }
    }

    @Override
    public Object evaluate(DeferredObject[] args) {
        // 直接使用内存中的 ipData，不再需要 FileSystem
    }
}
```

### 不改 UDF 的止血方案

```sql
set hive.rpc.query.plan=true;  -- plan 不走 HDFS，绕过问题
```

## 核心知识点

| API | 是否缓存 | close 是否安全 |
|-----|---------|--------------|
| `FileSystem.get(conf)` | 是（全局缓存） | ❌ 不安全，影响所有使用者 |
| `path.getFileSystem(conf)` | 是（全局缓存） | ❌ 不安全 |
| `FileSystem.newInstance(conf)` | 否（独立实例） | ✅ 安全 |
| `FileSystem.getLocal(conf)` | 是（缓存） | ❌ 不安全 |

**铁律：通过 `FileSystem.get()` 获取的缓存实例，永远不要手动 close。**

## 环境信息

- Hive 3.1.3 / Hadoop 3.2.2 / MR 引擎
- UDF jar: `onlineip.jar` (`com.inke.udf.GitParser`)
- JDK: Tencent OpenJDK 1.8.0_372

## 关联 JIRA

- 社区无直接修复，属于用户 UDF 编码错误
- Hadoop 侧有讨论但未做引用计数保护：FileSystem.CACHE 的 close 不是引用计数模式

---

*分析人：eric | 2026-04-29*
