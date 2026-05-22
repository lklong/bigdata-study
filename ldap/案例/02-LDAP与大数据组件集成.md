# LDAP 与大数据组件集成配置矩阵

> 作者：Eric（豹纹）| 配套：01-LDAP搭建手册.md  
> 原则：所有参数名均来自真实源码 / 官方默认配置文件，不编造

**前置假设**：LDAP 已按 §1 搭建好，Suffix=`dc=bigdata,dc=local`，bind 账号 `cn=admin,dc=bigdata,dc=local`。

---

## 0. 集成模式速查

| 组件 | 用 LDAP 干什么 | 集成方式 |
|------|--------------|---------|
| OS（Linux 主机） | 用户登录、UID/GID 解析 | SSSD/nslcd + nsswitch + PAM |
| HDFS / YARN | 用户→组解析（HDFS 鉴权） | LdapGroupsMapping |
| Hive Server2 | JDBC/Beeline 连接认证 | hive.server2.authentication=LDAP |
| Spark Thrift Server | 同 HS2 | 同 HS2 |
| Kyuubi | JDBC 连接认证 | kyuubi.authentication=LDAP |
| Trino / Presto | HTTPS Web/JDBC 认证 | password-authenticator.properties |
| Impala | impala-shell / JDBC 认证 | --enable_ldap_auth |
| Knox Gateway | API 网关认证 | ShiroProvider/KnoxLdapRealm |
| Ranger Admin | Web UI / API 认证 | xa_ldap_* |
| Ranger UserSync | 把 LDAP 用户/组同步到 Ranger | unixauthservice/usersync |
| Hue | Web UI 登录 | desktop.auth.backend=LdapBackend |
| Ambari / Cloudera Manager | Web UI 登录 | ambari-server setup-ldap |
| Airflow / DolphinScheduler | Web UI 登录 | flask-ldap / spring-security |

**两条认证链路**：
1. **直接 LDAP**（Hive/Kyuubi/Trino/Impala/Hue/Ranger/CM）—— 客户端把用户名密码转给服务端，服务端 bind LDAP 校验
2. **OS 级 LDAP**（HDFS/YARN/MR）—— 客户端只管报 user，服务端通过 SSSD/JNDI 查 LDAP 拿 group

⚠️ **生产规则**：直接 LDAP 必须走 LDAPS/StartTLS，否则密码明文过网。

---

## 1. OS 接入：SSSD（推荐）

> SSSD = System Security Services Daemon，红帽出品，**统一 NSS+PAM+LDAP 缓存**，是 Linux 接 LDAP 的事实标准。  
> 比 nslcd 更稳，支持离线缓存、Kerberos 集成、多域。

### 1.1 安装

```bash
# CentOS/Rocky
dnf install -y sssd sssd-ldap oddjob-mkhomedir authselect

# Ubuntu
apt install -y sssd sssd-ldap libpam-sss libnss-sss
```

### 1.2 配置 `/etc/sssd/sssd.conf`

```ini
[sssd]
config_file_version = 2
services = nss, pam, sudo
domains = bigdata.local

[domain/bigdata.local]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
ldap_uri = ldaps://ldap.bigdata.local
ldap_search_base = dc=bigdata,dc=local
ldap_user_search_base = ou=People,dc=bigdata,dc=local
ldap_group_search_base = ou=Groups,dc=bigdata,dc=local
ldap_default_bind_dn = cn=readonly,ou=Services,dc=bigdata,dc=local
ldap_default_authtok_type = password
ldap_default_authtok = ReadonlyPwd@2026
ldap_id_use_start_tls = false                    # 已用 ldaps 不需要 StartTLS
ldap_tls_cacert = /etc/openldap/certs/ca.crt
ldap_tls_reqcert = demand                        # 严格校验证书
cache_credentials = true                         # 离线缓存（LDAP 挂掉时仍能登录）
enumerate = false                                # 不列出全部用户，按需查（性能）
fallback_homedir = /home/%u
default_shell = /bin/bash

# 性能优化
ldap_search_timeout = 10
ldap_network_timeout = 5
entry_cache_timeout = 600
```

