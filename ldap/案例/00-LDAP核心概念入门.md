# LDAP 核心概念入门（零基础版）

> 作者：Eric（豹纹）| 适合：完全没接触过 LDAP 的同学  
> 看完本篇 ≈ 理解 LDAP 90% 的术语，再读后面 01~04 不再费解  
> 建议阅读时长：30 分钟（不要跳，每节都有比喻和配图）

---

## 一、LDAP 是什么？用一句话讲清楚

> **LDAP = 一个专门用来"查人 / 查组织架构"的数据库 + 一套查询协议**

类比：

| 你熟悉的东西 | LDAP 对应物 |
|------------|------------|
| MySQL | **OpenLDAP**（实现） |
| SQL | **LDAP 协议**（查询语言） |
| 表 / 行 / 列 | **条目（entry）/ 属性（attribute）** |
| 主键 | **DN（Distinguished Name，唯一标识）** |
| 表结构 | **objectClass + Schema** |
| `SELECT * FROM users WHERE name='alice'` | `ldapsearch -b "ou=People,..." "(uid=alice)"` |

**为什么不用 MySQL 而要专门搞个 LDAP？**

1. **读多写极少**：员工信息一年改几次，但每秒被查上千次（每次登录都要查）
2. **天然层级结构**：公司→部门→人，用关系表硬凑很别扭，用树表达天然
3. **跨厂商标准**：1993 年起就是 IETF 标准（RFC 1487 / 4510），所有大公司软件都认它
4. **轻量**：lightweight 就在名字里 —— 比它前辈 X.500 砍掉一半复杂性

---

## 二、最核心的图：DIT（目录信息树）

LDAP 的所有数据存在一棵**树**里，叫 **DIT**（Directory Information Tree）。

```
                    dc=bigdata,dc=local                    ← 根（Suffix）
                    ┌────────┴────────┐
                    │                 │
              ou=People          ou=Groups                 ← 第二层（OU 组织单元）
              ┌────┴─────┐       ┌────┴────┐
              │          │       │         │
        uid=alice   uid=bob   cn=hadoop  cn=data-eng       ← 第三层（叶子条目）
              ▲
              │
              └─ 这是一个【条目 entry】，包含很多属性：
                   uid:          alice
                   cn:           Alice Wang
                   mail:         alice@bigdata.local
                   userPassword: {SSHA}xxxx
                   uidNumber:    10001
                   ...
```

**记住三个层级**：
- **根（Root / Suffix）**：整棵树的命名空间，约定用域名反向（`bigdata.local` → `dc=bigdata,dc=local`）
- **OU（Organizational Unit）**：相当于"文件夹"，用来分类
- **条目（Entry）**：树叶，存一个具体对象（一个人、一个组、一台机器）

---

## 三、DN：LDAP 的"主键 / 文件路径"

每个条目都有一个**全世界唯一**的 ID，叫 **DN**（Distinguished Name）。

它的写法是**从下往上**用逗号串起来：

```
uid=alice, ou=People, dc=bigdata, dc=local
  └RDN┘   └─────── 父节点的 DN ───────┘
```

类比：
- DN ≈ Linux **文件的绝对路径** `/local/bigdata/People/alice`，只是顺序倒过来
- **RDN**（Relative DN）= "在父节点下的名字"，比如 `uid=alice` 就是 alice 这条记录的 RDN

**生产规则**：
- DN 一旦定下来不要改（改 = 重建条目，所有引用都得改）
- 建 People 用 `uid=...` 当 RDN（不要用 `cn=...`，因为人重名很常见，uid 在公司内唯一）
- 建 Groups 用 `cn=...` 当 RDN

---

## 四、属性（Attribute）：条目里的"列"

一个 LDAP 条目就是**一堆 `属性: 值` 的集合**：

```ldif
dn: uid=alice,ou=People,dc=bigdata,dc=local      ← 这条记录的 DN
objectClass: inetOrgPerson                       ← 「我属于什么类型」
objectClass: posixAccount                        ← 多个 objectClass 可叠加！
uid: alice
cn: Alice Wang
sn: Wang                                          ← surname 姓
givenName: Alice                                  ← 名
mail: alice@bigdata.local
mail: alice.wang@bigdata.local                   ← ★ 同一属性可以有多个值！
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/alice
loginShell: /bin/bash
userPassword: {SSHA}5xR9... (哈希)
```

