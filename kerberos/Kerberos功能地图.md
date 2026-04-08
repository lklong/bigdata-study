# Kerberos 功能地图

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **身份认证** | 基于票据的三方认证 | `kinit principal` / keytab 自动认证 | 不做授权（只管你是谁） | 配合 Ranger/ACL 做授权 |
| **票据管理** | TGT + Service Ticket | `kinit` 获取 TGT → 自动获取 ST | TGT 有效期默认 10h | 长任务要自动续期 |
| **Keytab** | 免密认证文件 | `kinit -kt keytab principal` | Keytab 泄漏 = 密码泄漏 | 权限 400, 定期轮换 |
| **Delegation Token** | 给子任务传递认证 | Spark/MR 自动获取和传递 | Token 有有效期 | 长任务需要 Token 续期机制 |
| **跨域信任** | 多 KDC 间信任 | `krbtgt/REALM_B@REALM_A` | 配置复杂；需要双方 KDC 管理员配合 | 密码必须一致 |
| **SPNEGO** | HTTP 认证 | Web UI (NN/RM/HS2) 通过浏览器 Kerberos 认证 | 浏览器需配置 | Knox 网关简化 |

**边界**: 只管认证不管授权；需要 NTP 时钟同步（误差 < 5 分钟）；KDC 是单点

---
