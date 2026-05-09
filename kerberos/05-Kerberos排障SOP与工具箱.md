# Kerberos 排障 SOP + 工具箱

> 大数据 SRE 必修课 · Eric · 2026-05-09  
> 排障一站式手册：从故障接报 → 工具采集 → 决策树定位 → 修复验证

---

## 一、黄金排障六步法（Kerberos 专用版）

```
                ┌──────────────────┐
                │ 0. 接报：现象描述 │   收集错误堆栈/时间/范围/影响
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │ 1. 复现：能复现吗 │   命令行能复现就直接看 trace
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │ 2. 探针：采集事实 │   klist/kvno/KRB5_TRACE/日志/JVM debug
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │ 3. 决策树定位     │   按错误码走标准决策树
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │ 4. 修复：最小变更 │   keytab/principal/krb5.conf/重启
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │ 5. 验证：观察窗口 │   15/30/60min 看是否复发
                └────────┬─────────┘
                         │
                ┌────────▼─────────┐
                │ 6. 沉淀：知识晶体 │   案例进 case 库 + 巡检规则更新
                └──────────────────┘
```

---

## 二、决策树（排障核心，背下来）

```
Kerberos 故障
│
├─ ① 客户端能 kinit 吗？
│   ├─ NO  → 走「客户端认证树」
│   │   ├─ Clock skew → A1 时钟
│   │   ├─ Client not found → B1 principal 不存在
│   │   ├─ Pre-auth failed → B5 密码/keytab/KVNO
│   │   ├─ Illegal key size → D1 JCE
│   │   ├─ Cannot find KDC → C1/I 配置/网络
│   │   └─ 其他 → KRB5_TRACE 看 trace
│   │
│   └─ YES → 进 ②
│
├─ ② 客户端能 kvno <SPN> 吗？
│   ├─ NO → 走「服务 SPN 树」
│   │   ├─ Server not found → B2 SPN 不存在/FQDN 错
│   │   ├─ Cannot find KDC → 网络
│   │   └─ Decrypt failed → KVNO 不一致
│   │
│   └─ YES → 进 ③
│
├─ ③ 客户端能访问服务吗？
│   ├─ NO + GSSException No valid credentials → E1
│   │   ├─ KRB5CCNAME 不一致
│   │   ├─ 没传 jaas.conf
│   │   └─ JVM 没启用 Kerberos
│   ├─ NO + Cannot authenticate via [KERBEROS] → E3
│   │   └─ 客户端 core-site.xml 没开 kerberos
│   ├─ NO + Token expired → G1
│   │   └─ 长任务没 --keytab
│   └─ YES → 排查上层应用问题（不在 Kerberos 范畴）
│
└─ ④ 跨域问题？
    ├─ Decrypt integrity check failed → F2 krbtgt 密码
    ├─ No path → F1 capaths 缺失
    └─ Auth OK 但鉴权失败 → F3 auth_to_local
```

---

## 三、工具箱（每个 SRE 必装）

### 3.1 klist / kvno / kinit

最基础三件套，用法见实战手册 §3。**排障第一步永远是这三个命令**。

### 3.2 KRB5_TRACE（最重要）

```bash
# 终端实时
export KRB5_TRACE=/dev/stderr
kinit -V alice

# 写文件后续分析
KRB5_TRACE=/tmp/krb.log kinit -V alice
cat /tmp/krb.log
```

**trace 中关键字**：

| 字符串 | 含义 |
|-------|------|
| `Sending initial UDP request to dgram` | UDP 发送 |
| `Sending TCP request to stream` | TCP 发送 |
| `Sending request (X bytes) to REALM` | 实际请求 |
| `Received error from KDC: -1765328359/Clock skew too great` | 错误码 |
| `Decoded AS-REP` | 成功收到 AS_REP |
| `tkt_creds: requesting ticket for ...` | 请求 ST |
| `crypto: aes256-cts/16` | 实际用的 enctype |

### 3.3 sun.security.krb5.debug=true（Java 客户端）

```bash
# 一次性
HADOOP_OPTS="-Dsun.security.krb5.debug=true -Dsun.security.spnego.debug=true" hdfs dfs -ls /

# 服务端永久
# hadoop-env.sh
export HADOOP_OPTS="-Dsun.security.krb5.debug=true $HADOOP_OPTS"
export HADOOP_NAMENODE_OPTS="-Dsun.security.krb5.debug=true $HADOOP_NAMENODE_OPTS"
```