**和 MySQL 的本质区别**（这点不理解后面就懵）：

| 特性 | MySQL | LDAP |
|------|-------|------|
| 一列只能一个值 | 是 | **否！** mail 可以有 N 个值 |
| 必须先 ALTER 才能加列 | 是 | **否！** 加 objectClass 自动获得对应属性 |
| Schema 强约束 | 是 | 是（但更灵活） |
| 跨表 join | 用 SQL JOIN | LDAP 不擅长，要么内嵌要么应用层处理 |

---

## 五、objectClass：决定"我能有哪些属性"

`objectClass` 是个超关键的概念。它就像 OOP 里的"类"，决定**这个条目能有/必须有/不能有**哪些属性。

```ldif
objectClass: inetOrgPerson      ← 来自 RFC 2798，定义了 cn, sn, mail, telephoneNumber...
objectClass: posixAccount       ← 来自 RFC 2307，定义了 uid, uidNumber, gidNumber, homeDirectory...
objectClass: shadowAccount      ← 同上，定义了 shadowLastChange, shadowMax...
```

每个 objectClass 在 Schema 里规定：
- **MUST**：必填属性（不写就报错 65 objectClassViolation）
- **MAY**：可选属性

举例：`posixAccount` 的 MUST = `cn, uid, uidNumber, gidNumber, homeDirectory`，少一个都不行。

**为什么要叠加多个 objectClass？**
- `inetOrgPerson` 给你"人"的属性（姓、名、邮箱、电话）
- `posixAccount` 给你"Linux 账号"属性（uid 数字、home 目录、shell）
- `shadowAccount` 给你"密码策略"属性（过期时间）
- 一个 LDAP 条目同时是这三种 → 同时叠加 → 大数据生态的标配组合

**类比**：
```python
# 像多重继承
class AliceEntry(InetOrgPerson, PosixAccount, ShadowAccount):
    uid = "alice"
    ...
```

---

## 六、Schema：所有"列定义"的总目录

Schema 文件里规定了：
- 有哪些 **AttributeType**（属性类型，如 `mail`、`uidNumber`）—— 名字、数据类型、是否大小写敏感、是否多值
- 有哪些 **ObjectClass**（如 `posixAccount`）—— 包含哪些 MUST/MAY

OpenLDAP 默认带的 Schema：
```
/etc/openldap/schema/
├── core.ldif              ← 核心（top, person, organizationalUnit）
├── cosine.ldif            ← 1996 年互联网通讯人员 schema
├── inetorgperson.ldif     ← 互联网组织人员（最常用）
├── nis.ldif               ← UNIX 网络服务（posixAccount/Group 在这里）
└── ppolicy.ldif           ← 密码策略
```

**记住**：搭 LDAP 的第一步就是 `ldapadd 这些 .ldif`，否则你想加 `posixAccount` 就找不到这个 class。

**Eric 经验**：90% 的"添加用户报 65 错误"都是因为忘了导入 nis schema，或者 objectClass 拼错。

---

## 七、LDIF：LDAP 数据的"YAML / SQL 脚本"

LDIF (LDAP Data Interchange Format) 就是 LDAP 的**文本表达格式**，所有的导入导出、配置脚本都用它。

```ldif
# 这是一条加用户的 LDIF
dn: uid=charlie,ou=People,dc=bigdata,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: charlie
cn: Charlie Liu
sn: Liu
uidNumber: 10003
gidNumber: 10003
homeDirectory: /home/charlie
userPassword: {SSHA}xxx

# 空行分隔下一条
dn: uid=david,...
...
```

**改条目用 `changetype`**：

```ldif
# 改邮箱
dn: uid=alice,ou=People,dc=bigdata,dc=local
changetype: modify
replace: mail
mail: alice.new@bigdata.local

# 加一个邮箱（不删原来的）
dn: uid=alice,ou=People,dc=bigdata,dc=local
changetype: modify
add: mail
mail: alice.work@bigdata.local

# 删除
dn: uid=alice,ou=People,dc=bigdata,dc=local
changetype: delete
```

**和 SQL 对照**：

