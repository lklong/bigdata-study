# KYUUBI-5232: SESSION 级别引擎不释放复现

> **JIRA**：KYUUBI-5232
> **严重级别**：Major
> **影响版本**：1.5.0 ~ 1.7.x
> **方法论**：刻意练习 — Bug 复现 + 根因定位 + 修复方案

---

## 1. 问题描述

**现象**：CONNECTION 级别的 Session 关闭后，对应的引擎进程没有停止，ZK 上的引擎节点残留，YARN 上的 Application 持续运行。

## 2. 根因定位

### 2.1 预期行为

CONNECTION 级别下，Session 关闭应触发引擎停止：

```
KyuubiSessionImpl.close()
  → engineRef.close()
    → 如果 shareLevel == CONNECTION → 关闭引擎
  → client.closeSession()
    → 引擎端 closeSession()
      → SparkSQLSessionManager: shareLevel == CONNECTION → stopEngine()
```

### 2.2 实际问题

当 `openEngineSession()` 阶段失败（如 Thrift 连接被拒），Session 关闭时 `_client` 为 null：

```scala
class KyuubiSessionImpl {
  @volatile private var _client: KyuubiSyncThriftClient = _  // null!

  override def close(): Unit = {
    // _client 为 null，跳过 closeSession
    Option(_client).foreach(_.closeSession())

    // engineRef.close() 尝试关闭引擎
    // 但如果引擎连接失败，engineRef 可能没有正确初始化
    if (openSessionError.isDefined) engine.close()
    // ★ 问题：openSessionError 可能为 None（重试期间状态不一致）
  }
}
```

### 2.3 竞态条件

```
Thread A: openEngineSession() 第 3 次重试中...
Thread B: Session 超时 → closeSession() 被调用
  → _client = null (还没连上)
  → openSessionError = None (还在重试中，不算"确定失败")
  → engine.close() 不被调用！
  → 引擎进程继续运行 → 成为孤儿引擎
```

## 3. 修复方案

```scala
// 修复后: close() 中无条件关闭 ENGINE_REF
override def close(): Unit = {
  super.close()
  Option(_client).foreach(_.closeSession())
  
  // ★ 修复: 对 CONNECTION 级别，无条件关闭引擎
  if (shareLevel == CONNECTION) {
    try { engine.close() }
    catch { case NonFatal(e) => warn(s"Error closing engine: $e") }
  }
}
```

## 4. 影响分析

**孤儿引擎的后果**：
- YARN 资源持续占用（Driver + Executor）
- CONNECTION 级别的 UUID 路径不会被其他 Session 复用
- 引擎 `IdleTimeout` 最终会触发自终止，但可能要等 30 分钟

**检测方法**：
```bash
# 检查 YARN 上的 Kyuubi 引擎应用
yarn application -list -appTypes SPARK | grep kyuubi

# 检查 ZK 上的引擎节点
zkCli.sh ls /kyuubi_1.8.0_CONNECTION_SPARK_SQL
```

## 5. 知识晶体

| 维度 | 内容 |
|------|------|
| **问题** | CONNECTION 级别 Session 关闭后引擎不释放 |
| **根因** | close() 中引擎关闭条件依赖 openSessionError 状态，重试期间状态不一致 |
| **源码** | `KyuubiSessionImpl.close()` — engine.close() 的条件判断 |
| **修复** | CONNECTION 级别无条件关闭引擎 |
| **教训** | 资源释放逻辑不应依赖中间状态，应使用确定性条件（如 shareLevel） |
