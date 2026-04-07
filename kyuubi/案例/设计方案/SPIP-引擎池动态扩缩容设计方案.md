# SPIP: 引擎池动态扩缩容设计方案

> **类型**：Kyuubi Improvement Proposal（SPIP 级别）
> **作者**：Eric (BigData Ops Orchestrator)
> **状态**：Draft
> **方法论**：刻意练习 — 设计方案（L4 创造者级别）

---

## 1. 背景与动机

### 1.1 问题描述

当前 Kyuubi 引擎池（`ENGINE_POOL_SIZE`）是**静态配置**的。一旦设定，池大小在运行时不可更改。

**问题场景**：
- **白天高峰**：100 个用户并发查询，需要 `pool.size=5` 以获得足够并行度
- **夜间低谷**：10 个用户偶尔查询，5 个引擎大部分空闲，浪费 YARN 资源
- **突发事件**：ETL 批次到达，瞬间需要 10 个引擎，但池大小只有 5

### 1.2 目标

引入**引擎池动态扩缩容**机制：
1. 根据负载自动调整引擎池大小
2. 支持最小/最大池大小限制
3. 支持扩容预热和缩容优雅关闭
4. 不影响现有 Session

---

## 2. 方案设计

### 2.1 核心概念

```
EnginePoolManager (新增组件)
  ├── 监控指标: 活跃 Session 数 / 引擎 CPU 利用率 / 排队等待数
  ├── 扩容策略: 当排队等待 > 阈值 → 增加引擎
  ├── 缩容策略: 当引擎空闲 > 阈值 → 标记引擎为 draining → 等待 Session 清空 → 关闭
  └── 限制: minPoolSize ≤ currentSize ≤ maxPoolSize
```

### 2.2 配置设计

```properties
# 启用动态引擎池
kyuubi.engine.pool.dynamic.enabled=true

# 池大小范围
kyuubi.engine.pool.dynamic.minSize=1
kyuubi.engine.pool.dynamic.maxSize=10

# 扩容触发条件
kyuubi.engine.pool.dynamic.scaleUp.threshold=5  # 排队超过 5 个请求
kyuubi.engine.pool.dynamic.scaleUp.step=1        # 每次扩 1 个

# 缩容触发条件
kyuubi.engine.pool.dynamic.scaleDown.idleTimeout=PT10M  # 空闲 10 分钟
kyuubi.engine.pool.dynamic.scaleDown.step=1              # 每次缩 1 个

# 决策间隔
kyuubi.engine.pool.dynamic.checkInterval=PT30S
```

### 2.3 状态机

```
引擎状态:
  ACTIVE   → 正常服务
  DRAINING → 标记缩容，不接受新 Session，等待现有 Session 完成
  STOPPED  → 已停止

扩容流程:
  EnginePoolManager 检测到排队 > 阈值
    → currentSize < maxSize?
      → YES: getOrCreate(new subdomain) 启动新引擎
      → NO: 忽略（已达上限）

缩容流程:
  EnginePoolManager 检测到引擎空闲 > idleTimeout
    → currentSize > minSize?
      → YES: 标记引擎为 DRAINING
             → 从 ZK 注销（不接受新路由）
             → 等待 activeSessionCount == 0
             → engine.stop()
      → NO: 忽略（保持最小池）
```

### 2.4 与现有引擎池的兼容性

| 维度 | 静态池（现有） | 动态池（新增） |
|------|-------------|-------------|
| 池大小 | 固定 | minSize ~ maxSize |
| POLLING 策略 | `index % poolSize` | `index % currentSize` |
| 配置方式 | `pool.size=N` | `dynamic.enabled=true` |
| 向后兼容 | 不变 | `dynamic.enabled=false` 时等同静态池 |

---

## 3. 接口设计

### 3.1 新增类

```scala
class EnginePoolManager(conf: KyuubiConf, user: String) {
  private var currentSize: AtomicInteger
  private val engines: ConcurrentHashMap[String, EngineState]

  def checkAndScale(): Unit            // 定期检查，扩/缩容
  def getSubdomain(): String           // 基于 currentSize 的路由
  def markDraining(subdomain: String)  // 标记缩容
}

enum EngineState { ACTIVE, DRAINING, STOPPED }
```

### 3.2 REST API

```
GET  /api/v1/admin/engine-pools/{user}          → 查看用户的引擎池状态
POST /api/v1/admin/engine-pools/{user}/scale-up  → 手动扩容
POST /api/v1/admin/engine-pools/{user}/scale-down → 手动缩容
```

---

## 4. 测试计划

| 测试 | 验证点 |
|------|--------|
| UT: 扩容触发 | 排队数超过阈值 → currentSize 增加 |
| UT: 缩容触发 | 空闲超时 → currentSize 减少 |
| UT: 最小池保护 | currentSize 不低于 minSize |
| UT: DRAINING 状态 | 不接受新 Session，等待清空 |
| IT: 端到端 | 负载增加 → 自动扩容 → 负载降低 → 自动缩容 |
| Benchmark | 动态池 vs 静态池的资源利用率对比 |

---

## 5. 里程碑

| 阶段 | 内容 | 预计工期 |
|------|------|---------|
| Phase 1 | EnginePoolManager 核心逻辑 + UT | 2 周 |
| Phase 2 | 与 EngineRef 集成 + IT | 1 周 |
| Phase 3 | REST API + 文档 | 1 周 |
| Phase 4 | 社区 Review + 合入 | 2 周 |

---

## 6. 知识晶体

| 维度 | 内容 |
|------|------|
| **问题** | 静态引擎池无法适应负载波动 |
| **方案** | 引入 EnginePoolManager + DRAINING 状态 + 动态扩缩容 |
| **核心挑战** | 缩容时的优雅排水（不中断现有 Session） |
| **权衡** | 复杂度增加 vs 资源利用率提升 |
