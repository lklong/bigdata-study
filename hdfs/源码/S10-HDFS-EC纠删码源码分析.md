# [教案] HDFS Erasure Coding 纠删码源码分析

> 🎯 教学目标：掌握 HDFS EC 纠删码的策略管理、StripedBlock 读写原理、数据恢复机制 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：RAID 5 的网盘版

想象你有一张重要的照片（比如 1MB），你害怕硬盘坏了丢失数据。

**传统方案（3 副本复制）：** 把照片复制 3 份，分别存在 3 个硬盘里。安全，但要花 3MB 空间。**存储效率只有 33%**。

**纠删码方案（RS-6-3）：** 把照片切成 6 片（每片约 170KB），然后用数学公式算出 3 片"校验片"。总共 9 片分散存到 9 个硬盘。任意坏 3 个硬盘，都能用剩下的 6 片数学恢复出原始数据。**存储效率达到 67%**！

这就是 HDFS 3.0 引入的 **Erasure Coding (EC)** 特性 —— 用 Reed-Solomon 编码在不降低可靠性的前提下，将存储开销从 200% 降到 50%。

### 生产场景

某大数据团队 HDFS 集群有 100PB 数据，3 副本需要 300PB 磁盘。引入 EC 后：
- 冷数据（占 70%）使用 RS-6-3 策略，存储开销从 200% 降到 50%
- 热数据（占 30%）保持 3 副本保证读取性能
- **节省了约 100PB 磁盘空间**，每年省下数百万元存储成本

> **注意**：本地源码仓库为 Hadoop 2.8.5（EC 特性在 3.0 中引入），以下分析基于 Hadoop 3.x 架构设计，结合 2.8.5 已有的 BlockManager 基础进行讲解。

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| **Erasure Coding (EC)** | 纠删码编码技术，将数据编码为数据块+校验块 | RAID 5/6 的分布式版本 |
| **Reed-Solomon (RS)** | 最常用的 EC 编码算法 | 二维码的纠错原理 |
| **ErasureCodingPolicy** | EC 策略，定义数据块/校验块数量和 Cell 大小 | 保险方案：选几份副本、几份校验 |
| **StripedBlock** | 条带化块，一个逻辑块由多个内部块组成 | 一本书被拆成多个章节分开存放 |
| **Cell** | EC 编码的最小单元（默认 1MB） | 书中的每一页 |
| **Stripe** | 一组 Cell 构成的条带 | 一整行书架（数据+校验） |
| **Data Block** | 存储实际数据的内部块 | 书的正文章节 |
| **Parity Block** | 存储校验数据的内部块 | 书的"纠错附录" |
| **BlockGroup** | 一个 StripedBlock 的所有内部块的集合 | 整个书架组 |
| **ErasureCodingPolicyManager** | EC 策略管理器，管理所有可用的 EC 策略 | 保险公司的方案管理中心 |
| **DFSStripedOutputStream** | EC 写入流，将数据条带化写入多个 DataNode | 多人协作抄写，每人写不同章节 |
| **DFSStripedInputStream** | EC 读取流，从多个 DataNode 并行读取并解码 | 多人同时翻书，拼接完整内容 |

### 2.2 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    HDFS EC 整体架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Client 层                                                   │
│  ┌───────────────────┐    ┌───────────────────┐             │
│  │DFSStripedOutput   │    │DFSStripedInput    │             │
│  │Stream             │    │Stream             │             │
│  │                   │    │                   │             │
│  │ ┌─────────────┐   │    │ ┌─────────────┐   │             │
│  │ │ RS Encoder   │   │    │ │ RS Decoder   │   │             │
│  │ └─────────────┘   │    │ └─────────────┘   │             │
│  └───────┬───────────┘    └───────┬───────────┘             │
│          │                        │                          │
├──────────┼────────────────────────┼──────────────────────────┤
│          ▼                        ▼                          │
│  NameNode 层                                                 │
│  ┌───────────────────────────────────────────┐               │
│  │         ErasureCodingPolicyManager        │               │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐     │               │
│  │  │RS-6-3   │ │RS-3-2   │ │RS-10-4  │     │               │
│  │  │1MB Cell │ │1MB Cell │ │1MB Cell │     │               │
│  │  └─────────┘ └─────────┘ └─────────┘     │               │
│  └───────────────────────────────────────────┘               │
│  ┌───────────────────────────────────────────┐               │
│  │  BlockManager (StripedBlock 管理)          │               │
│  │  - BlockInfoStriped 替代 BlockInfoContiguous│               │
│  │  - 副本放置策略适配 EC                       │               │
│  └───────────────────────────────────────────┘               │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  DataNode 层                                                 │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐│
│  │D0  │ │D1  │ │D2  │ │D3  │ │D4  │ │D5  │ │P0  │ │P1  │ │P2  ││
│  │    │ │    │ │    │ │    │ │    │ │    │ │    │ │    │ │    ││
│  │DN1 │ │DN2 │ │DN3 │ │DN4 │ │DN5 │ │DN6 │ │DN7 │ │DN8 │ │DN9 ││
│  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘│
│  ← 6 个数据块 →                      ← 3 个校验块 →              │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 EC 编码原理（RS-6-3 示例）

