# [教案] Flink on YARN — Kerberos 安全集群配置使用姿势

> 🎯 教学目标：掌握 Flink on YARN 在 Kerberos 安全集群中的配置方法，包括 Keytab 分发、访问 HDFS/Kafka/HBase/Hive/ZK 的安全配置、Delegation Token 更新、常见认证失败排障 | ⏰ 预计学时: 80分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入

### 1.1 为什么需要 Kerberos？

**生活类比**：在非安全集群中，任何人拿到 HDFS/Kafka 的地址就能读写数据——就像一栋没有门禁的大楼。Kerberos 就是给大数据集群装上了"门禁系统"：
- 每个用户/服务必须用"门禁卡"（Keytab）刷卡认证
- 认证通过后获得"临时通行证"（Ticket/Token）
- 通行证有有效期，过期需要续签

Flink 作业运行在 YARN 上时，需要：
1. 作业提交时进行 Kerberos 认证
2. 将认证凭据分发到所有 Container（JM/TM）
3. 长期运行的作业需要自动续签 Delegation Token

### 1.2 认证流程概览

```
┌──────────┐     kinit/keytab      ┌──────────┐
│  Client  │ ────────────────────→ │   KDC    │
│(flink提交)│ ←─── TGT ──────────── │(认证中心) │
└────┬─────┘                       └──────────┘
     │ 
     │ TGT → 获取各服务的 Service Ticket
     │
     ├──→ HDFS (nn/host@REALM)
     ├──→ YARN (rm/host@REALM)
     ├──→ Kafka (kafka/host@REALM)
     ├──→ HBase (hbase/host@REALM)
     ├──→ Hive (hive/host@REALM)
     └──→ ZooKeeper (zookeeper/host@REALM)
```

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 说明 |
|------|------|
| KDC | MIT Kerberos / Active Directory |
| Hadoop | 已开启 Kerberos 安全认证 |
| Flink | 1.15+ |
| Keytab | Flink 作业专用 principal + keytab 文件 |

### 2.2 创建 Flink 专用 Principal 和 Keytab

```bash
# 在 KDC 服务器上操作
kadmin.local

# 创建 Flink 作业专用 principal
addprinc -randkey flink/flink-client@HADOOP.COM
addprinc -randkey flink/yarn-host@HADOOP.COM

# 导出 keytab
xst -k /etc/security/keytabs/flink.keytab flink/flink-client@HADOOP.COM
xst -k /etc/security/keytabs/flink.keytab flink/yarn-host@HADOOP.COM

# 设置权限
chmod 400 /etc/security/keytabs/flink.keytab
chown flink:hadoop /etc/security/keytabs/flink.keytab

# 验证 keytab
klist -kt /etc/security/keytabs/flink.keytab
kinit -kt /etc/security/keytabs/flink.keytab flink/flink-client@HADOOP.COM
klist
```

### 2.3 Hadoop 安全配置确认

```bash
# 确认 core-site.xml 中安全配置
grep -A2 "hadoop.security.authentication" /etc/hadoop/conf/core-site.xml
# 应为: kerberos

# 确认 hdfs-site.xml
grep -A2 "dfs.namenode.kerberos.principal" /etc/hadoop/conf/hdfs-site.xml

# 确认 yarn-site.xml
grep -A2 "yarn.resourcemanager.principal" /etc/hadoop/conf/yarn-site.xml
```

---

## 三、核心使用方式

### 3.1 Flink 安全配置（flink-conf.yaml）

```yaml
# ===== Kerberos 核心配置 =====
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/flink-client@HADOOP.COM

# Kerberos 配置文件路径
security.kerberos.krb5-conf.path: /etc/krb5.conf

# ===== Delegation Token 配置 =====
# 自动获取和续签 Delegation Token
security.kerberos.login.contexts: Client,KafkaClient

# HDFS Delegation Token
security.kerberos.access.hadoopFileSystems: hdfs://nameservice1

# ===== 长期运行作业的 Token 续签 =====
# Flink 1.17+ 内置 DelegationToken 框架
security.delegation.tokens.enabled: true
security.delegation.tokens.renewal.interval: 24h
security.delegation.tokens.renewal.retry.backoff: 1h
```

### 3.2 参数详解表

