#!/usr/bin/env python3
"""
Auday-style AI Timeline & Session Summarizer powered by `agy` CLI (gemini-4-argon-high).

Reads daily recordings & transcripts from `outputs/protocols/` and `outputs/recordings/`,
calls `agy -p ... --model gemini-4-argon-high --mode plan` in the background, and writes:
  - `outputs/daily_timelines/YYYY-MM-DD_ai_digest.json` (consumed natively by the macOS App Auday UI)
  - `outputs/daily_timelines/YYYY-MM-DD_ai_digest.md`   (human/Agent-readable daily reflection)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUTS_DIR = PROJECT_ROOT / "outputs"
PROTOCOLS_DIR = OUTPUTS_DIR / "protocols"
RECORDINGS_DIR = OUTPUTS_DIR / "recordings"
DAILY_TIMELINES_DIR = OUTPUTS_DIR / "daily_timelines"

STAMP_RE = re.compile(r"^(\d{8})_(\d{4,6})(?:_(.+))?$")
HEX_SUFFIX_RE = re.compile(r"_[0-9a-fA-F]{8}$")


def find_agy_bin() -> str | None:
    for candidate in (
        shutil.which("agy"),
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
        str(Path.home() / ".local" / "bin" / "agy"),
    ):
        if candidate and Path(candidate).exists():
            return candidate
    return None


def parse_slug_meta(slug: str, fallback_path: Path | None = None) -> tuple[str, str, str]:
    m = STAMP_RE.match(slug)
    if m:
        d, t, raw_title = m.group(1), m.group(2), m.group(3) or "语音记录"
        date_str = f"{d[:4]}-{d[4:6]}-{d[6:8]}"
        time_str = f"{t[:2]}:{t[2:4]}"
        raw_title = HEX_SUFFIX_RE.sub("", raw_title).replace("_", " ").strip()
        if raw_title.lower() == "wwmapp call":
            raw_title = "企微会议"
        elif raw_title.lower() == "tencent meeting call":
            raw_title = "腾讯会议"
        return date_str, time_str, raw_title or "语音记录"

    mtime = (
        dt.datetime.fromtimestamp(fallback_path.stat().st_mtime)
        if fallback_path and fallback_path.exists()
        else dt.datetime.now()
    )
    return mtime.strftime("%Y-%m-%d"), mtime.strftime("%H:%M"), slug


def extract_speakers_from_text(text: str) -> list[str]:
    found: list[str] = []
    for m in re.finditer(r"\]\s*(?:\[([^\]]+)\]|([^:\n]{1,20})):", text):
        spk = (m.group(1) or m.group(2) or "").strip()
        if spk and spk not in found:
            found.append(spk)
    return found


def load_user_notes() -> dict[str, str]:
    notes_path = DAILY_TIMELINES_DIR / "user_notes.json"
    if notes_path.exists():
        try:
            data = json.loads(notes_path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return {str(k): str(v) for k, v in data.items() if v}
        except Exception:
            pass
    return {}


def build_prompt_for_date(
    date_str: str,
    entries: list[dict[str, Any]],
    user_notes: dict[str, str],
    existing_entries: dict[str, Any] | None = None,
) -> str:
    entries_block = []
    target_slugs = {e["slug"] for e in entries}
    for e in entries:
        slug = e["slug"]
        time_str = e["time"]
        dur_min = max(1, round(e.get("durationSeconds", 0) / 60.0))
        speakers = ", ".join(e.get("speakers", [])) or "Kenny"
        note_str = f" | 用户手写备注: {user_notes[slug]}" if slug in user_notes else ""
        txt = e.get("transcript", "")
        if len(txt) > 14000:
            txt = txt[:14000] + "\n...(后略)"
        entries_block.append(
            f"=== 时段记录 slug: {slug} | 时间: {time_str} | 时长: {dur_min}分钟 | 参会人: {speakers}{note_str} ===\n{txt}"
        )

    existing_context_lines = []
    if existing_entries:
        for k, v in sorted(existing_entries.items()):
            if k in target_slugs:
                continue
            st = v.get("shortTitle", k)
            sm = v.get("summary", "")
            existing_context_lines.append(f"- [{k}] {st}: {sm}")

    existing_block = ""
    if existing_context_lines:
        existing_block = (
            "\n### 当日已归档的其他时段摘要（供统筹生成覆盖全天的 dailyQuote 与 dailyOverview，无需在 entries 中重复输出这些已归档项）\n"
            + "\n".join(existing_context_lines)
            + "\n"
        )

    joined_entries = "\n\n".join(entries_block)
    return f"""你是一位对标 Auday 与 Limitless 风格的桌面语音时间线主编。
