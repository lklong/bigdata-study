# Kerberos 票据交换源码深度解析（Hadoop UGI + SaslRpcServer 全链路）

> 版本: Hadoop 3.x
> 源码路径: `/Users/kailongliu/bigdata/txProjects/hadoop`
> 作者: Eric (豹纹)
> 输出时间: 2026-05-20

---

## 一、问题/场景

Kerberos 是大数据安全的基石，Hadoop / Hive / HBase / Kafka / Spark 跨集群认证全靠它。但生产中是"调试地狱级"难题：
- Kerberos 三方认证（Client / KDC / Service）在 Hadoop 中怎么映射到 UGI 抽象？
- `loginUserFromKeytab` / `reloginFromKeytab` / `checkTGTAndReloginFromKeytab` 这三个方法的区别？什么时候调哪个？
- TGT 票据过期了为什么任务突然挂掉？怎么自动续期？
- `doAs` 是怎么实现"以指定身份执行操作"的？
- SaslRpcServer 是怎么把 SPNEGO/GSSAPI 协议接入 Hadoop RPC 的？

理解这条链是排查"GSS Exception / Server not found in Kerberos database / Cannot get tgt / Token Expired"等所有 Kerberos 故障的前置。

## 二、Kerberos 在 Hadoop 中的角色映射

### Kerberos 协议三方
```
[Client] ─── (1) AS_REQ: 我是 alice@HADOOP.COM，请给我 TGT ──→ [KDC.AS]
[Client] ←── (2) AS_REP: 给你 TGT（用 alice 的密码加密）─────── [KDC.AS]

[Client] ─── (3) TGS_REQ: 用 TGT 换 hdfs/nn1@HADOOP.COM 的服务票 ──→ [KDC.TGS]
[Client] ←── (4) TGS_REP: 给你 ServiceTicket ────────────────── [KDC.TGS]

[Client] ─── (5) AP_REQ: 拿 ServiceTicket 访问 NameNode ────────→ [Service NN]
[Client] ←── (6) AP_REP: 认证成功（可选互认）────────────────── [Service NN]
```

### Hadoop 中的对应实现
| Kerberos 概念 | Hadoop 实现 |
|--------------|-------------|
| TGT 获取（步骤 1-2） | `UserGroupInformation.loginUserFromKeytab` 内调用 JAAS Krb5LoginModule |
| TGT 持有（票据缓存） | `Subject.getPrivateCredentials()` 内的 `KerberosTicket` |
| TGT 续期 | `checkTGTAndReloginFromKeytab` / `reloginFromKeytab` |
| Service Ticket 获取（步骤 3-4） | JDK GSS-API 内部自动完成（client 调 RPC 时）|
| AP_REQ/REP（步骤 5-6） | `SaslRpcServer` + `SaslRpcClient` 走 SASL-GSSAPI 机制 |
| 用户身份 | `UserGroupInformation` 包装 JAAS `Subject` |
| 委托执行 | `UserGroupInformation.doAs(action)` ← 经典 PrivilegedAction 模式 |

## 三、关键源码逐段精读

### 3.1 loginUserFromKeytab —— Hadoop Kerberos 登录入口

`UserGroupInformation.java:1042-1071`：

```java
static void loginUserFromKeytab(String user, String path) throws IOException {
    if (!isSecurityEnabled()) return;          // ★ Simple 认证模式直接返回

    keytabFile = path;
    keytabPrincipal = user;
    Subject subject = new Subject();
    LoginContext login;
    long start = 0;
    try {
        // ① 创建 JAAS LoginContext（用 KEYTAB_KERBEROS_CONFIG_NAME 配置）
        login = newLoginContext(HadoopConfiguration.KEYTAB_KERBEROS_CONFIG_NAME,
                                 subject, new HadoopConfiguration());
        start = Time.now();
        // ② 真正登录（内部走 JDK Krb5LoginModule，与 KDC 交互拿 TGT）
        login.login();
        metrics.loginSuccess.add(Time.now() - start);
        // ③ 把登录后的 subject 包装成 UGI
        loginUser = new UserGroupInformation(subject);
        loginUser.setLogin(login);
        loginUser.setAuthenticationMethod(AuthenticationMethod.KERBEROS);
    } catch (LoginException le) {
        if (start > 0) metrics.loginFailure.add(Time.now() - start);
        throw new IOException("Login failure for " + user + " from keytab " +
                              path + ": " + le, le);
    }
    LOG.info("Login successful for user " + keytabPrincipal +
             " using keytab file " + keytabFile);
}
```

