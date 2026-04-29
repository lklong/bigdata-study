# 教案 S07：Flink Job 提交与部署模式 — Session/Per-Job/Application 三选一

> **课时**：35分钟 | **难度**：⭐⭐⭐

## 一、课前导入

> 新同事问你："我该用 `flink run` 还是 `flink run-application`？Session 集群和 Per-Job 有什么区别？" 这三种部署模式决定了**资源隔离级别、启动速度、运维复杂度**。

## 二、三种部署模式对比

| 维度 | Session Mode | Per-Job Mode (已废弃) | Application Mode |
|------|-------------|----------------------|-----------------|
| **JM 生命周期** | 长期运行，多 Job 共享 | 每 Job 一个 JM | 每 Application 一个 JM |
| **资源隔离** | 差（Job 间共享 TM） | 好（独立 TM） | 最好（独立集群） |
| **启动速度** | 快（JM 已在） | 慢（启动 JM+TM） | 中（启动集群但 main 在 JM 跑） |
| **适用** | 开发测试、短小 Job | （已不推荐） | **生产首选** |
| **main() 在哪执行** | 客户端 | 客户端 | JobManager |

## 三、Application Mode — 为什么是生产首选？

```
传统方式 (Session/Per-Job):
  Client → 解析 main() → 生成 JobGraph → 提交到 JM
  问题: main() 中如果加载大量 JAR / 做复杂计算 → Client 负载重

Application Mode:
  Client → 只上传 JAR → JM 内部执行 main() → 生成 JobGraph → 运行
  优势: Client 轻量，JM 有集群资源来执行 main()
```

### 提交命令对比

```bash
# Session Mode
flink run -t yarn-session -Dyarn.application.id=xxx myJob.jar

# Application Mode (推荐)
flink run-application -t yarn-application \
  -Djobmanager.memory.process.size=2048m \
  -Dtaskmanager.memory.process.size=4096m \
  myJob.jar

# Kubernetes Application Mode
flink run-application -t kubernetes-application \
  -Dkubernetes.cluster-id=my-job \
  -Dkubernetes.container.image=flink:1.18 \
  local:///opt/flink/usrlib/myJob.jar
```

## 四、StreamGraph → JobGraph → ExecutionGraph 转换链

```
用户代码 (DataStream API / Table API)
    │
    ▼
StreamGraph (逻辑图: 每个算子一个节点)
    │ 优化: 算子链合并 (Chaining)
    ▼
JobGraph (优化后的图: 可链合的算子合成一个 JobVertex)
    │ JM 接收后
    ▼
ExecutionGraph (运行时图: 每个并行实例一个 ExecutionVertex)
    │
    ▼
物理执行 (调度到 TaskManager 的 Slot)
```

## 五、课堂练习

### 思考题：100 个短 Job，用 Session 还是 Application？

<details>
<summary>参考答案</summary>

- 如果每个 Job 只跑 1-5 分钟 → **Session Mode**（启动快，不用反复创建/销毁集群）
- 如果每个 Job 跑数小时且需要独立资源 → **Application Mode**
- 折中方案：多个相关的短 Job 打包成一个 Application（一个 main 提交多个 Job）
</details>

## 六、知识晶体

```
Session: JM常驻，多Job共享，开发测试用
Application: 每App独立集群，main在JM执行，生产首选
图转换: StreamGraph(逻辑) → JobGraph(优化) → ExecutionGraph(运行时)
K8s场景: kubernetes-application + native 模式 → Pod 动态伸缩
```

*教案作者：Eric | 最后更新：2026-04-30*
