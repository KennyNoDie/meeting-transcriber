import AppKit
import AVFoundation
import SwiftUI

struct TimelineEntry: Identifiable {
    let id: String
    let dateString: String
    let timeString: String
    let sortKey: String
    let title: String
    let transcriptURL: URL?
    let audioURL: URL?
    let micAudioURL: URL?
    let appAudioURL: URL?
    let durationSeconds: Double
    let transcriptText: String

    var formattedDuration: String {
        guard durationSeconds > 0 else { return "未知时长" }
        let total = Int(durationSeconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return mins > 0 ? "\(mins)分\(String(format: "%02d", secs))秒" : "\(secs)秒"
    }
}

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

struct TimelineSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var entries: [TimelineEntry] = []
    @State private var selectedDate: String = "ALL"
    @State private var expandedIDs: Set<String> = []
    @State private var statusBanner: String?
    @State private var isRunningAction: Bool = false
    @State private var audioPlayer = TimelineAudioPlayer()

    private var availableDates: [String] {
        let dates = Set(entries.map(\.dateString))
        return dates.sorted(by: >)
    }

    private var filteredEntries: [TimelineEntry] {
        if selectedDate == "ALL" {
            return entries
        }
        return entries.filter { $0.dateString == selectedDate }
    }

    private var totalDurationText: String {
        let sum = filteredEntries.reduce(0.0) { $0 + $1.durationSeconds }
        let mins = Int(sum) / 60
        let secs = Int(sum) % 60
        return "\(filteredEntries.count) 段记录 · 共 \(mins)分\(secs)秒"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            if let banner = statusBanner {
                bannerView(banner)
                Divider()
            }
            contentArea
        }
        .onAppear {
            reloadTimeline()
        }
        .onDisappear {
            audioPlayer.stop()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("日期筛选", selection: $selectedDate) {
                Text("全部日期").tag("ALL")
                ForEach(availableDates, id: \.self) { date in
                    Text(date).tag(date)
                }
            }
            .frame(width: 180)

            Text(totalDurationText)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())

            Spacer()

            if isRunningAction {
                ProgressView()
                    .controlSize(.small)
            }

            Button("生成每日时间线汇总") {
                runDailyTimelineBuilder()
            }
            .disabled(isRunningAction)

            Button("打开输出目录") {
                NSWorkspace.shared.open(settings.effectiveOutputDir)
            }

