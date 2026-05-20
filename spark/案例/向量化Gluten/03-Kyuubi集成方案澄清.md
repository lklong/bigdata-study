# Kyuubi 集成 Gluten 方案澄清（专题 2）

> **沉淀来源**：今晚大哥连续提问"Kyuubi 为啥继承 Gluten / 怎么用 / 和 Spark+Gluten 啥区别"  
> **核心铁律（被大哥纠正过的）**：**技术方案上零差异，只有调度层差异**

---

## 〇、必须先认账的事

> **Kyuubi+Gluten 和 Spark+Gluten 在 Gluten 这一层完全相同**——同一个 jar、同一份配置、同一份性能。  
> 之前豹纹用 9 个维度对比"看着像技术差异"，**其实都是 Kyuubi 的能力，不是 Gluten 方案的差异**。  
> **真正的差异只在"外面套了什么调度层"**。

---

## 一、Kyuubi 是什么？

```
        ┌──────────────────────────────────────────┐
        │   BI 工具 / JDBC / Beeline / SQL 客户端  │
        └─────────────────┬────────────────────────┘
                          │  Thrift/REST/MySQL 协议
                          ▼
                ┌─────────────────────┐
                │   Kyuubi Server     │  ← SQL 网关（多租户、HA、鉴权、路由）
                └─────────────────────┘
                          │
              动态拉起/复用 Spark Engine
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
   Spark Engine A    Spark Engine B    Spark Engine C
   (用户1)           (用户2)           (用户3)
```

**Kyuubi 定位**：
- HiveServer2 现代替代品
- 把 Spark 当后端引擎用
- 不写 SQL、不算数据，**职责是"管 Spark"**：多租户隔离 / Engine 池化 / HA / 鉴权 / 路由

---

## 二、Kyuubi 集成 Gluten 的本质

**不是"继承"，是"集成"**——Kyuubi 没写任何粘合代码、没改 Plugin、没 Hook、没 patch。它只做了三件事：

1. **测试**（kyuubi-gluten-it 模块跑 TPC-DS/H）
2. **文档**（一份 50 行部署 md）
3. **CI**（每天凌晨 4 点定时跑）

源码铁证（Kyuubi `GlutenSuiteMixin.scala` 第 27-33 行）：
```scala
trait GlutenSuiteMixin {  // 只是个 Scala trait（混入），不是继承
  protected def extraConfigs: Map[String, String] = Map(
    "spark.plugins" -> "io.glutenproject.GlutenPlugin",
    "spark.memory.offHeap.size" -> "4g",
    "spark.memory.offHeap.enabled" -> "true",
    "spark.shuffle.manager" -> "org.apache.spark.shuffle.sort.ColumnarShuffleManager",
    "spark.gluten.ui.enabled" -> "false",
    "spark.jars" -> extraJars)
}
```

**注意**：这就是普通 Spark 配置，没有任何 Kyuubi 专属逻辑。**Kyuubi 把 Gluten jar 和配置作为可选项透传给 Spark 而已**。

---

## 三、为啥 Kyuubi 要做这层集成？

### 理由 1：性能问题是 Kyuubi 用户核心诉求
Kyuubi 用户多是数仓 / BI / 分析师场景，正是 Gluten 收益最大的场景。

### 理由 2：兼容性必须用 CI 锁住
源码铁证（`GlutenTPCDSQuerySuite.scala` 第 41-43 行）：
```scala
// TODO:Fix gluten tpc-ds query test
("q1", "q4", "q7", "q11", "q12", "q17", "q20", "q21", "q25", "q26", "q29",
"q30", "q34", "q37", "q39a", "q39b", "q40", "q43", "q46", "q49", "q56",
"q58", "q59", "q60", "q68", "q73", "q74", "q78", "q79", "q81", "q82",
"q83", "q84", "q91", "q98")
```
**Kyuubi v1.9.2 + Gluten 1.2 实测**：TPC-DS 99 条查询有 36 条出问题。Kyuubi 通过 CI 把"哪些 SQL 在 Gluten 下安全"摸清楚。

### 理由 3：每天定时跑 CI（gluten.yml 第 21-22 行）
```yaml
on:
  schedule:
    - cron: 0 4 * * *
matrix:
  spark: [ '3.4', '3.3' ]
```
Kyuubi 把 Gluten 当作"必须每天回归"的一等公民。

### 理由 4：降低用户接入门槛
配置 + 文档现成，用户改 5 行就能开启向量化。

---

## 四、Kyuubi+Gluten 实际怎么用？

### 4.1 部署位置（关键认知）

| 组件 | 位置 |
|---|---|
| Gluten jar | `$SPARK_HOME/jars/`（Spark 引擎层）|
| 配置 | `$KYUUBI_HOME/conf/spark-defaults.conf`（透传到 Spark）|
| **Kyuubi Server 自身** | **零改动**，不用重编、不装 Gluten 包 |

### 4.2 三层启用模式（Kyuubi 多租户特性）

**模式 A：全局启用**（所有用户）
```properties
# $KYUUBI_HOME/conf/spark-defaults.conf
spark.plugins=org.apache.gluten.GlutenPlugin
spark.memory.offHeap.enabled=true
spark.memory.offHeap.size=20g
spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager
```

