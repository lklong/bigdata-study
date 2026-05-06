# [教案] S09-HDFS快照机制源码深度剖析

> 🎯 教学目标：掌握HDFS快照的COW实现原理、SnapshotManager架构、快照Diff计算机制 | ⏰ 预计学时: 80分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：文档的版本历史

想象你在编辑一份重要的Word文档：
- 你每隔一段时间点"保存版本"（创建快照），比如"V1: 初稿"、"V2: 修改后"
- **关键**：Word不会为每个版本保存一份完整的副本，而是**只记录变化的部分**（这就是COW — Copy-On-Write）
- 当你想回到V1版本时，系统根据当前状态和记录的变化，还原出V1的样子
- 你还可以比较V1和V2的差异（Snapshot Diff）

HDFS快照和这个原理完全一样：
- 创建快照时**不复制任何数据Block**，只在内存中记录一个时间点的"快照标记"
- 后续文件被修改/删除时，旧的元数据（INode信息）被保存到快照的Diff列表中
- 这就是 **COW（Copy-On-Write）** ——只在写入发生时才"复制"（保存旧版本）

### 生产故障场景

```
场景：误删了 /data/warehouse/ 下的关键分区目录
现象：Hive表查询报错 "Input path does not exist"
恢复：
  hdfs dfs -ls /data/warehouse/.snapshot/daily_backup/  # 查看快照
  hdfs dfs -cp /data/warehouse/.snapshot/daily_backup/partition_key \
               /data/warehouse/partition_key             # 从快照恢复
  
关键：如果没有快照，数据彻底丢失！HDFS的rm是真删除，没有回收站之外的恢复手段。
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| Snapshot | 目录在某一时间点的只读副本 | Word的"保存版本" |
| Snapshottable Directory | 允许创建快照的目录 | 启用了版本历史的文档 |
| COW (Copy-On-Write) | 修改时才保存旧版本 | 只在改动时才记录变化 |
| SnapshotManager | 管理所有快照的组件 | 版本管理器 |
| DirectorySnapshottableFeature | INode的快照能力特性 | 文档的"版本历史"功能 |
| DirectoryWithSnapshotFeature | 目录的快照数据 | 存储版本差异的容器 |
| SnapshotDiff | 两个快照之间的差异 | 两个版本的对比结果 |
| Snapshot ID | 全局唯一的快照标识(24位) | 版本号 |
| .snapshot | 访问快照的虚拟目录 | 版本历史的入口 |

### 2.2 架构图

```
┌──────────────────────────────────────────────────────────────┐
│                      NameNode                                 │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │                SnapshotManager                        │    │
│  │                                                       │    │
│  │  snapshottables: Map<Long, INodeDirectory>            │    │
│  │  snapshotCounter: int (全局递增)                       │    │
│  │  numSnapshots: AtomicInteger                          │    │
│  │                                                       │    │
│  │  方法:                                                │    │
│  │  - setSnapshottable()    启用目录快照能力              │    │
│  │  - createSnapshot()      创建快照                     │    │
│  │  - deleteSnapshot()      删除快照                     │    │
│  │  - diff()               计算快照差异                  │    │
│  └──────────────────────────────────────────────────────┘    │
│                          │                                    │
│  ┌──────────────────────────────────────────────────────┐    │
│  │            INodeDirectory (/data/warehouse)           │    │
│  │                                                       │    │
│  │  ┌──────────────────────────────────────────────────┐│    │
│  │  │  DirectorySnapshottableFeature                    ││    │
│  │  │  - snapshotQuota: 65536 (最大快照数)              ││    │
│  │  │  - snapshotList: [snap1, snap2, ...]             ││    │
│  │  └──────────────────────────────────────────────────┘│    │
│  │                                                       │    │
│  │  ┌──────────────────────────────────────────────────┐│    │
│  │  │  DirectoryWithSnapshotFeature                     ││    │
│  │  │  - diffs: DiffList                                ││    │
│  │  │    [SnapshotDiff(id=1): {created=[], deleted=[]}] ││    │
│  │  │    [SnapshotDiff(id=2): {created=[], deleted=[]}] ││    │
│  │  └──────────────────────────────────────────────────┘│    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### 2.3 COW 工作原理

