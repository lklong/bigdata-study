# Kerberos 灾备演练剧本

> 大数据 SRE 必修课 · Eric · 2026-05-10  
> "战时如平时" — 没演练过的预案不算预案  
> 配套：[故障场景恢复手册](./06-Kerberos故障场景恢复手册.md)

---

## 一、演练核心理念

### 1.1 为什么必须演练

| 不演练的代价 | 演练的收益 |
|------------|----------|
| 文档过时不知道 | 强制更新 |
| 团队不熟练，故障时慌乱 | 形成肌肉记忆 |
| 预案有 BUG（命令错/路径错） | 演练时暴露 |
| 监控/告警可能没生效 | 演练时验证 |
| 备份可能不可用（**最致命**） | 演练时发现 |

> **70% 的备份在第一次真实使用时失败** — Google SRE 内部统计

### 1.2 Chaos Engineering 原则（应用到 Kerberos）

```
1. 在生产相似环境演练（非生产，但配置一致）
2. 从小规模故障开始
3. 渐进式增加复杂度
4. 设置爆炸半径（明确停止条件）
5. 自动化（人工演练成本太高）
6. 全程录像 + 留痕
7. 复盘 + 文档化
```

---

## 二、演练分级

| 级别 | 频率 | 范围 | 时长 | 影响 |
|-----|------|-----|------|------|
| **L1 单点演练** | 月度 | 单服务恢复 | 30min | 测试环境 |
| **L2 流程演练** | 季度 | 多服务联动 | 2h | 准生产 |
| **L3 红蓝对抗** | 半年 | 完整故障注入 | 4h | 演练专用环境 |
| **L4 灾难恢复** | 年度 | 整集群重建 | 1day | 完整 DR 演练 |

---

## 三、L1 单点演练剧本

### 剧本 1.1：KDC 进程挂死恢复

#### 准备
```bash
# 演练前快照
ssh kdc01.bigdata.com "
    systemctl status krb5kdc kadmin
    cp -a /var/kerberos/krb5kdc /var/kerberos/krb5kdc.before_drill_$(date +%s)
    ls -la /var/kerberos/krb5kdc/
"
```

#### 注入故障
```bash
# 模拟 KDC 进程挂
ssh kdc01.bigdata.com "kill -9 \$(pidof krb5kdc)"

# 启动定时器
START=$(date +%s)
echo "演练开始：$START"
```

#### 期望响应
| 时间窗 | 期望事件 | 实际 | PASS/FAIL |
|-------|---------|-----|----------|
| T+30s | Prometheus 告警 KDC down | | |
| T+1min | 值班员收到告警 | | |
| T+5min | 值班员登录 KDC 主机 | | |
| T+10min | 完成诊断 + 重启 | | |
| T+12min | kinit 测试通过 | | |
| T+15min | 业务方确认恢复 | | |

#### 自动化恢复脚本（drill_kdc_restart.sh）
```bash
#!/bin/bash
# 监控告警触发后的自动恢复（可选自动 / 手动）
set -euo pipefail

KDC_HOST=${1:-kdc01.bigdata.com}
LOG="/var/log/kerberos_drill_$(date +%s).log"

{
    echo "=== 演练自动恢复开始 $(date) ==="
    
    # 1) 探测
    if nc -zv -w2 $KDC_HOST 88 2>/dev/null; then
        echo "✅ KDC 已恢复，无需操作"
        exit 0
    fi
    
    # 2) SSH 进去看进程
    ssh $KDC_HOST "
        if ! pgrep -x krb5kdc; then
            echo '进程不存在，准备拉起'
            systemctl start krb5kdc
            sleep 3
            systemctl status krb5kdc
        fi
    "
    
    # 3) 验证
    sleep 5
    if nc -zv -w2 $KDC_HOST 88 2>/dev/null; then
        echo "✅ 自动恢复成功 $(date)"
    else
        echo "❌ 自动恢复失败，需人工介入"
        exit 1
    fi
} 2>&1 | tee $LOG
```

