# [教案] Flink on YARN — HBase 维表查询与写入使用姿势

> 🎯 教学目标：掌握 Flink HBase Connector 的配置与使用，实现 Lookup Join 维表查询和 Sink 写入 HBase | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

### 1.1 典型业务场景

在实时数据处理中，HBase 是最常见的维表存储之一：

| 场景 | 描述 | 示例 |
|------|------|------|
| **维表关联** | Kafka 实时流 Join HBase 维表，补全字段 | 订单流关联用户画像表 |
| **实时写入** | 实时计算结果写入 HBase 供在线查询 | 实时指标写入 HBase，前端查询展示 |
| **宽表构建** | 多流 Join + 维表补全 → 写入 HBase 宽表 | 实时构建用户行为宽表 |
| **实时风控** | 流数据 Join HBase 规则表做实时风控判断 | 交易流 Join 黑名单/规则表 |

### 1.2 为什么选 Flink + HBase？

- **HBase 天然适合点查**：Rowkey 查询毫秒级响应，非常适合做 Lookup Join 维表
- **Flink 原生支持**：官方提供 `flink-connector-hbase-2.2`，无需额外开发
- **SQL 友好**：Flink SQL 的 `FOR SYSTEM_TIME AS OF` 语法让维表 Join 变得简洁
- **缓存机制**：内置 LRU 缓存，减少对 HBase 的请求压力

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Flink | 1.17.x / 1.18.x / 1.19.x | 推荐 1.17+ |
| HBase | 2.2.x / 2.4.x / 2.5.x | 需要 hbase-2 connector |
| Hadoop/YARN | 3.1+ | Flink on YARN 运行环境 |
| Kafka | 2.x / 3.x | 作为实时数据源 |
| Java | JDK 8 / JDK 11 | Flink 运行时 |
| ZooKeeper | 3.5+ | HBase 依赖 |

### 2.2 环境准备命令

```bash
# ============================================
# 1. 设置环境变量
# ============================================
export FLINK_HOME=/opt/flink-1.17.2
export HADOOP_HOME=/opt/hadoop
export HBASE_HOME=/opt/hbase
export HADOOP_CLASSPATH=$(hadoop classpath)
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop

# ============================================
# 2. 下载必需 JAR 包
# ============================================
cd $FLINK_HOME/lib

# Flink HBase Connector（核心依赖）
wget https://repo1.maven.org/maven2/org/apache/flink/flink-connector-hbase-2.2/1.17.2/flink-connector-hbase-2.2-1.17.2.jar

# Flink Kafka Connector（Kafka 数据源）
wget https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.17.2/flink-sql-connector-kafka-1.17.2.jar

# HBase Client（如果 connector fat jar 未包含）
wget https://repo1.maven.org/maven2/org/apache/hbase/hbase-client/2.4.17/hbase-client-2.4.17.jar

# ============================================
# 3. 拷贝 HBase 配置文件到 Flink
# ============================================
cp $HBASE_HOME/conf/hbase-site.xml $FLINK_HOME/conf/
cp $HADOOP_HOME/etc/hadoop/core-site.xml $FLINK_HOME/conf/
cp $HADOOP_HOME/etc/hadoop/hdfs-site.xml $FLINK_HOME/conf/

# ============================================
# 4. 验证 HBase 连通性
# ============================================
# 检查 HBase 是否可用
echo "status 'simple'" | hbase shell

# 创建测试维表
echo "
create 'dim_user', 'info'
put 'dim_user', 'U001', 'info:name', 'Alice'
put 'dim_user', 'U001', 'info:age', '28'
put 'dim_user', 'U001', 'info:city', 'Beijing'
put 'dim_user', 'U002', 'info:name', 'Bob'
put 'dim_user', 'U002', 'info:age', '32'
put 'dim_user', 'U002', 'info:city', 'Shanghai'
put 'dim_user', 'U003', 'info:name', 'Charlie'
put 'dim_user', 'U003', 'info:age', '25'
put 'dim_user', 'U003', 'info:city', 'Guangzhou'
" | hbase shell

# 创建结果表
echo "
create 'order_detail', 'order', 'user'
" | hbase shell

# ============================================
# 5. 准备 Kafka 测试 Topic
# ============================================
kafka-topics.sh --create \
  --bootstrap-server kafka01:9092 \
  --topic order_events \
  --partitions 3 \
  --replication-factor 2

# 写入测试数据
echo '{"order_id":"ORD001","user_id":"U001","amount":99.9,"ts":"2026-04-29 10:00:00"}' | \
  kafka-console-producer.sh --bootstrap-server kafka01:9092 --topic order_events

echo '{"order_id":"ORD002","user_id":"U002","amount":199.0,"ts":"2026-04-29 10:01:00"}' | \
  kafka-console-producer.sh --bootstrap-server kafka01:9092 --topic order_events

echo '{"order_id":"ORD003","user_id":"U003","amount":59.5,"ts":"2026-04-29 10:02:00"}' | \
  kafka-console-producer.sh --bootstrap-server kafka01:9092 --topic order_events
```

