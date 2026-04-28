# [教案] Hadoop RPC 框架源码分析

> 🎯 教学目标：掌握 Hadoop RPC 的 Reactor 线程模型（Listener→Reader→Handler→Responder）、ProtobufRpcEngine 核心架构、Client 端调用流程 | ⏰ 预计学时: 90分钟 | 📊 难度: ⭐⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：餐厅的服务模型

一家大型餐厅的运作流程：

1. **门口迎宾（Listener）**：一个人站在门口，有客人来就接待，给他分配到某个服务区
2. **服务员（Reader）**：每个服务区有一个服务员，负责接收客人点的菜（读取请求）
3. **厨师（Handler）**：后厨有多个厨师，拿到菜单就做菜（处理请求）
4. **传菜员（Responder）**：一个人负责把做好的菜端给客人（发送响应）

这就是 **Reactor 模式** —— Hadoop RPC 框架的核心设计模式。HDFS 中所有的 Client→NameNode、DataNode→NameNode 的通信都走这条路。

### 为什么重要？

Hadoop RPC 是整个 Hadoop 生态的**通信基石**：
- Client 调用 `dfs.create()` → RPC 调用 NameNode
- DataNode 发心跳 → RPC 调用 NameNode
- ResourceManager、NodeManager 通信 → RPC
- HBase RegionServer → RPC

**理解 RPC 框架，就理解了 Hadoop 所有组件之间如何通信。**

### 生产故障场景

> "用户反馈 HDFS 操作非常慢，查看 NameNode 日志发现大量 `IPC Server handler X on 8020 is taking long: callQueue size Y` 告警。RPC CallQueue 队列满了，所有新请求被拒绝。原因是一个大目录的 `ls` 操作占用了 Handler 线程 30 秒，导致其他线程饥饿。"

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| **Reactor 模式** | 事件驱动的 I/O 多路复用设计模式 | 餐厅服务模型 |
| **Server.Listener** | 监听连接的线程，accept 新连接 | 门口迎宾 |
| **Server.Reader** | 读取请求数据的线程（多个） | 服务员接单 |
| **Server.Handler** | 处理请求的线程（多个） | 厨师做菜 |
| **Server.Responder** | 发送响应的线程 | 传菜员 |
| **Server.Connection** | 一个客户端连接的状态 | 一桌客人 |
| **Server.Call/RpcCall** | 一个 RPC 调用 | 一份菜单 |
| **CallQueue** | RPC 调用队列 | 待做菜单队列 |
| **ProtobufRpcEngine** | 基于 Protobuf 的 RPC 引擎 | 标准点菜流程 |
| **Client.Connection** | 客户端到服务端的连接 | 电话线路 |
| **Client.Call** | 客户端一次调用 | 一次电话下单 |
| **RPC.RpcKind** | RPC 类型（Writable/Protobuf） | 点菜方式（口头/菜单） |

