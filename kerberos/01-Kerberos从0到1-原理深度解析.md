# Kerberos 从 0 到 1 — 原理深度解析

> 大数据 SRE 必修课 · Eric · 2026-05-09  
> 对标：MIT Kerberos V5 / RFC 4120 / RFC 4121 / Cloudera & Hortonworks 官方文档  
> 适用读者：从未接触过 Kerberos 的运维新人 → 能独立排查跨域认证问题的高级 SRE

---

## 一、为什么大数据集群必须用 Kerberos

### 1.1 不开启 Kerberos 的裸奔集群有多危险

```bash
# 裸奔的 HDFS 集群
hdfs dfs -ls /                  # 你是谁？root
hdfs dfs -ls / -fs hdfs://nn  # 我说我是 hdfs 用户
HADOOP_USER_NAME=hdfs hdfs dfs -rm -r /user/critical/*  # 我说我是 hdfs，集群信了
```

**根因**：Hadoop SimpleAuth 模式下，客户端**自报家门**就被信任，环境变量 `HADOOP_USER_NAME` 就能伪装成任何人，包括 `hdfs` 超级用户。

| 攻击场景 | 裸奔后果 |
|---------|---------|
| 任何人可读所有 HDFS 数据 | 数据泄漏 |
| 任何人可删 / | 数据全毁 |
| 任何人可往 YARN 提交任务 | 集群计算资源被占 |
| 任何人可改 HMS 元数据 | 表结构破坏 |

### 1.2 Kerberos 解决的核心问题

| 问题 | Kerberos 解法 |
|------|-------------|
| 网络上传明文密码不安全 | 密码永远不上网，只用对称密钥派生 |
| 客户端怎么证明"我就是我" | 票据（Ticket）+ 时间戳验证 |
| 服务端怎么证明"我才是真服务" | 双向认证（mutualAuth） |
| 客户端要重复登录每个服务 | 单点登录（SSO）通过 TGT 实现 |
| 中间人重放攻击 | Authenticator + 时钟同步（5 分钟窗口） |

### 1.3 Kerberos 不解决什么

> ⚠️ **Kerberos 只管"认证"（你是谁），不管"授权"（你能干啥）**

- 授权交给 Ranger / Sentry / HDFS ACL / Hive SQL Standard 鉴权
- 加密交给 SSL/TLS（Kerberos 加密的只是认证报文，业务流量需要 RPC SASL_PRIVACY 或 TLS）
- 审计交给 Ranger Audit / HDFS Audit Log

---

## 二、核心概念字典（必背）

| 术语 | 全称 | 通俗解释 | 例子 |
|------|------|---------|------|
| **KDC** | Key Distribution Center | 中央票务大厅 | `kdc01.bigdata.com:88` |
| **AS** | Authentication Server | KDC 中负责发 TGT 的窗口 | KDC 的一个进程模块 |
| **TGS** | Ticket Granting Server | KDC 中负责发 ST 的窗口 | KDC 的另一个进程模块 |
| **Realm** | 领域 / 王国 | 一个 KDC 管辖的范围，**全大写** | `BIGDATA.COM` |
| **Principal** | 身份主体 | "用户名@王国" 三段式 | `hive/hs2.bigdata.com@BIGDATA.COM` |
| **TGT** | Ticket Granting Ticket | 入园门票（凭它换景点票） | `krbtgt/BIGDATA.COM@BIGDATA.COM` |
| **ST** | Service Ticket | 景点票（每个服务一张） | `hdfs/nn.bigdata.com@BIGDATA.COM` |
| **Keytab** | Key Table | 装着 Principal 加密密钥的免密文件 | `/etc/security/keytabs/hive.keytab` |
| **KVNO** | Key Version Number | 密钥版本号（密码改一次 +1） | `KVNO 5` |
| **Authenticator** | 认证体 | 带时间戳的"我就是我"证明 | 客户端临时生成 |
| **SPN** | Service Principal Name | 服务身份名 | `HTTP/hs2.bigdata.com` |
| **SPNEGO** | Simple and Protected GSS-API Negotiation | HTTP 上的 Kerberos | Web UI 认证 |
| **GSS-API** | Generic Security Services API | Kerberos 的标准编程接口 | Java 用 sun.security.jgss |

