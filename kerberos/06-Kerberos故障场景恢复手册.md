# Kerberos 故障场景恢复手册

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> 10 大典型故障场景 × 端到端恢复 SOP × 影响评估 × 决策路径 × 复盘模板  
> 配套：[问题库 Top50](./04-Kerberos运维问题库Top50.md) + [排障 SOP](./05-Kerberos排障SOP与工具箱.md)

---

## 引言：故障 vs 问题，根本不同

| 维度 | 普通问题（问题库 Top50） | 故障场景（本文） |
|-----|------------------------|-----------------|
| 范围 | 单点 / 单服务 | **大面积影响** |
| 时长 | 几分钟 | 几十分钟到几小时 |
| 决策 | 自动 | **需要决策树+人工判断** |
| 操作 | 改个配置 | **多步骤+多角色协作** |
| 风险 | 低 | **高（误操作可能扩大故障）** |
| 验证 | 一次 | **分阶段+多窗口确认** |

> 故障恢复 = 在**信息不全 + 时间紧迫 + 决策可逆性差**的条件下做正确的事。不是技术问题，是工程问题。

---

## 故障恢复总原则（铁律）

### 0.1 救火五字诀

```
止损 → 隔离 → 诊断 → 恢复 → 复盘
 (1)    (2)    (3)    (4)    (5)
```

| # | 含义 | Kerberos 场景的体现 |
|---|------|--------------------|
| **止损** | 不让故障扩大 | 暂停业务提交、冻结配置变更、保留现场 |
| **隔离** | 把坏的隔离开 | 切流量、停问题节点、隔离 KDC |
| **诊断** | 摸清根因 | 看日志/抓包/对比配置 |
| **恢复** | 让服务可用 | keytab 重发、KDC 切主、服务重启 |
| **复盘** | 防止再发 | 改 SOP / 加监控 / 演练 |

### 0.2 故障期间禁忌

🚫 **禁止做的事**：

1. ❌ 慌乱中乱改 KDC 配置 / 删 principal / cpw（**永久放大故障**）
2. ❌ 全集群同时重启（**雪崩**，见后文 5.2）
3. ❌ 不留痕迹的紧急操作（事后无法复盘）
4. ❌ 单人闷头干（**必须双人复核**关键命令）
5. ❌ 不通报业务方（**信息差是更大故障源**）

✅ **必须做的事**：

1. ✅ 开应急群，每 5/10/15 分钟通报一次进展
2. ✅ 所有变更走 ChatOps（命令+输出全留痕）
3. ✅ 每个动作前问"这个能不能回滚？"
4. ✅ 关键操作 4 眼校验（reviewer 同时确认）
5. ✅ 留现场（日志/dump/状态快照）

### 0.3 影响评估矩阵

| 等级 | 标准 | 响应时长 | 通报范围 |
|-----|------|---------|---------|
| **P0** | KDC 全挂 / 核心业务全停 | <5min 响应，<30min 恢复 | CTO/全体 SRE/核心业务 |
| **P1** | 单 KDC 挂 / 单服务大面积失败 | <10min 响应，<1h 恢复 | SRE 主管/相关业务 |
| **P2** | 单节点 / 部分用户受影响 | <30min 响应，<4h 恢复 | SRE 团队 |
| **P3** | 巡检发现潜在问题 | 工作时间处理 | SRE 内部 |

---

## 场景一：KDC 主节点宕机（P0）

### 1.1 现象

```
- 监控告警：KDC 端口 88 不可达
- 用户反馈：kinit 卡住超时 / 报 "Cannot contact any KDC for realm"
- Hadoop 服务日志：大量 GSSException, Ticket expired
- 业务影响：现有票据未过期的服务还在跑，但新连接全失败
```

### 1.2 影响评估时间窗

```
T+0       KDC 挂                   ← 起点
T+0~10min  现有 TGT 还能换 ST       ← 灰度期，影响小
T+10min~24h 现有 TGT 仍有效，但无法 kinit ← 大量服务开始失败
T+24h     全部 TGT 过期              ← 全集群瘫痪
```

> **黄金窗口：30 分钟内必须恢复**，否则 24 小时后业务全停

### 1.3 恢复 SOP

#### Step 1：止损（0~5min）

```bash
# 1) 立即应急群通报
echo "P0: KDC kdc01.bigdata.com 不可达，开始恢复，请暂停一切配置变更"

# 2) 确认是真挂还是网络问题
# 从多个节点测试
for h in nn01 nn02 dn01 dn02; do
    ssh $h "nc -zv -w2 kdc01.bigdata.com 88"
done

# 3) 直接登录 KDC 主机
ssh kdc01.bigdata.com
systemctl status krb5kdc kadmin
journalctl -xeu krb5kdc -n 100
```

