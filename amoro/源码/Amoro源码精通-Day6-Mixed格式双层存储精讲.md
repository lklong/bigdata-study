# Amoro 源码精通 · Day6 · 《Mixed 格式深挖 —— ChangeStore + BaseStore 双层存储精讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 06 讲  
> 承接：Day5《Task 执行与 Commit 全链路精讲》

---

## 🎯 本讲学完你能干什么

- ✅ **默画 Mixed 格式的类层次图**（MixedTable → KeyedTable → BaseTable + ChangeTable）
- ✅ **讲清楚** "为什么一张 Mixed 表要拆成两张 Iceberg 子表？"
- ✅ **回答** "Mixed 表的 MINOR/MAJOR/FULL 跟原生 Iceberg 有什么区别？"
- ✅ **理解 `TreeNodeTaskSplitter`** —— Amoro 独创的按"完全二叉树"拆分任务的算法
- ✅ **看透 Flink connector 的写入链路**是怎么把 CDC 记录路由到 ChangeTable 的

---

## 🧠 一句话心智模型

> **Mixed 格式 = "双层笔记本"：ChangeTable 是草稿本（频繁写、不排序），BaseTable 是正式本（合并后、排好序的基准数据）。自优化 = 物业定期把草稿本内容抄到正式本上，抄完撕掉草稿。**

---

## 🏛️ 生活类比：草稿本 + 正式本

```
  Flink CDC 流式写入
     │
     ▼ (频繁小提交)
  📝 草稿本（ChangeTable）
     ├─ INSERT_FILE (新增记录)
     ├─ EQ_DELETE_FILE (按主键删除)
     └─ CHANGE_FILE (变更记录)
     
  AMS 自优化定期执行（MINOR compaction）
     │
     ▼ (把草稿抄到正式本)
  📘 正式本（BaseTable）
     ├─ BASE_FILE (合并后的大文件)
     └─ Position Delete (精确删除)
     
  Spark/Trino 查询
     │
     ▼ (MOR: 正式本 + 草稿本合并读)
  读取时把两本合起来看 = 实时数据
```

**一句话总结**：**写走草稿本（快但乱），读走两本合并（准但慢），优化就是把草稿抄正式本（平衡读写）**。

---

## 🔍 源码逐层剥离

### L1 · 类层次图（必背）

```
MixedTable (interface, Serializable)           ← 顶层表抽象
├── KeyedTable (interface)                     ← 有主键的 Mixed 表
│   ├── primaryKeySpec()                       ← 主键定义
│   ├── baseTable() → BaseTable                ★ 正式本
│   ├── changeTable() → ChangeTable            ★ 草稿本
│   ├── beginTransaction(signature) → txnId
│   └── 实现类: BasicKeyedTable
│        └── 构造器持有 BaseTable + ChangeTable 两个 UnkeyedTable
│
└── UnkeyedTable (interface, extends Iceberg Table) ← 无主键的 Mixed 表
    ├── partitionProperty()
    ├── 实现类: BasicUnkeyedTable
    │    └── 包装一张标准 Iceberg 表
    │
    ├── BaseTable (interface extends UnkeyedTable)  ← 标记接口，无新增方法
    │
    └── ChangeTable (interface extends UnkeyedTable)
         └── newScan() → ChangeTableIncrementalScan  ← 支持增量读
```

**🔑 教学关键点**：

1. **`KeyedTable` 不是一张表，是一对表**：`baseTable()` + `changeTable()` 各返回一个 `UnkeyedTable`。
2. **`BaseTable` 是纯标记接口**（0 个方法），只用于类型区分。
3. **`ChangeTable` 只比 `UnkeyedTable` 多了一个 `newScan()` 返回增量扫描器**——这是 CDC 消费的入口。
4. **`BasicKeyedTable` 的构造器**：`new BasicKeyedTable(location, keySpec, baseTable, changeTable)` —— 物理上就是两张子表拼成一张逻辑表。

**为什么这么设计？**

