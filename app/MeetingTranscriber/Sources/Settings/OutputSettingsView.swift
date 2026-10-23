import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pure derivations used by `OutputSettingsView`. Extracted so the wrapping
/// logic can be unit-tested without instantiating a SwiftUI host.
enum OutputSettingsLogic {
    /// Abbreviate `url` for display by replacing the home-directory prefix
    /// with `~` so paths inside the user's home stay compact. Falls back to
    /// the full path when `url` is outside `home`. Matches at the path-
    /// component boundary so `home="/Users/alice"` doesn't abbreviate
    /// `/Users/alicebob/...` to `~bob/...`.
    static func displayPath(for url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefixed = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefixed) else { return path }
        return "~/" + path.dropFirst(prefixed.count)
    }

    /// Merge the currently-selected model into a fetched picker list so the
    /// user's choice survives even when `/models` doesn't echo it back
    /// (custom Ollama tags, in-flight rename, offline cache). Returns
    /// `available` unchanged when `selected` is empty or already present.
    static func mergePickerOptions(available: [String], selected: String) -> [String] {
        guard !selected.isEmpty, !available.contains(selected) else { return available }
        return [selected] + available
    }
}

struct OutputSettingsView: View {
    @Bindable var settings: AppSettings

    #if !APPSTORE
        @State private var claudeBinaries: [String] = ["claude"]
    #endif
    @State private var testingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var availableModels: [String] = []
    @State private var didAttemptConnectionTest = false
    @State private var showResetPromptConfirmation = false
    @State private var hasCustomPrompt = false

