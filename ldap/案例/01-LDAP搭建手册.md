# LDAP 搭建手册（生产级）

> 作者：Eric（豹纹）| 适用：大数据集群统一身份服务 | 双方案：OpenLDAP / 389-DS  
> 目标：30 分钟单机起、4 小时主从就绪、1 天高可用集群投产

---

## 0. 选型决策

| 维度 | OpenLDAP（slapd） | 389-DS（Red Hat Directory Server） |
|------|------------------|--------------------------------|
| 厂商 | OpenLDAP Foundation | Red Hat / Fedora |
| 安装难度 | ⭐⭐⭐ 依赖 cn=config 动态配置，门槛高 | ⭐⭐ dscreate 一键，开箱即用 |
| 性能 | 单实例 5w+ QPS，mdb 后端读极快 | 单实例 2-3w QPS，但写入更稳 |
| 复制 | syncrepl（单主/多主/镜像） | 4-Way MMR（多主复制）原生支持 |
| 管理工具 | 命令行为主（ldapadd/ldapmodify/ldapsearch） | 命令行 + Cockpit Web UI |
| 大数据生态 | 主流（CDH/HDP/CDP 默认） | 红帽系（OCP、IDM）默认 |
| 维护成本 | 配置即数据（cn=config）易踩坑 | 文件配置 + 数据库分离，清晰 |
| **大哥推荐** | ✅ **优先选 OpenLDAP**（社区资料多、与 SSSD/Kerberos 配合最稳） | 红帽订阅环境优先 |

**本手册以 OpenLDAP 2.5+ 为主线，389-DS 在 §6 单独成节。**

---

## 1. 架构规划

### 1.1 拓扑

```
                         ┌─────────────────┐
                         │   HAProxy/F5    │  VIP: ldap.bigdata.local
                         │  (LDAPS 636)    │
                         └────────┬────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                   │
        ┌─────▼─────┐       ┌─────▼─────┐       ┌─────▼─────┐
        │ ldap-m1   │◄─────►│ ldap-m2   │◄─────►│ ldap-r1   │
        │ Provider  │ MMR   │ Provider  │ sync  │ Consumer  │
        │ 8C/16G    │       │ 8C/16G    │       │ (RO)      │
        └───────────┘       └───────────┘       └───────────┘
              ▲                   ▲                   ▲
              └───────────────────┴───────────────────┘
                                  │
                  Clients: HDFS/YARN/Hive/Kyuubi/Trino/Ranger/Hue
```

### 1.2 容量规划（SRE 经验值）

| 用户规模 | 单机配置 | 节点数 | 估算 QPS |
|---------|---------|--------|---------|
| <1万 | 4C 8G SSD 100G | 2（主备） | 1k |
| 1-10万 | 8C 16G SSD 500G | 3（2主1从） | 1w |
| 10-50万 | 16C 32G SSD 1T | 4（2主2从）+ HAProxy | 5w |
| >50万 | 16C 64G NVMe 2T | 4-Way MMR + 多副本 | 10w+ |

### 1.3 目录设计（DIT, Directory Information Tree）

```
dc=bigdata,dc=local                              ← Suffix（根）
├── ou=People                                    ← 用户
│   ├── uid=alice,ou=People,dc=bigdata,dc=local
│   ├── uid=bob,ou=People,dc=bigdata,dc=local
│   └── ...
├── ou=Groups                                    ← 用户组（POSIX/AD 风格二选一）
│   ├── cn=hadoop-admin,ou=Groups,...
│   ├── cn=data-engineer,ou=Groups,...
│   └── cn=hive-readonly,ou=Groups,...
├── ou=Services                                  ← 服务账号（HS2/Kyuubi 绑定 DN 用）
│   ├── uid=svc-hive,ou=Services,...
│   └── uid=svc-readonly,ou=Services,...
├── ou=Hosts                                     ← 主机条目（NSS 用，可选）
└── cn=admin,dc=bigdata,dc=local                 ← 超级管理员
```

**命名约定（生产铁律）**：
- `dc=` 不要用公网域名（避免 DNS 冲突），用 `dc=bigdata,dc=local` 或 `dc=corp,dc=internal`
- `ou=People` 必须用 `uid` 作 RDN（不要用 `cn`，因 `cn` 可能重复）
- 服务账号单独 OU，便于 ACL 隔离
- 用户组优先用 `groupOfNames`（成员是 DN）或 `posixGroup`（成员是 uid 字符串）—— 大数据生态用 `posixGroup` 更兼容

---

