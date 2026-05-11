# SOP：NM 关机对 Flink 作业的影响与操作手册（索引）

> 正文归档在 YARN 目录（因为操作主体是 YARN 侧的 NM 下线），本文件仅作为 Flink 知识库的索引入口。

**正文路径**：[../yarn/案例/SOP-NM节点关机-Flink作业零影响操作手册.md](../../yarn/案例/SOP-NM节点关机-Flink作业零影响操作手册.md)

## 快速导航

| 章节 | 内容 |
|---|---|
| § 0 | 一句话速查（紧急情况直接看这个）|
| § 1 | 影响分级 + 为什么 Graceful Decommission 对 Flink 无效 |
| § 2 | 关机前预检（5 分钟清单）|
| § 3 | 执行流程：Savepoint 路径 A / HA 自恢复路径 B |
| § 5 | 长期加固配置（flink-conf.yaml + yarn-site.xml）|
| § 6 | 常见坑与规避 |

## 核心结论（速记）

1. **永远不要对 Flink 用 `yarn rmadmin -refreshNodes -g <timeout>`**，它只对批作业有效
2. **正确姿势**：`refreshNodes`（不加 -g）隔离调度 + `flink stop -p` 做 Savepoint + 停 NM + 关机
3. **默认 10 分钟 AM 超时**是最大业务感知点，必须通过配置或主动 `applicationattempt -fail` 规避
4. **TM 复用**（`resourcemanager.taskmanager-timeout: 300000`）能把 JM 切换期间的恢复时间从 2min 压到 30s

## 关联文档

- [../../yarn/YARN故障排查决策树.md](../../yarn/YARN故障排查决策树.md)
- [Flink故障排查决策树.md](./Flink故障排查决策树.md)
- [案例/](./案例/) — 其他 Flink 故障案例

## 专项预案（不同版本/不同作业）

| 作业/场景 | 版本 | 预案文件 |
|---|---|---|
| tdata_sync | **Flink 1.13.1** ⚠️ | [案例/case-tdata-sync-1131-shutdown-plan.md](./案例/case-tdata-sync-1131-shutdown-plan.md) |

> 主 SOP § 8 提供了 1.13 / 1.14 / 1.15 / 1.17+ 的版本差异矩阵，选择合适的处置路径。

---

**作者**：eric ｜ **版本**：v1.0 / 2026-05-11
