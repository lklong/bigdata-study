# [教案] Flink on YARN — Redis 维表与缓存使用姿势

> 🎯 教学目标：掌握 Flink 读写 Redis 的多种方式，包括维表 Join、Async I/O、Sink 写入 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

在实时数据处理中，Redis 承担着至关重要的角色：

| 场景 | 说明 | 典型案例 |
|------|------|----------|
| **维表关联** | 实时流关联 Redis 中的维度数据 | 订单流关联用户画像、商品信息 |
| **实时缓存** | 将 Flink 计算结果写入 Redis 供下游查询 | 实时大屏指标、实时排行榜 |
| **去重/计数** | 利用 Redis 的 Set/HyperLogLog 做实时去重 | UV 统计、设备去重 |
| **限流/风控** | 利用 Redis 做滑动窗口限流 | 实时风控、刷单检测 |
| **状态外置** | 将部分热点状态存入 Redis 供多任务共享 | 跨任务状态共享 |

**核心问题**：Flink 的 State 虽然强大，但它是 Task 私有的，无法被外部系统直接查询。而 Redis 作为高性能 KV 存储，天然适合承接「可被外部查询的实时状态」。

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17+ / 1.18+ / 1.19+ | 推荐 1.18.1 |
| Hadoop/YARN | 3.x | 需开启 YARN |
| Redis | 5.0+ | 单机或 Cluster |
| Java | JDK 8 / JDK 11 | |
| Maven | 3.6+ | 构建项目 |

### 2.2 环境准备命令

```bash
# 1. 验证 Flink
export FLINK_HOME=/opt/flink-1.18.1
$FLINK_HOME/bin/flink --version

# 2. 验证 YARN
yarn node -list
yarn application -list

# 3. 验证 Redis
redis-cli -h redis-host -p 6379 ping
# 期望输出: PONG

# 4. 设置 HADOOP 环境变量
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)

# 5. 准备 Redis 测试数据（维表数据）
redis-cli -h redis-host -p 6379 << 'EOF'
HSET user:1001 name "张三" age "28" city "北京" level "VIP"
HSET user:1002 name "李四" age "35" city "上海" level "普通"
HSET user:1003 name "王五" age "22" city "深圳" level "VIP"
HSET user:1004 name "赵六" age "40" city "广州" level "钻石"
HSET user:1005 name "钱七" age "31" city "杭州" level "普通"
EOF

# 6. 下载所需 Connector JAR
# bahir-flink-connector（社区维护）
wget https://repo1.maven.org/maven2/org/apache/bahir/flink-connector-redis_2.12/1.1.0/flink-connector-redis_2.12-1.1.0.jar \
  -P $FLINK_HOME/lib/

# 或使用 Jedis 自定义方式（推荐）
wget https://repo1.maven.org/maven2/redis/clients/jedis/4.4.6/jedis-4.4.6.jar \
  -P $FLINK_HOME/lib/
wget https://repo1.maven.org/maven2/org/apache/commons/commons-pool2/2.11.1/commons-pool2-2.11.1.jar \
  -P $FLINK_HOME/lib/
```

### 2.3 Maven 依赖

```xml
<properties>
    <flink.version>1.18.1</flink.version>
    <jedis.version>4.4.6</jedis.version>
    <scala.binary.version>2.12</scala.binary.version>
</properties>

<dependencies>
    <!-- Flink 核心 -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-streaming-java</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-clients</artifactId>
        <version>${flink.version}</version>
        <scope>provided</scope>
    </dependency>

    <!-- Flink Kafka Connector -->
    <dependency>
        <groupId>org.apache.flink</groupId>
        <artifactId>flink-connector-kafka</artifactId>
        <version>3.1.0-1.18</version>
    </dependency>

    <!-- Bahir Redis Connector（可选） -->
    <dependency>
        <groupId>org.apache.bahir</groupId>
        <artifactId>flink-connector-redis_2.12</artifactId>
        <version>1.1.0</version>
    </dependency>

    <!-- Jedis（自定义 Redis 操作推荐） -->
    <dependency>
        <groupId>redis.clients</groupId>
        <artifactId>jedis</artifactId>
        <version>${jedis.version}</version>
    </dependency>

    <!-- 连接池 -->
    <dependency>
        <groupId>org.apache.commons</groupId>
        <artifactId>commons-pool2</artifactId>
        <version>2.11.1</version>
    </dependency>

    <!-- JSON 处理 -->
    <dependency>
        <groupId>com.alibaba</groupId>
        <artifactId>fastjson</artifactId>
        <version>2.0.42</version>
    </dependency>
</dependencies>
```

