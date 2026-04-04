# Hadoop 2.8.5 NodeManager 堆外内存泄漏 — 推荐代码修复清单

## P0 级修复（必须修复）

---

### Fix 1: ShuffleHandler sendError() — ByteBuf 泄漏修复

**文件**: `hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-shuffle/src/main/java/org/apache/hadoop/mapred/ShuffleHandler.java`

**问题**: sendError() 中创建的 ByteBuf 在 write 失败时未 release

**修复方案**:
```java
// 修复前 (Hadoop 2.8.5):
protected void sendError(ChannelHandlerContext ctx, String message,
    HttpResponseStatus status) {
  HttpResponse response = new DefaultHttpResponse(HTTP_1_1, status);
  response.headers().set(CONTENT_TYPE, "text/plain; charset=UTF-8");
  ChannelBuffer content = ChannelBuffers.copiedBuffer(message, CharsetUtil.UTF_8);
  response.setContent(content);
  ChannelFuture future = ctx.getChannel().write(response);
  future.addListener(ChannelFutureListener.CLOSE);
}

// 修复后:
protected void sendError(ChannelHandlerContext ctx, String message,
    HttpResponseStatus status) {
  HttpResponse response = new DefaultHttpResponse(HTTP_1_1, status);
  response.headers().set(CONTENT_TYPE, "text/plain; charset=UTF-8");
  ChannelBuffer content = ChannelBuffers.copiedBuffer(message, CharsetUtil.UTF_8);
  response.setContent(content);
  
  Channel ch = ctx.getChannel();
  if (!ch.isConnected()) {
    // 对端已断连，直接释放 ByteBuf
    if (content.readable()) {
      content.clear();
    }
    return;
  }
  
  ChannelFuture future = ch.write(response);
  future.addListener(new ChannelFutureListener() {
    @Override
    public void operationComplete(ChannelFuture f) {
      if (!f.isSuccess()) {
        LOG.warn("Failed to send error response, releasing resources");
      }
      f.getChannel().close();
    }
  });
}
```

**调用位置**: `ShuffleHandler.java` 的 `sendError()` 方法，所有调用点包括：
- `channelRead()` 中 jobId 校验失败
- `verifyRequest()` 权限校验失败  
- `sendMapOutput()` 发送数据异常

