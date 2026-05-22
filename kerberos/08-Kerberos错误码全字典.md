# Kerberos 错误码全字典（速查版）

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> 100+ 错误码 / 报错信息 → 根因 → 一句话解法 → 触发场景  
> **Ctrl+F 直接搜你的错误信息**

---

## 使用说明

```
搜索方式：
  1) 复制报错关键字 → Ctrl+F 在本文档搜
  2) 找到对应条目 → 看「立即排查」三步
  3) 还不行 → 看「深挖路径」走完整流程
```

每条记录格式：

```
### 错误码/关键字
**报错全文**：（一行最关键的）
**根因**：核心原因
**一句话解法**：最快修复命令
**深度排查**：详细步骤
**触发场景**：什么操作会触发
**误区**：常见错误判断
```

---

## A. KrbException 系列（错误码-1765328xxx）

> Java 客户端最常见，错误码是 MIT 标准 KRB_AP_ERR / KRB_AS_ERR 系列负数

### A1. -1765328370 / Cannot find KDC for realm

**报错全文**：`Cannot find KDC for realm "BIGDATA.COM"` 或 `KrbException: Cannot find KDC for realm`

**根因**：`/etc/krb5.conf` 里没找到 `realm = BIGDATA.COM` 的 kdc 配置

**一句话解法**：
```bash
grep -A5 "BIGDATA.COM" /etc/krb5.conf | grep kdc
```

**深度排查**：
1. `cat /etc/krb5.conf` 看 `[realms]` 段
2. JVM 中 `-Djava.security.krb5.conf=...` 是不是指向了错的文件
3. `default_realm` 大小写是否匹配（**必须全大写**）
4. `dns_lookup_kdc=true` 时检查 DNS SRV 记录

**触发场景**：
- 新机器 krb5.conf 没分发
- JVM 启动加 `-Djava.security.krb5.conf=/wrong/path`
- 容器中 `/etc/krb5.conf` 不存在

**误区**：以为是 KDC 挂了 → 其实是配置找不到

---

### A2. -1765328359 / Clock skew too great

**报错全文**：`Clock skew too great (37)` 或 `kinit: Clock skew too great while getting initial credentials`

**根因**：客户端与 KDC 时间偏差 > 5 分钟（默认 `clockskew=300s`）

**一句话解法**：
```bash
ntpdate -s ntp.aliyun.com   # 或 chronyc -a makestep
```

**深度排查**：
```bash
# 同时看两端
date && ssh kdc01.bigdata.com date
# 看 chrony 状态
chronyc tracking
chronyc sources -v
# 时区
timedatectl
```

**触发场景**：
- VM 暂停后恢复（虚拟化时钟漂移）
- NTP 服务挂了
- 防火墙挡了 NTP 端口（123 UDP）
- 容器与宿主机时钟不同步（mount /etc/localtime）

**误区**：以为只要 `date` 看着差不多就行 → 必须秒级对齐 + UTC 一致

---

### A3. -1765328378 / Pre-authentication failed

**报错全文**：`Preauthentication failed` 或 `KrbException: Pre-authentication information was invalid (24)`

**根因**：3 选 1
1. 密码错误
2. keytab 中密钥与 KDC 不一致（KVNO 错乱 / enctype 不支持）
3. 时钟偏差（PA-ENC-TIMESTAMP 验证失败）

**一句话解法**：
```bash
KRB5_TRACE=/dev/stderr kinit -V -kt /path/to/keytab principal@REALM 2>&1 | grep -E "Salt|etype|skew"
```

**深度排查**：
```bash
# 1) 验证 keytab 与 KDC enctype 一致
klist -ket /path/to/keytab
kadmin.local -q "getprinc principal" | grep "Key:"

# 2) KVNO 比对
kt_kvno=$(klist -kt /path/to/keytab | awk 'NR==4{print $1}')
kdc_kvno=$(kvno principal@REALM | awk '{print $NF}')
echo "keytab=$kt_kvno KDC=$kdc_kvno"

# 3) 时钟
date
```

