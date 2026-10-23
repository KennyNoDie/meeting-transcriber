import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Qwen3ASREngine")

/// Transcription engine backed by Alibaba Qwen3-ASR-1.7B (or 0.6B) running locally on Apple Silicon MLX.
@MainActor
@Observable
final class Qwen3ASREngine: TranscribingEngine {
    private(set) var modelState: EngineModelState = .unloaded
    private(set) var downloadProgress: Double = 0
    private(set) var transcriptionProgress: Double = 0

    var modelVariant: String = "Qwen/Qwen3-ASR-1.7B"
    var language: String? = "zh"
    var customVocabularyPath: String = ""

    private let modelLoad = SingleFlight<Void>()

    private struct BridgeOutput: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }

        let segments: [Segment]?
        let error: String?
    }

    private static var maintenanceRoot: URL {
        AppPaths.workspaceRootDir
    }

    private static var pythonExecutable: URL {
        maintenanceRoot.appendingPathComponent(".venv/bin/python")
    }

    private static var bridgeScript: URL {
        maintenanceRoot.appendingPathComponent("scripts/qwen3_asr_transcribe.py")
    }

    private func isCachedLocally(model: String) -> Bool {
        let sanitized = model.replacingOccurrences(of: "/", with: "--")
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)/snapshots")
        guard let snapshots = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
            return false
        }
        return !snapshots.isEmpty
    }

    func loadModel() async {
        await modelLoad.run { [self] in
            if isCachedLocally(model: modelVariant),
               FileManager.default.fileExists(atPath: Self.pythonExecutable.path),
               FileManager.default.fileExists(atPath: Self.bridgeScript.path) {
                downloadProgress = 1.0
                modelState = .loaded
                logger.info("Qwen3-ASR model cached and ready: \(self.modelVariant, privacy: .public)")
                return
            }

            modelState = .downloading
            downloadProgress = 0.2
            let modelID = modelVariant
            let pyPath = Self.pythonExecutable
            let scriptPath = Self.bridgeScript

            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                let proc = Process()
                proc.executableURL = pyPath
                proc.arguments = [scriptPath.path, "--check-model", "--model", modelID]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    return proc.terminationStatus == 0
                } catch {
                    return false
                }
            }.value

            if ok {
                downloadProgress = 1.0
                modelState = .loaded
            } else {
                downloadProgress = 0
                modelState = .unloaded
            }
        }
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        if modelState != .loaded {
            await loadModel()
        }
        guard modelState == .loaded else {
            throw TranscriptionError.modelNotLoaded
        }

        transcriptionProgress = 0.1
        let pyPath = Self.pythonExecutable
        let scriptPath = Self.bridgeScript
        let modelID = modelVariant
        let lang = (language?.isEmpty == false) ? (language ?? "zh") : "zh"
        let vocab = customVocabularyPath

        let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let proc = Process()
            proc.executableURL = pyPath
            var args = [
                scriptPath.path,
                "--input", audioPath.path,
                "--model", modelID,
                "--language", lang,
                "--json",
            ]
            if !vocab.isEmpty {
                args.append(contentsOf: ["--vocab", vocab])
            }
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 {
                let errStr = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                logger.error("Qwen3-ASR bridge failed: \(errStr, privacy: .public)")
                throw NSError(
                    domain: "Qwen3ASREngine",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errStr],
                )
            }
            return outData
        }.value

        transcriptionProgress = 1.0
        let decoded = try JSONDecoder().decode(BridgeOutput.self, from: data)
        guard let rawSegments = decoded.segments else {
            return []
        }

        return rawSegments.compactMap { seg in
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TimestampedSegment(start: seg.start, end: max(seg.start + 0.05, seg.end), text: trimmed)
        }
    }
}