| 参数 | 说明 |
|------|------|
| `security.kerberos.login.keytab` | Keytab 文件路径 |
| `security.kerberos.login.principal` | 登录 Principal |
| `security.kerberos.krb5-conf.path` | krb5.conf 路径 |
| `security.kerberos.login.contexts` | JAAS 登录上下文（Client=ZK, KafkaClient=Kafka） |
| `security.kerberos.access.hadoopFileSystems` | 需要获取 HDFS DT 的 NameService |
| `security.delegation.tokens.enabled` | 是否启用 DT 框架 |
| `security.delegation.tokens.renewal.interval` | DT 续签间隔 |

### 3.3 Keytab 分发方式

```bash
# 方式1：yarn.ship-files（推荐，自动分发到所有 Container）
flink run -m yarn-cluster \
    -yD yarn.ship-files=/etc/security/keytabs/flink.keytab \
    -yD security.kerberos.login.keytab=flink.keytab \
    ...

# 方式2：-yt 参数上传
flink run -m yarn-cluster \
    -yt /etc/security/keytabs/flink.keytab \
    -yD security.kerberos.login.keytab=flink.keytab \
    ...

# 方式3：放在 Flink conf 目录（所有节点都有）
# 适合集群所有节点都能访问同一路径的情况
```

---

## 四、完整实战示例

### 4.1 场景一：访问 Kerberized HDFS

```bash
# 完整提交命令
flink run-application -t yarn-application \
    -Dyarn.application.name="flink-kerberized-hdfs" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dsecurity.kerberos.login.keytab=flink.keytab \
    -Dsecurity.kerberos.login.principal=flink/flink-client@HADOOP.COM \
    -Dsecurity.kerberos.access.hadoopFileSystems=hdfs://nameservice1 \
    -Dyarn.ship-files=/etc/security/keytabs/flink.keytab \
    -Dstate.checkpoints.dir=hdfs://nameservice1/flink/checkpoints \
    -c com.example.MyFlinkJob \
    hdfs://nameservice1/flink/jars/my-job.jar
```

### 4.2 场景二：访问 Kerberized Kafka

#### flink-conf.yaml 配置

```yaml
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/flink-client@HADOOP.COM
security.kerberos.login.contexts: Client,KafkaClient
```

#### Kafka JAAS 配置方式

```sql
-- 方式1：在 Kafka Source/Sink WITH 子句中配置
CREATE TABLE kafka_source (
    ...
) WITH (
    'connector' = 'kafka',
    'topic' = 'my-topic',
    'properties.bootstrap.servers' = 'kafka01:9092',
    'properties.security.protocol' = 'SASL_PLAINTEXT',
    'properties.sasl.mechanism' = 'GSSAPI',
    'properties.sasl.kerberos.service.name' = 'kafka',
    'properties.sasl.jaas.config' = 'com.sun.security.auth.module.Krb5LoginModule required useKeyTab=true storeKey=true keyTab="flink.keytab" principal="flink/flink-client@HADOOP.COM";',
    'format' = 'json'
);
```

#### Java 代码方式

```java
Properties kafkaProps = new Properties();
kafkaProps.setProperty("bootstrap.servers", "kafka01:9092");
kafkaProps.setProperty("security.protocol", "SASL_PLAINTEXT");
kafkaProps.setProperty("sasl.mechanism", "GSSAPI");
kafkaProps.setProperty("sasl.kerberos.service.name", "kafka");
// JAAS 配置通过 flink-conf.yaml 的 login.contexts 自动注入
```

### 4.3 场景三：访问 Kerberized HBase

```sql
CREATE TABLE hbase_dim (
    rowkey STRING,
    cf ROW<name STRING, age INT, city STRING>,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'dim_users',
    'zookeeper.quorum' = 'zk01:2181,zk02:2181,zk03:2181',
    'zookeeper.znode.parent' = '/hbase-secure',
    'properties.hbase.security.authentication' = 'kerberos',
    'properties.hbase.master.kerberos.principal' = 'hbase/_HOST@HADOOP.COM',
    'properties.hbase.regionserver.kerberos.principal' = 'hbase/_HOST@HADOOP.COM'
);
```

### 4.4 场景四：访问 Kerberized Hive

