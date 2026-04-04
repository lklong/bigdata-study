# Hive 深度运维手册（拿来就能排障版）

> 版本：v2.0 | 更新：2026-04-02 | 目标：照着做，不用再查资料

---

# 第一章 Hive 架构深度理解

## 1.1 整体架构（为什么这么设计）

```
                  ┌──────────────┐
                  │   客户端      │
                  │ Beeline/JDBC │
                  └──────┬───────┘
                         │ Thrift RPC（端口 10000）
                         ▼
              ┌─────────────────────┐
              │   HiveServer2 (HS2) │  ← 可多实例，ZK 做服务发现
              │  ┌──────────────┐   │
              │  │ SQL Parser   │   │  ← 解析 SQL 语法
              │  │ Semantic     │   │  ← 语义分析（表/列是否存在）
              │  │ Optimizer    │   │  ← CBO/RBO 优化（生成执行计划）
              │  │ Compiler     │   │  ← 编译成 Tez/MR DAG
              │  └──────────────┘   │
              └──────┬──────┬───────┘
                     │      │
          ┌──────────┘      └──────────┐
          ▼                            ▼
┌──────────────────┐        ┌──────────────────┐
│  Hive MetaStore  │        │   执行引擎        │
│  (HMS)           │        │  Tez / Spark / MR │
│  ┌────────────┐  │        └────────┬─────────┘
│  │ Thrift API │  │                 │
│  │ 端口 9083  │  │                 ▼
│  └─────┬──────┘  │        ┌──────────────────┐
│        ▼         │        │  YARN            │
│  ┌────────────┐  │        │  ResourceManager │
│  │ MySQL/PG   │  │        └────────┬─────────┘
│  │ 元数据存储  │  │                 ▼
│  └────────────┘  │        ┌──────────────────┐
└──────────────────┘        │  HDFS / Iceberg  │
                            │  数据存储         │
                            └──────────────────┘
```

### 为什么要分 HS2 和 HMS？

- **HS2（HiveServer2）**：面向用户的 SQL 网关，处理查询。可以水平扩展（多实例 + ZK 负载均衡）
- **HMS（Hive MetaStore）**：存储表/分区/列的元数据。独立进程，Spark/Flink/Iceberg/Trino 都要访问它
- **分离的好处**：HS2 挂了不影响元数据；HMS 可以被多个引擎共享

### 为什么 Hive 4.0 弃用了 MR 和 Hive on Spark？

- **MR**：每个 Stage 落盘，太慢。Tez 支持 DAG 执行，中间结果内存传递
- **Hive on Spark**：维护成本高，社区资源不够同时维护两个引擎。集中力量做 Tez
- **结论**：Hive 4.0+ 只剩 Tez 一个执行引擎

---

## 1.2 MetaStore 元数据结构（为什么查 HMS 这么重要）

HMS 后端数据库中的核心表：

| 表名 | 存什么 | 排障用途 |
|------|--------|---------|
| `DBS` | 数据库信息 | 确认数据库是否存在 |
| `TBLS` | 表信息（表名、类型、所有者） | 确认表是否存在、是什么类型 |
| `SDS` | 存储描述（HDFS 路径、文件格式、分隔符） | 确认表数据在哪、什么格式 |
| `PARTITIONS` | 分区信息 | 确认分区是否注册（分区丢失 = 查不到数据） |
| `PARTITION_KEY_VALS` | 分区键值 | 分区值校验 |
| `COLUMNS_V2` | 列信息 | 确认列名/类型 |
| `TAB_COL_STATS` | 列统计信息 | CBO 优化依赖，过期会导致执行计划差 |
| `TXN_COMPONENTS` | 事务组件 | ACID 表事务排查 |
| `COMPACTION_QUEUE` | Compaction 队列 | Compaction 状态排查 |
| `HIVE_LOCKS` | 锁信息 | 锁等待排查 |

**直接查 HMS 数据库的场景**（当 HiveServer2 连不上时）：

