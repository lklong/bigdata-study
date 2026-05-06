# 教案 S01：Kerberos 认证流程 — 大数据集群的身份证系统

> **课时**：45分钟 | **难度**：⭐⭐⭐

## 一、课前导入 — 为什么你的 Spark 作业报 "GSSException: No valid credentials"？

> 你的 Spark 作业每天凌晨 2 点跑，跑了 3 个月一直正常。突然有一天报错了：`GSSException: No valid credentials provided`。原因：**Keytab 对应的 Kerberos 票据过期了**，或者 KDC 服务挂了。

## 二、核心概念 — 游乐园门票系统

把 Kerberos 想象成游乐园的**三方认证系统**：

| 角色 | 游乐园类比 | Kerberos 实体 |
|------|-----------|--------------|
| **你** | 游客 | Client (用户/服务) |
| **售票处** | 验证身份，发门票 | KDC - Authentication Server (AS) |
| **检票员** | 验证门票有效性 | KDC - Ticket Granting Server (TGS) |
| **游乐设施** | 你要访问的服务 | Service (HDFS/Hive/Kafka...) |
| **门票** | 证明你的身份 | Ticket (TGT / Service Ticket) |

### 三次握手流程

```
Step 1: AS-REQ → AS-REP (你去售票处买"通票")
  Client → KDC(AS): "我是 user@REALM，请给我 TGT"
  KDC(AS) → Client: "[TGT] + [Session Key]" (用你的密码加密)

Step 2: TGS-REQ → TGS-REP (你用通票换"单项票")
  Client → KDC(TGS): "[TGT] + 我要访问 hdfs/nn@REALM"
  KDC(TGS) → Client: "[Service Ticket for HDFS]"

Step 3: AP-REQ → AP-REP (你拿着单项票进入设施)
  Client → HDFS NameNode: "[Service Ticket]"
  NameNode: 验证 Ticket → 确认身份 → 允许访问
```

## 三、大数据场景中的 Kerberos

### 3.1 Keytab — 免密码认证

```bash
# Keytab = 密码的加密存储文件，免交互认证
kinit -kt /etc/security/keytabs/hdfs.keytab hdfs/nn1@EXAMPLE.COM

# Spark 作业使用 Keytab
spark-submit \
  --principal user@EXAMPLE.COM \
  --keytab /path/to/user.keytab \
  myJob.jar
```

### 3.2 Delegation Token — 为什么需要它？

```
问题：Spark 有 1000 个 Executor，每个都要访问 HDFS。
      如果每个 Executor 都走完整 Kerberos 三步握手 → KDC 被打爆！

解决：Driver 拿到 HDFS 的 Delegation Token（有效期 24h）
      把 Token 分发给所有 Executor
      Executor 用 Token 直接访问 HDFS，不需要再找 KDC

类比：老师带 50 个学生参观博物馆
      不是每个学生都去买票 → 老师买一张团体票，带着大家一起进
```

### 3.3 常见问题排查

| 报错 | 原因 | 解法 |
|------|------|------|
| `No valid credentials` | TGT 过期 | `kinit` 重新认证，或检查 Keytab |
| `Clock skew too great` | 时钟偏差 > 5分钟 | `ntpdate` 同步时间 |
| `Server not found in Kerberos database` | Principal 拼写错误 | 检查 `klist -kt` |
| `Checksum failed` | Keytab 与 KDC 中密码不同步 | 重新导出 Keytab |
| `Connection refused to KDC` | KDC 服务挂了 | 检查 KDC 进程和端口 88 |

## 四、课堂练习

### 思考题：为什么 Delegation Token 有有效期限制？

<details>
<summary>参考答案</summary>

安全考虑：
1. Token 如果永不过期，被截获后攻击者可以永久使用
2. Token 不像 TGT 那样绑定到 KDC Session → 无法被 KDC 主动撤销
3. 所以设置有效期（默认 24h），需要 Token Renewer 定期续期
4. 最大续期次数也有限制（`dfs.namenode.delegation.token.max-lifetime`）

Spark/Flink 的 Driver 有 Token Renewal 线程自动续期。
</details>

## 五、知识晶体

```
Kerberos = 三方认证(Client + KDC + Service)
三步: AS-REQ(获TGT) → TGS-REQ(获ServiceTicket) → AP-REQ(访问服务)
Keytab: 免密码文件，生产环境必用
Delegation Token: 避免大量Executor都找KDC，Driver代劳
常见坑: 时钟偏差/Keytab过期/Principal拼错
```

*教案作者：Eric | 最后更新：2026-04-30*
