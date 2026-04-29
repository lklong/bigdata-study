# 教案 12：Spark Task 执行与数据序列化全链路

> **课时**：45分钟 | **难度**：⭐⭐⭐⭐

## 一、课前导入 — 为什么你的 Spark 作业 Task 执行这么慢？

> Spark UI 显示你的某个 Stage 有 200 个 Task，其中 195 个 10 秒就完成了，但有 5 个跑了 10 分钟。这就是**数据倾斜**。但更隐蔽的问题是：即使没有倾斜，如果**序列化方式选错了**，所有 Task 都会慢 3-5 倍。

## 二、Task 执行全链路

```
Driver 端:
  DAGScheduler → TaskScheduler → SchedulerBackend
       │                │
       ▼                ▼
  Stage 划分       Task 序列化 + 发送
                        │
                        ▼ (网络传输 TaskDescription)
Executor 端:
  CoarseGrainedExecutorBackend → Executor → TaskRunner
       │
       ▼
  反序列化 Task → 反序列化 RDD 闭包 → 执行 compute()
       │
       ▼
  结果序列化 → 返回 Driver (或写 Shuffle)
```

### 核心性能关键点

| 环节 | 性能风险 | 解法 |
|------|---------|------|
| Task 序列化 | 闭包中引用了大对象 → 序列化慢 | 用 Broadcast 替代 |
| 数据反序列化 | Kryo 不稳定 / Java 序列化慢 | 注册 Kryo 类 |
| compute() 执行 | UDF 效率低 / 数据倾斜 | 向量化 / 加盐 |
| 结果序列化 | collect() 拉回大量数据 | 避免 collect()，用 write |
| Shuffle 写 | 磁盘 IO / 网络瓶颈 | 用 Celeborn / 增大 buffer |

## 三、序列化器选型

| 序列化器 | 速度 | 大小 | 适用 |
|---------|------|------|------|
| **Java Serializable** | 慢（1x） | 大（1x） | 默认，兼容性好 |
| **Kryo** | 快（3-5x） | 小（0.3-0.5x） | 生产推荐 |
| **Tungsten UnsafeRow** | 最快（10x） | 最小 | Spark SQL 内部自动使用 |

```python
# 启用 Kryo
spark.conf.set("spark.serializer", "org.apache.spark.serializer.KryoSerializer")
spark.conf.set("spark.kryo.registrationRequired", "true")  # 生产建议开启
spark.conf.set("spark.kryo.classesToRegister", "com.company.MyClass,com.company.MyClass2")
```

## 四、Tungsten 的秘密 — 为什么 Spark SQL 比 RDD 快？

Spark SQL 内部使用 **UnsafeRow**：
- 数据直接存储在堆外内存的连续字节数组中
- 不需要 Java 对象头（省 16 字节/对象）
- 固定长度字段直接按 offset 访问（O(1)，无需反序列化）
- Cache-friendly（CPU 缓存命中率高）

```
Java Object:  [Header 16B] [Field1 pointer] [Field2 pointer] ...
                              ↓                 ↓
                        [实际数据]          [实际数据]   ← 内存不连续

UnsafeRow:    [null bitmap] [field1 value] [field2 value] [var-len data...]
              └──────── 连续内存块，无指针追踪 ─────────┘
```

## 五、课堂练习

### 思考题：Broadcast 变量 vs 闭包引用

<details>
<summary>参考答案</summary>

```python
# 错误：大字典在闭包中，每个 Task 序列化一份
big_dict = load_big_dict()  # 100MB
rdd.map(lambda x: big_dict.get(x))  # 100个Task = 传输 10GB！

# 正确：Broadcast 只传一份到每个 Executor
bc_dict = sc.broadcast(big_dict)   # 只传 1 次到每个 Executor
rdd.map(lambda x: bc_dict.value.get(x))  # 传输量 = Executor数 × 100MB
```
</details>

## 六、知识晶体

```
Task链路: Driver序列化 → 网络 → Executor反序列化 → compute → 结果返回
序列化: Java(慢) < Kryo(快3-5x) < UnsafeRow(最快10x)
优化: Broadcast大对象 + Kryo注册类 + 避免collect
Tungsten: 堆外连续内存 + 无对象头 + O(1)字段访问
```

*教案作者：Eric | 最后更新：2026-04-30*
