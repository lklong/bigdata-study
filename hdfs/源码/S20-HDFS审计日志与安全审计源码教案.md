# [教案] HDFS审计日志与安全审计源码深度剖析

> 🎯 教学目标：掌握HDFS审计日志（Audit Log）的架构设计、AuditLogger接口体系、FSNamesystem中审计事件的触发点、审计日志格式解析、TopAuditLogger热点统计、以及与Ranger审计的集成  
> ⏰ 预计学时：2.5学时  
> 📊 难度：★★★☆☆

---

## 一、课前导入（生活类比/故障场景引入）

### 1.1 生活类比：银行监控录像

想象银行的安全监控系统：
- **审计日志** = 监控录像 + 交易流水
- **AuditLogger** = 摄像头（记录每一个人的每一次操作）
- **TopAuditLogger** = 统计大屏（哪个柜台最忙？谁操作最频繁？）
- **Ranger审计** = 合规部门（审查是否有越权操作）

### 1.2 生产故障场景引入

**场景1：数据被误删排查**
- 凌晨3:00，生产表`/warehouse/fact_order`目录被删除
- 通过审计日志快速定位：`who(用户) + when(时间) + what(操作) + where(IP)`
- 审计日志：`2024-01-15 03:00:12 allowed=true ugi=etl_admin ip=/10.0.1.55 cmd=delete src=/warehouse/fact_order`

**场景2：安全合规审查**
- 监管要求证明"只有授权人员访问过客户数据"
- 通过审计日志导出所有对`/data/customer/`的访问记录
- 配合Ranger Policy验证每次访问都经过授权

---

## 二、核心概念讲解

### 2.1 术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| Audit Log | 审计日志 | 记录所有对HDFS的操作（成功和失败） |
| AuditLogger | 审计记录器 | 接口，定义审计事件的处理方式 |
| DefaultAuditLogger | 默认审计器 | 将审计事件写入log4j的hdfs-audit.log |
| TopAuditLogger | Top热点统计器 | 将审计事件汇入指标系统，统计Top用户/操作 |
| FSNamesystem | 文件系统核心 | 审计事件的产生地 |
| logAuditEvent() | 记录审计事件 | FSNamesystem中每个操作完成后调用 |
| Ranger Audit | Ranger审计 | Apache Ranger的授权审计，记录策略评估结果 |
| auditLog | 审计日志Logger | log4j中名为`org.apache.hadoop.hdfs.server.namenode.FSNamesystem.audit`的logger |

### 2.2 审计日志架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                      FSNamesystem                                     │
│                                                                     │
│  create() / delete() / rename() / setPermission() / open() ...     │
│      │                                                              │
│      ▼ 操作完成后                                                    │
│  logAuditEvent(succeeded, userName, addr, cmd, src, dst, stat)      │
│      │                                                              │
│      ├──────────────────┬────────────────────┐                      │
│      ▼                  ▼                    ▼                      │
│  ┌──────────────┐  ┌───────────────┐  ┌────────────────────┐      │
│  │DefaultAudit- │  │TopAuditLogger │  │Custom AuditLogger  │      │
│  │Logger        │  │(热点统计)     │  │(如Ranger插件)      │      │
│  └──────┬───────┘  └───────┬───────┘  └────────┬───────────┘      │
│         │                  │                    │                   │
│         ▼                  ▼                    ▼                   │
│  hdfs-audit.log     TopMetrics/JMX        Ranger/Solr/Kafka       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 三、源码深度剖析

### 3.1 AuditLogger接口

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/AuditLogger.java`

```java
// 第33-61行：审计日志接口定义
@InterfaceAudience.Public
@InterfaceStability.Evolving
public interface AuditLogger {

  /**
   * Called during initialization of the logger.
   */
  void initialize(Configuration conf);

  /**
   * Called to log an audit event.
   * This method must return as quickly as possible, since it's called
   * in a critical section of the NameNode's operation.
   *
   * @param succeeded Whether authorization succeeded.
   * @param userName Name of the user executing the request.
   * @param addr Remote address of the request.
   * @param cmd The requested command.
   * @param src Path of affected source file.
   * @param dst Path of affected destination file (if any).
   * @param stat File information for operations that change the file's metadata.
   */
  void logAuditEvent(boolean succeeded, String userName,
      InetAddress addr, String cmd, String src, String dst,
      FileStatus stat);
}
```

**设计要点**：
- 接口方法必须快速返回（在NameNode关键路径上调用）
- 7个参数完整描述了一次操作的所有关键信息
- 支持多个AuditLogger同时工作（责任链模式）

### 3.2 FSNamesystem中的审计调用点

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java`