### 2.2 Hadoop RPC 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Hadoop RPC 架构全景                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Client 端                                                           │
│  ┌─────────────────────────────────────────┐                        │
│  │  ProtobufRpcEngine.Invoker              │                        │
│  │    ↓ 构造 RequestHeaderProto            │                        │
│  │    ↓ 序列化 Protobuf 参数               │                        │
│  │  Client.call()                           │                        │
│  │    ↓                                     │                        │
│  │  Client.Connection                       │                        │
│  │    ├─ sendRpcRequest() → 发送请求       │                        │
│  │    └─ receiveRpcResponse() → 接收响应   │                        │
│  └──────────────┬──────────────────────────┘                        │
│                 │ TCP                                                │
│                 ▼                                                    │
│  Server 端 (Reactor 模式)                                            │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                                                             │    │
│  │  Listener (1个线程)                                          │    │
│  │  ┌───────────────────────────────┐                          │    │
│  │  │ ServerSocketChannel.accept()   │                          │    │
│  │  │ → 分配给 Reader               │                          │    │
│  │  └──────────────┬────────────────┘                          │    │
│  │                 │ Round-Robin                                │    │
│  │                 ▼                                            │    │
│  │  Reader (N个线程, 默认1)                                      │    │
│  │  ┌───────────────────────────────┐                          │    │
│  │  │ Selector.select()             │                          │    │
│  │  │ → SocketChannel.read()        │                          │    │
│  │  │ → 解析RPC请求                  │                          │    │
│  │  │ → 放入 CallQueue              │                          │    │
│  │  └──────────────┬────────────────┘                          │    │
│  │                 │                                            │    │
│  │                 ▼                                            │    │
│  │  CallQueue (公平调度队列)                                     │    │
│  │  ┌───────────────────────────────┐                          │    │
│  │  │ [Call1] [Call2] [Call3] ...    │                          │    │
│  │  │ (支持FairCallQueue/FIFO)      │                          │    │
│  │  └──────────────┬────────────────┘                          │    │
│  │                 │                                            │    │
│  │                 ▼                                            │    │
│  │  Handler (M个线程, 默认10)                                    │    │
│  │  ┌───────────────────────────────┐                          │    │
│  │  │ callQueue.take()              │                          │    │
│  │  │ → 反序列化请求                 │                          │    │
│  │  │ → 调用实际方法                 │                          │    │
│  │  │ → 序列化响应                   │                          │    │
│  │  │ → 直接写或交给Responder        │                          │    │
│  │  └──────────────┬────────────────┘                          │    │
│  │                 │                                            │    │
│  │                 ▼                                            │    │
│  │  Responder (1个线程)                                         │    │
│  │  ┌───────────────────────────────┐                          │    │
│  │  │ Selector.select(OP_WRITE)     │                          │    │
│  │  │ → SocketChannel.write()       │                          │    │
│  │  │ → 异步发送大响应               │                          │    │
│  │  └───────────────────────────────┘                          │    │
│  │                                                             │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 核心类 | 文件路径 | 职责 |
|--------|----------|------|
| `Server` | `hadoop-common/.../ipc/Server.java` | RPC 服务端抽象基类 |
| `Server.Listener` | 同上 (行 906) | 监听新连接 |
| `Server.Reader` | 同上 (行 942) | 读取请求数据 |
| `Server.Handler` | 同上 (行 2462) | 处理 RPC 请求 |
| `Server.Responder` | 同上 (行 1181) | 发送响应 |
| `Server.Connection` | 同上 (行 1497) | 连接状态管理 |
| `Server.Call` | 同上 (行 671) | RPC 调用对象 |
| `Client` | `hadoop-common/.../ipc/Client.java` | RPC 客户端 |
| `RPC` | `hadoop-common/.../ipc/RPC.java` | RPC 工厂类 |
| `ProtobufRpcEngine` | `hadoop-common/.../ipc/ProtobufRpcEngine.java` | Protobuf RPC 引擎 |

### 3.2 Server 端源码剖析

#### 3.2.1 Listener — 连接监听

```java
// 文件: hadoop-common/src/main/java/org/apache/hadoop/ipc/Server.java
// 行号: 906-940

private class Listener extends Thread {
    private ServerSocketChannel acceptChannel = null;
    private Selector selector = null;
    private Reader[] readers = null;        // Reader 线程数组
    private int currentReader = 0;          // Round-Robin 计数器

    public Listener() throws IOException {
        address = new InetSocketAddress(bindAddress, port);
        
        // 1. 创建非阻塞的 ServerSocketChannel
        acceptChannel = ServerSocketChannel.open();
        acceptChannel.configureBlocking(false);
        
        // 2. 绑定端口
        bind(acceptChannel.socket(), address, backlogLength, conf, portRangeConfig);
        
        // 3. 创建 Selector，注册 ACCEPT 事件
        selector = Selector.open();
        
        // 4. 创建 Reader 线程数组
        // ipc.server.read.threadpool.size 默认 = 1
        readers = new Reader[readThreads];
        for (int i = 0; i < readThreads; i++) {
            Reader reader = new Reader(
                "Socket Reader #" + (i + 1) + " for port " + port);
            readers[i] = reader;
            reader.start();
        }
        
        // 5. 注册 ACCEPT 事件
        acceptChannel.register(selector, SelectionKey.OP_ACCEPT);
    }
    
    // Listener 主循环：accept 新连接，分配给 Reader
    @Override
    public void run() {
        while (running) {
            SelectionKey key = null;
            try {
                getSelector().select();  // 等待连接
                Iterator<SelectionKey> iter = 
                    getSelector().selectedKeys().iterator();
                while (iter.hasNext()) {
                    key = iter.next();
                    iter.remove();
                    if (key.isValid() && key.isAcceptable()) {
                        doAccept(key);  // 接受连接
                    }
                }
            } catch (Exception e) { ... }
        }
    }
    
    void doAccept(SelectionKey key) throws ... {
        SocketChannel channel = ((ServerSocketChannel) key.channel()).accept();
        channel.configureBlocking(false);
        
        // ★ Round-Robin 分配给 Reader
        Reader reader = getReader();
        Connection c = connectionManager.register(channel);
        reader.addConnection(c);  // 放入 Reader 的待处理队列
    }
    
    Reader getReader() {
        currentReader = (currentReader + 1) % readers.length;
        return readers[currentReader];
    }
}
```

