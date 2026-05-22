# LDAP 数据治理与灾备演练专题

> 作者：Eric（豹纹）| 配套：00~05 系列  
> 主题：**数据**这条命脉的全生命周期管理 —— 防丢失、丢了能恢复、平时管得住、定期演得动

---

## 0. 这篇专题为什么单独写？

前面的章节中，"数据"散落在多处：
- 03-§4 讲过备份恢复
- 04-§6 讲过数据问题（schema/编码）
- 05-§3/§4/§9 讲过几种灾难下的数据恢复

但缺一份**站在"数据"这条命脉上**的全景图。本篇按"4 个动词"组织：

```
        ┌────────────────────────────────────┐
        │           数据生命周期                │
        │                                    │
        │  防(Prevention)                    │
        │     ↓ 还是丢了                       │
        │  救(Recovery)                       │
        │     ↓ 救完归位                       │
        │  管(Governance)                    │
        │     ↓ 不出事不算赢                    │
        │  演(Drill)                          │
        │     ↑ 反复淬炼                       │
        └────────────────────────────────────┘
```

**核心理念**（Eric 大哥经验）：
1. **能不丢就不丢**（90% 投入在防）
2. **丢了能找回**（5% 投入在救，但救的时候必须 100% 可靠）
3. **管得住才能保证防有效**（5% 在数据治理）
4. **演练是唯一让"防+救+管"持续生效的方式**

---

## 1. 第一篇章：防（Prevention）—— 别让数据丢

### 1.1 数据丢失的 6 大根因（按发生概率排序）

| 排名 | 根因 | 发生概率 | 影响范围 |
|------|------|---------|---------|
| 🥇 #1 | **人为误操作**（rm/ldapdelete/Studio 拖错）| 60% | 单条~整树 |
| 🥈 #2 | **应用 Bug**（脚本写错条件、批处理事务错）| 20% | 部分子树 |
| 🥉 #3 | **硬件故障**（磁盘坏、电池没电、内存 ECC 错）| 10% | 单节点 |
| 4 | **配置失误**（accesslog purge 太狠、备份目录被清）| 5% | 部分历史 |
| 5 | **入侵/勒索**（外部攻击）| 3% | 全部 |
| 6 | **不可抗力**（机房失火、双路掉电）| 2% | 全部 |

**结论**：80% 的数据丢失是"自己人"造成的。所以"防"的重点不是堆硬件，而是 **流程 + 权限 + 自动化兜底**。

### 1.2 防御纵深（Defense in Depth）—— 7 层保护网

```
┌─────────────────────────────────────────────────────────┐
│ L7: 业务侧账本（HRIS / IDM / Excel 全员表）              │  最终兜底
├─────────────────────────────────────────────────────────┤
│ L6: 异地容灾备份（S3 / 异地 HDFS / 对端机房）            │  抗机房级灾难
├─────────────────────────────────────────────────────────┤
│ L5: 全量定时备份（每天 2 点 slapcat → 压缩 → 多副本）    │  抗误删
├─────────────────────────────────────────────────────────┤
│ L4: 增量日志（accesslog overlay，可回放/可反推）         │  抗误改
├─────────────────────────────────────────────────────────┤
│ L3: 复制副本（MMR/Master-Slave，3 节点起）               │  抗节点宕
├─────────────────────────────────────────────────────────┤
│ L2: ACL 删除保护（顶层 dn 不允许任何人删）               │  抗误删
├─────────────────────────────────────────────────────────┤
│ L1: 操作流程（双人复核 + 工单 + 软删除策略）             │  抗手抖
└─────────────────────────────────────────────────────────┘
                         ↑
                    数据本身
```

**任何单层失效都不会丢数据**，这才叫纵深。

### 1.3 L1 操作层：手抖防御

#### 1.3.1 软删除强制策略

**铁律**：**禁止使用 `ldapdelete` 直接删生产数据**。改用 `modrdn` 移到 `ou=Disabled`：

```bash
# 创建禁用 OU（一次性）
ldapadd -x -D "cn=admin,..." -W <<EOF
dn: ou=Disabled,dc=bigdata,dc=local
objectClass: organizationalUnit
ou: Disabled
description: 软删除回收站（保留 90 天）
EOF

# 把 alice "删除" → 实际是搬到 Disabled
cat <<EOF | ldapmodify -x -D "cn=admin,..." -W
dn: uid=alice,ou=People,dc=bigdata,dc=local
changetype: modrdn
newrdn: uid=alice
deleteoldrdn: 0
newsuperior: ou=Disabled,dc=bigdata,dc=local

dn: uid=alice,ou=Disabled,dc=bigdata,dc=local
changetype: modify
replace: loginShell
loginShell: /sbin/nologin
-
add: pwdAccountLockedTime
pwdAccountLockedTime: 000001010000Z
-
add: description
description: Disabled at $(date -Iseconds), by ${USER}, ticket=TKT-XXX
EOF
```

#### 1.3.2 客户端工具上的"刹车"