#### 复原 + 复盘
```bash
# 复原（如果演练时改动了配置）
ssh kdc01.bigdata.com "
    rm -rf /var/kerberos/krb5kdc.before_drill_*
"

# 复盘表格填写（必填）
cat > /tmp/drill_report_$(date +%Y%m%d).md <<EOF
# KDC 进程挂死演练报告

## 时间线
- T+0:    注入故障
- T+XXs:  告警触发（预期 30s）
- T+XXmin: 值班员介入
- T+XXmin: 恢复完成

## 偏差
- 告警延迟 X 秒（原因：__）
- 恢复时长超出 SLA X 分钟（原因：__）

## 改进
- [ ] 优化告警 alertmanager 路由
- [ ] 加自动重启逻辑
EOF
```

---

### 剧本 1.2：Keytab 文件权限错乱恢复

#### 注入
```bash
# 故意改权限
ssh dn01.bigdata.com "chmod 644 /etc/security/keytabs/hdfs.service.keytab"
ssh dn01.bigdata.com "systemctl restart hadoop-hdfs-datanode"
# DN 启动应失败
```

#### 期望
- 巡检脚本（kerberos-health-check.sh）应在 6h 内告警
- 服务日志应有明显的 `LoginException`

#### 恢复
```bash
ssh dn01.bigdata.com "
    chown hdfs:hadoop /etc/security/keytabs/hdfs.service.keytab
    chmod 400 /etc/security/keytabs/hdfs.service.keytab
    systemctl restart hadoop-hdfs-datanode
"
```

---

### 剧本 1.3：单节点 KVNO 不一致

#### 注入
```bash
# 主 KDC 改 principal 密码（KVNO+1）但不分发新 keytab
ssh kdc01 "kadmin.local -q 'cpw -randkey hdfs/dn01.bigdata.com@BIGDATA.COM'"

# DN01 重启应失败
ssh dn01 "systemctl restart hadoop-hdfs-datanode"
```

#### 恢复脚本（fix_kvno_mismatch.sh）
```bash
#!/bin/bash
# Usage: bash fix_kvno_mismatch.sh <host> <principal>
set -euo pipefail

HOST=$1
PRINCIPAL=$2
KDC=kdc01.bigdata.com
SVC=$(echo $PRINCIPAL | cut -d/ -f1)
FQDN=$(echo $PRINCIPAL | cut -d/ -f2 | cut -d@ -f1)
KEYTAB="/etc/security/keytabs/${SVC}.service.keytab"

echo "=== 修复 $HOST 的 $PRINCIPAL ==="

# 1) 重新导出 keytab（带 -norandkey 保 KVNO 不变）
ssh $KDC "kadmin.local -q 'ktadd -norandkey -k /tmp/${SVC}.${FQDN}.keytab $PRINCIPAL'"

# 2) 分发
scp $KDC:/tmp/${SVC}.${FQDN}.keytab /tmp/
scp /tmp/${SVC}.${FQDN}.keytab $HOST:/tmp/

# 3) 部署
ssh $HOST "
    cp $KEYTAB ${KEYTAB}.bak_\$(date +%s)
    mv /tmp/${SVC}.${FQDN}.keytab $KEYTAB
    chown ${SVC}:hadoop $KEYTAB
    chmod 400 $KEYTAB
"

# 4) 验证
ssh $HOST "sudo -u $SVC kinit -kt $KEYTAB $PRINCIPAL && klist && kdestroy"

# 5) 重启服务
case $SVC in
    hdfs) ssh $HOST "systemctl restart hadoop-hdfs-datanode" ;;
    yarn) ssh $HOST "systemctl restart hadoop-yarn-nodemanager" ;;
    hive) ssh $HOST "systemctl restart hive-server2" ;;
esac

# 6) 清理
ssh $KDC "rm /tmp/${SVC}.${FQDN}.keytab"
rm /tmp/${SVC}.${FQDN}.keytab

echo "✅ 修复完成"
```

---

## 四、L2 流程演练剧本

### 剧本 2.1：KDC 主备切换演练

#### 演练目标
- 验证客户端 krb5.conf 多 KDC 配置生效
- 验证备 KDC 承载全集群流量
- 验证 RTO（Recovery Time Objective）≤ 5min

