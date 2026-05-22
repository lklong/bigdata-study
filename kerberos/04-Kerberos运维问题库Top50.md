# Kerberos 运维问题库 Top 50

> 大数据 SRE 必修课 · Eric · 2026-05-09  
> 真实生产环境踩坑总集 · 按错误码 / 现象 / 场景三维分类 · **Eric 在多个项目踩过的坑**

---

## 索引：按现象快速定位

| 类别 | 问题数 | 关键词 |
|------|-------|--------|
| **A. 时间相关** | 5 | Clock skew |
| **B. Principal/Keytab** | 8 | KVNO/keytab/principal not found |
| **C. DNS / 主机名** | 6 | _HOST/FQDN/反解 |
| **D. Java/JCE/加密** | 5 | enctype/Illegal key size/JCE |
| **E. GSS API 错误** | 7 | GSSException/SASL/No credentials |
| **F. 跨域 Cross-Realm** | 4 | krbtgt/capaths |
| **G. 长任务/Token** | 5 | Token expired/renew |
| **H. 浏览器/SPNEGO** | 4 | 401/Negotiate |
| **I. 部署/启动** | 6 | KDC/kpropd/permission |

---

## A. 时间相关问题（最常见）

### A1. Clock skew too great

**现象**：
```
kinit: Clock skew too great while getting initial credentials
KrbException: Clock skew too great (37)
```

**根因**：客户端与 KDC 时间偏差 > 5 分钟（`clockskew=300s`）。

**排查**：
```bash
# 客户端
date
# KDC
ssh kdc01.bigdata.com date
# 偏差
clockdiff kdc01.bigdata.com
```

**根治**：
```bash
# 全集群部署 chrony，统一 NTP 源
yum install -y chrony
systemctl enable --now chronyd
chronyc tracking
chronyc sources -v

# 巡检脚本
for h in $(cat hosts.txt); do
    ssh $h "date +%s"
done | sort -u
# 输出多个值 → 时钟有偏差
```

**临时**：`ntpdate -s ntp.ntsc.ac.cn`

### A2. 时区不一致导致证票验证失败

**现象**：明明 ntp 同步了还报 clock skew

**根因**：UTC 与 CST 时区配置不同（`timedatectl` 检查）。Kerberos 用 UTC 时间戳，但日期命令显示本地时区，会让你以为时间一致。

**根治**：
```bash
timedatectl set-timezone Asia/Shanghai
hwclock --systohc
```

### A3. kvno 时报 KRB_AP_ERR_TKT_EXPIRED

**现象**：跑了一段时间的服务突然报票据过期

**根因**：服务进程的 UGI 没正确刷新 / 没启用 reloginFromKeytab

**临时**：重启服务进程

**根治**：检查代码是否调用 `UserGroupInformation.reloginFromKeytab()`，或在配置中确认 token-renewer 配置了

### A4. NodeManager 启动一段时间后批量挂

**现象**：NM 启动正常，运行 24 小时后大量挂

**根因**：YARN 的 LinuxContainerExecutor 没正确续期，TGT 7 天后过期就挂

**根治**：升级到 Hadoop 3.x，或手动每天 cron 重启 NM 错峰滚动

### A5. Spark 任务跑 5 天后 Token 过期

**现象**：
```
org.apache.hadoop.security.token.SecretManager$InvalidToken: 
token (HDFS_DELEGATION_TOKEN ...) is expired
```

**根因**：用 `kinit` 提交，没用 `--keytab`，token 7 天上限到了

**根治**：长任务必须传 `--keytab + --principal`

---

## B. Principal / Keytab 问题

### B1. Client not found in Kerberos database

**现象**：
```
kinit: Client 'alice@BIGDATA.COM' not found in Kerberos database
```

**根因**：principal 不存在

**排查**：
```bash
kadmin.local -q "listprincs" | grep alice
```

**根治**：
```bash
kadmin.local -q "addprinc alice"
```

### B2. Server not found in Kerberos database

**现象**：
```
GSSException: No valid credentials provided 
(Mechanism level: Server not found in Kerberos database (7))
```