**JAAS Krb5LoginModule 配置选项**（`HadoopConfiguration.KEYTAB_KERBEROS_CONFIG_NAME` 内部定义）：
```java
useKeyTab = "true"
keyTab = path
storeKey = "true"
doNotPrompt = "true"
useTicketCache = "false"
principal = user
refreshKrb5Config = "true"
isInitiator = "true"
```

**login.login() 内部做的事**：
1. 调 KDC 的 AS（Authentication Server）请求 TGT，传送 principal
2. KDC 用 keytab 中存储的密钥（kvno）加密响应
3. JDK 用 keytab 同款密钥解密，验证成功 → 拿到 TGT
4. TGT 存进 Subject 的 PrivateCredentials

**生产关键 LOG**：`LOG.info("Login successful for user " + keytabPrincipal ...)` ←— 这条 INFO 是确认登录成功的标志。看不到这条就意味着登录失败。

### 3.2 checkTGTAndReloginFromKeytab —— 票据自动续期

`UserGroupInformation.java:1115-1126`：

```java
public synchronized void checkTGTAndReloginFromKeytab() throws IOException {
    if (!isSecurityEnabled()
            || user.getAuthenticationMethod() != AuthenticationMethod.KERBEROS
            || !isKeytab)                               // ★ 必须用 keytab 登录的才能 relogin
        return;
    KerberosTicket tgt = getTGT();
    if (tgt != null && !shouldRenewImmediatelyForTests &&
            Time.now() < getRefreshTime(tgt)) {         // ★ 没到续期点就 skip
        return;
    }
    reloginFromKeytab();                                 // ★ 真正续期
}
```

**`getRefreshTime(tgt)` 计算**（基于 Hadoop 通用经验）：
- 一般是 `tgt.startTime + (tgt.endTime - tgt.startTime) * 0.8`，即 80% 寿命点续期
- 比如 TGT 寿命 24h，启动后 19.2h 触发 relogin

**调用模式（生产代码必须）**：
```java
// 长期运行的服务，每次 RPC 前都调一下
ugi.checkTGTAndReloginFromKeytab();
ugi.doAs((PrivilegedExceptionAction<Void>) () -> {
    // 业务代码（HDFS/Hive/HBase 操作）
});
```

**为什么不能依赖 RPC 自动续期**？
- TGT 在 JDK GSS 层是"被动消费"的 —— 拿来换 ServiceTicket，但**不会主动续期**
- 长期服务（如 HiveServer2 / Spark Thrift Server）必须**主动调用** checkTGT，否则 TGT 一过期，下一次 RPC 报 `Cannot get tgt` 直接挂

### 3.3 reloginFromKeytab —— 真正续期

`UserGroupInformation.java:1173-1230`：

