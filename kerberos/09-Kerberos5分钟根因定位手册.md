# Kerberos 5 分钟根因定位手册

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> **从"看到现象"到"锁定根因"，目标 ≤ 5 分钟**  
> 配套：[错误码全字典](./08-Kerberos错误码全字典.md)

---

## 一、5 分钟定位法核心思想

### 1.1 黄金法则

```
不要从原理推根因 → 太慢
要用「症状→根因」反查表 → 5 秒命中
```

### 1.2 5 步定位法

```
Step 1 [10s]  确认是 Kerberos 问题（不是应用 bug）
Step 2 [30s]  归类报错类别（A/B/C/D/E/F 6 类）
Step 3 [60s]  对应类别走 1-2 个验证命令
Step 4 [120s] 锁定根因（90% 命中）
Step 5 [60s]  执行修复 + 验证
─────────────
合计 ≤ 5 分钟
```

---

## 二、Step 1 — 是不是 Kerberos 问题？（10 秒）

### 2.1 必须有以下关键字之一才是 Kerberos：

```
✅ Kerberos
✅ KrbException
✅ GSSException
✅ kinit / klist
✅ TGT / TGS / Service Ticket
✅ keytab / principal
✅ SPNEGO
✅ SASL (大概率)
✅ KDC
✅ -1765328xxx 这类错误码
```

### 2.2 容易误判的"伪 Kerberos"问题：

```
❌ Permission denied (org.apache.hadoop.security.AccessControlException) 
   但 caused by 不是 GSSException → 是授权问题，不是认证
   
❌ Connection refused → 网络 / 服务挂，不一定是 KDC

❌ Hive Privilege Check Failed → SQL 鉴权问题

❌ Block missing → HDFS 数据问题

❌ HTTP 401 但 Hadoop 没开 Kerberos → 应用自身鉴权
```

### 2.3 一行命令快速验证

```bash
# 把报错堆栈贴到这个 grep
echo "$ERROR_LOG" | grep -iE "kerberos|gssexception|krbexception|sasl|spnego|keytab|kinit|kdc|tgt|principal|-176532"
# 命中 → 是 Kerberos 问题
# 没命中 → 不是
```

---

## 三、Step 2 — 归类报错类别（30 秒）

### 3.1 6 大类速判

| 报错关键字 | 类别 | 跳到 |
|----------|------|------|
| `Clock skew`、`Ticket not yet valid` | **A 时间类** | §4 |
| `Cannot contact any KDC`、`UnknownHostException`、`Connection refused` | **B 网络类** | §5 |
| `Pre-authentication failed`、`KVNO`、`Specified version of key`、`Decrypt integrity check failed` | **C 密钥类** | §6 |
| `Client not found`、`Server not found`、`PREAUTH_FAILED` | **D Principal 类** | §7 |
| `No valid credentials`、`No LoginModules`、`Failed to find any Kerberos tgt` | **E Login/Token 类** | §8 |
| `Cannot authenticate via [KERBEROS]`、`SIMPLE auth not enabled` | **F 配置类** | §9 |

### 3.2 命令行 30 秒分类法

```bash
# 一行命令搞定
classify_error() {
    local err="$*"
    case "$err" in
        *Clock\ skew*|*Ticket\ not\ yet\ valid*) echo "A 时间类" ;;
        *Cannot\ contact*|*UnknownHostException*|*Connection\ refused*) echo "B 网络类" ;;
        *Pre-authentication*|*KVNO*|*Specified\ version*|*Decrypt\ integrity*) echo "C 密钥类" ;;
        *Client\ not\ found*|*Server\ not\ found*|*PREAUTH_FAILED*) echo "D Principal类" ;;
        *No\ valid\ credentials*|*No\ LoginModules*|*Failed\ to\ find*) echo "E Login/Token类" ;;
        *Cannot\ authenticate\ via*|*SIMPLE\ auth*) echo "F 配置类" ;;
        *) echo "未分类，需 KRB5_TRACE" ;;
    esac
}
```

---

