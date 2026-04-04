# S07: Hive SQL Parser — 词法语法解析到 AST 源码深度分析

> **创建时间**: 2026-04-04
> **分析版本**: Apache Hive 3.x / 4.x
> **标签**: #Hive #Parser #ANTLR #AST #编译原理 #源码分析

---

## 一、全局定位：Parser 在编译链路中的位置

```
SQL 文本
  ↓
┌──────────────────────────────────────────────────────┐
│ Phase 1: Parser（词法 + 语法分析）← 本文聚焦          │
│   SQL String → Token Stream → AST (ASTNode)          │
└──────────────────────────────────────────────────────┘
  ↓
Phase 2: SemanticAnalyzer（语义分析）
  AST → QB (QueryBlock) → Operator Tree
  ↓
Phase 3: Optimizer（逻辑优化 + CBO）
  Operator Tree → 优化后的 Operator Tree
  ↓
Phase 4: TaskCompiler（物理计划生成）
  Operator Tree → Task Tree (MapRedTask / TezTask)
  ↓
Phase 5: PhysicalOptimizer（物理优化）
  Task Tree → 优化后的 Task Tree
  ↓
Phase 6: Execution
  提交到 YARN 执行
```

---

## 二、ANTLR 语法文件体系

### 2.1 文件清单与职责

Hive 使用 **ANTLR v3** 定义词法和语法规则，源文件位于 `ql/src/java/org/apache/hadoop/hive/ql/parse/`：

| 文件 | 类型 | 职责 |
|------|------|------|
| **HiveLexer.g** | Lexer | 词法分析：定义所有 Token（关键字、运算符、字面量、标识符） |
| **HiveParser.g** | Parser (主文件) | 语法分析：定义 SQL 整体语法结构（DDL/DML/Query） |
| **SelectClauseParser.g** | Parser (子文件) | SELECT 子句的语法规则 |
| **FromClauseParser.g** | Parser (子文件) | FROM 子句的语法规则（包括 JOIN、子查询、LATERAL VIEW） |
| **IdentifiersParser.g** | Parser (子文件) | 标识符、UDF 函数调用、表达式的语法规则 |
| **ResourcePlanParser.g** | Parser (子文件) | WM（Workload Management）资源计划语法 |

### 2.2 文件依赖关系

```
HiveParser.g (主语法文件)
  ├── import SelectClauseParser.g
  ├── import FromClauseParser.g
  ├── import IdentifiersParser.g
  └── import ResourcePlanParser.g

HiveLexer.g (独立的词法文件)
```

**设计原因**: ANTLR 生成的 Java 文件大小与语法规则量成正比。Hive 的语法极其庞大，如果全部塞入一个 `.g` 文件，生成的 Java 类会超过 JVM 方法大小限制。使用 `import` 拆分后：
- 各模块独立维护
- 生成的 Java 代码分散到多个文件
- 编译和加载更高效

### 2.3 ANTLR v3 工作原理

```
SQL 字符串
  ↓ HiveLexer (词法分析)
Token 流 (KW_SELECT, TOK_TABLE_OR_COL, COMMA, ...)
  ↓ HiveParser (语法分析)
AST Tree (ASTNode 树结构)
```

**词法分析示例**:
```sql
SELECT a.id, b.name FROM t1 a JOIN t2 b ON a.id = b.id WHERE a.age > 18
```

词法分析后的 Token 流:
```
KW_SELECT → Identifier("a") → DOT → Identifier("id") → COMMA →
Identifier("b") → DOT → Identifier("name") → KW_FROM →
Identifier("t1") → Identifier("a") → KW_JOIN → Identifier("t2") →
Identifier("b") → KW_ON → Identifier("a") → DOT → Identifier("id") →
EQUAL → Identifier("b") → DOT → Identifier("id") → KW_WHERE →
Identifier("a") → DOT → Identifier("age") → GREATERTHAN → Number(18)
```

---

## 三、核心源码类

### 3.1 ParseDriver — 解析入口

