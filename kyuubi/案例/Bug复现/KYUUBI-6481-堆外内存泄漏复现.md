# KYUUBI-6481: Driver 堆外内存泄漏复现

> **JIRA**：KYUUBI-6481
> **严重级别**：Major
> **影响版本**：1.6.0 ~ 1.9.x
> **方法论**：刻意练习 — Bug 复现 + 根因定位 + 修复方案

---

## 1. 问题描述

**现象**：USER 级别共享引擎运行数小时后，YARN 报告 Container 内存超限被 Kill。

```
Container [pid=xxx,containerID=container_xxx] is running beyond physical memory limits.
Current usage: 5.5 GB of 5 GB physical memory used.
Killing container.
```

但 JVM 堆内存只用了 2.8G（Driver 配置 `spark.driver.memory=4g`），额外的 2.7G 来自**堆外内存**。

## 2. 根因定位

### 2.1 Kyuubi 引擎的堆外内存组成

```
堆外内存来源:
  ├── Thrift Server (Netty NIO buffers)     ~200-500MB
  ├── ZK Curator Client                      ~50-100MB
  ├── Session/Operation 管理对象             ~100-300MB
  ├── Spark 内部 DirectByteBuffer            ~200-500MB
  │     (shuffle, broadcast, network)
  ├── JVM Metaspace (类元数据)               ~200-400MB
  └── JNI / Native Memory                    ~100-200MB

总计估算: ~850MB - 2000MB
```

### 2.2 SparkProcessBuilder 分析

**源码位置**：`SparkProcessBuilder.scala`

```scala
// SparkProcessBuilder 的配置透传逻辑
// 它只是一个配置透传器，不会显式设置 memoryOverhead
def convertConfigKey(key: String): String = key match {
  case k if k.startsWith("spark.")  => k
  case k if k.startsWith("hadoop.") => s"spark.hadoop.$k"
  case k => s"spark.$k"
}
```

**关键发现**：SparkProcessBuilder **没有**为 Kyuubi 引擎显式设置 `spark.driver.memoryOverhead`。

Spark 的默认计算：
```
memoryOverhead = max(driverMemory * 0.1, 384MB)
对于 driverMemory=4g: memoryOverhead = max(4096 * 0.1, 384) = 409MB
```

但 Kyuubi 引擎的实际堆外需求 ~1-2GB，**远超默认的 409MB**。

### 2.3 累积效应

USER 级别下，引擎长期运行（小时-天级），每个新 Session 创建：
- 新的 `SparkSession.newSession()` → 新的 SessionState → Metaspace 增长
- 新的临时视图/UDF 注册 → native memory 增长
- 未关闭的 Thrift 连接 → Netty buffer 累积

## 3. 解决方案

```properties
# 生产必配（P0）
spark.driver.memoryOverhead=1g

# Spark 4.0+ 推荐
spark.driver.minMemoryOverhead=1g

# 辅助措施：减少堆外内存消耗
spark.network.io.preferDirectBufs=false
spark.shuffle.io.preferDirectBufs=false

# 辅助措施：限制引擎生命周期（防止累积）
kyuubi.session.engine.spark.max.lifetime=PT4H
```

## 4. 复现步骤

```bash
# 1. 启动 Kyuubi，不配置 memoryOverhead（使用默认值）
# spark.driver.memory=4g
# spark.driver.memoryOverhead=<不配置，默认 409MB>

# 2. 持续创建 Session 并执行查询
for i in $(seq 1 100); do
  beeline -u "jdbc:hive2://host:10009/" \
    -e "SELECT count(*) FROM db.large_table" &
  sleep 10
done

# 3. 监控 YARN Container 内存
yarn application -status <app_id> | grep "Memory Used"

# 4. 预期：数小时后 Container 被 Kill
```

## 5. 知识晶体

| 维度 | 内容 |
|------|------|
| **问题** | Kyuubi Engine Driver 堆外内存超出 YARN Container 限制 |
| **根因** | SparkProcessBuilder 不设 memoryOverhead + Kyuubi 堆外开销远高于原生 Spark |
| **源码** | `SparkProcessBuilder.scala` — 配置透传，不显式设置 overhead |
| **修复** | 显式配置 `spark.driver.memoryOverhead=1g` |
| **教训** | Kyuubi 引擎 ≠ 原生 spark-sql，堆外内存基础开销增加 ~1GB |
