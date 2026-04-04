# S01: 一条 SQL 从提交到返回结果的完整链路 — Part 2

## 5. 逐节点源码分析（语义分析 → 执行 → 结果返回）

### 5.1 Compiler.analyze() — 语义分析总控

- **源码位置**: `ql/.../Compiler.java:185`
- **核心逻辑**:
  ```java
  perfLogger.perfLogBegin(CLASS_NAME, PerfLogger.ANALYZE);
  hookRunner.runBeforeCompileHook(context.getCmd());
  SessionState.get().getCurrentFunctionsInUse().clear();
  Hive.get().getMSC().flushCache();  // ★ 刷新 MetaStore 缓存，防止脏读

  // 执行 PreAnalyze Hooks
  if (hasPreAnalyzeHooks) {
      tree = hookRunner.runPreAnalyzeHooks(hookCtx, tree);
  }

  // ★ 根据 AST 类型选择 SemanticAnalyzer
  BaseSemanticAnalyzer sem = SemanticAnalyzerFactory.get(queryState, tree);

  // ★ 执行语义分析
  sem.startAnalysis();
  sem.analyze(tree, context);  // 模板方法 → analyzeInternal()
  sem.endAnalysis(tree);

  LOG.info("Semantic Analysis Completed (retrial = {})");  // ← 【日志点③】
  sem.validate();
  ```

**故障点 F6**: MetaStore 缓存刷新
| 现象 | 日志 | 根因 |
|------|------|------|
| 查询引用的表刚创建却报"表不存在" | MetaException | HMS 连接断开，`getMSC()` 失败 |

### 5.2 SemanticAnalyzerFactory.get() — 路由决策

- **源码位置**: `ql/.../parse/SemanticAnalyzerFactory.java:44`
- **路由规则**（完整 switch）:

| AST Token | 路由到 | 说明 |
|-----------|--------|------|
| `TOK_EXPLAIN` | `ExplainSemanticAnalyzer` | EXPLAIN 语句 |
| `TOK_LOAD` | `LoadSemanticAnalyzer` | LOAD DATA |
| `TOK_EXPORT` | `ExportSemanticAnalyzer` / `AcidExportSemanticAnalyzer` | EXPORT |
| `TOK_IMPORT` | `ImportSemanticAnalyzer` | IMPORT |
| `TOK_REPL_*` | `ReplicationSemanticAnalyzer` | 复制相关 |
| `TOK_ANALYZE` | `ColumnStatsSemanticAnalyzer` | ANALYZE TABLE |
| `TOK_UPDATE_TABLE` | `UpdateSemanticAnalyzer` | UPDATE |
| `TOK_DELETE_FROM` | `DeleteSemanticAnalyzer` | DELETE |
| `TOK_MERGE` | `MergeSemanticAnalyzer` | MERGE |
| DDL 类 | `DDLSemanticAnalyzerFactory` | CREATE/ALTER/DROP 等 |
| **default（SELECT/INSERT 等）** | **`hive.cbo.enabled=true` → `CalcitePlanner`** | **标准 DML 走这里** |
| | **`hive.cbo.enabled=false` → `SemanticAnalyzer`** | 原生分析器 |

- **继承关系**: `CalcitePlanner` → `SemanticAnalyzer` → `BaseSemanticAnalyzer`

### 5.3 BaseSemanticAnalyzer.analyze() — 模板方法

- **源码位置**: `ql/.../parse/BaseSemanticAnalyzer.java:355`
  ```java
  public void analyze(ASTNode ast, Context ctx) throws SemanticException {
      initCtx(ctx);           // 初始化上下文
      init(true);             // 清空 rootTasks
      analyzeInternal(ast);   // ★ 子类实现
  }
  ```

### 5.4 CalcitePlanner.analyzeInternal() — CBO 优化器

- **源码位置**: `ql/.../parse/CalcitePlanner.java:477`
  ```java
  public void analyzeInternal(ASTNode ast) throws SemanticException {
      if (runCBO) {
          super.analyzeInternal(ast, PreCboCtx::new);  // CBO 路径
      } else {
          super.analyzeInternal(ast);  // 非 CBO 降级
      }
  }
  ```
