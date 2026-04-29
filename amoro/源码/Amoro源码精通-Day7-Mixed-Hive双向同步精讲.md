# Amoro 源码精通 · Day7 · 《Hive 兼容的秘密 —— Mixed-Hive + 双向同步精讲》

> 作者：eric  
> 日期：2026-04-28  
> 课程编号：源码精通 · Amoro 篇 · 第 07 讲  
> 承接：Day6《Mixed 格式双层存储精讲》

---

## 🎯 本讲学完你能干什么

- ✅ **讲清楚** "Mixed-Hive 表和 Mixed-Iceberg 表的本质区别是什么？"——答案不是"多了个 Hive"
- ✅ **默画 Hive↔Iceberg 双向同步架构图**——弄清"谁同步谁、什么时候、看什么字段"
- ✅ **回答** "为什么我用 Hive INSERT 写了数据，Amoro Dashboard 上看不到？"
- ✅ **回答** "为什么 Amoro 优化完了，Hive 查到的还是旧数据？"
- ✅ **看透 `UpdateHiveFiles.commit()` 的 9 步流程**——这是 Mixed-Hive 最容易出 bug 的地方

---

## 🧠 一句话心智模型

> **Mixed-Hive = Mixed-Iceberg + 一面"魔镜"：BaseTable 是 Iceberg 的，但 Hive 侧也有一份元数据的"倒影"。Amoro 的全部额外工作就是维护这面魔镜——让 Iceberg 和 Hive 两边看到的数据永远一致。**

---

## 🏛️ 生活类比：镜像档案室

```
┌──────────────────┐            ┌──────────────────┐
│   Iceberg 侧      │            │   Hive (HMS) 侧    │
│   (真相源)          │   魔镜     │   (镜像)           │
│                    │  ←─────→  │                    │
│ Snapshot #42       │           │ Partition list     │
│ manifest/data      │           │   location/stats   │
│ partitionProperty  │ ←─桥梁→   │ transient_lastDdl  │
│   hive-location    │           │                    │
│   transient-time   │           │                    │
└──────────────────┘            └──────────────────┘

桥梁字段（存在 Iceberg partitionProperty 里）：
  - PARTITION_PROPERTIES_KEY_HIVE_LOCATION  → Hive 分区路径
  - PARTITION_PROPERTIES_KEY_TRANSIENT_TIME → 最后同步时间戳

同步方向 1: Iceberg → Hive（AMS 每 10min 跑一次 HiveCommitSyncExecutor）
同步方向 2: Hive → Iceberg（表加载/刷新时 syncHiveDataToMixedTable）
```

---

## 🔍 源码逐层剥离

### L1 · Mixed-Hive vs Mixed-Iceberg 的类层次差异

```
Mixed-Iceberg:
  KeyedTable → BasicKeyedTable(BaseTable=BasicUnkeyedTable, ChangeTable=BasicUnkeyedTable)
                              ↑ 两个子表都是纯 Iceberg

Mixed-Hive:
  KeyedTable → KeyedHiveTable(BaseTable=UnkeyedHiveTable, ChangeTable=BasicUnkeyedTable)
                              ↑ BaseTable 用 Hive 存储！ChangeTable 仍是纯 Iceberg
```

**关键差异**：Mixed-Hive 的 **BaseTable 是 `UnkeyedHiveTable`（实现了 `SupportHive` 接口）**，而 ChangeTable 仍然是普通 Iceberg 表。

**`SupportHive` 接口**（52 行，4 个核心方法）：

```java
public interface SupportHive extends MixedTable {
  String hiveLocation();                          // Hive 数据根路径
  HMSClientPool getHMSClient();                   // HMS 客户端
  boolean enableSyncHiveDataToMixedTable();       // 是否同步 Hive→Iceberg
  void syncHiveDataToMixedTable(boolean force);   // 执行同步
}
```

**`UnkeyedHiveTable` 的精妙之处**（L48）：

```java
public class UnkeyedHiveTable extends BasicUnkeyedTable implements BaseTable, SupportHive {
```

**同时实现 `BaseTable` + `SupportHive`**——这让 KeyedHiveTable 拿到的 baseTable 既是 Iceberg 表又有 Hive 能力。

**构造函数里即同步**（L79-84）：

```java
if (enableSyncHiveSchemaToMixedTable()) syncHiveSchemaToMixedTable();
if (enableSyncHiveDataToMixedTable())   syncHiveDataToMixedTable(false);
```

**一加载就同步**——这保证每次有人 `loadTable()` 都能看到 Hive 侧最新状态。

---

### L2 · 双向同步核心引擎 `HiveMetaSynchronizer`（657 行）

这是 Day7 的**灵魂文件**——Hive↔Iceberg 双向同步的完整实现。

#### 方向 1: Hive → Iceberg（`syncHiveDataToMixedTable`，L185-272）

**触发时机**：表加载（`UnkeyedHiveTable` 构造函数）/ 表刷新（`refresh()`）

**算法**（分区表场景）：

