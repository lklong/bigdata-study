# [知识晶体] Iceberg Manifest 合并机制 — 为什么 Planning 会突然变慢？

> 法则2（分形剥离法）L3 异常/边界层 + 法则4（对抗性阅读）
> 基于 `SnapshotProducer.java` / `FastAppend.java` / `MergingSnapshotProducer.java` / `ManifestMergeManager.java` / `BinPacking.java` 真实源码
> Eric | 2026-04-27

---

## 问题/场景

```
故障现象：
  Spark Streaming 作业写入 Iceberg 表 3 个月后：
  - 查询 Planning 从 0.5s 退化到 45s
  - Spark Driver OOM：java.lang.OutOfMemoryError in ManifestGroup.planFiles()
  - HDFS 上 metadata/ 目录有 130,000+ 个 manifest 文件

根因预测：manifest 数量失控。但为什么？Iceberg 不是有自动合并机制吗？

答案在源码里。让我们逐行看清楚。
```

---

## 核心源码

### 第一个关键分叉：FastAppend vs MergeAppend

Iceberg 有两种 append 实现。**选错了，就是灾难的起点。**

```java
// FastAppend.java Line 35 — 注意它的继承关系
class FastAppend extends SnapshotProducer<AppendFiles> implements AppendFiles {
    // 直接继承 SnapshotProducer，★没有★经过 MergingSnapshotProducer
}

// MergeAppend.java Line 24 — 对比看
class MergeAppend extends MergingSnapshotProducer<AppendFiles> implements AppendFiles {
    // 经过 MergingSnapshotProducer，★有★ manifest 合并能力
}
```

**这个继承关系的差异决定了一切。**

### FastAppend.apply() — 永远不合并

```java
// FastAppend.java Line 134-158
@Override
public List<ManifestFile> apply(TableMetadata base, Snapshot snapshot) {
    List<ManifestFile> manifests = Lists.newArrayList();

    // 1. 写一个新 manifest（包含本次新增的文件）
    List<ManifestFile> newWrittenManifests = writeNewManifests();
    if (newWrittenManifests != null) {
        manifests.addAll(newWrittenManifests);
    }

    // 2. 加入手动 append 的 manifest
    Iterables.addAll(manifests, appendManifestsWithMetadata);

    // ★★★ 3. 把旧 snapshot 的所有 manifest 原封不动地加进来 ★★★
    if (snapshot != null) {
        manifests.addAll(snapshot.allManifests(ops.io()));
    }
    // 没有任何 merge 步骤！
    // 每次 commit 至少新增 1 个 manifest，旧的全部保留

    return manifests;
}
```

**对抗性问题**："如果 Spark Streaming 每分钟 commit 一次，用的是 FastAppend 会怎样？"

```
答：每分钟 +1 个 manifest
  1 天 = 1,440 个 manifest
  3 个月 = 129,600 个 manifest
  每次查询 Planning 要读取所有 manifest → O(n) 线性退化
  这就是 130,000 manifest 的由来。
```

### MergingSnapshotProducer — 有合并，但有条件

MergeAppend 继承 MergingSnapshotProducer，后者内部有一个 `ManifestMergeManager`：

```java
// ManifestMergeManager.java Line 72-87（合并入口）
Iterable<ManifestFile> mergeManifests(Iterable<ManifestFile> manifests) {
    // 如果禁用了合并 → 直接返回
    if (!mergeEnabled) {
        return manifests;
    }

    // 如果没有 manifest → 直接返回
    if (Iterables.isEmpty(manifests)) {
        return manifests;
    }

    // 按 PartitionSpec 分组，分别合并
    return Iterables.concat(
        Iterables.transform(
            groupBySpec(manifests),
            group -> mergeGroup(first, group)));  // ← 每个 spec 组独立合并
}
```

### mergeGroup() — 合并的真正判定逻辑

