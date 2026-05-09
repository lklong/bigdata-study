# LDAP 大数据运维手册（总览）

> 作者：Eric（豹纹）| 团队：BigData SRE AI Expert Team v3.0  
> 版本：v1.0 / 2026-05  
> 仓库：https://github.com/lklong/bigdata-study/tree/main/ldap/案例

---

## 📚 文档结构

| 序号 | 文档 | 内容 | 适用角色 |
|------|------|------|---------|
| **00** | [**LDAP 核心概念入门**](./00-LDAP核心概念入门.md) | **零基础必读**：DIT/DN/属性/Schema/LDIF/bind/search/ACL 全套术语+类比 | **新人 / 跨界** |
| 01 | [LDAP 搭建手册](./01-LDAP搭建手册.md) | 从 0 到 1 部署 OpenLDAP/389-DS、目录设计、TLS、MMR、HA | SRE 部署 |
| 02 | [LDAP 与大数据组件集成](./02-LDAP与大数据组件集成.md) | HDFS/YARN/Hive/Kyuubi/Trino/Impala/Ranger/Knox/Hue/Ambari/CM 全配置 | 平台工程师 |
| 03 | [LDAP 日常运维手册](./03-LDAP日常运维手册.md) | 用户/组管理、ppolicy、ACL、备份、监控、调优、灾难演练 | Day 2 运维 |
| 04 | [LDAP 常见问题排障](./04-LDAP常见问题排障.md) | 30+ 真实 Case，按错误码/场景分类 | 应急排障 |
| 05 | [LDAP 故障场景恢复手册](./05-LDAP故障场景恢复手册.md) | 10+ 重大灾难 Runbook，RTO/RPO/演练矩阵/复盘模板 | DR / 灾备 |

> 💡 **零基础读者请务必先看 00**：30 分钟搞懂 LDAP 全部术语，再读 01~04 不再费解。

---

## 🎯 快速索引（按场景）

### 我要做什么？

| 场景 | 直达章节 |
|------|---------|
| **完全没接触过 LDAP，啥都不懂** | **00-§ 全篇（必看）** |
| 看不懂 DN / OU / objectClass 是啥 | 00-§2~§6 |
| filter 语法 `(&(...)(...))` 看着头大 | 00-§9 search 与 filter |
| 不知道 posixGroup 和 groupOfNames 选哪个 | 00-§10 用户和组 |
| 想看完整的"alice 登录 Hive"流程 | 00-§14 串起来 |
| 新建一套 LDAP | 01-§2 OpenLDAP 单机搭建 |
| 让多套 LDAP 互为主备 | 01-§4 主主复制 MMR |
| 给集群加 LDAP 认证 | 02-§3 HS2 / §4 Kyuubi / §5 Trino |
| 让 Linux 主机用 LDAP 登录 | 02-§1 SSSD 配置 |
| HDFS 鉴权用 LDAP 组 | 02-§2 LdapGroupsMapping |
| 让 Ranger 同步 LDAP 用户 | 02-§8 Ranger UserSync |
| 加密码强度策略 | 03-§2 ppolicy |
| 备份恢复 | 03-§4 备份与恢复 |
| 接 Prometheus 监控 | 03-§5.3 |
| 用户登录失败排查 | 04-§1.1 Invalid credentials 49 |
| HS2 LDAP 认证失败 | 04-§1.2 |
| 复制不同步 | 04-§4.1 contextCSN 不一致 |
| 暴力破解应急 | 04-§7.2 |
| 全集群宕机应急 | 05-§2 S1 全节点宕机 Runbook |
| mdb 数据库损坏 | 05-§3 S2 |
| 误删全树 / 顶层 OU | 05-§4 S3 黄金恢复路径 |
| 勒索加密 / 入侵 | 05-§5 S4 事件响应 |
| 双主脑裂强制收敛 | 05-§6 S5 |
| TLS 证书全集群过期 | 05-§7 S6 |
| 备份本身坏了 | 05-§9 S8 |
| 想做季度灾备演练 | 05-§13 演练矩阵 |
| 故障复盘怎么写 | 05-§14 复盘模板 |

---

## 🏗️ 架构总览

