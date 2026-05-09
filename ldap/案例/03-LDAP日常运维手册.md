# LDAP 日常运维手册（Day 2 Operations）

> 作者：Eric（豹纹）| 配套：01-搭建手册 / 02-集成配置  
> 目标：用户管理、密码策略、ACL、备份恢复、监控、调优、灾难演练全套 SOP

---

## 1. 用户与组管理

### 1.1 LDIF 模板库（直接套用）

#### 1.1.1 新增用户

```bash
cat > /tmp/add-user.ldif <<EOF
dn: uid=charlie,ou=People,dc=bigdata,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: charlie
cn: Charlie Liu
sn: Liu
givenName: Charlie
mail: charlie@bigdata.local
employeeNumber: E20260001
telephoneNumber: 13800000001
uidNumber: 10003
gidNumber: 10003
homeDirectory: /home/charlie
loginShell: /bin/bash
userPassword: $(slappasswd -h {SSHA} -s 'Charlie@2026')
shadowLastChange: 19000
shadowMin: 1
shadowMax: 90
shadowWarning: 7
shadowInactive: 30
EOF

ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -W -f /tmp/add-user.ldif
```

#### 1.1.2 改密码（管理员）

```bash
ldappasswd -x -D "cn=admin,dc=bigdata,dc=local" -W \
  -s 'NewPwd@2026' "uid=charlie,ou=People,dc=bigdata,dc=local"
```

#### 1.1.3 用户自助改密码

```bash
ldappasswd -x -D "uid=charlie,ou=People,dc=bigdata,dc=local" -W \
  -a 'OldPwd' -s 'NewPwd@2026'
# -a 旧密码 -s 新密码
```

#### 1.1.4 锁定/解锁账号

```bash
# 锁定（写 pwdAccountLockedTime）
cat <<EOF | ldapmodify -x -D "cn=admin,dc=bigdata,dc=local" -W
dn: uid=charlie,ou=People,dc=bigdata,dc=local
changetype: modify
add: pwdAccountLockedTime
pwdAccountLockedTime: 000001010000Z
EOF

# 解锁
cat <<EOF | ldapmodify -x -D "cn=admin,dc=bigdata,dc=local" -W
dn: uid=charlie,ou=People,dc=bigdata,dc=local
changetype: modify
delete: pwdAccountLockedTime
EOF
```

#### 1.1.5 删除用户（软删除，推荐）

```bash
# 不建议直接 ldapdelete（审计无痕迹）
# 推荐：移到 ou=Disabled 子树 + 改 loginShell=/sbin/nologin
cat <<EOF | ldapmodify -x -D "cn=admin,dc=bigdata,dc=local" -W
dn: uid=charlie,ou=People,dc=bigdata,dc=local
changetype: modrdn
newrdn: uid=charlie
deleteoldrdn: 0
newsuperior: ou=Disabled,dc=bigdata,dc=local

dn: uid=charlie,ou=Disabled,dc=bigdata,dc=local
changetype: modify
replace: loginShell
loginShell: /sbin/nologin
-
replace: pwdAccountLockedTime
pwdAccountLockedTime: 000001010000Z
EOF
```

#### 1.1.6 加入/移出组

```bash
# 加入（posixGroup 用 memberUid）
cat <<EOF | ldapmodify -x -D "cn=admin,dc=bigdata,dc=local" -W
dn: cn=data-engineer,ou=Groups,dc=bigdata,dc=local
changetype: modify
add: memberUid
memberUid: charlie
EOF

# 移出
cat <<EOF | ldapmodify -x -D "cn=admin,dc=bigdata,dc=local" -W
dn: cn=data-engineer,ou=Groups,dc=bigdata,dc=local
changetype: modify
delete: memberUid
memberUid: charlie
EOF
```

### 1.2 批量操作脚本

#### 1.2.1 CSV 批量导入

