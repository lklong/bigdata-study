# Kerberos 根因树状速查图（一图流）

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> **从现象到根因到修复，一图全包**  
> 配套：[错误码字典](./08-Kerberos错误码全字典.md) + [5 分钟根因定位](./09-Kerberos5分钟根因定位手册.md)

---

## 总图：Kerberos 故障根因决策树

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Kerberos 故障                                   │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │  Q1: 是 Kerberos 错？   │
                    └────────────┬───────────┘
                       是│       │否
                         │       └──→ 应用 / 网络 / 授权问题（不在本图）
                         ▼
              ┌──────────────────────────┐
              │  Q2: 客户端能 kinit 吗？  │
              └──────────┬───────────────┘
                  否│    │是
                    │    └──────────────────────────────┐
                    ▼                                    ▼
          ┌──────────────────┐                  ┌────────────────────┐
          │  KINIT 阶段问题  │                  │  Q3: kvno SPN 通?  │
          └────────┬─────────┘                  └──────┬─────────────┘
                   │                              否│  │是
                   ▼                                │  ▼
       ┌──────────────────────┐                    │  ┌────────────────┐
       │ Q1.1: 报什么错？     │                    │  │ Q4: 业务可用?   │
       └─┬────┬────┬────┬───┬─┘                    │  └────┬───────────┘
         │    │    │    │   │                      │       │
         ▼    ▼    ▼    ▼   ▼                      ▼       ▼
       时间 网络 密钥 P身份 J/JCE              SPN问题   GSS/Token问题
```

---

## 子树 A: 时间问题（Clock skew 类）

```
报错: Clock skew too great / Ticket not yet valid / Defective token
                              │
                              ▼
                   ┌──────────────────────┐
                   │  date 与 KDC 偏差?  │
                   └─┬────────────────┬───┘
                  >5min               <5min
                     │                 │
                     ▼                 ▼
            ┌─────────────────┐    ┌──────────────────┐
            │ NTP 同步是否OK? │    │ 时区是否一致?    │
            └─┬────────────┬──┘    └─┬───────────┬────┘
             否│          是│       否│         是│
              │            │          │           │
              ▼            ▼          ▼           ▼
        启动 chronyd     防火墙挡   timedatectl  replay cache
        ntpdate -s       UDP 123    set-timezone 异常?
                         开放                     │
                                                  ▼
                                        rm -rf /var/tmp/krb5_*_rcache
```

**修复脚本**：
```bash
# 紧急
chronyc -a makestep || ntpdate -s ntp.aliyun.com

# 持续
systemctl enable --now chronyd
```

---

## 子树 B: 网络问题

```
报错: Cannot contact any KDC / UnknownHostException / Connection refused / Receive timed out
                              │
                              ▼
                   ┌──────────────────────┐
                   │  nc -zv kdc 88 通?  │
                   └─┬────────────────┬───┘
                   不通                通
                     │                 │
                     ▼                 ▼
        ┌────────────────────┐   ┌──────────────────┐
        │ nslookup kdc 解析? │   │ 看 KRB5_TRACE   │
        └─┬───────────────┬──┘   └─┬───────────────┬┘
         否│             是│       UDP超时         其他
          │              │           │
          ▼              ▼           ▼
       配 /etc/hosts  ┌──────────────┐
       或修 DNS       │ ping 通?     │
                      └─┬──────────┬─┘
                       否│        是│
                        │          │
                        ▼          ▼
                     路由问题  ┌──────────────────┐
                     mtr 看    │ ssh kdc systemctl│
                              │ status krb5kdc   │
                              └─┬─────────────┬──┘
                              不在            在
                               │             │
                               ▼             ▼
                            启动进程     防火墙
                                        iptables -L | grep 88
