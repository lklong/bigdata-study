# [教案] HDFS 权限模型与 ACL 源码分析

> 🎯 教学目标：掌握 HDFS POSIX 权限模型、ACL 扩展机制、FSPermissionChecker 权限检查流程、Delegation Token 认证原理 | ⏰ 预计学时: 75分钟 | 📊 难度: ⭐⭐⭐⭐

---

## 一、课前导入（为什么要学这个？）

### 生活类比：办公室门禁系统

一栋办公楼的安全系统有三层：

1. **基础门禁（POSIX 权限）**：每间办公室有一个"所有者"（Owner），一个"部门"（Group），以及"其他人"（Other）。门禁卡设置为：所有者可以进出+修改，部门成员可以进入，其他人不能进。就像 `rwxr-x---` 这样。

2. **特殊通行证（ACL）**：有时候你需要给特定的人额外权限——"张三虽然不是这个部门的，但他可以进这间办公室"。这就是 ACL（Access Control List）——在基础权限之上的**精细化控制**。

3. **访客临时卡（Delegation Token）**：有客人来访，前台给他一张临时卡，有效期 24 小时，不需要知道门禁密码就能进入。这就是 Delegation Token——客户端可以获取一个临时令牌，代替 Kerberos 认证。

### 生产故障场景

> "Hive 任务报错 `Permission denied: user=hive, access=WRITE, inode="/data/warehouse":hdfs:supergroup:drwxr-xr-x`。明明 hive 用户有 Ranger 策略允许写入，但 HDFS 层面还是拒绝了。原来是 Ranger 插件没生效，HDFS 的原生权限检查先于 Ranger 执行。"

---

## 二、核心概念讲解

### 2.1 关键术语表

| 术语 | 解释 | 类比 |
|------|------|------|
| **FsPermission** | POSIX 风格文件权限（rwxrwxrwx） | 门禁基础设置 |
| **FsAction** | 权限操作类型（READ/WRITE/EXECUTE） | 进/出/改 |
| **AclEntry** | 一条 ACL 规则 | 特殊通行证 |
| **AclFeature** | INode 上附加的 ACL 特性 | 门上贴的特殊规则表 |
| **AclStorage** | ACL 存储工具类，管理 ACL 的读写 | 规则表管理员 |
| **FSPermissionChecker** | 权限检查器核心类 | 安保检查员 |
| **Sticky Bit** | 粘滞位，目录下只有文件所有者能删除文件 | /tmp 目录规则 |
| **INodeAttributeProvider** | 外部权限提供者（如 Ranger） | 外包安保公司 |
| **Delegation Token** | 委托令牌，替代 Kerberos 的临时认证 | 访客临时卡 |
| **Superuser** | 超级用户，跳过所有权限检查 | 大楼管理员 |

### 2.2 HDFS 权限模型全景图

