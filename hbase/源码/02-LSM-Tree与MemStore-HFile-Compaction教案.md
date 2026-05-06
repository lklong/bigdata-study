# HBase 第二课：LSM-Tree 与 MemStore/HFile/Compaction

> **教学目标**：学完本课后，你能解释 LSM-Tree 的核心思想"以写放大换读性能"，画出 Compaction 的两种策略（Minor/Major）流程，理解为什么 Compaction 会导致"写停顿"。

---

## 一、先讲个故事（白话层）

想象你在管理一个**图书馆的新书入库系统**：

**笨方法（B+Tree / MySQL 模式）**：每来一本新书，立刻找到书架上正确的位置插入——需要挪动很多书（随机写，慢！）

**聪明方法（LSM-Tree / HBase 模式）**：
1. 新书先放到**桌上**（MemStore，内存）
2. 桌子满了，把桌上的书**按字母排好序**，整批搬到一个新书架上（Flush → HFile）
3. 书架越来越多，定期**合并几个书架为一个大书架**（Compaction）

**代价（Trade-off）**：
- 写入快了（只追加不插入）
- 读取要多看几个书架（需要合并多个 HFile 的结果）
- 后台合并消耗 I/O（写放大）

---

## 二、LSM-Tree 核心数据结构

```
Level-0: MemStore (内存中的有序跳表)
         │
         │ Flush (128MB 满了)
         ▼
Level-1: HFile-1  HFile-2  HFile-3  (磁盘上的 SSTable)
         │
         │ Minor Compaction (合并几个小文件)
         ▼
Level-2: HFile-A  HFile-B  (更大的有序文件)
         │
         │ Major Compaction (合并所有文件为一个)
         ▼
Level-3: HFile-Final  (单个超大有序文件)
```

### 2.1 MemStore — 内存写缓冲

```java
// HBase 内部使用 ConcurrentSkipListMap
ConcurrentSkipListMap<Cell, Cell> cellSet;

// 特点：
// ① 有序（按 RowKey + CF + Qualifier + Timestamp 排序）
// ② 并发安全（支持多线程同时写入）
// ③ 达到阈值后 Flush 为 HFile
```

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hbase.hregion.memstore.flush.size` | 128MB | 单个 MemStore flush 阈值 |
| `hbase.regionserver.global.memstore.size` | 0.4 | RS 全部 MemStore 占堆比例 |
| `hbase.regionserver.global.memstore.size.lower.limit` | 0.95 | 触发强制 flush 的下限比例 |

### 2.2 HFile — 磁盘有序文件（SSTable）

```
HFile 内部结构：
┌──────────────────────────────────────────────────────┐
│  Data Block 1  │  数据块（默认 64KB，存储排序后的 KV）  │
│  Data Block 2  │                                     │
│  ...           │                                     │
│  Data Block N  │                                     │
├──────────────────────────────────────────────────────┤
│  Meta Block    │  Bloom Filter 数据                   │
├──────────────────────────────────────────────────────┤
│  File Info     │  文件元信息                          │
├──────────────────────────────────────────────────────┤
│  Data Index    │  Data Block 的索引（多级索引树）      │
├──────────────────────────────────────────────────────┤
│  Meta Index    │  Meta Block 的索引                   │
├──────────────────────────────────────────────────────┤
│  Trailer       │  固定大小，指向各部分偏移量           │
└──────────────────────────────────────────────────────┘

读取过程：
  ① 读 Trailer（文件末尾，找到索引位置）
  ② 读 Data Index（二分查找定位 Data Block）
  ③ 读 Bloom Filter（快速判断 key 是否在此文件）
  ④ 读 Data Block（获取实际数据）
```

---

## 三、Compaction — 文件合并

### 3.1 为什么需要 Compaction？

```
随着 Flush 不断执行，HFile 越来越多：

Flush 前：   MemStore
Flush 后：   HFile-1, HFile-2, HFile-3, ... HFile-100

问题：
  读取时需要扫描所有 HFile → 读放大 → 性能下降
  
解决：
  定期将多个 HFile 合并成少数大文件 = Compaction
```

### 3.2 Minor Compaction vs Major Compaction

| 维度 | Minor Compaction | Major Compaction |
|------|-----------------|-----------------|
| 合并范围 | 选择**部分** HFile（3-10个） | 合并**所有** HFile 为 1 个 |
| 删除标记 | **不处理** Delete 标记 | **清除** Delete 标记和过期版本 |
| I/O 开销 | 中等 | **巨大**（全量重写） |
| 触发方式 | 自动（文件数达到阈值） | 自动（7天一次）或手动 |
| 执行频率 | 频繁（分钟级） | 罕见（天/周级） |
| 对读的影响 | 减少文件数 | 读性能最优化 |
| 对写的影响 | 轻微 | **可能阻塞写入！** |

### 3.3 Compaction 流程图

```
Minor Compaction:
  [HFile-1] [HFile-2] [HFile-3]
       │         │         │
       └─────────┼─────────┘
                 │ 合并排序
                 ▼
         [HFile-New]  (保留 Delete 标记)

