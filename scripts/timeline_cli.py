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
import math
import re
import subprocess
import sys
import time
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

SPEAKERS_DB_PRIMARY = OUTPUTS_DIR / "speakers.json"
SPEAKERS_DB_APPSUPPORT = (
    Path.home() / "Library" / "Application Support" / "MeetingTranscriber" / "speakers.json"
)
SPEAKERS_DB_BACKUP = CONFIG_DIR / "speakers.json"
APPLE_REFERENCE_EPOCH = 978307200.0  # 2001-01-01 00:00:00 UTC (Swift Date default JSON encoding)
MAX_RECENT_SAMPLES = 3
MIN_SPEAKING_TIME_FOR_CENTROID = 3.0

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


_INLINE_ECHO_RE = re.compile(
    r"(?:(?:大家都在玩\s*)?发现\s*Feeds\s*游廊\s*主题精选.*?|Kenny\s*小光\s*Codex\s*Claude\s*)Qwen3-ASR\s*WhisperKit\s*FluidAudio[。.\s]*",
    re.IGNORECASE,
)


def is_prompt_echo_line(line: str) -> bool:
    """Detect silent-chunk Qwen3-ASR context prompt echoes."""
    cleaned = _INLINE_ECHO_RE.sub("", line).strip()
    if re.match(r"^\[[^\]]+\]\s*(?:\[[^\]]+\]|[^:]+):\s*$", cleaned):
        return True
    if re.search(r":\s*大家都在玩[。.\s]*$", line.strip()):
        return True
    if "Qwen3-ASR" in line and "WhisperKit" in line and "FluidAudio" in line and len(cleaned) < 25:
        return True
    if ("发现" in line and "游廊" in line and "主题精选" in line) and len(cleaned) < 25:
        return True
    return False


def cosine_distance(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 2.0
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a <= 0 or norm_b <= 0:
        return 2.0
    return round(1.0 - (dot / (norm_a * norm_b)), 4)


def load_speakers_db() -> list[dict[str, Any]]:
    for path in (SPEAKERS_DB_PRIMARY, SPEAKERS_DB_APPSUPPORT, SPEAKERS_DB_BACKUP):
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(data, list):
                    return data
            except Exception:
                continue
    return []


def save_speakers_db(speakers: list[dict[str, Any]]) -> None:
    payload = json.dumps(speakers, ensure_ascii=False, separators=(",", ":"))
    for path in (SPEAKERS_DB_PRIMARY, SPEAKERS_DB_APPSUPPORT, SPEAKERS_DB_BACKUP):
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".json.tmp")
            tmp.write_text(payload, encoding="utf-8")
            tmp.chmod(0o600)
            tmp.replace(path)
        except Exception:
            pass


def mean_embedding(vectors: list[list[float]]) -> list[float] | None:
    if not vectors or not vectors[0]:
        return None
    dim = len(vectors[0])
    if any(len(v) != dim for v in vectors):
        return None
    n = float(len(vectors))
    return [sum(v[i] for v in vectors) / n for i in range(dim)]


