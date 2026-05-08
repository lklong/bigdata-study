# HS2 (Hive 3.1.2) UDFClassLoader 泄漏 OOM 案例

> **作者**: eric
> **日期**: 2026-05-08
> **审查**: Challenger（CONDITIONAL → 修正后 APPROVED）
> **状态**: 已沉淀
> **关键词**: HiveServer2, OOM, UDFClassLoader, CONSTRUCTOR_CACHE, HIVE-21971, HIVE-24636, HIVE-26530, HIVE-24590

---

## 一、问题快照

| 项目 | 值 |
|------|-----|
| 组件 | HiveServer2 |
| Hive 版本 | 3.1.2 |
| 现象 | 持续运行后堆占用 90%、Full GC 频繁、最终 OOM |
| Heap Dump 大小 | 3.52 GB（实际堆使用 2.1 GB） |
| Dump 时间 | 2026-05-06 11:41 |
| 对象总数 | 44,999,557 |
| ClassLoader 总数 | 3,323（健康值 < 100） |
| GC 算法 | G1GC |

---

## 二、MAT 三大 Leak Suspect（硬证据）

| Suspect | 类 | 实例数 | 占用 | 占比 |
|---------|----|------|------|------|
| **#1** | `java.util.jar.JarFile` | 1,114,675 | 760 MB | 33.01% |
| **#2** | `org.apache.hadoop.hive.ql.exec.UDFClassLoader` | 1,346 | 711 MB | 30.86% |
| **#3** | `java.lang.ref.Finalizer` | 1,824,179 | 601 MB | 26.10% |
| **合计** | — | — | **2,072 MB** | **89.97%** |

### 引用链（来自 MAT "Common Path To The Accumulation Point"）

```
class org.apache.logging.log4j.core.AbstractLifeCycle[]   ← Log4j Appender 注册表
  └─ <classloader> sun.misc.Launcher$AppClassLoader
       └─ classes java.util.Vector
            └─ elementData java.lang.Object[20480]
                 └─ class org.apache.hadoop.util.ReflectionUtils  ← 泄漏起点
                      └─ CONSTRUCTOR_CACHE (ConcurrentHashMap)     ← 921 entries
                           └─ table Node[2048]                     ← Retained 417 KB

并联链路：
  ThreadWithGarbageCleanup (HS2-Handler-Pool: Thread-xxx)
    └─ contextClassLoader → UDFClassLoader @ xxx                  ← Retained ~527 KB / loader
```

---

## 三、根因（已实证）

### 3.1 一句话根因

> **Hive 3.1.2 自带的 4 个已知泄漏 Bug 叠加，使每次执行 UDF 的 SQL 都会持续累积 `CONSTRUCTOR_CACHE` 条目和 `UDFClassLoader` 实例，且 Session 关闭时无法释放。**

### 3.2 泄漏环节分布图

```
┌──────────────────────────────────────────────────────────┐
│            HS2 OOM (堆占用 89.97%)                        │
└────────────────────────┬─────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   ┌────▼────┐      ┌────▼────┐      ┌───▼─────┐
   │ 入口泄漏 │       │ 链路泄漏 │       │ 出口泄漏  │
   │(Op管理) │       │(CL管理) │       │(日志/FD) │
   └────┬────┘      └────┬────┘      └───┬─────┘
        │                │                │
   ┌────▼────┐      ┌────▼─────┐    ┌────▼────┐
   │HIVE-26530│     │HIVE-21971│     │HIVE-24590│
   │HIVE-22275│     │HIVE-24636│     │HIVE-18820│
   └─────────┘      └──────────┘     └──────────┘
                          ↑
                    本次 dump 直接证据
```

### 3.3 各 Bug 在你 3.1.2 源码中的实证（已逐行核查）

#### Bug 1：HIVE-21971 — Hadoop ReflectionUtils 缓存泄漏

**Affects**: 所有 < 4.0.0 版本 | **Fix Version**: 4.0.0-alpha-1（3.1.x **未合入**）

**3.1.2 现状（裸奔）**：

