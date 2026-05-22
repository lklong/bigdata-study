# 大数据组件 Kerberos 集成配置大全

> 大数据 SRE 必修课 · Eric · 2026-05-09  
> HDFS / YARN / MapReduce / Hive / Spark / Kyuubi / HBase / Kafka / ZooKeeper / Ranger / Impala 全集成

---

## 一、集成总览图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         BIGDATA.COM Realm                           │
│                                                                     │
│  ┌───────────┐    ┌───────────┐    ┌──────────┐    ┌────────────┐ │
│  │  HDFS NN  │    │  YARN RM  │    │  HMS     │    │  HiveServer2│ │
│  │  hdfs/_HOST│    │ yarn/_HOST│    │hive/_HOST│    │ hive/_HOST  │ │
│  └─────┬─────┘    └─────┬─────┘    └─────┬────┘    └──────┬──────┘ │
│        │                │                │                │         │
│        └────────────────┴────────────────┴────────────────┘         │
│                                │                                     │
│                          ┌─────▼─────┐                               │
│                          │    KDC    │  kdc01/kdc02.bigdata.com     │
│                          └───────────┘                               │
│                                │                                     │
│        ┌────────────────┬──────┴──────┬────────────────┐             │
│        │                │             │                │             │
│  ┌─────▼──────┐  ┌─────▼─────┐  ┌────▼────┐  ┌────────▼─────┐     │
│  │  Spark     │  │  Kyuubi   │  │  HBase  │  │   ZooKeeper   │     │
│  │spark/_HOST │  │kyuubi/_HOST│  │hbase/_HOST│  │zookeeper/_HOST│     │
│  └────────────┘  └───────────┘  └─────────┘  └───────────────┘     │
└─────────────────────────────────────────────────────────────────────┘

每个服务进程：keytab + Kerberos principal + JVM Kerberos 配置
```

---

## 二、HDFS Kerberos 集成

### 2.1 需要的 Principal

| 用途 | Principal 模板 | 节点 |
|------|---------------|------|
| NameNode RPC | `hdfs/_HOST@BIGDATA.COM` | NN 主备 |
| NameNode HTTP | `HTTP/_HOST@BIGDATA.COM` | NN 主备 |
| DataNode | `hdfs/_HOST@BIGDATA.COM` | 所有 DN |
| JournalNode | `hdfs/_HOST@BIGDATA.COM` | JN |
| ZKFC | `hdfs/_HOST@BIGDATA.COM` | NN 主备 |

### 2.2 core-site.xml

```xml
<configuration>
  <property>
    <name>hadoop.security.authentication</name>
    <value>kerberos</value>
  </property>
  <property>
    <name>hadoop.security.authorization</name>
    <value>true</value>
  </property>
  <property>
    <name>hadoop.rpc.protection</name>
    <value>authentication</value>
    <!-- 三档：authentication（仅认证）/ integrity（防篡改）/ privacy（加密） -->
    <!-- 生产敏感数据用 privacy，普通用 authentication（性能最好） -->
  </property>
  <property>
    <name>hadoop.security.auth_to_local</name>
    <value>
      RULE:[2:$1@$0](hdfs@BIGDATA.COM)s/.*/hdfs/
      RULE:[2:$1@$0](yarn@BIGDATA.COM)s/.*/yarn/
      RULE:[2:$1@$0](mapred@BIGDATA.COM)s/.*/mapred/
      RULE:[2:$1@$0](hive@BIGDATA.COM)s/.*/hive/
      RULE:[2:$1@$0](hbase@BIGDATA.COM)s/.*/hbase/
      RULE:[2:$1@$0](spark@BIGDATA.COM)s/.*/spark/
      RULE:[2:$1@$0](HTTP@BIGDATA.COM)s/.*/HTTP/
      RULE:[1:$1@$0](.*@BIGDATA.COM)s/@BIGDATA.COM//
      DEFAULT
    </value>
  </property>