| 如果不拆 | 拆了以后 |
|---|---|
| 流式写入会产生大量碎片小文件，读取性能差 | Change 小文件只在 ChangeTable 里，BaseTable 保持大文件 |
| 无法支持 CDC 增量读 | ChangeTable 天然支持 `ChangeTableIncrementalScan` |
| Compaction 需要全量重写 | MINOR 只需把 Change 合入 Base，不动 Base 的大文件 |

**对比原生 Iceberg**：原生 Iceberg 的 MOR（merge-on-read）用 equality delete + position delete 实现，**不拆表**。Amoro 的 Mixed 格式**拆成两张表**是为了在流式场景下获得更好的写吞吐和增量读能力，代价是读时需要 MOR 合并两表。

---

### L2 · Mixed 表的 Minor/Major/Full 语义差异

Day4 讲了原生 Iceberg 的三种优化判定。Mixed 表（特别是 KeyedTable）在 `MixedIcebergPartitionEvaluator` 里**重写了判定逻辑**（L128-286）：

#### Mixed Minor（草稿→正式）

```java
@Override
public boolean isMinorNecessary() {
  if (keyedTable) {
    int smallFileCount = fragmentFileCount + equalityDeleteFileCount;
    int baseSplitCount = getBaseSplitCount();  // = hashBucket 数
    // 条件 A: 小文件数 >= max(baseSplitCount+1, minorLeastFileCount)
    if (smallFileCount >= Math.max(baseSplitCount + 1, config.getMinorLeastFileCount())) {
      return true;
    }
    // 条件 B: (小文件 > baseSplitCount 或有 change 文件) + 到达 minor 间隔
    else if ((smallFileCount > baseSplitCount || hasChangeFiles) && reachMinorInterval()) {
      return true;
    }
    // 条件 C: 有 change 文件 + 到达 base refresh 间隔
    else {
      return hasChangeFiles && reachBaseRefreshInterval();
    }
  } else {
    return super.isMinorNecessary();  // 非 Keyed 走父类逻辑
  }
}
```

**翻译**：Mixed Minor 的核心目的是**把 ChangeTable 里的碎片合并到 BaseTable 里**。触发条件比原生 Iceberg 更复杂，因为多了一个维度——`hasChangeFiles`（有没有 change 文件）和 `baseSplitCount`（hash 分桶数）。

#### Mixed Full（全分区大手术）

```java
@Override
public boolean isFullNecessary() {
  if (!reachFullInterval()) return false;
  return anyDeleteExist() 
      || fragmentFileCount > getBaseSplitCount()  // ★ 碎片数 > 桶数
      || hasChangeFiles;                           // ★ Mixed 特有条件
}
```

**精妙之处**：Mixed Full 比原生多了 `hasChangeFiles` 这个判断——即使文件数量看起来还行，只要有 change 文件存在，到了 fullInterval 就必须全清。因为**change 文件越积越多会严重影响读性能**。

#### `isFragmentFile` 的 Mixed 特殊逻辑

```java
@Override
protected boolean isFragmentFile(DataFile dataFile) {
  PrimaryKeyedFile file = (PrimaryKeyedFile) dataFile;
  if (file.type() == DataFileType.BASE_FILE) {
    return dataFile.fileSizeInBytes() <= fragmentSize;  // Base 看大小
  } else if (file.type() == DataFileType.INSERT_FILE 
          || file.type() == DataFileType.CHANGE_FILE) {
    return true;  // ★ Insert/Change 文件一律视为碎片
  }
}
```

**关键教学点**：在 Mixed 格式里，**所有 Insert 和 Change 文件都被当作碎片**，无论大小。因为它们在 ChangeTable 里天然就是小提交产物，必须被合并。

---

### L2 · `TreeNodeTaskSplitter`：Amoro 独创的二叉树拆分算法

这是 Mixed 格式最精妙的设计之一——用**完全二叉树**管理 hash 分桶下的文件分布。

**背景**：KeyedTable 的每个文件都有一个 `DataTreeNode`（树节点 ID），它标记这个文件属于哪个 hash 分桶。分桶是一棵二叉树：

```
          root(0,0)
         /          \
      left(1,0)    right(1,1)
      /    \        /    \
   (2,0) (2,1)  (2,2)  (2,3)
```