**触发场景**：
- 用户密码改了但用旧密码 kinit
- KDC 上 cpw -randkey 后 keytab 没分发
- 不同 enctype（KDC 只支持 AES，keytab 只有 DES）

**误区**：看到 "Pre-auth" 就以为是密码错 → 50% 是 KVNO 不一致

---

### A4. -1765328377 / Decrypt integrity check failed

**报错全文**：`Decrypt integrity check failed (31)` 或 `KrbException: Integrity check on decrypted field failed`

**根因**：用错了密钥解密 — 通常是**跨域 krbtgt 密码两边不一致**

**一句话解法**：跨域两端 KDC 必须用相同密码重置
```bash
# 两边都执行
kadmin.local -q "cpw -pw 'SAME_PASSWORD' krbtgt/B@A"
```

**深度排查**：
- 单域：keytab 损坏 / 错配；重新 ktadd
- 跨域：核对两边 krbtgt 的 KVNO + 密码（必须一致）

**触发场景**：
- AD 团队改了 krbtgt 密码没通知
- 跨域信任建立时密码输错
- keytab 是从其他集群拷过来的（密钥不通用）

**误区**：以为是网络/防火墙 → 这是**密钥级**错误

---

### A5. -1765328353 / Server not found in Kerberos database

**报错全文**：`Server not found in Kerberos database (7)` 或 `GSSException: ... Server not found in Kerberos database`

**根因**：KDC 中没有这个 SPN — 通常是 **FQDN 不匹配**

**一句话解法**：
```bash
KRB5_TRACE=/dev/stderr <你的命令> 2>&1 | grep "TGS-REQ for"
# 看实际请求的 SPN，再到 KDC listprincs 比对
```

**深度排查**：
```bash
# 1) 客户端实际 hostname
hostname -f
# 2) KDC 中 SPN 列表
kadmin.local -q "listprincs '*service*'"
# 3) 大小写敏感！ NN01 ≠ nn01
# 4) 短名 vs FQDN
```

**触发场景**：
- `hostname -f` 返回短名而不是 FQDN
- 域名大小写不一致（KDC 中是 `nn01`，请求是 `NN01`）
- DNS 反解换成了 IP
- 多网卡 advertise 了不同 hostname

**误区**：以为是 KDC 挂了 → 其实 SPN 写错

---

### A6. -1765328378 / Client not found in Kerberos database

**报错全文**：`Client 'alice@BIGDATA.COM' not found in Kerberos database (6)` 或 `kinit: Client ... not found`

**根因**：KDC 中没有这个用户 principal

**一句话解法**：
```bash
kadmin.local -q "listprincs" | grep alice
# 没有就创建
kadmin.local -q "addprinc alice"
```

**触发场景**：
- 新用户没建
- 用户被删了
- Realm 写错（`alice@WRONG.COM`）
- 备 KDC 数据库没同步到

**误区**：忘记 principal 是 `user@REALM`，光写用户名

---

### A7. -1765328324 / Ticket expired

**报错全文**：`Ticket expired (32)` 或 `KrbException: Ticket expired`

**根因**：TGT 已过期（默认 24h）

**一句话解法**：
```bash
kinit alice    # 或 kinit -kt keytab principal
```

**触发场景**：
- 长任务但没传 `--keytab`
- 服务进程没正确调用 `reloginFromKeytab()`
- 系统时间被调快了

**误区**：与 "Token expired" 混淆 — TGT 是 Kerberos 票据，DT 是 Hadoop Token

---

### A8. -1765328352 / Ticket not yet valid

**报错全文**：`Ticket not yet valid (33)`

**根因**：客户端时钟**慢于** KDC，刚发的票"将来才生效"

**一句话解法**：同步时间
```bash
chronyc -a makestep
```

**触发场景**：客户端时间被调慢

---

### A9. -1765328332 / KDC reply did not match expectations

