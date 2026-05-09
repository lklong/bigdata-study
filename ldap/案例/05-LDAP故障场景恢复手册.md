# LDAP 故障场景恢复手册（DR Runbook）

> 作者：Eric（豹纹）| 团队：BigData SRE AI Expert Team v3.0  
> 配套：00 入门 / 01 搭建 / 02 集成 / 03 运维 / 04 排障  
> 定位：**这是灾难恢复（DR, Disaster Recovery）手册，不是问题排障手册**  
> 与 04 的区别：04 治"病"（症状→根因），05 治"伤"（已发生灾难→止血→复活→预防）

---

## 0. 前置：你必须先理解的 4 个数字

任何 DR 手册第一件事是**约定 SLA**，否则恢复操作没有准绳。

| 概念 | 含义 | LDAP 推荐目标 | 触发条件 |
|------|------|-------------|---------|
| **MTTD** | 故障检测时长（告警时间） | **<2 min** | 监控接 Prometheus + Alertmanager |
| **MTTR** | 平均修复时长 | **<30 min** | 见各 Runbook |
| **RTO** | 恢复时间目标（业务多久回血） | **P0=15min / P1=1h / P2=4h** | DR 演练考核 |
| **RPO** | 数据丢失容忍（最多丢多久数据） | **<5 min** | 备份 + 复制频率 |

**与大数据组件的耦合**：LDAP 挂 → HDFS NN/HS2/Ranger/Kyuubi 全连锁，且各组件**缓存生效时间** 不同：
- HDFS `groups.cache.secs` 默认 300s → 用户组缓存 5 分钟保命
- SSSD `entry_cache_timeout` 600s → 主机登录 10 分钟保命
- HS2 / Trino 无 group 缓存 → **LDAP 一挂，新连接立即失败**

⚠️ **结论**：LDAP RTO 必须 < min(各组件 cache TTL)，否则故障会扩散成集群级。

---

## 1. 故障场景全景图（10 大场景 + 影响等级）

```
┌────────────────────────────────────────────────────────────────────┐
│                       故障等级定义                                    │
│  P0 全集群业务停摆     P1 部分业务停摆     P2 单点 / 性能劣化         │
└────────────────────────────────────────────────────────────────────┘

[P0 级] —— 必须 15 分钟内有动作
  S1.  全部 LDAP 节点宕机（断电 / 网络分区 / 配置错误）
  S2.  数据库文件损坏 / mdb 无法打开
  S3.  误操作：rm -rf 全树 / ldapdelete 顶层 OU
  S4.  勒索加密 / 入侵：data.mdb 被加密、admin 密码被改

[P1 级] —— 1 小时内
  S5.  双主脑裂（MMR 节点互相不同步，写入冲突）
  S6.  TLS 证书全集群过期 → 客户端 SSL 报错风暴
  S7.  Schema 损坏 / cn=config 损坏 → slapd 启动失败但数据完好
  S8.  备份数据本身损坏 / 不可恢复

[P2 级] —— 4 小时内
  S9.  单节点宕机 / 单磁盘故障
  S10. 复制中断 7 天以上（cookie 失效）
  S11. 性能急剧劣化（突然 P99 > 1s）
  S12. 客户端连接耗尽（fd 打满，新连接拒绝）
```

> 📌 04 排障篇覆盖 S11/S12 的常规版；本篇侧重"已经造成业务影响"的恢复套路。

---

## 2. S1：全部 LDAP 节点宕机（最严重，先看这个）

### 2.1 现象

- Alertmanager 同时报：`LDAPDown @ m1, m2, r1`
- 大数据集群级告警雪崩：HS2 报 `Could not establish connection`，Ranger UI 502
- HDFS / YARN 短期内可工作（cache 撑着），但新 group resolve 全失败

### 2.2 影响范围

| 时间窗口 | 影响 |
|---------|------|
| 0~5 min | HS2/Trino/Hue 新连接全失败；老连接还在 |
| 5~15 min | Ranger 鉴权 cache 失效，HDFS 写入开始 403 |
| 15~30 min | HDFS group cache 失效，**全集群读写双停** |
| >30 min | 灾难级 |

### 2.3 决策树（先止血再修复）

```
     全部 LDAP 不可达
            │
   ┌────────┴────────┐
   │                 │
机房网络问题？        机房 OK 但 LDAP 进程都挂？
   │                 │
   ▼                 ▼
联系网络团队         systemctl status slapd
分钟级 ETA          能起来？
                    │
            ┌───────┴───────┐
            │               │
           能              不能
            │               │
            ▼               ▼
      自然恢复       看 /var/log/slapd.log
      监控验证       是哪个节点先挂
                    可能是配置 / 数据 / 内核
                    → 走 S2 / S7 流程
```

### 2.4 恢复 Runbook（按时间线）