```java
public synchronized void reloginFromKeytab() throws IOException {
    if (!isSecurityEnabled() ||
        user.getAuthenticationMethod() != AuthenticationMethod.KERBEROS ||
        !isKeytab) {
        return;
    }

    long now = Time.now();
    if (!shouldRenewImmediatelyForTests && !hasSufficientTimeElapsed(now)) {
        return;                                          // ① 太频繁的 relogin 会被忽略
    }

    KerberosTicket tgt = getTGT();
    if (tgt != null && !shouldRenewImmediatelyForTests &&
            now < getRefreshTime(tgt)) {
        return;                                          // ② 双重检查 TGT 还在
    }

    LoginContext login = getLogin();
    if (login == null || keytabFile == null) {
        throw new IOException("loginUserFromKeyTab must be done first");
    }

    long start = 0;
    user.setLastLogin(now);
    try {
        synchronized (UserGroupInformation.class) {
            // ③ 关键：先 logout 清理旧 TGT
            login.logout();
            // ④ 用同样的 Subject 重新构造 LoginContext（保留 token，只清 kerberos creds）
            login = newLoginContext(
                HadoopConfiguration.KEYTAB_KERBEROS_CONFIG_NAME, getSubject(),
                new HadoopConfiguration());
            start = Time.now();
            // ⑤ 重新登录拿新 TGT
            login.login();
            // ⑥ 修复 TGT 顺序（HADOOP-13433：JDK 默认拿第一个 ticket 做 TGT）
            fixKerberosTicketOrder();
            metrics.loginSuccess.add(Time.now() - start);
            setLogin(login);
        }
    } catch (LoginException le) {
        if (start > 0) metrics.loginFailure.add(Time.now() - start);
        throw new IOException("Login failure for " + keytabPrincipal +
            " from keytab " + keytabFile + ": " + le, le);
    }
}
```

**生产中最重要的细节 —— `fixKerberosTicketOrder`**（`UserGroupInformation.java:1131-1160`）：

```java
private void fixKerberosTicketOrder() {
    Set<Object> creds = getSubject().getPrivateCredentials();
    synchronized (creds) {
        for (Iterator<Object> iter = creds.iterator(); iter.hasNext();) {
            Object cred = iter.next();
            if (cred instanceof KerberosTicket) {
                KerberosTicket ticket = (KerberosTicket) cred;
                if (ticket.isDestroyed() || ticket.getServer() == null) {
                    LOG.warn("Ticket is already destroyed, remove it.");
                    iter.remove();
                } else if (!ticket.getServer().getName().startsWith("krbtgt")) {
                    // ★ 如果第一个 ticket 不是 TGT（即 krbtgt/REALM@REALM），删掉
                    LOG.warn("The first kerberos ticket is not TGT" +
                             "(the server principal is {}), remove and destroy it.",
                             ticket.getServer());
                    iter.remove();
                    try { ticket.destroy(); }
                    catch (DestroyFailedException e) { LOG.warn("destroy ticket failed", e); }
                } else {
                    return;          // 找到 TGT 在第一位，OK
                }
            }
        }
    }
    LOG.warn("Warning, no kerberos ticket found while attempting to renew ticket");
}
```

**HADOOP-13433 修的什么 bug**？
- JDK Kerberos 库默认把 Subject 中的**第一个 KerberosTicket** 当作 TGT
- 如果 Service Ticket 排在前面，TGT 排后面 → JDK 误把 Service Ticket 当 TGT 用 → relogin 失败
- 修复：每次 relogin 后扫一遍 credentials，确保 TGT (`krbtgt/REALM@REALM`) 在第一位

**生产现象**：日志看到 `The first kerberos ticket is not TGT (the server principal is hdfs/...)` 说明踩过这个修复，是正常修复路径，不用慌。

### 3.4 doAs —— 委托身份执行

`UserGroupInformation.java:1822-1865`：

```java
public <T> T doAs(PrivilegedAction<T> action) {
    logPrivilegedAction(subject, action);
    return Subject.doAs(subject, action);                // ★ JDK 标准 API
}

public <T> T doAs(PrivilegedExceptionAction<T> action)
        throws IOException, InterruptedException {
    try {
        logPrivilegedAction(subject, action);
        return Subject.doAs(subject, action);
    } catch (PrivilegedActionException pae) {
        Throwable cause = pae.getCause();
        if (cause instanceof IOException) {
            throw (IOException) cause;
        } else if (cause instanceof Error) {
            throw (Error) cause;
        } else if (cause instanceof RuntimeException) {
            throw (RuntimeException) cause;
        } else if (cause instanceof InterruptedException) {
            throw (InterruptedException) cause;
        } else {
            throw new UndeclaredThrowableException(cause);
        }
    }
}
```

