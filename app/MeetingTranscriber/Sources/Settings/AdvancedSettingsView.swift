import AppKit
import ApplicationServices
import AudioTapLib
import AVFoundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "AdvancedSettingsView")

private enum PrivacyPane: String {
    case screenCapture = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"

    var url: String {
        "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
    }
}

struct AdvancedSettingsView: View {
    @Bindable var settings: AppSettings

    @State private var micPermission: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingOK = false
    @State private var accessibilityOK = false
    @State private var lastExportFile: String?
    @State private var lastExportError: String?
    /// True while a `DiagnosticExporter.export` call is running off-main.
    /// Used to dim the button and surface a spinner so a 50-200 MB persistent
    /// log doesn't look like the app froze.
    @State private var isExportingDiagnostics = false

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            Section("系统权限状态") {
                PermissionRow(
                    label: "屏幕录制与系统音频 (Screen & System Audio)",
                    detail: Self.screenRecordingDetail,
                    granted: screenRecordingOK,
                    help: "\(SystemSettingsPaths.screenRecording) → 开启 Meeting Transcriber",
                    settingsURL: PrivacyPane.screenCapture.url,
                )
                PermissionRow(
                    label: "麦克风权限 (Microphone)",
                    detail: micPermission == .authorized ? "已授权"
                        : micPermission == .notDetermined ? "首次录音时自动弹窗申请"
                        : "未授权 — 点击前往系统设置开启",
                    granted: micPermission == .authorized,
                    warning: micPermission == .notDetermined,
                    help: "系统设置 → 隐私与安全性 → 麦克风 → 开启 Meeting Transcriber",
                    settingsURL: PrivacyPane.microphone.url,
                )
                PermissionRow(
                    label: "辅助功能 (Accessibility · 可选)",
                    detail: "可选 — 用于静音状态检测与自动提取会议窗口标题",
                    granted: accessibilityOK,
                    optional: true,
                    help: "系统设置 → 隐私与安全性 → 辅助功能 → 开启 Meeting Transcriber",
                    settingsURL: PrivacyPane.accessibility.url,
                )

                Button("刷新权限状态") {
                    refreshPermissions()
                }
                .font(.caption)
            }

            // swiftlint:disable:next closure_body_length
            Section("诊断与本地自动化接口") {
                Toggle("启用详细诊断日志 (Verbose Logging)", isOn: $settings.verboseDiagnostics)
                Text(
                    "记录录音、ASR 转录、说话人分离的详细日志。默认关闭；排查故障时开启并点击下方导出。",
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("导出脱敏诊断日志…") { exportDiagnostics() }
                        .disabled(isExportingDiagnostics)
                    if isExportingDiagnostics {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let file = lastExportFile {
                    Text("已导出至: \(file)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = lastExportError {
                    Text("导出失败: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                #if !APPSTORE
                    Button("打开日志文件夹") {
                        NSWorkspace.shared.activateFileViewerSelecting([PersistentDiagnosticLog.logDirectory])
                    }
                    Text(
                        "持久日志保留 30 天，位于 ~/Library/Logs/MeetingTranscriber/。",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle("启用本地自动化 RPC 接口 (mt-cli / Agent 协同)", isOn: $settings.debugRPCEnabled)
                    Text(
                        "在 127.0.0.1:9876 暴露本地自动化接口（支持 mt-cli 状态查询、启停监听与录音控制，仅本机 Bearer Token 鉴权）。",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    #if APPSTORE
        private static let screenRecordingDetail = "用于捕获会议应用内系统音频"
    #else
        private static let screenRecordingDetail = "用于会议自动检测与应用内系统音频捕获"
    #endif

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        screenRecordingOK = Permissions.checkScreenRecording()
        accessibilityOK = AXIsProcessTrusted()
        NotificationCenter.default.post(name: .refreshPermissions, object: nil)
    }

    private func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTranscriber-diagnostics-\(stamp).log")
        let info = DiagnosticExporter.HeaderInfo(
            appVersion: Bundle.main.appVersion,
            commit: Bundle.main.gitCommitHash,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: [
                "verboseDiagnostics": "\(settings.verboseDiagnostics)",
                "diarize": "\(settings.diarize)",
                "vadEnabled": "\(settings.vadEnabled)",
                "transcriptionEngine": settings.transcriptionEngine.rawValue,
                "protocolProvider": settings.protocolProvider.rawValue,
                "recordOnly": "\(settings.recordOnly)",
            ],
        )

        isExportingDiagnostics = true
        // The persistent-log file source can be 50-200 MB and reads via
        // `String(contentsOf:)` + `split(separator:)` — and the OSLogStore
        // fallback's `getEntries` is famously slow on the main actor. Detach
        // so the Settings UI stays responsive while the export runs.
        Task.detached(priority: .userInitiated) {
            let result = Result { try DiagnosticExporter.export(to: outURL, info: info) }
            await MainActor.run {
                isExportingDiagnostics = false
                switch result {
                case let .success(count):
                    lastExportFile = outURL.lastPathComponent
                    lastExportError = nil
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                    let exportedFile = outURL.lastPathComponent
                    logger.info(
                        "diagnostics_exported lines=\(count, privacy: .public) file=\(exportedFile, privacy: .public)",
                    )

                case let .failure(error):
                    lastExportFile = nil
                    lastExportError = error.localizedDescription
                    logger.error(
                        "diagnostics_export_failed error=\(error.localizedDescription, privacy: .public)",
                    )
                }
            }
        }
    }
}
