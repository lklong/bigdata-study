# Gluten 与 Velox 关系图谱（专题 1）

> **沉淀来源**：今晚大哥提问"Gluten 和 Velox 是啥关系，为啥放一起说"  
> **核心铁律**：**Velox 是发动机，Gluten 是变速箱**

---

## 〇、最短答案

> **Velox** 是 Meta 出品的通用 C++ 执行引擎库（被加速器）  
> **Gluten** 是 Intel + Kyligence 主导的 Spark→Native 适配层（粘合剂）  
> 两者关系：**集成方 vs 被集成方**，不是父子，不是同类

---

## 一、各自定位

### Velox（被加速器）

| 项 | 值 |
|---|---|
| 出品方 | **Meta**（原 Facebook） |
| 仓库 | github.com/facebookincubator/velox |
| 定位 | **通用 C++ 数据库执行引擎库** |
| **不提供** | SQL 解析、DataFrame、查询优化器 |
| **只接收** | 已优化的物理计划，做 SIMD + 列存执行 |
| 函数语义兼容 | **Presto + Spark 双兼容** |
| License | Apache-2.0 |
| GitHub Stars | 4.1k+，1.5k Forks |
| 用户 | Presto (Prestissimo)、**Gluten**、字节、IBM、Microsoft、Voltron Data |

### Gluten（粘合剂）

| 项 | 值 |
|---|---|
| 出品方 | **Intel + Kyligence + 社区** |
| 仓库 | github.com/apache/incubator-gluten |
| 定位 | **Spark 物理计划 → Native 引擎执行的中间层** |
| 核心工作 | Plan 翻译为 Substrait 协议，丢后端执行 |
| 后端引擎 | **Velox**（主推）/ **ClickHouse**（备选） |
| License | Apache-2.0（**已是 Apache 顶级项目**） |
| 毕业时间 | 2026 年 3 月 |
| 计算位置 | **本身不算数据**，全部交给后端引擎 |

---

## 二、三层架构图

```
        ┌──────────────────────────────────────────┐
        │              Spark                        │
        │  (SparkSession / Catalyst / 物理计划)     │
        └──────────────────┬───────────────────────┘
                           │  把"行式 Plan"丢给 Gluten
                           ▼
        ┌──────────────────────────────────────────┐
        │           Apache Gluten                   │   ← 适配器
        │  ┌───────────────────────────────────┐   │
        │  │ 1. 拦截 Spark 物理计划             │   │
        │  │ 2. 转换为 Substrait 协议           │   │
        │  │ 3. JNI 桥接                        │   │
        │  │ 4. 不支持的算子 fallback 回 Spark  │   │
        │  └───────────────────────────────────┘   │
        └──────────────────┬───────────────────────┘
                           │  Substrait Plan + 数据
                           ▼
        ┌──────────────────────────────────────────┐
        │              Velox                        │   ← 真正干活的
        │  ┌───────────────────────────────────┐   │
        │  │ • Type / Vector / Expression Eval  │   │
        │  │ • Scan / Filter / Project / Agg /  │   │
        │  │   Join / Sort / Window 算子        │   │
        │  │ • SIMD + Arrow 列存                │   │
        │  │ • I/O: Parquet / ORC / HDFS / S3   │   │
        │  │ • Memory / Cache / Spill           │   │
        │  └───────────────────────────────────┘   │
        └──────────────────────────────────────────┘
```

---

## 三、为啥总是连着说"Gluten + Velox"？

因为 **Spark 用户几乎只能选 Velox 这一个后端**：

| 后端选项 | Spark 实际能用吗？ |
|---|---|
| **Velox** | ✅ 默认推荐，社区最活跃 |
| **ClickHouse** | ⚠️ 能用但生态小，主要 Kyligence 维护 |
| 其他 | ❌ 没有 |

所以 "Spark + Gluten" 实际等于 "Spark + Gluten + Velox"，三层捆绑，于是简称 **"Gluten + Velox"**。

但严格讲，**真实结构是三层**：
```
Spark  ─→  Gluten  ─→  Velox
（应用） （适配器） （执行引擎）
```

---

## 四、为啥要分开做？

### 4.1 Velox 的设计哲学：**不绑定特定上层**

Velox 官方原话：
> *"接收完全优化后的查询计划作为输入并执行计算"*  
> *"主要供开发者集成到自己的计算引擎中"*

Velox 故意只做"执行层"，不做 SQL 解析、不做优化器、不做 API。这样它能同时被这些上层用：

| 上层 | 适配器 | 用途 |
|---|---|---|
| **Presto** | **Prestissimo**（Meta 出品）| Presto C++ Worker |
| **Spark** | **Gluten**（Intel 出品）| Spark 加速 |
| **PyTorch / AI** | 直接调 | 数据预处理 |
| **Axiom** | Axiom 自己 | Velox-native 查询引擎 |
| **字节内部** | 自研适配 | OLAP |

如果 Velox 写死成"Spark 专用"，Presto 就用不了了。**Velox 故意不偏袒任何上层**。

