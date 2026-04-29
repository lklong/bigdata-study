# [教案] Flink on YARN — Kerberos 安全集群配置使用姿势

> 🎯 教学目标：掌握 Flink on YARN 在 Kerberos 安全集群中的认证配置、Keytab 分发、访问安全组件的完整配置 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（什么场景需要用？）

| 场景 | 说明 |
|------|------|
| **生产集群** | 企业 Hadoop 集群几乎 100% 开启 Kerberos |
| **Flink 读写 HDFS** | Checkpoint/Savepoint 存 HDFS 需要认证 |
| **Flink 消费 Kafka** | Kafka 开启 SASL_PLAINTEXT/SASL_SSL |
| **Flink 访问 HBase** | HBase 开启安全认证 |
| **Flink 访问 Hive Metastore** | Hive 元数据需要 Kerberos 认证 |

**核心挑战**：
- Flink on YARN 是分布式部署，JM/TM 跑在不同节点
- Keytab 文件需要分发到所有节点
- Delegation Token 有过期时间，需要更新机制
- 多个安全组件（HDFS + Kafka + HBase + Hive）需要分别配置

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Flink | 1.17+ / 1.18+ | 推荐 1.18.1 |
| Hadoop/YARN | 3.x | 已开启 Kerberos |
| KDC | MIT Kerberos 5 | 集群已配置 |
| Java | JDK 8 / JDK 11 | |

### 2.2 环境准备命令

```bash
# 1. 验证 Kerberos 环境
klist -V
cat /etc/krb5.conf

# 2. 验证能获取 TGT
kinit -kt /etc/security/keytabs/flink.keytab flink/hostname@REALM.COM
klist

# 3. 验证 HDFS 认证
hdfs dfs -ls /

# 4. 验证 YARN 认证
yarn node -list

# 5. 确认 Flink Keytab 文件存在
ls -la /etc/security/keytabs/flink.keytab

# 6. 确认 Flink Principal
klist -kt /etc/security/keytabs/flink.keytab
# 期望输出类似:
# KVNO Principal
# ---- ----------
#    2 flink/hostname@REALM.COM

# 7. 设置环境变量
export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)
export KRB5_CONFIG=/etc/krb5.conf
```

### 2.3 KDC 中创建 Flink Principal（管理员操作）

```bash
# 在 KDC 服务器上执行
kadmin.local << 'EOF'
addprinc -randkey flink/flink-host@REALM.COM
xst -k /etc/security/keytabs/flink.keytab flink/flink-host@REALM.COM
EOF

# 设置权限
chmod 400 /etc/security/keytabs/flink.keytab
chown flink:hadoop /etc/security/keytabs/flink.keytab

# 分发 keytab 到所有节点（或使用 YARN 的 keytab 分发机制）
```

---

## 三、核心配置方式

### 3.1 flink-conf.yaml 安全配置详解

```yaml
# ======================== Kerberos 核心配置 ========================

# Kerberos 认证上下文（必需）
security.kerberos.login.use-ticket-cache: false
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/flink-host@REALM.COM

# Kerberos krb5.conf 路径（通常系统默认即可）
security.kerberos.krb5-conf.path: /etc/krb5.conf

# ======================== Delegation Token 配置 ========================

# HDFS Delegation Token 更新（Flink 自动获取和更新）
security.kerberos.login.contexts: Client,KafkaClient

# Token 更新间隔（默认 1 小时，必须小于 Token 过期时间）
security.kerberos.relogin.period: 60000

# ======================== YARN 相关安全配置 ========================

# 在 YARN 上运行时自动获取 HDFS Token
yarn.security.kerberos.ship-local-keytab: true
yarn.security.kerberos.localized-keytab-path: flink.keytab
```

### 3.2 完整参数对照表

| 参数 | 说明 | 默认值 | 示例 |
|------|------|--------|------|
| `security.kerberos.login.keytab` | Keytab 文件路径 | 无 | `/etc/security/keytabs/flink.keytab` |
| `security.kerberos.login.principal` | Kerberos Principal | 无 | `flink/host@REALM.COM` |
| `security.kerberos.login.use-ticket-cache` | 是否使用票据缓存 | true | `false`（生产必须 false） |
| `security.kerberos.login.contexts` | 认证上下文 | Client,KafkaClient | `Client,KafkaClient` |
| `security.kerberos.krb5-conf.path` | krb5.conf 路径 | /etc/krb5.conf | `/etc/krb5.conf` |
| `security.kerberos.relogin.period` | 重新登录间隔(ms) | 60000 | `60000` |
| `yarn.security.kerberos.ship-local-keytab` | 是否分发 Keytab | false | `true` |
| `yarn.security.kerberos.localized-keytab-path` | YARN 容器中 Keytab 路径 | 无 | `flink.keytab` |