**文件**: `ql/src/java/org/apache/hadoop/hive/ql/parse/ParseDriver.java`

```java
public class ParseDriver {
    
    /**
     * 核心方法：将 SQL 字符串解析为 ASTNode
     */
    public ASTNode parse(String command) throws ParseException {
        return parse(command, null);
    }
    
    public ASTNode parse(String command, Context ctx) throws ParseException {
        
        // ★ Step 1: 词法分析 — 创建 HiveLexer
        HiveLexerX lexer = new HiveLexerX(
            new ANTLRNoCaseStringStream(command));
        // ANTLRNoCaseStringStream: 忽略大小写的字符流
        // → SQL 关键字不区分大小写
        
        // ★ Step 2: Token 流
        TokenRewriteStream tokens = new TokenRewriteStream(lexer);
        
        // ★ Step 3: 语法分析 — 创建 HiveParser
        HiveParser parser = new HiveParser(tokens);
        parser.setTreeAdaptor(adaptor);  // 设置树适配器（生成 ASTNode）
        
        // ★ Step 4: 执行解析 — 调用 ANTLR 生成的 statement() 规则
        HiveParser.statement_return r = parser.statement();
        
        // ★ Step 5: 获取 AST 根节点
        ASTNode tree = (ASTNode) r.getTree();
        
        // Step 6: 后处理
        tree.setUnknownTokenBoundaries();
        
        return tree;
    }
}
```

### 3.2 ANTLRNoCaseStringStream — 大小写无关

```java
public class ANTLRNoCaseStringStream extends ANTLRStringStream {
    
    @Override
    public int LA(int i) {
        int returnChar = super.LA(i);
        if (returnChar == CharStream.EOF) {
            return returnChar;
        }
        // ★ 关键：所有字符转大写
        // 使得 SELECT/select/Select 都匹配同一个 Token
        return Character.toUpperCase((char) returnChar);
    }
}
```

### 3.3 ASTNode — 抽象语法树节点

```java
public class ASTNode extends CommonTree implements Node, Serializable {
    
    private transient ASTNodeOrigin origin;  // 节点来源信息
    
    // 继承自 CommonTree 的核心属性:
    // - token: Token 类型和文本
    // - parent: 父节点
    // - children: 子节点列表
    // - childIndex: 在父节点中的索引
    // - startIndex / stopIndex: 在 Token 流中的位置
    
    /**
     * 获取节点文本（如表名、列名等）
     */
    public String getText() {
        return token.getText();
    }
    
    /**
     * 获取节点 Token 类型（对应 HiveParser 中的常量）
     */
    public int getType() {
        return token.getType();
    }
    
    /**
     * 打印树结构（调试用）
     */
    public String dump() {
        StringBuilder sb = new StringBuilder();
        dump(sb, "");
        return sb.toString();
    }
}
```

### 3.4 HiveParser 中的关键 Token 常量

```java
// HiveParser.g 中定义的 Token（部分示例）
public class HiveParser extends Parser {
    // 语句类型
    public static final int TOK_QUERY = ...;           // 查询语句
    public static final int TOK_INSERT = ...;          // INSERT
    public static final int TOK_CREATETABLE = ...;     // CREATE TABLE
    
    // 子句
    public static final int TOK_SELECT = ...;          // SELECT 子句
    public static final int TOK_SELECTDI = ...;        // SELECT DISTINCT
    public static final int TOK_FROM = ...;            // FROM 子句
    public static final int TOK_WHERE = ...;           // WHERE 子句
    public static final int TOK_GROUPBY = ...;         // GROUP BY
    public static final int TOK_ORDERBY = ...;         // ORDER BY
    public static final int TOK_HAVING = ...;          // HAVING
    public static final int TOK_LIMIT = ...;           // LIMIT
    
    // 表达式
    public static final int TOK_TABLE_OR_COL = ...;    // 表名或列名引用
    public static final int TOK_TABREF = ...;          // 表引用
    public static final int TOK_SUBQUERY = ...;        // 子查询
    public static final int TOK_JOIN = ...;            // INNER JOIN
    public static final int TOK_LEFTOUTERJOIN = ...;   // LEFT OUTER JOIN
    public static final int TOK_RIGHTOUTERJOIN = ...;  // RIGHT OUTER JOIN
    public static final int TOK_FULLOUTERJOIN = ...;   // FULL OUTER JOIN
    
    // 函数
    public static final int TOK_FUNCTION = ...;        // 函数调用
    public static final int TOK_FUNCTIONDI = ...;      // DISTINCT 函数
    public static final int TOK_FUNCTIONSTAR = ...;    // COUNT(*)
}
```