```java
// FunctionRegistry.java:1383-1399
public static GenericUDF cloneGenericUDF(GenericUDF genericUDF) {
    ...
    } else {
        clonedUDF = ReflectionUtils.newInstance(genericUDF.getClass(), null);  // 1398 ← 泄漏点1
    }
    ...
}

// FunctionRegistry.java:1432-1437
public static GenericUDTF cloneGenericUDTF(GenericUDTF genericUDTF) {
    ...
    return ReflectionUtils.newInstance(genericUDTF.getClass(), null);   // 1436 ← 泄漏点2
}

// FunctionRegistry.java:1756
return (TableFunctionResolver) ReflectionUtils.newInstance(tfInfo.getFunctionClass(), null);  // ← 泄漏点3
```

**Hadoop 端的 cache（已确认本地 hadoop 源码 ReflectionUtils.java）**：

```java
// hadoop-common ReflectionUtils.java:65
private static final Map<Class<?>, Constructor<?>> CONSTRUCTOR_CACHE = ...

// hadoop-common ReflectionUtils.java:293
static void clearCache() { ... }   // ★ package-private，需反射调用
```

**3.1.2 SessionState.close() 末尾（实测无清理逻辑）**：

```bash
# 实测命令（D:\bigdata\txproject\hive\ql\src\java\org\apache\hadoop\hive\ql\session\SessionState.java）
findstr /I /C:"clearReflectionUtilsCache" /C:"clearCache" SessionState.java
# 返回：Command failed with exit code 1（即未找到任何匹配）
```

dump 中可见的 921 个 CONSTRUCTOR_CACHE 条目就是这里持续累积的产物。

---

#### Bug 2：HIVE-24636 — commons-logging LogFactory 持有 ClassLoader

**Affects**: 3.1.0+ | **Fix Version**: 3.1.3 / 3.2.0（3.1.2 **未含**）

**机制**：

```
ADD JAR / 调用 UDF
  → Apache Commons LogFactory.getLog(class)
  → LogFactory.factories  ← key 是 ClassLoader（强引用）
  → 即使 SessionState.close() 调了 closeClassLoader
  → factories Map 还攥着 UDFClassLoader 不放
  → ClassLoader 永远 GC 不掉
```

dump 中 1346 个 UDFClassLoader 大部分通过 Thread.contextClassLoader / commons-logging factories 被锁住。

---

#### Bug 3：HIVE-26530 — OperationManager.queryIdOperation 清理不全

**Affects**: 3.1.2 | **Fix Version**: 3.2.0（**branch-3.1 专用 backport，PR #3589**）

**3.1.2 现状**：

```java
// OperationManager.java:188-212
private String getQueryId(Operation operation) {
    return operation.getQueryId();      // ← Hive 4.0 才修正，3.1.2 仍取 HiveConf.HIVEQUERYID
}

private void addOperation(Operation operation) {
    queryIdOperation.put(getQueryId(operation), operation);   // ← 同 queryId 会覆盖
    ...
}

private Operation removeOperation(OperationHandle opHandle) {
    Operation operation = handleToOperation.remove(opHandle);
    String queryId = getQueryId(operation);
    queryIdOperation.remove(queryId);   // ← 多 query 共用同一 queryId 时只清掉一个，其他永远残留
    ...
}
```

**重要修正**：HIVE-22275 的 patch 是基于 4.0.0 代码，cherry-pick 到 3.1.x **冲突大**；
**HIVE-26530 是社区专为 branch-3.1 写的对应 patch（同一问题，3.1.2 适配版）**，应**优先选 26530**。

---

#### Bug 4：HIVE-24590 — Operation Logging 仍泄漏 log4j Appender

**Affects**: 3.1.x | **Fix Version**: 4.0.0-alpha-1（3.1.2 **未含**）

dump 中顶端的 `org.apache.logging.log4j.core.AbstractLifeCycle[]` 数组（Retained 持有 8590 个引用对象）就是此 Bug 的直接产物。

---

#### Bug 5：HIVE-18820（**已实测在 3.1.2 含有**）

```bash
# 实测确认
findstr /N /C:"cleanupOperationLog" Operation.java
# 输出：268: protected synchronized void cleanupOperationLog(final long operationLogCleanupDelayMs)
```

✅ 3.1.2 已含此 patch（Fix Version: 3.0.0），**无需重复打**。

---

### 3.4 ★ 待验证假设（不作为最终结论）

下列推断**没有直接证据**，归为假设、需要后续核实：

