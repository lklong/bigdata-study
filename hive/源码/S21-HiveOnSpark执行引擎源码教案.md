# [教案] HiveOnSpark执行引擎源码深度剖析

> 🎯 教学目标：掌握Hive on Spark的任务提交、监控、执行全链路，理解SparkTask/SparkWork的生成逻辑，能排查Spark任务提交失败问题 | ⏰ 预计学时: 100分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：外卖平台的配送调度

想象一个外卖平台：客户下了一单（SQL查询），平台需要把订单拆成多个配送任务（Map/Reduce阶段），然后分配给骑手（Spark Executor）去执行。

- **SparkWork** = 配送方案：哪些菜从哪个餐厅取，先取什么后取什么
- **SparkTask** = 配送调度员：负责把方案提交给骑手团队，并监控配送进度
- **RemoteSparkJobMonitor** = 实时追踪系统：骑手现在在哪？还有多远？超时了吗？
- **SparkSession** = 骑手团队的连接通道

### 生产故障场景

```
故障现象：Hive SQL通过Spark引擎执行时卡住30分钟后超时失败
日志关键信息：
  WARN SparkTask - Spark job state = QUEUED
  ERROR RemoteSparkJobMonitor - Failed to monitor Job[null] with exception 'Connection to remote Spark driver was lost'
  
根因：yarn队列资源不足，Spark Application无法获取Container启动Driver
```

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| SparkWork | Spark DAG执行计划，包含多个MapWork/ReduceWork | 外卖配送方案 |
| SparkTask | Hive Task的子类，负责提交和管理Spark作业 | 配送调度员 |
| SparkSession | 与远程Spark Driver的连接会话 | 骑手团队的通信频道 |
| SparkJobRef | Spark作业的引用句柄，用于监控和取消 | 配送单号 |
| RemoteSparkJobMonitor | 远程Spark作业状态监控器 | 实时配送追踪系统 |
| SparkEdgeProperty | 两个Work之间的数据交换方式（Shuffle/Broadcast） | 餐厅之间的中转方式 |
| GenSparkWork | 将Operator Tree转换为SparkWork的规则 | 订单拆分算法 |

### 2.2 架构图