**根因**：服务的 SPN 不存在（最常见：FQDN 不对）

**排查**：
```bash
# 看 KDC 是否有这个 SPN
kadmin.local -q "getprinc hdfs/nn01.bigdata.com"

# 看客户端实际请求的 SPN（开 KRB5_TRACE）
KRB5_TRACE=/dev/stderr hdfs dfs -ls /
# [xxx] sending TGS-REQ for hdfs/NN01.bigdata.com@BIGDATA.COM
#                                 ^^^^^ 大小写差异？
```

**根治**：
- 检查 hdfs-site.xml 中 `_HOST` 是否被解析为正确 FQDN（`hostname -f` 验证）
- 检查 KDC 中 SPN 大小写（Kerberos 区分大小写）
- 检查客户端 `/etc/hosts` 与 DNS 是否一致

### B3. Key version number mismatch (KVNO 不一致)

**现象**：
```
KrbException: Specified version of key is not available (44)
```

**根因**：keytab 的 KVNO 与 KDC 中的 KVNO 不一致

**排查**：
```bash
# keytab
klist -kt /etc/security/keytabs/hdfs.service.keytab | grep nn01
#  3 2026-05-09 ...   ← keytab 是 KVNO 3

# KDC
kvno hdfs/nn01.bigdata.com
# hdfs/nn01.bigdata.com@BIGDATA.COM: kvno = 5    ← KDC 是 KVNO 5
```

**根因深扒**：
- 有人在 KDC 上 `cpw -randkey` 改密码了 → KVNO+2（一次改一次）
- 但没把新 keytab 同步到对应主机

**根治**：
```bash
# 不变 KVNO 重新导出 keytab
kadmin.local -q "ktadd -norandkey -k /etc/security/keytabs/hdfs.service.keytab hdfs/nn01.bigdata.com"

# 分发到对应主机
scp /etc/security/keytabs/hdfs.service.keytab nn01:/etc/security/keytabs/
```

> ⚠️ **不带 `-norandkey` 直接 ktadd 会再生成新密码 KVNO+1**，可能让其他持有老 keytab 的服务全挂

### B4. ktadd 时 KVNO 跳过几个

**现象**：keytab 中 KVNO=10，但 KDC 中 KVNO=15

**根因**：每次 `ktadd`（不带 -norandkey）都会改密码 KVNO+1，被批量执行了多次

**根治**：建立 keytab 管理 SOP，必须用 `-norandkey` 或一次性导出

### B5. Pre-authentication information was invalid

**现象**：
```
kinit: Preauthentication failed while getting initial credentials
KrbException: Pre-authentication information was invalid (24)
```

**根因**：
1. 密码错误
2. keytab 中的密钥与 KDC 数据库不一致（KVNO 错乱 / enctype 不匹配）

**排查**：
```bash
# 1) 验证 keytab 与 KDC 一致
KRB5_TRACE=/dev/stderr kinit -V -kt /path/to/keytab principal@REALM
# 看 trace 中 "Salt: ..." 是否与 KDC 一致

# 2) 重新导出 keytab
kadmin.local -q "ktadd -norandkey -k /tmp/test.keytab hdfs/nn01.bigdata.com"
kinit -kt /tmp/test.keytab hdfs/nn01.bigdata.com@BIGDATA.COM
```

### B6. 删 principal 后 keytab 还在用

**现象**：服务挂了，报 principal 不存在，但管理员说没删

**根因**：曾经有 `delprinc` 操作（KDC 操作日志里能找到）

**根治**：
- 重新 `addprinc -randkey` + `ktadd -k`
- KDC 必须开操作日志（`/var/log/krb5kdc.log`）便于审计

### B7. keytab 文件权限错误导致服务启动失败

**现象**：
```
java.io.IOException: Login failure for hdfs/nn01.bigdata.com from keytab 
/etc/security/keytabs/hdfs.service.keytab: 
javax.security.auth.login.LoginException: Unable to obtain password from user
```

**根因**：进程用户读不到 keytab 文件