#### Step 2：隔离 + 诊断（5~10min）

**判断分支**：

##### A. 进程挂了，主机正常

```bash
# 看是不是 OOM / Coredump
dmesg | tail -50
ls -la /var/lib/systemd/coredump/

# 看磁盘
df -h /var/kerberos/
# /var/kerberos/krb5kdc/principal 数据库不能损坏

# 看数据库完整性
kdb5_util dump /tmp/test_dump.txt && echo "DB OK"
```

→ 数据库 OK，进 Step 3-A 直接拉起

##### B. 数据库损坏

```bash
ls -la /var/kerberos/krb5kdc/principal*
# 文件大小异常 / 时间戳错乱 → 损坏

# 尝试恢复
kdb5_util load /backup/krb5_dump_$(date -d yesterday +%Y%m%d).txt
```

→ 进 Step 3-B 从备份恢复

##### C. 主机硬件故障

```bash
# 网络/磁盘/主板，登录都进不去
ipmitool sel list           # IPMI 日志
```

→ 进 Step 3-C 切到备 KDC

#### Step 3-A：进程拉起（最常见，5min）

```bash
systemctl restart krb5kdc kadmin
systemctl status krb5kdc

# 立即验证
kinit admin/admin
klist

# 应急群通报：KDC 已恢复，开始观察 15 分钟
```

#### Step 3-B：数据库恢复（10~20min）

```bash
# 1) 停 KDC（防止脏写）
systemctl stop krb5kdc kadmin

# 2) 备份当前坏文件（保留现场）
mv /var/kerberos/krb5kdc/principal{,.broken_$(date +%s)}

# 3) 从最新备份恢复
ls -lh /backup/krb5_dump_*.txt | tail -3
kdb5_util load /backup/krb5_dump_LATEST.txt

# 4) 起 KDC
systemctl start krb5kdc kadmin

# 5) 验证（重点验证最新创建的 principal 是否存在）
kadmin.local -q "listprincs" | wc -l
kadmin.local -q "getprinc <最近创建的某个>"

# 6) 通报：可能丢失最近 N 小时的 principal 变更（取决于备份频率）
```

#### Step 3-C：切到备 KDC（20~30min）

```bash
# 前提：客户端 krb5.conf 已配多 KDC（生产必须！）
# [realms]
#     BIGDATA.COM = {
#         kdc = kdc01.bigdata.com:88
#         kdc = kdc02.bigdata.com:88   ← 备机
#     }

# 1) 验证备 KDC 状态
ssh kdc02.bigdata.com "systemctl status krb5kdc"
ssh kdc02.bigdata.com "ls -la /var/kerberos/krb5kdc/principal"

# 2) 备 KDC 升主（如果是只读副本，要切成可写）
ssh kdc02.bigdata.com "systemctl start kadmin"

# 3) DNS / VIP 切换（如果用了 VIP）
# 让 kdc.bigdata.com 指向 kdc02

# 4) 客户端验证（无 VIP 的情况下，krb5.conf 多 KDC 自动 failover）
kinit admin/admin
klist

# 5) 立即修主 KDC（异步），并补做主备同步
```

### 1.4 恢复后验证（30~60min 观察窗）

```bash
# 1) 端到端测试
sudo -u hdfs kinit -kt /etc/security/keytabs/hdfs.service.keytab hdfs/$(hostname -f)
sudo -u hdfs hdfs dfs -ls /
sudo -u hdfs kdestroy

# 2) 业务方验证（关键链路）
# - 提交一个测试 Spark 任务
# - 提交一个测试 Hive 查询
# - Beeline 连接

# 3) 监控指标观察
# - kinit 成功率
# - GSSException 错误数
# - TGS_REQ QPS

# 4) 三个观察窗
# T+15min：基础认证恢复
# T+30min：业务任务全恢复
# T+60min：无新增告警，宣布故障结束
```

### 1.5 复盘清单

- [ ] KDC 是否有主备 + 自动 failover
- [ ] 备份频率是否足够（建议 RPO ≤ 1h）
- [ ] 客户端 krb5.conf 是否多 KDC 配置
- [ ] 监控是否第一时间告警
- [ ] 应急 SOP 是否文档化
- [ ] 演练是否定期做（建议季度一次）

---

## 场景二：KDC 数据库主从同步断裂（P1）

### 2.1 现象

```
- 备 KDC 上某个新 principal 不存在
- 主 KDC 创建成功，但分发到集群后部分节点报 "Client not found"
- /var/kerberos/krb5kdc/slave_datatrans 文件停止更新
```

### 2.2 诊断