---

## 三、核心使用方式

### 3.1 Flink SQL — HBase 维表（Lookup Source）

```sql
-- ============================================
-- 创建 HBase 维表（用于 Lookup Join）
-- ============================================
CREATE TABLE dim_user (
    rowkey STRING,                    -- HBase Rowkey，映射为第一个字段
    info ROW<                         -- Column Family: info
        name STRING,                  -- Column: info:name
        age INT,                      -- Column: info:age
        city STRING                   -- Column: info:city
    >,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'dim_user',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    'zookeeper.znode.parent' = '/hbase',
    -- Lookup 缓存配置
    'lookup.cache.max-rows' = '5000',       -- LRU 缓存最大行数
    'lookup.cache.ttl' = '60s',             -- 缓存 TTL
    'lookup.max-retries' = '3'              -- 查询重试次数
);
```

### 3.2 Flink SQL — HBase Sink（写入表）

```sql
-- ============================================
-- 创建 HBase Sink 表
-- ============================================
CREATE TABLE order_detail_sink (
    rowkey STRING,                          -- HBase Rowkey
    order ROW<                              -- Column Family: order
        order_id STRING,
        amount DOUBLE,
        order_time STRING
    >,
    user ROW<                               -- Column Family: user
        user_name STRING,
        user_age INT,
        user_city STRING
    >,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'order_detail',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    'zookeeper.znode.parent' = '/hbase',
    'sink.buffer-flush.max-size' = '10mb',  -- 批量写入缓冲大小
    'sink.buffer-flush.max-rows' = '1000',  -- 批量写入最大行数
    'sink.buffer-flush.interval' = '1s',    -- 定时刷新间隔
    'sink.parallelism' = '3'                -- 写入并行度
);
```

### 3.3 参数详解表 — HBase Connector

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `connector` | ✅ | - | 固定 `hbase-2.2` |
| `table-name` | ✅ | - | HBase 表名 |
| `zookeeper.quorum` | ✅ | - | ZooKeeper 地址，逗号分隔 |
| `zookeeper.znode.parent` | ❌ | `/hbase` | HBase 在 ZK 上的 znode |
| `lookup.cache.max-rows` | ❌ | `-1` (不缓存) | LRU 缓存最大行数 |
| `lookup.cache.ttl` | ❌ | `0s` | 缓存 TTL，0 表示不过期 |
| `lookup.max-retries` | ❌ | `3` | Lookup 查询最大重试次数 |
| `lookup.async` | ❌ | `false` | 是否启用异步 Lookup |
| `sink.buffer-flush.max-size` | ❌ | `2mb` | 写入缓冲区大小 |
| `sink.buffer-flush.max-rows` | ❌ | `1000` | 缓冲区最大行数，达到即 flush |
| `sink.buffer-flush.interval` | ❌ | `1s` | 定时 flush 间隔 |
| `sink.parallelism` | ❌ | - | Sink 并行度（不设则继承全局） |
| `properties.*` | ❌ | - | 透传 HBase 客户端配置 |

