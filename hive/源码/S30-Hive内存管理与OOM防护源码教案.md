# [教案] Hive内存管理与OOM防护源码深度剖析

> 🎯 教学目标：掌握Hive/Tez内存配置体系、MapJoin内存限制机制、HashTable溢写、向量化批次内存关系、HS2自身内存管理及常见OOM防护策略  
> ⏰ 预计学时：3学时  
> 📊 难度：⭐⭐⭐⭐⭐（高级）

---

## 一、课前导入（生活类比引入）

### 1.1 生活类比：厨房操作台空间管理

- **厨房总面积（Container内存）**：tez.am.resource.memory.mb
- **操作台面（JVM堆内存）**：-Xmx（Container的80%）
- **切菜板（MapJoin HashTable）**：hive.auto.convert.join.noconditionaltask.size
- **冰箱暂存（溢写磁盘）**：当操作台放不下时转移到冰箱
- **一次端多少盘（向量化批次）**：hive.vectorized.execution.row.batch.size

### 1.2 生产故障场景Top3

```
1. MapJoin OOM：
   java.lang.OutOfMemoryError: Java heap space
   at org.apache.hadoop.hive.ql.exec.MapJoinOperator.loadHashTable

2. Tez Container OOM：
   Container [pid=xxx] is running beyond physical memory limits.
   Current usage: 4.2 GB of 4 GB physical memory used

3. HS2 OOM：
   GC overhead limit exceeded
   at org.apache.hive.service.cli.operation.SQLOperation
   (大量并发查询结果集堆积)
```

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 含义 | 类比 |
|------|------|------|
| Container Memory | YARN分配的物理内存总量 | 厨房面积 |
| JVM Heap (-Xmx) | Java堆内存 | 操作台面积 |
| noconditionaltask.size | MapJoin小表阈值 | 切菜板大小 |
| HashTableSinkOperator | 构建Hash表的算子 | 食材预处理 |
| VectorizedRowBatch | 向量化行批次 | 一次端的盘数 |
| Spill | 内存不足时写磁盘 | 放冰箱暂存 |
| MapJoinMemoryExhaustionHandler | 内存耗尽处理器 | 台面爆满应急 |

### 2.2 Hive内存层次架构

```
┌──────────────────────────────────────────────────────────────────┐
│                    Hive/Tez Memory Hierarchy                       │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Level 1: YARN Container (物理内存)                              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ tez.am.resource.memory.mb = 4096 (Tez AM)                 │ │
│  │ hive.tez.container.size = 4096 (Task Container)            │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  Level 2: JVM Heap                                              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ hive.tez.java.opts = -Xmx3276m (Container的80%)            │ │
│  │                                                            │ │
│  │  ┌─────────────────────────────────────────────────────┐  │ │
│  │  │ Level 3: Operator Memory                            │  │ │
│  │  │                                                     │  │ │
│  │  │ ┌──────────────┐ ┌───────────────┐ ┌────────────┐ │  │ │
│  │  │ │MapJoin HT    │ │Sort Buffer    │ │Result Cache│ │  │ │
│  │  │ │(nocondition  │ │(io.sort.mb)   │ │(HS2)       │ │  │ │
│  │  │ │ task.size)   │ │               │ │            │ │  │ │
│  │  │ │ 10MB默认     │ │ 100MB默认     │ │            │ │  │ │
│  │  │ └──────────────┘ └───────────────┘ └────────────┘ │  │ │
│  │  └─────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  Level 4: Off-Heap / Native Memory                              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ Snappy/LZ4 压缩缓冲 | LLAP IO Cache | Netty Buffer        │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 MapJoin内存限制与Hash表构建

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/exec/MapJoinOperator.java`

#### 3.1.1 MapJoin自动转换判断

```java
// ConvertJoinMapJoin.java 中的判断逻辑
// 核心参数：hive.auto.convert.join.noconditionaltask.size (默认10MB)

public class ConvertJoinMapJoin {
    private long getThresholdOfSmallTable(HiveConf conf) {
        // 小表的数据大小 < noconditionaltask.size 时才转MapJoin
        return conf.getLongVar(HiveConf.ConfVars.HIVECONVERTJOINNOCONDITIONALTASKTHRESHOLD);
    }
}
```

#### 3.1.2 HashTable加载过程

