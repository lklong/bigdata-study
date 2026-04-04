# Hadoop HDFS — 分布式存储核心

---

## 一、概述

HDFS（Hadoop Distributed File System）是 Hadoop 生态的分布式存储基石。集群中几乎所有数据（Hive 表、Spark 数据、HBase 数据）最终都存在 HDFS 上。

**在集群中的角色**：最底层的存储引擎，所有上层组件依赖它。HDFS 出问题 = 整个集群出问题。

---

## 二、架构

### 2.1 核心架构

```
客户端
  ↕ 元数据操作（文件名→Block位置）
NameNode（主节点）
  ├── FSImage（文件系统快照）
  ├── EditLog（操作日志）
  └── Block Map（Block→DataNode映射，内存中）
  ↕ 心跳 + Block汇报
DataNode（数据节点 × N）
  └── Block 文件（默认128MB/块，3副本）
```

### 2.2 HA 架构

```
Active NameNode ←── ZK Failover Controller ──→ Standby NameNode
       │                   ↕                        │
       └──── JournalNode 集群（共享 EditLog）────────┘
```

### 2.3 Federation 架构（大规模集群扩展）

```
NameNode-1 (namespace: /user)  ──→ Block Pool 1
NameNode-2 (namespace: /data)  ──→ Block Pool 2
NameNode-3 (namespace: /hive)  ──→ Block Pool 3
      ↕            ↕            ↕
  共享 DataNode 集群（存所有 Block Pool）

客户端通过 ViewFS 统一视图访问：
viewfs://cluster/ → 按路径路由到不同 NameNode
```

**Federation 适用条件**：单 NN 内存 >200GB 或文件数 >10 亿
**局限**：跨 namespace 不能硬链接，需提前规划拆分

---

## 三、版本信息

| 版本 | 发布时间 | 关键变更 |
|------|----------|---------|
| 3.4.0 | 2024-03 | 3.4 系列首发，2888 项修复 |
| 3.4.2 | 2025 | 修复 CVE-2025-27821（libhdfs 越界写入） |
| **3.4.3** | **2026-02** | ⚠️ **不再内置 AWS SDK bundle.jar**，S3A 需手动加依赖 |

**升级 3.4.3 注意**：使用 S3/OSS 的环境必须手动下载 AWS SDK 2.35.4 放到 `share/hadoop/common/lib/`

---

## 四、常见故障排查

### 4.1 NameNode RPC 延迟高

**现象**：上层应用（Hive/Spark）变慢，NN Web UI 显示 RPC 延迟 >5s

**排查路径**（由浅到深）：

1. **查文件总数**：`hdfs dfs -count /` → >5000万就可能是小文件问题
2. **定位小文件目录**：`hdfs dfs -ls -R / | awk '{if($5<131072) print $8}' | head -50`
3. **查 NN JVM 状态**：`jstat -gcutil <nn_pid> 1000 5` → GC 时间占比
4. **查 NN 线程**：`jstack <nn_pid> | grep "IPC Server handler"` → 是否有大量线程阻塞
5. **查 NN 堆内存**：Web UI → Overview → Heap Memory Used

**解决方案**：
- 小文件合并（HAR / CombineFileInputFormat / Spark repartition）
- 增大 NN 堆内存：`-Xmx100g`（每 1 亿文件约需 60-80G 堆）
- 考虑 Federation（终极方案）

### 4.2 NameNode 启动慢

**现象**：NN 启动或 HA failover 耗时 >5min

**排查**：
1. 检查 EditLog 数量：`ls $HADOOP_HOME/data/dfs/nn/current/edits_* | wc -l`
2. 检查 checkpoint 频率：`dfs.namenode.checkpoint.period`（默认 3600s）
3. 手动触发 checkpoint：`hdfs dfsadmin -saveNamespace`（需 SafeMode）

### 4.3 HDFS SafeMode 退不出

**现象**：`hdfs dfsadmin -safemode get` 返回 ON

**排查**：
1. 检查 DN 存活数：`hdfs dfsadmin -report | grep "Live datanodes"`
2. 检查 Block 上报比例：NN Web UI → Overview → Blocks（需 >99.9%）
3. 检查是否有坏盘：`dmesg | grep -i "error\|I/O"` on DN nodes
4. 确认安全后强制退出：`hdfs dfsadmin -safemode leave`

### 4.4 DataNode 磁盘使用不均

**现象**：部分 DN 磁盘 >90%，部分 <50%

**解决**：
```bash
# 限速启动 balancer（50MB/s，业务低峰执行）
hdfs balancer -threshold 10 \
  -D dfs.datanode.balance.bandwidthPerSec=52428800
```

---

## 五、性能调优

### 5.1 关键参数

| 参数 | 默认值 | 建议值 | 说明 |
|------|--------|--------|------|
| `dfs.replication` | 3 | 3 | 副本数，勿随意改 |
| `dfs.blocksize` | 128MB | 128MB~256MB | 大文件可用 256MB |
| `dfs.namenode.handler.count` | 10 | 100~200 | NN 处理线程数，按集群规模调 |
| `dfs.datanode.handler.count` | 10 | 20~50 | DN 处理线程数 |
| `dfs.namenode.checkpoint.period` | 3600 | 3600 | checkpoint 间隔（秒） |
| `dfs.namenode.checkpoint.txns` | 1000000 | 1000000 | 超过 N 个事务触发 checkpoint |

### 5.2 JVM 调优

```bash
# NameNode（根据文件数调整）
-Xms60g -Xmx60g -XX:+UseG1GC -XX:MaxGCPauseMillis=200

# DataNode
-Xms4g -Xmx4g -XX:+UseG1GC
```

---

## 六、最佳实践

1. **NN 元数据目录**：`dfs.namenode.name.dir` 配置多个路径（不同磁盘），互为备份
2. **JournalNode**：至少 3 个，分布在不同机架
3. **EditLog 和 Block Report**：分离到不同磁盘
4. **定期 fsck**：`hdfs fsck / -files -blocks` 检查数据完整性
5. **Balancer**：每周定期执行一次，保持磁盘均衡
6. **Snapshot**：关键目录开启快照功能，用于数据恢复

---

## 七、命令速查

```bash
# 集群状态
hdfs dfsadmin -report                    # 集群概况
hdfs dfsadmin -safemode get              # SafeMode 状态
hdfs haadmin -getServiceState nn1        # NN HA 角色

# 文件操作
hdfs dfs -count /path                    # 目录文件数/大小统计
hdfs dfs -du -s -h /path                 # 目录实际大小
hdfs dfs -ls -R /path | wc -l           # 递归文件数

# 健康检查
hdfs fsck / -files -blocks -locations    # 数据块完整性
hdfs fsck / -openforwrite                # 正在写入的文件

# Balancer
hdfs balancer -threshold 10              # 磁盘均衡

# 快照
hdfs dfsadmin -allowSnapshot /path       # 开启快照
hdfs dfs -createSnapshot /path snap1     # 创建快照
```
