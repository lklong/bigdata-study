# LDAP 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **用户目录** | 集中存储用户/组/组织架构 | `ldapsearch -h host -b "dc=example,dc=com" "(uid=bob)"` | 读优化设计，写性能差 | 频繁写入场景不适合 |
| **身份认证** | LDAP Bind 验证密码 | 应用配置 LDAP 连接 → `bind(dn, password)` | 明文传输密码（需 TLS/LDAPS） | 必须用 LDAPS (636 端口) |
| **组管理** | 用户分组 | `memberOf` / `groupOfNames` | 嵌套组查询性能差 | 扁平化组结构 |
| **Hive/Kyuubi 集成** | HS2/Kyuubi LDAP 认证 | `hive.server2.authentication=LDAP` + 配 LDAP URL | 仅做认证，不做授权 | 授权用 Ranger |
| **Ranger UserSync** | 同步 LDAP 用户/组到 Ranger | Ranger UserSync 进程 | 同步有延迟（默认 5 分钟） | 新用户需等待同步 |

**边界**: 只管用户目录和认证；不做细粒度授权；不适合高并发写入

---
