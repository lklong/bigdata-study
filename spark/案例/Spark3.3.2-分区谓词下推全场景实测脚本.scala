// =====================================================================
// Spark 3.3.2 分区谓词下推全场景实测脚本（v2: 支持 ANSI 模式切换）
//
// 用法（在 EMR master 节点上）:
//   spark-shell --conf spark.sql.hive.metastorePartitionPruningFastFallback=false \
//     -i Spark3.3.2-分区谓词下推全场景实测脚本.scala 2>&1 | tee 下推实测.log
//
// 设计:
//   - 造 4 张测试表: t_str / t_int / t_bigint / t_date, 各 5 个分区
//   - 每个用例独立 reset() metric, 输出 fetched=N 直读
//   - 外层循环 ANSI 模式 (false 默认, true 验证)
//   - TestCase 通过 expectedFetchedAnsi 区分 ANSI 是否影响下推
//
// 对照: 手册 Spark3.3.2-分区谓词下推完全速查手册.md
// =====================================================================

import org.apache.spark.metrics.source.HiveCatalogMetrics
import scala.collection.mutable.ArrayBuffer

val TEST_DB = "default"
val TABLES = Map(
  "t_str"    -> ("STRING",  Seq("'20260601'", "'20260602'", "'20260603'", "'20260604'", "'20260605'")),
  "t_int"    -> ("INT",     Seq("20260601",   "20260602",   "20260603",   "20260604",   "20260605")),
  "t_bigint" -> ("BIGINT",  Seq("20260601",   "20260602",   "20260603",   "20260604",   "20260605")),
  "t_date"   -> ("DATE",    Seq("'2026-06-01'", "'2026-06-02'", "'2026-06-03'", "'2026-06-04'", "'2026-06-05'"))
)
val TOTAL_PARTITIONS = 5

println("\n========== Stage 1: 准备测试表 ==========\n")
TABLES.foreach { case (tbl, (colType, vals)) =>
  spark.sql(s"DROP TABLE IF EXISTS $TEST_DB.$tbl")
  spark.sql(s"CREATE TABLE $TEST_DB.$tbl (id BIGINT) PARTITIONED BY (dt $colType)")
  vals.zipWithIndex.foreach { case (v, idx) =>
    spark.sql(s"INSERT INTO $TEST_DB.$tbl PARTITION (dt=$v) VALUES (${idx + 1})")
  }
  val cnt = spark.sql(s"SELECT count(DISTINCT dt) as c FROM $TEST_DB.$tbl").collect()(0).getLong(0)
  println(s"  $tbl ($colType): $cnt 个分区")
  assert(cnt == TOTAL_PARTITIONS, s"$tbl 实际分区数 $cnt != 期望 $TOTAL_PARTITIONS")
}

// ---------- Test case 数据结构 ----------
case class TestCase(
  table: String,
  colType: String,
  description: String,
  sql: String,
  expectedFetched: Int,                // ansi=false 期望
  expectedFetchedAnsi: Option[Int],    // ansi=true 期望: None = 与 ansi=false 同; Some(n) = 不同
  expectedRows: Int,
  expectedRowsAnsi: Option[Int] = None  // ansi=true 行数期望: None = 与 ansi=false 同
)

case class Result(
  tc: TestCase,
  ansiMode: Boolean,
  expectedFetched: Int,
  expectedRows: Int,
  actualFetched: Long,
  actualRows: Long,
  exception: Option[String],
  status: String
)

