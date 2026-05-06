# 教案 15：Amoro Self-Optimizing 全参数字典 — 每个参数都讲透

> **课时**：30分钟 | **难度**：⭐⭐⭐

## 一、课前导入

> Amoro 有几十个参数控制自动优化行为。参数设错了，要么不优化（小文件堆积），要么过度优化（浪费资源）。这张参数字典是你的调优工具箱。

## 二、参数分类全景

### 2.1 触发条件参数（什么时候开始优化？）

| 参数 | 默认值 | 含义 | 调优建议 |
|------|--------|------|---------|
| `self-optimizing.minor.trigger.file-count` | 12 | 小文件数达到此值触发 Minor | 写入频繁调小(8)，不频繁调大(20) |
| `self-optimizing.minor.trigger.interval` | 3600000 (1h) | 距上次优化超过此间隔触发 | 实时场景调小(600000=10min) |
| `self-optimizing.major.trigger.duplicate-ratio` | 0.1 | Delete File 与数据文件比例超此值触发 Major | MoR 场景可调大(0.3) |
| `self-optimizing.full.trigger.interval` | -1 (关闭) | Full Optimize 间隔 | 一般不开，除非需要彻底重写 |

### 2.2 执行参数（怎么执行优化？）

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `self-optimizing.target-size` | 134217728 (128MB) | 目标文件大小 |
| `self-optimizing.max-file-count` | 10000 | 单次优化最大处理文件数 |
| `self-optimizing.fragment-ratio` | 8 | 小文件判定阈值 = target-size / fragment-ratio |
| `self-optimizing.min-input-file-count` | 12 | 至少这么多文件才值得合并 |

### 2.3 资源参数（用多少资源？）

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `self-optimizing.group` | "default" | 绑定的资源组 |
| `self-optimizing.quota-occupy-timeout` | 30000 | 配额占用超时(ms) |
| `self-optimizing.execute.num-retries` | 5 | 任务失败重试次数 |

### 2.4 维护参数（自动清理）

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `table-expiration.enabled` | false | 是否开启数据过期 |
| `table-expiration.retention-time` | - | 数据保留时间 |
| `snapshot.expire.age` | 604800000 (7天) | 快照保留时间 |
| `orphan.clean.enabled` | true | 是否清理孤立文件 |

## 三、常见配置模板

### 实时入湖场景（高写入频率）
```properties
self-optimizing.minor.trigger.file-count = 8
self-optimizing.minor.trigger.interval = 600000
self-optimizing.target-size = 134217728
self-optimizing.group = "realtime"
```

### 批量 ETL 场景（每天写一次）
```properties
self-optimizing.minor.trigger.file-count = 20
self-optimizing.minor.trigger.interval = 7200000
self-optimizing.target-size = 268435456
self-optimizing.group = "batch"
```

## 四、课堂练习

### 思考题：target-size 设 128MB 还是 256MB？

<details>
<summary>参考答案</summary>

- **128MB**：适合查询时需要高并行度的场景（更多 split → 更多 task → 更快扫描）
- **256MB**：适合大表顺序扫描场景（更大文件 → 更少 IO 开销 → 更好的列式压缩效率）
- **决策**：如果表 >1TB 且主要做全表扫描 → 256MB；如果经常做点查或小范围扫描 → 128MB
</details>

## 五、知识晶体

```
触发: file-count(文件数) + interval(时间间隔) + duplicate-ratio(删除比例)
执行: target-size(目标大小) + max-file-count(最大文件数)
资源: group(资源组) + quota-timeout(配额超时) + retries(重试)
模板: 实时→小阈值快触发, 批量→大阈值低频
```

*教案作者：Eric | 最后更新：2026-04-30*
