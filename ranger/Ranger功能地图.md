# Apache Ranger 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **集中授权** | 统一管理 HDFS/Hive/HBase/Kafka/... 的权限 | Ranger Admin Web UI / REST API 创建策略 | 策略生效有延迟（30s 拉取间隔） | 紧急授权可手动刷新 Plugin |
| **策略模型** | Allow/Deny + 条件（IP/时间/标签） | Web UI 创建策略 | Deny 优先于 Allow | 策略冲突时 Deny 赢 |
| **列级权限** | 控制用户可见的列 | Hive/Spark Plugin | 仅 SQL 引擎支持 | HDFS 级别仍可直接读数据文件 |
| **数据脱敏** | Column Masking | 策略类型 = Masking | 支持 mask/hash/null/custom | 用户无感知 |
| **行级过滤** | Row Filter | 策略类型 = RowFilter，配 WHERE 条件 | 条件表达式有限 | 复杂过滤考虑视图 |
| **审计** | 记录所有访问 | 自动写入 Solr/ES/HDFS | 审计量大需要独立存储 | 合规必须 |
| **标签策略** | 基于 Atlas 分类标签授权 | `Tag-Based Policy` | 需要 Apache Atlas | 自动化分类授权 |
| **Plugin 机制** | 嵌入各组件进程内鉴权 | 部署 Ranger Plugin 到对应组件 | Plugin 更新需重启组件（部分支持热加载） | 策略缓存在本地，Admin 挂了仍可鉴权 |

**边界**: 不做认证（需要 Kerberos/LDAP）；不做数据加密（需要 HDFS TDE/KMS）

---