### 2.1 Principal 三段式深度解读

```
hive/hs2.bigdata.com@BIGDATA.COM
└─┬─┘ └────┬────────┘  └────┬───┘
  │        │                  │
  │        │                  └─ Realm（领域，全大写）
  │        └─ Instance（实例，对服务来说就是 FQDN）
  └─ Primary（主名，用户名 / 服务名）
```

| Principal 类型 | 格式 | 例子 | 用途 |
|---------------|------|------|------|
| **用户型** | `user@REALM` | `kailong@BIGDATA.COM` | 人类登录 |
| **服务型** | `service/FQDN@REALM` | `hdfs/nn01.bigdata.com@BIGDATA.COM` | 守护进程身份 |
| **HTTP 服务型** | `HTTP/FQDN@REALM` | `HTTP/hs2.bigdata.com@BIGDATA.COM` | Web UI SPNEGO |
| **特殊型** | `krbtgt/REALM@REALM` | `krbtgt/BIGDATA.COM@BIGDATA.COM` | TGT 自身 |
| **跨域型** | `krbtgt/REALM_B@REALM_A` | `krbtgt/PROD.COM@DEV.COM` | 跨 Realm 信任 |

#### 2.1.1 为什么 Kerberos Principal 是三段式？（设计哲学）

> 这个问题面试和实战都会反复遇到，必须想透。三段式不是拍脑袋，是 **MIT 雅典娜计划（1980s）用最少字段表达身份认证完整语义** 的工程结晶。

##### 核心：三段对应三个**正交维度**

```
hive  /  hs2.bigdata.com  @  BIGDATA.COM
 ↑           ↑                    ↑
Primary   Instance              Realm
（谁）    （在哪/哪个实例）       （哪个王国）
```

| 维度 | 段位 | 回答的问题 | 不能省略的理由 |
|-----|------|-----------|--------------|
| **角色** | Primary | "你是谁？"（用户/服务名） | 没名字 KDC 数据库无法建索引 |
| **位置** | Instance | "你在哪台机器/哪个角色？" | 同一服务跑在多台机器上必须区分 |
| **王国** | Realm | "你属于哪个安全域？" | 跨公司/跨集群信任必须区分归属 |

> 严格说 Instance 是**可选**的（用户型常没有），形式：`Primary [/Instance] @ Realm`。习惯叫"三段式"。

##### 为什么必须有 Instance？— 三大设计动机

**① 服务必须按"机器"区分密钥（爆炸半径最小化）**

设想 100 台 DataNode 全部共用 `hdfs@BIGDATA.COM`：
- 只有一份 keytab 一份密钥
- **任何一台 DN 被攻破** → 攻击者拿到 keytab → **能伪装所有 DN**
- 想轮换密钥 → 100 台同步停机才能换

加上 Instance 后：
```
hdfs/dn01.bigdata.com@BIGDATA.COM
hdfs/dn02.bigdata.com@BIGDATA.COM
hdfs/dn03.bigdata.com@BIGDATA.COM
...
```
- 每台独立 principal、独立 keytab、独立密钥
- DN01 失陷 → **只 DN01 失陷**，DN02 不受影响
- 每台可独立轮换密钥

**这是分布式系统安全设计的核心原则：最小爆炸半径（Blast Radius Minimization）**。

**② 用户支持多个权限角色（类似 sudo）**

```
alice@BIGDATA.COM           ← 普通查询
alice/admin@BIGDATA.COM     ← KDC 管理员（kadmin 操作）
alice/root@BIGDATA.COM      ← OS root 角色
```

类比 Linux sudo / Windows "Run as Administrator"：**同一个人，不同场景用不同身份，权限分级**。

> kadm5.acl 默认规则就是 `*/admin@REALM *` —— 凡是带 `/admin` 实例的全是管理员

**③ krbtgt 用 Instance 巧妙表达"信任关系"**

```
krbtgt/BIGDATA.COM@BIGDATA.COM      ← 本域 TGT
krbtgt/HADOOP.COM@CORP.COM          ← 跨域 TGT（CORP→HADOOP 的票根）
krbtgt/PROD.COM@DEV.COM             ← 跨域 TGT（DEV→PROD）
```

