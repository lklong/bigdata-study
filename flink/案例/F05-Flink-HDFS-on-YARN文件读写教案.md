# [教案] Flink on YARN — HDFS 文件读写使用姿势

> 🎯 教学目标：掌握 Flink FileSystem Connector 读写 HDFS 的完整姿势，包括多种文件格式支持、FileSink 配置、分桶策略、小文件处理 | ⏰ 预计学时: 80分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

**生活类比**：想象你在经营一个日报出版社。每天大量新闻稿件（实时流数据）涌入编辑室，你需要把它们按日期和版面分类归档到档案柜（HDFS 目录）中。每个文件夹存一天的稿件，每份稿件达到一定页数就封装成册（文件滚动），最后小页纸要装订成大本（文件合并）。

**生产场景**：
- 实时日志归档：Kafka → Flink → HDFS（按日期/小时分目录）
- 数据湖入口：原始数据以 Parquet/ORC 写入 HDFS
- ETL 落地：清洗后的数据持久化
- 批量回溯分析：读取 HDFS 历史文件

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.17.x | 本教案以 1.17.2 为例 |
| Hadoop/YARN | 3.x | 3.3.6 |
| Java | JDK 8/11 | |

### 2.2 所需 JAR 包

```bash
flink-sql-parquet-1.17.2.jar   # Parquet
flink-sql-orc-1.17.2.jar       # ORC
# CSV/JSON 内置无需额外JAR
```

### 2.3 环境准备

```bash
export HADOOP_CLASSPATH=`hadoop classpath`
hdfs dfs -mkdir -p /flink/output/
cd $FLINK_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-parquet/1.17.2/flink-sql-parquet-1.17.2.jar
```

---

## 三、核心使用方式

### 3.1 FileSystem Source（读 HDFS）

```sql
CREATE TABLE hdfs_source (
    user_id STRING, behavior STRING, event_time STRING
) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///flink/input/',
    'format' = 'csv',
    'source.monitor-interval' = '60s'
);
```

### 3.2 FileSink（写 HDFS）

```sql
CREATE TABLE hdfs_parquet_sink (
    user_id STRING, behavior STRING, event_time TIMESTAMP(3), dt STRING, hr STRING
) PARTITIONED BY (dt, hr) WITH (
    'connector' = 'filesystem',
    'path' = 'hdfs:///flink/output/archive/',
    'format' = 'parquet',
    'parquet.compression' = 'SNAPPY',
    'sink.rolling-policy.file-size' = '128MB',
    'sink.rolling-policy.rollover-interval' = '30min',
    'sink.partition-commit.trigger' = 'process-time',
    'sink.partition-commit.delay' = '30min',
    'sink.partition-commit.policy.kind' = 'success-file',
    'auto-compaction' = 'true',
    'compaction.file-size' = '128MB'
);
```

### 3.3 DataStream API（FileSink）

```java
FileSink<String> sink = FileSink
    .forRowFormat(new Path("hdfs:///flink/output/logs/"), new SimpleStringEncoder<>("UTF-8"))
    .withBucketAssigner(new DateTimeBucketAssigner<>("yyyy-MM-dd/HH", ZoneId.of("Asia/Shanghai")))
    .withRollingPolicy(DefaultRollingPolicy.builder()
        .withMaxPartSize(MemorySize.ofMebiBytes(128))
        .withRolloverInterval(Duration.ofMinutes(30))
        .withInactivityInterval(Duration.ofMinutes(10))
        .build())
    .withOutputFileConfig(OutputFileConfig.builder()
        .withPartPrefix("flink-log").withPartSuffix(".txt").build())
    .build();
```

### 3.4 文件三态模型

- **In-Progress** → Checkpoint触发 → **Pending** → Checkpoint成功 → **Finished**
- 必须开启 Checkpoint，否则文件永远不可见

### 3.5 小文件合并

```sql
'auto-compaction' = 'true',
'compaction.file-size' = '128MB'
```

---

## 四、完整实战示例

### 4.1 场景：Kafka日志 → HDFS Parquet归档

### 4.2 提交命令

```bash
export HADOOP_CLASSPATH=`hadoop classpath`
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=2 \
    -Dparallelism.default=6 \
    -Dyarn.application.name="Kafka-To-HDFS-Parquet" \
    -Dyarn.application.queue=flink \
    -Dexecution.checkpointing.interval=120000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/hdfs-archive \
    -c com.example.flink.hdfs.KafkaToHDFSParquetJob \
    /opt/flink-jobs/kafka-hdfs-archive-1.0.jar
```

### 4.3 验证

```bash
hdfs dfs -ls -R /flink/output/archive/
hdfs dfs -ls /flink/output/archive/dt=2025-04-20/hr=10/_SUCCESS
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决 |
|------|------|------|
| 文件一直隐藏(`.`开头) | Checkpoint未开启 | 确认 checkpoint 配置 |
| 大量小文件 | ckp太频/并行度高 | auto-compaction + 增大间隔 |
| OOM | Parquet缓冲 | 增大TM内存 |
| Lease recovery | HDFS租约未释放 | 等待自动恢复 |
| Bulk格式不支持rollover | Parquet/ORC限制 | 用OnCheckpointRollingPolicy |

---

## 六、生产最佳实践

### 6.1 参数调优

```properties
execution.checkpointing.interval: 120000
sink.rolling-policy.file-size: 128MB
auto-compaction: true
taskmanager.memory.managed.fraction: 0.4
```

### 6.2 监控告警

- In-Progress文件超30min → P2
- 单目录小文件>100 → P3
- HDFS空间>80% → P2

---

## 七、举一反三

### 7.1 面试高频题

**Q1: FileSink为何必须Checkpoint？** A: 基于两阶段提交，Checkpoint成功时文件才从Pending→Finished可见。

**Q2: Bulk格式 vs Row格式滚动区别？** A: Row支持按大小/时间滚动；Bulk(Parquet/ORC)只能按Checkpoint滚动（需写Footer）。

**Q3: 小文件解决方案？** A: auto-compaction、增大checkpoint间隔、降低并行度、后置合并。

### 7.2 思考题

1. 如何配置让每个分区最多5个文件且>100MB？
2. 作业重启后`.inprogress`文件会怎样？
3. FileSink直写 vs 写Hive表各适合什么场景？