```
时间线:
  
T0: 创建快照 snap1
    /data/warehouse/
    ├── fileA (100MB, Block1-Block10)
    ├── fileB (50MB, Block11-Block15)
    └── dirX/
        └── fileC
    
    此时：不复制任何东西！只记录"snap1"标记
    
T1: 删除 fileA
    /data/warehouse/
    ├── fileB (50MB)           ← 当前状态
    └── dirX/
        └── fileC
    
    COW: fileA 的 INode信息被保存到 snap1 的 Diff 中
         fileA 的数据Block不会被删除（因为快照还在引用）
    
T2: 修改 fileB (追加数据)
    /data/warehouse/
    ├── fileB (80MB)           ← 当前状态（新Block）
    └── dirX/
        └── fileC
    
    COW: fileB 修改前的INode信息被保存到 snap1 的 Diff 中

访问快照:
    /data/warehouse/.snapshot/snap1/
    ├── fileA (100MB)          ← 从Diff中恢复
    ├── fileB (50MB)           ← 从Diff中恢复
    └── dirX/
        └── fileC
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 类名 | 文件路径 | 职责 |
|------|---------|------|
| `SnapshotManager` | `snapshot/SnapshotManager.java` | 全局快照管理 |
| `DirectorySnapshottableFeature` | `snapshot/DirectorySnapshottableFeature.java` | 目录的快照能力 |
| `DirectoryWithSnapshotFeature` | `snapshot/DirectoryWithSnapshotFeature.java` | 目录的快照数据(Diff列表) |
| `Snapshot` | `snapshot/Snapshot.java` | 快照实体 |
| `FileDiff` / `FileDiffList` | `snapshot/FileDiff.java` | 文件的Diff记录 |
| `SnapshotDiffInfo` | `snapshot/SnapshotDiffInfo.java` | 快照差异计算 |
| `AbstractINodeDiff` | `snapshot/AbstractINodeDiff.java` | Diff记录基类 |

### 3.2 关键方法逐行解读

#### 3.2.1 SnapshotManager 核心数据结构

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java
// 行号: 62-77

public class SnapshotManager implements SnapshotStatsMXBean {
  private final FSDirectory fsdir;
  private static final int SNAPSHOT_ID_BIT_WIDTH = 24;  // 24位ID，最大16M个快照

  private final AtomicInteger numSnapshots = new AtomicInteger();
  private int snapshotCounter = 0;  // 全局递增的快照ID
  
  /** 所有可快照目录: INodeID → INodeDirectory */
  private final Map<Long, INodeDirectory> snapshottables =
      new HashMap<Long, INodeDirectory>();
}
```

**教学要点**：
- `snapshottables` 存储所有启用了快照功能的目录
- `snapshotCounter` 是全局递增的，即使删除快照也不会回退
- 24位宽度限制了最大快照数为 2^24 - 1 ≈ 1600万

#### 3.2.2 setSnapshottable()：启用目录快照

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java
// 行号: 110-125

public void setSnapshottable(final String path, 
    boolean checkNestedSnapshottable) throws IOException {
  final INodesInPath iip = fsdir.getINodesInPath(path, DirOp.WRITE);
  final INodeDirectory d = INodeDirectory.valueOf(iip.getLastINode(), path);
  
  // 检查嵌套快照（默认不允许嵌套）
  if (checkNestedSnapshottable) {
    checkNestedSnapshottable(d, path);
  }

  if (d.isSnapshottable()) {
    // 已经是可快照目录，只更新配额
    d.setSnapshotQuota(DirectorySnapshottableFeature.SNAPSHOT_LIMIT);
  } else {
    // 添加快照能力（Feature模式）
    d.addSnapshottableFeature();
  }
  addSnapshottable(d);  // 加入snapshottables Map
}
```

**教学要点**：
- HDFS使用**Feature模式**（类似装饰器模式）为INode添加能力
- `addSnapshottableFeature()` 给 INodeDirectory 装上了"快照"装备
- 不允许嵌套快照：如果 /a 可快照，则 /a/b 不能再设为可快照

#### 3.2.3 createSnapshot()：创建快照

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java
// 行号: 206-225

public String createSnapshot(final INodesInPath iip, String snapshotRoot,
    String snapshotName) throws IOException {
  INodeDirectory srcRoot = getSnapshottableRoot(iip);

  // 检查快照ID是否溢出
  if (snapshotCounter == getMaxSnapshotID()) {
    throw new SnapshotException(
        "Failed to create the snapshot. The FileSystem has run out of " +
        "snapshot IDs and ID rollover is not supported.");
  }

  // 核心：在目录上添加快照（只记录ID和名称，不复制数据！）
  srcRoot.addSnapshot(snapshotCounter, snapshotName);
    
  snapshotCounter++;              // 全局ID递增
  numSnapshots.getAndIncrement(); // 快照计数+1
  return Snapshot.getSnapshotPath(snapshotRoot, snapshotName);
}
```

**教学要点**：
- 创建快照是**O(1)操作**！不需要遍历目录树，不需要复制数据
- 只做了两件事：① `addSnapshot()` 记录快照 ② 递增计数器
- 这就是COW的精髓——创建时什么都不做，修改时才保存旧版本

#### 3.2.4 deleteSnapshot()：删除快照

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java
// 行号: 233-238