**`Subject.doAs(subject, action)` 内部做的事**（JDK API）：
1. 把当前线程的 `AccessControlContext` 关联到给定 `Subject`
2. 在该 context 下执行 `action.run()`
3. 在 action 执行期间，`Subject.getSubject(AccessController.getContext())` 返回这个 subject
4. action 内的所有 RPC 调用都自动用这个 subject 的 credentials

**UGI 的 doAs 与 Subject.doAs 对比**：
- `Subject.doAs` 是 JDK 原生 API，但调用方需要自己处理 PrivilegedActionException
- UGI 的 doAs 帮你把 PrivilegedActionException 解包成具体的业务异常（IOException 等），编程友好

### 3.5 getCurrentUser —— "我是谁" 的查询入口

`UserGroupInformation.java:676-684`：

```java
public synchronized
static UserGroupInformation getCurrentUser() throws IOException {
    AccessControlContext context = AccessController.getContext();
    Subject subject = Subject.getSubject(context);       // ★ 从当前 thread 的 AccessControlContext 取 subject
    if (subject == null || subject.getPrincipals(User.class).isEmpty()) {
        return getLoginUser();                            // 没 subject → 返回 login user（启动时的）
    } else {
        return new UserGroupInformation(subject);         // 有 subject → 返回当前线程的（可能是 doAs 切的）
    }
}
```

**这就是 "doAs 内 vs doAs 外" 拿到不同 UGI 的原因**：
```java
ugi.doAs(() -> {
    // 这里 getCurrentUser() 返回 ugi 本身
    UserGroupInformation u = UserGroupInformation.getCurrentUser();
    return null;
});
// 这里 getCurrentUser() 返回 loginUser（启动时登录的，比如 hdfs principal）
```

### 3.6 SaslRpcServer —— Kerberos RPC 服务端入口

`SaslRpcServer.java:96-150`：

```java
public class SaslRpcServer {
    public static enum QualityOfProtection {
        AUTHENTICATION("auth"),       // 仅认证
        INTEGRITY("auth-int"),         // 认证 + 完整性校验（HMAC）
        PRIVACY("auth-conf");          // 认证 + 加密
    }

    public AuthMethod authMethod;
    public String mechanism;
    public String protocol;
    public String serverId;

    public SaslRpcServer(AuthMethod authMethod) throws IOException {
        this.authMethod = authMethod;
        mechanism = authMethod.getMechanismName();
        switch (authMethod) {
            case SIMPLE: return;        // 不安全模式
            case TOKEN: {                // 委托令牌（DT）
                protocol = "";
                serverId = SaslRpcServer.SASL_DEFAULT_REALM;
                break;
            }
            case KERBEROS: {             // ★ Kerberos 主流路径
                String fullName = UserGroupInformation.getCurrentUser().getUserName();
                String[] parts = fullName.split("[/@]", 3);
                protocol = parts[0];      // "hdfs"
                serverId = (parts.length < 2) ? "" : parts[1];   // "nn1.example.com"
                break;
            }
            default:
                throw new AccessControlException("Server does not support SASL " + authMethod);
        }
    }

    public SaslServer create(final Connection connection,
                              final Map<String,?> saslProperties,
                              SecretManager<TokenIdentifier> secretManager
        ) throws IOException, InterruptedException {
        UserGroupInformation ugi = null;
        final CallbackHandler callback;
        switch (authMethod) {
            case TOKEN:
                callback = new SaslDigestCallbackHandler(secretManager, connection);
                break;
            case KERBEROS: {
                ugi = UserGroupInformation.getCurrentUser();
                if (serverId.isEmpty()) {
                    throw new AccessControlException(
                        "Kerberos principal name does NOT have the expected hostname part: " +
                        ugi.getUserName());
                }
                callback = new SaslGssCallbackHandler();      // ★ GSS-API 回调
                break;
            }
            ...
        }
    }
}
```

