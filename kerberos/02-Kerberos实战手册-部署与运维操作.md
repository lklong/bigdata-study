# Kerberos 实战手册 — 部署 / Principal / Keytab / 客户端

> 大数据 SRE 必修课 · Eric · 2026-05-09  
> 配套：原理篇 → 实践篇（本文）→ 组件集成篇 → 问题库 → 排障 SOP

---

## 一、KDC 部署：从 0 到生产可用

### 1.1 环境规划（生产标准）

| 项 | 推荐 | 说明 |
|---|------|------|
| KDC 主机数 | **2 台**（主备） | 一主一从，通过 kpropd 同步 |
| OS | RHEL 7+/8+/Rocky 8/9 | CentOS 7 已 EOL |
| 端口 | TCP/UDP 88 (KDC) + TCP 749 (kadmin) + TCP 754 (kpropd) | 防火墙必开 |
| Realm | `BIGDATA.COM` | **全大写**，与公司域名一致或自定义 |
| 软件 | `krb5-server krb5-workstation krb5-libs` | RHEL 系发行版 |
| NTP | chrony 主从同步 | **时钟偏差 < 1 分钟** |
| DNS | 正反解齐全 | 所有节点 FQDN 可解析 |

### 1.2 主 KDC 安装与初始化（kdc01）

```bash
# 1) 安装
yum install -y krb5-server krb5-workstation krb5-libs

# 2) 配置 /etc/krb5.conf（见原理篇 §九 模板）
cat > /etc/krb5.conf <<'EOF'
[logging]
    default = FILE:/var/log/krb5libs.log
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmind.log

[libdefaults]
    default_realm = BIGDATA.COM
    dns_lookup_realm = false
    dns_lookup_kdc = false
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
    rdns = false
    udp_preference_limit = 1
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    BIGDATA.COM = {
        kdc = kdc01.bigdata.com:88
        kdc = kdc02.bigdata.com:88
        admin_server = kdc01.bigdata.com:749
    }

[domain_realm]
    .bigdata.com = BIGDATA.COM
    bigdata.com  = BIGDATA.COM
EOF

# 3) 配置 /var/kerberos/krb5kdc/kdc.conf
cat > /var/kerberos/krb5kdc/kdc.conf <<'EOF'
[kdcdefaults]
    kdc_ports = 88
    kdc_tcp_ports = 88

[realms]
    BIGDATA.COM = {
        master_key_type = aes256-cts
        max_life = 24h
        max_renewable_life = 7d
        acl_file = /var/kerberos/krb5kdc/kadm5.acl
        dict_file = /usr/share/dict/words
        admin_keytab = /var/kerberos/krb5kdc/kadm5.keytab
        supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal
        default_principal_flags = +preauth
    }
EOF

# 4) 配置 ACL
cat > /var/kerberos/krb5kdc/kadm5.acl <<'EOF'
*/admin@BIGDATA.COM    *
EOF

# 5) 创建 KDC 数据库（会问你设主密钥，记牢！）
kdb5_util create -s -r BIGDATA.COM
# Master Password: 设置一个强密码（生产存到密码保险箱）

# 6) 启动并开机自启
systemctl enable --now krb5kdc kadmin

# 7) 创建 admin principal
kadmin.local -q "addprinc admin/admin"

# 8) 验证
kinit admin/admin
klist
```

### 1.3 主备同步（kdc02）

```bash
# 在主 KDC（kdc01）上：
kadmin.local -q "addprinc -randkey host/kdc01.bigdata.com"
kadmin.local -q "addprinc -randkey host/kdc02.bigdata.com"
kadmin.local -q "ktadd host/kdc01.bigdata.com"
kadmin.local -q "ktadd host/kdc02.bigdata.com"

# 配置 /var/kerberos/krb5kdc/kpropd.acl（主从都要有）
cat > /var/kerberos/krb5kdc/kpropd.acl <<'EOF'
host/kdc01.bigdata.com@BIGDATA.COM
host/kdc02.bigdata.com@BIGDATA.COM
EOF

# 备 KDC（kdc02）：
yum install -y krb5-server krb5-workstation
# 复制 krb5.conf, kdc.conf, .k5.BIGDATA.COM 到 kdc02
scp kdc01:/etc/krb5.conf /etc/
scp kdc01:/var/kerberos/krb5kdc/{kdc.conf,kadm5.acl,kpropd.acl,.k5.BIGDATA.COM} /var/kerberos/krb5kdc/

systemctl enable --now kpropd
systemctl enable --now krb5kdc

# 主 KDC 上每 5 分钟同步一次（crontab）
*/5 * * * * /usr/sbin/kdb5_util dump /var/kerberos/krb5kdc/slave_datatrans && /usr/sbin/kprop -f /var/kerberos/krb5kdc/slave_datatrans kdc02.bigdata.com
```

