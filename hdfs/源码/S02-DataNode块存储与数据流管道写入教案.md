# HDFS 第二课：DataNode 块存储与数据流管道写入

> **教学目标**：学完本课后，你能画出 HDFS 写入数据时的管道（Pipeline）工作原理，解释为什么 HDFS 默认 3 副本，以及 DataNode 如何管理本地块存储。

---

## 一、先讲个故事（白话层）

想象你在寄一份**特别重要的合同**，需要保证安全送达：

1. 你把合同交给**第一个快递员**（DataNode-1）
2. 第一个快递员**一边收件一边转发**给第二个快递员（DataNode-2）
3. 第二个快递员**一边收件一边转发**给第三个快递员（DataNode-3）
4. 第三个快递员收完后，回复"收到"给第二个
5. 第二个收到确认后，回复"收到"给第一个
6. 第一个收到确认后，回复"收到"给你

这就是 HDFS 的**管道写入（Pipeline Write）**——数据像流水一样在 DataNode 之间传递，不需要等一个写完再传下一个。

---

## 二、HDFS 写入流程全景图

```
Client（你的应用程序）
    │
    │ ① create("/data/file.txt")
    ▼
NameNode（总管）
    │ 返回：[DN-1, DN-2, DN-3]（副本放置位置）
    │
    │ ② 建立管道
    ▼
Client → DN-1 → DN-2 → DN-3  （Pipeline 建立）
    │
    │ ③ 写入数据（以 Packet 为单位，默认 64KB）
    │
    │   Packet-1 ──→ DN-1 ──→ DN-2 ──→ DN-3
    │   Packet-2 ──→ DN-1 ──→ DN-2 ──→ DN-3
    │   ...
    │
    │ ④ 确认回传（ACK Pipeline）
    │
    │   DN-3 ──ACK──→ DN-2 ──ACK──→ DN-1 ──ACK──→ Client
    │
    │ ⑤ 关闭管道
    ▼
Client: "写入完成！"
```

### 关键设计思想

**为什么用管道而不是并行写？**

```
并行写（Client 同时发给 3 个 DN）：
  网络带宽 = Client 上行 × 3
  Client 成为瓶颈！（一份数据传 3 次）

管道写（Client → DN1 → DN2 → DN3）：
  每个节点只需发送 1 次
  Client 上行带宽 = 1 份数据
  总时间 ≈ 传输 1 次的时间（管道并行！）
```

**类比**：就像消防员传水桶——不是每个人都回水源取水，而是排成一队传递。

---

## 三、副本放置策略

```
3 副本放置规则（默认）：
┌──────────────┐
│ 第 1 副本     │ → 写入发起节点（或离客户端最近的节点）
│ 第 2 副本     │ → 不同机架的某个节点（跨机架容灾）
│ 第 3 副本     │ → 与第 2 副本同机架的另一个节点（减少跨机架流量）
└──────────────┘

为什么这样设计？
  - 第 1+第 3 在同机架 → 写入快（机架内带宽高）
  - 第 2 在不同机架 → 容灾好（整个机架掉电也不丢数据）
  - 权衡了性能和可靠性
```

## 四、DataNode 本地块存储

```
DataNode 磁盘目录结构：
/dfs/data/
├── current/
│   ├── BP-123456-192.168.1.1-1234567890/  （Block Pool）
│   │   └── current/
│   │       ├── finalized/           （已完成的块）
│   │       │   └── subdir0/
│   │       │       └── subdir1/
│   │       │           ├── blk_1073741825        （数据文件）
│   │       │           └── blk_1073741825.meta   （校验和文件）
│   │       └── rbw/                 （正在写入的块 = Replica Being Written）
│   └── VERSION                      （版本信息）
└── in_use.lock                      （防止多实例）
```

### 块的生命周期状态

```
FINALIZED ← 正常状态：写入完成，数据完整
RBW       ← 正在写入：客户端正在往里写数据
RWR       ← 等待恢复：DataNode 重启后发现未完成的块
RUR       ← 正在恢复中
TEMPORARY ← 临时状态：块复制/均衡过程中
```

## 五、Packet 与 Chunk

```
HDFS 写入的数据组织：

Block (默认 128MB)
├── Packet (默认 64KB)
│   ├── Chunk-1 (默认 512 bytes) + Checksum (4 bytes CRC32C)
│   ├── Chunk-2 (512 bytes) + Checksum (4 bytes)
│   ├── ...
│   └── Chunk-N (512 bytes) + Checksum (4 bytes)
├── Packet-2
└── ...

为什么分这么多层？
  Block → 大粒度管理单位（NameNode 内存友好）
  Packet → 网络传输单位（流式传输，不用等整个 Block）
  Chunk  → 校验单位（每 512 字节一个校验和，发现损坏精确到 512B）
```

## 六、课堂练习

### 练习 1：计算写入带宽

> 场景：写入一个 1GB 文件，3 副本，集群网络带宽 10Gbps。管道写入 vs 并行写入，分别需要多少时间？

答：
- 管道写入：Client 只发 1GB，耗时 = 1GB / 10Gbps ≈ 0.8秒（管道中 DN1→DN2→DN3 与 Client→DN1 并行）
- 并行写入：Client 发 3GB，耗时 = 3GB / 10Gbps ≈ 2.4秒（Client 上行带宽被分为 3 份）
- 管道写入快 **3 倍**！

### 练习 2：举一反三

> "HDFS 的管道写入与 Kafka 的 ISR 复制有什么异同？"

同：都是数据从一个节点流向下一个节点，保证多副本一致性
异：HDFS 是同步管道（必须所有副本确认），Kafka ISR 可以配置 `min.insync.replicas`

---

## 七、知识晶体

```
问题/场景: HDFS 如何高效写入大文件并保证多副本一致性？
核心机制: Pipeline Write + ACK 反向确认
设计意图: 最大化网络带宽利用率，Client 只需上传一次数据
关键参数:
  dfs.replication           → 副本数（默认 3）
  dfs.blocksize             → 块大小（默认 128MB）
  dfs.client-write-packet-size → Packet 大小（默认 64KB）
  dfs.bytes-per-checksum    → Chunk 校验粒度（默认 512 bytes）
踩坑记录:
  - 管道中某个 DN 失败：Client 通知 NameNode，NameNode 选择新 DN 重建管道
  - 写入期间 DN 宕机不会丢数据：已确认的 Packet 至少有 min(dfs.replication, 当前管道长度) 个副本
认知更新: HDFS 写入本质是"流式管道复制"，这个模式在分布式系统中普遍存在（Chain Replication）
```