```
T+0    : 接告警
T+1min : SRE 全员钉钉/企微开会议；启动 P0 应急流程
T+2min : 停掉所有"会自动重启 slapd 的脚本"（防止反复挂起）
T+3min : 一次性 ssh 到所有 LDAP 节点，screen / tmux 内执行：
         systemctl status slapd --no-pager -l
         tail -100 /var/log/slapd.log
         dmesg -T | tail -30                    # 看是否 OOM kill
         df -h /var/lib/ldap                    # 看是否磁盘满
T+5min : 三选一：
         (a) OOM killed → 临时 vm.overcommit_memory=2 + 重启
         (b) 磁盘满    → 清 /var/log/slapd.log 老文件 + 重启
         (c) 数据损坏  → 走 §3 S2 流程
T+10min: 任意一个节点先起来 → 立即把客户端流量切到这一个：
         haproxy: 保留这个 server，其他临时 disable
T+15min: 大数据组件验证：
         ldapwhoami -x -H ldaps://recovered-node -D ... -w ...
         beeline -u jdbc:hive2://hs2:10000 -n test -p test
T+30min: 其他节点逐个起来 → 加回 LB
T+1h  : 全恢复 → 写故障复盘
```

### 2.5 关键命令包（直接复制用）

```bash
# 一键状态收集脚本（应急时跑这个，输出粘到群里）
cat <<'EOF' > /tmp/ldap-emergency.sh
#!/bin/bash
echo "=== $(date) on $(hostname) ==="
echo "--- systemd ---"
systemctl status slapd --no-pager | head -20
echo "--- last 50 log ---"
tail -50 /var/log/slapd.log 2>/dev/null
echo "--- disk ---"
df -h /var/lib /var/log
echo "--- mem ---"
free -h
echo "--- listen ---"
ss -tlnp | grep -E ":389|:636"
echo "--- conn count ---"
ss -tn state established | wc -l
echo "--- dmesg OOM ---"
dmesg -T | grep -i "killed process\|out of memory" | tail -5
EOF
chmod +x /tmp/ldap-emergency.sh

# 集群批跑
for h in m1 m2 r1; do
  echo "##### $h #####"
  ssh $h 'bash -s' < /tmp/ldap-emergency.sh
done
```

### 2.6 复盘清单

- [ ] 为什么所有节点同时挂？（配置同步过来的 bug？广播脚本踩到的？）
- [ ] 监控告警是否在 2 分钟内响应？
- [ ] 客户端缓存是否撑住了到第一个节点恢复？
- [ ] HAProxy 健康检查是否准确反映了节点状态？

---

## 3. S2：mdb 数据库文件损坏

### 3.1 现象

- slapd 启动失败：
  ```
  bdb_db_open: warning - no DB_CONFIG file found
  mdb_env_open failed: Invalid argument (22)
  bdb_db_open: database "dc=bigdata,dc=local" cannot be opened
  ```
- 或者运行中突然崩溃：`mdb_txn_commit: MDB_CORRUPTED`

### 3.2 根因（从重到轻）

1. **磁盘坏块**：dmesg 看 `Buffer I/O error on dev sda`
2. **内核 OOM** 杀进程，slapd 没来得及 commit txn
3. **强制 kill -9**（违反规范）
4. **备份脚本用 cp 而非 slapcat**（cp 不保证原子，破坏 mmap 一致性）
5. **mdb 文件超出 olcDbMaxSize**

### 3.3 恢复决策树

```
mdb 损坏
   │
   ▼
是单节点损坏？还是全部？
   │
┌──┴──┐
│     │
单点  全部
│     │
▼     ▼
方案A  方案B
```

#### 方案 A：单节点损坏（其他节点健康）

```bash
# 1. 把损坏节点先从 LB 摘掉
# 2. 停损坏节点 slapd
systemctl stop slapd

# 3. 备份损坏现场（取证用，别覆盖）
mv /var/lib/ldap /var/lib/ldap.broken.$(date +%s)
mkdir /var/lib/ldap && chown ldap:ldap /var/lib/ldap

# 4. 从健康节点 slapcat 出干净 LDIF
ssh m2 "slapcat -F /etc/openldap/slapd.d -n 2" > /tmp/clean.ldif
ssh m2 "slapcat -F /etc/openldap/slapd.d -n 0" > /tmp/config.ldif

# 5. 注入到损坏节点
slapadd -F /etc/openldap/slapd.d -n 2 -l /tmp/clean.ldif
chown -R ldap:ldap /var/lib/ldap

# 6. 启动
systemctl start slapd
ldapsearch -x -D "cn=admin,..." -w ... -b "dc=bigdata,dc=local" | head

# 7. 等 syncrepl 把"损坏期间的增量"补上
ldapsearch -x -H ldap://localhost -D "cn=admin,..." -w ... \
  -b "dc=bigdata,dc=local" -s base contextCSN
# 与 m2 比对，差值应在秒级缩小

# 8. 加回 LB
```

#### 方案 B：全部节点都损坏（最坏情况）

走 §11 备份恢复流程，并启动 RPO 评估（丢了多久数据）。

### 3.4 关键决策点