### 1.4 验证 KDC 健康度

```bash
# 端口
ss -lntup | grep -E ':88|:749'

# 认证测试
kinit admin/admin
klist

# KDC 日志（重点看）
tail -f /var/log/krb5kdc.log

# 备 KDC 同步检查
ls -lh /var/kerberos/krb5kdc/principal*
# kdc01 和 kdc02 的 principal 文件 size 应基本相同
```

---

## 二、kadmin / kadmin.local 操作大全

### 2.1 两种登录模式

| 命令 | 适用 | 区别 |
|------|------|------|
| `kadmin.local` | 仅 KDC 本机 | 直接读数据库，**不需要密码** |
| `kadmin -p user/admin` | 任意主机 | 走网络，需要密码或 keytab |

### 2.2 Principal 管理

```bash
# === 增 ===
# 用户型（带密码）
kadmin.local -q "addprinc alice"
# 用户型（指定密码）
kadmin.local -q "addprinc -pw 'P@ssw0rd!' alice"
# 服务型（随机密码，仅 keytab 用）
kadmin.local -q "addprinc -randkey hdfs/nn01.bigdata.com"
# 永不过期密码
kadmin.local -q "addprinc -pwexpire never -randkey spark/spark.bigdata.com"
# 指定 enctypes
kadmin.local -q "addprinc -e aes256-cts-hmac-sha1-96:normal,aes128-cts-hmac-sha1-96:normal -randkey hive/hs2.bigdata.com"

# === 查 ===
kadmin.local -q "listprincs"                              # 列全部
kadmin.local -q "listprincs '*hdfs*'"                     # 模糊查
kadmin.local -q "getprinc alice"                          # 详情（含 KVNO/enctypes/过期时间）
kadmin.local -q "getprinc hdfs/nn01.bigdata.com"

# === 改 ===
kadmin.local -q "modprinc -maxlife '1 day' alice"         # 改 max_life
kadmin.local -q "modprinc -maxrenewlife '7 days' alice"   # 改 renew_life
kadmin.local -q "modprinc +requires_preauth alice"        # 强制预认证
kadmin.local -q "modprinc -pwexpire '2027-01-01' alice"   # 改密码过期
kadmin.local -q "cpw -randkey hdfs/nn01.bigdata.com"      # 改密码（KVNO+1）

# === 删 ===
kadmin.local -q "delprinc alice"
kadmin.local -q "delprinc -force hdfs/nn01.bigdata.com"   # 跳过确认
```

### 2.3 Keytab 管理（核心运维操作）

```bash
# === 创建 keytab ===
kadmin.local -q "ktadd -k /etc/security/keytabs/hdfs.keytab hdfs/nn01.bigdata.com"

# 多个 principal 写到一个 keytab
kadmin.local -q "ktadd -k /etc/security/keytabs/hdfs.keytab \
  hdfs/nn01.bigdata.com \
  HTTP/nn01.bigdata.com"

# 不改密码导出（KVNO 不变，老 keytab 仍然可用）
kadmin.local -q "ktadd -norandkey -k /etc/security/keytabs/hdfs.keytab hdfs/nn01.bigdata.com"

# === 查看 keytab ===
klist -kt /etc/security/keytabs/hdfs.keytab        # 看条目
klist -ket /etc/security/keytabs/hdfs.keytab       # 加上 enctype 详情

# === 验证 keytab 可用性 ===
kinit -kt /etc/security/keytabs/hdfs.keytab hdfs/nn01.bigdata.com@BIGDATA.COM
klist
kdestroy

# === 删除 keytab 中某条 ===
ktutil
ktutil:  read_kt /etc/security/keytabs/hdfs.keytab
ktutil:  list
ktutil:  delete_entry 1
ktutil:  write_kt /etc/security/keytabs/hdfs.keytab
ktutil:  quit

# === 合并 keytab ===
ktutil
ktutil:  read_kt hdfs.keytab
ktutil:  read_kt http.keytab
ktutil:  write_kt merged.keytab
ktutil:  quit

# === 验证 keytab KVNO 与 KDC 一致 ===
# keytab 里
klist -kt /etc/security/keytabs/hdfs.keytab | awk 'NR>3 {print $1, $4}' | sort -u

# KDC 里
kadmin.local -q "getprinc hdfs/nn01.bigdata.com" | grep "Key: vno"

# 不一致 → 重新 ktadd（不要 cpw 又只导出！）
```

