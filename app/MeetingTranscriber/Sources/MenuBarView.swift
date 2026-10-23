import SwiftUI

struct MenuBarView: View {
    let status: TranscriberStatus?
    let isWatching: Bool
    let pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker?
    let onStartStop: () -> Void
    let onRecordApp: () -> Void
    let onRecordMicrophone: () -> Void
    /// Whether the user set "No Microphone (app audio only)". Only reaches the
    /// microphone item, which it disables with a reason.
    let noMic: Bool
    /// The *wide* predicate: a manual recording that is running, or a start that
    /// has registered and not yet built its loop. `state == .recording` misses
    /// that second window, and the microphone item would sit enabled through it
    /// handing back a dead click, which is what `AppPickerStartState` was built
    /// to avoid on the picker.
    let manualRecordingPendingOrActive: Bool
    let onStopManualRecording: (() -> Void)?
    let onOpenLastProtocol: () -> Void
    let onOpenProtocol: (URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onOpenSettings: () -> Void
    let onNameSpeakers: (() -> Void)?
    let onProcessFiles: () -> Void
    let onDismissJob: (UUID) -> Void
    let onQuit: () -> Void

    private var state: TranscriberState {
        status?.state ?? .idle
    }

    private var microphoneAvailability: MicrophoneRecordingAvailability {
        .resolve(
            isRecording: manualRecordingPendingOrActive || state == .recording,
            noMic: noMic,
        )
    }

    /// Hoisted out of the `ViewBuilder`: an `Optional.map` returning an
    /// interpolated string, coalesced with `??`, inside an overloaded `Text`
    /// initializer is the exact shape that blew the 300 ms type-check budget in
    /// this file before (see the note on `body`).
    private func meetingLabel(_ meeting: MeetingInfo) -> String {
        guard let pid = meeting.pid else { return meeting.app }
        return "\(meeting.app) (PID \(pid))"
    }

    // The sections below are hoisted out of `body` into separate computed
    // properties so each is type-checked independently. Inlined as one
    // expression, the `body` getter crossed the 300 ms type-check budget that
    // the analyze build enforces (-warn-long-expression-type-checking=300 with
    // -warnings-as-errors), failing the build on slower CI hardware. The view
    // order, dividers, and conditionals are unchanged.
    var body: some View {
        statusHeader
        meetingInfo
        errorInfo

        Divider()

        watchControls
        processingQueue

        Divider()

        protocolActions
        updateSection

        Divider()

        settingsButton

        Divider()

        quitButton
    }

    // MARK: - Body sections

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(state.label, systemImage: state.icon)
                .font(.headline)

            if let detail = status?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var meetingInfo: some View {
        if let meeting = status?.meeting {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                // A microphone-only recording owns no process, so there is no
                // PID to show and a placeholder would only read as a real one.
                Text(meetingLabel(meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var errorInfo: some View {
        if let error = status?.error, state == .error {
            Divider()
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var watchControls: some View {
        Button {
            onStartStop()
        } label: {
            if isWatching {
                Label("停止自动监听", systemImage: "stop.fill")
            } else {
                Label("启动自动监听", systemImage: "play.fill")
            }
        }
        .keyboardShortcut("s")

        if let onStopManualRecording {
            Button {
                onStopManualRecording()
            } label: {
                Label("停止当前录音", systemImage: "stop.circle.fill")
            }
            .keyboardShortcut(".")
        } else if state != .recording {
            Button {
                onRecordMicrophone()
            } label: {
                Label("仅录制麦克风 (速记)", systemImage: "mic.circle")
            }
            .keyboardShortcut("m")
            .disabled(!microphoneAvailability.allowsStart)
            .help(microphoneAvailability.disabledReason ?? "仅录制当前麦克风输入，不录制应用声音")

            Button {
                onRecordApp()
            } label: {
                Label("指定应用双轨录音...", systemImage: "record.circle")
            }
            .keyboardShortcut("r")
        }

        Button {
            onProcessFiles()
        } label: {
            Label("导入音视频文件转录...", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("p")
    }

    @ViewBuilder private var processingQueue: some View {
        if !pipelineQueue.jobs.isEmpty {
            Divider()
            Label("处理队列", systemImage: "gearshape.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(pipelineQueue.jobs.enumerated()), id: \.element.id) { index, job in
                jobRow(job, index: index)
            }
        }
    }

    @ViewBuilder private var protocolActions: some View {
        Button {
            onOpenSettings()
            NotificationCenter.default.post(name: .showTimeline, object: nil)
        } label: {
            Label("打开录音 × 时间线...", systemImage: "clock.arrow.circlepath")
        }
        .keyboardShortcut("t")

        if let protocolPath = status?.protocolPath {
            Button {
                onOpenLastProtocol()
            } label: {
                Label("打开最新转录记录", systemImage: "doc.text")
            }
            .keyboardShortcut("o")
            .disabled(protocolPath.isEmpty)
        }

        Button {
            onOpenProtocolsFolder()
        } label: {
            Label("打开输出文件夹", systemImage: "folder")
        }
    }

    @ViewBuilder private var updateSection: some View {
        if let update = updateChecker?.availableUpdate {
            Divider()
            Button {
                NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
            } label: {
                Label(
                    "发现新版本: \(update.tagName)",
                    systemImage: "arrow.down.circle.fill",
                )
            }
        }
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label("设置与时间线...", systemImage: "gear")
        }
        .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button {
            onQuit()
        } label: {
            Text("退出 MeetingTranscriber")
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    private func jobRow(_ job: PipelineJob, index: Int) -> some View {
        HStack {
            Circle()
                .fill(jobColor(job))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(job.meetingTitle)
                    .font(.caption)
                jobStateLabel(job)
            }
            Spacer()
            if job.state == .done, let path = job.protocolPath ?? job.transcriptPath {
                Button("打开") { onOpenProtocol(path) }
                    .font(.caption2)
            }
            if job.state == .speakerNamingPending {
                Button("命名说话人") { onNameSpeakers?() }
                    .font(.caption2)
            }
            if job.state == .waiting || job.state == .transcribing
                || job.state == .diarizing || job.state == .generatingProtocol {
                Button("取消") { pipelineQueue.cancelJob(id: job.id) }
                    .font(.caption2)
            }
            retryButton(job, index: index)
            if job.state == .done || job.state == .error || job.state == .speakerNamingPending {
                Button("清除") { onDismissJob(job.id) }
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Runs a failed job again from its audio, instead of the user having to
    /// find the staged recording and import it by hand.
    @ViewBuilder
    private func retryButton(_ job: PipelineJob, index: Int) -> some View {
        if pipelineQueue.canRetryJob(id: job.id) {
            Button("重试") { pipelineQueue.retryJob(id: job.id) }
                .font(.caption2)
                .accessibilityIdentifier(A11yID.jobRetryButton(index))
        }
    }

    private func jobStateLabel(_ job: PipelineJob) -> some View {
        Group {
            if [.transcribing, .diarizing, .generatingProtocol].contains(job.state) {
                Text(stageProgressText(job))
                    .foregroundStyle(.secondary)
            } else if job.state == .error, let msg = job.error {
                Text(msg)
                    .foregroundStyle(.red)
            } else if job.state == .done, !job.warnings.isEmpty {
                Text(job.warnings.joined(separator: "; "))
                    .foregroundStyle(.orange)
            } else {
                Text(job.state.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    /// Live elapsed for the active stage, plus the historical average ("· Ø
    /// m:ss") when one exists, and a "longer than usual" hint once the live run
    /// runs meaningfully past that average — so the user can tell at a glance
    /// whether the current run is normal. Purely informational.
    private func stageProgressText(_ job: PipelineJob) -> String {
        let elapsed = pipelineQueue.activeJobElapsed
        let base = "\(job.state.label) \(formattedElapsed(elapsed))"
        guard let stage = StageKind(jobState: job.state),
              let avg = pipelineQueue.averageSeconds(forJobID: job.id, stage: stage), avg > 0 else { return base }
        let suffix = StageTimingStats.isSlowerThanUsual(elapsed: elapsed, average: avg)
            ? " · longer than usual (Ø \(formattedElapsed(avg)))"
            : " · Ø \(formattedElapsed(avg))"
        return base + suffix
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        formattedTime(seconds)
    }

    private func jobColor(_ job: PipelineJob) -> Color {
        switch job.state {
        case .waiting: .gray
        case .transcribing: .blue
        case .diarizing: .purple
        case .generatingProtocol: .orange
        case .speakerNamingPending: .purple
        case .done: job.warnings.isEmpty ? .green : .yellow
        case .error: .red
        }
    }
}
