# Kerberos 认证流程与大数据集成深度分析

> Kerberos Expert 补课学习 — 企业级安全认证核心

## 一、Kerberos 核心三方认证

### 1.1 三个角色

```
KDC (Key Distribution Center):
  ├── AS (Authentication Server) — 验证用户身份，发 TGT
  └── TGS (Ticket Granting Server) — 用 TGT 换 Service Ticket

Client — 发起请求的用户/服务
Service — 被访问的服务 (HDFS NameNode / HiveServer2 / ...)
```

### 1.2 认证流程（三次握手）

```
Step 1: AS-REQ / AS-REP (获取 TGT)
  Client → KDC/AS: "我是 user@REALM, 给我 TGT"
    请求包含: principal name, 时间戳 (用 user 密码加密)
  KDC/AS → Client: TGT + Session Key (用 user 密码加密)
    TGT 内容: [client principal, tgs session key, 有效期] (用 krbtgt 密码加密)

Step 2: TGS-REQ / TGS-REP (获取 Service Ticket)
  Client → KDC/TGS: "我要访问 hdfs/nn1@REALM" + TGT + Authenticator
    Authenticator: [client principal, 时间戳] (用 session key 加密)
  KDC/TGS → Client: Service Ticket + Service Session Key

Step 3: AP-REQ / AP-REP (访问服务)
  Client → HDFS NameNode: Service Ticket + Authenticator
    NameNode 用自己的 keytab 解密 Service Ticket → 验证 Client 身份
  NameNode → Client: 认证成功，开始服务

安全保证:
  - 密码从不在网络上传输（只用于加解密）
  - Ticket 有时效性（默认 10 小时）
  - 每个 Service Ticket 只对特定服务有效
```

### 1.3 Keytab 机制

```
Keytab = 存储 principal 密码的文件（二进制格式）
用途: 服务自动认证，不需要人工输入密码

# 创建 keytab
kadmin: addprinc -randkey hdfs/nn1@REALM
kadmin: ktadd -k /etc/security/keytab/hdfs.keytab hdfs/nn1@REALM

# 验证 keytab
klist -kt /etc/security/keytab/hdfs.keytab
kinit -kt /etc/security/keytab/hdfs.keytab hdfs/nn1@REALM

安全规范:
  - keytab 权限 400, owner 为服务用户
  - 每个服务独立 keytab, 不共用
  - 定期轮换 (建议 90 天)
```

## 二、大数据组件 Kerberos 集成

### 2.1 HDFS

```xml
<!-- core-site.xml -->
<property>
  <name>hadoop.security.authentication</name>
  <value>kerberos</value>
</property>
<property>
  <name>hadoop.security.authorization</name>
  <value>true</value>
</property>

<!-- hdfs-site.xml -->
<property>
  <name>dfs.namenode.kerberos.principal</name>
  <value>hdfs/_HOST@REALM</value>  <!-- _HOST 自动替换为主机名 -->
</property>
<property>
  <name>dfs.namenode.keytab.file</name>
  <value>/etc/security/keytab/hdfs.keytab</value>
</property>
<property>
  <name>dfs.datanode.kerberos.principal</name>
  <value>hdfs/_HOST@REALM</value>
</property>

<!-- 委托令牌 (Delegation Token) -->
<!-- Client 获取一次 → 传给 MapReduce/Spark Task → Task 免密访问 HDFS -->
<property>
  <name>dfs.namenode.delegation.token.max-lifetime</name>
  <value>604800000</value>  <!-- 7天 -->
</property>
```

### 2.2 Hive / HiveServer2

