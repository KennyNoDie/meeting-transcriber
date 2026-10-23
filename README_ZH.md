# Meeting Transcriber 中文增强版 · 原生 Qwen3-ASR 1.7B + 每日时间线 + Agent Skill

> 基于 [pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber) 深度定制的 **macOS 全天后台静默双轨录音、本地 `Qwen3-ASR-1.7B` (MLX) 语音转写、可视化录音时间线与桌面 Agent 上下文工作流（Skill）** 开源增强版。

---

## 一、本仓库相对原版的核心差异化升级

| 维度 | 原版 `pasrom/meeting-transcriber` | **本仓库增强版 (`KennyNoDie/meeting-transcriber`)** |
| :--- | :--- | :--- |
| **1. 全中文界面汉化与状态栏反馈优化** | 全英文界面；当参会人安静听会超过 90 秒不说话时，状态栏图标上半截会误报亮红灯 | **全中文菜单栏与设置面板**；修复「安静听会 90 秒误报麦克风静音红灯」问题（仅在真实设备故障或双通道死寂时告警） |
| **2. 原生集成 `Qwen/Qwen3-ASR-1.7B` (MLX)** | 仅支持 WhisperKit / Parakeet（对中英混杂与专业术语识别率有限） | 原生新增 **`Qwen3-ASR 1.7B (阿里千问 · 本地 MLX)`** 引擎，支持注入 `config/vocabulary.txt` 业务热词偏置与 `terminology_rules.txt` 确定性同音纠错，并与 `FluidAudio` 声纹分离无缝拼装 |
| **3. 国内办公软件无感自动监听** | 仅预设 Teams / Zoom / Webex | 原生支持 **企业微信（含独立会议子包 `com.tencent.wwmapp`）**、**微信语音/视频**、**腾讯会议 (`wemeet`)**、飞书与网页会议的麦克风占用检测与自动双轨开录 |
| **4. 录音 × 时间线可视化面板 (`⌘T`)** | 无内置时间线浏览与回放界面 | 设置首屏新增 **「录音 × 时间线」** 面板：按日期筛选、内嵌播放原声、展开/复制带时间戳逐字稿、一键 `Qwen3-ASR` 重转、一键生成每日时间线汇总 |
| **5. 「单次零提示词 → 晚间 Agent 时间线复盘」机制** | 每次录音结束强制跑单场 LLM 生成协议 | 默认单次录音结束**零提示词静默落盘** `[MM:SS] [Speaker]` 高保真逐字稿；晚间或次日通过 `timeline_cli.py` 与内置 Agent Skill 汇总全天时间线与行动账本 |
| **6. 内置 `meeting-transcriber-timeline` Agent Skill** | 无 Agent Skill 集成 | 借鉴 [auday-skill](https://github.com/666ghj/auday-skill) 窄检索与三层归属隔离，内置可直接安装到 Claude Code / Codex / Antigravity / Cursor 的完整 Skill 与 6 大工作流提示词合同 |

---

## 二、仓库新增目录结构

```text
meeting-transcriber/
├── app/MeetingTranscriber/Sources/
│   ├── Qwen3ASREngine.swift                  # 原生 Qwen3-ASR 1.7B (Apple Silicon MLX) 转写引擎实现
│   ├── Settings/TimelineSettingsView.swift   # 「录音 × 时间线」可视化浏览、内嵌播放与一键汇总面板
│   ├── ChannelHealthController.swift         # 优化状态栏声道健康指示（安静听会不再误报上半截红灯）
│   └── MicInputDetector.swift                # 新增企业微信会议子包 com.tencent.wwmapp / 微信 / 腾讯会议自动感知
├── config/
│   ├── vocabulary.example.txt                # 注入 Qwen3-ASR Context 的领域高频词表示例
│   └── terminology_rules.example.txt         # ASR 后置确定性同音错字替换规则示例
├── prompts/
│   ├── protocol_prompt.md                    # [可选] 单段对话高保真时间切片 Prompt
│   └── daily_timeline_summary.md             # [核心] 每日全景语音时间线与双向承诺账本复盘 Prompt
├── scripts/
│   ├── apply_config.swift                    # 一键写入 UserDefaults（绑定 qwen3ASR、中文化配置与输出目录）
│   ├── qwen3_asr_transcribe.py               # Qwen3-ASR-1.7B MLX 桥接脚本（含 RMS 静音边界精修与分句时间戳）
│   ├── build_daily_timeline.py               # 按日期聚合全天录音与逐字稿碎片，输出时间线汇总包
│   └── timeline_cli.py                       # Auday 风格窄检索 CLI（status / list / search / read / build-timeline / retranscribe）
└── skills/
    └── meeting-transcriber-timeline/         # 开箱即用的桌面 Agent Skill（支持 Claude Code / Codex / Antigravity）
        ├── SKILL.md
        └── references/workflows-and-prompts.md
```

---

## 三、快速开始（Build & Setup）

### 1. 准备 `Qwen3-ASR-1.7B` 本地 MLX Python 环境

```bash
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install mlx-qwen3-asr soundfile numpy

# 预热并校验 Qwen/Qwen3-ASR-1.7B 模型
.venv/bin/python scripts/qwen3_asr_transcribe.py --check-model
```

### 2. 编译并安装中文增强版 `MeetingTranscriber.app`

```bash
cd app/MeetingTranscriber
swift build -c release
cd ../..

# 应用默认配置（自动选中 qwen3ASR 引擎、中文语言、国内会议监听列表与输出目录）
swift scripts/apply_config.swift
```

> **提示（macOS 权限免重复授权技巧）**：使用固定证书（如 Apple Development 证书或本机自签名代码签名证书）对 `/Applications/MeetingTranscriber.app` 进行签名后，后续每次重新编译更新二进制都不会触发 macOS「录屏与系统录音」权限失效。

---

## 四、多麦克风切换与状态栏工作态说明

### 1. 多麦克风热切换兼容
- **跟随系统默认（推荐）**：当你在外接无线麦（如大疆 `Wireless Mic Rx`）、有线/蓝牙耳机与 `MacBook Pro 麦克风` 之间切换时，底层 `MicCaptureHandler` 会监听 `AVAudioEngineConfigurationChange` 并在约 100ms 内完成重采样（48kHz/44.1kHz → 16kHz）与墙钟对齐（`TimelineAnchor`），不丢轨、不错位。
- **固定指定转录麦克风**：可在「设置 → 音频与麦克风 → 录音麦克风来源」中单独指定某一个物理麦克风，不会篡改 macOS 系统默认输入设备。

### 2. 状态栏图标 3 种状态区分
- **平时静默监听（`watching`）**：状态栏 5 根竖条**完全静止**，菜单首行显示 `正在静默监听会议...`。
- **会议录制中（`recording`）**：状态栏 5 根竖条**每 0.4 秒上下跳动**，菜单首行显示绿点 `正在录制会议音频...`。当你在会中安静听别人讲话时，图标保持正常跳动不误报红灯；仅当远端应用无声超过 90 秒（下半截变红）或双端彻底无声（整条变红）时才会预警。
- **会后转写与声纹分离（`transcribing` / `diarizing`）**：5 根竖条变成横向文字行或左右分离动画。

---

## 五、Agent 窄检索 CLI 与 `meeting-transcriber-timeline` Skill

将 `skills/meeting-transcriber-timeline` 软链或复制到你的本地 Agent 技能目录（或通过 `skillshare` 同步），Agent 即可通过 `scripts/timeline_cli.py` 执行 **窄检索（Narrow Retrieval）**：

```bash
# 1. 查看实时录制状态、双轨声道电平与今日归档数
python3 scripts/timeline_cli.py status

# 2. 按日期列出录音与转写元数据索引（不刷屏全文）
python3 scripts/timeline_cli.py list --date 2026-10-23

# 3. 窄检索某次讨论关键词或某人发言片段
python3 scripts/timeline_cli.py search "实验口径" --speaker Me --context-lines 3

# 4. 按时间戳切片读取指定区间 [MM:SS - MM:SS]
python3 scripts/timeline_cli.py read <slug> --start 05:00 --end 10:00

# 5. 一键聚合当日全部录音碎片为时间线汇总包
python3 scripts/timeline_cli.py build-timeline --date 2026-10-23

# 6. 对存疑原声调起 Qwen3-ASR-1.7B 非破坏性重转（生成独立 .qwen3.txt）
python3 scripts/timeline_cli.py retranscribe <slug>
```

### 内置 6 大 Agent 上下文工作流（详见 [`workflows-and-prompts.md`](skills/meeting-transcriber-timeline/references/workflows-and-prompts.md)）
1. **§1 每日时间线复盘（Daily Reflection）**：按时间轴串联全天多场会议，提取核心定论、交锋依据与带 `[MM:SS]` 时间戳的原话高光。
2. **§2 查找某次讨论或拍板（Find a Statement or Decision）**：先搜后读，精准定位原话与拍板演变。
3. **§3 五栏工程交接单（Project Brief & Handoff）**：按「已拍板决策 / 决策依据 / 明确承诺 / 跨模块依赖 / 未决问题」重组。
4. **§4 待办与跟进提取（Follow-ups）**：严格拆分 **「原话明确承诺（Explicit Commitments）」** 与 **「Agent 建议跟进（Suggested Next Steps）」**，杜绝 AI 把顺口闲聊脑补成待办。
5. **§5 争议原话原声重转（Audio Re-analysis）**：不覆写原件，生成 `.qwen3.txt` 衍生件核对细节。
6. **§6 业务热词与同音纠错自进化（Vocabulary Feedback Loop）**：沉淀高频专有名词到 `config/vocabulary.txt` 与 `config/terminology_rules.txt`。