```
┌─────────────────────────────────────────────────────────────────┐
│                   HDFS 权限检查架构                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  用户请求 (如: dfs.create("/data/file.txt"))                     │
│      │                                                          │
│      ▼                                                          │
│  ┌─────────────────────────────────────────┐                    │
│  │  FSNamesystem                            │                    │
│  │  ┌─────────────────────────────────────┐│                    │
│  │  │  getPermissionChecker()              ││                    │
│  │  │  → 创建 FSPermissionChecker          ││                    │
│  │  │                                      ││                    │
│  │  │  checkPermission(iip,                ││                    │
│  │  │    doCheckOwner,                     ││                    │
│  │  │    ancestorAccess=FsAction.WRITE,    ││                    │
│  │  │    parentAccess=FsAction.WRITE,      ││                    │
│  │  │    access=null,                      ││                    │
│  │  │    subAccess=null)                   ││                    │
│  │  └──────────────┬──────────────────────┘│                    │
│  └─────────────────┼───────────────────────┘                    │
│                    ▼                                             │
│  ┌─────────────────────────────────────────┐                    │
│  │  FSPermissionChecker                     │                    │
│  │                                          │                    │
│  │  1. isSuperUser? → 跳过所有检查 ✅        │                    │
│  │                                          │                    │
│  │  2. checkTraverse()                      │                    │
│  │     对路径上每个祖先目录检查 EXECUTE 权限  │                    │
│  │     / → /data → /data/warehouse         │                    │
│  │                                          │                    │
│  │  3. checkStickyBit()                     │                    │
│  │     如果目录有粘滞位，检查删除权限        │                    │
│  │                                          │                    │
│  │  4. hasPermission(inode, access)         │                    │
│  │     ┌──────────────────────────────┐     │                    │
│  │     │ 有 ACL?                       │     │                    │
│  │     │ YES → hasAclPermission()     │     │                    │
│  │     │ NO  → 检查 POSIX rwx 权限    │     │                    │
│  │     └──────────────────────────────┘     │                    │
│  │                                          │                    │
│  │  5. 如有 INodeAttributeProvider (Ranger) │                    │
│  │     → 委托给外部检查器                    │                    │
│  │                                          │                    │
│  └─────────────────────────────────────────┘                    │
│                                                                 │
│  权限存储结构:                                                   │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  INode                                                │       │
│  │  ├─ FsPermission: rwxr-x--- (3 bytes)               │       │
│  │  ├─ userName: "hdfs"                                  │       │
│  │  ├─ groupName: "supergroup"                           │       │
│  │  └─ AclFeature: (可选)                               │       │
│  │      ├─ [USER:alice:rwx]  ← 命名用户ACL              │       │
│  │      ├─ [GROUP:dev:r-x]   ← 命名组ACL                │       │
│  │      └─ [DEFAULT:USER::rwx] ← 默认ACL(仅目录)        │       │
│  └──────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 权限检查优先级

```
1. SuperUser (fsOwner 或 supergroup 成员) → 直接通过 ✅
2. 有 INodeAttributeProvider (如 Ranger) → 委托外部检查
3. 有 ACL → hasAclPermission()
   a. Owner 匹配 → 用 owner permission bits
   b. Named User 匹配 → 用 ACL entry & mask
   c. Group 匹配 → 用 ACL entry & mask  
   d. Other → 用 other permission bits
4. 无 ACL → 标准 POSIX 检查
   a. Owner → user bits (rwx)
   b. Group → group bits (rwx)
   c. Other → other bits (rwx)
```

---

## 三、源码深度剖析

### 3.1 核心类与职责

| 核心类 | 文件路径 | 职责 |
|--------|----------|------|
| `FSPermissionChecker` | `server/namenode/FSPermissionChecker.java` | 权限检查核心逻辑 |
| `AclStorage` | `server/namenode/AclStorage.java` | ACL 读写存储管理 |
| `AclFeature` | `server/namenode/AclFeature.java` | INode 上的 ACL 特性 |
| `AclEntryStatusFormat` | `server/namenode/AclEntryStatusFormat.java` | ACL 条目的紧凑存储格式 |
| `AclTransformation` | `server/namenode/AclTransformation.java` | ACL 的合并、排序、验证 |
| `FsPermission` | `hadoop-common/.../fs/permission/FsPermission.java` | POSIX 权限 |
| `FsAction` | `hadoop-common/.../fs/permission/FsAction.java` | 权限操作枚举 |

### 3.2 关键方法逐行解读

#### 3.2.1 FSPermissionChecker 构造 — 确定用户身份

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSPermissionChecker.java
// 行号: 85-95

FSPermissionChecker(String fsOwner, String supergroup,
    UserGroupInformation callerUgi,
    INodeAttributeProvider attributeProvider) {
    this.fsOwner = fsOwner;           // NN 启动用户（如 hdfs）
    this.supergroup = supergroup;     // 超级用户组（如 supergroup）
    this.callerUgi = callerUgi;       // 调用者身份
    this.groups = callerUgi.getGroups(); // 调用者所属的所有组
    user = callerUgi.getShortUserName(); // 短用户名
    
    // ★ 超级用户判断：用户名 == fsOwner 或 用户属于 supergroup
    isSuper = user.equals(fsOwner) || groups.contains(supergroup);
    
    this.attributeProvider = attributeProvider; // Ranger等外部权限提供者
}
```

