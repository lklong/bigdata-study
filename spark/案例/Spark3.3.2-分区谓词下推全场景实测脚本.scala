// =====================================================================
// Spark 3.3.2 分区谓词下推全场景实测脚本
//
// 用法（在 EMR master 节点上）:
//   spark-shell --conf spark.sql.hive.metastorePartitionPruningFastFallback=false \
//     -i Spark3.3.2-分区谓词下推全场景实测脚本.scala 2>&1 | tee 下推实测.log
//
// 或者:
//   spark-shell --conf spark.sql.hive.metastorePartitionPruningFastFallback=false
//   :load Spark3.3.2-分区谓词下推全场景实测脚本.scala
//
// 设计:
//   - 造 4 张测试表: t_str / t_int / t_bigint / t_date
//   - 每张表 5 个分区, 用足够区分 fetched=1 (下推) vs fetched=5 (全拉)
//   - 每个测试用例前 reset() metric, 输出 fetched=N 直接读
//   - 输出格式: [✅ PASS / ❌ FAIL / ⚠️ ATYPICAL] 表 | 列类型 | SQL片段 | 期望 | 实际
//   - 总结行: 通过/失败统计
//
// 配套手册: Spark3.3.2-分区谓词下推完全速查手册.md
// =====================================================================

import org.apache.spark.metrics.source.HiveCatalogMetrics
import scala.collection.mutable.ArrayBuffer

// 测试库
val TEST_DB = "default"
val TABLES = Map(
  "t_str"    -> ("STRING",  Seq("'20260601'", "'20260602'", "'20260603'", "'20260604'", "'20260605'")),
  "t_int"    -> ("INT",     Seq("20260601",   "20260602",   "20260603",   "20260604",   "20260605")),
  "t_bigint" -> ("BIGINT",  Seq("20260601",   "20260602",   "20260603",   "20260604",   "20260605")),
  "t_date"   -> ("DATE",    Seq("'2026-06-01'", "'2026-06-02'", "'2026-06-03'", "'2026-06-04'", "'2026-06-05'"))
)

val TOTAL_PARTITIONS = 5

// ----- 阶段 1: 准备表 -----
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

// ----- 实测核心函数 -----
case class TestCase(
  table: String,
  colType: String,
  description: String,
  sql: String,
  expectedFetched: Int,    // 期望的 fetched 数（1=下推, 5=全拉）
  expectedRows: Int        // 期望命中行数
)

case class Result(
  tc: TestCase,
  actualFetched: Long,
  actualRows: Long,
  status: String           // PASS / FAIL / ATYPICAL
)

def runOne(tc: TestCase): Result = {
  HiveCatalogMetrics.reset()
  val rows = try {
    spark.sql(tc.sql).collect().length.toLong
  } catch {
    case e: Throwable =>
      println(s"  ❗ 异常: ${tc.sql} -> ${e.getClass.getSimpleName}: ${e.getMessage.take(120)}")
      -1L
  }
  val fetched = HiveCatalogMetrics.METRIC_PARTITIONS_FETCHED.getCount
  val status =
    if (rows == -1L) "FAIL(异常)"
    else if (fetched == tc.expectedFetched && rows == tc.expectedRows) "✅ PASS"
    else if (fetched == tc.expectedFetched) s"⚠️ FETCH-OK(行数${rows}≠${tc.expectedRows})"
    else if (rows == tc.expectedRows) s"❌ FAIL(fetched=$fetched 期望${tc.expectedFetched})"
    else s"❌ FAIL(双不符 f=$fetched r=$rows)"
  Result(tc, fetched, rows, status)
}

// ----- 用例定义 -----
// 注意: 每个用例对应"配套手册"中的一行, 改用例时同步更新手册
val cases = ArrayBuffer[TestCase]()

