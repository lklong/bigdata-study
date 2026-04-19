# Tez 分片 availableSlots 瞬时快照问题 — 源码级解法

---

## 一、问题本质（源码定位）

```java
// HiveSplitGenerator.java（Hive 3.1.3）第186-189行
if (getContext() != null) {
    totalResource = getContext().getTotalAvailableResource().getMemory();
    taskResource = getContext().getVertexTaskResource().getMemory();
    availableSlots = totalResource / taskResource;
}
```

`getTotalAvailableResource()` 返回的是 AM 注册时 RM 通过心跳返回的 **headroom**（当前可用资源），这是一个**瞬时快照**。

### 社区已知问题

| JIRA | 标题 | 状态 |
|------|------|------|
| **[TEZ-3168](https://issues.apache.org/jira/browse/TEZ-3168)** | Provide a more predictable approach for total resource guidance for wave/split calculation | **Reopened/Unresolved**（2016 年提出，至今未合入） |
| **[HIVE-24734](https://issues.apache.org/jira/browse/HIVE-24734)** | Sanity check in HiveSplitGenerator available slot calculation | **Open/Unresolved**（2021 年提出，无 patch） |

TEZ-3168 的原话：
> "Currently, Tez uses headroom for checking total available resources. This is **flaky** as it ends up causing the split count to be determined by a **point in time lookup** at what is available in the cluster."

---

## 二、社区已有的改进（Hive master 分支）

Hive master（4.x）已经重构了 `availableSlots` 的计算方式：

```java
// HiveSplitGenerator.java（Hive master / 4.x）
// 旧代码：
//   availableSlots = totalResource / taskResource;
// 新代码：
int availableSlots = getAvailableSlotsCalculator().getAvailableSlots();

private AvailableSlotsCalculator getAvailableSlotsCalculator() throws Exception {
    Class<?> clazz = Class.forName(
        HiveConf.getVar(conf, HiveConf.ConfVars.HIVE_SPLITS_AVAILABLE_SLOTS_CALCULATOR_CLASS),
        true, Utilities.getSessionSpecifiedClassLoader());
    AvailableSlotsCalculator slotsCalculator =
        (AvailableSlotsCalculator) ReflectionUtil.newInstance(clazz, null);
    slotsCalculator.initialize(conf, this);
    return slotsCalculator;
}
```

**改为了策略模式**：通过配置项 `HIVE_SPLITS_AVAILABLE_SLOTS_CALCULATOR_CLASS` 指定计算类，可插拔。

但默认实现仍然是 headroom 模式，**本质问题没有彻底解决**。

---

## 三、源码级解法

### 方案 A：在 Hive 3.1.3 上 Patch（最小改动）

**改 `HiveSplitGenerator.java`**，在计算 `availableSlots` 后增加基于队列容量的稳定化逻辑：

```java
// ===== 原始代码（第186-189行）=====
if (getContext() != null) {
    totalResource = getContext().getTotalAvailableResource().getMemory();
    taskResource = getContext().getVertexTaskResource().getMemory();
    availableSlots = totalResource / taskResource;
}

// ===== Patch: 增加以下代码 =====

// 1. 读取用户配置的固定 slots 数（新增配置项）
int configuredSlots = conf.getInt(
    "hive.tez.split.available.slots.override", -1);
if (configuredSlots > 0) {
    LOG.info("Using configured availableSlots override: " + configuredSlots
        + " (original headroom-based: " + availableSlots + ")");
    availableSlots = configuredSlots;
}

// 2. 如果未配置 override，使用队列容量代替 headroom（更稳定）
if (configuredSlots <= 0) {
    int queueBasedSlots = conf.getInt(
        "hive.tez.split.queue.slots", -1);
    if (queueBasedSlots > 0) {
        LOG.info("Using queue-based availableSlots: " + queueBasedSlots
            + " (original headroom-based: " + availableSlots + ")");
        availableSlots = queueBasedSlots;
    }
}

// 3. 兜底：确保 availableSlots >= 1
if (availableSlots < 1) {
    LOG.warn("availableSlots=" + availableSlots + " is invalid"
        + " (totalResource=" + totalResource + ", taskResource=" + taskResource
        + "). Correcting to 1.");
    availableSlots = 1;
}
```

**使用方式**：
```sql
-- 在 session 或集群级别设置
SET hive.tez.split.available.slots.override=200;
-- 效果：不管队列瞬时资源多少，availableSlots 固定为 200
-- Map 数 ≈ min(200 * waves, totalLength / minGroupSize)
```

### 方案 B：在 TezSplitGrouper 层 Patch（Tez 侧）

**改 `TezSplitGrouper.java`**，在边界检查中增加对 `desiredNumSplits` 的稳定化：

```java
// ===== 原始代码（第216-270行的边界检查之前）=====
// 增加以下逻辑：

// 如果 desiredNumSplits 和原始 splits 数量差距过大，做修正
// 防止 "desiredNumSplits >= originalSplits.size()" 导致不分组
int maxDesiredRatio = conf.getInt(
    "tez.grouping.max-desired-to-original-ratio", 2);
if (desiredNumSplits > originalSplits.size() / maxDesiredRatio) {
    int cappedDesired = originalSplits.size() / maxDesiredRatio;
    LOG.info("Capping desiredNumSplits from " + desiredNumSplits
        + " to " + cappedDesired
        + " (originalSplits=" + originalSplits.size()
        + ", maxRatio=" + maxDesiredRatio + ")");
    desiredNumSplits = cappedDesired;
}
```

### 方案 C：实现自定义 AvailableSlotsCalculator（适用于 Hive 4.x）

```java
/**
 * 基于队列总容量（而非 headroom）计算 availableSlots。
 * 解决 headroom 瞬时快照导致分片不稳定的问题。
 */
public class QueueCapacityBasedSlotsCalculator implements AvailableSlotsCalculator {

    private Configuration conf;
    private InputInitializer initializer;

    @Override
    public void initialize(Configuration conf, InputInitializer initializer) {
        this.conf = conf;
        this.initializer = initializer;
    }

    @Override
    public int getAvailableSlots() {
        InputInitializerContext context = initializer.getContext();
        if (context == null) {
            return 1;
        }

        int taskResource = context.getVertexTaskResource().getMemory();
        if (taskResource <= 0) {
            throw new IllegalStateException(
                "Invalid taskResource: " + taskResource);
        }

        // 方式1：使用配置的固定值
        int configuredSlots = conf.getInt(
            "hive.tez.split.available.slots.fixed", -1);
        if (configuredSlots > 0) {
            return configuredSlots;
        }

        // 方式2：使用队列最大容量（通过 YARN API 获取）
        // 需要额外实现 YarnClient 调用获取队列信息
        // 参见 TEZ-3168 的 patch 实现
        int queueMaxMB = conf.getInt(
            "hive.tez.split.queue.max.memory.mb", -1);
        if (queueMaxMB > 0) {
            int slots = queueMaxMB / taskResource;
            LOG.info("Queue-based availableSlots: " + slots
                + " (queueMaxMB=" + queueMaxMB
                + ", taskResource=" + taskResource + ")");
            return Math.max(1, slots);
        }

        // 方式3：fallback 到 headroom（原始行为）
        int totalResource = context.getTotalAvailableResource().getMemory();
        int slots = totalResource / taskResource;
        return Math.max(1, slots);
    }
}
```

**配置使用**：
```xml
<property>
  <name>hive.splits.available.slots.calculator.class</name>
  <value>com.yourcompany.QueueCapacityBasedSlotsCalculator</value>
</property>
<property>
  <name>hive.tez.split.queue.max.memory.mb</name>
  <value>819200</value>  <!-- 队列最大容量 800GB -->
</property>
```

### 方案 D：TEZ-3168 的方案（Tez 框架层）

TEZ-3168 提出了三种资源报告模式，通过配置切换：

```xml
<!-- tez-site.xml -->
<property>
  <name>tez.am.total.resource.calculator</name>
  <value>queue</value>
  <!-- 可选值: headroom(默认) / queue / cluster -->
</property>
```

| 模式 | 来源 | 稳定性 | 风险 |
|------|------|--------|------|
| **headroom** | RM 心跳返回的当前可用资源 | 不稳定，瞬时波动大 | 分片结果不一致 |
| **queue** | 队列总配置容量 | 稳定 | 可能高估（用户限制、Node Labels） |
| **cluster** | 集群总资源 | 最稳定 | 严重高估（多租户场景） |

**但 TEZ-3168 的 patch 至今未合入**（2016 年提出，WIP 状态），主要争议：
- Jason Lowe 指出 queue 模式在用户限制、队列迁移、Node Labels 场景下不准确
- Bikas Saha 认为 cluster 模式更合理（数据分布在整个集群）
- 测试未通过，HA 场景未处理

---

## 四、推荐方案（按场景）

| 场景 | 推荐方案 | 改动量 |
|------|---------|--------|
| **不改源码，立即生效** | 用 `tez.grouping.max-size` + `min-size` 夹逼 | 0（纯配置） |
| **小改 Hive 源码** | 方案 A：增加 `hive.tez.split.available.slots.override` 配置项 | ~20 行 |
| **改 Tez 源码** | 方案 B：在 TezSplitGrouper 中 cap desiredNumSplits | ~10 行 |
| **升级到 Hive 4.x** | 方案 C：实现自定义 AvailableSlotsCalculator | ~50 行 |
| **改 Tez 框架** | 方案 D：合入 TEZ-3168 的 queue/cluster 模式 | ~500 行（复杂） |

### 对于大哥当前的 Hive 3.1.3 + Tez 0.10.2 环境

**最实际的源码改法是方案 A**：在 `HiveSplitGenerator.java` 第 189 行之后加一个 override 配置项，改动最小、风险最低、效果明确。编译后替换 `hive-exec-3.1.3.jar` 即可。

---

> **分析者**：Eric (BigData SRE AI Expert Team)  
> **日期**：2026-04-18  
> **参考**：TEZ-3168, HIVE-24734, Hive 3.1.3 源码, Hive master 分支源码