```

**修复路径**：
```bash
# 进程 → 端口 → 防火墙 → 网络 → DNS
ssh kdc01 "systemctl restart krb5kdc"
ssh kdc01 "ss -lntup | grep 88"
ssh kdc01 "iptables -nL | grep 88"
nc -zv kdc01 88
nslookup kdc01.bigdata.com
```

---

## 子树 C: 密钥问题（最复杂）

```
报错: Pre-authentication failed / Specified version of key / Decrypt integrity check failed
                              │
                              ▼
                   ┌──────────────────────┐
                   │  KVNO 一致?          │
                   └─┬────────────────┬───┘
                   不一致              一致
                     │                  │
                     ▼                  ▼
        ┌────────────────────┐   ┌──────────────────┐
        │ 解决: ktadd        │   │ enctype 一致?    │
        │ -norandkey         │   └─┬───────────────┬┘
        │ 重新导出 keytab   │    不一致           一致
        └────────────────────┘     │                │
                                   ▼                ▼
                          ┌──────────────────┐   ┌──────────────────┐
                          │ keytab 加 enctype │   │ 跨域?            │
                          │ ktadd -e aes256.. │   └─┬─────────────┬─┘
                          └──────────────────┘    是│            否│
                                                    │              │
                                                    ▼              ▼
                                          ┌──────────────────┐  ┌──────────┐
                                          │ krbtgt 密码一致? │  │ JCE 解锁?│
                                          └─┬─────────────┬──┘  └─┬──────┬─┘
                                          不一致         一致     未解锁  已解
                                            │            │         │      │
                                            ▼            ▼         ▼      ▼
                                       双方重置      capaths     解 JCE  其他
                                       同密码        配置                 看 trace
```

**修复决策一览表**：

| 现象 | 99% 根因 | 修复 |
|------|---------|------|
| KVNO 不一致 | KDC 改密码没分发 | `ktadd -norandkey` |
| enctype 缺 | keytab 老旧 | `ktadd -e aes256-cts...` |
| 跨域 Decrypt | krbtgt 密码 | 双方 `cpw -pw 'SAME'` |
| Illegal key size | JCE 限制 | `crypto.policy=unlimited` |

---

## 子树 D: Principal 不存在

```
报错: Server not found / Client not found in Kerberos database
                              │
                              ▼
                   ┌──────────────────────┐
                   │  哪种 Principal?     │
                   └─┬────────────────┬───┘
                  Server型           Client型
                  (svc/host)         (user)
                     │                 │
                     ▼                 ▼
        ┌────────────────────┐   ┌──────────────────┐
        │ kadmin.local -q    │   │ kadmin.local -q  │
        │ 'getprinc svc/host'│   │ 'listprincs'\    │
        └─┬────────────────┬─┘   │  | grep user     │
       存在                不存   └─┬───────────┬────┘
         │                   │   存在            不存
         ▼                   ▼     │              │
   FQDN 大小写匹配?       创建 SPN  ▼              ▼
   hostname -f vs SPN     kadmin   Realm        addprinc
                                   写错？       创建用户
```

**FQDN 三向校验**：
```bash
# 必须三方一致
A=$(hostname -f)                                  # 客户端
B=$(getent hosts $(hostname -i) | awk '{print $2}')  # DNS 反解
C=$(kadmin.local -q "listprincs '*$(hostname -f)*'") # KDC SPN

# 都指向同一个 FQDN 才行
```

---

## 子树 E: Login / Token 问题

```
报错: No valid credentials / Failed to find any tgt / Login failure / token expired
                              │
                              ▼
                   ┌──────────────────────┐
                   │  klist 有票吗?       │
                   └─┬────────────────┬───┘
                   没票               有票
                     │                 │
                     ▼                 ▼
        ┌────────────────────┐   ┌──────────────────┐
        │ KRB5CCNAME 设了?   │   │ 票过期?          │
        └─┬────────────────┬─┘   └─┬─────────────┬──┘
        没设              已设   过期             未过期
          │                │      │                │
          ▼                ▼      ▼                ▼
    kinit -kt        路径与     长任务?         JAAS 加载?
    keytab princ     进程一致?    │              │
                       │         ▼              ▼
                       ▼      没 --keytab    -Djava.security
                    SU 切换    kinit + 7天    .auth.login.config
                    后丢了?
```

---

## 子树 F: 配置问题

```
报错: Cannot authenticate via KERBEROS / SIMPLE auth not enabled / Cannot impersonate
                              │
                              ▼
                   ┌──────────────────────┐
                   │  哪一端的问题?       │
                   └─┬────────────────┬───┘
                  客户端              服务端
                     │                 │
                     ▼                 ▼
        ┌────────────────────┐   ┌──────────────────┐
        │ core-site.xml中    │   │ 服务端启用了     │
        │ hadoop.security    │   │ Kerberos 吗？    │
        │ .authentication?  │   └─┬─────────────┬──┘
        └─┬────────────────┬─┘   是             否
       simple             kerberos │              │
         │                  │      ▼              ▼
         ▼                  ▼   ProxyUser?      启用 Kerberos
       改成 kerberos    然后 kinit  │
                                   ▼
                                 hadoop.proxyuser
                                 .X.hosts/groups
