# 教案 S06：Flink 内存模型 — 为什么你的 TaskManager 总是 OOM？

> **课时**：45分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入

> 你给 TaskManager 配了 8GB 内存，但作业跑起来后 Container 被 YARN Kill 了，报 `Container killed by the ApplicationMaster. Exit code is 137`（OOM Killed）。明明只用了 4GB 状态，为什么 8GB 还不够？
>
> 因为 Flink 的内存模型**不是一整块**，而是切成了很多份，每份有自己的用途和限制。

## 二、Flink TaskManager 内存结构

```
Total Process Memory (配置或自动推算)
├── Total Flink Memory (flink 管理的部分)
│   ├── Framework Heap (框架堆内存, 128MB 默认)
│   ├── Task Heap (用户代码堆内存, ★最常调的)
│   ├── Framework Off-Heap (框架堆外, 128MB)
│   ├── Task Off-Heap (用户代码堆外, 0 默认)
│   ├── Network Memory (网络缓冲区, 占比 10%, min=64MB, max=1GB)
│   └── Managed Memory (托管内存, 占比 40%, 用于 RocksDB/排序/哈希)
├── JVM Metaspace (256MB 默认)
└── JVM Overhead (占比 10%, min=192MB, 用于线程栈/JNI等)
```

## 三、关键配置

| 配置 | 推荐值 | 说明 |
|------|--------|------|
| `taskmanager.memory.process.size` | 4g-16g | 容器总内存 |
| `taskmanager.memory.task.heap.size` | 手动设或自动推算 | 用户代码可用堆 |
| `taskmanager.memory.managed.fraction` | 0.4 (RocksDB) / 0.1 (HashMap) | 托管内存占比 |
| `taskmanager.memory.network.fraction` | 0.1 | 网络缓冲占比 |
| `taskmanager.memory.jvm-overhead.fraction` | 0.1 | JVM 开销 |

## 四、OOM 排查决策树

```
Container 被 Kill (exit 137)?
├── 堆内存不够 → java.lang.OutOfMemoryError: Java heap space
│   └── 增大 task.heap.size 或减少状态大小
├── 堆外内存溢出 → 容器超限但没有 Java OOM
│   ├── RocksDB 使用超过 managed memory → 配置 RocksDB block cache
│   ├── Netty 网络缓冲超限 → 增大 network memory
│   └── JNI/线程栈超限 → 增大 jvm-overhead
└── 元空间不够 → OutOfMemoryError: Metaspace
    └── 增大 jvm-metaspace.size (动态类加载多时)
```

## 五、Managed Memory 详解（为什么占 40%？）

| 使用者 | 场景 | 说明 |
|--------|------|------|
| **RocksDB** | Keyed State 后端 | Block Cache + Write Buffer |
| **Batch Sort** | 批处理排序 | 外部排序缓冲区 |
| **Hash Join** | 批处理 Join | 哈希表构建 |
| **Python UDF** | PyFlink | Python 进程内存 |

如果用 **HashMapStateBackend**（状态在堆内），可以把 managed.fraction 调低到 0.1，省出的给 task.heap。

## 六、课堂练习

### 思考题：process.size=8GB，managed=40%，network=10%，算出 task.heap 有多少？

<details>
<summary>参考答案</summary>

```
Total Process = 8GB
- JVM Metaspace = 256MB
- JVM Overhead = 8GB × 10% = 800MB (但 min=192MB, max 由配置决定)
= Total Flink Memory ≈ 8GB - 256MB - 800MB ≈ 6.94GB

Total Flink Memory ≈ 6.94GB
- Managed = 6.94GB × 40% = 2.78GB
- Network = 6.94GB × 10% = 694MB
- Framework Heap = 128MB
- Framework Off-Heap = 128MB
- Task Off-Heap = 0
= Task Heap = 6.94GB - 2.78GB - 694MB - 128MB - 128MB - 0 ≈ 3.21GB
```

**结论：8GB 总内存，用户代码实际只能用 ~3.2GB 堆内存！**
</details>

## 七、知识晶体

```
Flink TM 内存 = Task Heap + Managed + Network + Framework + Overhead + Metaspace
Task Heap: 用户代码实际可用（通常只占总量的 30-40%！）
Managed: RocksDB/Sort/Hash（HashMap后端可调低到10%）
OOM排查: exit 137 → 区分堆内/堆外/Metaspace → 对症调参
```

*教案作者：Eric | 最后更新：2026-04-30*