`TreeNodeTaskSplitter` 的算法：
1. 把所有要处理的文件挂到二叉树上
2. 先 `completeTree()` —— 把二叉树补完整（避免祖先节点的文件在分裂时丢失）
3. 递归 `splitFileTree()`：如果一个节点**没有直接文件**，就继续分裂给左右子树；如果**有直接文件**，就作为一个 `SplitTask`

**类比**：就像把一张大桌子上散落的棋子按区域分组——先用十字线切一刀（根→左右），再切第二刀（左→左左+左右），直到每个小区域里的棋子足够少能一手拿完。

**为什么不用简单的 BinPacking？** 因为 KeyedTable 的主键 hash 决定了文件必须在同一个 tree node 内合并，**跨 node 合并会破坏主键去重语义**。`TreeNodeTaskSplitter` 保证了**同一 task 内的文件一定属于同一棵子树**。

Unkeyed 表则用 `BinPackingTaskSplitter`（按大小装箱，简单粗暴）。

---

### L2 · Flink 写入链路：CDC → ChangeTable

**入口**：`FlinkSink.java` / `FlinkChangeTaskWriter.java`

```
Flink CDC Source (Debezium/Canal)
     │
     ▼
FlinkSink.build(table)
     │ 判断 KeyedTable → 路由到 ChangeTaskWriter
     ▼
FlinkChangeTaskWriter
     │ 按 RowKind 分类：
     │   INSERT → INSERT_FILE
     │   DELETE → EQ_DELETE_FILE
     │   UPDATE_BEFORE + UPDATE_AFTER → CHANGE_FILE
     ▼
ChangeTable.commit()  ← 写入 ChangeTable 的 snapshot
```

**关键类**：
- `FlinkSink.java` (L16.88KB) —— Flink Sink 建构器
- `FlinkChangeTaskWriter.java` (L4.24KB) —— 写 ChangeTable 的 Writer
- `FlinkBaseTaskWriter.java` (L2.4KB) —— 写 BaseTable 的 Writer（批量场景）

**这就是 Day2 讲的"表状态变化"的上游来源**：Flink 写了 ChangeTable，AMS 的 `TableRuntimeRefreshExecutor` 发现 snapshot 变了，触发 `fireStatusChanged`，走进 Day3-Day4 的自优化链路。

---

## 💡 精妙设计拆解

### 精妙一：KeyedTable "持有"而非"继承"两个子表

```java
public class BasicKeyedTable implements KeyedTable {
  protected final BaseTable baseTable;      // 正式本
  protected final ChangeTable changeTable;  // 草稿本
}
```

**这是组合（Composition）而非继承**。好处：
1. BaseTable 和 ChangeTable 可以**独立演化**（比如 Change 加增量扫描 API）
2. 物理存储路径独立：`{location}/base` 和 `{location}/change`
3. 可以对 BaseTable 和 ChangeTable **分别做 schema 同步**（`KeyedSchemaUpdate.syncSchema`）

### 精妙二：`Weight` 里的 `reachDelay` 优先于 `cost`

```java
protected static class Weight implements PartitionEvaluator.Weight {
  private final long cost;
  private final boolean reachDelay;
  
  @Override
  public int compareTo(Weight o) {
    int compare = Boolean.compare(this.reachDelay, that.reachDelay);  // ★ 先比延迟
    if (compare != 0) return compare;
    return Long.compare(this.cost, that.cost);                         // 再比代价
  }
}
```

**含义**：如果一个分区已经达到 `baseRefreshInterval`（太久没刷 Base），它的**优先级永远高于**还没达到间隔的分区——**即使后者 cost 更大**。这是"**SLA 优先于效率**"的调度哲学。

### 精妙三：`completeTree()` 防止祖先节点数据丢失

```java
public void completeTree() {
  completeTree(false);
}
private void completeTree(boolean ancestorFileExist) {
  boolean thisNodeMustBalance = ancestorFileExist || fileExist();
  if (thisNodeMustBalance) {
    if (left == null) left = new FileTree(node.left());
    if (right == null) right = new FileTree(node.right());
  }
  // 递归...
}
```