```sql
-- 连接 HMS 后端 MySQL
mysql -h mysql-host -u hive -p hive_metastore

-- 查表的 HDFS 路径
SELECT t.TBL_NAME, s.LOCATION 
FROM TBLS t JOIN SDS s ON t.SD_ID = s.SD_ID 
WHERE t.TBL_NAME = 'your_table';

-- 查分区数量
SELECT COUNT(*) FROM PARTITIONS p 
JOIN TBLS t ON p.TBL_ID = t.TBL_ID 
WHERE t.TBL_NAME = 'your_table';

-- 查卡住的事务
SELECT * FROM TXNS WHERE TXN_STATE = 'o';  -- o=open

-- 查 Compaction 状态
SELECT * FROM COMPACTION_QUEUE WHERE CQ_STATE = 'f';  -- f=failed
```

---

# 第二章 常见故障深度排查

## 案例 1：Hive 查询突然变慢（从 5 分钟变成 2 小时）

### 完整排查过程

**第一步：确认是不是所有查询都慢（定位范围）**

```bash
# 在 HS2 日志中看最近的查询耗时
grep "Completed executing command" /var/log/hive/hiveserver2.log | tail -20
# 输出示例：
# 2026-04-02 10:15:23 Completed executing command(queryId=xxx); Time taken: 7234.56 seconds

# 如果只有特定查询慢 → 查询本身的问题（数据倾斜/SQL 写法）
# 如果所有查询都慢 → 基础设施的问题（HDFS/YARN/HMS）
```

**第二步：排查小文件（最常见原因，占 60%）**

```bash
# 查看目标表的文件数和大小
hdfs dfs -ls /user/hive/warehouse/db.db/table_name/ | wc -l
# 正常：几十到几百个文件
# 异常：上万甚至几十万个文件 → 小文件问题

# 查看文件大小分布
hdfs dfs -ls /user/hive/warehouse/db.db/table_name/ | awk '{print $5}' | sort -n | head -20
# 如果大量文件 <1MB → 严重小文件问题
# 如果文件在 64MB-256MB → 正常

# 单个分区的文件数（分区表）
hdfs dfs -ls /user/hive/warehouse/db.db/table_name/dt=2026-04-02/ | wc -l
```

**小文件为什么让查询变慢？**

```
每个小文件 → 1 个 Map Task → 1 个 JVM 进程
10000 个小文件 → 10000 个 Map Task
每个 JVM 启动 = 1-3 秒开销
光启动就要：10000 × 2s = 20000s ≈ 5.5 小时
```

**解决方案**：

```sql
-- 方案 A：设置参数让 Hive 自动合并（对新写入生效）
SET hive.merge.mapfiles = true;
SET hive.merge.mapredfiles = true;
SET hive.merge.size.per.task = 268435456;         -- 合并目标 256MB
SET hive.merge.smallfiles.avgsize = 134217728;     -- 平均 <128MB 触发合并

-- 方案 B：手动合并已有小文件（INSERT OVERWRITE 重写）
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

INSERT OVERWRITE TABLE db.table PARTITION(dt)
SELECT * FROM db.table WHERE dt = '2026-04-02';
-- 这会读取所有小文件，重新写成少量大文件

-- 方案 C：控制 Map 数（合并输入端小文件）
SET mapreduce.input.fileinputformat.split.maxsize = 268435456;  -- 256MB
SET mapreduce.input.fileinputformat.split.minsize = 134217728;  -- 128MB
SET hive.input.format = org.apache.hadoop.hive.ql.io.CombineHiveInputFormat;
-- CombineHiveInputFormat 会把多个小文件合并成一个 Map 的输入
```

**第三步：排查数据倾斜（占 25%）**

```bash
# 在 YARN UI 中查看任务
# 进入 Application → 看 Map/Reduce 的 Task 列表
# 如果 99% 的 Task 在 30 秒内完成，1% 的 Task 跑了 1 小时 → 数据倾斜
```

**怎么判断是哪个 key 倾斜？**

```sql
-- 查看 JOIN key 或 GROUP BY key 的分布
SELECT join_key, COUNT(*) as cnt 
FROM your_table 
GROUP BY join_key 
ORDER BY cnt DESC 
LIMIT 20;

-- 如果某个 key 的 count 远超其他（比如 null 值、默认值）→ 就是它
```

**解决数据倾斜**：