            Button {
                reloadTimeline()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    private func bannerView(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.caption)
            Spacer()
            Button("关闭") {
                statusBanner = nil
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.08))
    }

    @ViewBuilder
    private var contentArea: some View {
        if filteredEntries.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredEntries) { entry in
                        timelineCard(entry)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("暂无录音与转录时间线记录")
                .font(.headline)
            Text("点击菜单栏图标 →「录制麦克风」或进入企微/腾讯会议后，录音与 Qwen3-ASR 转录将自动按时间线归档在此处。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timelineCard(_ entry: TimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            timeColumn(entry)
            cardBody(entry)
        }
    }

    private func timeColumn(_ entry: TimelineEntry) -> some View {
        VStack(spacing: 4) {
            Text(entry.timeString)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(entry.dateString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 72)
    }

    private func cardBody(_ entry: TimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeaderRow(entry)
            cardActionRow(entry)
            cardTranscriptPreview(entry)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1),
        )
    }

    private func cardHeaderRow(_ entry: TimelineEntry) -> some View {
        HStack {
            Text(entry.title)
                .font(.headline)
            Text(entry.formattedDuration)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            if entry.appAudioURL != nil && entry.micAudioURL != nil {
                Text("双轨 (应用+麦克风)")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            } else if entry.audioURL != nil {
                Text("单轨录音")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func cardActionRow(_ entry: TimelineEntry) -> some View {
        HStack(spacing: 8) {
            if let audioURL = entry.audioURL {
                let playingThis = audioPlayer.playingEntryID == entry.id && audioPlayer.isPlaying
                Button {
                    audioPlayer.togglePlay(entryID: entry.id, url: audioURL)
                } label: {
                    Label(
                        playingThis ? "停止播放" : "播放录音",
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
                Button("打开文本") {
                    NSWorkspace.shared.open(txtURL)
                }
                .controlSize(.small)
            }

            Spacer()

            Button(expandedIDs.contains(entry.id) ? "收起全文" : "展开全文") {
                if expandedIDs.contains(entry.id) {
                    expandedIDs.remove(entry.id)
                } else {
                    expandedIDs.insert(entry.id)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    @ViewBuilder
    private func cardTranscriptPreview(_ entry: TimelineEntry) -> some View {
        if entry.transcriptText.isEmpty {
            Text("（仅录音文件，尚未生成转录文本，可点击上方「Qwen3-ASR 重转」生成）")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let isExpanded = expandedIDs.contains(entry.id)
            Text(entry.transcriptText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 5)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Actions & Discovery

    private func reloadTimeline() {
        let outDir = settings.effectiveOutputDir
        let accessing = outDir.startAccessingSecurityScopedResource()
        defer { if accessing { outDir.stopAccessingSecurityScopedResource() } }
        entries = TimelineScanner.scan(outputDir: outDir, stagingDir: AppPaths.recordingsDir)
    }

    private func runDailyTimelineBuilder() {
        isRunningAction = true
        let targetDate = selectedDate == "ALL" ? nil : selectedDate
        Task.detached(priority: .userInitiated) {
            let root = AppPaths.workspaceRootDir
            let py = root.appendingPathComponent(".venv/bin/python")
            let script = root.appendingPathComponent("scripts/build_daily_timeline.py")
            let proc = Process()
            proc.executableURL = py
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
                statusBanner = output.isEmpty ? "已生成每日时间线汇总包" : output.components(separatedBy: "\n").last
                NSWorkspace.shared.open(timelinesDir)
            }
        }
    }

    private func retranscribeWithQwen(audioURL: URL, entry: TimelineEntry) {
        isRunningAction = true
        statusBanner = "正在使用 Qwen3-ASR 1.7B 重新转录 \(entry.title)..."
        let outDir = settings.effectiveOutputDir
        Task.detached(priority: .userInitiated) {
            let root = AppPaths.workspaceRootDir
            let py = root.appendingPathComponent(".venv/bin/python")
            let script = root.appendingPathComponent("scripts/qwen3_asr_transcribe.py")
            let proc = Process()
            proc.executableURL = py
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
                statusBanner = "已完成 Qwen3-ASR 1.7B 转录：\(entry.title)"
                reloadTimeline()
            }
        }
    }
}

enum TimelineScanner {
    private static let stampRegex = try? NSRegularExpression(pattern: #"^(\d{8})_(\d{6})(?:_(.+))?$"#)

    static func scan(outputDir: URL, stagingDir: URL) -> [TimelineEntry] {
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

        let allSlugs = Set(textBySlug.keys).union(mixBySlug.keys).union(micBySlug.keys).union(appBySlug.keys)
        var results: [TimelineEntry] = []

        for slug in allSlugs {
            let txtURL = textBySlug[slug]
            let micURL = micBySlug[slug]
            let appURL = appBySlug[slug]
            let primaryAudio = mixBySlug[slug] ?? micURL ?? appURL
            let (dateStr, timeStr, rawTitle) = parseSlug(slug, fallbackURL: txtURL ?? primaryAudio)
            let content = txtURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let duration = primaryAudio.map(audioDurationSeconds) ?? 0
            results.append(
                TimelineEntry(
                    id: slug,
                    dateString: dateStr,
                    timeString: timeStr,
                    sortKey: "\(dateStr)_\(timeStr)_\(slug)",
                    title: rawTitle,
                    transcriptURL: txtURL,
                    audioURL: primaryAudio,
                    micAudioURL: micURL,
                    appAudioURL: appURL,
                    durationSeconds: duration,
                    transcriptText: content.trimmingCharacters(in: .whitespacesAndNewlines),
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

    private static func parseSlug(_ slug: String, fallbackURL: URL?) -> (String, String, String) {
        let ns = slug as NSString
        if let match = stampRegex?.firstMatch(in: slug, range: NSRange(location: 0, length: ns.length)) {
            let d = ns.substring(with: match.range(at: 1))
            let t = ns.substring(with: match.range(at: 2))
            let dateFormatted = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
            let timeFormatted = "\(t.prefix(2)):\(t.dropFirst(2).prefix(2)):\(t.suffix(2))"
            var titlePart = match.range(at: 3).location != NSNotFound
                ? ns.substring(with: match.range(at: 3))
                : "语音记录"
            titlePart = titlePart.replacingOccurrences(of: "_", with: " ")
            return (dateFormatted, timeFormatted, titlePart)
        }

        let mtime = (fallbackURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        return (df.string(from: mtime), tf.string(from: mtime), slug)
    }

    private static func audioDurationSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }
}
