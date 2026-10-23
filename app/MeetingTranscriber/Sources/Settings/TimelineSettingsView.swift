import AppKit
import AVFoundation
import SwiftUI

// MARK: - AI Digest & User Notes Models

struct TimelineEntryDigest: Codable {
    var shortTitle: String?
    var summary: String?
    var densityLabel: String?
    var highlightsCount: Int?
    var tags: [String]?
    var highlights: [String]?
    var todos: [String]?
}

struct DailyTimelineDigest: Codable {
    var date: String
    var generatedAt: String?
    var model: String?
    var dailyQuote: String?
    var dailyOverview: String?
    var totalHighlightsCount: Int?
    var entries: [String: TimelineEntryDigest]?
}

struct TimelineEntry: Identifiable {
    let id: String
    let dateString: String
    let timeString: String
    let hourMinuteString: String
    let hourOfDay: Int
    let sortKey: String
    let rawTitle: String
    let transcriptURL: URL?
    let audioURL: URL?
    let micAudioURL: URL?
    let appAudioURL: URL?
    let durationSeconds: Double
    let transcriptText: String
    let speakers: [String]
    let aiDigest: TimelineEntryDigest?
    let userNote: String?

    var isVoiceMemoFocus: Bool {
        rawTitle.contains("语音输入速记")
            || id.contains("语音输入速记")
            || aiDigest?.densityLabel == "当前关注"
            || (appAudioURL == nil && durationSeconds < 120 && speakers.count <= 1)
    }

    var displayTitle: String {
        if let short = aiDigest?.shortTitle, !short.isEmpty {
            return short
        }
        return rawTitle
    }

    var categoryBadgeText: String {
        if isVoiceMemoFocus {
            return "📌 当前关注 · 主动语音速记"
        }
        if appAudioURL != nil && micAudioURL != nil {
            return "已记录 · \(rawTitle)"
        }
        return "已记录 · \(rawTitle)"
    }

    var formattedDurationShort: String {
        guard durationSeconds > 0 else { return "1 分钟" }
        let total = Int(durationSeconds.rounded())
        let mins = total / 60
        let secs = total % 60
        if mins >= 1 {
            return secs >= 30 ? "\(mins + 1) 分钟" : "\(mins) 分钟"
        }
        return "\(max(1, secs)) 秒"
    }

