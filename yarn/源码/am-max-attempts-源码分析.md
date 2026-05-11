# YARN AM Max Attempts 源码分析（Flink on YARN 场景）

> **目的**：彻底厘清 `yarn.application-attempts` 和 `yarn.resourcemanager.am.max-attempts` 这两个参数在 Flink on YARN 作业中的真实行为，避免因经验推断导致误判。
>
> **证据基准**：
> - Flink 源码：`D:\bigdata\gitproject\flink`（`release-1.13` 分支）
> - Hadoop 源码：`D:\bigdata\txproject\hadoop`（`emr-3.2.2` 分支）
>
> **作者**：eric ｜ **日期**：2026-05-11

---

## 1. 问题背景

在生产排障中看到某个 Flink 1.13.1 作业的配置包含：

```properties
yarn.application-attempts                = 0
yarn.resourcemanager.am.max-attempts     = 0
```

经验上容易得出"HA 完全失效"的结论。本文通过源码证伪此结论，给出正确的判定方法。

---

## 2. Flink 客户端侧行为

### 2.1 `YarnClusterDescriptor.java`

文件：`flink-yarn/src/main/java/org/apache/flink/yarn/YarnClusterDescriptor.java`

```java
// 位于 deployInternal() 方法，第 816-828 行
if (HighAvailabilityMode.isHighAvailabilityModeActivated(configuration)) {
    // activate re-execution of failed applications
    appContext.setMaxAppAttempts(
            configuration.getInteger(
                    YarnConfigOptions.APPLICATION_ATTEMPTS.key(),
                    YarnConfiguration.DEFAULT_RM_AM_MAX_ATTEMPTS));  // 2

    activateHighAvailabilitySupport(appContext);
} else {
    // set number of application retries to 1 in the default case
    appContext.setMaxAppAttempts(
            configuration.getInteger(YarnConfigOptions.APPLICATION_ATTEMPTS.key(), 1));
}
```

**关键点**：

1. Flink 只读取 `yarn.application-attempts`（Flink Configuration 里的 key）
2. **`yarn.resourcemanager.am.max-attempts` Flink 不读**，在 Flink 侧配了只是"脏数据"
3. 用户配 `application-attempts=0` → `configuration.getInteger("yarn.application-attempts", 2)` 返回 0（不是默认值 2，因为 key 有值）
4. `appContext.setMaxAppAttempts(0)` → 透传到 YARN

### 2.2 `YarnConfigOptions.APPLICATION_ATTEMPTS` 定义

文件：`flink-yarn/src/main/java/org/apache/flink/yarn/configuration/YarnConfigOptions.java`（94-108）

```java
public static final ConfigOption<String> APPLICATION_ATTEMPTS =
        key("yarn.application-attempts")
                .stringType()
                .noDefaultValue()  // 无默认值，靠代码兜底
                .withDescription(
                    "Number of ApplicationMaster restarts. By default, the value will be set to 1. "
                    + "If high availability is enabled, then the default value will be 2. "
                    + "The restart number is also limited by YARN (configured via "
                    + "yarn.resourcemanager.am.max-attempts)...");
```

**描述确认**：官方文档说默认值 "HA 开=2，HA 关=1"，源码验证了这点（代码里的两个分支）。

---

## 3. Hadoop RM 侧行为（真正的决定者）

### 3.1 `RMAppImpl.java` 构造函数

文件：`hadoop-yarn-server-resourcemanager/.../rmapp/RMAppImpl.java`（457-478）

```java
int globalMaxAppAttempts = conf.getInt(
    YarnConfiguration.GLOBAL_RM_AM_MAX_ATTEMPTS,               // "yarn.resourcemanager.am.global.max-attempts"
    conf.getInt(YarnConfiguration.RM_AM_MAX_ATTEMPTS,          // "yarn.resourcemanager.am.max-attempts"
        YarnConfiguration.DEFAULT_RM_AM_MAX_ATTEMPTS));        // 2

int rmMaxAppAttempts = conf.getInt(YarnConfiguration.RM_AM_MAX_ATTEMPTS,
    YarnConfiguration.DEFAULT_RM_AM_MAX_ATTEMPTS);             // 2

int individualMaxAppAttempts = submissionContext.getMaxAppAttempts();  // 作业侧提交的值

if (individualMaxAppAttempts <= 0) {
    this.maxAppAttempts = rmMaxAppAttempts;   // ★ 回退到 RM 侧配置
    LOG.warn("The specific max attempts: " + individualMaxAppAttempts
        + " for application: " + applicationId.getId()
        + " is invalid, because it is less than or equal to zero."
        + " Use the rm max attempts instead.");
} else if (individualMaxAppAttempts > globalMaxAppAttempts) {
    this.maxAppAttempts = globalMaxAppAttempts;
    LOG.warn("The specific max attempts: " + individualMaxAppAttempts
        + " for application: " + applicationId.getId()
        + " is invalid, because it is out of the range [1, "
        + globalMaxAppAttempts + "]. Use the global max attempts instead.");
} else {
    this.maxAppAttempts = individualMaxAppAttempts;
}
```