```bash
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
authselect select sssd with-mkhomedir --force
systemctl enable --now sssd oddjobd
```

### 1.3 验证

```bash
id alice                       # 应返回 uid/gid/groups
getent passwd alice            # 应有 alice 条目
su - alice                     # 应能切换
ssh alice@localhost            # 应能登录（PAM 走 LDAP）
```

---

## 2. HDFS / YARN：LdapGroupsMapping

> Hadoop 默认用 `ShellBasedUnixGroupsMapping`（`id alice` 取组），如果 OS 已接 SSSD，**保持默认就行**（推荐）。  
> 直接走 LDAP（不经 OS）的方式：`LdapGroupsMapping`，适合 NN 节点不接 SSSD 的场景。

### 2.1 `core-site.xml`

```xml
<property>
  <name>hadoop.security.group.mapping</name>
  <value>org.apache.hadoop.security.LdapGroupsMapping</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.url</name>
  <value>ldaps://ldap.bigdata.local:636</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.ssl</name>
  <value>true</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.ssl.truststore</name>
  <value>/etc/hadoop/conf/ldap-truststore.jks</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.ssl.truststore.password.file</name>
  <value>/etc/hadoop/conf/ldap-truststore.password</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.bind.user</name>
  <value>cn=readonly,ou=Services,dc=bigdata,dc=local</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.bind.password.file</name>
  <value>/etc/hadoop/conf/ldap-bind.password</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.base</name>
  <value>dc=bigdata,dc=local</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.search.filter.user</name>
  <value>(&amp;(objectClass=posixAccount)(uid={0}))</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.search.filter.group</name>
  <value>(objectClass=posixGroup)</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.search.attr.member</name>
  <value>memberUid</value>
</property>
<property>
  <name>hadoop.security.group.mapping.ldap.search.attr.group.name</name>
  <value>cn</value>
</property>
<!-- 缓存：减少 LDAP 压力 -->
<property>
  <name>hadoop.security.groups.cache.secs</name>
  <value>300</value>
</property>
<property>
  <name>hadoop.security.groups.negative-cache.secs</name>
  <value>30</value>
</property>
```

### 2.2 准备 truststore

```bash
keytool -import -trustcacerts -file /etc/openldap/certs/ca.crt \
  -alias bigdata-ldap-ca -keystore /etc/hadoop/conf/ldap-truststore.jks \
  -storepass changeit -noprompt
echo -n "changeit" > /etc/hadoop/conf/ldap-truststore.password
echo -n "ReadonlyPwd@2026" > /etc/hadoop/conf/ldap-bind.password
chmod 400 /etc/hadoop/conf/ldap-bind.password
chown hdfs:hadoop /etc/hadoop/conf/ldap-bind.password
```

### 2.3 验证

```bash
# 重启 NN/RM 后
hdfs dfsadmin -refreshUserToGroupsMappings
hdfs groups alice           # 应返回 alice 的组
yarn rmadmin -refreshUserToGroupsMappings
```

---

## 3. Hive Server2 直接 LDAP 认证

> 真实参数来自 `org.apache.hadoop.hive.conf.HiveConf` 源码，无编造。

### 3.1 `hive-site.xml`

```xml
<!-- 切换认证方式 -->
<property>
  <name>hive.server2.authentication</name>
  <value>LDAP</value>
</property>

<!-- LDAP URL，多个用逗号；ldaps 用 636 -->
<property>
  <name>hive.server2.authentication.ldap.url</name>
  <value>ldaps://ldap-m1.bigdata.local:636,ldaps://ldap-m2.bigdata.local:636</value>
</property>

<property>
  <name>hive.server2.authentication.ldap.baseDN</name>
  <value>dc=bigdata,dc=local</value>
</property>

<!-- 推荐：用 userFilter（不用 userDNPattern，更灵活） -->
<property>
  <name>hive.server2.authentication.ldap.userFilter</name>
  <value>alice,bob,svc-hive</value>          <!-- 留空=所有用户都允许 -->
</property>

<!-- 关键：guidKey，用户名属性，OpenLDAP=uid，AD=sAMAccountName -->
<property>
  <name>hive.server2.authentication.ldap.guidKey</name>
  <value>uid</value>
</property>

<!-- 组过滤（限定哪些组的人能连） -->
<property>
  <name>hive.server2.authentication.ldap.groupFilter</name>
  <value>data-engineer,hadoop-admin,hive-readonly</value>
</property>

<property>
  <name>hive.server2.authentication.ldap.groupClassKey</name>
  <value>posixGroup</value>                   <!-- OpenLDAP=posixGroup, AD=group -->
</property>

<property>
  <name>hive.server2.authentication.ldap.groupMembershipKey</name>
  <value>memberUid</value>                    <!-- posixGroup 用 memberUid; groupOfNames 用 member -->
</property>

<!-- 用 groupOfNames（成员是DN）时，反向用 member 也要配 -->
<property>
  <name>hive.server2.authentication.ldap.userMembershipKey</name>
  <value>uid</value>
</property>
```

