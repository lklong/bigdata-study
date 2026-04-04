# Apache Ranger — 权限管理框架

---

## 一、概述

Apache Ranger 是 Hadoop 生态的集中式权限管理框架，提供细粒度访问控制、数据脱敏、审计日志。

**在集群中的角色**：统一权限管控中心，控制谁能访问什么数据。

---

## 二、架构

```
Ranger Admin（Web UI + 策略管理 + 审计查看）
  │ 策略同步（周期性拉取）
  ↓
Ranger Plugin（嵌入各组件，执行鉴权）
  ├── HDFS Plugin    → NameNode
  ├── Hive Plugin    → HiveServer2
  ├── HBase Plugin   → RegionServer
  ├── Kafka Plugin   → Broker
  ├── Spark Plugin   → Kyuubi / Thrift Server
  └── YARN Plugin    → ResourceManager
  │ 审计日志
  ↓
Solr / Elasticsearch（审计存储）
```

---

## 三、核心能力

| 能力 | 说明 |
|------|------|
| 细粒度授权 | 库/表/列/行级别 |
| **列脱敏** | Partial mask（138****1234）/ Hash / Nullify / Custom |
| **行级过滤** | `dept_id = {USER.dept}` → 用户只看自己部门数据 |
| 审计日志 | 所有访问操作记录 |
| 标签策略 | 基于 Atlas 标签自动授权 |

**注意**：脱敏和行级过滤只对 HiveServer2 SELECT 生效。Hive CLI 和直接读 HDFS 不受控。

---

## 四、常见故障排查

### 权限不生效 → 4 步排查

1. **Plugin 同步**：Admin → Audit → Plugin Status → 最后同步时间
2. **策略冲突**：deny 优先级 > allow，检查是否有 deny 策略
3. **用户/组映射**：Settings → Users/Groups → 用户是否在正确的组
4. **审计日志**：Audit → Access → 搜索用户访问记录，看 Allowed/Denied

### 常见坑

| 现象 | 原因 | 解决 |
|------|------|------|
| 策略不生效 | Plugin 未同步 | 重启组件 |
| Hive CLI 不受控 | Ranger 只拦截 HS2 | 禁用 Hive CLI |
| HDFS 直接读绕过 | Hive Plugin 只管 SQL 层 | 同时配 HDFS Plugin |
| Admin 登不上 | DB 连接失败 | 检查 MySQL/PG |

---

## 五、与 LDAP/Kerberos 的关系

```
LDAP（用户目录）→ Ranger UserSync 同步用户/组
Kerberos（认证）→ 确认"你是谁"
Ranger（授权）→ 确认"你能干什么"
三者通常一起用：Kerberos 认证 + LDAP 用户管理 + Ranger 授权
```
