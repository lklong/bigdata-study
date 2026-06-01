-- Q3（Velox 兼容版）：order_items ⋈ products ⋈ customers
-- 改造点：DECIMAL(12,2) unit_price/price 在聚合前 CAST AS DOUBLE
USE bench_cosn;
SELECT
  p.category_id,
  c.gender,
  COUNT(*) AS item_cnt,
  COUNT(DISTINCT oi.customer_id) AS unique_buyers,
  SUM(oi.quantity) AS total_qty,
  SUM(CAST(oi.unit_price AS DOUBLE) * oi.quantity) AS gross_amount,
  AVG(CAST(p.price AS DOUBLE)) AS avg_product_price
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN customers c ON oi.customer_id = c.customer_id
WHERE oi.item_date BETWEEN '2024-06-01' AND '2025-06-30'
  AND oi.is_returned = 0
GROUP BY p.category_id, c.gender
ORDER BY gross_amount DESC
LIMIT 100;
