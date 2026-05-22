# Kerberos 日志分析速查表

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> 一行命令 · 直击根因 · 不需要进 ELK / Grafana

---

## 一、Hadoop 服务日志位置

| 服务 | 日志路径（典型） |
|------|----------------|
| HDFS NameNode | `/var/log/hadoop-hdfs/hadoop-hdfs-namenode-*.log` |
| HDFS DataNode | `/var/log/hadoop-hdfs/hadoop-hdfs-datanode-*.log` |
| YARN ResourceManager | `/var/log/hadoop-yarn/yarn-yarn-resourcemanager-*.log` |
| YARN NodeManager | `/var/log/hadoop-yarn/yarn-yarn-nodemanager-*.log` |
| MR JobHistoryServer | `/var/log/hadoop-mapreduce/mapred-mapred-historyserver-*.log` |
| Hive HS2 | `/var/log/hive/hiveserver2.log` |
| Hive Metastore | `/var/log/hive/hivemetastore.log` |
| HBase Master | `/var/log/hbase/hbase-hbase-master-*.log` |
| HBase RegionServer | `/var/log/hbase/hbase-hbase-regionserver-*.log` |
| Spark History | `/var/log/spark/spark-spark-org.apache.spark.deploy.history.HistoryServer-*.log` |
| Kafka | `/var/log/kafka/server.log` |
| ZooKeeper | `/var/log/zookeeper/zookeeper.log` |
| Kyuubi | `/var/log/kyuubi/kyuubi-*.log` |
| Ranger Admin | `/var/log/ranger/admin/xa_portal.log` |
| **KDC 自身** | `/var/log/krb5kdc.log` |
| **kadmin** | `/var/log/kadmind.log` |
| **krb5 库** | `/var/log/krb5libs.log` |

---

## 二、客户端日志位置

| 客户端 | 日志位置 |
|-------|---------|
| `kinit -V` | stdout |
| `KRB5_TRACE` | 你指定的文件（推荐 `/dev/stderr`） |
| Java 程序 `-Dsun.security.krb5.debug=true` | stderr |
| Beeline | `~/.beeline/logs/` 或 stdout |
| Spark Driver | YARN logs / `~/.spark/` |
| Hadoop CLI | stdout（要加 HADOOP_OPTS） |

---

## 三、关键正则速查

### 3.1 一行命令找所有 Kerberos 错误

```bash
# 单文件
grep -iE "kerberos|gssexception|krbexception|sasl|spnego|keytab|kinit|kdc|tgt|principal|-176532" /var/log/hadoop-hdfs/*.log

# 多目录递归
grep -riE --include="*.log" "krb|gss|sasl" /var/log/hadoop*/

# 仅看错误（带 ERROR/WARN）
grep -iE "ERROR.*krb|ERROR.*gss|ERROR.*sasl" /var/log/hadoop-*/*.log
```

### 3.2 按错误分类的 grep 模板

```bash
# 时间问题
grep -i "Clock skew\|Ticket not yet valid\|Defective token" *.log

# 网络问题
grep -i "Cannot contact.*KDC\|UnknownHostException\|Connection refused.*88\|Receive timed out" *.log

# 密钥问题
grep -i "Pre-?authentication\|Specified version of key\|Decrypt integrity\|Cannot find key\|Encryption type.*not supported" *.log

# Principal 问题
grep -i "Server not found\|Client not found\|invalid Kerberos principal\|UNKNOWN_SERVER\|PREAUTH_FAILED" *.log

# Login/Token 问题
grep -i "No valid credentials\|Failed to find any.*tgt\|No LoginModules\|Unable to obtain password\|Login failure\|InvalidToken\|token.*expired" *.log

# 配置问题
grep -i "Cannot authenticate via\|SIMPLE auth.*not enabled\|impersonate" *.log
```

### 3.3 错误码精准定位

```bash
# 所有 Kerberos 错误码
grep -oE "\-1765328[0-9]{3}" *.log | sort | uniq -c | sort -rn

# 输出示例：
#   42 -1765328359   ← Clock skew 最多
#   15 -1765328230   ← KVNO 不一致
#    3 -1765328353   ← Server not found
```

---

## 四、KDC 服务端日志分析（最重要）

### 4.1 KDC 日志格式

