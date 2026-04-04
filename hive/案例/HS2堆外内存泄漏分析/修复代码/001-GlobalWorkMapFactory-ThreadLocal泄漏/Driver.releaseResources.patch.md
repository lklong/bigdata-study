# OHL-001 修复补丁 — Driver.releaseResources() 调用点

## 需要修改的文件

`ql/src/java/org/apache/hadoop/hive/ql/Driver.java`

## 补丁位置

在 `Driver.releaseResources()` 方法的末尾添加 WorkMap 清理调用。

### Hive 3.x 补丁

在 `Driver.java` 的 `releaseResources()` 方法中添加：

```java
// 在 releaseResources() 方法末尾，释放锁之前
// [FIX OHL-001] 清理 ThreadLocal WorkMap 防止 BaseWork 对象泄漏
if (ctx != null) {
    GlobalWorkMapFactory workMapFactory = ctx.getWorkMapFactory();
    if (workMapFactory != null) {
        workMapFactory.clearThreadLocalWorkMap();
    }
}
```

### Hive 2.3.x 补丁

Hive 2.3.x 中 `Utilities` 类持有静态 `gWorkMap`，修改方式：

在 `Driver.releaseResources()` 中添加：
```java
// [FIX OHL-001] 清理 ThreadLocal WorkMap
Utilities.clearWorkMap();
```

同时在 `Utilities.java` 中添加：
```java
public static void clearWorkMap() {
    if (gWorkMap instanceof ThreadLocal) {
        // Hive 2.3.x 中需根据实际实现适配
    }
    // 或直接清理全局引用
    gWorkMap.get().clear();
}
```

## 验证方法

1. 编译修改后的模块：`mvn package -pl ql -DskipTests`
2. 部署到 HS2
3. 连续执行 100 次查询后检查：
   ```bash
   jmap -histo:live $(pgrep -f HiveServer2) | grep -E "BaseWork|GlobalWorkMap" | head -5
   ```
4. 对比修复前后 `BaseWork` 对象数量趋势

## 预期效果

修复前：每次查询后 BaseWork 实例数 +N (N = 查询中的 Stage 数)
修复后：每次查询后 BaseWork 实例数稳定在当前运行查询的数量，不随历史查询积累
