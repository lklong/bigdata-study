-- Q4（Velox 兼容版）：窗口函数 —— 每个省份内 GMV TopN 用户
-- 改造点：DECIMAL(12,2) total_amount 在聚合前 CAST AS DOUBLE
USE bench_cosn;
WITH user_gmv AS (
  SELECT
    o.customer_id,
    c.province_id,
    c.vip_level,
    SUM(CAST(o.total_amount AS DOUBLE)) AS user_gmv,
    COUNT(*) AS order_cnt
  FROM orders o
  JOIN customers c ON o.customer_id = c.customer_id
  WHERE o.is_paid = 1
    AND o.order_date BETWEEN '2024-01-01' AND '2025-12-31'
  GROUP BY o.customer_id, c.province_id, c.vip_level
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY province_id ORDER BY user_gmv DESC) AS rn,
    DENSE_RANK() OVER (PARTITION BY province_id ORDER BY vip_level DESC) AS vip_rank,
    AVG(user_gmv) OVER (PARTITION BY province_id) AS province_avg_gmv
  FROM user_gmv
)
SELECT province_id, customer_id, user_gmv, order_cnt, vip_rank, province_avg_gmv
FROM ranked
WHERE rn <= 10
ORDER BY province_id, rn;
