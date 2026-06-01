-- Q1（Velox 兼容版）：订单宽聚合 —— 4 亿行
-- 改造点：将 DECIMAL(12,2)/(8,2) 列在聚合前 CAST AS DOUBLE，绕过 Gluten 1.6.0 + Velox 在 decimal 表达式 type 推导时的 a_precision native bug
USE bench_cosn;
SELECT
  province_id,
  date_format(order_date, 'yyyy-MM') AS month,
  channel_id,
  COUNT(*) AS order_cnt,
  SUM(CAST(total_amount AS DOUBLE))    AS total_gmv,
  AVG(CAST(total_amount AS DOUBLE))    AS avg_amount,
  SUM(CAST(discount_amount AS DOUBLE)) AS total_discount,
  MAX(CAST(total_amount AS DOUBLE))    AS max_amount,
  MIN(CAST(total_amount AS DOUBLE))    AS min_amount,
  STDDEV(CAST(total_amount AS DOUBLE)) AS stddev_amount
FROM orders
WHERE order_date BETWEEN '2024-06-01' AND '2025-06-30'
GROUP BY province_id, date_format(order_date, 'yyyy-MM'), channel_id
ORDER BY total_gmv DESC
LIMIT 50;
