# Kerberos — 集群认证协议

---

## 一、概述

Kerberos 是大数据集群的标准认证协议，通过对称密钥加密实现"你是谁"的验证。

**在集群中的角色**：服务间（NN↔DN、HS2↔NN）和用户→服务的身份认证。不开 Kerberos = 裸奔。

---

## 二、认证流程

```
1. kinit → 客户端向 KDC(AS) 请求 TGT
2. TGT → KDC 返回 TGT（有效期默认 10h）
3. 客户端用 TGT 向 KDC(TGS) 请求 Service Ticket
4. Service Ticket → 客户端出示给目标服务（如 HDFS NameNode）
5. 服务验证 → 允许访问
```

### 核心概念

| 概念 | 说明 | 运维关注 |
|------|------|---------|
| **KDC** | 密钥分发中心 | 单点风险，需 HA |
| **Principal** | `user/host@REALM` | 大小写敏感 |
| **Keytab** | 免密密钥文件 | 权限 600 |
| **TGT** | 票据授权票据 | 默认 10h，可续期 7d |
| **Realm** | 认证域（大写） | 跨域需 cross-realm trust |

---

## 三、常见故障排查（5 步法）

| 步骤 | 检查 | 命令 |
|------|------|------|
| 1. 时钟 | 偏差 <5min | `pdsh -a "date" \| sort` / `ntpdate ntp.aliyun.com` |
| 2. Keytab | 是否有效 | `klist -kt /path/keytab` + `kinit -kt ...` |
| 3. KDC | 是否可达 | `telnet kdc-host 88` |
| 4. krb5.conf | REALM/KDC 对不对 | `cat /etc/krb5.conf` |
| 5. DNS | 正反向解析一致 | `nslookup hostname` + `nslookup IP` |

### 高频错误速查

| 错误 | 根因 | 解决 |
|------|------|------|
| `Clock skew too great` | 时间不同步 | ntpdate |
| `No valid credentials` | TGT 过期 | kinit 重新获取 |
| `Pre-authentication failed` | 密码/keytab 错 | 检查 keytab |
| `Server not found in Kerberos database` | Principal 不存在 | kadmin 创建 |
| `Cannot find KDC` | KDC 不可达 | 检查网络/krb5.conf |

---

## 四、票据自动续期

| 方案 | 场景 | 配置 |
|------|------|------|
| keytab 自动续期 | Hadoop 服务 | Hadoop 内置，确认 `auth_to_local` |
| cron + kinit | 脚本/用户 | `0 */4 * * * kinit -kt keytab principal` |
| k5start | 容器/K8s | `k5start -f keytab -K 60 -U` |

**KDC 侧配置**：
```
max_life = 24h
max_renewable_life = 7d
```

---

## 五、跨域认证（Cross-Realm Trust）

```bash
# REALM_A 的 KDC 上
kadmin.local -q "addprinc -pw PWD krbtgt/REALM_B@REALM_A"
# REALM_B 的 KDC 上
kadmin.local -q "addprinc -pw PWD krbtgt/REALM_A@REALM_B"
# 两边 krb5.conf 互配、core-site.xml 配 auth_to_local 映射规则
```

---

## 六、命令速查

```bash
kinit principal@REALM               # 获取 TGT
kinit -kt /path/keytab principal    # 用 keytab 获取
klist                                # 查看当前票据
klist -kt /path/keytab              # 查看 keytab 内容
kdestroy                             # 销毁票据
kadmin.local                         # KDC 管理
kadmin.local -q "listprincs"        # 列出所有 principal
```