#### 准备工作（演练前 1 周）
```bash
# 1) 客户端检查（所有节点）
ansible all -m shell -a "grep -A3 '\[realms\]' /etc/krb5.conf | grep kdc"
# 必须看到至少 2 个 KDC

# 2) 备 KDC 数据同步检查
ssh kdc02 "ls -lh /var/kerberos/krb5kdc/principal*"
ssh kdc01 "ls -lh /var/kerberos/krb5kdc/principal*"
# size 应基本一致（差距 < 5%）

# 3) 提前预热演练业务
# 准备一组测试任务，演练时不间断提交
```

#### 演练执行
```bash
#!/bin/bash
# drill_kdc_failover.sh
DRILL_LOG="/tmp/drill_failover_$(date +%Y%m%d_%H%M%S).log"

{
    echo "=== KDC 主备切换演练 ==="
    echo "Start: $(date)"
    
    # T+0：基线
    echo ""
    echo "--- T+0 基线测试 ---"
    time kinit -kt /etc/security/keytabs/test.keytab test@BIGDATA.COM
    klist
    kdestroy
    
    # T+1：注入故障：主 KDC 断网
    echo ""
    echo "--- T+1 注入故障 ---"
    ssh kdc01 "iptables -A INPUT -p tcp --dport 88 -j DROP; iptables -A INPUT -p udp --dport 88 -j DROP"
    
    # T+2：客户端测试（应 failover 到备 KDC）
    echo ""
    echo "--- T+2 故障后测试（应 failover 到 kdc02）---"
    time kinit -kt /etc/security/keytabs/test.keytab test@BIGDATA.COM
    # 第一次 kinit 会有 5~10s 超时，自动切到 kdc02
    
    # T+3：验证业务可用性
    echo ""
    echo "--- T+3 业务验证 ---"
    sudo -u hdfs hdfs dfs -ls /
    yarn application -list
    
    # T+30min：恢复主 KDC
    echo ""
    echo "--- T+30min 恢复主 KDC ---"
    sleep 30  # 实际演练 30min
    ssh kdc01 "iptables -F"
    
    # T+31：验证主 KDC 重新可用
    echo ""
    echo "--- T+31 主 KDC 恢复验证 ---"
    nc -zv kdc01.bigdata.com 88
    
    echo ""
    echo "End: $(date)"
} 2>&1 | tee $DRILL_LOG
```

#### 验收标准
- [ ] 客户端 kinit 在 30s 内完成 failover
- [ ] 故障期间业务任务无失败
- [ ] 主 KDC 恢复后能继续承载流量
- [ ] 监控告警正确触发
- [ ] 演练日志完整

---

### 剧本 2.2：批量 keytab 重发演练

#### 场景
模拟 100 个 DN 全部 keytab KVNO 错乱，验证批量恢复能力

#### 注入
```bash
#!/bin/bash
# inject_keytab_chaos.sh — 演练专用，不要在生产用！

# 仅在演练环境中
[[ "$DRILL_ENV" != "true" ]] && { echo "ABORT: 必须设 DRILL_ENV=true"; exit 1; }

# 1) 在主 KDC 上批量改密码（不分发）
for h in $(cat dns_drill.txt); do
    ssh kdc01-drill "kadmin.local -q 'cpw -randkey hdfs/$h@DRILL.COM'"
done

# 2) 滚动重启 DN，应大量失败
for h in $(cat dns_drill.txt); do
    ssh $h "systemctl restart hadoop-hdfs-datanode" &
done
wait
```