## 四、A 类「时间问题」5 分钟定位

### 4.1 症状速查表

| 现象 | 99% 根因 | 验证命令 | 修复 |
|------|---------|---------|------|
| Clock skew too great | 时钟偏差 > 5min | `date && ssh kdc date` | `chronyc -a makestep` |
| Ticket not yet valid | 客户端时钟慢 | 同上 | 同上 |
| Defective token detected | 时钟微差 | 同上 | 同上 |
| Ticket expired（短期内）| 时钟跳变 | `journalctl \| grep clock` | NTP 修复 |

### 4.2 一键诊断脚本

```bash
#!/bin/bash
# kerb_time_check.sh
echo "=== 本机时间 ==="
date
echo ""
echo "=== KDC 时间 ==="
KDC=$(awk '/^\s*kdc\s*=/{print $3; exit}' /etc/krb5.conf | cut -d: -f1)
ssh -o ConnectTimeout=2 $KDC "date" 2>/dev/null || echo "KDC 不可达，跳过"
echo ""
echo "=== chrony 状态 ==="
chronyc tracking 2>/dev/null | head -5
echo ""
echo "=== 与公网 NTP 偏差 ==="
ntpdate -q ntp.aliyun.com 2>/dev/null | tail -1
echo ""
echo "=== 时区 ==="
timedatectl 2>/dev/null | grep -E "Time zone|NTP|RTC"
```

### 4.3 修复 3 选 1

```bash
# 紧急（立即同步）
chronyc -a makestep

# 或（强制）
ntpdate -s ntp.aliyun.com

# 或（持续同步）
systemctl restart chronyd
```

---

## 五、B 类「网络问题」5 分钟定位

### 5.1 症状速查表

| 现象 | 90% 根因 | 验证 | 修复 |
|------|---------|-----|------|
| Cannot contact any KDC | KDC 进程挂 / 端口封 | `nc -zv kdc 88` | 拉起 KDC |
| UnknownHostException | DNS 解析失败 | `nslookup kdc` | 加 hosts |
| Connection refused | 端口未监听 | `nc -zv kdc 88` | 启动服务 |
| Receive timed out | UDP 包大被截断 | `KRB5_TRACE` 看 | `udp_preference_limit=1` |
| NoRouteToHostException | 路由不通 | `mtr kdc` | 防火墙/路由 |

### 5.2 一键诊断脚本

```bash
#!/bin/bash
# kerb_network_check.sh
KDC=${1:-$(awk '/^\s*kdc\s*=/{print $3; exit}' /etc/krb5.conf | cut -d: -f1)}

echo "=== DNS 解析 ==="
nslookup $KDC 2>&1 | grep -E "Address|server"
echo ""

echo "=== TCP 88 ==="
nc -zv -w2 $KDC 88
echo ""

echo "=== UDP 88 ==="
nc -zvu -w2 $KDC 88
echo ""

echo "=== TCP 749 (kadmin) ==="
nc -zv -w2 $KDC 749
echo ""

echo "=== ICMP ==="
ping -c2 -W2 $KDC | tail -3
echo ""

echo "=== 路由 ==="
ip route get $(getent ahostsv4 $KDC | head -1 | awk '{print $1}') 2>/dev/null

echo ""
echo "=== 防火墙（KDC 端） ==="
ssh -o ConnectTimeout=2 $KDC "iptables -L INPUT -n | grep 88; firewall-cmd --list-ports 2>/dev/null" 2>/dev/null
```

### 5.3 决策树

```
nc -zv kdc 88
├── 通 → 不是网络问题，回 §3 重新分类
└── 不通
    ├── nslookup kdc 失败 → DNS 问题
    │   └── 修复：加 /etc/hosts 或修 DNS
    ├── ping 不通 → 网络/防火墙
    │   └── mtr 找断点
    └── ping 通但端口不通 → 服务/防火墙
        ├── ssh kdc 'ss -lntup | grep 88' → 看进程
        └── 没进程 → systemctl start krb5kdc
```

---

## 六、C 类「密钥问题」5 分钟定位（最复杂）