// =========== STRING 分区列用例 ===========
val s = "t_str"
cases += TestCase(s, "STRING", "dt = '20260601' (字符串字面量, 同类型)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt = '20260601'", 1, 1)
cases += TestCase(s, "STRING", "dt = 20260601 (数字字面量, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt = 20260601", 5, 1)
cases += TestCase(s, "STRING", "cast(dt as int) = 20260601 (显式 cast, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE cast(dt as int) = 20260601", 5, 1)
cases += TestCase(s, "STRING", "cast(dt as bigint) = 20260601 (显式 cast bigint, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE cast(dt as bigint) = 20260601", 5, 1)
cases += TestCase(s, "STRING", "dt != '20260601' (Not Equal, 字符串)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt != '20260601'", 1, 4)
cases += TestCase(s, "STRING", "dt > '20260603' (GreaterThan)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt > '20260603'", 1, 2)
cases += TestCase(s, "STRING", "dt >= '20260601' AND dt < '20260603' (区间)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt >= '20260601' AND dt < '20260603'", 1, 2)
cases += TestCase(s, "STRING", "dt IN ('20260601','20260603') (In 字符串)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IN ('20260601','20260603')", 1, 2)
cases += TestCase(s, "STRING", "dt IN (20260601, 20260603) (In 数字, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IN (20260601, 20260603)", 5, 2)
cases += TestCase(s, "STRING", "dt NOT IN ('20260601','20260603') (NotIn 字符串)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt NOT IN ('20260601','20260603')", 1, 3)
cases += TestCase(s, "STRING", "dt LIKE '202606%' (前缀)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '202606%'", 1, 5)
cases += TestCase(s, "STRING", "dt LIKE '%0601' (后缀)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '%0601'", 1, 1)
cases += TestCase(s, "STRING", "dt LIKE '%0601%' (包含)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '%0601%'", 1, 1)
cases += TestCase(s, "STRING", "dt LIKE '202606_1' (复杂 like, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt LIKE '202606_1'", 5, 1)
cases += TestCase(s, "STRING", "dt RLIKE '^2026.*' (正则, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt RLIKE '^2026.*'", 5, 5)
cases += TestCase(s, "STRING", "dt <=> '20260601' (NullSafe Equal, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt <=> '20260601'", 5, 1)
cases += TestCase(s, "STRING", "dt = '20260601' OR dt = '20260602' (Or)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt = '20260601' OR dt = '20260602'", 1, 2)
cases += TestCase(s, "STRING", "dt IS NULL (❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IS NULL", 5, 0)
cases += TestCase(s, "STRING", "dt IS NOT NULL (❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt IS NOT NULL", 5, 5)
cases += TestCase(s, "STRING", "dt BETWEEN '20260601' AND '20260603' (Between)",
  s"SELECT * FROM $TEST_DB.$s WHERE dt BETWEEN '20260601' AND '20260603'", 1, 3)
cases += TestCase(s, "STRING", "substr(dt,1,6)='202606' (函数包裹, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE substr(dt,1,6)='202606'", 5, 5)
cases += TestCase(s, "STRING", "concat(dt,'_x')='20260601_x' (函数包裹, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE concat(dt,'_x')='20260601_x'", 5, 1)
cases += TestCase(s, "STRING", "length(dt)=8 (函数包裹, ❌)",
  s"SELECT * FROM $TEST_DB.$s WHERE length(dt)=8", 5, 5)
cases += TestCase(s, "STRING", "无 filter (基线)",
  s"SELECT * FROM $TEST_DB.$s", 5, 5)

// =========== INT 分区列用例 ===========
val i = "t_int"
cases += TestCase(i, "INT", "dt = 20260601 (整数字面量)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = 20260601", 1, 1)
cases += TestCase(i, "INT", "dt = 20260601L (long 字面量, int upcast)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = 20260601L", 1, 1)
cases += TestCase(i, "INT", "dt = '20260601' (字符串字面量, ❌)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = '20260601'", 5, 1)
cases += TestCase(i, "INT", "dt > 20260603 (区间)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt > 20260603", 1, 2)
cases += TestCase(i, "INT", "dt IN (20260601, 20260603) (In 整数)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt IN (20260601, 20260603)", 1, 2)
cases += TestCase(i, "INT", "dt = 20260601D (double 字面量, ❌)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = 20260601D", 5, 1)
cases += TestCase(i, "INT", "dt = -1 (负数字面量, 不命中)",
  s"SELECT * FROM $TEST_DB.$i WHERE dt = -1", 1, 0)

