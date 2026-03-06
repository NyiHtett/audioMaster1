import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<audioMasterWidgetAttributes>?
    private var lastPushTime: Date = .distantPast

    private init() {}

    func start(sessionID: UUID, title: String, startTime: Date, inputDevice: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = audioMasterWidgetAttributes(sessionID: sessionID, sessionTitle: title)
        let state = audioMasterWidgetAttributes.ContentState(
            recordingState: RecordingState.recording.rawValue,
            recordingStart: startTime,
            inputDevice: inputDevice,
            transcribedSegments: 0,
            totalSegments: 0,
            barHeights: [6, 6, 6, 6, 6],
            interruptionMessage: nil
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("Live Activity start failed: \(error)")
        }
    }

    func update(from snapshot: RecordingRuntimeSnapshot) async {
        guard let activity else { return }
        guard Date().timeIntervalSince(lastPushTime) >= 0.2 else { return }
        lastPushTime = Date()

        let startedAt = snapshot.startedAt ?? Date()
        let content = audioMasterWidgetAttributes.ContentState(
            recordingState: snapshot.state.rawValue,
            recordingStart: startedAt,
            inputDevice: snapshot.inputDevice,
            transcribedSegments: snapshot.transcribedSegments,
            totalSegments: snapshot.totalSegments,
            barHeights: snapshot.audioBars,
            interruptionMessage: snapshot.state == .interrupted ? "Audio interrupted" : nil
        )

        await activity.update(.init(state: content, staleDate: nil))
    }

    func end() async {
        guard let activity else { return }
        await activity.end(dismissalPolicy: .immediate)
        self.activity = nil
    }
}
