# Linux/OS 功能地图（大数据运维视角）

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 核心能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **CPU 调度** | CFS 公平调度 / RT 实时调度 | `taskset` / `cgroups cpu.shares/cfs_quota` | CFS quota 硬限制会 throttle 大数据进程 | K8s limit.cores 就是 CFS quota |
| **内存管理** | 虚拟内存 + Page Cache + Swap | `/proc/meminfo` / `vm.swappiness` / `vm.overcommit_memory` | OOM Killer 可能杀关键进程 | 大数据节点 swappiness=1, overcommit_memory=1 |
| **磁盘 I/O** | 块设备读写 + I/O 调度器 | `iostat` / `iotop` / `blkio cgroup` | 机械盘 IOPS ~200；SSD ~100K | HDFS DataNode 用多盘 + deadline/noop 调度器 |
| **网络** | TCP/UDP 协议栈 + 网卡 | `ss` / `netstat` / `iptables` / `tc` | 单连接吞吐受 TCP window 限制 | 大数据调大 `net.core.somaxconn` + `tcp_max_syn_backlog` |
| **cgroups v1/v2** | 资源限制和隔离 | `/sys/fs/cgroup/` | v1 和 v2 API 不同 | YARN 用 v1；K8s 新版用 v2 |
| **namespace** | 进程/网络/挂载隔离 | `unshare` / Docker/K8s 自动创建 | 隔离有性能开销（尤其网络） | K8s Pod 网络 namespace = CNI 开销来源 |
| **文件系统** | ext4/xfs 文件系统 | `mkfs.xfs` / `mount` / `fstab` | ext4 单文件 16TB；xfs 支持更大 | 大数据推荐 xfs + noatime |
| **内核参数** | sysctl 调优 | `/etc/sysctl.conf` | 参数改错可能导致系统不稳定 | 改前备份；改后验证 |
| **进程管理** | systemd 管理服务 | `systemctl start/stop/status` | PID 1 问题（容器中） | 大数据服务用 systemd 托管 |
| **日志** | syslog / journald | `journalctl` / `/var/log/` | 日志量大需要 logrotate | 大数据节点必配 logrotate |

---

## 大数据节点关键内核参数

| 参数 | 建议值 | 说明 |
|------|--------|------|
| `vm.swappiness` | 1 | 尽量不用 swap |
| `vm.overcommit_memory` | 1 | 允许 overcommit（防止 fork 失败） |
| `net.core.somaxconn` | 65535 | TCP 监听队列 |
| `net.ipv4.tcp_max_syn_backlog` | 65535 | SYN 队列 |
| `net.core.rmem_max` | 16MB | TCP 接收缓冲区 |
| `net.core.wmem_max` | 16MB | TCP 发送缓冲区 |
| `fs.file-max` | 6553560 | 最大文件描述符 |
| `vm.max_map_count` | 262144 | mmap 区域数（ES 需要） |
| `kernel.pid_max` | 65536 | 最大 PID 数 |

---

*OS Expert | 功能地图 v1.0 | 2026-04-08*