Instance 在 krbtgt 这里**承载了"目标 Realm"信息**——一个字段巧妙复用，跨域信任的方向直接表达，不用引入新字段。

##### 为什么必须有 Realm？

**① 全局唯一性**：公司 AD 有 `alice@CORP.COM`，大数据有 `alice@BIGDATA.COM`——**两个完全不同的人**（或同人不同权限）。没 Realm，全网用户名要强制唯一，根本不可能。

**② 跨域信任的路由**：

```
alice@CORP.COM 想访问 hdfs/nn01@HADOOP.COM
   ↓
1. 先去 CORP.COM 的 KDC 拿 TGT
2. 跨域换 krbtgt/HADOOP.COM@CORP.COM
3. 再去 HADOOP.COM 的 KDC 拿 hdfs/nn01@HADOOP.COM 的 ST
```
没有 Realm 字段，第 2/3 步路由不知往哪走。

**③ 安全边界**：Realm 是**信任域的边界**。Realm A 的 KDC **绝对信任**域内所有 principal，但跨 Realm 必须显式建立 `krbtgt/B@A` 跨域信任。Realm 让"信任范围"清晰可控。

##### 为什么不是 2 段（合并 Primary 和 Instance）？

设想合并成 `hdfs.nn01.bigdata.com@BIGDATA.COM` —— 看似差不多，致命问题：

| 问题 | 三段式 | 合并两段 |
|-----|-------|---------|
| 服务类型识别 | `Primary=hdfs` 直接知道是 HDFS | 要解析整个字符串猜哪部分是服务 |
| **`_HOST` 占位符替换** | 替换 Instance 段干净利落 | 字符串中间替换，规则复杂易错 |
| auth_to_local 规则 | `RULE:[2:$1@$0]` 第 2 段精确匹配 | 要写复杂正则 |
| ACL 表达 | `*/admin@REALM *` 一行覆盖所有管理员 | 要枚举 |
| krbtgt 跨域 | `krbtgt/B@A` 天然表达信任方向 | 失去这种表达力 |

**Hadoop 的 `_HOST` 占位符就是依赖三段式设计**：

```xml
<property>
  <name>dfs.namenode.kerberos.principal</name>
  <value>hdfs/_HOST@BIGDATA.COM</value>
</property>
```

启动时自动把 `_HOST` 替换成 `hostname -f`——**只动 Instance 段**，Primary 和 Realm 是固定的。这种"模板化部署"两段式做不到。

##### 为什么不是 4 段或更多？

理论上可加（如 `hdfs/nn01/dc1@REALM`），但：
- KDC 数据库 schema 复杂，索引/查找性能下降
- 协议字段冗余，AS_REQ/TGS_REQ 报文变大
- 用户/管理员心智负担，记不住写错率高
- **数据中心/机房等维度可放进 Instance 子分割**（如 `hdfs/nn01.dc1.bigdata.com`，FQDN 已有层级）
- **更多权限维度交给授权层（Ranger/ACL/RBAC）**——Kerberos 不该管授权

**最小完备原则**：Primary（谁）+ Instance（哪个实例）+ Realm（哪个域）已经覆盖**身份认证**所有必需信息。其他维度交给上层。

##### 类比理解 — 三段式 = 现实世界身份识别

```
hive    /  hs2.bigdata.com  @  BIGDATA.COM
 ↓              ↓                   ↓
张三    /  北京朝阳区某街道3号   @  中华人民共和国
（人名）   （住址/精确定位）       （国家/管辖范围）
```

- **Primary = 人名**：你是谁
- **Instance = 住址**：你具体在哪（同名的人靠住址区分）
- **Realm = 国家**：你属于哪个法律体系（跨国要走信任协议 = Cross-Realm）

身份证号 = `Principal full name`（三段拼起来全局唯一），KDC = 派出所。

##### 记忆口诀

> **"谁 / 在哪 / 哪国"**  
> Primary = WHO，Instance = WHERE，Realm = WHICH WORLD  
> 三段对应三个正交维度 — 少一段有歧义，多一段是冗余。