---

## 三、核心使用方式

### 3.1 方式一：Bahir Redis Connector（RedisSink）

Bahir 提供了开箱即用的 Redis Sink，支持多种 Redis 数据结构。

#### 支持的 Redis 命令

| RedisCommand | Redis 数据结构 | 说明 |
|-------------|---------------|------|
| `LPUSH` | List | 左侧插入列表 |
| `RPUSH` | List | 右侧插入列表 |
| `SADD` | Set | 添加到集合 |
| `SET` | String | 设置键值对 |
| `PFADD` | HyperLogLog | 添加到 HyperLogLog |
| `HSET` | Hash | 设置 Hash 字段 |
| `ZADD` | Sorted Set | 添加到有序集合 |
| `PUBLISH` | Pub/Sub | 发布消息 |

#### 代码示例：Bahir RedisSink

```java
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.connectors.redis.RedisSink;
import org.apache.flink.streaming.connectors.redis.common.config.FlinkJedisPoolConfig;
import org.apache.flink.streaming.connectors.redis.common.mapper.RedisCommand;
import org.apache.flink.streaming.connectors.redis.common.mapper.RedisCommandDescription;
import org.apache.flink.streaming.connectors.redis.common.mapper.RedisMapper;

public class BahirRedisSinkExample {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // Redis 连接配置
        FlinkJedisPoolConfig redisConfig = new FlinkJedisPoolConfig.Builder()
                .setHost("redis-host")
                .setPort(6379)
                .setPassword("your-password")  // 无密码则不设置
                .setDatabase(0)
                .setMaxTotal(8)
                .setMaxIdle(8)
                .setMinIdle(2)
                .setTimeout(5000)
                .build();

        // 模拟数据流: (userId, score)
        DataStream<Tuple2<String, String>> stream = env.fromElements(
                Tuple2.of("user:1001", "100"),
                Tuple2.of("user:1002", "250"),
                Tuple2.of("user:1003", "180")
        );

        // 写入 Redis（String 类型，SET 命令）
        stream.addSink(new RedisSink<>(redisConfig, new RedisStringMapper()));

        env.execute("Bahir-Redis-Sink-Demo");
    }

    // 自定义 RedisMapper：写入 String 类型
    public static class RedisStringMapper
            implements RedisMapper<Tuple2<String, String>> {
        @Override
        public RedisCommandDescription getCommandDescription() {
            return new RedisCommandDescription(RedisCommand.SET);
        }

        @Override
        public String getKeyFromData(Tuple2<String, String> data) {
            return data.f0;  // Redis Key
        }

        @Override
        public String getValueFromData(Tuple2<String, String> data) {
            return data.f1;  // Redis Value
        }
    }
}
```

#### 写入 Hash 类型

```java
// 写入 Redis Hash: HSET additionalKey field value
public static class RedisHashMapper
        implements RedisMapper<Tuple3<String, String, String>> {

    @Override
    public RedisCommandDescription getCommandDescription() {
        // additionalKey 是 Hash 的 key
        return new RedisCommandDescription(RedisCommand.HSET, "user_profile");
    }

    @Override
    public String getKeyFromData(Tuple3<String, String, String> data) {
        return data.f0;  // Hash Field
    }

    @Override
    public String getValueFromData(Tuple3<String, String, String> data) {
        return data.f1 + ":" + data.f2;  // Hash Value
    }
}
```