### 4.2 Gluten 的设计哲学：**不绑定特定后端**

Gluten 用 **Substrait**（标准协议）做中间层，理论上任何能解析 Substrait 的引擎都能接：

```
                    Spark
                      │
                   Gluten
                      │
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
      Velox       ClickHouse     未来其他
                  （Kyligence）
```

---

## 五、职责切分对照表

| 工作 | 在哪做 | 谁的代码 |
|---|---|---|
| 解析 SQL | Spark Catalyst | Spark |
| 优化执行计划 | Spark Catalyst | Spark |
| 拦截物理 Plan | **Gluten** | Gluten |
| Plan → Substrait 协议 | **Gluten** | Gluten |
| JNI 调用 | **Gluten** | Gluten |
| Fallback 决策 | **Gluten** | Gluten |
| Substrait → Velox Plan | **Velox** | Velox |
| 真正算数据（SIMD）| **Velox** | Velox |
| 列式向量计算 | **Velox** | Velox |
| 内存管理 / Spill | **Velox** | Velox |
| 读 Parquet / ORC | **Velox** | Velox |
| 读 HDFS / S3 | **Velox** | Velox |

**记忆口诀**：**Gluten 管"翻译和路由"，Velox 管"算和读"**。

---

## 六、三个类比帮记忆

### 类比 1：发动机和变速箱
```
Spark    = 整车（轿子壳子+方向盘）
Gluten   = 变速箱（把发动机的转速翻译成轮子能用的力）
Velox    = 发动机（真正做功的部件）
```

### 类比 2：USB 转接头
```
你的电脑      = Spark（出 USB-C 信号）
USB 转接头   = Gluten（把 USB-C 转成 HDMI）
显示器       = Velox（接收 HDMI 信号显示画面）
```

### 类比 3：联合国翻译员
```
Spark 说英语                = Spark 物理 Plan
Gluten                       = 翻译员（翻成 Substrait 世界语）
Velox 听 Substrait + 出列存  = 干完活的人
```

---

## 七、版本绑定关系（坑点）

| 项 | 现实 |
|---|---|
| Gluten 1.5 | 内置 fork 版 Velox（每天从上游同步）|
| Velox 上游 | Meta 自己迭代 |
| 你能换 Velox 版本吗？ | **不能**，跟着 Gluten 走 |
| Velox 升级新算子，多久 Gluten 能用？| 1-3 个月 |
| Velox 有 bug 怎么办？| 给 Velox 提 PR + 等 Gluten 同步 |

> 这就是为啥 Gluten 文档总说：*"Currently, Gluten is using a forked Velox which is daily updated based on upstream Velox"*

---

## 八、源码侧分工（哪些代码在哪里）

| 代码包 | 在哪 | 做什么 |
|---|---|---|
| `org.apache.gluten.GlutenPlugin` | Gluten 项目 / Java+Scala | Spark Plugin 入口 |
| `org.apache.gluten.execution.*` | Gluten 项目 / Scala | Plan 拦截 + Substrait 转换 |
| `gluten-substrait/` | Gluten 项目 / Scala | Substrait 协议序列化 |
| `cpp/core/jni/` | Gluten 项目 / **C++** | JNI 桥接 |
| `velox/exec/` | Velox 项目 / **C++** | 算子实现（HashJoin、Aggregation 等）|
| `velox/expression/` | Velox 项目 / **C++** | 向量化表达式求值 |
| `velox/vector/` | Velox 项目 / **C++** | 列存内存格式 |
| `velox/connectors/hive/` | Velox 项目 / **C++** | Parquet/ORC + HDFS 读取 |

**Gluten 仓库打包时把 Velox 源码拉进来一起编**，最后产出 `gluten-velox-bundle.jar` 里同时含 `libgluten.so` 和 `libvelox.so`。

---

## 九、为啥不直接用 Velox（不要 Gluten）？

理论上你可以写自己的 Spark 适配器直接对接 Velox（绕过 Gluten），但：

| 理由 | 说明 |
|---|---|
| Plan 转换工程量巨大 | 100+ 算子要逐一翻译 |
| Fallback 机制要重写 | Gluten 已处理不支持算子的回退 |
| Spark Hook 要自己写 | Gluten 用 SparkPlugin + ColumnarRule |
| Substrait 序列化要自己做 | Gluten 已做完 |
| 内存模型对接要自己做 | Spark 内存 ↔ Velox 堆外 |

**结论**：Gluten 替你省了 80% 的脏活。除非你想自己写一个新 Gluten 替代品。

---

## 十、一句话总结

> **Velox 是 Meta 的通用 C++ 执行引擎，谁来都能用；Gluten 是 Intel 主导、把 Velox 接到 Spark 上的适配层**。  
> **二者是"被集成方"和"集成方"的关系**。  
> 总连着说是因为 Spark 用户几乎都选 Velox 后端，简称 "Gluten+Velox"。  
> **Gluten 是政策，Velox 是产能**。

---

**End of 专题 1**
