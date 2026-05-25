-- ====================================================================
-- 80GB Bench 数据集 5 张外部表 DDL（共享 cosn 数据时使用）
-- 日期：2026-05-24
-- 数据：5 表 / 29 亿行 / 91.7G Parquet
-- 说明：
--   1. 把 LOCATION 中的 cosn 桶名改成你自己的桶
--   2. 已验证 schema 与 spark.read.parquet inferSchema 一致
--   3. 适用 Hive 2.3.7（H2）/ Hive 3.1.3（H3）双版本
-- ====================================================================

CREATE DATABASE IF NOT EXISTS bench;
USE bench;

DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS order_items;

-- ① customers（5 千万行 / 1.1G）
CREATE EXTERNAL TABLE customers (
  customer_id BIGINT,
  username STRING,
  email STRING,
  province_id INT,
  city_id INT,
  age INT,
  gender STRING,
  vip_level INT,
  total_spent DECIMAL(12,2),
  register_date DATE,
  last_active_date DATE,
  is_active INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/customers';

-- ② products（1 千万行 / 408M）
CREATE EXTERNAL TABLE products (
  product_id BIGINT,
  sku STRING,
  product_name STRING,
  category_id INT,
  brand_id INT,
  shop_id INT,
  price DECIMAL(12,2),
  cost DECIMAL(12,2),
  stock INT,
  rating DECIMAL(3,2),
  sales_count INT,
  review_count INT,
  create_date DATE,
  is_active INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/products';

-- ③ reviews（1.5 亿行 / 3.0G）
CREATE EXTERNAL TABLE reviews (
  review_id BIGINT,
  customer_id BIGINT,
  product_id BIGINT,
  order_id BIGINT,
  rating INT,
  useful_count INT,
  comment_length INT,
  review_date DATE,
  is_verified INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/reviews';

-- ④ orders（4 亿行 / 8.2G）
CREATE EXTERNAL TABLE orders (
  order_id BIGINT,
  customer_id BIGINT,
  order_date DATE,
  order_ts TIMESTAMP,
  province_id INT,
  city_id INT,
  total_amount DECIMAL(12,2),
  discount_amount DECIMAL(8,2),
  shipping_fee DECIMAL(8,2),
  payment_method INT,
  order_status INT,
  channel_id INT,
  item_count INT,
  is_paid INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/orders';

-- ⑤ order_items（24 亿行 / 79.1G — 最大表）
CREATE EXTERNAL TABLE order_items (
  item_id BIGINT,
  order_id BIGINT,
  product_id BIGINT,
  customer_id BIGINT,
  quantity INT,
  unit_price DECIMAL(12,2),
  item_discount DECIMAL(8,2),
  item_date DATE,
  category_id INT,
  shop_id INT,
  is_returned INT
) STORED AS PARQUET
LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench/order_items';

-- ====== 验收 SQL ======
SHOW TABLES;
SELECT 'customers',   COUNT(*) FROM customers;    -- 期望 50000000
SELECT 'products',    COUNT(*) FROM products;     -- 期望 10000000
SELECT 'reviews',     COUNT(*) FROM reviews;      -- 期望 150000000
SELECT 'orders',      COUNT(*) FROM orders;       -- 期望 400000000
SELECT 'order_items', COUNT(*) FROM order_items;  -- 期望 2400000000