```
Jan 15 10:23:45 kdc01 krb5kdc[1234]: AS_REQ (8 etypes ...) 10.0.0.5: ISSUE: authtime 1234567890, etypes {18}, alice@BIGDATA.COM for krbtgt/BIGDATA.COM@BIGDATA.COM
                                          ↑                    ↑                    ↑              ↑                    ↑
                                          客户端IP              动作                时间            Client Principal     SPN
```

### 4.2 关键事件 grep

```bash
# 看认证成功率
grep -c "ISSUE" /var/log/krb5kdc.log
grep -c "FAILED\|UNKNOWN" /var/log/krb5kdc.log

# 失败的请求（按客户端 IP 排序）
grep -E "PREAUTH_FAILED|UNKNOWN_SERVER|UNKNOWN_CLIENT" /var/log/krb5kdc.log | \
    awk -F'[][:]' '{print $5}' | sort | uniq -c | sort -rn | head -10

# 频繁失败的 IP（DDoS / 攻击 / 故障客户端）
grep "FAILED" /var/log/krb5kdc.log | \
    grep -oP '(\d+\.){3}\d+' | sort | uniq -c | sort -rn | head -10

# 谁的 AS_REQ 失败最多
grep "AS_REQ.*FAILED" /var/log/krb5kdc.log | \
    grep -oP '\b\w+@[A-Z0-9.]+\b' | sort | uniq -c | sort -rn | head -10

# 哪些 SPN 不存在被疯狂请求
grep "UNKNOWN_SERVER" /var/log/krb5kdc.log | \
    grep -oP 'for \K[^ ]+' | sort | uniq -c | sort -rn | head
```

### 4.3 KDC 性能分析

```bash
# QPS 趋势（每分钟）
awk '/AS_REQ|TGS_REQ/{print substr($0,1,16)}' /var/log/krb5kdc.log | \
    sort | uniq -c | tail -20

# 高峰期 QPS
awk '/AS_REQ|TGS_REQ/{print substr($0,1,16)}' /var/log/krb5kdc.log | \
    sort | uniq -c | sort -rn | head -5

# 单客户端调用频率（找异常）
awk '/AS_REQ|TGS_REQ/{
    match($0, /[0-9.]+\.[0-9.]+/)
    ip = substr($0, RSTART, RLENGTH)
    print ip
}' /var/log/krb5kdc.log | sort | uniq -c | sort -rn | head -20
```

---

## 五、KRB5_TRACE 日志解析

### 5.1 关键事件提取

```bash
# 抓现场
KRB5_TRACE=/tmp/trace.log kinit -V principal

# 看请求/响应
grep -E "Sending|Received" /tmp/trace.log

# 看选了什么 enctype
grep -oP "Selected etype info: etype \K\d+" /tmp/trace.log
# 18 = aes256-cts-hmac-sha1-96
# 17 = aes128-cts-hmac-sha1-96
# 16 = des3-cbc-sha1
# 23 = arcfour-hmac (RC4)

# 看错误码
grep -oP "Received error from KDC: \K-?\d+" /tmp/trace.log

# 看 KDC 路由（fail-over 行为）
grep "KdcAccessibility" /tmp/trace.log
```

### 5.2 完整事件链 grep

```bash
grep -E "(Sending|Received|Decoded|tkt_creds|Selected|error)" /tmp/trace.log
```

输出像这样：
```
[xxx] Sending TCP request to stream kdc01.bigdata.com:88
[xxx] Received answer (320 bytes) from stream kdc01.bigdata.com:88
[xxx] Selected etype info: etype 18, salt "BIGDATA.COMalice"
[xxx] Decoded AS-REP
[xxx] tkt_creds: requesting ticket for hdfs/nn01.bigdata.com@BIGDATA.COM
[xxx] Decoded TGS-REP
```

---

## 六、Java 客户端 debug 日志

### 6.1 启用方式

```bash
# Hadoop 命令
HADOOP_OPTS="-Dsun.security.krb5.debug=true \
             -Dsun.security.spnego.debug=true \
             -Djava.security.debug=gssloginconfig,configfile,configparser,logincontext" \
hdfs dfs -ls /

# Spark
spark-submit \
    --conf spark.driver.extraJavaOptions=-Dsun.security.krb5.debug=true \
    --conf spark.executor.extraJavaOptions=-Dsun.security.krb5.debug=true \
    ...
```

