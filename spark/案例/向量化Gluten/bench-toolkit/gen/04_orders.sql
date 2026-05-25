SET spark.sql.shuffle.partitions=200;
USE bench;
CREATE TABLE bench.orders USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/orders'
AS
SELECT
  id AS order_id,
  pmod(hash(id, 'cust'), 50000000L) AS customer_id,
  date_add('2024-01-01', CAST(pmod(id, 700) AS INT)) AS order_date,
  CAST(unix_timestamp('2024-01-01') + pmod(id, 700) * 86400 + pmod(id, 86400) AS TIMESTAMP) AS order_ts,
  CAST(pmod(hash(id, 'prov'), 34) AS INT) AS province_id,
  CAST(pmod(hash(id, 'city'), 300) AS INT) AS city_id,
  CAST(rand(21) * 9999 + 1 AS DECIMAL(12,2)) AS total_amount,
  CAST(rand(22) * 100 AS DECIMAL(8,2)) AS discount_amount,
  CAST(rand(23) * 30 + 1 AS DECIMAL(8,2)) AS shipping_fee,
  CAST(pmod(hash(id, 'pay'), 5) AS INT) AS payment_method,
  CAST(pmod(hash(id, 'st'), 6) AS INT) AS order_status,
  CAST(pmod(hash(id, 'chan'), 8) AS INT) AS channel_id,
  CAST(rand(24) * 10 + 1 AS INT) AS item_count,
  CAST(pmod(id, 2) AS INT) AS is_paid
FROM range(400000000)
DISTRIBUTE BY pmod(id, 200);
