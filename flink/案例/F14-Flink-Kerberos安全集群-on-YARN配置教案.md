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
| **Flink 访问 Hive** | Hive 元数据需要 Kerberos 认证 |

---

## 二、前置条件

### 2.1 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flink | 1.18+ | |
| Hadoop/YARN | 3.x | 已开启 Kerberos |
| KDC | MIT Kerberos 5 | |

### 2.2 环境准备

```bash
# 验证 Kerberos
kinit -kt /etc/security/keytabs/flink.keytab flink/hostname@REALM.COM
klist
hdfs dfs -ls /

# 创建 Flink Principal
kadmin.local -q "addprinc -randkey flink/host@REALM.COM"
kadmin.local -q "xst -k /etc/security/keytabs/flink.keytab flink/host@REALM.COM"
chmod 400 /etc/security/keytabs/flink.keytab
```

---

## 三、核心配置

### 3.1 flink-conf.yaml

```yaml
security.kerberos.login.use-ticket-cache: false
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/host@EXAMPLE.COM
security.kerberos.login.contexts: Client,KafkaClient
security.kerberos.krb5-conf.path: /etc/krb5.conf
security.kerberos.relogin.period: 60000
yarn.security.kerberos.ship-local-keytab: true
yarn.security.kerberos.localized-keytab-path: flink.keytab
```

### 3.2 参数表

| 参数 | 说明 | 示例 |
|------|------|------|
| `security.kerberos.login.keytab` | Keytab 路径 | `/etc/security/keytabs/flink.keytab` |
| `security.kerberos.login.principal` | Principal | `flink/host@REALM.COM` |
| `security.kerberos.login.use-ticket-cache` | 使用票据缓存 | `false` |
| `security.kerberos.login.contexts` | 认证上下文 | `Client,KafkaClient` |
| `yarn.security.kerberos.ship-local-keytab` | 分发 Keytab | `true` |

---

## 四、完整实战示例

### 4.1 提交命令

```bash
kinit -kt /etc/security/keytabs/flink.keytab flink/host@EXAMPLE.COM

$FLINK_HOME/bin/flink run-application \
    -t yarn-application \
    -Dsecurity.kerberos.login.keytab=/etc/security/keytabs/flink.keytab \
    -Dsecurity.kerberos.login.principal=flink/host@EXAMPLE.COM \
    -Dsecurity.kerberos.login.use-ticket-cache=false \
    -Dyarn.security.kerberos.ship-local-keytab=true \
    -Dyarn.security.kerberos.localized-keytab-path=flink.keytab \
    -Djobmanager.memory.process.size=2048m \
    -Dtaskmanager.memory.process.size=4096m \
    -Dyarn.application.name="Flink-Kerberos-Job" \
    -Dstate.checkpoints.dir=hdfs:///flink/checkpoints/kerb-job \
    -c com.example.MyJob \
    /path/to/job.jar
```

### 4.2 访问 Kafka（SASL）

```java
KafkaSource.<String>builder()
    .setProperty("security.protocol", "SASL_PLAINTEXT")
    .setProperty("sasl.mechanism", "GSSAPI")
    .setProperty("sasl.kerberos.service.name", "kafka")
    .build();
```

### 4.3 访问 HBase

```sql
CREATE TABLE hbase_dim (
    rowkey STRING,
    cf1 ROW<name STRING>,
    PRIMARY KEY (rowkey) NOT ENFORCED
) WITH (
    'connector' = 'hbase-2.2',
    'table-name' = 'user_dim',
    'zookeeper.quorum' = 'zk:2181',
    'properties.hbase.security.authentication' = 'kerberos'
);
```

---

## 五、常见问题与排障

| 问题 | 原因 | 解决 |
|------|------|------|
| `No valid credentials` | TGT 过期 | `kinit -kt` 刷新 |
| `Login failure` | Principal 不匹配 | 检查 keytab 内容 |
| `Clock skew too great` | 时间不同步 | 配置 NTP |
| `Token expired` | Token 未续期 | 启用 keytab 分发 |
| `Client not found` | KDC 无此 Principal | kadmin 添加 |

```bash
# 开启 Debug
-Denv.java.opts="-Dsun.security.krb5.debug=true"

# 查日志
yarn logs -applicationId app_xxx | grep -i "kerberos\|login\|token"
```

---

## 六、生产最佳实践

### 6.1 安全 Checklist

| # | 检查项 |
|---|--------|
| 1 | Keytab 权限 400 |
| 2 | Principal 存在于 KDC |
| 3 | kinit 能成功 |
| 4 | 节点时间同步 |
| 5 | flink-conf.yaml 安全参数完整 |
| 6 | HADOOP_CONF_DIR 正确 |

### 6.2 Token 续期

- `ship-local-keytab=true` → JM 自动续期
- Token 默认有效 24h，最大 7 天
- 超过 7 天的任务必须用 Keytab 分发

---

## 七、举一反三

**Q: 为什么用 Keytab 而不用 ticket-cache？**
> Ticket cache 是会话级别的，用户退出失效。Keytab 是永久密钥文件，适合长期运行任务。

**Q: Token 过期怎么办？**
> 配置 `ship-local-keytab=true`，JM 自动用 Keytab 重新获取 Token。

---

> 📅 **更新日期**: 2026-04-30
> ✍️ **作者**: Eric（豹纹）— 大数据实战教学专家