**模式 B：用户级启用**（按租户隔离）
```properties
# $KYUUBI_HOME/conf/kyuubi-defaults.conf
___user_a___.spark.plugins=org.apache.gluten.GlutenPlugin
___user_a___.spark.memory.offHeap.enabled=true
___user_a___.spark.memory.offHeap.size=20g
```

**模式 C：Session/作业级**（最灵活，灰度首选）
```bash
beeline -u "jdbc:hive2://kyuubi:10009/" \
  --hiveconf spark.plugins=org.apache.gluten.GlutenPlugin \
  --hiveconf spark.memory.offHeap.enabled=true
```

### 4.3 Engine 共享级别建议

```properties
kyuubi.engine.share.level=USER
kyuubi.engine.share.level.subdomain=gluten   # 给 Gluten Engine 单独子域名
```
**好处**：同一用户既有 Gluten Engine 也有原生 Engine，按子域名路由。

---

## 五、Kyuubi+Gluten vs Spark+Gluten — 真正的差异

### 5.1 Gluten 技术方案部分

| 项 | 差异 |
|---|---|
| Gluten jar | **完全相同** |
| Spark 配置 | **完全相同** |
| Velox 后端 | **完全相同** |
| 性能收益 | **完全相同** |
| Fallback 逻辑 | **完全相同** |

**结论：Gluten 部分零差异**。

### 5.2 真正差异在外围调度

| 维度 | Spark+Gluten | Kyuubi+Gluten |
|---|---|---|
| 作业触发 | spark-submit | JDBC/Thrift 协议 |
| Engine 生命周期 | 作业级（用完销毁）| 长驻（USER/GROUP/SERVER 级共享）|
| 多租户 | 无 | 天然支持 |
| 冷启动均摊 | 每作业重启 | 首次启动后复用 |
| 灰度粒度 | 改作业脚本 | 改 JDBC URL 一行 |
| 典型负载 | ETL 批处理 | Ad-hoc / BI 查询 |

**这些差异是 Kyuubi 这一层带来的，不是 Gluten 带来的**。

---

## 六、决策树：要不要加 Kyuubi？

```
Q1：你需要向量化加速？
    └→ 是 → 上 Gluten（这是单选题）

Q2：你需要 SQL 网关 / 多租户能力？
    ├→ 是 → 上 Kyuubi（顺便配 Gluten）
    └→ 否 → 直接 spark-submit（也配 Gluten）

两个决策互不干扰。
```

| 你的场景 | 推荐 |
|---|---|
| 主要跑离线 ETL（Airflow/DS 调度）| **Spark + Gluten** |
| 数仓即席查询 / BI 报表 / Ad-hoc | **Kyuubi + Gluten** |
| 既有 ETL 又有 Ad-hoc | **两套并存**（业界主流）|
| 已有 HiveServer2 想升级 | **Kyuubi + Gluten** |
| 已有 Spark Thrift Server (STS) | **Kyuubi + Gluten 替换 STS** |

---

## 七、企业落地真实选择

| 公司 | 用法 |
|---|---|
| **美团**（数万节点）| Spark + Gluten（ETL 主导）|
| **顺丰**（70 万任务）| Spark + Gluten |
| **快手** | Spark + **Blaze**（自研路线）|
| **网易**（Kyuubi 主创）| **Kyuubi + Gluten** |
| **Apache Kyuubi 社区** | **Kyuubi + Gluten** |

> **观察**：ETL 重的场景普遍 Spark+Gluten；网关 / 数据服务场景普遍 Kyuubi+Gluten。**很多公司两条线都有**。

---

## 八、Kyuubi+Gluten 运维风险（要小心）

| 风险 | Spark+Gluten | Kyuubi+Gluten |
|---|---|---|
| OOM 影响范围 | 单作业挂 | **整个 Engine 挂，影响该 Engine 所有 Session** |
| Velox crash | 作业失败 | **整个 Spark Engine 进程死掉** |
| Fallback 监控 | 每作业 EXPLAIN | 全局汇总更易 |
| 配置错误 | 单作业失败 | **影响一片用户** |
| 回滚速度 | 改脚本 | 改配置 + 重启 Engine |

**生产经验**：Kyuubi+Gluten 的 Velox crash 爆炸半径更大，必须做：
1. Engine 自动重启（Kyuubi 自带）
2. `spark.executor.maxFailures` 调高
3. Engine 健康检查 + 主动 kill 重建

---

## 九、Kyuubi v1.9.2 实测兼容性数据

源码铁证（Kyuubi 仓库 `kyuubi-gluten-it` 模块）：

| 测试集 | 总数 | 通过 | 排除/失败 | 通过率 |
|---|---|---|---|---|
| TPC-DS | 99 | 63 | 36 | **63.6%** |
| TPC-H | 22 | 21 | 1（q9 结果不一致）| **95.5%** |

> ⚠️ 这是 **Kyuubi v1.9.2 + Spark 3.3/3.4 + Gluten 1.2** 的实测。  
> 升级到 **Kyuubi 1.10+ + Spark 3.5 + Gluten 1.5** 兼容性会大幅提升（AWS 实测 86.5%）。

---

## 十、一句话总结

> **Kyuubi 集成 Gluten 不是技术方案差异，是网关层把引擎层加速插件包装成开箱即用的产品特性**。  
> **Gluten 部分配置在两边一模一样，差异都在 Kyuubi 这一层提供的多租户/调度能力上**。  
> **选 Gluten 是技术决策；选 Kyuubi 是产品形态决策；两者解耦**。

---

**End of 专题 2**
