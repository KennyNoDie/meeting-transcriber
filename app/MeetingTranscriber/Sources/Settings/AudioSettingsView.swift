import AVFoundation
import SwiftUI

struct AudioSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var audioDevices: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section("麦克风输入与热切换") {
                Toggle("禁用麦克风 (仅录制应用内声音)", isOn: $settings.noMic)

                if !settings.noMic {
                    Picker("录音麦克风来源", selection: $settings.micDeviceUID) {
                        Text("跟随系统默认 (自动热切换)").tag("")
                        ForEach(audioDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .onAppear { refreshAudioDevices() }
                    Text("提示：选择「跟随系统默认」时，录音中途切换无线麦/耳机/内置麦会自动无缝重连并保持时间轴对齐；若指定固定麦克风（如 MacBook Pro麦克风），则即使会议软件切走系统默认输入，转录仍固定使用该设备（拔出时自动回退系统默认）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VoiceActivityDetectionSection(settings: settings)

            EchoSection(settings: settings)

            PerChannelIndicatorSection(settings: settings)
        }
        .formStyle(.grouped)
    }

    private func refreshAudioDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified,
        )
        audioDevices = session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
}

private struct VoiceActivityDetectionSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("语音活动检测 (VAD 静音过滤)") {
            HelpfulToggle(
                title: "启用 VAD 静音裁剪 (过滤长段空白噪音)",
                help: SettingsHelp.vad,
                isOn: $settings.vadEnabled,
            )

            if settings.vadEnabled {
                HStack {
                    Text("触发阈值:")
                    Slider(value: $settings.vadThreshold, in: 0.3 ... 0.9, step: 0.05)
                    Text(String(format: "%.2f", settings.vadThreshold))
                        .monospacedDigit()
                        .frame(width: 35)
                }
            }
        }
        .accessibilityIdentifier(A11yID.vadSection)
        .recordOnlyDisabled(settings.recordOnly)
    }
}

private struct EchoSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("扬声器回声消除") {
            HelpfulToggle(
                title: "转录前消除麦克风串入的远端扬声器回声 (推荐)",
                help: SettingsHelp.echoCancellation,
                isOn: $settings.echoCancellationEnabled,
            )
            .accessibilityIdentifier(A11yID.echoCancellationToggle)

            HelpfulToggle(
                title: "转录后去重回声文本",
                help: SettingsHelp.echoDedup,
                isOn: $settings.echoDedupEnabled,
            )
            .accessibilityIdentifier(A11yID.echoDedupToggle)
            .disabled(settings.echoCancellationEnabled)
        }
        .recordOnlyDisabled(settings.recordOnly)
    }
}

private struct PerChannelIndicatorSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("声道健康监控") {
            HelpfulToggle(
                title: "检测静音采集通道并在状态栏告警",
                help: SettingsHelp.silentCaptureChannel,
                isOn: $settings.perChannelIndicatorEnabled,
            )

            HelpfulToggle(
                title: "应用音频通道无声时自动重建采集流",
                help: SettingsHelp.silentTrackWatchdog,
                isOn: $settings.silentTrackWatchdogEnabled,
            )
            .accessibilityIdentifier(A11yID.silentTrackWatchdogToggle)

            HStack {
                Text("单边静音告警时长:")
                HelpBadge(text: SettingsHelp.asymmetricSilenceWarning)
                Slider(
                    value: $settings.asymmetricSilenceWarningSeconds,
                    in: 30 ... 300,
                    step: 10,
                )
                Text("\(Int(settings.asymmetricSilenceWarningSeconds))秒")
                    .monospacedDigit()
                    .frame(width: 45)
            }
        }
        .accessibilityIdentifier(A11yID.channelIndicatorSection)
    }
}
