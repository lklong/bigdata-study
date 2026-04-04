# Linux — 操作系统基础（大数据运维必精通）

---

## 一、概述

Linux 是大数据集群所有组件的运行平台。**不懂 Linux 性能诊断，上层排障就是盲人摸象。**

**核心原则**：排障时先看 OS 层（CPU/内存/磁盘/网络），再看组件层。很多组件"异常"的根因在 OS。

---

## 二、性能诊断四板斧：CPU → 内存 → 磁盘 → 网络

### 2.1 CPU 诊断

**从宏观到微观**：

```bash
# 1. 整体负载（1/5/15分钟平均）
uptime
# load average > CPU核数 = 过载

# 2. CPU 使用分布
top -bn1 | head -5
# 关注：%us(用户)  %sy(内核)  %wa(IO等待)  %id(空闲)
# %wa 高 → 磁盘瓶颈   %us 高 → 计算密集   %sy 高 → 内核调用频繁

# 3. 每个 CPU 核使用率
mpstat -P ALL 1 3

# 4. 找出 CPU 占用最高的进程
top -bn1 -o %CPU | head -20

# 5. 找出 CPU 占用最高的线程（定位到 Java 线程）
top -Hp <pid>
# 然后 printf "%x\n" <线程号> 转十六进制 → jstack <pid> | grep <十六进制>
```

### 2.2 内存诊断

```bash
# 1. 总体内存（关注 available，不是 free）
free -h
# available = free + buffer/cache 中可回收的部分

# 2. 谁在用内存
ps aux --sort=-%mem | head -20

# 3. 详细内存分布
cat /proc/meminfo | head -10

# 4. 是否在用 swap（大数据集群 swap 应该关掉或设很低）
free -h | grep Swap
swapon -s

# 5. OOM 记录
dmesg | grep -i "oom\|out of memory\|killed process"
```

### 2.3 磁盘诊断

```bash
# 1. 磁盘空间
df -h

# 2. 哪个目录占用最多
du -sh /* | sort -rh | head -10
du -sh /data/* | sort -rh | head -10

# 3. 磁盘 IO 性能（关键！）
iostat -x 1 3
# 关注：%util(使用率) > 90% = 磁盘瓶颈
#        await(平均等待) > 10ms = IO 慢
#        r/s, w/s = 读写 IOPS

# 4. 哪个进程在做 IO
iotop -oP

# 5. 磁盘健康
smartctl -a /dev/sda   # 需要 smartmontools
dmesg | grep -i "error\|I/O\|sector\|fail"
```

### 2.4 网络诊断

```bash
# 1. 网络连接统计
ss -s

# 2. 连接状态分布（TIME_WAIT 过多说明短连接频繁）
ss -ant | awk '{print $1}' | sort | uniq -c | sort -rn

# 3. 网络流量
sar -n DEV 1 3
# 或
iftop -n   # 实时流量

# 4. 端口监听
netstat -tlnp
# 或
ss -tlnp

# 5. 网络连通性
ping target-host
traceroute target-host
telnet target-host port

# 6. DNS 解析
nslookup hostname
dig hostname
```

---

## 三、进程与文件诊断

```bash
# 进程查看
ps aux | grep [关键字]
ps -ef --forest                    # 进程树

# 打开的文件/连接
lsof -p <pid> | wc -l             # 进程打开的文件数
lsof -i :8088                     # 谁在用这个端口
lsof +D /data/                    # 谁在用这个目录

# 系统调用跟踪（高级排障）
strace -p <pid> -f -c             # 统计系统调用
strace -p <pid> -e trace=open     # 跟踪文件打开

# 系统日志
dmesg | tail -50                   # 内核日志
journalctl -xe                     # systemd 日志
tail -f /var/log/messages          # 系统日志
```

---

## 四、OS 内核参数调优（大数据集群必调）

### 4.1 必须调整的参数

```bash
# ===== /etc/sysctl.conf =====

# 关闭 swap（大数据集群核心！JVM 用 swap = 性能灾难）
vm.swappiness = 1                  # 设 0 或 1，几乎不用 swap

# 文件描述符
fs.file-max = 6553600             # 系统级文件描述符上限

# 虚拟内存
vm.overcommit_memory = 1          # 允许 overcommit（Redis/Spark 需要）
vm.dirty_ratio = 40               # 脏页占内存 40% 开始强制写盘
vm.dirty_background_ratio = 10    # 脏页占 10% 开始后台写盘

# 网络参数
net.core.somaxconn = 65535        # 监听队列长度
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_fin_timeout = 15     # TIME_WAIT 回收加速
net.ipv4.tcp_tw_reuse = 1         # 允许 TIME_WAIT 复用

# 生效
sysctl -p
```

### 4.2 用户级限制

```bash
# ===== /etc/security/limits.conf =====

# Hadoop/Spark 用户
hadoop  soft  nofile  1048576      # 打开文件数
hadoop  hard  nofile  1048576
hadoop  soft  nproc   131072       # 最大进程数
hadoop  hard  nproc   131072
*       soft  memlock unlimited    # 内存锁定（HBase 需要）
*       hard  memlock unlimited
```

### 4.3 磁盘调优

```bash
# 关闭 atime（减少无意义的磁盘写入）
# /etc/fstab 中添加 noatime
/dev/sdb1  /data  ext4  defaults,noatime  0 0

# 调度器（SSD 用 noop/none，HDD 用 deadline）
echo deadline > /sys/block/sda/queue/scheduler    # HDD
echo none > /sys/block/nvme0n1/queue/scheduler    # SSD

# 预读（大数据场景适当调大）
blockdev --setra 4096 /dev/sda
```

### 4.4 大页内存（Transparent Huge Pages）

```bash
# 大数据集群建议关闭 THP（会导致 JVM GC 停顿变长）
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# 写入 /etc/rc.local 持久化
```

---

## 五、排障速查表

| 现象 | 首先检查 | 命令 |
|------|----------|------|
| 系统卡顿 | CPU 负载 | `uptime` + `top` |
| 进程被杀 | OOM | `dmesg \| grep -i oom` |
| 磁盘满 | 空间 | `df -h` + `du -sh` |
| IO 慢 | 磁盘利用率 | `iostat -x 1` |
| 网络不通 | 连通性 | `ping` + `telnet` + `ss` |
| 文件打不开 | 文件描述符 | `ulimit -n` + `lsof -p <pid> \| wc -l` |
| Swap 高 | swappiness | `free -h` + `cat /proc/sys/vm/swappiness` |
