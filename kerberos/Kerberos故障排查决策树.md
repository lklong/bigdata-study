# Kerberos 故障排查决策树

---

```
认证失败
├── "Clock skew too great"
│   └── 时钟偏差 > 5 分钟 → ntpdate 同步
├── "Pre-authentication information was invalid"
│   └── 密码错误 / keytab 过期 → 重新生成 keytab
├── "Client not found in Kerberos database"
│   └── Principal 不存在 → kadmin 检查 / 创建
├── "Server not found in Kerberos database"
│   └── Service principal 的 hostname 不匹配 → 检查 DNS
├── "Ticket expired"
│   └── TGT 过期 → kinit 重新获取
├── "No valid credentials provided" (GSSException)
│   ├── 没有 kinit → kinit -kt keytab principal
│   ├── keytab 文件权限不对 → chmod 400
│   └── Delegation Token 过期 → 续期
└── 跨域认证失败
    ├── krbtgt principal 密码不一致 → 两个 KDC 重新同步
    └── capaths 配置缺失 → 添加域路由
```

---

---

*Kerberos Expert | 2026-04-08*