```
slapd 起不来时，做不做 mdb_recover？

方案：99% 情况下 ❌ 不做。原因：
1. mdb 不像 BDB 有 db_recover 工具，"修复"基本无效
2. 强行 mdb_dump 出来的数据可能含损坏条目，导入还是炸
3. **正确路径永远是从健康副本/备份重建**，不是修文件
```

### 3.5 取证（事后必做）

```bash
# 复盘时分析损坏原因
file /var/lib/ldap.broken/data.mdb
xxd /var/lib/ldap.broken/data.mdb | head     # 看 magic number
ls -la /var/lib/ldap.broken/                  # 看修改时间
# 与 dmesg / messages 时间线对齐
journalctl -u slapd --since "1 hour ago"
```

---

## 4. S3：误操作——rm -rf 全树 / ldapdelete 顶层

### 4.1 真实场景

> "我本来想删 ou=Disabled，结果手抖删了 dc=bigdata,dc=local —— 整棵树没了"

### 4.2 第一反应（黄金 30 秒）

```
1. 立即 STOP！不要再发任何写操作！不要 restart slapd！
2. 立即 systemctl stop slapd（防止删除被同步到从节点）
3. 立即在【其他节点】也 systemctl stop slapd
4. 喊 SRE Lead 上线、通报老板
5. 评估：删除是否已 sync 到从节点？
```

### 4.3 决策矩阵

```
                           误删时间 < 5 分钟          5~30 分钟              > 30 分钟
                           ─────────────             ─────────────         ─────────────
所有节点都同步了删除？      可能从节点还没收到         几乎都同步了            肯定都同步了
                           → 抢救从节点              → 走备份恢复             → 走备份恢复

是否有 accesslog？          有 → 可以 reverse 操作    有 → 可以 reverse        accesslog 已 purge
                           → 黄金路径                → 黄金路径               → 走备份恢复

最后一次备份多久前？        <1h → RPO 可接受          <1h → RPO 可接受         可能 RPO 长达 24h
                           走备份恢复 OK             走备份恢复 OK            通知业务做数据补偿
```

### 4.4 黄金路径：用 accesslog 反向恢复

OpenLDAP 的 `accesslog` overlay 会记录所有写操作的"前像"，可逆向：

```bash
# 1. 找到删除操作的时间戳
ldapsearch -x -D "cn=admin,cn=accesslog" -w ... -b "cn=accesslog" \
  "(&(reqType=delete)(reqDN=dc=bigdata,dc=local))" \
  reqStart reqEnd reqAuthzID reqOld

# 输出会包含 reqOld 即被删条目的所有原属性 → 可以重建

# 2. 写脚本把 reqOld 转回 LDIF（实操脚本，节录）
ldapsearch ... -b "cn=accesslog" "(&(reqType=delete)(reqDN=*))" reqDN reqOld \
  | python3 reverse-delete.py > /tmp/restore.ldif

# 3. 验证后导入
ldapadd -x -D "cn=admin,..." -w ... -f /tmp/restore.ldif
```

### 4.5 兜底路径：备份恢复

```bash
# 选最近的 backup（必须晚于误删之前）
ls -lt /data/backup/ldap/data_*.ldif.gz | head

# 解压
gunzip -c /data/backup/ldap/data_20260509_020000.ldif.gz > /tmp/restore.ldif

# 在被删节点上：
systemctl stop slapd
rm -rf /var/lib/ldap/*
slapadd -F /etc/openldap/slapd.d -n 2 -l /tmp/restore.ldif
chown -R ldap:ldap /var/lib/ldap
systemctl start slapd

# 等其他节点 syncrepl 自动同步过去
# （但若其他节点已停过，可能也需要相同恢复操作）

# 评估 RPO：
# 备份时间 02:00，误删时间 14:30，业务在 02:00~14:30 间的写入全丢
# → 通知业务方："请重新提交 02:00 之后的用户/组变更"
```

### 4.6 强制预防

```ldif
# 给整棵根加"删除保护"ACL（顶层只能 admin 删）
olcAccess: {0}to dn.exact="dc=bigdata,dc=local"
  by dn.exact="cn=root,cn=config" write
  by * read

# OU 删除保护（防止误删 ou=People）
olcAccess: {1}to dn.exact="ou=People,dc=bigdata,dc=local" attrs=entry
  by dn.exact="cn=root,cn=config" write
  by * read
```

并在所有 admin 工作站设别名：
```bash
alias ldapdelete='echo "禁止使用 ldapdelete，请走工单" && false'
# 真正删除走 modrdn 移到 ou=Disabled，软删除
```

---

## 5. S4：勒索加密 / 入侵后恢复

### 5.1 现象

- `data.mdb` 大小变 0 或文件被改成 `.encrypted`
- `cn=admin` 密码被改、`olcRootDN` 被换、出现勒索 entry
- 主机 `/etc/passwd` 多了奇怪用户、`crontab` 出现挖矿任务

### 5.2 第一反应（按事件响应预案）

