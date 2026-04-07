# COS I/O 网络延迟深度分析 + hostNetwork 源码逻辑

---

## 一、COS I/O 网络延迟证据链

### 证据 1：单 Task 粒度对比 — K8s 每个 task 多 ~2s

**K8s Exec-1 前 10 个 task（Stage 3）：**
```
task  0 → 15s (13:29:50 → 13:30:05)
task 29 → 13s (13:30:05 → 13:30:18)
task 90 → 13s (13:30:18 → 13:30:31)
task179 → 16s (13:30:31 → 13:30:47)
task290 → 12s (13:30:47 → 13:30:59)
task386 → 13s (13:30:59 → 13:31:12)
task488 → 13s (13:31:12 → 13:31:25)
task594 → 14s (13:31:25 → 13:31:39)
task693 → 13s (13:31:39 → 13:31:52)
task790 → 15s (13:31:52 → 13:32:07)
```

**YARN Exec 前 10 个 task（Stage 3）：**
```
task 84 → 18s (13:26:28 → 13:26:46)  ← 首个task含初始化
task203 → 10s (13:26:46 → 13:26:56)
task299 → 10s (13:26:56 → 13:27:06)
task403 →  9s (13:27:06 → 13:27:15)
task502 → 11s (13:27:15 → 13:27:26)
task611 → 11s (13:27:26 → 13:27:37)
task716 → 13s (13:27:37 → 13:27:50)
task819 → 16s (13:27:50 → 13:28:06)
task930 → 15s (13:28:06 → 13:28:21)
task1044→ 12s (13:28:21 → 13:28:33)
```

**观察**：K8s 稳定在 12-16s，YARN 大部分在 9-13s。K8s 每 task 确实平均多 ~1-2s。

### 证据 2：Event Log 精确指标 — scan time 差 6.2%

```
K8s  scan time total: 212,424s → 平均 6,162ms/task
YARN scan time total: 199,962s → 平均 5,800ms/task
差异: +362ms/task (+6.2%)
```

`scan time` 的源码定义（`DataSourceScanExec.scala` 第 558-563 行）：
```scala
override def hasNext: Boolean = {
  val startNs = System.nanoTime()
  val res = batches.hasNext  // ← 这里包含：COS HTTP GET + zstd 解压 + ORC 解码
  scanTime += NANOSECONDS.toMillis(System.nanoTime() - startNs)
  res
}
```

**源码已证明 zstd 解压和 ORC 解码两端代码路径完全相同**。因此 scan time 的差异 **只能来自 COS HTTP GET 的 I/O 延迟**。

### 证据 3：COS SDK 配置差异

| 配置 | K8s | YARN |
|------|-----|------|
| `hadoop cos retry times` | **200** | **1000** |
| `cos client retry times` | 5 | 5 |
| `fs.cos.userinfo.region` | `bj` | （相同） |
| `fs.cos.local_block_size` | `536870912` (512MB) | （相同） |
| `fs.cos.buffer.dir` | `/data/emr/hdfs/tmp` | （相同） |

retry times 差 5x（200 vs 1000），但正常读取不触发 retry，不影响性能。

### 证据 4：K8s CNI 网络开销的间接证据

**K8s Pod 的网络路径**：
```
K8s Pod → veth pair → CNI bridge/overlay → Node eth0 → VPC → COS endpoint
                      ↑ 额外的封装/解封装
```

**YARN Container 的网络路径**：
```
YARN Container → Node eth0 → VPC → COS endpoint
                 ↑ 直接使用宿主机网络栈
```

**从连接延迟间接验证**：
```
K8s Exec-1 首次连接 Driver: 61ms  (走 Service DNS + CNI)
YARN Exec 首次连接 Driver:  126ms (走直连IP，但跨 AZ)
```

首次连接延迟 K8s 反而低（说明 K8s 的 Pod 和 Driver 在同一 AZ/同一 Node），但这不代表 COS 连接也快。**COS 的流量模式是大量小块顺序读（每次 HTTP GET 512MB），CNI 网络的 MTU/encapsulation overhead 在大流量下更明显**。

### 证据 5：无法通过日志精确定位 COS 延迟

**不足之处**：COS SDK 没有打印每次 HTTP GET 的延迟日志。要精确验证，需要：