**报错全文**：`KDC reply did not match expectations` 或 `KRB_AP_ERR_MODIFIED`

**根因**：通常是 enctype 协商问题 — KDC 返回的 enctype 客户端不支持

**一句话解法**：
```ini
# /etc/krb5.conf
[libdefaults]
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac
    permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac
```

**触发场景**：JDK 升级后默认 enctype 变了

---

### A10. -1765328230 / Specified version of key is not available

**报错全文**：`Specified version of key is not available (44)` 或 `KrbException: ...`

**根因**：**KVNO 不一致** — keytab 中的 KVNO 与 KDC 数据库不一致

**一句话解法**：
```bash
# KDC 上重新导出（带 -norandkey 保 KVNO 不变）
kadmin.local -q "ktadd -norandkey -k /tmp/svc.keytab principal@REALM"
# 分发到对应主机
```

**深度排查**：
```bash
# keytab 里的 KVNO
klist -kt /etc/security/keytabs/svc.keytab

# KDC 里的 KVNO
kvno principal@REALM
```

**触发场景**：
- 有人在 KDC 跑了 `ktadd`（不带 -norandkey）改了密码
- 跨集群拷贝 keytab 但 KVNO 不对应
- KDC 数据库恢复后 KVNO 错位

**这是生产 Top1 错误**，必背 ⭐⭐⭐⭐⭐

---

### A11. -1765328351 / Cannot contact any KDC for realm

**报错全文**：`Cannot contact any KDC for realm "BIGDATA.COM"`

**根因**：KDC 不可达（端口/网络/进程）

**一句话解法**：
```bash
nc -zv kdc01.bigdata.com 88   # TCP
nc -zvu kdc01.bigdata.com 88  # UDP
```

**深度排查**：
```bash
# 1) 进程
ssh kdc01 "systemctl status krb5kdc"
# 2) 端口
ssh kdc01 "ss -lntup | grep 88"
# 3) 防火墙
ssh kdc01 "iptables -L -n | grep 88"
# 4) 客户端 → KDC 可达
mtr -n kdc01.bigdata.com
# 5) krb5.conf 的 KDC 地址对不对
```

**触发场景**：KDC 进程挂 / 防火墙改 / DNS 改 / 网络分区

---

### A12. -1765328228 / Decrypt integrity check failed (TGS_REP)

类似 A4，但发生在 TGS_REQ → TGS_REP 阶段。根因：**Service principal 的密钥不匹配**（服务端 keytab 与 KDC 不一致）。

---

### A13. -1765328346 / Connection refused

**报错全文**：`Receive timed out` + `java.net.ConnectException: Connection refused`

**根因**：KDC 端口未开 / KDC 进程未启动

**一句话解法**：
```bash
ssh kdc01 "systemctl restart krb5kdc"
```

---

### A14. -1765328383 / Encryption type ... is not supported

**报错全文**：`Encryption type AES256 CTS mode with HMAC SHA1-96 is not supported/enabled`

**根因**：JCE 限制版（Java 8 < 152）/ krb5.conf permitted_enctypes 缺失

**一句话解法**：
```bash
# Java 8 >= 152
sed -i 's/^#crypto.policy=unlimited/crypto.policy=unlimited/' \
    $JAVA_HOME/jre/lib/security/java.security
```

---

### A15. -1765328369 / KDC has no support for encryption type

**报错全文**：`KDC has no support for encryption type`

**根因**：客户端请求的 enctype KDC 不支持（通常是 RC4 在新 KDC 被禁用）

**一句话解法**：
```ini
[libdefaults]
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
```

---

## B. GSSException 系列（Java JGSS API 报错）

### B1. No valid credentials provided

**报错全文**：`GSSException: No valid credentials provided (Mechanism level: Failed to find any Kerberos tgt)`

**根因前 5（按概率）**：
1. 没 kinit（30%）
2. KRB5CCNAME 路径与进程不一致（25%）
3. 票据已过期（20%）
4. JAAS 配置没加载（15%）
5. ccache 是 KEYRING 但跨进程（10%）

