# Ray 分布式计算框架知识手册

> 整理自 Ray 2.55.1 官方文档，2026-05-26 归档

---

## 一、Ray 是什么

Ray 是由加州大学伯克利分校 RISE 实验室开源的**统一分布式计算框架**，核心定位：

- 简化 AI 和 Python 应用的扩展流程
- 提供简单通用的 API，支持从笔记本电脑到大规模集群无缝扩展
- 自动完成资源调度、任务分配等分布式逻辑，用户无需手写

---

## 二、核心功能模块

### 2.1 Ray Core（基础分布式计算原语）

提供两种核心抽象，支持 Python、Java 多语言：

- **无状态任务（Task）**：`@ray.remote` 装饰普通函数 → 分布式异步任务，`.remote()` 触发，返回 ObjectRef，`ray.get()` 获取结果
- **有状态 Actor**：`@ray.remote` 装饰类 → 分布式有状态对象，Ray 自动创建远程实例，维护内部状态

### 2.2 Ray AI Libraries（端到端 AI 工作流）

| 模块 | 功能 |
|------|------|
| **Ray Data** | 分布式 AI 数据预处理，支持 S3/HDFS 等，自动并行转换 |
| **Ray Train** | 分布式模型训练，原生支持 PyTorch/TensorFlow，自动封装 DDP/FSDP |
| **Ray Tune** | 大规模超参数调优，内置网格搜索/贝叶斯优化，支持 TensorBoard |
| **Ray Serve** | 可扩展模型部署，支持多模型、A/B 测试、动态扩缩容 |
| **RLlib** | 工业级强化学习库，支持并行环境采样 |

### 2.3 多环境集群部署

支持一键部署到 AWS、GCP、Azure、Kubernetes、本地服务器，自动扩缩容。

### 2.4 内置可观测工具

- **Ray Dashboard**：Web 控制台，默认 `http://localhost:8265`
- **Ray State API**：CLI/Python SDK 获取集群状态快照

---

## 三、架构设计

### 3.1 基础运行逻辑

```
初始化 Ray → @ray.remote 标记的函数/类自动调度到远程 Worker
    ├── 无状态函数 → 返回 ObjectRef（Future）
    └── 有状态类   → 创建独立远程 Actor 实例
Ray 自动完成：资源分配 + 任务调度 + 跨节点对象传输
```

### 3.2 架构白皮书（深入参考）

- Ray 2.0：https://docs.google.com/document/d/1tBw9A4j62ruI5omIJbMxly-la5w4q_TjyJgJL_jN2fI/preview
- Ray 1.0：https://docs.google.com/document/d/1lAy0Owi-vPz2jEqBSaHNQcy2IBSDEHyXNOQZlGuj93c/preview

### 3.3 内部核心组件

| 组件 | 职责 |
|------|------|
| Driver 进程 | 提交任务，收集结果 |
| Worker 进程 | 执行 Task/Actor，输出 ObjectRef |
| Object Store（Plasma） | 分布式内存对象存储 |
| GCS（Global Control Store） | 集群元数据（Redis 协议） |

---

## 四、依赖关系

### 4.1 基础环境要求

- Python 3.8+（TensorFlow 不支持 Python 3.12）
- GPU 训练需提前配置 CUDA + cuDNN

### 4.2 安装命令

| 场景 | 安装命令 |
|------|----------|
| Ray Core 基础功能 | `pip install -U ray` |
| 完整默认安装 | `pip install -U "ray[default]"` |
| Ray Data | `pip install -U "ray[data]"` |
| Ray Train | `pip install -U "ray[train]"` |
| Ray Tune | `pip install -U "ray[tune]"` |
| Ray Serve | `pip install -U "ray[serve]"` |
| RLlib | `pip install -U "ray[rllib]"` |
| AWS 集群部署 | 额外安装 `boto3` |
| Java 开发 | Maven 引入 `ray-api`、`ray-runtime` |

---

## 五、Ray vs Spark 对比

### 5.1 核心定位差异

| 维度 | Spark | Ray |
|------|-------|-----|
| 设计目标 | 大规模数据处理、批处理、SQL 分析 | AI/ML 工作负载、分布式计算框架 |
| 核心用户 | 数据工程师、数据分析师 | AI 研究员、ML 工程师 |
| 计算范式 | 批量、声明式（DataFrame/SQL） | 细粒度、命令式（Task/Actor） |

### 5.2 适用场景对比

| 场景 | 推荐 |
|------|------|
| 大规模 ETL | ✅ Spark |
| SQL 分析 | ✅ Spark |
| 离线批处理 | ✅ Spark |
| 分布式模型训练 | ✅ Ray |
| 超参数搜索 | ✅ Ray |
| 强化学习 | ✅ Ray |
| 在线推理服务 | ✅ Ray |
| 异构 GPU/CPU 混合调度 | ✅ Ray |

### 5.3 性能特点对比

