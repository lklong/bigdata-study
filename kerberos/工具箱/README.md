# Kerberos 工具箱 README

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> 一键诊断 / 自动修复 / 持续巡检 · 6 个生产级脚本

---

## 工具一览

| 脚本 | 用途 | 何时用 |
|------|------|-------|
| **kerb-doctor.sh** | 综合体检（10 项检查） | 故障第一时间跑这个 |
| **kerb-trace.sh** | KRB5_TRACE 一键采集+智能分析 | 拿不到根因时 |
| **kerb_error_classifier.py** | 报错智能分类（错误码+关键字） | 看到一堆错误日志 |
| **kvno-fixer.sh** | 批量修复 KVNO 不一致 | 生产 Top1 故障 |
| **keytab-health.sh** | 全集群 keytab 健康巡检（cron） | 定时任务 |
| **kerb-log-grep.sh** | Hadoop 日志聚合分析 | 大面积异常时 |
| **kerb-fqdn-check.sh** | FQDN/DNS 一致性检查 | SPN 不存在类问题 |
| **kerb-token-monitor.sh** | Delegation Token 监控 | 防长任务雪崩 |

---

## 一、kerb-doctor.sh — 综合体检（首选）

### 用法

```bash
chmod +x kerb-doctor.sh

# 最简
bash kerb-doctor.sh

# 带 keytab 测试
bash kerb-doctor.sh -p hdfs/$(hostname -f)@BIGDATA.COM -k /etc/security/keytabs/hdfs.service.keytab

# 指定 KDC
bash kerb-doctor.sh -K kdc01.bigdata.com -p alice@BIGDATA.COM -k /home/alice/alice.keytab
```

### 检查 10 项

1. 基础环境（hostname -f / FQDN）
2. 时钟检查（与 KDC 偏差）
3. 网络（KDC 88/UDP/749）
4. krb5.conf 关键项（rdns/udp_pref/forwardable/enctype）
5. 当前 ccache（票据状态）
6. keytab 文件（权限/属主/enctype）
7. **KVNO 一致性**（与 KDC 比对）
8. kinit 测试（带 KRB5_TRACE）
9. JCE 解锁状态
10. Hadoop 配置（authentication / proxyuser）

### 输出示例

```
✅ FQDN 配置正常
✅ 时钟偏差 2秒，正常
✅ TCP 88 通
✅ rdns = false
⚠️  forwardable 未设为 true
❌ KVNO 不一致! 修复命令：kadmin.local -q 'ktadd -norandkey ...'
```

### 退出码
- 0：全绿
- 1：有黄色警告
- 2：有红色错误

---

## 二、kerb-trace.sh — 智能 TRACE 采集

### 用法

```bash
# 模式 1：测 kinit
bash kerb-trace.sh -p alice@BIGDATA.COM -k /home/alice/alice.keytab

# 模式 2：包装命令（最常用）
bash kerb-trace.sh -c "hdfs dfs -ls /"

# 测 beeline
bash kerb-trace.sh -c "beeline -u 'jdbc:hive2://hs2:10000/default;principal=hive/_HOST@BIGDATA.COM' -e 'show databases'"

# 测 spark-submit
bash kerb-trace.sh -c "spark-submit --class ... my.jar"
```

### 智能输出

- 自动识别错误码（如 -1765328359）→ 给出根因 + 修复
- 提取关键事件：请求/响应/enctype 协商/SPN 请求
- Java 程序自动加 `-Dsun.security.krb5.debug=true`
- 输出 trace 完整日志路径，可贴给 Eric 升级分析

---

## 三、kerb_error_classifier.py — 错误智能分类

### 用法

```bash
# 管道方式
cat error.log | python3 kerb_error_classifier.py

# 直接传文件
python3 kerb_error_classifier.py error.log

# 一行报错
echo "GSSException: No valid credentials provided" | python3 kerb_error_classifier.py
```

### 输出示例

```
━━━ [Login类] ━━━
  匹配:    关键字 'No valid credentials provided'
  根因:    没 kinit / CCNAME 错
  解法:    kinit + echo $KRB5CCNAME

━━━ [密钥类] ━━━
  匹配:    errorcode -1765328230
  根因:    KVNO 不一致
  解法:    kadmin.local -q 'ktadd -norandkey -k /tmp/x.keytab P'

📌 优先排查建议
按类别优先级处理: Login → 密钥 → 配置
```

---

## 四、kvno-fixer.sh — 批量 KVNO 修复（生产级）

### 用法

```bash
# 准备 hosts.txt（每行一个 FQDN）
cat > hosts.txt <<EOF
nn01.bigdata.com
nn02.bigdata.com
dn01.bigdata.com
dn02.bigdata.com
hs2.bigdata.com
EOF

# 先 dry-run 看影响
bash kvno-fixer.sh -h hosts.txt --dry-run

# 实际修复（会问你确认）
bash kvno-fixer.sh -h hosts.txt -K kdc01.bigdata.com
```

### 流程

1. 探测所有节点 keytab → 与 KDC KVNO 比对
2. 生成 mismatch 清单
3. dry-run 模式只显示，不操作
4. 用户确认后 → KDC 上 `ktadd -norandkey` 重新导出
5. 拉取新 keytab → 分发到对应节点
6. 自动备份老 keytab（`.bak_<ts>`）
7. 提示重启服务命令

### 安全设计

- 每步都有日志（`/tmp/kvno_fix_<ts>/`）
- 老 keytab 自动备份
- 用 `-norandkey` 不改密码（避免雪崩）
- 用户确认后才操作 KDC

---

## 五、keytab-health.sh — 健康巡检（cron 定时）

### 用法