**一句话解法**：
```bash
kinit -kt /path/to/keytab principal@REALM
echo $KRB5CCNAME
klist
```

**深度排查**：
```bash
# 1) 看进程的环境变量
cat /proc/<pid>/environ | tr '\0' '\n' | grep -i krb

# 2) 看 ccache 类型
klist -A
# 如果是 KEYRING:persistent:UID，跨进程会失效

# 3) 改成 FILE 类型
echo "[libdefaults]
default_ccache_name = FILE:/tmp/krb5cc_%{uid}" >> /etc/krb5.conf

# 4) Java 进程加调试
-Dsun.security.krb5.debug=true
-Dsun.security.spnego.debug=true
-Djavax.security.auth.useSubjectCredsOnly=false
```

**触发场景**：服务用 `su - hdfs` 切换后 ccache 路径不一致 / 容器中 KEYRING 失效

---

### B2. Defective token detected

**报错全文**：`GSSException: Defective token detected (Mechanism level: AP_REP token id does not match!)`

**根因**：
1. 时钟偏差（最常见）
2. replay cache 异常
3. 客户端服务端用的密钥不一致

**一句话解法**：
```bash
# 1) 时钟
chronyc -a makestep

# 2) 清 replay cache
rm -rf /var/tmp/krb5_*_rcache
systemctl restart <service>
```

---

### B3. Failure unspecified at GSS-API level

**报错全文**：`GSSException: Failure unspecified at GSS-API level (Mechanism level: ...)`

**根因**：占位错误，必须看后面的 `(Mechanism level: ...)` 才知道真因

**一句话解法**：
```bash
# 一定要打开 debug 看完整堆栈
HADOOP_OPTS="-Dsun.security.krb5.debug=true" <你的命令>
```

---

### B4. The ticket isn't for us

**报错全文**：`GSSException: ... The ticket isn't for us`

**根因**：服务端 keytab 中的 SPN 与 ST 中的 SPN 不一致

**一句话解法**：
```bash
# 服务端 keytab 应该有的 SPN
klist -kt /etc/security/keytabs/hdfs.service.keytab
# 应包含 hdfs/$(hostname -f)@REALM
```

**触发场景**：负载均衡 / VIP 后端 hostname 不匹配

---

### B5. Connection closed by peer

**报错全文**：`GSSException: ... Connection closed by peer`

**根因**：服务端 SASL 协商失败 — 看服务端日志才能定位

```bash
tail -100 /var/log/hadoop-hdfs/hadoop-hdfs-namenode-*.log | grep -i sasl
```

---

### B6. Mechanism level: Checksum failed

**根因**：通常 KVNO 不一致或 keytab 损坏

**解法**：参见 A10

---

### B7. Mechanism level: Invalid argument (400) - Cannot find key of appropriate type

**报错全文**：`Invalid argument (400) - Cannot find key of appropriate type to decrypt AP REP - AES256 CTS mode with HMAC SHA1-96`

**根因**：服务端 keytab 缺少 KDC 协商的 enctype（如 keytab 只有 RC4，KDC 给的票是 AES256）

**一句话解法**：
```bash
kadmin.local -q "ktadd -e aes256-cts-hmac-sha1-96:normal,aes128-cts-hmac-sha1-96:normal -norandkey -k /path principal"
```

---

## C. SASL / RPC 错误

### C1. Cannot authenticate via:[TOKEN, KERBEROS]

**报错全文**：`org.apache.hadoop.security.AccessControlException: Client cannot authenticate via:[TOKEN, KERBEROS]`

**根因**：客户端没启用 Kerberos 认证

**一句话解法**：
```xml
<!-- core-site.xml -->
<property>
  <name>hadoop.security.authentication</name>
  <value>kerberos</value>
</property>
```
然后 `kinit`

---

### C2. SIMPLE authentication is not enabled

**报错全文**：`SIMPLE authentication is not enabled. Available:[TOKEN, KERBEROS]`

