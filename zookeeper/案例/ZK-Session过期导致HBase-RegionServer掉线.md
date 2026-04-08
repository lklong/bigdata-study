# ZooKeeper Session 过期导致 HBase RegionServer 掉线

> ZK Expert 案例学习 — ZK 会话超时引发雪崩

## 案例背景

```
环境: HBase 2.4 + ZooKeeper 3.6, 50 RegionServer, 3 ZK 节点
现象:
  - 10 个 RegionServer 同时掉线（ZK Session 过期）
  - HBase Master 触发大规模 Region 迁移
  - 迁移过程中集群不可用 20 分钟
  - 但 RegionServer 机器本身没有任何异常（CPU/内存/磁盘都正常）
```

## 排查过程

### Step 1: ZK 日志分析

```
ZK Server 日志:
  07:30:01 INFO  Expiring session 0x1234abcd, timeout of 30000ms exceeded
  07:30:01 INFO  Expiring session 0x1234abce, timeout of 30000ms exceeded
  ... (10 个 session 在同一秒过期)

ZK Client (RegionServer) 日志:
  07:30:00 WARN  Client session timed out, have not heard from server in 35012ms
  07:30:00 INFO  Unable to reconnect to ZooKeeper service, session 0x1234abcd has expired
  07:30:01 FATAL Lost connection to ZK, shutting down RegionServer
```

### Step 2: 为什么 10 个 RS 同时过期？

```
排查 ZK Server 的 GC 日志:
  07:29:25 [GC pause] 5.2 seconds  ← ZK Server 发生了 5.2 秒的 Full GC！

时间线:
  07:29:25  ZK Leader Full GC 开始 (5.2s)
  07:29:30  GC 结束，ZK 恢复
  07:29:30  ZK 检查所有 session → 发现 10 个 session 在 GC 期间没有心跳
  07:30:01  sessionTimeout=30s 到期 → 批量过期

根因: ZK Leader 节点发生 Full GC → 无法处理心跳 → 多个 session 同时超时
```

### Step 3: 为什么 ZK Leader 会 Full GC？

```
ZK Leader 的 JVM 配置:
  -Xmx2g -XX:+UseG1GC

ZK 数据量:
  znode_count = 150,000 (HBase 的 Region 信息)
  approximate_data_size = 800MB

问题: 800MB 数据在 2GB 堆上 → 堆使用率 > 50% → G1 频繁 Mixed GC → 偶发 Full GC
```

### Step 4: 修复

```bash
# 1. ZK JVM 调优
-Xmx4g -Xms4g           # 堆翻倍
-XX:MaxGCPauseMillis=50  # 降低 GC 暂停目标
-XX:+UseG1GC
-XX:G1HeapRegionSize=4m

# 2. HBase Session Timeout 调大
hbase.zookeeper.property.sessionTimeout=90000  # 30s → 90s

# 3. ZK 独立部署（不和 DataNode 混部）
# 之前 ZK 和 DN 混部，DN 的 I/O 影响 ZK 的 fsync

# 4. 开启 ZK 的 maxSessionTimeout 保护
maxSessionTimeout=120000  # 允许 Client 设更大的超时
```

## 经验规则

```
R-ZK-001: ZK Leader 堆内存至少是数据量的 3 倍以上
R-ZK-002: ZK 必须独立部署，不和计算/存储服务混部
R-ZK-003: HBase sessionTimeout 生产环境建议 60-120s（不是默认 30s）
R-ZK-004: ZK 的 GC 暂停 > sessionTimeout/3 就有雪崩风险
R-ZK-005: ZK 节点数推荐 5 个（容忍 2 个故障），不是 3 个
```

---

*ZooKeeper Expert 案例产出 | 2026-04-08*