### 6.1 症状速查表

| 现象 | 90% 根因 | 验证 | 修复 |
|------|---------|-----|------|
| Pre-authentication failed | 密码错 / KVNO 错 / enctype 错 | KRB5_TRACE | 见 §6.2 |
| Specified version of key not available | KVNO 不一致 | `klist -kt` vs `kvno` | `ktadd -norandkey` |
| Decrypt integrity check failed (单域) | keytab 损坏 | `klist -kt` | 重新 ktadd |
| Decrypt integrity check failed (跨域) | krbtgt 密码不一致 | 双方 KDC 比对 | 重置 krbtgt |
| Cannot find key of appropriate type | enctype 缺失 | `klist -ket` | `ktadd -e <enctype>` |
| Encryption type not supported | JCE 限制 / krb5.conf 不支持 | java security | 解锁 JCE |

### 6.2 三秒判别 KVNO 是否一致（C 类首选检查）

```bash
#!/bin/bash
# kvno_check.sh - 一行命令搞定
PRINCIPAL=$1
KEYTAB=$2

kt_kvno=$(klist -kt $KEYTAB 2>/dev/null | grep "$PRINCIPAL" | awk '{print $1}' | sort -u)
kdc_kvno=$(kvno $PRINCIPAL 2>/dev/null | awk '{print $NF}')

echo "Principal: $PRINCIPAL"
echo "Keytab KVNO: $kt_kvno"
echo "KDC KVNO:    $kdc_kvno"

if [[ "$kt_kvno" != "$kdc_kvno" ]]; then
    echo "❌ MISMATCH"
    echo ""
    echo "修复：在 KDC 上执行"
    echo "  kadmin.local -q 'ktadd -norandkey -k /tmp/$(basename $KEYTAB) $PRINCIPAL'"
    echo "  scp /tmp/$(basename $KEYTAB) <host>:$KEYTAB"
else
    echo "✅ MATCH，问题不在 KVNO"
fi
```

### 6.3 enctype 是否齐全

```bash
# keytab 中的 enctype
klist -ket /path/keytab | awk -F'[()]' '{print $2}' | sort -u

# KDC 中的 enctype（看 principal 的 keys）
kadmin.local -q "getprinc principal" | grep "Key:"

# 期望两边都有：
# aes256-cts-hmac-sha1-96
# aes128-cts-hmac-sha1-96
```

### 6.4 KRB5_TRACE 看密钥协商（决定性证据）

```bash
KRB5_TRACE=/dev/stderr kinit -V -kt $KEYTAB $PRINCIPAL 2>&1 | grep -E "Salt|etype|KVNO|key"

# 关键行：
# [xxx] Selected etype info: etype 18, salt "..."
#                                     ^^^ enctype 18 = aes256-cts-hmac-sha1-96
# [xxx] Decoded AS-REP            ← 成功
# [xxx] Preauth tryagain ...      ← 失败
```

### 6.5 修复决策树

```
Pre-auth failed
├── KVNO 不一致 → ktadd -norandkey
├── enctype 缺失 → ktadd -e aes256-cts...
├── 密码改了 → 重新 cpw + ktadd
└── 跨域 → 双方重置 krbtgt 同密码
```

---

## 七、D 类「Principal 不存在」5 分钟定位

### 7.1 症状速查表

| 现象 | 99% 根因 | 验证 | 修复 |
|------|---------|-----|------|
| Client 'X' not found | KDC 中没有用户 | `kadmin.local -q "listprincs" \| grep X` | `addprinc X` |
| Server 'svc/host' not found | SPN 不存在 / FQDN 错 | 同上 | `addprinc -randkey` |
| /var/log/krb5kdc.log: UNKNOWN_SERVER | 同上 | 看 KDC 日志 | 同上 |

### 7.2 一键 SPN 诊断