```
原始数据: [D0, D1, D2, D3, D4, D5]  (6 个数据块)

Reed-Solomon 编码矩阵:
┌     ┐   ┌                ┐   ┌     ┐
│ D0  │   │ 1  0  0  0  0  0 │   │ D0  │
│ D1  │   │ 0  1  0  0  0  0 │   │ D1  │
│ D2  │   │ 0  0  1  0  0  0 │   │ D2  │
│ D3  │ = │ 0  0  0  1  0  0 │ × │ D3  │
│ D4  │   │ 0  0  0  0  1  0 │   │ D4  │
│ D5  │   │ 0  0  0  0  0  1 │   │ D5  │
│ P0  │   │ a  b  c  d  e  f │   │     │
│ P1  │   │ g  h  i  j  k  l │   │     │
│ P2  │   │ m  n  o  p  q  r │   │     │
└     ┘   └                ┘   └     ┘

任意丢失最多 3 个块 → 用剩余 6 个块 + 编码矩阵的逆矩阵恢复
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

> 注：以下类在 Hadoop 3.x 中引入，本地 2.8.5 仓库中没有这些文件。分析基于 Hadoop 3.x 社区源码。

| 核心类 | 所在模块 | 职责 |
|--------|----------|------|
| `ErasureCodingPolicyManager` | hdfs-server (namenode) | 管理所有 EC 策略的生命周期 |
| `ErasureCodingPolicy` | hdfs-client | EC 策略的数据模型（data blocks、parity blocks、cell size） |
| `ECSchema` | hdfs-common | EC 编码方案定义（编码器类型 + 参数） |
| `DFSStripedOutputStream` | hdfs-client | 条带化写入流，负责数据编码和并行写入 |
| `DFSStripedInputStream` | hdfs-client | 条带化读取流，负责并行读取和解码恢复 |
| `StripedBlockUtil` | hdfs-client | 条带化块的工具类（计算 Cell 位置等） |
| `BlockInfoStriped` | hdfs-server (namenode) | NameNode 中 EC 块的元数据表示 |
| `BlockManager.processReport()` | hdfs-server (namenode) | 处理 EC 块的汇报（已有基础在 2.8.5 中） |
| `ErasureCodeNative` | hadoop-common | ISA-L 加速的编码/解码本地库 |

### 3.2 关键源码剖析

#### 3.2.1 ErasureCodingPolicyManager — EC 策略管理

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ErasureCodingPolicyManager.java
// Hadoop 3.x 源码

/**
 * 管理所有 EC 策略的生命周期
 * 系统预置了 5 种策略，用户也可以自定义
 */
public final class ErasureCodingPolicyManager {

  // 系统预置的 EC 策略（5种）
  private static final ErasureCodingPolicy[] SYS_POLICIES;
  
  static {
    SYS_POLICIES = new ErasureCodingPolicy[] {
      // 策略名称            数据块数  校验块数  Cell大小
      SystemErasureCodingPolicies.getByID(
          SystemErasureCodingPolicies.RS_6_3_POLICY_ID),  // RS-6-3-1024k
      SystemErasureCodingPolicies.getByID(
          SystemErasureCodingPolicies.RS_3_2_POLICY_ID),  // RS-3-2-1024k
      SystemErasureCodingPolicies.getByID(
          SystemErasureCodingPolicies.RS_6_3_LEGACY_POLICY_ID),
      SystemErasureCodingPolicies.getByID(
          SystemErasureCodingPolicies.XOR_2_1_POLICY_ID), // XOR-2-1-1024k
      SystemErasureCodingPolicies.getByID(
          SystemErasureCodingPolicies.RS_10_4_POLICY_ID)  // RS-10-4-1024k
    };
  }

  // 当前所有策略（系统 + 用户自定义）
  private Map<Byte, ErasureCodingPolicy> policiesByID;
  // 已启用的策略
  private Map<Byte, ErasureCodingPolicy> enabledPoliciesByName;

  /**
   * 给目录设置 EC 策略
   * 通过 hdfs ec -setPolicy -path /data -policy RS-6-3-1024k
   */
  public synchronized void checkPolicy(String ecPolicyName)
      throws UnknownErasureCodingPolicyException {
    // 检查策略是否存在且已启用
    if (!enabledPoliciesByName.containsKey(ecPolicyName)) {
      throw new UnknownErasureCodingPolicyException(
          "Policy '" + ecPolicyName + "' is not enabled");
    }
  }
}
```