```bash
# 所有 admin 工作站 ~/.bashrc
alias ldapdelete='echo "❌ 禁止直接删除！请走软删除工单。如确需 hard delete，使用 ldapdelete-real" && false'
alias ldapdelete-real='/usr/bin/ldapdelete'   # 真实命令藏起来，故意让人多敲

# 高危命令二次确认
ldapsafe() {
  echo "你即将执行: ldapmodify $@"
  read -p "确认请输入 yes-modify: " c
  [ "$c" = "yes-modify" ] && /usr/bin/ldapmodify "$@"
}
alias ldapmodify=ldapsafe
```

#### 1.3.3 工单驱动 + 双人复核（人事 / SOX 合规要求）

```
[用户/组] 变更流程：
1. 申请人提工单（含变更内容、生效时间、回滚方案）
2. 主管审批
3. SRE A 操作（生成 LDIF）
4. SRE B 复核（diff 对比）
5. 灰度执行（先一个节点 / 一条 OU）
6. 验证后全量
7. 工单关闭 + 7 天观察
```

**所有操作必须在 git 仓库留痕**：
```bash
git clone git@internal:ldap-changes.git
cd ldap-changes
mkdir -p $(date +%Y/%m/%d)/TKT-XXX
cp /tmp/change.ldif $(date +%Y/%m/%d)/TKT-XXX/
git add . && git commit -m "TKT-XXX: 新增 charlie@..."
git push
# 之后才执行 ldapadd
ldapadd -x -D "cn=admin,..." -W -f /tmp/change.ldif
```

### 1.4 L2 ACL 层：顶层删除保护

```ldif
dn: olcDatabase={2}mdb,cn=config
changetype: modify
add: olcAccess
# 顶层 Suffix 完全禁删 / 禁改（除了 cn=config 内核管理员）
olcAccess: {0}to dn.exact="dc=bigdata,dc=local" attrs=entry
  by * read
  by * +0 break

# 顶层 OU 删除保护
olcAccess: {1}to dn.regex="^ou=(People|Groups|Services|Disabled),dc=bigdata,dc=local$" attrs=entry
  by group/groupOfNames/member.exact="cn=ldap-superadmins,ou=Groups,dc=bigdata,dc=local" write
  by * read

# 普通 admin 只能改子条目，不能删 OU
```

**测试**：
```bash
slapacl -D "uid=alice-admin,ou=People,..." \
  -b "ou=People,dc=bigdata,dc=local" entry/delete
# 应输出：=0   ← 拒绝
```

### 1.5 L3 复制层：N+1 部署 + 时钟严格同步

参考 01-§4 配置 MMR。补充几条**防丢失**专属规则：

```bash
# 1. 节点数 = N+1（生产至少 3 个，2 个机房）
# 2. NTP 必须 chrony 严格同步（差 100ms 必出问题）
chronyc tracking | awk '/RMS offset/{print $4}'   # 应 < 0.001 秒

# 3. 关键：accesslog 不能 purge 太狠
#    至少保留 7 天（覆盖周末故障未及时发现的窗口）
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" \
  "(olcOverlay=accesslog)" olcAccessLogPurge
# 推荐：olcAccessLogPurge: 07+00:00 01+00:00 （保留7天，每天purge一次）
```

**关键警告**：从节点不要长期处于"网络不通"状态，否则其上的数据可能被复制流"重放抹除"。如果某节点要下线 >7 天，应该先解除 syncrepl 配置。

### 1.6 L4 增量日志：accesslog 必装

accesslog overlay 是 OpenLDAP 自带的"操作录像机"，记下每个写操作的**前像和后像**。

```ldif
# 启用（详见 01-§4.1.2）
dn: olcOverlay=accesslog,olcDatabase={2}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcAccessLogConfig
olcOverlay: accesslog
olcAccessLogDB: cn=accesslog
olcAccessLogOps: writes              # 记所有 add/modify/delete/modrdn
olcAccessLogSuccess: TRUE
olcAccessLogPurge: 07+00:00 01+00:00 # 7天保留
olcAccessLogOld: (objectclass=*)     # 记完整前像（关键！）
olcAccessLogOldAttr: *               # 所有属性
```

**accesslog 的价值**：
- 删了能恢复（reqOld 含完整前像）
- 改了能回退（reqOld + reqMod 可计算反操作）
- 审计：谁、什么时候、改了什么，一查就知道

```bash
# 看最近 1 小时所有写操作
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(&(reqStart>=$(date -u -d '1 hour ago' +%Y%m%d%H%M%S).000000Z)(reqResult=0))" \
  reqStart reqType reqDN reqAuthzID
```

### 1.7 L5 全量备份：3-2-1 原则

**3-2-1 原则**（业内黄金标准）：
- **3** 份数据副本（含原始）
- **2** 种存储介质（本地盘 + S3，或本地 + HDFS）
- **1** 份异地（不同机房 / 不同 region）

#### 1.7.1 完整备份脚本（生产级）

