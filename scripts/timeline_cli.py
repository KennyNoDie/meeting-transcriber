#!/usr/bin/env python3
"""
MeetingTranscriber Timeline & Context CLI (Auday-style local retrieval & operations).

Provides narrow search, metadata listing, interval reading, daily timeline building,
and non-destructive Qwen3-ASR-1.7B re-transcription over local recordings & transcripts.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
import wave
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUTS_DIR = PROJECT_ROOT / "outputs"
PROTOCOLS_DIR = OUTPUTS_DIR / "protocols"
RECORDINGS_DIR = OUTPUTS_DIR / "recordings"
DAILY_TIMELINES_DIR = OUTPUTS_DIR / "daily_timelines"
CONFIG_DIR = PROJECT_ROOT / "config"
PROMPTS_DIR = PROJECT_ROOT / "prompts"

STAMP_RE = re.compile(r"^(\d{8})_(\d{6})(?:_(.+))?$")
AUDIO_SUFFIXES = (
    "_mix_16k",
    "_app_16k",
    "_mic_16k",
    "_16k",
    "_mix",
    "_app",
    "_mic",
)


def normalize_stem(stem: str) -> str:
    if stem.endswith(".qwen3"):
        stem = stem[: -len(".qwen3")]
    for suffix in AUDIO_SUFFIXES:
        if stem.endswith(suffix):
            return stem[: -len(suffix)]
    return stem


def parse_slug(slug: str, fallback_path: Path | None = None) -> tuple[str, str, str]:
    match = STAMP_RE.match(slug)
    if match:
        d, t, raw_title = match.group(1), match.group(2), match.group(3) or "语音记录"
        date_str = f"{d[:4]}-{d[4:6]}-{d[6:8]}"
        time_str = f"{t[:2]}:{t[2:4]}:{t[4:6]}"
        return date_str, time_str, raw_title.replace("_", " ")

    if fallback_path and fallback_path.exists():
        mtime = dt.datetime.fromtimestamp(fallback_path.stat().st_mtime)
    else:
        mtime = dt.datetime.now()
    return mtime.strftime("%Y-%m-%d"), mtime.strftime("%H:%M:%S"), slug


def wav_duration_seconds(path: Path | None) -> float:
    if not path or not path.exists():
        return 0.0
    try:
        if path.suffix.lower() == ".wav":
            with wave.open(str(path), "rb") as wf:
                rate = wf.getframerate()
                frames = wf.getnframes()
                channels = max(1, wf.getnchannels())
                sampwidth = max(1, wf.getsampwidth())
                if frames > 0 and rate > 0:
                    return round(frames / float(rate), 1)
                size = path.stat().st_size
                if size > 44 and rate > 0:
                    return round((size - 44) / float(rate * channels * sampwidth), 1)
    except Exception:
        pass
    return 0.0


def discover_records(date_filter: str | None = None) -> list[dict[str, Any]]:
    text_by_slug: dict[str, Path] = {}
    qwen_by_slug: dict[str, Path] = {}

    for folder in (PROTOCOLS_DIR, OUTPUTS_DIR):
        if not folder.exists():
            continue
        for p in sorted(folder.iterdir()):
            if not p.is_file() or p.name.startswith("."):
                continue
            ext = p.suffix.lower()
            if ext not in (".txt", ".md"):
                continue
            stem = p.stem
            is_qwen = stem.endswith(".qwen3")
            slug = normalize_stem(stem)
            if is_qwen:
                qwen_by_slug[slug] = p
            if slug not in text_by_slug or ext == ".md" or is_qwen:
                text_by_slug[slug] = p

    mix_by_slug: dict[str, Path] = {}
    mic_by_slug: dict[str, Path] = {}
    app_by_slug: dict[str, Path] = {}
    in_progress_slugs: set[str] = set()

    for folder in (RECORDINGS_DIR, OUTPUTS_DIR):
        if not folder.exists():
            continue
        for p in sorted(folder.iterdir()):
            if p.name.endswith("_recording.marker"):
                in_progress_slugs.add(p.name[: -len("_recording.marker")])
                continue
            if p.name.endswith("_app16k_raw.tmp"):
                slug = p.name[: -len("_app16k_raw.tmp")]
                in_progress_slugs.add(slug)
                app_by_slug.setdefault(slug, p)
                continue
            if not p.is_file() or p.suffix.lower() != ".wav":
                continue
            stem = p.stem
            slug = normalize_stem(stem)
            if stem.endswith("_mic") or stem.endswith("_mic_16k"):
                mic_by_slug.setdefault(slug, p)
            elif stem.endswith("_app") or stem.endswith("_app_16k"):
                app_by_slug.setdefault(slug, p)
            else:
                mix_by_slug.setdefault(slug, p)

    all_slugs = (
        set(text_by_slug)
        | set(mix_by_slug)
        | set(mic_by_slug)
        | set(app_by_slug)
        | in_progress_slugs
    )

    records: list[dict[str, Any]] = []
    for slug in sorted(all_slugs):
        txt_path = qwen_by_slug.get(slug) or text_by_slug.get(slug)
        mic_path = mic_by_slug.get(slug)
        app_path = app_by_slug.get(slug)
        primary_audio = mix_by_slug.get(slug) or mic_path or app_path
        date_str, time_str, title = parse_slug(slug, txt_path or primary_audio)

        if date_filter and not date_str.startswith(date_filter):
            continue

        content = ""
        if txt_path and txt_path.exists():
            content = txt_path.read_text(encoding="utf-8", errors="replace").strip()

        speakers = sorted(
            set(
                re.findall(r"\]\s*\[([A-Za-z0-9_\u4e00-\u9fa5 ]+)\]", content)
                + re.findall(r"\[([A-Za-z0-9_\u4e00-\u9fa5 ]+)\]:", content)
            )
        )
        duration = wav_duration_seconds(primary_audio)
        track_mode = (
            "dual_track"
            if (mic_path and app_path)
            else ("mic_only" if mic_path else ("app_only" if app_path else "transcript_only"))
        )

        records.append(
            {
                "slug": slug,
                "date": date_str,
                "time": time_str,
                "title": title,
                "status": "recording_in_progress" if slug in in_progress_slugs else (
                    "transcribed" if content else "audio_only"
                ),
                "trackMode": track_mode,
                "durationSeconds": duration,
                "charCount": len(content),
                "speakers": speakers,
                "transcriptPath": str(txt_path) if txt_path else None,
                "qwenDerivativePath": str(qwen_by_slug[slug]) if slug in qwen_by_slug else None,
                "primaryAudioPath": str(primary_audio) if primary_audio else None,
                "micAudioPath": str(mic_path) if mic_path else None,
                "appAudioPath": str(app_path) if app_path else None,
            }
        )

    records.sort(key=lambda r: f"{r['date']}_{r['time']}_{r['slug']}")
    return records


def parse_mmss(ts: str) -> float:
    parts = [float(p) for p in ts.strip().split(":")]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0.0


def cmd_status(_args: argparse.Namespace) -> int:
    mt_cli = Path.home() / ".local" / "bin" / "mt-cli"
    app_state: dict[str, Any] = {}
    if mt_cli.exists():
        res = subprocess.run([str(mt_cli), "state"], capture_output=True, text=True)
        if res.returncode == 0:
            try:
                app_state = json.loads(res.stdout)
            except Exception:
                pass

    today = dt.date.today().strftime("%Y-%m-%d")
    today_records = discover_records(date_filter=today)
    all_records = discover_records()

    payload = {
        "checkedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "watchState": app_state.get("watchState", "unknown"),
        "badge": app_state.get("badge", "unknown"),
        "activeEngine": app_state.get("engines", {}).get("active", "qwen3ASR"),
        "permissionHealth": app_state.get("permissionHealth", {}),
        "channelHealth": app_state.get("channelHealth", {}),
        "todayDate": today,
        "todayRecordCount": len(today_records),
        "totalRecordCount": len(all_records),
        "latestRecord": all_records[-1] if all_records else None,
        "outputsDir": str(OUTPUTS_DIR),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    records = discover_records(date_filter=args.date)
    if args.limit and args.limit > 0:
        records = records[-args.limit :]
    print(
        json.dumps(
            {
                "dateFilter": args.date,
                "count": len(records),
                "records": records,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    records = discover_records(date_filter=args.date)
    pattern = re.compile(re.escape(args.query), re.IGNORECASE)
    matches: list[dict[str, Any]] = []

    for rec in records:
        t_path = rec.get("transcriptPath")
        if not t_path or not Path(t_path).exists():
            continue
        lines = Path(t_path).read_text(encoding="utf-8", errors="replace").splitlines()
        hit_snippets: list[str] = []
        for idx, line in enumerate(lines):
            if args.speaker and f"[{args.speaker}]" not in line:
                continue
            if pattern.search(line):
                start_i = max(0, idx - args.context_lines)
                end_i = min(len(lines), idx + args.context_lines + 1)
                snippet = "\n".join(lines[start_i:end_i])
                hit_snippets.append(snippet)

        if hit_snippets:
            matches.append(
                {
                    "slug": rec["slug"],
                    "date": rec["date"],
                    "time": rec["time"],
                    "title": rec["title"],
                    "transcriptPath": t_path,
                    "primaryAudioPath": rec["primaryAudioPath"],
                    "hitCount": len(hit_snippets),
                    "excerpts": hit_snippets[:10],
                }
            )

    print(
        json.dumps(
            {
                "query": args.query,
                "dateFilter": args.date,
                "speakerFilter": args.speaker,
                "matchedRecords": len(matches),
                "results": matches,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def cmd_read(args: argparse.Namespace) -> int:
    records = discover_records()
    target = None
    for rec in records:
        if (
            rec["slug"] == args.target
            or args.target in (rec["slug"], rec.get("transcriptPath"), rec.get("primaryAudioPath"))
            or args.target in rec["slug"]
        ):
            target = rec
            break

    if not target:
        print(json.dumps({"error": f"Record not found: {args.target}"}, ensure_ascii=False))
        return 1

    t_path = target.get("transcriptPath")
    text = ""
    if t_path and Path(t_path).exists():
        text = Path(t_path).read_text(encoding="utf-8", errors="replace")

    if args.start or args.end:
        start_s = parse_mmss(args.start) if args.start else 0.0
        end_s = parse_mmss(args.end) if args.end else float("inf")
        filtered_lines: list[str] = []
        ts_re = re.compile(r"\[(\d{1,2}:\d{2}(?::\d{2})?)(?:\s*-\s*(\d{1,2}:\d{2}(?::\d{2})?))?\]")
        for line in text.splitlines():
            m = ts_re.search(line)
            if not m:
                continue
            seg_start = parse_mmss(m.group(1))
            seg_end = parse_mmss(m.group(2)) if m.group(2) else seg_start
            if seg_end >= start_s and seg_start <= end_s:
                filtered_lines.append(line)
        text = "\n".join(filtered_lines)

    print(
        json.dumps(
            {
                "record": target,
                "interval": {"start": args.start, "end": args.end},
                "text": text,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def cmd_build_timeline(args: argparse.Namespace) -> int:
    builder = PROJECT_ROOT / "scripts" / "build_daily_timeline.py"
    cmd = [sys.executable, str(builder)]
    if args.date:
        cmd.extend(["--date", args.date])
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(json.dumps({"error": res.stderr.strip() or res.stdout.strip()}, ensure_ascii=False))
        return res.returncode
    date_str = args.date or dt.date.today().strftime("%Y-%m-%d")
    raw_file = DAILY_TIMELINES_DIR / f"{date_str}_raw_timeline.md"
    bundle_file = DAILY_TIMELINES_DIR / f"{date_str}_prompt_bundle.md"
    print(
        json.dumps(
            {
                "status": "ok",
                "date": date_str,
                "rawTimelinePath": str(raw_file),
                "promptBundlePath": str(bundle_file),
                "message": res.stdout.strip(),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def cmd_retranscribe(args: argparse.Namespace) -> int:
    records = discover_records()
    audio_path: Path | None = None
    candidate = Path(args.target)
    if candidate.exists() and candidate.suffix.lower() == ".wav":
        audio_path = candidate
    else:
        for rec in records:
            if args.target == rec["slug"] or args.target in rec["slug"]:
                if rec.get("primaryAudioPath"):
                    audio_path = Path(rec["primaryAudioPath"])
                break

    if not audio_path or not audio_path.exists():
        print(json.dumps({"error": f"Audio file not found for: {args.target}"}, ensure_ascii=False))
        return 1

    venv_py = PROJECT_ROOT / ".venv" / "bin" / "python"
    py_bin = str(venv_py) if venv_py.exists() else sys.executable
    qwen_script = PROJECT_ROOT / "scripts" / "qwen3_asr_transcribe.py"
    slug = normalize_stem(audio_path.stem)
    PROTOCOLS_DIR.mkdir(parents=True, exist_ok=True)
    out_txt = PROTOCOLS_DIR / f"{slug}.qwen3.txt"

    cmd = [py_bin, str(qwen_script), "--input", str(audio_path), "--json"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(json.dumps({"error": res.stderr.strip() or res.stdout.strip()}, ensure_ascii=False))
        return res.returncode

    payload = json.loads(res.stdout.strip() or "{}")
    segments = payload.get("segments", [])
    default_mic_spk = os.environ.get("MT_MIC_SPEAKER", "Me")
    spk = args.speaker or (default_mic_spk if "_mic" in audio_path.stem else "Remote")
    lines = [
        f"# Qwen3-ASR Transcript (Qwen/Qwen3-ASR-1.7B)",
        f"# Source: {audio_path.name}",
        f"# Transcribed At: {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        "",
    ]
    for s in segments:
        st = int(float(s.get("start", 0)))
        et = int(float(s.get("end", st)))
        txt = str(s.get("text", "")).strip()
        if txt:
            lines.append(f"[{st//60:02d}:{st%60:02d} - {et//60:02d}:{et%60:02d}] [{spk}]: {txt}")
    content = "\n".join(lines).strip()
    out_txt.write_text(content + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "status": "ok",
                "slug": slug,
                "sourceAudioPath": str(audio_path),
                "derivativeTranscriptPath": str(out_txt),
                "charCount": len(content),
                "preview": content[:800],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="MeetingTranscriber Local Timeline & Context CLI (Auday-style)"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Show live MeetingTranscriber state and archive counts")

    p_list = sub.add_parser("list", help="List recordings and transcripts by date")
    p_list.add_argument("--date", help="Date prefix YYYY-MM-DD or YYYY-MM")
    p_list.add_argument("--limit", type=int, default=50, help="Max records to return")

    p_search = sub.add_parser("search", help="Keyword search across transcripts with context")
    p_search.add_argument("query", help="Keyword or phrase to search")
    p_search.add_argument("--date", help="Filter by date prefix YYYY-MM-DD")
    p_search.add_argument("--speaker", help="Filter by speaker tag (e.g. Me, Remote)")
    p_search.add_argument("--context-lines", type=int, default=1, help="Surrounding lines")

    p_read = sub.add_parser("read", help="Read a transcript or time slice")
    p_read.add_argument("target", help="Recording slug or path")
    p_read.add_argument("--start", help="Start timestamp MM:SS")
    p_read.add_argument("--end", help="End timestamp MM:SS")

    p_tl = sub.add_parser("build-timeline", help="Aggregate daily timeline markdown")
    p_tl.add_argument("--date", help="Date YYYY-MM-DD (default: today)")

    p_re = sub.add_parser("retranscribe", help="Re-transcribe audio with Qwen3-ASR-1.7B")
    p_re.add_argument("target", help="Recording slug or .wav file path")
    p_re.add_argument("--speaker", default=os.environ.get("MT_MIC_SPEAKER", "Me"), help="Speaker tag for single-track")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    dispatch = {
        "status": cmd_status,
        "list": cmd_list,
        "search": cmd_search,
        "read": cmd_read,
        "build-timeline": cmd_build_timeline,
        "retranscribe": cmd_retranscribe,
    }
    return dispatch[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