**关键解析**：
- principal 命名规则 `protocol/host@REALM`，如 `hdfs/nn1.example.com@HADOOP.COM`
- `parts = fullName.split("[/@]", 3)` 拆成 `["hdfs", "nn1.example.com", "HADOOP.COM"]`
- `protocol` 用于 SASL `SaslServer.create(protocol, serverId, ...)` 的服务标识
- `serverId` 必须包含 hostname，否则报 `Kerberos principal name does NOT have the expected hostname part`

**QOP（Quality Of Protection）三档**：
- `auth`：只认证
- `auth-int`：认证 + 完整性（防篡改）
- `auth-conf`：认证 + 加密（机密性 + 完整性）
- 配置：`hadoop.rpc.protection=privacy/integrity/authentication`

## 四、Kerberos RPC 全链路（端到端）

```
[Spark Driver / Hive Client]
   │
   │ 启动时：UserGroupInformation.loginUserFromKeytab("alice", "alice.keytab")
   │ → JAAS → KDC.AS → 拿 TGT 存到 Subject
   ▼
[业务代码触发 RPC，比如 fs.open(path)]
   │
   │ Hadoop RPC client 发现 server 是 KERBEROS auth
   │ → SaslRpcClient 调 GSS-API 用 TGT 换 ServiceTicket（hdfs/nn1@HADOOP.COM）
   │ → 发送 AP_REQ 到 server
   ▼
[NameNode]
SaslRpcServer.create(KERBEROS) → 构造 SaslServer
SaslGssCallbackHandler 接 GSS-API → 验证 AP_REQ
   │
   │ 验证通过 → 提取 client principal "alice@HADOOP.COM"
   │ → auth_to_local 规则映射到 short name "alice"
   │ → new UserGroupInformation(alice subject)
   ▼
RPC handler 执行业务逻辑（在 alice 身份下）
   │
   │ doAs 委托？
   │ - HiveServer2 用 hive principal 登录
   │ - 用户 alice 提交查询
   │ - HS2 用 ugi.doAs(alice) 包裹下游 fs 操作
   │ - NameNode 收到的是 hive 的 ticket（impersonation）
   │   但 effective user = alice
   ▼
[操作完成]
audit log 记 user=alice, op=open, path=/data/...
```

## 五、实战 LOG 对齐

| 日志关键词 | 出处 | 含义 |
|----------|------|------|
| `Login successful for user X using keytab file Y` | `UserGroupInformation.java:1069` (INFO) | keytab 登录成功 |
| `Login failure for X from keytab Y: ...` | `:1066` (异常) | keytab 登录失败 |
| `Initiating logout for X` | `:1095/1202` (DEBUG) | logout 触发 |
| `Initiating re-login for X` | `:1215` (DEBUG) | reloginFromKeytab 触发 |
| `The first kerberos ticket is not TGT...` | `:1142` (WARN) | HADOOP-13433 修复路径触发 |
| `Ticket is already destroyed, remove it` | `:1139` (WARN) | TGT 已销毁，可能续期失败前兆 |
| `Warning, no kerberos ticket found while attempting to renew ticket` | `:1158` (WARN) | 严重：subject 中没 TGT，relogin 必败 |
| `Kerberos principal name is X` | `SaslRpcServer.java:111` (DEBUG) | server 端识别 client principal |
| `Kerberos principal name does NOT have the expected hostname part` | `SaslRpcServer.java:144` | server principal 配错（缺 hostname）|

**经典故障 LOG 排查矩阵**：

