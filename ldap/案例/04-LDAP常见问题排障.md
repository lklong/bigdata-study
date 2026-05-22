# LDAP 常见问题排障手册（30+ 真实案例）

> 作者：Eric（豹纹）| 配套：01/02/03 三册  
> 原则：按 **黄金排障六步法**（看现象→看日志→定位组件→证据闭环→执行修复→验证沉淀）  
> 每个 Case = 现象 / 根因 / 排查 / 修复 / 预防

---

## 0. LDAP 错误码速查（结合 RFC 4511）

| Code | 名称 | 常见原因 | 通常排查方向 |
|------|------|---------|------------|
| 0  | success | OK | - |
| 1  | operationsError | 服务端逻辑错 | 服务端日志 |
| 2  | protocolError | 客户端协议错 | 客户端版本 |
| 4  | sizeLimitExceeded | 返回超 sizeLimit | 加分页 / 调 olcSizeLimit |
| 7  | authMethodNotSupported | SASL 不支持 | 看 olcSaslMech |
| 8  | strongerAuthRequired | 必须用 TLS/SASL | 启 LDAPS |
| 12 | unavailableCriticalExtension | 客户端要的控件不支持 | 升级 slapd |
| 19 | constraintViolation | 密码策略 / 唯一约束 | 看 ppolicy |
| 20 | attributeOrValueExists | 属性已存在 | 用 replace 而非 add |
| 21 | invalidAttributeSyntax | 属性值格式错 | 看 schema |
| 32 | noSuchObject | DN 不存在 | base/dn 拼错 |
| 49 | invalidCredentials | 密码错 / 账号锁 / 不存在 | **最常见，重点看子原因** |
| 50 | insufficientAccessRights | ACL 拒绝 | slapacl 调试 |
| 51 | busy | 服务端过载 | 看 cn=Monitor |
| 52 | unavailable | 服务停 / 复制中 | systemctl status |
| 53 | unwillingToPerform | 服务端拒绝（如改 readonly） | 看 olcReadOnly |
| 65 | objectClassViolation | objectClass 必须属性缺失 | 看 schema |
| 68 | entryAlreadyExists | DN 已存在 | 改 modify |
| 81 | LDAP_SERVER_DOWN | 网络不通 | telnet 端口 |
| 82 | LDAP_LOCAL_ERROR | TLS / 证书错 | openssl s_client |

⚠️ **49 子原因解读**（slapd 日志里）：
- `info: invalid credentials` → 密码错
- `info: account locked` → ppolicy 锁
- `info: password expired` → 密码过期
- `info: no such object` → DN 不存在（也返 49 防枚举）

---

## 1. 认证失败类（最高频）

### Case 1.1 `ldap_bind: Invalid credentials (49)` 但密码明明是对的

**现象**：用户 alice 在 Hue/HS2 登录失败，命令行 `ldapwhoami` 同样失败。

**排查**：
```bash
# 1. 直接对 LDAP 测试
ldapwhoami -x -H ldaps://ldap.bigdata.local:636 \
  -D "uid=alice,ou=People,dc=bigdata,dc=local" -w 'Alice@123'

# 2. 看 slapd 日志（必须开 stats）
tail -f /var/log/slapd.log | grep alice
# RESULT tag=97 err=49 info=password is expired ← 找到子原因
```

**根因可能**：
1. ppolicy 锁定（pwdAccountLockedTime 有值）
2. 密码过期（pwdGraceAuthNLimit 用尽）
3. 用户被搬到 `ou=Disabled` 但客户端还查 `ou=People`
4. 大写敏感（uid 默认大小写不敏感，但某些 schema 是 caseExactString）
5. 客户端 bind DN 拼接错（如 `uid=alice` 漏 baseDN）

**修复**：
```bash
# 看锁状态
ldapsearch -x -D "cn=admin,..." -W -b "uid=alice,ou=People,dc=bigdata,dc=local" '+'
# 找到 pwdAccountLockedTime / pwdFailureTime / pwdChangedTime

# 解锁
cat <<EOF | ldapmodify -x -D "cn=admin,..." -W
dn: uid=alice,ou=People,dc=bigdata,dc=local
changetype: modify
delete: pwdAccountLockedTime
EOF

# 重置密码（同时清失败计数）
ldappasswd -x -D "cn=admin,..." -W -s 'NewPwd@2026' "uid=alice,ou=People,dc=bigdata,dc=local"
```

