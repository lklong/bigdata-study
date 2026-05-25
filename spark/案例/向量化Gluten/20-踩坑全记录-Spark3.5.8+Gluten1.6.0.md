# Spark 3.5.8 社区版 + Gluten 1.6.0 测试踩坑全记录

**集群**: 211 (43.143.233.211, 1 master + 3 worker, 32c/115GB×3)  
**目标**: 在 Hadoop 3.x EMR 集群上跑 Spark 社区版 3.5.8 + Gluten 1.6.0 + JDK17  
**时间跨度**: 5/22 - 5/25  

---

## 📊 错误发生时间线

| # | 时间 | 错误现象 | 当时尝试的方案 | 结果 |
|---|---|---|---|---|
| 1 | 5/22 21:19 | DirectByteBuffer 错误启动失败 | Spark 3.5.8 + JDK8 | ❌ Spark 3.5.x 不支持 JDK8 |
| 2 | 5/22 装 JDK17 后 | YARN exit code 50 | 默认配置跑 | ❌ worker 没装 JDK17 |
| 3 | 5/22 装 worker JDK17 后 | 跑通 ✅ | 7-Q TPC-H | ✅ Q1 cold 4.27× 加速 |
| 4 | 5/23 17:08 | 跑通但结果不一致 | offHeap=3g | ⚠️ Gluten md5 ≠ Native md5 |
| 5 | 5/23 17:42 | 完美跑通 | bench_yarn.sh + q_complex | ✅ Native 23.7s vs Gluten 8.4s = **2.8×** |
| 6 | 5/23 21:14 | 后期 fail | 加大数据/复杂查询 | ❌ ColumnarBatchOutIterator hasNext 异常 |
| 7 | 5/24 23:34 | container exit 50 | hadoop 用户跑 | ❌ worker JDK17 不见了（被人卸了？） |
| 8 | 5/24 23:50 | exit 50 + ByteBuffer.flip() NoSuchMethodError | archive 分发 JDK17 | ❌ NM aux service shuffle 用 JDK8 |
| 9 | 5/25 00:00 | 同上 | worker 重新装 JDK17 | ❌ 还是同样错误 |
| 10 | 5/25 00:08 | 同上 | 关闭 shuffle.service.enabled | ❌ 还是同样错误 |

---

## 🎯 各错误根因深度分析

### 坑 1: `DirectByteBuffer.<init>(long, int)` NoSuchMethod
**报错**: 启动 Spark 3.5.8 时 Netty 抛 NoSuchMethodError  
**根因**: JDK9+ 移除了 `DirectByteBuffer(long, int)` 私有构造器  
**根因**: Spark 3.5.x 社区版要求 JDK11+ 编译，运行时也必须 JDK11+ → **JDK8 完全不能用**  
**解决**: 装 JDK17 + 加完整 13 个 add-opens

### 坑 2: YARN container exit code 50（5/22）
**报错**: `Container exited with a non-zero exit code 50`  
**根因**: NM 启动 container 时执行 `${JAVA_HOME}/bin/java`，**worker 节点没装 JDK17**  
**解决**: 3 个 worker 都执行 `yum install -y java-17-konajdk`

### 坑 3: Gluten 结果不一致（5/23 17:08）
**报错**: NATIVE_MD5 ≠ GLUTEN_MD5  
**根因 1**: HyperLogLog 函数 (`approx_count_distinct`) Velox 实现与 Spark 不一致  
**根因 2**: Velox NOOP arbitrator 内存压力下 spill 行为不同  
**解决**: 去掉 HLL 函数 + 加大 offHeap 到 3GB

### 坑 4: 大数据量/复杂查询 fail（5/23 21:14）
**报错**: `ColumnarBatchOutIterator.hasNext0` Native crash  
**根因**: Velox `aggregationSpillEnabled=false` + 大数据量 → OOM  
**临时方案**: 限定小数据量（1亿行）+ 简单查询  
**根本方案**: 启用 spill + 调大 partialAggregationMemoryRatio