Major Compaction:
  [HFile-A] [HFile-B] [HFile-C] [HFile-D]
       │         │         │         │
       └─────────┴─────────┴─────────┘
                           │ 合并排序 + 删除过期数据
                           ▼
                   [HFile-Final]  (清除 Delete 标记)
```

### 3.4 写放大问题

```
写放大（Write Amplification）= 实际写入磁盘的数据量 / 用户写入的数据量

例如：用户写入 1MB 数据
  → Flush 到 HFile: 1MB (放大 1x)
  → Minor Compaction: 再写 1MB (放大 2x)
  → Major Compaction: 再写 1MB (放大 3x)
  总写放大 ≈ 3x ~ 10x（取决于 Compaction 层数）

对比：
  B+Tree（MySQL）: 写放大 ~2x（WAL + 数据页）
  LSM-Tree（HBase）: 写放大 ~10x
  
但 LSM 的每次写都是顺序写，B+Tree 是随机写
顺序写吞吐 >> 随机写吞吐 → LSM 总体写入吞吐更高
```

---

## 四、调优策略

### 4.1 Compaction 配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `hbase.hstore.compaction.min` | 3 | 触发 Minor 的最小文件数 |
| `hbase.hstore.compaction.max` | 10 | 一次 Minor 最多合并文件数 |
| `hbase.hstore.compaction.max.size` | Long.MAX | 参与 Compaction 的最大文件大小 |
| `hbase.hregion.majorcompaction` | 604800000 (7天) | Major Compaction 自动触发间隔 |
| `hbase.hregion.majorcompaction.jitter` | 0.5 | 随机抖动（防止所有 Region 同时 Major） |

### 4.2 生产建议

```properties
# ⚠️ 生产环境关闭自动 Major Compaction，改为调度执行！
hbase.hregion.majorcompaction = 0

# 原因：
# Major Compaction 会重写所有数据文件，I/O 巨大
# 在业务高峰期执行会导致 RS 响应延迟飙升
# 建议在凌晨通过脚本手动触发

# 调整 Minor Compaction 触发条件
hbase.hstore.compaction.min = 5          # 少触发一点
hbase.hstore.compaction.max = 10         # 每次多合并一点
hbase.hstore.compaction.ratio = 1.2      # 文件大小比率（越大越不容易触发）
```

---

## 五、课堂练习

### 练习 1：计算写放大

> 场景：某 Region 的 MemStore 大小 128MB，Minor Compaction 合并 5 个文件，一天执行 3 次 Minor + 1 次 Major。用户每天写入 1GB 数据。实际磁盘写入量？

答：
- Flush: 1GB（用户数据）
- 3 次 Minor: 约 3 × (5 × 128MB) = 1.9GB（假设每次合并 5 个 128MB 文件）
- 1 次 Major: 约 1GB + 1.9GB = 2.9GB（重写所有数据）
- 总磁盘写入 ≈ 1 + 1.9 + 2.9 = **5.8GB**
- 写放大 = 5.8 / 1 = **~6x**

### 练习 2：举一反三

> "HBase 的 Compaction 与 Iceberg 的 RewriteDataFiles 有什么同构关系？"

答：
- 都是"后台文件合并"——将碎片文件整理为大文件
- 都是为了优化读性能——减少扫描文件数
- 都有写放大问题——合并需要重写所有数据
- 区别：HBase 在 RS 内部自动执行，Iceberg 通过 Spark/Amoro 外部触发

---

## 六、知识晶体

```
问题/场景: HBase 写入很快但读延迟有时不稳定
核心机制: LSM-Tree = MemStore(内存缓冲) + HFile(磁盘SSTable) + Compaction(后台合并)
设计意图: 将随机写转为顺序写，牺牲一定的读性能和磁盘空间换取极高的写吞吐
关键参数:
  hbase.hregion.memstore.flush.size     → 128MB（Flush 阈值）
  hbase.hstore.compaction.min           → 3（Minor 触发文件数）
  hbase.hregion.majorcompaction         → 建议设为 0（关闭自动Major）
踩坑记录:
  - Major Compaction 在业务高峰期触发 → RS 响应超时 → RegionServer 假死
  - MemStore 过多导致堆内存不足 → 触发全局 Flush → 写入阻塞
  - Compaction 队列堆积 → HFile 数量爆炸 → 读性能断崖式下降
认知更新: LSM-Tree 的核心公式：写吞吐 ∝ 1/写放大系数，读性能 ∝ 1/HFile数量。Compaction 是在两者之间找平衡的旋钮
```