```sql
-- 方案 A：Hive 内置倾斜优化
SET hive.optimize.skewjoin = true;
SET hive.skewjoin.key = 100000;  -- key 出现次数超过这个值就认为倾斜

-- 方案 B：Map Join（小表直接广播）
SET hive.auto.convert.join = true;
SET hive.mapjoin.smalltable.filesize = 50000000;  -- 小表 <50MB 自动 Map Join

-- 方案 C：手动处理倾斜 key（最彻底）
-- 把倾斜 key（如 null）单独处理，非倾斜 key 正常 JOIN
SELECT * FROM (
  -- 非倾斜部分正常 JOIN
  SELECT a.*, b.* FROM table_a a JOIN table_b b ON a.key = b.key
  WHERE a.key IS NOT NULL
  UNION ALL
  -- 倾斜部分用 Map Join
  SELECT /*+ MAPJOIN(b) */ a.*, b.* FROM table_a a JOIN table_b b ON a.key = b.key
  WHERE a.key IS NULL
) t;
```

**第四步：排查统计信息过期（占 10%）**

```sql
-- 查看表统计信息是否存在
DESCRIBE FORMATTED db.table;
-- 看 Table Parameters 中的：
--   numRows: 如果是 -1 或 0 → 统计信息缺失
--   rawDataSize: 同上
--   numFiles: 应该和实际文件数一致

-- 更新统计信息
ANALYZE TABLE db.table COMPUTE STATISTICS;               -- 表级别
ANALYZE TABLE db.table COMPUTE STATISTICS FOR COLUMNS;    -- 列级别（CBO 需要）
ANALYZE TABLE db.table PARTITION(dt='2026-04-02') COMPUTE STATISTICS FOR COLUMNS;  -- 分区级别
```

**为什么统计信息过期会导致查询慢？**

```
CBO（Cost-Based Optimizer）依赖统计信息决定：
- 用 Map Join 还是 Reduce Join → 选错了性能差 10x
- 先过滤还是先 JOIN → 选错了数据量膨胀
- 分配多少个 Reducer → 太少导致单 Reducer 数据过大

统计信息过期 → CBO 估算错误 → 执行计划垃圾 → 查询慢
```

**第五步：排查 YARN 资源不足（占 5%）**

```bash
# 查看 YARN 队列使用情况
yarn queue -status default
# 如果 Used Resources 接近 Max Resources → 资源不够，任务排队

# 查看 YARN 上的应用状态
yarn application -list -appStates ACCEPTED
# 如果大量 ACCEPTED 状态 → 资源不够分配
```

---

## 案例 2：HiveServer2 连不上

### 报错信息

```
Could not open client transport with JDBC Uri: 
jdbc:hive2://host:10000/default;
Could not establish connection to jdbc:hive2://host:10000: 
Connection refused
```

### 完整排查过程

**第一步：检查 HS2 进程是否存活**

```bash
ps aux | grep HiveServer2 | grep -v grep
# 输出示例：
# hive  12345  3.2  5.1 8388608 4194304 ?  Sl  09:00  15:30 /usr/java/jdk/bin/java ... org.apache.hive.service.server.HiveServer2
# 如果没有输出 → HS2 挂了

# 检查端口是否在监听
netstat -tlnp | grep 10000
# 或
ss -tlnp | grep 10000
# 如果端口不在 → HS2 进程异常或没完全启动
```

**第二步：HS2 挂了 → 看日志找原因**

```bash
# HS2 日志
tail -500 /var/log/hive/hiveserver2.log | grep -i "error\|exception\|fatal"

# 常见死亡原因：
```

| 日志中的错误 | 含义 | 解决 |
|-------------|------|------|
| `java.lang.OutOfMemoryError: Java heap space` | HS2 堆内存不够 | 增大 `-Xmx`，如 `-Xmx16g` |
| `java.lang.OutOfMemoryError: GC overhead limit exceeded` | GC 占比过高 | 同上 + 检查是否有大量并发查询 |
| `Unable to connect to MetaStore` | HMS 连不上 | 检查 HMS（见案例 3） |
| `Connection refused to host: <zk-host>` | ZK 连不上 | 检查 ZK 集群 |
| `Caused by: java.net.BindException: Address already in use` | 端口被占 | `lsof -i :10000` 找占用进程 |

**第三步：HS2 活着但连不上 → 检查 ZK 注册**