- **CBO 核心方法 `genLogicalPlan()`** (CalcitePlanner.java:493):
  ```java
  processPositionAlias(ast);         // 处理 ORDER BY 1, 2 这种位置别名
  genResolvedParseTree(ast, cboCtx); // 解析表/列/分区引用 → 调 HMS getTable()
  canCBOHandleAst(queryForCbo, ...); // 检查 CBO 是否能处理
  RelNode resPlan = logicalPlan();   // ★ 生成 Calcite 逻辑计划并优化
  ```

**故障点 F7**: 语义分析阶段
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| `SemanticException: Table not found` | 在 analyze 阶段 | 表名拼错 / 没权限 / HMS 返回异常 |
| `SemanticException: Invalid column reference` | 在 analyze 阶段 | 列名不存在 |
| CBO 降级 | `Plan not optimized by CBO because...` | CBO 无法处理该 SQL，降级到原生 SemanticAnalyzer |

### 5.5 Hive.getTable() — 与 MetaStore 的 RPC 交互

- **源码位置**: `ql/.../metadata/Hive.java:1773`（9 个重载，最终走到 6 参数版本）
- **核心逻辑**:
  ```java
  GetTableRequest request = new GetTableRequest(dbName, tableName);
  request.setCatName(getDefaultCatalog(conf));
  request.setGetColumnStats(getColumnStats);
  request.setEngine(Constants.HIVE_ENGINE);
  if (checkTransactional) {
      // ACID 表: 获取当前事务的 ValidWriteIdList → 快照隔离
      long txnId = SessionState.get().getTxnMgr().getCurrentTxnId();
      validWriteIdList = AcidUtils.getTableValidWriteIdListWithTxnList(...);
      request.setValidWriteIdList(validWriteIdList.toString());
  }
  tTable = getMSC().getTable(request);  // ★ Thrift RPC 到 MetaStore
  ```
- **异常处理**:
  - `NoSuchObjectException` → `InvalidTableException`（throwException=true）或 return null
  - `Exception` → `HiveException("Unable to fetch table xxx")`
- **后处理**: 修复不可打印字符 + 将过时 `MetadataTypedColumnsetSerDe` 替换为 `LazySimpleSerDe`

**故障点 F8**: MetaStore RPC
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| `MetaException: TTransportException` | HMS 连接超时 | HMS 进程挂了 / 网络不通 |
| `HiveException: Unable to fetch table` | getMSC().getTable 异常 | HMS 后端 DB (MySQL/PG) 连接池耗尽 |
| 查询很慢但不报错 | HMS RPC 延迟高 | HMS 表/分区数过多，JDOQL 查询慢 |

### 5.6 Driver.runInternal() — 执行总控

- **源码位置**: `ql/.../Driver.java:152`
- **核心流程**:
  ```java
  setInitialStateForRun(alreadyCompiled);  // 设置 DriverState
  runPreDriverHooks(hookContext);           // 前置 Hook
  if (!alreadyCompiled) compileInternal(command, true);

  lockAndRespond();                         // ★ 获取表/分区锁
  validateCurrentSnapshot();                // ★ 验证事务快照（可能触发重编译）

  execute();                                // ★ 执行任务树
  // Executor executor = new Executor(context, driverContext, driverState, taskQueue);
  // executor.execute();

  fetchTask.execute();                      // 准备结果获取
  driverTxnHandler.handleTransactionAfterExecution();  // 事务提交
  runPostDriverHooks(hookContext);           // 后置 Hook
  ```

**故障点 F9**: 锁获取
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| 查询长时间 WAITING | `SHOW LOCKS` 可见 | 另一个写操作持有排他锁 |
| `LockException` | 获取锁超时 | 死锁 / Compaction 持有锁 |

**故障点 F10**: 快照失效重编译
| 现象 | 日志 | 根因 |
|------|------|------|
| `Re-compiling after acquiring locks, attempt #N` | Driver.java:239 | 编译后到获取锁之间，另一个事务修改了数据 |
| `Snapshot is outdated, re-initiating transaction` | Driver.java:248 | 需要回滚当前事务，重新开启 |

### 5.7 TezTask.execute() — Tez DAG 执行