```bash
# 主 KDC
ls -la /var/kerberos/krb5kdc/slave_datatrans*
# 上次同步时间是否异常

# 看 cron / kprop 日志
grep kprop /var/log/messages
journalctl | grep kprop

# 备 KDC
journalctl -xeu kpropd
ls -la /var/kerberos/krb5kdc/from_master
```

### 2.3 恢复 SOP

#### Step 1：手动强制同步

```bash
# 主 KDC 上
kdb5_util dump /var/kerberos/krb5kdc/slave_datatrans
kprop -f /var/kerberos/krb5kdc/slave_datatrans kdc02.bigdata.com

# 看输出
# Database propagation to kdc02.bigdata.com: SUCCEEDED
```

#### Step 2：常见根因排查

| 根因 | 排查命令 | 修复 |
|-----|---------|------|
| host principal 缺失 | `kadmin.local -q "getprinc host/kdc02.bigdata.com"` | `addprinc -randkey host/kdc02 && ktadd host/kdc02` |
| keytab KVNO 不一致 | `klist -kt /etc/krb5.keytab \| grep kdc02` | 重新 `ktadd -norandkey` |
| kpropd.acl 错配 | `cat /var/kerberos/krb5kdc/kpropd.acl` | 加上 `host/kdc01@REALM` |
| 端口 754 不通 | `nc -zv kdc02 754` | 防火墙/iptables |
| /var 磁盘满 | `df -h /var` | 清日志 |

#### Step 3：定时同步恢复

```bash
# 主 KDC crontab
crontab -l | grep kprop
# 应有：*/5 * * * * /usr/sbin/kdb5_util dump ... && /usr/sbin/kprop ...

# 没有就加上
(crontab -l; echo "*/5 * * * * /usr/sbin/kdb5_util dump /var/kerberos/krb5kdc/slave_datatrans && /usr/sbin/kprop -f /var/kerberos/krb5kdc/slave_datatrans kdc02.bigdata.com >> /var/log/kprop.log 2>&1") | crontab -
```

### 2.4 验证

```bash
# 主 + 备 比对 principal 数量
kadmin.local -q "listprincs" | wc -l     # 主
ssh kdc02 "kadmin.local -q 'listprincs' | wc -l"  # 备
# 应一致
```

---

## 场景三：批量 Keytab KVNO 错乱（P0/P1）

### 3.1 现象

```
- 多个服务同时启动失败
- 日志报 "Specified version of key is not available (44)"
- klist -kt vs kvno 比对不一致
```

### 3.2 根因（典型）

🔴 **真实生产事故**：

1. 运维 X 半夜在主 KDC 上跑了 `for p in $(...); do kadmin.local -q "ktadd $p"; done`
2. **没加 `-norandkey`** → 每个 principal 密码都被改 → KVNO+1
3. 但 keytab 没分发到对应主机
4. 第二天服务重启 → 大批量挂

### 3.3 恢复 SOP

#### Step 1：止损（5min）

```bash
# 1) 立即冻结 KDC 写操作
# 应急群通报：禁止任何 kadmin 操作！

# 2) 确认影响范围
for h in $(cat hosts.txt); do
    ssh $h "for kt in /etc/security/keytabs/*.keytab; do
        principal=\$(klist -kt \$kt 2>/dev/null | awk 'NR==4{print \$4}')
        kt_kvno=\$(klist -kt \$kt 2>/dev/null | awk 'NR==4{print \$1}')
        echo \"\$(hostname),\$kt,\$principal,\$kt_kvno\"
    done"
done > /tmp/keytab_inventory.csv

# 3) 与 KDC 对比，找出不一致的
while IFS=, read -r host kt principal kt_kvno; do
    kdc_kvno=$(kvno "$principal" 2>/dev/null | awk '{print $NF}')
    if [[ "$kt_kvno" != "$kdc_kvno" ]]; then
        echo "MISMATCH: $host $principal kt=$kt_kvno kdc=$kdc_kvno"
    fi
done < /tmp/keytab_inventory.csv > /tmp/keytab_mismatch.txt

wc -l /tmp/keytab_mismatch.txt   # 受影响节点数
```

#### Step 2：批量恢复（按服务分批）