```bash
# HS2 如果配了 ZK 服务发现，客户端是通过 ZK 找到 HS2 的
# 检查 ZK 上是否有 HS2 注册
zkCli.sh -server zk-host:2181
ls /hiveserver2
# 应该看到至少一个节点，如：
# [serverUri=hs2-host:10000;version=4.0.0;sequence=0000000001]

# 如果是空的 → HS2 注册失败，检查 hive-site.xml 中 ZK 配置
```

**第四步：网络层面排查**

```bash
# 从客户端测试连通性
telnet hs2-host 10000
# 如果连不上 → 网络/防火墙问题

# 检查防火墙
iptables -L -n | grep 10000
firewall-cmd --list-ports | grep 10000
```

---

## 案例 3：MetaStore 连接超时

### 报错信息

```
MetaException(message:Could not connect to meta store using any of the URIs provided)
javax.jdo.JDODataStoreException: Cannot create PoolableConnectionFactory
```

### 完整排查过程

**第一步：HMS 进程检查**

```bash
ps aux | grep HiveMetaStore | grep -v grep
netstat -tlnp | grep 9083
```

**第二步：HMS 日志分析**

```bash
tail -300 /var/log/hive/hive-metastore-*.log | grep -i "error\|exception"

# 高频错误：
```

| 日志错误 | 含义 | 解决 |
|---------|------|------|
| `Communications link failure` | MySQL 连接断了 | 检查 MySQL 进程 + 网络 |
| `Too many connections` | MySQL 连接数满 | `SHOW PROCESSLIST` 看谁在占，调大 `max_connections` |
| `Lock wait timeout exceeded` | MySQL 行锁超时 | 有长事务阻塞，`SHOW ENGINE INNODB STATUS` |
| `Table 'hive_metastore.TBLS' doesn't exist` | 元数据库被删/损坏 | 从备份恢复 |

**第三步：检查 HMS 后端 MySQL 状态**

```bash
# 连接 MySQL
mysql -h mysql-host -u hive -p

# 检查连接数
SHOW STATUS LIKE 'Threads_connected';
SHOW VARIABLES LIKE 'max_connections';
# 如果 Threads_connected 接近 max_connections → 连接数满了

# 查看当前连接在做什么
SHOW FULL PROCESSLIST;
# 看有没有长时间 Sleep 或 Locked 的连接

# 检查慢查询
SHOW VARIABLES LIKE 'slow_query_log';
# 如果开了，查看慢查询日志

# 检查表是否损坏
CHECK TABLE TBLS;
CHECK TABLE PARTITIONS;
CHECK TABLE SDS;
```

**第四步：HMS 连接池调优**

```xml
<!-- hive-site.xml -->

<!-- 连接池大小（默认 10，太小） -->
<property>
  <name>datanucleus.connectionPool.maxPoolSize</name>
  <value>50</value>
</property>

<!-- 连接验证（避免拿到已断开的连接） -->
<property>
  <name>datanucleus.connectionPool.testOnBorrow</name>
  <value>true</value>
</property>

<!-- MySQL 连接超时（毫秒） -->
<property>
  <name>javax.jdo.option.ConnectionDriverName</name>
  <value>com.mysql.cj.jdbc.Driver</value>
</property>
<property>
  <name>javax.jdo.option.ConnectionURL</name>
  <value>jdbc:mysql://host:3306/hive_metastore?useSSL=false&amp;connectTimeout=10000&amp;socketTimeout=60000</value>
</property>
```

---

## 案例 4：ACID 表 Compaction 失败，查询越来越慢

### 背景知识：为什么 ACID 表需要 Compaction

```
每次 INSERT/UPDATE/DELETE 不会修改原始数据文件，而是写一个 delta 文件：

table_dir/
  ├── base_0000001/          ← 基线数据
  ├── delta_0000002_0000002/ ← INSERT 操作
  ├── delta_0000003_0000003/ ← UPDATE 操作
  ├── delete_delta_0000004/  ← DELETE 操作
  └── delta_0000005_0000005/ ← INSERT 操作

查询时需要合并所有 delta 文件 → delta 越多查询越慢

Compaction 就是把多个 delta 合并：
- Minor Compaction：多个 delta → 1 个 delta
- Major Compaction：所有 delta + base → 1 个新 base（最彻底但最重）
```

### 完整排查过程

**第一步：查看 Compaction 状态**

