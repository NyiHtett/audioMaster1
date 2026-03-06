import ActivityKit
import Foundation

struct audioMasterWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var recordingState: String
        var recordingStart: Date
        var inputDevice: String
        var transcribedSegments: Int
        var totalSegments: Int
        var barHeights: [Double]
        var interruptionMessage: String?
    }

    var sessionID: UUID
    var sessionTitle: String
}
