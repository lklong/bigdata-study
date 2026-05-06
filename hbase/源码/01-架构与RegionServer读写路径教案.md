# HBase 第一课：架构与 RegionServer 读写路径

> **教学目标**：学完本课后，你能画出 HBase 的完整架构图，解释一条数据从客户端到最终落盘的完整路径，并理解为什么 HBase 适合"海量数据随机读写"场景。

---

## 一、先讲个故事（白话层）

把 HBase 想象成一个**超级大的自助快递柜系统**：

- **HMaster**：快递柜公司的总部，管理所有快递柜的分配
- **RegionServer**：一栋楼里的快递柜集合
- **Region**：一组连续编号的柜子（比如 1-1000 号）
- **RowKey**：你的取件码（排好序的！按照字典序排列）
- **MemStore**：快递员的手持设备（内存缓冲，快速接收包裹）
- **HFile**：最终存进仓库的文件（HDFS 上的数据文件）
- **WAL（Write-Ahead Log）**：登记本（先记账再操作，防丢件）

你寄件（写入）：先在登记本上记一笔（WAL） → 放进手持设备缓冲区（MemStore） → 满了就批量入库（Flush 到 HFile）

你取件（读取）：先看缓冲区有没有（MemStore） → 没有就去仓库找（HFile） → 用 Bloom Filter 快速定位

---

## 二、架构全景图

```
┌──────────────────────────────────────────────────────┐
│                     Client                            │
│  (通过 ZooKeeper 找到 meta 表位置，定位 RegionServer) │
└────────────────────────┬─────────────────────────────┘
                         │
            ┌────────────┼────────────┐
            ▼            ▼            ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ RegionServer-1  │ │ RegionServer-2  │ │ RegionServer-3  │
│ ┌─────────────┐ │ │ ┌─────────────┐ │ │ ┌─────────────┐ │
│ │  Region-A   │ │ │ │  Region-C   │ │ │ │  Region-E   │ │
│ │ (row a-m)   │ │ │ │ (row a-k)   │ │ │ │ (row a-f)   │ │
│ ├─────────────┤ │ │ ├─────────────┤ │ │ ├─────────────┤ │
│ │  Region-B   │ │ │ │  Region-D   │ │ │ │  Region-F   │ │
│ │ (row n-z)   │ │ │ │ (row l-z)   │ │ │ │ (row g-z)   │ │
│ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────┘ │
└────────┬────────┘ └────────┬────────┘ └────────┬────────┘
         │                   │                   │
         └───────────────────┼───────────────────┘
                             │
                    ┌────────▼────────┐
                    │      HDFS       │  数据最终存在 HDFS 上
                    │  (HFile + WAL)  │
                    └─────────────────┘

                    ┌─────────────────┐
                    │    ZooKeeper    │  存储 meta 表位置 + RS 注册
                    └─────────────────┘

                    ┌─────────────────┐
                    │     HMaster     │  Region 分配 + 负载均衡 + DDL
                    └─────────────────┘
```

---

## 三、写入路径（Write Path）

```
Client.put(rowKey, value)
    │
    ▼ ① 客户端定位：通过 ZK → meta 表 → 找到 RowKey 所在的 RegionServer
RegionServer
    │
    ├─ ② 写 WAL（Write-Ahead Log）
    │     → 追加写入 HDFS 上的 WAL 文件
    │     → 目的：防止 RegionServer 宕机时内存数据丢失
    │
    ├─ ③ 写 MemStore
    │     → 内存中的有序 Map（跳表/ConcurrentSkipListMap）
    │     → 写入即返回成功给客户端！
    │
    └─ ④ MemStore 满了 → Flush
          → 将内存数据排序后写成 HFile（Sorted String Table）
          → HFile 存到 HDFS
          → 同时生成 Bloom Filter（加速后续查找）
```

**关键设计**：
- **先写 WAL 再写 MemStore** → 保证数据不丢（WAL 在 HDFS 上，3 副本）
- **MemStore 是跳表** → 内存中有序，Flush 时直接顺序写出
- **写入只涉及追加操作** → 极高的写入吞吐量

---

## 四、读取路径（Read Path）

```
Client.get(rowKey)
    │
    ▼ ① 定位 RegionServer（同写入）
RegionServer
    │
    ├─ ② 查 BlockCache（读缓存）
    │     → 命中则直接返回
    │
    ├─ ③ 查 MemStore（写缓存）
    │     → 最新数据可能还在内存中
    │
    └─ ④ 查 HFile（磁盘文件）
          ├─ Bloom Filter 快速判断"这个 key 可能在这个文件中吗？"
          ├─ 如果 Bloom Filter 说"不在" → 跳过这个文件
          └─ 如果 Bloom Filter 说"可能在" → 读取文件中的 Data Block 查找

最终结果 = merge(BlockCache, MemStore, HFile1, HFile2, ...)
          取时间戳最新的版本返回
```

