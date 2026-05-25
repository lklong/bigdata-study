-- TPC-H Q5: Local Supplier Volume
select n_name, sum(l_extendedprice * (1 - l_discount)) as revenue
from parquet.`/bench/tpch_200g/customer` c,
     parquet.`/bench/tpch_200g/orders` o,
     parquet.`/bench/tpch_200g/lineitem` l,
     parquet.`/bench/tpch_200g/supplier` s,
     parquet.`/bench/tpch_200g/nation` n,
     parquet.`/bench/tpch_200g/region` r
where c_custkey = o_custkey and l_orderkey = o_orderkey
  and l_suppkey = s_suppkey and c_nationkey = s_nationkey
  and s_nationkey = n_nationkey and n_regionkey = r_regionkey
  and r_name = 'ASIA'
  and o_orderdate >= '1994-01-01' and o_orderdate < '1995-01-01'
group by n_name
order by revenue desc;