// =========== BIGINT 分区列用例 ===========
val b = "t_bigint"
cases += TestCase(b, "BIGINT", "dt = 20260601 (int 字面量被提升到 bigint)",
  s"SELECT * FROM $TEST_DB.$b WHERE dt = 20260601", 1, 1)
cases += TestCase(b, "BIGINT", "dt = 20260601L (long 字面量, 同类型)",
  s"SELECT * FROM $TEST_DB.$b WHERE dt = 20260601L", 1, 1)
cases += TestCase(b, "BIGINT", "dt = '20260601' (字符串字面量, ❌)",
  s"SELECT * FROM $TEST_DB.$b WHERE dt = '20260601'", 5, 1)

// =========== DATE 分区列用例 ===========
val d = "t_date"
cases += TestCase(d, "DATE", "dt = DATE '2026-06-01' (显式 DATE 字面量)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = DATE '2026-06-01'", 1, 1)
cases += TestCase(d, "DATE", "dt = '2026-06-01' (字符串字面量, Catalyst cast)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = '2026-06-01'", 1, 1)
cases += TestCase(d, "DATE", "dt = 20260601 (数字字面量, ❌)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = 20260601", 5, 0)
cases += TestCase(d, "DATE", "dt >= DATE '2026-06-01' AND dt < DATE '2026-06-03' (区间)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt >= DATE '2026-06-01' AND dt < DATE '2026-06-03'", 1, 2)
cases += TestCase(d, "DATE", "year(dt) = 2026 (函数包裹, ❌)",
  s"SELECT * FROM $TEST_DB.$d WHERE year(dt) = 2026", 5, 5)
cases += TestCase(d, "DATE", "dt = current_date() (常量函数, 取决于今天)",
  s"SELECT * FROM $TEST_DB.$d WHERE dt = current_date()", 1, 0)  // 不命中（除非今天恰好是 2026-06-01~05）

// ----- 阶段 2: 跑用例 -----
println(s"\n========== Stage 2: 跑 ${cases.size} 个用例 ==========\n")
val results = cases.map(runOne)

// ----- 阶段 3: 汇总输出 -----
println("\n========== Stage 3: 结果汇总 ==========\n")
println(f"${"状态"}%-26s ${"表"}%-9s ${"列类型"}%-9s ${"f期望"}%-7s ${"f实际"}%-7s ${"r期望"}%-7s ${"r实际"}%-7s ${"用例描述"}%-50s")
println("-" * 140)
results.foreach { r =>
  println(f"${r.status}%-26s ${r.tc.table}%-9s ${r.tc.colType}%-9s ${r.tc.expectedFetched}%-7d ${r.actualFetched}%-7d ${r.tc.expectedRows}%-7d ${r.actualRows}%-7d ${r.tc.description}%-50s")
}
println("-" * 140)
val passCount = results.count(_.status.startsWith("✅"))
val failCount = results.count(_.status.startsWith("❌"))
val atypicalCount = results.count(_.status.startsWith("⚠️"))
println(s"\n总计: ${results.size}  通过: $passCount  失败: $failCount  非典型: $atypicalCount")
println(if (failCount == 0) "🎉 全部通过 (允许非典型)" else s"⚠️ 有 $failCount 个用例与源码推断不符, 需要回看源码或修正手册")

// ----- 阶段 4: 失败用例详情 -----
val failures = results.filter(r => r.status.startsWith("❌"))
if (failures.nonEmpty) {
  println("\n========== Stage 4: 失败用例详情 ==========\n")
  failures.foreach { r =>
    println(s"❌ ${r.tc.table} (${r.tc.colType}) - ${r.tc.description}")
    println(s"   SQL: ${r.tc.sql}")
    println(s"   期望 fetched=${r.tc.expectedFetched} rows=${r.tc.expectedRows}")
    println(s"   实际 fetched=${r.actualFetched}     rows=${r.actualRows}")
    println()
  }
}

println("\n========== 完成 ==========")
println("如有失败用例, 请把失败行贴回, 我据此修正手册标记 [⚙️ 源码推断] -> [✅ 已实测] 或 [❌ 需修正]")

// 退出 (-i 模式下不会自动退出，用 :quit 或 Ctrl-D)
// System.exit(0)
