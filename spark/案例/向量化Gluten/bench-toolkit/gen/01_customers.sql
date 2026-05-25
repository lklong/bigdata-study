SET spark.sql.shuffle.partitions=60;
USE bench;
CREATE TABLE bench.customers USING parquet
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/customers'
AS
SELECT
  id AS customer_id,
  CONCAT('user_', id) AS username,
  CONCAT('user_', id, '@example.com') AS email,
  CAST(pmod(hash(id), 34) AS INT) AS province_id,
  CAST(pmod(hash(id, 'city'), 300) + 1 AS INT) AS city_id,
  CAST(pmod(hash(id, 'age'), 50) + 18 AS INT) AS age,
  CASE WHEN pmod(id, 2) = 0 THEN 'M' ELSE 'F' END AS gender,
  CAST(pmod(hash(id, 'vip'), 10) AS INT) AS vip_level,
  CAST(rand(42) * 100000 AS DECIMAL(12,2)) AS total_spent,
  date_add('2020-01-01', CAST(pmod(id, 2200) AS INT)) AS register_date,
  date_add('2024-01-01', CAST(pmod(id, 800) AS INT)) AS last_active_date,
  CAST(pmod(id, 2) AS INT) AS is_active
FROM range(50000000)
DISTRIBUTE BY pmod(id, 60);