**参考 JIRA**: [YARN-7754](https://issues.apache.org/jira/browse/YARN-7754)

---

### Fix 2: ShuffleHandler sendMapOutput() — FadvisedFileRegion 泄漏修复

**文件**: `hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-shuffle/src/main/java/org/apache/hadoop/mapred/ShuffleHandler.java`

**问题**: sendMapOutput() 中 Channel write 失败时 FadvisedFileRegion 未释放

**修复方案**:
```java
// 修复前:
protected ChannelFuture sendMapOutput(ChannelHandlerContext ctx, Channel ch,
    String user, String mapId, int reduce, MapOutputInfo mapOutputInfo)
    throws IOException {
  
  final FadvisedFileRegion partition = new FadvisedFileRegion(
      spill, offset, partLength, manageOsCache, readaheadLength,
      readaheadPool, spillfile.getAbsolutePath(), shuffleBufferSize,
      shuffleTransferToAllowed);
  
  ChannelFuture writeFuture = ch.write(partition);
  writeFuture.addListener(new ChannelFutureListener() {
    public void operationComplete(ChannelFuture future) {
      if (!future.isSuccess()) {
        future.getChannel().close();
        // 缺少：partition.release()
      }
    }
  });
  return writeFuture;
}

// 修复后:
protected ChannelFuture sendMapOutput(ChannelHandlerContext ctx, Channel ch,
    String user, String mapId, int reduce, MapOutputInfo mapOutputInfo)
    throws IOException {
  
  final FadvisedFileRegion partition = new FadvisedFileRegion(
      spill, offset, partLength, manageOsCache, readaheadLength,
      readaheadPool, spillfile.getAbsolutePath(), shuffleBufferSize,
      shuffleTransferToAllowed);
  
  ChannelFuture writeFuture;
  try {
    writeFuture = ch.write(partition);
  } catch (Exception e) {
    // write 本身抛异常时，确保释放
    partition.releaseExternalResources();
    throw e;
  }
  
  writeFuture.addListener(new ChannelFutureListener() {
    public void operationComplete(ChannelFuture future) {
      // 无论成功失败都释放 FileRegion
      partition.releaseExternalResources();
      if (!future.isSuccess()) {
        LOG.warn("Failed to send map output for " + mapId, future.getCause());
        future.getChannel().close();
      }
    }
  });
  return writeFuture;
}
```

**参考 JIRA**: [MAPREDUCE-6424](https://issues.apache.org/jira/browse/MAPREDUCE-6424)

---

### Fix 3: LogAggregationService — Deflater end() 修复

**文件**: `hadoop-yarn-project/hadoop-yarn/hadoop-yarn-server/hadoop-yarn-server-nodemanager/src/main/java/org/apache/hadoop/yarn/server/nodemanager/containermanager/logaggregation/LogAggregationService.java`

**问题**: 日志聚合压缩使用的 Deflater 在异常路径下未调用 end() 释放 JNI native memory

**修复方案**:
```java
// 在所有使用 Deflater/DeflaterOutputStream 的地方，确保 finally 中调用 end()

// 修复模式 A: 包装 DeflaterOutputStream
Deflater deflater = new Deflater(Deflater.DEFAULT_COMPRESSION);
DeflaterOutputStream dos = null;
try {
    dos = new DeflaterOutputStream(outputStream, deflater);
    dos.write(logData);
    dos.flush();
    dos.finish();
} finally {
    // 先关闭流
    IOUtils.closeStream(dos);
    // 再显式释放 Deflater native memory
    deflater.end();
}

// 修复模式 B: try-with-resources (如果项目支持)
Deflater deflater = new Deflater(Deflater.DEFAULT_COMPRESSION);
try {
    try (DeflaterOutputStream dos = new DeflaterOutputStream(outputStream, deflater)) {
        dos.write(logData);
        dos.flush();
    }
} finally {
    deflater.end();  // 必须在 DeflaterOutputStream.close() 之后调用
}
```

**需要修改的文件列表**（所有涉及日志压缩的位置）:
1. `LogAggregationService.java` — 主要的日志聚合逻辑
2. `AggregatedLogFormat.java` — 聚合日志格式化
3. `AppLogAggregatorImpl.java` — 应用日志聚合实现

**参考 JIRA**: [YARN-8482](https://issues.apache.org/jira/browse/YARN-8482), [HADOOP-12611](https://issues.apache.org/jira/browse/HADOOP-12611)

---

### Fix 4: 设置 MALLOC_ARENA_MAX（运维级修复）

**文件**: `hadoop-common-project/hadoop-common/src/main/bin/hadoop-env.sh` 或 `yarn-env.sh`

**问题**: glibc malloc arena 碎片化导致 RSS 虚高

**修复方案**:
```bash
# 在 hadoop-env.sh 或 yarn-env.sh 中添加
export MALLOC_ARENA_MAX=4

# 或者在 yarn-site.xml 中通过环境变量传递
# <property>
#   <name>yarn.nodemanager.env-whitelist</name>
#   <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,
#          CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_HOME,
#          PATH,LANG,TZ,MALLOC_ARENA_MAX</value>
# </property>
```

**参考 JIRA**: [HADOOP-7154](https://issues.apache.org/jira/browse/HADOOP-7154)

---

## P1 级修复（尽快修复）

---

### Fix 5: ContainersLauncher 线程池上限

**文件**: `hadoop-yarn-project/hadoop-yarn/hadoop-yarn-server/hadoop-yarn-server-nodemanager/src/main/java/org/apache/hadoop/yarn/server/nodemanager/containermanager/launcher/ContainersLauncher.java`

**问题**: 线程池 maximumPoolSize = Integer.MAX_VALUE，无上限

**修复方案**:
```java
// 修复前:
private final ExecutorService containerLauncher =
    new ThreadPoolExecutor(INITIAL_POOL_SIZE, Integer.MAX_VALUE,
        1, TimeUnit.HOURS, new SynchronousQueue<Runnable>());

// 修复后:
// 从配置中读取上限，默认为 CPU 核数 * 4
int maxThreads = conf.getInt(
    YarnConfiguration.NM_CONTAINER_LAUNCHER_MAX_THREADS,
    Runtime.getRuntime().availableProcessors() * 4);

private final ExecutorService containerLauncher =
    new ThreadPoolExecutor(INITIAL_POOL_SIZE, maxThreads,
        60, TimeUnit.SECONDS,  // 缩短空闲线程存活时间
        new LinkedBlockingQueue<Runnable>(1024),  // 有界队列
        new ThreadFactoryBuilder()
            .setNameFormat("ContainersLauncher #%d")
            .setDaemon(true)
            .build());
```

---

### Fix 6: Metrics System 源注销修复

**文件**: `hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/metrics2/impl/MetricsSystemImpl.java`

**问题**: Container Metrics 注册后注销时源名称字符串泄漏

**修复方案**: 

直接 backport [HADOOP-13362](https://issues.apache.org/jira/browse/HADOOP-13362) 的 Patch 到 2.8.5 分支。

核心修复：在 `MetricsSystemImpl.unregisterSource()` 中同时清理源名称缓存：
```java
// 在 unregisterSource 中添加
@Override
public synchronized void unregisterSource(String name) {
  if (sources.containsKey(name)) {
    sources.remove(name);
    sourceNames.remove(name);  // 修复：同时清理源名称缓存
    // ... 其他清理 ...
  }
}
```

---

### Fix 7: Hadoop IPC DirectByteBuffer 管理

**文件**: `hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/ipc/Client.java`

**问题**: RPC 连接重建时旧 DirectByteBuffer 依赖 GC 释放

**修复方案**:
```java
// 在 Connection.close() 中主动释放 DirectByteBuffer
public void close() {
    // ... 其他清理逻辑 ...
    
    // 主动释放 DirectByteBuffer（Java 8 方式）
    if (dataBuffer != null && dataBuffer.isDirect()) {
        try {
            Method cleanerMethod = dataBuffer.getClass().getMethod("cleaner");
            cleanerMethod.setAccessible(true);
            Object cleaner = cleanerMethod.invoke(dataBuffer);
            if (cleaner != null) {
                Method cleanMethod = cleaner.getClass().getMethod("clean");
                cleanMethod.invoke(cleaner);
            }
        } catch (Exception e) {
            LOG.debug("Failed to clean DirectByteBuffer", e);
        }
    }
}
```

---

### Fix 8: 日志聚合文件流关闭修复

**文件**: 日志聚合相关文件

**问题**: 异常路径下 OutputStream/InputStream 可能不会正确关闭

**修复方案**: 统一使用 try-with-resources 或确保 finally 块中的 close 不会吞掉异常：
```java
// 修复模式：双层 try-finally
FSDataOutputStream out = null;
try {
    out = fs.create(remoteLogFile);
    // 写入逻辑
} finally {
    if (out != null) {
        try {
            out.close();
        } catch (IOException closeEx) {
            LOG.warn("Error closing aggregated log file stream", closeEx);
            // 不要吞掉异常，至少记录日志
        }
    }
}
```

---

## P2 级修复（计划修复）

---

### Fix 9: BuiltInZlibDeflater/Inflater — 确保 end() 调用

**文件**: 所有使用 `CodecPool.returnCompressor()` / `CodecPool.returnDecompressor()` 的位置

**修复方案**:
```java
// 在 CodecPool 的 returnCompressor/returnDecompressor 中
// 检查并清理 Compressor/Decompressor 的内部状态
public static void returnCompressor(Compressor compressor) {
    if (compressor == null) return;
    
    // 如果 Compressor 处于异常状态，不放回池中，直接 end()
    try {
        compressor.reset();
    } catch (Exception e) {
        LOG.warn("Compressor in bad state, calling end() directly", e);
        compressor.end();  // 释放 native memory
        return;
    }
    
    // 正常放回池中复用
    pool.offer(compressor);
}
```

---

### Fix 10: 统一 Native Memory 释放工具类

建议创建一个统一的 native memory 管理工具类：

```java
/**
 * NativeMemoryUtil — 用于安全释放 native memory 资源
 */
public class NativeMemoryUtil {
    
    private static final Logger LOG = LoggerFactory.getLogger(NativeMemoryUtil.class);
    
    /**
     * 安全释放 DirectByteBuffer
     */
    public static void freeDirectBuffer(ByteBuffer buffer) {
        if (buffer == null || !buffer.isDirect()) return;
        try {
            // Java 8: sun.misc.Cleaner
            Method cleanerMethod = buffer.getClass().getMethod("cleaner");
            cleanerMethod.setAccessible(true);
            Object cleaner = cleanerMethod.invoke(buffer);
            if (cleaner != null) {
                Method cleanMethod = cleaner.getClass().getMethod("clean");
                cleanMethod.invoke(cleaner);
            }
        } catch (Exception e) {
            LOG.debug("Failed to free DirectByteBuffer, relying on GC", e);
        }
    }
    
    /**
     * 安全释放 Deflater
     */
    public static void safeEndDeflater(Deflater deflater) {
        if (deflater != null) {
            try {
                deflater.end();
            } catch (Exception e) {
                LOG.debug("Error calling Deflater.end()", e);
            }
        }
    }
    
    /**
     * 安全释放 Inflater
     */
    public static void safeEndInflater(Inflater inflater) {
        if (inflater != null) {
            try {
                inflater.end();
            } catch (Exception e) {
                LOG.debug("Error calling Inflater.end()", e);
            }
        }
    }
}
```

---

## 修复优先级矩阵

| 优先级 | 修复项 | 难度 | 风险 | 预期收益 |
|--------|--------|------|------|----------|
| P0 | Fix 1: sendError ByteBuf release | 低 | 低 | 高 — 消除最大泄漏源 |
| P0 | Fix 2: sendMapOutput FadvisedFileRegion release | 中 | 低 | 高 — 消除文件描述符+内存双重泄漏 |
| P0 | Fix 3: Deflater end() | 低 | 低 | 高 — 消除 JNI native memory 泄漏 |
| P0 | Fix 4: MALLOC_ARENA_MAX=4 | 极低 | 极低 | 高 — 立即减少数 GB RSS 虚高 |
| P1 | Fix 5: ContainersLauncher 线程池上限 | 中 | 中 | 中 — 防止线程池爆炸 |
| P1 | Fix 6: Metrics 源注销 | 中 | 低 | 低-中 — 主要影响堆内 |
| P1 | Fix 7: IPC DirectByteBuffer | 中 | 中 | 中 — 减少 RPC 重连时的泄漏 |
| P1 | Fix 8: 日志聚合流关闭 | 低 | 低 | 中 — 减少异常路径泄漏 |
| P2 | Fix 9: CodecPool end() | 中 | 低 | 低 — 减少 Codec 池泄漏 |
| P2 | Fix 10: 统一工具类 | 中 | 低 | 长期收益 — 标准化释放方式 |

---

## 打 Patch 指引

### 步骤

```bash
# 1. 获取 Hadoop 2.8.5 源码
git clone https://github.com/apache/hadoop.git
cd hadoop
git checkout rel/release-2.8.5

# 2. 应用修复
# 编辑上述文件，应用对应的 Fix

# 3. 编译 ShuffleHandler 相关模块
cd hadoop-mapreduce-project/hadoop-mapreduce-client/hadoop-mapreduce-client-shuffle
mvn clean package -DskipTests

# 4. 替换线上 jar
# 将编译好的 hadoop-mapreduce-client-shuffle-2.8.5.jar 替换到所有 NM 节点
# 路径通常在: $HADOOP_HOME/share/hadoop/mapreduce/

# 5. 滚动重启 NM
# 逐节点重启，确保每个节点重启后 Container 正常调度
```

### 验证

```bash
# 验证修复后 RSS 稳定性
./scripts/monitor-nm-offheap.sh 300 288  # 持续 24 小时监控

# 验证 Netty ByteBuf 不再泄漏
grep -i "LEAK.*ByteBuf" /var/log/hadoop-yarn/yarn-*-nodemanager*.log

# 验证文件描述符不再泄漏
watch -n 60 'ls /proc/$(pgrep -f NodeManager)/fd | wc -l'
```