**根因**：客户端走了 SIMPLE 认证但服务端只接 KERBEROS

**一句话解法**：客户端 `core-site.xml` 加 `hadoop.security.authentication=kerberos`，再 kinit

---

### C3. SASL authentication failed: GSS initiate failed

**报错全文**：`SASL authentication failed: GSS initiate failed`

**根因**：客户端拿不到合法 ST — 看后面的 caused by 定位

**一句话解法**：开 trace 看具体错误
```bash
KRB5_TRACE=/dev/stderr <client cmd>
```

---

### C4. Server has invalid Kerberos principal

**报错全文**：`SaslException: GSS initiate failed [Caused by GSSException: ... Server has invalid Kerberos principal]`

**根因**：客户端预期的 SPN ≠ 服务端实际启动的 SPN

**深度排查**：
```bash
# 服务端进程实际用的 principal
ps -ef | grep namenode
jstack <pid> | grep -i principal

# 客户端预期的 SPN（看配置）
grep "kerberos.principal" /etc/hadoop/conf/*.xml
```

---

### C5. ClientFallbackToSimpleAuthBugException

**根因**：服务端开了 Kerberos 但客户端配置 fallback 到 SIMPLE

**一句话解法**：
```xml
<property>
  <name>ipc.client.fallback-to-simple-auth-allowed</name>
  <value>false</value>
</property>
```

---

## D. Token 相关错误

### D1. token (HDFS_DELEGATION_TOKEN ...) is expired

**报错全文**：`org.apache.hadoop.security.token.SecretManager$InvalidToken: token (HDFS_DELEGATION_TOKEN ...) is expired`

**根因**：长任务的 Delegation Token 超过 7 天 max-lifetime

**一句话解法**：用 `--keytab` 重新提交
```bash
spark-submit --keytab xxx.keytab --principal xxx@REALM ...
```

---

### D2. token is expired or doesn't exist anymore

**报错全文**：`SecretManager$InvalidToken: token is expired or doesn't exist anymore`

**根因**：token 在 NN 端被取消了（cancelDelegationToken）/ 或 NN 重启清空了

**一句话解法**：重启任务，确认 NN 是否近期重启过

---

### D3. token can't be found in cache

**根因**：NN HA 切主后从机的 token cache 没同步（罕见）

**一句话解法**：等待 ZKFC 选举完成后重试

---

## E. 网络/DNS 错误

### E1. UnknownHostException

**报错全文**：`java.net.UnknownHostException: kdc01.bigdata.com`

**根因**：DNS 解析失败 / hosts 文件没配

**一句话解法**：
```bash
nslookup kdc01.bigdata.com
echo "10.0.0.1 kdc01.bigdata.com" >> /etc/hosts
```

---

### E2. Receive timed out

**报错全文**：`Receive timed out`（伴随 sun.security.krb5.KdcComm 警告）

**根因**：UDP 包大被截断 / KDC 响应慢

**一句话解法**：
```ini
[libdefaults]
    udp_preference_limit = 1   # 强制 TCP
```

---

### E3. java.net.NoRouteToHostException

**根因**：路由不通 / 防火墙

**一句话解法**：`mtr` 或 `traceroute` 找断点

---

## F. JAAS/Login 错误

### F1. No LoginModules configured

**报错全文**：`javax.security.auth.login.LoginException: No LoginModules configured for Client`

**根因**：JVM 没加 `-Djava.security.auth.login.config=...`

**一句话解法**：
```bash
export HADOOP_OPTS="-Djava.security.auth.login.config=/etc/security/jaas.conf $HADOOP_OPTS"
```

---

### F2. Unable to obtain password from user

**报错全文**：`javax.security.auth.login.LoginException: Unable to obtain password from user`

**根因**：keytab 文件读不到（权限/路径错）

**一句话解法**：
```bash
ls -l /path/to/keytab
chown <user>:<group> /path/to/keytab
chmod 400 /path/to/keytab
```