def upsert_speaker_embedding(
    speakers: list[dict[str, Any]],
    name: str,
    embedding: list[float],
    duration: float,
) -> None:
    now_apple = round(time.time() - APPLE_REFERENCE_EPOCH, 3)
    qualifies = duration >= MIN_SPEAKING_TIME_FOR_CENTROID
    for spk in speakers:
        if spk.get("name") == name:
            samples: list[list[float]] = list(spk.get("embeddings") or [])
            samples.append(embedding)
            if len(samples) > MAX_RECENT_SAMPLES:
                samples = samples[-MAX_RECENT_SAMPLES:]
            seed_centroid = spk.get("centroid") or mean_embedding(spk.get("embeddings") or [])
            seed_count = (
                int(spk.get("centroidSampleCount") or 0)
                if spk.get("centroid") is not None
                else (len(spk.get("embeddings") or []) if seed_centroid is not None else 0)
            )
            if qualifies and embedding:
                if seed_centroid and len(seed_centroid) == len(embedding):
                    total = float(seed_count + 1)
                    next_centroid = [
                        (seed_centroid[i] * seed_count + embedding[i]) / total
                        for i in range(len(embedding))
                    ]
                    next_count = seed_count + 1
                else:
                    next_centroid = embedding
                    next_count = 1
            else:
                next_centroid = seed_centroid
                next_count = seed_count

            spk["embeddings"] = samples
            if next_centroid is not None:
                spk["centroid"] = next_centroid
            if next_count > 0:
                spk["centroidSampleCount"] = next_count
            spk["lastUsed"] = now_apple
            spk["useCount"] = int(spk.get("useCount") or 0) + 1
            spk.pop("isSynthetic", None)
            return

    entry: dict[str, Any] = {
        "name": name,
        "embeddings": [embedding],
        "lastUsed": now_apple,
        "useCount": 1,
    }
    if qualifies and embedding:
        entry["centroid"] = embedding
        entry["centroidSampleCount"] = 1
    speakers.append(entry)


def merge_or_rename_speaker_in_db(
    speakers: list[dict[str, Any]],
    old_name: str,
    new_name: str,
) -> bool:
    if old_name == new_name:
        return False
    src_idx = next((i for i, s in enumerate(speakers) if s.get("name") == old_name), None)
    if src_idx is None:
        return False
    dst_idx = next((i for i, s in enumerate(speakers) if s.get("name") == new_name), None)
    src = speakers[src_idx]
    if dst_idx is None:
        src["name"] = new_name
        src["lastUsed"] = round(time.time() - APPLE_REFERENCE_EPOCH, 3)
        return True

    dst = speakers[dst_idx]
    samples = list(dst.get("embeddings") or []) + list(src.get("embeddings") or [])
    if len(samples) > MAX_RECENT_SAMPLES:
        samples = samples[-MAX_RECENT_SAMPLES:]
    ca, cb = dst.get("centroid"), src.get("centroid")
    na, nb = int(dst.get("centroidSampleCount") or 0), int(src.get("centroidSampleCount") or 0)
    if ca and cb and len(ca) == len(cb):
        tot = max(1, na + nb)
        merged_c = [(ca[i] * na + cb[i] * nb) / float(tot) for i in range(len(ca))]
    else:
        merged_c = ca or cb or mean_embedding(samples)
    dst["embeddings"] = samples
    if merged_c is not None:
        dst["centroid"] = merged_c
    if na + nb > 0:
        dst["centroidSampleCount"] = na + nb
    dst["useCount"] = int(dst.get("useCount") or 0) + int(src.get("useCount") or 0)
    dst["lastUsed"] = round(time.time() - APPLE_REFERENCE_EPOCH, 3)
    speakers.pop(src_idx)
    return True


def find_speaker_sidecar(slug_query: str | None = None) -> tuple[str, Path, dict[str, Any]] | None:
    if not RECORDINGS_DIR.exists():
        return None
    candidates: list[tuple[float, str, Path]] = []
    for p in RECORDINGS_DIR.iterdir():
        if p.name.endswith("_speakers.json"):
            slug = p.name[: -len("_speakers.json")]
            candidates.append((p.stat().st_mtime, slug, p))
        elif p.name.endswith("_naming.json"):
            slug = p.name[: -len("_naming.json")]
            speakers_copy = RECORDINGS_DIR / f"{slug}_speakers.json"
            if not speakers_copy.exists():
                try:
                    speakers_copy.write_bytes(p.read_bytes())
                except Exception:
                    pass
            candidates.append((p.stat().st_mtime, slug, speakers_copy if speakers_copy.exists() else p))

    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    for _, slug, path in candidates:
        if slug_query is None or slug_query == slug or slug_query in slug:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                return slug, path, data
            except Exception:
                continue
    return None


