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

    @State private var selection: SettingsTab = .timeline

    var body: some View {
        splitView
            .onReceive(NotificationCenter.default.publisher(for: .showTimeline)) { _ in
                selection = .timeline
            }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label(tab.label, systemImage: tab.systemImage)
                    .tag(tab)
                    .accessibilityIdentifier(A11yID.settingsTab(tab.rawValue))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView(for: selection)
        }
        .navigationTitle("设置与时间线")
        .frame(
            minWidth: 760,
            idealWidth: 860,
            maxWidth: 1000,
            minHeight: 520,
            idealHeight: 640,
            maxHeight: .infinity,
        )
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