---

## 四、AST 结构示例

### 4.1 简单查询

```sql
SELECT id, name FROM users WHERE age > 18
```

生成的 AST:
```
TOK_QUERY
├── TOK_FROM
│   └── TOK_TABREF
│       └── TOK_TABNAME
│           └── "users"
├── TOK_INSERT
│   ├── TOK_DESTINATION
│   │   └── TOK_DIR
│   │       └── TOK_TMP_FILE
│   ├── TOK_SELECT
│   │   ├── TOK_SELEXPR
│   │   │   └── TOK_TABLE_OR_COL
│   │   │       └── "id"
│   │   └── TOK_SELEXPR
│   │       └── TOK_TABLE_OR_COL
│   │           └── "name"
│   └── TOK_WHERE
│       └── > (GREATERTHAN)
│           ├── TOK_TABLE_OR_COL
│           │   └── "age"
│           └── 18
```

### 4.2 JOIN 查询

```sql
SELECT a.id, b.name
FROM t1 a JOIN t2 b ON a.id = b.id
WHERE a.age > 18
```

生成的 AST:
```
TOK_QUERY
├── TOK_FROM
│   └── TOK_JOIN
│       ├── TOK_TABREF
│       │   ├── TOK_TABNAME("t1")
│       │   └── "a" (alias)
│       ├── TOK_TABREF
│       │   ├── TOK_TABNAME("t2")
│       │   └── "b" (alias)
│       └── = (EQUAL)  ← ON 条件
│           ├── . (DOT)
│           │   ├── TOK_TABLE_OR_COL("a")
│           │   └── "id"
│           └── . (DOT)
│               ├── TOK_TABLE_OR_COL("b")
│               └── "id"
├── TOK_INSERT
│   ├── TOK_DESTINATION(...)
│   ├── TOK_SELECT
│   │   ├── TOK_SELEXPR(a.id)
│   │   └── TOK_SELEXPR(b.name)
│   └── TOK_WHERE
│       └── > (a.age > 18)
```

---

## 五、从 Driver 到 Parser 的调用链

```java
// 完整调用链
Driver.run(String command)
  → Driver.runInternal(String command)
    → Driver.compileInternal(String command, boolean deferClose)
      → Driver.compile(String command, boolean resetTaskIds, boolean deferClose)
        → ParseUtils.parse(command, ctx)          // Hive 4.x
        // 或
        → ParseDriver.parse(command, ctx)          // Hive 3.x
          → new HiveLexerX(new ANTLRNoCaseStringStream(command))
          → new TokenRewriteStream(lexer)
          → new HiveParser(tokens)
          → parser.statement()                    // ANTLR 生成的解析入口
          → return (ASTNode) r.getTree()
```

### Driver.compile() 中的 Parser 调用位置

```java
// Driver.java (简化)
public int compile(String command, boolean resetTaskIds, boolean deferClose) {
    
    PerfLogger perfLogger = SessionState.getPerfLogger();
    perfLogger.PerfLogBegin(CLASS_NAME, PerfLogger.COMPILE);
    
    // ★★★ Step 1: 词法 + 语法分析 → AST ★★★
    perfLogger.PerfLogBegin(CLASS_NAME, PerfLogger.PARSE);
    ASTNode tree;
    try {
        tree = ParseUtils.parse(command, ctx);
    } catch (ParseException e) {
        // 语法错误 → 直接返回错误给用户
        errorMessage = "FAILED: ParseException " + e.getMessage();
        return ErrorMsg.PARSE_ERROR.getErrorCode();
    }
    perfLogger.PerfLogEnd(CLASS_NAME, PerfLogger.PARSE);
    
    // Step 2: 语义分析（→ S08 文档）
    perfLogger.PerfLogBegin(CLASS_NAME, PerfLogger.ANALYZE);
    BaseSemanticAnalyzer sem = SemanticAnalyzerFactory.get(queryState, tree);
    sem.analyze(tree, ctx);
    perfLogger.PerfLogEnd(CLASS_NAME, PerfLogger.ANALYZE);
    
    // Step 3: 后续编译步骤...
}
```