##### 生产中的实战体现

| 场景 | 三段式如何起作用 |
|-----|---------------|
| HDFS 100 台 DN | Primary=hdfs，Instance=各 DN FQDN，**100 个独立 keytab** 实现爆炸半径隔离 |
| Hive Metastore HA | `hive/hms01@REALM` + `hive/hms02@REALM` 两个 SPN，客户端按 FQDN 拿对应 ST |
| 用户管理员双身份 | `alice@REALM`（普通）+ `alice/admin@REALM`（kadmin） |
| 跨域信任 | `krbtgt/HADOOP.COM@CORP.COM` 用 Instance 表达信任目标 |
| Hadoop _HOST | 启动时只替换 Instance 段，Primary/Realm 不变，配置模板化 |

**一句话总结**：三段式 = `(谁, 在哪, 哪个王国)` 是身份识别的最小完备坐标。少一段有歧义，多一段是冗余——这是**数学美**。

### 2.2 Keytab 文件格式（深扒）

Keytab 不是文本文件，是二进制格式（MIT 格式 v0x502），可用 `klist -kt` 查看：

```bash
$ klist -kt /etc/security/keytabs/hive.keytab
Keytab name: FILE:/etc/security/keytabs/hive.keytab
KVNO Timestamp           Principal
---- ------------------- ------------------------------------------------------
   3 2026-05-09 12:00:00 hive/hs2.bigdata.com@BIGDATA.COM (aes256-cts-hmac-sha1-96)
   3 2026-05-09 12:00:00 hive/hs2.bigdata.com@BIGDATA.COM (aes128-cts-hmac-sha1-96)
   3 2026-05-09 12:00:00 hive/hs2.bigdata.com@BIGDATA.COM (des3-cbc-sha1)
   3 2026-05-09 12:00:00 hive/hs2.bigdata.com@BIGDATA.COM (arcfour-hmac)
```

**关键字段**：
- **KVNO**：密钥版本号，`change_password` 一次就 +1，**KDC 端 KVNO 与 keytab KVNO 必须一致**否则报 `KrbException: Encryption type ... is not supported`
- **enctype**：加密算法。生产强制用 `aes256-cts-hmac-sha1-96`，DES/RC4 等已被 KDC 禁用（CVE）
- **每个加密算法一行**：同一个 Principal 的不同 enctype 各占一条记录

---

## 三、Kerberos 认证全流程（六步法图解）

> 这是面试和排障的必考点，必须烂熟于心

```
┌─────────┐                                              ┌─────────┐
│ Client  │                                              │   KDC   │
│ (kinit) │                                              │ (AS+TGS)│
└────┬────┘                                              └────┬────┘
     │                                                        │
     │  ① AS_REQ  (我是 alice，PA-ENC-TIMESTAMP 用密钥加密时间戳)│
     │ ────────────────────────────────────────────────────► │
     │                                                        │
     │  ② AS_REP  (TGT={alice信息}_krbtgt密钥, 会话密钥SK1)    │
     │ ◄──────────────────────────────────────────────────── │
     │                                                        │
     │  --- alice 现在有 TGT，存在 ccache ---                  │
     │                                                        │
     │  ③ TGS_REQ (我要访问 hdfs/nn 的票，附 TGT + Authenticator)│
     │ ────────────────────────────────────────────────────► │
     │                                                        │
     │  ④ TGS_REP (ST={alice信息}_hdfs密钥, 会话密钥SK2)       │
     │ ◄──────────────────────────────────────────────────── │
     │                                                        │
     │                                              ┌─────────┐
     │  ⑤ AP_REQ (ST + Authenticator)              │ HDFS NN │
     │ ─────────────────────────────────────────►  │         │
     │                                              │         │
     │  ⑥ AP_REP (Authenticator+1，双向认证)        │         │
     │ ◄─────────────────────────────────────────  │         │
     │                                              └─────────┘
     │  --- 认证完成，开始走业务 RPC（SASL/GSSAPI）---
```

### 3.1 步骤详解（每步都有坑）