### 6.2 关键日志 grep

```bash
# 加载的配置文件
grep "Java config name" *.log
grep "Loaded from" *.log

# 协商的 enctype
grep "default etypes" *.log

# AS_REQ / AS_REP
grep ">>> KrbAsReq" *.log
grep ">>> KrbAsRep" *.log

# TGS_REQ / TGS_REP
grep ">>> KrbTgsReq" *.log
grep ">>> KrbTgsRep" *.log

# 认证成功
grep "Found ticket for" *.log
grep "Default principal" *.log

# 失败
grep "KrbException\|GSSException" *.log

# KDC 选择（fail-over）
grep "KdcAccessibility:" *.log

# JAAS 加载
grep "Krb5LoginModule" *.log
```

### 6.3 完整成功流程示意

```
Java config name: /etc/krb5.conf       ← 加载配置
Loaded from Java config
default etypes for default_tkt_enctypes: 18 17 16 23.   ← 客户端支持
>>> KrbAsReq creating message            ← 构造 AS_REQ
>>>KrbKdcReq send: kdc=kdc01 TCP:88     ← 发送
>>>KrbKdcReq send: #bytes read=312      ← 收到
>>>KdcAccessibility: remove kdc01       ← KDC 可用
>>> KrbAsRep cons in KrbAsReq.getReply  ← 解析响应
Found ticket for alice@REALM            ← 拿到 TGT
```

---

## 七、Hadoop UGI 日志

### 7.1 UGI 关键事件

```bash
# 服务启动时的登录
grep "UserGroupInformation.*Login successful for user" *.log

# 自动 relogin
grep "UserGroupInformation.*Initiating logout for" *.log
grep "UserGroupInformation.*Initiating re-login for" *.log

# Token 续期
grep "DelegationTokenRenewer" *.log
grep "Renewing token" *.log
grep "Token.*renewed" *.log

# Token 过期
grep "Token.*expired\|InvalidToken" *.log
```

---

## 八、按场景定位的一行命令

### 8.1 场景：服务启动失败

```bash
# 看启动时的 Kerberos 错误
journalctl -u hadoop-hdfs-namenode --since "10 minutes ago" | grep -iE "krb|gss|login"

# 或
tail -n 200 /var/log/hadoop-hdfs/hadoop-hdfs-namenode-*.log | \
    grep -iE "krb|gss|sasl|login|principal|keytab" | tail -20
```

### 8.2 场景：用户提交任务失败

```bash
# 该用户的 RM 日志
yarn logs -applicationId <appId> 2>&1 | \
    grep -iE "krb|gss|sasl|token" | head -20
```

### 8.3 场景：HiveServer2 连接拒绝

```bash
# HS2 端
tail -100 /var/log/hive/hiveserver2.log | grep -iE "krb|gss|sasl|login|spnego"

# 客户端开调试
beeline -d com.cloudera.hive.jdbc4.HS2Driver -u "jdbc:hive2://...;LogLevel=6"
```

### 8.4 场景：Web UI 401

```bash
# 服务端
tail -100 /var/log/hadoop-hdfs/hadoop-hdfs-namenode-*.log | grep -iE "spnego|http.*auth"

# 客户端测试
curl -v --negotiate -u : http://nn:9870/jmx 2>&1 | head -30
```

### 8.5 场景：cron / systemd 任务认证失败

```bash
# systemd 服务的环境变量
systemctl show <service> | grep -i krb

# cron 任务（环境变量缺失）
grep CRON /var/log/syslog | grep -i kerb
```

---

## 九、批量节点日志聚合

### 9.1 ansible 一键拉取

```bash
# 拉取所有节点最近的 Kerberos 错误
ansible all -m shell -a "tail -1000 /var/log/hadoop-*/*.log 2>/dev/null | grep -iE 'gssexception|krbexception' | tail -3" | \
    grep -B1 "krb\|gss"
```

### 9.2 关键字命中数全集群统计

```bash
ansible all -m shell -a "grep -cE 'GSSException|KrbException|Clock skew' /var/log/hadoop-*/*.log 2>/dev/null | grep -v ':0' | head -5" | \
    grep -E ":\d+" | sort -t: -k2 -rn
```