#### 3.2.2 Reader — 请求读取

```java
// 文件: hadoop-common/src/main/java/org/apache/hadoop/ipc/Server.java
// 行号: 942-1031

private class Reader extends Thread {
    // ★ 待注册的连接队列（线程安全）
    final private BlockingQueue<Connection> pendingConnections;
    private final Selector readSelector;

    private synchronized void doRunLoop() {
        while (running) {
            try {
                // 1. 从 Listener 转来的连接注册到自己的 Selector
                int size = pendingConnections.size();
                for (int i = size; i > 0; i--) {
                    Connection conn = pendingConnections.take();
                    conn.channel.register(readSelector, 
                        SelectionKey.OP_READ, conn);
                }
                
                // 2. 等待可读事件
                readSelector.select();
                
                // 3. 遍历可读的连接
                Iterator<SelectionKey> iter = 
                    readSelector.selectedKeys().iterator();
                while (iter.hasNext()) {
                    SelectionKey key = iter.next();
                    iter.remove();
                    if (key.isReadable()) {
                        doRead(key);  // 读取请求
                    }
                }
            } catch (Exception e) { ... }
        }
    }
}

// doRead 最终会调用 Connection.readAndProcess()
// → 解析 RPC Header
// → 反序列化请求
// → 创建 Call 对象
// → 放入 CallQueue
```

#### 3.2.3 Handler — 请求处理

```java
// 文件: hadoop-common/src/main/java/org/apache/hadoop/ipc/Server.java
// 行号: 2462-2515

private class Handler extends Thread {
    public Handler(int instanceNumber) {
        this.setDaemon(true);
        this.setName("IPC Server handler " + instanceNumber 
            + " on " + port);
    }

    @Override
    public void run() {
        SERVER.set(Server.this);
        while (running) {
            try {
                // ★ 核心：从 CallQueue 取出请求（可能阻塞）
                final Call call = callQueue.take();
                
                CurCall.set(call);
                
                // 设置调用上下文
                CallerContext.setCurrent(call.callerContext);
                
                // ★ 以调用者身份执行请求
                UserGroupInformation remoteUser = call.getRemoteUser();
                if (remoteUser != null) {
                    remoteUser.doAs(call);  // call.run() 在用户身份下执行
                } else {
                    call.run();
                }
            } catch (InterruptedException e) {
                if (running) {
                    LOG.info(getName() + " unexpectedly interrupted", e);
                }
            } catch (Exception e) {
                LOG.info(getName() + " caught an exception", e);
            } finally {
                CurCall.set(null);
            }
        }
    }
}
```

#### 3.2.4 Responder — 异步响应

```java
// 文件: hadoop-common/src/main/java/org/apache/hadoop/ipc/Server.java
// 行号: 1181-1280

private class Responder extends Thread {
    private final Selector writeSelector;
    final static int PURGE_INTERVAL = 900000; // 15分钟清理一次

    private void doRunLoop() {
        while (running) {
            try {
                waitPending();
                writeSelector.select(PURGE_INTERVAL);
                
                Iterator<SelectionKey> iter = 
                    writeSelector.selectedKeys().iterator();
                while (iter.hasNext()) {
                    SelectionKey key = iter.next();
                    iter.remove();
                    if (key.isWritable()) {
                        // ★ 异步写入响应
                        doAsyncWrite(key);
                    }
                }
                
                // 定期清理超时未发送的响应
                // 防止某个连接断了导致响应堆积
            } catch (Exception e) { ... }
        }
    }
}

// ★ 设计要点：
// Handler 处理完请求后，先尝试直接写响应（channelWrite）
// 如果一次写不完（TCP 缓冲区满），才注册到 Responder 的 Selector
// 由 Responder 异步完成写入
// 这样大部分小响应可以在 Handler 线程直接完成，减少线程切换
```

### 3.3 Client 端源码剖析

#### 3.3.1 ProtobufRpcEngine.Invoker — 客户端调用入口