**关键设计点：**
- EC 策略挂在**目录级别**，而非文件级别（类似 StoragePolicy）
- 子文件继承父目录的 EC 策略
- 策略一旦设置，已有文件不受影响，只影响新创建的文件

#### 3.2.2 DFSStripedOutputStream — EC 条带化写入

```java
// 文件: hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/DFSStripedOutputStream.java
// Hadoop 3.x 源码

/**
 * EC 写入流 —— 最复杂的 EC 类
 * 将用户数据编码为 data+parity，并行写入多个 DataNode
 */
public class DFSStripedOutputStream extends DFSOutputStream
    implements StreamCapabilities {

  // 协调器：管理所有内部 DataStreamer
  private final Coordinator coordinator;
  
  // 每个内部块一个 StripedDataStreamer
  // RS-6-3 策略 = 6个数据Streamer + 3个校验Streamer = 9个
  private final StripedDataStreamer[] streamers;
  
  // Cell 缓冲区
  private final CellBuffers cellBuffers;
  
  // RS 编码器
  private final RawErasureEncoder encoder;
  
  // 当前条带中已写的 cell 数量
  private int currentCellIndex;

  /**
   * 写入数据的核心方法
   * 用户调用 write(byte[]) 时进入
   */
  @Override
  protected synchronized void writeChunk(byte[] bytes, int offset,
      int len, byte[] checksum, int ckoff, int cklen) throws IOException {
    
    final int cellSize = ecPolicy.getCellSize();
    final int numDataBlocks = ecPolicy.getNumDataUnits();
    
    // 1. 将数据写入当前 Cell 缓冲区
    cellBuffers.write(bytes, offset, len);
    
    // 2. Cell 写满后，切换到下一个 DataStreamer
    currentCellIndex++;
    if (currentCellIndex == numDataBlocks) {
      // 一个 Stripe 的数据 Cell 全部写完
      // 3. 触发 RS 编码，生成校验 Cell
      encode(cellBuffers);
      
      // 4. 将数据 Cell 发送给对应的 Data Streamer
      //    将校验 Cell 发送给对应的 Parity Streamer
      flushAllInternals();
      
      currentCellIndex = 0;
    }
  }

  /**
   * RS 编码核心：将 numDataBlocks 个数据 Cell 编码为 numParityBlocks 个校验 Cell
   */
  private void encode(CellBuffers cellBuffers) throws IOException {
    // inputs: 6 个数据 Cell（RS-6-3 场景）
    ByteBuffer[] inputs = cellBuffers.getDataBuffers();
    // outputs: 3 个校验 Cell
    ByteBuffer[] outputs = cellBuffers.getParityBuffers();
    
    // 调用 RS 编码器（可能走 ISA-L 本地加速）
    encoder.encode(inputs, outputs);
  }
}
```

**写入流程时序图：**