#### Step 1: AS_REQ
- 客户端用 **principal 的密钥**（kinit 时由用户密码派生 / 或从 keytab 读取）加密**当前时间戳**
- 报文内容：`{ Pre-Auth (encrypted timestamp), client_principal, requested_realm, nonce }`
- **注**：**密码本身从不上网**，只是用密码派生的密钥加密时间戳

#### Step 2: AS_REP
- KDC 用 KDC 数据库里 alice 的密钥**解密时间戳验证身份**（PA-ENC-TIMESTAMP 预认证）
- 时间戳偏差 > 5 分钟 → **`Clock skew too great`** ❌（最常见错误 #1）
- 验证通过后返回：
  - **TGT** = `{客户端身份, SK1会话密钥, 有效期, 标志位}` 用 `krbtgt principal 的密钥` 加密
  - **SK1** 用 alice 密钥加密给 alice
- TGT 客户端打不开（不知道 krbtgt 密钥），只能整体上交给 KDC

#### Step 3: TGS_REQ
- 客户端构造 **Authenticator** = `{客户端 principal, 时间戳}`，用 SK1 加密
- 发送：`TGT + Authenticator + 我要访问的 SPN（hdfs/nn.bigdata.com@BIGDATA.COM）`

#### Step 4: TGS_REP
- KDC 用 krbtgt 密钥解开 TGT 拿到 SK1，再用 SK1 解开 Authenticator 验证身份
- **SPN 不存在 → `Server not found in Kerberos database`** ❌（最常见错误 #2）
- 返回 ST + SK2

#### Step 5: AP_REQ
- 客户端把 ST 和新构造的 Authenticator（用 SK2 加密）发给 HDFS NameNode
- NameNode 用**自己 keytab 里的密钥**解开 ST（拿到 SK2 + 客户端身份）
- 用 SK2 解开 Authenticator 验证时间戳
- **NameNode keytab 中的 SPN 与 ST 中的 SPN 必须一致**，否则 → `KrbException: Specified version of key is not available`

#### Step 6: AP_REP（可选，mutualAuth=true 时）
- NameNode 把 Authenticator 中的时间戳 +1，用 SK2 加密回送
- 客户端验证：证明对方真是 NameNode（防止假 NN 攻击）

### 3.2 为什么 TGT 设计这么绕？

> 核心动机：**减少客户端密码使用频率**

- 用户密码只在 kinit 时用一次（拿 TGT）
- 之后每次访问服务都用 TGT 换 ST，**不再碰密码**
- TGT 默认 10 小时，实现"一次登录，全天通行"= **SSO 单点登录**

### 3.3 为什么需要 Authenticator？

> 防重放攻击

- TGT/ST 本身可被网络窃听
- 但每次 AP_REQ 都附带**新鲜的 Authenticator**（带当前时间戳）
- 服务端缓存最近 5 分钟内的 Authenticator（replay cache）
- 时间戳过期 / 重复 → 拒绝

---

## 四、关键加密算法（生产配置必看）

### 4.1 enctype 加密算法演进

| 算法 | 强度 | 状态 | 备注 |
|------|------|------|------|
| `des-cbc-crc` | 56位 | ❌ 禁用 | 已破 |
| `des3-cbc-sha1` | 168位 | ⚠️ 不推荐 | NIST 已淘汰 |
| `arcfour-hmac` (RC4) | 128位 | ⚠️ 仅兼容 AD 旧版 | 有漏洞 |
| `aes128-cts-hmac-sha1-96` | 128位 | ✅ 可用 | 兼容性好 |
| **`aes256-cts-hmac-sha1-96`** | 256位 | ✅ **生产推荐** | 默认首选 |
| `aes256-cts-hmac-sha384-192` | 256位 | ✅ 新版 | RFC 8009，2018 后 |
| `camellia256-cts-cmac` | 256位 | ✅ 高性能 | 日本标准 |

### 4.2 配置位置（krb5.conf）

```ini
[libdefaults]
    default_realm = BIGDATA.COM
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
```

> ⚠️ **如果用 AES-256，必须装 JCE Unlimited Strength Policy**（Java 8 < 152，Java 9+ 默认开启）

### 4.3 JCE 限制踩坑

