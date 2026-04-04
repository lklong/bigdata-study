# S01: 一条 SQL 从提交到返回结果的完整链路 — Part 1

## 1. 场景描述

> 用户通过 Beeline 执行 `SELECT * FROM db.t WHERE dt='2026-04-01'`，从提交到拿到结果，代码经过了哪些类、哪些方法、哪些线程？每一步可能出什么问题？

---

## 2. 完整请求链路图

```
Beeline (JDBC/Thrift Client)
  │
  ▼ [Thrift RPC: ExecuteStatement]
┌─────────────────────────────────────────────────────────────┐
│ ThriftCLIService.ExecuteStatement()                         │ ← service/.../thrift/ThriftCLIService.java:641
│   提取: sessionHandle, statement, confOverlay, runAsync     │
│   根据 runAsync 选择同步/异步                                │
│     ▼                                                       │
│ CLIService.executeStatement()                               │ ← service/.../cli/CLIService.java:260
│   sessionManager.getSession(sessionHandle) → HiveSession    │
│   session.getSessionState().updateProgressMonitor(null)     │
│     ▼                                                       │
│ HiveSessionImpl.executeStatementInternal()                  │ ← service/.../session/HiveSessionImpl.java:546
│   acquire(true, true)  ← 获取 Session 级锁                  │
│   LOG.info("executing " + statement)  ← 【日志点①】         │
│     ▼                                                       │
│ OperationManager.newExecuteStatementOperation()             │ ← service/.../operation/OperationManager.java:107
│     ▼                                                       │
│ ExecuteStatementOperation.newExecuteStatementOperation()    │ ← service/.../operation/ExecuteStatementOperation.java:58
│   ├─ HiveStringUtils.removeComments(statement) ← 去注释     │
│   ├─ 检查是否 HPL/SQL 模式 → HplSqlOperation               │
│   ├─ CommandProcessorFactory.getForHiveCommand() ← 是否内置命令│
│   │    SET/ADD JAR/DFS → HiveCommandOperation               │
│   │    SHOW PROCESSLIST → ShowProcessListOperation          │
│   └─ 标准 SQL → new SQLOperation(...)  ← 【进入核心路径】   │
│     ▼                                                       │
│ operation.run() → SQLOperation.runInternal()                │ ← service/.../operation/SQLOperation.java:260
│   setState(PENDING)                                         │
│   asyncPrepare? = HIVE_SERVER2_ASYNC_EXEC_ASYNC_COMPILE     │
│   ┌──同步模式──────────┐  ┌──异步模式─────────────────┐     │
│   │ prepare(queryState)│  │ BackgroundWork → 线程池提交 │     │
│   │ runQuery()         │  │   prepare() + runQuery()  │     │
│   └────────────────────┘  └───────────────────────────┘     │
│     ▼                                                       │
│ SQLOperation.prepare()                                      │ ← SQLOperation.java:169
│   driver = DriverFactory.newDriver(queryState, queryInfo)   │
│   ┌─ 超时控制: timeoutExecutor.schedule(cancel, timeout)    │
│   │  queryTimeout 取 min(HIVE_QUERY_TIMEOUT_SECONDS, req)   │
│   ▼                                                         │
│ driver.compileAndRespond(statement)  ← 【编译入口】          │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ Driver.compileAndRespond()                                  │ ← ql/.../Driver.java:408
│   ▼                                                         │
│ Driver.compileInternal()                                    │ ← Driver.java:428
│   metrics.incrementCounter(WAITING_COMPILE_OPS)             │
│   CompileLock compileLock = CompileLockFactory.newInstance() │
│   compileLock.tryAcquire() ← 【编译锁】超时则报 COMPILE_LOCK_TIMED_OUT│
│   ▼                                                         │
│ Driver.compile()                                            │ ← Driver.java:495
│   prepareForCompile(resetTaskIds)                           │
│   │  ├─ driverTxnHandler.createTxnManager() ← 创建事务管理器│
│   │  ├─ prepareContext() ← 创建/重置 Context               │
│   │  └─ setQueryId() ← 设置 QueryId                         │
│   ▼                                                         │
│ Compiler compiler = new Compiler(context, driverContext, ..) │
│ QueryPlan plan = compiler.compile(command, deferClose)       │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ Compiler.compile()                                          │ ← ql/.../Compiler.java:98
│                                                             │
│ Step 1: initialize(rawCommand)                              │ ← Compiler.java:139
│   ├─ VariableSubstitution.substitute() ← ${hivevar:xxx} 替换│
│   ├─ HookUtils.redactLogString() ← 日志脱敏                 │
│   └─ LOG.info("Compiling command(queryId=..): ...") ← 【日志点②】│
│                                                             │
│ Step 2: parse()                                             │ ← Compiler.java:169
│   ├─ hookRunner.runBeforeParseHook()                        │
│   ├─ ParseUtils.parse(cmd, ctx)                             │
│   │    └─ ParseDriver.parse(command, configuration)         │ ← parser/.../ParseDriver.java:112
│   │         ├─ GenericHiveLexer.of(command, config) ← 词法分析│
│   │         ├─ TokenRewriteStream tokens                    │
│   │         ├─ HiveParser parser(tokens) ← ANTLR 语法解析   │
│   │         ├─ parser.statement() ← 【解析入口】             │
│   │         ├─ 错误检查: lexer.getErrors() / parser.errors   │
│   │         └─ return ParseResult(ASTNode tree, tokens, tables)│
│   └─ hookRunner.runAfterParseHook()                         │
│                                                             │
│ Step 3: analyze()                                           │ ← Compiler.java:185
│   (详见 Part 2)                                              │
│                                                             │
│ Step 4: createPlan(sem) → QueryPlan                         │
│ Step 5: openTxnAndGetValidTxnList() ← 如需事务              │
│ Step 6: initializeFetchTask(plan)                           │
│ Step 7: authorize(sem) ← Ranger 权限检查                    │
│ Step 8: explainOutput(sem, plan) ← EXPLAIN 处理             │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 逐节点源码分析（Thrift → 编译）

### 3.1 ThriftCLIService.ExecuteStatement()

- **源码位置**: `service/src/java/org/apache/hive/service/cli/thrift/ThriftCLIService.java:641`
- **入参**: `TExecuteStatementReq req`（含 sessionHandle, statement, confOverlay, runAsync, queryTimeout）
- **核心逻辑**:
  ```java
  OperationHandle operationHandle =
      runAsync ? cliService.executeStatementAsync(...)
               : cliService.executeStatement(...);
  ```
- **出参**: `TExecuteStatementResp`（含 operationHandle + WebUI drilldown URL）
- **异常处理**: catch `Exception`（注意：不 catch `Error`，允许 OOM 传播）
  - 日志: `LOG.error("Failed to execute statement [request: {}]", req, e)`
- **并发控制**: 无（每个 Thrift 请求独立线程）

**故障点 F1**: Thrift 连接层
| 现象 | 日志 | 根因 |
|------|------|------|
| Beeline 连接被拒绝 | 无（客户端报错） | HS2 进程挂了或端口 `hive.server2.thrift.port`(默认10000) 被占 |
| 连接超时 | 无 | 防火墙/HS2 Thrift 线程池满 |

### 3.2 HiveSessionImpl.executeStatementInternal()

- **源码位置**: `service/.../session/HiveSessionImpl.java:546`
- **核心逻辑**:
  ```java
  acquire(true, true);  // Session 级锁，保证会话内串行
  operation = getOperationManager().newExecuteStatementOperation(...);
  opHandle = operation.getHandle();
  addOpHandle(opHandle);
  operation.run();  // ★ 触发编译 + 执行
  ```
- **异常处理**: catch `HiveSQLException` → 清理 opHandle
- **finally**: 
  - 同步模式: `release(true, true)` 直接释放锁
  - 异步模式: `releaseBeforeOpLock(true)` 仅释放 session 锁，保留 operation 锁

**故障点 F2**: Session 锁
| 现象 | 日志 | 根因 |
|------|------|------|
| 同一 session 第二个查询卡住 | 无明显日志 | 第一个查询未完成，`acquire()` 阻塞 |

### 3.3 ExecuteStatementOperation 工厂路由

- **源码位置**: `service/.../operation/ExecuteStatementOperation.java:58`
- **路由决策**:
  1. `HiveStringUtils.removeComments(statement)` → 去掉 SQL 注释
  2. 检查 HPL/SQL 模式 → `HplSqlOperation`
  3. `CommandProcessorFactory.getForHiveCommand(tokens, conf)` → 内置命令？
     - `SET/ADD JAR/DFS/RESET` → `HiveCommandOperation`
     - `SHOW PROCESSLIST` → `ShowProcessListOperation`
  4. **processor == null → `new SQLOperation(...)` ← 标准 SQL 走这里**

### 3.4 SQLOperation.runInternal() — 调度中枢

- **源码位置**: `service/.../operation/SQLOperation.java:260`
- **核心逻辑**:
  ```java
  setState(PENDING);
  boolean asyncPrepare = doRunAsync 
      && HiveConf.getBoolVar(conf, HIVE_SERVER2_ASYNC_EXEC_ASYNC_COMPILE);
  
  if (!asyncPrepare) prepare(queryState);  // 同步编译
  if (!doRunAsync) {
      runQuery();  // 同步执行
  } else {
      // 异步: 提交到后台线程池
      Future<?> backgroundHandle = getParentSession().submitBackgroundOperation(work);
  }
  ```
- **线程模型**:
  - 同步: Thrift 工作线程直接编译+执行
  - 异步: BackgroundWork Runnable 提交到 SessionManager 线程池

**故障点 F3**: 线程池拒绝
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| `The background threadpool cannot accept new task` | `RejectedExecutionException` | 后台线程池满，参数 `hive.server2.async.exec.threads`(默认100) |

### 3.5 SQLOperation.prepare() — 编译入口

- **源码位置**: `SQLOperation.java:169`
- **核心逻辑**:
  1. `DriverFactory.newDriver(queryState, queryInfo)` → 创建 Driver
  2. 如果 `queryTimeout > 0`，启动超时取消线程
  3. **`driver.compileAndRespond(statement)` ← 核心调用**
- **超时控制**:
  ```java
  // 取 min(配置值, 请求值)
  long timeout = HiveConf.getTimeVar(conf, HIVE_QUERY_TIMEOUT_SECONDS);
  if (timeout > 0 && (queryTimeout <= 0 || timeout < queryTimeout)) {
      this.queryTimeout = timeout;
  }
  ```
- **异常处理**:
  - `CommandProcessorException` → `setState(ERROR)` → 包装为 `HiveSQLException`
  - `Throwable` → 若 `OutOfMemoryError` **直接重抛不包装**

### 3.6 Driver.compileInternal() — 编译锁

- **源码位置**: `ql/.../Driver.java:428`
- **核心逻辑**:
  ```java
  try (CompileLock compileLock = CompileLockFactory.newInstance(conf, command)) {
      boolean success = compileLock.tryAcquire();
      if (!success) throw COMPILE_LOCK_TIMED_OUT;
      compile(command, true, deferClose);
  }
  ```

**故障点 F4**: 编译锁超时
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| `Compile lock timed out` | ErrorMsg.COMPILE_LOCK_TIMED_OUT | 另一个查询正在编译，锁等待超时。参数 `hive.server2.compile.lock.timeout` |

### 3.7 Compiler.compile() — 编译总控

- **源码位置**: `ql/.../Compiler.java:98`
- **核心流程** (7 步):
  ```
  initialize()  → 变量替换 + 日志脱敏
  parse()       → 词法/语法分析 → ASTNode
  analyze()     → 语义分析 → 执行计划 (详见 Part 2)
  createPlan()  → QueryPlan
  openTxn()     → 如需事务
  initializeFetchTask() → 准备结果获取
  authorize()   → Ranger 权限检查
  ```
- **日志点②**: `LOG.info("Compiling command(queryId=xxx): SQL文本")` ← **排障时最关键的日志**

### 3.8 ParseDriver.parse() — 词法/语法分析

- **源码位置**: `parser/.../ParseDriver.java:112`
- **核心逻辑**:
  ```java
  GenericHiveLexer lexer = GenericHiveLexer.of(command, configuration);  // 词法
  TokenRewriteStream tokens = new TokenRewriteStream(lexer);
  HiveParser parser = new HiveParser(tokens);  // ANTLR 语法解析器
  parser.setTreeAdaptor(adaptor);  // 自定义 TreeAdaptor → 生成 ASTNode
  r = parser.statement();  // ★ 解析整个 SQL
  ```
- **ANTLR 语法文件**: `parser/src/main/antlr3/org/apache/hadoop/hive/ql/parse/HiveParser.g`（86KB）
- **自定义 TreeAdaptor**: 将 ANTLR `CommonTree` 转为 Hive 的 `ASTNode`

**故障点 F5**: SQL 语法错误
| 现象 | 日志/报错 | 根因 |
|------|----------|------|
| `ParseException: cannot recognize input near...` | `parser.errors` 非空 | SQL 语法不符合 HiveParser.g 定义 |
| 词法错误 | `lexer.getErrors()` 非空 | 非法字符、未闭合引号等 |

---

## 4. 设计模式标注

| 模式 | 位置 | 说明 |
|------|------|------|
| **工厂方法** | `ExecuteStatementOperation.newExecuteStatementOperation()` | 根据 SQL 类型路由到不同 Operation |
| **模板方法** | `BaseSemanticAnalyzer.analyze()` → `analyzeInternal()` | 父类定义流程，子类实现核心逻辑 |
| **策略模式** | `SemanticAnalyzerFactory` | CBO开启→CalcitePlanner / 关闭→SemanticAnalyzer |
| **代理模式** | `RetryingHMSHandler` | JDK Proxy 包装 HMSHandler，JDO 异常自动重试 |
| **Builder** | `QueryState.Builder` | 查询状态构建，支持配置隔离、queryId 生成 |

> Part 2 → 语义分析到 Tez 执行 + 结果返回 + 故障点地图
