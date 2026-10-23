#!/usr/bin/env python3
"""
Qwen3-ASR-1.7B 本地 MLX 转录桥接脚本（支持 MeetingTranscriber 原生引擎调用与 CLI 批处理）

特性：
1. 默认使用 Qwen/Qwen3-ASR-1.7B（Apple Silicon MLX 原生加速）
2. 自动加载 config/vocabulary.txt 作为 Qwen3-ASR 的 domain context 词表偏置
3. 自动加载 config/terminology_rules.txt 执行 ASR 后正则纠错
4. 支持 --json 输出带精确语音起止时间戳的分句数组 [{"start": float, "end": float, "text": str}]，
   直接对接 MeetingTranscriber.app 的 Qwen3ASREngine 与 FluidAudio 说话人分离流水线
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np

BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUTS = BASE_DIR / "outputs" / "protocols"
DEFAULT_VOCAB = BASE_DIR / "config" / "vocabulary.txt"
DEFAULT_RULES = BASE_DIR / "config" / "terminology_rules.txt"
DEFAULT_MODEL = "Qwen/Qwen3-ASR-1.7B"


def load_vocab_context(vocab_path: Path) -> str:
    """Read vocabulary.txt and return space-separated domain terms for Qwen3-ASR context biasing."""
    if not vocab_path.exists():
        return ""
    terms: list[str] = []
    for raw in vocab_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        terms.append(line)
    return " ".join(terms[:120])


def load_terminology_rules(rules_path: Path) -> list[tuple[str, list[str]]]:
    """Parse 'Canonical => variant1 | variant2' rules from terminology_rules.txt."""
    if not rules_path.exists():
        return []
    rules: list[tuple[str, list[str]]] = []
    for raw in rules_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=>" not in line:
            continue
        canonical, rhs = line.split("=>", 1)
        canonical = canonical.strip()
        variants = [v.strip() for v in rhs.split("|") if v.strip()]
        if canonical and variants:
            rules.append((canonical, variants))
    return rules


def apply_terminology_rules(text: str, rules: list[tuple[str, list[str]]]) -> str:
    """Apply canonical terminology replacements."""
    out = text
    for canonical, variants in rules:
        for variant in variants:
            pattern = re.compile(re.escape(variant), re.IGNORECASE)
            out = pattern.sub(canonical, out)
    return out


def trim_silence_bounds(
    chunk_audio: np.ndarray,
    sr: int,
    chunk_start: float,
    rms_threshold: float = 0.006,
    frame_sec: float = 0.05,
) -> tuple[float, float]:
    """Refine speech onset and offset within an audio chunk using short-frame RMS energy."""
    n_samples = len(chunk_audio)
    if n_samples == 0 or sr <= 0:
        return chunk_start, chunk_start
    duration = n_samples / sr
    frame_len = max(1, int(frame_sec * sr))
    n_frames = n_samples // frame_len
    if n_frames <= 1:
        return chunk_start, chunk_start + duration

    frames = chunk_audio[: n_frames * frame_len].reshape(n_frames, frame_len)
    rms = np.sqrt(np.mean(frames**2, axis=1))
    active = np.where(rms >= rms_threshold)[0]
    if len(active) == 0:
        return chunk_start, chunk_start + duration

    first_idx = max(0, int(active[0]) - 1)
    last_idx = min(n_frames, int(active[-1]) + 2)
    refined_start = chunk_start + (first_idx * frame_len) / sr
    refined_end = chunk_start + min(duration, (last_idx * frame_len) / sr)
    if refined_end <= refined_start:
        return chunk_start, chunk_start + duration
    return refined_start, refined_end


def split_chunk_into_sentence_segments(
    text: str,
    start_sec: float,
    end_sec: float,
) -> list[dict[str, Any]]:
    """Split a chunk transcript by sentence punctuation and distribute timestamps proportionally."""
    cleaned = text.strip()
    if not cleaned:
        return []

    parts = [
        p.strip()
        for p in re.split(r"(?<=[。！？；.!?;])\s*", cleaned)
        if p.strip()
    ]
    if len(parts) <= 1:
        return [{"start": round(start_sec, 2), "end": round(max(start_sec + 0.1, end_sec), 2), "text": cleaned}]

    total_chars = sum(max(1, len(p)) for p in parts)
    span = max(0.2, end_sec - start_sec)
    cursor = start_sec
    segments: list[dict[str, Any]] = []
    for idx, part in enumerate(parts):
        weight = max(1, len(part)) / total_chars
        seg_end = end_sec if idx == len(parts) - 1 else cursor + span * weight
        segments.append(
            {
                "start": round(cursor, 2),
                "end": round(max(cursor + 0.05, seg_end), 2),
                "text": part,
            }
        )
        cursor = seg_end
    return segments


def transcribe_to_segments(
    audio_path: Path,
    model_id: str,
    language: str | None,
    vocab_context: str,
    rules: list[tuple[str, list[str]]],
    max_chunk_sec: float = 12.0,
) -> list[dict[str, Any]]:
    """Run Qwen3-ASR on an audio file and return timestamped segments."""
    import mlx_qwen3_asr
    import mlx_qwen3_asr.chunking as qwen_chunking
    from mlx_qwen3_asr.audio import SAMPLE_RATE, load_audio_np

    qwen_chunking.MAX_CHUNK_SECONDS = max_chunk_sec
    audio_np = load_audio_np(str(audio_path), sr=SAMPLE_RATE)
    if len(audio_np) == 0:
        return []

    # Check overall RMS energy so pure silence doesn't hallucinate
    overall_rms = float(np.sqrt(np.mean(audio_np**2)))
    if overall_rms < 1e-4:
        return []

    lang_arg = None
    if language:
        norm = language.strip().lower()
        if norm in ("zh", "zh-cn", "zh-hans", "chinese"):
            lang_arg = "Chinese"
        elif norm in ("en", "english"):
            lang_arg = "English"
        elif norm in ("ja", "japanese"):
            lang_arg = "Japanese"
        elif norm in ("ko", "korean"):
            lang_arg = "Korean"
        elif norm != "auto":
            lang_arg = language

    res = mlx_qwen3_asr.transcribe(
        audio_np,
        model=model_id,
        context=vocab_context,
        language=lang_arg,
        return_chunks=True,
        verbose=False,
    )

    chunks = res.chunks or [
        {
            "text": res.text,
            "start": 0.0,
            "end": float(len(audio_np) / SAMPLE_RATE),
        }
    ]

    segments: list[dict[str, Any]] = []
    for item in chunks:
        raw_text = (item.get("text") or "").strip()
        if not raw_text:
            continue
        normalized_text = apply_terminology_rules(raw_text, rules)
        c_start = float(item.get("start", 0.0))
        c_end = float(item.get("end", c_start))
        s_idx = max(0, int(c_start * SAMPLE_RATE))
        e_idx = min(len(audio_np), int(c_end * SAMPLE_RATE))
        sub_audio = audio_np[s_idx:e_idx]
        refined_start, refined_end = trim_silence_bounds(sub_audio, SAMPLE_RATE, c_start)
        segments.extend(
            split_chunk_into_sentence_segments(normalized_text, refined_start, refined_end)
        )

    return segments


def main() -> int:
    parser = argparse.ArgumentParser(description="使用本地 Qwen3-ASR (MLX) 引擎转录音频")
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"HuggingFace 模型 ID（默认：{DEFAULT_MODEL}）",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=None,
        help="指定单个音频文件（.wav / .m4a / .mp3）",
    )
    parser.add_argument(
        "--language",
        default="zh",
        help="识别语言（默认 zh -> Chinese，可设 auto 自动检测）",
    )
    parser.add_argument(
        "--vocab",
        type=Path,
        default=DEFAULT_VOCAB,
        help="词表文件路径",
    )
    parser.add_argument(
        "--rules",
        type=Path,
        default=DEFAULT_RULES,
        help="术语替换规则路径",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="向 stdout 输出 JSON 格式的分段时间戳（供 MeetingTranscriber.app 原生调用）",
    )
    parser.add_argument(
        "--check-model",
        action="store_true",
        help="仅检查/预热模型并返回 JSON 状态",
    )
    parser.add_argument(
        "--latest",
        type=int,
        default=1,
        help="未指定 --input 时，重跑最近 N 条录音（默认 1）",
    )
    args = parser.parse_args()

    if args.check_model:
        import mlx_qwen3_asr

        mlx_qwen3_asr.load_model(args.model)
        print(json.dumps({"status": "loaded", "model": args.model}, ensure_ascii=False))
        return 0

    vocab_context = load_vocab_context(args.vocab)
    rules = load_terminology_rules(args.rules)

    if args.input:
        if not args.input.exists():
            if args.json:
                print(json.dumps({"error": f"File not found: {args.input}"}, ensure_ascii=False))
            else:
                print(f"[ERROR] 找不到音频文件: {args.input}", file=sys.stderr)
            return 1

        segments = transcribe_to_segments(
            audio_path=args.input,
            model_id=args.model,
            language=args.language,
            vocab_context=vocab_context,
            rules=rules,
        )
        if args.json:
            print(json.dumps({"segments": segments}, ensure_ascii=False))
            return 0

        full_text = "\n".join(
            f"[{int(s['start']//60):02d}:{int(s['start']%60):02d}] {s['text']}"
            for s in segments
        )
        out_path = args.input.with_suffix(".qwen3.txt")
        header = (
            f"# Qwen3-ASR Transcript ({args.model})\n"
            f"# Source: {args.input.name}\n"
            f"# Transcribed At: {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
        )
        out_path.write_text(header + full_text + "\n", encoding="utf-8")
        print(f"[OK] 已生成: {out_path}")
        return 0

    app_support_rec = (
        Path.home()
        / "Library"
        / "Application Support"
        / "MeetingTranscriber"
        / "recordings"
    )
    candidates: list[Path] = []
    for folder in [DEFAULT_OUTPUTS, app_support_rec]:
        if folder.exists():
            candidates.extend(sorted(folder.glob("*.wav"), key=lambda p: p.stat().st_mtime, reverse=True))
    if not candidates:
        print("[INFO] 暂无可转录的 .wav 录音文件。")
        return 0

    targets = candidates[: args.latest]
    for wav in targets:
        print(f"[RUN] 正在使用 {args.model} 转录: {wav.name} ...")
        segments = transcribe_to_segments(
            audio_path=wav,
            model_id=args.model,
            language=args.language,
            vocab_context=vocab_context,
            rules=rules,
        )
        full_text = "\n".join(
            f"[{int(s['start']//60):02d}:{int(s['start']%60):02d}] {s['text']}"
            for s in segments
        )
        out_path = DEFAULT_OUTPUTS / f"{wav.stem}.qwen3.txt"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        header = (
            f"# Qwen3-ASR Transcript ({args.model})\n"
            f"# Source: {wav.name}\n"
            f"# Transcribed At: {dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
        )
        out_path.write_text(header + full_text + "\n", encoding="utf-8")
        print(f"[OK] 已生成: {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