def extract_speaker_clues(transcript_path: Path | None, speaker_tags: list[str]) -> tuple[list[str], list[str]]:
    """Return (sample_utterances, adjacent_context_clues) for a speaker from the transcript."""
    if not transcript_path or not transcript_path.exists():
        return [], []
    lines = [
        ln.strip()
        for ln in transcript_path.read_text(encoding="utf-8", errors="replace").splitlines()
        if ln.strip() and not is_prompt_echo_line(ln)
    ]
    utterances: list[str] = []
    clues: list[str] = []
    line_re = re.compile(r"^\[([^\]]+)\]\s*(?:\[([^\]]+)\]|([^:]+)):\s*(.+)$")
    parsed: list[tuple[str, str, str, str]] = []
    for ln in lines:
        m = line_re.match(ln)
        if m:
            ts = m.group(1).strip()
            spk = (m.group(2) or m.group(3) or "").strip()
            txt = m.group(4).strip()
            parsed.append((ts, spk, txt, ln))

    tag_set = set(speaker_tags)
    for idx, (ts, spk, txt, full_ln) in enumerate(parsed):
        if spk in tag_set:
            if len(txt) >= 8 and len(utterances) < 5:
                utterances.append(f"[{ts}] {spk}: {txt[:140]}")
            if idx > 0 and parsed[idx - 1][1] not in tag_set and len(clues) < 4:
                prev_ts, prev_spk, prev_txt, _ = parsed[idx - 1]
                if any(k in prev_txt for k in ("哥", "少", "总", "老师", "你", "请", "讲", "投屏", "下面", "看下", "Kenny")):
                    clues.append(f"前一句 [{prev_ts}] {prev_spk}: {prev_txt[:100]} -> 当前 [{ts}] {spk}: {txt[:80]}")
            if idx + 1 < len(parsed) and parsed[idx + 1][1] not in tag_set and len(clues) < 4:
                next_ts, next_spk, next_txt, _ = parsed[idx + 1]
                if any(k in next_txt for k in ("哥", "少", "总", "老师", "辛苦", "谢谢", "刚刚")):
                    clues.append(f"当前 [{ts}] {spk}: {txt[:80]} -> 后一句 [{next_ts}] {next_spk}: {next_txt[:100]}")

    return utterances, clues