---

### F3. Login failure for ... from keytab

**报错全文**：`Login failure for hdfs/nn01 from keytab /etc/security/keytabs/hdfs.keytab`

**根因**：keytab 中没有这个 principal 的条目

**一句话解法**：
```bash
klist -kt /path/to/keytab
# 看 principal 列表，没有就 ktadd
```

---

## G. KDC 服务端错误

### G1. PREAUTH_FAILED in /var/log/krb5kdc.log

**根因**：客户端密码错 / keytab 错

**深度**：在 KDC 上能看到客户端 IP，反查谁失败

---

### G2. UNKNOWN_SERVER in /var/log/krb5kdc.log

**根因**：客户端请求的 SPN 在 KDC 不存在（A5 的服务端日志体现）

---

### G3. Database lock file already exists

**报错全文**：`Kerberos database lock file already exists`

**根因**：上次 kadmin 异常退出留的锁

**一句话解法**：
```bash
# 确认没 kadmin 在跑
ps -ef | grep kadmin
# 删锁
rm /var/kerberos/krb5kdc/principal.lock
```

---

## H. SPNEGO/Web UI 错误

### H1. HTTP 401 Unauthorized + WWW-Authenticate: Negotiate

**根因**：浏览器没配 SPNEGO / 客户端没 kinit

**一句话解法**：
```bash
# Firefox: about:config 改 network.negotiate-auth.trusted-uris=.bigdata.com
# Chrome: 启动加 --auth-server-whitelist="*.bigdata.com"

# 或 curl 测
curl --negotiate -u : http://nn01.bigdata.com:9870/jmx
```

---

### H2. HTTP 403 + Authentication required

**根因**：服务端的 `HTTP/_HOST` SPN 没创建或 spnego.keytab 没分发

**一句话解法**：
```bash
kadmin.local -q "addprinc -randkey HTTP/$(hostname -f)"
kadmin.local -q "ktadd -k /etc/security/keytabs/spnego.service.keytab HTTP/$(hostname -f)"
```

---

### H3. Browser 弹窗反复输密码

**根因**：浏览器没正确发 SPNEGO Token

**一句话解法**：检查浏览器 SPNEGO 配置 + 客户端 `klist` 确认有 TGT

---

## I. 跨域/Cross-Realm 错误

### I1. KrbException: Generic error (description in e-text)

**根因**：跨域路径不通（capaths 缺失）

**一句话解法**：
```ini
[capaths]
    A.COM = {
        B.COM = .
    }
    B.COM = {
        A.COM = .
    }
```

---

### I2. Permission denied 但 Kerberos 认证成功

**根因**：跨域用户没被 auth_to_local 映射到本地 OS user

**一句话解法**：
```xml
<property>
  <name>hadoop.security.auth_to_local</name>
  <value>
    RULE:[1:$1@$0](.*@CORP\.COM)s/@CORP\.COM//
    DEFAULT
  </value>
</property>
```

---

## J. 容器/K8s 特有错误

### J1. cannot open keyring

**根因**：容器中 KEYRING ccache 失效（容器没 keyring）

**一句话解法**：
```ini
[libdefaults]
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
```

---

### J2. hostname mismatch in container

**根因**：容器 hostname 是 random ID，不是 FQDN

**一句话解法**：
```yaml
# K8s pod
hostname: client01
subdomain: bigdata-com
hostAliases:
  - ip: 10.0.0.1
    hostnames: ["kdc01.bigdata.com"]
```

---

## K. 其他常见

### K1. Illegal key size

**根因**：JCE 没解锁

**解法**：参见 A14

---

### K2. unable to load file ... krb5.keytab

**根因**：JVM 找不到 default keytab

**一句话解法**：
```bash
-Djavax.security.auth.useSubjectCredsOnly=false
# 或
export KRB5_KTNAME=/etc/security/keytabs/your.keytab
```

---

### K3. AbstractAuthorizableContainer$1 ... Caused by: GSSException