### 9.3 用 logstash / fluentd 集中

如果用了 ELK：

```
# Kibana 查询语句
message: ("GSSException" OR "KrbException" OR "Clock skew" OR "Specified version of key")

# 时间窗：最近 1 小时
# 分组：service.name
# 显示：error_count
```

---

## 十、awk / sed 高级技巧

### 10.1 提取错误堆栈（多行）

```bash
# 提取 GSSException 完整堆栈（直到下一个时间戳）
awk '/GSSException/,/^[0-9]{4}-[0-9]{2}-[0-9]{2}/' /var/log/hadoop-hdfs/*.log

# 或者提取连续 20 行
grep -A20 "GSSException" /var/log/hadoop-hdfs/*.log
```

### 10.2 按时间段过滤

```bash
# 最近 1 小时（log 格式 ISO8601）
awk -v cutoff="$(date -d '1 hour ago' '+%Y-%m-%d %H:%M')" '$1 " " $2 > cutoff' \
    /var/log/hadoop-hdfs/*.log | grep -i krb

# 特定时间段
awk '/2026-05-10 09:00/,/2026-05-10 10:00/' /var/log/hadoop-hdfs/*.log | grep -i krb
```

### 10.3 报错频率分析

```bash
# 按分钟统计 GSSException 数量
awk '/GSSException/{print substr($0,1,16)}' /var/log/hadoop-hdfs/*.log | \
    sort | uniq -c | sort -rn | head -20

# 按小时
awk '/GSSException/{print substr($0,1,13)}' /var/log/hadoop-hdfs/*.log | \
    sort | uniq -c
```

---

## 十一、日志分析最佳实践

### 11.1 三步定位法

```
Step 1: tail + grep 看最近错误
Step 2: 定位时间点 → awk 提取该时段全部上下文
Step 3: 找 caused by 链 → 找到根因
```

### 11.2 避免误判

| 表象 | 容易误判 | 真实原因 |
|------|---------|---------|
| `Failed login` | 密码错 | 50% 是 KVNO |
| `GSSException` | Kerberos 故障 | 看 caused by 才知道 |
| `Connection refused` | KDC 挂 | 可能是端口/防火墙 |
| `401 Unauthorized` | 服务端问题 | 多半是浏览器 |
| `Permission denied` | 认证问题 | 可能是授权（Ranger） |

### 11.3 留证关键

故障期必须保存：
- [ ] 时间戳（精确到秒）
- [ ] 客户端 IP / hostname
- [ ] 服务端日志（前后 5 分钟）
- [ ] KRB5_TRACE 完整文件
- [ ] sun.security.krb5.debug 输出
- [ ] kdc.log 同时段
- [ ] `klist`、`kvno`、`klist -kt` 输出

---

## 十二、Cheat Sheet（贴墙）

```
┌─────────────────────────────────────────────────────────────────┐
│ Kerberos 日志分析 Cheat Sheet                                    │
├─────────────────────────────────────────────────────────────────┤
│ 一键扫错误：                                                      │
│   bash kerb-log-grep.sh                                          │
├─────────────────────────────────────────────────────────────────┤
│ 关键 grep：                                                       │
│   grep -iE "krb|gss|sasl" *.log                                  │
│   grep -oE "\-1765328[0-9]{3}" *.log | sort | uniq -c            │
├─────────────────────────────────────────────────────────────────┤
│ KRB5_TRACE 看 5 件事：                                            │
│   Sending     → 请求发往哪                                        │
│   Received    → 响应是什么                                        │
│   Selected    → enctype 协商                                      │
│   Salt        → 密钥派生                                          │
│   error       → 具体错误                                          │
├─────────────────────────────────────────────────────────────────┤
│ KDC 日志 5 个字段：                                               │
│   时间戳 KDC机器 进程[PID] 动作 客户端IP 状态 主体 SPN              │
├─────────────────────────────────────────────────────────────────┤
│ Java debug 启用：                                                 │
│   -Dsun.security.krb5.debug=true                                 │
│   -Dsun.security.spnego.debug=true                               │
└─────────────────────────────────────────────────────────────────┘
```

---

*Eric · 大数据 SRE AI 专家团队 · 日志速查 v1.0*