```java
// MapJoinOperator.java 核心加载逻辑
public class MapJoinOperator extends AbstractMapJoinOperator<MapJoinDesc> {
    
    // Hash表容器
    protected transient MapJoinTableContainer[] mapJoinTables;
    
    @Override
    protected void loadHashTable(MapredContext mrContext, ExecMapperContext mapContext) {
        // 1. 确定加载策略
        if (isDirectFetch) {
            // 直接从本地文件加载（小表已提前分发）
            loadHashTableFromFile(mapContext);
        } else {
            // 从HDFS加载
            loadHashTableFromDFS(mapContext);
        }
    }
    
    private void loadHashTableFromFile(ExecMapperContext ctx) {
        for (int pos = 0; pos < mapJoinTables.length; pos++) {
            if (pos == conf.getPosBigTable()) continue; // 跳过大表
            
            // 创建Hash表容器
            MapJoinTableContainer tableContainer = new HashMapWrapper(hconf, -1);
            
            // 逐行加载到内存
            while (reader.next(key, value)) {
                tableContainer.putRow(key, value);
                
                // 内存检查！
                numEntries++;
                if (numEntries % CHECK_INTERVAL == 0) {
                    checkMemoryUsage(tableContainer, numEntries);
                }
            }
            mapJoinTables[pos] = tableContainer;
        }
    }
    
    private void checkMemoryUsage(MapJoinTableContainer container, long numEntries) {
        long usedMemory = container.getEstimatedMemorySize();
        long threshold = conf.getMemoryThreshold();
        
        if (usedMemory > threshold) {
            // 触发内存耗尽处理
            handleMemoryExhaustion(container);
        }
    }
}
```

#### 3.1.3 内存耗尽处理器

```java
// MapJoinMemoryExhaustionHandler
public interface MapJoinMemoryExhaustionHandler {
    void handleMemoryExhaustion(MapJoinTableContainer container, ...);
}

// 实现1：降级为Common Join
public class MapJoinFallbackHandler implements MapJoinMemoryExhaustionHandler {
    public void handleMemoryExhaustion(...) {
        LOG.warn("MapJoin memory threshold exceeded, falling back to common join");
        // 中止MapJoin，告知框架用Reduce端Join
        throw new MapJoinMemoryExhaustionException("Spill threshold exceeded");
    }
}
```

---

### 3.2 VectorMapJoin的Fast HashTable

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/exec/vector/mapjoin/fast/VectorMapJoinFastHashTable.java`

```java
public abstract class VectorMapJoinFastHashTable {
    
    protected int logicalHashBucketCount;  // Hash桶数量
    protected int logicalHashBucketMask;   // 桶掩码（用于取模）
    protected float loadFactor;            // 负载因子
    protected int writeBufferSize;         // 写缓冲大小
    
    // 内存估算
    protected long estimatedKeyCount;      // 预估key数量
    
    public VectorMapJoinFastHashTable(int initialCapacity, float loadFactor, int writeBufferSize) {
        // 计算桶数量（2的幂次）
        int capacity = Long.highestOneBit(initialCapacity);
        if (capacity < initialCapacity) capacity <<= 1;
        
        this.logicalHashBucketCount = capacity;
        this.logicalHashBucketMask = capacity - 1;
        this.loadFactor = loadFactor;
        this.writeBufferSize = writeBufferSize;
    }
}
```

#### Fast HashTable加载器

```java
// VectorMapJoinFastHashTableLoader.java
public class VectorMapJoinFastHashTableLoader {
    
    public void load(MapJoinTableContainer tableContainer, ...) {
        // 关键参数：
        // hive.mapjoin.optimized.hashtable.wbsize = 10485760 (10MB写缓冲)
        // hive.hashtable.loadfactor = 0.75
        // hive.hashtable.initialCapacity = 100000
        
        long keyCount = 0;
        while (reader.next(key, value)) {
            hashTable.putRow(key.getBytes(), value.getBytes());
            keyCount++;
            
            // 定期检查内存
            if (keyCount % 100000 == 0) {
                long memoryUsed = hashTable.getEstimatedMemorySize();
                long maxMemory = Runtime.getRuntime().maxMemory();
                
                if (memoryUsed > maxMemory * memoryThreshold) {
                    // 溢写到磁盘
                    spillToDisk(hashTable);
                }
            }
        }
    }
}
```

---

### 3.3 向量化批次与内存关系

> 📁 源码位置：`ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizedRowBatch.java`

```java
public class VectorizedRowBatch {
    // 每批次行数，直接影响内存使用
    // hive.vectorized.execution.row.batch.size = 1024 (默认)
    public static final int DEFAULT_SIZE = 1024;
    
