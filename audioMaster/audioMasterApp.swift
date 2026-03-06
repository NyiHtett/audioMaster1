import SwiftUI

@main
struct audioMasterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    guard url.scheme == "audiomaster" else { return }
                    switch url.host {
                    case "start":
                        Task { await AudioActor.shared.startRecording(sessionName: nil, quality: .balanced) }
                    case "stop":
                        Task { await AudioActor.shared.stopRecording() }
                    default:
                        break
                    }
                }
        }
    }
}
