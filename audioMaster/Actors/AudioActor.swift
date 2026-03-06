import AVFoundation
import Foundation

private final class SegmentFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?

    func rotate(to url: URL, settings: [String: Any]) throws {
        lock.lock()
        defer { lock.unlock() }
        // switch to the next file safely while mic buffers keep coming in
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }
}

private struct ActiveSegment {
    let index: Int
    let startedAt: Date
    let url: URL
}

actor AudioActor {
    static let shared = AudioActor()

    private let dataManager: DataManagerActor
    private let liveActivity: LiveActivityManager
    private let transcription: TranscriptionActor
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let writer = SegmentFileWriter()

    private var runtime = RecordingRuntimeSnapshot()
    private var continuation: AsyncStream<RecordingRuntimeSnapshot>.Continuation?
    lazy var runtimeStream: AsyncStream<RecordingRuntimeSnapshot> = AsyncStream { continuation in
        self.continuation = continuation
        continuation.yield(self.runtime)
    }

    private var state: RecordingState = .idle
    private var currentQuality: RecordingQualityPreset = .balanced
    private var activeSegment: ActiveSegment?
    private var segmentTask: Task<Void, Never>?
    private var interruptedPreviously = false

    private var observeInterruptionsTask: Task<Void, Never>?
    private var observeRouteChangesTask: Task<Void, Never>?

    private var segmentLengthSeconds: TimeInterval = 30

    init(
        dataManager: DataManagerActor = .shared,
        liveActivity: LiveActivityManager = .shared,
        transcription: TranscriptionActor = .shared
    ) {
        self.dataManager = dataManager
        self.liveActivity = liveActivity
        self.transcription = transcription
        observeAudioNotifications()
        observeTranscriptionEvents()
    }

    func runtimeUpdates() -> AsyncStream<RecordingRuntimeSnapshot> {
        runtimeStream
    }

    func currentSnapshot() -> RecordingRuntimeSnapshot {
        runtime
    }

    func configureSegmentLength(_ seconds: TimeInterval) {
        segmentLengthSeconds = max(10, seconds)
    }

    func startRecording(sessionName: String?, quality: RecordingQualityPreset) async {
        guard state != .recording else { return }

        do {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                runtime.lastError = "Microphone permission denied"
                state = .failed
                emitRuntime()
                return
            }

            try configureAudioSession(quality: quality)
            try ensureStorageAvailable()

            let inputName = currentAudioDeviceName()
            let title = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? sessionName!
                : "Session \(Date.now.formatted(date: .abbreviated, time: .shortened))"

            let sessionID = try await dataManager.createSession(title: title, quality: quality, inputDevice: inputName)

            currentQuality = quality
            state = .recording
            runtime.state = .recording
            runtime.sessionID = sessionID
            runtime.sessionTitle = title
            runtime.startedAt = Date()
            runtime.elapsed = 0
            runtime.inputDevice = inputName
            runtime.totalSegments = 0
            runtime.transcribedSegments = 0
            runtime.lastError = nil
            emitRuntime()

            try installInputTap()
            try createNextSegment(index: 0)

            if !engine.isRunning { try engine.start() }
            // rotate files in fixed chunks so each one can be transcribed independently
            startSegmentRotationTask()

            await liveActivity.start(sessionID: sessionID, title: title, startTime: runtime.startedAt ?? Date(), inputDevice: inputName)
            await liveActivity.update(from: runtime)
        } catch {
            state = .failed
            runtime.state = .failed
            runtime.lastError = error.localizedDescription
            emitRuntime()
        }
    }

    func pauseRecording() async {
        guard state == .recording else { return }
        engine.pause()
        state = .paused
        runtime.state = .paused
        emitRuntime()
        await liveActivity.update(from: runtime)
    }

    func resumeRecording() async {
        guard state == .paused || state == .interrupted else { return }
        do {
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            state = .recording
            runtime.state = .recording
            emitRuntime()
            await liveActivity.update(from: runtime)
        } catch {
            state = .failed
            runtime.state = .failed
            runtime.lastError = error.localizedDescription
            emitRuntime()
        }
    }

    func stopRecording() async {
        guard state == .recording || state == .paused || state == .interrupted else { return }

        segmentTask?.cancel()
        segmentTask = nil

        await rotateAndQueueCurrentSegment(createNext: false)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()

        if let sessionID = runtime.sessionID {
            try? await dataManager.finishSession(id: sessionID)
        }

        state = .stopped
        runtime.state = .stopped
        runtime.elapsed = runtime.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        emitRuntime()
        await liveActivity.update(from: runtime)
        await liveActivity.end()
    }

    private func configureAudioSession(quality: RecordingQualityPreset) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(quality.sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func installInputTap() throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.removeTap(onBus: 0)

        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.writer.write(buffer)
            // convert raw pcm levels to simple bars for waveform/live activity UI
            let bars = Self.bars(from: buffer)
            Task { await self?.handleInputBars(bars) }
        }
    }

    private func createNextSegment(index: Int) throws {
        try ensureStorageAvailable()

        let dir = try recordingsDirectory()
        let url = dir.appendingPathComponent("segment_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: currentQuality.sampleRate,
            AVNumberOfChannelsKey: 1
        ]

        try writer.rotate(to: url, settings: settings)
        activeSegment = ActiveSegment(index: index, startedAt: Date(), url: url)

        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func rotateAndQueueCurrentSegment(createNext: Bool) async {
        guard let sessionID = runtime.sessionID, let activeSegment else { return }

        writer.close()
        let endedAt = Date()

        do {
            // save pending segment first so user can see it immediately in the list
            let segmentID = try await dataManager.addPendingSegment(
                sessionID: sessionID,
                index: activeSegment.index,
                startedAt: activeSegment.startedAt,
                endedAt: endedAt,
                fileURL: activeSegment.url
            )
            runtime.totalSegments += 1
            emitRuntime()
            await liveActivity.update(from: runtime)

            await transcription.enqueue(
                QueuedSegment(
                    segmentID: segmentID,
                    sessionID: sessionID,
                    url: activeSegment.url
                )
            )

            if createNext {
                try createNextSegment(index: activeSegment.index + 1)
            } else {
                self.activeSegment = nil
            }
        } catch {
            runtime.lastError = "Segment rotation failed: \(error.localizedDescription)"
            runtime.state = .failed
            state = .failed
            emitRuntime()
        }
    }

    private func startSegmentRotationTask() {
        segmentTask?.cancel()
        segmentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(segmentLengthSeconds))
                guard !Task.isCancelled else { return }
                guard await self.isActivelyRecording() else { continue }
                // rollover keeps recording continuous while chunking per segment length
                await self.rotateAndQueueCurrentSegment(createNext: true)
            }
        }
    }

    private func isActivelyRecording() -> Bool {
        state == .recording
    }

    private func observeAudioNotifications() {
        // keep app state synced with ios interruption and route-change events
        observeInterruptionsTask = Task { [weak self] in
            guard let self else { return }
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                await self.handleInterruption(note)
            }
        }

        observeRouteChangesTask = Task { [weak self] in
            guard let self else { return }
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                await self.handleRouteChange(note)
            }
        }
    }

    private func observeTranscriptionEvents() {
        Task { [weak self] in
            guard let self else { return }
            let stream = await self.transcription.eventStream()
            for await event in stream {
                // feed transcription updates back into the runtime counters
                await self.handleTranscriptionEvent(event)
            }
        }
    }

    private func handleInterruption(_ note: Notification) async {
        guard let userInfo = note.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            guard state == .recording else { return }
            interruptedPreviously = true
            state = .interrupted
            runtime.state = .interrupted
            engine.pause()
            emitRuntime()
            await liveActivity.update(from: runtime)

        case .ended:
            guard interruptedPreviously else { return }
            interruptedPreviously = false

            let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                await resumeRecording()
            } else {
                state = .paused
                runtime.state = .paused
                emitRuntime()
                await liveActivity.update(from: runtime)
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) async {
        guard state == .recording || state == .paused || state == .interrupted else { return }

        if let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) {
            if reason == .oldDeviceUnavailable {
                runtime.lastError = "Audio route changed, switching input device"
            }
        }

        runtime.inputDevice = currentAudioDeviceName()
        emitRuntime()
        await liveActivity.update(from: runtime)
    }

    private func handleInputBars(_ bars: [Double]) async {
        guard state == .recording else { return }
        runtime.audioBars = bars
        runtime.elapsed = runtime.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        emitRuntime()
        await liveActivity.update(from: runtime)
    }

    private func handleTranscriptionEvent(_ event: TranscriptionRuntimeEvent) async {
        if let isOnline = event.isNetworkAvailable {
            runtime.isNetworkAvailable = isOnline
            emitRuntime()
            await liveActivity.update(from: runtime)
        }

        guard runtime.sessionID == event.sessionID else { return }
        do {
            let progress = try await dataManager.sessionProgress(sessionID: event.sessionID)
            runtime.transcribedSegments = progress.transcribed
            runtime.totalSegments = progress.total
            runtime.lastError = event.status == .failed ? event.errorMessage : runtime.lastError
            emitRuntime()
            await liveActivity.update(from: runtime)
        } catch {
            runtime.lastError = error.localizedDescription
            emitRuntime()
        }
    }

    private func emitRuntime() {
        runtime.elapsed = runtime.startedAt.map { Date().timeIntervalSince($0) } ?? runtime.elapsed
        continuation?.yield(runtime)
    }

    private func recordingsDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func ensureStorageAvailable() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let values = try docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available < 50_000_000 {
            throw NSError(domain: "AudioActor", code: 507, userInfo: [NSLocalizedDescriptionKey: "Insufficient storage available"]) 
        }
    }

    private static func bars(from buffer: AVAudioPCMBuffer) -> [Double] {
        guard let channel = buffer.floatChannelData?[0] else { return [6, 6, 6, 6, 6] }
        let frameCount = Int(buffer.frameLength)
        if frameCount <= 0 { return [6, 6, 6, 6, 6] }

        let barsCount = 5
        let stride = max(1, frameCount / barsCount)

        return (0..<barsCount).map { index in
            let start = index * stride
            let count = min(stride, frameCount - start)
            guard count > 0 else { return 6 }

            let samples = UnsafeBufferPointer(start: channel + start, count: count)
            let sum = samples.reduce(0) { $0 + ($1 * $1) }
            let rms = sqrt(sum / Float(count))
            let normalized = min(max(Double(rms * 120), 0), 1)
            return 6 + normalized * 18
        }
    }

    private func currentAudioDeviceName() -> String {
        let route = session.currentRoute
        let input = route.inputs.first
        let output = route.outputs.first

        if let input,
           input.portType == .builtInMic,
           let output,
           output.portType == .bluetoothA2DP || output.portType == .bluetoothLE || output.portType == .bluetoothHFP {
            return output.portName
        }

        return input?.portName ?? output?.portName ?? "iPhone Microphone"
    }
}