| SQL | LDIF |
|-----|------|
| `INSERT INTO users ...` | `dn: ...` + 属性，无 changetype（默认 add） |
| `UPDATE users SET mail=...` | `changetype: modify` + `replace: mail` |
| `DELETE FROM users WHERE uid=...` | `changetype: delete` |

---

## 八、bind：LDAP 的"登录"

LDAP 协议里没有 SQL 的 "USE database" 概念，但有 **bind**（绑定身份）：

```
客户端                    LDAP服务端
   │  bind(DN=alice, pw=Alice@123)  │
   │ ─────────────────────────────► │
   │                                 │ ← 校验密码
   │  ◄───── success/fail ─────      │
   │  search(base=..., filter=...)   │
   │ ─────────────────────────────► │
```

三种 bind 模式：

| 模式 | 描述 | 使用场景 |
|------|------|---------|
| **anonymous bind** | 不传账号密码 | 公开数据，**生产严禁** |
| **simple bind** | 传 DN + 明文密码（应走 TLS） | 最常用 |
| **SASL bind** | GSSAPI/Kerberos/External 等机制 | 高级 SSO 场景 |

**关键点**：
- bind 的本质是**校验密码** → 这就是为什么大数据组件能"用 LDAP 认证"：服务端拿用户密码去 LDAP bind，bind 成功 = 密码对
- 同一连接可以多次 bind（切换身份）

---

## 九、search：LDAP 怎么查数据？

搜索三要素：**baseDN + scope + filter**

```bash
ldapsearch \
  -b "ou=People,dc=bigdata,dc=local"   \   # baseDN：从哪个节点开始搜
  -s sub                                \   # scope：base/one/sub（自身/子节点/全子树）
  "(uid=alice)"                             # filter：过滤条件
  uid cn mail                                # 只返回这几个属性
```

### 9.1 三种 scope 必须分清

```
   baseDN: ou=People,...
            │
   ┌────────┼────────┐
  alice   bob    sub-ou
                  │
                charlie

scope=base : 只匹配 baseDN 自己（People 这个 OU）
scope=one  : 只匹配 baseDN 的【直接子节点】（alice, bob, sub-ou）
scope=sub  : 匹配 baseDN 及其【所有后代】（包括 charlie）  ← 最常用
```

### 9.2 filter 语法（LDAP 自己的小 DSL）

```
(uid=alice)                     ← 等于
(uid=ali*)                      ← 通配
(!(uid=alice))                  ← 非
(&(objectClass=posixAccount)(uid=al*))   ← 与
(|(uid=alice)(uid=bob))         ← 或
(mail=*)                        ← 该属性存在
(uidNumber>=10000)              ← 范围
```

**注意**：是**前缀**操作符（波兰式表达），不是中缀。这是 LDAP 新手最容易懵的点。

```
SQL: WHERE objectClass='posixAccount' AND uid LIKE 'al%'
LDAP filter: (&(objectClass=posixAccount)(uid=al*))
```

### 9.3 用大白话翻译几条常见 filter

| filter | 含义 |
|--------|------|
| `(uid=alice)` | 找用户名是 alice 的人 |
| `(&(objectClass=posixAccount)(uid=alice))` | 找用户名是 alice **且**是 Linux 账号的 |
| `(\|(uid=alice)(uid=bob))` | 找 alice **或** bob |
| `(memberUid=alice)` | 找成员里包含 alice 的组（注意基础是 ou=Groups） |
| `(&(objectClass=posixGroup)(cn=hadoop-*))` | 找所有以 hadoop- 开头的组 |

---

## 十、用户和组：大数据生态的关键设计

大数据组件（Hadoop、Hive、Ranger）需要回答两个问题：
1. **alice 是谁？密码对吗？** → 用 People 子树 + bind
2. **alice 在哪些组？** → 用 Groups 子树查

LDAP 表达"组成员关系"有**两套主流做法**，新手必踩坑：

### 10.1 posixGroup（大数据生态首选）

```ldif
dn: cn=data-engineer,ou=Groups,dc=bigdata,dc=local
objectClass: posixGroup
cn: data-engineer
gidNumber: 20001
memberUid: alice           ← 注意：值是【字符串 uid】
memberUid: bob
memberUid: charlie
```