```
Client                DFSStripedOutputStream         9个StripedDataStreamer        9个DataNode
  |                          |                              |                         |
  |--- write(data) -------->|                              |                         |
  |                          |                              |                         |
  |                          |-- 填充 Cell[0] (DN1的数据) --|                         |
  |                          |-- 填充 Cell[1] (DN2的数据) --|                         |
  |                          |-- 填充 Cell[2] (DN3的数据) --|                         |
  |                          |-- 填充 Cell[3] (DN4的数据) --|                         |
  |                          |-- 填充 Cell[4] (DN5的数据) --|                         |
  |                          |-- 填充 Cell[5] (DN6的数据) --|                         |
  |                          |                              |                         |
  |                          |== RS Encode ================|                         |
  |                          |-- 生成 Parity[0] (DN7的校验)-|                         |
  |                          |-- 生成 Parity[1] (DN8的校验)-|                         |
  |                          |-- 生成 Parity[2] (DN9的校验)-|                         |
  |                          |                              |                         |
  |                          |-- flushAllInternals() ------>|                         |
  |                          |                              |--- 并行写入 9个DN ----->|
  |                          |                              |                         |
  |<-- ack ------------------|<--- ack --------------------|<--- ack ---------------|
```

#### 3.2.3 DFSStripedInputStream — EC 条带化读取

```java
// 文件: hadoop-hdfs-client/src/main/java/org/apache/hadoop/hdfs/DFSStripedInputStream.java
// Hadoop 3.x 源码

public class DFSStripedInputStream extends DFSInputStream {

  private final RawErasureDecoder decoder;
  
  /**
   * 读取数据时，只需要读 numDataBlocks 个数据块
   * 正常情况不需要读校验块
   */
  @Override
  protected synchronized int readWithStrategy(ReaderStrategy strategy)
      throws IOException {
    
    // 1. 计算当前读取位置对应哪些 Cell
    StripeRange stripeRange = StripedBlockUtil.getStripeRange(
        getPosition(), readLen, ecPolicy);
    
    // 2. 并行从对应的 DataNode 读取数据 Cell
    //    （正常情况只读 6 个数据块，不读 3 个校验块）
    AlignedStripe[] stripes = StripedBlockUtil.divideOneStripe(
        ecPolicy, cellSize, blockGroup, ...);
    
    for (AlignedStripe stripe : stripes) {
      // 3. 并行读取
      readOneStripe(stripe);
      
      // 4. 如果某个数据块读取失败，启用降级读取
      if (stripe.hasFailed()) {
        // 读取校验块，用 RS 解码恢复丢失的数据块
        degradedRead(stripe);
      }
    }
  }
  
  /**
   * 降级读取：当某个数据块不可用时，
   * 读取校验块 + 可用数据块，通过 RS 解码恢复数据
   */
  private void degradedRead(AlignedStripe stripe) throws IOException {
    // 1. 确定哪些块缺失
    int[] erasedIndices = stripe.getErasedIndices();
    
    // 2. 读取额外的校验块来补足
    readParityBlocks(stripe);
    
    // 3. RS 解码恢复缺失的数据
    decoder.decode(availableData, erasedIndices, recoveredData);
  }
}
```

#### 3.2.4 数据恢复（重建丢失的 Strip）

当 DataNode 宕机导致某些内部块丢失时，NameNode 会调度重建任务：

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/ErasureCodingWork.java
// Hadoop 3.x 源码

/**
 * EC 数据恢复工作单元
 * 由 BlockManager.computeReconstructionWork() 创建
 */
public class ErasureCodingWork extends BlockReconstructionWork {

  // 源节点：提供可用数据/校验块的 DataNode
  private final DatanodeDescriptor[] sources;
  // 目标节点：存储恢复后数据的 DataNode
  private final DatanodeDescriptor[] targets;
  // 缺失的内部块索引
  private final byte[] liveBlockIndices;

  /**
   * 重建流程：
   * 1. NameNode 检测到 StripedBlock 缺少内部块
   * 2. 创建 ErasureCodingWork 调度重建
   * 3. 通过心跳下发 DNA_ERASURE_CODING_RECONSTRUCTION 命令给目标 DN
   * 4. 目标 DN 从源 DN 读取足够的数据/校验块
   * 5. 用 RS 解码重建缺失的内部块
   * 6. 将重建的块存储到本地
   */
}
```

**恢复流程图：**

```
         NameNode
            |
    检测到 DN7 宕机
    BlockGroup 缺少 P0
            |
            ▼
    选择 Target DN（DN10）
    下发重建命令
            |
            ▼
    ┌───────────────────────────────────────────┐
    │              DN10 (Target)                 │
    │                                           │
    │  1. 从 DN1~DN6 读取 D0~D5 (6个数据块)      │
    │  2. RS Encode 重新计算 P0                   │
    │  3. 将 P0 存储到本地                        │
    │  4. 向 NameNode 汇报                       │
    └───────────────────────────────────────────┘