```bash
#!/bin/bash
# batch-add-users.sh   CSV 格式：uid,cn,sn,mail,uidNumber,gidNumber,password
CSV=$1
ADMIN_DN="cn=admin,dc=bigdata,dc=local"
ADMIN_PWD="AdminPwd@2026"
OUT=/tmp/batch-add.ldif
> $OUT

while IFS=, read uid cn sn mail uidNum gidNum pwd; do
  PWD_HASH=$(slappasswd -h {SSHA} -s "$pwd")
  cat >> $OUT <<EOF
dn: uid=${uid},ou=People,dc=bigdata,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${uid}
cn: ${cn}
sn: ${sn}
mail: ${mail}
uidNumber: ${uidNum}
gidNumber: ${gidNum}
homeDirectory: /home/${uid}
loginShell: /bin/bash
userPassword: ${PWD_HASH}

EOF
done < $CSV

ldapadd -x -D "$ADMIN_DN" -w "$ADMIN_PWD" -f $OUT
```

#### 1.2.2 全量导出

```bash
ldapsearch -x -D "cn=admin,dc=bigdata,dc=local" -W \
  -b "ou=People,dc=bigdata,dc=local" \
  "(objectClass=posixAccount)" \
  uid cn mail uidNumber gidNumber > /tmp/users.ldif
```

---

## 2. 密码策略（ppolicy）

### 2.1 启用 ppolicy overlay

```bash
# 1. 加载模块
cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy.la
EOF

# 2. 在主库挂 overlay
cat <<EOF | ldapadd -Y EXTERNAL -H ldapi:///
dn: olcOverlay=ppolicy,olcDatabase={2}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: cn=default,ou=Policies,dc=bigdata,dc=local
olcPPolicyHashCleartext: TRUE
olcPPolicyUseLockout: TRUE
olcPPolicyForwardUpdates: FALSE
EOF

# 3. 创建 Policies OU + 默认策略
ldapadd -x -D "cn=admin,dc=bigdata,dc=local" -W <<EOF
dn: ou=Policies,dc=bigdata,dc=local
objectClass: organizationalUnit
ou: Policies

dn: cn=default,ou=Policies,dc=bigdata,dc=local
objectClass: pwdPolicy
objectClass: device
cn: default
pwdAttribute: userPassword
pwdMinLength: 12                    # 最小长度
pwdMinAge: 0
pwdMaxAge: 7776000                  # 90 天过期（秒）
pwdInHistory: 5                     # 不能与最近 5 个相同
pwdCheckQuality: 2                  # 强制质量检查（需 pwQuality 模块）
pwdMaxFailure: 5                    # 5 次失败锁定
pwdFailureCountInterval: 1800       # 30 分钟内累计
pwdLockout: TRUE
pwdLockoutDuration: 1800            # 锁定 30 分钟（0=永久）
pwdAllowUserChange: TRUE
pwdSafeModify: FALSE
pwdMustChange: TRUE                 # 管理员重置后必须改
pwdExpireWarning: 604800            # 过期前 7 天预警
pwdGraceAuthNLimit: 3               # 过期后宽限登录次数
EOF
```

### 2.2 验证

```bash
# 故意输错 5 次，第 6 次应被锁
for i in {1..6}; do
  ldapwhoami -x -D "uid=charlie,ou=People,dc=bigdata,dc=local" -w 'WrongPwd'
done
# 第 6 次报：ldap_bind: Invalid credentials (49); additional info: Account locked

# 查锁状态
ldapsearch -x -D "cn=admin,..." -W -b "uid=charlie,ou=People,dc=bigdata,dc=local" \
  '+' pwdAccountLockedTime pwdFailureTime
```

### 2.3 强密码哈希（必须）

```bash
# 默认 SSHA 已不够安全，升级 SSHA512 或 ARGON2
cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: pw-argon2.la
-
replace: olcPasswordHash
olcPasswordHash: {ARGON2}
EOF
```

---

## 3. ACL 进阶（生产模板）