</configuration>
```

### 2.3 hdfs-site.xml

```xml
<configuration>
  <!-- NameNode -->
  <property>
    <name>dfs.namenode.kerberos.principal</name>
    <value>hdfs/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>dfs.namenode.keytab.file</name>
    <value>/etc/security/keytabs/hdfs.service.keytab</value>
  </property>
  <property>
    <name>dfs.web.authentication.kerberos.principal</name>
    <value>HTTP/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>dfs.web.authentication.kerberos.keytab</name>
    <value>/etc/security/keytabs/spnego.service.keytab</value>
  </property>

  <!-- DataNode -->
  <property>
    <name>dfs.datanode.kerberos.principal</name>
    <value>hdfs/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>dfs.datanode.keytab.file</name>
    <value>/etc/security/keytabs/hdfs.service.keytab</value>
  </property>
  <property>
    <name>dfs.datanode.address</name>
    <value>0.0.0.0:1019</value>     <!-- 必须 < 1024，否则 SASL 无效 -->
  </property>
  <property>
    <name>dfs.datanode.http.address</name>
    <value>0.0.0.0:1022</value>     <!-- 同上 -->
  </property>
  <property>
    <name>dfs.data.transfer.protection</name>
    <value>integrity</value>         <!-- DN 数据传输保护级别 -->
  </property>

  <!-- JournalNode -->
  <property>
    <name>dfs.journalnode.kerberos.principal</name>
    <value>hdfs/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>dfs.journalnode.keytab.file</name>
    <value>/etc/security/keytabs/hdfs.service.keytab</value>
  </property>
  <property>
    <name>dfs.journalnode.kerberos.internal.spnego.principal</name>
    <value>HTTP/_HOST@BIGDATA.COM</value>
  </property>

  <!-- BlockToken -->
  <property>
    <name>dfs.block.access.token.enable</name>
    <value>true</value>
  </property>
</configuration>
```

### 2.4 DataNode 启动特殊处理

DataNode 监听 < 1024 端口（特权端口），有两种方案：

#### 方案 A：jsvc 启动（CDH/HDP 老方案）

```bash
# /etc/default/hadoop-hdfs-datanode
export HADOOP_SECURE_DN_USER=hdfs
export JSVC_HOME=/usr/lib/bigtop-utils
export HADOOP_SECURE_DN_PID_DIR=/var/run/hadoop-hdfs
export HADOOP_SECURE_DN_LOG_DIR=/var/log/hadoop-hdfs
```

#### 方案 B：SASL（Hadoop 2.6+ 推荐）

```xml
<!-- hdfs-site.xml -->
<property>
  <name>dfs.data.transfer.protection</name>
  <value>integrity</value>
</property>
<property>
  <name>dfs.datanode.address</name>
  <value>0.0.0.0:9866</value>      <!-- 任意非特权端口 -->
</property>
<property>
  <name>dfs.datanode.http.address</name>
  <value>0.0.0.0:9864</value>
</property>
```

### 2.5 验证

```bash
# 用 hdfs 用户 kinit
sudo -u hdfs kinit -kt /etc/security/keytabs/hdfs.service.keytab hdfs/$(hostname -f)@BIGDATA.COM
hdfs dfs -ls /

# Web UI（需要浏览器配 SPNEGO）
curl --negotiate -u : http://nn01.bigdata.com:9870/jmx
```

---

## 三、YARN Kerberos 集成

### 3.1 yarn-site.xml

```xml
<configuration>
  <!-- ResourceManager -->
  <property>
    <name>yarn.resourcemanager.principal</name>
    <value>yarn/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>yarn.resourcemanager.keytab</name>
    <value>/etc/security/keytabs/yarn.service.keytab</value>
  </property>
  <property>
    <name>yarn.resourcemanager.webapp.spnego-principal</name>
    <value>HTTP/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>yarn.resourcemanager.webapp.spnego-keytab-file</name>
    <value>/etc/security/keytabs/spnego.service.keytab</value>
  </property>

  <!-- NodeManager -->
  <property>
    <name>yarn.nodemanager.principal</name>
    <value>yarn/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>yarn.nodemanager.keytab</name>
    <value>/etc/security/keytabs/yarn.service.keytab</value>
  </property>
  <property>
    <name>yarn.nodemanager.webapp.spnego-principal</name>
    <value>HTTP/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>yarn.nodemanager.webapp.spnego-keytab-file</name>
    <value>/etc/security/keytabs/spnego.service.keytab</value>
  </property>

  <!-- 必须使用 LinuxContainerExecutor 才能保证容器以提交者身份运行 -->
  <property>
    <name>yarn.nodemanager.container-executor.class</name>
    <value>org.apache.hadoop.yarn.server.nodemanager.LinuxContainerExecutor</value>
  </property>
  <property>
    <name>yarn.nodemanager.linux-container-executor.group</name>
    <value>hadoop</value>
  </property>
  <property>
    <name>yarn.nodemanager.linux-container-executor.path</name>
    <value>/usr/lib/hadoop-yarn/bin/container-executor</value>
  </property>

  <!-- TimelineServer -->
  <property>
    <name>yarn.timeline-service.principal</name>
    <value>yarn/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>yarn.timeline-service.keytab</name>
    <value>/etc/security/keytabs/yarn.service.keytab</value>
  </property>
