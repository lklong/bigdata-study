# Kyuubi on K8s Engine 启动链路与 Celeborn 集成

> 来源案例：K8s vs YARN 性能对比（K8s 慢 8%），2026-04-07

---

## Kyuubi on K8s 的 Engine 启动链路

```
1. Kyuubi Server 收到连接请求
2. 创建 SparkSQLEngine (submitInDriver=true, deploy-mode=client)
3. K8s Driver Pod 启动:
   - Volcano PodGroup 创建 (minMember=1)
   - Driver Pod 调度到 spark-cluster=pangu 节点
   - SparkContext 初始化
   - KubernetesClusterSchedulerBackend 启动
   - dynamicAllocation.initialExecutors=1 → 先请求 1 个 executor

4. Executor Pod 启动（每个都要）:
   - Volcano 调度
   - Container 启动 + JVM 启动
   - TransportClientFactory 连接 Driver (走 Service DNS)
   - 从 Driver 拉取 kyuubi-spark-sql-engine JAR (~1s)
   - BlockManager 注册
   - 开始执行 task

5. 动态扩容:
   - initialExecutors=1 → 第一个 task 触发 backlog
   - 指数扩容: 1→2→4→8→16→32→64→100 (约 25s)
   - 全部 100 exec 就绪约需 117s (从首次请求到最后注册)
```

## Celeborn 集成配置

```properties
# K8s 环境特有
spark.shuffle.manager = org.apache.spark.shuffle.celeborn.SparkShuffleManager
spark.shuffle.service.enabled = false  # 不用 ESS
spark.shuffle.sort.io.plugin.class = org.apache.spark.shuffle.celeborn.CelebornShuffleDataIO
spark.dynamicAllocation.shuffleTracking.enabled = false  # Celeborn 不需要 shuffle tracking
spark.sql.adaptive.localShuffleReader.enabled = false    # ← 注意！禁用了本地读

# Celeborn master
spark.celeborn.master.endpoints = celeborn-master-0...svc,celeborn-master-1...svc,celeborn-master-2...svc
spark.celeborn.client.push.replicate.enabled = false
spark.celeborn.client.spark.push.dynamicWriteMode.enabled = true
```

## 注意事项

```
1. localShuffleReader.enabled=false 在有 Shuffle 的查询中会影响性能
   - YARN 端默认 true (本地读优化)
   - K8s+Celeborn 需要 false (因为 shuffle 数据在 Celeborn worker 上)
   
2. initialExecutors=1 导致前 65s 只有 1 个 executor
   - 建议设为预期值 100 或关闭动态分配
```