```
T+0   : 立即 systemctl stop slapd 全集群
T+0   : 立即在防火墙级断开 LDAP 节点 → 防止数据外泄
T+5   : 通知信息安全团队、法务、CISO
T+10  : 创建快照 / dd 镜像，全节点取证盘
T+15  : 不要执行任何 rm（取证完成前所有动作可逆）
T+30  : 与安全团队评估入侵路径
T+1h  : 隔离环境重建新集群，从【可信备份】恢复
T+4h  : 网络逐步切回新集群
T+24h : 写事故报告、通报合规
```

### 5.3 可信备份判定

```
判断备份是否被污染：
1. 备份产生时间是否早于第一次入侵迹象？
   → 看 auditlog overlay 的最后异常 bind 时间
2. 备份内容是否含异常条目？
   → diff 备份与历史快照的 cn=admin 条目
3. 备份脚本本身是否被改？
   → 看 git log + sha256 vs 已知值

⚠️ 如果不确定 → 用最早的"绝对干净"备份 + 业务侧重新走人事系统全量重建
```

### 5.4 取证保存

```bash
# 制作内存镜像（恶意软件可能只在内存）
gcore -o /forensic/slapd $(pidof slapd)

# 制作磁盘镜像
dd if=/dev/sda1 of=/forensic/sda1.img bs=4M status=progress

# 抓取所有 auditlog
cp /var/log/openldap/audit.log /forensic/

# 网络连接快照
ss -tnp > /forensic/ss.txt
netstat -anp > /forensic/netstat.txt
lsof -p $(pidof slapd) > /forensic/lsof.txt

# 进程树
ps -auxf > /forensic/ps.txt
```

### 5.5 重建集群的安全加固

- **bind 账号密码全部轮换** + 走 Vault
- **TLS 证书全部重签**（攻击者可能拿到了私钥）
- **管理员账号改名 + 多因素认证**
- **网络隔离**：LDAP 子网只允许大数据集群子网访问
- **启用 fail2ban**（详见 04-§7.2）
- **接 SIEM**：所有 bind 失败 / admin 写操作实时告警

---

## 6. S5：双主脑裂（MMR 节点互相不同步）

### 6.1 现象

- m1 加用户 alice，m2 上查不到
- 反过来 m2 加用户 bob，m1 上查不到
- 各自的 contextCSN 在自增但**不互相收敛**

### 6.2 根因诊断

```bash
# 1. 看双方对对方的 syncrepl 状态
ssh m1 "ldapsearch -Y EXTERNAL -H ldapi:/// -b 'cn=config' \
  '(olcSyncrepl=*)' olcSyncrepl"
ssh m2 "..."

# 2. 看双方的 accesslog 是否还在记录写
ssh m1 "ldapsearch -x -D 'cn=admin,cn=accesslog' -w ... -b 'cn=accesslog' \
  -s one '(reqResult=0)' | tail -20"

# 3. 看网络
ssh m1 "nc -zv m2 636"
ssh m2 "nc -zv m1 636"

# 4. 看时钟
ssh m1 "chronyc tracking" 
ssh m2 "chronyc tracking"
# 时钟差 >100ms 就是元凶
```

### 6.3 决策树

```
脑裂检测到
    │
    ▼
是网络不通？
    ├── 是 → 联系网络团队，等连通后自动收敛
    │       期间客户端流量只走【最新】节点（看 contextCSN 大者）
    │
    ▼ 否
时钟差 >100ms？
    ├── 是 → 立即 chrony 同步：chronyc -a makestep
    │       同步后 5 分钟自动收敛
    │
    ▼ 否
syncrepl 配置丢了？
    ├── 是 → 重新 add olcSyncrepl 触发 refresh
    │
    ▼ 否
schema 不一致？（一边导了新 schema 另一边没导）
    ├── 是 → 把缺失 schema add 上
    │
    ▼ 否
数据冲突（同一 DN 双方都在改）
    └── 选权威节点 → 另一边停服 → slapcat 权威 → slapadd 重建 → 启 sync
```

### 6.4 强制收敛步骤（最坏情况）

```bash
# 选 m1 为权威（数据更新或更全）
# 1. m2 停服
ssh m2 "systemctl stop slapd"

# 2. m1 dump 全量
ssh m1 "slapcat -F /etc/openldap/slapd.d -n 2 > /tmp/auth.ldif"
scp m1:/tmp/auth.ldif m2:/tmp/

# 3. m2 清数据 + 重建
ssh m2 "rm -rf /var/lib/ldap/* && \
        slapadd -F /etc/openldap/slapd.d -n 2 -l /tmp/auth.ldif && \
        chown -R ldap:ldap /var/lib/ldap"

# 4. m2 启动
ssh m2 "systemctl start slapd"

# 5. 验证
ssh m2 "ldapsearch ... -b 'dc=bigdata,dc=local' -s base contextCSN"
# 与 m1 contextCSN 应一致或仅秒级差
```

### 6.5 双盲冲突恢复（双方都改了同一条目）