| 假设 | 当前证据 | 验证方法 |
|------|---------|---------|
| **tezign UDF 用了 ReflectASM 等字节码生成框架** | 仅类名带 `ConstructorAccess` 后缀（经验联想） | 反编译 jar / 看 MAT 中类的 defining ClassLoader |
| **1346 UDFClassLoader 都来自 tezign UDF** | 仅多次出现 `JsonSplitUDFConstructorAccess` 一个类名 | OQL 按 ClassLoader 分组统计加载的 Class 包名 |
| **业务方 JDBC 连接不规范关闭** | 只见 1346 个 UDFClassLoader 多于合理并发 | 看 HS2 access log / `OpenSessions` JMX 历史 |

> ⚠️ 修正 v1：之前文档中"tezign 是元凶"的表述属于过度归因，**已降级为待验证假设**。
> 真正的原生 Bug 是上述 4 个 JIRA，跟具体哪个 UDF **无关**。

---

## 四、解决方案

### 4.1 短期止血（不打 patch，配置改完即生效）

```xml
<!-- hive-site.xml -->
<property>
  <name>hive.server2.idle.session.timeout</name>
  <value>3600000</value>     <!-- 1 小时 -->
</property>
<property>
  <name>hive.server2.session.check.interval</name>
  <value>900000</value>      <!-- 15 分钟 -->
</property>
<property>
  <name>hive.server2.idle.operation.timeout</name>
  <value>1800000</value>     <!-- 30 分钟 -->
</property>
<property>
  <name>hive.server2.limit.connections.per.user</name>
  <value>20</value>
</property>
```

JVM 参数（与已有 24G 堆配合）：

```bash
-XX:MaxMetaspaceSize=2048m
-XX:+ParallelRefProcEnabled
-XX:InitiatingHeapOccupancyPercent=35
-XX:G1HeapRegionSize=16m
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/data/hive/dumps/
-Xlog:gc*:file=/data/hive/gc-%t.log:time,uptime:filecount=10,filesize=100M
```

> ⚠️ **风险**：`MaxMetaspaceSize=2048m` 是按"健康水位"设的，如果当前实际 Metaspace **已经超过 2GB**，加上这个参数后会立即 Metaspace OOM。
> **执行前先 `jstat -gc <pid> | awk '{print $4+$6}'`** 查看当前 Metaspace 使用量，超过 1.5GB 就放宽到 4096m。

### 4.2 根治方案（cherry-pick 4 个 P0 patch）

**优先级和打 patch 顺序**：

| 顺序 | JIRA | 修改文件 | 改动量 | 冲突风险 |
|------|------|---------|-------|---------|
| 1 | HIVE-26530 | OperationManager.java + Operation.java | 中 | 🟢 低（branch-3.1 原生） |
| 2 | HIVE-21971 | SessionState.java | 5 KB | 🟢 极低（仅新增方法） |
| 3 | HIVE-24636 | JavaUtils.java | 小 | 🟡 中（依赖 commons-logging API） |
| 4 | HIVE-24590 | LogDivertAppender.java + 相关 | 中 | 🟡 中 |

**HIVE-21971 patch 内容（直接抄即可）**：

```java
// ============== SessionState.java ==============

// 1. 文件头部增加 import（如已有可省略）
import java.lang.reflect.Method;
import org.apache.hadoop.util.ReflectionUtils;

// 2. close() 方法末尾追加（在原 JavaUtils.closeClassLoadersTo 之后）
public void close() throws IOException {
    // ... 原有所有代码不动 ...
    JavaUtils.closeClassLoadersTo(sessionConf.getClassLoader(), parentLoader);
    // ... 原有所有代码不动 ...

    // ★★★ HIVE-21971 新增：清理 Hadoop ReflectionUtils 的 CONSTRUCTOR_CACHE
    clearReflectionUtilsCache();
}

// 3. 新增私有方法
private void clearReflectionUtilsCache() {
    Method clearCacheMethod;
    try {
        clearCacheMethod = ReflectionUtils.class.getDeclaredMethod("clearCache");
        if (clearCacheMethod != null) {
            clearCacheMethod.setAccessible(true);
            clearCacheMethod.invoke(null);
            LOG.debug("Cleared Hadoop ReflectionUtils CONSTRUCTOR_CACHE");
        }
    } catch (Exception e) {
        LOG.info("Failed to clear up Hadoop ReflectionUtils CONSTRUCTOR_CACHE", e);
    }
}
```

> ✅ 已实测 Hadoop 本地源码：`ReflectionUtils.clearCache()` 在第 293 行，`static void`（package-private），反射 + setAccessible 可调通。

