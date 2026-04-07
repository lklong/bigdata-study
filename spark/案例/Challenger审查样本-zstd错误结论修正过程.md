# Challenger 审查样本：K8s vs YARN 分析中的"zstd 错误结论→修正"

> 来源案例：K8s vs YARN 性能对比（K8s 慢 8%），2026-04-07
> 目的：作为 Challenger 审查的标准样本，展示"错误结论如何被源码推翻"的完整过程

---

## 错误结论的产生过程

### 第一版报告的结论（错误）

```
根因 #1: Native Hadoop Library 缺失导致 zstd 解压变慢 → 占 77%
证据: K8s 日志 "WARN NativeCodeLoader: Unable to load native-hadoop library"
推理: native lib 缺失 → zstd 解压走 Java fallback → 比 native 慢 2-5x
```

### 看起来合理的推理链

```
NativeCodeLoader 加载失败
  → Hadoop 没有 native zstd 库
  → zstd 解压走纯 Java 实现
  → 每个 task 读 380MB zstd 数据变慢
  → 34,466 tasks 累积出 250s+ 差距
```

### 为什么这个结论被接受了？

1. 日志中确实有 WARN（看起来有证据）
2. scan time 差 6.2%（看起来有数据支撑）
3. "native 比 Java 快" 是常识（看起来逻辑通）
4. 数字能算得拢（250s 占 77%，看起来合理）

---

## 源码推翻的过程

### 追踪 1: Spark 3.3.2 的 zstd 实现

```
源码: core/src/main/scala/org/apache/spark/io/CompressionCodec.scala
第 23 行: import com.github.luben.zstd.{..., ZstdInputStreamNoFinalizer, ...}
第 241-244 行: 
  override def compressedInputStream(s: InputStream): InputStream = {
    new BufferedInputStream(new ZstdInputStreamNoFinalizer(s, bufferPool), bufferSize)
  }

结论: Spark Core 的 zstd 用 zstd-jni (JNI 自带 native .so)，不依赖 libhadoop.so
```

### 追踪 2: ORC 1.7.8 的 zstd 实现

```
pom.xml 第 137 行: <orc.version>1.7.8</orc.version>

ORC 1.7.8 的 ZSTD 内部实现:
  → org.apache.orc.impl.InStream 
  → io.airlift.compress.zstd.ZstdDecompressor (aircompressor 库)
  → 纯 Java 实现，不依赖任何 native lib

结论: ORC 的 zstd 用 aircompressor（纯 Java），不走 Hadoop CodecPool
```

### 追踪 3: NativeCodeLoader 加载的是什么？

```
NativeCodeLoader（Hadoop 源码，不在 Spark 仓库中）:
  → 加载 libhadoop.so
  → 包含: CRC32C native 加速、snappy native、LZ4 native
  → 不包含: zstd（Hadoop 3.3.2 的 zstd 也是基于 zstd-jni）

结论: "Unable to load native-hadoop library" 对 zstd 完全无影响
```

### 追踪 4: CodecPool 日志的来源

```
"CodecPool: Got brand-new decompressor [.zstd]"
→ 来自 Hadoop 的 org.apache.hadoop.io.compress.CodecPool
→ 在读取 COS 上的 zstd 文件时触发
→ Hadoop 3.3.2 的 ZStandardCodec 内部也用 zstd-jni
→ 两端都打了这条日志，说明两端走的是相同的 codec
```

---

## 修正后的结论

```
原结论: "Native lib 缺失 → zstd 慢 → 占 77%"  ❌ 错误
修正为: "I/O 等待增加 → 占 82.4%" (通过 executorCpuTime 精确拆解验证)

关键证据:
  executorRunTime 差: +34,871s
  executorCpuTime 差: +6,149s (仅 17.6%)
  I/O 等待差:        +28,722s (82.4%)  ← 真正的主因

zstd 两端完全相同（源码铁证），差距全在 I/O 层面
```

---

## Challenger 经验总结

### 教训 1: 相关性 ≠ 因果性

```
❌ "NativeCodeLoader WARN 出现了" + "scan time 慢了" ≠ "因为 native lib 所以慢"
✅ 必须追踪到源码级别，确认 zstd 的实际调用路径
```

### 教训 2: 排除法不能偷懒

```
❌ "解压相同，所以差异只能来自 I/O" — 排除不完整
✅ 还要排除: CPU cgroup throttle / JIT 差异 / 内存带宽 / NUMA
✅ 用 executorCpuTime 精确拆解 CPU vs I/O
```

### 教训 3: 数字能算得拢 ≠ 正确

```
❌ "250s 占 77%，看起来合理" — 数字是编出来的
✅ 必须有独立的验证手段（executorCpuTime 就是独立验证）
```

### 教训 4: 审查标准化工具

```
今后所有"性能差异"报告，Challenger 必须要求:
  1. executorCpuTime vs executorRunTime 拆解（CPU vs I/O）
  2. jvmGCTime 独立列出（GC 影响）
  3. 源码级确认关键路径（不能只看日志推断）
```

---

## 审查检查清单（从本案例提炼）

```
□ 是否有 "看起来有证据但其实是误导" 的日志？
□ 定量归因的百分比是计算出来的还是估出来的？
□ 排除法是否穷举了所有可能？
□ 是否用了 executorCpuTime 做 CPU vs I/O 拆解？
□ 关键代码路径是否追到源码级别？
□ 结论能不能被一个简单的反例推翻？
```