审计事件在FSNamesystem的每个文件操作完成后触发。以下是核心模式：

```java
// FSNamesystem.java (审计逻辑伪代码，真实代码分散在各操作方法中)

// 审计日志Logger（log4j）
private static final Log auditLog = LogFactory.getLog(
    FSNamesystem.class.getName() + ".audit");

// 可插拔的AuditLogger列表
private List<AuditLogger> auditLoggers;

/**
 * 记录审计事件的核心方法
 */
private void logAuditEvent(boolean succeeded, String cmd, String src) {
  logAuditEvent(succeeded, cmd, src, null, null);
}

private void logAuditEvent(boolean succeeded, String cmd, String src, 
    String dst, FileStatus stat) {
  // 获取当前用户信息
  final UserGroupInformation ugi = getRemoteUser();
  final String ugiStr = ugi.toString();
  // 获取客户端IP
  final InetAddress addr = getRemoteIp();
  
  // 1. 写入默认的log4j audit日志
  if (auditLog.isInfoEnabled()) {
    final StringBuilder sb = auditBuffer.get();
    sb.setLength(0);
    sb.append("allowed=").append(succeeded).append("\t");
    sb.append("ugi=").append(ugiStr).append("\t");
    sb.append("ip=").append(addr).append("\t");
    sb.append("cmd=").append(cmd).append("\t");
    sb.append("src=").append(src).append("\t");
    sb.append("dst=").append(dst).append("\t");
    sb.append("perm=").append(stat == null ? "null" : 
        stat.getOwner() + ":" + stat.getGroup() + ":" + stat.getPermission());
    auditLog.info(sb);
  }
  
  // 2. 调用所有注册的AuditLogger
  for (AuditLogger logger : auditLoggers) {
    try {
      logger.logAuditEvent(succeeded, ugiStr, addr, cmd, src, dst, stat);
    } catch (RuntimeException e) {
      LOG.error("Error in audit logger", e);
    }
  }
}

// 典型调用示例 —— create操作
HdfsFileStatus startFile(String src, ...) throws IOException {
  HdfsFileStatus stat = null;
  try {
    stat = startFileInt(src, ...);  // 实际创建逻辑
  } catch (AccessControlException e) {
    logAuditEvent(false, "create", src);  // 权限拒绝也记录
    throw e;
  }
  logAuditEvent(true, "create", src, null, stat);  // 成功记录
  return stat;
}

// 典型调用示例 —— delete操作
boolean delete(String src, boolean recursive) throws IOException {
  boolean ret = false;
  try {
    ret = deleteInt(src, recursive);
  } catch (AccessControlException e) {
    logAuditEvent(false, "delete", src);
    throw e;
  }
  if (ret) {
    logAuditEvent(true, "delete", src);
  }
  return ret;
}
```

**所有会触发审计的操作（cmd字段值）**：

| cmd | 操作 | 说明 |
|-----|------|------|
| create | 创建文件 | create/append |
| open | 打开文件 | getBlockLocations |
| delete | 删除 | delete(recursive) |
| rename | 重命名 | rename/concat |
| mkdirs | 创建目录 | mkdirs |
| listStatus | 列举目录 | listStatus/getFileInfo |
| setPermission | 设置权限 | chmod |
| setOwner | 设置所有者 | chown |
| setReplication | 设置副本 | setReplication |
| setTimes | 设置时间 | setTimes |
| getfileinfo | 获取文件信息 | getFileInfo |
| contentSummary | 内容摘要 | getContentSummary |
| setQuota | 设置配额 | setQuota |
| getEZForPath | 获取加密区 | getEZForPath |
| createEncryptionZone | 创建加密区 | createEZ |

### 3.3 TopAuditLogger——热点统计

**文件路径**: `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/top/TopAuditLogger.java`

```java
// 第37-82行：TopAuditLogger实现
@InterfaceAudience.Private
public class TopAuditLogger implements AuditLogger {
  private final TopMetrics topMetrics;

  public TopAuditLogger(TopMetrics topMetrics) {
    Preconditions.checkNotNull(topMetrics);
    this.topMetrics = topMetrics;
  }

  @Override
  public void initialize(Configuration conf) {
    // TopMetrics已在构造时注入
  }

  @Override
  public void logAuditEvent(boolean succeeded, String userName,
      InetAddress addr, String cmd, String src, String dst, FileStatus status) {
    try {
      // 将审计事件汇入TopMetrics进行统计
      topMetrics.report(succeeded, userName, addr, cmd, src, dst, status);
    } catch (Throwable t) {
      LOG.error("Error reflecting event in top service, cmd={}, user={}",
          cmd, userName);
    }
  }
}
```

