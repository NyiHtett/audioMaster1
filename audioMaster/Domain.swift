import Foundation

enum RecordingState: String, Codable, Sendable, CaseIterable {
    case idle
    case recording
    case paused
    case interrupted
    case stopped
    case failed
}

enum RecordingQualityPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case speech
    case balanced
    case high

    var id: String { rawValue }

    var sampleRate: Double {
        switch self {
        case .speech: return 16_000
        case .balanced: return 22_050
        case .high: return 44_100
        }
    }

    var bitRate: Int {
        switch self {
        case .speech: return 64_000
        case .balanced: return 96_000
        case .high: return 128_000
        }
    }

    var displayName: String {
        switch self {
        case .speech: return "Speech"
        case .balanced: return "Balanced"
        case .high: return "High"
        }
    }
}

enum SegmentStatus: String, Codable, Sendable {
    case pending
    case transcribing
    case completed
    case failed
}

enum TranscriptionSource: String, Codable, Sendable {
    case elevenLabs
    case appleLocal
}

struct RecordingSessionDTO: Identifiable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let quality: RecordingQualityPreset
    let inputDevice: String
    let totalSegments: Int
    let transcribedSegments: Int

    var isActive: Bool { endedAt == nil }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

struct TranscriptionSegmentDTO: Identifiable, Sendable {
    let id: UUID
    let index: Int
    let startedAt: Date
    let endedAt: Date
    let status: SegmentStatus
    let source: TranscriptionSource?
    let text: String
    let retryCount: Int
    let errorMessage: String?
}

struct RecordingRuntimeSnapshot: Sendable {
    var state: RecordingState = .idle
    var sessionID: UUID?
    var sessionTitle: String = ""
    var startedAt: Date?
    var elapsed: TimeInterval = 0
    var inputDevice: String = "iPhone Microphone"
    var audioBars: [Double] = [6, 6, 6, 6, 6]
    var totalSegments: Int = 0
    var transcribedSegments: Int = 0
    var isNetworkAvailable: Bool = true
    var lastError: String?
}

struct QueuedSegment: Sendable {
    let segmentID: UUID
    let sessionID: UUID
    let url: URL
}