```
1. 列出 Hive 所有分区 → hivePartitions
2. 列出 Iceberg BaseTable 所有文件 → filesGroupedByPartition
3. for each hivePartition:
     对比 transient_lastDdlTime 是否变了
     ├─ 没变 → 跳过
     └─ 变了 → 列出 Hive 分区文件 → overwrite 到 Iceberg
4. for each iceberg 独有分区（Hive 里没有）:
     检查文件是否还存在
     └─ 不存在 → 从 Iceberg 删除
```

**核心判据 `partitionHasModified()`**（L530-562）：

```java
static boolean partitionHasModified(UnkeyedTable baseStore, Partition hivePartition, StructLike partitionData) {
  String hiveTransientTime = hivePartition.getParameters().get("transient_lastDdlTime");
  String mixedTransientTime = baseStore.partitionProperty()
      .get(partitionData)
      .get(PARTITION_PROPERTIES_KEY_TRANSIENT_TIME);
  
  // 如果 Hive location 已被 Amoro 改过（Full Optimizing），不触发反向同步
  if (mixedPartitionLocation != null && !mixedPartitionLocation.equals(hiveLocation)) {
    return false;
  }
  
  // 比较时间戳
  return mixedTransientTime == null || !mixedTransientTime.equals(hiveTransientTime);
}
```

**🔑 教学关键点**：`transient_lastDdlTime` 是 Hive 自动维护的时间戳——每次有人往 Hive 分区写数据，这个值就变。Amoro 对比这个值来判断"Hive 侧有没有新数据"。

#### 方向 2: Iceberg → Hive（`syncMixedTableDataToHive`，L279-297）

**触发时机**：AMS 的 `HiveCommitSyncExecutor` 每 **10 分钟**执行一次

**算法**（分区表场景）：

```
1. 读 Iceberg partitionProperty → icebergPartitions（含 hive-location + transient-time）
2. 列出 HMS 所有分区 → hivePartitions
3. 计算三个集合：
   - inIcebergNotInHive → 创建 Hive 分区（createPartitionIfAbsent）
   - inHiveNotInIceberg → 删除 Hive 分区（仅删 mixed-table 标记的）
   - inBoth → 比较 location，不同则更新（updatePartitionLocation）
```

**又是差集同步！** 跟 Day2 讲的 `exploreExternalCatalog` 完全同构。

---

### L2 · `UpdateHiveFiles.commit()` 的 9 步流程（生产踩坑重灾区）

**文件**：`amoro-mixed-hive/.../op/UpdateHiveFiles.java`（634 行）

```
UpdateHiveFiles.commit()                                    (L143)
  │
  ├─ ① 计算 commitTimestamp                                (L144)
  ├─ ② 解析 delete 表达式                                   (L145)
  ├─ ③ if syncDataToHive → 先同步 Iceberg→Hive             (L146-148)
  ├─ ④ 确保 add files 一致性写入                            (L149-152)
  ├─ ⑤ 计算 Hive 分区变更（delete/create/alter）            (L155-160)
  ├─ ⑥ 清理孤儿文件（if checkOrphanFiles）                  (L162-164)
  ├─ ⑦ 提交 Iceberg snapshot（delegate.commit）             (L171) ★
  ├─ ⑧ 更新 Iceberg partitionProperty（hive-location + time）(L173)
  ├─ ⑨ 提交到 HMS（add/alter/drop partition）               (L182-191)
  │
  └─ ⑨ 如果 HMS 提交失败 → 只打 WARN 不回滚 Iceberg！        (L188-190)
```

**🔥 生产最大坑在 ⑦→⑨ 之间**：Iceberg 先提交（⑦），HMS 后提交（⑨）。如果 HMS 失败：

- **Iceberg 侧**：新 snapshot 已经生效，数据是对的
- **Hive 侧**：分区 location 还指向旧位置，查询看到的是旧数据

**这就是为什么生产经常出现"Amoro 优化完了，Hive 查到的还是旧数据"的根因**——AMS 的 `HiveCommitSyncExecutor`（每 10 分钟）会最终修复，但中间有窗口期。

---

### L2 · MixedHivePartitionPlan 的 Hive 特殊逻辑

`MixedHivePartitionPlan`（257 行）继承 `MixedIcebergPartitionPlan`，增加了：

#### 1. `inHiveLocation` 判断

```java
private boolean inHiveLocation(ContentFile<?> file) {
  return file.path().toString().contains(hiveLocation);
}
```

在 Hive 目录内的文件被视为"已同步"，**非 Full 优化时不会动它**。

#### 2. `isFragmentFile` 特殊逻辑

```java
protected boolean isFragmentFile(DataFile dataFile) {
  if (file.type() == DataFileType.BASE_FILE) {
    return dataFile.fileSizeInBytes() <= fragmentSize && !inHiveLocation(dataFile);
    //  ★ Hive 目录内的文件无论多小都不算碎片
  }
}
```

#### 3. Full 优化的"移动而非重写"优化

