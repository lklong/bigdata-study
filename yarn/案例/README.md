# Hadoop 2.8.5 NodeManager 堆外内存泄漏深度分析

## 背景

Hadoop 2.8.5 YARN NodeManager (NM) 进程在长时间运行后，RSS（Resident Set Size）远超 `-Xmx` 设定值，持续增长直至打满机器物理内存，导致 OOM Killer 杀死进程或机器完全不可用。

**问题环境**：
- **Hadoop 版本**: 2.8.5
- **JDK**: Java 8
- **集群规模**: 500 节点，偶发（非所有节点同时出现）
- **问题表现**: NM 正常调度 Container → 机器出现 OOM → NM 不再调度任务执行 → NM 堆外内存持续上升 → 最终打满机器内存

本项目通过对 Hadoop 2.8.5 YARN NodeManager 源码和社区已知 JIRA 的全面分析，定位了 **18 个堆外内存泄漏点**，覆盖 6 大维度。

## 严重程度

- **P0 级**（致命）: 4 个泄漏点
- **P1 级**（严重）: 6 个泄漏点
- **P2 级**（中度）: 8 个泄漏点

## 最致命的 4 个问题

| # | 泄漏点 | 源码路径 | 根因 | 相关 JIRA |
|---|--------|----------|------|-----------|
| 1 | ShuffleHandler `sendError()` ByteBuf 泄漏 | `ShuffleHandler.java:1088-1096` | sendError 异常路径下 Netty ByteBuf 未 release，错误响应写失败时 ByteBuf 泄漏 | YARN-7754 |
| 2 | ShuffleHandler `sendMapOutput()` FadvisedFileRegion 泄漏 | `ShuffleHandler.java:sendMapOutput()` | ChannelFuture 写失败后 FadvisedFileRegion 未关闭，文件描述符 + ByteBuf 双重泄漏 | MAPREDUCE-6424 |
| 3 | LogAggregationService Deflater 原生内存泄漏 | `LogAggregationService.java` | Container 日志压缩使用的 Deflater 未调用 end() 释放 JNI native memory | YARN-8482 |
| 4 | glibc malloc arena 碎片化导致 RSS 虚高 | JVM + glibc 层面 | JDK 8 + glibc 默认 MALLOC_ARENA_MAX=8*cores，大量线程并发分配/释放 native memory 导致 arena 碎片化 | HADOOP-7154 |

## 分析维度

| 维度 | 状态 | 关键发现 |
|------|------|----------|
| ShuffleHandler (Netty ByteBuf) | ❌ 严重 | sendError/sendMapOutput 异常路径 ByteBuf 未 release、FadvisedFileRegion 泄漏、ChannelPipeline idle 超时后资源未清理 |
| Container 日志聚合 | ❌ 严重 | Deflater/Inflater 未调用 end() 释放 JNI native memory，大量 Container 频繁创建销毁时累积 |
| NIO DirectByteBuffer | ⚠️ 中度 | NM-RM 心跳 RPC 的 Hadoop IPC 层 DirectByteBuffer、日志读取的 MappedByteBuffer |
| 线程池 / ThreadLocal | ⚠️ 中度 | ContainersLauncher 线程池异常路径线程不释放、AsyncDispatcher 线程泄漏 |
| gzip/snappy 原生库 | ⚠️ 中度 | Container 日志压缩编解码器通过 JNI 分配原生内存，Codec 池复用异常路径不释放 |
| glibc malloc arena 碎片化 | ⚠️ 中度 | Linux glibc 默认每核 8 个 arena (64MB/个)，高并发线程场景下 RSS 虚高 |

## 偶发性分析

500 节点中偶发出现，说明与特定触发条件相关：

| 假设 | 概率 | 关键证据 |
|------|------|----------|
| ShuffleHandler 错误路径触发 | **高** | 只有 Shuffle fetch 失败/超时/连接断开时才走 sendError 路径泄漏 ByteBuf |
| 特定作业的 Container 异常退出频率高 | **高** | 异常退出触发日志聚合异常路径，Deflater 不调用 end() |
| 节点硬件差异导致的 GC 表现不同 | **中** | 内存较小的节点 GC 更频繁，DirectByteBuffer Cleaner 延迟执行 |
| 特定 Shuffle 负载模式 | **中** | 某些作业的 Shuffle 数据量大、并发高，放大 ShuffleHandler 泄漏 |

## 快速缓解

```bash
# 1. 限制 glibc malloc arena 数量（最关键的运维措施）
export MALLOC_ARENA_MAX=4
# 在 yarn-env.sh 或 hadoop-env.sh 中设置

# 2. 限制 DirectByteBuffer 总量
# 在 NM JVM 参数中添加
-XX:MaxDirectMemorySize=1g

# 3. 启用 NMT 精确定位泄漏源
-XX:NativeMemoryTracking=detail

# 4. 开启 Netty ByteBuf 泄漏检测（排查用，线上慎开）
-Dio.netty.leakDetectionLevel=PARANOID

# 5. 低峰期定期重启 NM（临时缓解）
# 配合 NM 优雅退出：yarn.nodemanager.recovery.enabled=true
```

## 因果链

```
[触发条件] Shuffle fetch 失败/超时 OR Container 异常退出
    → [ShuffleHandler] sendError() 中 ByteBuf 未 release + FadvisedFileRegion 未关闭
    → [日志聚合] Deflater/Inflater 未调用 end()，JNI native memory 泄漏
    → [中间影响] Netty ByteBuf 累积 + Deflater native memory 累积 + DirectByteBuffer 依赖 GC Finalizer
    → [glibc] 大量 native memory 分配/释放导致 malloc arena 碎片化，RSS 进一步虚高
        → [最终现象] NM RSS 远超 Xmx，持续增长 → 机器 OOM → 不再调度 Container → 打满机器内存
```

## 文件结构

```
.
├── README.md                           # 本文件
├── report/
│   └── full-analysis-report.md         # 完整分析报告（含所有 18 个泄漏点详情）
├── patches/
│   └── recommended-fixes.md            # 推荐的代码修复清单
└── scripts/
    ├── monitor-nm-offheap.sh           # NM 堆外内存监控脚本
    ├── nmt-diff-nm.sh                  # NMT 快照对比脚本
    └── check-shuffle-leak.sh           # ShuffleHandler Netty ByteBuf 泄漏专项检测脚本
```

## 版本修复矩阵

| JIRA | 问题 | 2.8.5 | 2.10.x | 3.1.x | 3.3.x |
|------|------|-------|--------|-------|-------|
| YARN-7754 | ShuffleHandler sendError ByteBuf 泄漏 | ❌ | ❌ | ✅ 3.1.0 | ✅ |
| MAPREDUCE-6424 | ShuffleHandler sendMapOutput 泄漏 | 部分 | ✅ | ✅ | ✅ |
| YARN-8482 | 日志聚合 Deflater 泄漏 | ❌ | ❌ | ✅ 3.1.0 | ✅ |
| YARN-6062 | NM native memory leak (综合) | ❌ | ❌ | ❌ | ❌ |
| HADOOP-7154 | MALLOC_ARENA_MAX | ✅ Workaround | ✅ | ✅ | ✅ |
| HADOOP-12611 | Deflater native memory 通用泄漏 | 部分 | ✅ | ✅ | ✅ |
| HADOOP-13362 | Metrics system 源名称泄漏 | ❌ | ✅ | ✅ | ✅ |
| YARN-3528 | NM 日志聚合资源泄漏 | ✅ 2.8.0 | ✅ | ✅ | ✅ |

## License

Internal use - 内部运维分析文档
