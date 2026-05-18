# HMS 删大量分区 StackOverflowError — HIVE-6980+15956 backport 案例

> **状态**：✅ 已闭环验证（旧版复现 SOF + 新版 backport 后修复）
> **时间**：2026-05-18
> **集群**：EMR 测试集群（172.21.240.4，TencentOS 2.4 / KonaJDK 8u482 / Hive 3.1.3）
> **影响版本**：Apache Hive 3.1.x 社区原版（emr-3.1.3 含同等代码）
> **修复 PR 链**：HIVE-18986（前置）→ HIVE-6980（DirectSQL 主修） → HIVE-15956（ORM 兜底分批）

---

## 一、现象

HMS 在被调用一次性 drop 上千个分区时抛 `java.lang.StackOverflowError`，触发 Thrift 连接被服务端单方面切断；客户端拿到 `TTransportException: null`，drop 整体回滚（事务回退，分区一个都没删掉）。HMS 进程不挂，但处理这一次请求的 worker 线程崩溃。

典型客户端堆栈尾部：
```
Caused by: org.apache.thrift.transport.TTransportException
    at org.apache.thrift.transport.TIOStreamTransport.read(...)
    at org.apache.thrift.protocol.TBinaryProtocol.readMessageBegin(...)
```

典型 HMS 端栈（递归段）：
```
java.lang.StackOverflowError
    at org.datanucleus.query.expression.ExpressionCompiler.compileOrAndExpression(ExpressionCompiler.java:200)
    at org.datanucleus.query.expression.ExpressionCompiler.compileExpression(ExpressionCompiler.java:187)
    at org.datanucleus.query.expression.ExpressionCompiler.compileOrAndExpression(ExpressionCompiler.java:200)
    ... ×千次递归 ...
```

---

## 二、根因

`ObjectStore.dropPartitions(catName, db, tbl, List<String> partNames)` 老代码走纯 ORM 路径，对每一组操作都用 `JDOQL filter` 拼出形如 `partitionName == 'v0' || partitionName == 'v1' || ... || partitionName == 'v11999'` 的长 OR 链，由 DataNucleus `ExpressionCompiler` 递归编译。递归深度 = OR 链长度，1MB 默认 `-Xss` 在万级 OR 时直接炸栈。

5 处隐藏 SOF 触发点（每删一批都全过一遍）：

| 步骤 | 方法 | 目标表 | OR 链来源 |
|---|---|---|---|
| 1 | `dropPartitionGrantsNoTxn` | `PART_PRIVS` | partNames 拼 OR |
| 2 | `dropPartitionAllColumnGrantsNoTxn` | `PART_COL_PRIVS` | partNames 拼 OR |
| 3 | `dropPartitionColumnStatisticsNoTxn` | `PART_COL_STATS` | partNames 拼 OR |
| 4 | `detachCdsFromSdsNoTxn` | SD/CD 关系 | partNames 拼 OR |
| 5 | `dropPartitionsNoTxn` | `PARTITIONS` 主表 | partNames 拼 OR（**炸点**） |

**关键反直觉点**：`hive.metastore.try.direct.sql=true` 对 `dropPartitions` **完全无效**——drop 路径在原版 Hive 3.1.3 里**不走 DirectSQL**，无论该开关如何设置都是走 ORM。这是为什么生产现场 `try.direct.sql=true` 仍然炸的原因。

---

## 三、修复

按依赖顺序 backport 三个社区 PR 到 emr-3.1.3：

| PR | 角色 | 关键改动 |
|---|---|---|
| **HIVE-18986** | 前置基础设施 | 引入公共 `Batchable<I,R>` 抽象类 + 静态 `runBatched(int, List, Batchable)` |
| **HIVE-6980** | 主修方案 | 给 `MetaStoreDirectSql` 加 `dropPartitionsViaSqlFilter / dropPartitionsByPartitionIds / dropStorageDescriptors / dropSerdes / dropDanglingColumnDescriptors`；`ObjectStore.dropPartitions` 改用 `GetListHelper` 跑 try-DirectSQL-then-ORM 模式 |
| **HIVE-15956** | 兜底防御 | `dropPartitionsViaJdo` + `getPartitionsViaOrmFilter` + `getMTableColumnStatistics` 等 ORM 路径用 `Batchable.runBatched(batchSize, ...)` 分批，避免单批 OR 链超长 |

**配置**（极简化，只加一条）：

```xml
<property>
  <name>metastore.rawstore.batch.size</name>
  <value>300</value>
</property>
```

注意：
- 默认值 `-1`（NO_BATCHING）= HIVE-15956 不生效，**必须显式配 >0**
- `hive.metastore.try.direct.sql` 默认 true，无需显式声明
- `hive.metastore.batch.retrieve.table.partition.max` 与本修复无关，控制的是 **retrieve（查询）** 路径分批，不是 drop

---

## 四、变更涉及文件

emr-3.1.3 仓库本次实际改动：