---

## 六、HiveParser.g 语法规则精选

### 6.1 statement — 顶层入口

```antlr
// HiveParser.g
statement
    : explainStatement EOF
    | execStatement EOF
    ;

execStatement
    : queryStatementExpression
    | loadStatement
    | exportStatement
    | importStatement
    | ddlStatement
    | deleteStatement
    | updateStatement
    | mergeStatement
    ;
```

### 6.2 queryStatementExpression — 查询语句

```antlr
queryStatementExpression
    : queryStatementExpressionBody
        -> ^(TOK_QUERY queryStatementExpressionBody)
    ;

queryStatementExpressionBody
    : fromClause                    // FROM 子句（Hive 支持 FROM 写在前面）
      (insertClause)+              // INSERT INTO ... SELECT ...
    | regular_body                  // 标准 SELECT ... FROM ...
    ;

regular_body
    : insertClause
      selectStatement               // SELECT 部分
    ;
```

### 6.3 selectClause — SELECT 子句

```antlr
// SelectClauseParser.g
selectClause
    : KW_SELECT QUERY_HINT? (KW_ALL | dist=KW_DISTINCT)?
      selectList
      -> {$dist == null}? ^(TOK_SELECT QUERY_HINT? selectList)
      -> ^(TOK_SELECTDI QUERY_HINT? selectList)
    ;

selectList
    : selectItem (COMMA selectItem)*
      -> selectItem+
    ;

selectItem
    : ( selectExpression (KW_AS? Identifier | KW_AS LPAREN Identifier (COMMA Identifier)* RPAREN)? )
      -> ^(TOK_SELEXPR selectExpression Identifier*)
    ;
```

### 6.4 fromClause — FROM 子句（含 JOIN）

```antlr
// FromClauseParser.g
fromClause
    : KW_FROM fromSource
      -> ^(TOK_FROM fromSource)
    ;

joinSource
    : fromSource
      ( joinToken joinSourcePart (KW_ON expression)? )+
    ;

joinToken
    : KW_JOIN                               -> TOK_JOIN
    | KW_INNER KW_JOIN                      -> TOK_JOIN
    | KW_LEFT KW_OUTER? KW_JOIN             -> TOK_LEFTOUTERJOIN
    | KW_RIGHT KW_OUTER? KW_JOIN            -> TOK_RIGHTOUTERJOIN
    | KW_FULL KW_OUTER? KW_JOIN             -> TOK_FULLOUTERJOIN
    | KW_CROSS KW_JOIN                      -> TOK_CROSSJOIN
    | KW_LEFT KW_SEMI KW_JOIN               -> TOK_LEFTSEMIJOIN
    ;
```

---

## 七、词法规则精选（HiveLexer.g）

