# 一键 Bench：给个 IP 就出 2×2 矩阵报告

> **作者**：Eric（豹纹）  
> **日期**：2026-05-24  
> **目标**：本地一条命令 `./oneshot.sh <master_ip>`，**远端集群从 0 到 2×2 矩阵报告自动跑完**。  
> **原则**：大哥只给入口 IP，**其他全自动探测、自动决策、自动执行**。

---

## 一、最简使用（90% 场景）

### Case 1：取已跑过 Bench 的报告（5 秒）

```bash
cd bench-toolkit/
./oneshot.sh 62.234.130.135 report
```

输出到 `../reports/<ip>_<时间戳>_2x2_matrix_report.md` + `duration_*.csv`。

### Case 2：环境已就绪，只跑 Bench（30 分钟）

```bash
./oneshot.sh 62.234.130.135 bench all       # HDFS + cosn 全跑
./oneshot.sh 62.234.130.135 bench hdfs      # 只 HDFS
./oneshot.sh 62.234.130.135 bench cosn      # 只 cosn
```

### Case 3：全新集群从 0 到出报告（45-60 分钟）

```bash
./oneshot.sh 62.234.130.135                 # 默认 all：体检 + 装环境 + 跑 Bench + 出报告
```

### Case 4：只体检看现状（10 秒）

```bash
./oneshot.sh 62.234.130.135 inspect
```

---

## 二、5 个 Action 详解

| Action | 做什么 | 耗时 | 何时用 |
|---|---|---|---|
| `inspect` | 远端体检，输出 env.json | 10s | 看新集群有啥 |
| `install` | 体检 + 缺啥装啥（JDK11/Spark/Gluten + toolkit 部署） | 5-15 分钟 | 新集群准备 |
| `bench [all/hdfs/cosn]` | 跑 Bench + 出报告 | 15-45 分钟 | 已装好环境 |
| `report` | 只拉远端已有报告 | 5 秒 | 看历史结果 |
| `all`（默认） | 上述全部 | 45-60 分钟 | 新集群全自动 |

---

## 三、内部架构（4 阶段）

```
[本地 Mac]  ./oneshot.sh <IP> [action]
   │
   │ 1. tar 打包 toolkit 到 /tmp/bench-toolkit-local-$$（避开中文路径）
   │ 2. ssh + scp 推送到远端 master /tmp/bench-toolkit/
   ↓
[远端 master]
   │
   ├── Stage 1 cluster_inspect.sh  → 自动探测：
   │   - JDK 11 路径
   │   - Hadoop / Hive 版本
   │   - Spark 3.5 是否就位
   │   - Gluten jar 是否就位
   │   - YARN worker 列表（自动从 yarn node -list 抓）
   │   - cosn 可用性
   │   - bench 工作目录是否已部署
   │   产物：/tmp/env.json
   │
   ├── Stage 2 install_env.sh      → 按 env.json 决策：
   │   - 缺 JDK11 → wget Kona11 + tar -x + 软链 /usr/local/jdk
   │   - worker SSH 互通 → 批量装 JDK11 到所有 worker
   │   - 缺 Spark 3.5 → 用本地 spark.tar.gz 或 cosn 上的 EMR 包
   │   - 缺 Gluten → wget Apache snapshot
   │   - 部署 bench-toolkit 到 /home/hadoop/bench/
   │   - 自动改 DRIVER_HOST 为本机内网 IP
   │
   ├── Stage 3 run_bench.sh        → 全自动跑：
   │   - 步骤 1：HDFS 数据生成（如果 HDFS 没数据，自动 ./gen_all.sh all）
   │   - 步骤 2：HDFS Bench（native + gluten）
   │   - 步骤 3：distcp HDFS → cosn（如果 cosn 没数据）
   │   - 步骤 4：cosn 建外部表 bench_cosn
   │   - 步骤 5：cosn Bench（native + gluten）
   │   - 步骤 6：自动生成 2x2_matrix_report.md（含加速比、基线对比）
   │
   └── Stage 4 远端→本地           → scp 拉回 reports/<IP>_<TS>_*.md + csv
```

---

## 四、自动探测的关键能力

`cluster_inspect.sh` 能识别：

| 项 | 探测方式 | 用途 |
|---|---|---|
| Master 内网 IP | `hostname -I` | 自动改 DRIVER_HOST |
| JDK 11 | `/usr/local/jdk` + `/usr/lib/jvm/java-11` 双路径 | 决定是否要装 |
| Spark 3.5 | `spark-submit --version` 正则匹配 3.5.x | 决定是否要装 |
| Gluten | `ls jars/gluten-velox-bundle-*.jar` | 决定是否要装 |
| YARN workers | `yarn node -list` 解析 IP 列表 | 批量装 / 资源估算 |
| YARN 单节点资源 | `yarn node -list -showDetails` | 算最优 num-executors |
| cosn 可用性 | `hadoop fs -ls cosn://` 看是否报 No FileSystem | 决定能否跑 cosn bench |
| Worker SSH 互通 | 试连第一个 worker | 决定能否批量装 JDK |
| bench 工作目录 | `ls /home/hadoop/bench/scripts/` | 决定是否要部署 toolkit |

---

## 五、产物路径

```
本地（你的 Mac）：
  bench-toolkit/../reports/
  ├── <ip>_<TS>_env.json              # 体检结果
  ├── <ip>_<TS>_2x2_matrix_report.md  # 最终报告
  ├── duration_native.csv             # HDFS Native
  ├── duration_gluten.csv             # HDFS Gluten
  ├── duration_cosn_native.csv        # cosn Native
  └── duration_cosn_gluten.csv        # cosn Gluten

远端（master 上）：
  /home/hadoop/bench/
  ├── results/
  │   ├── 2x2_matrix_report.md        # 远端原始报告
  │   ├── duration_*.csv              # 4 个 CSV
  │   ├── native/                     # 每条 SQL 详细日志
  │   ├── gluten/
  │   ├── cosn_native/
  │   └── cosn_gluten/
  ├── gen/, queries/, queries_cosn/, scripts/
  └── external_tables.sql
```