    var formattedDurationExact: String {
        guard durationSeconds > 0 else { return "未知时长" }
        let total = Int(durationSeconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return mins > 0 ? "\(mins)分\(String(format: "%02d", secs))秒" : "\(secs)秒"
    }

    var audaySummaryText: String {
        if let s = aiDigest?.summary, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        let cleanLines = transcriptText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !cleanLines.isEmpty else {
            return "已捕获现场录音，点击下方「AI 提炼摘要」或「Qwen3-ASR 重转」生成结构化总结。"
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
            return "你主动记录了关注重点：\(String(joined.prefix(110)))"
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
        return "轻量速记"
    }

    var highlightsCount: Int {
        aiDigest?.highlightsCount ?? aiDigest?.highlights?.count ?? (isVoiceMemoFocus ? 1 : 0)
    }

    var highlights: [String] {
        aiDigest?.highlights ?? []
    }

    var todos: [String] {
        aiDigest?.todos ?? []
    }

    var tags: [String] {
        aiDigest?.tags ?? (isVoiceMemoFocus ? ["当前关注", "主动速记"] : [])
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

    // Auday Warm Editorial Palette
    private var canvasBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.09)
            : Color(red: 0.965, green: 0.961, blue: 0.941) // #F6F5F0
    }

    private var cardSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.15, green: 0.15, blue: 0.14)
            : Color.white
    }

    private var focusCardSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.20, green: 0.17, blue: 0.11)
            : Color(red: 1.0, green: 0.985, blue: 0.935) // Warm Amber Ivory
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

    private var filteredEntries: [TimelineEntry] {
        let base: [TimelineEntry]
        switch categoryFilter {
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

    private var totalRecordingMinutes: Int {
        let sum = dateFilteredEntries.reduce(0.0) { $0 + $1.durationSeconds }
        return max(1, Int((sum / 60.0).rounded()))
    }

    private var totalHighlightsCount: Int {
        if let d = digestsByDate[activeDate], let c = d.totalHighlightsCount, c > 0 {
            return c
        }
        return dateFilteredEntries.reduce(0) { $0 + $1.highlightsCount }
    }

    private var focusMemoCount: Int {
        dateFilteredEntries.filter(\.isVoiceMemoFocus).count
    }

    private var meetingSessionCount: Int {
        dateFilteredEntries.filter { !$0.isVoiceMemoFocus }.count
    }

    var body: some View {
        ZStack {
            canvasBackground.ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        audayTopHeader
                            .id("TIMELINE_TOP")
                        dayPillStrip
                        hourlyDensityChart
                        if isRunningAction || statusBanner != nil {
                            liveActivityBanner
                        }
                        dailyHeroReviewCard
                        timeSlotStreamSection
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
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

    // MARK: - 1. Top Editorial Header

    private var audayTopHeader: some View {
        let parts = Self.parseDateDisplay(activeDate)
        return HStack(alignment: .bottom, spacing: 14) {
            Text(parts.dayNumber)
                .font(.system(size: 46, weight: .bold, design: .serif))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(parts.weekday)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(parts.yearMonth)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 5)

            Text("\(parts.relativeLabel) —— 记忆 \(totalRecordingMinutes) 分钟")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.bottom, 6)

            Spacer()

            HStack(spacing: 8) {
                Button {
                    runAgyTimelineSummarizer()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("AI 提炼 (agy)")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.15, blue: 0.13),
                                Color(red: 0.20, green: 0.26, blue: 0.22),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing,
                        ),
                        in: Capsule(),
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isRunningAction)

                Button {
                    runDailyTimelineBuilder()
                } label: {
                    Label("导出汇总", systemImage: "doc.richtext")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isRunningAction)

                Button {
                    NSWorkspace.shared.open(settings.effectiveOutputDir)
                } label: {
                    Label("目录", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    reloadTimeline()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(7)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("刷新时间线")
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 4)
        }
    }

    // MARK: - 2. 7-Day Circular Pill Selector

    private var dayPillStrip: some View {
        let stripDays = Self.buildRecentSevenDays(around: activeDate, available: Set(entries.map(\.dateString)))
        return HStack(spacing: 12) {
            ForEach(stripDays, id: \.dateString) { item in
                let isSelected = selectedDate != "ALL" && item.dateString == activeDate
                Button {
                    selectedDate = item.dateString
                } label: {
                    VStack(spacing: 4) {
                        Text(item.dayNumber)
                            .font(.system(size: 15, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white : (item.hasRecords ? Color.primary : Color.secondary.opacity(0.55)))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color(red: 0.11, green: 0.12, blue: 0.11) : Color.clear),
                            )
                        Circle()
                            .fill(item.hasRecords ? (isSelected ? Color.orange : Color.primary.opacity(0.45)) : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                selectedDate = (selectedDate == "ALL") ? Self.todayDateString() : "ALL"
            } label: {
                Text(selectedDate == "ALL" ? "仅看当天" : "全部日期 (\(entries.count))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selectedDate == "ALL" ? Color.white : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(selectedDate == "ALL" ? Color.accentColor : Color.primary.opacity(0.06)),
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 3. 24-Hour Activity Density Bar Chart

    private var hourlyDensityChart: some View {
        let buckets = computeHourlyBuckets()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    let info = buckets[hour]
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: 6, height: 28)
                            if info.minutes > 0 {
                                let ratio = min(1.0, max(0.22, info.minutes / 30.0))
                                Capsule()
                                    .fill(
                                        info.hasFocusMemo && info.minutes < 5
                                            ? Color.orange
                                            : Color(red: 0.14, green: 0.17, blue: 0.15),
                                    )
                                    .frame(width: 6, height: CGFloat(28.0 * ratio))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30)

            HStack {
                Text("00").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("06").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("12").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("18").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("24").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 4. Live Activity & Status Banner (Auday Screenshot 4 Style)

    private var liveActivityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if isRunningAction {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                }
                Text(isRunningAction ? runningActionLabel : (statusBanner ?? ""))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if !isRunningAction {
                    Button("知道了") {
                        statusBanner = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            if isRunningAction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 5)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange, Color.green],
                                    startPoint: .leading,
                                    endPoint: .trailing,
                                ),
                            )
                            .frame(width: geo.size.width * 0.65, height: 5)
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color(red: 0.93, green: 0.92, blue: 0.89)),
        )
    }

    // MARK: - 5. Dark Hero "每日回顾" Card (Auday Screenshot 2 & 3 Style)

    private var dailyHeroReviewCard: some View {
        let digest = digestsByDate[activeDate]
        let quote = digest?.dailyQuote ?? "把复杂的事拆小，才看得见路。"
        let overview = digest?.dailyOverview
            ?? "已归档 \(filteredEntries.count) 段今日会议与语音速记，点击右上角「AI 提炼」即可由 agy Gemini 4 High 生成全天洞察与时段摘要。"

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.08, blue: 0.07),
                            Color(red: 0.12, green: 0.14, blue: 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                )

            // Dot-matrix botanical/waveform illustration (Auday signature art)
            dotMatrixHeroArt
                .frame(width: 190, height: 150)
                .opacity(0.85)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("每日回顾")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                    if let model = digest?.model {
                        Text("· \(model)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.green.opacity(0.85))
                    }
                    Spacer()
                }

                Text("“\(quote)”")
                    .font(.system(size: 21, weight: .bold, design: .serif))
                    .foregroundStyle(Color.white)
                    .padding(.trailing, 120)

                Text(overview)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineSpacing(4)
                    .padding(.trailing, 40)

                HStack(spacing: 14) {
                    Label("已录音 \(totalRecordingMinutes) 分钟", systemImage: "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))

                    Label("\(totalHighlightsCount) 个重点", systemImage: "sparkle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.98, green: 0.80, blue: 0.32))

                    if focusMemoCount > 0 {
                        Label("\(focusMemoCount) 条个人当前关注", systemImage: "pin.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.64, blue: 0.26))
                    }

                    Spacer()

                    Button {
                        runAgyTimelineSummarizer()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("刷新回顾")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunningAction)
                }
                .padding(.top, 4)
            }
            .padding(22)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 6)
    }

    private var dotMatrixHeroArt: some View {
        Canvas { context, size in
            let cols = 16
            let rows = 12
            let spacingX = size.width / CGFloat(cols + 2)
            let spacingY = size.height / CGFloat(rows + 2)
            let center = CGPoint(x: size.width * 0.58, y: size.height * 0.48)

            for r in 0 ..< rows {
                for c in 0 ..< cols {
                    let x = CGFloat(c + 1) * spacingX
                    let y = CGFloat(r + 1) * spacingY
                    let dx = (x - center.x) / (size.width * 0.42)
                    let dy = (y - center.y) / (size.height * 0.42)
                    let dist = sqrt(dx * dx + dy * dy)
                    let angle = atan2(dy, dx)
                    let petal = 0.55 + 0.32 * cos(angle * 5.0)
                    if dist < petal {
                        let dotRadius: CGFloat = dist < 0.22 ? 2.4 : (dist < petal * 0.75 ? 2.0 : 1.3)
                        let color: Color = if dist < 0.20 {
                            Color(red: 0.96, green: 0.78, blue: 0.30)
                        } else if (r + c).isMultiple(of: 3) {
                            Color(red: 0.36, green: 0.82, blue: 0.54).opacity(0.75)
                        } else {
                            Color.white.opacity(max(0.18, 0.72 - dist * 0.5))
                        }
                        let rect = CGRect(
                            x: x - dotRadius,
                            y: y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2,
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
        }
    }

    // MARK: - 6. "当日时段" Time-Slot Stream

    private var timeSlotStreamSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("当日时段")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    filterChip(title: "全部 (\(dateFilteredEntries.count))", key: "ALL", tint: .primary)
                    filterChip(title: "👥 会议评审 (\(meetingSessionCount))", key: "MEETING", tint: .indigo)
                    filterChip(title: "📌 个人关注 (\(focusMemoCount))", key: "VOICE_MEMO", tint: .orange)
                }
                .padding(.leading, 6)

                Spacer()

                Button {
                    sortChronological.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sortChronological ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(sortChronological ? "按时间正序" : "最新优先")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
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

    private func filterChip(title: String, key: String, tint: Color) -> some View {
        let isSelected = categoryFilter == key
        return Button {
            categoryFilter = key
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : tint.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? (key == "ALL" ? Color(red: 0.16, green: 0.17, blue: 0.16) : tint) : tint.opacity(0.09)),
                )
        }
        .buttonStyle(.plain)
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.clock")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("该日期暂无录音与时间线归档")
                .font(.system(size: 15, weight: .semibold))
            Text("进入企微/腾讯会议或使用 DJI Mic 语音输入时，系统将静默收音并通过 Qwen3-ASR 与 agy Gemini 4 High 自动生成时段摘要。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func audayTimelineRow(entry: TimelineEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Left Time Axis (Auday Screenshot 2 & 3 style)
            VStack(spacing: 6) {
                Text(entry.hourMinuteString)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(entry.isVoiceMemoFocus ? Color.orange : Color.secondary)

                ZStack {
                    Circle()
                        .stroke(
                            entry.isVoiceMemoFocus ? Color.orange : Color.primary.opacity(0.35),
                            lineWidth: 1.8,
                        )
                        .frame(width: 9, height: 9)
                    if entry.isVoiceMemoFocus {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 4.5, height: 4.5)
                    }
                }

                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 52)
            .padding(.top, 14)

            // Right Editorial Session Card
            audaySessionCard(entry)
                .padding(.bottom, 16)
        }
    }

    private func audaySessionCard(_ entry: TimelineEntry) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)
        let isEditingThisNote = editingNoteID == entry.id

        return VStack(alignment: .leading, spacing: 11) {
            sessionCardHeader(entry)
            sessionCardSummary(entry)
            if let note = entry.userNote, !note.isEmpty, !isEditingThisNote {
                sessionCardNoteBanner(entry: entry, note: note)
            }
            if isEditingThisNote {
                sessionCardNoteEditor(entry)
            }
            sessionCardFooter(entry: entry, isExpanded: isExpanded)
            if isExpanded {
                Divider().padding(.vertical, 2)
                expandedDrawerView(entry)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sessionCardBackground(entry))
        .overlay(sessionCardBorder(entry))
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    private func sessionCardBackground(_ entry: TimelineEntry) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(entry.isVoiceMemoFocus ? focusCardSurface : cardSurface)
    }

    private func sessionCardBorder(_ entry: TimelineEntry) -> some View {
        let strokeColor = entry.isVoiceMemoFocus ? Color.orange.opacity(0.32) : Color.primary.opacity(0.07)
        let width: CGFloat = entry.isVoiceMemoFocus ? 1.4 : 1.0
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(strokeColor, lineWidth: width)
    }

    private func sessionCardHeader(_ entry: TimelineEntry) -> some View {
        let badgeTint: Color = entry.isVoiceMemoFocus ? .orange : .indigo
        return HStack(alignment: .center, spacing: 8) {
            Text(entry.categoryBadgeText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(badgeTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badgeTint.opacity(0.12), in: Capsule())

            if !entry.isVoiceMemoFocus {
                Text(entry.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
            }

            Spacer()

            Text(entry.formattedDurationShort)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func sessionCardSummary(_ entry: TimelineEntry) -> some View {
        Text(entry.audaySummaryText)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .lineSpacing(5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sessionCardNoteBanner(entry: TimelineEntry, note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.green)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("我的备注 / 重点补充")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.green)
                Text(note)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("修改") {
                editingNoteID = entry.id
                noteDraft = note
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.green.opacity(0.25), lineWidth: 1),
                ),
        )
    }

    private func sessionCardNoteEditor(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📌 为该时段添加备注或重点说明（将持久保存并供 Agent 总结参考）：")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("输入你的备注、结论修正或重点关注事项...", text: $noteDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 5)
            HStack(spacing: 8) {
                Button("保存备注") {
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

                if entry.userNote != nil {
                    Button("清空") {
                        saveUserNote(for: entry.id, text: "")
                        editingNoteID = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sessionCardFooter(entry: TimelineEntry, isExpanded: Bool) -> some View {
        let accentColor: Color = entry.isVoiceMemoFocus ? .orange : .indigo
        let dColor = densityColor(entry.densityLabel)
        return HStack(spacing: 8) {
            Text(entry.densityLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(dColor.opacity(0.12), in: Capsule())

            sessionCardMetadataPills(entry)

            Spacer()

            Button {
                if editingNoteID == entry.id {
                    editingNoteID = nil
                } else {
                    editingNoteID = entry.id
                    noteDraft = entry.userNote ?? ""
                }
            } label: {
                Label(entry.userNote == nil ? "备注" : "改备注", systemImage: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedIDs.remove(entry.id)
                    } else {
                        expandedIDs.insert(entry.id)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(isExpanded ? "收起详情" : "重点与逐字稿")
                    Image(systemName: isExpanded ? "chevron.up" : "arrow.up.right")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func sessionCardMetadataPills(_ entry: TimelineEntry) -> some View {
        if !entry.speakers.isEmpty {
            let spkText = entry.speakers.count <= 3
                ? entry.speakers.joined(separator: "、")
                : "\(entry.speakers.prefix(3).joined(separator: "、")) 等\(entry.speakers.count)人"
            Label(spkText, systemImage: "person.2")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }

        if entry.highlightsCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "sparkle")
                Text("\(entry.highlightsCount) 个重点")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(red: 0.82, green: 0.48, blue: 0.04))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.18), in: Capsule())
        }

        if !entry.todos.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "checklist")
                Text("\(entry.todos.count) 项待办")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.red)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.10), in: Capsule())
        }

        ForEach(entry.tags.prefix(3), id: \.self) { tag in
            Text("#\(tag)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func expandedDrawerView(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Structured Highlights
            if !entry.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("✦ 核心重点结论")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0.80, green: 0.45, blue: 0.02))
                    ForEach(entry.highlights, id: \.self) { hl in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .fontWeight(.bold)
                                .foregroundStyle(Color.orange)
                            Text(hl)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            // 2. Actionable Todos
            if !entry.todos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("☑ 双向待办与承诺")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.red)
                    ForEach(entry.todos, id: \.self) { td in
                        let isMine = td.contains("我方") || td.contains("Kenny")
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: isMine ? "person.crop.circle.badge.exclamationmark" : "arrow.turn.down.right")
                                .font(.system(size: 11))
                                .foregroundStyle(isMine ? Color.red : Color.blue)
                                .padding(.top, 2)
                            Text(td)
                                .font(.system(size: 12, weight: isMine ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            // 3. Audio Controls & Action Bar
            HStack(spacing: 8) {
                if let audioURL = entry.audioURL {
                    let playingThis = audioPlayer.playingEntryID == entry.id && audioPlayer.isPlaying
                    Button {
                        audioPlayer.togglePlay(entryID: entry.id, url: audioURL)
                    } label: {
                        Label(
                            playingThis ? "停止播放 (\(entry.formattedDurationExact))" : "播放录音 (\(entry.formattedDurationExact))",
                            systemImage: playingThis ? "stop.fill" : "play.fill",
                        )
                    }
                    .controlSize(.small)

                    Button("定位音频") {
                        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
                    }
                    .controlSize(.small)

                    Button("Qwen3-ASR 重转") {
                        retranscribeWithQwen(audioURL: audioURL, entry: entry)
                    }
                    .controlSize(.small)
                    .disabled(isRunningAction)
                }

                if let txtURL = entry.transcriptURL {
                    Button("打开逐字稿文件") {
                        NSWorkspace.shared.open(txtURL)
                    }
                    .controlSize(.small)
                }

                Button("单条 AI 重提炼") {
                    runAgyTimelineSummarizer(singleSlug: entry.id)
                }
                .controlSize(.small)
                .disabled(isRunningAction)

                Spacer()
            }

            // 4. Raw Transcript Box
            if !entry.transcriptText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("📝 原始逐字稿 (\(entry.id))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(entry.transcriptText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 240)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func densityColor(_ label: String) -> Color {
        switch label {
        case "信息密集": Color.indigo
        case "当前关注": Color.orange
        case "信息适中": Color.teal
        default: Color.secondary
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
            let mins = max(0.8, entry.durationSeconds / 60.0)
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
            stagingDir: AppPaths.recordingsDir,
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
        let outDir = settings.effectiveOutputDir
        TimelineScanner.saveUserNotes(userNotes, outputDir: outDir)
        reloadTimeline()
    }

    private func runAgyTimelineSummarizer(singleSlug: String? = nil) {
        isRunningAction = true
        runningActionLabel = singleSlug == nil
            ? "正在后台调用 agy (gemini-4-argon-high) 提炼 \(activeDate) 每日回顾与时段摘要..."
            : "正在后台调用 agy (gemini-4-argon-high) 提炼时段摘要..."
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
            var args = [script.path, "--date", targetDate, "--timeout", "90"]
            if let singleSlug {
                args.append(contentsOf: ["--slug", singleSlug])
            }
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            proc.waitUntilExit()

            await MainActor.run {
                isRunningAction = false
                runningActionLabel = ""
                statusBanner = "✨ 已通过 agy (gemini-4-argon-high) 更新 \(targetDate) 时段摘要与每日回顾"
                reloadTimeline()
            }
        }
    }

    private func runDailyTimelineBuilder() {
        isRunningAction = true
        runningActionLabel = "正在生成 \(activeDate) Markdown 时间线汇总包..."
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
        let weekday: String
        let yearMonth: String
        let relativeLabel: String
    }

    private static func parseDateDisplay(_ dateStr: String) -> DateDisplayParts {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let date = df.date(from: dateStr) ?? Date()
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let wdIdx = max(1, min(7, cal.component(.weekday, from: date))) - 1
        let rel = cal.isDateInToday(date) ? "今天" : (cal.isDateInYesterday(date) ? "昨天" : "\(month)月\(day)日")
        return DateDisplayParts(
            dayNumber: String(format: "%02d", day),
            weekday: weekdays[wdIdx],
            yearMonth: "\(year)年\(month)月",
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

// MARK: - Timeline Scanner & Digest Loader

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
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return dict
    }

    static func saveUserNotes(_ notes: [String: String], outputDir: URL) {
        let timelinesDir = outputDir.appendingPathComponent("daily_timelines", isDirectory: true)
        try? FileManager.default.createDirectory(at: timelinesDir, withIntermediateDirectories: true)
        let notesURL = timelinesDir.appendingPathComponent("user_notes.json")
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: notesURL, options: .atomic)
        }
    }

    static func scan(
        outputDir: URL,
        stagingDir: URL,
        digestsByDate: [String: DailyTimelineDigest] = [:],
        userNotes: [String: String] = [:],
    ) -> [TimelineEntry] {
        let fm = FileManager.default
        let protocolsSubdir = outputDir.appendingPathComponent("protocols", isDirectory: true)
        let recordingsSubdir = outputDir.appendingPathComponent("recordings", isDirectory: true)

        var textBySlug: [String: URL] = [:]
        for dir in [protocolsSubdir, outputDir] {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ext == "txt" || ext == "md" else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                let slug = name.hasSuffix(".qwen3") ? String(name.dropLast(".qwen3".count)) : name
                let normalizedSlug = normalizeAudioStem(slug)
                if textBySlug[normalizedSlug] == nil || ext == "md" || name.hasSuffix(".qwen3") {
                    textBySlug[normalizedSlug] = url
                }
            }
        }

        var mixBySlug: [String: URL] = [:]
        var micBySlug: [String: URL] = [:]
        var appBySlug: [String: URL] = [:]
        for dir in [recordingsSubdir, outputDir, stagingDir] {
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension.lowercased() == "wav" {
                let stem = url.deletingPathExtension().lastPathComponent
                let slug = normalizeAudioStem(stem)
                if stem.hasSuffix("_mic") || stem.hasSuffix("_mic_16k") {
                    if micBySlug[slug] == nil { micBySlug[slug] = url }
                } else if stem.hasSuffix("_app") || stem.hasSuffix("_app_16k") {
                    if appBySlug[slug] == nil { appBySlug[slug] = url }
                } else {
                    if mixBySlug[slug] == nil { mixBySlug[slug] = url }
                }
            }
        }

        // Collect minute prefixes (`YYYYMMDD_HHMM`) that already have a transcribed slug
        let transcribedMinutePrefixes = Set(
            textBySlug.keys.compactMap { slug -> String? in
                guard slug.count >= 13 else { return nil }
                return String(slug.prefix(13))
            },
        )

        let allSlugs = Set(textBySlug.keys).union(mixBySlug.keys).union(micBySlug.keys).union(appBySlug.keys)
        var results: [TimelineEntry] = []

        for slug in allSlugs {
            let nsSlug = slug as NSString
            let isRawAudioSlug = rawAudioOnlySlugRegex?.firstMatch(
                in: slug,
                range: NSRange(location: 0, length: nsSlug.length),
            ) != nil
            if isRawAudioSlug, textBySlug[slug] == nil {
                let minutePrefix = String(slug.prefix(13))
                if transcribedMinutePrefixes.contains(minutePrefix) {
                    continue
                }
            }

            let txtURL = textBySlug[slug]
            let micURL = micBySlug[slug]
            let appURL = appBySlug[slug]
            let primaryAudio = mixBySlug[slug] ?? micURL ?? appURL
            let (dateStr, timeStr, hmStr, hourInt, rawTitle) = parseSlug(slug, fallbackURL: txtURL ?? primaryAudio)
            let content = (txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = primaryAudio.map(audioDurationSeconds) ?? 0
            let speakers = extractSpeakers(from: content)
            let entryDigest = digestsByDate[dateStr]?.entries?[slug]

            results.append(
                TimelineEntry(
                    id: slug,
                    dateString: dateStr,
                    timeString: timeStr,
                    hourMinuteString: hmStr,
                    hourOfDay: hourInt,
                    sortKey: "\(dateStr)_\(timeStr)_\(slug)",
                    rawTitle: rawTitle,
                    transcriptURL: txtURL,
                    audioURL: primaryAudio,
                    micAudioURL: micURL,
                    appAudioURL: appURL,
                    durationSeconds: duration,
                    transcriptText: content,
                    speakers: speakers,
                    aiDigest: entryDigest,
                    userNote: userNotes[slug],
                ),
            )
        }

        return results.sorted { $0.sortKey > $1.sortKey }
    }

    private static func normalizeAudioStem(_ stem: String) -> String {
        for suffix in ["_mix_16k", "_app_16k", "_mic_16k", "_16k", "_mix", "_app", "_mic"] {
            if stem.hasSuffix(suffix) {
                return String(stem.dropLast(suffix.count))
            }
        }
        return stem
    }

    private static func parseSlug(_ slug: String, fallbackURL: URL?) -> (String, String, String, Int, String) {
        let ns = slug as NSString
        if let match = stampRegex?.firstMatch(in: slug, range: NSRange(location: 0, length: ns.length)) {
            let d = ns.substring(with: match.range(at: 1))
            let t = ns.substring(with: match.range(at: 2))
            let dateFormatted = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
            let hh = String(t.prefix(2))
            let mm = String(t.dropFirst(2).prefix(2))
            let ss = t.count >= 6 ? String(t.suffix(2)) : "00"
            let timeFormatted = "\(hh):\(mm):\(ss)"
            let hmFormatted = "\(hh):\(mm)"
            let hourInt = Int(hh) ?? 0

            var titlePart = match.range(at: 3).location != NSNotFound
                ? ns.substring(with: match.range(at: 3))
                : "语音记录"
            let nsTitle = titlePart as NSString
            if let hexMatch = hexSuffixRegex?.firstMatch(in: titlePart, range: NSRange(location: 0, length: nsTitle.length)) {
                titlePart = nsTitle.substring(to: hexMatch.range.location)
            }
            titlePart = titlePart.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            let lowered = titlePart.lowercased()
            if lowered == "wwmapp call" {
                titlePart = "企微会议"
            } else if lowered == "tencent meeting call" {
                titlePart = "腾讯会议"
            } else if titlePart.isEmpty {
                titlePart = "语音记录"
            }
            return (dateFormatted, timeFormatted, hmFormatted, hourInt, titlePart)
        }

        let mtime = (fallbackURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        let hmf = DateFormatter()
        hmf.dateFormat = "HH:mm"
        let hour = Calendar.current.component(.hour, from: mtime)
        return (df.string(from: mtime), tf.string(from: mtime), hmf.string(from: mtime), hour, slug)
    }

    private static func extractSpeakers(from text: String) -> [String] {
        guard !text.isEmpty, let regex = speakerBracketRegex else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen: [String] = []
        for m in matches {
            let s1 = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            let s2 = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            let spk = (s1.isEmpty ? s2 : s1).trimmingCharacters(in: .whitespaces)
            if !spk.isEmpty, !seen.contains(spk) {
                seen.append(spk)
            }
        }
        return seen
    }

    private static func audioDurationSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }
}