**教学点**：如果祖先节点有文件，但只有左子树没有右子树，split 的时候会漏掉祖先的文件。`completeTree` 确保**任何有文件的祖先都补全左右子节点**，把"不完全二叉树"变成"完全二叉树"。

---

## 🎓 举一反三

| Amoro Mixed 机制 | 同构系统 | 关键词 |
|---|---|---|
| ChangeTable + BaseTable 双层 | HBase MemStore + HFile / LSM-Tree L0 + L1+ | **WAL + Compacted Store** |
| Minor = Change → Base | HBase Minor Compaction / RocksDB L0→L1 | **层间合并** |
| Major = Base 内部重写 | HBase Major Compaction / RocksDB L1+ 合并 | **层内重组** |
| Full = 全量重写 | HBase forced Major / Iceberg rewrite_data_files | **全量清理** |
| TreeNodeTaskSplitter | HBase Region split by rowkey range | **按 key 范围拆任务** |
| `PrimaryKeyedFile.node()` | HBase `KeyValue` 的 rowkey hash | **hash 分桶定位** |
| MOR 读取（Base + Change 合并） | HBase MOR / Delta Lake MOR | **读时合并** |

---

## 📝 课后习题

### ⭐ 题目 1：30 秒默画类层次

不看任何资料，画出 `MixedTable → KeyedTable → BaseTable + ChangeTable` 的继承关系。

### ⭐⭐ 题目 2：生产问题推理

"我用 Flink CDC 往 Mixed-Iceberg 表写了 2 小时，Dashboard 显示表健康分从 90 降到 30。为什么？怎么恢复？"

### ⭐⭐⭐ 题目 3：对比题

写 200 字对比：Amoro Mixed 的 ChangeTable + BaseTable 双层设计 vs HBase 的 MemStore + HFile + Compaction。异同各列 3 条。

### ⭐⭐⭐⭐ 题目 4：TreeNodeTaskSplitter 验证

手画一棵 3 层二叉树，在 (2,0) 和 (1,1) 各放 2 个文件。按 `completeTree()` + `splitFileTree()` 算法，最终生成几个 SplitTask？

### ⭐⭐⭐⭐⭐ 题目 5：设计题

如果要给 Mixed 表加一个"**只清理 ChangeTable 不动 BaseTable**"的新优化类型（比如叫 `CHANGE_ONLY`），你需要改哪些类？画出改动点清单。

---

## 🧪 知识晶体

### 核心源码锚点
- `MixedTable.java` — 顶层接口（106 行）
- `KeyedTable.java` — 有主键表（78 行），`baseTable()` + `changeTable()`
- `ChangeTable.java` — 草稿本（31 行），`newScan()` 增量扫描
- `BaseTable.java` — 正式本（22 行），纯标记接口
- `BasicKeyedTable.java` — 实现类，持有 base + change
- `MixedIcebergPartitionEvaluator` — Mixed 专用决策（`isMinorNecessary` 重写）
- `MixedIcebergPartitionPlan` — Mixed 专用计划（`TreeNodeTaskSplitter`）
- `FlinkChangeTaskWriter.java` — Flink 写 ChangeTable 入口
- `FlinkSink.java` — Flink Sink 建构器

### 段位变化

| 维度 | Day5 末 | **Day6 末** |
|---|---|---|
| Amoro 源码段位 | L2 毕业 | **L2+**（Mixed 格式核心打通）|
| 能画的图 | 端到端闭环 | + **Mixed 类层次 + 双层存储 + TreeNode 算法** |
| Phase 1 完成度 | 5/15 | **6/15** |

### 下次开工（Day7）

**Day7 主题**：《Hive 兼容的秘密 —— Mixed-Hive 格式 + HiveCommitSync 精讲》

---

> **信条**：Mixed 格式就像"双账本"——写在草稿本上快，但必须定期抄到正式本上。这个"定期抄"就是 Amoro 的全部价值。

— eric · Amoro 源码精通 · 第 06 讲
