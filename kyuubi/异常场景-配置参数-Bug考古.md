# Apache Kyuubi 异常场景 + 配置参数体系 + JIRA Bug 考古 — L4 深度分析

> **源码版本**：Apache Kyuubi v1.8~v1.12 + master 分支（2026-04）
> **段位目标**：L4 创造者/科学家 — 对抗性阅读 + 考古学方法 + 知识晶体化
> **方法论**：源码精通九大法则 × 费曼三层输出
> **本文定位**：将运维经验与源码分析深度结合，每个异常场景追溯到源码根因 + JIRA 演化

---

## 白话版导读（费曼 L1）

> **给运维新人讲**
>
> 这份文档像一本**急诊科病例集**。每个病例（异常场景）包含：
> - **症状**（现象）：患者哪里不舒服
> - **诊断**（根因）：什么器官出了问题，追溯到哪行代码
> - **处方**（解决方案）：改什么配置、打什么补丁
> - **病理学报告**（JIRA 考古）：这个病以前有人得过吗，社区怎么治的
>
> 三类"疾病"：
> 1. **Engine 相关**：引擎启不来、内存炸了、卡死了 → 类似"心脏/发动机"问题
> 2. **Session/连接相关**：连不上、断线、超时 → 类似"血管堵塞"
> 3. **配置/安全相关**：权限不对、参数错误 → 类似"免疫系统"问题

---

## 一、异常场景研究

### 1. Engine 启动失败

#### 1.1 spark-submit 报错

**现象**：
- 客户端报错 `Session initialization timed out after 120000 ms`
- Server 日志中 `spark-submit` 返回非零退出码
- 报错 `Could not find or load main class`（本地模式下 Hive/Flink 引擎）

**根因**：
1. `SPARK_HOME` 环境变量未设置或路径错误
2. Spark 版本与 Kyuubi 编译版本不匹配（如 Kyuubi 1.8 编译了 Spark 3.4，但部署了 Spark 3.2）
3. `kyuubi-defaults.conf` 中 `spark.master=yarn` 但 `HADOOP_CONF_DIR` 未配置
4. 引擎 Jar 包缺失：`kyuubi-spark-sql-engine_*.jar` 不在 `$KYUUBI_HOME/externals/engines/spark/`

**解决方案**：
```bash
# 1. 检查环境变量
echo $SPARK_HOME $HADOOP_CONF_DIR $JAVA_HOME

# 2. 检查引擎 jar 包
ls $KYUUBI_HOME/externals/engines/spark/

# 3. 手动测试 spark-submit
$SPARK_HOME/bin/spark-submit \
  --class org.apache.kyuubi.engine.spark.SparkSQLEngine \
  --master yarn \
  --deploy-mode client \
  $KYUUBI_HOME/externals/engines/spark/kyuubi-spark-sql-engine_*.jar

# 4. 增加初始化超时时间
kyuubi.session.engine.initialize.timeout=PT5M  # 默认 PT3M
```

**涉及源码**：
- `org.apache.kyuubi.engine.spark.SparkProcessBuilder` — 构建 spark-submit 命令
- `org.apache.kyuubi.session.KyuubiSessionImpl#open` — 触发 LaunchEngine 操作
- `org.apache.kyuubi.operation.LaunchEngine` — 后台提交引擎启动任务

#### 1.2 YARN 资源不足

**现象**：
- 引擎启动超时，YARN 日志显示 Application 状态为 ACCEPTED 长时间不变
- 报错 `Application application_xxx is not running`

**根因**：
1. YARN 队列资源满，Spark Driver 容器无法被调度
2. `spark.driver.memory` + `spark.driver.memoryOverhead` 超出队列限制
3. AM 资源请求超出 `yarn.scheduler.maximum-allocation-mb`

**解决方案**：
```properties
# 1. 减小 Driver 资源需求
spark.driver.memory=2g
spark.driver.memoryOverhead=1g  # Kyuubi 引擎堆外内存基础开销约 1G！

# 2. 指定队列
spark.yarn.queue=kyuubi_pool

# 3. 增加引擎启动超时
kyuubi.session.engine.initialize.timeout=PT10M

# 4. 配置失败重试策略
kyuubi.session.engine.open.max.attempts=3
kyuubi.session.engine.open.onFailure=DEREGISTER_AFTER_RETRY
```

#### 1.3 Classpath 缺失

**现象**：
- `ClassNotFoundException` 或 `NoClassDefFoundError`
- 常见于自定义 UDF、Hive Serde、Iceberg 等依赖

**根因**：
1. 第三方依赖未放入 Spark 的 jars 目录或未通过 `spark.jars` 指定
2. `kyuubi.engine.spark.extra.classpath` 未配置
3. YARN 模式下缺少 `spark.yarn.dist.jars`

**解决方案**：
```properties
# 在 kyuubi-defaults.conf 或 spark-defaults.conf 中添加
spark.jars=/path/to/custom.jar,/path/to/another.jar
spark.driver.extraClassPath=/path/to/libs/*
spark.executor.extraClassPath=/path/to/libs/*

# 或通过 Kyuubi 环境变量传递
kyuubi.engineEnv.SPARK_DIST_CLASSPATH=/path/to/extra/*
```

---

### 2. Engine OOM

#### 2.1 Driver OOM

**现象**：
- 引擎进程崩溃，日志报 `java.lang.OutOfMemoryError: Java heap space`
- YARN 容器被 Kill：`Container killed by YARN for exceeding memory limits`
- 客户端收到连接断开错误

