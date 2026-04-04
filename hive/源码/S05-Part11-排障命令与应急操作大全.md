# 11 - Hive 卡住问题排查命令大全

> 故障发生时的一站式排查手册

---

## 一、应急排查流程

```
故障发生 → Step 1: 拿 jstack → Step 2: 分析阻塞模式 → Step 3: 查日志 → Step 4: 应急处理
```

---

## 二、Step 1: 拿 jstack（最重要！）

### 定位 HS2/HMS 进程

```bash
# 方法1: jps
jps -l | grep -E "HiveServer2|HiveMetaStore"

# 方法2: ps
ps aux | grep -E "HiveServer2|HiveMetaStore" | grep -v grep | awk '{print $2}'

# 方法3: 如果在容器中
docker exec <container> jps -l
```

### 连续取 jstack

```bash
PID=<进程PID>
OUTPUT_DIR=/tmp/hive_jstack_$(date +%Y%m%d)
mkdir -p $OUTPUT_DIR

# 连续取 3 次，间隔 5 秒（对比多次 jstack 可以判断线程是否真的卡住）
for i in 1 2 3; do
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  jstack -l $PID > ${OUTPUT_DIR}/jstack_${TIMESTAMP}.txt 2>&1
  echo "Captured jstack #$i at $TIMESTAMP"
  sleep 5
done

echo "Jstack files saved to $OUTPUT_DIR"
ls -la $OUTPUT_DIR/
```

### 如果 jstack 卡住

```bash
# 强制模式（不获取锁信息，但不会卡住）
jstack -F $PID > /tmp/hs2_jstack_force.txt 2>&1
```

---

## 三、Step 2: jstack 分析

### 自动化分析脚本

```bash
#!/bin/bash
# analyze_jstack.sh — Hive 卡住问题 jstack 分析
FILE=$1

echo "===== 死锁检测 ====="
grep -A 5 "Found.*deadlock" $FILE

echo ""
echo "===== 编译锁等待 ====="
grep -B 2 -A 15 "CompileLock\|SERIALIZABLE_COMPILE_LOCK" $FILE | head -50

echo ""
echo "===== Metastore 连接阻塞 ====="
grep -B 2 -A 15 "getMSC\|HiveMetaStoreClient\|MetaStoreClient.*init" $FILE | head -50

echo ""
echo "===== HDFS list 操作 ====="
grep -B 2 -A 10 "listStatus\|listFiles\|globStatus\|DFSClient" $FILE | head -50

echo ""
echo "===== Tez Session 等待 ====="
grep -B 2 -A 10 "TezSessionPool\|Awaiting.*Tez\|notEmpty.await" $FILE | head -30

echo ""
echo "===== DPP 阻塞 ====="
grep -B 2 -A 10 "DynamicPartitionPruner\|LinkedBlockingQueue.take" $FILE | head -30

echo ""
echo "===== 事务锁等待 ====="
grep -B 2 -A 10 "DbLockManager\|backoff\|checkLock\|WAITING.*LockState" $FILE | head -30

echo ""
echo "===== Session 操作锁 ====="
grep -B 2 -A 10 "operationLock\|HiveSessionImpl.*acquire\|Semaphore" $FILE | head -30

echo ""
echo "===== BLOCKED 线程统计 ====="
echo "BLOCKED 线程数: $(grep 'BLOCKED' $FILE | wc -l)"
echo "WAITING 线程数: $(grep 'WAITING' $FILE | wc -l)"
echo "TIMED_WAITING: $(grep 'TIMED_WAITING' $FILE | wc -l)"

echo ""
echo "===== BLOCKED 线程详情 ====="
grep -B 1 -A 20 "BLOCKED" $FILE | head -100
```

**使用方法**:
```bash
chmod +x analyze_jstack.sh
./analyze_jstack.sh /tmp/hive_jstack_xxx/jstack_*.txt
```

### 关键 jstack 模式对照表

| 搜索模式 | 线程状态 | 问题 | 文档 |
|----------|----------|------|------|
| `CompileLock.*tryAcquire` + `WAITING` | WAITING | 编译锁等待 | 02 |
| `ReentrantLock.*lock` + `CompileLock` | WAITING | 编译锁等待 | 02 |
| `DFSClient.listPaths` + `RUNNABLE` | RUNNABLE | listStatus 阻塞(等IO) | 01 |
| `Hive.getMSC` + `BLOCKED` | BLOCKED | MSC synchronized | 03 |
| `TSocket.read` + `Hive.getTable` | RUNNABLE | HMS RPC 慢 | 03 |
| `notEmpty.await` + `TezSessionPool` | TIMED_WAITING | Tez Session 等待 | 04 |
| `LinkedBlockingQueue.take` + `DPP` | WAITING | DPP 永久阻塞 | 05 |
| `Thread.sleep` + `DbLockManager` | TIMED_WAITING | 事务锁 backoff | 06 |
| `Semaphore.acquire` + `HiveSession` | WAITING | operationLock | 07 |
| `SharedCache.*tableLock` + `WAITING` | WAITING | 缓存锁竞争 | 08 |

---

## 四、Step 3: 日志分析

### HS2 日志

