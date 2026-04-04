# OHL-003 修复补丁 — LlapIoImpl.close() 调用点

## 需要修改的文件

1. `llap-server/src/java/org/apache/hadoop/hive/llap/cache/BuddyAllocator.java`
2. `llap-server/src/java/org/apache/hadoop/hive/llap/io/api/impl/LlapIoImpl.java`

## 修改 1: BuddyAllocator.java

### 类声明

```java
// 原代码
public final class BuddyAllocator
    implements EvictionAwareAllocator, StoppableAllocator, BuddyAllocatorMXBean, LlapIoDebugDump {

// 修改后 — 添加 Closeable 接口
public final class BuddyAllocator
    implements EvictionAwareAllocator, StoppableAllocator, BuddyAllocatorMXBean, LlapIoDebugDump, Closeable {
```

### 添加 import

```java
import java.io.Closeable;
import org.apache.hive.common.util.CleanerUtil;
```

### 添加 close() 方法（在 preallocateArenaBuffer 方法之前）

```java
/**
 * [FIX OHL-003] 释放所有 Arena 持有的 DirectByteBuffer 内存。
 * 调用时机: LlapIoImpl.close() → buddyAllocator.close()
 */
@Override
public void close() throws IOException {
    LlapIoImpl.LOG.info("BuddyAllocator.close(): releasing {} arenas, isDirect={}",
        arenas.length, isDirect);
    int releasedCount = 0;
    int failedCount = 0;

    for (int i = 0; i < arenas.length; i++) {
        ByteBuffer arenaData = arenas[i].data;
        if (arenaData == null) {
            continue;
        }

        if (arenaData.isDirect()) {
            try {
                if (CleanerUtil.UNMAP_SUPPORTED) {
                    CleanerUtil.getCleaner().freeBuffer(arenaData);
                    releasedCount++;
                } else {
                    LlapIoImpl.LOG.warn("Arena[{}]: CleanerUtil not supported ({}), "
                        + "DirectByteBuffer of {} bytes will rely on GC",
                        i, CleanerUtil.UNMAP_NOT_SUPPORTED_REASON, arenaData.capacity());
                    failedCount++;
                }
            } catch (Exception e) {
                failedCount++;
                LlapIoImpl.LOG.warn("Arena[{}]: failed to release DirectByteBuffer of {} bytes",
                    i, arenaData.capacity(), e);
            }
        }
        // null out reference to help GC
        arenas[i].data = null;
    }

    // Clean up thread-local discard context
    threadCtx.remove();

    LlapIoImpl.LOG.info("BuddyAllocator.close() complete: released={}, failed={}, totalArenas={}",
        releasedCount, failedCount, arenas.length);
}
```

## 修改 2: LlapIoImpl.java

在 `LlapIoImpl.close()` 方法中添加 BuddyAllocator 关闭：

```java
// 在 LlapIoImpl.close() 方法中，关闭 MXBean 和线程池之后添加:

// [FIX OHL-003] 释放 BuddyAllocator 的 DirectByteBuffer 内存
if (allocator instanceof BuddyAllocator) {
    try {
        ((BuddyAllocator) allocator).close();
    } catch (IOException e) {
        LOG.warn("Failed to close BuddyAllocator", e);
    }
}
```

## 编译验证

```bash
# 编译 common 模块（CleanerUtil 依赖）
mvn package -pl common -DskipTests

# 编译 llap-server 模块
mvn package -pl llap-server -DskipTests

# 运行修复验证测试
mvn test -pl llap-server -Dtest=TestBuddyAllocatorClose -DskipTests=false
```

## 运行时验证

```bash
# 1. 部署修复后的 llap-server jar 到 LLAP Daemon

# 2. 启动 LLAP 并记录初始 NMT 快照
jcmd $(pgrep -f LlapDaemon) VM.native_memory baseline

# 3. 执行若干查询后关闭 LLAP
# 观察日志中应出现:
# INFO BuddyAllocator.close(): releasing N arenas, isDirect=true
# INFO BuddyAllocator.close() complete: released=N, failed=0, totalArenas=N

# 4. 对比 NMT 快照
jcmd $(pgrep -f LlapDaemon) VM.native_memory summary.diff

# 预期: Internal 区域的内存应显著下降
```

## 风险评估

- **低风险**: close() 只在 LLAP Daemon 关闭时调用，不影响正常运行
- **注意**: 如果 CleanerUtil.UNMAP_SUPPORTED=false，close() 会 log 警告但不会失败
- **向后兼容**: 新增方法，不修改任何现有方法签名