```
┌────────────────────────────────────────────────────────────┐
│                     HiveServer2                              │
│                                                              │
│  SQL ──> Parser ──> Optimizer ──> PhysicalPlan               │
│                                       │                      │
│                                       ▼                      │
│                              ┌─────────────┐                 │
│                              │ GenSparkWork │ (规则)          │
│                              └──────┬──────┘                 │
│                                     │ 生成                    │
│                                     ▼                        │
│                              ┌─────────────┐                 │
│                              │  SparkWork   │ (DAG)          │
│                              │ ┌─────────┐  │                │
│                              │ │MapWork 1│──┤                │
│                              │ └────┬────┘  │                │
│                              │      │Edge   │                │
│                              │ ┌────▼────┐  │                │
│                              │ │ReduceWork│  │                │
│                              │ └─────────┘  │                │
│                              └──────┬──────┘                 │
│                                     │                        │
│                              ┌──────▼──────┐                 │
│                              │  SparkTask   │                │
│                              │  .execute()  │                │
│                              └──────┬──────┘                 │
│                                     │                        │
│                              ┌──────▼──────┐                 │
│                              │SparkSession  │                │
│                              │  .submit()   │                │
│                              └──────┬──────┘                 │
└─────────────────────────────────────┼────────────────────────┘
                                      │ Remote Spark Client (RSC)
                                      ▼
                        ┌──────────────────────────┐
                        │    Spark Driver (YARN)     │
                        │  ┌──────┐  ┌──────┐       │
                        │  │Stage1│─>│Stage2│       │
                        │  └──┬───┘  └──┬───┘       │
                        │     │         │            │
                        │  ┌──▼───┐  ┌──▼───┐       │
                        │  │Tasks │  │Tasks │       │
                        │  └──────┘  └──────┘       │
                        └──────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 核心类 | 源码路径 | 职责 |
|--------|---------|------|
| `SparkTask` | `ql/src/java/org/apache/hadoop/hive/ql/exec/spark/SparkTask.java` | 提交Spark作业并监控执行 |
| `SparkWork` | `ql/src/java/org/apache/hadoop/hive/ql/plan/SparkWork.java` | 封装Spark DAG执行计划 |
| `RemoteSparkJobMonitor` | `ql/.../exec/spark/status/RemoteSparkJobMonitor.java` | 监控远程Spark作业状态 |
| `GenSparkWork` | `ql/.../parse/spark/GenSparkWork.java` | 将Operator Tree转换为SparkWork |
| `SparkSessionManager` | `ql/.../exec/spark/session/SparkSessionManager.java` | 管理SparkSession池 |

### 3.2 关键方法逐行解读

#### 3.2.1 SparkTask.execute() — 核心执行入口

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/spark/SparkTask.java
// 行号: 106-219

@Override
public int execute(DriverContext driverContext) {
    int rc = 0;
    perfLogger = SessionState.getPerfLogger();
    SparkSession sparkSession = null;
    SparkSessionManager sparkSessionManager = null;
    try {
      printConfigInfo();
      // 【步骤1】获取SparkSession
      sparkSessionManager = SparkSessionManagerImpl.getInstance();
      sparkSession = SparkUtilities.getSparkSession(conf, sparkSessionManager);

      // 【步骤2】获取SparkWork（DAG计划）
      SparkWork sparkWork = getWork();
      sparkWork.setRequiredCounterPrefix(getOperatorCounters());

      // 【步骤3】提交Spark作业
      perfLogger.PerfLogBegin(CLASS_NAME, PerfLogger.SPARK_SUBMIT_JOB);
      submitTime = perfLogger.getStartTime(PerfLogger.SPARK_SUBMIT_JOB);
      jobRef = sparkSession.submit(driverContext, sparkWork);
      perfLogger.PerfLogEnd(CLASS_NAME, PerfLogger.SPARK_SUBMIT_JOB);

      // 【步骤4】检查是否被取消
      if (driverContext.isShutdown()) {
        killJob();
        throw new HiveException("Operation is cancelled.");
      }

      // 【步骤5-6】获取ID
      sparkJobHandleId = jobRef.getJobId();
      jobID = jobRef.getSparkJobStatus().getAppID();

      // 【步骤7】启动监控循环
      rc = jobRef.monitorJob();

      // 【步骤8-9】处理结果
      sparkJobID = jobRef.getSparkJobStatus().getJobId();
      SparkJobStatus sparkJobStatus = jobRef.getSparkJobStatus();

      if (rc == 0) {
        sparkStatistics = sparkJobStatus.getSparkStatistics();
        printExcessiveGCWarning();
      } else if (rc == 2) {
        killJob();  // 超时
      } else if (rc == 4) {
        killJob();  // Task数超限
      }
    } finally {
      // 【步骤10】清理资源
      Utilities.clearWork(conf);
      if (sparkSession != null && sparkSessionManager != null) {
        rc = close(rc);
        sparkSessionManager.returnSession(sparkSession);
      }
    }
    return rc;
}
```

#### 3.2.2 RemoteSparkJobMonitor.startMonitor() — 状态机监控

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/exec/spark/status/RemoteSparkJobMonitor.java
// 行号: 55-215

@Override
public int startMonitor() {
    boolean running = false;
    boolean done = false;
    int rc = 0;

    while (true) {
      try {
        state = sparkJobStatus.getRemoteJobState();
        Preconditions.checkState(sparkJobStatus.isRemoteActive(),
            "Connection to remote Spark driver was lost");

        switch (state) {
        case SENT:
        case QUEUED:
          long timeCount = (System.currentTimeMillis() - startTime) / 1000;
          if (timeCount > monitorTimeoutInterval) {
            rc = 2;  // 超时
            done = true;
          }
          break;

        case STARTED:
          if (sparkJobState == JobExecutionStatus.RUNNING) {
            if (!running) {
              printAppInfo();
              running = true;
            }
            // 检查Task数限制
            if (stageMaxTaskCount > sparkStageMaxTaskCount) {
              rc = 4; done = true;
            }
            printStatus(progressMap, lastProgressMap);
          }
          break;

        case SUCCEEDED: rc = 0; done = true; break;
        case FAILED:    rc = 3; done = true; break;
        case CANCELLED: rc = 3; done = true; break;
        }

        if (!done) Thread.sleep(checkInterval);
      } catch (Exception e) {
        rc = 1; done = true;
      } finally {
        if (done) break;
      }
    }
    return rc;
}
```

#### 3.2.3 SparkWork DAG结构

```java
// 文件: ql/src/java/org/apache/hadoop/hive/ql/plan/SparkWork.java
// 行号: 50-96

