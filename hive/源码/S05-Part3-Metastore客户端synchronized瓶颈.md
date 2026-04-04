# 03 - Metastore 客户端阻塞分析

> 风险等级: 🟡 P1 | 触发条件: Metastore 不可用/创建慢 | 影响: 同 Hive 实例所有操作阻塞

---

## 一、问题概述

`Hive.java` 中的 `getMSC()` 方法是 **synchronized** 的，它是所有 Metastore 操作的入口。整个 Hive.java 中有 **90+ 处** 调用 `getMSC()`。当 Metastore 连接创建慢或不可用时，一个线程卡在 `getMSC()` 中会阻塞同一个 `Hive` 实例的所有其他 Metastore 操作。

### 因果链

```
[HMS 不可用/网络抖动/连接池满]
  → [getMSC() 中创建 MetaStoreClient 卡住 (synchronized)]
    → [同 Hive 实例的所有 getMSC() 调用排队]
      → [编译阶段的 getTable/getPartitions 全部阻塞]
        → [编译锁持有时间延长]
          → [其他查询等待编译锁]
```

---

## 二、源码分析

### 2.1 synchronized getMSC()

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/metadata/Hive.java`

```java
// 行 6161-6163
@LimitedPrivate(value = {"Hive"})
@Unstable
public synchronized IMetaStoreClient getMSC() throws MetaException {
    return getMSC(true, false);
}

// 行 6171-6187
public synchronized IMetaStoreClient getMSC(
    boolean allowEmbedded, boolean forceCreate) throws MetaException {
    if (metaStoreClient == null || forceCreate) {
        // ⚠️ 创建 MetaStoreClient — 可能很慢
        // 涉及: 网络连接、Kerberos 认证、重试等
        metaStoreClient = createMetaStoreClient(allowEmbedded);
    }
    return metaStoreClient;
}
```

**关键**: `synchronized` 关键字意味着同一个 `Hive` 对象的所有 `getMSC()` 调用是串行的。如果 `createMetaStoreClient()` 花了 30 秒，这 30 秒内所有其他需要 MSC 的操作都被阻塞。

### 2.2 函数注册阻塞

```java
// 行 321-364: registerAllFunctionsOnce()
private void registerAllFunctionsOnce() throws HiveException {
    while (!breakLoop) {
        int val = didRegisterAllFuncs.get();
        switch (val) {
        case REG_FUNCS_PENDING: {
            synchronized (didRegisterAllFuncs) {
                didRegisterAllFuncs.wait(100);  // ⚠️ 每100ms轮询一次
            }
            continue;  // ⚠️ 继续循环等待
        }
        // ...
        }
    }
    // 注册函数需要连接 Metastore
    reloadFunctions();  // ⚠️ 如果 HMS 慢，这里会很慢
}
```

**问题**: 当一个线程在注册函数（需要连接 Metastore），其他线程每 100ms 轮询一次状态。如果注册过程很慢（HMS 不可用），大量线程会在 while 循环中空转。

### 2.3 90+ 处 getMSC() 调用

以下是 `Hive.java` 中部分典型的 `getMSC()` 调用场景：

| 行号 | 方法 | 调用 | 场景 |
|------|------|------|------|
| ~632 | createCatalog | `getMSC().createCatalog()` | 创建 catalog |
| ~753 | dropDatabase | `getMSC().dropDatabase()` | 删除数据库 |
| ~978 | alterTable | `getMSC().alter_table()` | 修改表 |
| ~1166 | alterPartition | `getMSC().alter_partition()` | 修改分区 |
| ~1428 | createTable | `getMSC().createTable()` | 创建表 |
| ~1545 | dropTable | `getMSC().dropTable()` | 删除表 |
| ~1797 | getTable | `getMSC().getTable()` | **获取表元数据（最高频）** |
| ~1590 | truncateTable | `getMSC().truncateTable()` | 截断表 |

---

## 三、线上排查

### jstack 识别

```bash
# 搜索 getMSC 相关阻塞
grep -B 2 -A 10 "getMSC\|HiveMetaStoreClient\|MetaStoreClient" /tmp/hs2_jstack_*.txt | grep -B 5 "BLOCKED\|waiting to lock"
```

**典型 jstack**:
```
"Thread-A" BLOCKED (on object monitor)
  at org.apache.hadoop.hive.ql.metadata.Hive.getMSC(Hive.java:6161)
  - waiting to lock <0x00000007xxxxx> (a org.apache.hadoop.hive.ql.metadata.Hive)
  
"Thread-B" RUNNABLE  
  at java.net.SocketInputStream.socketRead0(Native Method)
  at org.apache.thrift.transport.TSocket.read(TSocket.java:xxx)
  at org.apache.hadoop.hive.metastore.HiveMetaStoreClient.<init>(...)
  at org.apache.hadoop.hive.ql.metadata.Hive.getMSC(Hive.java:6182)
  - locked <0x00000007xxxxx> (a org.apache.hadoop.hive.ql.metadata.Hive)
```

### 日志检查

```bash
grep -i "MetaException\|Could not connect to meta store\|Connection refused\|socket timeout" \
  /var/log/hive/hiveserver2.log | tail -20
```

---

## 四、修复建议

### 🔴 紧急

```xml
<!-- Metastore 客户端连接超时 -->
<property>
    <name>hive.metastore.client.connect.retry.delay</name>
    <value>5</value> <!-- 秒 -->
</property>
<property>
    <name>hive.metastore.client.socket.timeout</name>
    <value>600</value> <!-- 秒 -->
</property>
```

### 🟡 短期

- 启用 Metastore 客户端本地缓存，减少 RPC 次数
- 增加 HMS 实例数做负载均衡
- 监控 HMS 连接池状态

### 🟢 长期

- 代码层面：将 `getMSC()` 的 `synchronized` 改为更细粒度的锁（如 `ReentrantLock` 带超时）
- 架构层面：考虑使用独立的 MSC 连接池而非 thread-local 实例