| 错误信息 | 大概率原因 | 应对 |
|---------|-----------|------|
| `Cannot get tgt` | TGT 过期，未调 reloginFromKeytab | 加定期 checkTGT |
| `Server not found in Kerberos database` | krb5.conf 没配 realm，或 KDC 没该 service principal | 检查 krb5.conf [realms] + KDC `addprinc` |
| `Clock skew too great` | client/server 时钟差 > 5min | NTP 同步 |
| `KrbException: Specified version of key is not available (44)` | keytab 里 kvno 与 KDC 不一致 | 重新 ktadd 生成 keytab |
| `GSS initiate failed [...] No valid credentials provided` | client 没登录就发 RPC | 调 loginUserFromKeytab |
| `auth_to_local rule X not matched` | core-site.xml `hadoop.security.auth_to_local` 没覆盖 principal | 加规则 |
| `Failed to find any Kerberos tgt` | Subject 没 TGT，可能 fixKerberosTicketOrder 删错了 | 看 WARN 日志确认 |

## 六、设计意图总结

| 设计 | 为什么 |
|------|-------|
| UGI 包装 JAAS Subject | 屏蔽 JAAS 复杂性，提供 Hadoop 友好 API |
| keytab 模式 vs ticket cache 模式 | keytab 适合长期服务（无需 kinit），ticket cache 适合人类用户 |
| `checkTGTAndRelogin` vs `reloginFromKeytab` 双层 | check 是廉价的（看 TGT 时间），relogin 是昂贵的（与 KDC 交互），分开避免无谓 KDC 压力 |
| `fixKerberosTicketOrder` 修 JDK bug | 在框架层兜底，不依赖 JDK 修复 |
| `doAs` 用 PrivilegedAction | 复用 JDK 标准安全模型，与 SecurityManager 兼容 |
| SASL-GSSAPI 接入 | 让 Hadoop RPC 不直接依赖 Kerberos API，通过标准 SASL 桥接 |
| QOP 三档可选 | 性能与安全权衡（生产敏感数据强制 privacy）|
| auth_to_local 规则 | 多 realm 集群需要把 `alice@CORP.COM` 映射成本地 `alice` |

## 七、关键参数清单

| 参数 | 默认 | 含义 |
|------|------|------|
| `hadoop.security.authentication` | simple | 认证模式：simple / kerberos |
| `hadoop.security.authorization` | false | 授权检查（独立于认证）|
| `hadoop.rpc.protection` | authentication | SASL QOP |
| `hadoop.kerberos.kinit.command` | kinit | kinit 命令路径（用于 ticket cache 续期）|
| `hadoop.kerberos.min.seconds.before.relogin` | 60 | reloginFromKeytab 最小间隔（防风暴）|
| `hadoop.security.auth_to_local` | DEFAULT | principal → short name 映射规则 |
| `hadoop.security.token.service.use_ip` | true | DT 是否用 IP 当服务标识 |
| Java system property `java.security.krb5.conf` | /etc/krb5.conf | KDC 配置文件路径 |
| Java system property `sun.security.krb5.debug` | false | **生产排查必开**：KDC 通讯调试日志 |
| Java system property `sun.security.spnego.debug` | false | SPNEGO 调试 |

## 八、踩坑记录

