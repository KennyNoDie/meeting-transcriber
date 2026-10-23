#!/usr/bin/env swift
import Foundation

let bundleID = "app.meetingtranscriber"
guard let defaults = UserDefaults(suiteName: bundleID) else {
    fputs("Error: Could not open UserDefaults suite \(bundleID)\n", stderr)
    exit(1)
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
defaults.set(projectRoot.path, forKey: "workspaceRootDir")

let configDir = projectRoot.appendingPathComponent("config", isDirectory: true)
let promptsDir = projectRoot.appendingPathComponent("prompts", isDirectory: true)
let outputsRootDir = projectRoot.appendingPathComponent("outputs", isDirectory: true)
let protocolsOutDir = outputsRootDir.appendingPathComponent("protocols", isDirectory: true)
let recordingsOutDir = outputsRootDir.appendingPathComponent("recordings", isDirectory: true)

let fm = FileManager.default
try? fm.createDirectory(at: protocolsOutDir, withIntermediateDirectories: true)
try? fm.createDirectory(at: recordingsOutDir, withIntermediateDirectories: true)

let vocabFile = configDir.appendingPathComponent("vocabulary.txt")
let rulesFile = configDir.appendingPathComponent("terminology_rules.txt")
let promptFile = promptsDir.appendingPathComponent("protocol_prompt.md")

func makeSecurityBookmark(for url: URL) -> Data? {
    if let scoped = try? url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    ) {
        return scoped
    }
    return try? url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}

// 1. 后台静默监听配置（覆盖主流会议 + 微信/企微/腾讯会议麦克风激活检测）
defaults.set(true, forKey: "autoWatch")
defaults.set(true, forKey: "watchTeams")
defaults.set(true, forKey: "watchZoom")
defaults.set(true, forKey: "watchWebex")
defaults.set(true, forKey: "watchBrowserMeetings")
defaults.set(true, forKey: "watchWeChat")
defaults.set(true, forKey: "watchTencentMeeting")
defaults.set(true, forKey: "watchFaceTime")
defaults.set(["com.tencent.wwmapp", "com.tencent.meeting", "com.tencent.wemeet"], forKey: "watchCustomApps")

defaults.set(1.0, forKey: "pollInterval")
defaults.set(15.0, forKey: "endGrace")
defaults.set(false, forKey: "noMic")
defaults.set(false, forKey: "recordOnly")
defaults.set("Kenny", forKey: "micName")

// 2. 转写、VAD 静音剔除与声纹分离配置（默认使用本地 MLX Qwen3-ASR 1.7B + 中文 zh）
defaults.set("qwen3ASR", forKey: "transcriptionEngine")
defaults.set("openai_whisper-large-v3-v20240930_turbo", forKey: "whisperKitModel")
defaults.set("zh", forKey: "whisperLanguage")
defaults.set(true, forKey: "whisperKitVocabularyPromptEnabled")
defaults.set(true, forKey: "vadEnabled")
defaults.set(Float(0.5), forKey: "vadThreshold")
defaults.set(true, forKey: "diarize")
defaults.set("offline", forKey: "diarizerMode")
defaults.set(0, forKey: "numSpeakers")

// 3. 绑定自定义高频词表与后置术语校准规则
if fm.fileExists(atPath: vocabFile.path) {
    defaults.set(vocabFile.path, forKey: "customVocabularyPath")
    if let vocabBookmark = makeSecurityBookmark(for: vocabFile) {
        defaults.set(vocabBookmark, forKey: "customVocabularyBookmark")
    }
}

if let rulesText = try? String(contentsOf: rulesFile, encoding: .utf8) {
    defaults.set(rulesText, forKey: "terminologyRulesText")
}

// 4. 输出与协议生成配置（默认 none 仅静默落盘带时间戳与声纹的 .txt 逐字稿，零报错弹窗；传参 openAICompatible 可开启单场实时摘要）
let providerArg = CommandLine.arguments.dropFirst().first ?? "none"
defaults.set(providerArg, forKey: "protocolProvider")
defaults.set("Chinese", forKey: "protocolLanguage")
defaults.set(true, forKey: "includeFullTranscriptInProtocol")
defaults.set(true, forKey: "saveRawTranscriptSeparately")
defaults.set(true, forKey: "debugRPCEnabled")

if let outBookmark = makeSecurityBookmark(for: outputsRootDir) {
    defaults.set(outBookmark, forKey: "customOutputDirBookmark")
}

defaults.synchronize()

// 5. 软链自定义 protocol_prompt.md 到 Application Support
if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
    let appDataDir = appSupport.appendingPathComponent("MeetingTranscriber", isDirectory: true)
    try? fm.createDirectory(at: appDataDir, withIntermediateDirectories: true)
    let targetPromptURL = appDataDir.appendingPathComponent("protocol_prompt.md")
    if fm.fileExists(atPath: targetPromptURL.path) || (try? fm.attributesOfItem(atPath: targetPromptURL.path)) != nil {
        try? fm.removeItem(at: targetPromptURL)
    }
    try? fm.createSymbolicLink(at: targetPromptURL, withDestinationURL: promptFile)
    print("Linked custom prompt: \(targetPromptURL.path) -> \(promptFile.path)")
}

print("Successfully applied MeetingTranscriber configuration:")
print("  - Bundle ID: \(bundleID)")
print("  - Auto Watch: true (Teams, Zoom, Webex, Browser, WeChat, TencentMeeting, WeCom)")
print("  - Whisper Language: zh (Fixed from default 'de')")
print("  - Protocol Language: Chinese (Fixed from default 'German')")
print("  - Mic Speaker Label: Kenny")
print("  - VAD & Dual-Track Diarization: Enabled")
print("  - Output Folder: \(protocolsOutDir.path)")
print("  - Local RPC API: Enabled (http://127.0.0.1:9876)")
