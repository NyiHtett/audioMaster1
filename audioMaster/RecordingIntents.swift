import AppIntents
import Foundation

enum IntentQuality: String, AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recording Quality")
    static var caseDisplayRepresentations: [IntentQuality: DisplayRepresentation] = [
        .speech: "Speech",
        .balanced: "Balanced",
        .high: "High"
    ]

    case speech
    case balanced
    case high

    var preset: RecordingQualityPreset {
        switch self {
        case .speech: return .speech
        case .balanced: return .balanced
        case .high: return .high
        }
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Start a new recording session")
    static let openAppWhenRun = true

    @Parameter(title: "Session Name")
    var sessionName: String?

    @Parameter(title: "Quality", default: .balanced)
    var quality: IntentQuality

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AudioActor.shared.startRecording(sessionName: sessionName, quality: quality.preset)
        return .result(dialog: IntentDialog("Recording started"))
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stop active recording and return a summary")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = await AudioActor.shared.currentSnapshot()

        guard snapshot.state == .recording || snapshot.state == .paused || snapshot.state == .interrupted else {
            return .result(value: "No active recording session", dialog: IntentDialog("No active recording session"))
        }

        await AudioActor.shared.stopRecording()

        let duration = Int(snapshot.elapsed)
        let summary = "Stopped. Duration \(duration) seconds, \(snapshot.totalSegments) segments."
        return .result(value: summary, dialog: IntentDialog("Recording stopped"))
    }
}

struct RecordingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record audio with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Finish recording with \(.applicationName)"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill"
        )
    }
}
