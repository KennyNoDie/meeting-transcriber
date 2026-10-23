# 工作流与文稿操作提示词合同（借鉴 Auday 架构）

本文档定义 `meeting-transcriber-timeline` 的 6 类核心工作流、窄检索执行顺序与结构化输出提示词模板。通过环境变量 `MEETING_TRANSCRIBER_WORKSPACE`（默认 `~/Documents/MeetingTranscriber`）定位项目目录。

---

## §1 每日时间线复盘（Daily / Weekly Reflection）

**适用场景**：用户问「今天录了什么」「帮我复盘今天的会议时间线」「总结一下今天开会做了什么」。

### 执行步骤
1. 检查运行态与截止时间：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" status
   ```
   若 `watchState` 为 `"recording"`，在结论首行注明「当前仍有一场会议正在录制中，以下复盘截至 `checkedAt` 已落盘文稿」。
2. 聚合当日时间线索引稿：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" build-timeline --date YYYY-MM-DD
   ```
3. 读取生成的 `outputs/daily_timelines/YYYY-MM-DD_raw_timeline.md`，按下方复盘提示词合同提炼交付。

### 提炼提示词合同（Daily Timeline Synthesizer）
- **角色与目标**：将全天多段静默录音转写稿合并为一份**按时间轴排列、去水词、结论先行、带原话溯源的《每日会议时间线与决策账》**。
- **硬性纪律**：
  1. **中英术语对齐**：基于业务词表（`config/vocabulary.txt`）自动修正同音错字，无法确认专有名词时保留原词并加 `[?存疑: 原词]`。
  2. **说话人隔离**：严格区分 `[Me]`（本机麦克风，我方表态/承诺）与 `[Remote / Speaker X]`（远端参会人）。未确认真实姓名前保留标签，不瞎猜人名。
  3. **跨场串联**：同一议题在上下午多场讨论中出现时，指出方案演进或口径变化，而非孤立罗列。
- **输出结构**：
  ```markdown
  # YYYY-MM-DD 语音时间线复盘（截至 HH:MM，共 N 场录音）

  ## 一、今日核心脉络（3~5 条一句话结论）
  - **[议题 A]**：最终拍板结论（对应 HH:MM 场次）。

  ## 二、分时段会议时间线
  ### 🕒 [HH:MM - HH:MM] 会议主题（基于内容重命名，附源文件 `slug`）
  - **核心结论**：1~3 条定论。
  - **关键交锋与依据**：为什么这么定？放弃了什么备选方案？
  - **高光原话（Highlights）**：
    - `[MM:SS] [Me]`：「原话关键句」
    - `[MM:SS] [Remote]`：「原话关键句」

  ## 三、今日待办账单（承诺 vs 建议分栏）
  ### 1. 原话明确承诺（Explicit Commitments）
  - [ ] **[我方待办]** 具体动作 —— 截止时间（溯源：`slug` `[MM:SS] [Me]`）
  - [ ] **[对方承诺]** 具体动作 —— 负责人/角色（溯源：`slug` `[MM:SS] [Remote]`）

  ### 2. Agent 建议跟进（Suggested Next Steps）
  - [ ] **[建议动作]** 针对未决问题或潜在风险的跟进建议（标注：`[Agent 推断]`）
  ```

---

## §2 查找某次讨论、原话或拍板结论（Find a Statement or Decision）

**适用场景**：用户问「刚才/昨天谁提到了 XX」「关于某方案当时是怎么定的」「找一下我答应什么时候交付」。

### 执行步骤
1. 先用窄检索定位命中记录与时间窗口，不要全量读文件：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" search "关键词" --date YYYY-MM-DD --context-lines 3
   ```
2. 针对命中的 `slug` 与时间戳区间，读取上下文切片（例如前后扩展 2~3 分钟）：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" read <slug> --start 05:00 --end 10:00
   ```
3. 若用户需要核对「我方原话」还是「对方原话」，用 `--speaker Me` 或 `--speaker Remote` 过滤。

