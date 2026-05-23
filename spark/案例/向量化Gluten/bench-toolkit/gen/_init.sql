SET spark.sql.adaptive.enabled=true;
SET spark.sql.adaptive.coalescePartitions.enabled=true;
SET spark.sql.parquet.compression.codec=snappy;

DROP DATABASE IF EXISTS bench CASCADE;
CREATE DATABASE bench LOCATION 'cosn://lkl-bj-update-1308597516/meson/data/bench';
USE bench;
