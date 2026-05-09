# Kerberos 知识体系 README

> 大数据 SRE 必修课 · Eric · 2026-05-09  
> 从 0 到 1 的完整学习路径 · 原理 → 实战 → 集成 → 排障

---

## 一、学习路径（建议顺序）

| 阶段 | 文档 | 时长 | 目标 |
|-----|------|------|------|
| **L1 入门** | [01-Kerberos从0到1-原理深度解析.md](./01-Kerberos从0到1-原理深度解析.md) | 4h | 理解为什么需要 + 六步认证流程 + 核心概念 |
| **L2 实操** | [02-Kerberos实战手册-部署与运维操作.md](./02-Kerberos实战手册-部署与运维操作.md) | 8h | 独立部署 KDC + Principal/Keytab 管理 |
| **L3 集成** | [03-大数据组件Kerberos集成配置大全.md](./03-大数据组件Kerberos集成配置大全.md) | 16h | HDFS/YARN/Hive/Spark/Kyuubi/HBase/Kafka/ZK/Ranger 全集成 |
| **L4 排障** | [04-Kerberos运维问题库Top50.md](./04-Kerberos运维问题库Top50.md) | 持续 | 50 个真实生产问题 + 速查 |
| **L5 应急** | [05-Kerberos排障SOP与工具箱.md](./05-Kerberos排障SOP与工具箱.md) | 持续 | 决策树 + 工具链 + 监控告警 |
| **L6 故障恢复** | [06-Kerberos故障场景恢复手册.md](./06-Kerberos故障场景恢复手册.md) | 持续 | 10 大故障场景端到端恢复 SOP + 复盘模板 |
| **L7 灾备演练** | [07-Kerberos灾备演练剧本.md](./07-Kerberos灾备演练剧本.md) | 持续 | L1-L4 演练剧本 + Chaos Monkey + DR 演练 |

### 老素材（保留参考）
- [Kerberos功能地图.md](./Kerberos功能地图.md) — 能力清单一览
- [Kerberos故障排查决策树.md](./Kerberos故障排查决策树.md) — 旧版决策树
- 源码/ — 早期 4 篇笔记
- 案例/ — 1 个 KVNO 不匹配案例

---

## 二、知识地图（One-Page 全景）

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Kerberos 知识体系                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  原理层（懂为什么）                                                  │
│  ├── 为什么大数据集群必须开 Kerberos                                 │
│  ├── 核心概念字典（KDC/AS/TGS/Principal/Keytab/TGT/ST/KVNO）        │
│  ├── 六步认证全流程（AS_REQ→AS_REP→TGS_REQ→TGS_REP→AP_REQ→AP_REP）  │
│  ├── 加密算法演进（DES→3DES→RC4→AES）                                │
│  ├── Ticket 生命周期 + Flags（FRIA）                                 │
│  ├── Delegation Token 机制                                          │
│  ├── Cross-Realm 跨域信任                                           │
│  └── SPNEGO HTTP 认证                                               │
│                                                                     │
│  实战层（会做事）                                                    │
│  ├── KDC 主备部署（kdc01/kdc02 + kpropd 同步）                       │
│  ├── kadmin 操作大全（addprinc/ktadd/cpw/getprinc/listprincs/...）  │
│  ├── 客户端命令（kinit/klist/kdestroy/kvno/kpasswd/ktutil）          │
│  ├── Java 调试（sun.security.krb5.debug/jaas.conf/UGI）             │
│  ├── 批量初始化脚本（一键创建/分发/巡检）                            │
│  └── ccache 类型选择（FILE/KEYRING/DIR/MEMORY）                     │
│                                                                     │
│  集成层（贯通全栈）                                                  │
│  ├── HDFS（NN/DN/JN + SPNEGO + DataNode SASL）                      │
│  ├── YARN（RM/NM + LinuxContainerExecutor + container-executor）   │
│  ├── MapReduce JobHistoryServer                                    │
│  ├── Hive（Metastore + HS2 + JDBC URL + doAs）                     │
│  ├── Spark（spark-submit --keytab + STS）                           │
│  ├── Kyuubi（多租户代理 + Hadoop ProxyUser）                        │
│  ├── HBase（hbase-jaas.conf + Coprocessor）                         │
│  ├── Kafka（SASL_PLAINTEXT/GSSAPI + KafkaServer JAAS）             │
│  ├── ZooKeeper（SASLAuthenticationProvider）                       │
│  ├── Ranger（Admin/UserSync/Plugin Kerberos）                      │
│  └── Impala（impalad/catalogd/statestored）                         │
│                                                                     │
│  排障层（保稳定）                                                    │
│  ├── 黄金六步法（接报→复现→探针→定位→修复→沉淀）                     │
│  ├── 决策树（kinit→kvno→访问→跨域 四级判断）                         │
│  ├── 工具箱（KRB5_TRACE / sun.security.krb5.debug / tcpdump）       │
│  ├── 50 个真实生产问题（按 9 大类分）                                │
│  ├── 4 大应急预案（KDC 全挂/keytab 错乱/跨域失效/长任务挂）          │
│  └── 监控告警（Prometheus + 健康度评分卡）                           │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、Kerberos 核心心法（10 条）