</configuration>
```

### 3.2 LinuxContainerExecutor 配置

```bash
# /etc/hadoop/container-executor.cfg
yarn.nodemanager.linux-container-executor.group=hadoop
banned.users=hdfs,yarn,mapred,bin
min.user.id=1000
allowed.system.users=
feature.tc.enabled=false

# 权限要求（NodeManager 启动会校验）
chown root:hadoop /usr/lib/hadoop-yarn/bin/container-executor
chmod 6050 /usr/lib/hadoop-yarn/bin/container-executor    # SetUID + SetGID
chmod 400 /etc/hadoop/container-executor.cfg
chown root:hadoop /etc/hadoop/container-executor.cfg
```

> ⚠️ **container-executor 必须 6050 权限**（root setuid + group rx），否则启动报 `LinuxContainerExecutor: not configured properly`

---

## 四、MapReduce / JobHistoryServer

### 4.1 mapred-site.xml

```xml
<configuration>
  <property>
    <name>mapreduce.jobhistory.principal</name>
    <value>mapred/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>mapreduce.jobhistory.keytab</name>
    <value>/etc/security/keytabs/mapred.service.keytab</value>
  </property>
  <property>
    <name>mapreduce.jobhistory.webapp.spnego-principal</name>
    <value>HTTP/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>mapreduce.jobhistory.webapp.spnego-keytab-file</name>
    <value>/etc/security/keytabs/spnego.service.keytab</value>
  </property>
</configuration>
```

---

## 五、Hive Metastore + HiveServer2

### 5.1 hive-site.xml（Metastore）

```xml
<configuration>
  <property>
    <name>hive.metastore.sasl.enabled</name>
    <value>true</value>
  </property>
  <property>
    <name>hive.metastore.kerberos.principal</name>
    <value>hive/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>hive.metastore.kerberos.keytab.file</name>
    <value>/etc/security/keytabs/hive.service.keytab</value>
  </property>
</configuration>
```

### 5.2 hive-site.xml（HiveServer2）

```xml
<configuration>
  <!-- HS2 接受 Kerberos 客户端连接 -->
  <property>
    <name>hive.server2.authentication</name>
    <value>KERBEROS</value>
  </property>
  <property>
    <name>hive.server2.authentication.kerberos.principal</name>
    <value>hive/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>hive.server2.authentication.kerberos.keytab</name>
    <value>/etc/security/keytabs/hive.service.keytab</value>
  </property>

  <!-- HS2 SPNEGO（Web UI / HTTP 协议下的 JDBC） -->
  <property>
    <name>hive.server2.authentication.spnego.principal</name>
    <value>HTTP/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>hive.server2.authentication.spnego.keytab</name>
    <value>/etc/security/keytabs/spnego.service.keytab</value>
  </property>

  <!-- HS2 模拟用户：Doas -->
  <property>
    <name>hive.server2.enable.doAs</name>
    <value>true</value>
    <!-- true：以连接用户身份执行；false：所有查询都以 hive 身份运行（用于 LLAP / Ranger） -->
  </property>

  <!-- HS2 -> Metastore 走 Kerberos -->
  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://hms01.bigdata.com:9083</value>
  </property>