```java
// ManifestMergeManager.java Line 116-161（简化后的核心逻辑）
private Iterable<ManifestFile> mergeGroup(ManifestFile first, List<ManifestFile> group) {
    // ★ 用 BinPacking 按 targetSizeBytes 把 manifest 分到不同的 bin 里
    ListPacker<ManifestFile> packer = new ListPacker<>(targetSizeBytes, 1, false);
    List<List<ManifestFile>> bins = packer.packEnd(group, ManifestFile::length);

    List<ManifestFile> outputManifests = Lists.newArrayList();

    for (List<ManifestFile> bin : bins) {
        // 情况1: bin 里只有 1 个 manifest → 不需要合并
        if (bin.size() == 1) {
            outputManifests.addAll(bin);
            continue;
        }

        // 情况2: ★★★ 关键！★★★
        // 如果这个 bin 包含了"第一个 manifest"（即本次新写的）
        // 且 bin 里的 manifest 数量 < minCountToMerge
        // → 跳过合并！
        if (bin.contains(first) && bin.size() < minCountToMerge) {
            outputManifests.addAll(bin);
            continue;
        }

        // 情况3: 其他情况 → 执行合并
        // 先查缓存（重试时可以复用上次合并的结果）
        if (mergedManifests.containsKey(bin)) {
            outputManifests.add(mergedManifests.get(bin));
        } else {
            ManifestFile merged = createManifest(bin);  // 读取 + 合并 + 写新 manifest
            mergedManifests.put(ImmutableList.copyOf(bin), merged);  // 缓存
            outputManifests.add(merged);
        }
    }

    return outputManifests;
}
```

### BinPacking 算法 — 决定哪些 manifest 在同一个 bin

```java
// BinPacking.java Line 35-58
public class ListPacker<T> {
    private final long targetWeight;   // = targetManifestSizeBytes（默认 8MB）
    private final int lookback;        // = 1

    public List<List<T>> packEnd(List<T> items, Function<T, Long> weightFunc) {
        // 从列表末尾开始打包
        // 每个 bin 的总 weight 不超过 targetWeight
        // lookback = 1：只保持 1 个打开的 bin
        return Lists.reverse(
            ImmutableList.copyOf(
                Iterables.transform(
                    new PackingIterable<>(Lists.reverse(items), targetWeight, 1, weightFunc, false),
                    Lists::reverse)));
    }
}
```

**对抗性问题**："minCountToMerge 默认多少？什么情况下合并永远不会触发？"

```
minCountToMerge 在 ManifestMergeManager 构造中：
  this.minCountToMerge = minCountToMerge;
  // 由 MergingSnapshotProducer 传入，默认 100

这意味着：
  包含新 manifest 的 bin 里需要有 ≥100 个 manifest 才会触发合并！

  但 BinPacking 用 targetWeight=8MB 分 bin：
  如果每个 manifest 都有 7-8MB（比较满），
  那每个 bin 只能放 1 个 → bin.size() 永远 = 1 → 永远不合并！

  ★ 这就是"即使用了 MergeAppend，manifest 仍然不断增长"的根因 ★
  当每个 manifest 都接近 targetSizeBytes 时，BinPacking 无法把它们装进同一个 bin。
```

---

## 调用链

```
table.newAppend().appendFile(f).commit()
  │
  ├── 使用 FastAppend（Spark INSERT INTO 默认）
  │     └── FastAppend.apply() → 不合并，manifest 线性增长
  │
  └── 使用 MergeAppend（Spark 配置 spark.sql.sources.partitionOverwriteMode=dynamic）
        └── MergingSnapshotProducer.apply()
              → ManifestMergeManager.mergeManifests()
                → BinPacking.packEnd()
                  → 按 targetSizeBytes 分 bin
                    → mergeGroup()
                      → bin.size() < minCountToMerge(100)?
                        → YES: 不合并
                        → NO:  合并！
```

---

## 设计意图

为什么 Iceberg 要这么保守地合并？两个 trade-off：

| 考量 | 激进合并 | 保守合并（当前设计） |
|------|---------|-------------------|
| **commit 延迟** | 高（每次都要读旧 manifest + 重写） | 低（大多数情况不合并） |
| **manifest 数量** | 少 | 可能很多 |
| **并发友好** | 差（合并范围大 → 冲突概率高） | 好（只写新 manifest → 冲突少） |
| **重试代价** | 高（合并结果可能作废） | 低（直接拼接） |

