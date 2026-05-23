SET spark.sql.shuffle.partitions=1600;
USE bench;

DROP TABLE IF EXISTS bench.order_items;

CREATE TABLE bench.order_items USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/order_items'
AS
SELECT /*+ REPARTITION(800) */
  id AS item_id,
  pmod(id, 400000000L) AS order_id,
  pmod(hash(id, 'prod'), 10000000L) AS product_id,
  pmod(hash(id, 'cust'), 50000000L) AS customer_id,
  CAST(rand(31) * 5 + 1 AS INT) AS quantity,
  CAST(rand(32) * 1000 + 10 AS DECIMAL(12,2)) AS unit_price,
  CAST(rand(33) * 100 AS DECIMAL(8,2)) AS item_discount,
  date_add('2024-01-01', CAST(pmod(id, 700) AS INT)) AS item_date,
  CAST(pmod(hash(id, 'cat'), 50) AS INT) AS category_id,
  CAST(pmod(hash(id, 'shop'), 50000) AS INT) AS shop_id,
  CAST(pmod(id, 2) AS INT) AS is_returned
FROM range(2400000000);