**根因**：
1. **collect() 拉取大数据到 Driver**：`SELECT * FROM large_table` 没有 LIMIT
2. **广播变量过大**：`spark.sql.autoBroadcastJoinThreshold` 默认 10MB 可能导致大表被广播
3. **堆外内存不足**：Kyuubi 引擎的 Driver 堆外内存基础开销约 **1GB**（比原生 spark-sql 高很多），默认 `memoryOverhead = max(driverMemory * 0.1, 384MB)` 太小
4. **大量 Session 共享同一 Engine**：USER 模式下多个 Session 的临时表、缓存累积

**解决方案**：
```properties
# 1. 显式设置堆外内存（关键！）
spark.driver.memoryOverhead=1g
# Spark 4.0+:
spark.driver.minMemoryOverhead=1g

# 2. 调大 Driver 堆内存
spark.driver.memory=4g

# 3. 禁用直接内存缓冲（减少堆外内存）
spark.network.io.preferDirectBufs=false
spark.shuffle.io.preferDirectBufs=false
spark.reducer.maxReqsInFlight=256

# 4. 限制结果集大小
kyuubi.server.thrift.resultset.default.fetch.size=1000
spark.sql.thriftServer.queryResult.maxRows=10000

# 5. 控制共享引擎的最大生命周期
kyuubi.session.engine.spark.max.lifetime=PT4H
```

