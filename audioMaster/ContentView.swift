import SwiftUI

struct ContentView: View {
    @StateObject private var vm = RecorderViewModel()
    @State private var showingFullTranscript = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let compact = proxy.size.width < 760
                Group {
                    if compact {
                        VStack(spacing: 12) {
                            runtimePanel
                            sessionsPanel
                            detailPanel
                        }
                    } else {
                        HStack(spacing: 14) {
                            VStack(spacing: 12) {
                                runtimePanel
                                sessionsPanel
                            }
                            .frame(width: proxy.size.width * 0.52)

                            detailPanel
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(12)
                .background(BrutalPalette.paper.ignoresSafeArea())
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("TOKEN") {
                        vm.showingTokenSheet = true
                    }
                    .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.black, text: BrutalPalette.paper))
                }
            }
            .sheet(isPresented: $vm.showingTokenSheet) {
                tokenSheet
            }
            .sheet(isPresented: $showingFullTranscript) {
                fullTranscriptSheet
            }
        }
        .onAppear { vm.start() }
    }

    private var runtimePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECORDER")
                .font(.system(size: 22, weight: .black, design: .rounded))

            HStack(spacing: 8) {
                metricCell(title: "STATE", value: vm.runtime.state.rawValue.uppercased())
                metricCell(title: "SEGMENTS", value: "\(vm.runtime.transcribedSegments)/\(vm.runtime.totalSegments)")
            }

            HStack(spacing: 8) {
                metricCell(title: "TIME", value: format(seconds: vm.runtime.elapsed))
                metricCell(title: "NETWORK", value: vm.runtime.isNetworkAvailable ? "ONLINE" : "OFFLINE")
            }

            BrutalMeter(bars: vm.runtime.audioBars)
                .frame(height: 24)

            metricCell(title: "INPUT", value: vm.runtime.inputDevice)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("START") { vm.startRecording() }
                        .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.signal, text: BrutalPalette.black))
                    Button("PAUSE") { vm.pauseRecording() }
                        .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.warning, text: BrutalPalette.black))
                    Button("RESUME") { vm.resumeRecording() }
                        .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.ink, text: BrutalPalette.paper))
                    Button("STOP") { vm.stopRecording() }
                        .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.black, text: BrutalPalette.paper))
                }
            }

            if let error = vm.runtime.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption.bold())
                    .foregroundStyle(BrutalPalette.signal)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(BrutalPalette.signal, lineWidth: 2))
            }
        }
        .padding(12)
        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 3))
        .background(BrutalPalette.paper)
    }

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SESSIONS")
                .font(.system(size: 24, weight: .black, design: .rounded))

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.bold())
                    TextField("Search", text: $vm.searchQuery)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
                Button("GO") { vm.refreshSearch() }
                    .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.black, text: BrutalPalette.paper))
                    .frame(width: 86)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.sessions) { session in
                        HStack(spacing: 8) {
                            Button {
                                vm.selectSession(session)
                            } label: {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)

                            Button("DELETE") {
                                vm.deleteSession(session)
                            }
                            .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.signal, text: BrutalPalette.black))
                            .frame(width: 92)
                        }
                        .onAppear {
                            vm.loadMoreSessionsIfNeeded(current: session)
                        }
                    }
                }
            }
        }
        .padding(12)
        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 3))
        .background(BrutalPalette.paper)
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TRANSCRIPT")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                Spacer()
                if !vm.selectedSegments.isEmpty {
                    Button("FULL") {
                        showingFullTranscript = true
                    }
                    .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.black, text: BrutalPalette.paper))
                    .frame(width: 84)
                }
            }

            if let session = vm.selectedSession {
                Text(session.title.uppercased())
                    .font(.headline.weight(.black))

                if vm.selectedSegments.isEmpty {
                    Text("Waiting for first 30s segment...")
                        .font(.caption.bold())
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.selectedSegments) { segment in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("#\(segment.index) • \(segment.status.rawValue.uppercased())")
                                        .font(.caption.bold())
                                    Text(segment.text.isEmpty ? "(transcribing...)" : segment.text)
                                        .font(.body.monospaced())
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text("SELECT A SESSION")
                    .font(.title3.weight(.heavy))
                Spacer()
            }
        }
        .padding(12)
        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 3))
        .background(BrutalPalette.paper)
    }

    private var fullTranscriptSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("FULL TRANSCRIPT")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                    Spacer()
                    Button("DONE") { showingFullTranscript = false }
                        .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.black, text: BrutalPalette.paper))
                        .frame(width: 90)
                }

                if vm.selectedSegments.isEmpty {
                    Text("No transcript available.")
                        .font(.body.monospaced())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                vm.selectedSegments
                                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                                    .joined(separator: "\n\n")
                            )
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                    }
                    .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
                }
            }
            .padding(14)
            .background(BrutalPalette.paper.ignoresSafeArea())
        }
    }

    private var tokenSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("ELEVENLABS API KEY")
                    .font(.title2.weight(.black))
                TextField("xi-api-key...", text: $vm.apiToken)
                    .textFieldStyle(BrutalFieldStyle())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("Save In Keychain") {
                    vm.saveToken()
                    vm.showingTokenSheet = false
                }
                .buttonStyle(BrutalButtonStyle(fill: BrutalPalette.black, text: BrutalPalette.paper))
                Spacer()
            }
            .padding(16)
            .background(BrutalPalette.paper.ignoresSafeArea())
        }
    }

    private func sessionRow(_ session: RecordingSessionDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title.uppercased())
                .font(.headline.weight(.heavy))
                .lineLimit(1)
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
            Text("\(session.transcribedSegments)/\(session.totalSegments) • \(session.quality.displayName.uppercased())")
                .font(.caption.bold())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(vm.selectedSession?.id == session.id ? BrutalPalette.warning.opacity(0.4) : .clear)
        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.bold))
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .lineLimit(1)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
    }

    private func format(seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}

private enum BrutalPalette {
    static let paper = Color(red: 0.97, green: 0.95, blue: 0.9)
    static let black = Color.black
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.09)
    static let signal = Color(red: 1, green: 0.22, blue: 0.22)
    static let warning = Color(red: 1, green: 0.82, blue: 0.22)
}

private struct BrutalButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.black))
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .foregroundStyle(text)
            .background(configuration.isPressed ? fill.opacity(0.7) : fill)
            .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 3))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct BrutalFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(10)
            .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
            .font(.system(.body, design: .monospaced))
    }
}

private struct BrutalMeter: View {
    let bars: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<20, id: \.self) { i in
                let source = bars.isEmpty ? 6 : bars[i % bars.count]
                Rectangle()
                    .fill(BrutalPalette.signal)
                    .frame(width: 9, height: CGFloat(source))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrutalPalette.ink)
        .overlay(Rectangle().stroke(BrutalPalette.black, lineWidth: 2))
    }
}

#Preview {
    ContentView()
}