**预防**：业务侧加"密码即将过期"邮件提醒（pwdExpireWarning），SIEM 监控连续失败。

---

### Case 1.2 Hive Server2 `Error validating LDAP user`，但 ldapsearch 正常

**现象**：beeline 报错：
```
Error: Could not establish connection to jdbc:hive2://hs2:10000:
Peer indicated failure: Error validating LDAP user (state=08S01,code=0)
```

**排查链**：
```bash
# 1. HS2 日志
tail -f /var/log/hive/hiveserver2.log | grep -i ldap
# 常见：
# javax.naming.AuthenticationException: [LDAP: error code 49 - Invalid Credentials]
# 或：UserSearchFilter ... no result
```

**根因清单**：
1. `userFilter` 配了白名单但 alice 不在
2. `groupFilter` 配了组但 alice 不在该组
3. `userDNPattern` 与 `userFilter` 同时配了，前者优先级高，DN 拼错
4. `guidKey` 应是 `uid` 但配成 `cn`
5. `groupClassKey` 配 `groupOfNames`，但 LDAP 实际是 `posixGroup`
6. `groupMembershipKey` 配 `member`（DN），但 LDAP 是 `memberUid`（字符串）
7. truststore 没装 LDAP 的 CA → SSL handshake 失败（不会是 49 而是 SSL 异常）

**修复**（按 §02 节 3 核对配置）：
```xml
<!-- 三件套必须匹配 -->
<property><name>hive.server2.authentication.ldap.guidKey</name><value>uid</value></property>
<property><name>hive.server2.authentication.ldap.groupClassKey</name><value>posixGroup</value></property>
<property><name>hive.server2.authentication.ldap.groupMembershipKey</name><value>memberUid</value></property>
```

**调试技巧**：HS2 开 DEBUG：
```properties
# log4j2.properties
logger.LdapAuth.name = org.apache.hive.service.auth
logger.LdapAuth.level = DEBUG
```
日志会打出实际下发的 LDAP filter，与手工 `ldapsearch -b ... '<filter>'` 比对。

---

### Case 1.3 SSSD 用户能 `id` 但 `ssh` 不能登

**现象**：
```
$ id alice         # OK
uid=10001(alice) gid=10001 groups=10001,20001(data-engineer)
$ ssh alice@host
Permission denied (publickey,password)
```

**根因**：PAM 没改全 / authselect 没生效 / `/var/log/secure` 报 `module unknown`。

**排查**：
```bash
sudo grep alice /var/log/secure | tail -20
# pam_sss(sshd:auth): authentication failure; logname=...
# pam_sss(sshd:auth): system info: [Authentication failed]

# 看 PAM 配置
authselect current
# 应输出 sssd with-mkhomedir
```

**修复**：
```bash
authselect select sssd with-mkhomedir --force
systemctl restart sssd sshd
```

如果还不行，手工查 `/etc/pam.d/system-auth`，应包含：
```
auth        sufficient    pam_sss.so forward_pass
account     [default=bad success=ok user_unknown=ignore] pam_sss.so
password    sufficient    pam_sss.so use_authtok
session     optional      pam_sss.so
```

---

### Case 1.4 用户改了密码，HS2 一段时间内还能用旧密码

**现象**：alice 改完密码，10 分钟内 beeline 用旧密码仍能连。

**根因**：HS2 / Trino / SSSD 的 LDAP 连接缓存或绑定缓存。

**排查**：
```bash
# Trino: ldap.cache-ttl 默认 1h
# SSSD: cache_credentials=true → /var/lib/sss/db/cache_*.ldb

sudo sss_cache -E                # 清 SSSD 缓存
systemctl restart sssd

# HS2/Kyuubi 没有内置缓存（每次都查），但客户端连接池保留连接
# → 关闭客户端 idle 连接（修改 dataSource maxLifetime）
```

**预防**：在 02-集成 中明确 `ldap.cache-ttl=5m`（生产权衡：太短压力大、太长一致性差），并在密码变更流程中提示用户"5 分钟生效"。

---

### Case 1.5 Hive 启了 LDAP 后，doAs 失败 / Spark Submit 报 `User: hive is not allowed`