### 3.4 参数详解表 — Lookup 缓存策略

| 缓存策略 | 配置 | 适用场景 |
|----------|------|---------|
| **不缓存** | `max-rows = -1` | 维表变化频繁，实时性要求极高 |
| **小缓存短 TTL** | `max-rows = 1000, ttl = 30s` | 维表偶尔变更，平衡性能与实时 |
| **大缓存长 TTL** | `max-rows = 50000, ttl = 300s` | 维表几乎不变，追求高吞吐 |
| **全量缓存** | `max-rows = 很大, ttl = 1h` | 维表很小且极少变更 |

---

## 四、完整实战示例

### 4.1 实战场景：Kafka 订单流 Join HBase 用户维表 → 写入 HBase 宽表

#### 4.1.1 Flink SQL 完整实现

创建 SQL 文件 `hbase_lookup_job.sql`：

```sql
-- ============================================================
-- Flink SQL: Kafka 订单流 Join HBase 用户维表 → 写入 HBase
-- ============================================================

-- 1. 创建 Kafka 订单流 Source
CREATE TABLE kafka_orders (
    order_id STRING,
    user_id STRING,
    amount DOUBLE,
    ts STRING,
    proc_time AS PROCTIME()              -- 处理时间，用于 Lookup Join
) WITH (
    'connector' = 'kafka',
    'topic' = 'order_events',
    'properties.bootstrap.servers' = 'kafka01:9092,kafka02:9092,kafka03:9092',
    'properties.group.id' = 'flink-hbase-lookup-group',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json',
    'json.fail-on-missing-field' = 'false',
    'json.ignore-parse-errors' = 'true'
);

-- 2. 创建 HBase 维表（Lookup Source）
CREATE TABLE dim_user (
    rowkey STRING,
    info ROW<name STRING, age INT, city STRING>,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'dim_user',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    'zookeeper.znode.parent' = '/hbase',
    'lookup.cache.max-rows' = '5000',
    'lookup.cache.ttl' = '60s',
    'lookup.max-retries' = '3'
);

-- 3. 创建 HBase Sink 表
CREATE TABLE order_detail_sink (
    rowkey STRING,
    order ROW<order_id STRING, amount DOUBLE, order_time STRING>,
    user ROW<user_name STRING, user_age INT, user_city STRING>,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'order_detail',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    'zookeeper.znode.parent' = '/hbase',
    'sink.buffer-flush.max-size' = '10mb',
    'sink.buffer-flush.max-rows' = '1000',
    'sink.buffer-flush.interval' = '1s'
);

-- 4. Lookup Join + 写入 HBase
INSERT INTO order_detail_sink
SELECT
    o.order_id AS rowkey,                                -- 用 order_id 做 Rowkey
    ROW(o.order_id, o.amount, o.ts) AS `order`,          -- order 列族
    ROW(u.info.name, u.info.age, u.info.city) AS `user`  -- user 列族
FROM kafka_orders AS o
LEFT JOIN dim_user FOR SYSTEM_TIME AS OF o.proc_time AS u
    ON o.user_id = u.rowkey;
```

#### 4.1.2 DataStream API 实现