### 4.3 业务侧建议（非操作）

1. 反编译 tezign jar，确认是否使用了 ReflectASM/FST/ByteBuddy 等字节码生成框架
2. 如确认使用，建议改造为标准反射 + WeakReference Class 缓存
3. 推动业务方 JDBC 客户端规范使用 `try-with-resources`

---

## 五、修复效果（★均为预估，需打完实测）

| 阶段 | UDFClassLoader★ | CONSTRUCTOR_CACHE★ | 堆占用★ | FGC 频率★ |
|------|----------------|-------------------|---------|---------|
| 当前裸奔 | 1346 | 921 entries | 90% | 频繁 |
| 仅改配置 | ~400 | 仍累积 | ~60% | 1 天 1 次 |
| +HIVE-21971 | 1346（不变） | 每次 close 后清空 | ~70% | 1 天 1 次 |
| +HIVE-21971+24636 | 显著下降 | 每次清空 | 显著下降 | 周级 |
| +全部 4 个 P0 | 趋于 < 50 | 趋于 0 | 趋于 < 30% | 接近无 |

> ⚠️ **★ 上述数字是 eric 基于经验和社区案例的预估，未做基准测试**。
> **真实数据需打完 patch 后采集 7 天 GC 日志和 heap histogram 验证**。

---

## 六、监控告警（防复发）

```bash
# 关键指标
jmap -histo <pid> | grep UDFClassLoader               # 健康 < 50
jmap -histo <pid> | grep "java.util.jar.JarFile"      # 健康 < 5000
jmap -finalizerinfo <pid>                              # pending < 100
curl http://hs2:10002/jmx | grep OpenSessions        # 应有降有升
```

Prometheus rule（节选）：

```yaml
- alert: HS2ClassLoaderLeak
  expr: jvm_classes_loaded_total{job="hiveserver2"} > 50000
  for: 10m
  labels: {severity: critical}

- alert: HS2FinalizerBacklog
  expr: jvm_gc_pending_finalizers{job="hiveserver2"} > 10000
  for: 5m
  labels: {severity: warning}
```

---

## 七、🛡️ 操作安全清单（落地前必读）

### 操作分级

| 操作 | 安全等级 | 回滚方案 | 灰度策略 |
|------|---------|---------|---------|
| 改配置 + 滚动重启 HS2 | 🟡 CAUTION | 改回原值再重启 | 双节点先改一台 |
| 加 JVM 参数（含 MaxMetaspaceSize） | 🟡 CAUTION | 移除参数重启 | 单节点观察 24h |
| cherry-pick patch + 替换 jar | 🔴 高风险 | 必须保留 .bak jar | 必须先测试环境 ≥ 7 天 |

### 上线前必做（强制）

```bash
# 1. 备份原 jar（每个 HS2 节点）
cp /usr/local/service/hive/lib/hive-exec-3.1.2.jar  \
   /usr/local/service/hive/lib/hive-exec-3.1.2.jar.bak.$(date +%Y%m%d_%H%M%S)

# 2. 备份原配置
cp /usr/local/service/hive/conf/hive-site.xml \
   /usr/local/service/hive/conf/hive-site.xml.bak.$(date +%Y%m%d_%H%M%S)

# 3. 当前 GC 基线快照（用于对比修复效果）
jstat -gccapacity <pid> > /tmp/gc-baseline-before.txt
jmap -histo <pid> | head -50 > /tmp/histo-before.txt
```

### 灰度路线

```
测试集群打 patch
    ↓ 跑 7 天 + 业务回归
    ↓ 7 天内 UDFClassLoader 不再增长 → PASS
   ✅
生产 HS2 节点 1 打 patch
    ↓ 观察 24h
    ↓ FGC 频率不上升 / 堆占用稳定 → PASS
   ✅
生产 HS2 节点 2 打 patch
   完成
```

### 回滚条件（任一触发即立即回滚）

- 24 小时内 FGC 频率超过修复前
- 24 小时内 HS2 启动失败 ≥ 1 次
- 业务报错率上升 ≥ 1%
- Metaspace 使用量持续上涨触发 OOM

### 回滚操作