```sql
CREATE CATALOG my_hive WITH (
    'type' = 'hive',
    'default-database' = 'default',
    'hive-conf-dir' = '/etc/hive/conf'
    -- hive-site.xml 中已包含 Kerberos 配置：
    -- hive.metastore.sasl.enabled = true
    -- hive.metastore.kerberos.principal = hive/_HOST@HADOOP.COM
);
```

### 4.5 场景五：访问 Kerberized ZooKeeper

```yaml
# flink-conf.yaml
security.kerberos.login.contexts: Client
# "Client" 上下文用于 ZooKeeper SASL 认证

# 如果 ZK 用了自定义 service name：
# 在 JVM 参数中添加：
env.java.opts: "-Dzookeeper.server.principal=zookeeper/zk-host@HADOOP.COM"
```

### 4.6 Delegation Token 续签机制

```yaml
# Flink 1.17+ 内置 DelegationToken 框架配置
security.delegation.tokens.enabled: true

# HDFS Token 续签
security.delegation.tokens.hdfs.enabled: true

# HBase Token 续签
security.delegation.tokens.hbase.enabled: true

# Kafka 不使用 Delegation Token，而是直接用 Kerberos TGT
# 所以 Kafka 长连接不需要额外 Token 配置

# Token 续签间隔（默认 Token 有效期的 75%）
security.delegation.tokens.renewal.interval: 24h

# Token 最大生命周期到期前重新获取
security.delegation.tokens.renewal.retry.backoff: 1h
```

### 4.7 完整提交命令（全组件安全访问）

```bash
flink run-application -t yarn-application \
    -Dyarn.application.name="flink-secure-all-components" \
    -Djobmanager.memory.process.size=4096m \
    -Dtaskmanager.memory.process.size=8192m \
    -Dtaskmanager.numberOfTaskSlots=4 \
    -Dparallelism.default=4 \
    \
    # Kerberos 认证
    -Dsecurity.kerberos.login.keytab=flink.keytab \
    -Dsecurity.kerberos.login.principal=flink/flink-client@HADOOP.COM \
    -Dsecurity.kerberos.login.contexts=Client,KafkaClient \
    -Dsecurity.kerberos.access.hadoopFileSystems=hdfs://nameservice1 \
    \
    # Delegation Token
    -Dsecurity.delegation.tokens.enabled=true \
    -Dsecurity.delegation.tokens.renewal.interval=24h \
    \
    # Keytab 分发
    -Dyarn.ship-files=/etc/security/keytabs/flink.keytab;/etc/hive/conf/hive-site.xml \
    \
    # Checkpoint
    -Dexecution.checkpointing.interval=60000 \
    -Dstate.backend=rocksdb \
    -Dstate.checkpoints.dir=hdfs://nameservice1/flink/checkpoints \
    \
    -c com.example.SecureFlinkJob \
    hdfs://nameservice1/flink/jars/secure-job.jar
```

---

## 五、常见问题与排障

| # | 现象 | 原因 | 解决方案 |
|---|------|------|----------|
| 1 | `GSSException: No valid credentials provided` | Keytab 无效或 Principal 错误 | 用 `kinit -kt` 验证 keytab，检查 principal 拼写 |
| 2 | `Clock skew too great` | 集群节点时间不同步 | 配置 NTP 同步，时间差 < 5 分钟 |
| 3 | `Keytab not found` | Keytab 未分发到 Container | 使用 `yarn.ship-files` 分发 |
| 4 | `Token has expired` | Delegation Token 过期 | 确认 `security.delegation.tokens.enabled=true`，检查续签 |
| 5 | `Login failure for principal` | KDC 不可达 | 检查 krb5.conf 配置，确认 KDC 网络可达 |
| 6 | `javax.security.auth.login.LoginException` | JAAS 配置错误 | 检查 `security.kerberos.login.contexts` |
| 7 | Kafka `SASL authentication failed` | Kafka service name 不对 | 确认 `sasl.kerberos.service.name` 与 Kafka 配置一致 |
| 8 | HBase `Unable to obtain password` | HBase Token 未获取 | 确认 `security.delegation.tokens.hbase.enabled=true` |
| 9 | 长期运行(>7天)后 Token 失败 | Token 最大生命周期到期 | 使用 Keytab 重新获取（Flink 1.17+ 自动处理） |
| 10 | `KrbException: Identifier doesn't match` | krb5.conf 中加密类型不匹配 | 在 krb5.conf 中添加支持的 enctypes |