```
                     ┌──────────────────────────────────┐
                     │     大数据集群（统一身份目录）    │
                     │                                  │
   ┌────────────┐    │    ┌──────────────────────┐     │
   │  人事系统   │───►│   │  ou=People           │     │
   │  HRIS      │    │   │  uid=alice,bob,...   │     │
   └────────────┘    │   └──────────────────────┘     │
                     │                                  │
   ┌────────────┐    │   ┌──────────────────────┐     │
   │  AD 主域    │───►│   │  ou=Groups           │     │
   │  (可选同步) │    │   │  cn=hadoop-admin,    │     │
   └────────────┘    │   │      data-engineer   │     │
                     │   └──────────────────────┘     │
                     └──────────────────────────────────┘
                                    │ LDAPS 636
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
  ┌─────────────┐            ┌─────────────┐           ┌─────────────┐
  │ OS 层 (SSSD)│            │ 认证服务层  │           │ 同步服务    │
  │ - PAM       │            │ - HS2/HMS   │           │ - Ranger    │
  │ - NSS       │            │ - Kyuubi    │           │   UserSync  │
  │ - sudo      │            │ - Trino     │           │ - Ambari    │
  └─────────────┘            │ - Impala    │           │   sync-ldap │
                             │ - Hue       │           └─────────────┘
                             │ - Knox      │
                             │ - Ranger    │
                             │ - Ambari/CM │
                             └─────────────┘
                                    │
                                    ▼ 鉴权
                             ┌─────────────┐
                             │  HDFS/YARN  │
                             │ Group Map   │
                             └─────────────┘
```

---

## 🔑 三个最重要的认知

### 1. LDAP 不是 AD，但要兼容 AD

| 特性 | OpenLDAP | AD |
|------|---------|-----|
| 用户名 | `uid` | `sAMAccountName` |
| 组成员（POSIX） | `memberUid: alice` | `member: CN=alice,...` |
| 组类 | `posixGroup` | `group` |
| 嵌套组 | 不支持 | 支持（特殊 OID 1.2.840.113556.1.4.1941） |

→ 大数据组件配置时，三件套（`guidKey`/`groupClassKey`/`groupMembershipKey`）必须匹配 LDAP 类型。

### 2. 缓存是性能的命脉，也是一致性的死敌

```
LDAP ──────── 鉴权链路 ──────── 客户端
  │                                │
  └─→ 服务端 entry cache           │
                                   ├─→ HDFS groups.cache.secs
                                   ├─→ SSSD entry_cache_timeout
                                   ├─→ Trino ldap.cache-ttl
                                   └─→ HS2 客户端连接池

⚠ 改密码后多久生效？= 链路上最长的 cache TTL
⚠ LDAP 挂了多久才被发现？= 各级 cache 失效时间总和
```

### 3. 没有 TLS 就没有 LDAP

```
明文 ldap://389  →  密码 base64 走网线  →  tcpdump 直接抓
ldaps://636     →  全程 TLS            →  生产唯一选择
StartTLS         →  389 端口升级          →  兼容老客户端可选
```

---

## 🛠️ 工具箱

### 必备命令速记

```bash
# 测连通
nc -zv ldap.bigdata.local 636

# 测 TLS
openssl s_client -connect ldap.bigdata.local:636 -showcerts < /dev/null

# 测 bind
ldapwhoami -x -H ldaps://ldap.bigdata.local:636 \
  -D "uid=alice,ou=People,dc=bigdata,dc=local" -w 'Alice@123'

# 查用户
ldapsearch -x -D "cn=admin,dc=bigdata,dc=local" -W \
  -H ldaps://ldap.bigdata.local:636 \
  -b "ou=People,dc=bigdata,dc=local" "(uid=alice)"

# 查复制状态
ldapsearch -x -H ldap://ldap-m1 -D "cn=admin,..." -W \
  -b "dc=bigdata,dc=local" -s base contextCSN

# 看监控
ldapsearch -x -D "cn=admin,..." -W -b "cn=Monitor" \
  "(|(cn=Total)(cn=Current))" 2>/dev/null

# 改密码
ldappasswd -x -D "cn=admin,..." -W -s 'NewPwd@2026' \
  "uid=alice,ou=People,dc=bigdata,dc=local"

# ACL 调试
slapacl -D "uid=alice,ou=People,dc=bigdata,dc=local" \
  -b "uid=bob,ou=People,dc=bigdata,dc=local" userPassword/read
```

