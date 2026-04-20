# Tez 分片逻辑完整解析 + 682541 vs 683560 Map 数差异根因

---

## 一、分片计算完整链路（三层影响）

```
availableSlots = totalResource / taskResource
                 ↑ AM第一次心跳时RM返回的headroom快照（只赋值一次）
                 
                 │
                 │ 影响层1：原始 split 切分
                 ▼
inputFormat.getSplits(jobConf, numSplits=(int)(availableSlots * waves))
  └→ HiveInputFormat.getSplits(job, numSplits)
       └→ addSplitsForGroup(..., currentDirs.size() * (numSplits / dirs.length), ...)
            └→ 实际InputFormat.getSplits(conf, numSplitsForThisGroup)
                 └→ FileInputFormat.getSplits():
                      goalSize = totalSize / numSplits
                      splitSize = max(minSize, min(goalSize, blockSize))
                      ← minSize 已被设为 preferredSplitSize
                      ← numSplits 越大 → goalSize 越小 → splitSize 越小 → 原始splits越多

                 │
                 │ 影响层2：SplitGrouper 分桶
                 ▼
SplitGrouper.generateGroupedSplits(jobConf, conf, splits, waves, availableSlots, ...)
  └→ schemaEvolved() → 按 schema 边界分桶
  └→ group(conf, bucketSplitMultiMap, availableSlots, waves, locationProvider)
       └→ estimateBucketSizes(availableSlots, waves, bucketSplitMap)
            desiredNumSplits = (int)(availableSlots * waves * bucketSize / totalSize)
            ← 如果只有1个bucket: desiredNumSplits = (int)(availableSlots * waves)

                 │
                 │ 影响层3：TezSplitGrouper 边界检查 + 分组
                 ▼
TezSplitGrouper.getGroupedSplits(conf, rawSplits, desiredNumSplits, ...)
  │
  ├─ lengthPerGroup = totalLength / desiredNumSplits
  │
  ├─ if (lengthPerGroup > maxSize):
  │    desiredNumSplits = totalLength / maxSize + 1     ← 被max-size兜底
  │
  ├─ if (lengthPerGroup < minSize):
  │    desiredNumSplits = totalLength / minSize + 1     ← 被min-size兜底
  │
  ├─ ★★★ if (desiredNumSplits >= originalSplits.size()):
  │    return 原始splits，不分组！                       ← 关键退出路径！
  │
  └─ 否则：按 location 多轮迭代合并 → 最终 grouped splits
```

### 关键：三种结果路径

| 路径 | 条件 | 最终 Map 数 |
|------|------|------------|
| **A. max-size 兜底** | `lengthPerGroup > maxSize` | `totalLength / maxSize + 1`（**固定，跟 availableSlots 无关**） |
| **B. min-size 兜底** | `lengthPerGroup < minSize` | `totalLength / minSize + 1`（**固定，跟 availableSlots 无关**） |
| **C. 不分组** | `desiredNumSplits >= 原始splits数` | **= 原始 splits 数**（直接受 availableSlots 影响） |
| **D. 正常分组** | 其他情况 | **≈ desiredNumSplits**（直接受 availableSlots 影响） |

---

## 二、682541 vs 683560 Map 数差异根因

### 已知事实

| | 682541 | 683560 |
|---|---|---|
| **AM 提交** | 00:20:04 | 03:51:36 |
| **AM 启动** | ~00:26 | ~04:11（等了20分钟） |
| **DAG2 Map 1** | **246** | **487** |
| **DAG2 Reducer 2** | 2000 | 2000（auto缩减后500） |
| **DAG2 实际并发** | ? | **3** |
| **数据量** | 相同 | 相同 |
| **SQL** | 相同 | 相同 |
| **队列** | dw | dw |

### 推断

**487 / 246 ≈ 1.98 ≈ 2 倍**。同一份数据，Map 数差一倍。

根据上面的三层链路，`availableSlots` 同时影响了：
1. **原始 split 数**（通过 `getSplits(numSplits)` → `goalSize` → `splitSize`）
2. **desiredNumSplits**（通过 `estimateBucketSizes`）
3. **是否触发边界检查**

最可能的场景：

```
682541 (00:26 AM启动):
  队列 dw 比较忙 → totalResource 较小
  → availableSlots = A（较小，比如 ~150）
  → numSplits 传给 getSplits = (int)(A * 1.7) ≈ 255
  → 原始 splits 按这个 hint 切出来 ≈ N 个
  → desiredNumSplits = (int)(A * 1.7) ≈ 255
  → lengthPerGroup = totalLength / 255
  → 可能在 minSize~maxSize 之间 → 走路径 D
  → 分组后 ≈ 246

683560 (04:11 AM启动):
  队列 dw 此刻恰好有资源释放 → totalResource 较大
  → availableSlots = B ≈ 2A（较大，比如 ~300）
  → numSplits 传给 getSplits = (int)(B * 1.7) ≈ 510
  → 原始 splits 被切得更细 ≈ M 个（M > N）
  → desiredNumSplits = (int)(B * 1.7) ≈ 510
  → 如果 desiredNumSplits >= 原始splits数 → 走路径 C（不分组）
  → Map 数 = 原始 splits 数 ≈ 487
  
  或者 lengthPerGroup < minSize → 走路径 B → Map 数被 minSize 兜底
```

