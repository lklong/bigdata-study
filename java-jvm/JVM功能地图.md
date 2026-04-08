# JVM 功能地图（大数据运维视角）

> 完整能力清单 | 使用方式 | 限制 | 注意事项

---

## 核心能力

| 能力 | 说明 | 使用方式 | 限制 | 注意 |
|------|------|---------|------|------|
| **内存管理** | 堆内存 (Young/Old) + 堆外 (Metaspace/DirectBuffer) | `-Xmx/-Xms/-XX:MaxMetaspaceSize/-XX:MaxDirectMemorySize` | 堆内受 GC 管理；堆外需手动/NIO 管理 | K8s 场景 Pod limit 必须 > Xmx + Overhead |
| **GC (G1)** | 分区式垃圾回收 | `-XX:+UseG1GC -XX:MaxGCPauseMillis=200` | STW 暂停不可避免；大堆 GC 暂停更长 | 生产必须开 GC 日志 |
| **GC (ZGC)** | 亚毫秒级暂停 | `-XX:+UseZGC` (JDK 15+) | 额外 3% 内存开销；不支持 JDK 8 | 延迟敏感场景 |
| **JIT 编译** | 热点代码编译为机器码 | 自动；`-XX:CICompilerCount` 控制编译线程 | 启动阶段有预热期（解释执行慢） | 容器环境 CICompilerCount 被 CPU limit 限制 |
| **容器感知** | 自动感知 cgroup CPU/Memory 限制 | `-XX:+UseContainerSupport` (JDK 8u191+ 默认开启) | CPU limit 影响 GC/JIT 线程数 | 用 `-XX:ActiveProcessorCount` 手动覆盖 |
| **堆 Dump** | 导出堆内存快照分析 | `jmap -dump:format=b,file=heap.hprof <pid>` / `-XX:+HeapDumpOnOutOfMemoryError` | Dump 期间进程暂停（大堆可能几十秒） | OOM 必须自动 Dump |
| **线程 Dump** | 导出线程栈分析死锁/热点 | `jstack <pid>` / `kill -3 <pid>` | 快照瞬时状态，需多次采样 | 死锁排查首选 |
| **Flight Recorder (JFR)** | 低开销性能采样 | `-XX:StartFlightRecording=duration=60s,filename=app.jfr` | JDK 11+ 免费 | CPU/GC/I-O 全面诊断 |
| **远程调试** | JDWP 远程调试 | `-agentlib:jdwp=transport=dt_socket,server=y,address=5005` | 严重影响性能；生产禁用 | 仅开发环境 |

---

## 功能边界

| 不支持 | 替代方案 |
|--------|---------|
| 直接操作硬件内存 | Unsafe (不推荐) / JNI |
| 实时 GC 调优 | 只能通过参数调整 |
| 容器外内存限制 | OS cgroup |

---

*JVM Expert | 功能地图 v1.0 | 2026-04-08*