#### 3.2.2 checkPermission — 权限检查入口

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSPermissionChecker.java
// 行号: 162-192

void checkPermission(INodesInPath inodesInPath, boolean doCheckOwner,
    FsAction ancestorAccess, FsAction parentAccess, FsAction access,
    FsAction subAccess, boolean ignoreEmptyDir)
    throws AccessControlException {
    
    // 1. 获取路径上所有 INode 的属性
    final INode[] inodes = inodesInPath.getINodesArray();
    final INodeAttributes[] inodeAttrs = new INodeAttributes[inodes.length];
    for (int i = 0; i < inodes.length && inodes[i] != null; i++) {
        // ★ 如果有外部 AttributeProvider (Ranger)，用它的属性
        inodeAttrs[i] = getINodeAttrs(components, i, inodes[i], snapshotId);
    }

    // 2. 获取权限检查器（可能是外部的）
    AccessControlEnforcer enforcer = getAccessControlEnforcer();
    
    // 3. 执行检查
    enforcer.checkPermission(fsOwner, supergroup, callerUgi, 
        inodeAttrs, inodes, components, snapshotId, path, 
        ancestorIndex, doCheckOwner,
        ancestorAccess, parentAccess, access, subAccess, 
        ignoreEmptyDir);
}
```

#### 3.2.3 hasPermission — 核心权限判断

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSPermissionChecker.java
// 行号: 326-348

private boolean hasPermission(INodeAttributes inode, FsAction access) {
    if (inode == null) return true;
    
    final FsPermission mode = inode.getFsPermission();
    final AclFeature aclFeature = inode.getAclFeature();
    
    // ★ 检查是否有 ACL
    if (aclFeature != null) {
        int firstEntry = aclFeature.getEntryAt(0);
        if (AclEntryStatusFormat.getScope(firstEntry) == AclEntryScope.ACCESS) {
            // 有 ACL → 走 ACL 检查逻辑
            return hasAclPermission(inode, access, mode, aclFeature);
        }
    }
    
    // ★ 无 ACL → 标准 POSIX 检查
    final FsAction checkAction;
    if (getUser().equals(inode.getUserName())) {
        // 用户是文件所有者 → 用 owner bits
        checkAction = mode.getUserAction();
    } else if (isMemberOfGroup(inode.getGroupName())) {
        // 用户属于文件的组 → 用 group bits
        checkAction = mode.getGroupAction();
    } else {
        // 其他人 → 用 other bits
        checkAction = mode.getOtherAction();
    }
    return checkAction.implies(access);
}
```

#### 3.2.4 hasAclPermission — ACL 权限判断（POSIX ACL 标准）

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSPermissionChecker.java
// 行号: 373-426

private boolean hasAclPermission(INodeAttributes inode,
    FsAction access, FsPermission mode, AclFeature aclFeature) {
    boolean foundMatch = false;

    // ★ Step 1: Owner 匹配
    if (getUser().equals(inode.getUserName())) {
        if (mode.getUserAction().implies(access)) {
            return true;   // Owner 有权限
        }
        foundMatch = true; // Owner 但无权限 → 不再检查其他
    }

    // ★ Step 2: 遍历 ACL 条目
    if (!foundMatch) {
        for (int pos = 0; pos < aclFeature.getEntriesSize(); pos++) {
            int entry = aclFeature.getEntryAt(pos);
            
            // 跳过 Default ACL
            if (AclEntryStatusFormat.getScope(entry) == AclEntryScope.DEFAULT) {
                break;
            }
            
            AclEntryType type = AclEntryStatusFormat.getType(entry);
            String name = AclEntryStatusFormat.getName(entry);
            
            if (type == AclEntryType.USER) {
                // ★ Named User: user:alice:rwx
                if (getUser().equals(name)) {
                    // 重要：Named User 的权限要和 mask 做 AND！
                    FsAction masked = AclEntryStatusFormat.getPermission(entry)
                        .and(mode.getGroupAction()); // group bits = mask
                    if (masked.implies(access)) {
                        return true;
                    }
                    foundMatch = true;
                    break;
                }
            } else if (type == AclEntryType.GROUP) {
                // ★ Named Group: group:dev:r-x
                String group = name == null ? inode.getGroupName() : name;
                if (isMemberOfGroup(group)) {
                    FsAction masked = AclEntryStatusFormat.getPermission(entry)
                        .and(mode.getGroupAction()); // group bits = mask
                    if (masked.implies(access)) {
                        return true;
                    }
                    foundMatch = true;
                }
            }
        }
    }

    // ★ Step 3: 如果没有任何匹配 → 用 Other 权限
    return !foundMatch && mode.getOtherAction().implies(access);
}
```

**ACL Mask 机制的关键理解**：
```
文件权限: rwxrwx--- (750)
ACL: user:alice:rwx

