# Amoro (原 Arctic) 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **Self-Optimizing** | 自动小文件合并 + 排序 | AMS Dashboard 配置 + 表属性 | 需要独立部署 AMS + Optimizer | 流式表必开 |
| **Mixed-Iceberg** | ChangeStore + BaseStore 混合存储 | Flink 写 Change / Spark 读 MOR | Change 累积太多影响读性能 | 及时 Compaction |
| **多格式管理** | 管理 Iceberg / Hive / Paimon 表 | AMS 注册 Catalog | 不同格式支持程度不同 | Iceberg 最完整 |
| **Dashboard** | Web UI 监控表健康度 | `http://ams:1630` | 无告警通知功能 | 配合外部监控 |
| **Optimizer** | 执行优化任务的进程 | Flink/Spark/Local Optimizer | 需要计算资源 | 按表数量规划 Optimizer 数 |

**边界**: 不是查询引擎（不能执行 SQL）；不是存储层（管理层）

---

