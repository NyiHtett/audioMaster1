import Foundation
import SwiftData

@Model
final class RecordingSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var qualityRaw: String
    var inputDevice: String
    var totalSegments: Int
    var transcribedSegments: Int

    // delete all child segments automatically when a session is removed
    @Relationship(deleteRule: .cascade, inverse: \TranscriptionSegment.session)
    var segments: [TranscriptionSegment]

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        quality: RecordingQualityPreset,
        inputDevice: String
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = nil
        self.qualityRaw = quality.rawValue
        self.inputDevice = inputDevice
        self.totalSegments = 0
        self.transcribedSegments = 0
        self.segments = []
    }

    var quality: RecordingQualityPreset {
        RecordingQualityPreset(rawValue: qualityRaw) ?? .balanced
    }
}

@Model
final class TranscriptionSegment {
    @Attribute(.unique) var id: UUID
    var index: Int
    var startedAt: Date
    var endedAt: Date
    var filePath: String
    var statusRaw: String
    var sourceRaw: String?
    var text: String
    var retryCount: Int
    var processingDuration: Double
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    // relation back to parent session so we can query by session id
    var session: RecordingSession?

    init(
        id: UUID = UUID(),
        index: Int,
        startedAt: Date,
        endedAt: Date,
        filePath: String,
        status: SegmentStatus = .pending,
        source: TranscriptionSource? = nil,
        text: String = "",
        retryCount: Int = 0,
        processingDuration: Double = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.index = index
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.filePath = filePath
        self.statusRaw = status.rawValue
        self.sourceRaw = source?.rawValue
        self.text = text
        self.retryCount = retryCount
        self.processingDuration = processingDuration
        self.errorMessage = errorMessage
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var status: SegmentStatus {
        get { SegmentStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var source: TranscriptionSource? {
        get { sourceRaw.flatMap(TranscriptionSource.init(rawValue:)) }
        set { sourceRaw = newValue?.rawValue }
    }
}

actor DataManagerActor {
    static let shared = DataManagerActor()

    private let container: ModelContainer
    private let context: ModelContext

    init() {
        do {
            let schema = Schema([RecordingSession.self, TranscriptionSegment.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.container = try ModelContainer(for: schema, configurations: config)
            self.context = ModelContext(container)
            // manual save gives predictable write points during heavy segment ingestion
            self.context.autosaveEnabled = false
        } catch {
            fatalError("Unable to bootstrap SwiftData: \(error)")
        }
    }

    // create a session row and return id so audio/transcription can attach segments
    func createSession(title: String, quality: RecordingQualityPreset, inputDevice: String) throws -> UUID {
        let session = RecordingSession(title: title, startedAt: Date(), quality: quality, inputDevice: inputDevice)
        context.insert(session)
        try context.save()
        return session.id
    }

    func finishSession(id: UUID) throws {
        guard let session = try fetchSessionModel(id: id) else { return }
        session.endedAt = Date()
        try context.save()
    }

    func addPendingSegment(
        sessionID: UUID,
        index: Int,
        startedAt: Date,
        endedAt: Date,
        fileURL: URL
    ) throws -> UUID {
        guard let session = try fetchSessionModel(id: sessionID) else {
            throw NSError(domain: "DataManagerActor", code: 404, userInfo: [NSLocalizedDescriptionKey: "Session not found"]) 
        }

        let segment = TranscriptionSegment(
            index: index,
            startedAt: startedAt,
            endedAt: endedAt,
            filePath: fileURL.path,
            status: .pending
        )
        segment.session = session
        session.totalSegments += 1
        context.insert(segment)
        // save immediately so pending segment shows up in UI without delay
        try context.save()

        return segment.id
    }

    func markSegmentTranscribing(segmentID: UUID, retryCount: Int) throws {
        guard let segment = try fetchSegmentModel(id: segmentID) else { return }
        segment.status = .transcribing
        segment.retryCount = retryCount
        segment.updatedAt = Date()
        try context.save()
    }

    func markSegmentCompleted(
        segmentID: UUID,
        text: String,
        source: TranscriptionSource,
        retryCount: Int,
        processingDuration: TimeInterval
    ) throws {
        guard let segment = try fetchSegmentModel(id: segmentID) else { return }
        segment.status = .completed
        segment.source = source
        segment.text = text
        segment.retryCount = retryCount
        segment.processingDuration = processingDuration
        segment.errorMessage = nil
        segment.updatedAt = Date()

        if let session = segment.session {
            session.transcribedSegments += 1
        }

        try context.save()
    }

    func markSegmentFailed(segmentID: UUID, retryCount: Int, errorMessage: String) throws {
        guard let segment = try fetchSegmentModel(id: segmentID) else { return }
        segment.status = .failed
        segment.retryCount = retryCount
        segment.errorMessage = errorMessage
        segment.updatedAt = Date()
        try context.save()
    }

    func sessionProgress(sessionID: UUID) throws -> (transcribed: Int, total: Int) {
        guard let session = try fetchSessionModel(id: sessionID) else { return (0, 0) }
        return (session.transcribedSegments, session.totalSegments)
    }

    func fetchSessions(limit: Int = 50, offset: Int = 0, search: String = "") throws -> [RecordingSessionDTO] {
        var descriptor = FetchDescriptor<RecordingSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        let models = try context.fetch(descriptor)
        let normalizedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // keep search filtering in-memory after paging fetch
        return models
            .filter { normalizedSearch.isEmpty || $0.title.lowercased().contains(normalizedSearch) }
            .map {
                RecordingSessionDTO(
                    id: $0.id,
                    title: $0.title,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt,
                    quality: $0.quality,
                    inputDevice: $0.inputDevice,
                    totalSegments: $0.totalSegments,
                    transcribedSegments: $0.transcribedSegments
                )
            }
    }

    func fetchSegments(sessionID: UUID, limit: Int = 100, offset: Int = 0) throws -> [TranscriptionSegmentDTO] {
        var descriptor = FetchDescriptor<TranscriptionSegment>(
            predicate: #Predicate { $0.session?.id == sessionID },
            sortBy: [SortDescriptor(\.index, order: .forward)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        // segments are sorted by capture index to preserve spoken timeline
        return try context.fetch(descriptor).map {
            TranscriptionSegmentDTO(
                id: $0.id,
                index: $0.index,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                status: $0.status,
                source: $0.source,
                text: $0.text,
                retryCount: $0.retryCount,
                errorMessage: $0.errorMessage
            )
        }
    }

    func countSessions() throws -> Int {
        try context.fetchCount(FetchDescriptor<RecordingSession>())
    }

    func deleteSession(id: UUID) throws {
        guard let session = try fetchSessionModel(id: id) else { return }
        context.delete(session)
        try context.save()
    }

    private func fetchSessionModel(id: UUID) throws -> RecordingSession? {
        let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func fetchSegmentModel(id: UUID) throws -> TranscriptionSegment? {
        let descriptor = FetchDescriptor<TranscriptionSegment>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }
}