### 2.4 Keytab 安全规范（生产铁律）

| 规则 | 命令 | 雷点 |
|------|------|------|
| 文件权限 400 | `chmod 400 *.keytab` | 否则被普通用户读走 = 密码泄漏 |
| 属主对应进程用户 | `chown hdfs:hadoop hdfs.keytab` | hdfs 进程读不到 → 启动失败 |
| 集中存放 | `/etc/security/keytabs/` | 不要散在 home 目录 |
| 命名规范 | `<service>.keytab` 或 `<service>.service.keytab` | spnego.service.keytab 单独管理 |
| 定期轮换 | 半年 / 一年 `cpw -randkey` 一次 | 长期不换有泄漏风险 |
| 备份加密 | 备份必须加密 | 备份盘被偷 = 集群沦陷 |

---

## 三、客户端命令完整手册

### 3.1 kinit — 获取票据

```bash
# 用密码登录
kinit alice
kinit alice@BIGDATA.COM

# 用 keytab 登录（生产服务的标准方式）
kinit -kt /etc/security/keytabs/hdfs.keytab hdfs/nn01.bigdata.com@BIGDATA.COM

# 详细输出（排障必备）
kinit -V -kt /etc/security/keytabs/hdfs.keytab hdfs/nn01.bigdata.com@BIGDATA.COM
# Using existing cache: FILE:/tmp/krb5cc_0
# Using principal: hdfs/nn01.bigdata.com@BIGDATA.COM
# Using keytab: /etc/security/keytabs/hdfs.keytab
# Authenticated to Kerberos v5

# 续期
kinit -R                                # 用现有票据续期
kinit -r 7d alice                       # 显式指定可续期至 7 天

# 指定 ccache 路径
kinit -c /tmp/krb5cc_alice_special alice

# 指定有效期
kinit -l 12h alice

# 强制 forwardable
kinit -f alice

# 全套排障日志
KRB5_TRACE=/tmp/krb_trace.log kinit -V alice
cat /tmp/krb_trace.log
```

### 3.2 klist — 查看票据

```bash
klist                          # 看默认 ccache
klist -e                       # 加 enctype
klist -f                       # 加 flags
klist -A                       # 看所有 ccache（KEYRING/DIR 类型可能多个）
klist -k /path/to/keytab       # 看 keytab 内容
klist -kt /path/to/keytab      # 同上但带时间戳
klist -ket /path/to/keytab     # 同上加 enctype
klist -c FILE:/tmp/krb5cc_xxx  # 指定 ccache
```

### 3.3 kdestroy — 销毁票据

```bash
kdestroy                       # 默认 ccache
kdestroy -A                    # 全部
kdestroy -c FILE:/tmp/xxx      # 指定
```

### 3.4 kvno — 查询服务 SPN 的 KVNO

```bash
# 查询某 SPN 当前 KVNO
kvno hdfs/nn01.bigdata.com@BIGDATA.COM
# hdfs/nn01.bigdata.com@BIGDATA.COM: kvno = 5

# 用途：与 keytab 的 KVNO 比对，排查认证失败
klist -kt /etc/security/keytabs/hdfs.keytab | grep nn01
```

### 3.5 kpasswd — 改密码

```bash
kpasswd                        # 改自己（要先 kinit）
kpasswd alice                  # 改别人（要 admin 权限）
```

### 3.6 KRB5_TRACE — 排障神器

