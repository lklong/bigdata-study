-- TPC-H Q2: Minimum Cost Supplier
select
  s_acctbal, s_name, n_name, p_partkey, p_mfgr,
  s_address, s_phone, s_comment
from parquet.`/bench/tpch_200g/part` p,
     parquet.`/bench/tpch_200g/supplier` s,
     parquet.`/bench/tpch_200g/partsupp` ps,
     parquet.`/bench/tpch_200g/nation` n,
     parquet.`/bench/tpch_200g/region` r
where p_partkey = ps_partkey and s_suppkey = ps_suppkey
  and p_size = 15 and p_type like '%BRASS'
  and s_nationkey = n_nationkey and n_regionkey = r_regionkey
  and r_name = 'EUROPE'
  and ps_supplycost = (
    select min(ps2.ps_supplycost)
    from parquet.`/bench/tpch_200g/partsupp` ps2,
         parquet.`/bench/tpch_200g/supplier` s2,
         parquet.`/bench/tpch_200g/nation` n2,
         parquet.`/bench/tpch_200g/region` r2
    where p_partkey = ps2.ps_partkey
      and s2.s_suppkey = ps2.ps_suppkey
      and s2.s_nationkey = n2.n_nationkey
      and n2.n_regionkey = r2.r_regionkey
      and r2.r_name = 'EUROPE'
  )
order by s_acctbal desc, n_name, s_name, p_partkey
limit 100;