```
任务粒度：Spark ────────────────────────────── 粗粒度（批次）
          Ray    ──── 细粒度（单个函数/类）

延迟：    Spark ───────────────── 高（任务启动秒级）
          Ray    ──── 低（毫秒级任务调度）

内存管理：Spark ─── JVM，Execution/Storage 内存池
          Ray    ─── gRPC + 共享内存，Object Store

容错：    Spark ─── Lineage 重试（DAG 级别）
          Ray    ─── Actor 故障恢复、Task 自动重试（更细粒度）
```

### 5.4 典型协作架构

```
数据层：  Spark 做 ETL、特征工程（处理大规模数据）
           ↓ 输出特征表
训练层：  Ray 做分布式训练、超参搜索
           ↓ 输出模型
服务层：  Ray Serve 做模型部署
```

---

## 六、Ray 与大模型（LLM）的关系

### 6.1 定位：编排层，不是训练引擎

```
大模型训练技术栈：

底层训练引擎：  DeepSpeed、Megatron-LM、FSDP（PyTorch 原生）
                ↑  Ray 负责编排/调度，不负责底层加速
编排/调度层：   Ray Train、Ray Core
                ↑
用户代码：      训练脚本
```

### 6.2 Ray 在大模型场景中的角色

| 场景 | Ray 的作用 |
|------|------------|
| **分布式训练编排** | 协调多节点多 GPU 资源分配，管理容错重启，简化启动逻辑 |
| **RLHF** | Ray RLlib 是开源界做 RLHF 的主流选择，支持 32+ Worker 并行采样 |
| **推理服务管理** | Ray Serve 管理多个 vLLM 副本，做负载均衡和动态扩缩容 |
| **批量推理** | Ray Core 并行处理 10k+ Prompt，适合离线评估 |

### 6.3 业界使用情况

- Anthropic：用 Ray 做 RLHF（公开博客提及）
- Uber：用 Ray 做 ML 平台后端
- Meta/OpenAI：未公开技术栈

---

## 七、典型场景示例

### 7.1 超参数调优（Ray Tune）

```python
from ray import tune

def train_model(config):
    lr = config["lr"]
    depth = config["depth"]
    accuracy = train_and_eval(lr, depth)
    tune.report(accuracy=accuracy)

tune.run(
    train_model,
    config={
        "lr": tune.loguniform(1e-4, 1e-1),
        "depth": tune.randint(3, 15),
    },
    num_samples=100,  # 100 组组合自动并行
)
```
原来 3 天 → 现在 1 小时。

### 7.2 分布式训练（Ray Train）

```python
from ray.train.torch import TorchTrainer

def train_fn(config):
    model = MyModel()
    # Ray 自动封装 DDP，不用手写
    ...

trainer = TorchTrainer(
    train_fn,
    scaling_config={"num_workers": 8, "use_gpu": True}
)
trainer.fit()  # 8 张 GPU 并行训练
```

### 7.3 在线推理服务（Ray Serve）

```python
from ray import serve

@serve.deployment(num_replicas=4, route_prefix="/model-a")
class ModelA:
    def __call__(self, request):
        ...

@serve.deployment(num_replicas=2, route_prefix="/model-b")
class ModelB:
    def __call__(self, request):
        ...

serve.run([ModelA.bind(), ModelB.bind()])
```
一个服务内部署多个模型，自动扩缩容。

### 7.4 并行数据处理（Ray Core）

```python
import ray

ray.init()

@ray.remote
def process_file(path):
    return process(path)

futures = [process_file.remote(f) for f in file_list]
results = ray.get(futures)
```
`@ray.remote` 一行把函数变分布式。

---

## 八、技术栈位置总结

```
┌──────────────────────────────────────────────┐
│               应用层（用户代码）                 │
├──────────────────────────────────────────────┤
│         计算框架层                              │
│   ┌──────────┐              ┌──────────┐     │
│   │   Ray    │              │  Spark  │     │
│   │(AI/ML)  │              │(批处理)  │     │
│   └────┬─────┘              └────┬─────┘     │
├────────▼──────────────────────────▼──────────┤
│       DeepSpeed / vLLM / PyTorch / HF         │
├──────────────────────────────────────────────┤
│   Kubernetes / YARN / SLURM / Ray CLI        │
├──────────────────────────────────────────────┤
│      CPU / GPU / 内存 / 网络 / 存储            │
└──────────────────────────────────────────────┘

Ray 定位：计算框架层，AI/ML 场景的分布式编排层
```

---

## 九、参考资料

- 官方文档：https://docs.ray.io/en/latest/ray-overview/getting-started.html
- Ray 2.0 架构白皮书：https://docs.google.com/document/d/1tBw9A4j62ruI5omIJbMxly-la5w4q_TjyJgJL_jN2fI/preview
- Ray 1.0 架构白皮书：https://docs.google.com/document/d/1lAy0Owi-vPz2jEqBSaHNQcy2IBSDEHyXNOQZlGuj93c/preview