### 输出要求
- 首句直接给出查到的拍板结论或原话核心意思。
- 附上精确溯源：日期、场次 `slug`、时间戳 `[MM:SS - MM:SS]`、说话人标签（`[Me]` / `[Remote]`）及逐字原话引用。
- 若存在多处讨论且前后口径有修正，按时间先后列出并指明最终生效版本。

---

## §3 项目简报与交接单（Project Brief or Handoff）

**适用场景**：用户刚开完一场长会或多场专题讨论，要求「把刚才那场会整理成纪要/交接单」「整理成能发给团队或写进文档的方案摘要」。

### 执行步骤
1. 列出当日记录定位目标场次 `slug`：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" list --date YYYY-MM-DD
   ```
2. 读取目标场次完整逐字稿：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" read <slug>
   ```

### 提炼提示词合同（5 栏工程交接结构）
将口语化讨论重组为无废话的工程交接结构，每一项后附 `[MM:SS]` 时间戳溯源：
1. **已拍板决策（Decisions）**：明确敲定的机制、状态机、UI 规则、配置数值或实验方案。
2. **决策依据与取舍（Reasons & Trade-offs）**：为什么选 A 不选 B（如性能开销、用户理解成本、研发排期限制）。
3. **明确承诺（Explicit Commitments）**：各方在会上亲口接下的交付物与时间点。
4. **跨模块依赖（Dependencies）**：依赖客户端、后端接口、数据表或外部团队配合的事项。
5. **未决问题与阻塞项（Unresolved Questions）**：会上提出但未定论、需会后拉群或查数据确认的悬念。

---

## §4 待办与跟进提取（Follow-ups：承诺 vs 建议严格分栏）

**适用场景**：用户问「从今天会议里提取待办」「我今天开会答应了别人什么事」。

### 核心规则（借鉴 Auday 归属纪律）
- **绝不混淆「原话承诺」与「AI 脑补建议」**：严格拆成两个独立分组：
  1. **原话明确承诺（Explicit Commitments）**：必须有 `[Me]` 或 `[Remote]` 的原话支撑；仅在原话明确提到负责人或期限时才填写对应字段，否则标 `未指定`。
  2. **Agent 建议跟进（Suggested Next Steps）**：会上悬而未决、风险未闭环、按业务逻辑应当补充验证的动作，显式标注 `[Agent 建议]`。
- **默认本地交付**：默认在对话或本地 Markdown 中输出待办清单；只有当用户明确下达写入外部任务系统的指令时才执行外部写入。

---

## §5 关键原话存疑与原声重转（Disputed Wording / Audio Re-analysis）

**适用场景**：某段逐字稿因为多人抢话、中英混杂或背景音导致识别含糊，或者某场历史录音当时只留了 `.wav` 没有 `.txt`，需要用 `Qwen3-ASR-1.7B` 深度重转。

### 执行步骤
1. 检查目标场次的音频文件列表（区分合成轨 `.wav`、远端轨 `_app.wav`、本机麦克风轨 `_mic.wav`）：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" list --limit 10
   ```
2. 运行非破坏性重转写（可针对混合轨，也可专门针对 `_mic.wav` 只重转本机原话）：
   ```bash
   python3 "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/timeline_cli.py" retranscribe <slug或wav路径> --speaker Me
   ```
3. 读取新生成的 `<slug>.qwen3.txt` 衍生件，与原 `.txt` 对比核实存疑字词。

---

## §6 业务热词与同音纠错进化（Vocabulary & Terminology Feedback Loop）

**适用场景**：用户在审阅时间线或纪要时指出「XX 词识别错了，应该是 YY」，或出现了新的业务专有名词。

### 执行步骤
1. **标准业务热词**：将正确词条按分类写入 `config/vocabulary.txt`。
2. **高频同音错字确定性替换**：若某个词被固定听错，以 `标准词 => 误识词1 | 误识词2` 格式追加到 `config/terminology_rules.txt`（`qwen3_asr_transcribe.py` 会在每次转录落盘前自动执行确定性纠错）。
3. **同步至 App 配置**：更新词表后运行：
   ```bash
   swift "${MEETING_TRANSCRIBER_WORKSPACE:-$HOME/Documents/MeetingTranscriber}/scripts/apply_config.swift"
   ```