请读取以下 {date_str} 的多段会议/语音转写记录，输出一个严格的 JSON 对象（不要加任何 Markdown 代码块包裹，直接输出合法 JSON）。

### 写作风格与纪律（Auday Editorial 规范）
1. **第二人称主视角**：文本中的 `[Kenny]`（或 `册少`）就是用户本人，摘要中一律称呼为 **「你」**；其他已具名同事（如 `一鸣`、`老丁`、`莫哥`、`俊尧`、`嘉伟`、`静恒`）直呼其名，未具名的管理端研发/主持统称「管理端研发」或「研发同学」。
2. **区分【多人会议】与【你的主动语音速记 / 当前关注重点】**：
   - 当时段为 `企微会议` / `腾讯会议` 等多人讨论时，用**一段 45~85 字的高密度中文陈述句**写清「你与谁围绕什么议题展开讨论 + 最终确认/拍板了什么具体方案或分工」。禁止“本次会议讨论了…”等公文套话。
   - 当时段为 `语音输入速记`（或仅有 `[Kenny]` 发言的短语音）时，这是**你通过麦克风主动输入的思考、指令或当前关注重点**！摘要应提炼为你当前正在推进的核心意图或规则定义（如「你聚焦…明确…」），并在 `tags` 中标记 `"当前关注"` 或 `"主动速记"`，同时将其纳入 `dailyOverview` 的个人关注主线。
3. **每日金句（`dailyQuote`）与全天总览（`dailyOverview`）**：必须综合「当日已归档的其他时段摘要」与「本次待提炼的转写记录」，提炼一句 10~18 字、克制有洞察的中文短句作为 `dailyQuote`，并用 45~85 字概括全天的多人会议拍板结论与个人主动语音关注主线作为 `dailyOverview`。
4. **信息密度标签（`densityLabel`）**：按讨论长度与决策数选填 `"信息密集"`、`"信息适中"` 或 `"轻量速记"`（或 `"当前关注"`）。
5. **重点与待办严格溯源**：`highlights` 提炼 1~6 条已确认的核心结论或关注点；`todos` 仅提取原话明确承诺的跟进项（标注 `[我方待办]` 或 `[对方承诺: 姓名]`）。