**排查**：
```bash
ls -l /etc/security/keytabs/hdfs.service.keytab
# 应该是 -r-------- 1 hdfs hadoop
```

**根治**：
```bash
chown hdfs:hadoop /etc/security/keytabs/hdfs.service.keytab
chmod 400 /etc/security/keytabs/hdfs.service.keytab
```

### B8. Keytab 中存在多个相同 SPN 但 enctype 不全

**现象**：能 kinit 成功，但访问服务时报 enctype 不支持

**根因**：keytab 缺少 KDC 要求的 enctype

**排查**：
```bash
klist -ket /path/to/keytab
# 看是否有 aes256-cts-hmac-sha1-96 这一行
```

**根治**：
```bash
kadmin.local -q "ktadd -e aes256-cts-hmac-sha1-96:normal,aes128-cts-hmac-sha1-96:normal -k /path/to/keytab principal"
```

---

## C. DNS / 主机名问题

### C1. _HOST 占位符没被替换

**现象**：服务启动报 principal 是 `hdfs/_HOST@BIGDATA.COM` 不存在

**根因**：进程拿不到 FQDN

**排查**：
```bash
hostname -f
# nn01.bigdata.com  ← 必须是 FQDN，不能只是 nn01
```

**根治**：
- 配置 `/etc/hostname` 为 FQDN
- 或在 `/etc/hosts` 中确保 IP → FQDN 映射在 IP → 短名前面

### C2. DNS 反解失败

**现象**：客户端能正解出 KDC，但报无法连接

**根因**：`rdns=true`（默认）触发反解，DNS 反解失败

**根治**：
```ini
# /etc/krb5.conf
[libdefaults]
    rdns = false
```

> 生产建议**永远关闭 rdns**

### C3. 多网卡导致 hostname -f 不一致

**现象**：HDFS 报 `hdfs/192.168.1.10@BIGDATA.COM` SPN 不存在

**根因**：进程绑了 IP，反解出来的不是预期的 hostname

**根治**：
```xml
<!-- core-site.xml -->
<property>
  <name>hadoop.rpc.bind.host</name>
  <value>0.0.0.0</value>
</property>
<!-- hdfs-site.xml -->
<property>
  <name>dfs.namenode.rpc-bind-host</name>
  <value>0.0.0.0</value>
</property>
```
让进程监听 0.0.0.0 但 advertise FQDN

### C4. /etc/hosts 与 DNS 不一致

**现象**：A 主机能认证，B 主机不行

**排查**：
```bash
ansible all -a "getent hosts kdc01.bigdata.com"
# 输出不一致 → /etc/hosts 各节点不同
```

**根治**：用 ansible/saltstack 统一 `/etc/hosts`，或全部走 DNS

### C5. 客户端在 Docker 容器中无 FQDN

**现象**：容器中 `hostname -f` 返回的是容器 ID，不是真实 FQDN

**根治**：
```bash
docker run --hostname client01.bigdata.com --add-host kdc01.bigdata.com:10.0.0.1 ...
# 或 K8s
hostAliases:
  - ip: 10.0.0.1
    hostnames: ["kdc01.bigdata.com"]
```

### C6. KDC 自身 hostname 没设 FQDN

**现象**：客户端连 KDC 报 `Cannot find KDC for realm`

**根因**：KDC 的 hostname 写错，krb5.conf 写的是 IP/短名

**根治**：krb5.conf 中 `kdc=kdc01.bigdata.com:88`（FQDN + 端口）

---

## D. Java / JCE / 加密问题

### D1. KrbException: Illegal key size

**现象**：Java 客户端连接失败
```
KrbException: Illegal key size
Caused by: java.security.InvalidKeyException: Illegal key size
```

**根因**：JCE 没装 Unlimited Strength Policy（Java 8 < 152）

**根治**：
```bash
# 检查
jrunscript -e 'print(javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))'
# 输出 128 → 限制版

# Java 8 < 152：下载 JCE Policy Files 替换 jar
# Java 8 >= 152：
sed -i 's/^#crypto.policy=unlimited/crypto.policy=unlimited/' \
    $JAVA_HOME/jre/lib/security/java.security

# Java 11+：默认开启
```