---

## 六、前提条件（很少，3 项）

1. **本地（你的 Mac）**：能 ssh 到远端 master root 用户
   ```bash
   ssh root@<master_ip> hostname    # 必须能直接登录
   ```
   如果不能：把本地公钥（`~/.ssh/id_*.pub`）加到目标 master 的 `/root/.ssh/authorized_keys`

2. **远端 master**：root 能 `su - hadoop`（EMR 默认满足）

3. **可选**：cosn 桶可用（如果要测 cosn 单元）。腾讯云 EMR 默认配置了 `EMRInstanceCredentialsProvider`，开箱即用，**不需要 secret**

---

## 七、典型场景剧本

### 剧本 A：明天换到 H4 集群

```bash
# 0. 把我的公钥加到 H4 master（一次性，5 秒）
ssh root@h4_master 'echo "<my_pubkey>" >> /root/.ssh/authorized_keys'

# 1. 一键全跑（45-60 分钟，期间可以去喝咖啡）
./oneshot.sh <h4_ip>

# 2. 报告自动落地到 reports/
ls reports/<h4_ip>_*_2x2_matrix_report.md
```

### 剧本 B：H3 上补 D 单元（HDFS）

```bash
# H3 已有 cosn 数据，但还没 HDFS。先 distcp 回 HDFS 再跑 hdfs bench
./oneshot.sh 101.43.161.139 inspect    # 看现状
ssh root@101.43.161.139 'su - hadoop -c "hadoop distcp -m 100 cosn://lkl-bj-update-1308597516/meson/data/bench/ hdfs:///user/hadoop/bench/"'
./oneshot.sh 101.43.161.139 bench hdfs  # 只跑 HDFS bench
```

### 剧本 C：定期监控（每周自动跑一次）

```bash
# 配 cron（每周一凌晨 2 点）
0 2 * * 1 cd /path/to/bench-toolkit && ./oneshot.sh <h2_ip> bench >> /var/log/bench.log 2>&1
0 3 * * 1 cd /path/to/bench-toolkit && ./oneshot.sh <h3_ip> bench >> /var/log/bench.log 2>&1
```

---

## 八、踩坑兜底

### 坑 1：本地 zsh 中文路径展开问题

**现象**：`scp: stat local "scripts/cluster_inspect.sh": No such file or directory`

**根因**：本仓库路径 `spark/案例/向量化Gluten/` 含中文，zsh/bash 在变量展开 + scp 命令组合时会转义出错。

**解法**：oneshot.sh 已自动处理——开头会把 toolkit tar pipe 到 `/tmp/bench-toolkit-local-$$`（纯英文路径）作为工作目录，最后 trap 自动 cp 报告到中文路径下的 `reports/`。

### 坑 2：远端 SSH Permission denied

**现象**：oneshot 报 "无法 SSH 到 xxx"

**解法**：把本地公钥加到目标 master：
```bash
cat ~/.ssh/id_ed25519.pub
# 复制输出，让大哥加到 master 的 /root/.ssh/authorized_keys
```

### 坑 3：Worker SSH 不互通，无法批量装 JDK11

**现象**：inspect 显示 `Worker SSH (hadoop): ✗ 不互通`

**解法**：oneshot 会提示手动命令。或者在每个 worker 上单独执行：
```bash
wget -O /tmp/k.tar.gz https://github.com/Tencent/TencentKona-11/releases/download/kona11.0.27/TencentKona-11.0.27.b1-jdk_linux-x86_64.tar.gz
tar -xf /tmp/k.tar.gz -C /usr/local/
ln -snf /usr/local/TencentKona-11* /usr/local/jdk
```

### 坑 4：Spark 包不在默认位置

**现象**：install_env 报 "未找到 Spark 包：/home/hadoop/spark.tar.gz"

**解法**：传环境变量：
```bash
ssh root@master_ip 'export SPARK_PKG_PATH=/path/to/spark.tar.gz; bash /tmp/bench-toolkit/scripts/install_env.sh'
```

或者在跑 oneshot 之前先把包传到默认位置：
```bash
scp spark.tar.gz root@master_ip:/home/hadoop/
./oneshot.sh master_ip
```

---

## 九、已验证状态（H2 + H3）

| 集群 | inspect | install | bench | report | 是否成功 |
|---|---|---|---|---|---|
| H2 (62.234.130.135) | ✅ | （已装） | （已跑） | ✅ | **完整 2x2 一键拉回** |
| H3 (101.43.161.139) | ✅ | （已装） | （已跑） | ✅ | **inspect 链路通** |

**待验证（明天）**：
- 全新集群 from-scratch（install + bench 全自动）
- 多个集群并行跑（在不同窗口同时跑两个 oneshot）

---

## 十、改进路线（L4 / L5 长远）

| 级别 | 内容 | 状态 |
|---|---|---|
| L1 | 一键跑 Bench + 出报告（环境已就绪） | ✅ 已完成 |
| L2 | 自动装环境（JDK + Spark + Gluten） | ✅ 已完成 |
| L3 | 批量装 worker JDK | ✅ 部分完成（SSH 互通时全自动，否则给手动命令）|
| L4 | 多集群并行测试 + 自动汇总 | 📋 待做 |
| L5 | 接入 Prometheus 监控，每天定时 Bench，跑出趋势图 | 📋 待做 |

---

**End of 17 — 一键测试落地。明天开新集群，给我一个 IP 就好。🐆**
