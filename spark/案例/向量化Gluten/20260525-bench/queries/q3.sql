-- TPC-H Q3: Shipping Priority
select
  l_orderkey,
  sum(l_extendedprice * (1 - l_discount)) as revenue,
  o_orderdate,
  o_shippriority
from parquet.`/bench/tpch_200g/lineitem` l,
     parquet.`/bench/tpch_200g/orders` o
where l_orderkey = o_orderkey
  and o_orderdate < '1995-03-15'
  and l_shipdate > '1995-03-15'
group by l_orderkey, o_orderdate, o_shippriority
order by revenue desc, o_orderdate
limit 10;