```bash
# 用 entryCSN 决定胜者（OpenLDAP 默认行为）
# 但有时业务希望"两边都保留"，则需要手工合并：

# 1. 从 m1 取该条目
ldapsearch -x ... "(uid=alice)" -b "..." > alice.m1.ldif
# 2. 从 m2 取
ldapsearch -x ... "(uid=alice)" -b "..." > alice.m2.ldif
# 3. diff 比较
diff alice.m1.ldif alice.m2.ldif

# 4. 与业务方确认要保留哪些字段，手工编辑成最终版
# 5. 在 m1 上 modify 写入最终版（其他节点会自动同步）
```

---

## 7. S6：TLS 证书全集群过期

### 7.1 现象

- 某天早上突然全部客户端报：
  ```
  TLS error: certificate has expired
  ```
- 监控也连不上 LDAP（因为它也走 LDAPS）

### 7.2 应急处理（30 分钟内回血）

```bash
# === 应急方案：客户端临时关 TLS 校验（业务先恢复）===
# 风险提示：MITM 风险，仅作为应急，必须在 1h 内换正式证书

# 1. SSSD 客户端
sed -i 's/ldap_tls_reqcert.*/ldap_tls_reqcert = allow/' /etc/sssd/sssd.conf
systemctl restart sssd

# 2. Hadoop 客户端：临时改用 ldap:// 明文（仅限内网且不允许超 1h）
# core-site.xml:
#   hadoop.security.group.mapping.ldap.url = ldap://...:389
#   hadoop.security.group.mapping.ldap.ssl = false

# 3. 同时启动正式签证流程
```

### 7.3 正式恢复 Runbook

```bash
# 1. 重签证书（CA 还有效）
cd /etc/openldap/certs
openssl req -new -key ldap-m1.key -out ldap-m1.csr \
  -subj "/CN=ldap-m1.bigdata.local" -config ldap-m1.cnf -extensions req_ext
openssl x509 -req -in ldap-m1.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out ldap-m1.crt -days 1825 -sha256 -extfile ldap-m1.cnf -extensions req_ext

# 2. 替换并重启
chown ldap:ldap *.crt *.key && chmod 600 *.key
systemctl restart slapd

# 3. 滚动其他节点

# 4. 客户端如果证书没更新 truststore 不用动；如果换了 CA 则要：
keytool -delete -alias bigdata-ldap-ca -keystore truststore.jks -storepass changeit
keytool -import -file ca.crt -alias bigdata-ldap-ca-2026 \
  -keystore truststore.jks -storepass changeit -noprompt

# 5. 验证
openssl s_client -connect ldap.bigdata.local:636 < /dev/null \
  | openssl x509 -dates -noout

# 6. 清理临时关 TLS 的客户端配置
```

### 7.4 强制预防（必做）

```bash
# 装 cron 提前 30 / 7 / 1 天告警
cat > /opt/scripts/cert-monitor.sh <<'EOF'
#!/bin/bash
for cert in /etc/openldap/certs/*.crt; do
  END=$(openssl x509 -enddate -noout -in $cert | cut -d= -f2)
  DAYS=$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))
  if [ $DAYS -lt 30 ]; then
    echo "$cert expires in $DAYS days"
    echo "$cert expires in $DAYS days" | mail -s "[P1] LDAP cert" sre@bigdata.local
  fi
done
EOF
echo "0 6 * * * /opt/scripts/cert-monitor.sh" >> /etc/crontab
```

更进一步：用 cert-manager / step-ca 自动化轮换，永远不靠人记。

---

## 8. S7：cn=config 损坏（数据完好但 slapd 不起）

### 8.1 现象

- slapd 启动报：
  ```
  config error processing olcDatabase={2}mdb,cn=config
  slap_init: bad configuration
  ```
- /var/lib/ldap 目录里 data.mdb 完好（dump 出来正常）

### 8.2 根因常见

1. 手工改 /etc/openldap/slapd.d/ 下的 ldif 文件（应改 cn=config 而非文件！）
2. ldif 文件中 olcAccess / olcSyncrepl 语法错
3. 模块加载顺序错（如 syncprov 引用了未加载的 accesslog）
4. 升级 OpenLDAP 版本，schema 不兼容

### 8.3 恢复步骤

```bash
# 1. 备份当前 cn=config（用于事后分析）
cp -r /etc/openldap/slapd.d /etc/openldap/slapd.d.broken.$(date +%s)

# 2. 看具体哪条配置出错
slapd -d 1 -F /etc/openldap/slapd.d 2>&1 | head -50
# 输出会指出某行某文件出错

# 3. 三选一恢复：

# 方案 A：从 git 恢复（如果配置纳管）
cd /etc/openldap/slapd.d && git checkout HEAD -- .

# 方案 B：从备份恢复 cn=config
slapadd -F /etc/openldap/slapd.d -n 0 -l /data/backup/config_20260509.ldif

# 方案 C：从其他健康节点 slapcat -n 0 + slapadd
ssh m2 "slapcat -F /etc/openldap/slapd.d -n 0" > /tmp/config.ldif
rm -rf /etc/openldap/slapd.d/*
slapadd -F /etc/openldap/slapd.d -n 0 -l /tmp/config.ldif

# 4. 启动
chown -R ldap:ldap /etc/openldap/slapd.d
systemctl start slapd
```

