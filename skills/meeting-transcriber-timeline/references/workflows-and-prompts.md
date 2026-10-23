# 工作流与文稿操作提示词合同（借鉴 Auday 架构）

本文档定义 `meeting-transcriber-timeline` 的 6 类核心工作流、窄检索执行顺序与结构化输出提示词模板。所有路径均以 `${AI_WORK_ROOT}/05_效率工具/meeting-transcriber` 为项目根目录。

---

## §1 每日时间线复盘（Daily / Weekly Reflection）

**适用场景**：用户问「今天录了什么」「帮我复盘今天的会议时间线」「总结一下今天开会做了什么」。

### 执行步骤
1. 检查运行态与截止时间：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" status
   ```
   若 `watchState` 为 `"recording"`，在结论首行注明「当前仍有一场会议正在录制中，以下复盘截至 `checkedAt` 已落盘文稿」。
2. 聚合当日时间线索引稿：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" build-timeline --date YYYY-MM-DD
   ```
3. 读取生成的 `outputs/daily_timelines/YYYY-MM-DD_daily_timeline.md`，按下方复盘提示词合同提炼交付。

### 提炼提示词合同（Daily Timeline Synthesizer）
- **角色与目标**：将全天多段静默录音转写稿合并为一份**按时间轴排列、去水词、结论先行、带原话溯源的《每日会议时间线与决策账》**。
- **硬性纪律**：
  1. **中英术语对齐**：基于业务词表（`${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/config/vocabulary.txt`）自动修正同音错字（如「太普迪/踏普迪 → TAPD」「天穷 → 天穹」「脑浮 → 脑腐」「游狼 → 游廊」），无法确认专有名词时保留原词并加 `[?存疑: 原词]`。
  2. **说话人隔离**：严格区分 `[Kenny]`（本机麦克风，我方表态/承诺）与 `[Remote / Speaker X]`（远端参会人）。未确认真实姓名前保留标签，不瞎猜人名。
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
    - `[MM:SS] [Kenny]`：「原话关键句」
    - `[MM:SS] [Remote]`：「原话关键句」

  ## 三、今日待办账单（承诺 vs 建议分栏）
  ### 1. 原话明确承诺（Explicit Commitments）
  - [ ] **[我方待办]** 具体动作 —— 截止时间（溯源：`slug` `[MM:SS] [Kenny]`）
  - [ ] **[对方承诺]** 具体动作 —— 负责人/角色（溯源：`slug` `[MM:SS] [Remote]`）

  ### 2. Agent 建议跟进（Suggested Next Steps）
  - [ ] **[建议动作]** 针对未决问题或潜在风险的跟进建议（标注：`[Agent 推断]`）
  ```

---

## §2 查找某次讨论、原话或拍板结论（Find a Statement or Decision）

**适用场景**：用户问「刚才/昨天谁提到了 XX」「关于某需求的曝光口径当时是怎么定的」「找一下我答应什么时候交数」。

### 执行步骤
1. 先用窄检索定位命中记录与时间窗口，不要全量读文件：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" search "关键词" --date YYYY-MM-DD --context-lines 3
   ```
2. 针对命中的 `slug` 与时间戳区间，读取上下文切片（例如前后扩展 2~3 分钟）：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" read <slug> --start 05:00 --end 10:00
   ```
3. 若用户需要核对「我方原话」还是「对方原话」，用 `--speaker Kenny` 或 `--speaker Remote` 过滤。

### 输出要求
- 首句直接给出查到的拍板结论或原话核心意思。
- 附上精确溯源：日期、场次 `slug`、时间戳 `[MM:SS - MM:SS]`、说话人标签（`[Kenny]` / `[Remote]`）及逐字原话引用。
- 若存在多处讨论且前后口径有修正，按时间先后列出并指明最终生效版本。

---

## §3 项目简报与交接单（Project Brief or Handoff）

**适用场景**：用户刚开完一场长会或多场专题讨论，要求「把刚才那场会整理成策划纪要/交接单」「整理成能发给研发或写进需求单的方案摘要」。

### 执行步骤
1. 列出当日记录定位目标场次 `slug`：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" list --date YYYY-MM-DD
   ```