**三分支决策树**：

```
作业侧 individualMaxAppAttempts (submissionContext.getMaxAppAttempts())
│
├─ <= 0  → 回退到 RM 侧 rmMaxAppAttempts（yarn-site.xml 的 yarn.resourcemanager.am.max-attempts，默认 2）
│         打一条 WARN 日志
│
├─ > globalMaxAppAttempts  → 使用 globalMaxAppAttempts（yarn.resourcemanager.am.global.max-attempts）
│                            打一条 WARN 日志
│
└─ 其他  → 使用作业侧值
```

### 3.2 常量定义

文件：`hadoop-yarn-api/.../conf/YarnConfiguration.java`（508-517）

```java
// 每作业默认最大重试次数（当用户未配置时）
public static final String RM_AM_MAX_ATTEMPTS =
    RM_PREFIX + "am.max-attempts";                         // "yarn.resourcemanager.am.max-attempts"
public static final int DEFAULT_RM_AM_MAX_ATTEMPTS = 2;    // 默认 2 次

// 集群全局最大重试次数上限（硬上限）
public static final String GLOBAL_RM_AM_MAX_ATTEMPTS =
    RM_PREFIX + "am.global.max-attempts";                  // "yarn.resourcemanager.am.global.max-attempts"
```

### 3.3 AM 失败判定逻辑

文件：`RMAppImpl.java`（1544, 1563-1589）

```java
// AttemptFailedTransition.transition()
int numberOfFailure = app.getNumFailedAppAttempts();

if (app.maxAppAttempts == 1) {
    // 特殊情况：用户显式设置为 1，立即不重试
    LOG.info("Max app attempts is 1 for " + app.applicationId
        + ", preventing further attempts.");
    numberOfFailure = app.maxAppAttempts;
} else {
    // 正常统计失败次数，可能 removeExcessAttempts 清理过期失败
    if (app.attemptFailuresValidityInterval > 0) {
        removeExcessAttempts(app);
    }
}

if (!app.submissionContext.getUnmanagedAM()
    && numberOfFailure < app.maxAppAttempts) {
    // 重试：启动新 Attempt
    ...
} else {
    if (numberOfFailure >= app.maxAppAttempts) {
        // 达到上限，作业 FAILED
    }
}
```

**重试判定**：`numberOfFailure < maxAppAttempts` 才重试。

---

## 4. 真实场景推演

### 场景 A：作业侧 `application-attempts=0`，RM 侧 `am.max-attempts=10`

```
Flink:    setMaxAppAttempts(0) 透传
RM 收到:  individualMaxAppAttempts = 0
RM 分支:  <=0 → 回退到 rmMaxAppAttempts = 10
最终:     maxAppAttempts = 10  ✅ HA 正常工作
日志:     WARN "max attempts ... is invalid ... Use the rm max attempts instead"
```

### 场景 B：作业侧 `application-attempts=0`，RM 侧 `am.max-attempts=未配置`（⭐ 生产常见）

```
Flink:    setMaxAppAttempts(0) 透传
RM 收到:  individualMaxAppAttempts = 0
RM 分支:  <=0 → 回退到 rmMaxAppAttempts = DEFAULT_RM_AM_MAX_ATTEMPTS = 2
最终:     maxAppAttempts = 2  ✅ HA 可工作，但只重试 1 次
```

**⭐ 真实案例**：某 DP 平台托管的 Flink 1.13.1 数据同步作业：
- 作业侧：`application-attempts=0` + `am.max-attempts=0`（后者 Flink 不读，实际无效）
- 集群：`yarn.resourcemanager.am.global.max-attempts` 未配置
- 作业稳定运行 **30 天+**

反推：
- AM 第一次必须能启动 → `maxAppAttempts >= 1`
- 结合集群未额外配置 → `maxAppAttempts = 2`（默认值）
- HA 是工作的，但只允许 AM 失败 1 次就 FAILED，靠平台侧自愈兜底

### 场景 C：作业侧 `application-attempts=0`，RM 侧 `am.max-attempts=0`

```
Flink:    setMaxAppAttempts(0) 透传
RM 收到:  individualMaxAppAttempts = 0
RM 分支:  <=0 → 回退到 rmMaxAppAttempts = 0 (RM 侧也是 0)
最终:     maxAppAttempts = 0  🔴 AM 失败立即 FAILED（first attempt 失败就死）
```

**结论**：只有场景 C 才是真正的"HA 失效"。**光看作业侧配置判断不够，必须实测 RM 侧生效值**。

---

## 5. 正确的实测方法

### 5.1 查 RM 实际给作业分配的 maxAppAttempts