**现象**：
```
RemoteException: User: hive is not allowed to impersonate alice
```

**根因**：HS2 LDAP 认证后 doAs 到 alice，但 NN 的 `core-site.xml` 没配代理用户：
```xml
hadoop.proxyuser.hive.hosts=*
hadoop.proxyuser.hive.groups=*
```

**修复**：补 proxyuser 配置 → `hdfs dfsadmin -refreshSuperUserGroupsConfiguration`。

---

## 2. 网络 / TLS 类

### Case 2.1 `ldap_sasl_bind(SIMPLE): Can't contact LDAP server (-1)`

**排查**：
```bash
# 1. 端口
nc -zv ldap.bigdata.local 636
nmap -p 636 ldap.bigdata.local

# 2. DNS
dig ldap.bigdata.local
getent hosts ldap.bigdata.local

# 3. 防火墙
sudo iptables -L -n | grep 636
firewall-cmd --list-all
```

### Case 2.2 `TLS: hostname does not match CN in peer certificate`

**根因**：证书 CN/SAN 与连接用的主机名不匹配（特别是用 IP 连 LDAP）。

**修复**：
```bash
# 客户端 ldap.conf 临时关
echo "TLS_REQCERT allow" >> /etc/openldap/ldap.conf
# 但生产必须重新签证书，含正确 SAN
```

### Case 2.3 `error:1408F10B:SSL routines:ssl3_get_record:wrong version number`

**根因**：客户端用了 ldaps:// 但服务端是 ldap:// 明文，或反之。

**修复**：用 `openssl s_client -connect host:636` 验证服务端 TLS；改客户端 URL。

### Case 2.4 LDAPS 突然全部连不上 → 证书过期

**排查**：
```bash
openssl s_client -connect ldap-m1:636 < /dev/null 2>&1 | openssl x509 -dates -noout
# notAfter=Apr  1 00:00:00 2026 GMT  ← 看是否已过
```

**修复**：滚动换证（见 03-§8.2）。

**预防**：装 cert-manager 或 cron + smtp 提前 30 天告警。

---

## 3. 性能问题

### Case 3.1 Hive 查询前 10 秒"卡住"

**现象**：beeline 连接成功后第一条 SQL 卡 10s+ 才执行。

**根因**：HS2 用 LDAP 查 group 走全表扫描（无 memberUid 索引）。

**排查**：
```bash
# slapd 日志开 stats，找慢查询
grep "slow" /var/log/slapd.log
grep "no equality index" /var/log/slapd.log
# 输出：<= mdb_equality_candidates: (memberUid) not indexed
```

**修复**：补索引（见 01-§5.2），并 `slapindex` 重建。

### Case 3.2 `cn=Monitor` 连接数 >5000，slapd CPU 满

**根因**：客户端泄漏连接（典型：HS2 升级后连接池实现 bug）。

**排查**：
```bash
ldapsearch -x -D "cn=admin,..." -W -b "cn=Connections,cn=Monitor" \
  "(objectClass=*)" monitorConnectionPeerAddress \
  | awk '/PeerAddress/{print $2}' | sort | uniq -c | sort -rn | head
# 输出：3500 IP=10.0.1.20:xxxx  ← 找到 hot client
```

**修复**：
- 服务端：限连接 `olcConnMaxPending: 5`，`olcConnMaxPendingAuth: 5`
- 客户端：升级或回滚版本，配置连接池 maxLifetime

### Case 3.3 巡检发现 `mdb` 文件越涨越大但用户没增加多少

**根因**：`accesslog` 没启 purge 或 purge 周期太长。

**排查**：
```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" \
  "(olcOverlay=accesslog)" olcAccessLogPurge
# olcAccessLogPurge: 07+00:00 01+00:00   ← 7天保留 1天purge一次

du -sh /var/lib/ldap/accesslog/
```

**修复**：缩短 purge：`olcAccessLogPurge: 03+00:00 01+00:00`（保留 3 天，每天 purge）

### Case 3.4 LDAP 重启后比较慢，几分钟才能服务

**根因**：mdb 在大数据库下需要 mmap 加载页缓存。

**修复**：
```bash
# 启动前预热（可选）
cat /var/lib/ldap/data.mdb > /dev/null

# 调内核
echo never > /sys/kernel/mm/transparent_hugepage/enabled
sysctl -w vm.swappiness=1
```