### 3.2 方式二：自定义 RichSinkFunction + Jedis（推荐）

Bahir Connector 功能有限，生产环境推荐自定义 Sink，可完全控制连接池、序列化、异常处理。

```java
import org.apache.flink.configuration.Configuration;
import org.apache.flink.streaming.api.functions.sink.RichSinkFunction;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

public class CustomRedisSink extends RichSinkFunction<OrderEvent> {

    private transient JedisPool jedisPool;

    private final String redisHost;
    private final int redisPort;
    private final String redisPassword;

    public CustomRedisSink(String host, int port, String password) {
        this.redisHost = host;
        this.redisPort = port;
        this.redisPassword = password;
    }

    @Override
    public void open(Configuration parameters) throws Exception {
        super.open(parameters);
        JedisPoolConfig poolConfig = new JedisPoolConfig();
        poolConfig.setMaxTotal(16);
        poolConfig.setMaxIdle(8);
        poolConfig.setMinIdle(4);
        poolConfig.setMaxWaitMillis(5000);
        poolConfig.setTestOnBorrow(true);
        poolConfig.setTestWhileIdle(true);

        jedisPool = new JedisPool(poolConfig, redisHost, redisPort, 5000, redisPassword);
    }

    @Override
    public void invoke(OrderEvent event, Context context) throws Exception {
        try (Jedis jedis = jedisPool.getResource()) {
            // 写入 Hash
            String key = "order:" + event.getOrderId();
            jedis.hset(key, "userId", event.getUserId());
            jedis.hset(key, "amount", String.valueOf(event.getAmount()));
            jedis.hset(key, "status", event.getStatus());
            jedis.hset(key, "timestamp", String.valueOf(event.getTimestamp()));
            // 设置过期时间 24 小时
            jedis.expire(key, 86400);

            // 写入 Sorted Set（实时排行榜）
            jedis.zadd("order_rank:daily", event.getAmount(), event.getUserId());
        }
    }

    @Override
    public void close() throws Exception {
        if (jedisPool != null && !jedisPool.isClosed()) {
            jedisPool.close();
        }
        super.close();
    }
}
```

### 3.3 方式三：Async I/O 异步查询 Redis 维表（核心重点）

#### 参数详解表

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| `timeout` | 异步请求超时时间 | 5000ms |
| `capacity` | 异步请求队列容量 | 100~1000 |
| `asyncMode` | ORDERED（保序）/ UNORDERED（无序） | UNORDERED（吞吐优先） |
| `cacheMaxSize` | 本地缓存大小 | 10000 |
| `cacheTTL` | 本地缓存过期时间 | 60s~300s |

#### 完整 Async I/O 代码