### D2. enctype 不支持

**现象**：
```
KrbException: Encryption type AES256 CTS mode with HMAC SHA1-96 is not supported/enabled
```

**根因**：krb5.conf 中 enctype 列表与 KDC/keytab 不一致

**根治**：统一三方 enctype（krb5.conf、kdc.conf、keytab）

### D3. RC4 算法被 KDC 禁用

**现象**：升级 Windows AD 后旧 keytab 突然失效

**根因**：MS 推送了禁用 RC4-HMAC 的安全策略

**根治**：升级 keytab，加入 AES enctypes
```bash
ktpass -princ user@CORP.COM -mapuser user -crypto AES256-SHA1 -ptype KRB5_NT_PRINCIPAL -pass * -out user.keytab
```

### D4. Java 版本不兼容（Java 17 与 Hadoop 2.x）

**现象**：升级 JDK17 后 Kerberos 报 `module java.security.jgss does not export ...`

**根因**：JDK 17 移除了内部 API 默认导出

**根治**：JVM 启动加
```bash
--add-opens java.security.jgss/sun.security.jgss=ALL-UNNAMED
--add-opens java.security.jgss/sun.security.jgss.krb5=ALL-UNNAMED
```

### D5. JAAS 配置文件未加载

**现象**：
```
javax.security.auth.login.LoginException: 
No LoginModules configured for Client
```

**根因**：JVM 启动没加 `-Djava.security.auth.login.config=...`

**根治**：
```bash
export HADOOP_OPTS="-Djava.security.auth.login.config=/etc/security/jaas.conf $HADOOP_OPTS"
```

---

## E. GSS API 错误（最高频）

### E1. GSSException: No valid credentials provided

**现象**：
```
GSSException: No valid credentials provided 
(Mechanism level: Failed to find any Kerberos tgt)
```

**根因前 5**：
1. 没 kinit
2. ccache 路径与进程不一致（`echo $KRB5CCNAME`）
3. ccache 在容器中是 KEYRING 类型而进程跨容器
4. 票据已过期
5. JAAS 没正确加载

**排查**：
```bash
echo $KRB5CCNAME
klist
klist -A
KRB5_TRACE=/dev/stderr <你的命令>
```

### E2. GSSException: Defective token detected

**现象**：
```
GSSException: Defective token detected (Mechanism level: AP_REP token id does not match!)
```

**根因**：客户端和服务端时钟不同步导致 token 校验失败 / replay cache 异常

**根治**：先查时钟，再清 replay cache
```bash
# 服务端
rm -rf /var/tmp/krb5_*_rcache
systemctl restart <service>
```

### E3. SASL negotiation failure

**现象**：
```
org.apache.hadoop.security.AccessControlException: 
Client cannot authenticate via:[TOKEN, KERBEROS]
```

**根因**：客户端没启用 Kerberos 认证

**根治**：
```bash
# 客户端 core-site.xml
<property>
  <name>hadoop.security.authentication</name>
  <value>kerberos</value>
</property>

# 然后 kinit
kinit alice
```

### E4. Server has invalid Kerberos principal

**现象**：客户端连接 NN 报对方 SPN 不对

**根因**：客户端预期 `hdfs/_HOST@REALM`，但 NN 实际启动用了别的 principal

**排查**：
```bash
# NN 端
ps aux | grep namenode
jstack <namenode_pid> | grep -i principal
```

### E5. Mechanism level: Checksum failed

**现象**：偶发性 GSSException

**根因**：通常是 KVNO 不一致 / keytab 损坏

**根治**：重新 ktadd

### E6. UnknownHostException 嵌套在 GSSException

**现象**：
```
GSSException: ... Caused by: java.net.UnknownHostException: kdc01
```

**根因**：DNS 反解失败 / 短名没 FQDN 映射

**根治**：krb5.conf 用 FQDN，加 /etc/hosts 兜底

### E7. Service ticket request failed

**现象**：能拿到 TGT，访问服务时拿 ST 失败

**根因**：服务 SPN 不存在 / KDC 无法访问