```bash
# 1) 在主 KDC 上批量重新导出（带 -norandkey！！！）
KDC_HOST=kdc01.bigdata.com
ssh $KDC_HOST "mkdir -p /tmp/keytab_redeploy"

while IFS=' ' read -r _ host principal _; do
    svc=$(echo $principal | cut -d/ -f1)
    fqdn=$(echo $principal | cut -d/ -f2 | cut -d@ -f1)
    out="/tmp/keytab_redeploy/${svc}.${fqdn}.keytab"
    ssh $KDC_HOST "kadmin.local -q 'ktadd -norandkey -k $out $principal'"
done < /tmp/keytab_mismatch.txt

# 2) 分发到对应节点（按服务批次，每批等待5分钟观察）
# 第一批：HMS / HS2（影响最大但只有几台）
# 第二批：HDFS NN/JN
# 第三批：DN / NM（数量最多）
# 第四批：其他

# 3) 单批分发脚本
deploy_keytab() {
    local host=$1 principal=$2 svc=$3 fqdn=$4
    local kt="${svc}.${fqdn}.keytab"
    
    scp $KDC_HOST:/tmp/keytab_redeploy/$kt /tmp/
    scp /tmp/$kt $host:/tmp/
    
    ssh $host "
        cp /etc/security/keytabs/${svc}.service.keytab /etc/security/keytabs/${svc}.service.keytab.bak_$(date +%s)
        mv /tmp/$kt /etc/security/keytabs/${svc}.service.keytab
        chown $svc:hadoop /etc/security/keytabs/${svc}.service.keytab
        chmod 400 /etc/security/keytabs/${svc}.service.keytab
        sudo -u $svc kinit -kt /etc/security/keytabs/${svc}.service.keytab $principal && \
            sudo -u $svc klist && \
            sudo -u $svc kdestroy
    "
}

# 4) 滚动重启服务（每批 5 分钟间隔）
for host in $(awk '/MISMATCH:/ {print $2}' /tmp/keytab_mismatch.txt | sort -u); do
    ssh $host "systemctl restart hadoop-hdfs-datanode hadoop-yarn-nodemanager"
    sleep 30
    # 看监控，确认健康再下一台
done
```

#### Step 3：复盘 + 防范

```bash
# 给所有人发警告：
# 禁止裸 kadmin.local -q "ktadd ..."
# 必须 ktadd -norandkey 或者 cpw -randkey + ktadd

# 在 KDC 上加个 wrapper
cat > /usr/local/bin/safe-ktadd <<'EOF'
#!/bin/bash
if [[ "$@" != *"-norandkey"* ]]; then
    echo "ERROR: 必须用 -norandkey，否则会改密码导致老 keytab 全废"
    echo "Usage: safe-ktadd -norandkey -k /path/to/keytab principal"
    exit 1
fi
exec kadmin.local -q "ktadd $@"
EOF
chmod 755 /usr/local/bin/safe-ktadd

# 加 audit log
echo "TYPE=COMMAND ACTION=ktadd USER=$USER" >> /var/log/audit/audit.log
```

---

## 场景四：跨域信任突然失效（P0）

### 4.1 现象

```
- 公司员工 alice@CORP.COM 突然无法访问 Hadoop 集群（HADOOP.COM）
- 报错：KrbException: Decrypt integrity check failed (31)
- 影响范围：所有走 AD/CORP 域的用户全部失败
```

### 4.2 典型根因

| 根因 | 概率 | 排查 |
|-----|------|-----|
| AD 侧改了 krbtgt 密码 | 60% | 联系 AD 团队 |
| AD 侧禁用了信任 | 20% | AD 侧管理界面查看 |
| Hadoop 侧 krb5.conf 被改 | 10% | git diff /etc/krb5.conf |
| 时钟漂移（跨域更敏感） | 5% | NTP |
| enctype 兼容性（AD 升级后） | 5% | KRB5_TRACE 看 enctype |

### 4.3 恢复 SOP

#### Step 1：止损 + 通报

```bash
# 1) 通报 AD 团队 + 业务方
echo "P0: 跨域信任失效，CORP→HADOOP 用户无法访问"

# 2) 留现场
KRB5_TRACE=/tmp/cross_realm_$(date +%s).log kinit alice@CORP.COM
# 把 trace 发给 AD 团队
```

#### Step 2：诊断

```bash
# 1) 确认 AD 侧 krbtgt
ssh ad-admin "PowerShell -Command 'Get-ADUser -Filter {Name -like \"krbtgt*\"} -Server CORP.COM'"

# 2) Hadoop 侧 krb5.conf
diff /etc/krb5.conf /etc/krb5.conf.git_backup

# 3) capaths 是否还在
grep -A5 "\[capaths\]" /etc/krb5.conf

# 4) auth_to_local 是否还在
grep -A20 "auth_to_local" /etc/hadoop/conf/core-site.xml
```

#### Step 3：双方协调重建信任

```bash
# 1) 与 AD 管理员确认时间窗，双方同时操作

# 2) AD 侧 (PowerShell)
# Set-ADUser -Identity "krbtgt/HADOOP.COM" -KerberosEncryptionType "AES256-SHA1"
# 重置密码（双方协议好密码）

# 3) Hadoop KDC 侧
kadmin.local -q "cpw -pw 'NEGOTIATED_SAME_PASSWORD' krbtgt/HADOOP.COM@CORP.COM"
kadmin.local -q "cpw -pw 'NEGOTIATED_SAME_PASSWORD' krbtgt/CORP.COM@HADOOP.COM"

# 4) 验证
kinit alice@CORP.COM
klist
hdfs dfs -ls /
```

