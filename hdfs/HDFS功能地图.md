# HDFS 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 一、核心存储能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **文件读写** | 大文件流式读写 | `hdfs dfs -put/-get` 或 `FileSystem.create()/open()` | 不支持随机写入（只追加）；不支持文件修改（需重写整个文件） | 适合一次写入多次读取 (WORM) |
| **目录操作** | 创建/删除/重命名/列表 | `hdfs dfs -mkdir/-rm/-mv/-ls` | `rename` 同 NameNode 内原子，跨 NN 不支持 | 大目录 `ls` 是 NN 性能杀手 |
| **块存储** | 文件按 Block 分片存储 | 自动完成；`dfs.blocksize=128MB`（默认） | 小文件（< blocksize）也占一个 Block 的元数据开销 | 避免百万级小文件 |
| **多副本** | 数据自动复制到多个 DataNode | `dfs.replication=3`（默认） | 3 副本 = 3 倍存储开销 | 冷数据可降到 2 副本；EC 纠删码可降到 1.5 倍 |
| **纠删码 (EC)** | 用 RS 编码替代多副本 | `hdfs ec -setPolicy -path /cold -policy RS-6-3-1024k` | CPU 开销增加 20-30%（编解码）；恢复速度比副本慢 | 仅用于冷数据；热数据继续用 3 副本 |
| **追加写入** | 已有文件末尾追加 | `FileSystem.append(path)` | 同一时刻只能有一个 Writer 追加 | HBase WAL/Flume 使用此特性 |
| **快照** | 目录级别的只读快照 | `hdfs dfsadmin -allowSnapshot /dir` → `hdfs dfs -createSnapshot /dir snap1` | 快照是增量的（COW），不复制数据 | 误删数据的最后防线 |
| **回收站** | 删除文件先移到 Trash | `fs.trash.interval=1440`（分钟） | Trash 也占存储空间 | 定期清理 Trash |

---

## 二、高可用能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **NameNode HA** | Active/Standby 双 NN 热备 | `hdfs-site.xml` 配置 HA + JournalNode/ZK | 需要 3+ JournalNode；需要 ZK | 必须开启防脑裂 (fencing) |
| **自动故障转移** | Active NN 挂 → 自动切 Standby | ZKFC (ZKFailoverController) 自动完成 | 切换时间 ~30-60s | 切换期间 Client 请求阻塞 |
| **Federation** | 多 NameNode 水平扩展 | ViewFS / Router-Based Federation | 跨 namespace 不能 rename | 超过 5 亿文件考虑 Federation |
| **Observer NameNode** | 只读 NN 分流读请求 | `dfs.ha.tail-edits.in-progress=true` | 数据有延迟（秒级）；只能读不能写 | 分析型查询走 Observer 减轻 Active NN 压力 |

---

## 三、数据完整性

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **Checksum** | 每个 Block 的 CRC32 校验 | 自动完成；读取时校验 | 校验有 CPU 开销 (~3%) | 不要关闭 `dfs.checksum.enabled` |
| **Block Scanner** | DataNode 后台定期扫描 Block 完整性 | `dfs.datanode.scan.period.hours=504`（默认 3 周） | 扫描期间增加磁盘 I/O | 不要设太短 |
| **Balancer** | Block 在 DataNode 间均衡分布 | `hdfs balancer -threshold 10` | 占用网络带宽 | 低峰期执行；`dfs.datanode.balance.bandwidthPerSec` 限速 |

---

## 四、权限与安全

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **POSIX 权限** | Unix 风格 rwx 权限 | `hdfs dfs -chmod 755 /dir` | 粒度只到文件/目录级别 | 不够灵活用 ACL |
| **ACL** | 扩展权限控制 | `hdfs dfs -setfacl -m user:bob:rwx /dir` | NameNode 内存开销增加（每个 ACL entry） | 不要滥用 ACL |
| **Kerberos 认证** | 企业级身份认证 | `hadoop.security.authentication=kerberos` | 需要 KDC 基础设施 | 和 Ranger 配合做细粒度授权 |
| **加密区域** | 透明数据加密 (TDE) | `hdfs crypto -createZone -path /encrypted -keyName mykey` | KMS 是单点；加解密有 CPU 开销 | 合规场景必须开启 |
| **Delegation Token** | Client 获取一次 Token → 传给子任务 | Spark/MapReduce 自动获取和传递 | Token 有有效期（默认 24h） | 长时任务需要 Token 续期 |

---

## 五、管理运维能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **安全模式** | NN 启动时等待 Block 报告 | `hdfs dfsadmin -safemode get/enter/leave` | 安全模式下不可写入 | 如果长时间不退出，检查 Block 丢失情况 |
| **fsck** | 文件系统健康检查 | `hdfs fsck / -files -blocks -locations` | 大集群 fsck 非常慢（分钟~小时） | 不要在高峰期执行 |
| **配额** | 目录级别的空间/文件数配额 | `hdfs dfsadmin -setSpaceQuota 1T /user/bob` | 配额检查在 NN 内存中 | 防止单用户占满集群 |
| **存储策略** | Hot/Warm/Cold/AllSSD 多级存储 | `hdfs storagepolicies -setStoragePolicy -path /hot -policy HOT` | 需要 DataNode 配置多种存储类型 | 配合数据生命周期管理 |
| **快速退役 DN** | 安全下线 DataNode | `dfs.hosts.exclude` + `hdfs dfsadmin -refreshNodes` | 退役期间数据迁移占用带宽 | 不要直接 kill DN |

---

## 六、功能边界 — HDFS 做不到什么

| 不支持 | 替代方案 |
|--------|---------|
| 随机写入/更新 | HBase / Iceberg / Hudi |
| 低延迟读取 (< 10ms) | HBase / Redis / Alluxio |
| 小文件高效存储 | HAR 归档 / HBase / 对象存储 |
| POSIX 完整兼容 | Alluxio / CephFS |
| 跨机房同步 | DistCp / 对象存储多区域复制 |
| 多 Writer 并发写同一文件 | 不支持，需应用层协调 |

---

## 七、关键参数速查

| 参数 | 默认 | 建议 | 说明 |
|------|------|------|------|
| `dfs.blocksize` | 128MB | 128-256MB | Block 大小 |
| `dfs.replication` | 3 | 热数据 3 / 冷数据 2 / EC | 副本数 |
| `dfs.namenode.handler.count` | 10 | 100-200 | NN RPC 处理线程数 |
| `dfs.datanode.handler.count` | 10 | 20-50 | DN RPC 线程数 |
| `dfs.namenode.fs-limits.max-directory-items` | 1M | 1M | 单目录最大子项数 |
| `dfs.namenode.acls.enabled` | false | true（需要时） | 启用 ACL |
| `ipc.maximum.data.length` | 64MB | 128MB | RPC 最大数据长度 |

---

*HDFS Expert | 功能地图 v1.0 | 2026-04-08*
