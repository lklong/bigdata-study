# OS 内核 — 操作系统层面深度调优

---

## 一、概述

操作系统是所有应用的地基。大数据集群的性能瓶颈经常不在组件层，而在 OS 层：文件描述符不够、swap 导致 GC 变慢、TCP 参数不合理。

**核心原则**：部署大数据集群前，先把 OS 参数调好。事后调比事前调代价大 10 倍。

---

## 二、大数据集群 OS 调优清单（部署前必做）

### 2.1 内存管理

```bash
# ===== /etc/sysctl.conf =====

# 【最关键】关闭/最小化 swap
# JVM 用了 swap = GC 停顿从毫秒变成秒，直接灾难
vm.swappiness = 1

# 脏页策略（控制磁盘写入节奏）
vm.dirty_ratio = 40                # 脏页占内存 40% → 强制写盘
vm.dirty_background_ratio = 10     # 脏页占 10% → 后台异步写盘
vm.dirty_expire_centisecs = 3000   # 脏页 30s 后过期

# 允许 overcommit（Spark/Redis 需要 fork 大进程）
vm.overcommit_memory = 1

# OOM 策略
vm.oom_kill_allocating_task = 1    # OOM 时杀申请内存的进程

# 关闭透明大页（THP）— 导致 JVM GC 停顿不稳定
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

### 2.2 文件系统

```bash
# 文件描述符上限（大数据组件打开大量文件）
fs.file-max = 6553600

# /etc/security/limits.conf
hadoop  soft  nofile  1048576
hadoop  hard  nofile  1048576
hadoop  soft  nproc   131072
hadoop  hard  nproc   131072
*       soft  memlock unlimited
*       hard  memlock unlimited

# 挂载选项（/etc/fstab）
# noatime: 不记录访问时间，减少无意义写入
# nodiratime: 同上，目录级别
/dev/sdb1  /data  ext4  defaults,noatime,nodiratime  0 0

# IO 调度器
# SSD → noop/none    HDD → deadline
echo deadline > /sys/block/sda/queue/scheduler

# 预读（大数据顺序读多，调大预读）
blockdev --setra 4096 /dev/sda    # 4096 扇区 = 2MB
```

### 2.3 网络参数

```bash
# ===== /etc/sysctl.conf =====

# 连接队列
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# TCP 缓冲区
net.core.rmem_max = 16777216       # 16MB
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TIME_WAIT 优化
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# 端口范围（大量短连接时需要更多端口）
net.ipv4.ip_local_port_range = 1024 65535

# TCP keepalive（检测死连接）
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
```

### 2.4 其他

```bash
# NTP 时间同步（Kerberos 强制要求 <5min 偏差）
timedatectl set-ntp true
# 或
ntpd / chronyd 持续同步

# hostname 配置（Hadoop/Kerberos 依赖正确的主机名解析）
# /etc/hosts 中每个节点都必须有所有集群节点的映射
# hostname 不能用 localhost

# 防火墙（生产环境通常关闭内网防火墙）
systemctl stop firewalld
systemctl disable firewalld

# SELinux（大数据集群通常关闭）
setenforce 0
# /etc/selinux/config → SELINUX=disabled
```

---

## 三、OS 层面排障速查

### 3.1 系统整体健康检查（一键）

```bash
echo "===== 负载 =====" && uptime
echo "===== 内存 =====" && free -h
echo "===== 磁盘 =====" && df -h
echo "===== IO =====" && iostat -x 1 1
echo "===== 网络连接 =====" && ss -s
echo "===== OOM记录 =====" && dmesg | grep -i "oom\|killed" | tail -5
echo "===== Swap =====" && swapon -s
echo "===== 文件描述符 =====" && cat /proc/sys/fs/file-nr
```

### 3.2 常见 OS 层问题 → 上层表现

| OS 问题 | 上层组件表现 | 排查 |
|---------|-------------|------|
| Swap 使用高 | JVM GC 停顿长、服务超时 | `free -h` + `vmstat 1` |
| 磁盘满 | 日志写失败、服务无法启动 | `df -h` + `du -sh` |
| IO util 100% | HDFS 读写慢、HBase 写入超时 | `iostat -x 1` |
| 文件描述符耗尽 | "Too many open files" | `ulimit -n` + `lsof -p` |
| OOM Killer | 进程被杀、服务突然消失 | `dmesg \| grep oom` |
| 时钟不同步 | Kerberos 失败、HBase Region 切换异常 | `ntpstat` + `timedatectl` |
| TCP TIME_WAIT 堆积 | 新连接建立慢 | `ss -ant \| grep TIME-WAIT \| wc -l` |
| 网络分区 | ZK 选举失败、HDFS HA 脑裂 | `ping` + `traceroute` |

---

## 四、大数据集群 OS 检查清单（部署前核对）

- [ ] `vm.swappiness = 1`
- [ ] THP 关闭
- [ ] `fs.file-max = 6553600`
- [ ] `ulimit -n` ≥ 1048576
- [ ] `ulimit -u` ≥ 131072
- [ ] 磁盘挂载 noatime
- [ ] IO 调度器正确（SSD→none, HDD→deadline）
- [ ] NTP 时间同步
- [ ] hostname 正反向解析一致
- [ ] 防火墙关闭（内网）
- [ ] SELinux 关闭
- [ ] TCP 参数已调优
- [ ] 数据盘和日志盘分离