**涉及源码**：
- `org.apache.kyuubi.engine.spark.SparkProcessBuilder` — 构建内存参数
- GitHub Issue [#6481](https://github.com/apache/kyuubi/issues/6481) — Kyuubi 堆外内存过高分析

**源码佐证（来自 SparkProcessBuilder 源码分析）**：

> `SparkProcessBuilder`（位于 `kyuubi-server` 模块）**没有显式设置 `spark.driver.memoryOverhead` 的逻辑**，它只是一个配置透传器。`convertConfigKey` 方法将 Kyuubi 配置转为 Spark 配置，以 `--conf key=value` 格式传给 `spark-submit`。如果用户没有主动配置 `spark.driver.memoryOverhead`，就完全依赖 Spark 的默认值（`driverMemory * 0.1` 或 384MB，取较大者）。Kyuubi 引擎 Driver 额外加载了 Thrift Server、Session/Operation 管理、ZK 客户端等组件，堆外开销远高于原生 spark-sql，因此**显式设置 `spark.driver.memoryOverhead=1g` 是生产必要配置**。
>
> 另外，`SparkSQLEngine` 启动时有初始化 SQL 执行逻辑（`kyuubi.engine.spark.initialize.sql` 配置项，默认 `SHOW DATABASES`），但这主要消耗堆内内存做 SparkSession 预热，堆外开销主要来自 Kyuubi 引擎自身组件加载（Thrift/ZK/Session 管理），与初始化 SQL 内容无关。

#### 2.2 Executor OOM

**现象**：
- 部分 Task 失败，日志报 `Container killed by YARN for exceeding memory limits`
- Shuffle 阶段 `FetchFailedException`

**根因**：
1. 数据倾斜导致单个 Partition 过大
2. `spark.executor.memory` 设置过小
3. 聚合/Join 操作导致内存膨胀

**解决方案**：
```properties
# 1. 增大 Executor 内存
spark.executor.memory=8g
spark.executor.memoryOverhead=2g

# 2. 增加分区数（减小每个 Partition 大小）
spark.sql.shuffle.partitions=400

# 3. 启用 AQE 自动优化
spark.sql.adaptive.enabled=true
spark.sql.adaptive.coalescePartitions.enabled=true
spark.sql.adaptive.skewJoin.enabled=true
```

---

### 3. Engine 僵死

**现象**：
- 引擎进程仍在运行（YARN Application 状态 RUNNING），但不响应请求
- ZK 中引擎节点仍存在，但客户端连接超时
- WebUI Kill Engine 无效，引擎不退出（GitHub Issue [#6790](https://github.com/apache/kyuubi/issues/6790)）
- 日志持续打印 `1 connection(s) are active, delay shutdown`

**根因**：
1. **activeSessionCount 计数器不准**：ServiceDiscovery 关闭时，`activeSessionCount` 未正确归零，引擎认为仍有活跃连接
2. **GC 长暂停**：Full GC 导致引擎线程暂停，ZK 心跳超时前进程实际已无响应
3. **死锁**：引擎内部线程死锁，无法处理新请求
4. **ZK Ephemeral 节点未及时清理**：进程 OOM 后被系统 Kill，但 ZK 会话超时时间长（默认 60s），节点延迟消失

**解决方案**：
```properties
# 1. 配置引擎存活探针
kyuubi.session.engine.alive.probe.enabled=true
kyuubi.session.engine.alive.probe.interval=PT10S
kyuubi.session.engine.alive.timeout=PT2M

# 2. 缩短 ZK 会话超时
kyuubi.ha.zookeeper.session.timeout=30000

# 3. 配置空闲超时作为兜底
kyuubi.session.engine.idle.timeout=PT15M

# 4. 配置最大生命周期
kyuubi.session.engine.spark.max.lifetime=PT6H
kyuubi.session.engine.spark.max.lifetime.gracefulPeriod=PT5M

# 5. 添加 shutdown watchdog（v1.11+）
# 参见 PR #7150: 添加强制终止看门狗
```

**涉及源码**：
- `org.apache.kyuubi.engine.spark.SparkSQLEngine#stop` — 引擎停止逻辑
- `org.apache.kyuubi.ha.client.ServiceDiscovery` — ZK 注册/注销和 activeSessionCount 管理
- `org.apache.kyuubi.engine.EngineRef` — 引擎引用和健康探测

**源码佐证（来自 SparkSQLEngine 源码分析）**：

> **`gracefulStop()` 僵死根因确认**：`SparkSQLEngine.gracefulStop()` 方法中有一个 `while` 循环检查 `backendService.sessionManager.getActiveUserSessionCount > 0`，循环体内 `Thread.sleep(10秒)` 等待。如果客户端异常断连导致 Session 的 `close()` 未被调用，`activeSessionCount` 计数器不递减，引擎就永远卡在循环里反复打印 `delay shutdown` 日志。
>
> **两层看门狗机制（v1.11+）**：
> 1. **生命周期终止检查器 `startLifetimeTerminatingChecker`**：配置项 `ENGINE_SPARK_MAX_LIFETIME` + `ENGINE_SPARK_MAX_LIFETIME_GRACEFUL_PERIOD`。第一阶段调用 `gracefulStop()` 注销服务+等待会话；第二阶段（超时+宽限期后）**强制关闭空闲会话**（无正在运行 Operation 的会话），不再无限等待——这是 PR #7150 添加的强制终止看门狗逻辑。
> 2. **连接快速失败检查器 `startFastFailChecker`**：配置项 `ENGINE_SPARK_MAX_INITIAL_WAIT`，CONNECTION 级别引擎启动后一直没有建连就直接 stop，避免空转。

---

### 4. Session 泄漏

**现象**：
- `list session` 接口显示大量已无客户端连接的 Session
- 引擎不退出，资源不释放
- Session 数量持续增长

**根因**：
1. **Client 断开但 Session 未关闭**：`kyuubi.session.close.on.disconnect=false`（或客户端异常断开时关闭逻辑未触发）
2. **Engine 崩溃后 Session 残留**：Engine 进程被 Kill，但 Kyuubi Server 端的 Session 对象仍存活（Issue [#4847](https://github.com/apache/kyuubi/issues/4847)）
3. **Socket 泄漏**：LaunchEngine 后台任务仍在运行，Engine 启动成功后分配了 `_client`，但 Session 已关闭，Socket 无法释放（Issue [#4821](https://github.com/apache/kyuubi/issues/4821)）
4. **Engine Session 泄漏**：Kyuubi Session 关闭时 Engine 尚未就绪，导致 Engine 侧 Session 未正确关闭（Issue [#7290](https://github.com/apache/kyuubi/issues/7290)）

**解决方案**：
```properties
# 1. 确保断开时关闭 Session
kyuubi.session.close.on.disconnect=true  # 默认 true

# 2. 配置 Session 空闲超时作为兜底
kyuubi.session.idle.timeout=PT6H
kyuubi.session.check.interval=PT5M

# 3. 配置引擎存活探针（检测 Engine 崩溃）
kyuubi.session.engine.alive.probe.enabled=true
kyuubi.session.engine.alive.probe.interval=PT10S
kyuubi.session.engine.alive.timeout=PT2M

# 4. 升级到包含修复的版本（≥1.9.x 包含 #7290 修复）
```

**涉及源码**：
- `org.apache.kyuubi.session.KyuubiSessionImpl#close` — Session 关闭逻辑
- `org.apache.kyuubi.session.SessionManager#closeSession` — Session 管理器清理
- `org.apache.kyuubi.operation.LaunchEngine` — 引擎启动任务的取消和清理

---

### 5. Server OOM

**现象**：
- Kyuubi Server 进程 OOM 崩溃
- 日志报 `java.lang.OutOfMemoryError: unable to create new native thread` 或 `Java heap space`
- Server 重启后快速再次 OOM

**根因**：
1. **线程资源耗尽**（Discussion [#3091](https://github.com/apache/kyuubi/discussions/3091)）：yarn-client 模式下大量 Spark Engine 的线程由 Kyuubi Server 进程创建，超出 OS nproc 限制
2. **嵌套 JAAS 配置内存泄漏**（Issue [#7153](https://github.com/apache/kyuubi/issues/7153)）：每次创建 ZK 客户端生成新 JaasConf 对象，链式引用导致内存持续增长
3. **Batch 作业状态轮询风暴**（Issue [#7226](https://github.com/apache/kyuubi/issues/7226)）：大量 PENDING 状态的 Batch 作业持续轮询，消耗内存
4. **Session 堆积**：大量未清理的 Session 对象占用堆内存

**解决方案**：
```bash
# 1. 增加 OS 资源限制
# /etc/security/limits.conf
kyuubi    soft    nproc    16384
kyuubi    hard    nproc    16384
kyuubi    soft    nofile   65536
kyuubi    hard    nofile   65536

# 2. 增加 Server JVM 堆内存
# $KYUUBI_HOME/conf/kyuubi-env.sh
export KYUUBI_JAVA_OPTS="-Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# 3. 定期 GC（已内置）
kyuubi.server.periodicGC.interval=PT30M

# 4. 限制连接数
kyuubi.server.limit.connections.per.user=50
kyuubi.server.limit.connections.per.user.ipaddress=20

# 5. 升级版本修复 JAAS 泄漏（≥修复 #7153 的版本）
```

---

### 6. ZK 连接丢失

**现象**：
- Server 日志警告 `Unable to read additional data from server, server is probably down`
- `Session expired` 错误，引擎节点从 ZK 消失
- 客户端连接间歇性失败（Issue [#7006](https://github.com/apache/kyuubi/issues/7006)）

**根因**：
1. **网络抖动**：Server 与 ZK 集群之间网络不稳定（K8s 环境尤其常见）
2. **GC 导致心跳超时**：Server 或 ZK 的 GC 暂停超过 ZK session timeout
3. **ZK 集群负载过高**：大量 Engine 节点注册导致 ZK watch 风暴
4. **ZK Session 超时配置过短**：默认 `kyuubi.ha.zookeeper.session.timeout=60000ms`

**解决方案**：
```properties
# 1. 调大 ZK 超时参数
kyuubi.ha.zookeeper.session.timeout=120000
kyuubi.ha.zookeeper.connection.timeout=30000

# 2. 使用负载均衡器替代 ZK 做服务发现（推荐生产环境）
# 客户端直连 LB 地址，而非 zooKeeper 服务发现

# 3. 优化 ZK 集群
# - 独立部署 ZK 集群，不与 Kafka/HBase 共用
# - 增加 ZK 节点数和内存
# - 调优 tickTime/initLimit/syncLimit

# 4. 检查 K8s 网络策略和 Pod 亲和性
```

---

### 7. Kerberos 认证失败

**现象**：
- `javax.security.sasl.SaslException: GSS initiate failed`
- `GSSException: No valid credentials provided`
- `Server not found in Kerberos database`
- 连接建立后一段时间（通常 24h）突然失败

**根因**：
1. **Keytab/Principal 配置错误**：`kyuubi.kinit.keytab` 路径错误或文件权限不对
2. **TGT 过期**：`kyuubi.kinit.interval` 大于 Kerberos 票据有效期
3. **Proxy User 权限未配置**：Hadoop `core-site.xml` 中缺少 `hadoop.proxyuser.<kyuubi-principal>.hosts/groups`
4. **时钟偏差**：Server/KDC 时间差超过 5 分钟（Kerberos 默认容忍窗口）
5. **加密类型不匹配**：KDC 支持的加密类型与 JVM 不一致

**解决方案**：
```properties
# kyuubi-defaults.conf
kyuubi.authentication=KERBEROS
kyuubi.kinit.principal=kyuubi/hostname@REALM
kyuubi.kinit.keytab=/etc/security/keytabs/kyuubi.keytab
kyuubi.kinit.interval=PT1H  # 确保小于 ticket 有效期

# Hadoop core-site.xml
hadoop.proxyuser.kyuubi.hosts=*
hadoop.proxyuser.kyuubi.groups=*
```

```bash
# 1. 验证 keytab
klist -kt /etc/security/keytabs/kyuubi.keytab
kinit -kt /etc/security/keytabs/kyuubi.keytab kyuubi/hostname@REALM
klist

# 2. 检查时钟同步
ntpstat  # 或 chronyc tracking

# 3. 检查 Keytab 文件权限
ls -la /etc/security/keytabs/kyuubi.keytab
# 应为 kyuubi 用户可读：-r-------- kyuubi hadoop
```

**涉及源码**：
- `org.apache.kyuubi.service.authentication.KyuubiAuthenticationFactory`
- `org.apache.kyuubi.service.authentication.KyuubiKerberosHandler`

---

### 8. Batch 作业提交失败

**现象**：
- REST API `POST /api/v1/batches` 返回错误
- Batch 状态一直 PENDING，不转为 RUNNING
- Server 日志显示 `spark-submit --proxy-user` 失败

**根因**：
1. **proxy-user 权限问题**：Hadoop 代理用户配置缺失
2. **资源文件路径错误**：Batch 请求中的 `resource` 路径不存在
3. **K8s 调度超时**：大量 Batch 同时提交，Driver Pod 无法调度（Issue [#7226](https://github.com/apache/kyuubi/issues/7226)）
4. **Metadata Store 残留**：Server 重启后脏数据导致轮询风暴

**解决方案**：
```properties
# 1. 配置 Batch 检查间隔
kyuubi.batch.application.check.interval=PT5S

# 2. 配置饥饿检测超时
kyuubi.batch.application.starvation.timeout=PT3M

# 3. 增加 Batch Session 空闲超时
kyuubi.batch.session.idle.timeout=PT6H

# 4. 限制每个用户的 Batch 连接数
kyuubi.server.limit.batch.connections.per.user=10

# 5. K8s 环境增加提交超时
kyuubi.engine.kubernetes.submit.timeout=PT300S
```

---

## 二、配置参数体系

### 1. Server 核心参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.server.name` | 空 | Server 名称 | 生产环境设为有意义的名称 |
| `kyuubi.server.administrators` | 空 | 管理员列表（逗号分隔） | 配置运维账号 |
| `kyuubi.server.periodicGC.interval` | `PT30M` | 定期 GC 间隔 | 保持默认或根据内存压力调整 |
| `kyuubi.server.info.provider` | `ENGINE` | 信息提供者 | `ENGINE`=引擎信息，`SERVER`=服务器信息 |
| `kyuubi.server.limit.connections.per.user` | 无限制 | 每用户最大连接数 | 生产建议设 50~100 |
| `kyuubi.server.limit.connections.per.user.ipaddress` | 无限制 | 每用户+IP 最大连接数 | 生产建议设 20 |
| `kyuubi.server.limit.batch.connections.per.user` | 无限制 | 每用户最大 Batch 连接数 | 建议设 10~20 |
| `kyuubi.server.limit.connections.user.deny.list` | 空 | 拒绝连接用户列表 | 封禁异常用户 |
| `kyuubi.server.limit.connections.user.unlimited.list` | 空 | 不限连接数用户列表 | 服务账号 |
| `kyuubi.server.thrift.resultset.default.fetch.size` | `1000` | 默认每次 Fetch 行数 | 视场景调整 |
| `kyuubi.server.tempFile.expireTime` | `P30D` | 临时文件过期时间 | 磁盘紧张可缩短 |
| `kyuubi.server.redaction.regex` | 空 | 日志脱敏正则 | 配合安全合规 |

### 2. Session 参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.session.idle.timeout` | `PT6H` | Session 空闲超时 | 生产建议 PT1H~PT4H |
| `kyuubi.session.check.interval` | `PT5M` | Session 检查间隔 | 保持默认 |
| `kyuubi.session.close.on.disconnect` | `true` | 断开时关闭 Session | **生产必须 true** |
| `kyuubi.session.name` | 空 | Session 可读名称 | 调试用 |
| `kyuubi.session.engine.launch.async` | `true` | 异步启动引擎 | 保持 true |
| `kyuubi.session.engine.initialize.timeout` | `PT3M` | 引擎初始化超时 | YARN 环境建议 PT5M~PT10M |
| `kyuubi.session.engine.idle.timeout` | `PT30M` | 引擎空闲超时 | 按场景：临时查询 PT10M，ETL PT1H |
| `kyuubi.session.engine.alive.probe.enabled` | `false` | 引擎存活探针 | **生产建议 true** |
| `kyuubi.session.engine.alive.probe.interval` | `PT10S` | 探针间隔 | 保持默认 |
| `kyuubi.session.engine.alive.timeout` | `PT2M` | 引擎存活超时 | 保持默认 |
| `kyuubi.session.engine.open.max.attempts` | `9` | 引擎打开重试次数 | 资源紧张时调小 |
| `kyuubi.session.engine.open.onFailure` | `RETRY` | 失败策略 | `DEREGISTER_AFTER_RETRY` 避免僵尸 |
| `kyuubi.session.engine.spark.max.lifetime` | `PT0S` | Spark 引擎最大生命周期 | 生产建议 PT4H~PT8H |
| `kyuubi.session.engine.spark.max.lifetime.gracefulPeriod` | `PT0S` | 生命周期结束优雅期 | 建议 PT5M |
| `kyuubi.session.engine.startup.waitCompletion` | `true` | 等待引擎启动完成 | 保持默认 |

### 3. Engine 参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.engine.type` | `SPARK_SQL` | 引擎类型 | SPARK_SQL/FLINK_SQL/TRINO/JDBC/HIVE/CHAT |
| `kyuubi.engine.share.level` | `USER` | 引擎共享级别 | 见下方详细说明 |
| `kyuubi.engine.pool.size` | `-1`(禁用) | 引擎池大小 | USER 级别下建议 2~5 |
| `kyuubi.engine.pool.name` | `engine-pool` | 引擎池名称 | 按队列命名 |
| `kyuubi.engine.pool.selectPolicy` | `RANDOM` | 引擎池选择策略 | RANDOM/POLLING |
| `kyuubi.engine.pool.size.threshold` | `9` | 引擎池大小阈值(server端) | 防止用户设置过大 |
| `kyuubi.engine.single.spark.session` | `false` | 单 SparkSession 模式 | 需要共享临时表时设 true |
| `kyuubi.engine.share.level.subdomain` | 空 | 引擎子域 | 同用户多引擎时使用 |
| `kyuubi.engine.ui.retainedSessions` | `200` | WebUI 保留 Session 数 | 保持默认 |
| `kyuubi.engine.ui.stop.enabled` | `true` | 允许 WebUI 停止引擎 | 保持默认 |
| `kyuubi.engine.spark.initialize.sql` | `SHOW DATABASES` | Spark 引擎初始化 SQL | 可改为更轻量的 SQL |

**Engine Share Level 详细说明**：

| 共享级别 | 含义 | 隔离度 | 适用场景 |
|----------|------|--------|----------|
| `CONNECTION` | 每会话独享引擎 | 最高 | 大规模 ETL、重要批处理 |
| `USER`(默认) | 同用户共享引擎 | 中 | 交互式查询、小 ETL |
| `GROUP` | 同组用户共享引擎 | 低 | 部门级共享查询 |
| `SERVER_LOCAL` | 单 Server 实例独享 | 极低 | 负载均衡 |
| `SERVER` | 全集群共享引擎 | 最低 | 管理员用途 |

### 4. HA 参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.ha.addresses` | 空 | ZK/Etcd 连接地址 | **生产必配**，如 `zk1:2181,zk2:2181,zk3:2181` |
| `kyuubi.ha.namespace` | `kyuubi` | ZK 根节点路径 | 按环境隔离：`kyuubi_prod`/`kyuubi_test` |
| `kyuubi.ha.client.class` | `...ZookeeperDiscoveryClient` | HA 客户端实现类 | 默认 ZK，也支持 Etcd |
| `kyuubi.ha.zookeeper.connection.timeout` | `15000`(ms) | ZK 连接超时 | 网络差环境调到 30000 |
| `kyuubi.ha.zookeeper.session.timeout` | `60000`(ms) | ZK 会话超时 | 建议 60000~120000 |
| `kyuubi.ha.zookeeper.auth.type` | `NONE` | ZK 认证类型 | NONE/KERBEROS/DIGEST |
| `kyuubi.ha.etcd.lease.timeout` | `PT10S` | Etcd 租约超时 | 保持默认 |

**客户端 HA 连接方式**：
```
jdbc:kyuubi://zk1:2181,zk2:2181,zk3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=kyuubi
```

### 5. Security 参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.authentication` | `NONE` | 认证方式 | 生产环境用 KERBEROS 或 LDAP |
| `kyuubi.authentication.sasl.qop` | `auth` | SASL QOP | `auth`=认证，`auth-int`=完整性，`auth-conf`=加密 |
| `kyuubi.authentication.ldap.url` | 空 | LDAP URL | LDAP 认证时配置 |
| `kyuubi.kinit.principal` | 空 | Kerberos Principal | 如 `kyuubi/host@REALM` |
| `kyuubi.kinit.keytab` | 空 | Keytab 文件路径 | 确保 kyuubi 用户可读 |
| `kyuubi.kinit.interval` | `PT1H` | kinit 续订频率 | 小于 ticket 有效期 |
| `kyuubi.spnego.keytab` | 空 | SPNego keytab | HTTP 认证用 |
| `kyuubi.spnego.principal` | 空 | SPNego Principal | HTTP 认证用 |
| `kyuubi.frontend.thrift.binary.ssl.enabled` | `false` | Thrift SSL 加密 | 安全环境建议启用 |

### 6. Batch 参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.batch.application.check.interval` | `PT5S` | Batch 应用检查间隔 | 保持默认 |
| `kyuubi.batch.application.starvation.timeout` | `PT3M` | Batch 饥饿告警超时 | YARN 繁忙时调大 |
| `kyuubi.batch.session.idle.timeout` | `PT6H` | Batch Session 空闲超时 | 短 Batch 可缩短 |
| `kyuubi.batch.conf.ignore.list` | 空 | 忽略的配置键 | 安全过滤敏感配置 |
| `kyuubi.batch.info.internal.redirect` | `true` | 内部 RPC 转发 Batch 信息 | HA 模式保持 true |

### 7. Metrics/Events 参数

| 参数名 | 默认值 | 含义 | 调优建议 |
|--------|--------|------|----------|
| `kyuubi.metrics.enabled` | `true` | 启用指标系统 | 保持 true |
| `kyuubi.metrics.reporters` | `PROMETHEUS` | 指标报告器 | CONSOLE/JMX/JSON/PROMETHEUS/SLF4J |
| `kyuubi.metrics.prometheus.port` | `10019` | Prometheus HTTP 端口 | 确保不冲突 |
| `kyuubi.metrics.prometheus.path` | `/metrics` | Prometheus URI 路径 | 保持默认 |
| `kyuubi.metrics.json.location` | `${KYUUBI_HOME}/metrics` | JSON 指标文件位置 | 保持默认 |

**可用指标类别**：
- **连接指标**：`kyuubi.connection.opened`/`kyuubi.connection.failed`
- **Session 指标**：`kyuubi.session.open`/`kyuubi.session.total`
- **Operation 指标**：`kyuubi.operation.open`/`kyuubi.operation.total`/`kyuubi.operation.state.*`
- **Engine 指标**：`kyuubi.engine.total`/`kyuubi.engine.timeout`
- **JVM 指标**：内存使用、GC、线程数等
- **Thrift 指标**：RPC 调用计数和延迟

---

## 三、JIRA Bug 考古

### 1. Engine 启动相关 Bug

| Bug | 标题 | 影响 | 修复方案 |
|-----|------|------|----------|
| [#6481](https://github.com/apache/kyuubi/issues/6481) | **[Improvement] off-heap memory usage of the driver is too high** | Kyuubi 引擎 Driver 堆外内存基础开销约 1GB，远高于原生 spark-sql。默认 `memoryOverhead` 太小导致 YARN OOM Kill | 显式设置 `spark.driver.memoryOverhead=1g`；Spark 4.0+ 使用 `spark.driver.minMemoryOverhead=1g`；禁用直接内存缓冲 |
| [#6111](https://github.com/apache/kyuubi/discussions/6111) | **使用 spark.master=yarn, cluster 模式启动引擎建表报错** | Spark cluster 模式下建表操作异常 | 使用 client 模式或检查 Hive Metastore 连通性 |

### 2. Session/Connection 泄漏 Bug

| Bug | 标题 | 影响 | 修复方案 |
|-----|------|------|----------|
| [#7290](https://github.com/apache/kyuubi/issues/7290) | **Spark engine might not stop when kyuubi session is closed** | Kyuubi Session 关闭时 Engine 尚未就绪（_client 为 null），导致 Engine 侧 Session 无法关闭，Spark Driver Pod 持续运行造成资源泄漏 | PR [#7294](https://github.com/apache/kyuubi/pull/7294) 修复，已合入 v1.11.1 |
| [#4847](https://github.com/apache/kyuubi/issues/4847) | **Session leak caused by engine stop (close session immediately when engine corrupt)** | Engine 崩溃（如用户执行 `spark.close`）后，Server 端 Session 残留，`list session` 显示过期 Session | PR [#4848](https://github.com/apache/kyuubi/pull/4848) 实现当 Engine 损坏时立即关闭 Session |
| [#4821](https://github.com/apache/kyuubi/issues/4821) | **Possible socket leak in KyuubiSessionImpl** | Session 关闭后 LaunchEngine 后台任务仍在运行，Engine 启动成功后 `_client` 被赋值，Socket 无法释放 | PR [#4826](https://github.com/apache/kyuubi/pull/4826) 避免 Socket 泄漏 |
| [#5832](https://github.com/apache/kyuubi/issues/5832) | **Close KyuubiSession when OperationLog not initialized** | OperationLog 未初始化时关闭 Session 的竞态条件 | 修复 Session 关闭的线程安全问题 |

### 3. HA/ZK 相关 Bug

| Bug | 标题 | 影响 | 修复方案 |
|-----|------|------|----------|
| [#7153](https://github.com/apache/kyuubi/issues/7153) | **Server OOM due to nested Zookeeper Jaas Client Configurations** | 每次创建 ZK 客户端生成新 JaasConf 并链式引用前一个，导致严重内存泄漏，最终 Server OOM | PR [#7154](https://github.com/apache/kyuubi/pull/7154) 共享 JAAS 配置，避免重复创建 |
| [#7087](https://github.com/apache/kyuubi/issues/7087) | **Failed to initialize the embedded ZooKeeper** | 内嵌 ZK 因端口冲突或僵尸进程无法启动，`kill -9` 无效 | 停止父进程（如 supervisorctl stop QuorumPeerMain）；使用外部独立 ZK 集群 |
| [#7006](https://github.com/apache/kyuubi/issues/7006) | **Socket Timeout When Connecting to Kyuubi Server** | K8s 环境中 ZK 连接间歇性超时，导致客户端连接不稳定 | 排查 K8s 网络；建议使用 LB 替代 ZK 做服务发现 |
| [#6790](https://github.com/apache/kyuubi/issues/6790) | **WebUI kill engine failed** | WebUI 终止引擎时 activeSessionCount 不归零，引擎延迟关闭直到 idle.timeout | 修复 ServiceDiscovery 中 activeSessionCount 计数逻辑 |

### 4. 安全相关 Bug

| Bug | 标题 | 影响 | 修复方案 |
|-----|------|------|----------|
| [#7333](https://github.com/apache/kyuubi/issues/7333) | **Running spark on k8s cluster through kyuubi find kerberos auth failure** | K8s 环境下 Kerberos SASL 协商失败：`GSS initiate failed` | 检查 krb5.conf 配置、Keytab 挂载、KDC 可达性 |
| [#5123](https://github.com/apache/kyuubi/discussions/5123) | **How to enable zookeeper authentication?** | 内嵌 ZK 不支持完整认证配置 | 生产环境使用外部 ZK 并启用 `kyuubi.ha.zookeeper.auth.type=KERBEROS` |

### 5. 性能相关 Bug

| Bug | 标题 | 影响 | 修复方案 |
|-----|------|------|----------|
| [#7226](https://github.com/apache/kyuubi/issues/7226) | **Kyuubi OOM when polling for status of spark driver** | K8s 模式大量 Batch 同时提交，PENDING 状态作业持续轮询导致 Kyuubi Pod OOM，重启后循环崩溃 | 清理 Metadata Store 脏数据；限制并发 Batch 数量；增加 Kyuubi Pod 内存 |
| [#7149](https://github.com/apache/kyuubi/issues/7149) | **Add shutdown watchdog to forcefully terminate spark engine** | 引擎优雅关闭失败时无强制终止机制，导致资源泄漏 | PR [#7150](https://github.com/apache/kyuubi/pull/7150) 添加 shutdown watchdog |
| [#6913](https://github.com/apache/kyuubi/discussions/6913) | **Questions about kyuubi.engine.pool.size** | 引擎池配置理解歧义，用户不清楚 pool.size=-1 时的行为 | 默认 -1 禁用池，每个用户仅一个引擎；需要多引擎时设正整数 |
| [#5952](https://github.com/apache/kyuubi/issues/5952) | **Disconnect connections without running operations after engine maxlife time graceful period** | 引擎最大生命周期到达后，空闲连接未被主动断开 | 优雅期后强制断开无活跃操作的连接 |

---

## 四、生产环境推荐配置模板

```properties
# === kyuubi-defaults.conf 生产推荐 ===

# --- Server ---
kyuubi.server.administrators=admin,ops
kyuubi.server.periodicGC.interval=PT30M
kyuubi.server.limit.connections.per.user=50
kyuubi.server.limit.connections.per.user.ipaddress=20
kyuubi.server.limit.batch.connections.per.user=10

# --- Session ---
kyuubi.session.idle.timeout=PT2H
kyuubi.session.check.interval=PT5M
kyuubi.session.close.on.disconnect=true
kyuubi.session.engine.initialize.timeout=PT5M
kyuubi.session.engine.idle.timeout=PT30M
kyuubi.session.engine.alive.probe.enabled=true
kyuubi.session.engine.alive.probe.interval=PT10S
kyuubi.session.engine.alive.timeout=PT2M
kyuubi.session.engine.open.max.attempts=3
kyuubi.session.engine.open.onFailure=DEREGISTER_AFTER_RETRY
kyuubi.session.engine.spark.max.lifetime=PT6H
kyuubi.session.engine.spark.max.lifetime.gracefulPeriod=PT5M

# --- Engine ---
kyuubi.engine.type=SPARK_SQL
kyuubi.engine.share.level=USER
kyuubi.engine.pool.size=2

# --- HA ---
kyuubi.ha.addresses=zk1:2181,zk2:2181,zk3:2181
kyuubi.ha.namespace=kyuubi_prod
kyuubi.ha.zookeeper.session.timeout=60000
kyuubi.ha.zookeeper.connection.timeout=15000

# --- Security ---
kyuubi.authentication=KERBEROS
kyuubi.kinit.principal=kyuubi/_HOST@REALM
kyuubi.kinit.keytab=/etc/security/keytabs/kyuubi.keytab
kyuubi.kinit.interval=PT1H

# --- Batch ---
kyuubi.batch.application.check.interval=PT5S
kyuubi.batch.application.starvation.timeout=PT5M
kyuubi.batch.session.idle.timeout=PT2H

# --- Metrics ---
kyuubi.metrics.enabled=true
kyuubi.metrics.reporters=PROMETHEUS
kyuubi.metrics.prometheus.port=10019

# --- Spark Defaults (通过 kyuubi 传递) ---
spark.driver.memory=4g
spark.driver.memoryOverhead=1g
spark.executor.memory=8g
spark.executor.memoryOverhead=2g
spark.sql.adaptive.enabled=true
spark.network.io.preferDirectBufs=false
spark.shuffle.io.preferDirectBufs=false
```

```bash
# === kyuubi-env.sh ===
export KYUUBI_JAVA_OPTS="-Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
```

```bash
# === OS Limits (/etc/security/limits.conf) ===
kyuubi    soft    nproc    16384
kyuubi    hard    nproc    16384
kyuubi    soft    nofile   65536
kyuubi    hard    nofile   65536
```

---

## 四、L4 对抗性分析总结

### 4.1 最危险的配置缺失 Top 5

| 排名 | 配置 | 缺失后果 | 严重级别 |
|------|------|---------|---------|
| 1 | `spark.driver.memoryOverhead=1g` | Engine Driver OOM（Kyuubi 堆外开销 ~1G） | **P0** |
| 2 | `kyuubi.session.engine.idle.timeout` | Engine 永不释放，资源浪费 | P1 |
| 3 | `kyuubi.server.limit.connections.per.user` | 单用户创建无限 Engine | P1 |
| 4 | `kyuubi.authentication` | 无认证，任何人可冒充任何用户 | **P0** |
| 5 | `spark.sql.adaptive.enabled=true` | 缺少 AQE，大查询性能差 10x | P2 |

### 4.2 最隐蔽的 Bug 模式 Top 5

| 排名 | 模式 | 触发条件 | 根因 |
|------|------|---------|------|
| 1 | POLLING 计数器溢出 | 运行数月 | `Integer.MAX_VALUE % N` 为负数 |
| 2 | 引用计数泄漏 | Session 创建后立即异常 | `decrementAndGet` 未执行 |
| 3 | 限流计数器泄漏 | 线程被 OOM Kill | `AtomicInteger` 未回滚 |
| 4 | ZK 节点残留 | Engine 被 kill -9 | 临时节点在 session timeout 内有效 |
| 5 | 结果集 OOM | `SELECT * FROM huge_table` | `df.collect()` 全量加载 |

### 4.3 异常场景与源码文件映射

| 异常类别 | 核心源码文件 | 关键方法 |
|---------|------------|---------|
| Engine 启动失败 | `SparkProcessBuilder.scala` | `commands`, `start()` |
| Engine OOM | `ExecuteStatement.scala` | `collectAsIterator()` |
| Engine 僵死 | `SparkSQLEngine.scala` | `startIdleTerminatingChecker()` |
| 连接被拒 | `SessionLimiter.scala` | `increment()` |
| Session 超时 | `SessionManager.scala` | `timeoutChecker` |
| 分布式锁超时 | `EngineRef.scala` | `tryWithLock()` |
| ZK 节点残留 | `ZookeeperDiscoveryClient.scala` | `registerService()` |

---

## 五、知识晶体

| 维度 | 内容 |
|------|------|
| **问题/场景** | Kyuubi 生产环境最常见的 10+ 异常场景及其源码级根因 |
| **核心源码** | SparkProcessBuilder、ExecuteStatement、SessionLimiter、EngineRef、ZookeeperDiscoveryClient |
| **调用链** | 异常 → 日志表现 → 源码定位 → 配置修复 → JIRA 验证 |
| **设计意图** | 将运维经验 × 源码分析 × JIRA 考古深度融合，形成可复用的排障知识体系 |
| **关键参数** | `driver.memoryOverhead=1g`, `engine.idle.timeout=30min`, `limit.connections.per.user`, `authentication` |
| **踩坑记录** | ① memoryOverhead 默认值太小是最高频 OOM 根因 ② 无限流 = 资源灾难 ③ 无认证 = 安全灾难 |
| **认知更新** | 从"改配置试试"→ "每个异常追溯到源码行+JIRA Issue+配置默认值计算公式的系统化排障方法" |

---

> 本文档遵循"源码精通方法论"L4 标准。
> 覆盖：对抗性阅读 + 考古学方法 + 知识晶体化模板 + 量化驱动（Top N 排序）