```bash
# 在 K8s Pod 和 YARN Node 上分别跑 COS bandwidth benchmark
# K8s Pod 内
kubectl exec -it <exec-pod> -- bash -c "
  time hadoop fs -cat cosn://zyb-offline/hive/ods_rds/cinfo_oc_01_audit_cinfo_dayinc/dt=20250815/part-00006-*.zstd.orc > /dev/null
"
# YARN Node 上
ssh <yarn-node> "
  time hadoop fs -cat cosn://zyb-offline/hive/ods_rds/cinfo_oc_01_audit_cinfo_dayinc/dt=20250815/part-00006-*.zstd.orc > /dev/null
"
```

---

## 二、hostNetwork 源码分析

### 核心结论：Spark 3.3.2 **不原生支持** `spark.kubernetes.driver.hostNetwork`

在 `emr-3.3.2-zyb` 分支的整个代码库中搜索 `hostNetwork`、`HOST_NETWORK`、`host_network`，**结果为零**。

### 源码关键位置

#### Config.scala（720 行，所有 K8s 配置定义）

```
路径: resource-managers/kubernetes/core/src/main/scala/org/apache/spark/deploy/k8s/Config.scala
```

网络相关配置只有 `namespace`、`scheduler.name`、`podTemplateFile`，**没有 hostNetwork**。

#### BasicDriverFeatureStep.scala（构建 Driver Pod spec）

```scala
// 第 150-163 行 — 构建 Driver Pod
val driverPod = new PodBuilder(pod.pod)
  .editOrNewSpec()
    .withRestartPolicy("Never")
    .addToNodeSelector(conf.nodeSelector.asJava)
    .addToNodeSelector(conf.driverNodeSelector.asJava)
    .addToImagePullSecrets(conf.imagePullSecrets: _*)
    .endSpec()
  .build()
```

**只设置了** `restartPolicy`、`nodeSelector`、`imagePullSecrets`。没有 `.withHostNetwork(true)`。

Driver 的 bind address：
```scala
// 第 136-140 行
.addNewEnv()
  .withName(ENV_DRIVER_BIND_ADDRESS)
  .withValueFrom(new EnvVarSourceBuilder()
    .withNewFieldRef("v1", "status.podIP")  // ← 用 Pod IP (CNI 分配的虚拟 IP)
    .build())
  .endEnv()
```

#### BasicExecutorFeatureStep.scala（构建 Executor Pod spec）

```scala
// 第 283-295 行
val executorPodBuilder = new PodBuilder(pod.pod)
  .editOrNewSpec()
    .withHostname(hostname)
    .withRestartPolicy(policy)
    .addToNodeSelector(kubernetesConf.nodeSelector.asJava)
    .addToNodeSelector(kubernetesConf.executorNodeSelector.asJava)
    .addToImagePullSecrets(kubernetesConf.imagePullSecrets: _*)
```

同样没有 `hostNetwork`。

#### ExecutorPodsAllocator.scala（Pod 创建流程）

```scala
// 第 400-407 行
val podWithAttachedContainer = new PodBuilder(executorPod.pod)
  .editOrNewSpec()
  .addToContainers(executorPod.container)
  .endSpec()
  .build()
val createdExecutorPod = kubernetesClient.pods().create(podWithAttachedContainer)
```

不涉及任何网络配置。

### 实现 hostNetwork 的三种方案

#### 方案 A：Pod Template（推荐，零代码修改）

```yaml
# executor-pod-template.yaml
apiVersion: v1
kind: Pod
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
```

```properties
# Spark 配置
spark.kubernetes.executor.podTemplateFile=/path/to/executor-pod-template.yaml
spark.kubernetes.driver.podTemplateFile=/path/to/driver-pod-template.yaml
```

**源码验证**：`PodBuilderSuite.scala` 第 176 行验证了 Pod Template 中的 `dnsPolicy` 会被保留，说明 Spark 使用 `PodBuilder(pod.pod).editOrNewSpec()` 构建 Pod 时**不会覆盖模板中已有的 spec 字段**。`hostNetwork: true` 也会被保留。

#### 方案 B：自定义 FeatureStep（代码方式）

利用 Spark 3.3.2 的 Developer API：