```bash
# 单次跑
bash keytab-health.sh /etc/sre/hosts.txt

# 加入 crontab（每 6 小时）
0 */6 * * * /opt/sre/keytab-health.sh /etc/sre/hosts.txt >/dev/null 2>&1
```

### 检查项

每个 keytab 检查：
- 文件权限（应为 400/600）
- 属主（与服务用户匹配）
- enctype 数量（应 ≥ 2）
- kinit 是否成功
- KVNO 与 KDC 是否一致

### 输出

- CSV 报告：`/var/log/sre/keytab_health_<ts>.csv`
- 异常时邮件告警（设 `SRE_MAIL` 环境变量）
- 退出码 0=全绿，1=有异常

---

## 六、kerb-log-grep.sh — 日志聚合分析

### 用法

```bash
# 默认看最近 24 小时
bash kerb-log-grep.sh

# 看最近 1 小时（排查刚发生的）
bash kerb-log-grep.sh 1

# 看最近 7 天（趋势分析）
bash kerb-log-grep.sh 168
```

### 自动扫描的日志

- `/var/log/hadoop-hdfs/`
- `/var/log/hadoop-yarn/`
- `/var/log/hive/`
- `/var/log/spark/`
- `/var/log/kafka/`
- `/var/log/krb5kdc.log`
- `/var/log/kadmin.log`

### 提取关键字

- GSSException / KrbException
- Clock skew
- Pre-authentication failed
- Specified version of key (KVNO)
- Server/Client not found
- Ticket expired
- token expired
- 等 25+ 关键字

### 输出

- 每个日志文件命中数
- 模式 TOP（哪种错误最多）
- 最近 5 条错误样本
- **智能修复建议**

---

## 七、kerb-fqdn-check.sh — FQDN 一致性

### 用法

```bash
bash kerb-fqdn-check.sh hosts.txt
```

### 检查

每个节点：
- `hostname` vs `hostname -f`（必须 FQDN）
- DNS 正解
- DNS 反解（与 FQDN 一致）
- 三方对齐才算 OK

### 用途

排查 `Server not found in Kerberos database` 类问题——通常是 FQDN 不对。

---

## 八、kerb-token-monitor.sh — Token 防雪崩

### 用法

```bash
RM_HOST=rm01.bigdata.com NN_HOST=nn01.bigdata.com bash kerb-token-monitor.sh
```

### 检查

1. NN JMX 中 token 数量、即将过期数
2. 运行 > 6 天的长任务清单
3. **未配 --keytab 的长任务（高危！）**
4. 给出修复建议

### 推荐 cron

```cron
# 每天早上 8 点检查，发现高危任务发邮件
0 8 * * * /opt/sre/kerb-token-monitor.sh | mail -s "[Kerberos] Token 监控" sre@bigdata.com
```

---

## 综合使用模式

### 模式 A：故障应急（5 分钟）

```bash
# 1. 综合体检
bash kerb-doctor.sh -p $PRINCIPAL -k $KEYTAB > diag.log

# 2. 看输出，根据红色错误分类
# 3. KRB5_TRACE 抓现场
bash kerb-trace.sh -c "<复现命令>"

# 4. 错误分类
cat diag.log | python3 kerb_error_classifier.py

# 5. 按建议修复
```

### 模式 B：日常巡检（cron）

```cron
# 每 6 小时全集群 keytab 巡检
0 */6 * * * /opt/sre/keytab-health.sh

# 每天扫一遍 Hadoop 日志的 Kerberos 错误
0 8 * * * /opt/sre/kerb-log-grep.sh 24 | mail -s "[Kerberos] 日志巡检" sre@bigdata.com

# 每天检查长任务 token
0 9 * * * /opt/sre/kerb-token-monitor.sh | mail -s "[Kerberos] Token 监控" sre@bigdata.com
```

### 模式 C：批量故障恢复

```bash
# KVNO 大面积错乱
bash kvno-fixer.sh -h all_hosts.txt --dry-run     # 看影响
bash kvno-fixer.sh -h all_hosts.txt               # 实修

# FQDN 集中检查
bash kerb-fqdn-check.sh all_hosts.txt
```

---

## 部署建议

### 标准部署路径

```bash
# 1. 复制工具箱到 /opt/sre/
sudo mkdir -p /opt/sre/kerberos
sudo cp *.sh *.py /opt/sre/kerberos/
sudo chmod +x /opt/sre/kerberos/*.sh
sudo chmod +x /opt/sre/kerberos/*.py

# 2. 加 PATH
echo 'export PATH=/opt/sre/kerberos:$PATH' | sudo tee /etc/profile.d/kerb-tools.sh

# 3. 部署到所有节点（Ansible）
ansible all -m copy -a "src=/opt/sre/kerberos/ dest=/opt/sre/kerberos/ mode=preserve"
```

### 加 cron

```bash
sudo crontab -e
# 追加：
0 */6 * * * /opt/sre/kerberos/keytab-health.sh /etc/sre/hosts.txt
0 8 * * * /opt/sre/kerberos/kerb-log-grep.sh 24
0 9 * * * /opt/sre/kerberos/kerb-token-monitor.sh
```

---

## 故障排查速查

| 现象 | 跑哪个工具 |
|------|-----------|
| 任意 Kerberos 报错 | `kerb-doctor.sh` |
| 报错没看懂 | `kerb-trace.sh -c '<命令>'` |
| 一堆错误日志 | `kerb-log-grep.sh \| python3 kerb_error_classifier.py` |
| KVNO 不一致 | `kvno-fixer.sh --dry-run` |
| `Server not found` | `kerb-fqdn-check.sh` |
| 长任务挂 | `kerb-token-monitor.sh` |
| 例行体检 | `keytab-health.sh` |

---

*Eric · 大数据 SRE AI 专家团队 · 工具箱 v1.0*