```bash
HS2_LOG="/var/log/hive/hiveserver2.log"

# 编译相关
echo "=== 编译锁超时 ==="
grep "COMPILE_LOCK_TIMED_OUT\|Waiting to acquire compile lock" $HS2_LOG | tail -20

echo "=== 编译耗时 ==="
grep "Compiling command\|Semantic Analysis Completed\|WAIT_COMPILE" $HS2_LOG | tail -40

# Metastore 相关
echo "=== Metastore 连接问题 ==="
grep -i "MetaException\|Could not connect\|Connection refused\|socket.*timeout" $HS2_LOG | tail -20

# Tez 相关
echo "=== Tez Session 问题 ==="
grep -i "Awaiting Tez session\|Failed to use a session\|AM.*failed\|Session.*expired" $HS2_LOG | tail -20

# HDFS 相关
echo "=== HDFS 操作问题 ==="
grep -i "listStatus.*timeout\|NameNode.*not.*reachable\|SocketTimeout" $HS2_LOG | tail -20

# 锁相关
echo "=== 事务锁问题 ==="
grep -i "LOCK_ACQUIRE_TIMEDOUT\|lock.*timeout\|Unable to acquire.*lock" $HS2_LOG | tail -20
```

### HMS 日志

```bash
HMS_LOG="/var/log/hive/metastore.log"

echo "=== HMS 慢操作 ==="
grep -i "slow\|took.*ms\|timeout" $HMS_LOG | tail -20

echo "=== HMS 连接问题 ==="
grep -i "too many connections\|connection.*pool\|refused" $HMS_LOG | tail -20
```

---

## 五、Step 4: 应急操作

### 场景 1: HS2 查询全部卡住

```bash
# 1. 确认是否编译锁问题
grep "WAITING.*CompileLock" /tmp/hs2_jstack_*.txt | wc -l
# 如果 > 0，大概率是编译锁

# 2. 紧急: 不重启的情况下，通过 beeline 设置参数
beeline -u "jdbc:hive2://localhost:10000" -e "
SET hive.driver.parallel.compilation=true;
SET hive.server2.compile.lock.timeout=60;
"
# 注意: 运行时 SET 只影响当前 session，需要修改 hive-site.xml 并重启才能全局生效

# 3. 如果必须重启
# 先优雅关闭
kill -TERM <PID>
sleep 30
# 如果还没退出，强制关闭
kill -9 <PID>
# 修改配置后启动
```

### 场景 2: 单个查询永久挂起

```bash
# 1. 找到挂起的查询
beeline -u "jdbc:hive2://localhost:10000" -e "
SHOW PROCESSLIST;
"

# 2. Kill 查询
beeline -u "jdbc:hive2://localhost:10000" -e "
KILL QUERY '<query_id>';
"
```

### 场景 3: Metastore 连接不上

```bash
# 1. 检查 HMS 进程
jps -l | grep HiveMetaStore

# 2. 检查 HMS 端口
netstat -tlnp | grep 9083

# 3. 检查 HMS 日志
tail -100 /var/log/hive/metastore.log | grep -i "error\|exception\|fatal"

# 4. 检查后端数据库
# MySQL
mysql -u hive -p -e "SHOW PROCESSLIST;" | head -20
# PostgreSQL
psql -U hive -c "SELECT * FROM pg_stat_activity WHERE state != 'idle';"
```

### 场景 4: HDFS list 操作慢

```bash
# 1. 检查 NN 状态
hdfs dfsadmin -report | head -20
hdfs dfsadmin -safemode get

# 2. 检查 NN RPC 队列
curl -s "http://<nn_host>:9870/jmx?qry=Hadoop:service=NameNode,name=RpcActivityForPort8020" | \
  python -m json.tool | grep -E "CallQueueLength|NumOpenConnections|RpcProcessingTime"

# 3. 检查目标路径文件数
hdfs dfs -count /user/hive/warehouse/<db>/<table>
# 如果文件数 > 10万，需要合并小文件
```

---

## 六、监控指标

### HS2 JMX Metrics

```bash
# 编译等待操作数
curl -s "http://<hs2_host>:10002/jmx" | python -m json.tool | grep "WAITING_COMPILE_OPS"

# 活跃 session 数
curl -s "http://<hs2_host>:10002/jmx" | python -m json.tool | grep "hs2_open_sessions"

# 活跃操作数
curl -s "http://<hs2_host>:10002/jmx" | python -m json.tool | grep "hs2_open_operations"
```

### 告警阈值建议

| 指标 | 正常值 | 告警阈值 | 说明 |
|------|--------|----------|------|
| WAITING_COMPILE_OPS | 0 | > 5 | 编译锁排队 |
| hs2_open_sessions | < 100 | > 200 | Session 过多 |
| HS2 线程数 (BLOCKED) | 0 | > 10 | 大量线程阻塞 |
| HMS 响应时间 | < 100ms | > 5000ms | HMS 慢 |
| NN RPC CallQueueLength | < 100 | > 1000 | NN 过载 |

---

## 七、定期巡检命令

```bash
#!/bin/bash
# hive_health_check.sh — Hive 健康检查

echo "===== HS2 进程状态 ====="
jps -l | grep HiveServer2

echo ""
echo "===== HS2 线程统计 ====="
PID=$(jps -l | grep HiveServer2 | awk '{print $1}')
if [ -n "$PID" ]; then
  jstack $PID 2>/dev/null | grep "java.lang.Thread.State" | sort | uniq -c | sort -rn
fi

echo ""
echo "===== HMS 连接测试 ====="
beeline -u "jdbc:hive2://localhost:10000" -e "SHOW DATABASES;" 2>&1 | tail -5

echo ""
echo "===== HDFS 状态 ====="
hdfs dfsadmin -report 2>/dev/null | head -10

echo ""
echo "===== 最近错误日志 ====="
tail -100 /var/log/hive/hiveserver2.log | grep -i "error\|exception" | tail -10
```