1. **永远先看时钟** — 80% 的诡异错误最后是时钟问题
2. **永远开 KRB5_TRACE 排障** — 不开 trace 排障等于盲人摸象
3. **永远用 FQDN** — `_HOST` 解析依赖 `hostname -f`，必须正反解齐全
4. **rdns 永远 false** — 反解一旦失败你的 Kerberos 就崩
5. **Keytab 权限永远 400** — 否则就是密码泄漏
6. **KVNO 永远要核对** — keytab 与 KDC 不一致是最常见暗坑
7. **长任务永远传 --keytab** — kinit 走不过 7 天
8. **生产永远不直接 cpw** — 改密码就是 KVNO+1，老 keytab 全废
9. **JCE 永远要解锁** — Java 8 < 152 必装 Policy Files
10. **永远沉淀案例** — 每解决一个问题就进案例库

---

## 四、面试高频题（自检）

### 原理
- [ ] 详细描述 Kerberos 六步认证流程
- [ ] TGT 和 ST 有什么区别？为什么要分两步？
- [ ] Authenticator 的作用是什么？时钟偏差为什么是 5 分钟？
- [ ] KVNO 是什么？KVNO 不一致会怎样？
- [ ] Keytab 和密码的区别？为什么 keytab 是免密的？
- [ ] Delegation Token 比 Kerberos 票据强在哪？

### 实战
- [ ] 怎么部署一套 KDC 主备？
- [ ] 怎么给一个新加入的 NodeManager 节点配 Kerberos？
- [ ] keytab 巡检脚本写一下
- [ ] 怎么改 KDC 数据库的主密钥？

### 集成
- [ ] HDFS DataNode 启动为什么要监听 < 1024 端口（或者 SASL）？
- [ ] HiveServer2 doAs 是什么？开启与关闭的影响？
- [ ] Spark 长任务为什么必须 --keytab？
- [ ] Kyuubi 多租户怎么实现的？

### 排障
- [ ] GSSException No valid credentials provided 怎么排？
- [ ] Server not found in Kerberos database 怎么排？
- [ ] 跨域信任失败怎么排？
- [ ] Web UI 401 怎么排？

---

## 五、扩展阅读

### 官方文档
- MIT Kerberos: https://web.mit.edu/kerberos/krb5-latest/doc/
- RFC 4120 (Kerberos V5): https://datatracker.ietf.org/doc/html/rfc4120
- RFC 4121 (GSS-API): https://datatracker.ietf.org/doc/html/rfc4121
- RFC 4178 (SPNEGO): https://datatracker.ietf.org/doc/html/rfc4178

### 大数据官方
- Hadoop Secure Mode: https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-common/SecureMode.html
- Hive Authentication: https://cwiki.apache.org/confluence/display/Hive/Setting+Up+HiveServer2
- Spark Security: https://spark.apache.org/docs/latest/security.html

### 进阶
- Cloudera Security Guide
- Hortonworks Data Platform Security
- 《Kerberos: The Definitive Guide》— Jason Garman, O'Reilly

---

## 六、文档变更记录

| 日期 | 文档 | 变更 |
|-----|------|------|
| 2026-04-04 | Kerberos原理与排障.md | 初版 |
| 2026-04-08 | Kerberos功能地图/决策树 | 概念整理 |
| 2026-04-30 | S01/S02 笔记 | 学习笔记 |
| 2026-05-09 | **本次重构** | 新增 5 篇深度文档（原理/实战/集成/问题库/SOP），构建从 0 到 1 完整体系 |
| 2026-05-10 | **故障恢复+演练** | 新增 06 故障场景恢复手册 + 07 灾备演练剧本，01 原理篇补充三段式设计哲学 |

---

*Eric · 大数据 SRE AI 专家团队 · Orchestrator · 持续更新*