```java
// 文件: hadoop-common/src/main/java/org/apache/hadoop/ipc/ProtobufRpcEngine.java
// 行号: 116-200

private static class Invoker implements RpcInvocationHandler {
    private final Client.ConnectionId remoteId;
    private final Client client;
    private final String protocolName;

    /**
     * 动态代理的 invoke 方法
     * 当用户调用 protocol 接口方法时，自动走这里
     */
    @Override
    public Message invoke(Object proxy, final Method method, Object[] args)
        throws ServiceException {
        
        // 1. 构造 RPC 请求头
        RequestHeaderProto rpcRequestHeader = 
            constructRpcRequestHeader(method);
        // 包含: methodName, declaringClassProtocolName, clientProtocolVersion
        
        // 2. 获取 Protobuf 请求参数 (args[1])
        // args[0] 是 RpcController, args[1] 是 Protobuf Message
        Message theRequest = (Message) args[1];
        
        // 3. 发起 RPC 调用
        // ★ 关键：通过 Client 发送请求并等待响应
        final RpcWritable.Buffer val;
        val = (RpcWritable.Buffer) client.call(
            RPC.RpcKind.RPC_PROTOCOL_BUFFER,    // RPC 类型
            new RpcProtobufRequest(rpcRequestHeader, theRequest), // 请求
            remoteId,                             // 连接ID
            fallbackToSimpleAuth);                // 降级认证标志
        
        // 4. 反序列化响应
        Message prototype = getReturnProtoType(method);
        Message returnMessage = prototype.newBuilderForType()
            .mergeFrom(val.getValue()).build();
            
        return returnMessage;
    }
}
```

### 3.4 调用链时序图

```
Client                                     Server
ProtobufRpcEngine.Invoker                  Listener  Reader  Handler  Responder
    |                                         |        |        |        |
    |-- 序列化请求 (Protobuf) -->              |        |        |        |
    |-- Client.call() -->                     |        |        |        |
    |   Client.Connection.sendRpcRequest()    |        |        |        |
    |                                         |        |        |        |
    |======= TCP =============================>|        |        |        |
    |                                         |        |        |        |
    |                                  accept()|        |        |        |
    |                                  分配Reader        |        |        |
    |                                         |------->|        |        |
    |                                         |  add   |        |        |
    |                                         |Connection        |        |
    |                                         |        |        |        |
    |                                         |  select()|       |        |
    |                                         |  read() |        |        |
    |                                         |  解析请求|        |        |
    |                                         |  构造Call|        |        |
    |                                         | callQueue.put()  |        |
    |                                         |        |------->|        |
    |                                         |        |        |        |
    |                                         |        | take() |        |
    |                                         |        |  ↓     |        |
    |                                         |        | 反序列化|        |
    |                                         |        | 调用方法|        |
    |                                         |        | 序列化响应       |
    |                                         |        |  ↓     |        |
    |                                         |        | 直接write        |
    |                                         |        | (小响应)|        |
    |<====== TCP ==============================|========|========|        |
    |                                         |        |        |        |
    | -- 若响应大，交给Responder:              |        |        |        |
    |                                         |        |  注册   |------->|
    |                                         |        | Selector|  异步  |
    |<====== TCP ==============================|========|========|  write |
    |                                         |        |        |        |
    |-- 反序列化响应 (Protobuf)               |        |        |        |
    |-- 返回结果给调用者                       |        |        |        |
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：NameNode RPC CallQueue 满

```
# 症状
WARN ipc.Server: Large response: 5242880 bytes
WARN ipc.Server: IPC Server handler on 8020, call queue size 1000

# 原因：Handler 线程被大操作阻塞（如 ls 大目录、递归 count）

# 排障：
# 1. 查看 NN JMX 指标
curl http://nn-host:9870/jmx | grep -i "callqueue\|rpc"

# 2. 检查 Handler 线程状态
jstack <nn-pid> | grep "IPC Server handler"

# 3. 增加 Handler 线程数
dfs.namenode.handler.count = 100  # 默认10，生产建议集群DN数的 20*ln(集群大小)

# 4. 启用 FairCallQueue 防止大操作饥饿小操作
ipc.<port>.callqueue.impl = org.apache.hadoop.ipc.FairCallQueue
```

#### 场景2：Client RPC 超时

```
# 症状
ERROR: Call From client to nn-host:8020 failed on socket timeout exception

# 原因：
# 1. NN Handler 线程满（见场景1）
# 2. 网络问题
# 3. NN GC 导致 STW

# 排障：
ipc.client.connect.timeout = 20000     # 连接超时
ipc.client.connect.max.retries = 10     # 连接重试
ipc.ping.interval = 60000              # Ping 间隔
```

### 4.2 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.namenode.handler.count` | 10 | NN Handler 线程数（建议 20*ln(DN数)） |
| `dfs.namenode.service.handler.count` | 10 | NN 服务端 Handler（DN心跳等） |
| `ipc.server.read.threadpool.size` | 1 | Reader 线程数（建议 = Handler/10） |
| `ipc.<port>.callqueue.impl` | LinkedBlockingQueue | CallQueue 实现（推荐 FairCallQueue） |
| `ipc.maximum.data.length` | 67108864 (64MB) | 单个 RPC 最大数据量 |
| `ipc.client.connect.timeout` | 20000ms | 客户端连接超时 |
| `ipc.server.max.connections` | 0 (无限) | 最大连接数 |