#### 恢复（自动化批量）
```bash
#!/bin/bash
# batch_fix_keytab.sh — 批量修复脚本

KDC=kdc01-drill.bigdata.com
HOSTS_FILE=${1:-dns_drill.txt}
PARALLEL=${2:-10}

# 1) 找出所有失败节点
echo "=== 探测失败节点 ==="
for h in $(cat $HOSTS_FILE); do
    if ! ssh $h "systemctl is-active hadoop-hdfs-datanode" >/dev/null 2>&1; then
        echo $h
    fi
done > /tmp/down_hosts.txt
echo "失败节点数: $(wc -l < /tmp/down_hosts.txt)"

# 2) 批量重新导出 keytab（在 KDC 上）
echo "=== 重新导出 keytab ==="
ssh $KDC "mkdir -p /tmp/keytab_redeploy && rm -f /tmp/keytab_redeploy/*"
while read h; do
    ssh $KDC "kadmin.local -q 'ktadd -norandkey -k /tmp/keytab_redeploy/hdfs.${h}.keytab hdfs/${h}@DRILL.COM'" &
    [[ $(jobs -r | wc -l) -ge $PARALLEL ]] && wait -n
done < /tmp/down_hosts.txt
wait

# 3) 拉取到本地
echo "=== 拉取 keytab ==="
mkdir -p /tmp/keytab_local
rsync -av $KDC:/tmp/keytab_redeploy/ /tmp/keytab_local/

# 4) 并行分发 + 部署
echo "=== 分发 + 部署 ==="
fix_one_host() {
    local h=$1
    local kt="/tmp/keytab_local/hdfs.${h}.keytab"
    
    [[ ! -f $kt ]] && { echo "❌ $h keytab 缺失"; return 1; }
    
    scp $kt $h:/tmp/ >/dev/null
    ssh $h "
        cp /etc/security/keytabs/hdfs.service.keytab /etc/security/keytabs/hdfs.service.keytab.bak_\$(date +%s)
        mv /tmp/hdfs.${h}.keytab /etc/security/keytabs/hdfs.service.keytab
        chown hdfs:hadoop /etc/security/keytabs/hdfs.service.keytab
        chmod 400 /etc/security/keytabs/hdfs.service.keytab
        systemctl restart hadoop-hdfs-datanode
    " && echo "✅ $h" || echo "❌ $h"
}

while read h; do
    fix_one_host $h &
    [[ $(jobs -r | wc -l) -ge $PARALLEL ]] && wait -n
done < /tmp/down_hosts.txt
wait

# 5) 验收
echo "=== 验收 ==="
sleep 30
hdfs dfsadmin -report | head -20

# 6) 清理 KDC 上临时文件
ssh $KDC "rm -rf /tmp/keytab_redeploy"
```

#### SLA
- 100 节点恢复 RTO ≤ 30 分钟
- 数据完整性：演练后 fsck 全 healthy

---

## 五、L3 红蓝对抗演练

### 剧本 3.1：Chaos Monkey for Kerberos

#### 场景
红队（攻击方）随机注入故障，蓝队（防守方）发现 + 恢复

#### 红队工具集
```bash
# chaos_kerberos.sh — 随机故障注入
#!/bin/bash
ATTACKS=(
    "kdc_process_kill"
    "keytab_permission_chaos"
    "kvno_mismatch"
    "krb5conf_corruption"
    "ntp_skew_inject"
    "dns_break"
    "kpropd_stop"
)

ATTACK=${ATTACKS[$RANDOM % ${#ATTACKS[@]}]}
TARGET=$(shuf -n1 hosts.txt)

echo "RED TEAM: 攻击 $TARGET 类型 $ATTACK 时间 $(date)"

case $ATTACK in
    kdc_process_kill)
        ssh $TARGET "[ \$(hostname) =~ kdc ] && kill -9 \$(pidof krb5kdc) 2>/dev/null"
        ;;
    keytab_permission_chaos)
        kt=$(ssh $TARGET "ls /etc/security/keytabs/*.keytab 2>/dev/null | shuf -n1")
        ssh $TARGET "chmod 644 $kt"
        ;;
    kvno_mismatch)
        # 在 KDC 上随机选一个 principal cpw
        principal=$(ssh kdc01 "kadmin.local -q 'listprincs' | grep -v krbtgt | grep -v admin | shuf -n1")
        ssh kdc01 "kadmin.local -q 'cpw -randkey $principal'"
        ;;
    krb5conf_corruption)
        ssh $TARGET "sed -i 's/rdns = false/rdns = true/' /etc/krb5.conf"
        ;;
    ntp_skew_inject)
        ssh $TARGET "date -s '+10 minutes'"
        ;;
    dns_break)
        ssh $TARGET "echo '127.0.0.1 kdc01.bigdata.com' >> /etc/hosts"
        ;;
    kpropd_stop)
        ssh kdc02 "systemctl stop kpropd"
        ;;
esac

# 留痕（演练复盘用）
echo "$(date),$TARGET,$ATTACK" >> /var/log/chaos_drill.log
```