```java
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.RichMapFunction;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.async.AsyncFunction;
import org.apache.flink.streaming.api.functions.async.ResultFuture;
import org.apache.flink.streaming.api.functions.async.RichAsyncFunction;
import org.apache.flink.streaming.api.datastream.AsyncDataStream;

import org.apache.hadoop.hbase.HBaseConfiguration;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.*;
import org.apache.hadoop.hbase.util.Bytes;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Collections;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/**
 * DataStream API: Kafka → HBase Lookup → 写入 HBase
 */
public class HBaseLookupWriteJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.enableCheckpointing(60000);

        // 1. Kafka Source
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka01:9092,kafka02:9092,kafka03:9092")
                .setTopics("order_events")
                .setGroupId("flink-hbase-ds-group")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<String> kafkaStream = env.fromSource(
                kafkaSource, WatermarkStrategy.noWatermarks(), "Kafka Source");

        // 2. 异步 HBase Lookup Join
        DataStream<String> enrichedStream = AsyncDataStream.unorderedWait(
                kafkaStream,
                new HBaseAsyncLookupFunction(),
                30, TimeUnit.SECONDS,  // 超时时间
                100                     // 最大并发请求数
        );

        // 3. 写入 HBase
        enrichedStream.addSink(new HBaseSinkFunction());

        env.execute("Kafka-HBase-Lookup-Write-Job");
    }

    /**
     * 异步 HBase Lookup Function
     */
    public static class HBaseAsyncLookupFunction extends RichAsyncFunction<String, String> {
        private transient AsyncConnection asyncConnection;
        private transient ObjectMapper mapper;

        @Override
        public void open(Configuration parameters) throws Exception {
            org.apache.hadoop.conf.Configuration conf = HBaseConfiguration.create();
            conf.set("hbase.zookeeper.quorum", "zk01:2181,zk02:2181,zk03:2181");
            conf.set("zookeeper.znode.parent", "/hbase");
            asyncConnection = ConnectionFactory.createAsyncConnection(conf).get();
            mapper = new ObjectMapper();
        }

        @Override
        public void asyncInvoke(String input, ResultFuture<String> resultFuture) {
            try {
                JsonNode order = mapper.readTree(input);
                String userId = order.get("user_id").asText();

                AsyncTable<AdvancedScanResultConsumer> table =
                        asyncConnection.getTable(TableName.valueOf("dim_user"));

                Get get = new Get(Bytes.toBytes(userId));
                get.addFamily(Bytes.toBytes("info"));

                CompletableFuture<Result> future = table.get(get);
                future.whenComplete((result, throwable) -> {
                    if (throwable != null) {
                        resultFuture.completeExceptionally(throwable);
                    } else {
                        try {
                            String name = result.isEmpty() ? "UNKNOWN" :
                                    Bytes.toString(result.getValue(Bytes.toBytes("info"), Bytes.toBytes("name")));
                            String age = result.isEmpty() ? "0" :
                                    Bytes.toString(result.getValue(Bytes.toBytes("info"), Bytes.toBytes("age")));
                            String city = result.isEmpty() ? "UNKNOWN" :
                                    Bytes.toString(result.getValue(Bytes.toBytes("info"), Bytes.toBytes("city")));

                            String enriched = String.format(
                                    "{\"order_id\":\"%s\",\"user_id\":\"%s\",\"amount\":%s," +
                                    "\"ts\":\"%s\",\"user_name\":\"%s\",\"user_age\":%s,\"user_city\":\"%s\"}",
                                    order.get("order_id").asText(),
                                    userId,
                                    order.get("amount").asText(),
                                    order.get("ts").asText(),
                                    name, age, city
                            );
                            resultFuture.complete(Collections.singletonList(enriched));
                        } catch (Exception e) {
                            resultFuture.completeExceptionally(e);
                        }
                    }
                });
            } catch (Exception e) {
                resultFuture.completeExceptionally(e);
            }
        }

        @Override
        public void close() throws Exception {
            if (asyncConnection != null) {
                asyncConnection.close();
            }
        }
    }

    /**
     * HBase Sink Function — 批量写入
     */
    public static class HBaseSinkFunction extends org.apache.flink.streaming.api.functions.sink.RichSinkFunction<String> {
        private transient Connection connection;
        private transient BufferedMutator mutator;
        private transient ObjectMapper mapper;

        @Override
        public void open(Configuration parameters) throws Exception {
            org.apache.hadoop.conf.Configuration conf = HBaseConfiguration.create();
            conf.set("hbase.zookeeper.quorum", "zk01:2181,zk02:2181,zk03:2181");
            connection = ConnectionFactory.createConnection(conf);

            BufferedMutatorParams params = new BufferedMutatorParams(TableName.valueOf("order_detail"))
                    .writeBufferSize(10 * 1024 * 1024);  // 10MB 缓冲
            mutator = connection.getBufferedMutator(params);
            mapper = new ObjectMapper();
        }

        @Override
        public void invoke(String value, Context context) throws Exception {
            JsonNode node = mapper.readTree(value);
            String rowkey = node.get("order_id").asText();

            Put put = new Put(Bytes.toBytes(rowkey));
            put.addColumn(Bytes.toBytes("order"), Bytes.toBytes("order_id"),
                    Bytes.toBytes(node.get("order_id").asText()));
            put.addColumn(Bytes.toBytes("order"), Bytes.toBytes("amount"),
                    Bytes.toBytes(node.get("amount").asText()));
            put.addColumn(Bytes.toBytes("order"), Bytes.toBytes("order_time"),
                    Bytes.toBytes(node.get("ts").asText()));
            put.addColumn(Bytes.toBytes("user"), Bytes.toBytes("user_name"),
                    Bytes.toBytes(node.get("user_name").asText()));
            put.addColumn(Bytes.toBytes("user"), Bytes.toBytes("user_age"),
                    Bytes.toBytes(node.get("user_age").asText()));
            put.addColumn(Bytes.toBytes("user"), Bytes.toBytes("user_city"),
                    Bytes.toBytes(node.get("user_city").asText()));

            mutator.mutate(put);
        }

        @Override
        public void close() throws Exception {
            if (mutator != null) {
                mutator.flush();
                mutator.close();
            }
            if (connection != null) {
                connection.close();
            }
        }
    }
}
```

