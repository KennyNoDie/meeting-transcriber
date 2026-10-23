#!/usr/bin/env python3
"""
按日期聚合后台静默转录切片，生成：
1. outputs/daily_timelines/YYYY-MM-DD_raw_timeline.md  (按时间排序的全天对话时间线原文与切片合集)
2. outputs/daily_timelines/YYYY-MM-DD_prompt_bundle.md (已注入每日复盘 Prompt 的完整输入包，可直接喂给 Agent)

用法：
  python3 scripts/build_daily_timeline.py                    # 默认汇总今天
  python3 scripts/build_daily_timeline.py --date 2026-10-23  # 汇总指定日期
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUTS_ROOT = PROJECT_ROOT / "outputs"
PROTOCOLS_DIR = OUTPUTS_ROOT / "protocols"
RECORDINGS_DIR = OUTPUTS_ROOT / "recordings"
TIMELINES_DIR = OUTPUTS_ROOT / "daily_timelines"
DAILY_PROMPT_FILE = PROJECT_ROOT / "prompts" / "daily_timeline_summary.md"

FALLBACK_DIRS = [
    PROTOCOLS_DIR,
    OUTPUTS_ROOT,
    Path.home() / "Library" / "Application Support" / "MeetingTranscriber" / "protocols",
    Path.home() / "Downloads" / "MeetingTranscriber",
]

AUDIO_DIRS = [
    RECORDINGS_DIR,
    PROTOCOLS_DIR,
    OUTPUTS_ROOT,
    Path.home() / "Library" / "Application Support" / "MeetingTranscriber" / "recordings",
]


@dataclass(order=True)
class TimeSliceEntry:
    sort_time: str
    stem: str
    md_path: Path | None
    txt_path: Path | None
    qwen_path: Path | None
    audio_paths: list[Path]


def extract_time_from_stem(stem: str, fallback_mtime: float) -> tuple[str, str]:
    """从文件名形如 20261023_1430_slug 提取 (YYYY-MM-DD, HH:MM)。"""
    match = re.match(r"^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})", stem)
    if match:
        y, m, d, hh, mm = match.groups()
        return f"{y}-{m}-{d}", f"{hh}:{mm}"
    dt_obj = dt.datetime.fromtimestamp(fallback_mtime)
    return dt_obj.strftime("%Y-%m-%d"), dt_obj.strftime("%H:%M")


def collect_entries_for_date(target_date: str) -> list[TimeSliceEntry]:
    by_stem: dict[str, TimeSliceEntry] = {}
    for folder in FALLBACK_DIRS:
        if not folder.exists():
            continue
        for file_path in sorted(folder.iterdir()):
            if not file_path.is_file() or file_path.name.startswith("."):
                continue
            if file_path.suffix not in {".md", ".txt"}:
                continue

            base_stem = file_path.name
            is_qwen = base_stem.endswith(".qwen3.txt")
            if is_qwen:
                base_stem = base_stem[: -len(".qwen3.txt")]
            else:
                base_stem = file_path.stem

            file_date, hhmm = extract_time_from_stem(base_stem, file_path.stat().st_mtime)
            if file_date != target_date:
                continue

            entry = by_stem.get(base_stem)
            if entry is None:
                entry = TimeSliceEntry(
                    sort_time=hhmm,
                    stem=base_stem,
                    md_path=None,
                    txt_path=None,
                    qwen_path=None,
                    audio_paths=[],
                )
                by_stem[base_stem] = entry

            if is_qwen:
                entry.qwen_path = file_path
            elif file_path.suffix == ".md":
                entry.md_path = file_path
            elif file_path.suffix == ".txt":
                entry.txt_path = file_path

    for audio_dir in AUDIO_DIRS:
        if not audio_dir.exists():
            continue
        for wav in sorted(audio_dir.glob("*.wav")):
            stem = wav.stem
            for suffix in ("_mix_16k", "_app_16k", "_mic_16k", "_16k", "_mix", "_app", "_mic"):
                if stem.endswith(suffix):
                    stem = stem[: -len(suffix)]
                    break
            if stem in by_stem and wav not in by_stem[stem].audio_paths:
                by_stem[stem].audio_paths.append(wav)

    return sorted(by_stem.values())


def extract_prompt_template(prompt_doc_path: Path) -> str:
    if not prompt_doc_path.exists():
        return "请按时间顺序总结以下全天语音转录内容，提取关键结论与双向待办。"
    raw = prompt_doc_path.read_text(encoding="utf-8")
    code_blocks = re.findall(r"```markdown\n(.*?)```", raw, flags=re.DOTALL)
    return code_blocks[0].strip() if code_blocks else raw.strip()


def build_timeline_markdown(target_date: str, entries: list[TimeSliceEntry]) -> str:
    lines: list[str] = [
        f"# 🗂️ 原始语音时间线汇总 ({target_date})",
        "",
        f"- **捕获对话场次**：{len(entries)} 场",
        f"- **生成时间**：{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "",
        "---",
        "",
    ]

    for idx, entry in enumerate(entries, start=1):
        lines.append(f"## 切片 #{idx} | 起始时间 `{entry.sort_time}` | 标识 `{entry.stem}`")
        if entry.audio_paths:
            audio_list = " , ".join(f"`{p.name}`" for p in entry.audio_paths)
            lines.append(f"- **关联录音文件**：{audio_list}")
        lines.append("")

        if entry.md_path and entry.md_path.exists():
            md_content = entry.md_path.read_text(encoding="utf-8").strip()
            lines.append("### [结构化切片摘要]")
            lines.append(md_content)
            lines.append("")

        transcript_source = entry.qwen_path or entry.txt_path
        if transcript_source and transcript_source.exists():
            label = "Qwen3-ASR-1.7B 逐字稿" if entry.qwen_path else "原始逐字稿"
            txt_content = transcript_source.read_text(encoding="utf-8").strip()
            if not (entry.md_path and txt_content in entry.md_path.read_text(encoding="utf-8")):
                lines.append(f"### [{label}]")
                lines.append("```text")
                lines.append(txt_content)
                lines.append("```")
                lines.append("")

        lines.append("---")
        lines.append("")

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="聚合指定日期的所有后台静默转录切片为全天时间线")
    parser.add_argument(
        "--date",
        type=str,
        default=dt.date.today().strftime("%Y-%m-%d"),
        help="目标日期 YYYY-MM-DD（默认今天）",
    )
    args = parser.parse_args()

    TIMELINES_DIR.mkdir(parents=True, exist_ok=True)
    entries = collect_entries_for_date(args.date)

    raw_timeline_path = TIMELINES_DIR / f"{args.date}_raw_timeline.md"
    bundle_path = TIMELINES_DIR / f"{args.date}_prompt_bundle.md"

    if not entries:
        print(f"[{args.date}] 暂无捕获到的对话切片（检查目录: {PROTOCOLS_DIR}）。")
        return

    raw_timeline_md = build_timeline_markdown(args.date, entries)
    raw_timeline_path.write_text(raw_timeline_md, encoding="utf-8")

    prompt_template = extract_prompt_template(DAILY_PROMPT_FILE).replace("YYYY-MM-DD", args.date)
    bundle_md = f"{prompt_template}\n\n---\n\n# 附：今日真实转录时间线数据 ({args.date})\n\n{raw_timeline_md}\n"
    bundle_path.write_text(bundle_md, encoding="utf-8")

    print(f"已生成 [{args.date}] 全天时间线（共 {len(entries)} 场对话）：")
    print(f"  1. 纯时间线汇总: {raw_timeline_path}")
    print(f"  2. 含复盘 Prompt 的完整输入包: {bundle_path}")


if __name__ == "__main__":
    main()