```bash
#!/bin/bash
# /opt/scripts/ldap-backup.sh
# 跑在主节点 cron，每天 02:00

set -euo pipefail

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=/data/backup/ldap
LOG=/var/log/ldap-backup.log
SLAPD_DIR=/etc/openldap/slapd.d

mkdir -p $BACKUP_DIR

log() { echo "[$(date -Iseconds)] $*" | tee -a $LOG; }
fail() { log "FAIL: $*"; mail -s "[P0] LDAP backup FAIL" sre@bigdata.local <<<"$*"; exit 1; }

log "=== Backup start ==="

# 1. 配置（cn=config）
log "1/6 Backup cn=config"
slapcat -F $SLAPD_DIR -n 0 -l $BACKUP_DIR/config_${DATE}.ldif \
  || fail "slapcat config"

# 2. 主数据（mdb）
log "2/6 Backup main DB"
slapcat -F $SLAPD_DIR -n 2 -l $BACKUP_DIR/data_${DATE}.ldif \
  || fail "slapcat data"

# 3. accesslog（DR 用，含完整写历史）
log "3/6 Backup accesslog"
slapcat -F $SLAPD_DIR -n 3 -l $BACKUP_DIR/accesslog_${DATE}.ldif \
  || fail "slapcat accesslog"

# 4. 证书 + cn=config 文件本身
log "4/6 Backup certs and slapd.d"
tar czf $BACKUP_DIR/certs_${DATE}.tgz /etc/openldap/certs /etc/openldap/slapd.d \
  || fail "tar certs"

# 5. 压缩 + 校验
log "5/6 Compress and checksum"
for f in config data accesslog; do
  gzip $BACKUP_DIR/${f}_${DATE}.ldif
  sha256sum $BACKUP_DIR/${f}_${DATE}.ldif.gz > $BACKUP_DIR/${f}_${DATE}.ldif.gz.sha256
  gunzip -t $BACKUP_DIR/${f}_${DATE}.ldif.gz || fail "verify $f"
done

# 6. 异地（HDFS + S3）—— 3-2-1 第二份和第三份
log "6/6 Replicate to HDFS + S3"
hdfs dfs -mkdir -p /backup/ldap/$(date +%Y/%m)
hdfs dfs -put $BACKUP_DIR/*_${DATE}.* /backup/ldap/$(date +%Y/%m)/ \
  || fail "hdfs put"

aws s3 sync $BACKUP_DIR/ s3://bigdata-dr-backup/ldap/ \
  --exclude "*" --include "*_${DATE}.*" \
  || fail "s3 sync"

# 7. 保留策略（本地 30 天，S3/HDFS 365 天）
find $BACKUP_DIR -name "*_*.gz" -mtime +30 -delete
find $BACKUP_DIR -name "*.tgz" -mtime +30 -delete

# 8. 通知
SIZE=$(du -sh $BACKUP_DIR/data_${DATE}.ldif.gz | cut -f1)
log "✓ Backup OK, size=$SIZE"
echo "$DATE size=$SIZE OK" | curl -s -X POST -d @- https://wecom-bot/key/xxx
```

#### 1.7.2 备份的 4 项验收标准

```
[ ] gunzip -t 通过        ← 完整性
[ ] sha256 校验对得上     ← 一致性
[ ] 异地有副本           ← 可达性
[ ] 演练能恢复           ← 可用性 ★最重要
```

**只满足前 3 项是"备份的幻觉"** —— 业界很多公司就栽在第 4 项。详见 §4 演练章节。

### 1.8 L6 异地容灾：跨机房 / 跨 Region

```
机房 A                           机房 B
├── ldap-m1 (写主)             ├── ldap-m3 (写主，MMR)
├── ldap-m2 (写主)             ├── ldap-r2 (只读)
├── ldap-r1 (只读)             └── 备份存储
└── 备份存储
        │                              │
        └────────── S3 异地 ──────────┘
                  (季度对账)
```

**机房间通信要求**：
- 网络延迟 < 50ms（MMR 才稳）
- 专线 / VPN，加密
- 防火墙只允许 LDAPS 636 + replicator 账号

### 1.9 L7 业务侧账本：最终兜底

LDAP 永远不该是"唯一数据源"。**LDAP 的源头应该是 HRIS / IDM**：

```
HRIS（人事系统）       <-- 真理之源
   ↓ 每天同步一次
IDM（身份管理系统）    <-- 加工层
   ↓ 同步
LDAP                 <-- 大数据集群消费层
```

哪怕 LDAP 整库丢失，理论上可以从 HRIS 重新拉一遍。这是**最后的保险**。

---

## 2. 第二篇章：救（Recovery）—— 真丢了怎么找回

### 2.1 数据丢失分类与对应恢复方案矩阵

| 丢失场景 | 严重等级 | 首选方案 | 备选方案 | 兜底方案 |
|---------|---------|---------|---------|---------|
| 删了一条用户 | P3 | accesslog 反向 | 备份提取单条 | 业务侧重建 |
| 删了一个 OU（百条以下）| P2 | accesslog 反向 | 备份恢复 OU 子树 | HRIS 重建 |
| 改错了密码字段 | P3 | accesslog 取 reqOld | 备份取旧密码哈希 | 用户走重置流程 |
| 误删整棵树 | P0 | accesslog 反向（5min 内）| 全量备份恢复 | HRIS 全量重建 |
| mdb 文件损坏 | P0 | 从健康节点 slapcat | 备份恢复 | HRIS 全量重建 |
| 全节点数据全损 | P0 | 异地备份恢复 | HDFS 副本 | HRIS 全量重建 |
| 备份本身坏了 | P0 | 上一份备份 | accesslog 重放 | HRIS 全量重建 |

### 2.2 救援第一原则：**STOP & FREEZE**

发现数据丢失的瞬间：