**结论**：Iceberg 选择了**写入友好**而非**读取友好**的策略。manifest 合并是"尽力而为"，不是"保证执行"。

---

## 关键参数

| 参数 | 默认值 | 作用 | 调优建议 |
|------|--------|------|---------|
| `commit.manifest.target-size-bytes` | `8388608`（8MB） | BinPacking 的 bin 上限 | 高频写入可增大到 32MB-64MB |
| `commit.manifest.min-count-to-merge` | `100` | 包含新 manifest 的 bin 最小合并数 | 高频写入可降低到 10-20 |
| `commit.manifest-merge.enabled` | `true` | 是否启用 manifest 合并 | 不建议关闭 |

```sql
-- 高频 Streaming 场景的推荐配置
ALTER TABLE t SET TBLPROPERTIES (
    'commit.manifest.target-size-bytes' = '33554432',  -- 32MB（放更多 manifest 进同一个 bin）
    'commit.manifest.min-count-to-merge' = '10'         -- 降低合并阈值
);
```

---

## 关联知识

- **上游**：`SparkWrite` 决定使用 `FastAppend` 还是 `MergeAppend` — 由 `write.spark.use-table-distribution-and-ordering` 和操作类型决定
- **下游**：`ManifestGroup.planFiles()` 在查询时遍历所有 manifest — manifest 越多，Planning 越慢
- **同构**：类似于 LSM-Tree 的 compaction 策略 — Level Compaction（MergeAppend）vs FIFO Compaction（FastAppend）。Iceberg 的保守合并类似 LSM-Tree 的 Size-Tiered Compaction

---

## 踩坑记录

### 踩坑 1：Spark Streaming 默认用 FastAppend

```
现象：用 MergeAppend 配置了参数，但 manifest 还是线性增长
原因：Spark DataSourceV2 的 Streaming 写入内部调用 appendFile()，
      走的是 FastAppend 路径，不经过 MergeAppend
诊断：查看 snapshot summary 中的 operation 字段
      如果是 "append" 且 manifest 不断增长 → FastAppend
解决：定期用 Amoro Self-Optimizing 或手动 rewrite_manifests
```

### 踩坑 2：MergeAppend 的 minCountToMerge 过高

```
现象：用了 MergeAppend，manifest 仍然缓慢增长
原因：每个 manifest 已经接近 8MB，BinPacking 无法在一个 bin 里放下 100 个
      → bin.size() < 100 → 永远不触发合并
解决：降低 min-count-to-merge 或增大 target-size-bytes
```

### 踩坑 3：rewrite_manifests 才是最终杀招

```
当 manifest 已经膨胀到万级，靠 MergeAppend 已经来不及了。
必须用外部 Action 强制重写：

CALL catalog.system.rewrite_manifests(table => 'db.orders');

这个操作会：
1. 读取所有旧 manifest
2. 按 partition spec 重新 BinPacking
3. 写出最优数量的新 manifest
4. 原子替换

相当于 LSM-Tree 的 Manual Compaction。
```

---

## 认知更新记录

```
更新前的认知：
  "Iceberg 会自动合并 manifest，不需要额外关心"

更新后的认知：
  1. FastAppend 永远不合并 manifest — Streaming 写入默认走这条路
  2. MergeAppend 的合并是"尽力而为" — 受 minCountToMerge 和 targetSizeBytes 双重限制
  3. 当 manifest 都接近 targetSize 时，BinPacking 无法把它们合进同一个 bin → 合并失效
  4. manifest 管理需要外部介入：Amoro Self-Optimizing 或 rewrite_manifests Action
  5. 这个设计是有意为之 — 写入友好 > 读取友好，trade-off 在于 commit 延迟和并发安全

核心洞察：
  Iceberg 的 manifest 管理策略是 LSM-Tree 的 Size-Tiered Compaction 思想。
  写入只管追加，合并交给后台（Amoro / 定时 Action）。
  理解了这一点，就理解了为什么 Amoro 存在的核心价值。
```