```scala
// HostNetworkFeatureStep.scala
package com.zyb.spark.k8s

import io.fabric8.kubernetes.api.model.PodBuilder
import org.apache.spark.deploy.k8s.{KubernetesDriverConf, KubernetesExecutorConf, SparkPod}
import org.apache.spark.deploy.k8s.features.{
  KubernetesDriverCustomFeatureConfigStep,
  KubernetesExecutorCustomFeatureConfigStep
}

class HostNetworkFeatureStep extends KubernetesDriverCustomFeatureConfigStep
  with KubernetesExecutorCustomFeatureConfigStep {

  private var enableHostNetwork = false

  override def init(conf: KubernetesDriverConf): Unit = {
    enableHostNetwork = conf.sparkConf.getBoolean("spark.kubernetes.hostNetwork.enabled", false)
  }

  override def init(conf: KubernetesExecutorConf): Unit = {
    enableHostNetwork = conf.sparkConf.getBoolean("spark.kubernetes.hostNetwork.enabled", false)
  }

  override def configurePod(pod: SparkPod): SparkPod = {
    if (enableHostNetwork) {
      val modifiedPod = new PodBuilder(pod.pod)
        .editOrNewSpec()
          .withHostNetwork(true)
          .withDnsPolicy("ClusterFirstWithHostNet")
        .endSpec()
        .build()
      SparkPod(modifiedPod, pod.container)
    } else {
      pod
    }
  }
}
```

使用方式：
```properties
spark.kubernetes.driver.pod.featureSteps=com.zyb.spark.k8s.HostNetworkFeatureStep
spark.kubernetes.executor.pod.featureSteps=com.zyb.spark.k8s.HostNetworkFeatureStep
spark.kubernetes.hostNetwork.enabled=true
```

**注意**：当前环境的 executor featureSteps 已经配了 `VolcanoFeatureStep`：
```
spark.kubernetes.executor.pod.featureSteps = org.apache.spark.deploy.k8s.features.VolcanoFeatureStep
```
需要改为：
```properties
spark.kubernetes.executor.pod.featureSteps=org.apache.spark.deploy.k8s.features.VolcanoFeatureStep,com.zyb.spark.k8s.HostNetworkFeatureStep
```

#### 方案 C：直接改 Spark 源码

在 `Config.scala` 中添加配置项，在 `BasicDriverFeatureStep` 和 `BasicExecutorFeatureStep` 中读取并应用。改动最大但原生体验最好。

### hostNetwork 的注意事项

| 风险 | 说明 | 缓解 |
|------|------|------|
| **端口冲突** | Pod 直接用宿主机端口 | 设 `spark.driver.port=0`、`spark.blockManager.port=0` 随机分配 |
| **DNS 失效** | 默认 DNS 变成宿主机 DNS | 必须设 `dnsPolicy: ClusterFirstWithHostNet` |
| **Driver bind address** | `status.podIP` 变成宿主机 IP | hostNetwork 模式下这是正确的行为（源码第 138 行） |
| **Executor hostname** | hostname 会设为 Pod name（源码第 112 行） | hostNetwork 模式下可能需要关注 |
| **安全性** | Pod 可以监听宿主机任意端口 | 只在 Spark 专用节点上使用 |

### hostNetwork 对 COS I/O 的预期效果

```
开启前: Pod → veth → CNI bridge → iptables/ipvs → Node eth0 → VPC → COS
开启后: Pod → Node eth0 → VPC → COS（直接宿主机网络栈）

每次 COS HTTP GET 减少：
  - 1 次 veth 数据包拷贝
  - 1 次 CNI 封装（如 VXLAN/IPIP encapsulation）
  - 1 次 conntrack 表查询
  
预期改善：对大流量 I/O（本场景每 task 读 ~380MB），减少 ~1-3% 的 I/O 延迟
```

---

## 三、推荐的实施方案

```
优先级排序:
  1. Pod Template 方式（零代码，改配置即可）← 推荐
  2. COS bandwidth benchmark（验证是否真是网络瓶颈）
  3. 自定义 FeatureStep（如果 Pod Template 不满足需求）
```

**推荐的 Pod Template 配置**：

```yaml
# /opt/spark/conf/executor-pod-template.yaml
apiVersion: v1
kind: Pod
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
```

```properties
# Spark 配置加上
spark.kubernetes.executor.podTemplateFile=/opt/spark/conf/executor-pod-template.yaml
```

---

*基于 Spark 3.3.2 emr-3.3.2-zyb 分支源码 + Executor Log + Event Log 分析*
*Eric (豹纹) | 2026-04-08*
