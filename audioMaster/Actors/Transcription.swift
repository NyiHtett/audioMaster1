import Foundation
import Network
import Speech

struct TranscriptionRuntimeEvent: Sendable {
    let sessionID: UUID
    let segmentID: UUID
    let status: SegmentStatus
    let text: String?
    let source: TranscriptionSource?
    let retryCount: Int
    let errorMessage: String?
    let isNetworkAvailable: Bool?
}

actor TranscriptionActor {
    static let shared = TranscriptionActor()

    private let dataManager: DataManagerActor
    private let tokenVault: TokenVaultActor
    private let monitor = NWPathMonitor()

    // online/offline gate for queue processing
    private var isOnline = true
    private var queue: [QueuedSegment] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentJobs = 2
    // after repeated remote failures we fallback to local speech recognizer
    private var consecutiveRemoteFailures = 0

    private var runtimeContinuation: AsyncStream<TranscriptionRuntimeEvent>.Continuation?
    lazy var runtimeEvents: AsyncStream<TranscriptionRuntimeEvent> = AsyncStream { continuation in
        self.runtimeContinuation = continuation
    }

    func eventStream() -> AsyncStream<TranscriptionRuntimeEvent> {
        runtimeEvents
    }

    init(dataManager: DataManagerActor = .shared, tokenVault: TokenVaultActor = .shared) {
        self.dataManager = dataManager
        self.tokenVault = tokenVault
        // monitor runs continuously and wakes queue pump when network returns
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.setNetworkAvailability(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "TranscriptionActor.Network"))
    }

    deinit {
        monitor.cancel()
    }

    func enqueue(_ segment: QueuedSegment) async {
        // new segment jobs are appended and drained by pump()
        queue.append(segment)
        await pump()
    }

    func setNetworkAvailability(_ online: Bool) async {
        isOnline = online
        emit(
            TranscriptionRuntimeEvent(
                sessionID: UUID(),
                segmentID: UUID(),
                status: .pending,
                text: nil,
                source: nil,
                retryCount: 0,
                errorMessage: nil,
                isNetworkAvailable: online
            )
        )
        await pump()
    }

    private func pump() async {
        guard isOnline else { return }

        // start as many jobs as allowed by max concurrency
        while activeTasks.count < maxConcurrentJobs, !queue.isEmpty {
            let item = queue.removeFirst()
            let task = Task {
                await self.process(item)
            }
            activeTasks[item.segmentID] = task
        }
    }

    private func process(_ item: QueuedSegment) async {
        defer {
            activeTasks[item.segmentID] = nil
            Task { await self.pump() }
        }

        let start = Date()
        var retryCount = 0
        let maxRetries = 5

        while retryCount <= maxRetries {
            do {
                try await dataManager.markSegmentTranscribing(segmentID: item.segmentID, retryCount: retryCount)

                let transcription: String
                let source: TranscriptionSource

                if consecutiveRemoteFailures >= 5 {
                    // fallback path when remote api has repeated failures
                    transcription = try await transcribeLocally(url: item.url)
                    source = .appleLocal
                } else {
                    transcription = try await transcribeRemotely(url: item.url)
                    source = .elevenLabs
                }

                let duration = Date().timeIntervalSince(start)
                try await dataManager.markSegmentCompleted(
                    segmentID: item.segmentID,
                    text: transcription,
                    source: source,
                    retryCount: retryCount,
                    processingDuration: duration
                )
                consecutiveRemoteFailures = 0
                emit(
                    TranscriptionRuntimeEvent(
                        sessionID: item.sessionID,
                        segmentID: item.segmentID,
                        status: .completed,
                        text: transcription,
                        source: source,
                        retryCount: retryCount,
                        errorMessage: nil,
                        isNetworkAvailable: nil
                    )
                )
                return
            } catch {
                retryCount += 1
                consecutiveRemoteFailures += 1

                if retryCount > maxRetries {
                    let message = error.localizedDescription
                    try? await dataManager.markSegmentFailed(segmentID: item.segmentID, retryCount: retryCount, errorMessage: message)
                    emit(
                        TranscriptionRuntimeEvent(
                            sessionID: item.sessionID,
                            segmentID: item.segmentID,
                            status: .failed,
                            text: nil,
                            source: nil,
                            retryCount: retryCount,
                            errorMessage: message,
                            isNetworkAvailable: nil
                        )
                    )
                    return
                }

                if !isOnline {
                    // put it back so it can resume after connectivity returns
                    queue.append(item)
                    return
                }

                // exponential backoff: 2s, 4s, 8s... capped to 20s
                let backoff = min(pow(2, Double(retryCount)), 20)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }

    private func transcribeRemotely(url: URL) async throws -> String {
        guard let token = await tokenVault.loadElevenLabsToken() else {
            throw NSError(domain: "TranscriptionActor", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing ElevenLabs API key in Keychain"])
        }

        let audioData = try Data(contentsOf: url)
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // multipart form body for elevenlabs speech-to-text endpoint
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("scribe_v2\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw NSError(domain: "TranscriptionActor", code: 502, userInfo: [NSLocalizedDescriptionKey: serverMessage])
        }

        struct ElevenLabsResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(ElevenLabsResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeLocally(url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw NSError(domain: "TranscriptionActor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Local speech recognizer unavailable"])
        }

        let speechPermission = await requestSpeechAuthorization()
        guard speechPermission else {
            throw NSError(domain: "TranscriptionActor", code: 403, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied"])
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        // bridge callback-style speech api to async/await
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error, !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal, !didResume else { return }
                didResume = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }

            Task {
                // safety timeout so local recognition never hangs forever
                try? await Task.sleep(for: .seconds(50))
                if !didResume {
                    didResume = true
                    task.cancel()
                    continuation.resume(throwing: NSError(domain: "TranscriptionActor", code: 408, userInfo: [NSLocalizedDescriptionKey: "Local transcription timed out"]))
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func emit(_ event: TranscriptionRuntimeEvent) {
        runtimeContinuation?.yield(event)
    }
}