### 8.4 强制预防

```bash
# 把 cn=config 纳入 git
cd /etc/openldap/slapd.d
git init && git add . && git commit -m "baseline"

# 每次 ldapmodify cn=config 前，先做快照
slapcat -F . -n 0 > /tmp/config-before-change-$(date +%s).ldif
```

---

## 9. S8：备份本身坏了 / 恢复失败

### 9.1 现象

- 紧急恢复时发现 backup ldif 文件 gunzip 失败
- 或 slapadd 报 `attribute "createTimestamp" cannot have multiple values`
- 或恢复后数据缺一半

### 9.2 根因

1. **备份没校验**：脚本写完没 `gunzip -t` 验证完整性
2. **跨版本不兼容**：用 OpenLDAP 2.4 的 backup 在 2.6 上恢复
3. **schema 缺失**：恢复时新机没装 nis schema → posixAccount 条目全报 65
4. **磁盘静默错误（bit rot）**：备份文件本身在磁盘上慢慢坏了

### 9.3 应急方案

```bash
# 1. 试用所有可用备份点
for f in /data/backup/ldap/data_*.ldif.gz; do
  echo "Testing $f"
  gunzip -t "$f" && echo "OK" || echo "BROKEN"
done

# 2. 跨节点交叉验证
# 主备份点坏了 → 看 S3/HDFS/异地的副本

# 3. 用 accesslog 重放（如果 accesslog 没坏）
ldapsearch -x -D "cn=admin,cn=accesslog" -w ... -b "cn=accesslog" \
  "(reqResult=0)" > /tmp/replay.ldif
# 用脚本转换 reqType=add 为正常 LDIF 重新 add

# 4. 业务系统重建（最后手段）
# 用 HRIS 系统的全量员工列表，一行一行重新生成 LDIF
```

### 9.4 永久性预防

```bash
# 备份脚本必须包含三件套
slapcat ... > backup.ldif
gzip backup.ldif
gunzip -t backup.ldif.gz                                  # 1. 完整性
sha256sum backup.ldif.gz > backup.ldif.gz.sha256          # 2. 校验和
# 3. 异地：上传到 S3 / HDFS / 对端机房
hdfs dfs -put backup.ldif.gz /backup/ldap/

# 每周自动恢复演练（在测试环境）
0 3 * * 0 /opt/scripts/backup-restore-drill.sh
```

恢复演练脚本核心：
```bash
#!/bin/bash
# backup-restore-drill.sh
LATEST=$(ls -t /data/backup/ldap/data_*.ldif.gz | head -1)
docker run --rm -v $LATEST:/backup.gz osixia/openldap:latest \
  /bin/bash -c "gunzip -c /backup.gz | slapadd -F /etc/openldap/slapd.d"
[ $? -eq 0 ] && echo "Drill OK" || \
  mail -s "[P1] Backup drill FAILED" sre@bigdata.local
```

---

## 10. S9：单节点宕机（最常见，演练必考）

> 严格说这是 P2，但因为高频出现且是 DR 演练保留题，单独列出。

### 10.1 期望表现

- HAProxy 5 秒内检测到 down，自动剔除
- 客户端连接 1 次重试切到健康节点
- 业务**完全无感**

### 10.2 实操恢复

```bash
# 1. 看是物理 / OS / slapd 哪一层
# 2. 物理层：联系 IDC 重启 / 换硬件
# 3. OS 层：fsck / 换盘 / 重装
# 4. slapd 层：systemctl restart

# 5. 节点起来后，检查数据是否过时
ldapsearch -x ... -b "dc=..." -s base contextCSN
# 与主节点比对，差值 = 该节点宕期间错过的写

# 6. 如差值 > accesslog purge 时长 → 必须 slapadd 重建（见 §3 方案 A）
# 7. 如差值小 → 等 syncrepl 自动追上即可

# 8. 加回 LB
```

### 10.3 演练验证项

```
[ ] HAProxy 健康检查 5s 内剔除
[ ] 客户端无明显错误（最多 1 次重试）
[ ] 节点恢复后 syncrepl 自动追上
[ ] 监控告警准时（恰好 1 个 critical，没误报）
[ ] 大数据组件（HS2/Trino）无新增错误
```

---

## 11. 通用：备份恢复的"标准 SOP"（多个场景共用）

### 11.1 完整备份恢复流程