```bash
#!/bin/bash
# spn_check.sh
PRINCIPAL=$1
KDC=${2:-kdc01.bigdata.com}

echo "=== 本机 hostname ==="
echo "hostname: $(hostname)"
echo "hostname -f: $(hostname -f)"
echo ""

echo "=== KDC 中是否存在 ==="
ssh $KDC "kadmin.local -q 'getprinc $PRINCIPAL'" 2>&1 | head -3
echo ""

echo "=== 模糊匹配（大小写敏感）==="
SVC=$(echo $PRINCIPAL | cut -d/ -f1)
ssh $KDC "kadmin.local -q \"listprincs '$SVC*'\"" 2>&1 | head -10
echo ""

echo "=== 客户端实际请求的 SPN（要看 KRB5_TRACE）==="
echo "执行：KRB5_TRACE=/dev/stderr <你的命令> 2>&1 | grep 'TGS-REQ for'"
```

### 7.3 FQDN 错配排查

```bash
# 三方对齐
echo "客户端 hostname -f: $(hostname -f)"
echo "DNS 正解: $(getent hosts $(hostname -f))"
echo "DNS 反解: $(getent hosts $(hostname -i))"
# 这三方必须指向同一个 FQDN，否则 _HOST 替换出错
```

---

## 八、E 类「Login/Token 问题」5 分钟定位

### 8.1 症状速查表

| 现象 | 90% 根因 | 验证 | 修复 |
|------|---------|-----|------|
| No valid credentials provided | 没 kinit / CCNAME 路径错 | `klist; echo $KRB5CCNAME` | kinit |
| Failed to find any Kerberos tgt | 同上 | 同上 | 同上 |
| No LoginModules configured | 没指定 jaas.conf | 看 JVM 参数 | `-Djava.security.auth.login.config` |
| Unable to obtain password | keytab 读不到 | `ls -l keytab` | chown/chmod |
| Login failure for X from keytab | keytab 缺 X | `klist -kt` | `ktadd` |
| token (HDFS_DELEGATION_TOKEN) is expired | 长任务 7 天到期 | 看任务运行时长 | `--keytab` 重提交 |

### 8.2 一键 Login 诊断

```bash
#!/bin/bash
# login_check.sh
echo "=== 当前用户 ==="
id
echo ""

echo "=== KRB5CCNAME ==="
echo "环境变量: ${KRB5CCNAME:-<未设>}"
echo ""

echo "=== 默认 ccache ==="
klist 2>&1 | head -10
echo ""

echo "=== 所有 ccache (KEYRING/DIR) ==="
klist -A 2>&1 | head -20
echo ""

echo "=== 系统默认 ccache 类型 ==="
grep -E "default_ccache_name" /etc/krb5.conf
echo ""

echo "=== 进程环境变量（如果是服务）==="
if [[ -n "$1" ]]; then
    PID=$1
    cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep -i "krb5\|jaas"
fi
```

### 8.3 ccache 类型问题（容器/K8s 必查）

```bash
# 看 ccache 是不是 KEYRING（容器中失效）
echo $KRB5CCNAME
# 如果是 KEYRING:persistent:1000 或类似 → 改成 FILE

# 修改
echo "[libdefaults]
default_ccache_name = FILE:/tmp/krb5cc_%{uid}" | sudo tee -a /etc/krb5.conf
```

---

## 九、F 类「配置问题」5 分钟定位

### 9.1 症状速查表

| 现象 | 90% 根因 | 验证 | 修复 |
|------|---------|-----|------|
| Cannot authenticate via [TOKEN, KERBEROS] | 客户端没启 Kerberos | `grep authentication core-site.xml` | 改成 kerberos |
| SIMPLE authentication is not enabled | 同上 | 同上 | 同上 |
| Server has invalid Kerberos principal | 服务端 SPN 与配置不符 | 看服务进程 | hostname -f 校验 |
| ProxyUser 'X' is not allowed to impersonate 'Y' | proxyuser 没配 | core-site.xml | hadoop.proxyuser.X.hosts/groups |

### 9.2 一键配置诊断

