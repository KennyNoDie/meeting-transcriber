import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var qwen3Engine: Qwen3ASREngine = Qwen3ASREngine()
    var whisperKitEngine: WhisperKitEngine
    var parakeetEngine: ParakeetEngine
    var updateChecker: UpdateChecker?

    /// Notification visibility from `PermissionsController`, forwarded to the
    /// General tab so it can warn when browser-meeting consent cannot reach the
    /// user. Nil until the first permission check completes.
    var notificationVisibility: NotificationVisibility?
    /// Required: the same actor instance the pipeline writes to, so the Stats
    /// tab and the pipeline don't race two writers on `recognition_log.jsonl`.
    var recognitionStatsLog: RecognitionStatsLog
    /// Same actor instance the pipeline writes to, so the Processing Stats tab
    /// and the pipeline don't race two writers on `stage_timing.jsonl`.
    var stageTimingLog: StageTimingLog
    /// Factory for the voice-enrollment diarizer. nil → enroll button hidden.
    var enrollmentDiarizerFactory: (() -> any DiarizationProvider)?
    /// True when a meeting is currently waiting on a naming dialog. We gate
    /// the enroll button to avoid two `SpeakerNamingView` instances.
    var namingDialogActive: Bool = false
    /// True when the pipeline is processing a job — soft hint only.
    var pipelineBusy: Bool = false
    var onSpeakerMutate: (() -> Void)?

    // Live status & quick controls surfaced directly inside the main UI
    var transcriberStatus: TranscriberStatus? = nil
    var isWatching: Bool = true
    var isManualRecording: Bool = false
    var onToggleWatching: (() -> Void)? = nil
    var onRecordMicrophone: (() -> Void)? = nil
    var onStopManualRecording: (() -> Void)? = nil
    var onRecordApp: (() -> Void)? = nil
    var onProcessFiles: (() -> Void)? = nil
    var onNameSpeakers: (() -> Void)? = nil
    var onQuit: (() -> Void)? = nil

    @State private var selection: SettingsTab = .timeline

    var body: some View {
        mainContainer
            .onReceive(NotificationCenter.default.publisher(for: .showTimeline)) { _ in
                withAnimation(.easeInOut(duration: 0.18)) {
                    selection = .timeline
                }
            }
            .frame(
                minWidth: 520,
                idealWidth: 780,
                maxWidth: 1280,
                minHeight: 580,
                idealHeight: 820,
                maxHeight: .infinity,
            )
    }

    @ViewBuilder
    private var mainContainer: some View {
        if selection == .timeline {
            TimelineSettingsView(
                settings: settings,
                transcriberStatus: transcriberStatus,
                isWatching: isWatching,
                isManualRecording: isManualRecording,
                pipelineBusy: pipelineBusy,
                onToggleWatching: onToggleWatching,
                onRecordMicrophone: onRecordMicrophone,
                onStopManualRecording: onStopManualRecording,
                onRecordApp: onRecordApp,
                onProcessFiles: onProcessFiles,
                onNameSpeakers: onNameSpeakers,
                onOpenSettingsTab: { rawTab in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = SettingsTab(rawValue: rawTab) ?? .general
                    }
                },
                onQuit: onQuit,
            )
        } else {
            inWindowSettingsLayout
        }
    }

    private var inWindowSettingsLayout: some View {
        VStack(spacing: 0) {
            inWindowSettingsTopBar
            Divider()
            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var inWindowSettingsTopBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = .timeline
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回时间线")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.08, green: 0.08, blue: 0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.settingsTab(SettingsTab.timeline.rawValue))

                Text("设置与系统控制")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                if let onRecordApp {
                    Button {
                        onRecordApp()
                    } label: {
                        Label("指定应用录音", systemImage: "record.circle")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let onProcessFiles {
                    Button {
                        onProcessFiles()
                    } label: {
                        Label("导入音频转录", systemImage: "doc.badge.plus")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let onQuit {
                    Button(role: .destructive) {
                        onQuit()
                    } label: {
                        Label("退出", systemImage: "power")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.leading, 64)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SettingsTab.settingsCases) { tab in
                        let isSelected = selection == tab
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selection = tab
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 11, weight: .medium))
                                Text(tab.label)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            }
                            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.78))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? Color(red: 0.14, green: 0.14, blue: 0.14)
                                        : Color.primary.opacity(0.06),
                                ),
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.settingsTab(tab.rawValue))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(red: 0.969, green: 0.965, blue: 0.949))
    }

    @ViewBuilder
    private func detailView(for tab: SettingsTab) -> some View {
        switch tab {
        case .timeline:
            TimelineSettingsView(settings: settings)

        case .general:
            GeneralSettingsView(
                settings: settings,
                notificationVisibility: notificationVisibility,
            )

        case .audio:
            AudioSettingsView(settings: settings)

        case .transcription:
            TranscriptionSettingsView(
                settings: settings,
                qwen3Engine: qwen3Engine,
                whisperKitEngine: whisperKitEngine,
                parakeetEngine: parakeetEngine,
            )

        case .speakers:
            SpeakersSettingsView(
                settings: settings,
                recognitionStatsLog: recognitionStatsLog,
                stageTimingLog: stageTimingLog,
                enrollmentDiarizerFactory: enrollmentDiarizerFactory,
                namingDialogActive: namingDialogActive,
                pipelineBusy: pipelineBusy,
                onSpeakerMutate: onSpeakerMutate,
            )

        case .output:
            OutputSettingsView(settings: settings)

        case .advanced:
            AdvancedSettingsView(settings: settings)

        case .about:
            AboutSettingsView(settings: settings, updateChecker: updateChecker)
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case timeline, general, audio, transcription, speakers, output, advanced, about

    static var settingsCases: [Self] {
        [.general, .audio, .transcription, .speakers, .output, .advanced, .about]
    }

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .timeline: "录音 × 时间线"
        case .general: "常规监听"
        case .audio: "音频与麦克风"
        case .transcription: "语音识别 (ASR)"
        case .speakers: "说话人识别"
        case .output: "输出与提示词"
        case .advanced: "权限与诊断"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: "clock.arrow.circlepath"
        case .general: "gear"
        case .audio: "mic"
        case .transcription: "waveform"
        case .speakers: "person.2"
        case .output: "doc.text"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}
