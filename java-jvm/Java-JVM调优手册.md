# Java / JVM — 大数据组件的运行时基石

---

## 一、概述

大数据生态 99% 的组件都跑在 JVM 上（Hadoop/Spark/Flink/Hive/HBase/Kafka/ZK/Kyuubi）。**JVM 出问题 = 组件出问题。**

**核心原则**：遇到 OOM、GC 停顿、进程卡住，先看 JVM 再看组件。

---

## 二、JVM 内存模型

### 2.1 堆内存（Heap）

```
         ┌───────────────────────────────┐
         │          JVM Heap             │
         │  ┌──────────┬───────────────┐ │
         │  │  Young    │     Old       │ │
         │  │  ├─Eden   │  (长生命对象) │ │
         │  │  ├─S0     │               │ │
         │  │  └─S1     │               │ │
         │  └──────────┴───────────────┘ │
         └───────────────────────────────┘

-Xms：初始堆大小    -Xmx：最大堆大小（生产环境 Xms=Xmx）
-Xmn：年轻代大小    -XX:NewRatio=2（Old:Young=2:1）
```

### 2.2 堆外内存（Off-Heap / Direct Memory）

```
-XX:MaxDirectMemorySize=2g     # 直接内存（NIO/Netty 用）
-XX:MaxMetaspaceSize=512m      # 元空间（类信息）
-Xss=1m                        # 线程栈大小
```

### 2.3 大数据组件典型配置

| 组件 | 角色 | 推荐堆内存 | GC |
|------|------|-----------|-----|
| NameNode | 元数据（1亿文件~60-80G） | 60-100G | G1 |
| DataNode | 数据节点 | 4-8G | G1 |
| ResourceManager | 调度 | 8-16G | G1 |
| HiveServer2 | SQL 网关 | 8-16G | G1 |
| Spark Driver | 任务驱动 | 4-16G | G1 |
| Spark Executor | 计算执行 | 4-32G | G1 |
| Flink TaskManager | 流处理 | 4-16G（JVM 部分） | G1 |
| HBase RegionServer | 存储 | 16-32G | G1/CMS |
| Kafka Broker | 消息队列 | 6-8G | G1 |
| ZooKeeper | 协调 | 2-4G | G1 |

---

## 三、GC 收集器选型

### 3.1 收集器对比

| 收集器 | 特点 | 适用场景 | 参数 |
|--------|------|----------|------|
| **G1**（推荐） | 分区回收，可控停顿 | **大数据首选**，堆 >4G | `-XX:+UseG1GC` |
| CMS | 并发标记清除 | 旧版本兼容 | `-XX:+UseConcMarkSweepGC` |
| **ZGC** | 超低停顿（<10ms） | JDK 17+，极低延迟场景 | `-XX:+UseZGC` |
| Parallel | 高吞吐 | 批处理 | `-XX:+UseParallelGC` |

### 3.2 G1GC 关键参数

```bash
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200          # 目标停顿时间（毫秒）
-XX:G1HeapRegionSize=16m          # Region 大小（堆大时调大）
-XX:InitiatingHeapOccupancyPercent=45  # 触发并发标记的堆占用比
-XX:G1NewSizePercent=5            # 年轻代最小比例
-XX:G1MaxNewSizePercent=60        # 年轻代最大比例
-XX:ConcGCThreads=4               # 并发 GC 线程数
-XX:ParallelGCThreads=8           # 并行 GC 线程数
```

### 3.3 GC 日志（必须开启）

```bash
# JDK 8
-XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCTimeStamps
-Xloggc:/var/log/hadoop/gc.log -XX:+UseGCLogFileRotation
-XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=50M

# JDK 11+
-Xlog:gc*:file=/var/log/hadoop/gc.log:time,uptime,level,tags:filecount=10,filesize=50m
```

---

## 四、JVM 排障工具箱

### 4.1 线程分析（进程卡住/CPU 高）

```bash
# 1. 找到 Java 进程 PID
jps -mlv | grep [组件关键字]

# 2. 导出线程栈（最重要的排障工具）
jstack <pid> > thread_dump.txt

# 3. 如果进程不响应
jstack -F <pid> > thread_dump.txt

# 4. 分析线程状态
grep "java.lang.Thread.State" thread_dump.txt | sort | uniq -c | sort -rn
# RUNNABLE = 运行中   BLOCKED = 锁等待   WAITING = 条件等待
# 大量 BLOCKED → 锁竞争   大量 WAITING → 等待外部资源

# 5. 定位 CPU 最高的线程
top -Hp <pid>                       # 找到线程号
printf "%x\n" <线程号>               # 转十六进制
jstack <pid> | grep -A 20 "nid=0x<十六进制>"   # 定位线程栈
```

### 4.2 内存分析（OOM）

