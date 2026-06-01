#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""timeline_when_230g.py
查 13233986 在哪个时间点 Top1/Top2 Host 累计 Shuffle Write 突破 230G，
并和 ApplicationEnd 缺失、Executor killed by driver 时间做对照。
回答：是不是 hadoop-alarm 检测到 230G 就 kill 了应用？
"""
from __future__ import annotations
import sys, json, io
from pathlib import Path
from collections import defaultdict

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

PATH = r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13233986_1.inprogress"


def human(n):
    n = float(n)
    for u in ("B","KB","MB","GB","TB"):
        if abs(n)<1024: return f"{n:.2f}{u}"
        n /= 1024
    return f"{n:.2f}PB"


def main():
    exec_to_host = {}
    host_cum_sw = defaultdict(int)
    threshold_hits = {}     # host -> first ts when crossed 230G
    # 230G in bytes
    THRESHOLD = 230 * 1024**3
    app_start = None
    last_task_finish = 0
    exec_kill_first_ts = None
    exec_kill_count_per_minute = defaultdict(int)  # epoch_min -> count

    with open(PATH, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: d = json.loads(line)
            except: continue
            ev = d.get("Event")
            if ev == "SparkListenerApplicationStart":
                app_start = d.get("Timestamp")
            elif ev == "SparkListenerExecutorAdded":
                eid = d.get("Executor ID")
                host = d.get("Executor Info", {}).get("Host")
                exec_to_host[eid] = host
            elif ev == "SparkListenerBlockManagerAdded":
                bm = d.get("Block Manager ID", {})
                eid = bm.get("Executor ID")
                host = bm.get("Host")
                if eid and host: exec_to_host[eid] = host
            elif ev == "SparkListenerExecutorRemoved":
                ts = d.get("Timestamp")
                if exec_kill_first_ts is None or ts < exec_kill_first_ts:
                    exec_kill_first_ts = ts
                exec_kill_count_per_minute[ts // 60000] += 1
            elif ev == "SparkListenerTaskEnd":
                ti = d.get("Task Info", {})
                ft = ti.get("Finish Time", 0) or 0
                if ft > last_task_finish: last_task_finish = ft
                if d.get("Task End Reason", {}).get("Reason") != "Success":
                    continue
                eid = ti.get("Executor ID")
                host = exec_to_host.get(eid, "?")
                tm = d.get("Task Metrics", {})
                sw = (tm.get("Shuffle Write Metrics", {}) or {}).get("Shuffle Bytes Written", 0) or 0
                if sw <= 0: continue
                host_cum_sw[host] += sw
                if host_cum_sw[host] >= THRESHOLD and host not in threshold_hits:
                    threshold_hits[host] = ft

    print(f"  ApplicationStart : {app_start}  -> {ts_to_min(app_start, app_start)}")
    print(f"  Last Task Finish : {last_task_finish}  -> {ts_to_min(last_task_finish, app_start)}")
    print(f"  First Executor Removed: {exec_kill_first_ts}  -> {ts_to_min(exec_kill_first_ts, app_start)}")
    print()
    print(f"  Host 累计 Shuffle Write 突破 230GB 的时间点：")
    print(f"  {'Host':<25} {'突破阈值时刻':<25} {'相对启动 min':<15}")
    for h, ts in sorted(threshold_hits.items(), key=lambda x: x[1]):
        print(f"  {h:<25} {ts:<25} {ts_to_min(ts, app_start)}")

    print(f"\n  Top 10 Host 最终累计 Shuffle Write：")
    for h, sw in sorted(host_cum_sw.items(), key=lambda x: -x[1])[:10]:
        marker = " ← 超 230G" if sw >= THRESHOLD else ""
        print(f"    {h:<25} {human(sw):>12}{marker}")

    print(f"\n  Executor 被移除（killed by driver）的分钟级密度（前 10 分钟）：")
    if app_start:
        start_min = app_start // 60000
        for offset in range(35):
            cnt = exec_kill_count_per_minute.get(start_min + offset, 0)
            if cnt > 0:
                print(f"    +{offset:>2} min  killed = {cnt}")


def ts_to_min(ts, base):
    if ts is None or base is None: return "-"
    return f"+{(ts-base)/60000:.2f} min"


if __name__ == "__main__":
    main()