## 2. OpenLDAP 单机搭建（CentOS 7/8 / Rocky / Ubuntu）

### 2.1 安装

**CentOS/Rocky 8：**
```bash
# OpenLDAP 2.4 在 CentOS 7 默认仓库；CentOS 8 需用 LTB Project 或 Symas 包
dnf install -y openldap-servers openldap-clients
systemctl enable --now slapd
```

**生产推荐：Symas OpenLDAP 2.6（官方维护版，含最新补丁）：**
```bash
cat > /etc/yum.repos.d/symas-openldap.repo <<EOF
[symas-openldap-release]
name=Symas OpenLDAP
baseurl=https://repo.symas.com/repo/yum/release/26/redhat-8/x86_64/
gpgcheck=1
gpgkey=https://repo.symas.com/repo/RPM-GPG-KEY-symas-com-signing-key
EOF
dnf install -y symas-openldap-clients symas-openldap-servers
```

**Ubuntu 20.04/22.04：**
```bash
DEBIAN_FRONTEND=noninteractive apt install -y slapd ldap-utils
# 重新配置（设置管理员密码）
dpkg-reconfigure slapd
```

### 2.2 初始化（cn=config 模式，OpenLDAP 2.4+ 标准）

OpenLDAP 2.4+ 抛弃了 `slapd.conf`，改用 **cn=config**（在线配置，配置即 LDIF 条目）。

#### 2.2.1 设置 root 密码（cn=config 的）

```bash
# 生成 SSHA 哈希
SLAPPASSWD_HASH=$(slappasswd -h {SSHA} -s 'YourStrongPwd@2026')
echo $SLAPPASSWD_HASH

# 写入 cn=config
cat > /tmp/chrootpw.ldif <<EOF
dn: olcDatabase={0}config,cn=config
changetype: modify
add: olcRootPW
olcRootPW: ${SLAPPASSWD_HASH}
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/chrootpw.ldif
```

#### 2.2.2 导入基础 Schema

```bash
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/cosine.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nis.ldif
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif
# 大数据可选：增加 ppolicy（密码策略）
ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/ppolicy.ldif
```

#### 2.2.3 创建后端数据库（mdb，推荐）

```bash
DOMAIN_HASH=$(slappasswd -h {SSHA} -s 'AdminPwd@2026')

cat > /tmp/db.ldif <<EOF
# 1. 设置 mdb 后端的 suffix 和 rootdn
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: dc=bigdata,dc=local
-
replace: olcRootDN
olcRootDN: cn=admin,dc=bigdata,dc=local
-
replace: olcRootPW
olcRootPW: ${DOMAIN_HASH}
-
add: olcDbMaxSize
olcDbMaxSize: 10737418240
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/db.ldif
```

#### 2.2.4 配置访问控制（ACL，关键！）

```bash
cat > /tmp/acl.ldif <<EOF
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword,shadowLastChange
  by self write
  by anonymous auth
  by dn="cn=admin,dc=bigdata,dc=local" write
  by * none
olcAccess: {1}to dn.base=""
  by * read
olcAccess: {2}to *
  by self write
  by dn="cn=admin,dc=bigdata,dc=local" write
  by users read
  by * none
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/acl.ldif
```

**ACL 规则解读（生产必懂）**：
- `userPassword` 任何人不可读，仅本人/管理员可改 → 防密码哈希泄漏
- `users read`：必须先认证才能查目录 → **严禁匿名查询**
- `* none`：默认拒绝兜底

#### 2.2.5 创建根条目

```bash
ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -W <<EOF
dn: dc=bigdata,dc=local
objectClass: top
objectClass: dcObject
objectClass: organization
o: BigData Cluster
dc: bigdata

dn: ou=People,dc=bigdata,dc=local
objectClass: organizationalUnit
ou: People

dn: ou=Groups,dc=bigdata,dc=local
objectClass: organizationalUnit
ou: Groups

dn: ou=Services,dc=bigdata,dc=local
objectClass: organizationalUnit
ou: Services
EOF
```

### 2.3 添加用户和组（POSIX 风格，大数据兼容）

```bash
# 添加用户 alice
PWD_HASH=$(slappasswd -h {SSHA} -s 'Alice@123')
ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -W <<EOF
dn: uid=alice,ou=People,dc=bigdata,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: alice
cn: Alice Wang
sn: Wang
mail: alice@bigdata.local
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/alice
loginShell: /bin/bash
userPassword: ${PWD_HASH}
shadowLastChange: 19000
shadowMin: 0
shadowMax: 99999
shadowWarning: 7
EOF

# 添加组 hadoop-admin
ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -W <<EOF
dn: cn=hadoop-admin,ou=Groups,dc=bigdata,dc=local
objectClass: posixGroup
cn: hadoop-admin
gidNumber: 20001
memberUid: alice
EOF
```

