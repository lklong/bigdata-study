# 教案 S08：YARN Container 日志聚合 — 排障时找不到日志怎么办？

> **课时**：30分钟 | **难度**：⭐⭐

## 一、课前导入

> 你的 Spark 作业失败了，想看 Executor 的日志。但 Container 已经退出，本地日志被清理了。你慌了——日志去哪了？答案：如果开启了**日志聚合**，日志被上传到 HDFS 了。

## 二、日志聚合流程

```
Container 运行时:
  日志写在 NM 本地: ${yarn.nodemanager.log-dirs}/app-id/container-id/

Container 结束后:
  日志聚合线程 → 打包上传到 HDFS
  HDFS 路径: ${yarn.nodemanager.remote-app-log-dir}/${user}/logs/app-id/

本地日志保留:
  ${yarn.nodemanager.log.retain-seconds} 后删除（默认 3 小时）
```

## 三、关键配置

```xml
<!-- 开启日志聚合 -->
<property>
    <name>yarn.log-aggregation-enable</name>
    <value>true</value>
</property>

<!-- HDFS 存储路径 -->
<property>
    <name>yarn.nodemanager.remote-app-log-dir</name>
    <value>/tmp/logs</value>
</property>

<!-- 日志在 HDFS 保留多久 -->
<property>
    <name>yarn.log-aggregation.retain-seconds</name>
    <value>604800</value>  <!-- 7 天 -->
</property>

<!-- 本地日志保留时间（聚合前的备份） -->
<property>
    <name>yarn.nodemanager.log.retain-seconds</name>
    <value>10800</value>  <!-- 3 小时 -->
</property>
```

## 四、查看聚合日志

```bash
# 方式 1: yarn logs 命令
yarn logs -applicationId application_12345_001

# 方式 2: 只看某个 Container
yarn logs -applicationId application_12345_001 -containerId container_e01_12345_001_000002

# 方式 3: 直接看 HDFS
hdfs dfs -ls /tmp/logs/user/logs/application_12345_001/
hdfs dfs -text /tmp/logs/user/logs/application_12345_001/node1_8041

# 方式 4: Spark History Server (有 UI)
# 方式 5: YARN ResourceManager Web UI → Application → logs
```

## 五、课堂练习

### 思考题：日志聚合失败了怎么办？

<details>
<summary>参考答案</summary>

常见原因和解法：
1. **HDFS 权限问题** → 检查日志目录权限，确保 yarn 用户能写
2. **HDFS 空间不足** → 清理旧日志 or 增加配额
3. **NM 本地日志被提前删除** → 增大 `log.retain-seconds`
4. **聚合线程超时** → 检查 NM 到 HDFS 的网络连通性
5. **应急方案**：如果聚合失败，趁 retain 时间内直接去 NM 本地目录找
</details>

## 六、知识晶体

```
日志聚合: Container结束 → NM打包上传HDFS → 本地删除
查看: yarn logs -applicationId xxx
保留: HDFS retain=7天(可配), 本地=3小时
排障: 聚合失败趁retain时间去NM本地找
```

*教案作者：Eric | 最后更新：2026-04-30*