```bash
# 检查 JCE 是否解锁
jrunscript -e 'print(javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))'
# 输出 128 → 限制版（CRYPTO 弱）
# 输出 2147483647 → 解锁版（CRYPTO 强）

# 解锁方法（Java 8 < 152）：
# 下载 JCE Policy Files，替换 $JAVA_HOME/jre/lib/security/{local_policy.jar, US_export_policy.jar}

# Java 8 >= 152：
# 编辑 $JAVA_HOME/jre/lib/security/java.security
# 改为：crypto.policy=unlimited
```

不解锁 → 报 `KrbException: Illegal key size` ❌

---

## 五、Ticket 生命周期管理

### 5.1 时间维度

```
[起始时间(starttime)] ──┬──────────[到期时间(endtime)]──┬───────[最长可续(renew_till)]──→
                       │                              │
                       │ ← 默认 10h ───────────────► │ ← 默认 7 天 ────────────────►│
                       │                              │
                       │       票据正常使用            │   过期但可续，不可使用
```

| 时间字段 | 默认 | 配置项 | 说明 |
|---------|------|--------|------|
| 默认有效期 | 10h | `ticket_lifetime` | TGT 自然到期时间 |
| 最长续期窗口 | 7d | `renew_lifetime` | 在此窗口内可 `kinit -R` 续 |
| 时钟容差 | 5min | `clockskew` | 双方时钟最大偏差 |

### 5.2 票据状态查看

```bash
$ klist
Ticket cache: FILE:/tmp/krb5cc_1000
Default principal: alice@BIGDATA.COM

Valid starting       Expires              Service principal
05/09/2026 14:00:00  05/10/2026 00:00:00  krbtgt/BIGDATA.COM@BIGDATA.COM
        renew until 05/16/2026 14:00:00, Flags: FRIA
05/09/2026 14:05:33  05/10/2026 00:00:00  hdfs/nn01.bigdata.com@BIGDATA.COM
        renew until 05/16/2026 14:00:00, Flags: FAT
```

**Flags 解读**（FRIA 等于一组标志位）：

| 标志 | 含义 | 重要性 |
|------|------|--------|
| **F** | Forwardable | 可转发，YARN 任务必须 |
| **R** | Renewable | 可续期，长任务必须 |
| **I** | Initial | 初始票据（TGT） |
| **A** | Pre-authenticated | 已预认证 |
| **D** | Postdated | 延期生效 |
| **T** | Transited（多域时） | 跨域转发 |
| **H** | Hardware authenticated | 硬件认证 |
| **O** | Forwarded | 已被转发的副本 |

### 5.3 续期机制（长任务必懂）

```bash
# 手动续期一次
kinit -R

# 检查是否可续
klist -f | grep "renew until"

# Hadoop UGI 自动续期机制（核心源码）
# org.apache.hadoop.security.UserGroupInformation
#   - reloginFromKeytab()  → 当 TGT 剩余 < 80% 时自动重新 kinit
#   - reloginFromTicketCache() → 同上但走 ccache
#   - 后台线程：TicketCacheRenewalThread（每 1/10 周期检查一次）
```

**长任务（如 Spark Streaming / Flink）必须**：
- 提交时 `--keytab xxx.keytab --principal xxx`，让 ApplicationMaster 持续刷新
- 或者 Driver 启动 UGI 后台续期线程
- 否则跑到 7 天后 → 任务必死，报 `Ticket expired and not renewable`

---

## 六、Delegation Token：长任务的真正救星

### 6.1 为什么 Kerberos 票据不够用

| 问题 | Kerberos 票据 | Delegation Token |
|------|--------------|------------------|
| 续期上限 | 7 天 | 7 天，但可由 ResourceManager **代续无限次** |
| 数量 | 每个用户 1 个 TGT | 每个 Job 一组 token，独立 |
| 撤销 | 难（要 KDC 操作） | 容易（NN 端 cancelDelegationToken） |
| 子任务传递 | 不安全 | 设计用途就是传递 |
| 性能 | 每次 RPC 走 KDC | 不走 KDC，纯本地校验 |

### 6.2 Token 流程（Spark on YARN 为例）