```bash
#!/bin/bash
# /opt/scripts/ldap-restore.sh
# 用法: ./ldap-restore.sh <backup_date>
# 例: ./ldap-restore.sh 20260509_020000

DATE=$1
BACKUP_DIR=/data/backup/ldap
SLAPD_DIR=/etc/openldap/slapd.d
DATA_DIR=/var/lib/ldap

# 1. 安全检查
[ -z "$DATE" ] && { echo "Usage: $0 <date>"; exit 1; }
[ ! -f "$BACKUP_DIR/data_${DATE}.ldif.gz" ] && { echo "Backup not found"; exit 1; }

# 2. 完整性校验
gunzip -t $BACKUP_DIR/data_${DATE}.ldif.gz || { echo "Backup corrupted"; exit 1; }

# 3. 二次确认（防误操作）
echo "=== 即将从 ${DATE} 恢复 LDAP ==="
echo "当前数据将被覆盖!"
read -p "确认输入 'yes-restore-ldap': " CONFIRM
[ "$CONFIRM" != "yes-restore-ldap" ] && { echo "Aborted"; exit 1; }

# 4. 停服
systemctl stop slapd
sleep 3

# 5. 备份当前现场（防恢复失败要回滚）
mv $DATA_DIR ${DATA_DIR}.before-restore.$(date +%s)
mv $SLAPD_DIR ${SLAPD_DIR}.before-restore.$(date +%s)
mkdir -p $DATA_DIR $SLAPD_DIR
chown ldap:ldap $DATA_DIR $SLAPD_DIR

# 6. 恢复 cn=config
gunzip -c $BACKUP_DIR/config_${DATE}.ldif.gz | \
  slapadd -F $SLAPD_DIR -n 0

# 7. 恢复数据
gunzip -c $BACKUP_DIR/data_${DATE}.ldif.gz | \
  slapadd -F $SLAPD_DIR -n 2

# 8. 权限
chown -R ldap:ldap $SLAPD_DIR $DATA_DIR

# 9. 启动 + 验证
systemctl start slapd
sleep 2
systemctl is-active slapd || { echo "FAILED to start"; exit 1; }

ldapwhoami -x -H ldaps://localhost \
  -D "cn=admin,dc=bigdata,dc=local" -w "$ADMIN_PWD" \
  || { echo "FAILED to bind"; exit 1; }

echo "✓ Restore SUCCESS"
echo "RPO: $(date -d "${DATE:0:8} ${DATE:9:2}:${DATE:11:2}:${DATE:13:2}")"
```

### 11.2 部分恢复（只恢复某个 OU）

```bash
# 1. 从全量备份提取
gunzip -c $BACKUP/data_20260509.ldif.gz \
  | awk 'BEGIN{RS=""; FS="\n"} /ou=People/' \
  > /tmp/people.ldif

# 2. 干净导入（已存在的会报错，先删后导）
ldapadd -x -D "cn=admin,..." -w ... -f /tmp/people.ldif -c
# -c 忽略已存在错误继续
```

### 11.3 时间点恢复（PITR）

OpenLDAP 不直接支持 PITR，但 accesslog 提供能力：
```
全量备份(02:00) + accesslog 重放(02:00 ~ 14:25) = 14:25 时点
```

实操脚本（节录）：
```bash
# 1. 恢复全量到 02:00
./ldap-restore.sh 20260509_020000

# 2. 提取 accesslog 中 02:00~14:25 的写操作
ldapsearch -x ... -b "cn=accesslog" \
  "(&(reqStart>=20260509020000.000000Z)(reqStart<=20260509142500.000000Z)(reqResult=0))" \
  > /tmp/replay.ldif

# 3. 用专门工具回放（业内有 slapd-meta + 自写脚本）
python3 replay-accesslog.py /tmp/replay.ldif
```

---

## 12. RTO/RPO 与场景对照表

| 场景 | 检测 (MTTD) | 恢复 (MTTR) | 数据丢失 (RPO) | 优先级 |
|------|----------|----------|-------------|--------|
| S1 全节点宕 | <2min | 15~30min | 0（同步主已停） | P0 |
| S2 mdb 损坏 | <5min | 15min | 0（其他副本完好） | P0 |
| S3 误删全树 | <5min | 30~60min | 取决于备份 (≤1h) | P0 |
| S4 入侵 | 看 SIEM | 4~24h | 取决于污染时间点 | P0 |
| S5 双主脑裂 | <10min | 30min | 可能少量冲突 | P1 |
| S6 证书过期 | 应提前 30 天 | 1h | 0 | P1 |
| S7 cn=config 损坏 | <5min | 15min | 0 | P1 |
| S8 备份失效 | 演练发现 | 看业务 | 大 | P1 |
| S9 单节点宕 | <30s | 5min | 0 | P2 |
| S10 复制中断 | <1h | 30min | 0（追上即可） | P2 |

---

## 13. 演练矩阵（季度必跑）

