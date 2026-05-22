#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kerb_error_classifier.py — Kerberos 报错智能分类器

用法：
  cat error.log | python3 kerb_error_classifier.py
  python3 kerb_error_classifier.py error.log
  echo "GSSException: ..." | python3 kerb_error_classifier.py

输出：错误分类 + 根因 + 一句话解法 + 详细建议
"""
import sys
import re
import os

# 错误码 → (类别, 根因, 一句话解法)
ERROR_CODES = {
    "-1765328359": ("时间", "时钟偏差 > 5 分钟", "chronyc -a makestep"),
    "-1765328370": ("配置", "krb5.conf 缺 realm", "检查 /etc/krb5.conf [realms] 段"),
    "-1765328351": ("网络", "KDC 不可达（网络/进程/端口）", "nc -zv kdc 88 && systemctl status krb5kdc"),
    "-1765328378": ("密钥", "Pre-auth 失败（密码/KVNO/enctype）", "KRB5_TRACE=/dev/stderr kinit -V"),
    "-1765328353": ("Principal", "SPN 不存在 / FQDN 错配", "kadmin.local -q 'getprinc <spn>' && hostname -f"),
    "-1765328377": ("密钥", "解密失败（跨域 krbtgt 密码不一致）", "双方 KDC 重置 krbtgt 同密码"),
    "-1765328324": ("Login", "TGT 已过期", "kinit / 长任务用 --keytab"),
    "-1765328352": ("时间", "客户端时钟慢于 KDC", "chronyc -a makestep"),
    "-1765328332": ("配置", "enctype 协商失败", "krb5.conf 加 default_tkt_enctypes"),
    "-1765328230": ("密钥", "KVNO 不一致", "kadmin.local -q 'ktadd -norandkey -k /tmp/x.keytab P'"),
    "-1765328383": ("配置", "Encryption type 不支持（JCE 限制）", "解锁 JCE Policy"),
    "-1765328369": ("配置", "KDC 不支持此 enctype", "krb5.conf permitted_enctypes 加 AES"),
    "-1765328346": ("网络", "Connection refused", "systemctl restart krb5kdc"),
    "-1765328228": ("密钥", "Service principal 密钥不匹配（TGS 阶段）", "服务端 keytab 重新 ktadd"),
}

# 关键字 → (类别, 根因, 一句话解法)
KEYWORDS = [
    # 时间类
    (r"Clock skew too great", "时间", "时钟偏差", "chronyc -a makestep"),
    (r"Ticket not yet valid", "时间", "客户端时钟慢", "chronyc -a makestep"),
    (r"Defective token detected", "时间", "时钟微差/replay cache", "同步时钟+清 rcache"),
    
    # 网络类
    (r"Cannot contact any KDC", "网络", "KDC 不可达", "nc -zv kdc 88 + 检查进程"),
    (r"Cannot find KDC for realm", "配置", "krb5.conf realm 缺失", "检查 [realms] 段"),
    (r"UnknownHostException", "网络", "DNS 解析失败", "nslookup + /etc/hosts"),
    (r"Connection refused", "网络", "端口未监听", "systemctl status krb5kdc"),
    (r"Receive timed out", "网络", "UDP 截断/超时", "udp_preference_limit=1"),
    
    # 密钥类
    (r"Pre-?authentication.*(failed|invalid)", "密钥", "密码/KVNO/enctype 错", "KRB5_TRACE 看具体"),
    (r"Specified version of key is not available", "密钥", "KVNO 不一致", "ktadd -norandkey 重新导出"),
    (r"Decrypt integrity check failed", "密钥", "密钥不一致（单域 keytab/跨域 krbtgt）", "重新 ktadd / 跨域重置"),
    (r"Cannot find key of appropriate type", "密钥", "keytab 缺 KDC 协商的 enctype", "ktadd -e aes256-cts..."),
    (r"Encryption type.*not supported", "配置", "enctype 不支持（JCE限制）", "解锁 JCE Policy"),
    (r"Checksum failed", "密钥", "通常是 KVNO 不一致", "ktadd -norandkey"),
    (r"Illegal key size", "配置", "JCE 限制版", "crypto.policy=unlimited"),
    
    # Principal
    (r"Client.*not found in Kerberos database", "Principal", "用户 principal 不存在", "kadmin addprinc"),
    (r"Server not found in Kerberos database", "Principal", "服务 SPN 不存在/FQDN 错", "检查 hostname -f"),
    (r"Server has invalid Kerberos principal", "Principal", "服务端 SPN 与配置不符", "校对进程实际 principal"),
    (r"PREAUTH_FAILED", "密钥", "客户端预认证失败", "查 KDC 日志中的客户端 IP"),
    (r"UNKNOWN_SERVER", "Principal", "请求的 SPN 在 KDC 不存在", "kadmin listprincs"),
    
    # Login/Token
    (r"No valid credentials provided", "Login", "没 kinit / CCNAME 错", "kinit + echo $KRB5CCNAME"),
    (r"Failed to find any Kerberos tgt", "Login", "没拿到 TGT", "kinit -kt keytab principal"),
    (r"No LoginModules configured", "Login", "缺 jaas.conf", "-Djava.security.auth.login.config"),
    (r"Unable to obtain password from user", "Login", "keytab 读不到", "chown/chmod 400"),
    (r"Login failure for .* from keytab", "Login", "keytab 缺 principal", "klist -kt 看条目"),
    (r"token.*expired", "Token", "Delegation Token 过期（长任务）", "spark-submit --keytab"),
    (r"InvalidToken", "Token", "Hadoop Token 失效", "重新提交 + --keytab"),
    
    # 配置
    (r"Cannot authenticate via.*KERBEROS", "配置", "客户端没启用 Kerberos", "core-site.xml 改 kerberos"),
    (r"SIMPLE authentication is not enabled", "配置", "客户端走 SIMPLE", "改成 kerberos + kinit"),
    (r"is not allowed to impersonate", "配置", "ProxyUser 没配", "hadoop.proxyuser.X.hosts/groups"),
    (r"SaslException", "配置/密钥", "SASL 协商失败", "看 caused by 定位"),
    
    # SPNEGO
    (r"WWW-Authenticate.*Negotiate", "SPNEGO", "浏览器/客户端没 kinit", "浏览器配 SPNEGO 白名单"),
    
    # 跨域
    (r"capaths", "跨域", "跨域路径配置", "krb5.conf [capaths]"),
]

# 类别颜色
COLORS = {
    "时间": "\033[1;33m",      # 黄
    "网络": "\033[0;36m",      # 青
    "密钥": "\033[0;31m",      # 红
    "Principal": "\033[0;35m", # 紫
    "Login": "\033[0;34m",     # 蓝
    "Token": "\033[1;31m",     # 亮红
    "配置": "\033[0;32m",      # 绿
    "SPNEGO": "\033[1;36m",    # 亮青
    "跨域": "\033[1;35m",      # 亮紫
    "其他": "\033[0;37m",      # 灰
}
NC = "\033[0m"

def classify(text):
    """对一段文本进行分类，返回所有命中"""
    hits = []
    
    # 1) 错误码精确匹配
    for code, info in ERROR_CODES.items():
        if code in text:
            hits.append({
                "match_type": "errorcode",
                "code": code,
                "category": info[0],
                "root_cause": info[1],
                "fix": info[2],
            })
    
    # 2) 关键字模糊匹配
    for pattern, cat, cause, fix in KEYWORDS:
        if re.search(pattern, text, re.IGNORECASE):
            hits.append({
                "match_type": "keyword",
                "pattern": pattern,
                "category": cat,
                "root_cause": cause,
                "fix": fix,
            })
    
    return hits


def deduplicate(hits):
    """根据 root_cause 去重"""
    seen = set()
    out = []
    for h in hits:
        key = h["root_cause"]
        if key not in seen:
            seen.add(key)
            out.append(h)
    return out


def main():
    # 读取输入
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        with open(sys.argv[1]) as f:
            text = f.read()
    else:
        text = sys.stdin.read()
    
    if not text.strip():
        print("请通过管道传入错误日志或指定文件路径")
        print("Usage:")
        print("  cat error.log | python3 kerb_error_classifier.py")
        print("  python3 kerb_error_classifier.py error.log")
        sys.exit(1)
    
    hits = classify(text)
    hits = deduplicate(hits)
    
    print("=" * 60)
    print("Kerberos 错误智能分类器")
    print("=" * 60)
    print(f"输入长度: {len(text)} 字符")
    print(f"命中条目: {len(hits)}")
    print()
    
    if not hits:
        print("⚠️  未识别为 Kerberos 错误。可能是：")
        print("  - 应用层错误（不是 Kerberos）")
        print("  - 错误格式不在字典中（请补充）")
        print()
        print("建议运行：bash kerb-trace.sh -c '<你的命令>'")
        sys.exit(0)
    
    # 按类别分组输出
    by_cat = {}
    for h in hits:
        by_cat.setdefault(h["category"], []).append(h)
    
    # 类别优先级
    cat_order = ["时间", "网络", "密钥", "Principal", "Login", "Token", "配置", "SPNEGO", "跨域", "其他"]
    
    for cat in cat_order:
        if cat not in by_cat:
            continue
        color = COLORS.get(cat, NC)
        print(f"{color}━━━ [{cat}类] ━━━{NC}")
        for h in by_cat[cat]:
            tag = f"errorcode {h['code']}" if h.get("code") else f"关键字 '{h.get('pattern')}'"
            print(f"  匹配:    {tag}")
            print(f"  根因:    {h['root_cause']}")
            print(f"  解法:    {h['fix']}")
            print()
    
    # 优先建议
    print("=" * 60)
    print("📌 优先排查建议")
    print("=" * 60)
    priority = list(by_cat.keys())
    priority_str = " → ".join(priority[:3])
    print(f"按类别优先级处理: {priority_str}")
    print()
    
    # 推荐脚本
    print("🔧 推荐执行：")
    print("  1. bash kerb-doctor.sh -p <principal> -k <keytab>  # 全面体检")
    print("  2. bash kerb-trace.sh -c '<复现命令>'              # 抓 trace")
    print("  3. 查阅 08-Kerberos错误码全字典.md")
    print("  4. 查阅 09-Kerberos5分钟根因定位手册.md")


if __name__ == "__main__":
    main()
