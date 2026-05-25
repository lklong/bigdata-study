-- TPC-H Q4: Order Priority Checking
select o_orderpriority, count(*) as order_count
from parquet.`/bench/tpch_200g/orders` o
where o_orderdate >= '1993-07-01'
  and o_orderdate < '1993-10-01'
  and exists (
    select * from parquet.`/bench/tpch_200g/lineitem` l
    where l_orderkey = o_orderkey and l_receiptdate > l_commitdate
  )
group by o_orderpriority
order by o_orderpriority;