```bash
# 任何 Kerberos 操作前打开 trace
export KRB5_TRACE=/dev/stderr
# 或写文件
export KRB5_TRACE=/tmp/krb.log

# trace 中的关键行
# [12345] sending TGS-REQ for hdfs/nn01.bigdata.com@BIGDATA.COM
# [12345] received TGS-REP
# [12345] AS key obtained for encrypted timestamp
# [12345] Decoded AS-REP
```

---

## 四、Java 客户端 Kerberos 调试

### 4.1 -Dsun.security.krb5.debug=true

```bash
# Hadoop 命令行加调试
export HADOOP_OPTS="-Dsun.security.krb5.debug=true -Dsun.security.spnego.debug=true"
hdfs dfs -ls /

# 输出关键行
# Java config name: /etc/krb5.conf
# Loaded from Java config
# >>> KdcAccessibility: reset
# default etypes for default_tkt_enctypes: 18 17 16 23.
# >>> KrbAsReq creating message
# >>>KrbKdcReq send: kdc=kdc01.bigdata.com TCP:88
# >>>KrbKdcReq send: #bytes read=312
# >>>KdcAccessibility: remove kdc01.bigdata.com
# >>> KrbAsRep cons in KrbAsReq.getReply
# Found ticket for hdfs/nn01.bigdata.com@BIGDATA.COM to go to krbtgt/...
```

### 4.2 jaas.conf 模板

```ini
# /etc/security/jaas.conf

Client {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    keyTab="/etc/security/keytabs/hdfs.keytab"
    principal="hdfs/nn01.bigdata.com@BIGDATA.COM"
    storeKey=true
    useTicketCache=false
    debug=true;
};

Server {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    keyTab="/etc/security/keytabs/hdfs.keytab"
    principal="hdfs/_HOST@BIGDATA.COM"
    storeKey=true
    useTicketCache=false
    debug=true;
};
```

启动 Java 应用时：
```bash
java -Djava.security.auth.login.config=/etc/security/jaas.conf \
     -Djava.security.krb5.conf=/etc/krb5.conf \
     -Dsun.security.krb5.debug=true \
     YourApp
```

### 4.3 UGI 调试

```java
// 代码层
UserGroupInformation.setConfiguration(conf);
UserGroupInformation ugi = UserGroupInformation.loginUserFromKeytabAndReturnUGI(
    "hdfs/nn01.bigdata.com@BIGDATA.COM",
    "/etc/security/keytabs/hdfs.keytab"
);
ugi.doAs((PrivilegedExceptionAction<Void>) () -> {
    // 在这里执行业务
    FileSystem fs = FileSystem.get(conf);
    fs.listStatus(new Path("/"));
    return null;
});

// 强制重新登录
ugi.reloginFromKeytab();
```

---

## 五、生产环境批量初始化脚本（实战）

### 5.1 一键创建大数据集群所有 principal

```bash
#!/usr/bin/env bash
# init-cluster-principals.sh
# Usage: bash init-cluster-principals.sh <hosts.txt>
# hosts.txt 内容：每行一个 FQDN

set -euo pipefail
REALM="BIGDATA.COM"
KEYTAB_DIR="/etc/security/keytabs"
mkdir -p "$KEYTAB_DIR"

HOSTS=$(cat "${1:-hosts.txt}")

# 服务列表 → 每个节点都要创建
declare -A SERVICES=(
    [hdfs]="nn dn jn"
    [yarn]="rm nm"
    [mapred]="jhs"
    [hive]="hs2 metastore"
    [HTTP]="all"          # SPNEGO，每个节点都要
    [zookeeper]="zk"
    [hbase]="master rs"
    [spark]="spark"
    [kyuubi]="kyuubi"
    [ranger]="admin"
)

for host in $HOSTS; do
    for svc in "${!SERVICES[@]}"; do
        principal="${svc}/${host}@${REALM}"
        keytab="${KEYTAB_DIR}/${svc}.${host}.keytab"
        echo ">>> Creating $principal -> $keytab"
        kadmin.local -q "addprinc -randkey $principal" || true
        kadmin.local -q "ktadd -k $keytab -norandkey $principal"
        chmod 400 "$keytab"
    done
done

echo "All principals & keytabs created."
echo "Now distribute keytabs to corresponding hosts and chown to service user."
```

### 5.2 keytab 分发与权限脚本