### 3.2 truststore

```bash
keytool -import -trustcacerts -file /etc/openldap/certs/ca.crt \
  -alias bigdata-ldap-ca -keystore /etc/hive/conf/ldap-truststore.jks \
  -storepass changeit -noprompt

# hive-env.sh 追加
export HIVE_OPTS="$HIVE_OPTS -Djavax.net.ssl.trustStore=/etc/hive/conf/ldap-truststore.jks -Djavax.net.ssl.trustStorePassword=changeit"
```

### 3.3 客户端连接

```bash
beeline -u "jdbc:hive2://hs2.bigdata.local:10000/default" -n alice -p 'Alice@123'
# 或 SSL：
beeline -u "jdbc:hive2://hs2.bigdata.local:10000/default;ssl=true;sslTrustStore=/etc/hive/conf/hs2-truststore.jks;trustStorePassword=changeit" -n alice -p 'Alice@123'
```

---

## 4. Kyuubi LDAP

`$KYUUBI_HOME/conf/kyuubi-defaults.conf`：

```properties
kyuubi.authentication                          LDAP
kyuubi.authentication.ldap.url                 ldaps://ldap.bigdata.local:636
kyuubi.authentication.ldap.baseDN              dc=bigdata,dc=local
kyuubi.authentication.ldap.domain              bigdata.local
kyuubi.authentication.ldap.guidKey             uid
kyuubi.authentication.ldap.groupClassKey       posixGroup
kyuubi.authentication.ldap.groupMembershipKey  memberUid
kyuubi.authentication.ldap.userFilter          alice,bob
kyuubi.authentication.ldap.groupFilter         data-engineer,hadoop-admin
# 复用 Hive 的 truststore
kyuubi.frontend.ssl.keystore.path              /etc/kyuubi/conf/server.jks
kyuubi.frontend.ssl.keystore.password          changeit
kyuubi.frontend.ssl.enabled                    true
```

JVM 参数（`kyuubi-env.sh`）：
```bash
export KYUUBI_JAVA_OPTS="$KYUUBI_JAVA_OPTS -Djavax.net.ssl.trustStore=/etc/kyuubi/conf/ldap-truststore.jks -Djavax.net.ssl.trustStorePassword=changeit"
```

---

## 5. Trino / Presto LDAP 密码认证

> Trino 必须先有 HTTPS（无 HTTPS 不允许 password authenticator）

### 5.1 `etc/config.properties`

```properties
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/etc/trino/keystore.jks
http-server.https.keystore.key=changeit

http-server.authentication.type=PASSWORD
```

### 5.2 `etc/password-authenticator.properties`

```properties
password-authenticator.name=ldap
ldap.url=ldaps://ldap.bigdata.local:636
ldap.user-bind-pattern=uid=${USER},ou=People,dc=bigdata,dc=local
# 支持多种 DN 模板（多 OU 时用 |）
# ldap.user-bind-pattern=uid=${USER},ou=People,dc=bigdata,dc=local|uid=${USER},ou=Services,dc=bigdata,dc=local
ldap.user-base-dn=ou=People,dc=bigdata,dc=local
ldap.group-auth-pattern=(&(objectClass=posixGroup)(memberUid=${USER})(cn=trino-users))
ldap.allow-insecure=false
ldap.ssl.truststore.path=/etc/trino/ldap-truststore.jks
ldap.ssl.truststore.password=changeit
ldap.cache-ttl=1h
```

