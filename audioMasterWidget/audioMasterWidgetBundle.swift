import SwiftUI
import WidgetKit

@main
struct audioMasterWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingStatusWidget()
        audioMasterWidgetLiveActivity()
    }
}
