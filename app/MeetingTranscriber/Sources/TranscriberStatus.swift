/// Matches the JSON status file written by the Python status emitter.
struct TranscriberStatus: Codable {
    let version: Int
    let timestamp: String
    let state: TranscriberState
    let detail: String
    let meeting: MeetingInfo?
    let protocolPath: String?
    let error: String?
    let audioPath: String?
    let pid: Int?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, state, detail, meeting, error, pid
        case protocolPath = "protocol_path"
        case audioPath = "audio_path"
    }
}

enum TranscriberState: String, Codable {
    case idle
    case watching
    case recording
    case transcribing
    case generatingProtocol = "generating_protocol"
    case waitingForSpeakerCount = "waiting_for_speaker_count"
    case waitingForSpeakerNames = "waiting_for_speaker_names"
    case recordingDone = "recording_done"
    case protocolReady = "protocol_ready"
    case error

    var label: String {
        switch self {
        case .idle: "待机中 (Idle)"
        case .watching: "后台静默监听会议中..."
        case .recording: "正在录音..."
        case .transcribing: "正在转录..."
        case .generatingProtocol: "正在生成纪要..."
        case .waitingForSpeakerCount: "等待确认说话人数"
        case .waitingForSpeakerNames: "等待命名说话人"
        case .recordingDone: "录音完成 · 本地转录中..."
        case .protocolReady: "转录已就绪"
        case .error: "错误"
        }
    }

    var icon: String {
        switch self {
        case .idle: "waveform.circle"
        case .watching: "eye.fill"
        case .recording: "record.circle.fill"
        case .transcribing: "waveform"
        case .generatingProtocol: "waveform"
        case .waitingForSpeakerCount: "person.2.wave.2"
        case .waitingForSpeakerNames: "person.2.fill"
        case .recordingDone: "waveform"
        case .protocolReady: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct MeetingInfo: Codable {
    let app: String
    let title: String
    /// The process being recorded, or nil for a microphone-only recording,
    /// which has no owning process. Encodes as an absent key rather than a
    /// sentinel, so a reader cannot mistake it for a real PID.
    let pid: Int?
}