### 推荐图形化工具

- **Apache Directory Studio**（免费，跨平台）
- **JXplorer**（轻量）
- **phpLDAPadmin**（Web，注意安全）
- **Cockpit + 389-DS**（红帽系）

---

## 📊 容量与性能基线（Eric 经验值）

| 场景 | 单机配置 | QPS | P99 延迟 |
|------|---------|-----|---------|
| 中小集群（<10万用户、<100节点） | 8C16G + SSD | 5k bind/s | <50ms |
| 中型集群（10-50万、100-500节点） | 16C32G + NVMe | 2w bind/s | <30ms |
| 大型集群（>50万、>500节点） | 16C64G + NVMe + LB | 5w bind/s | <20ms |

⚠️ **节点数 ≠ 用户数**：NN/RM/HS2 等服务每秒会有数百次 LDAP 查询（即使有 cache），需要扛住。

---

## 🚨 安全红线（违反 = 事故）

```
🔴 严禁明文 389 暴露在非管理网
🔴 严禁 olcAccess 中 by * read（除 RootDSE）
🔴 严禁 bind_anon
🔴 严禁 referral=follow 跨域
🔴 严禁 root 密码弱口令
🔴 严禁 userPassword 普通用户可读
🔴 严禁不接 SIEM
🔴 严禁备份只在本机
🔴 严禁多人共用 cn=admin
🔴 严禁直接 ldapdelete 用户（用软删除）
```

---

## 📈 改进路线图（增强建议）

### Phase 1（已就绪）
- [x] 主主复制 MMR
- [x] LDAPS 全链路加密
- [x] ppolicy 密码策略
- [x] Ranger UserSync

### Phase 2（推荐做）
- [ ] 接入 Kerberos（GSSAPI bind）实现 SSO
- [ ] FreeIPA 整合（DNS+CA+LDAP+KDC 四合一）
- [ ] 自助密码重置门户（Self-Service Password）
- [ ] LDAP 审计日志接 Splunk/ELK

### Phase 3（前沿）
- [ ] 接入 OIDC / SAML（让 LDAP 做后端，OIDC 做前端）
- [ ] Vault 接 LDAP 做 Secret 引擎
- [ ] 零信任：每次访问都 check ppolicy + MFA

---

## 🔗 关联学习成果

本手册输出后会与以下材料形成闭环：

```
ldap/
├── 源码/                           ← OpenLDAP 源码精读（待补）
│   ├── slapd-启动流程.md
│   ├── syncrepl-复制机制.md
│   └── mdb-后端原理.md
├── 案例/                           ← 本手册（7 篇）
│   ├── 00-LDAP核心概念入门.md       ← 零基础必读
│   ├── 01-LDAP搭建手册.md
│   ├── 02-LDAP与大数据组件集成.md
│   ├── 03-LDAP日常运维手册.md
│   ├── 04-LDAP常见问题排障.md
│   ├── 05-LDAP故障场景恢复手册.md   ← DR / 灾备 Runbook
│   └── README.md (本文件)
└── LDAP功能地图.md                 ← 概念地图
```

---

## 👨‍🔬 关于团队

**BigData SRE AI Expert Team v3.0** 由 Eric（豹纹）作为编排核心，统筹 22+ 领域专家：

- 📚 **KnowMiner**（知识矿工）：负责本手册的沉淀
- 🔬 **Probe**（探针）：贡献了真实参数的源码取证（HiveConf / Ranger install.properties）
- 🛡️ **Compliance Guardian**（合规守卫）：审核了所有"严禁"红线
- 🔗 **Cross-Correlator**（交叉关联器）：整合 OS/HDFS/HS2/Ranger/Knox 多组件视角

> 编排原则：**Agent 狭窄时最可靠 + 文档就近原则 + 源码必须真实**

---

## 📝 反馈与贡献

发现错误或想补充 Case？提 PR 到 https://github.com/lklong/bigdata-study  
线上排障踩坑案例 → 04-§ 持续更新。

> 大哥说：源码学习与故障复盘并重，案例越多，专家越值钱。