```
T+0   : 喊"STOP！"，大声喊出来
T+5s  : 立即 systemctl stop slapd（防止删除被同步）
        在所有节点执行！
T+30s : 开应急会议（电话/钉钉群）
T+1min: 评估：删除发生时间 / 范围 / 是否已同步
T+2min: 决定走哪条恢复路径
T+5min: 开始恢复
```

**为什么先 STOP？**
- 防止误删被同步到从节点（M-MR 是双向的，从节点的"未删"可以救主节点）
- 防止后续写入污染恢复点（写一条覆盖 accesslog purge 阈值就麻烦了）
- 给 SRE 思考时间（人在慌乱中容易做出更糟糕的决定）

### 2.3 黄金路径 1：accesslog 反向恢复（最快）

**适用**：误删/误改发生在 accesslog 保留期内（默认 7 天）。

#### 2.3.1 找到误操作

```bash
# 找最近 1 小时所有 delete
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(&(reqType=delete)(reqStart>=$(date -u -d '1 hour ago' +%Y%m%d%H%M%S).000000Z))" \
  reqStart reqDN reqAuthzID

# 输出例：
# reqStart: 20260510140523.123456Z
# reqDN: ou=People,dc=bigdata,dc=local       ← 这是被删的
# reqAuthzID: dn:cn=admin,dc=bigdata,dc=local ← 谁干的
```

#### 2.3.2 提取被删条目的完整数据

```bash
# 关键：reqOld 字段含被删条目的所有属性
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(&(reqType=delete)(reqDN=ou=People,dc=bigdata,dc=local))" \
  reqDN reqOld

# 输出例（截取）：
# reqDN: ou=People,dc=bigdata,dc=local
# reqOld: objectClass: organizationalUnit
# reqOld: ou: People
# reqOld: description: ...
```

#### 2.3.3 转换 reqOld 为可导入的 LDIF

```python
#!/usr/bin/env python3
# accesslog-reverse.py
# 用法: ldapsearch ... | python3 accesslog-reverse.py > restore.ldif

import sys

current_dn = None
output = []

for line in sys.stdin:
    line = line.rstrip('\n')
    if line.startswith('reqDN: '):
        current_dn = line[7:]
    elif line.startswith('reqOld: '):
        if current_dn:
            output.append(f'dn: {current_dn}')
            current_dn = None
        output.append(line[8:])
    elif line == '' and current_dn is None and output and output[-1] != '':
        output.append('')

print('\n'.join(output))
```

```bash
# 走一遍
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(&(reqType=delete)(reqDN=ou=People,dc=bigdata,dc=local))" \
  reqDN reqOld | python3 accesslog-reverse.py > /tmp/restore.ldif

# 检查 LDIF
less /tmp/restore.ldif

# 导入
ldapadd -x -D "cn=admin,..." -W -f /tmp/restore.ldif
```

#### 2.3.4 误改恢复（取 reqOld 替换当前值）

```bash
# 找 modify 操作
ldapsearch ... -b "cn=accesslog" \
  "(&(reqType=modify)(reqDN=uid=alice,ou=People,...)(reqStart>=...))" \
  reqMod reqOld

# reqOld 是改前的值，写一条 modify 替换回去：
cat <<EOF | ldapmodify ...
dn: uid=alice,ou=People,dc=bigdata,dc=local
changetype: modify
replace: mail
mail: <从reqOld提取的旧值>
EOF
```

### 2.4 黄金路径 2：备份恢复（accesslog 不够用时）

#### 2.4.1 部分恢复（只恢复一个 OU / 一组用户）

```bash
# 1. 找最近的备份
LATEST=$(ls -t /data/backup/ldap/data_*.ldif.gz | head -1)
gunzip -c $LATEST > /tmp/full.ldif

# 2. 用 awk 提取目标子树（按 DN 后缀过滤）
awk '
  BEGIN { RS=""; FS="\n" }
  /^dn:.*ou=People,dc=bigdata,dc=local/ { print; print "" }
' /tmp/full.ldif > /tmp/people.ldif

# 或更精准：按特定 DN
awk '
  BEGIN { RS=""; FS="\n"; want="uid=alice,ou=People,dc=bigdata,dc=local" }
  $1 ~ "^dn: " want { print; print "" }
' /tmp/full.ldif > /tmp/alice.ldif

# 3. 导入（已存在条目跳过 -c，否则会因 entryAlreadyExists 中断）
ldapadd -x -D "cn=admin,..." -W -f /tmp/people.ldif -c
```

#### 2.4.2 全量恢复

详见 05-§11.1 完整 SOP。核心两步：

```bash
systemctl stop slapd
mv /var/lib/ldap /var/lib/ldap.before-restore.$(date +%s)
mkdir /var/lib/ldap && chown ldap:ldap /var/lib/ldap

gunzip -c /data/backup/ldap/data_20260510_020000.ldif.gz \
  | slapadd -F /etc/openldap/slapd.d -n 2

chown -R ldap:ldap /var/lib/ldap
systemctl start slapd
```

### 2.5 时间点恢复（PITR, Point-In-Time Recovery）

**目标**：恢复到 14:25 这个时刻的状态（02:00 备份 + 02:00~14:25 的写日志）。