---

## 4. 复制问题

### Case 4.1 主从 contextCSN 长期不一致

**排查**：
```bash
# m1 看自己
M1=$(ldapsearch -x -H ldap://m1 -D ... -w ... -b "dc=bigdata,dc=local" -s base contextCSN | grep -i csn)
# m2 看自己
M2=$(ldapsearch -x -H ldap://m2 -D ... -w ... -b "dc=bigdata,dc=local" -s base contextCSN | grep -i csn)
# 解析时间戳差值
```

**根因可能**：
1. 网络抖动，syncrepl 重试中
2. accesslog purge 太激进，导致从节点 cookie 已不在 log 中 → 强制全量
3. RID 冲突
4. credentials 错（密码改了但 syncrepl 配置没改）
5. schemachecking 导致条目被拒

**修复**：
```bash
# 看 syncrepl 状态
grep -i "syncrepl" /var/log/slapd.log | tail -50

# 强制重新同步（清 cookie）
cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: olcDatabase={2}mdb,cn=config
changetype: modify
delete: olcSyncrepl
EOF
# 然后重新 add olcSyncrepl 即可触发 refresh
```

### Case 4.2 双主写冲突，某条目被"还原"

**现象**：alice 在 m1 改了 mail，5s 后查发现还是旧值。

**根因**：MMR 双向同步，时钟不同步导致 entryCSN 大小判断混乱。

**排查 + 修复**：
```bash
# 1. 强制 NTP 同步（双主时钟差 >100ms 必出问题）
chronyc tracking
chronyc sources

# 2. 接入 LB 时启会话粘连（按 source-IP hash 路由）
# HAProxy: balance source

# 3. 必要时降级为单主+多从
```

### Case 4.3 从节点说 "Unable to start refresh"，cookie 失效

**日志**：
```
slapd[12345]: do_syncrep2: rid=001 cookie=...
slapd[12345]: do_syncrep2: rid=001 LDAP_RES_SEARCH_RESULT (53) Server is unwilling to perform
```

**根因**：accesslog 已 purge 过这个 cookie，必须全量重传。

**修复**：
```bash
# 删 cookie 文件（OpenLDAP 2.5+ 在 /etc/openldap/slapd.d 中）
# 实际办法：删除 syncrepl 然后重加，触发 refresh
```

---

## 5. 复杂集成问题

### Case 5.1 Ranger UserSync 同步成功但 Ranger UI 看不到组

**排查**：
```bash
# 1. 看 usersync log
tail -f /var/log/ranger/usersync/usersync.log | grep -i group
# Number of users found: 1234, groups found: 0  ← 组同步失败

# 2. 看配置
grep -E "GROUP_SEARCH_ENABLED|GROUP_OBJECT_CLASS|GROUP_MEMBER_ATTR" \
  /etc/ranger/usersync/conf/install.properties
```

**常见根因**：
1. `SYNC_GROUP_SEARCH_ENABLED=false`（默认 false！）
2. `SYNC_GROUP_MEMBER_ATTRIBUTE_NAME=member` 但 LDAP 实际是 `memberUid`
3. group_search_base 配错了 OU

### Case 5.2 Knox / Hue 走 LDAP 但慢，每个 API 一秒+

**根因**：每次请求都新建 LDAP 连接 + StartTLS handshake（300ms~1s）。

**修复**：
- Knox：用 `KnoxLdapRealm` + 配置 `connection-pool: true`
- Hue：开 `[ldap] sync_groups_on_login=false`，避免每次登录全量同步

### Case 5.3 SSSD 跨子网慢，某个客户端登陆要 30s

**根因**：SSSD 默认每个域只用第一个 server，第一个不可达时 timeout 30s 才切。

**修复**：
```ini
# /etc/sssd/sssd.conf
[domain/bigdata.local]
ldap_uri = ldaps://m1.bigdata.local,ldaps://m2.bigdata.local,ldaps://r1.bigdata.local
ldap_network_timeout = 3      # 默认 6
ldap_opt_timeout = 5          # 默认 6
```

### Case 5.4 启 Kerberos 后 LDAP 客户端报 `KDC has no support for encryption type`

**根因**：JDK 默认禁用部分加密类型（如 `arcfour-hmac`）。