### 2.4 验证

```bash
# 匿名查根（应失败 → 证明 ACL 生效）
ldapsearch -x -H ldap://localhost -b "dc=bigdata,dc=local" -s base
# → 报 "Insufficient access"

# 管理员查
ldapsearch -x -D "cn=admin,dc=bigdata,dc=local" -W \
  -H ldap://localhost -b "dc=bigdata,dc=local" "(uid=alice)"

# 用户自己绑定（认证测试）
ldapwhoami -x -D "uid=alice,ou=People,dc=bigdata,dc=local" -w 'Alice@123'
# → "dn:uid=alice,ou=People,dc=bigdata,dc=local"
```

---

## 3. TLS/LDAPS 配置（必做，无 TLS 不上生产）

### 3.1 自签 CA（POC/内网）或 内部 CA 签发

```bash
# 1. 生成 CA
mkdir -p /etc/openldap/certs && cd /etc/openldap/certs
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=BigData-Internal-CA" -out ca.crt

# 2. 生成 ldap server 证书（含 SAN）
openssl genrsa -out ldap-m1.key 4096
cat > ldap-m1.cnf <<EOF
[req]
distinguished_name=req
[req_ext]
subjectAltName=@alt_names
[alt_names]
DNS.1=ldap-m1.bigdata.local
DNS.2=ldap.bigdata.local
IP.1=10.0.0.11
EOF
openssl req -new -key ldap-m1.key -out ldap-m1.csr \
  -subj "/CN=ldap-m1.bigdata.local" -config ldap-m1.cnf -extensions req_ext
openssl x509 -req -in ldap-m1.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ldap-m1.crt -days 1825 -sha256 -extfile ldap-m1.cnf -extensions req_ext

chown -R ldap:ldap /etc/openldap/certs
chmod 600 /etc/openldap/certs/*.key
```

### 3.2 注入到 cn=config

```bash
cat > /tmp/tls.ldif <<EOF
dn: cn=config
changetype: modify
add: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/openldap/certs/ca.crt
-
add: olcTLSCertificateFile
olcTLSCertificateFile: /etc/openldap/certs/ldap-m1.crt
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/openldap/certs/ldap-m1.key
-
add: olcTLSProtocolMin
olcTLSProtocolMin: 3.3
-
add: olcTLSCipherSuite
olcTLSCipherSuite: HIGH:!aNULL:!MD5:!RC4
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls.ldif
```

### 3.3 启用 LDAPS（636 端口）

```bash
# CentOS：编辑 /etc/sysconfig/slapd
sed -i 's|^SLAPD_URLS=.*|SLAPD_URLS="ldapi:/// ldap:/// ldaps:///"|' /etc/sysconfig/slapd

# Ubuntu：编辑 /etc/default/slapd
# SLAPD_SERVICES="ldap:/// ldaps:/// ldapi:///"

systemctl restart slapd
```

### 3.4 验证 TLS

```bash
# StartTLS（端口 389 升级）
ldapsearch -ZZ -x -D "cn=admin,dc=bigdata,dc=local" -W \
  -H ldap://ldap-m1.bigdata.local -b "dc=bigdata,dc=local"

# LDAPS（端口 636 直接 TLS）
ldapsearch -x -D "cn=admin,dc=bigdata,dc=local" -W \
  -H ldaps://ldap-m1.bigdata.local -b "dc=bigdata,dc=local"

# OpenSSL 直查证书
openssl s_client -connect ldap-m1.bigdata.local:636 -showcerts < /dev/null
```

---

## 4. 主主复制（MMR, Multi-Master Replication）

> ⚠️ **MMR 不是银弹**：写冲突时以 entryCSN 较大者胜，最终一致；需要前端 LB 做"会话粘连"避免冲突。  
> 大哥经验：3 节点以下用 MMR，3 节点以上用 1 主多从（syncrepl Refresh+Persist）更稳。

### 4.1 在 m1 和 m2 都启用 syncprov + accesslog