1. **TGT 过期任务挂掉（最经典）** —— Spark/Flink 长任务跑 24h 后突然 `Cannot get tgt`。**根因**：默认 TGT 24h 过期，没 relogin 机制。**应对**：① 启动时 keytab 登录 ② 用 `--principal` `--keytab` 提交（YARN/K8s 自动续期）③ 自定义代码每隔 N 分钟 `checkTGTAndReloginFromKeytab`。
2. **HiveServer2 高并发 relogin 风暴** —— 多线程同时调 reloginFromKeytab，KDC 被打挂。**应对**：`hadoop.kerberos.min.seconds.before.relogin=300` 抑制频繁 relogin。
3. **`auth_to_local` 不生效** —— 配了规则但日志看到完整 principal `alice@CORP.COM` 当用户名。**根因**：规则语法错（如 `RULE:[1:$1@$0](.*@CORP.COM)s/@.*//`），Hadoop 在解析失败时静默 fallback。**应对**：用 `hadoop org.apache.hadoop.security.HadoopKerberosName <principal>` 测试规则。
4. **Clock Skew** —— client 和 KDC 时钟差超过 5min（默认）报 `Clock skew too great`。**应对**：NTP 强制同步；或调 KDC `clockskew=300`（仍建议同步）。
5. **`No valid credentials provided`** —— Spark Executor 拿不到 TGT。**根因**：NodeManager 转发 token 时漏了，或 Executor 启动顺序问题。**应对**：`--principal` `--keytab` 让 driver 把 keytab 推送到 executor。
6. **跨 realm 不通** —— Hive 在 CORP.HADOOP.COM realm，HBase 在 PROD.HADOOP.COM realm，互调失败。**应对**：建立 cross-realm trust：两 KDC 互相 `addprinc krbtgt/CORP.HADOOP.COM@PROD.HADOOP.COM`。
7. **HADOOP-13433 痕迹** —— 日志看到 `The first kerberos ticket is not TGT, remove and destroy it`。**这是修复路径，不是 bug**。但频繁出现说明应用在 ticket 顺序上有问题，看是否手动操作过 Subject。
8. **kvno 不一致** —— 改密码后 keytab 没重新生成 → kvno mismatch。**应对**：`ktutil` 重做 keytab 时 `addent` 用最新 kvno，老的 keytab 立即失效。
9. **`hadoop.rpc.protection` 不一致** —— client 配 privacy，server 配 authentication，握手失败。**应对**：所有节点统一配置（或 server 配置 `authentication,integrity,privacy` 兼容多种 client）。
10. **JVM 进程长跑后 KerberosTicket 内存泄漏** —— 每次 relogin 旧 ticket 没及时 destroy。**应对**：fixKerberosTicketOrder 已经处理大部分，自定义代码不要持有 KerberosTicket 强引用。

## 九、认知更新

- **`checkTGTAndReloginFromKeytab` 是廉价操作**：之前以为每次调都会走 KDC，**实际上先看 TGT 是否过 80% 寿命，没到就直接 return**。生产中**每次 RPC 前都调一次** 是安全且低成本的做法。
- **`reloginFromKeytab` 不会清空 token**（HDFS Delegation Token 等）：源码注释明确 "the kerberos credentials are cleared"，但 token 保留。**所以 relogin 不会让正在执行的 task 失去 token 授权**。
- **`fixKerberosTicketOrder` 是必经路径**：日志看到这个 WARN 不要慌，是 HADOOP-13433 的修复在工作。但**应用不该自己往 Subject 加 KerberosTicket**，否则可能反复触发。
- **`Subject.doAs` 是线程级别的**：不传播到子线程！如果在 doAs 内 `new Thread().start()`，新线程**不在** doAs context 内，需要手动再 doAs 一次。**这是 Spark/Flink 多线程 Kerberos bug 的常见根源**。
- **SaslRpcServer 的 `serverId` 必须包含 hostname**：principal 必须是 `service/host@REALM` 形式，**不能是** `service@REALM`。这是为了支持同 service 在多机部署，每个节点用不同 ticket。
- 长期服务的 keytab 提交方案：**Spark `--keytab` / Flink `security.kerberos.login.keytab`** 让框架接管 relogin，**比应用自己写 checkTGT 更可靠**（框架会处理 executor 端转发）。

## 十、下一步深挖方向

- [ ] HDFS Delegation Token 全生命周期（issue / renew / cancel）
- [ ] SPNEGO over HTTP（webhdfs / KNOX 用的）
- [ ] cross-realm trust 配置 + ticket flag (forwardable/proxiable) 影响
- [ ] Hadoop RPC 的 `IpcConnectionContextProto` 协议（client 如何把 effective user 传给 server）
- [ ] auth_to_local 规则引擎（KerberosName.java）
- [ ] Kerberos 与 LDAP/AD 集成的 SSSD 路径

---

**沉淀完成。Kerberos 三方协议到 Hadoop UGI 抽象的映射、loginUserFromKeytab/reloginFromKeytab/checkTGT 三件套区别、SaslRpcServer GSSAPI 集成机制源码精确对齐。**
