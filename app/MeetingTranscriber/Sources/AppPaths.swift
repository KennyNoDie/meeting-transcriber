import Foundation
import os.log

/// Centralized path constants and logger subsystem for the app.
enum AppPaths {
    /// Logger subsystem for all os.log loggers.
    static let logSubsystem = "com.meetingtranscriber"

    /// App data directory: `~/Library/Application Support/MeetingTranscriber/`
    /// In sandbox, this automatically resolves to the container path.
    /// Falls back to `~/.MeetingTranscriber/` if Application Support is unavailable.
    static let dataDir: URL = {
        if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("MeetingTranscriber", isDirectory: true)
        }
        Logger(subsystem: logSubsystem, category: "AppPaths")
            .error("Application Support directory unavailable — falling back to home directory")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".MeetingTranscriber", isDirectory: true)
    }()

    /// IPC directory: under `dataDir` for sandbox compatibility.
    static let ipcDir = dataDir.appendingPathComponent("ipc", isDirectory: true)

    /// Configurable workspace root for Qwen3-ASR bridge scripts, `.venv`, and persistent `outputs/`.
    /// Reads `MEETING_TRANSCRIBER_WORKSPACE` environment variable or `UserDefaults("workspaceRootDir")`,
    /// falling back to `~/Documents/MeetingTranscriber`.
    static var workspaceRootDir: URL {
        if let envPath = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBER_WORKSPACE"], !envPath.isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let custom = UserDefaults.standard.string(forKey: "workspaceRootDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingTranscriber", isDirectory: true)
    }

    /// Persistent output root: `<workspaceRootDir>/outputs/`
    static var persistentOutputDir: URL {
        workspaceRootDir.appendingPathComponent("outputs", isDirectory: true)
    }

    /// Recordings directory (stored directly inside `outputs/recordings` to avoid cache cleanup).
    static var recordingsDir: URL {
        persistentOutputDir.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Protocols output directory.
    static var protocolsDir: URL {
        persistentOutputDir.appendingPathComponent("protocols", isDirectory: true)
    }

    /// Default output directory: `<workspaceRootDir>/outputs/`
    static var downloadsProtocolsDir: URL {
        persistentOutputDir
    }

    /// Speaker voice profiles DB.
    static let speakersDB = dataDir.appendingPathComponent("speakers.json")

    /// Custom protocol prompt file.
    static let customPromptFile = dataDir.appendingPathComponent("protocol_prompt.md")

    /// Exists exactly while a run of this bundle is alive; see `LivenessMarker`.
    /// Named per bundle identifier because the dev and release builds share
    /// `dataDir`, and each must judge only its own previous run: one build's
    /// leftover must not read as the other's crash. Kept out of
    /// `recordingsDir`, which is scanned for crash signatures by filename.
    static let livenessMarker = dataDir
        .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "MeetingTranscriber").running")

    /// Legacy IPC directory (`~/.meeting-transcriber/`) used before sandbox migration.
    private static let legacyIpcDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".meeting-transcriber", isDirectory: true)

    private static let logger = Logger(subsystem: logSubsystem, category: "AppPaths")

    /// Migrate IPC files from `~/.meeting-transcriber/` to `dataDir/ipc/`.
    /// Safe to call multiple times — copyItem fails gracefully if destination exists.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyIpcDir.path) else { return }

        let filesToMigrate = [
            "processed_recordings.json",
            "pipeline_queue.json",
            "pipeline_log.jsonl",
        ]

        try? fm.createDirectory(at: ipcDir, withIntermediateDirectories: true)

        for name in filesToMigrate {
            let src = legacyIpcDir.appendingPathComponent(name)
            let dst = ipcDir.appendingPathComponent(name)
            do {
                try fm.copyItem(at: src, to: dst)
                logger.info("Migrated \(name) from legacy IPC directory")
            } catch CocoaError.fileWriteFileExists {
                // Already migrated — expected on subsequent launches
            } catch CocoaError.fileReadNoSuchFile {
                // Source doesn't exist — skip
            } catch {
                logger.error("Failed to migrate \(name): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