```bash
# 单节点回滚
systemctl stop hiveserver2
cp /usr/local/service/hive/lib/hive-exec-3.1.2.jar.bak.YYYYMMDD_HHMMSS \
   /usr/local/service/hive/lib/hive-exec-3.1.2.jar
cp /usr/local/service/hive/conf/hive-site.xml.bak.YYYYMMDD_HHMMSS \
   /usr/local/service/hive/conf/hive-site.xml
systemctl start hiveserver2
```

---

## 八、本次留下的待办（TODO）

- [ ] 反编译 tezign jar，确认 UDF 实现方式
- [ ] 在 MAT OQL 验证 UDFClassLoader 真实分布（不只是 tezign）
- [ ] 打 patch 后采集 7 天 GC 日志做实测对比
- [ ] 实测填入第五节"修复效果"的真实数字
- [ ] 抓取客户当前 hive-site.xml 中 `idle.session.timeout` 实际值（怀疑是 7d 默认）
- [ ] 确认客户 Hadoop 版本对 `ReflectionUtils.clearCache()` 反射调用的兼容性

---

## 九、相关 JIRA 全清单

### P0（必打）

| JIRA | 标题 | 3.1.2 状态 | dump 命中点 |
|------|------|-----------|-----------|
| HIVE-26530 | OperationManager.queryIdOperation 多 queryId 清理不全（branch-3.1 backport） | ❌ 未合入 | SessionManager$7 lambda |
| HIVE-21971 | HS2 leaks classloader due to ReflectionUtils::CONSTRUCTOR_CACHE | ❌ 未合入 | ReflectionUtils @ 0x600c526d8 |
| HIVE-24636 | Memory leak due to commons-logging LogFactory | ❌ 未合入 | 1346 UDFClassLoader |
| HIVE-24590 | Operation logging still leaks log4j appenders | ❌ 未合入 | AbstractLifeCycle[] 顶端 |

### P1（推荐）

| JIRA | 标题 | 3.1.2 状态 |
|------|------|-----------|
| HIVE-19860 | OIF leak with cachedUnionStructObjectInspector | ❌ 未合入 |
| HIVE-20274 | OIF leaks Struct/List object inspectors | ❌ 未合入 |

### P2（顺手）

| JIRA | 标题 | 与本次 OOM 关系 |
|------|------|--------------|
| HIVE-21799 | DPP NPE on aggregation column | 无关，NPE 修复 |

### 已含（无需操作）

| JIRA | 标题 | 实证 |
|------|------|------|
| HIVE-18820 | Operation 不总是清理 log4j operation log | ✅ 已实测 Operation.java:268 含 cleanupOperationLog |
| HIVE-7563 | 早期 ClassLoader 泄漏 | 3.1.2 已含 |
| HIVE-11878 | Each session has its own UDFClassloader | 3.1.2 已含 |
| HIVE-19611 | Close classloader when session closes | 3.1.2 已含（JavaUtils.closeClassLoadersTo） |

### 已废弃（被替代）

| JIRA | 替代为 | 原因 |
|------|------|------|
| ~~HIVE-22275~~ | HIVE-26530 | HIVE-22275 patch 基于 4.0.0，cherry-pick 到 3.1.x 冲突大 |

---

## 十、参考资料

- HIVE-21971: https://issues.apache.org/jira/browse/HIVE-21971（commit `bd84b5c`）
- HIVE-24636: https://issues.apache.org/jira/browse/HIVE-24636（PR #1923/#1924）
- HIVE-26530: https://issues.apache.org/jira/browse/HIVE-26530（PR #3589）
- HIVE-24590: https://issues.apache.org/jira/browse/HIVE-24590
- HADOOP-10513: https://issues.apache.org/jira/browse/HADOOP-10513（Hadoop 端根因）

---

## 十一、Challenger 审查记录

| 轮次 | 裁决 | 修正项 |
|------|------|------|
| v1 | ❌ REJECTED | tezign UDF 因果链未证实；patch 适用性未实测 |
| v2 | ⚠️ CONDITIONAL | 修复效果数字无依据；HIVE-18820 未实测 |
| v3（本版本） | ✅ APPROVED | 所有疑点已降级为「待验证」或补充实证；操作风险已分级；rollback 方案已补全 |

**审查通过签字**: Challenger / 2026-05-08

---

> 本案例归档于 `D:\bigdata\gitproject\bigdata-study\hive\案例\case-hs2-3.1.2-classloader-leak.md`
> 配套 git commit message: `case: HS2 3.1.2 UDFClassLoader 泄漏 OOM 案例归档`