def runOne(tc: TestCase, ansi: Boolean): Result = {
  val expF = if (ansi) tc.expectedFetchedAnsi.getOrElse(tc.expectedFetched) else tc.expectedFetched
  val expR = if (ansi) tc.expectedRowsAnsi.getOrElse(tc.expectedRows) else tc.expectedRows
  HiveCatalogMetrics.reset()
  var rows = -1L
  var ex: Option[String] = None
  try {
    rows = spark.sql(tc.sql).collect().length.toLong
  } catch {
    case e: Throwable =>
      ex = Some(s"${e.getClass.getSimpleName}: ${e.getMessage.take(120)}")
  }
  val fetched = HiveCatalogMetrics.METRIC_PARTITIONS_FETCHED.getCount
  val status =
    if (ex.isDefined && ansi) s"⚠️ ANSI异常(可能符合预期)"
    else if (ex.isDefined) s"❗ 异常: ${ex.get.take(60)}"
    else if (fetched == expF && rows == expR) "✅ PASS"
    else if (fetched == expF) s"⚠️ FETCH-OK(行数${rows}≠${expR})"
    else s"❌ FAIL(f=${fetched}≠${expF})"
  Result(tc, ansi, expF, expR, fetched, rows, ex, status)
}

// ---------- 用例集合 ----------
val cases = ArrayBuffer[TestCase]()

// === STRING 分区列（ANSI 不影响下推结论，cast 目标类型不同）===
val s = "t_str"
cases += TestCase(s, "STRING", "dt = '20260601' (string lit, 同类型)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt = '20260601'", 1, None, 1)
cases += TestCase(s, "STRING", "dt = 20260601 (number lit)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt = 20260601", 5, None, 1)
cases += TestCase(s, "STRING", "cast(dt as int) = 20260601",
  s"SELECT * FROM $TEST_DB.$s WHERE cast(dt as int) = 20260601", 5, None, 1)
cases += TestCase(s, "STRING", "cast(dt as bigint) = 20260601",
  s"SELECT * FROM $TEST_DB.$s WHERE cast(dt as bigint) = 20260601", 5, None, 1)
cases += TestCase(s, "STRING", "dt != '20260601'",
  s"SELECT * FROM $TEST_DB.$s WHERE dt != '20260601'", 1, None, 4)
cases += TestCase(s, "STRING", "dt > '20260603'",
  s"SELECT * FROM $TEST_DB.$s WHERE dt > '20260603'", 1, None, 2)
