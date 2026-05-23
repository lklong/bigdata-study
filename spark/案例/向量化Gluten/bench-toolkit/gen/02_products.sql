SET spark.sql.shuffle.partitions=40;
USE bench;
CREATE TABLE bench.products USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/products'
AS
SELECT
  id AS product_id,
  CONCAT('sku_', id) AS sku,
  CONCAT('product_name_', id) AS product_name,
  CAST(pmod(hash(id, 'cat'), 50) AS INT) AS category_id,
  CAST(pmod(hash(id, 'brand'), 2000) AS INT) AS brand_id,
  CAST(pmod(hash(id, 'shop'), 50000) AS INT) AS shop_id,
  CAST(rand(11) * 9000 + 100 AS DECIMAL(12,2)) AS price,
  CAST(rand(12) * 9000 AS DECIMAL(12,2)) AS cost,
  CAST(rand(13) * 100000 AS INT) AS stock,
  CAST(rand(14) * 5 AS DECIMAL(3,2)) AS rating,
  CAST(rand(15) * 100000 AS INT) AS sales_count,
  CAST(rand(16) * 50000 AS INT) AS review_count,
  date_add('2020-01-01', CAST(pmod(id, 2000) AS INT)) AS create_date,
  CAST(pmod(id, 2) AS INT) AS is_active
FROM range(10000000)
DISTRIBUTE BY pmod(id, 40);