```
[Spark Submit] kinit 拿 TGT
   ↓
[Spark Submit] 用 TGT 找 NameNode 拿 HDFS_DELEGATION_TOKEN
[Spark Submit] 用 TGT 找 ResourceManager 拿 RM_DELEGATION_TOKEN
[Spark Submit] 用 TGT 找 HMS 拿 HIVE_DELEGATION_TOKEN
   ↓
[把所有 token 打包到 ContainerLaunchContext]
   ↓
[YARN] 启动 ApplicationMaster（不需要 keytab，用 token 即可）
[YARN] 启动 Executor（同上）
   ↓
[AM] 后台线程定期 renewToken()
[AM] 7 天接近时 → 用 keytab 重新 kinit → 拿新 token → 重新分发（如果 --keytab 指定了）
```

### 6.3 Token 命令

```bash
# 查看 NameNode 上谁有 token
hdfs fsck / -openforwrite | grep dt

# 取消某个 token
hadoop dtutil cancel /path/to/token

# Spark 长任务推荐参数
spark-submit \
  --master yarn \
  --deploy-mode cluster \
  --keytab /etc/security/keytabs/spark.keytab \
  --principal spark/spark.bigdata.com@BIGDATA.COM \
  --conf spark.yarn.principal=spark/... \
  --conf spark.yarn.keytab=/etc/security/keytabs/spark.keytab \
  ...
```

---

## 七、Cross-Realm 跨域信任（高级）

### 7.1 场景

- 公司有 **AD（CORP.COM）** 管员工，**MIT KDC（HADOOP.COM）** 管 Hadoop
- 员工 alice@CORP.COM 想访问 HDFS（在 HADOOP.COM）
- 不想给每个员工再发一个 Hadoop principal

### 7.2 配置（双向信任示例）

#### KDC 端（两边都要做）

```bash
# CORP.COM 的 KDC 上：
kadmin.local -q "addprinc -pw SAMEPASSWORD krbtgt/HADOOP.COM@CORP.COM"
kadmin.local -q "addprinc -pw SAMEPASSWORD krbtgt/CORP.COM@HADOOP.COM"

# HADOOP.COM 的 KDC 上：执行相同命令（密码必须完全一致！）
```

> ⚠️ **两个 KDC 上 `krbtgt/HADOOP.COM@CORP.COM` 的密码必须完全一致**，否则跨域失败

#### 客户端 krb5.conf

```ini
[realms]
    CORP.COM = {
        kdc = ad01.corp.com
        admin_server = ad01.corp.com
    }
    HADOOP.COM = {
        kdc = kdc01.hadoop.com
        admin_server = kdc01.hadoop.com
    }

[domain_realm]
    .corp.com = CORP.COM
    .hadoop.com = HADOOP.COM

[capaths]
    CORP.COM = {
        HADOOP.COM = .   # 直接信任
    }
    HADOOP.COM = {
        CORP.COM = .
    }
```

#### Hadoop 端 auth_to_local 规则

```xml
<!-- core-site.xml -->
<property>
  <name>hadoop.security.auth_to_local</name>
  <value>
    RULE:[1:$1@$0](.*@CORP\.COM)s/@CORP\.COM//
    RULE:[1:$1@$0](.*@HADOOP\.COM)s/@HADOOP\.COM//
    DEFAULT
  </value>
</property>
```

把 `alice@CORP.COM` → 映射成本地 OS 用户 `alice`，HDFS ACL/Ranger 策略才能匹配上。

### 7.3 跨域排障

```bash
# 用 KRB5_TRACE 跟踪
KRB5_TRACE=/tmp/krb_trace.log kinit alice@CORP.COM
hdfs dfs -ls hdfs://nn.hadoop.com/

# 看 trace 中是否走了：
# [xxxx] sending TGS-REQ for krbtgt/HADOOP.COM@CORP.COM  ← 跨域 referral
# [xxxx] sending TGS-REQ for hdfs/nn.hadoop.com@HADOOP.COM
```

---

## 八、SPNEGO：Web UI 的 Kerberos

### 8.1 流程