```bash
APP_ID=application_xxxxx_xxxxx
RM_HOST=<your-rm-host>

curl -s "http://$RM_HOST:8088/ws/v1/cluster/apps/$APP_ID" | \
  python -m json.tool | grep -i maxAppAttempts
```

返回示例：
```json
"maxAppAttempts": 2,
```

### 5.2 查 RM 侧 yarn-site.xml 配置

```bash
# 在 RM 节点上
grep -A1 "yarn.resourcemanager.am.max-attempts" /etc/hadoop/conf/yarn-site.xml
grep -A1 "yarn.resourcemanager.am.global.max-attempts" /etc/hadoop/conf/yarn-site.xml
```

### 5.3 查 RM 日志验证回退 WARN

```bash
grep "$APP_ID" /var/log/hadoop-yarn/yarn-*-resourcemanager-*.log | \
  grep -E "max attempts.*is invalid|Use the rm max attempts"
```

如果看到 WARN 日志，说明发生了回退（场景 A 或 B）。

---

## 6. 误区澄清

| 常见误区 | 真相 |
|---|---|
| "`application-attempts=0` 会导致 AM 不重试" | ❌ 错。RM 会回退到 `am.max-attempts`（默认 2）。只有 RM 侧也是 0 才真不重试 |
| "作业侧配 `yarn.resourcemanager.am.max-attempts` 会影响 RM 行为" | ❌ 错。这是 RM 端配置，作业侧 flink-conf 里配了也不会传给 RM |
| "Flink Web UI 看到的 YARN 参数就是生效值" | ❌ 错。Web UI 只展示 JM 启动时的 Configuration，是作业侧配置，不是 RM 实际生效值 |
| "所有 YARN 参数都能通过作业侧覆盖" | ❌ 错。RM 端参数（`yarn.resourcemanager.*`）只能在 RM 端配置 |
| "`application-attempts` 上限是无限的" | ❌ 错。会被 `am.global.max-attempts` 硬限制（见 `RMAppImpl.java:470`）|

---

## 6.5 生产设计模式：DP 平台刻意把 `application-attempts` 设为 0

一些数据平台（如 DP 平台）会**有意**在提交的作业里把 `yarn.application-attempts=0`，配合平台自愈机制形成"双层保险"：

```
作业失败
    │
    ▼
① YARN 侧 AM Retry（次数少，通常 2）
    │ ├─ 成功恢复 → 作业继续
    │ └─ 失败
    ▼
② 平台监控捕获 (作业 FAILED 状态)
    │
    ▼
③ 平台自动提交新 AppID 拉起（从最新 CK/SP 恢复）
```

**为什么设为 0 而不是 1 或 2？**

作业侧配 0 等价于"不指定"，RM 自然回退到集群默认（通常 2），效果和不配一样。**这是一种"偷懒但正确"的提交模板写法**——平台不需要关心集群配置，也不会和集群默认冲突。

**风险识别**：如果作业侧配了 `application-attempts=1` 明示"不让 YARN 重试"，那是真的禁用 YARN 侧 Retry；而配 0 是委托给集群默认。**两种情况含义完全不同**。

---

## 7. 推荐配置

### 7.1 作业侧（`flink-conf.yaml` 或 `-D` 参数）

```yaml
yarn.application-attempts: 10
yarn.application-attempt-failures-validity-interval: 600000  # 10min 滑动窗口
```

**不要在作业侧配置**：`yarn.resourcemanager.am.max-attempts`（Flink 不读，无效）

### 7.2 集群侧（`yarn-site.xml`）

```xml
<!-- 每作业默认最大重试次数（作业侧未配置时使用）-->
<property>
  <name>yarn.resourcemanager.am.max-attempts</name>
  <value>10</value>
</property>

<!-- 集群全局硬上限，保护 RM 不被作业恶意配超大值 -->
<property>
  <name>yarn.resourcemanager.am.global.max-attempts</name>
  <value>20</value>
</property>
```

---

## 8. 相关文件索引

| 文件 | 路径 | 关键行 |
|---|---|---|
| Flink 客户端逻辑 | `flink-yarn/.../YarnClusterDescriptor.java` | 816-828 |
| Flink 配置定义 | `flink-yarn/.../configuration/YarnConfigOptions.java` | 94-108 |
| Hadoop RM 逻辑 | `hadoop-yarn-server-resourcemanager/.../rmapp/RMAppImpl.java` | 457-478, 1544, 1563-1589 |
| Hadoop 常量 | `hadoop-yarn-api/.../conf/YarnConfiguration.java` | 508-517 |

---

## 9. 变更记录

| 版本 | 日期 | 作者 | 变更说明 |
|---|---|---|---|
| v1.0 | 2026-05-11 | eric | 初版，基于 Flink `release-1.13` + Hadoop `emr-3.2.2` 源码分析 |
| v1.1 | 2026-05-11 | eric | 新增 §6.5 DP 平台自愈设计模式；场景 B 补充真实 30 天稳定运行案例 |