public void deleteSnapshot(final INodesInPath iip, final String snapshotName,
    INode.ReclaimContext reclaimContext) throws IOException {
  INodeDirectory srcRoot = getSnapshottableRoot(iip);
  srcRoot.removeSnapshot(reclaimContext, snapshotName);
  numSnapshots.getAndDecrement();
}
```

**教学要点**：
- 删除快照时，通过 `ReclaimContext` 收集可以回收的Block和INode
- 如果某个Block只被这个快照引用（没有其他快照引用），则可以被删除
- 如果Block被多个快照引用，则不能删除

#### 3.2.5 diff()：计算快照差异

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java
// 行号: 357-374

public SnapshotDiffReport diff(final INodesInPath iip,
    final String snapshotRootPath, final String from,
    final String to) throws IOException {
  final INodeDirectory snapshotRoot = getSnapshottableRoot(iip);

  if ((from == null || from.isEmpty())
      && (to == null || to.isEmpty())) {
    // 两个都是当前状态，无差异
    return new SnapshotDiffReport(snapshotRootPath, from, to,
        Collections.<DiffReportEntry> emptyList());
  }
  
  // 计算差异
  final SnapshotDiffInfo diffs = snapshotRoot
      .getDirectorySnapshottableFeature()
      .computeDiff(snapshotRoot, from, to);
  
  return diffs != null ? diffs.generateReport() : ...;
}
```

#### 3.2.6 嵌套快照检查

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java
// 行号: 84-104

private void checkNestedSnapshottable(INodeDirectory dir, String path)
    throws SnapshotException {
  if (allowNestedSnapshots) return;

  for(INodeDirectory s : snapshottables.values()) {
    // 检查: dir不能是已有可快照目录的祖先
    if (s.isAncestorDirectory(dir)) {
      throw new SnapshotException(
          "Nested snapshottable directories not allowed: " + path
          + ", the subdirectory " + s.getFullPathName()
          + " is already a snapshottable directory.");
    }
    // 检查: dir不能是已有可快照目录的后代
    if (dir.isAncestorDirectory(s)) {
      throw new SnapshotException(
          "Nested snapshottable directories not allowed: " + path
          + ", the ancestor " + s.getFullPathName()
          + " is already a snapshottable directory.");
    }
  }
}
```

### 3.3 调用链时序图

#### 3.3.1 创建快照

```
Client                     NameNode (FSNamesystem)        SnapshotManager
  │                              │                              │
  │──createSnapshot("/data",     │                              │
  │    "snap1")────────────────→ │                              │
  │                              │──createSnapshot(iip,         │
  │                              │    "/data","snap1")─────────→│
  │                              │                              │
  │                              │                              │──getSnapshottableRoot()
  │                              │                              │  检查目录是否可快照
  │                              │                              │
  │                              │                              │──srcRoot.addSnapshot(
  │                              │                              │    counter, "snap1")
  │                              │                              │  记录快照（O(1)!）
  │                              │                              │
  │                              │                              │──snapshotCounter++
  │                              │                              │──numSnapshots++
  │                              │                              │
  │                              │←─"/data/.snapshot/snap1"─────│
  │←─────成功────────────────────│                              │
```

#### 3.3.2 COW触发（删除文件）

```
Client                     FSNamesystem          INodeDirectory(/data)
  │                              │                       │
  │──delete("/data/fileA")─────→ │                       │
  │                              │                       │
  │                              │  检查fileA所在目录     │
  │                              │  是否有快照              │
  │                              │  YES → 触发COW         │
  │                              │                       │
  │                              │──recordModification()─→│
  │                              │                       │
  │                              │  将fileA的旧INode信息  │
  │                              │  保存到snap1的Diff中   │
  │                              │                       │
  │                              │  从当前目录树删除fileA │
  │                              │  但fileA的Block不删除  │
  │                              │  (因为快照还在引用)    │
  │←─────成功────────────────────│                       │
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：误删关键目录

```bash
# 恢复步骤
# 1. 查看可用快照
hdfs dfs -ls /data/warehouse/.snapshot/

# 2. 查看快照中的文件
hdfs dfs -ls /data/warehouse/.snapshot/daily_backup_20260428/

# 3. 从快照恢复
hdfs dfs -cp -r /data/warehouse/.snapshot/daily_backup_20260428/lost_dir \
               /data/warehouse/lost_dir
```

#### 场景2：数据对比审计

```bash
# 对比两个快照之间的差异
hdfs snapshotDiff /data/warehouse snap1 snap2

# 输出示例:
# M  ./table_a/partition_key=20260428
# +  ./table_b/new_partition
# -  ./table_c/deleted_file
```

#### 场景3：快照过多导致NN内存压力