```bash
# 1. 全量恢复到 02:00
./ldap-restore.sh 20260510_020000

# 2. 提取 02:00 ~ 14:25 的写操作
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(&(reqStart>=20260510020000.000000Z)(reqStart<=20260510142500.000000Z)(reqResult=0))" \
  > /tmp/replay.txt

# 3. 转换为 LDIF（脚本节录，实际工程要更完整）
python3 accesslog-replay.py /tmp/replay.txt > /tmp/replay.ldif

# 4. 顺序回放
ldapmodify -x -D "cn=admin,..." -W -f /tmp/replay.ldif
```

**注意**：accesslog 重放比单纯 add 复杂得多，因为含 modify/delete/modrdn 各种操作类型，需要按 reqType 分别处理。本团队有一个开源工具仓库 `ldap-pitr-tool`（待补）。

### 2.6 业务兜底路径：从 HRIS 全量重建

**适用场景**：备份全坏 + accesslog 也没了（极端情况）。

```bash
# 1. 从 HRIS 拉员工列表（CSV/JSON）
curl https://hris-api.corp/api/employees > employees.json

# 2. 转 LDIF
python3 hris-to-ldif.py employees.json > /tmp/rebuild.ldif

# 3. 重建（密码字段无法从 HRIS 取，先设临时密码 + 强制首次登录改）
ldapadd -x -D "cn=admin,..." -W -f /tmp/rebuild.ldif

# 4. 触发用户改密邮件
python3 send-reset-emails.py employees.json
```

**关键**：HRIS 同步链路平时就要保证可用，否则灾难时它也指望不上。

### 2.7 数据救援验收清单

恢复后必做这些验证（少一项都不能宣布"已恢复"）：

```
[ ] systemctl is-active slapd            （服务起来了）
[ ] ldapwhoami -x ... 管理员能 bind      （ACL 正确）
[ ] 抽 5 个用户能 bind 成功              （密码哈希完好）
[ ] 抽 3 个组 memberUid 完整             （组成员关系完整）
[ ] contextCSN 与其他副本一致            （复制健康）
[ ] HS2 / Trino / Hue 能 LDAP 登录      （集成可用）
[ ] HDFS hdfs groups alice 能查         （组解析可用）
[ ] 用户数对账（与 HRIS 对比，差异 < 1%）  （数据完整）
[ ] /var/log/slapd.log 无 ERR / FAIL    （无次生故障）
[ ] 24 小时观察期内无异常                （稳定）
```

---

## 3. 第三篇章：管（Governance）—— 数据治理

### 3.1 数据治理 5 大要素

```
1. 数据质量    （Quality）   —— 准、全、新
2. 数据血缘    （Lineage）   —— 从哪来，到哪去
3. 数据权限    （Access）    —— 谁能看、谁能改
4. 数据生命周期 （Lifecycle） —— 从入职到离职
5. 数据合规    （Compliance）—— GDPR / SOX / 等保
```

### 3.2 数据质量：准、全、新

#### 3.2.1 准（Accuracy）—— 与 HRIS 对账

每天自动对账脚本：

```bash
#!/bin/bash
# /opt/scripts/ldap-hris-recon.sh

# 1. 拉 HRIS 员工列表
curl -s https://hris-api.corp/api/employees \
  | jq -r '.[] | .uid' | sort > /tmp/hris-uids.txt

# 2. 拉 LDAP 用户列表
ldapsearch -x -D ... -w ... -b "ou=People,dc=bigdata,dc=local" \
  "(objectClass=posixAccount)" uid \
  | grep "^uid:" | awk '{print $2}' | sort > /tmp/ldap-uids.txt

# 3. 三方比对
echo "=== HRIS 有 LDAP 没（漏建）==="
comm -23 /tmp/hris-uids.txt /tmp/ldap-uids.txt

echo "=== LDAP 有 HRIS 没（应离职未删）==="
comm -13 /tmp/hris-uids.txt /tmp/ldap-uids.txt

echo "=== 双方都有 ==="
comm -12 /tmp/hris-uids.txt /tmp/ldap-uids.txt | wc -l

# 4. 偏差超阈值告警
DIFF=$(comm -3 /tmp/hris-uids.txt /tmp/ldap-uids.txt | wc -l)
[ $DIFF -gt 10 ] && \
  mail -s "[P2] LDAP-HRIS recon diff=$DIFF" sre@bigdata.local
```

cron：每天 03:00 跑（备份后 1 小时）。

#### 3.2.2 全（Completeness）—— 必填属性体检

```bash
# 找出缺关键属性的"残缺条目"
ldapsearch -x ... -b "ou=People,..." \
  "(&(objectClass=posixAccount)(|(!(mail=*))(!(uidNumber=*))(!(homeDirectory=*))))" \
  uid mail uidNumber homeDirectory

# 找出 uidNumber 重复的（POSIX 严重错误）
ldapsearch -x ... -b "ou=People,..." \
  "(objectClass=posixAccount)" uidNumber \
  | grep "^uidNumber:" | awk '{print $2}' | sort | uniq -d
```

#### 3.2.3 新（Freshness）—— 长期不活跃账号清理

```bash
# 找出 90 天没改密码的（可能是僵尸号）
NINETY_DAYS_AGO=$(date -d '90 days ago' +%Y%m%d000000Z)
ldapsearch -x ... -b "ou=People,..." \
  "(&(objectClass=posixAccount)(pwdChangedTime<=${NINETY_DAYS_AGO}))" \
  uid pwdChangedTime

# 推送提醒邮件 → 30 天后仍不活跃 → 自动 disable（移到 ou=Disabled）
```