### 3.3 Keytab 分发机制

```
┌──────────────────────────────────────────────────────────────┐
│                    Flink on YARN + Kerberos                    │
│                                                                │
│  提交节点:                                                      │
│    kinit -kt flink.keytab flink@REALM.COM                      │
│                    │                                           │
│                    ▼                                           │
│  YARN RM 分配 Container:                                        │
│    ┌─────────┐   ┌─────────┐   ┌─────────┐                   │
│    │   JM    │   │   TM1   │   │   TM2   │                   │
│    │ keytab  │   │ keytab  │   │ keytab  │  ← YARN 自动分发   │
│    │ tokens  │   │ tokens  │   │ tokens  │  ← DelegationToken │
│    └─────────┘   └─────────┘   └─────────┘                   │
└──────────────────────────────────────────────────────────────┘
```

**两种分发方式**：

| 方式 | 配置 | 说明 |
|------|------|------|
| **Keytab 分发**（推荐） | `yarn.security.kerberos.ship-local-keytab=true` | Keytab 随 YARN Container 一起分发 |
| **Delegation Token** | Flink 自动获取 | 提交时获取 HDFS/Kafka Token，Container 内使用 Token |

---

## 四、完整实战示例

### 4.1 场景：Kerberos 集群中提交 Flink 任务读写 HDFS

#### flink-conf.yaml 配置

```yaml
# === Kerberos 认证 ===
security.kerberos.login.use-ticket-cache: false
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/submit-host@EXAMPLE.COM
security.kerberos.login.contexts: Client,KafkaClient
security.kerberos.krb5-conf.path: /etc/krb5.conf

# === YARN Keytab 分发 ===
yarn.security.kerberos.ship-local-keytab: true
yarn.security.kerberos.localized-keytab-path: flink.keytab

# === Checkpoint 存储 HDFS ===
state.backend: rocksdb
state.checkpoints.dir: hdfs:///flink/checkpoints
state.savepoints.dir: hdfs:///flink/savepoints
state.backend.incremental: true

# === 基础资源配置 ===
jobmanager.memory.process.size: 2048m
taskmanager.memory.process.size: 4096m
taskmanager.numberOfTaskSlots: 4
parallelism.default: 4
```

#### 提交命令

```bash
# 先 kinit（如果不使用 keytab 自动认证）
kinit -kt /etc/security/keytabs/flink.keytab flink/submit-host@EXAMPLE.COM

# Application Mode 提交
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Dsecurity.kerberos.login.keytab=/etc/security/keytabs/flink.keytab \
    -Dsecurity.kerberos.login.principal=flink/submit-host@EXAMPLE.COM \
    -Dsecurity.kerberos.login.use-ticket-cache=false \
    -Dyarn.security.kerberos.ship-local-keytab=true \
    -Dyarn.security.kerberos.localized-keytab-path=flink.keytab \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    -Dyarn.application.name="Flink-Kerberos-Demo" \
    -Dyarn.application.queue=default \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kerberos-demo \
    -c com.example.MyFlinkJob \
    /path/to/my-flink-job.jar
```

### 4.2 场景：Kerberos 集群访问 Kafka（SASL_PLAINTEXT）

#### Kafka JAAS 配置文件 `kafka_jaas.conf`

```
KafkaClient {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    storeKey=true
    keyTab="/etc/security/keytabs/flink.keytab"
    principal="flink/submit-host@EXAMPLE.COM"
    serviceName="kafka";
};
```

#### Flink 任务中 Kafka 安全配置

```java
// Kafka Source 安全配置
KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
        .setBootstrapServers("kafka-host:9092")
        .setTopics("secure-topic")
        .setGroupId("flink-kerberos-group")
        .setStartingOffsets(OffsetsInitializer.latest())
        .setValueOnlyDeserializer(new SimpleStringSchema())
        // Kerberos 安全配置
        .setProperty("security.protocol", "SASL_PLAINTEXT")
        .setProperty("sasl.mechanism", "GSSAPI")
        .setProperty("sasl.kerberos.service.name", "kafka")
        .build();
```

#### 提交命令（带 Kafka Kerberos）