    public int numCols;           // 列数
    public ColumnVector[] cols;   // 列向量数组
    public int size;              // 当前批次实际行数
    
    // 内存估算：
    // 每个LongColumnVector: 8bytes * batchSize = 8KB (batchSize=1024)
    // 每个DoubleColumnVector: 8bytes * batchSize = 8KB
    // 每个BytesColumnVector: 变长，取决于字符串长度
    // 100列 * 8KB ≈ 800KB per batch (仅数值型)
}
```

**内存计算公式**：
```
单Batch内存 ≈ batchSize × numCols × avgColumnSize
总内存 ≈ 并行度 × pipelineDepth × 单Batch内存
```

---

### 3.4 HS2自身内存管理

#### 3.4.1 结果集缓存

```java
// SQLOperation 中的结果获取
public class SQLOperation {
    
    // 结果行以序列化形式暂存
    private transient List<Object[]> resultRows;
    
    // 关键参数：
    // hive.server2.thrift.resultset.serialize.in.tasks = true (序列化在Task中完成)
    // hive.server2.thrift.resultset.max.fetch.size = 10000 (每次fetch最大行数)
    
    public RowSet getNextRowSet(FetchOrientation orientation, long maxRows) {
        // 从Driver获取结果（可能触发Fetch Task）
        driver.getResults(results);
        // 序列化为RowSet返回客户端
        // 注意：如果客户端fetch慢，结果会堆积在HS2内存中！
    }
}
```

#### 3.4.2 操作日志内存

```java
// OperationLog 存储在内存中直到写入文件
// hive.server2.logging.operation.enabled = true
// hive.server2.logging.operation.log.location = /tmp/hive/operation_logs

// 每个Operation都有独立的日志缓冲
// 大量并发Operation + 大量日志输出 → 内存压力
```

#### 3.4.3 元数据缓存

```java
// SessionHiveMetaStoreClient 中的缓存
// hive.metastore.client.cache.enabled = false (默认关闭)
// 如果开启，表/分区元数据会缓存在HS2进程中
// 大量表 × 大量分区 = 巨大内存占用
```

---

### 3.5 常见OOM场景与防护机制

#### 场景1：MapJoin小表估算不准

```
原因：统计信息不准确，实际数据远大于noconditionaltask.size
防护：
1. hive.auto.convert.join.noconditionaltask.size 设置保守值
2. hive.mapjoin.check.memory.rows = 100000 (定期检查内存)
3. hive.hashtable.key.count.adjustment = 0.99 (调整hash表大小)
```

#### 场景2：Container物理内存超限

```
原因：JVM堆 + 堆外(压缩缓冲/Netty) > Container内存
防护：
1. JVM堆 = Container × 0.8 (预留20%给堆外)
2. -XX:MaxDirectMemorySize 显式限制堆外
3. YARN: yarn.nodemanager.pmem-check-enabled (物理内存检查)
```

#### 场景3：HS2大量并发查询结果堆积

```
原因：客户端fetch慢，结果集在HS2堆积
防护：
1. hive.server2.idle.operation.timeout = 3600000 (操作超时)
2. hive.server2.thrift.resultset.max.fetch.size = 1000 (限制单次fetch)
3. 限制并发: hive.server2.async.exec.threads
```

---

## 四、生产实战案例

### 4.1 案例：MapJoin OOM调优

**故障现象**：
```
java.lang.OutOfMemoryError: Java heap space
  at org.apache.hadoop.hive.ql.exec.persistence.MapJoinBytesTableContainer.putRow
```

**排障步骤**：
```sql
-- 1. 检查当前配置
SET hive.auto.convert.join;                            -- true
SET hive.auto.convert.join.noconditionaltask.size;     -- 10485760 (10MB)

-- 2. 检查小表实际大小
DESCRIBE FORMATTED small_table;
-- 看totalSize

-- 3. 调优方案
-- 方案A：减小阈值（避免错误地转MapJoin）
SET hive.auto.convert.join.noconditionaltask.size=5242880;  -- 5MB