#### 4.1.3 Application Mode on YARN 提交命令

```bash
# ============================================================
# 方式一：使用 SQL Client 提交（推荐快速验证）
# ============================================================
$FLINK_HOME/bin/sql-client.sh embedded \
  -l $FLINK_HOME/lib \
  -f hbase_lookup_job.sql

# ============================================================
# 方式二：Application Mode on YARN 提交（生产推荐）
# ============================================================
export HADOOP_CLASSPATH=$(hadoop classpath)

$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  -Dtaskmanager.numberOfTaskSlots=2 \
  -Dparallelism.default=3 \
  -Dyarn.application.name="Flink-HBase-Lookup-Write" \
  -Dyarn.application.queue=production \
  -Dyarn.ship-files="$FLINK_HOME/conf/hbase-site.xml" \
  -c com.example.HBaseLookupWriteJob \
  /path/to/flink-hbase-job.jar

# ============================================================
# 方式三：Per-Job Mode on YARN（Flink 1.15+ 已废弃，仅做参考）
# ============================================================
$FLINK_HOME/bin/flink run -m yarn-cluster \
  -yjm 2048m \
  -ytm 4096m \
  -ys 2 \
  -yqu production \
  -c com.example.HBaseLookupWriteJob \
  /path/to/flink-hbase-job.jar
```

#### 4.1.4 验证结果

```bash
# ============================================================
# 验证 HBase 写入结果
# ============================================================
echo "scan 'order_detail', {LIMIT => 10}" | hbase shell

# 预期输出:
# ROW                 COLUMN+CELL
# ORD001              column=order:amount, value=99.9
# ORD001              column=order:order_id, value=ORD001
# ORD001              column=order:order_time, value=2026-04-29 10:00:00
# ORD001              column=user:user_age, value=28
# ORD001              column=user:user_city, value=Beijing
# ORD001              column=user:user_name, value=Alice

# 验证 YARN 上的 Flink 作业状态
yarn application -list | grep Flink-HBase

# 查看 Flink Web UI
echo "访问 http://<yarn-rm>:8088 → 点击对应 Application → Flink Dashboard"
```