```bash
$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Dsecurity.kerberos.login.keytab=/etc/security/keytabs/flink.keytab \
    -Dsecurity.kerberos.login.principal=flink/submit-host@EXAMPLE.COM \
    -Dsecurity.kerberos.login.use-ticket-cache=false \
    -Dsecurity.kerberos.login.contexts=Client,KafkaClient \
    -Dyarn.security.kerberos.ship-local-keytab=true \
    -Dyarn.security.kerberos.localized-keytab-path=flink.keytab \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dyarn.application.name="Flink-Kafka-Kerberos" \
    -Denv.java.opts="-Djava.security.krb5.conf=/etc/krb5.conf -Djava.security.auth.login.config=/path/to/kafka_jaas.conf" \
    -c com.example.KafkaKerberosJob \
    /path/to/my-kafka-job.jar
```

### 4.3 场景：Kerberos 集群访问 HBase

```java
// HBase 配置
Configuration hbaseConf = HBaseConfiguration.create();
hbaseConf.set("hbase.zookeeper.quorum", "zk-host:2181");
hbaseConf.set("hbase.security.authentication", "kerberos");
hbaseConf.set("hbase.master.kerberos.principal", "hbase/_HOST@EXAMPLE.COM");
hbaseConf.set("hbase.regionserver.kerberos.principal", "hbase/_HOST@EXAMPLE.COM");

// Flink HBase Connector 安全配置
CREATE TABLE hbase_dim (
    rowkey STRING,
    cf1 ROW<name STRING, age STRING>,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'user_dim',
    'zookeeper.quorum' = 'zk-host:2181',
    'properties.hbase.security.authentication' = 'kerberos',
    'properties.hbase.master.kerberos.principal' = 'hbase/_HOST@EXAMPLE.COM',
    'properties.hbase.regionserver.kerberos.principal' = 'hbase/_HOST@EXAMPLE.COM'
);
```

### 4.4 场景：Kerberos 集群访问 Hive Metastore

```yaml
# flink-conf.yaml 中添加 Hive 认证
security.kerberos.login.contexts: Client,KafkaClient

# 将 hive-site.xml 放入 Flink conf 目录
# hive-site.xml 关键配置:
# <property>
#   <name>hive.metastore.kerberos.principal</name>
#   <value>hive/_HOST@EXAMPLE.COM</value>
# </property>
# <property>
#   <name>hive.metastore.sasl.enabled</name>
#   <value>true</value>
# </property>
```

#### Flink SQL 访问 Kerberos Hive

```sql
CREATE CATALOG hive_catalog WITH (
    'type' = 'hive',
    'hive-conf-dir' = '/etc/hive/conf',
    'default-database' = 'default'
);

USE CATALOG hive_catalog;
SHOW DATABASES;
```

### 4.5 完整生产提交命令模板

```bash
#!/bin/bash
# ============================================================
# Flink on YARN + Kerberos 生产提交脚本
# ============================================================

export FLINK_HOME=/opt/flink-1.18.1
export HADOOP_CONF_DIR=/etc/hadoop/conf
export HADOOP_CLASSPATH=$(hadoop classpath)

KEYTAB=/etc/security/keytabs/flink.keytab
PRINCIPAL="flink/$(hostname -f)@EXAMPLE.COM"
JOB_JAR=/opt/flink-jobs/my-job-1.0.jar
MAIN_CLASS=com.example.MyProductionJob

# 先 kinit 确保 TGT 有效
kinit -kt $KEYTAB $PRINCIPAL

$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    \
    -Dsecurity.kerberos.login.keytab=$KEYTAB \
    -Dsecurity.kerberos.login.principal=$PRINCIPAL \
    -Dsecurity.kerberos.login.use-ticket-cache=false \
    -Dsecurity.kerberos.login.contexts=Client,KafkaClient \
    -Dsecurity.kerberos.krb5-conf.path=/etc/krb5.conf \
    \
    -Dyarn.security.kerberos.ship-local-keytab=true \
    -Dyarn.security.kerberos.localized-keytab-path=flink.keytab \
    \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    \
    -Dyarn.application.name="Prod-Kerberos-FlinkJob" \
    -Dyarn.application.queue=production \
    \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/prod-job \
    -Dstate.savepoints.dir=hdfs:///flink/savepoints/prod-job \
    -Dstate.backend.incremental=true \
    -Dexecution.checkpointing.interval=60000 \
    -Dexecution.checkpointing.mode=EXACTLY_ONCE \
    \
    -Denv.java.opts="-Djava.security.krb5.conf=/etc/krb5.conf" \
    \
    -c $MAIN_CLASS \
    $JOB_JAR
```

