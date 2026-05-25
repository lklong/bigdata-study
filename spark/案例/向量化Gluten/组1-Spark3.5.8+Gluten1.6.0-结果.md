# 组1：Spark 3.5.8 社区版 + Gluten 1.6.0 + JDK17 — 测试结果

## 环境信息

| 项目 | 值 |
|---|---|
| 集群 | 211 EMR (43.143.233.211) |
| Spark | 3.5.8 社区版 |
| Gluten | 1.6.0 ( Velox backend) |
| JDK | JDK17 (TencentKona 17.0.18) |
| Hadoop | 3.x (EMR) |
| 数据 | TPC-H 200GB (`/bench/tpch_200g/`) |
| 部署模式 | yarn-client |
| Executor | 6 × 2core × 2GB |

## 关键踩坑与解决方案

### 问题：`java.lang.NoSuchMethodError: java.nio.ByteBuffer.flip()Ljava/nio/ByteBuffer;`

**根因**：Spark 3.5.x 社区版 jar 用 JDK11+ 编译（`ByteBuffer.flip()` 返回 `ByteBuffer`，JDK8 返回 `Buffer`）。  
NM (NodeManager) 生成 `launch_container.sh` 时，顶层 `export JAVA_HOME="/usr/local/jdk"`（JDK8），覆盖了 `spark.yarn.appMasterEnv.JAVA_HOME` 配置。

**解决**：在 `bench_yarn.sh` 的 `COMMON_OPTS` **命令行**显式加：
```bash
--conf spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
--conf spark.executorEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
```
> 注意：`spark-defaults.conf` 里设的不生效（被 NM env-whitelist 覆盖），**必须命令行 `--conf` 优先级最高才能压过 NM 默认值**。

## 测试结果

### Q1：Pricing Summary（lineitem 全表扫描 + GROUP BY）

| 模式 | Round1 | Round2 | Round3 | 平均 |
|---|---|---|---|---|
| Native Spark | 74.30s | 68.38s | 68.47s | **70.38s** |
| Gluten + Velox | 36.56s | 44.18s | 38.45s | **39.73s** |

- **加速比**：70.38 / 39.73 = **1.77×**
- **结果一致性**：YES ✅

---

*Q2-Q7 测试中...*