</configuration>
```

### 5.3 HiveServer2 JDBC 连接串

#### Binary 模式（默认）

```
jdbc:hive2://hs2.bigdata.com:10000/default;principal=hive/hs2.bigdata.com@BIGDATA.COM
```

#### HTTP 模式（透 Knox / 走 LB）

```
jdbc:hive2://hs2.bigdata.com:10001/default;principal=hive/hs2.bigdata.com@BIGDATA.COM;transportMode=http;httpPath=cliservice
```

#### Beeline 命令

```bash
# 客户端先 kinit
kinit alice
beeline -u "jdbc:hive2://hs2.bigdata.com:10000/default;principal=hive/_HOST@BIGDATA.COM"
```

> ⚠️ JDBC URL 中的 principal 是**服务端 SPN**，不是客户端用户

---

## 六、Spark Kerberos 集成

### 6.1 spark-defaults.conf

```ini
# Kerberos 基础
spark.yarn.principal               spark/_HOST@BIGDATA.COM
spark.yarn.keytab                  /etc/security/keytabs/spark.service.keytab

# 对接 HMS（让 Spark SQL 拿 Hive Token）
spark.sql.hive.metastore.version   3.1.2
spark.sql.hive.metastore.jars      builtin
spark.kerberos.access.hadoopFileSystems  hdfs://nn.bigdata.com:8020
```

### 6.2 spark-submit（长任务）

```bash
spark-submit \
  --master yarn \
  --deploy-mode cluster \
  --principal spark/spark.bigdata.com@BIGDATA.COM \
  --keytab /etc/security/keytabs/spark.service.keytab \
  --conf spark.kerberos.access.hadoopFileSystems=hdfs://nn.bigdata.com:8020,hdfs://nn02.bigdata.com:8020 \
  --conf spark.sql.hive.metastore.uris=thrift://hms01.bigdata.com:9083 \
  --class com.example.MyApp \
  myapp.jar
```

> ⚠️ **长任务必须传 --keytab**：让 AM 端用 keytab 不断刷新 token；只 kinit 不传 keytab，跑到 7 天后必死

### 6.3 Spark Thrift Server（STS）

```bash
$SPARK_HOME/sbin/start-thriftserver.sh \
  --master yarn \
  --principal spark/sts.bigdata.com@BIGDATA.COM \
  --keytab /etc/security/keytabs/spark.service.keytab \
  --hiveconf hive.server2.thrift.bind.host=sts.bigdata.com \
  --hiveconf hive.server2.thrift.port=10010 \
  --hiveconf hive.server2.authentication=KERBEROS \
  --hiveconf hive.server2.authentication.kerberos.principal=spark/_HOST@BIGDATA.COM \
  --hiveconf hive.server2.authentication.kerberos.keytab=/etc/security/keytabs/spark.service.keytab
```

---

## 七、Kyuubi Kerberos 集成

### 7.1 kyuubi-defaults.conf

```ini
kyuubi.authentication                          KERBEROS
kyuubi.kinit.principal                         kyuubi/_HOST@BIGDATA.COM
kyuubi.kinit.keytab                            /etc/security/keytabs/kyuubi.service.keytab

# Kyuubi Engine 子进程也要 kerberized
spark.yarn.principal                           kyuubi/_HOST@BIGDATA.COM
spark.yarn.keytab                              /etc/security/keytabs/kyuubi.service.keytab

# Kyuubi 多租户：以提交用户身份启 Engine
kyuubi.engine.share.level                      USER
kyuubi.engine.user.isolated.spark.conf.options  --proxy-user

# HMS 对接
spark.sql.hive.metastore.uris                  thrift://hms01.bigdata.com:9083
spark.kerberos.access.hadoopFileSystems        hdfs://nn.bigdata.com:8020
```

### 7.2 Kyuubi 多用户代理 + Hadoop ProxyUser

```xml
<!-- core-site.xml on NN/RM -->
<property>
  <name>hadoop.proxyuser.kyuubi.hosts</name>
  <value>*</value>