```ldif
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcAccess
# 0. 密码字段：本人改、匿名 auth、管理员管、其他禁
olcAccess: {0}to attrs=userPassword,shadowLastChange,pwdHistory,pwdChangedTime
  by self =xw
  by anonymous auth
  by group/groupOfNames/member.exact="cn=ldap-admins,ou=Groups,dc=bigdata,dc=local" write
  by * none

# 1. RootDSE 公开
olcAccess: {1}to dn.base=""
  by * read

# 2. 服务账号 OU：只读账号能查，其他禁
olcAccess: {2}to dn.subtree="ou=Services,dc=bigdata,dc=local"
  by dn.exact="cn=admin,dc=bigdata,dc=local" write
  by group/groupOfNames/member.exact="cn=ldap-admins,ou=Groups,dc=bigdata,dc=local" write
  by users read
  by * none

# 3. People：本人改本人，admin 写，其他用户读基本属性
olcAccess: {3}to dn.subtree="ou=People,dc=bigdata,dc=local"
  by self write
  by group/groupOfNames/member.exact="cn=ldap-admins,ou=Groups,dc=bigdata,dc=local" write
  by users read
  by * none

# 4. Groups：admin 写，其他读
olcAccess: {4}to dn.subtree="ou=Groups,dc=bigdata,dc=local"
  by group/groupOfNames/member.exact="cn=ldap-admins,ou=Groups,dc=bigdata,dc=local" write
  by users read
  by * none

# 5. 兜底：禁
olcAccess: {5}to *
  by group/groupOfNames/member.exact="cn=ldap-admins,ou=Groups,dc=bigdata,dc=local" write
  by * none
```

### ACL 测试工具

```bash
slapacl -D "uid=charlie,ou=People,dc=bigdata,dc=local" \
  -b "uid=alice,ou=People,dc=bigdata,dc=local" \
  userPassword/read
# entry: =0
# attr: =0   ← 0=拒绝, =rwxd=允许
```

---

## 4. 备份与恢复

### 4.1 在线备份（不停服，推荐）

```bash
#!/bin/bash
# /opt/scripts/ldap-backup.sh
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=/data/backup/ldap
mkdir -p $BACKUP_DIR

# 1. 配置备份（cn=config）
slapcat -F /etc/openldap/slapd.d -n 0 \
  -l ${BACKUP_DIR}/config_${DATE}.ldif

# 2. 数据备份（mdb 主库）
slapcat -F /etc/openldap/slapd.d -n 2 \
  -l ${BACKUP_DIR}/data_${DATE}.ldif

# 3. accesslog 备份（复制状态）
slapcat -F /etc/openldap/slapd.d -n 3 \
  -l ${BACKUP_DIR}/accesslog_${DATE}.ldif

# 4. 证书备份
tar czf ${BACKUP_DIR}/certs_${DATE}.tgz /etc/openldap/certs

# 5. 压缩 + 上传 S3/HDFS
gzip ${BACKUP_DIR}/*_${DATE}.ldif
hdfs dfs -put ${BACKUP_DIR}/*_${DATE}.* /backup/ldap/

# 6. 保留 30 天
find $BACKUP_DIR -name "*.gz" -mtime +30 -delete
find $BACKUP_DIR -name "*.tgz" -mtime +30 -delete

# 7. 校验
gunzip -t ${BACKUP_DIR}/data_${DATE}.ldif.gz && echo "Backup OK"
```

cron：
```cron
0 2 * * * /opt/scripts/ldap-backup.sh >> /var/log/ldap-backup.log 2>&1
```

### 4.2 整库恢复（灾难场景）

```bash
# 1. 停服
systemctl stop slapd

# 2. 清空数据目录
rm -rf /var/lib/ldap/* /etc/openldap/slapd.d/*

# 3. 恢复 cn=config
slapadd -F /etc/openldap/slapd.d -n 0 -l config_20260509.ldif
chown -R ldap:ldap /etc/openldap/slapd.d /var/lib/ldap

# 4. 恢复数据
slapadd -F /etc/openldap/slapd.d -n 2 -l data_20260509.ldif
chown -R ldap:ldap /var/lib/ldap

# 5. 启动
systemctl start slapd

# 6. 验证
ldapsearch -x -D "cn=admin,..." -W -b "dc=bigdata,dc=local" "(uid=alice)"
```

### 4.3 单条恢复

```bash
# 从 LDIF 中提取
ldapsearch -x -D "cn=admin,..." -W -L -L -L \
  -b "uid=alice,ou=People,dc=bigdata,dc=local" > alice.ldif

# 删除并重建
ldapdelete -x -D "cn=admin,..." -W "uid=alice,ou=People,dc=bigdata,dc=local"
ldapadd -x -D "cn=admin,..." -W -f alice.ldif
```

---

## 5. 监控告警

### 5.1 关键指标

