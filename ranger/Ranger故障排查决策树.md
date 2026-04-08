# Ranger 故障排查决策树

---

```
权限问题
├── 策略不生效
│   ├── Plugin 没加载 → 检查组件日志 grep "ranger"
│   ├── 策略还没拉取到 → 等 30s / 手动刷新 Plugin
│   ├── service name 不匹配 → Ranger Admin 和 Plugin 配置对齐
│   └── 策略优先级冲突 → Deny 优先于 Allow，检查 Deny 策略
├── 审计日志不全
│   ├── Solr/ES 挂了 → 检查审计后端
│   ├── 审计队列满 → 调大 batch size
│   └── Plugin 没配审计 → 检查 ranger-*-audit.xml
├── UserSync 不同步
│   ├── LDAP 连不上 → 检查 LDAP URL / 认证
│   ├── 同步间隔太长 → 调小 sync interval
│   └── 用户组映射不对 → 检查 groupSearchFilter
└── Ranger Admin 无法访问
    ├── 进程挂了 → 重启
    ├── DB 连不上 → 检查 MySQL/PG
    └── 端口被占 → 默认 6080
```

---

---

*Ranger Expert | 2026-04-08*