| 演练编号 | 场景 | 频率 | 通过标准 |
|---------|------|------|---------|
| DR-01 | 主节点 panic | 月 | RTO < 30s 切换 |
| DR-02 | 整机房断网 | 季 | 跨机房切换 RTO < 5min |
| DR-03 | 数据损坏全节点 | 季 | 备份恢复 < 30min |
| DR-04 | 误删演练（沙箱） | 季 | accesslog 反向恢复 |
| DR-05 | 证书过期模拟 | 半年 | 应急 + 正式恢复 < 1h |
| DR-06 | 双主脑裂 | 半年 | 强制收敛 < 30min |
| DR-07 | 备份恢复演练 | 周 | 自动化跑通 |
| DR-08 | 双盲攻防 | 年 | 安全团队 + SRE 联演 |

### 13.1 演练执行模板

```
预案：
  - 时间窗口
  - 受影响范围
  - 通报对象
  - 回滚方案

演练步骤：
  T+0    : 制造故障
  T+1min : 等待告警
  T+x    : 值班人员介入（不预先告知场景！）
  T+y    : 恢复完成
  T+y+15 : 评审会议

通过标准：
  - MTTD < SLA
  - MTTR < SLA
  - 业务影响范围 < 预期
  - 客户端无数据丢失

输出物：
  - 演练报告（含时间线）
  - Runbook 修订
  - 监控/告警规则补丁
```

---

## 14. 故障复盘模板（事件后 24h 内必产出）

```markdown
# LDAP 故障复盘 - <故障编号 INC-YYYYMMDD-NNN>

## 1. 故障概况
- 时间窗口: 2026-05-09 14:30 ~ 15:05 (35 min)
- 等级: P0
- 影响范围: 全集群 HS2/Trino 新连接失败约 25 分钟
- 恢复人: Eric, A, B
- 故障编号: INC-20260509-001

## 2. 时间线
| 时间 | 事件 | 处理人 |
|------|------|--------|
| 14:30:12 | Alertmanager 报 LDAPDown | (auto) |
| 14:31:00 | SRE 群响应，@豹纹接单 | Eric |
| 14:33:00 | 登录确认全部 LDAP slapd 进程都 OOM Killed | Eric |
| 14:35:00 | 启动 Runbook S1，检查内存使用历史 | Eric |
| 14:40:00 | 发现连接数从 5k 飙升到 20k（客户端泄漏） | Eric |
| 14:45:00 | 临时调整 slapd 最大连接数 + 重启 | A |
| 14:50:00 | LDAP m1 起来，HAProxy 切流量 | A |
| 15:00:00 | 全节点恢复 | A |
| 15:05:00 | 业务验证通过 | B |

## 3. 根因
直接原因: HS2 升级到 4.0.0 后引入连接池泄漏 bug
深层原因: LDAP 没限制单客户端最大连接数，单点失效扩大成集群故障
根本原因: 监控只看 LDAP 是否 alive，没看连接数趋势 → 没提前预警

## 4. 改进项
| 编号 | 改进项 | 负责人 | 截止 |
|------|-------|--------|------|
| AC-01 | LDAP 加 olcConnMaxPending 限制 | Eric | 5/12 |
| AC-02 | 监控加连接数趋势告警 | A | 5/15 |
| AC-03 | HS2 回滚到 3.x 或修 bug | B | 5/20 |
| AC-04 | 演练 DR-01 增加"客户端泄漏"场景 | Eric | 6/30 |

## 5. 经验教训
- 单点保护不能只防自己挂，还要防客户端把自己打挂
- 监控指标需要趋势预警，而非阈值预警
- 大数据组件升级必须经过 LDAP 压测
```

---

## 15. 应急联系卡（贴墙上）

```
LDAP 紧急情况联系顺序：
1. SRE 值班手机:  138-XXXX-XXXX
2. SRE Lead:     豹纹（Eric）
3. 网络团队:      网络运维群（钉钉）
4. 安全团队:      仅 P0/入侵场景
5. 老板:          P0 30 分钟未恢复时

应急资料位置：
- Runbook (本文档): /opt/runbook/ldap/
- 备份位置:        s3://bigdata-backup/ldap/ 和 hdfs:///backup/ldap/
- 配置 git 仓库:   git@internal.corp:bigdata/ldap-config.git
- 监控大盘:        https://grafana.bigdata.local/d/ldap
- 应急用 LDIF 模板: /opt/runbook/ldap/templates/

紧急命令清单：
- 一键状态: bash /opt/runbook/ldap/emergency-status.sh
- 一键恢复: bash /opt/runbook/ldap/restore.sh <date>
- 一键演练: bash /opt/runbook/ldap/drill.sh <scenario>
```

---

## 16. 与 04 排障篇的协同使用

```
单点小问题 (认证错、慢查询、TLS 错)
    │
    ▼
查 04 排障篇 → 找 Case → 修复
    │
    ▼ 修复失败/范围扩大
查 05 故障恢复篇 → 走 Runbook → 止血优先

灾难性事件 (全挂、误删、入侵)
    │
    ▼
直接走 05 → 不要在 04 里浪费时间
```

---

> 📌 上一篇：04-LDAP常见问题排障 | 主索引：README.md  
> 推荐配套阅读：03-§9 灾难演练章节、03-§4 备份与恢复章节