### 3.3 数据血缘：变更可追溯

```
HRIS 改 alice 邮箱
   │
   ▼ Webhook
IDM 调度 sync 任务
   │
   ▼ ldapmodify
LDAP 更新 mail 字段
   │
   ▼ accesslog 记录
   │ (含变更前后值 + 时间 + 操作者)
   ▼
Ranger UserSync 增量拉
   │
   ▼
Ranger 用户档案更新
```

**关键追溯链**：
- accesslog: `reqAuthzID`（who） + `reqStart`（when） + `reqDN`（what） + `reqMod`（how）
- 应用层日志：HRIS 工单号 → IDM 同步任务号 → LDAP modify 时间戳 → 各组件感知时间

### 3.4 数据权限：最小权限 + 定期审计

#### 3.4.1 角色分层

```
┌─────────────────────────────────────────┐
│  cn=root,cn=config（OpenLDAP 内部超管）  │  仅紧急时用
├─────────────────────────────────────────┤
│  cn=admin,dc=bigdata,...（业务超管）    │  日常变更
├─────────────────────────────────────────┤
│  ldap-superadmins 组                    │  能改 ACL/Schema
├─────────────────────────────────────────┤
│  ldap-admins 组                          │  能加用户/组
├─────────────────────────────────────────┤
│  cn=readonly,ou=Services（只读账号）     │  组件用
├─────────────────────────────────────────┤
│  普通用户                                │  改自己密码 / 读公开属性
└─────────────────────────────────────────┘
```

ACL 配置参考 03-§3。

#### 3.4.2 月度权限审计

```bash
# 1. 列出所有有写权限的用户
ldapsearch -Y EXTERNAL -H ldapi:/// -b "cn=config" \
  "(olcAccess=*)" olcAccess \
  | grep -E "by .* write"

# 2. 列出 admin 组成员（应严控数量）
ldapsearch ... -b "cn=ldap-admins,ou=Groups,..." memberUid

# 3. 看 90 天内执行写操作的所有人
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(reqStart>=$(date -d '90 days ago' +%Y%m%d000000Z))" \
  reqAuthzID | sort -u

# 4. 异常账号自动检查
# - 管理员账号是否有"未在白名单"的来源 IP？
# - 服务账号是否做了"非业务正常"的写操作？
```

### 3.5 数据生命周期：员工入离职流程

```
入职:
    HRIS 入职单
       ↓
    IDM 自动建账号
       ↓
    LDAP 创建 uid + 默认组 + 临时密码
       ↓
    邮件通知员工 + 强制首次登录改密
       ↓
    7 天观察期，未首次登录 → 提醒 HR

转岗:
    HRIS 转岗单
       ↓
    IDM 调整组成员关系
       ↓
    LDAP 移除旧组 memberUid + 加入新组
       ↓
    Ranger 权限自动同步（5 分钟内）

离职:
    HRIS 离职日 T-7
       ↓
    自动锁密码（pwdAccountLockedTime）
       ↓
    T+0 软删除（移到 ou=Disabled）
       ↓
    T+90 硬删除 + accesslog 永久归档
       ↓
    审计：该员工所有数据操作历史归档到 cold storage
```

### 3.6 合规与审计

#### 3.6.1 GDPR / 个人信息保护

```
要求               | LDAP 实现
───────────────────┼─────────────────────────────
最小化收集         | Schema 只放业务必需字段
访问控制           | ACL + 审计日志
被遗忘权           | 离职 + 90 天硬删除 + accesslog 归档
数据可携带         | slapcat 导出 LDIF + 转 JSON
告知义务           | 注册时勾选 + 隐私政策链接
泄漏通知           | SIEM 触发 → 72h 内报告
```

#### 3.6.2 SOX 合规（金融场景）

要点：
- 所有写操作必须双人复核
- 日志保留 ≥ 7 年
- 季度访问 review（手动签字确认）
- 年度第三方审计

#### 3.6.3 等保 2.0 三级（国内）

要点：
- 身份鉴别用 LDAP（已是默认）
- 访问控制颗粒度（每个 ou 独立 ACL）
- 安全审计（auditlog 接 SIEM 实时）
- 入侵防范（fail2ban + 弱密码扫描）
- 可信验证（slapd 启动签名校验）

---

## 4. 第四篇章：演（Drill）—— 故障演练全套

### 4.1 演练的意义（为什么必须做）

> "未演练的备份 = 没备份；未演练的 Runbook = 废纸"  
> —— Eric 大哥铁律

业内悲剧案例：
- 某大厂备份做了 5 年，灾难时发现备份脚本 3 年前就开始报错（没人看告警）
- 某金融客户文档完美，演练时发现密码写文档里就忘了改，被审计扣分
- 某互联网公司每月演练，所以重大故障只用 8 分钟恢复 → SRE 拿了奖金

**演练的真正价值**：发现"以为可以"和"实际可以"之间的差距。

### 4.2 演练等级与频率

