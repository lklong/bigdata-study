# ZooKeeper 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 核心能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **分布式锁** | 互斥访问共享资源 | 创建 EPHEMERAL_SEQUENTIAL 节点 + watch 前序节点 | 锁粒度是节点级；不支持可重入锁（需自己实现） | 用 Curator `InterProcessMutex` |
| **Leader 选举** | 从多个候选中选一个 Leader | EPHEMERAL 节点 + watch | 选举延迟 ~1-5s | 用 Curator `LeaderLatch` |
| **配置中心** | 集中存储和分发配置 | `setData()` + Watcher 通知变更 | 单节点数据 < 1MB（默认） | 不适合存大数据 |
| **服务发现** | 服务注册与发现 | EPHEMERAL 节点注册 + `getChildren()` 发现 | 服务挂 → 节点删除有 sessionTimeout 延迟 | 不是实时感知（秒级） |
| **命名服务** | 全局唯一 ID 生成 | PERSISTENT_SEQUENTIAL 节点 | 序号是 int 范围（~21 亿） | 超大量 ID 用分布式 ID 生成器 |
| **Barrier/屏障** | 同步多个进程的执行点 | 所有参与者创建子节点 → 达到数量后放行 | 参与者数量需预知 | 大数据场景较少用 |
| **Watcher** | 事件通知机制 | `getData(path, watcher=true)` | 一次性触发（3.6+ 支持持久化 Watcher） | 触发后必须重新注册 |
| **ACL** | 节点级权限控制 | `setAcl(path, acls)` | ACL 不递归（子节点需单独设） | 用 `world:anyone:cdrwa` 要小心 |
| **事务** | 多操作原子执行 | `multi()` API | 操作数有限制 | 跨节点事务 |
| **快照** | 内存数据持久化 | 自动完成（snapCount 触发） | 快照期间有短暂延迟 | `autopurge.purgeInterval` 清理旧快照 |

---

## 功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 大数据存储 (> 1MB/节点) | etcd / Consul / Redis |
| 高吞吐消息队列 | Kafka |
| 强一致性 KV 存储 | etcd |
| 复杂查询 | 数据库 |

---

## 关键参数

| 参数 | 默认 | 建议 | 说明 |
|------|------|------|------|
| `tickTime` | 2000ms | 2000ms | 基本时钟单位 |
| `initLimit` | 10 | 10 | Follower 初始化超时 (×tickTime) |
| `syncLimit` | 5 | 5 | Follower 同步超时 (×tickTime) |
| `maxClientCnxns` | 60 | 200 | 单 IP 最大连接数 |
| `autopurge.snapRetainCount` | 3 | 5 | 保留快照数 |
| `autopurge.purgeInterval` | 0 | 24 | 清理间隔 (小时) |
| `jute.maxbuffer` | 1MB | 4MB | 单节点最大数据 |

---

*ZooKeeper Expert | 功能地图 v1.0 | 2026-04-08*
