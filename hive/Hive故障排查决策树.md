# Hive 故障排查决策树

---

## 1. 查询卡住/慢

```
查询慢
├── 查 Tez/Spark UI 确认瓶颈 Stage
│   ├── Map 阶段慢
│   │   ├── 输入文件太多（小文件） → 合并输入 CombineHiveInputFormat
│   │   ├── 文件格式差（TextFile） → 转为 ORC/Parquet
│   │   └── 列裁剪没生效 → 检查 SELECT * 是否必要
│   ├── Reduce 阶段慢
│   │   ├── 数据倾斜 → 看 Task Duration 分布
│   │   │   └── hive.optimize.skewjoin=true / hive.groupby.skewindata=true
│   │   ├── Reducer 数太少 → hive.exec.reducers.bytes.per.reducer 调小
│   │   └── JOIN 方式不对 → 检查是否可以 MapJoin
│   └── 两个 Stage 间等待长
│       └── 中间 Shuffle 数据量大 → 减少中间结果
├── HiveServer2 层面
│   ├── 编译慢 → Metastore 查询慢（分区太多）
│   ├── 排队等待 → HS2 并发满 / Tez Session 不够
│   └── 获取结果慢 → 结果集太大 → 用 INSERT 代替 SELECT
└── Metastore 层面
    ├── getPartitions 慢 → 分区数 > 10 万 → 减少分区或用 Iceberg
    └── MySQL 慢查询 → 检查 HMS 底层数据库性能
```

## 2. 查询报错

```
查询报错
├── "SemanticException: Table not found"
│   └── 表不存在 / database 没切换 / Metastore 连接问题
├── "Error while compiling statement"
│   ├── SQL 语法错误 → 检查 HiveQL 语法
│   └── UDF 找不到 → ADD JAR / CREATE FUNCTION
├── "Return code 2 from org.apache.hadoop.hive.ql.exec.mr.MapRedTask"
│   ├── OOM → 调大 Container 内存
│   ├── 数据格式错误 → 检查 SerDe 配置
│   └── 权限问题 → 检查 HDFS 路径权限
├── "ACID table not valid"
│   └── 表开了事务但 Compaction 没配 → hive.compactor.initiator.on=true
└── "Lock wait timeout"
    └── ACID 表锁冲突 → SHOW LOCKS → 手动释放
```

## 3. HS2 连接问题

```
连接问题
├── "Could not open client transport"
│   ├── HS2 没启动 → 检查进程
│   ├── 端口不对 → 默认 10000 (binary) / 10001 (http)
│   └── Kerberos 认证失败 → kinit / 检查 keytab
├── "TTransportException: MaxMessageSize reached"
│   └── 结果集太大 → 分页查询 / LIMIT
├── 连接数耗尽
│   └── hive.server2.thrift.max.worker.threads 调大 / 检查连接泄漏
└── ZK 服务发现失败
    └── HS2 没注册到 ZK / ZK 挂了
```

---

*Hive Expert | 故障排查决策树 v1.0 | 2026-04-08*
