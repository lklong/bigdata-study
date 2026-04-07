# PR Review 分析：EngineRef 重构 — 引擎池支持

> **方法论**：刻意练习 — PR 深度 Review（L4 创造者级别）
> **PR 背景**：引入 ENGINE_POOL_SIZE 和 ENGINE_POOL_SELECT_POLICY，支持同一 ShareLevel 下运行多个引擎实例

---

## 1. 变更概述

**目标**：在 USER/GROUP/SERVER 级别下，支持引擎池（多个引擎实例），通过 POLLING 或 RANDOM 策略分配请求。

**核心变更文件**：
- `EngineRef.scala` — 新增 subdomain 计算逻辑
- `KyuubiConf.scala` — 新增配置项
- `DiscoveryClient.scala` — 新增 `getAndIncrement` 原子计数器 API

## 2. 代码变更分析

### 2.1 EngineRef.scala — subdomain 计算

```scala
// 新增逻辑
private def getSubdomain(): Option[String] = {
  val poolSize = conf.get(ENGINE_POOL_SIZE)
  if (poolSize <= 0) return None  // 未启用引擎池
  
  val poolName = conf.get(ENGINE_POOL_NAME)
  conf.get(ENGINE_POOL_SELECT_POLICY) match {
    case POLLING =>
      val index = discoveryClient.getAndIncrement(counterPath, 1) % poolSize
      Some(s"$poolName-$index")
    case RANDOM =>
      Some(s"$poolName-${Random.nextInt(poolSize)}")
  }
}
```

**Review 意见**：

| 评价 | 说明 |
|------|------|
| ✅ 优点 | POLLING 使用 ZK 原子计数器，保证全局有序分配 |
| ✅ 优点 | RANDOM 策略简单无状态，适合池较大的场景 |
| ⚠️ 风险 | `% poolSize` 对负数返回负值（后来在 KYUUBI-5941 修复） |
| ⚠️ 风险 | 计数器持久化在 ZK，如果 ZK 数据丢失，计数器重置可能导致分配不均 |
| 🔧 建议 | 应使用 `Math.floorMod` 替代 `%` 防止溢出 |

### 2.2 DiscoveryClient — 原子计数器

```scala
// 新增 API
def getAndIncrement(path: String, delta: Int = 1): Int
```

**底层实现**：ZK `SharedCount`（Curator Recipes），基于 ZK 的版本号实现 CAS 原子操作。

**Review 意见**：
- ✅ 使用 Curator 成熟库，而非手动 CAS
- ⚠️ 高并发下 CAS 重试可能增加 ZK 压力

### 2.3 配置设计

```scala
val ENGINE_POOL_SIZE = buildConf("kyuubi.engine.pool.size")
  .intConf.checkValue(_ >= -1, "Must be >= -1")
  .createWithDefault(-1)  // 默认禁用

val ENGINE_POOL_SELECT_POLICY = buildConf("kyuubi.engine.pool.selectPolicy")
  .stringConf.checkValue(Set("POLLING", "RANDOM").contains, "...")
  .createWithDefault("POLLING")
```

**Review 意见**：
- ✅ 默认禁用（-1），向后兼容
- ✅ 策略枚举化，类型安全
- 🔧 建议：增加 `LEAST_CONNECTIONS` 策略（基于活跃 Session 数的路由）

## 3. 设计权衡分析

| 决策 | 选择 | 替代方案 | 理由 |
|------|------|---------|------|
| 计数器存储 | ZK SharedCount | Redis/DB | 复用 ZK，不引入新依赖 |
| 默认策略 | POLLING | RANDOM | POLLING 更均匀（确定性） |
| 池大小配置 | 静态 | 动态 | 简单优先，动态后续迭代 |

## 4. 改进建议

1. **Math.floorMod** 替代 `%`（已在 KYUUBI-5941 实现）
2. **健康感知路由**：如果某个池实例挂掉，POLLING 跳过该实例
3. **动态池大小**：根据负载自动扩缩容（参见 SPIP 设计方案）

## 5. 知识晶体

| 维度 | 内容 |
|------|------|
| **PR 核心** | 引入引擎池，通过 subdomain 将一个 ShareLevel 拆分为多个引擎槽 |
| **关键设计** | ZK 原子计数器保证全局 POLLING 有序 |
| **隐患** | 计数器溢出（已修复）、无健康感知路由 |
| **学到的** | PR Review 不仅看"是否正确"，还要看"长期运行是否安全"（溢出、泄漏、一致性） |