```

### 3.3 与 2.8.5 BlockManager 的关联

虽然 2.8.5 没有 EC，但其 BlockManager 的设计为 EC 打下了基础：

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/BlockManager.java
// 2.8.5 源码

// BlockInfo 是块元数据的基类
// 3.x 中新增了 BlockInfoStriped 子类
// 3.x: BlockInfo → BlockInfoContiguous (原有副本模式)
//                → BlockInfoStriped   (EC 条带模式)

// 2.8.5 中只有 BlockInfoContiguous:
public class BlockInfoContiguous extends BlockInfo {
    // 每个副本的存储位置
    private DatanodeStorageInfo[] storages;
    // 副本因子
    private short replication;
}

// 3.x 中新增 BlockInfoStriped:
// public class BlockInfoStriped extends BlockInfo {
//     // 内部块索引 → 存储位置的映射
//     // RS-6-3: 最多9个内部块
//     private DatanodeStorageInfo[] storages;
//     private byte[] indices;  // 每个存储位置对应的内部块索引
//     private ErasureCodingPolicy ecPolicy;
// }
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：EC 写入超时，客户端报错

```
ERROR: Failed to write to striped block group
Caused by: java.io.IOException: 
  Failed to get 9 DataNodes for RS-6-3-1024k policy,
  only got 7 live DataNodes
```

**原因**：RS-6-3 策略需要至少 9 个 DataNode（6 数据 + 3 校验），集群中存活 DataNode 不足。

**排障步骤**：
```bash
# 1. 检查存活 DataNode 数量
hdfs dfsadmin -report | grep "Live datanodes"

# 2. 检查是否有 DataNode 正在退役
hdfs dfsadmin -report | grep "Decommission"

# 3. 如果 DataNode 确实不足，可以降级为 RS-3-2 策略
hdfs ec -setPolicy -path /data -policy RS-3-2-1024k
```

#### 场景2：EC 文件读取性能差

**原因**：EC 读取需要从多个 DataNode 并行读取（6个），不像副本模式只需读 1 个 DN。如果某个 DN 响应慢，会拖慢整体。

**排障步骤**：
```bash
# 1. 检查慢节点
hdfs ec -verifyClusterSetup

# 2. 检查网络延迟
# EC 对网络要求更高，因为要并行读 6+ 个节点

# 3. 检查 ISA-L 本地库是否加载（影响编码/解码性能）
hadoop checknative -a | grep ISA-L
```

### 4.2 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.namenode.ec.system.default.policy` | RS-6-3-1024k | 默认 EC 策略 |
| `dfs.datanode.ec.reconstruction.stripedread.timeout.millis` | 5000 | EC 重建读取超时 |
| `dfs.datanode.ec.reconstruction.stripedread.buffer.size` | 65536 | EC 重建读取缓冲区 |
| `dfs.datanode.ec.reconstruction.threads` | 8 | EC 重建线程数 |
| `io.erasurecode.codec.rs.rawcoder` | org.apache.hadoop.io.erasurecode.rawcoder.NativeRSRawErasureCoderFactory | RS 编码器实现 |

### 4.3 EC 策略选择建议

| 策略 | 存储开销 | 最少DN数 | 容错数 | 适用场景 |
|------|----------|---------|--------|----------|
| RS-3-2-1024k | 67% | 5 | 2 | 小集群冷数据 |
| RS-6-3-1024k | 50% | 9 | 3 | 中大集群冷数据 |
| RS-10-4-1024k | 40% | 14 | 4 | 大集群归档数据 |
| XOR-2-1-1024k | 50% | 3 | 1 | 极小集群测试 |
| 3-副本（对比） | 200% | 3 | 2 | 热数据、小文件 |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 系统 | HDFS EC | Ceph EC | Azure Blob | 
|------|---------|---------|------------|
| 编码算法 | RS/XOR | RS/LRC | LRC |
| 编码位置 | Client 端 | OSD 端 | 存储节点 |
| 恢复调度 | NameNode | CRUSH+Monitor | Storage Controller |
| 最小分布 | dataUnits+parityUnits 个节点 | 故障域控制 | 自动 |