TopMetrics内部维护滑动窗口统计：
- Top N 活跃用户（按操作数量）
- Top N 频繁操作（cmd类型分布）
- Top N 热点路径（被访问最多的文件/目录）

可通过JMX/Web UI查看：`http://namenode:9870/topUsers`

### 3.4 审计日志格式详解

**默认输出位置**：`/var/log/hadoop/hdfs-audit.log`（通过log4j配置）

**标准格式**：
```
2024-01-15 08:30:12,345 INFO FSNamesystem.audit: allowed=true	ugi=alice@EXAMPLE.COM (auth:KERBEROS)	ip=/10.0.1.100	cmd=open	src=/data/warehouse/orders/part-00000	dst=null	perm=alice:analytics:rw-r-----
```

**字段解析**：

| 字段 | 含义 | 示例 |
|------|------|------|
| allowed | 操作是否被允许 | true/false |
| ugi | 用户标识（含认证方式） | alice@REALM (auth:KERBEROS) |
| ip | 客户端IP | /10.0.1.100 |
| cmd | 操作命令 | open/create/delete/rename |
| src | 源路径 | /data/warehouse/orders |
| dst | 目标路径（rename时） | /data/warehouse/orders_bak |
| perm | 权限信息 | owner:group:permission |

### 3.5 log4j审计日志配置

```properties
# log4j.properties (NameNode)
# 审计日志配置
log4j.logger.org.apache.hadoop.hdfs.server.namenode.FSNamesystem.audit=INFO,RFAAUDIT
log4j.additivity.org.apache.hadoop.hdfs.server.namenode.FSNamesystem.audit=false

# 审计日志输出到独立文件
log4j.appender.RFAAUDIT=org.apache.log4j.RollingFileAppender
log4j.appender.RFAAUDIT.File=/var/log/hadoop/hdfs-audit.log
log4j.appender.RFAAUDIT.MaxFileSize=256MB
log4j.appender.RFAAUDIT.MaxBackupIndex=20
log4j.appender.RFAAUDIT.layout=org.apache.log4j.PatternLayout
log4j.appender.RFAAUDIT.layout.ConversionPattern=%d{ISO8601} %p %c{2}: %m%n
```

### 3.6 与Ranger审计的集成

Apache Ranger通过自定义AuditLogger插件集成：

```java
// RangerHdfsAuditLogger.java (Ranger HDFS插件中)
public class RangerHdfsAuditLogger implements AuditLogger {
  
  private RangerAuditHandler auditHandler;  // Ranger审计处理器
  
  @Override
  public void logAuditEvent(boolean succeeded, String userName,
      InetAddress addr, String cmd, String src, String dst, FileStatus stat) {
    // 构造Ranger审计事件
    AuthzAuditEvent event = new AuthzAuditEvent();
    event.setUser(userName);
    event.setClientIP(addr.getHostAddress());
    event.setAccessType(cmd);
    event.setResourcePath(src);
    event.setAccessResult(succeeded ? 1 : 0);
    event.setEventTime(new Date());
    event.setRepositoryName("hadoop");
    
    // 发送到Ranger审计后端（Solr/HDFS/Kafka）
    auditHandler.logAuthzAudit(event);
  }
}
```

Ranger审计提供的增强能力：
1. **结构化存储**：审计事件存入Solr/ES，支持全文检索
2. **策略关联**：每条审计记录关联授权策略ID
3. **Web UI**：可视化审计报表和查询
4. **告警**：异常访问模式自动告警

---

## 四、生产实战案例

### 4.1 案例一：通过审计日志排查数据删除事件

```bash
# 1. 快速定位谁删除了/warehouse/fact_order
grep "cmd=delete.*src=/warehouse/fact_order" /var/log/hadoop/hdfs-audit.log
# 2024-01-15 03:00:12,345 INFO allowed=true ugi=etl_admin ip=/10.0.1.55 
#   cmd=delete src=/warehouse/fact_order dst=null perm=etl_admin:hadoop:rwxr-x---

# 2. 追溯该用户近期所有操作
grep "ugi=etl_admin" /var/log/hadoop/hdfs-audit.log | grep "2024-01-15 03:" | head -20

# 3. 追溯该IP的所有操作
grep "ip=/10.0.1.55" /var/log/hadoop/hdfs-audit.log | grep "2024-01-15 03:"
```

