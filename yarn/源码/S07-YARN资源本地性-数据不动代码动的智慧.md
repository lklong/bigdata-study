# 教案 S07：YARN 资源本地性 — 数据不动代码动的智慧

> **课时**：35分钟 | **难度**：⭐⭐⭐

## 一、课前导入

> 你的 Spark 作业有 100 个 Task 读 HDFS 数据。如果 Task 被调度到数据所在的节点 → 本地读取（2GB/s SSD 速度）。如果被调度到远程节点 → 网络传输（1Gbps = 125MB/s）。性能差 **16 倍**！这就是为什么资源本地性如此重要。

## 二、三级本地性

| 级别 | 含义 | 速度 | 对应常量 |
|------|------|------|---------|
| **NODE_LOCAL** | 数据和计算在同一节点 | 最快（磁盘速度） | NodeLocalityLevel |
| **RACK_LOCAL** | 数据和计算在同一机架 | 中等（机架内网络） | RackLocalityLevel |
| **OFF_SWITCH** (ANY) | 数据在远程节点 | 最慢（跨机架网络） | OffSwitchLevel |

## 三、调度器如何保证本地性？

### Delay Scheduling（延迟调度）

```
AM 请求: "我要一个 Container，最好在 node-01 上"

调度器:
  Round 1: node-01 没有空闲资源 → 不分配，等一下
  Round 2: node-01 还是没资源 → 继续等
  Round 3: 等了 40 次心跳了 → 算了，给个 RACK_LOCAL 的
  Round 4: RACK_LOCAL 也没有 → 再等
  Round 5: 等了 40 次 → 算了，ANY 级别随便找个节点
```

### 关键配置

```xml
<!-- CapacityScheduler -->
<property>
    <name>yarn.scheduler.capacity.node-locality-delay</name>
    <value>40</value> <!-- 等多少次心跳后放宽到 RACK_LOCAL -->
</property>
<property>
    <name>yarn.scheduler.capacity.rack-locality-additional-delay</name>
    <value>-1</value> <!-- -1=同上, 正数=额外等待次数 -->
</property>
```

## 四、Spark 的本地性等待

Spark 在 YARN 之上还有自己的等待机制：

```properties
spark.locality.wait = 3s           # 总等待时间
spark.locality.wait.node = 3s      # NODE_LOCAL 等待
spark.locality.wait.rack = 3s      # RACK_LOCAL 等待
spark.locality.wait.process = 3s   # PROCESS_LOCAL 等待（同Executor）
```

## 五、课堂练习

### 思考题：什么时候应该关闭 Delay Scheduling？

<details>
<summary>参考答案</summary>

1. **集群资源紧张**：空闲节点很少，等半天也等不到 LOCAL → 延迟启动严重
2. **数据已做 replication=3**：3 副本意味着 3 个节点都有数据，随机分配也大概率 LOCAL
3. **网络带宽充足**：万兆网（10Gbps）的 OFF_SWITCH 和 NODE_LOCAL 差距不大
4. **短任务为主**：等待 3 秒比任务本身还长

此时设置 `spark.locality.wait=0s` 或 YARN `node-locality-delay=0`
</details>

## 六、知识晶体

```
本地性: NODE_LOCAL(磁盘速度) > RACK_LOCAL(机架内) > ANY(跨机架)
YARN: Delay Scheduling — 等N次心跳后放宽级别
Spark: spark.locality.wait — 每级等待时间
经验: 万兆网+3副本 → 本地性没那么重要, 可调低等待
```

*教案作者：Eric | 最后更新：2026-04-30*