### 4.2 实战场景：批量导入维表数据到 HBase

```sql
-- 从 Hive 批量导入用户维表到 HBase
-- 适用于维表初始化或定期全量更新

CREATE TABLE hive_user_dim (
    user_id STRING,
    name STRING,
    age INT,
    city STRING,
    update_time TIMESTAMP(3)
) WITH (
    'connector' = 'hive',
    'database' = 'dim',
    'table' = 'user_dim'
);

CREATE TABLE hbase_dim_user_sink (
    rowkey STRING,
    info ROW<name STRING, age INT, city STRING>,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'dim_user',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    'sink.buffer-flush.max-rows' = '5000',
    'sink.buffer-flush.interval' = '2s'
);

INSERT INTO hbase_dim_user_sink
SELECT
    user_id AS rowkey,
    ROW(name, age, city) AS info
FROM hive_user_dim;
```

---

## 五、常见问题与排障

### 5.1 问题排查速查表

| 问题现象 | 可能原因 | 排查命令 / 解决方案 |
|---------|---------|-------------------|
| `NoSuchColumnFamilyException` | HBase 表的 Column Family 名称不匹配 | `echo "describe 'table_name'" \| hbase shell` 检查 CF 名 |
| `ConnectionClosedException` | ZooKeeper 连接超时或地址错误 | 检查 `zookeeper.quorum` 配置，telnet 验证端口 |
| `RegionTooBusyException` | HBase Region 过热 / 写入压力过大 | 检查 Region 分布：`status 'detailed'`，考虑预分区 |
| Lookup Join 结果全为 null | Rowkey 不匹配（类型或编码问题） | 在 HBase shell 中 `get 'table', 'key'` 验证数据是否存在 |
| 写入延迟高 | 缓冲区配置不当 | 调大 `sink.buffer-flush.max-rows` 和 `interval` |
| `ClassNotFoundException` | 缺少 HBase 依赖 JAR | 检查 `$FLINK_HOME/lib` 下是否有 connector jar |
| Kerberos 认证失败 | keytab 过期或路径错误 | `klist -kt /path/to/keytab` 验证 |
| YARN container 启动失败 | HBase 配置文件未传递到 container | 使用 `-Dyarn.ship-files` 携带 hbase-site.xml |

### 5.2 详细排障步骤

#### 问题 1：Lookup Join 返回 null

```bash
# Step 1: 确认 HBase 维表数据存在
echo "get 'dim_user', 'U001'" | hbase shell

# Step 2: 确认 Rowkey 类型一致（String vs Bytes）
# 如果 HBase 中是 Bytes.toBytes(int) 存储，但 Flink SQL 用 STRING 声明，会查不到

# Step 3: 确认 Column Family 名称完全匹配
echo "describe 'dim_user'" | hbase shell
# 输出的 CF 名必须和 Flink DDL 中的 ROW 字段名一致

# Step 4: 在 Flink SQL Client 中单独查询维表
SELECT * FROM dim_user WHERE rowkey = 'U001';
```

#### 问题 2：写入性能差

```bash
# Step 1: 检查 HBase Region 分布
echo "status 'detailed'" | hbase shell

# Step 2: 检查写入参数
# 如果 buffer-flush.interval 太小（如 100ms），会频繁 flush 导致性能差
# 推荐配置：
# sink.buffer-flush.max-rows = 1000 ~ 5000
# sink.buffer-flush.max-size = 5mb ~ 20mb
# sink.buffer-flush.interval = 1s ~ 5s

# Step 3: 检查 Rowkey 设计是否导致热点
# 避免时间戳开头的 Rowkey → 加盐或 Reverse
```

---

## 六、生产最佳实践

