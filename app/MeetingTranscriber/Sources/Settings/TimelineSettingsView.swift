import AppKit
import AVFoundation
import SwiftUI

// MARK: - AI Digest Codable Models

struct DailyTimelineDigest: Codable {
    var date: String
    var generatedAt: String?
    var model: String?
    var dailyQuote: String?
    var dailyOverview: String?
    var totalHighlightsCount: Int?
    var entries: [String: TimelineEntryDigest]?
}

struct TimelineEntryDigest: Codable {
    var shortTitle: String?
    var summary: String?
    var densityLabel: String?
    var highlightsCount: Int?
    var tags: [String]?
    var highlights: [String]?
    var todos: [String]?
}

// MARK: - Timeline Data Model

struct TimelineSubClip: Identifiable {
    let id: String
    let timeString: String
    let durationSeconds: TimeInterval
    let summary: String
    let transcriptText: String
    let audioURL: URL?
    let protocolURL: URL?
    let isTrivialFragment: Bool
}

struct TimelineEntry: Identifiable {
    let id: String
    let dateString: String
    let timeString: String
    let rawTitle: String
    let protocolURL: URL?
    let audioURL: URL?
    let transcriptPreview: String
    let fullTranscriptText: String
    let fileDate: Date
    let durationSeconds: TimeInterval
    let speakerNames: [String]
    let aiDigest: TimelineEntryDigest?
    let userNote: String?
    let subClips: [TimelineSubClip]
    let foldedFragmentCount: Int
    let unrefinedSlugs: [String]

    /// True when this entry has been AI-distilled and has no pending unrefined sub-clips.
    var isRefined: Bool {
        aiDigest != nil && unrefinedSlugs.isEmpty
    }

    var sortKey: String {
        "\(dateString)_\(timeString)_\(id)"
    }

    var hourMinuteString: String {
        let parts = timeString.split(separator: ":")
        if parts.count >= 2 {
            return "\(parts[0]):\(parts[1])"
        }
        return timeString
    }

    var hourOfDay: Int {
        let parts = timeString.split(separator: ":")
        if let first = parts.first, let h = Int(first) {
            return max(0, min(23, h))
        }
        return Calendar.current.component(.hour, from: fileDate)
    }

    var formattedDurationShort: String {
        guard durationSeconds > 0 else { return "1 分钟" }
        let totalSec = Int(durationSeconds.rounded())
        let mins = totalSec / 60
        let secs = totalSec % 60
        if mins == 0 {
            return "\(max(1, secs)) 秒"
        }
        return "\(mins) 分钟"
    }

    var nonKennySpeakers: [String] {
        speakerNames.filter { name in
            let lower = name.lowercased()
            return lower != "kenny" && name != "册少" && name != "策少" && !name.hasPrefix("说话人_")
        }
    }

    /// True when this entry is the user's own active voice dictation / personal focus memo.
    var isVoiceMemoFocus: Bool {
        if rawTitle.contains("语音输入速记") || id.contains("语音输入速记") {
            return true
        }
        return nonKennySpeakers.isEmpty && speakerNames.count <= 1 && !rawTitle.lowercased().contains("call")
    }

    var sourceSubtitle: String {
        if isVoiceMemoFocus {
            if subClips.count > 1 {
                return "当前关注 · 语音速记 (\(subClips.count) 段聚合)"
            }
            return "当前关注 · 语音速记"
        }
        let lower = rawTitle.lowercased()
        if lower.contains("wwmapp") || rawTitle.contains("企微") {
            return "企微多人评审"
        }
        if lower.contains("tencent") || rawTitle.contains("腾讯会议") {
            return "腾讯会议"
        }
        return displayTitle
    }

    var displayTitle: String {
        if let st = aiDigest?.shortTitle, !st.isEmpty {
            return st
        }
        let lower = rawTitle.lowercased()
        if lower == "wwmapp call" || lower == "wwmapp_call" {
            return "企业微信会议"
        }
        if lower == "tencent meeting call" || lower == "tencent_meeting_call" {
            return "腾讯会议"
        }
        return rawTitle
    }

    /// Auday-style 2nd-person narrative summary.
    var narrativeSummary: String {
        if let s = aiDigest?.summary, !s.isEmpty {
            return s
        }
        let cleanLines = transcriptPreview
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !cleanLines.isEmpty else {
            return "已捕获现场录音，点击右上角「重新提炼」或展开「Qwen3-ASR 重转」生成结构化总结。"
        }
        let bodies = cleanLines.prefix(3).map { line -> String in
            let strippedTime = line.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
            if let range = strippedTime.range(of: #":\s*"#, options: .regularExpression) {
                return String(strippedTime[range.upperBound...])
            }
            return strippedTime
        }
        let joined = bodies.joined(separator: " ")
        if isVoiceMemoFocus {
            return "你梳理了当前关注重点：\(String(joined.prefix(110)))"
        }
        return String(joined.prefix(120))
    }

    var densityLabel: String {
        if let d = aiDigest?.densityLabel, !d.isEmpty {
            return d
        }
        if isVoiceMemoFocus { return "当前关注" }
        if durationSeconds >= 600 { return "信息密集" }
        if durationSeconds >= 120 { return "信息适中" }
        return "信息适中"
    }

    var highlightsCount: Int {
        aiDigest?.highlightsCount ?? aiDigest?.highlights?.count ?? 0
    }

    var highlights: [String] {
        aiDigest?.highlights ?? []
    }

    var todos: [String] {
        aiDigest?.todos ?? []
    }

    var tags: [String] {
        aiDigest?.tags ?? []
    }
}

// MARK: - Audio Player

@MainActor
@Observable
final class TimelineAudioPlayer: NSObject, AVAudioPlayerDelegate {
    var playingEntryID: String?
    var isPlaying: Bool = false
    private var player: AVAudioPlayer?

    func togglePlay(entryID: String, url: URL) {
        if playingEntryID == entryID, isPlaying {
            stop()
            return
        }
        stop()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingEntryID = entryID
            isPlaying = true
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingEntryID = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}

// MARK: - Auday Editorial Timeline View

struct TimelineSettingsView: View {
    @Bindable var settings: AppSettings
    var transcriberStatus: TranscriberStatus? = nil
    var isWatching: Bool = true
    var isManualRecording: Bool = false
    var pipelineBusy: Bool = false
    var onToggleWatching: (() -> Void)? = nil
    var onRecordMicrophone: (() -> Void)? = nil
    var onStopManualRecording: (() -> Void)? = nil
    var onRecordApp: (() -> Void)? = nil
    var onProcessFiles: (() -> Void)? = nil
    var onNameSpeakers: (() -> Void)? = nil
    var onOpenSettingsTab: ((String) -> Void)? = nil
    var onQuit: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    @State private var entries: [TimelineEntry] = []
    @State private var digestsByDate: [String: DailyTimelineDigest] = [:]
    @State private var userNotes: [String: String] = [:]
    @State private var selectedDate: String = ""
    @State private var categoryFilter: String = "ALL"
    @State private var sortChronological: Bool = true
    @State private var expandedIDs: Set<String> = []
    @State private var editingNoteID: String?
    @State private var noteDraft: String = ""
    @State private var statusBanner: String?
    @State private var isRunningAction: Bool = false
    @State private var runningActionLabel: String = ""
    @State private var audioPlayer = TimelineAudioPlayer()

