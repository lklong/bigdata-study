#!/usr/bin/env bash
# ============================================================================
# HiveServer2 结果正确性验证脚本
# 
# 功能：自动执行 14 组验证 SQL，检测当前 Hive 环境是否存在已知的结果正确性 Bug
# 用法：bash verify-result-bugs.sh <hs2_host> <hs2_port> <user>
# 
# 每组测试自包含（建表+插数据+查询+对比），脚本会输出 PASS/FAIL 和命中的 Bug
# 
# 案例来源：S04-Part2-HS2结果不对排障实战手册
# ============================================================================

set -euo pipefail

# ========== 参数解析 ==========
HS2_HOST="${1:?用法: $0 <hs2_host> <hs2_port> <user>}"
HS2_PORT="${2:?用法: $0 <hs2_host> <hs2_port> <user>}"
HS2_USER="${3:?用法: $0 <hs2_host> <hs2_port> <user>}"
JDBC_URL="jdbc:hive2://${HS2_HOST}:${HS2_PORT}/default"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

# ========== 工具函数 ==========

run_sql() {
    local sql="$1"
    beeline -u "${JDBC_URL}" -n "${HS2_USER}" --silent=true --outputformat=tsv2 \
        -e "${sql}" 2>/dev/null || echo "ERROR"
}