### 为什么 DAG2 实际只拿到 3 个 Container？

`availableSlots` 是 **AM 注册那一瞬间** RM 返回的队列资源快照。

```
04:11  AM 启动，注册到 RM
       → RM 返回 totalResource（此刻队列瞬时有大量空闲）
       → availableSlots 很大
       → 分片计算得出 487 个 Map

04:12  DAG2 开始调度 Container
       → RM 的调度器（CapacityScheduler）逐心跳分配
       → 此时队列里有 82 个 active apps 竞争
       → 每次心跳只分到 0~3 个 Container
       → 实际并发 = 3
```

**核心矛盾**：分片计算用的是**理论资源快照**，实际调度用的是**竞争后的真实分配**。两者可以差十倍以上。

---

## 三、Tez 这个缺陷的解法

### 3.1 问题定义

`availableSlots` 是 AM 注册时的瞬时快照，不反映实际可用资源：
- 资源多时 → Map 数过多 → 小 split、高并发预期 → 实际并发低 → Map 慢慢排队跑
- 资源少时 → Map 数过少 → 大 split → 单个 Map 耗时长

### 3.2 方案一：固定分片大小（推荐，最简单）

**绕过 `availableSlots` 的影响，用固定参数控制分片。**

```sql
-- 方案1a: 直接指定分组数（最强硬）
SET tez.grouping.split-count=250;
-- 效果：TezSplitGrouper 的 configNumSplits 生效，覆盖 desiredNumSplits
-- 源码: TezSplitGrouper.java 第172行
--   int configNumSplits = conf.getInt(TEZ_GROUPING_SPLIT_COUNT, 0);
--   if (configNumSplits > 0) desiredNumSplits = configNumSplits;

-- 方案1b: 通过 max-size 和 min-size 夹逼（推荐）
SET tez.grouping.max-size=268435456;   -- 256MB
SET tez.grouping.min-size=201326592;   -- 192MB
-- 效果：不管 availableSlots 多少，lengthPerGroup 都会被约束在 192MB~256MB
-- Map 数 ≈ totalLength / 256MB ~ totalLength / 192MB
-- 两次执行结果一致

-- 方案1c: 控制原始 split 大小
SET mapreduce.input.fileinputformat.split.maxsize=268435456;  -- 256MB
-- 效果：FileInputFormat.getSplits() 的 splitSize 被限制
```

### 3.3 方案二：Session 级别固定 availableSlots

```sql
-- Tez 没有直接暴露这个参数，但可以通过固定 task 资源间接影响
SET hive.tez.container.size=4096;      -- 固定 task 内存
-- 如果 totalResource 波动，availableSlots = totalResource / 4096 仍会波动
-- 所以这个方案效果有限
```

### 3.4 方案三：开启 auto reducer parallelism 做后期调整

```sql
SET hive.tez.auto.reducer.parallelism=true;
-- 效果：Reducer 数可以在运行时根据实际 Map 输出调整
-- 但注意：这只调整 Reducer，不调整 Map 数
-- Map 数一旦在 InputInitializer 阶段确定就不会变
```

### 3.5 方案四：升级到更新版本

**Tez 0.10.2+ 和 Hive 4.x 的改进**：

- **HIVE-22192**：引入 `hive.tez.bucket.pruning`，减少不必要的 split
- **TEZ-4384**：改进 `TezSplitGrouper` 的分组算法，减少对 `availableSlots` 的依赖
- **HIVE-23717**：`SplitGrouper` 支持基于历史统计的分片，而非依赖瞬时资源

### 3.6 最佳实践建议（针对本案例）

```sql
-- 对于这个 ODS→DWD 的 ETL 任务，建议在调度脚本中加：
SET tez.grouping.max-size=268435456;    -- 256MB
SET tez.grouping.min-size=201326592;    -- 192MB
SET hive.tez.auto.reducer.parallelism=true;
SET hive.exec.reducers.bytes.per.reducer=268435456;  -- 256MB

-- 这样：
-- 1. Map 数 = totalLength / (192~256MB)，固定不受队列资源波动影响
-- 2. Reducer 数根据实际 Map 输出自动调整
-- 3. 两次执行同一数据的 Map 数一致
```

---

## 四、总结

```
根因链：
  AM注册时 RM 返回的 totalResource 不同
  → availableSlots 不同
  → 同时影响原始 split 切分 + SplitGrouper 的 desiredNumSplits
  → 最终 Map 数不同（246 vs 487）
  → 但实际可用 Container 远少于 Map 数（只有 3 个并发）
  → 487 个 Map 以 3 并发串行跑，效率极低

解法：
  SET tez.grouping.max-size 和 min-size 夹逼
  → 让 Map 数由数据量决定，不受 availableSlots 瞬时波动影响
```