**修复**：
```bash
# /etc/krb5.conf
[libdefaults]
default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
```

JDK：去掉 `crypto.policy=limited`，用 unlimited。

---

## 6. 数据问题

### Case 6.1 `objectClass: posixAccount requires uidNumber`

**现象**：导入用户报 65。

**根因**：必填属性缺失（看 `/etc/openldap/schema/nis.schema`）。

**修复**：补全必填项（uid, cn, uidNumber, gidNumber, homeDirectory）。

### Case 6.2 `attribute "userPassword" provided more than once`

**现象**：modify 时报 20。

**根因**：用 `add` 但属性已存在。

**修复**：改 `replace`：
```ldif
changetype: modify
replace: userPassword     # ← 而不是 add
userPassword: ...
```

### Case 6.3 用户名含中文 / 特殊字符导入失败

**根因**：LDIF 默认 ASCII，非 ASCII 必须 base64 编码（行用 `::` 而非 `:`）。

**修复**：
```ldif
cn:: 5byg5LiJ              # base64 of "张三"
# 或用 ldapmodify -i input.ldif 让客户端处理
```

或在 LDIF 头部声明：`version: 1`。

### Case 6.4 写操作报 53 unwillingToPerform

**根因**：连到了从节点 / 节点处于 readonly。

**修复**：
```bash
# 看节点状态
ldapsearch -Y EXTERNAL -H ldapi:/// -b "olcDatabase={2}mdb,cn=config" olcReadOnly

# 客户端用 LB 时，写请求路由到主
# HAProxy 配置中加 `tcp-check connect ssl` + `option ldap-check`
```

---

## 7. 安全相关

### Case 7.1 安全扫描报 `LDAP allows anonymous bind`

**修复**：
```ldif
dn: cn=config
changetype: modify
add: olcDisallows
olcDisallows: bind_anon
-
add: olcRequires
olcRequires: bind, LDAPv3
```

### Case 7.2 被暴力破解：某账号每秒 50 次失败

**应急**：
```bash
# 1. 临时锁该账号
ldapmodify ... <<EOF
dn: uid=victim,ou=People,dc=bigdata,dc=local
changetype: modify
add: pwdAccountLockedTime
pwdAccountLockedTime: 000001010000Z
EOF

# 2. 防火墙拉黑攻击 IP
iptables -A INPUT -s 1.2.3.4 -j DROP

# 3. ppolicy 调严：失败 3 次就锁，锁 1 小时
```

**长期**：fail2ban + LDAP filter：
```ini
# /etc/fail2ban/filter.d/openldap.conf
[Definition]
failregex = conn=\d+ op=\d+ RESULT tag=97 err=49 .* dn="<HOST>"
```

### Case 7.3 `userPassword` 字段被普通用户读到

**现象**：渗透测试发现 alice 能 `ldapsearch ... uid=bob userPassword` 拿到 SSHA 哈希。

**根因**：ACL 漏配。

**修复**：见 03-§3 ACL 模板，`{0}` 行必须 `by * none`。

### Case 7.4 AuthZ regex 错配，导致权限提升

**现象**：SASL 用户都被映射到 admin。

**根因**：`olcAuthzRegexp` 正则太宽：
```
olcAuthzRegexp: uid=(.*),cn=auth ...   # ← 危险
```

**修复**：精确化：
```
olcAuthzRegexp: uid=([^,]+),cn=BIGDATA.LOCAL,cn=GSSAPI,cn=auth uid=$1,ou=People,dc=bigdata,dc=local
```

---

## 8. AD 接入小坑（混合域专用）

### Case 8.1 用户登录 AD 后 HS2 失败

**现象**：用户在 Windows 域改了密码，HS2 还是用旧密码失败 5 次后锁。

**根因**：sAMAccountName 大小写、域前缀（`DOMAIN\\alice` vs `alice`）混淆。

**修复**：
```xml
<property>
  <name>hive.server2.authentication.ldap.guidKey</name>
  <value>sAMAccountName</value>
</property>
<property>
  <name>hive.server2.authentication.ldap.Domain</name>
  <value>BIGDATA.LOCAL</value>             <!-- HS2 自动拼 user@domain -->
</property>
```

### Case 8.2 嵌套组（Group of Groups）查不到