---

## 五、举一反三

### 5.1 与其他 RPC 框架的类比

| 特性 | Hadoop RPC | gRPC | Thrift | Dubbo |
|------|-----------|------|--------|-------|
| 序列化 | Protobuf/Writable | Protobuf | TBinaryProtocol | Hessian/Protobuf |
| 传输层 | 自研 NIO | HTTP/2 | TSocket/TNonblocking | Netty |
| 线程模型 | Reactor (L→R→H→R) | Netty EventLoop | TThreadPoolServer | Netty |
| 服务发现 | 配置文件 | Consul/etcd | Zookeeper | Zookeeper |
| 认证 | SASL/Kerberos | TLS/Token | SASL | Token |

### 5.2 面试高频题

**Q1: Hadoop RPC 的线程模型是什么？每种线程的作用？**

A: 经典 Reactor 模式。Listener(1个)负责 accept 连接；Reader(N个)负责读取请求数据，用 NIO Selector 多路复用；Handler(M个)负责实际业务处理；Responder(1个)负责异步发送大响应。小响应由 Handler 直接写回。

**Q2: 为什么 Handler 处理完请求后要尝试直接写响应，而不是统一交给 Responder？**

A: 优化。大部分 RPC 响应较小，可以在一次 `channel.write()` 中写完。直接写避免了线程切换和 Selector 注册的开销。只有当 TCP 缓冲区满写不完时，才交给 Responder 异步完成。

**Q3: NameNode handler.count 应该设多少？**

A: 经验公式是 `20 * ln(集群 DataNode 数量)`。如 100 个 DN → 约 92 个 Handler。太少会导致 CallQueue 堆积，太多会导致线程切换和锁竞争增加。还应配合 FairCallQueue 使用防止长请求饿死短请求。

**Q4: ProtobufRpcEngine 和 WritableRpcEngine 的区别？**

A: Hadoop 2.x 开始推荐 ProtobufRpcEngine。区别：1) 序列化效率更高（Protobuf vs Java Writable）；2) 跨语言兼容（Protobuf 有多语言 binding）；3) Schema evolution 更好（Protobuf 字段可选）。WritableRpcEngine 已标记 @Deprecated。

### 5.3 思考题

1. **如果 Reader 线程只有 1 个（默认），会不会成为瓶颈？什么场景下需要增加？**
2. **FairCallQueue 是如何防止长请求饿死短请求的？它的调度算法是什么？**
3. **Hadoop RPC 能否做到异步调用？如果能，怎么实现的？**

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────┐
│              Hadoop RPC 框架知识晶体                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  核心设计: Reactor 模式 (NIO多路复用)                        │
│                                                             │
│  Server端4类线程:                                            │
│  Listener(1) → Reader(N) → [CallQueue] → Handler(M) → Responder(1)│
│  accept连接     读请求       FIFO/Fair     处理请求     异步写响应│
│                                                             │
│  Client端:                                                   │
│  ProtobufRpcEngine.Invoker (动态代理)                       │
│  → Client.call() → Connection.sendRpcRequest()              │
│  → 阻塞等待响应 → receiveRpcResponse()                     │
│                                                             │
│  序列化: Protobuf (推荐) / Writable (旧)                    │
│  认证: SASL (Simple/Kerberos/Token)                         │
│                                                             │
│  关键参数:                                                   │
│    handler.count = 20*ln(DN数)                              │
│    read.threadpool.size = handler/10                         │
│    callqueue.impl = FairCallQueue (防饥饿)                  │
│                                                             │
│  性能优化:                                                   │
│    小响应Handler直接写(避免Responder切换)                    │
│    BR拆分为多RPC(避免单个RPC过大)                            │
│    ConnectionManager清理idle连接                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/ipc/Server.java` (3100+ 行，核心 Reactor 实现)
2. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/ipc/Client.java` (客户端实现)
3. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/ipc/ProtobufRpcEngine.java` (Protobuf RPC 引擎)
4. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-common-project/hadoop-common/src/main/java/org/apache/hadoop/ipc/RPC.java` (RPC 工厂)
5. [Reactor Pattern](https://en.wikipedia.org/wiki/Reactor_pattern) — Doug Lea's Scalable IO in Java
6. [HDFS-9903: FairCallQueue 设计](https://issues.apache.org/jira/browse/HDFS-9903)