```bash
# 1. 堆内存概况
jmap -heap <pid>

# 2. 对象统计（不触发 Full GC）
jmap -histo <pid> | head -30

# 3. 导出堆转储（会暂停进程！慎用生产环境）
jmap -dump:format=b,file=heap.hprof <pid>

# 4. 自动导出（OOM 时自动 dump，推荐配置）
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/heap_dump.hprof

# 5. 分析工具
# MAT (Eclipse Memory Analyzer)
# VisualVM
# jhat（命令行）
```

### 4.3 GC 监控

```bash
# 实时 GC 统计（每秒一次，共 10 次）
jstat -gcutil <pid> 1000 10

# 输出解读：
# S0/S1: Survivor 区使用率    E: Eden 使用率    O: Old 区使用率
# M: Metaspace 使用率
# YGC: Young GC 次数          YGCT: Young GC 总时间
# FGC: Full GC 次数           FGCT: Full GC 总时间
# GCT: GC 总时间

# 关注点：
# FGC 频繁增长 → 内存不够或内存泄漏
# FGCT 占比高 → Full GC 停顿太长
# O 持续 >80% → Old 区快满了
```

---

## 五、常见 JVM 问题排查

### 5.1 Full GC 频繁

**排查路径**：
1. `jstat -gcutil <pid> 1000` → 看 FGC 是否持续增长
2. `jmap -histo <pid> | head -20` → 看什么对象占用最多
3. 堆是否太小？→ 加大 `-Xmx`
4. 是否有内存泄漏？→ dump 堆分析

**大数据常见原因**：
| 组件 | 常见 Full GC 原因 |
|------|-------------------|
| NameNode | 文件数太多，堆不够 |
| Spark Executor | 数据倾斜，单分区数据过大 |
| Spark Driver | collect() 拉回太多数据 |
| HBase RS | Memstore 刷写不及时 |
| Kafka Broker | 消息堆积，PageCache 不够 |

### 5.2 OOM（OutOfMemoryError）

| 错误类型 | 含义 | 解决 |
|----------|------|------|
| `Java heap space` | 堆内存不够 | 加大 -Xmx 或排查泄漏 |
| `GC overhead limit exceeded` | GC 占比 >98% 时间 | 同上 |
| `Metaspace` | 类信息空间不够 | 加大 -XX:MaxMetaspaceSize |
| `Direct buffer memory` | 直接内存不够（NIO） | 加大 -XX:MaxDirectMemorySize |
| `unable to create new native thread` | 线程数超限 | `ulimit -u` 调大或减少线程 |
| `Requested array size exceeds VM limit` | 数组太大 | 检查代码逻辑 |
| `kill process (oom-killer)` | OS 级别 OOM，JVM 被杀 | 加物理内存或减少进程 |

### 5.3 进程卡住（Hang）

1. `jstack <pid>` 导出线程栈
2. 多次 dump（间隔 5s），对比哪些线程一直在同一位置 → 卡死点
3. 常见原因：
   - 死锁：`jstack` 输出末尾会提示 `Found 1 deadlock`
   - 锁竞争：大量线程 BLOCKED on 同一个 lock
   - IO 阻塞：线程卡在 `socketRead` / `write` → 检查外部系统
   - GC 风暴：所有线程都在等 GC → `jstat` 看 GC

---

## 六、JDK 版本选择（大数据场景）

| JDK 版本 | 状态 | 适用 |
|----------|------|------|
| JDK 8 | 仍广泛使用 | Hadoop 3.3.x、Spark 3.x、Flink 1.x |
| **JDK 11** | LTS，推荐升级目标 | Flink CDC 3.6.0 要求 |
| **JDK 17** | LTS，未来主力 | Spark 4.0 要求 |
| JDK 21 | 最新 LTS | Hive 4.2 支持，前沿探索 |

**注意**：同一集群中不同组件可能需要不同 JDK 版本，通过 `JAVA_HOME` 环境变量分别设置。

---

## 七、命令速查

```bash
# 进程查看
jps -mlv                            # Java 进程列表
jps -mlv | grep NameNode            # 找特定组件

# 线程分析
jstack <pid>                        # 线程栈
jstack -F <pid>                     # 强制导出（进程无响应时）

# 内存分析
jmap -heap <pid>                    # 堆概况
jmap -histo <pid> | head -30        # 对象统计
jmap -dump:format=b,file=dump.hprof <pid>  # 堆转储

# GC 监控
jstat -gcutil <pid> 1000 10         # GC 统计
jstat -gc <pid> 1000 10             # GC 详细

# 运行时信息
jinfo <pid>                         # JVM 参数
jinfo -flag MaxHeapSize <pid>       # 查看单个参数

# 性能采样（JDK 11+）
jcmd <pid> JFR.start duration=60s filename=record.jfr  # 飞行记录
```
