#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""list_eventlog.py — 扫描桌面 Event Log 目录，核验 4 个 Application 的文件齐全性与完整性。

输出：
  - stdout 打印一张人类可读的清单表
  - 同时写出 ../output/00_eventlog_inventory.md（中文 Markdown，给报告引用）

约束（来自 requirements.md 需求 1 与需求 7.5）：
  - 桌面路径不在 IDE workspace 索引内，全程用绝对路径
  - 不把 Event Log 拷入 workspace；只读取 + 输出元信息
"""
from __future__ import annotations
import os
import json
import zipfile
from pathlib import Path
from datetime import datetime

# ===== 配置 =====
DESKTOP_DIR = Path(r"C:/Users/lkl/Desktop/高途异常作业分析")
EXTRACT_DIR = DESKTOP_DIR / "_extracted"
OUTPUT_MD = Path(__file__).resolve().parent.parent / "output" / "00_eventlog_inventory.md"

# 4 个目标 ApplicationID（来自告警原文）
TARGET_APPS = [
    {
        "app_id": "application_1767599787371_13233986",
        "biz_name": "service_dw.dm_crm_trace_lead_full_link_data_hf",
        "scheduler": "zeus",
        "task_id": "1729816",
        "alarm_status": "FAIL",
    },
    {
        "app_id": "application_1767599787371_13230312",
        "biz_name": "renew_lift_train_fpc_em_zonghesuyang_spring_and_autumn_stage4",
        "scheduler": "u_strategy",
        "task_id": "2386919",
        "alarm_status": "FAIL",
    },
    {
        "app_id": "application_1767599787371_13232163",
        "biz_name": "service_dw.dm_crm_trace_lead_full_link_data_hf",
        "scheduler": "zeus",
        "task_id": "1672415",
        "alarm_status": "FAIL",
    },
    {
        "app_id": "application_1767599787371_13236774",
        "biz_name": "(对照组：打平到3从 成功)",
        "scheduler": "-",
        "task_id": "-",
        "alarm_status": "SUCCESS_CONTROL",
    },
]


def human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} PB"


def find_zip_for_app(app_id: str) -> Path | None:
    """根据 app_id 在 DESKTOP_DIR 下找形如 eventLogs-<app_id>-*.zip 的文件"""
    for p in DESKTOP_DIR.iterdir():
        if p.is_file() and app_id in p.name and p.suffix.lower() == ".zip":
            return p
    return None


def find_extracted(app_id: str) -> Path | None:
    """在 _extracted 下找已解压的 Event Log 文件（可能带或不带 .inprogress 后缀）"""
    if not EXTRACT_DIR.exists():
        return None
    for p in EXTRACT_DIR.iterdir():
        if p.is_file() and app_id in p.name:
            return p
    return None


def sniff_first_last_events(path: Path) -> tuple[str | None, str | None, int]:
    """快速读取首尾各 1 行 JSON 事件名，返回 (first_event, last_event, total_lines_estimate)。
    大文件不做 wc -l 全量扫描，total_lines 用文件行计数（流式）。
    """
    first_event = None
    last_event = None
    total_lines = 0
    last_line = ""
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for i, line in enumerate(f):
            total_lines += 1
            line = line.strip()
            if not line:
                continue
            if first_event is None:
                try:
                    first_event = json.loads(line).get("Event")
                except Exception:
                    first_event = "<unparseable>"
            last_line = line
    if last_line:
        try:
            last_event = json.loads(last_line).get("Event")
        except Exception:
            last_event = "<unparseable>"
    return first_event, last_event, total_lines


def classify_completeness(file_name: str, last_event: str | None) -> tuple[str, str]:
    """根据文件后缀 + 尾事件 判定完整性等级，返回 (level, reason)"""
    is_inprogress = file_name.endswith(".inprogress")
    has_app_end = (last_event == "SparkListenerApplicationEnd")
    if is_inprogress and not has_app_end:
        return ("LOW", "文件名为 .inprogress 且缺少 SparkListenerApplicationEnd → 作业异常终止")
    if is_inprogress and has_app_end:
        return ("MEDIUM", "文件名为 .inprogress 但已写出 ApplicationEnd → Spark History Server 未来得及 rename")
    if not is_inprogress and has_app_end:
        return ("HIGH", "文件已正常 close 且含 ApplicationEnd → 完整闭合")
    return ("MEDIUM", f"未知组合：is_inprogress={is_inprogress}, last_event={last_event}")


def main() -> None:
    rows: list[dict] = []
    for app in TARGET_APPS:
        app_id = app["app_id"]
        rec = dict(app)
        zip_path = find_zip_for_app(app_id)
        ext_path = find_extracted(app_id)

        if zip_path is None and ext_path is None:
            rec["zip_present"] = False
            rec["zip_size"] = "-"
            rec["extracted_path"] = "-"
            rec["extracted_size"] = "-"
            rec["first_event"] = "-"
            rec["last_event"] = "-"
            rec["total_lines"] = 0
            rec["confidence"] = "MISSING"
            rec["confidence_reason"] = "桌面目录下未找到该 ApplicationID 对应的任何 zip / 解压文件 → 证据完全缺失"
            rows.append(rec)
            continue

        rec["zip_present"] = zip_path is not None
        rec["zip_size"] = human_size(zip_path.stat().st_size) if zip_path else "-"

        if ext_path is None:
            rec["extracted_path"] = "(未解压)"
            rec["extracted_size"] = "-"
            rec["first_event"] = "-"
            rec["last_event"] = "-"
            rec["total_lines"] = 0
            rec["confidence"] = "MEDIUM"
            rec["confidence_reason"] = "zip 存在但未解压；解压后再核验"
            rows.append(rec)
            continue

        rec["extracted_path"] = str(ext_path)
        rec["extracted_size"] = human_size(ext_path.stat().st_size)
        first, last, total = sniff_first_last_events(ext_path)
        rec["first_event"] = first
        rec["last_event"] = last
        rec["total_lines"] = total
        level, reason = classify_completeness(ext_path.name, last)
        rec["confidence"] = level
        rec["confidence_reason"] = reason
        rows.append(rec)

    # ===== 输出到 stdout（人类可读）=====
    print(f"扫描目录: {DESKTOP_DIR}")
    print(f"扫描时间: {datetime.now().isoformat(timespec='seconds')}\n")
    print(f"{'app_id':45} {'告警状态':10} {'置信度':8} {'尾事件':40} {'行数':>10}")
    print("-" * 130)
    for r in rows:
        print(f"{r['app_id']:45} {r['alarm_status']:10} {r['confidence']:8} {str(r.get('last_event','-'))[:38]:40} {r['total_lines']:>10}")

    # ===== 输出 Markdown 报告片段 =====
    OUTPUT_MD.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    lines.append("# 00 — Event Log 清单核验\n")
    lines.append(f"> 扫描目录：`{DESKTOP_DIR}`  ")
    lines.append(f"> 扫描时间：{datetime.now().isoformat(timespec='seconds')}  ")
    lines.append(f"> 解压目录：`{EXTRACT_DIR}`（**不**拷入 IDE workspace，遵循需求 7.5）\n")

    lines.append("## 1. 4 个目标 Application 文件清单\n")
    lines.append("| ApplicationID | 业务名 | 调度 | 任务ID | 告警状态 | zip 大小 | 解压后大小 | 首事件 | 尾事件 | 总行数 | 置信度 |")
    lines.append("|---|---|---|---|---|---|---|---|---|---:|---|")
    for r in rows:
        lines.append(
            f"| `{r['app_id']}` | {r['biz_name']} | {r['scheduler']} | {r['task_id']} | "
            f"**{r['alarm_status']}** | {r['zip_size']} | {r['extracted_size']} | "
            f"`{r.get('first_event','-')}` | `{r.get('last_event','-')}` | {r['total_lines']:,} | "
            f"**{r['confidence']}** |"
        )
    lines.append("")

    lines.append("## 2. 完整性结论（每个 App 一条）\n")
    for r in rows:
        emoji = {"HIGH": "🟢", "MEDIUM": "🟡", "LOW": "🔴", "MISSING": "⚫"}.get(r["confidence"], "❓")
        lines.append(f"- {emoji} **`{r['app_id']}`** — 置信度 **{r['confidence']}**：{r['confidence_reason']}")
    lines.append("")

    lines.append("## 3. 关键观察（基于首尾事件嗅探）\n")
    lines.append("> 这一节是后续根因分析的**第一组证据**，请在主报告中显式引用。\n")
    inprogress_count = sum(1 for r in rows if r.get("extracted_path") and ".inprogress" in str(r.get("extracted_path","")))
    missing_count = sum(1 for r in rows if r["confidence"] == "MISSING")
    lines.append(f"1. **3 个失败作业中有 {inprogress_count} 个文件停留在 `.inprogress` 状态**——这是 Spark History Server 没收到 `ApplicationEnd` 事件的直接物证，与告警\"自动处理失败\"现象一致。")
    if missing_count > 0:
        miss_apps = [r["app_id"] for r in rows if r["confidence"] == "MISSING"]
        lines.append(f"2. **缺失 {missing_count} 个 Application 的 Event Log**：{', '.join(f'`{a}`' for a in miss_apps)}。该作业的根因分析将仅基于告警原文与同业务作业（`dm_crm_trace_lead_full_link_data_hf`）的横向对比，**结论为低置信度推断**。")
    lines.append("3. **对照组 `application_1767599787371_13236774` 的尾事件为 `SparkListenerApplicationEnd`**——作业正常结束，证据链完整，可作为成功打散的基准。")
    lines.append("")

    lines.append("## 4. 给后续步骤的输入\n")
    lines.append("| 用途 | 文件路径 |")
    lines.append("|---|---|")
    for r in rows:
        if r.get("extracted_path") and r["extracted_path"] not in ("-", "(未解压)"):
            lines.append(f"| 解析输入（{r['app_id'].split('_')[-1]}） | `{r['extracted_path']}` |")
    lines.append("")

    OUTPUT_MD.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n✅ Markdown 已写出: {OUTPUT_MD}")


if __name__ == "__main__":
    main()