```sql
SHOW COMPACTIONS;
-- 输出列含义：
-- Database | Table | Partition | Type | State | Worker | Start Time | Duration
-- State 值：
--   initiated → 已创建，等待执行
--   working   → 正在执行
--   ready for cleaning → 完成，等待清理
--   failed    → 失败 ⚠️
--   succeeded → 成功
```

**如果看到大量 `initiated` 堆积**：
```
原因：Compactor Worker 线程不够或资源不足
→ 调大 hive.compactor.worker.threads（默认 1，建议 4-8）
```

**如果看到 `failed`**：
```sql
-- 查看失败原因
SELECT * FROM COMPACTION_QUEUE WHERE CQ_STATE = 'f';
-- 然后去 HS2/HMS 日志搜 compaction 关键字
grep -i "compaction.*failed\|compactor.*error" /var/log/hive/*.log | tail -20
```

**第二步：检查 delta 文件堆积程度**

```bash
# 查看某个分区的 delta 文件数
hdfs dfs -ls /user/hive/warehouse/db.db/acid_table/dt=2026-04-02/ | grep delta | wc -l
# < 10 个：正常
# 10-50 个：需要关注
# > 100 个：严重，必须立即处理

# 查看 base 目录（最近一次 Major Compaction 的结果）
hdfs dfs -ls /user/hive/warehouse/db.db/acid_table/dt=2026-04-02/ | grep base
# 如果没有 base → 从未做过 Major Compaction
```

**第三步：手动触发 Compaction**

```sql
-- Minor Compaction（合并 delta，快但不彻底）
ALTER TABLE db.acid_table PARTITION(dt='2026-04-02') COMPACT 'minor';

-- Major Compaction（delta + base → 新 base，慢但彻底）
ALTER TABLE db.acid_table PARTITION(dt='2026-04-02') COMPACT 'major';

-- 查看是否开始执行
SHOW COMPACTIONS;
```

**第四步：Compaction 相关参数完整解释**

```properties
# ===== 是否开启自动 Compaction =====
hive.compactor.initiator.on = true
# 含义：Initiator 线程定期扫描表，发现需要 compaction 就发起
# 为什么要开：不开就得手动触发，运维负担大
# 默认：true（HMS 需要运行 Initiator）

# ===== Compactor Worker 线程数 =====
hive.compactor.worker.threads = 4
# 含义：同时执行 compaction 的并行度
# 为什么默认 1 不够：如果有很多 ACID 表，1 个 worker 会堆积大量任务
# 建议：4-8（取决于集群 YARN 资源）

# ===== 触发 Minor Compaction 的 delta 数阈值 =====
hive.compactor.delta.num.threshold = 10
# 含义：一个分区的 delta 文件数超过这个值就触发 Minor Compaction
# 为什么设 10：太小会频繁 compaction 浪费资源，太大会影响查询
# 调优：如果写入频繁可以调到 20，如果查询敏感可以调到 5

# ===== 触发 Major Compaction 的阈值 =====
hive.compactor.delta.pct.threshold = 0.1
# 含义：delta 总大小 / base 大小 > 10% 就触发 Major Compaction
# 为什么设 0.1：Major Compaction 很重（全量重写），不能太频繁

# ===== Compaction 超时 =====
hive.compactor.worker.timeout = 86400
# 含义：单个 compaction 任务最大执行时间（秒），默认 24 小时
# 为什么这么长：Major Compaction 可能需要重写 TB 级数据

# ===== 清理过期 delta 的延迟 =====
hive.compactor.cleaner.run.interval = 5000
# 含义：Cleaner 线程检查间隔（毫秒）
# Compaction 完成后，旧的 delta 文件不会立即删除
# 需要等所有正在读这些文件的查询结束后才删
```

---

## 案例 5：Hive 锁等待（SQL 一直不执行）

### 报错信息

```
FAILED: Error in acquiring locks: 
Locks on the underlying objects cannot be acquired. retry after some time
```

### 排查过程

**第一步：查看当前锁**

```sql
SHOW LOCKS;
-- 输出示例：
-- Lock ID | Database | Table | Partition | State | Type | Transaction ID | Last Heartbeat | Acquired At
-- 1       | db       | t1    | NULL      | ACQUIRED | EXCLUSIVE | 100 | 2026-04-02 10:00:00 | 2026-04-02 09:55:00

SHOW LOCKS db.t1 EXTENDED;
-- 更详细的信息
```