**与 RAID 的对比：**
- RAID 5：相当于 XOR-N-1（异或校验）
- RAID 6：相当于 RS-N-2（两个校验块）
- HDFS EC RS-6-3：比 RAID 6 更强（3个校验块）

### 5.2 面试高频题

**Q1: HDFS EC 和传统 3 副本有什么区别？各自适用什么场景？**

A: 3 副本存储开销 200%，读写性能好，适合热数据和小文件。EC 存储开销 33%~50%，写入需要编码，读取需要从多个 DN 并行读，适合大文件冷数据。EC 不适合频繁修改的文件（不支持 append/hflush）。

**Q2: EC 文件能否做 append 操作？为什么？**

A: 不能。因为 EC 是条带化写入，append 意味着在不完整的条带上继续写入，而校验块已经计算完成。如果 append，需要重新计算整个条带的校验数据，代价极高。这是 EC 的主要限制之一。

**Q3: EC 数据恢复和副本模式的数据恢复有什么不同？**

A: 副本模式恢复简单——从另一个副本直接复制。EC 恢复需要读取足够多的数据块+校验块（至少 numDataBlocks 个），然后通过 RS 解码重建缺失块，计算开销和网络开销都更大。

**Q4: 为什么 EC 需要 ISA-L 本地库？**

A: RS 编码/解码涉及大量 GF（伽罗华域）矩阵运算。Java 实现的 RS 编码器性能有限（约 200MB/s），ISA-L 利用 SIMD 指令集加速（可达 5GB/s+），性能差距 25 倍。生产环境必须开启 ISA-L。

### 5.3 思考题

1. **如果一个 RS-6-3 的 BlockGroup 同时丢失 4 个内部块，会发生什么？能否恢复？**

2. **EC Cell 大小（默认 1MB）对性能有什么影响？设置过小或过大分别有什么问题？**

3. **如果一个 EC 目录下创建了很多小文件（每个 100KB），存储效率会怎样？为什么？**

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────┐
│                HDFS EC 纠删码知识晶体                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  核心思想: 用数学编码替代完整副本，降低存储开销               │
│                                                             │
│  编码原理:                                                   │
│  ┌─────────────────────────────────────────────┐            │
│  │ 数据 → 切分Cell → RS编码 → 数据块+校验块     │            │
│  │ RS-6-3: 6数据+3校验=9块，存储开销50%          │            │
│  │ 容错: 最多同时丢3块仍可恢复                    │            │
│  └─────────────────────────────────────────────┘            │
│                                                             │
│  写入: DFSStripedOutputStream                               │
│    填Cell→凑齐numData个→RS编码→并行写9个DN                  │
│                                                             │
│  读取: DFSStripedInputStream                                │
│    正常: 并行读6个数据DN (不读校验)                           │
│    降级: 读校验块 + RS解码恢复缺失块                          │
│                                                             │
│  恢复: ErasureCodingWork                                    │
│    NN检测缺失→选Target DN→下发重建命令→DN重建                │
│                                                             │
│  适用场景: 大文件冷数据 (不支持append/hflush)                │
│  不适用: 小文件、频繁修改、低延迟读取                        │
│                                                             │
│  生产关键: ISA-L本地库(25x性能提升)、DN数量 >= 策略要求      │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. [HDFS Erasure Coding 官方文档](https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HDFSErasureCoding.html)
2. [HDFS-7285: Erasure Coding 初始设计文档](https://issues.apache.org/jira/browse/HDFS-7285)
3. [Reed-Solomon 编码原理](https://en.wikipedia.org/wiki/Reed%E2%80%93Solomon_error_correction)
4. [Intel ISA-L (Intelligent Storage Acceleration Library)](https://github.com/intel/isa-l)
5. 本地源码: Hadoop 2.8.5 `BlockManager.java` 中的块管理基础
   - `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/BlockManager.java`
   - `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/blockmanagement/BlockInfoContiguous.java`