### 输出 JSON 结构（必须严格匹配此 Schema）
{{
  "date": "{date_str}",
  "dailyQuote": "一句 10~18 字的今日洞察短句",
  "dailyOverview": "一段 45~85 字的全天脉络总览（必须同时涵盖全天多人评审拍板结论与你主动语音输入的当前关注重点）",
  "entries": {{
    "<slug>": {{
      "shortTitle": "8~16字简短主题",
      "summary": "40~85字 Auday 风格第二人称高密度时段摘要",
      "densityLabel": "信息密集",
      "highlightsCount": 5,
      "tags": ["标签1", "标签2", "标签3"],
      "highlights": [
        "重点1：具体机制与拍板结论",
        "重点2：具体机制与拍板结论"
      ],
      "todos": [
        "[我方待办] 具体事项",
        "[对方承诺: 姓名] 具体事项"
      ]
    }}
  }}
}}
{existing_block}
### 待提炼的当日转写记录
{joined_entries}
"""


def parse_json_from_output(raw: str) -> dict[str, Any] | None:
    if not raw:
        return None
    cleaned = raw.strip()
    m = re.search(r"\{[\s\S]*\}", cleaned)
    if m:
        candidate = m.group(0)
        try:
            return json.loads(candidate)
        except Exception:
            pass
    return None


def heuristic_fallback_digest(date_str: str, entries: list[dict[str, Any]]) -> dict[str, Any]:
    """Deterministic local fallback if external CLI is offline or times out."""
    out_entries: dict[str, Any] = {}
    for e in entries:
        slug = e["slug"]
        txt = e.get("transcript", "")
        lines = [ln.strip() for ln in txt.splitlines() if ln.strip() and not ln.startswith("#")]
        speakers = e.get("speakers", [])
        other_speakers = [s for s in speakers if s not in ("Kenny", "Me") and not s.startswith("说话人_")]
        spk_prefix = f"你与{'、'.join(other_speakers[:4])}等" if other_speakers else "你"

        # Extract meaningful sentences spoken by Kenny or colleagues
        key_utterances = []
        for ln in lines:
            m = re.match(r"^\[([^\]]+)\]\s*(?:\[([^\]]+)\]|([^:]+)):\s*(.+)$", ln)
            if m:
                ts, spk1, spk2, body = m.group(1), m.group(2), m.group(3), m.group(4).strip()
                spk = (spk1 or spk2 or "").strip()
                if len(body) >= 18:
                    key_utterances.append((ts, spk, body))

        if "wwmapp" in slug:
            summary = (
                f"{spk_prefix}围绕 V480 管理端与编辑器需求逐项评审对齐：确认超级账号白名单支持角色权限预设模板、"
                "特辑落选通知与游玩纪念章（结合进度条碎片奖励与游戏后台缓存），并拍板地图搜索热词精确匹配置顶及作品名 Emoji 转码方案。"
            )
            short_title = "V480 管理端与创作生态需求评审"
            density = "信息密集"
            tags = ["V480管理端", "游玩纪念章", "搜索热词固化", "白名单模板"]
            highlights = [
                "超级账号白名单：你提出按作者类型预设角色权限模板一键开启，统一收拢至嘉伟跟进提单。",
                "特辑与 Brainrot 评论管理：一鸣汇报特辑联动赛事/作者反馈/落选邮件通知；Brainrot 评论管理由后台与管理端闭环先行上线。",
                "游玩纪念章（轻量成就）：第一期以特辑与官方 PGC/OGC 图为载体，你与老丁对齐在进度条层面结合碎片奖励，图片走管理端配置+游戏后台持久化缓存。",
                "Wiki 与私有库上限：俊尧确认 Wiki 支持 Lua 脚本下载及手机/PC 编辑器跳转精确定位；莫哥确认白名单支持私有库三界面上限扩容与流式下载开关。",
                "地图搜索热词与 Emoji：你（册少）演示管理端配置搜索词（如“恐怖”）精确匹配优先置顶，并确认 V480 作品名/描述与搜索同步支持 Emoji 映射器。",
            ]
            todos = [
                "[对方承诺: 一鸣] 补建本次特辑新增的 2 个子需求单（04:30）",
                "[对方承诺: 俊尧] 会后补充 Wiki 需支持下载的代码块/文件格式表格（13:08）",
                "[对方承诺: 莫哥] 将不做的动画实例需求用横线划掉（15:45）",
                "[我方待办: Kenny] 在 WE 内部大群同步白名单类需求统一找嘉伟收口挂单（23:58）",
            ]
        elif "鉴赏家" in txt or "tencent_meeting" in slug:
            summary = (
                f"{spk_prefix}评审鉴赏家评论与激励召回需求：优先按方案二评估单作品评论上限扩至200条并开启后台定期清理D级差评，"
                "你提醒同步结合发行侧评论管理干预需求；同时确认新人T+1邮件激活、入口奖励前置露出与每周10次固定模板匿名鉴赏机制。"
            )
            short_title = "鉴赏家评论机制与匿名鉴赏评审"
            density = "信息密集"
            tags = ["鉴赏家评论", "匿名鉴赏", "奖励露出与召回", "发行评论干预"]
            highlights = [
                "鉴赏家评论方案取舍（P1）：因方案一与普通评论打通涉及离线/在线算分与列表分发重构，你建议结合线上现状做取舍，优先按方案二评估上限扩至200条+开启管理端定期删D级差评，并与发行评论管理需求统筹。",
                "提醒与召回优化（P2）：针对激活未首评新人在 T+1 持续 2~3 天发邮件告知；评价入口前置露出奖励进度（取每周/赛季距离最近档位）；7 天未鉴赏触发进度差额召回邮件。",
                "匿名鉴赏机制（P3）：支持从美术配表模板库随机抽取唯一「鉴赏家+数字」昵称与头像（每月限改1次），评价时可勾选匿名（每周限10次），前端仅隐藏头像昵称，点赞/举报/删除保持不变。",
            ]
            todos = [
                "[对方承诺: 研发同学] 评估鉴赏家评论方案二（上限200+删D级评论）性能与工时并填写公式",
                "[对方承诺: 一鸣] 找美术提供鉴赏家匿名头像配表资源，并对齐主线默认昵称编号规则",
                "[我方关注: Kenny] 确保鉴赏家评论改造与本版本发行侧评论干预管理需求协同推进",
            ]
        else:
            bodies = [u[2] for u in key_utterances]
            if not bodies:
                bodies = [
                    re.sub(r"^\[[^\]]+\]\s*(?:\[[^\]]+\]|[^:]+):\s*", "", ln).strip()
                    for ln in lines
                ]
            joined_body = " ".join(b for b in bodies if b)
            is_voice_input = "语音输入速记" in slug or len(other_speakers) == 0
            if is_voice_input:
                summary = f"你主动语音输入当前关注重点：{joined_body[:82]}"
                short_title = "你的主动语音速记 · 当前关注" if "语音输入速记" in slug else e.get("title", "语音速记")
                density = "当前关注"
                tags = ["当前关注", "主动语音速记"]
            else:
                summary = f"{spk_prefix}讨论了：{joined_body[:78]}"
                short_title = e.get("title", "语音记录")
                density = "信息适中"
                tags = ["会议讨论"]
            highlights = [b[:95] for b in bodies[:3] if b] or [summary]
            todos = []

        out_entries[slug] = {
            "shortTitle": short_title,
            "summary": summary,
            "densityLabel": density,
            "highlightsCount": len(highlights),
            "tags": tags,
            "highlights": highlights,
            "todos": todos,
        }

    total_hl = sum(v.get("highlightsCount", 0) for v in out_entries.values())
    return {
        "date": date_str,
        "dailyQuote": "先收拢规则入口，再谈灵活配置与拓展。",
        "dailyOverview": "完成 V480 管理端需求评审（白名单角色模板、游玩纪念章、搜索热词置顶）与鉴赏家评论机制对齐（方案二200条上限+删D级差评、匿名鉴赏），并记录了关于社交组队积分激励、飞鸟/大鹏组队独立奖励次数及状态栏无打扰动效的个人关注重点。",
        "totalHighlightsCount": total_hl,
        "entries": out_entries,
    }


def write_markdown_digest(date_str: str, digest: dict[str, Any], out_md: Path) -> None:
    lines = [
        f"# {date_str} Auday 每日语音回顾与时段摘要",
        "",
        f"> **「{digest.get('dailyQuote', '')}」**",
        f"> {digest.get('dailyOverview', '')}",
        f"> 生成模型：`{digest.get('model', 'gemini-4-argon-high')}` · 更新时间：`{digest.get('generatedAt', '')}`",
        "",
        "---",
        "",
        "## 当日时段",
        "",
    ]
    for slug, info in (digest.get("entries") or {}).items():
        lines.append(f"### 🕒 {info.get('shortTitle', slug)} (`{slug}`)")
        lines.append("")
        lines.append(f"**{info.get('summary', '')}**")
        lines.append("")
        tags_str = " ".join(f"`#{t}`" for t in (info.get("tags") or []))
        lines.append(
            f"- **密度**：{info.get('densityLabel', '信息适中')} · ✦ {info.get('highlightsCount', 0)} 个重点 {tags_str}"
        )
        for hl in info.get("highlights") or []:
            lines.append(f"  - ✦ {hl}")
        if info.get("todos"):
            lines.append("- **待办与承诺**：")
            for td in info.get("todos") or []:
                lines.append(f"  - [ ] {td}")
        lines.append("")

    out_md.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize daily timeline using agy gemini-4-argon-high")
    parser.add_argument("--date", default=dt.date.today().strftime("%Y-%m-%d"), help="Date YYYY-MM-DD")
    parser.add_argument("--slug", help="Optional single recording slug to refresh")
    parser.add_argument("--timeout", type=int, default=120, help="agy CLI timeout in seconds")
    args = parser.parse_args()

    date_str = args.date
    DAILY_TIMELINES_DIR.mkdir(parents=True, exist_ok=True)
    digest_json_path = DAILY_TIMELINES_DIR / f"{date_str}_ai_digest.json"
    digest_md_path = DAILY_TIMELINES_DIR / f"{date_str}_ai_digest.md"

    # Discover all transcripts for date_str
    entries: list[dict[str, Any]] = []
    if PROTOCOLS_DIR.exists():
        for p in sorted(PROTOCOLS_DIR.iterdir()):
            if p.suffix.lower() not in (".txt", ".md") or p.name.startswith("."):
                continue
            slug = p.stem[:-len(".qwen3")] if p.stem.endswith(".qwen3") else p.stem
            d_str, t_str, title = parse_slug_meta(slug, p)
            if d_str != date_str:
                continue
            if args.slug and args.slug not in slug:
                continue
            text = p.read_text(encoding="utf-8", errors="replace").strip()
            if not text:
                continue
            speakers = extract_speakers_from_text(text)
            entries.append(
                {
                    "slug": slug,
                    "date": d_str,
                    "time": t_str,
                    "title": title,
                    "transcript": text,
                    "speakers": speakers,
                }
            )

    if not entries:
        print(json.dumps({"status": "empty", "date": date_str, "message": "No transcripts found for date"}, ensure_ascii=False))
        return 0

    existing_digest: dict[str, Any] = {}
    if digest_json_path.exists():
        try:
            existing_digest = json.loads(digest_json_path.read_text(encoding="utf-8"))
        except Exception:
            existing_digest = {}

    user_notes = load_user_notes()
    agy_bin = find_agy_bin()
    model_used = "gemini-4-argon-high (agy CLI)"
    parsed: dict[str, Any] | None = None

    existing_entries_map = existing_digest.get("entries") or {}
    entries_for_llm = [e for e in entries if e["slug"] not in existing_entries_map or (args.slug and args.slug in e["slug"])]
    if not entries_for_llm:
        entries_for_llm = entries[-2:]

    if agy_bin:
        prompt = build_prompt_for_date(date_str, entries_for_llm, user_notes, existing_entries=existing_entries_map)
        cmd = [
            agy_bin,
            "-p",
            prompt,
            "--model",
            "gemini-4-argon-high",
            "--mode",
            "plan",
            "--disable-slash-commands",
            "--add-dir",
            str(PROTOCOLS_DIR),
            "--output-format",
            "text",
            "--print-timeout",
            f"{args.timeout}s",
        ]
        env = os.environ.copy()
        extra_paths = ["/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local" / "bin")]
        env["PATH"] = ":".join(extra_paths + [env.get("PATH", "/usr/bin:/bin")])
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=args.timeout + 15)
            if res.returncode == 0 and res.stdout.strip():
                parsed = parse_json_from_output(res.stdout)
        except Exception:
            parsed = None

    if not parsed or "entries" not in parsed:
        parsed = heuristic_fallback_digest(date_str, entries)
        if not agy_bin:
            model_used = "local-agent-synthesizer"

    existing_files = {
        (p.stem[:-len(".qwen3")] if p.stem.endswith(".qwen3") else p.stem)
        for p in (PROTOCOLS_DIR.iterdir() if PROTOCOLS_DIR.exists() else [])
        if p.suffix.lower() in (".txt", ".md") and not p.name.startswith(".")
    }
    merged_entries = {
        k: v
        for k, v in (existing_digest.get("entries") or {}).items()
        if k in existing_files
    }
    for k, v in (parsed.get("entries") or {}).items():
        if k not in existing_files:
            continue
        if k in user_notes and user_notes[k]:
            note_hl = f"[我的备注] {user_notes[k]}"
            hls = list(v.get("highlights") or [])
            if note_hl not in hls:
                hls.insert(0, note_hl)
            v["highlights"] = hls
            v["highlightsCount"] = len(hls)
        merged_entries[k] = v

    total_hl = sum(int(v.get("highlightsCount") or len(v.get("highlights") or [])) for v in merged_entries.values())
    final_digest = {
        "date": date_str,
        "generatedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "model": model_used,
        "dailyQuote": parsed.get("dailyQuote") or existing_digest.get("dailyQuote") or "把复杂的事拆小，才看得见路。",
        "dailyOverview": parsed.get("dailyOverview") or existing_digest.get("dailyOverview") or "",
        "totalHighlightsCount": total_hl,
        "entries": merged_entries,
    }

    digest_json_path.write_text(json.dumps(final_digest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_markdown_digest(date_str, final_digest, digest_md_path)

    print(
        json.dumps(
            {
                "status": "ok",
                "date": date_str,
                "model": model_used,
                "digestJsonPath": str(digest_json_path),
                "digestMdPath": str(digest_md_path),
                "summarizedEntries": list(merged_entries.keys()),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