实际生效权限 = ACL权限 AND mask
mask = group permission bits = rwx (在上面例子中)

所以如果管理员 chmod g=r-- (修改了group bits):
文件权限: rwxr----- (740)
alice实际权限 = rwx AND r-- = r--  (只有读！)

这就是 POSIX ACL 的 mask 机制：
group bits 同时充当 ACL 的 mask
chmod 修改 group bits = 修改 ACL mask
```

#### 3.2.5 AclStorage — ACL 存储与继承

```java
// 文件: hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/AclStorage.java
// 行号: 76-148

/**
 * ACL 继承：父目录的 Default ACL → 子文件/目录的 Access ACL
 */
public static void copyINodeDefaultAcl(INode child) {
    INodeDirectory parent = child.getParent();
    AclFeature parentAclFeature = parent.getAclFeature();
    if (parentAclFeature == null) return;  // 父目录无 ACL

    // 1. 拆分父目录的 ACL 为 Access + Default
    List<AclEntry> featureEntries = getEntriesFromAclFeature(
        parent.getAclFeature());
    ScopedAclEntries scopedEntries = new ScopedAclEntries(featureEntries);
    List<AclEntry> parentDefaultEntries = scopedEntries.getDefaultEntries();

    if (parentDefaultEntries.isEmpty()) return; // 无 Default ACL

    // 2. 将父目录的 Default ACL 复制为子文件的 Access ACL
    List<AclEntry> accessEntries = Lists.newArrayListWithCapacity(
        parentDefaultEntries.size());

    FsPermission childPerm = child.getFsPermission();

    for (AclEntry entry : parentDefaultEntries) {
        AclEntryType type = entry.getType();
        String name = entry.getName();
        
        // ★ 子文件的 umask 过滤父目录的 Default ACL
        final FsAction permission;
        if (type == AclEntryType.USER && name == null) {
            permission = entry.getPermission().and(childPerm.getUserAction());
        } else if (type == AclEntryType.MASK) {
            permission = entry.getPermission().and(childPerm.getGroupAction());
        } else if (type == AclEntryType.OTHER) {
            permission = entry.getPermission().and(childPerm.getOtherAction());
        } else {
            permission = entry.getPermission(); // Named entries 不受 umask 影响
        }

        accessEntries.add(new AclEntry.Builder()
            .setScope(AclEntryScope.ACCESS)
            .setType(type).setName(name)
            .setPermission(permission).build());
    }

    // 3. 如果子节点是目录，还要继承 Default ACL
    List<AclEntry> defaultEntries = child.isDirectory() ? 
        parentDefaultEntries : Collections.emptyList();
    
    // 4. 保存到子节点
    child.addAclFeature(createAclFeature(accessEntries, defaultEntries));
}
```

### 3.3 Delegation Token 认证流程

```
┌───────┐                    ┌──────────┐                  ┌──────────┐
│Client │                    │NameNode  │                  │DataNode  │
│       │                    │(KDC代理) │                  │          │
│       │                    │          │                  │          │
│  1. Kerberos认证           │          │                  │          │
│  ──────────────────────>   │          │                  │          │
│                            │          │                  │          │
│  2. getDelegationToken()   │          │                  │          │
│  ──────────────────────>   │          │                  │          │
│                            │ 生成Token│                  │          │
│  <──────────────────────   │ (含密钥) │                  │          │
│  3. Token (有效期24h)      │          │                  │          │
│                            │          │                  │          │
│  4. 后续RPC请求:           │          │                  │          │
│     携带Token而非Kerberos  │          │                  │          │
│  ──────────────────────>   │          │                  │          │
│                            │ 验证Token│                  │          │
│                            │ (本地验证│                  │          │
│                            │  无需KDC)│                  │          │
│  <──────────────────────   │          │                  │          │
│                            │          │                  │          │
│  5. 提交MR/Spark任务时     │          │                  │          │
│     Token传递给YARN        │          │                  │          │
│     → AM → Task            │          │                  │          │
│     Task用Token访问HDFS    │          │                  │          │
└───────┘                    └──────────┘                  └──────────┘
```

---

## 四、生产实战案例

### 4.1 典型故障场景

#### 场景1：Permission denied 排查

```bash
# 错误信息
Permission denied: user=hive, access=WRITE, 
  inode="/data/warehouse":hdfs:supergroup:drwxr-xr-x