| 指标 | 数据源 | 告警阈值 |
|------|-------|---------|
| 连接数 | `monitorCounter` cn=Total,cn=Connections,cn=Monitor | >5000 |
| 操作 QPS | `monitorOpCompleted` cn=Operations,cn=Monitor | 突降 50% |
| 复制延迟 | `contextCSN` 主从对比 | >60s |
| 后端大小 | `olcDbMaxSize` 使用率 | >80% |
| 文件描述符 | `lsof -p $(pidof slapd) | wc -l` | >5w |
| TLS 证书有效期 | `openssl x509 -enddate` | <30 天 |
| 失败认证 | bindFailures (cn=Monitor) | 突增 |

### 5.2 启用 cn=monitor

```bash
ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
dn: olcDatabase={1}monitor,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMonitorConfig
olcDatabase: {1}monitor
olcAccess: to dn.subtree="cn=Monitor"
  by dn.exact="cn=admin,dc=bigdata,dc=local" read
  by * none
EOF
```

查询：
```bash
ldapsearch -x -D "cn=admin,dc=bigdata,dc=local" -W -b "cn=Monitor" \
  "(|(cn=Total)(cn=Current))"
```

### 5.3 Prometheus 集成

部署 [openldap_exporter](https://github.com/tomcz/openldap_exporter)：

```yaml
# /etc/openldap_exporter/config.yaml
ldapAddr: ldaps://localhost:636
ldapUser: cn=monitor-readonly,ou=Services,dc=bigdata,dc=local
ldapPass: MonPwd@2026
interval: 30s
metricsAddr: ":9330"
```

Prometheus 抓取后，关键 metric：
- `openldap_monitor_counter_object{dn=...}`
- `openldap_scrape_counter_total`
- `openldap_replication_master_csn`

### 5.4 Grafana Dashboard 关键面板

```
1. 总览：QPS、错误率、连接数
2. 复制健康：主从 CSN 差值
3. 后端：mdb 大小、txn 数
4. TLS：证书剩余天数
5. 失败认证 Top 用户
```

### 5.5 关键告警规则（PromQL）

```yaml
- alert: LDAPHighReplicationLag
  expr: max(openldap_master_csn) - min(openldap_master_csn) > 60
  for: 2m
  annotations:
    summary: "LDAP 复制延迟 >60s"

- alert: LDAPDown
  expr: up{job="openldap"} == 0
  for: 1m
  annotations:
    summary: "LDAP 节点 {{$labels.instance}} 宕机"

- alert: LDAPCertExpiry
  expr: openldap_tls_cert_expiry_days < 30
  annotations:
    summary: "LDAP TLS 证书 {{$labels.instance}} 剩余 {{$value}} 天"

- alert: LDAPHighBindFailureRate
  expr: rate(openldap_bind_failures_total[5m]) > 10
  annotations:
    summary: "LDAP 认证失败率突增（可能被暴力破解）"
```

---

## 6. 性能调优 Day 2

### 6.1 慢查询分析

```bash
# 启日志，等级 stats+sync
cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: stats sync
EOF

# 用 logrotate + grep 分析
grep "SRCH" /var/log/slapd.log | awk '{print $8,$9,$10,$11,$12}' | sort | uniq -c | sort -rn | head
```

### 6.2 cn=accesslog 分析（更精确）

```bash
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(reqResult=0)" reqDN reqType reqStart reqEnd \
  | awk '/reqStart/{s=$2} /reqEnd/{print $2-s}'
```

### 6.3 索引补漏

```bash
# 看哪些查询走了全表扫描（需要 stats 日志）
grep "no equality index" /var/log/slapd.log | awk '{print $NF}' | sort -u
# 输出例：mail, employeeNumber → 立即补索引
```

### 6.4 连接池调优

客户端侧（Hadoop/Hive/Trino）：
- **不要为每个请求新建连接** —— 用 LdapConnectionPool
- 默认连接数：HDFS 10、HS2 20、Ranger 50
- Trino：`ldap.cache-ttl=1h` 缓存绑定结果
- SSSD：`ldap_connection_expire_timeout=600`

---

## 7. 复制运维

### 7.1 复制状态健康检查

```bash
# m1 上查 m1 的 contextCSN
ldapsearch -x -H ldap://ldap-m1 -D "cn=admin,..." -W \
  -b "dc=bigdata,dc=local" -s base "(objectclass=*)" contextCSN

# m1 上查 m2 的 contextCSN
ldapsearch -x -H ldap://ldap-m2 -D "cn=admin,..." -W \
  -b "dc=bigdata,dc=local" -s base "(objectclass=*)" contextCSN

# 两边 contextCSN 应几乎相同（差值 <100ms）
```

### 7.2 复制中断恢复

**症状**：主库写入后从库不更新。

```bash
# 1. 看 syncrepl cookie
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" \
  "(olcSyncrepl=*)" olcSyncrepl

# 2. 看 accesslog 是否堆积
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  -s one "(reqResult=0)" | wc -l

# 3. 强制重新同步（只在测试或万不得已时）
systemctl stop slapd
slapadd -F /etc/openldap/slapd.d -n 2 \
  -l <(ldapsearch -x -H ldap://ldap-m1 -D "cn=admin,..." -W \
       -b "dc=bigdata,dc=local")
systemctl start slapd

# 4. 临时降级：从节点改为只读模式
cat <<EOF | ldapmodify -Y EXTERNAL -H ldapi:///
dn: olcDatabase={2}mdb,cn=config
changetype: modify
replace: olcReadOnly
olcReadOnly: TRUE
EOF
```

### 7.3 RID 冲突修复

复制 RID 必须唯一：m1=001 复制 m2=002，m2=001 复制 m1=002，**不要重复**。

```bash
# 查
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" olcSyncrepl | grep rid=
```

---

## 8. 证书运维

### 8.1 证书到期告警

```bash
# /opt/scripts/check-cert.sh
DAYS=$(( ( $(date -d "$(openssl x509 -enddate -noout -in /etc/openldap/certs/ldap-m1.crt | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
if [ $DAYS -lt 30 ]; then
  echo "WARN: cert expires in $DAYS days" | mail -s "LDAP cert" sre@bigdata.local
fi
```

### 8.2 滚动换证

```bash
# 1. 生成新证书（保持私钥不变也可以；推荐换私钥）
# 2. 测试新证书：先在一个节点替换 + 重启 + 客户端测试
cp /etc/openldap/certs/ldap-m1.crt /etc/openldap/certs/ldap-m1.crt.bak
cp /tmp/new/ldap-m1.crt /etc/openldap/certs/
systemctl restart slapd
openssl s_client -connect ldap-m1:636 < /dev/null | openssl x509 -dates -noout

# 3. 滚动其他节点
# 4. 客户端 truststore 提前加新 CA（不要替换，先并存）
keytool -import -alias bigdata-ca-2026 -file new-ca.crt \
  -keystore truststore.jks -storepass changeit
```

---

## 9. 灾难演练（季度必做）

### 9.1 演练矩阵

| 场景 | 操作 | 期望恢复时间 | 期望影响 |
|------|------|------------|---------|
| 主节点宕 | `systemctl stop slapd` | 30s（HAProxy 切换） | 客户端 1 次重连 |
| 网络分区 | `iptables -A INPUT -s m2 -j DROP` | 立即（双主继续工作） | 写冲突日志 |
| 数据损坏 | 删 mdb data.mdb 一半 | 15min（slapadd 恢复） | 短暂只读 |
| 全节点宕 | 全停 | 30min（备份恢复） | 全集群认证失败 |
| 证书过期 | 等 1 天 | 立即（提前 30 天换证） | 客户端 SSL 失败 |
| 复制断连 7 天 | 关一个节点 7 天 | 1h（refresh 全量重传） | 该节点期间数据不更新 |

### 9.2 双盲演练 SOP

```
1. 周五下午通知：周日 02:00-04:00 演练，但不告诉具体场景
2. SRE 值班 + Kafka 应急群准备
3. 02:00 制造故障（主节点 panic）
4. 监控应在 1min 内告警
5. 值班按 runbook 处理
6. 04:00 评审：MTTD/MTTR/SLO 影响
7. 整改清单 → 下次再演
```

---

## 10. 安全加固

### 10.1 必做项

```
[ ] LDAPS/StartTLS 启用，禁明文 389（除 ldapi://）
[ ] olcAllows 不含 bind_v2、bind_anon_dn
[ ] olcDisallows: bind_anon              （禁匿名 bind）
[ ] olcRequires: bind                    （所有操作需先 bind）
[ ] ACL 禁 userPassword 普通用户读
[ ] ppolicy 启用，密码强度 + 锁定策略
[ ] 密码哈希用 ARGON2 / SSHA512，禁 SSHA / CRYPT
[ ] bind 账号最小权限 + 强密码 + 90天轮换
[ ] 防火墙限源（只允许集群 IP 段访问 389/636）
[ ] /etc/openldap/certs 700 + ldap:ldap
[ ] auditlog overlay 启用，记录所有写操作
[ ] 慢查询日志 + 失败 bind 日志接 SIEM
[ ] 定期渗透测试（nmap --script ldap-*）
```

### 10.2 禁配置（红线）

```ldif
# ❌ 禁
olcAllows: bind_anon
olcAccess: to * by anonymous read       # 任何条目允许匿名读
olcRootPW: 明文密码
referral: ldap://外网LDAP
```

### 10.3 审计日志

```bash
cat <<EOF | ldapadd -Y EXTERNAL -H ldapi:///
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: auditlog.la

dn: olcOverlay=auditlog,olcDatabase={2}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcAuditLogConfig
olcOverlay: auditlog
olcAuditlogFile: /var/log/openldap/audit.log
EOF

# 审计日志格式
# # add 1715234567 dn="cn=admin,..."
# dn: uid=alice,...
# changetype: add
# ...
```

接 SIEM：filebeat → Kafka → ES，按 `dn=admin` 触发告警。

---

## 11. 日常运维 Checklist

### 11.1 日检（5 分钟）

```bash
#!/bin/bash
# /opt/scripts/ldap-daily-check.sh

echo "=== LDAP 日检 $(date) ==="

# 1. 服务存活
systemctl is-active slapd || echo "❌ slapd 未运行"

# 2. 端口监听
ss -tlnp | grep -E ":389|:636" || echo "❌ 端口未监听"

# 3. bind 测试
ldapwhoami -x -H ldaps://localhost:636 \
  -D "cn=monitor-readonly,ou=Services,dc=bigdata,dc=local" \
  -w "MonPwd@2026" >/dev/null && echo "✓ bind OK" || echo "❌ bind 失败"

# 4. 复制延迟
M1_CSN=$(ldapsearch -x -H ldap://ldap-m1 -D "cn=admin,..." -w "$ADMIN_PWD" \
  -b "dc=bigdata,dc=local" -s base contextCSN | grep contextCSN | awk '{print $2}')
M2_CSN=$(ldapsearch -x -H ldap://ldap-m2 -D "cn=admin,..." -w "$ADMIN_PWD" \
  -b "dc=bigdata,dc=local" -s base contextCSN | grep contextCSN | awk '{print $2}')
[ "$M1_CSN" = "$M2_CSN" ] && echo "✓ 复制同步" || echo "⚠ 复制有延迟"

# 5. 证书有效期
DAYS=$(( ( $(date -d "$(openssl x509 -enddate -noout -in /etc/openldap/certs/ldap-m1.crt | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
echo "证书剩余 $DAYS 天"

# 6. 后端容量
du -sh /var/lib/ldap

# 7. 错误日志
ERRORS=$(grep -c "ERR\|ERROR" /var/log/slapd.log | tail -100)
[ $ERRORS -gt 0 ] && echo "⚠ 近期错误 $ERRORS 条"
```

### 11.2 周检（30 分钟）

- [ ] 备份验证：随机抽一份 backup 做 slapadd 到测试机
- [ ] 慢查询 Top 10 分析 + 索引优化
- [ ] 失败 bind Top 10（被刷的账号 / 错配的客户端）
- [ ] 用户/组数对账（与人事系统）
- [ ] 复制日志清理：`ldap_accesslog` 老于 7 天的 purge

### 11.3 月检（2 小时）

- [ ] 容量评估：用户数增长率 → 推算 6 个月后容量
- [ ] 性能基线：QPS / 延迟 P99 / 连接数 P99
- [ ] 凭证轮换：bind 账号密码、replicator 密码
- [ ] ACL Review：是否有越权
- [ ] 灾备演练（季度一次）
- [ ] 补丁评估：Symas / OpenLDAP 安全公告

---

> 📌 下一步：`04-LDAP常见问题排障.md` 进入故障应急篇。