### 5.3 客户端

```bash
trino --server https://trino.bigdata.local:8443 --user alice --password
# 提示输入密码
```

---

## 6. Impala LDAP

`/etc/default/impala`：

```bash
IMPALA_SERVER_ARGS="\
  --enable_ldap_auth=true \
  --ldap_uri=ldaps://ldap.bigdata.local:636 \
  --ldap_baseDN=ou=People,dc=bigdata,dc=local \
  --ldap_user_search_basedn=ou=People,dc=bigdata,dc=local \
  --ldap_bind_pattern='uid=#UID,ou=People,dc=bigdata,dc=local' \
  --ldap_passwords_in_clear_ok=false \
  --ldap_tls=true \
  --ldap_ca_certificate=/etc/openldap/certs/ca.crt \
  --ldap_group_filter=data-engineer,hadoop-admin \
  --ldap_group_dn_pattern='cn=%sGROUP,ou=Groups,dc=bigdata,dc=local' \
  --ldap_group_membership_key=memberUid \
  --ldap_group_class_key=posixGroup"
```

---

## 7. Ranger Admin LDAP（真实参数取自 install.properties）

`ranger-admin/install.properties` 关键段（基于本地源码 `txProjects/ranger/security-admin/scripts/install.properties` 模板）：

```properties
authentication_method=LDAP

xa_ldap_url=ldaps://ldap.bigdata.local:636
xa_ldap_userDNpattern=uid={0},ou=People,dc=bigdata,dc=local
xa_ldap_groupSearchBase=ou=Groups,dc=bigdata,dc=local
xa_ldap_groupSearchFilter=(member=uid={0},ou=People,dc=bigdata,dc=local)
xa_ldap_groupRoleAttribute=cn
xa_ldap_base_dn=dc=bigdata,dc=local
xa_ldap_bind_dn=cn=readonly,ou=Services,dc=bigdata,dc=local
xa_ldap_bind_password=ReadonlyPwd@2026
xa_ldap_referral=follow
xa_ldap_userSearchFilter=(uid={0})
```

`ranger-admin/setup.sh` 后会写入 `ranger-admin-site.xml`：
```xml
<property>
  <name>ranger.ldap.url</name>
  <value>ldaps://ldap.bigdata.local:636</value>
</property>
<property>
  <name>ranger.ldap.user.dnpattern</name>
  <value>uid={0},ou=People,dc=bigdata,dc=local</value>
</property>
<property>
  <name>ranger.ldap.group.searchbase</name>
  <value>ou=Groups,dc=bigdata,dc=local</value>
</property>
```

---

## 8. Ranger UserSync（把 LDAP 同步到 Ranger）

`ranger-usersync/install.properties`：

```properties
SYNC_SOURCE=ldap

SYNC_LDAP_URL=ldaps://ldap.bigdata.local:636
SYNC_LDAP_BIND_DN=cn=readonly,ou=Services,dc=bigdata,dc=local
SYNC_LDAP_BIND_PASSWORD=ReadonlyPwd@2026
SYNC_LDAP_DELTASYNC=true                              # 增量同步（用 entryCSN）

SYNC_LDAP_SEARCH_BASE=dc=bigdata,dc=local
SYNC_LDAP_USER_SEARCH_BASE=ou=People,dc=bigdata,dc=local
SYNC_LDAP_USER_SEARCH_SCOPE=sub
SYNC_LDAP_USER_OBJECT_CLASS=posixAccount
SYNC_LDAP_USER_NAME_ATTRIBUTE=uid
SYNC_LDAP_USER_GROUP_NAME_ATTRIBUTE=memberof,ismemberof

SYNC_GROUP_SEARCH_ENABLED=true
SYNC_LDAP_GROUP_SEARCH_BASE=ou=Groups,dc=bigdata,dc=local
SYNC_GROUP_OBJECT_CLASS=posixGroup
SYNC_GROUP_NAME_ATTRIBUTE=cn
SYNC_GROUP_MEMBER_ATTRIBUTE_NAME=memberUid

# 同步周期
SYNC_INTERVAL=60                                      # 分钟

# 信任证书
SYNC_LDAP_TRUSTSTORE_FILE=/etc/ranger/usersync/conf/truststore.jks
SYNC_LDAP_TRUSTSTORE_PASSWORD=changeit
```