**根因**：HS2/HMS proxyuser 没配

**一句话解法**：
```xml
<property>
  <name>hadoop.proxyuser.hive.hosts</name>
  <value>*</value>
</property>
<property>
  <name>hadoop.proxyuser.hive.groups</name>
  <value>*</value>
</property>
```

---

### K4. PERMISSION DENIED 但已 kinit

**根因**：HDFS/Hive ACL 拒绝（认证 OK，授权不通）—— **这不是 Kerberos 问题**

**解法**：查 Ranger / HDFS ACL / Sentry

---

## L. 错误码速查表（Top 30 一图流）

| 错误码 | 报错关键字 | 根因 | 一句话解法 |
|-------|----------|------|----------|
| -1765328359 | Clock skew | 时钟偏差 | `chronyc -a makestep` |
| -1765328370 | Cannot find KDC | krb5.conf 缺 realm | 配 `[realms]` |
| -1765328351 | Cannot contact any KDC | 网络/进程 | `nc -zv kdc 88` |
| -1765328378 | Pre-authentication failed | 密码/KVNO/enctype | `KRB5_TRACE=...` |
| -1765328353 | Server not found | SPN 不存在/FQDN 错 | `kvno SPN` |
| -1765328377 | Decrypt integrity check failed | 密钥不一致 | 跨域核 krbtgt |
| -1765328324 | Ticket expired | TGT 过期 | `kinit` |
| -1765328352 | Ticket not yet valid | 客户端时钟慢 | 同步时间 |
| -1765328230 | Specified version of key | KVNO 不一致 | `ktadd -norandkey` |
| -1765328383 | Encryption type not supported | JCE/enctype 不支持 | 解锁 JCE |
| -1765328369 | KDC has no support for enctype | RC4 被禁 | 配 AES |
| -1765328332 | KDC reply did not match | enctype 协商 | krb5.conf 加 enctype |
| GSS | No valid credentials | 没 kinit/CCNAME 错 | `kinit + echo $KRB5CCNAME` |
| GSS | Defective token | 时钟/replay cache | 同步+清 cache |
| GSS | Failure unspecified | 占位 | 看 caused by |
| GSS | Cannot find key | keytab 缺 enctype | `ktadd -e ...` |
| Hadoop | Cannot authenticate via | 客户端没启 Kerberos | core-site.xml |
| Hadoop | SIMPLE auth not enabled | 同上 | 同上 |
| Hadoop | token is expired | DT 7 天上限 | `--keytab` |
| Hadoop | Server has invalid principal | SPN 不匹配 | hostname -f |
| JAAS | No LoginModules | 没指定 jaas.conf | `-Djava.security.auth.login.config` |
| JAAS | Unable to obtain password | keytab 读不到 | chown/chmod 400 |
| JAAS | Login failure from keytab | keytab 缺 principal | klist -kt |
| KDC log | PREAUTH_FAILED | 客户端密码错 | 反查 IP |
| KDC log | UNKNOWN_SERVER | SPN 不存在 | listprincs |
| KDC | Database lock | kadmin 锁 | rm lock |
| HTTP 401 | WWW-Authenticate Negotiate | 浏览器 SPNEGO | 配白名单 |
| Cross-Realm | Generic error | capaths 缺 | 加 capaths |
| Container | cannot open keyring | KEYRING 失效 | FILE ccache |
| Misc | Illegal key size | JCE 限制 | crypto.policy=unlimited |

---

## 使用流程图

```
报错出现
   ↓
[1] 复制错误关键字 → Ctrl+F 本文档
   ↓
[2] 找到对应条目 → 看「一句话解法」
   ↓
[3] 没解决 → 走「深度排查」三步
   ↓
[4] 还没解决 → 开 KRB5_TRACE + sun.security.krb5.debug=true 收集证据
   ↓
[5] 把证据贴到 Eric → 升级到根因分析
```

---

*Eric · 大数据 SRE AI 专家团队 · 速查字典 v1.0 · 持续更新*