```
L1 单元演练   日级    单台节点 / 单条恢复
L2 集成演练   周级    跨节点 / 跨流程
L3 场景演练   月级    完整故障场景
L4 大型演练   季级    多场景叠加 / 双盲
L5 实战演习   年级    红蓝对抗 / 不通知值班
```

### 4.3 演练矩阵（与 05-§13 对齐 + 数据维度专项）

| 编号 | 名称 | 频率 | 目标 | 通过标准 |
|------|------|------|------|---------|
| **数据专项** | | | | |
| DD-01 | 备份完整性自动验证 | **每日** | 验证备份 gunzip+slapadd 通畅 | 100% 通过 |
| DD-02 | 单条恢复演练 | **每周** | 删 1 个测试用户，accesslog 反向恢复 | < 5 分钟 |
| DD-03 | OU 级恢复演练 | **每月** | 删整个 ou=TestOU，备份恢复 | < 15 分钟 |
| DD-04 | 时间点恢复 PITR | **每月** | 恢复到指定时刻 | 数据精确 |
| DD-05 | 全库恢复演练 | **每季** | 异地备份完整重建 | < 30 分钟 |
| DD-06 | HRIS 兜底重建 | **每半年** | 备份全坏，从 HRIS 重建 | < 4 小时 |
| **场景演练** | | | | |
| DD-07 | 误删全树（沙箱） | **每季** | 见下文 §4.5 | accesslog 路径 < 30 分钟 |
| DD-08 | 双主脑裂 | **每半年** | 强制收敛 | 数据一致 |
| DD-09 | 入侵后重建 | **每半年** | 从可信备份重建 | 数据干净 |
| DD-10 | 双盲实战 | **每年** | 不通知值班，红蓝对抗 | RTO 达标 |

### 4.4 演练 SOP 模板（任何演练都套这个）

```markdown
# 演练 #DD-XX: <名称>

## 1. 演练目的
- 验证 <能力>
- 测试 <流程>
- 训练 <人员>

## 2. 演练范围
- 环境: <生产 / 预生产 / 沙箱>
- 影响: <无 / 部分 / 全部>
- 时间窗口: YYYY-MM-DD HH:MM ~ HH:MM

## 3. 参演角色
- 总指挥: 豹纹（Eric）
- 操作员: A
- 记录员: B
- 观察员: C

## 4. 准备清单
- [ ] 备份近 7 天可用
- [ ] 演练剧本审批
- [ ] 通知告警平台屏蔽（避免误报）
- [ ] 通知业务方（演练通报）
- [ ] 回滚方案 ready

## 5. 演练步骤
T+0    : 制造故障 - <具体操作>
T+1min : 等待告警
T+x    : 值班响应（不预先告知）
T+y    : 执行恢复 - <具体步骤>
T+z    : 验证业务

## 6. 通过标准
- [ ] MTTD < <X> 分钟
- [ ] MTTR < <Y> 分钟
- [ ] RPO = 0
- [ ] 业务无新增报错

## 7. 回滚方案
若演练超时 / 失败：
1. 立即恢复备份
2. 通知业务
3. 停止演练分析

## 8. 输出物
- 演练报告（含时间线）
- Runbook 修订
- 监控/告警优化项
- 知识库 Case 沉淀
```

### 4.5 重点演练详解

#### 4.5.1 DD-02 单条恢复（最高频）

```bash
#!/bin/bash
# 每周自动跑

# T+0: 在测试 OU 加一个用户
ldapadd ... <<EOF
dn: uid=drill-$(date +%s),ou=Test,dc=bigdata,dc=local
objectClass: inetOrgPerson
uid: drill-test
cn: Drill Test
sn: Test
EOF

UID="drill-$(date +%s)"
sleep 5

# T+1: 删除
ldapdelete -x ... "uid=$UID,ou=Test,dc=bigdata,dc=local"

# T+2: 走 accesslog 反向恢复
ldapsearch -x -D "cn=admin,cn=accesslog" -W -b "cn=accesslog" \
  "(&(reqType=delete)(reqDN=uid=$UID,ou=Test,dc=bigdata,dc=local))" \
  reqDN reqOld | python3 accesslog-reverse.py | \
  ldapadd -x ...

# T+3: 验证
ldapsearch -x ... "(uid=$UID)" >/dev/null && echo "DRILL OK" || \
  mail -s "[P2] Drill DD-02 FAILED" sre@bigdata.local
```

#### 4.5.2 DD-07 误删全树（季度大考）

**沙箱环境** 必备：复制一套生产数据到独立 LDAP 实例。

剧本：
```
T+0    : 总指挥宣布开始
T+0    : 操作员对沙箱执行 "删除 ou=People"
T+30s  : 监控应已告警
T+1min : 值班 SRE 进群响应
T+2min : 决策：accesslog 反向（< 5min）or 备份（30min）
T+5min : 执行 accesslog 反向恢复
T+15min: 验证：用户数恢复 / 业务测试
T+30min: 演练结束 + 评审
```

**评审输出**：
- 时间线表
- 失误点（如果有）
- Runbook 优化项
- 团队培训需求

#### 4.5.3 DD-10 双盲实战（年度大考）

**双盲** = 双方都不知道：
- 演练员不知道值班是谁
- 值班不知道演练时间和场景

**触发方式**：管理层授权 + CTO 签字 + 自动脚本随机时间触发。