执行 `./setup.sh` 后启动：`ranger-usersync start`。

---

## 9. Hue LDAP

`/etc/hue/conf/hue.ini` 中 `[desktop][[ldap]]` 段：

```ini
[desktop]
  [[auth]]
    backend=desktop.auth.backend.LdapBackend

  [[ldap]]
    base_dn="dc=bigdata,dc=local"
    ldap_url=ldaps://ldap.bigdata.local:636
    use_start_tls=false
    ldap_cert=/etc/openldap/certs/ca.crt
    bind_dn="cn=readonly,ou=Services,dc=bigdata,dc=local"
    bind_password=ReadonlyPwd@2026
    search_bind_authentication=true
    create_users_on_login=true
    user_filter="objectclass=posixAccount"
    user_name_attr=uid
    group_filter="objectclass=posixGroup"
    group_name_attr=cn
    group_member_attr=memberUid

    [[[users]]]
      user_filter="objectclass=*"
      user_name_attr=uid
    [[[groups]]]
      group_filter="objectclass=*"
      group_name_attr=cn
```

执行同步：`/usr/lib/hue/build/env/bin/hue useradmin_sync_with_unix --min-uid=10000`

---

## 10. Knox Gateway（API 网关）

`{stack}/topologies/sandbox.xml`：

```xml
<topology>
  <gateway>
    <provider>
      <role>authentication</role>
      <name>ShiroProvider</name>
      <enabled>true</enabled>
      <param>
        <name>main.ldapRealm</name>
        <value>org.apache.knox.gateway.shirorealm.KnoxLdapRealm</value>
      </param>
      <param>
        <name>main.ldapContextFactory</name>
        <value>org.apache.knox.gateway.shirorealm.KnoxLdapContextFactory</value>
      </param>
      <param>
        <name>main.ldapRealm.contextFactory</name>
        <value>$ldapContextFactory</value>
      </param>
      <param>
        <name>main.ldapRealm.contextFactory.url</name>
        <value>ldaps://ldap.bigdata.local:636</value>
      </param>
      <param>
        <name>main.ldapRealm.userDnTemplate</name>
        <value>uid={0},ou=People,dc=bigdata,dc=local</value>
      </param>
      <param>
        <name>main.ldapRealm.contextFactory.authenticationMechanism</name>
        <value>simple</value>
      </param>
      <param>
        <name>urls./**</name>
        <value>authcBasic</value>
      </param>
    </provider>
  </gateway>
</topology>
```

---

## 11. Ambari / Cloudera Manager LDAP

### 11.1 Ambari

```bash
ambari-server setup-ldap \
  --ldap-url=ldap.bigdata.local:636 \
  --ldap-secondary-url= \
  --ldap-ssl=true \
  --ldap-base-dn=dc=bigdata,dc=local \
  --ldap-manager-dn=cn=readonly,ou=Services,dc=bigdata,dc=local \
  --ldap-manager-password=ReadonlyPwd@2026 \
  --ldap-user-class=posixAccount \
  --ldap-user-attr=uid \
  --ldap-group-class=posixGroup \
  --ldap-group-attr=cn \
  --ldap-member-attr=memberUid \
  --ldap-referral=follow \
  --ldap-bind-anonym=false \
  --truststore-type=jks \
  --truststore-path=/etc/ambari-server/conf/truststore.jks \
  --truststore-password=changeit

ambari-server sync-ldap --all
ambari-server restart
```

### 11.2 CM

页面：Administration → Settings → External Authentication
- Authentication Backend Order = `LDAP Then Database`
- LDAP URL = `ldaps://ldap.bigdata.local:636`
- LDAP Bind Distinguished Name = `cn=readonly,ou=Services,dc=bigdata,dc=local`
- LDAP Bind Password = `ReadonlyPwd@2026`
- LDAP Search Base = `ou=People,dc=bigdata,dc=local`
- LDAP User Search Filter = `(uid={0})`
- LDAP Group Search Base = `ou=Groups,dc=bigdata,dc=local`
- LDAP Group Search Filter = `(memberUid={0})`