### 4.4 应急方案：跨域信任暂时无法恢复

**降级方案**：让 CORP 用户**临时**用 HADOOP 域 principal

```bash
# 1) 给关键用户在 HADOOP 域创建临时 principal
for user in alice bob charlie; do
    kadmin.local -q "addprinc -pw 'TEMP_$(openssl rand -hex 8)' $user@HADOOP.COM"
done

# 2) 通过加密渠道发给用户

# 3) 业务方临时改用 user@HADOOP.COM 登录

# 4) 待跨域恢复后，删除临时 principal
```

---

## 场景五：长任务集体雪崩（Token 过期）（P1）

### 5.1 现象

```
- 某个时刻（通常是凌晨）大量长任务（Spark Streaming/Flink/Long Hive）同时挂
- 错误：org.apache.hadoop.security.token.SecretManager$InvalidToken: 
        token (HDFS_DELEGATION_TOKEN ...) is expired
- 时间点：通常在任务提交后的第 7 天前后
```

### 5.2 根因深扒

```
[任务提交] kinit + 拿 HDFS_DELEGATION_TOKEN（max-lifetime=7天）
   ↓
[T+0~T+1d] AM renewToken() 续期一次（renew-interval=1天）
   ↓
[T+1d~T+7d] AM 持续 renewToken()
   ↓
[T+7d] 达到 max-lifetime，token 不能再续 → 任务挂
   ↓
解药：必须 --keytab 让 AM 重新走 kinit 拿新 token
```

> ⚠️ **没传 --keytab 的任务在 T+7d 必死，无解**

### 5.3 恢复 SOP

#### Step 1：止损（不可逆，已挂的任务挽回不了）

```bash
# 1) 应急群通报：受影响任务列表

# 2) 给业务方提供"快速重新提交"模板
cat <<'EOF' > /tmp/spark_resubmit.sh
spark-submit \
  --master yarn \
  --deploy-mode cluster \
  --principal $USER@BIGDATA.COM \
  --keytab /home/$USER/$USER.keytab \
  --conf spark.kerberos.access.hadoopFileSystems=hdfs://nn.bigdata.com:8020 \
  ... 业务参数 ...
EOF

# 3) 协助业务方批量重启
for app in $(yarn application -list -appStates RUNNING | awk '/SPARK/{print $1}'); do
    echo "Need to resubmit with --keytab: $app"
done
```

#### Step 2：根治（建立 wrapper 强制 --keytab）

```bash
# /usr/local/bin/safe-spark-submit
cat <<'EOF' > /usr/local/bin/safe-spark-submit
#!/bin/bash
if [[ "$@" != *"--keytab"* ]] || [[ "$@" != *"--principal"* ]]; then
    if [[ "$@" == *"--deploy-mode cluster"* ]]; then
        echo "❌ 拒绝执行：长任务必须传 --keytab 和 --principal"
        echo "   例：--keytab /home/$USER/$USER.keytab --principal $USER@BIGDATA.COM"
        exit 1
    fi
fi
exec /opt/spark/bin/spark-submit "$@"
EOF
chmod 755 /usr/local/bin/safe-spark-submit

# 把 PATH 中 spark-submit 软链到 safe-spark-submit
ln -sf /usr/local/bin/safe-spark-submit /usr/local/bin/spark-submit
```

### 5.4 防范监控

```bash
# Prometheus 规则：HDFS NN 即将过期 token 数
- alert: HDFSDelegationTokenExpiringSoon
  expr: hadoop_namenode_dt_count{type="expired_in_24h"} > 50
  for: 30m
  labels: { severity: warning }
  annotations:
    summary: "HDFS 即将过期 token 超过 50 个，可能有长任务未配 --keytab"

# 自定义巡检：找出未配 --keytab 的长任务
yarn application -list -appStates RUNNING -appTypes SPARK | \
    awk 'NR>2 {print $1}' | \
    while read app; do
        # 这个判断需要从 RM API 拿到提交命令的完整参数
        if ! curl -s "http://rm:8088/ws/v1/cluster/apps/$app" | grep -q "keytab"; then
            echo "WARNING: $app 未配 --keytab，将在 7 天内挂"
        fi
    done
```

---

## 场景六：DataNode 大面积启动失败（P1）

### 6.1 现象

```
- HDFS DataNode 大量节点启动失败
- 日志：javax.security.auth.login.LoginException: 
        Unable to obtain password from user
- 影响：数据可用性下降，HDFS 报警 missing blocks
```

