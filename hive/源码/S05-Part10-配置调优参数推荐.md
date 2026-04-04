# 10 - Hive 卡住问题配置调优指南

> 针对十大卡住场景的所有相关 HiveConf / HDFS / Metastore 参数

---

## 一、紧急必改（默认配置有风险）

这些参数**默认值就可能导致卡住**，建议所有环境立即调整：

```xml
<!-- ============================================ -->
<!-- 1. 编译锁 — 默认全局串行+无限等待 → 极高风险 -->
<!-- ============================================ -->

<!-- 开启并行编译（解除全局单锁） -->
<property>
    <name>hive.driver.parallel.compilation</name>
    <value>true</value>
    <!-- 默认: false → 所有查询共享一把编译锁 -->
</property>

<!-- 设置编译锁超时（防止无限等待） -->
<property>
    <name>hive.server2.compile.lock.timeout</name>
    <value>60</value>
    <!-- 默认: 0s → 无限等待!!! 设为60秒 -->
</property>

<!-- 限制并行编译数（防止并行过多OOM） -->
<property>
    <name>hive.driver.parallel.compilation.global.limit</name>
    <value>16</value>
    <!-- 默认: -1(不限制)，建议: CPU核数×2 -->
</property>
```

---

## 二、事务锁相关

```xml
<!-- ============================================ -->
<!-- 2. 事务锁等待 — 默认最长可等100分钟 -->
<!-- ============================================ -->

<!-- 减少锁重试次数 -->
<property>
    <name>hive.lock.numretries</name>
    <value>50</value>
    <!-- 默认: 100 次 -->
</property>

<!-- 减少锁重试间隔 -->
<property>
    <name>hive.lock.sleep.between.retries</name>
    <value>15</value>
    <!-- 默认: 60s → 改为15s → 最大等待≈12.5分钟 -->
</property>

<!-- 锁超时时 dump 锁状态（便于排查） -->
<property>
    <name>hive.txn.manager.dump.lock.state.on.acquire.timeout</name>
    <value>true</value>
    <!-- 默认: false -->
</property>
```

---

## 三、Metastore 连接相关

```xml
<!-- ============================================ -->
<!-- 3. Metastore 客户端超时 -->
<!-- ============================================ -->

<property>
    <name>hive.metastore.client.connect.retry.delay</name>
    <value>5</value>
    <!-- 重连延迟，秒 -->
</property>

<property>
    <name>hive.metastore.client.socket.timeout</name>
    <value>600</value>
    <!-- Socket 超时，秒 -->
</property>

<!-- Metastore 客户端本地缓存（减少RPC） -->
<property>
    <name>hive.metastore.client.cache.enabled</name>
    <value>true</value>
</property>
```

---

## 四、HDFS 操作相关

```xml
<!-- ============================================ -->
<!-- 4. HDFS 客户端超时（影响 listStatus 等） -->
<!-- ============================================ -->

<!-- 放在 core-site.xml 或 hdfs-site.xml -->
<property>
    <name>ipc.client.connect.timeout</name>
    <value>20000</value>
    <!-- NN RPC 连接超时，20秒 -->
</property>

<property>
    <name>ipc.client.connect.max.retries.on.timeouts</name>
    <value>3</value>
</property>

<property>
    <name>dfs.client.socket-timeout</name>
    <value>60000</value>
    <!-- NN RPC socket超时，60秒 -->
</property>

<!-- ============================================ -->
<!-- 文件操作线程数 -->
<!-- ============================================ -->

<property>
    <name>hive.metastore.fshandler.threads</name>
    <value>25</value>
    <!-- 默认: 15，增加并行度 -->
</property>

<property>
    <name>hive.mv.files.thread</name>
    <value>25</value>
    <!-- 默认: 15 -->
</property>
```

---

## 五、Session 与查询超时

```xml
<!-- ============================================ -->
<!-- 5. 防止查询永久挂起 -->
<!-- ============================================ -->

<!-- 空闲操作超时 -->
<property>
    <name>hive.server2.idle.operation.timeout</name>
    <value>7200000</value>
    <!-- 2小时，毫秒 -->
</property>

<!-- 空闲 session 超时 -->
<property>
    <name>hive.server2.idle.session.timeout</name>
    <value>43200000</value>
    <!-- 12小时，毫秒 -->
</property>

<!-- Session 内并行操作（保持默认true） -->
<property>
    <name>hive.server2.parallel.ops.in.session</name>
    <value>true</value>
    <!-- 默认: true → 不限制，设为false会启用operationLock有死锁风险 -->
</property>
```

---

## 六、小文件治理（治根本）

```sql
-- 开启自动合并小文件
SET hive.merge.mapfiles=true;
SET hive.merge.mapredfiles=true;
SET hive.merge.smallfiles.avgsize=128000000;  -- 128MB
SET hive.merge.size.per.task=256000000;       -- 256MB

-- 开启 CBO 优化器（减少编译时间）
SET hive.cbo.enable=true;
SET hive.compute.query.using.stats=true;
SET hive.stats.fetch.column.stats=true;
```

---

## 七、配置参数速查表

| 场景 | 参数键名 | 默认值 | 推荐值 | 风险等级 |
|------|----------|--------|--------|:--------:|
| 编译锁-并行 | `hive.driver.parallel.compilation` | `false` | `true` | 🔴 |
| 编译锁-超时 | `hive.server2.compile.lock.timeout` | `0s` | `60s` | 🔴 |
| 编译锁-限制 | `hive.driver.parallel.compilation.global.limit` | `-1` | `16` | 🟡 |
| 事务锁-重试 | `hive.lock.numretries` | `100` | `50` | 🟡 |
| 事务锁-间隔 | `hive.lock.sleep.between.retries` | `60s` | `15s` | 🟡 |
| HMS-socket超时 | `hive.metastore.client.socket.timeout` | `600s` | `600s` | 🟢 |
| FS-线程数 | `hive.metastore.fshandler.threads` | `15` | `25` | 🟢 |
| 文件移动-线程 | `hive.mv.files.thread` | `15` | `25` | 🟢 |
| Session-并行 | `hive.server2.parallel.ops.in.session` | `true` | `true` | 🟡 |
| HDFS-RPC超时 | `ipc.client.connect.timeout` | `20000` | `20000` | 🟡 |
| HDFS-socket超时 | `dfs.client.socket-timeout` | `60000` | `60000` | 🟡 |
| 空闲操作超时 | `hive.server2.idle.operation.timeout` | `0`(不超时) | `7200000` | 🟡 |