#### 蓝队评分
| 指标 | 满分 | 评分标准 |
|-----|------|---------|
| 发现耗时（MTTD）| 30 | 1min 内 30 分；5min 内 20 分；10min 内 10 分 |
| 定位准确率 | 20 | 第一次定位正确 20 分；第二次 10 分 |
| 恢复耗时（MTTR）| 30 | 5min 内 30 分；15min 内 20 分；30min 内 10 分 |
| 业务影响最小化 | 10 | 业务方未感知 10 分；感知但无失败 5 分 |
| 留痕规范 | 10 | 命令+输出全留痕 10 分 |

---

## 六、L4 灾难恢复演练（DR）

### 剧本 4.1：完整 KDC 重建演练

#### 场景
模拟 KDC 主机硬件全毁 + 所有备份只有冷备 + 必须 4 小时内恢复

#### 演练步骤

```bash
#!/bin/bash
# dr_full_rebuild.sh — 灾难恢复完整重建演练
# 必须在演练环境执行！

set -euo pipefail
DR_HOST=kdc-dr.bigdata.com
COLD_BACKUP="/cold_backup/krb5_dump_LATEST.gz"
T0=$(date +%s)

echo "=== DR 演练开始 $(date) ==="

# Phase 1: 准备新主机（30min）
echo ""
echo "--- Phase 1: 新主机准备 ---"
ssh $DR_HOST "
    # 装包
    yum install -y krb5-server krb5-workstation krb5-libs
    
    # NTP
    systemctl enable --now chronyd
    chronyc tracking
    
    # 防火墙
    firewall-cmd --add-port=88/tcp --permanent
    firewall-cmd --add-port=88/udp --permanent
    firewall-cmd --add-port=749/tcp --permanent
    firewall-cmd --reload
"

# Phase 2: 还原配置（10min）
echo ""
echo "--- Phase 2: 还原配置 ---"
scp /backup/krb5.conf $DR_HOST:/etc/krb5.conf
scp /backup/kdc.conf $DR_HOST:/var/kerberos/krb5kdc/kdc.conf
scp /backup/kadm5.acl $DR_HOST:/var/kerberos/krb5kdc/kadm5.acl
scp /backup/kpropd.acl $DR_HOST:/var/kerberos/krb5kdc/kpropd.acl

# Phase 3: 还原数据库（30min）
echo ""
echo "--- Phase 3: 还原数据库 ---"
scp $COLD_BACKUP $DR_HOST:/tmp/

ssh $DR_HOST "
    cd /tmp
    gunzip krb5_dump_LATEST.gz
    
    # 创建空数据库（用相同 master key）
    # ⚠️ master key 必须从安全保险箱取出
    kdb5_util create -s -r BIGDATA.COM -P '\$(cat /secure/master_key)'
    
    # 加载备份
    kdb5_util load /tmp/krb5_dump_LATEST
    
    # 启动
    systemctl enable --now krb5kdc kadmin
    systemctl status krb5kdc
"

# Phase 4: 验证（30min）
echo ""
echo "--- Phase 4: 验证 ---"
ssh $DR_HOST "
    # 1. listprincs 数量
    PRINC_COUNT=\$(kadmin.local -q 'listprincs' | wc -l)
    echo \"Principal count: \$PRINC_COUNT\"
    [[ \$PRINC_COUNT -lt 100 ]] && { echo '❌ 数量异常'; exit 1; }
    
    # 2. 测试 kinit
    kinit admin/admin
    klist
    
    # 3. 测试 kvno（验证密钥可用）
    kvno hdfs/nn01.bigdata.com
"

# Phase 5: 切流量（30min）
echo ""
echo "--- Phase 5: 切流量 ---"
# 方案 A: 改 DNS（如果用 VIP）
# 方案 B: 客户端 krb5.conf 推新（Ansible 全集群）
ansible all -m copy -a "src=/backup/krb5_dr.conf dest=/etc/krb5.conf"

# Phase 6: 端到端业务验证（60min）
echo ""
echo "--- Phase 6: E2E 验证 ---"
# 提交 Hive 查询
beeline -u "jdbc:hive2://hs2.bigdata.com:10000/default;principal=hive/_HOST@BIGDATA.COM" \
    -e "SELECT COUNT(*) FROM test.drill_table;"

# 提交 Spark 任务
spark-submit \
    --master yarn --deploy-mode cluster \
    --principal test@BIGDATA.COM \
    --keytab /etc/security/keytabs/test.keytab \
    --class org.apache.spark.examples.SparkPi \
    /opt/spark/examples/jars/spark-examples_*.jar 100

T_END=$(date +%s)
DURATION=$((T_END - T0))
echo ""
echo "=== DR 演练完成 ==="
echo "总时长: ${DURATION}秒 ($(($DURATION/60))分钟)"
echo "目标: 14400秒 (240分钟)"
[[ $DURATION -lt 14400 ]] && echo "✅ 达标" || echo "❌ 超时"
```