    enum ConnectionTestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            // Output folder applies to record-only AND protocol mode, so this
            // section deliberately sits outside the .recordOnlyDisabled block.
            Section("输出目录 (录音与转录归档根路径)") {
                HStack {
                    Text("当前输出根目录")
                    Spacer()
                    Text(outputDirDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("更改目录…") {
                        chooseOutputFolder()
                    }

                    Button("恢复默认") {
                        settings.clearCustomOutputDir()
                    }
                    .disabled(settings.customOutputDirBookmark == nil)

                    Spacer()
                }
            }
            .accessibilityIdentifier(A11yID.outputFolderSection)

            Section("单次纪要与提示词 (日常推荐保持「不启用」，由本地 Agent 汇总每日时间线)") {
                Toggle("在生成的纪要末尾附带完整原始逐字稿", isOn: $settings.includeFullTranscriptInProtocol)
                    .accessibilityIdentifier(A11yID.includeFullTranscriptToggle)
                Toggle("始终单独保存原始带时间戳逐字稿 (.txt)", isOn: $settings.saveRawTranscriptSeparately)
                    .accessibilityIdentifier(A11yID.saveRawTranscriptToggle)

                Picker("单次总结提供方", selection: $settings.protocolProvider) {
                    ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                providerConfigView

                Picker("纪要输出语言", selection: $settings.protocolLanguage) {
                    ForEach(AppSettings.protocolLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }

                promptControls
            }
            .accessibilityIdentifier(A11yID.protocolSection)
            .recordOnlyDisabled(settings.recordOnly)
        }
        .formStyle(.grouped)
        .onAppear {
            #if !APPSTORE
                claudeBinaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            #endif
            refreshCustomPromptState()
        }
    }

    @ViewBuilder
    private var providerConfigView: some View { // swiftlint:disable:this attributes
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                Picker("Claude CLI", selection: $settings.claudeBin) {
                    ForEach(claudeBinaries, id: \.self) { bin in
                        Text(bin).tag(bin)
                    }
                }
                Text("Binary used for protocol generation")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("API Key")
                    Spacer()
                    SecureField("", text: $settings.claudeAPIKey)
                        .frame(width: 200)
                }
                Text("Optional. Leave empty to use your \"claude login\" session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only set this if that session can't stay signed in. An explicit key here is billed separately from your subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
        #endif

        case .openAICompatible:
            openAIConfigView

        case .none:
            Text("当前每次录音只做本地 Qwen3-ASR 逐字转录（无需每次写提示词）。所有带时间戳的 .txt 片段会归档到时间线中，晚间由本地 Agent 统一按每日提示词润色汇总。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openAIConfigView: some View { // swiftlint:disable:this attributes
        VStack(alignment: .leading, spacing: 4) {
            Text("Endpoint")
            TextField("http://localhost:1234/v1", text: $settings.openAIEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("Base URL (e.g. http://localhost:1234/v1) or full chat-completions URL — both work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !availableModels.isEmpty {
            Picker("Model", selection: $settings.openAIModel) {
                ForEach(modelPickerOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        } else {
            HStack {
                Text("Model")
                Spacer()
                TextField("", text: $settings.openAIModel)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
            }
        }

        HStack {
            Text("API Key")
            Spacer()
            SecureField("", text: $settings.openAIAPIKey)
                .frame(width: 200)
        }
        Text("Leave empty if your local server doesn't require authentication")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Button {
                testConnection()
            } label: {
                HStack(spacing: 4) {
                    if testingConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(availableModels.isEmpty ? "Fetch Models" : "Refresh Models")
                }
            }
            .disabled(testingConnection)

            if let result = connectionTestResult {
                switch result {
                case let .success(msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                case let .failure(msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .onAppear {
            if availableModels.isEmpty && !didAttemptConnectionTest {
                testConnection()
            }
        }
    }

    private var promptControls: some View {
        // swiftlint:disable:next closure_body_length
        HStack {
            Button("编辑提示词模板") {
                openCustomPrompt()
                refreshCustomPromptState()
            }

            Button("导入提示词") {
                importCustomPrompt()
                refreshCustomPromptState()
            }

            Button("重置为内置默认") {
                showResetPromptConfirmation = true
            }
            .disabled(!hasCustomPrompt)
            .confirmationDialog(
                "确认将提示词模板重置为内置默认？",
                isPresented: $showResetPromptConfirmation,
                titleVisibility: .visible,
            ) {
                Button("重置", role: .destructive) {
                    try? FileManager.default.removeItem(at: AppPaths.customPromptFile)
                    refreshCustomPromptState()
                }
            }

            Spacer()

            if hasCustomPrompt {
                Label("已启用自定义高保真提示词", systemImage: "doc.text.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            } else {
                Label("使用默认提示词", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    private func refreshCustomPromptState() {
        hasCustomPrompt = FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path)
    }

    func testConnection() {
        testingConnection = true
        didAttemptConnectionTest = true
        connectionTestResult = nil
        Task {
            let apiKey = settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: settings.openAIEndpoint,
                model: settings.openAIModel,
                apiKey: apiKey,
            )
            testingConnection = false
            switch result {
            case let .success(models):
                availableModels = models
                if !models.isEmpty {
                    if !models.contains(settings.openAIModel) {
                        settings.openAIModel = models[0]
                    }
                    connectionTestResult = .success("Connected (\(models.count) models)")
                } else {
                    connectionTestResult = .success("Connected")
                }

            case let .failure(error):
                availableModels = []
                connectionTestResult = .failure(error.localizedDescription)
            }
        }
    }

    private var modelPickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: availableModels, selected: settings.openAIModel)
    }

    private func ensurePromptDirectory() {
        try? FileManager.default.createDirectory(
            at: AppPaths.customPromptFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
    }

    private func openCustomPrompt() {
        let url = AppPaths.customPromptFile
        if !FileManager.default.fileExists(atPath: url.path) {
            ensurePromptDirectory()
            try? ProtocolGenerator.protocolPrompt.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func importCustomPrompt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")].compactMap(\.self)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a prompt file to import"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        ensurePromptDirectory()
        let dest = AppPaths.customPromptFile
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try? FileManager.default.replaceItemAt(dest, withItemAt: source)
        } else {
            try? FileManager.default.copyItem(at: source, to: dest)
        }
    }

    private var outputDirDisplay: String {
        OutputSettingsLogic.displayPath(
            for: settings.effectiveOutputDir,
            home: FileManager.default.homeDirectoryForCurrentUser,
        )
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for protocol output"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setCustomOutputDir(url)
    }
}