### 坑 5: 5/23 跑通 → 5/24 跑不通
**根因**: 5/24 集群发生过维护操作：
1. yarn-site.xml 5/24 01:22 被改过（属主 hadoop:hadoop，未备份）
2. worker JDK17 被卸载了（验证：`java-17-konajdk` rpm 不存在）
3. RM epoch 没变（说明 NM 没整体重启），但配置变了

### 坑 6: archive 分发 JDK17 + exit 50（5/24 23:50）
**报错**: container exit 50（即使 archive 已分发 JDK17）  
**根因**: **NM container launcher 在 archive 解压前就执行了 `bin/java`**  
- launch_container.sh 第一行解析 `JAVA_HOME` 用的是 NM 当前进程的 env（=worker 默认 JDK = JDK8）
- archive 是在 spark JVM 启动**之后**才解压到 container 工作目录
- `--conf spark.executorEnv.JAVA_HOME=./jdk17/...` 只对 spark 内部 JVM 生效，对**第一层 launcher 进程无效**
**结论**: archive 分发 JDK17 这条路根本走不通，必须 worker 节点本地装 JDK17

### 坑 7: worker 装 JDK17 后还是 ByteBuffer.flip() NoSuchMethodError（5/25 00:08）⭐ **当前阻塞**

**报错**: 
```
java.lang.NoSuchMethodError: java.nio.ByteBuffer.flip()Ljava/nio/ByteBuffer;
    at org.apache.spark.network.client.TransportClient$3.onSuccess(TransportClient.java:274)
```

**根因深度分析**:
- `ByteBuffer.flip()` JDK8 返回 `Buffer`（父类），JDK9+ 返回 `ByteBuffer`（子类）
- spark-3.5.x 的 `TransportClient.java` 用 JDK11+ 编译，字节码中 `INVOKEVIRTUAL ByteBuffer.flip()ByteBuffer`
- 运行时 JDK8 找 `flip()ByteBuffer` 找不到（JDK8 的方法签名是 `flip()Buffer`）→ NoSuchMethodError

**为什么 worker 装了 JDK17 还报错？**

**可能原因 A**: NM aux-service 的 shuffle jar 用 JDK8 跑
- `yarn.nodemanager.aux-services.spark_shuffle.class=org.apache.spark.network.yarn.YarnShuffleService`
- 这个 service 是 NM 启动时加载到 NM JVM 进程内（NM JVM = JDK8）
- spark-3.5.x-yarn-shuffle.jar 用 JDK11+ 编译 → NoSuchMethodError
- 关 `spark.shuffle.service.enabled=false` 不能解决，因为 NM 启动时 aux-service 已经在 NM JVM 里挂了

**可能原因 B**: spark.executor.extraClassPath 引入了 spark-network-common.jar 旧版
- spark-defaults 没设这个，应该不是

**可能原因 C**: YARN AM/driver 启的 client mode 在 master 上用了 JDK8
- master 默认 java 是 JDK8，但 spark-env.sh 已经 export JAVA_HOME=JDK17
- 但是 spark-submit 内部启 driver 时用的是 `$JAVA_HOME/bin/java`，应该是 JDK17

**精确定位需要的信息**:
1. container 002 在哪个进程？是 ApplicationMaster 还是 spark executor？
2. 它 launch_container.sh 实际执行的 java 路径
3. NM 自己的 JDK 版本

---

## 🚧 关键约束与对比

### 之前 5/22-5/23 跑通的真实配置（07/09/10 文档铁证）

```bash
# spark-env.sh
export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
export PATH=$JAVA_HOME/bin:$PATH

# spark-defaults.conf 
spark.yarn.appMasterEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
spark.executorEnv.JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1
spark.executor.extraJavaOptions=<7个add-opens>
spark.driver.extraJavaOptions=<7个add-opens>

# 资源
--num-executors 6 --executor-cores 2 --executor-memory 2g

# Gluten
spark.plugins=org.apache.gluten.GlutenPlugin
spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager
spark.memory.offHeap.size=3g
```