### 6.1 资源配置推荐

| 场景 | JobManager 内存 | TaskManager 内存 | Parallelism | Slots/TM |
|------|----------------|-----------------|-------------|----------|
| 小流量（< 1K TPS） | 1G | 2G | 2 | 2 |
| 中等流量（1K ~ 10K TPS） | 2G | 4G | 4-6 | 2 |
| 大流量（10K ~ 100K TPS） | 4G | 8G | 8-16 | 4 |
| 超大流量（> 100K TPS） | 4G | 16G | 16-32 | 4 |

### 6.2 Lookup 缓存调优

```sql
-- 生产推荐配置
CREATE TABLE dim_user (
    ...
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'dim_user',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    -- 缓存策略：根据维表大小和更新频率调整
    'lookup.cache.max-rows' = '10000',     -- 维表 10w 行以内可设 10000
    'lookup.cache.ttl' = '120s',           -- 维表更新频率 > 2min 可设 120s
    'lookup.max-retries' = '3',            -- 重试 3 次
    'lookup.async' = 'true',               -- 异步查询提升吞吐
    -- HBase 客户端配置透传
    'properties.hbase.client.retries.number' = '5',
    'properties.hbase.rpc.timeout' = '10000',
    'properties.hbase.client.operation.timeout' = '30000'
);
```

### 6.3 HBase 写入调优

```sql
-- Sink 生产推荐配置
CREATE TABLE hbase_sink (
    ...
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'result_table',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    -- 批量写入优化
    'sink.buffer-flush.max-size' = '10mb',
    'sink.buffer-flush.max-rows' = '2000',
    'sink.buffer-flush.interval' = '2s',
    -- HBase WAL 配置（高吞吐场景可考虑关闭 WAL）
    'properties.hbase.client.write.buffer' = '10485760'  -- 10MB write buffer
);
```

### 6.4 Kerberos 环境配置

```bash
# ============================================
# 方式一：通过 flink-conf.yaml 配置
# ============================================
cat >> $FLINK_HOME/conf/flink-conf.yaml << 'EOF'
security.kerberos.login.use-ticket-cache: false
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/_HOST@EXAMPLE.COM
security.kerberos.login.contexts: Client,KafkaClient
EOF

# ============================================
# 方式二：提交时通过 -D 参数指定
# ============================================
$FLINK_HOME/bin/flink run-application -t yarn-application \
  -Dsecurity.kerberos.login.keytab=/etc/security/keytabs/flink.keytab \
  -Dsecurity.kerberos.login.principal=flink/_HOST@EXAMPLE.COM \
  -Dsecurity.kerberos.login.contexts=Client,KafkaClient \
  -Dyarn.ship-files="$FLINK_HOME/conf/hbase-site.xml;/etc/security/keytabs/flink.keytab" \
  -c com.example.HBaseLookupWriteJob \
  /path/to/flink-hbase-job.jar

# ============================================
# 方式三：hbase-site.xml 中的 Kerberos 配置
# ============================================
cat > hbase-site-kerberos.xml << 'EOF'
<configuration>
    <property>
        <name>hbase.security.authentication</name>
        <value>kerberos</value>
    </property>
    <property>
        <name>hbase.master.kerberos.principal</name>
        <value>hbase/_HOST@EXAMPLE.COM</value>
    </property>
    <property>
        <name>hbase.regionserver.kerberos.principal</name>
        <value>hbase/_HOST@EXAMPLE.COM</value>
    </property>
</configuration>
EOF
```

### 6.5 监控告警