### 3.4 tcpdump / wireshark 抓包（高级）

```bash
# 抓 KDC 流量（端口 88）
tcpdump -i any -w /tmp/krb.pcap port 88 or port 749

# 抓特定主机
tcpdump -i any -w /tmp/krb.pcap host kdc01.bigdata.com

# Wireshark 解析（需要 KDC master key 或对话密钥才能解密）
# 但能看到 AS_REQ/AS_REP/TGS_REQ/TGS_REP/AP_REQ 包结构
```

### 3.5 jstack（Java 进程 hang 分析）

```bash
# Hadoop 服务 hang 时
jstack <pid> > /tmp/jstack.out
grep -A20 "Krb5LoginModule" /tmp/jstack.out

# 重点看是否卡在
# - sun.security.krb5.KdcComm
# - org.apache.hadoop.security.UserGroupInformation
```

### 3.6 strace（系统调用）

```bash
# 看 kinit 的 syscall（找配置文件加载顺序、网络连接顺序）
strace -e trace=open,connect,sendto,recvfrom -o /tmp/kinit.strace kinit alice
```

### 3.7 KDC 端日志

```bash
# 主日志
tail -f /var/log/krb5kdc.log

# 关键格式
# Jan 15 10:23:45 kdc01 krb5kdc[1234]: AS_REQ (8 etypes ...) 10.0.0.5: ISSUE: authtime 1234567890, etypes {18}, alice@BIGDATA.COM for krbtgt/BIGDATA.COM@BIGDATA.COM
# Jan 15 10:24:12 kdc01 krb5kdc[1234]: TGS_REQ ... ISSUE ... hdfs/nn01.bigdata.com@BIGDATA.COM

# 失败的会记录 NEEDED_PREAUTH / FAILED_PREAUTH / UNKNOWN_SERVER 等
grep -E "FAILED|UNKNOWN" /var/log/krb5kdc.log
```

### 3.8 检查脚本：一键诊断

```bash
#!/usr/bin/env bash
# kerberos-diag.sh — 一键 Kerberos 诊断
# Usage: bash kerberos-diag.sh <principal> [keytab]

PRINCIPAL="${1:?usage: $0 <principal> [keytab]}"
KEYTAB="${2:-}"
REALM=$(echo "$PRINCIPAL" | awk -F@ '{print $2}')

echo "=== 1. 时钟检查 ==="
date
ssh -o ConnectTimeout=2 ${REALM,,} date 2>/dev/null || echo "无法连接 KDC 测试时钟"

echo ""
echo "=== 2. krb5.conf 关键字 ==="
grep -E "default_realm|rdns|udp_preference|forwardable|enctypes" /etc/krb5.conf

echo ""
echo "=== 3. KDC 连通性 ==="
KDC=$(awk '/^\s*kdc\s*=/{print $3; exit}' /etc/krb5.conf)
nc -zv -w2 ${KDC%:*} 88

echo ""
echo "=== 4. 当前 ccache ==="
echo "KRB5CCNAME=$KRB5CCNAME"
klist 2>/dev/null || echo "无 ccache"

echo ""
echo "=== 5. KRB5_TRACE 测试 kinit ==="
TMP=$(mktemp)
if [[ -n "$KEYTAB" ]]; then
    KRB5_TRACE=$TMP kinit -V -kt "$KEYTAB" "$PRINCIPAL" 2>&1
    [[ $? -eq 0 ]] && echo "✅ kinit 成功"
else
    echo "需要密码 kinit（手动）"
fi
echo "--- trace 摘要 ---"
grep -E "Received|Sending|AS-REP|TGS-REP|error" $TMP | head -20

echo ""
echo "=== 6. keytab 检查 ==="
if [[ -n "$KEYTAB" ]]; then
    ls -l "$KEYTAB"
    klist -kt "$KEYTAB"
fi

echo ""
echo "=== 7. KDC 上 KVNO ==="
kvno "$PRINCIPAL" 2>&1

echo ""
echo "=== 完成 ==="
```

---

## 四、典型场景排障 SOP

### 场景 A：HDFS 服务启动失败