**读取优化三板斧**：
1. **BlockCache** — LRU 缓存热点数据块
2. **Bloom Filter** — 一次磁盘 I/O 都不浪费
3. **Compaction** — 减少需要扫描的 HFile 数量

---

## 五、数据模型

```
HBase 数据模型 = (RowKey, Column Family:Qualifier, Timestamp) → Value

示例：用户表
┌──────────────────────────────────────────────────────────────┐
│  RowKey      │ CF:info              │ CF:stats              │
│              │ name    │ age        │ login_count │ score   │
├──────────────┼─────────┼────────────┼─────────────┼─────────┤
│ user_001     │ "Alice" │ 25         │ 100         │ 95.5    │
│ user_002     │ "Bob"   │ 30         │ 50          │ 88.0    │
│ user_003     │ "Carol" │ 28         │ 200         │ 92.3    │
└──────────────┴─────────┴────────────┴─────────────┴─────────┘

特点：
  - RowKey 按字典序排列（决定数据分布！）
  - Column Family 物理隔离存储（不同 CF 是不同的 HFile）
  - 每个 Cell 可以有多个版本（按 Timestamp）
  - 稀疏表：不同行可以有不同的列
```

---

## 六、HBase vs 关系型数据库 vs HDFS

| 维度 | HBase | MySQL | HDFS |
|------|-------|-------|------|
| 数据模型 | 宽列（NoSQL） | 行列固定（SQL） | 文件 |
| 随机读写 | **毫秒级** | 毫秒级 | 不支持 |
| 批量扫描 | 秒级 | 较慢（大表） | **最强** |
| 数据量级 | PB 级 | TB 级 | PB 级 |
| Schema | 灵活（稀疏列） | 严格 | 无 |
| 事务 | 行级原子性 | ACID | 无 |
| 适用场景 | 海量随机读写 | OLTP 事务 | 批处理/存储 |

---

## 七、课堂练习

### 练习 1：RowKey 设计

> 场景：监控系统需要存储每台服务器每分钟的 CPU 使用率。要求：①能快速查询某台服务器最近 1 小时的数据 ②数据均匀分布

设计：
```
RowKey = reverse(hostname) + "_" + (Long.MAX_VALUE - timestamp)
例如: moc.elpmaxe.bew_9999999999999876543

为什么：
  - reverse(hostname)：避免热点（同前缀的 key 集中在同一个 Region）
  - Long.MAX_VALUE - timestamp：最新数据排在前面，scan 时自然获取最新数据
```

### 练习 2：举一反三

> "HBase 的 MemStore + WAL + HFile 与 Kafka 的 Page Cache + Log Segment 有什么同构？"

答：
- HBase WAL ≈ Kafka 的 Segment File（都是顺序追加的持久化日志）
- HBase MemStore ≈ Kafka 的 Page Cache（都是内存缓冲加速写入）
- HBase HFile ≈ Kafka 的 Index File（都是有序结构方便查找）
- 共同原理：**LSM 思想** — 先缓冲在内存，攒够一批再顺序写磁盘

---

## 八、知识晶体

```
问题/场景: 如何实现 PB 级数据的毫秒级随机读写？
核心机制: LSM-Tree (Log-Structured Merge Tree) + Region 分区 + HDFS 存储
调用链: Client → ZK(meta定位) → RegionServer → WAL+MemStore → Flush → HFile(HDFS)
设计意图: 将随机写转为顺序写（MemStore flush），将随机读通过 Bloom Filter + Cache 加速
关键参数:
  hbase.hregion.memstore.flush.size    → MemStore flush 阈值（默认 128MB）
  hbase.regionserver.global.memstore.size → RS 总 MemStore 占堆内存比例（默认 0.4）
  hfile.block.cache.size                → BlockCache 占堆内存比例（默认 0.4）
  hbase.hstore.compaction.min           → 触发 Minor Compaction 的最小文件数（默认 3）
踩坑记录:
  - RowKey 设计不好导致热点 Region（所有请求打到一台 RS）
  - MemStore 过大导致 Flush 风暴 + RS 暂停（Block）
  - Compaction 在业务高峰期执行导致读写延迟飙升
认知更新: HBase 本质是"HDFS 之上的随机访问层"——通过 LSM-Tree 把随机 I/O 转化为顺序 I/O，用写放大换读性能
```
