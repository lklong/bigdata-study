#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dig_diff_13233986_vs_13236774.py
深挖 13233986（失败）和 13236774（成功）的真正差异。

环境配置一样、SQL 一样、数据量一样、Stage 结构一样，那差别只能在"运行时态":
1) 跑在哪些物理节点上（Host 集合）
2) 单 Executor / 单 Host 累计 Shuffle Write 峰值（按 Host 聚合）
3) 单 Executor 失败次数、节点磁盘事件
4) 时间窗口（前后相邻几分钟，集群是否处于不同负载）
5) 是否有 Speculative Task / TaskKilled 事件密度不同
"""
from __future__ import annotations
import sys, json, io
from pathlib import Path
from collections import defaultdict

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

PATHS = {
    "13233986_FAIL": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13233986_1.inprogress",
    "13236774_SUCC": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13236774_1",
}


def human(n):
    try:
        n = float(n)
    except Exception:
        return str(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.2f}{u}"
        n /= 1024
    return f"{n:.2f}PB"


def analyze(tag, path):
    print(f"\n{'='*100}\n  {tag}  {Path(path).name}\n{'='*100}")
    if not Path(path).exists():
        print("  not found"); return None

    exec_to_host = {}                         # exec_id -> host
    exec_added_ts = {}                        # exec_id -> ts
    exec_removed = {}                         # exec_id -> (ts, reason)
    host_shuffle_write = defaultdict(int)     # host -> sum shuffle write bytes
    exec_shuffle_write = defaultdict(int)     # exec_id -> sum shuffle write
    host_disk_block_size = defaultdict(int)   # host -> max BlockManager Disk Size used at any point
    block_disk_size_per_host_peak = defaultdict(int)  # host -> max simultaneous disk size
    block_disk_size_per_host_now = defaultdict(int)
    task_failed_count = defaultdict(int)      # exec_id -> failed count
    task_lost_count = 0
    task_killed_count = 0
    task_succ_count = 0
    speculative_count = 0
    app_start = None
    app_end = None
    last_event_ts = 0

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            ev = d.get("Event")
            if ev == "SparkListenerApplicationStart":
                app_start = d.get("Timestamp")
            elif ev == "SparkListenerApplicationEnd":
                app_end = d.get("Timestamp")
            elif ev == "SparkListenerExecutorAdded":
                eid = d.get("Executor ID")
                ei = d.get("Executor Info", {})
                host = ei.get("Host", "?")
                exec_to_host[eid] = host
                exec_added_ts[eid] = d.get("Timestamp")
            elif ev == "SparkListenerExecutorRemoved":
                eid = d.get("Executor ID")
                exec_removed[eid] = (d.get("Timestamp"), d.get("Removed Reason", "?"))
            elif ev == "SparkListenerBlockManagerAdded":
                bm = d.get("Block Manager ID", {})
                eid = bm.get("Executor ID")
                host = bm.get("Host")
                if eid and host:
                    exec_to_host[eid] = host
            elif ev == "SparkListenerBlockUpdated":
                bu = d.get("Block Updated Info", {})
                bm = bu.get("Block Manager ID", {})
                host = bm.get("Host", "?")
                ds = bu.get("Disk Size", 0) or 0
                ms = bu.get("Memory Size", 0) or 0
                # 这里近似把"当前事件值"叠加（不严谨，但够看 host 维度的 spill 峰值规模）
                block_disk_size_per_host_now[host] += ds
                if block_disk_size_per_host_now[host] > block_disk_size_per_host_peak[host]:
                    block_disk_size_per_host_peak[host] = block_disk_size_per_host_now[host]
            elif ev == "SparkListenerTaskEnd":
                ts = d.get("Task Info", {}).get("Finish Time", 0) or 0
                if ts > last_event_ts: last_event_ts = ts
                ti = d.get("Task Info", {})
                eid = ti.get("Executor ID")
                if ti.get("Speculative"): speculative_count += 1
                ter = d.get("Task End Reason", {})
                reason = ter.get("Reason", "")
                if reason == "Success":
                    task_succ_count += 1
                    tm = d.get("Task Metrics", {})
                    swm = tm.get("Shuffle Write Metrics", {}) or {}
                    sw = swm.get("Shuffle Bytes Written", 0) or 0
                    host = exec_to_host.get(eid, "?")
                    host_shuffle_write[host] += sw
                    exec_shuffle_write[eid] += sw
                elif reason == "TaskKilled":
                    task_killed_count += 1
                elif reason in ("ExecutorLostFailure", "FetchFailed"):
                    task_lost_count += 1
                    task_failed_count[eid] += 1
                else:
                    task_failed_count[eid] += 1

    # 输出
    print(f"  ApplicationStart: {app_start}")
    print(f"  ApplicationEnd  : {app_end}  (None → 异常终止)")
    print(f"  Last Task Finish: {last_event_ts}")
    if app_start:
        print(f"  时长 / 心跳间隔: {((app_end or last_event_ts)-app_start)/60000:.2f} min")

    print(f"\n  累计 Executor 数: {len(exec_to_host)}")
    print(f"  涉及物理 Host 数 (unique): {len(set(exec_to_host.values()))}")
    print(f"  TaskSuccess={task_succ_count}  TaskKilled={task_killed_count}  TaskLost/Fetched={task_lost_count}  Speculative={speculative_count}")

    # Top 10 host 累计 Shuffle Write
    print(f"\n  [Top 10 Host 累计 Shuffle Write Bytes]（合并所有跑在该 Host 上的 Executor）")
    print(f"  {'Host':<25} {'Executors':>10} {'Sum_ShuffleWrite':>18} {'PeakDiskBlock':>18}")
    host_exec_count = defaultdict(int)
    for eid, h in exec_to_host.items():
        host_exec_count[h] += 1
    rows = sorted(host_shuffle_write.items(), key=lambda x: -x[1])
    for h, sw in rows[:10]:
        print(f"  {h:<25} {host_exec_count.get(h,0):>10} {human(sw):>18} {human(block_disk_size_per_host_peak.get(h,0)):>18}")

    print(f"\n  [Top 5 Executor 累计 Shuffle Write]")
    rows2 = sorted(exec_shuffle_write.items(), key=lambda x: -x[1])
    for eid, sw in rows2[:5]:
        host = exec_to_host.get(eid, "?")
        added = exec_added_ts.get(eid)
        rem = exec_removed.get(eid, (None, None))
        print(f"  exec_{eid:<5} host={host:<20} sw={human(sw):>12}  added={added}  removed={rem[0]}  reason={(rem[1] or '')[:60]}")

    # Executor 异常移除原因
    print(f"\n  [Executor 移除原因 Top 5]")
    reasons = defaultdict(int)
    for eid, (ts, reason) in exec_removed.items():
        reasons[(reason or "?")[:80]] += 1
    for r, c in sorted(reasons.items(), key=lambda x: -x[1])[:5]:
        print(f"    [{c:>3}] {r}")

    return {
        "tag": tag,
        "app_start": app_start,
        "app_end": app_end,
        "last_event_ts": last_event_ts,
        "host_count": len(set(exec_to_host.values())),
        "exec_count": len(exec_to_host),
        "host_top1_sw": rows[0] if rows else None,
        "exec_top1_sw": rows2[0] if rows2 else None,
        "remove_reasons": dict(reasons),
        "task_succ": task_succ_count,
        "task_killed": task_killed_count,
        "task_lost": task_lost_count,
    }


def main():
    results = []
    for tag, path in PATHS.items():
        results.append(analyze(tag, path))

    # 时间线对比
    print(f"\n{'='*100}\n  时间线对比\n{'='*100}")
    for r in results:
        if r:
            print(f"  {r['tag']}: start={r['app_start']}  end={r['app_end']}  last_task={r['last_event_ts']}")

    # 节点重叠度
    print(f"\n{'='*100}\n  关键问题：两次跑的节点是否重叠？\n{'='*100}")


if __name__ == "__main__":
    main()
