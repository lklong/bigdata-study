# [教案] Compaction调度策略与性能优化源码深度剖析

> 🎯 教学目标：掌握Hive ACID Compaction的完整调度链路（Initiator→Worker→Cleaner），理解触发策略和性能调优 | ⏰ 预计学时: 110分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：办公室文件整理

想象一个忙碌的办公室，员工们不断往文件柜里塞新文件（INSERT delta）、修改文件（UPDATE delta）。久而久之文件柜塞满小纸条（delta文件堆积），找一个文件要翻很多小纸条（查询变慢）。Compaction就是定期来整理的人：Initiator=主管巡查决定整理哪个柜子；Worker=实际整理员；Cleaner=清洁工扔废纸。

---

## 二、核心概念

### 2.1 三大角色

| 角色 | 职责 | 源码 |
|------|------|------|
| Initiator | 扫描→决策→提交请求 | `Initiator.java` |
| Worker | 获取任务→执行MR→标记完成 | `Worker.java` |
| Cleaner | 检查锁→删除旧文件 | `Cleaner.java` |

### 2.2 状态机

```
initiated → working → ready_for_cleaning → succeeded/failed
```

### 2.3 Minor vs Major

- **Minor**: 合并delta → 更大的delta（快，但不合并base）
- **Major**: 重写base+所有delta → 新base（慢，但彻底整理）

---

## 三、源码深度剖析

### 3.1 Initiator 触发策略（行265-345）

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Initiator.java

// 条件1: delta/base > 10% → Major
float deltaPctThreshold = HiveConf.getFloatVar(conf, HIVE_COMPACTOR_DELTA_PCT_THRESHOLD);
if ((float)deltaSize / (float)baseSize > deltaPctThreshold) return CompactionType.MAJOR;

// 条件2: delta数 > 10 → Minor(有base) / Major(无base)
int deltaNumThreshold = HiveConf.getIntVar(conf, HIVE_COMPACTOR_DELTA_NUM_THRESHOLD);
if (deltas.size() > deltaNumThreshold) {
    return noBase ? CompactionType.MAJOR : CompactionType.MINOR;
}
```

### 3.2 Worker 执行（行80-217）

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Worker.java
public void run() {
    do {
      CompactionInfo ci = txnHandler.findNextToCompact(name); // CAS获取任务
      if (ci == null) { Thread.sleep(5000); continue; }
      
      Table t = resolveTable(ci);
      StorageDescriptor sd = resolveStorageDescriptor(t, p);
      
      CompactorMR mr = new CompactorMR();
      mr.run(conf, jobName, t, p, sd, tblValidWriteIds, ci, su, txnHandler);
      
      txnHandler.markCompacted(ci); // state → ready_for_cleaning
    } while (!stop.get());
}
```

### 3.3 Cleaner 延迟删除（行81-213）

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Cleaner.java
// 核心逻辑：等待所有相关锁释放后才删除旧文件
List<CompactionInfo> toClean = txnHandler.findReadyToClean();
for (CompactionInfo ci : toClean) {
    if (!compactId2LockMap.containsKey(ci.id)) {
        compactId2LockMap.put(ci.id, findRelatedLocks(ci, locksResponse));
    }
}
// 检查锁是否全部释放
if (!sawLock) {
    clean(ci); // AcidUtils.getAcidState() → getObsolete() → fs.delete()
}
```

### 3.4 CompactionTxnHandler CAS获取任务（行165-229）

```java
// 文件: standalone-metastore/.../txn/CompactionTxnHandler.java
// CAS操作防止任务重复执行
String s = "update COMPACTION_QUEUE set cq_worker_id='" + workerId + "', " +
    "cq_state='" + WORKING_STATE + "' where cq_id=" + info.id +
    " AND cq_state='" + INITIATED_STATE + "'";
int updCount = updStmt.executeUpdate(s);
if (updCount == 1) return info;  // 成功获取
if (updCount == 0) continue;     // 被其他Worker抢了
```

---

## 四、关键参数

| 参数名 | 默认值 | 说明 |
|--------|--------|------|
| `hive.compactor.worker.threads` | 1 | Worker线程数 |
| `hive.compactor.delta.num.threshold` | 10 | delta文件数阈值 |
| `hive.compactor.delta.pct.threshold` | 0.1 | delta/base比阈值 |
| `hive.compactor.worker.timeout` | 86400s | Worker超时 |
| `hive.compactor.initiator.failed.compactions.threshold` | 2 | 连续失败容忍 |

---

## 五、面试高频题

**Q1：Minor vs Major 如何决策？**
A：aborted过多→Major; delta/base>10%→Major; delta数>10且有base→Minor; 无base→Major

**Q2：Cleaner为什么等锁？**
A：正在读旧delta的查询可能失败，等锁释放确保安全删除

**Q3：Worker如何防重复执行？**
A：SQL的CAS操作：`UPDATE ... SET state='working' WHERE id=X AND state='initiated'`

---

## 六、知识晶体

```
Initiator(扫描决策) → Worker(执行MR) → Cleaner(删旧文件)
状态: initiated → working → ready_for_cleaning → done
触发: Major(delta/base>10% | 无base) | Minor(delta数>10+有base)
踩坑: Worker OOM堆积 | 长查询阻塞Cleaner | 连续失败停止
```

---

## 七、参考资料

- `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Initiator.java` 行61-378
- `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Worker.java` 行55-326
- `ql/src/java/org/apache/hadoop/hive/ql/txn/compactor/Cleaner.java` 行64-400
- `standalone-metastore/.../txn/CompactionTxnHandler.java` 行44-250
- HIVE-5317: Compaction of ACID tables