**排查**：
```bash
kvno hdfs/nn01.bigdata.com@BIGDATA.COM
KRB5_TRACE=/dev/stderr <client command>
```

---

## F. 跨域 Cross-Realm 问题

### F1. capaths 配置缺失

**现象**：跨 Realm 认证失败，报路径不通

**根因**：krb5.conf 中没配 `[capaths]`

**根治**：
```ini
[capaths]
    CORP.COM = {
        HADOOP.COM = .
    }
    HADOOP.COM = {
        CORP.COM = .
    }
```

### F2. krbtgt 密码两边不一致

**现象**：报 `KDC has no support for encryption type` 或 `KrbException: Decrypt integrity check failed`

**根因**：两边 KDC 上 `krbtgt/B@A` 密码不一致

**根治**：
```bash
# 两边 KDC 用相同密码重设
kadmin.local -q "cpw -pw 'SAMEPASSWORD' krbtgt/HADOOP.COM@CORP.COM"
```

### F3. auth_to_local 规则错配

**现象**：跨域用户能认证，但访问 HDFS 报权限错（鉴权失败）

**根因**：core-site.xml `auth_to_local` 没把跨域 principal 映射到本地 OS user

**根治**：
```xml
<property>
  <name>hadoop.security.auth_to_local</name>
  <value>
    RULE:[1:$1@$0](.*@CORP\.COM)s/@CORP\.COM//
    RULE:[2:$1@$0](.*@CORP\.COM)s/@CORP\.COM//
    DEFAULT
  </value>
</property>
```

### F4. enctype 不匹配（AD 用 RC4, MIT 用 AES）

**现象**：从 AD 跨域到 MIT KDC 报 enctype 不支持

**根治**：在 `[libdefaults]` 或 `[realms]` 里加上对方支持的 enctype
```ini
[realms]
    CORP.COM = {
        kdc = ad01.corp.com
        default_tkt_enctypes = aes256-cts-hmac-sha1-96 arcfour-hmac
    }
```

---

## G. 长任务 / Token 问题

### G1. HDFS_DELEGATION_TOKEN expired

**现象**：长任务跑了 7 天突然挂

**根治**：`spark-submit --keytab xxx --principal xxx`

### G2. Token max-lifetime 设置过短

**现象**：MR/Spark 任务跑了 1 天就挂

**根因**：HDFS NN `dfs.namenode.delegation.token.max-lifetime` 默认 7 天，但有人改成 1 天

**根治**：
```xml
<!-- hdfs-site.xml -->
<property>
  <name>dfs.namenode.delegation.token.max-lifetime</name>
  <value>604800000</value>   <!-- 7 天 ms -->
</property>
<property>
  <name>dfs.namenode.delegation.token.renew-interval</name>
  <value>86400000</value>    <!-- 1 天 ms -->
</property>
```

### G3. YARN renewer 没在 NN 白名单

**现象**：
```
DelegationTokenRenewer: Unable to renew token: 
yarn tries to renew, but yarn is not the renewer specified in the token
```

**根因**：HDFS_DELEGATION_TOKEN 申请时 renewer 写的是 `yarn/_HOST`，但 NN 配的 renewer 是 `yarn`

**根治**：统一 renewer 写法
```xml
<!-- yarn-site.xml -->
<property>
  <name>yarn.resourcemanager.principal</name>
  <value>yarn/_HOST@BIGDATA.COM</value>
</property>
```

### G4. Spark Streaming 长任务 token 过期

**根治**：`--keytab` + `spark.yarn.credentials.updateTime=...`

### G5. Flink 长流任务

```yaml
# flink-conf.yaml
security.kerberos.login.use-ticket-cache: false
security.kerberos.login.keytab: /etc/security/keytabs/flink.keytab
security.kerberos.login.principal: flink/_HOST@BIGDATA.COM
security.kerberos.login.contexts: Client,KafkaClient
```

---

## H. 浏览器 / SPNEGO 问题

### H1. Web UI 401 Unauthorized

**现象**：访问 NN/RM Web UI 报 401