```

---

## 子树 G: SPNEGO / Web UI

```
报错: HTTP 401 + WWW-Authenticate: Negotiate
                              │
                              ▼
                   ┌──────────────────────┐
                   │  curl --negotiate?   │
                   └─┬────────────────┬───┘
                  200                401
                  ↑                   │
                  │                   ▼
                  │        ┌──────────────────┐
                  │        │ 客户端 klist 有票│
                  │        └─┬─────────────┬──┘
                  │         没             有
                  │          │              │
                  │          ▼              ▼
                  │       kinit          ┌──────────────────┐
                  │                       │ 服务端 HTTP/_HOST│
                  │                       │ SPN 存在？       │
                  │                       └─┬─────────────┬──┘
                  │                       不存在          存在
                  │                         │              │
                  │                         ▼              ▼
                  │                    addprinc HTTP/  spnego.keytab
                  │                    + ktadd          路径正确?
                  │                                       │
                  │                                       ▼
                  │                                   重启服务
                  │
        浏览器配置问题
        Firefox: trusted-uris
        Chrome: --auth-server-whitelist
```

---

## 子树 H: 跨域 Cross-Realm

```
跨域用户访问失败
                              │
                              ▼
                   ┌──────────────────────┐
                   │  klist 拿到 TGT?     │
                   └─┬────────────────┬───┘
                  没                  有
                     │                 │
                     ▼                 ▼
        ┌────────────────────┐   ┌──────────────────┐
        │ 自家 KDC 通?       │   │ KRB5_TRACE 看    │
        └────────────────────┘   │ 跨域 referral    │
                                  └─┬─────────────┬──┘
                                  失败            成功
                                    │              │
                                    ▼              ▼
                          ┌──────────────────┐   认证 OK 但权限错？
                          │ capaths 配了？   │       │
                          └─┬─────────────┬──┘       ▼
                          没             有     auth_to_local
                           │              │     映射规则
                           ▼              ▼
                       加 capaths    krbtgt/B@A
                                     密码两边一致?
                                       │
                                       ▼
                                  双方 cpw -pw
                                  'SAME'
```

---

## 速查表 1: 报错关键字 → 子树

| 关键字 | 子树 | 章节 |
|-------|-----|------|
| `Clock skew` | A 时间 | §A |
| `Cannot contact KDC` | B 网络 | §B |
| `KVNO`、`Specified version of key` | C 密钥 | §C |
| `Decrypt integrity check failed` | C 密钥 | §C |
| `Server not found` | D Principal | §D |
| `Client not found` | D Principal | §D |
| `No valid credentials` | E Login | §E |
| `token expired` | E Login | §E |
| `Cannot authenticate via` | F 配置 | §F |
| `WWW-Authenticate Negotiate` | G SPNEGO | §G |
| 跨域用户失败 | H Cross-Realm | §H |

---

## 速查表 2: 一线命令清单（按优先级）

```bash
# Level 1 — 最快（10 秒）
klist                  # 当前票据
echo $KRB5CCNAME        # ccache 路径
date                    # 时钟

# Level 2 — 快速（30 秒）
nc -zv kdc01 88         # KDC 连通
kinit -kt $KEYTAB $PRINC # 测试 kinit
kvno $PRINC             # 测试 SPN

# Level 3 — 标准（2 分钟）
KRB5_TRACE=/dev/stderr kinit -V -kt ...  # 全程 trace
klist -kt $KEYTAB                         # keytab 内容
hostname -f                               # FQDN

# Level 4 — 深度（5 分钟）
bash kerb-doctor.sh -p $P -k $K           # 全面体检
bash kerb-log-grep.sh                      # 日志聚合
bash kerb-fqdn-check.sh hosts.txt          # FQDN 一致性
```

---

## 速查表 3: 修复命令大全

```bash
# 时间
chronyc -a makestep
ntpdate -s ntp.aliyun.com

# 网络
ssh kdc01 "systemctl restart krb5kdc"
ssh kdc01 "iptables -F"

