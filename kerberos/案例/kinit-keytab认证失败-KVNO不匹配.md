# Kerberos kinit 使用 Keytab 认证失败 — KVNO 不匹配

> **TL;DR**：`kinit -kt` 报 "Password incorrect" 并非密码错误，根因是 keytab 中 KVNO=1 而 KDC 上 principal 的密钥版本已递增到 KVNO=2，导致密钥不匹配认证失败。

---

## 一、问题现象（如何识别）

### 1.1 错误信息

```bash
# kinit -kt /var/krb5kdc/emr.keytab hadoop/10.8.1.107@EMR-0ATE1KFO
kinit: Password incorrect while getting initial credentials
```

### 1.2 特征

- 使用 keytab 文件进行 `kinit`，而非交互式输入密码
- 错误信息为 "Password incorrect"（误导性极强，实际与密码无关）
- 之前曾正常工作，突然失败

### 1.3 环境信息

| 项目 | 值 |
|------|-----|
| 集群 | EMR-0ATE1KFO |
| KDC 节点 | 10.8.1.124, 10.8.1.107 |
| Keytab 路径 | /var/krb5kdc/emr.keytab |
| Principal | hadoop/10.8.1.107@EMR-0ATE1KFO |
| 加密类型 | des3-cbc-sha1 |
| Kerberos 配置 | /etc/krb5.conf |

---

## 二、根因类别（常见 5 类）

使用 keytab 进行 `kinit` 报 "Password incorrect" 时，按以下优先级排查：

| # | 根因类别 | 概率 | 排查难度 |
|---|----------|------|----------|
| 1 | **KVNO 不匹配** — keytab 中密钥版本 < KDC 当前版本 | ⭐⭐⭐⭐⭐ | 低 |
| 2 | **Principal 不匹配** — keytab 中的 principal 名称与命令行指定的不完全一致 | ⭐⭐⭐⭐ | 低 |
| 3 | **Enctype 不匹配** — keytab 加密类型不在 krb5.conf 的 permitted_enctypes 列表中 | ⭐⭐⭐ | 中 |
| 4 | **Keytab 文件损坏或权限不足** — 文件不可读 | ⭐⭐ | 低 |
| 5 | **KDC 不可达或时钟偏差 >5min** — 网络/时间问题 | ⭐ | 中 |

### 本次根因：类别 1 — KVNO 不匹配

```
Keytab KVNO = 1（2026-04-21 生成）
KDC    KVNO = 2（2026-04-29 14:38 被变更）
```

2026-04-29 14:38 有人对该 principal 执行了密钥变更操作（`ktadd`/`change_password`/`modprinc`），KDC 侧 KVNO 递增到 2，但 keytab 文件未同步更新，仍持有旧密钥。

---

## 三、快速诊断命令集

### 3.1 第一步：确认 keytab 内容（principal + enctype + kvno）

```bash
# 查看 keytab 中的 principal 列表及 KVNO
klist -kt /var/krb5kdc/emr.keytab

# 查看 keytab 中的加密类型详情（多一个 e）
klist -kte /var/krb5kdc/emr.keytab
```

**示例输出**：
```
KVNO Timestamp           Principal
---- ------------------- ------------------------------------------------------
   1 2026-04-21T16:34:33 hadoop/10.8.1.107@EMR-0ATE1KFO (des3-cbc-sha1)
```

### 3.2 第二步：确认 KDC 上 principal 的当前 KVNO

```bash
kadmin.local -q "getprinc hadoop/10.8.1.107@EMR-0ATE1KFO"
```

**关键输出**：
```
Key: vno 2, des3-cbc-sha1    ← 如果这里的 vno > keytab 中的 KVNO，即为根因
Last modified: Wed Apr 29 14:38:52 CST 2026 (root/admin@EMR-0ATE1KFO)
```

### 3.3 第三步：开启 KRB5_TRACE 看详细握手日志

```bash
KRB5_TRACE=/dev/stderr kinit -kt /var/krb5kdc/emr.keytab hadoop/10.8.1.107@EMR-0ATE1KFO 2>&1
```

trace 日志会明确显示：
- 客户端尝试使用的 kvno 和 enctype
- KDC 返回的错误码（如 KRB5KRB_AP_ERR_MODIFIED 表示密钥不匹配）

### 3.4 批量检查所有 principal 的 KVNO 对比

```bash
# 批量查看 KDC 上所有 principal 的 kvno（在 KDC 节点执行）
kadmin.local -q "listprincs" | while read p; do printf "%-50s " "$p"; kadmin.local -q "getprinc $p" 2>/dev/null | grep "Key: vno"; done
```

### 3.5 辅助检查：enctype 和 krb5.conf 是否匹配

```bash
# 查看 krb5.conf 中配置的加密类型
grep -i enctypes /etc/krb5.conf
```

确保 keytab 中的 enctype 在 `permitted_enctypes` 列表中。

---

## 四、标准处置 SOP

### 场景 A：KVNO 不匹配 — 推荐用 `-norandkey` 重导（不改变 KDC 密钥）

```bash
# MIT Kerberos 1.15+ 支持 -norandkey
# 效果：把 KDC 当前密钥导出到 keytab，KVNO 保持不变
kadmin.local -q "ktadd -norandkey -k /var/krb5kdc/emr.keytab hadoop/10.8.1.107@EMR-0ATE1KFO"
```

> ⚠️ 如果版本不支持 `-norandkey`，使用标准 `ktadd`（会递增 KVNO，其他持有旧 keytab 的节点也需更新）：
> ```bash
> kadmin.local -q "ktadd -k /var/krb5kdc/emr.keytab hadoop/10.8.1.107@EMR-0ATE1KFO"
> ```

