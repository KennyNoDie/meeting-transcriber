import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionSettingsView: View {
    @Bindable var settings: AppSettings
    var qwen3Engine: Qwen3ASREngine = Qwen3ASREngine()
    var whisperKitEngine: WhisperKitEngine
    var parakeetEngine: ParakeetEngine

    /// Set when the user flips live captions on while a first-use Nemotron model
    /// download is pending — defers the actual enable to the consent alert.
    @State private var pendingCaptionEnable = false

    private static let qwen3Models: [(variant: String, label: String)] = [
        ("Qwen/Qwen3-ASR-1.7B", "Qwen3-ASR-1.7B (旗舰 · 4.7GB FP16 · 推荐)"),
        ("Qwen/Qwen3-ASR-0.6B", "Qwen3-ASR-0.6B (轻量 · 1.8GB FP16)"),
    ]

    private static let whisperKitModels: [(variant: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Large V3 Turbo (推荐)"),
        ("openai_whisper-large-v3-v20240930", "Large V3"),
        ("openai_whisper-large-v2", "Large V2"),
        ("openai_whisper-small", "Small"),
        ("openai_whisper-base", "Base"),
        ("openai_whisper-tiny", "Tiny"),
    ]

    var body: some View {
        Form {
            transcriptionSection
            liveTranscriptionSection
        }
        .formStyle(.grouped)
    }

    /// Each group of controls is a named property rather than inline in
    /// `body`: inline, this section made `body` the slowest body in the app
    /// to type-check, close enough to the 300 ms limit CI enforces that a
    /// slow runner pushed it over. Each property stands for exactly one of the
    /// section's former direct children, in the same order: view tests reach
    /// some controls by their position in the section, so merging two of them
    /// into one property would move every control after it.
    private var transcriptionSection: some View {
        Section("语音转录引擎 (ASR)") {
            enginePicker
            qwen3Pickers
            whisperKitPickers
            parakeetLanguagePicker
            customVocabularyRow
            customVocabularyValidation
            whisperKitVocabularyPromptControls
            terminologyRulesEditor
            engineStatusView
        }
        .accessibilityIdentifier(A11yID.transcriptionSection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    private var enginePicker: some View {
        Picker("识别引擎", selection: $settings.transcriptionEngine) {
            ForEach(TranscriptionEngineSetting.availableCases, id: \.self) { engine in
                Text(engine.label).tag(engine)
            }
        }
    }

    @ViewBuilder
    private var qwen3Pickers: some View { // swiftlint:disable:this attributes
        if settings.transcriptionEngine == .qwen3ASR {
            Picker("Qwen3 模型规格", selection: Binding(
                get: { qwen3Engine.modelVariant },
                set: { qwen3Engine.modelVariant = $0 },
            )) {
                ForEach(Self.qwen3Models, id: \.variant) { model in
                    Text(model.label).tag(model.variant)
                }
            }

            Picker("识别语言", selection: $settings.whisperLanguage) {
                ForEach(PickerLanguages.whisperKit, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
        }
    }

    @ViewBuilder
    private var whisperKitPickers: some View { // swiftlint:disable:this attributes
        if settings.transcriptionEngine == .whisperKit {
            Picker("Whisper 模型", selection: $settings.whisperKitModel) {
                ForEach(Self.whisperKitModels, id: \.variant) { model in
                    Text(model.label).tag(model.variant)
                }
            }

            Picker("识别语言", selection: $settings.whisperLanguage) {
                ForEach(PickerLanguages.whisperKit, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
        }
    }

    @ViewBuilder
    private var parakeetLanguagePicker: some View { // swiftlint:disable:this attributes
        if settings.transcriptionEngine == .parakeet {
            Picker("识别语言", selection: $settings.parakeetLanguage) {
                ForEach(PickerLanguages.parakeet, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
        }
    }

    private var customVocabularyRow: some View {
        HStack {
            TextField("专属词表文件 (vocabulary.txt)", text: Binding(
                get: { settings.customVocabularyPath },
                set: { settings.setCustomVocabularyPath($0) },
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.customVocabularyPathField)
            Button("选择文件…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    settings.setCustomVocabularyFile(url)
                }
            }
        }
        .help(Self.vocabularyHelpText(for: settings.transcriptionEngine))
    }

    private var customVocabularyValidation: some View {
        Text(settings.customVocabularyValidation.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear { settings.refreshCustomVocabularyValidation() }
            .onChange(of: settings.customVocabularyPath) { _, _ in
                settings.refreshCustomVocabularyValidation()
            }
    }

    @ViewBuilder
    private var whisperKitVocabularyPromptControls: some View { // swiftlint:disable:this attributes
        if settings.transcriptionEngine == .whisperKit {
            Toggle("启用自定义词表解码提示 (实验性)", isOn: $settings.whisperKitVocabularyPromptEnabled)
                .accessibilityIdentifier(A11yID.whisperKitVocabularyPromptToggle)
                .help(Self.whisperKitVocabularyPromptHelpText)
            Text("注意：WhisperKit 词表提示在密集对话下可能吞句；中文与术语偏置建议直接使用 Qwen3-ASR 1.7B。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var terminologyRulesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("术语纠错替换规则 (ASR 后自动正则归一化)")
            TextEditor(text: $settings.terminologyRulesText)
                .font(.body.monospaced())
                .frame(minHeight: 72)
                .accessibilityIdentifier(A11yID.terminologyRulesEditor)
            Text(
                "每行一条规则：标准写法 => 同音误识词1 | 误识词2（例如：TAPD => 踏平地 | 他批地）。",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(settings.terminologyRulesValidation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Hoisted out of `body` into a named property so the section's nesting
    /// doesn't grow the `body` type-check past the 300 ms hard limit on CI.
    private var liveTranscriptionSection: some View {
        Section("实时字幕浮窗 (可选)") {
            Toggle("录音期间开启实时字幕流", isOn: Binding(
                get: { settings.liveTranscriptionEnabled },
                set: { enabled in
                    if enabled, needsCaptionModelConsent {
                        pendingCaptionEnable = true
                    } else {
                        settings.liveTranscriptionEnabled = enabled
                    }
                },
            ))
            .alert("下载实时字幕模型？", isPresented: $pendingCaptionEnable) {
                Button("取消", role: .cancel) {}
                Button("启用") { settings.liveTranscriptionEnabled = true }
            } message: {
                Text(
                    "实时字幕在首次启用时需下载约 0.6 GB 本地流式模型。",
                )
            }

            captionOverlayToggle
            captionSizePicker

            Text(captionBackendFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(liveTranscriptionFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(A11yID.liveTranscriptionSection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    private var captionOverlayToggle: some View {
        Toggle("显示屏幕底部穿透字幕条", isOn: $settings.liveCaptionsOverlayEnabled)
            .disabled(!settings.liveTranscriptionEnabled)
            .accessibilityIdentifier(A11yID.liveCaptionsOverlayToggle)
    }

    private var captionSizePicker: some View {
        Picker("字幕字号", selection: $settings.liveCaptionsSize) {
            ForEach(LiveCaptionsSize.allCases, id: \.self) { size in
                Text(size.label).tag(size)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!settings.liveTranscriptionEnabled || !settings.liveCaptionsOverlayEnabled)
        .accessibilityIdentifier(A11yID.liveCaptionsSizePicker)
    }

    private var needsCaptionModelConsent: Bool {
        guard let language = settings.activeEngineLanguageOrNil, language != "en" else { return false }
        return !nemotronModelDownloaded
    }

    static func vocabularyHelpText(for engine: TranscriptionEngineSetting) -> String {
        switch engine {
        case .qwen3ASR:
            "每行一个词条。Qwen3-ASR 1.7B 会将该词表直接作为 System Context 注入解码器，原生提升业务术语（如 PUBGM、WOW、TAPD、天穹）识别准确率。"

        case .parakeet:
            "每行一个词条。Parakeet 使用 CTC 重打分提升词表命中率。"

        case .whisperKit:
            "每行一个词条。WhisperKit 仅提供 32-token 软提示。"
        }
    }

    static let whisperKitVocabularyPromptHelpText = "WhisperKit 将词表作为 32-token 软提示，密集音频下可能导致漏句；推荐使用 Qwen3-ASR 1.7B。"

    private var nemotronModelDownloaded: Bool {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask,
        ).first else { return false }
        let dir = base.appendingPathComponent("FluidAudio/Models/nemotron-multilingual")
        return FileManager.default.fileExists(atPath: dir.path)
    }

    private var captionBackendFootnote: String {
        "提示：您的诉求是「后台静默转录 + 每日时间线」，建议保持实时字幕关闭，零前台打扰、零额外内存占用。"
    }

    private var liveTranscriptionFootnote: String {
        "按住 ⌥ (Option) 可拖动字幕条位置；切换识别引擎将在下一次录音生效。"
    }

    private var activeEngine: any TranscribingEngine {
        switch settings.transcriptionEngine {
        case .qwen3ASR: qwen3Engine
        case .parakeet: parakeetEngine
        case .whisperKit: whisperKitEngine
        }
    }

    @ViewBuilder
    private var engineStatusView: some View { // swiftlint:disable:this attributes
        let engine = activeEngine
        switch engine.modelState {
        case .downloading:
            ProgressView(value: engine.downloadProgress)
                .progressViewStyle(.linear)
            Text("正在下载/检查模型... \(Int(engine.downloadProgress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("正在加载模型到内存...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loaded:
            Label(
                settings.transcriptionEngine == .qwen3ASR
                    ? "模型已就绪 · Qwen3-ASR-1.7B 本地 MLX 缓存已验证"
                    : "模型已就绪 (Model ready)",
                systemImage: "checkmark.circle.fill",
            )
            .foregroundStyle(.green)
            .font(.caption)

        case .unloaded:
            Button("加载并校验模型") {
                if settings.transcriptionEngine == .whisperKit {
                    whisperKitEngine.modelVariant = settings.whisperKitModel
                }
                Task { await engine.loadModel() }
            }
        }
    }
}