#### 演练后必须完成
- [ ] 复盘文档
- [ ] 备份策略评估（是否要更频繁）
- [ ] master key 保管流程评估
- [ ] DR 主机预置（是否准备热备主机）
- [ ] 客户端 krb5.conf 推送方案优化

---

## 七、演练自动化平台建议

### 7.1 演练编排（基于 Argo Workflow / Tekton）

```yaml
# kerberos-drill-workflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: kerberos-drill-
spec:
  entrypoint: drill
  templates:
  - name: drill
    steps:
    - - name: pre-snapshot
        template: snapshot
    - - name: inject-fault
        template: chaos
        arguments:
          parameters:
          - name: type
            value: "{{workflow.parameters.fault_type}}"
    - - name: wait-for-alert
        template: monitor
    - - name: auto-recover
        template: recover
    - - name: validate
        template: validate
    - - name: report
        template: report
```

### 7.2 演练日历

```
| 月 | 演练类型 | 范围 | 责任人 |
|---|---------|------|-------|
| 1 | L1 KDC 进程挂 | 单 KDC | 张三 |
| 2 | L1 keytab 权限 | 抽 5 节点 | 李四 |
| 3 | L2 主备切换 | 全集群 | 团队 |
| 4 | L1 KVNO 错乱 | 抽 3 节点 | 王五 |
| 5 | L1 跨域信任失效 | AD-Hadoop | 张三 |
| 6 | L3 红蓝对抗 | 全集群 | 团队 |
| 7 | L1 长任务 token | 测试任务 | 李四 |
| 8 | L1 SPNEGO 故障 | Web UI | 王五 |
| 9 | L2 批量 keytab | 50+ 节点 | 团队 |
| 10 | L1 NTP 漂移 | 单节点 | 张三 |
| 11 | L2 KDC 数据库恢复 | 测试库 | 李四 |
| 12 | **L4 完整 DR 演练** | DR 环境 | **全体 + 高管** |
```

---

## 八、演练治理

### 8.1 演练 SLO

| 指标 | 目标 |
|-----|------|
| 演练覆盖率 | 100%（所有 P0/P1 场景每年至少 1 次） |
| 演练成功率 | ≥ 80% 一次通过 |
| 演练后 BUG 修复 | 30 天内 100% |
| 演练文档更新率 | 每次演练后 100% 更新 |

### 8.2 演练问责（不是处罚，是改进）

- 演练失败不追责，但**不写复盘 = 严重问责**
- 真实故障如果**演练过的场景挂了** → 反向改进 SOP
- 真实故障如果**演练过没挂的场景挂了** → 大概率是新型故障，加进演练库

### 8.3 演练宣传

- 每次演练做内部分享
- 优秀复盘进 SRE 知识库
- 年度评奖："最佳故障演练奖"

---

## 九、参考脚本汇总

```
/opt/sre/drill/
├── L1/
│   ├── drill_kdc_restart.sh
│   ├── drill_keytab_perm.sh
│   ├── drill_kvno_mismatch.sh
│   └── ...
├── L2/
│   ├── drill_kdc_failover.sh
│   ├── drill_batch_keytab.sh
│   └── ...
├── L3/
│   ├── chaos_kerberos.sh
│   └── score_blueteam.sh
├── L4/
│   └── dr_full_rebuild.sh
├── lib/
│   ├── snapshot.sh
│   ├── validate.sh
│   └── report.sh
└── playbooks/
    ├── kerberos-drill-l1.yaml
    └── kerberos-drill-l2.yaml
```

---

*Eric · 大数据 SRE AI 专家团队 · "战时如平时" · v1.0*