### 场景 B：Principal 不匹配

确认 keytab 中的 principal 是否与 kinit 命令中指定的 **完全一致**（包括主机名/IP、REALM 大小写）：

```bash
klist -kt /var/krb5kdc/emr.keytab | grep hadoop
```

常见陷阱：
- keytab 里是 FQDN（`hadoop/node1.cluster.com`），命令行用的是 IP（`hadoop/10.8.1.107`）
- REALM 大小写不一致（`EMR-0ATE1KFO` vs `emr-0ate1kfo`）

### 场景 C：Enctype 不匹配

修改 `/etc/krb5.conf`，放开 enctype 限制：

```ini
[libdefaults]
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 des3-cbc-sha1
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 des3-cbc-sha1
    permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 des3-cbc-sha1
```

或者用指定 enctype 重新导出 keytab：

```bash
kadmin.local -q "ktadd -e des3-cbc-sha1:normal -k /var/krb5kdc/emr.keytab hadoop/10.8.1.107@EMR-0ATE1KFO"
```

### 修复后验证

```bash
# 确认新 keytab 的 KVNO 与 KDC 一致
klist -kte /var/krb5kdc/emr.keytab

# 重新认证
kinit -kt /var/krb5kdc/emr.keytab hadoop/10.8.1.107@EMR-0ATE1KFO

# 确认票据
klist
```

---

## 五、预防措施

| # | 措施 | 优先级 |
|---|------|--------|
| 1 | **操作规范**：任何 `ktadd`/`change_password` 操作后，立即同步更新所有使用该 principal 的 keytab 文件 | P0 |
| 2 | **监控告警**：定时脚本对比 keytab KVNO 与 KDC KVNO，不一致则告警 | P1 |
| 3 | **变更记录**：所有 Kerberos 密钥变更操作纳入变更管理流程，记录操作人/时间/影响范围 | P1 |
| 4 | **使用 `-norandkey`**：导出 keytab 时优先使用 `-norandkey` 避免不必要的 KVNO 递增 | P2 |
| 5 | **keytab 集中管理**：对多节点共用同一 principal 的场景，使用自动化分发（如 Ansible）保持一致 | P2 |

### 预防脚本示例：KVNO 一致性检查

```bash
#!/bin/bash
# kvno_check.sh - 检查 keytab 与 KDC 的 KVNO 是否一致
KEYTAB="/var/krb5kdc/emr.keytab"

klist -kt "$KEYTAB" | grep -v "^Keytab\|^KVNO\|^----\|^$" | while read kvno ts princ; do
    kdc_kvno=$(kadmin.local -q "getprinc $princ" 2>/dev/null | grep "Key: vno" | awk '{print $3}' | tr -d ',')
    if [ "$kvno" != "$kdc_kvno" ]; then
        echo "[MISMATCH] $princ: keytab=$kvno, KDC=$kdc_kvno"
    else
        echo "[OK] $princ: kvno=$kvno"
    fi
done
```

---

## 六、排查流程图

```
kinit -kt 报 "Password incorrect"
    │
    ▼
[Step 1] klist -kte 查看 keytab principal + enctype + kvno
    │
    ├── principal 不存在 ──→ 根因：Principal 不匹配 ──→ 场景 B
    │
    ▼
[Step 2] 对比 krb5.conf permitted_enctypes
    │
    ├── enctype 不在白名单 ──→ 根因：Enctype 不匹配 ──→ 场景 C
    │
    ▼
[Step 3] kadmin.local getprinc 查 KDC 侧 kvno
    │
    ├── KDC kvno > keytab kvno ──→ 根因：KVNO 不匹配 ──→ 场景 A ✅
    │
    ▼
[Step 4] KRB5_TRACE 开 debug 看详细错误
    │
    └── 进一步定位（时钟偏差 / KDC 不可达 / 其他）
```

---

## 七、相关知识点

### KVNO（Key Version Number）机制

- 每次对 principal 执行 `ktadd`（默认 randkey）或 `change_password`，KDC 会生成新密钥并 KVNO+1
- keytab 是密钥的**静态快照**，不会自动同步 KDC 的变更
- KDC 验证时会检查客户端提供的 KVNO 是否与当前存储的匹配
- `-norandkey` 参数可以导出当前密钥而不生成新密钥，KVNO 保持不变

### 常见触发 KVNO 递增的操作

| 操作 | 是否递增 KVNO |
|------|---------------|
| `kadmin ktadd` (默认) | ✅ 是 |
| `kadmin ktadd -norandkey` | ❌ 否 |
| `kadmin change_password` | ✅ 是 |
| `kadmin modprinc` (改属性) | ❌ 否 |
| `kadmin addprinc` (新建) | N/A（初始值=1） |

---

## 八、本次排查时间线

| 时间 | 操作 | 结果 |
|------|------|------|
| 15:04 | kinit -kt 报错 | Password incorrect |
| 15:05 | klist -kt 查看 keytab | principal 存在，KVNO=1 |
| 15:06 | klist -kte 查看 enctype | des3-cbc-sha1，与 krb5.conf 一致 |
| 15:07 | kadmin.local getprinc | 发现 KDC 上 Key: vno 2 |
| — | **根因确认** | keytab KVNO=1 ≠ KDC KVNO=2 |

**根因一句话**：2026-04-29 14:38 有人变更了 `hadoop/10.8.1.107` 的密钥（KVNO 1→2），但未同步更新 `/var/krb5kdc/emr.keytab`，导致 keytab 中的旧密钥无法通过 KDC 验证。

---

*文档作者：eric | 日期：2026-04-29*