### 4.2 案例二：安全合规——敏感目录访问审计

```bash
# 统计谁访问了客户数据目录
grep "src=/data/customer" /var/log/hadoop/hdfs-audit.log | \
  awk -F'\t' '{print $2}' | sort | uniq -c | sort -rn | head -10

# 检查是否有未授权访问（allowed=false）
grep "allowed=false.*src=/data/customer" /var/log/hadoop/hdfs-audit.log

# 导出为CSV供合规部门审查
grep "src=/data/customer" /var/log/hadoop/hdfs-audit.log | \
  awk -F'\t' '{print $1","$2","$3","$4","$5}' > customer_access_audit.csv
```

### 4.3 审计日志监控脚本

```bash
#!/bin/bash
# 实时监控高危操作
tail -F /var/log/hadoop/hdfs-audit.log | \
  grep -E "cmd=(delete|rename|setPermission|setOwner)" | \
  while read line; do
    echo "[ALERT] High-risk operation detected: $line" | \
      mail -s "HDFS Audit Alert" admin@example.com
  done
```

### 4.4 启用自定义AuditLogger

```xml
<!-- hdfs-site.xml -->
<property>
  <name>dfs.namenode.audit.loggers</name>
  <value>default,org.apache.hadoop.hdfs.server.namenode.top.TopAuditLogger</value>
  <!-- 可以加入自定义logger，如Ranger -->
</property>

<!-- 启用Top热点统计 -->
<property>
  <name>dfs.namenode.top.enabled</name>
  <value>true</value>
</property>
<property>
  <name>dfs.namenode.top.window.num.buckets</name>
  <value>10</value>
</property>
<property>
  <name>dfs.namenode.top.num.users</name>
  <value>10</value>
</property>
```

---

## 五、举一反三

### 5.1 面试高频题

**Q1：HDFS审计日志记录了哪些信息？在什么时机触发？**

A：记录7个字段：allowed(成功/失败)、ugi(用户)、ip(地址)、cmd(命令)、src(源路径)、dst(目标路径)、perm(权限信息)。在FSNamesystem中每个文件系统操作完成后调用logAuditEvent()触发，无论操作成功还是失败（权限拒绝）都会记录。

**Q2：审计日志对NameNode性能有影响吗？如何优化？**

A：有影响但通常可接受：
- 每次操作多一次StringBuilder拼接 + log4j写入
- 优化措施：使用AsyncAppender异步写日志、限制auditLogger数量、TopAuditLogger内部使用无锁统计

**Q3：如何实现审计日志的集中收集和分析？**

A：
- 方案1：Flume/Filebeat采集 → Kafka → ES/Solr → Kibana可视化
- 方案2：Ranger审计插件 → 直接写入Solr/HDFS
- 方案3：log4j KafkaAppender直接投递到Kafka

### 5.2 思考题

1. 审计日志中`allowed=false`的记录意味着什么？如何利用它发现安全威胁？
2. 如果审计日志量过大（每天100GB+），如何做归档和查询优化？
3. 在启用Kerberos的集群中，审计日志的`ugi`字段会是什么格式？如何关联到真实用户？

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────────────┐
│         HDFS 审计日志与安全审计 · 知识晶体                            │
├─────────────────────────────────────────────────────────────────────┤
│  【核心接口】AuditLogger.logAuditEvent(succeeded,user,ip,cmd,src,..)│
│  【触发时机】FSNamesystem每个操作完成后，成功/失败都记录              │
│  【默认输出】hdfs-audit.log（log4j RollingFileAppender）            │
│  【日志格式】allowed=T/F  ugi=用户  ip=地址  cmd=命令  src=路径     │
│  【TopAuditLogger】汇入TopMetrics，统计Top用户/操作/路径            │
│  【Ranger集成】自定义AuditLogger → Solr/ES/Kafka结构化存储          │
│  【关键用途】安全合规 / 误操作排查 / 异常检测 / 访问统计             │
│  【性能提示】审计在关键路径上，logger.logAuditEvent()必须快速返回   │
│  【配置】dfs.namenode.audit.loggers=default,TopAuditLogger,...     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. **源码文件**
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/AuditLogger.java`
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSNamesystem.java`（audit相关代码）
   - `hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/top/TopAuditLogger.java`

2. **相关文档**
   - HDFS-6801: Pluggable Audit Logger
   - Apache Ranger: HDFS Plugin Audit
   - Hadoop Security Guide: Auditing
