# application_1762781849738_683560 Task 执行进度日志

---

## DAG 执行进度时间线

```
03:51:34  ──── SQL 编译开始 ────
03:51:36  Tez Session 创建 + YARN 提交
          Session: dwd_nf_iot_report_gps_others_alarm_event_mt_da_2026/04/07/00
          Track URL: http://10.23.0.33:5004/proxy/application_1762781849738_683560/
          │
          │  （等待 AM 启动 + PreWarm，耗时 ~20 分钟）
          │
04:11:46  ──── DAG 1: TezPreWarmDAG_0 提交 ────
04:11:46  dagId=dag_1762781849738_683560_1（预热 Container）
          │
04:12:05  ──── DAG 2: 实际查询提交 ────
04:12:05  dagId=dag_1762781849738_683560_2
          dagName=dwd.dwd_nf_iot_report_gps_others_alarm_event_mt_da_20260407
          queryId=hadoop_20260408035134_bca05f56-67bf-44ed-b25f-51424252fef6
          Map 1: 486 tasks（task 编号 000000~000485）
          Reducer 2: 500 tasks
          │
          │  （DAG 2 运行 1 小时 11 分钟）
          │
05:23:23  ──── DAG 2: FAILED ────
          Map 1: task_000485 失败（最后一个 task）
            attempt 0: EOFException: Unexpected end of input stream
            attempt 1: EOFException: Unexpected end of input stream
            attempt 2: EOFException: Unexpected end of input stream
            attempt 3: EOFException: Unexpected end of input stream
          → failedTasks:1 killedTasks:0
          Reducer 2: killedTasks:500（因 Map 1 失败而被 kill）
          DAG 状态: VERTEX_FAILURE → failedVertices:1 killedVertices:1
          │
05:23:24  Driver 报错: return code 2 from TezTask
          │
05:23:25  ──── DAG 3: 自动重试提交 ────
05:23:25  dagId=dag_1762781849738_683560_3（同一 queryId，重新执行）
          dagName=dwd.dwd_nf_iot_report_gps_others_alarm_event_mt_da_20260407
          Map 1: 487 tasks
          Reducer 2: ≥2 tasks
          │
          │  （DAG 3 运行 1 小时 43 分钟）
          │
07:06:36  ──── DAG 3: 被用户 KILL ────
          "Sending client kill from dmp (auth:SIMPLE) at 10.23.0.43"
          Map 1: killedTasks:487（全部被 kill，failedTasks:0）
          Reducer 2: killedTasks:2（DAG_TERMINATED）
          │
07:06:36  RM 端：488 个 Container 批量状态变化（0.1 秒内）
          ├─ RUNNING→COMPLETED: 157 个
          ├─ RUNNING→RELEASED: 331 个
          └─ RMContainer doesn't exist: 487 条
          │
07:06:58  App 注销: RUNNING → FINAL_SAVING → FINISHING
07:06:58  "unregistered successfully"
07:06:59  AM Container(000001): RUNNING → COMPLETED
07:06:59  App: FINISHING → FINISHED
          队列 dw: 82 active apps remaining
          │
07:06:59  ──── 应用结束 ────
          │
09:10:29  从 StateStore 清除（maxCompletedApps=1000）
```

---

## 详细日志

### 一、HiveServer2 端（查询编译、DAG 提交、Vertex 状态）