    // Auday Warm Editorial Palette (#F6F5F0 light / #141413 dark)
    private var canvasBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.075)
            : Color(red: 0.965, green: 0.961, blue: 0.941)
    }

    private var primaryInk: Color {
        colorScheme == .dark
            ? Color(red: 0.94, green: 0.93, blue: 0.90)
            : Color(red: 0.11, green: 0.12, blue: 0.11)
    }

    private var secondaryInk: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.50)
            : Color(red: 0.45, green: 0.45, blue: 0.43)
    }

    private var warmAccent: Color {
        Color(red: 0.76, green: 0.48, blue: 0.18)
    }

    private var refinedGreen: Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.78, blue: 0.52)
            : Color(red: 0.16, green: 0.48, blue: 0.31)
    }

    private var availableDates: [String] {
        let dates = Set(entries.map(\.dateString))
        let today = Self.todayDateString()
        return Array(dates.union([today])).sorted(by: >)
    }

    private var activeDate: String {
        if !selectedDate.isEmpty, selectedDate != "ALL" {
            return selectedDate
        }
        return availableDates.first ?? Self.todayDateString()
    }

    private var dateFilteredEntries: [TimelineEntry] {
        if selectedDate == "ALL" {
            return entries
        }
        return entries.filter { $0.dateString == activeDate }
    }

    private var refinedEntriesForDay: [TimelineEntry] {
        dateFilteredEntries.filter(\.isRefined)
    }

    private var unrefinedEntriesForDay: [TimelineEntry] {
        dateFilteredEntries.filter { !$0.isRefined }
    }

    private var filteredEntries: [TimelineEntry] {
        let base: [TimelineEntry]
        switch categoryFilter {
        case "UNREFINED":
            base = dateFilteredEntries.filter { !$0.isRefined }
        case "REFINED":
            base = dateFilteredEntries.filter(\.isRefined)
        case "MEETING":
            base = dateFilteredEntries.filter { !$0.isVoiceMemoFocus }
        case "VOICE_MEMO":
            base = dateFilteredEntries.filter(\.isVoiceMemoFocus)
        default:
            base = dateFilteredEntries
        }
        return sortChronological
            ? base.sorted { $0.sortKey < $1.sortKey }
            : base.sorted { $0.sortKey > $1.sortKey }
    }

    private var totalRecordingDurationLabel: String {
        let totalMin = max(1, Int((dateFilteredEntries.reduce(0.0) { $0 + $1.durationSeconds } / 60.0).rounded()))
        if totalMin >= 60 {
            let h = totalMin / 60
            let m = totalMin % 60
            return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
        }
        return "\(totalMin) 分钟"
    }

    private var totalHighlightsCount: Int {
        let sum = dateFilteredEntries.reduce(0) { $0 + $1.highlightsCount }
        if sum > 0 { return sum }
        if let d = digestsByDate[activeDate], let c = d.totalHighlightsCount, c > 0 {
            return c
        }
        return 0
    }

    var body: some View {
        ZStack {
            canvasBackground.ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        inAppStatusAndControlBar
                            .id("TIMELINE_TOP")
                        audayTopHeader
                        dayPillStrip
                        hourlyDensityChart
                        if isRunningAction || statusBanner != nil {
                            liveActivityBanner
                        }
                        dailyHeroReviewCard
                        timeSlotStreamSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
                .onAppear {
                    reloadTimeline()
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo("TIMELINE_TOP", anchor: .top)
                    }
                }
                .onChange(of: selectedDate) { _, _ in
                    scrollProxy.scrollTo("TIMELINE_TOP", anchor: .top)
                }
            }
        }
        .onDisappear {
            audioPlayer.stop()
        }
    }

    // MARK: - 0. In-UI Status & Control Strip (Replaces Menu Bar Dropdown & Sidebar)

    private var inAppStatusAndControlBar: some View {
        let state = transcriberStatus?.state ?? .idle
        let isRec = state == .recording
        let statusDotColor: Color = if isRec {
            Color(red: 0.16, green: 0.78, blue: 0.40)
        } else if pipelineBusy || state == .transcribing {
            warmAccent
        } else if isWatching {
            Color(red: 0.22, green: 0.62, blue: 0.40)
        } else {
            secondaryInk.opacity(0.5)
        }

        let statusText: String = if isRec {
            if let meeting = transcriberStatus?.meeting, !meeting.title.isEmpty {
                "正在录制 · \(meeting.title)"
            } else {
                "正在录制音频..."
            }
        } else if pipelineBusy || state == .transcribing {
            "正在转写与声纹识别..."
        } else if isWatching {
            "自动监听中"
        } else {
            "监听已暂停"
        }

        return HStack(spacing: 10) {
            // Left: Live Status Capsule Menu
            Menu {
                if let onToggleWatching {
                    Button {
                        onToggleWatching()
                    } label: {
                        Label(
                            isWatching ? "暂停自动监听会议" : "开启自动监听会议",
                            systemImage: isWatching ? "pause.circle" : "play.circle",
                        )
                    }
                }
                if let onStopManualRecording {
                    Button {
                        onStopManualRecording()
                    } label: {
                        Label("停止当前手动录音", systemImage: "stop.circle.fill")
                    }
                } else if !isRec {
                    if let onRecordMicrophone {
                        Button {
                            onRecordMicrophone()
                        } label: {
                            Label("开始麦克风语音速记", systemImage: "mic.circle")
                        }
                    }
                    if let onRecordApp {
                        Button {
                            onRecordApp()
                        } label: {
                            Label("指定应用双轨录音...", systemImage: "record.circle")
                        }
                    }
                }
                if let onProcessFiles {
                    Divider()
                    Button {
                        onProcessFiles()
                    } label: {
                        Label("导入音视频文件转录...", systemImage: "doc.badge.plus")
                    }
                }
                if let onNameSpeakers {
                    Button {
                        onNameSpeakers()
                    } label: {
                        Label("确认待定说话人...", systemImage: "person.2.wave.2")
                    }
                }
                Divider()
                Button {
                    NSWorkspace.shared.open(settings.effectiveOutputDir)
                } label: {
                    Label("打开录音与文稿目录", systemImage: "folder")
                }
                if let onQuit {
                    Divider()
                    Button(role: .destructive) {
                        onQuit()
                    } label: {
                        Label("退出 MeetingTranscriber", systemImage: "power")
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7.5, height: 7.5)
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(primaryInk.opacity(0.88))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(secondaryInk)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(
                    Capsule()
                        .fill(primaryInk.opacity(0.05))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isRec ? statusDotColor.opacity(0.45) : primaryInk.opacity(0.08),
                                    lineWidth: 1,
                                ),
                        ),
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: 8)

            // Right: Quick Voice Memo + In-Window More Settings
            HStack(spacing: 8) {
                if let onStopManualRecording {
                    Button {
                        onStopManualRecording()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("结束速记")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(Color(red: 0.82, green: 0.24, blue: 0.20)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                } else if !isRec, let onRecordMicrophone {
                    Button {
                        onRecordMicrophone()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("速记")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(primaryInk.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5.5)
                        .background(
                            Capsule()
                                .fill(primaryInk.opacity(0.05))
                                .overlay(Capsule().strokeBorder(primaryInk.opacity(0.10), lineWidth: 1)),
                        )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }

                if let onOpenSettingsTab {
                    Menu {
                        Button {
                            onOpenSettingsTab("general")
                        } label: {
                            Label("常规与自动监听设置", systemImage: "gear")
                        }
                        Button {
                            onOpenSettingsTab("audio")
                        } label: {
                            Label("音频与麦克风设置", systemImage: "mic")
                        }
                        Button {
                            onOpenSettingsTab("transcription")
                        } label: {
                            Label("语音识别引擎与热词 (ASR)", systemImage: "waveform")
                        }
                        Button {
                            onOpenSettingsTab("speakers")
                        } label: {
                            Label("说话人声纹库管理", systemImage: "person.2")
                        }
                        Button {
                            onOpenSettingsTab("output")
                        } label: {
                            Label("输出目录与提示词", systemImage: "doc.text")
                        }
                        Button {
                            onOpenSettingsTab("advanced")
                        } label: {
                            Label("权限健康与系统诊断", systemImage: "wrench.and.screwdriver")
                        }
                        Button {
                            onOpenSettingsTab("about")
                        } label: {
                            Label("关于与版本信息", systemImage: "info.circle")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .medium))
                            Text("更多设置")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(primaryInk.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5.5)
                        .background(
                            Capsule()
                                .fill(primaryInk.opacity(0.05))
                                .overlay(Capsule().strokeBorder(primaryInk.opacity(0.10), lineWidth: 1)),
                        )
                    } primaryAction: {
                        onOpenSettingsTab("general")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - 1. Top Editorial Header (Auday Screenshot 1 & 3 Layout — Narrow-Safe)

    private var audayTopHeader: some View {
        let parts = Self.parseDateDisplay(activeDate)
        let unrefinedCount = unrefinedEntriesForDay.count
        let refinedCount = refinedEntriesForDay.count

        return HStack(alignment: .center, spacing: 14) {
            // Left Date Block: Big Serif Day + 3 Stacked Lines (never stretches horizontally)
            HStack(alignment: .center, spacing: 14) {
                Text(parts.dayNumber)
                    .font(.system(size: 64, weight: .regular, design: .serif))
                    .foregroundStyle(primaryInk)
                    .tracking(-1.5)
                    .fixedSize()

                VStack(alignment: .leading, spacing: 4) {
                    Text(parts.weekdayName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(primaryInk)
                    Text(parts.yearMonthLabel)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(secondaryInk)
                    HStack(spacing: 6) {
                        Text(parts.relativeLabel)
                        Rectangle()
                            .fill(primaryInk.opacity(0.18))
                            .frame(width: 18, height: 1)
                        Text("记忆 \(totalRecordingDurationLabel)")
                        if !dateFilteredEntries.isEmpty {
                            Text("·")
                            if unrefinedCount > 0 {
                                Text("已提炼 \(refinedCount) · 未提炼 \(unrefinedCount)")
                                    .foregroundStyle(warmAccent)
                                    .fontWeight(.medium)
                            } else {
                                Text("已全部提炼 (\(refinedCount))")
                                    .foregroundStyle(refinedGreen)
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(secondaryInk)
                }
                .fixedSize()
            }

            Spacer(minLength: 10)

            // Right Action Cluster: Explicitly Distinguishes Unrefined ("提炼新记录") vs Refined ("已全部提炼")
            HStack(spacing: 8) {
                if unrefinedCount > 0 {
                    Button {
                        runAgyTimelineSummarizer(newOnly: true)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.42))
                            Text(refinedCount == 0 ? "一键提炼 (\(unrefinedCount))" : "提炼新记录 (\(unrefinedCount))")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(primaryInk),
                        )
                        .foregroundStyle(canvasBackground)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunningAction)
                    .fixedSize()
                    .help("仅对今日尚未提炼的 \(unrefinedCount) 段新记录执行 AI 摘要与重点提炼")
                } else if refinedCount > 0 {
                    Menu {
                        Button {
                            runAgyTimelineSummarizer(forceAll: true)
                        } label: {
                            Label("重新提炼今日全部 \(refinedCount) 段记录", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("已全部提炼 (\(refinedCount))")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6.5)
                        .background(
                            Capsule()
                                .fill(refinedGreen.opacity(0.11))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(refinedGreen.opacity(0.28), lineWidth: 1),
                                ),
                        )
                        .foregroundStyle(refinedGreen)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(isRunningAction)
                    .fixedSize()
                }

                Menu {
                    if unrefinedCount > 0 {
                        Button {
                            runAgyTimelineSummarizer(newOnly: true)
                        } label: {
                            Label("提炼未处理的 \(unrefinedCount) 段新记录", systemImage: "sparkles")
                        }
                    }
                    if !dateFilteredEntries.isEmpty {
                        Button {
                            runAgyTimelineSummarizer(forceAll: true)
                        } label: {
                            Label("重新提炼今日全部时段", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Divider()
                    }

                    Button {
                        NSWorkspace.shared.open(settings.effectiveOutputDir)
                    } label: {
                        Label("打开录音与文稿目录", systemImage: "folder")
                    }

                    Button {
                        runDailyTimelineBuilder()
                    } label: {
                        Label("导出 Markdown 时间线汇总", systemImage: "doc.richtext")
                    }

                    Divider()

                    Button {
                        selectedDate = (selectedDate == "ALL") ? Self.todayDateString() : "ALL"
                    } label: {
                        Label(
                            selectedDate == "ALL" ? "仅看当天记录" : "查看全部日期 (\(entries.count))",
                            systemImage: "calendar",
                        )
                    }

                    Button {
                        reloadTimeline()
                    } label: {
                        Label("刷新列表", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryInk)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .strokeBorder(primaryInk.opacity(0.12), lineWidth: 1)
                                .background(Circle().fill(primaryInk.opacity(0.04))),
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 32)
            }
            .fixedSize()
        }
    }

    // MARK: - 2. 7-Day Circular Strip (Auday Screenshot 1 & 3 Style)

    private var dayPillStrip: some View {
        let stripDays = Self.buildRecentSevenDays(around: activeDate, available: Set(entries.map(\.dateString)))
        return HStack(spacing: 0) {
            ForEach(stripDays, id: \.dateString) { item in
                let isSelected = selectedDate != "ALL" && item.dateString == activeDate
                Button {
                    selectedDate = item.dateString
                } label: {
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(primaryInk)
                                .frame(width: 42, height: 42)
                        }
                        VStack(spacing: 3) {
                            Text(item.dayNumber)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(
                                    isSelected
                                        ? canvasBackground
                                        : (item.hasRecords ? primaryInk : secondaryInk.opacity(0.55)),
                                )
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    item.hasRecords
                                        ? (isSelected ? canvasBackground.opacity(0.85) : primaryInk.opacity(0.55))
                                        : Color.clear,
                                )
                                .frame(width: 8, height: 1.6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 3. 24-Hour Activity Density Bar Chart (Auday Baseline Dash -> Dark Block Style)

    private var hourlyDensityChart: some View {
        let buckets = computeHourlyBuckets()
        let maxMinutes = max(15.0, buckets.map(\.minutes).max() ?? 15.0)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    let mins = buckets[hour].minutes
                    let isActive = mins > 0
                    let ratio = min(1.0, max(0.24, mins / maxMinutes))
                    let barHeight: CGFloat = isActive ? CGFloat(6.0 + 20.0 * ratio) : 3.5

                    RoundedRectangle(cornerRadius: isActive ? 3.0 : 1.75)
                        .fill(
                            isActive
                                ? primaryInk.opacity(0.82)
                                : primaryInk.opacity(0.10),
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight)
                }
            }
            .frame(height: 28, alignment: .bottom)

            HStack {
                Text("00")
                Spacer()
                Text("06")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("24")
            }
            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
            .foregroundStyle(secondaryInk.opacity(0.8))
        }
    }

    // MARK: - 4. Live Activity Banner (Auday Screenshot 3 Style)

    private var liveActivityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if isRunningAction {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.32, green: 0.65, blue: 0.40))
                }
                Text(isRunningAction ? runningActionLabel : (statusBanner ?? ""))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(primaryInk)
                Spacer()
                if !isRunningAction {
                    Button("收起") {
                        statusBanner = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(secondaryInk)
                }
            }
            if isRunningAction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(primaryInk.opacity(0.08))
                            .frame(height: 4)
                        Capsule()
                            .fill(primaryInk.opacity(0.75))
                            .frame(width: geo.size.width * 0.45, height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(primaryInk.opacity(0.045)),
        )
    }

    // MARK: - 5. Dark Hero "每日回顾" Card (Auday Screenshot 1 Botanical Dot-Matrix Style)

    private var dailyHeroReviewCard: some View {
        let digest = digestsByDate[activeDate]
        let rawQuote = digest?.dailyQuote ?? "把复杂的事拆小，才看得见路。"
        let quote = rawQuote.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"'「」 "))
        let overview = digest?.dailyOverview
            ?? "已归档今日 \(dateFilteredEntries.count) 个时段的会议讨论与个人业务关注速记。"

        return VStack(alignment: .leading, spacing: 0) {
            // Top Stippled Botanical Leaf Dot-Matrix Art (Auday Screenshot 1)
            botanicalDotMatrixCanvas
                .frame(height: 116)
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text("每日回顾")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.46))

                Text(quote)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .fixedSize(horizontal: false, vertical: true)

                Text(overview)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineSpacing(4.5)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center) {
                    Text("已录音 \(totalRecordingDurationLabel)  ·  \(totalHighlightsCount) 个重点")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.45))

                    Spacer()

                    Button {
                        openOrRefreshDailyMarkdown()
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("打开每日回顾 Markdown 文稿")
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.055, green: 0.063, blue: 0.055)),
        )
    }

    /// Stippled dot-matrix botanical branch inspired by Auday Screenshot 1.
    private var botanicalDotMatrixCanvas: some View {
        Canvas { context, size in
            let spacing: CGFloat = 4.6
            let cols = Int(size.width / spacing)
            let rows = Int(size.height / spacing)
            let centerX = size.width * 0.48

            // Four organic tilted elliptical leaf shapes + stem
            struct LeafShape {
                let cx: CGFloat
                let cy: CGFloat
                let rx: CGFloat
                let ry: CGFloat
                let angle: CGFloat
            }

            let leaves: [LeafShape] = [
                LeafShape(cx: centerX - 68, cy: 78, rx: 34, ry: 13, angle: -0.58),
                LeafShape(cx: centerX - 24, cy: 40, rx: 42, ry: 16, angle: -0.82),
                LeafShape(cx: centerX + 34, cy: 36, rx: 46, ry: 15, angle: 0.62),
                LeafShape(cx: centerX + 22, cy: 76, rx: 44, ry: 14, angle: 0.22),
                LeafShape(cx: centerX + 74, cy: 52, rx: 36, ry: 12, angle: -0.25),
            ]

            for r in 0 ..< rows {
                for c in 0 ..< cols {
                    let x = CGFloat(c) * spacing
                    let y = CGFloat(r) * spacing
                    var maxIntensity: CGFloat = 0

                    for leaf in leaves {
                        let dx = x - leaf.cx
                        let dy = y - leaf.cy
                        let cosA = cos(leaf.angle)
                        let sinA = sin(leaf.angle)
                        let lx = dx * cosA + dy * sinA
                        let ly = -dx * sinA + dy * cosA
                        let norm = (lx * lx) / (leaf.rx * leaf.rx) + (ly * ly) / (leaf.ry * leaf.ry)
                        if norm <= 1.0 {
                            let edgeFade = 1.0 - pow(norm, 0.75)
                            // Subtle central vein modulation
                            let vein = abs(ly) < 1.8 ? 0.35 : 1.0
                            maxIntensity = max(maxIntensity, edgeFade * vein)
                        }
                    }

                    guard maxIntensity > 0.08 else { continue }
                    let dotDiameter: CGFloat = maxIntensity > 0.55 ? 2.7 : 2.1
                    let dotColor: Color = if maxIntensity > 0.68 {
                        Color(red: 0.82, green: 0.89, blue: 0.64).opacity(0.92)
                    } else if maxIntensity > 0.38 {
                        Color(red: 0.54, green: 0.76, blue: 0.53).opacity(0.82)
                    } else {
                        Color(red: 0.28, green: 0.48, blue: 0.32).opacity(0.65)
                    }

                    let rect = CGRect(
                        x: x - dotDiameter / 2,
                        y: y - dotDiameter / 2,
                        width: dotDiameter,
                        height: dotDiameter,
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                }
            }
        }
    }

    // MARK: - 6. "当日时段" Editorial Time-Slot Stream (Auday Screenshot 2 & 3 Style)

    private var timeSlotStreamSection: some View {
        let unrefinedCount = unrefinedEntriesForDay.count
        let refinedCount = refinedEntriesForDay.count

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                Text("当日时段")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(primaryInk)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(title: "全部 \(dateFilteredEntries.count)", key: "ALL")
                        if unrefinedCount > 0 {
                            filterChip(title: "● 未提炼 \(unrefinedCount)", key: "UNREFINED", accent: warmAccent)
                        }
                        if refinedCount > 0 {
                            filterChip(title: "✓ 已提炼 \(refinedCount)", key: "REFINED", accent: refinedGreen)
                        }
                        filterChip(title: "多人会议", key: "MEETING")
                        filterChip(title: "当前关注", key: "VOICE_MEMO")
                    }
                }
                .padding(.leading, 4)

                Spacer(minLength: 8)

                Button {
                    sortChronological.toggle()
                } label: {
                    Text("\(filteredEntries.count) 个时段 · \(sortChronological ? "正序" : "最新")")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(secondaryInk)
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }

            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                        audayTimelineRow(entry: entry, isLast: idx == filteredEntries.count - 1)
                    }
                }
            }
        }
    }

    private func filterChip(title: String, key: String, accent: Color? = nil) -> some View {
        let isSelected = categoryFilter == key
        let textFg: Color = if isSelected {
            canvasBackground
        } else if let accent {
            accent
        } else {
            secondaryInk
        }
        let bgFill: Color = if isSelected {
            accent ?? primaryInk
        } else if let accent {
            accent.opacity(0.10)
        } else {
            primaryInk.opacity(0.06)
        }

        return Button {
            categoryFilter = key
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: (isSelected || accent != nil) ? .medium : .regular))
                .foregroundStyle(textFg)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(bgFill),
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.clock")
                .font(.system(size: 28))
                .foregroundStyle(secondaryInk)
            Text("当前筛选条件下暂无时段记录")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(primaryInk)
            Text("进入企微/腾讯会议或使用麦克风语音输入时，系统将静默收音并支持一键提炼时段重点。")
                .font(.system(size: 12))
                .foregroundStyle(secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Clean, unboxed Auday editorial row that explicitly distinguishes `✓ 已提炼` vs `● 未提炼`.
    private func audayTimelineRow(entry: TimelineEntry, isLast: Bool) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)
        let isEditingThisNote = editingNoteID == entry.id
        let isRefined = entry.isRefined

        return HStack(alignment: .top, spacing: 18) {
            // Left Time Axis ("14:00" + node indicator + vertical line)
            VStack(spacing: 8) {
                Text(entry.hourMinuteString)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(primaryInk)

                if isRefined {
                    Circle()
                        .stroke(
                            entry.isVoiceMemoFocus ? warmAccent : refinedGreen.opacity(0.75),
                            lineWidth: 1.4,
                        )
                        .frame(width: 7, height: 7)
                } else {
                    ZStack {
                        Circle()
                            .fill(warmAccent.opacity(0.22))
                            .frame(width: 12, height: 12)
                        Circle()
                            .fill(warmAccent)
                            .frame(width: 6.5, height: 6.5)
                    }
                }

                if !isLast {
                    Rectangle()
                        .fill(primaryInk.opacity(0.09))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 48)
            .padding(.top, 2)

            // Right Editorial Content Column
            VStack(alignment: .leading, spacing: 10) {
                // Row 1: Explicit Refinement Badge ("✓ 已提炼" vs "● 未提炼") + Source Subtitle + Action/Duration
                HStack(alignment: .center, spacing: 7) {
                    if isRefined {
                        HStack(spacing: 3.5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("已提炼")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(refinedGreen)
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(refinedGreen.opacity(0.11)),
                        )
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(warmAccent)
                                .frame(width: 5.5, height: 5.5)
                            Text("未提炼")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(warmAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(warmAccent.opacity(0.13)),
                        )
                    }

                    Text(entry.sourceSubtitle)
                        .font(.system(size: 12, weight: entry.isVoiceMemoFocus ? .medium : .regular))
                        .foregroundStyle(entry.isVoiceMemoFocus ? warmAccent : secondaryInk)
                        .lineLimit(1)

                    Spacer()

                    if !isRefined {
                        Button {
                            let slugs = entry.unrefinedSlugs.isEmpty ? [entry.id] : entry.unrefinedSlugs
                            runAgyTimelineSummarizer(targetSlugs: slugs)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.42))
                                Text("立即提炼")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(canvasBackground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(primaryInk))
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunningAction)
                        .fixedSize()
                    }

                    Text(entry.formattedDurationShort)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(secondaryInk)
                        .fixedSize()
                }

                // Row 2: Main Content (Polished Narrative for Refined vs Raw Transcript Preview for Unrefined)
                if isRefined {
                    Text(entry.narrativeSummary)
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundStyle(primaryInk.opacity(0.92))
                        .lineSpacing(5.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleExpand(entry.id)
                        }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(warmAccent.opacity(0.65))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原始转写预览（尚未生成 AI 摘要与待办）")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(warmAccent)
                            Text(entry.narrativeSummary)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(primaryInk.opacity(0.78))
                                .lineSpacing(4.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(warmAccent.opacity(0.05)),
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleExpand(entry.id)
                    }
                }

                // Optional User Custom Remark Banner
                if let note = entry.userNote, !note.isEmpty, !isEditingThisNote {
                    sessionCardNoteBanner(entry: entry, note: note)
                }
                if isEditingThisNote {
                    sessionCardNoteEditor(entry)
                }

                // Row 3: Subtle Metadata + Right Actions
                sessionCardFooter(entry: entry, isExpanded: isExpanded)
                    .padding(.top, 2)

                // Expandable Detail Drawer
                if isExpanded {
                    expandedDrawerView(entry)
                        .padding(.top, 6)
                }

                // Bottom Hairline Divider (Auday Screenshot 2)
                Rectangle()
                    .fill(primaryInk.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 14)
            }
            .padding(.bottom, 18)
        }
    }

    private func sessionCardNoteBanner(entry: TimelineEntry, note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(warmAccent)
                .padding(.top, 2)
            Text("备注：\(note)")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(primaryInk.opacity(0.88))
            Spacer()
            Button("编辑") {
                editingNoteID = entry.id
                noteDraft = note
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(secondaryInk)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(primaryInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sessionCardNoteEditor(_ entry: TimelineEntry) -> some View {
        HStack(spacing: 8) {
            TextField("输入这段录音的重点备注或跟进结论...", text: $noteDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Button("保存") {
                saveUserNote(for: entry.id, text: noteDraft)
                editingNoteID = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("取消") {
                editingNoteID = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func sessionCardFooter(entry: TimelineEntry, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Text(entry.densityLabel)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(secondaryInk)

            if entry.highlightsCount > 0 {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryInk.opacity(0.6))
                HStack(spacing: 3) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(warmAccent)
                    Text("\(entry.highlightsCount) 个重点")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(secondaryInk)
                }
            }

            if !entry.todos.isEmpty {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryInk.opacity(0.6))
                Text("\(entry.todos.count) 项待办")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(secondaryInk)
            }

            if !entry.nonKennySpeakers.isEmpty {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryInk.opacity(0.6))
                Text(entry.nonKennySpeakers.prefix(4).joined(separator: "、"))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
            }

            if entry.foldedFragmentCount > 0 {
                Text("· 已过滤 \(entry.foldedFragmentCount) 条碎片输入")
                    .font(.system(size: 11.5))
                    .foregroundStyle(secondaryInk.opacity(0.75))
            }

            Spacer()

            Button {
                editingNoteID = entry.id
                noteDraft = entry.userNote ?? ""
            } label: {
                Text("备注")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(secondaryInk)
            }
            .buttonStyle(.plain)

            Button {
                toggleExpand(entry.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleExpand(_ id: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }

    // MARK: - 7. Expanded Detail Drawer

    private func expandedDrawerView(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !entry.highlights.isEmpty {
                expandedHighlightsSection(entry)
            }
            if !entry.todos.isEmpty {
                expandedTodosSection(entry)
            }
            if entry.subClips.count > 1 {
                expandedSubClipsSection(entry)
            }
            expandedActionsToolbar(entry)
            expandedRawTranscriptBox(entry)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(primaryInk.opacity(0.035)),
        )
    }

    private func expandedHighlightsSection(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("✦ 核心重点结论")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(warmAccent)

            ForEach(entry.highlights, id: \.self) { hl in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(warmAccent.opacity(0.75))
                        .frame(width: 4.5, height: 4.5)
                        .padding(.top, 6)
                    Text(hl)
                        .font(.system(size: 13))
                        .foregroundStyle(primaryInk.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func expandedTodosSection(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("☑ 双向待办与承诺")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primaryInk.opacity(0.75))

            ForEach(entry.todos, id: \.self) { td in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "square")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryInk)
                        .padding(.top, 2)
                    Text(td)
                        .font(.system(size: 13))
                        .foregroundStyle(primaryInk.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func expandedSubClipsSection(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("包含 \(entry.subClips.count) 段连续语音记录")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(secondaryInk)

            ForEach(entry.subClips) { clip in
                HStack(alignment: .center, spacing: 8) {
                    Text(clip.timeString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(secondaryInk)
                    Text(clip.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(clip.isTrivialFragment ? secondaryInk : primaryInk.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    if let url = clip.audioURL {
                        Button {
                            audioPlayer.togglePlay(entryID: clip.id, url: url)
                        } label: {
                            Image(
                                systemName: (audioPlayer.playingEntryID == clip.id && audioPlayer.isPlaying)
                                    ? "stop.circle.fill"
                                    : "play.circle",
                            )
                            .font(.system(size: 13))
                            .foregroundStyle(secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func expandedActionsToolbar(_ entry: TimelineEntry) -> some View {
        HStack(spacing: 10) {
            if let audioURL = entry.audioURL {
                let isPlayingThis = audioPlayer.playingEntryID == entry.id && audioPlayer.isPlaying
                Button {
                    audioPlayer.togglePlay(entryID: entry.id, url: audioURL)
                } label: {
                    Label(isPlayingThis ? "停止播放" : "播放原声", systemImage: isPlayingThis ? "stop.fill" : "play.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([audioURL])
                } label: {
                    Label("定位音频", systemImage: "waveform")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    retranscribeWithQwen(audioURL: audioURL, entry: entry)
                } label: {
                    Label("Qwen3-ASR 重转", systemImage: "sparkles")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunningAction)
            }

            if let protocolURL = entry.protocolURL {
                Button {
                    NSWorkspace.shared.open(protocolURL)
                } label: {
                    Label("打开文稿", systemImage: "doc.text")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            Button {
                let copyText = """
                【\(entry.displayTitle)】(\(entry.dateString) \(entry.hourMinuteString))
                摘要：\(entry.narrativeSummary)
                重点：
                \(entry.highlights.map { "- \($0)" }.joined(separator: "\n"))

                原始逐字稿：
                \(entry.fullTranscriptText)
                """
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                statusBanner = "已复制「\(entry.displayTitle)」摘要与逐字稿"
            } label: {
                Label("复制全文", systemImage: "doc.on.doc")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func expandedRawTranscriptBox(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原始逐字稿")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(secondaryInk)
            ScrollView {
                Text(entry.fullTranscriptText.isEmpty ? "（暂无转写内容）" : entry.fullTranscriptText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(primaryInk.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 90, maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(primaryInk.opacity(0.03)),
            )
        }
    }

    // MARK: - Hourly Bucket Calculation

    private struct HourBucket {
        var minutes: Double = 0
        var hasFocusMemo: Bool = false
    }

    private func computeHourlyBuckets() -> [HourBucket] {
        var buckets = Array(repeating: HourBucket(), count: 24)
        for entry in dateFilteredEntries {
            let h = max(0, min(23, entry.hourOfDay))
            let mins = max(1.0, entry.durationSeconds / 60.0)
            buckets[h].minutes += mins
            if entry.isVoiceMemoFocus {
                buckets[h].hasFocusMemo = true
            }
        }
        return buckets
    }

    // MARK: - Actions & Persistence

    private func reloadTimeline() {
        let outDir = settings.effectiveOutputDir
        let accessing = outDir.startAccessingSecurityScopedResource()
        defer { if accessing { outDir.stopAccessingSecurityScopedResource() } }

        let loadedDigests = TimelineScanner.loadDigests(outputDir: outDir)
        let loadedNotes = TimelineScanner.loadUserNotes(outputDir: outDir)
        digestsByDate = loadedDigests
        userNotes = loadedNotes
        entries = TimelineScanner.scan(
            outputDir: outDir,
            recordingsDir: AppPaths.recordingsDir,
            digestsByDate: loadedDigests,
            userNotes: loadedNotes,
        )
        if selectedDate.isEmpty {
            selectedDate = availableDates.first ?? Self.todayDateString()
        }
    }

    private func saveUserNote(for entryID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userNotes.removeValue(forKey: entryID)
        } else {
            userNotes[entryID] = trimmed
        }
        TimelineScanner.saveUserNotes(userNotes, outputDir: settings.effectiveOutputDir)
        reloadTimeline()
        statusBanner = "已保存备注"
    }

    private func openOrRefreshDailyMarkdown() {
        let mdURL = settings.effectiveOutputDir
            .appendingPathComponent("daily_timelines", isDirectory: true)
            .appendingPathComponent("\(activeDate)_ai_digest.md")
        if FileManager.default.fileExists(atPath: mdURL.path) {
            NSWorkspace.shared.open(mdURL)
        } else {
            runAgyTimelineSummarizer(newOnly: true)
        }
    }

    /// Background execution of `summarize_timeline_agy.py`.
    private func runAgyTimelineSummarizer(
        singleSlug: String? = nil,
        targetSlugs: [String] = [],
        newOnly: Bool = false,
        forceAll: Bool = false,
    ) {
        isRunningAction = true
        if !targetSlugs.isEmpty || singleSlug != nil {
            runningActionLabel = "正在后台提炼选定时段摘要与待办..."
        } else if newOnly {
            runningActionLabel = "正在后台提炼 \(activeDate) 新增未提炼记录..."
        } else {
            runningActionLabel = "正在后台重新提炼 \(activeDate) 全部时段重点..."
        }
        let targetDate = activeDate
        Task.detached(priority: .userInitiated) {
            let root = AppPaths.workspaceRootDir
            let venvPy = root.appendingPathComponent(".venv/bin/python")
            let pyURL = FileManager.default.fileExists(atPath: venvPy.path)
                ? venvPy
                : URL(fileURLWithPath: "/usr/bin/python3")
            let script = root.appendingPathComponent("scripts/summarize_timeline_agy.py")

            let proc = Process()
            proc.executableURL = pyURL
            var args = [script.path, "--date", targetDate]
            if let singleSlug {
                args.append(contentsOf: ["--slug", singleSlug])
            } else if !targetSlugs.isEmpty {
                args.append(contentsOf: ["--slugs", targetSlugs.joined(separator: ",")])
            } else if newOnly {
                args.append("--new-only")
            } else if forceAll {
                args.append("--force")
            }
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
            env["PATH"] = (extraPaths + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()

            await MainActor.run {
                isRunningAction = false
                runningActionLabel = ""
                statusBanner = "已完成 \(targetDate) 提炼并更新时段状态"
                reloadTimeline()
            }
        }
    }

    private func runDailyTimelineBuilder() {
        isRunningAction = true
        runningActionLabel = "正在导出 \(activeDate) 时间线汇总文稿..."
        let targetDate = selectedDate == "ALL" ? nil : activeDate
        Task.detached(priority: .userInitiated) {
            let root = AppPaths.workspaceRootDir
            let venvPy = root.appendingPathComponent(".venv/bin/python")
            let pyURL = FileManager.default.fileExists(atPath: venvPy.path)
                ? venvPy
                : URL(fileURLWithPath: "/usr/bin/python3")
            let script = root.appendingPathComponent("scripts/build_daily_timeline.py")
            let proc = Process()
            proc.executableURL = pyURL
            var args = [script.path]
            if let targetDate {
                args.append(contentsOf: ["--date", targetDate])
            }
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let timelinesDir = root.appendingPathComponent("outputs/daily_timelines")
            await MainActor.run {
                isRunningAction = false
                runningActionLabel = ""
                statusBanner = output.isEmpty ? "已导出每日时间线汇总包" : output.components(separatedBy: "\n").last
                NSWorkspace.shared.open(timelinesDir)
            }
        }
    }

    private func retranscribeWithQwen(audioURL: URL, entry: TimelineEntry) {
        isRunningAction = true
        runningActionLabel = "正在使用 Qwen3-ASR 1.7B 重新转录 \(entry.displayTitle)..."
        let outDir = settings.effectiveOutputDir
        Task.detached(priority: .userInitiated) {
            let root = AppPaths.workspaceRootDir
            let venvPy = root.appendingPathComponent(".venv/bin/python")
            let pyURL = FileManager.default.fileExists(atPath: venvPy.path)
                ? venvPy
                : URL(fileURLWithPath: "/usr/bin/python3")
            let script = root.appendingPathComponent("scripts/qwen3_asr_transcribe.py")
            let proc = Process()
            proc.executableURL = pyURL
            proc.arguments = [script.path, "--input", audioURL.path]
            try? proc.run()
            proc.waitUntilExit()

            let qwenTxt = audioURL.deletingPathExtension().appendingPathExtension("qwen3.txt")
            let protocolsDir = outDir.appendingPathComponent("protocols", isDirectory: true)
            try? FileManager.default.createDirectory(at: protocolsDir, withIntermediateDirectories: true)
            let destTxt = protocolsDir.appendingPathComponent("\(entry.id).txt")
            if FileManager.default.fileExists(atPath: qwenTxt.path) {
                if !FileManager.default.fileExists(atPath: destTxt.path) {
                    try? FileManager.default.copyItem(at: qwenTxt, to: destTxt)
                }
            }
            await MainActor.run {
                isRunningAction = false
                runningActionLabel = ""
                statusBanner = "已完成 Qwen3-ASR 1.7B 转录：\(entry.displayTitle)"
                reloadTimeline()
            }
        }
    }

    // MARK: - Date Formatting Helpers

    private static func todayDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private struct DateDisplayParts {
        let dayNumber: String
        let weekdayName: String
        let yearMonthLabel: String
        let relativeLabel: String
    }

    private static func parseDateDisplay(_ dateStr: String) -> DateDisplayParts {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: dateStr) else {
            return DateDisplayParts(dayNumber: "--", weekdayName: "全部日期", yearMonthLabel: dateStr, relativeLabel: "历史")
        }
        let cal = Calendar.current
        let day = String(format: "%02d", cal.component(.day, from: date))
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let wdIdx = max(1, min(7, cal.component(.weekday, from: date))) - 1

        let rel = if cal.isDateInToday(date) {
            "今天"
        } else if cal.isDateInYesterday(date) {
            "昨天"
        } else {
            "\(month)月\(day)日"
        }
        return DateDisplayParts(
            dayNumber: day,
            weekdayName: weekdays[wdIdx],
            yearMonthLabel: "\(year)年 \(month)月",
            relativeLabel: rel,
        )
    }

    private struct DayPillItem {
        let dateString: String
        let dayNumber: String
        let hasRecords: Bool
    }

    private static func buildRecentSevenDays(around centerDateStr: String, available: Set<String>) -> [DayPillItem] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let baseDate = df.date(from: centerDateStr) ?? Date()
        let cal = Calendar.current
        return (-5 ... 1).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: baseDate) else { return nil }
            let ds = df.string(from: d)
            let dayNum = String(format: "%02d", cal.component(.day, from: d))
            return DayPillItem(dateString: ds, dayNumber: dayNum, hasRecords: available.contains(ds))
        }
    }
}

// MARK: - Timeline Scanner, Voice-Memo Clusterer & Digest Loader

enum TimelineScanner {
    private static let stampRegex = try? NSRegularExpression(pattern: #"^(\d{8})_(\d{4,6})(?:_(.+))?$"#)
    private static let hexSuffixRegex = try? NSRegularExpression(pattern: #"_[0-9a-fA-F]{8}$"#)
    private static let rawAudioOnlySlugRegex = try? NSRegularExpression(pattern: #"^\d{8}_\d{6}$"#)
    private static let speakerBracketRegex = try? NSRegularExpression(pattern: #"\]\s*(?:\[([^\]]+)\]|([^:\n]{1,20})):"#)

    static func loadDigests(outputDir: URL) -> [String: DailyTimelineDigest] {
        let timelinesDir = outputDir.appendingPathComponent("daily_timelines", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: timelinesDir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var out: [String: DailyTimelineDigest] = [:]
        let decoder = JSONDecoder()
        for url in urls where url.lastPathComponent.hasSuffix("_ai_digest.json") {
            if let data = try? Data(contentsOf: url),
               let digest = try? decoder.decode(DailyTimelineDigest.self, from: data) {
                out[digest.date] = digest
            }
        }
        return out
    }

    static func loadUserNotes(outputDir: URL) -> [String: String] {
        let notesURL = outputDir
            .appendingPathComponent("daily_timelines", isDirectory: true)
            .appendingPathComponent("user_notes.json")
        guard let data = try? Data(contentsOf: notesURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func saveUserNotes(_ notes: [String: String], outputDir: URL) {
        let dir = outputDir.appendingPathComponent("daily_timelines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notesURL = dir.appendingPathComponent("user_notes.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(notes) {
            try? data.write(to: notesURL, options: .atomic)
        }
    }

    static func scan(
        outputDir: URL,
        recordingsDir: URL,
        digestsByDate: [String: DailyTimelineDigest],
        userNotes: [String: String],
    ) -> [TimelineEntry] {
        let fm = FileManager.default
        let protocolsDir = outputDir.appendingPathComponent("protocols", isDirectory: true)
        let altRecordingsDir = outputDir.appendingPathComponent("recordings", isDirectory: true)

        var protocolFiles: [String: URL] = [:]
        for dir in [protocolsDir, outputDir] {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
            ) else { continue }
            for url in urls where ["txt", "md"].contains(url.pathExtension.lowercased()) {
                let stem = url.deletingPathExtension().lastPathComponent
                if stem.hasPrefix(".") || stem.hasSuffix("_timeline") || stem.hasSuffix("_bundle") { continue }
                let normalizedStem = stem.hasSuffix(".qwen3")
                    ? String(stem.dropLast(".qwen3".count))
                    : stem
                if protocolFiles[normalizedStem] == nil || stem.hasSuffix(".qwen3") {
                    protocolFiles[normalizedStem] = url
                }
            }
        }

        var audioFiles: [String: URL] = [:]
        var speakerSidecars: [String: [String]] = [:]
        for dir in [altRecordingsDir, recordingsDir] {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
            ) else { continue }
            for url in urls {
                let name = url.lastPathComponent
                if name.hasSuffix("_speakers.json") {
                    let key = String(name.dropLast("_speakers.json".count))
                    if let names = parseSpeakerNames(from: url), !names.isEmpty {
                        speakerSidecars[key] = names
                    }
                    continue
                }
                guard ["wav", "m4a"].contains(url.pathExtension.lowercased()) else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                if stem.hasSuffix("_16k") { continue }
                let key = normalizeAudioKey(stem)
                if audioFiles[key] == nil || stem.hasSuffix("_mix") {
                    audioFiles[key] = url
                }
            }
        }

        let allKeys = Set(protocolFiles.keys).union(audioFiles.keys)
        var rawItems: [TimelineEntry] = []

        for key in allKeys {
            let pURL = protocolFiles[key]
            if pURL == nil, let rx = rawAudioOnlySlugRegex {
                let range = NSRange(key.startIndex ..< key.endIndex, in: key)
                if rx.firstMatch(in: key, range: range) != nil {
                    continue
                }
            }
            let aURL = audioFiles[key]
            let refURL = pURL ?? aURL
            let mtime = (try? refURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let (dateStr, timeStr, rawTitle) = parseSlug(key, fallbackDate: mtime)

            var preview = ""
            var fullText = ""
            if let pURL, let text = try? String(contentsOf: pURL, encoding: .utf8) {
                fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = fullText
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                preview = lines.prefix(6).joined(separator: "\n")
            }

            let dur = aURL.flatMap { audioDurationSeconds(for: $0) }
                ?? estimateDurationFromTranscript(fullText)
            var spks = speakerSidecars[key] ?? []
            if spks.isEmpty, !fullText.isEmpty {
                spks = extractSpeakersFromTranscript(fullText)
            }

            let entryDigest = digestsByDate[dateStr]?.entries?[key]
            let customNote = userNotes[key]

            rawItems.append(
                TimelineEntry(
                    id: key,
                    dateString: dateStr,
                    timeString: timeStr,
                    rawTitle: rawTitle,
                    protocolURL: pURL,
                    audioURL: aURL,
                    transcriptPreview: preview,
                    fullTranscriptText: fullText,
                    fileDate: mtime,
                    durationSeconds: dur,
                    speakerNames: spks,
                    aiDigest: entryDigest,
                    userNote: customNote,
                    subClips: [],
                    foldedFragmentCount: 0,
                    unrefinedSlugs: entryDigest == nil ? [key] : [],
                ),
            )
        }

        return clusterVoiceMemos(rawItems, userNotes: userNotes)
    }

    /// Groups consecutive short `语音输入速记` clips within a 12-minute window into consolidated
    /// personal-focus sessions (keeping refined and unrefined items separated) and folds out
    /// AI meta-prompts / trivial `<22 char` fragments.
    private static func clusterVoiceMemos(_ items: [TimelineEntry], userNotes: [String: String]) -> [TimelineEntry] {
        let sortedAsc = items.sorted { $0.sortKey < $1.sortKey }
        var result: [TimelineEntry] = []
        var currentCluster: [TimelineEntry] = []

        func flushCluster() {
            guard !currentCluster.isEmpty else { return }
            if let merged = mergeVoiceMemoCluster(currentCluster, userNotes: userNotes) {
                result.append(merged)
            }
            currentCluster.removeAll()
        }

        for item in sortedAsc {
            if !item.isVoiceMemoFocus || item.durationSeconds >= 180 {
                flushCluster()
                result.append(item)
                continue
            }

            if let last = currentCluster.last {
                let sameDate = last.dateString == item.dateString
                let sameRefinedState = last.isRefined == item.isRefined
                let minsDiff = abs(minutesSinceMidnight(item.timeString) - minutesSinceMidnight(last.timeString))
                if sameDate, sameRefinedState, minsDiff <= 12 {
                    currentCluster.append(item)
                } else {
                    flushCluster()
                    currentCluster = [item]
                }
            } else {
                currentCluster = [item]
            }
        }
        flushCluster()

        return result.sorted { $0.sortKey > $1.sortKey }
    }

    private static func isTrivialOrMetaPrompt(_ entry: TimelineEntry) -> Bool {
        if entry.aiDigest?.densityLabel == "碎片输入" {
            return true
        }
        let metaKeywords = ["弹通知", "状态栏", "提示词", "界面拉窄", "增加更多的通知", "语音输入法"]
        for kw in metaKeywords where entry.fullTranscriptText.contains(kw) {
            return true
        }
        let stripped = entry.fullTranscriptText
            .replacingOccurrences(of: #"^\[[^\]]+\]\s*(?:\[[^\]]+\]|[^:]+):\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.count < 22 && (entry.aiDigest?.highlightsCount ?? 0) == 0
    }

    private static func mergeVoiceMemoCluster(_ cluster: [TimelineEntry], userNotes: [String: String]) -> TimelineEntry? {
        guard let first = cluster.first else { return nil }
        let substantive = cluster.filter { !isTrivialOrMetaPrompt($0) }
        let trivialCount = cluster.count - substantive.count

        // If every clip in this cluster is a trivial fragment / AI meta-prompt and has no user note, skip cluttering the main stream
        let clusterNotes = cluster.compactMap { userNotes[$0.id] }.filter { !$0.isEmpty }
        if substantive.isEmpty, clusterNotes.isEmpty {
            return nil
        }

        let activeItems = substantive.isEmpty ? cluster : substantive
        let subClips: [TimelineSubClip] = cluster.map { item in
            TimelineSubClip(
                id: item.id,
                timeString: item.hourMinuteString,
                durationSeconds: item.durationSeconds,
                summary: item.narrativeSummary,
                transcriptText: item.fullTranscriptText,
                audioURL: item.audioURL,
                protocolURL: item.protocolURL,
                isTrivialFragment: isTrivialOrMetaPrompt(item),
            )
        }

        if cluster.count == 1, let single = substantive.first {
            return single
        }

        let totalDur = cluster.reduce(0.0) { $0 + $1.durationSeconds }
        var combinedHighlights: [String] = []
        var combinedTodos: [String] = []
        var combinedTags: [String] = []
        for item in activeItems {
            for h in item.highlights where !combinedHighlights.contains(h) {
                combinedHighlights.append(h)
            }
            for t in item.todos where !combinedTodos.contains(t) {
                combinedTodos.append(t)
            }
            for tg in item.tags where !combinedTags.contains(tg) {
                combinedTags.append(tg)
            }
        }

        let combinedSummary: String = if activeItems.count == 1 {
            activeItems[0].narrativeSummary
        } else {
            activeItems.map { item -> String in
                item.narrativeSummary
                    .replacingOccurrences(of: "你通过语音速记", with: "")
                    .replacingOccurrences(of: "你主动语音输入当前关注重点：", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "，。； "))
            }
            .prefix(3)
            .joined(separator: "；") + "。"
        }

        let combinedTranscript = cluster.map { item in
            "--- [\(item.hourMinuteString)] \(item.id) ---\n\(item.fullTranscriptText)"
        }.joined(separator: "\n\n")

        let allClusterRefined = activeItems.allSatisfy(\.isRefined)
        let pendingSlugs = activeItems.filter { !$0.isRefined }.map(\.id)

        let mergedDigest: TimelineEntryDigest? = allClusterRefined
            ? TimelineEntryDigest(
                shortTitle: activeItems.first?.displayTitle ?? first.displayTitle,
                summary: combinedSummary.hasPrefix("你") ? combinedSummary : "你围绕当前关注重点连续梳理：\(combinedSummary)",
                densityLabel: "当前关注",
                highlightsCount: combinedHighlights.count,
                tags: combinedTags,
                highlights: combinedHighlights,
                todos: combinedTodos,
            )
            : nil

        return TimelineEntry(
            id: first.id,
            dateString: first.dateString,
            timeString: first.timeString,
            rawTitle: first.rawTitle,
            protocolURL: activeItems.first?.protocolURL ?? first.protocolURL,
            audioURL: activeItems.first?.audioURL ?? first.audioURL,
            transcriptPreview: activeItems.first?.transcriptPreview ?? first.transcriptPreview,
            fullTranscriptText: combinedTranscript,
            fileDate: first.fileDate,
            durationSeconds: totalDur,
            speakerNames: ["Kenny"],
            aiDigest: mergedDigest,
            userNote: clusterNotes.first,
            subClips: subClips,
            foldedFragmentCount: trivialCount,
            unrefinedSlugs: pendingSlugs,
        )
    }

    private static func minutesSinceMidnight(_ timeStr: String) -> Int {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    private static func normalizeAudioKey(_ stem: String) -> String {
        for suffix in ["_mix", "_app", "_mic"] where stem.hasSuffix(suffix) {
            return String(stem.dropLast(suffix.count))
        }
        return stem
    }

    private static func parseSlug(_ key: String, fallbackDate: Date) -> (String, String, String) {
        let ns = key as NSString
        if let regex = stampRegex,
           let match = regex.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)) {
            let dRaw = ns.substring(with: match.range(at: 1))
            let tRaw = ns.substring(with: match.range(at: 2))
            let dateStr = "\(dRaw.prefix(4))-\(dRaw.dropFirst(4).prefix(2))-\(dRaw.suffix(2))"
            let hh = tRaw.prefix(2)
            let mm = tRaw.dropFirst(2).prefix(2)
            let ss = tRaw.count >= 6 ? String(tRaw.suffix(2)) : "00"
            let timeStr = "\(hh):\(mm):\(ss)"

            var title = "语音记录"
            if match.range(at: 3).location != NSNotFound {
                var raw = ns.substring(with: match.range(at: 3))
                if let hexRx = hexSuffixRegex {
                    raw = hexRx.stringByReplacingMatches(
                        in: raw,
                        range: NSRange(location: 0, length: (raw as NSString).length),
                        withTemplate: "",
                    )
                }
                raw = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty { title = raw }
            }
            return (dateStr, timeStr, title)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        return (df.string(from: fallbackDate), tf.string(from: fallbackDate), key)
    }

    private static func audioDurationSeconds(for url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return nil }
        return Double(file.length) / sr
    }

    private static func estimateDurationFromTranscript(_ text: String) -> TimeInterval {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})\]"#) else { return 0 }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return 0 }
        let mm = Double(ns.substring(with: last.range(at: 1))) ?? 0
        let ss = Double(ns.substring(with: last.range(at: 2))) ?? 0
        return mm * 60 + ss + 8
    }

    private static func parseSpeakerNames(from url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var seen: [String] = []
        for item in arr {
            if let name = item["autoName"] as? String ?? item["label"] as? String,
               !name.isEmpty, !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen
    }

    private static func extractSpeakersFromTranscript(_ text: String) -> [String] {
        guard let rx = speakerBracketRegex else { return [] }
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen: [String] = []
        for m in matches {
            let r1 = m.range(at: 1)
            let r2 = m.range(at: 2)
            let raw = r1.location != NSNotFound ? ns.substring(with: r1) : (r2.location != NSNotFound ? ns.substring(with: r2) : "")
            let name = raw.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.contains(name) {
                seen.append(name)
            }
        }
        return seen
    }
}