```antlr
// HiveLexer.g

// 关键字定义
KW_SELECT    : 'SELECT';
KW_FROM      : 'FROM';
KW_WHERE     : 'WHERE';
KW_JOIN      : 'JOIN';
KW_ON        : 'ON';
KW_INSERT    : 'INSERT';
KW_INTO      : 'INTO';
KW_CREATE    : 'CREATE';
KW_TABLE     : 'TABLE';
KW_DROP      : 'DROP';
KW_ALTER     : 'ALTER';
KW_GROUP     : 'GROUP';
KW_BY        : 'BY';
KW_ORDER     : 'ORDER';
KW_HAVING    : 'HAVING';
KW_LIMIT     : 'LIMIT';

// 运算符
EQUAL            : '=';
NOTEQUAL         : '<>';
LESSTHAN         : '<';
GREATERTHAN      : '>';
LPAREN           : '(';
RPAREN           : ')';
COMMA            : ',';
DOT              : '.';
STAR             : '*';
SEMICOLON        : ';';

// 标识符（表名、列名等）
Identifier
    : (Letter | Digit) (Letter | Digit | '_')*
    | '`' RegexComponent+ '`'    // 反引号包裹的特殊标识符
    ;

// 字符串字面量
StringLiteral
    : '\'' (~('\'' | '\\') | ('\\' .))* '\''
    | '"' (~('"' | '\\') | ('\\' .))* '"'
    ;

// 数字
Number
    : (Digit)+ ('.' (Digit)*)? (('e' | 'E') ('+' | '-')? (Digit)+)?
    ;
```

---

## 八、错误处理与容错

### 8.1 语法错误处理

```java
// ParseDriver.java
public ASTNode parse(String command, Context ctx) throws ParseException {
    try {
        HiveParser.statement_return r = parser.statement();
        tree = (ASTNode) r.getTree();
    } catch (RecognitionException e) {
        // ANTLR 识别错误 → 包装为 ParseException
        throw new ParseException(parser.errors);
    }
    
    // 检查是否有语法错误
    if (lexer.getErrors().size() > 0) {
        throw new ParseException(lexer.getErrors());
    }
    if (parser.errors.size() > 0) {
        throw new ParseException(parser.errors);
    }
    
    return tree;
}
```

### 8.2 常见解析错误

| 错误类型 | 典型报错 | 原因 |
|----------|----------|------|
| 词法错误 | `cannot recognize input near 'xxx'` | 非法字符、未闭合的字符串 |
| 语法错误 | `missing EOF at 'xxx'` | SQL 语法结构不完整 |
| Token 错误 | `mismatched input 'xxx' expecting yyy` | 关键字位置错误 |
| 保留字冲突 | `cannot recognize input near 'order'` | 使用保留字作为标识符，需用反引号 |

---

## 九、Parser 性能特征

| 特征 | 说明 |
|------|------|
| 时间复杂度 | O(n)，n = SQL 文本长度 |
| 内存占用 | AST 节点数 ≈ Token 数 × 1.5-2 |
| 耗时占比 | 在整个编译过程中占比极小（通常 < 5%） |
| 瓶颈场景 | 极长 SQL（>10万字符）、大量 UNION ALL、深层嵌套子查询 |

---

## 十、排障与源码索引

### 10.1 源码文件索引

| 文件 | 路径 | 职责 |
|------|------|------|
| **ParseDriver** | `ql/.../parse/ParseDriver.java` | 解析入口：SQL → AST |
| **HiveLexer.g** | `ql/.../parse/HiveLexer.g` | 词法规则定义 |
| **HiveParser.g** | `ql/.../parse/HiveParser.g` | 主语法规则定义 |
| **SelectClauseParser.g** | `ql/.../parse/SelectClauseParser.g` | SELECT 子句语法 |
| **FromClauseParser.g** | `ql/.../parse/FromClauseParser.g` | FROM/JOIN 子句语法 |
| **IdentifiersParser.g** | `ql/.../parse/IdentifiersParser.g` | 标识符/函数/表达式语法 |
| **ASTNode** | `ql/.../parse/ASTNode.java` | AST 节点定义 |
| **ParseUtils** | `ql/.../parse/ParseUtils.java` | 解析工具类 |

### 10.2 调试方法

```sql
-- 查看 AST（不执行查询）
EXPLAIN AST SELECT id FROM users WHERE age > 18;
-- Hive 4.x 支持 EXPLAIN AST
```

```java
// 代码级调试
ParseDriver pd = new ParseDriver();
ASTNode tree = pd.parse("SELECT id FROM users WHERE age > 18");
System.out.println(tree.dump());  // 打印 AST 树结构
```