```xml
<!-- hive-site.xml -->
<property>
  <name>hive.server2.authentication</name>
  <value>KERBEROS</value>
</property>
<property>
  <name>hive.server2.authentication.kerberos.principal</name>
  <value>hive/_HOST@REALM</value>
</property>
<property>
  <name>hive.server2.authentication.kerberos.keytab</name>
  <value>/etc/security/keytab/hive.keytab</value>
</property>

<!-- 代理用户 (Proxy User) — HS2 代替最终用户访问 HDFS -->
<property>
  <name>hadoop.proxyuser.hive.hosts</name>
  <value>*</value>
</property>
<property>
  <name>hadoop.proxyuser.hive.groups</name>
  <value>*</value>
</property>
```

### 2.3 Spark on YARN + Kerberos

```bash
# 提交 Spark 任务到 Kerberos 集群
spark-submit \
  --master yarn \
  --principal user@REALM \
  --keytab /path/to/user.keytab \
  --conf spark.yarn.security.tokens.hive.enabled=true \
  --conf spark.yarn.security.tokens.hbase.enabled=true \
  my-app.jar

# Spark 内部流程:
# 1. Driver 用 keytab kinit → 获取 TGT
# 2. Driver 获取 HDFS/Hive/HBase 的 Delegation Token
# 3. Delegation Token 打包到 Container 的 credentials 中
# 4. Executor 用 Delegation Token 免密访问各服务
# 5. 长任务: Token 即将过期 → Driver 自动续期
```

### 2.4 Spark on K8s + Kerberos（案例延伸）

```
K8s 场景的特殊挑战:
  - Pod 没有宿主机的 keytab 文件
  - Pod IP 动态变化，反向 DNS 不一定配置
  - K8s Secret 挂载 keytab → 权限和安全性

解决方案:
  1. 将 keytab 存入 K8s Secret
     kubectl create secret generic krb5-keytab --from-file=user.keytab
  
  2. Pod Template 挂载
     volumes:
     - name: krb5-keytab
       secret:
         secretName: krb5-keytab
         defaultMode: 0400
     volumeMounts:
     - name: krb5-keytab
       mountPath: /etc/security/keytab
       readOnly: true
  
  3. Spark 配置
     spark.kubernetes.kerberos.enabled=true
     spark.kubernetes.kerberos.krb5.path=/etc/krb5.conf
     spark.kubernetes.kerberos.keytab=/etc/security/keytab/user.keytab
     spark.kubernetes.kerberos.principal=user@REALM
```

## 三、常见故障排查

### 3.1 认证失败

```
错误: GSSException: No valid credentials provided
原因: TGT 过期 / keytab 不匹配 / 时钟偏差

排查:
  klist              # 检查当前 TGT 状态
  klist -kt keytab   # 检查 keytab 内容
  ntpdate -q ntp     # 检查时钟同步 (Kerberos 要求 < 5 分钟偏差)

解决:
  kinit -kt keytab principal  # 重新获取 TGT
  ntpdate ntp.server          # 同步时钟
```

### 3.2 跨域信任 (Cross-Realm Trust)

```
场景: 开发集群 DEV.REALM 访问生产集群 PROD.REALM

配置:
  # 在两个 KDC 上都创建 krbtgt principal
  kadmin (PROD): addprinc krbtgt/PROD.REALM@DEV.REALM
  kadmin (DEV):  addprinc krbtgt/PROD.REALM@DEV.REALM
  # 密码必须一致！

  # krb5.conf 配置域路由
  [capaths]
  DEV.REALM = {
    PROD.REALM = .
  }
```

### 3.3 调试模式

```bash
# Java 应用开启 Kerberos 调试
export JAVA_OPTS="-Dsun.security.krb5.debug=true"

# Hadoop 组件调试
export HADOOP_OPTS="-Dsun.security.krb5.debug=true -Dsun.security.spnego.debug=true"

# 日志关键词:
# "Found ticket for" — 找到有效 TGT
# "Credentials are no longer valid" — TGT 过期
# "Pre-authentication information was invalid" — 密码错误
# "Clock skew too great" — 时钟偏差过大
```

---

*Kerberos Expert 学习产出 | 2026-04-08 | 补课：认证流程与大数据集成*