```bash
# 1. 看日志关键字
tail -100 /var/log/hadoop-hdfs/hadoop-hdfs-namenode-*.log | grep -iE "kerberos|gss|sasl|login"

# 2. 验 keytab
ls -l /etc/security/keytabs/hdfs.service.keytab
sudo -u hdfs klist -kt /etc/security/keytabs/hdfs.service.keytab

# 3. 手动 kinit 验证
sudo -u hdfs kinit -kt /etc/security/keytabs/hdfs.service.keytab hdfs/$(hostname -f)@BIGDATA.COM
sudo -u hdfs klist

# 4. 验配置 _HOST 解析
hostname -f   # 必须是 FQDN

# 5. KDC 上 SPN 是否存在
kadmin.local -q "getprinc hdfs/$(hostname -f)"

# 6. 重启服务
systemctl restart hadoop-hdfs-namenode
```

### 场景 B：用户提交 Spark 任务报 GSSException

```bash
# 1. 用户当前票据
sudo -u $USER klist

# 2. 用户的 keytab 是否能 kinit
sudo -u $USER kinit -kt $USER.keytab $USER@BIGDATA.COM

# 3. proxyUser 配置
grep -A2 "hadoop.proxyuser" /etc/hadoop/conf/core-site.xml

# 4. submit 命令
spark-submit \
  --master yarn --deploy-mode cluster \
  --principal $USER@BIGDATA.COM --keytab $USER.keytab \
  --conf spark.kerberos.access.hadoopFileSystems=hdfs://nn.bigdata.com:8020 \
  ...
```

### 场景 C：Beeline 连不上 HS2

```bash
# 1. 客户端是否 kinit
klist

# 2. URL 中 principal 是否正确
beeline -u "jdbc:hive2://hs2.bigdata.com:10000/default;principal=hive/hs2.bigdata.com@BIGDATA.COM"

# 3. HS2 服务端是否开了 KERBEROS
grep "hive.server2.authentication" /etc/hive/conf/hive-site.xml

# 4. 网络
nc -zv hs2.bigdata.com 10000

# 5. 调试输出
beeline -d com.cloudera.hive.jdbc4.HS2Driver \
  -u "jdbc:hive2://...;principal=...;LogLevel=6;LogPath=/tmp"
```

### 场景 D：Web UI 401（NN/RM Web 打不开）

```bash
# 1. 客户端票据
klist

# 2. 浏览器配置（curl 测试）
curl --negotiate -u : http://nn01.bigdata.com:9870/jmx
# 200 → 服务端 OK，浏览器配置问题
# 401 → 服务端配置问题

# 3. 服务端 spnego 配置
grep "spnego" /etc/hadoop/conf/hdfs-site.xml

# 4. SPN HTTP/_HOST 是否存在
kvno HTTP/nn01.bigdata.com@BIGDATA.COM
```

---

## 五、应急预案（重大故障）

### 5.1 KDC 主备全挂

**影响**：全集群无法新认证（已认证服务还能跑到票据过期）

**处置**：
1. 立即拉群通报，给业务"票据过期前的窗口期"
2. 启动应急 KDC（克隆备份）
3. 修改 krb5.conf 指向应急 KDC
4. 滚动重启所有服务
5. **教训**：必须主备 + 异地备份 + 自动化恢复演练

### 5.2 大量 keytab 失效（KVNO 错乱）

**影响**：批量服务挂

**处置**：
1. 锁定 KDC 数据库（防止再被改）
2. 从备份恢复 keytab，或用 `ktadd -norandkey` 重新导出
3. 批量分发 keytab
4. 滚动重启
5. **教训**：禁止在生产 KDC 上执行 `cpw` / `ktadd`（不带 -norandkey），写入运维制度

### 5.3 跨域信任突然失效

**影响**：依赖 AD 的所有用户登录失败

**处置**：
1. 与 AD 管理员联系，确认是否 AD 侧改了密码 / 禁用了信任
2. 重新建立信任：双方 KDC 重置 `krbtgt/B@A`
3. 重新分发新 keytab（如果有缓存的话）

### 5.4 长任务集体挂（token 过期）

**影响**：所有 7 天前提交的 Spark/Flink 任务挂

**处置**：
1. 业务方重新提交，**带 --keytab**
2. 长期：在 spark-submit 包装脚本里强制要求 --keytab + --principal

---

## 六、巡检规则（建议加入监控）