```
03:51:36,522  INFO  TezClient: Tez system stage directory 
              hdfs://HDFS8002921/tmp/hive/dmp/_tez_session_dir/
              afda0248-d50b-4a12-a59c-239907caedcf/.tez/application_1762781849738_683560 
              doesn't exist and is created

03:51:36,756  INFO  YarnClientImpl: Submitted application application_1762781849738_683560

03:51:36,757  INFO  TezClient: The url to track the Tez Session: 
              http://10.23.0.33:5004/proxy/application_1762781849738_683560/

04:11:46,611  INFO  TezClient: Submitting dag to TezSession
              sessionName=dwd_nf_iot_report_gps_others_alarm_event_mt_da_2026/04/07/00
              applicationId=application_1762781849738_683560
              dagName=TezPreWarmDAG_0

04:11:46,885  INFO  FrameworkClient: Submitted dag
              dagId=dag_1762781849738_683560_1, dagName=TezPreWarmDAG_0

04:12:05,258  INFO  TezClient: Submitting dag to TezSession
              dagName=dwd.dwd_nf_iot_report_gps_others_alarm_event_mt_da_20260407
              callerContext={ context=HIVE, callerType=HIVE_QUERY_ID, 
              callerId=hadoop_20260408035134_bca05f56-67bf-44ed-b25f-51424252fef6 }

04:12:05,447  INFO  FrameworkClient: Submitted dag
              dagId=dag_1762781849738_683560_2

04:12:05,447  INFO  exec.Task: TezTask jobId: application_1762781849738_683560

04:12:05,798  INFO  SessionState: Status: Running 
              (Executing on YARN cluster with App id application_1762781849738_683560)

05:23:23,603  ERROR SessionState: Vertex failed
              vertexName=Map 1
              vertexId=vertex_1762781849738_683560_2_00
              taskId=task_1762781849738_683560_2_00_000485
              ├─ attempt 0: EOFException: Unexpected end of input stream
              ├─ attempt 1: EOFException: Unexpected end of input stream
              ├─ attempt 2: EOFException: Unexpected end of input stream
              └─ attempt 3: EOFException: Unexpected end of input stream
              failedTasks:1 killedTasks:0
              原因: OWN_TASK_FAILURE

05:23:23,603  ERROR SessionState: Vertex killed
              vertexName=Reducer 2
              vertexId=vertex_1762781849738_683560_2_01
              failedTasks:0 killedTasks:500
              原因: OTHER_VERTEX_FAILURE

05:23:24,447  ERROR Driver: FAILED: Execution Error, return code 2 from TezTask
              DAG did not succeed due to VERTEX_FAILURE
              failedVertices:1 killedVertices:1

05:23:25,817  INFO  TezClient: Submitting dag to TezSession（DAG 3 重试）
              dagName=dwd.dwd_nf_iot_report_gps_others_alarm_event_mt_da_20260407

05:23:25,895  INFO  FrameworkClient: Submitted dag
              dagId=dag_1762781849738_683560_3

05:23:25,895  INFO  exec.Task: TezTask jobId: application_1762781849738_683560

05:23:25,923  INFO  SessionState: Status: Running

07:06:36,870  ERROR SessionState: Sending client kill 
              from dmp (auth:SIMPLE) at 10.23.0.43 
              to dag dag_1762781849738_683560_3

07:06:36,870  ERROR SessionState: Vertex killed
              vertexName=Reducer 2
              vertexId=vertex_1762781849738_683560_3_01
              failedTasks:0 killedTasks:2
              原因: DAG_TERMINATED

07:06:36,870  ERROR SessionState: Vertex killed
              vertexName=Map 1
              vertexId=vertex_1762781849738_683560_3_00
              failedTasks:0 killedTasks:487
              原因: DAG_TERMINATED

07:06:36,929  INFO  TezClient: Shutting down Tez Session
              sessionName=dwd_nf_iot_report_gps_others_alarm_event_mt_da_2026/04/07/00
              applicationId=application_1762781849738_683560
```

### 二、ResourceManager 端（Container 状态转换）

**Container 状态统计（07:06:36 批量处理）**：

| 状态转换 | 数量 |
|---------|------|
| RUNNING → COMPLETED | 157 |
| RUNNING → RELEASED | 331 |
| RMContainer doesn't exist | 487 |

**App 状态机转换**：

```
07:06:58,713  AppAttempt: RUNNING → FINAL_SAVING (UNREGISTERED, exit:-1000)
07:06:58,713  App: RUNNING → FINAL_SAVING (ATTEMPT_UNREGISTERED)
07:06:58,716  StateStore: Updating info for app
07:06:58,716  AppAttempt: FINAL_SAVING → FINISHING (ATTEMPT_UPDATE_SAVED)
07:06:58,718  App: FINAL_SAVING → FINISHING (APP_UPDATE_SAVED)
07:06:58,815  ApplicationMasterService: unregistered successfully
07:06:59,198  Unregistering app attempt: appattempt_1762781849738_683560_000001
07:06:59,198  AM Container(000001): RUNNING → COMPLETED
07:06:59,198  AMRMTokenSecretManager: removing password
07:06:59,198  AppAttempt: FINISHING → FINISHED (CONTAINER_FINISHED)
07:06:59,199  App: FINISHING → FINISHED (ATTEMPT_FINISHED)
07:06:59,199  CapacityScheduler: finalState=FINISHED
07:06:59,199  requests cleared
07:06:59,199  LeafQueue removed: dw, user:dmp, active:82, pending:0
07:06:59,199  ParentQueue removed: users, apps:82
07:06:59,199  ParentQueue removed: root, apps:92
```

### 三、RM Audit 日志（Container 释放失败）

- **总计**：865 条 `AM Released Container FAILURE`
- **时间**：05:14:20 ~ 07:06:36
- **Container 范围**：000002 ~ 000943
- **原因**：`Trying to release container not owned by app or with invalid id`
- **根因**：RM Failover（epoch=e40）后旧 Container 状态丢失

### 四、HS2 Audit 快照（每 10 秒采样）

| 时间 | Duration(s) | State |
|------|------------|-------|
| 03:51:38 | 3 | RUNNING |
| 03:52:17 | 43 | RUNNING |
| ... | ... | RUNNING（每 10 秒一条，共 1193 条） |
| 07:07:26 | 11701 | RUNNING（end_time=07:06:36） |
| 07:08:55 | 11701 | RUNNING（最后一条快照） |

**总执行时长**：11701 秒 = **3 小时 15 分钟**（03:51:34 ~ 07:06:36）

---

## DAG 级别 Task 汇总

| DAG | Vertex | Task 总数 | Failed | Killed | 运行时长 | 结果 |
|-----|--------|----------|--------|--------|---------|------|
| dag_1 | TezPreWarmDAG | - | - | - | ~19s | 预热完成 |
| dag_2 | Map 1 | 486 | 1 (task_000485) | 0 | 71 min | FAILED |
| dag_2 | Reducer 2 | 500 | 0 | 500 | - | KILLED |
| dag_3 | Map 1 | 487 | 0 | 487 | 103 min | KILLED(用户) |
| dag_3 | Reducer 2 | ≥2 | 0 | 2 | - | KILLED |