### 6.2 根因常见模式

| 模式 | 排查 |
|-----|------|
| keytab 文件权限错乱 | `ls -l /etc/security/keytabs/hdfs.service.keytab` |
| keytab 没分发到新节点 | 节点上文件不存在 |
| 集群批量改了 hostname | `hostname -f` 与 KDC SPN 不符 |
| krb5.conf 被批量改坏 | 与 git 备份对比 |

### 6.3 恢复 SOP

```bash
# 1) 找出所有失败节点
for h in $(cat datanodes.txt); do
    ssh $h "systemctl is-active hadoop-hdfs-datanode" || echo "DOWN: $h"
done > /tmp/dn_down.txt

# 2) 抽样诊断（找一台具体看）
SAMPLE=$(head -1 /tmp/dn_down.txt | awk '{print $2}')
ssh $SAMPLE "
    ls -l /etc/security/keytabs/hdfs.service.keytab
    sudo -u hdfs klist -kt /etc/security/keytabs/hdfs.service.keytab
    sudo -u hdfs kinit -kt /etc/security/keytabs/hdfs.service.keytab hdfs/\$(hostname -f)@BIGDATA.COM
    journalctl -u hadoop-hdfs-datanode -n 50
"

# 3) 根据根因批量修
# 假设是权限问题
for h in $(awk '{print $2}' /tmp/dn_down.txt); do
    ssh $h "
        chown hdfs:hadoop /etc/security/keytabs/hdfs.service.keytab
        chmod 400 /etc/security/keytabs/hdfs.service.keytab
        systemctl restart hadoop-hdfs-datanode
    "
    sleep 10  # 错峰避免 NN 压力
done

# 4) 滚动重启的同时观察 NN
watch -n 5 "hdfs dfsadmin -report | head -20"
```

### 6.4 防范

> 故障最佳防范是 **配置变更走 ChatOps + Ansible Playbook + 自动化校验**

```yaml
# ansible playbook: validate_kerberos.yml
---
- hosts: all
  tasks:
    - name: 检查 keytab 文件
      stat:
        path: /etc/security/keytabs/hdfs.service.keytab
      register: kt
      
    - name: 校验权限
      assert:
        that:
          - kt.stat.mode == '0400'
          - kt.stat.pw_name == 'hdfs'
        fail_msg: "keytab 权限错"
        
    - name: 测试 kinit
      command: "sudo -u hdfs kinit -kt /etc/security/keytabs/hdfs.service.keytab hdfs/{{ ansible_fqdn }}@BIGDATA.COM"
      changed_when: false
```

---

## 场景七：HiveServer2 全集群拒绝连接（P0）

### 7.1 现象

```
- 业务方 Beeline / JDBC 全部连不上
- 错误：GSSException: No valid credentials provided 
        (Mechanism level: Failed to find any Kerberos tgt)
        Or: Could not open client transport
- 影响：所有 Hive/Spark SQL 查询全停
```

### 7.2 排查决策树

```
HS2 连不上
├── HS2 进程是否在跑？
│   ├── 否 → 看 HS2 日志，多半是 keytab/配置问题（场景六类似）
│   └── 是 → 进 ②
├── ② HS2 是否能 kinit 自己的 keytab？
│   ├── 否 → keytab 失效，重发
│   └── 是 → 进 ③
├── ③ HS2 是否能连 HMS？
│   ├── 否 → HMS Kerberos 问题
│   └── 是 → 进 ④
├── ④ HS2 是否能连 NN？
│   ├── 否 → HDFS Kerberos 问题
│   └── 是 → 进 ⑤
└── ⑤ 客户端 connect 报错
    ├── principal 写错？
    ├── 端口不通？
    └── HS2 SPN 不对？
```

### 7.3 恢复 SOP

```bash
# 1) 服务端诊断
ssh hs2.bigdata.com "
    # 看 HS2 进程
    jps | grep -i hiveserver
    
    # 看日志最后 100 行
    tail -100 /var/log/hive/hiveserver2.log
    
    # HS2 是否能 kinit
    sudo -u hive kinit -kt /etc/security/keytabs/hive.service.keytab hive/\$(hostname -f)@BIGDATA.COM
    
    # 测试连 HMS
    sudo -u hive beeline -u 'jdbc:hive2://hs2.bigdata.com:10000/default;principal=hive/_HOST@BIGDATA.COM' -e 'show databases;'
"

# 2) 如果是 keytab 问题
ssh hs2.bigdata.com "
    chown hive:hive /etc/security/keytabs/hive.service.keytab
    chmod 400 /etc/security/keytabs/hive.service.keytab
    systemctl restart hive-server2
"

# 3) 如果是 HMS 问题，先修 HMS
# (类似流程)

# 4) 客户端验证
kinit alice
beeline -u "jdbc:hive2://hs2.bigdata.com:10000/default;principal=hive/_HOST@BIGDATA.COM" -e "show databases;"
```