public class SparkWork extends AbstractOperatorDesc {
  private final Set<BaseWork> roots = new LinkedHashSet<>();
  private final Set<BaseWork> leaves = new LinkedHashSet<>();
  protected final Map<BaseWork, List<BaseWork>> workGraph;
  protected final Map<BaseWork, List<BaseWork>> invertedWorkGraph;
  protected final Map<Pair<BaseWork, BaseWork>, SparkEdgeProperty> edgeProperties;
}
```

### 3.3 调用链时序图

```
 HiveServer2       SparkTask      SparkSession    RSC(Remote)    SparkDriver
     │                │                │               │               │
     │ execute()      │                │               │               │
     │───────────────>│                │               │               │
     │                │ submit(work)   │               │               │
     │                │───────────────>│  submitJob()  │               │
     │                │                │──────────────>│  executeJob() │
     │                │                │               │──────────────>│
     │                │ monitorJob()   │               │               │
     │                │──loop──>getRemoteJobState()───>│               │
     │                │         QUEUED/RUNNING/DONE    │               │
     │                │<──────────────────────────────│               │
     │  rc=0/2/3/4    │                │               │               │
     │<───────────────│                │               │               │
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：提交超时（rc=2）
```
原因：YARN资源不足
解决：增大 hive.spark.job.monitor.timeout 和 YARN 队列资源
```

#### 场景2：Driver连接丢失
```
原因：Driver OOM / 网络分区
解决：增大 spark.driver.memory / hive.spark.client.connect.timeout
```

#### 场景3：Task数超限（rc=4）
```
原因：小文件过多/分区数太多
解决：SET hive.merge.sparkfiles=true; 调大 max.tasks 限制
```

### 4.2 关键参数调优

| 参数名 | 默认值 | 建议值 | 说明 |
|--------|--------|--------|------|
| `hive.spark.job.monitor.timeout` | 60s | 300s | 监控超时 |
| `hive.spark.job.max.tasks` | 100000 | 200000 | Task数上限 |
| `spark.driver.memory` | 1g | 4g | Driver内存 |
| `spark.executor.memory` | 1g | 4g | Executor内存 |

---

## 五、举一反三

### 5.1 与Hive on Tez对比

| 维度 | Hive on Spark | Hive on Tez |
|------|--------------|-------------|
| DAG模型 | SparkWork | TezWork |
| 监控方式 | RSC远程轮询 | Tez AM直接回调 |
| Session复用 | SparkSession池 | LLAP Container复用 |
| 社区状态 | 已弃用 | 主力引擎 |

### 5.2 面试高频题

**Q1：Hive SQL如何转换为Spark作业？**
A：SQL→AST→LogicalPlan→GenSparkWork→SparkWork(DAG)→SparkTask→RSC提交

**Q2：监控状态机有哪些状态？**
A：SENT→QUEUED→STARTED(RUNNING)→SUCCEEDED/FAILED/CANCELLED

### 5.3 思考题

1. 为什么Hive on Spark被弃用了？Tez有什么架构优势？
2. GC警告阈值10%是否合理？什么场景需要调整？

---

## 六、知识晶体（一页纸总结）

```
┌────────── Hive on Spark 知识晶体 ──────────┐
│ 链路: SQL→GenSparkWork→SparkWork→SparkTask  │
│       →SparkSession.submit()→Monitor→Done   │
│ 返回码: 0=成功 2=超时 3=失败 4=Task超限      │
│ 踩坑: QUEUED超时查YARN | Driver OOM查内存     │
│ 注意: Hive 3.0+ 已弃用，推荐 Tez            │
└────────────────────────────────────────────┘
```

---

## 七、参考资料

- `ql/src/java/org/apache/hadoop/hive/ql/exec/spark/SparkTask.java` 行 77-349
- `ql/src/java/org/apache/hadoop/hive/ql/exec/spark/status/RemoteSparkJobMonitor.java` 行 38-228
- `ql/src/java/org/apache/hadoop/hive/ql/plan/SparkWork.java` 行 50-96
- HIVE-7292: Hive on Spark 总体设计
- HIVE-14213: Deprecation of Hive on Spark
