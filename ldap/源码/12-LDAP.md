# LDAP — 统一用户目录

---

## 一、概述

LDAP（Lightweight Directory Access Protocol）是统一用户目录服务，在大数据集群中作为用户和组的中央管理。

**在集群中的角色**：存储"用户是谁、属于哪个组"，供 Ranger/Hive/Kyuubi/Knox 查询。

---

## 二、在大数据集群中的位置

```
LDAP / Active Directory（统一用户目录）
  ├──→ Ranger UserSync（同步用户/组到 Ranger 做授权）
  ├──→ HiveServer2（hive.server2.authentication = LDAP）
  ├──→ Kyuubi（LDAP 登录认证）
  ├──→ Knox（网关 LDAP 认证）
  └──→ Ambari / CM（管理平台登录）
```

### 与 Kerberos 的关系

| 维度 | LDAP | Kerberos |
|------|------|----------|
| 功能 | 用户目录（who are you） | 认证协议（prove it） |
| 存什么 | 用户名/组/属性 | Principal/密钥 |
| 搭配 | Ranger UserSync 用 LDAP | 服务间用 Kerberos |
| 共存 | ✅ 通常一起用 | ✅ |

---

## 三、Ranger UserSync 同步排障

**现象**：Ranger 中看不到 LDAP 的用户/组

**排查**：
1. `ps aux | grep usersync` → 进程是否存活
2. `/var/log/ranger/usersync/usersync.log` → 查日志
3. 检查 LDAP 连接配置：
   ```properties
   ranger.usersync.ldap.url = ldap://host:389
   ranger.usersync.ldap.binddn = cn=admin,dc=example,dc=com
   ranger.usersync.ldap.searchBase = ou=users,dc=example,dc=com
   ```
4. 手动测试：`ldapsearch -x -H ldap://host:389 -D "binddn" -w pwd -b "base"`

---

## 四、HiveServer2 LDAP 认证配置

```xml
<property>
  <name>hive.server2.authentication</name>
  <value>LDAP</value>
</property>
<property>
  <name>hive.server2.authentication.ldap.url</name>
  <value>ldap://ldap-host:389</value>
</property>
<property>
  <name>hive.server2.authentication.ldap.baseDN</name>
  <value>ou=users,dc=example,dc=com</value>
</property>
```

**注意**：开启 Kerberos 的集群，如果 HS2 配了 LDAP 认证，则 LDAP 只做 HS2 登录验证，服务间通信仍走 Kerberos。