```java
if (evaluator().isFullNecessary() && !config.isFullRewriteAllFiles() && !anyDeleteExist()) {
  // 不重写 Hive 目录内的文件，只移动非 Hive 目录的文件到 Hive 目录
  rewriteDataFiles.removeIf(entry -> evaluator().inHiveLocation(entry.getKey()));
}
```

**精妙之处**：如果只是需要把不在 Hive 目录的文件搬到 Hive 目录（没有 delete 需要处理），就**只 move 不 rewrite**——省大量 IO。

---

## 💡 精妙设计拆解

### 精妙一：`partitionProperty` 作为 Iceberg↔Hive 的桥梁

Amoro 不用额外数据库存同步状态，**直接利用 Iceberg 表自己的 `partitionProperty`** 存两个字段：`hive-location` 和 `transient-time`。这意味着：

1. **状态和表在一起**——不怕 AMS 重启丢失状态
2. **可审计**——查 Iceberg metadata 就能看到同步历史
3. **无额外依赖**——不需要 ZK/Redis/DB 额外存储

### 精妙二：先提交 Iceberg 再提交 Hive 的顺序

```
⑦ Iceberg commit  →  ⑨ HMS commit
```

为什么不先 Hive 再 Iceberg？因为 **Iceberg 是真相源**。如果先提 Hive 后 Iceberg 失败，Hive 指向了新文件但 Iceberg 不认，**数据一致性被破坏**。而现在的顺序下：Iceberg 失败就两边都不变；Iceberg 成功但 Hive 失败，AMS 的 10 分钟同步会修复——**最终一致**。

### 精妙三：`syncHiveDataToMixedTable` 在构造函数里调用

```java
public UnkeyedHiveTable(...) {
  super(...);
  if (enableSyncHiveDataToMixedTable()) syncHiveDataToMixedTable(false);
}
```

**每次有人 loadTable 就做一次 Hive→Iceberg 同步**。这保证了"即使有人绕过 Amoro 直接往 Hive 写数据，下次 loadTable 时也能感知到"。

---

## 🎓 举一反三

| Amoro Mixed-Hive | 同构系统 | 关键词 |
|---|---|---|
| Iceberg→Hive 每 10min 同步 | MySQL→ES 的 canal 同步 | **异步最终一致** |
| `transient_lastDdlTime` 比对 | MySQL binlog position | **变更检测点** |
| `partitionProperty` 作桥梁 | Iceberg metadata 自带属性 | **状态内聚** |
| 先 Iceberg 后 Hive 的提交顺序 | 2PC 的 prepare→commit | **偏序提交** |
| AMS 修复同步窗口 | K8s controller 的 reconcile | **Reconciler** |
| moveFile 而非 rewrite 优化 | HDFS `rename` 代替 `copy` | **零拷贝搬移** |

---

## 📝 课后习题

### ⭐ 题目 1：30 秒默画双向同步图

不看任何资料，画出 Hive↔Iceberg 双向同步的触发时机 + 数据流方向。

### ⭐⭐ 题目 2：生产排障

"用 Hive INSERT OVERWRITE 写了一个分区，10 分钟后 Spark 通过 Amoro Catalog 查还是旧数据。"

根据今天的源码，列出 3 种可能原因。

### ⭐⭐⭐ 题目 3：`UpdateHiveFiles.commit()` 顺序分析

如果把步骤 ⑦ 和 ⑨ 反过来（先提 HMS 再提 Iceberg），会出什么问题？用 200 字描述至少 2 种故障场景。

### ⭐⭐⭐⭐ 题目 4：设计题

现在 HMS 提交失败只打 WARN（L188-190），如果你要加一个 **HMS 提交重试 + 告警** 机制，你要改哪些文件？画出改动清单。

---

## 🧪 知识晶体

### 核心源码锚点
- `SupportHive.java` (52 行) — Hive 能力标记接口
- `UnkeyedHiveTable.java` (184 行) — Hive 表实现，构造时同步
- `UpdateHiveFiles.commit()` (L143-191) — 9 步提交流程
- `HiveMetaSynchronizer.syncHiveDataToMixedTable` (L185-272) — Hive→Iceberg
- `HiveMetaSynchronizer.syncMixedTableDataToHive` (L279-297) — Iceberg→Hive
- `HiveCommitSyncExecutor.execute` (L53-71) — AMS 10min 定时同步
- `MixedHivePartitionPlan` (257 行) — Hive 专用优化计划

### 段位变化

| 维度 | Day6 末 | **Day7 末** |
|---|---|---|
| Amoro 源码段位 | L2+ | **L2++**（Hive 兼容核心打通）|
| Phase 1 完成度 | 6/15 | **7/15**（半程+2） |

---

> **信条**：最难的不是 Iceberg 的部分，是"让 Hive 老系统和 Iceberg 新系统和平共处"的部分。这才是 Mixed-Hive 的全部价值，也是生产最容易出问题的地方。

— eric · Amoro 源码精通 · 第 07 讲
