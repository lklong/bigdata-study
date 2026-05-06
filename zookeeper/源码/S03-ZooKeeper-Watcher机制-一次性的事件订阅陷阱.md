# 教案 S03：ZooKeeper Watcher 机制 — 一次性的事件订阅陷阱

> **课时**：40分钟 | **难度**：⭐⭐⭐

---

## 一、课前导入 — 你的配置变更通知为什么漏了？

> 你用 ZK 做配置中心，监听 `/config/db-url` 节点。第一次变更收到了通知，但第二次变更却漏了！排查发现：**ZK 的 Watcher 是一次性的**，触发一次后就失效了，你需要重新注册。

## 二、核心概念 — 门铃只响一次

ZK 的 Watcher 像一个**只能按一次的门铃**：
- 你注册了一个 Watcher（装了门铃）
- 事件发生时通知你一次（门铃响了）
- 通知完就拆掉了（门铃消失了）
- 如果你还想收通知，必须重新注册（再装一次门铃）

```java
// 注册 Watcher（exists / getData / getChildren 都可以）
zk.getData("/config/db-url", new Watcher() {
    @Override
    public void process(WatchedEvent event) {
        // 收到通知！但此 Watcher 已失效
        // 必须在这里重新注册：
        zk.getData("/config/db-url", this, null);  // 重新装门铃
    }
}, null);
```

## 三、源码核心 — WatchManager（双向映射）

```java
// WatchManager.java — 服务端 Watcher 管理
class WatchManager {
    // 双向映射：高效查找
    HashMap<String, HashSet<Watcher>> watchTable;      // path → watchers
    HashMap<Watcher, HashSet<String>> watch2Paths;      // watcher → paths

    // 触发 Watcher — 注意：触发后移除！
    Set<Watcher> triggerWatch(String path, EventType type) {
        Set<Watcher> watchers = watchTable.remove(path);  // 移除！一次性！
        for (Watcher w : watchers) {
            watch2Paths.get(w).remove(path);  // 反向也移除
            w.process(new WatchedEvent(type, KeeperState.SyncConnected, path));
        }
        return watchers;
    }
}
```

**设计决策——为什么一次性？**
- **减轻服务端负担**：百万个 Watcher 如果不自动失效，服务端内存会爆
- **简化语义**：客户端明确知道"我收到了通知"，不会重复收到
- **避免通知风暴**：高频变更的节点如果永久 Watch，客户端会被通知淹没

## 四、Watcher 事件类型

| 事件 | 触发条件 | 对应注册方法 |
|------|---------|-------------|
| `NodeCreated` | 节点被创建 | exists() |
| `NodeDeleted` | 节点被删除 | exists() / getData() |
| `NodeDataChanged` | 节点数据变更 | getData() |
| `NodeChildrenChanged` | 子节点列表变化 | getChildren() |
| `DataWatchRemoved` | Watch 被主动移除 | removeWatches() |

## 五、生产陷阱与最佳实践

### 陷阱 1：Watcher 注册与事件之间的间隙

```
时间线:
T1: getData("/x", watcher) → 返回 value="A"
T2: 其他客户端 setData("/x", "B")  ← 这次变更你会收到通知
T3: 你收到通知，开始处理
T4: 在你重新注册 Watcher 之前，其他客户端 setData("/x", "C")  ← 这次变更你漏了！
T5: 你重新注册 getData("/x", watcher) → 返回 "C"

问题：你漏了 "B" → "C" 这次变更的通知
解决：重新注册时读取最新值，用返回值而不是通知中的值
```

### 陷阱 2：Session 过期丢失所有 Watcher

Session 过期 → 所有 Watcher 自动清除 → 重连后需要全部重新注册。
**Apache Curator 的 TreeCache / NodeCache 帮你自动处理了这些**。

### 最佳实践

```
1. 永远在 Watcher 回调中重新注册
2. 用 Curator 的 NodeCache/PathChildrenCache 代替原生 Watcher
3. 重新注册时用返回的数据，不依赖通知时刻的数据
4. 监控 Watch 数量：4lw 命令 'wchs' (watch count summary)
```

## 六、课堂练习

### 思考题：如果 ZK 集群在你注册 Watcher 后、事件触发前发生了 Leader 切换，Watcher 还有效吗？

<details>
<summary>参考答案</summary>

有效！Watcher 注册信息存储在 Leader 的内存中，但在 Leader 切换时：
1. 新 Leader 从数据同步中恢复所有 Session 信息
2. 但 **Watcher 不在持久化数据中**！
3. 客户端 Session 重连时会**重新发送 Watcher 注册**（客户端 SDK 自动）
4. 所以最终 Watcher 不会丢失——但重连期间可能漏掉事件

这就是为什么 Curator 比原生 API 更安全。
</details>

## 七、知识晶体

```
┌──────────────────────────────────────────────────┐
│  ZooKeeper Watcher                                 │
├──────────────────────────────────────────────────┤
│  核心特性: 一次性触发（触发后自动移除）             │
│  服务端: WatchManager 双向映射 (path↔watcher)      │
│  triggerWatch: 通知 + 移除 (原子操作)              │
├──────────────────────────────────────────────────┤
│  陷阱:                                            │
│  1. 重新注册前可能漏事件 → 读返回值而非依赖通知    │
│  2. Session 过期丢所有 Watch → 用 Curator          │
│  3. 高频变更节点 Watch 风暴 → 限制 Watch 数量      │
├──────────────────────────────────────────────────┤
│  生产: 用 Curator NodeCache/TreeCache 代替原生API  │
│  监控: echo wchs | nc zk-host 2181                │
└──────────────────────────────────────────────────┘
```

*教案作者：Eric | 数据来源：ZooKeeper WatchManager.java | 最后更新：2026-04-30*
