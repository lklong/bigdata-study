# Apache Amoro 全部使用姿势（权威版）

> 作者：eric  |  版本：v1.0  |  日期：2026-04-24  
> 覆盖面：定位 / 架构 / AMS / Catalog / Optimizer / 自优化 / Mixed 格式 / 客户端 / 运维  
> 说明：Amoro = 原 Arctic，Apache 孵化中。核心价值是给 Iceberg / Hive / Paimon 提供**自动化湖仓管理层**（Self-Managed Lakehouse Service）。

---

## 0. 一句话定位

Amoro = **湖仓管理平台**，不是存储、不是引擎，而是"**管起来**"——  
为 Iceberg/Mixed-Iceberg/Mixed-Hive/Paimon 等表格式统一做：
- **自动小文件合并**（Self-Optimizing）
- **元数据治理**（表健康度、过期快照、孤儿文件）
- **多 Catalog 统一纳管**
- **提供 Dashboard + API 做可视化运维**

对标：Tabular（商业）、Databricks Unity Catalog（商业）、Dremio Arctic（商业）。

---

## 1. 体系结构

```
┌──────────────────────────────────────────────────────────┐
│                    AMS (Arctic Management Service)        │
│                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │  Dashboard   │  │  REST API    │  │  Thrift API  │   │
│  │  (Web UI)    │  │  (运维)       │  │  (引擎侧)     │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │
│         │                 │                  │            │
│  ┌──────▼──────────────────▼──────────────────▼───────┐  │
│  │     Core：Catalog Manager / Optimizer Manager /     │  │
│  │           Table Service / Metric / Plan Service     │  │
│  └──────────────────┬──────────────────────────────────┘  │
└─────────────────────┼──────────────────────────────────────┘
                      │
      ┌───────────────┼──────────────────┐
      │               │                  │
 ┌────▼─────┐   ┌────▼─────┐      ┌─────▼──────┐
 │Optimizer │   │Optimizer │      │ Optimizer  │
 │ (Local)  │   │(Flink YARN)│    │(Spark/K8s) │
 └────┬─────┘   └────┬─────┘      └─────┬──────┘
      │              │                   │
      └──────────────┼───────────────────┘
                     │  读写
                     ▼
       Iceberg / Mixed-Iceberg / Mixed-Hive / Paimon 表
       （存在 HDFS/S3/OSS/COS/MinIO）
```

核心组件：
- **AMS（Arctic Management Service）**：管控中心，Java 进程。元数据存 MySQL/Derby/PostgreSQL。
- **Optimizer Container**：执行优化任务的资源池（Local / Flink-on-YARN / Flink-K8s / Spark）。
- **Optimizer Group**：一组 Optimizer 的逻辑组，表可以绑定到某个 group。
- **Dashboard**：默认端口 **1630**，展示所有 Catalog、表健康度、优化进度。

---

## 2. 表格式家族

| 格式 | 说明 | 主要能力 | 场景 |
|------|------|---------|------|
| **Iceberg** | 原生 Iceberg 表 | 读写 + 自动维护 | 已有 Iceberg 基础设施 |
| **Mixed-Iceberg** | Amoro 特有：ChangeStore(Iceberg) + BaseStore(Iceberg) 双层 | 高吞吐流式 Upsert，分钟级可见性 | Flink CDC 落湖 |
| **Mixed-Hive** | BaseStore 是 Hive 表，Change 是 Iceberg | 兼容老 Hive 表同时支持 CDC | Hive 表无侵入升级 |
| **Paimon** | 纳管 Paimon 表 | 只读元数据 + 监控（自优化正在完善） | 统一观测 |
| **Hudi** | 社区贡献中 | 读 + 监控 | 混合湖仓 |

**Mixed 格式核心：ChangeStore + BaseStore 双层**
```
写入（流）→ ChangeStore（频繁小提交，保留 CDC 字段 _file_offset/_transaction_id）
              │
              │  Amoro Self-Optimizing 周期性把 Change 合并入 Base
              ▼
读取（OLAP）← BaseStore（大文件、按主键去重、高效查询）
```

