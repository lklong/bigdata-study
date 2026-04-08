# HDFS NameNode 慢请求排查实战

> HDFS Expert 案例学习 — NameNode RPC 延迟飙高

## 案例背景

```
环境: Hadoop 3.2, 2 NameNode (HA), 200 DataNode, 3 亿文件
现象:
  - NameNode RPC 平均延迟从 5ms 飙到 500ms
  - Spark/Hive 任务大面积超时
  - HDFS 写入成功率下降到 80%
  - NN JVM 堆使用率 85% (200GB 堆)
```

## 排查过程

### Step 1: RPC 队列分析

```bash
# 检查 RPC 队列
curl http://nn1:9870/jmx | jq '.beans[] | select(.name | contains("RpcActivity"))'

# 关键指标:
CallQueueLength: 512        # 队列满了！(默认最大 1024)
NumOpenConnections: 8500     # 连接数很高
RpcProcessingTimeAvgTime: 450ms  # 平均处理时间
RpcQueueTimeAvgTime: 300ms      # 排队时间

# 正常应该:
CallQueueLength: < 50
RpcProcessingTimeAvgTime: < 10ms
```

### Step 2: 慢操作定位

```bash
# 开启 NN 审计日志详细模式
# 找到最慢的操作类型
grep "AUDIT" nn-audit.log | awk '{print $NF}' | sort | uniq -c | sort -rn | head
  45000  listStatus     ← 最多！
  12000  getFileInfo
   8000  create
   5000  rename
   3000  delete

# 检查 listStatus 的具体目录
grep "listStatus" nn-audit.log | awk -F'src=' '{print $2}' | awk '{print $1}' | sort | uniq -c | sort -rn | head
  15000  /user/hive/warehouse/huge_table/   ← 这个目录有问题！
```

### Step 3: 根因确认

```bash
# 检查该目录的文件数
hdfs dfs -count /user/hive/warehouse/huge_table/
  0  1500000  /user/hive/warehouse/huge_table/

# 150 万个小文件！每次 listStatus 要返回全部文件列表
# NameNode 在 FSNamesystem 锁内遍历 → 阻塞其他所有操作

# 确认: FSNamesystem 锁竞争
curl http://nn1:9870/jmx | jq '.beans[] | select(.name | contains("FSNamesystemLock"))'
  FsLockQueueLength: 200        # 等待获取锁的线程
  LockWait99thPercentile: 800ms # P99 锁等待时间
```

### Step 4: 修复

```bash
# 短期: 合并小文件
hadoop jar hadoop-streaming.jar \
  -D mapred.reduce.tasks=100 \
  -input /user/hive/warehouse/huge_table/ \
  -output /user/hive/warehouse/huge_table_merged/ \
  -mapper cat -reducer cat

# 中期: NameNode 配置优化
# 开启 FairCallQueue（公平调度 RPC 请求）
<property>
  <name>ipc.scheduler.impl</name>
  <value>org.apache.hadoop.ipc.DecayRpcScheduler</value>
</property>
<property>
  <name>ipc.scheduler.priority.levels</name>
  <value>4</value>
</property>
# 效果: listStatus 大目录的请求被降权，不会饿死其他请求

# 长期: 开启 HDFS Router Federation
# 将大表的 namespace 拆分到独立 NameNode
```

## 经验规则

```
R-HDFS-001: 单目录文件数 < 10 万，超过必须合并或分层
R-HDFS-002: NN 堆使用率 > 80% 就要扩容或拆分 namespace
R-HDFS-003: 生产 NN 必须开启 FairCallQueue 防止慢请求饿死
R-HDFS-004: listStatus 大目录是 NN 性能杀手 — 持有全局锁
R-HDFS-005: 监控 FsLockQueueLength > 100 → 告警
```

---

*HDFS Expert 案例产出 | 2026-04-08*