```bash
#!/bin/bash
# config_check.sh
HADOOP_CONF=${HADOOP_CONF_DIR:-/etc/hadoop/conf}

echo "=== Kerberos 是否启用 ==="
grep -A1 "hadoop.security.authentication" $HADOOP_CONF/core-site.xml | grep -A1 value
echo ""

echo "=== Kerberos principals 配置 ==="
grep -E "kerberos.principal|keytab.file" $HADOOP_CONF/*.xml | head -20
echo ""

echo "=== auth_to_local 规则 ==="
grep -A20 "auth_to_local" $HADOOP_CONF/core-site.xml | head -25
echo ""

echo "=== ProxyUser 配置 ==="
grep -E "hadoop.proxyuser" $HADOOP_CONF/core-site.xml
echo ""

echo "=== krb5.conf 关键 ==="
grep -E "default_realm|rdns|udp_preference|forwardable|enctype" /etc/krb5.conf
echo ""

echo "=== JCE 解锁状态 ==="
java -version 2>&1
jrunscript -e 'print(javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))' 2>/dev/null
# 输出 2147483647 ✅ / 128 ❌
```

---

## 十、终极武器 — KRB5_TRACE + sun.security.krb5.debug

### 10.1 启用方式

```bash
# 命令行客户端（kinit/klist 等）
export KRB5_TRACE=/dev/stderr
kinit -V principal

# Java 客户端
HADOOP_OPTS="-Dsun.security.krb5.debug=true \
             -Dsun.security.spnego.debug=true \
             -Djava.security.debug=gssloginconfig,configfile,configparser,logincontext" \
hdfs dfs -ls /

# Spark
spark-submit \
    --conf "spark.driver.extraJavaOptions=-Dsun.security.krb5.debug=true" \
    --conf "spark.executor.extraJavaOptions=-Dsun.security.krb5.debug=true" \
    ...
```

### 10.2 关键日志解读

```
KRB5_TRACE 输出关键行：

[xxx] Sending initial UDP request                    ← 发包
[xxx] Sending TCP request to                          ← 走 TCP
[xxx] Received error from KDC: -1765328359/Clock skew too great   ← KDC 拒绝
[xxx] Selected etype info: etype 18, salt "..."       ← 协商 enctype
[xxx] Decoded AS-REP                                  ← 拿到 TGT
[xxx] tkt_creds: requesting ticket for hdfs/nn01...   ← 请求 ST
[xxx] crypto: aes256-cts/16                           ← 加密算法

Java debug 输出关键行：

>>> KrbAsReq creating message                          ← 构造请求
>>>KdcAccessibility: remove kdc01:88                   ← KDC 不可达
>>> KrbKdcReq send: kdc=kdc02 TCP:88                  ← 重试
>>> KrbAsRep cons in KrbAsReq.getReply                ← 收到响应
Found ticket for hdfs/nn01@REALM to go to krbtgt/...  ← 找到票
```

### 10.3 5 步分析法

```
Step 1: grep "Sending"    看请求往哪发
Step 2: grep "Received"   看响应是什么（成功 or 错误码）
Step 3: grep "etype"      看 enctype 协商结果
Step 4: grep "Salt"       看密钥派生用的 salt
Step 5: grep "error"      看具体错误
```

---

## 十一、5 分钟黄金诊断脚本（综合）