**评分维度**：
- 检测速度（MTTD）
- 决策准确性（是否走对 Runbook）
- 沟通效率（群里通报清不清晰）
- 恢复速度（MTTR）
- 数据完整性（RPO）
- 复盘质量

---

## 5. 工具集（Eric 推荐 / 自研）

| 用途 | 工具 | 说明 |
|------|------|------|
| 备份 | `slapcat` + 自研脚本 | 基础不变 |
| accesslog 反向 | `accesslog-reverse.py` | 见 §2.3.3 |
| PITR 重放 | 自研 `ldap-pitr-tool` | TBD |
| HRIS 对账 | 自研 `ldap-hris-recon.sh` | 见 §3.2.1 |
| 演练编排 | Ansible / Chaos Mesh | 故障注入 |
| 监控 | `openldap_exporter` + Prometheus | 见 03-§5.3 |
| 审计接 SIEM | filebeat + Elasticsearch | auditlog 实时分析 |
| 文档纳管 | Git + GitHub Actions | 配置 + Runbook 版本控制 |

---

## 6. 经验晶体（按九大法则沉淀）

按 `lkl-code-mastery-methodology` 知识晶体化模板，把核心经验固化：

### 经验 1：备份做了不等于能恢复

**场景**：每天 02:00 跑备份，但从未演练。某次真灾难时发现备份解压出错。

**核心源码/配置**：
```
slapcat → gzip → sha256 → gunzip -t → slapadd 验证
```

**调用链**：备份脚本 → 异地复制 → 周演练 → 月恢复测试 → 季度全量演练。

**设计意图**：4-2-1 原则的最后那个 1（演练）是真正决定备份是否有效的。

**关键参数**：
- `slapcat -F /path -n N`（N=2 是主数据库）
- `slapadd -F /path -n N -l file.ldif`

**踩坑记录**：
- 跨大版本 OpenLDAP 备份不通用（2.4 → 2.6 schema 变了）
- gzip 默认 6 级不算最优，生产用 9 级
- sha256 校验和必须和文件分开存（同坏盘上没意义）

**认知更新**：备份不是"做了"就行，是"能恢复才算"。

### 经验 2：accesslog 是穷人的时光机

**场景**：误删用户 / 误改字段，5 分钟内可"穿越回去"。

**核心源码/配置**：
```ldif
olcAccessLogOps: writes
olcAccessLogOld: (objectclass=*)    # 关键：必须配，否则 reqOld 不全
olcAccessLogOldAttr: *               # 关键：所有属性
olcAccessLogPurge: 07+00:00 01+00:00 # 至少保留 7 天
```

**踩坑记录**：
- 默认配置 `olcAccessLogOld` 是空的，出事时发现 reqOld 没记
- purge 太狠（如 1 天）周末出事就来不及了

**认知更新**：accesslog 比备份"更接近实时"，是单条恢复的金标准。

### 经验 3：演练的真正目的不是"通过"

**场景**：演练通过率 100% 时，要警觉是不是题目太简单了。

**认知更新**：
- 演练 = 暴露问题 → 改进 → 再演练
- 通过率 100% 的演练没价值，至少 30% 的演练应该"暴露新问题"
- 把"找 bug"作为演练目标，不是"完成步骤"

---

## 7. 自检表（贴墙上）

每天 / 每周 / 每月 / 每季 一遍：

```
☐ 日检
  ☐ 备份脚本跑成功（看 wecom 通知）
  ☐ contextCSN 在所有副本一致
  ☐ accesslog 还在记录
  ☐ slapd 进程健康

☐ 周检
  ☐ 备份完整性自动验证（DD-01）
  ☐ 单条恢复演练（DD-02）
  ☐ HRIS 对账偏差 < 10
  ☐ 慢查询 / 失败 bind Top 10

☐ 月检
  ☐ OU 恢复演练（DD-03）
  ☐ PITR 演练（DD-04）
  ☐ 权限 review（看哪些账号有写权限）
  ☐ 僵尸账号清理

☐ 季检
  ☐ 全库恢复演练（DD-05）
  ☐ 误删演练（DD-07）
  ☐ 容量评估
  ☐ 凭证轮换（bind 账号 / replicator）

☐ 年检
  ☐ HRIS 全量重建演练（DD-06）
  ☐ 双盲实战（DD-10）
  ☐ 第三方安全审计
  ☐ 灾备等级评估（升级到 N+2？跨 region？）
```

---

## 8. 与其他章节的协同

```
00 入门:    理解 LDAP 数据怎么存的
01 搭建:    建好基础设施 + accesslog overlay
02 集成:    与大数据组件的数据流向
03 运维:    日常备份脚本（本篇 §1.7 是它的升级版）
04 排障:    单点数据问题处理
05 故障恢复: 灾难场景下的恢复 Runbook
06 本篇:    数据维度的全闭环（防/救/管/演）
```

**阅读建议**：
- **数据负责人 / DBA** → 主看本篇 + 03 + 05
- **SRE 工程师** → 全部
- **安全 / 审计** → 本篇 §3.6 + 05
- **新人** → 00 → 03 → 本篇

---

> 📌 上一篇：05-LDAP故障场景恢复手册 | 主索引：README.md  
> 下一步建议：把本篇的"演练矩阵 DD-01~10"落地成 Ansible playbook，做到一键演练