```
原因: 每个快照都在NN内存中维护Diff数据
      大量快照 × 大量文件变更 = 巨大的内存开销
解法: 定期清理过期快照，设置合理的snapshotQuota
```

### 4.2 常用命令

```bash
# 启用目录快照
hdfs dfsadmin -allowSnapshot /data/warehouse

# 创建快照
hdfs dfs -createSnapshot /data/warehouse daily_20260428

# 查看快照
hdfs dfs -ls /data/warehouse/.snapshot/
hdfs lsSnapshottableDir

# 快照Diff
hdfs snapshotDiff /data/warehouse snap1 snap2

# 删除快照
hdfs dfs -deleteSnapshot /data/warehouse daily_20260420

# 从快照恢复
hdfs dfs -cp /data/warehouse/.snapshot/snap1/lost_file /data/warehouse/

# 禁用目录快照（必须先删除所有快照）
hdfs dfsadmin -disallowSnapshot /data/warehouse
```

### 4.3 关键参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.namenode.snapshot.capture.openFiles` | false | 快照是否捕获打开的文件 |
| `dfs.namenode.snapshot.skipCaptureAccessTimeOnlyChange` | false | 是否跳过仅atime变更 |
| 快照Quota | 65536 | 每目录最大快照数 |
| 全局快照ID上限 | 2^24-1 ≈ 16M | 不可配置 |

---

## 五、举一反三

### 5.1 类比迁移

| 概念 | HDFS Snapshot | ZFS Snapshot | Git | LVM Snapshot |
|------|--------------|-------------|-----|-------------|
| 实现方式 | COW (元数据级) | COW (块级) | DAG (全量快照) | COW (块设备级) |
| 快照粒度 | 目录级 | 文件系统级 | 仓库级 | 卷级 |
| 创建开销 | O(1) | O(1) | O(n) | O(1) |
| Diff计算 | 内置 | zfs diff | git diff | N/A |
| 数据块复制 | 不复制 | 不复制 | 完整快照 | 不复制 |

### 5.2 面试高频题

**Q1: HDFS快照是如何实现的？创建快照需要复制数据吗？**
> 不需要！HDFS快照使用**COW（Copy-On-Write）**机制，创建快照时只在NameNode内存中记录一个快照标记（O(1)操作），不复制任何数据Block。只有当快照创建后文件被修改/删除时，旧的INode元数据才被保存到快照的Diff列表中。

**Q2: 快照是目录级还是文件级？**
> HDFS快照是**目录级**的。只能对整个目录创建快照，不能对单个文件。目录必须先通过 `allowSnapshot` 启用快照能力。不允许嵌套快照。

**Q3: 删除一个被快照引用的文件，数据Block会被删除吗？**
> 不会。NameNode在删除文件时会检查该文件是否被任何快照引用。如果被引用，文件的INode信息保存到快照Diff中，数据Block保留。只有当所有引用该Block的快照都被删除后，Block才能被回收。

**Q4: 访问 /path/.snapshot/snap1/ 时发生了什么？**
> `.snapshot` 是一个虚拟目录，不真实存在于文件系统中。NameNode拦截对 `.snapshot` 路径的请求，通过当前目录状态和Diff列表，反向计算出快照时间点的目录状态并返回。

**Q5: HDFS快照和FsImage的关系？**
> 快照的Diff数据是FsImage的一部分，会被持久化到FsImage文件中。NameNode重启后，从FsImage中恢复快照信息。

### 5.3 思考题

1. 如果一个目录下有100万个文件，创建快照后修改了其中1个文件，快照的内存开销是多少？
2. 为什么HDFS不支持嵌套快照？如果支持会有什么问题？
3. HDFS快照的COW和ZFS快照的COW有什么区别？

---

## 六、知识晶体

```
┌──────────────────────────────────────────────────────────────────┐
│ 核心源码: SnapshotManager.createSnapshot() → O(1)创建           │
│          DirectoryWithSnapshotFeature → COW Diff列表            │
│          SnapshotManager.diff() → 计算快照差异                   │
│ 设计意图: COW=创建不复制,修改才保存 | Feature模式=可插拔能力     │
│ 关键: 创建O(1) | 不复制Block | .snapshot虚拟目录 | 禁止嵌套    │
│ 踩坑: 快照过多→NN内存压力 | 忘记allowSnapshot | 删除前须清快照 │
└──────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/SnapshotManager.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/DirectorySnapshottableFeature.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/DirectoryWithSnapshotFeature.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/snapshot/Snapshot.java`

2. **官方文档**
   - [HDFS Snapshots](https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-hdfs/HdfsSnapshots.html)

3. **相关JIRA**
   - HDFS-2802: HDFS Snapshot 初始实现
   - HDFS-5427: 快照Diff优化
