# YARN 故障排查决策树

---

## 1. 应用提交失败

```
提交失败
├── "Application rejected"
│   ├── 队列满 → yarn queue -status queueName
│   ├── 用户无权限 → 检查队列 ACL
│   └── 资源超限 → 调小 AM 资源 / 调大队列
├── "Container launch failed"
│   ├── 节点磁盘满 → 检查 NM 本地目录
│   ├── 节点被标记 UNHEALTHY → yarn node -list -all
│   └── Java 版本不对 → 检查 NM 上的 JAVA_HOME
└── RM 无响应
    ├── RM 挂了 → 检查 RM 进程和日志
    └── RM HA 切换中 → 等待切换完成
```

## 2. 应用运行中异常

```
运行异常
├── Container 被杀
│   ├── "Container killed for exceeding memory"
│   │   ├── 物理内存超限 → 调大 Container memory
│   │   └── 虚拟内存超限 → 关闭 vmem-check 或调大 vmem-pmem-ratio
│   ├── 抢占 → 低优队列被高优抢 → 检查 preemption 配置
│   └── NM 重启 → 检查 NM 日志
├── 资源等待
│   ├── Pending containers 长期不分配 → 队列资源不足
│   ├── 数据本地性等待 → 延迟调度超时 → 调小 locality.delay
│   └── 节点标签不匹配 → 检查 node label 配置
└── AM 挂了
    ├── AM OOM → 调大 am.resource.mb
    ├── AM 心跳超时 → GC 暂停 / 网络问题
    └── AM 重试超过上限 → yarn.resourcemanager.am.max-attempts
```

## 3. 节点问题

```
节点问题
├── NM 标记 UNHEALTHY
│   ├── 磁盘健康检查失败 → yarn.nodemanager.disk-health-checker
│   ├── 本地目录不可用 → 检查 yarn.nodemanager.local-dirs
│   └── 日志目录满 → 清理 + logrotate
├── NM 掉线
│   ├── 进程挂了 → 重启
│   ├── 心跳超时 → 网络 / NM GC
│   └── 被退役 → 检查 yarn.resourcemanager.nodes.exclude-path
└── NM 资源利用率低
    └── 配置的 resource.memory-mb / cpu-vcores 太小 → 调大
```

---

*YARN Expert | 故障排查决策树 v1.0 | 2026-04-08*