---

## 场景八：YARN ResourceManager Kerberos 故障（P0）

### 8.1 现象

```
- 任务提交全失败
- yarn application -list 报权限错
- RM 日志：Failed to login as yarn/_HOST@REALM
```

### 8.2 恢复 SOP

```bash
# 1) RM 主节点诊断
ssh rm01.bigdata.com "
    systemctl status hadoop-yarn-resourcemanager
    
    # keytab 验证
    sudo -u yarn klist -kt /etc/security/keytabs/yarn.service.keytab
    sudo -u yarn kinit -kt /etc/security/keytabs/yarn.service.keytab yarn/\$(hostname -f)@BIGDATA.COM
    
    # 看完整日志
    tail -200 /var/log/hadoop-yarn/yarn-yarn-resourcemanager-*.log
"

# 2) 如果是 RM HA 主备都挂
# 先拉起备 RM
ssh rm02.bigdata.com "systemctl restart hadoop-yarn-resourcemanager"

# 等待 ZKFC 选主
sleep 30
yarn rmadmin -getAllServiceState

# 3) 修主 RM
ssh rm01.bigdata.com "
    # 修复 keytab/配置
    systemctl restart hadoop-yarn-resourcemanager
"

# 4) 验证
yarn application -list
yarn application -submit ...  # 提交一个测试任务
```

---

## 场景九：KDC 性能下降（请求超时）（P1）

### 9.1 现象

```
- kinit 需要等 30 秒以上
- TGS_REQ 大量超时
- 集群整体性能下降，但各组件本身正常
```

### 9.2 根因

| 根因 | 排查 |
|-----|------|
| QPS 暴增 | `tail -f /var/log/krb5kdc.log \| pv -lr > /dev/null` 看速率 |
| 数据库变大 | `du -sh /var/kerberos/krb5kdc/` |
| 磁盘 IO 瓶颈 | `iostat -x 1` |
| 网络抖动 | `mtr kdc01.bigdata.com` |
| 进程 GC（如果是 FreeIPA） | `jstat -gc` |

### 9.3 恢复 SOP

```bash
# 1) 紧急扩容：起更多 KDC 副本
# 客户端 krb5.conf 加更多 kdc=

# 2) 限流：临时屏蔽异常 IP
# 看谁在疯狂请求
awk '/AS_REQ|TGS_REQ/ {print $NF}' /var/log/krb5kdc.log | sort | uniq -c | sort -rn | head
# 找到异常 IP 后临时 iptables 限流

# 3) 优化客户端
# replay cache 关闭可大幅提升性能（仅在受信网络）
# /etc/krb5.conf
[libdefaults]
    krb5_get_init_creds_opt_set_no_address = true
```

---

## 场景十：KDC 数据库被误删 / 加密（勒索软件）（P0+++）

### 10.1 现象

```
- /var/kerberos/krb5kdc/principal* 文件不存在或被加密
- KDC 起不来
- 业务方反馈无法 kinit
- 看 audit log 发现可疑操作
```

### 10.2 这是最严重的故障 — 可能整个集群报废

### 10.3 恢复 SOP

#### Step 1：紧急止损（5min）

```bash
# 1) 立即下线 KDC（防止勒索软件横向）
systemctl stop krb5kdc kadmin
systemctl mask krb5kdc kadmin

# 2) 启动应急通报（CTO 级别）

# 3) 隔离 KDC 主机（断网/转 VLAN）
ip link set eth0 down
```

#### Step 2：从备份恢复（30min~2h）

```bash
# 1) 找最新可信备份
ls -lh /backup/krb5_dump_*.txt /backup/krb5_dump_*.gz

# 2) 取出 master key 文件备份
ls -la /backup/.k5.BIGDATA.COM_*

# 3) 在新主机或清理后的主机上恢复
# 完整重建步骤
yum install -y krb5-server krb5-workstation

# 4) 还原配置（git 仓库）
cp /backup/krb5.conf /etc/krb5.conf
cp /backup/kdc.conf /var/kerberos/krb5kdc/kdc.conf
cp /backup/kadm5.acl /var/kerberos/krb5kdc/kadm5.acl

# 5) 创建空数据库
kdb5_util create -s -r BIGDATA.COM
# 用相同 master key（关键！）

# 6) 加载备份
kdb5_util load /backup/krb5_dump_LATEST.txt

# 7) 启动
systemctl unmask krb5kdc kadmin
systemctl start krb5kdc kadmin

# 8) 验证
kinit admin/admin
klist
```