```java
import org.apache.flink.streaming.api.datastream.AsyncDataStream;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.functions.async.ResultFuture;
import org.apache.flink.streaming.api.functions.async.RichAsyncFunction;
import org.apache.flink.configuration.Configuration;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

import java.util.Collections;
import java.util.Map;
import java.util.concurrent.*;

public class AsyncRedisLookupFunction
        extends RichAsyncFunction<OrderEvent, EnrichedOrderEvent> {

    private transient JedisPool jedisPool;
    private transient ExecutorService executorService;

    // 本地缓存（减少 Redis 访问）
    private transient com.google.common.cache.Cache<String, Map<String, String>> localCache;

    private final String redisHost;
    private final int redisPort;
    private final String redisPassword;

    public AsyncRedisLookupFunction(String host, int port, String password) {
        this.redisHost = host;
        this.redisPort = port;
        this.redisPassword = password;
    }

    @Override
    public void open(Configuration parameters) throws Exception {
        // 初始化 Jedis 连接池
        JedisPoolConfig poolConfig = new JedisPoolConfig();
        poolConfig.setMaxTotal(32);
        poolConfig.setMaxIdle(16);
        poolConfig.setMinIdle(8);
        poolConfig.setMaxWaitMillis(3000);
        poolConfig.setTestOnBorrow(true);

        jedisPool = new JedisPool(poolConfig, redisHost, redisPort, 5000, redisPassword);

        // 异步线程池
        executorService = new ThreadPoolExecutor(
                8, 32, 60L, TimeUnit.SECONDS,
                new LinkedBlockingQueue<>(1000),
                new ThreadPoolExecutor.CallerRunsPolicy()
        );

        // Guava 本地缓存
        localCache = com.google.common.cache.CacheBuilder.newBuilder()
                .maximumSize(10000)
                .expireAfterWrite(60, TimeUnit.SECONDS)
                .build();
    }

    @Override
    public void asyncInvoke(OrderEvent input, ResultFuture<EnrichedOrderEvent> resultFuture) {
        String userId = input.getUserId();

        // 先查本地缓存
        Map<String, String> cached = localCache.getIfPresent("user:" + userId);
        if (cached != null) {
            resultFuture.complete(Collections.singleton(
                    enrichOrder(input, cached)
            ));
            return;
        }

        // 缓存未命中，异步查 Redis
        CompletableFuture.supplyAsync(() -> {
            try (Jedis jedis = jedisPool.getResource()) {
                return jedis.hgetAll("user:" + userId);
            }
        }, executorService).thenAccept(userInfo -> {
            if (userInfo != null && !userInfo.isEmpty()) {
                // 写入本地缓存
                localCache.put("user:" + userId, userInfo);
                resultFuture.complete(Collections.singleton(
                        enrichOrder(input, userInfo)
                ));
            } else {
                // 维表数据不存在，设置默认值
                resultFuture.complete(Collections.singleton(
                        enrichOrderDefault(input)
                ));
            }
        }).exceptionally(throwable -> {
            resultFuture.complete(Collections.singleton(
                    enrichOrderDefault(input)
            ));
            return null;
        });
    }

    @Override
    public void timeout(OrderEvent input, ResultFuture<EnrichedOrderEvent> resultFuture) {
        // 超时处理：返回默认值
        resultFuture.complete(Collections.singleton(enrichOrderDefault(input)));
    }

    private EnrichedOrderEvent enrichOrder(OrderEvent order, Map<String, String> userInfo) {
        return new EnrichedOrderEvent(
                order.getOrderId(),
                order.getUserId(),
                order.getAmount(),
                order.getStatus(),
                order.getTimestamp(),
                userInfo.getOrDefault("name", "unknown"),
                userInfo.getOrDefault("city", "unknown"),
                userInfo.getOrDefault("level", "unknown")
        );
    }

    private EnrichedOrderEvent enrichOrderDefault(OrderEvent order) {
        return new EnrichedOrderEvent(
                order.getOrderId(), order.getUserId(), order.getAmount(),
                order.getStatus(), order.getTimestamp(),
                "unknown", "unknown", "unknown"
        );
    }

    @Override
    public void close() throws Exception {
        if (executorService != null) executorService.shutdown();
        if (jedisPool != null) jedisPool.close();
    }
}
```

#### 在主流程中使用 Async I/O

```java
// 主流程
DataStream<OrderEvent> orderStream = env
        .fromSource(kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-orders");

// 异步关联 Redis 维表
DataStream<EnrichedOrderEvent> enrichedStream = AsyncDataStream.unorderedWait(
        orderStream,
        new AsyncRedisLookupFunction("redis-host", 6379, "password"),
        5000,                    // 超时时间 ms
        TimeUnit.MILLISECONDS,
        100                      // 异步请求队列容量
);
```

### 3.4 方式四：Flink SQL + Redis（自定义 Connector）