---

## 五、常见问题与排障

### 5.1 问题速查表

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `GSSException: No valid credentials provided` | TGT 过期或 Keytab 无效 | `kinit -kt` 刷新，检查 Keytab 权限 |
| `Login failure: javax.security.auth.login.LoginException` | Principal 不匹配 | 确认 Principal 与 Keytab 中的一致 |
| `Could not login: the client is being asked for a password` | 未找到 Keytab | 检查 `security.kerberos.login.keytab` 路径 |
| `Delegation token expired` | Token 过期未更新 | 确认 `security.kerberos.relogin.period` 配置 |
| `Client not found in Kerberos database` | KDC 中无此 Principal | `kadmin.local` 中添加 |
| `Clock skew too great` | 节点时间不同步 | 配置 NTP，时钟差异 < 5 分钟 |
| `YARN: Token can not be found` | HDFS Delegation Token 未生成 | 确认 `yarn.security.kerberos.ship-local-keytab=true` |
| Kafka `SASL authentication failed` | Kafka JAAS 配置错误 | 检查 `security.protocol` 和 `sasl.mechanism` |

### 5.2 排障命令

```bash
# 1. 验证 Keytab 有效性
klist -kt /etc/security/keytabs/flink.keytab
kinit -kt /etc/security/keytabs/flink.keytab flink/host@REALM.COM
klist

# 2. 开启 Kerberos Debug
export FLINK_ENV_JAVA_OPTS="-Dsun.security.krb5.debug=true"
# 或者在提交时加:
-Denv.java.opts="-Dsun.security.krb5.debug=true -Djava.security.krb5.conf=/etc/krb5.conf"

# 3. 查看 Flink 日志中的认证信息
yarn logs -applicationId application_xxxxx_xxxx | grep -i "kerberos\|login\|keytab\|token\|SASL"

# 4. 检查节点时间同步
for host in node1 node2 node3; do
    echo "$host: $(ssh $host date)"
done

# 5. 验证 Delegation Token
hdfs fetchdt --renewer flink token.txt
hdfs fetchdt --print token.txt

# 6. 检查 krb5.conf
cat /etc/krb5.conf
```

### 5.3 Kerberos Debug 日志分析

```
# 正常认证流程日志:
[DEBUG] Trying to find KDC for realm EXAMPLE.COM
[DEBUG] Found KDC kdc.example.com:88 for realm EXAMPLE.COM
[DEBUG] Using keytab: /etc/security/keytabs/flink.keytab
[DEBUG] Principal: flink/host@EXAMPLE.COM
[DEBUG] Commit Succeeded  ← 认证成功

# 失败示例:
[ERROR] Pre-authentication information was invalid (24) ← 密码/Keytab 错误
[ERROR] Clock skew too great (37) ← 时间偏差
[ERROR] Client not found in Kerberos database (6) ← Principal 不存在
```

---

## 六、生产最佳实践

### 6.1 Delegation Token 更新机制

```
Flink on YARN Token 生命周期:

1. 提交时: Flink Client 使用 Keytab 获取 HDFS/Kafka Token
2. 运行时: Token 随 Container 分发
3. 更新机制:
   - Flink 1.18+ 支持自动 Token 更新
   - JM 定期使用 Keytab 更新 Token（security.kerberos.relogin.period）
   - 更新后的 Token 通过 RPC 分发给 TM

关键配置:
  security.kerberos.relogin.period: 60000  (1分钟检查一次)
  Token 默认有效期: 24h (由 Hadoop 配置决定)
  Token 最大续期时间: 7天 (dfs.namenode.delegation.token.max-lifetime)
```

### 6.2 多安全组件配置汇总

```yaml
# flink-conf.yaml 完整安全配置示例
# ===== Kerberos 基础 =====
security.kerberos.login.use-ticket-cache: false
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/host@EXAMPLE.COM
security.kerberos.login.contexts: Client,KafkaClient
security.kerberos.krb5-conf.path: /etc/krb5.conf
security.kerberos.relogin.period: 60000

# ===== YARN Keytab 分发 =====
yarn.security.kerberos.ship-local-keytab: true
yarn.security.kerberos.localized-keytab-path: flink.keytab

# ===== HDFS（通过 hadoop conf 自动认证）=====
# 只需确保 HADOOP_CONF_DIR 指向正确的 core-site.xml/hdfs-site.xml

# ===== Kafka SASL =====
# 方式1: 在代码中配置 security.protocol + sasl.mechanism
# 方式2: 通过 JAAS 配置文件
# env.java.opts: -Djava.security.auth.login.config=/path/to/jaas.conf

# ===== ZooKeeper =====
# 如果 ZK 也开启了 Kerberos:
zookeeper.sasl.disable: false
```