| 检查项 | 频率 | 阈值 | 工具 |
|-------|------|------|------|
| 时钟偏差 | 1min | <500ms | chrony tracking |
| KDC 端口存活 | 1min | TCP/UDP 88 | nc/blackbox-exporter |
| keytab 文件权限 | 1day | 400 | shell 脚本 |
| keytab KVNO 一致性 | 1day | klist -kt vs kvno | shell 脚本 |
| KDC 数据库大小 | 1hr | 持续增长 | du |
| 备 KDC 同步延迟 | 5min | <10min | ls -l principal |
| 集群 token 即将过期数 | 1hr | <100 | NN JMX |
| Kerberos 错误日志频率 | 5min | <10/min | log-exporter |

### 6.1 Prometheus 关键指标

```yaml
# blackbox-exporter — KDC TCP 88 探活
- job_name: 'kerberos-kdc'
  metrics_path: /probe
  params:
    module: [tcp_connect]
  static_configs:
    - targets: ['kdc01.bigdata.com:88', 'kdc02.bigdata.com:88']
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - target_label: __address__
      replacement: blackbox-exporter:9115

# Hadoop JMX — token 数量
hadoop_namenode_dt_count{type="active"}
hadoop_namenode_dt_count{type="expired_soon"}
```

### 6.2 告警规则

```yaml
groups:
- name: kerberos
  rules:
  - alert: KDCDown
    expr: probe_success{job="kerberos-kdc"} == 0
    for: 1m
    labels: { severity: critical }
    annotations: { summary: "KDC {{$labels.instance}} 不可达" }

  - alert: ClockSkew
    expr: abs(node_timex_offset_seconds) > 30
    for: 5m
    labels: { severity: warning }
    annotations: { summary: "{{$labels.instance}} 时钟偏差 > 30s" }

  - alert: TokenExpiringSoon
    expr: hadoop_namenode_dt_count{type="expired_soon"} > 100
    for: 10m
    labels: { severity: warning }
    annotations: { summary: "HDFS 即将过期 token 超过 100" }
```

---

## 七、Kerberos 健康度评分卡（团队建设用）

| 维度 | 满分 | 评分标准 |
|------|------|---------|
| KDC 高可用 | 10 | 主备 + 自动切换 + 异地备份 |
| 时钟同步 | 10 | 全集群 < 500ms 偏差 |
| krb5.conf 规范 | 10 | rdns=false, forwardable=true, udp_preference=1 |
| Keytab 管理 | 15 | 集中存放 + 权限 400 + 巡检 + 半年轮换 |
| Principal 命名 | 10 | 服务/_HOST + 命名规范 + auth_to_local |
| 长任务 Token | 10 | --keytab 强制 + 续期监控 |
| 跨域信任 | 10 | 双向信任 + krbtgt 同步 + capaths |
| 监控告警 | 15 | KDC + 时钟 + token + 错误日志 |
| 排障工具链 | 5 | KRB5_TRACE 启用 + jaas debug 可开 |
| 知识沉淀 | 5 | 案例库 + SOP 文档 + 演练记录 |
| **总分** | **100** | |

> 60 分：能用；80 分：可靠；95+ 分：精通

---

## 八、附录：英文报错速查（最常 Google）

| 报错 | 中文翻译 | 立即排查 |
|------|---------|---------|
| Clock skew too great | 时钟偏差太大 | NTP |
| Cannot find KDC for realm | 找不到 KDC | krb5.conf / DNS |
| Server not found in Kerberos database | KDC 上没这个 SPN | listprincs |
| Client not found in Kerberos database | KDC 上没这个用户 | listprincs |
| Pre-authentication information was invalid | 预认证失败 | 密码/keytab |
| Specified version of key is not available | KVNO 不一致 | klist -kt vs kvno |
| Key version number for principal does not match | 同上 | 同上 |
| Decrypt integrity check failed | 解密失败 | krbtgt 密码（跨域） |
| Cannot contact any KDC | 网络不通 | nc 88 |
| KDC has no support for encryption type | enctype 不支持 | krb5.conf permitted_enctypes |
| Illegal key size | JCE 限制 | java.security crypto.policy |
| No valid credentials provided | 没票/票过期 | klist + kinit |
| Failed to find any Kerberos tgt | 同上 | 同上 |
| Defective token detected | 票据损坏 | 时钟 + replay cache |
| Ticket expired | 票过期 | --keytab |
| Receive timed out | KDC 不响应 | 网络/UDP→TCP |

---

*Eric · 大数据 SRE AI 专家团队 · 知识晶体化 v1.0*
