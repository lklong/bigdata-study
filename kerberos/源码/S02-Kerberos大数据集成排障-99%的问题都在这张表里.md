# 教案 S02：Kerberos 大数据集成排障 — 99% 的问题都在这张表里

> **课时**：35分钟 | **难度**：⭐⭐⭐

## 一、课前导入

> "Kerberos 一出问题就是一天"——这是大数据运维的共识。因为错误信息模糊，排查路径长，涉及组件多。这张排障手册覆盖 99% 的 Kerberos 问题。

## 二、排障决策树

```
Kerberos 报错
├── "No valid credentials"
│   ├── kinit 能成功吗？
│   │   ├── YES → Keytab 路径/权限问题，检查 spark.yarn.keytab 配置
│   │   └── NO → KDC 问题或 Principal 不存在
│   └── klist 显示有 Ticket 吗？
│       ├── YES → Ticket 过期，检查 renew 时间
│       └── NO → kinit 没执行或失败了
├── "Clock skew too great"
│   └── ntpdate 同步时间（允许偏差 < 5min）
├── "Server not found in Kerberos database"
│   ├── 检查 Principal 名大小写
│   ├── 检查 hostname 是否能正确反向解析
│   └── kadmin.local → listprincs | grep xxx
├── "Encryption type ... not supported"
│   └── /etc/krb5.conf 的 permitted_enctypes 配置
├── "Delegation Token can not be renewed"
│   ├── Token 超过 max-lifetime
│   └── Token Renewer Principal 配置错误
└── "SASL authentication failed"
    ├── 检查 _HOST 是否正确替换为实际 hostname
    ├── DNS 反向解析是否正确
    └── 服务端 Keytab 是否包含正确的 Principal
```

## 三、调试技巧

### 3.1 开启 Kerberos 调试日志

```bash
# Java 级别
export HADOOP_OPTS="-Dsun.security.krb5.debug=true"

# Hadoop 级别
export HADOOP_JAAS_DEBUG=true

# Spark
spark-submit --conf "spark.driver.extraJavaOptions=-Dsun.security.krb5.debug=true"
```

### 3.2 必备诊断命令

```bash
# 查看当前票据
klist -e

# 检查 Keytab 内容
klist -kt /path/to/keytab

# 手动认证测试
kinit -kt /path/to/keytab principal@REALM

# 检查 KDC 连通性
echo | nc kdc-host 88

# 检查 DNS 反向解析（很多问题根因在这！）
nslookup $(hostname)
host $(hostname -i)

# 检查时钟偏差
ntpdate -q ntp-server
```

### 3.3 各组件 Kerberos 配置速查

| 组件 | 配置文件 | 关键配置 |
|------|---------|---------|
| HDFS | `core-site.xml` | `hadoop.security.authentication=kerberos` |
| Hive | `hive-site.xml` | `hive.server2.authentication=KERBEROS` |
| Kafka | `server.properties` | `sasl.mechanism.inter.broker.protocol=GSSAPI` |
| Spark | `spark-defaults.conf` | `spark.yarn.principal` + `spark.yarn.keytab` |
| Flink | `flink-conf.yaml` | `security.kerberos.login.keytab` |
| HBase | `hbase-site.xml` | `hbase.security.authentication=kerberos` |

## 四、课堂练习

### 思考题：为什么 DNS 反向解析对 Kerberos 这么重要？

<details>
<summary>参考答案</summary>

Kerberos 的 Service Principal 格式是 `service/hostname@REALM`。
客户端连接时：
1. 先通过 DNS 解析目标 hostname 得到 IP
2. 建立连接后，用**反向 DNS**（IP → hostname）确定 Service Principal
3. 如果反向解析得到的 hostname 和正向解析的不一致 → Principal 不匹配 → 认证失败

例如：
- 正向: `nn1.example.com` → `10.0.0.1`
- 反向: `10.0.0.1` → `node-001.internal` ← 和正向不一样！
- 客户端构造的 Principal: `hdfs/node-001.internal@REALM`
- KDC 中注册的 Principal: `hdfs/nn1.example.com@REALM`
- 结果: "Server not found in Kerberos database"！

解决: 确保正向和反向 DNS 一致，或在 krb5.conf 中设置 `rdns = false`
</details>

## 五、知识晶体

```
排障三板斧: klist + kinit -kt + sun.security.krb5.debug=true
TOP3根因: 时钟偏差 / DNS反向解析 / Keytab过期
Delegation Token: max-lifetime默认7天，超过需重新获取
安全关闭Kerberos调试日志的前提: 先确认问题复现路径
```

*教案作者：Eric | 最后更新：2026-04-30*