2. 读取目标场次完整逐字稿：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" read <slug>
   ```

### 提炼提示词合同（5 栏工程交接结构）
将口语化讨论重组为无废话的工程交接结构，每一项后附 `[MM:SS]` 时间戳溯源：
1. **已拍板决策（Decisions）**：明确敲定的机制、状态机、UI 规则、配置数值或实验分流比例。
2. **决策依据与取舍（Reasons & Trade-offs）**：为什么选 A 不选 B（如性能开销、玩家理解成本、研发排期限制）。
3. **明确承诺（Explicit Commitments）**：各方在会上亲口接下的交付物与时间点。
4. **跨模块依赖（Dependencies）**：依赖客户端协议、后台接口、天穹表字段、版更时间或外部团队配合的事项。
5. **未决问题与阻塞项（Unresolved Questions）**：会上提出但未定论、需会后拉群或查数据确认的悬念。

---

## §4 待办与跟进提取（Follow-ups：承诺 vs 建议严格分栏）

**适用场景**：用户问「从今天会议里提取待办」「我今天开会答应了别人什么事」。

### 核心规则（借鉴 Auday 归属纪律）
- **绝不混淆「原话承诺」与「AI 脑补建议」**：很多人被语音总结困扰，是因为 AI 把顺口聊到的想法全变成了待办。必须严格拆成两个独立分组：
  1. **原话明确承诺（Explicit Commitments）**：必须有 `[Kenny]` 或 `[Remote]` 的原话支撑；仅在原话明确提到负责人或期限时才填写对应字段，否则标 `未指定`。
  2. **Agent 建议跟进（Suggested Next Steps）**：会上悬而未决、风险未闭环、按业务逻辑应当补充验证的动作，显式标注 `[Agent 建议]`。
- **默认本地交付**：默认在对话或本地 Markdown 中输出待办清单；只有当用户明确下达「把第 1、2 条加到滴答清单 / 企微待办 / Notion」时，才切换到对应外部工具 Skill 执行写入。

---

## §5 关键原话存疑与原声重转（Disputed Wording / Audio Re-analysis）

**适用场景**：某段逐字稿因为多人抢话、中英混杂或背景音导致识别含糊，或者某场历史录音当时只留了 `.wav` 没有 `.txt`，需要用 `Qwen3-ASR-1.7B` 深度重转。

### 执行步骤
1. 检查目标场次的音频文件列表（区分合成轨 `.wav`、远端轨 `_app.wav`、本机麦克风轨 `_mic.wav`）：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" list --limit 10
   ```
2. 运行非破坏性重转写（可针对混合轨，也可专门针对 `_mic.wav` 只重转 Kenny 原话）：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" retranscribe <slug或wav路径> --speaker Kenny
   ```
3. 读取新生成的 `<slug>.qwen3.txt` 衍生件，与原 `.txt` 对比核实存疑字词。

---

## §6 业务热词与同音纠错进化（Vocabulary & Terminology Feedback Loop）

**适用场景**：用户在审阅时间线或纪要时指出「XX 词识别错了，应该是 YY」，或新版本出现了新的业务黑话/玩法代号。

### 执行步骤
1. **标准业务热词**：将正确词条按分类写入 `${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/config/vocabulary.txt`。
2. **高频同音错字确定性替换**：若某个词被固定听错（如 `太普迪 -> TAPD`），以 `错误词 -> 正确词` 格式追加到 `${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/config/terminology_rules.txt`（`qwen_transcribe.py` 会在每次转录落盘前自动执行确定性纠错）。
3. **同步至 App 配置**：更新词表后运行：
   ```bash
   swift "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/apply_config.swift"
   ```
   使新词表同步写入 `~/Library/Application Support/MeetingTranscriber/vocabulary.txt`。

---

## §7 说话人音色自动识别与持久化声纹库维护（Persistent Speaker Voiceprints）

**适用场景**：
- 新一场多人会议转写完成后，自动根据文稿内点名/称呼线索识别 `说话人_01`、`R_S1` 等标签对应的真实同事姓名；
- 用户指出「刚才那场会里的 `说话人_01` 是小辉、`R_S5` 是一鸣，帮我改过来并记住他们的声音」。

### 机制说明（零弹窗 + 256 维声纹质心持久化）
1. `MeetingTranscriber.app` 在每次离线说话人分离（FluidAudio 256 维声纹嵌入）完成后，**不弹出手动命名窗口**，自动将本机主讲麦克风 `M_S1` 映射为 `Kenny`，将已命中声纹库的远端同事直接替换为真名，未命中的新声纹（发言 `>= 5s`）自动分配 `说话人_01`、`说话人_02` 并把原始声纹向量保存在 `outputs/recordings/<slug>_speakers.json` 与全局声纹库 `outputs/speakers.json`。
2. 当 Agent 通过上下文线索或用户指令调用 `assign-speaker` 确认身份后，会同时：
   - 将该说话人的 256 维声纹向量及在线加权质心（running centroid）写入 `outputs/speakers.json`（并同步镜像至 `~/Library/Application Support/MeetingTranscriber/speakers.json`）；
   - 将对应文稿 `<slug>.txt` 中的临时标签批量替换为真实姓名；
   - **后续任何新会议只要同一人再次开口（余弦距离 `< 0.45`），App 在转写阶段即自动识别为该同事真名**。

### 执行步骤
1. 查看全局声纹库与目标会议各说话人的声纹候选、上下句点名线索（Context Clues）与代表发言：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" speakers --slug <slug>
   ```
2. 结合 `contextClues`（如主持人点名「一鸣哥」「老丁」「莫哥」「策少」「俊尧哥」）或用户给出的修正指令，执行持久化映射与文稿重写：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" assign-speaker --slug <slug> --map "M_S1=Kenny,R_S5=一鸣,R_S3=老丁,R_S7=莫哥,R_S8=策少,R_S6=俊尧"
   ```
3. 重建当日时间线汇总稿，使最新真名同步至 `daily_timelines/`：
   ```bash
   python3 "${AI_WORK_ROOT}/05_效率工具/meeting-transcriber/scripts/timeline_cli.py" build-timeline
   ```
