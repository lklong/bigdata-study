-- Q1：订单宽聚合 —— 4 亿行，按省份+月份+渠道维度聚合
USE bench;
SELECT
  province_id,
  date_format(order_date, 'yyyy-MM') AS month,
  channel_id,
  COUNT(*) AS order_cnt,
  SUM(total_amount) AS total_gmv,
  AVG(total_amount) AS avg_amount,
  SUM(discount_amount) AS total_discount,
  MAX(total_amount) AS max_amount,
  MIN(total_amount) AS min_amount,
  STDDEV(total_amount) AS stddev_amount
FROM orders
WHERE order_date BETWEEN '2024-06-01' AND '2025-06-30'
GROUP BY province_id, date_format(order_date, 'yyyy-MM'), channel_id
ORDER BY total_gmv DESC
LIMIT 50;