```bash
# ============================================
# 关键监控指标
# ============================================

# 1. Flink 作业级别
#    - numRecordsIn / numRecordsOut（吞吐量）
#    - currentInputWatermark（水位线）
#    - checkpointDuration（Checkpoint 耗时）

# 2. HBase Lookup 级别
#    - lookup 延迟（通过 Flink Metrics 自定义）
#    - 缓存命中率 = cache_hits / (cache_hits + cache_misses)

# 3. HBase Sink 级别
#    - numBytesOut（写入字节数）
#    - numRecordsOut（写入记录数）

# Prometheus + Grafana 监控配置
cat >> $FLINK_HOME/conf/flink-conf.yaml << 'EOF'
metrics.reporter.promgateway.factory.class: org.apache.flink.metrics.prometheus.PrometheusPushGatewayReporterFactory
metrics.reporter.promgateway.host: prometheus-gw.example.com
metrics.reporter.promgateway.port: 9091
metrics.reporter.promgateway.jobName: flink-hbase-job
metrics.reporter.promgateway.randomJobNameSuffix: true
metrics.reporter.promgateway.deleteOnShutdown: false
metrics.reporter.promgateway.interval: 15 SECONDS
EOF
```

---

## 七、举一反三

### 7.1 对比：HBase vs Redis vs MySQL 作为 Flink 维表

| 对比维度 | HBase | Redis | MySQL |
|---------|-------|-------|-------|
| **查询延迟** | 1~10ms（跨网络） | < 1ms | 1~5ms |
| **数据量** | TB ~ PB 级 | GB 级（受内存限制） | GB ~ TB 级 |
| **适用场景** | 海量维表、宽表 | 热点数据、小维表 | 关系型维表 |
| **Flink 支持** | 官方 Connector | 需自定义或三方 | 官方 JDBC Connector |
| **缓存机制** | 内置 LRU | 自身就是缓存 | 内置 LRU |
| **并发能力** | 高（分布式） | 极高（内存） | 中等 |

### 7.2 面试高频题

**Q1: Flink Lookup Join 的执行原理是什么？**

> Lookup Join 是基于处理时间的点查操作。当主流的每一条记录到达时，Flink 用 Join Key 去维表（如 HBase）做一次 Get 查询，将结果拼接后发往下游。它不是双流 Join，而是"流驱动查表"模式。

**Q2: 如何保证 HBase 维表数据更新后 Flink 能感知到？**

> 通过 `lookup.cache.ttl` 控制。TTL 到期后缓存失效，下次查询会重新访问 HBase。如果需要更实时，可以将 TTL 设小或直接关闭缓存（`max-rows = -1`）。

**Q3: 为什么 Lookup Join 只支持 PROCTIME 不支持 Event Time？**

> 因为 Lookup Join 是"当前时刻去查维表"的语义，Event Time 代表事件发生时间，但维表的历史版本无法回溯（除非维表支持时间旅行），所以只能用 Processing Time。

**Q4: HBase Sink 如何保证 Exactly-Once？**

> HBase Sink 本身不支持事务，但由于 HBase Put 操作是幂等的（相同 Rowkey 写入会覆盖），配合 Flink Checkpoint 的 At-Least-Once，实际效果接近 Exactly-Once。

### 7.3 思考题

1. **Rowkey 设计**：如果订单 ID 是递增的（如 ORD000001, ORD000002...），直接作为 HBase Rowkey 会有什么问题？如何优化？
2. **缓存权衡**：某业务的维表有 100 万行，每分钟更新约 100 行。你如何配置 `lookup.cache.max-rows` 和 `lookup.cache.ttl`？
3. **异步 Lookup**：`lookup.async = true` 相比同步模式的优劣是什么？在什么场景下应该开启？
4. **多 Column Family**：一张 HBase 表有 3 个 Column Family（info、metrics、tags），在 Flink DDL 中如何定义？

---

> 📝 **教案小结**：本教案覆盖了 Flink + HBase 的完整使用姿势，包括 Lookup Join 维表查询、Sink 批量写入、DataStream API 异步查询、Application Mode 提交、Kerberos 配置和生产调优。核心要点：**Rowkey 设计决定查询性能，缓存配置决定吞吐与实时的平衡，批量写入配置决定写入效率**。