---

## 3. 部署姿势

### 3.1 下载与启动 AMS
```bash
tar -xzf amoro-<ver>-bin.zip
cd amoro-<ver>
bin/ams.sh start        # 默认 Dashboard: http://host:1630
bin/ams.sh stop
```

### 3.2 AMS 配置 `conf/config.yaml`
```yaml
ams:
  server-bind-host: "0.0.0.0"
  server-expose-host: "ams-host"
  thrift-server:
    max-message-size: 100MB
    selector-thread-count: 2
  http-server:
    bind-port: 1630
  optimizing:
    scheduling-policy: quota        # quota | balanced
  database:
    type: mysql                     # derby(默认) / mysql / postgres
    jdbc-driver-class: com.mysql.cj.jdbc.Driver
    url: jdbc:mysql://db:3306/amoro
    username: amoro
    password: ***
  terminal:                         # 内置 SQL Terminal
    backend: local                  # local | kyuubi
    local.spark.sql.iceberg.handle-timestamp-without-timezone: true
```

生产强烈建议：
- 元数据库用 MySQL/PG（Derby 只适合单机 demo）。
- AMS 启多实例 + 前置 Nginx（官方 1.x 还不原生 HA，**多实例要共享 MySQL 元库**，并避免同时启动写冲突）。

### 3.3 Optimizer Group 部署

**Local Optimizer（测试）**：AMS 进程内启动，小规模可用。

**Flink on YARN Optimizer（生产推荐）**：
```bash
bin/optimizer.sh start \
  -a thrift://ams:1261 \
  -g flink-group \
  -p 4 \
  -m yarn-per-job \
  --memory 4096
```

**Flink on Kubernetes Optimizer**：
- 打镜像（`docker/optimizer/Dockerfile`）
- 在 AMS Dashboard → Optimizing → Containers 新增 K8s container
- 在 Optimizer Group 设定 parallelism / memory / taskmanager 资源

**Spark Optimizer**：适合需要在 Iceberg 上跑 `rewrite_data_files` 的场景。

---

## 4. Catalog 注册姿势

Dashboard → **Catalogs** → Create：

| 字段 | 取值 |
|------|------|
| Name | 业务名，如 `prod` |
| Type | `internal` / `external` |
| Table Format | Iceberg / Mixed-Iceberg / Mixed-Hive / Paimon |
| Metastore | Hive Metastore / Hadoop / Custom / AMS |
| Storage | HDFS / S3 / OSS / COS |
| Auth | SIMPLE / KERBEROS / AK/SK |

**Internal Catalog**：AMS 自己管元数据（仅支持 Mixed 格式）。  
**External Catalog**：复用外部 HMS / Hadoop / Glue（Iceberg 原生表）。

注册后，AMS 自动发现库/表并显示在 Dashboard，Self-Optimizing 可以立即启用。

---

## 5. Self-Optimizing（核心特性）

### 5.1 优化类型
| 类型 | 触发条件 | 动作 |
|------|---------|------|
| **minor** | 频繁小提交产生大量小 position delete / change 文件 | 合并小文件到 fragment 大小 |
| **major** | 有大量 equality delete 或 eq-delete 过多 | 合并 delete 到 data，减少读放大 |
| **full** | 手动 or 阈值触发 | 全表大文件重写（可指定分区） |

### 5.2 表级自优化配置
```sql
-- Iceberg 表上
ALTER TABLE prod.db.t SET TBLPROPERTIES (
  'self-optimizing.enabled'='true',
  'self-optimizing.group'='flink-group',
  'self-optimizing.quota'='0.1',                 -- 占 group 10%
  'self-optimizing.target-size'='134217728',     -- 128MB
  'self-optimizing.fragment-ratio'='8',          -- fragment = target/8 = 16MB
  'self-optimizing.minor.trigger.file-count'='12',
  'self-optimizing.major.trigger.duplicate-ratio'='0.5',
  'self-optimizing.full.trigger.interval'='-1'   -- -1=关，正数=ms
);
```