cases += TestCase(s, "STRING", "dt >= '...' AND dt < '...' (区间)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt >= '20260601' AND dt < '20260603'", 1, None, 2)
cases += TestCase(s, "STRING", "dt IN ('20260601','20260603')",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IN ('20260601','20260603')", 1, None, 2)
cases += TestCase(s, "STRING", "dt IN (20260601, 20260603) (number IN)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IN (20260601, 20260603)", 5, None, 2)
cases += TestCase(s, "STRING", "dt NOT IN ('20260601','20260603')",
  s"SELECT * FROM $TEST_DB.$s WHERE dt NOT IN ('20260601','20260603')", 1, None, 3)
cases += TestCase(s, "STRING", "dt LIKE '202606%' (前缀)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '202606%'", 1, None, 5)
cases += TestCase(s, "STRING", "dt LIKE '%0601' (后缀)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '%0601'", 1, None, 1)
cases += TestCase(s, "STRING", "dt LIKE '%0601%' (包含)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '%0601%'", 1, None, 1)
cases += TestCase(s, "STRING", "dt LIKE '202606_1' (复杂 like)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '202606_1'", 5, None, 1)
cases += TestCase(s, "STRING", "dt RLIKE '^2026.*' (正则)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt RLIKE '^2026.*'", 5, None, 5)
cases += TestCase(s, "STRING", "dt <=> '20260601' (NullSafe)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt <=> '20260601'", 5, None, 1)
cases += TestCase(s, "STRING", "OR 复合",
  s"SELECT * FROM $TEST_DB.$s WHERE dt = '20260601' OR dt = '20260602'", 1, None, 2)
cases += TestCase(s, "STRING", "IS NULL",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IS NULL", 5, None, 0)
cases += TestCase(s, "STRING", "IS NOT NULL",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IS NOT NULL", 5, None, 5)
cases += TestCase(s, "STRING", "BETWEEN",
  s"SELECT * FROM $TEST_DB.$s WHERE dt BETWEEN '20260601' AND '20260603'", 1, None, 3)
cases += TestCase(s, "STRING", "substr(dt,1,6)='202606'",
  s"SELECT * FROM $TEST_DB.$s WHERE substr(dt,1,6)='202606'", 5, None, 5)
cases += TestCase(s, "STRING", "concat(dt,'_x')='20260601_x'",
  s"SELECT * FROM $TEST_DB.$s WHERE concat(dt,'_x')='20260601_x'", 5, None, 1)
cases += TestCase(s, "STRING", "length(dt)=8",
  s"SELECT * FROM $TEST_DB.$s WHERE length(dt)=8", 5, None, 5)
cases += TestCase(s, "STRING", "无 filter (基线)",
  s"SELECT * FROM $TEST_DB.$s", 5, None, 5)

// === INT 分区列（!! ANSI 关键差异点 !!）===
val i = "t_int"
cases += TestCase(i, "INT", "dt = 20260601 (整数字面量)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = 20260601", 1, None, 1)
cases += TestCase(i, "INT", "dt = 20260601L (long 字面量, int upcast)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = 20260601L", 1, None, 1)
// ★ 关键: ansi=false 不下推 (5), ansi=true 下推 (1)
cases += TestCase(i, "INT", "★ANSI★ dt = '20260601' (string lit on INT col)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = '20260601'",
  expectedFetched = 5, expectedFetchedAnsi = Some(1), expectedRows = 1)
cases += TestCase(i, "INT", "dt > 20260603",
  s"SELECT * FROM $TEST_DB.$i WHERE dt > 20260603", 1, None, 2)
cases += TestCase(i, "INT", "dt IN (20260601, 20260603)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt IN (20260601, 20260603)", 1, None, 2)
cases += TestCase(i, "INT", "dt = 20260601D (double lit)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = 20260601D", 5, None, 1)
cases += TestCase(i, "INT", "dt = -1 (负数)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = -1", 1, None, 0)

// === BIGINT 分区列（!! ANSI 关键差异点 !!）===
val b = "t_bigint"
cases += TestCase(b, "BIGINT", "dt = 20260601 (int lit -> bigint)",
  s"SELECT * FROM $TEST_DB.$b WHERE dt = 20260601", 1, None, 1)
cases += TestCase(b, "BIGINT", "dt = 20260601L (long lit, 同类型)",
  s"SELECT * FROM $TEST_DB.$b WHERE dt = 20260601L", 1, None, 1)
// ★ 关键: ansi=false 不下推 (5), ansi=true 下推 (1)
cases += TestCase(b, "BIGINT", "★ANSI★ dt = '20260601' (string lit on BIGINT col)",
  s"SELECT * FROM $TEST_DB.$b WHERE dt = '20260601'",
  expectedFetched = 5, expectedFetchedAnsi = Some(1), expectedRows = 1)

// === DATE 分区列 ===
val d = "t_date"
cases += TestCase(d, "DATE", "dt = DATE '2026-06-01'",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = DATE '2026-06-01'", 1, None, 1)
cases += TestCase(d, "DATE", "dt = '2026-06-01' (字符串字面量)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = '2026-06-01'", 1, None, 1)
cases += TestCase(d, "DATE", "dt = 20260601 (数字字面量)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = 20260601", 5, None, 0)
cases += TestCase(d, "DATE", "dt >= ... AND dt < ... (区间)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt >= DATE '2026-06-01' AND dt < DATE '2026-06-03'", 1, None, 2)
cases += TestCase(d, "DATE", "year(dt) = 2026 (函数包裹)",
  s"SELECT * FROM $TEST_DB.$d WHERE year(dt) = 2026", 5, None, 5)
cases += TestCase(d, "DATE", "dt = current_date()",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = current_date()", 1, None, 0)

// ---------- 跑两轮 ----------
println(s"\n========== Stage 2: 跑 ${cases.size} 个用例 × 2 个 ANSI 模式 ==========\n")

val ansiResults = ArrayBuffer[Result]()
Seq(false, true).foreach { ansi =>
  spark.sql(s"SET spark.sql.ansi.enabled=$ansi")
  val actual = spark.sql("SET spark.sql.ansi.enabled").collect()(0).getString(1)
  println(s"\n----- ANSI 模式 = $ansi (实际生效: $actual) -----\n")
  cases.foreach { tc =>
    ansiResults += runOne(tc, ansi)
  }
}

// 还原默认
spark.sql("SET spark.sql.ansi.enabled=false")

// ---------- 汇总 ----------
println("\n========== Stage 3: 结果汇总 ==========\n")
println(f"${"ANSI"}%-6s ${"状态"}%-26s ${"表"}%-9s ${"列类型"}%-8s ${"f期望"}%-7s ${"f实际"}%-7s ${"r期望"}%-7s ${"r实际"}%-7s ${"用例描述"}")
println("-" * 160)
ansiResults.foreach { r =>
  println(f"${r.ansiMode}%-6s ${r.status}%-26s ${r.tc.table}%-9s ${r.tc.colType}%-8s ${r.expectedFetched}%-7d ${r.actualFetched}%-7d ${r.expectedRows}%-7d ${r.actualRows}%-7d ${r.tc.description}")
}
println("-" * 160)

val passCount = ansiResults.count(_.status.startsWith("✅"))
val failCount = ansiResults.count(_.status.startsWith("❌"))
val atypicalCount = ansiResults.count(_.status.startsWith("⚠️"))
val exCount = ansiResults.count(_.status.startsWith("❗"))
println(s"\n总计: ${ansiResults.size}  通过: $passCount  失败: $failCount  非典型: $atypicalCount  异常: $exCount")

// ---------- 关键差异对比 ----------
println("\n========== Stage 4: ANSI 模式差异对比（重点）==========\n")
val ansiSensitive = cases.filter(_.expectedFetchedAnsi.isDefined)
println(s"${ansiSensitive.size} 个用例标记 ANSI 模式敏感, 验证差异:")
println()
ansiSensitive.foreach { tc =>
  val rFalse = ansiResults.find(r => !r.ansiMode && r.tc.sql == tc.sql).get
  val rTrue = ansiResults.find(r => r.ansiMode && r.tc.sql == tc.sql).get
  val diff = if (rFalse.actualFetched != rTrue.actualFetched) "✓ 行为差异" else "✗ 行为相同"
  println(s"  $diff | ${tc.colType} | ${tc.description}")
  println(s"    ansi=false: fetched=${rFalse.actualFetched} rows=${rFalse.actualRows} ${rFalse.exception.map("EX:"+_).getOrElse("")}")
  println(s"    ansi=true:  fetched=${rTrue.actualFetched} rows=${rTrue.actualRows}  ${rTrue.exception.map("EX:"+_).getOrElse("")}")
  println()
}

// ---------- 失败用例详情 ----------
val failures = ansiResults.filter(r => r.status.startsWith("❌"))
if (failures.nonEmpty) {
  println("\n========== Stage 5: 失败用例详情 ==========\n")
  failures.foreach { r =>
    println(s"❌ ANSI=${r.ansiMode} | ${r.tc.table} (${r.tc.colType}) - ${r.tc.description}")
    println(s"   SQL: ${r.tc.sql}")
    println(s"   期望 fetched=${r.expectedFetched} rows=${r.expectedRows}")
    println(s"   实际 fetched=${r.actualFetched}     rows=${r.actualRows}")
    println()
  }
}

println("\n========== 完成 ==========")
println("如有失败用例或 ANSI 差异不符预期, 请把汇总贴回, 我据此修正手册")