def cmd_speakers(args: argparse.Namespace) -> int:
    stored = load_speakers_db()
    stored_summary = []
    for s in stored:
        last_used_apple = s.get("lastUsed")
        last_used_iso = (
            dt.datetime.fromtimestamp(float(last_used_apple) + APPLE_REFERENCE_EPOCH)
            .astimezone()
            .isoformat(timespec="seconds")
            if last_used_apple is not None
            else None
        )
        stored_summary.append(
            {
                "name": s.get("name"),
                "useCount": s.get("useCount", 0),
                "centroidSampleCount": s.get("centroidSampleCount", 0),
                "recentSamples": len(s.get("embeddings") or []),
                "lastUsed": last_used_iso,
            }
        )

    sidecar_info = find_speaker_sidecar(args.slug)
    meeting_report = None
    if sidecar_info:
        slug, sidecar_path, data = sidecar_info
        t_path = PROTOCOLS_DIR / f"{slug}.txt"
        mapping: dict[str, str] = data.get("mapping") or {}
        speaking_times: dict[str, float] = data.get("speakingTimes") or {}
        embeddings: dict[str, list[float]] = data.get("embeddings") or {}

        speakers_list = []
        for raw_label, dur in sorted(speaking_times.items(), key=lambda x: x[1], reverse=True):
            assigned = mapping.get(raw_label, raw_label)
            emb = embeddings.get(raw_label) or []
            candidates = []
            if emb:
                for spk in stored:
                    c_vec = spk.get("centroid")
                    s_vecs = spk.get("embeddings") or []
                    dists = [cosine_distance(emb, v) for v in s_vecs if v]
                    if c_vec:
                        dists.append(cosine_distance(emb, c_vec))
                    if dists:
                        candidates.append({"name": spk.get("name"), "distance": min(dists)})
                candidates.sort(key=lambda x: x["distance"])

            utterances, clues = extract_speaker_clues(t_path, [raw_label, assigned])
            speakers_list.append(
                {
                    "rawLabel": raw_label,
                    "assignedName": assigned,
                    "track": "mic (本人麦克风)" if raw_label.startswith("M_") else "app (远端参会人)",
                    "speakingSeconds": round(float(dur), 1),
                    "voiceprintCandidates": candidates[:3],
                    "contextClues": clues,
                    "sampleUtterances": utterances,
                }
            )

        meeting_report = {
            "slug": slug,
            "meetingTitle": data.get("meetingTitle"),
            "sidecarPath": str(sidecar_path),
            "transcriptPath": str(t_path) if t_path.exists() else None,
            "speakerCount": len(speakers_list),
            "speakers": speakers_list,
        }

    print(
        json.dumps(
            {
                "speakersDBPath": str(SPEAKERS_DB_PRIMARY),
                "storedVoiceprintCount": len(stored_summary),
                "storedVoiceprints": stored_summary,
                "meetingSpeakers": meeting_report,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def rewrite_transcript_speakers(
    transcript_path: Path,
    replacements: dict[str, str],
    clean_hallucinations: bool = True,
) -> tuple[int, int]:
    """Rewrite speaker labels in a transcript file and optionally strip prompt echoes."""
    if not transcript_path.exists():
        return 0, 0
    raw_lines = transcript_path.read_text(encoding="utf-8", errors="replace").splitlines()
    removed_echoes = 0
    renamed_lines = 0
    out_lines: list[str] = []

    for line in raw_lines:
        if clean_hallucinations and is_prompt_echo_line(line):
            removed_echoes += 1
            continue
        updated = _INLINE_ECHO_RE.sub("", line) if clean_hallucinations else line
        if updated != line:
            removed_echoes += 1
        for old_label, new_name in replacements.items():
            if not old_label or not new_name or old_label == new_name:
                continue
            for pat in (f"] {old_label}:", f"] [{old_label}]:"):
                if pat in updated:
                    updated = updated.replace(pat, f"] {new_name}:")
                    renamed_lines += 1
        out_lines.append(updated)

    transcript_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    return renamed_lines, removed_echoes


def cmd_assign_speaker(args: argparse.Namespace) -> int:
    pairs: dict[str, str] = {}
    for item in (args.map or "").split(","):
        item = item.strip()
        if not item or "=" not in item:
            continue
        k, v = item.split("=", 1)
        if k.strip() and v.strip():
            pairs[k.strip()] = v.strip()

    if not pairs and not args.clean_only:
        print(json.dumps({"error": "No valid speaker mappings provided in --map 'OLD=NEW,...'"}, ensure_ascii=False))
        return 1

    stored = load_speakers_db()
    sidecar_info = find_speaker_sidecar(args.slug)
    updated_voiceprints: list[str] = []
    rewritten_files: list[dict[str, Any]] = []

    if sidecar_info:
        slug, sidecar_path, data = sidecar_info
        mapping: dict[str, str] = data.get("mapping") or {}
        speaking_times: dict[str, float] = data.get("speakingTimes") or {}
        embeddings: dict[str, list[float]] = data.get("embeddings") or {}
        transcript_replacements: dict[str, str] = dict(pairs)

        for old_key, new_name in pairs.items():
            # Match either by raw label (e.g. R_S5) or by current assigned name (e.g. 说话人_02)
            matched_raw_labels = [
                raw for raw, assigned in mapping.items() if raw == old_key or assigned == old_key
            ]
            if old_key in embeddings and old_key not in matched_raw_labels:
                matched_raw_labels.append(old_key)

            for raw_label in matched_raw_labels:
                prev_assigned = mapping.get(raw_label, raw_label)
                mapping[raw_label] = new_name
                transcript_replacements[raw_label] = new_name
                transcript_replacements[prev_assigned] = new_name
                if prev_assigned != raw_label and prev_assigned != new_name:
                    merge_or_rename_speaker_in_db(stored, prev_assigned, new_name)

                emb = embeddings.get(raw_label)
                dur = float(speaking_times.get(raw_label) or 0.0)
                if emb:
                    upsert_speaker_embedding(stored, new_name, emb, dur)
                    updated_voiceprints.append(f"{raw_label} ({dur:.1f}s) -> {new_name}")

        data["mapping"] = mapping
        payload_bytes = json.dumps(data, ensure_ascii=False).encode("utf-8")
        for s_path in (
            RECORDINGS_DIR / f"{slug}_speakers.json",
            RECORDINGS_DIR / f"{slug}_naming.json",
        ):
            if s_path.exists() or s_path.name.endswith("_speakers.json"):
                try:
                    s_path.write_bytes(payload_bytes)
                    s_path.chmod(0o600)
                except Exception:
                    pass

        t_path = PROTOCOLS_DIR / f"{slug}.txt"
        if t_path.exists():
            r_cnt, e_cnt = rewrite_transcript_speakers(t_path, transcript_replacements, clean_hallucinations=True)
            rewritten_files.append(
                {
                    "transcriptPath": str(t_path),
                    "renamedLines": r_cnt,
                    "removedPromptEchoLines": e_cnt,
                }
            )

    # Also rename/merge in global speakers.json if user renamed a stored provisional name directly
    for old_key, new_name in pairs.items():
        if merge_or_rename_speaker_in_db(stored, old_key, new_name):
            updated_voiceprints.append(f"DB:{old_key} -> {new_name}")

    save_speakers_db(stored)

    print(
        json.dumps(
            {
                "status": "ok",
                "speakersDBPath": str(SPEAKERS_DB_PRIMARY),
                "totalStoredVoiceprints": len(stored),
                "updatedVoiceprints": updated_voiceprints,
                "rewrittenTranscripts": rewritten_files,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


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
    spk = args.speaker or ("Kenny" if "_mic" in audio_path.stem else "Remote")
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
    p_search.add_argument("--speaker", help="Filter by speaker tag (e.g. Kenny, Remote)")
    p_search.add_argument("--context-lines", type=int, default=1, help="Surrounding lines")

    p_read = sub.add_parser("read", help="Read a transcript or time slice")
    p_read.add_argument("target", help="Recording slug or path")
    p_read.add_argument("--start", help="Start timestamp MM:SS")
    p_read.add_argument("--end", help="End timestamp MM:SS")

    p_tl = sub.add_parser("build-timeline", help="Aggregate daily timeline markdown")
    p_tl.add_argument("--date", help="Date YYYY-MM-DD (default: today)")

    p_re = sub.add_parser("retranscribe", help="Re-transcribe audio with Qwen3-ASR-1.7B")
    p_re.add_argument("target", help="Recording slug or .wav file path")
    p_re.add_argument("--speaker", default="Kenny", help="Speaker tag for single-track")

    p_spk = sub.add_parser(
        "speakers",
        help="Inspect persistent voiceprint DB (speakers.json) and meeting speaker context clues",
    )
    p_spk.add_argument("--slug", help="Specific meeting slug (default: latest meeting with speaker data)")

    p_assign = sub.add_parser(
        "assign-speaker",
        help="Persist speaker identity mapping to speakers.json and rewrite transcript labels",
    )
    p_assign.add_argument("--slug", help="Specific meeting slug (default: latest meeting)")
    p_assign.add_argument(
        "--map",
        default="",
        help="Comma-separated speaker mappings, e.g. 'M_S1=Kenny,R_S5=一鸣,R_S3=老丁'",
    )
    p_assign.add_argument(
        "--clean-only",
        action="store_true",
        help="Only clean prompt-echo hallucination lines without changing speaker names",
    )

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
        "speakers": cmd_speakers,
        "assign-speaker": cmd_assign_speaker,
    }
    return dispatch[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