# KVNO
kadmin.local -q "ktadd -norandkey -k /tmp/x.keytab principal"

# Principal
kadmin.local -q "addprinc -randkey hdfs/$(hostname -f)"
kadmin.local -q "ktadd -k /etc/security/keytabs/x.keytab hdfs/$(hostname -f)"

# Login
kinit -kt /path principal
export KRB5CCNAME=FILE:/tmp/krb5cc_$(id -u)

# JCE
sed -i 's/^#crypto.policy=unlimited/crypto.policy=unlimited/' \
    $JAVA_HOME/jre/lib/security/java.security

# 长任务
spark-submit --keytab /path --principal X@REALM ...

# 跨域
kadmin.local -q "cpw -pw 'SAME' krbtgt/B@A"

# Web UI
kadmin.local -q "addprinc -randkey HTTP/$(hostname -f)"
```

---

## 速查表 4: 快速判别技巧

### 4.1 是不是 Kerberos 问题？

```bash
echo "$ERROR" | grep -ciE "krb|gss|sasl|kdc|tgt|principal|keytab|kinit|-176532"
# > 0 → 是
# = 0 → 不是
```

### 4.2 是认证还是授权？

```
✅ Kerberos = 认证（你是谁）
   报错关键字：GSSException, KrbException, kinit, keytab, principal

✅ Ranger / ACL = 授权（你能干啥）
   报错关键字：Permission denied, AccessControlException (不带 GSS)
              Access denied for user, Authorization fail
```

### 4.3 客户端 vs 服务端？

```
报错出现在 客户端 stderr/stdout → 客户端
   解决：kinit / krb5.conf / JAAS

报错出现在 服务端 *.log → 服务端
   解决：keytab / 服务端配置 / KDC
```

---

## 黄金法则（贴墙）

```
1. 看到 Kerberos 报错先看时钟（80% 是时钟）
2. KVNO 不一致是生产 Top1 故障（必查）
3. _HOST 替换前必须 hostname -f 正常（FQDN）
4. 长任务必须 --keytab（7 天后必死）
5. krb5.conf 永远 rdns=false（避免 DNS 故障扩散）
6. 容器中 ccache 永远用 FILE 类型
7. 跨域必查 capaths + krbtgt 密码一致
8. 报错先看 caused by 链找到根因
9. 开 KRB5_TRACE 是终极武器
10. 没解决前永远不要乱改 KDC 配置
```

---

## 一图流总览（终极版）

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│              【KERBEROS 故障速查 ONE-PAGER】                              │
│                                                                          │
│  ┌─Step 1: 是 Kerberos 吗？───────────────────────────────────────────┐  │
│  │ grep -iE "krb|gss|sasl|-176532"                                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─Step 2: 分类（看关键字）─────────────────────────────────────────┐  │
│  │ Clock skew      → A 时间                                          │  │
│  │ Cannot contact  → B 网络                                          │  │
│  │ KVNO/Pre-auth   → C 密钥                                          │  │
│  │ Not found       → D Principal                                     │  │
│  │ No credentials  → E Login                                         │  │
│  │ Cannot auth via → F 配置                                          │  │
│  │ 401 Negotiate   → G SPNEGO                                        │  │
│  │ 跨域            → H Cross-Realm                                   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─Step 3: 一键体检────────────────────────────────────────────────┐  │
│  │ bash kerb-doctor.sh -p $PRINCIPAL -k $KEYTAB                      │  │
│  │ bash kerb-trace.sh -c "<复现命令>"                                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─Step 4: 走对应子树定位根因─────────────────────────────────────┐  │
│  │ 时间 → date + ntpdate                                            │  │
│  │ 网络 → nc -zv 88                                                  │  │
│  │ 密钥 → klist -kt vs kvno                                          │  │
│  │ Principal → hostname -f + kadmin listprincs                      │  │
│  │ Login → klist + KRB5CCNAME                                       │  │
│  │ 配置 → grep authentication core-site.xml                          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─Step 5: 修复 + 验证 + 留痕──────────────────────────────────────┐  │
│  │ 1. 执行修复命令                                                    │  │
│  │ 2. 重新跑命令验证                                                  │  │
│  │ 3. 留痕（命令+trace+日志）                                         │  │
│  │ 4. 沉淀进案例库                                                    │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

*Eric · 大数据 SRE AI 专家团队 · 一图流速查 v1.0*