**前置条件**: 3 个 worker 都装了 `java-17-konajdk` rpm

### 5/22 vs 5/25 集群差异

| 项 | 5/22 | 5/25 |
|---|---|---|
| master JDK17 rpm | ✅ 装了 | ✅ 装了 |
| worker JDK17 rpm | ✅ 装了 | ✅ 刚装（00:00 装的） |
| yarn-site.xml | 默认 | 5/24 01:22 被改过 |
| NM aux-service spark_shuffle | 默认（不存在/不启用？） | 待查 |
| NM 进程的 JAVA_HOME | 待查 | 待查（很可能 JDK8） |

---

## 💡 待验证假设（按优先级）

### 假设 1（最高优先）: NM aux-services spark_shuffle.jar 兼容性问题
**验证方法**: 看 yarn-site.xml 是否配置了 spark_shuffle aux service + NM 启动时 classpath 是否含 spark-network-common.jar  
**修复方法**: 
- 选项 A: 从 yarn-site.xml 移除 spark_shuffle aux service
- 选项 B: 替换 NM classpath 里的 spark-yarn-shuffle.jar 为 JDK8 兼容版本（EMR 自带 spark-3.5.3 的）
- 选项 C: 把 NM 默认 JDK 切到 JDK17（动集群配置，慎重）

### 假设 2: master 上 driver 启动用了 JDK8
**验证方法**: 跑起来后 `ps -ef | grep SparkSubmit` 看 java 路径  
**修复方法**: 在 bench_yarn.sh 开头 `unset JAVA_HOME; export JAVA_HOME=/usr/lib/jvm/TencentKona-17.0.18.b1; export PATH=$JAVA_HOME/bin:$PATH`

### 假设 3: spark-defaults.conf 里某个 jar 路径冲突
**验证方法**: 看 driver/executor 加载的 spark-network-common.jar 是哪个版本  
**修复方法**: 检查 `extraClassPath` 是否引入了旧版 jar

---

## 📌 已知"绝对正确"的点

1. ✅ Spark 3.5.8 社区版 + Gluten 1.6.0 + JDK17 在 211 上**确实跑通过**（5/23 17:42 q_complex 2.8×, 10 文档 TPC-H Q1 cold 4.27×）
2. ✅ worker 必须本地装 `java-17-konajdk` rpm（archive 不行）
3. ✅ 必须用 hadoop 用户跑（root 没 HDFS /user 权限）
4. ✅ 完整 13 个 add-opens（少一个就 JDK17 启动失败）
5. ✅ 关 AQE（`spark.sql.adaptive.enabled=false`）
6. ✅ 211 worker = 172.21.240.126/184/202

---

## 🎯 下一步行动建议（请大哥定）

| 方案 | 操作 | 风险 | 预期 |
|---|---|---|---|
| **A** | 查 yarn-site.xml 看 NM aux-services 配置 + NM JVM 用的 JDK，**先诊断**再说 | 低（只读） | 找到 NoSuchMethodError 真因 |
| **B** | 把 5/22 跑通时的 yarn-site.xml.bak 还原（如果有） | 中（改集群） | 可能直接修好 |
| **C** | 不查 NM 了，直接在 bench_yarn.sh 头加 `unset JAVA_HOME; export JAVA_HOME=JDK17; export PATH=...` 强制 driver 用 JDK17 | 低（只改脚本） | 50% 概率修好 |
| **D** | 采信 5/23 17:42 跑通的数据 + 10 文档 TPC-H 4.27× 数据，组1 直接出报告 | 无 | 实际可交付 |

我推荐**先 A 诊断 + 再 C 试**，2 个动作 5 分钟搞定，不行就 D。

---

**结论**: 当前 211 集群在 5/24 维护后，NM/aux-service/JDK 配置发生了变化，5/22 跑通的"魔法配置"组合不再生效。需要先精确定位 NoSuchMethodError 来自哪个 JVM 进程，才能定向修复。