```bash
# 4.1.1 加载模块
cat > /tmp/mod.ldif <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov.la
-
add: olcModuleLoad
olcModuleLoad: accesslog.la
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/mod.ldif

# 4.1.2 配置 accesslog 数据库（专门记复制用的变更日志）
cat > /tmp/accesslog.ldif <<EOF
dn: olcDatabase={3}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {3}mdb
olcDbDirectory: /var/lib/ldap/accesslog
olcSuffix: cn=accesslog
olcRootDN: cn=admin,cn=accesslog
olcDbIndex: default eq
olcDbIndex: entryCSN,objectClass,reqEnd,reqResult,reqStart,reqDN
olcLimits: dn.exact="cn=replicator,dc=bigdata,dc=local" time.soft=unlimited time.hard=unlimited size.soft=unlimited size.hard=unlimited
EOF
mkdir -p /var/lib/ldap/accesslog && chown ldap:ldap /var/lib/ldap/accesslog
ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/accesslog.ldif

# 4.1.3 在主库启用 syncprov overlay
cat > /tmp/syncprov.ldif <<EOF
dn: olcOverlay=syncprov,olcDatabase={3}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpNoPresent: TRUE
olcSpReloadHint: TRUE

dn: olcOverlay=accesslog,olcDatabase={2}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcAccessLogConfig
olcOverlay: accesslog
olcAccessLogDB: cn=accesslog
olcAccessLogOps: writes
olcAccessLogSuccess: TRUE
olcAccessLogPurge: 07+00:00 01+00:00

dn: olcOverlay=syncprov,olcDatabase={2}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 10000
EOF
ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov.ldif
```

### 4.2 配置 ServerID 和 syncrepl

```bash
# m1 上
cat > /tmp/serverid_m1.ldif <<EOF
dn: cn=config
changetype: modify
add: olcServerID
olcServerID: 1
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/serverid_m1.ldif

# m1 配置 syncrepl 指向 m2
cat > /tmp/syncrepl_m1.ldif <<EOF
dn: olcDatabase={2}mdb,cn=config
changetype: modify
add: olcSyncrepl
olcSyncrepl: rid=002
  provider=ldap://ldap-m2.bigdata.local
  bindmethod=simple
  binddn="cn=replicator,dc=bigdata,dc=local"
  credentials=ReplPwd@2026
  searchbase="dc=bigdata,dc=local"
  type=refreshAndPersist
  retry="60 +"
  schemachecking=on
  logbase="cn=accesslog"
  logfilter="(&(objectClass=auditWriteObject)(reqResult=0))"
  syncdata=accesslog
-
add: olcMirrorMode
olcMirrorMode: TRUE
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncrepl_m1.ldif

# m2 上做对称配置（serverID=2，syncrepl 指 m1，rid=001）
```

### 4.3 创建复制账号

```bash
ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -W <<EOF
dn: cn=replicator,dc=bigdata,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: replicator
description: Replication account
userPassword: $(slappasswd -h {SSHA} -s 'ReplPwd@2026')
EOF
```

### 4.4 验证复制

```bash
# 在 m1 加用户
ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -w 'AdminPwd@2026' <<EOF
dn: uid=test-mmr,ou=People,dc=bigdata,dc=local
objectClass: inetOrgPerson
uid: test-mmr
cn: Test MMR
sn: MMR
EOF

# 立刻在 m2 查（应能查到）
ldapsearch -x -H ldap://ldap-m2.bigdata.local \
  -D "cn=admin,dc=bigdata,dc=local" -w 'AdminPwd@2026' \
  -b "dc=bigdata,dc=local" "(uid=test-mmr)"

# 看复制状态
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" \
  "(objectClass=olcSyncReplConfig)" olcSyncrepl
```

---

## 5. 性能调优（生产实战参数）

### 5.1 mdb 后端

```ldif
# 单库最大尺寸：>用户数*4KB*10 安全系数
olcDbMaxSize: 10737418240        # 10GB（10万用户够用）
olcDbMaxReaders: 1024            # 并发读上限
olcDbCheckpoint: 1024 30         # 每 1024KB 或 30 分钟做一次 checkpoint
```

### 5.2 索引（关键！）

```ldif
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcDbIndex
olcDbIndex: objectClass eq
olcDbIndex: uid eq,sub          # 用户名查询
olcDbIndex: cn eq,sub
olcDbIndex: mail eq,sub
olcDbIndex: memberUid eq        # 组成员查询（大数据组件高频）
olcDbIndex: member eq
olcDbIndex: uniqueMember eq
olcDbIndex: uidNumber eq
olcDbIndex: gidNumber eq
olcDbIndex: entryCSN eq         # 复制必需
olcDbIndex: entryUUID eq
```