| 文件 | +/- 行数 | 说明 |
|---|---|---|
| `Batchable.java`（新增） | +86 / 0 | HIVE-18986 引入公共类 |
| `MetaStoreDirectSql.java` | +352 / -45 | HIVE-6980 主体（drop 五件套）+ 旧 private Batchable 删除 |
| `ObjectStore.java` | +117 / -26 | HIVE-6980 重构 dropPartitions 入口 + HIVE-15956 ORM 路径分批 |
| `MetastoreConf.java` | 0 / 0 | `RAWSTORE_PARTITION_BATCH_SIZE` 配置项原本就在 |

---

## 五、验证矩阵

复现 + 修复在同一 EMR 测试集群上完整跑通，三种路径全部覆盖：

| 场景 | jar 版本 | DirectSQL 配置 | 走的路径 | drop 12000 分区耗时 | 结果 |
|---|---|---|---|---|---|
| 旧版基线 | 社区原版 3.1.3 | true（默认） | ORM 长 OR 链 | 5.9s 后炸 | ❌ **SOF** |
| **新版默认** | backport 后 | true（默认） | DirectSQL `dropPartitionsViaSqlFilter` | **2.1 ~ 2.3s** | ✅ 成功 |
| 新版 fallback | backport 后 | false（强制 ORM） | ORM `dropPartitionsViaJdo` 分批 300 | **91.8s** | ✅ 成功 |

**两个性能事实**：
- DirectSQL 路径比 ORM 路径快 **约 40 倍**（2.3s vs 91.8s）。原因：DirectSQL 用 `DELETE WHERE PART_ID IN (...)` 一条 SQL 批删多张表，约 30 条 SQL 完成 12000 分区；ORM 走 DataNucleus `deletePersistentAll`，会先 SELECT 加载到一级缓存、解析级联关系、再逐对象 delete，且每个分区会触发 `Updating partition stats fast` 这种 lifecycle 回调，总共数千条 SQL。
- ORM 路径 91.8s 不算 backport 没做好——这就是 DataNucleus ORM 抽象本身的代价。HIVE-15956 的目标是"分批后不炸"，不是"加速"。加速是 HIVE-6980 的功劳。

**JVM 配置**：复现时 HMS `-Xss` 未显式设置（即 HotSpot 64-bit Linux 默认 1MB）；修复后无需调大栈。

---

## 六、运维侧的不改 jar 临时方案（备份）

线上来不及 backport 时的纯运维兜底：

1. **客户端分批**（最优）：业务侧改 SQL，每次 `ALTER TABLE ... DROP IF EXISTS PARTITION (p IN (...))` 控制在 ≤500 个分区。
2. **加大 Xss**（缓冲）：`HADOOP_CLIENT_OPTS="$HADOOP_CLIENT_OPTS -Xss20m"`。能扛 ~16k OR 链，但每个 worker thread 多吃 ~19MB 虚拟内存。
3. **DBA 手工删**（救火）：HMS 卡死后直接到 MySQL 后端按外键顺序 `DELETE FROM PART_PRIVS / PART_COL_PRIVS / PART_COL_STATS / PARTITION_PARAMS / PARTITION_KEY_VALS / PARTITIONS WHERE PART_ID IN (...)`，删完必须重启 HMS 让缓存一致。**不适合常规批删，仅救火**。

⚠️ **不要寄希望于** `hive.metastore.try.direct.sql=true`：drop 路径不读这个配置。

---

## 七、上线指引

**前提条件**：emr-3.1.3 内部 fork 已合并 HIVE-18986+6980+15956，本次替换 5 个 jar：

| jar | 路径 |
|---|---|
| `hive-service-3.1.3.jar` | `/usr/local/service/hive/lib/` |
| `hive-standalone-metastore-3.1.3.jar` | 同上 |
| `hive-metastore-3.1.3.jar` | 同上 |
| `hive-exec-3.1.3.jar` | 同上 |
| `hive-common-3.1.3.jar` | 同上 |

**配置**：在 `hive-site.xml` 中加一条 `metastore.rawstore.batch.size=300`。

**重启**：HMS + HiveServer2 都要重启（jar 版本必须一致；HS2 与 HMS 共用 hive-exec/hive-metastore）。EMR 上 `kill <pid>` 即可，systemd 自动拉起约 12-18 秒。

**回滚**：备份的 `*.jar.bak.<timestamp>` 留在原目录，紧急时把后缀去掉重启即可。

**正向冒烟**：
```sql
-- 建一张测试表，加 1 万分区，一次性 drop，期望秒级完成无报错
CREATE TABLE t_smoke (id int) PARTITIONED BY (p string);
-- 用 java client 批量 add_partitions 10000 个
-- ALTER TABLE t_smoke DROP IF EXISTS PARTITION (p IN ('v0',...,'v9999'));
```

---

## 八、关联 JIRA

- [HIVE-18986](https://issues.apache.org/jira/browse/HIVE-18986)：Table rename will run java.lang.StackOverflowError in dataNucleus
- [HIVE-6980](https://issues.apache.org/jira/browse/HIVE-6980)：Drop table by using direct sql
- [HIVE-15956](https://issues.apache.org/jira/browse/HIVE-15956)：StackOverflowError when drop lots of partitions
