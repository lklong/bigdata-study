# ZooKeeper — 分布式协调服务

---

## 一、概述

Apache ZooKeeper 是分布式协调服务，提供配置管理、命名服务、分布式锁、Leader 选举等能力。

**在集群中的角色**：基础设施的基础设施。HDFS HA、HBase、Kafka、Kyuubi 等都依赖 ZK。ZK 挂了 = 一切都挂。

---

## 二、架构与 ZAB 协议

### 2.1 集群架构

```
Client ←→ Leader（接收写请求，广播给 Follower）
Client ←→ Follower（接收读请求，转发写请求给 Leader）
Client ←→ Observer（只读，不参与投票，用于扩展读能力）
```

### 2.2 ZAB 协议（ZooKeeper Atomic Broadcast）

| 阶段 | 做什么 | 机制 |
|------|--------|------|
| **选举** | 选 Leader | 过半投票（Quorum）：>N/2 票当选 |
| **原子广播** | 数据同步 | Proposal → ACK（过半）→ Commit |

| 概念 | 说明 |
|------|------|
| **Epoch** | 选举轮次，+1 防旧 Leader 幽灵写入 |
| **ZXID** | 事务 ID = Epoch + Counter |
| **Quorum** | 3 节点容忍 1 故障，5 节点容忍 2 |

### 2.3 脑裂防护

ZK 的 Quorum 机制天然防脑裂：
- 3 节点分成 1+2 → 只有 2 的那半能选 Leader
- 少数派自动降级为 LOOKING 状态，不对外服务

---

## 三、常见故障排查

| 现象 | 检查 | 命令 |
|------|------|------|
| 集群不可用 | 过半节点存活？ | `echo ruok \| nc zk 2181` |
| 选举失败 | myid/网络 | `echo stat \| nc zk 2181` |
| Session 过期 | 心跳超时 | 检查 `tickTime`/`sessionTimeout` |
| 写入慢 | Leader 压力/IO | `echo mntr \| nc zk 2181` |
| 连接数满 | maxClientCnxns | `echo cons \| nc zk 2181` |
| OOM | Watch/快照过大 | `echo wchs \| nc zk 2181` |

---

## 四、性能调优

```properties
dataDir=/data/zk/data
dataLogDir=/data/zk/txnlog           # 事务日志单独 SSD！
tickTime=2000
initLimit=10
syncLimit=5
maxClientCnxns=300
autopurge.snapRetainCount=5
autopurge.purgeInterval=24
```

**JVM**：`-Xms2g -Xmx2g -XX:+UseG1GC`

**部署最佳实践**：
- 生产至少 3 节点，推荐 5 节点
- 奇数节点（偶数无意义）
- 事务日志用 SSD（性能关键）
- 不要和 DN/NM 混部

---

## 五、四字命令速查

```bash
echo ruok | nc zk 2181   # 健康（返回 imok）
echo stat | nc zk 2181   # 角色/连接数
echo mntr | nc zk 2181   # 监控指标
echo cons | nc zk 2181   # 连接列表
echo wchs | nc zk 2181   # Watch 统计
echo envi | nc zk 2181   # 环境信息
echo dump | nc zk 2181   # 临时节点
```
