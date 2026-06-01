#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""quick_stage_analysis.py — 快速回答用户的问题：
"任务超过230G，重试2次失败后，第3次没有磁盘占用超过230G然后成功"

核心提取：
1) 每个 Stage 的所有 Attempt：耗时、Task 数、Shuffle Write、Failure Reason
2) 失败 Stage 的 Task End Reason 分布（FetchFailed / ExecutorLost / TaskKilled 等）
3) AQE 是否触发 skewJoin / coalescePartitions（决定 attempt 之间分区策略变化）
"""
from __future__ import annotations
import sys
import json
import io
from pathlib import Path
from collections import defaultdict, Counter

# 强制 stdout 用 utf-8，避免 Windows GBK 报错
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

EVENT_LOGS = {
    "13230312": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13230312_1.inprogress",
    "13233986": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13233986_1.inprogress",
    "13236774": r"C:/Users/lkl/Desktop/高途异常作业分析/_extracted/application_1767599787371_13236774_1",
}


def human_bytes(n):
    try:
        n = float(n)
    except Exception:
        return str(n)
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if abs(n) < 1024:
            return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} EB"


def get_acc(accs, name):
    for a in accs:
        if a.get("Name") == name:
            v = a.get("Value", "-")
            try:
                return int(v)
            except Exception:
                try:
                    return float(v)
                except Exception:
                    return v
    return None


def analyze_one(app_id: str, path: str):
    print(f"\n{'=' * 90}\n  Application {app_id}  ({path.split('/')[-1]})\n{'=' * 90}")
    p = Path(path)
    if not p.exists():
        print(f"  文件不存在，跳过")
        return

    stages = defaultdict(list)        # (stage_id, attempt_id) -> StageCompleted info
    task_end_by_stage = defaultdict(Counter)  # stage_id -> Counter of TaskEndReason
    task_end_by_attempt = defaultdict(Counter)  # (sid, aid) -> Counter
    aqe_events = []                   # AQE update events
    job_end_reasons = []
    app_end = False

    with open(p, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            ev = d.get("Event")
            if ev == "SparkListenerStageCompleted":
                si = d.get("Stage Info", {})
                sid = si.get("Stage ID")
                aid = si.get("Stage Attempt ID")
                sub = si.get("Submission Time")
                comp = si.get("Completion Time")
                accs = si.get("Accumulables", [])
                stages[(sid, aid)].append({
                    "name": si.get("Stage Name", "")[:80],
                    "ntasks": si.get("Number of Tasks"),
                    "sub": sub,
                    "comp": comp,
                    "dur_s": ((comp - sub) / 1000.0) if (comp and sub) else None,
                    "fail_reason": si.get("Failure Reason"),
                    "shuffle_write": get_acc(accs, "internal.metrics.shuffle.write.bytesWritten"),
                    "shuffle_read": get_acc(accs, "internal.metrics.shuffle.read.localBytesRead"),
                    "input_bytes": get_acc(accs, "internal.metrics.input.bytesRead"),
                    "output_bytes": get_acc(accs, "internal.metrics.output.bytesWritten"),
                    "peak_mem": get_acc(accs, "internal.metrics.peakExecutionMemory"),
                })
            elif ev == "SparkListenerTaskEnd":
                sid = d.get("Stage ID")
                aid = d.get("Stage Attempt ID")
                ter = d.get("Task End Reason", {})
                reason = ter.get("Reason", "Unknown")
                if reason == "TaskKilled":
                    reason = f"TaskKilled:{ter.get('Kill Reason','?')[:30]}"
                elif reason == "ExceptionFailure":
                    reason = f"ExceptionFailure:{ter.get('Class Name','?')[:40]}"
                elif reason == "FetchFailed":
                    reason = f"FetchFailed:from_exec_{ter.get('Block Manager Address',{}).get('Executor ID','?')}"
                elif reason == "ExecutorLostFailure":
                    reason = f"ExecutorLost:{ter.get('Loss Reason','?')[:50]}"
                task_end_by_stage[sid][reason] += 1
                task_end_by_attempt[(sid, aid)][reason] += 1
            elif ev == "org.apache.spark.sql.execution.adaptive.SparkListenerSQLAdaptiveExecutionUpdate":
                aqe_events.append(d)
            elif ev == "SparkListenerJobEnd":
                jr = d.get("Job Result", {})
                if jr.get("Result") != "JobSucceeded":
                    job_end_reasons.append({"job_id": d.get("Job ID"), "result": jr})
            elif ev == "SparkListenerApplicationEnd":
                app_end = True

    # 输出 stage 按 (sid, aid) 排序
    print(f"\n[Stage 历史 — 所有 Attempt]")
    print(f"  {'Stage':<10} {'Att':<4} {'Tasks':<7} {'Dur(s)':<10} {'ShuffleW':<14} {'ShuffleR':<14} {'OutW':<14} {'PeakMem':<14} {'Failure':<60}")
    for (sid, aid) in sorted(stages.keys()):
        for s in stages[(sid, aid)]:
            fail = (s["fail_reason"] or "")[:58].replace("\n", " ")
            print(f"  {sid:<10} {aid:<4} {str(s['ntasks']):<7} "
                  f"{('%.1f' % s['dur_s']) if s['dur_s'] is not None else '-':<10} "
                  f"{human_bytes(s['shuffle_write'] or 0):<14} "
                  f"{human_bytes(s['shuffle_read'] or 0):<14} "
                  f"{human_bytes(s['output_bytes'] or 0):<14} "
                  f"{human_bytes(s['peak_mem'] or 0):<14} "
                  f"{fail}")

    # 失败 Attempt 的 Task End Reason 分布
    print(f"\n[失败 Stage Attempt 的 TaskEndReason 分布]")
    failed_attempts = [(sid, aid) for (sid, aid), lst in stages.items()
                       for s in lst if s["fail_reason"]]
    for sid, aid in sorted(failed_attempts):
        print(f"  Stage {sid}.{aid} Task 结局:")
        for reason, cnt in task_end_by_attempt[(sid, aid)].most_common():
            print(f"      {reason}: {cnt}")

    # 同一 Stage 跨 Attempt 的 Task 数 / Shuffle Write 对比（最关键，回答用户问题）
    print(f"\n[同一 Stage 跨 Attempt 的 Task 数 / Shuffle Write 对比]（这是回答\"为什么第3次成功\"的关键）")
    by_sid = defaultdict(list)
    for (sid, aid), lst in stages.items():
        for s in lst:
            by_sid[sid].append((aid, s))
    for sid in sorted(by_sid.keys()):
        atts = sorted(by_sid[sid])
        if len(atts) <= 1:
            continue
        print(f"  Stage {sid} ({atts[0][1]['name']}):")
        for aid, s in atts:
            status = "FAIL" if s["fail_reason"] else "SUCCESS"
            print(f"      Attempt {aid}: tasks={s['ntasks']:>5}  shuffle_write={human_bytes(s['shuffle_write'] or 0):>12}  status={status}  fail={(s['fail_reason'] or '')[:80]}")

    print(f"\n[AQE 事件数] {len(aqe_events)}  [Job 失败数] {len(job_end_reasons)}  [ApplicationEnd] {app_end}")
    if job_end_reasons:
        print(f"\n[Job 失败原因前 3 条]")
        for j in job_end_reasons[:3]:
            print(f"  Job {j['job_id']}: {str(j['result'])[:300]}")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else None
    for app_id, path in EVENT_LOGS.items():
        if target and app_id != target:
            continue
        analyze_one(app_id, path)