</property>
<property>
  <name>hadoop.proxyuser.kyuubi.groups</name>
  <value>*</value>
</property>

<!-- hive-site.xml on HMS -->
<property>
  <name>hadoop.proxyuser.kyuubi.hosts</name>
  <value>*</value>
</property>
<property>
  <name>hadoop.proxyuser.kyuubi.groups</name>
  <value>*</value>
</property>
```

> Kyuubi 用自己的 keytab 拿 token，再代理（impersonate）成实际用户提交查询

---

## 八、HBase Kerberos 集成

### 8.1 hbase-site.xml

```xml
<configuration>
  <property>
    <name>hbase.security.authentication</name>
    <value>kerberos</value>
  </property>
  <property>
    <name>hbase.security.authorization</name>
    <value>true</value>
  </property>
  <property>
    <name>hbase.master.kerberos.principal</name>
    <value>hbase/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>hbase.master.keytab.file</name>
    <value>/etc/security/keytabs/hbase.service.keytab</value>
  </property>
  <property>
    <name>hbase.regionserver.kerberos.principal</name>
    <value>hbase/_HOST@BIGDATA.COM</value>
  </property>
  <property>
    <name>hbase.regionserver.keytab.file</name>
    <value>/etc/security/keytabs/hbase.service.keytab</value>
  </property>
  <property>
    <name>hbase.coprocessor.region.classes</name>
    <value>org.apache.hadoop.hbase.security.token.TokenProvider,org.apache.hadoop.hbase.security.access.AccessController</value>
  </property>
</configuration>
```

### 8.2 hbase-env.sh + jaas

```ini
# hbase-jaas.conf
Client {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    keyTab="/etc/security/keytabs/hbase.service.keytab"
    principal="hbase/_HOST@BIGDATA.COM"
    storeKey=true
    useTicketCache=false;
};
```

```bash
# hbase-env.sh
export HBASE_OPTS="-Djava.security.auth.login.config=/etc/hbase/conf/hbase-jaas.conf"
```

---

## 九、Kafka Kerberos 集成

### 9.1 server.properties

```ini
listeners=SASL_PLAINTEXT://kafka01.bigdata.com:9092
advertised.listeners=SASL_PLAINTEXT://kafka01.bigdata.com:9092
security.inter.broker.protocol=SASL_PLAINTEXT
sasl.mechanism.inter.broker.protocol=GSSAPI
sasl.enabled.mechanisms=GSSAPI
sasl.kerberos.service.name=kafka
authorizer.class.name=kafka.security.authorizer.AclAuthorizer
super.users=User:kafka
```

### 9.2 kafka_server_jaas.conf

```ini
KafkaServer {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    storeKey=true
    keyTab="/etc/security/keytabs/kafka.service.keytab"
    principal="kafka/kafka01.bigdata.com@BIGDATA.COM";
};

Client {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    storeKey=true
    keyTab="/etc/security/keytabs/kafka.service.keytab"
    principal="kafka/kafka01.bigdata.com@BIGDATA.COM";
};
```

### 9.3 启动时加载

```bash
# kafka-run-class.sh 或环境变量
export KAFKA_OPTS="-Djava.security.auth.login.config=/etc/kafka/kafka_server_jaas.conf"
```

### 9.4 客户端配置

```ini
# producer.properties / consumer.properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=GSSAPI
sasl.kerberos.service.name=kafka
sasl.jaas.config=com.sun.security.auth.module.Krb5LoginModule required \
  useKeyTab=true \
  keyTab="/etc/security/keytabs/client.keytab" \
  principal="alice@BIGDATA.COM";