**锁类型解释**：

| 锁类型 | 谁持有 | 和谁冲突 |
|--------|--------|---------|
| SHARED_READ | SELECT 查询 | 不和 SELECT 冲突，和 EXCLUSIVE 冲突 |
| SHARED_WRITE | INSERT/UPDATE/DELETE | 和 EXCLUSIVE 冲突 |
| EXCLUSIVE | ALTER TABLE / DROP / INSERT OVERWRITE | 和所有锁冲突 |

**第二步：找到锁的持有者**

```sql
SHOW TRANSACTIONS;
-- 找到 State = OPEN 且时间很久的事务
-- Transaction ID | State | Started | Last Heartbeat | User | Host

-- 如果某个事务长时间 OPEN → 可能是失败的任务没清理
```

**第三步：释放锁**

```sql
-- 方案 A：终止卡住的事务
ABORT TRANSACTIONS <txn_id>;

-- 方案 B：直接解锁（非 ACID 表）
UNLOCK TABLE db.t1;

-- 方案 C：查看调度系统是否同时调度了两个写同一张表的任务
-- 这是最常见的原因！
-- 解决：调度系统加依赖关系，避免并发写同一张表
```

**第四步：预防措施**

```sql
-- 缩短锁超时（默认很长）
SET hive.lock.mapred.retries = 5;           -- 重试次数
SET hive.lock.sleep.between.retries = 60;    -- 重试间隔（秒）

-- ACID 表事务超时（自动终止僵尸事务）
SET hive.txn.timeout = 600;                  -- 事务 10 分钟无心跳就超时

-- INSERT OVERWRITE 改为分区级别（减少锁范围）
-- 不好：INSERT OVERWRITE TABLE t SELECT ...         ← 锁整张表
-- 好：  INSERT OVERWRITE TABLE t PARTITION(dt='...') SELECT ... ← 只锁一个分区
```

---

# 第三章 关键参数深度解释

## 3.1 执行引擎参数

```properties
# ===== 执行引擎选择 =====
hive.execution.engine = tez
# Hive 4.0 只支持 tez
# 查看当前引擎：SET hive.execution.engine;

# ===== Tez Container 复用 =====
tez.am.container.reuse.enabled = true
# 为什么要开：Container 启动需要 1-3 秒，复用可以避免反复启动
# 效果：短查询提速 30-50%

# ===== Tez Session 模式 =====
hive.server2.tez.initialize.default.sessions = true
hive.server2.tez.sessions.per.default.queue = 2
# 为什么要开：预启动 Tez AM，第一个查询不用等 AM 启动
# 效果：首次查询延迟从 10-20s 降到 1-2s
```

## 3.2 查询优化参数

```properties
# ===== CBO（基于代价的优化器）=====
hive.cbo.enable = true
# 为什么必须开：CBO 根据表统计信息选择最优执行计划
# 关掉 CBO = 盲选执行计划，JOIN 顺序可能是灾难性的
# 前提：统计信息必须及时更新（ANALYZE TABLE）

# ===== Map Join =====
hive.auto.convert.join = true
hive.mapjoin.smalltable.filesize = 50000000    -- 50MB
# 原理：把小表加载到内存，广播给所有 Map Task
# 效果：避免 Shuffle + Reduce，速度快 5-10 倍
# 注意：表太大会 OOM，所以有 50MB 的阈值

# ===== 向量化执行 =====
hive.vectorized.execution.enabled = true
hive.vectorized.execution.reduce.enabled = true
# 原理：一次处理 1024 行而非 1 行，利用 CPU SIMD 指令
# 效果：扫描/过滤/聚合性能提升 2-10 倍
# 限制：只支持 ORC/Parquet 格式

# ===== 谓词下推 =====
hive.optimize.ppd = true
# 原理：把 WHERE 条件推到数据源层过滤，减少读取量
# 例如：SELECT * FROM t WHERE dt='2026-04-02'
#       不开 PPD：先读所有数据再过滤
#       开了 PPD：只读 dt=2026-04-02 的分区

# ===== 并行执行 =====
hive.exec.parallel = true
hive.exec.parallel.thread.number = 8
# 原理：SQL 中没有依赖关系的 Stage 可以并行执行
# 例如：UNION ALL 的两个分支可以同时跑
# 效果：多 Stage 查询提速 30-50%
```