- **源码位置**: `ql/.../exec/tez/TezTask.java:156`
- **核心流程** (7 步):
  ```java
  // 1. 获取 Tez Session（从 WorkloadManager 连接池）
  session = WorkloadManagerFederation.getSession(session, conf, mi, llapMode, wmContext);

  // 2. 确保 Session 有资源
  ensureSessionHasResources(session, allNonConfFiles);

  // 3. 构建 Tez DAG
  DAG dag = build(jobConf, work, scratchDir, ctx, allResources);

  // 4. 提交 DAG
  DAGClient dagClient = submit(dag, sessionRef);
  LOG.info("Query ID: [{}], Dag ID: [{}], App ID: [{}]");  // ← 【日志点④】

  // 5. 监控执行（阻塞）
  monitor = new TezJobMonitor(session, work.getAllWork(), dagClient, ...);
  rc = monitor.monitorExecution();  // 返回 0 = 成功

  // 6. 获取计数器
  DAGStatus dagStatus = dagClient.getDAGStatus(GET_COUNTERS);

  // 7. 收集提交信息（如 Iceberg commit）
  if (rc == 0) collectCommitInformation(work);
  ```
- **finally**: `sessionRef.value.returnToSessionManager()` → 归还 Session 到池

**故障点 F11**: Tez 执行
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| Tez Session 获取慢 | `TEZ_GET_SESSION` perflog 时间长 | YARN 资源不足 / AM 启动慢 |
| DAG 提交失败 | `Failed to execute tez graph` | AM 崩溃 / 资源不足 |
| Task 失败 | Tez UI 查看 | OOM / 数据倾斜 / UDF 异常 |
| `Operation cancelled` | `this.isShutdown = true` | 查询被用户取消 |

### 5.8 Driver.getResults() — 结果返回

- **源码位置**: `ql/.../Driver.java:661`
- **两条路径**:
  ```java
  if (isFetchingTable()) {
      // 路径 1: SELECT 查询 → FetchTask 拉取
      fetchTask.setMaxRows(maxRows);
      return fetchTask.fetch(results);
  }
  // 路径 2: DDL 结果 → ResStream 流式读取
  streamStatus = Utilities.readColumn(resStream, bos);
  ```

---

## 6. 故障点地图（全链路）

```
Beeline → ThriftCLIService → CLIService → HiveSessionImpl → SQLOperation → Driver → Compiler → Tez → Results
   F1          F2                              F3        F4      F5-F8     F9-F10    F11

F1  [Thrift层]     连接被拒绝/超时 → 检查 HS2 进程和端口
F2  [Session层]    Session 锁阻塞 → 同一 session 串行执行
F3  [线程池]       线程池拒绝 → hive.server2.async.exec.threads 不够
F4  [编译锁]       编译锁超时 → hive.server2.compile.lock.timeout
F5  [解析层]       SQL 语法错误 → ParseException
F6  [HMS缓存]      缓存刷新失败 → HMS 连接断开
F7  [语义分析]     表/列不存在 / CBO 降级
F8  [HMS RPC]      MetaStore 超时 → HMS 进程/后端 DB 问题
F9  [锁获取]       锁等待 → 写操作冲突 / Compaction
F10 [快照验证]     快照失效重编译 → 并发事务修改
F11 [Tez执行]      Session 获取慢 / DAG 失败 / Task OOM
```

---

## 7. 关键日志点速查

排障时按顺序搜索这些日志，快速定位卡在哪一步：

| 序号 | 日志关键字 | 位置 | 含义 |
|------|-----------|------|------|
| ① | `executing <SQL>` | HiveSessionImpl.java:549 | Session 收到请求 |
| ② | `Compiling command(queryId=xxx)` | Compiler.java:159 | 开始编译 |
| ③ | `Semantic Analysis Completed` | Compiler.java:234 | 语义分析完成 |
| ④ | `Query ID: [xxx], Dag ID: [xxx]` | TezTask.java:271 | DAG 已提交到 Tez |
| ⑤ | `Compile lock timed out` | Driver.java:445 | 编译锁超时（卡在编译锁） |
| ⑥ | `Re-compiling after acquiring locks` | Driver.java:239 | 快照失效触发重编译 |

**排障决策树**:
```
查询卡住/慢 →
  ├─ 看到 ① 没看到 ② → 卡在编译锁 → 检查 F4
  ├─ 看到 ② 没看到 ③ → 卡在语义分析 → 检查 F7/F8 (HMS)
  ├─ 看到 ③ 没看到 ④ → 卡在锁获取/快照验证 → 检查 F9/F10
  ├─ 看到 ④ 但未完成 → 卡在 Tez 执行 → 检查 F11 (YARN/数据倾斜/OOM)
  └─ 全看到但结果慢 → FetchTask 拉取慢 → 检查数据量/序列化
```
