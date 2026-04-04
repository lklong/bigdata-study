# Spark Shuffle 子系统源码分析

## 一、类继承关系

```
ShuffleManager (trait) → SortShuffleManager (唯一实现)
  ├── registerShuffle → 选择 Handle 类型
  ├── getWriter → 根据 Handle 分发 Writer
  └── getReader → BlockStoreShuffleReader

ShuffleHandle (abstract)
  └── BaseShuffleHandle
       ├── SerializedShuffleHandle    (序列化排序路径)
       └── BypassMergeSortShuffleHandle (绕过合并排序)

ShuffleWriter → SortShuffleWriter / UnsafeShuffleWriter / BypassMergeSortShuffleWriter
ShuffleReader → BlockStoreShuffleReader (唯一实现)
```

## 二、Handle 选择逻辑

```
1. BypassMergeSortShuffleHandle: 无 mapSideCombine && numPartitions ≤ 200
2. SerializedShuffleHandle: 无 mapSideCombine && serializer 支持 relocation && numPartitions ≤ 16M
3. BaseShuffleHandle: 兜底
```

## 三、Shuffle Write 链路

```
ShuffleMapTask.runTask → dep.shuffleWriterProcessor.write
  → manager.getWriter(handle) → writer.write(records)
  → SortShuffleWriter: ExternalSorter.insertAll → writePartitionedMapOutput
  → mapOutputWriter.commitAllPartitions → 生成 .data + .index + .checksum 文件
  → MapStatus(blockManager.shuffleServerId, partitionLengths, mapId)
```

## 四、Shuffle Read 链路

```
SortShuffleManager.getReader → BlockStoreShuffleReader.read()
  → ShuffleBlockFetcherIterator (流控: maxBytesInFlight/maxReqsInFlight)
    → partitionBlocksByFetchMode: local/hostLocal/pushMergedLocal/remote
    → fetchUpToMaxBytes → sendRequest (Netty)
  → deserialize → aggregate (如有) → sort (如有)
```

## 五、FetchFailedException 触发和传播

**触发场景**: 远程拉取失败、零字节块、本地IO异常、流解压失败(二次)、Netty OOM 超限

**传播链路**:
```
FetchFailedException 构造 → TaskContext.setFetchFailed (SPARK-19276 防御)
  → Executor 检测 fetchFailed → FetchFailed 发回 Driver
  → DAGScheduler: unregisterMapOutput → failedStages → 200ms 后 ResubmitFailedStages
```

## 六、关键配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `spark.shuffle.sort.bypassMergeThreshold` | 200 | 绕过合并排序的分区数阈值 |
| `spark.reducer.maxSizeInFlight` | 48MB | Reduce 端同时拉取最大数据量 |
| `spark.reducer.maxReqsInFlight` | Int.MaxValue | 最大并发远程请求数 |
| `spark.shuffle.maxAttemptsOnNettyOOM` | 10 | Netty OOM 最大重试 |
| `spark.shuffle.detectCorrupt` | true | 是否检测数据损坏 |
| `spark.shuffle.checksum.enabled` | true | 是否计算校验和 |
| `spark.shuffle.compress` | true | 是否压缩 shuffle 输出 |
| `spark.shuffle.file.buffer` | 32KB | 输出流缓冲区大小 |

## 七、数据倾斜在 Shuffle 中的影响

| 阶段 | 影响 |
|------|------|
| Write端 | ExternalSorter 频繁 spill，merge 大量文件 |
| Block分发 | 大 block 占满 bytesInFlight 预算，降低并行度 |
| 网络传输 | 单个大 block 传输慢，可能触发 Netty OOM |
| Read端聚合 | ExternalAppendOnlyMap 频繁 spill |
| Task执行时间 | 少数 reduce task 运行时间远超平均(长尾效应) |

## 八、核心源码文件索引

| 文件 | 关键内容 |
|------|---------|
| `shuffle/sort/SortShuffleManager.scala` | Handle 选择、Writer/Reader 分发 |
| `shuffle/sort/SortShuffleWriter.scala` | ExternalSorter + 写 shuffle 文件 |
| `shuffle/BlockStoreShuffleReader.scala` | 创建 ShuffleBlockFetcherIterator + 聚合 + 排序 |
| `shuffle/FetchFailedException.scala` | 异常定义 + SPARK-19276 防御 |
| `shuffle/IndexShuffleBlockResolver.scala` | .data/.index/.checksum 文件管理 |
| `storage/ShuffleBlockFetcherIterator.scala` | 1656行! 流控、Netty OOM、损坏检测 |
