SET spark.sql.shuffle.partitions=80;
USE bench;
CREATE TABLE bench.reviews USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/reviews'
AS
SELECT
  id AS review_id,
  pmod(hash(id, 'cust'), 50000000L) AS customer_id,
  pmod(hash(id, 'prod'), 10000000L) AS product_id,
  pmod(id, 400000000L) AS order_id,
  CAST(rand(41) * 5 + 1 AS INT) AS rating,
  CAST(rand(42) * 500 AS INT) AS useful_count,
  CAST(rand(43) * 100 AS INT) AS comment_length,
  date_add('2024-01-01', CAST(pmod(id, 700) AS INT)) AS review_date,
  CAST(pmod(id, 2) AS INT) AS is_verified
FROM range(150000000)
DISTRIBUTE BY pmod(id, 80);
