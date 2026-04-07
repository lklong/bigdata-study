# KYUUBI-5941: 引擎池 POLLING 计数器溢出复现

> **JIRA**：KYUUBI-5941
> **严重级别**：Critical
> **影响版本**：1.7.0 ~ 1.8.x
> **修复版本**：1.9.0
> **方法论**：刻意练习 — Bug 复现 + 根因定位 + 修复方案 + UT 设计

---

## 1. 问题描述

**现象**：生产环境运行数月后，部分用户的 Session 创建失败，错误日志显示引擎路径异常（包含负数索引）。

**报错示例**：
```
KyuubiException: Failed to open engine session:
  engineSpace = /kyuubi_1.8.0_USER_SPARK_SQL/alice/pool--2147483647
```

## 2. 根因定位

### 2.1 源码定位

**文件**：`EngineRef.scala`，引擎池子域计算逻辑：

```scala
// 旧代码（有 Bug）
val index = discoveryClient.getAndIncrement(counterPath, 1) % poolSize
subdomain = s"$poolName-$index"
```

### 2.2 根因分析

`getAndIncrement` 返回 `Int`，长期运行后超过 `Integer.MAX_VALUE`（2,147,483,647），溢出为负数。

Java 的 `%` 运算对负数返回负值：
```java
-1 % 3 = -1   // 而非 2
Integer.MIN_VALUE % 3 = -2
```

因此 `subdomain = "pool--2"` 或 `"pool--2147483647"`，这些路径在 ZK 中不会匹配任何已有引擎，导致每次都新建引擎。

### 2.3 复现步骤

```scala
// 模拟计数器溢出
val counter = Int.MaxValue  // 2147483647
val nextCounter = counter + 1  // 溢出为 Int.MinValue = -2147483648
val poolSize = 3
val index = nextCounter % poolSize  // -2147483648 % 3 = -2
println(s"pool-$index")  // "pool--2" ← 异常路径！
```

## 3. 修复方案

```scala
// 修复后代码
val index = Math.floorMod(
  discoveryClient.getAndIncrement(counterPath, 1), 
  poolSize
)
subdomain = s"$poolName-$index"
```

`Math.floorMod` 对负数返回非负值：
```java
Math.floorMod(-1, 3) = 2    // 正确
Math.floorMod(Int.MIN_VALUE, 3) = 1  // 正确
```

## 4. UT 设计

```scala
test("KYUUBI-5941: engine pool polling counter overflow") {
  val poolSize = 3

  // 正常值
  assert(Math.floorMod(0, poolSize) == 0)
  assert(Math.floorMod(1, poolSize) == 1)
  assert(Math.floorMod(2, poolSize) == 2)
  assert(Math.floorMod(3, poolSize) == 0)

  // 溢出边界
  assert(Math.floorMod(Int.MaxValue, poolSize) >= 0)
  assert(Math.floorMod(Int.MinValue, poolSize) >= 0)
  assert(Math.floorMod(-1, poolSize) == 2)
  assert(Math.floorMod(-2, poolSize) == 1)
}
```

## 5. 知识晶体

| 维度 | 内容 |
|------|------|
| **问题** | 引擎池 POLLING 计数器溢出导致异常路径 |
| **根因** | Java `%` 运算对负数返回负值 |
| **源码** | `EngineRef.scala` — `getAndIncrement() % poolSize` |
| **修复** | `Math.floorMod()` 替代 `%` |
| **教训** | 任何涉及 `Int` 计数器的代码都必须考虑溢出 |