# 排查步骤
# 1. 检查目录权限
hdfs dfs -ls -d /data/warehouse
# drwxr-xr-x   - hdfs supergroup   0 /data/warehouse

# 2. 检查 hive 用户信息
hdfs groups hive
# hive : hive hadoop

# 3. 分析：hive 不是 owner(hdfs)，不在 group(supergroup)
# other 权限是 r-x，没有 WRITE

# 解决方案：
# a) 改权限
hdfs dfs -chmod 775 /data/warehouse
# b) 或用 ACL
hdfs dfs -setfacl -m user:hive:rwx /data/warehouse
# c) 或改 owner
hdfs dfs -chown hive:hive /data/warehouse
```

#### 场景2：ACL 设了不生效

```bash
# 现象：设了 ACL 但用户还是没权限
hdfs dfs -setfacl -m user:alice:rwx /data/test.txt
hdfs dfs -getfacl /data/test.txt
# user::rw-
# user:alice:rwx      ← ACL 已设置
# group::r--           ← 注意这里！group bits = r-- = mask
# mask::r--            ← mask 限制了 alice 的有效权限为 r--
# other::---

# ★ 原因：mask = group bits = r--
# alice 的有效权限 = rwx AND r-- = r-- （只有读！）

# 解决：
hdfs dfs -setfacl -m mask::rwx /data/test.txt
# 或
hdfs dfs -chmod g=rwx /data/test.txt  # chmod 修改 group bits = 修改 mask
```

### 4.2 关键参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `dfs.permissions.enabled` | true | 是否启用权限检查 |
| `dfs.permissions.superusergroup` | supergroup | 超级用户组 |
| `dfs.namenode.acls.enabled` | false | 是否启用 ACL（需手动开启） |
| `dfs.cluster.administrators` | (空) | 集群管理员列表 |
| `dfs.namenode.inode.attributes.provider.class` | (空) | 外部权限提供者（Ranger） |
| `hadoop.security.authentication` | simple | 认证方式（simple/kerberos） |
| `dfs.namenode.delegation.token.max-lifetime` | 604800000 (7d) | Token 最大生命周期 |
| `dfs.namenode.delegation.token.renew-interval` | 86400000 (1d) | Token 续期间隔 |

---

## 五、举一反三

### 5.1 与其他系统的类比

| 特性 | HDFS | Linux | HBase | Hive (Ranger) |
|------|------|-------|-------|---------------|
| 基础权限 | POSIX rwx | POSIX rwx | Cell-level | Table/Column |
| ACL | POSIX ACL | POSIX ACL | 无 | Policy-based |
| 认证 | Kerberos/Token | PAM/LDAP | Kerberos | Kerberos |
| 授权扩展 | INodeAttributeProvider | SELinux/AppArmor | AccessController | Ranger Plugin |
| 粘滞位 | 支持 | 支持 | N/A | N/A |

### 5.2 面试高频题

**Q1: HDFS 权限检查的顺序是什么？**

A: 1) 超级用户直接通过；2) 检查路径上每个祖先目录的 EXECUTE 权限（traverse）；3) 检查 Sticky Bit；4) 检查目标节点权限：有 ACL 走 ACL 检查，无 ACL 走 POSIX 检查（owner→group→other）。

**Q2: ACL 的 mask 是什么？为什么 chmod 会影响 ACL？**

A: POSIX ACL 标准中，group permission bits 充当 mask。所有 Named User 和 Group 的有效权限 = ACL 权限 AND mask。chmod 修改 group bits 就是修改 mask，会影响所有 ACL 条目的有效权限。这是设计意图，不是 bug。

**Q3: Delegation Token 和 Kerberos 票据有什么区别？**

A: Kerberos 票据需要 KDC 参与颁发和验证，Token 由 NameNode 本地签发和验证（用 HMAC 密钥），不依赖 KDC。Token 适合分布式任务（MR/Spark Task），避免数万 Task 同时请求 KDC。Token 可以续期但有最大生命周期限制。

**Q4: 什么是 INodeAttributeProvider？Ranger 是如何集成的？**

A: INodeAttributeProvider 是 HDFS 的扩展点，允许外部系统（如 Ranger）覆盖 INode 的权限属性和检查逻辑。Ranger 通过实现这个接口，在 FSPermissionChecker 中插入自己的策略检查。当配置了 Ranger 插件时，HDFS 原生权限检查可以被 Ranger 策略覆盖。

### 5.3 思考题

1. **如果一个文件权限是 `----rwx---`（owner 无权限，group 有权限），owner 能读取这个文件吗？**
2. **Default ACL 是如何继承给子目录和子文件的？子文件和子目录的继承有什么区别？**
3. **Delegation Token 如果泄露了怎么办？有什么安全机制？**

---

## 六、知识晶体（一页纸总结）

```
┌─────────────────────────────────────────────────────────────┐
│            HDFS 权限模型与 ACL 知识晶体                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  三层权限:                                                   │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐             │
│  │POSIX rwx  │→│POSIX ACL  │→│Delegation Token│             │
│  │owner/group│ │精细化控制  │ │临时认证        │             │
│  │/other     │ │named user │ │替代Kerberos    │             │
│  └───────────┘ │named group│ └───────────────┘             │
│                │mask机制    │                                │
│                └───────────┘                                │
│                                                             │
│  检查顺序: SuperUser→Traverse→StickyBit→ACL/POSIX          │
│                                                             │
│  核心类: FSPermissionChecker                                │
│    hasPermission(): 有ACL→hasAclPermission()                │
│                     无ACL→POSIX(owner→group→other)          │
│                                                             │
│  ACL Mask 关键: group bits = mask                           │
│    有效权限 = ACL权限 AND mask                               │
│    chmod g=xxx 就是修改 mask！                               │
│                                                             │
│  ACL 继承: 父 Default ACL → 子 Access ACL                  │
│    目录: 继承 Access + Default                               │
│    文件: 只继承 Access                                       │
│                                                             │
│  Delegation Token:                                          │
│    Client Kerberos认证→获取Token→后续用Token                │
│    适合分布式任务(MR/Spark)避免KDC压力                      │
│    NN本地签发验证(HMAC),不依赖KDC                            │
│                                                             │
│  扩展: INodeAttributeProvider (Ranger插件)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 七、参考资料

1. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/FSPermissionChecker.java` (全文 582 行)
2. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/AclStorage.java` (全文 401 行)
3. 本地源码: `/Users/kailongliu/bigdata/txProjects/hadoop/hadoop-hdfs-project/hadoop-hdfs/src/main/java/org/apache/hadoop/hdfs/server/namenode/AclEntryStatusFormat.java`
4. [HDFS Permissions Guide](https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsPermissionsGuide.html)
5. [POSIX ACL 标准](https://www.usenix.org/legacy/publications/library/proceedings/usenix03/tech/freenix03/gruenbacher.html)
6. [HDFS-4685: ACL Support JIRA](https://issues.apache.org/jira/browse/HDFS-4685)