```
浏览器 → GET /jmx
         ← 401 Unauthorized + WWW-Authenticate: Negotiate

浏览器 自动 kinit 拿 HTTP/host SPN 的 ST，包装成 SPNEGO Token

浏览器 → GET /jmx
         Authorization: Negotiate <base64-spnego-token>
         ← 200 OK
```

### 8.2 浏览器配置

| 浏览器 | 配置位置 |
|-------|---------|
| **Firefox** | `about:config` → `network.negotiate-auth.trusted-uris` = `.bigdata.com` |
| **Chrome** | 启动加 `--auth-server-whitelist="*.bigdata.com" --auth-negotiate-delegate-whitelist="*.bigdata.com"` |
| **Edge** | 同 Chrome |

### 8.3 服务端配置（HDFS NameNode 为例）

```xml
<!-- hdfs-site.xml -->
<property>
  <name>dfs.web.authentication.kerberos.principal</name>
  <value>HTTP/_HOST@BIGDATA.COM</value>
</property>
<property>
  <name>dfs.web.authentication.kerberos.keytab</name>
  <value>/etc/security/keytabs/spnego.service.keytab</value>
</property>
```

> `_HOST` 是占位符，启动时自动替换为 FQDN

---

## 九、krb5.conf 配置详解（生产模板）

```ini
# /etc/krb5.conf

[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log

[libdefaults]
    default_realm = BIGDATA.COM
    dns_lookup_realm = false
    dns_lookup_kdc = false                  # 生产建议 false，避免 DNS 故障扩散
    ticket_lifetime = 24h                   # TGT 有效期
    renew_lifetime = 7d                     # 最长续期窗口
    forwardable = true                      # 必须 true，否则 YARN 跨节点失败
    rdns = false                            # 生产必须 false，反解会引入故障
    udp_preference_limit = 1                # 强制走 TCP（UDP 在大票据时会失败）
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    # default_ccache_name = KEYRING:persistent:%{uid}  # RHEL7+ 默认，可改回 FILE:/tmp/krb5cc_%{uid}

[realms]
    BIGDATA.COM = {
        kdc = kdc01.bigdata.com:88
        kdc = kdc02.bigdata.com:88           # 多 KDC 主备
        admin_server = kdc01.bigdata.com:749
        default_domain = bigdata.com
    }

[domain_realm]
    .bigdata.com = BIGDATA.COM
    bigdata.com  = BIGDATA.COM
```

### 9.1 容易踩雷的配置项

| 配置 | 默认 | 推荐 | 雷点 |
|------|------|------|------|
| `rdns` | true | **false** | DNS 反解失败 → 认证失败 |
| `dns_lookup_kdc` | true | **false** | DNS 故障扩散到 Kerberos |
| `udp_preference_limit` | 1465 | **1** | 大票据 UDP 截断 → 重发风暴 |
| `forwardable` | false | **true** | YARN/Spark 跨节点必须 |
| `default_ccache_name` | KEYRING (RHEL7+) | **`FILE:/tmp/krb5cc_%{uid}`** | KEYRING 在容器中失效 |
| `clockskew` | 300s | 不改 | 改大不安全 |

---

## 十、自检清单

学完本章应该能回答：

- [ ] 为什么大数据集群必须开 Kerberos？SimpleAuth 漏洞演示一遍
- [ ] Principal 三段式分别是什么？user 型和 service 型有什么区别？
- [ ] 画出 Kerberos 六步认证全流程，并指出每一步可能的报错
- [ ] TGT 和 ST 的本质区别是什么？为什么要这样设计？
- [ ] Authenticator 解决了什么问题？时钟同步为什么是 5 分钟？
- [ ] Keytab 中的 KVNO 是什么？KVNO 不一致会怎样？
- [ ] Delegation Token 比 Kerberos 票据强在哪里？长任务为什么需要它？
- [ ] 跨域信任配置时，krbtgt 密码为什么必须一致？
- [ ] SPNEGO 与 Kerberos 是什么关系？
- [ ] krb5.conf 中 `rdns=true` 会带来什么生产事故？

> 答得上 8 个以上 → 进入 Phase-3 实践手册

---

*Eric · 大数据 SRE AI 专家团队 · 知识晶体化 v1.0*