**根因**：AD 嵌套组需要 `LDAP_MATCHING_RULE_IN_CHAIN`：
```
(memberOf:1.2.840.113556.1.4.1941:=cn=group,...)
```

**修复**：在 `groupFilter` 用此扩展过滤。

### Case 8.3 referral 跨林导致超时

**修复**：`referral=ignore` + 显式指定每个域控的 LDAP URL。

---

## 9. 客户端工具问题

### Case 9.1 `ldapsearch -W` 不接受密码

**根因**：终端不交互（管道里）。改 `-w 'pwd'` 或 `-y password.file`。

### Case 9.2 `ldapsearch` 跨多 OU 没结果

**修复**：把 baseDN 提到 `dc=bigdata,dc=local` + `-s sub`（默认 sub）。

### Case 9.3 Apache Directory Studio 改条目报 50

**根因**：Studio 默认用 starttls 但服务端不支持。改 `Use plain LDAP / LDAPS`。

---

## 10. 排障方法论（Eric 经验总结）

### 10.1 黄金五问

```
1. 什么时候开始的？（找时间窗口）
2. 受影响范围？（单用户 / 单组件 / 全集群）
3. 最近变更了什么？（配置 / 代码 / 证书 / 密码 / 网络）
4. 直接 ldapsearch 能否复现？（剥离客户端）
5. 是认证失败、网络失败、还是数据失败？（三大类）
```

### 10.2 Probe 工具箱

| 用途 | 命令 |
|------|------|
| 端口连通性 | `nc -zv host port` / `nmap -p` |
| TLS 握手 | `openssl s_client -connect host:636 -showcerts` |
| 匿名查 RootDSE | `ldapsearch -x -H ldaps://h -s base -b ""` |
| bind 测试 | `ldapwhoami -x -D "<DN>" -w pwd` |
| ACL 调试 | `slapacl -D "<from>" -b "<to>" attr/access` |
| 配置导出 | `slapcat -F /etc/openldap/slapd.d -n 0` |
| 实时日志 | `tail -f /var/log/slapd.log | grep err=` |
| 连接监控 | `ldapsearch ... -b "cn=Monitor"` |
| 复制状态 | `ldapsearch ... -s base -b "<suffix>" contextCSN` |
| 抓包 | `tcpdump -i any port 389 or port 636 -w ldap.pcap` + Wireshark |

### 10.3 常见误区

```
❌ "应该是 LDAP 挂了" → 没有 ldapwhoami 验证就下结论
❌ "ldapsearch 能查就没问题" → 忘了客户端连接池缓存
❌ "改完配置 restart 一下" → 改 cn=config 不需要重启，但改 ldap.conf 需要
❌ "随便配 referral=follow" → 跨域劫持隐患
❌ "ACL 怎么测试都对" → 实际生效顺序按 olcAccess 编号 0/1/2…，先匹配先生效
❌ "时钟不重要" → MMR 时钟差 >100ms 必踩坑
```

---

## 11. 应急响应剧本（Runbook）

### 11.1 LDAP 全集群宕机

```
T+0     :  接告警，全员上线
T+2 min :  确认范围（一个机房？全网？）
T+5 min :  尝试 systemctl status / restart slapd
T+10 min:  若启动失败 → slapd -d 1 单步看错误
T+15 min:  若启动后立即崩溃 → 备份 /var/lib/ldap → 用 slapadd 从 LDIF 恢复到测试环境验证
T+20 min:  若数据损坏 → 切换到只读副本 + 客户端改 LDAP URL
T+30 min:  恢复主集群 → 灰度切回
T+1 hr  :  写复盘
```

### 11.2 复制全断（双主分裂）

```
1. 立即在所有客户端只读化（防止双写冲突扩大）
2. 选一个节点为"权威"，其他节点 slapcat → 比对 → 决议
3. 重置 syncrepl + cookie，从权威节点全量同步
4. 客户端逐步恢复写入
5. 复盘：为什么 NTP 没告警？
```

---

## 12. 参考与延伸

- OpenLDAP FAQ-O-Matic: https://www.openldap.org/faq/
- RFC 4511 (LDAP Protocol)
- RFC 4513 (LDAP Authentication Methods)
- Symas Knowledgebase: https://repo.symas.com/
- 《LDAP System Administration》Gerald Carter（经典书）

---

> 📌 上一篇：03-日常运维 | 主索引：README.md