```bash
#!/bin/bash
# kerb_5min_diag.sh - 5 分钟综合诊断
# Usage: kerb_5min_diag.sh [principal] [keytab]

PRINCIPAL="${1:-}"
KEYTAB="${2:-}"
TMPLOG=$(mktemp)
START=$(date +%s)

banner() { echo ""; echo "===== $1 ====="; }

banner "Step 0 - 基础环境"
echo "Host: $(hostname -f)"
echo "User: $(id)"
echo "Date: $(date)"
echo "JAVA: $JAVA_HOME"
echo "krb5.conf: $(stat -c %y /etc/krb5.conf 2>/dev/null)"

banner "Step 1 - 时钟检查"
date
KDC=$(awk '/^\s*kdc\s*=/{print $3; exit}' /etc/krb5.conf | cut -d: -f1)
[[ -n "$KDC" ]] && ssh -o ConnectTimeout=2 $KDC "date" 2>/dev/null
chronyc tracking 2>/dev/null | head -3

banner "Step 2 - 网络检查"
echo "KDC: $KDC"
nc -zv -w2 $KDC 88 2>&1
nc -zvu -w2 $KDC 88 2>&1

banner "Step 3 - DNS"
nslookup $KDC 2>&1 | grep -E "Address|server"
echo "本机 hostname -f: $(hostname -f)"

banner "Step 4 - krb5.conf 关键项"
grep -E "default_realm|rdns|udp_preference|forwardable" /etc/krb5.conf

banner "Step 5 - 当前 ccache"
echo "KRB5CCNAME: ${KRB5CCNAME:-<unset>}"
klist 2>&1 | head -10

if [[ -n "$KEYTAB" && -n "$PRINCIPAL" ]]; then
    banner "Step 6 - keytab 检查"
    ls -l $KEYTAB
    klist -ket $KEYTAB | head -10

    banner "Step 7 - KVNO 比对"
    kt_kvno=$(klist -kt $KEYTAB 2>/dev/null | grep "$PRINCIPAL" | awk '{print $1}' | sort -u | head -1)
    kdc_kvno=$(kvno $PRINCIPAL 2>/dev/null | awk '{print $NF}')
    echo "Keytab: $kt_kvno"
    echo "KDC:    $kdc_kvno"
    [[ "$kt_kvno" != "$kdc_kvno" ]] && echo "❌ KVNO MISMATCH"

    banner "Step 8 - 测试 kinit (with KRB5_TRACE)"
    KRB5_TRACE=$TMPLOG kinit -V -kt $KEYTAB $PRINCIPAL 2>&1
    echo ""
    echo "--- TRACE 关键行 ---"
    grep -E "Sending|Received|error|etype|Salt|Selected" $TMPLOG | head -15
    klist 2>&1 | head -5
    kdestroy 2>/dev/null
fi

banner "Step 9 - JCE 解锁状态"
jrunscript -e 'print(javax.crypto.Cipher.getMaxAllowedKeyLength("AES"))' 2>/dev/null

banner "Step 10 - Hadoop 配置"
HC=${HADOOP_CONF_DIR:-/etc/hadoop/conf}
[[ -d $HC ]] && grep -A1 "hadoop.security.authentication" $HC/core-site.xml | head -3

DURATION=$(($(date +%s) - START))
echo ""
echo "===== 诊断完成 (${DURATION}s) ====="
echo "完整 TRACE: $TMPLOG"
```

---

## 十二、实战：典型场景 5 分钟定位

### 12.1 场景：`hdfs dfs -ls /` 报 GSSException

```bash
# 1分钟：基础
klist                                         # 没有 TGT？
echo $KRB5CCNAME
sudo -u hdfs klist                            # 服务用户的票呢？

# 2分钟：触发 + trace
KRB5_TRACE=/dev/stderr hdfs dfs -ls / 2>&1 | tee /tmp/dbg.log

# 3分钟：分析
grep "TGS-REQ for" /tmp/dbg.log               # 实际请求的 SPN
grep "Received error" /tmp/dbg.log            # 错误码

# 4分钟：根据错误码查 §08 错误码字典

# 5分钟：执行修复 + 验证
```

### 12.2 场景：`spark-submit` 跑 7 天后挂

```bash
# 1分钟：症状判断
yarn logs -applicationId <appId> | grep -i "token\|expired"
# 命中 token expired → 长任务 token 问题

# 2分钟：检查提交命令
yarn application -status <appId> | grep -i "kerberos\|keytab"
# 没有 --keytab → 根因锁定

# 3分钟：修复
spark-submit \
    --keytab /path/to/keytab \
    --principal user@REALM \
    --conf spark.kerberos.access.hadoopFileSystems=hdfs://nn:8020 \
    ...

# 4-5分钟：验证 token 续期
# 看 AM 日志：
# Renewer: yarn ... successfully renewed
```

