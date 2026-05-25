-- Q5：找出高评分但销量低的潜力商品（review.rating ≥ 4 且 product.sales_count < 中位数）
USE bench;
WITH product_review AS (
  SELECT
    r.product_id,
    AVG(r.rating) AS avg_rating,
    COUNT(*) AS review_cnt,
    SUM(r.useful_count) AS total_useful
  FROM reviews r
  WHERE r.is_verified = 1
  GROUP BY r.product_id
),
hot_products AS (
  SELECT product_id
  FROM order_items
  WHERE item_date BETWEEN '2024-06-01' AND '2025-06-30'
  GROUP BY product_id
  HAVING COUNT(*) > 100
)
SELECT
  p.product_id,
  p.product_name,
  p.category_id,
  p.brand_id,
  p.price,
  p.sales_count,
  pr.avg_rating,
  pr.review_cnt,
  pr.total_useful
FROM products p
JOIN product_review pr ON p.product_id = pr.product_id
WHERE pr.avg_rating >= 4.0
  AND pr.review_cnt >= 50
  AND p.sales_count < 5000
  AND p.product_id IN (SELECT product_id FROM hot_products)
  AND p.is_active = 1
ORDER BY pr.avg_rating DESC, pr.total_useful DESC
LIMIT 200;
