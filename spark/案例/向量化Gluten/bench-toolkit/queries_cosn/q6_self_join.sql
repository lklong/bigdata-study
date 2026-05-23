-- Q6：复购分析 —— orders self join，找连续 2 单间隔
USE bench_cosn;
WITH order_seq AS (
  SELECT
    customer_id,
    order_id,
    order_date,
    total_amount,
    LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS prev_order_date,
    LAG(total_amount) OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS prev_amount
  FROM orders
  WHERE is_paid = 1
    AND order_date BETWEEN '2024-06-01' AND '2025-06-30'
)
SELECT
  CASE
    WHEN datediff(order_date, prev_order_date) <= 7 THEN '0-7d'
    WHEN datediff(order_date, prev_order_date) <= 30 THEN '8-30d'
    WHEN datediff(order_date, prev_order_date) <= 90 THEN '31-90d'
    ELSE '>90d'
  END AS gap_bucket,
  COUNT(*) AS repurchase_cnt,
  AVG(total_amount) AS avg_curr_amount,
  AVG(prev_amount) AS avg_prev_amount,
  AVG(total_amount - prev_amount) AS avg_amount_diff
FROM order_seq
WHERE prev_order_date IS NOT NULL
GROUP BY 1
ORDER BY 1;