-- 方案B：增大Container内存
SET hive.tez.container.size=8192;
SET hive.tez.java.opts=-Xmx6553m;

-- 方案C：关闭MapJoin
SET hive.auto.convert.join=false;

-- 方案D：更新统计信息让优化器做正确判断
ANALYZE TABLE small_table COMPUTE STATISTICS FOR COLUMNS;
```

### 4.2 参数调优全表

| 参数 | 默认值 | 建议 | 说明 |
|------|--------|------|------|
| `hive.tez.container.size` | 1024MB | 4096-8192 | Task Container内存 |
| `hive.tez.java.opts` | -Xmx820m | Container×0.8 | JVM堆大小 |
| `hive.auto.convert.join.noconditionaltask.size` | 10MB | 200-500MB | MapJoin阈值 |
| `hive.vectorized.execution.row.batch.size` | 1024 | 1024 | 向量化批次大小 |
| `hive.mapjoin.optimized.hashtable` | true | true | 优化HashTable |
| `hive.mapjoin.optimized.hashtable.wbsize` | 10MB | 10MB | 写缓冲大小 |
| `hive.server2.idle.operation.timeout` | 0 | 3600000 | 操作超时(ms) |
| `tez.runtime.io.sort.mb` | 100 | 256 | Sort缓冲区 |
| `tez.runtime.unordered.output.buffer.size-mb` | - | 100 | 无序输出缓冲 |

---

## 五、举一反三

### 5.1 面试高频题

**Q1：hive.auto.convert.join.noconditionaltask.size的含义和风险？**

A：该参数定义MapJoin中小表的最大允许大小（序列化后）。如果统计信息不准确导致实际数据大于该值，Hash表加载时会OOM。风险：统计信息过期、复杂表达式放大数据量、压缩率高导致解压后膨胀。

**Q2：Container被YARN杀死（physical memory exceeded）和Java OOM有什么区别？**

A：
- Container killed：总物理内存(堆+堆外+Native)超过YARN限制
- Java OOM：仅JVM堆内存超过-Xmx
前者需要增大container.size或减少堆外内存使用；后者需要增大-Xmx或减少堆内对象。

**Q3：向量化的batchSize设太大会怎样？**

A：每个batch占用更多内存（numCols × batchSize × typeSize），在多算子pipeline场景下内存成倍增长。设太小则无法充分利用CPU缓存行。1024是经验最佳值。

### 5.2 思考题

1. 如何设计一个自适应的MapJoin内存管理机制（实时监控+动态降级）？
2. Tez AM的内存和Task Container的内存有什么关系？AM OOM会怎样？
3. LLAP中的IO Cache和这里讨论的内存管理有什么关系？

---

## 六、知识晶体（一页纸总结）

```
┌────────────────────────────────────────────────────────────────┐
│         Hive 内存管理与OOM防护核心知识晶体                      │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  内存层次：                                                     │
│  Container(4G) → JVM Heap(3.2G=80%) → Operator Memory          │
│                                                                │
│  三大OOM场景：                                                   │
│  1. MapJoin HT溢出 → noconditionaltask.size控制                │
│  2. Container物理超限 → 堆+堆外 > container.size               │
│  3. HS2结果堆积 → 并发×结果集 > HS2 Heap                       │
│                                                                │
│  MapJoin内存控制链：                                            │
│  统计信息 → noconditionaltask.size比较 →                        │
│  决定是否MapJoin → loadHashTable → checkMemory →               │
│  超限则fallback/spill                                          │
│                                                                │
│  向量化内存公式：                                                │
│  batchMem = batchSize(1024) × numCols × avgColSize             │
│  totalMem = parallelism × pipelineDepth × batchMem             │
│                                                                │
│  防护策略：                                                      │
│  • Container=4G, Heap=3.2G, noconditionaltask=200MB            │
│  • ANALYZE TABLE定期更新统计信息                                 │
│  • 查询超时 + 操作超时 + 连接限流                               │
│  • mapjoin.check.memory.rows 定期内存检查                       │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/exec/MapJoinOperator.java`
2. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/exec/vector/mapjoin/fast/`
3. Hive源码：`ql/src/java/org/apache/hadoop/hive/ql/exec/vector/VectorizedRowBatch.java`
4. Tez文档：Container Memory Configuration
5. HIVE-13391: MapJoin memory management improvements
6. Hive Wiki: Vectorization / MapJoin