## 3.3 资源参数

```properties
# ===== Map/Reduce 任务数控制 =====
mapreduce.input.fileinputformat.split.maxsize = 268435456   -- 256MB
mapreduce.input.fileinputformat.split.minsize = 134217728   -- 128MB
# 含义：每个 Map 处理的数据量
# 文件小 → maxsize 调大（合并多个文件给一个 Map）
# 文件大 → minsize 调小（拆分大文件给多个 Map）

hive.exec.reducers.bytes.per.reducer = 268435456            -- 256MB
hive.exec.reducers.max = 999
# 含义：每个 Reducer 处理的数据量，自动计算 Reducer 数
# 数据量 1TB / 256MB = ~4000 个 Reducer

# ===== Tez 容器大小 =====
tez.am.resource.memory.mb = 4096          -- AM 内存 4GB
tez.task.resource.memory.mb = 4096        -- Task 内存 4GB
tez.task.resource.cpu.vcores = 1          -- Task CPU
# 注意：不能超过 YARN 单个 Container 的上限
```

---

# 第四章 多组件联动排障

## 4.1 Hive 慢 → 可能是 HDFS 的问题

```
现象：所有 Hive 查询都慢
排查：
1. HS2 和 HMS 正常
2. YARN 资源充足
3. 单表文件数正常
→ 但 hdfs dfsadmin -report 发现 NameNode RPC 延迟 >10s
→ 根因：HDFS NameNode 压力大（可能是小文件、可能是 NN GC）
→ 解决：从 HDFS 层面排查（参考 HDFS 手册）
```

## 4.2 Hive 慢 → 可能是 YARN 的问题

```
现象：Hive 查询提交后长时间处于 RUNNING 但无 Map/Reduce 进度
排查：
1. yarn application -status <appId> → 发现 AM 启动了但 Container 分配不出
2. yarn queue -status default → 队列使用率 100%
→ 根因：YARN 队列资源被其他 Spark/Flink 任务占满
→ 解决：调整队列容量或优先级
```

## 4.3 Hive 报错 → 可能是 Kerberos 的问题

```
报错：org.apache.hadoop.security.AccessControlException: Permission denied
排查：
1. 检查 Hive 表权限 → Ranger 中已授权
2. 但 HDFS 层面报权限拒绝 → ls -la 看文件 owner/group
3. klist 发现票据过期
→ 根因：Kerberos TGT 过期，HS2 无法以正确身份访问 HDFS
→ 解决：检查 keytab 和票据续期
```

## 4.4 Hive MetaStore 慢 → 可能是 MySQL 的问题

```
现象：SHOW TABLES/DESCRIBE TABLE 很慢（正常 <1s，现在 >10s）
排查：
1. HMS 进程正常
2. HMS 日志无明显错误
3. 直接连 MySQL 执行 SELECT COUNT(*) FROM TBLS → 也很慢
→ 根因：MySQL 表统计信息过期或索引损坏
→ 解决：
   ANALYZE TABLE TBLS;
   ANALYZE TABLE PARTITIONS;
   OPTIMIZE TABLE TBLS;
```

---

# 第五章 日常运维 Checklist

## 每日检查

- [ ] HS2 进程存活 + 端口 10000 可连
- [ ] HMS 进程存活 + 端口 9083 可连
- [ ] `SHOW COMPACTIONS` 无大量 failed/initiated 堆积
- [ ] `SHOW LOCKS` 无长时间锁等待
- [ ] HS2 日志无 OOM/异常

## 每周检查

- [ ] 重点表的文件数是否持续增长（小文件堆积）
- [ ] ACID 表 delta 文件数是否合理
- [ ] HMS 后端 MySQL 连接数和慢查询
- [ ] `ANALYZE TABLE` 更新关键表的统计信息

## 月度检查

- [ ] Hive 版本安全更新
- [ ] 清理 `/tmp/hive` 临时目录
- [ ] 清理过期的 ACID 事务记录
- [ ] 审查 Ranger 审计日志中的异常访问