**重建索引（修改后必做）**：
```bash
systemctl stop slapd
sudo -u ldap slapindex
systemctl start slapd
```

### 5.3 连接限制

```ldif
dn: cn=config
changetype: modify
replace: olcSizeLimit
olcSizeLimit: 5000              # 单次查询最多返回 5000 条
-
replace: olcTimeLimit
olcTimeLimit: 60                # 60 秒查询超时
-
replace: olcWriteTimeout
olcWriteTimeout: 30
```

### 5.4 OS 层

```bash
# /etc/security/limits.d/slapd.conf
ldap soft nofile 65536
ldap hard nofile 65536
ldap soft nproc 32768

# /etc/sysctl.d/99-ldap.conf
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65000
fs.file-max = 1000000
```

---

## 6. 389-DS 方案（红帽系简化路径）

```bash
# 1. 安装
dnf module install -y 389-ds:stable

# 2. 一键创建实例
cat > /tmp/ds.inf <<EOF
[general]
config_version=2

[slapd]
instance_name=bigdata
root_dn=cn=Directory Manager
root_password=DirMgr@2026
self_sign_cert=True

[backend-userroot]
sample_entries=yes
suffix=dc=bigdata,dc=local
EOF
dscreate from-file /tmp/ds.inf

# 3. 启用 MMR（4-Way）
dsconf bigdata replication enable --suffix="dc=bigdata,dc=local" \
  --role=supplier --replica-id=1 --bind-dn="cn=replication manager,cn=config" \
  --bind-passwd="ReplPwd@2026"

dsconf bigdata repl-agmt create --suffix="dc=bigdata,dc=local" \
  --host=ldap-m2.bigdata.local --port=636 --conn-protocol=LDAPS \
  --bind-dn="cn=replication manager,cn=config" --bind-passwd="ReplPwd@2026" \
  --bind-method=SIMPLE --init m1-to-m2

# 4. Cockpit Web UI
systemctl enable --now cockpit.socket
# 浏览器访问 https://server:9090 → Directory Server
```

---

## 7. 高可用前端（HAProxy）

```bash
# /etc/haproxy/haproxy.cfg
frontend ldaps_front
    bind *:636
    mode tcp
    option tcplog
    timeout client 1m
    default_backend ldaps_back

backend ldaps_back
    mode tcp
    balance leastconn               # 重要：避免单节点 hot
    option tcp-check
    tcp-check connect port 636 ssl
    timeout server 1m
    timeout connect 5s
    server m1 10.0.0.11:636 check inter 5s rise 2 fall 3
    server m2 10.0.0.12:636 check inter 5s rise 2 fall 3
    server r1 10.0.0.13:636 check inter 5s rise 2 fall 3 backup  # 只读副本作 backup
```

**Keepalived VIP**（可选）：用 VRRP 在 2 个 HAProxy 间漂移 VIP `10.0.0.10`。

---

## 8. 防火墙 / SELinux

```bash
# 防火墙
firewall-cmd --permanent --add-port=389/tcp
firewall-cmd --permanent --add-port=636/tcp
firewall-cmd --reload

# SELinux（如启用）
setsebool -P allow_ypbind=1
semanage port -a -t ldap_port_t -p tcp 636 2>/dev/null || true
```

---

## 9. 验收 Checklist

```
[ ] ldapsearch -x -H ldap://...  匿名查询失败（ACL 生效）
[ ] ldapsearch -x -H ldaps://... 端口 636 可用，证书校验通过
[ ] ldapwhoami -x -D "uid=user,..." -w pwd 用户绑定成功
[ ] m1 加条目后 5 秒内 m2 可查到（MMR 生效）
[ ] 关闭 m1，HAProxy 自动切到 m2，客户端无感知
[ ] cn=accesslog 中 reqStart/reqEnd 持续刷新（复制活动正常）
[ ] /var/log/slapd.log 无 ERROR
[ ] ldapsearch -E pr=1000/noprompt 翻页正常（防大查询）
[ ] systemctl reload slapd 配置热加载无报错
[ ] 备份脚本（slapcat → S3/HDFS）每天 02:00 自动跑
```

---

## 10. 参考

- OpenLDAP Admin Guide: https://www.openldap.org/doc/admin26/
- Symas OpenLDAP: https://repo.symas.com/
- 389-DS Docs: https://www.port389.org/docs/389ds/
- RFC 4510-4519（LDAP v3 协议族）

---

> 📌 下一步：阅读 `02-LDAP与大数据组件集成.md` 进入实战配置环节。