特点：
- 成员是**简单字符串**（uid 名）
- 用户被删了，组里还留着字符串"alice"，要手工清
- 与 Linux `/etc/group` 概念一致 → SSSD/PAM/Hadoop 兼容性最好

### 10.2 groupOfNames（AD 风格）

```ldif
dn: cn=data-engineer,ou=Groups,dc=bigdata,dc=local
objectClass: groupOfNames
cn: data-engineer
member: uid=alice,ou=People,dc=bigdata,dc=local       ← 注意：值是【完整 DN】
member: uid=bob,ou=People,dc=bigdata,dc=local
```

特点：
- 成员是**完整 DN**
- 用户改名/搬家时，所有引用要联动改（OpenLDAP 有 memberOf overlay 自动维护）
- AD（Active Directory）默认这种

### 10.3 这两种为什么要讲清楚？

**Hive/Trino/Ranger 配置 LDAP 时，三个参数必须匹配**：

| 配 LDAP 实际类型 | groupClassKey | groupMembershipKey |
|----------------|--------------|-------------------|
| posixGroup | `posixGroup` | `memberUid` |
| groupOfNames | `groupOfNames` | `member` |
| AD group | `group` | `member` |

**配错就是"用户能登录但查不到组" → 04-§1.2 这一类问题的根源。**

---

## 十一、LDAPS / StartTLS：加密通信

LDAP 默认协议明文（端口 389），bind 时**密码裸奔**。生产必须加密：

| 方式 | 端口 | 工作原理 |
|------|------|---------|
| **LDAPS** | 636 | TCP 一连上来就 TLS 握手（像 HTTPS） |
| **StartTLS** | 389 | 先明文连接，发一条特殊命令把连接升级为 TLS |
| 明文 LDAP | 389 | 不加密，**生产严禁** |

**记住**：URL 里看到 `ldaps://` 就是 636，看到 `ldap://` 就是明文 389（除非客户端主动 StartTLS）。

---

## 十二、ACL：谁能看 / 改什么

LDAP 的权限控制叫 **ACL**（Access Control List），核心句法：

```ldif
olcAccess: to <什么资源> by <谁> <能干什么>
```

举三个最重要的：

```ldif
# 1. 密码字段：本人改、匿名 auth、其他禁
olcAccess: {0}to attrs=userPassword
  by self write              ← 本人能改（修改自己的密码）
  by anonymous auth          ← 匿名能用它来 auth（这是 bind 校验的实现）
  by * none                  ← 其他人完全看不到（包括读）

# 2. 整棵树：登录用户能读，admin 能写
olcAccess: {1}to *
  by dn="cn=admin,..." write
  by users read              ← 任何已 bind 用户能读
  by * none
```

**注意点**：
- ACL 按 `{0}` `{1}` `{2}` 顺序匹配，**先匹配的生效，后面跳过**
- `users` = 任何已 bind 的（不是匿名）
- `self` = bind 时用的 DN 等于条目自己的 DN
- 用 `slapacl` 命令可以模拟测试：`slapacl -D <谁> -b <什么资源> 属性/权限`

---

## 十三、复制（Replication）：高可用的基础

单机 LDAP = 单点，挂了集群全瘫。所以生产至少 2 台，用 **syncrepl** 协议同步。

两种模式：

```
【主从（Master-Slave）】
   ┌───────┐    syncrepl     ┌───────┐
   │主(写) │ ───────────────►│ 从(只读)│
   └───────┘                  └───────┘
   简单清晰，但写入只能上主，主挂了得手工提升从

【主主（MMR, Multi-Master）】
   ┌───────┐ ◄─ syncrepl ─►  ┌───────┐
   │主1(写)│                  │主2(写)│
   └───────┘                  └───────┘
   都能写，任一挂了无感切换。但双写可能冲突，要靠 entryCSN 时间戳裁决
```

**通俗解释 entryCSN**：每条记录都有个修改时间戳（精确到微秒+ServerID）。冲突时**时间戳大的赢**。所以 MMR 节点之间的**时钟必须严格 NTP 同步**（差 100ms 以上就出问题）。

---

## 十四、把概念串起来：一次完整的"alice 登录 Hive"

把前面 13 章串起来，看 Hive 用 LDAP 认证的完整流程：