#### Step 3：评估丢失范围

```bash
# 备份时间 → 故障时间 之间创建的所有 principal 都丢了
# 需要重建：
#  - 期间新加入的节点（重新创建 host/<fqdn> + 各服务 principal）
#  - 期间新建的用户

# 业务方协作，提供丢失清单
```

#### Step 4：法证 + 加固

```bash
# 1) 保留被入侵主机的镜像（法证用）
dd if=/dev/sda of=/external/forensic_image.dd

# 2) 全集群安全审计
# - 改所有运维人员的 SSH key
# - 改所有服务账号密码
# - 旋转所有 keytab
# - 审查 sudo 日志、bash history、audit log

# 3) 加固
# - KDC 主机网络隔离（管理网）
# - 多因素认证 SSH
# - 备份异地+离线
# - Audit log 实时投递到 SIEM
```

### 10.4 这种故障最重要的是**预防**

| 加固项 | 措施 |
|-------|------|
| 备份 | **每小时全量** + 异地 + 离线（cold backup） |
| 网络 | KDC 仅管理网 + bastion 跳板 |
| 主机 | 最小化软件 + Selinux enforcing + auditd |
| 操作 | 双因素 + 操作录屏 + 4 眼校验 |
| 监控 | KDC 数据库文件大小变化告警 + 进程文件 inotify 监控 |
| 演练 | **半年一次完整恢复演练**（非必要不删，但要演） |

---

## 故障复盘模板（必填）

```markdown
# Kerberos 故障复盘 — YYYY-MM-DD

## 一、基本信息
- 故障级别：P0/P1/P2
- 触发时间：
- 发现时间：（说明监控发现 vs 业务报障）
- 解决时间：
- 总时长：
- MTTD（发现耗时）：
- MTTR（恢复耗时）：

## 二、现象
（用户视角的现象描述）

## 三、影响
- 影响范围：哪些业务/用户
- 影响时长：
- 影响程度：完全不可用 / 性能下降 / 部分功能受限
- 数据影响：（是否数据丢失/不一致）

## 四、时间线
| 时间 | 事件 | 操作人 |
|-----|------|--------|
| 10:00 | 监控告警 KDC 不可达 | - |
| 10:01 | 应急群通报 P0 | 张三 |
| 10:05 | 登录 KDC 主机确认进程挂 | 张三 |
| 10:08 | 发现 OOM Killer 杀 KDC | 张三 |
| 10:10 | 重启 KDC 服务 | 张三 |
| 10:12 | 验证 kinit 成功 | 李四 |
| 10:30 | 业务方确认全部恢复 | 王五 |

## 五、根因分析（5 Whys）
- Why 1：KDC 进程挂了
- Why 2：OOM Killer 杀的
- Why 3：KDC 内存使用超限
- Why 4：principal 数据库变大 + replay cache 增多
- Why 5：上周新增 1 万个临时 principal 没清理

## 六、改进措施
| 措施 | 责任人 | 截止 | 状态 |
|-----|--------|-----|-----|
| 限制 principal 总数告警 | 张三 | 2026-05-15 | 进行中 |
| KDC 主机内存扩容 | 李四 | 2026-05-12 | 完成 |
| 临时 principal 自动清理脚本 | 王五 | 2026-05-20 | 待办 |

## 七、经验沉淀
（这次故障教会我们什么 → 写进 Skill / SOP）
```

---

## 故障演练检查清单（季度执行）

- [ ] 主 KDC 故障 → 切备 KDC（验证客户端自动 failover）
- [ ] 备 KDC 落后 → 手动同步
- [ ] 单节点 keytab 失效 → 重发
- [ ] 跨域信任失效（模拟） → 重建
- [ ] 长任务 token 过期（提前调短测试） → 验证 --keytab
- [ ] KDC 数据库恢复（在测试环境）
- [ ] 监控告警是否准确触发
- [ ] 应急群通报流程是否顺畅
- [ ] 文档是否需要更新

---

## 参考文档

- [01-Kerberos从0到1-原理深度解析.md](./01-Kerberos从0到1-原理深度解析.md)
- [02-Kerberos实战手册-部署与运维操作.md](./02-Kerberos实战手册-部署与运维操作.md)
- [03-大数据组件Kerberos集成配置大全.md](./03-大数据组件Kerberos集成配置大全.md)
- [04-Kerberos运维问题库Top50.md](./04-Kerberos运维问题库Top50.md)
- [05-Kerberos排障SOP与工具箱.md](./05-Kerberos排障SOP与工具箱.md)

---

*Eric · 大数据 SRE AI 专家团队 · 知识晶体化 v1.0 · 故障即财富*
