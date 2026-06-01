-- Q7（Velox 兼容版）：5 表全 join —— 商品维度全画像
-- 改造点：DECIMAL(12,2) unit_price/total_amount 在聚合前 CAST AS DOUBLE；reviews.rating 是 INT 不需 cast
USE bench_cosn;
SELECT
  p.category_id,
  c.province_id,
  COUNT(DISTINCT oi.product_id) AS unique_products,
  COUNT(DISTINCT oi.customer_id) AS unique_buyers,
  COUNT(DISTINCT oi.order_id) AS unique_orders,
  SUM(CAST(oi.unit_price AS DOUBLE) * oi.quantity) AS gross_amount,
  AVG(CAST(o.total_amount AS DOUBLE)) AS avg_order_amount,
  AVG(CAST(r.rating AS DOUBLE)) AS avg_rating,
  COUNT(r.review_id) AS review_cnt
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN products p ON oi.product_id = p.product_id
JOIN customers c ON oi.customer_id = c.customer_id
LEFT JOIN reviews r ON r.order_id = oi.order_id AND r.product_id = oi.product_id
WHERE oi.item_date BETWEEN '2024-06-01' AND '2025-06-30'
  AND oi.is_returned = 0
  AND o.is_paid = 1
GROUP BY p.category_id, c.province_id
HAVING COUNT(*) > 1000
ORDER BY gross_amount DESC
LIMIT 100;