```
1. alice 在 beeline 输入 jdbc:hive2://hs2:10000  -n alice -p Alice@123
       │
       ▼
2. HS2 收到（用户名=alice, 密码=Alice@123）
       │
       ▼
3. HS2 用配置的 userDNPattern 拼出 DN：
       uid=alice,ou=People,dc=bigdata,dc=local
       │
       ▼
4. HS2 向 LDAP 发 simple bind(DN, "Alice@123")
       │
       ▼ TLS 加密
5. LDAP 服务端：
       a. 找到这个 DN 的条目
       b. 用 SSHA 算法对 "Alice@123" 加盐哈希
       c. 与条目里 userPassword 的哈希对比
       d. 一致 → bind 成功
       │
       ▼
6. HS2 接着用 readonly 服务账号 search:
       base = ou=Groups,...
       filter = (&(objectClass=posixGroup)(memberUid=alice))
       → 拿到 alice 所在的组列表
       │
       ▼
7. HS2 检查：alice 是否在 groupFilter 白名单组里？
       是 → 放行，建立 Hive Session
       否 → 报 "Error validating LDAP user"
       │
       ▼
8. doAs alice 后续 SQL → HDFS 鉴权 → Ranger 鉴权（也都靠 LDAP 查的组）
```

**这一张流程图理解了，前面所有章节的参数为什么这么配，全通了。**

---

## 十五、术语速记卡

| 术语 | 一句话解释 |
|------|----------|
| **DIT** | LDAP 整棵数据树 |
| **DN** | 一条记录的全路径主键 |
| **RDN** | DN 最左边那一段（"在父节点下叫什么"） |
| **dc** | domain component，域名片段（dc=bigdata） |
| **ou** | organizational unit，组织单元（≈文件夹） |
| **cn** | common name，常用名（≈"显示名"） |
| **uid** | user id，用户名（字符串，不是数字） |
| **uidNumber** | 数字 UID（Linux 用） |
| **objectClass** | 决定条目能有哪些属性的"类" |
| **Schema** | 所有属性和 objectClass 的定义集合 |
| **LDIF** | LDAP 数据的文本格式 |
| **bind** | 客户端用 DN+密码登录 |
| **search** | 查询数据，三要素 base+scope+filter |
| **filter** | 前缀式表达式 `(&(...)(...))` |
| **scope** | base/one/sub，决定搜索深度 |
| **slapd** | OpenLDAP 服务端进程名（s-LDAP-d） |
| **cn=config** | OpenLDAP 2.4+ 的"配置即数据"目录 |
| **mdb** | OpenLDAP 的默认存储后端（基于 LMDB） |
| **syncrepl** | LDAP 复制协议 |
| **entryCSN** | 条目修改时间戳，复制冲突裁决用 |
| **MMR** | 多主复制 |
| **ACL** | 访问控制列表 |
| **ppolicy** | password policy，密码策略 overlay |
| **referral** | 把查询转交给别的 LDAP 服务器 |
| **SSSD** | Linux 上接 LDAP 的标准守护进程 |

---

## 十六、读完本篇后该怎么走？

```
你现在在这里 ─────► 00 入门（本篇）✓
                      │
                      ▼
        想动手搭一个？──► 01-LDAP搭建手册
                      │
                      ▼
        要接大数据？───► 02-LDAP与大数据组件集成
                      │
                      ▼
        日常运维？─────► 03-LDAP日常运维手册
                      │
                      ▼
        遇到故障？─────► 04-LDAP常见问题排障
```

---

## 十七、给零基础同学的 5 条暖心建议

1. **先在虚拟机搭一个玩具 LDAP**，看着 ldif 一条一条 add，比看 100 篇文档管用
2. **学 ldapsearch 用熟练**，一切排障都从 `ldapsearch -x -D ... -W -b ...` 开始
3. **永远先想清楚 DIT 设计再动手**：搞错了 RDN/OU 划分，后面填用户填几万条再改就崩溃
4. **把 LDAP 当只读数据库用**：90% 时间在查、5% 在加用户、4% 在改密码、1% 在删
5. **配置参数不理解就回到这一篇查 §15 速记卡**，你会发现所有看不懂的字段都已经讲过

---

> 📌 下一篇：[01-LDAP搭建手册](./01-LDAP搭建手册.md) —— 卷起袖子，跑起来。