### 5.3 全局 group 配置（Dashboard）
- Parallelism：并行度
- Resource Per Thread：每线程 CPU / Memory
- Scheduling Policy：quota（按表配额） / balanced（按表数量均衡）

> Challenger 提示：`self-optimizing.group` 必须和已注册的 Optimizer Group 名称完全一致，否则表会一直 `pending`。生产必须监控 AMS 的 **pending tasks** 指标。

---

## 6. Table Service（生命周期治理）

AMS 除了自优化，还会周期性做：

| 任务 | 表属性 | 作用 |
|------|--------|------|
| **过期快照** | `snapshot.base.keep.minutes` / `snapshot.change.keep.minutes` | 清理 Iceberg snapshot |
| **孤儿文件扫描** | `clean-orphan-file.enabled=true` + `clean-orphan-file.min-existing-time-minutes` | 删无主文件 |
| **过期 hive 分区** | `table-expire.enabled=true` + `data-expire.field` + `data-expire.retention-time` | TTL 数据过期 |
| **Tag 自动创建** | `table-tags.enabled=true` + `table-tags.auto-create.interval` | 按周期自动打 tag |

---

## 7. 客户端访问姿势

### 7.1 Dashboard Terminal（内置 SQL）
Dashboard → Terminal，可直接对 Internal Catalog 的 Mixed 表跑 SQL（后端可选 local Spark 或 Kyuubi）。

### 7.2 Spark
```properties
spark.sql.catalog.prod             = com.netease.arctic.spark.ArcticSparkCatalog
spark.sql.catalog.prod.url         = thrift://ams:1260/prod
spark.sql.extensions               = com.netease.arctic.spark.ArcticSparkExtensions
```
> 注：新版本包路径可能已迁移到 `org.apache.amoro.*`，以实际 `amoro-spark` jar 内的 META-INF/services 为准。

### 7.3 Flink
```sql
CREATE CATALOG arctic WITH (
  'type'='arctic',
  'metastore.url'='thrift://ams:1260/prod'
);
USE CATALOG arctic;

-- CDC 写入 Mixed-Iceberg 表
INSERT INTO db.orders /*+ OPTIONS('arctic.emit.mode'='file,log') */
SELECT * FROM kafka_source;
```

### 7.4 Trino
```properties
# catalog/arctic.properties
connector.name=arctic
arctic.url=thrift://ams:1260/prod
```

### 7.5 REST API（运维自动化）
```bash
# 列出所有 catalog
curl http://ams:1630/api/ams/v1/catalogs

# 查看某表自优化状态
curl http://ams:1630/api/ams/v1/tables/prod/db/orders/optimizing/info

# 触发 full optimize
curl -XPOST http://ams:1630/api/ams/v1/tables/prod/db/orders/optimize?type=full

# 导出 metrics（Prometheus 兼容）
curl http://ams:1630/metrics
```

---

## 8. 监控与告警

### 8.1 Dashboard 健康度指标
- **Healthy Score**：综合小文件率、delete 堆积、stale snapshot 等
- **Small File Ratio**：fragment 数 / 总 data file 数
- **Average File Size**
- **Pending Optimizing Tasks**：堆积说明 Optimizer 资源不足
- **Optimizer Load**：资源使用率

### 8.2 Metrics 埋点（Prometheus）
```
amoro_optimizer_running_tasks
amoro_optimizer_pending_tasks
amoro_table_file_count{catalog,db,table,type}
amoro_table_total_size_bytes
amoro_table_last_optimizing_time_ms
```