```bash
#!/usr/bin/env bash
# distribute-keytabs.sh
# 分发 keytab 到每个节点的 /etc/security/keytabs/

set -euo pipefail

declare -A SVC_USER=(
    [hdfs]="hdfs:hadoop"
    [yarn]="yarn:hadoop"
    [mapred]="mapred:hadoop"
    [hive]="hive:hive"
    [HTTP]="root:hadoop"
    [zookeeper]="zookeeper:hadoop"
    [hbase]="hbase:hbase"
    [spark]="spark:spark"
    [kyuubi]="kyuubi:hadoop"
    [ranger]="ranger:ranger"
)

for host in $(cat hosts.txt); do
    ssh "$host" "mkdir -p /etc/security/keytabs && chmod 755 /etc/security/keytabs"
    for ktf in /etc/security/keytabs/*.${host}.keytab; do
        svc=$(basename "$ktf" | cut -d. -f1)
        owner="${SVC_USER[$svc]:-root:root}"
        scp "$ktf" "${host}:/etc/security/keytabs/${svc}.service.keytab"
        ssh "$host" "chown $owner /etc/security/keytabs/${svc}.service.keytab && chmod 400 /etc/security/keytabs/${svc}.service.keytab"
    done
done
```

---

## 六、Keytab 健康度巡检脚本（定时任务）

```bash
#!/usr/bin/env bash
# kerberos-health-check.sh
# 巡检：keytab 可用性 + KVNO 一致性 + 票据过期检查

REALM="BIGDATA.COM"
KEYTAB_DIR="/etc/security/keytabs"
ALERT=""

for ktf in $KEYTAB_DIR/*.keytab; do
    # 1) 文件权限检查
    perm=$(stat -c %a "$ktf")
    [[ "$perm" != "400" ]] && ALERT+="❌ $ktf 权限 $perm 应为 400\n"

    # 2) 测试 kinit
    principal=$(klist -kt "$ktf" | awk 'NR==4 {print $4}')
    if ! kinit -kt "$ktf" "$principal" 2>/dev/null; then
        ALERT+="❌ $ktf kinit 失败 ($principal)\n"
        continue
    fi

    # 3) KVNO 一致性
    keytab_kvno=$(klist -kt "$ktf" | awk 'NR==4 {print $1}')
    kdc_kvno=$(kvno "$principal" 2>/dev/null | awk '{print $NF}')
    if [[ "$keytab_kvno" != "$kdc_kvno" ]]; then
        ALERT+="❌ $ktf KVNO 不一致 keytab=$keytab_kvno KDC=$kdc_kvno\n"
    fi

    kdestroy
done

if [[ -n "$ALERT" ]]; then
    echo -e "Kerberos Health Alert:\n$ALERT" | mail -s "[Kerberos] Health Check Failed" sre@bigdata.com
else
    echo "✅ All keytabs healthy"
fi
```

加 crontab：
```cron
0 */6 * * * /usr/local/bin/kerberos-health-check.sh
```

---

## 七、常用 ccache 类型（Linux 环境差异）

| ccache 类型 | 配置 | 特点 | 雷点 |
|------------|------|------|------|
| `FILE:/tmp/krb5cc_%{uid}` | 最经典 | 文件，跨进程共享 | 容器中默认 /tmp 隔离 |
| `KEYRING:persistent:%{uid}` | RHEL 7+ 默认 | 内核 keyring，安全 | 容器中失效 |
| `DIR:/path` | 多 ccache | 一个目录管多个票据 | 用得少 |
| `MEMORY:` | 内存 | JVM 进程内 | 重启即丢 |

容器化 / Docker / K8s 中**强烈建议改回 FILE 类型**：

```bash
# /etc/krb5.conf
[libdefaults]
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
```

---

## 八、自检清单

完成本章应能：

- [ ] 30 分钟内独立部署一套 MIT KDC（主+备）
- [ ] 使用 kadmin 完成 Principal 增删改查
- [ ] 创建、合并、修改、查看 keytab
- [ ] 写出 keytab 巡检脚本，捕获 KVNO 不一致
- [ ] 用 KRB5_TRACE 和 sun.security.krb5.debug=true 排障
- [ ] 解释 ccache 不同类型的差异和使用场景

> 全部 ✅ 后进入 Phase-4：大数据组件集成

---

*Eric · 大数据 SRE AI 专家团队 · 知识晶体化 v1.0*