### 6.3 安全配置 Checklist

| # | 检查项 | 命令 / 位置 |
|---|--------|-------------|
| 1 | Keytab 文件存在且权限正确 | `ls -la /etc/security/keytabs/flink.keytab` (400) |
| 2 | Principal 在 KDC 中存在 | `klist -kt flink.keytab` |
| 3 | kinit 能成功 | `kinit -kt flink.keytab flink@REALM` |
| 4 | 节点时间同步 | `ntpq -p` 或 `chronyc tracking` |
| 5 | HADOOP_CONF_DIR 包含安全配置 | `grep -l "security" $HADOOP_CONF_DIR/*.xml` |
| 6 | flink-conf.yaml 安全参数完整 | 对照参数表检查 |
| 7 | krb5.conf 中 KDC 地址正确 | `cat /etc/krb5.conf` |
| 8 | YARN 队列有提交权限 | `yarn queue -status <queue>` |

### 6.4 长期运行任务的 Token 续期策略

```bash
# Hadoop Token 相关配置（hdfs-site.xml）
# dfs.namenode.delegation.token.max-lifetime = 604800000  (7天)
# dfs.namenode.delegation.token.renew-interval = 86400000  (1天)

# 如果任务需要跑超过 7 天（Token 最大生命周期）:
# → 必须使用 Keytab 分发模式（ship-local-keytab=true）
# → Flink 会使用 Keytab 自动重新获取 Token

# 验证策略:
# 1. 部署后观察 7 天内 Token 是否正常续期
# 2. 检查 JM 日志中 "Delegation token renewed" 关键字
yarn logs -applicationId application_xxxxx_xxxx | grep -i "token renew"
```

---

## 七、举一反三

### 7.1 Kerberos 认证 vs 其他认证方式

| 方式 | 安全级别 | 复杂度 | 适用场景 |
|------|----------|--------|----------|
| Kerberos | 高 | 高 | 企业级生产集群 |
| Simple（无认证） | 低 | 低 | 开发测试环境 |
| LDAP/AD | 中 | 中 | 用户管理 |
| SSL/TLS | 中 | 中 | 传输加密 |
| Ranger/Sentry | 高 | 高 | 细粒度授权（配合 Kerberos） |

### 7.2 面试高频题

**Q1: Flink on YARN 的 Kerberos 认证流程是什么？**

> 1. 提交节点：Client 使用 Keytab/TGT 认证
> 2. Client 向 NameNode/RM 获取 Delegation Token
> 3. Token 和 Keytab 随 YARN Container 分发到 JM/TM
> 4. JM/TM 使用 Token 访问 HDFS/Kafka 等
> 5. Token 过期前，JM 使用 Keytab 更新 Token

**Q2: 为什么 Flink 推荐 `use-ticket-cache=false`？**

> Ticket Cache 是用户会话级别的，不可靠：
> - 用户退出登录后 Cache 失效
> - 长期运行的 Flink 任务无法依赖人工 kinit
> - Keytab 是永久有效的密钥文件，适合自动化和长期运行

**Q3: 如果 Token 过期了任务会怎样？**

> - 如果配置了 Keytab 分发（`ship-local-keytab=true`）：JM 会自动用 Keytab 重新获取 Token
> - 如果没有 Keytab 分发：任务在 Token 过期后无法访问 HDFS/Kafka，抛出认证异常

### 7.3 思考题

1. 如果 KDC 临时宕机 5 分钟，正在运行的 Flink 任务会受影响吗？
2. 在多 Realm 环境中（cross-realm trust），Flink 如何配置？
3. 如何实现 Flink 任务的最小权限原则？（不同任务用不同 Principal）
4. Keytab 文件泄露了怎么办？如何快速止血？

---

> 📝 **本教案配套代码仓库**: [bigdata-study/flink/案例/](https://github.com/lklong/bigdata-study/tree/main/flink/案例/)
> 📅 **更新日期**: 2026-04-30
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