---

## 12. Spark / Spark Thrift Server

Spark 自身无独立 LDAP，复用方式：
- **走 Hive Metastore + HS2**：Spark On Hive，认证下沉到 HS2
- **Spark Thrift Server**：与 HS2 同套配置（`hive-site.xml` 的 LDAP 段对它生效）
- **Livy**：在 `livy.conf` 设 `livy.server.auth.type=ldap` 然后配同 HS2 参数

---

## 13. SASL EXTERNAL：与 Kerberos 联动（高级）

> 当大数据集群启 Kerberos 后，**LDAP 也可以用 GSSAPI/SASL** 而不是 simple bind，从而打通 SSO。

`sssd.conf` 改：
```ini
auth_provider = krb5
krb5_realm = BIGDATA.LOCAL
krb5_server = kdc1.bigdata.local,kdc2.bigdata.local
ldap_sasl_mech = GSSAPI
ldap_sasl_authid = host/$(hostname -f)@BIGDATA.LOCAL
```

OpenLDAP slapd 端启 SASL：
```ldif
dn: cn=config
changetype: modify
add: olcSaslHost
olcSaslHost: ldap-m1.bigdata.local
-
add: olcSaslRealm
olcSaslRealm: BIGDATA.LOCAL
-
add: olcAuthzRegexp
olcAuthzRegexp: uid=([^,]+),cn=BIGDATA.LOCAL,cn=GSSAPI,cn=auth uid=$1,ou=People,dc=bigdata,dc=local
```

slapd 跑在 keytab `ldap/ldap-m1.bigdata.local@BIGDATA.LOCAL` 下：
```bash
# /etc/sysconfig/slapd
KRB5_KTNAME=/etc/openldap/ldap.keytab
```

---

## 14. 集成验收矩阵

| 组件 | 测试命令 | 预期 |
|------|---------|------|
| OS | `id alice` | 返回 LDAP 中的 uid/gid/groups |
| HDFS | `hdfs groups alice` | 返回 alice 所属组 |
| HS2 | `beeline -u jdbc:hive2://... -n alice -p Alice@123` | 连接成功 |
| Kyuubi | `beeline -u jdbc:hive2://kyuubi:10009/...` | 同 |
| Trino | `trino --server https://... --user alice --password` | 同 |
| Ranger | 浏览器登录 alice/Alice@123 | 进入 UI |
| Ranger UserSync | `ranger-usersync log` 显示同步成功 | 用户/组列表更新 |
| Hue | 浏览器登录 alice/Alice@123 | 进入 UI |
| Ambari | 浏览器登录 ldap 用户 | 进入 UI |

---

## 15. 关键经验（生产铁律）

1. **bind 账号最小权限**：单独建 `cn=readonly,ou=Services`，只允许查 People/Groups 子树，禁写、禁查 userPassword
2. **truststore 统一管理**：所有组件用同一份 `/etc/pki/ca-trust/source/anchors/bigdata-ldap-ca.crt`，`update-ca-trust extract` 后 JDK 自动信任
3. **缓存必须开**：HDFS `groups.cache.secs`、SSSD `entry_cache_timeout`、各组件自带 cache，否则 LDAP 一挂全集群挂
4. **多 LDAP URL 列全**：`ldap.url=ldaps://m1,ldaps://m2,ldaps://r1`，组件会按顺序故障转移
5. **不允许 referral=follow 跨域**：除非真有跨域，否则 `referral=ignore` 防被劫持到外网 LDAP
6. **groupOfNames vs posixGroup**：选一种用到底，混用必踩坑。大数据生态选 `posixGroup`（成员 = uid 字符串）
7. **AD 接入小坑**：`uid` → `sAMAccountName`，`memberUid` → `member`（成员是 DN），`posixGroup` → `group`
8. **User Filter 不要漏服务账号**：HS2/Kyuubi/Spark Thrift 都需要服务账号能登录，否则 doAs 失败

---

> 📌 下一步：`03-LDAP日常运维手册.md` 进入 Day 2 操作。