### 排障工具

```bash
# 1. 验证 Keytab
klist -kt /path/to/flink.keytab

# 2. 手动 kinit 测试
kinit -kt /path/to/flink.keytab flink/flink-client@HADOOP.COM
klist

# 3. 开启 Kerberos 调试
export FLINK_ENV_JAVA_OPTS="-Dsun.security.krb5.debug=true"

# 4. 检查 KDC 连通性
echo | nc -w 3 kdc-host 88

# 5. 检查时间同步
ntpdate -q ntp-server
date

# 6. 查看 YARN Container 日志中的认证信息
yarn logs -applicationId <app-id> | grep -i "kerberos\|auth\|login\|GSS"
```

---

## 六、生产最佳实践

### 6.1 Keytab 管理

```bash
# 1. 使用专用 principal（不复用人员账号）
flink/production-job@HADOOP.COM

# 2. Keytab 定期轮转
kadmin.local -q "cpw -randkey flink/production-job@HADOOP.COM"
kadmin.local -q "xst -k /etc/security/keytabs/flink-new.keytab flink/production-job@HADOOP.COM"

# 3. 权限最小化
chmod 400 /etc/security/keytabs/flink.keytab
# 只有 Flink 运行用户可读
```

### 6.2 长期运行作业的配置

```yaml
# flink-conf.yaml 生产推荐
security.kerberos.login.keytab: flink.keytab
security.kerberos.login.principal: flink/production@HADOOP.COM
security.kerberos.login.contexts: Client,KafkaClient

# Delegation Token 自动续签（关键！）
security.delegation.tokens.enabled: true
security.delegation.tokens.renewal.interval: 12h

# HDFS HA 配置（确保两个 NN 都能获取 Token）
security.kerberos.access.hadoopFileSystems: hdfs://nameservice1
```

### 6.3 监控认证状态

```bash
# 在 Flink Web UI 中查看：
# Configuration → security.kerberos.* 相关配置

# 日志关键词监控
- "Successfully logged in"           → 登录成功
- "Delegation token obtained"        → Token 获取成功
- "Token renewal"                    → Token 续签
- "Login failure"                    → 登录失败（告警！）
- "Token has expired"                → Token 过期（告警！）
```

---

## 七、举一反三

### 7.1 面试高频题

**Q1: Flink on YARN 的 Kerberos 认证流程？**

> A:
> 1. Client 提交时用 Keytab 向 KDC 获取 TGT
> 2. 用 TGT 向各服务获取 Delegation Token（HDFS/HBase/Hive）
> 3. 将 Keytab + DT 一起提交到 YARN（打包到 Container LocalResource）
> 4. JM/TM 启动时用 Keytab 重新 login
> 5. 后续通过 DT 访问各组件（无需每次都回 KDC）
> 6. DT 即将过期时，用 Keytab 自动续签新 DT

**Q2: Delegation Token 和 TGT 的区别？**

> A:
> - TGT：向 KDC 获取的"身份证"，有效期通常 24h，需要 Keytab 获取
> - Delegation Token：向具体服务（如 HDFS NN）获取的"通行证"，有效期可配置
> - DT 的好处：分发给多个 Container 后，Container 无需直接访问 KDC
> - DT 可以续签（renew）延长有效期，直到最大生命周期

**Q3: 为什么 Kafka 不用 Delegation Token？**

> A: Kafka 的认证模型不同——Kafka Broker 直接通过 SASL/GSSAPI 与客户端做 Kerberos 认证。每个 TM 的 Kafka Client 直接用 Keytab 向 KDC 获取 Kafka Service Ticket。这种方式更简单直接，不需要 DT 中间层。

### 7.2 思考题

1. **如果 KDC 宕机 30 分钟，正在运行的 Flink 作业会受影响吗？**
2. **如何在不停止 Flink 作业的情况下轮转 Keytab？**
3. **多租户场景下，不同团队的 Flink 作业如何隔离 Kerberos 权限？**

---

**本教案结束。下一篇：F15-Flink状态管理与Checkpoint-on-YARN 实战教案**