### 12.3 场景：HiveServer2 启动失败

```bash
# 1分钟：进程 + 日志
systemctl status hive-server2
tail -50 /var/log/hive/hiveserver2.log | grep -iE "kerberos|gss|sasl|login"

# 2分钟：keytab 检查
sudo -u hive klist -kt /etc/security/keytabs/hive.service.keytab
ls -l /etc/security/keytabs/hive.service.keytab

# 3分钟：手动 kinit 验证
sudo -u hive kinit -kt /etc/security/keytabs/hive.service.keytab \
    hive/$(hostname -f)@REALM

# 4分钟：检查配置
grep "kerberos" /etc/hive/conf/hive-site.xml | head -10
hostname -f   # _HOST 替换是否正确

# 5分钟：根据上面发现修复
```

### 12.4 场景：跨域用户访问失败

```bash
# 1分钟：确认是跨域
klist | grep "Default principal"
# 如 alice@CORP.COM 但访问 HADOOP.COM 资源 → 跨域

# 2分钟：krb5.conf capaths
grep -A10 capaths /etc/krb5.conf

# 3分钟：跨域 trace
KRB5_TRACE=/tmp/cr.log hdfs dfs -ls hdfs://nn.hadoop.com:8020/
grep -E "TGS-REQ|krbtgt" /tmp/cr.log
# 看是否走了 krbtgt/HADOOP.COM@CORP.COM

# 4分钟：auth_to_local 映射
grep -A20 "auth_to_local" /etc/hadoop/conf/core-site.xml

# 5分钟：根据上面找到根因
```

---

## 十三、5 分钟定位训练

### 13.1 训练日历

| 周 | 训练内容 |
|---|---------|
| W1 | 抽 10 个错误码，每个用 5 分钟法定位 |
| W2 | 同事故意制造故障，互相猜根因 |
| W3 | 真实生产工单：每个工单写「5 分钟定位报告」 |
| W4 | 测试环境注入故障 + 录屏定位过程 |

### 13.2 评分卡（自评）

| 项 | 满分 | 标准 |
|---|------|-----|
| 是否 10 秒判断 Kerberos 类 | 10 | 关键字命中 |
| 是否 30 秒分类 | 10 | 6 大类对号入座 |
| 是否走对一键诊断脚本 | 20 | 选了对应的 |
| 是否定位到根因 | 30 | 命中 ≤ 5 分钟 |
| 修复是否一次成功 | 20 | 不二次返工 |
| 留痕是否完整 | 10 | trace + 命令 |

> ≥ 80 分：合格 SRE  
> ≥ 95 分：高级 SRE

---

## 十四、Cheat Sheet（贴墙）

```
┌──────────────────────────────────────────────────────────────────┐
│ Kerberos 5 分钟定位 Cheat Sheet                                   │
├──────────────────────────────────────────────────────────────────┤
│ 1. 是 Kerberos? → grep -iE "krb|gss|sasl|kdc"                    │
│ 2. 分类 → A时间/B网络/C密钥/D Principal/E Login/F 配置             │
│ 3. 一键脚本 → kerb_5min_diag.sh                                   │
│ 4. 终极武器 → KRB5_TRACE + sun.security.krb5.debug=true           │
├──────────────────────────────────────────────────────────────────┤
│ 错误码 -> 根因                                                     │
│ -1765328359 → 时钟           chronyc -a makestep                  │
│ -1765328351 → KDC 不可达      nc -zv kdc 88                       │
│ -1765328230 → KVNO 不一致    ktadd -norandkey                    │
│ -1765328353 → SPN 不存在     hostname -f + listprincs            │
│ -1765328377 → 跨域 krbtgt    双方重置同密码                       │
│ -1765328324 → TGT 过期       kinit                                │
│ GSS No valid creds → kinit + KRB5CCNAME                          │
│ token expired → spark-submit --keytab                             │
└──────────────────────────────────────────────────────────────────┘
```

---

*Eric · 大数据 SRE AI 专家团队 · 5 分钟定位 · v1.0*