Flink SQL 原生不支持 Redis，需要自定义 `DynamicTableSourceFactory` / `DynamicTableSinkFactory`。
社区有开源实现可直接使用：[flink-connector-redis](https://github.com/jeff-zou/flink-connector-redis)

```sql
-- 创建 Redis 维表（需自定义 Connector）
CREATE TABLE redis_user_dim (
    user_id STRING,
    name STRING,
    city STRING,
    level STRING
) WITH (
    'connector' = 'redis',
    'host' = 'redis-host',
    'port' = '6379',
    'password' = 'your-password',
    'command' = 'HGETALL',
    'lookup.cache.max-rows' = '10000',
    'lookup.cache.ttl' = '60s',
    'lookup.async' = 'true',
    'lookup.max-retries' = '3'
);

-- Kafka 订单表
CREATE TABLE kafka_orders (
    order_id STRING,
    user_id STRING,
    amount DOUBLE,
    order_time TIMESTAMP(3),
    WATERMARK FOR order_time AS order_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kafka',
    'topic' = 'orders',
    'properties.bootstrap.servers' = 'kafka-host:9092',
    'properties.group.id' = 'flink-redis-demo',
    'scan.startup.mode' = 'latest-offset',
    'format' = 'json'
);

-- Kafka 结果表
CREATE TABLE kafka_enriched_orders (
    order_id STRING,
    user_id STRING,
    amount DOUBLE,
    user_name STRING,
    city STRING,
    user_level STRING,
    order_time TIMESTAMP(3)
) WITH (
    'connector' = 'kafka',
    'topic' = 'enriched_orders',
    'properties.bootstrap.servers' = 'kafka-host:9092',
    'format' = 'json'
);

-- 维表 JOIN（LATERAL TABLE / FOR SYSTEM_TIME AS OF）
INSERT INTO kafka_enriched_orders
SELECT
    o.order_id,
    o.user_id,
    o.amount,
    u.name AS user_name,
    u.city,
    u.level AS user_level,
    o.order_time
FROM kafka_orders AS o
LEFT JOIN redis_user_dim FOR SYSTEM_TIME AS OF o.order_time AS u
ON o.user_id = u.user_id;
```

---

## 四、完整实战示例：Kafka → Flink Join Redis维表 → Kafka

### 4.1 场景描述

电商订单流从 Kafka 进入 Flink，需实时关联 Redis 中的用户画像（姓名、城市、等级），丰富后写入下游 Kafka 和 Redis 排行榜。

### 4.2 数据模型

```java
// 订单事件
@Data
@AllArgsConstructor
@NoArgsConstructor
public class OrderEvent implements Serializable {
    private String orderId;
    private String userId;
    private double amount;
    private String status;      // CREATED / PAID / SHIPPED
    private long timestamp;
}

// 丰富后的订单
@Data
@AllArgsConstructor
@NoArgsConstructor
public class EnrichedOrderEvent implements Serializable {
    private String orderId;
    private String userId;
    private double amount;
    private String status;
    private long timestamp;
    private String userName;
    private String city;
    private String userLevel;
}
```

### 4.3 完整主程序

```java
import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.connector.kafka.sink.KafkaSink;
import org.apache.flink.connector.kafka.sink.KafkaRecordSerializationSchema;
import org.apache.flink.streaming.api.datastream.AsyncDataStream;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import com.alibaba.fastjson.JSON;

import java.util.concurrent.TimeUnit;

public class KafkaRedisEnrichmentJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(4);

        // 启用 Checkpoint
        env.enableCheckpointing(60000);  // 60 秒

        // ===== 1. Kafka Source =====
        KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                .setBootstrapServers("kafka-host:9092")
                .setTopics("orders")
                .setGroupId("flink-redis-enrichment")
                .setStartingOffsets(OffsetsInitializer.latest())
                .setValueOnlyDeserializer(new SimpleStringSchema())
                .build();

        DataStream<OrderEvent> orderStream = env
                .fromSource(kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-orders")
                .map(json -> JSON.parseObject(json, OrderEvent.class))
                .name("parse-orders");

        // ===== 2. Async I/O 关联 Redis 维表 =====
        DataStream<EnrichedOrderEvent> enrichedStream = AsyncDataStream.unorderedWait(
                orderStream,
                new AsyncRedisLookupFunction("redis-host", 6379, "your-password"),
                5000, TimeUnit.MILLISECONDS, 200
        ).name("async-redis-lookup");

        // ===== 3. 写入下游 Kafka =====
        KafkaSink<String> kafkaSink = KafkaSink.<String>builder()
                .setBootstrapServers("kafka-host:9092")
                .setRecordSerializer(
                        KafkaRecordSerializationSchema.builder()
                                .setTopic("enriched_orders")
                                .setValueSerializationSchema(new SimpleStringSchema())
                                .build()
                )
                .build();

        enrichedStream
                .map(event -> JSON.toJSONString(event))
                .sinkTo(kafkaSink)
                .name("kafka-sink");

        // ===== 4. 同时写入 Redis 排行榜 =====
        enrichedStream
                .addSink(new CustomRedisSink("redis-host", 6379, "your-password"))
                .name("redis-rank-sink");

        env.execute("Kafka-Redis-Enrichment-Job");
    }
}
```

### 4.4 Application Mode 提交命令

```bash
# 打包
mvn clean package -DskipTests

# Application Mode 提交到 YARN
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Kafka-Redis-Enrichment" \
    -Dyarn.application.queue=default \
    -Dyarn.ship-files="/opt/flink-1.18.1/lib/jedis-4.4.6.jar;/opt/flink-1.18.1/lib/commons-pool2-2.11.1.jar" \
    -c com.example.KafkaRedisEnrichmentJob \
    /path/to/flink-redis-demo-1.0.jar
```

### 4.5 验证

```bash
# 1. 查看 YARN 应用
yarn application -list | grep "Kafka-Redis-Enrichment"

# 2. 发送测试数据到 Kafka
kafka-console-producer.sh --broker-list kafka-host:9092 --topic orders << 'EOF'
{"orderId":"ORD001","userId":"1001","amount":99.9,"status":"CREATED","timestamp":1714400000000}
{"orderId":"ORD002","userId":"1002","amount":259.0,"status":"PAID","timestamp":1714400001000}
{"orderId":"ORD003","userId":"1003","amount":188.5,"status":"CREATED","timestamp":1714400002000}
EOF

# 3. 消费下游 Kafka 验证
kafka-console-consumer.sh --bootstrap-server kafka-host:9092 \
    --topic enriched_orders --from-beginning

# 期望输出（JSON 已丰富用户信息）:
# {"orderId":"ORD001","userId":"1001","amount":99.9,"status":"CREATED",
#  "userName":"张三","city":"北京","userLevel":"VIP",...}

# 4. 验证 Redis 排行榜
redis-cli -h redis-host -p 6379 ZREVRANGE order_rank:daily 0 9 WITHSCORES
```

---

## 五、常见问题与排障

### 5.1 问题速查表

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `JedisConnectionException: Could not get a resource from the pool` | 连接池耗尽 | 增大 `maxTotal`，检查是否有连接泄漏（每次操作必须 `close()` Jedis） |
| `JedisDataException: NOAUTH Authentication required` | Redis 有密码但未配置 | 在连接池配置中添加密码参数 |
| `SocketTimeoutException: Read timed out` | Redis 响应超时 | 增大 `timeout`，检查 Redis 负载和网络 |
| Async I/O 超时大量报警 | Redis 慢查询或连接不足 | 增大线程池、检查 Redis `slowlog`、增大 `capacity` |
| Checkpoint 超时 | Sink buffer 过大或 Redis 写入慢 | 减小 batch size，检查 Redis 性能 |
| `ClassNotFoundException: redis.clients.jedis.Jedis` | JAR 未正确打包 | 使用 `maven-shade-plugin` 打 fat-jar 或用 `yarn.ship-files` 分发 |
| Redis Cluster `MOVED` 错误 | 使用了 JedisPool 连接 Cluster | 改用 `JedisCluster` |

### 5.2 排障命令

```bash
# 查看 Flink 任务日志
yarn logs -applicationId application_xxxxx_xxxx | grep -i "redis"

# 查看 Redis 慢查询
redis-cli -h redis-host SLOWLOG GET 10

# 查看 Redis 连接数
redis-cli -h redis-host INFO clients

# 查看 Redis 内存使用
redis-cli -h redis-host INFO memory

# 查看 Redis 命令统计
redis-cli -h redis-host INFO commandstats
```

### 5.3 连接池泄漏排查

```java
// 错误写法：忘记关闭 Jedis 连接
public void invoke(OrderEvent event, Context context) {
    Jedis jedis = jedisPool.getResource();
    jedis.set(event.getOrderId(), JSON.toJSONString(event));
    // 忘记 jedis.close() → 连接泄漏！
}

// 正确写法：try-with-resources 自动关闭
public void invoke(OrderEvent event, Context context) {
    try (Jedis jedis = jedisPool.getResource()) {
        jedis.set(event.getOrderId(), JSON.toJSONString(event));
    }  // 自动归还连接到连接池
}
```

---

## 六、生产最佳实践

### 6.1 连接池管理最佳配置

```java
JedisPoolConfig poolConfig = new JedisPoolConfig();
// 最大连接数 = TM 数量 * 并行度 * 单 Task 峰值并发
// 例如: 4 个 TM * 4 并行度 → 每个 Task 的池子不要太大
poolConfig.setMaxTotal(16);          // 每个 Task 最大 16 连接
poolConfig.setMaxIdle(8);            // 最大空闲 8
poolConfig.setMinIdle(4);            // 最小空闲 4（保持预热）
poolConfig.setMaxWaitMillis(3000);   // 获取连接最大等待 3s
poolConfig.setTestOnBorrow(true);    // 借出时验证连接
poolConfig.setTestWhileIdle(true);   // 空闲时验证连接
poolConfig.setTimeBetweenEvictionRunsMillis(30000); // 30s 检查一次空闲连接
poolConfig.setMinEvictableIdleTimeMillis(60000);    // 空闲 60s 被回收
```

### 6.2 Redis Cluster 模式

```java
// 单机模式
JedisPool pool = new JedisPool(config, host, port, timeout, password);

// Cluster 模式
Set<HostAndPort> nodes = new HashSet<>();
nodes.add(new HostAndPort("redis-node1", 7001));
nodes.add(new HostAndPort("redis-node2", 7002));
nodes.add(new HostAndPort("redis-node3", 7003));

JedisCluster jedisCluster = new JedisCluster(
    nodes, 5000, 5000, 3, "password",
    new GenericObjectPoolConfig<>()
);
```

### 6.3 Lettuce 异步客户端（高级）

```java
// Lettuce 天然支持异步，更适合 Flink Async I/O
import io.lettuce.core.RedisClient;
import io.lettuce.core.api.async.RedisAsyncCommands;
import io.lettuce.core.api.StatefulRedisConnection;

public class LettuceAsyncRedisFunction
        extends RichAsyncFunction<OrderEvent, EnrichedOrderEvent> {

    private transient RedisClient redisClient;
    private transient StatefulRedisConnection<String, String> connection;
    private transient RedisAsyncCommands<String, String> asyncCommands;

    @Override
    public void open(Configuration parameters) {
        redisClient = RedisClient.create("redis://password@redis-host:6379/0");
        connection = redisClient.connect();
        asyncCommands = connection.async();
    }

    @Override
    public void asyncInvoke(OrderEvent input, ResultFuture<EnrichedOrderEvent> resultFuture) {
        asyncCommands.hgetall("user:" + input.getUserId())
                .thenAccept(userInfo -> {
                    resultFuture.complete(Collections.singleton(
                            enrichOrder(input, userInfo)
                    ));
                })
                .exceptionally(throwable -> {
                    resultFuture.complete(Collections.singleton(
                            enrichOrderDefault(input)
                    ));
                    return null;
                });
    }

    @Override
    public void close() {
        if (connection != null) connection.close();
        if (redisClient != null) redisClient.shutdown();
    }
}
```

### 6.4 资源配置参考

| 场景 | 吞吐量 | 并行度 | TM 内存 | Redis 连接池/Task | Async 队列 |
|------|--------|--------|---------|-------------------|-----------|
| 小流量（<1K QPS） | 低 | 2 | 2G | 4 | 50 |
| 中流量（1K~10K QPS） | 中 | 4~8 | 4G | 8 | 100 |
| 大流量（10K~100K QPS） | 高 | 8~16 | 8G | 16 | 200 |
| 超大流量（>100K QPS） | 极高 | 16~32 | 8G+ | 32 | 500 |

### 6.5 监控告警

```yaml
# Prometheus 监控指标（Flink Metric Reporter 配置）
# flink-conf.yaml
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporter
metrics.reporter.prom.port: 9249

# 关键监控项
# - flink_taskmanager_job_task_numRecordsInPerSecond   (吞吐)
# - flink_taskmanager_job_task_numRecordsOutPerSecond   (输出吞吐)
# - flink_taskmanager_job_task_currentInputWatermark    (水位线)
# - AsyncWaitOperator 的 asyncTimeout 计数             (异步超时)
```

---

## 七、举一反三

### 7.1 Redis vs 其他维表存储对比

| 维度 | Redis | HBase | MySQL | Hive |
|------|-------|-------|-------|------|
| 延迟 | <1ms | 5~20ms | 5~50ms | 秒级 |
| 吞吐 | 10W+ QPS | 1W+ QPS | 5K QPS | 批处理 |
| 数据量 | GB 级 | TB 级 | GB 级 | PB 级 |
| 适用场景 | 热点维表 | 大维表 | 小维表 | 离线维表 |
| 一致性 | 最终一致 | 强一致 | 强一致 | 最终一致 |

### 7.2 面试高频题

**Q1: Flink Async I/O 的 ORDERED 和 UNORDERED 有什么区别？**

| 模式 | 行为 | 适用场景 |
|------|------|----------|
| `ORDERED` | 严格保持输入顺序，先请求的先输出 | 对顺序敏感的场景（如金融交易） |
| `UNORDERED` | 谁先返回谁先输出 | 对吞吐要求高、顺序不敏感的场景 |

> UNORDERED 吞吐更高，因为不会被慢请求阻塞。生产中 80% 的场景用 UNORDERED。

**Q2: 为什么要在 Async I/O 中加本地缓存？**

- 热点 Key 命中率极高（如 Top 1000 用户占 80% 流量）
- 减少 Redis 网络 I/O，降低延迟
- 降低 Redis 集群压力
- 注意：缓存 TTL 不能太长，否则维表更新不及时

**Q3: Flink 写 Redis 如何保证不丢数据？**

- 启用 Checkpoint + 两阶段提交（Redis 不支持事务的场景下，使用幂等写入）
- Redis 写入天然幂等（SET / HSET 覆盖写），所以只要 Flink 能重放数据即可保证 At-Least-Once
- 对于 LPUSH/SADD 等非幂等操作，需要在应用层做去重

### 7.3 思考题

1. 如果 Redis 集群发生主从切换，Flink 任务会受到什么影响？如何做到自动故障转移？
2. 当维表数据量从百万级增长到千万级时，Redis 单机内存不够了，你会如何扩展？
3. 如何实现 Redis 维表的「准实时更新」—— 维表数据变更后，Flink 任务能在 5 秒内感知？
4. Async I/O 的 capacity 设置过大或过小分别会有什么问题？如何根据实际场景调优？

---

> 📝 **本教案配套代码仓库**: [bigdata-study/flink/案例/](https://github.com/lklong/bigdata-study/tree/main/flink/案例/)
> 📅 **更新日期**: 2026-04-29
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
