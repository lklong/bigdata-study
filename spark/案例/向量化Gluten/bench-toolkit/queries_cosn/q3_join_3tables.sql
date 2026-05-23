-- Q3：order_items ⋈ products ⋈ customers —— 12亿 ⋈ 1千万 ⋈ 5千万
-- 按品类 + 用户性别 看销量 TopN
USE bench_cosn;
SELECT
  p.category_id,
  c.gender,
  COUNT(*) AS item_cnt,
  COUNT(DISTINCT oi.customer_id) AS unique_buyers,
  SUM(oi.quantity) AS total_qty,
  SUM(oi.unit_price * oi.quantity) AS gross_amount,
  AVG(p.price) AS avg_product_price
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN customers c ON oi.customer_id = c.customer_id
WHERE oi.item_date BETWEEN '2024-06-01' AND '2025-06-30'
  AND oi.is_returned = 0
GROUP BY p.category_id, c.gender
ORDER BY gross_amount DESC
LIMIT 100;