**根因**：浏览器没配 SPNEGO 白名单

**根治**：见原理篇 §8.2 浏览器配置

### H2. HTTP/_HOST principal 没创建

**现象**：服务启动失败，报 SPNEGO keytab 加载失败

**根治**：
```bash
kadmin.local -q "addprinc -randkey HTTP/nn01.bigdata.com"
kadmin.local -q "ktadd -k /etc/security/keytabs/spnego.service.keytab HTTP/nn01.bigdata.com"
```

### H3. Knox / 反向代理破坏 SPNEGO

**现象**：直连 HS2 SPNEGO 没问题，过 Knox 报 401

**根因**：反向代理需要 `auth-pass-through` + 自身有 HTTP principal

**根治**：Knox 配置 `KERBEROS` 认证 provider，并申请 `HTTP/knox.bigdata.com` SPN

### H4. Cookies 不复用导致每次请求都重认证

**根因**：服务端没启用 hadoop.http.authentication 的 cookie

**根治**：
```xml
<property>
  <name>hadoop.http.authentication.signature.secret.file</name>
  <value>/etc/hadoop/conf/hadoop-http-auth-signature-secret</value>
</property>
```

---

## I. 部署 / 启动问题

### I1. KDC 启动失败

**排查**：
```bash
journalctl -xeu krb5kdc
# 常见原因：端口被占用 / 数据库未初始化 / 配置语法错
```

### I2. kpropd 同步失败

**现象**：备 KDC 落后于主 KDC

**排查**：
```bash
# 主 KDC
kdb5_util dump /tmp/x && kprop -f /tmp/x kdc02.bigdata.com
# 报错查 /var/log/krb5kdc.log
```

**常见原因**：
- 主备 hostname 在 kpropd.acl 中没列全
- host/principal 没创建或 keytab 没分发

### I3. KDC 数据库被锁

**现象**：`kadmin.local` 报 `Kerberos database lock file already exists`

**根治**：
```bash
ls -la /var/kerberos/krb5kdc/ | grep lock
# 确认没 kadmind 在跑
rm /var/kerberos/krb5kdc/principal.lock
```

### I4. krb5.conf 语法错（无报错，但默默失败）

**根治**：用 `krb5_check_config` 或 `kinit -V` 验证

### I5. 容器中 KEYRING ccache 失效

**现象**：在 K8s pod 中 kinit 后 klist 看不到票

**根治**：`/etc/krb5.conf`
```ini
[libdefaults]
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
```

### I6. 大批量 keytab 分发后部分节点服务起不来

**根因**：scp 时权限丢失

**根治**：
```bash
# 正确做法
scp keytab nn01:/tmp/
ssh nn01 "mv /tmp/keytab /etc/security/keytabs/ && chown hdfs:hadoop /etc/security/keytabs/keytab && chmod 400 /etc/security/keytabs/keytab"
```

---

## 排障速查表（一图流）

| 报错 | 优先排查 |
|------|---------|
| Clock skew | 时钟 NTP |
| Client not found | KDC 上 listprincs |
| Server not found | hostname -f / SPN 大小写 |
| KVNO mismatch | klist -kt vs kvno |
| Pre-auth failed | 密码/keytab/enctype |
| Illegal key size | JCE policy |
| No valid creds | kinit / KRB5CCNAME / klist |
| Defective token | 时钟 + replay cache |
| Cannot authenticate via [KERBEROS] | 客户端 hadoop.security.authentication |
| Token expired | --keytab |

---

## 附录：日志关键字 grep 速查

```bash
# /var/log/krb5kdc.log 关键字
grep -E "AS_REQ|TGS_REQ|PREAUTH_FAILED|UNKNOWN_SERVER" /var/log/krb5kdc.log

# Hadoop 服务日志
grep -iE "kerberos|gssexception|krbexception|sasl" /var/log/hadoop-hdfs/*.log

# Java GC 中找 LoginException
grep "LoginException\|GSSException" *.log
```

---

*Eric · 大数据 SRE AI 专家团队 · 知识晶体化 v1.0 · 持续累积中*