```

---

## 十、ZooKeeper Kerberos 集成

### 10.1 zoo.cfg

```ini
authProvider.1=org.apache.zookeeper.server.auth.SASLAuthenticationProvider
jaasLoginRenew=3600000
kerberos.removeHostFromPrincipal=true
kerberos.removeRealmFromPrincipal=true
```

### 10.2 zk-server.jaas

```ini
Server {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    keyTab="/etc/security/keytabs/zookeeper.service.keytab"
    storeKey=true
    useTicketCache=false
    principal="zookeeper/_HOST@BIGDATA.COM";
};
```

### 10.3 zkServer.sh 启动加 JAAS

```bash
export SERVER_JVMFLAGS="-Djava.security.auth.login.config=/etc/zookeeper/conf/zk-server.jaas"
```

### 10.4 客户端 jaas

```ini
Client {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    keyTab="/etc/security/keytabs/zk-client.keytab"
    storeKey=true
    useTicketCache=false
    principal="zk-client@BIGDATA.COM";
};
```

---

## 十一、Ranger Kerberos 集成

### 11.1 ranger-admin install.properties

```ini
authentication_method=KERBEROS
spnego_principal=HTTP/_HOST@BIGDATA.COM
spnego_keytab=/etc/security/keytabs/spnego.service.keytab

admin_principal=rangeradmin/_HOST@BIGDATA.COM
admin_keytab=/etc/security/keytabs/rangeradmin.service.keytab

lookup_principal=rangerlookup/_HOST@BIGDATA.COM
lookup_keytab=/etc/security/keytabs/rangerlookup.service.keytab
```

### 11.2 各 Plugin（HDFS / Hive / HBase 等）

每个 Plugin 都需要：

```ini
# 例：ranger-hive-plugin
POLICY_MGR_URL=http://ranger-admin:6080
REPOSITORY_NAME=cm_hive
POLICY_USER=ranger

# Kerberos 集成 — Plugin 用什么身份去拉策略
SSL_TRUSTSTORE_FILE_PATH=/etc/ranger/security/cacerts.jks
COMPONENT_PRINCIPAL=hive/_HOST@BIGDATA.COM
COMPONENT_KEYTAB=/etc/security/keytabs/hive.service.keytab
```

### 11.3 Ranger 用户同步

如果走 LDAP/AD：Ranger UserSync 配置 LDAP 连接，定时拉用户/组。Kerberos 这层只管认证，**用户/组信息从 LDAP 拿**。

---

## 十二、Impala Kerberos 集成

```ini
# impalad / catalogd / statestored 启动参数

--kerberos_reinit_interval=60
--principal=impala/_HOST@BIGDATA.COM
--keytab_file=/etc/security/keytabs/impala.service.keytab

# Web UI
--webserver_authentication_domain=BIGDATA.COM
--webserver_certificate_file=/etc/impala/conf/cert.pem
--webserver_private_key_file=/etc/impala/conf/key.pem
```

---

## 十三、跨组件 Token 流转一览

```
                ┌──────────┐
                │  Client  │ kinit → TGT
                └────┬─────┘
                     │ TGT
        ┌────────────┼─────────────┬──────────────┬───────────────┐
        ▼            ▼             ▼              ▼               ▼
   ┌────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
   │HDFS NN │  │ YARN RM  │  │   HMS    │  │   HS2    │  │  Kafka   │
   └───┬────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────────┘
       │ HDFS_TOKEN │ RM_TOKEN    │ HIVE_TOKEN  │
       └────────────┴─────────────┴─────────────┘
                     │
                     ▼
              ┌─────────────┐
              │  YARN AM    │  把所有 token 注入到 Container
              │  / Driver   │
              └──────┬──────┘
                     │
                     ▼
              ┌─────────────┐
              │  Executor   │  用 token 访问 HDFS / HMS（不走 KDC）
              └─────────────┘
```

> **AM 用 keytab 后台续 token**，所以长任务必须传 `--keytab`

---

## 十四、集成验收清单

每接入一个组件，必须跑完：

- [ ] kinit 成功
- [ ] klist 看到 TGT
- [ ] 能用客户端命令访问服务（hdfs ls / yarn application list / beeline 连接）
- [ ] Web UI 用 SPNEGO 浏览器能打开
- [ ] kdestroy 后访问失败（证明确实在认证）
- [ ] keytab KVNO 与 KDC 一致
- [ ] 提交一个 YARN 任务，跨节点执行成功
- [ ] 跑超过 24 小时的长任务（验证 Token 续期）

---

*Eric · 大数据 SRE AI 专家团队 · 知识晶体化 v1.0*
