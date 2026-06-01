#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""compare_env.py — 对比 3 个 App 的 Spark 配置 + Executor 数 + 运行时长
回答：同一个 SQL 在 13233986 / 13236774 上为什么一个失败一个成功
"""
from __future__ import annotations
import sys, json, io
from pathlib import Path

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

EVENT_LOGS = {
    "13230312": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13230312_1.inprogress",
    "13233986": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13233986_1.inprogress",
    "13236774": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13236774_1",
}

KEYS = [
    "spark.app.name",
    "spark.app.id",
    "spark.executor.cores",
    "spark.executor.memory",
    "spark.executor.memoryOverhead",
    "spark.executor.instances",
    "spark.driver.memory",
    "spark.dynamicAllocation.enabled",
    "spark.dynamicAllocation.minExecutors",
    "spark.dynamicAllocation.maxExecutors",
    "spark.dynamicAllocation.initialExecutors",
    "spark.sql.shuffle.partitions",
    "spark.sql.adaptive.enabled",
    "spark.sql.adaptive.skewJoin.enabled",
    "spark.sql.adaptive.coalescePartitions.enabled",
    "spark.sql.adaptive.advisoryPartitionSizeInBytes",
    "spark.sql.adaptive.skewJoin.skewedPartitionFactor",
    "spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes",
    "spark.shuffle.service.enabled",
    "spark.shuffle.compress",
    "spark.local.dir",
    "spark.kyuubi.session.engine.share.level",
    "spark.kyuubi.engine.share.level",
]


def parse_env(path: str) -> tuple[dict, int, int, int, set, dict]:
    """返回 (spark_props, app_start_ts, app_end_ts, max_concurrent_executors, all_executor_ids, app_name)"""
    sp = {}
    app_start = None
    app_end = None
    executor_added = {}      # exec_id -> ts
    executor_removed = {}    # exec_id -> ts
    app_name = None
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            ev = d.get("Event")
            if ev == "SparkListenerEnvironmentUpdate" and not sp:
                sp = d.get("Spark Properties", {})
            elif ev == "SparkListenerApplicationStart":
                app_start = d.get("Timestamp")
                app_name = d.get("App Name")
            elif ev == "SparkListenerApplicationEnd":
                app_end = d.get("Timestamp")
            elif ev == "SparkListenerExecutorAdded":
                executor_added[d.get("Executor ID")] = d.get("Timestamp")
            elif ev == "SparkListenerExecutorRemoved":
                executor_removed[d.get("Executor ID")] = d.get("Timestamp")
    # 估算最大并发 executor 数：把 add/remove 时间合并成事件流，扫一遍
    events = []
    for eid, ts in executor_added.items():
        events.append((ts, +1, eid))
    for eid, ts in executor_removed.items():
        events.append((ts, -1, eid))
    events.sort()
    cur = 0
    peak = 0
    for ts, delta, eid in events:
        cur += delta
        peak = max(peak, cur)
    return sp, app_start, app_end, peak, set(executor_added.keys()), app_name


def main():
    rows = {}
    for app_id, path in EVENT_LOGS.items():
        if not Path(path).exists():
            print(f"[skip] {app_id}: file not found")
            continue
        sp, st, en, peak, eids, app_name = parse_env(path)
        rows[app_id] = {
            "sp": sp,
            "start": st,
            "end": en,
            "duration_min": ((en - st) / 60000.0) if st and en else None,
            "executor_peak": peak,
            "executor_total": len(eids),
            "app_name": app_name,
        }

    # 表头
    print(f"\n[Spark 配置 / Executor / 运行时长 三 App 对比]\n")
    cols = list(rows.keys())
    print(f"  {'指标':<55}", end="")
    for c in cols:
        print(f" | {c:<25}", end="")
    print()
    print("  " + "-" * (55 + 28 * len(cols)))

    # 元信息行
    for label, key in [
        ("AppName", "app_name"),
        ("Start (ts)", "start"),
        ("End (ts)", "end"),
        ("Duration (min)", "duration_min"),
        ("Executor 峰值并发数", "executor_peak"),
        ("Executor 累计申请数", "executor_total"),
    ]:
        print(f"  {label:<55}", end="")
        for c in cols:
            v = rows[c].get(key)
            if isinstance(v, float):
                v = f"{v:.2f}"
            print(f" | {str(v)[:25]:<25}", end="")
        print()

    # Spark Properties
    for k in KEYS:
        line = f"  {k:<55}"
        for c in cols:
            v = rows[c]["sp"].get(k, "<unset>")
            line += f" | {str(v)[:25]:<25}"
        print(line)


if __name__ == "__main__":
    main()