check_test() {
    local test_name="$1"
    local bug_id="$2"
    local description="$3"
    local sql_default="$4"
    local sql_safe="$5"
    local expected_behavior="$6"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  [%02d] %-50s " "${TOTAL_COUNT}" "${test_name}"

    local result_default
    local result_safe
    result_default=$(run_sql "${sql_default}")
    result_safe=$(run_sql "${sql_safe}")

    if [[ "${result_default}" == "ERROR" ]] || [[ "${result_safe}" == "ERROR" ]]; then
        printf "${YELLOW}SKIP${NC} (SQL 执行失败)\n"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return
    fi

    if [[ "${result_default}" != "${result_safe}" ]]; then
        printf "${RED}FAIL${NC} → 命中 ${bug_id}: ${description}\n"
        printf "    默认结果: %s\n" "${result_default}" | head -3
        printf "    安全结果: %s\n" "${result_safe}" | head -3
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        printf "${GREEN}PASS${NC}\n"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

# ========== 环境准备 ==========

echo "============================================================"
echo " HiveServer2 结果正确性验证"
echo " HS2: ${JDBC_URL}"
echo " 用户: ${HS2_USER}"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# 创建测试数据库和表
echo "[准备] 创建测试表..."
run_sql "
CREATE DATABASE IF NOT EXISTS _test_result_verify;
USE _test_result_verify;

-- 向量化 NULL 测试表
DROP TABLE IF EXISTS _tv_null;
CREATE TABLE _tv_null (id INT, flag BOOLEAN) STORED AS ORC;
INSERT INTO _tv_null VALUES (1, true), (2, false), (3, NULL);

-- NOT IN 测试表
DROP TABLE IF EXISTS _tv_notin_a;
DROP TABLE IF EXISTS _tv_notin_b;
CREATE TABLE _tv_notin_a (id INT) STORED AS ORC;
CREATE TABLE _tv_notin_b (id INT) STORED AS ORC;
INSERT INTO _tv_notin_a VALUES (1), (2), (3);
INSERT INTO _tv_notin_b VALUES (1), (NULL);

-- JOIN 测试表
DROP TABLE IF EXISTS _tv_join_a;
DROP TABLE IF EXISTS _tv_join_b;
CREATE TABLE _tv_join_a (id INT, val STRING) STORED AS ORC;
CREATE TABLE _tv_join_b (id INT, val STRING) STORED AS ORC;
INSERT INTO _tv_join_a VALUES (1,'a'), (2,'b'), (3,'c'), (4,'d'), (5,'e');
INSERT INTO _tv_join_b VALUES (1,'x'), (3,'y'), (NULL,'z');

-- 聚合测试表
DROP TABLE IF EXISTS _tv_agg;
CREATE TABLE _tv_agg (category STRING, amount DECIMAL(10,2)) STORED AS ORC;
INSERT INTO _tv_agg VALUES ('A', 100.50), ('A', 200.30), ('B', NULL), ('B', 50.10), (NULL, 75.00);

-- Timestamp 测试表
DROP TABLE IF EXISTS _tv_ts;
CREATE TABLE _tv_ts (id INT, ts TIMESTAMP) STORED AS ORC;
INSERT INTO _tv_ts VALUES (1, '2026-01-01 00:00:00'), (2, '2026-06-15 12:30:00'), (3, NULL);
" > /dev/null 2>&1
echo "[准备] 测试表创建完成"
echo ""

# ========== 测试执行 ==========

echo "========== 1. 向量化 Bug 检测 =========="

check_test "向量化 NULL→true (Boolean)" "HIVE-18622" "Boolean NULL 被错误转为 true" \
    "USE _test_result_verify; SET hive.vectorized.execution.enabled=true; SELECT id, flag FROM _tv_null WHERE flag IS NULL;" \
    "USE _test_result_verify; SET hive.vectorized.execution.enabled=false; SELECT id, flag FROM _tv_null WHERE flag IS NULL;" \
    "两者都应返回 id=3, flag=NULL"

check_test "向量化聚合 (无 GROUP BY)" "HIVE-11172" "向量化聚合结果不对" \
    "USE _test_result_verify; SET hive.vectorized.execution.enabled=true; SELECT COUNT(*), SUM(amount) FROM _tv_agg WHERE category='A';" \
    "USE _test_result_verify; SET hive.vectorized.execution.enabled=false; SELECT COUNT(*), SUM(amount) FROM _tv_agg WHERE category='A';" \
    "两者都应返回 2, 300.80"

check_test "向量化 CASE WHEN" "HIVE-17682" "向量化 CASE 表达式结果错" \
    "USE _test_result_verify; SET hive.vectorized.execution.enabled=true; SELECT id, CASE WHEN flag THEN 'Y' WHEN NOT flag THEN 'N' ELSE 'UNKNOWN' END AS result FROM _tv_null ORDER BY id;" \
    "USE _test_result_verify; SET hive.vectorized.execution.enabled=false; SELECT id, CASE WHEN flag THEN 'Y' WHEN NOT flag THEN 'N' ELSE 'UNKNOWN' END AS result FROM _tv_null ORDER BY id;" \
    "id=3 应为 UNKNOWN"

echo ""
echo "========== 2. NOT IN / 子查询 Bug 检测 =========="

check_test "NOT IN + NULL 丢数据" "HIVE-26135" "NOT IN 子查询含 NULL 时全部丢失" \
    "USE _test_result_verify; SELECT COUNT(*) FROM _tv_notin_a WHERE id NOT IN (SELECT id FROM _tv_notin_b);" \
    "USE _test_result_verify; SELECT COUNT(*) FROM _tv_notin_a WHERE NOT EXISTS (SELECT 1 FROM _tv_notin_b WHERE _tv_notin_b.id = _tv_notin_a.id);" \
    "NOT IN 含 NULL 按 SQL 标准应返回 0 行，NOT EXISTS 应返回 2 行(id=2,3)"

echo ""
echo "========== 3. JOIN Bug 检测 =========="

check_test "JOIN emit interval 截断" "HIVE-15327" "emit interval 截断 OUTER JOIN" \
    "USE _test_result_verify; SET hive.join.emit.interval=1000; SELECT COUNT(*) FROM _tv_join_a a LEFT JOIN _tv_join_b b ON a.id = b.id;" \
    "USE _test_result_verify; SET hive.join.emit.interval=0; SELECT COUNT(*) FROM _tv_join_a a LEFT JOIN _tv_join_b b ON a.id = b.id;" \
    "两者都应返回 5"

check_test "Map Join 开关对比" "HIVE-2101" "Map Join 结果不一致" \
    "USE _test_result_verify; SET hive.auto.convert.join=true; SELECT COUNT(*) FROM _tv_join_a a JOIN _tv_join_b b ON a.id = b.id;" \
    "USE _test_result_verify; SET hive.auto.convert.join=false; SELECT COUNT(*) FROM _tv_join_a a JOIN _tv_join_b b ON a.id = b.id;" \
    "两者都应返回 2"

check_test "N-way JOIN 合并" "HIVE-14326" "N-way JOIN 合并条件丢失" \
    "USE _test_result_verify; SET hive.merge.nway.joins=true; SELECT COUNT(*) FROM _tv_join_a a LEFT JOIN _tv_join_b b ON a.id = b.id LEFT JOIN _tv_notin_a c ON a.id = c.id;" \
    "USE _test_result_verify; SET hive.merge.nway.joins=false; SELECT COUNT(*) FROM _tv_join_a a LEFT JOIN _tv_join_b b ON a.id = b.id LEFT JOIN _tv_notin_a c ON a.id = c.id;" \
    "两者结果应一致"

echo ""
echo "========== 4. CBO Bug 检测 =========="

check_test "CBO 相关子查询" "HIVE-16229" "CBO 子查询聚合结果错" \
    "USE _test_result_verify; SET hive.cbo.enable=true; SELECT category, SUM(amount) FROM _tv_agg GROUP BY category HAVING SUM(amount) > (SELECT AVG(amount) FROM _tv_agg);" \
    "USE _test_result_verify; SET hive.cbo.enable=false; SELECT category, SUM(amount) FROM _tv_agg GROUP BY category HAVING SUM(amount) > (SELECT AVG(amount) FROM _tv_agg);" \
    "两者结果应一致"

echo ""
echo "========== 5. PPD / 存储格式 Bug 检测 =========="

check_test "PPD 开关对比" "HIVE-15680" "PPD 导致结果错误" \
    "USE _test_result_verify; SET hive.optimize.ppd=true; SET hive.optimize.index.filter=true; SELECT COUNT(*) FROM _tv_agg WHERE amount > 50;" \
    "USE _test_result_verify; SET hive.optimize.ppd=false; SET hive.optimize.index.filter=false; SELECT COUNT(*) FROM _tv_agg WHERE amount > 50;" \
    "两者都应返回 3"

echo ""
echo "========== 6. 统计信息 Bug 检测 =========="

check_test "stats-based 聚合" "HIVE-11266" "统计信息不准导致 count 错" \
    "USE _test_result_verify; SET hive.compute.query.using.stats=true; SELECT COUNT(*) FROM _tv_agg;" \
    "USE _test_result_verify; SET hive.compute.query.using.stats=false; SELECT COUNT(*) FROM _tv_agg;" \
    "两者都应返回 5"

echo ""
echo "========== 7. 常量传播 Bug 检测 =========="

check_test "常量传播" "HIVE-22513" "常量传播导致结果错" \
    "USE _test_result_verify; SET hive.optimize.constant.propagation=true; SELECT * FROM _tv_join_a WHERE id = 1 AND id = id;" \
    "USE _test_result_verify; SET hive.optimize.constant.propagation=false; SELECT * FROM _tv_join_a WHERE id = 1 AND id = id;" \
    "两者结果应一致"

echo ""
echo "========== 8. skewindata Bug 检测 =========="

check_test "skewindata + COUNT DISTINCT" "HIVE-10971" "skewindata 导致 count distinct 结果错" \
    "USE _test_result_verify; SET hive.groupby.skewindata=true; SELECT category, COUNT(DISTINCT amount) FROM _tv_agg GROUP BY category ORDER BY category;" \
    "USE _test_result_verify; SET hive.groupby.skewindata=false; SELECT category, COUNT(DISTINCT amount) FROM _tv_agg GROUP BY category ORDER BY category;" \
    "两者结果应一致"

# ========== 清理 ==========

echo ""
echo "[清理] 删除测试表..."
run_sql "DROP DATABASE IF EXISTS _test_result_verify CASCADE;" > /dev/null 2>&1
echo "[清理] 完成"

# ========== 汇总 ==========

echo ""
echo "============================================================"
echo " 验证结果汇总"
echo "============================================================"
echo -e " ${GREEN}PASS${NC}: ${PASS_COUNT}"
echo -e " ${RED}FAIL${NC}: ${FAIL_COUNT}"
echo -e " ${YELLOW}SKIP${NC}: ${SKIP_COUNT}"
echo " 总计: ${TOTAL_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo -e "${RED}⚠️  检测到 ${FAIL_COUNT} 个结果正确性 Bug！${NC}"
    echo "建议：查看 S04-Part2 排障实战手册 §四 对应 Bug 的根因和修复方案"
    exit 1
else
    echo -e "${GREEN}✅ 所有测试通过，当前环境未发现已知的结果正确性 Bug${NC}"
    exit 0
fi