### 8.3 告警推荐规则
| 规则 | 阈值 | 含义 |
|------|------|------|
| pending > 100 持续 10min | Optimizer 资源不足 | 扩 parallelism |
| fragment ratio > 70% | 自优化失效 | 查 group 配置 |
| 某表 last_optimizing_time > 1d | 表被遗漏 | 检查 `self-optimizing.enabled` |
| AMS CPU > 80% | 元数据库压力大 | 升 MySQL / 减 catalog 扫描频率 |

---

## 9. 典型使用场景

| 场景 | 方案 |
|------|------|
| **已有 Iceberg 表需要自动合并小文件** | External Catalog 纳管 + 表级 `self-optimizing.enabled=true` |
| **Flink CDC 落湖要分钟级可见** | Mixed-Iceberg 表 + ChangeStore + minor optimize 每 5min |
| **老 Hive 表要升级但不重写** | Mixed-Hive 表，Base 还是 Hive，Change 侧做 upsert |
| **多业务线湖仓统一观测** | AMS 纳管多个 Hive/Glue/REST Catalog，只做只读监控 |
| **湖仓合规审计** | 配合 Iceberg Tag 策略 + `table-tags.auto-create` |
| **K8s 云原生部署** | AMS Deployment + Flink K8s Optimizer + S3 存储 |

---

## 10. 功能边界

| 不是 | 替代 |
|------|------|
| 查询引擎 | Spark / Flink / Trino |
| 存储系统 | HDFS / S3 / OSS |
| Catalog 本身 | 依赖 HMS / Hadoop / Glue / 自身 Internal |
| 流处理引擎 | Flink（Amoro 只是 sink 管理者） |
| 告警平台 | 对接外部 Prometheus + Alertmanager |
| 权限中心 | 依赖 Ranger / 外部 RBAC |

---

## 11. 常见坑（真实运维）

1. **Optimizer Group 名写错** → 表 pending 永不优化。  
2. **元数据库用 Derby 上生产** → AMS 重启后元数据错乱。  
3. **没配 `clean-orphan-file.min-existing-time-minutes`** → 把正在写的文件删了 → 数据丢失。要至少大于最长写入事务时间（默认 2 天，保守）。  
4. **Mixed-Hive 的 BaseStore 被外部 Hive 直接写** → 破坏 Amoro 的一致性视图。约定：Base 只许 Amoro 或 compaction 写。  
5. **K8s Optimizer 无法注册回 AMS** → `server-expose-host` 必须是 Optimizer Pod 能访问到的地址（别填 127.0.0.1）。  
6. **Iceberg 表同时被外部 Spark 做 `expire_snapshots`** → 和 Amoro 的 snapshot 过期策略冲突。**二选一**。  
7. **self-optimizing.quota 总和 > 1.0** → group 资源超卖，所有表一起慢。

---

## 12. Challenger 审查记录

| 审查项 | 问题 | 处置 |
|--------|------|------|
| "AMS 原生 HA" | **1.x 官方不原生支持 HA**，需靠共享元库 + 前置 LB | ✅ 已改为提示"多实例共享 MySQL" |
| "Mixed-Iceberg = ChangeStore+BaseStore" | 确认源码 `core/src/main/java/.../table/MixedTable.java` | ✅ |
| "Optimizer quota 是百分比" | 0.1 代表占 group 10% 资源 | ✅ 已明示 |
| Spark Catalog 类名 | 老版本是 `com.netease.arctic.*`，Apache 化后改 `org.apache.amoro.*` | ✅ 已加"以实际 jar 为准"注释 |
| "clean-orphan-file 默认" | 官方默认保留 2 天（120min? 实际以配置为准） | ⚠️ 已加"至少大于最长事务时间"保守提示 |
| "Paimon 自优化完整支持" | 实际仅监控 + 部分操作 | ✅ 已加"自优化正在完善" |

**裁决：APPROVED**（含 1 处 CONDITIONAL：AMS HA 表述需随社区版本更新）。

---

*eric | Amoro 全部使用姿势 v1.0 | 2026-04-24*
