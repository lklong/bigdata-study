-- Q2：订单 join 用户 —— 4亿 ⋈ 5千万，按用户画像维度看 GMV
USE bench;
SELECT
  c.gender,
  c.vip_level,
  CASE
    WHEN c.age < 25 THEN '<25'
    WHEN c.age < 35 THEN '25-35'
    WHEN c.age < 50 THEN '35-50'
    ELSE '50+'
  END AS age_group,
  COUNT(DISTINCT o.customer_id) AS uv,
  COUNT(*) AS order_cnt,
  SUM(o.total_amount) AS gmv,
  AVG(o.total_amount) AS avg_order_value
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date BETWEEN '2024-06-01' AND '2025-12-31'
  AND o.is_paid = 1
GROUP BY c.gender, c.vip_level,
  CASE
    WHEN c.age < 25 THEN '<25'
    WHEN c.age < 35 THEN '25-35'
    WHEN c.age < 50 THEN '35-50'
    ELSE '50+'
  END
ORDER BY gmv DESC;
